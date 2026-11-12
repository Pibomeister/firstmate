#!/usr/bin/env bash
# fm-handoff-trigger.sh - early handoff trigger for a Claude primary session.
#
# Registered in tracked .claude/settings.json as a PostToolUse, a
# UserPromptSubmit, and a Stop command hook. When the session's context left before
# auto-compact falls to the configured percentage (default 15), the session
# receives ONE instruction, as hook additionalContext, to write its handoff
# from the mission ledger (bin/fm-ledger.sh handoff) before auto-compact, hand
# off to a live successor it launches with bin/fm-handoff-launch.sh (a second
# mate asks its parent to relaunch it instead), and report that it is ready to
# restart. It fires
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
# PUBLISHED POINT. On each PostToolUse or UserPromptSubmit run with a session
# id and a transcript, whatever percent-left says, the hook writes the point it
# resolved to state/compact-point as one line,
#   session=<id> compact_at=<tokens> at=<epoch>
# with an atomic rename, so a reader outside the session (the watchdog, through
# bin/fm-context-reading-lib.sh) uses the same window. A run that resolves no
# point removes a record that names its session. The record never changes this
# hook's own decision.
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
# ONCE PER SESSION. A firing claims, with exclusive creates, both the cycle
# marker state/.handoff-trigger.<session-id>.<count> (a cycle is one session id
# plus the count of compact boundary records in its transcript; the restart
# gate below reads it) and the per-session park-then-handoff claim
# state/.context-autopark.<session> that bin/fm-context-burn.sh's turn-end
# recorder shares. Whichever channel claims first emits the action; the other
# stays silent for the rest of the session, including after a compaction, and
# concurrent hook calls from parallel tool calls still fire once. A firing also
# removes markers older than 30 days.
#
# RESTART GATE (Stop). A session is handing off once the trigger has fired in
# its current context cycle, or once it ran `bin/fm-order.sh handoff --doc`
# (stow, a restart, or a home with percent-left=0). On each Stop of a session
# handing off, the hook runs `bin/fm-order.sh gate`; when the recorded handoff
# document does not name every open captain order it blocks that stop (exit 2,
# the gate's verdict on stderr) so the session writes the orders into its
# handoff before it reports ready to restart. A session the trigger fired on
# is also blocked until fm-handoff-lib.sh validates the completed successor's
# acknowledgement, digest, process instance and lock ownership. The completion
# record must be newer than this cycle's trigger marker. The successor confirms
# the handoff sha256 and stops on a mismatch. The lock transfers while this
# session is still alive, so no external exit is required. A second mate never launches its own
# successor and is not gated: its trigger instruction has it append one
# relaunch request to its parent channel and stop.
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

# publish_compact_point: write the point this run resolved, named for its
# session, to state/compact-point with an atomic rename, for readers outside the
# session (bin/fm-context-reading-lib.sh). A run that resolves no point
# withdraws its own session's record, so an outside reader never keeps a window
# this session no longer has.
publish_compact_point() {
  local record=$STATE/compact-point tmp
  [ -n "$SESSION_ID" ] || return 0
  case "$SESSION_ID" in *[!A-Za-z0-9_-]*) return 0 ;; esac
  if [ -z "$COMPACT_AT" ]; then
    [ "$(sed -n '1s/^session=\([^ ]*\) .*/\1/p' "$record" 2>/dev/null)" != "$SESSION_ID" ] || rm -f "$record"
    return 0
  fi
  tmp=$(mktemp "$record.XXXXXX" 2>/dev/null) || return 0
  if printf 'session=%s compact_at=%s at=%s\n' "$SESSION_ID" "$COMPACT_AT" "$(date +%s)" > "$tmp" && mv -f "$tmp" "$record"; then
    return 0
  fi
  rm -f "$tmp"
}

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
  # Shared quota/park policy also covers this parallel Stop writer.
  # shellcheck source=bin/fm-stop-policy-lib.sh
  . "$SCRIPT_DIR/fm-stop-policy-lib.sh"
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
    fm_stop_policy_allows_stop "$PAYLOAD" charge && exit 0
    printf 'Firstmate restart gate: this session is handing off, but its handoff does not list every open captain order. %s
' \
      "$(printf '%s' "$GATE_OUT" | tr '\n' ' ')" >&2
    exit 2
  fi
  # Successor gate: only a session the trigger fired on in this cycle owes a
  # successor; a handoff recorded for stow or compaction does not, and a
  # second mate asks its parent for a relaunch instead.
  if [ -n "$MARKER" ] && [ -e "$MARKER" ] && ! fm_root_is_secondmate_home "$FM_ROOT"; then
    LAUNCH="$STATE/.handoff-successor"
    # shellcheck source=bin/fm-session-lock-lib.sh
    . "$SCRIPT_DIR/fm-session-lock-lib.sh"
    # shellcheck source=bin/fm-handoff-lib.sh
    . "$SCRIPT_DIR/fm-handoff-lib.sh"
    if [ "$MARKER" -nt "$LAUNCH" ] || ! fm_handoff_completed "$LAUNCH"; then
      fm_stop_policy_allows_stop "$PAYLOAD" charge && exit 0
      printf '%s\n' 'Firstmate restart gate: no verified successor acknowledgement and lock transfer is recorded in state/.handoff-successor. Run bin/fm-handoff-launch.sh <handoff document path>. A live PID alone does not clear this gate. The successor confirms the handoff sha256 and stops on a mismatch. The lock transfers while this session is still alive, so do not wait for an external exit.' >&2
      exit 2
    fi
  fi
  exit 0
fi
# shellcheck source=bin/fm-compact-point-lib.sh
. "$SCRIPT_DIR/fm-compact-point-lib.sh"
COMPACT_AT=
[ -z "$SESSION_ID" ] || [ -z "$TRANSCRIPT" ] ||
  COMPACT_AT=$(fm_compact_at_tokens "$TRANSCRIPT" "$CONFIG/handoff-trigger") || COMPACT_AT=
publish_compact_point

[ "$PERCENT" -gt 0 ] || exit 0
[ -n "$MARKER" ] || exit 0
[ -e "$MARKER" ] && exit 0
AUTOPARK="$STATE/.context-autopark.$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9_' '_')"
[ -e "$AUTOPARK" ] && exit 0
[ -n "$COMPACT_AT" ] || exit 0

# shellcheck source=bin/fm-warm-compact-lib.sh
. "$SCRIPT_DIR/fm-warm-compact-lib.sh"
TOKENS=$(fm_warm_compact_context_tokens "$TRANSCRIPT") || exit 0
case "$TOKENS" in '' | *[!0-9]*) exit 0 ;; esac

LEFT=$(fm_compact_left_percent "$TOKENS" "$COMPACT_AT")
[ "$LEFT" -le "$PERCENT" ] || exit 0

# Claim the one firing for this context cycle; a concurrent call that loses exits.
( set -o noclobber; printf '%s\n' "$(date +%s) tokens=$TOKENS compact_at=$COMPACT_AT" > "$MARKER" ) 2>/dev/null || exit 0
if ! ( set -o noclobber; printf 'done %s hook\n' "$(date +%s)" > "$AUTOPARK" ) 2>/dev/null; then
  rm -f "$MARKER"
  exit 0
fi
find "$STATE" -maxdepth 1 -name '.handoff-trigger.*' -type f -mtime +30 -exec rm -f {} + 2>/dev/null

MESSAGE="Firstmate early handoff trigger, from this home's tracked Claude hook: about ${LEFT}% of context is left before auto-compact (${TOKENS} of ${COMPACT_AT} tokens). Park first, then hand off: park every open captain question as a held backlog item through bin/fm-captain-hold.sh (hold the work item the question gates, or create one captain-held task per genuine question) without asking the captain or waiting for an answer, and keep working on everything the parked questions do not gate. Then write your session handoff now, before auto-compact, from the mission ledger: file every open ask, approved proposal, and captain order that has no backlog item yet as its own item with bin/fm-ledger.sh intake, bring each item's note current, and persist every decision and piece of durable knowledge this session holds (the stow skill covers this). Then write a new handoff with bin/fm-ledger.sh handoff --doc <new handoff file> --note-file <short note of what is in flight right now>: it adds that note to the ledger plan, never continues an earlier handoff, and records the document with bin/fm-order.sh handoff --doc. If bin/fm-ledger.sh cannot read the backlog, do not skip the handoff: write a new handoff document yourself with the in-flight note, the open work, and bin/fm-dispatch-log.sh open, record it with bin/fm-order.sh handoff --doc <that file>, and say in it that the ledger was unreadable. Then hand off to a successor and report that this session is ready to restart."
if fm_root_is_secondmate_home "$FM_ROOT"; then
  MESSAGE="$MESSAGE This is a second mate, so never launch your own successor: append to your parent channel that your handoff is written, name the handoff document, and ask the parent to relaunch you, once, then end this turn."
else
  MESSAGE="$MESSAGE Launch your successor with bin/fm-handoff-launch.sh <handoff file>. Run it with the Bash tool's run_in_background=true, because a foreground tool timeout cannot cover its setup plus the ten-minute protocol deadline, and collect the launcher's exit status and output before reporting readiness. It requires the successor to read the document, write its nonce-bound acknowledgement with bin/fm-handoff-ack.sh, and take the session lock before state/.handoff-successor clears this turn's gate. The successor confirms the handoff sha256 and stops on a mismatch. The lock transfers while this session is still alive, so do not wait for an external exit. The successor then runs bin/fm-session-start.sh. After verified transfer, end this turn and retire the predecessor session. If both attempts fail within ten minutes, the launcher emits handoff_failed; report that failure instead of claiming readiness. A failure with reason=unresolved is not final: a later handoff_ack with reason=lock_transferred for the same nonce means the transfer committed."
fi
MESSAGE="$MESSAGE Do not run /compact. This instruction fires once per session."
# Durable captain orders are part of the handoff: name each open order and the
# command that writes them into the handoff document (bin/fm-order.sh owns the
# list and the restart gate this hook enforces on Stop).
ORDERS=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-order.sh" pickup 2>/dev/null \
  | awk '/^  [0-9]+-[0-9a-f]+ / && $3 ~ /^kind=/ { printf "%s%s (%s)", sep, $1, $2; sep = ", " }')
if [ -n "$ORDERS" ]; then
  MESSAGE="$MESSAGE Open captain orders that your handoff must list: ${ORDERS}. File each order that is not a hold as its own ledger item with bin/fm-ledger.sh intake --source order:<id>; bin/fm-ledger.sh handoff then writes them into your handoff document through bin/fm-order.sh handoff --doc, and this session cannot end its handoff turn until bin/fm-order.sh gate passes."
fi
jq -n --arg event "$EVENT" --arg context "$MESSAGE" \
  '{hookSpecificOutput: {hookEventName: $event, additionalContext: $context}}'
