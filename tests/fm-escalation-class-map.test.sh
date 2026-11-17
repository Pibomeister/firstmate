#!/usr/bin/env bash
# tests/fm-escalation-class-map.test.sh - the escalation class map is one table
# that gives every exception state a single class. The test reads the incident
# keys tables of the four signal PRDs and the states acceptance criterion AC-4
# names, and fails when one of them has no class or more than one. It proves
# the check itself by running it on maps with a row removed and a row repeated,
# and it runs each mapped exception through the gate to see the class it writes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MAP="$ROOT/bin/fm-escalation-class-map.tsv"
GATE="$ROOT/bin/fm-escalate.sh"
PRDS="$ROOT/docs/prd/supervision"
TMP_ROOT=$(fm_test_tmproot fm-escalation-class-map-tests)
tab=$(printf '\t')

# The exception classes of EQ-22 and the classes the class map adds to them.
EQ22_CLASSES="inject-wedged watcher-recovery-failed permission-dialog unconfirmed-restart restart-loop quota-all-at-floor conflicted-pr blocked-decision"

# The class AC-4 names for each state: "signal state class".
AC4_STATES=$(cat <<'EOF'
health-verdict dead health-dead
health-verdict unconfirmed-past-one-pass health-unconfirmed
captain-record none-with-open-work health-dead
watcher-freshness progress-lost-past-two-cycles watcher-recovery-failed
outer-guard-restarts budget-exhausted watcher-recovery-failed
check-watch terminal-failure check-failed
check-watch ambiguous-identity check-ambiguous
conflict-state conflicted conflicted-pr
ready-run orphan-past-bound orphan-ready-run
quota-floor all-candidates-at-floor quota-all-at-floor
move recheck-failed move-failed
move worker-killed-during-relaunch move-failed
move budget-exhausted move-budget-exhausted
primary-at-floor at-floor-past-one-pass quota-limited-primary
move held-captain-approval blocked-decision
move candidate-source-unclear blocked-decision
stall-detection second-detection stall-detected
stall-detection restart-failed unconfirmed-restart
successor-lifecycle pickup-failed unconfirmed-restart
successor-lifecycle wait-expired unconfirmed-restart
successor-lifecycle exited-before-recheck unconfirmed-restart
successor-lifecycle no-ender unconfirmed-restart
successor-lifecycle primary-successor-failed unconfirmed-restart
input-swallowed bound-expired-twice input-swallowed
startup-budget over-budget startup-over-budget
restart-budget refused-over-budget restart-loop
health-owner watchdog-absent watchdog-absent
wedge-alarm inject-wedged inject-wedged
permission-dialog waiting permission-dialog
away-decision waiting blocked-decision
usage-threshold crossed usage-threshold
EOF
)

# norm <text>: a PRD state or signal name as the map spells it.
norm() {
  printf '%s' "$1" | tr -d '`' | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]][[:space:]]*/-/g'
}

# prd_states <column>: "signal state" for each state in that column (3 exception, 4 routine)
# of the incident keys table of every signal PRD.
prd_states() {
  local col=$1 prd line sig cell state
  for prd in heartbeat-health stall-context-recovery quota-account-routing pr-check-monitoring; do
    while IFS= read -r line; do
      sig=$(norm "$(printf '%s' "$line" | awk -F '|' '{ print $2 }')")
      cell=$(printf '%s' "$line" | awk -F '|' -v c="$((col + 1))" '{ print $c }')
      while IFS= read -r state; do
        [ -n "$state" ] || continue
        printf '%s %s\n' "$sig" "$(norm "$state")"
      done < <(printf '%s\n' "$cell" | tr ',' '\n')
    done < <(awk '/^## Incident keys/ { t = 1; next } /^## / { t = 0 } t && /^\|/ && !/^\| ---/ && !/^\| Signal/' "$PRDS/$prd.md")
  done
}

# class_rows <map> <signal> <state>: the classes the map gives that state, one per line.
class_rows() {
  awk -F '\t' -v sig="$2" -v st="$3" '$1 !~ /^#/ && NF >= 3 && $1 == sig && $2 == st { print $3 }' "$1"
}

is_exception_class() {
  case "$1" in routine|closure|'') return 1 ;; *) return 0 ;; esac
}

# check_map <map>: print one line per defect; print nothing for a sound map.
check_map() {
  local map=$1 sig state want got n
  while read -r sig state; do
    n=$(class_rows "$map" "$sig" "$state" | wc -l | tr -d ' ')
    got=$(class_rows "$map" "$sig" "$state" | head -n 1)
    if [ "$n" -ne 1 ]; then
      printf 'PRD exception %s %s has %s classes\n' "$sig" "$state" "$n"
    elif ! is_exception_class "$got"; then
      printf 'PRD exception %s %s maps to %s\n' "$sig" "$state" "$got"
    fi
  done < <(prd_states 3)
  while read -r sig state want; do
    n=$(class_rows "$map" "$sig" "$state" | wc -l | tr -d ' ')
    got=$(class_rows "$map" "$sig" "$state" | head -n 1)
    if [ "$n" -ne 1 ]; then
      printf 'AC-4 state %s %s has %s classes\n' "$sig" "$state" "$n"
    elif [ "$got" != "$want" ]; then
      printf 'AC-4 state %s %s maps to %s, wanted %s\n' "$sig" "$state" "$got" "$want"
    fi
  done <<< "$AC4_STATES"
  # No state appears twice, with the same class or another.
  awk -F '\t' '$1 !~ /^#/ && NF >= 3 { if (seen[$1 FS $2]++) print "duplicate row " $1 " " $2 }' "$map"
  # Every row has three columns.
  awk -F '\t' '$1 !~ /^#/ && $0 != "" && (NF != 3 || $1 == "" || $2 == "" || $3 == "") { print "malformed row " NR }' "$map"
}

test_the_prd_tables_are_parsed() {
  local exc routine
  exc=$(prd_states 3 | wc -l | tr -d ' ')
  routine=$(prd_states 4 | wc -l | tr -d ' ')
  # Heartbeat 5, stall 6, quota 4 and pr-check 4 exception states.
  assert_equals 19 "$exc" "the four PRDs list nineteen exception states"
  [ "$routine" -ge 15 ] || fail "the four PRDs list their routine states (got $routine)"
  assert_contains "$(prd_states 3)" "health-verdict unconfirmed-past-one-pass" "a multi-word state is normalized"
  assert_contains "$(prd_states 3)" "captain-record none-with-open-work" "a quoted state with words is normalized"
  assert_contains "$(prd_states 3)" "conflict-state conflicted" "a quoted single word is normalized"
  pass "the incident keys tables of the four PRDs are parsed"
}

test_every_exception_state_has_exactly_one_class() {
  local out
  out=$(check_map "$MAP")
  [ -z "$out" ] || fail "the class map has defects: $out"
  pass "every PRD exception state and every AC-4 state maps to exactly one class"
}

test_the_check_fails_on_a_missing_or_repeated_class() {
  local m out
  m="$TMP_ROOT/missing.tsv"
  grep -v "^conflict-state${tab}conflicted${tab}" "$MAP" > "$m"
  out=$(check_map "$m")
  assert_contains "$out" "conflict-state conflicted has 0 classes" "a state with no class is reported"
  m="$TMP_ROOT/repeated.tsv"
  { cat "$MAP"; printf 'move\trecheck-failed\tblocked-decision\n'; } > "$m"
  out=$(check_map "$m")
  assert_contains "$out" "move recheck-failed has 2 classes" "a state with two classes is reported"
  m="$TMP_ROOT/routine.tsv"
  sed "s/^ready-run${tab}orphan-past-bound${tab}.*/ready-run${tab}orphan-past-bound${tab}routine/" "$MAP" > "$m"
  out=$(check_map "$m")
  assert_contains "$out" "ready-run orphan-past-bound maps to routine" "an exception mapped to routine is reported"
  pass "the check fails when a state has no class or more than one"
}

test_the_eq22_classes_and_the_routine_vocabulary() {
  local class
  for class in $EQ22_CLASSES; do
    [ -n "$(awk -F '\t' -v c="$class" '$1 !~ /^#/ && $3 == c { print; exit }' "$MAP")" ] || fail "the map holds no row of class $class"
  done
  assert_equals routine "$(class_rows "$MAP" handoff-interval context-churn)" "context-churn is routine"
  assert_equals routine "$(class_rows "$MAP" health-verdict ok)" "ok is routine"
  assert_equals routine "$(class_rows "$MAP" check-watch head-changed)" "head-changed is routine"
  assert_equals closure "$(class_rows "$MAP" move cleared)" "cleared is closure for the move signal"
  local sig
  while IFS= read -r sig; do
    assert_equals closure "$(class_rows "$MAP" "$sig" cleared)" "cleared is closure for $sig"
  done < <(awk -F '\t' '$1 !~ /^#/ && NF >= 3 { print $1 }' "$MAP" | sort -u)
  pass "the map holds the eight EQ-22 classes and the routine vocabulary, and cleared closes every signal"
}

test_the_gate_writes_the_mapped_class() {
  local h sig state class n=0 want got out
  h="$TMP_ROOT/gate-home"
  mkdir -p "$h/state"
  while IFS="$tab" read -r sig state class; do
    case "$sig" in '#'*|'') continue ;; esac
    is_exception_class "$class" || continue
    n=$((n + 1))
    out=$(env -u FM_STATE_OVERRIDE FM_HOME="$h" FM_TEST_SEAM=1 FM_NOW=1800000000 FM_ESCALATE_DELIVER=true \
      bash "$GATE" report --subject "subject-$n" --signal "$sig" --state "$state" < /dev/null) || fail "the gate failed on $sig $state"
    assert_contains "$out" "action=escalate" "$sig $state escalates"
    got=$(sed -n "${n}p" "$h/state/incident-ledger.tsv" | cut -f7)
    want=$class
    assert_equals "$want" "$got" "the gate writes the mapped class for $sig $state"
  done < "$MAP"
  [ "$n" -ge 30 ] || fail "the gate ran too few exceptions ($n)"
  pass "the gate escalates every mapped exception under its mapped class"
}

test_a_routine_state_never_escalates() {
  local h sig state class n=0 out
  h="$TMP_ROOT/routine-home"
  mkdir -p "$h/state"
  while IFS="$tab" read -r sig state class; do
    case "$sig" in '#'*|'') continue ;; esac
    is_exception_class "$class" && continue
    n=$((n + 1))
    out=$(env -u FM_STATE_OVERRIDE FM_HOME="$h" FM_TEST_SEAM=1 FM_NOW=1800000000 FM_ESCALATE_DELIVER=true \
      bash "$GATE" report --subject "subject-$n" --signal "$sig" --state "$state" < /dev/null) || fail "the gate failed on $sig $state"
    assert_contains "$out" "action=record" "$sig $state is recorded"
    assert_contains "$out" "send=none" "$sig $state sends nothing"
  done < "$MAP"
  [ "$n" -ge 30 ] || fail "the gate ran too few routine states ($n)"
  pass "no routine state escalates or sends"
}

fm_test_run \
  test_the_prd_tables_are_parsed \
  test_every_exception_state_has_exactly_one_class \
  test_the_check_fails_on_a_missing_or_repeated_class \
  test_the_eq22_classes_and_the_routine_vocabulary \
  test_the_gate_writes_the_mapped_class \
  test_a_routine_state_never_escalates
