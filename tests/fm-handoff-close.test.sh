#!/usr/bin/env bash
# bin/fm-handoff-close.sh: after a committed verified handoff the predecessor's
# recorded terminal is closed on tmux and Orca; an uncommitted, expired,
# unresolved, unprovable, or unsupported case closes nothing and records why.
# tmux and orca are fakes on PATH that act only on fixture processes; the
# harnesses are /bin/bash under the claude name; lock, ack, and close are real.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-handoff-close)
trap 'test_cleanup' EXIT
test_cleanup() {
  kill_fixtures
  fm_test_cleanup
}
LAB="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
FAKE="$TMP_ROOT/fake"
PIDS="$TMP_ROOT/pids"
mkdir -p "$LAB/state" "$LAB/data" "$FAKEBIN" "$FAKE"
: > "$PIDS"
ln -s /bin/bash "$FAKEBIN/claude"
# A pane or Orca terminal is a file naming its root pid. Closing one records
# the close and hangs up the root's whole tree, as a real close does.
cat > "$FAKEBIN/fake-kill-tree" <<'EOF'
#!/usr/bin/env bash
# One process-table snapshot: a ps per node can outlast the close's 5 s bound
# on a loaded host, which stops this fake before it signals anything.
table=$(ps -axo pid=,ppid=)
kill_tree() {
  local child
  for child in $(awk -v r="$1" '$2 == r { print $1 }' <<<"$table"); do kill_tree "$child"; done
  kill -HUP "$1" 2>/dev/null || true
}
[ -e "$FAKE/close-ignored" ] || kill_tree "$1"
EOF
cat > "$FAKEBIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -eu
echo "$*" >> "$FAKE/tmux.calls"
case "$1" in
  display-message)
    [ "$2 $3" = '-p -t' ] || exit 96
    # Real tmux (3.6a) answers a gone pane id with exit 0 and an empty line.
    [ -f "$FAKE/pane$4" ] || { echo; exit 0; }
    case "$5" in
      '#{pane_pid}') cat "$FAKE/pane$4" ;;
      '#{pane_id}') printf '%s\n' "$4" ;;
      *) exit 97 ;;
    esac
    ;;
  kill-pane)
    [ "$2" = -t ] && [ -f "$FAKE/pane$3" ] || exit 1
    echo "tmux $3" >> "$FAKE/closed"
    root=$(cat "$FAKE/pane$3")
    [ -e "$FAKE/close-ignored" ] || rm -f "$FAKE/pane$3"
    fake-kill-tree "$root"
    ;;
  *) exit 94 ;;
esac
EOF
cat > "$FAKEBIN/orca" <<'EOF'
#!/usr/bin/env bash
set -eu
echo "$*" >> "$FAKE/orca.calls"
case "$1 $2" in
  'terminal show')
    [ "$3" = --terminal ] || exit 96
    if [ -e "$FAKE/orca-$4.closed" ]; then
      printf '{"ok":false,"error":{"code":"terminal_handle_stale"}}\n'
      exit 1
    fi
    [ -f "$FAKE/orca-$4" ] || exit 1
    jq -n --arg handle "$4" --arg host "$(cat "$FAKE/orca-host" 2>/dev/null || echo local)" --arg wt "$FM_HOME" \
      '{ok:true,result:{terminal:{handle:$handle,connected:true,writable:true,executionHostId:$host,ptyId:("pty-" + $handle),worktreePath:$wt}}}'
    ;;
  'diagnostics memory')
    sessions='[]'
    for f in "$FAKE"/orca-*; do
      case "$f" in *.closed|*/orca-host|*/orca.calls) continue ;; esac
      [ -f "$f" ] || continue
      h=${f##*/orca-}
      sessions=$(jq -c --arg id "pty-$h" --argjson pid "$(cat "$f")" '. + [{sessionId:$id,pid:$pid}]' <<<"$sessions")
    done
    jq -n --argjson s "$sessions" '{ok:true,result:{worktrees:[{sessions:$s}]}}'
    ;;
  'terminal close')
    [ "$3" = --terminal ] && [ -f "$FAKE/orca-$4" ] || exit 1
    echo "orca $4" >> "$FAKE/closed"
    [ -e "$FAKE/close-ignored" ] || touch "$FAKE/orca-$4.closed"
    fake-kill-tree "$(cat "$FAKE/orca-$4")"
    ;;
  *) exit 91 ;;
esac
EOF
chmod +x "$FAKEBIN/fake-kill-tree" "$FAKEBIN/tmux" "$FAKEBIN/orca"
export PATH="$FAKEBIN:$PATH" FAKE ROOT
export FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_ORCA_CLI_CACHE=0
export FM_HANDOFF_CLOSE_RECORD_WAIT_SECS=0 FM_HANDOFF_CLOSE_VERIFY_SECS=10
unset TMUX TMUX_PANE ORCA_TERMINAL_HANDLE TERM_PROGRAM FM_BACKEND FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND
unset HERDR_ENV HERDR_PANE_ID HERDR_SESSION ZELLIJ CLAUDE_PID CLAUDE_CODE_SESSION_ID FM_SESSION_ENDPOINT_META
STATE="$LAB/state"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-handoff-lib.sh
. "$ROOT/bin/fm-handoff-lib.sh"
DOC="$LAB/data/handoff.md"
printf '# Handoff\nRead this document.\n' > "$DOC"
SHA=$(fm_handoff_hash "$DOC")
NONCE=0123456789abcdef0123456789abcdef

kill_fixtures() {
  local pid
  while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$PIDS"
  : > "$PIDS"
}
# start_fixture <name> <with-harness-child:0|1>: a detached root process; with 1
# it is a plain shell whose child is a claude harness, as a terminal hosts one.
# Writes <name>.root and, with a child, <name>.pid.
start_fixture() {
  local name=$1 child=$2 limit
  # shellcheck disable=SC2016 # The fixture shells expand their own variables.
  local loop='while kill -0 "$FM_TEST_SUITE_PID" 2>/dev/null && [ "$SECONDS" -lt 300 ]; do sleep 0.2; done'
  if [ "$child" = 1 ]; then
    # shellcheck disable=SC2016 # The root shell expands its own variables.
    (bash -c 'echo "$$" > "$1.root"; claude -c "$2" & echo "$!" > "$1.pid"; wait' fixture "$TMP_ROOT/$name" "$loop" &)
  else
    # shellcheck disable=SC2016 # The harness shell expands its own variables.
    (claude -c 'echo "$$" > "$1.root"; '"$loop" fixture "$TMP_ROOT/$name" &)
  fi
  limit=$((SECONDS + 30))
  while { [ ! -s "$TMP_ROOT/$name.root" ] || { [ "$child" = 1 ] && [ ! -s "$TMP_ROOT/$name.pid" ]; }; } \
    && [ "$SECONDS" -lt "$limit" ]; do sleep 0.05; done
  [ -s "$TMP_ROOT/$name.root" ] || fail "fixture $name did not start"
  cat "$TMP_ROOT/$name.root" >> "$PIDS"
  [ "$child" = 0 ] || cat "$TMP_ROOT/$name.pid" >> "$PIDS"
  [ "$child" = 1 ] || cp "$TMP_ROOT/$name.root" "$TMP_ROOT/$name.pid"
}
alive() { kill -0 "$1" 2>/dev/null; }
wait_gone() { # <pid>
  local limit=$((SECONDS + 10))
  while alive "$1" && [ "$SECONDS" -lt "$limit" ]; do sleep 0.05; done
  ! alive "$1"
}

# setup <backend> <terminal> [committed:1|0]: a predecessor in its own
# terminal, a successor elsewhere, the lock and sidecar, and the ack.
setup() {
  local backend=$1 terminal=$2 committed=${3:-1} holder start
  kill_fixtures
  rm -rf "${TMP_ROOT:?}"/pred.* "${TMP_ROOT:?}"/succ.* "${FAKE:?}"/* "$STATE"/.lock* "$STATE"/.handoff-* "$STATE/handoff-events.log" "$LAB"/data/handoff-ack-*
  start_fixture pred 1
  start_fixture succ 0
  PRED=$(cat "$TMP_ROOT/pred.pid") SUCC=$(cat "$TMP_ROOT/succ.pid")
  case "$backend" in
    tmux) cp "$TMP_ROOT/pred.root" "$FAKE/pane$terminal" ;;
    orca) cp "$TMP_ROOT/pred.root" "$FAKE/orca-$terminal" ;;
  esac
  holder=$SUCC
  [ "$committed" = 1 ] || holder=$PRED
  start=$(fm_session_process_start "$holder")
  printf '%s\n' "$holder" > "$STATE/.lock"
  printf '\nanchor_pid=%s\nanchor_start=%s\nbackend=orca\nterminal=term_successor\nworktree=%s\n' "$holder" "$start" "$LAB" > "$STATE/.lock-session"
  jq -n --arg nonce "$NONCE" --arg sha "$SHA" --arg doc "$DOC" --argjson pid "$SUCC" --arg start "$(fm_session_process_start "$SUCC")" \
    --argjson ppid "$PRED" --arg pstart "$(fm_session_process_start "$PRED")" --arg pb "$backend" --arg pt "$terminal" \
    '{version:1,nonce:$nonce,sha256:$sha,harness_pid:$pid,fm_lock_pid:$pid,harness_start:$start,terminal_handle:"term_successor",
      handoff:$doc,predecessor_pid:$ppid,predecessor_start:$pstart,predecessor_backend:$pb,predecessor_terminal:$pt}' \
    > "$LAB/data/handoff-ack-$NONCE.json"
  printf 'pid=%s\nnonce=%s\n' "$SUCC" "$NONCE" > "$STATE/.handoff-successor"
}
close() {
  CLOSE_RC=0
  CLOSE_OUT=$(bash "$ROOT/bin/fm-handoff-close.sh" "${1:-$NONCE}" 2>&1) || CLOSE_RC=$?
}
# refused <reason> <handle>: one refusal row, nothing closed, both alive.
refused() {
  [ "$CLOSE_RC" = 1 ] || fail "$1 must exit 1: $CLOSE_OUT"
  [ "$(grep -c ' event=predecessor_close' "$STATE/handoff-events.log")" = 1 ] || fail "$1 must write exactly one row: $(cat "$STATE/handoff-events.log")"
  grep -q "^HANDOFF v1 ts=[0-9]* event=predecessor_close_refused nonce=$NONCE attempt=0 pid=$PRED handle=$2 reason=$1\$" "$STATE/handoff-events.log" \
    || fail "expected refusal $1 for $2: $(cat "$STATE/handoff-events.log")"
  assert_contains "$CLOSE_OUT" "reason=$1" "the refusal row is also printed"
  [ ! -e "$FAKE/closed" ] || fail "$1 must close nothing: $(cat "$FAKE/closed")"
  alive "$PRED" || fail "$1 must leave the predecessor running"
  alive "$SUCC" || fail "$1 must leave the successor running"
}

# A committed transfer closes the recorded tmux pane and the predecessor.
setup tmux %5
close
[ "$CLOSE_RC" = 0 ] || fail "committed tmux close must succeed: $CLOSE_OUT"
[ "$(cat "$FAKE/closed")" = 'tmux %5' ] || fail "only the recorded pane closes: $(cat "$FAKE/closed")"
wait_gone "$PRED" || fail 'the predecessor must be gone'
alive "$SUCC" || fail 'the successor must survive'
grep -q "^HANDOFF v1 ts=[0-9]* event=predecessor_closed nonce=$NONCE attempt=0 pid=$PRED handle=tmux:%5 reason=closed\$" "$STATE/handoff-events.log" \
  || fail "the close row must name the handoff, endpoint, and result: $(cat "$STATE/handoff-events.log")"
[ "$(grep -c ' event=predecessor_' "$STATE/handoff-events.log")" = 1 ] || fail 'one row per close'
pass 'a committed transfer closes the recorded tmux pane and records one row'

# The same on Orca: a connected local terminal of this home.
setup orca term_pred
close
[ "$CLOSE_RC" = 0 ] || fail "committed Orca close must succeed: $CLOSE_OUT"
[ "$(cat "$FAKE/closed")" = 'orca term_pred' ] || fail "only the recorded terminal closes: $(cat "$FAKE/closed")"
wait_gone "$PRED" || fail 'the predecessor must be gone'
alive "$SUCC" || fail 'the successor must survive'
grep -q " event=predecessor_closed nonce=$NONCE attempt=0 pid=$PRED handle=orca:term_pred reason=closed\$" "$STATE/handoff-events.log" \
  || fail "the Orca close row: $(cat "$STATE/handoff-events.log")"
pass 'a committed transfer closes the recorded Orca terminal and records one row'

# Not committed: the lock still names the predecessor.
setup tmux %5 0
close
refused not_committed tmux:%5
# An ack that no longer validates, as for a handoff whose transfer never
# resolved to this successor, is not a commit either.
setup orca term_pred
jq '.sha256 = "0000"' "$LAB/data/handoff-ack-$NONCE.json" > "$TMP_ROOT/ack" && mv "$TMP_ROOT/ack" "$LAB/data/handoff-ack-$NONCE.json"
close
refused not_committed orca:term_pred
pass 'an uncommitted or unvalidated transfer closes nothing'

# An unresolved nonce with no ack has nothing bound to close.
setup tmux %5
close fedcba9876543210fedcba9876543210
[ "$CLOSE_RC" = 1 ] || fail 'a nonce without an ack must refuse'
grep -q ' event=predecessor_close_refused nonce=fedcba9876543210fedcba9876543210 .* handle=none reason=invalid_ack$' "$STATE/handoff-events.log" \
  || fail "missing ack refusal: $(cat "$STATE/handoff-events.log")"
{ [ ! -e "$FAKE/closed" ] && alive "$PRED"; } || fail 'a nonce without an ack must close nothing'
pass 'an unresolved handoff with no ack closes nothing'

# A transfer the launcher never recorded as complete, or reported failed or
# unresolved before a late ack committed it, closes nothing.
setup tmux %5
rm -f "$STATE/.handoff-successor"
close
refused not_completed tmux:%5
setup orca term_pred
printf 'at=%s pid=%s nonce=%s attempt=1 reason=unresolved\n' "$(date +%s)" "$PRED" "$NONCE" > "$STATE/.handoff-launch-failed"
close
refused launch_failed orca:term_pred
setup tmux %5
printf 'pid=%s\nnonce=%s\n' "$PRED" "$NONCE" > "$STATE/.handoff-successor"
close
refused not_completed tmux:%5
pass 'a handoff the launcher did not complete, or reported failed, closes nothing'

# An expired claim is rejected by the real ack before any lock work or close.
setup tmux %5 0
jq -n --arg nonce "$NONCE" --arg sha "$SHA" --arg doc "$DOC" --argjson pid "$PRED" --arg start "$(fm_session_process_start "$PRED")" \
  '{version:1,nonce:$nonce,handoff:$doc,sha256:$sha,predecessor_pid:$pid,predecessor_start:$start,deadline:0,successor:"",
    predecessor_backend:"tmux",predecessor_terminal:"%5"}' > "$STATE/.handoff-pending"
rm -f "$LAB/data/handoff-ack-$NONCE.json"
# shellcheck disable=SC2016 # The harness child expands its own arguments.
TMUX_PANE=%7 claude -c 'bash "$ROOT/bin/fm-handoff-ack.sh" "$1" "$2"' ack "$NONCE" "$SHA" > "$TMP_ROOT/ack.out" 2>&1 && fail 'an expired claim must be rejected'
assert_contains "$(cat "$TMP_ROOT/ack.out")" 'reason=expired_claim' 'the ack names the expiry'
grep -q ' event=predecessor_' "$STATE/handoff-events.log" && fail 'an expired handoff must not attempt a close'
[ "$(cat "$STATE/.lock")" = "$PRED" ] || fail 'an expired handoff keeps the predecessor lock'
{ [ ! -e "$FAKE/closed" ] && alive "$PRED"; } || fail 'an expired handoff must close nothing'
pass 'an expired handoff closes nothing'

# A backend without a supported close is reported and its tool is never run.
setup tmux %5
jq '.predecessor_backend = "herdr" | .predecessor_terminal = "lab:p1"' "$LAB/data/handoff-ack-$NONCE.json" > "$TMP_ROOT/ack" \
  && mv "$TMP_ROOT/ack" "$LAB/data/handoff-ack-$NONCE.json"
printf '#!/bin/sh\ntouch "%s/herdr-ran"\n' "$FAKE" > "$FAKEBIN/herdr"
chmod +x "$FAKEBIN/herdr"
close
refused unsupported_backend herdr:lab:p1
[ ! -e "$FAKE/herdr-ran" ] || fail 'an unsupported backend tool must not run'
rm -f "$FAKEBIN/herdr"
pass 'an unsupported backend is reported and nothing is killed'

# No concrete endpoint was recorded for the predecessor.
setup tmux %5
jq '.predecessor_backend = null | .predecessor_terminal = null' "$LAB/data/handoff-ack-$NONCE.json" > "$TMP_ROOT/ack" \
  && mv "$TMP_ROOT/ack" "$LAB/data/handoff-ack-$NONCE.json"
close
refused no_endpoint none
# The successor's own terminal is never closed.
setup orca term_successor
close
refused own_endpoint orca:term_successor
setup tmux %5
TMUX_PANE=%5 close
refused own_endpoint tmux:%5
pass 'a missing endpoint or the successor own terminal is refused'

# The recorded endpoint must still host the predecessor, and only it.
setup tmux %5
start_fixture stranger 0
cp "$TMP_ROOT/stranger.root" "$FAKE/pane%5"
close
refused endpoint_unproven tmux:%5
alive "$(cat "$TMP_ROOT/stranger.root")" || fail 'an unrelated pane process must survive'
setup tmux %5
cp "$TMP_ROOT/succ.root" "$FAKE/pane%5"
close
refused endpoint_unproven tmux:%5
# A missing pane cannot be proven.
setup tmux %5
rm -f "$FAKE/pane%5"
close
refused endpoint_unproven tmux:%5
# An Orca terminal on another execution host or in another worktree.
setup orca term_pred
echo remote-host > "$FAKE/orca-host"
close
refused endpoint_unproven orca:term_pred
pass 'an endpoint that cannot be proven to host the predecessor is refused'

# A root that also hosts the successor is never closed.
setup tmux %5
# The pane is the predecessor's own root shell; a fake ps reports that shell
# as the successor's parent too.
REAL_PS=$(command -v ps)
printf '#!/usr/bin/env bash\nif [ "$*" = "-o ppid= -p %s" ]; then echo %s; exit 0; fi\nexec %q "$@"\n' "$SUCC" "$(cat "$TMP_ROOT/pred.root")" "$REAL_PS" > "$FAKEBIN/ps"
chmod +x "$FAKEBIN/ps"
close
rm -f "$FAKEBIN/ps"
refused successor_in_endpoint tmux:%5
pass 'an endpoint that also hosts the successor is refused'

# A predecessor that already exited, or was replaced, is not closed.
setup tmux %5
kill "$PRED"
wait_gone "$PRED" || fail 'fixture predecessor did not exit'
close
[ "$CLOSE_RC" = 1 ] || fail 'an exited predecessor must refuse'
grep -q " event=predecessor_close_refused nonce=$NONCE attempt=0 pid=$PRED handle=tmux:%5 reason=predecessor_exited\$" "$STATE/handoff-events.log" \
  || fail "exited predecessor refusal: $(cat "$STATE/handoff-events.log")"
[ ! -e "$FAKE/closed" ] || fail 'an exited predecessor closes nothing'
setup tmux %5
jq '.predecessor_start = "another-instance"' "$LAB/data/handoff-ack-$NONCE.json" > "$TMP_ROOT/ack" \
  && mv "$TMP_ROOT/ack" "$LAB/data/handoff-ack-$NONCE.json"
close
refused predecessor_exited tmux:%5
pass 'an exited or replaced predecessor instance is not closed'

# A close the backend accepted but that left the endpoint is reported as failed.
setup orca term_pred
touch "$FAKE/close-ignored"
FM_HANDOFF_CLOSE_VERIFY_SECS=1 close
[ "$CLOSE_RC" = 1 ] || fail 'an unproven close must not report success'
grep -q " event=predecessor_close_failed nonce=$NONCE attempt=0 pid=$PRED handle=orca:term_pred reason=endpoint_present\$" "$STATE/handoff-events.log" \
  || fail "close failure row: $(cat "$STATE/handoff-events.log")"
grep -q ' event=predecessor_closed ' "$STATE/handoff-events.log" && fail 'an unproven close is never recorded as closed'
pass 'a close that leaves the endpoint running is recorded as failed, not closed'
