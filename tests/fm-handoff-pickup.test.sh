#!/usr/bin/env bash
# Behavior tests for bin/fm-handoff-pickup.sh. The launcher records a
# verified transfer and does not start this command. These tests drive
# pickup itself: a wrong sha256 stops before any signal, a predecessor
# whose start time or harness shape does not match is left alive, and a
# record that names this successor before the lock moves lets pickup end
# that predecessor and take the session lock.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PICKUP="$ROOT/bin/fm-handoff-pickup.sh"
TMP_ROOT=$(fm_test_tmproot fm-handoff-pickup)
PRED_PID=''
SUCC_PID=''
cleanup_pickup_test() {
  [ -z "$SUCC_PID" ] || kill "$SUCC_PID" 2>/dev/null || true
  [ -z "$PRED_PID" ] || kill "$PRED_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup_pickup_test EXIT

LAB="$TMP_ROOT/home"
PRED_BIN="$TMP_ROOT/pred-bin"
mkdir -p "$LAB/state" "$LAB/config" "$LAB/data" "$PRED_BIN"
ln -s /bin/bash "$PRED_BIN/claude"

cat > "$TMP_ROOT/pred-sleep.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$$" > "$1"
sleep 3600 &
child=$!
trap 'kill "$child" 2>/dev/null || true; exit 0' TERM INT
wait "$child"
EOF
cat > "$TMP_ROOT/pred-detach.sh" <<'EOF'
#!/bin/bash
"$3" "$1" "$2" >/dev/null 2>&1 &
exit 0
EOF

handoff_sha() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$LAB/data/handoff.md" | awk '{print $1}'
  else
    sha256sum "$LAB/data/handoff.md" | awk '{print $1}'
  fi
}

read_start() { # <pid>
  local i start
  for i in 1 2 3 4 5 6 7 8 9 10; do
    start=$(python3 "$ROOT/bin/fm-session-process.py" start "$1" 2>/dev/null || true)
    if [ -n "$start" ]; then
      printf '%s' "$start"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

start_detached_predecessor() {
  local i pid ppid
  rm -f "$TMP_ROOT/pred.pid"
  "$PRED_BIN/claude" "$TMP_ROOT/pred-detach.sh" "$TMP_ROOT/pred-sleep.sh" "$TMP_ROOT/pred.pid" "$PRED_BIN/claude" >/dev/null 2>&1
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    pid=$(cat "$TMP_ROOT/pred.pid" 2>/dev/null || true)
    case "$pid" in
      '' | *[!0-9]*) sleep 0.1; continue ;;
    esac
    kill -0 "$pid" 2>/dev/null || { sleep 0.1; continue; }
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ "$ppid" = 1 ]; then
      PRED_PID=$pid
      return 0
    fi
    sleep 0.1
  done
  return 1
}

write_predecessor_lock() { # <pid> [anchor_start]
  printf '%s\n' "$1" > "$LAB/state/.lock"
  if [ -n "${2:-}" ]; then
    printf '\nanchor_pid=%s\nanchor_start=%s\n' "$1" "$2" > "$LAB/state/.lock-session"
  else
    rm -f "$LAB/state/.lock-session"
  fi
}

reset_lab() { # harness | sleep
  local kind=${1:-harness} start
  [ -z "$SUCC_PID" ] || kill "$SUCC_PID" 2>/dev/null || true
  SUCC_PID=''
  [ -z "$PRED_PID" ] || kill "$PRED_PID" 2>/dev/null || true
  PRED_PID=''
  rm -f "$LAB/state/.handoff-successor" "$LAB/state/.lock" "$LAB/state/.lock-session" "$TMP_ROOT/pred.pid"
  printf '# Handoff\n\nContinue the work.\n' > "$LAB/data/handoff.md"
  if [ "$kind" = sleep ]; then
    sleep 300 &
    PRED_PID=$!
    write_predecessor_lock "$PRED_PID"
    return 0
  fi
  start_detached_predecessor || fail "could not start a detached harness predecessor"
  start=$(read_start "$PRED_PID") || fail "could not read the predecessor start time"
  write_predecessor_lock "$PRED_PID" "$start"
}

run_pickup() { # <sha> <mode>
  env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID -u CODEX_THREAD_ID -u CODEX_SESSION_ID \
    FM_TEST_SEAM=1 FM_HOME="$LAB" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config" \
    FM_HANDOFF_PICKUP_RECORD_WAIT_SECS=3 \
    FM_HANDOFF_PICKUP_GRACE_SECS=0 \
    FM_HANDOFF_PICKUP_DEATH_WAIT_SECS=2 \
    bash "$PICKUP" "$LAB/data/handoff.md" "$1" "$2"
}

test_sha_mismatch_stops_before_any_signal() {
  local out rc sha
  reset_lab harness
  sha=$(handoff_sha)
  rc=0
  out=$(run_pickup "${sha%?}0" bypass 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a mismatched sha256 must refuse, got success: $out"
  assert_contains "$out" "does not match" "the refusal names the hash mismatch"
  kill -0 "$PRED_PID" 2>/dev/null || fail "a hash mismatch must not signal the predecessor"
  [ ! -e "$LAB/state/.handoff-successor" ] || fail "a hash mismatch must not write a successor record"
  kill "$PRED_PID" 2>/dev/null || true
  PRED_PID=''
  pass "a successor that is given the wrong handoff sha256 stops and leaves the predecessor alive"
}

test_identity_mismatch_refuses_to_signal() {
  local out rc sha before
  reset_lab harness
  write_predecessor_lock "$PRED_PID" "not-a-start-time"
  before=$(head -n 1 "$LAB/state/.lock")
  sha=$(handoff_sha)
  rc=0
  out=$(run_pickup "$sha" bypass 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a mismatched predecessor identity must refuse, got success: $out"
  assert_contains "$out" "does not match" "the refusal names the identity mismatch"
  kill -0 "$PRED_PID" 2>/dev/null || fail "a mismatched predecessor must stay alive"
  [ "$(head -n 1 "$LAB/state/.lock")" = "$before" ] || fail "a refusal must not take the session lock"
  kill "$PRED_PID" 2>/dev/null || true
  PRED_PID=''
  pass "a live predecessor whose start time does not match the lock is not signaled"
}

test_non_harness_predecessor_is_not_signaled() {
  local out rc sha before
  reset_lab sleep
  before=$(head -n 1 "$LAB/state/.lock")
  sha=$(handoff_sha)
  rc=0
  out=$(run_pickup "$sha" bypass 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a non-harness predecessor must refuse, got success: $out"
  assert_contains "$out" "not a harness" "the refusal says the predecessor is not a harness"
  kill -0 "$PRED_PID" 2>/dev/null || fail "a non-harness predecessor must stay alive"
  [ "$(head -n 1 "$LAB/state/.lock")" = "$before" ] || fail "a refusal must not take the session lock"
  kill "$PRED_PID" 2>/dev/null || true
  wait "$PRED_PID" 2>/dev/null || true
  PRED_PID=''
  pass "an alive predecessor that is not a harness is not signaled and keeps the lock"
}

test_record_before_transfer_ends_predecessor_and_takes_lock() {
  local sha lock_pid i state
  reset_lab harness
  sha=$(handoff_sha)
  # exec keeps this pid through the claude-symlink re-exec, so the launch
  # record can name the successor before the lock moves.
  (
    unset CLAUDE_PID CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID CODEX_SESSION_ID
    export FM_TEST_SEAM=1 FM_HANDOFF_PICKUP_NO_EXEC=1
    export FM_HOME="$LAB" FM_ROOT_OVERRIDE="$ROOT"
    export FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config"
    export FM_HANDOFF_PICKUP_RECORD_WAIT_SECS=8
    export FM_HANDOFF_PICKUP_GRACE_SECS=0
    export FM_HANDOFF_PICKUP_DEATH_WAIT_SECS=4
    exec bash "$PICKUP" "$LAB/data/handoff.md" "$sha" bypass
  ) >"$TMP_ROOT/pickup.out" 2>"$TMP_ROOT/pickup.err" &
  SUCC_PID=$!
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    kill -0 "$SUCC_PID" 2>/dev/null || break
    ps -o args= -p "$SUCC_PID" 2>/dev/null | grep -F -q -e "$LAB/data/handoff.md" && break
    sleep 0.1
  done
  kill -0 "$SUCC_PID" 2>/dev/null || fail "pickup exited before the launch record could name it: $(cat "$TMP_ROOT/pickup.err" 2>/dev/null)"
  printf 'pid=%s\nhandoff=%s\n' "$SUCC_PID" "$LAB/data/handoff.md" > "$LAB/state/.handoff-successor"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
           21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
    lock_pid=$(head -n 1 "$LAB/state/.lock" 2>/dev/null | tr -cd '0-9')
    if [ "$lock_pid" = "$SUCC_PID" ]; then
      break
    fi
    sleep 0.25
  done
  [ "$(head -n 1 "$LAB/state/.lock" 2>/dev/null | tr -cd '0-9')" = "$SUCC_PID" ] \
    || fail "pickup did not take the lock (lock=$(head -n 1 "$LAB/state/.lock" 2>/dev/null || true) err=$(cat "$TMP_ROOT/pickup.err" 2>/dev/null) out=$(cat "$TMP_ROOT/pickup.out" 2>/dev/null))"
  if kill -0 "$PRED_PID" 2>/dev/null; then
    state=$(ps -o stat= -p "$PRED_PID" 2>/dev/null | awk 'NR == 1 { print $1 }')
    case "$state" in
      '' | Z*) ;;
      *) fail "the predecessor must be gone after pickup takes the lock (state=$state)" ;;
    esac
  fi
  kill "$SUCC_PID" 2>/dev/null || true
  wait "$SUCC_PID" 2>/dev/null || true
  SUCC_PID=''
  PRED_PID=''
  pass "a launch record written before the lock moves lets pickup end the predecessor and take the lock"
}

test_sha_mismatch_stops_before_any_signal
test_identity_mismatch_refuses_to_signal
test_non_harness_predecessor_is_not_signaled
test_record_before_transfer_ends_predecessor_and_takes_lock
