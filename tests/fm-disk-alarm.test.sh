#!/usr/bin/env bash
# Behavioral coverage for bin/fm-disk-alarm.sh: free-space levels, the crew and
# lane gates, a missing or unreadable volume, the test-seam bypass, and the
# launch paths that must read the alarm before they create anything.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-disk-alarm)
ALARM="$ROOT/bin/fm-disk-alarm.sh"
FAKE=$(fm_fakebin "$TMP_ROOT")
OUT=
RC=0

cat > "$FAKE/df" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_DF_MARKER:-}" ]; then
  printf '%s\n' called >> "$FM_DF_MARKER"
fi
target=
for arg in "$@"; do
  target=$arg
done
if [ -n "${FM_DF_FIXTURE_VOLUME:-}" ] && [ "$target" = "$FM_DF_FIXTURE_VOLUME" ]; then
  case "${FM_DF_FIXTURE_MODE:-number}" in
    fail) exit 1 ;;
    junk)
      printf '%s\n' "Filesystem 1024-blocks Used Available Capacity Mounted"
      printf '%s\n' "/dev/fake 1 1 not-a-number 1% ${target}"
      exit 0
      ;;
  esac
  printf '%s\n' "Filesystem 1024-blocks Used Available Capacity Mounted"
  printf '/dev/fake 999999999 1 %s 1%% %s\n' "${FM_DF_FIXTURE_AVAIL:-0}" "$target"
  exit 0
fi
exec /bin/df "$@"
SH
chmod +x "$FAKE/df"

read_alarm() {  # <volume> <mode> <avail> [alarm args...]
  local volume=$1 mode=$2 avail=$3
  shift 3
  RC=0
  OUT=$(FM_DF_FIXTURE_VOLUME="$volume" FM_DF_FIXTURE_MODE="$mode" FM_DF_FIXTURE_AVAIL="$avail" \
    PATH="$FAKE:$BASE_PATH" FM_TEST_SEAM=1 FM_DISK_ALARM_VOLUME="$volume" \
    "$ALARM" "$@" 2>&1) || RC=$?
}

check_level() {  # <kib> <level> <crew-rc> <lane-rc> <human phrase>
  local kib=$1 level=$2 crew=$3 lane=$4 human=$5
  local volume="$TMP_ROOT/vol-$kib"
  mkdir -p "$volume"
  read_alarm "$volume" number "$kib"
  [ "$RC" = 0 ] || fail "report $kib: expected exit 0, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "disk-alarm: level=$level " "report $kib level"
  assert_contains "$OUT" "free_kib=$kib " "report $kib free space"
  if [ -n "$human" ]; then
    assert_contains "$OUT" "$human" "report $kib human line"
  else
    assert_not_contains "$OUT" "disk-alarm: WARN" "an ok reading must not warn"
    assert_not_contains "$OUT" "disk-alarm: PAUSE" "an ok reading must not pause"
    assert_not_contains "$OUT" "disk-alarm: STOP" "an ok reading must not stop"
  fi
  read_alarm "$volume" number "$kib" --gate crew
  [ "$RC" = "$crew" ] || fail "crew gate $kib: expected exit $crew, got $RC"$'\n'"$OUT"
  read_alarm "$volume" number "$kib" --gate lane
  [ "$RC" = "$lane" ] || fail "lane gate $kib: expected exit $lane, got $RC"$'\n'"$OUT"
}

run_bounded() {
  local timeout=$1
  shift
  python3 -c '
import subprocess, sys
timeout = float(sys.argv[1])
cmd = sys.argv[2:]
try:
    p = subprocess.run(cmd, timeout=timeout, capture_output=True, text=True)
except subprocess.TimeoutExpired:
    sys.stderr.write("TIMEOUT\n")
    sys.exit(124)
sys.stdout.write(p.stdout)
sys.stderr.write(p.stderr)
sys.exit(p.returncode)
' "$timeout" "$@"
}

test_help_and_usage_do_not_probe() {
  local marker="$TMP_ROOT/df-called" probe="$TMP_ROOT/probe-bin" out rc
  mkdir -p "$probe"
  cat > "$probe/df" <<EOF
#!/usr/bin/env bash
printf '%s\\n' called >> $(printf '%q' "$marker")
exit 1
EOF
  chmod +x "$probe/df"
  rc=0
  out=$(PATH="$probe:$BASE_PATH" "$ALARM" --help 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "help: expected exit 0, got $rc"$'\n'"$out"
  assert_contains "$out" "/System/Volumes/Data" "help must name the volume"
  assert_contains "$out" "15 GiB" "help must name the warn threshold"
  assert_absent "$marker" "help must not probe"
  rc=0
  out=$(PATH="$probe:$BASE_PATH" "$ALARM" --gate 2>&1) || rc=$?
  [ "$rc" = 2 ] || fail "--gate without a value: expected exit 2, got $rc"$'\n'"$out"
  assert_not_contains "$out" "level=" "a usage error must not report a reading"
  rc=0
  out=$(PATH="$probe:$BASE_PATH" "$ALARM" --gate other 2>&1) || rc=$?
  [ "$rc" = 2 ] || fail "--gate other: expected exit 2, got $rc"
  rc=0
  out=$(PATH="$probe:$BASE_PATH" "$ALARM" --nope 2>&1) || rc=$?
  [ "$rc" = 2 ] || fail "unknown flag: expected exit 2, got $rc"
  rc=0
  out=$(PATH="$probe:$BASE_PATH" "$ALARM" --gate crew extra 2>&1) || rc=$?
  [ "$rc" = 2 ] || fail "extra argument: expected exit 2, got $rc"
  assert_absent "$marker" "a usage error must not probe"
  pass "help names the volume and threshold, and usage does not probe"
}

test_levels_and_boundaries() {
  check_level 15728640 ok 0 0 ""
  check_level 15728639 warn 0 0 "under 15 GiB"
  check_level 14680064 warn 0 0 "14.0 GiB"
  check_level 10485760 warn 0 0 "under 15 GiB"
  check_level 10485759 pause 1 0 "under 10 GiB"
  check_level 9437184 pause 1 0 "9.0 GiB"
  check_level 5242880 pause 1 0 "under 10 GiB"
  check_level 5242879 stop 1 1 "under 5 GiB"
  check_level 4194304 stop 1 1 "4.0 GiB"
  pass "levels nest at the 15, 10, and 5 GiB boundaries"
}

test_absent_volume_allows_both_gates() {
  local missing="$TMP_ROOT/missing-volume" file="$TMP_ROOT/volume-file"
  printf 'x\n' > "$file"
  read_alarm "$missing" number 4194304
  [ "$RC" = 0 ] || fail "absent report: expected exit 0, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "level=absent " "a missing path is not in force"
  assert_contains "$OUT" "free_kib=unknown " "a missing path has no free-space figure"
  assert_not_contains "$OUT" "disk-alarm: STOP" "a missing path must not refuse"
  read_alarm "$missing" number 4194304 --gate crew
  [ "$RC" = 0 ] || fail "absent crew gate: expected exit 0, got $RC"$'\n'"$OUT"
  read_alarm "$missing" number 4194304 --gate lane
  [ "$RC" = 0 ] || fail "absent lane gate: expected exit 0, got $RC"$'\n'"$OUT"
  read_alarm "$file" number 4194304
  assert_contains "$OUT" "level=absent " "a file is not a volume"
  pass "a path that is not a directory leaves the alarm not in force"
}

test_unreadable_volume_refuses_both_gates() {
  local volume="$TMP_ROOT/unreadable"
  mkdir -p "$volume"
  read_alarm "$volume" fail 0
  [ "$RC" = 0 ] || fail "unreadable report: expected exit 0, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "level=unreadable " "a failed probe is unreadable"
  assert_contains "$OUT" "free_kib=unknown " "a failed probe has no figure"
  assert_contains "$OUT" "could not be read" "a failed probe tells the reader"
  read_alarm "$volume" fail 0 --gate crew
  [ "$RC" = 1 ] || fail "unreadable crew gate: expected exit 1, got $RC"$'\n'"$OUT"
  read_alarm "$volume" fail 0 --gate lane
  [ "$RC" = 1 ] || fail "unreadable lane gate: expected exit 1, got $RC"$'\n'"$OUT"
  read_alarm "$volume" junk 0
  [ "$RC" = 0 ] || fail "non-integer report: expected exit 0, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "level=unreadable " "a non-integer Available is unreadable"
  read_alarm "$volume" junk 0 --gate crew
  [ "$RC" = 1 ] || fail "non-integer crew gate: expected exit 1, got $RC"
  read_alarm "$volume" junk 0 --gate lane
  [ "$RC" = 1 ] || fail "non-integer lane gate: expected exit 1, got $RC"
  pass "an unreadable volume refuses a crew launch and a new lane"
}

test_seam_off_keeps_the_real_volume() {
  local volume="$TMP_ROOT/seam-volume"
  mkdir -p "$volume"
  RC=0
  OUT=$(env -u FM_TEST_SEAM \
    FM_DISK_ALARM_VOLUME="$volume" \
    FM_DF_FIXTURE_VOLUME="$volume" \
    FM_DF_FIXTURE_MODE=number \
    FM_DF_FIXTURE_AVAIL=4194304 \
    PATH="$FAKE:$BASE_PATH" \
    "$ALARM" 2>&1) || RC=$?
  [ "$RC" = 0 ] || fail "seam bypass: expected exit 0, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "volume=/System/Volumes/Data" "without the seam the real volume is read"
  assert_not_contains "$OUT" "$volume" "without the seam the override is ignored"
  pass "the volume override is inert unless the test seam is armed"
}

test_host_smoke() {
  RC=0
  OUT=$(env -u FM_DISK_ALARM_VOLUME PATH="$BASE_PATH" "$ALARM" 2>&1) || RC=$?
  [ "$RC" = 0 ] || fail "host report: expected exit 0, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "volume=/System/Volumes/Data" "the host reading names the volume"
  if [ -d /System/Volumes/Data ]; then
    case "$OUT" in
      *"level=ok "*|*"level=warn "*|*"level=pause "*|*"level=stop "*|*"level=unreadable "*) ;;
      *) fail "host reading has no known level"$'\n'"$OUT" ;;
    esac
    case "$OUT" in
      *"level=unreadable "*)
        assert_contains "$OUT" "free_kib=unknown " "an unreadable host has no figure"
        ;;
      *)
        case "$OUT" in
          *"free_kib="[0-9]*) ;;
          *) fail "host free space is not an integer"$'\n'"$OUT" ;;
        esac
        ;;
    esac
  else
    assert_contains "$OUT" "level=absent " "without the volume the alarm is not in force"
    assert_contains "$OUT" "free_kib=unknown " "an absent host volume has no figure"
  fi
  pass "the host reading is a real probe or an absent volume"
}

test_spawn_refuses_before_it_creates_anything() {
  local home volume out rc
  home="$TMP_ROOT/spawn-home"
  volume="$TMP_ROOT/spawn-volume"
  mkdir -p "$home/state" "$volume"
  rc=0
  out=$(run_bounded 40 env \
    FM_SPAWN_NO_GUARD=1 \
    FM_HOME="$home" \
    FM_TEST_SEAM=1 \
    FM_DISK_ALARM_VOLUME="$volume" \
    FM_DF_FIXTURE_VOLUME="$volume" \
    FM_DF_FIXTURE_MODE=number \
    FM_DF_FIXTURE_AVAIL=9437184 \
    PATH="$FAKE:$BASE_PATH" \
    "$ROOT/bin/fm-spawn.sh" disk-alarm --mode no-mistakes --yolo off 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "pause spawn: expected exit 1, got $rc"$'\n'"$out"
  assert_contains "$out" "disk-alarm: PAUSE " "a pause must refuse a fresh ship"
  assert_contains "$out" "no new crewmate launch" "a pause must name the crew refusal"
  assert_absent "$home/state/.task-set.lock" "a refused ship must not take the task-set lock"
  rc=0
  out=$(run_bounded 40 env \
    FM_SPAWN_NO_GUARD=1 \
    FM_HOME="$home" \
    FM_TEST_SEAM=1 \
    FM_DISK_ALARM_VOLUME="$volume" \
    FM_DF_FIXTURE_VOLUME="$volume" \
    FM_DF_FIXTURE_MODE=number \
    FM_DF_FIXTURE_AVAIL=4194304 \
    PATH="$FAKE:$BASE_PATH" \
    "$ROOT/bin/fm-spawn.sh" disk-alarm --scout 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "stop scout: expected exit 1, got $rc"$'\n'"$out"
  assert_contains "$out" "disk-alarm: STOP " "a stop must refuse a fresh scout"
  assert_contains "$out" "no new lane, worktree, or gate" "a stop must name the lane refusal"
  assert_absent "$home/state/.task-set.lock" "a refused scout must not take the task-set lock"
  rc=0
  out=$(run_bounded 40 env \
    FM_SPAWN_NO_GUARD=1 \
    FM_HOME="$home" \
    FM_TEST_SEAM=1 \
    FM_DISK_ALARM_VOLUME="$volume" \
    FM_DF_FIXTURE_VOLUME="$volume" \
    FM_DF_FIXTURE_MODE=number \
    FM_DF_FIXTURE_AVAIL=9437184 \
    PATH="$FAKE:$BASE_PATH" \
    "$ROOT/bin/fm-spawn.sh" disk-alarm --relaunch 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "relaunch of a missing task should still fail"$'\n'"$out"
  assert_not_contains "$out" "disk-alarm:" "a relaunch is not a new crewmate launch"
  assert_contains "$out" "needs an existing task record" "a relaunch still requires the existing task"
  assert_absent "$home/state/.task-set.lock" "a relaunch must not take the fresh-spawn lock"
  pass "a fresh launch refuses before it creates anything, and a relaunch does not"
}

test_home_seed_stop_does_not_lease() {
  local home volume marker out rc
  home="$TMP_ROOT/seed-home"
  volume="$TMP_ROOT/seed-volume"
  marker="$TMP_ROOT/treehouse-called"
  mkdir -p "$home" "$volume"
  cat > "$FAKE/treehouse" <<EOF
#!/usr/bin/env bash
printf '%s\\n' called >> $(printf '%q' "$marker")
printf '%s\\n' /tmp/not-a-leased-home
exit 0
EOF
  chmod +x "$FAKE/treehouse"
  rc=0
  out=$(run_bounded 40 env \
    FM_HOME="$home" \
    FM_TEST_SEAM=1 \
    FM_DISK_ALARM_VOLUME="$volume" \
    FM_DF_FIXTURE_VOLUME="$volume" \
    FM_DF_FIXTURE_MODE=number \
    FM_DF_FIXTURE_AVAIL=4194304 \
    PATH="$FAKE:$BASE_PATH" \
    "$ROOT/bin/fm-home-seed.sh" disk-alarm - --no-projects 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "stop seed: expected exit 1, got $rc"$'\n'"$out"
  assert_contains "$out" "disk-alarm: STOP " "a stop must refuse a new home lease"
  assert_contains "$out" "no new lane, worktree, or gate" "a stop must name the lease refusal"
  assert_absent "$marker" "a refused seed must not call treehouse"
  pass "a stop refuses a new home before any lease"
}

seed_root() {
  local root="$TMP_ROOT/seed-root"
  if [ ! -d "$root/.git" ]; then
    mkdir -p "$root"
    printf 'fixture\n' > "$root/AGENTS.md"
    cp -R "$ROOT/bin" "$root/bin"
    git -C "$root" init --quiet
    git -C "$root" add -A
    git -C "$root" -c user.name=fixture -c user.email=fixture@example.com commit --quiet -m fixture
  fi
  printf '%s\n' "$root"
}

seed_at_level() {  # <home> <volume> <avail> <id> <requested-home>
  local home=$1 volume=$2 avail=$3 id=$4 requested=$5 root
  root=$(seed_root)
  run_bounded 180 env \
    FM_ROOT_OVERRIDE="$root" \
    FM_HOME="$home" \
    FM_TEST_SEAM=1 \
    FM_SECONDMATE_CHARTER='disk alarm seed charter' \
    FM_DISK_ALARM_VOLUME="$volume" \
    FM_DF_FIXTURE_VOLUME="$volume" \
    FM_DF_FIXTURE_MODE=number \
    FM_DF_FIXTURE_AVAIL="$avail" \
    PATH="$FAKE:$PATH" \
    "$ROOT/bin/fm-home-seed.sh" "$id" "$requested" --no-projects 2>&1
}

test_home_seed_stop_does_not_clone_a_new_home() {
  local home volume target out rc
  home="$TMP_ROOT/clone-seed-home"
  volume="$TMP_ROOT/clone-seed-volume"
  target="$TMP_ROOT/clone-seed-target"
  mkdir -p "$home" "$volume"
  rc=0
  out=$(seed_at_level "$home" "$volume" 4194304 disk-alarm "$target") || rc=$?
  [ "$rc" = 1 ] || fail "stop clone seed: expected exit 1, got $rc"$'\n'"$out"
  assert_contains "$out" "disk-alarm: STOP " "a stop must refuse a new local clone home"
  assert_absent "$target" "a refused seed must not clone a home"
  assert_absent "$home/data/secondmates.md" "a refused seed must not register a home"
  rc=0
  out=$(seed_at_level "$home" "$volume" 9437184 disk-alarm "$target") || rc=$?
  [ "$rc" = 0 ] || fail "pause clone seed: expected exit 0, got $rc"$'\n'"$out"
  [ -d "$target/.git" ] || [ -f "$target/.git" ] || fail "a pause must still clone a new home"
  pass "a stop refuses a new local clone home before the clone, and a pause does not"
}

test_home_seed_stop_leaves_an_existing_home_alone() {
  local home volume target out rc
  home="$TMP_ROOT/existing-seed-home"
  volume="$TMP_ROOT/existing-seed-volume"
  target="$TMP_ROOT/existing-seed-target"
  mkdir -p "$home" "$volume"
  rc=0
  out=$(seed_at_level "$home" "$volume" 15728640 disk-alarm "$target") || rc=$?
  [ "$rc" = 0 ] || fail "ok seed: expected exit 0, got $rc"$'\n'"$out"
  rc=0
  out=$(seed_at_level "$home" "$volume" 4194304 disk-alarm "$target") || rc=$?
  [ "$rc" = 0 ] || fail "stop reseed of an existing home: expected exit 0, got $rc"$'\n'"$out"
  assert_not_contains "$out" "disk-alarm:" "an existing home must not read the alarm"
  pass "a stop leaves an existing home unaffected"
}

provision_at_level() {  # <new-home> <volume> <avail> <manifest>
  local target=$1 volume=$2 avail=$3 manifest=$4 root
  root=$(seed_root)
  env \
    FM_ROOT_OVERRIDE="$root" \
    FM_HOME="$target" \
    FM_TEST_SEAM=1 \
    FM_DISK_ALARM_VOLUME="$volume" \
    FM_DF_FIXTURE_VOLUME="$volume" \
    FM_DF_FIXTURE_MODE=number \
    FM_DF_FIXTURE_AVAIL="$avail" \
    PATH="$FAKE:$PATH" \
    "$ROOT/bin/fm-remote-home-provision.sh" < "$manifest" 2>&1
}

test_remote_provision_stop_gates_only_a_new_home() {
  local parent volume target manifest out rc
  parent="$TMP_ROOT/remote-parent"
  volume="$TMP_ROOT/remote-volume"
  target="$parent/home"
  manifest="$TMP_ROOT/remote.manifest"
  mkdir -p "$parent" "$volume"
  printf 'schema=fm-remote-home-provision.v1\nid_b64=%s\ncharter_b64=%s\nparent_host_b64=%s\nproject_count=0\n' \
    "$(printf disk-alarm | base64 | tr -d '\n')" \
    "$(printf 'Disk alarm charter.\n' | base64 | tr -d '\n')" \
    "$(printf parent-host | base64 | tr -d '\n')" > "$manifest"
  rc=0
  out=$(provision_at_level "$target" "$volume" 4194304 "$manifest") || rc=$?
  [ "$rc" = 1 ] || fail "stop provision: expected exit 1, got $rc"$'\n'"$out"
  assert_contains "$out" "disk-alarm: STOP " "a stop must refuse a new remote home"
  assert_absent "$target" "a refused provision must not create a home"
  [ -z "$(find "$parent" -mindepth 1 -maxdepth 1 -name '.fm-home-provisioning.*' -print -quit)" ] \
    || fail "a refused provision must not leave a staging directory"
  rc=0
  out=$(provision_at_level "$target" "$volume" 9437184 "$manifest") || rc=$?
  [ "$rc" = 0 ] || fail "pause provision: expected exit 0, got $rc"$'\n'"$out"
  [ -f "$target/.fm-secondmate-home" ] || fail "a pause must still provision a new home"
  rc=0
  out=$(provision_at_level "$target" "$volume" 4194304 "$manifest") || rc=$?
  [ "$rc" = 0 ] || fail "stop reprovision of an existing home: expected exit 0, got $rc"$'\n'"$out"
  assert_not_contains "$out" "disk-alarm:" "an existing remote home must not read the alarm"
  pass "a stop refuses a new remote home before staging and leaves an existing home alone"
}

test_suite_default_does_not_read_the_host_volume() {
  local marker="$TMP_ROOT/default-df-called" out rc
  rc=0
  out=$(FM_DF_MARKER="$marker" PATH="$FAKE:$BASE_PATH" "$ALARM" --gate crew 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "suite default: expected exit 0, got $rc"$'\n'"$out"
  assert_contains "$out" "level=absent " "the suite default must read as absent"
  assert_absent "$marker" "the suite default must not probe a volume"
  pass "the suite default leaves the alarm off the host volume"
}

test_dispatch_resolve_prints_the_alarm_and_stays_off() {
  local home volume brief out rc
  home="$TMP_ROOT/dispatch-home"
  volume="$TMP_ROOT/dispatch-volume"
  brief="$home/brief.md"
  mkdir -p "$home" "$volume"
  printf '%s\n' '## Captain intent' 'read the disk before launch' > "$brief"
  rc=0
  out=$(run_bounded 40 env -u TYPESAFE_API_KEY -u OPENROUTER_API_KEY -u OPENAI_API_KEY \
    -u FM_DISPATCH_API_KEY -u FM_DISPATCH_PROVIDER -u FM_DISPATCH_MODEL -u FM_DISPATCH_BASE_URL \
    FM_HOME="$home" \
    FM_TEST_SEAM=1 \
    FM_DISK_ALARM_VOLUME="$volume" \
    FM_DF_FIXTURE_VOLUME="$volume" \
    FM_DF_FIXTURE_MODE=number \
    FM_DF_FIXTURE_AVAIL=9437184 \
    PATH="$FAKE:$BASE_PATH" \
    "$ROOT/bin/fm-dispatch-resolve.sh" "$brief" 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "dispatch off: expected exit 0, got $rc"$'\n'"$out"
  assert_contains "$out" "disk-alarm: PAUSE " "dispatch must show the pause before it returns"
  assert_contains "$out" "dispatch-resolve: off " "a missing key still leaves resolution off"
  assert_not_contains "$out" "level=" "dispatch must not mix the machine line into its output"
  pass "dispatch prints the alarm and still returns off"
}

test_nm_driving_block_names_the_lane_gate() {
  local out
  # shellcheck source=bin/fm-dod-lib.sh
  . "$ROOT/bin/fm-dod-lib.sh"
  out=$(fm_nm_driving_block github disk-alarm)
  assert_contains "$out" "$ROOT/bin/fm-disk-alarm.sh --gate lane" "the worker instructions must name the lane gate"
  assert_contains "$out" "no-mistakes axi run --help" "the worker instructions must keep the pipeline help pointer"
  assert_contains "$out" "NEVER pass \`--yes\`" "the worker instructions must keep the yes ban"
  pass "a no-mistakes worker is told to read the lane gate before starting a run"
}

RETRY="$ROOT/bin/fm-disk-retry.sh"

spawn_at_level() {  # <home> <volume> <avail> <spawn args...>
  local home=$1 volume=$2 avail=$3
  shift 3
  run_bounded 120 env \
    FM_SPAWN_NO_GUARD=1 \
    FM_HOME="$home" \
    FM_TEST_SEAM=1 \
    FM_DISK_ALARM_VOLUME="$volume" \
    FM_DF_FIXTURE_VOLUME="$volume" \
    FM_DF_FIXTURE_MODE=number \
    FM_DF_FIXTURE_AVAIL="$avail" \
    PATH="$FAKE:$BASE_PATH" \
    "$ROOT/bin/fm-spawn.sh" "$@"
}

# A code root whose fm-spawn.sh only logs its arguments, one per line, then a
# blank line, and exits with FM_STUB_SPAWN_RC; it stands in for the real launch.
# Its fm-dispatch-resolve.sh writes the task's resolution record: clear with the
# profile codex/gpt-x/high, or the status named in <brief-dir>/stub-status.
stub_root() {
  local root="$TMP_ROOT/retry-stub-root"
  if [ ! -d "$root/bin" ]; then
    mkdir -p "$root"
    cp -R "$ROOT/bin" "$root/bin"
    cat > "$root/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
{ printf '%s\n' "$@"; printf '\n'; } >> "$FM_STUB_SPAWN_LOG"
echo "stub spawn output"
exit "${FM_STUB_SPAWN_RC:-0}"
SH
    cat > "$root/bin/fm-dispatch-resolve.sh" <<'SH'
#!/usr/bin/env bash
dir=$(dirname "$1")
status=clear
[ ! -f "$dir/stub-status" ] || status=$(cat "$dir/stub-status")
if [ "$status" = clear ]; then
  jq -n --arg t "${dir##*/}" '{task: $t, status: "clear", profile: {harness: "codex", model: "gpt-x", effort: "high"}}'
else
  jq -n --arg t "${dir##*/}" --arg s "$status" '{task: $t, status: $s, profile: null}'
fi > "$dir/dispatch-resolution.json"
printf 'dispatch-resolve:\n  status: %s\n' "$status"
SH
    chmod +x "$root/bin/fm-spawn.sh" "$root/bin/fm-dispatch-resolve.sh"
  fi
  printf '%s\n' "$root"
}

retry_at_level() {  # <home> <volume> <avail> <retry args...>
  local home=$1 volume=$2 avail=$3
  shift 3
  mkdir -p "$home/data"
  env \
    FM_HOME="$home" \
    FM_TEST_SEAM=1 \
    FM_DISK_ALARM_VOLUME="$volume" \
    FM_DF_FIXTURE_VOLUME="$volume" \
    FM_DF_FIXTURE_MODE=number \
    FM_DF_FIXTURE_AVAIL="$avail" \
    FM_STUB_SPAWN_LOG="$home/stub-spawn.log" \
    PATH="$FAKE:$BASE_PATH" \
    "$(stub_root)/bin/fm-disk-retry.sh" "$@"
}

wake_rows() {  # <home>
  if [ -f "$1/state/.wake-queue" ]; then wc -l < "$1/state/.wake-queue" | tr -d ' '; else printf 0; fi
}

# Recorded task ids, sorted, space-separated: the record directory is this
# script's persisted state contract.
recorded_ids() {  # <home>
  local f out=''
  for f in "$1/state/disk-refused"/*; do
    [ -f "$f" ] || continue
    out="$out${f##*/} "
  done
  printf '%s' "$out"
}

# The spawn arguments stored in a record, one per line.
recorded_args() {  # <home> <id>
  tail -n +2 "$1/state/disk-refused/$2" | tr '\0' '\n'
}

# Rewrite a record's refusal epoch, keeping its stored arguments.
set_epoch() {  # <home> <id> <epoch>
  perl -0777 -pi -e "s/\\A[0-9]+\\n/$3\\n/" "$1/state/disk-refused/$2"
}

# The fresh routing the stub resolver hands back, as stub spawn argument lines.
FRESH=$'\n'"--harness"$'\n'"codex"$'\n'"--model"$'\n'"gpt-x"$'\n'"--effort"$'\n'"high"

write_brief() {  # <home> <id>...
  local home=$1 id
  shift
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf '# Task\n## Captain'"'"'s intent\nRetry %s.\n' "$id" > "$home/data/$id/brief.md"
  done
}

stub_calls() {  # <home>
  cat "$1/stub-spawn.log" 2>/dev/null || true
}

test_refused_spawn_is_recorded_for_retry() {
  local home volume out rc
  home="$TMP_ROOT/retry-record-home"
  volume="$TMP_ROOT/retry-record-volume"
  mkdir -p "$home/state" "$volume"
  rc=0
  out=$(spawn_at_level "$home" "$volume" 9437184 ship-a --mode no-mistakes --yolo off 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "pause spawn: expected exit 1, got $rc"$'\n'"$out"
  rc=0
  out=$(spawn_at_level "$home" "$volume" 4194304 scout-b --scout 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "stop scout: expected exit 1, got $rc"$'\n'"$out"
  rc=0
  out=$(spawn_at_level "$home" "$volume" 9437184 relaunch-c --relaunch 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "relaunch of a missing task should still fail"$'\n'"$out"
  assert_equals "scout-b ship-a " "$(recorded_ids "$home")" "each disk-refused fresh launch, and no relaunch, must be recorded"
  assert_equals "ship-a"$'\n'"--mode"$'\n'"no-mistakes"$'\n'"--yolo"$'\n'"off" "$(recorded_args "$home" ship-a)" "the record keeps the refused launch's exact arguments"
  assert_equals "scout-b"$'\n'"--scout" "$(recorded_args "$home" scout-b)" "the scout record keeps its exact arguments"
  assert_equals 0 "$(wake_rows "$home")" "a refusal alone must not notify"
  pass "a disk-refused fresh launch is recorded with its arguments, and a relaunch is not"
}

test_retry_redispatches_when_the_alarm_clears() {
  local home volume marker out rc
  home="$TMP_ROOT/retry-scan-home"
  volume="$TMP_ROOT/retry-scan-volume"
  marker="$TMP_ROOT/retry-scan-df"
  mkdir -p "$home/state" "$volume"
  out=$(FM_DF_MARKER="$marker" retry_at_level "$home" "$volume" 20971520 scan 2>&1) || fail "an empty scan must exit 0"
  assert_equals "" "$out" "an empty scan prints nothing"
  assert_absent "$marker" "a scan with no record must not read the disk"
  write_brief "$home" ship-a scout-b
  retry_at_level "$home" "$volume" 9437184 record ship-a ship-a /p/a --mode no-mistakes --yolo off --harness claude --model opus --effort max --dispatch-override 'two words' || fail "record ship-a"
  retry_at_level "$home" "$volume" 9437184 record scout-b scout-b /p/b claude --scout --account seat-1 || fail "record scout-b"
  set_epoch "$home" ship-a 100
  set_epoch "$home" scout-b 200
  out=$(retry_at_level "$home" "$volume" 9437184 scan 2>&1) || fail "a scan under a standing alarm must exit 0"
  assert_equals "" "$out" "a scan under a standing alarm prints nothing"
  assert_equals "" "$(stub_calls "$home")" "a standing alarm launches nothing"
  assert_equals 0 "$(wake_rows "$home")" "a standing alarm must not notify"
  assert_equals "scout-b ship-a " "$(recorded_ids "$home")" "a standing alarm keeps every record"
  rc=0
  out=$(retry_at_level "$home" "$volume" 20971520 scan 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "a clearing scan must exit 0, got $rc"$'\n'"$out"
  assert_equals "ship-a"$'\n'"/p/a"$'\n'"--mode"$'\n'"no-mistakes"$'\n'"--yolo"$'\n'"off$FRESH"$'\n\n'"scout-b"$'\n'"/p/b"$'\n'"--scout$FRESH" "$(stub_calls "$home")" "the cleared alarm dispatches each record again, oldest first, with its arguments and freshly resolved routing in place of the recorded routing"
  assert_contains "$out" "check: disk alarm cleared (level=ok free_kib=20971520): re-dispatched by bin/fm-spawn.sh:" "the result names the reading and the re-dispatch"
  assert_contains "$out" " ship-a" "the result names the re-dispatched ship"
  assert_contains "$out" " scout-b" "the result names the re-dispatched scout"
  assert_equals 1 "$(wake_rows "$home")" "a cleared alarm queues exactly one notification"
  assert_contains "$(cat "$home/state/.wake-queue")" "$out" "the queued notification is the printed line"
  assert_equals "" "$(recorded_ids "$home")" "a re-dispatched record is removed"
  : > "$home/stub-spawn.log"
  out=$(retry_at_level "$home" "$volume" 20971520 scan 2>&1) || fail "a repeat scan must exit 0"
  assert_equals "" "$out" "a repeat scan prints nothing"
  assert_equals "" "$(stub_calls "$home")" "a repeat scan launches nothing"
  assert_equals 1 "$(wake_rows "$home")" "a cleared alarm must not notify twice"
  pass "a cleared alarm dispatches every disk-refused task again by itself and reports it once"
}

test_retry_drops_work_already_placed_elsewhere() {
  local home volume out
  home="$TMP_ROOT/retry-elsewhere-home"
  volume="$TMP_ROOT/retry-elsewhere-volume"
  mkdir -p "$home/state" "$volume"
  retry_at_level "$home" "$volume" 9437184 record ship-live ship-live --mode no-mistakes --yolo off || fail "record ship-live"
  retry_at_level "$home" "$volume" 9437184 record ship-moved ship-moved --mode no-mistakes --yolo off || fail "record ship-moved"
  retry_at_level "$home" "$volume" 9437184 record ship-old ship-old --mode no-mistakes --yolo off || fail "record ship-old"
  retry_at_level "$home" "$volume" 9437184 record ship-c ship-c --mode no-mistakes --yolo off || fail "record ship-c"
  write_brief "$home" ship-c ship-old
  printf 'kind=ship\n' > "$home/state/ship-live.meta"
  printf '2026-11-19T00:00:00Z\t%s\tdispatched\tgoal-1\ttask=ship-moved note=placed on another host\n' "$(( $(date +%s) + 5 ))" > "$home/state/dispatch-log.tsv"
  printf '2026-01-01T00:00:00Z\t1\tdispatched\tgoal-0\ttask=ship-old\n' >> "$home/state/dispatch-log.tsv"
  out=$(retry_at_level "$home" "$volume" 20971520 scan 2>&1) || fail "the scan must exit 0"$'\n'"$out"
  assert_equals "ship-c"$'\n'"--mode"$'\n'"no-mistakes"$'\n'"--yolo"$'\n'"off$FRESH"$'\n\n'"ship-old"$'\n'"--mode"$'\n'"no-mistakes"$'\n'"--yolo"$'\n'"off$FRESH" "$(stub_calls "$home")" "only tasks with no live record and no newer dispatch are launched again"
  assert_contains "$out" "re-dispatched by bin/fm-spawn.sh: ship-c ship-old" "a dispatch older than the refusal does not stop the re-dispatch"
  assert_contains "$out" "dropped, already launched or placed elsewhere: ship-live ship-moved" "the result names the dropped records"
  assert_equals "" "$(recorded_ids "$home")" "a stale record is removed"
  pass "a record of work already launched or placed elsewhere is dropped without a second launch"
}

test_retry_keeps_deferred_and_reports_failed() {
  local home volume out
  home="$TMP_ROOT/retry-defer-home"
  volume="$TMP_ROOT/retry-defer-volume"
  mkdir -p "$home/state" "$volume"
  retry_at_level "$home" "$volume" 9437184 record ship-d ship-d --mode no-mistakes --yolo off || fail "record ship-d"
  write_brief "$home" ship-d
  out=$(FM_STUB_SPAWN_RC=75 retry_at_level "$home" "$volume" 20971520 scan 2>&1) || fail "a deferred scan must exit 0"
  assert_equals "" "$out" "a capacity deferral is not a result to report"
  assert_equals 0 "$(wake_rows "$home")" "a capacity deferral must not notify"
  assert_equals "ship-d"$'\n'"--mode"$'\n'"no-mistakes"$'\n'"--yolo"$'\n'"off" "$(recorded_args "$home" ship-d)" "a capacity deferral keeps the record for a later scan"
  out=$(FM_STUB_SPAWN_RC=1 retry_at_level "$home" "$volume" 20971520 scan 2>&1) || fail "a failed scan must exit 0"
  assert_contains "$out" "re-dispatch failed, see state/disk-refused/.log.<task-id>: ship-d" "a failed re-dispatch is reported"
  assert_equals "stub spawn output" "$(cat "$home/state/disk-refused/.log.ship-d")" "the failed spawn's output is kept"
  assert_equals "" "$(recorded_ids "$home")" "a failed re-dispatch is not retried again"
  assert_equals 1 "$(wake_rows "$home")" "a failed re-dispatch notifies once"
  pass "a capacity deferral keeps its record and a failed re-dispatch is reported once"
}

test_admitted_spawn_clears_its_retry_record() {
  local home volume
  home="$TMP_ROOT/retry-clear-home"
  volume="$TMP_ROOT/retry-clear-volume"
  mkdir -p "$home/state" "$volume"
  spawn_at_level "$home" "$volume" 9437184 ship-a --mode no-mistakes --yolo off >/dev/null 2>&1 || true
  assert_present "$home/state/disk-refused/ship-a" "the refusal must leave a record"
  spawn_at_level "$home" "$volume" 20971520 ship-a --mode no-mistakes --yolo off >/dev/null 2>&1 || true
  assert_absent "$home/state/disk-refused/ship-a" "a launch the alarm admits must not be dispatched again"
  pass "a launch the alarm admits removes its own retry record"
}

test_watcher_reports_the_redispatch() {
  local home volume out
  home="$TMP_ROOT/retry-watch-home"
  volume="$TMP_ROOT/retry-watch-volume"
  mkdir -p "$home/state" "$home/config" "$volume"
  write_brief "$home" ship-a
  retry_at_level "$home" "$volume" 9437184 record ship-a ship-a --mode no-mistakes --yolo off || fail "record ship-a"
  # shellcheck disable=SC2016
  out=$(env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_TEST_SEAM=1 FM_DISK_ALARM_VOLUME="$volume" FM_DF_FIXTURE_VOLUME="$volume" \
    FM_DF_FIXTURE_MODE=number FM_STUB_SPAWN_LOG="$home/stub-spawn.log" PATH="$FAKE:$BASE_PATH" \
    WATCH="$(stub_root)/bin/fm-watch.sh" STATE_DIR="$home/state" \
    bash -c '. "$WATCH"
      wait_scan() { local pid=$1 i=0; while kill -0 "$pid" 2>/dev/null; do i=$((i + 1)); [ "$i" -lt 600 ] || return 1; sleep 0.1; done; }
      export FM_DF_FIXTURE_AVAIL=9437184
      disk_retry_tick || exit 1
      wait_scan "$!" || exit 1
      ls "$STATE_DIR/disk-refused"/.report.* >/dev/null 2>&1 && exit 1
      export FM_DF_FIXTURE_AVAIL=20971520
      disk_retry_tick || exit 1
      printf "launch=[%s]\n" "$DISK_RETRY_REASON"
      wait_scan "$!" || exit 1
      disk_retry_tick || exit 1
      printf "cleared=[%s]\n" "$DISK_RETRY_REASON"
      disk_retry_tick || exit 1
      printf "repeat=[%s]\n" "$DISK_RETRY_REASON"' 2>&1) || fail "the watcher tick failed"$'\n'"$out"
  assert_contains "$out" "launch=[]" "the tick that starts the scan does not wait for it"
  assert_contains "$out" "cleared=[check: disk alarm cleared (level=ok free_kib=20971520): re-dispatched by bin/fm-spawn.sh: ship-a]" "the watcher reports the re-dispatch"
  assert_contains "$out" "repeat=[]" "the watcher reports the re-dispatch once"
  assert_equals "ship-a"$'\n'"--mode"$'\n'"no-mistakes"$'\n'"--yolo"$'\n'"off$FRESH" "$(stub_calls "$home")" "the watcher's scan dispatches the task again exactly once"
  assert_equals 1 "$(wake_rows "$home")" "the watcher path queues exactly one notification"
  pass "the watcher dispatches the refused task again in the background and reports it once"
}

test_retry_hands_unclear_routing_to_the_supervisor() {
  local home volume out
  home="$TMP_ROOT/retry-unclear-home"
  volume="$TMP_ROOT/retry-unclear-volume"
  mkdir -p "$home/state" "$volume"
  write_brief "$home" ship-e
  printf 'ambiguous\n' > "$home/data/ship-e/stub-status"
  retry_at_level "$home" "$volume" 9437184 record ship-e ship-e --mode no-mistakes --yolo off --harness claude || fail "record ship-e"
  retry_at_level "$home" "$volume" 9437184 record ship-f ship-f --mode no-mistakes --yolo off --harness claude || fail "record ship-f"
  set_epoch "$home" ship-e 100
  set_epoch "$home" ship-f 200
  out=$(retry_at_level "$home" "$volume" 20971520 scan 2>&1) || fail "the scan must exit 0"$'\n'"$out"
  assert_equals "" "$(stub_calls "$home")" "a task whose routing does not resolve clear is never launched with its recorded routing"
  assert_contains "$out" "not re-dispatched, dispatch resolution was not clear, dispatch by hand: ship-e (ambiguous) ship-f (no brief)" "the result hands each task to the supervisor with its resolution"
  assert_equals 1 "$(wake_rows "$home")" "the hand-off queues one notification"
  assert_equals "" "$(recorded_ids "$home")" "a handed-off record is not scanned again"
  pass "a re-dispatch whose fresh routing is not clear launches nothing and asks for dispatch by hand"
}

test_retry_skips_held_or_blocked_backlog_items() {
  local home volume out backlog axi_dir
  command -v tasks-axi >/dev/null 2>&1 || { pass "skipped: tasks-axi is not installed"; return 0; }
  axi_dir=$(dirname "$(command -v tasks-axi)")
  home="$TMP_ROOT/retry-held-home"
  volume="$TMP_ROOT/retry-held-volume"
  backlog="$home/data/backlog.md"
  mkdir -p "$home/state" "$home/config" "$home/data" "$volume"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$backlog"
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' > "$home/.tasks.toml"
  (
    cd "$home" || exit 1
    for id in ship-held ship-blocked ship-q; do
      TASKS_AXI_BACKEND=markdown tasks-axi add "$id" "item $id" --kind ship --file "$backlog" >/dev/null || exit 1
    done
    TASKS_AXI_BACKEND=markdown tasks-axi hold ship-held --reason "captain call" --kind captain --file "$backlog" >/dev/null || exit 1
    TASKS_AXI_BACKEND=markdown tasks-axi block ship-blocked --by ship-held --file "$backlog" >/dev/null || exit 1
  ) || fail "the backlog fixture could not be built"
  write_brief "$home" ship-held ship-blocked ship-q
  for id in ship-held ship-blocked ship-q; do
    retry_at_level "$home" "$volume" 9437184 record "$id" "$id" --mode no-mistakes --yolo off || fail "record $id"
  done
  set_epoch "$home" ship-held 100
  set_epoch "$home" ship-blocked 200
  set_epoch "$home" ship-q 300
  out=$(cd "$home" && TASKS_AXI_BACKEND=markdown FAKE="$FAKE:$axi_dir" retry_at_level "$home" "$volume" 20971520 scan 2>&1) || fail "the scan must exit 0"$'\n'"$out"
  assert_equals "ship-q"$'\n'"--mode"$'\n'"no-mistakes"$'\n'"--yolo"$'\n'"off$FRESH" "$(stub_calls "$home")" "only the unheld, unblocked Queued item is launched again"
  assert_contains "$out" "skipped, backlog item held or blocked, record kept: ship-held ship-blocked" "the result names the held and the blocked item"
  assert_equals "ship-blocked ship-held " "$(recorded_ids "$home")" "a held or blocked item keeps its record"
  assert_equals 1 "$(wake_rows "$home")" "the first scan notifies once"
  out=$(cd "$home" && TASKS_AXI_BACKEND=markdown FAKE="$FAKE:$axi_dir" retry_at_level "$home" "$volume" 20971520 scan 2>&1) || fail "the repeat scan must exit 0"$'\n'"$out"
  assert_equals "" "$out" "a repeat scan does not report the same skip again"
  assert_equals 1 "$(wake_rows "$home")" "a repeat scan does not notify again"
  assert_equals "ship-blocked ship-held " "$(recorded_ids "$home")" "a repeat scan still keeps the records"
  pass "a held or blocked backlog item is skipped once, keeps its record, and is never launched"
}

test_retry_report_is_renamed_into_place() {
  local home volume out wrap
  home="$TMP_ROOT/retry-report-home"
  volume="$TMP_ROOT/retry-report-volume"
  wrap="$TMP_ROOT/retry-report-mv"
  mkdir -p "$home/state" "$volume" "$wrap"
  cat > "$wrap/mv" <<'SH'
#!/usr/bin/env bash
for last in "$@"; do :; done
case "${last##*/}" in .report.*) printf '%s\n' "$(cat "${@: -2:1}")" >> "$MV_LOG" ;; esac
exec /bin/mv "$@"
SH
  chmod +x "$wrap/mv"
  write_brief "$home" ship-r
  retry_at_level "$home" "$volume" 9437184 record ship-r ship-r --mode no-mistakes --yolo off || fail "record ship-r"
  out=$(MV_LOG="$home/mv.log" FAKE="$wrap:$FAKE" retry_at_level "$home" "$volume" 20971520 scan 2>&1) || fail "the scan must exit 0"$'\n'"$out"
  assert_equals "$out" "$(cat "$home/mv.log" 2>/dev/null)" "the report file appears only by a rename of the complete line"
  assert_equals "$out" "$(cat "$home/state/disk-refused"/.report.*)" "the report file holds the complete line"
  pass "the scan report is written in full before it becomes visible"
}

test_retry_usage_errors() {
  local rc
  rc=0; "$RETRY" record >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "record without a task id is a usage error"
  rc=0; "$RETRY" record ship-a >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "record without spawn arguments is a usage error"
  rc=0; "$RETRY" record '../x' '../x' >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "a task id with a path character is a usage error"
  rc=0; "$RETRY" list >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "list is not a subcommand"
  rc=0; "$RETRY" bogus >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "an unknown subcommand is a usage error"
  assert_contains "$("$RETRY" --help)" "fm-disk-retry.sh scan" "help prints the usage"
  pass "the retry record refuses malformed input"
}

fm_test_run \
  test_help_and_usage_do_not_probe \
  test_levels_and_boundaries \
  test_absent_volume_allows_both_gates \
  test_unreadable_volume_refuses_both_gates \
  test_seam_off_keeps_the_real_volume \
  test_host_smoke \
  test_spawn_refuses_before_it_creates_anything \
  test_home_seed_stop_does_not_lease \
  test_home_seed_stop_does_not_clone_a_new_home \
  test_home_seed_stop_leaves_an_existing_home_alone \
  test_remote_provision_stop_gates_only_a_new_home \
  test_suite_default_does_not_read_the_host_volume \
  test_dispatch_resolve_prints_the_alarm_and_stays_off \
  test_nm_driving_block_names_the_lane_gate \
  test_refused_spawn_is_recorded_for_retry \
  test_retry_redispatches_when_the_alarm_clears \
  test_retry_drops_work_already_placed_elsewhere \
  test_retry_keeps_deferred_and_reports_failed \
  test_admitted_spawn_clears_its_retry_record \
  test_watcher_reports_the_redispatch \
  test_retry_hands_unclear_routing_to_the_supervisor \
  test_retry_skips_held_or_blocked_backlog_items \
  test_retry_report_is_renamed_into_place \
  test_retry_usage_errors
