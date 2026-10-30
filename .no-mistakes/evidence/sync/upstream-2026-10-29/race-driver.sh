#!/usr/bin/env bash
# Usage: race.sh <bin-dir> <work-dir>. Drives a real fm-watch.sh handling successor
# and has a live holder grab the wake-queue lock right after arm-check announces.
set -u
BIN=$1; W=$2
rm -rf "$W"; mkdir -p "$W/home/data" "$W/state" "$W/fakebin"
state=$W/state; home=$W/home; out=$W/watch.out; err=$W/watch.err
printf 'pending:downtime:later.1.aaa\n' > "$state/.watcher-down"; chmod 600 "$state/.watcher-down"
printf '%s\t1\tcheck\tinbox:n1\tcheck: captain inbox note n1\n' "$(date +%s)" > "$state/.wake-queue"
printf '1\n' > "$state/.wake-queue.seq"
# Holder: wait for the marker to be announced, then grab the queue lock and hold 6s.
FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash -c '
  . "$1"
  while :; do IFS= read -r m < "$2/.watcher-down" 2>/dev/null; case "$m" in announced:*) break;; esac; done
  until fm_lock_try_acquire "$FM_WAKE_QUEUE_LOCK"; do :; done
  date +%s.%N > "$2/../holder-got"; sleep 6
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"; date +%s > "$2/../holder-released"
' _ "$BIN/fm-wake-lib.sh" "$state" &
holder=$!
start=$(date +%s)
PATH="$W/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=0 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 FM_WAKE_QUEUE_LOCK_WAIT=2 FM_WATCHER_STALL_BOUND=600 \
  FM_WATCH_HANDLING_SUCCESSOR=1 "$BIN/fm-watch.sh" > "$out" 2> "$err" &
child=$!
# Settle the handoff once the successor owns the watch lock (as a handled host turn does).
for _ in $(seq 1 100); do [ "$(cat "$state/.watch.lock/pid" 2>/dev/null)" = "$child" ] && break; sleep 0.1; done
for _ in $(seq 1 100); do [ -e "$state/.last-watcher-beat" ] && break; sleep 0.1; done
FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_recovery_marker_begin_handling "$2/.watcher-down" later.1.aaa && fm_recovery_marker_handling_settled "$2/.watcher-down"' _ "$BIN/fm-wake-lib.sh" "$state" || echo "settle failed"
for _ in $(seq 1 120); do kill -0 "$child" 2>/dev/null || break; sleep 0.25; done
alive=no; kill -0 "$child" 2>/dev/null && alive=yes
kill -TERM "$child" "$holder" 2>/dev/null; wait "$child" 2>/dev/null
echo "elapsed=$(( $(date +%s) - start ))s watcher_still_running_after_30s=$alive holder_won_lock=$([ -e "$W/holder-got" ] && echo yes || echo no)"
echo "deferral_file: $(cat "$state"/.watcher-deferral.wake-queue 2>/dev/null || echo none)"
echo "marker: $(cat "$state/.watcher-down" 2>/dev/null)"
echo "--- watcher stdout:"; cat "$out"
echo "--- watcher stderr (lock lines):"; grep -E 'still held|recovery' "$err" || true
echo "rearm_resurface_count=$(grep -c '^check: rearm-resurface$' "$out")"
