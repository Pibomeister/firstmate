#!/usr/bin/env bash
# Executable handoff regression and failure drill. All state and processes
# belong to a temporary home. The Orca transport is fake; lock and ack are real.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-handoff-launch)
trap 'test_cleanup' EXIT
test_cleanup() {
  test_cleanup_processes
  fm_test_cleanup
}
# shellcheck disable=SC2089 # Literal quotes deliberately exercise argv safety.
LAB="$TMP_ROOT/home ) ' quoting"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$LAB/state" "$LAB/config" "$LAB/data" "$LAB/bin" "$FAKEBIN"
git init -q "$LAB"
: > "$LAB/AGENTS.md"
ln -s /bin/bash "$FAKEBIN/claude"
# shellcheck disable=SC2090 # These are data values, never shell commands.
export LAB ROOT
export FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config"
export FM_ROOT_OVERRIDE="$ROOT" FM_HANDOFF_TEST_HARNESS=claude
# Lab budgets leave each attempt's half enough headroom for process startup,
# ack validation and lock work on a heavily loaded host. A success case ends
# at its ack, so its larger budget costs nothing on a healthy host. LAB_SLACK
# bounds how far past its budget the launcher may report failure, and
# LAB_STARTUP also covers predecessor startup.
LAB_FAIL_BUDGET=80 LAB_SUCCESS_BUDGET=300 LAB_SLACK=60 LAB_STARTUP=120
FM_TEST_STUB_MAX_BLOCK_SECONDS=$((LAB_SUCCESS_BUDGET + LAB_SLACK + LAB_STARTUP))
export FM_TEST_STUB_MAX_BLOCK_SECONDS
export FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS=$LAB_FAIL_BUDGET
export PATH="$FAKEBIN:$PATH" FM_HANDOFF_TEST_PIDS="$TMP_ROOT/pids"
unset FM_BACKEND FM_SESSION_ENDPOINT_META CLAUDE_PID CLAUDE_CODE_SESSION_ID TMUX TMUX_PANE ZELLIJ
# Lab Orca handles come from Orca terminals, as fm_supervisor_in_orca requires.
export TERM_PROGRAM=Orca
FM_HANDOFF_REAL_SLEEP=$(command -v sleep)
export FM_HANDOFF_REAL_SLEEP
cat > "$FAKEBIN/sleep" <<'EOF'
#!/usr/bin/env bash
if [ "${FM_HANDOFF_LAB_MODE:-}" = error-exit ] && [ "${1:-}" = 0.2 ] \
  && [ -f "$FM_HOME/state/attempts" ]; then exit 42; fi
# Interrupt the launcher's poll only after the successor commits its transfer.
if [ "${FM_HANDOFF_LAB_MODE:-}" = interrupt-after-ack ] && [ "${1:-}" = 0.2 ] && [ ! -e "$FM_HOME/state/polling" ] \
  && [ "$PPID" = "$(cat "$FM_HOME/launcher.pid" 2>/dev/null)" ]; then
  touch "$FM_HOME/state/polling"
  # Wait past the attempt's claim deadline, half the total budget.
  end=$((SECONDS + FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS / 2 + 10))
  while [ "$(cat "$FM_HOME/state/.lock")" = "$(cat "$FM_HOME/pred.pid")" ] \
    && [ "$SECONDS" -lt "$end" ]; do "$FM_HANDOFF_REAL_SLEEP" 0.1; done
  kill -TERM "$PPID"
  exit 0
fi
# Mark that the launcher is waiting for the claim lock a lab successor holds.
if [ "${1:-}" = 0.1 ] && [ -e "$FM_HOME/state/claim-held" ] \
  && [ "$PPID" = "$(cat "$FM_HOME/launcher.pid" 2>/dev/null)" ]; then
  touch "$FM_HOME/state/claim-wait"
fi
exec "$FM_HANDOFF_REAL_SLEEP" "$@"
EOF
chmod +x "$FAKEBIN/sleep"
FM_HANDOFF_REAL_RM=$(command -v rm) FM_HANDOFF_DELAY_BIN="$TMP_ROOT/delaybin"
export FM_HANDOFF_REAL_RM FM_HANDOFF_DELAY_BIN
mkdir -p "$FM_HANDOFF_DELAY_BIN"
cat > "$FM_HANDOFF_DELAY_BIN/rm" <<'EOF'
#!/usr/bin/env bash
# Delay a successor's post-commit lease retirement, still under the claim
# lock, until the launcher has given up waiting for that lock.
for arg; do
  case "$arg" in
    */.lease-*)
      touch "$FM_HOME/state/retire-delayed"
      while ! grep -q ' event=handoff_failed ' "$FM_HOME/state/handoff-events.log" 2>/dev/null \
        && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do "$FM_HANDOFF_REAL_SLEEP" 0.2; done ;;
  esac
done
exec "$FM_HANDOFF_REAL_RM" "$@"
EOF
chmod +x "$FM_HANDOFF_DELAY_BIN/rm"
cat > "$FAKEBIN/orca" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "$1 $2" = 'agent launch' ] || exit 91
shift 2
prompt=
while [ $# -gt 0 ]; do
  case "$1" in
    --prompt) prompt=$2; shift 2 ;;
    --agent|--worktree|--surface) shift 2 ;;
    --json) shift ;;
    *) exit 92 ;;
  esac
done
[ -n "$prompt" ] || exit 93
n=$(cat "$FM_HOME/state/attempts" 2>/dev/null || echo 0)
n=$((n+1)); echo "$n" > "$FM_HOME/state/attempts"
case "$FM_HANDOFF_LAB_MODE" in
  interrupt) kill -TERM "$(cat "$FM_HOME/launcher.pid")"; sleep 1; exit 0 ;;
  error-exit) exit 0 ;;
esac
if [ "$FM_HANDOFF_LAB_MODE" = hung-launch ]; then sleep 60; exit 1; fi
ORCA_TERMINAL_HANDLE="term_lab_$n" claude "$FM_HOME/successor.sh" > "$FM_HOME/state/successor-$n.out" 2>&1 &
echo "$!" >> "$FM_HANDOFF_TEST_PIDS"
printf '{"outcome":{"kind":"terminal","terminal":{"handle":"term_lab_%s"}}}\n' "$n"
EOF
chmod +x "$FAKEBIN/orca"
cat > "$FAKEBIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -eu
# Exhaust only the first attempt's setup window, then let the fresh retry
# use the same backend normally. Record the nonce to prove replacement.
case "$FM_HANDOFF_LAB_MODE:$1" in
  tmux-display-timeout:display-message|tmux-has-timeout:has-session)
    if [ ! -e "$FM_HOME/state/tmux-setup-nonce" ]; then
      jq -r .nonce "$FM_HOME/state/.handoff-pending" > "$FM_HOME/state/tmux-setup-nonce"
      exec "$FM_HANDOFF_REAL_SLEEP" "$FM_TEST_STUB_MAX_BLOCK_SECONDS"
    fi ;;
esac
case "$1" in
  display-message) echo lab; exit 0 ;;
  has-session) exit 0 ;;
  new-window) shift ;;
  *) exit 94 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    -d) shift ;;
    -t) echo "$2" > "$FM_HOME/state/tmux-target"; shift 2 ;;
    -c|-n) shift 2 ;;
    *) break ;;
  esac
done
# Multiple command arguments are required: no executable shell string.
[ "$#" = 3 ] && [ "$1" = claude ] && [ "$2" = --dangerously-skip-permissions ] || exit 95
TMUX_PANE=%9 claude "$FM_HOME/successor.sh" >/dev/null 2>&1 &
echo "$!" >> "$FM_HANDOFF_TEST_PIDS"
echo 1 > "$FM_HOME/state/attempts"
EOF
chmod +x "$FAKEBIN/tmux"
cat > "$LAB/successor.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
nonce=$(jq -r .nonce "$FM_HOME/state/.handoff-pending")
sha=$(jq -r .sha256 "$FM_HOME/state/.handoff-pending")
wait_for_suite() {
  while kill -0 "$FM_TEST_SUITE_PID" 2>/dev/null \
    && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 1; done
}
case "$FM_HANDOFF_LAB_MODE" in
  exit) exit 0 ;;
  parse) if command -v zsh >/dev/null; then zsh -c ')'; else bash -c ')'; fi ;;
  reject) bash "$ROOT/bin/fm-lock.sh"; exit ;;
  no-ack)
    FM_HANDOFF_NONCE="$nonce" bash "$ROOT/bin/fm-lock.sh" > "$FM_HOME/ack.out" 2>&1 || true
    wait_for_suite; exit ;;
  unprovable)
    cp "$FM_HOME/state/.lock-session" "$FM_HOME/state/session.keep"
    sed 's/^anchor_start=.*/anchor_start=unprovable/' "$FM_HOME/state/session.keep" > "$FM_HOME/state/.lock-session"
    bash "$ROOT/bin/fm-handoff-ack.sh" "$nonce" "$sha" > "$FM_HOME/ack.out" 2>&1 || true
    cp "$FM_HOME/state/session.keep" "$FM_HOME/state/.lock-session"
    wait_for_suite; exit ;;
  pred-dies)
    pred=$(cat "$FM_HOME/pred.pid")
    kill "$pred"
    end=$((SECONDS + 60))
    while kill -0 "$pred" 2>/dev/null && [ "$SECONDS" -lt "$end" ]; do sleep 0.1; done ;;
  interrupt-after-ack)
    end=$((SECONDS + 60))
    while [ ! -e "$FM_HOME/state/polling" ] && [ "$SECONDS" -lt "$end" ]; do sleep 0.1; done ;;
  precommit)
    # Hold the claim lock and expose the successor's line 1 and sidecar the
    # way fm-lock.sh does before commit, then roll back as an interrupt would.
    STATE="$FM_HOME/state"
    . "$ROOT/bin/fm-wake-lib.sh"
    . "$ROOT/bin/fm-session-lock-lib.sh"
    fm_lock_acquire_wait "$STATE/.lock.acquire"
    start=$(fm_session_process_start "$$")
    jq -n --arg nonce "$nonce" --arg sha "$sha" --arg handle "$ORCA_TERMINAL_HANDLE" --arg start "$start" --argjson pid "$$" \
      '{version:1,nonce:$nonce,sha256:$sha,harness_pid:$pid,fm_lock_pid:$pid,harness_start:$start,terminal_handle:$handle}' \
      > "$FM_HOME/data/handoff-ack-$nonce.json"
    cp "$STATE/.lock" "$STATE/lock.keep"
    cp "$STATE/.lock-session" "$STATE/session.keep"
    printf '\nanchor_pid=%s\nanchor_start=%s\nbackend=orca\nterminal=%s\nworktree=%s\n' \
      "$$" "$start" "$ORCA_TERMINAL_HANDLE" "$FM_HOME" > "$STATE/.lock-session"
    echo "$$" > "$STATE/.lock"
    touch "$STATE/claim-held"
    end=$((SECONDS + 60))
    while [ ! -e "$STATE/claim-wait" ] && [ ! -e "$STATE/.handoff-successor" ] && [ "$SECONDS" -lt "$end" ]; do sleep 0.1; done
    [ ! -e "$STATE/.handoff-successor" ] || touch "$STATE/premature"
    cp "$STATE/lock.keep" "$STATE/.lock"
    cp "$STATE/session.keep" "$STATE/.lock-session"
    rm -f "$STATE/claim-held"
    fm_lock_release "$STATE/.lock.acquire" ;;
  cleanup-contention)
    # Hold the claim lock across the launcher's interrupt for longer than its
    # first 10-second cleanup wait, then try to complete the failed attempt.
    STATE="$FM_HOME/state"
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$STATE/.lock.acquire"
    touch "$STATE/claim-held"
    launcher=$(cat "$FM_HOME/launcher.pid")
    kill -TERM "$launcher"
    end=$((SECONDS + 12))
    while kill -0 "$launcher" 2>/dev/null && [ "$SECONDS" -lt "$end" ]; do sleep 0.1; done
    [ -e "$STATE/claim-wait" ] || touch "$STATE/no-claim-wait"
    kill -0 "$launcher" 2>/dev/null || touch "$STATE/no-claim-wait"
    rm -f "$STATE/claim-held"
    fm_lock_release "$STATE/.lock.acquire"
    end=$((SECONDS + 60))
    while kill -0 "$launcher" 2>/dev/null && [ "$SECONDS" -lt "$end" ]; do sleep 0.1; done ;;
  cleanup-second-signal)
    # Interrupt the launcher while holding the claim lock, then signal it
    # again during its bounded cleanup wait for that lock.
    STATE="$FM_HOME/state"
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$STATE/.lock.acquire"
    touch "$STATE/claim-held"
    launcher=$(cat "$FM_HOME/launcher.pid")
    kill -TERM "$launcher"
    sleep 1
    rm -f "$STATE/claim-wait"
    end=$((SECONDS + 8))
    while [ ! -e "$STATE/claim-wait" ] && [ "$SECONDS" -lt "$end" ]; do sleep 0.1; done
    [ -e "$STATE/claim-wait" ] || touch "$STATE/no-claim-wait"
    kill -TERM "$launcher" 2>/dev/null || true
    kill -INT "$launcher" 2>/dev/null || true
    sleep 1
    kill -0 "$launcher" 2>/dev/null || touch "$STATE/second-signal-killed"
    rm -f "$STATE/claim-held"
    fm_lock_release "$STATE/.lock.acquire"
    end=$((SECONDS + 60))
    while kill -0 "$launcher" 2>/dev/null && [ "$SECONDS" -lt "$end" ]; do sleep 0.1; done ;;
  slow-claim) exit 0 ;;
  delayed-successor)
    printf 'holder=%s\n' "$(cat "$FM_HOME/pred.pid")" > "$FM_HOME/state/.lease-task-a"
    PATH="$FM_HANDOFF_DELAY_BIN:$PATH" ;;
  stale) nonce=00000000000000000000000000000000 ;;
  expired) jq '.deadline=0' "$FM_HOME/state/.handoff-pending" > "$FM_HOME/state/expired"; mv "$FM_HOME/state/expired" "$FM_HOME/state/.handoff-pending" ;;
  wrong-sha) sha=$(printf '%064d' 0) ;;
esac
bash "$ROOT/bin/fm-handoff-ack.sh" "$nonce" "$sha" > "$FM_HOME/ack.out" 2>&1 || true
wait_for_suite
EOF
cat > "$LAB/predecessor.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
echo "$$" > "$FM_HOME/pred.pid"
ORCA_TERMINAL_HANDLE=term_predecessor bash "$ROOT/bin/fm-lock.sh" > "$FM_HOME/lock.out" 2>&1
set +e
if [ "$FM_HANDOFF_LAB_MODE" = slow-claim ]; then
  # Hold the claim lock past half the budget before the launcher starts.
  (STATE="$FM_HOME/state"
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$STATE/.lock.acquire"
    touch "$STATE/claim-busy"
    sleep $((FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS * 3 / 4))
    fm_lock_release "$STATE/.lock.acquire"
    date +%s > "$STATE/claim-released") &
  while [ ! -e "$FM_HOME/state/claim-busy" ]; do sleep 0.1; done
fi
bash "$ROOT/bin/fm-handoff-launch.sh" "$FM_HOME/data/handoff ) '.md" > "$FM_HOME/launch.out" 2>&1 &
launcher=$!
echo "$launcher" > "$FM_HOME/launcher.pid"
echo "$launcher" >> "$FM_HANDOFF_TEST_PIDS"
wait "$launcher"
echo "$?" > "$FM_HOME/rc"
while kill -0 "$FM_TEST_SUITE_PID" 2>/dev/null \
  && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 1; done
EOF

run_hook_fixture() {
  jq -nc --arg transcript "$LAB/transcript" --arg event "$1" \
    '{session_id:"lab-predecessor",transcript_path:$transcript,hook_event_name:$event,tool_name:"Bash"}' \
    | env FM_ROOT_OVERRIDE="$LAB" CLAUDE_PROJECT_DIR="$LAB" bash "$ROOT/bin/fm-handoff-trigger.sh"
}

run_case() {
  local mode=$1 limit
  test_cleanup_processes
  rm -f "$LAB/state/".* "$LAB/state/attempts" "$LAB/state/handoff-events.log" "$LAB/state/"successor-*.out "$LAB/rc" "$LAB/ack.out" \
    "$LAB/state/tmux-target" "$LAB/state/tmux-setup-nonce" "$LAB/state/polling" "$LAB/state/session.keep" "$LAB/state/lock.keep" "$LAB/state/claim-held" \
    "$LAB/state/claim-wait" "$LAB/state/no-claim-wait" "$LAB/state/premature" "$LAB/state/retire-delayed" "$LAB/state/claim-busy" "$LAB/state/claim-released" "$LAB/state/second-signal-killed" \
    "$LAB/launcher.pid" "$LAB/pred.pid" 2>/dev/null || true
  printf '%s\n' "${2:-orca}" > "$LAB/config/backend"
  printf '# Quoting-hostile handoff\nRead this document.\n' > "$LAB/data/handoff ) '.md"
  budget=$LAB_FAIL_BUDGET
  # interrupt-after-ack and precommit also end at a real ack, so they need
  # the success budget's claim deadline rather than the 40 s failure claim.
  case "$mode" in interrupt-after-ack|precommit) budget=$LAB_SUCCESS_BUDGET ;; esac
  if [ "$mode" = success ]; then
    budget=$LAB_SUCCESS_BUDGET
    printf 'compact-at-tokens=100000\n' > "$LAB/config/handoff-trigger"
    printf '{"type":"assistant","message":{"model":"claude-test-model","usage":{"input_tokens":90000,"output_tokens":1}}}\n' > "$LAB/transcript"
    hook_output=$(run_hook_fixture PostToolUse)
    printf '%s' "$hook_output" | jq -e '.hookSpecificOutput.additionalContext | contains("handoff")' >/dev/null \
      || fail 'the real hook must arm the lab handoff gate'
    [ -e "$LAB/state/.handoff-trigger.lab-predecessor.0" ] || fail 'the lab handoff gate marker must exist'
  fi
  # Detach the predecessor so its death is not hidden behind an unreaped zombie.
  (FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS="$budget" FM_HANDOFF_LAB_MODE="$mode" claude "$LAB/predecessor.sh" &
    echo "$!" >> "$TMP_ROOT/pids")
  limit=$((SECONDS + budget + LAB_SLACK + LAB_STARTUP))
  while [ "$SECONDS" -lt "$limit" ]; do
    [ ! -f "$LAB/rc" ] || return 0
    if [ "$mode" = pred-dies ] && [ -f "$LAB/launcher.pid" ] \
      && ! kill -0 "$(cat "$LAB/launcher.pid")" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  fail "handoff did not finish: $(cat "$LAB/launch.out" 2>/dev/null)"
}
test_cleanup_processes() {
  if [ -f "$TMP_ROOT/pids" ]; then
    while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$TMP_ROOT/pids"
    : > "$TMP_ROOT/pids"
  fi
}

test_resumed_endpoint() {
  local backend=$1 expected=$2 current=$3 explicit=${4:-} dir phase pid limit handle
  local -a endpoint_env metadata_env
  dir="$TMP_ROOT/resume-$backend-$expected"
  mkdir -p "$dir/state"
  metadata_env=("FM_SESSION_ENDPOINT_META=")
  if [ -n "$explicit" ]; then
    printf 'backend=orca\nterminal=term_explicit\nworktree=%s\nspawn_gen=s1.1.1\n' "$dir" > "$dir/endpoint"
    metadata_env=("FM_SESSION_ENDPOINT_META=$dir/endpoint")
  fi
  cat > "$dir/session.sh" <<'EOF'
#!/usr/bin/env bash
set -u
CLAUDE_CODE_SESSION_ID=endpoint-resume CLAUDE_PID=$$ bash "$ROOT/bin/fm-lock.sh" > "$FM_HOME/$FM_RESUME_PHASE.out" 2>&1
echo "$?" > "$FM_HOME/$FM_RESUME_PHASE.rc"
echo "$$" > "$FM_HOME/$FM_RESUME_PHASE.pid"
while kill -0 "$FM_TEST_SUITE_PID" 2>/dev/null \
  && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 1; done
EOF
  for phase in first second; do
    endpoint_env=("ORCA_TERMINAL_HANDLE=" "TMUX_PANE=")
    handle=$current
    [ "$phase" != first ] || handle=old_endpoint
    if [ -n "$handle" ]; then
      case "$backend" in
        tmux) endpoint_env=("ORCA_TERMINAL_HANDLE=" "TMUX_PANE=$handle") ;;
        orca) endpoint_env=("ORCA_TERMINAL_HANDLE=$handle" "TMUX_PANE=") ;;
      esac
    fi
    env -u ORCA_TERMINAL_HANDLE -u TMUX_PANE -u FM_SESSION_ENDPOINT_META \
      FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_RESUME_PHASE="$phase" \
      "${metadata_env[@]}" "${endpoint_env[@]}" claude "$dir/session.sh" &
    pid=$!
    echo "$pid" >> "$TMP_ROOT/pids"
    limit=$((SECONDS + LAB_STARTUP))
    while [ ! -f "$dir/$phase.pid" ] && [ "$SECONDS" -lt "$limit" ]; do sleep 0.1; done
    [ -f "$dir/$phase.rc" ] || fail "$backend $phase did not finish locking"
    [ "$(cat "$dir/$phase.rc")" = 0 ] || fail "$backend $phase refused: $(cat "$dir/$phase.out")"
  done
  kill -0 "$(cat "$dir/first.pid")" || fail 'resume must re-anchor while the old process is still alive'
  [ "$(cat "$dir/state/.lock")" = "$(cat "$dir/second.pid")" ] || fail 'resume did not move to the new process anchor'
  locate=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" bash "$ROOT/bin/fm-captain-locate.sh") \
    || fail "$backend resume lost its discoverable endpoint: $(cat "$dir/state/.lock-session")"
  assert_contains "$locate" "handle=$expected" "$backend resume uses the correct terminal"
  if [ -n "$explicit" ]; then
    assert_contains "$(cat "$dir/state/.lock-session")" 'spawn_gen=s1.1.1' 'explicit endpoint keeps its generation during resume'
  fi
  kill "$(cat "$dir/first.pid")" "$(cat "$dir/second.pid")" 2>/dev/null || true
  pass "$backend resume discovers $expected and preserves explicit metadata precedence"
}

test_resumed_endpoint tmux %32 %32
test_resumed_endpoint tmux old_endpoint ''
test_resumed_endpoint orca term_new term_new
test_resumed_endpoint orca term_explicit term_ignored explicit

for mode in interrupt error-exit; do
  run_case "$mode"
  [ "$(cat "$LAB/rc")" != 0 ] || fail "$mode must fail"
  expected_reason=error
  [ "$mode" != interrupt ] || expected_reason=interrupted
  [ "$(grep -c ' event=handoff_failed ' "$LAB/state/handoff-events.log" || true)" = 1 ] \
    || fail "$mode must emit exactly one durable failure"
  grep -q " event=handoff_failed nonce=[0-9a-f]* attempt=1 .* reason=$expected_reason$" "$LAB/launch.out" \
    || fail "$mode must emit its failure on the original stdout: $(cat "$LAB/launch.out")"
  [ "$(cat "$LAB/state/.lock")" = "$(cat "$LAB/pred.pid")" ] || fail "$mode moved the predecessor lock"
  [ ! -e "$LAB/state/.handoff-pending" ] || fail "$mode must retire its claim"
  [ ! -e "$LAB/state/.handoff-successor" ] || fail "$mode must not record completion"
  cat "$LAB/state/handoff-events.log"
  pass "DRILL $mode: one failure on stdout and log, predecessor lock retained"
done

# Existing supervisor endpoint metadata outranks an inherited terminal variable.
META_HOME="$TMP_ROOT/meta-home"
mkdir -p "$META_HOME/state"
printf 'backend=orca\nterminal=term_recorded\nworktree=%s\nspawn_gen=s1.1.1\n' "$META_HOME" > "$META_HOME/endpoint"
# shellcheck disable=SC2016 # The harness child expands its own environment.
FM_HOME="$META_HOME" FM_STATE_OVERRIDE="$META_HOME/state" ORCA_TERMINAL_HANDLE=term_inherited \
  FM_SESSION_ENDPOINT_META="$META_HOME/endpoint" claude -c '
    bash "$ROOT/bin/fm-lock.sh" > "$FM_HOME/out" 2>&1
    touch "$FM_HOME/ready"
    while kill -0 "$FM_TEST_SUITE_PID" 2>/dev/null && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 1; done' &
meta_pid=$!
echo "$meta_pid" >> "$TMP_ROOT/pids"
for i in $(seq 1 200); do [ ! -e "$META_HOME/ready" ] || break; sleep 0.1; done
assert_contains "$(cat "$META_HOME/state/.lock-session")" 'terminal=term_recorded' 'explicit endpoint metadata outranks inherited terminal'
assert_contains "$(cat "$META_HOME/state/.lock-session")" 'spawn_gen=s1.1.1' 'explicit endpoint generation survives'
kill "$meta_pid"; wait "$meta_pid" 2>/dev/null || true
pass 'supervisor endpoint metadata retains precedence and generation'

# A verified transfer retires predecessor leases only once it commits.
REAL_MKTEMP=$(command -v mktemp) REAL_RM=$(command -v rm)
REAL_CAT=$(command -v cat) REAL_CP=$(command -v cp)
export REAL_MKTEMP REAL_RM REAL_CAT REAL_CP
lease_transfer() {  # <case> <stub-name> <stub-body>
  local home="$TMP_ROOT/lease-$1" bin="$TMP_ROOT/lease-$1-bin"
  LEASE_HOME=$home
  mkdir -p "$home/state" "$home/data" "$bin"
  printf 'lease handoff\n' > "$home/handoff.md"
  printf '#!/usr/bin/env bash\n%s\n' "$3" > "$bin/$2"
  chmod +x "$bin/$2"
  if [ "${4:-}" = rollback-second-signal ]; then
    cp "$TMP_ROOT/rollback-cp" "$bin/cp"
    chmod +x "$bin/cp"
  fi
  # shellcheck disable=SC2016 # The harness child expands its own environment.
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" ORCA_TERMINAL_HANDLE=term_lease_pred claude -c '
    bash "$ROOT/bin/fm-lock.sh" > "$FM_HOME/pred.out" 2>&1
    echo "$$" > "$FM_HOME/pred.pid"
    while kill -0 "$FM_TEST_SUITE_PID" 2>/dev/null && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 1; done' &
  echo "$!" >> "$TMP_ROOT/pids"
  limit=$((SECONDS + LAB_STARTUP))
  while [ ! -f "$home/pred.pid" ] && [ "$SECONDS" -lt "$limit" ]; do sleep 0.1; done
  [ "$(cat "$home/state/.lock")" = "$(cat "$home/pred.pid")" ] || fail "lease predecessor must hold the lock: $(cat "$home/pred.out")"
  printf 'holder=%s\n' "$(cat "$home/pred.pid")" > "$home/state/.lease-task-a"
  cp "$home/state/.lock-session" "$home/session.before"
  [ "${4:-}" != no-sidecar ] || rm -f "$home/state/.lock-session"
  (
    export FM_HOME="$home" FM_STATE_OVERRIDE="$home/state"
    STATE="$home/state"
    . "$ROOT/bin/fm-wake-lib.sh"
    . "$ROOT/bin/fm-session-lock-lib.sh"
    . "$ROOT/bin/fm-handoff-lib.sh"
    pred=$(cat "$FM_HOME/pred.pid")
    nonce=0123456789abcdef0123456789abcdef
    sha=$(fm_handoff_hash "$FM_HOME/handoff.md")
    jq -n --arg nonce "$nonce" --arg doc "$FM_HOME/handoff.md" --arg sha "$sha" \
      --arg start "$(fm_session_process_start "$pred")" --argjson pid "$pred" --argjson deadline "$(( $(date +%s) + 600 ))" \
      '{version:1,nonce:$nonce,handoff:$doc,sha256:$sha,predecessor_pid:$pid,predecessor_start:$start,deadline:$deadline}' \
      > "$STATE/.handoff-pending"
    # shellcheck disable=SC2016 # The harness child expands its own environment.
    PATH="$bin:$PATH" ORCA_TERMINAL_HANDLE=term_lease_succ claude -c '
      echo "$$" > "$FM_HOME/succ.pid"
      bash "$ROOT/bin/fm-handoff-ack.sh" "$1" "$2" > "$FM_HOME/ack.out" 2>&1
      echo "$?" > "$FM_HOME/ack.rc"' lease-successor "$nonce" "$sha"
  ) || fail "lease fixture $1 failed"
}
assert_committed_transfer() {  # <case>
  [ "$(cat "$LEASE_HOME/ack.rc")" = 0 ] || fail "$1: a committed transfer must succeed: $(cat "$LEASE_HOME/ack.out")"
  assert_contains "$(cat "$LEASE_HOME/ack.out")" 'reason=lock_transferred' "$1: the committed transfer is acknowledged"
  [ "$(cat "$LEASE_HOME/state/.lock")" = "$(cat "$LEASE_HOME/succ.pid")" ] || fail "$1: the successor must own the lock"
  [ "$(sed -n 's/^anchor_pid=//p' "$LEASE_HOME/state/.lock-session")" = "$(cat "$LEASE_HOME/succ.pid")" ] \
    || fail "$1: the committed sidecar must name the successor"
  assert_contains "$(sed -n 's/^terminal=//p' "$LEASE_HOME/state/.lock-session")" term_lease_succ "$1: the committed sidecar keeps the successor terminal"
}

# shellcheck disable=SC2016 # The stub expands its own arguments.
lease_transfer rollback mktemp 'case "${1:-}" in */.lock-session.XXXXXX) exit 1 ;; esac
exec "$REAL_MKTEMP" "$@"'
[ "$(cat "$LEASE_HOME/ack.rc")" != 0 ] || fail 'a transfer whose publication fails must not succeed'
assert_contains "$(cat "$LEASE_HOME/ack.out")" 'reason=lock_refused' 'the failed publication is a nonce-bound reject'
[ "$(cat "$LEASE_HOME/state/.lock")" = "$(cat "$LEASE_HOME/pred.pid")" ] || fail 'a rolled-back transfer moved the lock'
cmp -s "$LEASE_HOME/session.before" "$LEASE_HOME/state/.lock-session" || fail 'a rolled-back transfer must restore the predecessor sidecar'
[ -f "$LEASE_HOME/state/.lease-task-a" ] || fail 'a rolled-back transfer retired the live predecessor lease'
pass 'a transfer that rolls back after its verdict preserves predecessor leases'

# shellcheck disable=SC2016 # The stub expands its own arguments.
lease_transfer retire-error rm 'for arg; do case "$arg" in */.lease-*) exit 1 ;; esac; done
exec "$REAL_RM" "$@"'
assert_committed_transfer 'retirement error'
assert_contains "$(cat "$LEASE_HOME/ack.out")" 'could not be retired' 'a failed lease retirement after commit is a warning'
[ -f "$LEASE_HOME/state/.lease-task-a" ] || fail 'the stub must have refused the lease retirement'
pass 'a lease retirement error after commit keeps the committed transfer'

# shellcheck disable=SC2016 # The stub expands its own arguments.
lease_transfer retire-signal rm 'for arg; do case "$arg" in */.lease-*) kill -TERM "$PPID" ;; esac; done
exec "$REAL_RM" "$@"'
assert_committed_transfer 'retirement interruption'
[ ! -e "$LEASE_HOME/state/.lease-task-a" ] || fail 'an interrupted retirement must still finish under the commit'
pass 'an interruption during lease retirement after commit keeps the committed transfer'

# A signal right after the successor's line-1 write rolls back to the
# predecessor through fm-lock.sh's own cleanup, not a fixture restore.
# shellcheck disable=SC2016 # The stub expands its own arguments.
lease_transfer phase2-signal cat 'if [ "${1:-}" = "$FM_HOME/state/.lock" ] && [ -f "$FM_HOME/succ.pid" ] \
  && [ "$("$REAL_CAT" "$1")" = "$("$REAL_CAT" "$FM_HOME/succ.pid")" ]; then kill -TERM "$PPID"; fi
exec "$REAL_CAT" "$@"'
[ "$(cat "$LEASE_HOME/ack.rc")" != 0 ] || fail 'a transfer interrupted before commit must not succeed'
assert_contains "$(cat "$LEASE_HOME/ack.out")" 'reason=lock_refused' 'the interrupted transfer is a nonce-bound reject'
[ "$(cat "$LEASE_HOME/state/.lock")" = "$(cat "$LEASE_HOME/pred.pid")" ] || fail 'an interrupted transfer must restore the predecessor line 1'
cmp -s "$LEASE_HOME/session.before" "$LEASE_HOME/state/.lock-session" || fail 'an interrupted transfer must restore the predecessor sidecar'
[ -f "$LEASE_HOME/state/.lease-task-a" ] || fail 'an interrupted transfer retired the live predecessor lease'
pass 'a transfer interrupted after its line-1 write restores predecessor ownership and leases'

# A second signal while rollback restores line 1 must not interrupt the
# sidecar restoration or the release of either transaction lock.
cat > "$TMP_ROOT/rollback-cp" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -f ] && [ "${3:-}" = "$FM_HOME/state/.lock" ]; then
  touch "$FM_HOME/rollback-second-signal"
  kill -TERM "$PPID"
fi
exec "$REAL_CP" "$@"
EOF
# shellcheck disable=SC2016 # The stub expands its own arguments.
lease_transfer phase2-second-signal cat 'if [ "${1:-}" = "$FM_HOME/state/.lock" ] && [ -f "$FM_HOME/succ.pid" ] \
  && [ "$("$REAL_CAT" "$1")" = "$("$REAL_CAT" "$FM_HOME/succ.pid")" ]; then kill -TERM "$PPID"; fi
exec "$REAL_CAT" "$@"' rollback-second-signal
[ -e "$LEASE_HOME/rollback-second-signal" ] || fail 'the second signal must arrive inside production rollback'
[ "$(cat "$LEASE_HOME/ack.rc")" != 0 ] || fail 'an interrupted transfer must not acknowledge success'
[ "$(cat "$LEASE_HOME/state/.lock")" = "$(cat "$LEASE_HOME/pred.pid")" ] || fail 'rollback interrupted twice must restore the predecessor PID'
cmp -s "$LEASE_HOME/session.before" "$LEASE_HOME/state/.lock-session" || fail 'rollback interrupted twice must restore the predecessor sidecar'
[ -f "$LEASE_HOME/state/.lease-task-a" ] || fail 'rollback interrupted twice must preserve the predecessor lease'
for guard in .lock.acquire .fm-lease-command.lock; do
  [ ! -e "$LEASE_HOME/state/$guard" ] || fail "rollback interrupted twice must release $guard"
  [ ! -L "$LEASE_HOME/state/$guard" ] || fail "rollback interrupted twice must unlink $guard"
done
pass 'a second signal during transaction rollback preserves ownership and releases its locks'

# A predecessor that owns the lock by ancestry, with no sidecar, is restored
# with its sidecar still absent when the transfer is interrupted.
# shellcheck disable=SC2016 # The stub expands its own arguments.
lease_transfer phase2-no-sidecar cat 'if [ "${1:-}" = "$FM_HOME/state/.lock" ] && [ -f "$FM_HOME/succ.pid" ] \
  && [ "$("$REAL_CAT" "$1")" = "$("$REAL_CAT" "$FM_HOME/succ.pid")" ]; then kill -TERM "$PPID"; fi
exec "$REAL_CAT" "$@"' no-sidecar
[ "$(cat "$LEASE_HOME/ack.rc")" != 0 ] || fail 'a sidecar-less transfer interrupted before commit must not succeed'
assert_contains "$(cat "$LEASE_HOME/ack.out")" 'reason=lock_refused' 'the interrupted sidecar-less transfer is a nonce-bound reject'
[ "$(cat "$LEASE_HOME/state/.lock")" = "$(cat "$LEASE_HOME/pred.pid")" ] || fail 'an interrupted sidecar-less transfer must restore the predecessor line 1'
[ ! -e "$LEASE_HOME/state/.lock-session" ] || fail 'an interrupted sidecar-less transfer must keep the sidecar absent'
[ -f "$LEASE_HOME/state/.lease-task-a" ] || fail 'an interrupted sidecar-less transfer retired the live predecessor lease'
pass 'a sidecar-less transfer interrupted after its line-1 write restores the predecessor'

# Discovery during the uncommitted interval reports unknown; afterwards it
# reports only the committed owner, for both rollback and commit.
for locate_case in rollback commit; do
  export LOCATE_CASE=$locate_case
  # shellcheck disable=SC2016 # The stub expands its own arguments.
  lease_transfer "locate-$locate_case" cat 'if [ "${1:-}" = "$FM_HOME/state/.lock" ] && [ -f "$FM_HOME/succ.pid" ] && [ ! -e "$FM_HOME/locate.during" ] \
  && [ "$("$REAL_CAT" "$1")" = "$("$REAL_CAT" "$FM_HOME/succ.pid")" ]; then
  PATH="${PATH#*:}" bash "$ROOT/bin/fm-captain-locate.sh" > "$FM_HOME/locate.during" 2>&1 || true
  [ "$LOCATE_CASE" != rollback ] || kill -TERM "$PPID"
fi
exec "$REAL_CAT" "$@"'
  during=$(cat "$LEASE_HOME/locate.during" 2>/dev/null || true)
  assert_contains "$during" 'handle=none state=unknown' "$locate_case: discovery during an uncommitted transfer is unknown"
  after=$(FM_HOME="$LEASE_HOME" FM_STATE_OVERRIDE="$LEASE_HOME/state" bash "$ROOT/bin/fm-captain-locate.sh" || true)
  if [ "$locate_case" = rollback ]; then
    assert_contains "$after" "pid=$(cat "$LEASE_HOME/pred.pid") handle=term_lease_pred state=held" 'discovery after rollback names the predecessor'
    # A dead holder's claim lock does not hide the committed endpoint.
    mkdir "$LEASE_HOME/state/.lock.acquire"
    # shellcheck disable=SC2016 # The child prints its own pid, then exits.
    dead_pid=$(bash -c 'echo "$$"')
    echo "$dead_pid" > "$LEASE_HOME/state/.lock.acquire/pid"
    stale=$(FM_HOME="$LEASE_HOME" FM_STATE_OVERRIDE="$LEASE_HOME/state" bash "$ROOT/bin/fm-captain-locate.sh" || true)
    assert_contains "$stale" 'handle=term_lease_pred state=held' 'a stale claim lock does not hide the committed endpoint'
  else
    # The fixture successor exits after its ack, so its committed lock is stale.
    assert_committed_transfer 'discovery commit'
    assert_contains "$after" "pid=$(cat "$LEASE_HOME/succ.pid") handle=none state=stale" 'discovery after commit names the committed successor'
  fi
done
pass 'discovery reports only committed endpoints across an uncommitted transfer'

# A tmux pane nested in Orca outranks the inherited Orca handle, and an Orca
# handle outside an Orca terminal is not trusted.
NEST_HOME="$TMP_ROOT/nest-home"
for nest in nested:%41:%41 inherited::none; do
  IFS=: read -r nest_case nest_pane nest_expected <<<"$nest"
  rm -rf "$NEST_HOME"; mkdir -p "$NEST_HOME/state"
  nest_env=("TERM_PROGRAM=Orca" "TMUX_PANE=$nest_pane")
  [ "$nest_case" = nested ] || nest_env=("TERM_PROGRAM=" "TMUX_PANE=")
  # shellcheck disable=SC2016 # The harness child expands its own environment.
  env FM_HOME="$NEST_HOME" FM_STATE_OVERRIDE="$NEST_HOME/state" ORCA_TERMINAL_HANDLE=term_inherited "${nest_env[@]}" claude -c '
    bash "$ROOT/bin/fm-lock.sh" > "$FM_HOME/out" 2>&1
    touch "$FM_HOME/ready"
    while kill -0 "$FM_TEST_SUITE_PID" 2>/dev/null && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 1; done' &
  # shellcheck disable=SC2031 # The background job above sets $! here.
  nest_pid=$!
  echo "$nest_pid" >> "$TMP_ROOT/pids"
  limit=$((SECONDS + LAB_STARTUP))
  while [ ! -e "$NEST_HOME/ready" ] && [ "$SECONDS" -lt "$limit" ]; do sleep 0.1; done
  locate=$(FM_HOME="$NEST_HOME" FM_STATE_OVERRIDE="$NEST_HOME/state" bash "$ROOT/bin/fm-captain-locate.sh" || true)
  assert_contains "$locate" "handle=$nest_expected" "$nest_case endpoint follows supervisor-target precedence"
  assert_not_contains "$(cat "$NEST_HOME/state/.lock-session")" 'term_inherited' "$nest_case must not record the inherited Orca handle"
  kill "$nest_pid"; wait "$nest_pid" 2>/dev/null || true
done
pass 'lock endpoints follow supervisor-target precedence for nested and inherited terminals'

run_case success
[ "$(cat "$LAB/rc")" = 0 ] || fail "valid ack should transfer: $(cat "$LAB/launch.out") $(cat "$LAB/ack.out" 2>/dev/null)"
nonce=$(sed -n 's/^nonce=//p' "$LAB/state/.handoff-successor")
ack="$LAB/data/handoff-ack-$nonce.json"
jq -e --argjson pid "$(cat "$LAB/state/.lock")" '.version == 1 and .harness_pid == $pid and .fm_lock_pid == $pid and (.sha256 | length) == 64 and .terminal_handle == "term_lab_1"' "$ack" >/dev/null || fail 'ack schema and lock must agree'
run_hook_fixture Stop >/dev/null 2>&1 || fail 'verified completion must clear the actual Stop gate'
cp "$ack" "$LAB/ack.backup"
jq '.sha256="wrong"' "$LAB/ack.backup" > "$ack"
run_hook_fixture Stop >/dev/null 2>&1 && fail 'tampered ack must not clear the Stop gate'
mv "$LAB/ack.backup" "$ack"
[ "$(cat "$LAB/state/.lock")" != "$(cat "$LAB/pred.pid")" ] || fail 'lock did not transfer'
kill -0 "$(cat "$LAB/pred.pid")" || fail 'predecessor must not be killed'
# Regression: the predecessor never exits, yet the launcher completes and the
# lock names the acknowledged successor rather than waiting for an exit.
[ "$(cat "$LAB/state/.lock")" = "$(jq -r .harness_pid "$ack")" ] || fail 'lock must name the acknowledged successor'
[ "$(sed -n 's/^pid=//p' "$LAB/state/.handoff-successor")" = "$(cat "$LAB/state/.lock")" ] || fail 'completion record must name the lock holder'
[ "$(grep -c " event=handoff_ack nonce=$nonce .* reason=lock_transferred\$" "$LAB/state/handoff-events.log")" = 1 ] \
  || fail 'a live predecessor must not delay the committed transfer event'
locate=$(bash "$ROOT/bin/fm-captain-locate.sh")
assert_contains "$locate" 'handle=term_lab_1' 'discovery follows lock holder'
assert_contains "$locate" "pid=$(cat "$LAB/state/.lock")" 'discovery names lock pid'
bash "$ROOT/bin/fm-handoff-ack.sh" "$nonce" "$(jq -r .sha256 "$ack")" >/dev/null 2>&1 && fail 'replay from another process must refuse'
pass 'verified successor ack transfers the lock while predecessor remains alive; discovery follows it'
# Discovery refuses a sidecar that changes while it is read.
RACE_BIN="$TMP_ROOT/race-bin"
mkdir -p "$RACE_BIN"
REAL_SED=$(command -v sed)
export REAL_SED
cat > "$RACE_BIN/sed" <<'EOF'
#!/usr/bin/env bash
if [ "${2:-}" = 's/^terminal=//p' ] && [ -e "$FM_HOME/state/race-sidecar" ]; then
  rm -f "$FM_HOME/state/race-sidecar"
  "$REAL_SED" 's/^terminal=.*/terminal=term_racing/' "$FM_HOME/state/.lock-session" > "$FM_HOME/state/race.tmp"
  mv "$FM_HOME/state/race.tmp" "$FM_HOME/state/.lock-session"
fi
exec "$REAL_SED" "$@"
EOF
chmod +x "$RACE_BIN/sed"
cp "$LAB/state/.lock-session" "$LAB/session.race"
touch "$LAB/state/race-sidecar"
race_rc=0
race=$(PATH="$RACE_BIN:$PATH" bash "$ROOT/bin/fm-captain-locate.sh") || race_rc=$?
[ ! -e "$LAB/state/race-sidecar" ] || fail 'the sidecar change must happen during discovery'
mv "$LAB/session.race" "$LAB/state/.lock-session"
[ "$race_rc" != 0 ] || fail "a changed sidecar must not be reported as a verified captain: $race"
assert_contains "$race" 'handle=none state=unknown' 'a changed snapshot reports unknown'
pass 'discovery reports a pid and handle only from one unchanged snapshot'
[ ! -e "$LAB/state/.handoff-pending" ] || fail 'a completed handoff must retire its pending claim'
rejects=$(grep -c ' event=handoff_reject ' "$LAB/state/handoff-events.log" || true)
# shellcheck disable=SC2016 # The harness child expands its own environment.
claude -c 'bash "$ROOT/bin/fm-lock.sh"' >/dev/null 2>&1 && fail 'an unrelated session must stay read-only'
[ "$(grep -c ' event=handoff_reject ' "$LAB/state/handoff-events.log" || true)" = "$rejects" ] \
  || fail 'an unrelated refused session after completion must not emit handoff_reject'
pass 'a completed handoff retires its claim, so later refused sessions emit no reject'
# An ordinary shell cannot open a handoff for a foreign session.
bash "$ROOT/bin/fm-handoff-launch.sh" "$LAB/data/handoff ) '.md" >/dev/null 2>&1 && fail 'foreign session must not launch a successor'
# A stale endpoint is not presented as a live captain.
kill "$(cat "$LAB/state/.lock")"
sleep 0.2
locate_rc=0
bash "$ROOT/bin/fm-captain-locate.sh" > "$LAB/locate.out" || locate_rc=$?
[ "$locate_rc" != 0 ] || fail 'dead successor must not be discovered as live'
assert_contains "$(cat "$LAB/locate.out")" 'handle=none' 'dead lock holder hides stale handle'
pass 'foreign launch is refused and dead lock holders are not captain endpoints'

run_case success tmux
[ "$(cat "$LAB/rc")" = 0 ] || fail "tmux direct argv must transfer: $(cat "$LAB/launch.out") $(cat "$LAB/ack.out" 2>/dev/null)"
assert_contains "$(bash "$ROOT/bin/fm-captain-locate.sh")" 'handle=%9' 'tmux discovery uses the successor pane'
run_hook_fixture Stop >/dev/null 2>&1 || fail 'tmux completion must clear Stop gate'
# The fake server answers display-message with an unrelated session.
[ "$(cat "$LAB/state/tmux-target")" = "=firstmate-$(basename "$LAB"):" ] \
  || fail "outside tmux the successor must open in this home's session, not $(cat "$LAB/state/tmux-target")"
pass 'tmux launches direct argv outside tmux in its home session and transfers the verified lock'
export TMUX=/tmp/lab-tmux,1,0
run_case success tmux
unset TMUX
[ "$(cat "$LAB/rc")" = 0 ] || fail "tmux inside a session must transfer: $(cat "$LAB/launch.out")"
[ "$(cat "$LAB/state/tmux-target")" = '=lab:' ] || fail 'inside tmux the successor must open in the current session'
pass 'tmux inside a session opens the successor in that session'

# An expired setup window must revoke attempt 1 and spend the reserved retry
# budget on a fresh claim, rather than exit before any successor launches.
for mode in tmux-display-timeout tmux-has-timeout; do
  export TMUX=/tmp/lab-tmux,1,0
  run_case "$mode" tmux
  unset TMUX
  [ -s "$LAB/state/tmux-setup-nonce" ] || fail "$mode must enter the hung setup probe"
  [ "$(cat "$LAB/rc")" = 0 ] || fail "$mode must complete its fresh retry: $(cat "$LAB/launch.out")"
  nonce=$(sed -n 's/^nonce=//p' "$LAB/state/.handoff-successor")
  [ "$nonce" != "$(cat "$LAB/state/tmux-setup-nonce")" ] || fail "$mode must replace the expired claim nonce"
  [ "$(cat "$LAB/state/attempts")" = 1 ] || fail "$mode must launch one successor after setup recovers"
  grep -q " event=handoff_retry nonce=$nonce attempt=2 " "$LAB/state/handoff-events.log" \
    || fail "$mode must announce the actual second-attempt launch"
  [ "$(grep -c ' event=handoff_failed ' "$LAB/state/handoff-events.log" || true)" = 0 ] \
    || fail "$mode must not fail while the retry can complete"
  [ "$(cat "$LAB/state/.lock")" != "$(cat "$LAB/pred.pid")" ] || fail "$mode must transfer the lock"
  [ ! -e "$LAB/state/.handoff-pending" ] || fail "$mode must retire its pending claim"
  assert_contains "$(bash "$ROOT/bin/fm-captain-locate.sh")" 'handle=%9' "$mode discovers the retry successor"
  cat "$LAB/state/handoff-events.log"
  pass "DRILL $mode: expired setup starts a fresh verified retry within the shared budget"
done

# A signal after the successor's committed transfer records completion only.
run_case interrupt-after-ack
[ "$(cat "$LAB/rc")" = 0 ] || fail "a committed transfer must not be reported as failed: $(cat "$LAB/launch.out")"
[ -e "$LAB/state/polling" ] || fail 'the interrupt must arrive during the launcher poll'
[ "$(grep -c ' event=handoff_failed ' "$LAB/state/handoff-events.log" || true)" = 0 ] \
  || fail "an interrupt after transfer must not emit handoff_failed: $(cat "$LAB/state/handoff-events.log")"
[ "$(grep -c ' event=handoff_ack .* reason=lock_transferred$' "$LAB/state/handoff-events.log")" = 1 ] \
  || fail 'the committed transfer must have exactly one ack outcome'
[ -e "$LAB/state/.handoff-successor" ] || fail 'cleanup must record the committed completion'
[ "$(cat "$LAB/state/.lock")" != "$(cat "$LAB/pred.pid")" ] || fail 'lock did not transfer'
cat "$LAB/state/handoff-events.log"
pass 'DRILL interrupt-after-ack: one completion outcome, no contradictory failure'

# An unlocked read during the successor's uncommitted transfer never completes.
run_case precommit
[ "$(cat "$LAB/rc")" = 0 ] || fail "the later committed transfer must complete: $(cat "$LAB/launch.out") $(cat "$LAB/ack.out" 2>/dev/null)"
[ ! -e "$LAB/state/premature" ] || fail 'the launcher recorded completion before the transfer committed'
[ -e "$LAB/state/claim-wait" ] || fail 'the launcher must wait for the claim lock before deciding completion'
[ "$(cat "$LAB/state/attempts")" = 1 ] || fail 'a rolled-back read must not consume the retry'
[ "$(grep -c ' event=handoff_failed ' "$LAB/state/handoff-events.log" || true)" = 0 ] || fail 'a committed transfer is not a failure'
[ "$(grep -c ' event=handoff_ack .* reason=lock_transferred$' "$LAB/state/handoff-events.log")" = 1 ] \
  || fail "the committed transfer must have exactly one ack: $(cat "$LAB/state/handoff-events.log")"
[ "$(sed -n 's/^pid=//p' "$LAB/state/.handoff-successor")" = "$(cat "$LAB/state/.lock")" ] || fail 'completion must name the committed owner'
pass 'DRILL precommit: completion waits for the committed transfer, not an uncommitted read'

# A busy claim lock during cleanup cannot leave a live claim behind a failure.
run_case cleanup-contention
[ "$(cat "$LAB/rc")" != 0 ] || fail 'an interrupted attempt must fail'
[ ! -e "$LAB/state/no-claim-wait" ] || fail 'cleanup must keep waiting past 10 seconds while the claim is live'
[ "$(grep -c ' event=handoff_failed .* reason=interrupted$' "$LAB/state/handoff-events.log" || true)" = 1 ] \
  || fail "the interrupt must emit exactly one failure: $(cat "$LAB/state/handoff-events.log")"
[ "$(grep -c ' event=handoff_ack ' "$LAB/state/handoff-events.log" || true)" = 0 ] \
  || fail "a failed attempt must not later transfer: $(cat "$LAB/state/handoff-events.log")"
[ "$(cat "$LAB/state/.lock")" = "$(cat "$LAB/pred.pid")" ] || fail 'a failed attempt moved the predecessor lock'
[ ! -e "$LAB/state/.handoff-pending" ] || fail 'a reported failure must retire its claim'
cat "$LAB/state/handoff-events.log"
pass 'DRILL cleanup-contention: failure is reported only after the claim is fenced'

# A second signal during cleanup's bounded claim wait cannot drop the event.
run_case cleanup-second-signal
[ "$(cat "$LAB/rc")" != 0 ] || fail 'an interrupted attempt must fail'
[ ! -e "$LAB/state/no-claim-wait" ] || fail 'the second signal must arrive during the cleanup claim wait'
[ ! -e "$LAB/state/second-signal-killed" ] || fail 'a second signal during cleanup must not kill the launcher'
[ "$(grep -c ' event=handoff_failed ' "$LAB/state/handoff-events.log" || true)" = 1 ] \
  || fail "two signals must emit exactly one failure: $(cat "$LAB/state/handoff-events.log" 2>/dev/null)"
grep -q ' event=handoff_failed .* reason=interrupted$' "$LAB/state/handoff-events.log" \
  || fail "cleanup after two signals must report interruption: $(cat "$LAB/state/handoff-events.log" 2>/dev/null)"
[ ! -e "$LAB/state/.handoff-pending" ] || fail 'cleanup after a second signal must retire its claim'
[ ! -e "$LAB/state/.handoff-launch.lock" ] || fail 'cleanup after a second signal must release the launcher lock'
pass 'DRILL cleanup-second-signal: a second signal during cleanup still emits exactly one failure'

# A claim lock held past half the budget at start cannot extend the first
# attempt past the total deadline: the attempt gets only what is left, less
# than its usual half of the budget.
run_case slow-claim
[ "$(cat "$LAB/rc")" != 0 ] || fail 'a handoff with no ack must fail'
[ "$(cat "$LAB/state/attempts")" = 2 ] || fail "a slow initial claim must leave time for two actual backend launches: $(cat "$LAB/launch.out")"
failed=$(sed -n 's/^HANDOFF v1 ts=\([0-9]*\) event=handoff_failed .*/\1/p' "$LAB/state/handoff-events.log")
[ -n "$failed" ] && [ "$((failed - $(cat "$LAB/state/claim-released")))" -lt "$((LAB_FAIL_BUDGET / 2))" ] \
  || fail "a slow initial claim must not push failure past the total budget: $(cat "$LAB/state/handoff-events.log")"
cat "$LAB/state/handoff-events.log"
pass 'DRILL slow-claim: a slow initial claim still fails within the total budget'

# A successor transaction still holding the claim lock past the launcher's
# bounded cleanup wait is reported unresolved, then settled by its ack.
run_case delayed-successor
[ "$(cat "$LAB/rc")" != 0 ] || fail 'an unsettled handoff must not report success'
[ -e "$LAB/state/retire-delayed" ] || fail 'the successor must be delayed during post-commit lease retirement'
limit=$((SECONDS + LAB_SLACK))
while ! grep -q ' event=handoff_ack ' "$LAB/state/handoff-events.log" && [ "$SECONDS" -lt "$limit" ]; do sleep 0.1; done
failed_line=$(grep -n ' event=handoff_failed ' "$LAB/state/handoff-events.log" || true)
ack_line=$(grep -n ' event=handoff_ack .* reason=lock_transferred$' "$LAB/state/handoff-events.log" || true)
[ "$(printf '%s\n' "$failed_line" | grep -c 'reason=unresolved$')" = 1 ] && [ "$(printf '%s\n' "$failed_line" | wc -l)" -eq 1 ] \
  || fail "a busy claim at the deadline must emit exactly one unresolved failure: $(cat "$LAB/state/handoff-events.log")"
[ -n "$ack_line" ] || fail "the delayed transfer must still be acknowledged: $(cat "$LAB/state/handoff-events.log")"
[ "${failed_line%%:*}" -lt "${ack_line%%:*}" ] || fail 'the settling ack must follow the unresolved failure'
failed_nonce=$(printf '%s\n' "$failed_line" | sed -n 's/.* nonce=\([0-9a-f]*\) .*/\1/p')
assert_contains "$ack_line" " nonce=${failed_nonce:-missing} " 'the settling ack must name the unresolved nonce'
[ "$(cat "$LAB/state/.lock")" != "$(cat "$LAB/pred.pid")" ] || fail 'the delayed transfer must commit'
[ ! -e "$LAB/state/.lease-task-a" ] || fail 'the committed transfer must retire the predecessor lease'
cat "$LAB/state/handoff-events.log"
pass 'DRILL delayed-successor: a busy claim at the deadline is unresolved, then settled by the ack'

# A predecessor that dies before the ack leaves an ordinary stale lock.
run_case pred-dies
[ -e "$LAB/state/.handoff-successor" ] || fail "the orphaned launcher must record the completed takeover: $(cat "$LAB/ack.out")"
ack_pid=$(jq -r .harness_pid "$LAB/data/handoff-ack-$(sed -n 's/^nonce=//p' "$LAB/state/.handoff-successor").json")
[ "$(cat "$LAB/state/.lock")" = "$ack_pid" ] || fail "the successor must take a dead predecessor's lock: $(cat "$LAB/ack.out")"
[ "$(grep -c ' event=handoff_ack .* reason=stale_takeover$' "$LAB/state/handoff-events.log")" = 1 ] \
  || fail "the stale takeover must be named in the log: $(cat "$LAB/state/handoff-events.log")"
grep -q 'reason=lock_held$' "$LAB/state/handoff-events.log" && fail 'a dead predecessor must not log lock_held'
assert_not_contains "$(cat "$LAB/ack.out")" 'another live firstmate session' 'a dead predecessor is not reported live'
[ "$(grep -c ' event=handoff_failed ' "$LAB/state/handoff-events.log" || true)" = 0 ] || fail 'a stale takeover is not a failed handoff'
cat "$LAB/state/handoff-events.log"
pass 'DRILL pred-dies: the successor takes the stale lock and the log names that path'

run_case success unsupported-backend
[ "$(cat "$LAB/rc")" != 0 ] || fail 'unsupported backend must refuse'
[ ! -e "$LAB/state/attempts" ] || fail 'unsupported backend must not launch'
printf 'auto\n' > "$LAB/config/claude-permission-mode"
run_case success
[ "$(cat "$LAB/rc")" != 0 ] || fail 'unenforceable Orca permission posture must refuse'
[ ! -e "$LAB/state/attempts" ] || fail 'permission refusal must not launch'
rm "$LAB/config/claude-permission-mode"
pass 'unsupported backends and unenforceable permission posture refuse before launch'

for mode in exit parse reject no-ack unprovable wrong-sha stale expired hung-launch; do
  run_case "$mode"
  [ "$(cat "$LAB/rc")" != 0 ] || fail "$mode must fail"
  [ "$(cat "$LAB/state/attempts")" = 2 ] || fail "$mode must retry exactly once in a fresh pane"
  [ ! -e "$LAB/state/.handoff-successor" ] || fail "$mode must not clear the stop gate"
  [ "$(cat "$LAB/state/.lock")" = "$(cat "$LAB/pred.pid")" ] || fail "$mode moved predecessor lock"
  grep -q '^HANDOFF v1 .* event=handoff_failed ' "$LAB/state/handoff-events.log" || fail "$mode must emit machine-readable failure"
  [ "$(grep -c ' event=handoff_failed ' "$LAB/state/handoff-events.log")" = 1 ] || fail "$mode must emit its failure exactly once"
  started=$(sed -n 's/^HANDOFF v1 ts=\([0-9]*\) event=handoff_started .*/\1/p' "$LAB/state/handoff-events.log")
  failed=$(sed -n 's/^HANDOFF v1 ts=\([0-9]*\) event=handoff_failed .*/\1/p' "$LAB/state/handoff-events.log")
  [ -n "$started" ] && [ "$((failed - started))" -lt "$((LAB_FAIL_BUDGET + LAB_SLACK))" ] \
    || fail "$mode exceeded bounded lab deadline"
  if [ "$mode" = reject ]; then
    grep -q ' event=handoff_reject nonce=none .* reason=lock_held_unbound$' "$LAB/state/handoff-events.log" \
      || fail 'a session refused during the pending window must log lock_held_unbound'
    grep -q ' event=handoff_reject nonce=[0-9a-f]* .* reason=lock_held$' "$LAB/state/handoff-events.log" \
      && fail 'a refusal without the claim nonce must never be a bound successor reject'
  fi
  if [ "$mode" = no-ack ] || [ "$mode" = unprovable ]; then
    grep -q ' event=handoff_reject nonce=[0-9a-f]* .* reason=lock_held$' "$LAB/state/handoff-events.log" \
      || fail "$mode must be refused at the live or unprovable predecessor lock"
    grep -q 'reason=stale_takeover' "$LAB/state/handoff-events.log" && fail "$mode must never take over"
  fi
  cat "$LAB/state/handoff-events.log"
  if [ "$mode" = parse ]; then cat "$LAB/state/"successor-*.out; fi
  pass "DRILL $mode: failed within lab deadline, retried once, predecessor lock preserved"
done
