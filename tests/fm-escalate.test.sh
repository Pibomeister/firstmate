#!/usr/bin/env bash
# tests/fm-escalate.test.sh - the escalation gate appends incident transitions
# and decides sends from the incident ledger alone: only exception classes
# escalate; three passes over one unchanged exception send once; a state change
# sends one delta naming both states; a cleared incident sends one closure
# record; an A, B, A sequence sends no second escalation for A; a cause and its
# effect give one escalation in either arrival order; and --wake enqueues one
# wake per transition, once across a crash before or after the enqueue.
# Every report is a fresh process, so a "restart" is every second report.
# Delivery goes to an FM_ESCALATE_DELIVER stub under FM_TEST_SEAM=1, and
# fm_now is the shared fixed-clock seam.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm-escalate.sh"
WAKE_LEDGER_LIB="$ROOT/bin/fm-wake-ledger-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-escalate-tests)
T0=1800000000
tab=$(printf '\t')

# The delivery stub appends each message to $FM_ESCALATE_LOG and exits non-zero
# when FM_ESCALATE_FAIL=1.
STUB="$TMP_ROOT/deliver-stub"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${FM_ESCALATE_LOG:-/dev/null}"
[ "${FM_ESCALATE_FAIL:-}" != 1 ] || exit 1
exit 0
EOF
chmod +x "$STUB"

# A notifier recorder for the real channel path: it logs "<channel>\t<summary>".
REC="$TMP_ROOT/notifier-rec"
cat > "$REC" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "${FM_WEDGE_ALARM_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$REC"

new_home() {  # <name>: a fresh home with a state directory; print its path
  mkdir -p "$TMP_ROOT/$1/state"
  : > "$TMP_ROOT/$1/sent.log"
  printf '%s\n' "$TMP_ROOT/$1"
}

# esc <home> <now> <report args...>: one gate process; print its output line.
esc() {
  local home=$1 now=$2
  shift 2
  env -u FM_STATE_OVERRIDE FM_HOME="$home" FM_TEST_SEAM=1 FM_NOW="$now" FM_ESCALATE_DELIVER="$STUB" \
    FM_ESCALATE_LOG="$home/sent.log" FM_WEDGE_ALARM_EXEC=discard \
    bash "$GATE" report "$@"
}

field() {  # <output-line> <name>: the value of name=value
  printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"
}

rows() {  # <home>: the number of ledger rows
  if [ -f "$1/state/incident-ledger.tsv" ]; then wc -l < "$1/state/incident-ledger.tsv" | tr -d ' '; else echo 0; fi
}

col() {  # <home> <row> <column>: one ledger column
  sed -n "$2p" "$1/state/incident-ledger.tsv" | cut -f"$3"
}

sent() {  # <home>: the number of delivered messages
  wc -l < "$1/sent.log" | tr -d ' '
}

queued() {  # <home>: the number of queued wake rows
  if [ -f "$1/state/.wake-queue" ]; then wc -l < "$1/state/.wake-queue" | tr -d ' '; else echo 0; fi
}

ikey() {  # <home> <subject> <signal> <state>: an incident key
  printf '%s|%s|%s|%s' "$1" "$2" "$3" "$4"
}

expect_line() {  # <output> <transition> <action> <wake> <send> <msg>
  assert_equals "transition=$2 action=$3 wake=$4 send=$5" "$1" "$6"
}

test_three_passes_over_one_exception_send_once() {
  local h out
  h=$(new_home three-passes)
  out=$(esc "$h" "$T0" --subject feat-a --signal health-verdict --state dead) || fail "first pass failed"
  expect_line "$out" t1 escalate none sent "the first pass escalates"
  out=$(esc "$h" $((T0 + 60)) --subject feat-a --signal health-verdict --state dead) || fail "second pass failed"
  expect_line "$out" none none none none "the second pass appends and sends nothing"
  out=$(esc "$h" $((T0 + 120)) --subject feat-a --signal health-verdict --state dead) || fail "third pass failed"
  expect_line "$out" none none none none "the third pass appends and sends nothing"
  assert_equals 1 "$(rows "$h")" "one ledger row for three passes"
  assert_equals 1 "$(sent "$h")" "one escalation left the gate"
  assert_equals "health-dead" "$(col "$h" 1 7)" "the exception class comes from the class map"
  assert_equals e1 "$(col "$h" 1 8)" "the first exception opens episode e1"
  assert_contains "$(cat "$h/sent.log")" "state=dead" "the message names the state"
  assert_contains "$(cat "$h/sent.log")" "class=health-dead" "the message names the class"
  pass "three passes over one unchanged exception produce one escalation, across fresh processes"
}

test_routine_states_record_and_send_nothing() {
  local h out
  h=$(new_home routine)
  out=$(esc "$h" "$T0" --subject feat-a --signal stall-detection --state first-nudge) || fail "nudge failed"
  expect_line "$out" t1 record none none "a nudge with no open episode is a record row"
  assert_equals routine "$(col "$h" 1 7)" "the nudge is routine"
  assert_equals record "$(col "$h" 1 11)" "the nudge action is record"
  out=$(esc "$h" "$T0" --subject feat-a --signal handoff-interval --state context-churn) || fail "churn failed"
  expect_line "$out" t2 record none none "context-churn is a routine recorded incident"
  out=$(esc "$h" "$T0" --subject feat-a --signal stall-detection --state some-unmapped-state) || fail "unmapped failed"
  expect_line "$out" t3 record none none "a state the map does not name is routine"
  out=$(esc "$h" "$T0" --subject feat-a --signal stall-detection --state first-nudge) || fail "repeat failed"
  expect_line "$out" t4 record none none "a routine state after another routine state appends a record row"
  assert_equals 0 "$(sent "$h")" "no routine recovery sends anything"
  pass "a routine recovery writes its record and sends nothing"
}

test_class_map_decides_the_class() {
  local h
  h=$(new_home classes)
  esc "$h" "$T0" --subject s --signal wedge-alarm --state inject-wedged > /dev/null || fail "wedge failed"
  esc "$h" "$T0" --subject s --signal permission-dialog --state waiting > /dev/null || fail "dialog failed"
  esc "$h" "$T0" --subject s --signal conflict-state --state conflicted > /dev/null || fail "conflict failed"
  esc "$h" "$T0" --subject s --signal conflict-state --state clean > /dev/null || fail "clean failed"
  esc "$h" "$T0" --subject s --signal quota-floor --state all-candidates-at-floor > /dev/null || fail "quota failed"
  esc "$h" "$T0" --subject s --signal restart-budget --state refused-over-budget > /dev/null || fail "restart failed"
  esc "$h" "$T0" --subject s --signal away-decision --state waiting > /dev/null || fail "away failed"
  assert_equals "inject-wedged permission-dialog conflicted-pr routine quota-all-at-floor restart-loop blocked-decision" \
    "$(cut -f7 "$h/state/incident-ledger.tsv" | tr '\n' ' ' | sed 's/ $//')" "each state keeps its mapped class"
  assert_equals 7 "$(sent "$h")" "six exceptions escalate, the clean state sends only its closure record"
  pass "the class map assigns each state its class"
}

test_delta_names_old_and_new_states() {
  local h out
  h=$(new_home delta)
  esc "$h" "$T0" --subject feat-a --signal stall-detection --state second-detection > /dev/null || fail "first failed"
  out=$(esc "$h" $((T0 + 60)) --subject feat-a --signal stall-detection --state restart-failed) || fail "delta failed"
  expect_line "$out" t2 delta none sent "a state change on an open incident is a delta"
  assert_equals unconfirmed-restart "$(col "$h" 2 7)" "the delta carries the new class"
  assert_equals e1 "$(col "$h" 2 8)" "the delta stays in the episode"
  assert_contains "$(sed -n 2p "$h/sent.log")" "old=second-detection" "the delta names the old state"
  assert_contains "$(sed -n 2p "$h/sent.log")" "new=restart-failed" "the delta names the new state"
  assert_equals 2 "$(sent "$h")" "one escalation and one delta"
  pass "a state change sends one delta that names the old and new states"
}

test_closure_sends_one_record_and_opens_a_new_episode() {
  local h out
  h=$(new_home closure)
  esc "$h" "$T0" --subject feat-a --signal health-verdict --state dead > /dev/null || fail "open failed"
  out=$(esc "$h" $((T0 + 60)) --subject feat-a --signal health-verdict --state ok) || fail "close failed"
  expect_line "$out" t2 closure none sent "a routine state closes the episode"
  assert_equals e1 "$(col "$h" 2 8)" "the closure row stays in the episode"
  assert_contains "$(sed -n 2p "$h/sent.log")" "incident closed" "the closure record says so"
  assert_contains "$(sed -n 2p "$h/sent.log")" "escalations=1" "the closure record counts the escalations"
  out=$(esc "$h" $((T0 + 120)) --subject feat-a --signal health-verdict --state ok) || fail "repeat close failed"
  expect_line "$out" none none none none "nothing follows a closure in its episode"
  out=$(esc "$h" $((T0 + 150)) --subject feat-a --signal health-verdict --state cleared) || fail "cleared failed"
  expect_line "$out" t3 record none none "cleared with no open episode is a record row"
  out=$(esc "$h" $((T0 + 180)) --subject feat-a --signal health-verdict --state dead) || fail "reopen failed"
  expect_line "$out" t4 escalate none sent "an exception after a closure escalates once"
  assert_equals e2 "$(col "$h" 4 8)" "the exception opens episode e2"
  assert_equals 3 "$(sent "$h")" "escalation, closure and the new escalation"
  esc "$h" $((T0 + 240)) --subject feat-a --signal health-verdict --state cleared > /dev/null || fail "cleared close failed"
  assert_equals closure "$(col "$h" 5 11)" "cleared closes an open episode for any signal"
  pass "a cleared incident sends one closure record, and a later exception opens a new episode"
}

test_a_b_a_sends_no_second_escalation_for_a() {
  local h out
  h=$(new_home aba)
  out=$(esc "$h" "$T0" --subject feat-a --signal stall-detection --state second-detection --wake) || fail "A failed"
  expect_line "$out" t1 escalate 1 sent "A escalates and wakes"
  out=$(esc "$h" $((T0 + 60)) --subject feat-a --signal stall-detection --state restart-failed --wake) || fail "B failed"
  expect_line "$out" t2 delta 2 sent "B is a delta and wakes"
  out=$(esc "$h" $((T0 + 120)) --subject feat-a --signal stall-detection --state second-detection --wake) || fail "return to A failed"
  expect_line "$out" t3 record 3 none "the return to A writes a row and wakes but sends nothing"
  assert_equals "escalate delta record" "$(cut -f11 "$h/state/incident-ledger.tsv" | tr '\n' ' ' | sed 's/ $//')" "the A, B, A actions"
  assert_equals 2 "$(sent "$h")" "no second escalation for A, not even a delta"
  assert_equals 3 "$(queued "$h")" "wake dedupe compares against the latest row, so the return to A wakes again"
  pass "an A, B, A sequence writes a row and wakes for the return to A and sends no second escalation"
}

test_cause_first_then_effect() {
  local h out cause
  h=$(new_home cause-first)
  cause=$(ikey "$h" primary health-verdict dead)
  out=$(esc "$h" "$T0" --subject primary --signal health-verdict --state dead) || fail "cause failed"
  expect_line "$out" t1 escalate none sent "the cause escalates"
  out=$(esc "$h" $((T0 + 5)) --subject primary --signal stall-detection --state second-detection --cause "$cause") || fail "effect failed"
  expect_line "$out" t2 record none none "the effect is recorded and sends nothing"
  assert_equals "$cause" "$(col "$h" 2 9)" "the cause key is stored in the cause column"
  assert_equals e1 "$(col "$h" 2 8)" "the effect opens its own episode"
  out=$(esc "$h" $((T0 + 10)) --subject primary --signal stall-detection --state second-detection --cause "$cause") || fail "repeat failed"
  expect_line "$out" none none none none "a repeat while the cause is open appends nothing"
  assert_equals 1 "$(sent "$h")" "a cause and its effect give one escalation"
  assert_equals 2 "$(rows "$h")" "two rows"
  pass "cause first, effect second gives one escalation"
}

test_effect_first_then_cause() {
  local h out cause
  h=$(new_home effect-first)
  cause=$(ikey "$h" primary health-verdict dead)
  out=$(esc "$h" "$T0" --subject primary --signal stall-detection --state second-detection --cause "$cause") || fail "effect failed"
  expect_line "$out" t1 escalate none sent "the effect arrives first and escalates once"
  assert_equals stall-detected "$(col "$h" 1 7)" "the one escalation carries the effect's class"
  out=$(esc "$h" $((T0 + 5)) --subject primary --signal health-verdict --state dead) || fail "cause failed"
  expect_line "$out" t2 record none none "the cause is recorded and sends nothing"
  out=$(esc "$h" $((T0 + 10)) --subject primary --signal health-verdict --state dead) || fail "cause repeat failed"
  expect_line "$out" none none none none "a repeat while the effect episode is open appends nothing"
  assert_equals 1 "$(sent "$h")" "a cause and its effect give one escalation"
  pass "effect first, cause second gives one escalation, in a fresh process"
}

test_after_both_episodes_close_the_next_report_escalates() {
  local h out cause
  h=$(new_home both-close)
  cause=$(ikey "$h" primary health-verdict dead)
  esc "$h" "$T0" --subject primary --signal health-verdict --state dead > /dev/null || fail "cause failed"
  esc "$h" "$T0" --subject primary --signal stall-detection --state second-detection --cause "$cause" > /dev/null || fail "effect failed"
  esc "$h" "$T0" --subject primary --signal health-verdict --state ok > /dev/null || fail "cause close failed"
  esc "$h" "$T0" --subject primary --signal stall-detection --state first-nudge > /dev/null || fail "effect close failed"
  out=$(esc "$h" "$T0" --subject primary --signal stall-detection --state second-detection --cause "$cause") || fail "report failed"
  expect_line "$out" t5 escalate none sent "with both episodes closed the report escalates normally"
  assert_equals e2 "$(col "$h" 5 8)" "it opens a new episode"
  assert_equals 4 "$(sent "$h")" "cause, its closure, the effect's closure record, and the new escalation"
  pass "a report after both episodes close escalates normally"
}

test_the_first_released_notification_is_an_escalation_after_a_state_change() {
  local h out cause
  h=$(new_home first-released-change)
  cause=$(ikey "$h" primary health-verdict dead)
  esc "$h" "$T0" --subject primary --signal health-verdict --state dead > /dev/null || fail "cause failed"
  esc "$h" "$T0" --subject effect --signal stall-detection --state second-detection --cause "$cause" > /dev/null || fail "withheld state failed"
  esc "$h" "$T0" --subject primary --signal health-verdict --state ok > /dev/null || fail "cause close failed"
  out=$(esc "$h" "$T0" --subject effect --signal stall-detection --state restart-failed --cause "$cause") || fail "changed release failed"
  expect_line "$out" t4 escalate none sent "the episode's first notification cannot be a delta from an unsent state"
  assert_equals e1 "$(col "$h" 4 8)" "the first released notification stays in the existing episode"
  assert_equals 3 "$(sent "$h")" "cause, closure, and the first released exception each send once"
  pass "an episode's first notification is an escalation even after a withheld state changed"
}

test_a_withheld_state_is_released_after_another_state_escalated() {
  local h out cause
  h=$(new_home prior-escalation)
  cause=$(ikey "$h" primary health-verdict dead)
  esc "$h" "$T0" --subject effect --signal stall-detection --state second-detection > /dev/null || fail "initial state failed"
  esc "$h" "$T0" --subject primary --signal health-verdict --state dead > /dev/null || fail "cause failed"
  out=$(esc "$h" "$T0" --subject effect --signal stall-detection --state restart-failed --cause "$cause" --wake) || fail "withheld state failed"
  expect_line "$out" t3 record 1 none "the new state is withheld while its cause holds"
  esc "$h" "$T0" --subject primary --signal health-verdict --state ok > /dev/null || fail "cause close failed"
  out=$(esc "$h" "$T0" --subject effect --signal stall-detection --state restart-failed --cause "$cause" --wake) || fail "release failed"
  expect_line "$out" t5 delta 2 sent "the withheld state must send its own delta after the cause clears"
  assert_equals e1 "$(col "$h" 5 8)" "the released state stays in its episode"
  assert_grep 'old=second-detection new=restart-failed' "$h/sent.log" "the released delta names the last sent state and the withheld state"
  out=$(esc "$h" "$T0" --subject effect --signal stall-detection --state restart-failed --cause "$cause" --wake) || fail "released repeat failed"
  expect_line "$out" t5 none none none "the released state sends and wakes only once"
  assert_equals 4 "$(sent "$h")" "initial effect, cause, closure, and released state each send once"
  assert_equals 5 "$(rows "$h")" "a repeat adds no ledger row"
  pass "a different prior escalation cannot suppress a withheld state's later release"
}

test_suppressed_effect_escalates_once_after_the_cause_clears() {
  local h out cause
  h=$(new_home cause-clears)
  cause=$(ikey "$h" primary health-verdict dead)
  esc "$h" "$T0" --subject primary --signal health-verdict --state dead > /dev/null || fail "cause failed"
  esc "$h" "$T0" --subject primary --signal stall-detection --state second-detection --cause "$cause" --wake > /dev/null || fail "effect failed"
  out=$(esc "$h" "$T0" --subject primary --signal stall-detection --state second-detection --cause "$cause" --wake) || fail "suppressed repeat failed"
  expect_line "$out" t2 none none none "a repeat while suppression holds appends nothing and wakes nothing new"
  assert_equals 2 "$(rows "$h")" "no row while suppression holds"
  esc "$h" "$T0" --subject primary --signal health-verdict --state ok > /dev/null || fail "cause close failed"
  out=$(esc "$h" "$T0" --subject primary --signal stall-detection --state second-detection --cause "$cause" --wake) || fail "released report failed"
  assert_equals escalate "$(field "$out" action)" "the next report escalates once"
  assert_equals t4 "$(field "$out" transition)" "it appends one new row"
  assert_equals sent "$(field "$out" send)" "and sends once"
  assert_not_equals none "$(field "$out" wake)" "and wakes once"
  assert_equals escalate "$(col "$h" 4 11)" "the released row is an escalate row"
  assert_equals e1 "$(col "$h" 4 8)" "in the effect's open episode"
  out=$(esc "$h" "$T0" --subject primary --signal stall-detection --state second-detection --cause "$cause" --wake) || fail "next repeat failed"
  expect_line "$out" t4 none none none "a repeat after the release appends nothing"
  assert_equals 4 "$(rows "$h")" "four rows"
  assert_equals 3 "$(sent "$h")" "cause escalation, cause closure, then the released effect"
  assert_equals 2 "$(queued "$h")" "the effect's record wake and the release wake"
  pass "a suppressed effect escalates once when its cause clears while the state persists"
}

test_suppressed_cause_escalates_once_after_the_effect_clears() {
  local h out cause
  h=$(new_home effect-clears)
  cause=$(ikey "$h" primary health-verdict dead)
  esc "$h" "$T0" --subject primary --signal stall-detection --state second-detection --cause "$cause" > /dev/null || fail "effect failed"
  esc "$h" "$T0" --subject primary --signal health-verdict --state dead > /dev/null || fail "cause failed"
  out=$(esc "$h" "$T0" --subject primary --signal health-verdict --state dead) || fail "suppressed repeat failed"
  expect_line "$out" none none none none "a repeat while suppression holds appends nothing"
  esc "$h" "$T0" --subject primary --signal stall-detection --state first-nudge > /dev/null || fail "effect close failed"
  out=$(esc "$h" "$T0" --subject primary --signal health-verdict --state dead) || fail "released report failed"
  expect_line "$out" t4 escalate none sent "the next report of the cause escalates once"
  assert_equals e1 "$(col "$h" 4 8)" "in the cause's open episode"
  out=$(esc "$h" "$T0" --subject primary --signal health-verdict --state dead) || fail "next repeat failed"
  expect_line "$out" none none none none "a repeat after the release appends nothing"
  assert_equals 3 "$(sent "$h")" "effect escalation, its closure, then the released cause"
  pass "the mirror case: a suppressed cause escalates once when its effect clears"
}

test_wake_once_per_transition_and_never_for_a_repeat() {
  local h out
  h=$(new_home wake)
  out=$(esc "$h" "$T0" --subject feat-a --signal health-verdict --state dead --wake) || fail "wake failed"
  assert_equals t1 "$(field "$out" transition)" "the transition id"
  assert_equals 1 "$(field "$out" wake)" "the queue sequence"
  assert_equals "incident${tab}incident-t1${tab}transition=t1" "$(cut -f3-5 "$h/state/.wake-queue")" "kind incident, key incident-<id> and payload transition=<id>"
  out=$(esc "$h" "$T0" --subject feat-a --signal health-verdict --state dead --wake) || fail "repeat failed"
  expect_line "$out" t1 none none none "a repeat prints the latest transition and wakes nothing, the queue already holds the key"
  assert_equals 1 "$(queued "$h")" "one wake in the queue"
  out=$(esc "$h" "$T0" --subject feat-a --signal health-verdict --state ok --wake) || fail "routine wake failed"
  assert_equals closure "$(field "$out" action)" "the closure"
  assert_not_equals none "$(field "$out" wake)" "a routine transition wakes too"
  out=$(esc "$h" "$T0" --subject feat-b --signal health-verdict --state ok) || fail "no-wake failed"
  assert_equals none "$(field "$out" wake)" "no --wake, no wake"
  assert_equals 2 "$(queued "$h")" "two wakes for two transitions"
  pass "each transition that asks for a wake yields one, and a repeat yields none"
}

test_wake_dedupe_reads_the_wake_ledger() {
  local h out
  h=$(new_home wake-ledger)
  esc "$h" "$T0" --subject feat-a --signal health-verdict --state dead --wake > /dev/null || fail "wake failed"
  # The drain removes the row and records the removal in the wake ledger.
  : > "$h/state/.wake-queue"
  FM_TEST_SEAM=1 FM_NOW="$T0" bash -c '. "$0"; fm_wake_ledger_append_locked "$1" ack gen1 1 1 "[\"incident-t1\"]"' "$WAKE_LEDGER_LIB" "$h/state" \
    || fail "wake ledger append failed"
  out=$(esc "$h" "$T0" --subject feat-a --signal health-verdict --state dead --wake) || fail "retry failed"
  expect_line "$out" t1 none none none "a retry after the drain acknowledged the wake wakes no second time"
  assert_equals 0 "$(queued "$h")" "nothing was queued again"
  pass "wake dedupe checks the wake ledger as well as the queue"
}

test_a_second_producer_adds_no_wake() {
  local h out
  h=$(new_home two-producers)
  esc "$h" "$T0" --subject feat-a --signal health-verdict --state dead --wake > /dev/null || fail "first producer failed"
  out=$(esc "$h" "$T0" --subject feat-a --signal health-verdict --state dead --wake) || fail "second producer failed"
  expect_line "$out" t1 none none none "the second producer's report adds no row and no wake"
  assert_equals 1 "$(queued "$h")" "one wake for one transition"
  assert_equals 1 "$(rows "$h")" "one row"
  pass "two producers reporting one transition yield one wake"
}

test_quiet_hours_never_delay_a_wake() {
  local h out night
  h=$(new_home quiet-wake)
  night=1793768400 # Tuesday 23:00 America/Costa_Rica, inside quiet hours
  out=$(esc "$h" "$night" --subject feat-a --signal health-verdict --state dead --wake) || fail "night report failed"
  assert_not_equals none "$(field "$out" wake)" "the wake is enqueued at night"
  assert_equals 1 "$(queued "$h")" "the wake is in the queue"
  pass "quiet hours never hold or delay a wake"
}

test_crash_between_append_and_enqueue() {
  local h out rc=0
  h=$(new_home crash-append)
  ( env -u FM_STATE_OVERRIDE FM_HOME="$h" FM_TEST_SEAM=1 FM_NOW="$T0" FM_ESCALATE_DELIVER="$STUB" FM_ESCALATE_LOG="$h/sent.log" \
    FM_ESCALATE_CRASH_AT=after-append bash "$GATE" report --subject feat-a --signal health-verdict --state dead --wake ) > "$TMP_ROOT/crash1.out" 2>&1 || rc=$?
  assert_not_equals 0 "$rc" "the crash point kills the process"
  assert_equals 1 "$(rows "$h")" "the row was appended before the crash"
  assert_equals 0 "$(queued "$h")" "no wake was enqueued before the crash"
  out=$(esc "$h" $((T0 + 5)) --subject feat-a --signal health-verdict --state dead --wake) || fail "retry failed"
  assert_equals t1 "$(field "$out" transition)" "the retry prints the first report's transition id"
  assert_equals none "$(field "$out" action)" "and appends nothing"
  assert_not_equals none "$(field "$out" wake)" "and enqueues the lost wake"
  assert_equals 1 "$(rows "$h")" "still one row"
  assert_equals 1 "$(queued "$h")" "one wake"
  out=$(esc "$h" $((T0 + 10)) --subject feat-a --signal health-verdict --state dead --wake) || fail "second retry failed"
  assert_equals none "$(field "$out" wake)" "a further retry wakes no second time"
  assert_equals 1 "$(queued "$h")" "still one wake"
  pass "a retry after a crash between the append and the enqueue wakes once"
}

test_crash_after_enqueue() {
  local h out rc=0
  h=$(new_home crash-enqueue)
  ( env -u FM_STATE_OVERRIDE FM_HOME="$h" FM_TEST_SEAM=1 FM_NOW="$T0" FM_ESCALATE_DELIVER="$STUB" FM_ESCALATE_LOG="$h/sent.log" \
    FM_ESCALATE_CRASH_AT=after-enqueue bash "$GATE" report --subject feat-a --signal health-verdict --state dead --wake ) > "$TMP_ROOT/crash2.out" 2>&1 || rc=$?
  assert_not_equals 0 "$rc" "the crash point kills the process"
  assert_equals 1 "$(rows "$h")" "the row was appended"
  assert_equals 1 "$(queued "$h")" "the wake was enqueued"
  out=$(esc "$h" $((T0 + 5)) --subject feat-a --signal health-verdict --state dead --wake) || fail "retry failed"
  expect_line "$out" t1 none none none "the retry enqueues no second wake"
  assert_equals 1 "$(rows "$h")" "still one row"
  assert_equals 1 "$(queued "$h")" "still one wake"
  pass "a retry after a crash that follows the enqueue wakes no second time"
}

test_message_carries_text_and_detail() {
  local h msg
  h=$(new_home text)
  printf 'line one\nline two\n' > "$TMP_ROOT/body.txt"
  esc "$h" "$T0" --subject feat-a --signal health-verdict --state dead --text-file "$TMP_ROOT/body.txt" --detail 'two passes' > /dev/null || fail "report failed"
  msg=$(cat "$h/sent.log")
  assert_contains "$msg" "line one line two" "the caller's text is on one line"
  assert_contains "$msg" "(two passes)" "the detail is appended"
  assert_equals 1 "$(sent "$h")" "one message"
  esc "$h" "$T0" --subject feat-b --signal health-verdict --state dead --text 'plain body' > /dev/null || fail "text report failed"
  assert_contains "$(sed -n 2p "$h/sent.log")" "plain body" "--text works"
  pass "the caller's text and detail travel in the message"
}

test_send_results() {
  local h out before
  h=$(new_home send)
  out=$(FM_ESCALATE_FAIL=1 esc "$h" "$T0" --subject a --signal health-verdict --state dead) || fail "failing send aborted the gate"
  assert_equals failed "$(field "$out" send)" "a stub that exits non-zero reads as failed"
  assert_equals 1 "$(rows "$h")" "the row is written even when the send fails"
  # Without the stub the message goes through wedge_alarm_notify and its channels.
  out=$(env -u FM_STATE_OVERRIDE FM_HOME="$h" FM_TEST_SEAM=1 FM_NOW="$T0" FM_WEDGE_ALARM_CHANNEL=osascript \
    FM_WEDGE_ALARM_EXEC="$REC" FM_WEDGE_ALARM_LOG="$h/channel.log" bash "$GATE" report --subject b --signal health-verdict --state dead) \
    || fail "channel send failed"
  assert_equals sent "$(field "$out" send)" "a delivered channel reads as sent"
  assert_contains "$(cat "$h/channel.log")" "osascript${tab}escalation: signal=health-verdict subject=b" "the channel got the composed message"
  out=$(env -u FM_STATE_OVERRIDE FM_HOME="$h" FM_TEST_SEAM=1 FM_NOW="$T0" FM_WEDGE_ALARM_CHANNEL=off \
    FM_WEDGE_ALARM_EXEC="$REC" FM_WEDGE_ALARM_LOG="$h/channel2.log" bash "$GATE" report --subject c --signal health-verdict --state dead) \
    || fail "off send failed"
  assert_equals pending "$(field "$out" send)" "no attempted channel reads as pending"
  assert_absent "$h/channel2.log" "the off directive sends nothing"
  # The stub is honoured only under the test seam.
  before=$(sent "$h")
  out=$(env -u FM_STATE_OVERRIDE -u FM_TEST_SEAM FM_HOME="$h" FM_ESCALATE_DELIVER="$STUB" FM_ESCALATE_LOG="$h/sent.log" \
    FM_WEDGE_ALARM_CHANNEL=osascript FM_WEDGE_ALARM_EXEC=discard bash "$GATE" report --subject d --signal health-verdict --state dead) \
    || fail "no-seam send failed"
  assert_equals sent "$(field "$out" send)" "the channel path still delivers"
  assert_equals "$before" "$(sent "$h")" "the stub got nothing without FM_TEST_SEAM=1"
  pass "send results: sent, failed and pending, and the stub needs the test seam"
}

test_concurrent_reports_give_one_escalation() {
  local h i
  h=$(new_home concurrent)
  for i in 1 2 3 4 5 6; do
    esc "$h" "$T0" --subject feat-a --signal health-verdict --state dead --wake > "$TMP_ROOT/concurrent-$i.out" &
  done
  wait
  assert_equals 1 "$(rows "$h")" "concurrent reports append one row"
  assert_equals 1 "$(sent "$h")" "and send once"
  assert_equals 1 "$(queued "$h")" "and wake once"
  pass "concurrent reports of one exception give one row, one send and one wake"
}

test_command_contract() {
  local h out rc
  h=$(new_home contract)
  rc=0
  out=$(esc "$h" "$T0" --subject a --signal s 2>&1) || rc=$?
  assert_equals 1 "$rc" "a missing --state is refused"
  assert_contains "$out" "--state is required" "the refusal names the flag"
  rc=0
  out=$(esc "$h" "$T0" --subject a --signal s --state x --bogus 2>&1) || rc=$?
  assert_equals 1 "$rc" "an unknown flag is refused"
  rc=0
  out=$(esc "$h" "$T0" --subject a --signal s --state x --cause not-a-key 2>&1) || rc=$?
  assert_equals 1 "$rc" "a cause that is not an incident key is refused"
  rc=0
  out=$(esc "$h" "$T0" --subject a --signal s --state x --text t --text-file /nonexistent 2>&1) || rc=$?
  assert_equals 1 "$rc" "--text with --text-file is refused"
  assert_equals 0 "$(rows "$h")" "a refusal writes nothing"
  rc=0
  out=$(env -u FM_STATE_OVERRIDE FM_HOME="$h" bash "$GATE" nonsense 2>&1) || rc=$?
  assert_equals 2 "$rc" "an unknown subcommand exits 2"
  rc=0
  out=$(env -u FM_STATE_OVERRIDE FM_HOME="$h" bash "$GATE" --help 2>&1) || rc=$?
  assert_equals 0 "$rc" "--help exits 0"
  assert_contains "$out" "report --subject" "--help prints the usage"
  rc=0
  out=$(env -u FM_STATE_OVERRIDE FM_HOME="$TMP_ROOT/no-such-home" FM_TEST_SEAM=1 bash "$GATE" report --subject a --signal s --state x 2>&1) || rc=$?
  assert_equals 1 "$rc" "a missing state directory is refused"
  pass "the command refuses bad input and writes nothing"
}

test_the_wake_lib_accepts_incident_and_refuses_unknown_kinds() {
  local h rc=0
  h=$(new_home wakelib)
  ( unset FM_STATE_OVERRIDE; FM_HOME="$h" bash -c '. "$0"; fm_wake_append incident incident-t1 transition=t1' "$ROOT/bin/fm-wake-lib.sh" ) > "$TMP_ROOT/wl1.out" 2>&1 \
    || fail "the wake library refused kind incident: $(cat "$TMP_ROOT/wl1.out")"
  assert_equals 1 "$(queued "$h")" "kind incident queues one row"
  ( unset FM_STATE_OVERRIDE; FM_HOME="$h" bash -c '. "$0"; fm_wake_append bogus bogus-1 x' "$ROOT/bin/fm-wake-lib.sh" ) > "$TMP_ROOT/wl2.out" 2>&1 || rc=$?
  assert_not_equals 0 "$rc" "an unknown kind is refused"
  assert_equals 1 "$(queued "$h")" "an unknown kind queues nothing"
  pass "the wake library accepts kind incident and still refuses an unknown kind"
}

fm_test_run \
  test_the_first_released_notification_is_an_escalation_after_a_state_change \
  test_a_withheld_state_is_released_after_another_state_escalated \
  test_three_passes_over_one_exception_send_once \
  test_routine_states_record_and_send_nothing \
  test_class_map_decides_the_class \
  test_delta_names_old_and_new_states \
  test_closure_sends_one_record_and_opens_a_new_episode \
  test_a_b_a_sends_no_second_escalation_for_a \
  test_cause_first_then_effect \
  test_effect_first_then_cause \
  test_after_both_episodes_close_the_next_report_escalates \
  test_suppressed_effect_escalates_once_after_the_cause_clears \
  test_suppressed_cause_escalates_once_after_the_effect_clears \
  test_wake_once_per_transition_and_never_for_a_repeat \
  test_wake_dedupe_reads_the_wake_ledger \
  test_a_second_producer_adds_no_wake \
  test_quiet_hours_never_delay_a_wake \
  test_crash_between_append_and_enqueue \
  test_crash_after_enqueue \
  test_message_carries_text_and_detail \
  test_send_results \
  test_concurrent_reports_give_one_escalation \
  test_command_contract \
  test_the_wake_lib_accepts_incident_and_refuses_unknown_kinds
