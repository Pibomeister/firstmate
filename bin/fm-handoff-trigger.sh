#!/usr/bin/env bash
# fm-handoff-trigger.sh - early handoff trigger for a Claude primary session.
#
# Registered in tracked .claude/settings.json as a PostToolUse, a
# UserPromptSubmit, and a Stop command hook. When the session's context left before
# auto-compact falls to the configured percentage (default 15), the session
# receives ONE instruction, as hook additionalContext, to write its full
# handoff before auto-compact, hand off to a successor (through the watchdog
# restart path where it acts, otherwise by launching one itself), and report that it is ready to restart. It fires
# at most once per context cycle, so a session that keeps working past the
# threshold is not nagged again, and a session that auto-compacts anyway is told
# again before its next auto-compact.
#
# CONTEXT LEFT. Claude Code does not hand hooks its own "% until auto-compact"
# figure, and the status line's context_window.remaining_percentage measures
# the full model window, not the auto-compact point (a 1M-token model with
# autoCompactWindow 250000 still reads about 78% remaining when it compacts).
# This hook therefore derives the figure the way Claude Code 2.1.314 does:
#   tokens      the last request's input + cache_read + cache_creation usage in
#               the session transcript (fm_warm_compact_context_tokens); none
#               until the first request after a compaction
#   compact-at  effective window minus Claude's 13000-token auto-compact buffer,
#               where effective window = autoCompactWindow - 20000 (the output
#               reserve); CLAUDE_AUTOCOMPACT_PCT_OVERRIDE, when set, lowers it
#               to that percentage of the effective window
#   left        (compact-at - tokens) * 100 / compact-at, floored, never < 0
# The window resolves as Claude Code's own resolver does. A usable
# CLAUDE_CODE_AUTO_COMPACT_WINDOW wins. Otherwise the settings layers are walked
# from highest precedence to lowest (the project's .claude/settings.local.json,
# its .claude/settings.json, then user settings under CLAUDE_CONFIG_DIR or
# ~/.claude), and the first layer that sets a modelSettings entry for the
# session's model or a top-level autoCompactWindow decides, the entry winning
# inside its layer. Per-model keys match on the canonical name, so dated and
# [1m] spellings are the same model. A settings value counts only as an integer
# from 100000 to 1000000 (or "auto" in a modelSettings entry); any other value
# counts as unset. Managed settings and a --settings launch flag are not visible
# here; a home that sets the window there, or wants a different point, pins
# compact-at-tokens in config/handoff-trigger.
# When nothing resolves (no autoCompactWindow, or "auto"), the auto-compact point
# depends on the model's window, which no hook input names, so the hook stays
# silent rather than guess. Claude also caps a configured window to the model's
# window, which the hook cannot see, so a home on a smaller-window model must pin
# compact-at-tokens.
# docs/verification/runtime-backends.md records the evidence.
#
# CONFIG (config/handoff-trigger, optional; docs/configuration.md "Early
# handoff trigger" owns the schema). Absent means on at the defaults.
#   percent-left=<n>        fire at or below n% context left (default 15,
#                           0 turns the trigger off, 1-99 otherwise)
#   compact-at-tokens=<n>   the auto-compact point in tokens, overriding the
#                           value derived from Claude's settings
# Blank lines and lines starting with # are ignored; an unusable value keeps
# its default.
#
# SCOPE. Only a genuine primary checkout with its state dir (the
# fm_primary_scope_matches predicate the turn-end guard uses, so a marked
# secondmate home is included and a crew or scout worktree is inert). Grok and
# Cursor load this Claude settings file too; Grok is excluded by the settings
# entry and Cursor by its payload marker, because the trigger is Claude-only.
#
# ONCE PER CONTEXT CYCLE. A cycle is one session id plus the count of compact
# boundary records in its transcript, so a compaction re-arms the trigger. The
# first firing in a cycle creates state/.handoff-trigger.<session-id>.<count>
# with an exclusive create, so concurrent hook calls from parallel tool calls
# still fire once. A firing also removes markers older than 30 days.
#
# RESTART GATE (Stop). A session is handing off once the trigger has fired in
# its current context cycle, or once it ran `bin/fm-order.sh handoff --doc`
# (stow, a restart, or a home with percent-left=0). On each Stop of a session
# handing off, the hook runs `bin/fm-order.sh gate`; when the recorded handoff
# document does not name every open captain order it blocks that stop (exit 2,
# the gate's verdict on stderr) so the session writes the orders into its
# handoff before it reports ready to restart. A session the trigger fired on
# is also blocked until a successor is under way. Where this home's
# config/watchdog sets mode=act, restart=on, and a restart-command, that means
# state/.watchdog-restart-request newer than the firing: the watchdog owns
# launching the successor from that request and verifying it holds the
# session lock (bin/fm-watchdog.sh, docs/watchdog.md). Anywhere else the
# watchdog ignores that request, so the gate clears only when a live successor
# holds the session lock (bin/fm-session-lock-lib.sh), and the block tells the
# session to launch it itself or tell the captain it is waiting. A handoff turn
# therefore cannot end on ready to restart with nobody launching the next
# session.
# An ordinary stop is never gated.
# A stop that already follows a block (stop_hook_active) is allowed, so the
# gate blocks at most once per turn and never wedges the session. It cannot
# stop a human `/quit` or a crash, and it does not run for a non-Claude
# primary; bin/fm-order.sh owns the gate and its limits.
#
# Any failure to read the payload, transcript, or settings is silent: the hook
# never blocks a tool call or prompt and never prints anything but the one
# instruction.
#
# Usage: fm-handoff-trigger.sh            (hook mode: payload JSON on stdin)
#        fm-handoff-trigger.sh -h|--help
set -u

case "${1:-}" in
  -h | --help) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

FM_HANDOFF_PERCENT_DEFAULT=15

command -v jq >/dev/null 2>&1 || exit 0
PAYLOAD=$(cat 2>/dev/null) || exit 0
[ -n "$PAYLOAD" ] || exit 0

# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# Read the threshold from config/handoff-trigger.
PERCENT=$FM_HANDOFF_PERCENT_DEFAULT
if [ -f "$CONFIG/handoff-trigger" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    case "$value" in '' | *[!0-9]*) continue ;; esac
    case "$key" in
      percent-left) [ "${#value}" -le 2 ] && PERCENT=$((10#$value)) ;;
    esac
  done < "$CONFIG/handoff-trigger"
fi

SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty | strings' 2>/dev/null)
TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty | strings' 2>/dev/null)
EVENT=$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty | strings' 2>/dev/null)
case "$EVENT" in PostToolUse | UserPromptSubmit | Stop) ;; *) exit 0 ;; esac

# The trigger marker for this session's context cycle, or empty when the
# transcript cannot say which cycle this is. Count boundaries before reading
# tokens: a compaction landing between the two reads then leaves no usage to
# measure instead of pre-compaction usage in the new cycle.
MARKER=
if [ -n "$SESSION_ID" ] && [ -n "$TRANSCRIPT" ]; then
  BOUNDARIES=$(LC_ALL=C grep -c '"subtype":"compact_boundary"' "$TRANSCRIPT" 2>/dev/null)
  case "$BOUNDARIES" in
    '' | *[!0-9]*) ;;
    *) MARKER="$STATE/.handoff-trigger.$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9_-' '_').$BOUNDARIES" ;;
  esac
fi
if [ "$EVENT" = Stop ]; then
  # Enforce the restart gate only on a session that is handing off: the
  # trigger fired in this cycle, or this session recorded a handoff document
  # (bin/fm-order.sh handing-off), which also covers percent-left=0. Another
  # session's handoff record in the same home never gates this stop.
  { [ -n "$MARKER" ] && [ -e "$MARKER" ]; } ||
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-order.sh" handing-off 2>/dev/null || exit 0
  [ "$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null)" != true ] || exit 0
  GATE_RC=0
  GATE_OUT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-order.sh" gate 2>/dev/null) || GATE_RC=$?
  if [ "$GATE_RC" -eq 3 ]; then
    printf 'Firstmate restart gate: this session is handing off, but its handoff does not list every open captain order. %s
' \
      "$(printf '%s' "$GATE_OUT" | tr '\n' ' ')" >&2
    exit 2
  fi
  # Successor gate: only a session the trigger fired on in this cycle owes a
  # successor; a handoff recorded for stow or compaction does not. A restart
  # request counts only where this home's watchdog acts on it (docs/watchdog.md
  # "Restart"); elsewhere the successor must already hold the session lock.
  if [ -n "$MARKER" ] && [ -e "$MARKER" ]; then
    # shellcheck source=bin/fm-watchdog-lib.sh
    . "$SCRIPT_DIR/fm-watchdog-lib.sh"
    if [ "$(fm_wd_conf_get "$CONFIG/watchdog" mode dry-run)" = act ] &&
      [ "$(fm_wd_conf_get "$CONFIG/watchdog" restart off)" = on ] &&
      [ -n "$(fm_wd_conf_get "$CONFIG/watchdog" restart-command "")" ]; then
      REQ="$STATE/.watchdog-restart-request"
      if [ ! -e "$REQ" ] || [ "$MARKER" -nt "$REQ" ]; then
        printf 'Firstmate restart gate: this session is handing off, but it has not requested its successor. Create state/.watchdog-restart-request in this home so the watchdog launches the successor and verifies it holds the session lock, then end the turn. Ending on ready to restart without that request leaves the fleet unsupervised.\n' >&2
        exit 2
      fi
    else
      # shellcheck source=bin/fm-session-lock-lib.sh
      . "$SCRIPT_DIR/fm-session-lock-lib.sh"
      if ! fm_session_lock_foreign_owner_live "$STATE"; then
        printf 'Firstmate restart gate: this session is handing off, but no successor holds the session lock, and this home'"'"'s watchdog will not launch one (config/watchdog does not set mode=act, restart=on, and a restart-command), so a restart request alone starts nobody. Launch your successor yourself: open a new terminal on this home'"'"'s backend and start a firstmate session there with a prompt naming your handoff document. The successor takes the session lock only after this session exits, so confirm with bin/fm-lock.sh status that it holds the lock; if you cannot confirm that, tell the captain plainly that no successor is running yet and that this session must be quit for it to take over. Do not end on ready to restart as if the handoff were complete.\n' >&2
        exit 2
      fi
    fi
  fi
  exit 0
fi
[ "$PERCENT" -gt 0 ] || exit 0
[ -n "$MARKER" ] || exit 0
[ -e "$MARKER" ] && exit 0

# shellcheck source=bin/fm-warm-compact-lib.sh
. "$SCRIPT_DIR/fm-warm-compact-lib.sh"
TOKENS=$(fm_warm_compact_context_tokens "$TRANSCRIPT") || exit 0
case "$TOKENS" in '' | *[!0-9]*) exit 0 ;; esac

# shellcheck source=bin/fm-compact-point-lib.sh
. "$SCRIPT_DIR/fm-compact-point-lib.sh"
COMPACT_AT=$(fm_compact_at_tokens "$TRANSCRIPT" "$CONFIG/handoff-trigger") || exit 0

LEFT=$(fm_compact_left_percent "$TOKENS" "$COMPACT_AT")
[ "$LEFT" -le "$PERCENT" ] || exit 0

# Claim the one firing for this context cycle; a concurrent call that loses exits.
( set -o noclobber; printf '%s\n' "$(date +%s) tokens=$TOKENS compact_at=$COMPACT_AT" > "$MARKER" ) 2>/dev/null || exit 0
find "$STATE" -maxdepth 1 -name '.handoff-trigger.*' -type f -mtime +30 -exec rm -f {} + 2>/dev/null

MESSAGE="Firstmate early handoff trigger, from this home's tracked Claude hook: about ${LEFT}% of context is left before auto-compact (${TOKENS} of ${COMPACT_AT} tokens). Write your full session handoff now, before auto-compact: persist every open work record, decision, and piece of durable knowledge this session holds (the stow skill covers this), record the handoff with bin/fm-order.sh handoff --doc <handoff file>, then hand off to a successor and report that this session is ready to restart. Where this home's config/watchdog sets mode=act, restart=on, and a restart-command, request the successor by creating state/.watchdog-restart-request in this home: the watchdog launches it and verifies it holds the session lock. Otherwise no watchdog will act on that request, so launch the successor yourself in a new terminal on this home's backend with a prompt naming your handoff document, and confirm it holds the session lock or tell the captain it is waiting for this session to be quit. Do not end this turn on ready to restart until one of those has happened. Do not run /compact. This instruction fires once per context cycle."
# Durable captain orders are part of the handoff: name each open order and the
# command that writes them into the handoff document (bin/fm-order.sh owns the
# list and the restart gate this hook enforces on Stop).
ORDERS=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-order.sh" pickup 2>/dev/null \
  | awk '/^  [0-9]+-[0-9a-f]+ / && $3 ~ /^kind=/ { printf "%s%s (%s)", sep, $1, $2; sep = ", " }')
if [ -n "$ORDERS" ]; then
  MESSAGE="$MESSAGE Open captain orders that your handoff must list: ${ORDERS}. Write them into your handoff document with bin/fm-order.sh handoff --doc <handoff file>; this session cannot end its handoff turn until bin/fm-order.sh gate passes."
fi
jq -n --arg event "$EVENT" --arg context "$MESSAGE" \
  '{hookSpecificOutput: {hookEventName: $event, additionalContext: $context}}'
