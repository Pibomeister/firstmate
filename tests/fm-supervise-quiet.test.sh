#!/usr/bin/env bash
# Executable quiet daemon and launcher regressions with an isolated send recorder.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-supervise-quiet)
SOURCE_ROOT=${FM_QUIET_TEST_SOURCE:-$ROOT}
REAL_TMUX=$(command -v tmux || true)
export REAL_TMUX
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/home/state" "$TMP_ROOT/home/config" "$TMP_ROOT/fakebin"
cp -R "$SOURCE_ROOT/bin/." "$TMP_ROOT/bin/"
export FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$TMP_ROOT/home/state"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/home/config" FM_TEST_HARNESS=claude
export FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=%42
export FM_ESCALATE_BATCH_SECS=0 FM_HOUSEKEEPING_TICK=1 FM_MAX_DEFER_SECS=1
: > "$FM_CONFIG_OVERRIDE/supervision-host-off"
# Public transport seam: affirmative empty composer; any send records and fails.
cat > "$TMP_ROOT/bin/fm-tmux-lib.sh" <<'SH'
fm_tmux_composer_state() { printf empty; }
fm_tmux_submit_core() { printf '%s\n' "$2" >> "$FM_HOME/composer"; return 1; }
SH
cat > "$TMP_ROOT/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
shim_dir=$(cd "$(dirname "$0")" && pwd)
if [ -f "$shim_dir/tmux-socket" ]; then
  exec "$(cat "$shim_dir/real-tmux")" -f /dev/null -S "$(cat "$shim_dir/tmux-socket")" "$@"
fi
case "$1" in
  list-panes) printf '%%42\n' ;;
  display-message) printf '0\n' ;;
  capture-pane) printf 'empty fixture composer\n' ;;
  send-keys) printf '%s\n' "$*" >> "$FM_HOME/keys"; exit 1 ;;
esac
SH
cat > "$TMP_ROOT/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_HOME/emit-status" ]; then
  rm "$FM_HOME/emit-status"
  printf 'signal: %s/quiet-task.status\n' "$FM_HOME/state"
  exit 0
fi
exec sleep 600
SH
# Existing notifier seam records the non-composer alert instead of posting it.
cat > "$TMP_ROOT/fakebin/alarm" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "$2" >> "$FM_HOME/alarms"
SH
export FM_WEDGE_ALARM_EXEC="$TMP_ROOT/fakebin/alarm" FM_WEDGE_ALARM_CHANNEL=command:fixture
chmod +x "$TMP_ROOT/bin/fm-watch.sh" "$TMP_ROOT/fakebin/tmux" "$TMP_ROOT/fakebin/alarm"
export PATH="$TMP_ROOT/fakebin:$PATH"
pid=
stop_daemon() {
  if [ -n "$pid" ]; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" || true; pid=; fi
}
cleanup() {
  stop_daemon
  if [ -n "${FM_QUIET_SOCKET:-}" ]; then
    "$REAL_TMUX" -S "$FM_QUIET_SOCKET" kill-server 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT
start_daemon() {
  bash "$TMP_ROOT/bin/fm-supervise-daemon.sh" > "$TMP_ROOT/daemon.out" 2>&1 &
  pid=$!
  for _ in $(seq 1 60); do
    [ -f "$FM_STATE_OVERRIDE/.subsuper-last-housekeep" ] && break
    kill -0 "$pid" 2>/dev/null || fail "daemon exited: $(cat "$TMP_ROOT/daemon.out")"
    sleep 0.1
  done
  [ -f "$FM_STATE_OVERRIDE/.subsuper-last-housekeep" ] || fail 'daemon never ran housekeeping'
  sleep 2
}
# Delivery is conservative even when only one damaged or contradictory signal
# says quiet. Exit is stricter and requires a validated, consistent record.
FM_AFK_MODE=quiet bash "$TMP_ROOT/bin/fm-afk-contract.sh" enter >/dev/null
cp "$FM_STATE_OVERRIDE/.afk-contract" "$TMP_ROOT/quiet-record"
for posture in flag-only invalid-record record-only contradictory-away contradictory-quiet malformed-flag directory-flag duplicate-mode; do
  rm -rf "$FM_STATE_OVERRIDE/.afk" "$FM_STATE_OVERRIDE/.afk-contract"
  case "$posture" in
    flag-only) printf 'quiet\n' > "$FM_STATE_OVERRIDE/.afk" ;;
    invalid-record) printf 'mode: quiet\n' > "$FM_STATE_OVERRIDE/.afk-contract" ;;
    record-only) cp "$TMP_ROOT/quiet-record" "$FM_STATE_OVERRIDE/.afk-contract" ;;
    contradictory-away)
      cp "$TMP_ROOT/quiet-record" "$FM_STATE_OVERRIDE/.afk-contract"
      printf 'away\n' > "$FM_STATE_OVERRIDE/.afk" ;;
    contradictory-quiet)
      FM_AFK_MODE=away bash "$TMP_ROOT/bin/fm-afk-contract.sh" enter >/dev/null
      printf 'quiet\n' > "$FM_STATE_OVERRIDE/.afk" ;;
    malformed-flag)
      cp "$TMP_ROOT/quiet-record" "$FM_STATE_OVERRIDE/.afk-contract"
      printf 'garbage\n' > "$FM_STATE_OVERRIDE/.afk" ;;
    directory-flag)
      cp "$TMP_ROOT/quiet-record" "$FM_STATE_OVERRIDE/.afk-contract"
      mkdir "$FM_STATE_OVERRIDE/.afk" ;;
    duplicate-mode)
      { printf 'mode: quiet\n'; cat "$TMP_ROOT/quiet-record"; } > "$FM_STATE_OVERRIDE/.afk-contract" ;;
  esac
  printf 'preserved detail\n' > "$FM_STATE_OVERRIDE/.subsuper-escalations"
  bash -c '
    . "$1/bin/fm-supervise-daemon.sh"
    inject_msg "must not submit" "$FM_STATE_OVERRIDE" && exit 1
    [ "$INJECT_SUBMIT_ATTEMPTED" -eq 0 ] || exit 1
    escalate_flush "$FM_STATE_OVERRIDE" || exit 1
  ' _ "$TMP_ROOT" || fail "quiet delivery predicate failed: $posture"
  grep -qx 'preserved detail' "$FM_STATE_OVERRIDE/.subsuper-escalations" || fail "flush lost detail: $posture"
  if FM_HOME="$FM_HOME" bash "$TMP_ROOT/bin/fm-afk-return.sh" guard >/dev/null 2>&1; then
    [ "$posture" = record-only ] || fail "quiet guard accepted $posture"
  else
    [ "$posture" != record-only ] || fail 'quiet guard rejected validated record'
  fi
done
[ ! -e "$FM_HOME/composer" ] && [ ! -e "$FM_HOME/keys" ] || fail 'inconsistent quiet signals wrote composer'
rm -f "$FM_STATE_OVERRIDE/.afk" "$FM_STATE_OVERRIDE/.afk-contract"
pass 'quiet delivery suppression accepts either signal; quiet guard requires validated consistent state'

FM_AFK_MODE=quiet bash "$TMP_ROOT/bin/fm-afk-contract.sh" enter >/dev/null
printf 'quiet\n%s\n' "$(date +%s)" > "$FM_STATE_OVERRIDE/.afk"
printf 'private throttle detail\n' > "$FM_STATE_OVERRIDE/.subsuper-escalations"
printf '1999999880\n' > "$FM_STATE_OVERRIDE/.subsuper-escalations.since"
FM_MAX_DEFER_SECS=60 bash -c '
  . "$1/bin/fm-supervise-daemon.sh"
  test_now=2000000000
  _now() { printf "%s\n" "$test_now"; }
  housekeeping "$FM_STATE_OVERRIDE"
  housekeeping "$FM_STATE_OVERRIDE"
  test_now=2000000059
  housekeeping "$FM_STATE_OVERRIDE"
  [ "$(wc -l < "$FM_HOME/alarms" | tr -d " ")" -eq 1 ] || exit 1
  test_now=2000000060
  housekeeping "$FM_STATE_OVERRIDE"
  [ "$(wc -l < "$FM_HOME/alarms" | tr -d " ")" -eq 2 ] || exit 1
' _ "$TMP_ROOT" || fail 'quiet alarm did not throttle by the max-defer window'
[ ! -e "$FM_STATE_OVERRIDE/.subsuper-inject-wedged" ] || fail 'throttled quiet alarm wrote a wedge marker'
! grep -q 'private throttle detail' "$FM_HOME/alarms" || fail 'throttled alert exposed detail'
rm "$FM_HOME/alarms"
pass 'quiet alarm repeats only after a full max-defer window without copying detail'
printf 'blocked nonce: private full detail\n' > "$FM_STATE_OVERRIDE/.subsuper-escalations"
date +%s > "$FM_STATE_OVERRIDE/.subsuper-escalations.since"
printf 'blocked [key=quiet-status]: private-status-nonce-92741\n' > "$FM_STATE_OVERRIDE/quiet-task.status"
date +%s > "$FM_STATE_OVERRIDE/.subsuper-last-scan"
: > "$FM_HOME/emit-status"
start_daemon
for _ in $(seq 1 200); do
  grep -q 'escalate: signal: .*quiet-task.status -> detail retained in durable state' "$FM_STATE_OVERRIDE/.supervise-daemon.log" && break
  sleep 0.1
done
grep -q private-status-nonce-92741 "$FM_STATE_OVERRIDE/.subsuper-escalations" || fail 'actual status wake did not reach buffer'
stop_daemon
[ ! -e "$FM_HOME/composer" ] && [ ! -e "$FM_HOME/keys" ] || fail 'quiet daemon wrote composer'
grep -qx 'blocked nonce: private full detail' "$FM_STATE_OVERRIDE/.subsuper-escalations" || fail 'quiet daemon lost detail'
[ ! -e "$FM_STATE_OVERRIDE/.subsuper-inject-wedged" ] || fail 'quiet produced transport wedge alarm'
grep -q '|quiet supervision retained escalations' "$FM_HOME/alarms" 2>/dev/null || fail 'quiet backlog raised no non-composer alert'
log_file="$FM_STATE_OVERRIDE/.supervise-daemon.log"
grep -q 'daemon starting' "$log_file" || fail 'quiet suppressed startup diagnostics'
grep -q 'daemon shutting down' "$log_file" || fail 'quiet suppressed lifecycle diagnostics'
! grep -q 'private full detail' "$FM_HOME/alarms" "$log_file" || fail 'quiet alert or log exposed raw detail'
grep -q 'escalate: signal: .*quiet-task.status -> detail retained in durable state' "$log_file" || fail "actual wake classification was not logged: $(cat "$log_file")"
! grep -q private-status-nonce-92741 "$FM_HOME/alarms" "$log_file" "$TMP_ROOT/daemon.out" || fail 'status wake leaked detail into diagnostics'
rm -f "$FM_STATE_OVERRIDE/.subsuper-last-housekeep"
start_daemon
stop_daemon
grep -qx 'blocked nonce: private full detail' "$FM_STATE_OVERRIDE/.subsuper-escalations" || fail 'direct restart lost detail'
bash "$TMP_ROOT/bin/fm-afk-launch.sh" start-native >/dev/null 2>&1
grep -qx 'blocked nonce: private full detail' "$FM_STATE_OVERRIDE/.subsuper-escalations" || fail 'launcher restart erased detail'
[ ! -e "$FM_HOME/composer" ] && [ ! -e "$FM_HOME/keys" ] || fail 'restart wrote composer'
pass 'quiet executable daemon batching, restart, shutdown and launcher preserve detail without composer send'

if [ -n "$REAL_TMUX" ]; then
  # Use a short private socket path; no operation addresses the operator server.
  export FM_QUIET_SOCKET="/tmp/fm-quiet-$$.sock"
  printf '%s\n' "$FM_QUIET_SOCKET" > "$TMP_ROOT/fakebin/tmux-socket"
  printf '%s\n' "$REAL_TMUX" > "$TMP_ROOT/fakebin/real-tmux"
  "$REAL_TMUX" -f /dev/null -S "$FM_QUIET_SOCKET" new-session -d -s supervisor
  export FM_SUPERVISOR_TARGET=supervisor:0
  # The launcher uses a login shell; restore the private-socket shim at its entry.
  cat > "$TMP_ROOT/bin/quiet-launch-entry.sh" <<'SH'
#!/usr/bin/env bash
entry_dir=$(cd "$(dirname "$0")" && pwd)
export PATH="$entry_dir/../fakebin:$PATH"
exec "$entry_dir/fm-afk-start.sh"
SH
  chmod +x "$TMP_ROOT/bin/quiet-launch-entry.sh"
  export FM_AFK_LAUNCH_ENTRY="$TMP_ROOT/bin/quiet-launch-entry.sh"
  for round in 1 2; do
    rm -f "$FM_STATE_OVERRIDE/.subsuper-last-housekeep"
    bash "$TMP_ROOT/bin/fm-afk-launch.sh" start > "$TMP_ROOT/launch-$round.out" 2>&1 \
      || fail "private tmux launcher failed: $(cat "$TMP_ROOT/launch-$round.out")"
    for _ in $(seq 1 80); do
      [ -f "$FM_STATE_OVERRIDE/.subsuper-last-housekeep" ] && break
      sleep 0.1
    done
    [ -f "$FM_STATE_OVERRIDE/.subsuper-last-housekeep" ] || fail 'launcher did not run actual daemon'
    pid=$(cat "$FM_STATE_OVERRIDE/.supervise-daemon.pid")
    kill -TERM "$pid"
    for _ in $(seq 1 80); do
      [ ! -e "$FM_STATE_OVERRIDE/.supervise-daemon.pid" ] && break
      sleep 0.1
    done
    [ ! -e "$FM_STATE_OVERRIDE/.supervise-daemon.pid" ] || fail 'actual daemon failed to stop'
    pid=
    grep -qx 'blocked nonce: private full detail' "$FM_STATE_OVERRIDE/.subsuper-escalations" \
      || fail 'real same-posture launcher restart lost detail'
  done
  bash "$TMP_ROOT/bin/fm-afk-launch.sh" stop >/dev/null 2>&1
  [ ! -e "$FM_HOME/composer" ] && [ ! -e "$FM_HOME/keys" ] || fail 'private tmux lifecycle wrote composer'
  pass 'real private tmux same-posture launcher restart preserves detail without model calls'
else
  printf 'skip: real private tmux launcher evidence unavailable (tmux absent)\n'
fi
