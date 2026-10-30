#!/usr/bin/env bash
# fm-dispatch-log.sh - timestamped captain-goal intake ledger with a dispatch SLA.
#
# Usage:
#   fm-dispatch-log.sh received   <goal-id> --summary <text> [--project <name>]
#   fm-dispatch-log.sh dispatched <goal-id> --task <task-id> [--note <text>]
#   fm-dispatch-log.sh queued     <goal-id> --reason <text>
#   fm-dispatch-log.sh blocked    <goal-id> --reason <text>
#   fm-dispatch-log.sh overdue
#   fm-dispatch-log.sh show       [<goal-id>]
#
# A goal is one new captain ask for work: a chat request, an inbox note, or an
# away-mode ask. A follow-up that only amends a goal already in the ledger is
# not a new goal. Its id is `<project-or-topic>-<yyyymmddHHMM>` from the moment
# it was read (add `-2`, `-3` for more goals in the same minute) and must match
# [A-Za-z0-9._-]+.
#
# Every new goal gets one `received` line the moment it is read, and then,
# within the dispatch SLA (default 15 minutes), a `dispatched` line naming the
# spawned task or a `blocked` line naming the concrete reason nothing can start.
# Routing a goal to a secondmate is `dispatched --task secondmate:<id>`; the
# secondmate logs the goal again in its own home's ledger.
# `queued` records work waiting behind other work: it is not final, and the
# goal still goes overdue until it is dispatched or blocked.
# The ledger is append-only TSV:
#   <utc-iso>\t<epoch>\t<event>\t<goal-id>\t<detail>
# A goal's current state is its newest line. `dispatched` and `blocked` are
# final; a later `dispatched` supersedes a `blocked`.
# The SLA is judged once, at the goal's first final line anywhere in its history:
# if that line is past the SLA, its detail ends with ` late=<m>m` (minutes since
# `received`) and it also prints `LATE <goal-id> late=<m>m`, so a late dispatch
# stays on record for `show`. `queued` lines and lines after the first final line
# never add a late mark. A trailing ` late=<m>m` in caller free text is dropped,
# so only the script can write the mark.
#
# A goal is overdue when its newest line is `received` or `queued` and the SLA
# has passed since its clock start: `received` if it has never had a final line
# (`queued` does not reset it), else its newest `queued` line. A re-queued goal
# that goes overdue and is later dispatched gets no second late mark.
#
# `overdue` prints every overdue goal, with age counted from its clock start, as
# `OVERDUE <goal-id> age=<m>m received=<iso>
# [project=<name> ]summary=<text>`, then every goal whose late final line was
# written in the last 24 hours, as `LATE <goal-id> late=<m>m event=<event>`; older
# late marks stay in `show`. It exits 3 when any OVERDUE line exists and 0 otherwise;
# exit 3 is a result to act on, not an error.
#
# Refuses, and writes nothing, when: the goal id is not [A-Za-z0-9._-]+; a
# required flag is missing, empty, or only space after tab and newline folding
# and late-mark removal; a flag value starts with `-`; an argument is unknown;
# FM_DISPATCH_SLA_MINUTES is not a whole number and the subcommand reads the SLA
# (`dispatched`, `queued`, `blocked`, `overdue`; `received` and `show` do not); or
# `dispatched`/`queued`/`blocked` names a goal with no `received` line (all exit 1).
# An unknown subcommand prints this usage and exits 2. `received` for an id
# already in the ledger exits 4, so a retry can tell "already logged" from a
# mistake.
# Tabs and newlines in free text are folded to spaces.
# `show` with no id prints the ledger. `show <goal-id>` prints one state line,
# `STATE <goal-id> event=<event> at=<iso> <detail>`, then that goal's ledger
# lines. An id with no ledger line exits 1, unlike an empty ledger.
#
# Environment: FM_HOME selects the home; FM_STATE_OVERRIDE overrides its state
# directory (the ledger is <state>/dispatch-log.tsv); FM_DISPATCH_SLA_MINUTES
# overrides the default SLA as a decimal whole number (a leading zero does not
# make it octal); FM_DISPATCH_NOW overrides the current epoch (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOG="$STATE/dispatch-log.tsv"
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

strip_late() { clean "$1" | sed -E 's/( late=[0-9]+m)+$//'; }

has_text() {
  local text
  text=$(strip_late "$1")
  case "$text" in *[![:space:]]*) return 0 ;; esac
  return 1
}

valid_id() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

sla_seconds() {
  local minutes=$SLA_MIN
  case "$minutes" in ''|*[!0-9]*) fail "FM_DISPATCH_SLA_MINUTES must be a whole number" ;; esac
  minutes=$((10#$minutes))
  printf '%s\n' "$((minutes * 60))"
}

latest_event() {  # <goal-id> -> newest event name, empty when absent
  [ -f "$LOG" ] || return 0
  awk -F '\t' -v g="$1" '$4 == g { e = $3 } END { if (e != "") print e }' "$LOG"
}

append() {  # <epoch> <event> <goal-id> <detail>
  mkdir -p "$STATE"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(iso_of "$1")" "$1" "$2" "$3" "$(clean "$4")" >> "$LOG"
  printf '%s %s %s: %s\n' "$(iso_of "$1")" "$2" "$3" "$(clean "$4")"
}

resolve() {  # <event> <goal-id> <detail>: append a resolution, marking lateness
  local sla epoch received judged age late='' detail
  sla=$(sla_seconds)
  [ -n "$(latest_event "$2")" ] || fail "goal $2 has no received line"
  epoch=$(now_epoch)
  detail=$(strip_late "$3")
  judged=$(awk -F '\t' -v g="$2" '$4 == g && ($3 == "dispatched" || $3 == "blocked") { print "yes"; exit }' "$LOG")
  if [ "$1" != queued ] && [ -z "$judged" ]; then
    received=$(awk -F '\t' -v g="$2" '$4 == g && $3 == "received" { print $2; exit }' "$LOG")
    age=$((epoch - received))
    [ "$age" -le "$sla" ] || late=" late=$((age / 60))m"
  fi
  append "$epoch" "$1" "$2" "$detail$late"
  [ -z "$late" ] || printf 'LATE %s%s\n' "$2" "$late"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  received|dispatched|queued|blocked|overdue|show) cmd=$1; shift ;;
  *) usage >&2; exit 2 ;;
esac

goal=''
case "$cmd" in
  received|dispatched|queued|blocked)
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
    --summary)
      [ $# -ge 2 ] || fail "--summary needs a value"
      case "$2" in -*) fail "--summary value looks like a flag: $2" ;; esac
      summary=$2
      shift 2
      ;;
    --project)
      [ $# -ge 2 ] || fail "--project needs a value"
      case "$2" in -*) fail "--project value looks like a flag: $2" ;; esac
      project=$2
      shift 2
      ;;
    --task)
      [ $# -ge 2 ] || fail "--task needs a value"
      case "$2" in -*) fail "--task value looks like a flag: $2" ;; esac
      task=$2
      shift 2
      ;;
    --note)
      [ $# -ge 2 ] || fail "--note needs a value"
      case "$2" in -*) fail "--note value looks like a flag: $2" ;; esac
      note=$2
      shift 2
      ;;
    --reason)
      [ $# -ge 2 ] || fail "--reason needs a value"
      case "$2" in -*) fail "--reason value looks like a flag: $2" ;; esac
      reason=$2
      shift 2
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done

case "$cmd" in
  received)
    has_text "$summary" || fail "received needs --summary"
    if [ -n "$(latest_event "$goal")" ]; then
      printf 'fm-dispatch-log: goal %s is already in the ledger\n' "$goal" >&2
      exit 4
    fi
    detail="summary=$summary"
    [ -z "$project" ] || detail="project=$project $detail"
    append "$(now_epoch)" received "$goal" "$detail"
    ;;
  dispatched)
    has_text "$task" || fail "dispatched needs --task"
    detail="task=$task"
    [ -z "$note" ] || detail="$detail note=$note"
    resolve dispatched "$goal" "$detail"
    ;;
  queued|blocked)
    has_text "$reason" || fail "$cmd needs --reason"
    resolve "$cmd" "$goal" "reason=$reason"
    ;;
  overdue)
    sla=$(sla_seconds)
    [ -f "$LOG" ] || exit 0
    now=$(now_epoch)
    rc=0
    out=$(awk -F '\t' -v now="$now" -v sla="$sla" '
      ($3 == "dispatched" || $3 == "blocked") && !($4 in final) {
        final[$4] = $2
        if (match($5, / late=[0-9]+m$/)) { late[$4] = substr($5, RSTART + 6, RLENGTH - 6); lev[$4] = $3 }
      }
      $3 == "queued" && ($4 in final) { start[$4] = $2 }
      $3 == "received" { start[$4] = $2; iso[$4] = $1; det[$4] = $5; order[++n] = $4 }
      { ev[$4] = $3 }
      END {
        for (i = 1; i <= n; i++) {
          g = order[i]
          if ((ev[g] == "received" || ev[g] == "queued") && now - start[g] > sla) {
            printf "OVERDUE %s age=%dm received=%s %s\n", g, int((now - start[g]) / 60), iso[g], det[g]
            over = 1
          }
        }
        for (i = 1; i <= n; i++) {
          g = order[i]
          if ((g in late) && now - final[g] <= 86400) printf "LATE %s late=%s event=%s\n", g, late[g], lev[g]
        }
        exit over ? 3 : 0
      }' "$LOG") || rc=$?
    [ -z "$out" ] || printf '%s\n' "$out"
    exit "$rc"
    ;;
  show)
    if [ -z "$goal" ]; then
      [ -f "$LOG" ] || exit 0
      cat "$LOG"
      exit 0
    fi
    [ -f "$LOG" ] || fail "goal $goal is not in the ledger"
    state=$(awk -F '\t' -v g="$goal" '
      $4 == g { e = $3; iso = $1; det = $5; found = 1 }
      END { if (found) printf "STATE %s event=%s at=%s %s\n", g, e, iso, det }
    ' "$LOG")
    [ -n "$state" ] || fail "goal $goal is not in the ledger"
    printf '%s\n' "$state"
    awk -F '\t' -v g="$goal" '$4 == g' "$LOG"
    ;;
esac
