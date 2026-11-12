#!/usr/bin/env bash
# Behavior tests for bin/fm-load-relief.sh: a stubbed sustained-high load
# pauses exactly the lowest-priority live worker through the control seam,
# and a falling load resumes it through the send seam. Heavy-suite
# serialization itself is owned by tests/fm-test-queue.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-load-relief)
RELIEF="$ROOT/bin/fm-load-relief.sh"

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/data"
  printf '4\nmax-load1 20\n' > "$home/config/lane-capacity"
  printf 'sustain-secs=60\n' > "$home/config/load-relief"
  cat > "$TMP_ROOT/$1-control" <<'SH'
#!/usr/bin/env bash
printf 'control %s\n' "$*" >> "$FM_RELIEF_LOG"
SH
  cat > "$TMP_ROOT/$1-send" <<'SH'
#!/usr/bin/env bash
printf 'send %s\n' "$*" >> "$FM_RELIEF_LOG"
SH
  chmod +x "$TMP_ROOT/$1-control" "$TMP_ROOT/$1-send"
  : > "$TMP_ROOT/$1.log"
  fm_write_meta "$home/state/high-prio.meta" "kind=ship" "spawn_gen=s100.1"
  fm_write_meta "$home/state/low-prio.meta" "kind=ship" "spawn_gen=s300.1"
  fm_write_meta "$home/state/no-prio.meta" "kind=scout" "spawn_gen=s50.1"
  fm_write_meta "$home/state/done-low.meta" "kind=ship" "spawn_gen=s10.1"
  printf 'done [at=1]: finished\n' > "$home/state/done-low.status"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog
- [ ] high-prio - urgent work (priority: 1)
- [ ] low-prio - background work (priority: 9)
- [ ] done-low - finished work (priority: 99)
EOF
  printf '%s\n' "$home"
}

run_relief() {  # <home> <name> <load> <now>
  printf '%s\n' "$3" > "$TMP_ROOT/load.txt"
  FM_HOME="$1" FM_LOAD_RELIEF_LOAD_FILE="$TMP_ROOT/load.txt" \
    FM_LOAD_RELIEF_NOW="$4" FM_LOAD_RELIEF_CORES=16 \
    FM_LOAD_RELIEF_CONTROL="$TMP_ROOT/$2-control" \
    FM_LOAD_RELIEF_SEND="$TMP_ROOT/$2-send" \
    FM_RELIEF_LOG="$TMP_ROOT/$2.log" \
    "$RELIEF" check 2>&1
}

test_sustained_high_pauses_lowest_then_falling_resumes() {
  local home out rc=0 log
  home=$(make_home relief)
  log="$TMP_ROOT/relief.log"

  out=$(run_relief "$home" relief 200 1000) || rc=$?
  expect_code 0 "$rc" "first high reading failed: $out"
  assert_contains "$out" "sustained window started" "first high reading did not open the window"
  assert_equals "" "$(cat "$log")" "a first high reading paused a worker before the window elapsed"

  out=$(run_relief "$home" relief 200 1030) || rc=$?
  expect_code 0 "$rc" "mid-window reading failed: $out"
  assert_equals "" "$(cat "$log")" "a mid-window high reading paused a worker early"

  out=$(run_relief "$home" relief 200 1061) || rc=$?
  expect_code 0 "$rc" "sustained reading failed: $out"
  assert_contains "$out" "load-relief: paused low-prio" "the sustained reading did not pause the lowest-priority worker"
  assert_equals "control low-prio interrupt" "$(cat "$log")" "the pause did not interrupt exactly the lowest-priority worker"
  assert_present "$home/state/load-relief/paused/low-prio" "no durable pause record was written"
  assert_absent "$home/state/load-relief/paused/high-prio" "the high-priority worker was paused"
  assert_absent "$home/state/load-relief/paused/no-prio" "the unprioritized worker was paused before a prioritized one"
  assert_absent "$home/state/load-relief/paused/done-low" "a finished worker was paused"
  assert_contains "$(cat "$home/state/low-prio.status")" "paused [at=1061]: load relief" "the paused worker has no durable paused status"

  printf '%s\n' "" > "$log"
  out=$(run_relief "$home" relief 5 1070) || rc=$?
  expect_code 0 "$rc" "falling reading failed: $out"
  assert_contains "$out" "load-relief: resumed low-prio" "the falling reading did not resume the paused worker"
  assert_contains "$(cat "$log")" "send low-prio" "the resume did not steer the paused worker"
  assert_absent "$home/state/load-relief/paused/low-prio" "the pause record survived the resume"
  assert_contains "$(cat "$home/state/low-prio.status")" "resolved [at=1070]: load relief lifted" "the resumed worker has no resolved status"
  pass "a sustained stubbed-high load pauses exactly the lowest-priority worker and a falling load resumes it"
}

test_no_lane_capacity_is_a_noop() {
  local home out rc=0
  home=$(make_home noop)
  rm "$home/config/lane-capacity"
  out=$(run_relief "$home" noop 200 2000) || rc=$?
  expect_code 0 "$rc" "an unconfigured check failed: $out"
  assert_equals "" "$(cat "$TMP_ROOT/noop.log")" "an unconfigured check paused a worker"
  assert_absent "$home/state/load-relief/paused/low-prio" "an unconfigured check wrote a pause record"
  pass "without config/lane-capacity a check is a no-op"
}

test_sustained_high_pauses_lowest_then_falling_resumes
test_no_lane_capacity_is_a_noop
