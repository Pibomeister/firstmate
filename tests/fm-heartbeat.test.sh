#!/usr/bin/env bash
# Behavioral coverage for bin/fm-heartbeat.sh: snapshot-backed assembly, atomic
# --write publication, explicit unknowns, the failure field, bounded reads, stopped
# runs, and detached single-flight watcher publication.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HEARTBEAT="$ROOT/bin/fm-heartbeat.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-heartbeat)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
WATCH_PID=

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

cleanup() {
  [ -z "$WATCH_PID" ] || kill -KILL "$WATCH_PID" >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT

unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION REX_SESSION REX_BLOCK TERM_PROGRAM \
  FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND FM_BACKEND
export PATH="$FAKEBIN:$PATH"
export CLAUDE_CONFIG_DIR="$TMP_ROOT/claude"

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
[ "${FAKE_TMUX_MODE:-}" != hang ] || sleep 30
case "${1:-}" in
  display-message) printf '%1\n' ;;
  list-panes) [ "${FAKE_TMUX_MODE:-}" = gone ] || printf '%%1\n' ;;
  capture-pane) printf 'fixture pane\n%s\n> \n' "${FAKE_PANE_TEXT:-}" ;;
esac
exit 0
SH
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ -z "${FAKE_NM_MARKER:-}" ] || : > "$FAKE_NM_MARKER"
if [ "${1:-}" = daemon ]; then
  case "${FAKE_NM_DAEMON:-up}" in
    up) printf '● daemon running\n' ;;
    stopped) printf '○ daemon not running\n' ;;
    refused) exit 1 ;;
    hang) sleep 30 ;;
  esac
  exit 0
fi
head=${FAKE_NM_HEAD:-abc1234}
if [ "$#" = 1 ] && [ "$1" = axi ]; then
  [ -z "${FAKE_NM_OVERVIEW_FAIL:-}" ] || exit 1
  case "${FAKE_NM_MODE:-none}" in
    run) rows="01RUN,fm/hb-task,running,$head,\"\"" ;;
    sibling) rows="01RUN,${FAKE_NM_SIBLING:-fm/older-sibling},running,$head,\"\"" ;;
    terminal) rows="01OLD,fm/hb-task,completed,$head,\"\"" ;;
    parked) rows="01OLD,fm/hb-task,running,$head,\"\"" ;;
    newer-failed) rows="01NEW,fm/hb-task,failed,$head,\"\"
01RUN,fm/hb-task,running,$head,\"\"" ;;
    competing) rows="01NEW,fm/hb-task,running,$head,\"\"
01RUN,fm/hb-task,running,$head,\"\"" ;;
  esac
  count=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
  printf 'count: %s of %s total\nruns[%s]{id,branch,status,head,pr}:\n' "$count" "$count" "$count"
  printf '%s\n' "$rows" | sed 's/^/  /'
  exit 0
fi
detail_mode=${FAKE_NM_MODE:-none}
case "$detail_mode" in newer-failed|competing) detail_mode=run ;; esac
if [ "${4:-}" = 01NEW ]; then detail_mode=newer-detail; fi
if [ "${3:-}" = --run ] && [ -n "${FAKE_NM_RUN_FAIL:-}" ]; then exit 1; fi
case "$detail_mode" in
  none)
    printf 'current_branch: fm/hb-task\nruns_on_current_branch: 0\n'
    ;;
  run|sibling)
    branch=fm/hb-task
    [ "$detail_mode" = run ] || branch=${FAKE_NM_SIBLING:-fm/older-sibling}
    cat <<EOF
run:
  id: "01RUN"
  branch: $branch
  status: running
  head: "$head"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
  active_steps[1]{step,active_for,last_activity,agent_pid,round}:
    review,1m,now,123,1
EOF
    [ -z "${FAKE_NM_SYNC:-}" ] || printf 'branch_sync:\n  state: %s\n' "$FAKE_NM_SYNC"
    ;;
  terminal)
    printf 'run:\n  id: "01OLD"\n  branch: fm/hb-task\n  status: completed\n  head: "%s"\n' "$head"
    ;;
  parked)
    printf 'run:\n  id: "01OLD"\n  branch: fm/hb-task\n  status: running\n  awaiting_agent: parked 1h\n  head: "%s"\n' "$head"
    ;;
  newer-detail)
    printf 'run:\n  id: "01NEW"\n  branch: fm/hb-task\n  status: failed\n  head: "%s"\n' "$head"
    ;;
  ungated)
    printf "error: repo not initialized (run 'no-mistakes init' first)\n"
    exit 1
    ;;
  fail) echo 'daemon unreachable' >&2; exit 1 ;;
  hang) sleep 30 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/no-mistakes"

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects/ship"
  printf '# fixture home\n' > "$home/AGENTS.md"
  fm_git_init_commit "$home/projects/ship"
  git -C "$home/projects/ship" checkout -q -b fm/hb-task
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] hb-task - heartbeat fixture (repo: firstmate) (kind: ship) (since 2026-10-30)

## Queued

## Done
EOF
  fm_write_meta "$home/state/hb-task.meta" \
    "window=fmtest:hb" \
    "worktree=$home/projects/ship" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "branch=fm/hb-task" \
    "spawn_gen=s1000000000.1.1"
  printf 'working: fixture\n' > "$home/state/hb-task.status"
  printf '%s\n' "$home"
}

# The ledger is the script's persisted public output.
ledger() {  # <home>
  printf '%s\n' "$1/state/heartbeat.json"
}

publish() {  # <home> [ENV=value...]
  local home=$1
  shift
  env FM_HOME="$home" "$@" "$HEARTBEAT" --write || fail "heartbeat --write failed"
}

assert_ledger() {  # <home> <jq-filter> <message>
  jq -e "$2" "$(ledger "$1")" >/dev/null \
    || fail "$3: $(cat "$(ledger "$1")" 2>/dev/null)"
}

assert_no_work_left() {  # <home>
  local left
  left=$(find "$1/state" -maxdepth 1 -name '.heartbeat*' 2>/dev/null)
  [ -z "$left" ] || fail "temp files leaked: $left"
}

# Canned snapshot with two live-worktree tasks, so read-failure cases do not also
# wait for the real snapshot's bounded no-mistakes reads.
canned_snapshot() {  # <home>
  local home=$1 script="$1/canned-snapshot.sh"
  jq -n --arg wt "$home/projects/ship" '{schema:"fm-fleet-snapshot.v1",generated:"2026-10-30T12:00:00Z",
    tasks:[{id:"task-a",branch:"fm/hb-task",harness:"claude",backend:"tmux",paths:{worktree:{path:$wt}}},
           {id:"task-b",branch:"fm/hb-task",harness:"codex",backend:"tmux",paths:{worktree:{path:$wt}}}]}' \
    > "$home/canned-snapshot.json"
  cat > "$script" <<SH
#!/usr/bin/env bash
cat "$home/canned-snapshot.json"
SH
  chmod +x "$script"
  printf '%s\n' "$script"
}

set_spawn_gen() {  # <home> <value-or-empty>
  local meta="$1/state/hb-task.meta"
  grep -v '^spawn_gen=' "$meta" > "$meta.next"
  [ -z "$2" ] || printf 'spawn_gen=%s\n' "$2" >> "$meta.next"
  mv "$meta.next" "$meta"
}

task_transcript() {  # <home> -> transcript path for the fixture worktree
  local slug
  slug=$(printf '%s' "$1/projects/ship" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')
  mkdir -p "$CLAUDE_CONFIG_DIR/projects/$slug"
  printf '%s\n' "$CLAUDE_CONFIG_DIR/projects/$slug/sess-task.jsonl"
}

wait_for_file() {  # <path> <seconds>
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt $(( $2 * 10 )) ]; do
    command -p sleep 0.1
    i=$((i + 1))
  done
  [ -e "$1" ]
}

test_ledger_schema_and_clean_run() {
  local home
  home=$(make_home clean)
  publish "$home" FM_HEARTBEAT_NOW=2026-10-30T12:00:00Z
  assert_ledger "$home" '
    .schema == "fm-heartbeat.v1"
    and .generated == "2026-10-30T12:00:00Z"
    and .snapshot.ok == true
    and .failure == null
    and (.tasks | length) == 1
    and .tasks[0].id == "hb-task"
    and (.tasks[0].stage.state | type) == "string"
    and (.tasks[0].last_commit.sha | type) == "string"
    and .tasks[0].no_mistakes_run == null
    and .tasks[0].terminal.target == "fmtest:hb"
    and (.tasks[0].composer_state | type) == "string"
    and .tasks[0].session.unknown == true
    and .tasks[0].last_turn.unknown == true
    and .tasks[0].context_left.used_tokens.unknown == true
  ' "clean run ledger is wrong"
  assert_no_work_left "$home"
  [ "$(stat -f %Lp "$(ledger "$home")" 2>/dev/null || stat -c %a "$(ledger "$home")")" = 600 ] \
    || fail "ledger is not mode 600"
  pass "--write publishes every field atomically with a null failure on a clean run"
}

test_no_mistakes_run_is_parsed_from_real_status() {
  local home
  home=$(make_home nm-run)
  publish "$home" FAKE_NM_MODE=run
  assert_ledger "$home" '.tasks[0].no_mistakes_run == {run_id:"01RUN",step:"review",active:true}' \
    "active run was not published"
  publish "$home" FAKE_NM_MODE=sibling
  assert_ledger "$home" '.tasks[0].no_mistakes_run == null' \
    "a run on another branch was attributed to this task"
  pass "no_mistakes_run reads the real status shape and refuses a sibling branch's run"
}

test_selection_owner_decides_the_run() {
  local home head
  home=$(make_home nm-select)
  head=$(git -C "$home/projects/ship" rev-parse HEAD)
  publish "$home" FAKE_NM_MODE=newer-failed "FAKE_NM_HEAD=$head"
  assert_ledger "$home" '.tasks[0].no_mistakes_run == {run_id:"01NEW",step:null,active:false}' \
    "an older live run hid a newer failure"
  publish "$home" FAKE_NM_MODE=competing "FAKE_NM_HEAD=$head"
  assert_ledger "$home" '
    (.tasks[0].no_mistakes_run.reason | test("competing live runs"))
    and (.failure.reason | test("competing live runs"))
  ' "competing live runs were not reported as unknown"
  publish "$home" FAKE_NM_MODE=run FAKE_NM_OVERVIEW_FAIL=1
  assert_ledger "$home" '.tasks[0].no_mistakes_run.unknown == true and (.failure.reason | test("overview exit"))' \
    "a failed overview read was not unknown with a failure"
  publish "$home" FAKE_NM_MODE=run FAKE_NM_RUN_FAIL=1
  assert_ledger "$home" '.tasks[0].no_mistakes_run.unknown == true and (.failure.reason | test("01RUN unreadable"))' \
    "a failed selected-run read was not unknown with a failure"
  pass "fm_nm_select_run chooses the run, and an unusable choice reads as unknown"
}

test_run_head_check_is_bounded() {
  local home head real_git fake
  home=$(make_home nm-head-bound)
  head=$(git -C "$home/projects/ship" rev-parse HEAD)
  git -C "$home/projects/ship" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m next
  real_git=$(command -v git)
  fake="$TMP_ROOT/hanging-git"
  mkdir -p "$fake"
  cat > "$fake/git" <<SH
#!/usr/bin/env bash
case "\$*" in *merge-base*) sleep 30 ;; esac
exec "$real_git" "\$@"
SH
  chmod +x "$fake/git"
  publish "$home" FAKE_NM_MODE=terminal "FAKE_NM_HEAD=$head" FM_HEARTBEAT_READ_TIMEOUT=1 "PATH=$fake:$PATH"
  assert_ledger "$home" '.tasks[0].no_mistakes_run.unknown == true and (.failure.reason | test("run head timed out"))' \
    "a hung head check was not bounded and recorded"
  pass "a hung run head check is bounded, unknown, and sets failure"
}

test_worktree_off_recorded_branch_is_unknown() {
  local home real_git fake script
  home=$(make_home nm-moved)
  git -C "$home/projects/ship" checkout -q -b fm/hb-other
  publish "$home" FAKE_NM_MODE=sibling FAKE_NM_SIBLING=fm/hb-other
  assert_ledger "$home" '
    .tasks[0].no_mistakes_run.unknown == true
    and (.tasks[0].no_mistakes_run.reason | test("fm/hb-other") and test("fm/hb-task"))
  ' "a moved worktree published a confident run value"

  home=$(make_home nm-detached)
  git -C "$home/projects/ship" checkout -q --detach
  publish "$home" FAKE_NM_MODE=run
  assert_ledger "$home" '.tasks[0].no_mistakes_run == {run_id:"01RUN",step:"review",active:true} and .failure == null' \
    "a detached worktree did not keep the selection path"

  real_git=$(command -v git)
  fake="$TMP_ROOT/branch-git"
  mkdir -p "$fake"
  cat > "$fake/git" <<SH
#!/usr/bin/env bash
case "\$*" in
  *symbolic-ref*)
    [ "\${FAKE_GIT_BRANCH:-}" != hang ] || sleep 30
    exit 128
    ;;
esac
exec "$real_git" "\$@"
SH
  chmod +x "$fake/git"
  home=$(make_home nm-branch-unread)
  script=$(canned_snapshot "$home")
  publish "$home" FAKE_NM_MODE=run FM_HEARTBEAT_SNAPSHOT_SCRIPT="$script" "PATH=$fake:$PATH"
  assert_ledger "$home" '
    .tasks[0].no_mistakes_run == {unknown:true,reason:"worktree branch unread"}
    and (.failure.reason | test("worktree branch unreadable"))
  ' "a failed branch read was treated as a match"
  publish "$home" FAKE_NM_MODE=run FM_HEARTBEAT_SNAPSHOT_SCRIPT="$script" \
    FAKE_GIT_BRANCH=hang FM_HEARTBEAT_READ_TIMEOUT=1 "PATH=$fake:$PATH"
  assert_ledger "$home" '
    .tasks[0].no_mistakes_run == {unknown:true,reason:"worktree branch unread"}
    and (.failure.reason | test("worktree branch timed out"))
  ' "a hung branch read was treated as a match"
  pass "a worktree off its recorded branch or with an unread branch reads as unknown"
}

test_settled_run_binds_only_on_worktree_head() {
  local home head mode
  home=$(make_home nm-settled)
  head=$(git -C "$home/projects/ship" rev-parse HEAD)
  for mode in terminal parked; do
    publish "$home" FAKE_NM_MODE=$mode
    assert_ledger "$home" '.tasks[0].no_mistakes_run.unknown == true' \
      "a stale $mode run on a reused branch was attributed"
  done
  publish "$home" FAKE_NM_MODE=terminal "FAKE_NM_HEAD=$head"
  assert_ledger "$home" '.tasks[0].no_mistakes_run == {run_id:"01OLD",step:null,active:false}' \
    "a terminal run at the worktree head was not published"
  publish "$home" FAKE_NM_MODE=parked "FAKE_NM_HEAD=$head"
  assert_ledger "$home" '.tasks[0].no_mistakes_run == {run_id:"01OLD",step:null,active:true}' \
    "a parked run at the worktree head was not published"
  pass "a terminal or parked run binds only through the worktree head"
}

test_daemon_answer_qualifies_executing_run() {
  local home head answer
  home=$(make_home nm-daemon)
  head=$(git -C "$home/projects/ship" rev-parse HEAD)
  for answer in stopped refused; do
    publish "$home" FAKE_NM_MODE=run "FAKE_NM_DAEMON=$answer"
    assert_ledger "$home" '.tasks[0].no_mistakes_run.unknown == true' \
      "daemon $answer: a stale executing record was attributed"
    publish "$home" FAKE_NM_MODE=run "FAKE_NM_DAEMON=$answer" "FAKE_NM_HEAD=$head"
    assert_ledger "$home" '.tasks[0].no_mistakes_run | .run_id == "01RUN" and .active.unknown == true' \
      "daemon $answer: a matching record claimed a live run"
  done
  publish "$home" FAKE_NM_MODE=run FAKE_NM_DAEMON=stopped FAKE_NM_SYNC=pipeline_owned
  assert_ledger "$home" '.tasks[0].no_mistakes_run | .run_id == "01RUN" and .active.unknown == true' \
    "a pipeline-owned run did not bind with an unknown live claim"
  publish "$home" FAKE_NM_MODE=run FAKE_NM_DAEMON=hang FM_HEARTBEAT_NM_TIMEOUT=1
  assert_ledger "$home" '
    .tasks[0].no_mistakes_run == {run_id:"01RUN",step:"review",active:true}
    and (.failure.reason | test("daemon status timed out"))
  ' "an unanswered probe dropped a live run or left failure null"
  publish "$home" FAKE_NM_MODE=parked "FAKE_NM_HEAD=$head" FAKE_NM_DAEMON=stopped
  assert_ledger "$home" '.tasks[0].no_mistakes_run | .run_id == "01OLD" and .active.unknown == true' \
    "a parked run claimed to be live with its daemon down"
  pass "only an answered daemon-down suppresses an active run's live claim"
}

test_failed_status_is_unknown_not_no_run() {
  local home script
  home=$(make_home nm-fail)
  script=$(canned_snapshot "$home")
  publish "$home" FAKE_NM_MODE=fail FM_HEARTBEAT_SNAPSHOT_SCRIPT="$script"
  assert_ledger "$home" '
    .tasks[0].no_mistakes_run.unknown == true
    and (.failure.reason | test("no-mistakes status exit"))
    and .tasks[0].open_asks.decisions.unknown == true
    and .tasks[0].open_asks.inbox_unhandled.unknown == true
    and .tasks[0].pr_head == null
  ' "failed status did not read as unknown with a failure"
  pass "a failed no-mistakes read is unknown and sets failure"
}

test_transcript_fields_with_fractional_timestamps() {
  local home project line
  home=$(make_home transcript)
  line='{"type":"assistant","timestamp":"2026-10-30T11:59:00.123Z","message":{"usage":{"input_tokens":90000}}}'
  printf 'sess-primary\n' > "$home/state/.lock-session"
  project="$CLAUDE_CONFIG_DIR/projects/primary-project"
  mkdir -p "$project"
  printf '%s\n' "$line" > "$project/sess-primary.jsonl"
  printf '%s\n' "$line" > "$(task_transcript "$home")"
  publish "$home" FM_HEARTBEAT_NOW=2026-10-30T12:00:00Z
  assert_ledger "$home" '
    .primary.session.trusted_id == "sess-primary"
    and .primary.last_turn.age_seconds == 60
    and .primary.last_turn.observed_at == "2026-10-30T11:59:00.123Z"
    and .primary.context_left.used_tokens == 90000
    and .primary.context_left.remaining.unknown == true
    and .tasks[0].session.id == "sess-task"
    and .tasks[0].last_turn.age_seconds == 60
    and .tasks[0].context_left.used_tokens == 90000
    and .tasks[0].last_output_time.source == "transcript"
  ' "transcript facts were not read"
  pass "real fractional transcripts give last turn and used tokens, with remaining unknown"
}

test_leftover_transcript_in_a_reused_slot_is_ignored() {
  local home transcript now
  home=$(make_home reused-slot)
  now=$(date +%s)
  transcript=$(task_transcript "$home")
  printf '%s\n' '{"type":"assistant","timestamp":"2026-10-30T11:59:00.123Z","message":{"usage":{"input_tokens":90000}}}' > "$transcript"
  fm_touch_epoch "$(( now - 3600 ))" "$transcript"
  set_spawn_gen "$home" "s$now.1.1"
  publish "$home"
  assert_ledger "$home" '.tasks[0].session.unknown == true
    and .tasks[0].last_turn.unknown == true
    and .tasks[0].context_left.used_tokens.unknown == true
    and .tasks[0].last_output_time.unknown == true' \
    "a transcript older than the spawn was attributed to this task"
  set_spawn_gen "$home" "s$(( now - 7200 )).1.1"
  publish "$home"
  assert_ledger "$home" '.tasks[0].session.id == "sess-task"' \
    "a transcript written since the spawn was not read"
  set_spawn_gen "$home" ""
  publish "$home"
  assert_ledger "$home" '.tasks[0].session.unknown == true' \
    "a transcript was attributed with no spawn epoch"
  pass "a transcript older than the spawn, or with no spawn epoch, fills no field"
}

test_remaining_context_comes_from_pane_text() {
  local home script
  home=$(make_home pane-context)
  script=$(canned_snapshot "$home")
  jq '.tasks[0].endpoint = {target:"fmtest:hb",exists:true}' "$home/canned-snapshot.json" > "$home/live.json"
  mv "$home/live.json" "$home/canned-snapshot.json"
  publish "$home" FAKE_PANE_TEXT='  12% until auto-compact' FM_HEARTBEAT_SNAPSHOT_SCRIPT="$script" \
    FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=%1
  assert_ledger "$home" '.primary.context_left.remaining == {percent:12,source:"terminal"}
    and .tasks[0].context_left.remaining == {percent:12,source:"terminal"}
    and .tasks[1].context_left.remaining.unknown == true' \
    "pane context text was not read"
  publish "$home" FAKE_PANE_TEXT='Context left until auto-compact: 7%' FM_HEARTBEAT_SNAPSHOT_SCRIPT="$script" \
    FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=%1
  assert_ledger "$home" '.tasks[0].context_left.remaining.percent == 7' \
    "the other harness wording was not read"
  publish "$home" FM_HEARTBEAT_SNAPSHOT_SCRIPT="$script" FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=%1
  assert_ledger "$home" '.tasks[0].context_left.remaining.unknown == true' \
    "a pane with no context text did not read as unknown"
  publish "$home" FAKE_PANE_TEXT=$'a mate quoted 3% until auto-compact\none\ntwo\nthree\nfour' \
    FM_HEARTBEAT_SNAPSHOT_SCRIPT="$script" FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=%1
  assert_ledger "$home" '.tasks[0].context_left.remaining.unknown == true' \
    "text quoted above the harness status was read as context"
  pass "remaining context comes from the harness's own pane text, else unknown"
}

test_ungated_repo_is_unknown_not_failure() {
  local home script
  home=$(make_home ungated)
  script=$(canned_snapshot "$home")
  publish "$home" FAKE_NM_MODE=ungated FM_HEARTBEAT_SNAPSHOT_SCRIPT="$script"
  assert_ledger "$home" '.tasks[0].no_mistakes_run == {unknown:true,reason:"repo has no gate"}
    and .failure == null' "an ungated repo was recorded as a failure"
  pass "an ungated repo is unknown with no failure"
}

test_last_output_needs_real_activity() {
  local home
  home=$(make_home last-output)
  touch "$home/state/hb-task.meta" "$home/state/hb-task.status" "$home/state/hb-task.turn-ended"
  publish "$home"
  assert_ledger "$home" '.tasks[0].last_output_time.unknown == true' \
    "meta, status, or turn-ended counted as output"
  printf 'abc' > "$home/state/.hash-fmtest_hb"
  publish "$home"
  assert_ledger "$home" '.tasks[0].last_output_time.source == "terminal"' \
    "the pane-change marker was not read as output"
  pass "last output comes from terminal evidence, never .meta, .status, or .turn-ended"
}

test_leftover_terminal_marker_is_ignored() {
  local home now
  home=$(make_home leftover-marker)
  now=$(date +%s)
  printf 'abc' > "$home/state/.hash-fmtest_hb"
  fm_touch_epoch "$(( now - 3600 ))" "$home/state/.hash-fmtest_hb"
  set_spawn_gen "$home" "s$now.1.1"
  publish "$home"
  assert_ledger "$home" '.tasks[0].last_output_time.unknown == true' \
    "a marker older than the spawn counted as output"
  set_spawn_gen "$home" "s$(( now - 7200 )).1.1"
  publish "$home"
  assert_ledger "$home" '.tasks[0].last_output_time.source == "terminal"' \
    "a marker written since the spawn was not read"
  set_spawn_gen "$home" ""
  publish "$home"
  assert_ledger "$home" '.tasks[0].last_output_time.unknown == true' \
    "a marker counted as output with no spawn epoch"
  pass "a terminal marker older than the spawn, or with no spawn epoch, is not output"
}

test_secondmate_frozen_marker_is_ignored() {
  local home script transcript now
  home=$(make_home secondmate-marker)
  script=$(canned_snapshot "$home")
  now=$(date +%s)
  jq --arg gen "s$(( now - 7200 )).1.1" '.tasks = [.tasks[0] + {kind:"secondmate",spawn_gen:$gen,endpoint:{target:"fmtest:sm",exists:false}}]' \
    "$home/canned-snapshot.json" > "$home/secondmate.json"
  mv "$home/secondmate.json" "$home/canned-snapshot.json"
  printf 'abc' > "$home/state/.hash-fmtest_sm"
  publish "$home" FM_HEARTBEAT_SNAPSHOT_SCRIPT="$script"
  assert_ledger "$home" '.tasks[0].last_output_time.unknown == true' \
    "a secondmate's frozen marker counted as output"
  transcript=$(task_transcript "$home")
  printf '%s\n' '{"type":"assistant","timestamp":"2026-10-30T11:59:00.123Z"}' > "$transcript"
  publish "$home" FM_HEARTBEAT_SNAPSHOT_SCRIPT="$script"
  assert_ledger "$home" '.tasks[0].last_output_time.source == "transcript"' \
    "a secondmate's qualifying transcript was not read"
  pass "a secondmate's marker is ignored and its transcript still qualifies"
}

test_missing_primary_endpoint_skips_pane_read() {
  local home script
  home=$(make_home primary-gone)
  script=$(canned_snapshot "$home")
  jq '.tasks = []' "$home/canned-snapshot.json" > "$home/empty.json"
  mv "$home/empty.json" "$home/canned-snapshot.json"
  publish "$home" FAKE_TMUX_MODE=gone FAKE_PANE_TEXT='12% until auto-compact' FM_HEARTBEAT_SNAPSHOT_SCRIPT="$script" \
    FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=%1
  assert_ledger "$home" '.primary.terminal.present == false
    and .primary.context_left.remaining.unknown == true' \
    "a missing primary endpoint still had its pane read for context"
  pass "a missing primary endpoint gets no pane context read"
}

test_last_push_names_the_local_ref() {
  local home sha
  home=$(make_home last-push)
  sha=$(git -C "$home/projects/ship" rev-parse HEAD)
  publish "$home"
  assert_ledger "$home" '.tasks[0].last_push.unknown == true' "no ref should be unknown"
  git -C "$home/projects/ship" update-ref refs/remotes/origin/fm/hb-task "$sha"
  publish "$home"
  assert_ledger "$home" '.tasks[0].last_push.ref == "origin/fm/hb-task"' "origin ref not reported"
  git -C "$home/projects/ship" update-ref refs/remotes/no-mistakes/fm/hb-task "$sha"
  publish "$home"
  assert_ledger "$home" '.tasks[0].last_push.ref == "no-mistakes/fm/hb-task"' "gate ref not preferred"
  pass "last_push reads local gate and origin refs and names the source"
}

test_snapshot_failure_is_recorded() {
  local home
  home=$(make_home snap-fail)
  publish "$home" FM_SNAPSHOT_BUDGET=0
  assert_ledger "$home" '.snapshot.ok == false and .snapshot.failure.reason != null
    and (.tasks | length) == 0 and (.failure.reason | test("snapshot"))' \
    "snapshot failure was not recorded"
  pass "a failed snapshot read sets failure without guessing task rows"
}

test_unreadable_fields_report_unknown() {
  local home
  home=$(make_home unknown-fields)
  fm_write_meta "$home/state/no-wt.meta" \
    "window=fmtest:nwt" \
    "worktree=$home/projects/missing-tree" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "spawn_gen=fm.hb999999"
  printf 'working: no worktree\n' > "$home/state/no-wt.status"
  publish "$home"
  assert_ledger "$home" '
    (.tasks[] | select(.id == "no-wt") | .last_commit.unknown) == true
    and (.tasks[] | select(.id == "no-wt") | .last_push.unknown) == true
    and (.tasks[] | select(.id == "no-wt") | .no_mistakes_run.unknown) == true
    and .primary.last_turn.unknown == true
    and .primary.session.trusted_id.unknown == true
  ' "unreadable fields did not report unknown"
  pass "unreadable task and primary fields stay explicitly unknown"
}

test_slow_snapshot_is_bounded() {
  local home slow started elapsed
  home=$(make_home slow-snap)
  slow="$TMP_ROOT/slow-snapshot.sh"
  cat > "$slow" <<'SH'
#!/usr/bin/env bash
sleep 120
exit 0
SH
  chmod +x "$slow"
  started=$(date +%s)
  publish "$home" FM_HEARTBEAT_SNAPSHOT_TIMEOUT=1 FM_HEARTBEAT_SNAPSHOT_SCRIPT="$slow"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 8 ] || fail "heartbeat waited ${elapsed}s for a slow snapshot"
  assert_ledger "$home" '.snapshot.ok == false and (.failure.reason | test("timed out"))' \
    "slow snapshot did not record failure"
  pass "a slow snapshot read is bounded and recorded as failure"
}

test_hung_primary_reads_are_bounded() {
  local home script started elapsed
  home=$(make_home hung-primary)
  script=$(canned_snapshot "$home")
  jq '.tasks = []' "$home/canned-snapshot.json" > "$home/empty.json"
  mv "$home/empty.json" "$home/canned-snapshot.json"
  started=$(date +%s)
  publish "$home" FAKE_TMUX_MODE=hang FM_HEARTBEAT_READ_TIMEOUT=1 FM_HEARTBEAT_SNAPSHOT_SCRIPT="$script" \
    FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=%1
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 15 ] || fail "hung primary reads took ${elapsed}s"
  assert_ledger "$home" '.primary.terminal.present.unknown == true
    and .primary.composer_state == "unknown"
    and (.failure.reason | test("primary terminal timed out"))' \
    "hung primary read was not reported"
  pass "each hung primary read has its own bound and sets failure"
}

test_deadline_publishes_unread_tasks_as_unknown() {
  local home script
  home=$(make_home deadline)
  script=$(canned_snapshot "$home")
  publish "$home" FAKE_NM_MODE=hang FM_HEARTBEAT_NM_TIMEOUT=2 FM_HEARTBEAT_DEADLINE=1 \
    FM_HEARTBEAT_SNAPSHOT_SCRIPT="$script"
  assert_ledger "$home" '(.tasks | map(.id)) == ["task-a","task-b"]
    and (.tasks[1].last_commit.reason | test("stopped before"))
    and (.failure.reason | test("deadline"))' \
    "deadline did not publish unknown rows"
  assert_no_work_left "$home"
  pass "a run past its deadline publishes unread tasks as unknown"
}

test_term_during_snapshot_still_publishes() {
  local home slow marker pid
  home=$(make_home term-snap)
  marker="$TMP_ROOT/term-snap.started"
  slow="$TMP_ROOT/term-slow-snapshot.sh"
  cat > "$slow" <<SH
#!/usr/bin/env bash
: > "$marker"
sleep 120
SH
  chmod +x "$slow"
  FM_HOME="$home" FM_HEARTBEAT_SNAPSHOT_TIMEOUT=5 FM_HEARTBEAT_SNAPSHOT_SCRIPT="$slow" "$HEARTBEAT" --write &
  pid=$!
  wait_for_file "$marker" 10 || fail "slow snapshot never started"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_ledger "$home" '.snapshot.ok == false and (.failure.reason | test("signal"))
    and .primary.terminal.unknown == true' "a stopped run did not publish its state"
  assert_no_work_left "$home"
  pass "TERM during the snapshot read publishes unknown markers and leaks no temp files"
}

test_term_during_task_read_still_publishes() {
  local home script marker pid
  home=$(make_home term-task)
  script=$(canned_snapshot "$home")
  marker="$TMP_ROOT/term-task.started"
  FM_HOME="$home" FAKE_NM_MODE=hang FAKE_NM_MARKER="$marker" FM_HEARTBEAT_NM_TIMEOUT=2 \
    FM_HEARTBEAT_SNAPSHOT_SCRIPT="$script" "$HEARTBEAT" --write &
  pid=$!
  wait_for_file "$marker" 20 || fail "task read never started"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_ledger "$home" '(.tasks | map(.id)) == ["task-a","task-b"]
    and (.tasks[1].last_commit.reason | test("stopped before"))
    and (.failure.reason | test("signal"))' "a stopped run lost its task list"
  assert_no_work_left "$home"
  pass "TERM during a task read publishes the whole task list with unknown markers"
}

test_stale_work_dir_is_swept() {
  local home stale
  home=$(make_home sweep)
  stale="$home/state/.heartbeat-work.killed"
  mkdir "$stale"
  fm_touch_epoch "$(( $(date +%s) - 3600 ))" "$stale"
  publish "$home"
  assert_no_work_left "$home"
  pass "the next run removes what a SIGKILLed run left"
}

test_watcher_poll_does_not_wait_for_heartbeat() {
  local home slow rc
  home=$(make_home watch-slow)
  slow="$TMP_ROOT/watch-slow-snapshot.sh"
  cat > "$slow" <<'SH'
#!/usr/bin/env bash
sleep 120
exit 0
SH
  chmod +x "$slow"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_HEARTBEAT_SNAPSHOT_TIMEOUT=60 FM_HEARTBEAT_SNAPSHOT_SCRIPT="$slow" \
    FM_WATCH_ONCE=1 \
    "$WATCH" > "$TMP_ROOT/watch-slow.out" 2> "$TMP_ROOT/watch-slow.err" &
  WATCH_PID=$!
  wait "$WATCH_PID"; rc=$?
  WATCH_PID=
  [ "$rc" -eq 0 ] || fail "watcher poll exited $rc: $(cat "$TMP_ROOT/watch-slow.err")"
  [ ! -e "$(ledger "$home")" ] || fail "the poll waited for the heartbeat to publish"
  [ -e "$home/state/.last-watcher-beat" ] || fail "watcher never advanced its liveness beacon"
  pass "a watcher poll does not wait for a slow heartbeat"
}

test_watcher_runs_one_heartbeat_at_a_time() {
  local home slow runs count
  home=$(make_home watch-single)
  rm -f "$home/state/hb-task.meta" "$home/state/hb-task.status"
  runs="$TMP_ROOT/watch-single.runs"
  : > "$runs"
  slow="$TMP_ROOT/watch-single-snapshot.sh"
  cat > "$slow" <<SH
#!/usr/bin/env bash
echo started >> "$runs"
sleep 120
SH
  chmod +x "$slow"
  fm_test_track_watcher_state "$home/state"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_HEARTBEAT_SNAPSHOT_TIMEOUT=45 FM_HEARTBEAT_SNAPSHOT_SCRIPT="$slow" \
    "$WATCH" > "$TMP_ROOT/watch-single.out" 2> "$TMP_ROOT/watch-single.err" &
  WATCH_PID=$!
  wait_for_file "$home/state/.last-watcher-beat" 30 || fail "watcher never polled"
  rm -f "$home/state/.last-watcher-beat"
  wait_for_file "$home/state/.last-watcher-beat" 4 || fail "polls stopped while a heartbeat ran"
  rm -f "$home/state/.last-watcher-beat"
  wait_for_file "$home/state/.last-watcher-beat" 4 || fail "polls stopped while a heartbeat ran"
  count=$(wc -l < "$runs" | tr -d ' ')
  [ "$count" = 1 ] || fail "expected one heartbeat in flight, saw $count"
  kill -KILL "$WATCH_PID" 2>/dev/null
  wait "$WATCH_PID" 2>/dev/null
  WATCH_PID=
  wait_for_file "$home/state/heartbeat.json" 60 || fail "the bounded heartbeat never published"
  assert_ledger "$home" '.snapshot.ok == false and (.failure.reason | test("timed out"))' \
    "timed-out detached heartbeat published no failure"
  pass "the watcher keeps polling with one detached heartbeat in flight, which still publishes"
}

test_ledger_schema_and_clean_run
test_no_mistakes_run_is_parsed_from_real_status
test_selection_owner_decides_the_run
test_run_head_check_is_bounded
test_worktree_off_recorded_branch_is_unknown
test_settled_run_binds_only_on_worktree_head
test_daemon_answer_qualifies_executing_run
test_failed_status_is_unknown_not_no_run
test_transcript_fields_with_fractional_timestamps
test_leftover_transcript_in_a_reused_slot_is_ignored
test_remaining_context_comes_from_pane_text
test_ungated_repo_is_unknown_not_failure
test_last_output_needs_real_activity
test_leftover_terminal_marker_is_ignored
test_secondmate_frozen_marker_is_ignored
test_missing_primary_endpoint_skips_pane_read
test_last_push_names_the_local_ref
test_snapshot_failure_is_recorded
test_unreadable_fields_report_unknown
test_slow_snapshot_is_bounded
test_hung_primary_reads_are_bounded
test_deadline_publishes_unread_tasks_as_unknown
test_term_during_snapshot_still_publishes
test_term_during_task_read_still_publishes
test_stale_work_dir_is_swept
test_watcher_poll_does_not_wait_for_heartbeat
test_watcher_runs_one_heartbeat_at_a_time

printf 'ok - %s tests passed\n' 27
