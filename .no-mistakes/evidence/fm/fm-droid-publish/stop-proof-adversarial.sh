#!/usr/bin/env bash
# Live adversarial check: a current-generation Droid SessionEnd marker must NOT
# count as stop proof while a real droid process still has its cwd in the worktree.
set -u
ROOT=$1
. "$ROOT/bin/fm-backend.sh"; . "$ROOT/bin/fm-busy-lib.sh"; . "$ROOT/bin/fm-control-lib.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-droid-stopproof.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
WT="$LAB/worktree"; ST="$LAB/state"; mkdir -p "$WT" "$ST"
git -C "$WT" init -q
SOCK=fm-droid-stopproof-$$
printf 'busy_gen=gLIVE\nworktree=%s\n' "$WT" >"$ST/t.meta"
printf 'gLIVE\n' >"$ST/t.droid-session-end"
tmux -L "$SOCK" new-session -d -s d -x 120 -y 40 -c "$WT" "FACTORY_DROID_AUTO_UPDATE_ENABLED=false droid"
for _ in $(seq 1 40); do lsof -w -a -c droid -d cwd -Fn 2>/dev/null | grep -qx "n$WT" && break; sleep 0.25; done
echo "droid processes with cwd in worktree:"; lsof -w -a -c droid -d cwd -Fpn 2>/dev/null | paste - - | grep -F "n$WT"
if fm_control_droid_session_ended "$ST" t "$ST/t.meta"; then echo "RESULT live-droid: STOPPED (WRONG)"; else echo "RESULT live-droid: not-stopped (correct, marker alone rejected)"; fi
printf 'gOLD\n' >"$ST/t.droid-session-end"
tmux -L "$SOCK" kill-server
for _ in $(seq 1 40); do lsof -w -a -c droid -d cwd -Fn 2>/dev/null | grep -q "^n$WT" || break; sleep 0.25; done
if fm_control_droid_session_ended "$ST" t "$ST/t.meta"; then echo "RESULT stale-marker+gone: STOPPED (WRONG)"; else echo "RESULT stale-marker+gone: not-stopped (correct, prior generation rejected)"; fi
printf 'gLIVE\n' >"$ST/t.droid-session-end"
if fm_control_droid_session_ended "$ST" t "$ST/t.meta"; then echo "RESULT current-marker+gone: stopped (correct)"; else echo "RESULT current-marker+gone: not-stopped (WRONG)"; fi
rm -rf "$LAB"
