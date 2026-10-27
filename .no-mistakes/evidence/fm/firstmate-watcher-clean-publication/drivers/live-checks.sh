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

echo "Revision: $(git rev-parse HEAD)"
echo "Harness: $(bash bin/fm-harness.sh)"

new_home quiet
capture live-quiet bash bin/fm-watch-checkpoint.sh --seconds 2
[ "$RC" -eq 0 ] || fail 'quiet checkpoint exit'
grep -q '^checkpoint: no actionable wake within 2s$' "$EVIDENCE/live-quiet.stdout" || fail 'quiet line'
[ ! -s "$FM_HOME/state/.watch.lock/pid" ] || fail 'quiet leaked watcher lock'

new_home empty-recovery
publish || fail 'publish empty recovery'
before=$(cat "$FM_HOME/state/.watcher-down")
bash bin/fm-watch-arm.sh >"$EVIDENCE/live-empty-arm.stdout" 2>"$EVIDENCE/live-empty-arm.stderr" &
arm=$!; ACTIVE+=("$arm")
wait_for ready || fail 'empty arm ready'
after=$(cat "$FM_HOME/state/.watcher-down")
printf 'before=%s\nafter=%s\nqueue_bytes=%s\n' "$before" "$after" "$(wc -c <"$FM_HOME/state/.wake-queue" 2>/dev/null || echo 0)" | tee "$EVIDENCE/live-empty-recovery.state"
[ "$after" = "acked:downtime:${before##*:}" ] || fail 'empty recovery did not retire on same generation'
kill -0 "$arm" || fail 'empty arm woke for bookkeeping'
append || fail 'concurrent append'
rc=0; wait "$arm" || rc=$?
echo "live concurrent append arm exit=$rc"
cat "$EVIDENCE/live-empty-arm.stdout" "$EVIDENCE/live-empty-arm.stderr"
cp "$FM_HOME/state/.wake-queue" "$EVIDENCE/live-concurrent-append.queue"
[ "$rc" -eq 0 ] || fail 'concurrent append failure'
grep -q '^check: rearm-resurface$' "$EVIDENCE/live-empty-arm.stdout" || fail 'concurrent append lost wake'

new_home buried
publish && append || fail 'seed pending durable wake'
capture live-buried-first bash bin/fm-watch-checkpoint.sh --seconds 4
[ "$RC" -eq 0 ] || fail 'buried recovery exit'
grep -q '^check: rearm-resurface$' "$EVIDENCE/live-buried-first.stdout" || fail 'buried wake lost'
before=$(cat "$FM_HOME/state/.watcher-down")
capture live-buried-second bash bin/fm-watch-checkpoint.sh --seconds 2
[ "$RC" -eq 0 ] || fail 'announced recovery repeat exit'
grep -q '^checkpoint:' "$EVIDENCE/live-buried-second.stdout" || fail 'repeated announced wake'
[ "$(cat "$FM_HOME/state/.watcher-down")" = "$before" ] || fail 'announced generation moved'
cp "$FM_HOME/state/.wake-queue" "$EVIDENCE/live-buried.queue"

new_home interrupted
FM_HOME="$FM_HOME" bash -c '
  . "$1"
  fm_lock_acquire_wait "$STATE/.watcher-down.lock" || exit 1
  touch "$FM_HOME/held"
  while [ ! -e "$FM_HOME/release" ]; do sleep 0.1; done
  fm_lock_release "$STATE/.watcher-down.lock"
' _ "$ROOT/bin/fm-wake-lib.sh" &
holder=$!; ACTIVE+=("$holder")
wait_for test -e "$FM_HOME/held" || fail 'contention holder'
start=$SECONDS
capture live-interrupted env FM_WATCHER_CLEANUP_LOCK_BOUND=2 bash bin/fm-watch-checkpoint.sh --seconds 1
elapsed=$((SECONDS-start))
touch "$FM_HOME/release"; wait "$holder" || fail 'release contention'
printf 'elapsed_seconds=%s\nlock_pid=%s\nbeacon_exists=%s\n' "$elapsed" "$(cat "$FM_HOME/state/.watch.lock/pid")" "$([ -e "$FM_HOME/state/.last-watcher-beat" ] && echo yes || echo no)" | tee "$EVIDENCE/live-interrupted.state"
[ "$RC" -ne 0 ] && [ "$elapsed" -lt 7 ] || fail 'interrupted startup not bounded failure'
grep -q 'recovery state could not be persisted' "$EVIDENCE/live-interrupted.stderr" || fail 'interrupted startup missing diagnostic'
[ -s "$FM_HOME/state/.watch.lock/pid" ] && [ ! -e "$FM_HOME/state/.last-watcher-beat" ] || fail 'interrupted startup state'

new_home host-quiet
touch "$FM_HOME/config/supervision-host"
capture live-host-quiet bash bin/fm-watch-checkpoint.sh --seconds 4
[ "$RC" -eq 0 ] || fail 'host quiet exit'
grep -q '^checkpoint: no actionable wake within 4s$' "$EVIDENCE/live-host-quiet.stdout" || fail 'host quiet line'
cp "$FM_HOME/state/.supervision-host.log" "$EVIDENCE/live-host-quiet.ledger"
[ ! -s "$FM_HOME/state/.watch.lock/pid" ] || fail 'host quiet leaked watcher'

new_home attended
touch "$FM_HOME/config/supervision-host"
printf 'project=live-lab\nwindow=fm-demo\nharness=codex\n' >"$FM_HOME/state/demo.meta"
bash bin/fm-supervision-host.sh park >"$EVIDENCE/live-attended.stdout" 2>"$EVIDENCE/live-attended.stderr" &
host=$!; ACTIVE+=("$host")
wait_for ready || fail 'attended host ready'
printf 'done: live attended handback\n' >"$FM_HOME/state/demo.status"
rc=0; wait "$host" || rc=$?
echo "live attended host exit=$rc"
cat "$EVIDENCE/live-attended.stdout" "$EVIDENCE/live-attended.stderr"
[ "$rc" -eq 0 ] || fail 'attended handback exit'
grep -q '^signal: .*demo.status' "$EVIDENCE/live-attended.stdout" || fail 'attended wake missing'
watcher=$(cat "$FM_HOME/state/.watch.lock/pid")
kill -0 "$watcher" || fail 'attended successor dead'
cp "$FM_HOME/state/.supervision-host.log" "$EVIDENCE/live-attended.ledger"
cp "$FM_HOME/state/.wake-queue" "$EVIDENCE/live-attended.queue"
printf 'successor_pid=%s\nsuccessor_alive=yes\n' "$watcher" | tee "$EVIDENCE/live-attended.state"
echo 'LIVE CHECKS COMPLETE'
