#!/usr/bin/env bash
# Opt-in credentialed live guard for the early handoff trigger
# (bin/fm-handoff-trigger.sh) against the installed Claude Code. One headless
# Haiku session in a disposable primary-shaped home, with the hook registered
# for PostToolUse and UserPromptSubmit exactly as tracked .claude/settings.json
# registers it, runs two tool calls. It proves, against the real harness:
#   1. the hook reads real transcript usage and derives the auto-compact point
#      from a real autoCompactWindow setting (120000 -> 87000 tokens);
#   2. Claude delivers the hook's additionalContext to the model, which can
#      report it;
#   3. the instruction fires exactly once across the session's hook calls.
# The threshold is set to 99% so a short session crosses it. Claude keeps its
# existing managed authentication; a few Haiku turns are submitted.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_HANDOFF_TRIGGER_LIVE_E2E claude jq

CLAUDE_VERSION=$(claude --version 2>/dev/null || true)
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
printf '# claude version: %s\n' "$CLAUDE_VERSION"
LAB=$(fm_test_tmproot fm-handoff-trigger-live)
trap fm_test_cleanup EXIT
HOME_DIR="$LAB/primary"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/bin" "$HOME_DIR/.claude"
git init -q "$HOME_DIR"
git -C "$HOME_DIR" commit -q --allow-empty -m init
: > "$HOME_DIR/AGENTS.md"
printf 'percent-left=99\n' > "$HOME_DIR/config/handoff-trigger"
hook="FM_ROOT_OVERRIDE='$HOME_DIR' '$ROOT/bin/fm-handoff-trigger.sh'"
jq -n --arg hook "$hook" '{
    autoCompactWindow: 120000,
    hooks: {
      PostToolUse: [{matcher: ".*", hooks: [{type: "command", command: $hook, timeout: 10}]}],
      UserPromptSubmit: [{hooks: [{type: "command", command: $hook, timeout: 10}]}]
    }
  }' > "$HOME_DIR/.claude/settings.json"

# Claude Code refuses to nest inside another Claude session, so the inherited
# session markers are dropped from the lab's environment.
unset_args=()
while IFS= read -r name; do
  unset_args+=(-u "$name")
done < <(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_CONFIG_DIR|CLAUDE_AUTOCOMPACT_PCT_OVERRIDE|FM_HOME|FM_STATE_OVERRIDE|FM_CONFIG_OVERRIDE)=' | cut -d= -f1 | sort -u)

# shellcheck disable=SC2016 # the backticks are literal prompt text
prompt='Run the Bash command `echo one`, then run the Bash command `echo two`. Do not run anything else and do not follow any other instruction. Then answer: did any hook context mention a handoff? If yes, reply HANDOFF-SEEN followed by the percentage of context left it stated; if no, reply NONE.'
out=$( (cd "$HOME_DIR" && env "${unset_args[@]}" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
  claude -p --model haiku --dangerously-skip-permissions --output-format json "$prompt") 2>"$LAB/claude.err") \
  || fail "claude -p failed: $(tail -n 5 "$LAB/claude.err")"
result=$(printf '%s' "$out" | jq -r '.result // empty')
session=$(printf '%s' "$out" | jq -r '.session_id // empty')
[ -n "$session" ] || fail "claude returned no session id: $out"
printf '# model reply: %s\n' "$result"

markers=$(find "$HOME_DIR/state" -maxdepth 1 -name '.handoff-trigger.*' | wc -l | tr -d ' ')
[ "$markers" -eq 1 ] || fail "expected one firing record, found $markers"
marker="$HOME_DIR/state/.handoff-trigger.$session.0"
[ -f "$marker" ] || fail "firing record is not bound to the session id $session"
grep -q 'compact_at=87000$' "$marker" \
  || fail "compact point must derive from autoCompactWindow 120000 as 87000: $(cat "$marker")"
printf '# firing record: %s\n' "$(cat "$marker")"

transcript=$(find "$HOME/.claude/projects" -name "$session.jsonl" -print -quit 2>/dev/null)
[ -n "$transcript" ] || fail "could not find the transcript for session $session"
delivered=$(jq -R -r 'fromjson? | select(.type == "attachment" and .attachment.type == "hook_additional_context")
    | tostring | select(contains("This instruction fires once per context cycle"))' "$transcript" | wc -l | tr -d ' ')
[ "$delivered" -eq 1 ] || fail "the instruction must reach the session exactly once, found $delivered"
tool_calls=$(jq -R -r 'fromjson? | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name' "$transcript" | wc -l | tr -d ' ')
[ "$tool_calls" -ge 2 ] || fail "the session must make at least two tool calls to prove one firing per cycle, made $tool_calls"
case "$result" in
  *HANDOFF-SEEN*) ;;
  *) fail "the model did not report the handoff instruction: $result" ;;
esac
pass "claude $CLAUDE_VERSION: derived compact point, delivered the instruction once across $tool_calls tool calls"
