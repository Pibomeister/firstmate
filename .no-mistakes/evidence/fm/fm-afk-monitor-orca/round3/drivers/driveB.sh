#!/usr/bin/env bash
# Mid-turn hold then repeated exact-once. The turn starts BEFORE away mode so the prompt cannot read as a captain return.
S=/tmp/fmlab-orca-state3; L=$(cat $S/lab); T=$(cat $S/t); E=/Users/eduardopicazo/.no-mistakes/evidence/01M68C1YCBXXQQQ6N5DEHCT0X6/round3; WT=$PWD
LOG=$L/state/.supervise-daemon.log
pause(){ perl -e "select(undef,undef,undef,$1)"; }
inbox(){ ls $L/state/operational-inbox 2>/dev/null | grep -c msg; }
sig(){ printf 'done: PR https://example.test/pr/%s\n' "$1" > $L/state/crew-$1.status; }
screen(){ orca terminal read --terminal $T --limit ${1:-25} --json | jq -r '.result.terminal.tail[]' | cut -c1-170; }
draft(){ orca terminal read --terminal $T --limit 12 --json | jq -r .result.terminal.draft; }
idle(){ orca terminal wait --terminal $T --for tui-idle --timeout-ms 150000 --json >/dev/null 2>&1; pause 5; }
verdict(){ orca terminal wait --terminal $T --for tui-idle --timeout-ms 500 --json 2>/dev/null | jq -r 'if .ok then "idle" else .error.code end'; }
waitinbox(){ local want=$1 max=$2 t=0; while [ $t -lt $max ]; do [ "$(inbox)" -ge "$want" ] && return 0; pause 5; t=$((t+5)); done; return 1; }
rm -f $L/state/crew-*.status
orca terminal send --terminal $T --text "Run this lab build step with the Bash tool in the foreground, not in the background, with a 300000 ms timeout: $L/lab-build-step.sh . When it ends, reply with the single word FINISHED." --enter --json >/dev/null
pause 6
env FM_HOME=$L bin/fm-afk-launch.sh enter --words lab 2>&1 | tail -1; env FM_HOME=$L bin/fm-afk-launch.sh start-native >/dev/null 2>&1
N0=$(wc -l < $LOG)
env -u TMUX -u TMUX_PANE FM_HOME=$L FM_SUPERVISOR_BACKEND=orca FM_SUPERVISOR_TARGET=$T FM_ESCALATE_BATCH_SECS=0 FM_STALE_ESCALATE_SECS=999999 FM_AFK_STATE_PREPARED=1 nohup bin/fm-afk-start.sh > $L/daemon2.out 2>&1 &
pause 8; sed -n "$((N0+1)),\$p" $LOG | grep 'daemon starting' | cut -c1-170
echo "== S3 busy"; B=$(inbox); sig busy; echo "$(date +%T) signalled inbox=$B"
for i in $(seq 1 25); do
  echo "$(date +%T) tui-idle=$(verdict) inbox=$(inbox) row=[$(screen 14 | grep -E 'step [0-9]+|FINISHED' | tail -1 | cut -c1-50)]"
  [ "$(inbox)" -gt "$B" ] && break; pause 8
done
waitinbox $((B+1)) 150 && echo "delivered-after-turn inbox=$(inbox) $(date +%T)" || echo "NOT-delivered inbox=$(inbox)"; idle; screen 30 > $E/03-busy-after-turn.txt
sed -n "$((N0+1)),\$p" $LOG | cut -c1-200 > $E/03-busy-daemon.log
echo "== S4 repeat exact-once"; for n in r1 r2 r3 r4 r5; do B=$(inbox); sig $n; waitinbox $((B+1)) 150 && echo "$n inbox=$(inbox)" || echo "$n NOT-delivered"; idle; pause 25; echo "  settled inbox=$(inbox) draft=[$(draft)]"; done
sed -n "$((N0+1)),\$p" $LOG > $L/run2.log
echo "unconfirmed=$(grep -c 'submit unconfirmed' $L/run2.log) firstmate0=$(grep -c 'firstmate:0' $LOG)"
grep -E 'escalate:|deferred|unconfirmed|shutting' $L/run2.log | cut -c1-200 > $E/04-daemon-events.log
grep -hoE 'crew-[a-z0-9]+\.status' $L/state/operational-inbox/*.msg 2>/dev/null | sort | uniq -c | tee $E/04-inbox-per-event.txt
echo FIN
