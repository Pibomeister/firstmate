#!/usr/bin/env bash
set -euo pipefail
. "$PWD/.test-agy-final/common.sh"
P=$(cat "$D/probe-pane"); T=$S:$P
AGY=$(command -v agy)
$H run "$S" pane run "$P" "HOME='$D/home' /usr/bin/sandbox-exec -f '$D/agy.sb' '$AGY' --log-file '$D/error-cli.log' --model fm-nonexistent-model --effort low --dangerously-skip-permissions --prompt-interactive 'Compute 43 plus 59.'" >/dev/null
for ((i=0;i<120;i++)); do
 screen=$(agy_capture)
 if [[ "$screen" == *'Error'* || "$screen" == *'not found'* || "$screen" == *'Unknown model'* || "$screen" == *'not available'* ]]; then
  printf '%s\n' "$screen" | sed 's/[A-Za-z0-9._%+-]*@[A-Za-z0-9.-]*\.[A-Za-z][A-Za-z]*/[account redacted]/g' > "$E/final-error.txt"
  rc=0; agy_wait_for_working || rc=$?
  printf 'Actual unsupported-model error: wait_exit=%s agent=%s\n' "$rc" "$(fm_backend_agent_state herdr "$T")" >> "$E/final-results.log"
  [ "$rc" = 1 ]; exit 0
 fi
 sleep .5
done
printf '%s\n' "$screen" > "$E/final-error-timeout.txt"
exit 2
