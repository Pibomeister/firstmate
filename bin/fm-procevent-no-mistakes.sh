#!/usr/bin/env bash
# Worker-owned advisory completion wake for an existing no-mistakes run.
#
# Usage:
#   FM_HOME=<owning-home> fm-procevent-no-mistakes.sh arm <task-id>
#   fm-procevent-no-mistakes.sh listen <worktree>
#   fm-procevent-no-mistakes.sh read|classify|terminal <result-file>
#
# arm resolves the existing task endpoint/worktree and confirms task-owned
# completion readiness. Declare paused only after success, then end the turn.
# listen is the runner's blocking child, never a conversational command. It
# attaches with axi run --wait 24h, without intent or gate responses. A normal
# elapsed hold reattaches here without a worker turn; other returns are captured
# verbatim with their CLI exit status. The existing runner owns leases, durable
# capture, recovery, inbox delivery, and acknowledgement.
#
# This wake is advisory for the task worktree's CURRENT BRANCH, not pinned to a
# run id. bin/fm-dod-lib.sh owns the generated worker completion-handling
# contract, including fresh-state inspection and acknowledgement ordering.
# Every captured attachment is terminal for its source round, including a gate.
# classify prints gate, the returned outcome, error, or unknown; read preserves
# the capture. Neither command decides a finding or authorizes publication.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:-}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

usage() { sed -n '2,/^set -u/{ /^#/s/^# \{0,1\}//p; }' "${BASH_SOURCE[0]}"; exit 2; }
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

arm() {
  local task=${1-} wt id digest= listening=0 owner
  [ "$#" -eq 1 ] || usage
  case "$FM_HOME" in /*) ;; *) die 'FM_HOME must explicitly name the owning home' ;; esac
  STATE=$(fm_procevent_state_root_resolve "$STATE") || die 'owning state root is unavailable'
  fm_backend_validate_task_endpoint "$STATE/$task.meta" "$task" >/dev/null \
    || die "task endpoint is unavailable: $task"
  wt=$(fm_backend_meta_exact_value "$STATE/$task.meta" worktree) || die 'missing worktree'
  case "$wt" in /*) ;; *) die 'task worktree must be absolute' ;; esac
  [ -d "$wt" ] || die "task worktree is unavailable: $wt"
  command -v no-mistakes >/dev/null 2>&1 || die 'no-mistakes is not installed'
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s\n%s\n' "$STATE" "$task" | shasum -a 256 | cut -c1-32)
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s\n%s\n' "$STATE" "$task" | sha256sum | cut -c1-32)
  fi
  [ "${#digest}" -eq 32 ] || die 'cannot derive the source id: shasum or sha256sum is required'
  id="nm-$digest"
  "$SCRIPT_DIR/fm-procevent.sh" register-task no-mistakes "$id" "$task" -- \
    "$SCRIPT_DIR/fm-procevent-no-mistakes.sh" listen "$wt" || return 1
  "$SCRIPT_DIR/fm-procevent.sh" ensure-listening "$id" || listening=$?
  if [ "$listening" -eq 3 ]; then
    printf 'still-listening: %s\n' "$id"
    return 0
  fi
  if [ "$listening" -ne 0 ]; then
    owner=$("$SCRIPT_DIR/fm-procevent.sh" list 2>/dev/null | awk -v id="$id" '$1 == id { print $3; exit }')
    case "$owner" in
      live|orphaned|task:*/listening|task:*/round-open) ;;
      *) "$SCRIPT_DIR/fm-procevent.sh" retire "$id" >/dev/null 2>&1 || true ;;
    esac
    return 1
  fi
  printf 'armed: %s\n' "$id"
}

listen() {
  local wt=$1 out rc
  while :; do
    rc=0
    out=$( ( cd "$wt" && no-mistakes axi run --wait 24h ) 2>&1) || rc=$?
    # Reuse the shared positive executing/parked predicates. An unknown or
    # failed return is news, never a reason for an unbounded quiet retry.
    if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -Eq '^(gate|outcome|error):' \
      && printf '%s\n' "$out" | grep -q '^run:' \
      && fm_nm_run_is_executing "$out"; then
      continue
    fi
    printf 'attachment-exit: %s\n%s\n' "$rc" "$out"
    return 0
  done
}

classify() {
  local file=$1 outcome
  [ -f "$file" ] || return 1
  if grep -Eq '^attachment-exit: [1-9][0-9]*$|^error:' "$file"; then
    printf 'error\n'
  elif grep -q '^gate:' "$file"; then
    printf 'gate\n'
  else
    outcome=$(sed -n 's/^outcome: *//p' "$file" | head -1)
    case "$outcome" in
      checks-passed|passed|passed-with-override|passed-with-skips|failed|cancelled) printf '%s\n' "$outcome" ;;
      *) printf 'unknown\n' ;;
    esac
  fi
}

case "${1-}" in
  arm) shift; arm "$@" ;;
  listen) [ "$#" -eq 2 ] || usage; listen "$2" ;;
  classify) [ "$#" -eq 2 ] || usage; classify "$2" ;;
  read) [ "$#" -eq 2 ] || usage; cat -- "$2" ;;
  terminal) [ "$#" -eq 2 ] || usage; [ -f "$2" ] ;;
  *) usage ;;
esac
