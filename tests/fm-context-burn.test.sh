#!/usr/bin/env bash
# Behavior tests for the external auto-compact footer recorder.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BURN="$ROOT/bin/fm-context-burn.sh"
TMP_ROOT=$(fm_test_tmproot fm-context-burn)

prepare() { # <home>
  mkdir -p "$1/state" "$1/data"
}

record_at() { # <home> <now> <turn> <session> <percent>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" \
    FM_CONTEXT_BURN_NOW="$2" \
    "$BURN" record --turn-type "$3" --session "$4" --percent "$5"
}

row_count() { # <home>
  if [ -f "$1/state/context-burn.tsv" ]; then
    wc -l < "$1/state/context-burn.tsv" | tr -d ' '
  else
    printf '0\n'
  fi
}

last_row() { # <home>
  tail -n 1 "$1/state/context-burn.tsv"
}

wake_count() { # <home> <key>
  if [ ! -f "$1/state/.wake-queue" ]; then
    printf '0\n'
    return 0
  fi
  awk -F '\t' -v key="$2" '$4 == key { n++ } END { print n + 0 }' "$1/state/.wake-queue"
}

test_footer_shapes_and_percent_bounds() {
  local home=$TMP_ROOT/shapes out status
  prepare "$home"
  printf '%s\n' 'mate said 3% until auto-compact' '12% until auto-compact' > "$home/plain.txt"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONTEXT_BURN_NOW=1000 \
    "$BURN" record --turn-type captain --session s1 --footer-file "$home/plain.txt")
  status=$?
  expect_code 0 "$status" "plain footer"
  assert_equals $'1000\ts1\tcaptain\t12' "$(last_row "$home")" "plain footer row"

  printf '%s\n' 'context 44% until auto-compact now' > "$home/mid.txt"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONTEXT_BURN_NOW=1001 \
    "$BURN" record --turn-type captain --session s1 --footer-file "$home/mid.txt" >/dev/null
  assert_equals $'1001\ts1\tcaptain\t44' "$(last_row "$home")" "embedded footer row"

  printf '%s\n' 'Context left until auto-compact: 7%' > "$home/colon.txt"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONTEXT_BURN_NOW=1002 \
    "$BURN" record --turn-type captain --session s1 --footer-file "$home/colon.txt" >/dev/null
  assert_equals $'1002\ts1\tcaptain\t7' "$(last_row "$home")" "colon footer row"

  printf '%s\n' '101% until auto-compact' > "$home/over.txt"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONTEXT_BURN_NOW=1003 \
    "$BURN" record --turn-type captain --session s1 --footer-file "$home/over.txt")
  status=$?
  expect_code 0 "$status" "over-range footer"
  assert_equals 3 "$(row_count "$home")" "over-range footer wrote a sample"
  assert_equals '' "$out" "over-range footer printed output"

  printf '%s\n' 'no footer here' > "$home/none.txt"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONTEXT_BURN_NOW=1004 \
    "$BURN" record --turn-type captain --session s1 --footer-file "$home/none.txt")
  status=$?
  expect_code 0 "$status" "missing footer"
  assert_equals 3 "$(row_count "$home")" "missing footer wrote a sample"

  out=$(record_at "$home" 1005 captain s1 100)
  status=$?
  expect_code 0 "$status" "percent 100"
  assert_equals $'1005\ts1\tcaptain\t100' "$(last_row "$home")" "percent 100 row"

  out=$(record_at "$home" 1006 captain s1 101 2>&1)
  status=$?
  expect_code 2 "$status" "percent 101"
  assert_equals 4 "$(row_count "$home")" "percent 101 wrote a sample"
  assert_contains "$out" "0 to 100" "percent 101 did not name the bound"
  pass "footer shapes and percent bounds"
}

test_drop_window_and_freshness() {
  local home=$TMP_ROOT/drop out
  prepare "$home"
  record_at "$home" 10000 captain s1 90 >/dev/null
  out=$(record_at "$home" 10100 captain s1 61)
  assert_not_contains "$out" "alert:" "a 29 point drop alerted"
  assert_equals 0 "$(wake_count "$home" context-burn-s1)" "wake after a 29 point drop"
  [ ! -e "$home/state/.context-burn-alert.s1" ] || fail "marker after a 29 point drop"

  out=$(record_at "$home" 10200 captain s1 60)
  assert_contains "$out" "alert: s1 dropped from 90 to 60 in 200s turn captain" "a 30 point drop did not alert"
  assert_equals 1 "$(wake_count "$home" context-burn-s1)" "wake missing after a 30 point drop"
  assert_contains "$(cat "$home/state/.wake-queue")" "check: context burn session s1 dropped from 90 to 60 in 200s turn captain" "wake payload"

  home=$TMP_ROOT/late
  prepare "$home"
  record_at "$home" 10000 captain s1 90 >/dev/null
  out=$(record_at "$home" 10901 captain s1 40)
  assert_not_contains "$out" "alert:" "a drop older than 15 minutes alerted"
  assert_equals 0 "$(wake_count "$home" context-burn-s1)" "wake for a drop outside the window"

  home=$TMP_ROOT/old
  prepare "$home"
  record_at "$home" 10000 captain s1 80 >/dev/null
  record_at "$home" 16301 captain s1 90 >/dev/null
  out=$(record_at "$home" 17201 captain s1 40)
  assert_not_contains "$out" "alert:" "a session older than two hours alerted"

  home=$TMP_ROOT/young
  prepare "$home"
  record_at "$home" 10000 captain s1 80 >/dev/null
  record_at "$home" 16300 captain s1 90 >/dev/null
  out=$(record_at "$home" 17200 captain s1 40)
  assert_contains "$out" "alert: s1 dropped from 90 to 40 in 900s turn captain" "a two-hour-old fresh session did not alert"
  pass "drop, window, and freshness"
}

test_alert_once_then_again_after_recovery() {
  local home=$TMP_ROOT/once out
  prepare "$home"
  record_at "$home" 30000 captain s1 90 >/dev/null
  out=$(record_at "$home" 30100 captain s1 50)
  assert_contains "$out" "alert:" "first drop did not alert"
  out=$(record_at "$home" 30103 heartbeat s1 50)
  assert_not_contains "$out" "alert:" "the same drop alerted twice"
  assert_equals 1 "$(wake_count "$home" context-burn-s1)" "wake count while the drop still holds"
  [ -e "$home/state/.context-burn-alert.s1" ] || fail "marker missing while the drop holds"

  record_at "$home" 30200 captain s1 88 >/dev/null
  [ ! -e "$home/state/.context-burn-alert.s1" ] || fail "marker stayed after the drop cleared"

  out=$(record_at "$home" 30300 captain s1 50)
  assert_contains "$out" "alert: s1 dropped from 90 to 50 in 300s turn captain" "a later drop did not alert again"
  assert_equals 2 "$(wake_count "$home" context-burn-s1)" "second wake missing after recovery"
  pass "one alert until the drop clears, then another"
}

test_unknown_session_and_dedupe() {
  local home=$TMP_ROOT/unknown out
  prepare "$home"
  record_at "$home" 40000 captain unknown 90 >/dev/null
  out=$(record_at "$home" 40100 captain unknown 40)
  assert_not_contains "$out" "alert:" "an unknown session alerted"
  assert_equals 0 "$(wake_count "$home" context-burn-unknown)" "wake for an unknown session"
  assert_equals 2 "$(row_count "$home")" "unknown session was not recorded"
  [ ! -e "$home/state/.context-burn-alert.unknown" ] || fail "marker for an unknown session"

  home=$TMP_ROOT/dedupe
  prepare "$home"
  record_at "$home" 5000 captain s1 40 >/dev/null
  record_at "$home" 5001 captain s1 40 >/dev/null
  assert_equals 1 "$(row_count "$home")" "duplicate sample inside two seconds was written"
  record_at "$home" 5003 captain s1 40 >/dev/null
  assert_equals 2 "$(row_count "$home")" "sample after two seconds was dropped"
  record_at "$home" 5003 wake s1 40 >/dev/null
  assert_equals 3 "$(row_count "$home")" "a different turn type was treated as a duplicate"
  pass "unknown sessions record without alerting, and identical samples dedupe"
}

test_auto_turn_type_from_tailed_transcript() {
  local home=$TMP_ROOT/auto out
  prepare "$home"
  printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"check: fleet"}]}}' > "$home/t.jsonl"
  printf '%s\n' "{\"session_id\":\"sess1\",\"transcript_path\":\"$home/t.jsonl\"}" > "$home/p.json"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONTEXT_BURN_NOW=6000 \
    "$BURN" record --turn-type auto --percent 70 --payload-file "$home/p.json" >/dev/null
  assert_equals $'6000\tsess1\twake\t70' "$(last_row "$home")" "wake classification"

  printf '%s\n' '{"type":"user","message":{"content":"SUPERVISION OPERATING INSTRUCTIONS heartbeat: check:"}}' > "$home/t.jsonl"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONTEXT_BURN_NOW=6010 \
    "$BURN" record --turn-type auto --percent 69 --payload-file "$home/p.json" >/dev/null
  assert_equals $'6010\tsess1\tstartup\t69' "$(last_row "$home")" "startup wins over other markers"

  : > "$home/t.jsonl"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONTEXT_BURN_NOW=6020 \
    "$BURN" record --turn-type auto --percent 68 --payload-file "$home/p.json" >/dev/null
  assert_equals $'6020\tsess1\tturn\t68' "$(last_row "$home")" "empty transcript is a turn"
  pass "auto turn type comes from the tailed transcript"
}

test_report_line() {
  local home=$TMP_ROOT/report out status sum
  prepare "$home"
  printf 'hello\n' > "$home/data/note.txt"
  sum=$(shasum -a 256 "$home/data/note.txt" | awk '{print $1}')
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$BURN" report "$home/data/note.txt")
  status=$?
  expect_code 0 "$status" "report under data"
  assert_equals "data/note.txt $sum" "$out" "report line"

  printf 'there\n' > "$home/state/secret.txt"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$BURN" report "$home/data/../state/secret.txt" 2>&1)
  status=$?
  expect_code 1 "$status" "report outside data"
  assert_not_contains "$out" "secret" "outside report leaked the file"

  ln -s "$home/data/note.txt" "$home/data/link.txt"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$BURN" report "$home/data/link.txt" 2>&1)
  status=$?
  expect_code 1 "$status" "report symlink"
  pass "report prints one path and sha under data and refuses the rest"
}

test_unmeasured_non_primary_writes_nothing() {
  local home=$TMP_ROOT/scope out status
  prepare "$home"
  out=$(env -u FM_TEST_SEAM -u FM_CONTEXT_BURN_CAPTURE \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONTEXT_BURN_NOW=7000 \
    "$BURN" record --turn-type auto --session s1 2>&1)
  status=$?
  expect_code 0 "$status" "unmeasured non-primary"
  assert_equals 0 "$(row_count "$home")" "unmeasured non-primary wrote a sample"
  assert_equals '' "$out" "unmeasured non-primary printed output"
  pass "an unmeasured record outside a primary home writes nothing"
}

fm_test_run \
  test_footer_shapes_and_percent_bounds \
  test_drop_window_and_freshness \
  test_alert_once_then_again_after_recovery \
  test_unknown_session_and_dedupe \
  test_auto_turn_type_from_tailed_transcript \
  test_report_line \
  test_unmeasured_non_primary_writes_nothing
