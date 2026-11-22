#!/usr/bin/env bash
set -euo pipefail
. "$PWD/.test-agy-live/common.sh"
R=$($H run "$S" workspace create --cwd "$D/fmhome/projects/scratch" --label agy-background --no-focus)
P=$(printf '%s' "$R" | jq -r '.result.root_pane.pane_id'); T=$S:$P
printf '%s\n' "$P" > "$D/background-pane"
AGY=$(command -v agy)
CMD="HOME='$D/home' /usr/bin/sandbox-exec -f '$D/agy.sb' '$AGY' --log-file '$D/background-cli.log' --prompt-interactive 'Use the terminal tool to run sleep 90 as a background task with a short async wait. Return control immediately. Do not poll or wait for its completion. Reply Background started.' --model gemini-3.8-flash-low --effort low --dangerously-skip-permissions"
$H run "$S" pane run "$P" "$CMD" >/dev/null
found=0
for i in $(seq 1 120); do
 screen=$(agy_capture)
 if [[ "$screen" == *'task(s)'* ]] && [[ "$screen" == *'/tasks'* ]] && [[ "$screen" == *'? for shortcuts'* ]]; then found=1; break; fi
 sleep 1
done
printf '%s\n' "$screen" | sed 's/[A-Za-z0-9._%+-]*@[A-Za-z0-9.-]*\.[A-Za-z][A-Za-z]*/[account redacted]/g' > "$E/live-background.txt"
if [ "$found" != 1 ]; then printf 'No actual background-task footer observed\n'; exit 2; fi
rc=0; agy_wait_for_working || rc=$?
printf 'actual background task: wait_exit=%s native="%s" agent="%s"\n' "$rc" "$(fm_busy_classify herdr "$T" agy "$ID" "$STATE" "$screen")" "$(fm_backend_agent_state herdr "$T")" | tee -a "$E/live-gate-results.log"
$H run "$S" pane process-info --pane "$P" > "$E/live-background-process.json"
exit "$rc"
