#!/usr/bin/env bash
# fm-handoff-launch.sh <handoff-file> - verified primary Claude handoff.
# Only the current lock owner can prepare a claim. Launches via Orca agent
# argv (never a shell command string), or tmux's direct argv execution.
# Two fresh terminals share a total 600-second deadline, 300 seconds each.
# A successor must read the document and call fm-handoff-ack.sh with its nonce
# and digest. fm-lock.sh validates that ack before moving the live lock.
# The predecessor is never killed. Failed attempts retain their panes for
# diagnosis; their nonce expires and cannot later take ownership.
# Outputs only the versioned events owned by fm-handoff-lib.sh. Other errors
# go to stderr. state/.handoff-successor is written only after lock verification.
# Test-only: FM_TEST_SEAM=1 enables FM_HANDOFF_TEST_HARNESS and
# FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS (total budget, minimum 4 seconds).
# Usage: fm-handoff-launch.sh <handoff-file> | --help
set -eu
umask 077
case "${1:-}" in
  -h|--help) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
die() { printf 'error: %s\n' "$1" >&2; exit 1; }
[ $# -eq 1 ] && [ -r "$1" ] && [ -f "$1" ] || die 'supply a readable handoff document'
HANDOFF=$1
case "$HANDOFF" in /*) ;; *) HANDOFF="$(pwd -P)/$HANDOFF" ;; esac
case "$HANDOFF" in *$'\n'*|*$'\r'*) die 'handoff path must be one line' ;; esac
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_root_is_secondmate_home "$FM_HOME" && die 'a second mate asks its parent to relaunch it'
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-handoff-lib.sh
. "$SCRIPT_DIR/fm-handoff-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_session_lock_owned_by_self "$STATE" || die 'only the current session lock owner can launch its successor'
PRED_PID=$(cat "$STATE/.lock")
case "$PRED_PID" in ''|*[!0-9]*) die 'verified successor launch currently requires a POSIX process anchor' ;; esac
PRED_START=$(fm_session_process_start "$PRED_PID") || die 'cannot identify predecessor instance'
HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null) || HARNESS=
if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_HANDOFF_TEST_HARNESS:-}" ]; then HARNESS=$FM_HANDOFF_TEST_HARNESS; fi
[ "$HARNESS" = claude ] || die "successor launcher serves claude only, resolved '$HARNESS'"
BACKEND=$(fm_backend_name) || die 'cannot determine backend'
case "$BACKEND" in orca|tmux) command -v "$BACKEND" >/dev/null || die "missing backend $BACKEND" ;; *) die "no successor launcher for backend '$BACKEND'" ;; esac
PERMISSION_MODE=bypass
if [ -e "$CONFIG/claude-permission-mode" ]; then
  PERMISSION_MODE=$(tr -d '[:space:]' < "$CONFIG/claude-permission-mode")
fi
case "$PERMISSION_MODE" in
  bypass) PERM_ARGS=(--dangerously-skip-permissions) ;;
  auto) PERM_ARGS=(--permission-mode auto) ;;
  *) die 'invalid config/claude-permission-mode' ;;
esac
# Orca owns its agent permission configuration; do not substitute a terminal
# shell command to carry permission flags that agent launch does not expose.
if [ "$BACKEND" = orca ] && [ "$PERMISSION_MODE" != bypass ]; then
  die 'Orca agent launch owns permission posture; explicit auto mode needs an Orca agent configured for auto before handoff'
fi
TIMEOUT=600
if [ "${FM_TEST_SEAM:-}" = 1 ]; then
  case "${FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS:-}" in
    ''|*[!0-9]*) ;; *) TIMEOUT=$FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS ;;
  esac
fi
[ "$TIMEOUT" -ge 4 ] || die 'handoff budget must be at least four seconds'
SHA256=$(fm_handoff_hash "$HANDOFF") || die 'cannot hash handoff'
mkdir -p "$FM_HOME/data"
fm_lock_try_acquire "$STATE/.handoff-launch.lock" || die 'a handoff launcher already owns this home'
NONCE=
CLAIM_HELD=0
cleanup() {
  if [ "$CLAIM_HELD" = 1 ]; then fm_lock_release "$STATE/.lock.acquire"; fi
  fm_lock_release "$STATE/.handoff-launch.lock"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
rm -f "$STATE/.handoff-successor"
DEADLINE=$(( $(date +%s) + TIMEOUT ))
MONO_DEADLINE=$((SECONDS + TIMEOUT))

take_claim() {
  local left=$((MONO_DEADLINE - SECONDS))
  if [ "$left" -gt 0 ]; then
    fm_lock_acquire_wait_max "$STATE/.lock.acquire" "$left" || return 1
  else
    fm_lock_try_acquire "$STATE/.lock.acquire" || return 1
  fi
  CLAIM_HELD=1
}

record_completion() {
  local record_tmp
  record_tmp=$(mktemp "$STATE/.handoff-successor.XXXXXX")
  printf 'pid=%s\nnonce=%s\nhandoff=%s\nsha256=%s\n' "$(cat "$STATE/.lock")" "$NONCE" "$HANDOFF" "$SHA256" > "$record_tmp"
  if ! fm_handoff_completed "$record_tmp"; then rm -f "$record_tmp"; return 1; fi
  mv "$record_tmp" "$STATE/.handoff-successor"
}

for attempt in 1 2; do
  if ! take_claim; then
    fm_handoff_event handoff_failed "$NONCE" "$attempt" "$PRED_PID" none claim_busy
    exit 1
  fi
  if [ "$(cat "$STATE/.lock")" != "$PRED_PID" ] || ! fm_session_lock_owned_by_self "$STATE"; then
    die 'predecessor no longer owns the lock'
  fi
  NONCE=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  ATTEMPT_END=$((SECONDS + TIMEOUT / 2))
  [ "$attempt" = 1 ] || ATTEMPT_END=$MONO_DEADLINE
  CLAIM_DEADLINE=$(( $(date +%s) + ATTEMPT_END - SECONDS ))
  [ "$CLAIM_DEADLINE" -le "$DEADLINE" ] || CLAIM_DEADLINE=$DEADLINE
  tmp=$(mktemp "$STATE/.handoff-pending.XXXXXX")
  jq -n --arg nonce "$NONCE" --arg doc "$HANDOFF" --arg sha "$SHA256" \
    --arg start "$PRED_START" --argjson pid "$PRED_PID" --argjson deadline "$CLAIM_DEADLINE" \
    '{version:1,nonce:$nonce,handoff:$doc,sha256:$sha,predecessor_pid:$pid,predecessor_start:$start,deadline:$deadline}' > "$tmp"
  mv "$tmp" "$STATE/.handoff-pending"
  fm_lock_release "$STATE/.lock.acquire"
  CLAIM_HELD=0
  event=handoff_started
  [ "$attempt" = 1 ] || event=handoff_retry
  fm_handoff_event "$event" "$NONCE" "$attempt" "$PRED_PID" "${ORCA_TERMINAL_HANDLE:-${TMUX_PANE:-}}" awaiting_ack
  printf -v ACK_CMD 'FM_HOME=%q bash %q %q %q' "$FM_HOME" "$SCRIPT_DIR/fm-handoff-ack.sh" "$NONCE" "$SHA256"
  printf -v START_CMD 'FM_HOME=%q bash %q' "$FM_HOME" "$SCRIPT_DIR/fm-session-start.sh"
  PROMPT="Firstmate handoff successor. Read the entire document at $HANDOFF. Its sha256 must be $SHA256. Before doing any project work or starting a read-only session, run this exact acknowledgement command: $ACK_CMD . It writes your harness pid, lock pid, terminal handle and document hash, and transfers the predecessor lock only after validation. If it refuses, emit no claim of readiness and exit; it records handoff_reject. After success run $START_CMD and continue the document. nonce=$NONCE"
  remaining=$((ATTEMPT_END - SECONDS))
  if [ "$remaining" -gt 0 ]; then
    case "$BACKEND" in
      orca)
        fm_run_timed "$remaining" orca agent launch --agent claude --worktree "path:$FM_HOME" \
          --surface terminal --prompt "$PROMPT" --json > "$STATE/.handoff-launch-result" 2>&1 || true
        ;;
      tmux)
        SESS=$(tmux display-message -p '#{session_name}' 2>/dev/null) || SESS="firstmate-$(basename "$FM_HOME")"
        SESS=${SESS:-firstmate-$(basename "$FM_HOME")}
        if tmux has-session -t "=$SESS" >/dev/null 2>&1; then
          fm_run_timed "$remaining" tmux new-window -d -t "=$SESS:" -c "$FM_HOME" -n firstmate claude "${PERM_ARGS[@]}" "$PROMPT" > "$STATE/.handoff-launch-result" 2>&1 || true
        else
          fm_run_timed "$remaining" tmux new-session -d -s "$SESS" -c "$FM_HOME" -n firstmate claude "${PERM_ARGS[@]}" "$PROMPT" > "$STATE/.handoff-launch-result" 2>&1 || true
        fi
        ;;
    esac
  fi
  while :; do
    # Check success before the deadline: a transfer that committed just before
    # expiry must be accepted even if the parent was scheduled after expiry.
    pid=$(cat "$STATE/.lock" 2>/dev/null) || pid=
    if [ "$pid" != "$PRED_PID" ] && fm_handoff_ack_valid "$NONCE" "$HANDOFF" "$SHA256" "$pid" \
      && fm_session_lock_anchor_instance_matches "$STATE"; then
      if record_completion; then exit 0; fi
    fi
    [ "$SECONDS" -lt "$ATTEMPT_END" ] || break
    sleep 0.2
  done
  # Revoke the attempt under the very same lock the successor uses for CAS.
  if ! take_claim; then
    fm_handoff_event handoff_failed "$NONCE" "$attempt" "$PRED_PID" none claim_busy
    exit 1
  fi
  if [ "$(cat "$STATE/.lock")" != "$PRED_PID" ]; then
    # A transfer may have raced the final inspection; do not launch another.
    if record_completion; then exit 0; fi
    fm_handoff_event handoff_failed "$NONCE" "$attempt" "$PRED_PID" none ownership_changed
    exit 1
  fi
  rm -f "$STATE/.handoff-pending"
  fm_lock_release "$STATE/.lock.acquire"
  CLAIM_HELD=0
done
fm_handoff_event handoff_failed "$NONCE" 2 "$PRED_PID" none deadline
exit 1
