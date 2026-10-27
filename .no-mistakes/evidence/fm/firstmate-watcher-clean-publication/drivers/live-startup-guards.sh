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
new_home invalid-host-startup
touch "$FM_HOME/config/supervision-host"
append || fail 'seed guard queue'
cp "$FM_HOME/state/.wake-queue" "$EVIDENCE/live-invalid-startup.before-queue"
capture live-invalid-startup env FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=invalid bash bin/fm-watch-checkpoint.sh --seconds 4
[ "$RC" -ne 0 ] || fail 'startup refusal claimed success'
cat "$EVIDENCE/live-invalid-startup.stdout" "$EVIDENCE/live-invalid-startup.stderr" | grep -q 'FAILED - FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS must be whole seconds' || fail 'missing startup diagnostic'
cmp "$EVIDENCE/live-invalid-startup.before-queue" "$FM_HOME/state/.wake-queue" || fail 'startup refusal changed queue'
[ ! -s "$FM_HOME/state/.watch.lock/pid" ] || fail 'startup refusal armed watcher'

new_home singleton
bash bin/fm-watch-arm.sh >"$EVIDENCE/live-singleton-owner.stdout" 2>"$EVIDENCE/live-singleton-owner.stderr" &
arm=$!; ACTIVE+=("$arm")
wait_for ready || fail 'singleton owner ready'
before=$(cat "$FM_HOME/state/.watch.lock/pid")
capture live-singleton-refusal bash bin/fm-watch-checkpoint.sh --seconds 2
[ "$RC" -ne 0 ] || fail 'checkpoint adopted unowned singleton'
grep -q 'watcher is already running outside this foreground checkpoint' "$EVIDENCE/live-singleton-refusal.stderr" || fail 'singleton missing diagnostic'
[ "$(cat "$FM_HOME/state/.watch.lock/pid")" = "$before" ] && kill -0 "$before" || fail 'singleton owner changed'
echo 'LIVE STARTUP GUARDS COMPLETE'

