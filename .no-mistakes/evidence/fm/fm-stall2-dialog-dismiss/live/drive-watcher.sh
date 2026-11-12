#!/usr/bin/env bash
# drive-watcher.sh <mode> <run-seconds>
# Live: a disposable lab home + lab-private tmux server + a fake Claude TUI pane
# recorded as a claude worker, polled by the REAL bin/fm-watch.sh.
set -u
ROOT={run-worktree}
EV=~/.no-mistakes/evidence/01M77BV33FZK9KN7V0QKXQMA6P/live
mode=$1 secs=${2:-45}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
TD=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB") || { echo "tmux-dir failed"; exit 1; }
unset TMUX TMUX_PANE
export TMUX_TMPDIR="$TD"
SOCK="$TD/tmux-$(id -u)/default"; mkdir -p "${SOCK%/*}"; chmod 700 "${SOCK%/*}"
KEYLOG="$LAB/keys.log"; : > "$KEYLOG"
cleanup() { cp "$LAB/watch.out" "$EV/last-watch.out" 2>/dev/null; ls -la "$STATE" > "$EV/last-state.ls" 2>/dev/null; [ -n "${WPID:-}" ] && kill "$WPID" 2>/dev/null; wait 2>/dev/null; tmux -S "$SOCK" kill-server >/dev/null 2>&1; "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
tmux -S "$SOCK" -f /dev/null new-session -d -s lab -n fm-w1 -x 120 -y 30 "python3 $EV/fake-claude-tui.py $mode $KEYLOG" || { echo "tmux failed"; exit 1; }
sleep 1
STATE="$LAB/state"
printf 'window=lab:fm-w1\nbackend=tmux\nharness=claude\nkind=ship\n' > "$STATE/w1.meta"
echo "=== mode=$mode: pane BEFORE watcher ==="
tmux -S "$SOCK" capture-pane -p -t lab:fm-w1 | sed '/^$/d'
for run in $(seq 1 "${RUNS:-1}"); do
rm -f "$STATE/.wake-queue"* 2>/dev/null
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" TMUX_TMPDIR="$TD" FM_POLL=2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_STALE_ESCALATE_SECS=999999 "$ROOT/bin/fm-watch.sh" > "$LAB/watch.out" 2>&1 &
WPID=$!
t=0; while [ $t -lt "$secs" ] && kill -0 $WPID 2>/dev/null; do sleep 1; t=$((t+1)); done
kill -0 $WPID 2>/dev/null && echo "(watcher still polling after ${secs}s; stopping it)" || echo "(watcher exited after ${t}s)"
kill $WPID 2>/dev/null; wait $WPID 2>/dev/null; WPID=
echo "--- watcher run $run output: $(head -c 200 "$LAB/watch.out")"
done
echo "=== pane AFTER watcher ==="
tmux -S "$SOCK" capture-pane -p -t lab:fm-w1 | sed '/^$/d'
if [ "$mode" = fullclear ]; then echo "=== scrollback (history) rows containing the survey ==="; tmux -S "$SOCK" capture-pane -p -S -60 -t lab:fm-w1 | grep -n "How is Claude\|0: Dismiss" ; fi
echo "=== bytes the TUI received (hex, one read per line) ==="
cat "$KEYLOG"; echo "count=$(wc -l < "$KEYLOG" | tr -d ' ')"
echo "=== watcher triage log lines about feedback ==="
grep -rh "feedback dialog" "$STATE" 2>/dev/null | head; grep -h "feedback" "$LAB/watch.out" | head
echo "=== feedback markers ==="; ls -a "$STATE" | grep feedback
