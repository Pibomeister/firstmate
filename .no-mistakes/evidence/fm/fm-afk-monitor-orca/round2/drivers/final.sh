#!/usr/bin/env bash
E=/Users/eduardopicazo/.no-mistakes/evidence/01M68C1YCBXXQQQ6N5DEHCT0X6/round2; S=/tmp/fmlab-orca-state
echo "--- busy screen"; tail -14 $E/04-busy-after-turn.txt | cut -c1-120
LAB=$(cat $S/lab); T=$(cat $S/t)
{
  echo "--- at $(date +%T), event raised 02:43:02"
  echo "deferred=$(grep -c 'inject deferred' $LAB/state/.supervise-daemon.log) inbox=$(ls $LAB/state/operational-inbox 2>/dev/null | wc -l | tr -d ' ') errors=$(grep -c ERROR $LAB/state/.supervise-daemon.log)"
  head -1 $LAB/state/.subsuper-inject-wedged
  echo "draft=$(orca terminal read --terminal $T --limit 8 --json | jq -r .result.terminal.draft)"
  orca terminal wait --terminal $T --for tui-idle --timeout-ms 500 --json | jq -r 'if .ok then "tui-idle=idle" else .error.code end'
} | tee -a $E/01-ghost-wedge-marker.txt
cut -c1-220 $LAB/state/.supervise-daemon.log > $E/01-ghost-hold-daemon.log
orca terminal read --terminal $T --limit 14 --json | jq -r '.result.terminal.tail[]' | cut -c1-170 > $E/01-ghost-hold-screen.txt
tail -7 $E/01-ghost-hold-screen.txt | cut -c1-110

echo "--- teardown"
for f in lab labD; do
  L=$(cat $S/$f); env FM_HOME=$L bin/fm-afk-launch.sh stop 2>&1 | tail -1 | cut -c1-120
done
for f in t td; do orca terminal close --terminal "$(cat $S/$f)" --json | jq -c .ok; done
orca terminal list 2>/dev/null | grep '^term_' | grep 'fm-lab-afk' | cut -c1-120 | while read -r h _; do orca terminal close --terminal "$h" --json | jq -c .ok; done
sleep 8
for f in lab labB labC labD; do
  L=$(cat $S/$f); pkill -f "$L" 2>/dev/null; bin/fm-lab-home.sh teardown "$L" 2>/dev/null; rm -rf "$L"
done
pgrep -fl "bin/fm-supervise-daemon" | grep "$PWD" | cut -c1-100 || echo no-run-daemons
orca terminal list 2>/dev/null | grep -c 'fm-lab-afk'
ls -d /tmp/fm-lab.* 2>/dev/null
git status --short | head
