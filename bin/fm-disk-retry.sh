#!/usr/bin/env bash
# fm-disk-retry.sh - remember a launch the disk alarm refused, and dispatch it again by itself when the alarm clears.
#
# Usage:
#   fm-disk-retry.sh record <task-id> <spawn-arg>...
#       Record that the disk alarm refused a fresh launch of <task-id>, with the
#       exact bin/fm-spawn.sh arguments of that launch.
#       bin/fm-spawn.sh runs this when bin/fm-disk-alarm.sh --gate crew refuses.
#       Recording the same task again replaces its record.
#   fm-disk-retry.sh clear <task-id>
#       Remove the record of <task-id>. An absent record is not an error.
#       bin/fm-spawn.sh runs this when the crew gate admits the launch.
#   fm-disk-retry.sh scan
#       With no record: print nothing, do not read the disk, exit 0.
#       While another scan of this home runs: print nothing, exit 0.
#       With a record: read bin/fm-disk-alarm.sh --gate crew. While the gate
#       still refuses, print nothing and keep every record. When the gate
#       admits, take each record, oldest first, and:
#         - drop it, launching nothing, when the task already has a task record
#           in this home (its worker is live or not yet cleaned up), when the
#           dispatch ledger shows a dispatch of the task at or after the
#           refusal, or when this home's backlog item is missing or no longer
#           Queued (placed elsewhere, cancelled, or done);
#         - keep it, launching nothing, when the backlog item cannot be read;
#         - otherwise run bin/fm-spawn.sh again with the recorded arguments,
#           so every spawn gate (disk alarm, capacity, backlog, spend) applies
#           again. A spawn the disk alarm refuses again records itself again;
#           a spawn a capacity gate defers (exit 75) keeps its record for a
#           later scan; any other failure drops the record and keeps the
#           spawn's output in <state>/disk-refused/.log.<task-id>.
#       When a task was dispatched, dropped, or failed, append one `check` wake
#       to this home's wake queue (bin/fm-wake-lib.sh), key `disk-retry`, write
#       the same line to <state>/disk-refused/.report.<epoch>.<pid>, and print
#       it on stdout:
#         check: disk alarm cleared (level=<level> free_kib=<n|unknown>): <part>[; <part>...]
#       where each part is one of
#         re-dispatched by bin/fm-spawn.sh: <task-id>...
#         dropped, already launched or placed elsewhere: <task-id>...
#         re-dispatch failed, see state/disk-refused/.log.<task-id>: <task-id>...
#       The wake reports the result; record each re-dispatch in the dispatch
#       ledger (bin/fm-dispatch-log.sh dispatched).
#   fm-disk-retry.sh --help
#
# A record is the file <state>/disk-refused/<task-id>. Its first line is the
# refusal epoch; the bytes after it are the spawn arguments, each ended by a NUL
# byte. The record is not a backlog item, a dispatch-ledger line, or a task
# record.
# The watcher (bin/fm-watch.sh) starts scan in the background on each poll while
# a record exists, because a spawn can outlast a poll, and wakes with each
# report file it finds, removing it.
#
# bin/fm-disk-alarm.sh owns the reading, the levels, and the gates.
#
# Exit 0 on success. Exit 1 when a record, the wake, or a removal could not be
# written. Exit 2 is a usage error: an unknown subcommand, a missing or extra
# argument, or a task id that is empty, starts with `.`, or has a character
# outside [A-Za-z0-9._-].
#
# Environment: FM_HOME selects the home; FM_STATE_OVERRIDE, FM_DATA_OVERRIDE,
# and FM_CONFIG_OVERRIDE override its state, data, and config directories.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DIR="$STATE/disk-refused"
LOCK="$DIR/.scan.lock"

usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

usage_error() {
  echo "usage: fm-disk-retry.sh record <task-id> <spawn-arg>... | clear <task-id> | scan | --help" >&2
  exit 2
}

valid_id() {
  case "$1" in '' | .* | *[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# Print "<task-id>\t<refused-epoch>" for each record, oldest first.
records() {
  local f id epoch
  for f in "$DIR"/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    id=${f##*/}
    valid_id "$id" || continue
    epoch=
    IFS= read -r epoch < "$f" || true
    case "$epoch" in '' | *[!0-9]*) epoch=0 ;; esac
    printf '%s\t%s\n' "$id" "$epoch"
  done | sort -t "$(printf '\t')" -k2,2n -k1,1
}

write_record() {  # <task-id> <epoch> <spawn-arg>...
  local id=$1 epoch=$2 tmp
  shift 2
  mkdir -p "$DIR" || return 1
  tmp=$(mktemp "$DIR/.record.XXXXXX") || return 1
  if ! { printf '%s\n' "$epoch" && printf '%s\0' "$@"; } > "$tmp" || ! mv -f "$tmp" "$DIR/$id"; then
    rm -f -- "$tmp"
    return 1
  fi
}

scan_lock() {
  local pid
  mkdir -p "$DIR" || return 1
  if ! mkdir "$LOCK" 2>/dev/null; then
    pid=$(cat "$LOCK/pid" 2>/dev/null) || pid=
    case "$pid" in '' | *[!0-9]*) return 1 ;; esac
    ! kill -0 "$pid" 2>/dev/null || return 1
    rm -rf -- "$LOCK"
    mkdir "$LOCK" 2>/dev/null || return 1
  fi
  printf '%s\n' "$$" > "$LOCK/pid"
  trap 'rm -rf -- "$LOCK"' EXIT
}

# True when the dispatch ledger names a dispatch of <task-id> at or after <epoch>.
dispatched_since() {  # <task-id> <epoch>
  [ -f "$STATE/dispatch-log.tsv" ] || return 1
  awk -F '\t' -v task="$1" -v since="$2" '
    $3 == "dispatched" && $2 + 0 >= since + 0 && ($5 == "task=" task || index($5, "task=" task " ") == 1) { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$STATE/dispatch-log.tsv"
}

# Exit 0 when the backlog allows a re-dispatch, 1 when the record is stale, and
# 2 when the backlog cannot be read now.
backlog_queued() {  # <task-id>
  (
    # shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
    . "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
    # shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
    . "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
    rc=0
    fm_backlog_transition_applies "$CONFIG" "$DATA" ship || rc=$?
    [ "$rc" -ne 1 ] || exit 0
    [ "$rc" -eq 0 ] || exit 2
    if fm_backlog_row_probe "$DATA" "$1"; then
      case "$FM_BACKLOG_ROW_STATE" in queued\ *) exit 0 ;; *) exit 1 ;; esac
    fi
    [ "$FM_BACKLOG_ROW_RESULT" = not_found ] && exit 1
    exit 2
  ) >/dev/null 2>&1
}

scan() {
  local rows id epoch line level free reason a rc stale
  local dispatched='' dropped='' failed='' parts=''
  local -a args
  rows=$(records)
  [ -n "$rows" ] || return 0
  scan_lock || return 0
  line=$("$SCRIPT_DIR/fm-disk-alarm.sh" --gate crew 2>/dev/null) || return 0
  level=unknown
  free=unknown
  case "$line" in
    'disk-alarm: level='*' free_kib='*' volume='*)
      level=${line#disk-alarm: level=}
      level=${level%% *}
      free=${line#* free_kib=}
      free=${free%% *}
      ;;
  esac
  while IFS="$(printf '\t')" read -r id epoch; do
    [ -n "$id" ] && [ -f "$DIR/$id" ] || continue
    args=()
    while IFS= read -r -d '' a; do
      args+=("$a")
    done < <(tail -n +2 "$DIR/$id")
    stale=0
    if [ -e "$STATE/$id.meta" ] || [ -L "$STATE/$id.meta" ] || dispatched_since "$id" "$epoch"; then
      stale=1
    else
      rc=0
      backlog_queued "$id" </dev/null || rc=$?
      [ "$rc" -ne 2 ] || continue
      [ "$rc" -eq 0 ] || stale=1
    fi
    if [ "$stale" -eq 1 ] || [ "${#args[@]}" -eq 0 ]; then
      rm -f -- "$DIR/$id" || return 1
      dropped="$dropped $id"
      continue
    fi
    rm -f -- "$DIR/$id" || return 1
    rc=0
    env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_SPAWN_NO_GUARD=1 \
      "$SCRIPT_DIR/fm-spawn.sh" "${args[@]}" </dev/null > "$DIR/.log.$id" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
      rm -f -- "$DIR/.log.$id"
      dispatched="$dispatched $id"
    elif [ -f "$DIR/$id" ]; then
      rm -f -- "$DIR/.log.$id"
    elif [ "$rc" -eq 75 ]; then
      rm -f -- "$DIR/.log.$id"
      write_record "$id" "$epoch" "${args[@]}" || return 1
    else
      failed="$failed $id"
    fi
  done <<EOF
$rows
EOF
  [ -z "$dispatched" ] || parts="re-dispatched by bin/fm-spawn.sh:$dispatched"
  [ -z "$dropped" ] || parts="${parts:+$parts; }dropped, already launched or placed elsewhere:$dropped"
  [ -z "$failed" ] || parts="${parts:+$parts; }re-dispatch failed, see state/disk-refused/.log.<task-id>:$failed"
  [ -n "$parts" ] || return 0
  reason="check: disk alarm cleared (level=$level free_kib=$free): $parts"
  (
    FM_ROOT_OVERRIDE=$FM_ROOT
    FM_STATE_OVERRIDE=$STATE
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    fm_wake_append check disk-retry "$reason"
  ) >/dev/null 2>&1 || {
    echo "fm-disk-retry: could not queue the notification: $reason" >&2
    return 1
  }
  printf '%s\n' "$reason" > "$DIR/.report.$(date +%s).$$" || return 1
  printf '%s\n' "$reason"
}

case "${1:-}" in
  --help | -h)
    [ $# -eq 1 ] || usage_error
    usage
    ;;
  record)
    [ $# -ge 3 ] && valid_id "$2" || usage_error
    id=$2
    shift 2
    write_record "$id" "$(date +%s)" "$@" || {
      echo "fm-disk-retry: could not record $id" >&2
      exit 1
    }
    ;;
  clear)
    [ $# -eq 2 ] && valid_id "$2" || usage_error
    rm -f -- "$DIR/$2" || exit 1
    ;;
  scan)
    [ $# -eq 1 ] || usage_error
    scan || exit 1
    ;;
  *) usage_error ;;
esac
