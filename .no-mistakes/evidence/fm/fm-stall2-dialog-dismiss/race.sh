#!/usr/bin/env bash
set -u
WT={run-worktree}
export TMUX_TMPDIR=$(mktemp -d /tmp/fbtest/tmux.XXXX); unset TMUX
ST=$(mktemp -d /tmp/fbtest/state.XXXX); log=/tmp/fbtest/race.keys; : > $log
. "$WT/bin/fm-backend.sh"; . "$WT/bin/fm-control-lib.sh"
tmux new-session -d -s race -x 100 -y 30 "python3 /tmp/fbtest/fake_tui.py survey $log"; sleep 0.8
scr=$(tmux capture-pane -p -t race -S -40)
echo "=== scenario race: 4 concurrent callers (watcher/daemon/watchdog stand-ins) see the same survey ==="
for n in 1 2 3 4; do ( rc=0; fm_control_dismiss_feedback_dialog "$ST" tmux race claude "$scr" "" 0.4 || rc=$?; echo "caller $n rc=$rc" ) & done; wait
sleep 0.5
echo "--- bytes received by TUI (hex) ---"; cat $log; echo "(end)"
echo "--- pane after ---"; tmux capture-pane -p -t race | grep -v '^$'
tmux kill-server; rm -rf "$TMUX_TMPDIR" "$ST"
