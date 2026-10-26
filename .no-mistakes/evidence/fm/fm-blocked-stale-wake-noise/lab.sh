#!/usr/bin/env bash
# usage: lab.sh <code-root> <outdir> <last-status-line> <scenario>
set -u
CODE=$1; OUT=$2; LINE=$3; SCEN=$4
mkdir -p "$OUT"; : > "$OUT/wakes.log"; : > "$OUT/events.log"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
WT=/Users/eduardopicazo/.no-mistakes/worktrees/76ca871d9699/01M5WH9Y6VPB133GX18HPG0MC4
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
TD=$("$WT/bin/fm-lab-home.sh" tmux-dir "$LAB")
ST="$LAB/state"; MODE="$LAB/mode"; echo idle > "$MODE"
ev() { printf '%s +%ss %s\n' "$(date +%T)" "$(( $(date +%s) - T0 ))" "$*" | tee -a "$OUT/events.log"; }
"$WT/bin/fm-lab-home.sh" tmux "$LAB" new-session -d -s lab -n fm-blk \
  "bash -c '(exec -a pi python3 /tmp/fmblk-drv/fakepi.py $MODE ${TICK:-6}); exec bash --norc -i'"
printf 'window=lab:fm-blk\nkind=ship\nharness=pi\n' > "$ST/blk.meta"
"$CODE/bin/fm-busy-event.sh" arm "$ST" blk --state idle >/dev/null
printf 'working [at=1]: setup done\n%s\n' "$LINE" > "$ST/blk.status"
T0=$(date +%s)
WENV=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
  -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX -u TMUX_PANE TMUX_TMPDIR="$TD" FM_HOME="$LAB" \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
  FM_PAUSE_RESURFACE_SECS=${RESURF:-40} FM_BUSY_TURN_MAX_SECS=999999)
# supervisor loop: run watcher, record its wake, drain+ack, relaunch
( while [ ! -e "$OUT/stop" ]; do
    out=$("${WENV[@]}" perl -e "alarm shift; exec @ARGV" 30 "$CODE/bin/fm-watch.sh" 2>>"$OUT/watch.err")
    [ -n "$out" ] && printf '%s +%ss %s\n' "$(date +%T)" "$(( $(date +%s) - T0 ))" "$out" | tr '\n' ' ' | sed 's/$/\n/' >> "$OUT/wakes.log"
    "${WENV[@]}" "$CODE/bin/fm-wake-drain.sh" >/dev/null 2>"$OUT/drain.err"
    seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation \([A-Za-z0-9._-]*\)$/\1 \2/p' "$OUT/drain.err")
    [ -n "$seq" ] && "${WENV[@]}" "$CODE/bin/fm-wake-drain.sh" --ack-through ${seq% *} --recovery-generation ${seq#* } >/dev/null 2>&1
  done ) &
SUP=$!
snap() { "$WT/bin/fm-lab-home.sh" tmux "$LAB" capture-pane -p -t lab:fm-blk > "$OUT/pane-$1.txt"; }
ev "start scenario=$SCEN code=$CODE status-last='$LINE'"
case "$SCEN" in
  churn) sleep "${DUR:-100}"; snap end ;;
  adversarial)
    sleep 20; snap idle; ev "pane now shows a blocking exit-picker dialog"; echo dialog > "$MODE"; sleep 8; snap dialog
    echo idle > "$MODE"; sleep 8
    ev "steer acknowledged (keep waiting on CI), no status line"; mkdir -p "$ST/blk.inbox/handled"
    printf 'schema=fm-task-inbox.v1\n--\nkeep waiting on CI\n' > "$ST/blk.inbox/handled/001.msg"; sleep 14
    ev "worker goes busy then idle"; echo busy > "$MODE"; "$CODE/bin/fm-busy-event.sh" apply "$ST" blk busy --current-gen --source pi-ext --event agent-start >/dev/null
    sleep 6; echo idle > "$MODE"; "$CODE/bin/fm-busy-event.sh" apply "$ST" blk idle --current-gen --source pi-ext --event agent-end >/dev/null; sleep 12
    ev "worker appends a NEW blocked line"; printf 'blocked [at=3] [key=ci2]: CI registered but runner pool empty\n' >> "$ST/blk.status"; sleep 12
    ev "agent process exits; pane falls back to a shell"; echo exit > "$MODE"; sleep 10; snap shell ;;
esac
touch "$OUT/stop"; ev "stop"; wait "$SUP" 2>/dev/null
"$WT/bin/fm-lab-home.sh" tmux "$LAB" kill-server 2>/dev/null; "$WT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"
echo "WAKES: $(grep -c . "$OUT/wakes.log")"; cat "$OUT/wakes.log"
