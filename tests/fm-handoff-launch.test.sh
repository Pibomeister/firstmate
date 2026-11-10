#!/usr/bin/env bash
# Behavior tests for the firstmate-owned successor launcher
# (bin/fm-handoff-launch.sh, issue 116): a written handoff launches a live
# successor on the home's recorded backend and records it in
# state/.handoff-successor, an unknown backend refuses rather than guess,
# and a successor that never appears records nothing. The terminal and
# harness binaries are fakes on PATH; the launcher runs for real.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAUNCHER="$ROOT/bin/fm-handoff-launch.sh"
TMP_ROOT=$(fm_test_tmproot fm-handoff-launch)
trap fm_test_cleanup EXIT

LAB="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$LAB/state" "$LAB/config" "$LAB/data" "$FAKEBIN"

# Fake successor harness: stay alive with the launch args visible, so the
# launcher's process-table wait can see the handoff path it was given.
# FM_FAKE_CLAUDE_MODE=crash exits at once, like a harness that dies at start.
cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${FM_FAKE_CLAUDE_MODE:-}" = crash ]; then sleep 0.2; exit 1; fi
sleep 60 &
wait
EOF
chmod +x "$FAKEBIN/claude"

# Fake orca: run the --command it was handed, with the fake harness on
# PATH, detached like a real new terminal. FM_FAKE_ORCA_MODE=noop accepts
# the create and launches nothing; first-fail fails only the first create;
# late holds the command until $FM_FAKE_ORCA_RELEASE exists, which the test
# creates only after the launcher returns. The late child signals once it has
# exec'd and the fake waits for that, because until then the fork still
# carries this create's arguments, handoff path included, and reads as a live
# successor. Each create appends one line to $FM_FAKE_ORCA_CMD.
cat > "$FAKEBIN/orca" <<'EOF'
#!/usr/bin/env bash
here=$(cd "$(dirname "$0")" && pwd)
cmd=''
while [ $# -gt 0 ]; do
  case "$1" in
    --command) cmd=$2; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$cmd" >> "$FM_FAKE_ORCA_CMD"
[ "${FM_FAKE_ORCA_MODE:-launch}" = noop ] && { printf '{"terminal":"term_fake"}\n'; exit 0; }
if [ "${FM_FAKE_ORCA_MODE:-launch}" = first-fail ] && [ "$(grep -c '' "$FM_FAKE_ORCA_CMD")" -le 1 ]; then
  exit 1
fi
[ -n "$cmd" ] || exit 1
if [ "${FM_FAKE_ORCA_MODE:-launch}" = late ]; then
  ready="$FM_FAKE_ORCA_RELEASE.ready"
  rm -f "$ready"
  FM_LATE_CMD=$cmd FM_LATE_READY=$ready PATH="$here:$PATH" bash -c '
    : > "$FM_LATE_READY"
    n=0
    while [ ! -e "$FM_FAKE_ORCA_RELEASE" ] && [ "$n" -lt 600 ]; do sleep 0.1; n=$((n + 1)); done
    [ -e "$FM_FAKE_ORCA_RELEASE" ] || exit 0
    exec bash -c "$FM_LATE_CMD"' >/dev/null 2>&1 &
  n=0
  while [ ! -e "$ready" ] && [ "$n" -lt 600 ]; do sleep 0.05; n=$((n + 1)); done
  printf '{"terminal":"term_fake"}\n'; exit 0
fi
PATH="$here:$PATH" bash -c "$cmd" >/dev/null 2>&1 &
printf '{"terminal":"term_fake"}\n'
EOF
chmod +x "$FAKEBIN/orca"

PRED_PID=''
SUCC_PID=''

reset_lab() {
  [ -z "$SUCC_PID" ] || { kill "$SUCC_PID" 2>/dev/null; SUCC_PID=''; }
  rm -f "$LAB/state/.handoff-successor" "$LAB/state/.handoff-launch-failed" "$LAB/config/backend" "$TMP_ROOT/orca-cmd"
  printf 'orca\n' > "$LAB/config/backend"
  printf '# Handoff\n\nContinue the work.\n' > "$LAB/data/handoff.md"
  sleep 60 &
  PRED_PID=$!
  printf '%s\n' "$PRED_PID" > "$LAB/state/.lock"
}

run_launcher() {  # [env assignments...] -- print output, set RC
  env -u FM_BACKEND PATH="$FAKEBIN:$PATH" FM_TEST_SEAM=1 \
    FM_HANDOFF_TEST_HARNESS=claude FM_FAKE_ORCA_CMD="$TMP_ROOT/orca-cmd" \
    FM_HOME="$LAB" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config" FM_HANDOFF_SETTLE_SECS=1 \
    "$@" bash "$LAUNCHER" "$LAB/data/handoff.md"
}

run_mode() {  # <mode args...> -- run the launcher in another mode, print output
  env PATH="$FAKEBIN:$PATH" FM_TEST_SEAM=1 FM_HOME="$LAB" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config" \
    FM_HANDOFF_AWAIT_SECS="${AWAIT_SECS:-3}" FM_HANDOFF_END_SETTLE_SECS="${END_SETTLE_SECS:-1}" FM_HANDOFF_END_WAIT_SECS=3 \
    bash "$LAUNCHER" "$@"
}

# fake_harness_pid: start a process the harness matcher reads as claude (a
# bash symlink named claude that stays a shell) and print its pid.
fake_harness_pid() {
  mkdir -p "$TMP_ROOT/fake-harness"
  ln -sf /bin/bash "$TMP_ROOT/fake-harness/claude"
  "$TMP_ROOT/fake-harness/claude" -c 'sleep 30; exit 0' </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

test_success_path_records_a_live_successor() {
  local out rc sha8 cmd
  reset_lab
  printf 'at=1 attempts=2 backend=orca handoff=x reason=old\n' > "$LAB/state/.handoff-launch-failed"
  rc=0
  out=$(run_launcher) || rc=$?
  [ "$rc" -eq 0 ] || fail "a launchable handoff must succeed (rc=$rc): $out"
  [ ! -e "$LAB/state/.handoff-launch-failed" ] || fail "a successful launch must clear an earlier launch-failure record"
  [ -f "$LAB/state/.handoff-successor" ] || fail "success must write state/.handoff-successor"
  SUCC_PID=$(sed -n 's/^pid=//p' "$LAB/state/.handoff-successor")
  case "$SUCC_PID" in '' | *[!0-9]*) fail "the record must name a numeric successor pid, got: $SUCC_PID" ;; esac
  [ "$SUCC_PID" != "$PRED_PID" ] || fail "the successor pid must not be the predecessor pid"
  kill -0 "$SUCC_PID" 2>/dev/null || fail "the recorded successor pid $SUCC_PID must be alive"
  assert_contains "$(cat "$LAB/state/.handoff-successor")" "handoff=$LAB/data/handoff.md" "the record names the handoff document"
  assert_contains "$(cat "$LAB/state/.handoff-successor")" "predecessor=$PRED_PID" "the record names the session it replaces"
  grep -qE '^launched=[0-9]+$' "$LAB/state/.handoff-successor" || fail "the record carries the launch time that leaves later orders to the successor's pickup"
  sha8=$(shasum -a 256 "$LAB/data/handoff.md" 2>/dev/null | cut -c1-8)
  [ -n "$sha8" ] || sha8=$(sha256sum "$LAB/data/handoff.md" | cut -c1-8)
  assert_contains "$out" "sha8=$sha8" "the launch reports the handoff sha8"
  assert_contains "$(cat "$TMP_ROOT/orca-cmd")" "$LAB/data/handoff.md" "the successor prompt names the handoff path"
  assert_contains "$(cat "$TMP_ROOT/orca-cmd")" "$sha8" "the successor prompt carries the handoff sha8"
  cmd=$(cat "$TMP_ROOT/orca-cmd")
  assert_contains "$cmd" "FM_HANDOFF_PREDECESSOR_PID=$PRED_PID claude" "the successor carries the predecessor pid for its session-start hook"
  # The prompt is the command's last word, shell-quoted by the launcher.
  # shellcheck disable=SC2016 # The inner shell expands these.
  cmd=$(bash -c 'eval "set -- $1"; printf "%s" "${!#}"' _ "$cmd")
  assert_contains "$cmd" "bin/fm-session-start.sh" "the successor prompt runs session start after the predecessor dies"
  assert_contains "$cmd" "--await-predecessor $PRED_PID" "the successor waits for the old session with the bounded wait"
  assert_contains "$cmd" "addendum" "the successor reads only the hashed document"
  assert_contains "$cmd" "bin/fm-crew-state.sh" "the successor re-checks worker and PR facts at pickup"
  assert_contains "$cmd" "bin/fm-order.sh pickup" "the successor re-checks open orders at pickup"
  assert_contains "$cmd" "once" "the successor runs session start once"
  kill -0 "$PRED_PID" 2>/dev/null || fail "the launcher must never kill or interrupt the current session"
  kill "$SUCC_PID" 2>/dev/null; SUCC_PID=''
  kill "$PRED_PID" 2>/dev/null; wait "$PRED_PID" 2>/dev/null
  pass "a written handoff launches a live successor and records its pid for the Stop gate"
}

test_unknown_backend_refuses_rather_than_guess() {
  local out rc
  reset_lab
  printf 'bogusbackend\n' > "$LAB/config/backend"
  rc=0
  out=$(run_launcher 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an unknown backend must refuse, got success: $out"
  assert_contains "$out" "bogusbackend" "the refusal names the unknown backend"
  [ ! -e "$LAB/state/.handoff-successor" ] || fail "a refused launch must not record a successor"
  [ ! -e "$TMP_ROOT/orca-cmd" ] || fail "a refused launch must not invoke the terminal launcher"
  kill "$PRED_PID" 2>/dev/null; wait "$PRED_PID" 2>/dev/null
  pass "an unknown recorded backend refuses rather than guessing another backend"
}

test_successor_never_appears_records_nothing() {
  local out rc failed="$LAB/state/.handoff-launch-failed"
  reset_lab
  rc=0
  out=$(run_launcher FM_FAKE_ORCA_MODE=noop FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS=1 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a successor that never appears must fail the launch: $out"
  assert_contains "$out" "never appeared" "the failure says the successor never appeared"
  [ ! -e "$LAB/state/.handoff-successor" ] || fail "no successor record may be written when nobody appeared"
  assert_equals 1 "$(grep -c '' "$TMP_ROOT/orca-cmd")" "a successor that never appears is not launched again"
  [ -f "$failed" ] || fail "a final launch failure must be recorded for the stop gate"
  assert_contains "$(cat "$failed")" "attempts=1" "the failure record names the attempts"
  assert_contains "$(cat "$failed")" "handoff=$LAB/data/handoff.md" "the failure record names the handoff"
  assert_contains "$out" "tell the captain" "the failure escalates to the captain"
  assert_contains "$out" "keep working" "the failure keeps the session working on auto-compaction"
  kill -0 "$PRED_PID" 2>/dev/null || fail "the launcher must never kill or interrupt the current session"

  rm -f "$failed" "$TMP_ROOT/orca-cmd"
  rc=0
  out=$(run_launcher FM_FAKE_CLAUDE_MODE=crash FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS=2 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a successor that dies at start must fail the launch: $out"
  [ ! -e "$LAB/state/.handoff-successor" ] || fail "a successor that died at start must never be recorded"
  [ -f "$failed" ] || fail "a successor that died at start must record the launch failure"
  kill "$PRED_PID" 2>/dev/null; wait "$PRED_PID" 2>/dev/null
  pass "a successor that never appears fails at once, one that dies at start fails, and both record the failure"
}

test_a_late_successor_is_never_joined_by_a_second() {
  local out rc pid n live release="$TMP_ROOT/late-release"
  reset_lab
  rm -f "$release" "$release.ready"
  rc=0
  out=$(run_launcher FM_FAKE_ORCA_MODE=late FM_FAKE_ORCA_RELEASE="$release" FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS=1 2>&1) || rc=$?
  : > "$release"
  [ "$rc" -ne 0 ] || fail "a successor that appears only after the timeout fails the launch: $out"
  n=0
  live=''
  while [ -z "$live" ] && [ "$n" -lt 60 ]; do
    sleep 0.1; n=$((n + 1))
    live=$(pgrep -f "$LAB/data/handoff.md" 2>/dev/null | tr '\n' ' ')
  done
  assert_equals 1 "$(grep -c '' "$TMP_ROOT/orca-cmd")" "a late successor is never joined by a second terminal"
  for pid in $live; do kill "$pid" 2>/dev/null; done
  pkill -f "$LAB/data/handoff.md" 2>/dev/null
  kill "$PRED_PID" 2>/dev/null; wait "$PRED_PID" 2>/dev/null
  rm -f "$release" "$release.ready"
  pass "a launch whose successor starts late opens only one terminal"
}

test_a_second_attempt_recovers_a_terminal_that_failed_to_open() {
  local out rc
  reset_lab
  rc=0
  out=$(run_launcher FM_FAKE_ORCA_MODE=first-fail FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS=2 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a second attempt must recover a terminal that failed to open (rc=$rc): $out"
  assert_contains "$out" "attempt 2" "the launch reports that it needed a second attempt"
  SUCC_PID=$(sed -n 's/^pid=//p' "$LAB/state/.handoff-successor")
  kill -0 "$SUCC_PID" 2>/dev/null || fail "the recorded successor pid must be alive"
  [ ! -e "$LAB/state/.handoff-launch-failed" ] || fail "a recovered launch records no failure"
  kill "$SUCC_PID" 2>/dev/null; SUCC_PID=''
  kill "$PRED_PID" 2>/dev/null; wait "$PRED_PID" 2>/dev/null
  pass "a second attempt recovers a first terminal that failed to open"
}

test_await_predecessor_is_bounded() {
  local out rc pred
  reset_lab
  kill "$PRED_PID" 2>/dev/null; wait "$PRED_PID" 2>/dev/null
  rc=0
  out=$(run_mode --await-predecessor "$PRED_PID" 2>&1) || rc=$?
  assert_equals 0 "$rc" "an ended predecessor ends the wait at once: $out"
  pred=$(fake_harness_pid)
  rc=0
  out=$(AWAIT_SECS=1 run_mode --await-predecessor "$pred" 2>&1) || rc=$?
  assert_equals 3 "$rc" "a predecessor still running after the bound reports 3: $out"
  assert_contains "$out" "still running" "the bounded wait says the old session still runs"
  ( sleep 1; kill "$pred" 2>/dev/null ) &
  rc=0
  out=$(AWAIT_SECS=10 run_mode --await-predecessor "$pred" 2>&1) || rc=$?
  assert_equals 0 "$rc" "the wait returns once the old session ends: $out"
  wait 2>/dev/null
  rc=0
  run_mode --await-predecessor nope >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "a non-numeric pid is a usage error"
  pass "the successor's wait for the old session is bounded and reports a still-running predecessor"
}

test_end_predecessor_skips_unless_safe() {
  local t="$TMP_ROOT/end-transcript" end="$LAB/state/.handoff-end" pred succ bytes
  reset_lab
  kill "$PRED_PID" 2>/dev/null; wait "$PRED_PID" 2>/dev/null
  printf '{"type":"assistant"}\n' > "$t"
  bytes=$(wc -c < "$t" | tr -d ' ')
  pred=$(fake_harness_pid)
  sleep 60 &
  succ=$!
  printf 'pid=%s\nhandoff=%s\n' "$succ" "$LAB/data/handoff.md" > "$LAB/state/.handoff-successor"
  printf '%s\n' "$succ" > "$LAB/state/.lock"
  run_mode --end-predecessor "$pred" "$t" "$bytes" >/dev/null 2>&1
  assert_contains "$(cat "$end")" "result=skipped" "a lock that moved to another session keeps the old session"
  kill -0 "$pred" 2>/dev/null || fail "the old session must survive a moved lock"
  printf '%s\n' "$pred" > "$LAB/state/.lock"
  kill "$succ" 2>/dev/null; wait "$succ" 2>/dev/null
  run_mode --end-predecessor "$pred" "$t" "$bytes" >/dev/null 2>&1
  assert_contains "$(cat "$end")" "result=skipped" "a dead successor keeps the old session"
  kill -0 "$pred" 2>/dev/null || fail "the old session must survive a dead successor"
  sleep 60 &
  succ=$!
  printf 'pid=%s\nhandoff=%s\n' "$succ" "$LAB/data/handoff.md" > "$LAB/state/.handoff-successor"
  run_mode --end-predecessor "$pred" "$t" "$bytes" >/dev/null 2>&1
  assert_contains "$(cat "$end")" "result=ended" "a quiet old session with a live successor is ended"
  ! kill -0 "$pred" 2>/dev/null || fail "the old session must be gone"
  kill "$succ" 2>/dev/null; wait "$succ" 2>/dev/null
  rm -f "$end" "$LAB/state/.handoff-successor"
  pass "the old session is ended only while it holds the lock, a live successor exists, and its transcript is quiet"
}

# The end re-checks orders after its settle: an open captain order recorded
# before the launch and missing from the successor's handoff keeps the old
# session alive, while an order recorded during the settle, after the launch,
# is left to the successor's pickup and does not.
test_end_predecessor_rechecks_the_order_gate() {
  local t="$TMP_ROOT/end-gate-transcript" end="$LAB/state/.handoff-end" pred succ bytes ender start older
  reset_lab
  kill "$PRED_PID" 2>/dev/null; wait "$PRED_PID" 2>/dev/null
  rm -rf "$LAB/data/orders" "$LAB/state/.order-handoff" "$end"
  printf '{"type":"assistant"}\n' > "$t"
  bytes=$(wc -c < "$t" | tr -d ' ')
  pred=$(fake_harness_pid)
  sleep 60 &
  succ=$!
  printf '%s\n' "$pred" > "$LAB/state/.lock"
  FM_HOME="$LAB" "$ROOT/bin/fm-order.sh" send --from test "order before the launch" >/dev/null \
    || fail "could not send the older order fixture"
  older=$(find "$LAB/data/orders/pending" -name '*.order' | sed 's#.*/##; s/\.order$//')
  sleep 1
  printf 'pid=%s\nhandoff=%s\nlaunched=%s\n' "$succ" "$LAB/data/handoff.md" "$(date +%s)" > "$LAB/state/.handoff-successor"
  run_mode --end-predecessor "$pred" "$t" "$bytes" >/dev/null 2>&1
  assert_contains "$(cat "$end")" "result=skipped" "an older order missing from the handoff keeps the old session"
  assert_contains "$(cat "$end")" "reason=order-gate" "the record names the order gate"
  kill -0 "$pred" 2>/dev/null || fail "the old session must survive an older order its handoff does not list"
  FM_HOME="$LAB" "$ROOT/bin/fm-order.sh" ack "$older" >/dev/null || fail "could not ack the older order"
  FM_HOME="$LAB" "$ROOT/bin/fm-order.sh" finish "$older" 'done' "handled" >/dev/null || fail "could not finish the older order"
  start=$(date +%s)
  END_SETTLE_SECS=6 run_mode --end-predecessor "$pred" "$t" "$bytes" >/dev/null 2>&1 &
  ender=$!
  FM_HOME="$LAB" "$ROOT/bin/fm-order.sh" send --from test "order during the settle" >/dev/null \
    || fail "could not send the order fixture"
  [ $(( $(date +%s) - start )) -lt 6 ] || fail "the order fixture took longer than the settle, so it did not land during it"
  wait "$ender"
  assert_contains "$(cat "$end")" "result=ended" "an order recorded after the launch is left to the successor's pickup"
  ! kill -0 "$pred" 2>/dev/null || fail "the old session must be gone"
  kill "$succ" 2>/dev/null; wait "$succ" 2>/dev/null
  rm -rf "$end" "$LAB/state/.handoff-successor" "$LAB/state/.order-handoff" "$LAB/data/orders"
  pass "the old session is ended only while its handoff lists every open captain order recorded before the launch"
}

test_stale_record_naming_the_current_session_still_launches() {
  local out rc
  reset_lab
  printf 'pid=%s\nhandoff=%s\n' "$PRED_PID" "$LAB/data/handoff.md" > "$LAB/state/.handoff-successor"
  rc=0
  out=$(run_launcher) || rc=$?
  [ "$rc" -eq 0 ] || fail "a stale record must not block a fresh launch (rc=$rc): $out"
  assert_contains "$out" "successor launched" "a stale record still launches a successor"
  SUCC_PID=$(sed -n 's/^pid=//p' "$LAB/state/.handoff-successor")
  [ "$SUCC_PID" != "$PRED_PID" ] || fail "the record must not name the current session as its own successor"
  kill -0 "$SUCC_PID" 2>/dev/null || fail "the recorded successor pid $SUCC_PID must be alive"
  kill "$SUCC_PID" 2>/dev/null; SUCC_PID=''
  kill "$PRED_PID" 2>/dev/null; wait "$PRED_PID" 2>/dev/null
  pass "a stale record naming the current session never stands in for a new successor"
}

test_success_path_records_a_live_successor
test_stale_record_naming_the_current_session_still_launches
test_unknown_backend_refuses_rather_than_guess
test_successor_never_appears_records_nothing
test_a_late_successor_is_never_joined_by_a_second
test_a_second_attempt_recovers_a_terminal_that_failed_to_open
test_await_predecessor_is_bounded
test_end_predecessor_skips_unless_safe
test_end_predecessor_rechecks_the_order_gate
