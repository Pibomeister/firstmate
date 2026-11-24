#!/usr/bin/env bash
# fm-delegated.sh - the delegated-agent progress contract (tickets 3a and 9b).
#
# Usage: FM_HOME=<home> fm-delegated.sh <command> [flags]
#   register --task <id> --deliverable <name> --artifact <path>
#            --heartbeat-secs <n> --silence-secs <n> [--supervisor <name>]
#                                 Record one delegated overnight task. The
#                                 deliverable is a single token name; the
#                                 silence window must exceed the heartbeat.
#   dispatch --task <id>         Record a dispatch-only receipt. This is
#                                 never progress on its own.
#   heartbeat --task <id>        Record a progress heartbeat now.
#   deliver --task <id> --path <path> --hash <sha256>
#                                 Attempt to close the deliverable with an
#                                 artifact receipt. A missing artifact or a
#                                 hash mismatch records the attempt, leaves
#                                 the deliverable open, and exits 1.
#   view [--task <id>]           The supervisor view: one line per task with
#                                 its state, plus one line per handoff. A
#                                 task with only a dispatch receipt renders
#                                 as state=dispatched-not-progressing.
#   check                        One supervision pass. A task silent past
#                                 its silence window produces exactly one
#                                 escalation naming task, age, and last
#                                 receipt. A handoff filed only outside the
#                                 receiver's read location produces a
#                                 delivery-failure line naming the hidden
#                                 item on every pass until it is mirrored.
#   handoff --task <task> --id <id> --receiver <id> --path <path> --hash <sha256>
#           [--read-dir <receiver-channel-dir>] --alt-dir <abs-dir.inbox>
#           --location read|alt
#                                 File one cross-agent handoff carrying the
#                                 artifact receipt (path plus hash) in the
#                                 chosen location.
#   mirror --id <id>             Mirror a hidden handoff into the read
#                                 location its receiver actually reads.
#
#   receipt --receiver <id>     Persist verified consumption before cleanup.
#
# Files, all under the owner home FM_HOME:
#   state/delegated/<task>.record       one key=value record per task.
#   state/delegated/handoffs/<id>.record one key=value record per handoff.
#   Firstmate reads the wake queue; other receivers read NNN.msg and handled/.
#   <alt-dir>/NNN.msg holds a non-read placement until mirrored.
#
# This command never instructs, pushes, restarts, or stops any external
# agent. Escalation and delivery failure are reports to the delegating
# supervisor only.
#
# Test seam, honoured only with FM_TEST_SEAM=1: FM_DELEGATED_NOW fixes the
# clock.
#
# Exit status: 0 on success, 1 on a refused or failed receipt, 2 on usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DELEGATED_DIR="$STATE/delegated"
HANDOFF_DIR="$DELEGATED_DIR/handoffs"

# shellcheck source=bin/fm-delegated-lib.sh
. "$SCRIPT_DIR/fm-delegated-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() { printf 'fm-delegated: %s\n' "$*" >&2; exit 1; }
usage_die() { printf 'fm-delegated: %s\n' "$*" >&2; exit 2; }

now_epoch() { fm_del_now; }

valid_secs() {  # <value>
  case "$1" in ''|*[!0-9]*|0) return 1 ;; esac
  [ "${#1}" -le 10 ]
}

single_line() {  # <value>: no tab or newline
  case "$1" in *"$tab"*|*$'\n'*|*$'\r'*) return 1 ;; esac
  return 0
}
tab=$(printf '\t')

task_file() { printf '%s/%s.record' "$DELEGATED_DIR" "$1"; }
handoff_file() { printf '%s/%s.record' "$HANDOFF_DIR" "$1"; }

require_task() {  # <id>: fills T_FILE or dies
  fm_del_valid_id "$1" || die "invalid task id: $1"
  T_FILE=$(task_file "$1")
  [ -f "$T_FILE" ] || die "no delegated task recorded: $1"
}

load_task() {  # <file>
  T_TASK=$(fm_del_record_get "$1" task)
  T_DELIVERABLE=$(fm_del_record_get "$1" deliverable)
  T_ARTIFACT=$(fm_del_record_get "$1" artifact_path)
  T_HEARTBEAT=$(fm_del_record_get "$1" heartbeat_secs)
  T_SILENCE=$(fm_del_record_get "$1" silence_secs)
  T_SUPERVISOR=$(fm_del_record_get "$1" supervisor)
  T_REGISTERED=$(fm_del_record_get "$1" registered_at)
  T_DISPATCHED=$(fm_del_record_get "$1" dispatched_at)
  T_LAST_KIND=$(fm_del_record_get "$1" last_receipt_kind)
  T_LAST_AT=$(fm_del_record_get "$1" last_receipt_at)
  T_LAST_PATH=$(fm_del_record_get "$1" last_receipt_path)
  T_LAST_HASH=$(fm_del_record_get "$1" last_receipt_hash)
  T_HAS_PROGRESS=$(fm_del_record_get "$1" has_progress)
  T_CLOSED=$(fm_del_record_get "$1" closed)
  T_CLOSED_AT=$(fm_del_record_get "$1" closed_at)
  T_ESCALATED=$(fm_del_record_get "$1" escalated_at)
  T_ATTEMPT=$(fm_del_record_get "$1" last_attempt)
  [ -n "$T_HAS_PROGRESS" ] || T_HAS_PROGRESS=0
  [ -n "$T_CLOSED" ] || T_CLOSED=0
}

save_task() {  # <file>
  local tmp
  tmp=$(mktemp "${1%/*}/.record.XXXXXX") || return 1
  {
    printf 'task=%s\n' "$T_TASK"
    printf 'deliverable=%s\n' "$T_DELIVERABLE"
    printf 'artifact_path=%s\n' "$T_ARTIFACT"
    printf 'heartbeat_secs=%s\n' "$T_HEARTBEAT"
    printf 'silence_secs=%s\n' "$T_SILENCE"
    printf 'supervisor=%s\n' "$T_SUPERVISOR"
    printf 'registered_at=%s\n' "$T_REGISTERED"
    printf 'dispatched_at=%s\n' "$T_DISPATCHED"
    printf 'last_receipt_kind=%s\n' "$T_LAST_KIND"
    printf 'last_receipt_at=%s\n' "$T_LAST_AT"
    printf 'last_receipt_path=%s\n' "$T_LAST_PATH"
    printf 'last_receipt_hash=%s\n' "$T_LAST_HASH"
    printf 'has_progress=%s\n' "$T_HAS_PROGRESS"
    printf 'closed=%s\n' "$T_CLOSED"
    printf 'closed_at=%s\n' "$T_CLOSED_AT"
    printf 'escalated_at=%s\n' "$T_ESCALATED"
    printf 'last_attempt=%s\n' "$T_ATTEMPT"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$1" || { rm -f "$tmp"; return 1; }
}

last_activity() {  # prints newest of registered/dispatched/last-receipt epochs
  local best=0 v
  for v in "$T_REGISTERED" "$T_DISPATCHED" "$T_LAST_AT"; do
    case "$v" in ''|*[!0-9]*) continue ;; esac
    [ "$v" -gt "$best" ] && best=$v
  done
  printf '%s' "$best"
}

last_receipt_label() {
  if [ -n "$T_LAST_KIND" ] && [ -n "$T_LAST_AT" ]; then
    printf '%s@%s' "$T_LAST_KIND" "$T_LAST_AT"
  else
    printf 'none'
  fi
}

load_handoff() {  # <file>
  H_TASK=$(fm_del_record_get "$1" task)
  H_FILE=$1
  H_READ_RECEIPT=$(fm_del_record_get "$1" read_receipt)
  H_MESSAGE=$(fm_del_record_get "$1" message)
  H_ID=$(fm_del_record_get "$1" id)
  H_RECEIVER=$(fm_del_record_get "$1" receiver)
  H_PATH=$(fm_del_record_get "$1" artifact_path)
  H_HASH=$(fm_del_record_get "$1" artifact_hash)
  H_READ_DIR=$(fm_del_record_get "$1" read_dir)
  H_ALT_DIR=$(fm_del_record_get "$1" alt_dir)
  H_LOCATION=$(fm_del_record_get "$1" location)
  H_MIRRORED=$(fm_del_record_get "$1" mirrored)
  [ -n "$H_MIRRORED" ] || H_MIRRORED=0
}

save_handoff() {  # <file>
  local tmp
  tmp=$(mktemp "${1%/*}/.record.XXXXXX") || return 1
  {
    printf 'task=%s\n' "$H_TASK"
    printf 'read_receipt=%s\n' "$H_READ_RECEIPT"
    printf 'message=%s\n' "$H_MESSAGE"
    printf 'id=%s\n' "$H_ID"
    printf 'receiver=%s\n' "$H_RECEIVER"
    printf 'artifact_path=%s\n' "$H_PATH"
    printf 'artifact_hash=%s\n' "$H_HASH"
    printf 'read_dir=%s\n' "$H_READ_DIR"
    printf 'alt_dir=%s\n' "$H_ALT_DIR"
    printf 'location=%s\n' "$H_LOCATION"
    printf 'mirrored=%s\n' "$H_MIRRORED"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$1" || { rm -f "$tmp"; return 1; }
}

handoff_body() {
  printf 'handoff=%s task=%s receiver=%s artifact=%s hash=%s' "$H_ID" "$H_TASK" "$H_RECEIVER" "$H_PATH" "$H_HASH"
}

handoff_state() {
  local pending="$H_READ_DIR/${H_MESSAGE##*/}" handled="$H_READ_DIR/handled/${H_MESSAGE##*/}" body
  H_STATE=delivery-failure
  if [ "$H_READ_RECEIPT" = "$H_PATH@$H_HASH" ]; then H_STATE=read; return; fi
  [ -n "$H_MESSAGE" ] && [ "$H_MIRRORED" = 1 ] || return 0
  if [ "$H_RECEIVER" = firstmate ]; then
    if [ -f "$FM_WAKE_QUEUE" ] && FM_DELEGATED_BODY="$(handoff_body)" awk -F '\t' -v key="$H_MESSAGE" \
      'BEGIN { body=ENVIRON["FM_DELEGATED_BODY"] } $4 == key && $5 == body { found=1 } END { exit !found }' "$FM_WAKE_QUEUE"; then
      H_STATE=mirrored
      return
    fi
    [ -f "$STATE/wake-ledger.tsv" ] || return 0
    awk -F '\t' -v key="\"$H_MESSAGE\"" \
      '($2 == "ack" || $2 == "consumed") && index($6, key) { found=1 } END { exit !found }' \
      "$STATE/wake-ledger.tsv" || return 0
  else
    fm_del_verify_artifact "$H_PATH" "$H_HASH" >/dev/null || return 0
    if body=$(fm_task_inbox_body "$pending" 2>/dev/null) && [ "$body" = "$(handoff_body)" ]; then
      H_STATE=mirrored
      return
    fi
    body=$(fm_task_inbox_body "$handled" 2>/dev/null) && [ "$body" = "$(handoff_body)" ] || return 0
  fi
  H_READ_RECEIPT="$H_PATH@$H_HASH"
  save_handoff "$H_FILE" || die "cannot record read receipt: $H_ID"
  H_STATE=read
}

write_placement() {
  local recipient=${1##*/}
  if [ "$1" = "$H_READ_DIR" ] && [ "$H_RECEIVER" = firstmate ]; then
    H_MESSAGE="delegated-handoff:$H_ID:$H_HASH"
    fm_wake_append check "$H_MESSAGE" "$(handoff_body)" || return 1
  else
    H_MESSAGE=$(fm_task_inbox_write_idempotent "${1%/*}" "${recipient%.inbox}" "$(handoff_body)") || return 1
  fi
}

cmd_receipt() {
  [ "$#" -eq 2 ] && [ "$1" = --receiver ] || usage_die 'receipt needs --receiver <id>'
  fm_del_valid_id "$2" || usage_die 'invalid receiver'
  local f
  for f in "$HANDOFF_DIR"/*.record; do
    [ -f "$f" ] || continue
    load_handoff "$f"
    [ "$H_RECEIVER" = "$2" ] || continue
    handoff_state
  done
}

closed_receipt() {
  printf 'closed task=%s deliverable=%s artifact=%s hash=%s\n' "$T_TASK" "$T_DELIVERABLE" "$T_LAST_PATH" "$T_LAST_HASH"
}

notify_supervisor() {
  local text=$1 key=$2
  fm_wake_append check "delegated:$T_SUPERVISOR:$key" "$text" || return 1
  if [ -f "$STATE/$T_SUPERVISOR.meta" ]; then
    fm_task_inbox_write_idempotent "$STATE" "$T_SUPERVISOR" "$text" >/dev/null || return 1
  fi
}

cmd_register() {
  local task='' deliverable='' artifact='' heartbeat='' silence='' supervisor='firstmate'
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) [ "$#" -ge 2 ] || usage_die '--task needs a value'; task=$2; shift 2 ;;
      --deliverable) [ "$#" -ge 2 ] || usage_die '--deliverable needs a value'; deliverable=$2; shift 2 ;;
      --artifact) [ "$#" -ge 2 ] || usage_die '--artifact needs a value'; artifact=$2; shift 2 ;;
      --heartbeat-secs) [ "$#" -ge 2 ] || usage_die '--heartbeat-secs needs a value'; heartbeat=$2; shift 2 ;;
      --silence-secs) [ "$#" -ge 2 ] || usage_die '--silence-secs needs a value'; silence=$2; shift 2 ;;
      --supervisor) [ "$#" -ge 2 ] || usage_die '--supervisor needs a value'; supervisor=$2; shift 2 ;;
      *) usage_die "unknown flag: $1" ;;
    esac
  done
  [ -n "$task" ] || usage_die 'register needs --task <id>'
  [ -n "$deliverable" ] || usage_die 'register needs --deliverable <name>'
  [ -n "$artifact" ] || usage_die 'register needs --artifact <path>'
  fm_del_valid_id "$task" || usage_die "invalid task id: $task"
  fm_del_valid_id "$deliverable" || usage_die "invalid deliverable name (one token of A-Za-z0-9._-): $deliverable"
  case "$artifact" in /*) ;; *) usage_die 'artifact path must be absolute' ;; esac
  single_line "$artifact" || usage_die 'artifact path must be one line'
  valid_secs "$heartbeat" || usage_die '--heartbeat-secs must be a positive integer'
  valid_secs "$silence" || usage_die '--silence-secs must be a positive integer'
  [ "$silence" -gt "$heartbeat" ] || usage_die '--silence-secs must exceed --heartbeat-secs'
  fm_del_valid_id "$supervisor" || usage_die "invalid supervisor name: $supervisor"
  mkdir -p "$DELEGATED_DIR" || die "cannot create $DELEGATED_DIR"
  T_FILE=$(task_file "$task")
  [ ! -f "$T_FILE" ] || die "delegated task already recorded: $task"
  T_TASK=$task T_DELIVERABLE=$deliverable T_ARTIFACT=$artifact
  T_HEARTBEAT=$heartbeat T_SILENCE=$silence T_SUPERVISOR=$supervisor
  T_REGISTERED=$(now_epoch) T_DISPATCHED='' T_LAST_KIND='' T_LAST_AT=''
  T_LAST_PATH='' T_LAST_HASH='' T_HAS_PROGRESS=0 T_CLOSED=0 T_CLOSED_AT=''
  T_ESCALATED='' T_ATTEMPT=''
  save_task "$T_FILE" || die "cannot record task: $task"
  printf 'registered task=%s deliverable=%s heartbeat_secs=%s silence_secs=%s\n' \
    "$task" "$deliverable" "$heartbeat" "$silence"
}

cmd_dispatch() {
  local task=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) [ "$#" -ge 2 ] || usage_die '--task needs a value'; task=$2; shift 2 ;;
      *) usage_die "unknown flag: $1" ;;
    esac
  done
  [ -n "$task" ] || usage_die 'dispatch needs --task <id>'
  require_task "$task"
  load_task "$T_FILE"
  if [ "$T_CLOSED" = 1 ]; then closed_receipt; return 0; fi
  T_DISPATCHED=$(now_epoch) T_LAST_KIND=dispatch T_LAST_AT=$T_DISPATCHED
  save_task "$T_FILE" || die "cannot record dispatch: $task"
  printf 'dispatched task=%s state=dispatched-not-progressing\n' "$task"
}

cmd_heartbeat() {
  local task=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) [ "$#" -ge 2 ] || usage_die '--task needs a value'; task=$2; shift 2 ;;
      *) usage_die "unknown flag: $1" ;;
    esac
  done
  [ -n "$task" ] || usage_die 'heartbeat needs --task <id>'
  require_task "$task"
  load_task "$T_FILE"
  if [ "$T_CLOSED" = 1 ]; then closed_receipt; return 0; fi
  T_LAST_KIND=heartbeat T_LAST_AT=$(now_epoch) T_HAS_PROGRESS=1
  save_task "$T_FILE" || die "cannot record heartbeat: $task"
  printf 'heartbeat task=%s state=progressing\n' "$task"
}

cmd_deliver() {
  local task='' path='' hash='' verdict lower
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) [ "$#" -ge 2 ] || usage_die '--task needs a value'; task=$2; shift 2 ;;
      --path) [ "$#" -ge 2 ] || usage_die '--path needs a value'; path=$2; shift 2 ;;
      --hash) [ "$#" -ge 2 ] || usage_die '--hash needs a value'; hash=$2; shift 2 ;;
      *) usage_die "unknown flag: $1" ;;
    esac
  done
  [ -n "$task" ] || usage_die 'deliver needs --task <id>'
  [ -n "$path" ] || usage_die 'deliver needs --path <path>'
  [ -n "$hash" ] || usage_die 'deliver needs --hash <sha256>'
  require_task "$task"
  load_task "$T_FILE"
  lower=$(printf '%s' "$hash" | tr '[:upper:]' '[:lower:]')
  if [ "$path" = "$T_ARTIFACT" ]; then
    verdict=$(fm_del_verify_artifact "$path" "$lower") || true
  else
    verdict=wrong-artifact
  fi
  T_ATTEMPT="deliverable:$verdict@$(now_epoch)"
  if [ "$verdict" = ok ]; then
    if [ "$T_CLOSED" = 1 ]; then closed_receipt; return 0; fi
    T_LAST_KIND=deliverable T_LAST_AT=$(now_epoch) T_LAST_PATH=$path T_LAST_HASH=$lower
    T_HAS_PROGRESS=1 T_CLOSED=1 T_CLOSED_AT=$T_LAST_AT
    save_task "$T_FILE" || die "cannot close task: $task"
    printf 'closed task=%s deliverable=%s artifact=%s hash=%s\n' "$task" "$T_DELIVERABLE" "$path" "$lower"
    return 0
  fi
  save_task "$T_FILE" || die "cannot record deliver attempt: $task"
  printf 'fm-delegated: deliverable not closed task=%s reason=%s artifact=%s\n' "$task" "$verdict" "$path" >&2
  exit 1
}

print_task_view() {  # <file>
  load_task "$1"
  printf 'task=%s state=%s deliverable=%s last_receipt=%s artifact=%s\n' \
    "$T_TASK" "$(fm_del_task_state "$T_CLOSED" "$T_HAS_PROGRESS" "$T_LAST_KIND" "$T_DISPATCHED")" \
    "$T_DELIVERABLE" "$(last_receipt_label)" "$T_ARTIFACT"
}

print_handoff_view() {  # <file>
  load_handoff "$1"
  handoff_state
  printf 'handoff=%s state=%s receiver=%s artifact=%s hash=%s\n' \
    "$H_ID" "$H_STATE" "$H_RECEIVER" "$H_PATH" "$H_HASH"
}

cmd_view() {
  local task='' f
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) [ "$#" -ge 2 ] || usage_die '--task needs a value'; task=$2; shift 2 ;;
      *) usage_die "unknown flag: $1" ;;
    esac
  done
  if [ -n "$task" ]; then
    require_task "$task"
    print_task_view "$T_FILE"
    return 0
  fi
  for f in "$DELEGATED_DIR"/*.record; do
    [ -f "$f" ] || continue
    print_task_view "$f"
  done
  for f in "$HANDOFF_DIR"/*.record; do
    [ -f "$f" ] || continue
    print_handoff_view "$f"
  done
}

cmd_check() {
  [ "$#" -eq 0 ] || usage_die 'check takes no flags'
  local f now age answered=' ' text
  now=$(now_epoch)
  for f in "$HANDOFF_DIR"/*.record; do
    [ -f "$f" ] || continue
    load_handoff "$f"
    answered="$answered$H_TASK "
    handoff_state
    [ "$H_STATE" = delivery-failure ] || continue
    load_task "$(task_file "$H_TASK")"
    text="delivery-failure handoff=$H_ID task=$H_TASK receiver=$H_RECEIVER artifact=$H_PATH hash=$H_HASH filed=$H_LOCATION read_dir=$H_READ_DIR"
    notify_supervisor "$text" "handoff:$H_ID" || die "cannot report handoff: $H_ID"
    printf '%s\n' "$text"
  done
  for f in "$DELEGATED_DIR"/*.record; do
    [ -f "$f" ] || continue
    load_task "$f"
    [ "$T_CLOSED" = 1 ] && continue
    case "$answered" in *" $T_TASK "*) continue ;; esac
    [ -n "$T_ESCALATED" ] && continue
    if age=$(fm_del_silence_age "$now" "$(last_activity)" "$T_SILENCE"); then
      text="escalation task=$T_TASK age=$age last_receipt=$(last_receipt_label) deliverable=$T_DELIVERABLE supervisor=$T_SUPERVISOR"
      notify_supervisor "$text" "silence:$T_TASK" || die "cannot report escalation: $T_TASK"
      T_ESCALATED=$now
      save_task "$f" || die "cannot record escalation: $T_TASK"
      printf '%s\n' "$text"
    fi
  done
}

cmd_handoff() {
  local task='' id='' receiver='' path='' hash='' read_dir='' alt_dir='' location='' lower verdict
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) [ "$#" -ge 2 ] || usage_die '--task needs a value'; task=$2; shift 2 ;;
      --id) [ "$#" -ge 2 ] || usage_die '--id needs a value'; id=$2; shift 2 ;;
      --receiver) [ "$#" -ge 2 ] || usage_die '--receiver needs a value'; receiver=$2; shift 2 ;;
      --path) [ "$#" -ge 2 ] || usage_die '--path needs a value'; path=$2; shift 2 ;;
      --hash) [ "$#" -ge 2 ] || usage_die '--hash needs a value'; hash=$2; shift 2 ;;
      --read-dir) [ "$#" -ge 2 ] || usage_die '--read-dir needs a value'; read_dir=$2; shift 2 ;;
      --alt-dir) [ "$#" -ge 2 ] || usage_die '--alt-dir needs a value'; alt_dir=$2; shift 2 ;;
      --location) [ "$#" -ge 2 ] || usage_die '--location needs a value'; location=$2; shift 2 ;;
      *) usage_die "unknown flag: $1" ;;
    esac
  done
  require_task "$task"
  load_task "$T_FILE"
  [ "$path" = "$T_ARTIFACT" ] || die 'handoff must name the registered artifact'
  local channel="$STATE/$receiver.inbox"
  if [ "$receiver" = firstmate ]; then
    channel=$STATE
  else
    [ -f "$STATE/$receiver.meta" ] || die "receiver has no task inbox consumer: $receiver"
  fi
  [ -n "$read_dir" ] || read_dir=$channel
  [ "$read_dir" = "$channel" ] || usage_die 'read-dir must name the receiver channel'
  single_line "$alt_dir" || usage_die 'alt-dir must be one line'
  case "$alt_dir" in *.inbox) ;; *) usage_die 'alt-dir must name an .inbox directory' ;; esac
  [ -n "$id" ] || usage_die 'handoff needs --id <id>'
  [ -n "$receiver" ] || usage_die 'handoff needs --receiver <id>'
  [ -n "$path" ] || usage_die 'handoff needs --path <path>'
  [ -n "$read_dir" ] || usage_die 'handoff needs --read-dir <abs-dir>'
  [ -n "$alt_dir" ] || usage_die 'handoff needs --alt-dir <abs-dir>'
  fm_del_valid_id "$id" || usage_die "invalid handoff id: $id"
  fm_del_valid_id "$receiver" || usage_die "invalid receiver id: $receiver"
  case "$read_dir" in /*) ;; *) usage_die '--read-dir must be an absolute path' ;; esac
  case "$alt_dir" in /*) ;; *) usage_die '--alt-dir must be an absolute path' ;; esac
  case "$location" in read|alt) ;; *) usage_die '--location must be read or alt' ;; esac
  lower=$(printf '%s' "$hash" | tr '[:upper:]' '[:lower:]')
  verdict=$(fm_del_verify_artifact "$path" "$lower") || true
  [ "$verdict" = ok ] || die "handoff artifact receipt does not verify: $verdict artifact=$path"
  mkdir -p "$HANDOFF_DIR" || die "cannot create $HANDOFF_DIR"
  H_FILE=$(handoff_file "$id")
  [ ! -f "$H_FILE" ] || die "handoff already recorded: $id"
  H_TASK=$task H_ID=$id H_RECEIVER=$receiver H_PATH=$path H_HASH=$lower
  H_READ_DIR=$read_dir H_ALT_DIR=$alt_dir H_LOCATION=$location H_MIRRORED=0 H_READ_RECEIPT=''
  if [ "$location" = read ]; then
    write_placement "$read_dir" || die "cannot file handoff: $id"
    H_MIRRORED=1
  else
    write_placement "$alt_dir" || die "cannot file handoff: $id"
  fi
  save_handoff "$H_FILE" || die "cannot record handoff: $id"
  if [ "$location" = read ]; then
    printf 'handoff=%s state=mirrored receiver=%s\n' "$id" "$receiver"
  else
    printf 'handoff=%s state=delivery-failure receiver=%s hidden=%s\n' "$id" "$receiver" "$id"
  fi
}

require_handoff() {  # <id>: fills H_FILE or dies
  fm_del_valid_id "$1" || die "invalid handoff id: $1"
  H_FILE=$(handoff_file "$1")
  [ -f "$H_FILE" ] || die "no handoff recorded: $1"
}

cmd_mirror() {
  local id=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --id) [ "$#" -ge 2 ] || usage_die '--id needs a value'; id=$2; shift 2 ;;
      *) usage_die "unknown flag: $1" ;;
    esac
  done
  [ -n "$id" ] || usage_die 'mirror needs --id <id>'
  require_handoff "$id"
  load_handoff "$H_FILE"
  handoff_state
  if [ "$H_STATE" = read ]; then
    printf 'handoff=%s state=read receiver=%s\n' "$id" "$H_RECEIVER"
    return 0
  fi
  fm_del_verify_artifact "$H_PATH" "$H_HASH" >/dev/null || die "handoff artifact no longer verifies: $id"
  if [ "$H_STATE" = delivery-failure ]; then
    write_placement "$H_READ_DIR" || die "cannot mirror handoff: $id"
  fi
  H_MIRRORED=1 H_LOCATION=read
  save_handoff "$H_FILE" || die "cannot record mirror: $id"
  printf 'handoff=%s state=mirrored receiver=%s\n' "$id" "$H_RECEIVER"
}

case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
esac
mkdir -p "$DELEGATED_DIR" || die 'cannot create delegated state'
DELEGATED_LOCK="$DELEGATED_DIR/.transaction.lock"
fm_lock_acquire_wait_max "$DELEGATED_LOCK" 60 || die 'delegated state is busy'
trap 'fm_lock_release "$DELEGATED_LOCK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

case "${1:-}" in
  register) shift; cmd_register "$@" ;;
  dispatch) shift; cmd_dispatch "$@" ;;
  heartbeat) shift; cmd_heartbeat "$@" ;;
  deliver) shift; cmd_deliver "$@" ;;
  view) shift; cmd_view "$@" ;;
  check) shift; cmd_check "$@" ;;
  handoff) shift; cmd_handoff "$@" ;;
  mirror) shift; cmd_mirror "$@" ;;
  receipt) shift; cmd_receipt "$@" ;;
  *) usage >&2; exit 2 ;;
esac
