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
# until a human trusts it (docs/verification/runtime-backends.md, "Codex hook
# trust").
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
#   - among the 200 lowest-sequence waiting records (fm_task_inbox_records_in),
#     the first that is not fire-and-forget (fm_task_inbox_is_fire_and_forget,
#     skipped exactly as the watcher's ladder skips it), that the watcher has
#     not escalated and that has been denied fewer than 3 times is at least
#     FM_SECONDMATE_INBOX_GUARD_GRACE seconds old (default 60), so a stuck
#     oldest record never switches the drain off for later ones;
#   - the last deny for any record is at least FM_SECONDMATE_INBOX_GUARD_REDENY
#     seconds old (default 60), so the drain's own calls run between denies.
# Every other case, including any error, exits 1 and the call is allowed: the
# watcher's bounded recovery is the backstop. Deny state lives in
# state/.inbox-guard, one "<record>\t<count>\t<epoch>" line per waiting record
# denied so far. Only record names are printed; payloads and record bodies are
# never read into output or logs.
set -u

ROOT=${1:-}
[ -n "$ROOT" ] && [ -d "$ROOT" ] || exit 1
command -v jq >/dev/null 2>&1 || exit 1
PAYLOAD=$(cat 2>/dev/null || true)
printf '%s' "$PAYLOAD" | jq -e 'type == "object" and has("tool_input") and has("session_id") and has("turn_id")' \
  >/dev/null 2>&1 || exit 1

GUARD_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 1
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$GUARD_DIR/fm-task-inbox-lib.sh"
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

WAITING=$(fm_task_inbox_records_in "$INBOX" | head -n 200)
if [ -z "$WAITING" ]; then
  rm -f "$STATE_FILE" 2>/dev/null
  exit 1
fi
# Deny counts of the records still waiting, and the newest deny of any.
DENIES=$(awk -F '\t' 'NR == FNR { waiting[$0] = 1; next }
  ($1 in waiting) && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { print $1 "\t" $2 "\t" $3 }' \
  - "$STATE_FILE" 2>/dev/null <<EOF
$WAITING
EOF
)
TARGET=
COUNT=0
while IFS= read -r NAME; do
  fm_task_inbox_is_fire_and_forget "$INBOX/$NAME" && continue
  fm_task_inbox_record_is_escalated "$INBOX/$NAME" && continue
  COUNT=$(printf '%s\n' "$DENIES" | awk -F '\t' -v n="$NAME" '$1 == n { c = $2 } END { print c + 0 }')
  [ "$COUNT" -lt 3 ] || continue
  TARGET=$NAME
  break
done <<EOF
$WAITING
EOF
[ -n "$TARGET" ] || exit 1
# fm_path_mtime picks the stat style by platform; a record that vanished
# fails the read and allows the call.
MTIME=$(fm_path_mtime "$INBOX/$TARGET") || exit 1
NOW=$(date +%s)
[ $((NOW - MTIME)) -ge "$GRACE" ] || exit 1
LAST=$(printf '%s\n' "$DENIES" | awk -F '\t' '$3 > m { m = $3 } END { print m + 0 }')
[ $((NOW - LAST)) -ge "$WINDOW" ] || exit 1
{
  printf '%s\n' "$DENIES" | awk -F '\t' -v n="$TARGET" 'NF == 3 && $1 != n'
  printf '%s\t%s\t%s\n' "$TARGET" "$((COUNT + 1))" "$NOW"
} > "$STATE_FILE" 2>/dev/null || exit 1

LISTED=$(printf '%s\n' "$WAITING" | head -n 5 | tr '\n' ' ')
printf 'Firstmate steering records are waiting in your parent-owned inbox %s: %s- before any other work, read each in numeric order, act on it (dispatch or answer, with its correlated parent line), then mv it into handled/. Calls are allowed again for the next %s seconds so the drain can run.' \
  "$INBOX" "$LISTED" "$WINDOW"
