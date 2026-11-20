#!/usr/bin/env bash
# Behavioral coverage for bin/fm-goal-digest.sh: new-merge detection,
# the changed flag, missed ETAs, stalls, unreachable sources, the
# changed-only summarizer, and the LaunchAgent install and its scheduled run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-goal-digest)
SCRIPT="$ROOT/bin/fm-goal-digest.sh"
FAKE=$(fm_fakebin "$TMP_ROOT")
FIXTURE="$TMP_ROOT/fixture"
mkdir -p "$FIXTURE"

cat > "$FAKE/gh" <<'SH'
#!/usr/bin/env bash
endpoint=${2:-}
repo=${endpoint#repos/}
repo=${repo%%/pulls*}
safe=$(printf '%s' "$repo" | tr '/ ' '__')
case "$endpoint" in
  *state=closed*) cat "$FM_GD_FIXTURE/merged-$safe.json" ;;
  *state=open*) cat "$FM_GD_FIXTURE/open-$safe.json" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKE/gh"

cat > "$FAKE/date" <<'SH'
#!/usr/bin/env bash
if [ "$*" = "+%s" ] && [ -n "${FM_GD_NOW_EPOCH:-}" ]; then
  printf '%s\n' "$FM_GD_NOW_EPOCH"
  exit 0
fi
exec /bin/date "$@"
SH
chmod +x "$FAKE/date"

cat > "$FAKE/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_GD_LAUNCH_LOG"
[ -n "${FM_GD_LAUNCH_FAIL:-}" ] && exit 1
exit 0
SH
chmod +x "$FAKE/launchctl"

cat > "$FAKE/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_GD_SSH_LOG"
printf 'ssh progress line\n'
exit 0
SH
chmod +x "$FAKE/ssh"

cat > "$TMP_ROOT/summarize.sh" <<'SH'
#!/usr/bin/env bash
cat >> "$FM_GD_SUMMARY_MARKER"
printf 'summary\n'
SH
chmod +x "$TMP_ROOT/summarize.sh"

# 2026-01-01T12:00:00Z and the following hours, independent of the host clock.
RUN1_EPOCH=1767268800
RUN2_EPOCH=1767272400
RUN3_EPOCH=1767276000

write_fixtures() {  # <include-second-merge:0|1>
  if [ "$1" = 1 ]; then
    cat > "$FIXTURE/merged-example-org_example-repo.json" <<'JSON'
[{"number": 2, "title": "Second", "html_url": "https://example.invalid/pr/2", "merge_commit_sha": "bbbbbbbbbbbbcccc", "merged_at": "2026-01-02T00:00:00Z", "created_at": "2026-01-01T00:00:00Z"},
 {"number": 9, "title": "Old merge, newly updated", "html_url": "https://example.invalid/pr/9", "merge_commit_sha": "999999999999dddd", "merged_at": "2025-06-01T00:00:00Z", "created_at": "2025-05-01T00:00:00Z"},
 {"number": 1, "title": "First", "html_url": "https://example.invalid/pr/1", "merge_commit_sha": "aaaaaaaaaaaa1111", "merged_at": "2026-01-01T00:00:00Z", "created_at": "2025-12-31T00:00:00Z"}]
JSON
  else
    cat > "$FIXTURE/merged-example-org_example-repo.json" <<'JSON'
[{"number": 1, "title": "First", "html_url": "https://example.invalid/pr/1", "merge_commit_sha": "aaaaaaaaaaaa1111", "merged_at": "2026-01-01T00:00:00Z", "created_at": "2025-12-31T00:00:00Z"}]
JSON
  fi
  cat > "$FIXTURE/open-example-org_example-repo.json" <<'JSON'
[{"number": 7, "title": "Waiting work", "html_url": "https://example.invalid/pr/7", "created_at": "2026-01-01T00:00:00Z", "user": {"login": "contributor"}, "draft": false}]
JSON
}

make_home() {  # <name> [summarize_cmd]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/data"
  printf 'eta: 2020-01-01 deliver the thing\nprogress: started\nbeta 2020-03-01 release\nshipped 2020-01-05 (eta: 2099-12-01)\n' > "$home/status.txt"
  touch -t 202001010000 "$home/status.txt"
  printf 'working [at=1]: T1 in progress\n' > "$home/review.status"
  {
    printf 'repo = example-org/example-repo\n'
    printf 'status = Example status | %s\n' "$home/status.txt"
    printf 'status = Missing status | %s\n' "$home/no-such-status.txt"
    printf 'review = Example review | %s\n' "$home/review.status"
    printf 'summarize_cmd = %s\n' "${2:-$TMP_ROOT/summarize.sh}"
  } > "$home/config/goal-digest"
  printf '%s' "$home"
}

run_digest() {  # <home> [now-epoch]
  PATH="$FAKE:$BASE_PATH" FM_TEST_SEAM=1 FM_HOME="$1" FM_GD_FIXTURE="$FIXTURE" \
    FM_GD_NOW_EPOCH="${2:-}" FM_GD_SUMMARY_MARKER="$TMP_ROOT/summary-marker" "$SCRIPT" run
}

test_new_merge_changed_and_summarize_only_on_change() {
  write_fixtures 0
  local home out1 out2
  home=$(make_home home1)
  out1=$(run_digest "$home" "$RUN1_EPOCH") || fail "first run failed: $out1"
  assert_contains "$out1" "changed=yes" "first run is changed"
  assert_contains "$(cat "$home/data/goal-digest/latest.md")" "https://example.invalid/pr/1" "digest lists new merge URL"
  assert_contains "$(cat "$home/data/goal-digest/latest.md")" "aaaaaaaaaaaa" "digest lists new merge SHA"
  assert_contains "$(cat "$home/data/goal-digest/latest.json")" '"changed": true' "json changed flag"
  [ -f "$TMP_ROOT/summary-marker" ] || fail "summarizer not called on changed run"
  local marker_size
  marker_size=$(wc -c < "$TMP_ROOT/summary-marker")
  out2=$(run_digest "$home" "$RUN2_EPOCH") || fail "second run failed: $out2"
  assert_contains "$out2" "changed=no" "second run an hour later with only ages grown is unchanged"
  [ "$(wc -c < "$TMP_ROOT/summary-marker")" = "$marker_size" ] || fail "summarizer called on unchanged run"
  write_fixtures 1
  local out3
  out3=$(run_digest "$home" "$RUN3_EPOCH") || fail "third run failed: $out3"
  assert_contains "$out3" "changed=yes" "new merge marks changed"
  assert_contains "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print([m["number"] for m in d["new_merges"]])' "$home/data/goal-digest/latest.json")" "[2]" "only the merge after the previous run is new, not an old merge newly in the window"
  [ -n "$(ls "$home/data/goal-digest/history/"*.md 2>/dev/null)" ] || fail "history copy missing"
  pass "new merge detection, changed flag and changed-only summarizer"
}

test_missed_eta_stall_and_unreachable() {
  write_fixtures 0
  local home
  home=$(make_home home2)
  run_digest "$home" >/dev/null || fail "run with unreachable source failed"
  local json="$home/data/goal-digest/latest.json"
  assert_contains "$(cat "$json")" '"eta": "2020-01-01"' "missed ETA recorded"
  assert_equals "['2020-01-01']" "$(python3 -c 'import json,sys; print(sorted(m["eta"] for m in json.load(open(sys.argv[1]))["missed_etas"]))' "$json")" "beta date and a date before the eta are not missed ETAs"
  assert_contains "$(cat "$json")" '"source": "Example status"' "stalled source recorded"
  assert_contains "$(cat "$json")" "Missing status" "unreachable status recorded"
  assert_contains "$(cat "$json")" "T1 in progress" "review convergence last line recorded"
  assert_contains "$(cat "$json")" "Waiting work" "open pull request waiting recorded"
  pass "missed ETA, stall, unreachable source and review record"
}

test_missing_config_uses_default_output_dir() {
  local home="$TMP_ROOT/home-noconfig" out
  mkdir -p "$home"
  out=$(run_digest "$home") || fail "run without config failed: $out"
  assert_contains "$out" "latest=$home/data/goal-digest/latest.md" "run without config reports the default digest path"
  [ -f "$home/data/goal-digest/latest.json" ] || fail "run without config did not write the default digest"
  pass "missing config writes an empty digest in the default directory"
}

test_install_launchagent() {
  write_fixtures 0
  local home other
  home=$(make_home home4)
  other=$(make_home home5)
  mkdir -p "$home/fake-home"
  FM_GD_LAUNCH_LOG="$TMP_ROOT/launch.log" PATH="$FAKE:$BASE_PATH" FM_TEST_SEAM=1 \
    FM_HOME="$home" HOME="$home/fake-home" "$SCRIPT" install >/dev/null || fail "install failed"
  FM_GD_LAUNCH_LOG="$TMP_ROOT/launch.log" PATH="$FAKE:$BASE_PATH" FM_TEST_SEAM=1 \
    FM_HOME="$other" HOME="$home/fake-home" "$SCRIPT" install >/dev/null || fail "second home install failed"
  local plists plist
  plists=$(ls "$home/fake-home/Library/LaunchAgents/"dev.firstmate.goal-digest*.plist 2>/dev/null)
  assert_equals "2" "$(printf '%s\n' "$plists" | grep -c .)" "two homes install two separate agents"
  plist=$(printf '%s\n' "$plists" | while IFS= read -r f; do grep -l "<string>$home</string>" "$f"; done | head -1)
  [ -f "$plist" ] || fail "plist for first home not installed"
  local agent
  agent=$(python3 -c '
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
env = d["EnvironmentVariables"]
print(d["StartInterval"])
print(env["FM_HOME"])
print(env["HOME"])
print(env["PATH"])
print("\0".join(d["ProgramArguments"]))
' "$plist") || fail "plist does not parse"
  assert_equals "1200" "$(printf '%s\n' "$agent" | sed -n 1p)" "plist uses 20 minute interval"
  assert_equals "$(cd "$home" && pwd -P)" "$(printf '%s\n' "$agent" | sed -n 2p)" "agent runs with the installing home"
  assert_equals "$home/fake-home" "$(printf '%s\n' "$agent" | sed -n 3p)" "agent runs with the installer HOME"
  local agent_path
  agent_path=$(printf '%s\n' "$agent" | sed -n 4p)
  # Run the agent's program the way launchd does: only its declared environment.
  env -i FM_HOME="$(printf '%s\n' "$agent" | sed -n 2p)" HOME="$home/fake-home" PATH="$agent_path" \
    FM_GD_FIXTURE="$FIXTURE" FM_GD_SUMMARY_MARKER="$TMP_ROOT/summary-marker" \
    "$SCRIPT" run >/dev/null || fail "scheduled run failed"
  assert_contains "$(cat "$home/data/goal-digest/latest.md")" "https://example.invalid/pr/1" "scheduled run finds gh and writes into the installing home"
  FM_GD_LAUNCH_LOG="$TMP_ROOT/launch.log" PATH="$FAKE:$BASE_PATH" FM_TEST_SEAM=1 \
    FM_HOME="$home" HOME="$home/fake-home" "$SCRIPT" uninstall >/dev/null || fail "uninstall failed"
  [ ! -f "$plist" ] || fail "plist not removed by uninstall"
  pass "launchagent install and uninstall"
}

test_ssh_quoting_lock_and_install_failure() {
  write_fixtures 0
  local home
  home=$(make_home home6)
  printf 'review = Quoted review | ssh:example-host:/tmp/it'"'"'s status.txt\n' >> "$home/config/goal-digest"
  FM_GD_SSH_LOG="$TMP_ROOT/ssh.log" run_digest "$home" >/dev/null || fail "run with quoted ssh path failed"
  assert_contains "$(cat "$TMP_ROOT/ssh.log")" "it'\\''s status.txt" "ssh path is shell-quoted"
  assert_contains "$(cat "$home/data/goal-digest/latest.json")" "ssh progress line" "ssh source content recorded"
  mkdir -p "$home/data/goal-digest/.state/run.lock"
  local rc=0
  run_digest "$home" >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "concurrent run was not refused by the lock"
  rmdir "$home/data/goal-digest/.state/run.lock"
  rc=0
  FM_GD_LAUNCH_FAIL=1 FM_GD_LAUNCH_LOG="$TMP_ROOT/launch.log" PATH="$FAKE:$BASE_PATH" FM_TEST_SEAM=1 \
    FM_HOME="$home" HOME="$home/fake-home" "$SCRIPT" install >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "failed launchctl bootstrap reported install success"
  pass "ssh quoting, concurrent-run lock and install failure"
}

fm_test_run test_new_merge_changed_and_summarize_only_on_change test_missed_eta_stall_and_unreachable test_missing_config_uses_default_output_dir test_install_launchagent test_ssh_quoting_lock_and_install_failure
