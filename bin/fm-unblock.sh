#!/usr/bin/env bash
# fm-unblock.sh - the auto-unblocker's decision step, in dry run only.
#
# Usage:
#   fm-unblock.sh plan [--probe-composer]      decide and print; write nothing
#   fm-unblock.sh observe [--probe-composer]   decide, claim each new candidate
#                                              once, and record it
#   fm-unblock.sh enforce                      always refused in this version
#
# It is a command firstmate runs, never a daemon, and it acts on nothing: no
# message is rung, no worker is started, and nothing is dispatched. It reads
# each task through bin/fm-task-snapshot.sh and the backlog through
# `bin/fm-ledger.sh next`, and prints one JSON decision per stall, one per line,
# in the schema docs/supervision-events.md "Unblocker" owns.
#
# The only actions it can name are:
#   resume    ring the doorbell again, under the strict draft guard, for the
#             oldest unacknowledged ordinary steering message of a task that is
#             stalled on it
#   dispatch  start the highest-priority ready backlog item, which is already
#             filed and therefore already authorized
# It never names an approval, merge, deploy, spend, account, authentication,
# permission, restart, kill, or shell command. It never reads heartbeat age, a
# runtime's visibility or orphaned-layout flags, or any other liveness guess:
# a quiet worker is not a stalled one, and a stale heartbeat alone is no reason
# to act.
#
# A resume stall is a task whose oldest ordinary message (the snapshot's
# queue.oldest_ordinary, which skips fire-and-forget records) has waited at least
# FM_UNBLOCK_STALL_SECS (default 900) since it was accepted. It is a candidate
# only when every one of these holds; otherwise it is a hold with the first
# failing reason:
#   - the task has not reported done or failed, has no open decision or
#     blocker, and declares no wait;
#   - the last screen read shows no dialog that needs an answer;
#   - the task records a spawn generation, which bounds the action's epoch;
#   - the last delivery of that same message is not ambiguous: a doorbell that
#     rang without pickup, a send that failed, an input line that could not be
#     read, or a gone endpoint is never repeated blindly;
#   - the input line reads empty, from a reading no older than
#     FM_UNBLOCK_COMPOSER_MAX_AGE seconds (default 120) or taken by
#     --probe-composer.
#
# ONE OWNER, ONE EPOCH. Every stall has a key bound to its epoch:
#   resume:<task>:<msg>@<spawn-gen>   a relaunch starts a new epoch
#   dispatch:<item>
# `observe` claims a candidate by creating state/unblock/<key>.claim
# exclusively; the first claimer owns the stall for that epoch, records one
# `unblock.candidate` line in state/unblock.jsonl, and later runs report it as
# claimed and record nothing. A claim is never retried or released by this
# command. Claims of resume stalls whose task meta is gone are removed.
#
# config/auto-unblock, first line: `observe` allows `observe`; `off`, absence,
# or any other value refuses it. `plan` needs no flag. No value enables
# enforcement.
#
# Environment: FM_UNBLOCK_STALL_SECS, FM_UNBLOCK_COMPOSER_MAX_AGE,
# FM_UNBLOCK_LEDGER (the ledger command, default bin/fm-ledger.sh; tests use
# it), FM_UNBLOCK_NOW (the current epoch; tests use it).
#
# Exit status: 0 decided, 1 a snapshot or the identity could not be read,
# 2 usage, 3 refused (enforce, or observe while auto-unblock is not observe).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG"

usage() {
  echo "usage: fm-unblock.sh plan [--probe-composer] | observe [--probe-composer] | enforce" >&2
  exit 2
}

CMD=${1-}
[ "$#" -gt 0 ] && shift
PROBE=()
for arg in "$@"; do
  case "$arg" in
    --probe-composer) PROBE=(--probe-composer) ;;
    *) usage ;;
  esac
done
case "$CMD" in
  plan|observe) ;;
  enforce)
    echo "fm-unblock: refused: this version runs in dry run only; nothing is enforced" >&2
    exit 3
    ;;
  *) usage ;;
esac

positive_int() {  # <value> <default>
  case "$1" in ''|*[!0-9]*|0) printf '%s' "$2" ;; *) printf '%s' "$((10#$1))" ;; esac
}
STALL_SECS=$(positive_int "${FM_UNBLOCK_STALL_SECS-}" 900)
COMPOSER_MAX_AGE=$(positive_int "${FM_UNBLOCK_COMPOSER_MAX_AGE-}" 120)
NOW=$(positive_int "${FM_UNBLOCK_NOW-}" "$(date +%s)")

if [ "$CMD" = observe ]; then
  mode=''
  { IFS= read -r mode < "$CONFIG/auto-unblock"; } 2>/dev/null || mode=''
  if [ "$mode" != observe ]; then
    echo "fm-unblock: refused: config/auto-unblock is not 'observe'; run 'plan' for a read-only view" >&2
    exit 3
  fi
fi

# shellcheck source=bin/fm-producer-identity-lib.sh
. "$SCRIPT_DIR/fm-producer-identity-lib.sh" || exit 1
fm_producer_identity_load "$STATE" || { echo "fm-unblock: cannot load the producer identity in $STATE" >&2; exit 1; }
SOURCE=$(fm_producer_source_json fm-unblock) || exit 1

DECISIONS=()

# shellcheck disable=SC2016 # $names in the filter are jq variables.
resume_decisions() {
  local snaps
  snaps=$("$SCRIPT_DIR/fm-task-snapshot.sh" --all ${PROBE[@]+"${PROBE[@]}"}) || return 1
  [ -n "$snaps" ] || return 0
  jq -c --argjson now "$NOW" --argjson stall "$STALL_SECS" --argjson cmax "$COMPOSER_MAX_AGE" '
    select(.queue.oldest_ordinary != null and .queue.oldest_ordinary_queued_at != null
           and ($now - .queue.oldest_ordinary_queued_at) >= $stall)
    | . as $s
    | $s.queue.oldest_ordinary as $msg
    | ($s.queue.last_delivery // {}) as $ld
    | (if ($s.state.state // "") == "done" or ($s.state.state // "") == "failed" then "worker-reported-final-state"
       elif ($s.waits.human_gates | length) > 0 then "open-human-gate"
       elif $s.waits.dependency != null then "declared-wait"
       elif ($s.waits.dialog as $d | ["permission","question","feedback","usage-limit","model-switch"] | any(. == $d)) then "dialog-needs-answer"
       elif $s.binding.spawn_gen == null then "no-spawn-generation"
       elif $ld.msg == $msg and ($ld.result // "") == "rang" then "ambiguous-delivery:rang-without-pickup"
       elif $ld.msg == $msg and ($ld.result // "") == "send-failed" then "ambiguous-delivery:send-failed"
       elif $ld.msg == $msg and ($ld.result // "") == "composer-unproven" then "ambiguous-delivery:input-line-unreadable"
       elif $ld.msg == $msg and ($ld.result // "") == "endpoint-gone" then "endpoint-gone"
       elif $s.queue.composer == null or $s.queue.composer.state != "empty" then "input-line-not-proven-empty"
       elif ($s.queue.composer.probed | not) and (($s.queue.composer.at // 0) < ($now - $cmax)) then "input-line-reading-stale"
       else null end) as $hold
    | {action: "resume", task: $s.task, msg: $msg, item: null,
       epoch: $s.binding.spawn_gen,
       stall_key: ("resume:" + $s.task + ":" + $msg + "@" + ($s.binding.spawn_gen // "none")),
       waited_secs: ($now - $s.queue.oldest_ordinary_queued_at),
       verdict: (if $hold == null then "candidate" else "hold" end),
       reason: ($hold // "stalled-on-unacknowledged-message"),
       would: (if $hold == null then {ring: $msg, draft_guard: "strict"} else null end)}
  ' <<< "$snaps"
}

# shellcheck disable=SC2016 # $names in the filter are jq variables.
dispatch_decision() {
  local ledger out rc line id
  ledger=${FM_UNBLOCK_LEDGER:-$SCRIPT_DIR/fm-ledger.sh}
  out=$("$ledger" next 2>/dev/null)
  rc=$?
  [ "$rc" -ne 3 ] || return 0
  if [ "$rc" -ne 0 ]; then
    jq -cn '{action: "dispatch", task: null, msg: null, item: null, epoch: null, stall_key: null,
             verdict: "hold", reason: "backlog-unreadable", would: null}'
    return 0
  fi
  line=$(printf '%s\n' "$out" | grep -m 1 '^NEXT ')
  id=${line#NEXT }
  id=${id%% *}
  case "$id" in ''|.*|*[!A-Za-z0-9._-]*)
    jq -cn '{action: "dispatch", task: null, msg: null, item: null, epoch: null, stall_key: null,
             verdict: "hold", reason: "backlog-unreadable", would: null}'
    return 0
    ;;
  esac
  local hold=''
  [ ! -e "$STATE/$id.meta" ] || hold=task-already-live
  jq -cn --arg id "$id" --arg hold "$hold" --arg line "$line" '
    {action: "dispatch", task: null, msg: null, item: $id, epoch: $id,
     stall_key: ("dispatch:" + $id),
     verdict: (if $hold == "" then "candidate" else "hold" end),
     reason: (if $hold == "" then "ready-backlog-item" else $hold end),
     would: (if $hold == "" then {dispatch: $id, ledger: $line} else null end)}'
}

claim_name() {  # <stall-key> -> a file name
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

prune_claims() {
  local f t
  for f in "$STATE"/unblock/resume_*.claim; do
    [ -f "$f" ] || continue
    t=$(jq -r '.task // empty' "$f" 2>/dev/null) || continue
    case "$t" in ''|.*|*[!A-Za-z0-9._-]*) continue ;; esac
    [ -e "$STATE/$t.meta" ] || rm -f "$f"
  done
}

emit() {  # <decision-json>
  local d=$1 claim rec owner
  # shellcheck disable=SC2016 # $names are jq variables.
  rec=$(jq -c --argjson ts "$NOW" --argjson source "$SOURCE" --arg mode dry-run \
    '{v: 1, ts: $ts, event: "unblock.decision", mode: $mode, source: $source} + .' <<< "$d") || return 1
  if [ "$CMD" = observe ] && [ "$(jq -r .verdict <<< "$rec")" = candidate ]; then
    # Only the recorded line is a candidate event; stdout keeps the decision event.
    mkdir -p "$STATE/unblock" || return 1
    claim="$STATE/unblock/$(claim_name "$(jq -r .stall_key <<< "$rec")").claim"
    if (set -o noclobber; printf '%s\n' "$rec" > "$claim") 2>/dev/null; then
      jq -c '.event = "unblock.candidate"' <<< "$rec" >> "$STATE/unblock.jsonl" || return 1
    else
      owner=$(jq -c '.source // null' "$claim" 2>/dev/null) || owner=null
      [ -n "$owner" ] || owner=null
      # shellcheck disable=SC2016 # $owner is a jq variable.
      rec=$(jq -c --argjson owner "$owner" '.verdict = "claimed" | .reason = "already-claimed-this-epoch" | .claimed_by = $owner | .would = null' <<< "$rec")
    fi
  fi
  printf '%s\n' "$rec"
}

[ "$CMD" != observe ] || prune_claims
rc=0
out=$(resume_decisions) || { echo "fm-unblock: a task snapshot failed" >&2; rc=1; }
while IFS= read -r d; do
  [ -n "$d" ] && DECISIONS+=("$d")
done <<< "$out"
out=$(dispatch_decision)
while IFS= read -r d; do
  [ -n "$d" ] && DECISIONS+=("$d")
done <<< "$out"
for d in "${DECISIONS[@]+"${DECISIONS[@]}"}"; do
  emit "$d" || rc=1
done
exit "$rc"
