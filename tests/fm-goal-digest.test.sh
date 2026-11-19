#!/usr/bin/env bash
# Behavioral coverage for bin/fm-goal-digest.sh: new-merge detection,
# the changed flag, missed ETAs, stalls, unreachable sources, the
# changed-only summarizer (and its Opus refusal), and LaunchAgent install.
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

cat > "$FAKE/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_GD_LAUNCH_LOG"
exit 0
SH
chmod +x "$FAKE/launchctl"

cat > "$TMP_ROOT/summarize.sh" <<'SH'
#!/usr/bin/env bash
cat >> "$FM_GD_SUMMARY_MARKER"
printf 'summary\n'
SH
chmod +x "$TMP_ROOT/summarize.sh"

write_fixtures() {  # <include-second-merge:0|1>
  if [ "$1" = 1 ]; then
    cat > "$FIXTURE/merged-example-org_example-repo.json" <<'JSON'
[{"number": 2, "title": "Second", "html_url": "https://example.invalid/pr/2", "merge_commit_sha": "bbbbbbbbbbbbcccc", "merged_at": "2026-01-02T00:00:00Z", "created_at": "2026-01-01T00:00:00Z"},
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
  printf 'eta: 2020-01-01 deliver the thing\nprogress: started\n' > "$home/status.txt"
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

run_digest() {  # <home>
  PATH="$FAKE:$BASE_PATH" FM_TEST_SEAM=1 FM_HOME="$1" FM_GD_FIXTURE="$FIXTURE" \
    FM_GD_SUMMARY_MARKER="$TMP_ROOT/summary-marker" "$SCRIPT" run
}

test_new_merge_changed_and_summarize_only_on_change() {
  write_fixtures 0
  local home out1 out2
  home=$(make_home home1)
  out1=$(run_digest "$home") || fail "first run failed: $out1"
  assert_contains "$out1" "changed=yes" "first run is changed"
  assert_contains "$(cat "$home/data/goal-digest/latest.md")" "https://example.invalid/pr/1" "digest lists new merge URL"
  assert_contains "$(cat "$home/data/goal-digest/latest.md")" "aaaaaaaaaaaa" "digest lists new merge SHA"
  assert_contains "$(cat "$home/data/goal-digest/latest.json")" '"changed": true' "json changed flag"
  [ -f "$TMP_ROOT/summary-marker" ] || fail "summarizer not called on changed run"
  local marker_size
  marker_size=$(wc -c < "$TMP_ROOT/summary-marker")
  out2=$(run_digest "$home") || fail "second run failed: $out2"
  assert_contains "$out2" "changed=no" "unchanged second run"
  [ "$(wc -c < "$TMP_ROOT/summary-marker")" = "$marker_size" ] || fail "summarizer called on unchanged run"
  write_fixtures 1
  local out3
  out3=$(run_digest "$home") || fail "third run failed: $out3"
  assert_contains "$out3" "changed=yes" "new merge marks changed"
  assert_contains "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print([m["number"] for m in d["new_merges"]])' "$home/data/goal-digest/latest.json")" "[2]" "only the unseen merge is new"
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
  assert_contains "$(cat "$json")" '"source": "Example status"' "stalled source recorded"
  assert_contains "$(cat "$json")" "Missing status" "unreachable status recorded"
  assert_contains "$(cat "$json")" "T1 in progress" "review convergence last line recorded"
  assert_contains "$(cat "$json")" "Waiting work" "open pull request waiting recorded"
  pass "missed ETA, stall, unreachable source and review record"
}

test_opus_summarizer_refused() {
  write_fixtures 0
  local home out
  home=$(make_home home3 "opus-model summarize")
  out=$(run_digest "$home" 2>&1) || fail "opus-refusal run failed: $out"
  assert_contains "$out" "changed=yes" "digest still produced when summarizer refused"
  [ ! -f "$home/data/goal-digest/summary.txt" ] || fail "opus summarizer produced a summary"
  pass "opus summarizer refused, digest still written"
}

test_install_launchagent() {
  local home
  home=$(make_home home4)
  mkdir -p "$home/fake-home"
  FM_GD_LAUNCH_LOG="$TMP_ROOT/launch.log" PATH="$FAKE:$BASE_PATH" FM_TEST_SEAM=1 \
    FM_HOME="$home" HOME="$home/fake-home" "$SCRIPT" install >/dev/null || fail "install failed"
  local plist="$home/fake-home/Library/LaunchAgents/dev.firstmate.goal-digest.plist"
  [ -f "$plist" ] || fail "plist not installed"
  assert_contains "$(cat "$plist")" "<integer>1200</integer>" "plist uses 20 minute interval"
  assert_contains "$(cat "$plist")" "fm-goal-digest.sh" "plist runs the digest script"
  FM_GD_LAUNCH_LOG="$TMP_ROOT/launch.log" PATH="$FAKE:$BASE_PATH" FM_TEST_SEAM=1 \
    FM_HOME="$home" HOME="$home/fake-home" "$SCRIPT" uninstall >/dev/null || fail "uninstall failed"
  [ ! -f "$plist" ] || fail "plist not removed by uninstall"
  pass "launchagent install and uninstall"
}

fm_test_run test_new_merge_changed_and_summarize_only_on_change test_missed_eta_stall_and_unreachable test_opus_summarizer_refused test_install_launchagent
