#!/bin/bash
set -eu
ROOT=$PWD
V=$ROOT/.kimi-validation
E=/Users/eduardopicazo/.no-mistakes/evidence/01M649GT90YA0AQX8YHNA4K4BZ
OP_HOME=$HOME
OP_PATH=$PATH
LAB=$V/herdr-home
SESSION=fm-lab-kimigate2-649
export FM_HERDR_LAB_STATE_DIR=$V/herdr-state HERDR_CONFIG_PATH=$V/herdr.toml
export XDG_CONFIG_HOME=$OP_HOME/.config
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH
unset FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
[ -f "$LAB/.fm-lab-home" ] || bin/fm-lab-home.sh create "$LAB" >/dev/null
export HOME=$LAB FM_HOME=$LAB SHELL=/bin/bash TREEHOUSE_ROOT=$V/herdr-pool UV_PYTHON_INSTALL_DIR=$V/python FM_SPAWN_NO_GUARD=1
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir -p "$LAB/.kimi-code" "$V/herdr-bin"
printf '# Isolated Kimi settings.\n' > "$LAB/.kimi-code/config.toml"
helper=$ROOT/bin/fm-herdr-lab.sh
lab() { PATH="$OP_PATH" "$helper" run "$SESSION" "$@"; }
cleanup() {
 local rc=$?
 trap - EXIT
 PATH="$OP_PATH" "$helper" teardown "$SESSION" >> "$E/kimi-herdr-lab.log" 2>&1 || rc=1
 printf 'herdr_lab_teardown_exit=%s\n' "$rc" >> "$E/kimi-herdr-lab.log"
 exit "$rc"
}
trap cleanup EXIT
PATH="$OP_PATH" "$helper" provision "$SESSION" >> "$E/kimi-herdr-lab.log" 2>&1
lab status --json > "$E/kimi-herdr-status.json"
cat > "$V/herdr-bin/herdr" <<EOF
#!/bin/bash
set -eu
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = "$SESSION" ]; then
 args=("\${args[@]:0:\$((n-2))}")
fi
exec env PATH='$OP_PATH' '$helper' run '$SESSION' "\${args[@]}"
EOF
chmod +x "$V/herdr-bin/herdr"
export PATH=$V/herdr-bin:$OP_PATH HERDR_SESSION=$SESSION
ID=lab-kimi-herdr2
bin/fm-brief.sh "$ID" project --scout --herdr-lab > /dev/null
python3 - "$LAB/data/$ID/brief.md" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read().replace('{TASK}', 'Prove that Kimi can read this brief in its isolated worktree.').replace('{FIRSTMATE_SPEC}', 'Write OK kimi seated as a one-line report and append done to the status file. Do not use network, git mutation, or pipeline commands.')
open(p,'w').write(s)
PY
rc=0
FM_KIMI_READY_POLLS=30 FM_KIMI_DELIVERY_POLLS=8 bin/fm-spawn.sh "$ID" "$V/project" --scout --harness kimi --backend herdr > "$E/kimi-live-herdr-spawn.txt" 2>&1 || rc=$?
printf 'spawn_exit=%s\n' "$rc" >> "$E/kimi-live-herdr-spawn.txt"
if [ -f "$LAB/state/$ID.meta" ]; then cp "$LAB/state/$ID.meta" "$E/kimi-live-herdr-meta.txt"; fi
if [ -f "$LAB/data/$ID/kimi-readiness-refusal.txt" ]; then cp "$LAB/data/$ID/kimi-readiness-refusal.txt" "$E/kimi-live-herdr-readiness-refusal.txt"; fi
lab list > "$E/kimi-live-herdr-inventory.json" 2>&1 || true
cat "$E/kimi-live-herdr-spawn.txt"
