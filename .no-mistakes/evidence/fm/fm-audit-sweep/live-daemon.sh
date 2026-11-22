#!/usr/bin/env bash
set -eu
ROOT=$PWD
HOME_LAB=$ROOT/.test-phase-tmp/daemon-live
mkdir -p "$HOME_LAB/state" "$HOME_LAB/data" "$HOME_LAB/config"
export FM_HOME=$HOME_LAB FM_STATE_OVERRIDE=$HOME_LAB/state FM_DATA_OVERRIDE=$HOME_LAB/data FM_CONFIG_OVERRIDE=$HOME_LAB/config
unset FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE TMUX TMUX_PANE HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH ORCA_TERMINAL_HANDLE
OWN=fm-lab-daemon-own-$$
OTHER=fm-lab-daemon-other-$$
cleanup() { tmux -L "$OWN" kill-server >/dev/null 2>&1 || true; tmux -L "$OTHER" kill-server >/dev/null 2>&1 || true; }
trap cleanup EXIT
TMUX_TMPDIR=/tmp tmux -L "$OWN" -f /dev/null new-session -d -s own -x 160 -y 40
TMUX_TMPDIR=/tmp tmux -L "$OTHER" -f /dev/null new-session -d -s worker -x 160 -y 40
OWN_SOCKET=$(TMUX_TMPDIR=/tmp tmux -L "$OWN" display-message -p '#{socket_path}')
OTHER_SOCKET=$(TMUX_TMPDIR=/tmp tmux -L "$OTHER" display-message -p '#{socket_path}')
export TMUX="$OWN_SOCKET,1,0"
. "$ROOT/bin/fm-supervise-daemon.sh"
STATE=$HOME_LAB/state
TASK=foreign-worker
WIN=worker:0
printf 'window=%s\nbackend=tmux\nkind=ship\nharness=claude\ntmux_socket=%s\n' "$WIN" "$OTHER_SOCKET" > "$STATE/$TASK.meta"
printf 'paused: awaiting external\n' > "$STATE/$TASK.status"
printf 'Real worker endpoint on another private server:\n'
tmux -S "$OTHER_SOCKET" list-panes -a -F '#{session_name}:#{window_index} #{pane_current_command}'
result=$(classify_stale "$WIN" "$STATE")
printf 'Foreign server result: %s\n' "$result"
case "$result" in 'pause|paused (awaiting external)'*) ;; *) exit 1 ;; esac
printf 'window=%s\nbackend=tmux\nkind=ship\nharness=claude\ntmux_socket=%s\n' "$WIN" "$OWN_SOCKET" > "$STATE/$TASK.meta"
result=$(classify_stale "$WIN" "$STATE")
printf 'Same server, missing endpoint result: %s\n' "$result"
case "$result" in 'escalate|paused worker gone:'*) ;; *) exit 1 ;; esac
printf 'RESULT: foreign endpoint retains declared wait; missing endpoint on addressed server escalates.\n'
