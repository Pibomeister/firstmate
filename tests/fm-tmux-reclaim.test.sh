#!/usr/bin/env bash
# Behavior tests for the tmux half of the control plane's absence proof
# (fm_control_endpoint_absence_verdict, bin/fm-control-lib.sh) against a real
# tmux server on a private socket: an endpoint is proven gone only when its
# recorded server is gone (or replaced) or its window id is gone from that same
# server, and nothing holds the task's copy as its working directory; a stopped
# server, an unlinked socket, a renamed window, a pane in the copy, a holder
# (through a symlinked path), and a record without the server identity all
# stay unproven. Every tmux call here names its private socket with -S and runs
# with the ambient pane identity removed, so the operator's server is never
# addressed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v tmux >/dev/null 2>&1 || ! command -v lsof >/dev/null 2>&1; then
  pass "SKIP: tmux and lsof are needed for the real-server tmux proof cases"
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-tmux-reclaim)
SOCKDIR=$(mktemp -d /tmp/fmr.XXXXXX)
SOCK="$SOCKDIR/s"
HOLDERS=
suite_cleanup() {
  local p
  for p in $HOLDERS; do kill -CONT "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
  env -u TMUX -u TMUX_PANE tmux -S "$SOCK" kill-server >/dev/null 2>&1 || true
  rm -rf "$SOCKDIR"
  fm_test_cleanup
}
trap suite_cleanup EXIT

t() { env -u TMUX -u TMUX_PANE tmux -S "$SOCK" "$@"; }

# A fresh private server holding the task's window (cwd in the copy) and an
# unrelated session, and a record of it; prints the record path.
start_task() {  # <name> -> meta path
  local dir=$TMP_ROOT/$1 wt pid wid identity
  wt="$dir/wt"
  mkdir -p "$wt" "$dir/state"
  t kill-server >/dev/null 2>&1 || true
  t -f /dev/null new-session -d -s other -c / 'sleep 600'
  t new-session -d -s fmses -n fm-t1 -c "$wt" 'sleep 600'
  pid=$(t display-message -p '#{pid}')
  wid=$(t display-message -p -t fmses:fm-t1 '#{window_id}')
  identity=$(bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$ROOT" "$pid" | tr '\t\n' '  ')
  identity=${identity% }
  printf 'window=fmses:fm-t1\nworktree=%s\nkind=ship\ntmux_socket=%s\ntmux_server_pid=%s\ntmux_server_identity=%s\ntmux_window_id=%s\n' \
    "$wt" "$SOCK" "$pid" "$identity" "$wid" > "$dir/state/t1.meta"
  printf '%s\n' "$dir/state/t1.meta"
}

verdict() {  # <meta> -> "<verdict>\t<reason>"
  bash -c '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-control-lib.sh"; fm_control_endpoint_absence_verdict tmux fmses:fm-t1 "$2"' \
    _ "$ROOT" "$1" 2>/dev/null
}

expect_verdict() {  # <meta> <verdict> <why>
  local got
  got=$(verdict "$1")
  [ "${got%%	*}" = "$2" ] || fail "$3: expected $2, got '$got'"
}

test_window_still_present_or_renamed_is_unproven() {
  local meta
  meta=$(start_task present)
  expect_verdict "$meta" unproven "a live window on the recorded server"
  t rename-window -t fmses:fm-t1 renamed
  expect_verdict "$meta" unproven "the same window under another name"
  pass "tmux proof: the recorded window id on the live recorded server is never gone, under any name"
}

test_window_gone_from_the_same_server_is_gone_unless_a_pane_is_in_the_copy() {
  local meta wt
  meta=$(start_task window-gone)
  wt=$(dirname "$(dirname "$meta")")/wt
  t new-window -d -t fmses -n stray -c "$wt" 'sleep 600'
  t kill-window -t fmses:fm-t1
  expect_verdict "$meta" unproven "another pane of the recorded server sits in the copy"
  t kill-window -t fmses:stray
  expect_verdict "$meta" gone "the window id gone from the same live server"
  pass "tmux proof: a window gone from its live server is gone only when no pane of it is in the copy"
}

test_killed_or_replaced_server_is_gone() {
  local meta
  meta=$(start_task killed)
  t kill-server
  expect_verdict "$meta" gone "the recorded server killed"
  t -f /dev/null new-session -d -s other -c / 'sleep 600'
  expect_verdict "$meta" gone "the recorded server replaced by a new one on the same socket"
  pass "tmux proof: the recorded server killed, or replaced on its socket, proves the endpoint gone"
}

test_stopped_server_or_unlinked_socket_is_unproven() {
  local meta pid
  meta=$(start_task stopped)
  pid=$(t display-message -p '#{pid}')
  HOLDERS="$HOLDERS $pid"
  kill -STOP "$pid"
  expect_verdict "$meta" unproven "a stopped server whose socket cannot answer"
  kill -CONT "$pid"
  rm -f "$SOCK"
  expect_verdict "$meta" unproven "a live recorded server whose socket was unlinked"
  kill "$pid" 2>/dev/null
  pass "tmux proof: a live recorded server that cannot answer is never read as gone"
}

test_working_directory_holder_blocks_the_proof() {
  local meta wt got sibling holder
  meta=$(start_task holder)
  wt=$(dirname "$(dirname "$meta")")/wt
  t kill-server
  sibling="${wt}-sibling"
  mkdir -p "$sibling"
  ( cd "$sibling" && exec sleep 300 ) &
  HOLDERS="$HOLDERS $!"
  expect_verdict "$meta" gone "a process in a sibling directory sharing the copy's name prefix is not a holder"
  ( cd "$wt" && exec sleep 300 ) &
  holder=$!
  HOLDERS="$HOLDERS $holder"
  sleep 0.5
  got=$(verdict "$meta")
  [ "${got%%	*}" = unproven ] || fail "a process with its working directory in the copy must block the proof, got '$got'"
  assert_contains "$got" "process $holder (sleep)" "the refusal must name the holder by pid and command name"
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  pass "tmux proof: a process holding the copy (reached through a symlinked path) blocks it; a sibling path does not"
}

test_record_without_server_identity_still_refuses() {
  local meta
  meta=$(start_task legacy)
  t kill-server
  grep -v '^tmux_' "$meta" > "$meta.legacy"
  expect_verdict "$meta.legacy" unproven "a record without the tmux server identity"
  assert_contains "$(verdict "$meta.legacy")" "carries no tmux server identity" "the legacy refusal must say why"
  pass "tmux proof: a record without the server identity keeps refusing"
}

test_window_still_present_or_renamed_is_unproven
test_window_gone_from_the_same_server_is_gone_unless_a_pane_is_in_the_copy
test_killed_or_replaced_server_is_gone
test_stopped_server_or_unlinked_socket_is_unproven
test_working_directory_holder_blocks_the_proof
test_record_without_server_identity_still_refuses
