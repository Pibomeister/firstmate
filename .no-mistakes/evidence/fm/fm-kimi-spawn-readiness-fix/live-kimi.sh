#!/bin/bash
set -eu
ROOT=$PWD
EVIDENCE=/Users/eduardopicazo/.no-mistakes/evidence/01M649GT90YA0AQX8YHNA4K4BZ
LAB=$ROOT/.test-kimi-lab/live
mkdir -p "$LAB"
KIMI=$(command -v kimi)
UV_ROOT=/Users/eduardopicazo/.local/share/uv/python
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM
export KIMI_CODE_NO_AUTO_UPDATE=1
# Public installer, actual system Python and actual uv Python.
mkdir -p "$LAB/hook/.kimi-code"
printf '# preserved operator-style comment\ndefault_model = ""\n' > "$LAB/hook/.kimi-code/config.toml"
cp "$LAB/hook/.kimi-code/config.toml" "$LAB/original.toml"
{
  /usr/bin/python3 --version
  env HOME="$LAB/hook" PATH=/usr/bin:/bin:/usr/sbin:/sbin UV_PYTHON_INSTALL_DIR="$UV_ROOT" "$ROOT/bin/fm-kimi-turnend-hook.sh" install
  test -f "$LAB/hook/.kimi-code/fm-turn-end.sh"
  cp "$LAB/hook/.kimi-code/config.toml" "$EVIDENCE/installed-hook-config.toml"
  env HOME="$LAB/hook" PATH=/usr/bin:/bin:/usr/sbin:/sbin UV_PYTHON_INSTALL_DIR="$UV_ROOT" "$ROOT/bin/fm-kimi-turnend-hook.sh" install
  env HOME="$LAB/hook" PATH=/usr/bin:/bin:/usr/sbin:/sbin UV_PYTHON_INSTALL_DIR="$UV_ROOT" "$ROOT/bin/fm-kimi-turnend-hook.sh" remove
  cmp "$LAB/original.toml" "$LAB/hook/.kimi-code/config.toml"
  echo 'Real Python fallback: install, repeat install, remove; original config bytes restored.'
  rc=0
  env HOME="$LAB/hook" PATH=/usr/bin:/bin:/usr/sbin:/sbin UV_PYTHON_INSTALL_DIR="$LAB/absent-uv" "$ROOT/bin/fm-kimi-turnend-hook.sh" install || rc=$?
  test "$rc" -ne 0
  cmp "$LAB/original.toml" "$LAB/hook/.kimi-code/config.toml"
  echo 'No compatible interpreter: refused without changing config.'
} > "$EVIDENCE/python-live.log" 2>&1
# A disposable real git project, not a copy of implementation.
PROJ=$LAB/project
mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main
printf 'Disposable Kimi seating project.\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=Lab -c user.email=lab@example.invalid commit -qm initial
HOME_LAB=$LAB/home
"$ROOT/bin/fm-lab-home.sh" create "$HOME_LAB"
mkdir -p "$HOME_LAB/.kimi-code"
printf 'default_model = ""\n' > "$HOME_LAB/.kimi-code/config.toml"
printf 'kimi\n' > "$HOME_LAB/config/crew-harness"
export HOME="$HOME_LAB" FM_HOME="$HOME_LAB" KIMI_CODE_HOME="$HOME_LAB/.kimi-code"
export UV_PYTHON_INSTALL_DIR="$UV_ROOT" TREEHOUSE_ROOT="$LAB/treehouse"
export XDG_CONFIG_HOME="$HOME_LAB/.config" XDG_DATA_HOME="$HOME_LAB/.local/share" XDG_CACHE_HOME="$HOME_LAB/.cache"
export SHELL=/bin/bash
unset TMUX TMUX_PANE HERDR_SESSION HERDR_ENV HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID
cleanup() {
  "$ROOT/bin/fm-lab-home.sh" tmux "$HOME_LAB" kill-server >/dev/null 2>&1 || true
  "$ROOT/bin/fm-lab-home.sh" teardown "$HOME_LAB" || true
}
trap cleanup EXIT
"$ROOT/bin/fm-lab-home.sh" tmux "$HOME_LAB" new-session -d -s firstmate -x 80 -y 24 -c "$ROOT" /bin/bash --noprofile --norc
SOCKET_DIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$HOME_LAB")
export TMUX_TMPDIR="$SOCKET_DIR"
TMUX_INFO=$("$ROOT/bin/fm-lab-home.sh" tmux "$HOME_LAB" display-message -p -t firstmate '#{socket_path},#{pid},0')
export TMUX="$TMUX_INFO"
export FM_SPAWN_NO_GUARD=1
export FM_KIMI_READY_POLLS=36 FM_KIMI_POLL_INTERVAL=0.5 FM_KIMI_DELIVERY_POLLS=8
ID=kimi-live-tmux
"$ROOT/bin/fm-brief.sh" "$ID" labproject --scout > "$EVIDENCE/tmux-brief.log" 2>&1
python3 - "$HOME_LAB/data/$ID/brief.md" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read().replace('{TASK}', 'Read this brief and write OK kimi seated to report.md.').replace('{FIRSTMATE_SPEC}', 'Do not change code or publish anything. Report completion if a model is available.')
open(p,'w').write(s)
PY
rc=0
"$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ" --scout --harness kimi --backend tmux > "$EVIDENCE/tmux-spawn.log" 2>&1 || rc=$?
printf 'spawn_exit=%s\n' "$rc" >> "$EVIDENCE/tmux-spawn.log"
"$ROOT/bin/fm-lab-home.sh" tmux "$HOME_LAB" list-panes -a -F '#{session_name}:#{window_name} #{pane_id} #{pane_width}x#{pane_height}' > "$EVIDENCE/tmux-panes.log"
for pane in $("$ROOT/bin/fm-lab-home.sh" tmux "$HOME_LAB" list-panes -a -F '#{pane_id}'); do
  "$ROOT/bin/fm-lab-home.sh" tmux "$HOME_LAB" capture-pane -p -t "$pane" -S -160 > "$EVIDENCE/tmux-${pane#%}.txt"
done
if [ -f "$HOME_LAB/data/$ID/kimi-readiness-refusal.txt" ]; then
  cp "$HOME_LAB/data/$ID/kimi-readiness-refusal.txt" "$EVIDENCE/tmux-readiness-refusal.txt"
fi
if [ -f "$HOME_LAB/.kimi-code/config.toml" ]; then cp "$HOME_LAB/.kimi-code/config.toml" "$EVIDENCE/tmux-kimi-config.toml"; fi
printf 'tmux lab complete; cleanup trap stops only its private server.\n'
