#!/usr/bin/env bash
# Behavior tests for the shared context reading (bin/fm-context-reading-lib.sh):
# the one footer parser every reader uses, the context window a reader outside
# the session takes from the early handoff trigger's state/compact-point record
# or the compact-at pin, the derived percentage, the owner choice and the
# disagreement flag. It also proves the two writers and readers end to end: the
# handoff trigger publishes the record, and the watchdog's low-context restart
# decision follows the owning reading and names both values. The watchdog cases
# use a disposable home whose pane is a stub file served by a PATH fake tmux.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-context-reading)
LOCK_PIDS=''
cleanup_context_reading_tests() {
  local p
  for p in $LOCK_PIDS; do kill "$p" 2>/dev/null || true; done
  fm_test_cleanup
}
trap cleanup_context_reading_tests EXIT

BASE=$(date +%s)
CASE_N=0

# lib <function> <args>...: run one library function in a fresh bash.
lib() {
  bash -c '. "$1/bin/fm-context-footer-lib.sh"; . "$1/bin/fm-warm-compact-lib.sh"; . "$1/bin/fm-context-reading-lib.sh"; shift; "$@"' _ "$ROOT" "$@"
}

# usage_transcript <file> <context-tokens> [session-id]: one assistant turn
# whose usage adds up to <context-tokens>.
usage_transcript() {
  local file=$1 tokens=$2 iso
  iso=$(date -u -r "$BASE" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$BASE" +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$(dirname "$file")"
  {
    printf '{"type":"user","message":{"content":"hi"}}\n'
    jq -nc --argjson t "$tokens" --arg ts "$iso" '{type: "assistant", timestamp: $ts, message: {model: "claude-test-model",
      content: [{type: "text", text: "Working."}],
      usage: {input_tokens: 2, cache_read_input_tokens: ($t - 1002), cache_creation_input_tokens: 1000, output_tokens: 50}}}'
  } > "$file"
}

new_home() {
  CASE_N=$((CASE_N + 1))
  H="$TMP_ROOT/home$CASE_N"
  mkdir -p "$H/state" "$H/config"
}

test_shared_footer_parser_reads_the_pane_footer() {
  assert_equals 42 "$(printf 'work\n  42%% until auto-compact\n' | bash -c '. "$1/bin/fm-context-footer-lib.sh"; fm_context_footer_percent_from_text' _ "$ROOT")" "auto-compact footer"
  pass "the shared footer parser reads the auto-compact footer"
}

test_window_comes_from_the_matching_record_then_the_pin() {
  new_home
  assert_equals "" "$(lib fm_context_window_for_session "$H" s-1)" "no record and no pin give no window"
  printf 'compact-at-tokens=150000\n' > "$H/config/handoff-trigger"
  assert_equals 150000 "$(lib fm_context_window_for_session "$H" s-1)" "the pin is the fallback with no record"
  printf 'session=s-1 compact_at=187000 at=%s\n' "$BASE" > "$H/state/compact-point"
  assert_equals 187000 "$(lib fm_context_window_for_session "$H" s-1)" "a record naming the session wins over the pin"
  assert_equals 150000 "$(lib fm_context_window_for_session "$H" s-2)" "a record naming another session falls back to the pin"
  rm -f "$H/config/handoff-trigger"
  assert_equals "" "$(lib fm_context_window_for_session "$H" s-2)" "another session's record and no pin give no window"
  assert_equals "" "$(lib fm_context_window_for_session "$H" '')" "an empty session id never matches a record"
  printf 'compact-at-tokens=0150000\n' > "$H/config/handoff-trigger"
  assert_equals "" "$(lib fm_context_window_for_session "$H" s-2)" "an unusable pin counts as unset"
  pass "the window comes from the record for the session, else the compact-at pin, else nothing"
}

test_derived_percent_is_left_of_the_window() {
  new_home
  usage_transcript "$H/t.jsonl" 93000
  assert_equals 7 "$(lib fm_context_derived_percent "$H/t.jsonl" 100000)" "93000 of 100000 leaves 7"
  usage_transcript "$H/t.jsonl" 1
  assert_equals 67 "$(lib fm_context_derived_percent "$H/t.jsonl" 3)" "100 - used*100/window, integer"
  usage_transcript "$H/t.jsonl" 120000
  assert_equals 0 "$(lib fm_context_derived_percent "$H/t.jsonl" 100000)" "past the window never reads below 0"
  assert_equals "" "$(lib fm_context_derived_percent "$H/t.jsonl" '')" "no window gives no reading"
  assert_equals "" "$(lib fm_context_derived_percent "$H/missing.jsonl" 100000)" "no transcript gives no reading"
  printf '{"type":"user","message":{"content":"hi"}}\n' > "$H/t.jsonl"
  assert_equals "" "$(lib fm_context_derived_percent "$H/t.jsonl" 100000)" "a transcript with no usage gives no reading"
  pass "the derived percentage is the integer share of the window left"
}

test_reading_names_the_owner_and_both_values() {
  new_home
  usage_transcript "$H/t.jsonl" 93000
  printf 'work\n  30%% until auto-compact\n' > "$H/pane.txt"
  printf 'session=s-1 compact_at=100000 at=%s\n' "$BASE" > "$H/state/compact-point"
  assert_equals "footer=30 derived=7 owner=derived disagreement=-" \
    "$(lib fm_context_reading "$H" s-1 "$H/t.jsonl" "$H/pane.txt")" "a derived reading owns over a higher pane"
  printf 'disagreement-points=10\n' > "$H/config/context-reading"
  assert_equals "footer=30 derived=7 owner=derived disagreement=1" \
    "$(lib fm_context_reading "$H" s-1 "$H/t.jsonl" "$H/pane.txt")" "a gap over the bound is a disagreement"
  printf 'disagreement-points=23\n' > "$H/config/context-reading"
  assert_equals "footer=30 derived=7 owner=derived disagreement=0" \
    "$(lib fm_context_reading "$H" s-1 "$H/t.jsonl" "$H/pane.txt")" "a gap at the bound is no disagreement"
  assert_equals "footer=30 derived=unknown owner=footer disagreement=0" \
    "$(lib fm_context_reading "$H" s-2 "$H/t.jsonl" "$H/pane.txt")" "another session's record leaves only the footer"
  rm -f "$H/config/context-reading"
  assert_equals "footer=30 derived=7 owner=derived disagreement=-" \
    "$(LC_ALL=en_US.UTF-8 lib fm_context_reading "$H" s-1 "$H/t.jsonl" <(printf 'w\377rk\n  30%% until auto-compact\n'))" \
    "a piped pane with a stray byte still reads, whatever the locale"
  assert_equals "footer=unknown derived=7 owner=derived disagreement=-" \
    "$(lib fm_context_reading "$H" s-1 "$H/t.jsonl" "$H/missing-pane.txt")" "no pane leaves the derived reading"
  printf 'work\n> \n' > "$H/pane.txt"
  assert_equals "footer=unknown derived=unknown owner=none disagreement=-" \
    "$(lib fm_context_reading "$H" s-2 "$H/t.jsonl" "$H/pane.txt")" "neither reading gives owner none"
  assert_equals "footer=unknown derived=unknown owner=none disagreement=-" \
    "$(lib fm_context_reading "$H" s-1 '' "$H/pane.txt")" "no transcript gives no derived reading"
  pass "the reading names the footer, the derived value, the owner, and the disagreement"
}

test_handoff_trigger_publishes_the_compact_point() {
  local primary="$TMP_ROOT/primary" claude_home="$TMP_ROOT/claude-config" rec at
  mkdir -p "$primary/state" "$primary/config" "$primary/bin" "$primary/.claude" "$claude_home"
  git init -q "$primary"
  git -C "$primary" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  : > "$primary/AGENTS.md"
  usage_transcript "$TMP_ROOT/t-50" 50000
  run_trigger() {  # <session> <transcript> [event]
    jq -nc --arg s "$1" --arg t "$2" --arg e "${3:-PostToolUse}" \
      '{session_id: $s, transcript_path: $t, hook_event_name: $e, tool_name: "Bash"}' \
      | env -u CLAUDE_AUTOCOMPACT_PCT_OVERRIDE -u CLAUDE_CODE_AUTO_COMPACT_WINDOW -u FM_HOME -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE \
        FM_ROOT_OVERRIDE="$primary" CLAUDE_CONFIG_DIR="$claude_home" CLAUDE_PROJECT_DIR="$primary" \
        bash "$ROOT/bin/fm-handoff-trigger.sh"
  }
  assert_equals "" "$(run_trigger s-a "$TMP_ROOT/t-50")" "nothing resolves, so the trigger stays silent"
  [ ! -e "$primary/state/compact-point" ] || fail "no resolved point must leave no record: $(cat "$primary/state/compact-point")"
  printf '{"autoCompactWindow":250000}\n' > "$claude_home/settings.json"
  assert_equals "" "$(run_trigger s-a "$TMP_ROOT/t-50")" "50000 of 217000 is above the threshold, so the trigger stays silent"
  rec=$(cat "$primary/state/compact-point" 2>/dev/null)
  at=$(printf '%s' "$rec" | sed -n 's/^session=s-a compact_at=217000 at=\([0-9][0-9]*\)$/\1/p')
  [ -n "$at" ] || fail "the trigger must publish the point it resolved for the session, got: $rec"
  printf 'compact-at-tokens=100000\n' > "$primary/config/handoff-trigger"
  run_trigger s-b "$TMP_ROOT/t-50" >/dev/null
  assert_contains "$(cat "$primary/state/compact-point")" "session=s-b compact_at=100000 at=" "each run publishes the point it resolved, the pin included"
  rm -f "$primary/config/handoff-trigger" "$claude_home/settings.json"
  run_trigger s-b "$TMP_ROOT/t-50" >/dev/null
  [ ! -e "$primary/state/compact-point" ] || fail "a run that resolves nothing must withdraw its session's record: $(cat "$primary/state/compact-point")"
  printf 'compact-at-tokens=100000\n' > "$primary/config/handoff-trigger"
  usage_transcript "$TMP_ROOT/t-93" 93000
  run_trigger s-c "$TMP_ROOT/t-93" | jq -e '.hookSpecificOutput.additionalContext | contains("93000 of 100000 tokens")' >/dev/null \
    || fail "the in-session decision must stay unchanged"
  assert_contains "$(cat "$primary/state/compact-point")" "session=s-c compact_at=100000 at=" "the firing run publishes too"
  find "$primary/state" -maxdepth 1 -name 'compact-point.*' | grep -q . && fail "the record must be written atomically, with no temp file left"
  pass "the handoff trigger publishes the compact point it resolved, named for its session"
}

# --- the watchdog restart decision ------------------------------------------------

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
# A stub tmux: the pane read prints the case's pane file and every other call succeeds.
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  capture-pane) cat "$FM_CTX_TEST_PANE" 2>/dev/null ;;
  list-panes) printf '%%1\n' ;;
  *) exit 0 ;;
esac
SH
chmod +x "$FAKEBIN/tmux"
for tool in gh gh-axi osascript terminal-notifier say mail sendmail curl claude agy; do
  printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/$tool"
  chmod +x "$FAKEBIN/$tool"
done

# wd_home <pane-text> <context-tokens>: a disposable home with a live lock
# holder, a pane stub, and a transcript whose last request used <context-tokens>.
wd_home() {
  new_home
  SID="00000000-0000-4000-8000-0000000000$CASE_N"
  mkdir -p "$H/data" "$H/claude/projects/p"
  printf '%s\n' "$1" > "$H/pane.txt"
  ( sleep 100000 > /dev/null 2>&1 & printf '%s\n' "$!" > "$H/lockpid" )
  LOCKPID=$(cat "$H/lockpid")
  LOCK_PIDS="$LOCK_PIDS $LOCKPID"
  printf '%s\n' "$LOCKPID" > "$H/state/.lock"
  printf '%s\n' "$SID" > "$H/state/.lock-session"
  fm_touch_epoch "$((BASE - 1))" "$H/state/.lock" "$H/state/.lock-session"
  jq -n --arg s "$SID" --argjson e "$BASE" --argjson p "$LOCKPID" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:"tmux",target:"%1",present:true},session:{trusted_id:$s},writer:{anchor_pid:$p,session_id:$s}}}' \
    > "$H/state/heartbeat.json"
  printf 'mode=dry-run\nclaude-config-dirs=%s\nmodels=\nrestart=on\nrestart-command=/bin/true\n' "$H/claude" > "$H/config/watchdog"
  usage_transcript "$H/claude/projects/p/$SID.jsonl" "$2"
  fm_touch_epoch "$((BASE - 3000))" "$H/claude/projects/p/$SID.jsonl"
}

run_wd() {
  PATH="$FAKEBIN:$PATH" FM_CTX_TEST_PANE="$H/pane.txt" FM_TEST_SEAM=1 FM_WD_TEST_COMPOSER=empty \
    FM_WD_NOW="$BASE" FM_HOME="$H" bash "$ROOT/bin/fm-watchdog.sh" once >/dev/null 2>&1
}

handoff_rows() {
  awk -F'\t' '$5 == "handoff-request" && $6 == "nudge"' "$H/state/watchdog/actions.tsv" 2>/dev/null
}

test_watchdog_restart_follows_the_owning_reading() {
  wd_home $'Captain session\n> \n  30% until auto-compact' 93000
  printf 'session=%s compact_at=100000 at=%s\n' "$SID" "$BASE" > "$H/state/compact-point"
  run_wd
  assert_contains "$(handoff_rows)" "footer=30 derived=7 owner=derived" "a derived 7 with a pane at 30 asks for the handoff and names both values"

  wd_home $'Captain session\n> \n  30% until auto-compact' 92000
  printf 'session=%s compact_at=100000 at=%s\n' "$SID" "$BASE" > "$H/state/compact-point"
  run_wd
  assert_contains "$(handoff_rows)" "footer=30 derived=8 owner=derived" "a derived reading at restart-at-percent asks for the handoff"

  wd_home $'Captain session\n> \n  7% until auto-compact' 50000
  printf 'session=%s compact_at=100000 at=%s\n' "$SID" "$BASE" > "$H/state/compact-point"
  run_wd
  assert_equals "" "$(handoff_rows)" "a derived 50 decides over a pane at 7"

  wd_home $'Captain session\n> \n  7% until auto-compact' 93000
  run_wd
  assert_contains "$(handoff_rows)" "footer=7 derived=unknown owner=footer" "with no derived reading the footer decides"

  wd_home $'Captain session\n> \n  50% until auto-compact' 93000
  printf 'compact-at-tokens=100000\n' > "$H/config/handoff-trigger"
  printf 'session=another-session compact_at=900000 at=%s\n' "$BASE" > "$H/state/compact-point"
  run_wd
  assert_contains "$(handoff_rows)" "footer=50 derived=7 owner=derived" "another session's record falls back to the pin"

  wd_home $'Captain session\n> ' 93000
  printf 'session=another-session compact_at=100000 at=%s\n' "$BASE" > "$H/state/compact-point"
  run_wd
  assert_equals "" "$(handoff_rows)" "owner none never asks for a restart"

  wd_home $'Captain session\n> \n  30% until auto-compact' 93000
  printf 'session=%s compact_at=100000 at=%s\n' "$SID" "$BASE" > "$H/state/compact-point"
  printf 'disagreement-points=10\n' > "$H/config/context-reading"
  run_wd
  assert_contains "$(handoff_rows)" "footer=30 derived=7 owner=derived disagreement=1" "a disagreement acts on the derived value and names both"
  pass "the watchdog restart gate follows the owning reading and records both values"
}

fm_test_run \
  test_shared_footer_parser_reads_the_pane_footer \
  test_window_comes_from_the_matching_record_then_the_pin \
  test_derived_percent_is_left_of_the_window \
  test_reading_names_the_owner_and_both_values \
  test_handoff_trigger_publishes_the_compact_point \
  test_watchdog_restart_follows_the_owning_reading
