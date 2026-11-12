#!/usr/bin/env bash
# Live scenario driver: real tmux (isolated TMUX_TMPDIR) + real fm-control-lib helper.
set -u
WT={run-worktree}
export TMUX_TMPDIR=$(mktemp -d /tmp/fbtest/tmux.XXXX)
unset TMUX
ST=$(mktemp -d /tmp/fbtest/state.XXXX)
. "$WT/bin/fm-backend.sh"
. "$WT/bin/fm-control-lib.sh"
run() { # <name> <mode> <harness> [calls]
  local name=$1 mode=$2 harness=$3 calls=${4:-1} log=/tmp/fbtest/$1.keys i rc scr
  : > "$log"
  tmux new-session -d -s "$name" -x 100 -y 30 "python3 /tmp/fbtest/fake_tui.py $mode $log"
  sleep 0.8
  echo "=== scenario $name (mode=$mode harness=$harness) ==="
  for i in $(seq 1 "$calls"); do
    scr=$(tmux capture-pane -p -t "$name" -S -40)
    echo "--- pane before call $i ---"; printf '%s\n' "$scr" | grep -v '^$'
    rc=0; fm_control_dismiss_feedback_dialog "$ST" tmux "$name" "$harness" "$scr" "" 0.4 || rc=$?
    echo "call $i rc=$rc dialog=${FM_CONTROL_FEEDBACK_DIALOG_ID:-none} key=${FM_CONTROL_FEEDBACK_DISMISS_KEY:-none}"
    sleep 0.3
  done
  echo "--- pane after ---"; tmux capture-pane -p -t "$name" | grep -v '^$'
  echo "--- bytes received by TUI (hex) ---"; cat "$log"; echo "(end)"
  tmux kill-session -t "$name"
}
run survey survey claude 1
run modal modal claude 1
run sticky sticky claude 3
run normal normal claude 1
run stale stale claude 1
run wrongharness survey codex 1
tmux kill-server 2>/dev/null; rm -rf "$TMUX_TMPDIR" "$ST"
