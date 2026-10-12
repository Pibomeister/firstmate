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
export FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=fixture:0
export FM_ESCALATE_BATCH_SECS=0 FM_HOUSEKEEPING_TICK=1 FM_MAX_DEFER_SECS=1
: > "$FM_CONFIG_OVERRIDE/supervision-host-off"
# Public transport seam: affirmative empty composer; any send records and fails.
cat > "$TMP_ROOT/bin/fm-tmux-lib.sh" <<'SH'
fm_tmux_composer_state() { printf empty; }
fm_tmux_submit_core() { printf '%s\n' "$2" >> "$FM_HOME/composer"; return 1; }
SH
cat > "$TMP_ROOT/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_QUIET_SOCKET:-}" ]; then
  exec "$REAL_TMUX" -L "$FM_QUIET_SOCKET" "$@"
fi
case "$1" in
  display-message) printf '0\n' ;;
  capture-pane) printf 'empty fixture composer\n' ;;
  send-keys) printf '%s\n' "$*" >> "$FM_HOME/keys"; exit 1 ;;
esac
SH
cat > "$TMP_ROOT/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
exec sleep 600
SH
chmod +x "$TMP_ROOT/bin/fm-watch.sh" "$TMP_ROOT/fakebin/tmux"
export PATH="$TMP_ROOT/fakebin:$PATH"
pid=
stop_daemon() {
  if [ -n "$pid" ]; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" || true; pid=; fi
}
cleanup() {
  stop_daemon
  if [ -n "${FM_QUIET_SOCKET:-}" ]; then
    "$REAL_TMUX" -L "$FM_QUIET_SOCKET" kill-server 2>/dev/null || true
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
FM_AFK_MODE=quiet bash "$TMP_ROOT/bin/fm-afk-contract.sh" enter >/dev/null
printf 'quiet\n%s\n' "$(date +%s)" > "$FM_STATE_OVERRIDE/.afk"
printf 'blocked nonce: private full detail\n' > "$FM_STATE_OVERRIDE/.subsuper-escalations"
date +%s > "$FM_STATE_OVERRIDE/.subsuper-escalations.since"
start_daemon
stop_daemon
[ ! -e "$FM_HOME/composer" ] && [ ! -e "$FM_HOME/keys" ] || fail 'quiet daemon wrote composer'
grep -qx 'blocked nonce: private full detail' "$FM_STATE_OVERRIDE/.subsuper-escalations" || fail 'quiet daemon lost detail'
[ ! -e "$FM_STATE_OVERRIDE/.subsuper-inject-wedged" ] || fail 'quiet produced transport wedge alarm'
rm -f "$FM_STATE_OVERRIDE/.subsuper-last-housekeep"
start_daemon
stop_daemon
grep -qx 'blocked nonce: private full detail' "$FM_STATE_OVERRIDE/.subsuper-escalations" || fail 'direct restart lost detail'
bash "$TMP_ROOT/bin/fm-afk-launch.sh" start-native >/dev/null 2>&1
grep -qx 'blocked nonce: private full detail' "$FM_STATE_OVERRIDE/.subsuper-escalations" || fail 'launcher restart erased detail'
[ ! -e "$FM_HOME/composer" ] && [ ! -e "$FM_HOME/keys" ] || fail 'restart wrote composer'
pass 'quiet executable daemon batching, restart, shutdown and launcher preserve detail without composer send'

if [ -n "$REAL_TMUX" ]; then
  export FM_QUIET_SOCKET="fm-quiet-test-$$"
  "$REAL_TMUX" -L "$FM_QUIET_SOCKET" new-session -d -s supervisor
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
