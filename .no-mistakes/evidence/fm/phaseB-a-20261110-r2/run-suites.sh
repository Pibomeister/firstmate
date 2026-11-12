#!/usr/bin/env bash
# Runs the three colocated handoff suites at the worktree head; writes a transcript.
set -u
WT={run-worktree}
OUT=$1
cd "$WT" || exit 99
{
  echo "tested_sha=$(git rev-parse HEAD)"
  echo "admitted_at=$(date -u +%FT%TZ) ticket=${FM_TEST_QUEUE_HELD:-unknown}"
} >"$OUT"
overall=0
for t in tests/fm-handoff-launch.test.sh tests/fm-handoff-trigger.test.sh tests/fm-session-lock-ancestry.test.sh; do
  echo "===== BEGIN bash $t $(date -u +%FT%TZ)" >>"$OUT"
  bash "$t" >>"$OUT" 2>&1; rc=$?
  echo "===== END bash $t exit=$rc $(date -u +%FT%TZ)" >>"$OUT"
  [ $rc -eq 0 ] || overall=1
done
echo "final_exit=$overall finished_at=$(date -u +%FT%TZ)" >>"$OUT"
exit $overall
