#!/usr/bin/env bash
# Starts the real daemon on disposable lab homes that have no Orca terminal.
WT=$PWD
run() {
  name=$1; shift
  L=$(mktemp -d /tmp/fm-lab.XXXXXX)
  bin/fm-lab-home.sh create "$L" >/dev/null
  touch "$L/config/supervision-host-off"
  [ "$name" = config ] && echo orca > "$L/config/backend"
  env FM_HOME="$L" bin/fm-afk-launch.sh enter --words lab >/dev/null 2>&1
  env -u TMUX -u TMUX_PANE -u ORCA_TERMINAL_HANDLE -u TERM_PROGRAM -u ZELLIJ FM_HOME="$L" "$@" bin/fm-afk-launch.sh start-native >"$L/n" 2>&1; echo "start-native rc=$?"
  env -u TMUX -u TMUX_PANE -u ORCA_TERMINAL_HANDLE -u TERM_PROGRAM -u ZELLIJ \
    FM_AFK_STATE_PREPARED=1 FM_HOME="$L" "$@" perl -e 'alarm 14; exec @ARGV' bin/fm-afk-start.sh >"$L/o" 2>&1
  rc=$?
  echo "--- case=$name rc=$rc"
  grep -E '^(error|warn):' "$L/o" | cut -c1-230
  grep -E 'daemon starting|startup failed' "$L/state/.supervise-daemon.log" 2>/dev/null | cut -c1-200
  pkill -f "$L" 2>/dev/null
  rm -rf "$L"
}
run env-orca FM_BACKEND=orca
run config
run inherited-tern TERM_PROGRAM=tern ORCA_TERMINAL_HANDLE=term_x
run zellij-nested TERM_PROGRAM=Orca ORCA_TERMINAL_HANDLE=term_x ZELLIJ=0
run override-no-target FM_SUPERVISOR_BACKEND=orca
run control-non-orca FM_BACKEND=tmux
