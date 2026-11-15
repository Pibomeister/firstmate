#!/usr/bin/env bash
# fm-handoff-launch.sh [options] <handoff-file> - verified primary handoff.
# Only the current lock owner can prepare a claim. Launches via Orca agent
# argv (never a shell command string), or tmux's direct argv execution.
# Options, each optional, choose the successor runtime without touching any
# account pin:
#   --harness claude|codex|agy  successor runtime (default: this session's)
#   --model <id>                successor model (default: the runtime's own)
#   --account <entry>           a config/claude-accounts entry for a claude
#                               successor; tmux only, because Orca agent launch
#                               cannot select a Claude account. The entry must
#                               already be signed in (claude auth status); no
#                               sign-in is opened.
#   --reason <token>            why this runtime was chosen (default: handoff)
# Before any claim, a quota preflight (bin/fm-supervisor-failover-lib.sh)
# reads the successor's own quota. A successor whose pool is exhausted_now or
# at 0% is refused with exit 3 before anything launches; an unmeasured pool is
# disclosed and does not block. The choice and verdict are appended to
# state/supervisor-failover.log and kept in the pending claim and in
# state/.handoff-successor as successor=.
# codex follows config/codex-approval-mode and config/codex-permission-mode on
# tmux; on Orca, Orca owns the agent's posture, so a non-bypass setting refuses.
# agy launches on tmux only, and only into a home agy already trusts.
# Two fresh terminals share a total 600-second deadline. After acquiring the
# initial claim lock, the first gets half the remaining time, up to 300 seconds,
# and the retry gets the rest.
# Setup and cleanup add to that budget, so a foreground tool timeout of 600
# seconds cannot cover it. Run in the background and collect the exit status
# and output before reporting readiness.
# A successor must read the document and call fm-handoff-ack.sh with its nonce
# and digest. fm-lock.sh validates that ack before moving the live lock.
# The predecessor is never killed. On Orca, failed attempts retain their panes
# for diagnosis. A failed attempt's nonce expires and cannot take ownership.
# Every unfinished exit after handoff_started emits one handoff_failed event,
# unless the lock already moved to a successor with a valid ack: that exit
# records completion instead. Completion and failure are decided only while
# holding .lock.acquire, so an uncommitted transfer is never reported. An exit
# waits for that lock until 10 seconds past the claim deadline. If the lock is
# still busy then, a successor transaction may yet commit, so the exit emits
# handoff_failed reason=unresolved: not final, settled by a later handoff_ack
# reason=lock_transferred for the same nonce.
# Outputs only the versioned events owned by fm-handoff-lib.sh. Other errors
# go to stderr. state/.handoff-successor is written only after lock verification.
# Test-only: FM_TEST_SEAM=1 enables FM_HANDOFF_TEST_HARNESS and
# FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS (total budget, minimum 4 seconds).
# Usage: fm-handoff-launch.sh [--harness <h>] [--model <id>] [--account <entry>]
#        [--reason <token>] <handoff-file> | --help
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
SUCC_HARNESS='' SUCC_MODEL='' SUCC_ACCOUNT='' SUCC_REASON=handoff
while [ $# -gt 1 ]; do
  case "$1" in
    --harness|--model|--account|--reason)
      [ -n "${2:-}" ] || die "$1 requires a value"
      case "$1" in
        --harness) SUCC_HARNESS=$2 ;;
        --model) SUCC_MODEL=$2 ;;
        --account) SUCC_ACCOUNT=$2 ;;
        --reason) SUCC_REASON=$2 ;;
      esac
      shift 2
      ;;
    *) break ;;
  esac
done
[ $# -eq 1 ] && [ -r "$1" ] && [ -f "$1" ] || die 'supply a readable handoff document'
HANDOFF=$1
case "$HANDOFF" in /*) ;; *) HANDOFF="$(pwd -P)/$HANDOFF" ;; esac
case "$HANDOFF" in *$'\n'*|*$'\r'*) die 'handoff path must be one line' ;; esac
case "$SUCC_MODEL" in
  default) SUCC_MODEL= ;;
  -*|*[!A-Za-z0-9._/:-]*) die '--model must be one model id' ;;
esac
case "$SUCC_REASON" in *[!A-Za-z0-9_.:-]*) die '--reason must be one token of letters, digits, _ . : -' ;; esac
case "$SUCC_ACCOUNT" in *[[:cntrl:]]*) die '--account must name one config/claude-accounts entry exactly' ;; esac
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
# shellcheck source=bin/fm-orca-cli-cache.sh
. "$SCRIPT_DIR/fm-orca-cli-cache.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"
# shellcheck source=bin/fm-supervisor-failover-lib.sh
. "$SCRIPT_DIR/fm-supervisor-failover-lib.sh"
fm_session_lock_owned_by_self "$STATE" || die 'only the current session lock owner can launch its successor'
PRED_PID=$(cat "$STATE/.lock")
case "$PRED_PID" in ''|*[!0-9]*) die 'verified successor launch currently requires a POSIX process anchor' ;; esac
PRED_START=$(fm_session_process_start "$PRED_PID") || die 'cannot identify predecessor instance'
HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null) || HARNESS=
if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_HANDOFF_TEST_HARNESS:-}" ]; then HARNESS=$FM_HANDOFF_TEST_HARNESS; fi
[ -n "$SUCC_HARNESS" ] || SUCC_HARNESS=$HARNESS
case "$SUCC_HARNESS" in
  claude|codex|agy) ;;
  *) die "successor launcher serves claude, codex, and agy, resolved '$SUCC_HARNESS'" ;;
esac
BACKEND=$(fm_backend_name) || die 'cannot determine backend'
case "$BACKEND" in orca|tmux) command -v "$BACKEND" >/dev/null || die "missing backend $BACKEND" ;; *) die "no successor launcher for backend '$BACKEND'" ;; esac
if [ "$BACKEND" = tmux ]; then
  command -v "$SUCC_HARNESS" >/dev/null || die "missing successor runtime $SUCC_HARNESS"
fi
MODEL_ARGS=()
[ -z "$SUCC_MODEL" ] || MODEL_ARGS=(--model "$SUCC_MODEL")
# Foreign primary markers would let bin/fm-harness.sh read a non-Claude
# successor as Claude; fm-spawn clears the same set for agy workers.
MARKER_ENV=(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS)
LAUNCH_ENV=()
read_mode() { # <file> <default>
  if [ -e "$1" ]; then tr -d '[:space:]' < "$1"; else printf '%s' "$2"; fi
}
case "$SUCC_HARNESS" in
  claude)
    PERMISSION_MODE=$(read_mode "$CONFIG/claude-permission-mode" bypass)
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
    ;;
  codex)
    CODEX_APPROVAL=$(read_mode "$CONFIG/codex-approval-mode" bypass)
    CODEX_PERMISSION=$(read_mode "$CONFIG/codex-permission-mode" bypass)
    case "$CODEX_APPROVAL" in
      bypass) PERM_ARGS=(--dangerously-bypass-approvals-and-sandbox) ;;
      approve-for-me) PERM_ARGS=(--approve-for-me) ;;
      *) die 'invalid config/codex-approval-mode' ;;
    esac
    case "$CODEX_PERMISSION" in
      bypass) ;;
      restricted) PERM_ARGS=(--sandbox workspace-write --ask-for-approval on-request) ;;
      *) die 'invalid config/codex-permission-mode' ;;
    esac
    if [ "$BACKEND" = orca ] && { [ "$CODEX_APPROVAL" != bypass ] || [ "$CODEX_PERMISSION" != bypass ]; }; then
      die 'Orca agent launch owns permission posture; a non-bypass Codex setting needs an Orca agent configured for it before handoff'
    fi
    ;;
  agy)
    [ "$BACKEND" = tmux ] || die "agy successor launch readiness is verified on tmux only, not $BACKEND"
    fm_failover_agy_trusted "$FM_HOME" \
      || die "agy does not trust $FM_HOME yet, and its folder-trust dialog would park the successor; trust the home in agy first"
    PERM_ARGS=(--dangerously-skip-permissions)
    ;;
esac
ACCOUNT_ROOT=
if [ -n "$SUCC_ACCOUNT" ]; then
  [ "$SUCC_HARNESS" = claude ] || die '--account names a Claude account and applies to a claude successor only'
  [ "$BACKEND" = tmux ] || die 'Orca agent launch cannot select a Claude account, so --account needs the tmux backend'
  listed=$(fm_worker_account_list claude "$CONFIG") || exit 1
  printf '%s\n' "$listed" | grep -Fxq -- "$SUCC_ACCOUNT" \
    || die "account '$SUCC_ACCOUNT' is not declared in config/claude-accounts"
  root=$SUCC_ACCOUNT
  [ "$root" != ordinary ] || root=
  if [ -n "$root" ] && { [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; }; then
    die "config/claude-accounts entry is not a readable, searchable directory: $root"
  fi
  fm_worker_account_check claude "$SUCC_ACCOUNT" "$root" "$(command -v claude)" '' config/claude-accounts || exit 1
  read -r -a LAUNCH_ENV <<< "$(fm_worker_account_claude_shed)"
  if [ -n "$root" ]; then
    LAUNCH_ENV+=("CLAUDE_CONFIG_DIR=$root")
    ACCOUNT_ROOT=$root
  else
    LAUNCH_ENV+=(-u CLAUDE_CONFIG_DIR)
    ACCOUNT_ROOT="${HOME:?HOME is required to measure the ordinary account}/.claude"
  fi
fi
quota_rc=0
QUOTA_LINE=$(fm_failover_quota_check "$SUCC_HARNESS" "${SUCC_MODEL:-default}" "$ACCOUNT_ROOT") || quota_rc=$?
SUCC_RECORD="harness=$SUCC_HARNESS model=$(fm_failover_token "${SUCC_MODEL:-default}") account=$(fm_failover_token "${SUCC_ACCOUNT:-ambient}") reason=$SUCC_REASON $QUOTA_LINE"
if [ "$quota_rc" -eq 1 ]; then
  fm_failover_log "event=successor_vetoed $SUCC_RECORD"
  printf 'error: successor quota is exhausted (%s); choose another account or runtime, for example with bin/fm-supervisor-failover.sh\n' "$SUCC_RECORD" >&2
  exit 3
fi
fm_failover_log "event=successor_preflight $SUCC_RECORD"
printf 'successor: %s\n' "$SUCC_RECORD" >&2
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
HANDOFF_STARTED=0
HANDOFF_COMPLETE=0
HANDOFF_FAIL_REQUESTED=0
HANDOFF_FAILURE_REASON=error
attempt=0
# A signal may arrive inside a call whose stdout is redirected to the backend
# receipt. Keep the event stream on its original descriptor, out of that receipt.
exec 9>&1
# Keep the existing hard-bound timeout mechanism. The constant exec wrapper
# closes our event descriptor in the backend process; all launch data stays argv.
# shellcheck disable=SC2016 # Expansion belongs to the fixed child wrapper.
BACKEND_EXEC=(bash -c 'exec 9>&-; exec "$@"' handoff-launch)
cleanup() {
  local rc=$? wait=10
  trap - EXIT
  trap '' HUP INT TERM
  set +e
  if [ -n "$NONCE" ] && [ "$CLAIM_HELD" != 1 ]; then
    [ $(( ${CLAIM_DEADLINE:-0} - $(date +%s) + 10 )) -le "$wait" ] || wait=$(( CLAIM_DEADLINE - $(date +%s) + 10 ))
    if fm_lock_acquire_wait_max "$STATE/.lock.acquire" "$wait"; then
      CLAIM_HELD=1
    else
      HANDOFF_FAILURE_REASON=unresolved
    fi
  fi
  if [ "$HANDOFF_COMPLETE" -eq 0 ] && [ "$CLAIM_HELD" = 1 ] && [ -n "$NONCE" ] \
    && transfer_committed && record_completion; then
    rc=0
  fi
  if [ "$HANDOFF_COMPLETE" -eq 0 ] \
    && { [ "$HANDOFF_STARTED" -eq 1 ] || [ "$HANDOFF_FAIL_REQUESTED" -eq 1 ]; }; then
    fm_handoff_event handoff_failed "$NONCE" "$attempt" "$PRED_PID" none "$HANDOFF_FAILURE_REASON" >&9
  fi
  if [ "$CLAIM_HELD" = 1 ] && [ -n "$NONCE" ] \
    && [ "$(jq -r '.nonce // ""' "$STATE/.handoff-pending" 2>/dev/null)" = "$NONCE" ]; then
    rm -f "$STATE/.handoff-pending"
  fi
  if [ "$CLAIM_HELD" = 1 ]; then fm_lock_release "$STATE/.lock.acquire"; fi
  fm_lock_release "$STATE/.handoff-launch.lock"
  exec 9>&-
  exit "$rc"
}
trap cleanup EXIT
trap 'HANDOFF_FAILURE_REASON=interrupted; exit 1' HUP INT TERM
rm -f "$STATE/.handoff-successor"
DEADLINE=$(( $(date +%s) + TIMEOUT ))
MONO_DEADLINE=$((SECONDS + TIMEOUT))

fail_handoff() {
  HANDOFF_FAILURE_REASON=$1
  HANDOFF_FAIL_REQUESTED=1
  exit 1
}

take_claim() {
  local left=$((MONO_DEADLINE - SECONDS))
  if [ "$left" -gt 0 ]; then
    fm_lock_acquire_wait_max "$STATE/.lock.acquire" "$left" || return 1
  else
    fm_lock_try_acquire "$STATE/.lock.acquire" || return 1
  fi
  CLAIM_HELD=1
}

transfer_committed() {
  local pid
  pid=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  [ "$pid" != "$PRED_PID" ] && fm_handoff_ack_valid "$NONCE" "$HANDOFF" "$SHA256" "$pid" \
    && fm_session_lock_anchor_instance_matches "$STATE"
}

record_completion() {
  local record_tmp
  record_tmp=$(mktemp "$STATE/.handoff-successor.XXXXXX")
  printf 'pid=%s\nnonce=%s\nhandoff=%s\nsha256=%s\nsuccessor=%s\n' "$(cat "$STATE/.lock")" "$NONCE" "$HANDOFF" "$SHA256" "$SUCC_RECORD" > "$record_tmp"
  if ! fm_handoff_completed "$record_tmp"; then rm -f "$record_tmp"; return 1; fi
  mv "$record_tmp" "$STATE/.handoff-successor" || return 1
  HANDOFF_COMPLETE=1
  fm_failover_log "event=successor_ready pid=$(cat "$STATE/.lock") $SUCC_RECORD" || true
}

# The successor's argv for this attempt's prompt; launch data stays argv.
successor_argv() {
  case "$SUCC_HARNESS" in
    claude) SUCC_ARGV=(${LAUNCH_ENV[@]+"${LAUNCH_ENV[@]}"} claude "${PERM_ARGS[@]}" ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} "$PROMPT") ;;
    codex) SUCC_ARGV=("${MARKER_ENV[@]}" codex ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} "${PERM_ARGS[@]}" "$PROMPT") ;;
    agy) SUCC_ARGV=("${MARKER_ENV[@]}" agy --prompt-interactive "$PROMPT" ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} "${PERM_ARGS[@]}") ;;
  esac
}

for attempt in 1 2; do
  if ! take_claim; then
    fail_handoff claim_busy
  fi
  if [ "$(cat "$STATE/.lock")" != "$PRED_PID" ] || ! fm_session_lock_owned_by_self "$STATE"; then
    die 'predecessor no longer owns the lock'
  fi
  NONCE=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  remaining=$((MONO_DEADLINE - SECONDS))
  [ "$remaining" -gt 0 ] || fail_handoff deadline
  ATTEMPT_END=$((SECONDS + remaining / 2))
  [ "$attempt" = 1 ] || ATTEMPT_END=$MONO_DEADLINE
  [ "$ATTEMPT_END" -le "$MONO_DEADLINE" ] || ATTEMPT_END=$MONO_DEADLINE
  CLAIM_DEADLINE=$(( $(date +%s) + ATTEMPT_END - SECONDS ))
  [ "$CLAIM_DEADLINE" -le "$DEADLINE" ] || CLAIM_DEADLINE=$DEADLINE
  tmp=$(mktemp "$STATE/.handoff-pending.XXXXXX")
  jq -n --arg nonce "$NONCE" --arg doc "$HANDOFF" --arg sha "$SHA256" \
    --arg start "$PRED_START" --argjson pid "$PRED_PID" --argjson deadline "$CLAIM_DEADLINE" --arg successor "$SUCC_RECORD" \
    '{version:1,nonce:$nonce,handoff:$doc,sha256:$sha,predecessor_pid:$pid,predecessor_start:$start,deadline:$deadline,successor:$successor}' > "$tmp"
  mv "$tmp" "$STATE/.handoff-pending"
  fm_lock_release "$STATE/.lock.acquire"
  CLAIM_HELD=0
  event=handoff_started
  [ "$attempt" = 1 ] || event=handoff_retry
  printf -v ACK_CMD 'FM_HOME=%q bash %q %q %q' "$FM_HOME" "$SCRIPT_DIR/fm-handoff-ack.sh" "$NONCE" "$SHA256"
  printf -v START_CMD 'FM_HOME=%q bash %q' "$FM_HOME" "$SCRIPT_DIR/fm-session-start.sh"
  PROMPT="Firstmate handoff successor. Read the entire document at $HANDOFF. Its sha256 must be $SHA256. Before doing any project work or starting a read-only session, run this exact acknowledgement command: $ACK_CMD . It writes your harness pid, lock pid, terminal handle and document hash, and transfers the predecessor lock only after validation. If it refuses, emit no claim of readiness and exit; it records handoff_reject. After success run $START_CMD and continue the document. nonce=$NONCE"
  remaining=$((ATTEMPT_END - SECONDS))
  if [ "$remaining" -gt 0 ]; then
    case "$BACKEND" in
      orca)
        HANDOFF_STARTED=1
        fm_handoff_event "$event" "$NONCE" "$attempt" "$PRED_PID" "$(fm_handoff_endpoint_handle || true)" awaiting_ack
        fm_orca_cli_mutation fm_run_timed "$remaining" "${BACKEND_EXEC[@]}" orca agent launch --agent "$SUCC_HARNESS" --worktree "path:$FM_HOME" \
          --surface terminal ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} --prompt "$PROMPT" --json > "$STATE/.handoff-launch-result" 2>&1 || true
        ;;
      tmux)
        SESS=
        if [ -n "${TMUX:-}" ]; then
          SESS=$(fm_run_timed "$remaining" "${BACKEND_EXEC[@]}" tmux display-message -p '#{session_name}' 2>/dev/null) || SESS=
        fi
        SESS=${SESS:-firstmate-$(basename "$FM_HOME")}
        TMUX_TARGET=(new-session -d -s "$SESS")
        remaining=$((ATTEMPT_END - SECONDS))
        if [ "$remaining" -gt 0 ] && fm_run_timed "$remaining" "${BACKEND_EXEC[@]}" tmux has-session -t "=$SESS" >/dev/null 2>&1; then
          TMUX_TARGET=(new-window -d -t "=$SESS:")
        fi
        remaining=$((ATTEMPT_END - SECONDS))
        if [ "$remaining" -gt 0 ]; then
          HANDOFF_STARTED=1
          fm_handoff_event "$event" "$NONCE" "$attempt" "$PRED_PID" "$(fm_handoff_endpoint_handle || true)" awaiting_ack
          successor_argv
          fm_run_timed "$remaining" "${BACKEND_EXEC[@]}" tmux "${TMUX_TARGET[@]}" -c "$FM_HOME" -n firstmate "${SUCC_ARGV[@]}" > "$STATE/.handoff-launch-result" 2>&1 || true
        fi
        ;;
    esac
  else
    fail_handoff deadline
  fi
  while :; do
    # Check success before the deadline: a transfer that committed just before
    # expiry must be accepted even if the parent was scheduled after expiry.
    if transfer_committed; then
      take_claim || fail_handoff claim_busy
      if transfer_committed && record_completion; then exit 0; fi
      fm_lock_release "$STATE/.lock.acquire"
      CLAIM_HELD=0
    fi
    [ "$SECONDS" -lt "$ATTEMPT_END" ] || break
    sleep 0.2
  done
  # Revoke the attempt under the very same lock the successor uses for CAS.
  if ! take_claim; then
    fail_handoff claim_busy
  fi
  if [ "$(cat "$STATE/.lock")" != "$PRED_PID" ]; then
    # A transfer may have raced the final inspection; do not launch another.
    if record_completion; then exit 0; fi
    fail_handoff ownership_changed
  fi
  rm -f "$STATE/.handoff-pending"
  fm_lock_release "$STATE/.lock.acquire"
  CLAIM_HELD=0
done
fail_handoff deadline
