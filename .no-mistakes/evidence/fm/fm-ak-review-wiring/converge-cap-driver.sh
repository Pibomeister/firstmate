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
. "{run-worktree}/tests/lib.sh"
expect_code() { [ "$2" = "$1" ] || fail "$3: expected exit $1, got $2 STDOUT=[$(cat "$CASE/stdout" 2>/dev/null)] STDERR=[$(cat "$CASE/stderr" 2>/dev/null)]"; }
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
{ [ -s delta.patch ] && echo delta=yes || echo delta=no; } > "$stub/$tool.delta"
printf '%s\n' "$prompt" > "$stub/$tool.prompt"
[ ! -f snapshot/feature.txt ] || cp snapshot/feature.txt "$stub/$tool.feature"
[ ! -f snapshot/README.md ] || cp snapshot/README.md "$stub/$tool.readme"
head=$(printf '%s\n' "$prompt" | sed -n 's/^Head commit under review: //p' | head -1)
if [ -e "$stub/$tool.wait" ]; then
  printf '%s\n' "$$" > "$stub/$tool.pid"
  : > "$stub/$tool.waiting"
  while [ -e "$stub/$tool.wait" ]; do sleep 0.1; done
fi
mode=$(cat "$stub/$tool.mode" 2>/dev/null || echo approve)
reported=$(cat "$stub/$tool.model" 2>/dev/null || echo "$model-build")
body='Summary: the change adds one feature file and nothing else.
Files read: diff.patch, snapshot/feature.txt, snapshot/README.md.
Findings: none that block. The file is plain text, nothing executes it, and no test or document contradicts it.
This stand-in review is long enough to be more than a bare verdict line for the receipt floor.'
# <stub>/<tool>.extra is added to the review before its verdict line, and
# <stub>/<tool>.close holds the vote for every open finding the prompt lists.
if [ -f "$stub/$tool.extra" ]; then
  body="$body
$(cat "$stub/$tool.extra")"
fi
if [ -f "$stub/$tool.close" ]; then
  for id in $(printf '%s\n' "$prompt" | sed -n '/^<open-findings>$/,/^<\/open-findings>$/s/^\(F[0-9]*\) | .*/\1/p'); do
    body="$body
CLOSURE: $id | $(cat "$stub/$tool.close") | feature.txt:1"
  done
fi
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
# <stub>/<tool>.tokens holds "<input> <output> <cache-read>" to report usage.
usage='{}'
if [ -f "$stub/$tool.tokens" ]; then
  read -r t_in t_out t_cache < "$stub/$tool.tokens"
  usage=$(jq -n --argjson i "$t_in" --argjson o "$t_out" --argjson c "$t_cache" \
    '{inputTokens: $i, outputTokens: $o, cacheReadInputTokens: $c}')
fi
# <stub>/<tool>.usage holds a top-level snake_case usage object, reported
# beside a model entry that carries no token counts.
if [ -f "$stub/$tool.usage" ]; then
  jq -n --arg t "$text" --arg m "$reported" --slurpfile u "$stub/$tool.usage" \
    '{result: $t, is_error: false, modelUsage: {($m): {}}, usage: $u[0]}'
  exit 0
fi
case "$tool" in
  claude) jq -n --arg t "$text" --arg m "$reported" --argjson u "$usage" '{result: $t, is_error: false, modelUsage: {($m): $u}}' ;;
  grok) jq -n --arg t "$text" --arg m "$reported" --argjson u "$usage" '{text: ("I will read the diff first." + $t), modelUsage: {($m): $u}}' ;;
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

# Write a reproduction script for verify-finding to <CASE>/<name>.
write_repro() {  # <name> <body>
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$CASE/$1"
}

# Run verify-finding as a worker against the case repository.
run_verify() {  # <repro-name> <path> [extra args...]
  local repro=$1 path=$2
  shift 2
  run_review verify-finding --repo "$REPO" --head "$HEAD_SHA" --repro "$CASE/$repro" --path "$path" "$@"
}

verify_line() {
  grep '^verify-finding: ' "$CASE/stdout"
}

expect_verify_field() {  # <field> <label>
  case " $(verify_line) " in
    *" $1 "*) ;;
    *) fail "$2: expected $1 in: $(verify_line) $(cat "$CASE/stderr")" ;;
  esac
}

test_verify_finding_red_at_head_and_green_at_base_is_introduced_evidence() {
  local rc=0 base
  make_case verify-introduced
  base=$(git -C "$REPO" rev-parse HEAD~1)
  write_repro repro.sh 'if [ -f feature.txt ]; then echo "defect reproduced"; exit 1; fi'
  run_verify repro.sh tests/repro-defect.test.sh --out "$CASE/evidence" || rc=$?
  expect_code 0 "$rc" "verify introduced"
  expect_verify_field 'introduced' "verify introduced"
  expect_verify_field "head=$HEAD_SHA" "verify introduced"
  expect_verify_field 'head_result=red' "verify introduced"
  expect_verify_field "base=$base" "verify introduced"
  expect_verify_field 'base_result=green' "verify introduced"
  expect_verify_field "repro_sha256=$({ shasum -a 256 "$CASE/repro.sh" 2>/dev/null || sha256sum "$CASE/repro.sh"; } | awk '{print $1}')" "verify introduced"
  assert_grep 'defect reproduced' "$CASE/evidence/head.log" "verify introduced: the head log is not kept as evidence"
  assert_equals "$(verify_line)" "$(cat "$CASE/evidence/result")" "verify introduced: the result line is not recorded with the logs"
  assert_equals 0 "$(git -C "$REPO" status --porcelain | grep -c .)" "verify introduced: the reproduction touched the source repository"
  pass "verify-finding: red at the head and green at the merge base is introduced evidence"
}

# Commit <file> with <content> in the case repository.
commit_case_file() {  # <file> <content> <message>
  mkdir -p "$(dirname "$REPO/$1")"
  printf '%s\n' "$2" > "$REPO/$1"
  git -C "$REPO" add "$1"
  git -C "$REPO" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "$3"
}

# Put <file> with <content> on origin/main, then rebuild the head on top of it.
set_case_base_file() {  # <file> <content>
  git -C "$REPO" reset -q --hard refs/remotes/origin/main
  commit_case_file "$1" "$2" 'base file'
  git -C "$REPO" update-ref refs/remotes/origin/main "$(git -C "$REPO" rev-parse HEAD)"
  commit_case_file feature.txt 'the feature' feature
  HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
}

test_verify_finding_waits_for_a_child_that_ignores_sigterm() {
  local rc=0
  make_case verify-ignore-term
  write_repro repro.sh '( trap "" TERM; sleep 60 ) &
if [ -f feature.txt ]; then exit 1; fi'
  run_verify repro.sh tests/repro-ignore-term.test.sh --out "$CASE/evidence" || rc=$?
  expect_code 0 "$rc" "verify ignore-term: $(cat "$CASE/stderr")"
  expect_verify_field 'introduced' "verify ignore-term"
  pass "verify-finding: a background child that ignores SIGTERM is killed and the result is still reported"
}

test_verify_finding_runs_one_frozen_copy_on_both_sides() {
  local rc=0 sha
  make_case verify-frozen
  # At the head the reproduction rewrites the caller's file to always fail.
  # The merge base must still run the bytes the head ran.
  write_repro repro.sh "if [ -f feature.txt ]; then printf '#!/usr/bin/env bash\nexit 1\n' > '$CASE/repro.sh'; exit 1; fi"
  sha=$({ shasum -a 256 "$CASE/repro.sh" 2>/dev/null || sha256sum "$CASE/repro.sh"; } | awk '{print $1}')
  run_verify repro.sh tests/repro-frozen.test.sh --out "$CASE/evidence" || rc=$?
  expect_code 0 "$rc" "verify frozen"
  expect_verify_field 'introduced' "verify frozen: the base ran a rewritten reproduction"
  expect_verify_field "repro_sha256=$sha" "verify frozen"
  pass "verify-finding: both sides run one frozen copy, the one repro_sha256 names"
}

test_verify_finding_never_replaces_evidence_written_during_the_run() {
  local rc=0
  make_case verify-noclobber
  mkdir -p "$CASE/evidence"
  write_repro repro.sh "printf 'planted\n' > '$CASE/evidence/result'
if [ -f feature.txt ]; then exit 1; fi"
  run_verify repro.sh tests/repro-noclobber.test.sh --out "$CASE/evidence" || rc=$?
  expect_code 2 "$rc" "verify noclobber"
  assert_grep 'evidence is never replaced' "$CASE/stderr" "verify noclobber: the refusal is not named"
  assert_equals planted "$(cat "$CASE/evidence/result")" "verify noclobber: evidence written during the run was replaced"
  pass "verify-finding: publication refuses to replace evidence that appeared while the reproduction ran"
}

test_verify_finding_red_at_both_is_classified_red_at_both() {
  local rc=0
  make_case verify-red-at-both
  write_repro repro.sh 'echo "always broken"; exit 1'
  run_verify repro.sh tests/repro-defect.test.sh --out "$CASE/evidence" || rc=$?
  expect_code 0 "$rc" "verify red at both"
  expect_verify_field 'red-at-both' "verify red at both"
  expect_verify_field 'head_result=red' "verify red at both"
  expect_verify_field 'base_result=red' "verify red at both"
  pass "verify-finding: red at both the head and the merge base is red-at-both"
}

test_verify_finding_red_at_both_on_a_script_the_head_adds() {
  local rc=0
  make_case verify-new-script
  commit_case_file bin/new-tool.sh 'echo "tool is broken"; exit 1' 'add a tool'
  HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
  write_repro repro.sh 'bash bin/new-tool.sh || exit 1'
  run_verify repro.sh tests/repro-new-tool.test.sh --out "$CASE/evidence" || rc=$?
  expect_code 0 "$rc" "verify new script"
  expect_verify_field 'red-at-both' "verify new script"
  expect_verify_field 'head_result=red' "verify new script"
  expect_verify_field 'base_result=red' "verify new script"
  pass "verify-finding: a failing script the head adds is red-at-both"
}

test_verify_finding_red_at_both_on_a_function_the_head_adds_to_an_existing_file() {
  local rc=0
  make_case verify-new-function
  set_case_base_file bin/lib.sh 'old_fn() { return 0; }'
  commit_case_file bin/lib.sh 'old_fn() { return 0; }
new_fn() { return 1; }' 'add new_fn'
  HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
  write_repro repro.sh '. bin/lib.sh; new_fn 2>/dev/null || exit 1'
  run_verify repro.sh tests/repro-new-fn.test.sh --out "$CASE/evidence" || rc=$?
  expect_code 0 "$rc" "verify new function"
  expect_verify_field 'red-at-both' "verify new function"
  expect_verify_field 'head_result=red' "verify new function"
  expect_verify_field 'base_result=red' "verify new function"
  assert_equals '' "$(cat "$CASE/evidence/head.log")" "verify new function: the head failure is not silent"
  pass "verify-finding: a silent failure in a function the head adds to an existing file is red-at-both"
}

test_verify_finding_a_wrong_helper_path_at_the_head_is_introduced() {
  local rc=0
  make_case verify-wrong-path
  set_case_base_file bin/helper.sh 'greet() { echo hello; }'
  commit_case_file bin/tool.sh '. bin/helper.sh || exit 1; greet' 'add the tool at the base'
  git -C "$REPO" update-ref refs/remotes/origin/main "$(git -C "$REPO" rev-parse HEAD)"
  commit_case_file bin/tool.sh '. bin/helpers.sh || exit 1; greet' 'source the helper from a wrong path'
  HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
  write_repro repro.sh 'bash bin/tool.sh || exit 1'
  run_verify repro.sh tests/repro-tool.test.sh --out "$CASE/evidence" || rc=$?
  expect_code 0 "$rc" "verify wrong path"
  expect_verify_field 'introduced' "verify wrong path"
  expect_verify_field 'head_result=red' "verify wrong path"
  expect_verify_field 'base_result=green' "verify wrong path"
  assert_grep 'No such file or directory' "$CASE/evidence/head.log" "verify wrong path: the head did not fail on the missing helper"
  pass "verify-finding: a helper sourced from a wrong path at the head is introduced, not a run error"
}

test_verify_finding_green_at_head_gives_no_evidence() {
  local rc=0
  make_case verify-green
  write_repro repro.sh 'echo "passes"; exit 0'
  run_verify repro.sh tests/repro-defect.test.sh --out "$CASE/evidence" || rc=$?
  expect_code 0 "$rc" "verify green"
  expect_verify_field 'no-evidence' "verify green"
  expect_verify_field 'head_result=green' "verify green"
  expect_verify_field 'base_result=skipped' "verify green"
  pass "verify-finding: a reproduction that passes at the head gives no evidence"
}

test_verify_finding_timeout_and_outside_writes_give_no_evidence() {
  local rc=0
  make_case verify-timeout
  write_repro slow.sh 'sleep 30; exit 1'
  run_verify slow.sh tests/repro-slow.test.sh --out "$CASE/slow" --timeout 1 || rc=$?
  expect_code 0 "$rc" "verify timeout"
  expect_verify_field 'no-evidence' "verify timeout"
  expect_verify_field 'head_result=timeout' "verify timeout"

  rc=0
  write_repro writer.sh 'echo changed > feature.txt; exit 1'
  run_verify writer.sh tests/repro-writer.test.sh --out "$CASE/writer" || rc=$?
  expect_code 0 "$rc" "verify outside write"
  expect_verify_field 'no-evidence' "verify outside write"
  expect_verify_field 'head_result=wrote-outside' "verify outside write"
  assert_equals 'the feature' "$(cat "$REPO/feature.txt")" "verify outside write: the source repository changed"
  pass "verify-finding: a timeout or a write outside the test directory leaves no evidence"
}

test_verify_finding_reaps_background_children_before_returning() {
  local rc status pid state leaked count
  for status in 0 1; do
    make_case "verify-background-$status"
    write_repro background.sh "sleep 120 & echo \$! >> '$CASE/children'
bash -c 'sleep 120 & echo \$!' >> '$CASE/children'
exit $status"
    rc=0
    run_verify background.sh tests/repro-background.test.sh --out "$CASE/evidence" --timeout 1 || rc=$?
    leaked=0
    count=0
    while IFS= read -r pid; do
      count=$((count + 1))
      state=$(ps -o stat= -p "$pid" 2>/dev/null || true)
      case "$state" in
        '' | *Z*) ;;
        *) leaked=1; kill -KILL "$pid" 2>/dev/null || true ;;
      esac
    done < "$CASE/children"
    expect_code 0 "$rc" "verify background ($(cat "$CASE/stderr"))"
    expect_code 0 "$leaked" "verify background: a child outlived verification"
    if [ "$status" -eq 0 ]; then
      assert_equals 2 "$count" "verify background: the head did not launch both children"
      expect_verify_field 'head_result=green' 'verify background green'
      expect_verify_field 'base_result=skipped' 'verify background green'
    else
      assert_equals 4 "$count" "verify background: both snapshots must launch both children"
      expect_verify_field 'head_result=red' 'verify background red'
      expect_verify_field 'base_result=red' 'verify background red'
    fi
  done
  pass "verify-finding stops background children and orphaned grandchildren on both snapshots"
}

test_verify_finding_reaps_children_before_the_final_manifest() {
  local rc=0
  make_case verify-background-manifest
  write_repro writer.sh '(trap "echo changed > feature.txt; exit 0" TERM
echo ready > tests/ready
while :; do sleep 1; done) &
while [ ! -f tests/ready ]; do sleep 0.01; done
exit 0'
  run_verify writer.sh tests/repro-background-writer.test.sh --out "$CASE/evidence" || rc=$?
  expect_code 0 "$rc" "verify background manifest ($(cat "$CASE/stderr"))"
  expect_verify_field 'head_result=wrote-outside' 'verify background manifest'
  expect_verify_field 'base_result=skipped' 'verify background manifest'
  assert_equals 'the feature' "$(cat "$REPO/feature.txt")" 'verify background manifest: the source repository changed'
  pass "verify-finding records writes made while stopping children in its final manifest"
}

test_verify_finding_refuses_paths_outside_new_test_files_and_supervisors() {
  local rc path
  make_case verify-refuse
  write_repro repro.sh 'exit 1'
  mkdir -p "$REPO/tests"
  printf 'exit 0\n' > "$REPO/tests/kept.test.sh"
  git -C "$REPO" add tests/kept.test.sh
  git -C "$REPO" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'add a test'
  HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
  for path in bin/repro.test.sh tests/../bin/repro.test.sh /tmp/repro.test.sh tests/sub/repro.test.sh \
    tests/repro.sh tests/kept.test.sh; do
    rc=0
    run_verify repro.sh "$path" --out "$CASE/out-${path//\//_}" || rc=$?
    expect_code 2 "$rc" "verify refuses $path"
    [ ! -e "$CASE/out-${path//\//_}/head.log" ] || fail "verify refuses $path: it ran the reproduction"
  done
  rc=0
  run_supervisor verify-finding --repo "$REPO" --head "$HEAD_SHA" --repro "$CASE/repro.sh" \
    --path tests/repro.test.sh --out "$CASE/supervisor" || rc=$?
  expect_code 2 "$rc" "verify refuses a supervisor"
  [ ! -e "$CASE/supervisor/head.log" ] || fail "verify refuses a supervisor: it ran the reproduction"
  rc=0
  run_verify repro.sh tests/repro.test.sh --out "$CASE/once" || rc=$?
  expect_code 0 "$rc" "verify first run"
  rc=0
  run_verify repro.sh tests/repro.test.sh --out "$CASE/once" || rc=$?
  expect_code 2 "$rc" "verify refuses to replace recorded evidence"
  pass "verify-finding refuses paths outside a new tests/*.test.sh file, supervisor sessions, and replaced evidence"
}

# Commit the case repository's index as it stands.
commit_case_index() {  # <message>
  git -C "$REPO" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "$1"
}

test_verify_finding_refuses_a_tests_link_or_a_case_collision() {
  local rc=0
  make_case verify-tests-link
  mkdir -p "$CASE/outside"
  ln -s "$CASE/outside" "$REPO/tests"
  git -C "$REPO" add tests
  commit_case_index 'tests is a link'
  HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
  write_repro repro.sh 'exit 1'
  run_verify repro.sh tests/repro.test.sh --out "$CASE/link" || rc=$?
  expect_code 2 "$rc" "verify tests link"
  assert_absent "$CASE/outside/repro.test.sh" "verify tests link: the reproduction was written through the committed link"
  assert_absent "$CASE/link/head.log" "verify tests link: it ran the reproduction"

  make_case verify-case-collision
  mkdir -p "$REPO/tests"
  printf 'exit 0\n' > "$REPO/tests/kept.test.sh"
  git -C "$REPO" add tests/kept.test.sh
  commit_case_index 'add a test'
  HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
  write_repro repro.sh 'exit 1'
  rc=0
  run_verify repro.sh tests/Kept.test.sh --out "$CASE/collide" || rc=$?
  expect_code 2 "$rc" "verify case collision"
  assert_absent "$CASE/collide/head.log" "verify case collision: it ran the reproduction over a committed test"
  pass "verify-finding refuses a committed tests link and a path that differs from a committed test only by case"
}

test_verify_finding_permission_changes_outside_tests_are_outside_writes() {
  local rc=0
  make_case verify-modes
  write_repro hide.sh 'chmod 000 feature.txt; exit 1'
  run_verify hide.sh tests/repro-hide.test.sh --out "$CASE/hide" || rc=$?
  expect_code 0 "$rc" "verify unreadable outside file ($(cat "$CASE/stderr"))"
  expect_verify_field 'head_result=wrote-outside' "verify unreadable outside file"
  expect_verify_field 'no-evidence' "verify unreadable outside file"

  rc=0
  write_repro exec.sh 'chmod +x feature.txt; exit 1'
  run_verify exec.sh tests/repro-exec.test.sh --out "$CASE/exec" || rc=$?
  expect_code 0 "$rc" "verify mode flip"
  expect_verify_field 'head_result=wrote-outside' "verify mode flip"
  pass "verify-finding: a permission change outside the test directory is an outside write, never evidence"
}

test_verify_finding_removes_a_locked_fixture_directory() {
  local rc=0
  make_case verify-locked
  mkdir -p "$CASE/tmp"
  write_repro locked.sh 'mkdir -p tests/tmp/locked/inner; chmod 500 tests/tmp/locked; exit 1'
  TMPDIR="$CASE/tmp" run_verify locked.sh tests/repro-locked.test.sh --out "$CASE/locked" || rc=$?
  expect_code 0 "$rc" "verify locked fixture ($(cat "$CASE/stderr"))"
  assert_equals '' "$(ls "$CASE/tmp")" "verify locked fixture: the scratch directory leaked"
  pass "verify-finding removes a reproduction's locked fixture directory with its scratch"
}

test_verify_finding_refuses_a_dangling_evidence_link() {
  local rc=0
  make_case verify-dangle
  write_repro repro.sh 'exit 1'
  mkdir -p "$CASE/dangle"
  ln -s "$CASE/nowhere" "$CASE/dangle/base.log"
  rc=0
  run_verify repro.sh tests/repro-dangle.test.sh --out "$CASE/dangle" || rc=$?
  expect_code 2 "$rc" "verify dangling evidence link"
  assert_absent "$CASE/nowhere" "verify dangling evidence link: the link was followed"
  pass "verify-finding refuses an evidence directory holding a dangling link"
}

test_verify_finding_removes_its_scratch_on_a_signal() {
  local rc=0 pid i
  make_case verify-signal
  mkdir -p "$CASE/sig"
  write_repro slow.sh "echo \$\$ > '$CASE/repro.pid'; sleep 120; exit 1"
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_TASK_ID=review-w1 FM_TEST_REVIEW_STUB="$STUB" \
    PATH="$FAKEBIN:$PATH" TMPDIR="$CASE/sig" \
    "$MERGE_REVIEW" verify-finding --repo "$REPO" --head "$HEAD_SHA" --repro "$CASE/slow.sh" \
    --path tests/repro-slow.test.sh --out "$CASE/sig-out" > "$CASE/stdout" 2> "$CASE/stderr" &
  pid=$!
  for i in $(seq 1 600); do
    [ ! -s "$CASE/repro.pid" ] || break
    sleep 0.1
  done
  [ -s "$CASE/repro.pid" ] || fail "verify interrupted: the reproduction never started"
  kill -TERM "$pid"
  # A run that defers the signal until the reproduction ends would hold on
  # for the reproduction's whole lifetime; the signal must stop it promptly.
  for i in $(seq 1 200); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$(cat "$CASE/repro.pid")" "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "verify interrupted: the run kept going for 20s after SIGTERM"
  fi
  rc=0
  wait "$pid" || rc=$?
  [ "$rc" -ne 0 ] || fail "verify interrupted: a terminated run reported success"
  for i in $(seq 1 50); do
    [ -n "$(ls "$CASE/sig")" ] || break
    sleep 0.1
  done
  assert_equals '' "$(ls "$CASE/sig")" "verify interrupted: the scratch directory leaked on SIGTERM"
  for i in $(seq 1 50); do
    kill -0 "$(cat "$CASE/repro.pid")" 2>/dev/null || break
    sleep 0.1
  done
  ! kill -0 "$(cat "$CASE/repro.pid")" 2>/dev/null || fail "verify interrupted: the reproduction outlived the run"
  pass "verify-finding stops the reproduction and removes its scratch on a signal"
}

test_verify_finding_stops_the_reproduction_on_a_process_group_signal() {
  local rc=0 pid i
  make_case verify-group-signal
  mkdir -p "$CASE/sig"
  write_repro slow.sh "echo \$\$ > '$CASE/repro.pid'; sleep 120; exit 1"
  # A tool runner or a terminal hangup signals the whole process group, so
  # run the command as its own group leader and signal that group.
  set -m
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_TASK_ID=review-w1 FM_TEST_REVIEW_STUB="$STUB" \
    PATH="$FAKEBIN:$PATH" TMPDIR="$CASE/sig" \
    "$MERGE_REVIEW" verify-finding --repo "$REPO" --head "$HEAD_SHA" --repro "$CASE/slow.sh" \
    --path tests/repro-slow.test.sh --out "$CASE/sig-out" > "$CASE/stdout" 2> "$CASE/stderr" < /dev/null &
  pid=$!
  set +m
  for i in $(seq 1 600); do
    [ ! -s "$CASE/repro.pid" ] || break
    sleep 0.1
  done
  [ -s "$CASE/repro.pid" ] || fail "verify group signal: the reproduction never started"
  kill -TERM -- "-$pid"
  for i in $(seq 1 200); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL -- "-$pid" 2>/dev/null || true
    fail "verify group signal: the run outlived its process-group signal"
  fi
  rc=0
  wait "$pid" || rc=$?
  [ "$rc" -ne 0 ] || fail "verify group signal: a terminated run reported success"
  for i in $(seq 1 50); do
    kill -0 "$(cat "$CASE/repro.pid")" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$(cat "$CASE/repro.pid")" 2>/dev/null; then
    kill -KILL "$(cat "$CASE/repro.pid")" 2>/dev/null || true
    fail "verify group signal: the reproduction outlived the run"
  fi
  assert_equals '' "$(ls "$CASE/sig")" "verify group signal: the scratch directory leaked"
  pass "verify-finding stops the reproduction and removes its scratch when its process group is signalled"
}

test_verify_finding_refuses_a_head_already_in_the_base() {
  local rc=0
  make_case verify-same-base
  write_repro same.sh 'exit 1'
  run_verify same.sh tests/repro-same.test.sh --base "$HEAD_SHA" --out "$CASE/same" || rc=$?
  expect_code 2 "$rc" "verify head already in base"
  assert_absent "$CASE/same/result" "verify head already in base: no evidence is recorded"
  pass "verify-finding refuses a head that is already contained in the base"
}

test_verify_finding_refuses_when_the_tree_manifest_cannot_read_permissions() {
  local rc=0
  make_case verify-mode-unreadable
  mkdir -p "$CASE/statbin"
  cat > "$CASE/statbin/stat" <<'STAT'
#!/bin/bash
case "$*" in *'mode %'*) exit 1 ;; esac
for real in /usr/bin/stat /bin/stat; do [ -x "$real" ] && exec "$real" "$@"; done
exit 127
STAT
  chmod +x "$CASE/statbin/stat"
  write_repro quiet.sh 'chmod +x feature.txt; exit 0'
  PATH="$CASE/statbin:$PATH" run_verify quiet.sh tests/repro-quiet.test.sh --out "$CASE/quiet" || rc=$?
  expect_code 2 "$rc" "verify unreadable permissions ($(cat "$CASE/stderr" 2>/dev/null))"
  assert_absent "$CASE/quiet/result" "verify unreadable permissions: no evidence is recorded"
  pass "verify-finding refuses rather than compare a manifest missing its permission bits"
}

test_verify_finding_runs_the_reproduction_without_firstmate_home_or_task_scope() {
  local rc=0
  make_case verify-scrub
  # shellcheck disable=SC2016 # the reproduction, not this test, must expand these
  write_repro scrub.sh '[ -z "${FM_STATE_OVERRIDE:-}${FM_CONFIG_OVERRIDE:-}${FM_TASK_INBOX:-}${AK_LIFECYCLE_POLICY:-}" ] || { env | grep -E "^(FM_|AK_)"; exit 1; }'
  FM_STATE_OVERRIDE="$CASE/live-state" FM_CONFIG_OVERRIDE="$CASE/live-config" FM_TASK_INBOX="$CASE/inbox" \
    AK_LIFECYCLE_POLICY=unattended run_verify scrub.sh tests/repro-scrub.test.sh --out "$CASE/scrub" || rc=$?
  expect_code 0 "$rc" "verify scrub"
  expect_verify_field 'head_result=green' "verify scrub ($(cat "$CASE/scrub/head.log" 2>/dev/null))"
  pass "verify-finding runs the reproduction without the caller's Firstmate home, task or lifecycle scope"
}

# assert_line <line> <file> <msg>: <file> holds exactly <line> as a whole line.
assert_line() {
  grep -Fx -- "$1" "$2" >/dev/null || fail "$3"
}

# Commit a follow-up change on the case repository and make it the head.
next_head() {  # <text>
  printf '%s\n' "$1" >> "$REPO/feature.txt"
  git -C "$REPO" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qam "fix: $1"
  HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
}

test_receipts_record_round_scope_and_tokens() {
  local first second store receipt
  make_case rounds "${TWO_SEATS[@]}"
  echo '1200 80 300' > "$STUB/claude.tokens"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || fail "rounds: the first head did not approve"
  first=$(store_dir)
  receipt="$first/anthropic.claude.claude-test-1.receipt"
  assert_line 'round=1' "$receipt" "rounds: the first reviewed head is not round 1"
  assert_line 'scope=full' "$receipt" "rounds: the receipt does not name a full review scope"
  assert_equals "$(sed -n 's/^diff_sha256=//p' "$receipt")" "$(sed -n 's/^scope_sha256=//p' "$receipt")" \
    "rounds: a full scope must hash the reviewed diff"
  assert_line 'tokens_in=1500' "$receipt" "rounds: input and cache-read tokens were not summed"
  assert_line 'tokens_out=80' "$receipt" "rounds: output tokens were not recorded"
  assert_line 'tokens_in=' "$first/google.agy.gemini-test-high.receipt" \
    "rounds: a tool that reports no usage must leave the token fields empty"

  next_head 'second round'
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || fail "rounds: the second head did not approve"
  second=$(store_dir)
  assert_line 'round=2' "$second/anthropic.claude.claude-test-1.receipt" "rounds: the next reviewed head is not round 2"
  assert_line 'round=2' "$second/google.agy.gemini-test-high.receipt" "rounds: seats at one head disagree on the round"

  set_started "$first" $(( $(date +%s) - 60 ))
  rm -f "$second/google.agy.gemini-test-high."*
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || fail "rounds: the rerun did not approve"
  assert_line 'round=2' "$second/google.agy.gemini-test-high.receipt" "rounds: a rerun at the same head moved the round"
  pass "receipts record the review round across heads, the full scope, and the tokens the tool reported"
}

# Rewrite the started= line of every receipt in one head directory.
set_started() {  # <head-dir> <epoch>
  local receipt
  for receipt in "$1"/*.receipt; do
    sed "s/^started=.*/started=$2/" "$receipt" > "$receipt.tmp" && mv "$receipt.tmp" "$receipt"
  done
}

test_a_new_head_started_in_the_same_second_is_the_next_round() {
  local first
  make_case same-second "${TWO_SEATS[@]}"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || fail "same-second: the first head did not approve"
  first=$(store_dir)
  set_started "$first" $(( $(date +%s) + 3600 ))
  next_head 'same second'
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || fail "same-second: the second head did not approve"
  assert_line 'round=2' "$(store_dir)/anthropic.claude.claude-test-1.receipt" \
    "same-second: a new head whose predecessor started in the same second is not round 2"
  pass "a new head counts every earlier reviewed head even when their start times tie"
}

test_receipts_read_tokens_from_top_level_usage() {  # a model entry without counts
  local receipt
  make_case usage-only "${TWO_SEATS[@]}"
  echo '{"input_tokens": 5, "cache_read_input_tokens": 2, "output_tokens": 9}' > "$STUB/claude.usage"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || fail "usage-only: the head did not approve"
  receipt="$(store_dir)/anthropic.claude.claude-test-1.receipt"
  assert_line 'tokens_in=7' "$receipt" "usage-only: input and cache-read tokens in top-level usage were not summed"
  assert_line 'tokens_out=9' "$receipt" "usage-only: output tokens in top-level usage were not recorded"
  pass "receipts read token counts a tool reports only in top-level usage"
}

test_metrics_count_rounds_calls_and_tokens_per_pull_request() {
  local rc=0 line
  make_case metrics "${TWO_SEATS[@]}"
  run_supervisor metrics || rc=$?
  expect_code 0 "$rc" "metrics: an empty home"
  assert_grep 'merge-review-metrics: summary prs=0 ' "$CASE/stdout" "metrics: an empty home must still print the summary"

  echo '1000 50 0' > "$STUB/claude.tokens"
  echo block > "$STUB/agy.mode"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || true
  next_head 'fixed'
  echo approve > "$STUB/agy.mode"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || fail "metrics: the second head did not approve"

  rc=0
  run_supervisor metrics || rc=$?
  expect_code 0 "$rc" "metrics: a supervisor reads the metrics"
  line=$(grep '^merge-review-metrics: pr ' "$CASE/stdout")
  assert_equals 1 "$(printf '%s\n' "$line" | grep -c .)" "metrics: one line per pull request"
  case "$line" in
    *" url=$PR_URL "*) ;;
    *) fail "metrics: the line does not name the pull request: $line" ;;
  esac
  for field in rounds=2 seat_calls=4 blocks=1 tokens_in=2000 tokens_out=100 tokens_unreported=2; do
    case " $line " in
      *" $field "*) ;;
      *) fail "metrics: expected $field in: $line" ;;
    esac
  done
  assert_grep 'merge-review-metrics: summary prs=1 rounds_median=2 rounds_max=2 seat_calls=4 ' "$CASE/stdout" \
    "metrics: the summary does not total the pull requests"
  assert_equals 4 "$(( $(calls claude) + $(calls agy) ))" "metrics: reading metrics called a reviewer"

  run_supervisor metrics --since "$(( $(date +%s) + 3600 ))" || fail "metrics: --since failed"
  assert_grep 'merge-review-metrics: summary prs=0 ' "$CASE/stdout" "metrics: --since kept older review activity"
  rc=0
  run_supervisor metrics --since soon || rc=$?
  expect_code 2 "$rc" "metrics: a malformed --since"
  pass "metrics count rounds, seat calls, blocks, and tokens per pull request and in one summary"
}

# ---- Converging review (config/merge-review ak=) ---------------------------
# These cases run the real agent-kit ak, because ak review owns the rule:
# FM_TEST_AK names it, or the vendored .cursor/bin/ak when it has the review
# command. A host with neither skips them by name.
converge_ak() {
  local ak=${FM_TEST_AK:-$ROOT/.cursor/bin/ak}
  [ -x "$ak" ] || return 1
  ( cd / && "$ak" review 2>&1 ) | grep -q '^usage: ak review ledger add' || return 1
  printf '%s\n' "$ak"
}

CONVERGE_AK=$(converge_ak) || CONVERGE_AK=

converge_skip() {  # <case>
  [ -z "$CONVERGE_AK" ] || return 1
  pass "SKIP: $1 (no ak with the review command; set FM_TEST_AK)"
}

# The pull request adds twenty lines, so a one-line fix stays inside the
# reviewed scope rather than growing it past ak's limit.
converge_case() {  # <name>
  make_case "$1" "${TWO_SEATS[@]}" "ak=$CONVERGE_AK"
  seq 1 20 | sed 's/^/feature line /' > "$REPO/feature.txt"
  git -C "$REPO" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q --amend -am feature
  HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
}

# Commit a one-line change to feature.txt and make it the head under review.
converge_next_head() {  # <text>
  { printf '%s\n' "$1"; sed 1d "$REPO/feature.txt"; } > "$REPO/feature.txt.new"
  mv "$REPO/feature.txt.new" "$REPO/feature.txt"
  git -C "$REPO" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qam "$1"
  HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
}

ledger_file() {
  printf '%s/data/merge-review/github/github.com/example/repo/7/ledger.jsonl\n' "$HOME_DIR"
}

FINDING_P1='FINDING: P1 | correctness | introduced | feature.txt:1 | reader-breaks | feature.txt breaks the reader.'

test_converge_full_round_records_the_ledger_and_approves() {
  local rc=0 store
  converge_skip 'converge: full round' && return 0
  converge_case converge-full
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "converge full: run with two approving families ($(cat "$CASE/stderr"))"
  assert_grep "merge-review: approved head=$HEAD_SHA seats=" "$CASE/stdout" "converge full: run did not end approved"
  assert_grep ' round=1 action=none ' "$CASE/stdout" "converge full: the line did not name round 1 and no next action"
  assert_grep '"mode":"full"' "$(ledger_file)" "converge full: the ledger has no full round"
  store=$(store_dir)
  assert_grep 'scope=full' "$store/anthropic.claude.claude-test-1.receipt" "converge full: the receipt is not a full-scope review"
  assert_grep 'full round of a converging review' "$STUB/claude.prompt" "converge full: the prompt did not name the round"
  assert_grep 'FINDING: <P0|P1|P2|P3>' "$STUB/claude.prompt" "converge full: the prompt did not give the finding grammar"
  rc=0
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" || rc=$?
  expect_code 0 "$rc" "converge full: a supervisor check"
  assert_equals 1 "$(wc -l < "$CASE/stdout" | tr -d ' ')" "converge full: check must print exactly one line"
  pass "a converging full round records the ledger and approves through ak review decide"
}

test_converge_a_near_miss_category_is_dropped_not_recorded() {
  local rc=0
  converge_skip 'converge: near-miss category' && return 0
  converge_case converge-near-miss
  {
    printf '%s\n' 'FINDING: P2 | correct | introduced | feature.txt:1 | near-correct | A prefix of a declared category.'
    printf '%s\n' 'FINDING: P2 | doc | introduced | feature.txt:2 | near-docs | A prefix of a declared category.'
    printf '%s\n' 'FINDING: P2 |  | introduced | feature.txt:3 | no-category | An empty category.'
  } > "$STUB/claude.extra"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "converge near-miss: run with malformed categories ($(cat "$CASE/stdout") $(cat "$CASE/stderr"))"
  assert_grep "merge-review: approved head=$HEAD_SHA seats=" "$CASE/stdout" "converge near-miss: the round was not recorded and approved"
  assert_no_grep 'near-correct' "$(ledger_file)" "converge near-miss: a category prefix reached the ledger"
  assert_no_grep 'near-docs' "$(ledger_file)" "converge near-miss: a category prefix reached the ledger"
  assert_no_grep 'no-category' "$(ledger_file)" "converge near-miss: an empty category reached the ledger"
  pass "a converging round drops a finding whose category only resembles a declared one"
}

test_converge_a_finding_in_a_path_with_a_space_blocks() {
  local rc=0
  converge_skip 'converge: path with a space' && return 0
  converge_case converge-space-path
  printf '%s\n' 'FINDING: P0 | correctness | introduced | docs/My Notes.md:12 | note-parser | The parser drops this file.' > "$STUB/claude.extra"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 1 "$rc" "converge space path: run with a P0 finding in a path with a space ($(cat "$CASE/stdout") $(cat "$CASE/stderr"))"
  assert_grep "merge-review: blocked head=$HEAD_SHA" "$CASE/stdout" "converge space path: the finding did not block ($(cat "$CASE/stdout"))"
  assert_grep 'docs/My Notes.md' "$(ledger_file)" "converge space path: the finding never reached the ledger"
  pass "a converging round records and blocks on a finding whose path contains a space"
}

test_converge_fix_only_round_closes_a_blocking_finding() {
  local rc=0 store
  converge_skip 'converge: fix-only round' && return 0
  converge_case converge-fix
  echo block > "$STUB/claude.mode"
  printf '%s\n' "$FINDING_P1" > "$STUB/claude.extra"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 1 "$rc" "converge fix: run with a blocking P1 finding ($(cat "$CASE/stderr"))"
  assert_grep "merge-review: blocked head=$HEAD_SHA" "$CASE/stdout" "converge fix: the P1 finding did not block ($(cat "$CASE/stdout"))"
  assert_grep ' blocks=F1 ' "$CASE/stdout" "converge fix: the line did not name the blocking row"
  rc=0
  run_review respond "$PR_URL" --finding F1 --response dispute || rc=$?
  expect_code 2 "$rc" "converge fix: a dispute without a claim"
  rc=0
  run_review respond "$PR_URL" --finding F1 --response fixed --claim unsupported || rc=$?
  expect_code 2 "$rc" "converge fix: a claim on a fixed response"
  rc=0
  run_review respond "$PR_URL" --finding F1 --response fixed || rc=$?
  expect_code 0 "$rc" "converge fix: the author's response ($(cat "$CASE/stderr"))"

  converge_next_head 'the fixed feature'
  rm -f "$STUB/claude.mode" "$STUB/claude.extra"
  echo addressed > "$STUB/claude.close"
  rc=0
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "converge fix: the closure round ($(cat "$CASE/stdout") $(cat "$CASE/stderr"))"
  assert_grep ' round=2 action=none ' "$CASE/stdout" "converge fix: the closure round is not round 2 ($(cat "$CASE/stdout"))"
  store=$(store_dir)
  assert_grep 'scope=closure' "$store/google.agy.gemini-test-high.receipt" "converge fix: the receipt is not a closure-scope review"
  assert_grep 'delta=yes' "$STUB/claude.delta" "converge fix: the reviewer had no delta.patch"
  assert_grep 'fix-only round of a converging review' "$STUB/claude.prompt" "converge fix: the prompt did not name the fix-only round"
  assert_grep 'F1 | P1 | correctness | feature.txt:1 | ' "$STUB/claude.prompt" "converge fix: the prompt did not list the open finding"
  pass "a fix-only round reviews the delta and closes the finding its seat raised"
}

test_converge_a_new_finding_without_a_repro_is_filed_not_blocking() {
  local rc=0
  converge_skip 'converge: unproven new finding' && return 0
  converge_case converge-followup
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "converge followup: round 1 ($(cat "$CASE/stderr"))"
  converge_next_head 'a second change'
  echo block > "$STUB/agy.mode"
  printf '%s\n' "$FINDING_P1" > "$STUB/agy.extra"
  rc=0
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 1 "$rc" "converge followup: a closure round with a new unproven finding"
  assert_no_grep 'merge-review: blocked' "$CASE/stdout" "converge followup: one seat's unproven finding blocked the change"
  assert_grep ' action=file-follow-ups ' "$CASE/stdout" "converge followup: the line did not ask for the follow-up ($(cat "$CASE/stdout"))"
  rc=0
  run_review followup "$PR_URL" --finding F1 --ref https://github.com/example/repo/issues/9 || rc=$?
  expect_code 0 "$rc" "converge followup: recording the follow-up ($(cat "$CASE/stderr"))"
  rc=0
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" || rc=$?
  expect_code 0 "$rc" "converge followup: check after the follow-up ($(cat "$CASE/stdout"))"
  pass "after round 1 a new finding without a reproduction is filed as a follow-up, and no single seat vetoes"
}

test_converge_a_reproduced_new_finding_blocks() {
  local rc=0 store
  converge_skip 'converge: reproduced new finding' && return 0
  converge_case converge-repro
  printf 'repro=on\n' >> "$HOME_DIR/config/merge-review"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "converge repro: round 1 ($(cat "$CASE/stderr"))"
  converge_next_head 'a second change'
  echo block > "$STUB/agy.mode"
  printf '%s\n' "$FINDING_P1" 'REPRO-BEGIN' '[ ! -f feature.txt ]' 'REPRO-END' > "$STUB/agy.extra"
  rc=0
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 1 "$rc" "converge repro: a closure round with a reproduced finding"
  assert_grep "merge-review: blocked head=$HEAD_SHA" "$CASE/stdout" "converge repro: the reproduced finding did not block ($(cat "$CASE/stdout") $(cat "$CASE/stderr"))"
  store=$(store_dir)
  assert_present "$(find "$store/evidence" -path "$store/evidence/F1.*/result" 2>/dev/null | head -n 1)" "converge repro: the reproduction evidence is missing"
  assert_grep 'comes with a reproduction that fails at the head and passes at the merge base' "$STUB/agy.prompt" "converge repro: the closure prompt did not offer a blocking reproduction"
  pass "a new finding whose reproduction fails at the head and passes at the merge base blocks"
}

test_converge_a_green_sibling_reproduction_keeps_the_introduced_one() {
  local rc=0
  converge_skip 'converge: introduced and green reproductions in one round' && return 0
  converge_case converge-repro-sibling
  printf 'repro=on\n' >> "$HOME_DIR/config/merge-review"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "converge sibling: round 1 ($(cat "$CASE/stderr"))"
  converge_next_head 'a second change'
  echo block > "$STUB/agy.mode"
  printf '%s\n' "$FINDING_P1" 'REPRO-BEGIN' '[ ! -f feature.txt ]' 'REPRO-END' > "$STUB/agy.extra"
  printf '%s\n' 'FINDING: P1 | correctness | introduced | feature.txt:2 | other-break | feature.txt breaks the writer.' \
    'REPRO-BEGIN' 'exit 0' 'REPRO-END' > "$STUB/claude.extra"
  rc=0
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 1 "$rc" "converge sibling: a closure round with an introduced and a green reproduction"
  assert_grep "merge-review: blocked head=$HEAD_SHA" "$CASE/stdout" "converge sibling: the introduced reproduction did not block ($(cat "$CASE/stdout") $(cat "$CASE/stderr"))"
  assert_grep '"kind":"round-close"' <(tail -n 1 "$(ledger_file)") "converge sibling: the round was left open"
  pass "a green reproduction beside an introduced one in the same round never drops the introduced evidence"
}

test_converge_a_red_at_both_reproduction_does_not_block() {
  local rc=0
  converge_skip 'converge: red-at-both reproduction' && return 0
  converge_case converge-repro-both
  printf 'repro=on\n' >> "$HOME_DIR/config/merge-review"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "converge red-at-both: round 1 ($(cat "$CASE/stderr"))"
  converge_next_head 'a second change'
  echo block > "$STUB/agy.mode"
  printf '%s\n' "$FINDING_P1" 'REPRO-BEGIN' 'exit 1' 'REPRO-END' > "$STUB/agy.extra"
  rc=0
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 1 "$rc" "converge red-at-both: a closure round with a reproduction red at both ($(cat "$CASE/stdout") $(cat "$CASE/stderr"))"
  assert_no_grep 'merge-review: blocked' "$CASE/stdout" "converge red-at-both: a reproduction red at both blocked ($(cat "$CASE/stdout") $(cat "$CASE/stderr"))"
  assert_grep ' action=file-follow-ups ' "$CASE/stdout" "converge red-at-both: the finding was not filed as a follow-up ($(cat "$CASE/stdout"))"
  assert_grep '"kind":"round-close"' <(tail -n 1 "$(ledger_file)") "converge red-at-both: the round was left open"
  pass "a correctness finding whose reproduction is red at the head and at the merge base does not block"
}

test_converge_a_red_at_both_security_reproduction_still_blocks() {
  local rc=0
  converge_skip 'converge: red-at-both security reproduction' && return 0
  converge_case converge-repro-both-security
  printf 'repro=on\n' >> "$HOME_DIR/config/merge-review"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "converge red-at-both security: round 1 ($(cat "$CASE/stderr"))"
  converge_next_head 'a second change'
  echo block > "$STUB/agy.mode"
  printf '%s\n' 'FINDING: P1 | security | introduced | feature.txt:1 | reader-leaks | feature.txt leaks a token.' \
    'RISK: the deploy token -> anyone who reads feature.txt can deploy' 'REPRO-BEGIN' 'exit 1' 'REPRO-END' > "$STUB/agy.extra"
  rc=0
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 1 "$rc" "converge red-at-both security: a closure round with a security finding red at both"
  assert_grep "merge-review: blocked head=$HEAD_SHA" "$CASE/stdout" "converge red-at-both security: the security finding did not block ($(cat "$CASE/stdout") $(cat "$CASE/stderr"))"
  pass "a security finding whose reproduction is red at both still blocks"
}

test_converge_a_reproduction_runs_only_with_the_opt_in() {
  local rc=0 store
  converge_skip 'converge: reproduction without the opt-in' && return 0
  converge_case converge-repro-off
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "converge repro-off: round 1 ($(cat "$CASE/stderr"))"
  converge_next_head 'a second change'
  echo block > "$STUB/agy.mode"
  printf '%s\n' "$FINDING_P1" 'REPRO-BEGIN' "touch '$CASE/repro-ran'" 'exit 1' 'REPRO-END' > "$STUB/agy.extra"
  rc=0
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 1 "$rc" "converge repro-off: a closure round with a reproduction and no opt-in"
  assert_absent "$CASE/repro-ran" "converge repro-off: the reviewer-written reproduction ran without repro=on"
  store=$(store_dir)
  assert_absent "$store/evidence" "converge repro-off: reproduction evidence was recorded without repro=on"
  assert_no_grep 'merge-review: blocked' "$CASE/stdout" "converge repro-off: an unrun reproduction blocked the change ($(cat "$CASE/stdout"))"
  assert_grep ' action=file-follow-ups ' "$CASE/stdout" "converge repro-off: the finding was not filed as a follow-up ($(cat "$CASE/stdout"))"
  assert_grep 'This round runs no reproduction' "$STUB/agy.prompt" "converge repro-off: the closure prompt did not say no reproduction runs"
  assert_no_grep 'comes with a reproduction' "$STUB/agy.prompt" "converge repro-off: the closure prompt promised a reproduction would block"
  pass "without repro=on a reviewer's reproduction never runs and its finding is filed, not blocking"
}

test_converge_a_moved_merge_base_never_approves_the_old_round() {
  local rc=0 base feature store
  converge_skip 'converge: moved merge base' && return 0
  converge_case converge-moved-base
  base=$(git -C "$REPO" rev-parse refs/remotes/origin/main)
  feature=$HEAD_SHA
  git -C "$REPO" reset -q --hard "$base"
  printf 'an upstream change\n' > "$REPO/upstream.txt"
  git -C "$REPO" add upstream.txt
  git -C "$REPO" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm upstream
  git -C "$REPO" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' cherry-pick "$feature" >/dev/null
  HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "converge moved-base: round 1 at the first merge base ($(cat "$CASE/stderr"))"
  git -C "$REPO" update-ref refs/remotes/origin/main "$(git -C "$REPO" rev-parse HEAD^)"
  echo block > "$STUB/agy.mode"
  printf '%s\n' "$FINDING_P1" > "$STUB/agy.extra"
  rc=0
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  [ "$rc" -ne 0 ] || fail "converge moved-base: the rerun at a moved merge base approved ($(cat "$CASE/stdout"))"
  assert_no_grep 'merge-review: approved' "$CASE/stdout" "converge moved-base: the old round approved at the new merge base"
  assert_equals 1 "$(calls agy)" "converge moved-base: a seat was called for a head the ledger already holds"
  store=$(store_dir)
  assert_equals "$base" "$(sed -n 's/^base=//p' "$store/ledger.bind")" "converge moved-base: the ledger binding was moved to the new merge base"
  rc=0
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" --base "$(git -C "$REPO" rev-parse HEAD^)" || rc=$?
  expect_code 1 "$rc" "converge moved-base: a supervisor check at the new merge base"
  assert_grep 'merge-review: incomplete' "$CASE/stdout" "converge moved-base: the check is not incomplete ($(cat "$CASE/stdout"))"
  pass "a head whose merge base moved after its round calls no seat and stays incomplete, never approved"
}

test_converge_an_unchanged_delta_carries_without_seats() {
  local rc=0 before
  converge_skip 'converge: carry' && return 0
  converge_case converge-carry
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "converge carry: round 1 ($(cat "$CASE/stderr"))"
  before=$(( $(calls claude) + $(calls agy) ))
  git -C "$REPO" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q --amend -m 'feature, reworded'
  HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
  rc=0
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "converge carry: a reworded head ($(cat "$CASE/stdout") $(cat "$CASE/stderr"))"
  assert_equals "$before" "$(( $(calls claude) + $(calls agy) ))" "converge carry: a seat was called for an unchanged delta"
  pass "a head with the same patch carries the earlier verdict and calls no seat"
}

test_converge_a_changed_ledger_never_approves() {
  local rc=0 ledger
  converge_skip 'converge: changed ledger' && return 0
  converge_case converge-tamper
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 0 "$rc" "converge tamper: round 1 ($(cat "$CASE/stderr"))"
  ledger=$(ledger_file)
  sed '$d' "$ledger" > "$ledger.new" && mv "$ledger.new" "$ledger"
  rc=0
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" || rc=$?
  expect_code 1 "$rc" "converge tamper: check after a ledger line was removed"
  assert_no_grep 'merge-review: approved' "$CASE/stdout" "converge tamper: a changed ledger approved"
  assert_grep 'review ledger' "$CASE/stdout" "converge tamper: the line did not name the ledger problem ($(cat "$CASE/stdout"))"
  pass "a ledger changed after its round never approves"
}

test_converge_the_round_cap_parks_without_approving() {
  local rc=0 n
  converge_skip 'converge: round cap' && return 0
  converge_case converge-cap
  echo block > "$STUB/claude.mode"
  printf '%s\n' "$FINDING_P1" > "$STUB/claude.extra"
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  expect_code 1 "$rc" "converge cap: round 1"
  rm -f "$STUB/claude.extra"
  echo not-addressed > "$STUB/claude.close"
  for n in 2 3; do
    converge_next_head "attempt $n"
    rc=0
    run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
    expect_code 1 "$rc" "converge cap: round $n ($(cat "$CASE/stdout") $(cat "$CASE/stderr"))"
  done
  assert_grep ' round=3 ' "$CASE/stdout" "converge cap: the last line is not round 3"
  converge_next_head 'attempt 4'
  rc=0
  run_review run "$PR_URL" --head "$HEAD_SHA" --repo "$REPO" || rc=$?
  [ "$rc" -ne 0 ] || fail "converge cap: a fourth round approved ($(cat "$CASE/stdout"))"
  assert_no_grep 'merge-review: approved' "$CASE/stdout" "converge cap: the change approved past the cap"
  pass "at the three-round cap the review parks and never approves"
}

test_converge_configuration_refuses_an_unsafe_ak() {
  local rc=0
  make_case converge-config "${TWO_SEATS[@]}" 'ak=bin/ak'
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" || rc=$?
  expect_code 2 "$rc" "converge config: a relative ak path"
  assert_grep 'absolute path' "$CASE/stderr" "converge config: the refusal did not ask for an absolute path"
  printf '#!/bin/sh\nexit 0\n' > "$CASE/ak"
  chmod +x "$CASE/ak"
  printf '%s\n' 'seat=anthropic:claude:m.1' 'seat=anthropic:claude:m-1' 'seat=google:agy:gemini-test-high' "ak=$CASE/ak" \
    > "$HOME_DIR/config/merge-review"
  rc=0
  run_supervisor check "$PR_URL" --head "$HEAD_SHA" || rc=$?
  expect_code 2 "$rc" "converge config: two seats with one agent-kit seat id"
  assert_grep 'share the agent-kit seat id' "$CASE/stderr" "converge config: the refusal did not name the shared seat id"
  pass "an ak setting refuses a relative path and seats that share one agent-kit seat id"
}
fm_test_run test_converge_the_round_cap_parks_without_approving test_converge_configuration_refuses_an_unsafe_ak
