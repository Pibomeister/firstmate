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
    murky)
      printf 'repo: /gate/murky\ncount: 1 of 1 total\nruns[1]{id,branch,status,head,pr}:\n  "%s",feat/murky,running,777bbbb,"https://github.com/example/murky/pull/3"\n' "$run_id" ;;
    *)
      printf 'repo: /gate/%s\ncount: 0 of 0 total\nruns[0]{id,branch,status,head,pr}:\n' "$repo" ;;
  esac
  exit 0
fi
if [ "${1:-}" = axi ] && [ "${2:-}" = status ] && [ "${3:-}" = --run ]; then
  case "$repo" in
    casco)
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

fm_test_run \
  test_orphan_ready_run_is_listed \
  test_owned_run_is_marked_owned \
  test_gate_run_is_listed \
  test_unreadable_repo_is_reported \
  test_json_shape_for_decision_batch \
  test_non_gate_projects_are_skipped_silently \
  test_unreadable_ci_log_is_not_ready \
  test_no_mutating_call_is_made
