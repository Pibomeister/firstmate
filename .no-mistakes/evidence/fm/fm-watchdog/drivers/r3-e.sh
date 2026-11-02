. /tmp/wdt/lib.sh
echo "revision: $(git -C $REPO rev-parse HEAD); date: $(date -u +%FT%TZ)"
LP=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); $REPO/bin/fm-lab-home.sh create "$LP" >/dev/null; LP=$(cd -P "$LP" && pwd -P); echo "$LP" > /tmp/wdt/labprimary
export TMUX_TMPDIR=$($REPO/bin/fm-lab-home.sh tmux-dir "$LP"); H=$LP; mkdir -p "$H/config"
touch "$H/config/supervision-host"
printf 'mode=act\nrestart=on\nkey-settle-secs=2\nmodels=\nnudge-secs=1\nkey-secs=1\nenter-secs=1\nowed-input-secs=5\nfrozen-secs=900\nrestart-quiet-secs=5\nrestart-secs=1\nhandoff-wait-secs=240\ndecision-secs=1800\nrestart-command=env FM_HOME=%s claude\n' "$H" > "$H/config/watchdog"
scr() { $REPO/bin/fm-lab-home.sh tmux "$H" capture-pane -p -t primary:0 2>/dev/null; }
scrw() { $REPO/bin/fm-lab-home.sh tmux "$H" capture-pane -p -t "$1" 2>/dev/null; }
sk() { $REPO/bin/fm-lab-home.sh tmux "$H" send-keys -t primary:0 "$@"; }
waitfor() { local i; for i in $(seq 1 "$2"); do eval "$1" && return 0; sleep 3; done; echo "TIMEOUT waiting: $1"; scr | tail -15; return 1; }
idle() { ! scr | grep -q 'esc to interrupt' ; }
shot() { scr | grep -v '^$' | tail -"${1:-12}" | cut -c1-160; }
$REPO/bin/fm-lab-home.sh tmux "$H" new-session -d -s primary -x 170 -y 50 -c "$REPO" env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_PID -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN FM_HOME="$H" claude
waitfor 'scr | grep -Eq "for shortcuts|auto mode|❯|trust this folder"' 20; sleep 3
scr | grep -q 'trust this folder' && { sk Enter; sleep 3; }
hdr "P0 start a real logged-in Claude primary in the lab home; it runs its own session start"
sk -l "You are in a disposable lab home. Run bin/fm-session-start.sh once, then bin/fm-heartbeat.sh --write. Do nothing else. Reply in one sentence."; sleep 1; sk Enter
waitfor '[ -s "$H/state/.lock" ] && [ -s "$H/state/heartbeat.json" ] && idle' 60; sleep 5
shot 6; jq -c '.primary.terminal,.primary.session.trusted_id' "$H/state/heartbeat.json"
wd scan
hdr "P1 clean unsent draft on the real composer: one Enter, session answers"
sk -l "Reply with exactly the word pong."; sleep 2; wd once; sleep 2; wd scan | sed -n 3p; wd once; led | tail -2; waitfor 'scr | grep -q "pong" && idle' 20; shot 5
hdr "P2 adversarial: merge draft stays unsent on the real composer"
sk -l "merge #12 now please"; sleep 2; n0=$(wc -l < "$(ls -t ~/.claude/projects/*/$(jq -r .primary.session.trusted_id "$H/state/heartbeat.json").jsonl | head -1)"); for i in 1 2 3; do wd once; sleep 2; done; led | tail -1; stat_ | grep -iE 'merge|Enter'; shot 5; sk C-c; sleep 2
hdr "P-end status"; stat_ | cut -c1-170; 
