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
# shellcheck source=bin/fm-operational-input.sh
. "$ROOT/bin/fm-operational-input.sh"

FAKE_LIB="$TMP_ROOT/fake-backend.sh"
cat > "$FAKE_LIB" <<'SH'
# File-backed fake backend for the resume doorbell (sourced under FM_TEST_SEAM).
# real-cli loads the real herdr adapter first; the fakes below then replace
# everything but its CLI helper and client selection.
# shellcheck source=bin/backends/herdr.sh
[ ! -e "$FAKE_DIR/real-cli" ] || . "$SCRIPT_DIR/backends/herdr.sh"
fake_get() { cat "$FAKE_DIR/$1" 2>/dev/null || printf '%s' "$2"; }
fake_posture_change() {  # <none|away|away-contract|lock-moved|cleared>
  case "$1" in
    away) : > "$FAKE_DIR/../state/.afk" ;;
    away-contract) : > "$FAKE_DIR/../state/.afk-contract" ;;
    lock-moved) printf '1\n' > "$FAKE_DIR/../state/.lock" ;;
    cleared) printf 'source=clear\n' > "$FAKE_DIR/../state/.context-epoch.new" \
      && mv -f "$FAKE_DIR/../state/.context-epoch.new" "$FAKE_DIR/../state/.context-epoch" ;;
  esac
}
fake_drop_enter() {  # true (and decrements) while Enters are being dropped
  local n
  n=$(fake_get drops 0)
  [ "$n" -gt 0 ] || return 1
  printf '%s\n' "$((n - 1))" > "$FAKE_DIR/drops"
  # Someone types into the composer right after our dropped Enter.
  [ ! -e "$FAKE_DIR/foreign-after-drop" ] || printf 'operator draft' > "$FAKE_DIR/composer"
  # The session's posture or context changes right after our dropped Enter.
  fake_posture_change "$(fake_get posture-after-drop none)"
  return 0
}
fm_backend_agent_state() { fake_get agent alive; }
fm_backend_busy_state() {
  # A fixture transcript that keeps growing models a turn writing to it.
  [ -z "${FAKE_GROW_TRANSCRIPT:-}" ] || printf '{"type":"assistant"}\n' >> "$FAKE_GROW_TRANSCRIPT"
  # The session's posture or context changes during the idle reads, once.
  if [ -e "$FAKE_DIR/posture-during-idle" ]; then
    fake_posture_change "$(fake_get posture-during-idle none)"
    rm -f "$FAKE_DIR/posture-during-idle"
  fi
  fake_get busy idle
}
fm_backend_herdr_rendered_busy_state() { fake_get rendered idle; }
# lazy-adapter: like the real adapter, the rendered read is defined only once
# fm_backend_source loads it.
if [ -e "$FAKE_DIR/lazy-adapter" ]; then
  unset -f fm_backend_herdr_rendered_busy_state
  fm_backend_source() {
    [ "$1" = herdr ] || return 1
    fm_backend_herdr_rendered_busy_state() { fake_get rendered idle; }
  }
fi
fm_backend_composer_state() {
  [ -s "$FAKE_DIR/composer" ] && { printf 'pending'; return 0; }
  fake_get composer-state empty
}
fake_posture_once() {  # <switch-file>: apply that posture change once
  [ -e "$FAKE_DIR/$1" ] || return 0
  fake_posture_change "$(fake_get "$1" none)"
  rm -f "$FAKE_DIR/$1"
}
# Like the real herdr adapter: each keystroke function first reads the
# endpoint (target_ready), then issues the keystroke through the herdr CLI,
# which the doorbell guards. By default the real adapter is never loaded;
# real-cli keeps the real fm_backend_herdr_cli, and its client selection,
# driving the fake herdr clients the fixture puts on PATH.
_FM_BACKEND_HERDR_SOURCED=1
[ -e "$FAKE_DIR/real-cli" ] || fm_backend_herdr_cli() {  # <session> pane send-text|send-keys <pane> <arg>; anything else is a read
  [ "${2:-}" = pane ] || return 0
  case "${3:-}" in
    send-text)
      printf 'text\t%s\t%s\n' "$4" "$5" >> "$FAKE_DIR/keys"
      printf '%s' "$5" > "$FAKE_DIR/composer"
      ;;
    send-keys)
      # The helper's own first Enter is not logged.
      [ -n "${FAKE_HELPER_ENTER:-}" ] || printf 'key\t%s\t%s\n' "$4" "$5" >> "$FAKE_DIR/keys"
      fake_drop_enter || : > "$FAKE_DIR/composer"
      ;;
  esac
}
fm_backend_herdr_send_literal() {  # <target> <text>
  fake_posture_once posture-in-target-ready
  fm_backend_herdr_cli fixture pane send-text "$1" "$2"
}
fm_backend_herdr_send_key() {  # <target> <key>
  fake_posture_once posture-in-target-ready
  fm_backend_herdr_cli fixture pane send-keys "$1" "$2"
}
fm_backend_send_key() { fm_backend_herdr_send_key "$2" "$3"; }
# Like the shared helper: its own reads, then typing, then more reads, then
# Enter, each keystroke through the adapter.
fm_backend_herdr_composer_clear() {  # <target> <text>: Ctrl+U until empty, like the real herdr adapter
  fm_backend_herdr_send_key "$1" C-u || return 1
  : > "$FAKE_DIR/composer"
  return 0
}
fm_backend_send_text_submit() {
  [ "$(fake_get send-fails 0)" = 1 ] && { printf 'text\t%s\t%s\n' "$2" "$3" >> "$FAKE_DIR/keys"; printf 'send-failed'; return 0; }
  fake_posture_once posture-during-send
  fm_backend_herdr_send_literal "$2" "$3" || { printf 'send-failed'; return 0; }
  # Like the real herdr claude proof path: operator text joining during the
  # settle fails the payload check before any Enter, and only a successful
  # clear turns the abort into send-failed (a refused clear leaves unknown).
  if [ -e "$FAKE_DIR/operator-joins" ]; then
    printf 'operator draft' > "$FAKE_DIR/composer"
    if fm_backend_herdr_composer_clear "$2" "$3"; then printf 'send-failed'; else printf 'unknown'; fi
    return 0
  fi
  # A forced verdict models an unproven submit (a blocking dialog noted, an
  # unreadable state) while the composer still holds exactly our line.
  if [ -n "$(fake_get submit-verdict '')" ]; then
    printf '%s' "$(fake_get submit-verdict '')"
    return 0
  fi
  fake_posture_once posture-before-enter
  FAKE_HELPER_ENTER=1 fm_backend_herdr_send_key "$2" Enter || { printf 'send-failed'; return 0; }
  if [ -s "$FAKE_DIR/composer" ]; then printf 'pending'; else printf 'empty'; fi
}
fm_task_inbox_composer_holds() {
  fake_posture_once posture-during-holds
  [ "$(cat "$FAKE_DIR/composer" 2>/dev/null)" = "$3" ]
}
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
typed_line() {  # <dir> -> the one line the doorbell typed
  grep -m1 '^text' "$1/fake/keys" 2>/dev/null | cut -f3-
}
# The one typed line must be the shared operational-input record carrier
# naming a live record in this home's operational inbox.
assert_carrier() {  # <dir>
  local line record kind
  line=$(typed_line "$1")
  case "$line" in
    "$FM_OPERATIONAL_DOORBELL_PREFIX"*"$FM_OPERATIONAL_DOORBELL_SUFFIX") ;;
    *) fail "the doorbell must type the operational-input record carrier, got: $line" ;;
  esac
  record=${line#"$FM_OPERATIONAL_DOORBELL_PREFIX"}
  record=${record%"$FM_OPERATIONAL_DOORBELL_SUFFIX"}
  [ "${record%/*}" = "$(cd -P "$1/state/operational-inbox" && pwd)" ] \
    || fail "the carrier must name a record in this home's operational inbox: $record"
  [ -f "$record" ] || fail "the carrier's record must exist: $record"
  kind=$(printf '%s' "$line" | "$ROOT/bin/fm-operational-input.sh" doorbell-kind) \
    || fail "the typed line must resolve to a live operational record"
  [ "$kind" = session-start ] || fail "the record's kind must be session-start, got: $kind"
  grep -qF 'resume after context compaction' "$record" \
    || fail "the record must carry the resume instruction: $(cat "$record")"
}

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
  assert_carrier "$dir"
  grep -qF 'fixture:w1:p1' "$dir/fake/keys" || fail "the doorbell did not type into the recorded captain handle"
  [ "$(last_outcome "$dir")" = submitted ] || fail "outcome must be submitted, got: $(cat "$dir/state/.resume-doorbell.log")"
  [ ! -e "$dir/state/.resume-doorbell.lock" ] || fail "the single-flight lock was left behind"
  pass "resume doorbell: an idle session with an empty composer gets one line and the submit is confirmed"
}

test_unsafe_targets_stand_down_and_type_nothing() {
  local dir case_name reason
  for case_name in busy rendered-busy rendered-busy-lazy pending dead unknown-no-transcript no-handle stale-handle away later-stop; do
    dir=$(make_home "stand-$case_name")
    case "$case_name" in
      busy) printf 'busy' > "$dir/fake/busy" ;;
      rendered-busy) printf 'busy' > "$dir/fake/rendered" ;;
      rendered-busy-lazy) printf 'busy' > "$dir/fake/rendered"; : > "$dir/fake/lazy-adapter" ;;
      pending) printf 'draft text' > "$dir/fake/composer" ;;
      dead) printf 'dead' > "$dir/fake/agent" ;;
      unknown-no-transcript) printf 'unknown' > "$dir/fake/busy" ;;
      no-handle) rm -f "$dir/state/captain-handle" ;;
      stale-handle) fm_touch_epoch "$(( $(date +%s) - 60 ))" "$dir/state/captain-handle" ;;
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
      busy|rendered-busy|rendered-busy-lazy) reason='a turn is running' ;;
      pending) reason='composer is pending' ;;
      dead) reason='agent state is dead' ;;
      unknown-no-transcript) reason='busy state is unknown' ;;
      no-handle) reason='captain-handle is unreadable' ;;
      stale-handle) reason='captain-handle is older than the session lock' ;;
      away) reason='an away or quiet record exists' ;;
      later-stop) reason='a turn already ended after the compaction' ;;
    esac
    assert_contains "$(last_detail "$dir")" "$reason" "$case_name: the stand-down must name its reason"
  done
  pass "resume doorbell: a running turn (native or rendered), a draft, a dead agent, an unproven busy state, no handle, a handle older than the session lock, an away record, or a turn that already ran types nothing"
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

test_turn_after_the_compaction_boundary_stands_down() {
  local dir boundary
  boundary='{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto","preTokens":1}}'
  # An in-turn compaction followed by a long tool call: native idle, a quiet
  # transcript, but the turn's assistant record follows the boundary.
  dir=$(make_home turn-after-boundary)
  printf '%s\n' '{"type":"assistant","message":{"content":[]}}' "$boundary" \
    '{"type":"user","isCompactSummary":true}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}' > "$dir/transcript.jsonl"
  run_doorbell "$dir" --source compact --transcript "$dir/transcript.jsonl"
  [ "$(typed_count "$dir")" = 0 ] || fail "a turn still running after the compaction must not get the line: $(cat "$dir/fake/keys")"
  [ "$(last_outcome "$dir")" = stood-down ] || fail "outcome must be stood-down, got: $(cat "$dir/state/.resume-doorbell.log")"
  assert_contains "$(last_detail "$dir")" "a turn is running after the compaction" "the stand-down must name the running turn"

  # An idle compaction: assistant records only before the newest boundary.
  dir=$(make_home idle-after-boundary)
  printf '%s\n' '{"type":"assistant","message":{"content":[]}}' "$boundary" \
    '{"type":"user","isCompactSummary":true}' > "$dir/transcript.jsonl"
  run_doorbell "$dir" --source compact --transcript "$dir/transcript.jsonl"
  [ "$(typed_count "$dir")" = 1 ] || fail "an idle compaction with no assistant record after its boundary must get the line"
  [ "$(last_outcome "$dir")" = submitted ] || fail "outcome must be submitted, got: $(cat "$dir/state/.resume-doorbell.log")"
  pass "resume doorbell: an assistant record after the newest compact boundary stands it down; an idle compaction still delivers"
}

test_newer_context_waits_out_an_older_doorbell() {
  local dir pid holder
  # Doorbell A settles under one compaction; a second compaction replaces the
  # epoch and starts B. B must wait for A to stand down and deliver.
  dir=$(make_home takeover-newer-context)
  printf 'source=compact\nlock_pid=%s\nat=1\n' "$(sed -n 1p "$dir/state/.lock")" > "$dir/state/.context-epoch"
  SETTLE=1 run_doorbell "$dir" --source compact &
  pid=$!
  wait_for_doorbell_lock "$dir"
  printf 'source=compact\nlock_pid=%s\nat=2\n' "$(sed -n 1p "$dir/state/.lock")" > "$dir/state/.context-epoch.new"
  mv -f "$dir/state/.context-epoch.new" "$dir/state/.context-epoch"
  run_doorbell "$dir" --source compact
  wait "$pid"
  [ "$(typed_count "$dir")" = 1 ] || fail "exactly one doorbell must deliver after a newer compaction: $(cat "$dir/fake/keys" 2>/dev/null)"
  [ "$(grep -c "$(printf '\tsubmitted\t')" "$dir/state/.resume-doorbell.log")" = 1 ] \
    || fail "exactly one doorbell must log submitted: $(cat "$dir/state/.resume-doorbell.log")"
  [ "$(grep -c "$(printf '\tstood-down\t')" "$dir/state/.resume-doorbell.log")" = 1 ] \
    || fail "the older doorbell must log stood-down: $(cat "$dir/state/.resume-doorbell.log")"
  [ ! -e "$dir/state/.resume-doorbell.lock" ] || fail "the doorbell lock was left behind after the takeover"

  # A second doorbell under the same context still stands down for the holder.
  dir=$(make_home same-context-second)
  printf 'source=compact\nlock_pid=%s\nat=1\n' "$(sed -n 1p "$dir/state/.lock")" > "$dir/state/.context-epoch"
  SETTLE=1 run_doorbell "$dir" --source compact &
  pid=$!
  wait_for_doorbell_lock "$dir"
  sleep 0.2
  run_doorbell "$dir" --source compact
  assert_contains "$(last_detail "$dir")" "another resume doorbell" "a same-context second doorbell must stand down for the holder"
  wait "$pid"
  [ "$(typed_count "$dir")" = 1 ] || fail "the holder must still deliver exactly once: $(cat "$dir/fake/keys" 2>/dev/null)"
  # The older holder stands down and removes the lock between the newer
  # doorbell's look and its next step: the newer one still takes the lock.
  dir=$(make_home older-holder-exits)
  printf 'old\n' > "$dir/state/old-epoch"
  printf 'source=compact\nlock_pid=%s\nat=2\n' "$(sed -n 1p "$dir/state/.lock")" > "$dir/state/.context-epoch"
  mkdir "$dir/state/.resume-doorbell.lock"
  sleep 30 >/dev/null 2>&1 &
  holder=$!
  printf '%s\n' "$holder" >> "$TMP_ROOT/sleepers"
  printf '%s\n' "$holder" > "$dir/state/.resume-doorbell.lock/pid"
  ln "$dir/state/old-epoch" "$dir/state/.resume-doorbell.lock/context-epoch.$holder"
  run_doorbell "$dir" --source compact --epoch-sum "$(cksum < "$dir/state/.context-epoch")" &
  pid=$!
  sleep 1
  [ "$(typed_count "$dir")" = 0 ] || fail "the newer doorbell must wait while the older one holds the lock"
  rm -rf "$dir/state/.resume-doorbell.lock"
  kill "$holder" 2>/dev/null || true
  wait "$pid"
  [ "$(typed_count "$dir")" = 1 ] || fail "the newer doorbell must deliver once the older one stood down: $(cat "$dir/state/.resume-doorbell.log")"
  [ "$(last_outcome "$dir")" = submitted ] || fail "outcome must be submitted, got: $(cat "$dir/state/.resume-doorbell.log")"
  # The older holder's pin vanishes first as it stands down, after the pin
  # grace, while its pid still answers: the newer one keeps waiting.
  dir=$(make_home older-holder-pin-vanishes)
  printf 'old\n' > "$dir/state/old-epoch"
  printf 'source=compact\nlock_pid=%s\nat=2\n' "$(sed -n 1p "$dir/state/.lock")" > "$dir/state/.context-epoch"
  mkdir "$dir/state/.resume-doorbell.lock"
  sleep 30 >/dev/null 2>&1 &
  holder=$!
  printf '%s\n' "$holder" >> "$TMP_ROOT/sleepers"
  printf '%s\n' "$holder" > "$dir/state/.resume-doorbell.lock/pid"
  ln "$dir/state/old-epoch" "$dir/state/.resume-doorbell.lock/context-epoch.$holder"
  run_doorbell "$dir" --source compact &
  pid=$!
  sleep 3.5
  rm -f "$dir/state/.resume-doorbell.lock/context-epoch.$holder"
  sleep 0.6
  [ -z "$(cat "$dir/state/.resume-doorbell.log" 2>/dev/null)" ] || fail "the newer doorbell must keep waiting while the older one exits: $(cat "$dir/state/.resume-doorbell.log")"
  kill "$holder" 2>/dev/null || true
  rm -rf "$dir/state/.resume-doorbell.lock"
  wait "$pid"
  [ "$(typed_count "$dir")" = 1 ] || fail "the newer doorbell must deliver after the older one exits: $(cat "$dir/state/.resume-doorbell.log")"
  [ "$(last_outcome "$dir")" = submitted ] || fail "outcome must be submitted, got: $(cat "$dir/state/.resume-doorbell.log")"
  # The older holder's exit removes its pid before its lock folder: the empty,
  # young lock is not mistaken for a new doorbell starting.
  dir=$(make_home older-holder-pid-removed)
  printf 'old\n' > "$dir/state/old-epoch"
  printf 'source=compact\nlock_pid=%s\nat=2\n' "$(sed -n 1p "$dir/state/.lock")" > "$dir/state/.context-epoch"
  mkdir "$dir/state/.resume-doorbell.lock"
  sleep 30 >/dev/null 2>&1 &
  holder=$!
  printf '%s\n' "$holder" >> "$TMP_ROOT/sleepers"
  printf '%s\n' "$holder" > "$dir/state/.resume-doorbell.lock/pid"
  ln "$dir/state/old-epoch" "$dir/state/.resume-doorbell.lock/context-epoch.$holder"
  run_doorbell "$dir" --source compact &
  pid=$!
  sleep 0.8
  rm -f "$dir/state/.resume-doorbell.lock/pid" "$dir/state/.resume-doorbell.lock/context-epoch.$holder"
  sleep 0.8
  [ -z "$(cat "$dir/state/.resume-doorbell.log" 2>/dev/null)" ] || fail "the newer doorbell must keep waiting while the older one removes its lock: $(cat "$dir/state/.resume-doorbell.log")"
  rmdir "$dir/state/.resume-doorbell.lock"
  kill "$holder" 2>/dev/null || true
  wait "$pid"
  [ "$(typed_count "$dir")" = 1 ] || fail "the newer doorbell must deliver after the older one removed its lock: $(cat "$dir/state/.resume-doorbell.log")"
  pass "resume doorbell: a doorbell for a newer context waits out an older one and delivers once; a same-context one stands down"
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

test_lock_taken_over_stands_down_and_keeps_the_new_lock() {
  local dir pid i other
  dir=$(make_home lock-taken-over)
  SETTLE=1 run_doorbell "$dir" --source compact &
  pid=$!
  i=0
  while [ ! -s "$dir/state/.resume-doorbell.lock/pid" ] && [ "$i" -lt 50 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  # A second doorbell that also judged an old lock stale replaced this one's.
  sleep 30 >/dev/null 2>&1 &
  other=$!
  printf '%s\n' "$other" >> "$TMP_ROOT/sleepers"
  printf '%s\n' "$other" > "$dir/state/.resume-doorbell.lock/pid"
  wait "$pid"
  [ "$(typed_count "$dir")" = 0 ] || fail "a doorbell whose lock another doorbell took must not type"
  assert_contains "$(last_detail "$dir")" "another resume doorbell took the lock" "stand-down must name the lock takeover"
  [ "$(cat "$dir/state/.resume-doorbell.lock/pid" 2>/dev/null)" = "$other" ] \
    || fail "a doorbell must not remove a lock that now names another doorbell"
  pass "resume doorbell: a lock another doorbell took over stands it down and is left to its new holder"
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

wait_for_doorbell_lock() {  # <dir>
  local i=0 pid
  while [ "$i" -lt 50 ]; do
    pid=$(cat "$1/state/.resume-doorbell.lock/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && [ -e "$1/state/.resume-doorbell.lock/context-epoch.$pid" ]; then
      return 0
    fi
    # A doorbell that started with no context epoch never writes the pin.
    if [ -n "$pid" ] && [ ! -e "$1/state/.context-epoch" ]; then
      return 0
    fi
    sleep 0.05
    i=$((i + 1))
  done
}

test_new_context_during_settle_stands_down() {
  local dir pid sum
  # A /clear during the settle replaces the epoch the doorbell started under.
  dir=$(make_home cleared-during-settle)
  printf 'source=compact\nlock_pid=%s\nat=1\n' "$(sed -n 1p "$dir/state/.lock")" > "$dir/state/.context-epoch"
  printf '{"type":"system"}\n' > "$dir/transcript.jsonl"
  SETTLE=1 run_doorbell "$dir" --source compact --transcript "$dir/transcript.jsonl" &
  pid=$!
  wait_for_doorbell_lock "$dir"
  printf 'source=clear\nlock_pid=%s\nat=2\n' "$(sed -n 1p "$dir/state/.lock")" > "$dir/state/.context-epoch.new"
  mv -f "$dir/state/.context-epoch.new" "$dir/state/.context-epoch"
  wait "$pid"
  [ "$(typed_count "$dir")" = 0 ] || fail "a doorbell must not type into a context cleared during its settle: $(cat "$dir/fake/keys")"
  [ "$(last_outcome "$dir")" = stood-down ] || fail "a cleared context must stand down, got: $(cat "$dir/state/.resume-doorbell.log")"
  assert_contains "$(last_detail "$dir")" "a new context began after the compaction" "the stand-down must name the new context"

  # A replacement with identical bytes (a repeat compaction in the same
  # second by the same owner) is still a new context.
  dir=$(make_home same-bytes-new-epoch)
  printf 'source=compact\nlock_pid=%s\nat=1\n' "$(sed -n 1p "$dir/state/.lock")" > "$dir/state/.context-epoch"
  SETTLE=1 run_doorbell "$dir" --source compact &
  pid=$!
  wait_for_doorbell_lock "$dir"
  cp "$dir/state/.context-epoch" "$dir/state/.context-epoch.new"
  mv -f "$dir/state/.context-epoch.new" "$dir/state/.context-epoch"
  wait "$pid"
  [ "$(typed_count "$dir")" = 0 ] || fail "a doorbell must not type after its epoch file was replaced, even with identical bytes"
  assert_contains "$(last_detail "$dir")" "a new context began after the compaction" "the stand-down must name the new context"

  # An epoch that appears after a start without one is a new context too.
  dir=$(make_home epoch-appeared)
  SETTLE=1 run_doorbell "$dir" --source compact &
  pid=$!
  wait_for_doorbell_lock "$dir"
  printf 'source=clear\nlock_pid=%s\nat=2\n' "$(sed -n 1p "$dir/state/.lock")" > "$dir/state/.context-epoch"
  wait "$pid"
  [ "$(typed_count "$dir")" = 0 ] || fail "a doorbell must not type after a context epoch appeared during its settle"
  assert_contains "$(last_detail "$dir")" "a new context began after the compaction" "the stand-down must name the new context"

  # A /clear between the hook's launch and the doorbell's start: the doorbell
  # is bound to the epoch the hook recorded, not the one it finds.
  dir=$(make_home cleared-before-start)
  printf 'source=compact\nlock_pid=%s\nat=1\n' "$(sed -n 1p "$dir/state/.lock")" > "$dir/state/.context-epoch"
  sum=$(cksum < "$dir/state/.context-epoch")
  printf 'source=clear\nlock_pid=%s\nat=2\n' "$(sed -n 1p "$dir/state/.lock")" > "$dir/state/.context-epoch.new"
  mv -f "$dir/state/.context-epoch.new" "$dir/state/.context-epoch"
  run_doorbell "$dir" --source compact --epoch-sum "$sum"
  [ "$(typed_count "$dir")" = 0 ] || fail "a doorbell must not type into a context cleared before it started: $(cat "$dir/fake/keys")"
  assert_contains "$(last_detail "$dir")" "a new context began after the compaction" "the stand-down must name the new context"
  [ ! -e "$dir/state/.resume-doorbell.lock" ] || fail "a doorbell for a gone context must not hold the lock"

  # An unchanged epoch still lets an idle session get its line, with or
  # without the hook's recorded sum.
  dir=$(make_home epoch-unchanged)
  printf 'source=compact\nlock_pid=%s\nat=1\n' "$(sed -n 1p "$dir/state/.lock")" > "$dir/state/.context-epoch"
  run_doorbell "$dir" --source compact --epoch-sum "$(cksum < "$dir/state/.context-epoch")"
  [ "$(typed_count "$dir")" = 1 ] || fail "an unchanged context epoch must not block the line"
  [ "$(last_outcome "$dir")" = submitted ] || fail "outcome must be submitted, got: $(cat "$dir/state/.resume-doorbell.log")"
  dir=$(make_home epoch-unchanged-no-sum)
  printf 'source=compact\nlock_pid=%s\nat=1\n' "$(sed -n 1p "$dir/state/.lock")" > "$dir/state/.context-epoch"
  run_doorbell "$dir" --source compact
  [ "$(last_outcome "$dir")" = submitted ] || fail "outcome must be submitted without a sum, got: $(cat "$dir/state/.resume-doorbell.log")"
  pass "resume doorbell: a /clear or a new context epoch before the start or during the settle stands it down; an unchanged epoch still delivers"
}

test_resubmit_rechecks_posture_after_a_pending_send() {
  local dir case_name reason
  for case_name in away away-contract lock-moved cleared; do
    dir=$(make_home "resubmit-$case_name")
    printf 'source=compact\nlock_pid=%s\nat=1\n' "$(sed -n 1p "$dir/state/.lock")" > "$dir/state/.context-epoch"
    printf '1\n' > "$dir/fake/drops"
    printf '%s' "$case_name" > "$dir/fake/posture-after-drop"
    run_doorbell "$dir" --source compact
    [ "$(typed_count "$dir")" = 1 ] || fail "$case_name: the first send must have typed the line once"
    [ "$(enter_count "$dir")" = 0 ] || fail "$case_name: no resubmit Enter may follow a posture change: $(cat "$dir/fake/keys")"
    [ "$(last_outcome "$dir")" = unverified ] || fail "$case_name: a withheld resubmit must log unverified, got: $(cat "$dir/state/.resume-doorbell.log")"
    case "$case_name" in
      away|away-contract) reason='an away or quiet record exists' ;;
      lock-moved) reason='the session lock changed owner' ;;
      cleared) reason='a new context began after the compaction' ;;
    esac
    assert_contains "$(last_detail "$dir")" "resubmit withheld" "$case_name: the log must say the resubmit was withheld"
    assert_contains "$(last_detail "$dir")" "$reason" "$case_name: the log must name the posture change"
  done
  pass "resume doorbell: an away record, a moved session lock, or a new context after a pending first send withholds every resubmit Enter"
}

test_posture_change_during_idle_reads_withholds_the_first_send() {
  local dir case_name reason
  for case_name in away lock-moved cleared; do
    dir=$(make_home "idle-reads-$case_name")
    printf 'source=compact\nlock_pid=%s\nat=1\n' "$(sed -n 1p "$dir/state/.lock")" > "$dir/state/.context-epoch"
    printf '%s' "$case_name" > "$dir/fake/posture-during-idle"
    run_doorbell "$dir" --source compact
    [ "$(typed_count "$dir")" = 0 ] || fail "$case_name: a posture change during the idle reads must withhold the first send: $(cat "$dir/fake/keys")"
    [ "$(last_outcome "$dir")" = stood-down ] || fail "$case_name: outcome must be stood-down, got: $(cat "$dir/state/.resume-doorbell.log")"
    case "$case_name" in
      away) reason='an away or quiet record exists' ;;
      lock-moved) reason='the session lock changed owner' ;;
      cleared) reason='a new context began after the compaction' ;;
    esac
    assert_contains "$(last_detail "$dir")" "$reason" "$case_name: the stand-down must name the change"
  done
  pass "resume doorbell: an away record, a moved session lock, or a new context during the idle reads withholds the first send"
}

test_posture_change_inside_the_send_withholds_the_keystroke() {
  local dir case_name reason
  for case_name in away lock-moved cleared; do
    case "$case_name" in
      away) reason='an away or quiet record exists' ;;
      lock-moved) reason='the session lock changed owner' ;;
      cleared) reason='a new context began after the compaction' ;;
    esac
    # During the send helper's own reads, before it types.
    dir=$(make_home "send-reads-$case_name")
    printf 'source=compact\nlock_pid=%s\nat=1\n' "$(sed -n 1p "$dir/state/.lock")" > "$dir/state/.context-epoch"
    printf '%s' "$case_name" > "$dir/fake/posture-during-send"
    run_doorbell "$dir" --source compact
    [ "$(typed_count "$dir")" = 0 ] || fail "$case_name: a posture change inside the send must withhold the typing: $(cat "$dir/fake/keys")"
    [ "$(last_outcome "$dir")" = stood-down ] || fail "$case_name: outcome must be stood-down, got: $(cat "$dir/state/.resume-doorbell.log")"
    assert_contains "$(last_detail "$dir")" "the send was withheld before typing: $reason" "$case_name: the stand-down must name the withheld send"

    # After typing, before the helper's Enter.
    dir=$(make_home "send-enter-$case_name")
    printf 'source=compact\nlock_pid=%s\nat=1\n' "$(sed -n 1p "$dir/state/.lock")" > "$dir/state/.context-epoch"
    printf '%s' "$case_name" > "$dir/fake/posture-before-enter"
    run_doorbell "$dir" --source compact
    [ "$(typed_count "$dir")" = 1 ] || fail "$case_name: the line was typed before the change"
    [ "$(cat "$dir/fake/composer")" = "$(grep '^text' "$dir/fake/keys" | cut -f3-)" ] \
      || fail "$case_name: the withheld Enter must leave the line unsubmitted"
    [ "$(enter_count "$dir")" = 0 ] || fail "$case_name: no resubmit Enter may follow: $(cat "$dir/fake/keys")"
    [ "$(last_outcome "$dir")" = unverified ] || fail "$case_name: outcome must be unverified, got: $(cat "$dir/state/.resume-doorbell.log")"
    assert_contains "$(last_detail "$dir")" "a keystroke was withheld after typing: $reason" "$case_name: the log must name the withheld Enter"

    # Inside the adapter's keystroke function, after its own endpoint read.
    dir=$(make_home "send-target-ready-$case_name")
    printf 'source=compact\nlock_pid=%s\nat=1\n' "$(sed -n 1p "$dir/state/.lock")" > "$dir/state/.context-epoch"
    printf '%s' "$case_name" > "$dir/fake/posture-in-target-ready"
    run_doorbell "$dir" --source compact
    [ "$(typed_count "$dir")" = 0 ] || fail "$case_name: a posture change in the adapter's own read must withhold the typing: $(cat "$dir/fake/keys")"
    [ "$(last_outcome "$dir")" = stood-down ] || fail "$case_name: outcome must be stood-down, got: $(cat "$dir/state/.resume-doorbell.log")"
    assert_contains "$(last_detail "$dir")" "the send was withheld before typing: $reason" "$case_name: the stand-down must name the withheld send"
  done

  # During the resubmit loop's composer read, before its Enter.
  dir=$(make_home resubmit-during-holds)
  printf 'source=compact\nlock_pid=%s\nat=1\n' "$(sed -n 1p "$dir/state/.lock")" > "$dir/state/.context-epoch"
  printf '1\n' > "$dir/fake/drops"
  printf 'away' > "$dir/fake/posture-during-holds"
  run_doorbell "$dir" --source compact
  [ "$(enter_count "$dir")" = 0 ] || fail "a posture change during the resubmit composer read must withhold the Enter: $(cat "$dir/fake/keys")"
  [ "$(last_outcome "$dir")" = unverified ] || fail "outcome must be unverified, got: $(cat "$dir/state/.resume-doorbell.log")"
  assert_contains "$(last_detail "$dir")" "resubmit withheld" "the log must say the resubmit was withheld"
  pass "resume doorbell: a posture change inside the send helper, the adapter, or the resubmit composer read withholds the next keystroke"
}

test_replacement_session_is_not_the_target() {
  local dir
  # The launching session recorded the epoch and exited; a replacement
  # session took the session lock before the doorbell started.
  dir=$(make_home replacement-session)
  printf 'source=compact\nlock_pid=1\nat=1\n' > "$dir/state/.context-epoch"
  run_doorbell "$dir" --source compact --epoch-sum "$(cksum < "$dir/state/.context-epoch")"
  [ "$(typed_count "$dir")" = 0 ] || fail "a doorbell must not type into a session that did not record its context: $(cat "$dir/fake/keys")"
  [ "$(last_outcome "$dir")" = stood-down ] || fail "outcome must be stood-down, got: $(cat "$dir/state/.resume-doorbell.log")"
  assert_contains "$(last_detail "$dir")" "the session lock changed owner" "the stand-down must name the owner change"
  pass "resume doorbell: a session other than the one that recorded the context gets nothing"
}

# Two fake herdr clients on PATH: the first is older than the running server,
# refuses every operational command with protocol_mismatch and applies the
# fixture's posture change while client selection reads its status; the second
# is compatible and types into the file-backed composer.
make_herdr_client_pair() {  # <dir>
  mkdir -p "$1/clients/stale" "$1/clients/current"
  cat > "$1/clients/stale/herdr" <<'CLIENT'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "status --json" ]; then
  if [ -e "$FAKE_DIR/posture-during-select" ]; then
    case "$(cat "$FAKE_DIR/posture-during-select")" in
      away) : > "$FAKE_DIR/../state/.afk" ;;
      lock-moved) printf '1\n' > "$FAKE_DIR/../state/.lock" ;;
      cleared) printf 'source=clear\n' > "$FAKE_DIR/../state/.context-epoch.new" \
        && mv -f "$FAKE_DIR/../state/.context-epoch.new" "$FAKE_DIR/../state/.context-epoch" ;;
    esac
    rm -f "$FAKE_DIR/posture-during-select"
  fi
  printf '{"client":{"protocol":20},"server":{"running":true,"protocol":22,"compatible":false}}\n'
  exit 0
fi
printf '{"error":{"code":"protocol_mismatch"}}\n' >&2
exit 1
CLIENT
  cat > "$1/clients/current/herdr" <<'CLIENT'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'status --json') printf '{"client":{"protocol":22},"server":{"running":true,"protocol":22,"compatible":true}}\n' ;;
  'pane send-text')
    printf 'text\t%s\t%s\n' "$3" "$4" >> "$FAKE_DIR/keys"
    printf '%s' "$4" > "$FAKE_DIR/composer"
    ;;
  'pane send-keys')
    [ -n "${FAKE_HELPER_ENTER:-}" ] || printf 'key\t%s\t%s\n' "$3" "$4" >> "$FAKE_DIR/keys"
    : > "$FAKE_DIR/composer"
    ;;
esac
CLIENT
  chmod +x "$1/clients/stale/herdr" "$1/clients/current/herdr"
  : > "$1/fake/real-cli"
}

test_protocol_mismatch_retry_rechecks_posture() {
  local dir case_name reason
  # No change during selection: the retry on the compatible client delivers.
  dir=$(make_home mismatch-retry)
  make_herdr_client_pair "$dir"
  PATH="$dir/clients/stale:$dir/clients/current:$PATH" run_doorbell "$dir" --source compact
  [ "$(typed_count "$dir")" = 1 ] || fail "a protocol_mismatch send must still deliver once on the compatible client: $(cat "$dir/fake/keys" 2>/dev/null)"
  [ "$(last_outcome "$dir")" = submitted ] || fail "outcome must be submitted after the retry, got: $(cat "$dir/state/.resume-doorbell.log")"
  for case_name in away lock-moved cleared; do
    case "$case_name" in
      away) reason='an away or quiet record exists' ;;
      lock-moved) reason='the session lock changed owner' ;;
      cleared) reason='a new context began after the compaction' ;;
    esac
    dir=$(make_home "mismatch-select-$case_name")
    printf 'source=compact\nlock_pid=%s\nat=1\n' "$(sed -n 1p "$dir/state/.lock")" > "$dir/state/.context-epoch"
    make_herdr_client_pair "$dir"
    printf '%s' "$case_name" > "$dir/fake/posture-during-select"
    PATH="$dir/clients/stale:$dir/clients/current:$PATH" run_doorbell "$dir" --source compact
    [ ! -e "$dir/fake/posture-during-select" ] || fail "$case_name: the fixture never reached client selection"
    [ "$(typed_count "$dir")" = 0 ] || fail "$case_name: a posture change during client selection must withhold the retried send: $(cat "$dir/fake/keys")"
    [ "$(last_outcome "$dir")" = stood-down ] || fail "$case_name: outcome must be stood-down, got: $(cat "$dir/state/.resume-doorbell.log")"
    assert_contains "$(last_detail "$dir")" "the send was withheld before typing: $reason" "$case_name: the stand-down must name the withheld send"
  done
  pass "resume doorbell: a protocol_mismatch retry re-checks posture after client selection; an unchanged posture still delivers"
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

test_an_operator_draft_survives_an_unproven_payload_check() {
  local dir
  dir=$(make_home operator-draft)
  : > "$dir/fake/operator-joins"
  run_doorbell "$dir" --source compact
  [ "$(typed_count "$dir")" = 1 ] || fail "the doorbell must type its line once: $(cat "$dir/fake/keys")"
  ! grep -q 'C-u' "$dir/fake/keys" \
    || fail "a failed payload check must not press Ctrl+U on the composer: $(cat "$dir/fake/keys")"
  grep -qF 'operator draft' "$dir/fake/composer" \
    || fail "the operator's draft must survive the aborted submit: $(cat "$dir/fake/composer")"
  [ "$(last_outcome "$dir")" = unverified ] \
    || fail "an aborted submit that erased nothing must log unverified, got: $(cat "$dir/state/.resume-doorbell.log")"
  assert_contains "$(last_detail "$dir")" "refused" "the log must say the composer clear was refused"
  pass "resume doorbell: an operator draft typed during the settle survives a failed payload check; the composer is never erased"
}

test_unproven_verdicts_send_no_extra_enter() {
  local dir verdict
  for verdict in unknown unconfirmed; do
    dir=$(make_home "unproven-$verdict")
    printf '%s\n' "$verdict" > "$dir/fake/submit-verdict"
    run_doorbell "$dir" --source compact
    [ "$(typed_count "$dir")" = 1 ] || fail "$verdict: the first send must type the line once: $(cat "$dir/fake/keys")"
    [ "$(enter_count "$dir")" = 0 ] \
      || fail "$verdict: an unproven verdict must send zero extra Enters: $(cat "$dir/fake/keys")"
    [ "$(last_outcome "$dir")" = unverified ] \
      || fail "$verdict: an unproven verdict must log unverified, got: $(cat "$dir/state/.resume-doorbell.log")"
  done
  pass "resume doorbell: an unknown or unconfirmed first verdict sends zero resubmit Enters and finishes unverified"
}

test_idle_session_gets_one_line_and_submits
test_unsafe_targets_stand_down_and_type_nothing
test_idle_needs_native_idle_and_a_quiet_transcript
test_turn_after_the_compaction_boundary_stands_down
test_changed_lock_owner_stands_down
test_lock_taken_over_stands_down_and_keeps_the_new_lock
test_dropped_enter_is_resubmitted_only_while_ours
test_new_context_during_settle_stands_down
test_resubmit_rechecks_posture_after_a_pending_send
test_newer_context_waits_out_an_older_doorbell
test_posture_change_during_idle_reads_withholds_the_first_send
test_posture_change_inside_the_send_withholds_the_keystroke
test_replacement_session_is_not_the_target
test_protocol_mismatch_retry_rechecks_posture
test_second_doorbell_types_nothing_while_one_runs
test_an_operator_draft_survives_an_unproven_payload_check
test_unproven_verdicts_send_no_extra_enter
