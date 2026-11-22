#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=~/.no-mistakes/evidence/01M7ZSQ6KCXZKNF16YKS1TEKEJ
exec >"$E/watchdog-failed-send-codex-live.log" 2>&1
LAB=$(mktemp -d "$ROOT/.phase-wd-codex.XXXXXX")
HELP=$ROOT/bin/fm-lab-home.sh
cleanup() {
 local rc=$?
 "$HELP" tmux "$LAB" capture-pane -p -t primary 2>/dev/null || true
 "$HELP" tmux "$LAB" kill-server 2>/dev/null || true
 "$HELP" teardown "$LAB" || rc=1
 rm -rf "$LAB"
 echo "FINAL_EXIT_STATUS: $rc"
 exit "$rc"
}
trap cleanup EXIT
"$HELP" create "$LAB"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
 "$HELP" tmux "$LAB" new-session -d -s primary -x 120 -y 40 -c "$ROOT" -e FM_HOME="$LAB" codex --no-alt-screen
export FM_HOME=$LAB
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TEST_SEAM FM_GATE_REFUSE_BYPASS
export TMUX=$("$HELP" tmux "$LAB" display-message -p '#{socket_path}'),1,0
P=$("$HELP" tmux "$LAB" display-message -p '#{pane_id}')
PID=$("$HELP" tmux "$LAB" display-message -p '#{pane_pid}')
. "$ROOT/bin/fm-session-lock-lib.sh"
START=$(fm_session_process_start "$PID")
printf '%s\n' "$PID" > "$LAB/state/.lock"
printf '\nanchor_pid=%s\nanchor_start=%s\nbackend=tmux\nterminal=%s\nworktree=%s\n' "$PID" "$START" "$P" "$ROOT" > "$LAB/state/.lock-session"
printf 'mode=act\nnudge-secs=1\nmodels=\nquota-guard=off\nmemory-guard=off\n' > "$LAB/config/watchdog"
REAL_TMUX=$(command -v tmux)
mkdir "$LAB/send-fault-bin"
cat > "$LAB/send-fault-bin/tmux" <<EOF
#!/usr/bin/env bash
if [ "\$1" = send-keys ]; then
 for arg; do
  if [ "\$arg" = -l ]; then
   "$REAL_TMUX" send-keys -t %2147483647 -l 'local invalid destination' > "$LAB/state/send-rejected" 2>&1
   code=\$?
   printf 'native tmux exit=%s\n' "\$code" >> "$LAB/state/send-rejected"
   exit "\$code"
  fi
 done
fi
exec "$REAL_TMUX" "\$@"
EOF
chmod +x "$LAB/send-fault-bin/tmux"
. "$ROOT/bin/fm-watchdog.sh"
mkdir -p "$WD" "$OUT"
O_HOME=$LAB O_TAG=primary O_BACKEND=tmux O_TARGET=$P O_DIALOG=''
wd_read_owner "$LAB/state"
[ "$O_OWNER" = live ]
for _ in $(seq 1 10); do
 O_PANE=$("$HELP" tmux "$LAB" capture-pane -p -t "$P")
 wd_read_composer
 [ "$O_COMPOSER" != empty ] || break
 sleep 1
done
printf 'Real Codex CLI owner=%s composer=%s\n' "$O_OWNER" "$O_COMPOSER"
[ "$O_COMPOSER" = empty ]
PATH="$LAB/send-fault-bin:$PATH" wd_nudge heartbeat-frozen 'the local heartbeat is stale; resume the local supervision pass.'
cat "$LAB/state/send-rejected"
[ -s "$LAB/state/send-rejected" ]
grep -q "native tmux exit=1" "$LAB/state/send-rejected"
cat "$LEDGER"
awk -F '\t' '$5 == "heartbeat-frozen" && $6 == "nudge" && $7 == "pending" { p++ } $5 == "heartbeat-frozen" && $6 == "nudge" && $7 == "done" { d++ } END { exit !(p==1 && d==0) }' "$LEDGER"
echo 'OBSERVED: failed terminal delivery into a real Codex pane left one pending nudge and no delivery receipt, so it cannot authorize restart.'
