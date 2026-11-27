#!/usr/bin/env bash
# Behavioral tests for bin/fm-rsi-instrument.sh, read through bin/fm-rsi-measure.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-rsi-instrument.sh"
MEASURE="$ROOT/bin/fm-rsi-measure.sh"
TMP_ROOT=$(fm_test_tmproot fm-rsi-instrument)
NOW=1795759200
START=2026-11-20T06:00:00Z
END=2026-11-27T06:00:00Z
URL1=https://github.com/acme/widget/pull/1
URL3=https://github.com/acme/widget/pull/3
URL4=https://github.com/acme/widget/pull/4

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

write_msg() {  # <path> <utc-iso>
  mkdir -p "$(dirname "$1")"
  printf 'schema=fm-task-inbox.v1\nat=%s\n--\nsteer\n' "$2" >"$1"
}

# Epochs: 1795499000 is 2026-11-24T05:43:20Z, 1795500000 is 06:00:00Z,
# 1795501500 is 06:25:00Z, 1795502000 is 06:33:20Z, 1795503000 is 06:50:00Z.
build_home() {
  local home=$1 st
  st=$home/state
  mkdir -p "$st"
  printf 'kind=ship\npr=%s\n' "$URL1" >"$st/task-a.meta"
  cat >"$st/task-a.status" <<EOF
blocked [at=1795499000]: an earlier incarnation, before dispatch
working [at=1795500100]: started
needs-decision [at=1795500900] [key=nm-review]: ask-user findings
resolved [at=1795501000] [key=nm-review]: answered
done [at=1795502000]: PR $URL1 checks green at abc1234
needs-decision [at=1795503000] [key=merge]: after green
EOF
  write_msg "$st/task-a.inbox/handled/001.msg" 2026-11-24T05:43:20Z
  write_msg "$st/task-a.inbox/handled/002.msg" 2026-11-24T06:25:00Z
  write_msg "$st/task-a.inbox/003.msg" 2026-11-24T06:50:00Z
  printf 'kind=ship\npr=%s\n' "$URL3" >"$st/task-c.meta"
  printf 'done [at=1795502000]: PR %s checks green at def5678\n' "$URL3" >"$st/task-c.status"
  printf 'kind=ship\npr=%s\n' "$URL4" >"$st/task-d.meta"
  printf 'done [at=1795502000]: committed on the branch\n' >"$st/task-d.status"
  printf '2026-11-24T06:00:00Z\t1795500000\tdispatched\tgoal-a\ttask=task-a note=x\n2026-11-24T07:00:00Z\t1795503600\tdispatched\tgoal-b\ttask=task-a note=later\n' >"$st/dispatch-log.tsv"
}

build_db() {
  python3 - "$1" "$URL1" <<'PY'
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
db.executescript(
    "CREATE TABLE runs (id TEXT PRIMARY KEY, pr_url TEXT);"
    "CREATE TABLE step_results (id TEXT PRIMARY KEY, run_id TEXT, step_name TEXT);"
    "CREATE TABLE step_rounds (id TEXT PRIMARY KEY, step_result_id TEXT, round INTEGER);"
)
url = sys.argv[2]
db.executemany("INSERT INTO runs VALUES (?, ?)", [("r1", url), ("r2", url), ("r3", "https://github.com/acme/widget/pull/9")])
db.executemany(
    "INSERT INTO step_results VALUES (?, ?, ?)",
    [("s1", "r1", "review"), ("s2", "r1", "test"), ("s3", "r2", "review"), ("s4", "r3", "review")],
)
db.executemany(
    "INSERT INTO step_rounds VALUES (?, ?, ?)",
    [("a", "s1", 1), ("b", "s1", 2), ("c", "s1", 3), ("d", "s2", 1), ("e", "s3", 1), ("f", "s4", 1)],
)
db.commit()
PY
}

write_input() {
  cat >"$1" <<'EOF'
{
  "merged": [
    {"repo": "acme/widget", "number": 1, "created_at": "2026-11-24T05:00:00Z", "merged_at": "2026-11-24T08:00:00Z", "review_rounds": 1, "interventions_before_green": null, "reached_green": null},
    {"repo": "acme/widget", "number": 2, "created_at": "2026-11-24T05:00:00Z", "merged_at": "2026-11-24T08:00:00Z", "review_rounds": 2, "interventions_before_green": null, "reached_green": null},
    {"repo": "acme/widget", "number": 3, "created_at": "2026-11-24T05:00:00Z", "merged_at": "2026-11-24T08:00:00Z", "review_rounds": null, "interventions_before_green": null, "reached_green": null},
    {"repo": "acme/widget", "number": 4, "created_at": "2026-11-24T05:00:00Z", "merged_at": "2026-11-24T08:00:00Z", "review_rounds": null, "interventions_before_green": null, "reached_green": null}
  ],
  "open": [
    {"repo": "acme/widget", "number": 20, "created_at": "2026-11-26T12:00:00Z", "is_draft": false, "failing_checks": 0, "pending_checks": 0, "changes_requested": false, "reported_checks": 1, "conflict": false}
  ]
}
EOF
}

row() {  # <json-file> <number> <field>
  jq -c --argjson n "$2" --arg f "$3" '.merged[] | select(.number == $n) | .[$f]' "$1"
}

test_fills_instrument_fields_from_home_and_run_records() {
  local home=$TMP_ROOT/home out=$TMP_ROOT/filled.json rc reading
  build_home "$home"
  build_db "$TMP_ROOT/state.sqlite"
  write_input "$TMP_ROOT/input.json"
  set +e
  "$SCRIPT" --input "$TMP_ROOT/input.json" --home "$home" --nm-db "$TMP_ROOT/state.sqlite" >"$out" 2>"$TMP_ROOT/err"
  rc=$?
  set -e
  expect_code 0 "$rc" "a producer run over a fixture home"
  assert_equals "4" "$(row "$out" 1 review_rounds)" "three review rounds plus one, from both runs, and no test-step round"
  assert_equals '"no-mistakes"' "$(row "$out" 1 review_rounds_source)" "a run record outranks the forge count"
  assert_equals "true" "$(row "$out" 1 reached_green)" "a done line with checks green is reached"
  assert_equals "2" "$(row "$out" 1 interventions_before_green)" "one decision and one steer between dispatch and green"
  assert_equals "2" "$(row "$out" 2 review_rounds)" "no run record keeps the forge count"
  assert_equals '"forge"' "$(row "$out" 2 review_rounds_source)" "the forge fallback is named"
  assert_equals "null" "$(row "$out" 2 reached_green)" "no task record is unknown"
  assert_equals "null" "$(row "$out" 3 review_rounds)" "no run and no forge count stays unknown"
  assert_equals "0" "$(row "$out" 3 interventions_before_green)" "a clean task has zero interventions"
  assert_equals "null" "$(row "$out" 4 reached_green)" "a done line without checks green is unknown, not failed"
  assert_equals "null" "$(row "$out" 4 interventions_before_green)" "an unknown green leaves the count unknown"
  assert_equals "1" "$(jq '.open | length' "$out")" "open rows pass through"
  set +e
  reading=$("$MEASURE" --input "$out" --now "$NOW" --window-start "$START" --window-end "$END" 2>"$TMP_ROOT/measure.err")
  rc=$?
  set -e
  expect_code 0 "$rc" "the measure command accepts the producer output"
  assert_contains "$reading" "review_rounds repo=acme/widget median=3.00 max=4 n=2 missing=2" "unknown rounds stay missing"
  assert_contains "$reading" "intervention_free repo=acme/widget free=1 completed=2 missing=2" "unknown green stays missing, never zero"
  pass "instrument fields come from status, inbox, dispatch, and run records"
}

test_without_run_records_the_forge_count_stays() {
  local home=$TMP_ROOT/home2 out=$TMP_ROOT/forge.json rc
  build_home "$home"
  write_input "$TMP_ROOT/input2.json"
  set +e
  "$SCRIPT" --input "$TMP_ROOT/input2.json" --home "$home" >"$out" 2>"$TMP_ROOT/err2"
  rc=$?
  set -e
  expect_code 0 "$rc" "a producer run without a run database"
  assert_equals "1" "$(row "$out" 1 review_rounds)" "the forge count stays without a run database"
  assert_equals '"forge"' "$(row "$out" 1 review_rounds_source)" "the source says forge"
  pass "without run records the forge count stays and is named"
}

test_refusals() {
  local rc
  write_input "$TMP_ROOT/input3.json"
  set +e
  "$SCRIPT" --input "$TMP_ROOT/input3.json" --home "$TMP_ROOT/missing-home" >/dev/null 2>"$TMP_ROOT/err3"
  rc=$?
  set -e
  expect_code 2 "$rc" "a home without a state directory"
  printf '%s\n' '{"merged":[{"repo":"bad repo","number":1}],"open":[]}' >"$TMP_ROOT/bad.json"
  mkdir -p "$TMP_ROOT/home3/state"
  set +e
  "$SCRIPT" --input "$TMP_ROOT/bad.json" --home "$TMP_ROOT/home3" >/dev/null 2>"$TMP_ROOT/err4"
  rc=$?
  set -e
  expect_code 2 "$rc" "a malformed repository name"
  set +e
  "$SCRIPT" --help >/dev/null
  rc=$?
  set -e
  expect_code 0 "$rc" "help"
  pass "missing home, malformed input, and help"
}

fm_test_run \
  test_fills_instrument_fields_from_home_and_run_records \
  test_without_run_records_the_forge_count_stays \
  test_refusals
