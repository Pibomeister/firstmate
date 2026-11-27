#!/usr/bin/env bash
# Live drive of bin/fm-handoff-close.sh against REAL tmux 3.6a on a private
# TMUX_TMPDIR socket. Predecessor = a claude-named harness inside a real pane;
# successor = a separate claude-named harness. Lock, sidecar, ack are real files.
set -u
ROOT=$1
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
LAB=$T/home; mkdir -p "$LAB/state" "$LAB/data" "$T/bin" "$T/tmux"
ln -s /bin/bash "$T/bin/claude"
export PATH="$T/bin:$PATH" TMUX_TMPDIR="$T/tmux" FM_HOME="$LAB"
unset TMUX TMUX_PANE ORCA_TERMINAL_HANDLE TERM_PROGRAM FM_BACKEND FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND HERDR_ENV HERDR_PANE_ID HERDR_SESSION ZELLIJ CLAUDE_PID CLAUDE_CODE_SESSION_ID FM_SESSION_ENDPOINT_META FM_STATE_OVERRIDE NO_MISTAKES_GATE
STATE=$LAB/state
. "$ROOT/bin/fm-wake-lib.sh"; . "$ROOT/bin/fm-session-lock-lib.sh"; . "$ROOT/bin/fm-handoff-lib.sh"
DOC=$LAB/data/handoff.md; printf '# Handoff\n' > "$DOC"; SHA=$(fm_handoff_hash "$DOC")
NONCE=00112233445566778899aabbccddeeff
LOOP='while [ "$SECONDS" -lt 240 ]; do sleep 0.2; done'
cleanup() { tmux kill-server 2>/dev/null; [ -n "${SUCC:-}" ] && kill "$SUCC" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
wait_file() { local l=$((SECONDS+30)); while [ ! -s "$1" ] && [ $SECONDS -lt $l ]; do sleep 0.1; done; }
# scenario <name> <committed 1|0> <successor-in-pane 0|1>
scenario() {
  local name=$1 committed=$2 inpane=$3 holder
  echo "=== scenario: $name"
  tmux kill-server 2>/dev/null; rm -f "$T"/*.pid "$STATE"/.lock* "$STATE"/.handoff-* "$STATE"/handoff-events.log "$LAB"/data/handoff-ack-*
  [ -n "${SUCC:-}" ] && kill "$SUCC" 2>/dev/null; SUCC=
  { echo '#!/bin/bash'
    echo "claude -c '$LOOP' & echo \$! > $T/pred.pid"
    [ "$inpane" = 1 ] && echo "claude -c '$LOOP' & echo \$! > $T/succ.pid"
    echo wait; } > "$T/pane.sh"; chmod +x "$T/pane.sh"
  tmux new-session -d -s pred -x 120 -y 30 "$T/pane.sh"
  wait_file "$T/pred.pid"; PRED=$(cat "$T/pred.pid")
  PANE=$(tmux display-message -p -t pred '#{pane_id}'); ROOTPID=$(tmux display-message -p -t pred '#{pane_pid}')
  if [ "$inpane" = 1 ]; then wait_file "$T/succ.pid"; SUCC=$(cat "$T/succ.pid")
  else (claude -c "echo \$\$ > $T/succ.pid; $LOOP" &); wait_file "$T/succ.pid"; SUCC=$(cat "$T/succ.pid"); fi
  echo "real pane=$PANE pane_pid=$ROOTPID predecessor=$PRED successor=$SUCC"
  holder=$SUCC; [ "$committed" = 1 ] || holder=$PRED
  printf '%s\n' "$holder" > "$STATE/.lock"
  printf '\nanchor_pid=%s\nanchor_start=%s\nbackend=orca\nterminal=term_successor\nworktree=%s\n' "$holder" "$(fm_session_process_start "$holder")" "$LAB" > "$STATE/.lock-session"
  jq -n --arg nonce "$NONCE" --arg sha "$SHA" --arg doc "$DOC" --argjson pid "$SUCC" --arg start "$(fm_session_process_start "$SUCC")" \
    --argjson ppid "$PRED" --arg pstart "$(fm_session_process_start "$PRED")" --arg pt "$PANE" \
    '{version:1,nonce:$nonce,sha256:$sha,harness_pid:$pid,fm_lock_pid:$pid,harness_start:$start,terminal_handle:"term_successor",
      handoff:$doc,predecessor_pid:$ppid,predecessor_start:$pstart,predecessor_backend:"tmux",predecessor_terminal:$pt}' > "$LAB/data/handoff-ack-$NONCE.json"
  printf 'pid=%s\nnonce=%s\n' "$SUCC" "$NONCE" > "$STATE/.handoff-successor"
  local rc=0; out=$(bash "$ROOT/bin/fm-handoff-close.sh" "$NONCE" 2>&1) || rc=$?
  echo "close exit=$rc"; echo "close output: $out"
  echo "events log: $(cat "$STATE/handoff-events.log" 2>/dev/null)"
  sleep 0.5
  echo "after: tmux panes=[$(tmux list-panes -a -F '#{pane_id}' 2>&1 | tr '\n' ' ')]"
  kill -0 "$PRED" 2>/dev/null && echo "after: predecessor $PRED ALIVE" || echo "after: predecessor $PRED GONE"
  kill -0 "$SUCC" 2>/dev/null && echo "after: successor $SUCC ALIVE" || echo "after: successor $SUCC GONE"
}
scenario committed-transfer-closes-real-pane 1 0
scenario uncommitted-lock-refused 0 0
scenario successor-in-same-pane-refused 1 1
