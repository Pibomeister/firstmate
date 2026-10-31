#!/usr/bin/env bash
# tests/fm-claims.test.sh - bin/fm-claims.sh reads claims only from a task's
# status log, judges each against real git repositories and stubbed forge,
# no-mistakes, AgentKit, tmux, and lsof tools, appends one ledger record per
# verdict, and turns a refuted verdict into a reopening blocker and a
# failure-class occurrence. docs/claim-ledger.md owns the record contract these
# cases read back.
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

commit_work() {  # <file> -> echoes the new HEAD
  printf 'change %s\n' "$RANDOM" > "$WT/$1"
  git -C "$WT" add "$1"
  git -C "$WT" commit -qm "work on $1"
  git -C "$WT" rev-parse HEAD
}

status() {  # <line>
  printf '%s\n' "$1" >> "$ST/t1.status"
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
  out=$(claims "$T0" scan t1); rc=$?
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

test_hedged_and_reserved_lines_are_not_claims() {
  setup_task hedge local-only
  status "working: will push once the tests pass"
  status "working: tests are not passing yet"
  status "working: pending-reply-answer: pushed deadbeef1 and tests passed"
  status "paused: claim-refuted-reopen: committed deadbeef1 claim at line 1 is false"
  claims "$T0" scan t1 >/dev/null
  [ "$(ledger_lines)" = 0 ] || fail "hedged or reserved lines produced claims: $(cat "$ST/t1.claims.jsonl")"
  pass "hedged lines and supervisor-token lines yield no claim"
}

test_pushed_against_the_remote_branch() {
  local head out
  setup_task pushed local-only
  head=$(commit_work a.txt)
  status "working: pushed ${head:0:9} for review"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pushed refuted line=1: origin has no branch fm/t1" "an unpushed branch is refuted"
  assert_equals git-ls-remote "$(rec pushed .checker)" "a non-GitHub origin is read with git ls-remote"
  git -C "$WT" push -q origin fm/t1 2>/dev/null || fail "fixture: push failed"
  head=$(commit_work b.txt)
  status "working: pushed ${head:0:9} too"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pushed refuted line=3: origin/fm/t1 at " "a commit beyond the remote head is refuted"
  git -C "$WT" push -q origin fm/t1 2>/dev/null || fail "fixture: second push failed"
  status "working: pushed again"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pushed verified line=5: origin/fm/t1 at ${head:0:12} contains ${head:0:12}" "a pushed HEAD is verified"
  pass "a pushed claim is checked against the remote branch head"
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

test_tests_green_from_no_mistakes_and_agentkit() {
  local head out
  setup_task nm no-mistakes
  head=$(commit_work a.txt)
  printf 'run:\n  id: r1\n  branch: fm/t1\n  head_sha: %s\n  status: completed\n  outcome: passed\n' "$head" > "$FAKE/nm-status"
  status "working: the suite passed locally"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green verified line=1: the no-mistakes run at ${head:0:12} passed (passed)" "a passed run at HEAD verifies"
  printf 'run:\n  id: r1\n  branch: fm/t1\n  head_sha: %s\n  status: completed\n  outcome: failed\n' "$head" > "$FAKE/nm-status"
  status "working: tests passed after the retry"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green refuted line=2: the no-mistakes run at ${head:0:12} failed" "a failed run at HEAD refutes"
  rm -f "$FAKE/nm-status"
  : > "$FAKE/ak-gate.mjs"
  printf '%s\n' "$FAKE/ak-gate.mjs" > "$H/config/agentkit-gate"
  printf '{"ok":true,"head":{"revision":"%s"}}\n' "$head" > "$FAKE/ak-json"
  status "working: tests pass now"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green verified line=4: AgentKit verify gate is current at ${head:0:12}" "a current AgentKit verify gate verifies"
  pass "tests-green falls back to the no-mistakes run and then to the AgentKit verify gate"
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
  pass "unverifiable claims retry after the interval, and a hung read is bounded and unverifiable"
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
  pass "order claims check the recognized rules and need a current AgentKit gate for the rest"
}

test_alive_endpoint_output_and_steers() {
  local out marker
  setup_task alive local-only
  marker="$ST/.hash-fm_fm-t1"
  : > "$marker"
  fm_touch_epoch $((T0 - 60)) "$marker"
  status "working: still at it"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " alive verified line=1: terminal output changed 60s ago" "fresh output verifies"
  out=$(claims $((T0 + 30)) scan t1)
  [ -z "$out" ] || fail "an unchanged alive verdict was recorded again: $out"
  printf 'p1\nn/elsewhere\n' > "$FAKE/lsof"
  out=$(claims $((T0 + 5000)) scan t1)
  assert_contains "$out" " alive refuted line=1: no terminal output for 5060s and 0% CPU in the local copy" "stale output with no CPU refutes"
  assert_equals 2 "$(rec alive .attempt)" "the changed verdict is the second record"
  mkdir -p "$ST/t1.inbox"
  printf 'hello\n' > "$ST/t1.inbox/001.msg"
  fm_touch_epoch $((T0 - 2000)) "$ST/t1.inbox/001.msg"
  : > "$marker"
  fm_touch_epoch "$T0" "$marker"
  status "working: back again"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " alive refuted line=" "an unread steer refutes even with fresh output"
  assert_contains "$out" "steering message 001.msg has been unread for 2000s" "the refutation names the steer"
  rm -rf "$ST/t1.inbox"
  : > "$FAKE/tmux-missing"
  status "paused: waiting on review"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " alive refuted line=5: the agent's endpoint (tmux) is gone" "a dead endpoint refutes"
  pass "alive is judged from the endpoint, terminal output age, CPU, and unread steers, recorded only on change"
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
  pass "secret-shaped tokens in claim text are redacted in the ledger"
}

test_refusals_and_usage() {
  local out rc
  setup_task refuse local-only
  out=$(claims "$T0" scan 'bad/id' 2>&1); rc=$?
  expect_code 1 "$rc" "a malformed task id refuses"
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

fm_test_run \
  test_committed_verified_record_shape \
  test_refuted_claim_reopens_and_records_failure_class \
  test_clear_closes_only_an_open_blocker \
  test_hedged_and_reserved_lines_are_not_claims \
  test_pushed_against_the_remote_branch \
  test_pr_and_tests_through_the_forge \
  test_tests_green_from_no_mistakes_and_agentkit \
  test_unverifiable_retries_and_timeouts \
  test_order_rules_and_agentkit \
  test_alive_endpoint_output_and_steers \
  test_secret_shaped_text_is_redacted \
  test_refusals_and_usage
