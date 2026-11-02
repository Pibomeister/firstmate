. /tmp/wdt/lib.sh
hdr "S3 2026-11-01 incident replay on a real Claude TUI pane: exact re-arm loop, aged owed input, no model. Ladder: nudge, then restart, then pickup"
mkr inc2 "max-nudges=1
restart=on
restart-secs=1"
cat > "$H/captain.sh" <<SH
#!/usr/bin/env bash
echo \$\$ > "$H/state/.lock"; echo newsession-$$ > "$H/state/.lock-session"
tok=\$(printf '%s' "\$1" | grep -oE 'pickup [a-f0-9]+' | cut -d' ' -f2)
printf '%s\n' "\$1" > "$H/new-prompt.txt"
FM_HOME="$H" "$WD" pickup "\$tok"
exec sleep 100000
SH
chmod +x "$H/captain.sh"; cfgadd "restart-command=$H/captain.sh"
TXT="I re-armed the 15-minute wake. Still waiting."
transcript 3000 600 "$TXT" "$TXT" "$TXT" "$TXT"; owe 3000
wd scan | sed -n 3,5p
pass_once; sleep 3; echo "-- pass 1 (real typed nudge)"; led; typed; ls "$H/state/operational-inbox"; cat "$H"/state/operational-inbox/*.msg | cut -c1-200
tmux capture-pane -p -t "$T" | grep -v '^$' | tail -14 | cut -c1-150
tmux send-keys -t "$T" Escape; sleep 1; transcript 3000 600 "$TXT" "$TXT" "$TXT" "$TXT"
for i in 1 2 3; do sleep 8; pass_once; done; echo "-- after nudge ignored"; led; stat_ | sed -n 1,3p; cut -c1-200 "$H/new-prompt.txt"; kill -0 $LOCKPID 2>/dev/null && echo "old holder alive" || echo "old holder stopped"
tmux list-windows -t inc2 -F '#{window_index} #{pane_current_command}'

hdr "S5 dead holder (kill -9), quiet transcript: nothing typed, restart, verified pickup; second death restarts; third escalates"
mkr dead2 "restart=on
restart-secs=1
max-restarts=2"
cat > "$H/captain.sh" <<SH
#!/usr/bin/env bash
( sleep 100000 >/dev/null 2>&1 & echo \$! > "$H/state/.lock" )
echo news-\$\$ > "$H/state/.lock-session"
tok=\$(printf '%s' "\$1" | grep -oE 'pickup [a-f0-9]+' | cut -d' ' -f2)
FM_HOME="$H" "$WD" pickup "\$tok"
exec sleep 100000
SH
chmod +x "$H/captain.sh"; cfgadd "restart-command=$H/captain.sh"
transcript 3000 60 "Working."; owe 3000
kill -9 $LOCKPID; sleep 1; pass_once; echo "doorbell on dead holder pane: $(typed)"; sleep 5; pass_once; led | cut -c1-90
for i in 1 2; do kill -9 "$(cat "$H/state/.lock")"; sleep 3; SID=$(cat "$H/state/.lock-session"); f=$H/claude/projects/p/$SID.jsonl; cp "$H/claude/projects/p/"*.jsonl "$f" 2>/dev/null; touch -t "$(date -r $(( $(date +%s)-3000 )) +%Y%m%d%H%M.%S)" "$f"; pass_once; sleep 5; pass_once; done
echo "-- final"; led | cut -c1-90; stat_ | cut -c1-170; ls "$H/state/watchdog/escalated/"
