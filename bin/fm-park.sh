#!/usr/bin/env bash
# fm-park.sh - record a supervisor-side declared wait for a task whose worker
# cannot declare its own.
#
# Usage: fm-park.sh <task-id> --until <YYYY-MM-DDTHH:MM[:SS]Z> --reason <text>
#
# A worker normally declares a known wait by appending `paused: ... until <t>`
# to its own status log (bin/fm-brief.sh owns that instruction). An inert agent
# cannot: one whose quota is exhausted, or whose pane is gone, while its
# delivered work waits on something external. Without a declaration its quiet
# pane escalates as stale on every supervision cycle. This command lets
# firstmate write that same declaration for it, so supervision absorbs the
# pane exactly as it absorbs a worker-declared pause.
#
# It appends one line to this home's state/<task-id>.status:
#   paused [key=fm-park] [at=<epoch>]: <reason> (parked by firstmate) until <t>
# The verb, the `until` grammar, and the keyed phase semantics are owned by
# bin/fm-classify-lib.sh (status_is_paused, status_paused_until,
# status_declared_wait_line), and bin/fm-watch.sh owns what a declared wait
# does to stale detection: the pane stays absorbed until <t>, then is rechecked
# once and held to the long recheck cadence. The wait ends as soon as any later
# event lands, such as the worker's own next status line; parking again appends
# a newer declaration that supersedes this one.
#
# The append is self-announced (fm_wake_status_append_self_announced in
# bin/fm-wake-lib.sh), so recording the park does not wake this same session.
#
# Refuses, and writes nothing, when: the task id is not a recorded task in this
# home (no state/<task-id>.meta); --until is missing, malformed, not UTC, or not
# in the future; --reason is empty; or the finished line would exceed the
# status-line cap (bin/fm-line-cap-lib.sh), since truncation would cut off the
# `until` time. After appending it re-reads the log and fails if the line is not
# the task's current declared wait with the requested time.
#
# Environment: FM_HOME selects the home; FM_STATE_OVERRIDE overrides its state
# directory.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

PARK_KEY=fm-park

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-park: %s\n' "$*" >&2
  exit 1
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  ''|-*) usage >&2; exit 2 ;;
esac
task=$1
shift
until_ts=''
reason=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --until) [ "$#" -ge 2 ] || fail "--until requires a value"; until_ts=$2; shift 2 ;;
    --until=*) until_ts=${1#--until=}; shift ;;
    --reason) [ "$#" -ge 2 ] || fail "--reason requires a value"; reason=$2; shift 2 ;;
    --reason=*) reason=${1#--reason=}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

case "$task" in
  .*|*[!A-Za-z0-9._-]*) fail "task id must be a plain task id: $task" ;;
esac
[ -f "$STATE/$task.meta" ] || fail "no recorded task '$task' in this home (missing $STATE/$task.meta)"

[ -n "$until_ts" ] || fail "--until <YYYY-MM-DDTHH:MM[:SS]Z> is required, so the park ends and supervision rechecks the task"
until_epoch=$(fm_utc_iso_to_epoch "$until_ts") \
  || fail "--until must be a UTC time shaped YYYY-MM-DDTHH:MM[:SS]Z: $until_ts"
[ "$until_epoch" -gt "$(date +%s)" ] || fail "--until must be in the future: $until_ts"

reason=$(printf '%s' "$reason" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177')
reason=$(printf '%s' "$reason" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
[ -n "$reason" ] || fail "--reason is required: say what the task is waiting for"

until_canonical=$(date -u -r "$until_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
  || date -u -d "@$until_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) \
  || fail "could not format --until: $until_ts"
line="paused [key=$PARK_KEY]: $reason (parked by firstmate) until $until_canonical"
max=$((FM_LINE_CAP_DEFAULT - $(status_stamp_width)))
[ "${#line}" -le "$max" ] \
  || fail "the park line is ${#line} characters, over the $max-character limit; shorten --reason"
if ! line_until=$(status_paused_until "$line") || [ "$line_until" != "$until_epoch" ]; then
  fail "the park line does not declare the requested --until; nothing was recorded"
fi

statusf="$STATE/$task.status"
rc=0
fm_wake_status_append_self_announced "$STATE" "$statusf" "$line" || rc=$?
[ "$rc" -ne 2 ] || fail "could not append the park to $statusf; nothing was recorded"

current=$(status_declared_wait_line "$statusf")
if ! current_until=$(status_paused_until "$current") || [ "$current_until" != "$until_epoch" ]; then
  fail "appended the park to $statusf, but it is not the task's current declared wait (a later line may have superseded it); current: ${current:-none}"
fi
printf 'parked %s until %s: %s\n' "$task" "$until_ts" "$reason"
