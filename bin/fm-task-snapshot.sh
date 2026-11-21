#!/usr/bin/env bash
# fm-task-snapshot.sh - one machine-readable snapshot of a task's supervision
# state, for tools outside the worker's terminal.
#
# Usage:
#   fm-task-snapshot.sh <task>... [--probe-composer]
#   fm-task-snapshot.sh --all [--probe-composer]
#
# Prints one JSON object per task, one per line, in the schema
# docs/supervision-events.md "Task snapshot" owns. It is read-only: it writes
# nothing under the home except creating state/producer-identity.json when it
# is absent (bin/fm-producer-identity-lib.sh), makes no network call, and
# starts nothing. --probe-composer adds one fresh read of each task's input
# line through the runtime's own read-only classifier (bin/fm-backend.sh
# fm_backend_composer_state); without it, the input-line reading is the last
# one a delivery attempt took. --all covers every state/<task>.meta.
#
# It never reads a runtime's visibility or orphaned-layout flags: a hidden or
# orphaned terminal says nothing about whether its worker is alive.
#
# Exit status: 0 when every named task was printed, 1 when a named task has no
# meta or the producer identity cannot be loaded, 2 on a usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export FM_CONFIG_OVERRIDE="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

usage() {
  echo "usage: fm-task-snapshot.sh <task>... [--probe-composer] | --all [--probe-composer]" >&2
  exit 2
}

PROBE=0
ALL=0
TASKS=()
for arg in "$@"; do
  case "$arg" in
    --probe-composer) PROBE=1 ;;
    --all) ALL=1 ;;
    -*) usage ;;
    *)
      case "$arg" in .*|*[!A-Za-z0-9._-]*) usage ;; esac
      TASKS+=("$arg")
      ;;
  esac
done
if [ "$ALL" = 1 ]; then
  [ "${#TASKS[@]}" -eq 0 ] || usage
  for f in "$STATE"/*.meta; do
    [ -f "$f" ] || continue
    t=${f##*/}
    t=${t%.meta}
    case "$t" in .*|*[!A-Za-z0-9._-]*) continue ;; esac
    TASKS+=("$t")
  done
  [ "${#TASKS[@]}" -gt 0 ] || exit 0
fi
[ "${#TASKS[@]}" -gt 0 ] || usage

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh" || exit 1
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh" || exit 1
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh" || exit 1
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh" || exit 1
# shellcheck source=bin/fm-producer-identity-lib.sh
. "$SCRIPT_DIR/fm-producer-identity-lib.sh" || exit 1
if [ "$PROBE" = 1 ]; then
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh" || exit 1
fi

fm_producer_identity_load "$STATE" || { echo "fm-task-snapshot: cannot load the producer identity in $STATE" >&2; exit 1; }
SOURCE=$(fm_producer_source_json fm-task-snapshot) || exit 1

meta_value() {  # <task> <key>: last value in the task's meta, or empty
  local line value=''
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) value=${line#*=} ;; esac
  done < "$STATE/$1.meta" 2>/dev/null
  printf '%s' "$value"
}

# The human gates still open in <status-file>, as a JSON array.
human_gates_json() {  # <status-file> <kind>
  local key verb note out='[]'
  while IFS=$'\t' read -r key verb note; do
    [ -n "$key" ] && [ -n "$verb" ] || continue
    # shellcheck disable=SC2016 # $names are jq variables.
    out=$(jq -c --arg key "$key" --arg verb "$verb" --arg note "$note" \
      '. + [{key: $key, wait: (if $verb == "blocked" then "blocker" else "decision" end), state: $verb, text: $note[0:2000]}]' \
      <<< "$out") || return 1
  done <<EOF
$(status_open_decisions "$1" "$2")
EOF
  printf '%s' "$out"
}

# shellcheck disable=SC2016 # $names in the filter are jq variables.
snapshot() {  # <task>
  local task=$1 meta status kind current='' cverb='' ckey='' last='' lverb='' lat='' mtime=''
  local wait='' wverb='' until='' gates lease='null' inbox dir f b n queued=0 oldest='' oldest_n=0
  local oldest_at='' ring_msg='' ring_result='' ring_at='' comp='' comp_at='' live_ts='' dialog=''
  local beat='' guard probe='' backend target binding working_at='' receipt='{}' odelivery='' project
  local ordinary='' ordinary_at=''
  meta="$STATE/$task.meta"
  [ -f "$meta" ] || { echo "fm-task-snapshot: no meta for $task" >&2; return 1; }
  status="$STATE/$task.status"
  kind=$(meta_value "$task" kind)
  if [ -f "$status" ]; then
    current=$(status_current_line "$status" "$kind" 2>/dev/null) || current=''
    [ -z "$current" ] || status_line_verb "$current" cverb
    ckey=$(_fm_decision_key "$current" '' 2>/dev/null) || ckey=''
    last=$(last_status_line "$status" 2>/dev/null) || last=''
    [ -z "$last" ] || status_line_verb "$last" lverb
    lat=$(status_line_at_epoch "$last" 2>/dev/null) || lat=''
    mtime=$(_fm_status_file_mtime "$status") || mtime=''
    wait=$(status_declared_wait_line "$status" 2>/dev/null) || wait=''
    if [ -n "$wait" ]; then
      status_line_verb "$wait" wverb
      until=$(status_paused_until "$wait" 2>/dev/null) || until=''
    fi
    gates=$(human_gates_json "$status" "$kind") || gates='[]'
    working_at=$(grep -E '^[[:space:]]*working([[:space:]]|:)' "$status" 2>/dev/null | tail -n 1)
    working_at=$(status_line_at_epoch "$working_at" 2>/dev/null) || working_at=''
  else
    gates='[]'
  fi
  if fm_lease_read "$task" 2>/dev/null; then
    lease=$(jq -cn --arg actor "$FM_LEASE_ACTOR" --arg pid "$FM_LEASE_PID" --arg epoch "$FM_LEASE_EPOCH" \
      '{actor: (if $actor == "" then null else $actor end), pid: (if $pid == "" then null else $pid end),
        epoch: ($epoch | tonumber? // null)}')
  fi
  dir="$STATE/$task.inbox"
  for f in "$dir"/*.msg; do
    [ -f "$f" ] || continue
    b=${f##*/}
    n=${b%.msg}
    case "$n" in ''|*[!0-9]*) continue ;; esac
    queued=$((queued + 1))
    if [ -z "$oldest" ] || [ "$((10#$n))" -lt "$oldest_n" ]; then
      oldest=$b
      oldest_n=$((10#$n))
    fi
  done
  if [ -n "$oldest" ]; then
    oldest_at=$(sed -n 's/^at=//p; /^--$/q' "$dir/$oldest" 2>/dev/null | head -n 1)
    if sed -n '/^--$/q; p' "$dir/$oldest" 2>/dev/null | grep -qx 'delivery=fire-and-forget'; then
      odelivery=fire-and-forget
    else
      odelivery=ordinary
    fi
    oldest_at=$(fm_utc_iso_to_epoch "$oldest_at" 2>/dev/null) || oldest_at=''
  fi
  if ordinary=$(fm_task_inbox_oldest_unhandled "$STATE" "$task" 2>/dev/null); then
    ordinary_at=$(sed -n 's/^at=//p; /^--$/q' "$ordinary" 2>/dev/null | head -n 1)
    ordinary_at=$(fm_utc_iso_to_epoch "$ordinary_at" 2>/dev/null) || ordinary_at=''
    ordinary=${ordinary##*/}
  else
    ordinary=''
  fi
  { IFS=$'\t' read -r ring_msg ring_result ring_at < "$dir/.last-ring"; } 2>/dev/null || ring_msg=''
  { IFS=$'\t' read -r comp comp_at < "$dir/.composer"; } 2>/dev/null || comp=''
  guard=$(fm_task_inbox_draft_guard "$dir/000.msg")
  if [ -s "$dir/receipts.jsonl" ]; then
    receipt=$(tail -n 1 "$dir/receipts.jsonl" | jq -c '{msg, receipt, ts}' 2>/dev/null) || receipt='{}'
    [ -n "$receipt" ] || receipt='{}'
  fi
  if [ -f "$STATE/$task.live.json" ]; then
    live_ts=$(jq -r '.ts // empty' "$STATE/$task.live.json" 2>/dev/null) || live_ts=''
    dialog=$(jq -r '.dialog.state // empty' "$STATE/$task.live.json" 2>/dev/null) || dialog=''
  fi
  { IFS= read -r beat < "$STATE/.$task.fleet-ledger-beat"; } 2>/dev/null || beat=''
  backend=$(meta_value "$task" backend)
  if [ "$PROBE" = 1 ]; then
    target=$(fm_backend_target_of_meta "$meta")
    if [ -n "$target" ]; then
      probe=$(fm_backend_composer_state "$(fm_backend_of_meta "$meta")" "$target" "fm-$task" 2>/dev/null) || probe=unknown
      case "$probe" in empty|pending|pending-unproven) ;; *) probe=unknown ;; esac
    fi
  fi
  binding=$(fm_producer_binding_json "$STATE" "$task") || return 1
  project=$(meta_value "$task" project)
  project=${project%/}
  project=${project##*/}
  inbox=$(jq -cn --argjson queued "$queued" --arg oldest "$oldest" --arg oldest_at "$oldest_at" \
    --arg rmsg "$ring_msg" --arg rres "$ring_result" --arg rat "$ring_at" \
    --arg comp "$comp" --arg comp_at "$comp_at" --arg probe "$probe" --arg guard "$guard" --arg odelivery "$odelivery" \
    --arg ordinary "$ordinary" --arg ordinary_at "$ordinary_at" '
    def n: if . == "" then null else . end;
    {queued: $queued, oldest: ($oldest | n), oldest_queued_at: ($oldest_at | tonumber? // null),
     oldest_delivery: ($odelivery | n),
     oldest_ordinary: ($ordinary | n), oldest_ordinary_queued_at: ($ordinary_at | tonumber? // null),
     last_delivery: (if $rmsg == "" then null else {msg: $rmsg, result: $rres, at: ($rat | tonumber? // null)} end),
     composer: (if $probe != "" then {state: $probe, at: (now | floor), probed: true}
                elif $comp != "" then {state: $comp, at: ($comp_at | tonumber? // null), probed: false}
                else null end),
     draft_guard: $guard}') || return 1
  jq -cn --arg task "$task" --argjson source "$SOURCE" --argjson binding "$binding" \
    --argjson lease "$lease" --argjson inbox "$inbox" --argjson gates "$gates" --argjson receipt "$receipt" \
    --arg kind "$kind" --arg project "$project" --arg mode "$(meta_value "$task" mode)" \
    --arg yolo "$(meta_value "$task" yolo)" --arg approval "$(meta_value "$task" approval_mode)" \
    --arg current "$current" --arg cverb "$cverb" --arg ckey "$ckey" \
    --arg lverb "$lverb" --arg lat "$lat" --arg mtime "$mtime" \
    --arg wverb "$wverb" --arg wait "$wait" --arg until "$until" \
    --arg live_ts "$live_ts" --arg dialog "$dialog" --arg beat "$beat" --arg backend "$backend" \
    --arg working_at "$working_at" '
    def n: if . == "" then null else . end;
    def num: tonumber? // null;
    {v: 1, ts: (now | floor), task: $task, source: $source, binding: $binding,
     ownership: {scope_id: $source.scope_id, lease: $lease},
     authorization: {kind: ($kind | n), project: ($project | n), mode: ($mode | n),
                     yolo: ($yolo | n), approval_mode: ($approval | n)},
     queue: $inbox,
     state: (if $current == "" then null
             else {state: ($cverb | n), key: ($ckey | n), text: ($current | sub("^[^:]*:"; ""))[0:2000]} end),
     progress: {last_working_at: ($working_at | num),
                last_status_state: ($lverb | n), last_status_at: ($lat | num),
                status_log_mtime: ($mtime | num), screen_beat_at: ($beat | num),
                last_receipt: (if $receipt.msg == null then null else $receipt end),
                live_ts: ($live_ts | num)},
     waits: {dependency: (if $wverb == "" then null
                          else {state: $wverb, until: ($until | num), text: ($wait | sub("^[^:]*:"; ""))[0:2000]} end),
             human_gates: $gates,
             dialog: ($dialog | n)},
     capabilities: {composer_readable: (if $inbox.composer == null then null
                                        else ($inbox.composer.state == "empty" or $inbox.composer.state == "pending") end),
                    dialog_readable: (if $dialog == "" then null else ($dialog != "not-read") end),
                    endpoint_recorded: ($binding.endpoint != null or $binding.native != null),
                    backend: ($backend | n),
                    strict_draft_guard: ($inbox.draft_guard == "strict")}}'
}

rc=0
for t in "${TASKS[@]}"; do
  snapshot "$t" || rc=1
done
exit "$rc"
