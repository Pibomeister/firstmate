. /tmp/wdt/lib.sh
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
hdr "P4 unread input: a real session gets a record-backed doorbell and drains the wake queue"
owe_real() { printf '%s\t1\tcheck\tinbox\tcaptain note waiting\n' "$(( $(date +%s) - 1000 ))" > "$H/state/.wake-queue"; }; owe_real; wd scan | tail -1; wd once; led | tail -1; ls "$H/state/operational-inbox" | tail -1; sleep 8; waitfor 'idle' 40; sleep 5; waitfor '[ ! -s "$H/state/.wake-queue" ] || ! wd scan | tail -1 | grep -q owed=1' 30; shot 8; wd scan | tail -1
hdr "P5 low context: nudge, session writes a full handoff and the request file; restart; new session proves pickup"
jq '.primary.context_left={remaining:{percent:5}}|.generated_epoch=now' "$H/state/heartbeat.json" > "$H/hb.tmp"; mv "$H/hb.tmp" "$H/state/heartbeat.json"; wd scan | sed -n 4p; wd once; led | tail -1 | cut -c1-200
waitfor '[ -f "$H/state/.watchdog-restart-request" ]' 60; ls -la "$H"/data/handoff-* "$H/state/.watchdog-restart-request"; cp "$H"/data/handoff-*.md $EV/r2-primary-full-handoff.md; waitfor 'idle' 20; sleep 8; OLD=$(cat "$H/state/.lock"); echo "old lock $OLD"; wd once; led | tail -2 | cut -c1-200; stat_ | sed -n 1,3p; sleep 3; wd once; led | tail -2 | cut -c1-200; sleep 3; kill -0 "$OLD" 2>/dev/null && echo "old holder alive" || echo "old holder stopped"
$REPO/bin/fm-lab-home.sh tmux "$H" list-windows -a -F '#{session_name}:#{window_index} #{pane_current_command}'
echo "-- status while the new session shows its trust picker (lab home is untrusted; the driver accepts it, the watchdog does not)"; sleep 6; W=$($REPO/bin/fm-lab-home.sh tmux "$H" list-panes -a -F '#{pane_id}' | tail -1); if scrw "$W" | grep -q 'trust this folder'; then echo "new pane shows trust picker; accepted by driver"; $REPO/bin/fm-lab-home.sh tmux "$H" send-keys -t "$W" Down; sleep 1; $REPO/bin/fm-lab-home.sh tmux "$H" send-keys -t "$W" Enter; fi; waitfor '[ -n "$(ls "$H/state/watchdog/pickups" 2>/dev/null)" ]' 60; ls "$H/state/watchdog/pickups"; sleep 20; wd once; led | tail -2 | cut -c1-170; cp "$H"/data/watchdog/handoffs/* $EV/ 2>/dev/null; echo "new lock $(cat "$H/state/.lock")"; ps -o pid=,comm= -p "$(cat "$H/state/.lock")" | cut -c1-60
W=$($REPO/bin/fm-lab-home.sh tmux "$H" list-panes -a -F '#{pane_id}' | tail -1); scrw "$W" | grep -v '^$' | tail -14 | cut -c1-160
hdr "P6 no second restart from the same request file"
sleep 5; wd once; led | grep -c 'restart.pending'; stat_ | cut -c1-160; cp "$H/data/watchdog/status.md" $EV/r2-primary-status.md; cut -f5-8 "$H/state/watchdog/actions.tsv" | cut -c1-180 > $EV/r2-primary-actions.tsv
$REPO/bin/fm-lab-home.sh tmux "$H" kill-server
