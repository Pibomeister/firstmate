#!/usr/bin/env bash
# Behavior tests for bin/fm-resume-doorbell.sh, the model-free typer that
# starts a turn in an idle primary after a Claude auto compaction.
#
# The backend reads and keystrokes are replaced through the script's
# FM_TEST_SEAM hook (FM_RESUME_DOORBELL_TEST_LIB) by a file-backed fake: the
# composer is a file, Enter clears it unless the fixture is told to drop it,
# and every keystroke is logged. No terminal, multiplexer or session is used.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-resume-doorbell)
DOORBELL="$ROOT/bin/fm-resume-doorbell.sh"
LINE=': Firstmate resume after context compaction: re-read state and open goals (run bin/fm-wake-drain.sh and bin/fm-order.sh pickup), then continue the open work.'

FAKE_LIB="$TMP_ROOT/fake-backend.sh"
cat > "$FAKE_LIB" <<'SH'
# File-backed fake backend for the resume doorbell (sourced under FM_TEST_SEAM).
fake_get() { cat "$FAKE_DIR/$1" 2>/dev/null || printf '%s' "$2"; }
fake_drop_enter() {  # true (and decrements) while Enters are being dropped
  local n
  n=$(fake_get drops 0)
  [ "$n" -gt 0 ] || return 1
  printf '%s\n' "$((n - 1))" > "$FAKE_DIR/drops"
  # Someone types into the composer right after our dropped Enter.
  [ ! -e "$FAKE_DIR/foreign-after-drop" ] || printf 'operator draft' > "$FAKE_DIR/composer"
}
fm_backend_agent_state() { fake_get agent alive; }
fm_backend_busy_state() {
  # A fixture transcript that keeps growing models a turn writing to it.
  [ -z "${FAKE_GROW_TRANSCRIPT:-}" ] || printf '{"type":"assistant"}\n' >> "$FAKE_GROW_TRANSCRIPT"
  fake_get busy idle
}
fm_backend_composer_state() {
  [ -s "$FAKE_DIR/composer" ] && { printf 'pending'; return 0; }
  fake_get composer-state empty
}
fm_backend_send_key() {
  printf 'key\t%s\t%s\n' "$2" "$3" >> "$FAKE_DIR/keys"
  fake_drop_enter || : > "$FAKE_DIR/composer"
}
fm_backend_send_text_submit() {
  printf 'text\t%s\t%s\n' "$2" "$3" >> "$FAKE_DIR/keys"
  [ "$(fake_get send-fails 0)" = 1 ] && { printf 'send-failed'; return 0; }
  printf '%s' "$3" > "$FAKE_DIR/composer"
  if fake_drop_enter; then
    printf 'pending'
  else
    : > "$FAKE_DIR/composer"
    printf 'empty'
  fi
}
fm_task_inbox_composer_holds() { [ "$(cat "$FAKE_DIR/composer" 2>/dev/null)" = "$3" ]; }
SH

# A fixture home with a live session lock and a recorded captain handle.
make_home() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/fake"
  sleep 300 >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$dir/state/.lock"
  printf '%s\n' "$!" >> "$TMP_ROOT/sleepers"
  printf 'backend=herdr\ntarget=fixture:w1:p1\nat=1\n' > "$dir/state/captain-handle"
  : > "$dir/fake/composer"
  printf '%s\n' "$dir"
}

run_doorbell() {  # <dir> [args...]
  local dir=$1
  shift
  env -u TMUX -u TMUX_PANE -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_ENV -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u ORCA_TERMINAL_HANDLE \
    FM_TEST_SEAM=1 FM_RESUME_DOORBELL_TEST_LIB="$FAKE_LIB" FAKE_DIR="$dir/fake" \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_RESUME_DOORBELL_SETTLE_SECS="${SETTLE:-0}" FM_RESUME_DOORBELL_POLL_SECS="${POLL:-0.2}" \
    FM_RESUME_DOORBELL_WAIT_SECS="${WAIT:-2}" FM_RESUME_DOORBELL_RESUBMIT_DELAY=0.1 \
    "$DOORBELL" "$@"
}

last_outcome() { tail -n 1 "$1/state/.resume-doorbell.log" | cut -f5; }
last_detail() { tail -n 1 "$1/state/.resume-doorbell.log" | cut -f6; }
typed_count() { { cat "$1/fake/keys" 2>/dev/null || true; } | grep -c '^text'; }
enter_count() { { cat "$1/fake/keys" 2>/dev/null || true; } | grep -c '^key'; }

cleanup_sleepers() {
  local pid
  [ -f "$TMP_ROOT/sleepers" ] || return 0
  while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$TMP_ROOT/sleepers"
}
trap 'cleanup_sleepers; fm_test_cleanup' EXIT

test_idle_session_gets_one_line_and_submits() {
  local dir
  dir=$(make_home idle)
  run_doorbell "$dir" --source compact
  [ "$(typed_count "$dir")" = 1 ] || fail "the idle session must receive the line exactly once: $(cat "$dir/fake/keys" 2>/dev/null)"
  grep -qF "$LINE" "$dir/fake/keys" || fail "the doorbell typed something other than its constant line"
  grep -qF 'fixture:w1:p1' "$dir/fake/keys" || fail "the doorbell did not type into the recorded captain handle"
  [ "$(last_outcome "$dir")" = submitted ] || fail "outcome must be submitted, got: $(cat "$dir/state/.resume-doorbell.log")"
  [ ! -e "$dir/state/.resume-doorbell.lock" ] || fail "the single-flight lock was left behind"
  pass "resume doorbell: an idle session with an empty composer gets one line and the submit is confirmed"
}

test_unsafe_targets_stand_down_and_type_nothing() {
  local dir case_name reason
  for case_name in busy pending dead unknown-no-transcript no-handle away later-stop; do
    dir=$(make_home "stand-$case_name")
    case "$case_name" in
      busy) printf 'busy' > "$dir/fake/busy" ;;
      pending) printf 'draft text' > "$dir/fake/composer" ;;
      dead) printf 'dead' > "$dir/fake/agent" ;;
      unknown-no-transcript) printf 'unknown' > "$dir/fake/busy" ;;
      no-handle) rm -f "$dir/state/captain-handle" ;;
      away) : > "$dir/state/.afk" ;;
      later-stop)
        printf 'source=compact\n' > "$dir/state/.context-epoch"
        fm_touch_epoch "$(( $(date +%s) - 60 ))" "$dir/state/.context-epoch"
        printf 'epoch=1 owner_pid=1 outcome=arming updated_at=1\n' > "$dir/state/.claude-autoarm-epoch"
        ;;
    esac
    WAIT=1 run_doorbell "$dir" --source compact
    [ "$(typed_count "$dir")" = 0 ] || fail "$case_name: the doorbell typed into an unsafe target: $(cat "$dir/fake/keys")"
    [ "$(last_outcome "$dir")" = stood-down ] || fail "$case_name: outcome must be stood-down, got: $(cat "$dir/state/.resume-doorbell.log")"
    case "$case_name" in
      busy) reason='a turn is running' ;;
      pending) reason='composer is pending' ;;
      dead) reason='agent state is dead' ;;
      unknown-no-transcript) reason='busy state is unknown' ;;
      no-handle) reason='captain-handle is unreadable' ;;
      away) reason='an away or quiet record exists' ;;
      later-stop) reason='a turn already ended after the compaction' ;;
    esac
    assert_contains "$(last_detail "$dir")" "$reason" "$case_name: the stand-down must name its reason"
  done
  pass "resume doorbell: a running turn, a draft, a dead agent, an unproven busy state, no handle, an away record, or a turn that already ran types nothing"
}

test_idle_needs_native_idle_and_a_quiet_transcript() {
  local dir
  dir=$(make_home quiet-transcript)
  printf '{"type":"system"}\n' > "$dir/transcript.jsonl"
  run_doorbell "$dir" --source compact --transcript "$dir/transcript.jsonl"
  [ "$(typed_count "$dir")" = 1 ] || fail "native idle plus a quiet transcript must let the doorbell type"
  [ "$(last_outcome "$dir")" = submitted ] || fail "outcome must be submitted, got: $(cat "$dir/state/.resume-doorbell.log")"

  dir=$(make_home idle-growing-transcript)
  printf '{"type":"system"}\n' > "$dir/transcript.jsonl"
  FAKE_GROW_TRANSCRIPT="$dir/transcript.jsonl" WAIT=1 run_doorbell "$dir" --source compact --transcript "$dir/transcript.jsonl"
  [ "$(typed_count "$dir")" = 0 ] || fail "native idle with a transcript still growing must not get the line"
  [ "$(last_outcome "$dir")" = stood-down ] || fail "a growing transcript must stand down, got: $(cat "$dir/state/.resume-doorbell.log")"
  assert_contains "$(last_detail "$dir")" "not-quiet" "the stand-down must say the transcript was not proven quiet"

  dir=$(make_home unknown-busy-quiet)
  printf 'unknown' > "$dir/fake/busy"
  printf '{"type":"system"}\n' > "$dir/transcript.jsonl"
  run_doorbell "$dir" --source compact --transcript "$dir/transcript.jsonl"
  [ "$(typed_count "$dir")" = 0 ] || fail "a backend with no native busy state must never get the line, even with a quiet transcript"
  [ "$(last_outcome "$dir")" = stood-down ] || fail "outcome must be stood-down, got: $(cat "$dir/state/.resume-doorbell.log")"
  pass "resume doorbell: typing needs a native idle plus a quiet transcript; an unproven busy state stands down"
}

test_changed_lock_owner_stands_down() {
  local dir pid i
  dir=$(make_home lock-moved)
  SETTLE=1 run_doorbell "$dir" --source compact &
  pid=$!
  i=0
  while [ ! -s "$dir/state/.resume-doorbell.lock/pid" ] && [ "$i" -lt 50 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  sleep 0.1
  printf '1\n' > "$dir/state/.lock"
  wait "$pid"
  [ "$(typed_count "$dir")" = 0 ] || fail "a doorbell must not type after the session lock changed owner"
  assert_contains "$(last_detail "$dir")" "session lock changed owner" "stand-down must name the lock change"
  pass "resume doorbell: a session lock that changed owner during the settle stands it down"
}

test_dropped_enter_is_resubmitted_only_while_ours() {
  local dir
  dir=$(make_home drop-one)
  printf '1\n' > "$dir/fake/drops"
  run_doorbell "$dir" --source compact
  [ "$(enter_count "$dir")" = 1 ] || fail "one dropped Enter must get exactly one resubmit Enter: $(cat "$dir/fake/keys")"
  [ "$(last_outcome "$dir")" = submitted ] || fail "outcome must be submitted after the resubmit, got: $(cat "$dir/state/.resume-doorbell.log")"

  dir=$(make_home drop-all)
  printf '99\n' > "$dir/fake/drops"
  run_doorbell "$dir" --source compact
  [ "$(enter_count "$dir")" = 2 ] || fail "resubmit must stop at FM_RESUME_DOORBELL_RESUBMIT_TRIES (2): $(cat "$dir/fake/keys")"
  [ "$(last_outcome "$dir")" = unverified ] || fail "an unconfirmed submit must log unverified, got: $(cat "$dir/state/.resume-doorbell.log")"

  dir=$(make_home drop-then-draft)
  printf '1\n' > "$dir/fake/drops"
  : > "$dir/fake/foreign-after-drop"
  run_doorbell "$dir" --source compact
  [ "$(enter_count "$dir")" = 0 ] || fail "no resubmit Enter may land on someone else's draft: $(cat "$dir/fake/keys")"
  [ "$(last_outcome "$dir")" = unverified ] || fail "a composer holding foreign text after the drop must log unverified, got: $(cat "$dir/state/.resume-doorbell.log")"

  dir=$(make_home send-failed)
  printf '1\n' > "$dir/fake/send-fails"
  run_doorbell "$dir" --source compact
  ! grep -q '^key' "$dir/fake/keys" 2>/dev/null || fail "a failed send must press no further Enter"
  [ "$(last_outcome "$dir")" = failed ] || fail "a failed send must log failed, got: $(cat "$dir/state/.resume-doorbell.log")"
  pass "resume doorbell: a dropped Enter is resubmitted, bounded, and only a confirmed submit logs submitted"
}

test_second_doorbell_types_nothing_while_one_runs() {
  local dir
  dir=$(make_home single-flight)
  mkdir "$dir/state/.resume-doorbell.lock"
  sleep 30 >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$dir/state/.resume-doorbell.lock/pid"
  printf '%s\n' "$!" >> "$TMP_ROOT/sleepers"
  run_doorbell "$dir" --source compact
  [ "$(typed_count "$dir")" = 0 ] || fail "a second doorbell typed while another held the lock"
  [ "$(last_outcome "$dir")" = stood-down ] || fail "the second doorbell must log stood-down"
  pass "resume doorbell: a second doorbell while one is live types nothing"
}

test_idle_session_gets_one_line_and_submits
test_unsafe_targets_stand_down_and_type_nothing
test_idle_needs_native_idle_and_a_quiet_transcript
test_changed_lock_owner_stands_down
test_dropped_enter_is_resubmitted_only_while_ours
test_second_doorbell_types_nothing_while_one_runs
