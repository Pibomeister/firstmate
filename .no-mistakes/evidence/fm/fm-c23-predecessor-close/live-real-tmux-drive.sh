#!/usr/bin/env bash
# Live check: real tmux 3.6a on a private TMUX_TMPDIR, real fm-handoff-close.sh.
# Usage: drive.sh <repo-root> <mode: active-pred|active-stranger|pane-id>
set -eu
ROOT=$1 MODE=$2
unset TMUX TMUX_PANE ORCA_TERMINAL_HANDLE TERM_PROGRAM FM_BACKEND FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND HERDR_ENV HERDR_PANE_ID HERDR_SESSION ZELLIJ CLAUDE_PID CLAUDE_CODE_SESSION_ID FM_SESSION_ENDPOINT_META NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/bin" "$LAB/data" "$LAB/state"
export TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB"
ln -s /bin/bash "$LAB/bin/claude"
cleanup() { tmux kill-server 2>/dev/null || true; [ -n "${SUCC:-}" ] && kill "$SUCC" 2>/dev/null || true; rm -rf "$LAB"; }
trap cleanup EXIT
LOOP='while :; do sleep 0.5; done'
# Window lab:0 with two panes: pane A hosts the predecessor harness, pane B an unrelated stranger.
tmux new-session -d -s lab -x 200 -y 50 "bash -c '\"$LAB/bin/claude\" -c \"$LOOP\" & echo \$! > $LAB/pred.pid; wait'"
PANE_A=$(tmux display-message -p -t lab:0 '#{pane_id}')
PANE_B=$(tmux split-window -P -F '#{pane_id}' -t lab:0 "bash -c 'echo \$\$ > $LAB/stranger.pid; $LOOP'")
for i in $(seq 100); do [ -s "$LAB/pred.pid" ] && [ -s "$LAB/stranger.pid" ] && break; sleep 0.1; done
PRED=$(cat "$LAB/pred.pid") STRANGER=$(cat "$LAB/stranger.pid")
# Successor harness outside tmux.
( exec -a claude "$LAB/bin/claude" -c "$LOOP" ) & SUCC=$!
sleep 0.5
case "$MODE" in
  active-pred) tmux select-pane -t "$PANE_A"; TERM_REC=lab:0 ;;
  active-stranger) tmux select-pane -t "$PANE_B"; TERM_REC=lab:0 ;;
  missing) TERM_REC=%99 ;;
  pane-id) tmux select-pane -t "$PANE_B"; TERM_REC=$PANE_A ;;
esac
. "$ROOT/bin/fm-wake-lib.sh"; . "$ROOT/bin/fm-session-lock-lib.sh"; . "$ROOT/bin/fm-handoff-lib.sh"
STATE="$LAB/state"
DOC="$LAB/data/handoff.md"; printf '# Handoff\n' > "$DOC"; SHA=$(fm_handoff_hash "$DOC")
NONCE=0123456789abcdef0123456789abcdef
printf '%s\n' "$SUCC" > "$STATE/.lock"
printf '\nanchor_pid=%s\nanchor_start=%s\nbackend=orca\nterminal=term_successor\nworktree=%s\n' "$SUCC" "$(fm_session_process_start "$SUCC")" "$LAB" > "$STATE/.lock-session"
jq -n --arg nonce "$NONCE" --arg sha "$SHA" --arg doc "$DOC" --argjson pid "$SUCC" --arg start "$(fm_session_process_start "$SUCC")" \
  --argjson ppid "$PRED" --arg pstart "$(fm_session_process_start "$PRED")" --arg pt "$TERM_REC" \
  '{version:1,nonce:$nonce,sha256:$sha,harness_pid:$pid,fm_lock_pid:$pid,harness_start:$start,terminal_handle:"term_successor",
    handoff:$doc,predecessor_pid:$ppid,predecessor_start:$pstart,predecessor_backend:"tmux",predecessor_terminal:$pt}' > "$LAB/data/handoff-ack-$NONCE.json"
printf 'pid=%s\nnonce=%s\n' "$SUCC" "$NONCE" > "$STATE/.handoff-successor"
echo "== mode=$MODE recorded_terminal=$TERM_REC pane_A(pred)=$PANE_A pane_B(stranger)=$PANE_B active=$(tmux display-message -p -t lab:0 '#{pane_id}')"
echo "panes before: $(tmux list-panes -a -F '#{pane_id}:pid=#{pane_pid}' | tr '\n' ' ')"
rc=0; out=$(bash "$ROOT/bin/fm-handoff-close.sh" "$NONCE" 2>&1) || rc=$?
echo "close exit=$rc"; echo "close output: $out"
sleep 0.5
echo "panes after: $(tmux list-panes -a -F '#{pane_id}:pid=#{pane_pid}' 2>/dev/null | tr '\n' ' ')"
kill -0 "$PRED" 2>/dev/null && echo "predecessor $PRED: alive" || echo "predecessor $PRED: gone"
kill -0 "$STRANGER" 2>/dev/null && echo "stranger $STRANGER: alive" || echo "stranger $STRANGER: gone"
kill -0 "$SUCC" 2>/dev/null && echo "successor $SUCC: alive" || echo "successor $SUCC: gone"
