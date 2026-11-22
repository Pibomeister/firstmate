#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=~/.no-mistakes/evidence/01M7ZSQ6KCXZKNF16YKS1TEKEJ
exec >"$E/watchdog-failed-send-live.log" 2>&1
LAB=$(mktemp -d "$ROOT/.phase-handoff.XXXXXX")
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
mkdir "$LAB/fault-bin"
printf 'tmux\n' > "$LAB/config/backend"
printf 'codex\n' > "$LAB/config/crew-harness"
printf '# Local interruption drill\nNo open orders.\n' > "$LAB/data/handoff.md"
cat > "$LAB/fault-bin/rm" <<'EOF'
#!/usr/bin/env bash
for arg; do
 case "$arg" in */.handoff-launch-failed)
  if [ ! -e "$FM_HOME/state/removal-interrupted" ]; then
   : > "$FM_HOME/state/removal-interrupted"
   kill -TERM "$PPID"
  fi ;;
 esac
done
exec /bin/rm "$@"
EOF
chmod +x "$LAB/fault-bin/rm"
cat > "$LAB/scenario.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
exec >"$FM_HOME/state/scenario.log" 2>&1
bash "$FM_PHASE_ROOT/bin/fm-lock.sh"
printf 'at=1 pid=1 nonce=none attempt=0 reason=error\n' > "$FM_HOME/state/.handoff-launch-failed"
rc=0
PATH="$FM_HOME/fault-bin:$PATH" bash "$FM_PHASE_ROOT/bin/fm-handoff-launch.sh" --harness codex "$FM_HOME/data/handoff.md" || rc=$?
printf '%s\n' "$rc" > "$FM_HOME/state/result"
printf '\nPERSISTED FAILURE RECORD:\n'
cat "$FM_HOME/state/.handoff-launch-failed"
[ "$rc" != 0 ]
[ -f "$FM_HOME/state/removal-interrupted" ]
grep -q 'nonce=none attempt=0 reason=interrupted' "$FM_HOME/state/.handoff-launch-failed"
echo 'OBSERVED: real Claude primary ran the launcher; signal during prior-record removal left a new interruption record, before any successor attempt.'
touch "$FM_HOME/state/passed"
EOF
python3 - "$LAB" <<'PY'
import pathlib,json,sys,shlex
p=pathlib.Path(sys.argv[1]); (p/'settings.json').write_text(json.dumps({'hooks':{'SessionStart':[{'matcher':'startup','hooks':[{'type':'command','command':'bash '+shlex.quote(str(p/'scenario.sh')),'timeout':180}]}]}}))
PY
# Actual installed harness as the session command, 120x40 pty, no submitted model prompt.
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
 "$HELP" tmux "$LAB" new-session -d -s primary -x 120 -y 40 -c "$ROOT" -e FM_HOME="$LAB" -e FM_PHASE_ROOT="$ROOT" \
 claude --setting-sources '' --settings "$LAB/settings.json"
for _ in $(seq 1 180); do
 [ ! -f "$LAB/state/passed" ] || break
 # No instruction is submitted. If the new checkout has a folder-trust picker,
 # confirm this isolated worktree so its explicit SessionStart hook can run.
 if "$HELP" tmux "$LAB" capture-pane -p -t primary 2>/dev/null | grep -Eiq 'trust this folder|Yes, I trust'; then
  "$HELP" tmux "$LAB" send-keys -t primary Enter
 fi
 [ ! -f "$LAB/state/result" ] || break
 sleep 1
done
cat "$LAB/state/scenario.log" 2>/dev/null || true
[ -f "$LAB/state/passed" ]

# Exercise the actual nudge delivery helper against that same real CLI pane.
export FM_HOME=$LAB
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TEST_SEAM FM_GATE_REFUSE_BYPASS
export TMUX=$("$HELP" tmux "$LAB" display-message -p '#{socket_path}'),1,0
P=$("$HELP" tmux "$LAB" display-message -p '#{pane_id}')
REAL_TMUX=$(command -v tmux)
printf 'mode=act\nnudge-secs=1\nmodels=\nquota-guard=off\nmemory-guard=off\n' > "$LAB/config/watchdog"
mkdir -p "$LAB/send-fault-bin"
cat > "$LAB/send-fault-bin/tmux" <<EOF
#!/usr/bin/env bash
if [ "\$1" = send-keys ]; then
 for arg; do [ "\$arg" != -l ] || { echo 'injected terminal delivery failure' >&2; exit 1; }; done
fi
exec "$REAL_TMUX" "\$@"
EOF
chmod +x "$LAB/send-fault-bin/tmux"
. "$ROOT/bin/fm-watchdog.sh"
mkdir -p "$WD" "$OUT"
O_HOME=$LAB O_TAG=primary O_BACKEND=tmux O_TARGET=$P O_DIALOG=''
O_PANE=$("$HELP" tmux "$LAB" capture-pane -p -t "$P")
wd_read_owner "$LAB/state"
[ "$O_OWNER" = live ]
for _ in $(seq 1 20); do
 wd_read_composer
 [ "$O_COMPOSER" != empty ] || break
 sleep 1
done
printf 'Real CLI owner=%s composer=%s\n' "$O_OWNER" "$O_COMPOSER"
[ "$O_COMPOSER" = empty ]
PATH="$LAB/send-fault-bin:$PATH" wd_nudge heartbeat-frozen 'the local heartbeat is stale; resume the local supervision pass.'
cat "$LEDGER"
awk -F '\t' '$5 == "heartbeat-frozen" && $6 == "nudge" && $7 == "pending" { p++ } $5 == "heartbeat-frozen" && $6 == "nudge" && $7 == "done" { d++ } END { exit !(p==1 && d==0) }' "$LEDGER"
echo 'OBSERVED: failed terminal delivery into a real Claude pane left one pending nudge and no delivery receipt, so it cannot authorize restart.'
