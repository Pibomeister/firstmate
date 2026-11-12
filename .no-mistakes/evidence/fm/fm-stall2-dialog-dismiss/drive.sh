#!/usr/bin/env bash
set -u
ROOT=$1; E=$2
export TMUX_TMPDIR=$(mktemp -d /tmp/fbd-live/tmux.XXXX); unset TMUX
. "$ROOT/bin/fm-backend.sh"
. "$ROOT/bin/fm-control-lib.sh"
fm_backend_source tmux
ST=$(mktemp -d /tmp/fbd-live/state.XXXX)
run() { # name kind sticky
  local name=$1 kind=$2 sticky=${3:-0} log=/tmp/fbd-live/$1.keys
  : > "$log"
  tmux new-session -d -s "$name" -x 100 -y 30 "/tmp/fbd-live/tui.sh $kind $log $sticky"
  sleep 0.6
  local before; before=$(fm_backend_capture tmux "$name:0" 60)
  echo "=== scenario $name (dialog=$kind sticky=$sticky)"
  echo "--- pane before:"; printf '%s\n' "$before" | sed '/^$/d'
  local rc=0
  fm_control_dismiss_feedback_dialog "$ST" tmux "$name:0" claude "$before" "" 0.5 || rc=$?
  echo "--- call1 rc=$rc id=$FM_CONTROL_FEEDBACK_DIALOG_ID key=$FM_CONTROL_FEEDBACK_DISMISS_KEY"
  if [ "$sticky" = 1 ]; then
    sleep 0.3; local again; again=$(fm_backend_capture tmux "$name:0" 60); rc=0
    fm_control_dismiss_feedback_dialog "$ST" tmux "$name:0" claude "$again" "" 0.5 || rc=$?
    echo "--- call2 (same unchanged pane) rc=$rc"
  fi
  sleep 0.3
  echo "--- pane after:"; fm_backend_capture tmux "$name:0" 60 | sed '/^$/d'
  echo "--- bytes received by the TUI (hex, one per keystroke):"; cat "$log"; echo "(end, $(wc -l < "$log" | tr -d ' ') keystrokes)"
  echo
}
run survey survey
run draft draft
run modal modal
run quoted quoted
run sticky survey 1
# concurrent claim: two callers capture the same pane and race
log=/tmp/fbd-live/race.keys; : > $log
tmux new-session -d -s race -x 100 -y 30 "/tmp/fbd-live/tui.sh survey $log 1"; sleep 0.6
scr=$(fm_backend_capture tmux race:0 60)
echo "=== scenario race (two concurrent callers, same survey pane)"
( fm_control_dismiss_feedback_dialog "$ST" tmux race:0 claude "$scr" "" 0.5; echo "caller A rc=$?" ) &
( fm_control_dismiss_feedback_dialog "$ST" tmux race:0 claude "$scr" "" 0.5; echo "caller B rc=$?" ) &
wait
echo "--- bytes received:"; cat $log; echo "(end, $(wc -l < $log | tr -d ' ') keystrokes)"
tmux kill-server
rm -rf "$TMUX_TMPDIR" "$ST"
