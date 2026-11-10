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
export FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS=12
export PATH="$FAKEBIN:$PATH" FM_HANDOFF_TEST_PIDS="$TMP_ROOT/pids"
unset FM_BACKEND FM_SESSION_ENDPOINT_META CLAUDE_PID CLAUDE_CODE_SESSION_ID
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
if [ "$FM_HANDOFF_LAB_MODE" = hung-launch ]; then sleep 60; exit 1; fi
ORCA_TERMINAL_HANDLE="term_lab_$n" claude "$FM_HOME/successor.sh" > "$FM_HOME/state/successor-$n.out" 2>&1 &
echo "$!" >> "$FM_HANDOFF_TEST_PIDS"
printf '{"outcome":{"kind":"terminal","terminal":{"handle":"term_lab_%s"}}}\n' "$n"
EOF
chmod +x "$FAKEBIN/orca"
cat > "$FAKEBIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -eu
case "$1" in
  display-message) echo lab; exit 0 ;;
  has-session) exit 0 ;;
  new-window) shift ;;
  *) exit 94 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    -d) shift ;;
    -t|-c|-n) shift 2 ;;
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
case "$FM_HANDOFF_LAB_MODE" in
  exit) exit 0 ;;
  parse) if command -v zsh >/dev/null; then zsh -c ')'; else bash -c ')'; fi ;;
  reject) bash "$ROOT/bin/fm-lock.sh"; exit ;;
  stale) nonce=00000000000000000000000000000000 ;;
  expired) jq '.deadline=0' "$FM_HOME/state/.handoff-pending" > "$FM_HOME/state/expired"; mv "$FM_HOME/state/expired" "$FM_HOME/state/.handoff-pending" ;;
  wrong-sha) sha=$(printf '%064d' 0) ;;
esac
bash "$ROOT/bin/fm-handoff-ack.sh" "$nonce" "$sha" > "$FM_HOME/ack.out" 2>&1 || true
while :; do sleep 1; done
EOF
cat > "$LAB/predecessor.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
echo "$$" > "$FM_HOME/pred.pid"
ORCA_TERMINAL_HANDLE=term_predecessor bash "$ROOT/bin/fm-lock.sh" > "$FM_HOME/lock.out" 2>&1
set +e
bash "$ROOT/bin/fm-handoff-launch.sh" "$FM_HOME/data/handoff ) '.md" > "$FM_HOME/launch.out" 2>&1
echo "$?" > "$FM_HOME/rc"
while :; do sleep 1; done
EOF

run_hook_fixture() {
  jq -nc --arg transcript "$LAB/transcript" --arg event "$1" \
    '{session_id:"lab-predecessor",transcript_path:$transcript,hook_event_name:$event,tool_name:"Bash"}' \
    | env FM_ROOT_OVERRIDE="$LAB" CLAUDE_PROJECT_DIR="$LAB" bash "$ROOT/bin/fm-handoff-trigger.sh"
}

run_case() {
  local mode=$1 i
  test_cleanup_processes
  rm -f "$LAB/state/".* "$LAB/state/attempts" "$LAB/state/handoff-events.log" "$LAB/state/"successor-*.out "$LAB/rc" "$LAB/ack.out" 2>/dev/null || true
  printf '%s\n' "${2:-orca}" > "$LAB/config/backend"
  printf '# Quoting-hostile handoff\nRead this document.\n' > "$LAB/data/handoff ) '.md"
  budget=12
  if [ "$mode" = success ]; then
    budget=60
    printf 'compact-at-tokens=100000\n' > "$LAB/config/handoff-trigger"
    printf '{"type":"assistant","message":{"model":"claude-test-model","usage":{"input_tokens":90000,"output_tokens":1}}}\n' > "$LAB/transcript"
    hook_output=$(run_hook_fixture PostToolUse)
    printf '%s' "$hook_output" | jq -e '.hookSpecificOutput.additionalContext | contains("handoff")' >/dev/null \
      || fail 'the real hook must arm the lab handoff gate'
    [ -e "$LAB/state/.handoff-trigger.lab-predecessor.0" ] || fail 'the lab handoff gate marker must exist'
  fi
  FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS="$budget" FM_HANDOFF_LAB_MODE="$mode" claude "$LAB/predecessor.sh" &
  echo "$!" >> "$TMP_ROOT/pids"
  for i in $(seq 1 400); do
    [ ! -f "$LAB/rc" ] || return 0
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

# Existing supervisor endpoint metadata outranks an inherited terminal variable.
META_HOME="$TMP_ROOT/meta-home"
mkdir -p "$META_HOME/state"
printf 'backend=orca\nterminal=term_recorded\nworktree=%s\nspawn_gen=s1.1.1\n' "$META_HOME" > "$META_HOME/endpoint"
# shellcheck disable=SC2016 # The harness child expands its own environment.
FM_HOME="$META_HOME" FM_STATE_OVERRIDE="$META_HOME/state" ORCA_TERMINAL_HANDLE=term_inherited \
  FM_SESSION_ENDPOINT_META="$META_HOME/endpoint" claude -c '
    bash "$ROOT/bin/fm-lock.sh" > "$FM_HOME/out" 2>&1
    touch "$FM_HOME/ready"
    while :; do sleep 1; done' &
meta_pid=$!
echo "$meta_pid" >> "$TMP_ROOT/pids"
for i in $(seq 1 200); do [ ! -e "$META_HOME/ready" ] || break; sleep 0.1; done
assert_contains "$(cat "$META_HOME/state/.lock-session")" 'terminal=term_recorded' 'explicit endpoint metadata outranks inherited terminal'
assert_contains "$(cat "$META_HOME/state/.lock-session")" 'spawn_gen=s1.1.1' 'explicit endpoint generation survives'
kill "$meta_pid"; wait "$meta_pid" 2>/dev/null || true
pass 'supervisor endpoint metadata retains precedence and generation'

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
locate=$(bash "$ROOT/bin/fm-captain-locate.sh")
assert_contains "$locate" 'handle=term_lab_1' 'discovery follows lock holder'
assert_contains "$locate" "pid=$(cat "$LAB/state/.lock")" 'discovery names lock pid'
bash "$ROOT/bin/fm-handoff-ack.sh" "$nonce" "$(jq -r .sha256 "$ack")" >/dev/null 2>&1 && fail 'replay from another process must refuse'
pass 'verified successor ack transfers the lock while predecessor remains alive; discovery follows it'
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
pass 'tmux launches direct argv and transfers the verified lock'

run_case success unsupported-backend
[ "$(cat "$LAB/rc")" != 0 ] || fail 'unsupported backend must refuse'
[ ! -e "$LAB/state/attempts" ] || fail 'unsupported backend must not launch'
printf 'auto\n' > "$LAB/config/claude-permission-mode"
run_case success
[ "$(cat "$LAB/rc")" != 0 ] || fail 'unenforceable Orca permission posture must refuse'
[ ! -e "$LAB/state/attempts" ] || fail 'permission refusal must not launch'
rm "$LAB/config/claude-permission-mode"
pass 'unsupported backends and unenforceable permission posture refuse before launch'

for mode in exit parse reject wrong-sha stale expired hung-launch; do
  start=$SECONDS
  run_case "$mode"
  [ "$(cat "$LAB/rc")" != 0 ] || fail "$mode must fail"
  [ "$(cat "$LAB/state/attempts")" = 2 ] || fail "$mode must retry exactly once in a fresh pane"
  [ ! -e "$LAB/state/.handoff-successor" ] || fail "$mode must not clear the stop gate"
  [ "$(cat "$LAB/state/.lock")" = "$(cat "$LAB/pred.pid")" ] || fail "$mode moved predecessor lock"
  grep -q '^HANDOFF v1 .* event=handoff_failed ' "$LAB/state/handoff-events.log" || fail "$mode must emit machine-readable failure"
  [ "$((SECONDS-start))" -lt 30 ] || fail "$mode exceeded bounded lab deadline"
  if [ "$mode" = reject ]; then
    grep -q ' event=handoff_reject ' "$LAB/state/handoff-events.log" || fail 'read-only successor must reject loudly'
  fi
  cat "$LAB/state/handoff-events.log"
  if [ "$mode" = parse ]; then cat "$LAB/state/"successor-*.out; fi
  pass "DRILL $mode: failed within lab deadline, retried once, predecessor lock preserved"
done
