#!/usr/bin/env bash
set -eu
ROOT=$PWD
LAB=$ROOT/.test-phase-tmp/spawn-live
bash bin/fm-lab-home.sh create "$LAB"
. tests/git-config-helpers.sh
export GIT_AUTHOR_NAME='Fixture' GIT_AUTHOR_EMAIL=fixture@example.test GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.test
mkdir -p "$LAB/proj" "$LAB/zdot" "$LAB/data/live-relaunch"
git init -q "$LAB/proj"
printf 'Disposable relaunch fixture.\n' > "$LAB/proj/fixture.txt"
git -C "$LAB/proj" add fixture.txt
git -C "$LAB/proj" commit -qm fixture
git -C "$LAB/proj" worktree add -q -b fm/live-relaunch "$LAB/wt"
cat > "$LAB/zdot/.zshrc" <<'EOF'
PROMPT='lab%% '
preexec() { print -r -- "$1" >> "$FM_LAB_COMMANDS"; }
EOF
cat > "$LAB/data/live-relaunch/brief.md" <<'EOF'
# Task
## Captain's intent
Reply READY. Do not edit files. Do not call tools.

## Firstmate spec
This is an isolated relaunch transport check. Keep all work unchanged.
EOF
SOCKET=fm-lab-spawn-$$
export FM_LAB_COMMANDS=$LAB/shell-commands.log
cleanup() { tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true; }
trap cleanup EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH TMUX TMUX_PANE ORCA_TERMINAL_HANDLE
ZDOTDIR=$LAB/zdot SHELL=$(command -v zsh) tmux -L "$SOCKET" -f /dev/null new-session -d -s lab -n fm-live-relaunch -c "$LAB/wt" -x 180 -y 40
SOCK=$(tmux -L "$SOCKET" display-message -p '#{socket_path}')
export TMUX="$SOCK,1,0" FM_HOME=$LAB
cat > "$LAB/state/live-relaunch.meta" <<EOF
window=lab:fm-live-relaunch
backend=tmux
endpoint_task_id=live-relaunch
worktree=$LAB/wt
project=$LAB/proj
harness=codex
kind=ship
mode=local-only
yolo=off
model=default
effort=default
tmux_socket=$SOCK
EOF
sleep 0.5
tmux -L "$SOCKET" send-keys -t lab:fm-live-relaunch -l 'UNSUBMITTED_STALE_INPUT'
rc=0
gtimeout 180 bash bin/fm-spawn.sh live-relaunch --relaunch --harness codex > "$LAB/spawn.out" 2>&1 || rc=$?
if [ "$rc" = 0 ]; then
  drawn=0
  while ! tmux -L "$SOCKET" capture-pane -p -t lab:fm-live-relaunch | grep -Eqi 'codex|trust|sign in|sign-in'; do
    drawn=$((drawn + 1))
    [ "$drawn" -le 200 ] || { echo 'Installed CLI did not draw within the startup bound'; exit 1; }
    sleep 0.1
  done
  runtime=$(tmux -L "$SOCKET" display-message -p -t lab:fm-live-relaunch '#{pane_current_command}')
  printf 'Runtime foreground: %s\n' "$runtime"
  case "$runtime" in *codex*) ;; *) echo 'Codex runtime not in foreground'; exit 1 ;; esac
fi
cat "$LAB/spawn.out"
printf 'SPAWN_EXIT=%s\n' "$rc"
tmux -L "$SOCKET" capture-pane -p -S -60 -t lab:fm-live-relaunch
[ "$rc" = 0 ]
cat "$LAB/shell-commands.log"
! grep -q 'UNSUBMITTED_STALE_INPUT' "$LAB/shell-commands.log"
grep -Fx "cd -- '$LAB/wt'" "$LAB/shell-commands.log"
printf 'RESULT: real spawn cleared stale input before cd and launched the installed Codex CLI in the recorded worktree.\n'
