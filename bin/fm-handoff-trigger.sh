#!/usr/bin/env bash
# fm-handoff-trigger.sh - early handoff trigger for a Claude primary session.
#
# Registered in tracked .claude/settings.json as a PostToolUse, a
# UserPromptSubmit, and a Stop command hook. When the session's context left before
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
# RESTART GATE (Stop). A session is handing off once the trigger has fired in
# its current context cycle, or once it ran `bin/fm-order.sh handoff --doc`
# (stow, a restart, or a home with percent-left=0). On each Stop of a session
# handing off, the hook runs `bin/fm-order.sh gate`; when the recorded handoff
# document does not name every open captain order it blocks that stop (exit 2,
# the gate's verdict on stderr) so the session writes the orders into its
# handoff before it reports ready to restart. An ordinary stop is never gated.
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
  # trigger fired in this cycle, or the session recorded a handoff document
  # (state/.order-handoff, owned by bin/fm-order.sh), which also covers
  # percent-left=0.
  { [ -n "$MARKER" ] && [ -e "$MARKER" ]; } || [ -e "$STATE/.order-handoff" ] || exit 0
  [ "$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null)" != true ] || exit 0
  GATE_RC=0
  GATE_OUT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-order.sh" gate 2>/dev/null) || GATE_RC=$?
  [ "$GATE_RC" -eq 3 ] || exit 0
  printf 'Firstmate restart gate: this session is handing off, but its handoff does not list every open captain order. %s
' \
    "$(printf '%s' "$GATE_OUT" | tr '\n' ' ')" >&2
  exit 2
fi
[ "$PERCENT" -gt 0 ] || exit 0
[ -n "$MARKER" ] || exit 0
[ -e "$MARKER" ] && exit 0

# shellcheck source=bin/fm-warm-compact-lib.sh
. "$SCRIPT_DIR/fm-warm-compact-lib.sh"
TOKENS=$(fm_warm_compact_context_tokens "$TRANSCRIPT") || exit 0
case "$TOKENS" in '' | *[!0-9]*) exit 0 ;; esac

# Print the window CLAUDE_CODE_AUTO_COMPACT_WINDOW value $1 means in tokens,
# clamped to Claude's limits; fail when Claude would ignore the value.
env_window() {
  awk -v raw="$1" 'BEGIN {
    gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", raw)
    if (raw !~ /^[0-9]+(\.[0-9]+)?[kKmM]?$/) exit 1
    n = raw + 0
    unit = tolower(substr(raw, length(raw)))
    if (unit == "m") n *= 1000000
    else if (unit == "k") n *= 1000
    if (n < 1) exit 1
    if (n < 100000) n = 100000
    if (n > 1000000) n = 1000000
    printf "%d\n", n + 0.5
  }'
}

# Print the window Claude applies to model $1; fail when it is "auto" or unset.
auto_compact_window() {
  local model=$1 file value project
  env_window "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}" && return 0
  project=${CLAUDE_PROJECT_DIR:-$FM_ROOT}
  for file in "$project/.claude/settings.local.json" "$project/.claude/settings.json" \
    "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"; do
    [ -r "$file" ] || continue
    value=$(jq -r --arg m "$model" '
        def canon: ascii_downcase | sub("\\[1m\\]$"; "") | sub("-[0-9]{8}$"; "");
        def size: select(type == "number" and . == floor and . >= 100000 and . <= 1000000) | tostring;
        def entry: if . == "auto" then . else size end;
        ($m | canon) as $c
        | first(
            ([.modelSettings | objects | to_entries[]
              | select(.key | canon == $c)
              | {exact: (.key == $c), window: (.value | objects | .autoCompactWindow | entry)}]
             | sort_by(.exact | not) | .[].window),
            (.autoCompactWindow | size)
          )
      ' "$file" 2>/dev/null)
    case "$value" in
      '') ;;
      auto) return 1 ;;
      *) printf '%s\n' "$value"; return 0 ;;
    esac
  done
  return 1
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

# Claim the one firing for this context cycle; a concurrent call that loses exits.
( set -o noclobber; printf '%s\n' "$(date +%s) tokens=$TOKENS compact_at=$COMPACT_AT" > "$MARKER" ) 2>/dev/null || exit 0
find "$STATE" -maxdepth 1 -name '.handoff-trigger.*' -type f -mtime +30 -exec rm -f {} + 2>/dev/null

MESSAGE="Firstmate early handoff trigger, from this home's tracked Claude hook: about ${LEFT}% of context is left before auto-compact (${TOKENS} of ${COMPACT_AT} tokens). Write your full session handoff now, before auto-compact: persist every open work record, decision, and piece of durable knowledge this session holds (the stow skill covers this), then report that this session is ready to restart. Do not run /compact. This instruction fires once per context cycle."
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
