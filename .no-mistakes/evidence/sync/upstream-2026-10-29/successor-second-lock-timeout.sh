#!/usr/bin/env bash
# Live repro: a handling-successor watcher whose arm-check says `recover`, but
# whose second (queued-row) wake-queue lock wait times out because a live
# process grabbed the lock right after arm-check released it.
# Usage: <repo-root> <bin-dir-under-test> <label>
set -u
ROOT=$1 BIN=$2 LABEL=$3
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-succ-repro.XXXXXX")
state="$WORK/state"; home="$WORK/home"; fakebin="$WORK/fakebin"; out="$WORK/watch.out"
mkdir -p "$state" "$home/data" "$fakebin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/tmux"; chmod +x "$fakebin/tmux"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/fm-crew-state.sh"; chmod +x "$fakebin/fm-crew-state.sh"
printf 'pending:downtime:repro.1.aaa\n' > "$state/.watcher-down"; chmod 600 "$state/.watcher-down"
pids=
cleanup() { for p in $pids; do kill "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT

env -u NO_MISTAKES_GATE PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
  FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
  FM_WATCH_HANDLING_SUCCESSOR=1 FM_WAKE_QUEUE_LOCK_WAIT=2 FM_WATCHER_STALL_BOUND=600 \
  "$BIN/fm-watch.sh" > "$out" 2>&1 &
watcher=$!; pids="$pids $watcher"
for i in $(seq 1 200); do [ -e "$state/.last-watcher-beat" ] && break; sleep 0.05; done
[ -e "$state/.last-watcher-beat" ] || { echo "[$LABEL] FIXTURE: no first beat: $(cat "$out")"; exit 2; }
echo "[$LABEL] watcher pid=$watcher alive after first beat; marker now: $(cat "$state/.watcher-down")"

# Holder: take the queue lock between cycles, bury one row (the next arm-check
# then sees acked + non-empty -> recover), release, then wait until the watcher
# is inside arm-check (marker lock held) and grab the queue lock the instant
# arm-check releases it, so only the second (queued-row) wait contends.
FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash -c '
  . "$1"
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || exit 1
  fm_wake_append_locked check inbox:n1 "check: captain inbox note n1 - from Basecamp" || exit 1
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  : > "$2/row-queued"
  while [ ! -e "$2/.watcher-down.lock" ] && [ ! -L "$2/.watcher-down.lock" ]; do :; done
  until fm_lock_try_acquire "$FM_WAKE_QUEUE_LOCK"; do :; done
  : > "$2/holder-has-lock"
  while [ ! -e "$2/holder-release" ]; do sleep 0.05; done
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
' _ "$BIN/fm-wake-lib.sh" "$state" &
holder=$!; pids="$pids $holder"
for i in $(seq 1 100); do [ -e "$state/row-queued" ] && break; sleep 0.05; done
echo "[$LABEL] queued a row: $(cut -f3- "$state/.wake-queue" | tr '\t' ' ')"
for i in $(seq 1 100); do [ -e "$state/holder-has-lock" ] && break; sleep 0.05; done
[ -e "$state/holder-has-lock" ] || { echo "[$LABEL] FIXTURE: holder never got the lock"; exit 2; }
echo "[$LABEL] holder pid=$holder took .wake-queue.lock right after arm-check; marker now: $(cat "$state/.watcher-down"); rearm-resurface already printed: $(grep -c rearm-resurface "$out")"
# Hold past the 2s bound plus a few beats.
for i in $(seq 1 80); do grep -q 'rearm-resurface' "$out" && break; kill -0 "$watcher" 2>/dev/null || break; sleep 0.1; done
echo "[$LABEL] triage deferrals: $(grep -c 'deferred wake-queue' "$state/.watch-triage.log" 2>/dev/null || echo 0)"
if grep -q 'check: rearm-resurface' "$out"; then
  echo "[$LABEL] RESULT: watcher woke main with 'check: rearm-resurface' while the lock was still held (exit status of watcher follows)"
  : > "$state/holder-release"; wait "$watcher"; echo "[$LABEL] watcher exited rc=$?"
  echo "[$LABEL] watch output: $(tr '\n' ' ' < "$out")"
  exit 0
fi
# Release and give it several more cycles: does the announced episode ever wake?
: > "$state/holder-release"; wait "$holder" 2>/dev/null
for i in $(seq 1 60); do grep -q 'rearm-resurface' "$out" && break; kill -0 "$watcher" 2>/dev/null || break; sleep 0.1; done
echo "[$LABEL] after holder released + 6s: marker=$(cat "$state/.watcher-down"); queue rows=$(wc -l < "$state/.wake-queue" | tr -d ' ')"
if grep -q 'check: rearm-resurface' "$out"; then
  echo "[$LABEL] RESULT: woke only after the holder released"
else
  echo "[$LABEL] RESULT: NO WAKE - announced episode with a buried row was dropped (watch output: $(tr '\n' ' ' < "$out"))"
fi
exit 1
