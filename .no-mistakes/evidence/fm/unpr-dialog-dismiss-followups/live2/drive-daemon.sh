#!/usr/bin/env bash
# Live: real tmux pane on a private socket, real daemon inject_msg, real capture,
# real dismiss helper and real tmux send path. Only pane_is_busy and the
# composer classifier verdict are pinned (idle Claude prompt => empty).
set -u
WT=$1; E=$2
export TMUX_TMPDIR=$(mktemp -d /tmp/fmlabtmux.XXXX); unset TMUX
LAB=$(mktemp -d /tmp/fmlabstate.XXXX)
cd "$WT"
export FM_TEST_DAEMON_SOURCED=1 FM_DAEMON_PRIMARY_HARNESS=claude
. bin/fm-supervise-daemon.sh
pane_is_busy() { return 1; }
fm_backend_composer_state() { printf empty; }
case_run() { # name mode
  local name=$1 mode=$2 st="$LAB/$1/state"; mkdir -p "$st"; : > "$st/.afk"
  tmux new-session -d -s "$name" -x 100 -y 20 "$E/recpane.sh $LAB/$name.keys $mode"; sleep 1
  echo "### $name ($mode) pane before:"; tmux capture-pane -p -t "$name"
  INJECT_LAST_FAILURE=; rc=0
  FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET="$name" inject_msg "LIVEDIGEST hello" "$st" || rc=$?
  sleep 1
  echo "inject rc=$rc INJECT_LAST_FAILURE=[${INJECT_LAST_FAILURE:-}]"
  echo "bytes received by pane (hex): [$(cat "$LAB/$name.keys")]"
}
echo "real composer classifier on the fixture (informational): $(tmux -V)"
case_run d1-sticky sticky
case_run d2-dismiss dismiss
echo "### d3: capture fails after printing part of the pane (real capture, then a timeout exit)"
real_vc=$(declare -f fm_backend_visible_capture)
fm_backend_visible_capture() { local o; o=$(fm_backend_capture "$1" "$2" 40); printf '%s\n' "$o" | head -2; return 124; }
case_run d3-partial sticky
echo "### d4: capture returns nothing"
fm_backend_visible_capture() { return 1; }
fm_backend_capture() { return 1; }
case_run d4-empty sticky
tmux kill-server; rm -rf "$TMUX_TMPDIR" "$LAB"
