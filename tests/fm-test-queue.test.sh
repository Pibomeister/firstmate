#!/usr/bin/env bash
# Behavior tests for bin/fm-test-queue.sh, the machine-wide line for heavy test
# runs. Every case drives the real script through its public run and status
# commands against a private spool, with the load average supplied through the
# FM_TEST_QUEUE_LOAD_FILE seam so the host's real load never decides a verdict.
# FM_TEST_BASH selects the interpreter (stock macOS /bin/bash 3.2 included).
# Literal sh -c programs read their positional arguments, not this shell's.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-test-queue)
QUEUE="$ROOT/bin/fm-test-queue.sh"
QBASH=${FM_TEST_BASH:-bash}
CASE_PIDS=()

reap_case_pids() {
  local p
  for p in "${CASE_PIDS[@]:-}"; do
    [ -n "$p" ] && kill -KILL "$p" 2>/dev/null
  done
  CASE_PIDS=()
}
trap 'reap_case_pids; fm_test_cleanup' EXIT

# new_case <name>: a private spool, no config file, load 1, fast polling.
new_case() {
  CASE="$TMP_ROOT/$1"
  mkdir -p "$CASE"
  echo 1 > "$CASE/load"
  export FM_TEST_QUEUE_DIR="$CASE/spool"
  export FM_TEST_QUEUE_CONFIG="$CASE/test-queue.conf"
  export FM_TEST_QUEUE_LOAD_FILE="$CASE/load"
  export FM_TEST_QUEUE_POLL=0.1
  export FM_TEST_SEAM=1
  unset FM_TEST_QUEUE_SLOTS FM_TEST_QUEUE_LOAD_CEILING FM_TEST_QUEUE_HELD
}

q() { "$QBASH" "$QUEUE" "$@"; }
# qbg: only ever run with `&`; exec makes $! the queue process itself, so a
# signal the test sends reaches the queue rather than a wrapping subshell.
qbg() { exec "$QBASH" "$QUEUE" "$@"; }

# wait_until <description> <command...>: poll up to 15 seconds.
wait_until() {
  local what=$1 i=0
  shift
  while ! "$@"; do
    i=$((i + 1))
    [ "$i" -lt 150 ] || fail "timed out waiting for: $what"$'\n'"$(q status 2>&1)"
    sleep 0.1
  done
}

status_has() { q status 2>/dev/null | grep -Eq -- "$1"; }
file_exists() { [ -e "$1" ]; }

# A held run: blocks until its release file appears, then logs its name.
start_held() {  # <name> -> sets HELD_PID
  qbg run --label "$1" -- sh -c 'while [ ! -e "$1/release-$2" ]; do sleep 0.05; done; echo "$2" >> "$1/order"' _ "$CASE" "$1" \
    2>>"$CASE/stderr" &
  HELD_PID=$!
  CASE_PIDS+=("$HELD_PID")
}

release() { : > "$CASE/release-$1"; }

line_is_empty() {
  status_has '^test-queue: .* serving=0 waiting=0 '
}

test_help_and_usage() {
  local out rc
  new_case usage
  out=$(q --help); rc=$?
  expect_code 0 "$rc" "--help"
  assert_contains "$out" "fm-test-queue.sh run [--label <text>] -- <command>" "help omitted the run usage"
  assert_contains "$out" "Exit status:" "help omitted the exit-status contract"
  for args in "" "bogus" "run" "run --" "run sleep 1" "status extra"; do
    # shellcheck disable=SC2086 # Word splitting builds the argument vector.
    q $args >/dev/null 2>&1; rc=$?
    expect_code 2 "$rc" "usage error for '$args'"
  done
  pass "fm-test-queue.sh: help prints the header and malformed calls are usage errors"
}

test_run_passes_status_and_output_through() {
  local out rc
  new_case passthrough
  out=$(q run -- sh -c 'echo from-command; exit 7' 2>/dev/null); rc=$?
  expect_code 7 "$rc" "run must return the command's exit status"
  assert_equals "from-command" "$out" "run must pass the command's stdout through"
  out=$(echo piped | q run -- cat 2>/dev/null); rc=$?
  expect_code 0 "$rc" "a successful command"
  assert_equals "piped" "$out" "run must give the command the caller's stdin"
  line_is_empty || fail "a finished run left its ticket in the line"
  pass "fm-test-queue.sh: run returns the command's status, keeps its stdio, and leaves"
}

test_line_is_first_in_first_out() {
  local a b c d
  new_case fifo
  export FM_TEST_QUEUE_SLOTS=1
  start_held A; a=$HELD_PID
  wait_until "A served" status_has '^serving .*label=A$'
  start_held B; b=$HELD_PID
  wait_until "B waiting" status_has '^waiting position=1 .*label=B$'
  start_held C; c=$HELD_PID
  wait_until "C waiting" status_has '^waiting position=2 .*label=C$'
  start_held D; d=$HELD_PID
  wait_until "D waiting" status_has '^waiting position=3 .*label=D$'
  # Release out of order: the line, not the release order, decides who runs.
  release D; release C; release B
  sleep 0.5
  status_has '^serving .*label=A$' || fail "A lost its slot while still running"
  release A
  wait "$a" "$b" "$c" "$d"
  assert_equals "A B C D" "$(tr '\n' ' ' < "$CASE/order" | sed 's/ $//')" "runs were not served in ticket order"
  grep -Fq "all 1 slot(s) busy" "$CASE/stderr" || fail "the head of the line did not say it waits for a slot"
  grep -Fq "waiting behind 1 earlier ticket(s)" "$CASE/stderr" || fail "a waiting run did not report the line ahead of it"
  line_is_empty || fail "the line is not empty after every run left"
  pass "fm-test-queue.sh: runs are served one at a time in ticket order"
}

test_slots_bound_concurrency() {
  local p1 p2 p3
  new_case slots
  export FM_TEST_QUEUE_SLOTS=2
  start_held one; p1=$HELD_PID
  start_held two; p2=$HELD_PID
  wait_until "two served" status_has ' serving=2 waiting=0 '
  start_held three; p3=$HELD_PID
  wait_until "third waits" status_has ' serving=2 waiting=1 '
  sleep 0.5
  status_has ' serving=2 waiting=1 ' || fail "a third run was served beyond two slots"
  release one
  wait_until "third served" status_has '^serving .*label=three$'
  release two; release three
  wait "$p1" "$p2" "$p3"
  pass "fm-test-queue.sh: no more runs are served at once than there are slots"
}

test_load_ceiling_holds_the_head() {
  local p rc
  new_case load
  echo 20.5 > "$CASE/load"
  qbg run -- sh -c 'echo ran > "$1/ran"' _ "$CASE" 2>"$CASE/stderr" &
  p=$!
  CASE_PIDS+=("$p")
  wait_until "load wait reported" grep -Fq "load 20.5 is not below 16" "$CASE/stderr"
  status_has '^waiting position=1 ' || fail "a run under high load is not shown waiting"
  assert_absent "$CASE/ran" "a run started while the load was above the ceiling"
  echo 15.9 > "$CASE/load"
  wait "$p"; rc=$?
  expect_code 0 "$rc" "the run once the load fell"
  assert_present "$CASE/ran" "the run never started after the load fell below the ceiling"
  pass "fm-test-queue.sh: the head of the line waits until the load is below the ceiling"
}

test_signals_release_the_ticket() {
  local p rc
  new_case signals
  export FM_TEST_QUEUE_SLOTS=1
  start_held holder
  wait_until "holder served" status_has '^serving .*label=holder$'
  qbg run --label waiter -- true 2>/dev/null &
  p=$!
  wait_until "waiter waiting" status_has '^waiting .*label=waiter$'
  kill -TERM "$p"
  wait "$p"; rc=$?
  expect_code 143 "$rc" "a waiting run ended by TERM"
  status_has ' waiting=0 ' || fail "a run ended by TERM while waiting left its ticket"
  release holder
  wait_until "holder left" line_is_empty

  q run -- sh -c 'kill -TERM $$' 2>/dev/null; rc=$?
  expect_code 143 "$rc" "a command ended by TERM"
  line_is_empty || fail "a command ended by a signal left its slot taken"

  # A signal that reaches only the queue while the command runs takes effect
  # when the command exits, and the slot is still released.
  start_held running; p=$HELD_PID
  wait_until "running served" status_has '^serving .*label=running$'
  kill -TERM "$p"
  sleep 0.3
  status_has '^serving .*label=running$' || fail "the slot was released while its command still ran"
  release running
  wait "$p"; rc=$?
  expect_code 143 "$rc" "a served run whose queue process got TERM"
  line_is_empty || fail "a served run ended by TERM left its slot taken"
  pass "fm-test-queue.sh: a signal releases the ticket and the slot"
}

test_dead_owners_are_reclaimed() {
  local p rc
  new_case dead
  export FM_TEST_QUEUE_SLOTS=1
  # A served owner killed outright.
  qbg run --label crashed -- sh -c 'echo $$ > "$1/child"; exec sleep 30' _ "$CASE" 2>/dev/null &
  p=$!
  CASE_PIDS+=("$p")
  wait_until "crashed served" status_has '^serving .*label=crashed$'
  wait_until "crashed command started" file_exists "$CASE/child"
  CASE_PIDS+=("$(cat "$CASE/child")")
  kill -KILL "$p"; wait "$p" 2>/dev/null
  wait_until "stale counted" status_has ' serving=0 waiting=0 stale=1 '
  # A waiting owner killed outright, behind a live holder.
  start_held holder
  wait_until "holder served" status_has '^serving .*label=holder$'
  qbg run --label ghost -- true 2>/dev/null &
  p=$!
  CASE_PIDS+=("$p")
  wait_until "ghost waiting" status_has '^waiting position=1 .*label=ghost$'
  kill -KILL "$p"; wait "$p" 2>/dev/null
  release holder
  q run --label after -- sh -c 'echo after > "$1/after"' _ "$CASE" 2>/dev/null; rc=$?
  expect_code 0 "$rc" "a run behind dead tickets"
  assert_present "$CASE/after" "a dead owner blocked the line"
  status_has ' stale=0 ' || fail "dead tickets were not reclaimed"
  pass "fm-test-queue.sh: tickets and slots of dead owners are reclaimed"
}

test_stale_lock_is_broken() {
  local dead rc
  new_case lock
  mkdir -p "$FM_TEST_QUEUE_DIR/lock"
  sh -c 'exit 0' & dead=$!
  wait "$dead"
  printf '%s %s\n' "$dead" "Thu Jan  1 00:00:00 1970" > "$FM_TEST_QUEUE_DIR/lock/owner"
  q run -- true 2>/dev/null; rc=$?
  expect_code 0 "$rc" "a run past a dead holder's lock"
  # An ownerless lock from a holder that died before writing its owner.
  mkdir -p "$FM_TEST_QUEUE_DIR/lock"
  touch -t 200001010000 "$FM_TEST_QUEUE_DIR/lock"
  q run -- true 2>/dev/null; rc=$?
  expect_code 0 "$rc" "a run past an old ownerless lock"
  assert_absent "$FM_TEST_QUEUE_DIR/lock" "the lock was left behind after the runs"
  pass "fm-test-queue.sh: a lock left by a dead process is broken"
}

test_configuration_precedence_and_validation() {
  local out rc
  new_case config
  out=$(q status); rc=$?
  expect_code 0 "$rc" "status on an empty spool"
  assert_contains "$out" "test-queue: slots=2 load_ceiling=16 load1=1 serving=0 waiting=0 stale=0 spool=$FM_TEST_QUEUE_DIR" \
    "status did not report the defaults"
  printf '# machine settings\nslots = 3\n\nload_ceiling=8.5\n' > "$FM_TEST_QUEUE_CONFIG"
  assert_contains "$(q status)" "slots=3 load_ceiling=8.5 " "status did not read the config file"
  assert_contains "$(FM_TEST_QUEUE_SLOTS=4 FM_TEST_QUEUE_LOAD_CEILING=12 q status)" "slots=4 load_ceiling=12 " \
    "environment did not override the config file"
  for bad in "slots=0" "slots=two" "load_ceiling=-1" "load_ceiling=" "colour=blue" "slots"; do
    printf '%s\n' "$bad" > "$FM_TEST_QUEUE_CONFIG"
    q run -- sh -c ': > "$1/ran"' _ "$CASE" 2>"$CASE/err"; rc=$?
    expect_code 125 "$rc" "run with config '$bad'"
    assert_absent "$CASE/ran" "run executed its command under invalid config '$bad'"
    [ -s "$CASE/err" ] || fail "invalid config '$bad' was not reported"
    q status >/dev/null 2>&1; rc=$?
    expect_code 125 "$rc" "status with config '$bad'"
  done
  rm -f "$FM_TEST_QUEUE_CONFIG"
  FM_TEST_QUEUE_SLOTS=1.5 q run -- true 2>/dev/null; rc=$?
  expect_code 125 "$rc" "a fractional slot count from the environment"
  FM_TEST_QUEUE_DIR=/dev/null/spool q run -- sh -c ': > "$1/ran"' _ "$CASE" 2>/dev/null; rc=$?
  expect_code 125 "$rc" "a spool that cannot be created"
  assert_absent "$CASE/ran" "run executed its command without a spool"
  pass "fm-test-queue.sh: environment beats the config file beats the defaults, and bad values stop the run"
}

test_nested_run_does_not_wait_on_itself() {
  local out rc
  new_case nested
  export FM_TEST_QUEUE_SLOTS=1
  out=$(q run -- "$QBASH" "$QUEUE" run -- sh -c 'echo inner; exit 3' 2>/dev/null); rc=$?
  expect_code 3 "$rc" "a nested run inside the only slot"
  assert_equals "inner" "$out" "the nested command did not run"
  line_is_empty || fail "a nested run left a ticket behind"
  pass "fm-test-queue.sh: a run nested inside a served run does not take a second ticket"
}

test_lost_counter_cannot_jump_the_line() {
  local holder later rc
  new_case counter
  export FM_TEST_QUEUE_SLOTS=1
  start_held first; holder=$HELD_PID
  wait_until "first served" status_has '^serving .*label=first$'
  start_held second; later=$HELD_PID
  wait_until "second waiting" status_has '^waiting position=1 .*label=second$'
  rm -f "$FM_TEST_QUEUE_DIR/next"
  qbg run --label third -- sh -c 'echo third >> "$1/order"' _ "$CASE" 2>/dev/null &
  rc=$!
  CASE_PIDS+=("$rc")
  wait_until "third waiting" status_has '^waiting position=2 .*label=third$'
  release first; release second
  wait "$holder" "$later" "$rc"
  assert_equals "first second third" "$(tr '\n' ' ' < "$CASE/order" | sed 's/ $//')" "a ticket taken after the counter was lost jumped the line"
  pass "fm-test-queue.sh: a lost ticket counter never lets a new run jump the line"
}

test_help_and_usage
test_run_passes_status_and_output_through
test_line_is_first_in_first_out
test_slots_bound_concurrency
test_load_ceiling_holds_the_head
test_signals_release_the_ticket
test_dead_owners_are_reclaimed
test_stale_lock_is_broken
test_configuration_precedence_and_validation
test_nested_run_does_not_wait_on_itself
test_lost_counter_cannot_jump_the_line
