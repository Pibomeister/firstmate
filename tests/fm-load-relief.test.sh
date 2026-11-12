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

# The tasks seam prints the `show` shape tasks-axi itself prints (a
# two-space-indented priority: field, "-" when unset) from <home>/prios,
# one "<id> <priority>" per line; an id absent there is not in the backlog.
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
  cat > "$TMP_ROOT/$1-tasks" <<'SH'
#!/usr/bin/env bash
[ "$1" = show ] || exit 2
prio=$(awk -v id="$2" '$1 == id { print $2; found = 1 } END { exit !found }' "$FM_HOME/prios") || {
  printf 'error: "Task \\"%s\\" not found in this backlog"\n' "$2"; exit 1; }
printf 'task:\n  id: %s\n  title: t\n  state: in_flight\n  kind: task\n  priority: %s\n  body: ""\n' "$2" "$prio"
SH
  chmod +x "$TMP_ROOT/$1-control" "$TMP_ROOT/$1-send" "$TMP_ROOT/$1-tasks"
  : > "$TMP_ROOT/$1.log"
  : > "$home/prios"
  printf '%s\n' "$home"
}

add_worker() {  # <home> <id> <spawn-epoch> <priority|-|absent>
  fm_write_meta "$1/state/$2.meta" "kind=ship" "spawn_gen=s$3.1" "backend=tmux" "harness=claude"
  [ "$4" = absent ] || printf '%s "%s"\n' "$2" "$4" | sed 's/"\([0-9][0-9]*\)"$/\1/' >> "$1/prios"
}

run_relief() {  # <home> <name> <load> <now>
  printf '%s\n' "$3" > "$TMP_ROOT/load.txt"
  FM_HOME="$1" FM_TEST_SEAM=1 FM_LOAD_RELIEF_LOAD_FILE="$TMP_ROOT/load.txt" \
    FM_LOAD_RELIEF_NOW="$4" FM_LOAD_RELIEF_CORES=16 \
    FM_LOAD_RELIEF_CONTROL="$TMP_ROOT/$2-control" \
    FM_LOAD_RELIEF_SEND="$TMP_ROOT/$2-send" \
    FM_LOAD_RELIEF_TASKS="$TMP_ROOT/$2-tasks" \
    FM_RELIEF_LOG="$TMP_ROOT/$2.log" \
    "$RELIEF" check 2>&1
}

# Opens the sustained window at <t0> and returns the pass at <t0>+61.
sustained_pass() {  # <home> <name> <t0>
  run_relief "$1" "$2" 200 "$3" >/dev/null
  run_relief "$1" "$2" 200 "$(($3 + 61))"
}

test_sustained_high_pauses_lowest_then_falling_resumes() {
  local home out rc=0 log
  home=$(make_home relief)
  log="$TMP_ROOT/relief.log"
  add_worker "$home" high-prio 300 1
  add_worker "$home" low-prio 100 9
  add_worker "$home" done-low 400 99
  printf 'done [at=1]: finished\n' > "$home/state/done-low.status"

  out=$(run_relief "$home" relief 200 1000) || rc=$?
  expect_code 0 "$rc" "first high reading failed: $out"
  assert_contains "$out" "sustained window started" "first high reading did not open the window"
  assert_equals "" "$(cat "$log")" "a first high reading paused a worker before the window elapsed"

  out=$(run_relief "$home" relief 200 1030) || rc=$?
  expect_code 0 "$rc" "mid-window reading failed: $out"
  assert_equals "" "$(cat "$log")" "a mid-window high reading paused a worker early"

  out=$(run_relief "$home" relief 200 1061) || rc=$?
  expect_code 0 "$rc" "sustained reading failed: $out"
  assert_equals "control low-prio interrupt" "$(cat "$log")" "the pause did not interrupt exactly the highest-number priority worker"
  assert_present "$home/state/load-relief/paused/low-prio" "no durable pause record was written"
  assert_absent "$home/state/load-relief/paused/high-prio" "the high-priority worker was paused"
  assert_absent "$home/state/load-relief/paused/done-low" "a finished worker was paused"
  assert_contains "$(cat "$home/state/low-prio.status")" "paused [key=load-relief] [at=1061]: load relief" "the paused worker has no keyed paused status"

  out=$(run_relief "$home" relief 200 1091) || rc=$?
  assert_equals "control low-prio interrupt" "$(cat "$log")" "a pass inside the restarted window paused another worker"

  : > "$log"
  out=$(run_relief "$home" relief 5 1100) || rc=$?
  expect_code 0 "$rc" "falling reading failed: $out"
  assert_contains "$(cat "$log")" "send low-prio" "the resume did not steer the paused worker"
  assert_absent "$home/state/load-relief/paused/low-prio" "the pause record survived the resume"
  assert_contains "$(cat "$home/state/low-prio.status")" "resolved [key=load-relief] [at=1100]: load relief lifted" "the resumed worker has no keyed resolved status"
  pass "a sustained stubbed-high load pauses the highest priority number once per window and a falling load resumes it"
}

test_priority_tie_pauses_newest_dispatch() {
  local home
  home=$(make_home tie)
  add_worker "$home" old-run 100 5
  add_worker "$home" new-run 900 5
  add_worker "$home" mid-run 500 5
  add_worker "$home" urgent 950 2
  sustained_pass "$home" tie 1000 >/dev/null
  assert_equals "control new-run interrupt" "$(cat "$TMP_ROOT/tie.log")" "a priority tie did not pause the newest dispatch"
  pass "a priority tie pauses the newest dispatch first"
}

test_unprioritized_pauses_first_and_absent_never() {
  local home
  home=$(make_home noprio)
  printf 'sustain-secs=60\npause-per-check=4\n' > "$home/config/load-relief"
  add_worker "$home" numbered 900 4
  add_worker "$home" old-unset 100 -
  add_worker "$home" new-unset 200 -
  add_worker "$home" not-in-backlog 950 absent
  sustained_pass "$home" noprio 1000 >/dev/null
  assert_equals "$(printf 'control new-unset interrupt\ncontrol old-unset interrupt\ncontrol numbered interrupt')" \
    "$(cat "$TMP_ROOT/noprio.log")" "pause order was not unprioritized newest-first, then numbered"
  [ ! -f "$home/state/load-relief/paused/not-in-backlog" ] || fail "a task with no backlog item was paused"
  pass "an item with no numeric priority pauses before a numbered one, newest first; no backlog item is never paused"
}

test_pr_ready_lane_is_not_paused() {
  local home
  home=$(make_home prready)
  add_worker "$home" ready 900 9
  printf 'pr=https://example.invalid/pr/1\n' >> "$home/state/ready.meta"
  add_worker "$home" working 100 1
  sustained_pass "$home" prready 1000 >/dev/null
  assert_equals "control working interrupt" "$(cat "$TMP_ROOT/prready.log")" "a lane with a ready PR was paused"
  pass "a lane with a ready PR is never paused, even as the first candidate"
}

test_waiting_worker_is_not_paused_and_decision_survives() {
  local home
  home=$(make_home waiting)
  add_worker "$home" asks 900 9
  add_worker "$home" busy 100 3
  printf 'needs-decision: which schema?\n' > "$home/state/asks.status"
  sustained_pass "$home" waiting 1000 >/dev/null
  assert_equals "control busy interrupt" "$(cat "$TMP_ROOT/waiting.log")" "a worker waiting on a decision was paused"
  run_relief "$home" waiting 5 1100 >/dev/null
  assert_equals "needs-decision: which schema?" "$(cat "$home/state/asks.status")" "the resume touched a waiting worker's status"
  pass "a worker waiting on a captain decision is never paused"
}

test_finished_pause_record_dropped_without_steer() {
  local home
  home=$(make_home gone)
  add_worker "$home" ended 100 9
  add_worker "$home" removed 200 8
  mkdir -p "$home/state/load-relief/paused"
  printf 'id=ended\n' > "$home/state/load-relief/paused/ended"
  printf 'id=removed\n' > "$home/state/load-relief/paused/removed"
  printf 'done [at=5]: shipped\n' >> "$home/state/ended.status"
  rm "$home/state/removed.meta"
  run_relief "$home" gone 5 1000 >/dev/null
  assert_equals "" "$(cat "$TMP_ROOT/gone.log")" "a finished or removed task was steered to resume"
  assert_absent "$home/state/load-relief/paused/ended" "a finished task's pause record was kept"
  assert_absent "$home/state/load-relief/paused/removed" "a removed task's pause record was kept"
  pass "a pause record for a finished or removed task is dropped without a steer"
}

test_tab_separated_max_load1_sets_ceiling() {
  local home out
  home=$(make_home tabbed)
  printf '4\nmax-load1\t50\n' > "$home/config/lane-capacity"
  add_worker "$home" w 100 9
  out=$(run_relief "$home" tabbed 40 1000)
  assert_not_contains "$out" "sustained window started" "a tab-separated max-load1 50 was ignored for the 16-core fallback"
  pass "max-load1 parses with the same tab-tolerant grammar as fm-capacity"
}

pause_record() {  # <home> <id> <paused-epoch> [priority]
  mkdir -p "$1/state/load-relief/paused"
  printf 'id=%s\npaused_epoch=%s\n%s' "$2" "$3" "${4:+priority=$4
}" > "$1/state/load-relief/paused/$2"
}

test_resume_waits_below_hysteresis_and_staggers() {
  local home log
  home=$(make_home stagger)
  log="$TMP_ROOT/stagger.log"
  add_worker "$home" p-low 100 4
  add_worker "$home" p-high 200 1
  add_worker "$home" legacy-old 300 -
  add_worker "$home" legacy-new 400 -
  pause_record "$home" p-low 1000 4
  pause_record "$home" p-high 1001 1
  pause_record "$home" legacy-old 900
  pause_record "$home" legacy-new 950
  run_relief "$home" stagger 17 2000 >/dev/null
  assert_equals "" "$(cat "$log")" "a load of 17 under ceiling 20 but over its 75% resume level (15) resumed a worker"
  run_relief "$home" stagger 5 2010 >/dev/null
  assert_equals "send p-high" "$(cut -d' ' -f1-2 "$log")" "the first resume pass did not lift exactly the highest-priority pause"
  run_relief "$home" stagger 5 2020 >/dev/null
  run_relief "$home" stagger 5 2030 >/dev/null
  run_relief "$home" stagger 5 2040 >/dev/null
  assert_equals "send p-high
send p-low
send legacy-new
send legacy-old" "$(cut -d' ' -f1-2 "$log")" "resume did not go one per pass, by priority, then newest unprioritized pause"
  pass "resume waits under 75% of the ceiling and lifts one pause per pass, highest priority first"
}

test_failed_interrupt_keeps_uncertain_record() {
  local home out
  home=$(make_home failint)
  add_worker "$home" w 100 4
  cat > "$TMP_ROOT/failint-control" <<'SH'
#!/usr/bin/env bash
[ -f "$FM_HOME/state/load-relief/paused/$1" ] && printf 'record-present %s\n' "$1" >> "$FM_RELIEF_LOG"
echo "control blew up after the key" >&2
exit 1
SH
  out=$(sustained_pass "$home" failint 1000)
  assert_equals "record-present w" "$(cat "$TMP_ROOT/failint.log")" "the pause record was not written before the interrupt"
  assert_present "$home/state/load-relief/paused/w" "a record was dropped after an interrupt whose delivery is unproven"
  assert_contains "$(cat "$home/state/load-relief/paused/w")" "state=uncertain" "the kept record is not marked uncertain"
  assert_contains "$out" "control blew up after the key" "the control error was not surfaced"
  run_relief "$home" failint 5 2000 >/dev/null
  assert_contains "$(cat "$TMP_ROOT/failint.log")" "send w" "the resume pass did not resolve the uncertain pause"
  assert_absent "$home/state/load-relief/paused/w" "the uncertain record survived its resume"
  pass "a nonzero interrupt keeps an uncertain pause record, surfaces the error, and the resume pass resolves it"
}

test_buried_decision_is_never_paused() {
  local home
  home=$(make_home buried)
  add_worker "$home" asks 900 9
  add_worker "$home" busy 100 3
  printf 'working [at=1]: investigating\nneeds-decision [key=schema] [at=2]: which schema?\nresolved [key=other] [at=3]: unrelated answer\nworking [at=4]: still waiting\n' > "$home/state/asks.status"
  sustained_pass "$home" buried 1000 >/dev/null
  assert_equals "control busy interrupt" "$(cat "$TMP_ROOT/buried.log")" "a worker with a buried open decision was paused"
  pass "a buried open decision keeps a worker unpaused even when its latest verb is working"
}

test_decision_after_pause_defers_resume() {
  local home log
  home=$(make_home afterpause)
  log="$TMP_ROOT/afterpause.log"
  add_worker "$home" w 100 4
  sustained_pass "$home" afterpause 1000 >/dev/null
  assert_present "$home/state/load-relief/paused/w" "setup pause missing"
  printf 'needs-decision [key=dec1] [at=2000]: which schema?\n' >> "$home/state/w.status"
  : > "$log"
  run_relief "$home" afterpause 5 2001 >/dev/null
  assert_equals "" "$(cat "$log")" "a worker that raised a decision after its pause was resumed"
  assert_present "$home/state/load-relief/paused/w" "the deferred resume dropped the pause record"
  printf 'resolved [key=dec1] [at=2002]: use schema A\n' >> "$home/state/w.status"
  run_relief "$home" afterpause 5 2003 >/dev/null
  assert_contains "$(cat "$log")" "send w" "an answered decision did not let the resume through"
  pass "a decision raised after a pause defers its resume until answered"
}

test_uninterruptible_worker_is_not_a_candidate() {
  local home out
  home=$(make_home orcaonly)
  add_worker "$home" orca-claude 100 9
  printf 'kind=ship\nspawn_gen=s100.1\nbackend=orca\nharness=claude\n' > "$home/state/orca-claude.meta"
  out=$(sustained_pass "$home" orcaonly 1000)
  assert_equals "" "$(cat "$TMP_ROOT/orcaonly.log")" "an Orca claude worker, whose interrupt key cannot be delivered, was interrupted"
  assert_contains "$out" "no live worker to pause" "the pass did not report having no eligible worker"
  out=$(run_relief "$home" orcaonly 200 1090)
  assert_contains "$out" "no pause yet" "the no-eligible pass did not restart the sustained window"
  pass "a worker whose backend cannot deliver its interrupt is never a candidate and the window restarts"
}

test_stale_high_since_restarts_window() {
  local home out
  home=$(make_home stale)
  add_worker "$home" w 100 4
  mkdir -p "$home/state/load-relief"
  printf '100\n' > "$home/state/load-relief/high-since"
  out=$(run_relief "$home" stale 200 100000)
  assert_contains "$out" "stale high-since restarted the window" "a stale high-since did not restart the window"
  assert_equals "" "$(cat "$TMP_ROOT/stale.log")" "a stale high-since paused a worker at once"
  pass "a stale high-since only restarts the sustained window"
}

test_resume_runs_without_lane_or_with_malformed_config() {
  local home log
  home=$(make_home stranded)
  log="$TMP_ROOT/stranded.log"
  add_worker "$home" w 100 4
  pause_record "$home" w 900 4
  rm "$home/config/lane-capacity"
  run_relief "$home" stranded 5 1000 >/dev/null
  assert_contains "$(cat "$log")" "send w" "a paused worker was stranded when lane-capacity was removed"
  add_worker "$home" w2 100 4
  pause_record "$home" w2 900 4
  printf '4\nmax-load1 20\n' > "$home/config/lane-capacity"
  printf 'bogus line\n' > "$home/config/load-relief"
  out=$(run_relief "$home" stranded 5 1010)
  assert_contains "$(cat "$log")" "send w2" "a paused worker was stranded by a malformed load-relief config"
  assert_contains "$out" "expected key=value" "the malformed config refusal was not printed"
  pass "the resume pass runs without lane-capacity and with a malformed relief config, printing the refusal"
}

test_replaced_worker_record_is_dropped() {
  local home
  home=$(make_home replaced)
  add_worker "$home" w 100 4
  mkdir -p "$home/state/load-relief/paused"
  printf 'id=w\npaused_epoch=900\npriority=4\nspawn_gen=s999.1\nstate=paused\n' > "$home/state/load-relief/paused/w"
  run_relief "$home" replaced 5 1000 >/dev/null
  assert_equals "" "$(cat "$TMP_ROOT/replaced.log")" "a replacement worker was steered by its predecessor's pause record"
  assert_absent "$home/state/load-relief/paused/w" "a mismatched-incarnation record was kept"
  pass "a pause record whose spawn_gen no longer matches is dropped without a steer"
}

test_resume_below_at_or_over_ceiling_refuses() {
  local home out rc
  home=$(make_home badresume)
  add_worker "$home" w 100 4
  printf 'ceiling=16\nresume-below=20\n' > "$home/config/load-relief"
  rc=0; out=$(run_relief "$home" badresume 18 1000) || rc=$?
  expect_code 1 "$rc" "a resume-below over the ceiling did not refuse: $out"
  assert_contains "$out" "resume-below 20 must be under the load ceiling 16" "the refusal did not name the bad resume level"
  printf 'ceiling=16\nresume-below=16\n' > "$home/config/load-relief"
  rc=0; out=$(run_relief "$home" badresume 18 1000) || rc=$?
  expect_code 1 "$rc" "a resume-below equal to the ceiling did not refuse: $out"
  assert_absent "$home/state/load-relief/high-since" "a refused check still acted"
  pass "an explicit resume-below at or over the ceiling refuses rather than silently disabling relief"
}

test_no_lane_capacity_is_a_noop() {
  local home out rc=0
  home=$(make_home noop)
  add_worker "$home" low-prio 100 9
  rm "$home/config/lane-capacity"
  out=$(run_relief "$home" noop 200 2000) || rc=$?
  expect_code 0 "$rc" "an unconfigured check failed: $out"
  assert_equals "" "$(cat "$TMP_ROOT/noop.log")" "an unconfigured check paused a worker"
  assert_absent "$home/state/load-relief/paused/low-prio" "an unconfigured check wrote a pause record"
  pass "without config/lane-capacity a check is a no-op"
}

test_sustained_high_pauses_lowest_then_falling_resumes
test_priority_tie_pauses_newest_dispatch
test_unprioritized_pauses_first_and_absent_never
test_pr_ready_lane_is_not_paused
test_waiting_worker_is_not_paused_and_decision_survives
test_finished_pause_record_dropped_without_steer
test_tab_separated_max_load1_sets_ceiling
test_resume_waits_below_hysteresis_and_staggers
test_failed_interrupt_keeps_uncertain_record
test_buried_decision_is_never_paused
test_decision_after_pause_defers_resume
test_uninterruptible_worker_is_not_a_candidate
test_stale_high_since_restarts_window
test_resume_runs_without_lane_or_with_malformed_config
test_replaced_worker_record_is_dropped
test_resume_below_at_or_over_ceiling_refuses
test_no_lane_capacity_is_a_noop
