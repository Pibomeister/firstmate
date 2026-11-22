#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=~/.no-mistakes/evidence/01M7ZSQ6KCXZKNF16YKS1TEKEJ
exec >"$E/tmux-live.log" 2>&1
LAB1=$(mktemp -d "$ROOT/.phase-tmux-a.XXXXXX")
LAB2=$(mktemp -d "$ROOT/.phase-tmux-b.XXXXXX")
HELP=$ROOT/bin/fm-lab-home.sh
cleanup() {
 local rc=$?
 "$HELP" tmux "$LAB1" kill-server 2>/dev/null || true
 "$HELP" tmux "$LAB2" kill-server 2>/dev/null || true
 "$HELP" teardown "$LAB1" || rc=1
 "$HELP" teardown "$LAB2" || rc=1
 rm -rf "$LAB1" "$LAB2"
 echo "FINAL_EXIT_STATUS: $rc"
 exit "$rc"
}
trap cleanup EXIT
"$HELP" create "$LAB1"; "$HELP" create "$LAB2"
"$HELP" tmux "$LAB1" new-session -d -s primary -x 120 -y 40 -c "$ROOT" '/bin/bash --noprofile --norc'
"$HELP" tmux "$LAB2" new-session -d -s worker -n worker -x 120 -y 40 -c "$ROOT" '/bin/bash --noprofile --norc'
S1=$("$HELP" tmux "$LAB1" display-message -p '#{socket_path}')
S2=$("$HELP" tmux "$LAB2" display-message -p '#{socket_path}')
P=$("$HELP" tmux "$LAB1" display-message -p '#{pane_id}')
export FM_HOME=$LAB1 FM_STATE_OVERRIDE=$LAB1/state FM_DATA_OVERRIDE=$LAB1/data FM_CONFIG_OVERRIDE=$LAB1/config
unset FM_ROOT_OVERRIDE FM_TEST_SEAM FM_GATE_REFUSE_BYPASS TMUX_PANE
export TMUX=$S1,1,0
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux
sleep 1
"$HELP" tmux "$LAB1" send-keys -t "$P" -l "touch '$LAB1/wrong-command'; "
fm_backend_tmux_prepare_relaunch "$P"
"$HELP" tmux "$LAB1" send-keys -t "$P" -l "printf 'clean command reached shell\\n' > '$LAB1/after'"
"$HELP" tmux "$LAB1" send-keys -t "$P" Enter
for _ in $(seq 1 40); do [ ! -f "$LAB1/after" ] || break; sleep .1; done
[ -f "$LAB1/after" ]; [ ! -e "$LAB1/wrong-command" ]
cat "$LAB1/after"
"$HELP" tmux "$LAB1" capture-pane -p -t "$P"
echo 'OBSERVED: prepare_relaunch cleared stale shell input before the replacement command; the stale command never ran.'
. "$ROOT/bin/fm-supervise-daemon.sh"
printf 'window=worker:worker\nbackend=tmux\nkind=ship\ntmux_socket=%s\n' "$S2" > "$LAB1/state/paused.meta"
rc=0
out=$(paused_wait_agent_gone worker:worker "$LAB1/state" 'paused: waiting for the vendor rate-limit reset') || rc=$?
printf 'Other-server paused probe: exit=%s output=%s\n' "$rc" "$out"
[ "$rc" = 1 ]; [ -z "$out" ]
"$HELP" tmux "$LAB2" has-session -t worker
printf 'window=worker:worker\nbackend=tmux\nkind=ship\ntmux_socket=%s\n' "$S1" > "$LAB1/state/paused.meta"
rc=0
out=$(paused_wait_agent_gone worker:worker "$LAB1/state" 'paused: waiting for the vendor rate-limit reset') || rc=$?
printf 'Addressed-server missing paused probe: exit=%s output=%s\n' "$rc" "$out"
[ "$rc" = 0 ]; [ "$out" = missing ]
echo 'OBSERVED: a paused window on another live server is not declared gone; a missing window recorded on the addressed server is detected.'
