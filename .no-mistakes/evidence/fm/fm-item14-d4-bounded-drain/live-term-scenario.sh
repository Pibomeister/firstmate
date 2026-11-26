#!/usr/bin/env bash
# Live scenario: TERM the real drain mid-fold in a lab home; check scratch and
# worker cleanup, then a retry presents the note the killed drain never committed.
set -u
WT=$1; OUT=$2; N=${LINES_N:-3000}
cd "$WT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null; : > "$LAB/config/supervision-host-off"
S="$LAB/state/task-live.status"; printf 'kind=ship\n' > "$LAB/state/task-live.meta"; : > "$S"
for i in $(seq -w 0 29); do echo "needs-decision [key=k$i]: live decision $i" >> "$S"; done
awk -v n="$N" 'BEGIN{for(i=0;i<n;i++) print "working: historical context " i}' >> "$S"
echo "note: note the killed drain must not swallow" >> "$S"
ENVX="env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME=$LAB"
( exec $ENVX FM_WAKE_DRAIN_PRESENTATION_TIMEOUT=120 bin/fm-wake-drain.sh > "$OUT/term.out" 2> "$OUT/term.err" ) & p=$!
for i in $(seq 1 60); do ls -d "$LAB"/state/.wake-drain-presentation.* >/dev/null 2>&1 && break; sleep 0.25; done
sleep 1
echo "drain pid $p: $(ps -o command= -p $p | cut -c1-80)"
ls -d "$LAB"/state/.wake-drain-presentation.* 2>/dev/null | sed "s|$LAB|LAB|;s/^/scratch during drain: /"
desc() { local q; for q in $(pgrep -P "$1"); do echo $q; desc $q; done; }
kids=$(desc $p | tr '\n' ' '); echo "descendants during drain: ${kids:-none}"
kill -TERM $p; wait $p; echo "term rc=$?"
sleep 2
echo "scratch dirs left after TERM: $(ls -d "$LAB"/state/.wake-drain-presentation.* 2>/dev/null | wc -l | tr -d ' ')"
alive=0; for k in $kids; do kill -0 $k 2>/dev/null && { alive=$((alive+1)); ps -o pid=,command= -p $k; }; done; echo "descendants still alive after TERM: $alive"
echo "killed drain printed the note: $(grep -c 'must not swallow' "$OUT/term.out")"
s=$SECONDS; $ENVX timeout 600 bin/fm-wake-drain.sh > "$OUT/after-term.out" 2> "$OUT/after-term.err"; rc=$?
echo "retry rc=$rc secs=$((SECONDS-s)) note shown=$(grep -c 'must not swallow' "$OUT/after-term.out") decisions=$(grep -c 'key=k' "$OUT/after-term.out")"
grep -h 'SKIPPED\|INCOMPLETE' "$OUT/after-term.out" "$OUT/after-term.err"
