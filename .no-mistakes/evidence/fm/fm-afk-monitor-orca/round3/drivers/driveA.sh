#!/usr/bin/env bash
# Default-settings Claude captain: finished turns, ghost check, delivery, draft hold, repeated exact-once.
S=/tmp/fmlab-orca-state3; L=$(cat $S/lab); T=$(cat $S/t); E=/Users/eduardopicazo/.no-mistakes/evidence/01M68C1YCBXXQQQ6N5DEHCT0X6/round3
LOG=$L/state/.supervise-daemon.log
pause(){ perl -e "select(undef,undef,undef,$1)"; }
inbox(){ ls $L/state/operational-inbox 2>/dev/null | grep -c msg; }
sig(){ printf 'done: PR https://example.test/pr/%s\n' "$1" > $L/state/crew-$1.status; }
screen(){ orca terminal read --terminal $T --limit ${1:-25} --json | jq -r '.result.terminal.tail[]' | cut -c1-170; }
draft(){ orca terminal read --terminal $T --limit 12 --json | jq -r .result.terminal.draft; }
send(){ orca terminal send --terminal $T --text "$1" --enter --json >/dev/null; }
idle(){ orca terminal wait --terminal $T --for tui-idle --timeout-ms 150000 --json >/dev/null 2>&1; pause 5; }
waitinbox(){ local want=$1 max=$2 t=0; while [ $t -lt $max ]; do [ "$(inbox)" -ge "$want" ] && return 0; pause 5; t=$((t+5)); done; return 1; }

send "Use the Bash tool with run_in_background set to true to run exactly: $L/daemon.sh  . Do nothing else. Then reply with the single word STARTED."
pause 25; idle; grep 'daemon starting' $LOG | cut -c1-200
echo "fresh-after-daemon draft=[$(draft)]"

echo "== S1 finished turns then ghost sampling"
for p in "Reply with one short sentence about what the README of this repo covers." "Name one script in the bin directory; one line only." "Suggest in one line what I should check next."; do
  send "$p"; pause 5; idle; for i in 1 2 3 4; do pause 8; echo "$(date +%T) draft=[$(draft)]"; done
done
screen 14 > $E/01-idle-screen-before-alert.txt
echo "== S1 delivery"; B=$(inbox); sig one; echo "$(date +%T) signalled"
waitinbox $((B+1)) 150 && echo "delivered inbox=$(inbox) $(date +%T)" || echo "NOT-delivered inbox=$(inbox)"; idle; screen 25 > $E/01-delivery-screen.txt

echo "== S2 typed draft"; orca terminal send --terminal $T --text "half typed captain words" --json >/dev/null; pause 3; echo "draft=[$(draft)]"; B=$(inbox); sig two; pause 75
echo "inbox before=$B now=$(inbox) draft=[$(draft)]"; screen 12 > $E/02-composer-while-typed.txt
echo "deferred-lines=$(grep -c 'composer not confirmed-empty' $LOG)"
orca terminal send --terminal $T --text $'\x15' --json >/dev/null; pause 3; echo "cleared draft=[$(draft)]"
waitinbox $((B+1)) 150 && echo "delivered-after-clear inbox=$(inbox)" || echo "NOT-delivered inbox=$(inbox)"; idle; screen 30 > $E/02-composer-after-clear.txt
echo "merged-count=$(grep -c 'half typed' $E/02-composer-after-clear.txt)"

echo "== S3 busy"; cat > $L/lab-build-step.sh <<'X'
#!/usr/bin/env bash
for i in $(seq 1 18); do echo "step $i"; python3 -c 'import select; select.select([],[],[],5)'; done
echo complete
X
chmod +x $L/lab-build-step.sh; B=$(inbox); N0=$(wc -l < $LOG)
send "Run this lab build step with the Bash tool in the foreground, not in the background, with a 300000 ms timeout: $L/lab-build-step.sh . When it ends, reply with the single word FINISHED."
pause 12; sig busy; echo "$(date +%T) signalled"
for i in $(seq 1 20); do
  echo "$(date +%T) tui-idle=$(orca terminal wait --terminal $T --for tui-idle --timeout-ms 500 --json 2>/dev/null | jq -r 'if .ok then "idle" else .error.code end') inbox=$(inbox) row=[$(screen 14 | grep -E 'step [0-9]+|FINISHED' | tail -1 | cut -c1-50)]"
  [ "$(inbox)" -gt "$B" ] && break; pause 8
done
waitinbox $((B+1)) 150 && echo "delivered-after-turn inbox=$(inbox)" || echo "NOT-delivered inbox=$(inbox)"; idle; screen 30 > $E/03-busy-after-turn.txt
sed -n "$((N0+1)),\$p" $LOG | cut -c1-200 > $E/03-busy-daemon.log

echo "== S4 repeat exact-once"; for n in r1 r2 r3 r4 r5; do B=$(inbox); sig $n; waitinbox $((B+1)) 150 && echo "$n inbox=$(inbox)" || echo "$n NOT-delivered"; idle; pause 25; echo "  settled inbox=$(inbox) draft=[$(draft)]"; done
echo "unconfirmed=$(grep -c 'submit unconfirmed' $LOG) firstmate0=$(grep -c 'firstmate:0' $LOG)"
cat $L/state/operational-inbox/*.msg 2>/dev/null | grep -oE 'crew-[a-z0-9]+\.status' | sort | uniq -c | tee $E/04-inbox-per-event.txt
cut -c1-220 $LOG > $E/01-all-daemon.log
echo FIN
