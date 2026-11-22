#!/usr/bin/env bash
set -euo pipefail
. "$PWD/.test-agy-retest/common.sh"
export TREEHOUSE_ROOT=$D/pool
export FM_AGY_READY_POLLS=240 FM_AGY_POLL_INTERVAL=0.5
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
mkdir -p "$D/shim" "$FM_HOME/data/agy-worker-isolated"
export PATH="$D/shim:$PATH"
cat > "$FM_HOME/data/agy-worker-isolated/brief.md" <<BRIEF
# Task
## Captain's intent
Verify delivery of a short task to an agy worker.
## Firstmate spec
Add 12345 and 67890. Use a terminal command to write a report at $FM_HOME/data/agy-worker-isolated/report.md containing WORKER_RECEIVED, the computed sum, and your current working directory. Do not read other files, commit, push, use lifecycle commands or launch other agents. Then stop and wait.
BRIEF
rc=0
"$ROOT/bin/fm-spawn.sh" agy-worker-isolated "$FM_HOME/projects/scratch" --scout --harness agy --model gemini-3.8-flash-low --effort low --backend herdr > "$E/retest-worker-isolated-spawn.log" 2>&1 || rc=$?
printf 'Worker full spawn exit=%s\n' "$rc" >> "$E/retest-results.log"
[ "$rc" = 0 ]
for i in $(seq 1 180); do
 [ -s "$FM_HOME/data/agy-worker-isolated/report.md" ] && break
 sleep 1
done
cat "$FM_HOME/data/agy-worker-isolated/report.md" > "$E/retest-worker-isolated-report.md"
grep -q '80235' "$E/retest-worker-isolated-report.md"
WT=$(sed -n 's/^worktree=//p' "$FM_HOME/state/agy-worker-isolated.meta")
grep -Fq "$WT" "$E/retest-worker-isolated-report.md"
T=$(sed -n 's/^window=//p' "$FM_HOME/state/agy-worker-isolated.meta")
[ "$(fm_backend_agent_state herdr "$T")" = alive ]
printf 'Worker report verified sum=80235 cwd=%s endpoint=%s agent=alive\n' "$WT" "$T" >> "$E/retest-results.log"
agy_capture | sed 's/[A-Za-z0-9._%+-]*@[A-Za-z0-9.-]*\.[A-Za-z][A-Za-z]*/[account redacted]/g' > "$E/retest-worker-isolated-pane.txt"
