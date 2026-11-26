#!/usr/bin/env bash
# tests/fm-agent-pgrp.test.sh - portable regression for bin/fm-agent-pgrp.sh,
# the launcher that starts every templated worker agent in a process group of
# its own that owns the pane terminal.
#
# It runs REAL processes, and the terminal cases run them in a REAL tmux server
# on a private socket (`-L`), so it needs no harness and no credentials. Each
# isolation case first runs the same cleanup WITHOUT the launcher and asserts
# that it kills the agent, so the protected case cannot pass vacuously.
#
# The scenario is a cleanup trap or test-runner teardown that signals the
# process group it inherited (`kill -TERM 0`) while sharing that group with the
# shell that started the agent - the shape a pane shell without job control
# gives every command it runs. The control half asserts that the deliberate
# paths still reach the agent: a signal addressed to the agent itself, a
# terminal-generated interrupt, and closing the endpoint.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

PGRP="$ROOT/bin/fm-agent-pgrp.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-agent-pgrp.XXXXXX")
SOCKET="fm-agent-pgrp-$$"
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
SESSION=pgrp

cleanup_all() {
  [ -z "$REAL_TMUX" ] || "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
  fm_test_cleanup
}
trap cleanup_all EXIT

STANDIN_BIN=$(fm_agent_standin "$LAB/standin") || {
  echo "skip: no long-running stand-in binary survives a rename (multicall coreutils, no C compiler)"
  exit 0
}
mkdir -p "$LAB/bin"
# Named after a verified harness so the tmux liveness classifier recognizes it.
ln -s "$STANDIN_BIN" "$LAB/bin/claude"
AGENT="$LAB/bin/claude"

wait_for() {  # <tries> <command...>
  local tries=$1 i=0
  shift
  while [ "$i" -lt "$tries" ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

file_has() { [ -s "$1" ]; }
pid_gone() { ! kill -0 "$1" 2>/dev/null; }
pgid_of() { ps -o pgid= -p "$1" 2>/dev/null | tr -d '[:space:]'; }

# --- exit status ------------------------------------------------------------

"$PGRP" sh -c 'exit 3'
assert_equals 3 "$?" "a plain exit status must pass through the launcher"
"$PGRP" sh -c 'kill -TERM $$'
assert_equals 143 "$?" "a signal death must be reported as 128+N"
"$PGRP" "$LAB/no-such-agent" 2>/dev/null
assert_equals 127 "$?" "an agent that cannot be executed must exit 127"
pass "fm-agent-pgrp: exit status, signal death, and a missing command are reported as a shell would"

# --- a group signal from the launching side, without a terminal -------------
# <group-runner> is a non-interactive bash, so the launch and its sibling cleanup
# share one process group. The sibling waits for the go file, then signals that
# group, recording that it fired. The runner itself survives by catching TERM.

run_group_case() {  # <dir> <with|without>
  local dir=$1 mode=$2
  mkdir -p "$dir"
  # Job control gives the runner a group of its own, so the sibling's signal
  # never reaches this test script.
  set -m
  bash -c '
    dir=$1 mode=$2 pgrp=$3 agent=$4
    trap : TERM
    (i=0; while [ ! -e "$dir/go" ] && [ "$i" -lt 600 ]; do sleep 0.05; i=$((i + 1)); done
      echo fired > "$dir/sibling.log"; kill -TERM 0) &
    if [ "$mode" = with ]; then
      "$pgrp" "$agent" 900 &
    else
      "$agent" 900 &
    fi
    launch=$!
    echo "$launch" > "$dir/launch.pid"
    echo "$$" > "$dir/runner.pid"
    # A trapped signal interrupts wait, so wait until the launch really ended.
    while :; do
      wait "$launch"
      rc=$?
      kill -0 "$launch" 2>/dev/null || break
    done
    echo "$rc" > "$dir/launch.rc"
  ' _ "$dir" "$mode" "$PGRP" "$AGENT" &
  echo "$!" > "$dir/bg.pid"
  set +m
}

# The stand-in agent: the launch itself or its direct child, whichever runs it.
agent_pid_under() {  # <launch-pid>
  local pid
  for pid in "$1" $(pgrep -P "$1" 2>/dev/null); do
    [ "$(ps -o comm= -p "$pid" 2>/dev/null | sed 's#.*/##')" = claude ] && { printf '%s' "$pid"; return 0; }
  done
  return 1
}

test_group_signal_without_terminal() {
  local dir mode launch agent runner rc
  for mode in without with; do
    dir="$LAB/group-$mode"
    run_group_case "$dir" "$mode"
    wait_for 100 file_has "$dir/launch.pid" || fail "$mode: the launch never started"
    launch=$(cat "$dir/launch.pid")
    runner=$(cat "$dir/runner.pid")
    wait_for 100 agent_pid_under "$launch" >/dev/null || fail "$mode: the agent process never appeared"
    agent=$(agent_pid_under "$launch")
    if [ "$mode" = with ]; then
      # The divergence the launcher exists for: the agent leads its own group.
      assert_equals "$agent" "$(pgid_of "$agent")" "the launched agent must lead its own process group"
      [ "$(pgid_of "$agent")" != "$(pgid_of "$runner")" ] \
        || fail "the launched agent still shares the launching shell's process group"
    else
      assert_equals "$(pgid_of "$runner")" "$(pgid_of "$agent")" \
        "baseline: an unwrapped agent must share the launching shell's group, or this case proves nothing"
    fi
    : > "$dir/go"
    wait_for 50 file_has "$dir/sibling.log" || fail "$mode: the sibling cleanup never signalled its group"
    if [ "$mode" = without ]; then
      wait_for 50 pid_gone "$agent" \
        || fail "baseline: the group signal did not kill the unwrapped agent, so the isolated case would be vacuous"
    else
      sleep 0.5
      kill -0 "$agent" 2>/dev/null || fail "the group signal from the launching side killed the isolated agent"
      kill -0 "$launch" 2>/dev/null || fail "the group signal killed the launcher and orphaned the agent"
      # The control path: a signal addressed to the agent itself still stops it,
      # and the launcher reports that death and exits with it.
      kill -TERM "$agent"
      wait_for 50 file_has "$dir/launch.rc" || fail "the launcher did not exit after its agent was stopped"
      rc=$(cat "$dir/launch.rc")
      assert_equals 143 "$rc" "the launcher must report the agent's SIGTERM death"
      pid_gone "$agent" || fail "a SIGTERM addressed to the agent did not stop it"
    fi
    wait "$(cat "$dir/bg.pid")" 2>/dev/null || true
  done
  pass "fm-agent-pgrp: a sibling's group signal kills an unwrapped agent but not an isolated one, and a signal to the agent still stops it"
}
test_group_signal_without_terminal

# --- the same in a real terminal --------------------------------------------

if [ -z "$REAL_TMUX" ]; then
  echo "ok - skipped: tmux is not installed, so the terminal cases did not run"
  exit 0
fi

mkdir -p "$LAB/shim" "$LAB/wt"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n idle -c "$LAB/wt" -- /bin/sh \
  || fail "could not start the private tmux server"

# The pane process is a non-interactive sh: no job control, so everything it
# starts shares its process group unless something isolates it. It catches
# TERM (a caught signal reverts to default across exec, so the agent's own
# disposition stays default), starts the sibling cleanup, which records that it
# fired because a shell defers a trap until its foreground command ends, runs
# the agent in the foreground, records the launch status, and then idles.
pane_window() {  # <name> <with|without>
  local name=$1 mode=$2 dir="$LAB/pane-$1" launch
  mkdir -p "$dir"
  if [ "$mode" = with ]; then
    launch="'$PGRP' '$AGENT' 900"
  else
    launch="'$AGENT' 900"
  fi
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$name" -c "$LAB/wt" -- /bin/sh -c "
    trap : TERM
    (i=0; while [ ! -e \"$dir/go\" ] && [ \"\$i\" -lt 600 ]; do sleep 0.05; i=\$((i + 1)); done
      echo fired > \"$dir/sibling.log\"; kill -TERM 0) &
    $launch
    echo \$? > \"$dir/launch.rc\"
    exec sleep 600
  " || fail "could not create window $name"
}

foreground_agent_pid() {  # <target>
  fm_backend_tmux_foreground_pids "$1" | while IFS= read -r pid; do
    [ "$(ps -o comm= -p "$pid" 2>/dev/null | sed 's#.*/##')" = claude ] && { printf '%s' "$pid"; break; }
  done
}

agent_alive_in() { [ "$(fm_backend_agent_state tmux "$1")" = alive ]; }

test_group_signal_in_terminal() {
  local mode name target dir agent pane_pid
  for mode in without with; do
    name="term-$mode"
    target="$SESSION:$name"
    dir="$LAB/pane-$name"
    pane_window "$name" "$mode"
    wait_for 100 agent_alive_in "$target" || fail "$mode: the agent never read alive in its pane"
    agent=$(foreground_agent_pid "$target")
    [ -n "$agent" ] || fail "$mode: the agent is not in the pane terminal's foreground process group"
    pane_pid=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$target" '#{pane_pid}')
    if [ "$mode" = with ]; then
      [ "$(pgid_of "$agent")" != "$(pgid_of "$pane_pid")" ] \
        || fail "the isolated agent still shares the pane shell's process group"
    else
      assert_equals "$(pgid_of "$pane_pid")" "$(pgid_of "$agent")" \
        "baseline: an unwrapped agent under a pane shell without job control must share its group"
    fi
    : > "$dir/go"
    wait_for 50 file_has "$dir/sibling.log" || fail "$mode: the sibling cleanup never signalled the pane group"
    if [ "$mode" = without ]; then
      wait_for 50 pid_gone "$agent" \
        || fail "baseline: the pane-group signal did not kill the unwrapped agent, so the isolated case would be vacuous"
    else
      sleep 0.5
      kill -0 "$agent" 2>/dev/null || fail "the pane-group signal killed the isolated agent"
      agent_alive_in "$target" || fail "the isolated agent no longer reads alive after the stray signal"
      # The interrupt path: a terminal-generated interrupt reaches the
      # foreground group, so the agent still receives it.
      "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" C-c
      wait_for 50 file_has "$dir/launch.rc" || fail "a terminal interrupt did not reach the isolated agent"
      assert_equals 130 "$(cat "$dir/launch.rc")" "the launcher must report the agent's SIGINT death"
      pid_gone "$agent" || fail "the agent survived a terminal interrupt"
    fi
  done
  pass "fm-agent-pgrp: in a real pane, a stray group signal kills an unwrapped agent but not an isolated one, which still owns the terminal and takes its interrupt"
}
test_group_signal_in_terminal

test_endpoint_close_still_stops_the_agent() {
  local name=close target agent
  target="$SESSION:$name"
  pane_window "$name" with
  wait_for 100 agent_alive_in "$target" || fail "close: the agent never read alive in its pane"
  agent=$(foreground_agent_pid "$target")
  [ -n "$agent" ] || fail "close: the agent is not in the pane terminal's foreground process group"
  fm_backend_tmux_kill "$target" || fail "close: the endpoint could not be closed"
  wait_for 50 pid_gone "$agent" || fail "closing the endpoint did not stop the isolated agent"
  pass "fm-agent-pgrp: closing the endpoint still stops the isolated agent"
}
test_endpoint_close_still_stops_the_agent
