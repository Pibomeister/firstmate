#!/usr/bin/env bash
# Live scenario: a lab firstmate home with a cold, large status log full of
# open decisions. Drive the real bin/fm-wake-drain.sh with a short bound until
# it converges; then interrupt one drain with TERM and check its cleanup.
set -u
WT=$1; OUT=$2; BOUND=${BOUND:-2}; N=${LINES_N:-3000}
cd "$WT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null
: > "$LAB/config/supervision-host-off"
run() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
S="$LAB/state/task-live.status"; printf 'kind=ship\n' > "$LAB/state/task-live.meta"
: > "$S"
for i in $(seq -w 0 29); do echo "needs-decision [key=k$i]: live decision $i" >> "$S"; done
awk -v n="$N" 'BEGIN{for(i=0;i<n;i++) print "working: historical context " i}' >> "$S"
echo "note: fresh event after the stall" >> "$S"
cp "$S" "$OUT/status.before"
echo "== scenario 1: bounded drains converge (bound=${BOUND}s, ${N} history lines)"
a=0
while :; do
  a=$((a+1)); s=$SECONDS; rc=0
  run FM_WAKE_DRAIN_PRESENTATION_TIMEOUT=$BOUND timeout 300 bin/fm-wake-drain.sh > "$OUT/attempt-$a.out" 2> "$OUT/attempt-$a.err" || rc=$?
  echo "attempt $a rc=$rc secs=$((SECONDS-s)) open_decisions_shown=$(grep -c 'key=k' "$OUT/attempt-$a.out") stderr_tail=$(tail -1 "$OUT/attempt-$a.err")"
  [ "$rc" = 0 ] && break
  [ "$rc" = 124 ] || { echo "UNEXPECTED rc"; break; }
  [ $a -lt 40 ] || { echo "NEVER CONVERGED"; break; }
done
echo "final attempt $a: decisions presented = $(grep -c 'key=k' "$OUT/attempt-$a.out")/30; fresh note presented = $(grep -c 'fresh event after the stall' "$OUT/attempt-$a.out")"
cmp -s "$OUT/status.before" "$S" && echo "status history unchanged: yes" || echo "status history unchanged: NO"
echo "== repeat drain does not replay the fresh note"
run timeout 300 bin/fm-wake-drain.sh > "$OUT/repeat.out" 2> "$OUT/repeat.err"; echo "repeat rc=$? fresh-note replays=$(grep -c 'fresh event after the stall' "$OUT/repeat.out") decisions still open=$(grep -c 'key=k' "$OUT/repeat.out")"
echo "== scenario 2: TERM during a drain leaves no scratch and no live children"
echo "note: second fresh note" >> "$S"
rm -f "$LAB"/state/.task-live.status.open-decisions-cursor* 2>/dev/null
run FM_WAKE_DRAIN_PRESENTATION_TIMEOUT=60 bin/fm-wake-drain.sh > "$OUT/term.out" 2> "$OUT/term.err" & p=$!
sleep 1.5; ls -d "$LAB"/state/.wake-drain-presentation.* 2>/dev/null | sed "s|$LAB|LAB|" | sed 's/^/scratch during drain: /'
kids=$(pgrep -P $p | tr '\n' ' '); echo "children during drain: ${kids:-none}"
kill -TERM $p; wait $p; echo "term rc=$?"
sleep 2
left=$(ls -d "$LAB"/state/.wake-drain-presentation.* 2>/dev/null | wc -l | tr -d ' '); echo "scratch dirs left after TERM: $left"
alive=0; for k in $kids; do kill -0 $k 2>/dev/null && alive=$((alive+1)); done; echo "children still alive after TERM: $alive"
echo "== retry after TERM presents the unread note"
run timeout 300 bin/fm-wake-drain.sh > "$OUT/after-term.out" 2> "$OUT/after-term.err"; echo "after-term rc=$? second-note shown=$(grep -c 'second fresh note' "$OUT/after-term.out") decisions=$(grep -c 'key=k' "$OUT/after-term.out")"
