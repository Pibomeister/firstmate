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
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

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
DROID_ORCA_IDLE_SCREEN=$(cat "$ROOT/tests/fixtures/droid/idle-orca-0.230.0.txt")

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
  out=$(fm_tmux_droid_composer_state "${screen/TMUX ⧉/TMUX ●}")
  [ "$out" = empty ] || fail "a changed Droid integration indicator must not hide an empty composer"
  out=$(fm_tmux_droid_composer_state "${screen/\[⏱ 16s, context: 3%\] /}")
  [ "$out" = unknown ] || fail "a footer without Droid's timer must refuse input, got '$out'"
  pass "Droid composer is readable only under a complete live TUI envelope"
}

test_droid_composer_requires_a_droid_process() {
  local fakebin screen out
  fakebin=$(fm_fakebin "$TMP_ROOT/composer-identity")
  screen="$TMP_ROOT/composer-identity/screen.txt"
  printf '%s\n' "$DROID_IDLE_SCREEN" >"$screen"
  cat >"$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *cursor_y*) printf '20\n' ;;
  *pane_current_command*) printf '%s\n' "${FM_FAKE_PROCESS_NAME:-bash}" ;;
  *pane_tty*) printf '\n' ;;
  *capture-pane*) cat "$FM_FAKE_SCREEN" ;;
  *) printf '\n' ;;
esac
SH
  chmod +x "$fakebin/tmux"
  out=$(FM_FAKE_SCREEN="$screen" FM_FAKE_PROCESS_NAME=droid PATH="$fakebin:$PATH" fm_tmux_composer_state fake:win)
  [ "$out" = empty ] || fail "a live Droid pane must reach the cursorless composer proof, got '$out'"
  out=$(FM_FAKE_SCREEN="$screen" FM_FAKE_PROCESS_NAME=notdroid PATH="$fakebin:$PATH" fm_tmux_composer_state fake:win)
  [ "$out" = unknown ] || fail "an identical screen from another process must stay unknown, got '$out'"
  pass "Droid composer proof is gated on the foreground process identity"
}

test_droid_orca_composer_uses_the_live_screen() {
  local screen=$DROID_ORCA_IDLE_SCREEN out
  out=$(fm_composer_droid_state "$screen" orca)
  [ "$out" = empty ] || fail "captured Orca Droid idle screen must read empty, got '$out'"
  out=$(fm_composer_droid_state "${screen/│ >           /│ > /exit     }" orca)
  [ "$out" = pending ] || fail "typed text in captured Orca composer must stay pending, got '$out'"
  out=$(fm_composer_droid_state "$screen
shell prompt" orca)
  [ "$out" = unknown ] || fail "a shell prompt below a stale Orca Droid frame must stay unknown"
  out=$(fm_composer_droid_state "${screen/IDE ◌/IDE ●}" orca)
  [ "$out" = empty ] || fail "an Orca integration status change must preserve the empty verdict"
  out=$(fm_composer_droid_state "${screen/\[⏱ 17s, context: 3%\] /}" orca)
  [ "$out" = unknown ] || fail "an Orca footer without Droid's timer must refuse input"
  pass "captured Orca Droid screen has strict idle, pending, and stale-frame verdicts"
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
# Identity queries for the trust-route probe. Keep these ahead of send-keys
# so a called send-key is not the only recorded proof of the target.
if [ "${1:-}" = display-message ]; then
  case "$*" in
    *'#{socket_path}'*|*'#{pane_id}'*|*'#{pane_pid}'*|*'#{pane_tty}'*|*'#{pane_current_command}'*)
      printf 'socket=/tmp/tmux-501/fm-droid-signals-fake pane_id=%%0 pane_pid=4242 pane_tty=/dev/ttys001 cmd=droid\n'
      exit 0
      ;;
  esac
fi
# Count only a bare named Enter or 1 (`send-keys -t <target> Enter|1`). A
# text-line payload and a -l literal both end with a key but are not the
# trust-dialog key.
if [ "${1:-}" = send-keys ] && [ -n "${FM_FAKE_DROID_SETTINGS:-}" ]; then
  skip_next=
  extra=
  saw_enter=
  saw_one=
  send_target=
  first=1
  for a in "$@"; do
    if [ -n "$first" ]; then first=; continue; fi
    if [ -n "$skip_next" ]; then
      [ -n "$send_target" ] || send_target=$a
      skip_next=
      continue
    fi
    case "$a" in
      -t) skip_next=1; continue ;;
      -l) extra=1; continue ;;
      Enter)
        [ -z "$saw_enter" ] || extra=1
        saw_enter=1
        ;;
      1)
        [ -z "$saw_one" ] || extra=1
        saw_one=1
        ;;
      *) extra=1 ;;
    esac
  done
  if [ -n "$saw_enter" ] && [ -z "$extra" ]; then
    printf 'Enter\n' >>"${FM_FAKE_DROID_SETTINGS}.enters"
    if [ -f "${FM_FAKE_DROID_SETTINGS}.trust" ]; then
      printf 'Enter\n' >>"${FM_FAKE_DROID_SETTINGS}.trust-enters"
      printf '%s\n' "$send_target" >>"${FM_FAKE_DROID_SETTINGS}.trust-send-target"
    fi
  fi
  if [ -n "$saw_one" ] && [ -z "$extra" ]; then
    printf '1\n' >>"${FM_FAKE_DROID_SETTINGS}.ones"
    if [ -f "${FM_FAKE_DROID_SETTINGS}.trust" ]; then
      printf '1\n' >>"${FM_FAKE_DROID_SETTINGS}.trust-ones"
      printf '%s\n' "$send_target" >>"${FM_FAKE_DROID_SETTINGS}.trust-send-target"
    fi
  fi
fi
if [ "${1:-}" = capture-pane ] && [ -f "${FM_FAKE_DROID_SETTINGS:-/nonexistent}" ]; then
  cap_skip=
  cap_target=
  for a in "$@"; do
    if [ -n "$cap_skip" ]; then
      cap_target=$a
      cap_skip=
      continue
    fi
    [ "$a" = -t ] && cap_skip=1
  done
  [ -z "$cap_target" ] || printf '%s\n' "$cap_target" >>"${FM_FAKE_DROID_SETTINGS}.capture-target"
  launched=$(wc -l <"${FM_FAKE_DROID_SETTINGS}.enters" 2>/dev/null | tr -d ' ')
  case "$launched" in ''|*[!0-9]*) launched=0 ;; esac
  # Pre-launch cwd probes are not the TUI. Trust and wait-loop poll counts
  # start only after the launch Enter that starts Droid.
  if [ "$launched" -lt 1 ]; then
    printf '\n'
    exit 0
  fi
  [ -z "${FM_FAKE_DROID_CAPTURE_SLEEP:-}" ] || sleep "$FM_FAKE_DROID_CAPTURE_SLEEP"
  captures=$(cat "${FM_FAKE_DROID_SETTINGS}.captures" 2>/dev/null || printf 0)
  captures=$((captures + 1))
  printf '%s\n' "$captures" >"${FM_FAKE_DROID_SETTINGS}.captures"
  [ "$captures" -gt "${FM_FAKE_DROID_CAPTURE_FAIL_POLLS:-0}" ] || exit 1
  if [ "$captures" -le "${FM_FAKE_DROID_BLANK_POLLS:-0}" ]; then
    printf '\n'
    exit 0
  fi
  shown=$(cat "${FM_FAKE_DROID_SETTINGS}.trust" 2>/dev/null || printf 0)
  trust_enters=$(wc -l <"${FM_FAKE_DROID_SETTINGS}.trust-enters" 2>/dev/null | tr -d ' ')
  case "$trust_enters" in ''|*[!0-9]*) trust_enters=0 ;; esac
  case "$shown" in ''|*[!0-9]*) shown=0 ;; esac
  clears=$(tr -d '\n' <"${FM_FAKE_DROID_SETTINGS}.trust-clears" 2>/dev/null || true)
  [ -n "$clears" ] || clears=${FM_FAKE_DROID_TRUST_CLEARS:-}
  show_trust=0
  if [ "$clears" = after-second ]; then
    [ "$trust_enters" -ge 2 ] || show_trust=1
  elif [ "$shown" -lt "${FM_FAKE_DROID_TRUST_POLLS:-0}" ]; then
    show_trust=1
  fi
  if [ "$show_trust" -eq 1 ]; then
    printf '%s\n' "$((shown + 1))" >"${FM_FAKE_DROID_SETTINGS}.trust"
    if [ "${FM_FAKE_DROID_TRUST_NEGATIVE:-0}" = 1 ]; then
      printf 'Trust this folder?\n  1. Trust this folder\n> 2. Exit without trusting\nEnter to confirm · Esc to exit\n'
    elif [ "${FM_FAKE_DROID_TRUST_PARTIAL:-0}" = 1 ]; then
      printf 'Trust this folder?\nEnter to confirm · Esc to exit\n'
    else
      printf 'Trust this folder?\n> 1. Trust this folder\n  2. Exit without trusting\nEnter to confirm · Esc to exit\n'
    fi
    exit 0
  fi
  if [ ! -e "${FM_FAKE_DROID_SETTINGS}.submitted" ]; then
    if [ "${FM_FAKE_DROID_HOOKS_DISABLED:-0}" != 1 ]; then
      command=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$FM_FAKE_DROID_SETTINGS")
      sh -c "$command"
    fi
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
if [ "${1:-}" = exec ] && IFS= read -r -t 1 _; then
  touch "$(dirname "$0")/probe-read-stdin"
fi
if [ "${1:-}" = exec ] && [ "${2:-}" = --help ]; then
  cat <<'HELP'
Available Models:
  gpt-5.6-luna                 GPT-5.6 Luna (default)
  claude-haiku-4-5-20251001    Haiku 4.5

Model details:
  - GPT-5.6 Luna: supports reasoning: Yes; supported: [none, low, medium, high, xhigh, max]; default: medium
  - Haiku 4.5: supports reasoning: Yes; supported: [off, low, medium, high]; default: off
HELP
  exit 0
fi
if [ "${1:-}" = exec ]; then
  case " $* " in
    *" --list-tools "*)
      if [ -n "${FM_FAKE_DROID_PROBE_HANG:-}" ]; then
        sleep "$FM_FAKE_DROID_PROBE_HANG"
      elif [ -n "${FM_FAKE_DROID_PROBE_SLEEP:-}" ]; then
        sleep "$FM_FAKE_DROID_PROBE_SLEEP"
      fi
      ;;
  esac
fi
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
  mkdir -p "$HOME_DIR/state"
  printf '%s\n' "${FM_FAKE_DROID_TRUST_CLEARS:-}" >"$HOME_DIR/state/$id.droid-settings.json.trust-clears"
  FM_FAKE_DROID_SETTINGS="$HOME_DIR/state/$id.droid-settings.json" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
    FM_FAKE_DROID_TRUST_CLEARS="${FM_FAKE_DROID_TRUST_CLEARS:-}" \
    FM_FAKE_DROID_TRUST_POLLS="${FM_FAKE_DROID_TRUST_POLLS:-0}" \
    FM_FAKE_DROID_TRUST_NEGATIVE="${FM_FAKE_DROID_TRUST_NEGATIVE:-0}" \
    FM_FAKE_DROID_TRUST_PARTIAL="${FM_FAKE_DROID_TRUST_PARTIAL:-0}" \
    FM_FAKE_DROID_BLANK_POLLS="${FM_FAKE_DROID_BLANK_POLLS:-0}" \
    FM_FAKE_DROID_CAPTURE_FAIL_POLLS="${FM_FAKE_DROID_CAPTURE_FAIL_POLLS:-0}" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
      "$id" "$PROJ_DIR" --scout --harness droid "$@"
}

test_droid_launch_and_hooks() {
  local id=droid-launch-1 out rc settings cmd state baseline digest gen live_bin live_pid
  make_droid_case launch "$id"
  out=$(run_droid_spawn "$id" --model gpt-5.6-luna --effort low)
  rc=$?
  expect_code 0 "$rc" "Droid spawn failed: $out"
  settings="$HOME_DIR/state/$id.droid-settings.json"
  state="$HOME_DIR/state"
  jq -e '.sessionDefaultSettings.model == "gpt-5.6-luna" and .reasoningEffort == "low" and .sessionDefaultSettings.autonomyLevel == "high" and (has("hooksDisabled") | not)' "$settings" >/dev/null \
    || fail "Droid settings lost model/effort/autonomy or overrode the operator's hooks policy"
  out=$(sh -c "$(jq -r '.statusLine.command' "$settings")" 2>/dev/null)
  [ -n "$out" ] && [ "$(fm_tmux_droid_composer_state "${DROID_IDLE_SCREEN%firstmate}$out")" = empty ] \
    || fail "Droid worker statusLine must draw the row the composer read accepts, got '$out'"
  grep -Fq -- '--settings' "$CASE_DIR/launch.log" || fail "Droid launch did not use its runtime settings"
  grep -Fq -- '--model' "$CASE_DIR/launch.log" && fail "interactive Droid does not accept --model" || true
  grep -Fq -- '--auto high' "$CASE_DIR/launch.log" || fail "Droid launch did not request unattended autonomy"
  grep -Fq -- 'encode launch-brief' "$CASE_DIR/launch.log" || fail "Droid launch did not carry the encoded brief"
  [ "$(fm_busy_classify tmux fake:win droid "$id" "$state")" = 'busy droid-hook' ] \
    || fail "UserPromptSubmit hook did not replace the spawn seed"
  baseline=$(fm_busy_record_read "$state" "$id")
  baseline=${baseline##* }
  gen=$(cat "$state/$id.busy-gen")
  cmd=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$settings")
  printf '{"hook_event_name":"UserPromptSubmit","prompt":"typed Droid prompt"}\n' | sh -c "$cmd"
  digest=$(printf '%s' 'typed Droid prompt' | fm_busy_prompt_sha256)
  fm_busy_prompt_receipt_after "$state" "$id" "$gen" "$baseline" "$digest" \
    || fail "spawned Droid hook did not receipt its exact submitted prompt"
  cmd=$(jq -r '.hooks.Stop[0].hooks[0].command' "$settings")
  sh -c "$cmd"
  [ -e "$state/$id.turn-ended" ] || fail "Stop hook did not signal turn end"
  [ "$(fm_busy_classify tmux fake:win droid "$id" "$state")" = 'idle droid-hook' ] \
    || fail "Stop hook did not close the busy record"
  cmd=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$settings")
  sh -c "$cmd" </dev/null
  cmd=$(jq -r '.hooks.Notification[0].hooks[0].command' "$settings")
  printf '%s\n' '{"notification_type":"idle_prompt"}' | sh -c "$cmd"
  [ "$(fm_busy_classify tmux fake:win droid "$id" "$state")" = 'idle droid-hook' ] \
    || fail "idle notification did not settle a cancelled turn"
  cmd=$(jq -r '.hooks.SessionEnd[0].hooks[0].command' "$settings")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" \
    --source droid-hook --event user-prompt-submit >/dev/null
  printf '%s\n' '{"session_id":"s-old","reason":"clear"}' | sh -c "$cmd"
  [ "$(fm_busy_classify tmux fake:win droid "$id" "$state")" = 'idle droid-hook' ] \
    || fail "a cleared Droid session did not close the busy record"
  [ ! -e "$state/$id.droid-session-end" ] || fail "/clear was recorded as a Droid session close"
  for reason in prompt_input_exit logout unverified; do
    printf '{"session_id":"s-new","reason":"%s"}\n' "$reason" | sh -c "$cmd"
    [ ! -e "$state/$id.droid-session-end" ] || fail "unverified SessionEnd reason $reason recorded a close"
  done
  printf '%s\n' '{"session_id":"s-new","reason":"other"}' | sh -c "$cmd"
  [ "$(cat "$state/$id.droid-session-end")" = "$(cat "$state/$id.busy-gen")" ] \
    || fail "SessionEnd did not record the current busy generation"
  live_bin="$CASE_DIR/live-droid"
  mkdir -p "$live_bin"
  # A re-signed copy of macOS's universal arm64e sleep is SIGKILLed on launch, so take its x86_64 slice.
  lipo "$(command -v sleep)" -thin x86_64 -output "$live_bin/droid" 2>/dev/null \
    || cp "$(command -v sleep)" "$live_bin/droid"
  if command -v codesign >/dev/null 2>&1; then
    codesign -s - -f "$live_bin/droid" >/dev/null 2>&1 || fail "could not sign the live droid stand-in"
  fi
  (cd "$WT_DIR" && exec "$live_bin/droid" 60) &
  live_pid=$!
  for _ in $(seq 1 50); do
    lsof -a -p "$live_pid" -d cwd -Fn 2>/dev/null | grep -q '^n' && break
    sleep 0.1
  done
  if fm_control_droid_session_ended "$state" "$id" "$state/$id.meta"; then
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
    fail "a session-close marker counted as a stop while Droid still ran in the worktree"
  fi
  kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
  fm_control_droid_session_ended "$state" "$id" "$state/$id.meta" \
    || fail "Orca control must accept the generation-bound SessionEnd marker once Droid is gone"
  rm -f "$state/$id.droid-session-end"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" >/dev/null
  printf '%s\n' '{"session_id":"s-new","reason":"other"}' | sh -c "$cmd"
  [ ! -e "$state/$id.droid-session-end" ] || fail "an old Droid session marked a replacement stopped"
  rm -f "$state/$id.turn-ended"
  cmd=$(jq -r '.hooks.Stop[0].hooks[0].command' "$settings")
  sh -c "$cmd"
  [ ! -e "$state/$id.turn-ended" ] || fail "an old Droid Stop falsely woke the replacement turn"
  pass "Droid spawn passes the brief and model settings; hooks open and close turns"
}

droid_enter_lines() {  # <id> [suffix]
  local f="$HOME_DIR/state/$1.droid-settings.json${2:-.enters}"
  if [ -f "$f" ]; then
    wc -l <"$f" | tr -d ' '
  else
    printf '0'
  fi
}

test_droid_swallowed_trust_enter_is_retried_until_the_dialog_clears() {
  local out rc base trust_enters
  make_droid_case trust-base droid-trust-base
  out=$(run_droid_spawn droid-trust-base)
  expect_code 0 $? "Droid baseline spawn failed: $out"
  base=$(droid_enter_lines droid-trust-base)
  make_droid_case trust-swallow droid-trust-swallow
  out=$(FM_FAKE_DROID_TRUST_CLEARS=after-second \
    FM_DROID_READY_POLLS=6 FM_DROID_POLL_INTERVAL=0 FM_DROID_READY_SECONDS=5 \
    run_droid_spawn droid-trust-swallow)
  rc=$?
  expect_code 0 "$rc" "a swallowed first trust Enter should be retried into a verified spawn: $out"
  [ "$(droid_enter_lines droid-trust-swallow)" -eq $((base + 2)) ] \
    || fail "Droid trust dialog was not re-answered until it cleared, extra $(( $(droid_enter_lines droid-trust-swallow) - base ))"
  trust_enters=$(droid_enter_lines droid-trust-swallow .trust-enters)
  [ "$trust_enters" -eq 2 ] \
    || fail "Droid trust-time Enter count should be 2 after a swallowed first key, got $trust_enters"
  pass "Droid retries a swallowed trust Enter until the dialog clears"
}

test_droid_trust_enter_max_sends_one_enter_while_the_dialog_stays() {
  local out rc trust_enters
  make_droid_case trust-max-one droid-trust-max-one
  out=$(FM_FAKE_DROID_TRUST_POLLS=5 \
    FM_DROID_TRUST_ENTER_MAX=1 \
    FM_DROID_READY_POLLS=5 FM_DROID_POLL_INTERVAL=0 FM_DROID_READY_SECONDS=5 \
    run_droid_spawn droid-trust-max-one)
  rc=$?
  expect_code 1 "$rc" "a staying trust dialog with ENTER_MAX=1 should not claim delivery: $out"
  trust_enters=$(droid_enter_lines droid-trust-max-one .trust-enters)
  [ "$trust_enters" -eq 1 ] \
    || fail "Droid trust-time Enter count should be 1 under ENTER_MAX=1, got $trust_enters"
  printf '%s' "$out" | grep -Fq 'answered but the launch prompt hook did not acknowledge' \
    || fail "capped trust Enter must still report unanswered brief: $out"
  pass "Droid sends exactly one trust Enter when ENTER_MAX=1 and the dialog stays"
}

test_droid_trust_probe_stop_captures_one_enter_delta() {
  local out rc probe trust_enters
  probe="$TMP_ROOT/trust-probe-a"
  make_droid_case trust-probe-stop droid-trust-probe-stop
  out=$(FM_FAKE_DROID_TRUST_POLLS=5 \
    FM_DROID_TRUST_ENTER_MAX=1 \
    FM_DROID_TRUST_PROBE_DIR="$probe" \
    FM_DROID_TRUST_PROBE_STOP=1 \
    FM_DROID_READY_POLLS=8 FM_DROID_POLL_INTERVAL=0 FM_DROID_READY_SECONDS=8 \
    run_droid_spawn droid-trust-probe-stop)
  rc=$?
  expect_code 1 "$rc" "trust probe stop should not claim delivery: $out"
  trust_enters=$(droid_enter_lines droid-trust-probe-stop .trust-enters)
  [ "$trust_enters" -eq 1 ] || fail "probe stop sent $trust_enters trust Enters"
  [ -s "$probe/before-enter.txt" ] || fail "missing before-enter capture"
  [ -f "$probe/after-0.3s.txt" ] || fail "missing +0.3s capture"
  [ -f "$probe/after-2s.txt" ] || fail "missing +2s capture"
  grep -Fq 'Trust this folder?' "$probe/before-enter.txt" \
    || fail "before-enter must be the affirmative dialog"
  printf '%s' "$out" | grep -Fq 'trust probe captured one Enter delta and stopped' \
    || fail "probe stop must name the laboratory stop: $out"
  pass "Droid trust probe captures one Enter delta and stops"
}

test_droid_trust_key_one_sends_digit_once_while_the_dialog_stays() {
  local out rc ones enters
  make_droid_case trust-key-one droid-trust-key-one
  out=$(FM_FAKE_DROID_TRUST_POLLS=5 \
    FM_DROID_TRUST_ENTER_MAX=1 \
    FM_DROID_TRUST_KEY=1 \
    FM_DROID_READY_POLLS=5 FM_DROID_POLL_INTERVAL=0 FM_DROID_READY_SECONDS=5 \
    run_droid_spawn droid-trust-key-one)
  rc=$?
  expect_code 1 "$rc" "a staying trust dialog with KEY=1 should not claim delivery: $out"
  ones=$(droid_enter_lines droid-trust-key-one .trust-ones)
  enters=$(droid_enter_lines droid-trust-key-one .trust-enters)
  case "$ones" in ''|*[!0-9]*) ones=0 ;; esac
  case "$enters" in ''|*[!0-9]*) enters=0 ;; esac
  [ "$ones" -eq 1 ] || fail "Droid trust-time key 1 count should be 1, got $ones"
  [ "$enters" -eq 0 ] || fail "KEY=1 must not send a wait-loop Enter, got $enters"
  pass "Droid sends exactly one trust key 1 when KEY=1 and the dialog stays"
}

test_droid_trust_probe_records_matching_send_and_capture_routes() {
  local out rc probe send_target capture_cmd send_cmd
  probe="$TMP_ROOT/trust-probe-route"
  make_droid_case trust-probe-route droid-trust-probe-route
  out=$(FM_FAKE_DROID_TRUST_POLLS=5 \
    FM_DROID_TRUST_ENTER_MAX=1 \
    FM_DROID_TRUST_PROBE_DIR="$probe" \
    FM_DROID_TRUST_PROBE_STOP=1 \
    FM_DROID_READY_POLLS=8 FM_DROID_POLL_INTERVAL=0 FM_DROID_READY_SECONDS=8 \
    run_droid_spawn droid-trust-probe-route)
  rc=$?
  expect_code 1 "$rc" "route probe stop should not claim delivery: $out"
  [ -s "$probe/capture-route.txt" ] || fail "missing capture-route identity"
  [ -s "$probe/send-route.txt" ] || fail "missing send-route identity"
  [ -s "$probe/last-pane.txt" ] || fail "missing last viewport pane"
  capture_cmd=$(grep -E 'cmd=' "$probe/capture-route.txt" | tail -1)
  send_cmd=$(grep -E 'cmd=' "$probe/send-route.txt" | tail -1)
  [ -n "$capture_cmd" ] && [ "$capture_cmd" = "$send_cmd" ] \
    || fail "capture and send routes diverged: capture='$capture_cmd' send='$send_cmd'"
  printf '%s' "$capture_cmd" | grep -Fq 'cmd=droid' \
    || fail "route identity must name the live Droid command: $capture_cmd"
  send_target=$(droid_enter_lines droid-trust-probe-route .trust-send-target)
  [ "$send_target" -eq 1 ] || fail "trust send should record one target line, got $send_target"
  pass "Droid trust probe records matching send and capture routes"
}

test_droid_sends_no_trust_enter_after_the_dialog_clears() {
  local out rc base
  make_droid_case trust-clear-base droid-trust-clear-base
  out=$(run_droid_spawn droid-trust-clear-base)
  expect_code 0 $? "Droid baseline spawn failed: $out"
  base=$(droid_enter_lines droid-trust-clear-base)
  make_droid_case trust-clear droid-trust-clear
  out=$(FM_FAKE_DROID_TRUST_POLLS=1 run_droid_spawn droid-trust-clear)
  rc=$?
  expect_code 0 "$rc" "Droid spawn after a one-frame trust dialog failed: $out"
  [ "$(droid_enter_lines droid-trust-clear)" -eq $((base + 1)) ] \
    || fail "Droid sent Enter after the trust dialog cleared, extra $(( $(droid_enter_lines droid-trust-clear) - base ))"
  [ "$(droid_enter_lines droid-trust-clear .trust-enters)" -eq 1 ] \
    || fail "a cleared Droid trust dialog was answered more than once"
  pass "Droid sends no trust Enter after the dialog disappears"
}

test_droid_sends_no_trust_enter_on_a_blank_or_failed_viewport() {
  local out rc base
  make_droid_case trust-blank-base droid-trust-blank-base
  out=$(run_droid_spawn droid-trust-blank-base)
  expect_code 0 $? "Droid baseline spawn failed: $out"
  base=$(droid_enter_lines droid-trust-blank-base)
  make_droid_case trust-blank droid-trust-blank
  out=$(FM_FAKE_DROID_BLANK_POLLS=1 FM_FAKE_DROID_TRUST_POLLS=1 run_droid_spawn droid-trust-blank)
  rc=$?
  expect_code 0 "$rc" "Droid spawn after a blank viewport frame failed: $out"
  [ "$(droid_enter_lines droid-trust-blank)" -eq $((base + 1)) ] \
    || fail "Droid sent Enter on a blank viewport, extra $(( $(droid_enter_lines droid-trust-blank) - base ))"
  make_droid_case capture-retry-enters droid-capture-retry-enters
  out=$(FM_FAKE_DROID_CAPTURE_FAIL_POLLS=1 run_droid_spawn droid-capture-retry-enters)
  rc=$?
  expect_code 0 "$rc" "Droid spawn after a failed viewport read failed: $out"
  [ "$(droid_enter_lines droid-capture-retry-enters)" -eq "$base" ] \
    || fail "Droid sent Enter without a successful viewport, extra $(( $(droid_enter_lines droid-capture-retry-enters) - base ))"
  pass "Droid sends no trust Enter on a blank or failed viewport"
}

test_droid_sends_no_trust_enter_on_an_ambiguous_dialog() {
  local id=droid-trust-partial out rc base
  make_droid_case trust-partial-base droid-trust-partial-base
  out=$(run_droid_spawn droid-trust-partial-base)
  expect_code 0 $? "Droid baseline spawn failed: $out"
  base=$(droid_enter_lines droid-trust-partial-base)
  make_droid_case trust-partial "$id"
  out=$(FM_FAKE_DROID_TRUST_POLLS=3 FM_FAKE_DROID_TRUST_PARTIAL=1 \
    FM_DROID_READY_POLLS=3 FM_DROID_POLL_INTERVAL=0 run_droid_spawn "$id")
  rc=$?
  expect_code 1 "$rc" "Droid must refuse an incomplete trust dialog: $out"
  printf '%s' "$out" | grep -Fq 'never showed a selected Trust this folder choice' \
    || fail "incomplete Droid trust dialog did not name the missing selection: $out"
  [ "$(droid_enter_lines "$id")" -eq "$base" ] \
    || fail "Droid answered an incomplete trust lookalike, extra $(( $(droid_enter_lines "$id") - base ))"
  pass "Droid sends no Enter on an ambiguous trust view"
}

test_droid_refuses_a_negative_trust_selection() {
  local id=droid-trust-negative out rc base seen
  make_droid_case trust-negative-base droid-trust-negative-base
  out=$(run_droid_spawn droid-trust-negative-base)
  expect_code 0 $? "Droid baseline spawn failed: $out"
  base=$(wc -l <"$HOME_DIR/state/droid-trust-negative-base.droid-settings.json.enters")
  make_droid_case trust-negative "$id"
  out=$(FM_FAKE_DROID_TRUST_POLLS=3 FM_FAKE_DROID_TRUST_NEGATIVE=1 run_droid_spawn "$id")
  rc=$?
  expect_code 1 "$rc" "Droid must refuse a trust dialog with Exit selected: $out"
  seen=$(wc -l <"$HOME_DIR/state/$id.droid-settings.json.enters")
  [ "$seen" -eq "$base" ] || fail "negative trust selection received an extra Enter"
  printf '%s' "$out" | grep -Fq 'Exit without trusting selected' || fail "trust refusal must identify the selected choice: $out"
  pass "Droid never confirms a selected negative trust choice"
}

test_droid_retries_one_transient_viewport_failure() {
  local id=droid-capture-retry out rc
  make_droid_case capture-retry "$id"
  out=$(FM_FAKE_DROID_CAPTURE_FAIL_POLLS=1 run_droid_spawn "$id")
  rc=$?
  expect_code 0 "$rc" "Droid should recover from one failed viewport read: $out"
  [ "$(cat "$HOME_DIR/state/$id.droid-settings.json.captures")" -ge 2 ] \
    || fail "Droid did not retry the viewport read"
  pass "Droid retries a transient viewport capture failure"
}

test_droid_bounds_a_hung_viewport_read() {
  local id=droid-capture-hung out rc started elapsed
  make_droid_case capture-hung "$id"
  started=$(date +%s)
  out=$(FM_FAKE_DROID_CAPTURE_SLEEP=10 FM_DROID_CAPTURE_TIMEOUT=1 \
    FM_DROID_READY_SECONDS=2 FM_DROID_READY_POLLS=2 FM_DROID_POLL_INTERVAL=0 \
    run_droid_spawn "$id")
  rc=$?
  elapsed=$(( $(date +%s) - started ))
  expect_code 1 "$rc" "a hung Droid viewport read must fail: $out"
  [ "$elapsed" -lt 30 ] || fail "hung Droid viewport read exceeded its bound (${elapsed}s)"
  printf '%s' "$out" | grep -Fq 'viewport capture never succeeded (last exit 124)' \
    || fail "hung viewport refusal did not identify capture failure: $out"
  pass "Droid bounds hung viewport reads and reports capture failure"
}

test_droid_respects_disabled_hooks_policy() {
  local id=droid-hooks-disabled out rc
  make_droid_case hooks-disabled "$id"
  out=$(FM_FAKE_DROID_HOOKS_DISABLED=1 FM_DROID_READY_POLLS=2 FM_DROID_POLL_INTERVAL=0 \
    run_droid_spawn "$id")
  rc=$?
  expect_code 1 "$rc" "Droid without operator-enabled hooks must fail readiness: $out"
  jq -e 'has("hooksDisabled") | not' "$HOME_DIR/state/$id.droid-settings.json" >/dev/null \
    || fail "Droid overrode the operator's hooks-disabled policy"
  printf '%s' "$out" | grep -Fq 'whether hooks are disabled' \
    || fail "Droid hook refusal did not name the policy possibility: $out"
  pass "Droid leaves operator hook policy intact and refuses unacknowledged launches"
}

test_droid_omits_unsupported_model_effort() {
  local id=droid-effort-unsupported out rc settings
  make_droid_case effort-unsupported "$id"
  out=$(run_droid_spawn "$id" --model claude-haiku-4-5-20251001 --effort xhigh)
  rc=$?
  expect_code 0 "$rc" "unsupported effort should use the recorded-and-omitted contract: $out"
  settings="$HOME_DIR/state/$id.droid-settings.json"
  jq -e '.sessionDefaultSettings.model == "claude-haiku-4-5-20251001" and (has("reasoningEffort") | not)' "$settings" >/dev/null \
    || fail "unsupported Haiku xhigh effort reached Droid runtime settings"
  grep -Fqx 'effort=xhigh' "$HOME_DIR/state/$id.meta" || fail "requested effort was not recorded"
  printf '%s' "$out" | grep -Fq 'unsupported' || fail "effort omission was not disclosed"
  pass "Droid records and omits a model-specific unsupported effort"
}

test_droid_omits_effort_without_explicit_model() {
  local id=droid-effort-no-model out rc settings
  make_droid_case effort-no-model "$id"
  out=$(run_droid_spawn "$id" --effort low)
  rc=$?
  expect_code 0 "$rc" "effort without a model should use the recorded-and-omitted contract: $out"
  settings="$HOME_DIR/state/$id.droid-settings.json"
  jq -e '(.sessionDefaultSettings | has("model") | not) and (has("reasoningEffort") | not)' "$settings" >/dev/null \
    || fail "effort without --model reached Droid runtime settings for the operator's default model"
  grep -Fqx 'effort=low' "$HOME_DIR/state/$id.meta" || fail "requested effort was not recorded"
  printf '%s' "$out" | grep -Fq 'omitting it from runtime settings' || fail "effort omission was not disclosed: $out"
  pass "Droid omits effort when the operator's default model runs"
}

test_droid_model_probe_detaches_stdin() {
  local id=droid-probe-stdin out rc
  make_droid_case probe-stdin "$id"
  out=$(printf 'stdin-leak\n' | run_droid_spawn "$id" --model gpt-5.6-luna)
  rc=$?
  expect_code 0 "$rc" "Droid spawn with piped stdin failed: $out"
  [ ! -e "$FAKEBIN_DIR/probe-read-stdin" ] || fail "Droid model probe read the caller's stdin"
  pass "Droid model probe cannot read the caller's stdin"
}

test_droid_model_probe_accepts_a_slow_valid_answer() {
  local id=droid-probe-slow out rc settings
  make_droid_case probe-slow "$id"
  out=$(FM_FAKE_DROID_PROBE_SLEEP=1 FM_DROID_MODEL_PROBE_TIMEOUT=3 \
    run_droid_spawn "$id" --model gpt-5.6-luna)
  rc=$?
  expect_code 0 "$rc" "a valid model probe that answers inside its bound must spawn: $out"
  settings="$HOME_DIR/state/$id.droid-settings.json"
  jq -e '.sessionDefaultSettings.model == "gpt-5.6-luna"' "$settings" >/dev/null \
    || fail "a slow valid probe lost the requested model"
  [ -e "$CASE_DIR/launch.log" ] || fail "a slow valid probe never launched"
  pass "Droid accepts a valid model whose tool-list probe answers inside its bound"
}

test_droid_model_probe_refuses_when_the_bound_expires() {
  local id=droid-probe-hang out rc started elapsed
  make_droid_case probe-hang "$id"
  started=$(date +%s)
  out=$(FM_FAKE_DROID_PROBE_HANG=30 FM_DROID_MODEL_PROBE_TIMEOUT=1 \
    run_droid_spawn "$id" --model gpt-5.6-luna)
  rc=$?
  elapsed=$(( $(date +%s) - started ))
  expect_code 1 "$rc" "a hung model probe must refuse: $out"
  [ "$elapsed" -lt 15 ] || fail "hung Droid model probe exceeded its bound (${elapsed}s)"
  printf '%s' "$out" | grep -Fq "within 1s" || fail "hung model probe did not name its bound: $out"
  [ ! -e "$CASE_DIR/launch.log" ] || fail "Droid launched after a hung model probe"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "Droid created a task record after a hung model probe"
  pass "Droid refuses a model probe that does not answer within its bound"
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

test_droid_composer_current_footer_shape() {
  local screen out
  screen=' Auto (High) · allow all commands                                  GLM-5.3-Flash (High)
╭──────────────────────────────────────────────────────────────────────────────╮
│ >                                                                            │
╰──────────────────────────────────────────────────────────────────────────────╯
[⏱ 37m 20s] 6 config issues — /diagnostics                                         IDE ◌
firstmate'
  out=$(fm_composer_droid_state "$screen" orca)
  [ "$out" = empty ] || fail "the current Droid footer without a pipe must read empty, got '$out'"
  out=$(fm_composer_droid_state "${screen/│ >           /│ > /exit     }" orca)
  [ "$out" = pending ] || fail "typed text under the current Droid footer must stay pending, got '$out'"
  out=$(fm_composer_droid_state "${screen/\[⏱ 37m 20s\] /}" orca)
  [ "$out" = unknown ] || fail "a footer without Droid's timer must refuse input under the current shape, got '$out'"
  out=$(fm_composer_droid_state "$screen
shell prompt" orca)
  [ "$out" = unknown ] || fail "a shell prompt below the current Droid frame must stay unknown, got '$out'"
  pass "the current Droid footer without an ASCII pipe reads empty or pending, never a shell"
}

# --- shared connected-shell absence proof -----------------------------------
# Stubs are defined only inside the run subshell, so no fake Orca surface
# leaks into the other cases in this file.
ABSENT_CASE=
ABSENT_STATE=
ABSENT_WT=
ABSENT_OTHER=
ABSENT_ID=droid-absent-1
ABSENT_GEN=

make_absent_case() {  # <name>
  ABSENT_CASE="$TMP_ROOT/absent-$1"
  ABSENT_STATE="$ABSENT_CASE/state"
  ABSENT_WT="$ABSENT_CASE/wt"
  ABSENT_OTHER="$ABSENT_CASE/other"
  mkdir -p "$ABSENT_STATE" "$ABSENT_WT" "$ABSENT_OTHER" "$ABSENT_CASE/fakebin"
  cat >"$ABSENT_CASE/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
cat "${FM_STUB_LSOF_FILE:?}" 2>/dev/null
exit "${FM_STUB_LSOF_EXIT:-0}"
SH
  chmod +x "$ABSENT_CASE/fakebin/lsof"
  printf 'p999\nn%s\n' "$ABSENT_OTHER" >"$ABSENT_CASE/scan-clean"
  printf 'p999\nn%s\n' "$ABSENT_WT" >"$ABSENT_CASE/scan-in-wt"
  printf 'p999\nn%s/sub\n' "$ABSENT_WT" >"$ABSENT_CASE/scan-in-wt-sub"
  mkdir -p "$ABSENT_WT/sub"
  ABSENT_GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$ABSENT_STATE" "$ABSENT_ID")
  "$ROOT/bin/fm-busy-event.sh" apply "$ABSENT_STATE" "$ABSENT_ID" idle \
    --gen "$ABSENT_GEN" --source droid-hook --event stop >/dev/null
  fm_write_meta "$ABSENT_STATE/$ABSENT_ID.meta" \
    'harness=droid' 'backend=orca' "worktree=$ABSENT_WT" \
    'terminal=term-1' "busy_gen=$ABSENT_GEN"
  export FM_STUB_LSOF_FILE="$ABSENT_CASE/scan-clean" FM_STUB_LSOF_EXIT=0
  export FM_STUB_FACTS=ok FM_STUB_TREE=dead FM_STUB_SESSION=ok
}

droid_absent_run() {  # [target]
  local target=${1:-term-1}
  (
    fm_backend_source orca >/dev/null 2>&1 || exit 99
    # shellcheck disable=SC2329 # Invoked indirectly by fm_control_droid_agent_absent.
    fm_backend_orca_terminal_facts() {
      case "${FM_STUB_FACTS:-ok}" in
        ok) printf 'ok\037true\037\037local\037pty-1\037%s' "$ABSENT_WT" ;;
        disconnected) printf 'ok\037false\037operator_close\037local\037pty-1\037%s' "$ABSENT_WT" ;;
        remote) printf 'ok\037true\037\037ssh-box\037pty-1\037%s' "$ABSENT_WT" ;;
        stale) printf 'stale\037\037\037\037\037' ;;
        otherwt) printf 'ok\037true\037\037local\037pty-1\037%s' "$ABSENT_OTHER" ;;
        *) return 1 ;;
      esac
    }
    # shellcheck disable=SC2329 # Invoked indirectly by fm_control_droid_agent_absent.
    fm_backend_orca_session_pid() {
      case "${FM_STUB_SESSION:-ok}" in
        ok) printf '4242' ;;
        missing) return 1 ;;
        *) return 2 ;;
      esac
    }
    # shellcheck disable=SC2329 # Invoked indirectly by fm_control_droid_agent_absent.
    fm_backend_orca_tree_state() { printf '%s' "${FM_STUB_TREE:-dead}"; }
    # shellcheck disable=SC2329 # Invoked indirectly by fm_control_droid_agent_absent.
    fm_backend_orca_physical_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }
    PATH="$ABSENT_CASE/fakebin:$PATH" \
      fm_control_droid_agent_absent "$ABSENT_STATE" "$ABSENT_ID" \
        "$ABSENT_STATE/$ABSENT_ID.meta" "$target"
  )
}

expect_absent() {  # <label>
  droid_absent_run || fail "connected-shell absence proof must accept: $1"
}
expect_present() {  # <label>
  droid_absent_run && fail "connected-shell absence proof must refuse: $1" || true
}

test_droid_connected_shell_absence_proof() {
  local name
  make_absent_case positive
  expect_absent "a connected owned idle shell, dead tree, current idle record, and clean exact-worktree scan, with no marker"
  # A Droid process whose cwd is a different worktree does not block this
  # task (the clean scan above already carries exactly that row).

  make_absent_case live-scan
  FM_STUB_LSOF_FILE="$ABSENT_CASE/scan-in-wt" expect_present "a live Droid process in the worktree"
  FM_STUB_LSOF_FILE="$ABSENT_CASE/scan-in-wt-sub" expect_present "a live Droid process under the worktree"

  make_absent_case wrong-gen
  printf 'g-other-generation\n' >"$ABSENT_STATE/$ABSENT_ID.droid-session-end"
  expect_present "a SessionEnd marker from another generation"

  make_absent_case ambiguous
  FM_STUB_TREE=ambiguous expect_present "an ambiguous endpoint tree"
  FM_STUB_TREE=alive expect_present "a live agent in the endpoint tree"
  FM_STUB_TREE=unreadable expect_present "an unreadable endpoint tree"
  FM_STUB_FACTS=unreadable expect_present "an unreadable endpoint"
  FM_STUB_FACTS=stale expect_present "a stale endpoint handle with no marker"
  FM_STUB_FACTS=disconnected expect_present "a disconnected endpoint with no marker"
  FM_STUB_FACTS=remote expect_present "an endpoint on another execution host"
  FM_STUB_SESSION=missing expect_present "a session the sweep no longer lists"
  FM_STUB_SESSION=unreadable expect_present "a session the sweep cannot read"

  make_absent_case scan
  FM_STUB_LSOF_EXIT=2 expect_present "a failed process scan"
  FM_STUB_LSOF_EXIT=0
  printf 'p999\nn%s\n' "$ABSENT_WT" >"$ABSENT_CASE/scan-partial"
  FM_STUB_LSOF_FILE="$ABSENT_CASE/scan-partial" FM_STUB_LSOF_EXIT=1 \
    expect_present "a partial process scan (status 1 with rows)"
  printf 'xgarbage\n' >"$ABSENT_CASE/scan-malformed"
  FM_STUB_LSOF_FILE="$ABSENT_CASE/scan-malformed" expect_present "a malformed process scan"

  make_absent_case different-worktree
  FM_STUB_FACTS=otherwt expect_present "an endpoint whose worktree is a different worktree"

  make_absent_case session-only-close
  # The marker is current, so neither route may fall through: the surviving
  # Droid in the worktree scan refuses both.
  printf '%s\n' "$ABSENT_GEN" >"$ABSENT_STATE/$ABSENT_ID.droid-session-end"
  FM_STUB_LSOF_FILE="$ABSENT_CASE/scan-in-wt" \
    expect_present "a process that survives a session-only close"

  make_absent_case marker-route
  printf '%s\n' "$ABSENT_GEN" >"$ABSENT_STATE/$ABSENT_ID.droid-session-end"
  FM_STUB_TREE=ambiguous FM_STUB_FACTS=unreadable expect_absent \
    "the unchanged current-generation marker route with a clean scan"

  for name in busy-record gen-mismatch no-gen-file target-mismatch recorded-mismatch; do
    make_absent_case "missing-$name"
    case "$name" in
      busy-record)
        "$ROOT/bin/fm-busy-event.sh" apply "$ABSENT_STATE" "$ABSENT_ID" busy \
          --gen "$ABSENT_GEN" --source droid-hook --event user-prompt-submit >/dev/null
        expect_present "a busy (not idle) current-generation record"
        ;;
      gen-mismatch)
        fm_write_meta "$ABSENT_STATE/$ABSENT_ID.meta" \
          'harness=droid' 'backend=orca' "worktree=$ABSENT_WT" \
          'terminal=term-1' 'busy_gen=g-other-generation'
        expect_present "a busy generation that is not the armed generation"
        ;;
      no-gen-file)
        rm -f "$ABSENT_STATE/$ABSENT_ID.busy-gen"
        expect_present "a missing armed-generation sidecar"
        ;;
      target-mismatch)
        droid_absent_run term-other \
          && fail "an endpoint handle that is not the recorded terminal must refuse" || true
        ;;
      recorded-mismatch)
        fm_write_meta "$ABSENT_STATE/$ABSENT_ID.meta" \
          'harness=droid' 'backend=orca' "worktree=$ABSENT_WT" \
          'terminal=term-other' "busy_gen=$ABSENT_GEN"
        expect_present "a target that is not this task's recorded terminal"
        ;;
    esac
  done
  pass "connected owned-shell absence proof accepts only the full proof and refuses every missing or wrong element"
}

test_droid_identity_and_control
test_droid_composer_envelope
test_droid_composer_requires_a_droid_process
test_droid_orca_composer_uses_the_live_screen
test_droid_composer_current_footer_shape
test_droid_connected_shell_absence_proof
test_droid_launch_and_hooks
test_droid_swallowed_trust_enter_is_retried_until_the_dialog_clears
test_droid_trust_enter_max_sends_one_enter_while_the_dialog_stays
test_droid_trust_probe_stop_captures_one_enter_delta
test_droid_trust_key_one_sends_digit_once_while_the_dialog_stays
test_droid_trust_probe_records_matching_send_and_capture_routes
test_droid_sends_no_trust_enter_after_the_dialog_clears
test_droid_sends_no_trust_enter_on_a_blank_or_failed_viewport
test_droid_sends_no_trust_enter_on_an_ambiguous_dialog
test_droid_refuses_a_negative_trust_selection
test_droid_retries_one_transient_viewport_failure
test_droid_bounds_a_hung_viewport_read
test_droid_respects_disabled_hooks_policy
test_droid_omits_unsupported_model_effort
test_droid_omits_effort_without_explicit_model
test_droid_model_probe_detaches_stdin
test_droid_model_probe_accepts_a_slow_valid_answer
test_droid_model_probe_refuses_when_the_bound_expires
test_droid_bad_model_refuses_before_launch
test_raw_droid_command_does_not_arm_unused_hooks
fm_test_cleanup "$TMP_ROOT"
