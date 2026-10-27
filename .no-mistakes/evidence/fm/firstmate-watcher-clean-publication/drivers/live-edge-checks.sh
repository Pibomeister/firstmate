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
new_home stalled-arms-v3
printf '%s\tunrelated-live-record\t%04096d\n' "$$" 0 >"$FM_HOME/state/.watch-deliveries.log"
mkdir "$FM_HOME/syncbin"
cat >"$FM_HOME/syncbin/mv" <<'SH'
#!/usr/bin/env bash
last=
for last in "$@"; do :; done
if [ "$last" = "$FM_HOME/state/.watch-deliveries.log" ]; then
  touch "$FM_HOME/delivered"
  n=0
  while [ ! -e "$FM_HOME/delivery-go" ] && [ "$n" -lt 1200 ]; do sleep 0.05; n=$((n+1)); done
fi
exec /bin/mv "$@"
SH
chmod +x "$FM_HOME/syncbin/mv"
PATH="$FM_HOME/syncbin:$PATH" FM_WATCH_DELIVERY_MAX_BYTES=4096 FM_GUARD_GRACE=5 FM_WATCHER_STALL_BOUND=12 FM_WATCHER_CLEANUP_LOCK_BOUND=30 \
  bash bin/fm-watch-arm.sh >"$EVIDENCE/live-owned-stall.stdout" 2>"$EVIDENCE/live-owned-stall.stderr" &
owned=$!; ACTIVE+=("$owned")
wait_for ready || fail 'owned stall watcher ready'
FM_GUARD_GRACE=5 FM_WATCHER_STALL_BOUND=12 FM_WATCHER_CLEANUP_LOCK_BOUND=30 \
  bash bin/fm-watch-arm.sh >"$EVIDENCE/live-attached-stall.stdout" 2>"$EVIDENCE/live-attached-stall.stderr" &
attached=$!; ACTIVE+=("$attached")
wait_for grep -q '^watcher: attached pid=' "$EVIDENCE/live-attached-stall.stdout" || fail 'attached arm ready'
append || fail 'queue stalled wake'
wait_for test -e "$FM_HOME/delivered" || fail 'watcher delivered before cleanup'
hold_recovery
touch "$FM_HOME/delivery-go"
wait_for grep -q 'check: rearm-resurface' "$FM_HOME/state/.watch-deliveries.log" || fail 'delivery ledger did not retain wake'
orc=0; wait "$owned" || orc=$?
arc=0; wait "$attached" || arc=$?
touch "$FM_HOME/release"; wait "$holder" || true
printf 'owned_exit=%s\nattached_exit=%s\n' "$orc" "$arc"
cat "$EVIDENCE/live-owned-stall.stdout" "$EVIDENCE/live-owned-stall.stderr" "$EVIDENCE/live-attached-stall.stdout" "$EVIDENCE/live-attached-stall.stderr"
cp "$FM_HOME/state/.wake-queue" "$EVIDENCE/live-stalled-arms.queue"
cp "$FM_HOME/state/.watch-cycle-exits.log" "$EVIDENCE/live-stalled-arms.ledger"
[ "$orc" -ne 0 ] && [ "$arc" -ne 0 ] || fail 'stalled arm claimed success'
grep -q '^check: rearm-resurface$' "$EVIDENCE/live-owned-stall.stdout" || fail 'owned stall lost delivered wake'
grep -q '^check: rearm-resurface$' "$EVIDENCE/live-attached-stall.stdout" || fail 'attached stall lost delivered wake'

new_home predecessor-startup
touch "$FM_HOME/config/supervision-host"
hold_recovery
cat >"$FM_HOME/preexec.env" <<'SH'
case "$(ps -ww -o args= -p "$$" 2>/dev/null)" in
  *"/bin/fm-watch.sh")
    if [ "${LIVE_EXECED:-0}" != 1 ]; then
      echo "$$" >"$FM_HOME/preexec.pid"
      while [ ! -e "$FM_HOME/go" ]; do sleep 0.05; done
      export LIVE_EXECED=1
      exec bash --noprofile "$PWD/bin/fm-watch.sh"
    fi
    ;;
esac
SH
BASH_ENV="$FM_HOME/preexec.env" FM_WATCHER_CLEANUP_LOCK_BOUND=8 \
  bash bin/fm-supervision-host.sh park >"$EVIDENCE/live-predecessor-initial.stdout" 2>"$EVIDENCE/live-predecessor-initial.stderr" &
predecessor=$!; ACTIVE+=("$predecessor")
wait_for test -s "$FM_HOME/preexec.pid" || fail 'preexec watcher ready'
watcher=$(cat "$FM_HOME/preexec.pid")
initial=$(ps -ww -o args= -p "$watcher")
sleep 2
touch "$FM_HOME/go"
wait_for test -s "$FM_HOME/state/.watch.lock/pid-identity" || fail 'published watcher identity'
final=$(ps -ww -o args= -p "$watcher")
printf 'preexec_args=%s\npostexec_args=%s\nbeacon_exists=%s\n' "$initial" "$final" "$([ -e "$FM_HOME/state/.last-watcher-beat" ] && echo yes || echo no)" | tee "$EVIDENCE/live-predecessor-startup.state"
[ "$initial" != "$final" ] || fail 'identity did not change across exec'
[ ! -e "$FM_HOME/state/.last-watcher-beat" ] || fail 'startup reached beacon'
kill -KILL "$predecessor"; wait "$predecessor" 2>/dev/null || true
capture live-predecessor-replacement env FM_WATCHER_CLEANUP_LOCK_BOUND=8 FM_SUPERVISION_HOST_PARK_SECONDS=12 bash bin/fm-supervision-host.sh park
touch "$FM_HOME/release"; wait "$holder" || true
[ "$RC" -ne 0 ] || fail 'preconfirmation replacement claimed success'
grep -q 'recovery state could not be persisted' "$EVIDENCE/live-predecessor-replacement.stdout" || fail 'preconfirmation replacement hid cleanup failure'
[ "$(cat "$FM_HOME/state/.watch.lock/pid")" = "$watcher" ] || fail 'lost stale identity evidence'
cp "$FM_HOME/state/.supervision-host.log" "$EVIDENCE/live-predecessor-startup.ledger"
echo 'LIVE EDGE CHECKS COMPLETE'

