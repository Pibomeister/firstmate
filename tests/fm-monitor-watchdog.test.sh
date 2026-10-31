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
  local home first second arm_pid still queued
  home=$(make_case actionable-close)
  mkdir -p "$home/config"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_POLL=1 FM_GUARD_GRACE=10 bash "$ROOT/bin/fm-watch-arm.sh" > "$home/arm.out" 2>&1 &
  arm_pid=$!
  first=$(wait_healthy "$home") || fail 'plain arm did not start a watcher'
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
  wait "$arm_pid" || fail 'plain arm did not finish its actionable cycle'
  [ -z "$(healthy_pid "$home" 2>/dev/null || true)" ] || fail 'plain arm left a successor before recovery'
  start_owner "$home"
  second=$(wait_healthy "$home" "$first") || fail "no successor after actionable close: $(cat "$home/watchdog.out")"
  [ "$second" != "$first" ] || fail "actionable close kept the old watcher pid"
  queued=$(wc -l < "$home/state/.wake-queue" | tr -d ' ')
  [ "$queued" -ge 1 ] || fail 'recovery consumed the unacknowledged wake'
  sleep 3
  still=$(healthy_pid "$home") || fail 'managed successor did not stay live'
  [ "$still" = "$second" ] || fail 'managed successor was replaced during the unacknowledged wake'
  stop_owner
  pass "independent owner restores a stable watcher after actionable close without ack"
}

test_unacked_actionable_close_stability() {
  local home first count second deliveries
  home=$(make_case unacked-actionable)
  mkdir -p "$home/config"
  start_owner "$home"
  first=$(wait_healthy "$home") || fail 'unacked case did not start a watcher'
  cat > "$home/state/probe.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'done: one actionable close\n'
SH
  chmod 0700 "$home/state/probe.check.sh"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash "$ROOT/bin/fm-check-register.sh" probe >/dev/null
  for _ in $(seq 1 100); do
    [ -s "$home/state/.wake-queue" ] && break
    sleep 0.1
  done
  [ -s "$home/state/.wake-queue" ] || fail 'managed watcher did not publish actionable wake'
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash "$ROOT/bin/fm-check-unregister.sh" probe >/dev/null
  sleep 3
  count=$(wc -l < "$home/state/.wake-queue" | tr -d ' ')
  deliveries=$(wc -l < "$home/state/.watch-deliveries.log" | tr -d ' ')
  second=$(healthy_pid "$home" 2>/dev/null || true)
  stop_owner
  [ "$second" = "$first" ] || fail "unacknowledged wake lost the managed watcher (queue=$count)"
  [ "$count" -eq 1 ] || fail "unacknowledged wake duplicated $count queued rows"
  [ "$deliveries" -eq 1 ] || fail "managed watcher delivered $deliveries notifications: $(cut -f3 "$home/state/.watch-deliveries.log" | tr '\n' ';')"
  pass 'unacknowledged actionable wake retains stable watcher coverage'
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

test_healthy_owner_and_takeover() {
  local home first first_owner second_owner rc still arm_pid
  home=$(make_case healthy-owner)
  mkdir -p "$home/config"
  start_owner "$home"; first_owner=$OWNER_PID
  first=$(wait_healthy "$home") || fail 'healthy owner did not start a watcher'
  start_owner "$home"; second_owner=$OWNER_PID
  rc=0; wait "$second_owner" || rc=$?
  [ "$rc" -ne 0 ] || fail 'a second independent owner acquired the same home'
  still=$(healthy_pid "$home") || fail 'duplicate owner disturbed the watcher'
  [ "$still" = "$first" ] || fail 'duplicate owner replaced a healthy watcher'
  OWNER_PID=$first_owner; stop_owner

  home=$(make_case healthy-takeover)
  mkdir -p "$home/config"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_POLL=1 FM_GUARD_GRACE=10 bash "$ROOT/bin/fm-watch-arm.sh" > "$home/arm.out" 2>&1 &
  arm_pid=$!
  first=$(wait_healthy "$home") || fail 'existing arm did not start a watcher'
  start_owner "$home"
  sleep 2
  still=$(healthy_pid "$home") || fail 'watchdog did not attach to healthy predecessor'
  [ "$still" = "$first" ] || fail 'watchdog replaced a healthy predecessor'
  stop_owner
  kill -TERM "$arm_pid" 2>/dev/null || true
  wait "$arm_pid" 2>/dev/null || true
  pass 'healthy owner and healthy take-over retain one watcher'
}

test_alert_clears_after_recovery() {
  local home arm i current
  home=$(make_case alert-clears)
  mkdir -p "$home/config"
  printf 'off\n' > "$home/config/wedge-alarm"
  arm="$home/two-failures-then-arm.sh"
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
count=$(cat "$FM_STATE_OVERRIDE/attempts" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s\n' "$count" > "$FM_STATE_OVERRIDE/attempts"
if [ "$count" -le 2 ]; then echo 'watcher: FAILED - fixture failure'; exit 1; fi
exec bash "$FM_TEST_REAL_ARM"
SH
  chmod 0700 "$arm"
  FM_TEST_WATCHDOG_ARM="$arm" FM_TEST_REAL_ARM="$ROOT/bin/fm-watch-arm.sh" start_owner "$home"
  current=$(wait_healthy "$home") || fail "watcher did not recover: $(cat "$home/watchdog.out")"
  for i in $(seq 1 50); do
    [ ! -f "$home/state/.monitor-watchdog-alert" ] && break
    sleep 0.1
  done
  [ ! -f "$home/state/.monitor-watchdog-alert" ] || fail 'recovered watcher left stale failure alert'
  [ "$(cat "$home/state/attempts")" -ge 3 ] || fail 'fixture did not exercise two failed arms'
  [ -n "$current" ] || fail 'recovered watcher identity missing'
  stop_owner
  pass 'successful recovery retires the prior failure alert'
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

test_failed_rearm_retries_pending_page() {
  local home arm alert i
  home=$(make_case retry-page)
  mkdir -p "$home/config"
  printf 'off\n' > "$home/config/wedge-alarm"
  arm="$home/failing-arm.sh"
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
echo 'watcher: FAILED - fixture arm could not start'
exit 1
SH
  chmod 0700 "$arm"
  FM_TEST_WATCHDOG_ARM="$arm" FM_MONITOR_ALERT_RETRY_SECS=2 start_owner "$home"
  alert="$home/state/.monitor-watchdog-alert"
  for i in $(seq 1 80); do
    grep -q 'page=pending' "$alert" 2>/dev/null && break
    sleep 0.1
  done
  grep -q 'page=pending' "$alert" 2>/dev/null || fail 'initial pending page was not recorded'
  printf 'command:true\n' > "$home/config/wedge-alarm"
  for i in $(seq 1 80); do
    grep -q 'page=sent' "$alert" 2>/dev/null && break
    sleep 0.1
  done
  stop_owner
  grep -q 'page=sent' "$alert" 2>/dev/null || fail 'configured channel did not retry pending watcher page'
  pass 'failed rearm retries a pending page after channel configuration'
}

case "${1:-all}" in
  actionable) test_actionable_close_without_successor ;;
  unacked) test_unacked_actionable_close_stability ;;
  dead-lock) test_dead_owner_lock ;;
  healthy) test_healthy_owner_and_takeover ;;
  alert-clear) test_alert_clears_after_recovery ;;
  term) test_term_without_successor ;;
  page) test_page_channel_result ;;
  failure-page) test_failed_rearm_records_pending_page ;;
  two-home) test_two_home_term_isolation ;;
  stalled) test_stalled_watcher_bound ;;
  configured-page) test_configured_page_results ;;
  retry-page) test_failed_rearm_retries_pending_page ;;
  all)
    test_actionable_close_without_successor
    test_unacked_actionable_close_stability
    test_dead_owner_lock
    test_healthy_owner_and_takeover
    test_alert_clears_after_recovery
    test_term_without_successor
    test_page_channel_result
    test_failed_rearm_records_pending_page
    test_two_home_term_isolation
    test_stalled_watcher_bound
    test_configured_page_results
    test_failed_rearm_retries_pending_page ;;
  *) fail "unknown case: $1" ;;
esac
