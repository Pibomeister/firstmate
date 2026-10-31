#!/usr/bin/env bash
# fm-handoff-trigger.sh - early handoff trigger for a Claude primary session.
#
# Registered in tracked .claude/settings.json as a PostToolUse and a
# UserPromptSubmit command hook. When the session's context left before
# auto-compact falls to the configured percentage (default 15), the session
# receives ONE instruction, as hook additionalContext, to write its full
# handoff before auto-compact and report that it is ready to restart. It fires
# at most once per Claude session id, so a session that keeps working past the
# threshold is not nagged again.
#
# CONTEXT LEFT. Claude Code does not hand hooks its own "% until auto-compact"
# figure, and the status line's context_window.remaining_percentage measures
# the full model window, not the auto-compact point (a 1M-token model with
# autoCompactWindow 250000 still reads about 78% remaining when it compacts).
# This hook therefore derives the figure the way Claude Code 2.1.314 does:
#   tokens      the last request's input + cache_read + cache_creation usage in
#               the session transcript (fm_warm_compact_context_tokens)
#   compact-at  effective window minus Claude's 13000-token auto-compact buffer,
#               where effective window = autoCompactWindow - 20000 (the output
#               reserve); CLAUDE_AUTOCOMPACT_PCT_OVERRIDE, when set, lowers it
#               to that percentage of the effective window
#   left        (compact-at - tokens) * 100 / compact-at, floored, never < 0
# autoCompactWindow is read from Claude's own settings layers (user settings
# under CLAUDE_CONFIG_DIR or ~/.claude, then the project's .claude/settings.json
# and .claude/settings.local.json), a modelSettings entry for the session's
# model winning over the top-level value. Managed settings and a --settings
# launch flag are not visible here; a home that sets the window there, or
# wants a different point, pins compact-at-tokens in config/handoff-trigger.
# When neither resolves (no autoCompactWindow, or the value "auto"), the
# auto-compact point depends on the model's window, which no hook input names,
# so the hook stays silent rather than guess.
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
# FIRE ONCE. The first firing for a session creates
# state/.handoff-trigger.<session-id> with an exclusive create, so concurrent
# hook calls from parallel tool calls still fire once. A firing also removes
# markers older than 30 days.
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
FM_HANDOFF_OUTPUT_RESERVE=20000
FM_HANDOFF_COMPACT_BUFFER=13000

command -v jq >/dev/null 2>&1 || exit 0
PAYLOAD=$(cat 2>/dev/null) || exit 0
[ -n "$PAYLOAD" ] || exit 0

# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# Read the threshold and any pinned compact point from config/handoff-trigger.
PERCENT=$FM_HANDOFF_PERCENT_DEFAULT
COMPACT_AT=
if [ -f "$CONFIG/handoff-trigger" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    case "$value" in '' | *[!0-9]*) continue ;; esac
    case "$key" in
      percent-left) [ "${#value}" -le 2 ] && PERCENT=$((10#$value)) ;;
      compact-at-tokens) case "$value" in 0*) ;; *) COMPACT_AT=$value ;; esac ;;
    esac
  done < "$CONFIG/handoff-trigger"
fi
[ "$PERCENT" -gt 0 ] || exit 0

SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty | strings' 2>/dev/null)
TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty | strings' 2>/dev/null)
EVENT=$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty | strings' 2>/dev/null)
[ -n "$SESSION_ID" ] && [ -n "$TRANSCRIPT" ] || exit 0
case "$EVENT" in PostToolUse | UserPromptSubmit) ;; *) exit 0 ;; esac
MARKER="$STATE/.handoff-trigger.$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9_-' '_')"
[ -e "$MARKER" ] && exit 0

# shellcheck source=bin/fm-warm-compact-lib.sh
. "$SCRIPT_DIR/fm-warm-compact-lib.sh"
TOKENS=$(fm_warm_compact_context_tokens "$TRANSCRIPT") || exit 0
case "$TOKENS" in '' | *[!0-9]*) exit 0 ;; esac

# Print a settings window value in tokens: a positive integer, or "<n>k".
window_tokens() {
  case "$1" in
    '' | 0* | *[!0-9kK]*) return 1 ;;
    *[kK]) case "${1%?}" in '' | *[!0-9]*) return 1 ;; esac; printf '%s\n' "$((${1%?} * 1000))" ;;
    *[!0-9]*) return 1 ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Print the autoCompactWindow Claude applies to model $1, from its settings
# layers lowest to highest precedence; a modelSettings entry beats top-level.
auto_compact_window() {
  local model=$1 file per_model='' top='' value project
  project=${CLAUDE_PROJECT_DIR:-$FM_ROOT}
  for file in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" \
    "$project/.claude/settings.json" "$project/.claude/settings.local.json"; do
    [ -r "$file" ] || continue
    value=$(jq -r --arg m "$model" '
        .modelSettings[$m].autoCompactWindow // empty | tostring
      ' "$file" 2>/dev/null) && [ -n "$value" ] && per_model=$value
    value=$(jq -r '.autoCompactWindow // empty | tostring' "$file" 2>/dev/null) \
      && [ -n "$value" ] && top=$value
  done
  window_tokens "${per_model:-$top}"
}

if [ -z "$COMPACT_AT" ]; then
  MODEL=$(tail -n 400 "$TRANSCRIPT" 2>/dev/null | jq -R -r '
      fromjson? | select(.type == "assistant") | .message.model // empty | strings
    ' 2>/dev/null | tail -n 1)
  WINDOW=$(auto_compact_window "$MODEL") || exit 0
  EFFECTIVE=$((WINDOW - FM_HANDOFF_OUTPUT_RESERVE))
  COMPACT_AT=$((EFFECTIVE - FM_HANDOFF_COMPACT_BUFFER))
  pct=${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-}
  case "$pct" in
    '' | *[!0-9.]* | *.*.*) ;;
    *)
      pct_at=$(awk -v w="$EFFECTIVE" -v p="$pct" 'BEGIN { if (p > 0 && p <= 100) printf "%d", w * p / 100 }')
      [ -n "$pct_at" ] && [ "$pct_at" -lt "$COMPACT_AT" ] && COMPACT_AT=$pct_at
      ;;
  esac
fi
[ "$COMPACT_AT" -gt 0 ] || exit 0

LEFT=$(((COMPACT_AT - TOKENS) * 100 / COMPACT_AT))
[ "$LEFT" -ge 0 ] || LEFT=0
[ "$LEFT" -le "$PERCENT" ] || exit 0

# Claim the one firing for this session; a concurrent call that loses exits.
( set -o noclobber; printf '%s\n' "$(date +%s) tokens=$TOKENS compact_at=$COMPACT_AT" > "$MARKER" ) 2>/dev/null || exit 0
find "$STATE" -maxdepth 1 -name '.handoff-trigger.*' -type f -mtime +30 -exec rm -f {} + 2>/dev/null

MESSAGE="Firstmate early handoff trigger, from this home's tracked Claude hook: about ${LEFT}% of context is left before auto-compact (${TOKENS} of ${COMPACT_AT} tokens). Write your full session handoff now, before auto-compact: persist every open work record, decision, and piece of durable knowledge this session holds (the stow skill covers this), then report that this session is ready to restart. Do not run /compact. This instruction fires once per session."
jq -n --arg event "$EVENT" --arg context "$MESSAGE" \
  '{hookSpecificOutput: {hookEventName: $event, additionalContext: $context}}'
