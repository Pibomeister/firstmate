#!/usr/bin/env bash
# fm-handoff-trigger.sh - context trigger for a Claude primary session.
#
# Registered in tracked .claude/settings.json as a PostToolUse, a
# UserPromptSubmit, and a Stop command hook. When the session's context left before
# auto-compact falls to the configured percentage (default 15), the session
# receives ONE instruction, as hook additionalContext, once per context cycle.
# Compaction-first: auto-compaction is the routine reset on the same harness, so
# the instruction is normally a CAPTURE step - file every piece of open work that
# lives only in the chat into its durable record, then let auto-compaction run;
# it never asks for a successor and never gates a stop. A cycle ends in a
# planned FRESH START (a full handoff to a live successor the session launches
# with bin/fm-handoff-launch.sh; a second mate asks its parent to relaunch it)
# only at the drift cap: once the transcript holds fresh-start-after compaction
# boundaries, or when the first context reading after the latest compaction is
# at or above fresh-start-context-tokens. fresh-start-after=0 restores a handoff
# every cycle. A handoff for quota exhaustion or a harness switch is a
# deliberate handoff the session or the captain starts on the same paths.
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
#   session=<id> compact_at=<tokens> at=<epoch> reset=compaction|handoff
# with an atomic rename, so a reader outside the session (the watchdog, through
# bin/fm-context-reading-lib.sh) uses the same window and knows whether this
# cycle ends in auto-compaction or in a planned fresh start. A run that resolves
# no point removes a record that names its session. The record never changes
# this hook's own decision.
#
# CONFIG (config/handoff-trigger, optional; docs/configuration.md "Early
# handoff trigger" owns the schema). Absent means on at the defaults.
#   percent-left=<n>        fire at or below n% context left (default 15,
#                           0 turns the trigger off, 1-99 otherwise)
#   compact-at-tokens=<n>   the auto-compact point in tokens, overriding the
#                           value derived from Claude's settings
#   fresh-start-after=<n>   the drift cap in compactions (default 4; 0 hands
#                           off every cycle)
#   fresh-start-context-tokens=<n>
#                           a first reading after compaction at or above n
#                           makes the cycle a fresh start (default 135000;
#                           0 turns that reading off)
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
# still fire once; the marker records mode=capture or mode=handoff, and a marker
# without a mode (written before compaction-first) counts as a handoff. A
# firing also removes markers older than 30 days.
#
# RESTART GATE (Stop). A session is handing off while its newest firing is a
# fresh start, which a compaction inside that turn does not close (only a newer
# firing or, for an earlier cycle's firing, a launch failure does), or once it ran
# `bin/fm-order.sh handoff --doc` (stow, a restart, a deliberate handoff, or a
# home with percent-left=0). A capture firing is not a handoff. On each Stop of
# a session handing off, the hook runs `bin/fm-order.sh gate`; when the recorded
# handoff document does not name every open captain order it blocks that stop
# (exit 2, the gate's verdict on stderr) so the session writes the orders into
# its handoff before it ends the turn. A primary with a fresh-start firing is
# also blocked until a successor is under way: state/.handoff-successor,
# written by bin/fm-handoff-launch.sh (or by another launcher writing the same
# record), must be newer than the firing and carry pid=<successor pid> for a
# process alive now, with handoff=<handoff document path> beside it. A
# state/.handoff-launch-failed record newer than the firing (the launcher's
# final failure) also releases the stop, so the session can tell the captain,
# keep working, and let auto-compaction run; the next cycle retries.
# A second mate never launches its own successor and is not successor-gated: its
# instruction has it append one relaunch request to its parent channel and stop.
# An ordinary stop is never gated.
# A stop that already follows a block (stop_hook_active) is allowed, so the
# gate blocks at most once per turn and never wedges the session. It cannot
# stop a human `/quit` or a crash, and it does not run for a non-Claude
# primary; bin/fm-order.sh owns the gate and its limits.
#
# DELIBERATE HANDOFF. A primary with no open fresh-start firing is on a
# deliberate handoff while state/.handoff-successor names a live successor pid
# and predecessor=<this session's lock pid>, the field bin/fm-handoff-launch.sh
# writes; a record that names another predecessor belongs to an earlier
# handoff. That record, not state/.order-handoff, is the evidence, so a rerun
# of handoff --doc or a compaction before the stop does not close it. Its stop
# is blocked once per turn while `bin/fm-order.sh covers` finds an open captain
# order missing from the record's handoff=<document>.
#
# ONE LIVE PANE. When a primary's stop passes with the order gate clear, this
# session holding the session lock, and either a fresh-start firing with a live
# successor recorded, or a deliberate handoff whose successor's handoff document
# lists every open captain order, the hook detaches
# `bin/fm-handoff-launch.sh --end-predecessor <lock pid> <transcript> <bytes>`,
# which ends this session after a quiet settle unless the transcript shows a
# new turn; that script's header owns the checks. The successor waits for that
# end before it runs bin/fm-session-start.sh, so exactly one session runs.
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
FM_HANDOFF_FRESH_AFTER_DEFAULT=4
FM_HANDOFF_FRESH_TOKENS_DEFAULT=135000

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
FRESH_AFTER=$FM_HANDOFF_FRESH_AFTER_DEFAULT
FRESH_TOKENS=$FM_HANDOFF_FRESH_TOKENS_DEFAULT
if [ -f "$CONFIG/handoff-trigger" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    case "$value" in '' | *[!0-9]*) continue ;; esac
    case "$key" in
      percent-left) [ "${#value}" -le 2 ] && PERCENT=$((10#$value)) ;;
      fresh-start-after) [ "${#value}" -le 3 ] && FRESH_AFTER=$((10#$value)) ;;
      fresh-start-context-tokens) [ "${#value}" -le 7 ] && FRESH_TOKENS=$((10#$value)) ;;
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
  if printf 'session=%s compact_at=%s at=%s%s\n' "$SESSION_ID" "$COMPACT_AT" "$(date +%s)" \
    "${MODE:+ reset=$( [ "$MODE" = capture ] && echo compaction || echo handoff)}" > "$tmp" && mv -f "$tmp" "$record"; then
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
BOUNDARIES=
if [ -n "$SESSION_ID" ] && [ -n "$TRANSCRIPT" ]; then
  BOUNDARIES=$(LC_ALL=C grep -c '"subtype":"compact_boundary"' "$TRANSCRIPT" 2>/dev/null)
  case "$BOUNDARIES" in
    '' | *[!0-9]*) BOUNDARIES= ;;
    *) MARKER="$STATE/.handoff-trigger.$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9_-' '_').$BOUNDARIES" ;;
  esac
fi

# detach_ender <lock pid>: detach the launcher's ender for this session, so the
# stop that ends the handoff turn also ends the old session. The caller has
# checked that this session holds the session lock and that a live successor is
# another process. The ender is detached before the slower gate checks, so a
# hook that Claude cancels at its timeout on a loaded host still ends the old
# session; the ender waits until this hook has exited, then rechecks the lock,
# the live successor, new turns, and order coverage after its settle. A stop
# that this hook blocks cancels the ender with cancel_ender before it exits.
ENDER=
detach_ender() {
  local size
  [ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || return 0
  size=$(wc -c < "$TRANSCRIPT" 2>/dev/null | tr -d ' ')
  case "$size" in '' | *[!0-9]*) return 0 ;; esac
  set -m
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" FM_HANDOFF_END_AFTER_PID=$$ \
    nohup "$SCRIPT_DIR/fm-handoff-launch.sh" --end-predecessor "$1" "$TRANSCRIPT" "$size" \
    >/dev/null 2>&1 </dev/null &
  ENDER=$!
  set +m
}

# cancel_ender: stop a detached ender, for every stop that does not end the
# old session.
cancel_ender() {
  [ -n "$ENDER" ] || return 0
  kill -TERM -- "-$ENDER" 2>/dev/null || kill -TERM "$ENDER" 2>/dev/null
  ENDER=
}

# newest_firing: this session's newest trigger marker at or below the current
# cycle count, or nothing. A compaction that lands inside a fresh-start turn
# advances the count before that turn's stop, so the current cycle can have no
# marker while the session's newest firing is still that open fresh start. An
# earlier cycle's firing stays open only until a launch failure releases it,
# because the cycle after a failed launch retries on its own firing.
newest_firing() {
  local f n best='' best_n=-1
  for f in "${MARKER%.*}".*; do
    [ -f "$f" ] || continue
    n=${f##*.}
    case "$n" in '' | *[!0-9]*) continue ;; esac
    [ "$n" -le "$BOUNDARIES" ] && [ "$n" -gt "$best_n" ] || continue
    best=$f best_n=$n
  done
  [ -z "$best" ] || [ "$best_n" -eq "$BOUNDARIES" ] ||
    [ ! "$STATE/.handoff-launch-failed" -nt "$best" ] || best=
  printf '%s' "$best"
}

if [ "$EVENT" = Stop ]; then
  # Enforce the restart gate only on a session that is handing off: its newest
  # firing is a fresh start, or this session recorded a handoff document
  # (bin/fm-order.sh handing-off), which also covers percent-left=0. A capture
  # firing is not a handoff. Another session's handoff record or firing in the
  # same home never gates this stop.
  HANDOFF_MARKER=
  [ -z "$MARKER" ] || MARKER=$(newest_firing)
  if [ -n "$MARKER" ]; then
    case "$(sed -n 's/.* mode=\([a-z]*\).*/\1/p' "$MARKER" 2>/dev/null)" in
      capture) ;;
      *) HANDOFF_MARKER=1 ;;
    esac
  fi
  # A deliberate handoff is under way while a live successor record names this
  # session, the lock owner, as its predecessor. The record is the evidence, not
  # the handoff record, which handoff --doc rewrites and a compaction clears.
  # An open fresh start ends this session once a live successor launched after
  # its firing is recorded. Either way this session must hold the session lock;
  # when it does, the ender is detached here, before the slower gate checks.
  LAUNCH="$STATE/.handoff-successor"
  SUCC_PID=$(sed -n 's/^pid=//p' "$LAUNCH" 2>/dev/null | tail -1)
  case "$SUCC_PID" in '' | *[!0-9]*) SUCC_PID= ;; esac
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null)
  case "$LOCK_PID" in '' | *[!0-9]*) LOCK_PID= ;; esac
  END_CANDIDATE=
  if [ -n "$SUCC_PID" ] && [ -n "$LOCK_PID" ] && [ "$SUCC_PID" != "$LOCK_PID" ] &&
    ! fm_root_is_secondmate_home "$FM_ROOT" && kill -0 "$SUCC_PID" 2>/dev/null; then
    if [ -n "$HANDOFF_MARKER" ]; then
      [ ! -f "$LAUNCH" ] || [ "$MARKER" -nt "$LAUNCH" ] || END_CANDIDATE=1
    elif [ "$(sed -n 's/^predecessor=//p' "$LAUNCH" 2>/dev/null | tail -1)" = "$LOCK_PID" ]; then
      END_CANDIDATE=1
    fi
  fi
  DELIBERATE=
  if [ -n "$END_CANDIDATE" ]; then
    # shellcheck source=bin/fm-session-lock-lib.sh
    . "$SCRIPT_DIR/fm-session-lock-lib.sh"
    if fm_session_lock_owned_by_self "$STATE"; then
      [ -n "$HANDOFF_MARKER" ] || DELIBERATE=1
      detach_ender "$LOCK_PID"
    fi
  fi
  HANDING_OFF=$HANDOFF_MARKER
  [ -n "$HANDING_OFF" ] ||
    ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-order.sh" handing-off 2>/dev/null || HANDING_OFF=1
  [ -n "$HANDING_OFF" ] || [ -n "$DELIBERATE" ] || { cancel_ender; exit 0; }
  ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null)
  if [ -n "$HANDING_OFF" ]; then
    GATE_RC=0
    GATE_OUT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-order.sh" gate 2>/dev/null) || GATE_RC=$?
    if [ "$GATE_RC" -eq 3 ]; then
      cancel_ender
      [ "$ACTIVE" != true ] || exit 0
      printf 'Firstmate restart gate: this session is handing off, but its handoff does not list every open captain order. %s\n' \
        "$(printf '%s' "$GATE_OUT" | tr '\n' ' ')" >&2
      exit 2
    fi
  fi
  # Successor gate: only an open fresh-start firing owes a successor; a
  # handoff recorded for stow does not, and a second mate asks its parent for a
  # relaunch instead. A deliberate handoff ends this session once its
  # successor's handoff document lists every open captain order.
  ! fm_root_is_secondmate_home "$FM_ROOT" || { cancel_ender; exit 0; }
  if [ -z "$HANDOFF_MARKER" ]; then
    [ -n "$DELIBERATE" ] || { cancel_ender; exit 0; }
    COVER_RC=0
    COVER_OUT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-order.sh" covers \
      "$(sed -n 's/^handoff=//p' "$LAUNCH" 2>/dev/null | tail -1)" 2>&1) || COVER_RC=$?
    if [ "$COVER_RC" -ne 0 ]; then
      cancel_ender
      [ "$ACTIVE" != true ] || exit 0
      printf 'Firstmate restart gate: this session launched successor pid %s for its handoff, but that handoff does not list every open captain order. %s Then end this turn; the stop that ends it also ends this session after a short quiet settle.\n' \
        "$SUCC_PID" "$(printf '%s' "$COVER_OUT" | tr '\n' ' ')" >&2
      exit 2
    fi
    exit 0
  fi
  if [ ! -f "$LAUNCH" ] || [ "$MARKER" -nt "$LAUNCH" ] || [ -z "$SUCC_PID" ] ||
    ! kill -0 "$SUCC_PID" 2>/dev/null; then
    cancel_ender
    [ "$ACTIVE" != true ] || exit 0
    FAILED="$STATE/.handoff-launch-failed"
    { [ -f "$FAILED" ] && [ "$FAILED" -nt "$MARKER" ]; } && exit 0
    printf 'Firstmate restart gate: this session is handing off for a planned fresh start, but no live successor launched after the trigger is recorded in state/.handoff-successor, so nobody will continue from the handoff. Launch the successor with bin/fm-handoff-launch.sh <handoff document path>: it starts the successor on this home'"'"'s backend, retries once, verifies that the successor stays live, and records it in state/.handoff-successor as pid=<successor pid> and handoff=<handoff document path>. That record clears this gate; then take no new work and end this turn, and the stop that ends it also ends this session after a short quiet settle. The successor confirms the handoff document'"'"'s sha256, waits until this session has ended, then runs bin/fm-session-start.sh once to take the session lock. If the launcher reports that no successor came up, it records state/.handoff-launch-failed, which also clears this gate: tell the captain, keep working, and let auto-compaction run; the next cycle tries again.\n' >&2
    exit 2
  fi
  exit 0
fi

# first_reading_after_compaction: the first assistant context reading after the
# latest compaction boundary, from the lines just after it.
first_reading_after_compaction() {
  local last
  last=$(LC_ALL=C grep -n '"subtype":"compact_boundary"' "$TRANSCRIPT" 2>/dev/null | tail -n 1 | cut -d: -f1)
  case "$last" in '' | *[!0-9]*) return 1 ;; esac
  sed -n "$((last + 1)),$((last + 400))p" "$TRANSCRIPT" 2>/dev/null | jq -R -r '
      fromjson? | select(.type == "assistant") | .message.usage // empty
      | select(type == "object")
      | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)
    ' 2>/dev/null | head -n 1
}

# The cycle's mode: capture (auto-compaction is the reset) or handoff (a planned
# fresh start), with the reason a fresh start gives.
MODE=
REASON=
POST_TOKENS=
if [ -n "$BOUNDARIES" ]; then
  MODE=capture
  if [ "$FRESH_AFTER" -eq 0 ]; then
    MODE=handoff
    REASON="this home hands off every context cycle (fresh-start-after=0)"
  elif [ "$BOUNDARIES" -ge "$FRESH_AFTER" ]; then
    MODE=handoff
    REASON="the drift cap is reached after ${BOUNDARIES} compactions on this harness (fresh-start-after=${FRESH_AFTER})"
  elif [ "$BOUNDARIES" -ge 1 ] && [ "$FRESH_TOKENS" -gt 0 ]; then
    POST_TOKENS=$(first_reading_after_compaction) || POST_TOKENS=
    case "$POST_TOKENS" in '' | *[!0-9]*) POST_TOKENS= ;; esac
    if [ -n "$POST_TOKENS" ] && [ "$POST_TOKENS" -ge "$FRESH_TOKENS" ]; then
      MODE=handoff
      REASON="the latest compaction left ${POST_TOKENS} tokens right after compaction, at or above ${FRESH_TOKENS}, so each cycle is getting shorter"
    fi
  fi
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
[ -n "$COMPACT_AT" ] || exit 0

# shellcheck source=bin/fm-warm-compact-lib.sh
. "$SCRIPT_DIR/fm-warm-compact-lib.sh"
TOKENS=$(fm_warm_compact_context_tokens "$TRANSCRIPT") || exit 0
case "$TOKENS" in '' | *[!0-9]*) exit 0 ;; esac

LEFT=$(fm_compact_left_percent "$TOKENS" "$COMPACT_AT")
[ "$LEFT" -le "$PERCENT" ] || exit 0

# Claim the one firing for this context cycle; a concurrent call that loses exits.
( set -o noclobber; printf '%s\n' "$(date +%s) tokens=$TOKENS compact_at=$COMPACT_AT mode=$MODE" > "$MARKER" ) 2>/dev/null || exit 0
find "$STATE" -maxdepth 1 -name '.handoff-trigger.*' -type f -mtime +30 -exec rm -f {} + 2>/dev/null

if [ "$MODE" = capture ]; then
  MESSAGE="Firstmate context capture, from this home's tracked Claude hook: about ${LEFT}% of context is left before auto-compact (${TOKENS} of ${COMPACT_AT} tokens). Auto-compaction is this session's routine reset, so do not hand off or launch a successor unless the captain asks for a handoff, such as for a quota limit or a harness switch, and do not run /compact by hand. Before it lands, file every piece of open work that lives only in this chat into its durable record: new captain goals in the dispatch log (bin/fm-dispatch-log.sh), your own to-dos as backlog items or task notes (bin/fm-tasks-axi.sh), pending captain calls as holds (bin/fm-captain-hold.sh), and captain orders through bin/fm-order.sh; route durable knowledge as the stow skill describes. After compaction the re-entry card lists open orders, decisions, overdue goals, and workers; drain the wake queue and run bin/fm-crew-state.sh before acting on any PR, worker, or decision fact the summary carries, because the summary can be stale. Compactions so far: ${BOUNDARIES}; a planned fresh start comes after ${FRESH_AFTER}. This instruction fires once per context cycle."
  jq -n --arg event "$EVENT" --arg context "$MESSAGE" \
    '{hookSpecificOutput: {hookEventName: $event, additionalContext: $context}}'
  exit 0
fi
MESSAGE="Firstmate planned fresh start, from this home's tracked Claude hook: about ${LEFT}% of context is left before auto-compact (${TOKENS} of ${COMPACT_AT} tokens), and ${REASON}, so this cycle ends in a handoff to a fresh session instead of another compaction. Write it incrementally, because the limit can land at any point: first file every piece of open work that lives only in this chat into its durable record (the dispatch log through bin/fm-dispatch-log.sh, backlog items or notes through bin/fm-tasks-axi.sh, holds through bin/fm-captain-hold.sh, orders through bin/fm-order.sh); next write a short handoff document and record it at once with bin/fm-order.sh handoff --doc <handoff file>; then extend it and record it again. Keep it slim: point to held items and backlog items instead of restating them or earlier handoffs, leave out an orders block and the startup steps that session start already prints, and move standing rules into data/learnings.md. A fact that arrives after you record the document goes into its durable record, never an addendum file, because the successor reads only the hashed document."
if fm_root_is_secondmate_home "$FM_ROOT"; then
  MESSAGE="$MESSAGE This is a second mate, so never launch your own successor: append to your parent channel that your handoff is written, name the handoff document, and ask the parent to relaunch you, once, then end this turn."
else
  MESSAGE="$MESSAGE Then launch your successor with bin/fm-handoff-launch.sh <handoff file>: it starts the successor on this home's backend, retries once, verifies that the successor stays live, and records it in state/.handoff-successor. Once that record names a live successor, take no new work and end this turn: the stop that ends it also ends this session after a short quiet settle, and the successor waits for that end before it runs bin/fm-session-start.sh to take the session lock. If the launcher reports that no successor came up, tell the captain, keep working, and let auto-compaction run; the next cycle tries again. This turn cannot end until the record names a live successor or a launch failure is recorded."
fi
MESSAGE="$MESSAGE Do not run /compact instead. This instruction fires once per context cycle."
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
