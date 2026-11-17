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
# In approve mode <stub>/<tool>.review, when present, supplies the finding
# lines and the verdict line that follow the prose, with @HEAD@ for the head.
# A review call also leaves its prompt in <stub>/<tool>.prompt, whether it was
# given prior findings and a delta in <stub>/<tool>.given, and a copy of each
# one it was given in <stub>/<tool>.prior and .delta. A council call (the
# prompt asks for a "COUNCIL: DONE" line) is logged to
# <stub>/<tool>.council-calls instead, leaves .council-prompt,
# .council-findings and .council-reviews, and answers from
# <stub>/<tool>.council, or with no disposition when that file is absent.
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
head=$(printf '%s\n' "$prompt" | sed -n 's/^Head commit under review: //p' | head -1)
reported=$(cat "$stub/$tool.model" 2>/dev/null || echo "$model-build")
answer() {
  case "$tool" in
    claude) jq -n --arg t "$1" --arg m "$reported" '{result: $t, is_error: false, modelUsage: {($m): {}}}' ;;
    grok) jq -n --arg t "$1" --arg m "$reported" '{text: ("I will read the diff first." + $t), modelUsage: {($m): {}}}' ;;
    agy) jq -n --arg t "$1" '{status: "SUCCESS", response: $t, num_turns: 1}' ;;
  esac
}
if printf '%s\n' "$prompt" | grep -q '^COUNCIL: DONE '; then
  printf '%s\n' "$PWD" >> "$stub/$tool.council-calls"
  printf '%s\n' "$prompt" > "$stub/$tool.council-prompt"
  cp council-findings.md "$stub/$tool.council-findings"
  ls reviews > "$stub/$tool.council-reviews"
  text='I read each finding against diff.patch and the snapshot.'
  [ ! -f "$stub/$tool.council" ] || text="$text
$(sed "s/@HEAD@/$head/g" "$stub/$tool.council")"
  answer "$text"
  exit 0
fi
# One line per call: agy takes the multi-line prompt as an argument.
printf '%s|%s\n' "$PWD" "$(printf '%s' "$*" | tr '\n' ' ')" >> "$stub/$tool.calls"
printf '%s\n' "$prompt" > "$stub/$tool.prompt"
{
  [ -f prior-findings.md ] && echo prior=yes || echo prior=no
  [ -f delta.patch ] && echo delta=yes || echo delta=no
} > "$stub/$tool.given"
[ ! -f prior-findings.md ] || cp prior-findings.md "$stub/$tool.prior"
[ ! -f delta.patch ] || cp delta.patch "$stub/$tool.delta"
{
  [ -s diff.patch ] && echo diff=yes || echo diff=no
  [ -f snapshot/feature.txt ] && echo snapshot=yes || echo snapshot=no
  git rev-parse --git-dir >/dev/null 2>&1 && echo repo=yes || echo repo=no
} > "$stub/$tool.saw"
[ ! -f snapshot/feature.txt ] || cp snapshot/feature.txt "$stub/$tool.feature"
[ ! -f snapshot/README.md ] || cp snapshot/README.md "$stub/$tool.readme"
if [ -e "$stub/$tool.wait" ]; then
  printf '%s\n' "$$" > "$stub/$tool.pid"
  : > "$stub/$tool.waiting"
  while [ -e "$stub/$tool.wait" ]; do sleep 0.1; done
fi
mode=$(cat "$stub/$tool.mode" 2>/dev/null || echo approve)
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
if [ "$mode" = approve ] && [ -f "$stub/$tool.review" ]; then
  text="$body
$(sed "s/@HEAD@/$head/g" "$stub/$tool.review")"
fi
answer "$text"
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

# assert_grep matches a fixed string; these match a basic regular expression,
# for a whole line of a findings listing or a patch.
assert_match() {  # <pattern> <file> <msg>
  grep -- "$1" "$2" >/dev/null || fail "$3"
}

assert_no_match() {  # <pattern> <file> <msg>
  ! grep -- "$1" "$2" >/dev/null || fail "$3"
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

test_damaged_dissent_never_approves_or_gets_replaced() {
  local mode receipt review rc
  for mode in review receipt missing-receipt unreadable-receipt unreadable-review; do
    make_case "damaged-$mode" "${TWO_SEATS[@]}" 'seat=xai:grok:grok-test'
    echo block > "$STUB/agy.mode"
    run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" && fail "damaged-$mode: initial BLOCK approved"
    receipt="$(store_dir)/google.agy.gemini-test-high.receipt"
    review="$(store_dir)/google.agy.gemini-test-high.review.md"
    case "$mode" in
      review) printf '\ncorrupted\n' >> "$review" ;;
      receipt) printf 'format=corrupted\n' > "$receipt" ;;
      missing-receipt) rm "$receipt" ;;
      unreadable-receipt) rm "$receipt"; ln -s "$CASE/absent" "$receipt" ;;
      unreadable-review) rm "$review"; ln -s "$CASE/absent" "$review" ;;
    esac
    rc=0
    run_supervisor check "$PR_URL" --head "$HEAD_SHA" || rc=$?
    expect_code 1 "$rc" "damaged-$mode: damaged dissent must not permit approval"
    assert_no_grep 'merge-review: approved' "$CASE/stdout" "damaged-$mode: check approved"

    echo approve > "$STUB/agy.mode"
    rc=0
    run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
    expect_code 1 "$rc" "damaged-$mode: rerun must keep damaged dissent fail-closed"
    assert_equals 1 "$(calls agy)" "damaged-$mode: rerun replaced the damaged dissent"
    assert_no_grep 'merge-review: approved' "$CASE/stdout" "damaged-$mode: rerun approved"
  done
  pass "corrupt, missing, and unreadable dissent never approves or gets rerolled"
}

test_check_waits_for_the_complete_review_batch() {
  local run_pid rc=0 i=0 store ready=0
  make_case active-batch "${TWO_SEATS[@]}" 'seat=xai:grok:grok-test'
  echo block > "$STUB/grok.mode"
  : > "$STUB/grok.wait"
  store=$(store_dir)
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" &
  run_pid=$!
  while [ "$i" -lt 300 ]; do
    if [ -f "$store/anthropic.claude.claude-test-1.receipt" ] &&
      [ -f "$store/google.agy.gemini-test-high.receipt" ] && [ -e "$STUB/grok.waiting" ]; then ready=1; break; fi
    sleep 0.1
    i=$((i + 1))
  done
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" bash "$MERGE_REVIEW" check "$PR_URL" --head "$HEAD_SHA" \
    > "$CASE/early-check" 2>&1 || rc=$?
  # Release and reap the owned job before assertions can terminate the test.
  rm "$STUB/grok.wait"
  wait "$run_pid" && fail "active-batch: completed BLOCK approved"
  assert_equals 1 "$ready" "active-batch: two approvals and a pending third reviewer were not established"
  expect_code 1 "$rc" "active-batch: two fast approvals must wait for the pending third reviewer"
  assert_grep 'merge-review: incomplete' "$CASE/early-check" "active-batch: active batch approved"
  assert_grep 'merge-review: blocked' "$CASE/stdout" "active-batch: final dissent missing"
  pass "check cannot approve while a third seat in the active batch has not answered"
}

test_an_unfinished_batch_stays_incomplete_after_lock_cleanup() {
  local rc=0
  make_case unfinished "${TWO_SEATS[@]}"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || fail "unfinished: initial run did not approve"
  # An interrupted run clears its lock without finishing the batch.
  rm -f "$(store_dir)/.complete"
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" || rc=$?
  expect_code 1 "$rc" "unfinished: receipts without a completed batch cannot approve"
  assert_grep 'merge-review: incomplete' "$CASE/stdout" "unfinished: cleared lock alone approved"
  rc=0
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "unfinished: rerun can complete the batch using the stored reviews"
  assert_equals 1 "$(calls claude)" "unfinished: first valid review was rerolled"
  assert_equals 1 "$(calls agy)" "unfinished: second valid review was rerolled"
  pass "lock cleanup alone cannot approve an unfinished batch, and recovery retains valid reviews"
}

test_github_url_case_cannot_select_another_review() {
  local rc=0 alias=https://github.com/Example/Repo/pull/7
  make_case url-case "${TWO_SEATS[@]}"
  echo block > "$STUB/agy.mode"
  run_review run "$alias" --head "$HEAD_SHA" --repo "$REPO" && fail "url-case: initial dissent approved"
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" || rc=$?
  expect_code 1 "$rc" "url-case: equivalent URL with stored dissent"
  assert_grep 'merge-review: blocked' "$CASE/stdout" "url-case: casing lost the stored dissent"
  echo approve > "$STUB/agy.mode"
  rc=0
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 1 "$rc" "url-case: a case alias cannot reroll dissent"
  assert_equals 1 "$(calls agy)" "url-case: case alias selected a new review"
  pass "GitHub URL case aliases share the same dissent and cannot reroll it"
}

test_dangling_configuration_cannot_disable_the_gate() {
  local rc=0
  make_case dangling-config "${TWO_SEATS[@]}" 'require=*'
  rm "$HOME_DIR/config/merge-review"
  ln -s "$CASE/absent" "$HOME_DIR/config/merge-review"
  run_supervisor covers "$PR_URL" || rc=$?
  expect_code 2 "$rc" "dangling-config: unreadable symlink must be an error, not no requirement"
  assert_grep 'not a readable file' "$CASE/stderr" "dangling-config: refusal did not name the invalid config"
  pass "a dangling merge-review configuration symlink refuses instead of disabling the gate"
}

test_invalid_configuration_parent_cannot_disable_the_gate() {
  local rc=0
  make_case config-parent "${TWO_SEATS[@]}" 'require=*'
  rm "$HOME_DIR/config/merge-review"
  rmdir "$HOME_DIR/config"
  printf 'not a directory\n' > "$HOME_DIR/config"
  run_supervisor covers "$PR_URL" || rc=$?
  expect_code 2 "$rc" "config-parent: an invalid config directory cannot mean no gate"
  pass "an invalid configuration parent refuses instead of hiding the gate"
}

test_searchable_configuration_parent_needs_no_directory_listing() {
  local rc=0
  make_case config-searchable "${TWO_SEATS[@]}" 'require=*'
  chmod 111 "$HOME_DIR/config"
  run_supervisor covers "$PR_URL" || rc=$?
  chmod 700 "$HOME_DIR/config"
  expect_code 0 "$rc" "config-searchable: a readable config in a searchable directory must still work"
  pass "config lookup works without directory-listing permission"
}

test_interruption_stops_reviewers_before_unlocking() {
  local run_pid rc=0 i=0 ready=0 reviewer_pid='' state='' alive=0
  make_case interrupted "${TWO_SEATS[@]}"
  : > "$STUB/agy.wait"
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_TASK_ID=review-w1 \
    FM_TEST_REVIEW_STUB="$STUB" PATH="$FAKEBIN:$PATH" \
    bash "$MERGE_REVIEW" run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" > "$CASE/interrupted.out" 2>&1 &
  run_pid=$!
  while [ "$i" -lt 300 ]; do
    if [ -e "$STUB/agy.waiting" ]; then ready=1; break; fi
    sleep 0.1
    i=$((i + 1))
  done
  [ ! -f "$STUB/agy.pid" ] || reviewer_pid=$(cat "$STUB/agy.pid")
  kill -TERM "$run_pid" 2>/dev/null || true
  wait "$run_pid" || rc=$?
  if [ -n "$reviewer_pid" ]; then
    state=$(ps -o stat= -p "$reviewer_pid" 2>/dev/null | tr -d '[:space:]')
    case "$state" in '' | *Z*) ;; *) alive=1 ;; esac
  fi
  # Release the fixture even on the unfixed path before an assertion exits.
  rm -f "$STUB/agy.wait"
  if [ "$alive" -eq 1 ]; then
    kill -TERM "$reviewer_pid" 2>/dev/null || true
    sleep 0.2
  fi
  assert_equals 1 "$ready" "interrupted: reviewer barrier was not reached"
  expect_code 143 "$rc" "interrupted: run did not acknowledge TERM"
  assert_equals 0 "$alive" "interrupted: parent unlocked while a reviewer was still alive"
  rc=0
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "interrupted: a clean recovery run must finish"
  pass "interrupted runs stop reviewer writers before releasing their lock, and recovery can finish"
}

test_publication_cannot_replace_a_review_recorded_during_the_call() {
  local receipt review raw run_pid rc=0 i=0 ready=0
  make_case immutable "${TWO_SEATS[@]}"
  echo block > "$STUB/agy.mode"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" && fail "immutable: initial dissent approved"
  receipt="$(store_dir)/google.agy.gemini-test-high.receipt"
  review="$(store_dir)/google.agy.gemini-test-high.review.md"
  raw="$(store_dir)/google.agy.gemini-test-high.raw.json"
  mv "$receipt" "$CASE/saved.receipt"
  mv "$review" "$CASE/saved.review"
  mv "$raw" "$CASE/saved.raw"
  echo approve > "$STUB/agy.mode"
  : > "$STUB/agy.wait"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" &
  run_pid=$!
  while [ "$i" -lt 300 ]; do
    if [ -e "$STUB/agy.waiting" ]; then ready=1; break; fi
    sleep 0.1
    i=$((i + 1))
  done
  # Simulate a concurrent valid dissent arriving after the model call began.
  cp "$CASE/saved.review" "$review"
  cp "$CASE/saved.raw" "$raw"
  cp "$CASE/saved.receipt" "$receipt"
  rm "$STUB/agy.wait"
  wait "$run_pid" || rc=$?
  assert_equals 1 "$ready" "immutable: concurrent call did not reach the barrier"
  expect_code 1 "$rc" "immutable: concurrent publication must not replace recorded dissent"
  assert_grep 'merge-review: blocked' "$CASE/stdout" "immutable: existing BLOCK was overwritten"
  assert_grep "VERDICT: BLOCK $HEAD_SHA" "$review" "immutable: blocking review text was overwritten"
  pass "a model call cannot overwrite a valid dissent recorded while it was running"
}

test_a_replaced_run_cannot_complete_or_unlock_its_successor() {
  local run_pid i=0 ready=0 rc=0 kept=0 completed=0 store
  make_case generation-owner "${TWO_SEATS[@]}" 'seat=xai:grok:grok-test'
  : > "$STUB/grok.wait"
  store=$(store_dir)
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" &
  run_pid=$!
  while [ "$i" -lt 300 ]; do
    if [ -f "$store/anthropic.claude.claude-test-1.receipt" ] &&
      [ -f "$store/google.agy.gemini-test-high.receipt" ] && [ -e "$STUB/grok.waiting" ]; then ready=1; break; fi
    sleep 0.1; i=$((i + 1))
  done
  mv "$store/.run.lock" "$CASE/previous-lock"
  mkdir "$store/.run.lock"
  printf '%s\n' "$$" > "$store/.run.lock/pid"
  printf 'successor-generation\n' > "$store/.run.lock/generation"
  rm "$STUB/grok.wait"
  wait "$run_pid" || rc=$?
  [ ! -d "$store/.run.lock" ] || kept=1
  [ ! -e "$store/.complete" ] || completed=1
  rm -rf "$store/.run.lock"
  assert_equals 1 "$ready" "generation-owner: active batch was not established"
  expect_code 2 "$rc" "generation-owner: a replaced run must refuse finalization"
  assert_equals 1 "$kept" "generation-owner: old finalizer removed its successor's lock"
  assert_equals 0 "$completed" "generation-owner: old finalizer marked an incomplete batch complete"
  pass "a replaced generation cannot complete the batch or remove its successor's lock"
}

test_stale_reclamation_is_serialized() {
  local holder_pid i=0 ready=0 rc=0 store dead_pid mode=${1:-stale}
  make_case "reclaim-owner-$mode" "${TWO_SEATS[@]}"
  store=$(store_dir)
  mkdir -p "$store"
  if [ "$mode" = stale ]; then
    mkdir "$store/.run.lock"
    sleep 0 & dead_pid=$!
    wait "$dead_pid"
    printf '%s\n' "$dead_pid" > "$store/.run.lock/pid"
  fi
  : > "$CASE/hold-reclaim"
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$2" || exit 1
    : > "$3"
    while [ -e "$4" ]; do sleep 0.1; done
    fm_lock_release "$2"
  ' _ "$ROOT" "$store/.reclaim.lock" "$CASE/reclaim-ready" "$CASE/hold-reclaim" &
  holder_pid=$!
  while [ "$i" -lt 300 ]; do
    if [ -e "$CASE/reclaim-ready" ]; then ready=1; break; fi
    sleep 0.1; i=$((i + 1))
  done
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  rm "$CASE/hold-reclaim"
  wait "$holder_pid"
  assert_equals 1 "$ready" "reclaim-owner: competing reclamation was not established"
  expect_code 2 "$rc" "reclaim-owner: a competing reclaimer must refuse before touching the run"
  assert_equals 0 "$(calls claude)" "reclaim-owner: competing reclamation launched a reviewer"
  assert_equals 0 "$(calls agy)" "reclaim-owner: competing reclamation launched a reviewer"
  rc=0
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "reclaim-owner: recovery must finish after the competing reclaimer releases"
  pass "stale-lock reclamation is serialized, and recovery proceeds once its owner releases"
}

test_check_rejects_a_batch_changed_after_receipt_enumeration() {
  local reader_pid reader_rc=0 writer_rc=0 i=0 ready=0
  make_case snapshot-race "${TWO_SEATS[@]}" 'seat=xai:grok:grok-test'
  echo fail > "$STUB/grok.mode"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || fail "snapshot-race: initial two-family approval failed"
  ln -s "$(command -v awk)" "$FAKEBIN/real-awk"
  cat > "$FAKEBIN/awk" <<'SH'
#!/usr/bin/env bash
stub=$FM_TEST_REVIEW_STUB
if [ "${2:-}" = k=format ] && [ -e "$stub/awk.wait" ] && [ ! -e "$stub/awk.waiting" ]; then
  : > "$stub/awk.waiting"
  while [ -e "$stub/awk.wait" ]; do sleep 0.1; done
fi
exec "$(dirname "$0")/real-awk" "$@"
SH
  chmod +x "$FAKEBIN/awk"
  : > "$STUB/awk.wait"
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_REVIEW_STUB="$STUB" PATH="$FAKEBIN:$PATH" \
    bash "$MERGE_REVIEW" check "$PR_URL" --head "$HEAD_SHA" > "$CASE/reader.out" 2> "$CASE/reader.err" &
  reader_pid=$!
  while [ "$i" -lt 300 ]; do
    if [ -e "$STUB/awk.waiting" ]; then ready=1; break; fi
    sleep 0.1; i=$((i + 1))
  done
  echo block > "$STUB/grok.mode"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || writer_rc=$?
  rm "$STUB/awk.wait"
  wait "$reader_pid" || reader_rc=$?
  assert_equals 1 "$ready" "snapshot-race: reader never reached the post-enumeration barrier"
  expect_code 1 "$writer_rc" "snapshot-race: new batch did not record its BLOCK"
  assert_grep 'merge-review: blocked' "$CASE/stdout" "snapshot-race: new dissent was not committed"
  expect_code 1 "$reader_rc" "snapshot-race: old enumeration cannot approve a completed newer batch"
  assert_no_grep 'merge-review: approved' "$CASE/reader.out" "snapshot-race: reader missed concurrent dissent"
  pass "check cannot approve when publication changes the completed batch after receipt enumeration"
}

test_fresh_acquisition_respects_the_reclamation_mutex() {
  test_stale_reclamation_is_serialized fresh
}

test_diff_includes_submodules_despite_git_configuration() {
  local old new receipt patch
  make_case diff-submodule "${TWO_SEATS[@]}"
  old=$(git -C "$REPO" rev-parse origin/main)
  new=$HEAD_SHA
  git -C "$REPO" update-index --add --cacheinfo "160000,$old,module"
  git -C "$REPO" commit -qm 'base submodule'
  git -C "$REPO" update-ref refs/remotes/origin/main HEAD
  git -C "$REPO" update-index --cacheinfo "160000,$new,module"
  printf 'ordinary change\n' >> "$REPO/feature.txt"
  git -C "$REPO" add feature.txt
  git -C "$REPO" commit -qm 'update submodule and ordinary file'
  HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
  git -C "$REPO" config diff.ignoreSubmodules all
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || fail "diff-submodule: review run failed"
  receipt="$(store_dir)/anthropic.claude.claude-test-1.receipt"
  patch="$(store_dir)/diff.$(sed -n 's/^diff_sha256=//p' "$receipt").patch"
  assert_grep "Subproject commit $new" "$patch" "diff-submodule: reviewer diff omitted the new gitlink"
  pass "review diff includes submodule changes despite diff.ignoreSubmodules=all"
}

test_diff_does_not_execute_external_or_text_conversion_tools() {
  local mode receipt patch
  for mode in external textconv; do
    make_case "diff-$mode" "${TWO_SEATS[@]}"
    cat > "$CASE/mask-diff" <<'SH'
#!/usr/bin/env bash
: > "$FM_TEST_REVIEW_STUB/converter-called"
printf 'masked content\n'
SH
    chmod +x "$CASE/mask-diff"
    if [ "$mode" = external ]; then
      git -C "$REPO" config diff.external "$CASE/mask-diff"
    else
      git -C "$REPO" config diff.mask.textconv "$CASE/mask-diff"
      printf '*.txt diff=mask\n' > "$REPO/.gitattributes"
      git -C "$REPO" add .gitattributes
      git -C "$REPO" commit -qm 'configure text conversion'
      HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
    fi
    run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || fail "diff-$mode: review run failed"
    assert_absent "$STUB/converter-called" "diff-$mode: review diff executed a configured converter"
    receipt="$(store_dir)/anthropic.claude.claude-test-1.receipt"
    patch="$(store_dir)/diff.$(sed -n 's/^diff_sha256=//p' "$receipt").patch"
    assert_grep '+the feature' "$patch" "diff-$mode: reviewer diff did not preserve the actual file change"
  done
  pass "review diff bypasses external diff and text conversion without hiding file content"
}

test_snapshot_preserves_committed_files_despite_archive_attributes() {
  local mode
  for mode in ignore subst; do
    make_case "archive-$mode" "${TWO_SEATS[@]}"
    # shellcheck disable=SC2016 # This Git placeholder must remain literal.
    printf 'literal $Format:%%H$\n' > "$REPO/README.md"
    if [ "$mode" = ignore ]; then printf 'feature.txt export-ignore\n' > "$REPO/.gitattributes";
    else printf 'README.md export-subst\n' > "$REPO/.gitattributes"; fi
    git -C "$REPO" add README.md .gitattributes
    git -C "$REPO" commit -qm 'archival attributes'
    HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
    run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || fail "archive-$mode: review run failed"
    assert_present "$STUB/claude.feature" "archive-$mode: snapshot omitted a committed file"
    assert_equals 'the feature' "$(cat "$STUB/claude.feature")" "archive-$mode: snapshot changed committed bytes"
    # shellcheck disable=SC2016 # Expected bytes must not undergo Git substitution.
    assert_equals 'literal $Format:%H$' "$(cat "$STUB/claude.readme")" "archive-$mode: snapshot applied export substitution"
  done
  pass "review snapshot ignores export-ignore and export-subst while preserving committed bytes"
}

test_local_replacement_refs_cannot_substitute_the_named_commit() {
  local tree replacement receipt patch
  make_case replace-commit "${TWO_SEATS[@]}"
  printf 'masked feature\n' > "$REPO/feature.txt"
  git -C "$REPO" add feature.txt
  tree=$(git -C "$REPO" write-tree)
  replacement=$(printf 'replacement commit\n' | git -C "$REPO" commit-tree "$tree" -p "$(git -C "$REPO" rev-parse origin/main)")
  git -C "$REPO" read-tree "$HEAD_SHA"
  printf 'the feature\n' > "$REPO/feature.txt"
  git -C "$REPO" replace "$HEAD_SHA" "$replacement"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || fail 'replace-commit: review run failed'
  receipt="$(store_dir)/anthropic.claude.claude-test-1.receipt"
  patch="$(store_dir)/diff.$(sed -n 's/^diff_sha256=//p' "$receipt").patch"
  assert_grep '+the feature' "$patch" 'replace-commit: diff used replacement content instead of the named commit'
  assert_equals 'the feature' "$(cat "$STUB/claude.feature")" 'replace-commit: snapshot used replacement content'
  pass "local replacement refs cannot substitute the review diff or snapshot for the named head"
}

test_snapshot_supports_sha256_object_repositories() {
  if ! git init --bare --quiet --object-format=sha256 "$TMP_ROOT/sha256-capability.git" > "$TMP_ROOT/sha256-probe.out" 2>&1; then
    pass "SHA-256 snapshot # SKIP installed Git cannot create SHA-256 repositories"
    return
  fi
  GIT_DEFAULT_HASH=sha256 make_case snapshot-sha256 "${TWO_SEATS[@]}"
  assert_equals 64 "${#HEAD_SHA}" "snapshot-sha256: fixture did not use SHA-256 objects"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || fail "snapshot-sha256: review could not read the SHA-256 source objects: $(cat "$CASE/stderr")"
  assert_equals 'the feature' "$(cat "$STUB/claude.feature")" "snapshot-sha256: snapshot changed committed bytes"
  pass "canonical snapshot reads SHA-256 source repositories without changing object format"
}

test_subdirectory_and_relative_config_cannot_omit_changes() {
  local receipt patch
  make_case relative-diff "${TWO_SEATS[@]}"
  mkdir -p "$REPO/src" "$REPO/scripts"
  printf 'inside source\n' > "$REPO/src/input.txt"
  printf 'outside source\n' > "$REPO/scripts/tool.sh"
  git -C "$REPO" add src scripts
  git -C "$REPO" commit -qm 'changes inside and outside the supplied subdirectory'
  HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
  git -C "$REPO" config diff.relative true
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO/src" || fail "relative-diff: review run failed"
  receipt="$(store_dir)/anthropic.claude.claude-test-1.receipt"
  patch="$(store_dir)/diff.$(sed -n 's/^diff_sha256=//p' "$receipt").patch"
  assert_grep 'diff --git a/scripts/tool.sh b/scripts/tool.sh' "$patch" "relative-diff: changes outside the supplied directory were omitted"
  assert_grep 'diff --git a/src/input.txt b/src/input.txt' "$patch" "relative-diff: paths are not relative to the repository root"
  pass "repository subdirectories and diff.relative cannot filter changes out of a review"
}

test_review_still_accepts_bare_source_repositories() {
  local base
  make_case bare-source "${TWO_SEATS[@]}"
  base=$(git -C "$REPO" rev-parse origin/main)
  git clone --bare --quiet "$REPO" "$CASE/source.git"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$CASE/source.git" --base "$base" \
    || fail "bare-source: review failed: $(cat "$CASE/stderr")"
  assert_equals 'the feature' "$(cat "$STUB/claude.feature")" "bare-source: snapshot changed the committed bytes"
  pass "normalizing review input paths keeps bare source repositories supported"
}

test_gitlab_url_case_cannot_select_another_review() {
  local rc=0 alias=https://gitlab.example/Group/Repo/-/merge_requests/7
  canonical=https://gitlab.example/group/repo/-/merge_requests/7
  make_case gitlab-url-case "${TWO_SEATS[@]}"
  echo block > "$STUB/agy.mode"
  run_review run "$alias" --head "$HEAD_SHA" --repo "$REPO" && fail "gitlab-case: initial dissent approved"
  run_supervisor check "$canonical" --head "$HEAD_SHA" || rc=$?
  expect_code 1 "$rc" "gitlab-case: equivalent URL with stored dissent"
  assert_grep 'merge-review: blocked' "$CASE/stdout" "gitlab-case: casing lost the stored dissent"
  echo approve > "$STUB/agy.mode"
  rc=0
  run_review run "$canonical" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 1 "$rc" "gitlab-case: a case alias cannot reroll dissent"
  assert_equals 1 "$(calls agy)" "gitlab-case: casing selected another model call"
  pass "GitLab URL case aliases retain the same recorded dissent"
}

test_forgejo_url_case_cannot_select_another_review() {
  local rc=0 alias=https://forgejo.example/Example/Repo/pulls/7 canonical=https://forgejo.example/example/repo/pulls/7
  make_case forgejo-url-case "${TWO_SEATS[@]}"
  echo block > "$STUB/agy.mode"
  run_review run "$alias" --head "$HEAD_SHA" --repo "$REPO" && fail "forgejo-case: initial dissent approved"
  run_supervisor check "$canonical" --head "$HEAD_SHA" || rc=$?
  expect_code 1 "$rc" "forgejo-case: equivalent URL with stored dissent"
  assert_grep 'merge-review: blocked' "$CASE/stdout" "forgejo-case: casing lost the stored dissent"
  echo approve > "$STUB/agy.mode"
  rc=0
  run_review run "$canonical" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 1 "$rc" "forgejo-case: a case alias cannot reroll dissent"
  assert_equals 1 "$(calls agy)" "forgejo-case: casing selected another model call"
  pass "Forgejo URL case aliases retain the same recorded dissent"
}

test_snapshot_refuses_paths_the_filesystem_cannot_distinguish() {
  local layout upper lower upper_tree lower_tree subtree tree probe expected rc
  for layout in files directories; do
    make_case "snapshot-collision-$layout" "${TWO_SEATS[@]}"
    upper=$(printf 'upper contents\n' | git -C "$REPO" hash-object -w --stdin)
    lower=$(printf 'lower contents\n' | git -C "$REPO" hash-object -w --stdin)
    if [ "$layout" = files ]; then
      subtree=$(printf '100644 blob %s\tConfig.py\n100644 blob %s\tconfig.py\n' "$upper" "$lower" | git -C "$REPO" mktree)
    else
      upper_tree=$(printf '100644 blob %s\tone.py\n' "$upper" | git -C "$REPO" mktree)
      lower_tree=$(printf '100644 blob %s\ttwo.py\n' "$lower" | git -C "$REPO" mktree)
      subtree=$(printf '040000 tree %s\tApi\n040000 tree %s\tapi\n' "$upper_tree" "$lower_tree" | git -C "$REPO" mktree)
    fi
    tree=$({ git -C "$REPO" ls-tree "$HEAD_SHA"; printf '040000 tree %s\tsrc\n' "$subtree"; } | git -C "$REPO" mktree)
    HEAD_SHA=$(printf 'case-distinct committed paths\n' | git -C "$REPO" commit-tree "$tree" -p "$HEAD_SHA")
    mkdir -p "$CASE/review-temp/probe/snapshot"
    probe="$CASE/review-temp/probe/snapshot"
    : > "$probe/CaseProbe"
    expected=0
    [ ! -e "$probe/caseprobe" ] || expected=2
    rm "$probe/CaseProbe"
    rc=0
    TMPDIR="$CASE/review-temp" run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
    expect_code "$expected" "$rc" "snapshot-collision-$layout: result must match the snapshot filesystem's path capability"
    if [ "$expected" -eq 2 ]; then
      assert_grep 'snapshot has colliding Git paths' "$CASE/stderr" "snapshot-collision-$layout: collision diagnostic missing: $(cat "$CASE/stderr")"
      assert_equals 0 "$(calls claude)" "snapshot-collision-$layout: reviewer received collapsed paths"
    else
      assert_equals 1 "$(calls claude)" "snapshot-collision-$layout: representable paths were not reviewed"
    fi
  done
  pass "snapshot refuses file or directory aliases only when the filesystem cannot represent distinct Git paths"
}

test_temp_directory_cannot_place_reviewers_inside_a_repository() {
  local mode temp rc
  for mode in checkout symlink bare bare-symlink; do
    make_case "temp-isolation-$mode" "${TWO_SEATS[@]}"
    if [ "$mode" = bare ] || [ "$mode" = bare-symlink ]; then
      git init --bare --quiet "$CASE/temp.git"
      temp="$CASE/temp.git"
      if [ "$mode" = bare-symlink ]; then
        rm "$temp/HEAD"
        ln -s refs/heads/main "$temp/HEAD"
      fi
    else
      mkdir "$REPO/private-temp"
      temp="$REPO/private-temp"
      if [ "$mode" = symlink ]; then ln -s "$temp" "$CASE/temp-alias"; temp="$CASE/temp-alias"; fi
    fi
    rc=0
    TMPDIR="$temp" run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
    expect_code 2 "$rc" "temp-isolation-$mode: repository-enclosed TMPDIR must refuse"
    assert_grep 'temporary review directory is inside a repository' "$CASE/stderr" "temp-isolation-$mode: isolation diagnostic missing"
    assert_equals 0 "$(calls claude)" "temp-isolation-$mode: reviewer started inside a repository"
    assert_equals 0 "$(calls agy)" "temp-isolation-$mode: reviewer started inside a repository"
  done
  pass "TMPDIR cannot place reviewers under a checkout, a symlinked checkout path, or a bare repository"
}

test_inherited_git_location_does_not_enter_reviewer_context() {
  make_case git-environment "${TWO_SEATS[@]}"
  GIT_DIR="$REPO/.git" run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" \
    || fail "git-environment: declared repository review failed: $(cat "$CASE/stderr")"
  assert_equals 'false' "$(git -C "$REPO" rev-parse --is-bare-repository)" "git-environment: snapshot initialization altered the source repository"
  assert_grep 'repo=no' "$STUB/claude.saw" "git-environment: inherited GIT_DIR leaked repository context to the reviewer"
  assert_grep 'repo=no' "$STUB/agy.saw" "git-environment: inherited GIT_DIR leaked repository context to the reviewer"
  pass "inherited Git location variables neither alter the declared source nor enter reviewer context"
}

test_snapshot_keeps_distinct_links_and_identical_regular_files() {
  make_case snapshot-distinct "${TWO_SEATS[@]}"
  cp "$REPO/feature.txt" "$REPO/copy.txt"
  ln -s feature.txt "$REPO/first-link"
  ln -s feature.txt "$REPO/second-link"
  git -C "$REPO" add copy.txt first-link second-link
  git -C "$REPO" commit -qm 'distinct nodes with identical content or link targets'
  HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" \
    || fail "snapshot-distinct: distinct filesystem nodes must remain accepted: $(cat "$CASE/stderr")"
  pass "snapshot accepts distinct regular files and symlinks even when their bytes or targets match"
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

test_fast_exiting_seat_continues_the_batch() {
  local rc=0
  make_case fast-claude "${THREE_SEATS[@]}"
  cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$FAKEBIN/claude"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "fast-claude: the batch continued ($(cat "$CASE/stderr"))"
  assert_grep "merge-review: approved head=$HEAD_SHA" "$CASE/stdout" "fast-claude: agy and the spare did not approve"
  pass "a seat that exits before identity is recorded does not abort the run"
}

test_leading_zero_timeout_runs_every_seat() {
  make_case timeout-leading-zero "${TWO_SEATS[@]}" 'timeout=090'
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" \
    || fail "timeout-leading-zero: run failed: $(cat "$CASE/stderr")"
  assert_equals 1 "$(calls claude)" "timeout-leading-zero: claude did not run"
  assert_equals 1 "$(calls agy)" "timeout-leading-zero: agy did not run"
  pass "timeout values with leading zeros still launch each seat"
}

test_stale_receipt_base_refreshes_approvals() {
  local rc=0 store live_base
  make_case stale-scope "${TWO_SEATS[@]}"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" \
    || fail "stale-scope: the first run did not approve"
  store=$(store_dir)
  live_base=$(sed -n 's/^base=//p' "$store/anthropic.claude.claude-test-1.receipt")
  sed "s/^base=.*$/base=$OTHER_HEAD/" "$store/anthropic.claude.claude-test-1.receipt" > "$CASE/r" \
    && cp "$CASE/r" "$store/anthropic.claude.claude-test-1.receipt"
  sed "s/^base=.*$/base=$OTHER_HEAD/" "$store/google.agy.gemini-test-high.receipt" > "$CASE/r" \
    && cp "$CASE/r" "$store/google.agy.gemini-test-high.receipt"
  assert_equals "$OTHER_HEAD" "$(sed -n 's/^base=//p' "$store/anthropic.claude.claude-test-1.receipt")" \
    "stale-scope: the stale base was not written"

  rc=0
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "stale-scope: rerun after the merge base moved ($(cat "$CASE/stderr"))"
  assert_equals 2 "$(calls claude)" "stale-scope: claude was not called again for the new scope"
  assert_equals 2 "$(calls agy)" "stale-scope: agy was not called again for the new scope"
  assert_equals "$live_base" "$(sed -n 's/^base=//p' "$store/anthropic.claude.claude-test-1.receipt")" \
    "stale-scope: the refreshed receipt did not record the live merge base"
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" --base "$live_base" || rc=$?
  expect_code 0 "$rc" "stale-scope: check at the live merge base"
  pass "stale approval receipts are replaced when the live merge base changes"
}

test_stale_spare_approval_is_dropped_before_the_run_starts() {
  local rc=0 store
  make_case stale-spare "${THREE_SEATS[@]}"
  echo fail > "$STUB/claude.mode"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "stale-spare: agy and the spare approve ($(cat "$CASE/stderr"))"
  store=$(store_dir)
  assert_present "$store/xai.grok.grok-test.receipt" "stale-spare: the spare receipt is missing"
  sed "s/^base=.*$/base=$OTHER_HEAD/" "$store/xai.grok.grok-test.receipt" > "$CASE/r" \
    && cp "$CASE/r" "$store/xai.grok.grok-test.receipt"
  sed "s/^base=.*$/base=$OTHER_HEAD/" "$store/google.agy.gemini-test-high.receipt" > "$CASE/r" \
    && cp "$CASE/r" "$store/google.agy.gemini-test-high.receipt"

  echo approve > "$STUB/claude.mode"
  rc=0
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "stale-spare: rerun after stale spare and agy receipts"
  assert_equals 2 "$(calls claude)" "stale-spare: claude was not called for the new scope"
  assert_equals 2 "$(calls agy)" "stale-spare: agy was not called for the new scope"
  assert_equals 1 "$(calls grok)" "stale-spare: the spare was called again"
  assert_absent "$store/xai.grok.grok-test.receipt" "stale-spare: the stale spare receipt was kept"
  assert_present "$store/google.agy.gemini-test-high.receipt" "stale-spare: agy did not refresh"
  assert_grep "merge-review: approved head=$HEAD_SHA" "$CASE/stdout" "stale-spare: the rerun did not approve"
  pass "a stale spare approval is dropped before seats run so a rerun can finish"
}

test_stale_block_at_another_base_is_not_replaced() {
  local rc=0 store
  make_case stale-block "${TWO_SEATS[@]}" 'seat=xai:grok:grok-test'
  echo block > "$STUB/agy.mode"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 1 "$rc" "stale-block: the blocking run"
  store=$(store_dir)
  sed "s/^base=.*$/base=$OTHER_HEAD/" "$store/google.agy.gemini-test-high.receipt" > "$CASE/r" \
    && cp "$CASE/r" "$store/google.agy.gemini-test-high.receipt"

  echo approve > "$STUB/agy.mode"
  rc=0
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 1 "$rc" "stale-block: rerun must not approve at the new scope"
  assert_equals 1 "$(calls agy)" "stale-block: the blocking seat was called again"
  assert_no_grep 'merge-review: approved' "$CASE/stdout" "stale-block: the rerun approved"
  assert_present "$(store_dir)/google.agy.gemini-test-high.review.md" \
    "stale-block: the prior block text was removed"
  pass "a BLOCK at another merge base is kept on disk and cannot be rolled forward"
}

test_stop_reviewers_skips_a_mismatched_recorded_identity() {
  local victim lock alive=0
  lock="$TMP_ROOT/stop-identity-lock"
  mkdir -p "$lock"
  sleep 300 &
  victim=$!
  printf '%s\t%s\n' "$victim" 'starttime=0 cmdline-hex=deadbeef' > "$lock/children"
  bash -c '
    lock=$1
    root=$2
    # shellcheck source=bin/fm-wake-lib.sh
    . "$root/bin/fm-wake-lib.sh"
    eval "$(sed -n "/^mr_stop_reviewers()/,/^}/p" "$root/bin/fm-merge-review.sh")"
    mr_stop_reviewers "$lock"
  ' _ "$lock" "$ROOT"
  kill -0 "$victim" 2>/dev/null && alive=1
  kill -TERM "$victim" 2>/dev/null || true
  wait "$victim" 2>/dev/null || true
  assert_equals 1 "$alive" "stop-identity: a recycled pid slot must not be signalled"
  pass "interrupted cleanup skips children whose live identity no longer matches the ledger"
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

# Commit one more change on the reviewed branch and move HEAD_SHA to it.
next_head() {  # <line>
  printf '%s\n' "$1" >> "$REPO/feature.txt"
  git -C "$REPO" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qam "$1"
  HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
}

# What a stand-in reviewer answers after its prose: finding lines and the
# verdict line, with @HEAD@ for the head under review.
set_review() {  # <tool> <line>...
  local tool=$1
  shift
  printf '%s\n' "$@" > "$STUB/$tool.review"
}

set_council() {  # <tool> <line>...
  local tool=$1
  shift
  printf '%s\n' "$@" > "$STUB/$tool.council"
}

run_at_head() {
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO"
}

findings_at_head() {
  run_supervisor findings "$PR_URL" --head "$HEAD_SHA"
}

CLAUDE_SEAT=anthropic.claude.claude-test-1
AGY_SEAT=google.agy.gemini-test-high

test_the_round_counter_spans_heads() {
  local rc=0 first second failed pr
  make_case rounds "${TWO_SEATS[@]}"
  first=$HEAD_SHA
  pr=$(dirname "$(store_dir)")
  run_at_head || fail "rounds: the first head did not approve"
  assert_grep " round=1 " "$CASE/stdout" "rounds: the first reviewed head is not round 1"
  run_at_head || fail "rounds: a rerun at the first head did not approve"
  assert_grep " round=1 " "$CASE/stdout" "rounds: a rerun at one head changed its round"

  next_head 'second head'
  second=$HEAD_SHA
  mkdir -p "$pr/$first/.run.lock"
  printf '%s\n' "$$" > "$pr/$first/.run.lock/pid"
  run_at_head || rc=$?
  expect_code 2 "$rc" "rounds: a round started while the previous round was running"
  assert_grep "still running" "$CASE/stderr" "rounds: the refusal did not name the running previous round"
  assert_equals 1 "$(calls claude)" "rounds: a reviewer was called while the previous round was running"
  mv "$pr/$first/.run.lock" "$CASE/released-run-lock"

  run_at_head || fail "rounds: the second head did not approve"
  assert_grep " round=2 " "$CASE/stdout" "rounds: the second reviewed head is not round 2"
  assert_grep "previous=$first" "$(store_dir)/round" "rounds: round 2 does not name the first head as previous"
  assert_grep "round=2" "$(store_dir)/$CLAUDE_SEAT.receipt" "rounds: the receipt does not carry its round"
  findings_at_head || fail "rounds: findings failed"
  assert_grep "round=2 head=$second previous=$first" "$CASE/stdout" "rounds: findings did not print the round"

  # A head whose every call failed is not a round.
  next_head 'third head'
  failed=$HEAD_SHA
  echo fail > "$STUB/claude.mode"
  echo fail > "$STUB/agy.mode"
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "rounds: a head with no review"
  echo approve > "$STUB/claude.mode"
  echo approve > "$STUB/agy.mode"
  next_head 'fourth head'
  run_at_head || fail "rounds: the fourth head did not approve"
  assert_grep " round=3 " "$CASE/stdout" "rounds: a head with no review counted as a round"
  assert_grep "previous=$second" "$(store_dir)/round" "rounds: round 3 took a head with no review as previous"

  # The head that failed takes the next round when it is reviewed at last.
  HEAD_SHA=$failed
  run_at_head || fail "rounds: the once-failed head did not approve"
  assert_grep " round=4 " "$CASE/stdout" "rounds: a head first reviewed later did not take the next round"

  HEAD_SHA=$first
  rc=0
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" || rc=$?
  expect_code 0 "$rc" "rounds: the first head after later rounds"
  assert_grep " round=1 " "$CASE/stdout" "rounds: later rounds changed the first head's round"
  pass "the round counter spans heads, holds on a rerun, skips a head with no review, and waits for the previous round"
}

test_a_round_waits_for_a_running_head_that_has_no_receipt_yet() {
  local rc=0 first second third pr ledger_before calls_before
  make_case running-head "${TWO_SEATS[@]}"
  first=$HEAD_SHA
  pr=$(dirname "$(store_dir)")
  run_at_head || fail "running-head: the first head did not approve"

  # The second head is in the ledger with no receipt, and a run holds it.
  next_head 'second head'
  second=$HEAD_SHA
  echo fail > "$STUB/claude.mode"
  echo fail > "$STUB/agy.mode"
  run_at_head || rc=$?
  expect_code 1 "$rc" "running-head: a head with no review"
  echo approve > "$STUB/claude.mode"
  echo approve > "$STUB/agy.mode"
  mkdir -p "$pr/$second/.run.lock"
  printf '%s\n' "$$" > "$pr/$second/.run.lock/pid"
  ledger_before=$(cat "$pr/rounds")
  calls_before=$(calls claude)

  next_head 'third head'
  third=$HEAD_SHA
  rc=0
  run_at_head || rc=$?
  expect_code 2 "$rc" "running-head: a round started while a head with no receipt was running"
  assert_grep "the review round at $second is still running" "$CASE/stderr" "running-head: the refusal did not name the running head"
  assert_equals "$ledger_before" "$(cat "$pr/rounds")" "running-head: the refused run changed the round ledger"
  [ ! -e "$pr/$third/round" ] || fail "running-head: the refused run recorded a round"
  [ ! -e "$pr/$third/prior.md" ] || fail "running-head: the refused run recorded prior findings"
  assert_equals "$calls_before" "$(calls claude)" "running-head: a reviewer was called while another head was running"

  mv "$pr/$second/.run.lock" "$CASE/released-run-lock"
  run_at_head || fail "running-head: the third head did not approve once the other run ended"
  assert_grep " round=2 " "$CASE/stdout" "running-head: the third head is not round 2"
  assert_grep "previous=$first" "$(store_dir)/round" "running-head: round 2 does not name the first head as previous"
  pass "a round waits for a running head that has no receipt yet, and changes nothing while it waits"
}

test_heads_reviewed_before_rounds_still_count_and_block() {
  local rc=0 first store receipt
  make_case legacy "${TWO_SEATS[@]}"
  first=$HEAD_SHA
  echo block > "$STUB/agy.mode"
  run_at_head || rc=$?
  expect_code 1 "$rc" "legacy: the blocking run"
  # Rewrite the store as a run before review rounds left it.
  store=$(store_dir)
  for receipt in "$store"/*.receipt; do
    grep -v -e '^round=' -e '^prior_sha256=' -e '^delta_sha256=' "$receipt" > "$receipt.tmp"
    mv "$receipt.tmp" "$receipt"
  done
  mkdir "$CASE/after-rounds"
  mv "$store/round" "$(dirname "$store")/rounds" "$CASE/after-rounds/"

  rc=0
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" || rc=$?
  expect_code 1 "$rc" "legacy: check of a BLOCK receipt written before rounds"
  assert_grep "merge-review: blocked head=$first" "$CASE/stdout" "legacy: an existing BLOCK receipt stopped blocking"
  assert_grep "blocks=$AGY_SEAT" "$CASE/stdout" "legacy: the existing dissent is not named"
  assert_no_grep " round=" "$CASE/stdout" "legacy: a head with no round record printed a round"

  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "legacy: a rerun at the blocked head"
  assert_equals 1 "$(calls agy)" "legacy: the existing dissent was called again"
  assert_grep "merge-review: blocked" "$CASE/stdout" "legacy: a rerun cleared an existing BLOCK receipt"

  echo approve > "$STUB/agy.mode"
  next_head 'the fix'
  run_at_head || fail "legacy: the fixed head did not approve ($(cat "$CASE/stdout"))"
  assert_grep " round=2 " "$CASE/stdout" "legacy: the head reviewed before rounds was not counted as round 1"
  assert_grep "previous=$first" "$(store_dir)/round" "legacy: round 2 does not name the earlier head"
  assert_equals 0 "$(wc -c < "$STUB/claude.prior" | tr -d ' ')" "legacy: a head with no finding lines carried a finding"

  HEAD_SHA=$first
  rc=0
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" || rc=$?
  expect_code 1 "$rc" "legacy: the blocked head after a later approval"
  assert_grep "merge-review: blocked" "$CASE/stdout" "legacy: a later head cleared the earlier head's BLOCK"
  pass "a head reviewed before rounds counts as a round, and its BLOCK receipt keeps blocking"
}

test_findings_keep_their_ids_and_reach_the_next_round_with_the_delta() {
  local rc=0 first store
  make_case carry "${TWO_SEATS[@]}"
  first=$HEAD_SHA
  set_review claude \
    '- **FINDING NEW | BLOCKING | none | feature.txt:1 | The reader breaks on the first line; guard it.**' \
    'VERDICT: BLOCK @HEAD@'
  set_review agy \
    'FINDING NEW | NON-BLOCKING | none | README.md:1 | The heading has a typo.' \
    'VERDICT: APPROVE-WITH-NONBLOCKING @HEAD@'
  run_at_head || rc=$?
  expect_code 1 "$rc" "carry: round 1 with a blocking finding"
  assert_grep "merge-review: blocked" "$CASE/stdout" "carry: round 1 is not blocked"
  assert_grep " open=F1 " "$CASE/stdout" "carry: the blocking finding has no id in the verdict line"
  assert_equals "prior=no delta=no" "$(tr '\n' ' ' < "$STUB/claude.given" | sed 's/ $//')" \
    "carry: round 1 got prior findings or a delta"
  findings_at_head || fail "carry: findings failed"
  assert_match "^F1	open	none	feature.txt:1	The reader breaks on the first line; guard it.	followup=none$" "$CASE/stdout" \
    "carry: the blocking finding is not listed as open"
  assert_match "^F2	noted	none	README.md:1	" "$CASE/stdout" "carry: the note is not listed"

  next_head 'guarded reader'
  # An approving review that skips an open finding does not count.
  set_review claude \
    'FINDING F1 | RESOLVED | none | feature.txt:1 | The guard is in place at this head.' \
    'VERDICT: APPROVE @HEAD@'
  set_review agy 'VERDICT: APPROVE @HEAD@'
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "carry: round 2 with one review that skips F1"
  store=$(store_dir)
  assert_absent "$store/$AGY_SEAT.receipt" "carry: an approval that skipped an open finding left a receipt"
  assert_grep "open finding F1 has no status line" "$CASE/stdout" "carry: the skipped finding was not named"
  assert_grep "merge-review: incomplete" "$CASE/stdout" "carry: one counted review was not incomplete"

  # What the reviewer was given in round 2.
  assert_equals "prior=yes delta=yes" "$(tr '\n' ' ' < "$STUB/claude.given" | sed 's/ $//')" \
    "carry: round 2 did not get the prior findings and the delta"
  assert_match "^F1 | open | none | feature.txt:1 | The reader breaks on the first line; guard it.$" "$STUB/claude.prior" \
    "carry: the open finding did not reach round 2 with its id"
  assert_match "^F2 | noted | none | README.md:1 | " "$STUB/claude.prior" "carry: the note did not reach round 2 with its id"
  assert_match "^+guarded reader$" "$STUB/claude.delta" "carry: the delta lacks the change since the reviewed head"
  assert_no_match "^+the feature$" "$STUB/claude.delta" "carry: the delta repeats the change already reviewed"
  assert_match "^+the feature$" "$store/diff.$(sed -n 's/^diff_sha256=//p' "$store/$CLAUDE_SEAT.receipt").patch" \
    "carry: the whole change is no longer in the reviewed diff"
  assert_equals "diff=yes snapshot=yes repo=no" "$(tr '\n' ' ' < "$STUB/claude.saw" | sed 's/ $//')" \
    "carry: round 2 lost the whole diff or the snapshot"
  assert_grep "still open: F1." "$STUB/claude.prompt" "carry: the prompt does not name the open finding"

  set_review agy \
    'FINDING F1 | RESOLVED | none | feature.txt:1 | Confirmed, the guard covers the first line.' \
    'VERDICT: APPROVE @HEAD@'
  run_at_head || fail "carry: round 2 did not approve once both seats ruled on F1 ($(cat "$CASE/stdout"))"
  assert_equals 2 "$(calls claude)" "carry: the seat that already answered round 2 was called again"
  assert_grep " round=2 " "$CASE/stdout" "carry: the approved head is not round 2"
  assert_no_grep " open=" "$CASE/stdout" "carry: a resolved finding is still open"
  findings_at_head || fail "carry: findings failed"
  assert_match "^F1	resolved	" "$CASE/stdout" "carry: the finding is not listed as resolved"

  # Ids are never reused, and a settled finding keeps its state.
  next_head 'more work'
  set_review claude \
    'FINDING NEW | NON-BLOCKING | none | feature.txt:3 | The new line lacks a comment.' \
    'VERDICT: APPROVE-WITH-NONBLOCKING @HEAD@'
  set_review agy 'VERDICT: APPROVE @HEAD@'
  run_at_head || fail "carry: round 3 did not approve ($(cat "$CASE/stdout"))"
  findings_at_head || fail "carry: findings failed"
  assert_match "^F1	resolved	" "$CASE/stdout" "carry: a resolved finding changed state in a later round"
  assert_match "^F3	noted	none	feature.txt:3	" "$CASE/stdout" "carry: a new finding did not take the next id"

  HEAD_SHA=$first
  findings_at_head || fail "carry: findings failed"
  assert_match "^F1	open	" "$CASE/stdout" "carry: later rounds rewrote the first head's findings"
  pass "findings keep their ids, later rounds get the open ones with the delta, and the whole change stays under review"
}

test_a_dissent_is_kept_whatever_its_form() {
  local rc=0
  make_case dissent "${THREE_SEATS[@]}"
  set_review claude \
    'FINDING NEW | BLOCKING | none | feature.txt:1 | The reader breaks on the first line.' \
    'VERDICT: BLOCK @HEAD@'
  run_at_head || rc=$?
  expect_code 1 "$rc" "dissent: round 1"

  next_head 'second head'
  # A BLOCK with a malformed finding line and no status for F1.
  set_review claude \
    'FINDING this line does not fit the form' \
    'VERDICT: BLOCK @HEAD@'
  # An approval with a malformed finding line.
  set_review agy \
    'FINDING F1 | RESOLVED | none | feature.txt:1 | Fixed.' \
    'FINDING NEW | SEVERE | none | feature.txt:2 | An unknown status.' \
    'VERDICT: APPROVE @HEAD@'
  set_review grok \
    'FINDING F1 | RESOLVED | none | feature.txt:1 | Fixed.' \
    'VERDICT: APPROVE @HEAD@'
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "dissent: round 2"
  assert_grep "blocks=$CLAUDE_SEAT" "$CASE/stdout" "dissent: a BLOCK with a malformed finding line was discarded"
  assert_absent "$(store_dir)/$AGY_SEAT.receipt" "dissent: an approval with a malformed finding line left a receipt"
  assert_present "$(store_dir)/xai.grok.grok-test.receipt" "dissent: the spare did not replace the review that did not count"
  assert_grep " open=F1 " "$CASE/stdout" "dissent: a dissent that gave an open finding no status released it"
  pass "a BLOCK is recorded whatever its finding lines look like, and an approval with a malformed line is not"
}

# Two approved heads, so the next head is round three.
two_approved_rounds() {
  run_at_head || fail "$1: round 1 did not approve"
  next_head 'second head'
  run_at_head || fail "$1: round 2 did not approve"
  next_head 'third head'
}

test_round_three_defers_an_edge_case_only_when_both_seats_agree() {
  local rc=0
  make_case defer "${TWO_SEATS[@]}"
  set_review claude \
    'FINDING NEW | BLOCKING | none | feature.txt:1 | An empty file makes the reader loop.' \
    'VERDICT: BLOCK @HEAD@'
  run_at_head || rc=$?
  expect_code 1 "$rc" "defer: round 1"

  next_head 'second head'
  # Before round three an edge case still blocks.
  set_review claude \
    'FINDING F1 | EDGE-CASE | none | feature.txt:1 | Only an empty file triggers it.' \
    'VERDICT: APPROVE-WITH-NONBLOCKING @HEAD@'
  set_review agy \
    'FINDING F1 | EDGE-CASE | none | feature.txt:1 | Only an empty file triggers it.' \
    'VERDICT: APPROVE @HEAD@'
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "defer: round 2 with an edge case"
  assert_grep "merge-review: blocked" "$CASE/stdout" "defer: an edge case was deferred before round three"
  assert_grep " open=F1 " "$CASE/stdout" "defer: the round 2 edge case is not open"

  next_head 'third head'
  # One seat calls it a regression: it blocks, with no BLOCK verdict needed.
  set_review agy \
    'FINDING F1 | REGRESSION | none | feature.txt:1 | An empty file worked at the merge base.' \
    'VERDICT: APPROVE-WITH-NONBLOCKING @HEAD@'
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "defer: round 3 with one seat calling a regression"
  assert_grep "merge-review: blocked" "$CASE/stdout" "defer: one seat deferred a finding the other calls a regression"
  assert_grep " open=F1 " "$CASE/stdout" "defer: the regression is not open"
  assert_grep "blocks=none" "$CASE/stdout" "defer: the case no longer shows an open finding blocking without a BLOCK verdict"

  next_head 'fourth head'
  set_review agy \
    'FINDING F1 | EDGE-CASE | none | feature.txt:1 | Agreed, the merge base loops the same way.' \
    'VERDICT: APPROVE @HEAD@'
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "defer: round 4 before the follow-up is recorded"
  assert_grep "merge-review: incomplete" "$CASE/stdout" "defer: a deferred finding approved with no follow-up"
  assert_grep " deferred=F1 " "$CASE/stdout" "defer: the deferred finding is not named"
  assert_grep "has no recorded follow-up" "$CASE/stdout" "defer: the missing follow-up was not reported"
  assert_equals 0 "$(cat "$STUB"/*.council-calls 2>/dev/null | wc -l | tr -d ' ')" \
    "defer: seats that both ruled in their reviews were asked again"

  rc=0
  run_supervisor followup "$PR_URL" --head "$HEAD_SHA" --finding F2 --ref 'backlog item 12' || rc=$?
  expect_code 2 "$rc" "defer: a follow-up for a finding that does not exist"
  rc=0
  run_supervisor followup "$PR_URL" --head "$HEAD_SHA" --finding F1 --ref 'backlog item 12' || rc=$?
  expect_code 0 "$rc" "defer: recording the follow-up ($(cat "$CASE/stderr"))"
  rc=0
  run_supervisor followup "$PR_URL" --head "$HEAD_SHA" --finding F1 --ref 'backlog item 99' || rc=$?
  expect_code 2 "$rc" "defer: replacing a recorded follow-up"
  rc=0
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" || rc=$?
  expect_code 0 "$rc" "defer: check once the follow-up is recorded ($(cat "$CASE/stdout"))"
  assert_grep "merge-review: approved" "$CASE/stdout" "defer: two agreeing seats and a follow-up did not approve"
  assert_grep " deferred=F1 " "$CASE/stdout" "defer: the approved line hides the deferred finding"
  findings_at_head || fail "defer: findings failed"
  assert_match "^F1	deferred	.*	followup=backlog item 12$" "$CASE/stdout" "defer: findings does not show the follow-up"

  rc=0
  run_supervisor followup "$PR_URL" --head "$HEAD_SHA" --finding F1 --ref 'backlog item 12' || rc=$?
  expect_code 0 "$rc" "defer: recording the same follow-up again"
  pass "from round three an edge case is deferred only when both seats agree, and approves only with a recorded follow-up"
}

test_the_council_rules_on_a_new_edge_case_in_round_three() {
  local rc=0 store
  make_case council "${TWO_SEATS[@]}"
  two_approved_rounds council
  set_review claude \
    'FINDING NEW | EDGE-CASE | none | feature.txt:3 | A file over 2 GB overflows the counter.' \
    'VERDICT: APPROVE-WITH-NONBLOCKING @HEAD@'
  # The other seat gives no usable answer: the finding waits.
  run_at_head || rc=$?
  expect_code 1 "$rc" "council: round 3 with no council answer"
  assert_grep "merge-review: incomplete" "$CASE/stdout" "council: a finding one seat never ruled on did not wait"
  assert_grep "waits for a seat" "$CASE/stdout" "council: the wait was not reported"
  assert_equals 1 "$(wc -l < "$STUB/agy.council-calls" | tr -d ' ')" "council: the other seat was not asked once"
  assert_absent "$STUB/claude.council-calls" "council: the seat that raised the finding was asked to rule on it"
  assert_match "^F1 | none | feature.txt:3 | A file over 2 GB overflows the counter. | reviews/$CLAUDE_SEAT.review.md$" \
    "$STUB/agy.council-findings" "council: the asked seat did not get the finding and its review"
  assert_grep "$CLAUDE_SEAT.review.md" "$STUB/agy.council-reviews" "council: the asked seat did not get the review"
  assert_grep "Rule on these findings: F1." "$STUB/agy.council-prompt" "council: the prompt does not name the finding"

  set_council agy \
    'DISPOSITION F1 | EDGE-CASE | none | The merge base uses the same 32-bit counter, so nothing regressed.' \
    'COUNCIL: DONE @HEAD@'
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "council: round 3 once the council answered"
  store=$(store_dir)
  assert_present "$store/$AGY_SEAT.council.1.ruling" "council: the ruling was not recorded"
  assert_equals 3 "$(calls claude)" "council: a seat was asked to review the head again"
  assert_equals 3 "$(calls agy)" "council: a seat was asked to review the head again"
  assert_grep " deferred=F1 " "$CASE/stdout" "council: the agreed edge case is not deferred"
  run_supervisor followup "$PR_URL" --head "$HEAD_SHA" --finding F1 --ref 'https://example.invalid/issues/4' \
    || fail "council: the follow-up was refused ($(cat "$CASE/stderr"))"
  rc=0
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" || rc=$?
  expect_code 0 "$rc" "council: check with the ruling and the follow-up ($(cat "$CASE/stdout"))"

  # An edited council answer no longer counts.
  printf 'edited\n' >> "$store/$AGY_SEAT.council.1.md"
  rc=0
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" || rc=$?
  expect_code 1 "$rc" "council: check after the council answer changed"
  assert_grep "waits for a seat" "$CASE/stdout" "council: an edited council answer still counted"
  pass "in round three the other seat rules on a new edge case, and the finding waits until it does"
}

test_the_council_can_hold_a_new_edge_case_as_a_regression() {
  local rc=0
  make_case council-regression "${TWO_SEATS[@]}"
  two_approved_rounds council-regression
  set_review claude \
    'FINDING NEW | EDGE-CASE | none | feature.txt:3 | A file over 2 GB overflows the counter.' \
    'VERDICT: APPROVE-WITH-NONBLOCKING @HEAD@'
  set_council agy \
    'DISPOSITION F1 | REGRESSION | none | The merge base used a 64-bit counter, so large files worked before.' \
    'COUNCIL: DONE @HEAD@'
  run_at_head || rc=$?
  expect_code 1 "$rc" "council-regression: round 3"
  assert_grep "merge-review: blocked" "$CASE/stdout" "council-regression: one seat deferred a finding the other calls a regression"
  assert_grep " open=F1 " "$CASE/stdout" "council-regression: the finding is not open"
  rc=0
  run_supervisor followup "$PR_URL" --head "$HEAD_SHA" --finding F1 --ref 'backlog item 3' || rc=$?
  expect_code 2 "$rc" "council-regression: a follow-up for an open finding"
  assert_grep "only a deferred finding takes a follow-up" "$CASE/stderr" "council-regression: the refusal did not say why"
  pass "a seat that calls a new edge case a regression keeps it blocking, and an open finding takes no follow-up"
}

test_unsupported_findings_are_dropped_with_evidence() {
  local rc=0
  make_case unsupported "${TWO_SEATS[@]}"
  set_review claude \
    'FINDING NEW | BLOCKING | none | feature.txt:1 | The reader may read past the end.' \
    'VERDICT: BLOCK @HEAD@'
  run_at_head || rc=$?
  expect_code 1 "$rc" "unsupported: round 1"

  next_head 'second head'
  # One seat alone cannot drop it.
  set_review claude \
    'FINDING F1 | BLOCKING | none | feature.txt:1 | Still reads past the end.' \
    'VERDICT: BLOCK @HEAD@'
  set_review agy \
    'FINDING F1 | UNSUPPORTED | none | feature.txt:1 | The reader stops at the length it was given; no read past the end exists.' \
    'VERDICT: APPROVE @HEAD@'
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "unsupported: round 2"
  assert_grep " open=F1 " "$CASE/stdout" "unsupported: one seat dropped a finding the other holds"

  next_head 'third head'
  # No evidence is not a disposition.
  set_review claude \
    'FINDING F1 | UNSUPPORTED | none | feature.txt:1 |' \
    'VERDICT: APPROVE @HEAD@'
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "unsupported: round 3 with a disposition that gives no evidence"
  assert_absent "$(store_dir)/$CLAUDE_SEAT.receipt" "unsupported: a disposition with no evidence left a receipt"

  set_review claude \
    'FINDING F1 | UNSUPPORTED | none | feature.txt:1 | I traced the read loop again: the bound check on line 4 stops it.' \
    'VERDICT: APPROVE @HEAD@'
  run_at_head || fail "unsupported: round 3 did not approve ($(cat "$CASE/stdout"))"
  assert_grep " dropped=F1 " "$CASE/stdout" "unsupported: the dropped finding is not named"
  assert_no_grep " open=" "$CASE/stdout" "unsupported: a dropped finding is still open"
  pass "a finding every seat calls unsupported, with evidence, is dropped; one seat alone cannot drop it"
}

test_security_destructive_and_data_loss_findings_always_block() {
  local rc=0
  make_case classed "${TWO_SEATS[@]}"
  two_approved_rounds classed
  # A classed finding is never an edge case, whatever the reviewer calls it.
  set_review claude \
    'FINDING NEW | EDGE-CASE | data-loss | feature.txt:3 | A crash mid-write truncates the file.' \
    'VERDICT: APPROVE-WITH-NONBLOCKING @HEAD@'
  run_at_head || rc=$?
  expect_code 1 "$rc" "classed: round 3 with a data-loss edge case"
  assert_grep "merge-review: blocked" "$CASE/stdout" "classed: a data-loss finding was deferred"
  assert_grep " open=F1 " "$CASE/stdout" "classed: the data-loss finding is not open"
  assert_absent "$STUB/agy.council-calls" "classed: a finding that cannot be deferred was put to the council"

  # The class stays once given, even when both seats later drop it.
  next_head 'fourth head'
  set_review claude \
    'FINDING F1 | EDGE-CASE | none | feature.txt:3 | Only a crash triggers it.' \
    'VERDICT: APPROVE-WITH-NONBLOCKING @HEAD@'
  set_review agy \
    'FINDING F1 | EDGE-CASE | none | feature.txt:3 | Only a crash triggers it.' \
    'VERDICT: APPROVE @HEAD@'
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "classed: round 4 with both seats relabelling the finding"
  assert_grep "merge-review: blocked" "$CASE/stdout" "classed: two seats deferred a data-loss finding"
  findings_at_head || fail "classed: findings failed"
  assert_match "^F1	open	data-loss	" "$CASE/stdout" "classed: the finding lost its class"

  next_head 'fifth head'
  set_review claude \
    'FINDING F1 | RESOLVED | none | feature.txt:3 | The write now goes to a temporary file first.' \
    'VERDICT: APPROVE @HEAD@'
  set_review agy \
    'FINDING F1 | RESOLVED | none | feature.txt:3 | Confirmed: write, then rename.' \
    'VERDICT: APPROVE @HEAD@'
  run_at_head || fail "classed: the fixed head did not approve ($(cat "$CASE/stdout"))"

  # A seat's council disposition can give the class.
  make_case classed-council "${TWO_SEATS[@]}"
  two_approved_rounds classed-council
  set_review claude \
    'FINDING NEW | EDGE-CASE | none | feature.txt:3 | A crafted name escapes the output directory.' \
    'VERDICT: APPROVE-WITH-NONBLOCKING @HEAD@'
  set_council agy \
    'DISPOSITION F1 | EDGE-CASE | security | It is rare, but it lets a file be written outside the directory.' \
    'COUNCIL: DONE @HEAD@'
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "classed-council: round 3"
  assert_grep "merge-review: blocked" "$CASE/stdout" "classed-council: a finding one seat calls a security hole was deferred"

  # A classed note blocks in any round.
  make_case classed-note "${TWO_SEATS[@]}"
  set_review claude \
    'FINDING NEW | NON-BLOCKING | destructive | feature.txt:1 | The cleanup removes the whole directory.' \
    'VERDICT: APPROVE-WITH-NONBLOCKING @HEAD@'
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "classed-note: round 1"
  assert_grep "merge-review: blocked" "$CASE/stdout" "classed-note: a destructive finding passed as a note"
  pass "a security, destructive, or data-loss finding is never deferred or noted, and keeps its class"
}

test_one_seat_alone_never_settles_a_finding() {
  local rc=0
  make_case oneseat "${TWO_SEATS[@]}"
  set_review claude \
    'FINDING NEW | BLOCKING | none | feature.txt:1 | An empty file makes the reader loop.' \
    'FINDING NEW | BLOCKING | none | feature.txt:2 | A long line is cut without notice.' \
    'VERDICT: BLOCK @HEAD@'
  run_at_head || rc=$?
  expect_code 1 "$rc" "oneseat: round 1"

  next_head 'second head'
  set_review claude \
    'FINDING F1 | BLOCKING | none | feature.txt:1 | The empty file still loops.' \
    'FINDING F2 | BLOCKING | none | feature.txt:2 | The long line is still cut.' \
    'VERDICT: BLOCK @HEAD@'
  set_review agy \
    'FINDING F1 | BLOCKING | none | feature.txt:1 | The empty file still loops.' \
    'FINDING F2 | BLOCKING | none | feature.txt:2 | The long line is still cut.' \
    'VERDICT: BLOCK @HEAD@'
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "oneseat: round 2"

  next_head 'third head'
  # Round three, and only one seat answers: its rulings settle nothing.
  echo fail > "$STUB/agy.mode"
  set_review claude \
    'FINDING F1 | EDGE-CASE | none | feature.txt:1 | Only an empty file triggers it.' \
    'FINDING F2 | UNSUPPORTED | none | feature.txt:2 | No line in the change is cut.' \
    'FINDING NEW | EDGE-CASE | none | feature.txt:3 | A file of blank lines is slow.' \
    'VERDICT: APPROVE-WITH-NONBLOCKING @HEAD@'
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "oneseat: round 3 with one seat"
  assert_grep "merge-review: incomplete" "$CASE/stdout" "oneseat: one seat's review was not reported incomplete"
  assert_grep "one model family" "$CASE/stdout" "oneseat: the missing second model family was not the reason"
  assert_no_grep " deferred=" "$CASE/stdout" "oneseat: one seat alone deferred a finding"
  assert_no_grep " dropped=" "$CASE/stdout" "oneseat: one seat alone dropped a finding"
  findings_at_head || fail "oneseat: findings failed"
  assert_match "^F1	pending	" "$CASE/stdout" "oneseat: the earlier finding one seat calls an edge case is not waiting"
  assert_match "^F2	pending	" "$CASE/stdout" "oneseat: the earlier finding one seat calls unsupported is not waiting"
  assert_match "^F3	pending	" "$CASE/stdout" "oneseat: the new edge case of one seat is not waiting"
  rc=0
  run_supervisor followup "$PR_URL" --head "$HEAD_SHA" --finding F1 --ref 'backlog item 12' || rc=$?
  expect_code 2 "$rc" "oneseat: a follow-up recorded before a second seat ruled"
  [ ! -e "$(dirname "$(store_dir)")/followups/F1" ] || fail "oneseat: a follow-up record exists before a second seat ruled"

  # The second seat reviews the same head and holds one finding.
  echo approve > "$STUB/agy.mode"
  set_review agy \
    'FINDING F1 | REGRESSION | none | feature.txt:1 | An empty file worked at the merge base.' \
    'FINDING F2 | UNSUPPORTED | none | feature.txt:2 | Agreed, no line is cut.' \
    'VERDICT: APPROVE-WITH-NONBLOCKING @HEAD@'
  set_council agy \
    'DISPOSITION F3 | EDGE-CASE | none | The merge base is slow in the same way.' \
    'COUNCIL: DONE @HEAD@'
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "oneseat: round 3 with both seats"
  assert_grep "merge-review: blocked" "$CASE/stdout" "oneseat: the regression the second seat holds does not block"
  assert_grep " open=F1 " "$CASE/stdout" "oneseat: the finding the second seat holds is not open"
  assert_grep " deferred=F3 " "$CASE/stdout" "oneseat: the edge case both seats agree on is not deferred"
  assert_grep " dropped=F2 " "$CASE/stdout" "oneseat: the finding both seats call unsupported is not dropped"
  rc=0
  run_supervisor followup "$PR_URL" --head "$HEAD_SHA" --finding F1 --ref 'backlog item 12' || rc=$?
  expect_code 2 "$rc" "oneseat: a follow-up for a finding a seat holds as a regression"
  pass "one seat alone never defers, drops, or resolves a finding, and no follow-up is recorded before a second model family rules"
}

# Rewrite the merge base a stored receipt names, as when the base branch moved
# under an unchanged head.
move_receipt_base() {  # <seat-id>
  local receipt
  receipt="$(store_dir)/$1.receipt"
  sed "s/^base=.*$/base=$OTHER_HEAD/" "$receipt" > "$CASE/r" && cp "$CASE/r" "$receipt"
}

test_a_moved_merge_base_never_replaces_a_review_that_holds_a_finding() {
  local rc=0 live_base
  make_case stale-finding "${TWO_SEATS[@]}"
  # An approving verdict over a blocking line: the finding blocks, the verdict does not.
  set_review claude \
    'FINDING NEW | BLOCKING | data-loss | feature.txt:1 | A crash mid-write truncates the file.' \
    'VERDICT: APPROVE-WITH-NONBLOCKING @HEAD@'
  run_at_head || rc=$?
  expect_code 1 "$rc" "stale-finding: round 1"
  assert_grep " open=F1 " "$CASE/stdout" "stale-finding: the data-loss finding is not open"
  assert_grep "blocks=none" "$CASE/stdout" "stale-finding: the case no longer shows a finding under an approving verdict"
  live_base=$(sed -n 's/^base=//p' "$(store_dir)/$CLAUDE_SEAT.receipt")
  move_receipt_base "$CLAUDE_SEAT"
  move_receipt_base "$AGY_SEAT"

  # The same reviewer would now approve with no finding at all.
  rm "$STUB/claude.review"
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "stale-finding: rerun after the merge base moved"
  assert_no_grep "merge-review: approved" "$CASE/stdout" "stale-finding: the rerun approved a head with a data-loss finding"
  assert_equals 1 "$(calls claude)" "stale-finding: the seat that holds the finding was called again"
  assert_equals 2 "$(calls agy)" "stale-finding: the plain approval was not refreshed"
  rc=0
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" --base "$live_base" || rc=$?
  expect_code 1 "$rc" "stale-finding: check at the live merge base"
  assert_no_grep "merge-review: approved" "$CASE/stdout" "stale-finding: check approved a head with a data-loss finding"
  findings_at_head || fail "stale-finding: findings failed"
  assert_match "^F1	open	data-loss	" "$CASE/stdout" "stale-finding: the finding was lost with the stale review"

  # The next head still gets it.
  next_head 'second head'
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "stale-finding: round 2 with reviews that skip the open finding"
  assert_match "^F1 | open | data-loss | feature.txt:1 | A crash mid-write truncates the file.$" "$STUB/agy.prior" \
    "stale-finding: the next round did not get the finding"

  # From round three a new edge case is held the same way.
  make_case stale-edge "${TWO_SEATS[@]}"
  two_approved_rounds stale-edge
  set_review claude \
    'FINDING NEW | EDGE-CASE | none | feature.txt:3 | A file over 2 GB overflows the counter.' \
    'VERDICT: APPROVE-WITH-NONBLOCKING @HEAD@'
  set_council agy \
    'DISPOSITION F1 | EDGE-CASE | none | The merge base uses the same 32-bit counter.' \
    'COUNCIL: DONE @HEAD@'
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "stale-edge: round 3"
  assert_grep " deferred=F1 " "$CASE/stdout" "stale-edge: the agreed edge case is not deferred"
  move_receipt_base "$CLAUDE_SEAT"
  move_receipt_base "$AGY_SEAT"
  rm "$STUB/claude.review"
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "stale-edge: rerun after the merge base moved"
  assert_no_grep "merge-review: approved" "$CASE/stdout" "stale-edge: the rerun approved without the edge case"
  assert_equals 3 "$(calls claude)" "stale-edge: the seat that raised the edge case was called again"
  findings_at_head || fail "stale-edge: findings failed"
  assert_match "^F1	" "$CASE/stdout" "stale-edge: the edge case was lost with the stale review"

  # A council answer that gives a finding its class is kept with its seat's approval.
  make_case stale-council "${TWO_SEATS[@]}"
  two_approved_rounds stale-council
  set_review claude \
    'FINDING NEW | EDGE-CASE | none | feature.txt:3 | A crafted name escapes the output directory.' \
    'VERDICT: APPROVE-WITH-NONBLOCKING @HEAD@'
  set_council agy \
    'DISPOSITION F1 | EDGE-CASE | security | It is rare, but it lets a file be written outside the directory.' \
    'COUNCIL: DONE @HEAD@'
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "stale-council: round 3"
  assert_grep " open=F1 " "$CASE/stdout" "stale-council: the security finding is not open"
  move_receipt_base "$CLAUDE_SEAT"
  move_receipt_base "$AGY_SEAT"
  sed "s/^base=.*$/base=$OTHER_HEAD/" "$(store_dir)/$AGY_SEAT.council.1.ruling" > "$CASE/r" \
    && cp "$CASE/r" "$(store_dir)/$AGY_SEAT.council.1.ruling"
  rm "$STUB/claude.review" "$STUB/agy.council"
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "stale-council: rerun after the merge base moved"
  assert_equals 3 "$(calls agy)" "stale-council: the seat whose council answer gives the class was called again"
  next_head 'fourth head'
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "stale-council: round 4 with reviews that skip the open finding"
  assert_match "^F1 | open | security | " "$STUB/agy.prior" "stale-council: the next round lost the finding's class"
  pass "a rerun after the merge base moved keeps a review that holds a finding, so the finding is never lost"
}

test_an_edge_case_is_deferred_only_when_every_seat_calls_it_one() {
  local rc=0
  make_case mixed "${TWO_SEATS[@]}"
  set_review claude \
    'FINDING NEW | BLOCKING | none | feature.txt:1 | An empty file makes the reader loop.' \
    'VERDICT: BLOCK @HEAD@'
  run_at_head || rc=$?
  expect_code 1 "$rc" "mixed: round 1"
  next_head 'second head'
  set_review claude \
    'FINDING F1 | BLOCKING | none | feature.txt:1 | The empty file still loops.' \
    'VERDICT: BLOCK @HEAD@'
  set_review agy \
    'FINDING F1 | BLOCKING | none | feature.txt:1 | The empty file still loops.' \
    'VERDICT: BLOCK @HEAD@'
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "mixed: round 2"

  next_head 'third head'
  # One seat calls it an edge case, the other says there is no defect.
  set_review claude \
    'FINDING F1 | EDGE-CASE | none | feature.txt:1 | Only an empty file triggers it.' \
    'VERDICT: APPROVE-WITH-NONBLOCKING @HEAD@'
  set_review agy \
    'FINDING F1 | UNSUPPORTED | none | feature.txt:1 | The loop has a bound on line 4, so it ends.' \
    'VERDICT: APPROVE @HEAD@'
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "mixed: round 3 with an edge case and an unsupported ruling"
  assert_grep "merge-review: blocked" "$CASE/stdout" "mixed: one seat alone deferred a finding"
  assert_grep " open=F1 " "$CASE/stdout" "mixed: the finding the seats disagree on is not open"
  assert_no_grep " deferred=" "$CASE/stdout" "mixed: a finding one seat calls unsupported was deferred"
  assert_no_grep " dropped=" "$CASE/stdout" "mixed: a finding one seat calls an edge case was dropped"
  rc=0
  run_supervisor followup "$PR_URL" --head "$HEAD_SHA" --finding F1 --ref 'backlog item 12' || rc=$?
  expect_code 2 "$rc" "mixed: a follow-up for a finding only one seat defers"
  assert_grep "only a deferred finding takes a follow-up" "$CASE/stderr" "mixed: the refusal did not say why"

  next_head 'fourth head'
  # A seat that calls it fixed does not agree to defer it either.
  set_review agy \
    'FINDING F1 | RESOLVED | none | feature.txt:1 | The reader now returns on an empty file.' \
    'VERDICT: APPROVE @HEAD@'
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "mixed: round 4 with an edge case and a resolved ruling"
  assert_grep " open=F1 " "$CASE/stdout" "mixed: a finding one seat calls resolved was deferred"

  next_head 'fifth head'
  set_review agy \
    'FINDING F1 | EDGE-CASE | none | feature.txt:1 | Agreed, the merge base loops the same way.' \
    'VERDICT: APPROVE @HEAD@'
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "mixed: round 5 before the follow-up is recorded"
  assert_grep " deferred=F1 " "$CASE/stdout" "mixed: the finding every seat calls an edge case is not deferred"

  # The council's answer counts the same way.
  make_case mixed-council "${TWO_SEATS[@]}"
  two_approved_rounds mixed-council
  set_review claude \
    'FINDING NEW | EDGE-CASE | none | feature.txt:3 | A file over 2 GB overflows the counter.' \
    'VERDICT: APPROVE-WITH-NONBLOCKING @HEAD@'
  set_council agy \
    'DISPOSITION F1 | UNSUPPORTED | none | The counter is 64-bit on line 2, so it cannot overflow.' \
    'COUNCIL: DONE @HEAD@'
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "mixed-council: round 3"
  assert_grep "merge-review: blocked" "$CASE/stdout" "mixed-council: one seat alone deferred a new edge case"
  assert_grep " open=F1 " "$CASE/stdout" "mixed-council: the new edge case the council calls unsupported is not open"
  pass "from round three an edge case is deferred only when every seat calls it one; any other ruling beside it keeps it open"
}

test_a_follow_up_must_name_where_it_was_filed() {
  local rc=0 record
  make_case blank-ref "${TWO_SEATS[@]}"
  two_approved_rounds blank-ref
  set_review claude \
    'FINDING NEW | EDGE-CASE | none | feature.txt:3 | A file over 2 GB overflows the counter.' \
    'VERDICT: APPROVE-WITH-NONBLOCKING @HEAD@'
  set_council agy \
    'DISPOSITION F1 | EDGE-CASE | none | The merge base uses the same 32-bit counter.' \
    'COUNCIL: DONE @HEAD@'
  run_at_head || rc=$?
  expect_code 1 "$rc" "blank-ref: round 3"
  assert_grep " deferred=F1 " "$CASE/stdout" "blank-ref: the agreed edge case is not deferred"
  record="$(dirname "$(store_dir)")/followups/F1"

  rc=0
  run_supervisor followup "$PR_URL" --head "$HEAD_SHA" --finding F1 --ref '   ' || rc=$?
  expect_code 2 "$rc" "blank-ref: a follow-up that names nothing"
  assert_grep "--ref requires one line of text" "$CASE/stderr" "blank-ref: the refusal did not say why"
  assert_absent "$record" "blank-ref: a follow-up that names nothing left a record"
  rc=0
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" || rc=$?
  expect_code 1 "$rc" "blank-ref: check after the refused follow-up"
  assert_grep "has no recorded follow-up" "$CASE/stdout" "blank-ref: check did not report the missing follow-up"

  # A record that names nothing does not count either, however it got there.
  mkdir -p "$(dirname "$record")"
  printf 'finding=F1\nhead=%s\nref=   \nat=1\n' "$HEAD_SHA" > "$record"
  rc=0
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" || rc=$?
  expect_code 1 "$rc" "blank-ref: check with a record that names nothing"
  assert_grep "has no recorded follow-up" "$CASE/stdout" "blank-ref: a record that names nothing counted as a follow-up"
  findings_at_head || fail "blank-ref: findings failed"
  assert_match "^F1	deferred	.*	followup=none$" "$CASE/stdout" "blank-ref: findings shows a follow-up that names nothing"

  printf 'finding=F1\nhead=%s\nref=backlog item 7\nat=1\n' "$HEAD_SHA" > "$record"
  rc=0
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" || rc=$?
  expect_code 0 "$rc" "blank-ref: check with a record that names where it was filed ($(cat "$CASE/stdout"))"
  pass "a follow-up counts only when it names where the finding was filed"
}

test_a_model_name_cannot_take_the_council_file_names() {
  local rc=0 spec n=0
  for spec in 'seat=google:agy:gemini.council.2' 'seat=google:agy:gemini.council'; do
    n=$((n + 1))
    make_case "council-name-$n" 'seat=anthropic:claude:claude-test-1' "$spec"
    rc=0
    run_at_head || rc=$?
    expect_code 2 "$rc" "council-name: run with $spec"
    assert_grep 'cannot hold the part ".council"' "$CASE/stderr" "council-name: the refusal for $spec did not say why"
    assert_equals 0 "$(calls claude)" "council-name: a seat was called under $spec"
    rc=0
    run_supervisor check "$PR_URL" --head "$HEAD_SHA" || rc=$?
    expect_code 2 "$rc" "council-name: check with $spec"
  done
  # Only the exact part is reserved.
  make_case council-name-ok 'seat=anthropic:claude:claude-test-1' 'seat=google:agy:gemini.councils-2'
  run_at_head || fail "council-name-ok: a model name that only resembles the part was refused ($(cat "$CASE/stderr"))"
  pass "a model name that would share a seat's council file names is refused before any seat runs"
}

test_a_finding_of_a_seat_that_left_the_config_reaches_the_next_round() {
  local rc=0
  make_case rotated "${TWO_SEATS[@]}"
  set_review claude \
    'FINDING NEW | BLOCKING | none | feature.txt:1 | An empty file makes the reader loop.' \
    'VERDICT: BLOCK @HEAD@'
  run_at_head || rc=$?
  expect_code 1 "$rc" "rotated: round 1"
  assert_grep " open=F1 " "$CASE/stdout" "rotated: the finding is not open"

  # The seat that holds the finding leaves the config before the next head.
  printf '%s\n' 'seat=google:agy:gemini-test-high' 'seat=xai:grok:grok-test' > "$HOME_DIR/config/merge-review"
  next_head 'second head'
  set_review agy \
    'FINDING F1 | BLOCKING | none | feature.txt:1 | The empty file still loops.' \
    'VERDICT: BLOCK @HEAD@'
  set_review grok \
    'FINDING F1 | UNSUPPORTED | none | feature.txt:1 | The loop has a bound on line 4, so it ends.' \
    'VERDICT: APPROVE @HEAD@'
  rc=0
  run_at_head || rc=$?
  expect_code 1 "$rc" "rotated: round 2 with the new seats"
  assert_match "^F1 | open | none | feature.txt:1 | An empty file makes the reader loop.$" "$STUB/grok.prior" \
    "rotated: the next round did not get the finding of the seat that left"
  assert_grep "merge-review: blocked" "$CASE/stdout" "rotated: the finding no longer blocks"
  assert_grep " open=F1 " "$CASE/stdout" "rotated: the finding of the seat that left is not open"
  assert_present "$(store_dir)/xai.grok.grok-test.receipt" "rotated: a ruling on the carried finding left no receipt"

  # A seat that left settles nothing: its approval of the old head is not counted there.
  make_case rotated-approval "${TWO_SEATS[@]}"
  run_at_head || fail "rotated-approval: round 1 did not approve"
  printf '%s\n' 'seat=google:agy:gemini-test-high' 'seat=xai:grok:grok-test' > "$HOME_DIR/config/merge-review"
  rc=0
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" || rc=$?
  expect_code 1 "$rc" "rotated-approval: check after the seat left the config"
  assert_grep "the seat is not declared in config/merge-review" "$CASE/stdout" "rotated-approval: a seat that left still counted"
  pass "a finding held by a seat that left config/merge-review still reaches the next round as open"
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
  test_damaged_dissent_never_approves_or_gets_replaced \
  test_check_waits_for_the_complete_review_batch \
  test_an_unfinished_batch_stays_incomplete_after_lock_cleanup \
  test_github_url_case_cannot_select_another_review \
  test_dangling_configuration_cannot_disable_the_gate \
  test_invalid_configuration_parent_cannot_disable_the_gate \
  test_searchable_configuration_parent_needs_no_directory_listing \
  test_interruption_stops_reviewers_before_unlocking \
  test_publication_cannot_replace_a_review_recorded_during_the_call \
  test_a_replaced_run_cannot_complete_or_unlock_its_successor \
  test_stale_reclamation_is_serialized \
  test_check_rejects_a_batch_changed_after_receipt_enumeration \
  test_fresh_acquisition_respects_the_reclamation_mutex \
  test_diff_includes_submodules_despite_git_configuration \
  test_diff_does_not_execute_external_or_text_conversion_tools \
  test_snapshot_preserves_committed_files_despite_archive_attributes \
  test_local_replacement_refs_cannot_substitute_the_named_commit \
  test_snapshot_supports_sha256_object_repositories \
  test_subdirectory_and_relative_config_cannot_omit_changes \
  test_review_still_accepts_bare_source_repositories \
  test_gitlab_url_case_cannot_select_another_review \
  test_forgejo_url_case_cannot_select_another_review \
  test_snapshot_refuses_paths_the_filesystem_cannot_distinguish \
  test_temp_directory_cannot_place_reviewers_inside_a_repository \
  test_inherited_git_location_does_not_enter_reviewer_context \
  test_snapshot_keeps_distinct_links_and_identical_regular_files \
  test_covers_follows_the_require_lines \
  test_run_refuses_what_it_cannot_review \
  test_stop_reviewers_skips_a_mismatched_recorded_identity \
  test_fast_exiting_seat_continues_the_batch \
  test_leading_zero_timeout_runs_every_seat \
  test_stale_receipt_base_refreshes_approvals \
  test_stale_spare_approval_is_dropped_before_the_run_starts \
  test_stale_block_at_another_base_is_not_replaced \
  test_intent_reaches_the_prompt_the_receipt_binds \
  test_the_round_counter_spans_heads \
  test_heads_reviewed_before_rounds_still_count_and_block \
  test_findings_keep_their_ids_and_reach_the_next_round_with_the_delta \
  test_a_dissent_is_kept_whatever_its_form \
  test_round_three_defers_an_edge_case_only_when_both_seats_agree \
  test_the_council_rules_on_a_new_edge_case_in_round_three \
  test_the_council_can_hold_a_new_edge_case_as_a_regression \
  test_unsupported_findings_are_dropped_with_evidence \
  test_security_destructive_and_data_loss_findings_always_block \
  test_one_seat_alone_never_settles_a_finding \
  test_a_moved_merge_base_never_replaces_a_review_that_holds_a_finding \
  test_an_edge_case_is_deferred_only_when_every_seat_calls_it_one \
  test_a_follow_up_must_name_where_it_was_filed \
  test_a_model_name_cannot_take_the_council_file_names \
  test_a_finding_of_a_seat_that_left_the_config_reaches_the_next_round \
  test_a_round_waits_for_a_running_head_that_has_no_receipt_yet
