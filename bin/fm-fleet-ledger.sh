#!/usr/bin/env bash
# fm-fleet-ledger.sh - append records to the opt-in fleet activity ledger.
#
# docs/fleet-ledger.md owns the public record contract (file, events, fields,
# limits). This header owns only the writer mechanics.
#
# Off by default. Every producer guards its call with one file test on the
# home's config/fleet-ledger flag, so while the flag is absent this script is
# never run. It repeats that test so a direct invocation writes nothing.
#
# Producers:
#   bin/fm-brief.sh              appended (in every worker's status command,
#                                right after its unchanged plain append)
#   bin/fm-spawn.sh              dispatched (fresh spawns only, never relaunch)
#   bin/fm-watch.sh              capture, once per poll cycle; activity, when
#                                a worker's screen changed, at most once per
#                                FM_FLEET_LEDGER_HEARTBEAT_SECS per task;
#                                stalled, when it queues a stale wake
#   bin/fm-pr-check.sh           pr_ready (a PR registered for review, not the
#                                merge-time re-record from bin/fm-pr-merge.sh)
#   bin/fm-merge-outcome-lib.sh  merged ... pr (a recorded PR merge)
#   bin/fm-merge-local.sh        merged ... local (a local-only landing)
#   bin/fm-teardown.sh           cleaned_up
#
# Usage:
#   fm-fleet-ledger.sh dispatched <task> <kind> <project> <harness> <model>
#   fm-fleet-ledger.sh pr_ready <task> <url>
#   fm-fleet-ledger.sh merged <task> pr <url>
#   fm-fleet-ledger.sh merged <task> local
#   fm-fleet-ledger.sh cleaned_up <task>
#   fm-fleet-ledger.sh capture
#   fm-fleet-ledger.sh appended <config> <state>/<task>.status
#   fm-fleet-ledger.sh activity <task>
#   fm-fleet-ledger.sh stalled <task> <reason>
#
# Derived events live in docs/fleet-ledger.md "Derived events".
# state/.<task>.fleet-ledger-started holds the spawn_gen already announced;
# dispatched and cleaned_up delete it. activity uses that file to decide
# started vs heartbeat; the watcher owns its throttle.
#
# Envelope. Every record carries the source envelope docs/fleet-ledger.md
# documents: event_id and seq from state/.fleet-ledger.seq, the home-wide last
# sequence number (when absent or behind, the ledger's last record's seq wins),
# task_rev from state/.<task>.fleet-ledger-rev, which dispatched and cleaned_up
# delete, source from bin/fm-producer-identity-lib.sh, and binding from the
# task's meta. Both counters are saved only after their record is appended, so
# an interrupted write can repeat a number but never skips one. A record whose
# identity cannot be loaded is not written.
#
# capture appends one task.status record for every complete (newline-ended)
# line added to a state/<task>.status log since that task's byte offset in
# state/.<task>.fleet-ledger-offset. An absent offset reads from byte 0, and a
# log shorter than its offset is re-read from byte 0. A partial last line waits
# for a later capture. Records are appended before the offset is saved, so an
# interrupted capture repeats records rather than losing them. Without any
# grown log, capture returns after one size listing and sources nothing.
# appended captures only that task, so a worker's status line is recorded as
# soon as the worker writes it; the byte offset keeps the per-poll capture from
# recording it again. Its arguments name the home, because a worker has no
# firstmate environment: the flag lives in <config> and the state directory is
# the status file's directory.
# pr_ready, merged, and cleaned_up first capture their own task, so its status
# records precede them. cleaned_up then deletes the task's offset, because teardown
# retires that status log right after. dispatched deletes any leftover offset
# so a reused task id starts at byte 0 of its fresh log.
# Every write holds state/.fleet-ledger.lock.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, and FM_CONFIG_OVERRIDE resolve the
# home exactly as the other bin/ scripts do.
#
# Exit status: 0 on success or when off, 2 on a usage error, 1 when a record
# could not be written. Producers ignore a failure so it never changes theirs.
set -u
# Byte semantics for offsets and lengths; jq still reads the text as UTF-8.
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-bash-compat-lib.sh
. "$SCRIPT_DIR/fm-bash-compat-lib.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LEDGER="$STATE/fleet-ledger.jsonl"
LOCK="$STATE/.fleet-ledger.lock"
TEXT_MAX_CHARS=2000

usage() {
  echo "usage: fm-fleet-ledger.sh dispatched <task> <kind> <project> <harness> <model> | pr_ready <task> <url> | merged <task> pr <url> | merged <task> local | cleaned_up <task> | capture | appended <config> <state>/<task>.status | activity <task> | stalled <task> <reason>" >&2
  exit 2
}

task_ok() {
  case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

cmd=${1:-}
case "$cmd" in
  dispatched) { [ "$#" -eq 6 ] && task_ok "$2"; } || usage ;;
  pr_ready) { [ "$#" -eq 3 ] && task_ok "$2" && [ -n "$3" ]; } || usage ;;
  merged)
    task_ok "${2:-}" || usage
    case "$#:${3:-}" in 4:pr) [ -n "$4" ] || usage ;; 3:local) ;; *) usage ;; esac
    ;;
  cleaned_up|activity) { [ "$#" -eq 2 ] && task_ok "$2"; } || usage ;;
  stalled) { [ "$#" -eq 3 ] && task_ok "$2" && [ -n "$3" ]; } || usage ;;
  capture) [ "$#" -eq 1 ] || usage ;;
  appended)
    [ "$#" -eq 3 ] && [ -n "$2" ] || usage
    case "$3" in /*/*.status) ;; *) usage ;; esac
    APPENDED_TASK=${3##*/}
    APPENDED_TASK=${APPENDED_TASK%.status}
    task_ok "$APPENDED_TASK" || usage
    CONFIG=$2
    STATE=${3%/*}
    [ -n "${FM_DATA_OVERRIDE:-}" ] || DATA=${STATE%/*}/data
    LEDGER="$STATE/fleet-ledger.jsonl"
    LOCK="$STATE/.fleet-ledger.lock"
    ;;
  *) usage ;;
esac

[ -e "$CONFIG/fleet-ledger" ] || exit 0
[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 1

offset_path() { printf '%s/.%s.fleet-ledger-offset' "$STATE" "$1"; }
started_path() { printf '%s/.%s.fleet-ledger-started' "$STATE" "$1"; }
rev_path() { printf '%s/.%s.fleet-ledger-rev' "$STATE" "$1"; }
SEQ_FILE="$STATE/.fleet-ledger.seq"

meta_field() { # <task> <field>: the field's last value in state/<task>.meta, or empty
  local line value=''
  [ -f "$STATE/$1.meta" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) value=${line#*=} ;; esac
  done < "$STATE/$1.meta"
  printf '%s' "$value"
}

sha256_of() { # <file>
  local digest
  if command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 < "$1") || return 1
  else
    digest=$(sha256sum < "$1") || return 1
  fi
  printf '%s' "${digest%% *}"
}

read_offset() { # <task> <out-var>: saved byte offset, 0 when absent or malformed
  local value=0
  { IFS= read -r value < "$STATE/.$1.fleet-ledger-offset"; } 2>/dev/null || value=0
  case "$value" in ''|*[!0-9]*) value=0 ;; esac
  printf -v "$2" '%s' "$value"
}

# Print "<task>\t<size>" for every status log whose size differs from its
# saved offset, using one wc call for the whole state directory.
grown_logs() {
  local -a logs=()
  local f size path id saved
  for f in "$STATE"/*.status; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    id=${f##*/}
    task_ok "${id%.status}" || continue
    logs+=("$f")
  done
  [ "${#logs[@]}" -gt 0 ] || return 0
  wc -c -- "${logs[@]}" 2>/dev/null | while read -r size path; do
    case "$path" in "$STATE"/*.status) ;; *) continue ;; esac
    id=${path##*/}
    id=${id%.status}
    read_offset "$id" saved
    [ "$size" = "$saved" ] || printf '%s\t%s\n' "$id" "$size"
  done
}

LIBS_LOADED=0
load_libs() {
  [ "$LIBS_LOADED" = 1 ] && return 0
  # shellcheck source=bin/fm-producer-identity-lib.sh
  . "$SCRIPT_DIR/fm-producer-identity-lib.sh" || return 1
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh" || return 1
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SCRIPT_DIR/fm-classify-lib.sh" || return 1
  LIBS_LOADED=1
}

read_counter() { # <file> <out-var>: a saved counter, 0 when absent or malformed
  local value=0
  { IFS= read -r value < "$1"; } 2>/dev/null || value=0
  case "$value" in ''|*[!0-9]*) value=0 ;; esac
  printf -v "$2" '%s' "$value"
}

save_counter() { # <file> <value>
  { printf '%s\n' "$2" > "$1.tmp" && mv -f "$1.tmp" "$1"; } 2>/dev/null
}

# The envelope's source member and the last sequence number, loaded once per
# run under the lock.
LEDGER_SOURCE=''
LEDGER_SEQ=''
envelope_ready() {
  local last
  [ -z "$LEDGER_SOURCE" ] || return 0
  fm_producer_identity_load "$STATE" || return 1
  # A worker's own status command runs appended; it is never a supervisor actor.
  [ "$cmd" != appended ] || FM_PRODUCER_ACTOR=worker
  LEDGER_SOURCE=$(fm_producer_source_json fm-fleet-ledger) || { LEDGER_SOURCE=''; return 1; }
  read_counter "$SEQ_FILE" LEDGER_SEQ
  last=$(tail -n 1 "$LEDGER" 2>/dev/null | jq -r '.seq // 0' 2>/dev/null) || last=0
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ "$last" -le "$LEDGER_SEQ" ] || LEDGER_SEQ=$last
}

# append <event> <task> <jq-object-of-extra-members> [jq --arg pairs...]
append() {
  local event=$1 task=$2 extra=$3 line seq rev binding
  shift 3
  envelope_ready || return 1
  seq=$((LEDGER_SEQ + 1))
  read_counter "$(rev_path "$task")" rev
  rev=$((rev + 1))
  binding=$(fm_producer_binding_json "$STATE" "$task") || return 1
  line=$(jq -cn --arg event "$event" --arg task "$task" --argjson seq "$seq" --argjson rev "$rev" \
    --argjson source "$LEDGER_SOURCE" --argjson binding "$binding" "$@" \
    "def n: if . == \"\" then null else . end;
     {v: 1, ts: (now | floor), event: \$event, task: \$task,
      event_id: (\$source.scope_id + \":\" + (\$seq | tostring)), seq: \$seq, task_rev: \$rev,
      source: \$source, binding: \$binding} + ($extra)") \
    || return 1
  printf '%s\n' "$line" >> "$LEDGER" || return 1
  LEDGER_SEQ=$seq
  save_counter "$SEQ_FILE" "$seq" || true
  save_counter "$(rev_path "$task")" "$rev" || true
}

# The status-line grammar belongs to bin/fm-classify-lib.sh; this only projects it.
append_status() { # <task> <status-line>
  local task=$1 line=$2 verb key text
  status_line_verb "$line" verb
  case "$verb" in [a-z]*) case "$verb" in *[!a-z-]*) verb='' ;; esac ;; *) verb='' ;; esac
  key=$(_fm_decision_key "$line" 2>/dev/null) || key=''
  [ "$key" != default ] || key=''
  text=${line#*:}
  append task.status "$task" \
    "{state: (\$state | n), key: (\$key | n), text: \$text[0:$TEXT_MAX_CHARS]}" \
    --arg state "$verb" --arg key "$key" --arg text "$text" || return 1
  [ -n "$verb" ] || return 0
  if [ "$verb" != resolved ]; then
    announce_started "$task" status || [ "$?" -eq 3 ] || return 1
  fi
  append_derived "$task" "$verb" "$key" "$text"
}

# task.started once per worker incarnation; <signal> is status or pane.
# Returns 3 when the incarnation was already announced.
# shellcheck disable=SC2016 # $names in the filter are jq variables.
announce_started() { # <task> <signal>
  local task=$1 gen seen=''
  gen=$(meta_field "$task" spawn_gen)
  { IFS= read -r seen < "$(started_path "$task")"; } 2>/dev/null || seen=''
  [ "$seen" != "${gen:--}" ] || return 3
  append task.started "$task" '{signal: $signal, spawn_gen: ($gen | n)}' \
    --arg signal "$2" --arg gen "$gen" || return 1
  printf '%s\n' "${gen:--}" > "$(started_path "$task")"
}

# The semantic projection of one status line (see the header).
# shellcheck disable=SC2016 # $names in the filters are jq variables.
append_derived() { # <task> <verb> <key> <text>
  local task=$1 verb=$2 key=$3 text=$4 wait pr='' report digest
  case "$verb" in
    working)
      append task.heartbeat "$task" "{signal: \"status\", text: \$text[0:$TEXT_MAX_CHARS]}" --arg text "$text"
      ;;
    paused|blocked|needs-decision)
      case "$verb" in paused) wait=dependency ;; blocked) wait=blocker ;; *) wait=decision ;; esac
      append task.blocked "$task" "{wait: \$wait, state: \$state, key: (\$key | n), text: \$text[0:$TEXT_MAX_CHARS]}" \
        --arg wait "$wait" --arg state "$verb" --arg key "$key" --arg text "$text"
      ;;
    done|failed)
      [[ $text =~ (https?://[^[:space:]]+/(pull|merge_requests)/[0-9]+) ]] && pr=${BASH_REMATCH[1]}
      append task.finished "$task" "{outcome: \$outcome, pr: (\$pr | n), text: \$text[0:$TEXT_MAX_CHARS]}" \
        --arg outcome "$verb" --arg pr "$pr" --arg text "$text" || return 1
      [ "$verb" = "done" ] && [ "$(meta_field "$task" kind)" = scout ] || return 0
      report="$DATA/$task/report.md"
      [ -f "$report" ] && [ ! -L "$report" ] || return 0
      digest=$(sha256_of "$report") || return 0
      append task.verified_outcome "$task" \
        '{outcome: "report", checker: "fm-fleet-ledger", evidence: {report: $report, sha256: $sha}}' \
        --arg report "data/$task/report.md" --arg sha "$digest"
      ;;
  esac
}

capture_task() { # <task>; caller holds the lock
  local task=$1 log offset data complete tail line saved
  log="$STATE/$task.status"
  saved=$(offset_path "$task")
  [ -f "$log" ] && [ ! -L "$log" ] || return 0
  read_offset "$task" offset
  data=$(wc -c < "$log") || return 1
  data=${data//[[:space:]]/}
  [ "$data" -ge "$offset" ] || offset=0
  [ "$data" -gt "$offset" ] || return 0
  # The trailing x keeps a final newline that command substitution would strip.
  data=$(tail -c "+$((offset + 1))" "$log"; printf x) || return 1
  data=${data%x}
  tail=${data##*$'\n'}
  complete=${data%"$tail"}
  [ -n "$complete" ] || return 0
  while IFS= read -r line; do
    [ -n "${line//[[:space:]]/}" ] || continue
    append_status "$task" "$line" || return 1
  done <<< "${complete%$'\n'}"
  offset=$((offset + ${#complete}))
  printf '%s\n' "$offset" > "$saved.tmp" && mv -f "$saved.tmp" "$saved"
}

if [ "$cmd" = capture ]; then
  grown=$(grown_logs) || exit 1
  [ -n "$grown" ] || exit 0
fi

load_libs || exit 1
fm_lock_acquire_wait "$LOCK" || exit 1
trap 'fm_lock_release "$LOCK"' EXIT
rc=0
# shellcheck disable=SC2016 # $names below are jq variables, not shell ones.
case "$cmd" in
  capture)
    while IFS=$'\t' read -r task _; do
      capture_task "$task" || rc=1
    done <<< "$grown"
    ;;
  appended)
    capture_task "$APPENDED_TASK" || rc=1
    ;;
  dispatched)
    rm -f -- "$(offset_path "$2")" "$(started_path "$2")" "$(rev_path "$2")"
    append task.dispatched "$2" \
      '{kind: ($kind | n), project: ($project | n), harness: ($harness | n), model: ($model | n)}' \
      --arg kind "$3" --arg project "$4" --arg harness "$5" --arg model "$6" || rc=1
    ;;
  pr_ready)
    capture_task "$2" || rc=1
    append task.pr_ready "$2" '{pr: $pr}' --arg pr "$3" || rc=1
    append task.verified_outcome "$2" \
      '{outcome: "pr_ready", checker: "fm-pr-check", evidence: {pr: $pr, head: ($head | n)}}' \
      --arg pr "$3" --arg head "$(meta_field "$2" pr_head)" || rc=1
    ;;
  merged)
    capture_task "$2" || rc=1
    if [ "$3" = pr ]; then
      append task.merged "$2" '{via: "pr", pr: $pr}' --arg pr "$4" || rc=1
      append task.verified_outcome "$2" \
        '{outcome: "merged", checker: "fm-merge-outcome", evidence: {via: "pr", pr: $pr}}' \
        --arg pr "$4" || rc=1
    else
      append task.merged "$2" '{via: "local"}' || rc=1
      append task.verified_outcome "$2" \
        '{outcome: "merged", checker: "fm-merge-local", evidence: {via: "local", head: ($head | n)}}' \
        --arg head "$(meta_field "$2" local_done_head)" || rc=1
    fi
    ;;
  activity)
    capture_task "$2" || rc=1
    announce_started "$2" pane || case "$?" in
      3) append task.heartbeat "$2" '{signal: "pane", text: null}' || rc=1 ;;
      *) rc=1 ;;
    esac
    ;;
  stalled)
    capture_task "$2" || rc=1
    append task.stalled "$2" "{reason: \$reason[0:$TEXT_MAX_CHARS]}" --arg reason "$3" || rc=1
    ;;
  cleaned_up)
    capture_task "$2" || rc=1
    append task.cleaned_up "$2" '{}' || rc=1
    [ "$rc" -ne 0 ] || rm -f -- "$(offset_path "$2")" "$(started_path "$2")" "$(rev_path "$2")"
    ;;
esac
[ "$rc" -eq 0 ] || echo "fm-fleet-ledger: could not record $cmd${2:+ for $2}; the ledger may be missing records" >&2
exit "$rc"
