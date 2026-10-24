#!/usr/bin/env bash
# Behavior tests for replacing a watcher that is alive but not progressing: the
# arm that started it gives up on it at the stall bound with a typed failure and
# leaves nothing it started behind (including a helper a bounded runner placed in
# a process group of its own); a cycle that is merely slow is left alone; the
# arm's signal path is bounded even when the watcher cannot run its own TERM
# trap; and the shared tree stop never touches a backend server a descendant
# started, a recycled pid, or a process that no longer answers to its identity.
# The wedge is a real blocking state read behind the watcher's own bounded
# runner, set to outlast the stall bound.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watcher-replacement)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
ARM="$ROOT/bin/fm-watch-arm.sh"

FIXTURE_PIDS=
suite_cleanup() {
  local p
  for p in $FIXTURE_PIDS; do kill -KILL "$p" 2>/dev/null; done
  fm_test_cleanup
}
trap suite_cleanup EXIT

# A case whose watcher blocks in its state read for <sleep> seconds; the read
# records its own pid so the test can prove it is gone.
wedge_case() {  # <name> <sleep-seconds> -> case dir
  local dir fakebin
  dir=$(make_case "$1")
  fakebin="$dir/fakebin"
  printf '#!/usr/bin/env bash\necho $$ > "%s/crew-state.pid"\nsleep %s &\necho $! > "%s/crew-sleep.pid"\nwait\necho "state: working source: run-step"\n' "$dir" "$2" "$dir" > "$fakebin/hang-crew-state.sh"
  chmod +x "$fakebin/hang-crew-state.sh"
  printf 'working: compiling step 2\n' > "$dir/state/task.status"
  printf '%s\n' "$dir"
}

start_arm() {  # <case-dir> [NAME=value...] -> sets ARM_PID
  local dir=$1
  shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CREW_STATE_BIN="$dir/fakebin/hang-crew-state.sh" FM_PARKED_GATE_READ_TIMEOUT=600 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_ARM_CONFIRM_TIMEOUT=10 FM_GUARD_GRACE=5 \
    FM_WATCHER_STALL_BOUND=12 "$@" "$ARM" > "$dir/arm.out" 2>&1 &
  ARM_PID=$!
  FIXTURE_PIDS="$FIXTURE_PIDS $ARM_PID"
}

watcher_pid_of() { cat "$1/state/.watch.lock/pid" 2>/dev/null; }

wait_for_file() {  # <path> <ticks>
  local i=0
  while [ ! -s "$1" ] && [ "$i" -lt "$2" ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$1" ]
}

gone_within() {  # <pid> <ticks>
  local i=0
  [ -n "$1" ] || fail "gone_within needs a pid"
  while kill -0 "$1" 2>/dev/null && [ "$i" -lt "$2" ]; do sleep 0.1; i=$((i + 1)); done
  ! kill -0 "$1" 2>/dev/null
}

test_started_arm_replaces_a_stalled_watcher_and_its_tree() {
  local dir watcher reader rsleep start elapsed i
  dir=$(wedge_case started-stall 600)
  start=$(date +%s)
  start_arm "$dir"
  wait_for_file "$dir/crew-state.pid" 200 || fail "the watcher never reached its state read: $(cat "$dir/arm.out")"
  reader=$(cat "$dir/crew-state.pid")
  watcher=$(watcher_pid_of "$dir")
  rsleep=$(cat "$dir/crew-sleep.pid" 2>/dev/null)
  FIXTURE_PIDS="$FIXTURE_PIDS $reader $rsleep $watcher"
  for i in $(seq 1 600); do kill -0 "$ARM_PID" 2>/dev/null || break; sleep 0.1; done
  elapsed=$(( $(date +%s) - start ))
  kill -0 "$ARM_PID" 2>/dev/null && fail "the arm still waits on a watcher whose beacon is ${elapsed}s old past a 12s stall bound"
  if wait "$ARM_PID"; then fail "a stalled started watcher must close its arm nonzero"; fi
  assert_contains "$(cat "$dir/arm.out")" "watcher: FAILED - started watcher pid=$watcher stalled" \
    "the arm must report the typed stalled-holder failure"
  [ "$elapsed" -le 45 ] || fail "the arm took ${elapsed}s to replace a watcher stalled past a 12s bound"
  gone_within "$watcher" 20 || fail "the stalled watcher $watcher survived its arm"
  gone_within "$reader" 20 || fail "the watcher's blocked state read $reader (its own process group) survived"
  gone_within "$rsleep" 20 || fail "the state read's own child $rsleep survived"
  pass "a started arm replaces a watcher stalled at the bound and leaves nothing it started behind"
}

test_slow_cycle_below_the_bound_is_left_alone() {
  local dir watcher
  dir=$(wedge_case slow-cycle 4)
  start_arm "$dir"
  wait_for_file "$dir/crew-state.pid" 200 || fail "the watcher never reached its state read"
  sleep 20
  kill -0 "$ARM_PID" 2>/dev/null || fail "an arm closed on a watcher whose cycles are slow but under the bound: $(cat "$dir/arm.out")"
  watcher=$(watcher_pid_of "$dir")
  kill -0 "$watcher" 2>/dev/null || fail "a slow but progressing watcher was stopped"
  case "$(cat "$dir/arm.out")" in *stalled*) fail "a slow cycle was reported stalled" ;; esac
  kill -TERM "$ARM_PID"
  gone_within "$ARM_PID" 150 || fail "the arm did not stop on TERM"
  pass "a cycle slower than a poll but under the stall bound is never stopped"
}

test_arm_signal_stops_a_watcher_that_cannot_run_its_trap() {
  local dir watcher reader rsleep
  dir=$(wedge_case signal-stop 600)
  start_arm "$dir" FM_WATCHER_STALL_BOUND=900
  wait_for_file "$dir/crew-state.pid" 200 || fail "the watcher never reached its state read"
  sleep 2
  reader=$(cat "$dir/crew-state.pid")
  watcher=$(watcher_pid_of "$dir")
  rsleep=$(cat "$dir/crew-sleep.pid" 2>/dev/null)
  FIXTURE_PIDS="$FIXTURE_PIDS $reader $rsleep $watcher"
  kill -TERM "$ARM_PID"
  gone_within "$ARM_PID" 200 || fail "the arm's TERM handler waited on a watcher blocked in a foreground read"
  gone_within "$watcher" 50 || fail "the watcher survived its arm's TERM"
  gone_within "$reader" 50 || fail "the watcher's blocked read survived its arm's TERM"
  gone_within "$rsleep" 50 || fail "the state read's own child $rsleep survived"
  pass "the arm's signal path stops a watcher (and its read) that cannot run its own TERM trap"
}

test_tree_stop_spares_servers_strangers_and_recycled_identities() {
  local out
  # shellcheck disable=SC2016 # expanded by the nested shell
  out=$(bash -c '
    . "$1/bin/fm-wake-lib.sh"
    d=$2
    # A watcher stand-in that starts a long-lived "server" the way the herdr
    # backend does (backgrounded from a subshell that exits at once), a child
    # in a process group of its own, and an ordinary child.
    bash -c "( sleep 300 & echo \$! > $d/server.pid ); set -m; sleep 300 & echo \$! > $d/own-group.pid; set +m; sleep 300 & echo \$! > $d/child.pid; wait" >/dev/null 2>&1 &
    root=$!
    for i in $(seq 1 50); do [ -s "$d/child.pid" ] && break; sleep 0.1; done
    identity=$(fm_pid_identity "$root")
    fm_watcher_stop_tree "$root" "wrong identity" 1; echo "mismatch:$?"
    kill -0 "$root" 2>/dev/null && echo "root-alive-after-mismatch"
    fm_watcher_stop_tree "$root" "$identity" 1; echo "stop:$?"
    for f in server own-group child; do kill -0 "$(cat "$d/$f.pid")" 2>/dev/null && echo "$f:alive" || echo "$f:gone"; done
    kill -0 "$root" 2>/dev/null && echo root:alive || echo root:gone
    kill "$(cat "$d/server.pid")" 2>/dev/null
  ' _ "$ROOT" "$TMP_ROOT")
  assert_contains "$out" "root-alive-after-mismatch" "a pid that does not answer to the given identity must not be signalled"
  assert_contains "$out" "stop:0" "the tree stop must report success when nothing survives"
  assert_contains "$out" "root:gone" "the stopped root must be gone"
  assert_contains "$out" "child:gone" "an ordinary child must be stopped"
  assert_contains "$out" "own-group:gone" "a child in its own process group must be stopped"
  assert_contains "$out" "server:alive" "a server that reparented away at start must never be signalled"
  pass "the tree stop reaches own-group children, spares a reparented server, and refuses a mismatched identity"
}

# A watcher started directly (no arm), wedged in its state read.
start_bare_watcher() {  # <case-dir> [NAME=value...] -> sets BARE_PID
  local dir=$1
  shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CREW_STATE_BIN="$dir/fakebin/hang-crew-state.sh" FM_PARKED_GATE_READ_TIMEOUT=600 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_GUARD_GRACE=5 FM_WATCHER_STALL_BOUND=12 "$@" \
    "$ROOT/bin/fm-watch.sh" > "$dir/bare.out" 2>&1 &
  BARE_PID=$!
  FIXTURE_PIDS="$FIXTURE_PIDS $BARE_PID"
}

test_stop_takes_a_wedged_watchers_whole_tree() {
  local dir reader rsleep out
  dir=$(wedge_case stop-tree 600)
  start_bare_watcher "$dir"
  wait_for_file "$dir/crew-state.pid" 200 || fail "the watcher never reached its state read"
  reader=$(cat "$dir/crew-state.pid")
  rsleep=$(cat "$dir/crew-sleep.pid" 2>/dev/null)
  FIXTURE_PIDS="$FIXTURE_PIDS $reader $rsleep"
  out=$(fm_run_timed 60 env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$ARM" --stop 2>&1)
  assert_contains "$out" "watcher: stopped pid=$BARE_PID" "--stop must stop this home's wedged watcher"
  gone_within "$BARE_PID" 50 || fail "--stop left the wedged watcher alive"
  gone_within "$reader" 50 || fail "--stop left the watcher's blocked read (its own process group) alive"
  gone_within "$rsleep" 50 || fail "the state read's own child $rsleep survived"
  pass "--stop stops a wedged watcher and everything it started"
}

test_new_arm_evicts_a_stalled_holder_and_its_tree() {
  local dir reader rsleep i
  dir=$(wedge_case evict-tree 600)
  start_bare_watcher "$dir"
  wait_for_file "$dir/crew-state.pid" 200 || fail "the watcher never reached its state read"
  reader=$(cat "$dir/crew-state.pid")
  rsleep=$(cat "$dir/crew-sleep.pid" 2>/dev/null)
  FIXTURE_PIDS="$FIXTURE_PIDS $reader $rsleep"
  # Let the holder's beacon pass the 12 s stall bound, then arm a replacement
  # whose own reads return at once.
  for i in $(seq 1 200); do
    [ "$(fm_path_age "$dir/state/.last-watcher-beat")" -ge 13 ] && break
    sleep 0.1
  done
  printf '%s\n' '#!/usr/bin/env bash' 'echo "state: working source: run-step"' > "$dir/fakebin/hang-crew-state.sh"
  start_arm "$dir"
  for i in $(seq 1 300); do grep -q 'replaced stalled pid' "$dir/arm.out" 2>/dev/null && break; sleep 0.1; done
  assert_contains "$(cat "$dir/arm.out")" "replaced stalled pid $BARE_PID" "a new arm must evict the stalled holder"
  gone_within "$BARE_PID" 50 || fail "the evicted holder survived"
  gone_within "$reader" 50 || fail "the evicted holder's blocked read (its own process group) survived the eviction"
  gone_within "$rsleep" 50 || fail "the state read's own child $rsleep survived"
  kill -TERM "$ARM_PID" 2>/dev/null
  pass "a replacement evicts a stalled holder together with everything the holder started"
}

test_harness_group_kill_still_ends_arm_and_watcher() {
  local dir watcher group
  dir=$(wedge_case group-kill 600)
  # The harness owns the hook's process group: start the arm leading its own.
  set -m
  start_arm "$dir" FM_WATCHER_STALL_BOUND=900
  set +m
  wait_for_file "$dir/crew-state.pid" 200 || fail "the watcher never reached its state read"
  watcher=$(watcher_pid_of "$dir")
  FIXTURE_PIDS="$FIXTURE_PIDS $watcher $(cat "$dir/crew-state.pid")"
  group=$(ps -o pgid= -p "$ARM_PID" | tr -d ' ')
  [ "$group" = "$ARM_PID" ] || fail "fixture: the arm does not lead its process group"
  kill -s KILL -- "-$group"
  gone_within "$watcher" 50 || fail "a harness kill of the arm's process group must still take its watcher"
  pass "a harness kill of the arm's process group still ends the arm and its watcher together"
}

# The one predicate the arm, the away daemon and the supervision host replace
# a watcher on: stalled only at or past the bound (plus the caller's extra
# window), and only while the pid still holds this home's watcher lock.
# The away daemon runs its watcher directly, with no arm: a watcher that stops
# making progress without exiting (here, stopped outright) is never reaped, so
# the daemon itself must stop it and run a replacement once the beacon reaches
# the stall bound.
test_away_daemon_replaces_a_stalled_watcher() {
  local dir log watcher dpid next i
  dir=$(make_case daemon-stall)
  printf 'away\n' > "$dir/state/.afk"
  log="$dir/state/.supervise-daemon.log"
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_GUARD_GRACE=5 FM_WATCHER_STALL_BOUND=12 \
    FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=@9 FM_FAKE_TMUX_WINDOWS=@9 \
    FM_WEDGE_ALARM_EXEC=discard FM_CRASH_NORMAL_SLEEP=1 \
    "$ROOT/bin/fm-supervise-daemon.sh" > "$dir/daemon.out" 2>&1 &
  dpid=$!
  FIXTURE_PIDS="$FIXTURE_PIDS $dpid"
  for i in $(seq 1 300); do
    watcher=$(watcher_pid_of "$dir")
    [ -n "$watcher" ] && [ -e "$dir/state/.last-watcher-beat" ] && break
    sleep 0.1
  done
  [ -n "$watcher" ] || fail "the daemon never started a watcher: $(cat "$dir/daemon.out" "$log" 2>/dev/null)"
  FIXTURE_PIDS="$FIXTURE_PIDS $watcher"
  kill -STOP "$watcher"
  for i in $(seq 1 600); do grep -q "watcher pid $watcher stalled" "$log" 2>/dev/null && break; sleep 0.1; done
  grep -q "watcher pid $watcher stalled" "$log" 2>/dev/null \
    || fail "the daemon never replaced its watcher stalled past a 12s bound: $(cat "$log" 2>/dev/null)"
  gone_within "$watcher" 100 || fail "the daemon left its stalled watcher $watcher in place"
  next=
  for i in $(seq 1 300); do
    next=$(watcher_pid_of "$dir")
    [ -n "$next" ] && [ "$next" != "$watcher" ] && kill -0 "$next" 2>/dev/null && break
    next=
    sleep 0.1
  done
  FIXTURE_PIDS="$FIXTURE_PIDS $next"
  kill -TERM "$dpid" 2>/dev/null
  for i in $(seq 1 100); do kill -0 "$dpid" 2>/dev/null || break; sleep 0.1; done
  [ -n "$next" ] || fail "the daemon never started a replacement watcher: $(cat "$log" 2>/dev/null)"
  pass "the away daemon replaces a watcher stalled past the bound with a fresh one"
}

# A watcher that took the lock but wedged before publishing its identity (here,
# waiting on a recovery-marker lock a live stranger holds) is still the away
# daemon's own child, so the daemon replaces it at the bound like any other.
test_away_daemon_replaces_a_watcher_wedged_in_startup() {
  local dir log holder holder_pid watcher dpid i
  dir=$(make_case daemon-startup-wedge)
  printf 'away\n' > "$dir/state/.afk"
  log="$dir/state/.supervise-daemon.log"
  holder="$dir/marker-holder.sh"
  # shellcheck disable=SC2016 # expanded by the holder script
  printf '%s\n' '#!/usr/bin/env bash' 'export STATE="$2"' '. "$1"' 'fm_lock_try_acquire "$2/.watcher-down.lock" || exit 1' \
    'sleep 300 >/dev/null 2>&1 &' 'trap "kill $! 2>/dev/null; exit 0" TERM' 'wait $!' > "$holder"
  chmod +x "$holder"
  "$holder" "$ROOT/bin/fm-wake-lib.sh" "$dir/state" &
  holder_pid=$!
  FIXTURE_PIDS="$FIXTURE_PIDS $holder_pid"
  for i in $(seq 1 50); do [ "$(cat "$dir/state/.watcher-down.lock/pid" 2>/dev/null)" = "$holder_pid" ] && break; sleep 0.1; done
  [ "$(cat "$dir/state/.watcher-down.lock/pid" 2>/dev/null)" = "$holder_pid" ] || fail "fixture: the marker lock was not taken"
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_GUARD_GRACE=5 FM_WATCHER_STALL_BOUND=12 \
    FM_WAKE_QUEUE_LOCK_WAIT=600 FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=@9 FM_FAKE_TMUX_WINDOWS=@9 \
    FM_WEDGE_ALARM_EXEC=discard FM_CRASH_NORMAL_SLEEP=1 \
    "$ROOT/bin/fm-supervise-daemon.sh" > "$dir/daemon.out" 2>&1 &
  dpid=$!
  FIXTURE_PIDS="$FIXTURE_PIDS $dpid"
  for i in $(seq 1 300); do watcher=$(watcher_pid_of "$dir"); [ -n "$watcher" ] && break; sleep 0.1; done
  [ -n "$watcher" ] || fail "the daemon's watcher never took its lock: $(cat "$dir/daemon.out" "$log" 2>/dev/null)"
  FIXTURE_PIDS="$FIXTURE_PIDS $watcher"
  sleep 1
  [ ! -s "$dir/state/.watch.lock/pid-identity" ] || fail "fixture: the watcher published its identity, so it did not wedge in startup"
  for i in $(seq 1 600); do grep -q "watcher pid $watcher stalled" "$log" 2>/dev/null && break; sleep 0.1; done
  kill -TERM "$dpid" "$holder_pid" 2>/dev/null
  grep -q "watcher pid $watcher stalled" "$log" 2>/dev/null \
    || fail "the daemon never replaced its watcher wedged in startup past a 12s bound: $(cat "$log" 2>/dev/null)"
  gone_within "$watcher" 100 || fail "the daemon left its watcher $watcher wedged in startup"
  for i in $(seq 1 100); do kill -0 "$dpid" 2>/dev/null || break; sleep 0.1; done
  pass "the away daemon replaces its own watcher wedged in startup before it published an identity"
}

test_stalled_predicate_needs_the_bound_and_this_homes_lock() {
  local state pid identity
  state="$TMP_ROOT/stalled-predicate/state"
  mkdir -p "$state/.watch.lock"
  sleep 300 >/dev/null 2>&1 &
  pid=$!
  FIXTURE_PIDS="$FIXTURE_PIDS $pid"
  # The identity is the exec'd sleep's, not the fork's before it.
  for _ in $(seq 1 50); do
    case "$(ps -o comm= -p "$pid" 2>/dev/null)" in *sleep*) break ;; esac
    sleep 0.1
  done
  identity=$(fm_pid_identity "$pid")
  printf '%s\n' "$TMP_ROOT/stalled-predicate" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  printf '%s\n' "$pid" > "$state/.watch.lock/pid"
  : > "$state/.last-watcher-beat"
  perl -e 'utime time - 20, time - 20, $ARGV[0]' "$state/.last-watcher-beat"
  ! FM_WATCHER_STALL_BOUND=12 fm_watcher_stalled "$state" "$ROOT/bin/fm-watch.sh" "$pid" "$TMP_ROOT/stalled-predicate" \
    || fail "a successor that took the lock just now must never be taken for its predecessor's stale beacon"
  perl -e 'utime time - 20, time - 20, $ARGV[0]' "$state/.watch.lock/pid"
  FM_WATCHER_STALL_BOUND=12 fm_watcher_stalled "$state" "$ROOT/bin/fm-watch.sh" "$pid" "$TMP_ROOT/stalled-predicate" \
    || fail "a 20s-old beacon past a 12s bound under this home's lock must be stalled"
  [ "$FM_WATCHER_STALL_AGE" -ge 20 ] || fail "the predicate must leave the beacon age it read, got: $FM_WATCHER_STALL_AGE"
  ! FM_WATCHER_STALL_BOUND=12 fm_watcher_stalled "$state" "$ROOT/bin/fm-watch.sh" "$pid" "$TMP_ROOT/stalled-predicate" 30 \
    || fail "an extra 30s window must keep a 20s-old beacon from counting as stalled"
  ! FM_WATCHER_STALL_BOUND=12 fm_watcher_stalled "$state" "$ROOT/bin/fm-watch.sh" "$pid" "$TMP_ROOT/another-home" \
    || fail "a lock recorded for another home must never count as this home's stalled watcher"
  ! FM_WATCHER_STALL_BOUND=12 fm_watcher_stalled "$state" "$ROOT/bin/fm-watch.sh" "$$" "$TMP_ROOT/stalled-predicate" \
    || fail "a pid that does not answer to the lock's recorded identity must never count as stalled"
  # A lock its holder never got to publish an identity for: only the holder's
  # own parent may take it for stalled, since only there the pid is certain.
  rm -f "$state/.watch.lock/pid-identity" "$state/.watch.lock/fm-home" "$state/.watch.lock/watcher-path"
  ! FM_WATCHER_STALL_BOUND=12 fm_watcher_stalled "$state" "$ROOT/bin/fm-watch.sh" "$pid" "$TMP_ROOT/stalled-predicate" \
    || fail "a lock without a published identity must never count as stalled for an outside owner"
  FM_WATCHER_STALL_BOUND=12 fm_watcher_stalled "$state" "$ROOT/bin/fm-watch.sh" "$pid" "$TMP_ROOT/stalled-predicate" 0 own \
    || fail "an own child wedged before publishing its identity must count as stalled past the bound"
  ! FM_WATCHER_STALL_BOUND=12 fm_watcher_stalled "$state" "$ROOT/bin/fm-watch.sh" "$$" "$TMP_ROOT/stalled-predicate" 0 own \
    || fail "an unpublished lock that names another pid must never count as the caller's stalled child"
  : > "$state/.last-watcher-beat"
  ! FM_WATCHER_STALL_BOUND=12 fm_watcher_stalled "$state" "$ROOT/bin/fm-watch.sh" "$pid" "$TMP_ROOT/stalled-predicate" 0 own \
    || fail "a fresh beacon must never count as stalled"
  pass "the shared stalled-watcher predicate needs the bound, its extra window, and this home's lock under the recorded identity, or its own child's unpublished lock"
}

if [ -n "${FM_WATCHER_REPLACEMENT_ONLY:-}" ]; then
  "$FM_WATCHER_REPLACEMENT_ONLY"
  exit $?
fi

test_stalled_predicate_needs_the_bound_and_this_homes_lock
test_away_daemon_replaces_a_stalled_watcher
test_away_daemon_replaces_a_watcher_wedged_in_startup
test_tree_stop_spares_servers_strangers_and_recycled_identities
test_started_arm_replaces_a_stalled_watcher_and_its_tree
test_slow_cycle_below_the_bound_is_left_alone
test_arm_signal_stops_a_watcher_that_cannot_run_its_trap
test_stop_takes_a_wedged_watchers_whole_tree
test_new_arm_evicts_a_stalled_holder_and_its_tree
test_harness_group_kill_still_ends_arm_and_watcher
