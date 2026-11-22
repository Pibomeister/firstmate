#!/usr/bin/env bash
set -euo pipefail
. "$PWD/.test-agy-live/common.sh"
LOG=$E/live-negative-results.log
P=$(cat "$D/real-pane"); T=$S:$P
git show 2994d3ea:bin/fm-spawn.sh > "$D/base-spawn.sh"
before=$(awk '/^agy_pane_is_working\(\)/ {flag=1} flag {print} flag && /^}$/ {exit}' "$D/base-spawn.sh" | sed 's/^agy_pane_is_working()/agy_pane_is_working_before_fix()/')
eval "$before"
screen=$(agy_capture)
old_rc=0; agy_pane_is_working_before_fix "$screen" || old_rc=$?
new_rc=0; agy_pane_is_working "$screen" || new_rc=$?
printf 'Same live completed tool turn: base predicate=%s target predicate=%s\n' "$old_rc" "$new_rc" > "$LOG"
[ "$old_rc" -ne 0 ]; [ "$new_rc" -eq 0 ]
$H run "$S" pane send-text "$P" 'Thought for 2.4s' >/dev/null
screen=$(agy_capture)
printf '%s\n' "$screen" | sed 's/[A-Za-z0-9._%+-]*@[A-Za-z0-9.-]*\.[A-Za-z][A-Za-z]*/[account redacted]/g' > "$E/live-unsubmitted.txt"
rc=0; agy_wait_for_working || rc=$?
printf 'Unsubmitted composer text that looks like progress: wait_exit=%s\n' "$rc" >> "$LOG"
[ "$rc" -ne 0 ]
# Clear pending text with the normal composer editing key, then quit this
# unrecorded lab probe through the harness command, preserving its shell.
$H run "$S" pane send-keys "$P" Ctrl+u >/dev/null
$H run "$S" pane send-text "$P" /quit >/dev/null
$H run "$S" pane send-keys "$P" Enter >/dev/null
for i in $(seq 1 30); do
 [ "$(fm_backend_agent_state herdr "$T")" != alive ] && break
 sleep 0.5
done
screen=$(agy_capture)
printf '%s\n' "$screen" | sed 's/[A-Za-z0-9._%+-]*@[A-Za-z0-9.-]*\.[A-Za-z][A-Za-z]*/[account redacted]/g' > "$E/live-returned-shell.txt"
$H run "$S" pane read "$P" --source recent --format text | sed 's/[A-Za-z0-9._%+-]*@[A-Za-z0-9.-]*\.[A-Za-z][A-Za-z]*/[account redacted]/g' > "$E/live-shell-scrollback.txt"
rc=0; agy_wait_for_working || rc=$?
printf 'Returned shell with prior real progress: wait_exit=%s agent=%s\n' "$rc" "$(fm_backend_agent_state herdr "$T")" >> "$LOG"
[ "$rc" -ne 0 ]
cat "$LOG"
