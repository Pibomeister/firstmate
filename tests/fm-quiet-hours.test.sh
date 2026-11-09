#!/usr/bin/env bash
# tests/fm-quiet-hours.test.sh - the quiet-hours clock reports whether a moment
# is inside quiet hours and when its window ends, in the zone named by the
# quiet-hours-zone key of config/escalation (default America/Costa_Rica) and
# never in the host's zone. Nightly is 22:00 to 08:00; the weekend is Friday
# 17:00 to Monday 08:00 and replaces the nightly windows inside it. The whole
# test runs with the host zone set to Asia/Tokyo, and a call with no epoch reads
# the shared fixed-clock seam.
#
# Every expected epoch is a literal worked out from UTC, independently of the
# clock: America/Costa_Rica is UTC-6 with no daylight saving time, so a Costa
# Rica wall time is its UTC wall time plus 21600 seconds.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export TZ=Asia/Tokyo

LIB="$ROOT/bin/fm-quiet-hours-lib.sh"
CLI="$ROOT/bin/fm-quiet-hours.sh"
TMP_ROOT=$(fm_test_tmproot fm-quiet-hours-tests)
NO_CONFIG="$TMP_ROOT/no-config"
mkdir -p "$NO_CONFIG"

# Costa Rica wall times, week of Monday 2026-11-02.
TUE_215959=1793764799
TUE_2200=1793764800
TUE_2300=1793768400
WED_075959=1793800799
WED_0800=1793800800
WED_2200=1793851200
THU_2300=1793941200
FRI_075959=1793973599
FRI_0800=1793973600
FRI_165959=1794005999
FRI_1700=1794006000
FRI_2300=1794027600
SAT_0300=1794042000
MON_075959=1794232799
MON_0800=1794232800
MON_2200=1794283200

# at <config-dir> <epoch>: one clock reading under that config directory.
at() {
  (unset FM_HOME; FM_CONFIG_OVERRIDE="$1" bash -c '. "$0"; "$@"' "$LIB" fm_quiet_hours_at "$2")
}

# cli <config-dir> args...: the command under that config directory.
cli() {
  local conf=$1
  shift
  env -u FM_HOME FM_CONFIG_OVERRIDE="$conf" bash "$CLI" "$@"
}

wall_hour() {  # <epoch>: the hour of that moment in the current TZ (BSD or GNU date)
  date -d "@$1" +%H 2> /dev/null || date -r "$1" +%H
}

new_config() {  # <name> <file content>: a config directory holding config/escalation
  mkdir -p "$TMP_ROOT/$1"
  printf '%s\n' "$2" > "$TMP_ROOT/$1/escalation"
  printf '%s\n' "$TMP_ROOT/$1"
}

test_host_zone_differs_from_the_clock_zone() {
  # The boundaries below prove zone independence only if the host zone is not
  # the clock's zone, so assert the divergence itself.
  local host_hour cr_hour
  host_hour=$(wall_hour "$TUE_2200")
  cr_hour=$(TZ=America/Costa_Rica wall_hour "$TUE_2200")
  assert_equals 22 "$cr_hour" "the boundary moment is 22:00 in America/Costa_Rica"
  [ "$host_hour" != "$cr_hour" ] || fail "the host zone reads the same hour as America/Costa_Rica"
  pass "the host zone (Asia/Tokyo) reads a different wall time from America/Costa_Rica"
}

test_happy_path_tuesday_night() {
  assert_equals "quiet=1 ends=$WED_0800 window=nightly" "$(at "$NO_CONFIG" "$TUE_2300")" \
    "Tuesday 23:00 is nightly and ends Wednesday 08:00"
  pass "Tuesday 23:00 reports the nightly window ending Wednesday 08:00"
}

test_nightly_boundaries() {
  assert_equals "quiet=0 next=$TUE_2200" "$(at "$NO_CONFIG" "$TUE_215959")" "21:59:59 is outside"
  assert_equals "quiet=1 ends=$WED_0800 window=nightly" "$(at "$NO_CONFIG" "$TUE_2200")" "22:00 is inside"
  assert_equals "quiet=1 ends=$WED_0800 window=nightly" "$(at "$NO_CONFIG" "$WED_075959")" "07:59:59 is inside"
  assert_equals "quiet=0 next=$WED_2200" "$(at "$NO_CONFIG" "$WED_0800")" "08:00 is outside"
  assert_equals "quiet=1 ends=$FRI_0800 window=nightly" "$(at "$NO_CONFIG" "$THU_2300")" \
    "Thursday night ends Friday 08:00"
  assert_equals "quiet=1 ends=$FRI_0800 window=nightly" "$(at "$NO_CONFIG" "$FRI_075959")" \
    "Friday 07:59:59 is still the Thursday nightly window"
  assert_equals "quiet=0 next=$FRI_1700" "$(at "$NO_CONFIG" "$FRI_0800")" \
    "Friday 08:00 is outside, and the next window is the weekend at 17:00"
  pass "the nightly boundaries at 21:59:59, 22:00, 07:59:59 and 08:00 under a foreign host zone"
}

test_weekend_boundaries() {
  assert_equals "quiet=0 next=$FRI_1700" "$(at "$NO_CONFIG" "$FRI_165959")" "Friday 16:59:59 is outside"
  assert_equals "quiet=1 ends=$MON_0800 window=weekend" "$(at "$NO_CONFIG" "$FRI_1700")" "Friday 17:00 is the weekend"
  assert_equals "quiet=1 ends=$MON_0800 window=weekend" "$(at "$NO_CONFIG" "$FRI_2300")" \
    "Friday 23:00 is the weekend, not a nightly window"
  assert_equals "quiet=1 ends=$MON_0800 window=weekend" "$(at "$NO_CONFIG" "$SAT_0300")" \
    "Saturday 03:00 is the weekend and ends Monday 08:00"
  assert_equals "quiet=1 ends=$MON_0800 window=weekend" "$(at "$NO_CONFIG" "$MON_075959")" \
    "Monday 07:59:59 is still the weekend"
  assert_equals "quiet=0 next=$MON_2200" "$(at "$NO_CONFIG" "$MON_0800")" "Monday 08:00 is outside"
  pass "the weekend boundaries at Friday 16:59:59 and 17:00 and Monday 08:00, replacing the nightly windows"
}

test_longest_hold_is_the_weekend_span() {
  local e out ends longest=0
  for e in "$TUE_2200" "$TUE_2300" "$WED_075959" "$THU_2300" "$FRI_075959" "$FRI_1700" "$FRI_2300" "$SAT_0300" "$MON_075959"; do
    out=$(at "$NO_CONFIG" "$e")
    ends=${out#*ends=}
    ends=${ends%% *}
    [ $((ends - e)) -le "$longest" ] || longest=$((ends - e))
  done
  assert_equals 226800 "$longest" "the longest hold is Friday 17:00 to Monday 08:00 (63 hours)"
  pass "the longest hold is the weekend span"
}

test_zone_comes_from_config_escalation() {
  local conf out rc
  # 2026-11-03 21:59:59 in Asia/Tokyo is 06:59:59 the same day in Costa Rica.
  out=$(at "$NO_CONFIG" 1793710799)
  assert_equals "quiet=1 ends=1793714400 window=nightly" "$out" "an absent config/escalation uses America/Costa_Rica"
  conf=$(new_config tokyo "# quiet hours follow the captain
quiet-hours-zone = Asia/Tokyo")
  assert_equals "quiet=0 next=1793710800" "$(at "$conf" 1793710799)" "quiet-hours-zone selects Asia/Tokyo"
  conf=$(new_config other-keys "send-retry-count=3")
  assert_equals "quiet=1 ends=1793714400 window=nightly" "$(at "$conf" 1793710799)" \
    "a config/escalation without the key uses America/Costa_Rica"
  conf=$(new_config bogus "quiet-hours-zone=Mars/Olympus_Mons")
  out=$(at "$conf" "$TUE_2300" 2> /dev/null); rc=$?
  assert_equals "3:" "$rc:$out" "an unknown zone is refused and prints no reading"
  conf=$(new_config not-tzif "quiet-hours-zone=zone.tab")
  out=$(at "$conf" "$TUE_2300" 2> /dev/null); rc=$?
  assert_equals "3:" "$rc:$out" "a zoneinfo file that is not zone data is refused"
  conf=$(new_config absolute "quiet-hours-zone=/usr/share/zoneinfo/UTC")
  out=$(at "$conf" "$TUE_2300" 2> /dev/null); rc=$?
  assert_equals "3:" "$rc:$out" "an absolute zone path is refused"
  pass "the zone is the quiet-hours-zone key of config/escalation, default America/Costa_Rica"
}

test_no_epoch_reads_the_fixed_clock_seam() {
  local out rc
  out=$(unset FM_HOME; FM_CONFIG_OVERRIDE="$NO_CONFIG" FM_TEST_SEAM=1 FM_NOW="$SAT_0300" \
    bash -c '. "$0"; "$@"' "$LIB" fm_quiet_hours_at)
  assert_equals "quiet=1 ends=$MON_0800 window=weekend" "$out" "no epoch reads fm_now"
  out=$(at "$NO_CONFIG" soon 2> /dev/null); rc=$?
  assert_equals "2:" "$rc:$out" "a non-numeric epoch is refused"
  pass "a call with no epoch reads the shared fixed-clock seam"
}

test_command_contract() {
  local out rc conf
  assert_equals "quiet=1 ends=$WED_0800 window=nightly" "$(cli "$NO_CONFIG" at "$TUE_2300")" "at <epoch>"
  out=$(env -u FM_HOME FM_CONFIG_OVERRIDE="$NO_CONFIG" FM_TEST_SEAM=1 FM_NOW="$FRI_165959" bash "$CLI" at)
  assert_equals "quiet=0 next=$FRI_1700" "$out" "at with no epoch reads fm_now"
  out=$(cli "$NO_CONFIG" at soon 2> /dev/null); rc=$?
  assert_equals "1:" "$rc:$out" "a non-numeric epoch is refused"
  out=$(cli "$NO_CONFIG" at 1 2 2> /dev/null); rc=$?
  assert_equals "1:" "$rc:$out" "an extra argument is refused"
  conf=$(new_config cli-bogus "quiet-hours-zone=Mars/Olympus_Mons")
  out=$(cli "$conf" at "$TUE_2300" 2> /dev/null); rc=$?
  assert_equals "3:" "$rc:$out" "an unknown configured zone exits 3"
  cli "$NO_CONFIG" when > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "an unknown subcommand exits 2"
  cli "$NO_CONFIG" --help > /dev/null 2>&1; rc=$?
  assert_equals 0 "$rc" "--help exits 0"
  pass "the at verb and its refusals"
}

fm_test_run \
  test_host_zone_differs_from_the_clock_zone \
  test_happy_path_tuesday_night \
  test_nightly_boundaries \
  test_weekend_boundaries \
  test_longest_hold_is_the_weekend_span \
  test_zone_comes_from_config_escalation \
  test_no_epoch_reads_the_fixed_clock_seam \
  test_command_contract
