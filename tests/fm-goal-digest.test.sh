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
if [ -n "${FM_GD_PAGE_FAIL:-}" ]; then
  page_no=${endpoint##*page=}
  [ "$page_no" != 1 ] && exit 1
fi
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
if [ -n "${FM_GD_NOW_EPOCH:-}" ]; then
  python3 - "$@" <<'PYDATE'
import datetime, os, sys
from zoneinfo import ZoneInfo
zone = datetime.timezone.utc if "-u" in sys.argv else ZoneInfo(os.environ.get("TZ", "UTC"))
fmt = next(a[1:] for a in sys.argv[1:] if a.startswith("+"))
print(datetime.datetime.fromtimestamp(int(os.environ["FM_GD_NOW_EPOCH"]), zone).strftime(fmt))
PYDATE
  exit $?
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

make_home() {  # <name> [claude-stub]
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
  } > "$home/config/goal-digest"
  printf '%s' "${2:-$TMP_ROOT/summarize.sh}" > "$home/.claude-stub"
  printf '%s' "$home"
}

run_digest() {  # <home> [now-epoch]
  local stub
  stub=$(cat "$1/.claude-stub" 2>/dev/null || printf '%s' "$TMP_ROOT/summarize.sh")
  PATH="$FAKE:$BASE_PATH" FM_TEST_SEAM=1 FM_HOME="$1" FM_GD_FIXTURE="$FIXTURE" \
    FM_GOAL_DIGEST_CLAUDE="$stub" \
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
  assert_contains "$(cat "$json")" "T1 in progress" "review convergence entry recorded"
  assert_contains "$(cat "$json")" "Waiting work" "open pull request recorded"
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
  printf 'interval_seconds = 1\n' >> "$home/config/goal-digest"
  mkdir -p "$home/fake-home"
  local installed
  installed=$(FM_GD_LAUNCH_LOG="$TMP_ROOT/launch.log" PATH="$FAKE:$BASE_PATH" FM_TEST_SEAM=1 \
    FM_HOME="$home" HOME="$home/fake-home" "$SCRIPT" install) || fail "install failed"
  assert_contains "$installed" "interval_seconds=1200" "install reports the required fixed cadence"
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
    FM_GD_FIXTURE="$FIXTURE" FM_GD_NOW_EPOCH="$RUN1_EPOCH" FM_GD_SUMMARY_MARKER="$TMP_ROOT/summary-marker" \
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
  local lock=$home/data/goal-digest/.state/run.flock ready=$TMP_ROOT/lock-held holder
  python3 -c 'import fcntl, sys, time
f = open(sys.argv[1], "a")
fcntl.flock(f, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(300)' "$lock" "$ready" &
  holder=$!
  local i=0
  while [ ! -f "$ready" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -f "$ready" ] || fail "lock holder never acquired the run lock"
  local rc=0
  run_digest "$home" >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "concurrent run was not refused by the lock"
  kill -9 "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  run_digest "$home" >/dev/null 2>&1 || fail "run lock held by a killed run was not released"
  rc=0
  FM_GD_LAUNCH_FAIL=1 FM_GD_LAUNCH_LOG="$TMP_ROOT/launch.log" PATH="$FAKE:$BASE_PATH" FM_TEST_SEAM=1 \
    FM_HOME="$home" HOME="$home/fake-home" "$SCRIPT" install >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "failed launchctl bootstrap reported install success"
  pass "ssh quoting, concurrent-run lock, crashed-run lock release and install failure"
}

test_lingering_summarizer_helper_does_not_hold_lock() {
  write_fixtures 0
  cat > "$TMP_ROOT/linger-summarize.sh" <<SH
#!/usr/bin/env bash
cat >/dev/null
sh -c 'sleep 120' "$TMP_ROOT/linger-helper" </dev/null >/dev/null 2>&1 &
SH
  chmod +x "$TMP_ROOT/linger-summarize.sh"
  local home
  home=$(make_home home7 "$TMP_ROOT/linger-summarize.sh")
  run_digest "$home" >/dev/null || fail "first run with lingering summarizer failed"
  run_digest "$home" >/dev/null 2>&1 || fail "background helper left by summarize_cmd kept the run lock held"
  pkill -f "$TMP_ROOT/linger-helper" 2>/dev/null || true
  pass "summarizer background helper does not hold the run lock"
}

test_first_run_seeds_old_merges_and_page_failure_is_incomplete() {
  local home
  home=$(make_home home8)
  cat > "$FIXTURE/merged-example-org_example-repo.json" <<'JSON'
[{"number": 1, "title": "Ancient", "html_url": "https://example.invalid/pr/1", "merge_commit_sha": "aaaaaaaaaaaa1111", "merged_at": "2020-01-01T00:00:00Z", "created_at": "2019-12-31T00:00:00Z"}]
JSON
  cat > "$FIXTURE/open-example-org_example-repo.json" <<'JSON'
[]
JSON
  run_digest "$home" "$RUN1_EPOCH" >/dev/null || fail "first-run seed run failed"
  assert_equals "[]" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["new_merges"])' "$home/data/goal-digest/latest.json")" "first run does not flood old merges"
  python3 - "$FIXTURE/merged-example-org_example-repo.json" <<'PY'
import json, sys
pulls = [{"number": i, "title": f"P{i}", "html_url": f"https://example.invalid/pr/{i}", "merge_commit_sha": "aaaaaaaaaaaa1111", "merged_at": "2026-01-01T00:00:00Z", "created_at": "2025-12-31T00:00:00Z", "updated_at": "2026-01-01T11:59:00Z"} for i in range(1, 101)]
with open(sys.argv[1], "w") as fh:
    json.dump(pulls, fh)
PY
  FM_GD_PAGE_FAIL=1 run_digest "$home" "$RUN2_EPOCH" >/dev/null || fail "page-failure run failed"
  assert_contains "$(cat "$home/data/goal-digest/latest.json")" "gh api failed or incomplete" "later page failure recorded as incomplete"
  pass "first-run seeding and later-page failure"
}

test_first_run_large_repo_stops_and_saves_watermark() {
  local home
  home=$(make_home home9)
  python3 - "$FIXTURE/merged-example-org_example-repo.json" <<'PY'
import json, sys
pulls = [{"number": i, "title": f"P{i}", "html_url": f"https://example.invalid/pr/{i}", "merge_commit_sha": "aaaaaaaaaaaa1111", "merged_at": "2020-01-01T00:00:00Z", "created_at": "2019-12-31T00:00:00Z", "updated_at": "2020-01-01T00:00:00Z"} for i in range(1, 101)]
with open(sys.argv[1], "w") as fh:
    json.dump(pulls, fh)
PY
  cat > "$FIXTURE/open-example-org_example-repo.json" <<'JSON'
[]
JSON
  FM_GD_PAGE_FAIL=1 run_digest "$home" "$RUN1_EPOCH" >/dev/null || fail "large first run failed"
  assert_equals "[]" "$(python3 -c 'import json,sys; print([u for u in json.load(open(sys.argv[1]))["unreachable_sources"] if u["kind"] == "repo"])' "$home/data/goal-digest/latest.json")" "first run stops at the initial watermark before the failing second page"
  [ -s "$home/data/goal-digest/.state/since.tsv" ] || fail "first run did not save a fetch watermark"
  FM_GD_PAGE_FAIL=1 run_digest "$home" "$RUN2_EPOCH" >/dev/null || fail "large second run failed"
  assert_equals "[]" "$(python3 -c 'import json,sys; print([u for u in json.load(open(sys.argv[1]))["unreachable_sources"] if u["kind"] == "repo"])' "$home/data/goal-digest/latest.json")" "second run stops at the saved watermark before the failing second page"
  pass "first-run large repository stops and saves watermark"
}

test_complete_collection_recovers_unreported_merge_window() {
  PATH="$FAKE:$BASE_PATH" python3 - "$SCRIPT" "$TMP_ROOT/pending-merges" "$RUN1_EPOCH" <<'PYTEST' || fail "collection omitted an unreported merge"
import datetime, json, os, pathlib, subprocess, sys
script, root, initial = sys.argv[1], pathlib.Path(sys.argv[2]), int(sys.argv[3])
outage = initial + 172800
retry_time = outage + 172800
def stamp(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
for scenario in ("resumed", "bootstrap", "bootstrap-failed"):
    home = root / scenario
    (home / "config").mkdir(parents=True)
    (home / "config/goal-digest").write_text("repo = example-org/example-repo\n")
    fixture = home / "pulls.json"
    fixture.write_text("[]")
    open_fixture = home / "open.json"
    open_fixture.write_text("[]")
    requests = home / "requests.jsonl"
    gh = home / "gh"
    gh.write_text("#!" + sys.executable + "\n" + '''import json, pathlib, sys
from urllib.parse import parse_qs, urlsplit
home = pathlib.Path(__file__).parent
query = parse_qs(urlsplit(sys.argv[2]).query)
page = int(query["page"][0])
state = query["state"][0]
with (home / "requests.jsonl").open("a") as fh:
    fh.write(json.dumps([state, page]) + "\\n")
if state == "closed" and page == 2 and (home / "fail").exists():
    sys.exit(1)
rows = json.loads((home / ("pulls.json" if state == "closed" else "open.json")).read_text())
print(json.dumps(rows[(page - 1) * 100:page * 100]))
''')
    gh.chmod(0o755)
    env = dict(os.environ, FM_HOME=str(home), FM_TEST_SEAM="1", FM_GOAL_DIGEST_GH=str(gh))
    output = home / "data/goal-digest"
    def run(now):
        env["FM_GD_NOW_EPOCH"] = str(now)
        requests.write_text("")
        result = subprocess.run([script, "run"], env=env, text=True, capture_output=True, timeout=60)
        assert result.returncode == 0, result.stderr
        return json.loads((output / "latest.json").read_text())
    if scenario == "resumed":
        run(initial)
        baseline = (output / ".state/since.tsv").read_bytes()
    else:
        baseline = f"example-org/example-repo\t{outage - 86400}\n".encode()
    rows = [{"number": i, "updated_at": stamp(outage - 60 - i), "merged_at": None} for i in range(1, 1001)]
    rows[0].update(merged_at=stamp(outage - 3600), merge_commit_sha="aaaaaaaaaaaa1111", html_url="https://example.invalid/pr/1")
    late = {"number": 1001, "updated_at": stamp(outage - 7200), "merged_at": stamp(outage - 43200),
            "merge_commit_sha": "bbbbbbbbbbbb2222", "html_url": "https://example.invalid/pr/1001"}
    rows.append(late)
    fixture.write_text(json.dumps(rows))
    if scenario == "resumed":
        open_fixture.write_text(json.dumps([
            {"number": i, "created_at": stamp(initial), "html_url": f"https://example.invalid/pr/{i}"}
            for i in range(1, 1002)
        ]))
    if scenario == "bootstrap-failed":
        (home / "fail").touch()
        incomplete = run(outage)
        assert any(u["kind"] == "repo" for u in incomplete["unreachable_sources"]), incomplete
        assert incomplete["new_merges"] == []
        assert (output / ".state/since.tsv").read_bytes() == baseline, scenario
        pages = [page for state, page in map(json.loads, requests.read_text().splitlines()) if state == "closed"]
        assert pages == [1, 2], pages
        (home / "fail").unlink()
        assert (output / ".state/seen.tsv").read_text() == ""
    collected_at = retry_time if scenario == "bootstrap-failed" else outage
    recovered = run(collected_at)
    assert {m["number"] for m in recovered["new_merges"]} == {1, 1001}, recovered
    merge = next(m for m in recovered["new_merges"] if m["number"] == 1001)
    assert merge["url"] == "https://example.invalid/pr/1001", merge
    assert merge["sha"] == "bbbbbbbbbbbb", merge
    merge_section = (output / "latest.md").read_text().split("## Open pull requests")[0]
    assert "https://example.invalid/pr/1001" in merge_section and "`bbbbbbbbbbbb`" in merge_section
    assert not any(u["kind"].startswith("repo") for u in recovered["unreachable_sources"])
    pages = [page for state, page in map(json.loads, requests.read_text().splitlines()) if state == "closed"]
    assert pages == list(range(1, 12)), pages
    assert (output / ".state/since.tsv").read_text() == f"example-org/example-repo\t{collected_at - 300}\n"
    if scenario == "resumed":
        assert [p["number"] for p in recovered["open_pull_requests"]] == list(range(1, 1002))
        assert "https://example.invalid/pr/1001" in (output / "latest.md").read_text().split("## Open pull requests")[1]
    assert run(collected_at + 1200)["new_merges"] == []
PYTEST
  pass "complete pagination reports unchanged page-11 merges after outages and bootstrap failures"
}


test_owner_actions_are_explicit_and_age_from_wait_start() {
  write_fixtures 0
  local home
  home=$(make_home owner-actions)
  cat > "$home/status.txt" <<'JSON'
{"schema":"fm-fleet-snapshot.v1","generated_at":"2026-01-01T12:00:00Z","backlog":{"present":true,"records":[
 {"id":"decision-a","title":"Choose route","captain_actionable":true,"hold_set":"2026-01-01T10:00:00Z"},
 {"id":"decision-b","title":"Choose access","captain_actionable":true},
 {"id":"decision-c","title":"Choose date","captain_actionable":true,"hold_set":"2025-12-30","hold_age_days":2},
 {"id":"done","title":"Answered","captain_actionable":false,"hold_set":"2020-01-01T00:00:00Z"}
]},"secondmate_current":{"registry":{"available":true,"complete":true},"records":[],"truncated":0}}
JSON
  cat > "$home/review.status" <<EOF
needs-decision [key=closed] [at=$((RUN1_EPOCH - 10800))]: old question
resolved [key=closed]: answered
needs-decision [key=live] [at=$((RUN1_EPOCH - 3600))]: choose format
working: unrelated progress
blocked [key=network]: network unavailable
needs-decision [key=later] [until=2099-01-01]: revisit later
EOF
  run_digest "$home" "$RUN1_EPOCH" >/dev/null || fail "owner-action run failed"
  python3 - "$home/data/goal-digest/latest.json" <<'PYCHECK' || fail "owner-action semantics incorrect"
import json, sys
value = json.load(open(sys.argv[1]))
waits = {w["id"]: w for w in value["waiting_on_captain"]}
assert set(waits) == {"decision-a", "decision-b", "decision-c"}, waits
assert waits["decision-a"]["age_hours"] == 2
assert waits["decision-b"]["age_hours"] is None
assert waits["decision-c"]["age_hours"] is None and waits["decision-c"]["age_days"] == 2 and waits["decision-c"]["age_precision"] == "day", waits["decision-c"]
assert [p["number"] for p in value["open_pull_requests"]] == [7]
assert value["waiting_on_captain_status"] == "unknown"
assert value["waiting_on_captain_unknown_sources"] == [{"source":"Missing status", "detail":"source unreachable"}]
PYCHECK
  assert_contains "$(cat "$home/data/goal-digest/latest.md")" "age_hours=unknown" "unknown wait age is explicit"
  local out
  out=$(run_digest "$home" "$RUN2_EPOCH") || fail "owner age-only run failed"
  assert_contains "$out" "changed=no" "owner wait ages alone do not retrigger summarization"
  out=$(run_digest "$home" 1767315600) || fail "owner UTC rollover run failed"
  assert_contains "$out" "changed=no" "UTC rollover alone does not retrigger summarization"
  assert_equals "2" "$(python3 -c 'import json,sys; print(next(w["age_days"] for w in json.load(open(sys.argv[1]))["waiting_on_captain"] if w["id"] == "decision-c"))' "$home/data/goal-digest/latest.json")" "day age follows the CST calendar before midnight"
  out=$(run_digest "$home" 1767355200) || fail "owner next-day run failed"
  assert_contains "$out" "changed=no" "day age alone does not retrigger summarization"
  assert_equals "3" "$(python3 -c 'import json,sys; print(next(w["age_days"] for w in json.load(open(sys.argv[1]))["waiting_on_captain"] if w["id"] == "decision-c"))' "$home/data/goal-digest/latest.json")" "unchanged snapshot hold ages advance on the next CST date"
  assert_contains "$(cat "$home/data/goal-digest/latest.md")" "Choose date age_days=3 (day precision)" "Markdown publishes the current day age"
  python3 - "$home/status.txt" <<'PYUPDATE'
import json, sys
value = json.load(open(sys.argv[1]))
value["backlog"]["records"][0]["captain_actionable"] = False
json.dump(value, open(sys.argv[1], "w"))
PYUPDATE
  run_digest "$home" "$RUN3_EPOCH" >/dev/null || fail "resolution run failed"
  assert_equals "['decision-b', 'decision-c']" "$(python3 -c 'import json,sys; print([w["id"] for w in json.load(open(sys.argv[1]))["waiting_on_captain"]])' "$home/data/goal-digest/latest.json")" "resolved owner action leaves waiting set"
  pass "explicit owner actions, actual wait age, resolutions and unknown sources"
}

test_secondmate_owner_actions_and_coverage() {
  local home="$TMP_ROOT/secondmate-actions"
  mkdir -p "$home/config"
  printf 'status = Fleet | %s/status.json\n' "$home" > "$home/config/goal-digest"
  python3 - "$SCRIPT" "$home" "$FAKE:$BASE_PATH" "$RUN1_EPOCH" <<'PYTEST' || fail "native secondmate owner-action contract failed"
import copy, json, os, pathlib, subprocess, sys
script, home, path, now = sys.argv[1:]
home = pathlib.Path(home)
env = dict(os.environ, FM_HOME=str(home), PATH=path, FM_GD_NOW_EPOCH=now, FM_TEST_SEAM="1")
mate = {
    "id":"mate-a", "registered":True,
    "provenance":{"selected":"structured-home", "trust":"complete", "summary_valid":True, "summary_source":"remote-ledger"},
    "current":{"state":"captain_decision"},
    "freshness":{"status":"fresh", "observed_at":"2026-01-01T12:00:00Z", "age_seconds":0},
    "decisions_open":[
        {"id":"route", "key":"route", "verb":"captain-hold", "summary":"Choose route", "question":"Choose route: north or south?", "hold_age_days":30},
        {"id":"worker", "key":"worker", "verb":"needs-decision", "summary":"Worker question"}
    ],
    "counts":{"decisions_open":2}, "omitted":[]
}
other = copy.deepcopy(mate)
other["id"] = "mate-b"
unregistered = copy.deepcopy(mate)
unregistered.update(id="unregistered", registered=False)
snapshot = {
    "schema":"fm-fleet-snapshot.v1", "backlog":{"present":True, "records":[]},
    "secondmate_current":{
        "registry":{"available":True,"complete":True,"records":[{"id":"mate-a"},{"id":"mate-b"}]},
        "records":[mate, other, unregistered], "total":3, "shown":3, "truncated":0
    }
}
def run(value):
    (home / "status.json").write_text(json.dumps(value))
    result = subprocess.run([script, "run"], env=env, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    return json.loads((home / "data/goal-digest/latest.json").read_text())
def check(digest, known, sources):
    assert digest["waiting_on_captain_status"] == ("known" if known else "unknown"), digest
    waits = digest["waiting_on_captain"]
    assert {(w["source"], w["id"]) for w in waits} == {(s,"route") for s in sources}, waits
    assert all(w["age_hours"] is None and w["wait_started_at"] is None for w in waits), waits
    assert bool(digest["waiting_on_captain_unknown_sources"]) != known, digest
first = run(snapshot)
check(first, True, {"Fleet/mate-a","Fleet/mate-b"})
assert all(w["title"] == "Choose route: north or south?" for w in first["waiting_on_captain"])
assert "Choose route: north or south? age_hours=unknown" in (home / "data/goal-digest/latest.md").read_text()
env["FM_GD_NOW_EPOCH"] = str(int(now) + 3600)
snapshot["secondmate_current"]["records"][0]["decisions_open"][0]["hold_age_days"] = 31
snapshot["secondmate_current"]["records"][0]["freshness"]["age_seconds"] = 3600
assert run(snapshot)["changed"] is False
snapshot["secondmate_current"]["records"][0]["decisions_open"][0]["question"] = "Choose route: east or west?"
assert run(snapshot)["changed"] is True
for marker in ("freshness", "provenance", "both"):
    value = copy.deepcopy(snapshot)
    row = value["secondmate_current"]["records"][0]
    if marker in ("freshness", "both"):
        row["freshness"]["status"] = "cached"
    if marker in ("provenance", "both"):
        row["provenance"]["summary_source"] = "remote-ledger-cache"
    cached = run(value)
    check(cached, False, {"Fleet/mate-a","Fleet/mate-b"})
    assert cached["changed"] is True, marker
    assert cached["waiting_on_captain_unknown_sources"] == [{"source":"Fleet/mate-a", "detail":"secondmate decisions from cached ledger"}], cached
    assert "- Unknown: Fleet/mate-a: secondmate decisions from cached ledger" in (home / "data/goal-digest/latest.md").read_text()
    if marker == "both":
        row["freshness"]["age_seconds"] += 1200
        env["FM_GD_NOW_EPOCH"] = str(int(env["FM_GD_NOW_EPOCH"]) + 1200)
        unchanged = run(value)
        check(unchanged, False, {"Fleet/mate-a","Fleet/mate-b"})
        assert unchanged["changed"] is False
    recovered = run(snapshot)
    check(recovered, True, {"Fleet/mate-a","Fleet/mate-b"})
    assert recovered["changed"] is True, marker
for case in ("registry-unavailable", "registry-incomplete", "parent-truncated", "unavailable", "partial", "decision-count", "decision-omitted", "missing-parent", "missing-local"):
    value = copy.deepcopy(snapshot)
    current = value["secondmate_current"]
    row = current["records"][0]
    expected = {"Fleet/mate-a","Fleet/mate-b"}
    if case == "registry-unavailable":
        current["registry"].update(available=False, complete=False)
    elif case == "registry-incomplete":
        current["registry"].update(complete=False, input_truncated=True)
    elif case == "parent-truncated":
        current["truncated"] = 1
    elif case == "unavailable":
        row["provenance"] = {"selected":"parent-event-fallback"}
        row["parent_event"] = {"open_decisions":row["decisions_open"]}
        row["decisions_open"] = []
        expected = {"Fleet/mate-b"}
    elif case == "partial":
        row["provenance"].update(trust="partial-structured", summary_valid=False)
        row["current"]["state"] = "unknown"
    elif case == "decision-count":
        row["counts"]["decisions_open"] = 3
    elif case == "decision-omitted":
        row["omitted"] = [{"surface":"decisions_open", "count":1}]
    elif case == "missing-parent":
        del value["secondmate_current"]
        expected = set()
    elif case == "missing-local":
        value["backlog"]["present"] = False
    digest = run(value)
    check(digest, False, expected)
    assert "- Unknown:" in (home / "data/goal-digest/latest.md").read_text(), case
dated = copy.deepcopy(snapshot)
for row in dated["secondmate_current"]["records"]:
    row["decisions_open"][0].update(hold_set="2025-12-30", hold_age_days=2)
env["FM_GD_NOW_EPOCH"] = now
first_day = run(dated)
assert all(w["age_days"] == 2 and w["age_hours"] is None and w["age_precision"] == "day" for w in first_day["waiting_on_captain"])
env["FM_GD_NOW_EPOCH"] = "1767355200"
next_day = run(dated)
assert {(w["source"], w["age_days"]) for w in next_day["waiting_on_captain"]} == {("Fleet/mate-a", 3), ("Fleet/mate-b", 3)}, next_day
assert next_day["changed"] is False
assert (home / "data/goal-digest/latest.md").read_text().count("age_days=3 (day precision)") == 2
snapshot["secondmate_current"]["records"][0]["decisions_open"] = []
snapshot["secondmate_current"]["records"][0]["counts"]["decisions_open"] = 0
resolved = run(snapshot)
check(resolved, True, {"Fleet/mate-b"})
assert resolved["changed"] is True
PYTEST
  pass "registered secondmate holds, change detection and incomplete coverage"
}

test_cst_calendar_and_complete_review_history() {
  write_fixtures 0
  local home out
  home=$(make_home cst-review)
  printf 'eta: 2026-01-01 deliver today\n' > "$home/status.txt"
  printf 'timezone = UTC\n' >> "$home/config/goal-digest"
  printf 'T1: blocked\nT7: pending\nT5: complete\nT6b: pending\nT10: pending\nT8: complete\n' > "$home/review.status"
  mkdir -p "$home/data/goal-digest/history"
  local i
  for i in $(seq 1 101); do printf 'retained\n' > "$home/data/goal-digest/history/20200101T$(printf '%06d' "$i")Z.md"; done
  run_digest "$home" 1767315600 >/dev/null || fail "CST run failed"
  python3 - "$home/data/goal-digest/latest.json" <<'PYCHECK' || fail "CST or review contract failed"
import json, sys
value = json.load(open(sys.argv[1]))
assert value["generated_at_local"] == "2026-01-01T19:00:00-0600 CST", value
assert value["missed_etas"] == [], value["missed_etas"]
assert value["review_convergence"] == [{"source":"Example review", "entries":["T1: blocked", "T7: pending", "T5: complete", "T6b: pending", "T10: pending", "T8: complete"]}]
PYCHECK
  [ -f "$home/data/goal-digest/history/20200101T000001Z.md" ] || fail "history was pruned"
  out=$(run_digest "$home" 1767315600) || fail "unchanged review run failed"
  assert_contains "$out" "changed=no" "unchanged ledger does not retrigger"
  printf 'T1: complete\nT7: pending\nT5: complete\nT6b: pending\nT10: pending\nT8: complete\n' > "$home/review.status"
  out=$(run_digest "$home" 1767315600) || fail "early review update failed"
  assert_contains "$out" "changed=yes" "early ledger update changes digest"
  assert_contains "$(cat "$home/data/goal-digest/latest.md")" "T1: complete" "early review entry published in Markdown"
  pass "CST calendar, complete review changes and retained history"
}

test_archive_failure_preserves_notification_state() {
  write_fixtures 0
  local home rc=0
  home=$(make_home archive-failure)
  run_digest "$home" "$RUN1_EPOCH" >/dev/null || fail "initial archive run failed"
  cp "$home/data/goal-digest/.state/seen.tsv" "$home/seen-before"
  cp "$home/data/goal-digest/.state/since.tsv" "$home/since-before"
  cp "$home/data/goal-digest/.state/content.hash" "$home/hash-before"
  cp "$home/data/goal-digest/latest.json" "$home/latest-before"
  write_fixtures 1
  mkdir "$home/data/goal-digest/history/20260101T140000Z.json.tmp"
  run_digest "$home" "$RUN3_EPOCH" >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "archive failure reported success"
  cmp "$home/seen-before" "$home/data/goal-digest/.state/seen.tsv" || fail "archive failure consumed merges"
  cmp "$home/since-before" "$home/data/goal-digest/.state/since.tsv" || fail "archive failure advanced watermark"
  cmp "$home/hash-before" "$home/data/goal-digest/.state/content.hash" || fail "archive failure consumed change"
  cmp "$home/latest-before" "$home/data/goal-digest/latest.json" || fail "archive failure replaced latest JSON"
  rmdir "$home/data/goal-digest/history/20260101T140000Z.json.tmp"
  run_digest "$home" "$RUN3_EPOCH" >/dev/null || fail "archive recovery failed"
  assert_equals "[2]" "$(python3 -c 'import json,sys; print([m["number"] for m in json.load(open(sys.argv[1]))["new_merges"]])' "$home/data/goal-digest/latest.json")" "unarchived merge remains reportable"
  pass "archive failure does not consume notifications or report success"
}

test_pagination_uses_utc_watermark() {
  local home
  home=$(make_home utc-pagination)
  python3 - "$FIXTURE/merged-example-org_example-repo.json" <<'PYFIX'
import json, sys
rows = [{"number":i, "updated_at":"2026-01-01T11:00:00Z", "merged_at":None} for i in range(1,101)]
json.dump(rows, open(sys.argv[1], "w"))
PYFIX
  printf '[]\n' > "$FIXTURE/open-example-org_example-repo.json"
  mkdir -p "$home/data/goal-digest/.state"
  printf 'example-org/example-repo\t1767268800\n' > "$home/data/goal-digest/.state/since.tsv"
  TZ=America/Mexico_City FM_GD_PAGE_FAIL=1 run_digest "$home" "$RUN2_EPOCH" >/dev/null || fail "UTC pagination run failed"
  python3 - "$home/data/goal-digest/latest.json" <<'PYCHECK' || fail "pagination fetched an unnecessary page"
import json, sys
value = json.load(open(sys.argv[1]))
assert not any(u["kind"] == "repo" for u in value["unreachable_sources"]), value["unreachable_sources"]
PYCHECK
  pass "UTC update times stop pagination before the watermark"
}

test_failed_serialization_keeps_published_documents() {
  write_fixtures 0
  local home
  home=$(make_home atomic-publication)
  run_digest "$home" "$RUN1_EPOCH" >/dev/null || fail "initial publication failed"
  cp "$home/data/goal-digest/latest.json" "$home/json-before"
  cp "$home/data/goal-digest/latest.md" "$home/md-before"
  local real_python rc=0
  real_python=$(PATH="$BASE_PATH" command -v python3)
  cat > "$FAKE/python3" <<SH
#!/usr/bin/env bash
if [ -n "\${FM_GD_OUTPUT:-}" ]; then
  exec '$real_python' -c 'import json, sys
source = sys.stdin.read()
def fail_dump(value, fh, **kwargs):
    fh.write("{partial")
    raise OSError("injected serialization failure")
json.dump = fail_dump
exec(compile(source, "<stdin>", "exec"))'
fi
exec '$real_python' "\$@"
SH
  chmod +x "$FAKE/python3"
  run_digest "$home" "$RUN2_EPOCH" >/dev/null 2>&1 || rc=$?
  rm "$FAKE/python3"
  [ "$rc" != 0 ] || fail "serialization failure reported success"
  cmp "$home/json-before" "$home/data/goal-digest/latest.json" || fail "partial JSON became visible"
  cmp "$home/md-before" "$home/data/goal-digest/latest.md" || fail "failed generation replaced Markdown"
  pass "failed serialization preserves complete published documents"
}

test_timeouts_terminate_descendants() {
  write_fixtures 0
  local home real_python child state
  home=$(make_home timeout-descendants "$TMP_ROOT/hanging-command")
  real_python=$(PATH="$BASE_PATH" command -v python3)
  cat > "$TMP_ROOT/hanging-command" <<'SH'
#!/usr/bin/env bash
sleep 300 &
printf '%s\n' "$!" >> "$FM_GD_CHILDREN"
wait
SH
  chmod +x "$TMP_ROOT/hanging-command"
  cat > "$FAKE/python3" <<SH
#!/usr/bin/env bash
[ "\${FM_GD_TIMEOUT:-}" != 120 ] || export FM_GD_TIMEOUT=1
exec '$real_python' "\$@"
SH
  chmod +x "$FAKE/python3"
  FM_GD_CHILDREN="$home/children" run_digest "$home" "$RUN1_EPOCH" >/dev/null 2>&1 || fail "summarizer timeout failed the digest"
  cp "$FAKE/gh" "$TMP_ROOT/gh-before"
  cp "$FAKE/ssh" "$TMP_ROOT/ssh-before"
  cp "$TMP_ROOT/hanging-command" "$FAKE/gh"
  cp "$TMP_ROOT/hanging-command" "$FAKE/ssh"
  printf 'timeout_seconds = 1\nreview = Remote | ssh:example-host:/status\n' >> "$home/config/goal-digest"
  FM_GD_CHILDREN="$home/children" run_digest "$home" "$RUN2_EPOCH" >/dev/null 2>&1 || fail "network timeout failed the digest"
  mv "$TMP_ROOT/gh-before" "$FAKE/gh"
  mv "$TMP_ROOT/ssh-before" "$FAKE/ssh"
  rm "$FAKE/python3"
  assert_equals "5" "$(wc -l < "$home/children" | tr -d ' ')" "summarizer, both gh calls, ssh and changed summarizer were exercised"
  while IFS= read -r child; do
    state=$(ps -o stat= -p "$child" 2>/dev/null || true)
    case "$state" in ''|*Z*) ;; *) kill "$child" 2>/dev/null || true; fail "timed-out descendant $child is still running" ;; esac
  done < "$home/children"
  pass "summarizer, gh and ssh timeouts stop owned descendants"
}

test_killed_digest_releases_lock_while_summarizer_lives() {
  python3 - "$SCRIPT" "$TMP_ROOT/crashed-summary" <<'PYTEST' || fail "orphan summarizer blocked or corrupted its replacement"
import os, pathlib, shlex, signal, subprocess, sys, time
script, home = sys.argv[1], pathlib.Path(sys.argv[2])
(home / "config").mkdir(parents=True)
ready = home / "ready"
release = home / "release"
done = home / "done"
review = home / "review"
review.write_text("pending\n")
helper = home / "summarize.py"
helper.write_text('''import os, pathlib, sys, time
home = pathlib.Path(sys.argv[1])
if sys.argv[2] == "replacement":
    print("replacement summary", flush=True)
else:
    print("orphan started", flush=True)
    (home / "ready").write_text(str(os.getpid()))
    deadline = time.monotonic() + 90
    while not (home / "release").exists():
        if time.monotonic() >= deadline:
            sys.exit(1)
        time.sleep(0.05)
    print("orphan finished", flush=True)
    (home / "done").touch()
''')
config = home / "config/goal-digest"
wrapper = home / "claude-stub"
wrapper.write_text("#!/bin/sh\nexec " + shlex.join([sys.executable, str(helper), str(home)]) + " \"$(cat " + str(home / "mode") + ")\"\n")
wrapper.chmod(0o755)
def configure(mode):
    config.write_text("review = Progress | " + str(review) + "\n")
    (home / "mode").write_text(mode)
configure("orphan")
env = dict(os.environ, FM_HOME=str(home), FM_TEST_SEAM="1", FM_GOAL_DIGEST_CLAUDE=str(wrapper))
children = set()
with (home / "first.log").open("w") as log:
    first = subprocess.Popen([script, "run"], env=env, stdout=log, stderr=log, start_new_session=True)
    try:
        deadline = time.monotonic() + 60
        while not ready.exists() and first.poll() is None and time.monotonic() < deadline:
            time.sleep(0.1)
        assert ready.exists(), "digest did not reach the real summarizer"
        pairs = [tuple(map(int, line.split())) for line in subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True).splitlines()]
        parents = {first.pid}
        while True:
            found = {pid for pid, parent in pairs if parent in parents} - parents
            if not found:
                break
            children.update(found)
            parents.update(found)
        child = int(ready.read_text())
        children.add(child)
        first.kill()
        first.wait()
        os.kill(child, 0)
        configure("replacement")
        review.write_text("complete\n")
        retry = subprocess.run([script, "run"], env=env, text=True, capture_output=True, timeout=60)
        assert retry.returncode == 0, retry.stderr
        assert "changed=yes" in retry.stdout, retry.stdout
        assert (home / "data/goal-digest/latest.json").is_file()
        summary = home / "data/goal-digest/summary.txt"
        assert summary.read_text() == "replacement summary\n"
        os.kill(child, 0)
        release.touch()
        deadline = time.monotonic() + 10
        while not done.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        assert done.exists(), "orphan never finished its delayed write"
        assert summary.read_text() == "replacement summary\n", summary.read_text()
    finally:
        try:
            os.killpg(first.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        for child in children:
            try:
                os.kill(child, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if first.poll() is None:
            first.wait()
PYTEST
  pass "killed digest releases its lock and its delayed summarizer cannot corrupt a replacement"
}

fm_test_run test_killed_digest_releases_lock_while_summarizer_lives test_complete_collection_recovers_unreported_merge_window test_new_merge_changed_and_summarize_only_on_change test_missed_eta_stall_and_unreachable test_missing_config_uses_default_output_dir test_install_launchagent test_ssh_quoting_lock_and_install_failure test_lingering_summarizer_helper_does_not_hold_lock test_first_run_seeds_old_merges_and_page_failure_is_incomplete test_owner_actions_are_explicit_and_age_from_wait_start test_secondmate_owner_actions_and_coverage test_cst_calendar_and_complete_review_history test_archive_failure_preserves_notification_state test_pagination_uses_utc_watermark test_failed_serialization_keeps_published_documents test_timeouts_terminate_descendants test_first_run_large_repo_stops_and_saves_watermark
