#!/usr/bin/env bash
# fm-load-relief.sh - automatic host-load relief for live workers.
#
# Usage:
#   fm-load-relief.sh check [--dry-run]
#   fm-load-relief.sh --help
#
# One check pass reads the host 1-minute load once. When the load stays at or
# over the ceiling for the sustained window, the pass pauses exactly one
# lowest-priority live ship or scout: it delivers that worker's verified
# interrupt through bin/fm-control.sh (the agent stays alive, its worktree
# and unlanded work untouched), writes a durable record under
# state/load-relief/paused/<id>, and appends one paused: line to the task's
# status file. The record is written before the interrupt and removed again
# when the interrupt is not delivered, so an interrupted worker always has
# one. When a later pass reads load below the resume level, it lifts one
# load-relief pause per pass, highest priority (smallest priority number)
# first and, among records without a priority, the most recently paused
# first: the record is removed and bin/fm-send.sh steers the worker to
# resume. Nothing is killed, exited, or discarded. A successful
# pause restarts the sustained window, so each further pause needs a fresh
# full window over the ceiling. Both status lines carry [key=load-relief], so
# lifting a pause never closes another open decision on that worker. A pause
# record whose task has no meta, or whose latest status is done: or failed:,
# is dropped without a steer.
#
# The watcher runs one detached check beside its lane-capacity publish while
# config/lane-capacity exists; with that file absent a check is a no-op, so
# load relief is opt-in on the same declaration that caps dispatch.
#
# Ceiling and window, in order: the optional config/load-relief keys
# ceiling and resume-below win, then max-load1 from config/lane-capacity,
# then the logical core count. config/load-relief holds one key=value per
# line (# comments and blank lines ignored):
#   ceiling=<positive number>       load at or over this starts the window
#   resume-below=<positive number>  load under this lifts pauses (default 75%
#                                   of the ceiling)
#   sustain-secs=<uint>             seconds at or over ceiling before a pause
#                                   (default 300)
#   pause-per-check=<uint>          workers paused per sustained pass (default 1)
# A malformed config/load-relief, or an unreadable config/lane-capacity,
# refuses with exit 1 rather than guessing the captain's limits.
#
# Priority: the priority: field that bin/fm-tasks-axi.sh show <id> reports
# for the task's backlog item (the value add --priority N sets; a larger N is
# lower priority, so it pauses first). A task with no backlog item or no
# priority value is never paused. Ties break by newest dispatch first (the
# epoch in the meta spawn_gen, else the meta file's mtime), which has the
# least progress to lose. Already load-paused workers, secondmates, and tasks
# whose latest status event is done, failed, needs-decision, blocked, paused,
# or captain-held are never candidates.
#
# State under state/load-relief/: high-since (epoch the current over-ceiling
# stretch began) and paused/<id> (key=value: id, paused_epoch, priority, load,
# ceiling). A check that finds load under the ceiling clears high-since.
#
# Test seams, honoured only with FM_TEST_SEAM=1: FM_LOAD_RELIEF_LOAD_FILE
# names a file whose first word stands in for load1, FM_LOAD_RELIEF_NOW
# fixes the clock, FM_LOAD_RELIEF_CORES fixes the core count,
# FM_LOAD_RELIEF_CONTROL, FM_LOAD_RELIEF_SEND, and FM_LOAD_RELIEF_TASKS name
# the executables called as <control> <id> interrupt, <send> <id> <text>, and
# <tasks> show <id>.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, and
# FM_DATA_OVERRIDE resolve the home exactly as the other bin/ scripts do.
#
# Exit status: 0 on a completed pass (including a no-op), 1 on a refusal,
# 2 on a usage error.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
LANE_CONFIG="$CONFIG/lane-capacity"
RELIEF_CONFIG="$CONFIG/load-relief"
RELIEF_DIR="$STATE/load-relief"
PAUSED_DIR="$RELIEF_DIR/paused"

dry_run=0
case "${1:-}" in
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  check)
    [ "${2:-}" = --dry-run ] && dry_run=1
    [ $# -le 2 ] || { echo "usage: fm-load-relief.sh check [--dry-run]" >&2; exit 2; }
    ;;
  *) echo "usage: fm-load-relief.sh check [--dry-run] | --help" >&2; exit 2 ;;
esac

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
is_positive_number() {
  case "$1" in ''|.|*[!0-9.]*|*.*.*) return 1 ;; esac
  awk -v v="$1" 'BEGIN { exit !(v + 0 > 0) }'
}
num_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a >= b)}'; }
num_lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a < b)}'; }
die() { echo "fm-load-relief: $1" >&2; exit 1; }

[ -e "$LANE_CONFIG" ] || exit 0

now=$(date +%s)
if [ "${FM_TEST_SEAM:-}" = 1 ] && is_uint "${FM_LOAD_RELIEF_NOW:-}"; then
  now=$FM_LOAD_RELIEF_NOW
fi

# --- configuration ----------------------------------------------------------
ceiling=
resume_below=
sustain_secs=300
pause_per_check=1
if [ -e "$LANE_CONFIG" ]; then
  [ -r "$LANE_CONFIG" ] || die "config/lane-capacity is unreadable; refusing to guess the load ceiling"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=$(printf '%s' "$line" | tr '\t\r' '  ' | sed 's/^ *//; s/ *$//')
    [ "${line%% *}" = max-load1 ] || continue
    value=$(printf '%s' "${line#* }" | sed 's/^ *//')
    [ -z "$ceiling" ] && ceiling=$value
  done < "$LANE_CONFIG"
fi
if [ -e "$RELIEF_CONFIG" ]; then
  [ -r "$RELIEF_CONFIG" ] || die "config/load-relief is unreadable; refusing to guess its values"
  lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%%#*}
    line=$(printf '%s' "$line" | sed 's/^ *//; s/ *$//')
    [ -n "$line" ] || continue
    key=${line%%=*} value=${line#*=}
    [ "$key" != "$line" ] || die "config/load-relief line $lineno: expected key=value"
    case "$key" in
      ceiling) is_positive_number "$value" || die "config/load-relief line $lineno: ceiling needs a positive number"; ceiling=$value ;;
      resume-below) is_positive_number "$value" || die "config/load-relief line $lineno: resume-below needs a positive number"; resume_below=$value ;;
      sustain-secs) is_uint "$value" || die "config/load-relief line $lineno: sustain-secs needs a non-negative integer"; sustain_secs=$((10#$value)) ;;
      pause-per-check) is_uint "$value" && [ "$value" -ge 1 ] || die "config/load-relief line $lineno: pause-per-check needs a positive integer"; pause_per_check=$((10#$value)) ;;
      *) die "config/load-relief line $lineno: unknown key '$key'" ;;
    esac
  done < "$RELIEF_CONFIG"
fi

cores=
if [ "${FM_TEST_SEAM:-}" = 1 ] && is_uint "${FM_LOAD_RELIEF_CORES:-}"; then
  cores=$FM_LOAD_RELIEF_CORES
else
  cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || cores=
  is_uint "$cores" || cores=$(sysctl -n hw.logicalcpu 2>/dev/null) || cores=
fi
is_uint "$cores" && [ "$cores" -gt 0 ] || cores=
[ -n "$ceiling" ] || ceiling=${cores:-}
[ -n "$ceiling" ] || die "no load ceiling: set max-load1 in config/lane-capacity or ceiling in config/load-relief"
is_positive_number "$ceiling" || die "load ceiling '$ceiling' is not a positive number"
[ -n "$resume_below" ] || resume_below=$(awk -v c="$ceiling" 'BEGIN { print c * 0.75 }')

# --- load probe ---------------------------------------------------------------
load1=
if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_LOAD_RELIEF_LOAD_FILE:-}" ]; then
  load1=$(awk 'NR==1{print $1}' "$FM_LOAD_RELIEF_LOAD_FILE" 2>/dev/null) || load1=
elif [ "$(uname -s 2>/dev/null)" = Darwin ]; then
  load1=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}') || load1=
else
  load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null) || load1=
fi
case "$load1" in [0-9]*) ;; *) echo "fm-load-relief: load probe unavailable; no action" >&2; exit 0 ;; esac

control_cmd="$SCRIPT_DIR/fm-control.sh"
send_cmd="$SCRIPT_DIR/fm-send.sh"
tasks_cmd="$SCRIPT_DIR/fm-tasks-axi.sh"
if [ "${FM_TEST_SEAM:-}" = 1 ]; then
  [ -z "${FM_LOAD_RELIEF_CONTROL:-}" ] || control_cmd=$FM_LOAD_RELIEF_CONTROL
  [ -z "${FM_LOAD_RELIEF_SEND:-}" ] || send_cmd=$FM_LOAD_RELIEF_SEND
  [ -z "${FM_LOAD_RELIEF_TASKS:-}" ] || tasks_cmd=$FM_LOAD_RELIEF_TASKS
fi

meta_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }
file_mtime() {
  local m
  m=$(stat -c %Y "$1" 2>/dev/null) || m=
  is_uint "$m" || m=$(/usr/bin/stat -f %m "$1" 2>/dev/null) || m=
  is_uint "$m" && printf '%s\n' "$m"
}

latest_verb() {
  status_line_verb "$(last_status_line "$STATE/$1.status")"
}

write_high_since() {
  [ "$dry_run" -eq 0 ] || return 0
  mkdir -p "$RELIEF_DIR" || die "cannot create $RELIEF_DIR"
  printf '%s\n' "$1" > "$RELIEF_DIR/high-since.tmp.$$" && mv "$RELIEF_DIR/high-since.tmp.$$" "$RELIEF_DIR/high-since"
}

# --- resume pass ---------------------------------------------------------------
if num_lt "$load1" "$resume_below"; then
  [ "$dry_run" -eq 0 ] && rm -f "$RELIEF_DIR/high-since"
  if [ -d "$PAUSED_DIR" ]; then
    resumable=
    for record in "$PAUSED_DIR"/*; do
      [ -f "$record" ] || continue
      id=$(basename "$record")
      case "$id" in *[!A-Za-z0-9._-]*) continue ;; esac
      if [ ! -f "$STATE/$id.meta" ] || case "$(latest_verb "$id")" in done|failed) true ;; *) false ;; esac; then
        if [ "$dry_run" -eq 0 ]; then
          rm -f "$record"
          echo "load-relief: dropped pause record for finished or removed $id"
        fi
        continue
      fi
      rprio=$(meta_get "$record" priority)
      repoch=$(meta_get "$record" paused_epoch)
      is_uint "$repoch" || repoch=0
      if is_uint "$rprio"; then
        resumable="$resumable$(printf '0\t%s\t0\t%s' "$((10#$rprio))" "$id")
"
      else
        resumable="$resumable$(printf '1\t0\t%s\t%s' "$repoch" "$id")
"
      fi
    done
    while IFS="$(printf '\t')" read -r _rank _prio _epoch id; do
      [ -n "$id" ] || continue
      if [ "$dry_run" -eq 1 ]; then
        echo "load-relief: would resume $id load=$load1 resume-below=$resume_below"
        break
      fi
      if FM_HOME="$FM_HOME" "$send_cmd" "$id" "Host load has fallen to $load1 (resume level $resume_below). Your load-relief pause is lifted; resume your task from where you left off." >/dev/null 2>&1; then
        rm -f "$PAUSED_DIR/$id"
        printf 'resolved [key=load-relief] [at=%s]: load relief lifted (load %s below %s); resumed by steer\n' "$now" "$load1" "$resume_below" >> "$STATE/$id.status" 2>/dev/null || true
        echo "load-relief: resumed $id load=$load1 resume-below=$resume_below"
        break
      fi
      echo "fm-load-relief: resume steer for $id was not confirmed delivered; its pause record is kept" >&2
    done <<EOF
$(printf '%s' "$resumable" | sort -t "$(printf '\t')" -k1,1n -k2,2n -k3,3nr)
EOF
  fi
  exit 0
fi

# --- sustained-high pass ---------------------------------------------------------
if ! num_ge "$load1" "$ceiling"; then
  [ "$dry_run" -eq 0 ] && rm -f "$RELIEF_DIR/high-since"
  exit 0
fi

high_since=
[ -f "$RELIEF_DIR/high-since" ] && high_since=$(head -1 "$RELIEF_DIR/high-since" 2>/dev/null)
is_uint "$high_since" || high_since=
if [ -z "$high_since" ]; then
  write_high_since "$now"
  echo "load-relief: load=$load1 at or over ceiling=$ceiling; sustained window started"
  exit 0
fi
elapsed=$((now - high_since))
if [ "$elapsed" -lt "$sustain_secs" ]; then
  echo "load-relief: load=$load1 at or over ceiling=$ceiling for ${elapsed}s of ${sustain_secs}s; no pause yet"
  exit 0
fi

# Candidates, worst priority first: larger backlog priority number, then
# newest dispatch. One tab-separated sortable row each.
candidates=$(mktemp "${TMPDIR:-/tmp}/fm-load-relief.XXXXXX") || die "cannot create a temporary file"
trap 'rm -f "$candidates"' EXIT
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  case "$id" in *[!A-Za-z0-9._-]*) continue ;; esac
  kind=$(meta_get "$meta" kind)
  case "$kind" in ship|scout|'') ;; *) continue ;; esac
  [ -f "$PAUSED_DIR/$id" ] && continue
  case "$(latest_verb "$id")" in
    done|failed|needs-decision|blocked|paused|captain-held) continue ;;
  esac
  prio=$(FM_HOME="$FM_HOME" "$tasks_cmd" show "$id" 2>/dev/null | sed -n 's/^  priority: //p' | head -1)
  is_uint "$prio" || continue
  gen=$(meta_get "$meta" spawn_gen)
  epoch=$(printf '%s' "$gen" | sed -n 's/^s\([0-9][0-9]*\).*/\1/p')
  is_uint "$epoch" || epoch=$(file_mtime "$meta")
  is_uint "$epoch" || epoch=0
  printf '%s\t%s\t%s\n' "$((10#$prio))" "$epoch" "$id" >> "$candidates"
done

paused=0
while IFS="$(printf '\t')" read -r _prio _epoch id; do
  [ -n "$id" ] || continue
  [ "$paused" -lt "$pause_per_check" ] || break
  if [ "$dry_run" -eq 1 ]; then
    echo "load-relief: would pause $id load=$load1 ceiling=$ceiling sustained=${elapsed}s"
    paused=$((paused + 1))
    continue
  fi
  mkdir -p "$PAUSED_DIR" || die "cannot create $PAUSED_DIR"
  if ! { printf 'id=%s\npaused_epoch=%s\npriority=%s\nload=%s\nceiling=%s\n' "$id" "$now" "$_prio" "$load1" "$ceiling" > "$PAUSED_DIR/$id.tmp.$$" \
      && mv "$PAUSED_DIR/$id.tmp.$$" "$PAUSED_DIR/$id"; }; then
    rm -f "$PAUSED_DIR/$id.tmp.$$"
    echo "fm-load-relief: cannot write the pause record for $id; it was not interrupted" >&2
    continue
  fi
  if FM_HOME="$FM_HOME" "$control_cmd" "$id" interrupt >/dev/null 2>&1; then
    printf 'paused [key=load-relief] [at=%s]: load relief: load %s at or over ceiling %s for %ss; interrupted in place, work preserved, resumes when load falls\n' \
      "$now" "$load1" "$ceiling" "$elapsed" >> "$STATE/$id.status" 2>/dev/null || true
    echo "load-relief: paused $id load=$load1 ceiling=$ceiling sustained=${elapsed}s"
    paused=$((paused + 1))
  else
    rm -f "$PAUSED_DIR/$id"
    echo "fm-load-relief: interrupt for $id was not delivered; it was not paused" >&2
  fi
done <<EOF
$(sort -t "$(printf '\t')" -k1,1nr -k2,2nr "$candidates")
EOF
[ "$paused" -eq 0 ] || write_high_since "$now"
[ "$paused" -gt 0 ] || echo "load-relief: load=$load1 sustained ${elapsed}s over ceiling=$ceiling; no live worker to pause"
exit 0
