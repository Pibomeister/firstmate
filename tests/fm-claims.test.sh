#!/usr/bin/env bash
# tests/fm-claims.test.sh - bin/fm-claims.sh reads claims only from a task's
# status log, judges each against real git repositories and stubbed forge,
# no-mistakes, AgentKit, tmux, and lsof tools, appends one ledger record per
# verdict, and turns a refuted verdict into a reopening blocker and a
# failure-class occurrence. Cases cover the extraction limits, claim-time and
# rewritten-history pushes, PR binding, the GitHub remote-head and compare
# reads, the custody gate, consequence recovery, and redaction.
# docs/claim-ledger.md owns the record contract these cases read back.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLAIMS="$ROOT/bin/fm-claims.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-claims-tests)
T0=1800000000
fm_git_identity

# Stubs answer from files in $FM_FAKE_DIR; a missing answer file is a failed
# read. gh-*.err makes that gh read fail with the file's text on stderr.
make_fakes() {  # <dir> -> echoes the fakebin dir
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
d=${FM_FAKE_DIR:?}
printf '%s\n' "$*" >> "$d/gh.calls"
[ -z "${FAKE_GH_SLEEP:-}" ] || sleep "$FAKE_GH_SLEEP"
# FAKE_GH_APPEND_FILE: the first gh call appends FAKE_GH_APPEND to that file,
# standing in for a mate line written while the scan runs.
if [ -n "${FAKE_GH_APPEND_FILE:-}" ] && [ ! -e "$d/gh.appended" ]; then
  : > "$d/gh.appended"
  printf '%s\n' "${FAKE_GH_APPEND:?}" >> "$FAKE_GH_APPEND_FILE"
fi
case "$1 $2" in
  "pr view") f="$d/gh-pr-view" ;;
  "pr checks") f="$d/gh-pr-checks" ;;
  "api --hostname")
    case "$4" in
      */git/ref/heads/*) f="$d/gh-ref" ;;
      */compare/*) f="$d/gh-compare" ;;
      *) f="$d/gh-api" ;;
    esac ;;
  *) exit 1 ;;
esac
if [ -f "$f.err" ]; then cat "$f.err" >&2; exit 1; fi
[ -f "$f" ] || exit 1
cat "$f"
SH
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ -f "${FM_FAKE_DIR:?}/nm-status" ] || exit 1
cat "$FM_FAKE_DIR/nm-status"
SH
  cat > "$fb/node" <<'SH'
#!/usr/bin/env bash
[ -f "${FM_FAKE_DIR:?}/ak-json" ] || exit 1
cat "$FM_FAKE_DIR/ak-json"
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
if [ -f "${FM_FAKE_DIR:?}/tmux-missing" ]; then
  echo "can't find session: fm" >&2
  exit 1
fi
echo "fake tmux cannot answer" >&2
exit 1
SH
  cat > "$fb/lsof" <<'SH'
#!/usr/bin/env bash
[ -f "${FM_FAKE_DIR:?}/lsof" ] || exit 1
cat "$FM_FAKE_DIR/lsof"
SH
  chmod +x "$fb"/*
  printf '%s\n' "$fb"
}

# A home with one ship task t1 on branch fm/t1 in a worktree of a repository
# whose origin is a local bare clone. Sets H, ST, DT, WT, REPO, FAKE, FB.
setup_task() {  # <name> <mode>
  local name=$1 mode=$2
  H="$TMP_ROOT/$name"
  ST="$H/state" DT="$H/data"
  FAKE="$H/fake"
  mkdir -p "$ST" "$DT/t1" "$H/config" "$FAKE"
  REPO="$H/repo"
  WT="$H/wt"
  fm_git_worktree "$REPO" "$WT" fm/t1 >/dev/null 2>&1 || fail "fixture: cannot build the worktree"
  git -C "$REPO" fetch -q origin 2>/dev/null
  git -C "$REPO" remote set-head origin main >/dev/null 2>&1 || true
  git -C "$WT" fetch -q origin 2>/dev/null
  FB=$(make_fakes "$H")
  fm_write_meta "$ST/t1.meta" "window=fm:fm-t1" "worktree=$WT" "project=$REPO" \
    "harness=claude" "model=claude-opus-5-5" "kind=ship" "mode=$mode" "yolo=off" \
    "branch=fm/t1" "spawn_gen=s1"
  : > "$ST/t1.status"
}

# <epoch> dates the commit and its branch reflog entry.
commit_work() {  # <file> [<epoch>] -> echoes the new HEAD
  printf 'change %s\n' "$RANDOM" > "$WT/$1"
  git -C "$WT" add "$1"
  if [ -n "${2:-}" ]; then
    GIT_COMMITTER_DATE="@$2 +0000" GIT_AUTHOR_DATE="@$2 +0000" git -C "$WT" commit -qm "work on $1"
  else
    git -C "$WT" commit -qm "work on $1"
  fi
  git -C "$WT" rev-parse HEAD
}

status() {  # <line>
  printf '%s\n' "$1" >> "$ST/t1.status"
}

last_line() {
  awk 'END { print NR }' "$ST/t1.status"
}

meta_set() {  # <key> <value>
  grep -v "^$1=" "$ST/t1.meta" > "$ST/t1.meta.tmp"
  printf '%s=%s\n' "$1" "$2" >> "$ST/t1.meta.tmp"
  mv "$ST/t1.meta.tmp" "$ST/t1.meta"
}

# The monitor's beat, dated <epoch>.
beat() {  # <epoch>
  : > "$ST/.last-watcher-beat"
  fm_touch_epoch "$1" "$ST/.last-watcher-beat"
}

# A no-mistakes status answer for fm/t1 in the shape of
# tests/captures/no-mistakes-v1.70.1/failed.toon.
nm_run() {  # <outcome> <head> <test-step> <ci-step> [<push-step>]
  printf 'run:\n  id: r1\n  branch: fm/t1\n  status: completed\n  head_sha: %s\n  steps[4]{step,status,findings,duration_ms}:\n    test,%s,0,10\n    push,%s,0,10\n    pr,completed,0,10\n    ci,%s,0,10\noutcome: %s\n' \
    "$2" "$3" "${5:-completed}" "$4" "$1" > "$FAKE/nm-status"
}

claims() {  # <now> <args...>
  local now=$1
  shift
  env PATH="$FB:$PATH" FM_HOME="$H" FM_FAKE_DIR="$FAKE" FM_CLAIMS_NOW="$now" \
    FM_CLAIMS_NET_TIMEOUT="${NET_TIMEOUT:-5}" bash "$CLAIMS" "$@"
}

ledger_lines() {
  if [ -f "$ST/t1.claims.jsonl" ]; then wc -l < "$ST/t1.claims.jsonl" | tr -d ' '; else echo 0; fi
}

# 0 when the wake drain's OPEN DECISIONS section lists <key> for t1.
decision_open() {  # <key>
  FM_STATE_OVERRIDE="$ST" "$DRAIN" 2>/dev/null | sed -n '/^OPEN DECISIONS (/,$p' \
    | grep -F "t1 [key=$1] blocked:" >/dev/null
}

kind_count() {  # <kind>
  jq -r --arg k "$1" 'select(.kind == $k) | .id' "$ST/t1.claims.jsonl" | wc -l | tr -d ' '
}

# The newest ledger record of <kind>, as one jq-selected field.
rec() {  # <kind> <jq-path>
  jq -r --arg k "$1" "select(.kind == \$k) | $2" "$ST/t1.claims.jsonl" | tail -n 1
}

test_committed_verified_record_shape() {
  local head out rc id
  setup_task committed-ok local-only
  head=$(commit_work a.txt)
  status "working [at=$((T0 - 30))]: committed $head with the parser change"
  out=$(claims "$T0" scan --all); rc=$?
  expect_code 0 "$rc" "a verified scan exits 0"
  assert_contains "$out" "t1 " "scan prints the task"
  assert_contains "$out" " committed verified line=1:" "scan prints the verdict line"
  [ "$(kind_count committed)" = 1 ] || fail "one claim should give one ledger record: $(cat "$ST/t1.claims.jsonl")"
  id=$(rec committed .id)
  [[ $id =~ ^[0-9a-f]{16}$ ]] || fail "claim id is not 16 hex: $id"
  assert_equals 1 "$(rec committed .v)" "record version"
  assert_equals "$T0" "$(rec committed .checked_at)" "checked_at is the scan time"
  assert_equals "$((T0 - 30))" "$(rec committed .time)" "time is the line's stamp"
  assert_equals t1 "$(rec committed .mate)" "mate"
  assert_equals ship "$(rec committed .mate_kind)" "mate_kind"
  assert_equals claude "$(rec committed .harness)" "harness"
  assert_equals s1 "$(rec committed .spawn_gen)" "spawn_gen"
  assert_equals "status state/t1.status 1" "$(rec committed '"\(.evidence.source) \(.evidence.path) \(.evidence.line)"')" "evidence pointer"
  [[ $(rec committed .evidence.line_sha256) =~ ^[0-9a-f]{64}$ ]] || fail "evidence line_sha256 is not a sha256"
  assert_equals fm/t1 "$(rec committed .subject.branch)" "subject branch"
  assert_equals "$head" "$(rec committed .subject.sha)" "subject sha is the resolved commit"
  assert_equals "verified git-local 1" "$(rec committed '"\(.verdict) \(.checker) \(.attempt)"')" "verdict, checker, attempt"
  assert_equals "committed $head with the parser change" "$(rec committed .claim)" "claim text"
  pass "a committed claim on the task branch is verified and its record carries the documented members"
}

test_refuted_claim_reopens_and_records_failure_class() {
  local out rc id fc
  setup_task committed-bad local-only
  commit_work a.txt >/dev/null
  status "working: committed deadbeef1 with the fix"
  out=$(claims "$T0" scan t1); rc=$?
  expect_code 3 "$rc" "a scan that records a refuted verdict exits 3"
  assert_contains "$out" " committed refuted line=1: commit deadbeef1 does not exist" "scan prints the refutation"
  id=$(rec committed .id)
  assert_equals refuted "$(rec committed .verdict)" "ledger verdict"
  grep -F "blocked [at=$T0] [key=claim-refuted-$id]: claim-refuted-reopen: committed claim at line 1 is false: commit deadbeef1 does not exist" \
    "$ST/t1.status" >/dev/null || fail "no reopening blocker in the status log: $(cat "$ST/t1.status")"
  fc="$DT/failure-classes/claim-refuted-committed.jsonl"
  assert_present "$fc" "the failure-class file was not written"
  assert_equals "occurrence claim-refuted-committed t1 $id opened claim-refuted-$id state/t1.status:1 state/t1.claims.jsonl" \
    "$(jq -r '"\(.event) \(.key) \(.task) \(.claim_id) \(.reopen) \(.reopen_key) \(.evidence) \(.ledger)"' "$fc")" \
    "failure-class occurrence members"
  decision_open "claim-refuted-$id" || fail "the reopening blocker does not list as an open decision"

  out=$(claims $((T0 + 10)) scan t1); rc=$?
  expect_code 0 "$rc" "a rescan with nothing due exits 0"
  [ -z "$out" ] || fail "a rescan judged a final claim again: $out"
  [ "$(kind_count committed)" = 1 ] || fail "a rescan appended to the ledger"
  [ "$(wc -l < "$fc" | tr -d ' ')" = 1 ] || fail "a rescan appended another occurrence"
  pass "a refuted claim is recorded, reopens the task, opens a failure-class occurrence, and is never judged twice"
}

test_clear_closes_only_an_open_blocker() {
  local id out rc
  setup_task clear local-only
  status "working: committed deadbeef1 with the fix"
  claims "$T0" scan t1 >/dev/null
  id=$(rec committed .id)
  status "resolved [key=claim-refuted-$id]: I fixed it"
  decision_open "claim-refuted-$id" || fail "a bare mate resolution cleared the refuted-claim blocker"
  out=$(claims "$T0" clear t1 "$id" 2>&1); rc=$?
  expect_code 1 "$rc" "clear without a reason refuses"
  out=$(claims "$T0" clear t1 "$id" --reason "checked by hand"); rc=$?
  expect_code 0 "$rc" "clear of an open blocker succeeds"
  assert_contains "$out" "t1 $id cleared" "clear reports the close"
  grep -F "claim-refuted-cleared: task=t1 claim=$id via=fm-claims-clear checked by hand" "$ST/t1.status" >/dev/null \
    || fail "clear did not write the close note: $(cat "$ST/t1.status")"
  if decision_open "claim-refuted-$id"; then
    fail "the blocker is still open after clear"
  fi
  assert_equals refuted "$(rec committed .verdict)" "clear leaves the refuted record"
  out=$(claims "$T0" clear t1 "$id" --reason again 2>&1); rc=$?
  expect_code 1 "$rc" "clearing a closed blocker refuses"
  assert_contains "$out" "is not open" "the refusal names the cause"
  pass "clear closes an open refuted-claim blocker that a bare mate resolution cannot, and refuses once it is closed"
}

test_hedges_tokens_and_verifier_lines() {
  local ln
  setup_task hedge local-only
  status "working: will push once the tests pass"
  status "working: tests are not passing yet"
  status "working: committed the defaced banner fix"
  status "working: pushed back on the reviewer's suggestion"
  status "working: fix the tests so they pass"
  status "working: tests passed locally, CI is red"
  status "working: claim-refuted-reopen: committed deadbeef1 with the fix"
  ln=$(last_line)
  status "blocked [at=$T0] [key=claim-refuted-0123456789abcdef]: claim-refuted-reopen: committed claim at line 9 is false"
  claims "$T0" scan t1 >/dev/null
  assert_equals "refuted $ln" "$(rec committed '"\(.verdict) \(.evidence.line)"')" "a reserved token exempted a claim"
  assert_equals "$ln" "$(rec alive .evidence.line)" "the verifier's own blocker became the newest mate line"
  assert_equals 2 "$(ledger_lines)" "hedged, sha-less, cue-less, or contrary lines produced claims: $(cat "$ST/t1.claims.jsonl")"
  pass "hedges, all-letter words, cue-less pushes, and contrary words yield no claim; a reserved token exempts nothing"
}

test_pushed_against_the_remote_branch() {
  local head c out ln
  setup_task pushed local-only
  head=$(commit_work a.txt)
  status "working: pushed ${head:0:9} for review"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pushed refuted line=1: origin has no branch fm/t1" "an unpushed branch is refuted"
  assert_equals git-ls-remote "$(rec pushed .checker)" "a non-GitHub origin is read with git ls-remote"
  git -C "$WT" push -q origin fm/t1 2>/dev/null || fail "fixture: push failed"
  head=$(commit_work b.txt)
  status "working: pushed ${head:0:9} too"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pushed refuted line=$ln: origin/fm/t1 at " "a commit beyond the remote head is refuted"
  git -C "$WT" push -q origin fm/t1 2>/dev/null || fail "fixture: second push failed"
  status "working [at=$T0]: pushed the branch again"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pushed verified line=$ln: origin/fm/t1 at ${head:0:12} contains ${head:0:12}" \
    "a sha-less claim is judged at the branch head of its stamp"
  c=$(commit_work c.txt $((T0 + 100)))
  git -C "$WT" push -q origin fm/t1 2>/dev/null || fail "fixture: third push failed"
  commit_work d.txt $((T0 + 200)) >/dev/null
  status "working [at=$((T0 + 150))]: pushed the fix branch"
  ln=$(last_line)
  out=$(claims $((T0 + 300)) scan t1)
  assert_contains "$out" " pushed verified line=$ln: origin/fm/t1 at ${c:0:12} contains ${c:0:12}" \
    "a commit made after the claim does not refute it"
  status "working: pushed to origin"
  ln=$(last_line)
  out=$(claims $((T0 + 300)) scan t1)
  assert_contains "$out" " pushed unverifiable line=$ln: the claim names no commit and the branch head at its time could not be read" \
    "a claim with neither a commit nor a stamp is unverifiable"
  pass "a pushed claim is checked against the remote branch head at the claim's commit"
}

test_rewritten_history_is_unverifiable() {
  local a out ln
  setup_task rewrite local-only
  a=$(commit_work a.txt)
  git -C "$WT" push -q origin fm/t1 2>/dev/null || fail "fixture: push failed"
  status "working: committed ${a:0:9} and pushed it to origin"
  ln=$(last_line)
  git -C "$WT" commit -q --amend -m "amended work"
  git -C "$WT" push -q -f origin fm/t1 2>/dev/null || fail "fixture: force push failed"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " committed unverifiable line=$ln: commit ${a:0:12} exists but is not on the task branch fm/t1" \
    "an amended-away commit is not refuted"
  assert_contains "$out" " pushed unverifiable line=$ln: origin/fm/t1 at " "a force-pushed branch is not refuted"
  assert_contains "$out" "has diverged from ${a:0:9}" "the reason names the divergence"
  pass "a claim about a commit that history rewrote away is unverifiable, not refuted"
}

test_pr_and_tests_through_the_forge() {
  local head url out
  setup_task forge direct-PR
  head=$(commit_work a.txt)
  git -C "$WT" push -q origin fm/t1 2>/dev/null
  url=https://github.com/o/r/pull/7
  printf 'OPEN\ttrue\t%s\tfm/t1\n' "$head" > "$FAKE/gh-pr-view"
  status "done: PR $url ready for review"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pr-ready refuted line=1: PR $url is still a draft" "a draft PR is refuted"
  assert_contains "$out" " pushed verified line=1:" "the direct-PR done is also a pushed claim"
  printf 'OPEN\tfalse\t%s\tfm/t1\n' "$head" > "$FAKE/gh-pr-view"
  printf '3\t0\t0\n' > "$FAKE/gh-pr-checks"
  status "working: PR $url opened; tests pass on it"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pr-opened verified line=3: PR $url exists (OPEN) on fm/t1" "an existing PR is verified"
  assert_contains "$out" " tests-green verified line=3: all 3 check(s) passed on PR $url" "passing checks verify"
  printf '2\t1\t0\n' > "$FAKE/gh-pr-checks"
  status "working: CI is green on $url"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green refuted line=4: 1 check(s) failed or were cancelled" "a failed check refutes"
  printf 'GraphQL: Could not resolve to a PullRequest with the number of 9.\n' > "$FAKE/gh-pr-view.err"
  status "working: opened https://github.com/o/r/pull/9"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pr-opened refuted line=6: the forge has no PR https://github.com/o/r/pull/9" "a missing PR is refuted"
  pass "PR and test claims are judged from gh pr view and gh pr checks"
}

test_pr_binding_and_states() {
  local head url other out ln
  setup_task prbind direct-PR
  head=$(commit_work a.txt)
  git -C "$WT" push -q origin fm/t1 2>/dev/null || fail "fixture: push failed"
  url=https://github.com/o/r/pull/7
  printf 'CLOSED\tfalse\t%s\tfm/t1\n' "$head" > "$FAKE/gh-pr-view"
  status "working: PR $url is ready"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pr-ready refuted line=$ln: PR $url is closed without merging" "a closed PR is not ready"
  printf 'MERGED\tfalse\t%s\tfm/t1\n' "$head" > "$FAKE/gh-pr-view"
  status "working: $url is ready and merged"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pr-ready verified line=$ln: PR $url is merged" "a merged PR was ready"
  other=1111111111111111111111111111111111111111
  printf 'OPEN\tfalse\t%s\tfm/t1\n' "$other" > "$FAKE/gh-pr-view"
  status "working: $url is ready for review"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pr-ready refuted line=$ln: PR $url is at ${other:0:12}, not the local copy's HEAD ${head:0:12}" \
    "a direct-PR claim must be at the local copy's HEAD"
  url=https://github.com/o/r/pull/8
  printf 'OPEN\tfalse\t%s\tother-branch\n' "$head" > "$FAKE/gh-pr-view"
  printf '3\t0\t0\n' > "$FAKE/gh-pr-checks"
  status "working: opened $url"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pr-opened unverifiable line=$ln: PR $url is on branch other-branch, not the task branch fm/t1, so the claim is not about the task's PR" \
    "a free-text claim about another branch's PR is unverifiable"
  rm -f "$FAKE/gh.calls"
  status "working: tests pass on $url"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green unverifiable line=$ln:" "another PR's checks do not verify the task's tests"
  if grep -q '^pr checks' "$FAKE/gh.calls" 2>/dev/null; then
    fail "another PR's checks were read for the task's claim: $(cat "$FAKE/gh.calls")"
  fi
  status "done: PR $url ready for review"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pr-ready refuted line=$ln: PR $url is on branch other-branch, not the task branch fm/t1" \
    "a done: claim about another branch's PR is refuted"
  pass "PR claims bind to the task's PR and judge closed, merged, draft, and head state"
}

test_tests_green_from_no_mistakes_and_agentkit() {
  local head out ln
  setup_task nm no-mistakes
  head=$(commit_work a.txt)
  nm_run passed "$head" completed pending
  status "working: the suite passed"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green verified line=$ln: the no-mistakes run at ${head:0:12} passed (passed)" "a passed run at HEAD verifies"
  nm_run failed "$head" failed pending
  status "working: tests passed after the retry"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green refuted line=$ln: the no-mistakes run at ${head:0:12} failed its test step" "a failed test step refutes"
  nm_run failed "$head" completed pending failed
  status "working: all tests green now"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green unverifiable line=$ln:" "a run that failed only its push neither verifies nor refutes"
  nm_run passed-with-override "$head" completed completed
  status "working: checks are green"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green unverifiable line=$ln:" "an overridden run never verifies"
  rm -f "$FAKE/nm-status"
  : > "$FAKE/ak-gate.mjs"
  printf '%s\n' "$FAKE/ak-gate.mjs" > "$H/config/agentkit-gate"
  printf '{"ok":true,"head":{"revision":"%s"}}\n' "$head" > "$FAKE/ak-json"
  status "working: tests pass now"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green verified line=$ln: AgentKit verify gate is current at ${head:0:12}" "a current AgentKit verify gate verifies"
  printf '{"ok":true,"head":{"revision":"%s"},"notes":["marker-only record: history, not proof"]}\n' "$head" > "$FAKE/ak-json"
  status "working: the test suite is green"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green unverifiable line=$ln:" "a gate answer with notes does not verify"
  assert_contains "$out" "carries notes, so it is not proof" "the reason names the notes"
  pass "tests-green reads the no-mistakes test and ci steps, then a note-free AgentKit verify gate"
}

test_unverifiable_retries_and_timeouts() {
  local out start elapsed
  setup_task retry direct-PR
  commit_work a.txt >/dev/null
  status "working: opened https://github.com/o/r/pull/7"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pr-opened unverifiable line=1: PR https://github.com/o/r/pull/7 could not be read" "an unreadable PR is unverifiable"
  out=$(claims $((T0 + 60)) scan t1)
  [ -z "$out" ] || fail "an unverifiable claim was retried before the retry interval: $out"
  printf 'MERGED\tfalse\tabc\tfm/t1\n' > "$FAKE/gh-pr-view"
  out=$(claims $((T0 + 301)) scan t1)
  assert_contains "$out" " pr-opened verified line=1:" "the retry after the interval records the new verdict"
  assert_equals 2 "$(rec pr-opened .attempt)" "the retry is attempt 2"
  [ "$(kind_count pr-opened)" = 2 ] || fail "the retry did not add exactly one record"
  out=$(claims $((T0 + 301)) show t1)
  assert_contains "$out" "$(rec pr-opened .id)"$'\t'"verified"$'\t'"pr-opened"$'\t'"line=1"$'\t'"attempt=2"$'\t'"gh-pr-view" \
    "show prints each claim's newest verdict"

  setup_task timeout direct-PR
  status "working: opened https://github.com/o/r/pull/8"
  printf 'OPEN\tfalse\tabc\tfm/t1\n' > "$FAKE/gh-pr-view"
  start=$(date +%s)
  out=$(FAKE_GH_SLEEP=30 NET_TIMEOUT=1 claims "$T0" scan t1)
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 20 ] || fail "a hung forge read was not bounded (${elapsed}s)"
  assert_contains "$out" " pr-opened unverifiable line=1:" "a timed-out read is unverifiable"
  out=$(FM_CLAIMS_MAX_ATTEMPTS=1 claims $((T0 + 1000)) scan t1)
  [ -z "$out" ] || fail "a claim at its attempt cap was judged again: $out"
  pass "unverifiable claims retry after the interval up to the cap, and a hung read is bounded and unverifiable"
}

test_order_rules_and_agentkit() {
  local head out
  setup_task order local-only
  printf '%s\n' "Work on the ship branch only." "Never push to the default branch." "Do not bump a version." > "$DT/t1/brief.md"
  head=$(commit_work a.txt)
  status "done: ready on fm/t1"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " order unverifiable line=1: no AgentKit gate is configured" "rules that hold still need the AgentKit gate"
  assert_contains "$out" " committed verified line=1:" "a local-only done is also a committed claim"
  : > "$FAKE/ak-gate.mjs"
  printf '%s\n' "$FAKE/ak-gate.mjs" > "$H/config/agentkit-gate"
  printf '{"ok":true,"head":{"revision":"%s"}}\n' "$head" > "$FAKE/ak-json"
  out=$(claims $((T0 + 400)) scan t1)
  assert_contains "$out" " order verified line=1: order rules hold (ship-branch no-default-push no-version-bump)" "held rules plus a current gate verify"
  printf '{\n  "version": "2.0.0"\n}\n' > "$WT/package.json"
  git -C "$WT" add package.json
  git -C "$WT" commit -qm "bump"
  head=$(git -C "$WT" rev-parse HEAD)
  git -C "$WT" push -q "$(git -C "$WT" remote get-url origin)" "fm/t1:main" 2>/dev/null \
    || fail "fixture: push to the default branch failed"
  printf '{"ok":true,"head":{"revision":"%s"}}\n' "$head" > "$FAKE/ak-json"
  status "done: ready again"
  out=$(claims $((T0 + 800)) scan t1)
  assert_contains "$out" " order refuted line=2: broke an order rule - no-default-push: origin's default branch main contains HEAD" "a default-branch push refutes"
  assert_contains "$out" "no-version-bump: the version field in package.json changed" "a version bump refutes"

  setup_task order-remote local-only
  printf '%s\n' "Never push to the default branch." > "$DT/t1/brief.md"
  commit_work a.txt >/dev/null
  git -C "$WT" push -q origin fm/t1:main 2>/dev/null || fail "fixture: push to the default branch by remote name failed"
  status "done: shipped"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " order refuted line=1: broke an order rule - no-default-push: origin's default branch main contains HEAD" \
    "a push by remote name, which moves the local base ref, still refutes"
  pass "order claims check the recognized rules and need a current AgentKit gate for the rest"
}

test_alive_endpoint_output_and_steers() {
  local out marker id ln
  setup_task alive local-only
  marker="$ST/.hash-fm_fm-t1"
  : > "$marker"
  fm_touch_epoch $((T0 - 60)) "$marker"
  beat "$T0"
  status "working: still at it"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " alive verified line=1: terminal output changed 60s ago" "fresh output verifies"
  out=$(claims $((T0 + 30)) scan t1)
  [ -z "$out" ] || fail "an unchanged alive verdict was recorded again: $out"
  printf 'p1\nn/elsewhere\n' > "$FAKE/lsof"
  beat $((T0 + 5000))
  out=$(claims $((T0 + 5000)) scan t1)
  assert_contains "$out" " alive refuted line=1: no terminal output for 5060s and 0% CPU in the local copy" "stale output with no CPU refutes"
  assert_equals 2 "$(rec alive .attempt)" "the changed verdict is the second record"
  id=$(rec alive .id)
  decision_open "claim-refuted-$id" || fail "the refuted alive claim did not reopen the task"
  fm_touch_epoch $((T0 + 5100)) "$marker"
  beat $((T0 + 5100))
  out=$(claims $((T0 + 5110)) scan t1)
  assert_contains "$out" "t1 $id cleared" "an alive claim that reads alive again closes its blocker"
  assert_contains "$out" " alive verified line=1: terminal output changed 10s ago" "the new verdict is recorded"
  grep -F "claim-refuted-cleared: task=t1 claim=$id via=fm-claims-scan" "$ST/t1.status" >/dev/null \
    || fail "the close note is missing: $(cat "$ST/t1.status")"
  if decision_open "claim-refuted-$id"; then
    fail "the alive blocker is still open after the agent read alive"
  fi
  beat "$T0"
  out=$(claims $((T0 + 9000)) scan t1)
  assert_contains "$out" " alive unverifiable line=1: terminal output age or CPU use could not be read" \
    "output age is not read while the monitor's beat is stale"
  mkdir -p "$ST/t1.inbox"
  printf 'hello\n' > "$ST/t1.inbox/001.msg"
  fm_touch_epoch $((T0 - 2000)) "$ST/t1.inbox/001.msg"
  fm_touch_epoch "$T0" "$marker"
  status "working: back again"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " alive refuted line=" "an unread steer refutes even with fresh output"
  assert_contains "$out" "steering message 001.msg has been unread for 2000s" "the refutation names the steer"
  rm -rf "$ST/t1.inbox"
  : > "$FAKE/tmux-missing"
  status "paused: waiting on review"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " alive refuted line=$ln: the agent's endpoint (tmux) is gone" "a dead endpoint refutes"

  setup_task alive-nocopy local-only
  meta_set worktree ""
  printf 'p1\nn/private\n' > "$FAKE/lsof"
  status "paused: waiting on review"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " alive unverifiable line=1: the paused agent's presence could not be read" \
    "an empty local copy path matches no process"
  pass "alive is judged from the endpoint, fresh output, CPU in the copy, and unread steers, and closes its own blocker"
}

test_secret_shaped_text_is_redacted() {
  local claim
  setup_task secrets local-only
  status "working: committed deadbeef1 using token=ghp_abcdefghijklmnopqrstuvwxyz0123 and https://user:pw@example.com/x"
  claims "$T0" scan t1 >/dev/null
  claim=$(rec committed .claim)
  assert_not_contains "$claim" "ghp_abcdefghijklmnopqrstuvwxyz0123" "a GitHub token survived in the ledger"
  assert_not_contains "$claim" "user:pw@" "URL credentials survived in the ledger"
  assert_contains "$claim" "[redacted]" "redaction is marked"

  setup_task secrets-forge direct-PR
  printf 'OPEN\tfalse\tabc\tghp_abcdefghijklmnopqrstuvwxyz0123\n' > "$FAKE/gh-pr-view"
  status "done: PR https://github.com/o/r/pull/7 ready"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pr-ready refuted line=1: PR https://github.com/o/r/pull/7 is on branch [redacted], not the task branch fm/t1" \
    "forge text in the reason is redacted"
  assert_not_contains "$out" "ghp_abcdefghijklmnopqrstuvwxyz0123" "a token reached stdout"
  if grep -rq "ghp_abcdefghijklmnopqrstuvwxyz0123" "$ST/t1.claims.jsonl" "$ST/t1.status" "$DT/failure-classes"; then
    fail "a token reached the ledger, the blocker, or the failure-class record"
  fi
  pass "secret-shaped text is redacted in claim text, reasons, observed values, blockers, and stdout"
}

test_refusals_and_usage() {
  local out rc
  setup_task refuse local-only
  out=$(claims "$T0" scan 'bad/id' 2>&1); rc=$?
  expect_code 1 "$rc" "a malformed task id refuses"
  out=$(claims "$T0" scan '..' 2>&1); rc=$?
  expect_code 1 "$rc" "a dot task id refuses"
  out=$(claims "$T0" scan nosuch 2>&1); rc=$?
  expect_code 1 "$rc" "a named task with neither status log nor metadata refuses"
  assert_contains "$out" "has neither a status log nor metadata" "the refusal names the cause"
  ln -s "$ST/elsewhere.jsonl" "$ST/t1.claims.jsonl"
  status "working: committed deadbeef1"
  out=$(claims "$T0" scan t1 2>&1); rc=$?
  expect_code 1 "$rc" "a symlinked ledger refuses"
  assert_contains "$out" "refusing the symlinked" "the refusal names the symlink"
  assert_absent "$ST/elsewhere.jsonl" "a refused scan wrote through the symlink"
  out=$(claims "$T0" frobnicate 2>&1); rc=$?
  expect_code 2 "$rc" "an unknown command prints usage"
  assert_contains "$out" "Usage:" "usage text is printed"
  out=$(FM_CLAIMS_RETRY_SECS=soon claims "$T0" scan t1 2>&1); rc=$?
  expect_code 1 "$rc" "a malformed tunable refuses"
  pass "malformed ids, symlinked records, malformed tunables, and unknown commands refuse"
}

test_promoted_and_scout_done_lines_are_not_ship_claims() {
  local out ln
  setup_task promoted no-mistakes
  meta_set promoted_status_lines 1
  status "done: committed deadbeef1 for the report"
  status "working: building the change now"
  claims "$T0" scan t1 >/dev/null
  assert_equals 0 "$(kind_count committed)" "a done: line from before the promotion was read as a claim"
  status "done: handed off for validation"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " committed refuted line=$ln: the task branch carries no commit of its own beyond its base" \
    "a ship done: after the promotion is a claim"

  setup_task scout no-mistakes
  meta_set kind scout
  status "done: committed deadbeef1 in the report"
  claims "$T0" scan t1 >/dev/null
  assert_equals 0 "$(ledger_lines)" "a scout's done: line was read as a claim"
  pass "done: lines a task wrote as a scout carry no claim"
}

test_custody_alone_never_verifies_a_push() {
  local out
  setup_task custody direct-PR
  commit_work a.txt >/dev/null
  git -C "$WT" update-ref refs/remotes/origin/fm/t1 HEAD
  status "done: pushed fm/t1 for review"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pushed refuted line=1: origin has no branch fm/t1" "a forged local tracking ref verified a push"
  assert_equals accepted "$(rec pushed .observed.custody)" "the custody gate's answer is recorded"
  pass "a custody acceptance from a local ref does not verify a push the remote lacks"
}

test_github_origin_remote_head_and_compare() {
  local head other out ln
  setup_task github direct-PR
  head=$(commit_work a.txt)
  git -C "$WT" remote set-url origin https://github.com/o/r
  printf 'gh: Not Found (HTTP 404)\n' > "$FAKE/gh-ref.err"
  printf 'o/r\n' > "$FAKE/gh-api"
  status "working: pushed ${head:0:9} to origin"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pushed refuted line=$ln: origin has no branch fm/t1" "a 404 on a readable repository is no branch"
  assert_equals gh-remote-head "$(rec pushed .checker)" "a GitHub origin is read with gh api"
  rm -f "$FAKE/gh-api"
  status "working: pushed ${head:0:9} to the remote"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pushed unverifiable line=$ln: origin's branch fm/t1 could not be read" \
    "a 404 on a repository that does not read is unverifiable"
  printf 'o/r\n' > "$FAKE/gh-api"
  meta_set pr https://github.com/o/r/pull/5
  printf 'MERGED\tfalse\t%s\tfm/t1\n' "$head" > "$FAKE/gh-pr-view"
  status "working: pushed ${head:0:9} upstream"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pushed verified line=$ln: origin/fm/t1 at ${head:0:12} contains ${head:0:9}" \
    "the merged PR head stands in for a deleted branch"
  assert_equals gh-pr-view "$(rec pushed .checker)" "the stand-in is the PR head"
  rm -f "$FAKE/gh-ref.err"
  other=2222222222222222222222222222222222222222
  printf '%s\n' "$other" > "$FAKE/gh-ref"
  printf 'diverged\n' > "$FAKE/gh-compare"
  status "working: pushed ${head:0:9} to origin again"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pushed unverifiable line=$ln: origin/fm/t1 at ${other:0:12} has diverged from ${head:0:9}" \
    "a diverged compare answer is unverifiable"
  printf 'ahead\n' > "$FAKE/gh-compare"
  status "working: pushed ${head:0:9} to the branch"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pushed verified line=$ln: origin/fm/t1 at ${other:0:12} contains ${head:0:9}" \
    "an ahead compare answer verifies"
  printf 'behind\n' > "$FAKE/gh-compare"
  status "working: pushed ${head:0:9} to the remote branch"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pushed refuted line=$ln: origin/fm/t1 at ${other:0:12} does not contain ${head:0:9}" \
    "a behind compare answer refutes"
  printf 'OPEN\tfalse\t%s\tfm/t1\n' "$head" > "$FAKE/gh-pr-view"
  status "working: opened https://github.com/x/y/pull/3"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pr-opened unverifiable line=$ln: PR https://github.com/x/y/pull/3 is not on origin's repository o/r" \
    "a PR on another repository is not the task's"
  status "working: opened https://github.com/O/R/pull/6"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pr-opened verified line=$ln: PR https://github.com/O/R/pull/6 exists (OPEN) on fm/t1" \
    "the repository match ignores case"
  pass "a GitHub origin's branch head, 404s, merged-PR stand-in, compare answers, and repository binding are judged"
}

test_dirty_check_survives_trailing_lines() {
  local out
  setup_task dirty local-only
  commit_work a.txt >/dev/null
  status "done: ready on fm/t1"
  status "resolved [key=other]: answered"
  status "note: firstmate read the report"
  printf 'stray\n' > "$WT/stray.txt"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " committed refuted line=1: the local copy has 1 uncommitted path(s)" \
    "a supervisor line after the done: switched off the clean-copy check"
  pass "the clean-copy check follows the newest mate line, not any writer's line"
}

test_reopen_skipped_after_a_newer_mate_line() {
  local out rc
  setup_task reopen-skip direct-PR
  printf 'GraphQL: Could not resolve to a PullRequest with the number of 9.\n' > "$FAKE/gh-pr-view.err"
  status "working: opened https://github.com/o/r/pull/9"
  out=$(FAKE_GH_APPEND_FILE="$ST/t1.status" FAKE_GH_APPEND="done: PR https://github.com/o/r/pull/10 ready for review" \
    claims "$T0" scan t1); rc=$?
  expect_code 3 "$rc" "the refuted verdict is still the scan's result"
  assert_contains "$out" " pr-opened refuted line=1:" "the claim is refuted"
  if grep -q '\[key=claim-refuted-' "$ST/t1.status"; then
    fail "a blocker landed after the mate's newer done: line: $(cat "$ST/t1.status")"
  fi
  assert_equals "skipped null" "$(jq -r '"\(.reopen) \(.reopen_key)"' "$DT/failure-classes/claim-refuted-pr-opened.jsonl")" \
    "the occurrence records the skipped reopen"
  pass "a mate line written during the scan skips the reopen and the occurrence says so"
}

test_reconcile_finishes_withheld_consequences() {
  local id id2 out rc fc
  setup_task reconcile local-only
  status "working: committed deadbeef1 with the fix"
  claims "$T0" scan t1 >/dev/null
  id=$(rec committed .id)
  fc="$DT/failure-classes/claim-refuted-committed.jsonl"
  rm -f "$fc"
  claims "$T0" scan t1 >/dev/null; rc=$?
  expect_code 0 "$rc" "a reconciling scan with nothing new exits 0"
  assert_equals "$id opened" "$(jq -r '"\(.claim_id) \(.reopen)"' "$fc")" "the missing occurrence was not rewritten"
  [ "$(grep -cF "[key=claim-refuted-$id]" "$ST/t1.status")" = 1 ] || fail "reconcile appended a second blocker"
  status "working: committed cafebabe2 too"
  chmod 444 "$ST/t1.status"
  if [ -w "$ST/t1.status" ]; then
    chmod 644 "$ST/t1.status"
    pass "a missing occurrence is rewritten (write protection is not enforced for this user)"
    return
  fi
  out=$(claims "$T0" scan t1 2>&1); rc=$?
  chmod 644 "$ST/t1.status"
  expect_code 1 "$rc" "a scan that cannot append the blocker fails"
  assert_contains "$out" "could not append the blocker" "the failure is named"
  id2=$(rec committed .id)
  if grep -qF "$id2" "$fc"; then
    fail "the occurrence was written without its blocker"
  fi
  claims "$T0" scan t1 >/dev/null; rc=$?
  expect_code 0 "$rc" "the reconciling scan succeeds"
  grep -qF "[key=claim-refuted-$id2]" "$ST/t1.status" || fail "reconcile did not append the withheld blocker"
  grep -qF "\"claim_id\":\"$id2\"" "$fc" || fail "reconcile did not write the withheld occurrence"
  pass "a failed blocker append withholds the occurrence, and the next scan finishes both"
}

test_new_spawn_generation_judges_again() {
  local id
  setup_task gen local-only
  status "working: committed deadbeef1 with the fix"
  claims "$T0" scan t1 >/dev/null
  id=$(rec committed .id)
  meta_set spawn_gen s2
  claims "$T0" scan t1 >/dev/null
  assert_equals 2 "$(kind_count committed)" "a new launch generation did not judge the line again"
  [ "$(rec committed .id)" != "$id" ] || fail "the claim id ignores the launch generation"
  assert_equals s2 "$(rec committed .spawn_gen)" "the new record names the new generation"
  pass "a reused task id under a new launch generation gets new claim ids"
}

fm_test_run \
  test_committed_verified_record_shape \
  test_refuted_claim_reopens_and_records_failure_class \
  test_clear_closes_only_an_open_blocker \
  test_hedges_tokens_and_verifier_lines \
  test_pushed_against_the_remote_branch \
  test_rewritten_history_is_unverifiable \
  test_pr_and_tests_through_the_forge \
  test_pr_binding_and_states \
  test_tests_green_from_no_mistakes_and_agentkit \
  test_unverifiable_retries_and_timeouts \
  test_order_rules_and_agentkit \
  test_alive_endpoint_output_and_steers \
  test_secret_shaped_text_is_redacted \
  test_refusals_and_usage \
  test_promoted_and_scout_done_lines_are_not_ship_claims \
  test_custody_alone_never_verifies_a_push \
  test_github_origin_remote_head_and_compare \
  test_dirty_check_survives_trailing_lines \
  test_reopen_skipped_after_a_newer_mate_line \
  test_reconcile_finishes_withheld_consequences \
  test_new_spawn_generation_judges_again
