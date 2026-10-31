#!/usr/bin/env bash
S=/tmp/fmlab-orca-state; LB=$(cat $S/labB); T=$(cat $S/tb); E=/Users/eduardopicazo/.no-mistakes/evidence/01M68C1YCBXXQQQ6N5DEHCT0X6/round2
LOG=$LB/state/.supervise-daemon.log
inbox(){ ls $LB/state/operational-inbox 2>/dev/null | grep -c msg; }
sig(){ printf 'done: PR https://example.test/pr/%s\n' "$1" > $LB/state/crew-$1.status; }
waitinbox(){ local want=$1 max=$2 t=0; while [ $t -lt $max ]; do [ "$(inbox)" -ge "$want" ] && return 0; sleep 5; t=$((t+5)); done; return 1; }
idlewait(){ orca terminal wait --terminal $T --for tui-idle --timeout-ms 90000 --json >/dev/null 2>&1; sleep 5; }
screen(){ orca terminal read --terminal $T --limit ${1:-25} --json | jq -r '.result.terminal.tail[]' | cut -c1-170; }
draft(){ orca terminal read --terminal $T --limit 12 --json | jq -r .result.terminal.draft; }

echo "== S1 delivery"; sig one; waitinbox 1 150 && echo delivered inbox=$(inbox) || echo NOT-delivered inbox=$(inbox); idlewait; screen 20 > $E/02-delivery-captain-screen.txt

echo "== S2 draft"; orca terminal send --terminal $T --text "half typed captain words" --json >/dev/null; sleep 3; echo "draft=[$(draft)]"; B=$(inbox); sig two; sleep 75
echo "inbox before=$B now=$(inbox) draft=[$(draft)]"; screen 12 > $E/03-composer-while-typed.txt
grep -c 'composer not confirmed-empty' $LOG
orca terminal send --terminal $T --text $'\x15' --json >/dev/null; sleep 3; echo "cleared draft=[$(draft)]"
waitinbox $((B+1)) 120 && echo delivered-after-clear inbox=$(inbox) || echo NOT-delivered inbox=$(inbox); idlewait; screen 30 > $E/03-composer-after-clear.txt
grep -c 'half typed' $E/03-composer-after-clear.txt | sed 's/^/merged-count=/'

echo "== S3 busy"; B=$(inbox); N0=$(wc -l < $LOG)
orca terminal send --terminal $T --text "Use the Bash tool in the foreground, not background, to run: sleep 70. Then reply DONE." --enter --json >/dev/null
sleep 12; sig three
for i in 1 2 3 4 5 6 7 8; do
  s=$(date +%s); orca terminal wait --terminal $T --for tui-idle --timeout-ms 500 --json 2>/dev/null | jq -r '(.ok|tostring)+" "+(.error.code//"satisfied")' | sed "s/^/$(date +%T) wait: /"
  echo "  inbox=$(inbox) spinner=[$(screen 12 | grep -E '…|Running' | tail -1 | cut -c1-70)]"; sleep 8
done
waitinbox $((B+1)) 150 && echo delivered-after-turn inbox=$(inbox) || echo NOT-delivered inbox=$(inbox); idlewait; screen 30 > $E/04-busy-after-turn.txt
sed -n "$((N0+1)),\$p" $LOG | cut -c1-200 > $E/04-busy-daemon.log

echo "== S4 repeat x4 exact-once"; for n in r1 r2 r3 r4; do B=$(inbox); sig $n; waitinbox $((B+1)) 150 && echo "$n inbox=$(inbox)" || echo "$n NOT-delivered"; idlewait; sleep 20; echo "  settled inbox=$(inbox)"; done
echo "unconfirmed=$(grep -c 'submit unconfirmed' $LOG)"; echo FIN
cut -c1-220 $LOG > $E/02-all-daemon.log; cat $LB/state/operational-inbox/*.msg 2>/dev/null | grep -oE 'crew-[a-z0-9]+\.status' | sort | uniq -c > $E/05-inbox-per-event.txt
