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
cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
sleep 60 &
wait
EOF
chmod +x "$FAKEBIN/claude"

# Fake orca: run the --command it was handed, with the fake harness on
# PATH, detached like a real new terminal. FM_FAKE_ORCA_MODE=noop accepts
# the create and launches nothing.
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
printf '%s\n' "$cmd" > "$FM_FAKE_ORCA_CMD"
[ "${FM_FAKE_ORCA_MODE:-launch}" = noop ] && { printf '{"terminal":"term_fake"}\n'; exit 0; }
[ -n "$cmd" ] || exit 1
PATH="$here:$PATH" bash -c "$cmd" >/dev/null 2>&1 &
printf '{"terminal":"term_fake"}\n'
EOF
chmod +x "$FAKEBIN/orca"

PRED_PID=''
SUCC_PID=''

reset_lab() {
  [ -z "$SUCC_PID" ] || { kill "$SUCC_PID" 2>/dev/null; SUCC_PID=''; }
  rm -f "$LAB/state/.handoff-successor" "$LAB/config/backend" "$TMP_ROOT/orca-cmd"
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
    FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config" \
    "$@" bash "$LAUNCHER" "$LAB/data/handoff.md"
}

test_success_path_records_a_live_successor() {
  local out rc sha8
  reset_lab
  rc=0
  out=$(run_launcher) || rc=$?
  [ "$rc" -eq 0 ] || fail "a launchable handoff must succeed (rc=$rc): $out"
  [ -f "$LAB/state/.handoff-successor" ] || fail "success must write state/.handoff-successor"
  SUCC_PID=$(sed -n 's/^pid=//p' "$LAB/state/.handoff-successor")
  case "$SUCC_PID" in '' | *[!0-9]*) fail "the record must name a numeric successor pid, got: $SUCC_PID" ;; esac
  [ "$SUCC_PID" != "$PRED_PID" ] || fail "the successor pid must not be the predecessor pid"
  kill -0 "$SUCC_PID" 2>/dev/null || fail "the recorded successor pid $SUCC_PID must be alive"
  assert_contains "$(cat "$LAB/state/.handoff-successor")" "handoff=$LAB/data/handoff.md" "the record names the handoff document"
  sha8=$(shasum -a 256 "$LAB/data/handoff.md" 2>/dev/null | cut -c1-8)
  [ -n "$sha8" ] || sha8=$(sha256sum "$LAB/data/handoff.md" | cut -c1-8)
  assert_contains "$out" "sha8=$sha8" "the launch reports the handoff sha8"
  assert_contains "$(cat "$TMP_ROOT/orca-cmd")" "$LAB/data/handoff.md" "the successor prompt names the handoff path"
  assert_contains "$(cat "$TMP_ROOT/orca-cmd")" "$sha8" "the successor prompt carries the handoff sha8"
  assert_contains "$(cat "$TMP_ROOT/orca-cmd")" "bin/fm-session-start.sh" "the successor prompt runs session start after the predecessor dies"
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
  local out rc
  reset_lab
  rc=0
  out=$(run_launcher FM_FAKE_ORCA_MODE=noop FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS=2 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a successor that never appears must fail the launch: $out"
  assert_contains "$out" "never appeared" "the failure says the successor never appeared"
  [ ! -e "$LAB/state/.handoff-successor" ] || fail "no successor record may be written when nobody appeared"
  kill -0 "$PRED_PID" 2>/dev/null || fail "the launcher must never kill or interrupt the current session"
  kill "$PRED_PID" 2>/dev/null; wait "$PRED_PID" 2>/dev/null
  pass "a successor that never appears fails loudly and leaves the record unwritten"
}

test_success_path_records_a_live_successor
test_unknown_backend_refuses_rather_than_guess
test_successor_never_appears_records_nothing
