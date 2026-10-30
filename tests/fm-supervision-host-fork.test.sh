#!/usr/bin/env bash
# Fork-only supervision-host behavior tests kept beside upstream's split
# (fm-supervision-host{,-drain,-hook,-park}.test.sh): cleanup ordering,
# lease-lock startup, Orca stale rows, attended pass-through successors,
# stalled-arm retirement, and park readiness.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

command -v node >/dev/null 2>&1 || { printf 'skip: node absent\n'; exit 0; }
command -v perl >/dev/null 2>&1 || { printf 'skip: perl absent\n'; exit 0; }

# shellcheck source=tests/supervision-host-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/supervision-host-helpers.sh"

test_cleanup_waits_for_a_stopping_session() {
  local home session
  home=$(make_home session-cleanup-wait attended)
  FM_HOME="$home" bash -c '
    trap '\''trap "" TERM; kill "$sleeper" 2>/dev/null || true; sleep 1; : > "$FM_HOME/session-finished"; exit 0'\'' TERM
    sleep 300 &
    sleeper=$!
    : > "$FM_HOME/session-ready"
    wait "$sleeper"
  ' &
  session=$!
  printf '%s\n' "$session" > "$home/claude-pids"
  wait_until 100 test -e "$home/session-ready" || fail "session cleanup fixture never became ready"
  : > "$home/session.stop"
  stop_home_processes "$home"
  if [ ! -e "$home/session-finished" ]; then
    wait_for_exit "$session" 100 >/dev/null 2>&1 || true
    fail "cleanup returned before the stopping session completed"
  fi
  wait_for_exit "$session" 100 >/dev/null 2>&1 || fail "cleanup left the stopping session alive"
  pass "fixture cleanup sends TERM first and waits for a stopping session to finish"
}

test_completed_case_stops_its_registered_processes() {
  local home pids pid
  home=$(make_home case-lifetime attended)
  start_session "$home"
  park_again "$home"
  pids=$(awk -F '\t' '$1 == "host" || $1 == "arm" { print $2 }' "$home/state/.supervision-host")
  pids="$pids $(cat "$home/state/.watch.lock/pid") $(cat "$home/claude-pids")"
  for pid in $pids; do
    kill -0 "$pid" 2>/dev/null || fail "fixture: process $pid was not running before cleanup"
  done
  stop_registered_homes
  for pid in $pids; do
    wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$pid" \
      || fail "a completed case retained fixture process $pid"
  done
  [ ! -s "$HOMES_FILE" ] || fail "the completed case left homes registered for later cases"
  [ -d "$home/state" ] || fail "case cleanup removed fixture evidence"
  pass "case cleanup stops its host, arm, watcher, and primary while retaining fixture evidence"
}

test_host_starts_despite_a_held_lease_command_lock() {
  local home holder holder_pid start elapsed i
  home=$(make_home lease-lock-held attended)
  holder="$home/fm-fake-lease-holder.sh"
  # shellcheck disable=SC2016 # expanded by the holder script
  printf '%s\n' '#!/usr/bin/env bash' 'export STATE="$2"' '. "$1"' 'fm_lock_try_acquire "$2/.fm-lease-command.lock" || exit 1' 'sleep 90 >/dev/null 2>&1 &' 'trap "kill $! 2>/dev/null; exit 0" TERM' 'wait $!' > "$holder"
  chmod +x "$holder"
  "$holder" "$ROOT/bin/fm-wake-lib.sh" "$home/state" &
  holder_pid=$!
  for i in $(seq 1 50); do [ "$(cat "$home/state/.fm-lease-command.lock/pid" 2>/dev/null)" = "$holder_pid" ] && break; sleep 0.1; done
  [ "$(cat "$home/state/.fm-lease-command.lock/pid" 2>/dev/null)" = "$holder_pid" ] || fail "fixture: the lease-command lock was not taken"
  start=$(date +%s)
  FM_SUPERVISION_HOST_RELEASE_BUDGET=6 start_host "$home"
  wait_until 300 grep -q '	start	' "$home/state/.supervision-host.log" \
    || { kill "$holder_pid" 2>/dev/null; fail "a host never logged start while a live process held the lease-command lock"$'\n'"$(cat "$home/state/.supervision-host.log" 2>/dev/null)"; }
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -le 20 ] || { kill "$holder_pid" 2>/dev/null; fail "the host took ${elapsed}s to start with a 6s release budget"; }
  assert_re '	init-blocked	release-leases	' "$home/state/.supervision-host.log" "the blocked release stage must be named in the host log"
  wait_until 200 watcher_live "$home" || { kill "$holder_pid" 2>/dev/null; fail "the host did not arm a watcher after starting"; }
  kill -0 "$holder_pid" 2>/dev/null || fail "the host must leave the foreign lock holder alive"
  [ "$(cat "$home/state/.fm-lease-command.lock/pid" 2>/dev/null)" = "$holder_pid" ] || fail "the host must leave the holder's lock untouched"
  kill "$holder_pid" 2>/dev/null
  pass "a host starts within its release bound beside a live lease-command lock holder and names the blocked stage"
}

test_dispatch_entry_resolves_an_orca_terminal_stale_row() {
  local home state out
  home="$TMP_ROOT/dispatch-orca"
  state="$home/state"
  mkdir -p "$state"
  printf 'window=fm-orca-task\nendpoint_task_id=orca-task\nproject=demo\nkind=ship\nbackend=orca\nterminal=term_0f0e0d0c-aaaa-bbbb-cccc-000000000001\n' \
    > "$state/orca-task.meta"
  append_wake "$state" stale term_0f0e0d0c-aaaa-bbbb-cccc-000000000001 \
    "stale: term_0f0e0d0c-aaaa-bbbb-cccc-000000000001 (paused 600s, awaiting external)"

  out=$(FM_HOME="$home" node "$DISPATCH" scope --afk)
  assert_contains "$out" "corrupted=0" "an Orca terminal-keyed stale row must not make the away scan unresolvable"
  assert_contains "$out" "status=safe" "an Orca terminal-keyed stale row must be claimable away"
  assert_contains "$out" "rows=1" "the away scan must claim the terminal-keyed stale row"
  assert_contains "$out" "tasks=orca-task" "the terminal key must resolve to the task that records it"

  append_wake "$state" stale term_0f0e0d0c-aaaa-bbbb-cccc-00000000ffff "stale: term_0f0e0d0c-aaaa-bbbb-cccc-00000000ffff"
  out=$(FM_HOME="$home" node "$DISPATCH" scope --afk)
  assert_contains "$out" "corrupted=1" "a terminal no task records must still read as unresolvable"
  pass "dispatch entry: an away scan resolves an Orca terminal-keyed stale row to its task and still refuses an unknown terminal"
}

test_attended_pass_through_without_an_engine_keeps_its_successor() {
  local home arm watcher queue host cycle_arm cycle
  home=$(make_home attended-no-engine attended claude)
  # The singleton probe identifies arms by this fixture-owned executable path.
  ln -s "$ROOT/bin" "$home/bin"
  HOST="$home/bin/fm-supervision-host.sh" FM_SUPERVISION_HOST_PRIMARY=codex \
    FM_SUPERVISION_ENGINE_CLAUDE_BIN="$home/missing-engine" start_host "$home"
  wait_until 150 watcher_live "$home" || fail "no engine: the host never started a watcher"
  for cycle in 1 2; do
  append_status "$home" "fixture finished $cycle" 'done'
  wait_until 250 host_exited "$home" || fail "no engine: the close did not reach main"
  expect_code 0 "$(cat "$home/host.rc")" "no engine: the real wake must reach main successfully"
  [ "$(grep -c '^signal:' "$home/host.out")" -eq 1 ] || fail "no engine: the original wake must reach main once"
  assert_grep 'the claude engine executable is missing' "$home/state/.supervision-host.log" \
    "no engine: the pass-through must name the unavailable engine"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "no engine: an engine turn ran"
  [ ! -s "$home/state/.branch-eligible-rows" ] || fail "no engine: branch rows were granted"
  watcher_live "$home" || fail "no engine: the pass-through left no successor watcher"
  watcher=$(cat "$home/state/.watch.lock/pid")
  arm=$(cut -f1 "$home/state/.supervision-host-left")
  kill -0 "$arm" 2>/dev/null || fail "no engine: the recorded successor arm is dead"
  [ "$(marker_kind "$home")" = downtime ] || fail "no engine: main's wake was marked handled"
  queue=$(cat "$home/state/.wake-queue")
  assert_contains "$queue" 'demo.status' "no engine: main's wake was lost"
  main_drain_and_ack "$home"
  [ ! -s "$home/state/.wake-queue" ] || fail "no engine: main's acknowledgement left queued work"
  [ "$(cat "$home/state/.watch.lock/pid")" = "$watcher" ] || fail "no engine: acknowledgement replaced the successor"
  HOST="$home/bin/fm-supervision-host.sh" FM_SUPERVISION_HOST_PRIMARY=codex \
    FM_SUPERVISION_ENGINE_CLAUDE_BIN="$home/missing-engine" start_host "$home"
  wait_until 250 sh -c '! kill -0 "$1" 2>/dev/null' _ "$arm" || fail "no engine: takeover left the old arm running"
  wait_until 250 watcher_live "$home" || fail "no engine: takeover left no watcher"
  watcher=$(cat "$home/state/.watch.lock/pid")
  cycle_arm=$(parent_of "$watcher")
  host=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$home/state/.supervision-host")
  [ "$(parent_of "$cycle_arm")" = "$host" ] || fail "no engine: the next park does not own the watcher cycle"
  host_owns_the_only_cycle "$home" || fail "no engine: takeover is not singleton"
  [ ! -s "$home/host.rc" ] || fail "no engine: takeover replayed the acknowledged wake"
  done
  pass "host: repeated attended closes without an engine preserve one successor and singleton takeover"
}

test_attended_successor_failures_preserve_the_close() {
  local home failure real_mktemp
  real_mktemp=$(command -v mktemp)
  for failure in start record; do
    home=$(make_home "attended-successor-$failure" attended claude)
    if [ "$failure" = record ]; then
      mkdir "$home/state/.supervision-host-left"
    else
      cat > "$home/fakebin/mktemp" <<SH
#!/usr/bin/env bash
case "\$*" in
  *.supervision-host-arm.*)
    if [ -s "\$FM_HOME/state/.watch-deliveries.log" ]; then
      : > "\$FM_HOME/start-refused"
      exit 1
    fi ;;
esac
exec "$real_mktemp" "\$@"
SH
      chmod +x "$home/fakebin/mktemp"
    fi
    FM_SUPERVISION_HOST_PRIMARY=codex start_host "$home"
    wait_until 150 watcher_live "$home" || fail "$failure: no initial watcher"
    append_status "$home" 'fixture finished' 'done'
    wait_until 250 host_exited "$home" || fail "$failure: close did not reach main"
    expect_code 0 "$(cat "$home/host.rc")" "$failure: original close must reach main"
    [ "$(grep -c '^signal:' "$home/host.out")" -eq 1 ] || fail "$failure: original wake changed or repeated"
    assert_no_re '^supervision-host' "$home/host.out" "$failure: original close changed"
    assert_grep 'demo.status' "$home/state/.wake-queue" "$failure: main's row disappeared"
    [ "$(engine_calls "$home")" -eq 0 ] || fail "$failure: engine called"
    [ "$(marker_kind "$home")" = downtime ] || fail "$failure: marker is not downtime"
    wait_until 100 no_home_arms "$home" || fail "$failure: unverified successor remained alive"
    if [ "$failure" = start ]; then
      [ -e "$home/start-refused" ] || fail "start control did not run"
      assert_grep successor-unverified "$home/state/.supervision-host.log" "start refusal was not recorded"
    else
      assert_grep successor-unrecorded "$home/state/.supervision-host.log" "record refusal was not recorded"
    fi
    stop_home_processes "$home"
  done
  pass "host: attended successor start and persistence refusals preserve main's close and stop unverified arms"
}

test_attended_pass_through_at_boundary_starts_no_successor() {
  local home real_sed
  home=$(make_home attended-boundary attended claude)
  printf '0\n' > "$home/park-clock"
  real_sed=$(command -v sed)
  cat > "$home/fakebin/sed" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"\$FM_HOME/state/.lock")
    if grep -q '^signal:' "\$FM_HOME/host.out" 2>/dev/null \
      || grep -q 'signal:' "\$FM_HOME/state/.watch-deliveries.log" 2>/dev/null; then
      printf '120\n' > "\$FM_HOME/park-clock"
      : > "\$FM_HOME/boundary-seam"
    fi ;;
esac
exec "$real_sed" "\$@"
SH
  chmod +x "$home/fakebin/sed"
  FM_SUPERVISION_HOST_PRIMARY=codex FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" \
    FM_SUPERVISION_HOST_PARK_SECONDS=120 start_host "$home"
  wait_until 150 watcher_live "$home" || fail "attended boundary: no initial watcher"
  append_status "$home" 'fixture finished' 'done'
  wait_until 250 host_exited "$home" || fail "attended boundary: no hand-back"
  [ -e "$home/boundary-seam" ] || fail "attended boundary: ordering seam did not run"
  expect_code 0 "$(cat "$home/host.rc")" "attended boundary: hand-back exit"
  [ "$(grep -c '^signal:' "$home/host.out")" -eq 1 ] || fail "attended boundary: wake changed or repeated"
  assert_grep 'demo.status' "$home/state/.wake-queue" "attended boundary: wake was acknowledged"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "attended boundary: engine called"
  assert_absent "$home/state/.supervision-host-left" "attended boundary: a successor was detached after the bound"
  watcher_live "$home" && fail "attended boundary: watcher survived beyond the park boundary"
  pass "host: an attended pass-through reaching its park boundary starts no successor"
}

test_host_retires_an_arm_that_left_its_watcher_stalled() {
  local home arm watcher capture mode=${1:-stopped}
  home=$(make_home "arm-stall-$mode" attended)
  FM_WATCHER_STALL_BOUND=12 start_host "$home"
  wait_until 300 watcher_live "$home" || fail "arm-stall: no watcher started"
  # Past startup: the watcher has published its identity and beaten once.
  wait_until 300 test -s "$home/state/.watch.lock/pid-identity" || fail "arm-stall: the watcher never published its identity"
  wait_until 300 test -e "$home/state/.last-watcher-beat" || fail "arm-stall: the watcher never beat"
  arm=$(awk -F '\t' '$1 == "arm" { print $2; exit }' "$home/state/.supervision-host")
  watcher=$(cat "$home/state/.watch.lock/pid")
  [ -n "$arm" ] && [ -n "$watcher" ] || fail "arm-stall: no recorded arm ($arm) or watcher ($watcher)"
  capture=$(printf '%s\n' "$home"/state/.supervision-host-arm.*)
  [ -f "$capture" ] || fail "arm-stall: no arm capture"
  kill -STOP "$arm" "$watcher"
  if ! wait_until 900 grep -q "	arm-retired	watcher pid $watcher " "$home/state/.supervision-host.log"; then
    kill -KILL "$arm" "$watcher" 2>/dev/null
    fail "the host never retired an arm that left its watcher stalled past the bound"$'\n'"$(cat "$home/state/.supervision-host.log" 2>/dev/null)"
  fi
  [ "$mode" != responsive ] || kill -CONT "$arm" "$watcher"
  wait_until 200 host_exited "$home" || { kill -KILL "$arm" "$watcher" 2>/dev/null; fail "the host did not close the cycle after retiring the arm"; }
  if [ "$mode" = stopped ]; then
    [ "$(cat "$home/host.rc")" != 0 ] || fail "the host accepted an unfinished arm retirement"
    assert_re "watcher arm $arm did not finish retirement" "$home/host.out" "the host must report the retirement refusal"
    kill -0 "$arm" 2>/dev/null || fail "the host killed the arm whose retirement did not finish"
    [ -f "$capture" ] || fail "the host discarded the surviving arm's capture"
    assert_re "^arm	$arm	" "$home/state/.supervision-host" "the host must retain the surviving arm's process record"
    assert_no_re '	pass-through	|	boundary	' "$home/state/.supervision-host.log" "failed retirement must not become a clean close"
    kill -KILL "$arm" 2>/dev/null
  else
    [ "$(cat "$home/host.rc")" = 0 ] || fail "the host failed after retiring a responsive arm"
    kill -0 "$arm" 2>/dev/null && { kill -KILL "$arm" "$watcher" 2>/dev/null; fail "the host left the retired arm $arm running"; }
    assert_absent "$capture" "the host must consume the retired arm's capture"
    assert_re '	pass-through	a close without a wake' "$home/state/.supervision-host.log" "the retired arm's cycle must close without a wake for its owner to re-arm"
  fi
  kill -KILL "$watcher" 2>/dev/null
  stop_home_processes "$home"
  pass "host: a $mode arm's stalled-watcher retirement closes with the correct status and retained evidence"
}

test_host_retires_a_responsive_arm_that_left_its_watcher_stalled() {
  test_host_retires_an_arm_that_left_its_watcher_stalled responsive
}

test_next_park_waits_for_the_previous_successor_to_be_taken_over() {
  local home session waiter early=0
  home=$(make_home park-readiness attended)
  start_session "$home"
  park_again "$home"
  append_status "$home" 'choose the export format' needs-decision
  wait_until 250 host_exited "$home" || fail "readiness: the attended close did not reach main"
  main_drain_and_ack "$home"
  watcher_live "$home" || fail "readiness: the attended close left no live successor"

  # Hold the session before it can take the next park request. The surviving
  # watcher must not make park_again report that this next park is ready.
  session=$(cat "$home/state/.lock")
  kill -STOP "$session"
  (park_again "$home" && : > "$home/park.ready") &
  waiter=$!
  wait_until 10 test -e "$home/park.ready" && early=1
  kill -CONT "$session"
  wait "$waiter" || fail "readiness: the resumed session did not park"
  [ "$early" -eq 0 ] || fail "the next park returned ready on the previous park's successor"
  pass "host: a repeated park waits for takeover before the test can append its next status"
}

# A completed case must not leave polling fixtures competing with later cases.
for host_test in \
  test_cleanup_waits_for_a_stopping_session \
  test_completed_case_stops_its_registered_processes \
  test_host_starts_despite_a_held_lease_command_lock \
  test_dispatch_entry_resolves_an_orca_terminal_stale_row \
  test_attended_pass_through_without_an_engine_keeps_its_successor \
  test_attended_successor_failures_preserve_the_close \
  test_attended_pass_through_at_boundary_starts_no_successor \
  test_host_retires_an_arm_that_left_its_watcher_stalled \
  test_host_retires_a_responsive_arm_that_left_its_watcher_stalled \
  test_next_park_waits_for_the_previous_successor_to_be_taken_over
do
  "$host_test"
  stop_registered_homes
done
