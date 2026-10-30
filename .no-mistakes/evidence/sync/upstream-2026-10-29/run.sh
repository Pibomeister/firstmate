#!/bin/bash
cd /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M65FZAGTBH5THVT8CTWDJSMT
EV=/Users/eduardopicazo/.no-mistakes/evidence/01M65FZAGTBH5THVT8CTWDJSMT
T="fm-agy-primary fm-approval-failover fm-backend-orca fm-merge-local fm-pr-health fm-session-lock-ancestry fm-supervision-host-hook fm-wake-queue fm-watch-arm fm-watch-checkpoint fm-watcher-lock fm-backend-tmux-smoke fm-supervision-bounds fm-watch-recovery-loop"
for t in $T; do
  ( s=$(date +%s); timeout 1500 bash tests/$t.test.sh > $EV/logs/$t.log 2>&1; rc=$?; echo "$t rc=$rc $(( $(date +%s)-s ))s" >> $EV/logs/summary.txt ) &
done
wait
echo DONE >> $EV/logs/summary.txt
