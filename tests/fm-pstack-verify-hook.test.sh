#!/usr/bin/env bash
# Behavior tests for bin/fm-pstack-verify-hook.sh: each pstack verification
# principle is injected when its event fires, and is not injected on a
# near-miss. Tests drive the hook through payloads, never by reading the
# helper's source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }

HOOK="$ROOT/bin/fm-pstack-verify-hook.sh"
TMP_ROOT=$(fm_test_tmproot fm-pstack-verify-hook)
trap fm_test_cleanup EXIT

run_hook() {  # <root> <payload-json> [flags...]
  local root=$1 payload=$2
  shift 2
  printf '%s' "$payload" | env -u FM_HOME \
    FM_ROOT_OVERRIDE="$root" FM_STATE_OVERRIDE="$root/state" \
    bash "$HOOK" "$@"
}

expect_principle() {  # <output> <principle> <label>
  printf '%s' "$1" | jq -e --arg p "$2" '
      (.hookSpecificOutput.additionalContext // .additional_context // "")
      | contains($p)
    ' >/dev/null 2>&1 || fail "$3: expected $2, got: $1"
}

expect_silent() {  # <output> <label>
  [ -z "$1" ] || fail "$2: expected no injection, got: $1"
}

PRIMARY="$TMP_ROOT/primary"
mkdir -p "$PRIMARY/state"

test_completion_report_injects_prove_it_works() {
  local out
  out=$(run_hook "$PRIMARY" \
    '{"hook_event_name":"afterAgentResponse","text":"done: PR https://example.test/pull/3 ready for review","cursor_version":"x"}' \
    --cursor)
  expect_principle "$out" "principle-prove-it-works" "a done: completion report"
  pass "a done: completion report injects principle-prove-it-works"
}

test_stamped_done_line_is_a_completion_report() {
  local out
  out=$(run_hook "$PRIMARY" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"done [at=1]: implementation complete, checks green"}' \
    --claude)
  expect_principle "$out" "principle-prove-it-works" "a stamped done: line"
  pass "a stamped done: status line injects principle-prove-it-works"
}

test_working_status_is_not_a_completion_report() {
  local out
  out=$(run_hook "$PRIMARY" \
    '{"hook_event_name":"afterAgentResponse","text":"working: still implementing the export","cursor_version":"x"}' \
    --cursor)
  expect_silent "$out" "working: is not a completion report"
  pass "a working: line does not inject principle-prove-it-works"
}

test_write_of_test_file_injects_test_behavior() {
  local out
  out=$(run_hook "$PRIMARY" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"path":"tests/fm-export.test.sh"}}' \
    --claude)
  expect_principle "$out" "principle-test-behavior-not-implementation" "Write of a test file"
  pass "writing a test file injects principle-test-behavior-not-implementation"
}

test_write_of_docs_testing_notes_is_not_a_test_change() {
  local out
  out=$(run_hook "$PRIMARY" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"path":"docs/testing.md"}}' \
    --claude)
  expect_silent "$out" "docs/testing.md is not a test file"
  pass "writing docs/testing.md does not inject principle-test-behavior-not-implementation"
}

test_speed_claim_injects_explain_the_number() {
  local out
  out=$(run_hook "$PRIMARY" \
    '{"hook_event_name":"beforeSubmitPrompt","prompt":"the export is faster now","cursor_version":"x"}' \
    --cursor)
  expect_principle "$out" "principle-explain-the-number" "an is-faster claim"
  pass "a speed claim injects principle-explain-the-number"
}

test_fast_forward_is_not_a_speed_claim() {
  local out
  out=$(run_hook "$PRIMARY" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"fast-forward the merge onto main"}' \
    --claude)
  expect_silent "$out" "fast-forward is not a speed claim"
  pass "fast-forward does not inject principle-explain-the-number"
}

test_faster_path_is_not_a_speed_claim() {
  local out
  out=$(run_hook "$PRIMARY" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"use the faster path without stacked review"}' \
    --claude)
  expect_silent "$out" "faster path is firstmate delivery language"
  pass "faster path does not inject principle-explain-the-number"
}

test_same_red_twice_after_claimed_fix_injects_attack_the_premise() {
  local home out
  home="$TMP_ROOT/reds"
  mkdir -p "$home/state"
  out=$(run_hook "$home" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"fixed tests/export.test.sh","prompt_id":"c1"}' \
    --claude)
  expect_silent "$out" "a claimed fix alone is not a recurring red"
  out=$(run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":"FAILED tests/export.test.sh","tool_use_id":"r1"}' \
    --claude)
  expect_silent "$out" "the first red after a claimed fix is not yet recurring"
  out=$(run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":"FAILED tests/export.test.sh","tool_use_id":"r2"}' \
    --claude)
  expect_principle "$out" "principle-attack-the-premise" "the same red twice after a claimed fix"
  pass "the same red twice after a claimed fix injects principle-attack-the-premise"
}

test_same_red_payload_is_idempotent() {
  local home out
  home="$TMP_ROOT/reds-idem"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"fixed tests/export.test.sh","prompt_id":"c1"}' \
    --claude >/dev/null
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":"FAILED tests/export.test.sh","tool_use_id":"r1"}' \
    --claude >/dev/null
  out=$(run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":"FAILED tests/export.test.sh","tool_use_id":"r1"}' \
    --claude)
  expect_silent "$out" "the same tool_use_id must not count as a second red"
  pass "a repeated red payload with the same token does not inject"
}

test_two_reds_without_a_claimed_fix_do_not_inject() {
  local home out
  home="$TMP_ROOT/reds-noclaim"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":"FAILED tests/export.test.sh","tool_use_id":"a"}' \
    --claude >/dev/null
  out=$(run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":"FAILED tests/export.test.sh","tool_use_id":"b"}' \
    --claude)
  expect_silent "$out" "two reds with no claimed fix"
  pass "the same red twice with no claimed fix does not inject"
}

test_different_check_ids_do_not_share_a_streak() {
  local home out
  home="$TMP_ROOT/reds-other"
  mkdir -p "$home/state"
  run_hook "$home" \
    '{"hook_event_name":"UserPromptSubmit","prompt":"fixed tests/export.test.sh","prompt_id":"c1"}' \
    --claude >/dev/null
  run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":"FAILED tests/export.test.sh","tool_use_id":"r1"}' \
    --claude >/dev/null
  out=$(run_hook "$home" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":"FAILED tests/other.test.sh","tool_use_id":"r2"}' \
    --claude)
  expect_silent "$out" "a different check id is not the same red"
  pass "a different check id does not inject principle-attack-the-premise"
}

test_claude_mode_stands_down_on_cursor_payload() {
  local out
  out=$(run_hook "$PRIMARY" \
    '{"hook_event_name":"afterAgentResponse","text":"done: PR https://example.test/pull/9 ready","cursor_version":"x"}' \
    --claude)
  expect_silent "$out" "Claude registration must stand down on a Cursor payload"
  pass " --claude is silent on a Cursor-delivered payload"
}

test_malformed_payload_fails_open() {
  local out status
  status=0
  out=$(run_hook "$PRIMARY" '{not-json' --cursor) || status=$?
  expect_code 0 "$status" "malformed JSON must not fail the turn"
  expect_silent "$out" "malformed JSON must not inject"
  pass "malformed JSON fails open"
}

test_cursor_and_claude_registrations_name_the_helper() {
  jq -e '.hooks.beforeSubmitPrompt[] | select(.command | contains("fm-pstack-verify-hook.sh"))' \
    "$ROOT/.cursor/hooks.json" >/dev/null \
    || fail "Cursor beforeSubmitPrompt must register the helper"
  jq -e '.hooks.afterAgentResponse[] | select(.command | contains("fm-pstack-verify-hook.sh"))' \
    "$ROOT/.cursor/hooks.json" >/dev/null \
    || fail "Cursor afterAgentResponse must register the helper"
  jq -e '.hooks.preToolUse[] | select(.command | contains("fm-pstack-verify-hook.sh"))' \
    "$ROOT/.cursor/hooks.json" >/dev/null \
    || fail "Cursor preToolUse must register the helper"
  jq -e '.hooks.UserPromptSubmit[].hooks[] | select(.command | contains("fm-pstack-verify-hook.sh"))' \
    "$ROOT/.claude/settings.json" >/dev/null \
    || fail "Claude UserPromptSubmit must register the helper"
  jq -e '.hooks.PostToolUse[].hooks[] | select(.command | contains("fm-pstack-verify-hook.sh"))' \
    "$ROOT/.claude/settings.json" >/dev/null \
    || fail "Claude PostToolUse must register the helper"
  jq -e '.hooks.PreToolUse[].hooks[] | select(.command | contains("fm-pstack-verify-hook.sh"))' \
    "$ROOT/.claude/settings.json" >/dev/null \
    || fail "Claude PreToolUse must register the helper"
  pass "Cursor and Claude hook files register the helper"
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
  pass "the four principle skills are vendored in both skill dirs"
}

test_completion_report_injects_prove_it_works
test_stamped_done_line_is_a_completion_report
test_working_status_is_not_a_completion_report
test_write_of_test_file_injects_test_behavior
test_write_of_docs_testing_notes_is_not_a_test_change
test_speed_claim_injects_explain_the_number
test_fast_forward_is_not_a_speed_claim
test_faster_path_is_not_a_speed_claim
test_same_red_twice_after_claimed_fix_injects_attack_the_premise
test_same_red_payload_is_idempotent
test_two_reds_without_a_claimed_fix_do_not_inject
test_different_check_ids_do_not_share_a_streak
test_claude_mode_stands_down_on_cursor_payload
test_malformed_payload_fails_open
test_cursor_and_claude_registrations_name_the_helper
test_vendored_skills_are_present
