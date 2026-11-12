#!/usr/bin/env bash
# Phase 2 retry: lane-capacity removed, one pause record, load 5; re-arm the
# one-shot watcher whenever it exits on a wake, as a supervisor does.
set -u
WT={run-worktree}
E=~/.no-mistakes/evidence/01M77FKWZDE4Y9C2Y8EKVXQV0W
LAB=/private/var/folders/93/6w1bxqxn2yb92mt6rmt5zbzw0000gn/T/fm-lab.WWTGrI
cd "$WT"
W=bin/fm-watch.sh
[ ! -e $LAB/config/lane-capacity ] && echo "config/lane-capacity: absent"
ls $LAB/state/load-relief/paused
echo 5 > $LAB/load.txt
start() { env -u TMUX -u TMUX_PANE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_ROOT_OVERRIDE \
  TMUX_TMPDIR=/tmp/fml.5mHS8J FM_HOME=$LAB FM_TEST_SEAM=1 FM_LOAD_RELIEF_LOAD_FILE=$LAB/load.txt \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$W" >> $E/watcher2.out 2>&1 & WPID=$!; arms=$((arms+1)); }
arms=0; start
i=0
while [ $i -lt 150 ] && [ -f $LAB/state/load-relief/paused/w-high ]; do
  sleep 1; i=$((i+1))
  kill -0 $WPID 2>/dev/null || { wait $WPID 2>/dev/null; start; }
done
if [ -f $LAB/state/load-relief/paused/w-high ]; then echo "RESULT: record still present after ${i}s (watcher armed $arms times)"; else echo "RESULT: watcher's relief check resumed w-high after ${i}s with lane-capacity absent (watcher armed $arms times)"; fi
tail -1 $LAB/state/w-high.status
kill $WPID 2>/dev/null; wait $WPID 2>/dev/null
FM_HOME=$LAB FM_STATE_OVERRIDE=$LAB/state bin/fm-watch-arm.sh --stop >/dev/null 2>&1 || true
echo "watcher stopped"
