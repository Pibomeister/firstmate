#!/usr/bin/env bash
# The endpoint recorded when a primary session takes the lock.
# Exercises bin/fm-lock.sh and bin/fm-handoff-ack.sh through real processes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-successor-endpoint)
FAKEBIN="$TMP_ROOT/bin"
PIDS="$TMP_ROOT/pids"
mkdir -p "$FAKEBIN"
ln -s /bin/bash "$FAKEBIN/claude"
: > "$PIDS"
export PATH="$FAKEBIN:$PATH"
unset ORCA_TERMINAL_HANDLE ORCA_PANE_KEY TMUX TMUX_PANE ZELLIJ HERDR_ENV HERDR_PANE_ID HERDR_SESSION
unset FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND FM_SESSION_ENDPOINT_META FM_BACKEND
unset CLAUDE_PID CLAUDE_CODE_SESSION_ID TERM_PROGRAM

cleanup_successor_endpoint() {
  local pid
  if [ -f "$PIDS" ]; then
    while read -r pid; do
      [ -n "$pid" ] || continue
      kill "$pid" 2>/dev/null || true
    done < "$PIDS"
  fi
  fm_test_cleanup
}
trap cleanup_successor_endpoint EXIT

cat > "$TMP_ROOT/hold.sh" <<'EOF'
#!/usr/bin/env bash
set -u
export CLAUDE_CODE_SESSION_ID=${FM_LOCK_SESSION:?}
export CLAUDE_PID=$$
bash "$ROOT/bin/fm-lock.sh" > "$FM_HOME/lock.out" 2>&1
echo $? > "$FM_HOME/lock.rc"
echo $$ > "$FM_HOME/holder.pid"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"
fm_session_process_start $$ > "$FM_HOME/holder.start"
touch "$FM_HOME/ready"
while kill -0 "$FM_TEST_SUITE_PID" 2>/dev/null && [ "$SECONDS" -lt 120 ]; do sleep 1; done
EOF

cat > "$TMP_ROOT/ack.sh" <<'EOF'
#!/usr/bin/env bash
set -u
export CLAUDE_CODE_SESSION_ID=${FM_LOCK_SESSION:?}
export CLAUDE_PID=$$
bash "$ROOT/bin/fm-handoff-ack.sh" "$FM_ACK_NONCE" "$FM_ACK_SHA" > "$FM_HOME/ack.out" 2>&1
echo $? > "$FM_HOME/ack.rc"
echo $$ > "$FM_HOME/succ.pid"
touch "$FM_HOME/ack.ready"
while kill -0 "$FM_TEST_SUITE_PID" 2>/dev/null && [ "$SECONDS" -lt 120 ]; do sleep 1; done
EOF
chmod +x "$TMP_ROOT/hold.sh" "$TMP_ROOT/ack.sh"

new_home() {
  local home=$TMP_ROOT/$1
  rm -rf "$home"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

wait_ready() { # <path> <label>
  local limit=$((SECONDS + 30))
  while [ ! -e "$1" ] && [ "$SECONDS" -lt "$limit" ]; do sleep 0.1; done
  [ -e "$1" ] || fail "$2 did not become ready"
}

start_holder() { # <home> <session> then extra env assignments
  local home=$1 session=$2
  shift 2
  env -u ORCA_TERMINAL_HANDLE -u TMUX -u TMUX_PANE -u ZELLIJ \
    -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION \
    -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND -u FM_SESSION_ENDPOINT_META \
    -u TERM_PROGRAM \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
    ROOT="$ROOT" FM_LOCK_SESSION="$session" \
    "$@" claude "$TMP_ROOT/hold.sh" &
  echo $! >> "$PIDS"
}

sidecar_terminal() {
  sed -n 's/^terminal=//p' "$1/state/.lock-session"
}

test_herdr_session_records_its_pane() {
  local home locate
  home=$(new_home herdr)
  start_holder "$home" herdr-session \
    HERDR_ENV=1 HERDR_SESSION=fm-lab HERDR_PANE_ID=w1:p9
  wait_ready "$home/ready" herdr
  assert_equals 0 "$(cat "$home/lock.rc")" "herdr lock refused: $(cat "$home/lock.out")"
  assert_equals "fm-lab:w1:p9" "$(sidecar_terminal "$home")" "herdr pane is the recorded terminal"
  assert_contains "$(cat "$home/state/.lock-session")" "backend=herdr" "herdr backend is recorded"
  locate=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash "$ROOT/bin/fm-captain-locate.sh") \
    || fail "herdr endpoint should be discoverable: $(cat "$home/state/.lock-session")"
  assert_contains "$locate" "handle=fm-lab:w1:p9" "locate names the herdr pane"
  pass "a Herdr session records its pane when it takes the lock"
}

test_undiscoverable_session_records_unknown() {
  local home locate
  home=$(new_home unknown)
  start_holder "$home" unknown-session
  wait_ready "$home/ready" unknown
  assert_equals 0 "$(cat "$home/lock.rc")" "unknown lock refused: $(cat "$home/lock.out")"
  assert_equals unknown "$(sidecar_terminal "$home")" "an unresolved endpoint is recorded as unknown"
  assert_contains "$(cat "$home/state/.lock-session")" "backend=unknown" "the backend is unknown too"
  locate=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash "$ROOT/bin/fm-captain-locate.sh" || true)
  assert_contains "$locate" "handle=none" "unknown is not a terminal handle"
  pass "a session with no confident endpoint records unknown"
}

test_new_session_does_not_keep_the_predecessor_terminal() {
  local home
  home=$(new_home replace)
  start_holder "$home" pred-session TERM_PROGRAM=Orca ORCA_TERMINAL_HANDLE=term_pred
  wait_ready "$home/ready" predecessor
  assert_equals term_pred "$(sidecar_terminal "$home")" "the predecessor records its own terminal"
  kill "$(cat "$home/holder.pid")" 2>/dev/null || true
  wait "$(cat "$home/holder.pid")" 2>/dev/null || true
  rm -f "$home/ready" "$home/lock.rc"
  start_holder "$home" succ-session
  wait_ready "$home/ready" successor
  assert_equals 0 "$(cat "$home/lock.rc")" "successor lock refused: $(cat "$home/lock.out")"
  assert_equals unknown "$(sidecar_terminal "$home")" "the successor does not inherit the predecessor terminal"
  assert_not_contains "$(cat "$home/state/.lock-session")" "term_pred" "the predecessor handle is gone"
  pass "a new session records unknown instead of the predecessor terminal"
}

test_same_session_keeps_its_concrete_endpoint() {
  local home
  home=$(new_home resume)
  start_holder "$home" same-session TERM_PROGRAM=Orca ORCA_TERMINAL_HANDLE=term_same
  wait_ready "$home/ready" "same-session first"
  assert_equals term_same "$(sidecar_terminal "$home")" "the first publication records the live terminal"
  kill "$(cat "$home/holder.pid")" 2>/dev/null || true
  wait "$(cat "$home/holder.pid")" 2>/dev/null || true
  rm -f "$home/ready" "$home/lock.rc"
  start_holder "$home" same-session
  wait_ready "$home/ready" "same-session second"
  assert_equals 0 "$(cat "$home/lock.rc")" "same-session relock refused: $(cat "$home/lock.out")"
  assert_equals term_same "$(sidecar_terminal "$home")" "the same trusted session keeps its concrete endpoint"
  pass "the same trusted session keeps its endpoint when the new process has none"
}

test_explicit_metadata_outranks_a_live_herdr_pane() {
  local home
  home=$(new_home explicit)
  printf 'backend=orca\nterminal=term_explicit\nworktree=%s\nspawn_gen=s1.1.1\n' "$home" > "$home/endpoint"
  start_holder "$home" explicit-session \
    FM_SESSION_ENDPOINT_META="$home/endpoint" \
    HERDR_ENV=1 HERDR_SESSION=fm-lab HERDR_PANE_ID=w1:p9
  wait_ready "$home/ready" explicit
  assert_equals 0 "$(cat "$home/lock.rc")" "explicit lock refused: $(cat "$home/lock.out")"
  assert_equals term_explicit "$(sidecar_terminal "$home")" "explicit launch metadata outranks the live pane"
  assert_contains "$(cat "$home/state/.lock-session")" "spawn_gen=s1.1.1" "explicit metadata keeps its generation"
  pass "explicit endpoint metadata still outranks a live Herdr pane"
}

test_illegal_live_target_fails_publication() {
  local home
  home=$(new_home illegal)
  start_holder "$home" illegal-session FM_SUPERVISOR_TARGET="not a handle"
  wait_ready "$home/ready" illegal
  assert_equals 1 "$(cat "$home/lock.rc")" "an illegal live target must fail the lock: $(cat "$home/lock.out")"
  assert_not_contains "$(cat "$home/state/.lock-session" 2>/dev/null || true)" "not a handle" \
    "an illegal target is not recorded"
  pass "a present but illegal endpoint fails publication"
}

write_claim() { # <home> <nonce> [<predecessor-start>]
  local home=$1 nonce=$2 start=${3:-} doc sha deadline
  doc=$home/handoff.md
  printf 'handoff\n' > "$doc"
  if command -v sha256sum >/dev/null 2>&1; then
    sha=$(sha256sum -- "$doc" | awk '{print $1}')
  else
    sha=$(shasum -a 256 -- "$doc" | awk '{print $1}')
  fi
  deadline=$(( $(date +%s) + 600 ))
  jq -n --arg nonce "$nonce" --arg sha "$sha" --arg doc "$doc" \
    --arg start "${start:-$(cat "$home/holder.start")}" \
    --argjson pid "$(cat "$home/holder.pid")" --argjson deadline "$deadline" \
    '{version:1,nonce:$nonce,handoff:$doc,sha256:$sha,predecessor_pid:$pid,predecessor_start:$start,deadline:$deadline}' \
    > "$home/state/.handoff-pending"
  printf '%s\n' "$sha"
}

test_herdr_ack_records_the_successor_pane() {
  local home nonce sha ack
  home=$(new_home ack-herdr)
  nonce=ab0123456789abcd
  start_holder "$home" pred-session TERM_PROGRAM=Orca ORCA_TERMINAL_HANDLE=term_pred
  wait_ready "$home/ready" "ack predecessor"
  assert_equals term_pred "$(sidecar_terminal "$home")" "the predecessor pane is recorded before the ack"
  sha=$(write_claim "$home" "$nonce")
  env -u ORCA_TERMINAL_HANDLE -u TMUX -u TMUX_PANE -u ZELLIJ \
    -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND -u FM_SESSION_ENDPOINT_META \
    -u TERM_PROGRAM \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
    ROOT="$ROOT" FM_LOCK_SESSION=succ-session FM_ACK_NONCE="$nonce" FM_ACK_SHA="$sha" \
    HERDR_ENV=1 HERDR_SESSION=fm-lab HERDR_PANE_ID=w1:p9 \
    claude "$TMP_ROOT/ack.sh" &
  echo $! >> "$PIDS"
  wait_ready "$home/ack.ready" "herdr ack"
  assert_equals 0 "$(cat "$home/ack.rc")" "herdr ack refused: $(cat "$home/ack.out")"
  assert_equals "fm-lab:w1:p9" "$(sidecar_terminal "$home")" "the committed sidecar names the successor pane"
  ack=$home/data/handoff-ack-$nonce.json
  assert_equals "fm-lab:w1:p9" "$(jq -r .terminal_handle "$ack")" "the ack names the same successor pane"
  kill -0 "$(cat "$home/holder.pid")" || fail "the predecessor must stay alive"
  assert_not_contains "$(cat "$home/state/.lock-session")" "term_pred" "the predecessor handle is not the successor endpoint"
  pass "a Herdr successor ack records its pane and leaves the predecessor alive"
}

test_ack_without_an_endpoint_refuses() {
  local home nonce sha
  home=$(new_home ack-none)
  nonce=cd0123456789abcd
  start_holder "$home" pred-session TERM_PROGRAM=Orca ORCA_TERMINAL_HANDLE=term_pred
  wait_ready "$home/ready" "refused-ack predecessor"
  sha=$(write_claim "$home" "$nonce")
  env -u ORCA_TERMINAL_HANDLE -u TMUX -u TMUX_PANE -u ZELLIJ \
    -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION \
    -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND -u FM_SESSION_ENDPOINT_META \
    -u TERM_PROGRAM \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
    ROOT="$ROOT" FM_LOCK_SESSION=succ-session FM_ACK_NONCE="$nonce" FM_ACK_SHA="$sha" \
    claude "$TMP_ROOT/ack.sh" &
  echo $! >> "$PIDS"
  wait_ready "$home/ack.ready" "refused ack"
  assert_equals 1 "$(cat "$home/ack.rc")" "an ack with no endpoint must refuse: $(cat "$home/ack.out")"
  assert_equals "$(cat "$home/holder.pid")" "$(cat "$home/state/.lock")" "the predecessor keeps the lock"
  assert_equals term_pred "$(sidecar_terminal "$home")" "the predecessor endpoint stays until a real successor commits"
  pass "an acknowledgement with no endpoint does not take the lock"
}

# run_ack <home> <nonce> <sha> [env assignments...]: the successor acks from a
# fresh claude stand-in whose environment holds only the given endpoint markers.
run_ack() {
  local home=$1 nonce=$2 sha=$3
  shift 3
  rm -f "$home/ack.ready" "$home/ack.rc"
  env -u ORCA_TERMINAL_HANDLE -u ORCA_PANE_KEY -u TMUX -u TMUX_PANE -u ZELLIJ \
    -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION \
    -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND -u FM_SESSION_ENDPOINT_META \
    -u TERM_PROGRAM \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
    ROOT="$ROOT" FM_LOCK_SESSION=succ-session FM_ACK_NONCE="$nonce" FM_ACK_SHA="$sha" \
    "$@" claude "$TMP_ROOT/ack.sh" &
  echo $! >> "$PIDS"
  wait_ready "$home/ack.ready" "ack in $home"
}

# The shape of a Codex tool shell that Orca launched under the operator's
# shell_environment_policy inherit="core": Orca forwards its ORCA_* markers,
# and TERM_PROGRAM is absent.
CODEX_ORCA_SHELL=(ORCA_TERMINAL_HANDLE=term_succ ORCA_PANE_KEY=tab_succ:leaf_succ)

test_codex_orca_tool_shell_ack_takes_over() {
  local home nonce sha ack
  home=$(new_home ack-codex-orca)
  nonce=ef0123456789abcd
  start_holder "$home" pred-session TERM_PROGRAM=Orca ORCA_TERMINAL_HANDLE=term_pred
  wait_ready "$home/ready" "codex-orca predecessor"
  sha=$(write_claim "$home" "$nonce")
  run_ack "$home" "$nonce" "$sha" "${CODEX_ORCA_SHELL[@]}"
  assert_equals 0 "$(cat "$home/ack.rc")" "a Codex tool shell in its Orca terminal must acknowledge: $(cat "$home/ack.out")"
  assert_equals "$(cat "$home/succ.pid")" "$(cat "$home/state/.lock")" "the successor takes the lock"
  assert_equals term_succ "$(sidecar_terminal "$home")" "the committed sidecar names the successor's own Orca terminal"
  assert_contains "$(cat "$home/state/.lock-session")" "backend=orca" "the successor endpoint is recorded on Orca"
  ack=$home/data/handoff-ack-$nonce.json
  assert_equals term_succ "$(jq -r .terminal_handle "$ack")" "the ack names the successor's actual terminal"
  assert_contains "$(cat "$home/state/handoff-events.log")" \
    "event=handoff_ack nonce=$nonce attempt=0 pid=$(cat "$home/succ.pid") handle=term_succ reason=lock_transferred" \
    "the takeover is recorded with the real successor pid and terminal"
  kill -0 "$(cat "$home/holder.pid")" || fail "the ack must not stop the predecessor"
  pass "a Codex tool shell without TERM_PROGRAM acknowledges from its Orca terminal and takes the lock"
}

# assert_ack_refused <home> <reason> <label>: the refusal names its reason and
# the real successor pid, and the predecessor keeps the lock and endpoint.
assert_ack_refused() {
  local home=$1 reason=$2 label=$3 events
  assert_equals 1 "$(cat "$home/ack.rc")" "$label must refuse: $(cat "$home/ack.out")"
  events=$(cat "$home/state/handoff-events.log")
  assert_contains "$events" "event=handoff_reject" "$label records a rejection"
  assert_contains "$events" "reason=$reason" "$label names $reason: $events"
  assert_equals "$(cat "$home/holder.pid")" "$(cat "$home/state/.lock")" "$label leaves the lock with the predecessor"
  assert_equals term_pred "$(sidecar_terminal "$home")" "$label keeps the predecessor endpoint"
}

test_codex_orca_tool_shell_refusals() {
  local home nonce sha events
  nonce=fa0123456789abcd

  home=$(new_home refuse-lone-handle)
  start_holder "$home" pred-session TERM_PROGRAM=Orca ORCA_TERMINAL_HANDLE=term_pred
  wait_ready "$home/ready" "lone-handle predecessor"
  sha=$(write_claim "$home" "$nonce")
  run_ack "$home" "$nonce" "$sha" ORCA_TERMINAL_HANDLE=term_succ
  assert_ack_refused "$home" no_terminal "a lone terminal handle with no TERM_PROGRAM"
  events=$(cat "$home/state/handoff-events.log")
  assert_contains "$events" "pid=$(cat "$home/succ.pid") handle=none reason=no_terminal" \
    "the no_terminal refusal names the real successor pid instead of 0: $events"

  home=$(new_home refuse-nested)
  start_holder "$home" pred-session TERM_PROGRAM=Orca ORCA_TERMINAL_HANDLE=term_pred
  wait_ready "$home/ready" "nested predecessor"
  sha=$(write_claim "$home" "$nonce")
  run_ack "$home" "$nonce" "$sha" "${CODEX_ORCA_SHELL[@]}" TERM_PROGRAM=tmux
  assert_ack_refused "$home" no_terminal "Orca markers under a nested terminal program"

  home=$(new_home refuse-zellij)
  start_holder "$home" pred-session TERM_PROGRAM=Orca ORCA_TERMINAL_HANDLE=term_pred
  wait_ready "$home/ready" "zellij predecessor"
  sha=$(write_claim "$home" "$nonce")
  run_ack "$home" "$nonce" "$sha" "${CODEX_ORCA_SHELL[@]}" ZELLIJ=0
  assert_ack_refused "$home" no_terminal "Orca markers inside Zellij"

  home=$(new_home refuse-hash)
  start_holder "$home" pred-session TERM_PROGRAM=Orca ORCA_TERMINAL_HANDLE=term_pred
  wait_ready "$home/ready" "hash predecessor"
  write_claim "$home" "$nonce" >/dev/null
  run_ack "$home" "$nonce" 0000000000000000000000000000000000000000000000000000000000000000 "${CODEX_ORCA_SHELL[@]}"
  assert_ack_refused "$home" hash_mismatch "a wrong document hash"

  home=$(new_home refuse-nonce)
  start_holder "$home" pred-session TERM_PROGRAM=Orca ORCA_TERMINAL_HANDLE=term_pred
  wait_ready "$home/ready" "nonce predecessor"
  sha=$(write_claim "$home" "$nonce")
  run_ack "$home" fb0123456789abcd "$sha" "${CODEX_ORCA_SHELL[@]}"
  assert_ack_refused "$home" stale_nonce "a stale nonce"

  home=$(new_home refuse-reused)
  start_holder "$home" pred-session TERM_PROGRAM=Orca ORCA_TERMINAL_HANDLE=term_pred
  wait_ready "$home/ready" "reused predecessor"
  sha=$(write_claim "$home" "$nonce" "not-the-recorded-start")
  run_ack "$home" "$nonce" "$sha" "${CODEX_ORCA_SHELL[@]}"
  assert_ack_refused "$home" lock_refused "a predecessor pid whose process start does not match the claim"
  pass "Orca tool-shell markers still refuse a lone handle, a nested terminal, Zellij, a wrong hash, a stale nonce, and a reused predecessor pid"
}

fm_test_run \
  test_herdr_session_records_its_pane \
  test_undiscoverable_session_records_unknown \
  test_new_session_does_not_keep_the_predecessor_terminal \
  test_same_session_keeps_its_concrete_endpoint \
  test_explicit_metadata_outranks_a_live_herdr_pane \
  test_illegal_live_target_fails_publication \
  test_herdr_ack_records_the_successor_pane \
  test_ack_without_an_endpoint_refuses \
  test_codex_orca_tool_shell_ack_takes_over \
  test_codex_orca_tool_shell_refusals
