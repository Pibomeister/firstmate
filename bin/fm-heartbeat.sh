#!/usr/bin/env bash
# fm-heartbeat.sh - publish a bounded fleet heartbeat ledger for self-watching.
#
# Usage:
#   fm-heartbeat.sh --write  atomically write state/heartbeat.json (best-effort)
#
# Each run observes bin/fm-fleet-snapshot.sh --json under FM_HEARTBEAT_SNAPSHOT_TIMEOUT
# (default 30 seconds, above the snapshot's own inner bounds), enriches that
# snapshot with git, no-mistakes, inbox, terminal, and transcript facts, and never
# guesses: unread fields carry {unknown:true,reason}. Every primary and per-task
# read has its own bound (FM_HEARTBEAT_READ_TIMEOUT, default 3 seconds, and
# FM_HEARTBEAT_NM_TIMEOUT, default 2), and FM_HEARTBEAT_DEADLINE (default 90
# seconds) stops starting new task reads. A deadline hit or a TERM, INT, or HUP
# still publishes what was read, with unknown rows for the rest. A SIGKILL cannot
# publish; the next run sweeps what it left. All temp files live in one private
# state/.heartbeat-work.* directory, and the ledger is renamed from it.
#
# Top-level fields:
#   schema            stable id fm-heartbeat.v1
#   generated         UTC observation time for this execution
#   generated_epoch   Unix seconds for generated
#   fm_home           resolved operational home
#   snapshot          {ok, schema, generated, failure} for the fleet snapshot read
#   primary           supervising firstmate session (not a ship/scout task row)
#     terminal          {backend, target, present}
#     session           {trusted_id, anchor_pid, recorded}
#     last_turn         {observed_at, age_seconds, source}
#     composer_state    empty|pending|pending-unproven|unknown
#     context_left      {used_tokens, remaining}; remaining is {percent, source} from
#                       the harness's own "N% until auto-compact" pane text, else
#                       unknown; no window size is ever assumed
#   tasks[]           one row per snapshot task id, sorted by id
#     id
#     terminal          {backend, target, exists} from snapshot endpoint
#     session           {id} from the worktree's newest Claude transcript, ignored
#                       when older than the spawn_gen epoch or with no such epoch
#     last_turn         as primary
#     composer_state    as primary; read only for a live local endpoint
#     context_left      as primary
#     stage             {state, source, detail} from snapshot current_state
#     last_commit       {sha, branch}; branch is unknown when the worktree left
#                       the recorded branch or its branch is unread
#     last_push         {sha, ref}: the local no-mistakes tracking ref, else origin;
#                       never a network read; unknown in the same branch cases
#     pr_head           string; null when the task records no PR
#     no_mistakes_run   {run_id, step, active} for the run fm_nm_select_run picks;
#                       null when it finds no run on the branch; unknown, not a
#                       failure, in a repo with no gate or for a run that fails
#                       the fm-nm-run-lib.sh attribution rule; unknown when the
#                       worktree left the recorded branch; active is unknown
#                       for an active record whose daemon answered down
#     last_output_time  {observed_at, age_seconds, source}: terminal (the watcher's
#                       pane-change marker) or transcript, each only from since the
#                       spawn_gen epoch; a secondmate's marker is never read, since
#                       the watcher does not refresh it for that kind
#     open_asks         {decisions, inbox_unhandled}
#   failure           null only on a clean run, else {reason, count} naming every
#                     read that failed or timed out; absent evidence is not a failure
#
# FM_HEARTBEAT_SNAPSHOT_SCRIPT may name a replacement snapshot producer; tests
# use it to simulate slow reads without touching the real fleet snapshot.
#
# bin/fm-watch.sh runs --write detached and single-flight, so no read here can
# hold a watcher poll.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
LEDGER="$STATE/heartbeat.json"

FM_HEARTBEAT_SNAPSHOT_TIMEOUT=${FM_HEARTBEAT_SNAPSHOT_TIMEOUT:-30}
FM_HEARTBEAT_READ_TIMEOUT=${FM_HEARTBEAT_READ_TIMEOUT:-3}
FM_HEARTBEAT_NM_TIMEOUT=${FM_HEARTBEAT_NM_TIMEOUT:-2}
FM_HEARTBEAT_DEADLINE=${FM_HEARTBEAT_DEADLINE:-90}

case "${1:-}" in
  --write) ;;
  -h|--help)
    sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac

case "$FM_HEARTBEAT_SNAPSHOT_TIMEOUT" in ''|*[!0-9]*|0) FM_HEARTBEAT_SNAPSHOT_TIMEOUT=30 ;; esac
case "$FM_HEARTBEAT_READ_TIMEOUT" in ''|*[!0-9]*|0) FM_HEARTBEAT_READ_TIMEOUT=3 ;; esac
case "$FM_HEARTBEAT_NM_TIMEOUT" in ''|*[!0-9]*|0) FM_HEARTBEAT_NM_TIMEOUT=2 ;; esac
case "$FM_HEARTBEAT_DEADLINE" in ''|*[!0-9]*|0) FM_HEARTBEAT_DEADLINE=90 ;; esac

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
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"

HEARTBEAT_NOW=${FM_HEARTBEAT_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
HEARTBEAT_EPOCH=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$HEARTBEAT_NOW" +%s 2>/dev/null \
  || date -u -d "$HEARTBEAT_NOW" +%s 2>/dev/null \
  || date +%s)

file_mtime() {
  local m
  m=$(stat -f %m "$1" 2>/dev/null) || m=$(stat -c %Y "$1" 2>/dev/null) || return 1
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$m"
}

heartbeat_unknown() {  # <reason>
  jq -n --arg reason "$1" '{unknown:true,reason:$reason}'
}

heartbeat_note_failure() {  # <reason>
  printf '%s\n' "$1" >> "$HEARTBEAT_WORK/failures" 2>/dev/null || true
}

# Run one read under its own bound. Stdout and status are the read's own; a hit
# bound is also recorded as a failure.
heartbeat_read() {  # <label> <function-or-command> [args...]
  local label=$1 rc=0
  shift
  fm_run_timed_fn "$FM_HEARTBEAT_READ_TIMEOUT" "$@" 2>/dev/null </dev/null || rc=$?
  if fm_timed_out "$rc"; then
    heartbeat_note_failure "$label timed out after ${FM_HEARTBEAT_READ_TIMEOUT}s"
  fi
  return "$rc"
}

# The background job plus wait lets a TERM reach the trap at once. A stopped run
# leaves the job to end at its own bound, which removes its own temp file.
heartbeat_read_snapshot() {  # <dest-file>
  local dest=$1 err=$HEARTBEAT_WORK/snapshot.err rc reason snapshot_sh
  snapshot_sh="${FM_HEARTBEAT_SNAPSHOT_SCRIPT:-$SCRIPT_DIR/fm-fleet-snapshot.sh}"
  fm_run_timed "$FM_HEARTBEAT_SNAPSHOT_TIMEOUT" env \
    FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" \
    FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_PROJECTS_OVERRIDE="$PROJECTS" \
    FM_SNAPSHOT_NOW="$HEARTBEAT_NOW" FM_SNAPSHOT_NOW_EPOCH="$HEARTBEAT_EPOCH" \
    "$snapshot_sh" --json > "$dest" 2>"$err" </dev/null &
  if wait "$!"; then
    return 0
  else
    rc=$?
  fi
  if fm_timed_out "$rc"; then
    reason="snapshot timed out after ${FM_HEARTBEAT_SNAPSHOT_TIMEOUT}s"
  else
    reason=$(tail -n 1 "$err" 2>/dev/null | tr '\t\r\n' '   ' | cut -c1-300)
    [ -n "$reason" ] || reason="snapshot exit $rc"
  fi
  HEARTBEAT_SNAPSHOT_FAILURE=$reason
  return 1
}

# shellcheck disable=SC2329 # Invoked through heartbeat_read.
heartbeat_last_turn_from_transcript() {  # <transcript>
  local transcript=$1 line stamp ts age
  [ -r "$transcript" ] || return 1
  line=$(tail -n 200 "$transcript" 2>/dev/null | jq -R -r '
    fromjson? | select(.type? == "turn_ended" or .type? == "assistant") | .timestamp // empty
  ' 2>/dev/null | awk 'NF { last=$0 } END { if (last != "") print last }')
  [ -n "$line" ] || return 1
  stamp=${line%%.*}
  stamp=${stamp%Z}Z
  ts=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$stamp" +%s 2>/dev/null \
    || date -u -d "$stamp" +%s 2>/dev/null) || return 1
  age=$(( HEARTBEAT_EPOCH - ts ))
  [ "$age" -ge 0 ] || age=0
  jq -n --arg observed "$line" --argjson age "$age" \
    '{observed_at:$observed,age_seconds:$age,source:"transcript"}'
}

heartbeat_turn_json() {  # <label> <transcript-or-empty>
  if [ -z "$2" ]; then
    heartbeat_unknown "no transcript found"
    return 0
  fi
  heartbeat_read "$1 last turn" heartbeat_last_turn_from_transcript "$2" \
    || heartbeat_unknown "transcript had no readable turn boundary"
}

# Only the pane's last lines, where the harness draws its status, so a mate
# quoting the phrase higher up in its output is not read as its own context.
# shellcheck disable=SC2329 # Invoked through heartbeat_read.
heartbeat_pane_context_percent() {  # <backend> <target> [expected-label]
  fm_backend_capture "$1" "$2" 5 ${3:+"$3"} 2>/dev/null \
    | awk 'NF' | tail -n 5 \
    | sed -n -E 's/.*[^0-9]([0-9]{1,3})% until auto-compact.*/\1/p; s/^([0-9]{1,3})% until auto-compact.*/\1/p; s/.*until auto-compact: ([0-9]{1,3})%.*/\1/p' \
    | tail -n 1
}

heartbeat_context_json() {  # <label> <transcript-or-empty> [backend] [target] [expected-label]
  local tokens='' percent=''
  [ -z "$2" ] || tokens=$(heartbeat_read "$1 context" fm_warm_compact_context_tokens "$2") || tokens=
  if [ -n "${3:-}" ] && [ -n "${4:-}" ]; then
    percent=$(heartbeat_read "$1 pane context" heartbeat_pane_context_percent "$3" "$4" "${5:-}") || percent=
  fi
  jq -n --arg used "$tokens" --arg percent "$percent" '
    def u(r): {unknown:true,reason:r};
    {
      used_tokens:(if ($used | test("^[0-9]+$")) then ($used | tonumber) else u("transcript had no token usage") end),
      remaining:(if $percent == "" then u("harness showed no context text in its pane")
        else {percent:($percent | tonumber),source:"terminal"} end)
    }'
}

heartbeat_primary_json() {
  local backend target present composer=unknown session_id anchor_pid rc=0 transcript
  local turn_json context_json
  backend=$(heartbeat_read "primary backend" discover_supervisor_backend) || backend=
  target=$(heartbeat_read "primary target" discover_supervisor_target) || target=
  present=$(heartbeat_unknown "no supervisor endpoint discovered")
  if [ -n "$target" ] && [ -n "$backend" ]; then
    heartbeat_read "primary terminal" fm_backend_target_exists "$backend" "$target" >/dev/null || rc=$?
    if [ "$rc" -eq 0 ]; then
      present=true
    elif fm_timed_out "$rc"; then
      present=$(heartbeat_unknown "terminal read timed out")
    else
      present=false
    fi
    composer=$(heartbeat_read "primary composer" fm_backend_composer_state "$backend" "$target") || composer=unknown
  fi
  session_id=$(heartbeat_read "primary session" fm_session_lock_recorded_session_id "$STATE") || session_id=
  anchor_pid=$(heartbeat_read "primary anchor" sed -n '1p' "$STATE/.lock") || anchor_pid=
  transcript=
  [ -z "$session_id" ] || transcript=$(heartbeat_read "primary transcript" fm_warm_compact_engine_transcript "$session_id") || transcript=
  turn_json=$(heartbeat_turn_json primary "$transcript")
  if [ "$present" = true ]; then
    context_json=$(heartbeat_context_json primary "$transcript" "$backend" "$target")
  else
    context_json=$(heartbeat_context_json primary "$transcript")
  fi
  jq -n \
    --arg backend "$backend" \
    --arg target "$target" \
    --argjson present "$present" \
    --arg composer "$composer" \
    --arg trusted "$session_id" \
    --arg anchor "$anchor_pid" \
    --argjson last_turn "$turn_json" \
    --argjson context_left "$context_json" \
    'def u(r): {unknown:true,reason:r};
    {
      terminal:{
        backend:(if $backend == "" then u("no supervisor backend discovered") else $backend end),
        target:(if $target == "" then u("no supervisor target discovered") else $target end),
        present:$present
      },
      session:{
        trusted_id:(if $trusted == "" then u("no session recorded") else $trusted end),
        anchor_pid:(if ($anchor | test("^[0-9]+$")) then ($anchor | tonumber) else u("no lock anchor read") end),
        recorded:($trusted != "")
      },
      last_turn:$last_turn,
      composer_state:(if $composer == "" then "unknown" else $composer end),
      context_left:$context_left
    }'
}

heartbeat_inbox_unhandled() {  # <task-id>
  local dir=$STATE/$1.inbox count=0 f
  if [ ! -d "$dir" ] || [ -L "$dir" ]; then
    heartbeat_unknown "no readable inbox directory"
    return 0
  fi
  for f in "$dir"/*.msg; do
    [ -f "$f" ] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

heartbeat_spawn_epoch() {  # <spawn-gen>
  local epoch
  case "$1" in s[0-9]*.*) ;; *) return 1 ;; esac
  epoch=${1#s}
  epoch=${epoch%%.*}
  case "$epoch" in *[!0-9]*) return 1 ;; esac
  printf '%s\n' "$epoch"
}

# Claude keeps a worktree's transcripts in a directory named after its path,
# with every non-alphanumeric byte replaced by a dash.
# Slots are reused and transcripts outlive them, so only one written since this
# task's spawn belongs to it. More than one qualifying file means another Claude
# session in the same directory and must not be attributed to this mate.
# shellcheck disable=SC2329 # Invoked through heartbeat_read.
heartbeat_worktree_transcript() {  # <worktree> <spawn-gen>
  local slug file m newest=0 found='' spawn_epoch count=0
  spawn_epoch=$(heartbeat_spawn_epoch "$2") || return 1
  slug=$(printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')
  for file in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$slug"/*.jsonl; do
    [ -f "$file" ] || continue
    m=$(file_mtime "$file") || continue
    [ "$m" -ge "$spawn_epoch" ] || continue
    count=$((count + 1))
    [ "$m" -le "$newest" ] || { newest=$m; found=$file; }
  done
  [ "$count" -gt 1 ] && return 2
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

heartbeat_last_output_json() {  # <target-or-empty> <qualified-transcript-or-empty> <spawn-gen> <kind>
  local target=$1 transcript=$2 spawn_gen=$3 kind=$4 key marker='' spawn_epoch newest=0 source='' observed_iso age f m label pair
  if [ -n "$target" ] && [ "$kind" != secondmate ] && spawn_epoch=$(heartbeat_spawn_epoch "$spawn_gen"); then
    key=$(window_key "$target")
    m=$(file_mtime "$STATE/.hash-$key") || m=0
    [ "$m" -lt "$spawn_epoch" ] || marker=$STATE/.hash-$key
  fi
  for pair in "terminal|$marker" "transcript|$transcript"; do
    label=${pair%%|*}
    f=${pair#*|}
    [ -f "$f" ] || continue
    m=$(file_mtime "$f") || continue
    [ "$m" -le "$newest" ] || { newest=$m; source=$label; }
  done
  if [ "$newest" -eq 0 ]; then
    heartbeat_unknown "no terminal or transcript activity read since this spawn"
    return 0
  fi
  observed_iso=$(date -u -r "$newest" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$newest" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '%s\n' "$newest")
  age=$(( HEARTBEAT_EPOCH - newest ))
  [ "$age" -ge 0 ] || age=0
  jq -n --arg observed "$observed_iso" --argjson age "$age" --arg source "$source" \
    '{observed_at:$observed,age_seconds:$age,source:$source}'
}

heartbeat_last_push_json() {  # <id> <worktree> <branch>
  local id=$1 wt=$2 branch=$3 remote sha
  if [ -z "$branch" ]; then
    heartbeat_unknown "branch unknown"
    return 0
  fi
  for remote in no-mistakes origin; do
    sha=$(heartbeat_read "task $id $remote ref" git -C "$wt" rev-parse --verify --quiet \
      "refs/remotes/$remote/$branch^{commit}") || sha=
    if [ -n "$sha" ]; then
      jq -n --arg sha "$sha" --arg ref "$remote/$branch" '{sha:$sha,ref:$ref}'
      return 0
    fi
  done
  heartbeat_unknown "no local no-mistakes or origin ref for the branch"
}

heartbeat_no_mistakes_json() {  # <id> <worktree> <branch> <reason the worktree branch disqualifies the read, or empty>
  local id=$1 wt=$2 branch=$3 branch_problem=$4 out overview choice run_id rc=0 step active=false daemon=""
  out=$(fm_nm_run_checked "$wt" "$FM_HEARTBEAT_NM_TIMEOUT" axi status </dev/null) || rc=$?
  if [ "$(fm_nm_strip_quotes "$(fm_nm_field "$out" error)")" = "repo not initialized (run 'no-mistakes init' first)" ]; then
    heartbeat_unknown "repo has no gate"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    heartbeat_note_failure "task $id no-mistakes status exit $rc"
    heartbeat_unknown "no-mistakes status read failed"
    return 0
  fi
  if [ -z "$branch" ]; then
    heartbeat_unknown "task records no branch"
    return 0
  fi
  if [ -n "$branch_problem" ]; then
    heartbeat_unknown "$branch_problem"
    return 0
  fi
  if [ "$(fm_nm_strip_quotes "$(fm_nm_field "$out" current_branch)")" = "$branch" ] \
    && [ "$(fm_nm_strip_quotes "$(fm_nm_field "$out" runs_on_current_branch)")" = 0 ]; then
    printf 'null\n'
    return 0
  fi
  overview=$(fm_nm_run_checked "$wt" "$FM_HEARTBEAT_NM_TIMEOUT" axi </dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    heartbeat_note_failure "task $id no-mistakes overview exit $rc"
    heartbeat_unknown "no-mistakes overview read failed"
    return 0
  fi
  choice=$(fm_nm_select_run "$branch" "$overview" "$wt" "$FM_HEARTBEAT_NM_TIMEOUT")
  case "$choice" in
    absent)
      printf 'null\n'
      return 0
      ;;
    selected\|*)
      run_id=${choice#selected|}
      run_id=${run_id%%|*}
      ;;
    *)
      heartbeat_note_failure "task $id no-mistakes run selection: ${choice#*|}"
      heartbeat_unknown "no-mistakes run selection: ${choice#*|}"
      return 0
      ;;
  esac
  out=$(fm_nm_run_checked "$wt" "$FM_HEARTBEAT_NM_TIMEOUT" axi status --run "$run_id" </dev/null) || rc=$?
  if [ "$rc" -ne 0 ] || [ "$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")" != "$run_id" ] \
    || [ "$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")" != "$branch" ]; then
    heartbeat_note_failure "task $id no-mistakes selected run $run_id unreadable"
    heartbeat_unknown "no-mistakes selected run unreadable"
    return 0
  fi
  if fm_nm_run_is_active "$out"; then
    daemon=$(fm_nm_daemon_answer "$wt" "$FM_HEARTBEAT_NM_TIMEOUT" </dev/null)
    if [ "$daemon" = unanswered ]; then
      heartbeat_note_failure "task $id no-mistakes daemon status timed out"
    fi
  fi
  if ! fm_nm_run_is_pipeline_owned_active "$out" \
    && ! { fm_nm_run_is_executing "$out" && [ "$daemon" != down ]; } \
    && ! heartbeat_read "task $id run head" fm_nm_head_matches_worktree "$wt" \
      "$(fm_nm_strip_quotes "$(fm_nm_field "$out" head)")"; then
    heartbeat_unknown "no-mistakes run code identity unverified"
    return 0
  fi
  step=$(fm_nm_table_column "$out" active_steps step | head -1)
  if [ "$daemon" = down ]; then
    active=$(heartbeat_unknown "no-mistakes daemon down; run record unverified")
  elif [ -n "$daemon" ]; then
    active=true
  fi
  jq -n --arg run_id "$run_id" --arg step "$step" --argjson active "$active" \
    '{run_id:$run_id,step:(if $step == "" then null else $step end),active:$active}'
}

heartbeat_task_row() {  # <snapshot-task-json>
  local wt_branch wt_branch_rc branch_problem
  local task_json=$1 id wt branch backend target exists remote harness spawn_gen kind transcript=
  local transcript_rc=0 ambiguous_transcript=''
  local turn_json context_json output_json
  local pane_backend='' pane_target='' pane_label=''
  local session composer=unknown last_commit last_push nm_json sha
  id=$(printf '%s' "$task_json" | jq -r '.id')
  wt=$(printf '%s' "$task_json" | jq -r '.paths.worktree.path // ""')
  branch=$(printf '%s' "$task_json" | jq -r '.branch // ""')
  backend=$(printf '%s' "$task_json" | jq -r '.backend // ""')
  target=$(printf '%s' "$task_json" | jq -r '.endpoint.target // ""')
  exists=$(printf '%s' "$task_json" | jq -r '.endpoint.exists // ""')
  remote=$(printf '%s' "$task_json" | jq -r '.remote.host // ""')
  harness=$(printf '%s' "$task_json" | jq -r '.harness // ""')
  spawn_gen=$(printf '%s' "$task_json" | jq -r '.spawn_gen // ""')
  kind=$(printf '%s' "$task_json" | jq -r '.kind // ""')
  if [ "$harness" = claude ] && [ -n "$wt" ]; then
    transcript=$(heartbeat_read "task $id transcript" heartbeat_worktree_transcript "$wt" "$spawn_gen") || transcript_rc=$?
    if [ "$transcript_rc" -eq 2 ]; then
      ambiguous_transcript='ambiguous transcript'
      transcript=
    fi
  fi
  if [ -n "$ambiguous_transcript" ]; then
    session=$(heartbeat_unknown "$ambiguous_transcript")
    turn_json=$(heartbeat_unknown "$ambiguous_transcript")
    context_json=$(heartbeat_unknown "$ambiguous_transcript")
    output_json=$(heartbeat_unknown "$ambiguous_transcript")
  elif [ -n "$transcript" ]; then
    session=$(jq -n --arg id "$(basename "$transcript" .jsonl)" '{id:$id}')
    turn_json=$(heartbeat_turn_json "task $id" "$transcript")
    context_json=$(heartbeat_context_json "task $id" "$transcript")
    output_json=$(heartbeat_last_output_json "$target" "$transcript" "$spawn_gen" "$kind")
  else
    session=$(heartbeat_unknown "no readable session for this harness and worktree")
    turn_json=$(heartbeat_turn_json "task $id" "$transcript")
    context_json=$(heartbeat_context_json "task $id" "$transcript")
    output_json=$(heartbeat_last_output_json "$target" "$transcript" "$spawn_gen" "$kind")
  fi
  if [ "$exists" = true ] && [ -z "$remote" ] && [ -n "$backend" ] && [ -n "$target" ]; then
    composer=$(heartbeat_read "task $id composer" fm_backend_composer_state "$backend" "$target" "fm-$id") || composer=unknown
    pane_backend=$backend
    pane_target=$target
    pane_label=fm-$id
    if [ -n "$transcript" ] && [ -z "$ambiguous_transcript" ]; then
      context_json=$(heartbeat_context_json "task $id" "$transcript" "$pane_backend" "$pane_target" "$pane_label")
    fi
  fi
  last_commit=$(heartbeat_unknown "no worktree")
  last_push=$(heartbeat_unknown "no worktree")
  nm_json=$(heartbeat_unknown "no worktree")
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    wt_branch_rc=0
    branch_problem=
    wt_branch=$(heartbeat_read "task $id worktree branch" git -C "$wt" symbolic-ref --quiet --short HEAD) || wt_branch_rc=$?
    case "$wt_branch_rc" in
      0)
        if [ -n "$branch" ] && [ "$wt_branch" != "$branch" ]; then
          branch_problem="worktree is on branch $wt_branch; task records $branch"
        fi
        ;;
      1) ;;
      *)
        fm_timed_out "$wt_branch_rc" || heartbeat_note_failure "task $id worktree branch unreadable"
        branch_problem="worktree branch unread"
        ;;
    esac
    sha=$(heartbeat_read "task $id HEAD" git -C "$wt" rev-parse --verify HEAD) || sha=
    if [ -n "$sha" ]; then
      last_commit=$(jq -n --arg sha "$sha" --arg branch "$branch" --arg problem "$branch_problem" \
        '{sha:$sha,branch:(if $problem != "" then {unknown:true,reason:$problem} elif $branch == "" then null else $branch end)}')
    else
      heartbeat_note_failure "task $id git HEAD unreadable"
      last_commit=$(heartbeat_unknown "git HEAD unreadable")
    fi
    if [ -n "$branch_problem" ]; then
      last_push=$(heartbeat_unknown "$branch_problem")
    else
      last_push=$(heartbeat_last_push_json "$id" "$wt" "$branch")
    fi
    nm_json=$(heartbeat_no_mistakes_json "$id" "$wt" "$branch" "$branch_problem")
  fi
  printf '%s' "$task_json" | jq -c \
    --argjson session "$session" \
    --argjson last_turn "$turn_json" \
    --arg composer "${composer:-unknown}" \
    --argjson context_left "$context_json" \
    --argjson last_commit "$last_commit" \
    --argjson last_push "$last_push" \
    --argjson no_mistakes_run "$nm_json" \
    --argjson last_output_time "$output_json" \
    --argjson inbox "$(heartbeat_inbox_unhandled "$id")" '
    def u(r): {unknown:true,reason:r};
    {
      id:.id,
      terminal:{
        backend:(.backend // u("no backend recorded")),
        target:(.endpoint.target // u("no endpoint recorded")),
        exists:(if (.endpoint.exists | type) == "boolean" then .endpoint.exists else u("endpoint not read") end)
      },
      session:$session,
      last_turn:$last_turn,
      composer_state:$composer,
      context_left:$context_left,
      stage:{state:(.current_state.state // "unknown"),source:(.current_state.source // "unknown"),detail:(.current_state.detail // null)},
      last_commit:$last_commit,
      last_push:$last_push,
      pr_head:(.pr.head // (if .pr.url then u("PR head not recorded") else null end)),
      no_mistakes_run:$no_mistakes_run,
      last_output_time:$last_output_time,
      open_asks:{decisions:(.hints.open_decisions // u("open decisions not read")),inbox_unhandled:$inbox}
    }'
}

heartbeat_collect_tasks() {
  local line row
  jq -c '.tasks[]?' "$SNAPSHOT_FILE" > "$HEARTBEAT_WORK/task-lines" 2>/dev/null || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$SECONDS" -ge "$FM_HEARTBEAT_DEADLINE" ]; then
      heartbeat_note_failure "deadline of ${FM_HEARTBEAT_DEADLINE}s hit before every task was read"
      return 0
    fi
    if row=$(heartbeat_task_row "$line" </dev/null); then
      printf '%s\n' "$row" >> "$HEARTBEAT_WORK/rows"
    else
      heartbeat_note_failure "a task row could not be assembled"
    fi
  done < "$HEARTBEAT_WORK/task-lines"
}

# Rows the run did not finish come from the snapshot with every read unknown, so
# a stopped run still lists each task it was told about.
heartbeat_publish() {
  local snapshot_meta tmp=$HEARTBEAT_WORK/heartbeat.json
  if [ "$SNAPSHOT_OK" = true ]; then
    snapshot_meta=$(jq -c '{ok:true,schema:.schema,generated:(.generated // null),failure:null}' "$SNAPSHOT_FILE")
    jq -s --slurpfile snapshot "$SNAPSHOT_FILE" '
      def u: {unknown:true,reason:"heartbeat stopped before this task was read"};
      . as $rows | ($rows | map(.id)) as $seen
      | ($snapshot[0].tasks // [])
      | map(select(.id as $id | $seen | index($id) | not)
        | {id:.id,terminal:u,session:u,last_turn:u,composer_state:"unknown",context_left:u,
           stage:{state:(.current_state.state // "unknown"),source:(.current_state.source // "unknown"),detail:(.current_state.detail // null)},
           last_commit:u,last_push:u,pr_head:u,no_mistakes_run:u,last_output_time:u,
           open_asks:{decisions:u,inbox_unhandled:u}})
      | ($rows + .) | sort_by(.id)
    ' "$HEARTBEAT_WORK/rows" > "$HEARTBEAT_WORK/tasks" 2>/dev/null || printf '[]\n' > "$HEARTBEAT_WORK/tasks"
  else
    snapshot_meta=$(jq -n --arg reason "${HEARTBEAT_SNAPSHOT_FAILURE:-snapshot not read}" \
      '{ok:false,schema:null,generated:null,failure:{reason:$reason}}')
    printf '[]\n' > "$HEARTBEAT_WORK/tasks"
  fi
  if jq -n \
    --arg generated "$HEARTBEAT_NOW" \
    --argjson generated_epoch "$HEARTBEAT_EPOCH" \
    --arg fm_home "$FM_HOME" \
    --argjson snapshot "$snapshot_meta" \
    --argjson primary "$PRIMARY_JSON" \
    --slurpfile tasks "$HEARTBEAT_WORK/tasks" \
    --rawfile failures "$HEARTBEAT_WORK/failures" \
    '($failures | split("\n") | map(select(. != ""))) as $f
    | {schema:"fm-heartbeat.v1",generated:$generated,generated_epoch:$generated_epoch,fm_home:$fm_home,
       snapshot:$snapshot,primary:$primary,tasks:$tasks[0],
       failure:(if ($f | length) == 0 then null else {reason:($f[:10] | join("; ")),count:($f | length)} end)}' > "$tmp" \
    && chmod 600 "$tmp" \
    && mv -f "$tmp" "$LEDGER"; then
    return 0
  fi
  echo "fm-heartbeat: could not write $LEDGER" >&2
}

# shellcheck disable=SC2329 # Registered by the signal trap below.
heartbeat_on_signal() {
  trap '' TERM INT HUP
  heartbeat_note_failure "heartbeat stopped by a signal before every read finished"
  heartbeat_publish
  exit 0
}

if [ ! -d "$STATE" ]; then
  echo "fm-heartbeat: no state directory at $STATE; nothing published" >&2
  exit 0
fi
find "$STATE" -maxdepth 1 -type d -name '.heartbeat-work.*' -mmin +10 -exec rm -rf {} + 2>/dev/null || true
HEARTBEAT_WORK=$(mktemp -d "$STATE/.heartbeat-work.XXXXXX" 2>/dev/null) || {
  echo "fm-heartbeat: cannot create a work directory in $STATE; nothing published" >&2
  exit 0
}
trap 'rm -rf "$HEARTBEAT_WORK"' EXIT
: > "$HEARTBEAT_WORK/failures"
: > "$HEARTBEAT_WORK/rows"

SNAPSHOT_FILE=$HEARTBEAT_WORK/snapshot.json
SNAPSHOT_OK=false
HEARTBEAT_SNAPSHOT_FAILURE=
PRIMARY_JSON=$(jq -n '
  {unknown:true,reason:"primary session not read"} as $u
  | {terminal:$u,session:$u,last_turn:$u,composer_state:"unknown",context_left:$u}')
trap heartbeat_on_signal TERM INT HUP

if heartbeat_read_snapshot "$SNAPSHOT_FILE"; then
  if jq -e '.schema == "fm-fleet-snapshot.v1"' "$SNAPSHOT_FILE" >/dev/null 2>&1; then
    SNAPSHOT_OK=true
  else
    HEARTBEAT_SNAPSHOT_FAILURE='snapshot returned malformed JSON'
  fi
fi
[ "$SNAPSHOT_OK" = true ] || heartbeat_note_failure "snapshot: ${HEARTBEAT_SNAPSHOT_FAILURE:-read failed}"

if primary=$(heartbeat_primary_json); then
  PRIMARY_JSON=$primary
else
  heartbeat_note_failure "primary session row could not be assembled"
fi
[ "$SNAPSHOT_OK" != true ] || heartbeat_collect_tasks

trap '' TERM INT HUP
heartbeat_publish
exit 0
