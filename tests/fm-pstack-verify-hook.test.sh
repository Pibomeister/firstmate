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

# Cursor postToolUse / postToolUseFailure / afterAgentResponse / afterShellExecution
# document additional_context and must not carry permission
# (https://cursor.com/docs/hooks).
expect_cursor_inject() {  # <principle> <label>
  expect_exit_ok "$2"
  [ -n "$RUN_OUT" ] || fail "$2: expected JSON, got empty stdout"
  printf '%s' "$RUN_OUT" | jq -e --arg p "$1" '
      (has("additional_context") and (.additional_context|type=="string")
        and (.additional_context|contains($p)))
      and (has("permission")|not)
    ' >/dev/null 2>&1 || fail "$2: Cursor schema/principle $1, got: $RUN_OUT"
}

expect_cursor_continue_inject() {  # <principle> <label>
  expect_exit_ok "$2"
  printf '%s' "$RUN_OUT" | jq -e --arg p "$1" '
      .continue==true
      and (.additional_context|type=="string")
      and (.additional_context|contains($p))
      and (has("permission")|not)
    ' >/dev/null 2>&1 || fail "$2: beforeSubmitPrompt schema/principle $1, got: $RUN_OUT"
}

# Claude documents hookSpecificOutput.additionalContext.
expect_claude_inject() {  # <principle> <label>
  expect_exit_ok "$2"
  [ -n "$RUN_OUT" ] || fail "$2: expected JSON, got empty stdout"
  printf '%s' "$RUN_OUT" | jq -e --arg p "$1" '
      (.hookSpecificOutput.additionalContext|type=="string")
      and (.hookSpecificOutput.additionalContext|contains($p))
      and (has("permission")|not)
    ' >/dev/null 2>&1 || fail "$2: Claude schema/principle $1, got: $RUN_OUT"
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
  expect_claude_inject "principle-prove-it-works" "STATUS_APPEND echo of done [at=]"
  pass "a STATUS_APPEND command injects principle-prove-it-works"
}

test_write_contents_done_line_injects_prove_it_works() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"path":"state/t.status","contents":"done [at=1731880000]: shipped\n"}}' \
    --claude
  expect_claude_inject "principle-prove-it-works" "Write contents with a done line"
  pass "Write contents holding a done line injects principle-prove-it-works"
}

test_working_status_is_not_a_completion_report() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"afterAgentResponse","text":"working: still implementing the export","cursor_version":"x"}' \
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
    '{"hook_event_name":"afterAgentResponse","text":"working: checks green so far","cursor_version":"x"}' \
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

test_write_of_test_file_injects_test_behavior() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"path":"tests/fm-export.test.sh","contents":"pass x\n"}}' \
    --claude
  expect_claude_inject "principle-test-behavior-not-implementation" "Write of a test file"
  pass "writing a test file injects principle-test-behavior-not-implementation"
}

test_cursor_post_tool_write_of_test_file_injects() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"postToolUse","tool_name":"Write","tool_input":{"path":"tests/fm-export.test.sh","contents":"pass x\n"},"tool_output":"{\"exitCode\":0}","cursor_version":"x"}' \
    --cursor
  expect_cursor_inject "principle-test-behavior-not-implementation" "Cursor postToolUse Write of a test file"
  pass "Cursor postToolUse writing a test file injects principle-test-behavior-not-implementation"
}

test_shell_redirect_to_test_file_injects() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat > tests/fm-export.test.sh <<EOF\npass x\nEOF"}}' \
    --claude
  expect_claude_inject "principle-test-behavior-not-implementation" "heredoc into a test path"
  pass "a Shell heredoc into a test path injects principle-test-behavior-not-implementation"
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
    '{"hook_event_name":"beforeSubmitPrompt","prompt":"the export is faster now","cursor_version":"x"}' \
    --cursor
  expect_cursor_continue_inject "principle-explain-the-number" "an is-faster claim"
  pass "a speed claim injects principle-explain-the-number"
}

test_two_x_as_fast_injects_explain_the_number() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"afterAgentResponse","text":"export is 2x as fast on the 60k-row set","cursor_version":"x"}' \
    --cursor
  expect_cursor_inject "principle-explain-the-number" "2x as fast"
  pass "2x as fast injects principle-explain-the-number"
}

test_much_faster_injects_explain_the_number() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"afterAgentResponse","text":"the parse path is much faster","cursor_version":"x"}' \
    --cursor
  expect_cursor_inject "principle-explain-the-number" "much faster"
  pass "much faster injects principle-explain-the-number"
}

test_got_a_lot_faster_injects_explain_the_number() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"afterAgentResponse","text":"the parse path got a lot faster","cursor_version":"x"}' \
    --cursor
  expect_cursor_inject "principle-explain-the-number" "got a lot faster"
  pass "got a lot faster injects principle-explain-the-number"
}

test_please_speed_up_ci_is_not_a_speed_claim() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"please speed up the CI"}' \
    --claude
  expect_silent "please speed up the CI"
  pass "please speed up the CI does not inject principle-explain-the-number"
}

test_cursor_before_submit_miss_still_continues() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"beforeSubmitPrompt","prompt":"please speed up the CI","cursor_version":"x"}' \
    --cursor
  expect_exit_ok "beforeSubmitPrompt miss"
  printf '%s' "$RUN_OUT" | jq -e '.continue==true and (has("additional_context")|not) and (has("permission")|not)' \
    >/dev/null 2>&1 || fail "beforeSubmitPrompt miss must emit continue:true only, got: $RUN_OUT"
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
    '{"hook_event_name":"afterAgentResponse","text":"fast-forward onto main; the export is 2x as fast","cursor_version":"x"}' \
    --cursor
  expect_cursor_inject "principle-explain-the-number" "speed claim beside fast-forward"
  pass "fast-forward does not suppress a later 2x as fast claim"
}

test_same_red_twice_after_claimed_fix_injects_attack_the_premise() {
  local home
  home="$TMP_ROOT/reds"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"afterAgentResponse","text":"fixed tests/export.test.sh","cursor_version":"x"}' \
    --cursor
  expect_silent "a claimed fix alone is not a recurring red"
  run_hook "$home" \
    '{"hook_event_name":"afterShellExecution","command":"bash tests/export.test.sh","output":"not ok - tests/export.test.sh does the thing\n","cursor_version":"x","tool_use_id":"r1"}' \
    --cursor
  expect_silent "the first TAP red after a claimed fix is not yet recurring"
  run_hook "$home" \
    '{"hook_event_name":"afterShellExecution","command":"bash tests/export.test.sh","output":"not ok - tests/export.test.sh does the thing\n","cursor_version":"x","tool_use_id":"r2"}' \
    --cursor
  expect_cursor_inject "principle-attack-the-premise" "the same TAP red twice after a claimed fix"
  pass "the same TAP red twice after a claimed fix injects principle-attack-the-premise"
}

test_cursor_post_tool_use_stderr_from_tool_output_json() {
  local home
  home="$TMP_ROOT/reds-cursor-stderr"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"afterAgentResponse","text":"fixed tests/export.test.sh","cursor_version":"x"}' \
    --cursor
  expect_silent "claim alone"
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Shell","tool_input":{"command":"bash tests/export.test.sh"},"tool_output":"{\"exitCode\":1,\"stdout\":\"\",\"stderr\":\"not ok - tests/export.test.sh does the thing\\n\"}","cursor_version":"x","tool_use_id":"s1"}' \
    --cursor
  expect_silent "first Cursor tool_output stderr red"
  run_hook "$home" \
    '{"hook_event_name":"postToolUse","tool_name":"Shell","tool_input":{"command":"bash tests/export.test.sh"},"tool_output":"{\"exitCode\":1,\"stdout\":\"\",\"stderr\":\"not ok - tests/export.test.sh does the thing\\n\"}","cursor_version":"x","tool_use_id":"s2"}' \
    --cursor
  expect_cursor_inject "principle-attack-the-premise" "Cursor postToolUse tool_output.stderr TAP"
  pass "Cursor postToolUse JSON tool_output stderr injects principle-attack-the-premise on the second red"
}

test_fail_style_stderr_on_claude_post_tool_use() {
  local home
  home="$TMP_ROOT/reds-stderr"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"bash tests/export.test.sh"},"tool_response":{"stdout":"1..1\n","stderr":"not ok - tests/export.test.sh does the thing\n"},"tool_use_id":"c1"}' \
    --claude
  expect_silent "first stderr TAP red with no prior claim should not inject attack"
  run_hook "$home" \
    '{"hook_event_name":"afterAgentResponse","text":"fixed tests/export.test.sh"}' \
    --claude
  expect_silent "claim after first red is not yet a streak of two"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"","stderr":"not ok - tests/export.test.sh does the thing\n"},"tool_use_id":"r1"}' \
    --claude
  expect_silent "first red after the claim"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"","stderr":"not ok - tests/export.test.sh does the thing\n"},"tool_use_id":"r2"}' \
    --claude
  expect_claude_inject "principle-attack-the-premise" "fail()-style stderr TAP"
  pass "fail()-style not ok - stderr injects principle-attack-the-premise on the second red"
}

test_tap_description_is_not_keyed_as_a() {
  local home
  home="$TMP_ROOT/reds-tap-a"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"afterAgentResponse","text":"fixed tests/export.test.sh"}' \
    --claude
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - a done: completion report injects principle-prove-it-works\n"},"tool_use_id":"t1"}' \
    --claude
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - a working: line does not inject\n"},"tool_use_id":"t2"}' \
    --claude
  expect_silent "two different TAP descriptions must not share id a"
  pass "a TAP line not ok - a done: does not key the id as a"
}

test_same_red_payload_is_idempotent() {
  local home
  home="$TMP_ROOT/reds-idem"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"afterAgentResponse","text":"fixed tests/export.test.sh","prompt_id":"c1"}' \
    --claude
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - tests/export.test.sh\n"},"tool_use_id":"r1"}' \
    --claude
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - tests/export.test.sh\n"},"tool_use_id":"r1"}' \
    --claude
  expect_silent "the same tool_use_id must not count as a second red"
  pass "a repeated red payload with the same token does not inject"
}

test_two_reds_without_a_claimed_fix_do_not_inject() {
  local home
  home="$TMP_ROOT/reds-noclaim"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - tests/export.test.sh\n"},"tool_use_id":"a"}' \
    --claude
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - tests/export.test.sh\n"},"tool_use_id":"b"}' \
    --claude
  expect_silent "two reds with no claimed fix"
  pass "the same red twice with no claimed fix does not inject"
}

test_different_check_ids_do_not_share_a_streak() {
  local home
  home="$TMP_ROOT/reds-other"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"afterAgentResponse","text":"fixed tests/export.test.sh"}' \
    --claude
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - tests/export.test.sh\n"},"tool_use_id":"r1"}' \
    --claude
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stderr":"not ok - tests/other.test.sh\n"},"tool_use_id":"r2"}' \
    --claude
  expect_silent "a different check id is not the same red"
  pass "a different check id does not inject principle-attack-the-premise"
}

test_claude_mode_stands_down_on_cursor_post_tool_use() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"postToolUse","tool_name":"Write","tool_input":{"path":"tests/fm-export.test.sh","contents":"x"},"cursor_version":"x"}' \
    --claude
  expect_silent "Claude registration must stand down on a Cursor postToolUse payload"
  pass "--claude is silent on a Cursor-delivered postToolUse payload"
}

test_claude_mode_is_silent_on_cursor_pre_tool_use() {
  run_hook "$PRIMARY" \
    '{"hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{"command":"true"},"cursor_version":"x"}' \
    --claude
  expect_silent "Claude registration must not emit permission on Cursor preToolUse"
  pass "--claude is silent on a Cursor-delivered preToolUse payload"
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
  grep -Fq 'benchmark-checklist' "$ROOT/.cursor/skills/principle-explain-the-number/SKILL.md" \
    && fail "principle-explain-the-number still names unvendored benchmark-checklist"
  [ -f "$ROOT/.cursor/licenses/provenance/adaptations.yaml" ] \
    || fail "missing provenance/adaptations.yaml"
  [ ! -e "$ROOT/.cursor/licenses/provenance/licenses/pstack.LICENSE" ] \
    || fail "duplicate pstack.LICENSE must not exist beside cursor_plugins.LICENSE"
  pass "the four principle skills are vendored in both skill dirs"
}

test_status_append_command_injects_prove_it_works
test_write_contents_done_line_injects_prove_it_works
test_working_status_is_not_a_completion_report
test_checks_green_question_is_not_completion
test_working_checks_green_so_far_is_not_completion
test_implementation_complete_question_is_not_completion
test_pr_ready_for_review_sentence_is_not_completion
test_write_of_test_file_injects_test_behavior
test_cursor_post_tool_write_of_test_file_injects
test_shell_redirect_to_test_file_injects
test_write_of_docs_testing_notes_is_not_a_test_change
test_docs_test_plan_is_not_a_test_file
test_speed_claim_injects_explain_the_number
test_two_x_as_fast_injects_explain_the_number
test_much_faster_injects_explain_the_number
test_got_a_lot_faster_injects_explain_the_number
test_please_speed_up_ci_is_not_a_speed_claim
test_cursor_before_submit_miss_still_continues
test_fast_forward_is_not_a_speed_claim
test_faster_path_is_not_a_speed_claim
test_fast_forward_does_not_hide_a_real_speed_claim
test_same_red_twice_after_claimed_fix_injects_attack_the_premise
test_cursor_post_tool_use_stderr_from_tool_output_json
test_fail_style_stderr_on_claude_post_tool_use
test_tap_description_is_not_keyed_as_a
test_same_red_payload_is_idempotent
test_two_reds_without_a_claimed_fix_do_not_inject
test_different_check_ids_do_not_share_a_streak
test_claude_mode_stands_down_on_cursor_post_tool_use
test_claude_mode_is_silent_on_cursor_pre_tool_use
test_malformed_payload_fails_open
test_missing_jq_fails_open
test_cursor_and_claude_registrations_name_the_helper
test_vendored_skills_are_present
