#!/usr/bin/env bash
set -euo pipefail
. "$PWD/.test-agy-final/common.sh"
T=$(sed -n 's/^window=//p' "$FM_HOME/state/agy-worker-isolated.meta")
git show 2994d3ea2d1f640ababe1c8d434f5c6fd316d832:bin/fm-spawn.sh > "$D/base-spawn.sh"
eval "$(awk '/^agy_pane_is_working\(\)/ {flag=1} flag {print} flag && /^}$/ {exit}' "$D/base-spawn.sh" | sed 's/^agy_pane_is_working()/agy_base_predicate()/')"
screen=$(agy_capture)
a=0; agy_base_predicate "$screen" || a=$?
b=0; agy_pane_is_working "$screen" || b=$?
printf 'Same live completed worker pane: base=%s target=%s native=%s agent=%s\n' "$a" "$b" "$(fm_busy_classify herdr "$T" agy "$ID" "$STATE" "$screen")" "$(fm_backend_agent_state herdr "$T")" >> "$E/final-results.log"
[ "$a" = 1 ]; [ "$b" = 0 ]
AGY_TRUST_PREREGISTERED=0 AGY_TRUST_ANSWERED=0
rc=0; agy_wait_for_working || rc=$?
printf 'Real progress without pre-registration or observed trust answer: wait_exit=%s\n' "$rc" >> "$E/final-results.log"
[ "$rc" = 1 ]
