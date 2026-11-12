#!/usr/bin/env bash
# tests/fm-stall-ledger.test.sh - the stall ledger records heartbeat samples,
# stalls, verified handoffs, and human interventions, and scores a proof window.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLI="$ROOT/bin/fm-stall-ledger.sh"
TMP_ROOT=$(fm_test_tmproot fm-stall-ledger-tests)
T0=1800000000

new_home() { # <name>
  mkdir -p "$TMP_ROOT/$1/state" "$TMP_ROOT/$1/data"
  printf '%s\n' "$TMP_ROOT/$1"
}

cli() { # <home> <now> args...
  local home=$1 now=$2
  shift 2
  env -u FM_ROOT_OVERRIDE \
    FM_TEST_SEAM=1 FM_NOW="$now" \
    FM_STALL_LEDGER_MIN_SECS="${FM_STALL_LEDGER_MIN_SECS:-0}" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    /bin/bash "$CLI" "$@"
}

ledger_of() { printf '%s/state/stall-ledger.tsv\n' "$1"; }

write_hb() { # <file> <published-epoch>
  printf '{"schema":"fm-heartbeat.v1","published_epoch":%s,"generated_epoch":%s}\n' "$2" "$2" > "$1"
}

one_hb() { # <ledger> <epoch> <published>
  printf '%s\thb\tprimary\t-\t%s\t-\t-\t-\t-\t-\n' "$2" "$3" >> "$1"
}

primary_cover() { # <ledger> <since> <until>
  local ledger=$1 since=$2 until=$3 t
  t=$since
  while [ "$t" -lt "$until" ]; do
    one_hb "$ledger" "$t" "$((t - 10))"
    t=$((t + 600))
  done
}

count_rows() { # <file> <event> [subject]
  local file=$1 event=$2 subject=${3:-}
  [ -f "$file" ] || { printf '0\n'; return 0; }
  awk -F '\t' -v e="$event" -v s="$subject" '
    $2 == e && (s == "" || $4 == s) { n++ }
    END { print n + 0 }
  ' "$file"
}

run_score() { # <home> <since> <until>
  OUT=$(cli "$1" "$T0" score --since "$2" --until "$3") && RC=0 || RC=$?
}

chi_epoch() { # <YYYY-MM-DD HH:MM:SS>
  if date -j -f '%Y-%m-%d %H:%M:%S' '2020-01-01 00:00:00' +%s >/dev/null 2>&1; then
    TZ=America/Chicago date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s
  else
    TZ=America/Chicago date -d "$1" +%s
  fi
}

observe_ok() { # <home> <now>
  local err rc=0
  err=$(cli "$1" "$2" observe 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "observe at $2 failed ($rc): $err"
}

test_score_passes_on_the_locking_boundaries() {
  local home ledger rows
  home=$(new_home pass)
  ledger=$(ledger_of "$home")
  one_hb "$ledger" 1000 400
  primary_cover "$ledger" 1600 4000
  one_hb "$ledger" 999 989
  one_hb "$ledger" 4000 3990
  {
    printf '1300\tstall-open\tprimary\t-\t700\t1300\t-\t-\t-\tprimary:-:700\n'
    printf '2500\tstall-close\tprimary\t-\t700\t1300\tfirstmate\t2500\t1800\tprimary:-:700\n'
    printf '1000\tstall-open\tprimary\t-\t1000\t1000\t-\t-\t-\tprimary:-:1000\n'
    printf '1600\tstall-close\tprimary\t-\t1000\t1000\tfirstmate\t1600\t600\tprimary:-:1000\n'
    printf '3400\tstall-open\tprimary\t-\t3400\t3400\t-\t-\t-\tprimary:-:3400\n'
  } >> "$ledger"
  run_score "$home" 1000 4000
  assert_equals 0 "$RC" "a locking-boundary window passes"
  assert_equals PASS "$OUT" "the pass line is the whole score"
  rows=$(cli "$home" "$T0" rows --since 1000 --until 4000) || fail "rows failed"
  assert_contains "$rows" $'1000\thb\t' "the sample at since is inside the window"
  printf '%s\n' "$rows" | awk -F '\t' '$1 == 999 || $1 == 4000 { found = 1 } END { exit (found ? 1 : 0) }' \
    || fail "rows included an epoch outside [since, until)"
  pass "a window on the 600, 1200, and 1800 boundaries scores PASS"
}

test_score_fails_a_human_intervention() {
  local home ledger
  home=$(new_home intervention)
  ledger=$(ledger_of "$home")
  primary_cover "$ledger" 1000 4000
  printf '2000\tintervention\tprimary\t-\t2000\t2000\thuman\t-\t-\torder:cap\n' >> "$ledger"
  run_score "$home" 1000 4000
  assert_equals 1 "$RC" "an intervention fails the window"
  assert_equals FAIL "${OUT%%$'\n'*}" "the score leads with FAIL"
  assert_contains "$OUT" $'intervention\t' "the intervention row is cited"
  assert_contains "$OUT" "order:cap" "the citation names the order"
  assert_not_contains "$OUT" "stall-duration" "duration stays inside the bar"
  assert_not_contains "$OUT" "heartbeat-missing" "primary samples cover the window"
  pass "a human intervention inside the window fails and is cited"
}

test_score_fails_stall_duration_over_30_minutes() {
  local home ledger
  home=$(new_home duration)
  ledger=$(ledger_of "$home")
  primary_cover "$ledger" 1000 4000
  printf '1500\tstall-open\tprimary\t-\t700\t1500\t-\t-\t-\tprimary:-:700\n' >> "$ledger"
  printf '2700\tstall-close\tprimary\t-\t700\t1500\tfirstmate\t2700\t2000\tprimary:-:700\n' >> "$ledger"
  run_score "$home" 1000 4000
  assert_equals 1 "$RC" "a stall over 30 minutes fails"
  assert_contains "$OUT" $'stall-duration\t' "duration is cited from the open row"
  assert_not_contains "$OUT" "stall-recovery" "recovery latency of 1200 seconds passes"
  printf '%s\n' "$OUT" | awk -F '\t' '$1 == "stall-open" { found = 1 } END { exit (found ? 1 : 0) }' \
    || fail "the stall recovered inside the window"
  assert_not_contains "$OUT" "heartbeat-missing" "primary samples cover the window"
  pass "a stall longer than 1800 seconds fails stall-duration only"
}

test_score_fails_recovery_over_20_minutes() {
  local home ledger
  home=$(new_home recovery)
  ledger=$(ledger_of "$home")
  primary_cover "$ledger" 1000 4000
  printf '1100\tstall-open\tprimary\t-\t1000\t1100\t-\t-\t-\tprimary:-:1000\n' >> "$ledger"
  printf '2400\tstall-close\tprimary\t-\t1000\t1100\tfirstmate\t2400\t1400\tprimary:-:1000\n' >> "$ledger"
  run_score "$home" 1000 4000
  assert_equals 1 "$RC" "a slow recovery fails"
  assert_contains "$OUT" $'stall-recovery\t' "recovery is cited"
  assert_not_contains "$OUT" "stall-duration" "duration of 1400 seconds passes"
  printf '%s\n' "$OUT" | awk -F '\t' '$1 == "stall-open" { found = 1 } END { exit (found ? 1 : 0) }' \
    || fail "the stall recovered inside the window"
  pass "recovery latency over 1200 seconds fails stall-recovery only"
}

test_score_fails_an_open_stall() {
  local home ledger
  home=$(new_home open)
  ledger=$(ledger_of "$home")
  primary_cover "$ledger" 1000 4000
  printf '3000\tstall-open\tprimary\t-\t3000\t3900\t-\t-\t-\tprimary:-:3000\n' >> "$ledger"
  run_score "$home" 1000 4000
  assert_equals 1 "$RC" "an open stall fails"
  assert_contains "$OUT" $'stall-open\t' "the open row is cited"
  assert_not_contains "$OUT" "stall-duration" "duration to the window end is 1000 seconds"
  assert_not_contains "$OUT" "stall-recovery" "detect is 100 seconds before the window end"
  pass "an open stall whose detect is 100 seconds before until fails stall-open only"
}

test_score_heartbeat_age_bounds() {
  local home ledger
  home=$(new_home age-fail)
  ledger=$(ledger_of "$home")
  one_hb "$ledger" 2000 1399
  run_score "$home" 2000 2600
  assert_equals 1 "$RC" "age 601 fails"
  assert_contains "$OUT" $'heartbeat-age\t' "the old sample is cited"
  assert_not_contains "$OUT" "heartbeat-gap" "the single sample leaves a 600 second gap"
  home=$(new_home age-pass)
  ledger=$(ledger_of "$home")
  one_hb "$ledger" 2000 1400
  run_score "$home" 2000 2600
  assert_equals 0 "$RC" "age 600 passes"
  assert_equals PASS "$OUT" "age 600 is a pass"
  pass "heartbeat age 601 fails and age 600 passes"
}

test_score_exempts_age_during_a_short_handoff() {
  local home ledger t
  home=$(new_home handoff-ok)
  ledger=$(ledger_of "$home")
  t=10000
  while [ "$t" -lt 13000 ]; do
    if [ "$t" -eq 11000 ]; then
      one_hb "$ledger" "$t" 10300
    else
      one_hb "$ledger" "$t" "$((t - 10))"
    fi
    t=$((t + 500))
  done
  printf '11200\thandoff\tprimary\t-\t10800\t11200\t-\t-\t400\tabc123\n' >> "$ledger"
  run_score "$home" 10000 13000
  assert_equals 0 "$RC" "a short handoff exempts the covered sample"
  assert_equals PASS "$OUT" "the exempted age is a pass"
  pass "heartbeat age 700 during a 400 second verified handoff passes"
}

test_score_does_not_exempt_a_long_handoff() {
  local home ledger t
  home=$(new_home handoff-long)
  ledger=$(ledger_of "$home")
  t=10000
  while [ "$t" -lt 13000 ]; do
    if [ "$t" -eq 11000 ]; then
      one_hb "$ledger" "$t" 10300
    else
      one_hb "$ledger" "$t" "$((t - 10))"
    fi
    t=$((t + 500))
  done
  printf '11200\thandoff\tprimary\t-\t10500\t11200\t-\t-\t700\tabc123\n' >> "$ledger"
  run_score "$home" 10000 13000
  assert_equals 1 "$RC" "a 700 second handoff does not exempt"
  assert_contains "$OUT" $'heartbeat-age\t' "the age-700 sample is cited"
  assert_not_contains "$OUT" "heartbeat-gap" "samples every 500 seconds cover the window"
  pass "a verified handoff longer than 600 seconds does not exempt heartbeat age"
}

test_score_fails_a_gap_and_a_missing_heartbeat() {
  local home ledger out rc=0
  home=$(new_home gap)
  ledger=$(ledger_of "$home")
  one_hb "$ledger" 1000 990
  one_hb "$ledger" 1700 1690
  run_score "$home" 1000 2200
  assert_equals 1 "$RC" "a gap over 600 seconds fails"
  assert_contains "$OUT" $'heartbeat-gap\tprimary\t1000\t1700' "the gap cites both sample epochs"
  home=$(new_home missing)
  out=$(cli "$home" "$T0" score --since 1000 --until 4000) && rc=0 || rc=$?
  assert_equals 1 "$rc" "an absent ledger fails"
  assert_equals "$(printf 'FAIL\nheartbeat-missing\tprimary')" "$out" "an absent ledger cites heartbeat-missing"
  out=$(cli "$home" "$T0" rows --since 0 --until 10) && rc=0 || rc=$?
  assert_equals 0 "$rc" "rows on an absent ledger succeeds"
  assert_equals "" "$out" "rows on an absent ledger prints nothing"
  home=$(new_home secondmate-only)
  ledger=$(ledger_of "$home")
  printf '1500\thb\tsecondmate\tmate1\t1490\t-\t-\t-\t-\t-\n' >> "$ledger"
  run_score "$home" 1000 4000
  assert_equals 1 "$RC" "secondmate samples do not cover the primary bar"
  assert_equals "$(printf 'FAIL\nheartbeat-missing\tprimary')" "$OUT" "a secondmate-only ledger is heartbeat-missing"
  pass "a sample gap fails, and a missing primary heartbeat fails closed"
}

test_rows_ignore_malformed_lines() {
  local home ledger rows
  home=$(new_home malformed)
  ledger=$(ledger_of "$home")
  {
    printf 'not a row\n'
    printf '1\t2\t3\n'
    printf '1000\thb\tprimary\t-\tnope\t-\t-\t-\t-\t-\n'
    printf '1000\tweird\tprimary\t-\t1000\t1000\t-\t-\t-\tx\n'
    printf '1000\thb\tbogon\t-\t1000\t-\t-\t-\t-\t-\n'
  } >> "$ledger"
  rows=$(cli "$home" "$T0" rows --since 0 --until 5000) || fail "rows failed"
  assert_equals "" "$rows" "malformed rows are skipped"
  run_score "$home" 1000 4000
  assert_equals 1 "$RC" "malformed rows do not cover the heartbeat"
  assert_equals "$(printf 'FAIL\nheartbeat-missing\tprimary')" "$OUT" "the score does not cite a malformed row"
  pass "rows and score ignore malformed ledger lines"
}

test_observe_records_one_fresh_heartbeat() {
  local home ledger rc=0 err
  home=$(new_home fresh)
  ledger=$(ledger_of "$home")
  write_hb "$home/state/heartbeat.json" "$((T0 - 30))"
  observe_ok "$home" "$T0"
  observe_ok "$home" "$T0"
  assert_equals 1 "$(count_rows "$ledger" hb)" "one heartbeat sample at one clock"
  assert_equals 0 "$(count_rows "$ledger" stall-open)" "a 30 second heartbeat is not a stall"
  ln -sfn "$home/not-the-ledger" "$ledger"
  err=$(cli "$home" "$T0" observe 2>&1) && rc=0 || rc=$?
  assert_equals 1 "$rc" "a symlink ledger is refused: $err"
  [ ! -e "$home/not-the-ledger" ] || fail "observe followed the symlink ledger"
  pass "a fresh heartbeat is one sample, and a symlink ledger is refused"
}

test_observe_opens_and_closes_a_stale_heartbeat() {
  local home ledger start detect
  home=$(new_home stale-hb)
  ledger=$(ledger_of "$home")
  start=$((T0 - 700))
  detect=$((start + 601))
  write_hb "$home/state/heartbeat.json" "$start"
  observe_ok "$home" "$T0"
  observe_ok "$home" "$T0"
  assert_equals 1 "$(count_rows "$ledger" hb)" "the same clock does not duplicate the sample"
  assert_equals 1 "$(count_rows "$ledger" stall-open)" "the same clock does not duplicate the stall"
  awk -F '\t' -v start="$start" -v detect="$detect" '
    $2 == "stall-open" && $3 == "primary" && $4 == "-" && $5 == start && $6 == detect { ok = 1 }
    END { exit !ok }
  ' "$ledger" || fail "the stall did not start at published_epoch and detect at published+601"
  write_hb "$home/state/heartbeat.json" "$((T0 + 100))"
  observe_ok "$home" "$((T0 + 100))"
  assert_equals 1 "$(count_rows "$ledger" stall-open)" "a fresh heartbeat does not open a second stall"
  awk -F '\t' -v recover="$((T0 + 100))" '
    $2 == "stall-close" && $7 == "firstmate" && $8 == recover { ok = 1 }
    END { exit !ok }
  ' "$ledger" || fail "the fresh heartbeat did not close the stall as firstmate"
  pass "a stale primary heartbeat opens one stall and a fresh one closes it as firstmate"
}

test_observe_watchdog_closes_only_on_done() {
  local home ledger actions start
  home=$(new_home wd-step)
  ledger=$(ledger_of "$home")
  actions=$home/state/watchdog/actions.tsv
  mkdir -p "$home/state/watchdog"
  start=$((T0 - 600))
  printf '%s\tid1\t\tprimary\tfrozen\trestart\tdry-run\tnope\n' "$T0" > "$actions"
  observe_ok "$home" "$T0"
  assert_equals 0 "$(count_rows "$ledger" stall-open)" "a dry-run at the 600 second line does not open"
  assert_equals 0 "$(count_rows "$ledger" stall-close)" "a dry-run does not close"
  printf '%s\tid2\t\tprimary\tfrozen\trestart\tdone\trestarted\n' "$((T0 + 700))" >> "$actions"
  observe_ok "$home" "$((T0 + 700))"
  awk -F '\t' -v start="$start" -v detect="$T0" -v recover="$((T0 + 700))" '
    $2 == "stall-close" && $3 == "primary" && $4 == "-" && $5 == start && $6 == detect && $7 == "watchdog" && $8 == recover { ok = 1 }
    END { exit !ok }
  ' "$ledger" || fail "the later restart done did not close as watchdog"
  assert_equals 1 "$(count_rows "$ledger" stall-open)" "the completed episode records one open"

  home=$(new_home wd-held)
  ledger=$(ledger_of "$home")
  actions=$home/state/watchdog/actions.tsv
  mkdir -p "$home/state/watchdog"
  printf '%s\n' "$T0" > "$home/state/.stall-ledger-born"
  printf '%s\tid1\t\tprimary\tfrozen\trestart\theld\theld\n' "$T0" > "$actions"
  observe_ok "$home" "$((T0 + 700))"
  assert_equals 1 "$(count_rows "$ledger" stall-open)" "a long held row opens a live stall"
  assert_equals 0 "$(count_rows "$ledger" stall-close)" "held does not close"

  home=$(new_home wd-once)
  ledger=$(ledger_of "$home")
  actions=$home/state/watchdog/actions.tsv
  mkdir -p "$home/state/watchdog"
  printf '%s\n' "$T0" > "$home/state/.stall-ledger-born"
  printf '%s\tid1\t\tprimary\tfrozen\trestart\theld\theld\n' "$T0" > "$actions"
  printf '%s\tid2\t\tprimary\tfrozen\trestart\tdone\trestarted\n' "$((T0 + 700))" >> "$actions"
  observe_ok "$home" "$((T0 + 700))"
  assert_equals 1 "$(count_rows "$ledger" stall-open)" "one observe records the open"
  awk -F '\t' -v start="$start" -v recover="$((T0 + 700))" '
    $2 == "stall-close" && $5 == start && $7 == "watchdog" && $8 == recover { ok = 1 }
    END { exit !ok }
  ' "$ledger" || fail "held and done in one observe did not close as watchdog"
  pass "watchdog dry-run and held stay open until a restart done closes them"
}

test_observe_secondmate_progress_closes_as_agentkit() {
  local home mate other ledger start
  home=$(new_home progress)
  mate=$(new_home progress-mate)
  other=$(new_home progress-other)
  ledger=$(ledger_of "$home")
  start=$((T0 - 700))
  printf 'mate1\n' > "$mate/.fm-secondmate-home"
  write_hb "$mate/state/heartbeat.json" "$((T0 - 30))"
  printf 'kind=secondmate\nhome=%s\n' "$mate" > "$home/state/mate1.meta"
  printf 'someone-else\n' > "$other/.fm-secondmate-home"
  write_hb "$other/state/heartbeat.json" "$((T0 - 30))"
  printf 'kind=secondmate\nhome=%s\n' "$other" > "$home/state/mate2.meta"
  printf '%s\trow\n' "$start" > "$home/state/.secondmate-wake-progress-mate1"
  observe_ok "$home" "$T0"
  awk -F '\t' -v start="$start" -v detect="$((start + 601))" '
    $2 == "stall-open" && $3 == "secondmate" && $4 == "mate1" && $5 == start && $6 == detect { ok = 1 }
    END { exit !ok }
  ' "$ledger" || fail "the idle progress marker did not open a secondmate stall"
  awk -F '\t' '$2 == "hb" && $3 == "secondmate" && $4 == "mate1" { ok = 1 } END { exit !ok }' "$ledger" \
    || fail "the matching secondmate heartbeat was not sampled"
  awk -F '\t' '$4 == "mate2" { n++ } END { exit n+0 }' "$ledger" \
    || fail "a mismatched secondmate identity was recorded"
  [ ! -e "$mate/state/stall-ledger.tsv" ] || fail "observe wrote a ledger into the secondmate home"
  [ ! -e "$other/state/stall-ledger.tsv" ] || fail "observe wrote a ledger into the other secondmate home"
  rm -f "$home/state/.secondmate-wake-progress-mate1"
  observe_ok "$home" "$((T0 + 10))"
  awk -F '\t' -v recover="$((T0 + 10))" '
    $2 == "stall-close" && $3 == "secondmate" && $4 == "mate1" && $7 == "agentkit" && $8 == recover { ok = 1 }
    END { exit !ok }
  ' "$ledger" || fail "removing the progress marker did not close as agentkit"
  pass "a secondmate progress stall closes as agentkit, and mate homes stay read-only"
}

test_observe_stale_wake_closes_as_firstmate() {
  local home ledger start
  home=$(new_home wake-boundary)
  ledger=$(ledger_of "$home")
  printf '%s\t1\tstale\tworker2\tstale: worker2 (idle 600s, quiet)\n' "$T0" > "$home/state/.wake-queue"
  observe_ok "$home" "$T0"
  assert_equals 0 "$(count_rows "$ledger" stall-open)" "idle of exactly 600 seconds is not a stall"

  home=$(new_home wake-worker)
  ledger=$(ledger_of "$home")
  start=$((T0 - 700))
  printf '%s\t1\tstale\tworker1\tstale: worker1 (idle 700s, quiet)\n' "$T0" > "$home/state/.wake-queue"
  observe_ok "$home" "$T0"
  awk -F '\t' -v start="$start" -v detect="$T0" '
    $2 == "stall-open" && $3 == "worker" && $4 == "worker1" && $5 == start && $6 == detect { ok = 1 }
    END { exit !ok }
  ' "$ledger" || fail "the stale wake did not open a worker stall"
  rm -f "$home/state/.wake-queue"
  observe_ok "$home" "$((T0 + 10))"
  awk -F '\t' -v recover="$((T0 + 10))" '
    $2 == "stall-close" && $4 == "worker1" && $7 == "firstmate" && $8 == recover { ok = 1 }
    END { exit !ok }
  ' "$ledger" || fail "clearing the wake did not close as firstmate"

  home=$(new_home wake-once)
  ledger=$(ledger_of "$home")
  start=$((T0 - 800))
  printf 'kind=secondmate\nhome=%s\n' "$TMP_ROOT/no-such-mate-home" > "$home/state/mate1.meta"
  printf '%s\trow\n' "$start" > "$home/state/.secondmate-wake-progress-mate1"
  printf '%s\t1\tstale\tmate1\tstale: mate1 (idle 700s, quiet)\n' "$T0" > "$home/state/.wake-queue"
  observe_ok "$home" "$T0"
  assert_equals 1 "$(count_rows "$ledger" stall-open mate1)" "progress and wake are one stall"
  awk -F '\t' -v start="$start" '
    $2 == "stall-open" && $3 == "secondmate" && $4 == "mate1" && $5 == start { ok = 1 }
    END { exit !ok }
  ' "$ledger" || fail "the progress marker did not win over the wake"
  pass "a stale wake opens a worker stall, and a covered secondmate is not opened twice"
}

test_window_maps_chicago_kickoff() {
  local home kick want got until_epoch a b ra=0 rb=0
  home=$(new_home window)
  kick=$(chi_epoch '2026-11-12 22:00:00')
  want=$(chi_epoch '2026-11-13 08:00:00')
  got=$(cli "$home" "$T0" window --kickoff "$kick") || fail "window --kickoff failed"
  assert_equals "since=$kick until=$want" "$got" "22:00 resolves to the next 08:00"
  kick=$(chi_epoch '2026-11-12 08:00:00')
  want=$(chi_epoch '2026-11-13 08:00:00')
  got=$(cli "$home" "$T0" window --kickoff "$kick") || fail "exact 08:00 window failed"
  assert_equals "since=$kick until=$want" "$got" "exactly 08:00 resolves to the next civil day"
  kick=$(chi_epoch '2026-11-12 07:00:00')
  want=$(chi_epoch '2026-11-12 08:00:00')
  got=$(cli "$home" "$T0" window --kickoff "$kick") || fail "07:00 window failed"
  assert_equals "since=$kick until=$want" "$got" "07:00 resolves to the same civil day's 08:00"
  kick=$(chi_epoch '2026-03-07 22:00:00')
  want=$(chi_epoch '2026-03-08 08:00:00')
  got=$(cli "$home" "$T0" window --kickoff "$kick") || fail "DST window failed"
  assert_equals "since=$kick until=$want" "$got" "a kickoff across the spring change uses the civil 08:00"
  kick=$(chi_epoch '2026-11-12 22:00:00')
  got=$(cli "$home" "$T0" window --kickoff "$kick") || fail "window repeat failed"
  until_epoch=${got##*until=}
  a=$(cli "$home" "$T0" score --kickoff "$kick") && ra=0 || ra=$?
  b=$(cli "$home" "$T0" score --since "$kick" --until "$until_epoch") && rb=0 || rb=$?
  assert_equals "$ra" "$rb" "kickoff and explicit windows exit alike"
  assert_equals "$a" "$b" "kickoff and explicit windows score alike"
  assert_equals 1 "$ra" "an empty home fails the proof window"
  assert_contains "$a" $'heartbeat-missing\tprimary' "the empty window names the missing heartbeat"
  pass "kickoff maps to the next 08:00 America/Chicago, including the spring change"
}

test_observe_records_orders_notes_and_handoffs() {
  local home ledger body
  home=$(new_home human)
  ledger=$(ledger_of "$home")
  mkdir -p "$home/data/orders" "$home/state/inbox"
  {
    printf '2026-11-12T00:00:00Z\t%s\told1\tsent\tabcd1234\tbefore\n' "$((T0 - 10))"
    printf '2026-11-12T00:00:00Z\t%s\tnew1\tsent\tabcd1234\tafter\n' "$T0"
    printf '2026-11-12T00:00:00Z\t%s\trep1\treplay\tabcd1234\treplay\n' "$T0"
  } > "$home/data/orders/log.tsv"
  printf 'fresh\n' > "$home/state/inbox/fresh.note"
  printf 'old\n' > "$home/state/inbox/old.note"
  perl -e 'utime($ARGV[0], $ARGV[0], $ARGV[1]) or exit 1' "$T0" "$home/state/inbox/fresh.note"
  perl -e 'utime($ARGV[0], $ARGV[0], $ARGV[1]) or exit 1' "$((T0 - 50))" "$home/state/inbox/old.note"
  {
    printf 'HANDOFF v1 ts=%s event=handoff_started nonce=abc123 attempt=1 pid=1 handle=h reason=begin\n' "$((T0 - 5))"
    printf 'HANDOFF v1 ts=%s event=handoff_ack nonce=abc123 attempt=1 pid=1 handle=h reason=lock_transferred\n' "$T0"
    printf 'HANDOFF v1 ts=%s event=handoff_started nonce=def456 attempt=1 pid=1 handle=h reason=begin\n' "$((T0 - 5))"
    printf 'HANDOFF v1 ts=%s event=handoff_ack nonce=def456 attempt=1 pid=1 handle=h reason=stale_takeover\n' "$T0"
  } > "$home/state/handoff-events.log"
  observe_ok "$home" "$T0"
  body=$(cat "$ledger")
  assert_contains "$body" "order:new1" "a sent order at birth is recorded"
  assert_contains "$body" "note:fresh" "an inbox note at birth is recorded"
  assert_not_contains "$body" "order:old1" "a sent order before birth is ignored"
  assert_not_contains "$body" "order:rep1" "replay is not a new intervention"
  assert_not_contains "$body" "note:old" "an older inbox note is ignored"
  assert_not_contains "$body" "def456" "stale_takeover is not a verified handoff"
  awk -F '\t' -v start="$((T0 - 5))" -v ack="$T0" '
    $2 == "handoff" && $3 == "primary" && $4 == "-" && $5 == start && $6 == ack && $10 == "abc123" { ok = 1 }
    END { exit !ok }
  ' "$ledger" || fail "the verified handoff row was not recorded"
  assert_equals 1 "$(count_rows "$ledger" handoff)" "one verified handoff is one row"
  pass "orders, inbox notes, and verified handoffs record only the in-birth events"
}

test_score_fails_a_human_recoverer() {
  local home ledger who
  home=$(new_home human-close)
  ledger=$(ledger_of "$home")
  primary_cover "$ledger" 1000 4000
  printf '1600\tstall-open\tprimary\t-\t1000\t1600\t-\t-\t-\tprimary:-:1000\n' >> "$ledger"
  printf '2200\tstall-close\tprimary\t-\t1000\t1600\thuman\t2200\t1200\tprimary:-:1000\n' >> "$ledger"
  run_score "$home" 1000 4000
  assert_equals 1 "$RC" "a human recoverer fails"
  who=$(printf '%s\n' "$OUT" | awk -F '\t' '$1 == "stall-recoverer" { print $3 " " $8; exit }')
  assert_equals "stall-close human" "$who" "stall-recoverer cites the close row"
  assert_contains "$OUT" $'intervention\t' "the human close is also an intervention"
  assert_not_contains "$OUT" "stall-duration" "duration of 1200 seconds passes"
  assert_not_contains "$OUT" "stall-recovery" "recovery latency of 600 seconds passes"
  printf '%s\n' "$OUT" | awk -F '\t' '$1 == "stall-open" { found = 1 } END { exit (found ? 1 : 0) }' \
    || fail "the stall recovered inside the window"
  pass "a human recoverer fails stall-recoverer and cites the close as an intervention"
}

test_score_parent_reads_secondmate_ledger() {
  local home mate ledger
  home=$(new_home parent-gap)
  mate=$(new_home parent-gap-mate)
  printf 'kind=secondmate\nhome=%s\n' "$mate" > "$home/state/mate1.meta"
  printf '1500\thb\tsecondmate\tmate1\t1490\t-\t-\t-\t-\t-\n' > "$(ledger_of "$mate")"
  run_score "$home" 1000 4000
  assert_equals 1 "$RC" "mate samples do not clear the parent bar"
  assert_equals "$(printf 'FAIL\nheartbeat-missing\tprimary')" "$OUT" "the parent still lacks a primary heartbeat"

  home=$(new_home parent-note)
  mate=$(new_home parent-note-mate)
  ledger=$(ledger_of "$home")
  primary_cover "$ledger" 1000 4000
  printf 'kind=secondmate\nhome=%s\n' "$mate" > "$home/state/mate1.meta"
  printf '1500\tintervention\tsecondmate\tmate1\t1500\t1500\thuman\t-\t-\torder:m1\n' > "$(ledger_of "$mate")"
  run_score "$home" 1000 4000
  assert_equals 1 "$RC" "a mate intervention fails the parent score"
  assert_contains "$OUT" "order:m1" "the mate intervention is cited"
  assert_not_contains "$OUT" "heartbeat-missing" "the parent heartbeat still covers the window"
  pass "a parent score reads secondmate ledgers and still requires its own heartbeat"
}

test_observe_throttles_inside_a_minute() {
  local home ledger
  home=$(new_home throttle)
  ledger=$(ledger_of "$home")
  write_hb "$home/state/heartbeat.json" "$T0"
  FM_STALL_LEDGER_MIN_SECS=60 observe_ok "$home" "$T0"
  assert_equals 1 "$(count_rows "$ledger" hb)" "the first observe records the sample"
  FM_STALL_LEDGER_MIN_SECS=60 observe_ok "$home" "$((T0 + 30))"
  assert_equals 1 "$(count_rows "$ledger" hb)" "thirty seconds later adds nothing"
  FM_STALL_LEDGER_MIN_SECS=60 observe_ok "$home" "$((T0 + 60))"
  assert_equals 2 "$(count_rows "$ledger" hb)" "sixty seconds later records the next sample"
  pass "observe skips a second pass inside the minute and records the next one"
}

test_usage_and_unknown_commands() {
  local home out rc=0
  home=$(new_home usage)
  out=$(cli "$home" "$T0" --help) && rc=0 || rc=$?
  assert_equals 0 "$rc" "help exits 0"
  assert_contains "$out" "fm-stall-ledger.sh observe" "help names observe"
  out=$(cli "$home" "$T0" frob 2>&1) && rc=0 || rc=$?
  assert_equals 2 "$rc" "an unknown command exits 2"
  out=$(cli "$home" "$T0" score --since 10 --until 10 2>&1) && rc=0 || rc=$?
  assert_equals 1 "$rc" "since equal to until is a usage error"
  assert_contains "$out" "not before" "the usage error names the window"
  pass "help, an unknown command, and an empty window exit as specified"
}

fm_test_run \
  test_score_passes_on_the_locking_boundaries \
  test_score_fails_a_human_intervention \
  test_score_fails_stall_duration_over_30_minutes \
  test_score_fails_recovery_over_20_minutes \
  test_score_fails_an_open_stall \
  test_score_heartbeat_age_bounds \
  test_score_exempts_age_during_a_short_handoff \
  test_score_does_not_exempt_a_long_handoff \
  test_score_fails_a_gap_and_a_missing_heartbeat \
  test_rows_ignore_malformed_lines \
  test_observe_records_one_fresh_heartbeat \
  test_observe_opens_and_closes_a_stale_heartbeat \
  test_observe_watchdog_closes_only_on_done \
  test_observe_secondmate_progress_closes_as_agentkit \
  test_observe_stale_wake_closes_as_firstmate \
  test_window_maps_chicago_kickoff \
  test_observe_records_orders_notes_and_handoffs \
  test_score_fails_a_human_recoverer \
  test_score_parent_reads_secondmate_ledger \
  test_observe_throttles_inside_a_minute \
  test_usage_and_unknown_commands
