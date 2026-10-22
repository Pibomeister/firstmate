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
CASE_RELEASES=()

reap_case_pids() {
  local p
  for p in "${CASE_RELEASES[@]:-}"; do
    [ -n "$p" ] && : > "$p"
  done
  for p in "${CASE_PIDS[@]:-}"; do
    [ -n "$p" ] && kill -KILL -- "$p" 2>/dev/null
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
  mkdir -p "$FM_TEST_QUEUE_DIR"
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
  CASE_RELEASES+=("$CASE/release-$1")
  qbg run --label "$1" -- sh -c ': > "$1/started-$2"; while [ ! -e "$1/release-$2" ]; do sleep 0.05; done; echo "$2" >> "$1/order"' _ "$CASE" "$1" \
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
  echo slots=1 > "$FM_TEST_QUEUE_DIR/config"
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
  echo slots=2 > "$FM_TEST_QUEUE_DIR/config"
  start_held one; p1=$HELD_PID
  start_held two; p2=$HELD_PID
  wait_until "two served" status_has ' serving=2 waiting=0 '
  FM_TEST_QUEUE_SLOTS=9 FM_TEST_QUEUE_LOAD_CEILING=100 start_held three; p3=$HELD_PID
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
  echo slots=1 > "$FM_TEST_QUEUE_DIR/config"
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
  q run -- sh -c 'kill -INT $$' 2>/dev/null; rc=$?
  expect_code 130 "$rc" "a command ended by INT"
  line_is_empty || fail "a command ended by INT left its slot taken"

  # A signal that reaches only the queue while the command runs takes effect
  # when the command exits, and the slot is still released.
  start_held running; p=$HELD_PID
  wait_until "running served" status_has '^serving .*label=running$'
  wait_until "running workload started" file_exists "$CASE/started-running"
  kill -TERM "$p"
  sleep 0.3
  process_state_has "$p" '^[[:space:]]*[RS]' || fail "TERM returned before the workload terminated"
  status_has '^serving .*label=running$' || fail "the slot was released while its command still ran"
  release running
  wait "$p"; rc=$?
  expect_code 143 "$rc" "a served run whose queue process got TERM"
  line_is_empty || fail "a served run ended by TERM left its slot taken"
  pass "fm-test-queue.sh: a signal releases the ticket and the slot"
}

process_state_has() {
  ps -p "$1" -o stat= 2>/dev/null | grep -Eq -- "$2"
}

test_stopped_workloads_suspend_and_resume_the_wrapper() {
  local wrapper child follower sig rc out
  new_case stop-resume
  echo slots=1 > "$FM_TEST_QUEUE_DIR/config"
  CASE_RELEASES+=("$CASE/release-workload")
  qbg run --label stoppable -- sh -c 'echo $$ > "$1/child"; while [ ! -e "$1/release-workload" ]; do sleep 0.05; done; exit 23' _ "$CASE" 2>"$CASE/stderr" &
  wrapper=$!
  CASE_PIDS+=("$wrapper")
  wait_until "stoppable workload started" file_exists "$CASE/child"
  child=$(cat "$CASE/child")
  CASE_PIDS+=("-$child")
  for sig in TSTP STOP; do
    kill -"$sig" -- "-$child"
    wait_until "wrapper suspended after $sig" process_state_has "$wrapper" '^[[:space:]]*T'
    process_state_has "$child" '^[[:space:]]*T' || fail "the workload did not remain stopped"
    status_has '^serving .*label=stoppable$' || fail "a stopped workload lost its slot"
    if [ "$sig" = TSTP ]; then
      start_held follower; follower=$HELD_PID
      wait_until "follower waits behind stopped workload" status_has '^waiting .*label=follower$'
    fi
    if [ "$sig" = STOP ]; then kill -CONT -- "-$child"; fi
    kill -CONT "$wrapper"
    wait_until "workload resumed after $sig" process_state_has "$child" '^[[:space:]]*[RS]'
    sleep 0.2
    process_state_has "$wrapper" '^[[:space:]]*[RS]' || fail "the wrapper returned before workload termination"
    status_has '^waiting .*label=follower$' || fail "continuation released the workload's slot"
  done
  : > "$CASE/release-workload"
  wait "$wrapper"; rc=$?
  expect_code 23 "$rc" "a workload after repeated stop and continue"
  wait_until "follower served after workload termination" status_has '^serving .*label=follower$'
  release follower
  wait "$follower"
  line_is_empty || fail "a stopped and resumed workload left a ticket behind"
  q run -- sh -c 'exit 148' 2>/dev/null; rc=$?
  expect_code 148 "$rc" "a normal exit resembling a stopped wait status"
  line_is_empty || fail "a normal exit resembling a stop left a ticket behind"
  out=$(HISTFILE="$CASE/disabled-history" q run -- sh -c 'printf "%s" "$HISTFILE"' 2>/dev/null)
  assert_equals "$CASE/disabled-history" "$out" "job-control initialization changed the command's history environment"
  assert_absent "$CASE/disabled-history" "job-control initialization wrote shell history"
  out=$(unset HISTFILE; q run -- sh -c 'printf "%s" "${HISTFILE-unset}"' 2>/dev/null)
  assert_equals unset "$out" "job-control initialization added HISTFILE to the command's environment"
  pass "fm-test-queue.sh: stopped workloads suspend their wrapper and resume until real termination"
}

test_dead_owners_are_reclaimed() {
  local p rc child holder
  new_case dead
  echo slots=1 > "$FM_TEST_QUEUE_DIR/config"
  qbg run --label crashed -- sh -c 'echo $$ > "$1/child"; while [ ! -e "$1/release-crashed" ]; do sleep 0.05; done' _ "$CASE" 2>/dev/null &
  p=$!
  CASE_PIDS+=("$p")
  wait_until "crashed command started" file_exists "$CASE/child"
  child=$(cat "$CASE/child")
  CASE_PIDS+=("$child")
  assert_equals "$child" "$(ps -p "$child" -o pgid= | tr -d ' ')" "command did not get its own process group"
  assert_grep "pgid=$child" "$FM_TEST_QUEUE_DIR/tickets/0000000001" "ticket did not persist its command group"
  kill -KILL "$p"; wait "$p" 2>/dev/null
  status_has ' serving=1 waiting=0 stale=0 ' || fail "a surviving workload lost its slot"
  mkdir -p "$CASE/fakebin"
  export REAL_PS
  REAL_PS=$(command -v ps)
  cat > "$CASE/fakebin/ps" <<'SH'
#!/bin/bash
[ "$*" != '-axo pgid=,stat=' ] || exit 1
exec "$REAL_PS" "$@"
SH
  chmod +x "$CASE/fakebin/ps"
  PATH="$CASE/fakebin:$PATH" status_has ' serving=1 waiting=0 stale=0 ' || fail "a failed ps probe discarded a live group"
  start_held holder; holder=$HELD_PID
  wait_until "holder waits for survivor" status_has '^waiting position=1 .*label=holder$'
  sleep 0.3
  status_has '^serving .*label=crashed$' || fail "a live group was reclaimed"
  release crashed
  wait_until "holder served after survivor left" status_has '^serving .*label=holder$'
  qbg run --label ghost -- true 2>/dev/null &
  p=$!
  CASE_PIDS+=("$p")
  wait_until "ghost waiting" status_has '^waiting position=1 .*label=ghost$'
  kill -KILL "$p"; wait "$p" 2>/dev/null
  release holder
  wait "$holder"
  q run --label after -- sh -c 'echo after > "$1/after"' _ "$CASE" 2>/dev/null; rc=$?
  expect_code 0 "$rc" "a run behind dead tickets"
  assert_present "$CASE/after" "a dead owner blocked the line"
  status_has ' stale=0 ' || fail "dead tickets were not reclaimed"
  pass "fm-test-queue.sh: surviving groups keep slots and abandoned tickets are reclaimed"
}

test_descendants_keep_the_slot_after_the_command_exits() {
  local follower child
  new_case descendants
  echo slots=1 > "$FM_TEST_QUEUE_DIR/config"
  cat > "$CASE/child.sh" <<'SH'
echo $$ > "$1/descendant"
while [ ! -e "$1/release-child" ]; do sleep 0.05; done
SH
  CASE_RELEASES+=("$CASE/release-child")
  q run --label parent -- sh -c 'sh "$1/child.sh" "$1" & while [ ! -s "$1/descendant" ]; do sleep 0.05; done' _ "$CASE" 2>/dev/null
  wait_until "descendant started" file_exists "$CASE/descendant"
  child=$(cat "$CASE/descendant")
  CASE_PIDS+=("$child")
  status_has '^serving .*label=parent$' || fail "a command's surviving descendant lost its slot"
  start_held follower; follower=$HELD_PID
  wait_until "follower waiting for descendant" status_has '^waiting .*label=follower$'
  release child
  wait_until "follower served" status_has '^serving .*label=follower$'
  release follower
  wait "$follower"
  pass "fm-test-queue.sh: group descendants keep the slot after their leader exits"
}

test_stale_lock_is_broken() {
  local dead rc record p
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
  mkdir -p "$FM_TEST_QUEUE_DIR/lock"
  : > "$FM_TEST_QUEUE_DIR/lock/owner"
  qbg run -- true 2>/dev/null & p=$!
  CASE_PIDS+=("$p")
  sleep 0.3
  assert_absent "$FM_TEST_QUEUE_DIR/tickets/0000000003" "a fresh uninitialized lock bypassed its grace period"
  touch -t 200001010000 "$FM_TEST_QUEUE_DIR/lock"
  wait "$p"; rc=$?
  expect_code 0 "$rc" "a run past an initialized lock's grace period"
  for record in empty malformed unreadable; do
    mkdir -p "$FM_TEST_QUEUE_DIR/lock"
    case "$record" in
      empty) : > "$FM_TEST_QUEUE_DIR/lock/owner" ;;
      malformed) echo broken > "$FM_TEST_QUEUE_DIR/lock/owner" ;;
      unreadable) ln -s "$CASE/missing-owner" "$FM_TEST_QUEUE_DIR/lock/owner" ;;
    esac
    touch -t 200001010000 "$FM_TEST_QUEUE_DIR/lock"
    q run -- true 2>/dev/null; rc=$?
    expect_code 0 "$rc" "a run past an old $record owner record"
  done
  assert_absent "$FM_TEST_QUEUE_DIR/lock" "the lock was left behind after the runs"
  pass "fm-test-queue.sh: a lock left by a dead process is broken"
}

test_shared_configuration_and_validation() {
  local out rc
  new_case config
  out=$(q status); rc=$?
  expect_code 0 "$rc" "status on an empty spool"
  assert_contains "$out" "test-queue: slots=2 load_ceiling=16 load1=1 serving=0 waiting=0 stale=0 spool=$FM_TEST_QUEUE_DIR" \
    "status did not report the defaults"
  printf '# machine settings\nslots = 3\n\nload_ceiling=8.5\n' > "$FM_TEST_QUEUE_DIR/config"
  assert_contains "$(q status)" "slots=3 load_ceiling=8.5 " "status did not read the config file"
  echo slots=9 > "$CASE/other-config"
  assert_contains "$(FM_TEST_QUEUE_SLOTS=4 FM_TEST_QUEUE_LOAD_CEILING=12 FM_TEST_QUEUE_CONFIG="$CASE/other-config" q status)" "slots=3 load_ceiling=8.5 " \
    "a per-process setting overrode the shared config file"
  for bad in "slots=0" "slots=two" "load_ceiling=-1" "load_ceiling=" "colour=blue" "slots"; do
    printf '%s\n' "$bad" > "$FM_TEST_QUEUE_DIR/config"
    q run -- sh -c ': > "$1/ran"' _ "$CASE" 2>"$CASE/err"; rc=$?
    expect_code 125 "$rc" "run with config '$bad'"
    assert_absent "$CASE/ran" "run executed its command under invalid config '$bad'"
    [ -s "$CASE/err" ] || fail "invalid config '$bad' was not reported"
    q status >/dev/null 2>&1; rc=$?
    expect_code 125 "$rc" "status with config '$bad'"
  done
  rm -f "$FM_TEST_QUEUE_DIR/config"
  FM_TEST_QUEUE_SLOTS=1.5 q run -- true 2>/dev/null; rc=$?
  expect_code 0 "$rc" "a per-process slot override must be ignored"
  FM_TEST_QUEUE_DIR=/dev/null/spool q run -- sh -c ': > "$1/ran"' _ "$CASE" 2>/dev/null; rc=$?
  expect_code 125 "$rc" "a spool that cannot be created"
  assert_absent "$CASE/ran" "run executed its command without a spool"
  pass "fm-test-queue.sh: all callers use shared configuration and reject bad shared values"
}

test_nested_run_does_not_wait_on_itself() {
  local out rc
  new_case nested
  echo slots=1 > "$FM_TEST_QUEUE_DIR/config"
  out=$(q run -- "$QBASH" "$QUEUE" run -- sh -c 'echo inner; exit 3' 2>/dev/null); rc=$?
  expect_code 3 "$rc" "a nested run inside the only slot"
  assert_equals "inner" "$out" "the nested command did not run"
  line_is_empty || fail "a nested run left a ticket behind"
  pass "fm-test-queue.sh: a run nested inside a served run does not take a second ticket"
}

test_lost_counter_cannot_jump_the_line() {
  local holder later rc
  new_case counter
  echo slots=1 > "$FM_TEST_QUEUE_DIR/config"
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

test_competing_reclaimers_preserve_the_replacement_lock() {
  local a b original_path real_ps real_mv
  new_case reclaim-race
  original_path=$PATH
  real_ps=$(command -v ps)
  real_mv=$(command -v mv)
  mkdir -p "$CASE/fakebin" "$FM_TEST_QUEUE_DIR/lock"
  printf '%s not-the-start-time\n' "$$" > "$FM_TEST_QUEUE_DIR/lock/owner"
  cat > "$CASE/fakebin/ps" <<'SH'
#!/bin/bash
if [ "${RECLAIMER:-}" = B ] && [ "$*" = "-p $OBSERVED_PID -o lstart=" ] && [ ! -e "$RACE_CASE/observed-B" ]; then
  : > "$RACE_CASE/observed-B"
  while [ ! -e "$RACE_CASE/allow-B" ]; do sleep 0.05; done
fi
exec "$REAL_PS" "$@"
SH
  cat > "$CASE/fakebin/mv" <<'SH'
#!/bin/bash
if [ "${RECLAIMER:-}" = A ] && [ "$1" = -f ] && [ ! -e "$RACE_CASE/holding-A" ]; then
  : > "$RACE_CASE/holding-A"
  while [ ! -e "$RACE_CASE/allow-A" ]; do sleep 0.05; done
fi
exec "$REAL_MV" "$@"
SH
  chmod +x "$CASE/fakebin/ps" "$CASE/fakebin/mv"
  export RACE_CASE="$CASE" OBSERVED_PID=$$ REAL_PS="$real_ps" REAL_MV="$real_mv"
  export PATH="$CASE/fakebin:$PATH"
  RECLAIMER=B qbg run --label B -- true 2>"$CASE/B.err" & b=$!
  CASE_PIDS+=("$b")
  wait_until "B observed the stale owner" file_exists "$CASE/observed-B"
  RECLAIMER=A qbg run --label A -- true 2>"$CASE/A.err" & a=$!
  CASE_PIDS+=("$a")
  wait_until "A holds the replacement lock" file_exists "$CASE/holding-A"
  : > "$CASE/allow-B"
  sleep 0.5
  assert_grep "$a " "$FM_TEST_QUEUE_DIR/lock/owner" "a competing reclaimer removed the replacement live lock"
  assert_absent "$FM_TEST_QUEUE_DIR/tickets/0000000001" "B allocated a ticket while A held the lock"
  : > "$CASE/allow-A"
  wait "$a" "$b" || fail "reclaimers failed after the replacement lock was released"
  export PATH="$original_path"
  pass "fm-test-queue.sh: a delayed reclaimer cannot remove a replacement live lock"
}

test_fast_command_keeps_its_exit_status() {
  local original_path out rc
  new_case fast-exit
  original_path=$PATH
  export REAL_MV
  REAL_MV=$(command -v mv)
  mkdir -p "$CASE/fakebin"
  cat > "$CASE/fakebin/mv" <<'SH'
#!/bin/bash
"$REAL_MV" "$@"
rc=$?
if [ "$rc" = 0 ] && [ "$1" = -f ] && [ -f "$3" ] &&
  awk -F= '$1 == "pgid" && $2 != "" { found=1 } END { exit !found }' "$3"; then
  sleep 0.5
fi
exit "$rc"
SH
  chmod +x "$CASE/fakebin/mv"
  export PATH="$CASE/fakebin:$PATH"
  echo earlier-error > "$CASE/err"
  out=$(q run -- sh -c 'echo fast; echo command-error >&2; exit 7' 2>>"$CASE/err"); rc=$?
  export PATH="$original_path"
  expect_code 7 "$rc" "command that exits before its wrapper foregrounds it"
  assert_equals fast "$out" "fast command stdout changed"
  assert_grep earlier-error "$CASE/err" "queue truncated the caller's stderr file"
  assert_grep command-error "$CASE/err" "fast command stderr changed"
  line_is_empty || fail "a fast command left its slot taken"
  pass "fm-test-queue.sh: commands that finish before foregrounding keep their exit status"
}

test_locale_and_umask_are_preserved() {
  local value out rc
  new_case locale
  echo slots=1 > "$FM_TEST_QUEUE_DIR/config"
  for value in C en_US.UTF-8 ''; do
    out=$(LC_ALL="$value" q run -- sh -c 'printf "%s:%s" "${LC_ALL+set}" "$LC_ALL"' 2>/dev/null); rc=$?
    expect_code 0 "$rc" "ordinary command with locale '$value'"
    assert_equals "set:$value" "$out" "ordinary command locale changed"
    out=$(LC_ALL="$value" q run -- "$QBASH" "$QUEUE" run -- sh -c 'printf "%s:%s" "${LC_ALL+set}" "$LC_ALL"' 2>/dev/null); rc=$?
    expect_code 0 "$rc" "nested command with locale '$value'"
    assert_equals "set:$value" "$out" "nested command locale changed"
  done
  out=$(unset LC_ALL; q run -- sh -c 'printf "%s" "${LC_ALL-unset}"' 2>/dev/null)
  assert_equals unset "$out" "ordinary command gained LC_ALL"
  out=$(unset LC_ALL; q run -- "$QBASH" "$QUEUE" run -- sh -c 'printf "%s" "${LC_ALL-unset}"' 2>/dev/null)
  assert_equals unset "$out" "nested command gained LC_ALL"
  out=$(umask 022; q run -- sh -c 'umask' 2>/dev/null)
  assert_equals 0022 "$out" "queue changed the command's umask"
  pass "fm-test-queue.sh: commands keep set, empty, and unset locales and the caller's umask"
}

test_private_metadata_and_failed_probe_warning() {
  local holder mode out
  new_case permissions
  rm -rf "$FM_TEST_QUEUE_DIR"
  start_held private; holder=$HELD_PID
  wait_until "private run served" status_has '^serving .*label=private$'
  mode=$(stat -c %a "$FM_TEST_QUEUE_DIR" 2>/dev/null || stat -f %Lp "$FM_TEST_QUEUE_DIR")
  assert_equals 700 "$mode" "spool is not private"
  mode=$(stat -c %a "$FM_TEST_QUEUE_DIR/tickets/0000000001" 2>/dev/null || stat -f %Lp "$FM_TEST_QUEUE_DIR/tickets/0000000001")
  assert_equals 600 "$mode" "ticket metadata is not private"
  release private
  wait "$holder"
  echo unknown > "$CASE/load"
  out=$(q run -- sh -c 'echo admitted' 2>"$CASE/probe.err")
  assert_equals admitted "$out" "a broken load probe blocked admission"
  assert_grep 'warning: load probe failed' "$CASE/probe.err" "failed probe admission did not warn"
  start_held first; holder=$HELD_PID
  wait_until "one fail-open run served" status_has ' serving=1 '
  start_held second
  wait_until "two fail-open runs served" status_has ' serving=2 '
  start_held third
  wait_until "failed probe still respects slots" status_has ' serving=2 waiting=1 '
  release first; release second; release third
  wait "$holder" "$HELD_PID"
  wait_until "all fail-open runs left" line_is_empty
  pass "fm-test-queue.sh: metadata is private and failed probes warn without bypassing slots"
}

test_terminal_execution_modes() {
  new_case terminal
  echo slots=1 > "$FM_TEST_QUEUE_DIR/config"
  python3 "$ROOT/tests/fm-test-queue-pty.py" "$QUEUE" "$QBASH" "$CASE" || fail "terminal execution modes"
  pass "fm-test-queue.sh: terminal foreground, background, input, interrupt, and stop/resume work"
}

test_help_and_usage
test_run_passes_status_and_output_through
test_line_is_first_in_first_out
test_slots_bound_concurrency
test_load_ceiling_holds_the_head
test_signals_release_the_ticket
test_stopped_workloads_suspend_and_resume_the_wrapper
test_dead_owners_are_reclaimed
test_descendants_keep_the_slot_after_the_command_exits
test_stale_lock_is_broken
test_competing_reclaimers_preserve_the_replacement_lock
test_shared_configuration_and_validation
test_nested_run_does_not_wait_on_itself
test_lost_counter_cannot_jump_the_line
test_fast_command_keeps_its_exit_status
test_locale_and_umask_are_preserved
test_private_metadata_and_failed_probe_warning
test_terminal_execution_modes
