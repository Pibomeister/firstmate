#!/usr/bin/env bash
# Best-effort Orca board status update for a recorded task.
# Usage: fm-orca-card.sh <task-id> <workspace-status>
# Reads state/<task-id>.meta using FM_HOME and FM_STATE_OVERRIDE like callers.
# Missing metadata, another backend, or a missing Orca id is a silent no-op.
# Bounds the Orca command to five seconds, warns once on failure, and ALWAYS
# exits 0: board metadata must never change a registration or merge outcome.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ID=${1:-}
case "$ID" in ''|.*|*[!A-Za-z0-9._-]*) exit 0 ;; esac
[ "$#" -eq 2 ] || exit 0
META="$STATE/$ID.meta"
[ -f "$META" ] || exit 0
BACKEND=$(grep '^backend=' "$META" 2>/dev/null | tail -1 | cut -d= -f2-)
ORCA_WORKTREE_ID=$(grep '^orca_worktree_id=' "$META" 2>/dev/null | tail -1 | cut -d= -f2-)
[ "$BACKEND" = orca ] && [ -n "$ORCA_WORKTREE_ID" ] || exit 0
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# Reuse the adapter's JSON-error check, including ok:false with exit status 0.
# shellcheck source=bin/backends/orca.sh
. "$SCRIPT_DIR/backends/orca.sh"
if out=$(fm_run_timed 5 orca worktree set --worktree "id:$ORCA_WORKTREE_ID" \
  --workspace-status "$2" --json 2>/dev/null) \
  && printf '%s' "$out" | fm_backend_orca_json_ok >/dev/null 2>&1; then
  :
else
  printf 'warning: orca card status not updated for %s\n' "$ID" >&2
fi
exit 0
