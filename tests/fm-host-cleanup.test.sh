#!/usr/bin/env bash
# Behavioral coverage for bin/fm-host-cleanup.sh: report measures without
# deleting, clean without --apply is a dry run, clean --apply removes only
# whole entries whose newest content is past the age limit under the
# configured roots (never a partly fresh entry, never worktree files) and
# prints the worktree size report, render-launchd emits a runnable 6-hour
# LaunchAgent, and a free-space reading under the target exits 3.
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

# Fixture layout under $TMP_ROOT/world (old means mtime in 2025):
#   cache/old.bin                 old file entry: removed whole
#   cache/sub/new.bin             fresh entry: kept
#   cache/pre-commit/repo1/hook.py + repo1/  old, pre-commit/db.db fresh:
#                                 a structured cache that must stay intact
#   cache/stale/a/b.bin + a/ + stale/  fully old directory entry: removed whole
#   logs/old.log                  old log entry: removed
#   workspaces/proj/tracked.txt   old but never in scope
WORLD="$TMP_ROOT/world"
mkdir -p "$WORLD/cache/sub" "$WORLD/cache/pre-commit/repo1" "$WORLD/cache/stale/a" \
  "$WORLD/logs" "$WORLD/workspaces/proj" "$WORLD/state" "$WORLD/vol"
printf 'old cache bytes\n' > "$WORLD/cache/old.bin"
printf 'new cache bytes\n' > "$WORLD/cache/sub/new.bin"
printf 'old hook env\n' > "$WORLD/cache/pre-commit/repo1/hook.py"
printf 'fresh index\n' > "$WORLD/cache/pre-commit/db.db"
printf 'stale bytes\n' > "$WORLD/cache/stale/a/b.bin"
printf 'old log bytes\n' > "$WORLD/logs/old.log"
printf 'project bytes\n' > "$WORLD/workspaces/proj/tracked.txt"
touch -t 202501010000 "$WORLD/cache/old.bin" "$WORLD/logs/old.log" "$WORLD/workspaces/proj/tracked.txt" \
  "$WORLD/cache/pre-commit/repo1/hook.py" "$WORLD/cache/pre-commit/repo1" \
  "$WORLD/cache/stale/a/b.bin" "$WORLD/cache/stale/a" "$WORLD/cache/stale"

line_for() {  # <prefix>: print the first output line starting with prefix
  printf '%s\n' "$OUT" | grep -F -- "$1" | head -n 1
}

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
  assert_contains "$(line_for "host-cleanup cache: root=$WORLD/cache ")" "old_entries=2" "report counts exactly the two fully old cache entries"
  assert_contains "$(line_for "host-cleanup logs: root=$WORLD/logs ")" "old_entries=1" "report counts the one old log entry"
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
  assert_contains "$(line_for "host-cleanup clean: root=$WORLD/cache ")" "old_entries=2 " "dry run counts the same two old cache entries as report"
  assert_contains "$(line_for "host-cleanup clean: root=$WORLD/cache ")" "remaining_old_entries=2" "dry run leaves the old entries counted"
  assert_present "$WORLD/cache/stale/a/b.bin" "dry run keeps the fully old entry"
  assert_present "$WORLD/cache/old.bin" "dry run keeps the old cache file"
  assert_contains "$OUT" "host-cleanup worktrees: root=$WORLD/workspaces/proj size_kib=" "dry run prints the worktree size report"
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
  assert_absent "$WORLD/cache/stale" "a fully old entry is removed whole"
  assert_present "$WORLD/cache/pre-commit/repo1/hook.py" "an old file inside a partly fresh entry survives"
  assert_present "$WORLD/cache/pre-commit/db.db" "the fresh index of that entry survives"
  assert_contains "$(line_for "host-cleanup clean: root=$WORLD/cache ")" "remaining_old_entries=0" "apply leaves no old cache entry behind"
  assert_present "$WORLD/workspaces/proj/tracked.txt" "an old worktree file is never in scope"
  assert_contains "$OUT" "host-cleanup worktrees: root=$WORLD/workspaces/proj size_kib=" "the scheduled apply run prints the worktree size report"
  assert_grep "clean free_before_kib=209715200 free_after_kib=209715200" "$WORLD/state/cleanup.log" "apply appends the before/after line"
  pass "clean --apply removes only whole old cache and log entries and logs the run"
}

npm_home() {  # <home> <index-age: old|fresh>: build a default-root npm cache
  local home=$1
  mkdir -p "$home/.npm/_cacache/content-v2/sha512/ab" "$home/.npm/_cacache/index-v5/cd" "$home/vol"
  printf 'blob\n' > "$home/.npm/_cacache/content-v2/sha512/ab/blob"
  printf 'index\n' > "$home/.npm/_cacache/index-v5/cd/entry"
  touch -t 202501010000 "$home/.npm/_cacache/content-v2/sha512/ab/blob" \
    "$home/.npm/_cacache/content-v2/sha512/ab" "$home/.npm/_cacache/content-v2/sha512" \
    "$home/.npm/_cacache/content-v2"
  if [ "$2" = old ]; then
    touch -t 202501010000 "$home/.npm/_cacache/index-v5/cd/entry" \
      "$home/.npm/_cacache/index-v5/cd" "$home/.npm/_cacache/index-v5" "$home/.npm/_cacache"
  fi
}

run_default_roots() {  # <home> [args...]: run with the default roots under home
  local home=$1
  shift
  RC=0
  OUT=$(env -u FM_CLEANUP_CACHE_ROOTS -u FM_CLEANUP_LOG_ROOTS -u FM_CLEANUP_WORKTREE_ROOTS \
    -u FM_CLEANUP_DIR -u XDG_STATE_HOME HOME="$home" \
    FM_TEST_SEAM=1 FM_CLEANUP_VOLUME="$home/vol" FM_FAKE_VOLUME="$home/vol" \
    FM_FAKE_DF_AVAIL=209715200 FM_CLEANUP_TARGET_GIB=100 \
    PATH="$FAKE:$BASE_PATH" bash "$CLEANUP" "$@" 2>&1) || RC=$?
}

test_clean_lists_each_root_once() {
  local world="$TMP_ROOT/scan" spy="$TMP_ROOT/scan-bin" log="$TMP_ROOT/scan.log" mode count args
  mkdir -p "$spy"
  cat > "$spy/find" <<'SH'
#!/usr/bin/env bash
if [ "$2" = -mindepth ] && [ "$3" = 1 ]; then printf '%s\n' "$1" >> "$FM_FIND_LOG"; fi
exec /usr/bin/find "$@"
SH
  chmod +x "$spy/find"
  for mode in dry-run apply; do
    args=(clean)
    [ "$mode" = apply ] && args+=(--apply)
    rm -rf "$world"
    mkdir -p "$world/cache/fresh" "$world/logs" "$world/state" "$world/vol"
    printf 'old\n' > "$world/cache/old.bin"
    printf 'new\n' > "$world/cache/fresh/new.bin"
    touch -t 202501010000 "$world/cache/old.bin"
    : > "$log"
    RC=0
    OUT=$(FM_TEST_SEAM=1 FM_CLEANUP_VOLUME="$world/vol" FM_FAKE_VOLUME="$world/vol" \
      FM_FAKE_DF_AVAIL=209715200 FM_FIND_LOG="$log" \
      FM_CLEANUP_CACHE_ROOTS="$world/cache" FM_CLEANUP_LOG_ROOTS="$world/logs" \
      FM_CLEANUP_WORKTREE_ROOTS="$world/none" FM_CLEANUP_DIR="$world/state" \
      FM_CLEANUP_TARGET_GIB=100 \
      PATH="$spy:$FAKE:$BASE_PATH" bash "$CLEANUP" "${args[@]}" 2>&1) || RC=$?
    [ "$RC" = 0 ] || fail "$mode clean: expected exit 0, got $RC"$'\n'"$OUT"
    count=$(grep -cxF "$world/cache" "$log" || true)
    assert_equals "1" "$count" "$mode clean lists the cache root's entries once"
  done
  assert_contains "$(printf '%s\n' "$OUT" | grep -F "root=$world/cache ")" "old_entries=1 old_kib=" "the apply pass counts the one old entry"
  assert_contains "$(printf '%s\n' "$OUT" | grep -F "root=$world/cache ")" "remaining_old_entries=0" "the apply pass reports it gone without a rescan"
  assert_absent "$world/cache/old.bin" "the old entry is deleted"
  assert_present "$world/cache/fresh/new.bin" "the fresh entry is kept"
  pass "clean walks each root once per run"
}

test_npm_cacache_is_one_entry_under_default_roots() {
  local fresh="$TMP_ROOT/home-fresh" old="$TMP_ROOT/home-old"
  npm_home "$fresh" fresh
  run_default_roots "$fresh" clean --apply
  [ "$RC" = 0 ] || fail "npm fresh index: expected exit 0, got $RC"$'\n'"$OUT"
  assert_present "$fresh/.npm/_cacache/content-v2/sha512/ab/blob" "old npm content survives while its index is fresh"
  assert_present "$fresh/.npm/_cacache/index-v5/cd/entry" "the fresh npm index survives"
  npm_home "$old" old
  run_default_roots "$old" clean --apply
  [ "$RC" = 0 ] || fail "npm fully old: expected exit 0, got $RC"$'\n'"$OUT"
  assert_absent "$old/.npm/_cacache" "a fully old npm cache is removed whole"
  pass "npm's _cacache is judged and removed as one whole entry under the default roots"
}

test_render_launchd_runs_clean_apply_every_six_hours() {
  local plist="$TMP_ROOT/cleanup.plist" home="$TMP_ROOT/launchd-home"
  mkdir -p "$home/vol" "$home/orca/workspaces/proj" "$home/state"
  HOME="$home" FM_CLEANUP_DIR="$home/state" PATH="$FAKE:$BASE_PATH" bash "$CLEANUP" render-launchd > "$plist" \
    || fail "render-launchd failed"
  FM_TEST_SEAM=1 FM_CLEANUP_VOLUME="$home/vol" FM_FAKE_VOLUME="$home/vol" FM_FAKE_DF_AVAIL=209715200 \
    python3 - "$plist" "$CLEANUP" "$home" <<'PY' || fail "rendered cleanup plist must run clean --apply every 6 h, logged"
import os, plistlib, subprocess, sys
with open(sys.argv[1], 'rb') as f:
    p = plistlib.load(f)
home = sys.argv[3]
assert p['Label'].startswith('dev.firstmate.host-cleanup-'), p['Label']
assert p['ProgramArguments'] == ['/bin/bash', sys.argv[2], 'clean', '--apply'], p['ProgramArguments']
assert p['StartInterval'] == 21600 and p['RunAtLoad'] is True, p
assert 'KeepAlive' not in p
log = os.path.join(home, 'state', 'cleanup-run.log')
assert p['StandardOutPath'] == log and p['StandardErrorPath'] == log, p
env = dict(os.environ, **p['EnvironmentVariables'])
assert env['HOME'] == home
out = subprocess.run(p['ProgramArguments'], env=env, cwd='/', capture_output=True, text=True, timeout=60)
assert out.returncode == 0, out
assert 'host-cleanup worktrees: root=%s/orca/workspaces/proj ' % home in out.stdout, out.stdout
PY
  pass "render-launchd emits a 6-hour LaunchAgent whose logged run carries the worktree report"
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
  test_clean_lists_each_root_once \
  test_npm_cacache_is_one_entry_under_default_roots \
  test_render_launchd_runs_clean_apply_every_six_hours \
  test_usage_errors_exit_2
