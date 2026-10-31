#!/usr/bin/env bash
# fm-heartbeat.sh - publish a bounded fleet heartbeat ledger for self-watching.
#
# Usage:
#   fm-heartbeat.sh --json   print the fm-heartbeat.v1 document on stdout
#   fm-heartbeat.sh --write  atomically write state/heartbeat.json (best-effort)
#
# Each run observes bin/fm-fleet-snapshot.sh --json under FM_HEARTBEAT_SNAPSHOT_TIMEOUT
# (default 5 seconds), enriches that snapshot with git, no-mistakes, inbox, and
# primary-session facts, and never guesses: unread fields stay explicitly unknown.
# A slow snapshot read or any heartbeat failure is recorded in the document's
# failure and snapshot.failure fields while still publishing every field that
# was read successfully. Atomic publication matches state/home-summary.json:
# mode 0600 temp file on the state directory, then rename over the ledger.
#
# Top-level fields:
#   schema            stable id fm-heartbeat.v1
#   generated         UTC observation time for this execution
#   generated_epoch   Unix seconds for generated
#   fm_home           resolved operational home
#   snapshot          {ok, schema, generated, failure} for the fleet snapshot read
#   primary           supervising firstmate session (not a ship/scout task row)
#     terminal        {backend, target, present}
#     session         {trusted_id, anchor_pid, recorded}
#     last_turn         {observed_at, age_seconds, source}
#     composer_state    empty|pending|pending-unproven|unknown
#     context_left      {used_tokens, limit_tokens, remaining_tokens}
#   tasks[]           one row per snapshot task id, sorted by id
#     id
#     stage             {state, source, detail} from snapshot current_state
#     last_commit       {sha, branch} or unknown
#     last_push         {sha, ref} or unknown
#     pr_head           string or null from snapshot pr.head
#     no_mistakes_run   {run_id, step, active} or null
#     last_output_time  {observed_at, age_seconds, source}
#     open_asks         {decisions[], inbox_unhandled}
#   failure           null, or {reason} when the heartbeat itself failed partially
#
# bin/fm-watch.sh invokes --write once per poll under fm_run_timed; a failure
# there must never block or kill the watcher poll.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
LEDGER="$STATE/heartbeat.json"

FM_HEARTBEAT_SNAPSHOT_TIMEOUT=${FM_HEARTBEAT_SNAPSHOT_TIMEOUT:-5}
FM_HEARTBEAT_GIT_TIMEOUT=${FM_HEARTBEAT_GIT_TIMEOUT:-2}
FM_HEARTBEAT_NM_TIMEOUT=${FM_HEARTBEAT_NM_TIMEOUT:-2}

MODE=
case "${1:-}" in
  --json) MODE=json ;;
  --write) MODE="write" ;;
  -h|--help)
    sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac

case "$FM_HEARTBEAT_SNAPSHOT_TIMEOUT" in ''|*[!0-9]*|0) FM_HEARTBEAT_SNAPSHOT_TIMEOUT=5 ;; esac
case "$FM_HEARTBEAT_GIT_TIMEOUT" in ''|*[!0-9]*|0) FM_HEARTBEAT_GIT_TIMEOUT=2 ;; esac
case "$FM_HEARTBEAT_NM_TIMEOUT" in ''|*[!0-9]*|0) FM_HEARTBEAT_NM_TIMEOUT=2 ;; esac

command -v jq >/dev/null 2>&1 || {
  echo 'fm-heartbeat: jq is required' >&2
  exit 1
}

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-warm-compact-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-warm-compact-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

HEARTBEAT_NOW=${FM_HEARTBEAT_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
if [ -n "${FM_HEARTBEAT_NOW_EPOCH:-}" ]; then
  HEARTBEAT_EPOCH=$FM_HEARTBEAT_NOW_EPOCH
else
  HEARTBEAT_EPOCH=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$HEARTBEAT_NOW" +%s 2>/dev/null \
    || date -u -d "$HEARTBEAT_NOW" +%s 2>/dev/null \
    || date +%s)
fi
case "$HEARTBEAT_EPOCH" in ''|*[!0-9]*) HEARTBEAT_EPOCH=$(date +%s) ;; esac

file_mtime() {
  local m
  m=$(stat -f %m "$1" 2>/dev/null) || m=$(stat -c %Y "$1" 2>/dev/null) || return 1
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$m"
}

heartbeat_unknown() {  # <reason>
  jq -n --arg reason "$1" '{unknown:true,reason:$reason}'
}

heartbeat_read_snapshot() {  # <dest-file>
  local dest=$1 err rc
  err=$(mktemp "${dest}.err.XXXXXX") || return 1
  if fm_run_timed "$FM_HEARTBEAT_SNAPSHOT_TIMEOUT" env \
    FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" \
    FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_PROJECTS_OVERRIDE="$PROJECTS" \
    FM_SNAPSHOT_NOW="$HEARTBEAT_NOW" FM_SNAPSHOT_NOW_EPOCH="$HEARTBEAT_EPOCH" \
    "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json > "$dest" 2>"$err"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    HEARTBEAT_SNAPSHOT_FAILURE=$(tail -n 1 "$err" 2>/dev/null | tr '\t\r\n' '   ' | cut -c1-300)
    [ -n "$HEARTBEAT_SNAPSHOT_FAILURE" ] || HEARTBEAT_SNAPSHOT_FAILURE="exit $rc"
    if fm_timed_out "$rc"; then
      HEARTBEAT_SNAPSHOT_FAILURE="snapshot timed out after ${FM_HEARTBEAT_SNAPSHOT_TIMEOUT}s"
    fi
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  return 0
}

heartbeat_claude_transcript_for_session() {  # <session-id>
  local session=$1 root=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects dir
  case "$session" in ''|*/|*..*) return 1 ;; esac
  for dir in "$root"/*/; do
    [ -f "${dir}${session}.jsonl" ] || continue
    printf '%s\n' "${dir}${session}.jsonl"
    return 0
  done
  return 1
}

heartbeat_primary_transcript() {
  local session transcript
  session=$(fm_session_lock_recorded_session_id "$STATE" 2>/dev/null) || session=
  [ -n "$session" ] || return 1
  heartbeat_claude_transcript_for_session "$session"
}

heartbeat_last_turn_from_transcript() {  # <transcript> <now-epoch>
  local transcript=$1 now=$2 line ts
  [ -r "$transcript" ] || return 1
  line=$(tail -n 200 "$transcript" 2>/dev/null | jq -R -r '
    fromjson? | select(.type? == "turn_ended" or .type? == "assistant") | .timestamp // empty
  ' 2>/dev/null | awk 'NF { last=$0 } END { if (last != "") print last }')
  [ -n "$line" ] || return 1
  ts=$(date -u -j -f '%Y-%m-%dT%H:%M:%S.%NZ' "$line" +%s 2>/dev/null \
    || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$line" +%s 2>/dev/null \
    || date -u -d "$line" +%s 2>/dev/null) || return 1
  jq -n --arg observed "$line" --argjson age "$(( now - ts < 0 ? 0 : now - ts ))" \
    --arg source transcript '{observed_at:$observed,age_seconds:$age,source:$source}'
}

heartbeat_primary_json() {
  local backend target present=unknown composer=unknown session_id anchor_pid recorded=0
  local transcript tokens limit remaining transcript_path turn_json context_json
  backend=$(discover_supervisor_backend 2>/dev/null) || backend=unknown
  target=$(discover_supervisor_target 2>/dev/null) || target=
  if [ -n "$target" ] && [ "$backend" != unknown ]; then
    if fm_backend_target_exists "$backend" "$target" 2>/dev/null; then
      present=true
    else
      present=false
    fi
    composer=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null) || composer=unknown
  fi
  session_id=$(fm_session_lock_recorded_session_id "$STATE" 2>/dev/null) || session_id=
  anchor_pid=$(sed -n '1p' "$STATE/.lock" 2>/dev/null) || anchor_pid=
  case "$anchor_pid" in ''|*[!0-9]*) anchor_pid= ;; esac
  [ -n "$session_id" ] && recorded=1 || recorded=0
  transcript_path=$(heartbeat_primary_transcript 2>/dev/null) || transcript_path=
  turn_json=$(heartbeat_unknown "no turn boundary read")
  if [ -n "$transcript_path" ]; then
    turn_json=$(heartbeat_last_turn_from_transcript "$transcript_path" "$HEARTBEAT_EPOCH" 2>/dev/null) \
      || turn_json=$(heartbeat_unknown "transcript had no turn boundary")
  fi
  tokens=
  if [ -n "$transcript_path" ]; then
    tokens=$(fm_warm_compact_context_tokens "$transcript_path" 2>/dev/null) || tokens=
  fi
  limit=
  if fm_warm_compact_config "$CONFIG" 2>/dev/null; then
    limit=$FM_WARM_COMPACT_MIN
  fi
  remaining=
  if [ -n "$tokens" ] && [ -n "$limit" ]; then
    case "$tokens" in *[!0-9]*) remaining= ;; *)
      if [ "$limit" -gt "$tokens" ]; then remaining=$((limit - tokens)); else remaining=0; fi
    ;; esac
  fi
  context_json=$(jq -n \
    --arg used "${tokens:-}" \
    --arg lim "${limit:-}" \
    --arg rem "${remaining:-}" '
    {
      used_tokens: (if $used == "" then null else ($used | tonumber) end),
      limit_tokens: (if $lim == "" then null else ($lim | tonumber) end),
      remaining_tokens: (if $rem == "" then null else ($rem | tonumber) end)
    }')
  jq -n \
    --arg backend "$backend" \
    --arg target "$target" \
    --arg present "$present" \
    --arg composer "$composer" \
    --arg trusted "$session_id" \
    --arg anchor "$anchor_pid" \
    --argjson recorded "$recorded" \
    --argjson last_turn "$turn_json" \
    --argjson context_left "$context_json" \
    '{
      terminal:{
        backend:(if $backend == "" then null else $backend end),
        target:(if $target == "" then null else $target end),
        present:(if $present == "unknown" then "unknown" elif $present == "true" then true else false end)
      },
      session:{
        trusted_id:(if $trusted == "" then null else $trusted end),
        anchor_pid:(if $anchor == "" then null else ($anchor | tonumber) end),
        recorded:($recorded == 1)
      },
      last_turn:$last_turn,
      composer_state:(if $composer == "" then "unknown" else $composer end),
      context_left:$context_left
    }'
}

heartbeat_inbox_unhandled() {  # <task-id>
  local dir=$STATE/$1.inbox count=0 f
  [ -d "$dir" ] && [ ! -L "$dir" ] || { printf 'null\n'; return 0; }
  for f in "$dir"/*.msg; do
    [ -f "$f" ] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

heartbeat_git_field() {  # <worktree> <command...>
  local wt=$1
  shift
  fm_run_timed "$FM_HEARTBEAT_GIT_TIMEOUT" git -C "$wt" "$@" 2>/dev/null
}

heartbeat_task_row() {  # <snapshot-task-json>
  local task_json=$1 id wt branch sha push_ref push_sha nm_out run_id step active
  local meta status turn now newest age source decisions inbox last_output
  local last_commit last_push nm_json observed_iso f m
  id=$(printf '%s' "$task_json" | jq -r '.id')
  wt=$(printf '%s' "$task_json" | jq -r '.paths.worktree.path // ""')
  branch=$(printf '%s' "$task_json" | jq -r '.branch // ""')
  meta="$STATE/$id.meta"
  status="$STATE/$id.status"
  turn="$STATE/$id.turn-ended"
  now=$HEARTBEAT_EPOCH
  newest=0
  source=unknown
  for f in "$meta" "$status" "$turn"; do
    [ -e "$f" ] || continue
    m=$(file_mtime "$f" 2>/dev/null) || continue
    [ "$m" -le "$newest" ] || { newest=$m; source=$(basename "$f"); }
  done
  if [ "$newest" -gt 0 ]; then
    observed_iso=$(date -u -r "$newest" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -d "@$newest" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || printf '%s\n' "$newest")
    age=$(( now - newest ))
    [ "$age" -ge 0 ] || age=0
    last_output=$(jq -n \
      --arg observed "$observed_iso" \
      --argjson age "$age" \
      --arg source "$source" \
      '{observed_at:$observed,age_seconds:$age,source:$source}')
  else
    last_output=$(heartbeat_unknown "no task output markers")
  fi
  last_commit=$(heartbeat_unknown "no worktree")
  last_push=$(heartbeat_unknown "no worktree")
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    sha=$(heartbeat_git_field "$wt" rev-parse --verify HEAD 2>/dev/null) || sha=
    if [ -n "$sha" ]; then
      last_commit=$(jq -n --arg sha "$sha" --arg branch "$branch" \
        '{sha:$sha,branch:(if $branch == "" then null else $branch end)}')
    else
      last_commit=$(heartbeat_unknown "git HEAD unreadable")
    fi
    if [ -n "$branch" ]; then
      push_ref="origin/$branch"
      push_sha=$(heartbeat_git_field "$wt" rev-parse --verify "$push_ref^{commit}" 2>/dev/null) || push_sha=
      if [ -n "$push_sha" ]; then
        last_push=$(jq -n --arg sha "$push_sha" --arg ref "$push_ref" '{sha:$sha,ref:$ref}')
      else
        last_push=$(heartbeat_unknown "remote tracking ref unreadable")
      fi
    else
      last_push=$(heartbeat_unknown "branch unknown")
    fi
  fi
  nm_out=
  run_id='' step='' active=false
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    nm_out=$(fm_nm_run_checked "$wt" "$FM_HEARTBEAT_NM_TIMEOUT" axi status 2>/dev/null) || nm_out=
    if [ -n "$nm_out" ]; then
      run_id=$(fm_nm_field "$nm_out" run_id)
      step=$(fm_nm_field "$nm_out" step)
      if fm_nm_run_is_active "$nm_out" 2>/dev/null; then active=true; fi
    fi
  fi
  if [ -n "$run_id" ]; then
    nm_json=$(jq -n --arg run_id "$run_id" --arg step "$step" --argjson active "$active" \
      '{run_id:(if $run_id == "" then null else $run_id end),step:(if $step == "" then null else $step end),active:$active}')
  else
    nm_json=null
  fi
  decisions=$(printf '%s' "$task_json" | jq -c '.hints.open_decisions // []')
  inbox=$(heartbeat_inbox_unhandled "$id")
  jq -n \
    --arg id "$id" \
    --argjson stage "$(printf '%s' "$task_json" | jq -c \
      '{state:(.current_state.state // "unknown"),source:(.current_state.source // "unknown"),detail:(.current_state.detail // null)}')" \
    --argjson last_commit "$last_commit" \
    --argjson last_push "$last_push" \
    --arg pr_head "$(printf '%s' "$task_json" | jq -r '.pr.head // ""')" \
    --argjson no_mistakes_run "$nm_json" \
    --argjson last_output_time "$last_output" \
    --argjson decisions "$decisions" \
    --argjson inbox "$inbox" \
    '{
      id:$id,
      stage:$stage,
      last_commit:$last_commit,
      last_push:$last_push,
      pr_head:(if $pr_head == "" then null else $pr_head end),
      no_mistakes_run:$no_mistakes_run,
      last_output_time:$last_output_time,
      open_asks:{decisions:$decisions,inbox_unhandled:$inbox}
    }'
}

heartbeat_tasks_json() {  # <snapshot-file>
  local snapshot=$1
  jq -c '.tasks[]?' "$snapshot" 2>/dev/null | while IFS= read -r row; do
    [ -n "$row" ] || continue
    heartbeat_task_row "$row"
  done | jq -s 'sort_by(.id)'
}

HEARTBEAT_SNAPSHOT_FAILURE=
SNAPSHOT_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-heartbeat-snapshot.XXXXXX") || exit 1
SNAPSHOT_OK=false
if heartbeat_read_snapshot "$SNAPSHOT_FILE"; then
  if jq -e '.schema == "fm-fleet-snapshot.v1"' "$SNAPSHOT_FILE" >/dev/null 2>&1; then
    SNAPSHOT_OK=true
  else
    HEARTBEAT_SNAPSHOT_FAILURE='snapshot returned malformed JSON'
  fi
else
  [ -n "$HEARTBEAT_SNAPSHOT_FAILURE" ] || HEARTBEAT_SNAPSHOT_FAILURE='snapshot read failed'
fi

PRIMARY_JSON=$(heartbeat_primary_json) || PRIMARY_JSON='{}'
if [ "$SNAPSHOT_OK" = true ]; then
  TASKS_JSON=$(heartbeat_tasks_json "$SNAPSHOT_FILE") || TASKS_JSON='[]'
  SNAPSHOT_META=$(jq -n -c \
    --argjson ok true \
    --arg failure '' \
    --arg generated "$(jq -r '.generated // ""' "$SNAPSHOT_FILE")" \
    --arg schema "$(jq -r '.schema // ""' "$SNAPSHOT_FILE")" \
    '{ok:$ok,schema:(if $schema == "" then null else $schema end),generated:(if $generated == "" then null else $generated end),failure:(if $failure == "" then null else {reason:$failure} end)}')
else
  TASKS_JSON='[]'
  SNAPSHOT_META=$(jq -n --arg reason "${HEARTBEAT_SNAPSHOT_FAILURE:-snapshot unavailable}" \
    '{ok:false,schema:null,generated:null,failure:{reason:$reason}}')
fi
rm -f "$SNAPSHOT_FILE"

DOC=$(jq -n \
  --arg schema fm-heartbeat.v1 \
  --arg generated "$HEARTBEAT_NOW" \
  --argjson generated_epoch "$HEARTBEAT_EPOCH" \
  --arg fm_home "$FM_HOME" \
  --argjson snapshot "$SNAPSHOT_META" \
  --argjson primary "$PRIMARY_JSON" \
  --argjson tasks "$TASKS_JSON" \
  --arg failure '' \
  '{schema:$schema,generated:$generated,generated_epoch:$generated_epoch,fm_home:$fm_home,
    snapshot:$snapshot,primary:$primary,tasks:$tasks,failure:(if $failure == "" then null else {reason:$failure} end)}') \
  || {
    echo 'fm-heartbeat: could not assemble heartbeat document' >&2
    exit 1
  }

if [ "$MODE" = json ]; then
  printf '%s\n' "$DOC"
  exit 0
fi

if [ ! -d "$STATE" ]; then
  echo "fm-heartbeat: no state directory at $STATE; nothing published" >&2
  exit 0
fi
tmp=$(umask 077; mktemp "$STATE/.heartbeat.json.XXXXXX" 2>/dev/null) || {
  echo "fm-heartbeat: cannot create a temporary file in $STATE; nothing published" >&2
  exit 0
}
if chmod 600 "$tmp" 2>/dev/null \
  && printf '%s\n' "$DOC" > "$tmp" \
  && mv -f "$tmp" "$LEDGER" 2>/dev/null; then
  exit 0
fi
rm -f "$tmp"
echo "fm-heartbeat: could not write $LEDGER" >&2
exit 0
