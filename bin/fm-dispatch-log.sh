#!/usr/bin/env bash
# fm-dispatch-log.sh - timestamped captain-goal intake ledger with a dispatch SLA.
#
# Usage:
#   fm-dispatch-log.sh received   <goal-id> --summary <text> [--project <name>]
#   fm-dispatch-log.sh dispatched <goal-id> --task <task-id> [--note <text>]
#   fm-dispatch-log.sh blocked    <goal-id> --reason <text>
#   fm-dispatch-log.sh overdue
#   fm-dispatch-log.sh show       [<goal-id>]
#
# Every new captain goal gets one `received` line the moment it is read, and
# then, within the dispatch SLA (default 15 minutes), either a `dispatched`
# line naming the spawned task or a `blocked` line naming the concrete reason
# nothing was spawned. The ledger is append-only TSV:
#   <utc-iso>\t<epoch>\t<event>\t<goal-id>\t<detail>
# A goal's current state is its newest line. `blocked` is an explicit, logged
# outcome and is not overdue; a later `dispatched` supersedes it.
#
# `overdue` prints every goal whose newest line is still `received` and older
# than the SLA, one per line as `OVERDUE <goal-id> age=<m>m received=<iso>
# summary=<text>`, and exits 3 when any exist (0 when none). Supervision runs it
# on every heartbeat and wake-handling turn so a goal cannot sit silently.
#
# Refuses, and writes nothing, when: the goal id is not [A-Za-z0-9._-]+;
# a required flag is missing or empty; `received` repeats an id already in the
# ledger; or `dispatched`/`blocked` names a goal with no `received` line.
# Tabs and newlines in free text are folded to spaces.
#
# Environment: FM_HOME selects the home; FM_STATE_OVERRIDE overrides its state
# directory; FM_DISPATCH_LOG overrides the ledger path (default
# <state>/dispatch-log.tsv); FM_DISPATCH_SLA_MINUTES overrides the default SLA;
# FM_DISPATCH_NOW overrides the current epoch (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOG="${FM_DISPATCH_LOG:-$STATE/dispatch-log.tsv}"
SLA_MIN="${FM_DISPATCH_SLA_MINUTES:-15}"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

fail() {
  printf 'fm-dispatch-log: %s\n' "$*" >&2
  exit 1
}

now_epoch() { printf '%s\n' "${FM_DISPATCH_NOW:-$(date +%s)}"; }

iso_of() {
  date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'
}

clean() { printf '%s' "$1" | tr '\t\r\n' '   '; }

valid_id() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

latest_event() {  # <goal-id> -> newest event name, empty when absent
  [ -f "$LOG" ] || return 0
  awk -F '\t' -v g="$1" '$4 == g { e = $3 } END { if (e != "") print e }' "$LOG"
}

append() {  # <event> <goal-id> <detail>
  local epoch
  epoch=$(now_epoch)
  mkdir -p "$(dirname "$LOG")"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(iso_of "$epoch")" "$epoch" "$1" "$2" "$(clean "$3")" >> "$LOG"
  printf '%s %s %s: %s\n' "$(iso_of "$epoch")" "$1" "$2" "$(clean "$3")"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  received|dispatched|blocked|overdue|show) cmd=$1; shift ;;
  *) usage >&2; exit 2 ;;
esac

goal=''
case "$cmd" in
  received|dispatched|blocked)
    goal="${1:-}"
    valid_id "$goal" || fail "goal id must match [A-Za-z0-9._-]+: '${goal}'"
    shift
    ;;
  show)
    if [ "$#" -gt 0 ]; then goal=$1; shift; fi
    ;;
esac

summary='' project='' task='' note='' reason=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --summary) summary="${2:-}"; shift 2 || fail "--summary needs a value" ;;
    --project) project="${2:-}"; shift 2 || fail "--project needs a value" ;;
    --task) task="${2:-}"; shift 2 || fail "--task needs a value" ;;
    --note) note="${2:-}"; shift 2 || fail "--note needs a value" ;;
    --reason) reason="${2:-}"; shift 2 || fail "--reason needs a value" ;;
    *) fail "unknown argument: $1" ;;
  esac
done

case "$cmd" in
  received)
    [ -n "$summary" ] || fail "received needs --summary"
    [ -z "$(latest_event "$goal")" ] || fail "goal $goal is already in the ledger"
    detail="summary=$summary"
    [ -z "$project" ] || detail="project=$project $detail"
    append received "$goal" "$detail"
    ;;
  dispatched)
    [ -n "$task" ] || fail "dispatched needs --task"
    [ -n "$(latest_event "$goal")" ] || fail "goal $goal has no received line"
    detail="task=$task"
    [ -z "$note" ] || detail="$detail note=$note"
    append dispatched "$goal" "$detail"
    ;;
  blocked)
    [ -n "$reason" ] || fail "blocked needs --reason"
    [ -n "$(latest_event "$goal")" ] || fail "goal $goal has no received line"
    append blocked "$goal" "reason=$reason"
    ;;
  overdue)
    case "$SLA_MIN" in ''|*[!0-9]*) fail "FM_DISPATCH_SLA_MINUTES must be a whole number" ;; esac
    [ -f "$LOG" ] || exit 0
    now=$(now_epoch)
    out=$(awk -F '\t' -v now="$now" -v sla="$((SLA_MIN * 60))" '
      { ev[$4] = $3; if ($3 == "received") { at[$4] = $2; iso[$4] = $1; det[$4] = $5; order[++n] = $4 } }
      END {
        for (i = 1; i <= n; i++) {
          g = order[i]
          if (ev[g] == "received" && now - at[g] > sla)
            printf "OVERDUE %s age=%dm received=%s %s\n", g, int((now - at[g]) / 60), iso[g], det[g]
        }
      }' "$LOG")
    [ -z "$out" ] && exit 0
    printf '%s\n' "$out"
    exit 3
    ;;
  show)
    [ -f "$LOG" ] || exit 0
    if [ -n "$goal" ]; then
      awk -F '\t' -v g="$goal" '$4 == g' "$LOG"
    else
      cat "$LOG"
    fi
    ;;
esac
