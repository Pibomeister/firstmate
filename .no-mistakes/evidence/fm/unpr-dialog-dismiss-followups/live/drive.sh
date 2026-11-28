#!/usr/bin/env bash
# Live: real tmux pane on a private socket + real fm-control-lib dismiss helper.
set -u
WT=$1; E=$2
export TMUX_TMPDIR=$(mktemp -d /tmp/fmlabtmux.XXXX); unset TMUX
cd "$WT"
. bin/fm-backend.sh
. bin/fm-timeout-lib.sh
. bin/fm-control-lib.sh
ST=$(mktemp -d /tmp/fmlabstate.XXXX)
run() { # name
  tmux new-session -d -s "$1" -x 100 -y 20 "$E/live/dialog-pane.sh"; sleep 1
}
idle=$'some work\n────────────────\n❯ \n────────────────'
echo "### S1 happy path: caller screen shows the survey, tmux backend"
run s1; scr=$(tmux capture-pane -p -t s1); printf '%s\n' "$scr"
rc=0; fm_control_dismiss_feedback_dialog "$ST" tmux s1 claude "$scr" "" 0.5 10 || rc=$?
echo "rc=$rc id=$FM_CONTROL_FEEDBACK_DIALOG_ID key=$FM_CONTROL_FEEDBACK_DISMISS_KEY"
echo "-- pane after:"; tmux capture-pane -p -t s1
echo "### S2 race: caller screen idle, live pane shows the survey (marker from earlier dismiss present)"
run s2; : > "$ST/.feedback-dismissed-$(fm_control_feedback_window_key tmux s2)"
rc=0; fm_control_dismiss_feedback_dialog "$ST" tmux s2 claude "$idle" "" 0.5 10 || rc=$?
echo "rc=$rc (expect 2 = hold, no key)"; sleep 0.5
echo "-- pane after (expect survey still shown, no GOT_KEY):"; tmux capture-pane -p -t s2
echo "### S3 Orca Escape gate"
for h in claude droid; do fm_control_backend_supports_key orca Escape $h && echo "orca Escape $h: supported" || echo "orca Escape $h: refused"; done
rc=0; fm_control_send_feedback_dismiss orca fake-target Escape "" claude || rc=$?; echo "send_feedback_dismiss orca Escape claude rc=$rc (expect 5)"
tmux kill-server; rm -rf "$TMUX_TMPDIR" "$ST"
