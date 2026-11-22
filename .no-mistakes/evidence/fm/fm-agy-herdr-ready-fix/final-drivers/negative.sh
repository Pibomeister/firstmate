#!/usr/bin/env bash
set -euo pipefail
. "$PWD/.test-agy-final/common.sh"
P=$(cat "$D/probe-pane"); T=$S:$P
# Active-task footer must not hide an unsubmitted draft.
$H run "$S" pane send-text "$P" 'Thought for 2.4s' >/dev/null
sleep 0.3
screen=$(agy_capture)
printf '%s\n' "$screen" | sed 's/[A-Za-z0-9._%+-]*@[A-Za-z0-9.-]*\.[A-Za-z][A-Za-z]*/[account redacted]/g' > "$E/final-unsubmitted.txt"
rc=0; agy_wait_for_working || rc=$?
printf 'Unsubmitted progress-like input with real task panel: wait_exit=%s\n' "$rc" >> "$E/final-results.log"
[ "$rc" = 1 ]
$H run "$S" pane send-keys "$P" Ctrl+u >/dev/null
# End the probe, preserving its real shell and scrollback; task killed at teardown if needed.
$H run "$S" pane send-text "$P" /quit >/dev/null
$H run "$S" pane send-keys "$P" Enter >/dev/null
for i in $(seq 1 30); do
 [ "$(fm_backend_agent_state herdr "$T")" != alive ] && break
 sleep 0.5
done
screen=$(agy_capture)
printf '%s\n' "$screen" | sed 's/[A-Za-z0-9._%+-]*@[A-Za-z0-9.-]*\.[A-Za-z][A-Za-z]*/[account redacted]/g' > "$E/final-returned-shell.txt"
$H run "$S" pane read "$P" --source recent --format text | sed 's/[A-Za-z0-9._%+-]*@[A-Za-z0-9.-]*\.[A-Za-z][A-Za-z]*/[account redacted]/g' > "$E/final-scrollback.txt"
rc=0; agy_wait_for_working || rc=$?
printf 'Returned shell with prior real AGY progress: wait_exit=%s agent=%s\n' "$rc" "$(fm_backend_agent_state herdr "$T")" >> "$E/final-results.log"
[ "$rc" = 1 ]
