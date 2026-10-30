#!/usr/bin/env bash
# The independent owner must restore coverage after each observed dead cycle.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

# shellcheck disable=SC2034 # make_case uses this shared fixture root.
TMP_ROOT=$(fm_test_tmproot fm-monitor-watchdog-tests)
WATCHDOG="$ROOT/bin/fm-monitor-watchdog.sh"
WATCH="$ROOT/bin/fm-watch.sh"

healthy_pid() {  # <home>
  local home=$1 pid
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_watcher_healthy "$2" "$3" 10 "$4" || exit 1
    printf "%s\n" "$FM_WATCHER_HEALTHY_PID"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$WATCH" "$home"
}

wait_healthy() {  # <home> [different-from-pid]
  local home=$1 old=${2:-} pid i
  for i in $(seq 1 100); do
    pid=$(healthy_pid "$home" 2>/dev/null || true)
    if [ -n "$pid" ] && [ "$pid" != "$old" ]; then
      printf '%s\n' "$pid"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

start_owner() {  # <home>
  local home=$1
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 \
    FM_GUARD_GRACE=10 FM_ARM_CONFIRM_TIMEOUT=5 \
    bash "$WATCHDOG" run > "$home/watchdog.out" 2>&1 &
  OWNER_PID=$!
}

stop_owner() {
  kill -TERM "$OWNER_PID" 2>/dev/null || true
  wait "$OWNER_PID" 2>/dev/null || true
}

drain_and_ack() {  # <home>
  local home=$1 err sequence generation
  err="$home/drain.err"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash "$ROOT/bin/fm-wake-drain.sh" \
    > "$home/drain.out" 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash "$ROOT/bin/fm-wake-drain.sh" \
    --ack-through "$sequence" --recovery-generation "$generation" >/dev/null
}

test_actionable_close_without_successor() {
  local home first second
  home=$(make_case actionable-close)
  mkdir -p "$home/config"
  start_owner "$home"
  first=$(wait_healthy "$home") || fail "independent owner did not start a watcher: $(cat "$home/watchdog.out")"
  cat > "$home/state/probe.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'done: one actionable close\n'
SH
  chmod 0700 "$home/state/probe.check.sh"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash "$ROOT/bin/fm-check-register.sh" probe >/dev/null \
    || fail "could not register actionable check"
  for _ in $(seq 1 100); do
    grep -q 'reason=actionable-check' "$home/state/.watch-cycle-exits.log" 2>/dev/null && break
    sleep 0.1
  done
  grep -q 'reason=actionable-check' "$home/state/.watch-cycle-exits.log" 2>/dev/null \
    || fail "watcher did not close on the actionable check"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash "$ROOT/bin/fm-check-unregister.sh" probe >/dev/null \
    || fail "could not unregister actionable check"
  drain_and_ack "$home" || fail "could not acknowledge actionable close"
  second=$(wait_healthy "$home" "$first") || fail "no successor after actionable close: $(cat "$home/watchdog.out")"
  [ "$second" != "$first" ] || fail "actionable close kept the old watcher pid"
  stop_owner
  pass "independent owner restores watcher after actionable close"
}

test_dead_owner_lock() {
  local home dead current
  home=$(make_case dead-lock)
  mkdir -p "$home/config" "$home/state/.watch.lock"
  dead=999999
  while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
  printf '%s\n' "$dead" > "$home/state/.watch.lock/pid"
  start_owner "$home"
  current=$(wait_healthy "$home") || fail "dead-owner lock was not recovered: $(cat "$home/watchdog.out")"
  [ "$current" != "$dead" ] || fail "dead-owner pid remained the lock owner"
  stop_owner
  pass "independent owner reclaims a dead watch lock"
}

test_term_without_successor() {
  local home first second
  home=$(make_case term-no-successor)
  mkdir -p "$home/config"
  start_owner "$home"
  first=$(wait_healthy "$home") || fail "independent owner did not start a watcher: $(cat "$home/watchdog.out")"
  kill -TERM "$first" || fail "could not TERM this home's watcher"
  second=$(wait_healthy "$home" "$first") || fail "no successor after watcher TERM: $(cat "$home/watchdog.out")"
  [ "$second" != "$first" ] || fail "TERM did not replace watcher"
  stop_owner
  pass "independent owner restores watcher after TERM"
}

test_page_channel_result() {
  local home result
  home=$(make_case page-result)
  mkdir -p "$home/config"
  result="$home/page"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_WEDGE_ALARM_CHANNEL=off python3 - "$ROOT/bin/fm-supervise-daemon.sh" "$result" <<'PY'
import os
import signal
import subprocess
import sys

script, result = sys.argv[1:]
with open(result + '.out', 'w') as out, open(result + '.err', 'w') as err:
    proc = subprocess.Popen(['bash', script, 'page', 'watcher recovery failed', result],
                            stdout=out, stderr=err, start_new_session=True)
    try:
        code = proc.wait(timeout=8)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
        code = 124
with open(result + '.rc', 'w') as receipt:
    receipt.write(str(code) + '\n')
PY
  [ "$(cat "$result.rc")" = 2 ] \
    || fail "missing channel did not return page-pending: rc=$(cat "$result.rc") $(cat "$result.out" "$result.err")"
  grep -q '^page: pending$' "$result.out" \
    || fail "missing channel falsely claimed a page: $(cat "$result.out" "$result.err")"
  pass "missing page channel returns a typed pending result"
}

test_failed_rearm_records_pending_page() {
  local home arm i alert
  home=$(make_case failed-rearm)
  mkdir -p "$home/config"
  arm="$home/failing-arm.sh"
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
echo 'watcher: FAILED - fixture arm could not start'
exit 1
SH
  chmod 0700 "$arm"
  FM_TEST_WATCHDOG_ARM="$arm" FM_WEDGE_ALARM_CHANNEL=off start_owner "$home"
  alert="$home/state/.monitor-watchdog-alert"
  for _ in $(seq 1 50); do
    [ -f "$alert" ] && break
    sleep 0.1
  done
  stop_owner
  [ -f "$alert" ] || fail "failed rearm left no durable alert: $(cat "$home/watchdog.out")"
  grep -q 'page=pending' "$alert" || fail "missing channel was not marked pending: $(cat "$alert")"
  pass "failed rearm records pending page without claiming delivery"
}

test_two_home_term_isolation() {
  local first_home second_home first second replacement first_owner second_owner still
  first_home=$(make_case term-home-a)
  second_home=$(make_case term-home-b)
  mkdir -p "$first_home/config" "$second_home/config"
  start_owner "$first_home"; first_owner=$OWNER_PID
  start_owner "$second_home"; second_owner=$OWNER_PID
  first=$(wait_healthy "$first_home") || fail 'first home has no watcher'
  second=$(wait_healthy "$second_home") || fail 'second home has no watcher'
  kill -TERM "$first" || fail 'could not TERM first home watcher'
  replacement=$(wait_healthy "$first_home" "$first") || fail 'first home was not recovered'
  still=$(healthy_pid "$second_home") || fail 'second home lost its watcher'
  [ "$still" = "$second" ] || fail 'recovery replaced the other home watcher'
  OWNER_PID=$first_owner; stop_owner
  OWNER_PID=$second_owner; stop_owner
  [ "$replacement" != "$second" ] || fail 'homes share a watcher'
  pass 'TERM recovery is confined to the affected home'
}

test_stalled_watcher_bound() {
  local home first replacement i
  home=$(make_case stalled-watcher)
  mkdir -p "$home/config"
  FM_WATCHER_STALL_BOUND=3 start_owner "$home"
  first=$(wait_healthy "$home") || fail 'stalled case did not start a watcher'
  kill -STOP "$first" || fail 'could not freeze the watcher'
  sleep 1
  kill -0 "$first" 2>/dev/null || fail 'watcher was replaced before the stall bound'
  replacement=
  for i in $(seq 1 200); do
    replacement=$(healthy_pid "$home" 2>/dev/null || true)
    [ -n "$replacement" ] && [ "$replacement" != "$first" ] && break
    sleep 0.1
  done
  if [ -z "$replacement" ] || [ "$replacement" = "$first" ]; then
    kill -CONT "$first" 2>/dev/null || true
    fail "stalled watcher was not replaced: $(cat "$home/watchdog.out")"
  fi
  stop_owner
  pass 'stale beacon is replaced after the bounded stall check'
}

test_configured_page_results() {
  local home out rc
  home=$(make_case configured-page)
  mkdir -p "$home/config"
  out=$(env -u FM_WEDGE_ALARM_EXEC FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_WEDGE_ALARM_CHANNEL=command:true \
    bash "$ROOT/bin/fm-supervise-daemon.sh" page 'watcher recovery failed' "$home/state/alert")
  [ "$out" = 'page: sent' ] || fail "working notifier was not confirmed: $out"
  rc=0
  out=$(env -u FM_WEDGE_ALARM_EXEC FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_WEDGE_ALARM_CHANNEL=command:false \
    bash "$ROOT/bin/fm-supervise-daemon.sh" page 'watcher recovery failed' "$home/state/alert") || rc=$?
  [ "$rc" -eq 1 ] && [ "$out" = 'page: failed' ] \
    || fail "failed notifier was misreported: rc=$rc result=$out"
  pass 'configured notifier records actual success and failure'
}

case "${1:-all}" in
  actionable) test_actionable_close_without_successor ;;
  dead-lock) test_dead_owner_lock ;;
  term) test_term_without_successor ;;
  page) test_page_channel_result ;;
  failure-page) test_failed_rearm_records_pending_page ;;
  two-home) test_two_home_term_isolation ;;
  stalled) test_stalled_watcher_bound ;;
  configured-page) test_configured_page_results ;;
  all)
    test_actionable_close_without_successor
    test_dead_owner_lock
    test_term_without_successor
    test_page_channel_result
    test_failed_rearm_records_pending_page
    test_two_home_term_isolation
    test_stalled_watcher_bound
    test_configured_page_results ;;
  *) fail "unknown case: $1" ;;
esac
