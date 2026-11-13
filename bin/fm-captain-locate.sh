#!/usr/bin/env bash
# fm-captain-locate.sh - read-only discovery from this home's verified lock.
# stdout: CAPTAIN v1 pid=<lock-pid-or-0> handle=<token-or-none> state=<held|free|stale|unknown|unreadable>
# A recorded terminal of unknown, or any token that is not a handle, is handle=none.
# unknown is the absence of an endpoint, not a terminal name.
# Exit 0 only for a held lock with its anchor-bound endpoint; otherwise exit 1.
# The pid and handle come from one snapshot of the lock and its sidecar; a
# change to either file during discovery reports state=unknown and handle=none.
# A live holder of .lock.acquire before or after the snapshot may still roll
# the lock back, so it also reports state=unknown and handle=none; a dead or
# stale holder does not hide the endpoint.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
claim_lock_busy() {
  local lockdir="$STATE/.lock.acquire" holder
  [ -e "$lockdir" ] || [ -L "$lockdir" ] || return 1
  holder=$(cat "$lockdir/pid" 2>/dev/null || true)
  fm_lock_holder_alive "$lockdir" "$holder" || fm_lock_mid_acquire_is_fresh "$lockdir" "$holder"
}
claim_busy=0
claim_lock_busy && claim_busy=1
fm_session_lock_inspect "$STATE"
lock_snap=$(cat "$STATE/.lock" 2>/dev/null || true)
session_snap=$(cat "$STATE/.lock-session" 2>/dev/null || true)
pid=${FM_LOCK_INSPECT_PID:-0}
case "$pid" in *[!A-Za-z0-9:._-]*) pid=0 ;; esac
handle=none
if [ "$FM_LOCK_INSPECT_STATE" = held ] && [ "$lock_snap" = "${FM_LOCK_INSPECT_PID:-}" ]; then
  anchor_start=$(printf '%s\n' "$session_snap" | sed -n 's/^anchor_start=//p')
  if [ -n "$anchor_start" ] \
    && [ "$(printf '%s\n' "$session_snap" | sed -n 's/^anchor_pid=//p')" = "$lock_snap" ] \
    && [ "$(fm_session_process_start "$lock_snap" 2>/dev/null || true)" = "$anchor_start" ]; then
    handle=$(printf '%s\n' "$session_snap" | sed -n 's/^terminal=//p')
    # unknown is the recorded absence of an endpoint, not a terminal name.
    case "$handle" in ''|unknown|*[!A-Za-z0-9_.:%-]*) handle=none ;; esac
  fi
fi
if [ "$claim_busy" -eq 1 ] || claim_lock_busy \
  || [ "$lock_snap" != "${FM_LOCK_INSPECT_PID:-}" ] \
  || [ "$(cat "$STATE/.lock" 2>/dev/null || true)" != "$lock_snap" ] \
  || [ "$(cat "$STATE/.lock-session" 2>/dev/null || true)" != "$session_snap" ]; then
  handle=none
  FM_LOCK_INSPECT_STATE=unknown
fi
printf 'CAPTAIN v1 pid=%s handle=%s state=%s\n' "$pid" "$handle" "$FM_LOCK_INSPECT_STATE"
[ "$FM_LOCK_INSPECT_STATE" = held ] && [ "$handle" != none ]
