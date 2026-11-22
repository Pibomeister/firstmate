#!/usr/bin/env bash
set -euo pipefail
. "$PWD/.test-agy-live/common.sh"
mkdir -p "$D/trust-workspace"
R=$($H run "$S" workspace create --cwd "$D/trust-workspace" --label agy-trust --no-focus)
P=$(printf '%s' "$R" | jq -r '.result.root_pane.pane_id'); T=$S:$P
AGY=$(command -v agy)
CMD="HOME='$D/home' /usr/bin/sandbox-exec -f '$D/agy.sb' '$AGY' --log-file '$D/trust-cli.log' --prompt-interactive 'Run pwd once. Then write proof.txt containing the computed result of 4 plus 7. Do not read files or launch agents.' --model gemini-3.8-flash-low --effort low --dangerously-skip-permissions"
$H run "$S" pane run "$P" "$CMD" >/dev/null
seen=0
for i in $(seq 1 60); do
 screen=$(agy_capture)
 if agy_pane_shows_trust_dialog "$screen"; then seen=1; break; fi
 sleep 1
done
[ "$seen" -eq 1 ]
printf '%s\n' "$screen" > "$E/live-trust-dialog.txt"
rc=0; agy_pane_is_working "$screen" || rc=$?
printf 'Unanswered actual trust dialog: readiness=%s\n' "$rc" > "$E/live-trust-result.log"
[ "$rc" -ne 0 ]
AGY_TRUST_PREREGISTERED=0 FM_AGY_READY_POLLS=180 FM_AGY_POLL_INTERVAL=0.5 agy_wait_for_working
printf 'After wait answered safe trust choice: wait_exit=0 agent=%s\n' "$(fm_backend_agent_state herdr "$T")" >> "$E/live-trust-result.log"
cat "$E/live-trust-result.log"
