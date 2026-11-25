#!/usr/bin/env bash
# tests/fm-pr-behind.test.sh - behavioral tests for bin/fm-pr-behind.sh, the
# watcher's trigger that relaunches a live ship whose local branch fell behind
# its own pull-request head. Each case builds a real bare origin, a pipeline
# clone that publishes to it, and a task clone holding the ship's branch, plus a
# state directory with the ship's record, status and armed merge poll. The real
# bin/fm-pr-resync.sh classifies the branch; a recording stand-in replaces the
# relaunch entry point, and a `no-mistakes` stand-in replays an active run's
# branch custody verdict.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

SCAN=$ROOT/bin/fm-pr-behind.sh
TMP_ROOT=$(fm_test_tmproot fm-pr-behind-tests)
fm_git_identity
B=fm/t-behind
TASK=t1
PR=https://github.com/example/repo/pull/7

STUB_BIN=$TMP_ROOT/stub-bin
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/fm-control" <<'EOF'
#!/usr/bin/env bash
printf '%s|gen=%s|noguard=%s\n' "$1 $2" "${FM_CONTROL_EXPECT_SPAWN_GEN:-}" "${FM_SPAWN_NO_GUARD:-}" >> "$CTL_CALLS"
rc=${CTL_RC:-0}
if [ "$rc" -eq 0 ]; then
  case "${CTL_SYNC:-ff}" in
    ff) git -C "$CTL_WT" pull -q --ff-only origin "$(git -C "$CTL_WT" symbolic-ref --short HEAD)" ;;
    dirty) printf 'late edit\n' > "$CTL_WT/late.txt" ;;
  esac
fi
exit "$rc"
EOF
cat > "$STUB_BIN/no-mistakes" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NM_CALLS"
cat "$NM_RESPONSE"
EOF
chmod +x "$STUB_BIN/fm-control" "$STUB_BIN/no-mistakes"

cm() {  # <repo> <file>: commit one new file
  printf '%s\n' "$2" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -qm "$2"
}

fixture() {  # <name>: origin publishes $B; the task clone holds $B at the same head
  D=$TMP_ROOT/$1
  fm_git_init_commit "$D/seed"
  git clone -q --bare "$D/seed" "$D/origin.git"
  git clone -q "$D/origin.git" "$D/pipe"
  git -C "$D/pipe" switch -q -c "$B"
  cm "$D/pipe" a
  git -C "$D/pipe" push -q origin "$B"
  git clone -q -b "$B" "$D/origin.git" "$D/wt"
  WT=$D/wt
  S=$D/state
  mkdir -p "$S" "$D/data"
  printf 'kind=ship\nworktree=%s\nbranch=%s\nmode=no-mistakes\nspawn_gen=4\npr=%s\n' "$WT" "$B" "$PR" > "$S/$TASK.meta"
  printf '#!/usr/bin/env bash\n' > "$S/$TASK.check.sh"
  printf 'working [at=1]: building\n' > "$S/$TASK.status"
  CTL_CALLS=$D/control-calls
  NM_CALLS=$D/nm-calls
}

publish() {  # the pipeline pushes one more commit to $B
  cm "$D/pipe" "$1"
  git -C "$D/pipe" push -q origin "$B"
}

age_ledger() {  # move every ledger row past the probe interval
  [ -f "$S/.pr-behind-$TASK" ] || return 0
  awk -F '\t' 'BEGIN { OFS = "\t" } { $1 = 1; print }' "$S/.pr-behind-$TASK" > "$S/.aged" &&
    mv "$S/.aged" "$S/.pr-behind-$TASK"
}

scan() {
  OUT=$(PATH="$STUB_BIN:$PATH" FM_HOME="$D" FM_STATE_OVERRIDE="$S" FM_CONTROL_BIN="$STUB_BIN/fm-control" \
    CTL_CALLS="$CTL_CALLS" CTL_WT="$WT" NM_CALLS="$NM_CALLS" NM_RESPONSE="$D/nm-response" bash "$SCAN" scan 2>&1)
  RC=$?
  expect_code 0 "$RC" "scan exit"
}

calls() { if [ -f "$CTL_CALLS" ]; then wc -l < "$CTL_CALLS" | tr -d '[:space:]'; else echo 0; fi; }
events() { cut -f 2 "$S/.pr-behind-$TASK" 2>/dev/null | tr '\n' ' '; }

test_behind_and_clean_requests_one_relaunch() {
  fixture behind
  publish fix1
  scan
  assert_equals 1 "$(calls)" "behind and clean: one relaunch request"
  assert_equals "$TASK relaunch|gen=4|noguard=1" "$(cat "$CTL_CALLS")" "behind and clean: relaunch bound to the recorded spawn generation"
  assert_contains "$OUT" "pr-behind-relaunched-$TASK-" "behind and clean: a durable wake key"
  assert_contains "$OUT" "check: $TASK relaunched because its local branch $B" "behind and clean: wake reason"
  assert_contains "$OUT" "$PR" "behind and clean: names the PR"
  assert_contains "$(events)" "requested relaunched" "behind and clean: the request is recorded before it is made"
  pass "a clean ship strictly behind its PR head gets exactly one relaunch request"
}

test_same_head_again_does_not_repeat() {
  fixture repeat
  publish fix1
  scan
  age_ledger
  scan
  assert_equals 1 "$(calls)" "same head: no second request"
  assert_equals "" "$OUT" "same head: nothing new to report"
  publish fix2
  age_ledger
  scan
  assert_equals 2 "$(calls)" "new head: one more request"
  pass "the same PR head never draws a second relaunch request, and a new head draws one"
}

test_probe_waits_for_the_interval() {
  fixture interval
  scan
  publish fix1
  scan
  assert_equals 0 "$(calls)" "inside the interval: not probed again"
  assert_equals "current " "$(events)" "inside the interval: one probe row"
  age_ledger
  scan
  assert_equals 1 "$(calls)" "after the interval: probed and requested"
  pass "each task is probed at most once per interval"
}

test_dirty_copy_is_recorded_without_relaunch() {
  fixture dirty
  publish fix1
  printf 'wip\n' > "$WT/wip.txt"
  scan
  assert_equals 0 "$(calls)" "dirty: no relaunch"
  assert_contains "$OUT" "pr-behind-dirty-$TASK-" "dirty: a durable wake key"
  assert_contains "$OUT" "uncommitted changes, so it was not relaunched" "dirty: wake reason"
  assert_equals "dirty " "$(events)" "dirty: event recorded"
  age_ledger
  scan
  assert_equals 0 "$(calls)" "dirty again: no relaunch"
  assert_equals "" "$OUT" "dirty again: reported only once per head"
  assert_equals "wip" "$(cat "$WT/wip.txt")" "dirty: the change is untouched"
  rm "$WT/wip.txt"
  age_ledger
  scan
  assert_equals 1 "$(calls)" "clean again: the same head is now requested"
  pass "a dirty copy is recorded once with no relaunch, and relaunched once it is clean"
}

test_active_run_is_recorded_without_relaunch() {
  fixture active
  git clone -q --bare "$D/origin.git" "$D/gate.git"
  git -C "$WT" remote add no-mistakes "$D/gate.git"
  printf 'branch_sync:\n  state: pipeline_owned\n  changed: false\n  pipeline:\n    run: "01RUN"\n    status: running\n    current_head: ""\n  relation: behind\n  safety: pipeline_owned_active\n  next_action:\n    code: continue_active_run\n    command: no-mistakes axi run\n' > "$D/nm-response"
  publish fix1
  scan
  assert_equals 0 "$(calls)" "active run: no relaunch"
  assert_contains "$(cat "$NM_CALLS")" "axi sync --check" "active run: custody read through the read-only check"
  assert_contains "$OUT" "pr-behind-active-$TASK-" "active run: a durable wake key"
  assert_contains "$OUT" "an active no-mistakes run holds the branch" "active run: wake reason"
  assert_equals "active " "$(events)" "active run: event recorded"
  age_ledger
  scan
  assert_equals 0 "$(calls)" "active run again: no relaunch"
  assert_equals "" "$OUT" "active run again: reported only once per head"
  pass "an active no-mistakes run is recorded once with no relaunch"
}

test_not_behind_does_nothing() {
  fixture equal
  scan
  assert_equals 0 "$(calls)" "equal: no relaunch"
  assert_equals "" "$OUT" "equal: no report"
  cm "$WT" local-ahead
  printf 'wip\n' > "$WT/wip.txt"
  age_ledger
  scan
  assert_equals 0 "$(calls)" "ahead and dirty: no relaunch"
  assert_equals "" "$OUT" "ahead and dirty: no report"
  assert_equals "local-ahead" "$(git -C "$WT" log -1 --format=%s)" "ahead: local commit kept"
  assert_equals "wip" "$(cat "$WT/wip.txt")" "ahead and dirty: the change is untouched"
  pass "a branch at or ahead of its PR head, dirty or not, draws no request and no report"
}

test_diverged_is_reported_without_relaunch() {
  fixture diverged
  cm "$WT" local-only
  publish fix1
  scan
  assert_equals 0 "$(calls)" "diverged: no relaunch"
  assert_contains "$OUT" "pr-behind-diverged-$TASK-" "diverged: a durable wake key"
  assert_equals "local-only" "$(git -C "$WT" log -1 --format=%s)" "diverged: local commit kept"
  pass "a diverged branch is reported for manual reconciliation with no relaunch"
}

test_refused_control_retries_later() {
  fixture deferred
  publish fix1
  CTL_RC=5 scan
  assert_equals 1 "$(calls)" "lock held: one attempt"
  assert_equals "" "$OUT" "lock held: nothing reported"
  assert_contains "$(events)" "requested deferred" "lock held: deferred recorded"
  age_ledger
  scan
  assert_equals 2 "$(calls)" "after a deferral: the same head is requested again"
  pass "a relaunch the control plane proved it never sent is retried on a later sweep"
}

test_ineligible_ships_are_skipped() {
  fixture ineligible
  publish fix1
  rm "$S/$TASK.check.sh"
  scan
  assert_equals 0 "$(calls)" "no merge poll: skipped"
  printf '#!/usr/bin/env bash\n' > "$S/$TASK.check.sh"
  printf 'done [at=2]: PR %s checks green\n' "$PR" >> "$S/$TASK.status"
  scan
  assert_equals 0 "$(calls)" "terminal status: skipped"
  printf 'working [at=3]: again\n' >> "$S/$TASK.status"
  : > "$S/.crew-stopped-$TASK"
  scan
  assert_equals 0 "$(calls)" "deliberately stopped: skipped"
  rm "$S/.crew-stopped-$TASK"
  printf 'remote_host=elsewhere\n' >> "$S/$TASK.meta"
  scan
  assert_equals 0 "$(calls)" "remote host: skipped"
  assert_equals "" "$(events)" "ineligible: never probed"
  pass "a ship with no merge poll, a terminal status, a deliberate stop or a remote host is never probed"
}

steer() {  # <iso-at> [handled]: one steering record for $TASK
  local dir=$S/$TASK.inbox
  [ -z "${2:-}" ] || dir=$dir/handled
  mkdir -p "$dir"
  printf 'schema=fm-task-inbox.v1\nat=%s\n--\nplease address the review\n' "$1" > "$dir/001.msg"
}

iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

test_steer_after_done_is_probed() {
  local done_at
  done_at=$(( $(date +%s) - 600 ))
  fixture steered
  publish fix1
  printf 'done [at=%s]: PR %s\n' "$done_at" "$PR" >> "$S/$TASK.status"
  steer "$(iso $(( done_at - 60 )))" handled
  scan
  assert_equals 0 "$(calls)" "steer older than done: no relaunch"
  assert_equals "" "$(events)" "steer older than done: never probed"
  steer "$(iso $(( done_at + 60 )))" handled
  scan
  assert_equals 1 "$(calls)" "steer newer than done: one relaunch request"
  assert_contains "$OUT" "check: $TASK relaunched because its local branch $B" "steer newer than done: wake reason"
  pass "a finished ship steered after its done line is probed, and one steered only before it is not"
}

test_relaunch_that_left_the_branch_behind_is_reported() {
  fixture unsynced
  publish fix1
  CTL_SYNC=dirty scan
  assert_equals 1 "$(calls)" "unsynced: one relaunch request"
  assert_contains "$OUT" "pr-behind-unsynced-$TASK-" "unsynced: a durable wake key"
  assert_contains "$OUT" "it was not resynced" "unsynced: honest reason"
  assert_contains "$OUT" "uncommitted changes" "unsynced: names the dirty copy"
  case "$OUT" in *"the relaunch resynced it"*) fail "unsynced: claimed a resync that did not happen" ;; esac
  rm "$WT/late.txt"
  age_ledger
  CTL_SYNC=none scan
  assert_equals 2 "$(calls)" "unsynced: the same head is requested again once clean"
  assert_equals "" "$OUT" "unsynced again: reported only once per head"
  age_ledger
  scan
  assert_equals 3 "$(calls)" "unsynced twice: still reopened"
  assert_contains "$OUT" "the relaunch resynced it" "synced at last: success reported"
  pass "a relaunch that leaves the branch behind its PR head is reported honestly and retried"
}

test_unreadable_captain_hold_does_not_relaunch() {
  fixture holdunknown
  publish fix1
  rmdir "$D/data"
  scan
  assert_equals 0 "$(calls)" "hold unknown: no relaunch"
  assert_equals "hold-unknown " "$(events)" "hold unknown: recorded"
  mkdir "$D/data"
  age_ledger
  scan
  assert_equals 1 "$(calls)" "hold readable again: the same head is requested"
  pass "a captain hold that cannot be read blocks the relaunch until a later sweep can read it"
}

test_watcher_sweep_queues_the_relaunch() {
  local out drain_out pid
  fixture watcher
  publish fix1
  fm_test_track_watcher_state "$S"
  chmod 0700 "$S/$TASK.check.sh"
  FM_STATE_OVERRIDE="$S" "$ROOT/bin/fm-check-register.sh" "$TASK" >/dev/null || fail "could not register the merge poll"
  out=$D/watch.out
  drain_out=$D/drain.out
  PATH="$STUB_BIN:$PATH" FM_HOME="$D" FM_STATE_OVERRIDE="$S" FM_CONTROL_BIN="$STUB_BIN/fm-control" \
    CTL_CALLS="$CTL_CALLS" CTL_WT="$WT" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch.sh" > "$out" 2>/dev/null &
  pid=$!
  wait_for_exit "$pid" 400 || fail "watcher did not wake for the relaunch"
  assert_equals 1 "$(calls)" "watcher: one relaunch request"
  assert_contains "$(cat "$out")" "check: $TASK relaunched because its local branch $B" "watcher: wake line"
  FM_STATE_OVERRIDE="$S" "$ROOT/bin/fm-wake-drain.sh" > "$drain_out" 2>/dev/null || fail "drain after the relaunch wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "pr-behind-relaunched-$TASK-" >/dev/null \
    || fail "the relaunch wake was not queued durably"
  pass "the watcher's merge-poll sweep queues and wakes on one behind-head relaunch"
}

test_usage() {
  OUT=$(bash "$SCAN" 2>&1)
  expect_code 2 "$?" "no verb: usage"
  assert_contains "$OUT" "usage: fm-pr-behind.sh scan" "no verb: usage text"
  OUT=$(bash "$SCAN" --help 2>&1)
  expect_code 0 "$?" "help: exit"
  assert_contains "$OUT" "Usage: fm-pr-behind.sh scan" "help: usage"
  assert_contains "$OUT" "FM_PR_BEHIND_INTERVAL" "help: knobs"
  pass "the scan verb is required, and --help prints the contract"
}

fm_test_run \
  test_behind_and_clean_requests_one_relaunch \
  test_same_head_again_does_not_repeat \
  test_probe_waits_for_the_interval \
  test_dirty_copy_is_recorded_without_relaunch \
  test_active_run_is_recorded_without_relaunch \
  test_not_behind_does_nothing \
  test_diverged_is_reported_without_relaunch \
  test_refused_control_retries_later \
  test_ineligible_ships_are_skipped \
  test_steer_after_done_is_probed \
  test_relaunch_that_left_the_branch_behind_is_reported \
  test_unreadable_captain_hold_does_not_relaunch \
  test_watcher_sweep_queues_the_relaunch \
  test_usage
