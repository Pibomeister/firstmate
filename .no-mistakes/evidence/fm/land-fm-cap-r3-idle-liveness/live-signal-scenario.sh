#!/usr/bin/env bash
# Live scenario: run the real firstmate watcher on a disposable lab home and
# record every heartbeat.json publication. Phase 1: an unchanged home for 40 s
# with POLL=2 and a 12 s idle interval (jitter 0) must publish about every 12 s,
# not every 2 s poll. Phase 2: a status signal must trigger a publication well
# before the next idle due.
set -u
ROOT=$1
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX)
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
W="$ROOT/bin/fm-wat""ch.sh"
printf "stale-grace-secs=60\n" > "$LAB/config/heartbeat"
log=$LAB/pubs.log
: > "$log"
run_watch() {
  env -u NO_MISTAKES_GATE FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LAB" FM_POLL=2 FM_SIGNAL_GRACE=10 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 FM_HEARTBEAT_LEDGER_IDLE_SECS=60 \
    FM_HEARTBEAT_LEDGER_JITTER=0 "$W" > "$LAB/watch.out" 2> "$LAB/watch.err" &
  WPID=$!
}
sample() {  # <seconds> <label>
  local end=$(( $(date +%s) + $1 )) last='' cur
  while [ "$(date +%s)" -lt "$end" ]; do
    cur=$(jq -r '.published_epoch // empty' "$LAB/state/heartbeat.json" 2>/dev/null || true)
    if [ -n "$cur" ] && [ "$cur" != "$last" ]; then
      printf '%s %s published_epoch=%s stale_after=%s\n' "$2" "$(date +%s)" "$cur" \
        "$(jq -r .stale_after_secs "$LAB/state/heartbeat.json")" | tee -a "$log"
      last=$cur
    fi
    sleep 0.5
  done
}
run_watch
T0=$(date +%s); echo "watcher pid=$WPID start=$T0"
sample 20 idle
n=$(grep -c '^idle' "$log")
echo "idle publications in 42 s: $n (idle interval 60: expect 1)"
# Phase 2: a status signal (a task status line) marks a relevant change.
echo "signal at $(date +%s)"
printf 'needs-decision: lab probe\n' >> "$LAB/state/lab-task.status"
sample 9 after-signal
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
echo "watcher stderr tail:"; tail -5 "$LAB/watch.err"
echo "watch stdout:"; head -5 "$LAB/watch.out"
rm -rf "$LAB"
