#!/usr/bin/env bash
# Executable adapter checks for Droid identity, launch settings, and hooks.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-agent-process-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-droid-harness)

test_droid_identity_and_control() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/identity")
  cat >"$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' /usr/local/bin/droid ;;
  *"args="*) printf '%s\n' 'droid --settings /tmp/task.json' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  out=$(CLAUDECODE=1 PATH="$fakebin:$PATH" "$ROOT/bin/fm-harness.sh")
  [ "$out" = droid ] || fail "droid ancestry must outrank an inherited launcher marker, got '$out'"
  [ "$(fm_agent_process_classify_name droid)" = agent ] || fail "droid process must be an agent"
  [ "$(fm_agent_process_classify_name droid-helper)" = other ] || fail "droid identity must be anchored"
  fm_control_harness_supports_kind droid scout || fail "droid must run scouts"
  fm_control_harness_supports_kind droid ship || fail "droid must run ships"
  fm_control_harness_supports_kind droid secondmate && fail "droid must refuse secondmates" || true
  [ "$(fm_control_interrupt_key droid)" = Escape ] || fail "droid interrupt key changed"
  [ "$(fm_control_interrupt_clear_key droid)" = C-u ] || fail "Droid interrupt must clear a queued prompt"
  [ "$(fm_control_exit_command droid)" = /exit ] || fail "droid exit command changed"
  printf ' ⠃ Thinking...  (Press ESC to stop)\n' | fm_busy_lines_match droid \
    || fail "Droid working status must acknowledge typed delivery"
  printf ' ⠃ Streaming...  (Press ESC to stop)\n' | fm_busy_lines_match droid \
    || fail "Droid streaming status must acknowledge typed delivery"
  printf 'Auto (High) · allow all commands\n' | fm_busy_lines_match droid \
    && fail "Droid idle status must not acknowledge typed delivery" || true
  pass "Droid is a crewmate/scout agent with verified control mechanics"
}

# Captured from a live tmux Droid 0.230.0 scout at idle after its first turn.
DROID_IDLE_SCREEN=' Auto (High) · allow all commands                            GPT-5.6 Luna (Low)
╭──────────────────────────────────────────────────────────────────────────────╮
│ >                                                                            │
╰──────────────────────────────────────────────────────────────────────────────╯
[⏱ 16s, context: 3%] 3 config issues — /diagnostics               MCP ✓ | TMUX ⧉
firstmate'

test_droid_composer_envelope() {
  local screen=$DROID_IDLE_SCREEN out
  out=$(fm_tmux_droid_composer_state "$screen")
  [ "$out" = empty ] || fail "Droid idle composer must be proven empty, got '$out'"
  out=$(fm_tmux_droid_composer_state "${screen/│ >           /│ > /exit     }")
  [ "$out" = pending ] || fail "Droid typed composer must stay pending, got '$out'"
  out=$(fm_tmux_droid_composer_state "$screen
unexpected modal")
  [ "$out" = unknown ] || fail "an overlay below Droid's composer must refuse input, got '$out'"
  out=$(fm_tmux_droid_composer_state "${screen%firstmate}[OMD] session:0m")
  [ "$out" = unknown ] || fail "a user statusLine below Droid's composer must refuse input, got '$out'"
  out=$(fm_tmux_droid_composer_state "${screen/\[⏱ 16s, context: 3%\] /}")
  [ "$out" = unknown ] || fail "a row ending in Droid's tmux indicator without its timer must refuse input, got '$out'"
  pass "Droid composer is readable only under a complete live TUI envelope"
}

make_droid_case() {  # <name> <id>
  local case_dir=$1 id=$2 fakebin
  CASE_DIR="$TMP_ROOT/$case_dir"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  fakebin=$(make_spawn_fakebin "$CASE_DIR/fake" droid)
  FAKEBIN_DIR=$fakebin
  fm_test_spawn_home "$HOME_DIR" droid
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$case_dir"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  mv "$fakebin/tmux" "$fakebin/tmux-base"
  cat >"$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = capture-pane ] && [ -f "${FM_FAKE_DROID_SETTINGS:-/nonexistent}" ]; then
  if [ ! -e "${FM_FAKE_DROID_SETTINGS}.submitted" ]; then
    command=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$FM_FAKE_DROID_SETTINGS")
    sh -c "$command"
    touch "${FM_FAKE_DROID_SETTINGS}.submitted"
  fi
  printf 'Droid ready\n'
  exit 0
fi
exec "$(dirname "$0")/tmux-base" "$@"
SH
  chmod +x "$fakebin/tmux"
  cat >"$fakebin/droid" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = exec ] && [ -n "${FM_FAKE_DROID_REJECT_MODEL:-}" ]; then
  printf 'Invalid model: %s\n' "$FM_FAKE_DROID_REJECT_MODEL" >&2
  exit 1
fi
exit 0
SH
  chmod +x "$fakebin/droid"
}

run_droid_spawn() {  # <id> [extra args]
  local id=$1
  shift
  FM_FAKE_DROID_SETTINGS="$HOME_DIR/state/$id.droid-settings.json" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
      "$id" "$PROJ_DIR" --scout --harness droid "$@"
}

test_droid_launch_and_hooks() {
  local id=droid-launch-1 out rc settings cmd state
  make_droid_case launch "$id"
  out=$(run_droid_spawn "$id" --model gpt-5.6-luna --effort low)
  rc=$?
  expect_code 0 "$rc" "Droid spawn failed: $out"
  settings="$HOME_DIR/state/$id.droid-settings.json"
  state="$HOME_DIR/state"
  jq -e '.model == "gpt-5.6-luna" and .reasoningEffort == "low" and .sessionDefaultSettings.autonomyLevel == "high" and .hooksDisabled == false' "$settings" >/dev/null \
    || fail "Droid settings lost model, effort, autonomy, or hooks"
  out=$(sh -c "$(jq -r '.statusLine.command' "$settings")" 2>/dev/null)
  [ -n "$out" ] && [ "$(fm_tmux_droid_composer_state "${DROID_IDLE_SCREEN%firstmate}$out")" = empty ] \
    || fail "Droid worker statusLine must draw the row the composer read accepts, got '$out'"
  grep -Fq -- '--settings' "$CASE_DIR/launch.log" || fail "Droid launch did not use its runtime settings"
  grep -Fq -- '--model' "$CASE_DIR/launch.log" && fail "interactive Droid does not accept --model" || true
  grep -Fq -- '--auto high' "$CASE_DIR/launch.log" || fail "Droid launch did not request unattended autonomy"
  grep -Fq -- 'encode launch-brief' "$CASE_DIR/launch.log" || fail "Droid launch did not carry the encoded brief"
  [ "$(fm_busy_classify tmux fake:win droid "$id" "$state")" = 'busy droid-hook' ] \
    || fail "UserPromptSubmit hook did not replace the spawn seed"
  cmd=$(jq -r '.hooks.Stop[0].hooks[0].command' "$settings")
  sh -c "$cmd"
  [ -e "$state/$id.turn-ended" ] || fail "Stop hook did not signal turn end"
  [ "$(fm_busy_classify tmux fake:win droid "$id" "$state")" = 'idle droid-hook' ] \
    || fail "Stop hook did not close the busy record"
  cmd=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$settings")
  sh -c "$cmd"
  cmd=$(jq -r '.hooks.Notification[0].hooks[0].command' "$settings")
  printf '%s\n' '{"notification_type":"idle_prompt"}' | sh -c "$cmd"
  [ "$(fm_busy_classify tmux fake:win droid "$id" "$state")" = 'idle droid-hook' ] \
    || fail "idle notification did not settle a cancelled turn"
  pass "Droid spawn passes the brief and model settings; hooks open and close turns"
}

test_droid_bad_model_refuses_before_launch() {
  local id=droid-bad-model out rc
  make_droid_case bad-model "$id"
  out=$(FM_FAKE_DROID_REJECT_MODEL=invalid run_droid_spawn "$id" --model invalid)
  rc=$?
  expect_code 1 "$rc" "Droid should refuse a model its own catalog rejects"
  [ ! -e "$CASE_DIR/launch.log" ] || fail "Droid rejected model after a pane launch"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "Droid rejected model after task record creation"
  pass "Droid rejects a model before creating a worker endpoint"
}

test_raw_droid_command_does_not_arm_unused_hooks() {
  local id=droid-raw-1 out rc
  make_droid_case raw "$id"
  out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" 'droid --auto high' --scout)
  rc=$?
  expect_code 0 "$rc" "raw Droid command should keep the raw-launch contract: $out"
  [ ! -e "$HOME_DIR/state/$id.busy-gen" ] || fail "raw Droid command armed a busy record with no hook writer"
  [ ! -e "$HOME_DIR/state/$id.droid-settings.json" ] || fail "raw Droid command wrote unused runtime settings"
  pass "raw Droid commands remain outside canonical hook arming"
}

test_droid_identity_and_control
test_droid_composer_envelope
test_droid_launch_and_hooks
test_droid_bad_model_refuses_before_launch
test_raw_droid_command_does_not_arm_unused_hooks
fm_test_cleanup "$TMP_ROOT"
