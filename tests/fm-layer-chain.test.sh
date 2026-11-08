#!/usr/bin/env bash
# tests/fm-layer-chain.test.sh - the layer check chain (docs/watchdog.md):
# each watchdog pass reads every watched home's monitor unit and writes
# <home>/state/monitor-status, and a session start with no enabled watchdog
# runs the same read once.
#
# The service manager is a PATH fake for both launchctl and systemctl, so each
# case runs on macOS and Linux alike. HOME and XDG_CONFIG_HOME point into the
# fixture, so unit files exist only where a case puts them. The fake answers by
# unit name: FAKE_MON_STATE for a monitor unit, FAKE_WD_STATE for a watchdog
# unit; `enabled` and `disabled` answer as the manager would, and `vanish` kills
# the calling script before it prints its `manager:` line.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-layer-chain-tests)
WD="$ROOT/bin/fm-watchdog.sh"
MON="$ROOT/bin/fm-monitor-watchdog.sh"
BASE_PATH=$PATH
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
CALLS="$TMP_ROOT/manager-calls.log"
NOW=1700000000

cat > "$FAKEBIN/launchctl" <<'SH'
#!/usr/bin/env bash
set -u
name=${2##*/}
printf 'launchctl %s\n' "$*" >> "$FAKE_CALLS"
case "$name" in
  firstmate-monitor-watchdog-*) state=${FAKE_MON_STATE:-disabled} ;;
  firstmate-watchdog-*) state=${FAKE_WD_STATE:-disabled} ;;
  *) state=disabled ;;
esac
case "$state" in
  enabled) exit 0 ;;
  vanish) kill -TERM "$PPID"; exit 1 ;;
  *) exit 1 ;;
esac
SH
cat > "$FAKEBIN/systemctl" <<'SH'
#!/usr/bin/env bash
set -u
name=''
for a in "$@"; do name=$a; done
name=${name%.service}
printf 'systemctl %s\n' "$*" >> "$FAKE_CALLS"
case "$name" in
  firstmate-monitor-watchdog-*) state=${FAKE_MON_STATE:-disabled} ;;
  firstmate-watchdog-*) state=${FAKE_WD_STATE:-disabled} ;;
  *) state=disabled ;;
esac
case "$state" in
  enabled) exit 0 ;;
  vanish) kill -TERM "$PPID"; exit 1 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/launchctl" "$FAKEBIN/systemctl"

FAKE_HOME="$TMP_ROOT/user-home"
mkdir -p "$FAKE_HOME/Library/LaunchAgents" "$FAKE_HOME/.config/systemd/user"

new_home() {  # <dir>
  mkdir -p "$1/state" "$1/config" "$1/data"
  printf '%s\n' "$1"
}

# install_unit <monitor|watchdog> <home>: the unit file at both platform paths.
install_unit() {
  local kind=$1 home=$2 name
  if [ "$kind" = monitor ]; then
    name=$(FM_HOME="$home" bash "$MON" manager-name)
  else
    name=$(FM_HOME="$home" "$WD" manager-name)
  fi
  : > "$FAKE_HOME/Library/LaunchAgents/$name.plist"
  : > "$FAKE_HOME/.config/systemd/user/$name.service"
}

clear_units() {
  find "$FAKE_HOME/Library/LaunchAgents" "$FAKE_HOME/.config/systemd/user" -type f -exec rm -f {} +
}

# A watchdog pass with the fixed clock and the fake manager.
wd_pass() {  # <owner-home> [env...]
  local owner=$1
  shift
  env HOME="$FAKE_HOME" XDG_CONFIG_HOME="$FAKE_HOME/.config" PATH="$FAKEBIN:$BASE_PATH" \
    FAKE_CALLS="$CALLS" FM_TEST_SEAM=1 FM_WD_NOW="$NOW" FM_HOME="$owner" "$@" \
    "$WD" once --dry-run >/dev/null 2>&1
}

no_temp_left() {  # <home> <msg>
  local left
  left=$(find "$1/state" -maxdepth 1 -name '.monitor-status.*' -print)
  [ -z "$left" ] || fail "$2: $left"
}

test_pass_records_every_watched_home() {
  local base="$TMP_ROOT/pass-every" owner other
  owner=$(new_home "$base/owner")
  other=$(new_home "$base/other")
  printf 'homes=%s,%s\n' "$owner" "$other" > "$owner/config/watchdog"
  clear_units
  install_unit monitor "$owner"
  wd_pass "$owner" FAKE_MON_STATE=enabled || fail "the watchdog pass failed"
  assert_equals "status=enabled at=$NOW" "$(cat "$owner/state/monitor-status" 2>/dev/null)" \
    "a home whose monitor unit runs should read enabled"
  assert_equals "status=uncovered at=$NOW" "$(cat "$other/state/monitor-status" 2>/dev/null)" \
    "a home with no monitor unit should read uncovered"
  no_temp_left "$owner" "the atomic write left a temp file"
  pass "each watchdog pass records every watched home's monitor unit status"
}

test_pass_records_disabled_unit() {
  local base="$TMP_ROOT/pass-disabled" owner
  owner=$(new_home "$base/owner")
  clear_units
  install_unit monitor "$owner"
  wd_pass "$owner" FAKE_MON_STATE=disabled || fail "the watchdog pass failed"
  assert_equals "status=disabled at=$NOW" "$(cat "$owner/state/monitor-status" 2>/dev/null)" \
    "an installed monitor unit that does not run should read disabled"
  pass "an installed monitor unit that does not run reads disabled"
}

test_pass_records_unreadable_without_manager_line() {
  local base="$TMP_ROOT/pass-unreadable" owner out
  owner=$(new_home "$base/owner")
  clear_units
  install_unit monitor "$owner"
  # The divergence this case depends on: the monitor read itself prints no
  # `manager:` line under this fake.
  out=$(env HOME="$FAKE_HOME" XDG_CONFIG_HOME="$FAKE_HOME/.config" PATH="$FAKEBIN:$BASE_PATH" \
    FAKE_CALLS="$CALLS" FAKE_MON_STATE=vanish FM_HOME="$owner" bash "$MON" manager-status 2>&1)
  assert_not_contains "$out" 'manager:' "the vanish fake must stop the read before its manager line"
  printf 'status=enabled at=1\n' > "$owner/state/monitor-status"
  wd_pass "$owner" FAKE_MON_STATE=vanish || fail "the watchdog pass failed"
  assert_equals "status=unreadable at=$NOW" "$(cat "$owner/state/monitor-status" 2>/dev/null)" \
    "a read that prints no manager line should replace the old record with unreadable"
  no_temp_left "$owner" "the atomic write left a temp file"
  pass "a monitor read with no manager line records unreadable over the old record"
}

test_monitor_read_reports_unwritten_record() {
  local base="$TMP_ROOT/read-exit" owner rc
  owner=$(new_home "$base/owner")
  clear_units
  install_unit monitor "$owner"
  run_read() {
    env HOME="$FAKE_HOME" XDG_CONFIG_HOME="$FAKE_HOME/.config" PATH="$FAKEBIN:$BASE_PATH" \
      FAKE_CALLS="$CALLS" FAKE_MON_STATE=enabled FM_TEST_SEAM=1 FM_WD_NOW="$NOW" FM_HOME="$owner" \
      "$WD" monitor-read >/dev/null 2>&1
  }
  run_read || fail "monitor-read should exit 0 when it writes the record"
  assert_equals "status=enabled at=$NOW" "$(cat "$owner/state/monitor-status" 2>/dev/null)" \
    "monitor-read should write the home's record"
  rm -f "$owner/state/monitor-status"
  chmod 555 "$owner/state"
  rc=0
  run_read || rc=$?
  chmod 755 "$owner/state"
  assert_equals 1 "$rc" "monitor-read should exit 1 when the record cannot be written"
  assert_absent "$owner/state/monitor-status" "an unwritable state directory should get no record"
  pass "monitor-read exits 0 on a written record and 1 when it cannot write one"
}

# --- session start -------------------------------------------------------------

SS_ROOT="$TMP_ROOT/ss-root"
SS_FAKEBIN="$TMP_ROOT/ss-fakebin"
mkdir -p "$SS_FAKEBIN"
git init -q -b main "$SS_ROOT"
git -C "$SS_ROOT" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
cp "$FAKEBIN/launchctl" "$FAKEBIN/systemctl" "$SS_FAKEBIN/"
fm_fake_exit0 "$SS_FAKEBIN" tmux node chrome-devtools-axi gh treehouse tasks-axi
fm_fake_version_tool "$SS_FAKEBIN" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.80
fm_fake_version_tool "$SS_FAKEBIN" gh-axi FM_FAKE_GH_AXI_VERSION 0.1.29
fm_fake_version_tool "$SS_FAKEBIN" no-mistakes FM_FAKE_NO_MISTAKES_VERSION \
  'no-mistakes version v1.46.0 (fake) 2026-06-27T00:02:18Z'
# fm-lock.sh finds its holder by walking the process tree through ps; this
# fake reports a live claude harness for a locked start, or plain bash for a
# start whose lock must be refused.
cat > "$SS_FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"comm="*) if [ "${FAKE_NO_HARNESS:-0}" = 1 ]; then echo /bin/bash; else echo /usr/local/bin/claude; fi; exit 0 ;;
  *"args="*) if [ "${FAKE_NO_HARNESS:-0}" = 1 ]; then echo bash; else echo claude; fi; exit 0 ;;
  *"ppid="*) exit 1 ;;
esac
exit 1
SH
chmod +x "$SS_FAKEBIN/ps"

session_start() {  # <home> [env...]
  local home=$1
  shift
  printf '# Backlog\n' > "$home/data/backlog.md"
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT -u FM_STATE_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE \
    HOME="$FAKE_HOME" XDG_CONFIG_HOME="$FAKE_HOME/.config" PATH="$SS_FAKEBIN:$BASE_PATH" \
    FAKE_CALLS="$CALLS" FM_HOME="$home" FM_ROOT_OVERRIDE="$SS_ROOT" "$@" \
    "$ROOT/bin/fm-session-start.sh" > "$home/digest.out" 2>&1 || true
}

monitor_calls() {  # <home>: manager calls naming this home's monitor unit
  local name
  name=$(FM_HOME="$1" bash "$MON" manager-name)
  grep -c -F -- "$name" "$CALLS" 2>/dev/null || true
}

test_session_start_reads_once_without_watchdog() {
  local home
  home=$(new_home "$TMP_ROOT/ss-absent/home")
  clear_units
  install_unit monitor "$home"
  : > "$CALLS"
  session_start "$home" FAKE_MON_STATE=enabled
  assert_present "$home/digest.out" "session start produced no digest"
  case "$(cat "$home/state/monitor-status" 2>/dev/null)" in
    'status=enabled at='[0-9]*) ;;
    *) fail "a start with no watchdog unit should record the monitor read, got: $(cat "$home/state/monitor-status" 2>/dev/null)"$'\n'"$(tail -n 40 "$home/digest.out")" ;;
  esac
  assert_equals 1 "$(monitor_calls "$home")" "session start should read the monitor unit exactly once"
  pass "a session start with no watchdog unit runs the monitor read once"
}

test_session_start_reads_when_watchdog_disabled() {
  local home
  home=$(new_home "$TMP_ROOT/ss-disabled/home")
  clear_units
  install_unit watchdog "$home"
  : > "$CALLS"
  session_start "$home" FAKE_WD_STATE=disabled
  case "$(cat "$home/state/monitor-status" 2>/dev/null)" in
    'status=uncovered at='[0-9]*) ;;
    *) fail "a start whose watchdog unit does not run should record the monitor read, got: $(cat "$home/state/monitor-status" 2>/dev/null)" ;;
  esac
  pass "a session start whose watchdog unit does not run records the monitor read"
}

test_session_start_skips_when_watchdog_enabled() {
  local home
  home=$(new_home "$TMP_ROOT/ss-enabled/home")
  clear_units
  install_unit watchdog "$home"
  install_unit monitor "$home"
  : > "$CALLS"
  session_start "$home" FAKE_WD_STATE=enabled FAKE_MON_STATE=enabled
  assert_present "$home/digest.out" "session start produced no digest"
  # The divergence: the watchdog check itself ran and answered enabled.
  grep -q -F -- "$(FM_HOME="$home" "$WD" manager-name)" "$CALLS" \
    || fail "session start never asked the manager about the watchdog unit"
  assert_absent "$home/state/monitor-status" "a start with an enabled watchdog should leave the read to the watchdog"
  assert_equals 0 "$(monitor_calls "$home")" "a start with an enabled watchdog should not read the monitor unit"
  pass "a session start with an enabled watchdog leaves the monitor read to the watchdog"
}

test_lock_refused_start_writes_nothing() {
  local home
  home=$(new_home "$TMP_ROOT/ss-refused/home")
  clear_units
  : > "$CALLS"
  session_start "$home" FAKE_NO_HARNESS=1
  grep -q 'READ-ONLY SESSION' "$home/digest.out" \
    || fail "the fixture should refuse the lock"$'\n'"$(head -n 20 "$home/digest.out")"
  assert_absent "$home/state/monitor-status" "a lock-refused start must not write the monitor record"
  pass "a lock-refused session start writes no monitor record"
}

fm_test_run \
  test_pass_records_every_watched_home \
  test_pass_records_disabled_unit \
  test_pass_records_unreadable_without_manager_line \
  test_monitor_read_reports_unwritten_record \
  test_session_start_reads_once_without_watchdog \
  test_session_start_reads_when_watchdog_disabled \
  test_session_start_skips_when_watchdog_enabled \
  test_lock_refused_start_writes_nothing
