#!/usr/bin/env bash
# burst.sh <code-root> <lab-home> <round>
set -u
ROOT=$1 LAB=$2 R=$3
S=$LAB/state
rm -f $S/.home-summary-stage.* ; SEEN=$LAB/seen; rm -rf $SEEN; mkdir -p $SEEN
( while :; do for f in $S/.home-summary-stage.?; do [ -e "$f" ] && cat "$f" >> $SEEN/${f##*.} 2>/dev/null; done; sleep 0.02; done ) & POLL=$!
printf '## In flight\n\n## Queued\n\n- **item-a** - first queued item\n\n## Done\n' > $LAB/data/backlog.md
env -u NO_MISTAKES_GATE FM_HOME=$LAB FM_HOME_SUMMARY_STAGE_PATH=$S/.home-summary-stage.A "$ROOT/bin/fm-home-summary-refresh.sh" --best-effort & A=$!
i=0; until grep -q '^task-observation' $S/.home-summary-stage.A 2>/dev/null || [ $i -ge 200 ]; do sleep 0.02; i=$((i+1)); done
echo "round $R: pass A in stage: $(cut -f1 $S/.home-summary-stage.A 2>/dev/null | tr '\n' ' ')"
# status change after A began collecting
printf '## In flight\n\n## Queued\n\n- **item-a** - first queued item\n- **item-b-r%s** - added while pass A was collecting\n\n## Done\n' "$R" > $LAB/data/backlog.md
pids=
for t in B C D E F; do
  env -u NO_MISTAKES_GATE FM_HOME=$LAB FM_HOME_SUMMARY_STAGE_PATH=$S/.home-summary-stage.$t "$ROOT/bin/fm-home-summary-refresh.sh" --best-effort & pids="$pids $!"
  sleep 0.05
done
rcs=; for p in $A $pids; do wait $p; rcs="$rcs $?"; done
kill $POLL; wait $POLL 2>/dev/null
echo "exit codes A..F:$rcs"
n=0; for t in A B C D E F; do if [ -s $SEEN/$t ] && grep -q "^producer" $SEEN/$t; then n=$((n+1)); echo "  trigger $t: collected (stages seen: $(cut -f1 $SEEN/$t | sort -u | tr '\n' ' '))"; elif [ -s $SEEN/$t ]; then echo "  trigger $t: entered $(cut -f1 $SEEN/$t | sort -u | tr '\n' ' ') but did not collect"; else echo "  trigger $t: exited at admission (joined queued pass)"; fi; done; echo "passes that collected: $n"
echo "published queued ids: $(jq -r '[.queued[].id]|join(",")' $S/home-summary.json)"
jq -e --arg id "item-b-r$R" 'any(.queued[]; .id==$id)' $S/home-summary.json >/dev/null && echo "RESULT round $R: PASS late change published" || echo "RESULT round $R: FAIL late change missing"
ls -a $S | grep -E 'flight|refresh.lock' || echo "  no admission/publication lock left behind"
