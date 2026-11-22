#!/usr/bin/env bash
set -euo pipefail
. "$PWD/.test-agy-final/common.sh"
P=$(cat "$D/probe-pane"); T=$S:$P
$H run "$S" pane send-text "$P" 'Use the terminal tool to run sleep 180 as a background task with a short async wait. Return control immediately. Do not poll or wait for its completion. Reply Background started.' >/dev/null
$H run "$S" pane send-keys "$P" Enter >/dev/null
for i in $(seq 1 180); do
 screen=$(agy_capture)
 if [[ "$screen" == *'task(s)'* ]] && [[ "$screen" == *'/tasks'* ]] && [[ "$screen" == *'? for shortcuts'* ]]; then
   printf '%s\n' "$screen" | sed 's/[A-Za-z0-9._%+-]*@[A-Za-z0-9.-]*\.[A-Za-z][A-Za-z]*/[account redacted]/g' > "$E/final-background.txt"
   agy_wait_for_working
   printf 'Active real background task: wait_exit=0 native=%s agent=%s\n' "$(fm_busy_classify herdr "$T" agy "$ID" "$STATE" "$screen")" "$(fm_backend_agent_state herdr "$T")" >> "$E/final-results.log"
   $H run "$S" pane process-info --pane "$P" > "$E/final-background-process.json"
   exit 0
 fi
 sleep 1
done
printf '%s\n' "$screen" > "$E/final-background-timeout.txt"
exit 2
