#!/usr/bin/env bash
# fm-handoff-trigger.sh - early handoff trigger for a Claude primary session.
#
# Registered in tracked .claude/settings.json as a PostToolUse and a
# UserPromptSubmit command hook. When the session's context left before
# auto-compact falls to the configured percentage (default 15), the session
# receives ONE instruction, as hook additionalContext, to write its full
# handoff before auto-compact and report that it is ready to restart. It fires
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
[ "$PERCENT" -gt 0 ] || exit 0

SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty | strings' 2>/dev/null)
TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty | strings' 2>/dev/null)
EVENT=$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty | strings' 2>/dev/null)
[ -n "$SESSION_ID" ] && [ -n "$TRANSCRIPT" ] || exit 0
case "$EVENT" in PostToolUse | UserPromptSubmit) ;; *) exit 0 ;; esac

# Count boundaries before reading tokens: a compaction landing between the two
# reads then leaves no usage to measure instead of pre-compaction usage in the
# new cycle.
BOUNDARIES=$(LC_ALL=C grep -c '"subtype":"compact_boundary"' "$TRANSCRIPT" 2>/dev/null)
case "$BOUNDARIES" in '' | *[!0-9]*) exit 0 ;; esac
MARKER="$STATE/.handoff-trigger.$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9_-' '_').$BOUNDARIES"
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

MESSAGE="Firstmate early handoff trigger, from this home's tracked Claude hook: about ${LEFT}% of context is left before auto-compact (${TOKENS} of ${COMPACT_AT} tokens). Write your full session handoff now, before auto-compact: persist every open work record, decision, and piece of durable knowledge this session holds (the stow skill covers this), then report that this session is ready to restart. Do not run /compact. This instruction fires once per context cycle."
jq -n --arg event "$EVENT" --arg context "$MESSAGE" \
  '{hookSpecificOutput: {hookEventName: $event, additionalContext: $context}}'
