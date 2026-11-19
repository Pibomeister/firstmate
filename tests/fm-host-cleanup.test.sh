#!/usr/bin/env bash
# Behavioral coverage for bin/fm-host-cleanup.sh: report measures without
# deleting, clean without --apply is a dry run, clean --apply deletes only
# files past the age limit under the configured roots (never worktree
# files), and a free-space reading under the target exits 3.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-host-cleanup)
CLEANUP="$ROOT/bin/fm-host-cleanup.sh"
FAKE=$(fm_fakebin "$TMP_ROOT")
OUT=
RC=0

cat > "$FAKE/df" <<'SH'
#!/usr/bin/env bash
target=
for arg in "$@"; do target=$arg; done
if [ "$target" = "$FM_FAKE_VOLUME" ]; then
  printf '%s\n' "Filesystem 1024-blocks Used Available Capacity Mounted"
  printf '/dev/fake 999999999 1 %s 1%% %s\n' "$FM_FAKE_DF_AVAIL" "$target"
  exit 0
fi
exec /bin/df "$@"
SH
chmod +x "$FAKE/df"

# Fixture layout under $TMP_ROOT/world:
#   cache/old.bin (old), cache/sub/new.bin (new), logs/old.log (old),
#   workspaces/proj/tracked.txt (old but never in scope)
WORLD="$TMP_ROOT/world"
mkdir -p "$WORLD/cache/sub" "$WORLD/logs" "$WORLD/workspaces/proj" "$WORLD/state" "$WORLD/vol"
printf 'old cache bytes\n' > "$WORLD/cache/old.bin"
printf 'new cache bytes\n' > "$WORLD/cache/sub/new.bin"
printf 'old log bytes\n' > "$WORLD/logs/old.log"
printf 'project bytes\n' > "$WORLD/workspaces/proj/tracked.txt"
touch -t 202501010000 "$WORLD/cache/old.bin" "$WORLD/logs/old.log" "$WORLD/workspaces/proj/tracked.txt"

run_cleanup() {  # <df-avail-kib> [args...]
  local avail=$1
  shift
  RC=0
  OUT=$(FM_TEST_SEAM=1 FM_CLEANUP_VOLUME="$WORLD/vol" FM_FAKE_VOLUME="$WORLD/vol" \
    FM_FAKE_DF_AVAIL="$avail" \
    FM_CLEANUP_CACHE_ROOTS="$WORLD/cache" FM_CLEANUP_LOG_ROOTS="$WORLD/logs" \
    FM_CLEANUP_WORKTREE_ROOTS="$WORLD/workspaces" FM_CLEANUP_DIR="$WORLD/state" \
    FM_CLEANUP_TARGET_GIB=100 \
    PATH="$FAKE:$BASE_PATH" bash "$CLEANUP" "$@" 2>&1) || RC=$?
}

test_report_measures_and_deletes_nothing() {
  run_cleanup 209715200 report
  [ "$RC" = 0 ] || fail "report: expected exit 0 over target, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "host-cleanup report: free_kib=209715200" "report prints the free reading"
  assert_contains "$OUT" "host-cleanup cache: root=$WORLD/cache" "report names the cache root"
  assert_contains "$OUT" "old_files=1" "report counts exactly the one old cache file"
  assert_contains "$OUT" "host-cleanup worktrees: root=$WORLD/workspaces/proj" "report sizes the worktree"
  assert_present "$WORLD/cache/old.bin" "report deletes nothing"
  pass "report measures free space, old files, and worktrees without deleting"
}

test_report_under_target_exits_3() {
  run_cleanup 1048576 report
  assert_equals "3" "$RC" "one GiB free against a 100 GiB target exits 3"
  assert_contains "$OUT" "under the 100 GiB target" "the under-target state is stated, not hidden"
  pass "an under-target reading exits 3 and says why"
}

test_clean_dry_run_deletes_nothing() {
  run_cleanup 209715200 clean
  [ "$RC" = 0 ] || fail "dry run: expected exit 0, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "mode=dry-run" "clean without --apply is a dry run"
  assert_contains "$OUT" "remaining_old_files=1" "dry run leaves the old files counted"
  assert_present "$WORLD/cache/old.bin" "dry run keeps the old cache file"
  assert_present "$WORLD/logs/old.log" "dry run keeps the old log file"
  pass "clean without --apply deletes nothing"
}

test_clean_apply_deletes_only_old_cache_and_logs() {
  run_cleanup 209715200 clean --apply
  [ "$RC" = 0 ] || fail "apply: expected exit 0, got $RC"$'\n'"$OUT"
  assert_contains "$OUT" "mode=apply" "apply mode is named in the output"
  assert_absent "$WORLD/cache/old.bin" "the old cache file is deleted"
  assert_absent "$WORLD/logs/old.log" "the old log file is deleted"
  assert_present "$WORLD/cache/sub/new.bin" "a fresh cache file survives"
  assert_present "$WORLD/workspaces/proj/tracked.txt" "an old worktree file is never in scope"
  assert_grep "clean free_before_kib=209715200 free_after_kib=209715200" "$WORLD/state/cleanup.log" "apply appends the before/after line"
  pass "clean --apply deletes only old cache and log files and logs the run"
}

test_usage_errors_exit_2() {
  run_cleanup 209715200 frobnicate
  assert_equals "2" "$RC" "an unknown mode is a usage error"
  run_cleanup 209715200 clean --bogus
  assert_equals "2" "$RC" "an unknown clean flag is a usage error"
  run_cleanup 209715200 --help
  assert_equals "0" "$RC" "--help succeeds"
  assert_contains "$OUT" "fm-host-cleanup.sh report" "--help prints the header"
  pass "usage errors exit 2 and --help prints the contract"
}

fm_test_run \
  test_report_measures_and_deletes_nothing \
  test_report_under_target_exits_3 \
  test_clean_dry_run_deletes_nothing \
  test_clean_apply_deletes_only_old_cache_and_logs \
  test_usage_errors_exit_2
