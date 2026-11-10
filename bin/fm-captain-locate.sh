#!/usr/bin/env bash
# fm-captain-locate.sh - read-only discovery from this home's verified lock.
# stdout: CAPTAIN v1 pid=<lock-pid-or-0> handle=<token-or-none> state=<held|free|stale|unknown|unreadable>
# Exit 0 only for a held lock with its anchor-bound endpoint; otherwise exit 1.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
fm_session_lock_inspect "$STATE"
pid=${FM_LOCK_INSPECT_PID:-0}
case "$pid" in *[!A-Za-z0-9:._-]*) pid=0 ;; esac
handle=none
if [ "$FM_LOCK_INSPECT_STATE" = held ] && [ -f "$STATE/.lock-session" ] \
  && [ -n "$(sed -n 's/^anchor_start=//p' "$STATE/.lock-session")" ] \
  && fm_session_lock_anchor_instance_matches "$STATE"; then
  handle=$(sed -n 's/^terminal=//p' "$STATE/.lock-session")
  case "$handle" in ''|*[!A-Za-z0-9_.:%-]*) handle=none ;; esac
fi
if [ "$(cat "$STATE/.lock" 2>/dev/null || true)" != "${FM_LOCK_INSPECT_PID:-}" ]; then
  handle=none
  FM_LOCK_INSPECT_STATE=unknown
fi
printf 'CAPTAIN v1 pid=%s handle=%s state=%s\n' "$pid" "$handle" "$FM_LOCK_INSPECT_STATE"
[ "$FM_LOCK_INSPECT_STATE" = held ] && [ "$handle" != none ]
