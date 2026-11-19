#!/usr/bin/env bash
# fm-disk-retry.sh - remember a launch the disk alarm refused, and say once when it can be dispatched again.
#
# Usage:
#   fm-disk-retry.sh record <task-id>
#       Record that the disk alarm refused a fresh launch of <task-id>.
#       bin/fm-spawn.sh runs this when bin/fm-disk-alarm.sh --gate crew refuses.
#       Recording the same task again replaces its record.
#   fm-disk-retry.sh clear <task-id>
#       Remove the record of <task-id>. An absent record is not an error.
#       bin/fm-spawn.sh runs this when the crew gate admits the launch.
#   fm-disk-retry.sh list
#       Print each recorded line, oldest first:
#         <task-id>\t<refused-epoch>
#   fm-disk-retry.sh scan
#       With no record: print nothing, do not read the disk, exit 0.
#       With a record: read bin/fm-disk-alarm.sh --gate crew. While the gate
#       still refuses, print nothing and keep every record. When the gate
#       admits, append one `check` wake to this home's wake queue
#       (bin/fm-wake-lib.sh), key `disk-retry`, then remove the records it
#       named, then print the same line on stdout:
#         check: disk alarm cleared (level=<level> free_kib=<n|unknown>): dispatch again with bin/fm-spawn.sh: <task-id>[ <task-id>...]
#       The wake is the one notification. scan launches nothing. A second scan
#       finds no record and stays silent. A task the alarm refuses again gets a
#       new record and a later notification.
#   fm-disk-retry.sh --help
#
# A record is the file <state>/disk-refused/<task-id>. It holds the refusal
# epoch on one line. The record is a marker for this notification only: it is
# not a backlog item, a dispatch-ledger line, or a task record.
# The watcher (bin/fm-watch.sh) runs scan on each poll while a record exists and
# reports the printed line as its wake. Nothing here spawns a worker; the
# supervisor that reads the wake dispatches each named task again.
#
# bin/fm-disk-alarm.sh owns the reading, the levels, and the gates.
#
# Exit 0 on success. Exit 1 when a record, the wake, or a removal could not be
# written; scan keeps the records when the wake could not be written. Exit 2 is
# a usage error: an unknown subcommand, a missing or extra argument, or a task
# id that is empty, starts with `.`, or has a character outside [A-Za-z0-9._-].
#
# Environment: FM_HOME selects the home; FM_STATE_OVERRIDE overrides its state
# directory.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DIR="$STATE/disk-refused"

usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

usage_error() {
  echo "usage: fm-disk-retry.sh record <task-id> | clear <task-id> | list | scan | --help" >&2
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

record() {
  local id=$1 tmp
  mkdir -p "$DIR" || return 1
  tmp=$(mktemp "$DIR/.record.XXXXXX") || return 1
  if ! date +%s > "$tmp" || ! mv -f "$tmp" "$DIR/$id"; then
    rm -f -- "$tmp"
    return 1
  fi
}

scan() {
  local rows ids='' id line level free reason
  rows=$(records)
  [ -n "$rows" ] || return 0
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
  while IFS="$(printf '\t')" read -r id _; do
    [ -n "$id" ] || continue
    ids="$ids $id"
  done <<EOF
$rows
EOF
  reason="check: disk alarm cleared (level=$level free_kib=$free): dispatch again with bin/fm-spawn.sh:$ids"
  (
    FM_ROOT_OVERRIDE=$FM_ROOT
    FM_STATE_OVERRIDE=$STATE
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    mkdir -p "$STATE"
    fm_wake_append check disk-retry "$reason"
  ) >/dev/null 2>&1 || {
    echo "fm-disk-retry: could not queue the notification; records kept" >&2
    return 1
  }
  for id in $ids; do
    rm -f -- "$DIR/$id" || return 1
  done
  printf '%s\n' "$reason"
}

case "${1:-}" in
  --help | -h)
    [ $# -eq 1 ] || usage_error
    usage
    ;;
  record)
    [ $# -eq 2 ] && valid_id "$2" || usage_error
    record "$2" || {
      echo "fm-disk-retry: could not record $2" >&2
      exit 1
    }
    ;;
  clear)
    [ $# -eq 2 ] && valid_id "$2" || usage_error
    rm -f -- "$DIR/$2" || exit 1
    ;;
  list)
    [ $# -eq 1 ] || usage_error
    records
    ;;
  scan)
    [ $# -eq 1 ] || usage_error
    scan || exit 1
    ;;
  *) usage_error ;;
esac
