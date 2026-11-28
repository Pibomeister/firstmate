#!/usr/bin/env bash
# Live: real zellij 0.46.1 (workspace-local binary) background session on a private
# TMPDIR socket dir. Calls the real fm_control_send_feedback_dismiss / backend functions
# from the tree given as $1 and records the bytes the pane actually received.
set -u
TREE=$1 ZDIR=$2 E=$3 TAG=$4
export PATH="$ZDIR:$PATH" TMPDIR="$ZDIR/tmp" ZELLIJ_CONFIG_DIR="$ZDIR/cfg"; mkdir -p "$TMPDIR" "$ZELLIJ_CONFIG_DIR"
unset ZELLIJ ZELLIJ_SESSION_NAME
S=fmlabz$TAG LOG="$ZDIR/$TAG.keys"
cat > "$ZDIR/layout-$TAG.kdl" <<KDL
layout {
  pane command="bash" {
    args "$E/zrec.sh" "$LOG"
  }
}
KDL
zellij --layout "$ZDIR/layout-$TAG.kdl" attach --create-background "$S" </dev/null >/dev/null 2>&1
sleep 3
PANE=$(zellij --session "$S" action list-panes --json 2>/dev/null | jq -r '[.[]|select(.is_plugin==false)][0].id')
echo "zellij $(zellij --version | awk '{print $2}') session=$S pane=terminal_$PANE"
cd "$TREE"
. bin/fm-backend.sh 2>/dev/null || true
. bin/backends/zellij.sh; . bin/fm-control-lib.sh 2>/dev/null
step() { : > "$LOG"; sleep 0.3; rc=0; "$@" || rc=$?; sleep 1; echo "$* -> rc=$rc pane bytes(hex)=[$(cat "$LOG")]"; }
step fm_control_send_feedback_dismiss zellij "$S:$PANE" 0
if declare -F fm_backend_zellij_write_chars >/dev/null; then
  for x in 1 00 hello $'0\n'; do step fm_backend_zellij_write_chars "$S:$PANE" "$x"; done
else echo "fm_backend_zellij_write_chars: not defined in this tree"; fi
zellij kill-session "$S" >/dev/null 2>&1; zellij delete-session "$S" >/dev/null 2>&1
