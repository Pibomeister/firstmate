#!/bin/bash
set -eu
ROOT=$PWD
V=$ROOT/.kimi-validation
LAB=$V/tmux-home
E=/Users/eduardopicazo/.no-mistakes/evidence/01M649GT90YA0AQX8YHNA4K4BZ
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
unset FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
export HOME=$LAB FM_HOME=$LAB TREEHOUSE_ROOT=$V/pool SHELL=/bin/bash FM_SPAWN_NO_GUARD=1
export UV_PYTHON_INSTALL_DIR=$V/python
PROJ=$V/project
mkdir -p "$PROJ" "$LAB/data" "$LAB/config"
git init -q -b main "$PROJ"
printf 'Disposable Kimi seating validation project.\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=Lab -c user.email=lab@example.invalid commit -qm initial
printf 'kimi\n' > "$LAB/config/crew-harness"
printf 'tmux\n' > "$LAB/config/backend"
bin/fm-lab-home.sh tmux "$LAB" set-environment -g TREEHOUSE_ROOT "$TREEHOUSE_ROOT"
bin/fm-lab-home.sh tmux "$LAB" set-environment -g FM_HOME "$LAB"
bin/fm-lab-home.sh tmux "$LAB" set-option -g default-shell /bin/bash
bin/fm-lab-home.sh tmux "$LAB" set-option -g default-command '/bin/bash --noprofile --norc'
export TMUX=$(bin/fm-lab-home.sh tmux "$LAB" display-message -p '#{socket_path},#{pid},0')
ID=lab-kimi-nopy
bin/fm-brief.sh "$ID" project --scout >/dev/null
python3 - "$LAB/data/$ID/brief.md" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read().replace('{TASK}', 'Prove that Kimi can read this brief in its isolated worktree.').replace('{FIRSTMATE_SPEC}', 'Write a one-line report OK kimi seated to the report path in this brief and append done to the status file. Do not use any network, git mutation, or pipeline command.')
open(p,'w').write(s)
PY
cp "$LAB/.kimi-code/config.toml" "$V/config-before.toml"
bin/fm-lab-home.sh tmux "$LAB" list-windows -a -F '#{window_id}' > "$V/windows-before.txt"
rc=0
UV_PYTHON_INSTALL_DIR="$V/no-python" FM_KIMI_PYTHON_PREFIXES='' bin/fm-spawn.sh "$ID" "$PROJ" --scout --harness kimi --backend tmux > "$E/kimi-prelaunch-no-python.txt" 2>&1 || rc=$?
printf 'spawn_exit=%s\n' "$rc" >> "$E/kimi-prelaunch-no-python.txt"
[ "$rc" -ne 0 ]
cmp "$V/config-before.toml" "$LAB/.kimi-code/config.toml"
bin/fm-lab-home.sh tmux "$LAB" list-windows -a -F '#{window_id}' > "$V/windows-after.txt"
cmp "$V/windows-before.txt" "$V/windows-after.txt"
[ ! -e "$LAB/state/$ID.meta" ]
printf 'Config bytes unchanged; no new tmux window or task record.\n' >> "$E/kimi-prelaunch-no-python.txt"
ID=lab-kimi-trust
bin/fm-brief.sh "$ID" project --scout >/dev/null
python3 - "$LAB/data/$ID/brief.md" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read().replace('{TASK}', 'Prove that Kimi can read this brief in its isolated worktree.').replace('{FIRSTMATE_SPEC}', 'Write a one-line report OK kimi seated to the report path in this brief and append done to the status file. Do not use any network, git mutation, or pipeline command.')
open(p,'w').write(s)
PY
rc=0
bin/fm-spawn.sh "$ID" "$PROJ" --scout --harness kimi --backend tmux > "$E/kimi-live-tmux-spawn.txt" 2>&1 || rc=$?
printf 'spawn_exit=%s\n' "$rc" >> "$E/kimi-live-tmux-spawn.txt"
if [ -f "$LAB/state/$ID.meta" ]; then
 cp "$LAB/state/$ID.meta" "$E/kimi-live-tmux-meta.txt"
fi
if [ -f "$LAB/data/$ID/kimi-readiness-refusal.txt" ]; then
 cp "$LAB/data/$ID/kimi-readiness-refusal.txt" "$E/kimi-live-tmux-readiness-refusal.txt"
fi
bin/fm-lab-home.sh tmux "$LAB" list-windows -a -F '#{window_id} #{window_name}' > "$E/kimi-live-tmux-windows.txt"
bin/fm-lab-home.sh tmux "$LAB" capture-pane -p -t firstmate:fm-lab-kimi-trust -S -100 > "$E/kimi-live-tmux-final.txt" 2>/dev/null || true
cat "$E/kimi-live-tmux-spawn.txt"
