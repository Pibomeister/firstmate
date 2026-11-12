#!/usr/bin/env bash
# fm-load-relief.sh - automatic host-load relief for live workers.
#
# Usage:
#   fm-load-relief.sh check [--dry-run]
#   fm-load-relief.sh --help
#
# One check pass reads the host 1-minute load once. When the load stays at or
# over the ceiling for the sustained window, the pass pauses exactly one
# lowest-priority live ship or scout whose recorded backend can deliver its
# harness's interrupt key: it writes a durable record under
# state/load-relief/paused/<id> bound to that worker's spawn_gen, delivers
# the verified interrupt through bin/fm-control.sh (the agent stays alive,
# its worktree and unlanded work untouched), and appends one paused: line to
# the task's status file. A meta with no backend= is the default tmux
# backend, and the recorded harness is mapped to its adapter family first.
# A nonzero interrupt keeps the record as state=uncertain, appends a keyed
# paused: line saying delivery is unproven, and counts toward the per-pass
# pause limit: delivery may already have happened, so the record is never
# dropped on an unproven failure, and the resume pass resolves it by steering
# that worker like a paused one. When a
# later pass reads load below the resume level, it lifts one load-relief
# pause per pass, highest priority (smallest priority number) first and,
# among records without a priority, the most recently paused first: the
# record is removed and bin/fm-send.sh steers the worker to resume. Nothing
# is killed, exited, or discarded. A successful pause, and a sustained pass
# that finds no eligible worker, both restart the sustained window, so each
# further pause needs a fresh full window over the ceiling. A high-since
# older than the window plus 300 s is stale (the watcher was away) and only
# restarts the window. Both status lines carry [key=load-relief], so lifting
# a pause never closes another open decision on that worker. A pause record
# whose task has no meta, whose spawn_gen no longer matches the record, or
# whose latest status is done or failed, is dropped without a steer.
#
# The watcher runs one detached check beside its lane-capacity publish while
# config/lane-capacity exists, and every 30 s while state/load-relief/paused/
# holds a record; load relief is opt-in on that declaration.
# The resume pass runs even when config/lane-capacity is absent or
# config/load-relief is malformed - the refusal is printed and the pause
# decision is what refuses - so a broken or removed opt-in never strands a
# paused worker.
#
# Ceiling and window, in order: the optional config/load-relief keys
# ceiling and resume-below win, then max-load1 from config/lane-capacity,
# then the logical core count. config/load-relief holds one key=value per
# line (# comments and blank lines ignored):
#   ceiling=<positive number>       load at or over this starts the window
#   resume-below=<positive number>  load under this lifts pauses (default 75%
#                                   of the ceiling; must be under it)
#   sustain-secs=<uint>             seconds at or over ceiling before a pause
#                                   (default 300)
#   pause-per-check=<uint>          workers paused per sustained pass (default 1)
# A malformed config/load-relief, or an unreadable config/lane-capacity,
# refuses the pause pass with exit 1 rather than guessing the captain's
# limits, after the resume pass above.
#
# Priority: the priority: field that bin/fm-tasks-axi.sh show <id> reports
# for the task's backlog item (the value add --priority N sets; a larger N is
# lower priority, so it pauses first). A task with no backlog item is never
# paused; an item with no numeric priority counts as the lowest priority and
# pauses first. Lanes that recorded a ready PR (pr=) are never paused. Ties
# break by newest dispatch first (the epoch in the meta spawn_gen, else the
# meta file's mtime), which has the least progress to lose.
#
# Candidates are pre-filtered to workers the interrupt can actually reach:
# bin/fm-control-lib.sh's fm_control_backend_supports_key must accept the
# worker's recorded backend for its harness's interrupt key (or the harness
# must use the REST interrupt transport). On the Orca backend that means
# only Droid (Escape) and Grok (C-c) workers are ever paused; other Orca
# workers are not candidates, and the pass never walks up the priority order
# past an unreachable worker by interrupting a higher-priority one instead -
# eligibility is part of candidacy, decided before any interrupt is sent.
#
# A worker with an open decision is never paused or resumed: the
# authoritative open-decision fold (status_open_decisions in
# bin/fm-classify-lib.sh) over its whole status file, its current declared
# wait, and a captain hold on its backlog item (the held: field) all count,
# never only the latest status verb. A decision raised after a pause
# therefore also defers that worker's resume until it is answered.
#
# State under state/load-relief/: high-since (epoch the current over-ceiling
# stretch began) and paused/<id> (key=value: id, paused_epoch, priority,
# load, ceiling, spawn_gen, state paused|uncertain). A check that finds load
# under the ceiling clears high-since.
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
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
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

now=$(date +%s)
if [ "${FM_TEST_SEAM:-}" = 1 ] && is_uint "${FM_LOAD_RELIEF_NOW:-}"; then
  now=$FM_LOAD_RELIEF_NOW
fi

# --- load probe and cores (independent of any config) -------------------------
load1=
if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_LOAD_RELIEF_LOAD_FILE:-}" ]; then
  load1=$(awk 'NR==1{print $1}' "$FM_LOAD_RELIEF_LOAD_FILE" 2>/dev/null) || load1=
elif [ "$(uname -s 2>/dev/null)" = Darwin ]; then
  load1=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}') || load1=
else
  load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null) || load1=
fi
case "$load1" in [0-9]*) ;; *) echo "fm-load-relief: load probe unavailable; no action" >&2; exit 0 ;; esac

cores=
if [ "${FM_TEST_SEAM:-}" = 1 ] && is_uint "${FM_LOAD_RELIEF_CORES:-}"; then
  cores=$FM_LOAD_RELIEF_CORES
else
  cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || cores=
  is_uint "$cores" || cores=$(sysctl -n hw.logicalcpu 2>/dev/null) || cores=
fi
is_uint "$cores" && [ "$cores" -gt 0 ] || cores=

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

# tasks_show <id>: the one recorded backlog read per task per pass; prints
# the show output, or nothing when the task has no backlog item.
tasks_show() {
  FM_HOME="$FM_HOME" "$tasks_cmd" show "$1" 2>/dev/null
}

# worker_waiting <id> <show-output>: the worker has an open decision or a
# captain hold - an open decision from the authoritative fold over the
# whole status file, a current declared wait that is not this relief's own
# pause, or held: yes on its backlog item.
worker_waiting() {
  local id=$1 show=$2 last
  [ -n "$(status_open_decisions "$STATE/$id.status")" ] && return 0
  printf '%s\n' "$show" | grep -q '^  held: yes' && return 0
  last=$(last_status_line "$STATE/$id.status")
  if status_is_captain_held "$last"; then return 0; fi
  if status_is_paused "$last"; then
    case "$last" in *"[key=load-relief]"*) ;; *) return 0 ;; esac
  fi
  return 1
}

# interrupt_eligible <meta>: the recorded backend can deliver this harness's
# interrupt, through the REST transport or the key table.
interrupt_eligible() {
  local backend harness key
  backend=$(meta_get "$1" backend)
  backend=${backend:-tmux}
  harness=$(fm_control_harness_family "$(meta_get "$1" harness)") || return 1
  [ "$(fm_control_interrupt_transport "$harness" 2>/dev/null)" = rest ] && return 0
  key=$(fm_control_interrupt_key "$harness" 2>/dev/null) || return 1
  [ -n "$key" ] || return 1
  fm_control_backend_supports_key "$backend" "$key" "$harness"
}

write_high_since() {
  [ "$dry_run" -eq 0 ] || return 0
  mkdir -p "$RELIEF_DIR" || die "cannot create $RELIEF_DIR"
  printf '%s\n' "$1" > "$RELIEF_DIR/high-since.tmp.$$" && mv "$RELIEF_DIR/high-since.tmp.$$" "$RELIEF_DIR/high-since"
}

# resume_pass <resume-level>: lift at most one pause while load is under the
# level. Records for removed, finished, or incarnation-mismatched tasks are
# dropped without a steer; a worker with an open decision keeps its record
# and is not steered.
resume_pass() {
  local level=$1 record id show rgen mgen rprio repoch resumable stale
  num_lt "$load1" "$level" || return 0
  [ "$dry_run" -eq 0 ] && rm -f "$RELIEF_DIR/high-since"
  [ -d "$PAUSED_DIR" ] || return 0
  resumable=
  for record in "$PAUSED_DIR"/*; do
    [ -f "$record" ] || continue
    id=$(basename "$record")
    case "$id" in *[!A-Za-z0-9._-]*) continue ;; esac
    show=$(tasks_show "$id")
    rgen=$(meta_get "$record" spawn_gen)
    mgen=
    [ -f "$STATE/$id.meta" ] && mgen=$(meta_get "$STATE/$id.meta" spawn_gen)
    stale=0
    [ -f "$STATE/$id.meta" ] || stale=1
    if [ -n "$rgen" ] && [ "$rgen" != "$mgen" ]; then stale=1; fi
    case "$(latest_verb "$id")" in done|failed) stale=1 ;; esac
    if [ "$stale" -eq 1 ]; then
      if [ "$dry_run" -eq 0 ]; then
        rm -f "$record"
        echo "load-relief: dropped pause record for finished, removed, or replaced $id"
      fi
      continue
    fi
    worker_waiting "$id" "$show" && continue
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
      echo "load-relief: would resume $id load=$load1 resume-below=$level"
      break
    fi
    if FM_HOME="$FM_HOME" "$send_cmd" "$id" "Host load has fallen to $load1 (resume level $level). Your load-relief pause is lifted; resume your task from where you left off." >/dev/null 2>&1; then
      rm -f "$PAUSED_DIR/$id"
      printf 'resolved [key=load-relief] [at=%s]: load relief lifted (load %s below %s); resumed by steer\n' "$now" "$load1" "$level" >> "$STATE/$id.status" 2>/dev/null || true
      echo "load-relief: resumed $id load=$load1 resume-below=$level"
      break
    fi
    echo "fm-load-relief: resume steer for $id was not confirmed delivered; its pause record is kept" >&2
  done <<EOF
$(printf '%s' "$resumable" | sort -t "$(printf '\t')" -k1,1n -k2,2n -k3,3nr)
EOF
}

# --- configuration (best effort first, so the resume level always exists) -----
lane_present=0
[ -e "$LANE_CONFIG" ] && lane_present=1
ceiling=
resume_below=
sustain_secs=300
pause_per_check=1
config_error=
if [ "$lane_present" -eq 1 ]; then
  if [ ! -r "$LANE_CONFIG" ]; then
    config_error="config/lane-capacity is unreadable; refusing to guess the load ceiling"
  else
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%%#*}
      line=$(printf '%s' "$line" | tr '\t\r' '  ' | sed 's/^ *//; s/ *$//')
      [ "${line%% *}" = max-load1 ] || continue
      value=$(printf '%s' "${line#* }" | sed 's/^ *//')
      [ -z "$ceiling" ] && ceiling=$value
    done < "$LANE_CONFIG"
  fi
fi
if [ -e "$RELIEF_CONFIG" ]; then
  if [ ! -r "$RELIEF_CONFIG" ]; then
    config_error="config/load-relief is unreadable; refusing to guess its values"
  else
    lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
      lineno=$((lineno + 1))
      line=${line%%#*}
      line=$(printf '%s' "$line" | sed 's/^ *//; s/ *$//')
      [ -n "$line" ] || continue
      key=${line%%=*} value=${line#*=}
      if [ "$key" = "$line" ]; then config_error="config/load-relief line $lineno: expected key=value"; break; fi
      case "$key" in
        ceiling) is_positive_number "$value" || { config_error="config/load-relief line $lineno: ceiling needs a positive number"; break; }; ceiling=$value ;;
        resume-below) is_positive_number "$value" || { config_error="config/load-relief line $lineno: resume-below needs a positive number"; break; }; resume_below=$value ;;
        sustain-secs) is_uint "$value" || { config_error="config/load-relief line $lineno: sustain-secs needs a non-negative integer"; break; }; sustain_secs=$((10#$value)) ;;
        pause-per-check) is_uint "$value" && [ "$value" -ge 1 ] || { config_error="config/load-relief line $lineno: pause-per-check needs a positive integer"; break; }; pause_per_check=$((10#$value)) ;;
        *) config_error="config/load-relief line $lineno: unknown key '$key'"; break ;;
      esac
    done < "$RELIEF_CONFIG"
  fi
fi
[ -n "$ceiling" ] || ceiling=${cores:-}
if [ -z "$ceiling" ] || ! is_positive_number "$ceiling"; then
  [ -n "$config_error" ] || config_error="no load ceiling: set max-load1 in config/lane-capacity or ceiling in config/load-relief"
  ceiling=${cores:-}
fi
if [ -n "$resume_below" ]; then
  if [ -n "$ceiling" ] && ! num_lt "$resume_below" "$ceiling"; then
    [ -n "$config_error" ] || config_error="config/load-relief: resume-below $resume_below must be under the load ceiling $ceiling"
    resume_below=$(awk -v c="$ceiling" 'BEGIN { print c * 0.75 }')
  fi
else
  resume_below=$(awk -v c="${ceiling:-0}" 'BEGIN { print c * 0.75 }')
fi

# The resume pass runs before any refusal, on the best-effort level.
[ -z "$config_error" ] || echo "fm-load-relief: $config_error" >&2
resume_pass "$resume_below"
if num_lt "$load1" "$resume_below"; then exit 0; fi
if [ "$lane_present" -eq 0 ]; then exit 0; fi
[ -z "$config_error" ] || exit 1
is_positive_number "$ceiling" || die "load ceiling '$ceiling' is not a positive number"

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
if [ "$elapsed" -gt $((sustain_secs + 300)) ]; then
  write_high_since "$now"
  echo "load-relief: load=$load1 at or over ceiling=$ceiling; stale high-since restarted the window"
  exit 0
fi
if [ "$elapsed" -lt "$sustain_secs" ]; then
  echo "load-relief: load=$load1 at or over ceiling=$ceiling for ${elapsed}s of ${sustain_secs}s; no pause yet"
  exit 0
fi

# Candidates, worst priority first: items without a numeric priority, then
# larger backlog priority number, then newest dispatch. Only workers whose
# recorded backend can deliver the interrupt are candidates at all.
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
    done|failed) continue ;;
  esac
  grep -q '^pr=..*' "$meta" 2>/dev/null && continue
  interrupt_eligible "$meta" || continue
  show=$(tasks_show "$id")
  [ -n "$show" ] || continue
  worker_waiting "$id" "$show" && continue
  prio=$(printf '%s\n' "$show" | sed -n 's/^  priority: //p' | head -1)
  [ -n "$prio" ] || continue
  if is_uint "$prio"; then rank=1; prio=$((10#$prio)); else rank=0; prio=0; fi
  gen=$(meta_get "$meta" spawn_gen)
  epoch=$(printf '%s' "$gen" | sed -n 's/^s\([0-9][0-9]*\).*/\1/p')
  is_uint "$epoch" || epoch=$(file_mtime "$meta")
  is_uint "$epoch" || epoch=0
  printf '%s\t%s\t%s\t%s\t%s\n' "$rank" "$prio" "$epoch" "$id" "$gen" >> "$candidates"
done

paused=0
while IFS="$(printf '\t')" read -r _rank _prio _epoch id gen; do
  [ -n "$id" ] || continue
  [ "$_rank" = 1 ] || _prio=
  [ "$paused" -lt "$pause_per_check" ] || break
  if [ "$dry_run" -eq 1 ]; then
    echo "load-relief: would pause $id load=$load1 ceiling=$ceiling sustained=${elapsed}s"
    paused=$((paused + 1))
    continue
  fi
  mkdir -p "$PAUSED_DIR" || die "cannot create $PAUSED_DIR"
  if ! { printf 'id=%s\npaused_epoch=%s\npriority=%s\nload=%s\nceiling=%s\nspawn_gen=%s\nstate=paused\n' "$id" "$now" "$_prio" "$load1" "$ceiling" "$gen" > "$PAUSED_DIR/$id.tmp.$$" \
      && mv "$PAUSED_DIR/$id.tmp.$$" "$PAUSED_DIR/$id"; }; then
    rm -f "$PAUSED_DIR/$id.tmp.$$"
    echo "fm-load-relief: cannot write the pause record for $id; it was not interrupted" >&2
    continue
  fi
  control_out=$(FM_HOME="$FM_HOME" "$control_cmd" "$id" interrupt 2>&1) && control_rc=0 || control_rc=$?
  if [ "$control_rc" -eq 0 ]; then
    printf 'paused [key=load-relief] [at=%s]: load relief: load %s at or over ceiling %s for %ss; interrupted in place, work preserved, resumes when load falls\n' \
      "$now" "$load1" "$ceiling" "$elapsed" >> "$STATE/$id.status" 2>/dev/null || true
    echo "load-relief: paused $id load=$load1 ceiling=$ceiling sustained=${elapsed}s"
    paused=$((paused + 1))
  else
    sed -i.bak 's/^state=paused$/state=uncertain/' "$PAUSED_DIR/$id" 2>/dev/null && rm -f "$PAUSED_DIR/$id.bak"
    printf 'paused [key=load-relief] [at=%s]: load relief: load %s at or over ceiling %s for %ss; interrupt delivery unproven (control exit %s); record kept as uncertain, resumes when load falls\n' \
      "$now" "$load1" "$ceiling" "$elapsed" "$control_rc" >> "$STATE/$id.status" 2>/dev/null || true
    paused=$((paused + 1))
    echo "fm-load-relief: interrupt for $id returned $control_rc; its pause record is kept as uncertain because delivery is unproven: $control_out" >&2
  fi
done <<EOF
$(sort -t "$(printf '\t')" -k1,1n -k2,2nr -k3,3nr "$candidates")
EOF
write_high_since "$now"
[ "$paused" -gt 0 ] || echo "load-relief: load=$load1 sustained ${elapsed}s over ceiling=$ceiling; no live worker to pause"
exit 0
