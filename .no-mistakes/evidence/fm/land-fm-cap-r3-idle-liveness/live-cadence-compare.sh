#!/usr/bin/env bash
# Live comparison: real fm-watch.sh at the base commit vs the target commit, each in a
# disposable lab home, counting heartbeat-ledger launches (logging publisher) and
# watcher-beat refreshes on an unchanged home, then injecting one wake.
set -u
ROOT=$1; OUT=$2; BASE_SHA=$3
BASE=$(mktemp -d "${TMPDIR:-/tmp}/fm-base.XXXXXX")
git -C "$ROOT" archive "$BASE_SHA" | tar -x -C "$BASE"
run_one() { # <label> <code-root>
  local label=$1 code=$2 LAB WPID start now injected=0 beats=0 last=
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
  local runs="$OUT.$label.launches"; : > "$runs"
  local stub="$LAB/hb-stub.sh"
  printf '#!/usr/bin/env bash\ndate +%%s >> %q\n' "$runs" > "$stub"; chmod +x "$stub"
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX -u TMUX_PANE \
    FM_HOME="$LAB" FM_POLL=2 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_HEARTBEAT_LEDGER_IDLE_SECS=15 FM_HEARTBEAT_LEDGER_JITTER=0 FM_HOME_SUMMARY_INTERVAL=999 \
    FM_WATCH_MANAGED_HOLD=1 FM_HEARTBEAT_BIN="$stub" \
    "$code/bin/fm-watch.sh" > "$OUT.$label.watch.out" 2> "$OUT.$label.watch.err" &
  WPID=$!
  start=$(date +%s)
  while [ $(( $(date +%s) - start )) -lt 80 ]; do
    now=$(date +%s)
    b=$(stat -f %m "$LAB/state/.last-watcher-beat" 2>/dev/null || true)
    [ -n "$b" ] && [ "$b" != "$last" ] && { beats=$((beats+1)); last=$b; }
    if [ $injected = 0 ] && [ $((now - start)) -ge 55 ]; then
      ( STATE=$LAB/state FM_HOME=$LAB; . "$ROOT/bin/fm-wake-lib.sh"; fm_wake_append check live-cadence "injected wake" )
      echo "$label injected_wake_epoch=$now" >> "$OUT.events"; injected=1
    fi
    sleep 0.5
  done
  echo "$label start=$start launches=$(wc -l < "$runs" | tr -d ' ') beat_refreshes=$beats alive=$(kill -0 $WPID 2>/dev/null && echo yes || echo no)" >> "$OUT.events"
  echo "$label launch_offsets: $(awk -v s=$start '{printf "%s ", $1-s}' "$runs")" >> "$OUT.events"
  kill -KILL $WPID 2>/dev/null; wait $WPID 2>/dev/null
  pkill -KILL -f "$LAB" 2>/dev/null; sleep 2; pkill -KILL -f "$LAB" 2>/dev/null
  rm -rf "$LAB"
}
: > "$OUT.events"
run_one base "$BASE" &
run_one target "$ROOT" &
wait
rm -rf "$BASE"
cat "$OUT.events"
