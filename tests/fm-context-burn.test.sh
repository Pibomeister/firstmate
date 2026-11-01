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

test_percent_bounds_and_turn_types() {
  local home=$TMP_ROOT/bounds out status
  prepare "$home"
  out=$(record_at "$home" 1005 captain s1 100)
  status=$?
  expect_code 0 "$status" "percent 100"
  assert_equals $'1005\ts1\tcaptain\t100' "$(last_row "$home")" "percent 100 row"

  out=$(record_at "$home" 1006 captain s1 101 2>&1)
  status=$?
  expect_code 2 "$status" "percent 101"
  assert_equals 1 "$(row_count "$home")" "percent 101 wrote a sample"
  assert_contains "$out" "0 to 100" "percent 101 did not name the bound"

  out=$(record_at "$home" 1007 review s1 50 2>&1)
  status=$?
  expect_code 2 "$status" "unclassified turn type"
  assert_equals 1 "$(row_count "$home")" "unclassified turn type wrote a sample"
  assert_contains "$out" "auto, startup, heartbeat, wake, captain, or turn" "turn type error did not name the types"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONTEXT_BURN_NOW=1008 \
    "$BURN" record --turn-type captain --session s1 --footer-file "$home/x.txt" 2>&1)
  status=$?
  expect_code 2 "$status" "footer file option"
  assert_equals 1 "$(row_count "$home")" "footer file option wrote a sample"
  pass "percent bounds and the closed turn-type set"
}

usage_line() { # <tokens>
  printf '{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":0,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0},"content":"ok"}}\n' "$1"
}

record_from_transcript() { # <home> <now> <payload-file>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" \
    FM_CONFIG_OVERRIDE="$1/config" CLAUDE_PROJECT_DIR="$1" CLAUDE_CONFIG_DIR="$1/claude" \
    CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 FM_CONTEXT_BURN_NOW="$2" \
    "$BURN" record --turn-type auto --payload-file "$3"
}

test_transcript_percent_when_footer_hidden() {
  local home=$TMP_ROOT/transcript out
  prepare "$home"
  printf '%s\n' "{\"session_id\":\"fresh1\",\"transcript_path\":\"$home/t.jsonl\"}" > "$home/p.json"
  {
    printf '%s\n' '{"type":"user","message":{"content":"captain asks a question"}}'
    usage_line 16700
  } > "$home/t.jsonl"
  out=$(record_from_transcript "$home" 20000 "$home/p.json")
  assert_equals $'20000\tfresh1\tcaptain\t90' "$(last_row "$home")" "transcript percent at 90"
  assert_not_contains "$out" "alert:" "first transcript sample alerted"

  {
    printf '%s\n' '{"type":"user","message":{"content":"check: fleet"}}'
    usage_line 66800
  } > "$home/t.jsonl"
  out=$(record_from_transcript "$home" 20600 "$home/p.json")
  assert_equals $'20600\tfresh1\twake\t60' "$(last_row "$home")" "transcript percent at 60"
  assert_contains "$out" "alert: fresh1 dropped from 90 to 60 in 600s turn wake" "transcript drop did not alert"

  mkdir -p "$home/config"
  printf 'compact-at-tokens=100000\n' > "$home/config/handoff-trigger"
  out=$(record_from_transcript "$home" 20700 "$home/p.json")
  assert_equals $'20700\tfresh1\twake\t33' "$(last_row "$home")" "pinned compact point"

  {
    printf '%s\n' '{"type":"user","message":{"content":"captain asks"}}'
    printf '%s\n' '{"type":"system","subtype":"compact_boundary"}'
  } > "$home/t.jsonl"
  record_from_transcript "$home" 20800 "$home/p.json" >/dev/null
  assert_equals 3 "$(row_count "$home")" "no usage after compaction wrote a sample"

  usage_line 16700 > "$home/t.jsonl"
  printf '%s\n' "{\"session_id\":\"cur1\",\"cursor_version\":\"1\",\"transcript_path\":\"$home/t.jsonl\"}" > "$home/cursor.json"
  record_from_transcript "$home" 20900 "$home/cursor.json" >/dev/null
  assert_equals 3 "$(row_count "$home")" "a Cursor payload used the Claude formula"
  pass "transcript percent fills in when the pane footer is hidden"
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

  {
    printf '%s\n' '{"type":"user","message":{"content":"captain asks a question"}}'
    printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"check: fleet"}]}}'
    for _ in $(seq 1 60); do
      printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Bash","input":{}}]}}'
      printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"pane table"}]}}'
    done
  } > "$home/t.jsonl"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONTEXT_BURN_NOW=6030 \
    "$BURN" record --turn-type auto --percent 67 --payload-file "$home/p.json" >/dev/null
  assert_equals $'6030\tsess1\twake\t67' "$(last_row "$home")" "wake behind 120 tool lines"

  printf '%s\n' '{"type":"user","message":{"content":"Stop hook feedback:\nworkers still open\n●━━━━━━━━"}}' > "$home/t.jsonl"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONTEXT_BURN_NOW=6040 \
    "$BURN" record --turn-type auto --percent 66 --payload-file "$home/p.json" >/dev/null
  assert_equals $'6040\tsess1\twake\t66' "$(last_row "$home")" "multi-line stop hook feedback"

  printf '%s\n' '{"type":"user","message":{"content":"<task-notification>\nStop hook feedback:\nworkers still open"}}' > "$home/t.jsonl"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONTEXT_BURN_NOW=6050 \
    "$BURN" record --turn-type auto --percent 65 --payload-file "$home/p.json" >/dev/null
  assert_equals $'6050\tsess1\twake\t65' "$(last_row "$home")" "stop hook feedback after a notification line"

  local pad
  pad=$(awk 'BEGIN { s = ""; while (length(s) < 2100) s = s "x"; printf "%s", s }')
  printf '%s\n' \
    "{\"type\":\"attachment\",\"attachment\":{\"type\":\"hook_success\",\"hookName\":\"SessionStart:startup\",\"hookEvent\":\"SessionStart\",\"content\":\"${pad} SUPERVISION OPERATING INSTRUCTIONS\"}}" \
    '{"type":"user","message":{"content":"status please"}}' \
    '{"type":"assistant","message":{"content":"noted"}}' \
    > "$home/t.jsonl"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONTEXT_BURN_NOW=6060 \
    "$BURN" record --turn-type auto --percent 64 --payload-file "$home/p.json" >/dev/null
  assert_equals $'6060\tsess1\tstartup\t64' "$(last_row "$home")" "SessionStart attachment classifies the opening turn"

  printf '%s\n' "{\"type\":\"user\",\"message\":{\"content\":\"${pad} SUPERVISION OPERATING INSTRUCTIONS\"}}" > "$home/t.jsonl"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONTEXT_BURN_NOW=6070 \
    "$BURN" record --turn-type auto --percent 63 --payload-file "$home/p.json" >/dev/null
  assert_equals $'6070\tsess1\tstartup\t63' "$(last_row "$home")" "supervision title past 2000 characters still starts up"

  printf '%s\n' '{"type":"user","message":{"content":"ready signal: the branch is published"}}' > "$home/t.jsonl"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONTEXT_BURN_NOW=6080 \
    "$BURN" record --turn-type auto --percent 62 --payload-file "$home/p.json" >/dev/null
  assert_equals $'6080\tsess1\tcaptain\t62' "$(last_row "$home")" "ready signal prose is not a wake"

  printf '%s\n' \
    '{"type":"assistant","message":{"content":"ok"}}' \
    '{"type":"user","message":{"content":"ready signal: the branch is published"}}' \
    > "$home/t.jsonl"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONTEXT_BURN_NOW=6090 \
    "$BURN" record --turn-type auto --percent 61 --payload-file "$home/p.json" >/dev/null
  assert_equals $'6090\tsess1\tcaptain\t61' "$(last_row "$home")" "later ready signal prose stays an ordinary turn"

  printf '%s\n' \
    '{"type":"attachment","attachment":{"type":"hook_success","hookName":"SessionStart:startup","hookEvent":"SessionStart","content":"SUPERVISION OPERATING INSTRUCTIONS"}}' \
    '{"type":"user","message":{"content":"status please"}}' \
    '{"type":"assistant","message":{"content":"noted"}}' \
    '{"type":"user","message":{"content":"ready signal: the branch is published"}}' \
    > "$home/t.jsonl"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONTEXT_BURN_NOW=6100 \
    "$BURN" record --turn-type auto --percent 60 --payload-file "$home/p.json" >/dev/null
  assert_equals $'6100\tsess1\tcaptain\t60' "$(last_row "$home")" "a later turn is not startup because the attachment remains in the tail"

  printf '%s\n' \
    '{"type":"attachment","attachment":{"type":"hook_success","hookName":"SessionStart:startup","hookEvent":"SessionStart","content":"hook stdout"}}' \
    '{"type":"user","message":{"content":"status please"}}' \
    '{"type":"attachment","attachment":{"type":"hook_success","hookName":"SessionStart:startup","hookEvent":"SessionStart","content":"hook stdout again"}}' \
    '{"type":"assistant","message":{"content":"noted"}}' \
    > "$home/t.jsonl"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONTEXT_BURN_NOW=6110 \
    "$BURN" record --turn-type auto --percent 59 --payload-file "$home/p.json" >/dev/null
  assert_equals $'6110\tsess1\tstartup\t59' "$(last_row "$home")" "a SessionStart after the opening user text stays startup"

  printf '%s\n' \
    '{"type":"attachment","attachment":{"type":"hook_success","hookName":"SessionStart:startup","hookEvent":"SessionStart","content":"hook stdout"}}' \
    '{"type":"user","message":{"content":"status please"}}' \
    '{"type":"assistant","message":{"content":"noted"}}' \
    '{"type":"user","message":{"content":"ready signal: the branch is published"}}' \
    '{"type":"attachment","attachment":{"type":"hook_success","hookName":"SessionStart:startup","hookEvent":"SessionStart","content":"hook stdout again"}}' \
    > "$home/t.jsonl"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONTEXT_BURN_NOW=6120 \
    "$BURN" record --turn-type auto --percent 58 --payload-file "$home/p.json" >/dev/null
  assert_equals $'6120\tsess1\tcaptain\t58' "$(last_row "$home")" "a SessionStart after a later user stays an ordinary turn"

  printf '%s\n' '{"type":"user","message":{"content":"heartbeat: fleet"}}' > "$home/t.jsonl"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONTEXT_BURN_NOW=6130 \
    "$BURN" record --turn-type auto --percent 57 --payload-file "$home/p.json" >/dev/null
  assert_equals $'6130\tsess1\theartbeat\t57' "$(last_row "$home")" "heartbeat at line start"

  printf '%s\n' '{"type":"user","message":{"content":"please note heartbeat: soon"}}' > "$home/t.jsonl"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONTEXT_BURN_NOW=6140 \
    "$BURN" record --turn-type auto --percent 56 --payload-file "$home/p.json" >/dev/null
  assert_equals $'6140\tsess1\tcaptain\t56' "$(last_row "$home")" "heartbeat mid-line is an ordinary turn"

  printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"note"},{"type":"text","text":"check: fleet"}]}}' > "$home/t.jsonl"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONTEXT_BURN_NOW=6150 \
    "$BURN" record --turn-type auto --percent 55 --payload-file "$home/p.json" >/dev/null
  assert_equals $'6150\tsess1\twake\t55' "$(last_row "$home")" "a wake token in a later text block stays at line start"
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
  test_percent_bounds_and_turn_types \
  test_transcript_percent_when_footer_hidden \
  test_drop_window_and_freshness \
  test_alert_once_then_again_after_recovery \
  test_unknown_session_and_dedupe \
  test_auto_turn_type_from_tailed_transcript \
  test_report_line \
  test_unmeasured_non_primary_writes_nothing
