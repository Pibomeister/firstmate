#!/usr/bin/env bash
# Behavioral coverage for bin/fm-host-ledger.sh: a sample row is appended
# with the documented columns, a second sample counts new pids against the
# first, report summarizes peaks, microbench and limits run, and usage
# errors exit 2.
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
  test_report_without_ledger_is_honest \
  test_microbench_and_limits_run \
  test_usage_errors_exit_2
