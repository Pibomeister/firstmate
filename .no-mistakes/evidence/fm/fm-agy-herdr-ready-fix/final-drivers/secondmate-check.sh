#!/usr/bin/env bash
set -euo pipefail
. "$PWD/.test-agy-final/common.sh"
export PATH="$D/shim:$PATH" FM_AGY_READY_POLLS=240 FM_AGY_POLL_INTERVAL=0.5
cp -R "$ROOT/bin" "$FM_HOME/bin"
SM=$D/secondmate
rc=0
"$FM_HOME/bin/fm-spawn.sh" agy-secondmate "$SM" --secondmate --harness agy --model gemini-3.8-flash-low --effort low --backend herdr > "$E/final-secondmate-retry.log" 2>&1 || rc=$?
printf 'Secondmate full spawn exit=%s\n' "$rc" >> "$E/final-results.log"
[ "$rc" = 0 ]
for i in $(seq 1 180); do
 [ -s "$SM/data/report.md" ] && break
 sleep 1
done
cat "$SM/data/report.md" > "$E/final-secondmate-report.md"
grep -q '80235' "$E/final-secondmate-report.md"
grep -Fq "$SM" "$E/final-secondmate-report.md"
T=$(sed -n 's/^window=//p' "$FM_HOME/state/agy-secondmate.meta")
[ "$(fm_backend_agent_state herdr "$T")" = alive ]
printf 'Secondmate report verified sum=80235 cwd=%s endpoint=%s agent=alive\n' "$SM" "$T" >> "$E/final-results.log"
agy_capture | sed 's/[A-Za-z0-9._%+-]*@[A-Za-z0-9.-]*\.[A-Za-z][A-Za-z]*/[account redacted]/g' > "$E/final-secondmate-pane.txt"
