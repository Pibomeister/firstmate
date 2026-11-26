#!/usr/bin/env bash
# Behavior tests for host-load throttling of the monitoring paths:
# bin/fm-load-lib.sh interval math, bin/fm-fleet-snapshot.sh single-flight,
# and bin/fm-heartbeat.sh skipping a publication inside the throttled
# interval. Load is injected only through the FM_LOAD_FILE test seam.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
HEARTBEAT="$ROOT/bin/fm-heartbeat.sh"
TMP_ROOT=$(fm_test_tmproot fm-load-throttle)
LOAD_FILE="$TMP_ROOT/load"
HOLDER_PID=

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

cleanup_load() {
  [ -z "$HOLDER_PID" ] || kill -KILL "$HOLDER_PID" >/dev/null 2>&1 || true
}
trap 'cleanup_load; fm_test_cleanup' EXIT

unset FM_HEARTBEAT_BIN
export FM_LOAD_FILE="$LOAD_FILE"

set_load() { printf '%s 0.00 0.00\n' "$1" > "$LOAD_FILE"; }

load_interval() {  # <base>
  bash -c '. "$1/bin/fm-load-lib.sh"; fm_load_interval "$2"' _ "$ROOT" "$1"
}

test_interval_math() {
  set_load 10.00
  assert_equals 15 "$(FM_LOAD_FILE="$LOAD_FILE" load_interval 15)" \
    "a calm load kept the base interval"
  set_load 200.00
  assert_equals 15 "$(FM_LOAD_FILE="$LOAD_FILE" load_interval 15)" \
    "load exactly at the threshold kept the base interval"
  set_load 200.01
  assert_equals 60 "$(FM_LOAD_FILE="$LOAD_FILE" load_interval 15)" \
    "load above the threshold did not quadruple the interval"
  set_load 999.00
  assert_equals 2400 "$(FM_LOAD_FILE="$LOAD_FILE" load_interval 600)" \
    "an extreme load did not quadruple a larger base interval"
  printf 'not-a-load\n' > "$LOAD_FILE"
  assert_equals 15 "$(FM_LOAD_FILE="$LOAD_FILE" load_interval 15)" \
    "an unreadable load throttled the interval instead of leaving it alone"
  rm -f "$LOAD_FILE"
  assert_equals 15 "$(FM_LOAD_FILE="$LOAD_FILE" load_interval 15)" \
    "a missing load seam file throttled the interval instead of leaving it alone"
  # shellcheck disable=SC2016 # $1 is the inner bash -c positional, expanded there.
  assert_equals 15 "$(env -u FM_LOAD_FILE bash -c '. "$1/bin/fm-load-lib.sh"; fm_load_interval 15' _ "$ROOT")" \
    "the test seam without a load file read the host load instead of staying unthrottled"
  pass "load interval follows the threshold and ignores an unreadable load"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

hold_snapshot_lock() {  # <home> <ready-file> <hold-seconds>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$2/.fleet-snapshot.lock" || exit 1
    : > "$3"
    sleep "$4"
  ' _ "$ROOT" "$1/state" "$2" "$3" &
  HOLDER_PID=$!
  for _ in $(seq 1 50); do [ -e "$2" ] && break; sleep 0.1; done
  assert_present "$2" "the lock holder never acquired the snapshot lock"
}

release_snapshot_lock_holder() {
  [ -z "$HOLDER_PID" ] || kill -KILL "$HOLDER_PID" >/dev/null 2>&1 || true
  [ -z "$HOLDER_PID" ] || wait "$HOLDER_PID" 2>/dev/null || true
  HOLDER_PID=
}

test_snapshot_single_flight() {
  local home out rc
  home=$(make_home single-flight)
  hold_snapshot_lock "$home" "$TMP_ROOT/holder-ready" 30
  out=$(FM_HOME="$home" FM_SNAPSHOT_SINGLE_FLIGHT_WAIT=1 "$SNAPSHOT" --json 2>"$TMP_ROOT/snapshot.err"); rc=$?
  expect_code 75 "$rc" "a second snapshot ran while one already held the home lock"
  assert_equals "" "$out" "the refused snapshot still printed a document"
  assert_grep "already running" "$TMP_ROOT/snapshot.err" \
    "the refused snapshot did not name the running one"
  release_snapshot_lock_holder
  out=$(FM_HOME="$home" "$SNAPSHOT" --json); rc=$?
  expect_code 0 "$rc" "the snapshot stayed refused after the lock holder died"
  printf '%s' "$out" | jq -e '.schema == "fm-fleet-snapshot.v1"' >/dev/null \
    || fail "the snapshot after the lock freed did not print its document"
  pass "a second fleet snapshot never starts while one holds the home lock"
}

test_snapshot_releases_lock_on_normal_exit() {
  local home rc
  home=$(make_home single-flight-release)
  FM_HOME="$home" "$SNAPSHOT" --json >/dev/null; rc=$?
  expect_code 0 "$rc" "the snapshot did not finish normally"
  [ ! -e "$home/state/.fleet-snapshot.lock" ] && [ ! -L "$home/state/.fleet-snapshot.lock" ] \
    || fail "a normal snapshot exit left the home lock behind"
  pass "a fleet snapshot releases the home lock when it exits normally"
}

test_snapshot_waits_for_holder_to_finish() {
  local home out rc
  home=$(make_home single-flight-wait)
  hold_snapshot_lock "$home" "$TMP_ROOT/wait-holder-ready" 2
  out=$(FM_HOME="$home" FM_SNAPSHOT_SINGLE_FLIGHT_WAIT=15 "$SNAPSHOT" --json); rc=$?
  release_snapshot_lock_holder
  expect_code 0 "$rc" "a snapshot that waited out the holder did not run"
  printf '%s' "$out" | jq -e '.schema == "fm-fleet-snapshot.v1"' >/dev/null \
    || fail "the snapshot that waited out the holder did not print its document"
  pass "a second fleet snapshot waits for the running one instead of overlapping it"
}

test_snapshot_contribution_input_not_single_flight() {
  local home out rc holder_ready
  home=$(make_home contribution)
  holder_ready="$TMP_ROOT/contribution-holder-ready"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$2/.fleet-snapshot.lock" || exit 1
    : > "$3"
    sleep 30
  ' _ "$ROOT" "$home/state" "$holder_ready" &
  HOLDER_PID=$!
  for _ in $(seq 1 50); do [ -e "$holder_ready" ] && break; sleep 0.1; done
  assert_present "$holder_ready" "the lock holder never acquired the snapshot lock"
  out=$(FM_HOME="$home" "$SNAPSHOT" --contribution-input); rc=$?
  expect_code 0 "$rc" "the cheap contribution-input mode was single-flighted"
  assert_not_equals "" "$out" "the contribution-input mode printed nothing"
  kill -KILL "$HOLDER_PID" >/dev/null 2>&1 || true
  wait "$HOLDER_PID" 2>/dev/null || true
  HOLDER_PID=
  pass "contribution-input stays outside the snapshot single-flight lock"
}

heartbeat_fixture() {  # <name>; sets HB_HOME, COUNT_FILE, and SNAP_SCRIPT
  HB_HOME=$(make_home "$1")
  printf 'stale-grace-secs=0\n' > "$HB_HOME/config/heartbeat"
  COUNT_FILE="$TMP_ROOT/$1.snapshot-count"
  SNAP_SCRIPT="$TMP_ROOT/$1.snapshot.sh"
  printf '0\n' > "$COUNT_FILE"
  cat > "$SNAP_SCRIPT" <<EOF
#!/usr/bin/env bash
n=\$(cat "$COUNT_FILE")
printf '%s\n' \$((n + 1)) > "$COUNT_FILE"
printf '{"schema":"fm-fleet-snapshot.v1","generated":"2026-11-20T17:00:00Z","tasks":[]}\n'
EOF
  chmod +x "$SNAP_SCRIPT"
}

seed_ledger() {  # <home> <generated_epoch> [<published_epoch>] [<throttled>]
  jq -n --argjson g "$2" --argjson p "${3:-$2}" --argjson t "${4:-true}" \
    '{schema:"fm-heartbeat.v1",generated_epoch:$g,published_epoch:$p,throttled:$t}' > "$1/state/heartbeat.json"
}

run_heartbeat() {  # <home>
  FM_HOME="$1" FM_HEARTBEAT_CYCLE_SECS=100 FM_HEARTBEAT_NOW=2026-11-20T17:00:00Z \
    FM_HEARTBEAT_SNAPSHOT_SCRIPT="$SNAP_SCRIPT" FM_LOAD_FILE="$LOAD_FILE" \
    "$HEARTBEAT" --write >/dev/null 2>&1
}

NOW_EPOCH=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' 2026-11-20T17:00:00Z +%s 2>/dev/null \
  || date -u -d 2026-11-20T17:00:00Z +%s)

test_heartbeat_skips_inside_throttled_interval() {
  heartbeat_fixture hb-skip
  seed_ledger "$HB_HOME" $((NOW_EPOCH - 10))
  set_load 300.00
  run_heartbeat "$HB_HOME"
  assert_equals 0 "$(cat "$COUNT_FILE")" \
    "the heartbeat republished inside the throttled interval"
  assert_equals $((NOW_EPOCH - 10)) "$(jq -r .generated_epoch "$HB_HOME/state/heartbeat.json")" \
    "the skipped heartbeat rewrote the ledger"
  pass "heartbeat skips a publication inside the throttled interval"
}

test_heartbeat_publishes_when_calm_or_due() {
  heartbeat_fixture hb-calm
  seed_ledger "$HB_HOME" $((NOW_EPOCH - 10))
  set_load 10.00
  run_heartbeat "$HB_HOME"
  assert_equals 1 "$(cat "$COUNT_FILE")" \
    "a calm heartbeat did not publish on its ordinary cadence"
  heartbeat_fixture hb-due
  seed_ledger "$HB_HOME" $((NOW_EPOCH - 401))
  set_load 300.00
  run_heartbeat "$HB_HOME"
  assert_equals 1 "$(cat "$COUNT_FILE")" \
    "a throttled heartbeat never published again once its interval elapsed"
  heartbeat_fixture hb-paced
  seed_ledger "$HB_HOME" $((NOW_EPOCH - 400)) $((NOW_EPOCH - 390))
  set_load 300.00
  run_heartbeat "$HB_HOME"
  assert_equals 1 "$(cat "$COUNT_FILE")" \
    "a launch one throttled interval after the prior launch skipped because the prior run published late"
  heartbeat_fixture hb-jitter
  seed_ledger "$HB_HOME" $((NOW_EPOCH - 399))
  set_load 300.00
  run_heartbeat "$HB_HOME"
  assert_equals 1 "$(cat "$COUNT_FILE")" \
    "a launch one second short of the throttled interval skipped, doubling the publication gap"
  pass "heartbeat publishes on the ordinary cadence when calm and again once a throttled interval elapses"
}

test_heartbeat_first_hot_launch_publishes_after_calm() {
  local calm_bound
  heartbeat_fixture hb-transition
  set_load 10.00
  run_heartbeat "$HB_HOME"
  calm_bound=$(jq -r .stale_after_secs "$HB_HOME/state/heartbeat.json")
  seed_ledger "$HB_HOME" $((NOW_EPOCH - 10)) $((NOW_EPOCH - 10)) false
  set_load 300.00
  run_heartbeat "$HB_HOME"
  assert_equals 2 "$(cat "$COUNT_FILE")" \
    "the first launch under load skipped after a calm publication whose bound never counted the throttled cycle"
  assert_equals true "$(jq -r .throttled "$HB_HOME/state/heartbeat.json")" \
    "the first throttled publication did not record throttled:true"
  assert_equals $((calm_bound + 300)) "$(jq -r .stale_after_secs "$HB_HOME/state/heartbeat.json")" \
    "the first throttled publication did not publish the extended stale bound"
  run_heartbeat "$HB_HOME"
  assert_equals 2 "$(cat "$COUNT_FILE")" \
    "the launch after a throttled publication did not skip inside the throttled interval"
  pass "the first launch under load publishes the extended bound and the next one skips"
}

test_heartbeat_stale_bound_uses_throttled_cycle() {
  local calm hot
  heartbeat_fixture hb-stale
  set_load 10.00
  run_heartbeat "$HB_HOME"
  calm=$(jq -r .stale_after_secs "$HB_HOME/state/heartbeat.json")
  seed_ledger "$HB_HOME" $((NOW_EPOCH - 100000))
  set_load 300.00
  run_heartbeat "$HB_HOME"
  hot=$(jq -r .stale_after_secs "$HB_HOME/state/heartbeat.json")
  assert_equals $((calm + 300)) "$hot" \
    "the stale bound did not grow by the throttled cycle difference"
  pass "heartbeat stale bound counts the throttled cycle"
}

test_heartbeat_bound_uses_launch_factor() {
  local calm
  heartbeat_fixture hb-launch-factor
  set_load 10.00
  run_heartbeat "$HB_HOME"
  calm=$(jq -r .stale_after_secs "$HB_HOME/state/heartbeat.json")
  rm -f "$HB_HOME/state/heartbeat.json"
  FM_HEARTBEAT_LOAD_FACTOR=4 run_heartbeat "$HB_HOME"
  assert_equals $((calm + 300)) "$(jq -r .stale_after_secs "$HB_HOME/state/heartbeat.json")" \
    "a launch the watcher scheduled throttled published a calm bound because the load fell during the run"
  assert_equals true "$(jq -r .throttled "$HB_HOME/state/heartbeat.json")" \
    "a launch the watcher scheduled throttled did not record throttled:true"
  set_load 300.00
  rm -f "$HB_HOME/state/heartbeat.json"
  FM_HEARTBEAT_LOAD_FACTOR=1 run_heartbeat "$HB_HOME"
  assert_equals "$calm" "$(jq -r .stale_after_secs "$HB_HOME/state/heartbeat.json")" \
    "a launch the watcher scheduled calm published a bound from a later hot reading"
  pass "heartbeat stale bound follows the throttle factor its launch was scheduled with"
}

fm_test_run \
  test_interval_math \
  test_snapshot_single_flight \
  test_snapshot_releases_lock_on_normal_exit \
  test_snapshot_waits_for_holder_to_finish \
  test_snapshot_contribution_input_not_single_flight \
  test_heartbeat_skips_inside_throttled_interval \
  test_heartbeat_publishes_when_calm_or_due \
  test_heartbeat_first_hot_launch_publishes_after_calm \
  test_heartbeat_stale_bound_uses_throttled_cycle \
  test_heartbeat_bound_uses_launch_factor
