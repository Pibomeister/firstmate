#!/usr/bin/env bash
set -u
LAB=$1 S=$1/state
echo "### idle try during a running pass (round $2)"
SEEN=$LAB/seen2; rm -rf $SEEN; mkdir -p $SEEN; rm -f $S/.home-summary-stage.*
( while :; do for f in $S/.home-summary-stage.?; do [ -e "$f" ] && cat "$f" >> $SEEN/${f##*.} 2>/dev/null; done; sleep 0.02; done ) & POLL=$!
printf '## In flight\n\n## Queued\n\n- **item-a** - first\n\n## Done\n' > $LAB/data/backlog.md
env -u NO_MISTAKES_GATE FM_HOME=$LAB FM_HOME_SUMMARY_STAGE_PATH=$S/.home-summary-stage.A bin/fm-home-summary-refresh.sh --best-effort & A=$!
i=0; until grep -q '^task-observation' $S/.home-summary-stage.A 2>/dev/null || [ $i -ge 300 ]; do sleep 0.02; i=$((i+1)); done
echo "pass A reached: $(cut -f1 $S/.home-summary-stage.A 2>/dev/null | tr '\n' ' ')"
printf '## In flight\n\n## Queued\n\n- **item-a** - first\n- **item-idle-%s** - added during pass A\n\n## Done\n' "$2" > $LAB/data/backlog.md
env -u NO_MISTAKES_GATE FM_HOME_SUMMARY_IF_IDLE=1 FM_HOME=$LAB FM_HOME_SUMMARY_STAGE_PATH=$S/.home-summary-stage.I bin/fm-home-summary-refresh.sh --best-effort
echo "idle try exit=$?; pass A still running when it returned: $(kill -0 $A 2>/dev/null && echo yes || echo no)"
[ -e $S/.home-summary-flight.lock ] && echo "admission slot: HELD after idle try" || echo "admission slot: free after idle try"
env -u NO_MISTAKES_GATE FM_HOME=$LAB FM_HOME_SUMMARY_STAGE_PATH=$S/.home-summary-stage.B bin/fm-home-summary-refresh.sh --best-effort & B=$!
wait $A; echo "A exit=$?"; wait $B; echo "B exit=$?"; kill $POLL; wait $POLL 2>/dev/null
for t in A I B; do if grep -q '^producer' $SEEN/$t 2>/dev/null; then echo "  $t collected"; else echo "  $t did not collect"; fi; done
jq -e --arg id "item-idle-$2" 'any(.queued[]; .id==$id)' $S/home-summary.json >/dev/null && echo "RESULT: PASS change made during pass A is published by the queued pass" || echo "RESULT: FAIL change missing"
