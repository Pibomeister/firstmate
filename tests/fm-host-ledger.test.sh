#!/usr/bin/env bash
# Behavioral coverage for bin/fm-host-ledger.sh: a sample row is appended
# with the documented columns, a second sample counts new pids against the
# first, report summarizes peaks, token readings come only from quota-axi's
# token-unit credits and report derives tokens per active-agent-hour from
# them, microbench and limits run, render-launchd emits a runnable 60-second
# LaunchAgent, and usage errors exit 2.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-host-ledger)
LEDGER="$ROOT/bin/fm-host-ledger.sh"
FAKE=$(fm_fakebin "$TMP_ROOT")
OUT=
RC=0

cat > "$FAKE/ps" <<'SH'
#!/usr/bin/env bash
cat "$FM_FAKE_PS_FILE"
SH
chmod +x "$FAKE/ps"

cat > "$FAKE/df" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "Filesystem 1024-blocks Used Available Capacity Mounted"
printf '/dev/fake 999999999 1 %s 1%% %s\n' "${FM_FAKE_DF_AVAIL:-104857600}" "${@: -1}"
SH
chmod +x "$FAKE/df"

cat > "$FAKE/sysctl" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    vm.loadavg) printf '{ 3.25 2.50 2.00 }\n' ;;
    vm.swapusage) printf 'total = 2048.00M  used = 512.50M  free = 1535.50M  (encrypted)\n' ;;
  esac
done
SH
chmod +x "$FAKE/sysctl"

# quota-axi stub: FM_FAKE_QUOTA_JSON names a file to print; unset means the
# read fails. Each call's arguments are appended to FM_FAKE_QUOTA_ARGS.
cat > "$FAKE/quota-axi" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_QUOTA_ARGS:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_QUOTA_ARGS"
[ -n "${FM_FAKE_QUOTA_JSON:-}" ] || { echo "quota-axi: vendor unreachable" >&2; exit 1; }
cat "$FM_FAKE_QUOTA_JSON"
SH
chmod +x "$FAKE/quota-axi"

run_ledger() {  # <ps-file> <ledger-dir> [args...]
  local ps_file=$1 dir=$2
  shift 2
  RC=0
  OUT=$(FM_FAKE_PS_FILE="$ps_file" FM_HOST_LEDGER_DIR="$dir" FM_HOST_LEDGER_NO_TOP=1 \
    PATH="$FAKE:$BASE_PATH" bash "$LEDGER" "$@" 2>&1) || RC=$?
}

test_sample_appends_row_and_counts_new_pids() {
  local dir="$TMP_ROOT/ledger" ps1="$TMP_ROOT/ps1" ps2="$TMP_ROOT/ps2"
  mkdir -p "$dir"
  cat > "$ps1" <<'EOF'
  100     1  10000 /sbin/launchd
  200   100   5000 /usr/local/bin/claude
  300   100   3000 /bin/bash
EOF
  cat > "$ps2" <<'EOF'
  100     1  10000 /sbin/launchd
  200   100   6000 /usr/local/bin/claude
  300   100   3000 /bin/bash
  400   300   2000 /usr/local/bin/grok
  500   300   1000 /usr/bin/timeout
EOF
  run_ledger "$ps1" "$dir" sample
  [ "$RC" = 0 ] || fail "first sample: expected exit 0, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "host-ledger: " "first sample prints its row"
  assert_contains "$OUT" "claude=1:5000" "first sample records the claude RSS"
  assert_contains "$OUT" "104857600" "first sample records free disk"
  assert_contains "$OUT" "512.50" "first sample records swap used"
  run_ledger "$ps2" "$dir" sample
  [ "$RC" = 0 ] || fail "second sample: expected exit 0, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "grok=1:2000" "second sample records the new grok worker"
  # two new pids (400, 500), both children of bash (300)
  local row new_field parents_field
  row=$(tail -n 1 "$dir"/ledger-*.tsv)
  new_field=$(printf '%s' "$row" | awk -F '\t' '{ print $4 }')
  parents_field=$(printf '%s' "$row" | awk -F '\t' '{ print $13 }')
  assert_equals "2" "$new_field" "second sample counts exactly the two new pids"
  assert_equals "bash=2" "$parents_field" "new pids are grouped under their parent"
  run_ledger "$ps2" "$dir" report --hours 1
  [ "$RC" = 0 ] || fail "report: expected exit 0, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "host-ledger report: rows=2" "report counts both rows"
  assert_contains "$OUT" "host-ledger cli: claude peak_count=1 peak_rss_kib=6000" "report keeps the peak RSS per CLI"
  pass "sample appends rows, counts new pids by parent, and report summarizes peaks"
}

quota_json() {  # <file> <claude-remaining> <grok-remaining>
  cat > "$1" <<EOF
{"schemaVersion":5,"providers":[
 {"provider":"claude","credits":{"remaining":$2,"unlimited":false,"unit":"tokens"},"windows":[]},
 {"provider":"grok","credits":{"remaining":$3,"unlimited":false,"unit":"tokens"},"windows":[]},
 {"provider":"codex","credits":{"remaining":17325.4,"unlimited":false,"unit":"credits"},"windows":[]},
 {"provider":"zai","notSetUp":true,"windows":[]}
]}
EOF
}

age_prev_pids() {  # <ledger-dir> <seconds>: backdate the previous snapshot
  perl -e 'my $t = time - $ARGV[1]; utime $t, $t, $ARGV[0] or die "utime: $!"' "$1/prev-pids.tsv" "$2"
}

test_tokens_recorded_from_quota_axi_and_rated_per_agent_hour() {
  local dir="$TMP_ROOT/tokens" ps="$TMP_ROOT/ps-tokens" q1="$TMP_ROOT/q1.json" q2="$TMP_ROOT/q2.json"
  local args="$TMP_ROOT/quota-args" row
  mkdir -p "$dir"
  cat > "$ps" <<'EOF'
  100     1  10000 /sbin/launchd
  200   100   5000 /usr/local/bin/claude
  300   100   3000 /bin/bash
EOF
  quota_json "$q1" 1000000 500000
  quota_json "$q2" 940000 500000
  FM_FAKE_QUOTA_JSON="$q1" FM_FAKE_QUOTA_ARGS="$args" run_ledger "$ps" "$dir" sample
  [ "$RC" = 0 ] || fail "first token sample: expected exit 0, got $RC"$'\n'"$OUT"
  row=$(tail -n 1 "$dir"/ledger-*.tsv)
  assert_equals "claude=1000000,grok=500000" "$(printf '%s' "$row" | awk -F '\t' '{ print $14 }')" \
    "only token-unit credits are recorded, per provider, unchanged"
  assert_equals "7" "$(printf '%s' "$row" | awk -F '\t' '{ print $15 }')" \
    "the seven known CLI providers without a token reading are counted as unreported"
  assert_contains "$(cat "$args")" "--json" "quota-axi is read as JSON"
  assert_contains "$(cat "$args")" "--no-credential-refresh" "the read never refreshes credentials"
  assert_contains "$(cat "$args")" "--max-age" "the read reuses quota-axi's cache"
  age_prev_pids "$dir" 1800
  FM_FAKE_QUOTA_JSON="$q2" run_ledger "$ps" "$dir" sample
  [ "$RC" = 0 ] || fail "second token sample: expected exit 0, got $RC"$'\n'"$OUT"
  run_ledger "$ps" "$dir" report --hours 1
  [ "$RC" = 0 ] || fail "token report: expected exit 0, got $RC"$'\n'"$OUT"
  local claude_line rate
  claude_line=$(printf '%s\n' "$OUT" | grep -F "host-ledger tokens: claude ")
  # 60000 tokens over one claude worker for ~1800 s (0.50 agent-hours) is ~120000 per agent-hour
  assert_contains "$claude_line" "tokens_consumed=60000" "consumption is the exact drop in remaining tokens"
  assert_contains "$claude_line" "active_agent_hours=0.50" "agent-hours are one worker over the measured interval"
  rate=$(printf '%s' "$claude_line" | sed -n 's/.*tokens_per_active_agent_hour=\([0-9]*\).*/\1/p')
  [ -n "$rate" ] && [ "$rate" -ge 119000 ] && [ "$rate" -le 120000 ] \
    || fail "expected about 120000 tokens per active-agent-hour, got: $claude_line"
  assert_contains "$OUT" "host-ledger tokens: grok tokens_consumed=0 active_agent_hours=0 tokens_per_active_agent_hour=unknown reason=no_active_workers" \
    "a provider with token readings but no live workers is not given a rate"
  pass "token readings come from quota-axi and report derives tokens per active-agent-hour only where both exist"
}

test_failed_quota_read_is_unreported_and_row_still_written() {
  local dir="$TMP_ROOT/tokens-fail" ps="$TMP_ROOT/ps-tokens" bad="$TMP_ROOT/bad.json" row
  mkdir -p "$dir"
  run_ledger "$ps" "$dir" sample
  [ "$RC" = 0 ] || fail "failed quota read: expected exit 0, got $RC"$'\n'"$OUT"
  row=$(tail -n 1 "$dir"/ledger-*.tsv)
  assert_equals "none" "$(printf '%s' "$row" | awk -F '\t' '{ print $14 }')" "a failed read records no tokens"
  assert_equals "9" "$(printf '%s' "$row" | awk -F '\t' '{ print $15 }')" "a failed read leaves every known provider unreported"
  printf 'not json {\n' > "$bad"
  FM_FAKE_QUOTA_JSON="$bad" run_ledger "$ps" "$dir" sample
  [ "$RC" = 0 ] || fail "unparsable quota read: expected exit 0, got $RC"$'\n'"$OUT"
  row=$(tail -n 1 "$dir"/ledger-*.tsv)
  assert_equals "none" "$(printf '%s' "$row" | awk -F '\t' '{ print $14 }')" "an unparsable read records no tokens"
  assert_equals "9" "$(printf '%s' "$row" | awk -F '\t' '{ print $15 }')" "an unparsable read leaves every known provider unreported"
  assert_equals "3" "$(wc -l < "$dir"/ledger-*.tsv | tr -d ' ')" "both samples appended their rows after the header"
  run_ledger "$ps" "$dir" report --hours 1
  assert_contains "$OUT" "host-ledger tokens: unreported" "report says tokens per active-agent-hour cannot be derived"
  pass "a failed or unparsable quota-axi read degrades to unreported and still appends the row"
}

test_render_launchd_runs_sample_every_minute() {
  local dir="$TMP_ROOT/launchd-ledger" plist="$TMP_ROOT/ledger.plist"
  mkdir -p "$dir"
  FM_HOST_LEDGER_DIR="$dir" PATH="$FAKE:$BASE_PATH" bash "$LEDGER" render-launchd > "$plist" \
    || fail "render-launchd failed"
  FM_FAKE_PS_FILE="$TMP_ROOT/ps1" FM_HOST_LEDGER_NO_TOP=1 \
    python3 - "$plist" "$LEDGER" "$dir" <<'PY' || fail "rendered ledger plist must run sample every 60 s"
import glob, os, plistlib, subprocess, sys
with open(sys.argv[1], 'rb') as f:
    p = plistlib.load(f)
assert p['Label'].startswith('dev.firstmate.host-ledger-'), p['Label']
assert p['ProgramArguments'] == ['/bin/bash', sys.argv[2], 'sample'], p['ProgramArguments']
assert p['StartInterval'] == 60 and p['RunAtLoad'] is True, p
assert 'KeepAlive' not in p
assert p['EnvironmentVariables']['FM_HOST_LEDGER_DIR'] == sys.argv[3]
env = dict(os.environ, **p['EnvironmentVariables'])
out = subprocess.run(p['ProgramArguments'], env=env, cwd='/', capture_output=True, text=True, timeout=60)
assert out.returncode == 0, out
assert glob.glob(os.path.join(sys.argv[3], 'ledger-*.tsv')), 'no ledger row written'
PY
  pass "render-launchd emits a 60-second LaunchAgent whose command appends a ledger row"
}

test_report_without_ledger_is_honest() {
  local dir="$TMP_ROOT/empty"
  mkdir -p "$dir"
  run_ledger "$TMP_ROOT/ps1" "$dir" report
  [ "$RC" = 0 ] || fail "empty report: expected exit 0, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "no ledger files" "an empty ledger reports no files instead of zeroed peaks"
  pass "report on an empty ledger says so"
}

test_microbench_and_limits_run() {
  run_ledger "$TMP_ROOT/ps1" "$TMP_ROOT/ledger" microbench --n 3
  [ "$RC" = 0 ] || fail "microbench: expected exit 0, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "cached_binary ms_per_exec=" "microbench times the cached binary"
  assert_contains "$OUT" "fresh_script_with_write ms_per_exec=" "microbench times fresh script paths"
  assert_contains "$OUT" "bash_c_true ms_per_exec=" "microbench keeps the bash -c row"
  assert_contains "$OUT" "builtin_true_in_one_bash ms_per_exec=" "microbench times the true builtin in one bash"
  assert_contains "$OUT" "external_true_in_one_bash ms_per_exec=" "microbench times the external true in that same bash"
  run_ledger "$TMP_ROOT/ps1" "$TMP_ROOT/ledger" microbench --n 0
  assert_equals "2" "$RC" "a zero --n is a usage error, not a division by zero"
  run_ledger "$TMP_ROOT/ps1" "$TMP_ROOT/ledger" limits
  [ "$RC" = 0 ] || fail "limits: expected exit 0, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "ulimit -n:" "limits prints the shell file limit"
  pass "microbench and limits produce their readings"
}

test_usage_errors_exit_2() {
  run_ledger "$TMP_ROOT/ps1" "$TMP_ROOT/ledger" frobnicate
  assert_equals "2" "$RC" "an unknown mode is a usage error"
  run_ledger "$TMP_ROOT/ps1" "$TMP_ROOT/ledger" report --hours nope
  assert_equals "2" "$RC" "a non-numeric --hours is a usage error"
  run_ledger "$TMP_ROOT/ps1" "$TMP_ROOT/ledger" --help
  assert_equals "0" "$RC" "--help succeeds"
  assert_contains "$OUT" "fm-host-ledger.sh sample" "--help prints the header"
  pass "usage errors exit 2 and --help prints the contract"
}

fm_test_run \
  test_sample_appends_row_and_counts_new_pids \
  test_tokens_recorded_from_quota_axi_and_rated_per_agent_hour \
  test_failed_quota_read_is_unreported_and_row_still_written \
  test_render_launchd_runs_sample_every_minute \
  test_report_without_ledger_is_honest \
  test_microbench_and_limits_run \
  test_usage_errors_exit_2
