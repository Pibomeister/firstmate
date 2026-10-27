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
for mode in completed retired predecessor; do
  new_home "host-$mode-failure"
  touch "$FM_HOME/config/supervision-host"
  printf 'project=live-lab\nwindow=fm-demo\nharness=codex\n' >"$FM_HOME/state/demo.meta"
  mkdir "$FM_HOME/syncbin"
  printf '%s\tunrelated-live-record\t%04096d\n' "$$" 0 >"$FM_HOME/state/.watch-deliveries.log"
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
  bound=8; park=120
  [ "$mode" != completed ] || bound=2
  [ "$mode" != retired ] || park=9
  PATH="$FM_HOME/syncbin:$PATH" FM_WATCH_DELIVERY_MAX_BYTES=4096 FM_WATCHER_CLEANUP_LOCK_BOUND="$bound" FM_SUPERVISION_HOST_PARK_SECONDS="$park" \
    bash bin/fm-supervision-host.sh park >"$EVIDENCE/live-host-$mode.stdout" 2>"$EVIDENCE/live-host-$mode.stderr" &
  host=$!; ACTIVE+=("$host")
  wait_for ready || fail "$mode host ready"
  printf 'done: live host cleanup failure\n' >"$FM_HOME/state/demo.status"
  wait_for test -e "$FM_HOME/delivered" || fail "$mode delivery barrier"
  hold_recovery
  cp "$FM_HOME/state/.wake-queue" "$EVIDENCE/live-host-$mode.before-queue"
  touch "$FM_HOME/delivery-go"
  wait_for grep -q 'signal: .*demo.status' "$FM_HOME/state/.watch-deliveries.log" || fail "$mode delivered ledger"
  if [ "$mode" = predecessor ]; then
    kill -KILL "$host"; wait "$host" 2>/dev/null || true
    PATH="$FM_HOME/syncbin:$PATH" FM_WATCH_DELIVERY_MAX_BYTES=4096 FM_WATCHER_CLEANUP_LOCK_BOUND="$bound" FM_SUPERVISION_HOST_PARK_SECONDS=15 \
      bash bin/fm-supervision-host.sh park >"$EVIDENCE/live-host-$mode-replacement.stdout" 2>"$EVIDENCE/live-host-$mode-replacement.stderr" &
    host=$!; ACTIVE+=("$host")
    output="$EVIDENCE/live-host-$mode-replacement"
  else
    output="$EVIDENCE/live-host-$mode"
  fi
  rc=0; wait "$host" || rc=$?
  touch "$FM_HOME/release"; wait "$holder" || true
  echo "$mode host exit=$rc"
  cat "$output.stdout" "$output.stderr"
  [ "$rc" -ne 0 ] || fail "$mode host hid cleanup failure"
  [ "$(grep -c '^signal: .*demo.status' "$output.stdout")" -eq 1 ] || fail "$mode host lost or repeated delivered wake"
  cat "$output.stdout" "$output.stderr" | grep -q 'recovery state could not be persisted' || fail "$mode host missing diagnostic"
  cmp "$EVIDENCE/live-host-$mode.before-queue" "$FM_HOME/state/.wake-queue" || fail "$mode host mutated wake queue"
  [ -s "$FM_HOME/state/.watch.lock/pid" ] || fail "$mode host discarded failed-cleanup evidence"
  cp "$FM_HOME/state/.supervision-host.log" "$EVIDENCE/live-host-$mode.ledger"
done
echo 'LIVE HOST FAILURE CHECKS COMPLETE'

