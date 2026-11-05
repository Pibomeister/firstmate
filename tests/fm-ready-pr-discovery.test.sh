#!/usr/bin/env bash
# Behavioral coverage for bin/fm-ready-pr-discovery.sh: orphan ready runs are
# listed, owned runs are marked owned, unreadable repos are reported (never
# silently skipped), and no mutating no-mistakes call is ever made.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DISCOVERY="$ROOT/bin/fm-ready-pr-discovery.sh"
TMP_ROOT=$(fm_test_tmproot fm-ready-pr-discovery)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
trap fm_test_cleanup EXIT

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# Fixed clock: 2026-11-04T09:00:00Z. The fixture run ULID decodes to
# 2026-11-03T23:02:00Z, so it has waited 9h58m.
export FM_READY_PR_NOW=1793782800
RUN_ID=01M6HTBRJ0AAAAAAAAAAAAAAAA
export FAKE_NM_CALLS="$TMP_ROOT/nm-calls"
: > "$FAKE_NM_CALLS"

cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$(basename "$PWD")" "$*" >> "${FAKE_NM_CALLS:-/dev/null}"
repo=$(basename "$PWD")
# Record any call that could mutate a run, a PR, or a project.
case " $* " in
  *" axi run "*|*" axi respond "*|*" axi abort "*|*" axi answer "*|*" axi sync "*|*" pr ready "*|*" merge "*)
    printf 'MUTATING %s|%s\n' "$repo" "$*" >> "${FAKE_NM_CALLS:-/dev/null}" ;;
esac
if [ "$repo" = broken ]; then
  echo 'daemon unreachable' >&2
  exit 1
fi
run_id=01M6HTBRJ0AAAAAAAAAAAAAAAA
if [ "$#" = 1 ] && [ "$1" = axi ]; then
  case "$repo" in
    casco)
      printf 'repo: /gate/casco\ncount: 1 of 1 total\nruns[1]{id,branch,status,head,pr}:\n  "%s",feat/orphan-ready,running,abc1234,"https://github.com/example/casco/pull/401"\n' "$run_id" ;;
    owned)
      printf 'repo: /gate/owned\ncount: 1 of 1 total\nruns[1]{id,branch,status,head,pr}:\n  "%s",fm/owned-task,running,def5678,"https://github.com/example/owned/pull/7"\n' "$run_id" ;;
    gated)
      printf 'repo: /gate/gated\ncount: 1 of 1 total\nruns[1]{id,branch,status,head,pr}:\n  "%s",feat/gated,running,999aaaa,""\n' "$run_id" ;;
    capped)
      printf 'repo: /gate/capped\ncount: 1 of 40 total\nruns[1]{id,branch,status,head,pr}:\n  "%s",feat/capped-ready,running,cab1234,"https://github.com/example/capped/pull/9"\n' "$run_id" ;;
    busy)
      printf 'repo: /gate/busy\ncount: 3 of 3 total\nruns[3]{id,branch,status,head,pr}:\n'
      for n in 1 2 3; do
        printf '  "01M6HTBRJ0AAAAAAAAAAAAAAA%s",feat/busy-%s,running,bb0000%s,"https://github.com/example/busy/pull/%s"\n' "$n" "$n" "$n" "$n"
      done ;;
    murky)
      printf 'repo: /gate/murky\ncount: 1 of 1 total\nruns[1]{id,branch,status,head,pr}:\n  "%s",feat/murky,running,777bbbb,"https://github.com/example/murky/pull/3"\n' "$run_id" ;;
    *)
      printf 'repo: /gate/%s\ncount: 0 of 0 total\nruns[0]{id,branch,status,head,pr}:\n' "$repo" ;;
  esac
  exit 0
fi
if [ "${1:-}" = axi ] && [ "${2:-}" = status ] && [ "${3:-}" = --run ]; then
  if [ "$repo" = busy ]; then
    sleep 2.5
  fi
  case "$repo" in capped|busy|Casco) run_id=$4 ;; esac
  case "$repo" in
    casco|capped|busy|Casco)
      cat <<EOF
run:
  id: "$run_id"
  branch: feat/orphan-ready
  status: running
  head: "abc1234"
  pr: "https://github.com/example/casco/pull/401"
  steps[3]{step,status,findings,duration_ms}:
    review,completed,0,10
    pr,completed,0,10
    ci,running,0,10
  active_steps[1]{step,active_for,last_activity,agent_pid,round}:
    ci,9h,now,123,1
EOF
      ;;
    owned)
      cat <<EOF
run:
  id: "$run_id"
  branch: fm/owned-task
  status: running
  head: "def5678"
  pr: "https://github.com/example/owned/pull/7"
  steps[3]{step,status,findings,duration_ms}:
    review,completed,0,10
    pr,completed,0,10
    ci,running,0,10
  active_steps[1]{step,active_for,last_activity,agent_pid,round}:
    ci,9h,now,123,1
EOF
      ;;
    gated)
      cat <<EOF
run:
  id: "$run_id"
  branch: feat/gated
  status: running
  awaiting_agent: parked 2h
  head: "999aaaa"
  pr: ""
  gate:
    step: review
    status: awaiting_approval
EOF
      ;;
    murky)
      cat <<EOF
run:
  id: "$run_id"
  branch: feat/murky
  status: running
  head: "777bbbb"
  pr: "https://github.com/example/murky/pull/3"
  steps[3]{step,status,findings,duration_ms}:
    review,completed,0,10
    pr,completed,0,10
    ci,running,0,10
  active_steps[1]{step,active_for,last_activity,agent_pid,round}:
    ci,9h,now,123,1
EOF
      ;;
  esac
  exit 0
fi
if [ "${1:-}" = axi ] && [ "${2:-}" = logs ]; then
  if [ "$repo" = murky ]; then
    printf 'some unrecognized ci output\n'
  else
    printf 'all CI checks passed - still monitoring until merged or closed\n'
  fi
  exit 0
fi
printf 'unexpected fake call: %s\n' "$*" >&2
exit 1
SH
chmod +x "$FAKEBIN/no-mistakes"
export PATH="$FAKEBIN:$PATH"

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/projects/casco" \
  "$HOME_DIR/projects/owned" "$HOME_DIR/projects/gated" "$HOME_DIR/projects/broken" \
  "$HOME_DIR/projects/directy" "$HOME_DIR/projects/murky"
cat > "$HOME_DIR/data/projects.md" <<'EOF'
# Projects

- casco [no-mistakes-prod-only] - Casco platform (added 2026-09-29)
- owned [no-mistakes] - Owned project (added 2026-09-29)
- gated [no-mistakes] - Gated project (added 2026-09-29)
- broken [no-mistakes] - Broken gate project (added 2026-09-29)
- directy [direct-PR] - Direct PR project with no gate (added 2026-09-29)
- murky [no-mistakes] - Project with an unreadable ci log (added 2026-09-29)
- ghost [no-mistakes] - Registered but never cloned (added 2026-09-29)
EOF
fm_write_meta "$HOME_DIR/state/owned-task.meta" \
  "branch=fm/owned-task" "worktree=$HOME_DIR/projects/owned" "kind=ship"

# An empty no-mistakes home: no state database, so no other checkout's gate.
export NM_HOME="$TMP_ROOT/empty-nm"
mkdir -p "$NM_HOME"

run_discovery() {  # [args...]
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    "$DISCOVERY" "$@"
}

test_orphan_ready_run_is_listed() {
  local out
  out=$(run_discovery --compact)
  assert_contains "$out" "ready-pr: repo=casco branch=feat/orphan-ready pr=https://github.com/example/casco/pull/401 head=abc1234 waited=9h58m owned=no kind=ci-ready gate=- checks=green run=$RUN_ID" \
    "orphan ci-ready run is listed with repo, branch, PR, head, and wait"
  pass "orphan ready run is listed"
}

test_owned_run_is_marked_owned() {
  local out
  out=$(run_discovery --compact)
  assert_contains "$out" "repo=owned branch=fm/owned-task" "owned repo run is listed"
  assert_contains "$out" "owned=yes" "run with a task record is marked owned"
  pass "owned run is marked owned"
}

test_gate_run_is_listed() {
  local out
  out=$(run_discovery --compact)
  assert_contains "$out" "repo=gated branch=feat/gated" "approval-gate run is listed"
  assert_contains "$out" "kind=gate" "approval-gate run carries its kind"
  pass "approval-gate run is listed"
}

test_unreadable_repo_is_reported() {
  local out
  out=$(run_discovery --compact)
  assert_contains "$out" "ready-pr-unreadable: repo=broken" "failed gate is reported, not skipped"
  assert_contains "$out" "ready-pr-unreadable: repo=ghost" "missing clone is reported, not skipped"
  pass "unreadable repo is reported, not silently skipped"
}

test_json_shape_for_decision_batch() {
  local out orphan owned unreadable
  out=$(run_discovery --json)
  printf '%s' "$out" | jq -e '.schema == "fm-ready-pr-discovery.v1"' >/dev/null \
    || fail "json carries the discovery schema"
  orphan=$(printf '%s' "$out" | jq -c '.runs[] | select(.repo == "casco")')
  assert_contains "$orphan" '"owned":false' "json flags the orphan run"
  assert_contains "$orphan" '"waited_seconds":35880' "json carries the wait in seconds"
  owned=$(printf '%s' "$out" | jq -c '.runs[] | select(.repo == "owned")')
  assert_contains "$owned" '"owned":true' "json marks the owned run"
  assert_contains "$owned" '"owner_task":"owned-task"' "json names the owning task"
  unreadable=$(printf '%s' "$out" | jq -c '.unreadable | map(.repo)')
  assert_contains "$unreadable" '"broken"' "json lists the unreadable repo"
  pass "json shape serves the decision batch"
}

test_non_gate_projects_are_skipped_silently() {
  local out
  : > "$FAKE_NM_CALLS"
  out=$(run_discovery --compact)
  assert_not_contains "$out" "directy" "direct-PR project is skipped silently"
  if grep -q '^directy|' "$FAKE_NM_CALLS"; then
    fail "discovery called the gate of a direct-PR project"
  fi
  pass "non-gate projects are skipped silently"
}

test_unreadable_ci_log_is_not_ready() {
  local out
  out=$(run_discovery --compact)
  assert_not_contains "$out" "repo=murky branch=feat/murky pr=" "run with unreadable ci log is not listed as ready"
  assert_contains "$out" "ready-pr-warning: repo murky: run $RUN_ID ci log unreadable; not reported as ready" \
    "unreadable ci log surfaces as a warning"
  pass "unreadable ci log is warned, not reported ready"
}

test_no_mutating_call_is_made() {
  : > "$FAKE_NM_CALLS"
  run_discovery --compact >/dev/null
  run_discovery --json >/dev/null
  if grep -q '^MUTATING' "$FAKE_NM_CALLS"; then
    fail "discovery made a mutating no-mistakes call: $(grep '^MUTATING' "$FAKE_NM_CALLS")"
  fi
  # Positive control: the read-only listing/status/log calls really happened.
  grep -q '^casco|axi$' "$FAKE_NM_CALLS" || fail "discovery never listed the casco gate"
  grep -q '^casco|axi status --run' "$FAKE_NM_CALLS" || fail "discovery never read the casco run"
  grep -q '^casco|axi logs' "$FAKE_NM_CALLS" || fail "discovery never read the casco ci log"
  pass "no mutating call is made"
}

HIDDEN_ID=01M6HTBRJ0AAAAAAAAAAAAAAAH

capped_home() {  # <home> <nm-home>
  mkdir -p "$1/data" "$1/state" "$1/projects/capped" "$2"
  printf '# Projects\n\n- capped [no-mistakes] - Capped overview (added 2026-11-04)\n' > "$1/data/projects.md"
}

run_capped() {  # <home> <nm-home> <mode>
  NM_HOME="$2" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" \
    FM_PROJECTS_OVERRIDE="$1/projects" "$DISCOVERY" "$3"
}

test_truncated_overview_lists_runs_outside_the_window() {
  local home=$TMP_ROOT/capped-home nm=$TMP_ROOT/capped-nm out json
  command -v python3 >/dev/null 2>&1 || { pass "skip: python3 not found"; return; }
  capped_home "$home" "$nm"
  python3 - "$nm/state.sqlite" "$RUN_ID" "$HIDDEN_ID" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("CREATE TABLE repos (id INTEGER PRIMARY KEY, working_path TEXT, upstream_url TEXT)")
db.execute("CREATE TABLE runs (id TEXT, repo_id INTEGER, branch TEXT, status TEXT, head_sha TEXT, created_at INTEGER)")
db.execute("INSERT INTO repos VALUES (1, '/gate/capped', 'git@example:capped.git'), (2, '/gate/other', 'git@example:other.git')")
db.executemany("INSERT INTO runs VALUES (?, ?, ?, ?, ?, ?)", [
    (sys.argv[2], 1, "feat/capped-ready", "running", "cab1234", 3),
    (sys.argv[3], 1, "feat/hidden-ready", "running", "fee1234", 1),
    ("01M6HTBRJ0AAAAAAAAAAAAAAAC", 1, "feat/old-done", "completed", "dd01234", 0),
    ("01M6HTBRJ0AAAAAAAAAAAAAAAO", 2, "feat/other-repo", "running", "aa01234", 2),
])
db.commit()
PY
  : > "$FAKE_NM_CALLS"
  out=$(run_capped "$home" "$nm" --compact)
  assert_contains "$out" "ready-pr: repo=capped branch=feat/capped-ready" "runs inside the overview window are still listed"
  assert_contains "$out" "ready-pr: repo=capped branch=feat/hidden-ready" "a live run outside the overview window is listed"
  assert_contains "$out" "run=$HIDDEN_ID" "the hidden run is read by its own id"
  assert_not_contains "$out" "feat/other-repo" "another repo's live run is not attributed to this repo"
  assert_not_contains "$out" "feat/old-done" "completed history is not listed"
  assert_not_contains "$out" "ready-pr-unreadable: repo=capped" "a completed inventory is not reported unreadable"
  [ "$(grep -c "^capped|axi status --run $RUN_ID" "$FAKE_NM_CALLS")" -eq 1 ] \
    || fail "a run shown in the overview and the inventory was read twice"
  json=$(run_capped "$home" "$nm" --json)
  printf '%s' "$json" | jq -e '[.runs[] | select(.repo == "capped")] | length == 2' >/dev/null \
    || fail "json lists both capped runs"
  pass "truncated overview lists runs outside the window"
}

test_truncated_overview_without_inventory_is_reported_incomplete() {
  local home=$TMP_ROOT/capped-noinv-home nm=$TMP_ROOT/capped-noinv-nm out json
  capped_home "$home" "$nm"
  out=$(run_capped "$home" "$nm" --compact)
  assert_contains "$out" "ready-pr: repo=capped branch=feat/capped-ready" "runs inside the overview window are still listed"
  assert_contains "$out" "ready-pr-unreadable: repo=capped reason=run inventory incomplete (1 of 40 runs shown)" \
    "an uncompletable truncated overview is reported as an incomplete repo"
  json=$(run_capped "$home" "$nm" --json)
  printf '%s' "$json" | jq -e '.unreadable | map(.repo) | index("capped") != null' >/dev/null \
    || fail "json lists the uncompletable repo as unreadable"
  pass "truncated overview without inventory is reported incomplete"
}

test_budget_stops_inside_a_repo_and_keeps_results() {
  local home=$TMP_ROOT/busy-home out
  mkdir -p "$home/data" "$home/state" "$home/projects/busy"
  printf '# Projects\n\n- busy [no-mistakes] - Many live runs (added 2026-11-04)\n' > "$home/data/projects.md"
  : > "$FAKE_NM_CALLS"
  out=$(FM_READY_PR_TIMEOUT=8 FM_READY_PR_NM_TIMEOUT=3 FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" "$DISCOVERY" --compact)
  assert_contains "$out" "ready-pr: repo=busy branch=feat/busy-1" "the run read before the budget ran out is kept"
  assert_contains "$out" "ready-pr-unreadable: repo=busy reason=discovery budget 8s reached; remaining live runs not read" \
    "the budget cut inside a repo is reported as incomplete"
  [ "$(grep -c '^busy|axi status --run' "$FAKE_NM_CALLS")" -eq 1 ] \
    || fail "discovery kept reading runs after the budget ran out"
  pass "budget stops inside a repo and keeps results"
}

test_other_checkout_gate_runs_are_listed() {
  local home=$TMP_ROOT/sibling-home nm=$TMP_ROOT/sibling-nm captain=$TMP_ROOT/captain/Casco
  local other_home=$TMP_ROOT/other-home/projects/casco out
  command -v python3 >/dev/null 2>&1 || { pass "skip: python3 not found"; return; }
  mkdir -p "$home/data" "$home/state" "$home/projects/casco" "$nm" "$captain" "$other_home"
  printf '# Projects\n\n- casco [no-mistakes-prod-only] - Casco platform (added 2026-09-29)\n' > "$home/data/projects.md"
  python3 - "$nm/state.sqlite" "$captain" "$other_home" "$TMP_ROOT/gone/Casco" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("CREATE TABLE repos (id INTEGER PRIMARY KEY, working_path TEXT, upstream_url TEXT)")
db.execute("CREATE TABLE runs (id TEXT, repo_id INTEGER, branch TEXT, status TEXT, head_sha TEXT, created_at INTEGER)")
db.executemany("INSERT INTO repos VALUES (?, ?, ?)", [
    (1, "/gate/casco", "git@example:casco.git"), (2, sys.argv[2], "git@example:casco.git"),
    (3, sys.argv[3], "git@example:casco.git"), (4, "/gate/unrelated", "git@example:other.git"),
])
db.executemany("INSERT INTO runs VALUES (?, ?, ?, ?, ?, ?)", [
    ("01M6HTBRJ0AAAAAAAAAAAAAAAK", 2, "feat/captain-ready", "running", "cab4250", 2),
    ("01M6HTBRJ0AAAAAAAAAAAAAAAD", 2, "feat/captain-done", "completed", "cab4240", 1),
    ("01M6HTBRJ0AAAAAAAAAAAAAAAM", 3, "feat/other-home", "running", "cab4260", 2),
    ("01M6HTBRJ0AAAAAAAAAAAAAAAU", 4, "feat/unrelated", "running", "cab4270", 2),
])
db.commit()
PY
  : > "$FAKE_NM_CALLS"
  out=$(NM_HOME="$nm" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" "$DISCOVERY" --compact)
  assert_contains "$out" "ready-pr: repo=casco branch=feat/orphan-ready" "the clone's own gate is still read"
  assert_contains "$out" "ready-pr: repo=casco branch=feat/captain-ready" "a live run in the captain's checkout gate is listed"
  assert_contains "$out" "run=01M6HTBRJ0AAAAAAAAAAAAAAAK" "the captain-checkout run is read by its own id"
  assert_not_contains "$out" "feat/captain-done" "completed runs in the other checkout are not listed"
  assert_not_contains "$out" "feat/other-home" "another home's clone gate is left to that home"
  assert_not_contains "$out" "feat/unrelated" "a gate with another upstream is not attributed to this repo"
  assert_not_contains "$out" "ready-pr-unreadable" "a readable inventory reports nothing unreadable"
  grep -q '^Casco|axi status --run 01M6HTBRJ0AAAAAAAAAAAAAAAK' "$FAKE_NM_CALLS" \
    || fail "the captain-checkout run was not read through its own gate"
  pass "runs in another checkout's gate are listed"
}

test_other_checkout_inventory_unreadable_is_reported() {
  local home=$TMP_ROOT/sibling-bad-home nm=$TMP_ROOT/sibling-bad-nm out
  mkdir -p "$home/data" "$home/state" "$home/projects/casco" "$nm"
  printf '# Projects\n\n- casco [no-mistakes-prod-only] - Casco platform (added 2026-09-29)\n' > "$home/data/projects.md"
  printf 'not a database' > "$nm/state.sqlite"
  out=$(NM_HOME="$nm" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" "$DISCOVERY" --compact)
  assert_contains "$out" "ready-pr: repo=casco branch=feat/orphan-ready" "the clone's own gate is still read"
  assert_contains "$out" "ready-pr-unreadable: repo=casco reason=gates of other checkouts unreadable" \
    "an unreadable other-checkout inventory is reported, not skipped"
  pass "unreadable other-checkout inventory is reported"
}

fm_test_run \
  test_orphan_ready_run_is_listed \
  test_owned_run_is_marked_owned \
  test_gate_run_is_listed \
  test_unreadable_repo_is_reported \
  test_json_shape_for_decision_batch \
  test_non_gate_projects_are_skipped_silently \
  test_unreadable_ci_log_is_not_ready \
  test_no_mutating_call_is_made \
  test_truncated_overview_lists_runs_outside_the_window \
  test_truncated_overview_without_inventory_is_reported_incomplete \
  test_budget_stops_inside_a_repo_and_keeps_results \
  test_other_checkout_gate_runs_are_listed \
  test_other_checkout_inventory_unreadable_is_reported
