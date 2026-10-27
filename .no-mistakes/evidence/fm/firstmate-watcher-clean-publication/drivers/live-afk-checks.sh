#!/usr/bin/env bash
set -u
ROOT=$PWD
EVIDENCE=/Users/eduardopicazo/.no-mistakes/evidence/01M5WPXNZDE1WCTBNY9HZY8TTC
export TMPDIR="$ROOT/.test-phase-tmp"
unset FM_GATE_REFUSE_BYPASS FM_TEST_SEAM FM_TEST_HARNESS
export FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
export FM_ARM_CONFIRM_TIMEOUT=30
ACTIVE=()
HOME_LIST=()
cleanup() {
  local pid home
  for pid in "${ACTIVE[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
  for home in "${HOME_LIST[@]}"; do
    FM_HOME="$home" bash "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
  done
  for pid in "${ACTIVE[@]}"; do wait "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT
fail() { echo "LIVE FAILURE: $*"; exit 1; }
wait_for() {
  local i=0
  while ! "$@"; do
    i=$((i+1)); [ "$i" -lt 400 ] || return 1
    sleep 0.1
  done
}
ready() { [ -e "$FM_HOME/state/.last-watcher-beat" ] && [ -s "$FM_HOME/state/.watch.lock/pid" ]; }
capture() {
  local name=$1; shift
  local rc=0
  "$@" >"$EVIDENCE/$name.stdout" 2>"$EVIDENCE/$name.stderr" || rc=$?
  echo "$name exit=$rc"
  cat "$EVIDENCE/$name.stdout" "$EVIDENCE/$name.stderr"
  RC=$rc
}
new_home() {
  export FM_HOME="$ROOT/.test-phase-tmp/live-$1"
  bash bin/fm-lab-home.sh create "$FM_HOME" >/dev/null || fail 'mark home'
  HOME_LIST+=("$FM_HOME")
  bash bin/fm-lock.sh || fail 'real Codex session lock'
}
publish() { FM_HOME="$FM_HOME" bash -c '. "$1"; fm_recovery_marker_publish "$STATE/.watcher-down" downtime' _ "$ROOT/bin/fm-wake-lib.sh"; }
append() { FM_HOME="$FM_HOME" bash -c '. "$1"; fm_wake_append check live-row "check: live durable row"' _ "$ROOT/bin/fm-wake-lib.sh"; }

echo "Revision: $(git rev-parse HEAD), harness: $(bash bin/fm-harness.sh)"
new_home away-guidance
touch "$FM_HOME/config/supervision-host"
capture live-away-inactive bash bin/fm-afk-launch.sh enter --words 'disposable live verification; merge nothing'
[ "$RC" -eq 0 ] || fail 'away entry'
grep -q 'Away supervision is not running yet:' "$EVIDENCE/live-away-inactive.stdout" || fail 'inactive checkpoint guidance absent'
capture live-away-protocol bash bin/fm-supervision-instructions.sh --harness codex --afk 1
[ "$RC" -eq 0 ] || fail 'away protocol emission'
grep -q 'foreground.*checkpoint\|checkpoint.*foreground' "$EVIDENCE/live-away-protocol.stdout" || fail 'emitted checkpoint instruction'
bash bin/fm-watch-arm.sh >"$EVIDENCE/live-away-active-arm.stdout" 2>"$EVIDENCE/live-away-active-arm.stderr" &
arm=$!; ACTIVE+=("$arm")
wait_for ready || fail 'away active watcher'
capture live-away-active bash bin/fm-afk-launch.sh enter --words 'disposable live verification; merge nothing'
[ "$RC" -eq 0 ] || fail 'refresh active away entry'
! grep -q 'Away supervision is not running yet:' "$EVIDENCE/live-away-active.stdout" || fail 'healthy watcher wrongly reported inactive'
kill -0 "$(cat "$FM_HOME/state/.watch.lock/pid")" || fail 'away watcher no longer alive'
echo 'LIVE AWAY CHECKS COMPLETE'

