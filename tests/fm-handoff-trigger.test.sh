#!/usr/bin/env bash
# Behavior tests for the early handoff trigger (bin/fm-handoff-trigger.sh,
# docs/configuration.md "Early handoff trigger"): the threshold, its
# configuration, the auto-compact point derived from Claude's settings, the
# fire-once guarantee (including concurrent hook calls), and the scope that
# keeps worker worktrees and Cursor payloads inert. The hook runs for real
# against synthetic Claude transcripts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }

HOOK="$ROOT/bin/fm-handoff-trigger.sh"
TMP_ROOT=$(fm_test_tmproot fm-handoff-trigger)
trap fm_test_cleanup EXIT

PRIMARY="$TMP_ROOT/primary"
mkdir -p "$PRIMARY/state" "$PRIMARY/config" "$PRIMARY/bin" "$PRIMARY/.claude"
git init -q "$PRIMARY"
git -C "$PRIMARY" commit -q --allow-empty -m init
: > "$PRIMARY/AGENTS.md"
CLAUDE_HOME="$TMP_ROOT/claude-config"
mkdir -p "$CLAUDE_HOME"

# transcript <file> <context-tokens> [model]: one user turn and one assistant
# turn whose usage adds up to <context-tokens>.
transcript() {
  local file=$1 tokens=$2 model=${3:-claude-test-model}
  {
    printf '{"type":"user","message":{"content":"hi"}}\n'
    jq -nc --argjson t "$tokens" --arg m "$model" '{type: "assistant", message: {model: $m,
      usage: {input_tokens: 2, cache_read_input_tokens: ($t - 1002), cache_creation_input_tokens: 1000, output_tokens: 50}}}'
  } > "$file"
}

# run_hook <root> <session> <transcript> [event] [extra-payload-jq]: print the
# hook's stdout for one payload, with Claude's settings isolated to the lab.
run_hook() {
  local root=$1 session=$2 file=$3 event=${4:-PostToolUse} extra=${5:-.}
  jq -nc --arg s "$session" --arg t "$file" --arg e "$event" \
    '{session_id: $s, transcript_path: $t, hook_event_name: $e, tool_name: "Bash"}' \
    | jq -c "$extra" \
    | env -u CLAUDE_AUTOCOMPACT_PCT_OVERRIDE -u FM_HOME -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE \
      FM_ROOT_OVERRIDE="$root" CLAUDE_CONFIG_DIR="$CLAUDE_HOME" CLAUDE_PROJECT_DIR="$root" \
      ${HOOK_ENV:+"$HOOK_ENV"} bash "$HOOK"
}

reset_lab() {
  rm -f "$PRIMARY"/state/.handoff-trigger.* "$PRIMARY/config/handoff-trigger" \
    "$PRIMARY/.claude/settings.json" "$PRIMARY/.claude/settings.local.json" "$CLAUDE_HOME/settings.json"
}

expect_fire() {  # <output> <event> <label>
  printf '%s' "$1" | jq -e --arg e "$2" '
      .hookSpecificOutput.hookEventName == $e
      and (.hookSpecificOutput.additionalContext | test("handoff"))
    ' >/dev/null 2>&1 || fail "$3: expected one handoff instruction for $2, got: $1"
}

expect_silent() {  # <output> <label>
  [ -z "$1" ] || fail "$2: expected no output, got: $1"
}

test_threshold_default_15() {
  reset_lab
  printf 'compact-at-tokens=100000\n' > "$PRIMARY/config/handoff-trigger"
  transcript "$TMP_ROOT/t-84" 84000
  expect_silent "$(run_hook "$PRIMARY" s-below "$TMP_ROOT/t-84")" "16% left is above the default threshold"
  [ ! -e "$PRIMARY/state/.handoff-trigger.s-below" ] || fail "a silent call must not claim the session's firing"
  transcript "$TMP_ROOT/t-85" 85000
  out=$(run_hook "$PRIMARY" s-at "$TMP_ROOT/t-85")
  expect_fire "$out" PostToolUse "15% left meets the default threshold"
  printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | test("about 15% of context is left") and test("85000 of 100000 tokens")' >/dev/null \
    || fail "instruction must name the measured context left: $out"
  pass "default threshold: silent at 16% left, fires at 15% left before auto-compact"
}

test_threshold_configurable() {
  reset_lab
  printf 'compact-at-tokens=100000\npercent-left=30\n' > "$PRIMARY/config/handoff-trigger"
  transcript "$TMP_ROOT/t-70" 70000
  expect_fire "$(run_hook "$PRIMARY" s-30 "$TMP_ROOT/t-70")" PostToolUse "percent-left=30 at 30% left"
  transcript "$TMP_ROOT/t-69" 69000
  expect_silent "$(run_hook "$PRIMARY" s-31 "$TMP_ROOT/t-69")" "percent-left=30 at 31% left"
  printf 'compact-at-tokens=100000\npercent-left=0\n' > "$PRIMARY/config/handoff-trigger"
  transcript "$TMP_ROOT/t-99" 99000
  expect_silent "$(run_hook "$PRIMARY" s-off "$TMP_ROOT/t-99")" "percent-left=0 turns the trigger off"
  printf 'compact-at-tokens=100000\npercent-left=abc\n' > "$PRIMARY/config/handoff-trigger"
  expect_silent "$(run_hook "$PRIMARY" s-bad "$TMP_ROOT/t-70")" "an unusable percent-left keeps the default 15"
  pass "threshold is configurable, 0 turns it off, and an unusable value keeps the default"
}

test_fires_once_per_session() {
  reset_lab
  printf 'compact-at-tokens=100000\n' > "$PRIMARY/config/handoff-trigger"
  transcript "$TMP_ROOT/t-90" 90000
  expect_fire "$(run_hook "$PRIMARY" s-once "$TMP_ROOT/t-90")" PostToolUse "first crossing"
  expect_silent "$(run_hook "$PRIMARY" s-once "$TMP_ROOT/t-90")" "second call in the same session"
  expect_silent "$(run_hook "$PRIMARY" s-once "$TMP_ROOT/t-90" UserPromptSubmit)" "a prompt in the same session"
  transcript "$TMP_ROOT/t-99" 99000
  expect_silent "$(run_hook "$PRIMARY" s-once "$TMP_ROOT/t-99")" "deeper into the same session"
  expect_fire "$(run_hook "$PRIMARY" s-next "$TMP_ROOT/t-90" UserPromptSubmit)" UserPromptSubmit "a new session"
  pass "fires once per session across tool calls and prompts, and again for a new session"
}

test_fires_once_under_concurrency() {
  local i fired=0 out
  reset_lab
  printf 'compact-at-tokens=100000\n' > "$PRIMARY/config/handoff-trigger"
  transcript "$TMP_ROOT/t-95" 95000
  for i in 1 2 3 4 5 6 7 8; do
    run_hook "$PRIMARY" s-race "$TMP_ROOT/t-95" > "$TMP_ROOT/race.$i" &
  done
  wait
  for i in 1 2 3 4 5 6 7 8; do
    out=$(cat "$TMP_ROOT/race.$i")
    [ -z "$out" ] || { expect_fire "$out" PostToolUse "concurrent call $i"; fired=$((fired + 1)); }
  done
  [ "$fired" -eq 1 ] || fail "eight concurrent calls (parallel tool calls) must fire exactly once, fired $fired"
  pass "eight concurrent hook calls for one session fire exactly once"
}

test_compact_point_from_claude_settings() {
  reset_lab
  # Claude Code 2.1.314: compact-at = autoCompactWindow - 20000 - 13000.
  printf '{"autoCompactWindow":250000}\n' > "$CLAUDE_HOME/settings.json"
  transcript "$TMP_ROOT/t-180" 180000
  expect_silent "$(run_hook "$PRIMARY" s-w1 "$TMP_ROOT/t-180")" "180000 of 217000 is 17% left"
  transcript "$TMP_ROOT/t-185" 185000
  out=$(run_hook "$PRIMARY" s-w2 "$TMP_ROOT/t-185")
  expect_fire "$out" PostToolUse "185000 of 217000 is 14% left"
  printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | test("185000 of 217000 tokens")' >/dev/null \
    || fail "compact point must derive from autoCompactWindow 250000 as 217000: $out"

  # A project-local window beats the user window; a per-model entry beats both.
  printf '{"autoCompactWindow":"300k"}\n' > "$PRIMARY/.claude/settings.local.json"
  expect_silent "$(run_hook "$PRIMARY" s-w3 "$TMP_ROOT/t-185")" "project-local 300k window: 185000 of 267000"
  printf '{"modelSettings":{"claude-test-model":{"autoCompactWindow":220000}}}\n' > "$PRIMARY/.claude/settings.json"
  transcript "$TMP_ROOT/t-160" 160000
  out=$(run_hook "$PRIMARY" s-w4 "$TMP_ROOT/t-160")
  expect_fire "$out" PostToolUse "per-model 220000 window: 160000 of 187000"
  printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | test("160000 of 187000 tokens")' >/dev/null \
    || fail "a modelSettings entry for the session's model must win: $out"

  # CLAUDE_AUTOCOMPACT_PCT_OVERRIDE lowers the point to that share of the effective window.
  rm -f "$PRIMARY/.claude/settings.json" "$PRIMARY/.claude/settings.local.json"
  transcript "$TMP_ROOT/t-100" 100000
  out=$(HOOK_ENV=CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50 run_hook "$PRIMARY" s-w5 "$TMP_ROOT/t-100")
  expect_fire "$out" PostToolUse "50% override: 100000 of 115000"
  printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | test("100000 of 115000 tokens")' >/dev/null \
    || fail "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50 must lower the point to 115000: $out"

  # A pinned compact point wins over the derived one.
  printf 'compact-at-tokens=500000\n' > "$PRIMARY/config/handoff-trigger"
  expect_silent "$(run_hook "$PRIMARY" s-w6 "$TMP_ROOT/t-185")" "pinned compact-at-tokens overrides settings"
  pass "compact point derives from Claude's autoCompactWindow layers and override, and a pin wins"
}

test_unresolved_compact_point_is_silent() {
  reset_lab
  transcript "$TMP_ROOT/t-990" 990000
  expect_silent "$(run_hook "$PRIMARY" s-u1 "$TMP_ROOT/t-990")" "no autoCompactWindow and no pin"
  printf '{"autoCompactWindow":"auto"}\n' > "$CLAUDE_HOME/settings.json"
  expect_silent "$(run_hook "$PRIMARY" s-u2 "$TMP_ROOT/t-990")" "autoCompactWindow auto"
  printf 'compact-at-tokens=100000\n' > "$PRIMARY/config/handoff-trigger"
  printf '{"type":"user","message":{"content":"hi"}}\n' > "$TMP_ROOT/t-none"
  expect_silent "$(run_hook "$PRIMARY" s-u3 "$TMP_ROOT/t-none")" "no assistant usage yet"
  expect_silent "$(run_hook "$PRIMARY" s-u4 "$TMP_ROOT/missing")" "missing transcript"
  pass "an unresolvable compact point or unreadable usage stays silent rather than guessing"
}

test_scope() {
  local worktree="$TMP_ROOT/crew-worktree"
  reset_lab
  printf 'compact-at-tokens=100000\n' > "$PRIMARY/config/handoff-trigger"
  transcript "$TMP_ROOT/t-95" 95000
  fm_git_worktree "$PRIMARY" "$worktree" fm/handoff-trigger-test >/dev/null 2>&1 \
    || fail "could not create the crew worktree fixture"
  mkdir -p "$worktree/state" "$worktree/config" "$worktree/bin"
  cp "$PRIMARY/config/handoff-trigger" "$worktree/config/"
  expect_silent "$(run_hook "$worktree" s-crew "$TMP_ROOT/t-95")" "crew worktree"
  expect_silent "$(run_hook "$PRIMARY" s-cursor "$TMP_ROOT/t-95" PostToolUse '. + {cursor_version: "2026.08.11"}')" "Cursor payload"
  expect_silent "$(run_hook "$PRIMARY" s-stop "$TMP_ROOT/t-95" Stop)" "Stop event"
  expect_silent "$(run_hook "$PRIMARY" '' "$TMP_ROOT/t-95")" "payload without a session id"
  rm -rf "$PRIMARY/state.bak"; mv "$PRIMARY/state" "$PRIMARY/state.bak"
  expect_silent "$(run_hook "$PRIMARY" s-nostate "$TMP_ROOT/t-95")" "primary without its state dir"
  mv "$PRIMARY/state.bak" "$PRIMARY/state"
  expect_fire "$(run_hook "$PRIMARY" s-primary "$TMP_ROOT/t-95")" PostToolUse "genuine primary"
  pass "inert in a crew worktree, for Cursor payloads, other events, and a home without state; live in the primary"
}

test_threshold_default_15
test_threshold_configurable
test_fires_once_per_session
test_fires_once_under_concurrency
test_compact_point_from_claude_settings
test_unresolved_compact_point_is_silent
test_scope
