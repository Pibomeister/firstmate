#!/bin/bash
set -eu
ROOT=$PWD
V=$ROOT/.kimi-validation
LAB=$V/tmux-home
E=/Users/eduardopicazo/.no-mistakes/evidence/01M649GT90YA0AQX8YHNA4K4BZ
unset FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
export HOME=$LAB FM_HOME=$LAB TREEHOUSE_ROOT=$V/pool SHELL=/bin/bash FM_SPAWN_NO_GUARD=1 UV_PYTHON_INSTALL_DIR=$V/python
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
ID=lab-kimi-clipped
PROJ=$V/project-clipped
git clone -q "$V/project" "$PROJ"
bin/fm-brief.sh "$ID" project-clipped --scout >/dev/null
python3 - "$LAB/data/$ID/brief.md" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read().replace('{TASK}', 'Read this brief and report OK.').replace('{FIRSTMATE_SPEC}', 'Write a one-line report only. Do not use network, git mutations, or pipeline commands.')
open(p,'w').write(s)
PY
export TMUX=$(bin/fm-lab-home.sh tmux "$LAB" display-message -p '#{socket_path},#{pid},0')
rc=0
FM_KIMI_READY_POLLS=20 FM_KIMI_POLL_INTERVAL=0.25 bin/fm-spawn.sh "$ID" "$PROJ" --scout --harness kimi --backend tmux > "$E/kimi-clipped-spawn.txt" 2>&1 &
spawn_pid=$!
for ((i=0; i<180; i++)); do
 wid=$(bin/fm-lab-home.sh tmux "$LAB" list-windows -a -F '#{window_id} #{window_name}' | awk '$2=="fm-lab-kimi-clipped" {print $1}')
 if [ -n "$wid" ]; then
  bin/fm-lab-home.sh tmux "$LAB" resize-window -t "$wid" -x 80 -y 10
  printf 'Resized owned window %s to 80x10 before Kimi startup.\n' "$wid" > "$E/kimi-clipped-grid.txt"
  break
 fi
 kill -0 "$spawn_pid" 2>/dev/null || break
 sleep 0.5
done
wait "$spawn_pid" || rc=$?
printf 'spawn_exit=%s\n' "$rc" >> "$E/kimi-clipped-spawn.txt"
if [ -f "$LAB/data/$ID/kimi-readiness-refusal.txt" ]; then
 cp "$LAB/data/$ID/kimi-readiness-refusal.txt" "$E/kimi-clipped-readiness-refusal.txt"
fi
bin/fm-lab-home.sh tmux "$LAB" list-windows -a -F '#{window_id} #{window_name}' > "$E/kimi-clipped-windows-after.txt"
if [ ! -e "$LAB/state/$ID.meta" ]; then printf 'Provisional task metadata removed.\n' >> "$E/kimi-clipped-windows-after.txt"; fi
cat "$E/kimi-clipped-spawn.txt"
