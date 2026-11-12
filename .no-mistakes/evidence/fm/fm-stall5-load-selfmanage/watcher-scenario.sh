#!/usr/bin/env bash
# Drive the real watcher against the lab home: phase 1 opt-in + load 200
# starts the sustained window; phase 2 removes the opt-in, leaves one pause
# record, drops load to 5, and expects the watcher to resume that worker.
set -u
WT={run-worktree}
E=~/.no-mistakes/evidence/01M77FKWZDE4Y9C2Y8EKVXQV0W
LAB=/private/var/folders/93/6w1bxqxn2yb92mt6rmt5zbzw0000gn/T/fm-lab.WWTGrI
cd "$WT"
printf '4\nmax-load1 16\n' > $LAB/config/lane-capacity; rm -rf $LAB/state/load-relief; echo 200 > $LAB/load.txt
W=bin/fm-watch.sh
env -u TMUX -u TMUX_PANE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_ROOT_OVERRIDE \
  TMUX_TMPDIR=/tmp/fml.5mHS8J FM_HOME=$LAB FM_TEST_SEAM=1 FM_LOAD_RELIEF_LOAD_FILE=$LAB/load.txt \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$W" > $E/watcher.out 2>&1 &
WPID=$!
i=0; while [ $i -lt 90 ] && [ ! -f $LAB/state/load-relief/high-since ]; do sleep 1; i=$((i+1)); done
echo "### phase 1: lane-capacity present, load 200: high-since after ${i}s = $(cat $LAB/state/load-relief/high-since 2>/dev/null || echo MISSING)"
rm -f $LAB/config/lane-capacity
mkdir -p $LAB/state/load-relief/paused
printf 'id=w-high\npaused_epoch=%s\npriority=1\nload=200\nceiling=16\nspawn_gen=s1000.1\nstate=paused\n' "$(date +%s)" > $LAB/state/load-relief/paused/w-high
printf 'paused [key=load-relief] [at=%s]: load relief: lab fixture pause\n' "$(date +%s)" >> $LAB/state/w-high.status
echo 5 > $LAB/load.txt
echo "### phase 2: lane-capacity removed, one pause record for w-high, load 5"
i=0; while [ $i -lt 120 ] && [ -f $LAB/state/load-relief/paused/w-high ]; do sleep 1; i=$((i+1)); done
if [ -f $LAB/state/load-relief/paused/w-high ]; then echo "RESULT: record still present after ${i}s"; else echo "RESULT: watcher resumed w-high after ${i}s"; fi
tail -1 $LAB/state/w-high.status
FM_HOME=$LAB FM_STATE_OVERRIDE=$LAB/state bin/fm-watch-arm.sh --stop >/dev/null 2>&1 || true
kill $WPID 2>/dev/null; wait $WPID 2>/dev/null
echo "watcher stopped"
