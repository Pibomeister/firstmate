#!/usr/bin/env bash
# Behavior tests for bin/fm-pstack-verify-hook.sh. Each hit drives a
# host-shaped payload through the public stdin/stdout/exit interface and
# checks the JSON that host documents for that event. Near-misses stay silent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOOK="$ROOT/bin/fm-pstack-verify-hook.sh"
TMP_ROOT=$(fm_test_tmproot fm-pstack-verify-hook)
trap fm_test_cleanup EXIT

RUN_OUT=
RUN_STATUS=0

run_hook() {  # <root> <payload-json> [flags...]
  local root=$1 payload=$2
  shift 2
  RUN_STATUS=0
  RUN_OUT=$(printf '%s' "$payload" | env -u FM_HOME \
    FM_ROOT_OVERRIDE="$root" FM_STATE_OVERRIDE="$root/state" \
    bash "$HOOK" "$@") || RUN_STATUS=$?
}

expect_exit_ok() {  # <label>
  expect_code 0 "$RUN_STATUS" "$1: hook must exit 0, got $RUN_STATUS"
}

# Cursor postToolUse / postToolUseFailure / sessionStart output
# additional_context (https://cursor.com/docs/hooks). afterAgentResponse and
# afterShellExecution have no documented output fields.
expect_cursor_inject() {  # <principle> <label>
  expect_exit_ok "$2"
  [ -n "$RUN_OUT" ] || fail "$2: expected JSON, got empty stdout"
  printf '%s' "$RUN_OUT" | jq -e --arg p "$1" '
      (keys | sort) == ["additional_context"]
      and (.additional_context|type=="string")
      and (.additional_context|contains($p))
    ' >/dev/null 2>&1 || fail "$2: Cursor additional_context schema/principle $1, got: $RUN_OUT"
}

expect_cursor_continue_only() {  # <label>
  expect_exit_ok "$1"
  printf '%s' "$RUN_OUT" | jq -e '. == {"continue":true}' >/dev/null 2>&1 \
    || fail "$1: beforeSubmitPrompt must be exactly {\"continue\":true}, got: $RUN_OUT"
}

# Claude UserPromptSubmit / PreToolUse / PostToolUse output
# hookSpecificOutput.additionalContext.
expect_claude_inject() {  # <principle> <event> <label>
  expect_exit_ok "$3"
  [ -n "$RUN_OUT" ] || fail "$3: expected JSON, got empty stdout"
  printf '%s' "$RUN_OUT" | grep -Fq permissionDecision \
    && fail "$3: output must not contain permissionDecision, got: $RUN_OUT"
  printf '%s' "$RUN_OUT" | jq -e --arg p "$1" --arg e "$2" '
      (keys | sort) == ["hookSpecificOutput"]
      and (.hookSpecificOutput.hookEventName == $e)
      and (.hookSpecificOutput.additionalContext|type=="string")
      and (.hookSpecificOutput.additionalContext|contains($p))
      and (tostring | contains("permissionDecision") | not)
    ' >/dev/null 2>&1 || fail "$3: Claude schema/principle $1 event $2, got: $RUN_OUT"
}

expect_silent() {  # <label>
  expect_exit_ok "$1"
  [ -z "$RUN_OUT" ] || fail "$1: expected no injection, got: $RUN_OUT"
}

PRIMARY="$TMP_ROOT/primary"
mkdir -p "$PRIMARY/state"

STATUS_APPEND='echo "done [at=1731880000]: shipped the export" >> /tmp/task.status && true'

test_status_append_command_injects_prove_it_works() {
  run_hook "$PRIMARY" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$STATUS_APPEND" | jq -Rs .)}}" \
    --claude
  expect_claude_inject "principle-prove-it-works" "PreToolUse" "STATUS_APPEND echo of done [at=]"
  pass "a STATUS_APPEND command injects principle-prove-it-works"
}

test_cursor_post_tool_use_status_append_injects() {
  run_hook "$PRIMARY" \
    "{\"hook_event_name\":\"postToolUse\",\"tool_name\":\"Shell\",\"tool_input\":{\"command\":$(printf '%s' "$STATUS_APPEND" | jq -Rs .)},\"tool_output\":\"{\\\"exitCode\\\":0}\",\"cursor_version\":\"x\",\"conversation_id\":\"c1\",\"generation_id\":\"g\"}" \
    --cursor
  expect_cursor_inject "principle-prove-it-works" "Cursor postToolUse STATUS_APPEND"
  pass "Cursor postToolUse Shell STATUS_APPEND injects principle-prove-it-works"
}

test_write_contents_done_line_injects_prove_it_works() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"state/t.status","content":"done [at=1731880000]: shipped\n"}}' \
    --claude
  expect_claude_inject "principle-prove-it-works" "PreToolUse" "Write content with a done line"
  pass "Write content holding a done line injects principle-prove-it-works"
}

test_captain_prompt_done_merge_is_not_completion() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"beforeSubmitPrompt","prompt":"done: merge it","cursor_version":"x","generation_id":"g"}' \
    --cursor
  expect_cursor_continue_only "captain prompt done: merge it"
  pass "done: merge it on a captain prompt does not inject principle-prove-it-works"
}

test_this_is_faster_than_main_is_a_speed_claim() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"this is faster than main"}' \
    --claude
  expect_claude_inject "principle-explain-the-number" "UserPromptSubmit" "X is faster than Y"
  pass "this is faster than main injects principle-explain-the-number"
}

test_working_status_is_not_a_completion_report() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"afterAgentResponse","text":"working: still implementing the export","cursor_version":"x","generation_id":"g"}' \
    --cursor
  expect_silent "working: is not a completion report"
  pass "a working: line does not inject principle-prove-it-works"
}

test_checks_green_question_is_not_completion() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"are the checks green yet?"}' \
    --claude
  expect_silent "checks-green question"
  pass "are the checks green yet? does not inject principle-prove-it-works"
}

test_working_checks_green_so_far_is_not_completion() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"afterAgentResponse","text":"working: checks green so far","cursor_version":"x","generation_id":"g"}' \
    --cursor
  expect_silent "working: checks green so far"
  pass "working: checks green so far does not inject principle-prove-it-works"
}

test_implementation_complete_question_is_not_completion() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"is the implementation complete?"}' \
    --claude
  expect_silent "implementation-complete question"
  pass "is the implementation complete? does not inject principle-prove-it-works"
}

test_pr_ready_for_review_sentence_is_not_completion() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"The PR is ready for review"}' \
    --claude
  expect_silent "PR ready sentence"
  pass "The PR is ready for review does not inject principle-prove-it-works"
}

test_blocked_line_is_not_a_completion() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"blocked: wait for my review"}' \
    --claude
  expect_silent "blocked: is not a completion"
  pass "blocked: wait for my review does not inject principle-prove-it-works"
}

test_needs_decision_line_is_not_a_completion() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"needs-decision: pick a design"}' \
    --claude
  expect_silent "needs-decision: is not a completion"
  pass "needs-decision: pick a design does not inject principle-prove-it-works"
}

test_write_of_test_file_injects_test_behavior() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"tests/fm-export.test.sh","content":"pass x\n"}}' \
    --claude
  expect_claude_inject "principle-test-behavior-not-implementation" "PreToolUse" "Write of a test file"
  pass "writing a test file injects principle-test-behavior-not-implementation"
}

test_cwd_relative_test_file_write_injects() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"foo.test.sh","content":"pass x\n"}}' \
    --claude
  expect_claude_inject "principle-test-behavior-not-implementation" "PreToolUse" "cwd-relative foo.test.sh"
  pass "a cwd-relative foo.test.sh Write injects principle-test-behavior-not-implementation"
}

test_cursor_post_tool_write_of_test_file_injects() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"postToolUse","tool_name":"Write","tool_input":{"path":"tests/fm-export.test.sh","contents":"pass x\n"},"tool_output":"{\"exitCode\":0}","cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  expect_cursor_inject "principle-test-behavior-not-implementation" "Cursor postToolUse Write of a test file"
  pass "Cursor postToolUse writing a test file injects principle-test-behavior-not-implementation"
}

test_shell_redirect_to_test_file_injects() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat > tests/fm-export.test.sh <<EOF\npass x\nEOF"}}' \
    --claude
  expect_claude_inject "principle-test-behavior-not-implementation" "PreToolUse" "heredoc into a test path"
  pass "a Shell heredoc into a test path injects principle-test-behavior-not-implementation"
}

test_cwd_relative_shell_redirect_injects() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat > foo.test.sh <<EOF\npass x\nEOF"}}' \
    --claude
  expect_claude_inject "principle-test-behavior-not-implementation" "PreToolUse" "cwd-relative cat > foo.test.sh"
  pass "a cwd-relative cat > foo.test.sh injects principle-test-behavior-not-implementation"
}

test_tee_with_flags_into_test_path_injects() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo pass | tee -a tests/fm-export.test.sh"}}' \
    --claude
  expect_claude_inject "principle-test-behavior-not-implementation" "PreToolUse" "tee -a into a test path"
  pass "tee -a tests/... injects principle-test-behavior-not-implementation"
}

test_cp_into_test_path_injects() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cp scratch.sh tests/fm-export.test.sh"}}' \
    --claude
  expect_claude_inject "principle-test-behavior-not-implementation" "PreToolUse" "cp into a test path"
  pass "cp into tests/... injects principle-test-behavior-not-implementation"
}

test_redirect_elsewhere_then_grep_test_path_is_silent() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git diff HEAD > /tmp/out && grep x tests/fm-pstack-verify-hook.test.sh"}}' \
    --claude
  expect_silent "redirect to /tmp then grep a test path"
  pass "git diff redirected to /tmp then grep of a test path does not inject"
}

test_redirect_elsewhere_then_cat_test_path_is_silent() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo x > /tmp/out && cat tests/export.test.sh"}}' \
    --claude
  expect_silent "redirect to /tmp then cat a test path"
  pass "echo redirected to /tmp then cat of a test path does not inject"
}

test_quoted_gt_in_echo_is_not_a_test_write() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo '\''a > tests/foo.test.sh'\''"}}' \
    --claude
  expect_silent "quoted greater-than in echo"
  pass "echo of a quoted > tests/foo.test.sh does not inject"
}

test_here_string_gt_follows_quote_blanking() {
  run_hook "$PRIMARY" \
    "$(jq -n --arg c 'cat <<< "echo x > tests/foo.test.sh"' '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}')" \
    --claude
  expect_silent "quoted greater-than inside a here-string"
  run_hook "$PRIMARY" \
    "$(jq -n --arg c 'cat <<< foo > tests/foo.test.sh' '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}')" \
    --claude
  expect_claude_inject "principle-test-behavior-not-implementation" "PreToolUse" \
    "here-string then a command-line redirect to a test path"
  pass "a quoted > in a here-string is silent; a redirect after <<< still injects"
}

test_interpreter_fed_quoted_heredoc_body_injects() {
  local cmd
  cmd=$(printf "bash <<'EOF'\necho hi > tests/foo.test.sh\nEOF")
  run_hook "$PRIMARY" \
    "$(jq -n --arg c "$cmd" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}')" \
    --claude
  expect_claude_inject "principle-test-behavior-not-implementation" "PreToolUse" \
    "bash <<'EOF' body test write"
  pass "bash <<'EOF' with a body test-file write injects"
}

test_quoted_heredoc_body_gt_is_accepted_false_positive() {
  local cmd
  cmd=$(printf "cat > /tmp/setup.sh <<'EOF'\necho x > tests/foo.test.sh\nEOF")
  run_hook "$PRIMARY" \
    "$(jq -n --arg c "$cmd" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}')" \
    --claude
  expect_claude_inject "principle-test-behavior-not-implementation" "PreToolUse" \
    "quoted heredoc body greater-than is an accepted false positive"
  pass "cat > /tmp/setup.sh <<'EOF' with a body > tests/foo.test.sh injects"
}

test_backup_test_path_is_silent() {
  local path
  for path in foo.test.sh.bak foo.test.sh.orig foo.test.sh.swp tests/foo.test.sh.bak; do
    run_hook "$PRIMARY" \
      "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":$(printf '%s' "$path" | jq -Rs .),\"content\":\"pass x\n\"}}" \
      --claude
    expect_silent "Write of $path"
  done
  run_hook "$PRIMARY" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat > foo.test.sh.bak <<EOF\npass x\nEOF"}}' \
    --claude
  expect_silent "Shell redirect to foo.test.sh.bak"
  run_hook "$PRIMARY" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"foo.test.sh","content":"pass x\n"}}' \
    --claude
  expect_claude_inject "principle-test-behavior-not-implementation" "PreToolUse" \
    "foo.test.sh still injects after backup paths stay silent"
  pass "backup suffixes on test paths do not inject principle-test-behavior-not-implementation"
}

test_its_faster_injects_explain_the_number() {
  run_hook "$PRIMARY" \
    "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"it's faster\"}" \
    --claude
  expect_claude_inject "principle-explain-the-number" "UserPromptSubmit" "literal it's faster"
  pass "it's faster injects principle-explain-the-number"
}

test_claude_write_of_test_file_emits_once_across_pre_and_post() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"tests/foo.test.sh","content":"pass x\n"}}' \
    --claude
  expect_claude_inject "principle-test-behavior-not-implementation" "PreToolUse" "first event of one Write"
  run_hook "$PRIMARY" \
    '{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"tests/foo.test.sh","content":"pass x\n"},"tool_response":{"stdout":""}}' \
    --claude
  expect_silent "PostToolUse of the same Write must not inject again"
  pass "one Claude Write of a test file injects on PreToolUse only"
}

test_blocked_status_append_is_not_completion() {
  local blocked
  blocked='echo "blocked: wait for review" >> /tmp/task.status && true'
  run_hook "$PRIMARY" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$blocked" | jq -Rs .)}}" \
    --claude
  expect_silent "blocked: STATUS_APPEND Bash"
  run_hook "$PRIMARY" \
    "{\"hook_event_name\":\"postToolUse\",\"tool_name\":\"Shell\",\"tool_input\":{\"command\":$(printf '%s' "$blocked" | jq -Rs .)},\"tool_output\":\"{\\\"exitCode\\\":0}\",\"cursor_version\":\"x\",\"conversation_id\":\"c1\",\"generation_id\":\"g\"}" \
    --cursor
  expect_silent "blocked: STATUS_APPEND Shell"
  pass "blocked: via STATUS_APPEND Shell/Bash does not inject principle-prove-it-works"
}

test_blocked_status_write_is_not_completion() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"state/t.status","content":"blocked: wait for review\n"}}' \
    --claude
  expect_silent "blocked: Write of a status file"
  pass "blocked: via a *.status Write does not inject principle-prove-it-works"
}

test_contest_path_is_not_a_test_write() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat > contest/helper.sh <<EOF\npass x\nEOF"}}' \
    --claude
  expect_silent "contest/ is not a test path segment"
  pass "a Shell redirect into contest/ does not inject principle-test-behavior-not-implementation"
}

test_write_of_docs_testing_notes_is_not_a_test_change() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"path":"docs/testing.md","contents":"# notes\n"}}' \
    --claude
  expect_silent "docs/testing.md is not a test file"
  pass "writing docs/testing.md does not inject principle-test-behavior-not-implementation"
}

test_docs_test_plan_is_not_a_test_file() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"path":"docs/test_plan.md","contents":"plan\n"}}' \
    --claude
  expect_silent "docs/test_plan.md"
  pass "docs/test_plan.md does not inject principle-test-behavior-not-implementation"
}

test_speed_claim_injects_explain_the_number() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"the export is faster now"}' \
    --claude
  expect_claude_inject "principle-explain-the-number" "UserPromptSubmit" "an is-faster claim"
  printf '%s' "$RUN_OUT" | grep -Fq 'benchmark-checklist' \
    && fail "injected text must not name unvendored benchmark-checklist"
  pass "a speed claim injects principle-explain-the-number"
}

test_trailing_question_on_speed_claim_still_injects() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"the export is 2x as fast?"}' \
    --claude
  expect_claude_inject "principle-explain-the-number" "UserPromptSubmit" "2x as fast with trailing ?"
  pass "the export is 2x as fast? injects principle-explain-the-number"
}

test_cursor_speed_claim_is_pending_then_delivered() {
  local home
  home="$TMP_ROOT/pending-speed"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"afterAgentResponse","text":"the export is faster now","cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  expect_silent "afterAgentResponse must print nothing"
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Read","tool_input":{"path":"src/export.c"},"tool_output":"{\"exitCode\":0}","cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  expect_cursor_inject "principle-explain-the-number" "pending speed claim delivered on postToolUse"
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Read","tool_input":{"path":"src/export.c"},"tool_output":"{\"exitCode\":0}","cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  expect_silent "pending marker must be cleared after one delivery"
  pass "a Cursor afterAgentResponse speed claim is delivered once on the next postToolUse"
}

test_cursor_before_submit_speed_prints_continue_only() {
  local home
  home="$TMP_ROOT/pending-prompt"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"beforeSubmitPrompt","prompt":"the export is faster now","cursor_version":"x","conversation_id":"c2","generation_id":"g"}' \
    --cursor
  expect_cursor_continue_only "beforeSubmitPrompt speed claim"
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Read","tool_input":{"path":"src/export.c"},"cursor_version":"x","conversation_id":"c2","generation_id":"g"}' \
    --cursor
  expect_cursor_inject "principle-explain-the-number" "pending prompt speed claim"
  pass "Cursor beforeSubmitPrompt prints continue:true and delivers the claim on postToolUse"
}

test_two_x_as_fast_injects_explain_the_number() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"export is 2x as fast on the 60k-row set"}' \
    --claude
  expect_claude_inject "principle-explain-the-number" "UserPromptSubmit" "2x as fast"
  pass "2x as fast injects principle-explain-the-number"
}

test_much_faster_injects_explain_the_number() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"the parse path is much faster"}' \
    --claude
  expect_claude_inject "principle-explain-the-number" "UserPromptSubmit" "much faster"
  pass "much faster injects principle-explain-the-number"
}

test_got_a_lot_faster_injects_explain_the_number() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"the parse path got a lot faster"}' \
    --claude
  expect_claude_inject "principle-explain-the-number" "UserPromptSubmit" "got a lot faster"
  pass "got a lot faster injects principle-explain-the-number"
}

test_please_speed_up_ci_is_not_a_speed_claim() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"please speed up the CI"}' \
    --claude
  expect_silent "please speed up the CI"
  pass "please speed up the CI does not inject principle-explain-the-number"
}

test_which_is_faster_is_not_a_speed_claim() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"which is faster, A or B?"}' \
    --claude
  expect_silent "which is faster question"
  pass "which is faster, A or B? does not inject principle-explain-the-number"
}

test_as_fast_as_is_not_a_speed_claim() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"this is sometimes as fast as the old path"}' \
    --claude
  expect_silent "as fast as is not a speedup"
  pass "this is sometimes as fast as the old path does not inject principle-explain-the-number"
}

test_speedup_noun_is_not_a_speed_claim() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"look at the CI speedup"}' \
    --claude
  expect_silent "speedup noun mention"
  pass "look at the CI speedup does not inject principle-explain-the-number"
}

test_cursor_before_submit_miss_still_continues() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"beforeSubmitPrompt","prompt":"please speed up the CI","cursor_version":"x","generation_id":"g"}' \
    --cursor
  expect_cursor_continue_only "beforeSubmitPrompt miss"
  pass "a Cursor beforeSubmitPrompt miss emits continue:true without a principle"
}

test_fast_forward_is_not_a_speed_claim() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"fast-forward the merge onto main"}' \
    --claude
  expect_silent "fast-forward is not a speed claim"
  pass "fast-forward does not inject principle-explain-the-number"
}

test_faster_path_is_not_a_speed_claim() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"use the faster path without stacked review"}' \
    --claude
  expect_silent "faster path is firstmate delivery language"
  pass "faster path does not inject principle-explain-the-number"
}

test_fast_forward_does_not_hide_a_real_speed_claim() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"fast-forward onto main; the export is 2x as fast"}' \
    --claude
  expect_claude_inject "principle-explain-the-number" "UserPromptSubmit" "speed claim beside fast-forward"
  pass "fast-forward does not suppress a later 2x as fast claim"
}

test_same_red_twice_after_claimed_fix_injects_attack_the_premise() {
  local home
  home="$TMP_ROOT/reds"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"true"},"tool_response":{"stdout":"fixed tests/export.test.sh\n"},"session_id":"s1"}' \
    --claude
  expect_silent "a claimed fix alone is not a recurring red"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - tests/export.test.sh does the thing\n"},"tool_use_id":"r1","session_id":"s1"}' \
    --claude
  expect_silent "the first TAP red after a claimed fix is not yet recurring"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - tests/export.test.sh does the thing\n"},"tool_use_id":"r2","session_id":"s1"}' \
    --claude
  expect_claude_inject "principle-attack-the-premise" "PostToolUse" "the same TAP red twice after a claimed fix"
  pass "the same TAP red twice after a claimed fix injects principle-attack-the-premise"
}

test_claim_plus_two_after_shell_same_generation() {
  local home
  home="$TMP_ROOT/reds-cursor-tap"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"afterAgentResponse","text":"fixed tests/export.test.sh","cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  expect_silent "claim alone"
  run_hook "$home" \
    '{"hook_event_name":"afterShellExecution","command":"bash tests/export.test.sh","output":"not ok - tests/export.test.sh does the thing\n","duration":1100,"cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  expect_silent "first afterShellExecution rerun"
  run_hook "$home" \
    '{"hook_event_name":"afterShellExecution","command":"bash tests/export.test.sh","output":"not ok - tests/export.test.sh does the thing\n","duration":1100,"cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  expect_silent "equal-duration afterShellExecution rerun is pending, no stdout"
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Read","tool_input":{"path":"src/export.c"},"tool_output":"{\"exitCode\":0}","cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  expect_cursor_inject "principle-attack-the-premise" "pending TAP red delivered on postToolUse"
  pass "two afterShellExecution reruns with equal integer ms duration reach streak 2"
}

test_after_shell_then_failure_stays_at_streak_one() {
  local home
  home="$TMP_ROOT/reds-shell-then-fail"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"afterAgentResponse","text":"fixed tests/export.test.sh","cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  run_hook "$home" \
    '{"hook_event_name":"afterShellExecution","command":"bash tests/export.test.sh","output":"not ok - tests/export.test.sh does the thing\n","duration":1.1,"cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  expect_silent "afterShellExecution first red"
  run_hook "$home" \
    '{"hook_event_name":"postToolUseFailure","tool_name":"Shell","command":"bash tests/export.test.sh","error_message":"Command failed","failure_type":"error","cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  expect_silent "postToolUseFailure must not count a second red"
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Read","tool_input":{"path":"src/export.c"},"cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  expect_silent "streak 1 must not deliver attack-the-premise"
  pass "afterShellExecution then postToolUseFailure of one physical command stays at streak 1"
}

test_failure_then_after_shell_stays_at_streak_one() {
  local home
  home="$TMP_ROOT/reds-fail-then-shell"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"afterAgentResponse","text":"fixed tests/export.test.sh","cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  run_hook "$home" \
    '{"hook_event_name":"postToolUseFailure","tool_name":"Shell","command":"bash tests/export.test.sh","error_message":"not ok - tests/export.test.sh does the thing\n","failure_type":"error","cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  expect_silent "postToolUseFailure does not count Cursor reds"
  run_hook "$home" \
    '{"hook_event_name":"afterShellExecution","command":"bash tests/export.test.sh","output":"not ok - tests/export.test.sh does the thing\n","duration":1.1,"cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  expect_silent "one afterShellExecution is streak 1"
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Read","tool_input":{"path":"src/export.c"},"cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  expect_silent "failure then afterShellExecution stays at streak 1"
  pass "postToolUseFailure then afterShellExecution of one physical command stays at streak 1"
}

test_claude_post_tool_use_failure_error_injects() {
  local home
  home="$TMP_ROOT/reds-claude-failure"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"fixed tests/export.test.sh\n"},"session_id":"s1"}' \
    --claude
  expect_silent "claim alone"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","error":"not ok - tests/export.test.sh does the thing\n","tool_use_id":"r1","session_id":"s1"}' \
    --claude
  expect_silent "first PostToolUseFailure .error TAP"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","error":"not ok - tests/export.test.sh does the thing\n","tool_use_id":"r2","session_id":"s1"}' \
    --claude
  expect_claude_inject "principle-attack-the-premise" "PostToolUseFailure" "Claude PostToolUseFailure .error TAP"
  pass "a Claude PostToolUseFailure with TAP in .error, twice after a claim, injects"
}

test_cursor_post_tool_use_success_does_not_count_tap() {
  local home
  home="$TMP_ROOT/reds-success-tap"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"afterAgentResponse","text":"fixed tests/export.test.sh","cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Shell","tool_input":{"command":"bash tests/export.test.sh"},"tool_output":"{\"exitCode\":0,\"stdout\":\"\",\"stderr\":\"not ok - tests/export.test.sh does the thing\\n\"}","cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  expect_silent "successful postToolUse must not count TAP"
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Shell","tool_input":{"command":"bash tests/export.test.sh"},"tool_output":"{\"exitCode\":0,\"stdout\":\"\",\"stderr\":\"not ok - tests/export.test.sh does the thing\\n\"}","cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  expect_silent "a second successful postToolUse still must not count TAP"
  pass "Cursor postToolUse is a successful tool use and does not count TAP as a red"
}

test_fail_style_stderr_on_claude_post_tool_use() {
  local home
  home="$TMP_ROOT/reds-stderr"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"bash tests/export.test.sh"},"tool_response":{"stdout":"1..1\n","stderr":"not ok - tests/export.test.sh does the thing\n"},"tool_use_id":"c1","session_id":"s1"}' \
    --claude
  expect_silent "first stderr TAP red with no prior claim should not inject attack"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"fixed tests/export.test.sh\n"},"session_id":"s1"}' \
    --claude
  expect_silent "claim after first red is not yet a streak of two"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"","stderr":"not ok - tests/export.test.sh does the thing\n"},"tool_use_id":"r1","session_id":"s1"}' \
    --claude
  expect_silent "first red after the claim"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"","stderr":"not ok - tests/export.test.sh does the thing\n"},"tool_use_id":"r2","session_id":"s1"}' \
    --claude
  expect_claude_inject "principle-attack-the-premise" "PostToolUse" "fail()-style stderr TAP"
  pass "fail()-style not ok - stderr injects principle-attack-the-premise on the second red"
}

test_tap_description_is_not_keyed_as_a() {
  local home
  home="$TMP_ROOT/reds-tap-a"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"fixed tests/export.test.sh\n"},"session_id":"s1"}' \
    --claude
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - a done: completion report injects principle-prove-it-works\n"},"tool_use_id":"t1","session_id":"s1"}' \
    --claude
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - a working: line does not inject\n"},"tool_use_id":"t2","session_id":"s1"}' \
    --claude
  expect_silent "two different TAP descriptions must not share id a"
  pass "a TAP line not ok - a done: does not key the id as a"
}

test_pytest_node_id_matches_file_claim() {
  local home
  home="$TMP_ROOT/reds-pytest"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"fixed tests/test_export.py\n"},"session_id":"s1"}' \
    --claude
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"FAILED tests/test_export.py::test_it\n"},"tool_use_id":"p1","session_id":"s1"}' \
    --claude
  expect_silent "first pytest node red"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"FAILED tests/test_export.py::test_it\n"},"tool_use_id":"p2","session_id":"s1"}' \
    --claude
  expect_claude_inject "principle-attack-the-premise" "PostToolUse" "pytest node id vs file claim"
  pass "a pytest node id tests/test_export.py::test_it matches a file claim"
}

test_jest_fail_line_is_extracted() {
  local home
  home="$TMP_ROOT/reds-jest"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"fixed src/foo.test.ts\n"},"session_id":"s1"}' \
    --claude
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"FAIL src/foo.test.ts\n"},"tool_use_id":"j1","session_id":"s1"}' \
    --claude
  expect_silent "first Jest FAIL red"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"FAIL src/foo.test.ts\n"},"tool_use_id":"j2","session_id":"s1"}' \
    --claude
  expect_claude_inject "principle-attack-the-premise" "PostToolUse" "Jest FAIL line"
  pass "Jest FAIL src/foo.test.ts injects principle-attack-the-premise on the second red"
}

test_glob_in_tap_line_does_not_expand() {
  local home
  home="$TMP_ROOT/reds-glob"
  mkdir -p "$home/state" "$home/work/tests"
  printf 'x\n' > "$home/work/tests/assets"
  printf 'x\n' > "$home/work/tests/export.test.sh"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"fixed tests/assets\n"},"session_id":"s1"}' \
    --claude
  (
    cd "$home/work" || exit 1
    RUN_STATUS=0
    RUN_OUT=$(printf '%s' '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - tests/*\n"},"tool_use_id":"g1","session_id":"s1"}' \
      | env -u FM_HOME FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
        bash "$HOOK" --claude) || RUN_STATUS=$?
    expect_code 0 "$RUN_STATUS" "glob red 1"
    [ -z "$RUN_OUT" ] || fail "glob red 1 injected: $RUN_OUT"
    RUN_OUT=$(printf '%s' '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - tests/*\n"},"tool_use_id":"g2","session_id":"s1"}' \
      | env -u FM_HOME FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
        bash "$HOOK" --claude) || RUN_STATUS=$?
    expect_code 0 "$RUN_STATUS" "glob red 2"
    [ -z "$RUN_OUT" ] || fail "a glob TAP line must not expand into tests/assets, got: $RUN_OUT"
  )
  pass "a TAP line not ok - tests/* does not glob-expand"
}

test_same_red_payload_is_idempotent() {
  local home
  home="$TMP_ROOT/reds-idem"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"fixed tests/export.test.sh\n"},"prompt_id":"c1","session_id":"s1"}' \
    --claude
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - tests/export.test.sh\n"},"tool_use_id":"r1","session_id":"s1"}' \
    --claude
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - tests/export.test.sh\n"},"tool_use_id":"r1","session_id":"s1"}' \
    --claude
  expect_silent "the same tool_use_id must not count as a second red"
  pass "a repeated red payload with the same token does not inject"
}

test_two_reds_without_a_claimed_fix_do_not_inject() {
  local home
  home="$TMP_ROOT/reds-noclaim"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - tests/export.test.sh\n"},"tool_use_id":"a","session_id":"s1"}' \
    --claude
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - tests/export.test.sh\n"},"tool_use_id":"b","session_id":"s1"}' \
    --claude
  expect_silent "two reds with no claimed fix"
  pass "the same red twice with no claimed fix does not inject"
}

test_different_check_ids_do_not_share_a_streak() {
  local home
  home="$TMP_ROOT/reds-other"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"fixed tests/export.test.sh\n"},"session_id":"s1"}' \
    --claude
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - tests/export.test.sh\n"},"tool_use_id":"r1","session_id":"s1"}' \
    --claude
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - tests/other.test.sh\n"},"tool_use_id":"r2","session_id":"s1"}' \
    --claude
  expect_silent "a different check id is not the same red"
  pass "a different check id does not inject principle-attack-the-premise"
}

test_stale_lock_is_broken() {
  local home now
  home="$TMP_ROOT/reds-stale-lock"
  mkdir -p "$home/state"
  mkdir "$home/state/pstack-verify-reds.tsv.lock"
  now=$(date +%s)
  python3 -c 'import os, sys; t = int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' \
    "$home/state/pstack-verify-reds.tsv.lock" "$((now - 60))"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"fixed tests/export.test.sh\n"},"session_id":"s1"}' \
    --claude
  expect_silent "claim through a stale lock"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - tests/export.test.sh\n"},"tool_use_id":"r1","session_id":"s1"}' \
    --claude
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - tests/export.test.sh\n"},"tool_use_id":"r2","session_id":"s1"}' \
    --claude
  expect_claude_inject "principle-attack-the-premise" "PostToolUse" "stale lock must not disable recurring-red"
  pass "a stale mkdir lock is broken so recurring-red still fires"
}

test_pending_without_conversation_id_is_not_stored() {
  local home
  home="$TMP_ROOT/pending-noconv"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"afterAgentResponse","text":"the export is faster now","cursor_version":"x","generation_id":"g"}' \
    --cursor
  expect_silent "speed claim with no conversation_id"
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Read","tool_input":{"path":"src/export.c"},"cursor_version":"x","conversation_id":"other","generation_id":"g"}' \
    --cursor
  expect_silent "no conversation_id must not leak pending to another conversation"
  pass "a pending marker is not stored without conversation_id"
}

test_pending_does_not_cross_conversations() {
  local home
  home="$TMP_ROOT/pending-cross"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"afterAgentResponse","text":"the export is faster now","cursor_version":"x","conversation_id":"a","generation_id":"g"}' \
    --cursor
  expect_silent "claim on conversation a"
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Read","tool_input":{"path":"src/export.c"},"cursor_version":"x","conversation_id":"b","generation_id":"g"}' \
    --cursor
  expect_silent "conversation b must not receive a's pending"
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Read","tool_input":{"path":"src/export.c"},"cursor_version":"x","conversation_id":"a","generation_id":"g"}' \
    --cursor
  expect_cursor_inject "principle-explain-the-number" "conversation a still delivers its own pending"
  pass "pending markers are keyed per conversation_id"
}

test_reds_do_not_cross_conversations() {
  local home
  home="$TMP_ROOT/reds-cross"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"afterAgentResponse","text":"fixed tests/export.test.sh","cursor_version":"x","conversation_id":"a","generation_id":"g"}' \
    --cursor
  run_hook "$home" \
    '{"hook_event_name":"afterShellExecution","command":"bash tests/export.test.sh","output":"not ok - tests/export.test.sh\n","duration":1.1,"cursor_version":"x","conversation_id":"b","generation_id":"g"}' \
    --cursor
  run_hook "$home" \
    '{"hook_event_name":"afterShellExecution","command":"bash tests/export.test.sh","output":"not ok - tests/export.test.sh\n","duration":1.4,"cursor_version":"x","conversation_id":"b","generation_id":"g"}' \
    --cursor
  expect_silent "conversation B reds must not use conversation A's claim"
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Read","tool_input":{"path":"src/export.c"},"cursor_version":"x","conversation_id":"b","generation_id":"g"}' \
    --cursor
  expect_silent "no pending attack on conversation B"
  pass "reds TSV is keyed by conversation_id plus test id"
}

test_reds_without_conversation_id_are_not_recorded() {
  local home
  home="$TMP_ROOT/reds-noconv"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"afterAgentResponse","text":"fixed tests/export.test.sh","cursor_version":"x","generation_id":"g"}' \
    --cursor
  run_hook "$home" \
    '{"hook_event_name":"afterShellExecution","command":"bash tests/export.test.sh","output":"not ok - tests/export.test.sh\n","duration":1.1,"cursor_version":"x","generation_id":"g"}' \
    --cursor
  run_hook "$home" \
    '{"hook_event_name":"afterShellExecution","command":"bash tests/export.test.sh","output":"not ok - tests/export.test.sh\n","duration":1.4,"cursor_version":"x","generation_id":"g"}' \
    --cursor
  expect_silent "reds with no conversation_id"
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Read","tool_input":{"path":"src/export.c"},"cursor_version":"x","conversation_id":"later","generation_id":"g"}' \
    --cursor
  expect_silent "unkeyed reds must not later inject"
  pass "reds without conversation_id are not recorded"
}

test_lock_aged_five_seconds_breaks_once_stale() {
  local home now
  home="$TMP_ROOT/reds-aging-lock"
  mkdir -p "$home/state"
  mkdir "$home/state/pstack-verify-reds.tsv.lock"
  now=$(date +%s)
  python3 -c 'import os, sys; t = int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' \
    "$home/state/pstack-verify-reds.tsv.lock" "$((now - 2))"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"fixed tests/export.test.sh\n"},"session_id":"s1"}' \
    --claude
  expect_silent "claim through a lock that ages past stale"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - tests/export.test.sh\n"},"tool_use_id":"r1","session_id":"s1"}' \
    --claude
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - tests/export.test.sh\n"},"tool_use_id":"r2","session_id":"s1"}' \
    --claude
  expect_claude_inject "principle-attack-the-premise" "PostToolUse" "aging lock must still record the claim"
  pass "a lock aged about 2s is broken once it goes stale"
}

test_missing_jq_before_submit_still_continues() {
  local fake status out
  fake="$TMP_ROOT/nojq-continue"
  mkdir -p "$fake"
  printf '#!/bin/sh\nexit 127\n' > "$fake/jq"
  chmod +x "$fake/jq"
  status=0
  out=$(printf '%s' '{"hook_event_name":"beforeSubmitPrompt","prompt":"hi","cursor_version":"x","generation_id":"g"}' \
    | env -u FM_HOME PATH="$fake:$PATH" \
      FM_ROOT_OVERRIDE="$PRIMARY" FM_STATE_OVERRIDE="$PRIMARY/state" \
      bash "$HOOK" --cursor) || status=$?
  expect_code 0 "$status" "missing jq beforeSubmitPrompt must exit 0"
  [ "$out" = '{"continue":true}' ] \
    || fail "missing jq beforeSubmitPrompt must print continue, got: $out"
  pass "missing jq still prints {\"continue\":true} on beforeSubmitPrompt"
}

test_claude_mode_stands_down_on_cursor_before_submit() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"beforeSubmitPrompt","prompt":"the export is faster now","cursor_version":"x","generation_id":"g"}' \
    --claude
  expect_cursor_continue_only "Claude stand-down on Cursor beforeSubmitPrompt"
  pass "--claude on a Cursor beforeSubmitPrompt still prints continue:true"
}

test_claude_mode_stands_down_on_cursor_post_tool_use() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"postToolUse","tool_name":"Write","tool_input":{"path":"tests/fm-export.test.sh","contents":"x"},"cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --claude
  expect_silent "Claude registration must stand down on a Cursor postToolUse payload"
  pass "--claude is silent on a Cursor-delivered postToolUse payload"
}

test_claude_mode_is_silent_on_cursor_pre_tool_use() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{"command":"true"},"cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --claude
  expect_silent "Claude registration must not emit permission on Cursor preToolUse"
  pass "--claude is silent on a Cursor-delivered preToolUse payload"
}

test_empty_stdin_fails_open() {
  run_hook "$PRIMARY" '' --cursor
  expect_silent "empty stdin --cursor"
  run_hook "$PRIMARY" '' --claude
  expect_silent "empty stdin --claude"
  pass "empty stdin fails open with no output"
}

test_malformed_payload_fails_open() {
  run_hook "$PRIMARY" '{not-json' --cursor
  expect_silent "malformed JSON must not inject"
  pass "malformed JSON fails open"
}

test_missing_jq_fails_open() {
  local fake status out
  fake="$TMP_ROOT/nojq"
  mkdir -p "$fake"
  printf '#!/bin/sh\nexit 127\n' > "$fake/jq"
  chmod +x "$fake/jq"
  status=0
  out=$(printf '%s' '{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"path":"tests/fm-export.test.sh"}}' \
    | env -u FM_HOME PATH="$fake:$PATH" \
      FM_ROOT_OVERRIDE="$PRIMARY" FM_STATE_OVERRIDE="$PRIMARY/state" \
      bash "$HOOK" --claude) || status=$?
  expect_code 0 "$status" "missing jq must not fail the turn"
  [ -z "$out" ] || fail "missing jq must not inject, got: $out"
  pass "missing jq fails open without skipping the suite"
}

test_after_shell_status_append_is_consumed_by_post_tool_use() {
  local home
  home="$TMP_ROOT/pending-status-consume"
  mkdir -p "$home/state"
  run_hook "$home" \
    "{\"hook_event_name\":\"afterShellExecution\",\"command\":$(printf '%s' "$STATUS_APPEND" | jq -Rs .),\"output\":\"\",\"duration\":1100,\"cursor_version\":\"x\",\"conversation_id\":\"c1\",\"generation_id\":\"g\"}" \
    --cursor
  expect_silent "afterShellExecution STATUS_APPEND does not emit or defer"
  run_hook "$home" \
    "{\"hook_event_name\":\"postToolUse\",\"tool_name\":\"Shell\",\"tool_input\":{\"command\":$(printf '%s' "$STATUS_APPEND" | jq -Rs .)},\"tool_output\":\"{\\\"exitCode\\\":0}\",\"cursor_version\":\"x\",\"conversation_id\":\"c1\",\"generation_id\":\"g\"}" \
    --cursor
  expect_cursor_inject "principle-prove-it-works" "postToolUse emits the same STATUS_APPEND"
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Read","tool_input":{"path":"src/export.c"},"tool_output":"{\"exitCode\":0}","cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  expect_silent "STATUS_APPEND must not inject again on a later Read"
  pass "afterShellExecution then postToolUse of STATUS_APPEND injects once"
}

test_post_tool_then_after_shell_status_append_injects_once() {
  local home
  home="$TMP_ROOT/pending-status-reverse"
  mkdir -p "$home/state"
  run_hook "$home" \
    "{\"hook_event_name\":\"postToolUse\",\"tool_name\":\"Shell\",\"tool_input\":{\"command\":$(printf '%s' "$STATUS_APPEND" | jq -Rs .)},\"tool_output\":\"{\\\"exitCode\\\":0}\",\"cursor_version\":\"x\",\"conversation_id\":\"c1\",\"generation_id\":\"g\"}" \
    --cursor
  expect_cursor_inject "principle-prove-it-works" "postToolUse STATUS_APPEND first"
  run_hook "$home" \
    "{\"hook_event_name\":\"afterShellExecution\",\"command\":$(printf '%s' "$STATUS_APPEND" | jq -Rs .),\"output\":\"\",\"duration\":1100,\"cursor_version\":\"x\",\"conversation_id\":\"c1\",\"generation_id\":\"g\"}" \
    --cursor
  expect_silent "afterShellExecution STATUS_APPEND after postToolUse"
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Read","tool_input":{"path":"src/export.c"},"tool_output":"{\"exitCode\":0}","cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  expect_silent "reverse-order STATUS_APPEND must not inject again on a later Read"
  pass "postToolUse then afterShellExecution of STATUS_APPEND injects once"
}

test_parallel_post_tool_use_takes_pending_once() {
  local home payload p1 p2 pid1 pid2 s1=0 s2=0 hits=0 f
  home="$TMP_ROOT/pending-parallel"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"afterAgentResponse","text":"the export is faster now","cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  expect_silent "speed claim deferred before parallel take"
  payload='{"hook_event_name":"postToolUse","tool_name":"Read","tool_input":{"path":"src/export.c"},"tool_output":"{\"exitCode\":0}","cursor_version":"x","conversation_id":"c1","generation_id":"g"}'
  p1="$home/p1.out"
  p2="$home/p2.out"
  printf '%s' "$payload" | env -u FM_HOME \
    FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    bash "$HOOK" --cursor >"$p1" &
  pid1=$!
  printf '%s' "$payload" | env -u FM_HOME \
    FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    bash "$HOOK" --cursor >"$p2" &
  pid2=$!
  wait "$pid1" || s1=$?
  wait "$pid2" || s2=$?
  expect_code 0 "$s1" "first parallel postToolUse must exit 0"
  expect_code 0 "$s2" "second parallel postToolUse must exit 0"
  for f in "$p1" "$p2"; do
    if [ -s "$f" ] && jq -e --arg p "principle-explain-the-number" '
        (keys | sort) == ["additional_context"]
        and (.additional_context|contains($p))
      ' "$f" >/dev/null 2>&1; then
      hits=$((hits + 1))
    fi
  done
  [ "$hits" -eq 1 ] || fail "parallel postToolUse must deliver pending once, got $hits"
  pass "parallel postToolUse takes a pending principle once"
}

test_prefixed_is_not_a_claimed_fix() {
  local home
  home="$TMP_ROOT/reds-prefixed"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"true"},"tool_response":{"stdout":"prefixed tests/export.test.sh\n"},"session_id":"s1"}' \
    --claude
  expect_silent "prefixed is not a claimed fix"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - tests/export.test.sh\n"},"tool_use_id":"r1","session_id":"s1"}' \
    --claude
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - tests/export.test.sh\n"},"tool_use_id":"r2","session_id":"s1"}' \
    --claude
  expect_silent "two TAP reds after prefixed must not inject attack-the-premise"
  pass "prefixed tests/export.test.sh is not a claimed fix"
}

test_nested_cursor_version_stays_on_claude_path() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"the export is faster now","tool_input":{"cursor_version":"nested"}}' \
    --claude
  expect_claude_inject "principle-explain-the-number" "UserPromptSubmit" "nested cursor_version must not flip host"
  pass "a nested cursor_version key stays on the Claude emit path"
}

test_command_comment_tap_is_not_a_claude_red() {
  local home
  home="$TMP_ROOT/reds-comment"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"fixed tests/export.test.sh\n"},"session_id":"s1"}' \
    --claude
  expect_silent "claimed fix before command-comment TAP"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo ok # not ok - tests/export.test.sh"},"tool_response":{"stdout":"ok\n"},"tool_use_id":"c1","session_id":"s1"}' \
    --claude
  expect_silent "first command-comment TAP is not a red"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo ok # not ok - tests/export.test.sh"},"tool_response":{"stdout":"ok\n"},"tool_use_id":"c2","session_id":"s1"}' \
    --claude
  expect_silent "a TAP line in the command string must not count as a red"
  pass "Claude red counting ignores a not ok comment in the command"
}

test_got_faster_to_write_is_not_a_speed_claim() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"tests got faster to write"}' \
    --claude
  expect_silent "got faster to write"
  pass "tests got faster to write does not inject principle-explain-the-number"
}

test_dotdot_conversation_id_is_not_stored() {
  local home
  home="$TMP_ROOT/pending-dotdot"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"afterAgentResponse","text":"the export is faster now","cursor_version":"x","conversation_id":"..","generation_id":"g"}' \
    --cursor
  expect_silent "speed claim with conversation_id .."
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Read","tool_input":{"path":"src/export.c"},"cursor_version":"x","conversation_id":"..","generation_id":"g"}' \
    --cursor
  expect_silent "conversation_id .. must not store or deliver pending"
  pass "conversation_id .. is not a pending filename component"
}

test_two_pending_principles_are_delivered_in_order() {
  local home
  home="$TMP_ROOT/pending-multi"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"afterAgentResponse","text":"the export is faster now","cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  expect_silent "first pending principle"
  run_hook "$home" \
    '{"hook_event_name":"afterAgentResponse","text":"done [at=1731880000]: shipped the export","cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  expect_silent "second pending principle"
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Read","tool_input":{"path":"src/export.c"},"tool_output":"{\"exitCode\":0}","cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  expect_cursor_inject "principle-explain-the-number" "first pending principle delivered"
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Read","tool_input":{"path":"src/export.c"},"tool_output":"{\"exitCode\":0}","cursor_version":"x","conversation_id":"c1","generation_id":"g"}' \
    --cursor
  expect_cursor_inject "principle-prove-it-works" "second pending principle delivered"
  pass "two pending principles in one conversation are delivered in order"
}

test_cursor_post_tool_use_then_after_agent_response_injects_once() {
  local home
  home="$TMP_ROOT/pending-post-then-after"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Shell","tool_input":{"command":"echo the export is faster now"},"tool_output":"{\"exitCode\":0}","cursor_version":"x","conversation_id":"c1","generation_id":"g1"}' \
    --cursor
  expect_cursor_inject "principle-explain-the-number" "postToolUse emits the speed claim"
  run_hook "$home" \
    '{"hook_event_name":"afterAgentResponse","text":"the export is faster now","cursor_version":"x","conversation_id":"c1","generation_id":"g1"}' \
    --cursor
  expect_silent "afterAgentResponse must not re-queue a principle this generation already emitted"
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Read","tool_input":{"path":"src/export.c"},"tool_output":"{\"exitCode\":0}","cursor_version":"x","conversation_id":"c1","generation_id":"g2"}' \
    --cursor
  expect_silent "a later postToolUse must not deliver the same principle again"
  pass "postToolUse then afterAgentResponse delivers a speed claim once"
}

test_missing_generation_id_reinjects_on_later_post_tool_use() {
  local home
  home="$TMP_ROOT/pending-nogen"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Shell","tool_input":{"command":"echo the export is faster now"},"tool_output":"{\"exitCode\":0}","cursor_version":"x","conversation_id":"c1"}' \
    --cursor
  expect_cursor_inject "principle-explain-the-number" "postToolUse emits without generation_id"
  run_hook "$home" \
    '{"hook_event_name":"afterAgentResponse","text":"the export is faster now","cursor_version":"x","conversation_id":"c1"}' \
    --cursor
  expect_silent "afterAgentResponse defers without generation_id"
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Read","tool_input":{"path":"src/export.c"},"tool_output":"{\"exitCode\":0}","cursor_version":"x","conversation_id":"c1"}' \
    --cursor
  expect_cursor_inject "principle-explain-the-number" "later postToolUse delivers the deferred claim"
  pass "missing generation_id on Cursor postToolUse then afterAgentResponse then postToolUse injects twice"
}

test_second_recurring_red_same_generation_still_injects() {
  local home
  home="$TMP_ROOT/reds-second-id"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"afterAgentResponse","text":"fixed tests/export.test.sh","cursor_version":"x","conversation_id":"c1","generation_id":"g1"}' \
    --cursor
  run_hook "$home" \
    '{"hook_event_name":"afterShellExecution","command":"bash tests/export.test.sh","output":"not ok - tests/export.test.sh does the thing\n","duration":1100,"cursor_version":"x","conversation_id":"c1","generation_id":"g1"}' \
    --cursor
  run_hook "$home" \
    '{"hook_event_name":"afterShellExecution","command":"bash tests/export.test.sh","output":"not ok - tests/export.test.sh does the thing\n","duration":1100,"cursor_version":"x","conversation_id":"c1","generation_id":"g1"}' \
    --cursor
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Read","tool_input":{"path":"src/export.c"},"tool_output":"{\"exitCode\":0}","cursor_version":"x","conversation_id":"c1","generation_id":"g1"}' \
    --cursor
  expect_cursor_inject "principle-attack-the-premise" "first test id delivered"
  run_hook "$home" \
    '{"hook_event_name":"afterAgentResponse","text":"fixed tests/other.test.sh","cursor_version":"x","conversation_id":"c1","generation_id":"g1"}' \
    --cursor
  run_hook "$home" \
    '{"hook_event_name":"afterShellExecution","command":"bash tests/other.test.sh","output":"not ok - tests/other.test.sh does the thing\n","duration":1100,"cursor_version":"x","conversation_id":"c1","generation_id":"g1"}' \
    --cursor
  run_hook "$home" \
    '{"hook_event_name":"afterShellExecution","command":"bash tests/other.test.sh","output":"not ok - tests/other.test.sh does the thing\n","duration":1100,"cursor_version":"x","conversation_id":"c1","generation_id":"g1"}' \
    --cursor
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Read","tool_input":{"path":"src/other.c"},"tool_output":"{\"exitCode\":0}","cursor_version":"x","conversation_id":"c1","generation_id":"g1"}' \
    --cursor
  expect_cursor_inject "principle-attack-the-premise" "second test id in the same generation"
  pass "a second recurring-red test id in the same generation still injects principle-attack-the-premise"
}

test_cursor_and_claude_registrations_name_the_helper() {
  command -v jq >/dev/null 2>&1 || fail "jq is required to pin hook JSON"
  jq -e '.hooks.postToolUse[] | select(.command | contains("fm-pstack-verify-hook.sh --cursor"))' \
    "$ROOT/.cursor/hooks.json" >/dev/null \
    || fail "Cursor postToolUse must register the helper with --cursor"
  jq -e '.hooks.postToolUseFailure[] | select(.command | contains("fm-pstack-verify-hook.sh --cursor"))' \
    "$ROOT/.cursor/hooks.json" >/dev/null \
    || fail "Cursor postToolUseFailure must register the helper with --cursor"
  jq -e '.hooks.afterShellExecution[] | select(.command | contains("fm-pstack-verify-hook.sh --cursor"))' \
    "$ROOT/.cursor/hooks.json" >/dev/null \
    || fail "Cursor afterShellExecution must register the helper with --cursor"
  jq -e '[.hooks.preToolUse[]? | select(.command | contains("fm-pstack-verify-hook.sh"))] | length == 0' \
    "$ROOT/.cursor/hooks.json" >/dev/null \
    || fail "Cursor preToolUse must not register this helper"
  jq -e '.hooks.beforeSubmitPrompt[] | select(.command | contains("fm-pstack-verify-hook.sh --cursor"))' \
    "$ROOT/.cursor/hooks.json" >/dev/null \
    || fail "Cursor beforeSubmitPrompt must register the helper with --cursor"
  jq -e '.hooks.afterAgentResponse[] | select(.command | contains("fm-pstack-verify-hook.sh --cursor"))' \
    "$ROOT/.cursor/hooks.json" >/dev/null \
    || fail "Cursor afterAgentResponse must register the helper with --cursor"
  jq -e '.hooks.UserPromptSubmit[].hooks[] | select(.command | contains("fm-pstack-verify-hook.sh --claude"))' \
    "$ROOT/.claude/settings.json" >/dev/null \
    || fail "Claude UserPromptSubmit must register --claude"
  jq -e '.hooks.PostToolUse[].hooks[] | select(.command | contains("fm-pstack-verify-hook.sh --claude"))' \
    "$ROOT/.claude/settings.json" >/dev/null \
    || fail "Claude PostToolUse must register --claude"
  jq -e '.hooks.PostToolUseFailure[].hooks[] | select(.command | contains("fm-pstack-verify-hook.sh --claude"))' \
    "$ROOT/.claude/settings.json" >/dev/null \
    || fail "Claude PostToolUseFailure must register --claude"
  jq -e '
      [.hooks.PreToolUse[].hooks[]
        | select(.command | contains("fm-pstack-verify-hook.sh --claude"))
        | .timeout] | length >= 2 and all(. == 10)
    ' "$ROOT/.claude/settings.json" >/dev/null \
    || fail "Claude PreToolUse helper entries must set timeout 10"
  jq -e '
      [.hooks.PreToolUse[] | select(.matcher == "Write|Edit|StrReplace|NotebookEdit")
        | .hooks[] | select(.command | contains("fm-pstack-verify-hook.sh"))] | length == 1
    ' "$ROOT/.claude/settings.json" >/dev/null \
    || fail "Claude PreToolUse Write matcher must register the helper"
  jq -e '
      [.hooks.PreToolUse[] | select(.matcher == "Bash")
        | .hooks[] | select(.command | contains("fm-pstack-verify-hook.sh"))] | length == 1
    ' "$ROOT/.claude/settings.json" >/dev/null \
    || fail "Claude PreToolUse Bash matcher must register the helper"
  pass "Cursor and Claude hook files register the helper on documented events"
}

test_vendored_skills_are_present() {
  local id
  for id in principle-prove-it-works principle-test-behavior-not-implementation \
    principle-explain-the-number principle-attack-the-premise
  do
    [ -f "$ROOT/.cursor/skills/$id/SKILL.md" ] \
      || fail "missing .cursor/skills/$id/SKILL.md"
    [ -f "$ROOT/.agents/skills/$id/SKILL.md" ] \
      || fail "missing .agents/skills/$id/SKILL.md"
    cmp -s "$ROOT/.cursor/skills/$id/SKILL.md" "$ROOT/.agents/skills/$id/SKILL.md" \
      || fail "$id Cursor and Claude copies drifted"
  done
  [ -f "$ROOT/.cursor/licenses/provenance/adaptations.yaml" ] \
    || fail "missing provenance/adaptations.yaml"
  [ ! -e "$ROOT/.cursor/licenses/provenance/licenses/pstack.LICENSE" ] \
    || fail "duplicate pstack.LICENSE must not exist beside cursor_plugins.LICENSE"
  grep -Fq 'principle-prove-it-works' "$ROOT/.cursor/catalog.d/pstack-verify.yaml" \
    || fail "fork catalog entries must live in catalog.d/pstack-verify.yaml"
  grep -Fq 'principle-prove-it-works' "$ROOT/.cursor/catalog.yaml" \
    && fail "fork catalog entries must not remain in catalog.yaml"
  grep -Fq 'principle-prove-it-works' "$ROOT/.cursor/references/shared/policies/invocation.yaml" \
    || fail "invocation.yaml model_invoked must name the four skills"
  pass "the four principle skills are vendored in both skill dirs"
}

test_status_append_command_injects_prove_it_works
test_cursor_post_tool_use_status_append_injects
test_write_contents_done_line_injects_prove_it_works
test_captain_prompt_done_merge_is_not_completion
test_this_is_faster_than_main_is_a_speed_claim
test_working_status_is_not_a_completion_report
test_checks_green_question_is_not_completion
test_working_checks_green_so_far_is_not_completion
test_implementation_complete_question_is_not_completion
test_pr_ready_for_review_sentence_is_not_completion
test_blocked_line_is_not_a_completion
test_blocked_status_append_is_not_completion
test_blocked_status_write_is_not_completion
test_needs_decision_line_is_not_a_completion
test_write_of_test_file_injects_test_behavior
test_cwd_relative_test_file_write_injects
test_cursor_post_tool_write_of_test_file_injects
test_shell_redirect_to_test_file_injects
test_cwd_relative_shell_redirect_injects
test_tee_with_flags_into_test_path_injects
test_cp_into_test_path_injects
test_redirect_elsewhere_then_grep_test_path_is_silent
test_redirect_elsewhere_then_cat_test_path_is_silent
test_quoted_gt_in_echo_is_not_a_test_write
test_here_string_gt_follows_quote_blanking
test_interpreter_fed_quoted_heredoc_body_injects
test_quoted_heredoc_body_gt_is_accepted_false_positive
test_backup_test_path_is_silent
test_claude_write_of_test_file_emits_once_across_pre_and_post
test_contest_path_is_not_a_test_write
test_write_of_docs_testing_notes_is_not_a_test_change
test_docs_test_plan_is_not_a_test_file
test_speed_claim_injects_explain_the_number
test_trailing_question_on_speed_claim_still_injects
test_cursor_speed_claim_is_pending_then_delivered
test_cursor_before_submit_speed_prints_continue_only
test_two_x_as_fast_injects_explain_the_number
test_much_faster_injects_explain_the_number
test_got_a_lot_faster_injects_explain_the_number
test_its_faster_injects_explain_the_number
test_please_speed_up_ci_is_not_a_speed_claim
test_which_is_faster_is_not_a_speed_claim
test_as_fast_as_is_not_a_speed_claim
test_speedup_noun_is_not_a_speed_claim
test_cursor_before_submit_miss_still_continues
test_fast_forward_is_not_a_speed_claim
test_faster_path_is_not_a_speed_claim
test_fast_forward_does_not_hide_a_real_speed_claim
test_same_red_twice_after_claimed_fix_injects_attack_the_premise
test_claim_plus_two_after_shell_same_generation
test_after_shell_then_failure_stays_at_streak_one
test_failure_then_after_shell_stays_at_streak_one
test_claude_post_tool_use_failure_error_injects
test_cursor_post_tool_use_success_does_not_count_tap
test_fail_style_stderr_on_claude_post_tool_use
test_tap_description_is_not_keyed_as_a
test_pytest_node_id_matches_file_claim
test_jest_fail_line_is_extracted
test_glob_in_tap_line_does_not_expand
test_same_red_payload_is_idempotent
test_two_reds_without_a_claimed_fix_do_not_inject
test_different_check_ids_do_not_share_a_streak
test_stale_lock_is_broken
test_pending_without_conversation_id_is_not_stored
test_pending_does_not_cross_conversations
test_reds_do_not_cross_conversations
test_reds_without_conversation_id_are_not_recorded
test_lock_aged_five_seconds_breaks_once_stale
test_missing_jq_before_submit_still_continues
test_claude_mode_stands_down_on_cursor_before_submit
test_claude_mode_stands_down_on_cursor_post_tool_use
test_claude_mode_is_silent_on_cursor_pre_tool_use
test_empty_stdin_fails_open
test_malformed_payload_fails_open
test_missing_jq_fails_open
test_after_shell_status_append_is_consumed_by_post_tool_use
test_post_tool_then_after_shell_status_append_injects_once
test_parallel_post_tool_use_takes_pending_once
test_prefixed_is_not_a_claimed_fix
test_nested_cursor_version_stays_on_claude_path
test_command_comment_tap_is_not_a_claude_red
test_got_faster_to_write_is_not_a_speed_claim
test_dotdot_conversation_id_is_not_stored
test_two_pending_principles_are_delivered_in_order
test_cursor_post_tool_use_then_after_agent_response_injects_once
test_missing_generation_id_reinjects_on_later_post_tool_use
test_second_recurring_red_same_generation_still_injects
test_cursor_and_claude_registrations_name_the_helper
test_vendored_skills_are_present
