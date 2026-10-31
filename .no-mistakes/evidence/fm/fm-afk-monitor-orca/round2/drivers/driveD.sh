#!/usr/bin/env bash
S=/tmp/fmlab-orca-state; E=/Users/eduardopicazo/.no-mistakes/evidence/01M68C1YCBXXQQQ6N5DEHCT0X6/round2; WT=$PWD
L=$(mktemp -d /tmp/fm-lab.XXXXXX); bin/fm-lab-home.sh create "$L" >/dev/null; touch $L/config/supervision-host-off; echo $L > $S/labD
cat > $L/daemon.sh <<EOF
#!/usr/bin/env bash
cd "$WT"
FM_HOME="$L" FM_ESCALATE_BATCH_SECS=0 FM_STALE_ESCALATE_SECS=999999 FM_AFK_STATE_PREPARED=1 exec bin/fm-afk-start.sh > "$L/daemon.out" 2>&1
EOF
cat > $L/lab-build-step.sh <<'EOF'
#!/usr/bin/env bash
for i in $(seq 1 36); do echo "step $i"; python3 -c 'import select; select.select([],[],[],5)'; done
echo complete
EOF
chmod +x $L/daemon.sh $L/lab-build-step.sh
env FM_HOME=$L bin/fm-afk-launch.sh enter --words lab >/dev/null; env FM_HOME=$L bin/fm-afk-launch.sh start-native >/dev/null 2>&1
T=$(orca terminal create --worktree path:/Users/eduardopicazo/orca/projects/firstmate --title fm-lab-afk-captain-d --command "cd $WT && env -u NO_MISTAKES_GATE CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false FM_HOME=$L claude --model haiku" --json | jq -r '.result.terminal.handle // .result.handle'); echo $T > $S/td
sleep 15
orca terminal send --terminal $T --text "Use the Bash tool with run_in_background set to true to run exactly: $L/daemon.sh  . Do nothing else. Then reply with the single word STARTED." --enter --json >/dev/null
sleep 30
LOG=$L/state/.supervise-daemon.log; grep 'daemon starting' $LOG | cut -c1-170
inbox(){ ls $L/state/operational-inbox 2>/dev/null | grep -c msg; }
screen(){ orca terminal read --terminal $T --limit ${1:-25} --json | jq -r '.result.terminal.tail[]' | cut -c1-170; }
verdict(){ orca terminal wait --terminal $T --for tui-idle --timeout-ms 500 --json 2>/dev/null | jq -r 'if .ok then "idle" else .error.code end'; }
orca terminal send --terminal $T --text "Run this lab build step with the Bash tool in the foreground, not in the background, with a 300000 ms timeout: $L/lab-build-step.sh . When it ends, reply with the single word FINISHED." --enter --json >/dev/null
sleep 10; printf 'done: PR https://example.test/pr/busy\n' > $L/state/crew-busy.status; echo "$(date +%T) signalled"
for i in $(seq 1 30); do
  c=$(wc -l < $L/daemon.out 2>/dev/null)
  echo "$(date +%T) tui-idle=$(verdict) draft=[$(orca terminal read --terminal $T --limit 8 --json | jq -r .result.terminal.draft | cut -c1-30)] inbox=$(inbox) row=[$(screen 14 | grep -E '^. .*…|FINISHED' | tail -1 | cut -c1-55)]"
  [ "$(inbox)" -gt 0 ] && break; sleep 8
done
sleep 30; screen 25 > $E/04-busy-after-turn.txt; cut -c1-200 $LOG > $E/04-busy-daemon.log; echo "final inbox=$(inbox)"; echo FIN
