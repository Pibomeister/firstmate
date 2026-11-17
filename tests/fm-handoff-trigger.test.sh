#!/usr/bin/env bash
# Behavior tests for the early handoff trigger (bin/fm-handoff-trigger.sh,
# docs/configuration.md "Early handoff trigger"): the threshold, its
# configuration, the auto-compact point derived from Claude's settings, the
# once-per-context-cycle guarantee (including concurrent hook calls), and the scope that
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

# append_usage <file> <context-tokens>: one more assistant turn with that usage.
append_usage() {
  jq -nc --argjson t "$2" '{type: "assistant", message: {model: "claude-test-model",
    usage: {input_tokens: 2, cache_read_input_tokens: ($t - 1002), cache_creation_input_tokens: 1000, output_tokens: 50}}}' >> "$1"
}

# run_hook <root> <session> <transcript> [event] [extra-payload-jq]: print the
# hook's stdout for one payload, with Claude's settings isolated to the lab.
run_hook() {
  local root=$1 session=$2 file=$3 event=${4:-PostToolUse} extra=${5:-.}
  jq -nc --arg s "$session" --arg t "$file" --arg e "$event" \
    '{session_id: $s, transcript_path: $t, hook_event_name: $e, tool_name: "Bash"}' \
    | jq -c "$extra" \
    | env -u CLAUDE_AUTOCOMPACT_PCT_OVERRIDE -u CLAUDE_CODE_AUTO_COMPACT_WINDOW -u FM_HOME -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE \
      FM_ROOT_OVERRIDE="$root" CLAUDE_CONFIG_DIR="$CLAUDE_HOME" CLAUDE_PROJECT_DIR="$root" \
      ${HOOK_ENV:+"$HOOK_ENV"} bash "$HOOK"
}

reset_lab() {
  rm -f "$PRIMARY"/state/.handoff-trigger.* "$PRIMARY/state/.order-handoff" "$PRIMARY/config/handoff-trigger" \
    "$PRIMARY/.claude/settings.json" "$PRIMARY/.claude/settings.local.json" "$CLAUDE_HOME/settings.json"
}

expect_fire() {  # <output> <event> <label>
  printf '%s' "$1" | jq -e --arg e "$2" '
      .hookSpecificOutput.hookEventName == $e
      and (.hookSpecificOutput.additionalContext | test("of context is left before auto-compact"))
    ' >/dev/null 2>&1 || fail "$3: expected one trigger instruction for $2, got: $1"
}

# expect_mode <output> capture|handoff <label>: the firing is the capture step
# (compaction is the reset) or a planned fresh start (a full handoff).
expect_mode() {
  case "$2" in
    capture)
      printf '%s' "$1" | jq -e '.hookSpecificOutput.additionalContext
          | test("Firstmate context capture") and (contains("bin/fm-handoff-launch.sh") | not)' >/dev/null 2>&1 \
        || fail "$3: expected the capture step, got: $1" ;;
    handoff)
      printf '%s' "$1" | jq -e '.hookSpecificOutput.additionalContext
          | test("Firstmate planned fresh start") and contains("bin/fm-ledger.sh handoff")' >/dev/null 2>&1 \
        || fail "$3: expected a planned fresh start, got: $1" ;;
  esac
}

# boundary <file>: append one compaction boundary record.
boundary() {
  printf '{"type":"system","subtype":"compact_boundary","content":"Conversation compacted"}\n' >> "$1"
}

expect_silent() {  # <output> <label>
  [ -z "$1" ] || fail "$2: expected no output, got: $1"
}

test_threshold_default_15() {
  reset_lab
  printf 'compact-at-tokens=100000\n' > "$PRIMARY/config/handoff-trigger"
  transcript "$TMP_ROOT/t-84" 84000
  expect_silent "$(run_hook "$PRIMARY" s-below "$TMP_ROOT/t-84")" "16% left is above the default threshold"
  [ ! -e "$PRIMARY/state/.handoff-trigger.s-below.0" ] || fail "a silent call must not claim the session's firing"
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

test_fires_once_per_context_cycle() {
  reset_lab
  printf 'compact-at-tokens=100000\n' > "$PRIMARY/config/handoff-trigger"
  transcript "$TMP_ROOT/t-90" 90000
  expect_fire "$(run_hook "$PRIMARY" s-once "$TMP_ROOT/t-90")" PostToolUse "first crossing"
  expect_silent "$(run_hook "$PRIMARY" s-once "$TMP_ROOT/t-90")" "second call in the same session"
  expect_silent "$(run_hook "$PRIMARY" s-once "$TMP_ROOT/t-90" UserPromptSubmit)" "a prompt in the same session"
  transcript "$TMP_ROOT/t-99" 99000
  expect_silent "$(run_hook "$PRIMARY" s-once "$TMP_ROOT/t-99")" "deeper into the same session"
  expect_fire "$(run_hook "$PRIMARY" s-next "$TMP_ROOT/t-90" UserPromptSubmit)" UserPromptSubmit "a new session"
  pass "fires once per cycle across tool calls and prompts, and again for a new session"
}

test_rearms_after_compaction() {
  local t="$TMP_ROOT/t-cycle"
  reset_lab
  printf 'compact-at-tokens=100000\n' > "$PRIMARY/config/handoff-trigger"
  transcript "$t" 90000
  expect_fire "$(run_hook "$PRIMARY" s-cycle "$t")" PostToolUse "first cycle"
  expect_silent "$(run_hook "$PRIMARY" s-cycle "$t")" "first cycle, second call"

  printf '{"type":"system","subtype":"compact_boundary","content":"Conversation compacted"}\n' >> "$t"
  expect_silent "$(run_hook "$PRIMARY" s-cycle "$t" UserPromptSubmit)" "pre-compaction usage must not fire in the new cycle"
  append_usage "$t" 40000
  expect_silent "$(run_hook "$PRIMARY" s-cycle "$t")" "new cycle below the threshold"
  append_usage "$t" 88000
  expect_fire "$(run_hook "$PRIMARY" s-cycle "$t")" PostToolUse "new cycle at the threshold"
  expect_silent "$(run_hook "$PRIMARY" s-cycle "$t")" "new cycle, second call"

  # Text that quotes a boundary is not a compaction.
  jq -nc '{type: "user", message: {content: "{\"type\":\"system\",\"subtype\":\"compact_boundary\"}"}}' >> "$t"
  expect_silent "$(run_hook "$PRIMARY" s-cycle "$t")" "a quoted boundary does not re-arm"
  pass "a compaction re-arms the trigger for one more firing, and stale usage cannot spend it"
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

  # CLAUDE_AUTOCOMPACT_PCT_OVERRIDE lowers the point to that share of the effective window.
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

# expect_point <session> <compact-point> <label> [model]: the hook fires at
# 99% of the point and names it.
expect_point() {
  local tokens=$(($2 * 99 / 100)) out
  transcript "$TMP_ROOT/t-point" "$tokens" "${4:-claude-test-model}"
  out=$(run_hook "$PRIMARY" "$1" "$TMP_ROOT/t-point")
  printf '%s' "$out" | jq -e --arg want "$tokens of $2 tokens" '.hookSpecificOutput.additionalContext | contains($want)' >/dev/null \
    || fail "$3: expected the compact point $2, got: $out"
}

test_window_precedence_matches_claude() {
  reset_lab
  # The highest layer that sets either form decides.
  printf '{"modelSettings":{"claude-test-model":{"autoCompactWindow":250000}}}\n' > "$CLAUDE_HOME/settings.json"
  printf '{"autoCompactWindow":150000}\n' > "$PRIMARY/.claude/settings.local.json"
  expect_point s-p1 117000 "a higher top-level value replaces a lower per-model entry"
  printf '{"modelSettings":{"claude-test-model":{"autoCompactWindow":220000}}}\n' > "$PRIMARY/.claude/settings.json"
  expect_point s-p2 117000 "project-local top-level beats project per-model"
  rm -f "$PRIMARY/.claude/settings.local.json"
  printf '{"autoCompactWindow":300000}\n' > "$CLAUDE_HOME/settings.json"
  expect_point s-p3 187000 "a higher per-model entry beats a lower top-level value"
  printf '{"autoCompactWindow":300000,"modelSettings":{"claude-test-model":{"autoCompactWindow":220000}}}\n' > "$PRIMARY/.claude/settings.json"
  expect_point s-p4 187000 "a per-model entry beats top-level inside its layer"
  printf '{"autoCompactWindow":300000,"modelSettings":{"another-model":{"autoCompactWindow":220000}}}\n' > "$PRIMARY/.claude/settings.json"
  expect_point s-p5 267000 "another model's entry does not apply"

  # Per-model "auto" decides, and silences; top-level "auto" counts as unset.
  printf '{"modelSettings":{"claude-test-model":{"autoCompactWindow":"auto"}}}\n' > "$PRIMARY/.claude/settings.json"
  transcript "$TMP_ROOT/t-990" 990000
  expect_silent "$(run_hook "$PRIMARY" s-p6 "$TMP_ROOT/t-990")" "per-model auto at a higher layer"
  printf '{"autoCompactWindow":"auto"}\n' > "$PRIMARY/.claude/settings.json"
  expect_point s-p7 267000 "top-level auto leaves the lower layer in force"

  # Canonical model names.
  rm -f "$PRIMARY/.claude/settings.json"
  printf '{"autoCompactWindow":300000,"modelSettings":{"claude-haiku-4-5":{"autoCompactWindow":220000}}}\n' > "$CLAUDE_HOME/settings.json"
  expect_point s-p8 187000 "a canonical key matches a dated model" claude-haiku-4-5-20251001
  printf '{"modelSettings":{"claude-opus-5-5[1m]":{"autoCompactWindow":220000}}}\n' > "$CLAUDE_HOME/settings.json"
  expect_point s-p9 187000 "a [1m] key matches the canonical model" claude-opus-5-5
  printf '{"modelSettings":{"claude-opus-5-5[1m]":{"autoCompactWindow":220000},"claude-opus-5-5":{"autoCompactWindow":300000}}}\n' > "$CLAUDE_HOME/settings.json"
  expect_point s-p10 267000 "the canonical spelling wins over a variant in one layer" claude-opus-5-5
  pass "the settings layers resolve the way Claude resolves them, on canonical model names"
}

test_window_values_claude_rejects_count_as_unset() {
  local bad
  reset_lab
  transcript "$TMP_ROOT/t-990" 990000
  for bad in '"300k"' 50000 2000000 250000.5 '"250000"'; do
    printf '{"autoCompactWindow":%s}\n' "$bad" > "$CLAUDE_HOME/settings.json"
    expect_silent "$(run_hook "$PRIMARY" "s-bad-$RANDOM" "$TMP_ROOT/t-990")" "autoCompactWindow $bad alone"
  done
  printf '{"autoCompactWindow":250000}\n' > "$CLAUDE_HOME/settings.json"
  printf '{"autoCompactWindow":50000}\n' > "$PRIMARY/.claude/settings.local.json"
  expect_point s-v1 217000 "an out-of-range value leaves the lower layer in force"
  printf '{"autoCompactWindow":100000}\n' > "$PRIMARY/.claude/settings.local.json"
  expect_point s-v2 67000 "100000 is in range"
  printf '{"autoCompactWindow":1000000}\n' > "$PRIMARY/.claude/settings.local.json"
  expect_point s-v3 967000 "1000000 is in range"
  pass "only integers from 100000 to 1000000 count as a settings window"
}

test_window_env_override() {
  reset_lab
  printf '{"modelSettings":{"claude-test-model":{"autoCompactWindow":"auto"}}}\n' > "$CLAUDE_HOME/settings.json"
  HOOK_ENV=CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 expect_point s-e1 167000 "env beats settings"
  HOOK_ENV=CLAUDE_CODE_AUTO_COMPACT_WINDOW=300k expect_point s-e2 267000 "env accepts k"
  HOOK_ENV=CLAUDE_CODE_AUTO_COMPACT_WINDOW=1m expect_point s-e3 967000 "env accepts m"
  HOOK_ENV=CLAUDE_CODE_AUTO_COMPACT_WINDOW=200 expect_point s-e4 67000 "env below the minimum is the minimum"
  HOOK_ENV=CLAUDE_CODE_AUTO_COMPACT_WINDOW=5m expect_point s-e5 967000 "env above the maximum is the maximum"
  printf '{"autoCompactWindow":250000}\n' > "$CLAUDE_HOME/settings.json"
  HOOK_ENV=CLAUDE_CODE_AUTO_COMPACT_WINDOW=soon expect_point s-e6 217000 "an unusable env value is ignored"
  pass "CLAUDE_CODE_AUTO_COMPACT_WINDOW overrides settings the way Claude reads it"
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

# Open durable captain orders are part of the handoff: the firing names each
# one, and once it has fired the Stop hook blocks the handoff turn's stop until
# the recorded handoff document lists every open order (bin/fm-order.sh gate).
test_names_open_captain_orders_and_gates_the_stop() {
  local order_id rc err doc succ
  reset_lab
  rm -rf "$PRIMARY/data/orders" "$PRIMARY"/data/handoff-*.md "$PRIMARY/state/.order-handoff"
  printf 'compact-at-tokens=100000\nfresh-start-after=0\n' > "$PRIMARY/config/handoff-trigger"
  transcript "$TMP_ROOT/t-90" 90000
  out=$(run_hook "$PRIMARY" s-orders-none "$TMP_ROOT/t-90")
  expect_fire "$out" PostToolUse "no open orders"
  printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | test("captain orders") | not' >/dev/null \
    || fail "with no open orders the instruction must not mention captain orders: $out"
  FM_HOME="$PRIMARY" "$ROOT/bin/fm-order.sh" send --from test "order mid handoff" >/dev/null \
    || fail "could not send the order fixture"
  order_id=$(find "$PRIMARY/data/orders/pending" -name '*.order' | sed 's#.*/##; s/\.order$//')

  # Before the trigger fires in this session, a stop is never gated.
  rc=0
  run_hook "$PRIMARY" s-orders "$TMP_ROOT/t-90" Stop >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "a stop before the handoff trigger fired must not be gated (rc=$rc)"

  out=$(run_hook "$PRIMARY" s-orders "$TMP_ROOT/t-90")
  expect_fire "$out" PostToolUse "one open order"
  printf '%s' "$out" | jq -e --arg id "$order_id" '.hookSpecificOutput.additionalContext | contains("Open captain orders that your handoff must list: " + $id + " (pending)")' >/dev/null \
    || fail "the instruction must name the open order $order_id: $out"
  printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("bin/fm-order.sh handoff --doc")' >/dev/null \
    || fail "the instruction must name the command that writes the orders into the handoff: $out"
  printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("If bin/fm-ledger.sh cannot read the backlog, do not skip the handoff")' >/dev/null \
    || fail "the instruction must give a handoff path that works when the ledger cannot read the backlog: $out"

  err="$TMP_ROOT/stop.err"
  rc=0
  run_hook "$PRIMARY" s-orders "$TMP_ROOT/t-90" Stop >/dev/null 2>"$err" || rc=$?
  [ "$rc" -eq 2 ] || fail "a handoff turn whose handoff omits an open order must be blocked (rc=$rc)"
  assert_contains "$(cat "$err")" "$order_id" "the block names the missing order"
  rc=0
  run_hook "$PRIMARY" s-orders "$TMP_ROOT/t-90" Stop '. + {stop_hook_active: true}' >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "a stop already continued by this hook must not be blocked again (rc=$rc)"

  doc="$PRIMARY/data/handoff-20261031-1200-captain-restart.md"
  printf '# Handoff\n' > "$doc"
  FM_HOME="$PRIMARY" "$ROOT/bin/fm-order.sh" handoff --doc "$doc" >/dev/null || fail "handoff --doc must succeed"
  # The orders are listed, but no successor has been launched yet: the stop
  # is still blocked, now by the successor gate (issues 133, 116).
  err="$TMP_ROOT/stop-successor.err"
  rc=0
  run_hook "$PRIMARY" s-orders "$TMP_ROOT/t-90" Stop >/dev/null 2>"$err" || rc=$?
  [ "$rc" -eq 2 ] || fail "a handoff turn with no successor launched must be blocked (rc=$rc)"
  assert_contains "$(cat "$err")" "state/.handoff-successor" "the successor block names the launch record"
  sleep 60 &
  succ=$!
  printf 'pid=%s\nhandoff=%s\n' "$succ" "$doc" > "$PRIMARY/state/.handoff-successor"
  rc=0
  run_hook "$PRIMARY" s-orders "$TMP_ROOT/t-90" Stop >/dev/null 2>"$err" || rc=$?
  kill "$succ" 2>/dev/null; wait "$succ" 2>/dev/null
  [ "$rc" -eq 2 ] || fail "listing orders and a live PID still requires the verified successor ack (rc=$rc)"
  assert_not_contains "$(cat "$err")" "$order_id" "the order gate clears once the handoff lists every open order"
  assert_contains "$(cat "$err")" "no verified successor acknowledgement" "only the successor gate still blocks the stop"
  rm -rf "$PRIMARY/data/orders" "$doc" "$PRIMARY/state/.order-handoff" "$PRIMARY/state/.handoff-successor"
  pass "a firing names every open captain order, and the stop is gated until the handoff lists them"
}

# A session that starts a handoff itself - stow or a restart - is gated even
# when the trigger never fired, including with the trigger off
# (percent-left=0). An ordinary stop with no handoff under way is never gated.
test_a_recorded_handoff_gates_the_stop_without_the_trigger() {
  local order_id rc err doc
  reset_lab
  rm -rf "$PRIMARY/data/orders" "$PRIMARY/state/.order-handoff"
  printf 'percent-left=0\n' > "$PRIMARY/config/handoff-trigger"
  transcript "$TMP_ROOT/t-stow" 10000
  FM_HOME="$PRIMARY" "$ROOT/bin/fm-order.sh" send --from test "order before stow" >/dev/null \
    || fail "could not send the order fixture"
  order_id=$(find "$PRIMARY/data/orders/pending" -name '*.order' | sed 's#.*/##; s/\.order$//')
  rc=0
  run_hook "$PRIMARY" s-stow "$TMP_ROOT/t-stow" Stop >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "an ordinary stop with no handoff under way must not be gated (rc=$rc)"

  doc="$PRIMARY/data/stow-handoff.md"
  printf '# Handoff\n' > "$doc"
  FM_HOME="$PRIMARY" "$ROOT/bin/fm-order.sh" handoff --doc "$doc" >/dev/null || fail "handoff --doc must succeed"
  rc=0
  run_hook "$PRIMARY" s-stow "$TMP_ROOT/t-stow" Stop >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "a recorded handoff that lists every open order lets the stop pass (rc=$rc)"
  sleep 1
  FM_HOME="$PRIMARY" "$ROOT/bin/fm-order.sh" send --from test "order after the stow handoff" >/dev/null \
    || fail "could not send the second order fixture"
  err="$TMP_ROOT/stow-stop.err"
  rc=0
  run_hook "$PRIMARY" s-stow "$TMP_ROOT/t-stow" Stop >/dev/null 2>"$err" || rc=$?
  [ "$rc" -eq 2 ] || fail "with percent-left=0, a recorded handoff that omits an open order must block the stop (rc=$rc)"
  assert_not_contains "$(cat "$err")" "$order_id" "the block names only the missing order"
  rc=0
  run_hook "$PRIMARY" s-stow "$TMP_ROOT/t-stow" Stop '. + {stop_hook_active: true}' >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "a stop already continued by this hook must not be blocked again (rc=$rc)"
  rm -rf "$PRIMARY/data/orders" "$doc" "$PRIMARY/state/.order-handoff" "$PRIMARY/config/handoff-trigger"
  pass "a recorded handoff gates the stop even with the trigger off, and an ordinary stop is never gated"
}

# Two harness sessions share one home: the lock owner records its handoff
# (stow), a newer order arrives, and a second, read-only session in the same
# home stops. Each session is a fake harness (a bash symlink named "claude"),
# so bin/fm-session-lock-lib.sh's ancestry walk tells them apart. Only the
# session that wrote the handoff is handing off; the other's stop stays
# ordinary, while the writer's own stop is still gated.
test_another_sessions_handoff_never_gates_this_stop() {
  local fakebin doc ready go a_pid rc err order_id
  reset_lab
  rm -rf "$PRIMARY/data/orders"
  fakebin="$TMP_ROOT/fake-harness"
  mkdir -p "$fakebin"
  ln -sf /bin/bash "$fakebin/claude"
  printf 'percent-left=0\n' > "$PRIMARY/config/handoff-trigger"
  transcript "$TMP_ROOT/t-two" 10000
  doc="$PRIMARY/data/two-handoff.md"
  ready="$TMP_ROOT/two.ready"
  go="$TMP_ROOT/two.go"
  rm -f "$ready" "$go"
  printf '# Handoff\n' > "$doc"
  FM_HOME="$PRIMARY" "$ROOT/bin/fm-order.sh" send --from test "order before the handoff" >/dev/null \
    || fail "could not send the order fixture"
  (
    export HOOK CLAUDE_HOME PRIMARY ROOT doc ready go TMP_ROOT
    export -f run_hook
    # shellcheck disable=SC2016 # The fake harness shell expands these.
    exec "$fakebin/claude" -c '
      FM_HOME="$PRIMARY" "$ROOT/bin/fm-order.sh" handoff --doc "$doc" >/dev/null || exit 9
      : > "$ready"
      n=0
      while [ ! -e "$go" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done
      rc=0
      run_hook "$PRIMARY" s-owner "$TMP_ROOT/t-two" Stop >/dev/null 2>"$TMP_ROOT/two-owner.err" || rc=$?
      exit "$rc"'
  ) &
  a_pid=$!
  n=0
  while [ ! -e "$ready" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done
  [ -e "$ready" ] || { kill "$a_pid" 2>/dev/null; fail "the handoff-writing session never recorded its handoff"; }
  sleep 1
  FM_HOME="$PRIMARY" "$ROOT/bin/fm-order.sh" send --from test "order after the handoff" >/dev/null \
    || fail "could not send the second order fixture"
  order_id=$(find "$PRIMARY/data/orders/pending" -name '*.order' | sed 's#.*/##; s/\.order$//' | sort | tail -n 1)

  err="$TMP_ROOT/two-other.err"
  rc=0
  (
    export HOOK CLAUDE_HOME PRIMARY ROOT TMP_ROOT
    export -f run_hook
    # shellcheck disable=SC2016 # The fake harness shell expands these.
    exec "$fakebin/claude" -c 'run_hook "$PRIMARY" s-other "$TMP_ROOT/t-two" Stop >/dev/null'
  ) 2>"$err" || rc=$?
  [ "$rc" -eq 0 ] || fail "another session's handoff record must not gate this session's ordinary stop (rc=$rc): $(cat "$err")"
  rc=0
  (
    export PRIMARY ROOT
    # The trailing exit keeps bash from exec-ing the one command, which would
    # replace the fake harness and leave the caller outside any harness.
    # shellcheck disable=SC2016 # The fake harness shell expands these.
    exec "$fakebin/claude" -c 'FM_HOME="$PRIMARY" "$ROOT/bin/fm-order.sh" handing-off; exit $?'
  ) || rc=$?
  [ "$rc" -eq 1 ] || fail "a session that wrote no handoff is not handing off (rc=$rc)"

  : > "$go"
  rc=0
  wait "$a_pid" || rc=$?
  [ "$rc" -eq 2 ] || fail "the session that wrote the handoff must still have its stop gated for the newer order (rc=$rc)"
  assert_contains "$(cat "$TMP_ROOT/two-owner.err")" "$order_id" "the writer's block names the newer order"
  rm -rf "$PRIMARY/data/orders" "$doc" "$PRIMARY/state/.order-handoff" "$PRIMARY/config/handoff-trigger" "$ready" "$go"
  pass "a handoff record gates only the session that wrote it, never another session's stop in the same home"
}

# outside_harness_order <output-file> <fm-order.sh args...>: run fm-order.sh in
# a detached process and print its exit status. The process waits until its
# parent has exited, so it is reparented away from the test runner and has no
# harness in its ancestry, even when a real harness runs this suite. It reports
# status 99 if the ancestry walk still finds a harness.
outside_harness_order() {
  local out=$1 rc_file n=0
  shift
  rc_file="$out.rc"
  rm -f "$rc_file" "$rc_file.tmp"
  # shellcheck disable=SC2016 # The detached shell expands these.
  ( bash -c '
      out=$1 rc_file=$2 root=$3 home=$4
      shift 4
      n=0
      while [ "$(ps -o ppid= -p "$$" | tr -d " ")" = "$PPID" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
      . "$root/bin/fm-session-lock-lib.sh"
      rc=0
      if fm_harness_ancestry_pids >"$out" 2>/dev/null; then
        rc=99
      else
        FM_HOME="$home" "$root/bin/fm-order.sh" "$@" >"$out" 2>&1 || rc=$?
      fi
      printf "%s\n" "$rc" >"$rc_file.tmp"
      mv "$rc_file.tmp" "$rc_file"
    ' _ "$out" "$rc_file" "$ROOT" "$PRIMARY" "$@" </dev/null >/dev/null 2>&1 & )
  while [ ! -e "$rc_file" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done
  [ -e "$rc_file" ] || fail "the detached caller outside any harness never finished"
  cat "$rc_file"
}

# The captain session records a handoff, then a caller outside any harness
# (a restarting leash or sender, run as a detached process) checks the gate: it
# reads the captain's record. A second fake harness session still treats the
# record as absent, so its stop stays ordinary.
test_a_caller_outside_any_harness_reads_the_captains_handoff() {
  local fakebin doc ready go a_pid rc err out newer
  reset_lab
  rm -rf "$PRIMARY/data/orders"
  fakebin="$TMP_ROOT/fake-harness"
  mkdir -p "$fakebin"
  ln -sf /bin/bash "$fakebin/claude"
  printf 'percent-left=0\n' > "$PRIMARY/config/handoff-trigger"
  transcript "$TMP_ROOT/t-out" 10000
  doc="$PRIMARY/data/outside-handoff.md"
  ready="$TMP_ROOT/out.ready"
  go="$TMP_ROOT/out.go"
  out="$TMP_ROOT/out.gate"
  rm -f "$ready" "$go"
  printf '# Handoff\n' > "$doc"
  FM_HOME="$PRIMARY" "$ROOT/bin/fm-order.sh" send --from test "order in the handoff" >/dev/null \
    || fail "could not send the order fixture"
  (
    export PRIMARY ROOT doc ready go
    # shellcheck disable=SC2016 # The fake harness shell expands these.
    exec "$fakebin/claude" -c '
      FM_HOME="$PRIMARY" "$ROOT/bin/fm-order.sh" handoff --doc "$doc" >/dev/null || exit 9
      : > "$ready"
      n=0
      while [ ! -e "$go" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done'
  ) &
  a_pid=$!
  n=0
  while [ ! -e "$ready" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done
  [ -e "$ready" ] || { kill "$a_pid" 2>/dev/null; fail "the captain session never recorded its handoff"; }
  [ -n "$(sed -n 's/^owner=//p' "$PRIMARY/state/.order-handoff")" ] \
    || fail "the record written in a harness session must name its owner"

  rc=$(outside_harness_order "$out" gate)
  assert_equals 0 "$rc" "a caller outside any harness clears the gate when the captain's handoff lists every order: $(cat "$out")"
  assert_contains "$(cat "$out")" "gate: clear (1 open order(s)" "the outside caller gets the clear verdict"

  sleep 1
  FM_HOME="$PRIMARY" "$ROOT/bin/fm-order.sh" send --from test "order after the handoff" >/dev/null \
    || fail "could not send the second order fixture"
  newer=$(find "$PRIMARY/data/orders/pending" -name '*.order' | sed 's#.*/##; s/\.order$//' | sort | tail -n 1)
  rc=$(outside_harness_order "$out" gate)
  assert_equals 3 "$rc" "a newer order missing from the captain's handoff blocks the outside caller"
  assert_contains "$(cat "$out")" "$newer" "the outside caller's block names the newer order"
  assert_contains "$(cat "$out")" "does not list" "the outside caller reads the captain's recorded handoff"

  rc=0
  (
    export PRIMARY ROOT
    # The trailing exit keeps bash from exec-ing the one command, which would
    # replace the fake harness and leave the caller outside any harness.
    # shellcheck disable=SC2016 # The fake harness shell expands these.
    exec "$fakebin/claude" -c 'FM_HOME="$PRIMARY" "$ROOT/bin/fm-order.sh" handing-off; exit $?'
  ) || rc=$?
  assert_equals 1 "$rc" "a second harness session is not handing off"
  err="$TMP_ROOT/out-other.err"
  rc=0
  (
    export HOOK CLAUDE_HOME PRIMARY TMP_ROOT
    export -f run_hook
    # shellcheck disable=SC2016 # The fake harness shell expands these.
    exec "$fakebin/claude" -c 'run_hook "$PRIMARY" s-out-other "$TMP_ROOT/t-out" Stop >/dev/null'
  ) 2>"$err" || rc=$?
  assert_equals 0 "$rc" "a second harness session's ordinary stop stays ungated: $(cat "$err")"

  : > "$go"
  wait "$a_pid" || true
  rm -rf "$PRIMARY/data/orders" "$doc" "$PRIMARY/state/.order-handoff" "$PRIMARY/config/handoff-trigger" "$ready" "$go"
  pass "a caller outside any harness reads the captain's handoff, and a second harness session does not"
}

test_handoff_gates_the_stop_until_a_recorded_successor_is_alive() {
  local rc err out succ doc launch
  reset_lab
  launch="$PRIMARY/state/.handoff-successor"
  doc="$TMP_ROOT/handoff-succ.md"
  rm -rf "$PRIMARY/data/orders" "$PRIMARY/state/.order-handoff" "$PRIMARY/state/.watchdog-restart-request" "$launch"
  printf '# Handoff\n' > "$doc"
  printf 'compact-at-tokens=100000\nfresh-start-after=0\n' > "$PRIMARY/config/handoff-trigger"
  transcript "$TMP_ROOT/t-succ" 90000
  # A launch record from an earlier episode must not satisfy this firing.
  sleep 60 &
  succ=$!
  printf 'pid=%s\nhandoff=%s\n' "$succ" "$doc" > "$launch"
  sleep 1
  out=$(run_hook "$PRIMARY" s-succ "$TMP_ROOT/t-succ")
  expect_fire "$out" PostToolUse "successor instruction firing"
  expect_mode "$out" handoff "fresh-start-after=0 hands off every cycle"
  printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("bin/fm-handoff-launch.sh") and contains("state/.handoff-successor") and contains("bin/fm-session-start.sh") and (contains("timeout=600000") | not) and contains("run_in_background=true")' >/dev/null \
    || fail "the instruction must say to launch the successor with the owned launcher and record it: $out"
  err="$TMP_ROOT/succ.err"
  rc=0
  run_hook "$PRIMARY" s-succ "$TMP_ROOT/t-succ" Stop >/dev/null 2>"$err" || rc=$?
  [ "$rc" -eq 2 ] || fail "a launch record older than the firing must not clear the stop (rc=$rc)"
  assert_contains "$(cat "$err")" "bin/fm-handoff-launch.sh" "the block tells a primary to launch its successor with the owned launcher"
  rc=0
  run_hook "$PRIMARY" s-succ "$TMP_ROOT/t-succ" Stop '. + {stop_hook_active: true}' >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "a stop already continued by this hook must not be blocked again (rc=$rc)"
  # A restart request alone launches nobody, so it does not clear the stop.
  sleep 1
  : > "$PRIMARY/state/.watchdog-restart-request"
  printf 'mode=act\nrestart=on\nrestart-command=claude\n' > "$PRIMARY/config/watchdog"
  rc=0
  run_hook "$PRIMARY" s-succ "$TMP_ROOT/t-succ" Stop >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "a restart request with no recorded successor must not clear the stop (rc=$rc)"
  rm -f "$PRIMARY/config/watchdog" "$PRIMARY/state/.watchdog-restart-request"
  # A fresh record naming a live process without an ack and lock never clears.
  printf 'pid=%s\nhandoff=%s\n' "$succ" "$doc" > "$launch"
  rc=0
  run_hook "$PRIMARY" s-succ "$TMP_ROOT/t-succ" Stop >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "a live pid without a verified ack must keep the stop blocked (rc=$rc)"
  # A fresh record whose successor has died keeps the stop blocked.
  kill "$succ" 2>/dev/null; wait "$succ" 2>/dev/null
  printf 'pid=%s\nhandoff=%s\n' "$succ" "$doc" > "$launch"
  rc=0
  run_hook "$PRIMARY" s-succ "$TMP_ROOT/t-succ" Stop >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "a recorded successor that is dead must keep the stop blocked (rc=$rc)"
  rm -f "$launch" "$doc"
  pass "a firing rejects stale, dead, request-only and unacknowledged live successor records"
}

test_secondmate_handoff_escalates_to_its_parent() {
  local rc out launch
  reset_lab
  launch="$PRIMARY/state/.handoff-successor"
  rm -rf "$PRIMARY/data/orders" "$PRIMARY/state/.order-handoff" "$launch"
  printf 'sm-test\n' > "$PRIMARY/.fm-secondmate-home"
  printf 'compact-at-tokens=100000\nfresh-start-after=0\n' > "$PRIMARY/config/handoff-trigger"
  transcript "$TMP_ROOT/t-sm" 90000
  out=$(run_hook "$PRIMARY" s-sm "$TMP_ROOT/t-sm")
  expect_fire "$out" PostToolUse "second-mate firing"
  printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("never launch your own successor") and contains("parent channel") and (contains("bin/fm-handoff-launch.sh") | not)' >/dev/null \
    || fail "a second mate's instruction must escalate to its parent and not self-launch: $out"
  rc=0
  run_hook "$PRIMARY" s-sm "$TMP_ROOT/t-sm" Stop >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "a second mate's stop with no launch record must not be gated (rc=$rc)"
  rm -f "$launch" "$PRIMARY/.fm-secondmate-home"
  pass "a second mate's handoff escalates to its parent once and its stop is never successor-gated (133, 116)"
}

# marker_mode <session> <boundaries>: the mode= word of that cycle's marker.
marker_mode() {
  sed -n 's/.* mode=\([a-z]*\).*/\1/p' "$PRIMARY/state/.handoff-trigger.$1.$2" 2>/dev/null
}

# record_reset: the reset= word the hook published in state/compact-point.
record_reset() {
  sed -n 's/.* reset=\([a-z]*\).*$/\1/p' "$PRIMARY/state/compact-point" 2>/dev/null
}

stop_rc() {  # <session> <transcript> [extra-payload-jq]
  local rc=0
  run_hook "$PRIMARY" "$1" "$2" Stop "${3:-.}" >/dev/null 2>"$TMP_ROOT/stop-rc.err" || rc=$?
  printf '%s\n' "$rc"
}

# Compaction-first: with the defaults, the trigger is a capture step that has
# the session file its chat-only open work into durable records and lets
# auto-compaction run. It never asks for a successor and never gates a stop.
test_capture_is_the_default_before_the_drift_cap() {
  local out t="$TMP_ROOT/t-capture"
  reset_lab
  rm -rf "$PRIMARY/data/orders" "$PRIMARY/state/.order-handoff" "$PRIMARY/state/.handoff-successor"
  printf 'compact-at-tokens=100000\n' > "$PRIMARY/config/handoff-trigger"
  transcript "$t" 90000
  out=$(run_hook "$PRIMARY" s-capture "$t")
  expect_fire "$out" PostToolUse "capture firing"
  expect_mode "$out" capture "the default firing"
  assert_equals capture "$(marker_mode s-capture 0)" "the marker records the capture mode"
  assert_equals compaction "$(record_reset)" "the published point names compaction as this cycle's reset"
  printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext
      | contains("bin/fm-dispatch-log.sh")
        and contains("bin/fm-captain-hold.sh") and contains("bin/fm-ledger.sh intake")
        and contains("bin/fm-crew-state.sh") and contains("re-entry card")
        and contains("do not hand off") and contains("Compactions so far: 0")
        and contains("planned fresh start comes after 4")' >/dev/null \
    || fail "the capture instruction must name the durable records, the re-entry card, the re-check, and the drift cap: $out"
  assert_equals 0 "$(stop_rc s-capture "$t")" "a capture firing never gates the stop"
  expect_silent "$(run_hook "$PRIMARY" s-capture "$t")" "the capture fires once per cycle"
  boundary "$t"
  append_usage "$t" 90000
  out=$(run_hook "$PRIMARY" s-capture "$t")
  expect_mode "$out" capture "the next cycle below the drift cap"
  assert_contains "$out" "Compactions so far: 1" "the capture names the compactions so far"
  printf 'compact-at-tokens=100000\npercent-left=0\n' > "$PRIMARY/config/handoff-trigger"
  expect_silent "$(run_hook "$PRIMARY" s-capture-off "$t")" "percent-left=0 never fires"
  assert_contains "$(cat "$PRIMARY/state/compact-point")" "session=s-capture-off compact_at=100000" "percent-left=0 still publishes the point"
  assert_equals "" "$(record_reset)" "percent-left=0 publishes no reset, so the watchdog keeps its low-context restart"
  pass "the default firing is a capture step: durable records, no successor, an ungated stop"
}

# A capture firing that Claude cancels while the hook builds its output, as it
# cancelled a UserPromptSubmit run at its 10 second timeout on a loaded host,
# must not spend the cycle's one firing: the hook claims the cycle only once
# the whole instruction is built, so the next run still delivers it.
test_a_capture_cancelled_while_building_its_output_fires_on_the_next_run() {
  local t="$TMP_ROOT/t-cut" slow="$TMP_ROOT/slowjq" started="$TMP_ROOT/slow-jq.started" out hook
  reset_lab
  rm -rf "$slow" "$started" "$TMP_ROOT/cut.out" "$PRIMARY/data/orders" "$PRIMARY/state/.handoff-successor"
  mkdir -p "$slow"
  # shellcheck disable=SC2016 # The wrapper expands these.
  printf '#!/usr/bin/env bash\ncase " $* " in *hookSpecificOutput*) : > %q; sleep 60 ;; esac\nexec %q "$@"\n' \
    "$started" "$(command -v jq)" > "$slow/jq"
  chmod +x "$slow/jq"
  printf 'compact-at-tokens=100000\n' > "$PRIMARY/config/handoff-trigger"
  transcript "$t" 90000
  set -m
  HOOK_ENV="PATH=$slow:$PATH" run_hook "$PRIMARY" s-cut "$t" UserPromptSubmit > "$TMP_ROOT/cut.out" 2>/dev/null &
  hook=$!
  set +m
  wait_for_file "$started" 300 || fail "the drill never reached the step that writes the hook's output"
  kill -KILL -- "-$hook" 2>/dev/null
  wait "$hook" 2>/dev/null
  expect_silent "$(cat "$TMP_ROOT/cut.out")" "the run cancelled while it built its output"
  out=$(run_hook "$PRIMARY" s-cut "$t")
  expect_fire "$out" PostToolUse "the next run after a cancelled capture firing"
  expect_mode "$out" capture "the delivered firing"
  expect_silent "$(run_hook "$PRIMARY" s-cut "$t")" "the delivered capture still fires once per cycle"
  rm -rf "$slow" "$started" "$TMP_ROOT/cut.out"
  pass "a capture firing cancelled while it builds its output is delivered by the next run"
}

# The drift cap: after fresh-start-after compactions on the same harness the
# next firing is a planned fresh start (a full handoff), and its stop is gated.
test_fresh_start_after_n_compactions() {
  local out t="$TMP_ROOT/t-drift"
  reset_lab
  rm -rf "$PRIMARY/data/orders" "$PRIMARY/state/.order-handoff" "$PRIMARY/state/.handoff-successor"
  printf 'compact-at-tokens=100000\nfresh-start-after=2\nfresh-start-context-tokens=0\n' > "$PRIMARY/config/handoff-trigger"
  transcript "$t" 90000
  expect_mode "$(run_hook "$PRIMARY" s-drift "$t")" capture "no compaction yet"
  boundary "$t"
  append_usage "$t" 90000
  expect_mode "$(run_hook "$PRIMARY" s-drift "$t")" capture "one compaction, below the cap of 2"
  assert_equals compaction "$(record_reset)" "below the cap the reset is compaction"
  boundary "$t"
  append_usage "$t" 30000
  expect_silent "$(run_hook "$PRIMARY" s-drift "$t")" "the cap cycle above the threshold"
  assert_equals handoff "$(record_reset)" "at the cap the reset is a handoff, published before the firing"
  append_usage "$t" 90000
  out=$(run_hook "$PRIMARY" s-drift "$t")
  expect_fire "$out" PostToolUse "the cap cycle at the threshold"
  expect_mode "$out" handoff "two compactions on the same harness"
  assert_equals handoff "$(marker_mode s-drift 2)" "the marker records the handoff mode"
  printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext
      | contains("after 2 compactions") and contains("bin/fm-handoff-launch.sh")
        and contains("never an addendum") and contains("bin/fm-ledger.sh handoff")' >/dev/null \
    || fail "the fresh-start instruction must give its reason and the hardened handoff steps: $out"
  assert_equals 2 "$(stop_rc s-drift "$t")" "a planned fresh start gates the stop until a successor is live"
  assert_contains "$(cat "$TMP_ROOT/stop-rc.err")" "state/.handoff-successor" "the block names the launch record"

  printf 'compact-at-tokens=100000\nfresh-start-after=abc\n' > "$PRIMARY/config/handoff-trigger"
  t="$TMP_ROOT/t-drift-bad"
  transcript "$t" 50000
  boundary "$t"; boundary "$t"; boundary "$t"
  append_usage "$t" 90000
  expect_mode "$(run_hook "$PRIMARY" s-drift-bad "$t")" capture "an unusable fresh-start-after keeps the default 4"
  boundary "$t"
  append_usage "$t" 90000
  expect_mode "$(run_hook "$PRIMARY" s-drift-bad "$t")" handoff "the default cap is 4 compactions"
  pass "after fresh-start-after compactions the firing is a planned fresh start whose stop is gated"
}

# A compaction that leaves a heavy context shortens every later cycle, so a
# first post-compaction reading at or above fresh-start-context-tokens makes the
# cycle's firing a planned fresh start before the count cap.
test_fresh_start_on_high_context_after_compaction() {
  local out t="$TMP_ROOT/t-heavy" t2="$TMP_ROOT/t-light"
  reset_lab
  printf 'compact-at-tokens=100000\nfresh-start-context-tokens=60000\n' > "$PRIMARY/config/handoff-trigger"
  transcript "$t" 50000
  boundary "$t"
  append_usage "$t" 65000
  expect_silent "$(run_hook "$PRIMARY" s-heavy "$t")" "a heavy post-compaction context above the threshold"
  assert_equals handoff "$(record_reset)" "a heavy post-compaction context publishes a handoff reset"
  append_usage "$t" 90000
  out=$(run_hook "$PRIMARY" s-heavy "$t")
  expect_mode "$out" handoff "a heavy post-compaction context"
  assert_contains "$out" "65000 tokens right after compaction" "the fresh start names the heavy reading"
  transcript "$t2" 50000
  boundary "$t2"
  append_usage "$t2" 40000
  append_usage "$t2" 90000
  expect_mode "$(run_hook "$PRIMARY" s-light "$t2")" capture "a light post-compaction context"
  printf 'compact-at-tokens=100000\nfresh-start-context-tokens=0\n' > "$PRIMARY/config/handoff-trigger"
  expect_mode "$(run_hook "$PRIMARY" s-heavy-off "$t")" capture "fresh-start-context-tokens=0 turns the reading off"
  pass "a heavy first reading after compaction makes the firing a planned fresh start; 0 turns that off"
}

# A marker from before compaction-first (no mode= word) was a handoff firing,
# so it gates the stop like a fresh start.
test_a_legacy_marker_gates_as_a_handoff() {
  local t="$TMP_ROOT/t-legacy"
  reset_lab
  rm -rf "$PRIMARY/data/orders" "$PRIMARY/state/.order-handoff" "$PRIMARY/state/.handoff-successor"
  printf 'compact-at-tokens=100000\n' > "$PRIMARY/config/handoff-trigger"
  transcript "$t" 90000
  printf '%s tokens=90000 compact_at=100000\n' "$(date +%s)" > "$PRIMARY/state/.handoff-trigger.s-legacy.0"
  assert_equals 2 "$(stop_rc s-legacy "$t")" "a marker without a mode is a handoff firing"
  pass "a marker from before compaction-first gates the stop as a handoff"
}

# A planned fresh start whose launch failed while this session kept the lock
# releases the cycle's whole Stop gate, open orders included, and publishes
# compaction as the reset; a record that is older than the firing or names
# another lock holder releases nothing.
test_a_failed_fresh_start_launch_releases_the_stop() {
  local t="$TMP_ROOT/t-launch-failed" record="$PRIMARY/state/.handoff-launch-failed" holder at out
  reset_lab
  rm -rf "$PRIMARY/data/orders" "$PRIMARY/state/.order-handoff" "$PRIMARY/state/.handoff-successor" "$record"
  printf 'compact-at-tokens=100000\nfresh-start-after=0\n' > "$PRIMARY/config/handoff-trigger"
  transcript "$t" 90000
  sleep 60 &
  holder=$!
  printf '%s\n' "$holder" > "$PRIMARY/state/.lock"
  FM_HOME="$PRIMARY" "$ROOT/bin/fm-order.sh" send --from test "order during a failed launch" >/dev/null \
    || fail "could not send the order fixture"
  out=$(run_hook "$PRIMARY" s-lf "$t")
  expect_mode "$out" handoff "the firing plans a fresh start"
  assert_equals handoff "$(record_reset)" "before any launch fails the cycle publishes a handoff reset"
  assert_equals 2 "$(stop_rc s-lf "$t")" "the fresh-start gate blocks before any launch fails"
  at=$(sed -n '1s/^\([0-9][0-9]*\) .*/\1/p' "$PRIMARY/state/.handoff-trigger.s-lf.0")

  printf 'at=%s pid=%s nonce=none attempt=1 reason=error\n' "$((at - 1))" "$holder" > "$record"
  assert_equals 2 "$(stop_rc s-lf "$t")" "a failure recorded before this firing does not release it"
  printf 'at=%s pid=%s nonce=none attempt=1 reason=error\n' "$at" "$((holder + 1))" > "$record"
  assert_equals 2 "$(stop_rc s-lf "$t")" "a failure naming another lock holder does not release the gate"
  printf 'at=%s pid=%s nonce=abc attempt=7 reason=error\n' "$at" "$holder" > "$record"
  assert_equals 2 "$(stop_rc s-lf "$t")" "a malformed failure record does not release the gate"
  ln -sf "$TMP_ROOT/absent" "$record.link"
  rm -f "$record"
  mv "$record.link" "$record"
  assert_equals 2 "$(stop_rc s-lf "$t")" "a symlinked failure record does not release the gate"
  rm -f "$record"

  printf 'at=%s pid=%s nonce=%s attempt=2 reason=deadline\n' "$at" "$holder" "$(printf '%032d' 0)" > "$record"
  assert_equals 0 "$(stop_rc s-lf "$t")" "a failed launch that left this session holding the lock releases the gate"
  run_hook "$PRIMARY" s-lf "$t" >/dev/null
  assert_equals compaction "$(record_reset)" "after a failed launch the cycle publishes a compaction reset"
  assert_contains "$(lib_reset s-lf)" compaction "the watchdog's reader also sees auto-compaction"

  # A launch that fails after this run chose its reset lands before the
  # publication with an older epoch. The published snapshot itself, read
  # before any later run, must already read as auto-compaction.
  rm -f "$record"
  mkdir -p "$TMP_ROOT/race-bin"
  cat > "$TMP_ROOT/race-bin/mktemp" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *compact-point.*) [ -e "$record" ] || printf 'at=%s pid=%s nonce=none attempt=1 reason=error\\n' "$at" "$holder" > "$record" ;;
esac
exec "$(command -v mktemp)" "\$@"
EOF
  chmod +x "$TMP_ROOT/race-bin/mktemp"
  printf 'session=s-lf compact_at=100000 at=%s reset=handoff\n' "$((at + 5))" > "$PRIMARY/state/compact-point"
  # The publication must land in a later second than the recorded failure.
  while [ "$(date +%s)" -le "$at" ]; do sleep 0.2; done
  HOOK_ENV="PATH=$TMP_ROOT/race-bin:$PATH" run_hook "$PRIMARY" s-lf "$t" >/dev/null
  [ -e "$record" ] || fail "the race seam must record the failure during the publication"
  assert_equals handoff "$(record_reset)" "the run chose its handoff reset before the failure landed"
  assert_contains "$(cat "$PRIMARY/state/compact-point")" " cycle=$at" "a fired handoff reset names its cycle by the marker epoch"
  [ "$(sed -n 's/.* at=\([0-9]*\) reset=.*/\1/p' "$PRIMARY/state/compact-point")" -gt "$at" ] \
    || fail "the publication must postdate the recorded failure for this race"
  assert_contains "$(lib_reset s-lf)" compaction "that very snapshot reads as auto-compaction, bound to its cycle"
  run_hook "$PRIMARY" s-lf "$t" >/dev/null
  assert_equals compaction "$(record_reset)" "the next run publishes the compaction reset itself"

  # A later launch removes the record, and the gate applies again.
  rm -f "$record"
  assert_equals 2 "$(stop_rc s-lf "$t")" "without the record the gate blocks again"
  run_hook "$PRIMARY" s-lf "$t" >/dev/null
  assert_equals handoff "$(record_reset)" "without the record the cycle publishes a handoff reset again"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  rm -rf "$PRIMARY/data/orders" "$PRIMARY/state/.lock" "$PRIMARY/state/compact-point"
  pass "a failed fresh-start launch releases the cycle's Stop gate and falls back to auto-compaction"
}

# lib_reset <session>: the reset the watchdog's context reader names for it.
lib_reset() {
  bash -c '. "$1/bin/fm-context-reading-lib.sh"; fm_context_reset_for_session "$2" "$3"' _ "$ROOT" "$PRIMARY" "$1"
}

wait_for_file() {  # <path> <tenths>
  local n=0
  while [ ! -e "$1" ] && [ "$n" -lt "$2" ]; do sleep 0.1; n=$((n + 1)); done
  [ -e "$1" ]
}

test_live_guard_config_and_api_failure() {
  local fakebin=$TMP_ROOT/guard-bin config=$TMP_ROOT/guard-config
  local recorded=$TMP_ROOT/guard-recorded out rc
  mkdir -p "$fakebin" "$config" "$TMP_ROOT/other/guard-config"
  cat > "$fakebin/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'fixture-cli\n'
  exit 0
fi
printf '%s\n' "${CLAUDE_CONFIG_DIR:-unset}" > "$FM_GUARD_FIXTURE_CONFIG"
printf '{"is_error":true,"api_error_status":429,"result":"fixture request refused"}\n'
exit 7
EOF
  chmod +x "$fakebin/claude"
  rc=0
  out=$(env -u FM_HANDOFF_TRIGGER_LIVE_CLAUDE_CONFIG_DIR PATH="$fakebin:$PATH" \
    FM_HANDOFF_TRIGGER_LIVE_E2E=1 FM_GUARD_FIXTURE_CONFIG="$recorded" \
    CLAUDE_CONFIG_DIR="$TMP_ROOT/inherited-config" \
    bash "$ROOT/tests/fm-handoff-trigger-live-e2e.test.sh" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a failed fixture request passed the live guard"
  assert_contains "$out" 'api_error_status=429: fixture request refused' "JSON API failure diagnostic"
  assert_equals unset "$(cat "$recorded")" "the live guard inherited an unrelated account"

  rc=0
  out=$(env PATH="$fakebin:$PATH" FM_HANDOFF_TRIGGER_LIVE_E2E=1 \
    FM_GUARD_FIXTURE_CONFIG="$recorded" CLAUDE_CONFIG_DIR="$TMP_ROOT/inherited-config" \
    FM_HANDOFF_TRIGGER_LIVE_CLAUDE_CONFIG_DIR="$config" \
    bash "$ROOT/tests/fm-handoff-trigger-live-e2e.test.sh" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a failed fixture request passed with an explicit config"
  assert_contains "$out" 'api_error_status=429: fixture request refused' "explicit-config API failure diagnostic"
  assert_equals "$config" "$(cat "$recorded")" "the explicit lab account was not used"

  rc=0
  out=$( (cd "$TMP_ROOT" && env PATH="$fakebin:$PATH" FM_HANDOFF_TRIGGER_LIVE_E2E=1 \
    FM_GUARD_FIXTURE_CONFIG="$recorded" FM_HANDOFF_TRIGGER_LIVE_CLAUDE_CONFIG_DIR=guard-config \
    CDPATH="$TMP_ROOT/other" \
    bash "$ROOT/tests/fm-handoff-trigger-live-e2e.test.sh") 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a failed fixture request passed with a relative config"
  assert_contains "$out" 'api_error_status=429: fixture request refused' "relative-config API failure diagnostic"
  assert_equals "$config" "$(cat "$recorded")" "the relative lab config changed meaning after entering the lab"
  pass "live-guard fixture isolates the account and reports the JSON API failure"
}

test_live_guard_config_and_api_failure
test_handoff_gates_the_stop_until_a_recorded_successor_is_alive
test_secondmate_handoff_escalates_to_its_parent
test_threshold_default_15
test_capture_is_the_default_before_the_drift_cap
test_a_capture_cancelled_while_building_its_output_fires_on_the_next_run
test_fresh_start_after_n_compactions
test_fresh_start_on_high_context_after_compaction
test_a_legacy_marker_gates_as_a_handoff
test_a_failed_fresh_start_launch_releases_the_stop
test_threshold_configurable
test_fires_once_per_context_cycle
test_rearms_after_compaction
test_fires_once_under_concurrency
test_compact_point_from_claude_settings
test_window_precedence_matches_claude
test_window_values_claude_rejects_count_as_unset
test_window_env_override
test_unresolved_compact_point_is_silent
test_scope
test_names_open_captain_orders_and_gates_the_stop
test_a_recorded_handoff_gates_the_stop_without_the_trigger
test_another_sessions_handoff_never_gates_this_stop
test_a_caller_outside_any_harness_reads_the_captains_handoff
