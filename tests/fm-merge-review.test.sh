#!/usr/bin/env bash
# Tests for bin/fm-merge-review.sh: the worker-run two-model merge review and
# the deterministic receipt check a supervisor and bin/fm-pr-merge.sh read.
#
# The reviewer tools are stand-ins on PATH that answer the way each real tool
# does (claude: .result and .modelUsage; grok: .text and .modelUsage; agy:
# .status and .response with no model), so these cases pin the script's own
# logic. tests/fm-merge-review-live.test.sh checks the real tools.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_REVIEW="$ROOT/bin/fm-merge-review.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-review-tests)
PR_URL=https://github.com/example/repo/pull/7
OTHER_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# One stand-in serves all three reviewer tools; its name selects the answer
# shape. Each call appends "<cwd>|<arguments>" to <stub>/<tool>.calls and
# records what the reviewer could see in its working directory. The behavior
# is read from <stub>/<tool>.mode (default approve) and the reported model
# from <stub>/<tool>.model (default: the requested model plus a suffix).
write_reviewer_stub() {  # <fakebin> <tool>
  cat > "$1/$2" <<'SH'
#!/usr/bin/env bash
tool=${0##*/}
stub=$FM_TEST_REVIEW_STUB
case "${1:-}" in
  --version) printf '%s 9.9.9 (stand-in)\n' "$tool"; exit 0 ;;
esac
prompt='' model='' prev=''
for arg in "$@"; do
  case "$prev" in
    -p) [ "$tool" != agy ] || prompt=$arg ;;
    --prompt-file) prompt=$(cat "$arg") ;;
    --model | -m) model=$arg ;;
  esac
  prev=$arg
done
[ "$tool" != claude ] || prompt=$(cat)
# One line per call: agy takes the multi-line prompt as an argument.
printf '%s|%s\n' "$PWD" "$(printf '%s' "$*" | tr '\n' ' ')" >> "$stub/$tool.calls"
{
  [ -s diff.patch ] && echo diff=yes || echo diff=no
  [ -f snapshot/feature.txt ] && echo snapshot=yes || echo snapshot=no
  git rev-parse --git-dir >/dev/null 2>&1 && echo repo=yes || echo repo=no
} > "$stub/$tool.saw"
head=$(printf '%s\n' "$prompt" | sed -n 's/^Head commit under review: //p' | head -1)
mode=$(cat "$stub/$tool.mode" 2>/dev/null || echo approve)
reported=$(cat "$stub/$tool.model" 2>/dev/null || echo "$model-build")
body='Summary: the change adds one feature file and nothing else.
Files read: diff.patch, snapshot/feature.txt, snapshot/README.md.
Findings: none that block. The file is plain text, nothing executes it, and no test or document contradicts it.
This stand-in review is long enough to be more than a bare verdict line for the receipt floor.'
case "$mode" in
  approve) text="$body
VERDICT: APPROVE $head" ;;
  nonblocking) text="$body
NON-BLOCKING: feature.txt has no trailing newline policy.
**VERDICT: APPROVE-WITH-NONBLOCKING $head**" ;;
  block) text="$body
BLOCKING: feature.txt:1 breaks the reader.
VERDICT: BLOCK $head" ;;
  bare) text="VERDICT: APPROVE $head" ;;
  wrong-head) text="$body
VERDICT: APPROVE aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ;;
  no-verdict) text="$body
I approve this change." ;;
  fail) echo "stand-in $tool failure" >&2; exit 3 ;;
esac
case "$tool" in
  claude) jq -n --arg t "$text" --arg m "$reported" '{result: $t, is_error: false, modelUsage: {($m): {}}}' ;;
  grok) jq -n --arg t "$text" --arg m "$reported" '{text: ("I will read the diff first." + $t), modelUsage: {($m): {}}}' ;;
  agy) jq -n --arg t "$text" '{status: "SUCCESS", response: $t, num_turns: 1}' ;;
esac
SH
  chmod +x "$1/$2"
}

# A stand-in gh that answers `gh pr comment <url> --body-file <file>` with a
# comment URL, or fails when <stub>/gh.fail exists.
write_gh_stub() {  # <fakebin>
  cat > "$1/gh" <<'SH'
#!/usr/bin/env bash
stub=$FM_TEST_REVIEW_STUB
printf '%s\n' "$*" >> "$stub/gh.calls"
[ ! -e "$stub/gh.fail" ] || exit 1
if [ -e "$stub/gh.fail-block" ] && grep -q "VERDICT: BLOCK " "$5"; then
  exit 1
fi
[ "$1 $2" = "pr comment" ] || exit 1
n=$(wc -l < "$stub/gh.calls" | tr -d ' ')
cp "$5" "$stub/gh.body.$n"
printf '%s#issuecomment-%s\n' "$3" "$n"
SH
  chmod +x "$1/gh"
}

# Build one case: a home, a repository with a base commit on origin/main and a
# head commit that adds feature.txt, and the stand-in tools.
# Sets CASE, HOME_DIR, REPO, HEAD_SHA, STUB, FAKEBIN.
make_case() {  # <name> [config-line]...
  local name=$1
  shift
  CASE="$TMP_ROOT/$name"
  HOME_DIR="$CASE/home"
  REPO="$CASE/repo"
  STUB="$CASE/stub"
  FAKEBIN=$(fm_fakebin "$CASE")
  mkdir -p "$HOME_DIR/config" "$HOME_DIR/data" "$STUB"
  fm_git_init_commit "$REPO"
  git -C "$REPO" update-ref refs/remotes/origin/main "$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  printf 'the feature\n' > "$REPO/feature.txt"
  git -C "$REPO" add feature.txt
  git -C "$REPO" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm feature
  HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
  write_reviewer_stub "$FAKEBIN" claude
  write_reviewer_stub "$FAKEBIN" agy
  write_reviewer_stub "$FAKEBIN" grok
  write_gh_stub "$FAKEBIN"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$HOME_DIR/config/merge-review"
  fi
}

TWO_SEATS=('seat=anthropic:claude:claude-test-1' 'seat=google:agy:gemini-test-high')
THREE_SEATS=('seat=anthropic:claude:claude-test-1' 'seat=google:agy:gemini-test-high' 'spare=xai:grok:grok-test')

# Run the script as a spawned worker would. Output lands in $CASE/stdout and
# $CASE/stderr; the exit status is returned.
run_review() {
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_TASK_ID=review-w1 \
    FM_TEST_REVIEW_STUB="$STUB" PATH="$FAKEBIN:$PATH" \
    "$MERGE_REVIEW" "$@" > "$CASE/stdout" 2> "$CASE/stderr"
}

# Run it as a supervisor session would: no worker marker.
run_supervisor() {
  env -u FM_TASK_ID FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_REVIEW_STUB="$STUB" PATH="$FAKEBIN:$PATH" \
    "$MERGE_REVIEW" "$@" > "$CASE/stdout" 2> "$CASE/stderr"
}

store_dir() {
  printf '%s/data/merge-review/github/github.com/example/repo/7/%s\n' "$HOME_DIR" "$HEAD_SHA"
}

calls() {  # <tool>
  if [ -f "$STUB/$1.calls" ]; then
    wc -l < "$STUB/$1.calls" | tr -d ' '
  else
    echo 0
  fi
}

test_two_families_approve_and_a_supervisor_reads_one_line() {
  local rc=0 store
  make_case approve "${TWO_SEATS[@]}"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "approve: run with two approving families ($(cat "$CASE/stderr"))"
  assert_grep "merge-review: approved head=$HEAD_SHA" "$CASE/stdout" "approve: run did not end with the approved line"
  store=$(store_dir)
  assert_present "$store/anthropic.claude.claude-test-1.receipt" "approve: the claude receipt is missing"
  assert_present "$store/google.agy.gemini-test-high.receipt" "approve: the agy receipt is missing"
  assert_grep "reported_model=claude-test-1-build" "$store/anthropic.claude.claude-test-1.receipt" \
    "approve: the receipt did not record the model the tool reported"
  assert_grep "identity=requested-accepted" "$store/google.agy.gemini-test-high.receipt" \
    "approve: the agy receipt did not state its identity basis"
  assert_grep "reviewer_task=review-w1" "$store/google.agy.gemini-test-high.receipt" \
    "approve: the receipt did not name the worker that ran the review"

  rc=0
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" || rc=$?
  expect_code 0 "$rc" "approve: a supervisor check of an approved head"
  assert_equals 1 "$(wc -l < "$CASE/stdout" | tr -d ' ')" "approve: check must print exactly one line"
  assert_grep "approvals=anthropic.claude.claude-test-1:APPROVE,google.agy.gemini-test-high:APPROVE" "$CASE/stdout" \
    "approve: the verdict line did not name both seats"
  pass "two approving reviews from two model families approve, and check prints one line"
}

test_run_refuses_in_a_supervisor_session() {
  local rc=0
  make_case supervisor "${TWO_SEATS[@]}"
  run_supervisor run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 2 "$rc" "supervisor: run without the worker marker"
  assert_grep "belongs in a background worker" "$CASE/stderr" "supervisor: the refusal did not say where run belongs"
  assert_equals 0 "$(calls claude)" "supervisor: a reviewer was called from a supervisor session"
  assert_equals 0 "$(calls agy)" "supervisor: a reviewer was called from a supervisor session"
  pass "run refuses outside a spawned worker and calls no reviewer"
}

test_reviewers_work_read_only_outside_every_repository() {
  local rc=0 cwd
  make_case sandbox "${THREE_SEATS[@]}"
  echo fail > "$STUB/agy.mode"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "sandbox: claude and the grok spare approve ($(cat "$CASE/stdout"))"
  for tool in claude agy grok; do
    assert_equals "diff=yes snapshot=yes repo=no" "$(tr '\n' ' ' < "$STUB/$tool.saw" | sed 's/ $//')" \
      "sandbox: $tool did not get the diff and the head snapshot outside a repository"
    cwd=$(head -1 "$STUB/$tool.calls" | cut -d'|' -f1)
    case "$cwd" in
      "$HOME_DIR"* | "$REPO"*) fail "sandbox: $tool ran inside the home or the repository: $cwd" ;;
    esac
    assert_absent "$cwd" "sandbox: the temporary review directory outlived the run"
  done
  assert_grep "--tools Read,Grep,Glob" "$STUB/claude.calls" "sandbox: claude was not limited to read tools"
  assert_grep "--mode plan" "$STUB/agy.calls" "sandbox: agy was not run in plan mode"
  assert_grep "--permission-mode plan" "$STUB/grok.calls" "sandbox: grok was not run in plan mode"
  pass "each reviewer gets the diff and head snapshot in a temporary directory with read-only flags"
}

test_one_block_blocks_and_a_rerun_keeps_it() {
  local rc=0
  make_case block "${THREE_SEATS[@]}"
  echo block > "$STUB/agy.mode"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 1 "$rc" "block: run with one blocking seat"
  assert_grep "merge-review: blocked head=$HEAD_SHA" "$CASE/stdout" "block: the verdict line is not blocked"
  assert_grep "blocks=google.agy.gemini-test-high" "$CASE/stdout" "block: the dissenting seat is not named"
  assert_equals 0 "$(calls grok)" "block: the spare was called to outvote a dissent"

  echo approve > "$STUB/agy.mode"
  rc=0
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 1 "$rc" "block: a rerun at the same head"
  assert_equals 1 "$(calls agy)" "block: the blocking seat was called again at the same head"
  assert_equals 1 "$(calls claude)" "block: the approving seat was called again at the same head"
  assert_grep "merge-review: blocked" "$CASE/stdout" "block: a rerun dropped the dissent"
  pass "one BLOCK blocks despite an approval, the spare stays out, and a rerun cannot replace it"
}

test_a_changed_head_has_no_reviews() {
  local rc=0
  make_case moved "${TWO_SEATS[@]}"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || fail "moved: the first run did not approve"
  run_supervisor check "$PR_URL" --head "$OTHER_HEAD" || rc=$?
  expect_code 1 "$rc" "moved: check at another head"
  assert_grep "merge-review: incomplete head=$OTHER_HEAD" "$CASE/stdout" "moved: another head was not incomplete"

  # A receipt copied to the new head still names the old one.
  rc=0
  mkdir -p "$(dirname "$(store_dir)")/$OTHER_HEAD"
  cp "$(store_dir)"/* "$(dirname "$(store_dir)")/$OTHER_HEAD/"
  run_supervisor check "$PR_URL" --head "$OTHER_HEAD" || rc=$?
  expect_code 1 "$rc" "moved: copied receipts at another head"
  assert_grep "the receipt names another head" "$CASE/stdout" "moved: a copied receipt was not refused"
  pass "a changed head is incomplete, and receipts copied from the old head do not count"
}

test_one_family_twice_counts_once() {
  local rc=0
  make_case family 'seat=anthropic:claude:claude-test-1' 'seat=anthropic:agy:gemini-test-high' 'spare=xai:grok:grok-test'
  echo fail > "$STUB/grok.mode"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 1 "$rc" "family: two approvals from one declared family"
  assert_grep "merge-review: incomplete" "$CASE/stdout" "family: one family approved a merge"
  assert_grep "one model family" "$CASE/stdout" "family: the reason did not name the family rule"
  assert_equals 1 "$(calls grok)" "family: the spare was not tried for the missing second family"

  make_case family-config 'seat=anthropic:claude:claude-test-1' 'seat=anthropic:agy:gemini-test-high'
  rc=0
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 2 "$rc" "family: a config with one family"
  assert_equals 0 "$(calls claude)" "family: a one-family config still called a reviewer"
  pass "two reviews from one model family count as one"
}

test_a_wrong_reported_model_leaves_no_receipt_and_the_spare_steps_in() {
  local rc=0 store
  make_case identity "${THREE_SEATS[@]}"
  echo some-other-model > "$STUB/claude.model"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "identity: agy and the spare approve ($(cat "$CASE/stdout"))"
  store=$(store_dir)
  assert_absent "$store/anthropic.claude.claude-test-1.receipt" "identity: a mismatched model still got a receipt"
  assert_grep "not the requested claude-test-1" "$CASE/stdout" "identity: the mismatch was not reported"
  ls "$store"/anthropic.claude.claude-test-1.failed.* >/dev/null 2>&1 \
    || fail "identity: the failed attempt left no record"
  assert_grep "approvals=google.agy.gemini-test-high:APPROVE,xai.grok.grok-test:APPROVE" "$CASE/stdout" \
    "identity: the spare did not supply the second family"
  pass "a tool that reports another model leaves no receipt, and the spare supplies the second family"
}

test_placeholder_reviews_never_count() {
  local rc mode
  for mode in bare wrong-head no-verdict fail; do
    make_case "placeholder-$mode" "${TWO_SEATS[@]}"
    echo "$mode" > "$STUB/claude.mode"
    rc=0
    run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
    expect_code 1 "$rc" "placeholder-$mode: run"
    assert_absent "$(store_dir)/anthropic.claude.claude-test-1.receipt" "placeholder-$mode: the answer got a receipt"
    assert_grep "merge-review: incomplete" "$CASE/stdout" "placeholder-$mode: the head was not incomplete"
  done
  # An invalid attempt is not a dissent, so the seat may answer again.
  echo approve > "$STUB/claude.mode"
  rc=0
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "placeholder: a retry after a failed call"
  assert_equals 1 "$(calls agy)" "placeholder: the seat that already reviewed was called again"
  pass "a bare verdict, another commit's verdict, a missing verdict, and a failed call leave no receipt"
}

test_nonblocking_approval_counts_and_is_named() {
  local rc=0
  make_case nonblocking "${TWO_SEATS[@]}"
  echo nonblocking > "$STUB/claude.mode"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "nonblocking: run"
  assert_grep "anthropic.claude.claude-test-1:APPROVE-WITH-NONBLOCKING" "$CASE/stdout" \
    "nonblocking: the verdict line lost the non-blocking findings marker"
  pass "an approval with non-blocking findings approves and stays visible in the verdict line"
}

test_tampered_receipts_do_not_count() {
  local rc store
  make_case tamper "${TWO_SEATS[@]}"
  echo block > "$STUB/agy.mode"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" && fail "tamper: a blocked run exited 0"
  store=$(store_dir)

  # Flip the recorded verdict without touching the review text.
  sed 's/^verdict=BLOCK$/verdict=APPROVE/' "$store/google.agy.gemini-test-high.receipt" > "$CASE/r" \
    && cp "$CASE/r" "$store/google.agy.gemini-test-high.receipt"
  rc=0
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" || rc=$?
  expect_code 1 "$rc" "tamper: a flipped receipt verdict"
  assert_grep "the receipt verdict is not the review verdict" "$CASE/stdout" "tamper: a flipped verdict was accepted"

  # Rewrite the review text itself.
  sed "s/^VERDICT: BLOCK /VERDICT: APPROVE /" "$store/google.agy.gemini-test-high.review.md" > "$CASE/r" \
    && cp "$CASE/r" "$store/google.agy.gemini-test-high.review.md"
  rc=0
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" || rc=$?
  expect_code 1 "$rc" "tamper: an edited review"
  assert_grep "the review text changed after the receipt" "$CASE/stdout" "tamper: an edited review was accepted"

  # Remove the diff the other seat reviewed.
  rm -f "$store"/diff.*.patch
  rc=0
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" || rc=$?
  expect_code 1 "$rc" "tamper: a missing diff"
  assert_grep "the diff is missing or changed" "$CASE/stdout" "tamper: a receipt without its diff was accepted"
  pass "a flipped verdict, an edited review, and a missing diff each void the receipt"
}

test_a_receipt_counts_only_while_its_seat_is_declared() {
  local rc=0
  make_case undeclared "${TWO_SEATS[@]}"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || fail "undeclared: the first run did not approve"
  printf '%s\n' 'seat=anthropic:claude:claude-test-1' 'seat=google:agy:gemini-other' > "$HOME_DIR/config/merge-review"
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" || rc=$?
  expect_code 1 "$rc" "undeclared: check after the seat left the config"
  assert_grep "the seat is not declared in config/merge-review" "$CASE/stdout" "undeclared: a removed seat still counted"
  pass "a receipt stops counting when config/merge-review no longer declares its seat"
}

test_posting_is_off_by_default_and_required_when_on() {
  local rc=0 store
  make_case post-off "${TWO_SEATS[@]}"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || fail "post-off: run did not approve"
  assert_equals 0 "$(calls gh)" "post-off: a review was posted without post=on"

  make_case post-on "${TWO_SEATS[@]}" 'post=on'
  : > "$STUB/gh.fail"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 1 "$rc" "post-on: run while the forge refuses comments"
  assert_grep "the review is not posted on the pull request" "$CASE/stdout" "post-on: an unposted review counted"

  rm -f "$STUB/gh.fail"
  rc=0
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "post-on: a rerun once the forge accepts comments ($(cat "$CASE/stdout"))"
  assert_equals 1 "$(calls claude)" "post-on: posting a stored review called the model again"
  store=$(store_dir)
  assert_grep "posted=$PR_URL#issuecomment-" "$store/anthropic.claude.claude-test-1.receipt" \
    "post-on: the comment URL was not recorded"
  assert_grep "Merge review at head $HEAD_SHA" "$STUB/gh.body.3" "post-on: the comment does not name the head"
  assert_grep "VERDICT: APPROVE $HEAD_SHA" "$STUB/gh.body.3" "post-on: the comment does not carry the review"
  pass "reviews are posted only with post=on, and then count only with the comment URL"
}

test_unposted_block_cannot_be_outvoted_or_replaced() {
  local rc=0
  make_case post-block "${TWO_SEATS[@]}" 'seat=xai:grok:grok-test' 'post=on'
  echo block > "$STUB/agy.mode"
  : > "$STUB/gh.fail-block"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 1 "$rc" "post-block: two posted approvals cannot outvote an unposted block"
  assert_grep "merge-review: blocked head=$HEAD_SHA" "$CASE/stdout" "post-block: the unposted block was discarded"
  assert_grep "blocks=google.agy.gemini-test-high" "$CASE/stdout" "post-block: the dissenting seat is missing"
  assert_grep "approvals=anthropic.claude.claude-test-1:APPROVE,xai.grok.grok-test:APPROVE" "$CASE/stdout" \
    "post-block: both posted approvals must be present to exercise the bypass"

  rc=0
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" || rc=$?
  expect_code 1 "$rc" "post-block: the supervisor must block too"
  assert_grep "merge-review: blocked" "$CASE/stdout" "post-block: supervisor discarded the unposted block"

  echo approve > "$STUB/agy.mode"
  rm -f "$STUB/gh.fail-block"
  rc=0
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 1 "$rc" "post-block: publishing the stored block must not replace it"
  assert_equals 1 "$(calls agy)" "post-block: the blocking reviewer was called again"
  assert_grep "merge-review: blocked" "$CASE/stdout" "post-block: retry lost the block"
  assert_grep "posted=$PR_URL#issuecomment-" "$(store_dir)/google.agy.gemini-test-high.receipt" \
    "post-block: the retry did not publish the stored block"
  pass "an unposted block defeats two posted approval families and survives publication retry"
}

test_covers_follows_the_require_lines() {
  local rc=0
  make_case covers-none
  run_supervisor covers "$PR_URL" || rc=$?
  expect_code 1 "$rc" "covers: a home with no config"

  make_case covers-other "${TWO_SEATS[@]}" 'require=github.com/example/other'
  rc=0
  run_supervisor covers "$PR_URL" || rc=$?
  expect_code 1 "$rc" "covers: another repository"

  make_case covers-match "${TWO_SEATS[@]}" 'require=GitHub.com/Example/Repo'
  rc=0
  run_supervisor covers "$PR_URL" || rc=$?
  expect_code 0 "$rc" "covers: the listed repository in another case"

  make_case covers-all "${TWO_SEATS[@]}" 'require=*'
  rc=0
  run_supervisor covers "$PR_URL" || rc=$?
  expect_code 0 "$rc" "covers: every repository"

  make_case covers-bad "${TWO_SEATS[@]}" 'requires=github.com/example/repo'
  rc=0
  run_supervisor covers "$PR_URL" || rc=$?
  expect_code 2 "$rc" "covers: a malformed config"
  assert_grep 'unknown key "requires"' "$CASE/stderr" "covers: the malformed line was not named"

  make_case covers-codex 'seat=openai:codex:gpt-test' 'seat=google:agy:gemini-test-high'
  rc=0
  run_supervisor covers "$PR_URL" || rc=$?
  expect_code 2 "$rc" "covers: a seat on a tool with no reviewer adapter"
  pass "covers answers from the require lines and a malformed config is an error, not a pass"
}

test_run_refuses_what_it_cannot_review() {
  local rc=0
  make_case no-commit "${TWO_SEATS[@]}"
  run_review run "$PR_URL" --head "$OTHER_HEAD" --repo "$REPO" || rc=$?
  expect_code 2 "$rc" "refuse: a head commit the repository does not hold"
  assert_grep "fetch it there first" "$CASE/stderr" "refuse: the missing commit was not explained"

  rc=0
  run_review run "$PR_URL" --head "$(git -C "$REPO" rev-parse origin/main)" --repo "$REPO" || rc=$?
  expect_code 2 "$rc" "refuse: a head already in the base"

  rc=0
  run_review run "$PR_URL" --head abc123 --repo "$REPO" || rc=$?
  expect_code 2 "$rc" "refuse: an abbreviated head"

  rc=0
  run_review run https://github.com/example/repo/issues/7 --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 2 "$rc" "refuse: a URL that is not a pull request"
  assert_equals 0 "$(calls claude)" "refuse: a reviewer was called for a refused run"
  pass "run refuses a missing or abbreviated head, an empty change, and a non-PR URL before any call"
}

test_intent_reaches_the_prompt_the_receipt_binds() {
  local store prompt
  make_case intent "${TWO_SEATS[@]}"
  printf 'Add the feature file for the reader.\n' > "$CASE/intent.md"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" --intent-file "$CASE/intent.md" \
    || fail "intent: run did not approve"
  store=$(store_dir)
  prompt="$store/prompt.$(sed -n 's/^prompt_sha256=//p' "$store/anthropic.claude.claude-test-1.receipt").md"
  assert_grep "Add the feature file for the reader." "$prompt" "intent: the stored prompt lacks the stated intent"
  assert_grep "VERDICT: BLOCK $HEAD_SHA" "$prompt" "intent: the stored prompt does not bind the verdict to the head"
  pass "the stated intent is part of the stored prompt each receipt is bound to"
}

fm_test_run \
  test_two_families_approve_and_a_supervisor_reads_one_line \
  test_run_refuses_in_a_supervisor_session \
  test_reviewers_work_read_only_outside_every_repository \
  test_one_block_blocks_and_a_rerun_keeps_it \
  test_a_changed_head_has_no_reviews \
  test_one_family_twice_counts_once \
  test_a_wrong_reported_model_leaves_no_receipt_and_the_spare_steps_in \
  test_placeholder_reviews_never_count \
  test_nonblocking_approval_counts_and_is_named \
  test_tampered_receipts_do_not_count \
  test_a_receipt_counts_only_while_its_seat_is_declared \
  test_posting_is_off_by_default_and_required_when_on \
  test_unposted_block_cannot_be_outvoted_or_replaced \
  test_covers_follows_the_require_lines \
  test_run_refuses_what_it_cannot_review \
  test_intent_reaches_the_prompt_the_receipt_binds
