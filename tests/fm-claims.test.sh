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
  # FAKE_LSOF_SLEEP: lsof prints its answer, then hangs.
  cat > "$fb/lsof" <<'SH'
#!/usr/bin/env bash
[ -f "${FM_FAKE_DIR:?}/lsof" ] || exit 1
cat "$FM_FAKE_DIR/lsof"
[ -z "${FAKE_LSOF_SLEEP:-}" ] || sleep "$FAKE_LSOF_SLEEP"
SH
  # ps answers a CPU read from $FM_FAKE_DIR/ps and passes every other call on.
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" %cpu= "*) if [ -f "${FM_FAKE_DIR:-}/ps" ]; then cat "$FM_FAKE_DIR/ps"; exit 0; fi ;;
esac
exec /bin/ps "$@"
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

# <epoch> dates the commit and its branch reflog entry; the default sits
# before every claim a case stamps, whatever the real clock reads. The commit
# is reworded until its 9-character abbreviation holds a letter and a digit,
# the shape the extractor reads as a sha.
commit_work() {  # <file> [<epoch>] -> echoes the new HEAD
  local when="@${2:-$((T0 - 1000))} +0000" n=0 abbr
  printf 'change %s %s\n' "$1" "$(git -C "$WT" rev-list --count HEAD)" > "$WT/$1"
  git -C "$WT" add "$1"
  GIT_COMMITTER_DATE="$when" GIT_AUTHOR_DATE="$when" git -C "$WT" commit -qm "work on $1"
  abbr=$(git -C "$WT" rev-parse HEAD | cut -c1-9)
  while ! { printf '%s' "$abbr" | grep -q '[a-f]' && printf '%s' "$abbr" | grep -q '[0-9]'; }; do
    n=$((n + 1))
    GIT_COMMITTER_DATE="$when" GIT_AUTHOR_DATE="$when" git -C "$WT" commit -q --amend -m "work on $1 ($n)"
    abbr=$(git -C "$WT" rev-parse HEAD | cut -c1-9)
  done
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

# The monitor's poll count for t1's window, which it writes on every
# successful capture, dated <epoch>.
polled() {  # <epoch>
  : > "$ST/.count-fm_fm-t1"
  fm_touch_epoch "$1" "$ST/.count-fm_fm-t1"
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
  local head base out rc id
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
  base=$(git -C "$WT" rev-parse HEAD~1)
  status "working: committed $base earlier"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " committed unverifiable line=2: commit ${base:0:12} is already in the base branch, so it is not shown to be the task's own" \
    "a free-text claim about a base commit is not the task's own work"
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
  status "working: adding tests, passing the flag through"
  status "working: testing the green path"
  status "working: writing tests that pass against the fixtures"
  status "working: the cipher suite is green"
  status "working: pushed back on the reviewer's commit message nit"
  status "working: pushed back on renaming the branch"
  status "working: confirmed CI is green on main"
  status "working: committed 0123456789abcdef from the ledger"
  status "working: claim-refuted-reopen: committed deadbeef1 with the fix"
  ln=$(last_line)
  status "blocked [at=$T0] [key=claim-refuted-0123456789abcdef]: claim-refuted-reopen: committed claim at line 9 is false"
  claims "$T0" scan t1 >/dev/null
  assert_equals "refuted $ln" "$(rec committed '"\(.verdict) \(.evidence.line)"')" "a reserved token exempted a claim"
  assert_equals "$ln" "$(rec alive .evidence.line)" "the verifier's own blocker became the newest mate line"
  assert_equals 2 "$(ledger_lines)" "hedged, sha-less, cue-less, void, or contrary lines produced claims: $(cat "$ST/t1.claims.jsonl")"
  pass "hedges, non-sha words, claim-id tokens, void and cue-less pushes, test words that are not a result, and contrary words yield no claim; a reserved token exempts nothing"
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
  git -C "$WT" remote set-url origin "$H/nowhere.git"
  status "working: pushed ${c:0:9} to origin, retry 2"
  ln=$(last_line)
  out=$(claims $((T0 + 300)) scan t1)
  assert_contains "$out" " pushed unverifiable line=$ln: origin's branch fm/t1 could not be read" \
    "an origin that cannot be read is unverifiable"

  setup_task pushed-gate no-mistakes
  commit_work a.txt >/dev/null
  status "working [at=$T0]: pushed fm/t1 to the no-mistakes gate"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pushed unverifiable line=1: origin has no branch fm/t1; the push may have gone to the no-mistakes gate or a review server" \
    "a push to the no-mistakes gate is not refuted by origin's missing branch"
  status "working [at=$T0]: pushed fm/t1 to origin"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pushed refuted line=2: origin has no branch fm/t1" "a push named to origin is still refuted"
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
  local head url out ln
  setup_task forge direct-PR
  head=$(commit_work a.txt)
  git -C "$WT" push -q origin fm/t1 2>/dev/null
  url=https://github.com/o/r/pull/7
  meta_set pr "$url"
  printf 'OPEN\ttrue\t%s\tfm/t1\n' "$head" > "$FAKE/gh-pr-view"
  status "done: PR $url ready for review"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pr-ready refuted line=1: PR $url is still a draft" "a draft PR is refuted"
  assert_contains "$out" " pushed verified line=1:" "the direct-PR done is also a pushed claim"
  printf 'OPEN\tfalse\t%s\tfm/t1\n' "$head" > "$FAKE/gh-pr-view"
  printf '3\t0\t0\n' > "$FAKE/gh-pr-checks"
  status "working [at=$T0]: PR $url opened; tests pass on it"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pr-opened verified line=3: PR $url exists (OPEN) on fm/t1" "an existing PR is verified"
  assert_contains "$out" " tests-green verified line=3: all 3 check(s) passed on PR $url" "passing checks verify"
  printf '2\t1\t0\n' > "$FAKE/gh-pr-checks"
  status "working [at=$T0]: CI is green on $url"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green refuted line=4: 1 check(s) failed or were cancelled" "a failed check refutes"
  status "working [at=$T0]: fixed the parser bug, all tests pass"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green unverifiable line=$ln: 1 check(s) failed on PR $url, but the claim may describe a local run" \
    "failed PR checks do not refute a claim that names no CI, checks or PR"
  printf 'GraphQL: Could not resolve to a PullRequest with the number of 9.\n' > "$FAKE/gh-pr-view.err"
  status "working: opened https://github.com/o/r/pull/9"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pr-opened refuted line=$ln: the forge has no PR https://github.com/o/r/pull/9" "a missing PR is refuted"
  rm -f "$FAKE/gh-pr-view.err"
  printf 'OPEN\tfalse\t%s\tfm/t1\n' "$head" > "$FAKE/gh-pr-view"
  status "done: PR $url ready for review"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pr-ready verified line=$ln: PR $url is open and ready at ${head:0:12}" "an open, ready PR at the branch head verifies"
  printf '1\t0\t2\n' > "$FAKE/gh-pr-checks"
  status "working [at=$T0]: CI checks are green on $url"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green unverifiable line=$ln: 2 check(s) still pending on PR $url" "pending checks do not verify"
  printf '0\t0\t0\n' > "$FAKE/gh-pr-checks"
  status "working [at=$T0]: CI is green for $url"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green unverifiable line=$ln: no check, no-mistakes run, or AgentKit verify gate confirms it" \
    "a PR with no checks does not verify"
  pass "PR and test claims are judged from gh pr view and gh pr checks"
}

test_pr_binding_and_states() {
  local head url base out ln
  setup_task prbind direct-PR
  head=$(commit_work a.txt)
  base=$(git -C "$WT" rev-parse HEAD~1)
  git -C "$WT" push -q origin fm/t1 2>/dev/null || fail "fixture: push failed"
  url=https://github.com/o/r/pull/7
  meta_set pr "$url"
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
  printf 'OPEN\tfalse\t%s\tfm/t1\n' "$base" > "$FAKE/gh-pr-view"
  status "working [at=$T0]: $url is ready for review"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pr-ready refuted line=$ln: PR $url is at ${base:0:12}, which does not contain the claimed head ${head:0:12}" \
    "a direct-PR claim needs the PR head to contain the branch head at the claim's time"
  status "working: $url is ready for review again"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pr-ready unverifiable line=$ln: the branch head at the claim's time could not be read" \
    "an unstamped free-text ready claim has no head to compare"
  url=https://github.com/o/r/pull/8
  printf 'OPEN\tfalse\t%s\tother-branch\n' "$head" > "$FAKE/gh-pr-view"
  printf '3\t0\t0\n' > "$FAKE/gh-pr-checks"
  status "working: opened $url"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pr-opened unverifiable line=$ln: PR $url is on branch other-branch, not the task branch fm/t1, so the claim is not about the task's PR" \
    "a free-text claim about another branch's PR is unverifiable"
  rm -f "$FAKE/gh.calls"
  status "working [at=$T0]: tests pass on $url"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green unverifiable line=$ln: PR $url is on branch other-branch, not the task branch fm/t1, so the claim is not about the task's PR" \
    "another PR's checks do not verify the task's tests"
  if grep -q '^pr checks' "$FAKE/gh.calls" 2>/dev/null; then
    fail "another PR's checks were read for the task's claim: $(cat "$FAKE/gh.calls")"
  fi
  status "done: PR $url ready for review"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pr-ready refuted line=$ln: PR $url is on branch other-branch, not the task branch fm/t1" \
    "a done: claim about another branch's PR is refuted"

  setup_task prbind-noref direct-PR
  head=$(commit_work a.txt)
  printf 'OPEN\tfalse\t%s\tfm/t1\n' "$head" > "$FAKE/gh-pr-view"
  status "done: PR https://github.com/x/y/pull/3 ready for review"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pr-ready unverifiable line=1: no recorded PR and no GitHub origin show whether PR https://github.com/x/y/pull/3 is the task's" \
    "with no recorded PR and a non-GitHub origin, a PR on the task branch is not taken as the task's"
  pass "PR claims bind to the task's PR and judge closed, merged, draft, and head state"
}

test_tests_green_from_no_mistakes_and_agentkit() {
  local head old out ln url
  setup_task nm no-mistakes
  head=$(commit_work a.txt)
  nm_run passed "$head" completed pending
  status "working [at=$T0]: the test suite passed"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green verified line=$ln: the no-mistakes run at ${head:0:12} passed (passed)" "a passed run at the claim's head verifies"
  nm_run failed "$head" failed pending
  status "working [at=$T0]: tests passed after the retry"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green refuted line=$ln: the no-mistakes run at ${head:0:12} failed its test step" "a failed test step refutes"
  nm_run failed "$head" completed pending failed
  status "working [at=$T0]: all tests green now"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green unverifiable line=$ln:" "a run that failed only its push neither verifies nor refutes"
  nm_run passed-with-override "$head" completed completed
  status "working [at=$T0]: checks are green"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green unverifiable line=$ln:" "an overridden run never verifies"
  status "working: tests pass on the branch"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green unverifiable line=$ln: the branch head at the claim's time could not be read" \
    "an unstamped free-text claim has no head to judge"

  old=$head
  nm_run passed "$old" completed completed
  head=$(commit_work b.txt $((T0 - 500)))
  status "working [at=$T0]: tests passed"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green unverifiable line=$ln: no check, no-mistakes run, or AgentKit verify gate confirms it; no AgentKit gate is configured" \
    "a passed run at an older head does not verify a claim about a newer one"
  url=https://github.com/o/r/pull/7
  meta_set pr "$url"
  status "done: PR $url checks green"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_not_contains "$out" " tests-green verified line=$ln:" "a passed run at an older head verified a done: report"
  assert_contains "$out" " tests-green unverifiable line=$ln:" "a done: report with a stale run is unverifiable"

  rm -f "$FAKE/nm-status"
  : > "$FAKE/ak-gate.mjs"
  printf '%s\n' "$FAKE/ak-gate.mjs" > "$H/config/agentkit-gate"
  printf '{"ok":true,"head":{"revision":"%s"},"refusals":[],"notes":[]}\n' "$head" > "$FAKE/ak-json"
  status "working [at=$T0]: tests pass now"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green verified line=$ln: AgentKit verify gate is current at ${head:0:12}" "a current AgentKit verify gate verifies"
  printf '{"ok":true,"head":{"revision":"%s"},"refusals":[],"notes":["marker-only record: history, not proof"]}\n' "$head" > "$FAKE/ak-json"
  status "working [at=$T0]: the test suite is green"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green unverifiable line=$ln:" "a gate answer with notes does not verify"
  assert_contains "$out" "carries notes, so it is not proof" "the reason names the notes"
  printf '{"ok":true,"head":{"revision":"%s"},"refusals":[],"notes":[]}\n' "$old" > "$FAKE/ak-json"
  status "working [at=$T0]: unit tests pass"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green unverifiable line=$ln:" "a gate current at an older revision does not verify"
  assert_contains "$out" "AgentKit verify gate is not current at ${head:0:12}" "the reason names the stale gate"
  printf '{"ok":false,"head":{"revision":"%s"},"refusals":["refused: gate verify has no current evidence"],"notes":[]}\n' "$head" > "$FAKE/ak-json"
  status "working [at=$T0]: integration tests pass"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " tests-green unverifiable line=$ln:" "a refusing gate does not verify"
  assert_contains "$out" "AgentKit verify gate is not current at ${head:0:12}" "the reason names the refusal"
  pass "tests-green reads the no-mistakes test and ci steps, then a note-free AgentKit verify gate, each only at the claim's head"
}

test_unverifiable_retries_and_timeouts() {
  local out start elapsed id
  setup_task retry direct-PR
  commit_work a.txt >/dev/null
  meta_set pr https://github.com/o/r/pull/7
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
  id=$(rec pr-opened .id)
  out=$(claims $((T0 + 301)) show t1)
  assert_contains "$out" "$id"$'\t'"verified"$'\t'"pr-opened"$'\t'"line=1"$'\t'"attempt=2"$'\t'"gh-pr-view" \
    "show prints each claim's newest verdict"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -cF "$id")" "show prints one line per claim"
  assert_not_contains "$(printf '%s\n' "$out" | grep -F "$id")" "attempt=1" "show printed a superseded verdict"

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
  local out marker id ln start elapsed
  setup_task alive local-only
  marker="$ST/.hash-fm_fm-t1"
  : > "$marker"
  fm_touch_epoch $((T0 - 60)) "$marker"
  beat "$T0"
  polled "$T0"
  status "working: still at it"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " alive verified line=1: terminal output changed 60s ago" "fresh output verifies"
  out=$(claims $((T0 + 30)) scan t1)
  [ -z "$out" ] || fail "an unchanged alive verdict was recorded again: $out"
  printf 'p1\nn/elsewhere\n' > "$FAKE/lsof"
  beat $((T0 + 5000))
  polled $((T0 + 5000))
  out=$(claims $((T0 + 5000)) scan t1)
  assert_contains "$out" " alive refuted line=1: no terminal output for 5060s and 0% CPU in the local copy" "stale output with no CPU refutes"
  assert_equals 2 "$(rec alive .attempt)" "the changed verdict is the second record"
  id=$(rec alive .id)
  decision_open "claim-refuted-$id" || fail "the refuted alive claim did not reopen the task"
  fm_touch_epoch $((T0 + 5100)) "$marker"
  beat $((T0 + 5100))
  polled $((T0 + 5100))
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

  setup_task alive-cpu local-only
  marker="$ST/.hash-fm_fm-t1"
  : > "$marker"
  fm_touch_epoch $((T0 - 5000)) "$marker"
  beat "$T0"
  polled "$T0"
  printf 'p4242\nn%s/src\n' "$WT" > "$FAKE/lsof"
  printf '40.0\n2.0\n' > "$FAKE/ps"
  status "working: grinding through the build"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " alive verified line=1: processes in the local copy use 42.0% CPU" \
    "CPU used inside the local copy verifies an agent whose output is stale"
  printf '0.3\n' > "$FAKE/ps"
  out=$(claims $((T0 + 10)) scan t1)
  assert_contains "$out" " alive refuted line=1: no terminal output for 5010s and 0.3% CPU in the local copy" \
    "stale output and CPU below the threshold refute"
  status "paused: waiting on review"
  ln=$(last_line)
  out=$(claims $((T0 + 20)) scan t1)
  assert_contains "$out" " alive verified line=$ln: the paused agent is still present" \
    "a process in the local copy shows a paused agent is present"

  setup_task alive-hang local-only
  marker="$ST/.hash-fm_fm-t1"
  : > "$marker"
  fm_touch_epoch $((T0 - 5000)) "$marker"
  beat "$T0"
  polled "$T0"
  printf 'p4242\nn%s/src\n' "$WT" > "$FAKE/lsof"
  printf '0.0\n' > "$FAKE/ps"
  status "working: still going"
  start=$(date +%s)
  out=$(FAKE_LSOF_SLEEP=30 NET_TIMEOUT=1 claims "$T0" scan t1)
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 20 ] || fail "a hung process listing was not bounded (${elapsed}s)"
  assert_contains "$out" " alive unverifiable line=1: terminal output age or CPU use could not be read" \
    "a process listing that hangs is unverifiable, not 0% CPU"

  setup_task alive-nocount local-only
  marker="$ST/.hash-fm_fm-t1"
  : > "$marker"
  fm_touch_epoch $((T0 - 60)) "$marker"
  beat "$T0"
  status "working: on it"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " alive unverifiable line=1: terminal output age or CPU use could not be read" \
    "an output marker the monitor is not polling is not read as output age"
  pass "alive is judged from the endpoint, fresh polled output, bounded CPU reads in the copy, and unread steers, and closes its own blocker"
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
  status "working: opened https://user:hunter2@github.com/o/r/pull/9"
  claims "$T0" scan t1 >/dev/null
  if grep -q hunter2 "$ST/t1.claims.jsonl"; then
    fail "credentials in a PR URL reached the ledger"
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
  out=$(claims "$T0" show nosuch 2>&1); rc=$?
  expect_code 1 "$rc" "show of a task with neither status log nor metadata refuses"
  assert_contains "$out" "has neither a status log nor metadata" "the show refusal names the cause"
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

  setup_task promoted-legacy no-mistakes
  status "done [at=$((T0 - 100))]: committed deadbeef1 for the report"
  printf 'ship\n' > "$DT/t1/ship-instructions.md"
  fm_touch_epoch $((T0 - 50)) "$DT/t1/ship-instructions.md"
  status "working [at=$T0]: building the change now"
  claims "$T0" scan t1 >/dev/null
  assert_equals 0 "$(kind_count committed)" "a scout done: line from before an unrecorded promotion was read as a claim"

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
  printf 'gh: Server Error (HTTP 502)\n' > "$FAKE/gh-ref.err"
  status "working: pushed ${head:0:9} to origin, retry 2"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pushed unverifiable line=$ln: origin's branch fm/t1 could not be read" \
    "a server error on the branch read is unverifiable"
  printf 'gh: Not Found (HTTP 404)\n' > "$FAKE/gh-ref.err"
  printf 'OPEN\tfalse\t%s\tfm/t1\n' "$head" > "$FAKE/gh-pr-view"
  status "working: opened https://github.com/x/y/pull/3"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pr-opened unverifiable line=$ln: PR https://github.com/x/y/pull/3 is not on origin's repository o/r, so the claim is not about the task's PR" \
    "with no recorded PR, a PR on another repository than origin's is not the task's"
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
  status "working: opened https://github.com/x/y/pull/4"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pr-opened unverifiable line=$ln: PR https://github.com/x/y/pull/4 is not on the recorded PR's repository o/r, so the claim is not about the task's PR" \
    "a PR on another repository than the recorded PR's is not the task's"
  status "working: opened https://github.com/O/R/pull/6"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pr-opened verified line=$ln: PR https://github.com/O/R/pull/6 exists (OPEN) on fm/t1" \
    "the repository match ignores case"
  rm -f "$FAKE/gh.calls"
  status "working: pushed ${head:0:9} to origin (1)"
  status "working: pushed ${head:0:9} to origin (2)"
  status "working: pushed ${head:0:9} to origin (3)"
  claims "$T0" scan t1 >/dev/null
  assert_equals 1 "$(grep -c '/git/ref/heads/' "$FAKE/gh.calls")" "one scan read origin's branch more than once"
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

  setup_task reopen-working direct-PR
  printf 'GraphQL: Could not resolve to a PullRequest with the number of 9.\n' > "$FAKE/gh-pr-view.err"
  status "working: opened https://github.com/o/r/pull/9"
  FAKE_GH_APPEND_FILE="$ST/t1.status" FAKE_GH_APPEND="working: still on it" claims "$T0" scan t1 >/dev/null
  grep -q '\[key=claim-refuted-' "$ST/t1.status" || fail "a working: line written during the scan skipped the blocker: $(cat "$ST/t1.status")"
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

test_claim_ids_follow_the_status_log() {
  local id out
  setup_task gen local-only
  status "working [at=$((T0 - 100))]: starting"
  status "working: committed deadbeef1 with the fix"
  claims "$T0" scan t1 >/dev/null
  id=$(rec committed .id)
  meta_set spawn_gen s2
  out=$(claims "$T0" scan t1)
  [ -z "$out" ] || fail "a new launch generation judged a recorded claim again: $out"
  assert_equals 1 "$(kind_count committed)" "a new launch generation added a record"
  printf '%s\n' "working [at=$((T0 - 50))]: starting" "working: committed deadbeef1 with the fix" > "$ST/t1.status"
  claims "$T0" scan t1 >/dev/null
  assert_equals 2 "$(kind_count committed)" "a replaced status log did not judge its claims again"
  [ "$(rec committed .id)" != "$id" ] || fail "the same line in a replaced status log kept its claim id"
  assert_equals s2 "$(rec committed .spawn_gen)" "the new record names the launch generation"
  pass "claim ids follow the status log's first line, so a replaced log gets new ids and a new launch generation alone does not"
}

# The kinds recorded for <line>, sorted and space-separated.
line_kinds() {  # <line>
  jq -r --argjson l "$1" 'select(.evidence.line == $l) | .kind' "$ST/t1.claims.jsonl" | sort -u | paste -sd' ' -
}

test_done_arms_by_mode_and_forge() {
  local head url out
  setup_task arm-ci no-mistakes
  head=$(commit_work a.txt)
  url=https://github.com/o/r/pull/7
  meta_set pr "$url"
  status "done: PR $url checks green"
  claims "$T0" scan t1 >/dev/null
  assert_equals "order pr-ready pushed tests-green" "$(line_kinds 1)" "a CI-ready done: carries the push, PR, tests, and order claims"

  setup_task arm-gerrit no-mistakes
  commit_work a.txt >/dev/null
  meta_set forge gerrit
  status "done: PR #12 published for review"
  out=$(claims "$T0" scan t1)
  assert_equals "order pushed" "$(line_kinds 1)" "a published-change done: carries the push and order claims"
  assert_contains "$out" " pushed unverifiable line=1: the custody gate could not confirm the change on its review server" \
    "a review-server done: the custody gate refuses is unverifiable"

  setup_task arm-direct direct-PR
  commit_work a.txt >/dev/null
  git -C "$WT" push -q origin fm/t1 2>/dev/null || fail "fixture: push failed"
  status "done: pushed fm/t1"
  out=$(claims "$T0" scan t1)
  assert_equals "order pushed" "$(line_kinds 1)" "a direct-PR done: with no PR carries the push and order claims"
  assert_contains "$out" " pushed verified line=1:" "a pushed direct-PR branch verifies"

  setup_task arm-external direct-PR
  commit_work a.txt >/dev/null
  git -C "$WT" push -q origin fm/t1 2>/dev/null || fail "fixture: push failed"
  meta_set forge external
  status "done: review https://review.example.com/r/42 uploaded for review"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " pushed unverifiable line=1:" "an external review report is unverifiable"
  assert_not_contains "$out" " pushed verified" "an external review report verified a push"
  pass "each done: report carries the claims its mode and forge define, and a review server the gate cannot read never verifies"
}

test_order_rule_outcomes() {
  local head old url out ln
  setup_task rule-clean local-only
  printf '%s\n' "Leave the worktree clean." > "$DT/t1/brief.md"
  head=$(commit_work a.txt)
  : > "$FAKE/ak-gate.mjs"
  printf '%s\n' "$FAKE/ak-gate.mjs" > "$H/config/agentkit-gate"
  printf '{"ok":true,"head":{"revision":"%s"},"refusals":[],"notes":[]}\n' "$head" > "$FAKE/ak-json"
  status "done: ready on fm/t1"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " order verified line=1: order rules hold (clean-worktree)" "a clean local copy holds the rule"
  printf 'stray\n' > "$WT/stray.txt"
  status "done: ready again"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " order refuted line=2: broke an order rule - clean-worktree: the local copy has 1 uncommitted path(s)" \
    "an uncommitted path breaks the rule"

  setup_task rule-branch local-only
  printf '%s\n' "Work on the ship branch only." > "$DT/t1/brief.md"
  commit_work a.txt >/dev/null
  git -C "$WT" checkout -q -b elsewhere
  status "done: ready"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " order refuted line=1: broke an order rule - ship-branch: the local copy is on elsewhere, not the ship branch fm/t1" \
    "a local copy on another branch breaks the rule"

  setup_task rule-after-run no-mistakes
  printf '%s\n' "Commit nothing after the run." > "$DT/t1/brief.md"
  old=$(commit_work a.txt)
  nm_run passed "$old" completed completed
  commit_work b.txt >/dev/null
  url=https://github.com/o/r/pull/7
  meta_set pr "$url"
  status "done: PR $url checks green"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " order refuted line=1: broke an order rule - commit-nothing-after-run: HEAD has 1 commit(s) after the no-mistakes run head ${old:0:12}" \
    "a commit after the run breaks the rule"

  setup_task rule-merged local-only
  printf '%s\n' "Never push to the default branch." > "$DT/t1/brief.md"
  head=$(commit_work a.txt)
  git -C "$WT" push -q origin fm/t1:main 2>/dev/null || fail "fixture: push to the default branch failed"
  url=https://github.com/o/r/pull/7
  meta_set pr "$url"
  printf 'MERGED\tfalse\t%s\tfm/t1\n' "$head" > "$FAKE/gh-pr-view"
  status "done: landed"
  out=$(claims "$T0" scan t1)
  assert_not_contains "$out" "no-default-push" "a merged PR did not exempt the default branch's copy of HEAD"
  assert_contains "$out" " order unverifiable line=1: no AgentKit gate is configured" "the exempt rule leaves only the gate"

  setup_task rule-version local-only
  printf '%s\n' "Do not bump a version." > "$DT/t1/brief.md"
  commit_work a.txt >/dev/null
  printf '0.2.0\n' > "$WT/VERSION"
  git -C "$WT" add VERSION
  GIT_COMMITTER_DATE="@$((T0 - 900)) +0000" GIT_AUTHOR_DATE="@$((T0 - 900)) +0000" git -C "$WT" commit -qm "version"
  status "done: ready"
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " order refuted line=1: broke an order rule - no-version-bump: VERSION changed" "a changed VERSION file breaks the rule"
  git -C "$WT" rm -q VERSION
  printf '[package]\nname = "x"\nversion = "0.2.0"\n' > "$WT/Cargo.toml"
  git -C "$WT" add Cargo.toml
  GIT_COMMITTER_DATE="@$((T0 - 800)) +0000" GIT_AUTHOR_DATE="@$((T0 - 800)) +0000" git -C "$WT" commit -qm "cargo"
  status "done: ready again"
  ln=$(last_line)
  out=$(claims "$T0" scan t1)
  assert_contains "$out" " order refuted line=$ln: broke an order rule - no-version-bump: the version field in Cargo.toml changed" \
    "a changed Cargo.toml version field breaks the rule"
  pass "the clean-copy, ship-branch, commit-after-run, default-branch, and version rules hold or break as their briefs say"
}

test_one_tests_claim_per_scan() {
  local head
  setup_task tests-once no-mistakes
  head=$(commit_work a.txt)
  nm_run passed "$head" completed completed
  status "working [at=$T0]: tests pass"
  status "working [at=$T0]: all tests pass again"
  claims "$T0" scan t1 >/dev/null
  assert_equals 1 "$(kind_count tests-green)" "an older tests claim was judged beside the newest"
  assert_equals 2 "$(rec tests-green .evidence.line)" "the judged tests claim is the newest"
  pass "a scan judges only the newest tests claim"
}

test_oversized_and_torn_input() {
  local out start elapsed
  setup_task oversized local-only
  { printf 'working: committed deadbeef1 '; head -c 200000 /dev/zero | tr '\0' 'x'; printf '\n'; } >> "$ST/t1.status"
  status "working: committed cafebabe2 too"
  claims "$T0" scan t1 >/dev/null
  assert_equals 2 "$(kind_count committed)" "an oversized line hid the claim after it"
  [ "$(jq -r 'select(.kind == "committed") | .claim | length' "$ST/t1.claims.jsonl" | sort -n | tail -n 1)" -le 2000 ] \
    || fail "an oversized claim text reached the ledger"

  setup_task oversized-done direct-PR
  commit_work a.txt >/dev/null
  { printf 'done: pushed fm/t1 '; head -c 1000000 /dev/zero | tr '\0' 'y'; printf '\n'; } >> "$ST/t1.status"
  start=$(date +%s)
  out=$(claims "$T0" scan t1)
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 60 ] || fail "a 1MB done: line took ${elapsed}s"
  assert_contains "$out" " pushed refuted line=1: origin has no branch fm/t1" "a 1MB done: line is still judged"

  setup_task torn local-only
  status "working: committed deadbeef1 with the fix"
  claims "$T0" scan t1 >/dev/null
  printf '{"v":1' >> "$ST/t1.claims.jsonl"
  printf 'working: committed cafebabe2 too' >> "$ST/t1.status"
  claims "$T0" scan t1 >/dev/null
  assert_equals 2 "$(jq -rR 'fromjson? // empty | select(.kind == "committed") | .id' "$ST/t1.claims.jsonl" | wc -l | tr -d ' ')" \
    "a record after a torn ledger tail did not land on its own line"
  tail -n 1 "$ST/t1.status" | grep -q '^blocked \[at=' || fail "the blocker did not land on its own line: $(tail -n 2 "$ST/t1.status")"
  out=$(claims "$T0" show t1)
  assert_contains "$out" "cafebabe2" "show skipped the record after a torn tail"
  pass "an oversized line is bounded and hides nothing, and a torn ledger or unterminated status line keeps records on their own lines"
}

test_tasks_are_isolated_and_locked() {
  local out rc holder head
  setup_task isolated local-only
  head=$(commit_work a.txt)
  status "working [at=$T0]: committed ${head:0:9} with the parser change"
  fm_write_meta "$ST/t2.meta" "window=fm:fm-t2" "worktree=$WT" "project=$REPO" \
    "harness=claude" "model=claude-opus-5-5" "kind=ship" "mode=local-only" "yolo=off" \
    "branch=fm/t1" "spawn_gen=s1"
  printf '%s\n' "working: committed deadbeef1 with the fix" > "$ST/t2.status"
  out=$(claims "$T0" scan --all); rc=$?
  expect_code 3 "$rc" "a refuted claim in any task makes the scan exit 3"
  assert_contains "$out" "t1 " "the first task was scanned"
  assert_contains "$out" "t2 " "the second task was scanned"
  assert_equals t1 "$(jq -r '.task' "$ST/t1.claims.jsonl" | sort -u | paste -sd' ' -)" "another task's record reached t1's ledger"
  assert_equals t2 "$(jq -r '.task' "$ST/t2.claims.jsonl" | sort -u | paste -sd' ' -)" "another task's record reached t2's ledger"
  if grep -q 'claim-refuted-' "$ST/t1.status"; then
    fail "t2's refutation reopened t1: $(cat "$ST/t1.status")"
  fi

  FM_HOME="$H" bash -c '. "$0/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$FM_HOME/state/.claims-t1.lock" || exit 1; printf "%s" "$$" > "$FM_HOME/state/.holder-pid"; touch "$FM_HOME/state/.held"; sleep 30' "$ROOT" >/dev/null 2>&1 &
  local i=0
  while [ ! -e "$ST/.held" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$ST/.held" ] || fail "fixture: could not take the claims lock"
  holder=$(cat "$ST/.holder-pid")
  status "working: committed cafebabe2 too"
  out=$(FM_WAKE_QUEUE_LOCK_WAIT=1 claims "$T0" scan t1 2>&1); rc=$?
  kill "$holder" 2>/dev/null
  wait 2>/dev/null
  expect_code 1 "$rc" "a scan that cannot take the task's lock refuses"
  assert_contains "$out" "is still held" "the refusal names the held lock"
  assert_equals 0 "$(jq -r 'select(.claim | test("cafebabe2")) | .id' "$ST/t1.claims.jsonl" | wc -l | tr -d ' ')" \
    "a refused scan wrote a record"
  pass "a scan of every task keeps each task's records and blockers apart, and a held task lock refuses the scan"
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
  test_claim_ids_follow_the_status_log \
  test_done_arms_by_mode_and_forge \
  test_order_rule_outcomes \
  test_one_tests_claim_per_scan \
  test_oversized_and_torn_input \
  test_tasks_are_isolated_and_locked
