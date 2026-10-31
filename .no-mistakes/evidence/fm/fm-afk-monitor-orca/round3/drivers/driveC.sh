#!/usr/bin/env bash
# Long mid-turn hold on a fresh default-settings captain. The turn starts before away mode.
E=/Users/eduardopicazo/.no-mistakes/evidence/01M68C1YCBXXQQQ6N5DEHCT0X6/round3; WT=$PWD; S=/tmp/fmlab-orca-state3; OL=$(cat $S/lab)
env FM_HOME=$OL bin/fm-afk-launch.sh stop 2>&1 | tail -1 | cut -c1-100
kill "$(cat $OL/state/.supervise-daemon.pid 2>/dev/null)" 2>/dev/null
pkill -f "$OL" 2>/dev/null
bin/fm-lab-home.sh teardown "$OL" 2>/dev/null
rm -rf "$OL"
L=$(mktemp -d /tmp/fm-lab.XXXXXX); bin/fm-lab-home.sh create "$L" >/dev/null; touch $L/config/supervision-host-off; echo $L > $S/lab
cat > $L/lab-build-step.sh <<'X'
#!/usr/bin/env bash
for i in $(seq 1 36); do echo "step $i"; python3 -c 'import select; select.select([],[],[],5)'; done
echo complete
X
chmod +x $L/lab-build-step.sh
T=$(orca terminal create --worktree path:/Users/eduardopicazo/orca/projects/firstmate --title fm-lab-afk-captain-r3b --command "cd $WT && env -u NO_MISTAKES_GATE FM_HOME=$L claude" --json | jq -r '.result.terminal.handle // .result.handle'); echo $T > $S/t
pause(){ perl -e "select(undef,undef,undef,$1)"; }
inbox(){ ls $L/state/operational-inbox 2>/dev/null | grep -c msg; }
screen(){ orca terminal read --terminal $T --limit ${1:-25} --json | jq -r '.result.terminal.tail[]' | cut -c1-170; }
verdict(){ orca terminal wait --terminal $T --for tui-idle --timeout-ms 500 --json 2>/dev/null | jq -r 'if .ok then "idle" else .error.code end'; }
pause 15
orca terminal send --terminal $T --text "Run this lab build step with the Bash tool in the foreground, not in the background, with a 300000 ms timeout: $L/lab-build-step.sh . When it ends, reply with the single word FINISHED." --enter --json >/dev/null
pause 8
env FM_HOME=$L bin/fm-afk-launch.sh enter --words lab >/dev/null 2>&1; env FM_HOME=$L bin/fm-afk-launch.sh start-native >/dev/null 2>&1
env -u TMUX -u TMUX_PANE FM_HOME=$L FM_SUPERVISOR_BACKEND=orca FM_SUPERVISOR_TARGET=$T FM_ESCALATE_BATCH_SECS=0 FM_STALE_ESCALATE_SECS=999999 FM_AFK_STATE_PREPARED=1 nohup bin/fm-afk-start.sh > $L/daemon.out 2>&1 &
pause 8
printf 'done: PR https://example.test/pr/busy\n' > $L/state/crew-busy.status; echo "$(date +%T) signalled"
for i in $(seq 1 40); do echo "$(date +%T) tui-idle=$(verdict) inbox=$(inbox) row=[$(screen 14 | grep -E 'FINISHED$|Running|…' | tail -1 | cut -c1-60)]"; [ "$(inbox)" -gt 0 ] && break; pause 6; done
pause 25; echo "final inbox=$(inbox)"
cut -c1-200 $L/state/.supervise-daemon.log > $E/03b-busy-daemon.log; screen 25 > $E/03b-busy-after-turn.txt
env FM_HOME=$L bin/fm-afk-launch.sh stop 2>&1 | tail -1 | cut -c1-100
orca terminal close --terminal $T --json | jq -c .ok; pause 5
kill "$(cat $L/state/.supervise-daemon.pid 2>/dev/null)" 2>/dev/null
pkill -f "$L" 2>/dev/null
bin/fm-lab-home.sh teardown "$L" 2>/dev/null
rm -rf "$L" "$S"
echo "--- leftovers"; ls -d /tmp/fm-lab.* 2>/dev/null
echo "lab-terminals=$(orca terminal list 2>/dev/null | grep -c fm-lab-afk) daemons=$(pgrep -fl fm-supervise-daemon | grep -c "$WT")"
git status --short | head
echo FIN
