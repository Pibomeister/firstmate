#!/usr/bin/env bash
set -euo pipefail
. "$PWD/.test-agy-retest/common.sh"
export TREEHOUSE_ROOT=$D/pool
export FM_AGY_READY_POLLS=240 FM_AGY_POLL_INTERVAL=0.5
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
mkdir -p "$D/shim" "$FM_HOME/data/agy-worker"
AGY=$(command -v agy)
cat > "$D/shim/agy" <<SH
#!/usr/bin/env bash
exec /usr/bin/sandbox-exec -f '$D/agy.sb' '$AGY' --log-file '$D/spawn-cli.log' "\$@"
SH
chmod +x "$D/shim/agy"
export PATH="$D/shim:$PATH"
cat > "$FM_HOME/data/agy-worker/brief.md" <<BRIEF
# Task
## Captain's intent
Verify delivery of a short task to an agy worker.
## Firstmate spec
Add 12345 and 67890. Use a terminal command to write a report at $FM_HOME/data/agy-worker/report.md containing WORKER_RECEIVED, the computed sum, and your current working directory. Do not read other files, commit, push, use lifecycle commands or launch other agents. Then stop and wait.
BRIEF
rc=0
"$ROOT/bin/fm-spawn.sh" agy-worker "$FM_HOME/projects/scratch" --scout --harness agy --model gemini-3.8-flash-low --effort low --backend herdr > "$E/retest-worker-spawn.log" 2>&1 || rc=$?
printf 'Worker full spawn exit=%s\n' "$rc" >> "$E/retest-results.log"
[ "$rc" = 0 ]
for i in $(seq 1 180); do
 [ -s "$FM_HOME/data/agy-worker/report.md" ] && break
 sleep 1
done
cat "$FM_HOME/data/agy-worker/report.md" > "$E/retest-worker-report.md"
grep -q '80235' "$E/retest-worker-report.md"
WT=$(sed -n 's/^worktree=//p' "$FM_HOME/state/agy-worker.meta")
grep -Fq "$WT" "$E/retest-worker-report.md"
T=$(sed -n 's/^window=//p' "$FM_HOME/state/agy-worker.meta")
[ "$(fm_backend_agent_state herdr "$T")" = alive ]
printf 'Worker report verified sum=80235 cwd=%s endpoint=%s agent=alive\n' "$WT" "$T" >> "$E/retest-results.log"
agy_capture | sed 's/[A-Za-z0-9._%+-]*@[A-Za-z0-9.-]*\.[A-Za-z][A-Za-z]*/[account redacted]/g' > "$E/retest-worker-pane.txt"
SM=$D/secondmate
"$ROOT/bin/fm-lab-home.sh" create "$SM" >/dev/null
cp -R "$ROOT/bin" "$SM/bin"
printf 'agy-secondmate\n' > "$SM/.fm-secondmate-home"
git -C "$SM" init -q -b main
printf 'data/\nstate/\nconfig/\nprojects/\n' > "$SM/.gitignore"
git -C "$SM" -c user.name=Test -c user.email=test@example.invalid add .gitignore
git -C "$SM" -c user.name=Test -c user.email=test@example.invalid commit -qm init
cat > "$SM/data/charter.md" <<BRIEF
# Bounded secondmate validation
Do this one task yourself. Add 12345 and 67890. Use the terminal tool to write $SM/data/report.md with SECOND_MATE_RECEIVED, the computed sum, and your actual current working directory. Do not read files, supervise, launch agents, run any Firstmate lifecycle command, commit or push. Stop and wait after the report.
BRIEF
rc=0
"$ROOT/bin/fm-spawn.sh" agy-secondmate "$SM" --secondmate --harness agy --model gemini-3.8-flash-low --effort low --backend herdr > "$E/retest-secondmate-spawn.log" 2>&1 || rc=$?
printf 'Secondmate full spawn exit=%s\n' "$rc" >> "$E/retest-results.log"
[ "$rc" = 0 ]
for i in $(seq 1 180); do
 [ -s "$SM/data/report.md" ] && break
 sleep 1
done
cat "$SM/data/report.md" > "$E/retest-secondmate-report.md"
grep -q '80235' "$E/retest-secondmate-report.md"
grep -Fq "$SM" "$E/retest-secondmate-report.md"
T=$(sed -n 's/^window=//p' "$FM_HOME/state/agy-secondmate.meta")
[ "$(fm_backend_agent_state herdr "$T")" = alive ]
printf 'Secondmate report verified sum=80235 cwd=%s endpoint=%s agent=alive\n' "$SM" "$T" >> "$E/retest-results.log"
agy_capture | sed 's/[A-Za-z0-9._%+-]*@[A-Za-z0-9.-]*\.[A-Za-z][A-Za-z]*/[account redacted]/g' > "$E/retest-secondmate-pane.txt"
