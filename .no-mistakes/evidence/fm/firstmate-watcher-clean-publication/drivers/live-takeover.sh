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

hold_recovery() {
  FM_HOME="$FM_HOME" bash -c '
    . "$1"
    fm_lock_acquire_wait "$STATE/.watcher-down.lock" || exit 1
    touch "$FM_HOME/held"
    n=0
    while [ ! -e "$FM_HOME/release" ] && [ "$n" -lt 1200 ]; do sleep 0.1; n=$((n+1)); done
    fm_lock_release "$STATE/.watcher-down.lock"
  ' _ "$ROOT/bin/fm-wake-lib.sh" &
  holder=$!; ACTIVE+=("$holder")
  wait_for test -e "$FM_HOME/held" || fail 'hold recovery lock'
}

echo "Revision: $(git rev-parse HEAD), harness: $(bash bin/fm-harness.sh)"
new_home interrupted-takeover-v2
touch "$FM_HOME/config/supervision-host"
printf 'project=live-lab\nwindow=fm-demo\nharness=codex\n' >"$FM_HOME/state/demo.meta"
bash bin/fm-supervision-host.sh park >"$EVIDENCE/live-takeover-initial.stdout" 2>"$EVIDENCE/live-takeover-initial.stderr" &
host=$!; ACTIVE+=("$host")
wait_for ready || fail 'initial takeover host ready'
printf 'done: first attended wake\n' >"$FM_HOME/state/demo.status"
wait "$host" || fail 'initial attended host'
left_arm=$(cut -f1 "$FM_HOME/state/.supervision-host-left")
[ -n "$left_arm" ] || fail 'left successor arm record'
old_watcher=$(cat "$FM_HOME/state/.watch.lock/pid")
ACTIVE+=("$left_arm")
bash bin/fm-wake-drain.sh >"$EVIDENCE/live-takeover-drain.stdout" 2>"$EVIDENCE/live-takeover-drain.stderr" || fail 'drain first wake'
ack=$(sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' "$EVIDENCE/live-takeover-drain.stderr" | tail -1)
[ -n "$ack" ] || fail 'drain acknowledgement required'
# The production drain emits only its numeric sequence and generation arguments.
bash bin/fm-wake-drain.sh $ack || fail 'ack first wake'
hold_recovery
bash bin/fm-supervision-host.sh park >"$EVIDENCE/live-takeover-interrupted.stdout" 2>"$EVIDENCE/live-takeover-interrupted.stderr" &
host=$!; ACTIVE+=("$host")
wait_for grep -q 'take-over' "$FM_HOME/state/.supervision-host.log" || fail 'host began takeover'
arm=$(awk -F '\t' '$1=="arm" {print $2;exit}' "$FM_HOME/state/.supervision-host")
[ -n "$arm" ] || fail 'takeover arm recorded'
ACTIVE+=("$arm")
queue_owned() { [ "$(cat "$FM_HOME/state/.wake-queue.lock/pid" 2>/dev/null)" = "$arm" ]; }
wait_for queue_owned || fail 'snapshot queue lock'
kill -STOP "$arm" || fail 'pause takeover arm'
touch "$FM_HOME/release"; wait "$holder" || fail 'release snapshot barrier'
lock_handed_over() { [ "$(cat "$FM_HOME/state/.watcher-down.lock/pid" 2>/dev/null)" = "$arm" ]; }
wait_for lock_handed_over || fail 'helper did not hand recovery lock to paused arm'
[ "$(cat "$FM_HOME/state/.wake-queue.lock/pid")" = "$arm" ] || fail 'paused arm does not own queue lock'
kill -TERM "$host"; kill -TERM "$arm"; kill -CONT "$arm"
wait "$host" 2>/dev/null || true
capture live-takeover-recovered env FM_SUPERVISION_HOST_PARK_SECONDS=6 bash bin/fm-supervision-host.sh park
[ "$RC" -eq 0 ] || fail 'next park could not recover interrupted takeover'
! cat "$EVIDENCE/live-takeover-recovered.stdout" "$EVIDENCE/live-takeover-recovered.stderr" | grep -q 'recovery state could not be persisted' || fail 'takeover manufactured failed cleanup'
cp "$FM_HOME/state/.supervision-host.log" "$EVIDENCE/live-takeover.ledger"
cp "$FM_HOME/state/.watch-cycle-exits.log" "$EVIDENCE/live-takeover-cycles.ledger"
printf 'original_arm=%s\noriginal_watcher=%s\ninterrupted_arm=%s\nrecovered_park_exit=%s\n' "$left_arm" "$old_watcher" "$arm" "$RC"
echo 'LIVE TAKEOVER CHECK COMPLETE'

