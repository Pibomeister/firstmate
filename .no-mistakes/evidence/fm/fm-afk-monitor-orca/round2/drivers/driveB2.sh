#!/usr/bin/env bash
S=/tmp/fmlab-orca-state; LB=$(cat $S/labB); T=$(cat $S/tb); E=/Users/eduardopicazo/.no-mistakes/evidence/01M68C1YCBXXQQQ6N5DEHCT0X6/round2; WT=$PWD
LOG=$LB/state/.supervise-daemon.log
inbox(){ ls $LB/state/operational-inbox 2>/dev/null | grep -c msg; }
sig(){ printf 'done: PR https://example.test/pr/%s\n' "$1" > $LB/state/crew-$1.status; }
screen(){ orca terminal read --terminal $T --limit ${1:-25} --json | jq -r '.result.terminal.tail[]' | cut -c1-170; }
verdict(){ orca terminal wait --terminal $T --for tui-idle --timeout-ms 500 --json 2>/dev/null | jq -r 'if .ok then "idle" else .error.code end'; }

echo "== busy retry"; B=$(inbox); N0=$(wc -l < $LOG)
orca terminal send --terminal $T --text "Use the Bash tool in the foreground, not background, to run exactly: python3 -c 'import time; time.sleep(90)' . Then reply with the single word FINISHED." --enter --json >/dev/null
sleep 12; screen 10 | tail -7 > $E/04-busy-early-screen.txt; sig busy; echo "$(date +%T) signalled"
for i in $(seq 1 14); do
  echo "$(date +%T) tui-idle=$(verdict) inbox=$(inbox) row=[$(screen 12 | grep -E '…|FINISHED' | tail -1 | cut -c1-60)]"
  [ "$(inbox)" -gt "$B" ] && break; sleep 9
done
for i in $(seq 1 12); do [ "$(inbox)" -gt "$B" ] && break; sleep 8; done
echo "final inbox before=$B now=$(inbox) at $(date +%T)"; sleep 25; screen 25 > $E/04-busy-after-turn.txt
sed -n "$((N0+1)),\$p" $LOG | cut -c1-200 > $E/04-busy-daemon.log

echo "== terminal gone"; N0=$(wc -l < $LOG); B=$(inbox); DP=$(cat $LB/state/.supervise-daemon.pid)
orca terminal close --terminal $T --json | jq -c .ok; sleep 5; sig gone; echo "$(date +%T) signalled, pid=$DP"
sleep 100; echo "inbox before=$B now=$(inbox)"; sed -n "$((N0+1)),\$p" $LOG | cut -c1-230 | tee $E/08-terminal-gone-daemon.log
grep -c 'firstmate:0' $E/08-terminal-gone-daemon.log | sed 's/^/firstmate:0-mentions=/'; ps -p "$DP" -o pid=,etime= | sed 's/^/daemon-still-alive /'
echo FIN
