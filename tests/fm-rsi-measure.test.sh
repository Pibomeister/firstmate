#!/usr/bin/env bash
# Behavioral tests for bin/fm-rsi-measure.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-rsi-measure.sh"
TMP_ROOT=$(fm_test_tmproot fm-rsi-measure)
NOW=1795759200
START=2026-11-20T06:00:00Z
END=2026-11-27T06:00:00Z

command -v jq >/dev/null 2>&1 || fail "jq is required"

run_measure() {
  "$SCRIPT" --input "$1" --now "$NOW" --window-start "$START" --window-end "$END"
}

test_median_aged_classes_and_instruments() {
  local out rc fixture
  fixture=$TMP_ROOT/reading.json
  cat > "$fixture" <<'EOF'
{
  "merged": [
    {
      "repo": "acme/widget",
      "number": 1,
      "created_at": "2026-11-20T06:00:00Z",
      "merged_at": "2026-11-20T18:00:00Z",
      "review_rounds": 1,
      "interventions_before_green": 0,
      "reached_green": true
    },
    {
      "repo": "acme/widget",
      "number": 2,
      "created_at": "2026-11-21T06:00:00Z",
      "merged_at": "2026-11-22T06:00:00Z",
      "review_rounds": 3,
      "interventions_before_green": 2,
      "reached_green": true
    },
    {
      "repo": "acme/widget",
      "number": 3,
      "created_at": "2026-11-19T06:00:00Z",
      "merged_at": "2026-11-19T12:00:00Z",
      "review_rounds": 9,
      "interventions_before_green": 0,
      "reached_green": true
    }
  ],
  "open": [
    {
      "repo": "acme/widget",
      "number": 10,
      "created_at": "2026-11-25T06:00:00Z",
      "is_draft": true,
      "failing_checks": 4,
      "pending_checks": 0,
      "changes_requested": false,
      "reported_checks": 4,
      "conflict": false
    },
    {
      "repo": "acme/widget",
      "number": 11,
      "created_at": "2026-11-26T06:00:00Z",
      "is_draft": false,
      "failing_checks": 0,
      "pending_checks": 0,
      "changes_requested": false,
      "reported_checks": 2,
      "conflict": false
    },
    {
      "repo": "acme/widget",
      "number": 12,
      "created_at": "2026-11-20T06:00:00Z",
      "is_draft": false,
      "failing_checks": 1,
      "pending_checks": 0,
      "changes_requested": true,
      "reported_checks": 3,
      "conflict": true
    },
    {
      "repo": "acme/widget",
      "number": 13,
      "created_at": "2026-11-20T07:00:00Z",
      "is_draft": false,
      "failing_checks": 0,
      "pending_checks": 0,
      "changes_requested": true,
      "reported_checks": 1,
      "conflict": false
    },
    {
      "repo": "acme/widget",
      "number": 14,
      "created_at": "2026-11-20T08:00:00Z",
      "is_draft": false,
      "failing_checks": 0,
      "pending_checks": 0,
      "changes_requested": false,
      "reported_checks": 1,
      "conflict": true
    },
    {
      "repo": "acme/widget",
      "number": 15,
      "created_at": "2026-11-20T09:00:00Z",
      "is_draft": false,
      "failing_checks": 0,
      "pending_checks": 2,
      "changes_requested": false,
      "reported_checks": 1,
      "conflict": false
    },
    {
      "repo": "acme/widget",
      "number": 16,
      "created_at": "2026-11-20T10:00:00Z",
      "is_draft": false,
      "failing_checks": 0,
      "pending_checks": 0,
      "changes_requested": false,
      "reported_checks": 0,
      "conflict": false
    },
    {
      "repo": "acme/widget",
      "number": 17,
      "created_at": "2026-11-20T11:00:00Z",
      "is_draft": null,
      "failing_checks": null,
      "pending_checks": null,
      "changes_requested": null,
      "reported_checks": null,
      "conflict": null
    },
    {
      "repo": "acme/widget",
      "number": 18,
      "created_at": "2026-11-20T12:00:00Z",
      "is_draft": false,
      "failing_checks": 0,
      "pending_checks": 0,
      "changes_requested": false,
      "reported_checks": 2,
      "conflict": false
    }
  ]
}
EOF
  # 1795759200 is 2026-11-27T06:00:00Z. Number 11 was created exactly 24 hours earlier.
  set +e
  out=$(run_measure "$fixture" 2>"$TMP_ROOT/err")
  rc=$?
  set -e
  expect_code 0 "$rc" "a complete fixture reading"
  assert_contains "$out" "median repo=acme/widget hours=18.00 n=2" "even median is the mean of 12h and 24h, and the pull request outside the window stays out"
  assert_contains "$out" "aged repo=acme/widget numerator=8 denominator=9" "exactly 24 hours is not older than 24 hours"
  assert_contains "$out" "review_rounds repo=acme/widget median=2.00 max=3 n=2 missing=0" "review rounds use only the in-window pull requests"
  assert_contains "$out" "intervention_free repo=acme/widget free=1 completed=2 missing=0" "a later landing approval is outside interventions_before_green"
  assert_contains "$out" "class repo=acme/widget number=10 class=draft" "a draft stays a draft when checks are also failing"
  assert_not_contains "$out" "number=11 class=" "a pull request aged exactly 24 hours has no class line"
  assert_contains "$out" "number=12 class=failing-checks" "failing checks outrank a requested change and a conflict"
  assert_contains "$out" "number=13 class=changes-requested" "a requested change outranks a clean check list"
  assert_contains "$out" "number=14 class=conflict" "a conflict is its own class once checks and review are clear"
  assert_contains "$out" "number=15 class=pending-checks" "pending checks are explained"
  assert_contains "$out" "number=16 class=pending-checks" "zero reported checks are pending, not unexplained"
  assert_contains "$out" "number=17 class=unexplained" "missing evidence is the only unexplained class"
  assert_contains "$out" "number=18 class=green-waiting" "a complete row with clear checks is waiting, not unexplained"
  pass "median, aged count, classes, review rounds, and intervention-free completion"
}

test_missing_instrument_fields_stay_out_of_the_rate() {
  local out rc fixture
  fixture=$TMP_ROOT/partial.json
  cat > "$fixture" <<'EOF'
{
  "merged": [
    {
      "repo": "acme/kit",
      "number": 4,
      "created_at": "2026-11-22T06:00:00Z",
      "merged_at": "2026-11-22T09:00:00Z",
      "review_rounds": null,
      "interventions_before_green": null,
      "reached_green": true
    },
    {
      "repo": "acme/kit",
      "number": 5,
      "created_at": "2026-11-22T06:00:00Z",
      "merged_at": "2026-11-22T08:00:00Z",
      "review_rounds": 1,
      "interventions_before_green": 0,
      "reached_green": true
    },
    {
      "repo": "acme/kit",
      "number": 6,
      "created_at": "2026-11-22T06:00:00Z",
      "merged_at": "2026-11-22T10:00:00Z",
      "review_rounds": 4,
      "interventions_before_green": null,
      "reached_green": false
    }
  ],
  "open": []
}
EOF
  set +e
  out=$(run_measure "$fixture" 2>"$TMP_ROOT/err-partial")
  rc=$?
  set -e
  expect_code 0 "$rc" "a partial instrument reading"
  assert_contains "$out" "median repo=acme/kit hours=3.00 n=3" "the middle of 2h, 3h, and 4h is 3h"
  assert_contains "$out" "review_rounds repo=acme/kit median=2.50 max=4 n=2 missing=1" "a null review round is missing, not zero"
  assert_contains "$out" "intervention_free repo=acme/kit free=1 completed=1 missing=1" "a false reached_green is neither completed nor missing, and a null intervention count on a true reached_green is missing"
  assert_contains "$out" "aged repo=acme/kit numerator=0 denominator=0" "an empty open list is a zero denominator"
  pass "missing review-round and intervention fields stay out of the rates"
}

test_duplicate_and_bad_time_refuse() {
  local rc
  printf '%s\n' '{"merged":[{"repo":"acme/widget","number":1,"created_at":"2026-11-20T06:00:00Z","merged_at":"2026-11-21T06:00:00Z","review_rounds":0,"interventions_before_green":0,"reached_green":true},{"repo":"acme/widget","number":1,"created_at":"2026-11-20T06:00:00Z","merged_at":"2026-11-21T07:00:00Z","review_rounds":0,"interventions_before_green":0,"reached_green":true}],"open":[]}' > "$TMP_ROOT/dup.json"
  set +e
  "$SCRIPT" --input "$TMP_ROOT/dup.json" --now "$NOW" --window-start "$START" --window-end "$END" >/dev/null 2>"$TMP_ROOT/dup.err"
  rc=$?
  set -e
  expect_code 2 "$rc" "a duplicate pull request"
  assert_contains "$(cat "$TMP_ROOT/dup.err")" "duplicate" "the refusal names the duplicate"
  printf '%s\n' '{"merged":[],"open":[{"repo":"acme/widget","number":2,"created_at":"yesterday","is_draft":false,"failing_checks":0,"pending_checks":0,"changes_requested":false,"reported_checks":1,"conflict":false}]}' > "$TMP_ROOT/bad.json"
  set +e
  "$SCRIPT" --input "$TMP_ROOT/bad.json" --now "$NOW" --window-start "$START" --window-end "$END" >/dev/null 2>"$TMP_ROOT/bad.err"
  rc=$?
  set -e
  expect_code 2 "$rc" "a malformed timestamp"
  pass "duplicate rows and malformed timestamps refuse"
}

test_usage_refuses_without_reading_a_fixture() {
  local rc
  set +e
  "$SCRIPT" --help >/dev/null
  rc=$?
  set -e
  expect_code 0 "$rc" "help"
  set +e
  "$SCRIPT" >/dev/null 2>"$TMP_ROOT/usage.err"
  rc=$?
  set -e
  expect_code 2 "$rc" "missing arguments"
  pass "help succeeds and a bare invocation refuses"
}

fm_test_run \
  test_median_aged_classes_and_instruments \
  test_missing_instrument_fields_stay_out_of_the_rate \
  test_duplicate_and_bad_time_refuse \
  test_usage_refuses_without_reading_a_fixture
