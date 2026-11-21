#!/usr/bin/env bash
# tests/fm-fleet-ledger.test.sh - the opt-in fleet activity ledger, driven
# through the real producers: bin/fm-spawn.sh (fake tmux, real git worktree),
# the real watcher through bin/fm-watch-checkpoint.sh, bin/fm-pr-check.sh,
# bin/fm-merge-local.sh, the shared PR merge outcome in bin/fm-merge-outcome-lib.sh, and
# bin/fm-teardown.sh. docs/fleet-ledger.md owns the record contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fleet-ledger)

make_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
window_file="$(dirname "$0")/.spawn-window"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  list-windows) [ ! -s "$window_file" ] || cat "$window_file" ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    printf '%s\n' "$name" > "$window_file"
    ;;
  kill-window) : > "$window_file" ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse no-mistakes
  printf '%s\n' "$fakebin"
}

# Sets HOME_DIR PROJ_DIR WT_DIR FAKEBIN TASK for one isolated case.
make_case() {  # <name> <on|off>
  local dir="$TMP_ROOT/$1"
  HOME_DIR="$dir/home"
  PROJ_DIR="$dir/sample"
  TASK="$1-t1"
  WT_DIR="$dir/wt"
  mkdir -p "$HOME_DIR/data/$TASK" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/user-home"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
  touch "$HOME_DIR/state/.last-watcher-beat"
  [ "$2" = off ] || : > "$HOME_DIR/config/fleet-ledger"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "fm/$TASK"
  cat > "$HOME_DIR/data/$TASK/brief.md" <<EOF
# Task
## Captain's intent
Exercise the fleet ledger for $TASK.

## Firstmate spec
Nothing to build.
EOF
  FAKEBIN=$(make_fakebin "$dir")
}

in_home() {  # <command...>: run one real script against the case home
  env -u FM_TRACE_CONTEXT FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    HOME="$HOME_DIR/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_HOST_ID_OVERRIDE="${CASE_HOST_ID:-test-host-1}" PATH="$FAKEBIN:$PATH" "$@"
}

# Spawn, write status lines, poll once, land locally, clean up.
run_lifecycle() {
  local out
  out=$(in_home "$ROOT/bin/fm-spawn.sh" "$TASK" "$PROJ_DIR" --mode local-only --yolo off 2>&1) \
    || fail "spawn failed: $out"
  {
    printf 'working [at=1790000000]: setup done\n'
    printf 'needs-decision [key=pick-one]: choose "a"\\b or c\n'
    printf 'resolved: [key=pick-one]  chose a\n'
    printf 'partial line without its newline'
  } >> "$HOME_DIR/state/$TASK.status"
  out=$(in_home env FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 2>&1)
  case "$out" in *"checkpoint:"*|*"signal:"*) ;; *) fail "watcher checkpoint did not run: $out" ;; esac
  LEDGER_AFTER_POLL=$(cat "$HOME_DIR/state/fleet-ledger.jsonl" 2>/dev/null || true)
  printf ' finished\ndone: ready in branch\n' >> "$HOME_DIR/state/$TASK.status"
  printf 'landed\n' > "$WT_DIR/landed.txt"
  git -C "$WT_DIR" add landed.txt
  git -C "$WT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'landed'
  LANDED_HEAD=$(git -C "$WT_DIR" rev-parse HEAD)
  printf 'local_done_head=%s\n' "$LANDED_HEAD" >> "$HOME_DIR/state/$TASK.meta"
  out=$(in_home "$ROOT/bin/fm-merge-local.sh" "$TASK" 2>&1) || fail "local merge failed: $out"
  out=$(in_home "$ROOT/bin/fm-teardown.sh" "$TASK" 2>&1) || fail "teardown failed: $out"
}

ledger_rows() {  # <jq filter>: print one compact row per ledger record
  # A spawn generation is random per launch, so rows show only its shape; the
  # source envelope has its own test.
  jq -c "del(.event_id, .seq, .task_rev, .source, .binding) | if has(\"spawn_gen\") then .spawn_gen |= (if type == \"string\" and test(\"^s[0-9]+[.]\") then \"<gen>\" else . end) else . end | $1" \
    "$HOME_DIR/state/fleet-ledger.jsonl"
}

# Every record's envelope: one home-wide gapless sequence, a gapless per-task
# revision, one source, and the task's binding.
assert_envelope() {
  local ledger="$HOME_DIR/state/fleet-ledger.jsonl" scope
  scope=$(jq -r '.scope_id' "$HOME_DIR/state/producer-identity.json") || fail "no producer identity file"
  jq -e -s --arg scope "$scope" --arg pid "$$" '
    (map(.seq) == [range(1; length + 1)])
    and all(.[]; .event_id == ($scope + ":" + (.seq | tostring)))
    and (map(.task_rev) == [range(1; length + 1)])
    and all(.[]; .source == {machine_id: .source.machine_id, scope_id: $scope, assurance: "host-match",
                             actor: "main", session_pid: ($pid | tonumber), producer: "fm-fleet-ledger"})
    and (map(.source.machine_id) | unique | length == 1)
    and (.[0].source.machine_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
    and all(.[]; .binding.native == null and (.binding.endpoint | type) == "string")
    and all(.[]; .binding.spawn_gen | test("^s[0-9]+[.]"))
  ' "$ledger" >/dev/null || fail "ledger envelopes are wrong: $(jq -c '{seq, event_id, task_rev, source, binding}' "$ledger")"
  jq -e 'has("host_digest") and (.host_digest | test("^[0-9a-f]{64}$")) and (tostring | contains("test-host-1") | not)' \
    "$HOME_DIR/state/producer-identity.json" >/dev/null || fail "identity file must hold only the host digest: $(cat "$HOME_DIR/state/producer-identity.json")"
}

test_envelope_reports_a_moved_home_and_a_native_incarnation() {
  local out ledger scope
  make_case envelope on
  ledger="$HOME_DIR/state/fleet-ledger.jsonl"
  fm_write_meta "$HOME_DIR/state/$TASK.meta" "window=fm-$TASK" "kind=ship" "backend=orca" \
    "spawn_gen=s1790000000.1.1" "terminal=term_0000aaaa" "orca_worktree_id=wt-9"
  out=$(in_home "$ROOT/bin/fm-fleet-ledger.sh" stalled "$TASK" "quiet" 2>&1) || fail "stalled failed: $out"
  scope=$(jq -r '.scope_id' "$HOME_DIR/state/producer-identity.json")
  out=$(CASE_HOST_ID=another-host in_home "$ROOT/bin/fm-fleet-ledger.sh" stalled "$TASK" "still quiet" 2>&1) \
    || fail "stalled on another host failed: $out"
  out=$(CASE_HOST_ID=none in_home "$ROOT/bin/fm-fleet-ledger.sh" stalled "$TASK" "no host id" 2>&1) \
    || fail "stalled without a host id failed: $out"
  assert_equals "$(printf '%s\n' \
    '[1,1,"host-match",true,{"spawn_gen":"s1790000000.1.1","backend":"orca","endpoint":"fm-'"$TASK"'","native":{"terminal":"term_0000aaaa","worktree_id":"wt-9"}}]' \
    '[2,2,"host-mismatch",true,null]' \
    '[3,3,"host-unknown",false,null]')" \
    "$(jq -c --arg scope "$scope" '[.seq, .task_rev, .source.assurance, (.source.machine_id != null and .source.scope_id == $scope),
      (if .seq == 1 then .binding else null end)]' "$ledger")" "envelopes across hosts"
  [ "$(sed -n 1p "$ledger" | jq -r .source.machine_id)" != "$(sed -n 2p "$ledger" | jq -r .source.machine_id)" ] \
    || fail "another host must report another machine id"
  rm -f "$HOME_DIR/state/.fleet-ledger.seq" "$HOME_DIR/state/.$TASK.fleet-ledger-rev"
  out=$(in_home "$ROOT/bin/fm-fleet-ledger.sh" stalled "$TASK" "after a lost counter" 2>&1) || fail "stalled failed: $out"
  assert_equals '[4,1]' "$(tail -n 1 "$ledger" | jq -c '[.seq, .task_rev]')" "a lost sequence file resumes from the ledger"
  pass "envelope: a moved home reads host-mismatch, a missing host id reads host-unknown, the native incarnation stays apart from the spawn generation, and a lost sequence file resumes after the last record"
}

test_flag_on_records_the_task_lifecycle() {
  local rows
  make_case on-lifecycle on
  run_lifecycle

  jq -e -s 'all(.[]; .v == 1 and (.ts | type) == "number" and (.task | type) == "string")' \
    "$HOME_DIR/state/fleet-ledger.jsonl" >/dev/null \
    || fail "every record must carry v, ts, event, and task: $(cat "$HOME_DIR/state/fleet-ledger.jsonl")"
  rows=$(ledger_rows '[.event, .task] + (del(.v, .ts, .event, .task) | to_entries | map(.value))')
  assert_envelope
  assert_equals "$(cat <<EOF
["task.dispatched","$TASK","ship","sample","claude",null]
["task.status","$TASK","working",null," setup done"]
["task.started","$TASK","status","<gen>"]
["task.heartbeat","$TASK","status"," setup done"]
["task.status","$TASK","needs-decision","pick-one"," choose \"a\"\\\\b or c"]
["task.blocked","$TASK","decision","needs-decision","pick-one"," choose \"a\"\\\\b or c"]
["task.status","$TASK","resolved","pick-one"," [key=pick-one]  chose a"]
["task.status","$TASK",null,null,"partial line without its newline finished"]
["task.status","$TASK","done",null," ready in branch"]
["task.finished","$TASK","done",null," ready in branch"]
["task.merged","$TASK","local"]
["task.verified_outcome","$TASK","merged","fm-merge-local",{"via":"local","head":"$LANDED_HEAD"}]
["task.cleaned_up","$TASK"]
EOF
)" "$rows" "ledger rows"
  assert_not_contains "$LEDGER_AFTER_POLL" "partial line" "the poll recorded a line before its newline arrived"
  assert_contains "$LEDGER_AFTER_POLL" '"state":"needs-decision"' "the watcher poll did not record the status lines"
  assert_absent "$HOME_DIR/state/.$TASK.fleet-ledger-offset" "cleanup left the task's ledger offset behind"
  assert_absent "$HOME_DIR/state/.$TASK.fleet-ledger-started" "cleanup left the task's started marker behind"
  pass "flag on: dispatch, polled status lines with their derived start, heartbeat, wait, and finish, the verified local merge, and cleanup are recorded in order"
}

test_flag_on_records_a_pr_merge_once() {
  local pr_url=https://github.com/acme/sample/pull/7 rows
  make_case on-pr on
  mkdir -p "$HOME_DIR/state"
  printf 'done: PR %s checks green\n' "$pr_url" > "$HOME_DIR/state/$TASK.status"
  (
    # shellcheck source=bin/fm-merge-outcome-lib.sh
    . "$ROOT/bin/fm-merge-outcome-lib.sh"
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" fm_merge_outcome_report "$HOME_DIR" "$HOME_DIR/state" "$TASK" "$pr_url" self \
      || fail "the merge outcome was not recorded"
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" fm_merge_outcome_report "$HOME_DIR" "$HOME_DIR/state" "$TASK" "$pr_url" poll \
      || fail "the repeated merge outcome failed"
  ) || exit 1
  rows=$(ledger_rows '[.event, .state // .outcome, .via, .pr // .evidence, .spawn_gen]')
  assert_equals "$(cat <<EOF
["task.status","done",null,null,null]
["task.started",null,null,null,null]
["task.finished","done",null,"$pr_url",null]
["task.merged",null,"pr","$pr_url",null]
["task.verified_outcome","merged",null,{"via":"pr","pr":"$pr_url"},null]
EOF
)" "$rows" "PR merge rows"
  assert_equals '"fm-merge-outcome"' "$(ledger_rows 'select(.event == "task.verified_outcome") | .checker')" \
    "verified merge checker"
  pass "flag on: a PR merge is recorded once with its verified outcome, after the task's pending status lines and their derived start and finish"
}

test_flag_on_records_a_pr_registration() {
  local pr_url=https://github.com/acme/sample/pull/9 rows out
  make_case on-pr-ready on
  # An unreadable forge answer: no draft refusal and no recorded head.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/gh"
  chmod +x "$FAKEBIN/gh"
  out=$(in_home "$ROOT/bin/fm-spawn.sh" "$TASK" "$PROJ_DIR" --mode direct-PR --yolo off 2>&1) \
    || fail "spawn failed: $out"
  printf 'done: PR %s\n' "$pr_url" >> "$HOME_DIR/state/$TASK.status"
  out=$(in_home "$ROOT/bin/fm-pr-check.sh" "$TASK" "$pr_url" 2>&1) || fail "PR registration failed: $out"
  out=$(in_home env FM_PR_CHECK_MERGE=1 "$ROOT/bin/fm-pr-check.sh" "$TASK" "$pr_url" 2>&1) \
    || fail "merge-time PR re-record failed: $out"
  rows=$(ledger_rows '[.event, .state // .outcome, .pr // .evidence, .signal, .checker]')
  assert_equals "$(cat <<EOF
["task.dispatched",null,null,null,null]
["task.status","done",null,null,null]
["task.started",null,null,"status",null]
["task.finished","done","$pr_url",null,null]
["task.pr_ready",null,"$pr_url",null,null]
["task.verified_outcome","pr_ready",{"pr":"$pr_url","head":null},null,"fm-pr-check"]
EOF
)" "$rows" "PR registration rows"
  assert_equals '"<gen>"' "$(ledger_rows 'select(.event == "task.started") | .spawn_gen')" \
    "started row names the recorded spawn generation"
  pass "flag on: registering a PR records task.pr_ready with its full URL and a verified outcome naming the unread head, after the task's pending status lines, and the merge-time re-record adds nothing"
}

# Scaffold a real brief for TASK and print its status command, filled the way a
# worker fills it.
# Optional arguments are the scaffold's state and config overrides; the
# scaffold runs from the home, so a relative config override names its config/.
worker_status_command() {  # <state> <note> [<state-dir> [<config-dir>]]
  local cmd
  rm -rf "${HOME_DIR:?}/data/$TASK"
  (cd "$HOME_DIR" && in_home env FM_STATE_OVERRIDE="${3:-$HOME_DIR/state}" \
    FM_CONFIG_OVERRIDE="${4:-$HOME_DIR/config}" \
    "$ROOT/bin/fm-brief.sh" "$TASK" sample --mode no-mistakes >/dev/null) \
    || fail "brief scaffold failed"
  # shellcheck disable=SC2016 # Match literal backticks in the generated brief.
  cmd=$(sed -n '/`echo "{state}/s/.*`\(echo .*\)`.*/\1/p' "$HOME_DIR/data/$TASK/brief.md" | head -1)
  [ -n "$cmd" ] || fail "the brief carries no status command"
  cmd=${cmd//\{state\}/$1}
  cmd=${cmd//<epoch>/1790000000}
  printf '%s\n' "${cmd//\{one short line\}/$2}"
}

# Run a filled status command as a worker would: a plain shell with no
# firstmate environment.
run_worker_command() {  # <command>
  env -i PATH="$PATH" HOME="$HOME_DIR/user-home" bash -c "$1"
}

test_worker_status_line_is_recorded_when_written() {
  local out
  make_case on-immediate on
  mkdir -p "$HOME_DIR/data"
  out=$(run_worker_command "$(worker_status_command needs-decision 'pick a lamp colour')" 2>&1) \
    || fail "the worker status command failed: $out"
  assert_equals "needs-decision [at=1790000000]: pick a lamp colour" \
    "$(cat "$HOME_DIR/state/$TASK.status")" "status log"
  assert_equals "$(cat <<'EOF'
["task.status","needs-decision"," pick a lamp colour"]
["task.started",null,null]
["task.blocked","needs-decision"," pick a lamp colour"]
EOF
)" "$(ledger_rows '[.event, .state, .text]')" "ledger rows right after the append"
  assert_equals '["worker"]' "$(jq -c -s 'map(.source.actor) | unique' "$HOME_DIR/state/fleet-ledger.jsonl")" \
    "records a worker's status command writes name the worker as their actor"
  out=$(in_home "$ROOT/bin/fm-fleet-ledger.sh" capture 2>&1) || fail "backstop capture failed: $out"
  assert_equals 3 "$(wc -l < "$HOME_DIR/state/fleet-ledger.jsonl" | tr -d ' ')" \
    "ledger records after the backstop capture"
  pass "flag on: a worker's status command records its line at once, and the watcher backstop does not record it again"
}

test_worker_status_line_is_recorded_under_a_state_override() {
  local out state_dir
  make_case on-state-override on
  state_dir="$TMP_ROOT/on-state-override/elsewhere/state"
  mkdir -p "$HOME_DIR/data" "$state_dir"
  out=$(run_worker_command "$(worker_status_command blocked 'need a token' "$state_dir")" 2>&1) \
    || fail "the worker status command failed: $out"
  assert_equals "blocked [at=1790000000]: need a token" "$(cat "$state_dir/$TASK.status")" "status log"
  assert_equals "$(printf '%s\n' '["task.status","blocked"]' '["task.started",null]' '["task.blocked","blocked"]')" \
    "$(jq -c '[.event, .state]' "$state_dir/fleet-ledger.jsonl" 2>/dev/null)" \
    "ledger rows right after the append"
  pass "flag on, state override outside the home: the worker's status command records its line at once"
}

test_worker_status_line_is_recorded_under_a_relative_config_override() {
  local out
  make_case on-relative-config on
  mkdir -p "$HOME_DIR/data"
  out=$(cd "$PROJ_DIR" && run_worker_command \
    "$(worker_status_command needs-decision 'which lamp' "$HOME_DIR/state" config)" 2>&1) \
    || fail "the worker status command failed: $out"
  assert_equals '["task.status","needs-decision"]' "$(ledger_rows 'select(.event == "task.status") | [.event, .state]')" \
    "ledger rows right after the append"
  pass "flag on, relative config override: a worker running elsewhere still records its line at once"
}

test_worker_status_command_fails_when_the_append_fails() {
  local out rc=0
  make_case on-append-fails on
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state/$TASK.status"
  out=$(run_worker_command "$(worker_status_command failed 'tests broke')" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "the worker status command succeeded although its append failed: $out"
  [ ! -e "$HOME_DIR/state/fleet-ledger.jsonl" ] || fail "a failed append still wrote a ledger record"
  pass "append failing: the worker's status command exits nonzero and records nothing"
}

test_worker_status_line_lands_when_the_ledger_fails() {
  local out
  make_case on-failing on
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state/fleet-ledger.jsonl"
  out=$(run_worker_command "$(worker_status_command failed 'tests broke')" 2>&1) \
    || fail "a ledger failure changed the worker status command's result: $out"
  assert_equals "" "$out" "worker status command output"
  assert_equals "failed [at=1790000000]: tests broke" \
    "$(cat "$HOME_DIR/state/$TASK.status")" "status log"
  rmdir "$HOME_DIR/state/fleet-ledger.jsonl"
  out=$(in_home "$ROOT/bin/fm-fleet-ledger.sh" capture 2>&1) || fail "backstop capture failed: $out"
  assert_equals "$(printf '%s\n' '["task.status","failed"]' '["task.started",null]' '["task.finished","failed"]')" \
    "$(ledger_rows '[.event, .state // .outcome]')" "ledger rows after the backstop capture"
  pass "ledger failing: the worker's status line still lands exactly, quietly, and the backstop records it later"
}

test_worker_status_line_with_the_flag_absent() {
  local out leftovers
  make_case off-immediate off
  mkdir -p "$HOME_DIR/data"
  out=$(run_worker_command "$(worker_status_command 'done' 'ready')" 2>&1) \
    || fail "the worker status command failed: $out"
  assert_equals "" "$out" "worker status command output"
  assert_equals "done [at=1790000000]: ready" "$(cat "$HOME_DIR/state/$TASK.status")" "status log"
  leftovers=$(cd "$HOME_DIR/state" && find . -name '*fleet-ledger*')
  assert_equals "" "$leftovers" "ledger files with the flag absent"
  pass "flag off: the worker's status command is a plain append and leaves no ledger file, offset, or lock"
}

test_flag_off_writes_nothing() {
  local leftovers
  make_case off-lifecycle off
  run_lifecycle
  leftovers=$(cd "$HOME_DIR/state" && find . -name '*fleet-ledger*')
  assert_equals "" "$leftovers" "ledger files with the flag absent"
  pass "flag off: the whole lifecycle leaves no ledger file, offset, or lock"
}

ledger_cmd() {  # <args...>: run the ledger writer against the case home
  in_home "$ROOT/bin/fm-fleet-ledger.sh" "$@"
}

test_screen_activity_starts_once_per_incarnation() {
  local out rows
  make_case on-activity on
  fm_write_meta "$HOME_DIR/state/$TASK.meta" "kind=ship" "spawn_gen=s1790000000.1.1"
  out=$(ledger_cmd activity "$TASK" 2>&1) || fail "first activity failed: $out"
  out=$(ledger_cmd activity "$TASK" 2>&1) || fail "second activity failed: $out"
  printf 'working: still going\n' >> "$HOME_DIR/state/$TASK.status"
  out=$(ledger_cmd stalled "$TASK" "screen frozen for 5 polls" 2>&1) || fail "stalled failed: $out"
  # A relaunch is a new incarnation: its first sign starts it again.
  fm_write_meta "$HOME_DIR/state/$TASK.meta" "kind=ship" "spawn_gen=s1790000500.2.2"
  out=$(ledger_cmd activity "$TASK" 2>&1) || fail "relaunch activity failed: $out"
  rows=$(jq -c '[.event, .signal, .spawn_gen, .state, .text, .reason]' "$HOME_DIR/state/fleet-ledger.jsonl")
  assert_equals "$(cat <<'EOF'
["task.started","pane","s1790000000.1.1",null,null,null]
["task.heartbeat","pane",null,null,null,null]
["task.status",null,null,"working"," still going",null]
["task.heartbeat","status",null,null," still going",null]
["task.stalled",null,null,null,null,"screen frozen for 5 polls"]
["task.started","pane","s1790000500.2.2",null,null,null]
EOF
)" "$rows" "activity, status, and stall rows"
  rc=0; out=$(ledger_cmd stalled "$TASK" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "stalled without a reason must be refused"
  pass "flag on: screen activity starts an incarnation once and then beats, a stall records its reason after pending status lines, and a relaunch starts again"
}

test_scout_done_records_its_report_as_verified_outcome() {
  local out sha rows
  make_case on-scout on
  fm_write_meta "$HOME_DIR/state/$TASK.meta" "kind=scout" "spawn_gen=s1790000000.3.3"
  printf '# Findings\nAll quiet.\n' > "$HOME_DIR/data/$TASK/report.md"
  sha=$(shasum -a 256 "$HOME_DIR/data/$TASK/report.md" | awk '{print $1}')
  printf 'done: report written\n' >> "$HOME_DIR/state/$TASK.status"
  out=$(ledger_cmd capture 2>&1) || fail "capture failed: $out"
  rows=$(ledger_rows 'select(.event == "task.verified_outcome") | [.outcome, .checker, .evidence]')
  assert_equals "[\"report\",\"fm-fleet-ledger\",{\"report\":\"data/$TASK/report.md\",\"sha256\":\"$sha\"}]" \
    "$rows" "scout verified outcome"
  # A scout done line without a report claims nothing it cannot show.
  rm -f "$HOME_DIR/data/$TASK/report.md"
  printf 'done: again\n' >> "$HOME_DIR/state/$TASK.status"
  out=$(ledger_cmd capture 2>&1) || fail "second capture failed: $out"
  assert_equals 1 "$(ledger_rows 'select(.event == "task.verified_outcome") | .outcome' | wc -l | tr -d ' ')" \
    "verified outcomes after a done line with no report"
  assert_equals 2 "$(ledger_rows 'select(.event == "task.finished") | .outcome' | wc -l | tr -d ' ')" \
    "finished records"
  pass "flag on: a scout's done line records its report path and digest as a verified outcome, and only when the report exists"
}

# The watcher's screen-heartbeat throttle survives a fresh watcher process,
# and the stale-notice helper records the stall when the wake lands.
test_watcher_throttles_screen_heartbeats_and_records_stalls() {
  local out
  make_case on-watch-helpers on
  fm_write_meta "$HOME_DIR/state/$TASK.meta" "kind=ship" "window=sess:fm-$TASK" "spawn_gen=s1790000000.4.4"
  watch_helper() {  # <snippet>
    # shellcheck disable=SC2016 # The inner shell expands its own arguments.
    in_home env FM_FLEET_LEDGER_HEARTBEAT_SECS=3600 bash -c '. "$1" && eval "$2"' _ "$ROOT/bin/fm-watch.sh" "$1"
  }
  out=$(watch_helper "ledger_task_activity $TASK; ledger_task_activity $TASK" 2>&1) || fail "activity helper failed: $out"
  out=$(watch_helper "ledger_task_activity $TASK" 2>&1) || fail "activity helper in a fresh process failed: $out"
  assert_equals '["task.started"]' "$(ledger_rows '[.event]')" "rows inside one heartbeat interval"
  printf '1\n' > "$HOME_DIR/state/.$TASK.fleet-ledger-beat"
  out=$(watch_helper "ledger_task_activity $TASK" 2>&1) || fail "activity helper after the interval failed: $out"
  assert_equals "$(printf '%s\n' '["task.started",null]' '["task.heartbeat","pane"]')" \
    "$(ledger_rows '[.event, (if .event == "task.heartbeat" then .signal else null end)]')" "rows after the interval"
  out=$(watch_helper "stale_wake_append sess:fm-$TASK 'no progress for 10 polls'" 2>&1) || fail "stale helper failed: $out"
  assert_contains "$(cat "$HOME_DIR/state/.wake-queue" 2>/dev/null)" "no progress for 10 polls" "the stale wake was not queued"
  assert_equals '["task.stalled","no progress for 10 polls"]' \
    "$(ledger_rows 'select(.event == "task.stalled") | [.event, .reason]')" "stall row"
  pass "watcher: screen heartbeats are throttled across watcher processes, and a queued stale notice records the stall"
}

test_flag_on_records_the_task_lifecycle
test_envelope_reports_a_moved_home_and_a_native_incarnation
test_screen_activity_starts_once_per_incarnation
test_scout_done_records_its_report_as_verified_outcome
test_watcher_throttles_screen_heartbeats_and_records_stalls
test_flag_on_records_a_pr_merge_once
test_flag_on_records_a_pr_registration
test_worker_status_line_is_recorded_when_written
test_worker_status_line_is_recorded_under_a_state_override
test_worker_status_line_is_recorded_under_a_relative_config_override
test_worker_status_command_fails_when_the_append_fails
test_worker_status_line_lands_when_the_ledger_fails
test_worker_status_line_with_the_flag_absent
test_flag_off_writes_nothing
