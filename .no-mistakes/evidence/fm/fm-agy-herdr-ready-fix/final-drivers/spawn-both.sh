#!/usr/bin/env bash
set -euo pipefail
. "$PWD/.test-agy-final/common.sh"
export TREEHOUSE_ROOT=$D/pool FM_AGY_READY_POLLS=240 FM_AGY_POLL_INTERVAL=0.5 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
mkdir -p "$D/shim" "$FM_HOME/data/agy-worker-isolated"
AGY=$(command -v agy)
cat > "$D/shim/agy" <<WRAP
#!/usr/bin/env bash
export HOME='$D/home'
exec /usr/bin/sandbox-exec -f '$D/agy.sb' '$AGY' --log-file '$D/spawn-cli.log' "\$@"
WRAP
chmod +x "$D/shim/agy"
export PATH="$D/shim:$PATH"
cat > "$FM_HOME/data/agy-worker-isolated/brief.md" <<BRIEF
# Task
You are a bounded test worker. Perform this task yourself.
## Captain's intent
Verify delivery of a short task to an agy worker.
## Firstmate spec
Add 12345 and 67890. Use a terminal command to write a report at $FM_HOME/data/agy-worker-isolated/report.md containing WORKER_RECEIVED, the computed sum, and your current working directory. Do not read other files, commit, push, use lifecycle commands or launch other agents. Then stop and wait.
BRIEF
bash "$D/isolated-worker.sh"
SM=$D/secondmate
"$ROOT/bin/fm-lab-home.sh" create "$SM" >/dev/null
cp -R "$ROOT/bin" "$FM_HOME/bin"
cp -R "$ROOT/bin" "$SM/bin"
cp "$ROOT/AGENTS.md" "$SM/AGENTS.md"
printf 'agy-secondmate\n' > "$SM/.fm-secondmate-home"
git -C "$SM" init -q -b main
printf 'data/\nstate/\nconfig/\nprojects/\n' > "$SM/.gitignore"
git -C "$SM" add .gitignore
git -C "$SM" -c user.name=Test -c user.email=test@example.invalid commit -qm init
cat > "$SM/data/charter.md" <<BRIEF
# Bounded secondmate validation
Do this one task yourself. Add 12345 and 67890. Use the terminal tool to write $SM/data/report.md with SECOND_MATE_RECEIVED, the computed sum, and your actual current working directory. Do not read files, supervise, launch agents, run any Firstmate lifecycle command, commit or push. Stop and wait after the report.
BRIEF
bash "$D/secondmate-check.sh"
