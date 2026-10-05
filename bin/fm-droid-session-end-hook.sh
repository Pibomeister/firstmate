#!/usr/bin/env bash
# Record Droid's SessionEnd as idle, and as process-stop proof only when the
# payload proves the TUI exited. Droid 0.230.0 was observed live: /exit and
# Ctrl-C end the current session with reason "other", while /clear ends the
# old session with "clear" and then again with "other" from its worker, and
# the process keeps running. Every other reason fails closed.
set -u
set -o pipefail

[ "$#" -eq 3 ] || { echo 'usage: fm-droid-session-end-hook.sh <state-dir> <id> <gen>' >&2; exit 2; }
STATE=$1 ID=$2 GEN=$3
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

payload=$(cat)
"$SCRIPT_DIR/fm-busy-event.sh" apply "$STATE" "$ID" idle \
  --gen "$GEN" --source droid-hook --event session-end >/dev/null 2>&1 || exit 0
reason=$(jq -r '.reason // empty' <<<"$payload" 2>/dev/null) || exit 0
session=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null) || exit 0
[ -n "$session" ] || exit 0
cleared="$STATE/$ID.droid-cleared-sessions"
case "$reason" in
  clear) printf '%s\n' "$session" >>"$cleared" ;;
  other)
    grep -Fxq -- "$session" "$cleared" 2>/dev/null && exit 0
    printf '%s\n' "$GEN" >"$STATE/$ID.droid-session-end"
    ;;
esac
exit 0
