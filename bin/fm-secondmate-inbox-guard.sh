#!/usr/bin/env bash
# fm-secondmate-inbox-guard.sh - the Codex secondmate steering-inbox check
# between tool calls.
#
# Usage: <Codex PreToolUse JSON on stdin> | bin/fm-secondmate-inbox-guard.sh <home-root>
#
# ONE owner of the policy that stops a busy Codex secondmate from starving its
# parent-owned steering inbox (bin/fm-task-inbox-lib.sh owns the inbox itself).
# bin/fm-arm-pretool-check.sh calls it from the already-trusted Bash
# PreToolUse registration in .codex/hooks.json and renders its deny, because a
# new hooks.json entry makes codex ask for hook-trust review at every launch
# until a human trusts it (measured on codex-cli 0.162.1, also under
# --dangerously-bypass-approvals-and-sandbox).
#
# It prints a drain instruction and exits 0 only when every condition holds:
#   - the payload is Codex-shaped (tool_input, session_id and turn_id);
#   - <home-root> is a genuine local secondmate home, and its parent-owned inbox
#     comes from the home's own marker and parent record
#     (fm_secondmate_home_inbox), never from the environment; an inherited
#     FM_TASK_INBOX that names another inbox allows the call;
#   - the calling session owns the home's session lock by the existing
#     ownership proof (fm_session_lock_owned_by_self), whose ancestry walk stops
#     at the nearest harness process, so a nested Codex, crewmate or probe that
#     merely inherited this home's environment is never steered;
#   - the oldest record (lowest sequence, at most 200 names scanned) is at least
#     FM_SECONDMATE_INBOX_GUARD_GRACE seconds old (default 60), the watcher has
#     not already escalated it, it has been denied fewer than 3 times, and its
#     last deny is at least FM_SECONDMATE_INBOX_GUARD_REDENY seconds old
#     (default 60), so the drain's own calls run between denies.
# Every other case, including any error, exits 1 and the call is allowed: the
# watcher's bounded recovery is the backstop. Deny state lives in
# state/.inbox-guard as "<record>\t<count>\t<epoch>". Only record names are
# printed; payloads and record bodies are never read into output or logs.
set -u

ROOT=${1:-}
[ -n "$ROOT" ] && [ -d "$ROOT" ] || exit 1
command -v jq >/dev/null 2>&1 || exit 1
PAYLOAD=$(cat 2>/dev/null || true)
printf '%s' "$PAYLOAD" | jq -e 'type == "object" and has("tool_input") and has("session_id") and has("turn_id")' \
  >/dev/null 2>&1 || exit 1

GUARD_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 1
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$GUARD_DIR/fm-primary-scope-lib.sh"
INBOX=$(fm_secondmate_home_inbox "$ROOT") || exit 1
[ -z "${FM_TASK_INBOX:-}" ] || [ "$FM_TASK_INBOX" = "$INBOX" ] || exit 1
# shellcheck source=bin/fm-session-lock-lib.sh
. "$GUARD_DIR/fm-session-lock-lib.sh"
fm_session_lock_owned_by_self "$ROOT/state" || exit 1

GRACE=${FM_SECONDMATE_INBOX_GUARD_GRACE:-60}
WINDOW=${FM_SECONDMATE_INBOX_GUARD_REDENY:-60}
case "$GRACE" in '' | *[!0-9]*) GRACE=60 ;; esac
case "$WINDOW" in '' | *[!0-9]*) WINDOW=60 ;; esac
STATE_FILE="$ROOT/state/.inbox-guard"

NAMES=$(find "$INBOX" -maxdepth 1 -name '[0-9]*.msg' -type f 2>/dev/null | sed 's#.*/##' | sort -n | head -n 200)
if [ -z "$NAMES" ]; then
  rm -f "$STATE_FILE" 2>/dev/null
  exit 1
fi
OLDEST=$(printf '%s\n' "$NAMES" | head -n 1)
NOW=$(date +%s)
MTIME=$(stat -f %m "$INBOX/$OLDEST" 2>/dev/null || stat -c %Y "$INBOX/$OLDEST" 2>/dev/null) || exit 1
case "$MTIME" in '' | *[!0-9]*) exit 1 ;; esac
[ $((NOW - MTIME)) -ge "$GRACE" ] || exit 1
[ "$(cat "$INBOX/.escalated" 2>/dev/null)" != "$OLDEST" ] || exit 1

LAST_NAME=
COUNT=0
LAST=0
IFS=$(printf '\t') read -r LAST_NAME COUNT LAST < "$STATE_FILE" 2>/dev/null || true
if [ "$LAST_NAME" = "$OLDEST" ]; then
  case "$COUNT" in '' | *[!0-9]*) COUNT=0 ;; esac
  case "$LAST" in '' | *[!0-9]*) LAST=0 ;; esac
  [ "$COUNT" -lt 3 ] || exit 1
  [ $((NOW - LAST)) -ge "$WINDOW" ] || exit 1
else
  COUNT=0
fi
printf '%s\t%s\t%s\n' "$OLDEST" "$((COUNT + 1))" "$NOW" > "$STATE_FILE" 2>/dev/null || exit 1

LISTED=$(printf '%s\n' "$NAMES" | head -n 5 | tr '\n' ' ')
printf 'Firstmate steering records are waiting in your parent-owned inbox %s: %s- before any other work, read each in numeric order, act on it (dispatch or answer, with its correlated parent line), then mv it into handled/. Calls are allowed again for the next %s seconds so the drain can run.' \
  "$INBOX" "$LISTED" "$WINDOW"
