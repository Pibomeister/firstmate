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
. "{run-worktree}/tests/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-test-queue)
QUEUE="$ROOT/bin/fm-test-queue.sh"
QBASH=${FM_TEST_BASH:-bash}
CASE_PIDS=()
CASE_RELEASES=()
# Files a fixture writes its own pid into, so a failed case still ends it.
CASE_PID_FILES=()

# case_pid_start <pid>: the process's start time, empty once it is gone.
case_pid_start() { TZ=UTC LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null | sed 's/^ *//; s/ *$//'; }
# track_pids <pid>...: registers fixtures with their start time, so cleanup
# never signals a process that later reused one of their pids.
track_pids() {
  local p
  for p in "$@"; do
    [ -n "$p" ] && CASE_PIDS+=("$p@$(case_pid_start "$p")")
  done
}
# case_pid_age <pid>: seconds the process has run, from ps etime.
case_pid_age() {
  ps -p "$1" -o etime= 2>/dev/null | awk '{
    t = $1; d = 0
    if (index(t, "-")) { d = substr(t, 1, index(t, "-") - 1); t = substr(t, index(t, "-") + 1) }
    n = split(t, a, ":"); s = 0
    for (i = 1; i <= n; i++) s = s * 60 + a[i]
    print d * 86400 + s
  }'
}
case_file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# reap_case_pids: ends the current case's fixtures and retires their
# registrations. A tracked pid is signalled only while its start time still
# matches; a pid read from a fixture's file only while that process is at
# least as old as the file, give or take the one-second clock granularity.
reap_case_pids() {
  local p e age mtime
  for p in "${CASE_RELEASES[@]:-}"; do
    [ -n "$p" ] && : > "$p"
  done
  for p in "${CASE_PID_FILES[@]:-}"; do
    [ -n "$p" ] && [ -s "$p" ] || continue
    e=$(cat "$p")
    case "$e" in '' | *[!0-9]*) continue ;; esac
    age=$(case_pid_age "$e")
    mtime=$(case_file_mtime "$p")
    [ -n "$age" ] && [ -n "$mtime" ] || continue
    [ $((age + 1)) -ge $(($(date +%s) - mtime)) ] && kill -KILL -- "$e" 2>/dev/null
  done
  for e in "${CASE_PIDS[@]:-}"; do
    p=${e%%@*}
    [ -n "$p" ] && [ "$p" != "$e" ] && [ -n "${e#*@}" ] || continue
    [ "$(case_pid_start "$p")" = "${e#*@}" ] && kill -KILL -- "$p" 2>/dev/null
  done
  CASE_PIDS=()
  CASE_PID_FILES=()
  CASE_RELEASES=()
}
trap 'reap_case_pids; fm_test_cleanup' EXIT

# new_case <name>: a private spool, no config file, load 1, fast polling,
# after ending the previous case's fixtures.
new_case() {
  reap_case_pids
  CASE="$TMP_ROOT/$1"
  mkdir -p "$CASE"
  echo 1 > "$CASE/load"
  export FM_TEST_QUEUE_DIR="$CASE/spool"
  mkdir -p "$FM_TEST_QUEUE_DIR"
  export FM_TEST_QUEUE_LOAD_FILE="$CASE/load"
  export FM_TEST_QUEUE_POLL=0.1
  export FM_TEST_SEAM=1
  unset FM_TEST_QUEUE_SLOTS FM_TEST_QUEUE_LOAD_CEILING FM_TEST_QUEUE_HELD FM_TEST_QUEUE_REMOTE_DISABLE
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
  track_pids "$HELD_PID"
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
  echo earlier-error > "$CASE/stderr"
  out=$(q run -- sh -c 'echo from-command; echo command-error >&2; exit 7' 2>>"$CASE/stderr"); rc=$?
  expect_code 7 "$rc" "run must return the command's exit status"
  assert_equals "from-command" "$out" "run must pass the command's stdout through"
  assert_grep earlier-error "$CASE/stderr" "queue truncated the caller's stderr file"
  assert_grep command-error "$CASE/stderr" "run must pass the command's stderr through"
  out=$(echo piped | q run -- cat 2>/dev/null); rc=$?
  expect_code 0 "$rc" "a successful command"
  assert_equals "piped" "$out" "run must give the command the caller's stdin"
  q run -- sh -c 'exit 148' 2>/dev/null; rc=$?
  expect_code 148 "$rc" "a normal exit resembling a stopped wait status"
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
  track_pids "$p"
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

test_dead_owners_are_reclaimed() {
  local p rc child holder group
  new_case dead
  echo slots=1 > "$FM_TEST_QUEUE_DIR/config"
  qbg run --label crashed -- sh -c 'echo $$ > "$1/child"; while [ ! -e "$1/release-crashed" ]; do sleep 0.05; done' _ "$CASE" 2>/dev/null &
  p=$!
  track_pids "$p"
  wait_until "crashed command started" file_exists "$CASE/child"
  child=$(cat "$CASE/child")
  track_pids "$child"
  group=$(ps -p "$p" -o pgid= | tr -d ' ')
  assert_equals "$group" "$(ps -p "$child" -o pgid= | tr -d ' ')" "command left its wrapper's job"
  assert_grep "child_pid=$child" "$FM_TEST_QUEUE_DIR/tickets/0000000001" "ticket did not persist its workload child"
  assert_grep "child_start=$(TZ=UTC LC_ALL=C ps -p "$child" -o lstart= | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')" \
    "$FM_TEST_QUEUE_DIR/tickets/0000000001" "ticket did not persist its child's start time"
  [ "$group" = "$p" ] || group=""
  assert_equals "$group" "$(awk -F= '$1 == "pgid" { print $2 }' "$FM_TEST_QUEUE_DIR/tickets/0000000001")" \
    "ticket recorded a group the wrapper did not lead"
  kill -KILL "$p"; wait "$p" 2>/dev/null
  status_has ' serving=1 waiting=0 stale=0 ' || fail "a surviving workload lost its slot"
  start_held holder; holder=$HELD_PID
  wait_until "holder waits for survivor" status_has '^waiting position=1 .*label=holder$'
  sleep 0.3
  status_has '^serving .*label=crashed$' || fail "a live group was reclaimed"
  release crashed
  wait_until "holder served after survivor left" status_has '^serving .*label=holder$'
  qbg run --label ghost -- true 2>/dev/null &
  p=$!
  track_pids "$p"
  wait_until "ghost waiting" status_has '^waiting position=1 .*label=ghost$'
  kill -KILL "$p"; wait "$p" 2>/dev/null
  release holder
  wait "$holder"
  q run --label after -- sh -c 'echo after > "$1/after"' _ "$CASE" 2>/dev/null; rc=$?
  expect_code 0 "$rc" "a run behind dead tickets"
  assert_present "$CASE/after" "a dead owner blocked the line"
  status_has ' stale=0 ' || fail "dead tickets were not reclaimed"
  pass "fm-test-queue.sh: surviving workload children keep slots and abandoned tickets are reclaimed"
}

test_unled_group_grandchildren_do_not_keep_the_slot() {
  local follower child
  new_case descendants
  echo slots=1 > "$FM_TEST_QUEUE_DIR/config"
  cat > "$CASE/child.sh" <<'SH'
echo $$ > "$1/descendant"
while [ ! -e "$1/release-child" ]; do sleep 0.05; done
SH
  CASE_RELEASES+=("$CASE/release-child")
  q run --label parent -- sh -c 'cp "$FM_TEST_QUEUE_HELD" "$1/record"; sh "$1/child.sh" "$1" & while [ ! -s "$1/descendant" ]; do sleep 0.05; done' _ "$CASE" 2>/dev/null
  wait_until "descendant started" file_exists "$CASE/descendant"
  child=$(cat "$CASE/descendant")
  track_pids "$child"
  kill -0 "$child" || fail "the grandchild did not survive its direct parent"
  assert_equals "" "$(awk -F= '$1 == "pgid" { print $2 }' "$CASE/record")" "nonleader wrapper recorded a shared group"
  line_is_empty || fail "an unrelated shared group kept the slot after wrapper and child exited"
  start_held follower; follower=$HELD_PID
  wait_until "follower served despite untracked grandchild" status_has '^serving .*label=follower$'
  release child
  release follower
  wait "$follower"
  pass "fm-test-queue.sh: nonleader grandchildren follow the documented lifetime limit"
}

pid_gone() { ! kill -0 "$1" 2>/dev/null; }

# A wrapper that leads its own group, as under an interactive shell, a tool
# that execs it, or an SSH session: set -m gives the job its own group and the
# job's first process is the wrapper itself.
test_led_group_straggler_is_reaped_and_frees_the_slot() {
  local follower straggler leader
  new_case straggler
  echo slots=1 > "$FM_TEST_QUEUE_DIR/config"
  CASE_RELEASES+=("$CASE/release-leaky")
  CASE_PID_FILES+=("$CASE/straggler")
  # The command leaves a background sleep holding the job's stdout, then exits 0.
  (
    set -m
    set -o pipefail
    qbg run --label leaky -- sh -c 'cp "$FM_TEST_QUEUE_HELD" "$1/record"; echo $$ > "$1/leader-child"
      while [ ! -e "$1/release-leaky" ]; do sleep 0.05; done
      sleep 100000 & echo $! > "$1/straggler"; echo leaky-done' _ "$CASE" 2>>"$CASE/stderr" |
      { sleep 0.3; cat; echo consumer-done; } > "$CASE/leaky.out" &
    wait $!
    echo $? > "$CASE/leaky.rc"
  ) 2>>"$CASE/stderr" &
  track_pids "$!"
  wait_until "leaky run served" status_has '^serving .*label=leaky$'
  wait_until "leaky ticket recorded" file_exists "$CASE/record"
  leader=$(awk -F= '$1 == "pid" { print $2 }' "$CASE/record")
  assert_equals "$leader" "$(awk -F= '$1 == "pgid" { print $2 }' "$CASE/record")" "the fixture wrapper did not lead its own group"
  start_held follower; follower=$HELD_PID
  wait_until "follower waits behind the leaky run" status_has '^waiting position=1 .*label=follower$'
  release leaky
  wait_until "the leaky run's caller saw end of output" file_exists "$CASE/leaky.rc"
  straggler=$(cat "$CASE/straggler")
  assert_equals 0 "$(cat "$CASE/leaky.rc")" "the leaky run or its consumer failed"
  assert_equals "leaky-done consumer-done" "$(tr '\n' ' ' < "$CASE/leaky.out" | sed 's/ $//')" \
    "the pipeline consumer beside the wrapper lost output or was ended"
  wait_until "straggler ended" pid_gone "$straggler"
  wait_until "follower served once the straggler was reaped" status_has '^serving .*label=follower$'
  release follower
  wait "$follower"
  line_is_empty || fail "the reaped run left its ticket behind"
  pass "fm-test-queue.sh: a leaked background child in the wrapper's own group is reaped and frees the slot"
}

# The holder is stopped before the child exits, so only the next run can do
# the reaping.
test_stale_led_group_straggler_is_reaped_by_the_next_run() {
  local wrapper child straggler rc after holder
  new_case stale-straggler
  echo slots=1 > "$FM_TEST_QUEUE_DIR/config"
  CASE_RELEASES+=("$CASE/release-crashed")
  CASE_PID_FILES+=("$CASE/straggler")
  (
    set -m
    qbg run --label crashed -- sh -c 'echo $$ > "$1/child"
      while [ ! -e "$1/release-crashed" ]; do sleep 0.05; done
      sleep 100000 & echo $! > "$1/straggler"' _ "$CASE" >/dev/null 2>&1 &
    echo $! > "$CASE/wrapper"
    wait
  ) 2>/dev/null &
  track_pids "$!"
  wait_until "crashed command started" file_exists "$CASE/child"
  wrapper=$(cat "$CASE/wrapper")
  child=$(cat "$CASE/child")
  track_pids "$wrapper" "$child"
  assert_grep "pgid=$wrapper" "$FM_TEST_QUEUE_DIR/tickets/0000000001" "the fixture wrapper did not record its own group"
  holder=$(awk -F= '$1 == "holder_pid" { print $2 }' "$FM_TEST_QUEUE_DIR/tickets/0000000001")
  [ -n "$holder" ] || fail "the served led group recorded no holder"
  track_pids "$holder"
  kill -KILL "$wrapper"
  wait_until "wrapper gone" pid_gone "$wrapper"
  # Stopped only now: a stopped member when the group is orphaned would get
  # the kernel's hangup, and so would the child.
  kill -STOP "$holder"
  status_has ' serving=1 ' || fail "a running child lost its slot when the wrapper died"
  release crashed
  wait_until "child left its straggler" file_exists "$CASE/straggler"
  straggler=$(cat "$CASE/straggler")
  wait_until "child exited" pid_gone "$child"
  kill -0 "$straggler" 2>/dev/null || fail "the straggler did not outlive its parent, so this case would be vacuous"
  qbg run --label after -- sh -c 'echo after > "$1/after"' _ "$CASE" 2>/dev/null &
  after=$!
  track_pids "$after"
  wait_until "a run behind a dead ticket's straggler was served" file_exists "$CASE/after"
  wait "$after"; rc=$?
  expect_code 0 "$rc" "a run behind a dead ticket's straggler"
  wait_until "stale straggler ended" pid_gone "$straggler"
  wait_until "stopped holder ended" pid_gone "$holder"
  line_is_empty || fail "the dead ticket was not reclaimed"
  pass "fm-test-queue.sh: the next run wakes a dead wrapper's stopped holder, which reaps its straggler, and takes the slot"
}

# With no later run at all, the holder itself reaps a killed wrapper's
# straggler once the child is gone, then exits.
test_killed_wrapper_holder_reaps_without_a_next_run() {
  local wrapper child straggler
  new_case holder-reap
  echo slots=1 > "$FM_TEST_QUEUE_DIR/config"
  CASE_RELEASES+=("$CASE/release-crashed")
  CASE_PID_FILES+=("$CASE/straggler")
  (
    set -m
    qbg run --label crashed -- sh -c 'echo $$ > "$1/child"
      while [ ! -e "$1/release-crashed" ]; do sleep 0.05; done
      sleep 100000 </dev/null >/dev/null 2>&1 & echo $! > "$1/straggler"' _ "$CASE" >/dev/null 2>&1 &
    echo $! > "$CASE/wrapper"
    wait
  ) 2>/dev/null &
  track_pids "$!"
  wait_until "crashed command started" file_exists "$CASE/child"
  wrapper=$(cat "$CASE/wrapper")
  child=$(cat "$CASE/child")
  track_pids "$wrapper" "$child"
  kill -KILL "$wrapper"
  wait_until "wrapper gone" pid_gone "$wrapper"
  release crashed
  wait_until "child left its straggler" file_exists "$CASE/straggler"
  straggler=$(cat "$CASE/straggler")
  wait_until "straggler ended with no later run" pid_gone "$straggler"
  wait_until "nothing is left in the group" group_empty "$wrapper"
  pass "fm-test-queue.sh: a killed wrapper's holder reaps its straggler with no later run"
}

# A wrapper killed while its child is still recording itself leaves the
# holder with no child to watch yet; the holder must keep waiting rather than
# leave the group unguarded. A ps gate holds the child inside its record.
test_holder_waits_for_a_child_still_recording_itself() {
  local wrapper straggler real_ps
  new_case holder-pending
  echo slots=1 > "$FM_TEST_QUEUE_DIR/config"
  real_ps=$(command -v ps)
  mkdir -p "$CASE/fakebin" "$CASE/gate"
  CASE_RELEASES+=("$CASE/gate/open")
  CASE_PID_FILES+=("$CASE/straggler")
  printf '%s\n' '#!/bin/sh' \
    "if [ \"\$*\" = '-axo pid=,ppid=,pgid=,stat=,lstart=' ] && mkdir '$CASE/gate/taken' 2>/dev/null; then" \
    "  : > '$CASE/gate/blocked'" \
    "  while [ ! -e '$CASE/gate/open' ]; do sleep 0.05; done" \
    'fi' \
    "exec '$real_ps' \"\$@\"" > "$CASE/fakebin/ps"
  chmod +x "$CASE/fakebin/ps"
  (
    set -m
    PATH="$CASE/fakebin:$PATH" qbg run --label pending -- sh -c \
      'sleep 100000 </dev/null >/dev/null 2>&1 & echo $! > "$1/straggler"' _ "$CASE" >/dev/null 2>&1 &
    echo $! > "$CASE/wrapper"
    wait
  ) 2>/dev/null &
  track_pids "$!"
  wait_until "the child is held inside its record" file_exists "$CASE/gate/blocked"
  wrapper=$(cat "$CASE/wrapper")
  track_pids "$wrapper"
  kill -KILL "$wrapper"
  wait_until "wrapper gone" pid_gone "$wrapper"
  # Longer than the holder's 2-second poll, so a holder that gave up is gone.
  sleep 3
  : > "$CASE/gate/open"
  wait_until "child left its straggler" file_exists "$CASE/straggler"
  straggler=$(cat "$CASE/straggler")
  wait_until "straggler ended with no later run" pid_gone "$straggler"
  wait_until "nothing is left in the group" group_empty "$wrapper"
  pass "fm-test-queue.sh: a holder outlasting its wrapper waits for a child still recording itself"
}

# The wrapper spares the holder while it reaps on exit, so a wrapper killed
# during the grace for a straggler that ignores TERM leaves the holder to
# finish with KILL.
test_wrapper_killed_mid_reap_leaves_the_holder_to_finish() {
  local wrapper child straggler
  new_case holder-mid-reap
  echo slots=1 > "$FM_TEST_QUEUE_DIR/config"
  CASE_PID_FILES+=("$CASE/straggler")
  (
    set -m
    qbg run --label stubborn -- sh -c 'echo $$ > "$1/child"
      sh -c '"'"'trap "" TERM; echo $$ > "$1/straggler"; exec sleep 100000'"'"' _ "$1" </dev/null >/dev/null 2>&1 &
      while [ ! -s "$1/straggler" ]; do sleep 0.05; done' _ "$CASE" >/dev/null 2>&1 &
    echo $! > "$CASE/wrapper"
    wait
  ) 2>/dev/null &
  track_pids "$!"
  wait_until "stubborn straggler started" file_exists "$CASE/straggler"
  wrapper=$(cat "$CASE/wrapper")
  child=$(cat "$CASE/child")
  straggler=$(cat "$CASE/straggler")
  track_pids "$wrapper" "$child"
  wait_until "child exited" pid_gone "$child"
  # Inside the wrapper's 2-second grace after a TERM the straggler ignores.
  sleep 0.5
  ! pid_gone "$wrapper" || fail "the wrapper finished before it could be killed mid-reap"
  kill -KILL "$wrapper"
  wait_until "wrapper gone" pid_gone "$wrapper"
  wait_until "stubborn straggler ended with no later run" pid_gone "$straggler"
  wait_until "nothing is left in the group" group_empty "$wrapper"
  pass "fm-test-queue.sh: a wrapper killed mid-reap leaves its holder to finish the reap"
}

# A caller that reads the run's output to the end before it waits leaves a
# killed wrapper a zombie until that output closes. The holder treats the
# zombie as gone, so it reaps the straggler holding the output.
test_zombie_wrapper_does_not_block_its_holder() {
  local wrapper straggler
  new_case holder-zombie
  echo slots=1 > "$FM_TEST_QUEUE_DIR/config"
  CASE_PID_FILES+=("$CASE/straggler")
  python3 - "$QBASH" "$QUEUE" "$CASE" <<'PYCALLER' &
import os, subprocess, sys
qbash, queue, case = sys.argv[1:4]
script = (
    'echo $$ > "$1/child"\n'
    'sh -c \'trap "" TERM; echo $$ > "$1/straggler"; exec sleep 100000\' _ "$1" </dev/null 2>/dev/null &\n'
    'while [ ! -s "$1/straggler" ]; do sleep 0.05; done\n'
)
p = subprocess.Popen([qbash, queue, "run", "--label", "zombie", "--", "sh", "-c", script, "_", case],
                     stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                     preexec_fn=os.setpgrp)
with open(os.path.join(case, "wrapper"), "w") as f:
    f.write(str(p.pid))
p.stdout.read()
open(os.path.join(case, "output-closed"), "w").close()
p.wait()
PYCALLER
  track_pids "$!"
  wait_until "stubborn straggler started" file_exists "$CASE/straggler"
  wrapper=$(cat "$CASE/wrapper")
  straggler=$(cat "$CASE/straggler")
  track_pids "$wrapper"
  wait_until "child exited" pid_gone "$(cat "$CASE/child")"
  sleep 0.5
  [ ! -e "$CASE/output-closed" ] || fail "the wrapper finished before it could be killed mid-reap"
  kill -KILL "$wrapper"
  wait_long 30 "the caller's output closed" file_exists "$CASE/output-closed"
  wait_until "stubborn straggler ended" pid_gone "$straggler"
  wait_until "nothing is left in the group" group_empty "$wrapper"
  pass "fm-test-queue.sh: a zombie wrapper whose caller still reads its output does not stall its holder"
}

# A shell that execs into the queue leaves the processes it already started,
# such as a process substitution's consumer, as the wrapper's own children.
# They are caller stages, so the run's exit spares them.
test_process_substitution_under_an_execd_leader_is_spared() {
  local leader
  new_case exec-substitution
  echo slots=1 > "$FM_TEST_QUEUE_DIR/config"
  (
    set -m
    "$QBASH" -c 'exec "$1" "$2" run --label substituted -- sh -c "seq 1 3" > >(sleep 1; tail -n 1 > "$3/out.tmp"; mv "$3/out.tmp" "$3/out")' \
      _ "$QBASH" "$QUEUE" "$CASE" </dev/null 2>/dev/null &
    echo $! > "$CASE/leader"
    wait
  ) 2>/dev/null &
  track_pids "$!"
  wait_until "the exec'd leader started" file_exists "$CASE/leader"
  leader=$(cat "$CASE/leader")
  track_pids "$leader"
  wait_until "the exec'd run ended" pid_gone "$leader"
  wait_until "the consumer finished after the run" file_exists "$CASE/out"
  assert_equals 3 "$(cat "$CASE/out")" "the process substitution's consumer lost its input"
  pass "fm-test-queue.sh: a process substitution started before an exec into the queue keeps its output"
}

# The holder's own nap is never recorded as a caller stage, so a holder that
# dies mid-nap leaves a nap the exit reap ends rather than one that holds the
# slot after the run is over. A slowed ps lets the first nap begin before the
# run records its siblings.
holder_nap() { NAP=$(pgrep -P "$1" -x sleep 2>/dev/null | head -n 1); [ -n "$NAP" ]; }
holder_recorded() { HOLDER=$(awk -F= '$1 == "holder_pid" { print $2 }' "$1" 2>/dev/null); [ -n "$HOLDER" ]; }
test_dead_holders_nap_is_not_a_caller_stage() {
  local wrapper real_ps
  new_case holder-nap
  echo slots=1 > "$FM_TEST_QUEUE_DIR/config"
  CASE_RELEASES+=("$CASE/release-napping")
  real_ps=$(command -v ps)
  mkdir -p "$CASE/fakebin"
  printf '%s\n' '#!/bin/sh' \
    "[ -e '$CASE/fast-ps' ] || sleep 0.3" \
    "exec '$real_ps' \"\$@\"" > "$CASE/fakebin/ps"
  chmod +x "$CASE/fakebin/ps"
  (
    set -m
    PATH="$CASE/fakebin:$PATH" qbg run --label napping -- sh -c 'echo $$ > "$1/child"
      while [ ! -e "$1/release-napping" ]; do sleep 0.05; done' _ "$CASE" >/dev/null 2>&1 &
    echo $! > "$CASE/wrapper"
    wait
  ) 2>/dev/null &
  track_pids "$!"
  wait_until "napping command started" file_exists "$CASE/child"
  wrapper=$(cat "$CASE/wrapper")
  track_pids "$wrapper" "$(cat "$CASE/child")"
  wait_until "the run recorded its holder" holder_recorded "$FM_TEST_QUEUE_DIR/tickets/0000000001"
  wait_until "the holder naps" holder_nap "$HOLDER"
  track_pids "$NAP"
  kill -KILL "$HOLDER"
  : > "$CASE/fast-ps"
  kill -0 "$NAP" 2>/dev/null || fail "the nap ended before the run did, so nothing was tested"
  release napping
  wait_until "the run ended" pid_gone "$wrapper"
  pid_gone "$NAP" || fail "the dead holder's nap $NAP outlived the run as a spared stage"
  status_has 'serving=0' || fail "the slot stayed held after the run ended"
  pass "fm-test-queue.sh: a dead holder's nap is reaped, not spared as a caller stage"
}

# A wrapper that could not read its holder's start time records no holder,
# and must still end rather than wait on a holder that waits for it.
test_unread_holder_start_does_not_hang_the_run() {
  local wrapper real_ps
  new_case holder-unread
  echo slots=1 > "$FM_TEST_QUEUE_DIR/config"
  real_ps=$(command -v ps)
  mkdir -p "$CASE/fakebin"
  cat > "$CASE/fakebin/ps" <<EOF
#!/bin/sh
# Fails once: the first start-time read of a process whose parent is this
# ps's grandparent, which is the wrapper asking about the holder it forked.
if [ "\$1" = -p ] && [ "\$3" = -o ] && [ "\$4" = lstart= ]; then
  gp=\$('$real_ps' -p "\$PPID" -o ppid= | tr -d ' ')
  tp=\$('$real_ps' -p "\$2" -o ppid= | tr -d ' ')
  if [ -n "\$gp" ] && [ "\$gp" = "\$tp" ] && mkdir '$CASE/ps-failed' 2>/dev/null; then exit 1; fi
fi
exec '$real_ps' "\$@"
EOF
  chmod +x "$CASE/fakebin/ps"
  (
    set -m
    PATH="$CASE/fakebin:$PATH" qbg run --label unread -- sh -c 'echo ran > "$1/out"' _ "$CASE" >/dev/null 2>&1 &
    echo $! > "$CASE/wrapper"
    wait
  ) 2>/dev/null &
  track_pids "$!"
  wait_until "the run started" file_exists "$CASE/wrapper"
  wrapper=$(cat "$CASE/wrapper")
  track_pids "$wrapper"
  wait_until "the command ran" file_exists "$CASE/out"
  [ -d "$CASE/ps-failed" ] || fail "the holder's start-time read never failed"
  wait_until "the run ended after an unread holder start" pid_gone "$wrapper"
  wait_until "nothing is left in the group" group_empty "$wrapper"
  status_has 'serving=0' || fail "the slot stayed held after the run ended"
  pass "fm-test-queue.sh: an unread holder start time neither hangs the run nor holds the slot"
}

# A snapshot that fails once during the wrapper's exit reap leaves the
# holder running to retry, rather than abandoning the straggler.
test_failed_exit_snapshot_leaves_the_holder_to_retry() {
  local wrapper straggler real_ps
  new_case holder-retry
  echo slots=1 > "$FM_TEST_QUEUE_DIR/config"
  real_ps=$(command -v ps)
  mkdir -p "$CASE/fakebin"
  CASE_PID_FILES+=("$CASE/straggler")
  printf '%s\n' '#!/bin/sh' \
    "if [ -e '$CASE/fail-ps' ] && [ \"\$*\" = '-axo pid=,ppid=,pgid=,stat=,lstart=' ] && mkdir '$CASE/ps-failed' 2>/dev/null; then exit 1; fi" \
    "exec '$real_ps' \"\$@\"" > "$CASE/fakebin/ps"
  chmod +x "$CASE/fakebin/ps"
  (
    set -m
    PATH="$CASE/fakebin:$PATH" qbg run --label retry -- sh -c \
      'sleep 100000 </dev/null >/dev/null 2>&1 & echo $! > "$1/straggler"; : > "$1/fail-ps"' _ "$CASE" >/dev/null 2>&1 &
    echo $! > "$CASE/wrapper"
    wait
  ) 2>/dev/null &
  track_pids "$!"
  wait_until "the run started" file_exists "$CASE/wrapper"
  wrapper=$(cat "$CASE/wrapper")
  track_pids "$wrapper"
  wait_until "the run left its straggler" file_exists "$CASE/straggler"
  straggler=$(cat "$CASE/straggler")
  wait_until "the run ended" pid_gone "$wrapper"
  [ -d "$CASE/ps-failed" ] || fail "the exit reap's snapshot never failed"
  wait_until "straggler ended after the failed snapshot" pid_gone "$straggler"
  wait_until "nothing is left in the group" group_empty "$wrapper"
  pass "fm-test-queue.sh: a snapshot failure during the exit reap leaves the holder to retry"
}

# An unrelated job whose leader exits leaves a member behind in a group whose
# id matches a dead ticket. Without a live holder in that group, nothing proves
# the group is the ticket's, so its member must survive.
test_reused_group_id_is_not_reaped() {
  local group member dead now start holder
  new_case reused-group
  echo slots=2 > "$FM_TEST_QUEUE_DIR/config"
  mkdir -p "$FM_TEST_QUEUE_DIR/tickets"
  CASE_PID_FILES+=("$CASE/member")
  (
    set -m
    sh -c 'sleep 100000 </dev/null >/dev/null 2>&1 & echo $! > "$1/member"' _ "$CASE" &
    echo $! > "$CASE/group"
    wait
  ) 2>/dev/null
  wait_until "unrelated member started" file_exists "$CASE/member"
  group=$(cat "$CASE/group")
  member=$(cat "$CASE/member")
  assert_equals "$group" "$(ps -p "$member" -o pgid= | tr -d '[:space:]')" "the unrelated member left its job's group"
  wait_until "unrelated leader gone" pid_gone "$group"
  sh -c 'exit 0' & dead=$!
  wait "$dead"
  now=$(date +%s)
  start=$(TZ=UTC LC_ALL=C ps -p "$$" -o lstart= | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  # First the holder is a live process outside the group, then it is dead.
  for holder in "$$ $start" "$dead dead"; do
    printf 'pid=%s\nstart=dead\nchild_pid=%s\nchild_start=dead\npgid=%s\ncaller_pid=\nholder_pid=%s\nholder_start=%s\nsiblings=\nenqueued=%s\nserved=%s\ntask=\nlabel=reused-group\n' \
      "$group" "$dead" "$group" "${holder%% *}" "${holder#* }" "$now" "$now" > "$FM_TEST_QUEUE_DIR/tickets/0000000001"
    q run -- true 2>/dev/null || fail "a run beside the reused group failed"
    kill -0 "$member" 2>/dev/null || fail "a run reaped a reused group it could not prove was its own (holder ${holder%% *})"
  done
  kill -KILL "$member" 2>/dev/null
  pass "fm-test-queue.sh: a matching group id without a live holder in it is never reaped"
}

# A caller starts the pipeline as its own job, waits until it is served, and
# exits, so its consumer is reparented away from the recorded caller. The
# consumer was already in the group at serve time, so it is a recorded stage.
test_pipeline_stage_outliving_its_caller_is_spared() {
  local caller consumer
  new_case orphaned-stage
  echo slots=1 > "$FM_TEST_QUEUE_DIR/config"
  CASE_RELEASES+=("$CASE/release-stage")
  CASE_PID_FILES+=("$CASE/consumer")
  cat > "$CASE/caller.sh" <<'SH'
set -m
"$1" "$2" run --label stage -- sh -c 'cp "$FM_TEST_QUEUE_HELD" "$1/record"
  while [ ! -e "$1/release-stage" ]; do sleep 0.05; done; echo stage-out' _ "$3" 2>/dev/null |
  sh -c 'echo $$ > "$1/consumer"; cat; sleep 0.5; echo consumer-done' _ "$3" > "$3/stage.out" 2>/dev/null &
while [ ! -s "$3/record" ]; do sleep 0.05; done
SH
  bash "$CASE/caller.sh" "$QBASH" "$QUEUE" "$CASE" </dev/null >/dev/null 2>&1 &
  caller=$!
  track_pids "$caller"
  wait "$caller"
  wait_until "consumer started" file_exists "$CASE/consumer"
  consumer=$(cat "$CASE/consumer")
  kill -0 "$consumer" 2>/dev/null || fail "the consumer ended before the run did"
  [ "$(ps -p "$consumer" -o ppid= | tr -d '[:space:]')" != "$caller" ] || fail "the consumer still has its caller, so this case would be vacuous"
  release stage
  wait_until "the consumer finished after the run" grep -q consumer-done "$CASE/stage.out"
  assert_equals "stage-out consumer-done" "$(tr '\n' ' ' < "$CASE/stage.out" | sed 's/ $//')" \
    "the orphaned pipeline consumer lost output or was ended"
  wait_until "the run released its slot" line_is_empty
  pass "fm-test-queue.sh: a pipeline stage that outlives its caller is not reaped"
}

# group_members <pgid>: every live process still in that group.
group_members() { ps -axo pgid=,stat=,args= 2>/dev/null | awk -v g="$1" '$1 == g && $2 !~ /^Z/'; }
group_empty() { [ -z "$(group_members "$1")" ]; }
# marked_fixture_running <suite pid>: whether any process anywhere still
# carries that watchdog suite's fixture marker as its last argument. The
# marker reaches awk through the environment, so the probe never matches.
marked_fixture_running() {
  ps -axo args= 2>/dev/null | WD_MARK="100000.$1" awk '"" $NF == "" ENVIRON["WD_MARK"] { found = 1 } END { exit !found }'
}
no_marked_fixture() { ! marked_fixture_running "$1"; }
# suite_tmux_gone <suite pid>: whether that suite's private tmux server ended.
suite_tmux_gone() {
  ! ps -axo args= 2>/dev/null | WD_SOCKET="fm-watchdog-test-$1" awk '
    { for (i = 1; i < NF; i++) if ($i == "-L" && $(i + 1) == ENVIRON["WD_SOCKET"]) found = 1 }
    END { exit !found }'
}

# wait_long <seconds> <description> <command...>: wait_until with a longer bound.
wait_long() {
  local limit=$(($1 * 10)) what=$2 i=0
  shift 2
  while ! "$@"; do
    i=$((i + 1))
    [ "$i" -lt "$limit" ] || fail "timed out waiting for: $what"
    sleep 0.1
  done
}

# A representative watchdog case runs as its own job, so everything it starts
# shares one group that must be empty once the suite is gone - after a normal
# exit and after a kill too hard for the suite to clean up itself, both
# directly and under the queue, whose cleanup of the dead run's group must
# not end the suite's guardian before it sweeps.
test_watchdog_fixtures_do_not_outlive_their_suite() {
  local mode suite group
  if ! command -v tmux >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    pass "fm-watchdog.test.sh fixtures: skipped, tmux or jq not found"
    return
  fi
  new_case watchdog-fixtures
  for mode in exit kill queued; do
    mkdir -p "$CASE/$mode-tmp"
    if [ "$mode" = queued ]; then
      (
        set -m
        TMPDIR="$CASE/$mode-tmp" qbg run --label watchdog -- bash "$ROOT/tests/fm-watchdog.test.sh" \
          test_captain_record_follows_the_lock_owner > "$CASE/$mode.log" 2>&1 < /dev/null &
        echo $! > "$CASE/$mode.group"
        wait
      ) 2>/dev/null &
      track_pids "$!"
      wait_until "the $mode suite started" grep -qs '^child_pid=[0-9]' "$FM_TEST_QUEUE_DIR/tickets/0000000001"
      group=$(cat "$CASE/$mode.group")
      suite=$(awk -F= '$1 == "child_pid" { print $2 }' "$FM_TEST_QUEUE_DIR/tickets/0000000001")
    else
      (
        set -m
        TMPDIR="$CASE/$mode-tmp" bash "$ROOT/tests/fm-watchdog.test.sh" test_captain_record_follows_the_lock_owner \
          > "$CASE/$mode.log" 2>&1 < /dev/null &
        echo $! > "$CASE/$mode.suite"
        wait
      ) 2>/dev/null &
      track_pids "$!"
      wait_until "the $mode suite started" file_exists "$CASE/$mode.suite"
      suite=$(cat "$CASE/$mode.suite")
      group=$suite
    fi
    track_pids "$suite" "$group"
    if [ "$mode" != exit ]; then
      wait_long 120 "a marked watchdog fixture started" marked_fixture_running "$suite"
      kill -KILL "$suite"
    fi
    wait_long 300 "the $mode suite ended" pid_gone "$suite"
    [ "$mode" != exit ] || assert_grep FM_TEST_COMPLETE "$CASE/$mode.log" "the watchdog case did not complete"
    wait_long 30 "nothing outlived the $mode suite" group_empty "$group"
    wait_long 30 "no marked fixture outlived the $mode suite" no_marked_fixture "$suite"
    wait_long 30 "the $mode suite's tmux server ended" suite_tmux_gone "$suite"
  done
  pass "fm-watchdog.test.sh: no fixture outlives its suite, even one killed outright or under the queue"
}

test_reused_child_pid_is_not_live() {
  local dead now
  new_case child-identity
  mkdir -p "$FM_TEST_QUEUE_DIR/tickets"
  sh -c 'exit 0' & dead=$!
  wait "$dead"
  now=$(date +%s)
  printf 'pid=%s\nstart=dead\nchild_pid=%s\nchild_start=wrong-start\npgid=\nenqueued=%s\nserved=%s\ntask=\nlabel=reused-child\n' \
    "$dead" "$$" "$now" "$now" > "$FM_TEST_QUEUE_DIR/tickets/0000000001"
  status_has ' serving=0 waiting=0 stale=1 ' || fail "a reused child pid kept the ticket alive"
  q run -- true 2>/dev/null || fail "a reused child pid blocked reclamation"
  status_has ' serving=0 waiting=0 stale=0 ' || fail "a reused child ticket was not reclaimed"
  pass "fm-test-queue.sh: child liveness requires the recorded start time"
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
  track_pids "$p"
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
  for bad in "slots=0" "slots=two" "load_ceiling=-1" "load_ceiling=" "colour=blue" "slots" "offload_threshold=0" "remote_hosts=-oProxyCommand=bad" "remote_hosts=m3,,hetzner" "offload_projects=a/b" "offload_projects=a,,b"; do
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
  track_pids "$rc"
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
  TZ=America/Mexico_City RECLAIMER=B qbg run --label B -- true 2>"$CASE/B.err" & b=$!
  track_pids "$b"
  wait_until "B observed the stale owner" file_exists "$CASE/observed-B"
  TZ=UTC RECLAIMER=A qbg run --label A -- true 2>"$CASE/A.err" & a=$!
  track_pids "$a"
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

test_contenders_in_different_timezones_share_ownership() {
  local holder follower child
  new_case timezones
  echo slots=1 > "$FM_TEST_QUEUE_DIR/config"
  CASE_RELEASES+=("$CASE/release-utc")
  TZ=UTC qbg run --label utc -- sh -c 'echo "$TZ" > "$1/utc-tz"; echo $$ > "$1/child"; while [ ! -e "$1/release-utc" ]; do sleep 0.05; done' _ "$CASE" 2>/dev/null &
  holder=$!
  track_pids "$holder"
  wait_until "UTC command started" file_exists "$CASE/child"
  child=$(cat "$CASE/child")
  track_pids "$child"
  TZ=America/Mexico_City qbg run --label mexico -- sh -c 'echo "$TZ" > "$1/mexico-tz"' _ "$CASE" 2>/dev/null &
  follower=$!
  track_pids "$follower"
  TZ=America/Mexico_City wait_until "other timezone waits for wrapper" status_has '^waiting position=1 .*label=mexico$'
  assert_absent "$CASE/mexico-tz" "a timezone difference freed an occupied slot"
  kill -KILL "$holder"; wait "$holder" 2>/dev/null
  TZ=America/Mexico_City status_has ' serving=1 waiting=1 stale=0 ' || fail "a timezone difference reclaimed the surviving child"
  assert_absent "$CASE/mexico-tz" "a contender bypassed a surviving child in another timezone"
  release utc
  wait "$follower" || fail "contender did not run after the surviving child exited"
  assert_equals UTC "$(cat "$CASE/utc-tz")" "queue changed the first command's timezone"
  assert_equals America/Mexico_City "$(cat "$CASE/mexico-tz")" "queue changed the second command's timezone"
  line_is_empty || fail "cross-timezone contenders left tickets behind"
  pass "fm-test-queue.sh: timezones preserve live wrappers, surviving children, and command environments"
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

offload_fixture_repo() {  # <dir> <origin-url>
  fm_git_init_commit "$1"
  git -C "$1" remote add origin "$2"
}

fake_remote_ssh() {  # <path>: runs SSH and rsync against an isolated local mirror
  cat > "$1" <<'SH'
#!/usr/bin/env bash
while [ "${1:-}" = -o ]; do shift 2; done
host=$1; shift
printf '%s\n' "$host" >> "$SSH_LOG"
[ "$host" != unreachable ] || exit 255
case "$*" in
  *"exec env FM_HOME="*)
    printf '%s\n' "$*" >> "$SSH_LOG.executions"
    [ "${FAIL_EXEC:-}" != 1 ] || exit 255 ;;
esac
export HOME="${SSH_LOG%/*}/remote-home"
mkdir -p "$HOME"
export FM_TEST_QUEUE_DIR="${SSH_LOG%/*}/remote-spool"
export FM_TEST_QUEUE_LOAD_FILE="${SSH_LOG%/*}/remote-load"
unset FM_TEST_QUEUE_HELD
if [ -n "${REMOTE_UMASK:-}" ]; then umask "$REMOTE_UMASK"; fi
# Like sshd, start the remote command as the leader of a new session.
exec python3 -c 'import os, sys
try:
    os.setsid()
except OSError:
    pass
os.execvp("bash", ["bash", "-c", sys.argv[1]])' "$*"
SH
  chmod +x "$1"
  cat > "${1%/*}/rsync" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --server ] || exec "$REAL_RSYNC" "$@"
[ "${FAIL_EXTRACT:-}" != 1 ] || exit 1
args=()
while [ "$#" -gt 1 ]; do
  if [ "$1" = -e ]; then shift 2; else args+=("$1"); shift; fi
done
dest=${1#*:}
if [ "${MIRROR_SAME_STAMP:-}" = 1 ] && [ -f "$dest/manifest" ] && [ -f "${args[${#args[@]}-1]}/manifest" ]; then
  # The mirror's stale manifest carries the new one's size and second, as when
  # two runs stage within one second; a quick check alone would skip it.
  touch -r "${args[${#args[@]}-1]}/manifest" "$dest/manifest"
fi
"$REAL_RSYNC" "${args[@]}" --stats "$dest" >> "$SSH_LOG.rsync" || exit
if [ "${CORRUPT_SNAPSHOT:-}" = 1 ] && [ -d "$dest/repo" ]; then printf stale > "$dest/repo/source"; fi
if [ -f "$dest/manifest" ] && [ "${STEAL_LOCK:-}" = 1 ]; then
  printf 'host=successor\npid=1\nepoch=%s\n' "$(date +%s)" > "${dest%/}/../lock/owner"
fi
if [ -f "$dest/manifest" ] && [ "${FOREIGN_SNAPSHOT:-}" = 1 ]; then
  # Another worktree's consistent files and manifest land in the shared mirror.
  python3 - "$dest" <<'PYFOREIGN'
import hashlib, json, os, sys
snap = sys.argv[1]
with open(os.path.join(snap, "repo", "source"), "w") as fh:
    fh.write("foreign\n")
lines = []
for line in open(os.path.join(snap, "manifest")):
    item = json.loads(line)
    if item[0] == "repo/source":
        item[3] = hashlib.sha256(b"foreign\n").hexdigest()
    lines.append(json.dumps(item, ensure_ascii=True))
with open(os.path.join(snap, "manifest"), "w") as fh:
    fh.write("\n".join(lines) + "\n")
PYFOREIGN
fi
SH
  chmod +x "${1%/*}/rsync"
  export REAL_RSYNC
  REAL_RSYNC=$(command -v rsync)
}

test_unlisted_project_runs_locally_and_failed_upload_falls_back() {
  local out rc saved_path=$PATH
  new_case offload-optin
  mkdir -p "$CASE/fakebin"
  fake_remote_ssh "$CASE/fakebin/ssh"
  export SSH_LOG="$CASE/ssh.log"
  offload_fixture_repo "$CASE/other" git@example.invalid:owner/webapp.git
  offload_fixture_repo "$CASE/listed" https://example.invalid/owner/firstmate.git
  printf 'slots=1\nload_ceiling=150\nremote_hosts=m3\n' > "$FM_TEST_QUEUE_DIR/config"
  echo 9 > "$CASE/load"
  echo 1 > "$CASE/remote-load"
  PATH="$CASE/fakebin:$PATH"
  out=$( ( cd "$CASE/other" && q run -- sh -c 'printf "%s\n" "$PWD"; exit 4' ) 2>"$CASE/other.err"); rc=$?
  expect_code 4 "$rc" 'unlisted project local exit status'
  assert_equals "$(cd "$CASE/other" && pwd -P)" "$(cd "$out" && pwd -P)" 'unlisted project did not run in its own checkout'
  assert_absent "$SSH_LOG" 'unlisted project tried SSH offload'
  out=$( ( cd "$CASE/listed" && FAIL_EXTRACT=1 q run -- sh -c 'printf "%s\n" "$PWD"; exit 5' ) 2>"$CASE/listed.err"); rc=$?
  PATH=$saved_path
  expect_code 5 "$rc" 'failed upload must run the suite locally, not report a failure'
  assert_equals "$(cd "$CASE/listed" && pwd -P)" "$(cd "$out" && pwd -P)" 'failed upload did not fall back to the local checkout'
  assert_grep 'no remote prepared; using local admission' "$CASE/listed.err" 'failed upload was not reported as a preparation failure'
  assert_absent "$SSH_LOG.executions" 'failed upload started a remote command'
  line_is_empty || fail 'fallback run leaked local ticket'
  pass 'fm-test-queue.sh: offload is per-project opt-in; a failed upload runs locally'
}

test_remote_offload_snapshot_and_failure() {
  local out rc saved_path=$PATH
  new_case offload
  mkdir -p "$CASE/fakebin"
  offload_fixture_repo "$CASE/repo" https://example.invalid/owner/firstmate.git
  printf 'original\n' > "$CASE/repo/source"
  printf 'delete me\n' > "$CASE/repo/deleted"
  git -C "$CASE/repo" add .
  git -C "$CASE/repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm fixture
  printf 'changed\n' > "$CASE/repo/source"
  rm "$CASE/repo/deleted"
  printf 'untracked\n' > "$CASE/repo/extra"
  printf 'slots=1\nload_ceiling=150\nremote_hosts=unreachable,m3\n' > "$FM_TEST_QUEUE_DIR/config"
  echo 9 > "$CASE/load"
  echo 1 > "$CASE/remote-load"
  fake_remote_ssh "$CASE/fakebin/ssh"
  export SSH_LOG="$CASE/ssh.log"
  PATH="$CASE/fakebin:$PATH"
  [ ! -e "$CASE/repo/bin/fm-test-queue.sh" ] || fail 'offload fixture must not carry the queue scripts'
  out=$( ( cd "$CASE/repo" && q run -- sh -c '[ ! -e deleted ] || exit 8; printf "%s|%s|%s|%s\n" "$(cat source)" "$(cat extra)" "$1" "$(git rev-parse --is-shallow-repository)"; exit 7' _ "quote' and spaces" ) 2>"$CASE/stderr"); rc=$?
  PATH=$saved_path
  expect_code 7 "$rc" 'remote exit status'
  assert_equals "changed|untracked|quote' and spaces|true" "$out" 'remote shallow snapshot and argv'
  assert_grep 'offloading to m3' "$CASE/stderr" 'load above eight must prefer reachable remote even below local ceiling'
  assert_grep unreachable "$SSH_LOG" 'the first configured host was not attempted'
  assert_equals 1 "$(wc -l < "$SSH_LOG.executions" | tr -d ' ')" 'failed remote command was retried'
  python3 - "$SSH_LOG.executions" <<'PYTEST' || fail 'normal remote scratch was not cleaned'
import os, shlex, sys
assert not os.path.exists(shlex.split(open(sys.argv[1]).read())[1])
PYTEST
  line_is_empty || fail 'remote command leaked local ticket'
  pass 'fm-test-queue.sh: high load offloads current source and preserves arguments and failure status'
}

test_remote_straggler_cannot_hold_the_ssh_output() {
  local saved_path=$PATH straggler
  new_case offload-straggler
  mkdir -p "$CASE/fakebin"
  offload_fixture_repo "$CASE/repo" https://example.invalid/owner/firstmate.git
  printf 'slots=1\nload_ceiling=150\nremote_hosts=builder\n' > "$FM_TEST_QUEUE_DIR/config"
  echo 9 > "$CASE/load"
  echo 1 > "$CASE/remote-load"
  fake_remote_ssh "$CASE/fakebin/ssh"
  export SSH_LOG="$CASE/ssh.log"
  PATH="$CASE/fakebin:$PATH"
  CASE_PID_FILES+=("$CASE/straggler")
  # The remote command leaves a background sleep holding the SSH output.
  (
    cd "$CASE/repo" || exit 1
    q run -- sh -c 'sleep 100000 & echo $! > "$1/straggler"; echo remote-done' _ "$CASE" 2>>"$CASE/stderr" | cat > "$CASE/out"
    echo $? > "$CASE/rc"
  ) 2>>"$CASE/stderr" &
  track_pids "$!"
  PATH=$saved_path
  wait_until 'remote run returned with its output closed' file_exists "$CASE/rc"
  straggler=$(cat "$CASE/straggler")
  assert_grep 'offloading to builder' "$CASE/stderr" 'the run was not offloaded'
  assert_equals 0 "$(cat "$CASE/rc")" 'remote run exit status'
  assert_equals remote-done "$(cat "$CASE/out")" 'remote run output'
  wait_until 'remote straggler ended' pid_gone "$straggler"
  line_is_empty || fail 'remote run leaked local ticket'
  pass 'fm-test-queue.sh: a remote straggler is reaped and cannot hold the SSH output open'
}

test_unreachable_remote_waits_locally_and_threshold_is_configurable() {
  local p saved_path=$PATH out
  new_case remote-fallback
  mkdir -p "$CASE/fakebin"
  printf '#!/bin/sh\nexit 255\n' > "$CASE/fakebin/ssh"
  chmod +x "$CASE/fakebin/ssh"
  PATH="$CASE/fakebin:$PATH"
  printf 'slots=1\nload_ceiling=16\nremote_hosts=m3,hetzner\n' > "$FM_TEST_QUEUE_DIR/config"
  echo 20 > "$CASE/load"
  offload_fixture_repo "$CASE/repo" https://example.invalid/owner/firstmate.git
  ( cd "$CASE/repo" && qbg run -- sh -c ': > "$1/ran"' _ "$CASE" ) 2>"$CASE/stderr" &
  p=$!
  track_pids "$p"
  wait_until 'unreachable remote fallback' grep -Fq 'no remote prepared; using local admission' "$CASE/stderr"
  assert_absent "$CASE/ran" 'unreachable hosts bypassed the local load ceiling'
  echo 1 > "$CASE/load"
  wait "$p" || fail 'local fallback did not complete after load fell'
  assert_present "$CASE/ran" 'local fallback never ran'
  printf 'slots=1\nload_ceiling=16\nremote_hosts=m3\noffload_threshold=12\n' > "$FM_TEST_QUEUE_DIR/config"
  echo 9 > "$CASE/load"
  out=$(cd "$CASE/repo" && q run -- echo local 2>"$CASE/threshold.err") || fail 'custom offload threshold failed'
  assert_equals local "$out" 'below-threshold command did not run locally'
  [ ! -s "$CASE/threshold.err" ] || fail 'below-threshold command tried SSH'
  PATH=$saved_path
  pass 'fm-test-queue.sh: unreachable hosts preserve local admission; threshold is configurable'
}

test_remote_incremental_manifest_and_uncertain_run() {
  local saved_path=$PATH out rc started elapsed mirror warm prepared
  new_case offload-incremental
  mkdir -p "$CASE/fakebin"
  offload_fixture_repo "$CASE/repo" https://example.invalid/owner/firstmate.git
  printf original > "$CASE/repo/source"
  printf removed > "$CASE/repo/deleted"
  printf 'ignored\n' > "$CASE/repo/.gitignore"
  # An unchanged, incompressible payload makes full retransfers observable.
  dd if=/dev/urandom of="$CASE/repo/large" bs=1048576 count=4 2>/dev/null
  git -C "$CASE/repo" add .
  git -C "$CASE/repo" -c user.name=Tests -c user.email=tests@example.invalid commit -qm fixture
  printf 'slots=1\nload_ceiling=150\nremote_hosts=m3\n' > "$FM_TEST_QUEUE_DIR/config"
  echo 9 > "$CASE/load"
  echo 1 > "$CASE/remote-load"
  fake_remote_ssh "$CASE/fakebin/ssh"
  export SSH_LOG="$CASE/ssh.log"
  PATH="$CASE/fakebin:$PATH"
  ( cd "$CASE/repo" && q run -- sh -c 'echo poison > source; echo junk > leaked' ) 2>"$CASE/cold.err" || fail 'cold offload'
  printf committed > "$CASE/repo/committed"
  git -C "$CASE/repo" add committed
  git -C "$CASE/repo" -c user.name=Tests -c user.email=tests@example.invalid commit -qm advance
  printf changed > "$CASE/repo/source"
  rm "$CASE/repo/deleted"
  printf extra > "$CASE/repo/extra space"
  printf secret > "$CASE/repo/ignored"
  ln -s source "$CASE/repo/link"
  chmod 755 "$CASE/repo/source"
  : > "$SSH_LOG.rsync"
  started=$(date +%s)
  ( cd "$CASE/repo" && REMOTE_UMASK=077 q run -- sh -c '[ "$(git show HEAD:committed)" = committed ] && [ ! -e deleted ] && [ ! -e ignored ] && [ ! -e leaked ] && [ -x source ] && [ "$(readlink link)" = source ] && [ "$(stat -c %a .. 2>/dev/null || stat -f %Lp ..)" = 700 ] || exit 9; printf "%s|%s" "$(cat source)" "$(cat "extra space")"' ) >"$CASE/warm.out" 2>"$CASE/warm.err" &
  warm=$!
  track_pids "$warm"
  # The 30s budget covers warm prepare only: it ends when the queue announces
  # the verified snapshot, before the remote command itself runs.
  prepared=""
  while kill -0 "$warm" 2>/dev/null; do
    if grep -Fq 'offloading to m3' "$CASE/warm.err"; then prepared=$(date +%s); break; fi
    sleep 0.2
  done
  wait "$warm" || fail 'warm offload'
  [ -n "$prepared" ] || prepared=$(date +%s)
  elapsed=$(( prepared - started ))
  out=$(cat "$CASE/warm.out")
  assert_equals 'changed|extra' "$out" 'warm manifest snapshot'
  assert_grep 'offloading to m3' "$CASE/warm.err" 'warm prepare fell back locally'
  [ "$elapsed" -lt 30 ] || fail "warm prepare took ${elapsed}s (limit 30s)"
  python3 - "$SSH_LOG.rsync" <<'PYTEST' || fail 'warm upload retransferred unchanged payload'
import re, sys
text = open(sys.argv[1]).read()
amounts = re.findall(r'(?:Literal|Unmatched) data: ([0-9,]+) (?:bytes|B)', text)
assert amounts, text
assert sum(int(n.replace(',', '')) for n in amounts) < 100000, text
PYTEST
  mirror=$(printf '%s\n' "$CASE/remote-home/.cache/firstmate/test-mirrors/"*)
  mkdir "$mirror/lock"
  out=$( ( cd "$CASE/repo" && q run -- pwd ) 2>"$CASE/busy.err") || fail 'busy mirror fallback'
  assert_equals "$(cd "$CASE/repo" && pwd -P)" "$out" 'busy mirror did not run locally'
  [ -d "$mirror/lock" ] || fail 'busy fallback removed another preparation lock'
  rmdir "$mirror/lock"
  out=$( ( cd "$CASE/repo" && CORRUPT_SNAPSHOT=1 q run -- pwd ) 2>"$CASE/mismatch.err") || fail 'manifest mismatch fallback'
  assert_equals "$(cd "$CASE/repo" && pwd -P)" "$out" 'manifest mismatch did not run locally'
  assert_grep 'no remote prepared' "$CASE/mismatch.err" 'manifest mismatch was accepted'
  ( cd "$CASE/repo" && FAIL_EXEC=1 q run -- sh -c 'touch "$1/ran"' _ "$CASE" ) 2>"$CASE/uncertain.err"; rc=$?
  expect_code 255 "$rc" 'uncertain SSH result'
  assert_absent "$CASE/ran" 'uncertain remote execution retried locally'
  assert_grep 'execution uncertain' "$CASE/uncertain.err" 'uncertain scratch was not preserved'
  python3 - "$SSH_LOG.executions" <<'PYTEST' || fail 'uncertain scratch was removed'
import os, shlex, shutil, sys
path = shlex.split(open(sys.argv[1]).read().splitlines()[-1])[1]
assert os.path.isdir(path), path
# Only the fixture knows that this injected connection failure ran nothing.
shutil.rmtree(os.path.dirname(path))
PYTEST
  PATH=$saved_path
  pass "fm-test-queue.sh: warm delta prepared in ${elapsed}s; mismatch falls back and uncertain execution does not"
}

test_remote_offload_hardening() {
  local saved_path=$PATH out mirror old_epoch sha
  new_case offload-hardening
  mkdir -p "$CASE/fakebin"
  offload_fixture_repo "$CASE/repo" https://example.invalid/owner/firstmate.git
  printf 'original-content\n' > "$CASE/repo/source"
  git -C "$CASE/repo" add .
  git -C "$CASE/repo" -c user.name=Tests -c user.email=tests@example.invalid commit -qm fixture
  printf 'slots=1\nload_ceiling=150\nremote_hosts=m3\n' > "$FM_TEST_QUEUE_DIR/config"
  echo 9 > "$CASE/load"
  echo 1 > "$CASE/remote-load"
  fake_remote_ssh "$CASE/fakebin/ssh"
  export SSH_LOG="$CASE/ssh.log"
  PATH="$CASE/fakebin:$PATH"
  ( cd "$CASE/repo" && q run -- true ) 2>"$CASE/cold.err" || fail 'hardening cold offload'
  assert_grep 'offloading to m3' "$CASE/cold.err" 'hardening cold run was not offloaded (rsync path semantics)'
  printf advance > "$CASE/repo/committed"
  git -C "$CASE/repo" add committed
  git -C "$CASE/repo" -c user.name=Tests -c user.email=tests@example.invalid commit -qm advance
  out=$( ( cd "$CASE/repo" && q run -- sh -c 'git rev-list --all >/dev/null || exit 9; echo revlist-ok' ) 2>"$CASE/delta.err") || fail 'hardening delta offload'
  assert_equals revlist-ok "$out" 'delta shallow history does not traverse (rev-list --all)'
  assert_grep 'offloading to m3' "$CASE/delta.err" 'hardening delta run was not offloaded'
  mkdir -p "$CASE/repo/nested"
  git -C "$CASE/repo/nested" init -q 2>/dev/null || fail 'nested fixture init'
  printf 'inner\n' > "$CASE/repo/nested/inner.txt"
  sha=$(git -C "$CASE/repo" rev-parse HEAD)
  mkdir -p "$CASE/repo/sub"
  printf 'gitlink-content\n' > "$CASE/repo/sub/file.txt"
  git -C "$CASE/repo" update-index --add --cacheinfo "160000,$sha,sub" || fail 'gitlink fixture'
  out=$( ( cd "$CASE/repo" && q run -- sh -c 'printf "%s|%s" "$(cat nested/inner.txt)" "$([ -e sub/file.txt ] && echo present || echo absent)"' ) 2>"$CASE/nested.err") || fail 'nested repo offload'
  assert_equals 'inner|present' "$out" 'nested repo or submodule working tree was not staged'
  assert_grep 'offloading to m3' "$CASE/nested.err" 'nested repo disabled offload instead of staging recursively'
  git -C "$CASE/repo" rm -q --cached sub 2>/dev/null || true
  rm -rf "$CASE/repo/sub" "$CASE/repo/nested"
  mirror=$(printf '%s\n' "$CASE/remote-home/.cache/firstmate/test-mirrors/"*)
  mkdir -p "$mirror/lock"
  old_epoch=$(python3 -c 'import time; print(int(time.time()) - 7200)')
  printf 'host=old\npid=1\nepoch=%s\n' "$old_epoch" > "$mirror/lock/owner"
  out=$( ( cd "$CASE/repo" && q run -- echo stale-ok ) 2>"$CASE/stale.err") || fail 'stale lock reclaim run'
  assert_equals stale-ok "$out" 'stale lock was not reclaimed'
  assert_grep 'reclaimed stale test-mirror lock' "$CASE/stale.err" 'stale lock reclaim printed no diagnostic'
  assert_grep 'offloading to m3' "$CASE/stale.err" 'run after stale lock reclaim was not offloaded'
  out=$( ( cd "$CASE/repo" && FOREIGN_SNAPSHOT=1 q run -- cat source ) 2>"$CASE/foreign.err") || fail 'foreign snapshot run'
  assert_equals 'original-content' "$out" 'run admitted another worktree snapshot instead of falling back locally'
  assert_grep 'no remote prepared' "$CASE/foreign.err" 'foreign manifest was accepted'
  out=$( ( cd "$CASE/repo" && MIRROR_SAME_STAMP=1 STEAL_LOCK=1 q run -- echo stolen-ok ) 2>"$CASE/steal.err") || fail 'reclaimed lock run'
  assert_equals stolen-ok "$out" 'run whose lock was reclaimed did not complete'
  assert_grep 'offloading to m3' "$CASE/steal.err" 'same-size, same-second stale mirror manifest was not replaced'
  assert_grep 'host=successor' "$mirror/lock/owner" 'a run released the lock its successor reclaimed'
  rm -f "$mirror/lock/owner"
  rmdir "$mirror/lock"
  git -C "$mirror/snapshot/repo" rm -q --cached source || fail 'stale index fixture'
  out=$( ( cd "$CASE/repo" && q run -- pwd ) 2>"$CASE/index1.err") || fail 'stale index run'
  assert_equals "$(cd "$CASE/repo" && pwd -P)" "$out" 'stale mirror index was admitted'
  out=$( ( cd "$CASE/repo" && q run -- cat source ) 2>"$CASE/index2.err") || fail 'stale index repair run'
  assert_equals 'original-content' "$out" 'stale index repair run output'
  assert_grep 'offloading to m3' "$CASE/index2.err" 'stale mirror index was not rebuilt after a failed verification'
  touch -t 202001010000 "$CASE/repo/source"
  printf 'XXXXXXXX-content\n' > "$mirror/snapshot/repo/source"
  touch -r "$CASE/repo/source" "$mirror/snapshot/repo/source"
  out=$( ( cd "$CASE/repo" && q run -- pwd ) 2>"$CASE/heal1.err") || fail 'quick-check mismatch run'
  assert_equals "$(cd "$CASE/repo" && pwd -P)" "$out" 'quick-check mismatch did not fall back locally first'
  out=$( ( cd "$CASE/repo" && q run -- cat source ) 2>"$CASE/heal2.err") || fail 'quick-check self-heal run'
  assert_equals 'original-content' "$out" 'quick-check self-heal did not repair the mirror'
  assert_grep 'offloading to m3' "$CASE/heal2.err" 'self-heal run was not offloaded'
  PATH=$saved_path
  pass 'fm-test-queue.sh: rsync paths, delta shallow, stale lock, nested staging, and quick-check self-heal hold'
}

for c in test_remote_offload_hardening; do s=$(date +%s); ( $c ); echo "case $c rc=$? $(( $(date +%s)-s ))s"; done
