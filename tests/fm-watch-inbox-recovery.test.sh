#!/usr/bin/env bash
# tests/fm-watch-inbox-recovery.test.sh - the watcher's automatic bounded
# recovery of a local secondmate's unacknowledged steering-inbox record
# (bin/fm-watch.sh; bin/fm-task-inbox-lib.sh owns the budget, the age bound and
# the answered proof). Each check runs the real watcher's inbox check against a
# fake tmux and a recording stand-in for bin/fm-control.sh, and pins that a
# spent ladder or a stuck-busy pane is interrupted and redirected at most twice
# per record and only past the charter's acknowledgement allowance, before
# exactly one alarm; that crewmates, remote secondmates and a relaunched
# generation keep their own budgets; and that a failed interrupt, failed
# bookkeeping or a busy-bookkeeping failure alarms at once instead of passing
# for a recovery. tests/fm-task-inbox.test.sh owns the inbox records, the
# doorbell, the composer and the ladder itself.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=tests/task-inbox-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/task-inbox-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-inbox-recovery)
# The doorbell line canonicalizes its paths, so keep the fixture root
# canonical too (a trailing-slash TMPDIR otherwise yields a double slash).
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Stuck-busy on a local secondmate of a harness whose busy state is verified is
# answered by the same bounded recovery before any alarm.
test_watcher_busy_secondmate_is_recovered_before_alarm() {
  local dir state
  dir=$(busy_case busy-recover)
  state="$dir/state"
  fm_write_meta "$state/t1.meta" "window=sess:fm-t1" "kind=secondmate" "harness=grok"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/control.log"\n' "$dir" > "$dir/fakebin/fm-control"
  chmod +x "$dir/fakebin/fm-control"
  : > "$dir/control.log"
  FM_CONTROL_BIN="$dir/fakebin/fm-control" busy_steer_check "$dir"
  FM_CONTROL_BIN="$dir/fakebin/fm-control" busy_steer_check "$dir"
  [ "$(grep -c '^t1 interrupt$' "$dir/control.log")" = 1 ] \
    || fail "a stuck-busy secondmate was not interrupted once:"$'\n'"$(cat "$dir/control.log")"
  [ ! -s "$state/.wake-queue" ] || fail "a recovered stuck-busy secondmate also alarmed:"$'\n'"$(cat "$state/.wake-queue")"
  pass "watcher: a stuck-busy local secondmate is interrupted and redirected before any alarm"
}

# A local secondmate's unacknowledged record is recovered automatically, at
# most twice per record, through the existing lifecycle interrupt and an
# ordinary doorbell, before exactly one alarm. The control plane is a
# recording stand-in reached through the watcher's real escalation path.
recover_case() {  # <name> [meta lines...]
  local dir
  dir=$(setup_watch_case "$1")
  shift
  fm_write_meta "$dir/state/t1.meta" "window=sess:fm-t1" "$@"
  cat > "$dir/fakebin/fm-control" <<'SH'
#!/usr/bin/env bash
printf 'FM_HOME=%s %s\n' "${FM_HOME:-}" "$*" >> "$FM_CONTROL_LOG"
SH
  chmod +x "$dir/fakebin/fm-control"
  : > "$dir/control.log"; : > "$dir/send.log"
  printf '%s' "$dir"
}

recover_check() {  # <case-dir>  (RECOVER_CAPTURE replaces the idle pane)
  # The age ceiling stays above these fixtures so its one-time report stays out
  # of their wake counts. RECOVER_AGE_SECS= selects the product default (300s).
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" FM_SEND_LOG="$1/send.log" \
    FM_FAKE_TMUX_CAPTURE="${RECOVER_CAPTURE:-$(idle_capture "$1")}" FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX="${RECOVER_RING_MAX:-0}" \
    FM_TASK_INBOX_SECONDMATE_ESCALATE_SECS="${RECOVER_AGE_SECS-999999999}" \
    FM_CONTROL_BIN="$1/fakebin/fm-control" FM_CONTROL_LOG="$1/control.log" FM_HOME="$1/home" \
    bash -c '. "$1" && inbox_steer_check sess:fm-t1 t1' _ "$WATCH" > "$1/check.out" 2>&1
}

recover_wakes() { cat "$1/state/.wake-queue" 2>/dev/null | grep -c 'unread firstmate instruction' || true; }
recover_interrupts() { grep -c ' t1 interrupt$' "$1/control.log" || true; }
recover_rings() { grep -cF 'Firstmate instruction waiting' "$1/send.log" || true; }

# A record behind an escalated one gets the watcher's own ladder. The newer
# record here is the fm-send redirect the alarm recommends: it is rung, then
# recovered past the bound with an interrupt and its redirect doorbell, and the
# escalated record is not touched again.
test_watcher_recovers_a_record_behind_an_escalated_one() {
  local dir first second rings
  dir=$(recover_case recover-behind "kind=secondmate" "harness=codex" "spawn_gen=g1")
  first=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "stuck ask")
  age_path "$first"
  inbox_lib "$dir/state" fm_task_inbox_record_escalated "$dir/state" t1 "$first"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_SEND_LOG="$dir/send.log" \
    FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    "$ROOT/bin/fm-send.sh" t1 "drain your inbox and dispatch independent work" > "$dir/fm-send.out" 2>&1 \
    || fail "the fm-send redirect failed:"$'\n'"$(cat "$dir/fm-send.out")"
  second=$(inbox_lib "$dir/state" fm_task_inbox_records_in "$dir/state/t1.inbox" | tail -n 1)
  [ -n "$second" ] && [ "$second" != "${first##*/}" ] || fail "the fm-send redirect wrote no new record"
  second="$dir/state/t1.inbox/$second"
  age_path "$second"
  rings=$(recover_rings "$dir")
  RECOVER_RING_MAX=1 recover_check "$dir"
  [ "$(recover_rings "$dir")" = $((rings + 1)) ] && [ "$(recover_interrupts "$dir")" = 0 ] \
    || fail "the redirect behind an escalated record was not rung:"$'\n'"$(cat "$dir/send.log" "$dir/control.log" 2>/dev/null)"
  recover_check "$dir"
  [ "$(recover_interrupts "$dir")" = 1 ] || fail "the redirect behind an escalated record was not recovered:"$'\n'"$(cat "$dir/control.log" 2>/dev/null)"
  [ "$(recover_rings "$dir")" = $((rings + 2)) ] || fail "the recovery interrupt was not followed by its redirect doorbell:"$'\n'"$(cat "$dir/send.log")"
  [ "$(cut -f1 "$dir/state/t1.inbox/.recover-state")" = "${second##*/}" ] \
    || fail "recovery claimed a slot for the escalated record instead of the redirect"
  [ "$(recover_wakes "$dir")" = 0 ] || fail "the escalated record alarmed again"
  pass "watcher: an fm-send redirect behind an escalated record is rung, then interrupted and redirected on its own ladder"
}

test_watcher_auto_recovers_a_secondmate_twice_then_alarms_once() {
  local dir rec
  dir=$(recover_case recover-twice "kind=secondmate" "harness=codex" "spawn_gen=g1")
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "routed ask")
  age_path "$rec"
  recover_check "$dir"
  [ "$(recover_interrupts "$dir")" = 1 ] || fail "the first spent ladder should interrupt once:"$'\n'"$(cat "$dir/control.log")"
  grep -qF "FM_HOME=$dir/home t1 interrupt" "$dir/control.log" || fail "the interrupt did not name this home explicitly"
  [ "$(recover_rings "$dir")" = 1 ] || fail "the interrupt should be followed by one redirect doorbell:"$'\n'"$(cat "$dir/send.log")"
  [ "$(recover_wakes "$dir")" = 0 ] || fail "a recovered record must not also alarm:"$'\n'"$(cat "$dir/state/.wake-queue")"
  recover_check "$dir"
  [ "$(recover_interrupts "$dir")" = 2 ] || fail "the second spent ladder should interrupt again"
  [ "$(recover_wakes "$dir")" = 0 ] || fail "the second recovery must not alarm"
  recover_check "$dir"
  [ "$(recover_interrupts "$dir")" = 2 ] || fail "a third interrupt was sent after two recoveries"
  [ "$(recover_wakes "$dir")" = 1 ] || fail "spent recovery should raise exactly one alarm"
  grep -qF 'automatic recovery already interrupted and redirected it 2 times' "$dir/state/.wake-queue" \
    || fail "the alarm does not say automatic recovery was spent:"$'\n'"$(cat "$dir/state/.wake-queue")"
  grep -qF "$rec" "$dir/state/.wake-queue" || fail "the alarm omitted the durable record"
  recover_check "$dir"; recover_check "$dir"
  [ "$(recover_interrupts "$dir")" = 2 ] && [ "$(recover_wakes "$dir")" = 1 ] \
    || fail "an exhausted record kept interrupting or alarming"
  [ -f "$rec" ] || fail "recovery moved or removed the durable record"
  mv "$rec" "$dir/state/t1.inbox/handled/"
  recover_check "$dir"
  [ ! -e "$dir/state/t1.inbox/.recover-state" ] || fail "an emptied inbox kept its recovery budget"
  pass "watcher: a local secondmate's unacked record is interrupted and redirected twice, then alarms exactly once"
}

test_watcher_recovery_rings_first_only_for_a_proven_answer() {
  local dir rec now
  dir=$(recover_case recover-answered "kind=secondmate" "harness=codex")
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 $'[from-firstmate]\xe2\x81\xa3corr=ab12cd34 routed ask')
  age_path "$rec"
  now=$(date +%s)
  printf 'working [corr=ab12cd340] [at=%s]: other request\n' "$now" > "$dir/state/t1.status"
  printf 'working [corr=ab12cd34] [at=1500000000]: an answer from before this record was enqueued\n' >> "$dir/state/t1.status"
  recover_check "$dir"
  [ "$(recover_interrupts "$dir")" = 1 ] || fail "a historic or prefix corr match must not suppress the interrupt"
  dir=$(recover_case recover-answered-2 "kind=secondmate" "harness=codex")
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 $'[from-firstmate]\xe2\x81\xa3corr=ab12cd34 routed ask')
  age_path "$rec"
  printf 'working [corr=ab12cd34] [key=x] [at=%s]: dispatched crew-x\n' "$(date +%s)" > "$dir/state/t1.status"
  recover_check "$dir"
  [ "$(recover_interrupts "$dir")" = 0 ] || fail "a proven answer should make the first recovery ring-only"
  [ "$(recover_rings "$dir")" = 1 ] || fail "the ring-only recovery did not ring"
  recover_check "$dir"
  [ "$(recover_interrupts "$dir")" = 1 ] || fail "a record still unacked after the ring-only slot should be interrupted"
  recover_check "$dir"
  [ "$(recover_interrupts "$dir")" = 1 ] && [ "$(recover_wakes "$dir")" = 1 ] \
    || fail "the ring-only slot must count toward the two-recovery budget"
  pass "watcher: only a proven post-enqueue answer makes the first recovery ring-only, and it consumes a slot"
}

# Each recovery restarts the record's ladder, so the redirect is followed by
# ordinary doorbells before the next recovery rather than an immediate repeat.
test_watcher_recovery_restarts_the_ladder() {
  local dir rec
  dir=$(recover_case recover-ladder "kind=secondmate" "harness=codex")
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "routed ask")
  age_path "$rec"
  printf '001.msg\t1\t0\n' > "$dir/state/t1.inbox/.ring-state"
  RECOVER_RING_MAX=1 recover_check "$dir"
  [ "$(recover_interrupts "$dir")" = 1 ] || fail "a spent ladder was not recovered"
  RECOVER_RING_MAX=1 recover_check "$dir"
  [ "$(recover_interrupts "$dir")" = 1 ] || fail "the restarted ladder was skipped: a second interrupt followed at once"
  [ "$(recover_rings "$dir")" = 2 ] || fail "the restarted ladder did not ring after the redirect:"$'\n'"$(cat "$dir/send.log")"
  RECOVER_RING_MAX=1 recover_check "$dir"
  [ "$(recover_interrupts "$dir")" = 2 ] || fail "the restarted ladder did not lead to the second recovery"
  pass "watcher: each recovery restarts the ladder before the next recovery"
}

test_watcher_recovery_scope_and_generation() {
  local dir rec kind
  for kind in ship remote; do
    if [ "$kind" = remote ]; then
      dir=$(recover_case "recover-$kind" "kind=secondmate" "harness=codex" "remote_host=example")
    else
      dir=$(recover_case "recover-$kind" "kind=ship" "harness=codex")
    fi
    rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "steer")
    age_path "$rec"
    recover_check "$dir"
    [ "$(recover_interrupts "$dir")" = 0 ] || fail "a $kind worker was interrupted automatically"
    [ "$(recover_wakes "$dir")" = 1 ] || fail "a $kind worker lost its single alarm"
  done
  dir=$(recover_case recover-gen "kind=secondmate" "harness=codex" "spawn_gen=g1")
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "steer")
  age_path "$rec"
  recover_check "$dir"; recover_check "$dir"
  fm_write_meta "$dir/state/t1.meta" "window=sess:fm-t1" "kind=secondmate" "harness=codex" "spawn_gen=g2"
  recover_check "$dir"
  [ "$(recover_interrupts "$dir")" = 3 ] && [ "$(recover_wakes "$dir")" = 0 ] \
    || fail "a relaunched secondmate should get a fresh recovery budget, not the old worker's alarm"
  rm -f "$dir/state/t1.inbox/.recover-state"
  mkdir "$dir/state/t1.inbox/.recover-state"
  recover_check "$dir"
  [ "$(recover_interrupts "$dir")" = 3 ] || fail "unwritable recovery bookkeeping still interrupted"
  grep -q 'recovery bookkeeping unwritable' "$dir/state/.wake-queue" \
    || fail "unwritable recovery bookkeeping did not surface:"$'\n'"$(cat "$dir/state/.wake-queue" 2>/dev/null)"
  pass "watcher: crewmates and remote secondmates keep one alarm, a relaunch resets the budget, and unwritable bookkeeping alarms without interrupting"
}

age_by() {  # <path> <seconds>: set the mtime that many seconds in the past
  python3 -c 'import os, sys, time; t = time.time() - int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$2"
}

# Recovery never interrupts before the charter's 5-minute acknowledgement
# allowance: a spent ladder or busy budget on a younger record stays quiet
# (no slot, no interrupt, no doorbell, no alarm) and the first recovery
# follows once the record is past the default 300 s bound.
test_watcher_recovery_waits_for_the_charter_bound() {
  local dir rec
  dir=$(recover_case recover-bound "kind=secondmate" "harness=codex")
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "routed ask")
  age_by "$rec" 290
  recover_check "$dir"; recover_check "$dir"
  [ "$(recover_interrupts "$dir")" = 0 ] && [ "$(recover_rings "$dir")" = 0 ] && [ "$(recover_wakes "$dir")" = 0 ] \
    || fail "a 290 s record was interrupted, rung or alarmed before the bound:"$'\n'"$(cat "$dir/control.log" "$dir/send.log" "$dir/state/.wake-queue" 2>/dev/null)"
  [ ! -e "$dir/state/t1.inbox/.recover-state" ] || fail "a record younger than the bound claimed a recovery slot"
  age_by "$rec" 310
  recover_check "$dir"
  [ "$(recover_interrupts "$dir")" = 1 ] && [ "$(recover_wakes "$dir")" = 0 ] \
    || fail "a 310 s record was not recovered once:"$'\n'"$(cat "$dir/control.log" "$dir/state/.wake-queue" 2>/dev/null)"
  pass "watcher: automatic recovery of a spent ladder waits until the record is 300 s old"
}

# The same bound holds for a busy-verified non-Codex secondmate (Claude, Pi or
# Grok) whose busy budget is spent: no interrupt at 120 s, exactly one past
# 300 s.
test_watcher_busy_recovery_waits_for_the_charter_bound() {
  local harness
  for harness in claude pi grok; do
    busy_recovery_bound_case "$harness"
  done
  pass "watcher: automatic recovery of a stuck-busy Claude, Pi or Grok secondmate waits until the record is 300 s old"
}

busy_recovery_bound_case() {  # <harness>
  local dir gen source event
  dir=$(busy_case "busy-bound-$1")
  fm_write_meta "$dir/state/t1.meta" "window=sess:fm-t1" "kind=secondmate" "harness=$1"
  # Claude and Pi report busy through their own trusted semantic source;
  # Grok's busy read is its pane regex.
  case "$1" in
    claude) source=claude-hook event=user-prompt-submit ;;
    pi) source=pi-ext event=agent-start ;;
    *) source='' ;;
  esac
  if [ -n "$source" ]; then
    gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/state" t1) || fail "$1: could not arm the busy record"
    "$ROOT/bin/fm-busy-event.sh" apply "$dir/state" t1 busy --gen "$gen" --source "$source" --event "$event" \
      || fail "$1: could not record a busy turn"
    [ "$(bash -c '. "$1" && fm_busy_classify tmux sess:fm-t1 "$2" t1 "$3"' _ "$ROOT/bin/fm-busy-lib.sh" "$1" "$dir/state")" = "busy $source" ] \
      || fail "$1: the fixture pane is not verified busy"
  fi
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/control.log"\n' "$dir" > "$dir/fakebin/fm-control"
  chmod +x "$dir/fakebin/fm-control"
  : > "$dir/control.log"
  age_by "$dir/state/t1.inbox/001.msg" 120
  FM_CONTROL_BIN="$dir/fakebin/fm-control" busy_steer_check "$dir"
  FM_CONTROL_BIN="$dir/fakebin/fm-control" busy_steer_check "$dir"
  FM_CONTROL_BIN="$dir/fakebin/fm-control" busy_steer_check "$dir"
  [ ! -s "$dir/control.log" ] && [ ! -s "$dir/state/.wake-queue" ] \
    || fail "$1: a stuck-busy secondmate was interrupted or alarmed at 120 s:"$'\n'"$(cat "$dir/control.log" "$dir/state/.wake-queue" 2>/dev/null)"
  [ "$(cut -f2 "$dir/state/t1.inbox/.busy-state" 2>/dev/null)" -ge 2 ] 2>/dev/null \
    || fail "$1: the watcher never counted the pane busy, so the stuck-busy path did not run"
  age_by "$dir/state/t1.inbox/001.msg" 310
  FM_CONTROL_BIN="$dir/fakebin/fm-control" busy_steer_check "$dir"
  [ "$(grep -c '^t1 interrupt$' "$dir/control.log")" = 1 ] || fail "$1: a stuck-busy secondmate past the bound was not interrupted once"
}

# An interrupt that fails or outlives its bound rings nothing: the slot stays
# spent and the same poll raises one alarm naming the failure and its status.
test_watcher_recovery_interrupt_failure_alarms_at_once() {
  local dir rec kind start elapsed
  for kind in exit hang; do
    dir=$(recover_case "recover-ctl-$kind" "kind=secondmate" "harness=codex")
    # The stand-in logs like recover_case's, then fails or hangs.
    if [ "$kind" = exit ]; then
      printf 'exit 1\n' >> "$dir/fakebin/fm-control"
    else
      printf 'sleep 30\nexit 1\n' >> "$dir/fakebin/fm-control"
    fi
    rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "routed ask")
    age_path "$rec"
    start=$(date +%s)
    FM_WATCH_RECOVER_INTERRUPT_SECS=2 recover_check "$dir"
    elapsed=$(( $(date +%s) - start ))
    [ "$elapsed" -le 8 ] || fail "$kind: the recovery interrupt held the poll for ${elapsed}s against a 2 s bound"
    [ "$(recover_interrupts "$dir")" = 1 ] || fail "$kind: the recovery interrupt was not attempted once"
    [ "$(recover_rings "$dir")" = 0 ] || fail "$kind: a failed interrupt was followed by a doorbell:"$'\n'"$(cat "$dir/send.log")"
    grep -c 'steering-inbox recovery interrupt failed' "$dir/state/.wake-queue" 2>/dev/null | grep -qx 1 \
      || fail "$kind: a failed interrupt did not alarm exactly once on the same poll:"$'\n'"$(cat "$dir/state/.wake-queue" 2>/dev/null)"
    [ "$(cat "$dir/state/t1.inbox/.escalated" 2>/dev/null)" = 001.msg ] || fail "$kind: the alarm did not mark the record escalated"
    if [ "$kind" = exit ]; then
      grep -qF 'interrupt exited 1 ' "$dir/state/.wake-queue" || fail "the alarm did not name the interrupt's exit status 1"
    else
      grep -qF 'interrupt exited 124 ' "$dir/state/.wake-queue" || fail "the alarm did not name the timed-out interrupt's status 124"
    fi
    recover_check "$dir"
    [ "$(recover_interrupts "$dir")" = 1 ] && [ "$(grep -c 'recovery interrupt failed' "$dir/state/.wake-queue")" = 1 ] \
      || fail "$kind: the escalated record was interrupted or alarmed again"
  done
  pass "watcher: a failed or timed-out recovery interrupt rings nothing and alarms once at once, within the interrupt bound"
}

# The spent budget comes from the recovery result, not from the slot count in
# the bookkeeping: a second slot whose interrupt failed is not reported as a
# second completed interrupt-and-redirect.
test_watcher_failed_second_recovery_is_not_reported_spent() {
  local dir rec
  dir=$(recover_case recover-second-fails "kind=secondmate" "harness=codex")
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "routed ask")
  age_path "$rec"
  recover_check "$dir"
  [ "$(recover_interrupts "$dir")" = 1 ] && [ "$(recover_rings "$dir")" = 1 ] || fail "the first recovery did not interrupt and ring once"
  printf 'exit 1\n' >> "$dir/fakebin/fm-control"
  recover_check "$dir"
  grep -qF 'steering-inbox recovery interrupt failed' "$dir/state/.wake-queue" 2>/dev/null \
    || fail "the failed second interrupt did not alarm:"$'\n'"$(cat "$dir/state/.wake-queue" 2>/dev/null)"
  ! grep -qF 'automatic recovery already interrupted and redirected it' "$dir/state/.wake-queue" \
    || fail "a failed second interrupt was reported as a completed recovery:"$'\n'"$(cat "$dir/state/.wake-queue")"
  pass "watcher: a failed second recovery interrupt is not reported as a spent interrupt-and-redirect budget"
}

# A redirect doorbell that cannot be typed after a successful interrupt is a
# failed recovery on that same poll: an unrelated composer draft is left alone,
# nothing is typed over it, and one alarm names the doorbell's status instead
# of passing the spent slot off as a delivered redirect.
test_watcher_recovery_doorbell_failure_alarms_at_once() {
  local dir rec draft
  dir=$(recover_case recover-ring-fails "kind=secondmate" "harness=codex")
  draft="$dir/draft.capture"
  printf '╭────────────────────╮\n│ a half-typed draft │\n╰────────────────────╯\n' > "$draft"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "routed ask")
  age_path "$rec"
  RECOVER_CAPTURE=$draft recover_check "$dir"
  [ "$(recover_interrupts "$dir")" = 1 ] || fail "the recovery interrupt was not sent once:"$'\n'"$(cat "$dir/control.log")"
  [ ! -s "$dir/send.log" ] || fail "the doorbell was typed over an unrelated composer draft:"$'\n'"$(cat "$dir/send.log")"
  grep -c 'steering-inbox recovery doorbell failed' "$dir/state/.wake-queue" 2>/dev/null | grep -qx 1 \
    || fail "a failed recovery doorbell did not alarm exactly once on the same poll:"$'\n'"$(cat "$dir/state/.wake-queue" 2>/dev/null)"
  grep -qF 'doorbell exited 1,' "$dir/state/.wake-queue" || fail "the alarm did not name the doorbell's status 1"
  ! grep -qF 'automatic recovery already interrupted and redirected it' "$dir/state/.wake-queue" \
    || fail "a failed doorbell was reported as a completed redirect:"$'\n'"$(cat "$dir/state/.wake-queue")"
  [ "$(cat "$dir/state/t1.inbox/.escalated" 2>/dev/null)" = 001.msg ] || fail "the alarm did not mark the record escalated"
  RECOVER_CAPTURE=$draft recover_check "$dir"
  [ "$(recover_interrupts "$dir")" = 1 ] && [ "$(grep -c 'recovery doorbell failed' "$dir/state/.wake-queue")" = 1 ] \
    || fail "the escalated record was interrupted or alarmed again"
  pass "watcher: a recovery doorbell that cannot be typed after a successful interrupt alarms at once and leaves the composer draft alone"
}

# Claiming a slot and restarting the ladder are one step: when the ladder
# cannot be restarted after the slot would be written, no slot is spent and
# no interrupt is sent, and the alarm names the bookkeeping it could not write.
test_watcher_recovery_ladder_failure_spends_no_slot() {
  local dir rec
  dir=$(recover_case recover-ladder-unwritable "kind=secondmate" "harness=codex" "spawn_gen=g1")
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "routed ask")
  age_path "$rec"
  mkdir "$dir/state/t1.inbox/.ring-state"
  recover_check "$dir"
  [ "$(recover_interrupts "$dir")" = 0 ] || fail "unwritable ladder bookkeeping still interrupted"
  grep -q 'recovery bookkeeping unwritable' "$dir/state/.wake-queue" \
    || fail "unwritable ladder bookkeeping did not surface:"$'\n'"$(cat "$dir/state/.wake-queue" 2>/dev/null)"
  rmdir "$dir/state/t1.inbox/.ring-state"
  [ "$(inbox_lib "$dir/state" fm_task_inbox_recover_next "$dir/state" t1 "$rec" g1)" = 1 ] \
    || fail "a failed ladder restart silently spent a recovery slot"
  grep -qF '.ring-state' "$dir/state/.wake-queue" \
    || fail "the alarm did not name the ladder it could not write:"$'\n'"$(cat "$dir/state/.wake-queue")"
  pass "watcher: a ladder that cannot be restarted spends no recovery slot, sends no interrupt and alarms naming it"
}

# Recovery is chosen from the stuck-busy flag, never by searching the reason
# text, so a busy-bookkeeping failure whose paths contain "stuck-busy" still
# alarms as bookkeeping and interrupts nothing.
test_watcher_busy_bookkeeping_failure_never_recovers() {
  local dir
  dir=$(busy_case busy-stuck-busy-unwritable)
  fm_write_meta "$dir/state/t1.meta" "window=sess:fm-t1" "kind=secondmate" "harness=grok"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/control.log"\n' "$dir" > "$dir/fakebin/fm-control"
  chmod +x "$dir/fakebin/fm-control"
  : > "$dir/control.log"
  mkdir "$dir/state/t1.inbox/.busy-state"
  FM_CONTROL_BIN="$dir/fakebin/fm-control" busy_steer_check "$dir"
  grep -q 'busy bookkeeping unwritable' "$dir/state/.wake-queue" \
    || fail "a busy-bookkeeping failure did not alarm as bookkeeping:"$'\n'"$(cat "$dir/state/.wake-queue" 2>/dev/null)"
  [ ! -s "$dir/control.log" ] || fail "a busy-bookkeeping failure interrupted the secondmate"
  pass "watcher: a busy-bookkeeping failure alarms as bookkeeping and never triggers recovery"
}

# The product ceiling is 300s. It reports once before the recovery ladder and
# leaves the record on that ladder. These cases do not export the fixture opt-out.
test_due_action_age_ceiling_leaves_a_young_record_on_the_ladder() {
  local dir state rec out
  dir=$(setup_watch_case due-young)
  state="$dir/state"
  fm_write_meta "$state/t1.meta" "window=sess:fm-t1" "kind=secondmate" "harness=grok"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "young steer")
  age_by "$rec" 10
  out=$(FM_TASK_INBOX_GRACE_SECS=0 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  case "$out" in
    ring\ *) ;;
    *) fail "a 10s secondmate record left the ring ladder: $out" ;;
  esac

  dir=$(setup_watch_case due-old)
  state="$dir/state"
  fm_write_meta "$state/t1.meta" "window=sess:fm-t1" "kind=secondmate" "harness=grok"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "old steer")
  age_by "$rec" 310
  out=$(FM_TASK_INBOX_GRACE_SECS=0 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  case "$out" in
    escalate-age\ *) ;;
    *) fail "a 310s secondmate record did not hit the age ceiling: $out" ;;
  esac
  inbox_lib "$state" fm_task_inbox_record_age_escalated "$state" t1 "$rec"
  out=$(FM_TASK_INBOX_GRACE_SECS=0 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  case "$out" in
    ring\ *) ;;
    *) fail "a reported aged secondmate record left the ring ladder: $out" ;;
  esac

  dir=$(setup_watch_case due-ship)
  state="$dir/state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "ship steer")
  age_path "$rec"
  out=$(FM_TASK_INBOX_GRACE_SECS=0 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  case "$out" in
    ring\ *) ;;
    *) fail "a non-secondmate record hit the secondmate age ceiling: $out" ;;
  esac
  pass "due action escalates only an aged secondmate record and still rings a younger one"
}

test_secondmate_unread_age_ceiling_reports_once_then_recovers() {
  local dir rec
  dir=$(recover_case age-ceiling "kind=secondmate" "harness=codex" "spawn_gen=g1")
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "unread steer")
  age_by "$rec" 310
  RECOVER_AGE_SECS='' recover_check "$dir"
  grep -q 'reported without another interrupt' "$dir/state/.wake-queue" \
    || fail "an aged unread instruction was not reported without another interrupt:"$'\n'"$(cat "$dir/state/.wake-queue" 2>/dev/null)"
  [ "$(recover_wakes "$dir")" = 1 ] || fail "the age ceiling did not report exactly once:"$'\n'"$(cat "$dir/state/.wake-queue" 2>/dev/null)"
  [ "$(recover_interrupts "$dir")" = 0 ] || fail "the age report interrupted the secondmate:"$'\n'"$(cat "$dir/control.log" 2>/dev/null)"
  RECOVER_AGE_SECS='' recover_check "$dir"
  [ "$(recover_interrupts "$dir")" = 1 ] || fail "automatic recovery did not run after the age report:"$'\n'"$(cat "$dir/control.log" 2>/dev/null)"
  RECOVER_AGE_SECS='' recover_check "$dir"
  [ "$(recover_interrupts "$dir")" = 2 ] || fail "the second automatic recovery did not run after the age report"
  [ "$(recover_wakes "$dir")" = 1 ] || fail "recovery after the age report alarmed early or repeated the age report"
  RECOVER_AGE_SECS='' recover_check "$dir"
  [ "$(recover_interrupts "$dir")" = 2 ] && [ "$(recover_wakes "$dir")" = 2 ] \
    || fail "spent recovery after the age report did not alarm exactly once:"$'\n'"$(cat "$dir/state/.wake-queue" 2>/dev/null)"
  pass "watcher: an unread secondmate instruction past 300s is reported once, then still recovered automatically"
}

test_watcher_busy_secondmate_is_recovered_before_alarm
test_watcher_auto_recovers_a_secondmate_twice_then_alarms_once
test_watcher_recovers_a_record_behind_an_escalated_one
test_watcher_recovery_rings_first_only_for_a_proven_answer
test_watcher_recovery_restarts_the_ladder
test_watcher_recovery_scope_and_generation
test_watcher_recovery_waits_for_the_charter_bound
test_watcher_busy_recovery_waits_for_the_charter_bound
test_watcher_recovery_interrupt_failure_alarms_at_once
test_watcher_failed_second_recovery_is_not_reported_spent
test_watcher_recovery_doorbell_failure_alarms_at_once
test_watcher_recovery_ladder_failure_spends_no_slot
test_watcher_busy_bookkeeping_failure_never_recovers
test_due_action_age_ceiling_leaves_a_young_record_on_the_ladder
test_secondmate_unread_age_ceiling_reports_once_then_recovers
