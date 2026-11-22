#!/usr/bin/env bash
# Public publisher/observer overlap contracts. The slow external boundary records
# producer entries; independent concurrent callers must share one observation.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-refresh-singleflight)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/quota-axi"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/no-mistakes"
chmod +x "$FAKEBIN/quota-axi" "$FAKEBIN/no-mistakes"
export PATH="$FAKEBIN:$PATH"
export FM_ROOT_OVERRIDE="$ROOT"

make_flight_home() {
  mkdir -p "$1/state" "$1/data" "$1/config" "$1/projects"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$1/data/backlog.md"
}

mirror_bin() {
  mkdir -p "$1/bin"
  python3 - "$ROOT/bin" "$1/bin" <<'PY'
import os
import sys
for entry in os.scandir(sys.argv[1]):
    os.symlink(entry.path, os.path.join(sys.argv[2], entry.name))
PY
}

wait_for_entry() {
  local i=0
  while [ ! -s "$1" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
  [ -s "$1" ] || fail "producer never entered its controlled boundary"
}

test_heartbeat_entrypoint_coalesces() {
  local home="$TMP_ROOT/heartbeat" producer="$TMP_ROOT/snapshot" first second
  make_flight_home "$home"
  cat > "$producer" <<'SH'
#!/usr/bin/env bash
printf 'entry\n' >> "$FM_HOME/entries"
sleep 2
printf '{"schema":"fm-fleet-snapshot.v1","tasks":[]}\n'
SH
  chmod +x "$producer"
  FM_HOME="$home" FM_HEARTBEAT_SNAPSHOT_SCRIPT="$producer" "$ROOT/bin/fm-heartbeat.sh" --write &
  first=$!
  wait_for_entry "$home/entries"
  FM_HOME="$home" FM_HEARTBEAT_SNAPSHOT_SCRIPT="$producer" "$ROOT/bin/fm-heartbeat.sh" --write &
  second=$!
  wait "$second" || fail "overlapping heartbeat failed"
  wait "$first" || fail "first heartbeat failed"
  [ "$(wc -l < "$home/entries" | tr -d ' ')" = 1 ] || fail "overlapping heartbeat collectors stacked"
  jq -e '.schema == "fm-heartbeat.v1"' "$home/state/heartbeat.json" >/dev/null || fail "heartbeat was not published"
  pass "independent overlapping heartbeat callers collect once"
}

test_summary_entrypoint_coalesces() {
  local home="$TMP_ROOT/summary" mirror="$TMP_ROOT/summary-code" first second
  make_flight_home "$home"
  mirror_bin "$mirror"
  rm "$mirror/bin/fm-fleet-snapshot.sh"
  cat > "$mirror/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf 'entry\n' >> "$FM_HOME/entries"
sleep 2
exec "$FM_TEST_REAL_SNAPSHOT" "$@"
SH
  chmod +x "$mirror/bin/fm-fleet-snapshot.sh"
  export FM_TEST_REAL_SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
  FM_HOME="$home" "$mirror/bin/fm-home-summary-refresh.sh" --best-effort &
  first=$!
  wait_for_entry "$home/entries"
  FM_HOME="$home" "$mirror/bin/fm-home-summary-refresh.sh" --best-effort &
  second=$!
  wait "$second" || fail "overlapping summary failed"
  wait "$first" || fail "first summary failed"
  [ "$(wc -l < "$home/entries" | tr -d ' ')" = 1 ] || fail "overlapping summaries stacked sequential passes"
  jq -e '.schema == "fm-secondmate-home-summary.v1"' "$home/state/home-summary.json" >/dev/null || fail "summary was not published"
  pass "independent overlapping summary triggers collect once"
}

test_snapshot_entrypoint_shares_only_overlapping_results() {
  local home="$TMP_ROOT/observer" mirror="$TMP_ROOT/observer-code" first second i id
  make_flight_home "$home"
  mirror_bin "$mirror"
  rm "$mirror/bin/fm-crew-state.sh"
  cat > "$mirror/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'entry\n' >> "$FM_HOME/entries"
[ "$1" != task ] || sleep 2
printf 'state: paused · source: status-log · fixture pause\n'
SH
  chmod +x "$mirror/bin/fm-crew-state.sh"
  printf 'kind=scout\nproject=fixture\n' > "$home/state/task.meta"
  printf 'paused: fixture pause\n' > "$home/state/task.status"
  # Historical/parked metadata remains in the accurate inventory. Overlap must
  # not multiply its current-state probes, even beyond one concurrency window.
  i=1
  while [ "$i" -le 216 ]; do
    printf -v id 'z-history-%03d' "$i"
    printf 'kind=scout\nproject=fixture\n' > "$home/state/$id.meta"
    printf 'paused: historical fixture pause\n' > "$home/state/$id.status"
    i=$((i + 1))
  done
  FM_HOME="$home" "$mirror/bin/fm-fleet-snapshot.sh" --json > "$home/first.json" &
  first=$!
  wait_for_entry "$home/entries"
  FM_HOME="$home" "$mirror/bin/fm-fleet-snapshot.sh" --json > "$home/second.json" &
  second=$!
  wait "$second" || fail "overlapping snapshot failed"
  wait "$first" || fail "first snapshot failed"
  [ "$(wc -l < "$home/entries" | tr -d ' ')" = 217 ] || fail "overlapping snapshots multiplied historical task observations"
  cmp "$home/first.json" "$home/second.json" || fail "overlapping readers did not receive the same complete observation"
  printf 'needs-decision [key=later]: a later observation\n' >> "$home/state/task.status"
  FM_HOME="$home" "$mirror/bin/fm-fleet-snapshot.sh" --json > "$home/later.json" || fail "later snapshot failed"
  [ "$(wc -l < "$home/entries" | tr -d ' ')" = 434 ] || fail "a later independent snapshot reused a stale observation"
  jq -e '.tasks[0].hints.open_decisions | any(.key == "later")' "$home/later.json" >/dev/null || fail "later status change was hidden"
  pass "snapshot overlap shares one observation, while later callers observe changes"
}

test_snapshot_modes_and_failures_remain_independent() {
  local home="$TMP_ROOT/modes" mirror="$TMP_ROOT/mode-code" first second first_rc=0 second_rc=0
  make_flight_home "$home"
  mirror_bin "$mirror"
  rm "$mirror/bin/fm-crew-state.sh" "$mirror/bin/fm-contributions.sh"
  cat > "$mirror/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
mkdir "$FM_HOME/active" || { printf 'overlap\n' >> "$FM_HOME/overlap"; exit 1; }
printf 'entry\n' >> "$FM_HOME/entries"
sleep 1
rmdir "$FM_HOME/active"
printf 'state: paused · source: status-log · fixture pause\n'
SH
  cat > "$mirror/bin/fm-contributions.sh" <<'SH'
#!/usr/bin/env bash
[ "${FM_TEST_FLIGHT_FAIL:-0}" != 1 ] || exit 9
exec "$FM_TEST_REAL_CONTRIBUTIONS" "$@"
SH
  chmod +x "$mirror/bin/fm-crew-state.sh" "$mirror/bin/fm-contributions.sh"
  export FM_TEST_REAL_CONTRIBUTIONS="$ROOT/bin/fm-contributions.sh"
  printf 'kind=scout\nproject=fixture\n' > "$home/state/task.meta"
  printf 'paused: fixture pause\n' > "$home/state/task.status"
  FM_HOME="$home" "$mirror/bin/fm-fleet-snapshot.sh" --json > "$home/fleet.json" &
  first=$!
  wait_for_entry "$home/entries"
  FM_HOME="$home" "$mirror/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$home/summary.json" &
  second=$!
  wait "$first" || fail "fleet-mode snapshot failed"
  wait "$second" || fail "summary-mode snapshot failed"
  [ ! -e "$home/overlap" ] || fail "different output modes collected concurrently for one home"
  jq -e '.schema == "fm-fleet-snapshot.v1"' "$home/fleet.json" >/dev/null || fail "fleet mode received another mode's result"
  jq -e '.schema == "fm-secondmate-home-summary.v1"' "$home/summary.json" >/dev/null || fail "summary mode received another mode's result"
  : > "$home/entries"
  FM_HOME="$home" FM_TEST_FLIGHT_FAIL=1 "$mirror/bin/fm-fleet-snapshot.sh" --json > "$home/failed-one" 2>/dev/null &
  first=$!
  wait_for_entry "$home/entries"
  FM_HOME="$home" FM_TEST_FLIGHT_FAIL=1 "$mirror/bin/fm-fleet-snapshot.sh" --json > "$home/failed-two" 2>/dev/null &
  second=$!
  wait "$first" || first_rc=$?
  wait "$second" || second_rc=$?
  [ "$first_rc" = 1 ] && [ "$second_rc" = 1 ] || fail "coalescing hid the producer's failure: $first_rc/$second_rc"
  [ ! -s "$home/failed-one" ] && [ ! -s "$home/failed-two" ] || fail "failed readers received a previous successful snapshot"
  FM_HOME="$home" "$mirror/bin/fm-fleet-snapshot.sh" --json > "$home/recovered.json" || fail "a failed producer stranded the observation lock"
  jq -e '.schema == "fm-fleet-snapshot.v1"' "$home/recovered.json" >/dev/null || fail "failure recovery returned an invalid result"
  pass "output modes serialize without mixing documents, and failed observations stay failed until a fresh successful pass"
}

test_snapshot_change_during_collection_requires_a_fresh_pass() {
  local home="$TMP_ROOT/changed" mirror="$TMP_ROOT/changed-code" first second
  make_flight_home "$home"
  mirror_bin "$mirror"
  rm "$mirror/bin/fm-crew-state.sh"
  cat > "$mirror/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'entry\n' >> "$FM_HOME/entries"
sleep 1
printf 'state: paused · source: status-log · fixture pause\n'
SH
  chmod +x "$mirror/bin/fm-crew-state.sh"
  printf 'kind=scout\nproject=fixture\n' > "$home/state/task.meta"
  printf 'paused: fixture pause\n' > "$home/state/task.status"
  FM_HOME="$home" "$mirror/bin/fm-fleet-snapshot.sh" --json > "$home/first.json" &
  first=$!
  wait_for_entry "$home/entries"
  printf 'needs-decision [key=changed]: changed during collection\n' >> "$home/state/task.status"
  FM_HOME="$home" "$mirror/bin/fm-fleet-snapshot.sh" --json > "$home/second.json" &
  second=$!
  wait "$first" || fail "first snapshot before the change failed"
  wait "$second" || fail "snapshot requested after the change failed"
  [ "$(wc -l < "$home/entries" | tr -d ' ')" = 2 ] || fail "a changed-input caller shared the obsolete observation"
  jq -e '.tasks[0].hints.open_decisions | any(.key == "changed")' "$home/second.json" >/dev/null || fail "coalescing hid a decision that predated the second request"
  pass "a status change before an overlapping request forces its own fresh serialized observation"
}

test_snapshot_preserves_stage_descriptor_and_recovers_dead_owner() {
  local home="$TMP_ROOT/stages"
  make_flight_home "$home"
  FM_HOME="$home" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$STATE/.fleet-observation.lock"' _ "$ROOT" \
    || fail "could not leave a dead fixture lock owner"
  (
    exec 7> "$home/stages"
    FM_HOME="$home" FM_SNAPSHOT_STAGE_FD=7 "$ROOT/bin/fm-fleet-snapshot.sh" --json > "$home/snapshot.json"
  ) || fail "snapshot did not recover the dead owner"
  jq -e '.schema == "fm-fleet-snapshot.v1"' "$home/snapshot.json" >/dev/null || fail "stage reporting corrupted snapshot stdout"
  grep -F 'task-observation' "$home/stages" >/dev/null || fail "snapshot replaced the caller's stage descriptor"
  [ ! -e "$home/state/.fleet-observation.lock" ] || fail "completed snapshot retained its observation lock"
  pass "snapshot recovers a dead lock owner and preserves the caller's stage descriptor"
}

test_contribution_inventory_does_not_wait_for_worker_probes() {
  local home="$TMP_ROOT/contribution" mirror="$TMP_ROOT/contribution-code" first rc=0
  make_flight_home "$home"
  mirror_bin "$mirror"
  rm "$mirror/bin/fm-crew-state.sh"
  cat > "$mirror/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'entry\n' >> "$FM_HOME/entries"
while [ ! -e "$FM_HOME/release" ]; do sleep 0.05; done
printf 'state: paused · source: status-log · fixture pause\n'
SH
  chmod +x "$mirror/bin/fm-crew-state.sh"
  printf 'kind=scout\nproject=fixture\n' > "$home/state/task.meta"
  FM_HOME="$home" "$mirror/bin/fm-fleet-snapshot.sh" --json > "$home/fleet.json" &
  first=$!
  wait_for_entry "$home/entries"
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$ROOT/bin/fm-timeout-lib.sh"
  FM_HOME="$home" fm_run_timed 2 "$mirror/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/contribution.json" || rc=$?
  : > "$home/release"
  wait "$first" || fail "fleet snapshot failed after releasing its probe"
  [ "$rc" = 0 ] || fail "cheap contribution inventory waited behind worker observation: $rc"
  jq -e '.tasks[0].id == "task" and (.tasks[0] | has("current_state") | not)' "$home/contribution.json" >/dev/null || fail "contribution inventory changed its worker-free contract"
  pass "contribution-only inventory stays bounded independently of a slow worker observation"
}

if [ "$#" -gt 0 ]; then
  for test in "$@"; do "$test"; done
else
  test_heartbeat_entrypoint_coalesces
  test_summary_entrypoint_coalesces
  test_snapshot_entrypoint_shares_only_overlapping_results
  test_snapshot_modes_and_failures_remain_independent
  test_snapshot_change_during_collection_requires_a_fresh_pass
  test_snapshot_preserves_stage_descriptor_and_recovers_dead_owner
  test_contribution_inventory_does_not_wait_for_worker_probes
fi
