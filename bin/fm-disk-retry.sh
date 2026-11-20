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
#         - keep it, launching nothing, when the backlog item is Queued but
#           held or blocked, and report it once until its record changes;
#         - otherwise run bin/fm-dispatch-resolve.sh on <data>/<task-id>/brief.md,
#           with --project set to the base name of the recorded project path.
#           When the resolution is not clear, or the brief is missing, drop the
#           record, launching nothing, and report the task for dispatch by hand.
#           On clear, scan itself runs bin/fm-spawn.sh with the recorded
#           arguments, minus --harness, --model, --effort, --dispatch-override,
#           and the harness-scoped selectors --account and --hermes-profile
#           (each with a separate or `=` value), and minus any positional after
#           the task id and project, plus the fresh profile. The recorded
#           harness-scoped selectors are passed again only when the fresh
#           harness is the recorded one. When the harness changed under any
#           recorded harness-scoped selector, or the fresh harness is claude,
#           config/claude-accounts exists, and no --account was recorded, the
#           record is handed over for dispatch by hand like an unclear
#           resolution. Every spawn gate (disk alarm, capacity, backlog,
#           spend) applies again. A spawn the disk alarm refuses again records
#           itself again; a spawn a capacity gate defers (exit 75) keeps its
#           record for a later scan; any other failure drops the record and
#           keeps the spawn's output in <state>/disk-refused/.log.<task-id>.
#       When there is a result to report, append one `check` wake to this
#       home's wake queue (bin/fm-wake-lib.sh), key `disk-retry`, write the same
#       line to <state>/disk-refused/.report.<epoch>.<pid> through a temporary
#       file and a rename, and print it on stdout:
#         check: disk alarm cleared (level=<level> free_kib=<n|unknown>): <part>[; <part>...]
#       where each part is one of
#         re-dispatched by bin/fm-spawn.sh: <task-id>...
#         dropped, already launched or placed elsewhere: <task-id>...
#         re-dispatch failed, see state/disk-refused/.log.<task-id>: <task-id>...
#         not re-dispatched, routing needs a decision, dispatch by hand: <task-id> (<reason>)...
#         skipped, backlog item held or blocked, record kept: <task-id>...
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
  mkdir -p "$DIR" || return 1
  FM_ROOT_OVERRIDE=$FM_ROOT
  FM_STATE_OVERRIDE=$STATE
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_lock_try_acquire "$LOCK" || return 1
  trap 'fm_lock_release "$LOCK"' EXIT
}

# True when the dispatch ledger names a dispatch of <task-id> at or after <epoch>.
dispatched_since() {  # <task-id> <epoch>
  [ -f "$STATE/dispatch-log.tsv" ] || return 1
  awk -F '\t' -v task="$1" -v since="$2" '
    $3 == "dispatched" && $2 + 0 >= since + 0 && ($5 == "task=" task || index($5, "task=" task " ") == 1) { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$STATE/dispatch-log.tsv"
}

# Exit 0 when the backlog allows a re-dispatch, 1 when the record is stale, 2
# when the backlog cannot be read now, and 3 when the item is held or blocked.
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
      case "$FM_BACKLOG_ROW_STATE" in queued\ *) ;; *) exit 1 ;; esac
      fm_backlog_row_dispatchable "$FM_BACKLOG_ROW_STATE" && exit 0
      exit 3
    fi
    [ "$FM_BACKLOG_ROW_RESULT" = not_found ] && exit 1
    exit 2
  ) >/dev/null 2>&1
}

# Resolve the task's routing again from its brief. On clear, set ROUTED to the
# recorded arguments without their routing flags, followed by the fresh
# profile and the recorded harness-scoped selectors, and return 0. Otherwise
# set RESOLVED to the resolution status and return 1.
resolve_routing() {  # <task-id> <spawn-arg>...
  local id=$1 rec="$DATA/$1/dispatch-resolution.json" harness model effort pos=0 was='' account_set=0 project_dir='' project=''
  local -a scoped=() resolve_args=()
  shift
  ROUTED=()
  RESOLVED=error
  [ -f "$DATA/$id/brief.md" ] || { RESOLVED='no brief'; return 1; }
  while [ $# -gt 0 ]; do
    case "$1" in
      --harness) [ $# -lt 2 ] || was=$2; shift ;;
      --harness=*) was=${1#--harness=} ;;
      --account | --hermes-profile)
        [ "$1" != --account ] || account_set=1
        scoped+=("$1")
        [ $# -lt 2 ] || { shift; scoped+=("$1"); }
        ;;
      --account=* | --hermes-profile=*)
        case "$1" in --account=*) account_set=1 ;; esac
        scoped+=("${1%%=*}" "${1#*=}")
        ;;
      --model | --effort | --dispatch-override) shift ;;
      --model=* | --effort=* | --dispatch-override=*) ;;
      --mode | --yolo | --branch-prefix | --base-branch | --backend | --pr-branch | --from-branch | \
        --upstream-consent | --traceparent | --budget-inclusive-hard | --budget-inclusive-stop | \
        --budget-fresh-hard | --budget-fresh-stop)
        ROUTED+=("$1")
        [ $# -lt 2 ] || { shift; ROUTED+=("$1"); }
        ;;
      -*) ROUTED+=("$1") ;;
      *)
        pos=$((pos + 1))
        if [ "$pos" -le 2 ]; then
          ROUTED+=("$1")
          [ "$pos" -ne 2 ] || project_dir=$1
        elif [ "$pos" -eq 3 ]; then
          was=$1
        fi
        ;;
    esac
    [ $# -eq 0 ] || shift
  done
  project=$project_dir
  while [ -n "$project" ] && [ "${project%/}" != "$project" ]; do
    project=${project%/}
  done
  project=${project##*/}
  resolve_args=("$DATA/$id/brief.md")
  [ -z "$project" ] || resolve_args+=(--project "$project")
  env FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$SCRIPT_DIR/fm-dispatch-resolve.sh" "${resolve_args[@]}" </dev/null >/dev/null 2>&1 || return 1
  RESOLVED=$(jq -r '.status // "error"' "$rec" 2>/dev/null) || RESOLVED=
  [ -n "$RESOLVED" ] || RESOLVED=off
  [ "$RESOLVED" = clear ] || return 1
  harness=$(jq -r '.profile.harness // empty' "$rec" 2>/dev/null) || harness=
  model=$(jq -r '.profile.model // empty' "$rec" 2>/dev/null) || model=
  effort=$(jq -r '.profile.effort // empty' "$rec" 2>/dev/null) || effort=
  [ -n "$harness" ] || { RESOLVED=error; return 1; }
  if [ "${#scoped[@]}" -gt 0 ] && [ "$was" != "$harness" ]; then
    RESOLVED="clear on $harness, but ${scoped[0]} was recorded for ${was:-the default harness}"
    return 1
  fi
  if [ "$account_set" -eq 0 ] && [ "$harness" = claude ] && { [ -e "$CONFIG/claude-accounts" ] || [ -L "$CONFIG/claude-accounts" ]; }; then
    RESOLVED="clear on claude, but no --account was recorded and config/claude-accounts needs one"
    return 1
  fi
  ROUTED+=(--harness "$harness")
  [ -z "$model" ] || ROUTED+=(--model "$model")
  [ -z "$effort" ] || ROUTED+=(--effort "$effort")
  [ "${#scoped[@]}" -eq 0 ] || ROUTED+=("${scoped[@]}")
}

scan() {
  local rows id epoch line level free reason a rc stale tmp
  local dispatched='' dropped='' failed='' skipped='' manual='' parts=''
  local -a args ROUTED
  local RESOLVED
  rows=$(records)
  [ -n "$rows" ] || return 0
  scan_lock || return 0
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
      if [ "$rc" -eq 3 ]; then
        if [ ! -e "$DIR/.skipped.$id" ]; then
          : > "$DIR/.skipped.$id" || return 1
          skipped="$skipped $id"
        fi
        continue
      fi
      [ "$rc" -eq 0 ] || stale=1
    fi
    rm -f -- "$DIR/.skipped.$id"
    if [ "$stale" -eq 1 ] || [ "${#args[@]}" -eq 0 ]; then
      rm -f -- "$DIR/$id" || return 1
      dropped="$dropped $id"
      continue
    fi
    if ! resolve_routing "$id" "${args[@]}"; then
      rm -f -- "$DIR/$id" || return 1
      manual="$manual $id ($RESOLVED)"
      continue
    fi
    rm -f -- "$DIR/$id" || return 1
    rc=0
    env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_SPAWN_NO_GUARD=1 \
      "$SCRIPT_DIR/fm-spawn.sh" "${ROUTED[@]}" </dev/null > "$DIR/.log.$id" 2>&1 || rc=$?
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
  [ -z "$manual" ] || parts="${parts:+$parts; }not re-dispatched, routing needs a decision, dispatch by hand:$manual"
  [ -z "$skipped" ] || parts="${parts:+$parts; }skipped, backlog item held or blocked, record kept:$skipped"
  [ -n "$parts" ] || return 0
  reason="check: disk alarm cleared (level=$level free_kib=$free): $parts"
  fm_wake_append check disk-retry "$reason" >/dev/null 2>&1 || {
    echo "fm-disk-retry: could not queue the notification: $reason" >&2
    return 1
  }
  tmp=$(mktemp "$DIR/.tmp-report.XXXXXX") || return 1
  if ! printf '%s\n' "$reason" > "$tmp" || ! mv -f "$tmp" "$DIR/.report.$(date +%s).$$"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$reason"
}

case "${1:-}" in
  --help | -h)
    [ $# -eq 1 ] || usage_error
    usage
    ;;
  record)
    { [ $# -ge 3 ] && valid_id "$2"; } || usage_error
    id=$2
    shift 2
    write_record "$id" "$(date +%s)" "$@" || {
      echo "fm-disk-retry: could not record $id" >&2
      exit 1
    }
    rm -f -- "$DIR/.skipped.$id"
    ;;
  clear)
    { [ $# -eq 2 ] && valid_id "$2"; } || usage_error
    rm -f -- "$DIR/$2" "$DIR/.skipped.$2" || exit 1
    ;;
  scan)
    [ $# -eq 1 ] || usage_error
    scan || exit 1
    ;;
  *) usage_error ;;
esac
