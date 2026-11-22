#!/usr/bin/env bash
set -euo pipefail
D=$PWD/.test-agy-final
E=~/.no-mistakes/evidence/01M8101Q8Q67QA7N3HWCG4M2M2
extract() { awk '/^agy_pane_has_brief_progress\(\)/ {flag=1} flag {print} flag && /^}$/ {exit}' "$1"; }
git show 8ee2414f:bin/fm-spawn.sh > "$D/pre-task-panel-fix.sh"
screen=$(cat "$E/final-background.txt")
eval "$(extract "$D/pre-task-panel-fix.sh")"
a=0; agy_pane_has_brief_progress "$screen" || a=$?
eval "$(extract bin/fm-spawn.sh)"
b=0; agy_pane_has_brief_progress "$screen" || b=$?
printf 'Recorded real task-panel regression: pre-fix=%s target=%s\n' "$a" "$b"
[ "$a" = 1 ]; [ "$b" = 0 ]
