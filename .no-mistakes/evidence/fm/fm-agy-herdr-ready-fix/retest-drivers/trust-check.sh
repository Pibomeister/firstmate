#!/usr/bin/env bash
set -euo pipefail
. "$PWD/.test-agy-retest/common.sh"
P=$(cat "$D/probe-pane"); T=$S:$P
screen=$(agy_capture)
printf '%s\n' "$screen" > "$E/retest-trust-dialog.txt"
rc=0; agy_pane_is_working "$screen" || rc=$?
printf 'Unanswered live folder-trust dialog: predicate_exit=%s\n' "$rc" > "$E/retest-results.log"
[ "$rc" = 1 ]
# Answer through the actual spawn readiness loop; an idle prompt must stay refused.
AGY_TRUST_PREREGISTERED=0 FM_AGY_READY_POLLS=8 FM_AGY_POLL_INTERVAL=0.5
rc=0; agy_wait_for_working || rc=$?
printf 'Readiness loop answered trust=%s, unstarted prompt wait_exit=%s\n' "$AGY_TRUST_ANSWERED" "$rc" >> "$E/retest-results.log"
[ "$AGY_TRUST_ANSWERED" = 1 ]; [ "$rc" = 1 ]
agy_capture > "$E/retest-unstarted.txt"
$H run "$S" pane send-text "$P" 'Run pwd using the terminal tool. Then write proof.txt with the computed result of 12345 plus 67890. Do not read other files or launch any agent. Reply only with the sum.' >/dev/null
$H run "$S" pane send-keys "$P" Enter >/dev/null
for i in $(seq 1 240); do
 screen=$(agy_capture)
 if [[ "$screen" == *'? for shortcuts'* ]] && [[ "$screen" == *'80235'* ]] && [[ "$screen" == *'Ran ('* || "$screen" == *'Thought for '* || "$screen" == *'Wrote '* ]]; then
   printf '%s\n' "$screen" | sed 's/[A-Za-z0-9._%+-]*@[A-Za-z0-9.-]*\.[A-Za-z][A-Za-z]*/[account redacted]/g' > "$E/retest-completed-turn.txt"
   FM_AGY_READY_POLLS=1 AGY_TRUST_PREREGISTERED=1
   agy_wait_for_working
   printf 'Completed real tool turn: wait_exit=0 agent=%s proof=%s\n' "$(fm_backend_agent_state herdr "$T")" "$(cat "$D/fmhome/projects/scratch/proof.txt")" >> "$E/retest-results.log"
   exit 0
 fi
 sleep 1
done
printf '%s\n' "$screen" > "$E/retest-tool-timeout.txt"
exit 2
