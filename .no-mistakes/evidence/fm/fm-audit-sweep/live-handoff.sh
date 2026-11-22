#!/usr/bin/env bash
set -eu
ROOT=$PWD
LAB=$ROOT/.test-phase-tmp/handoff-manual
bash bin/fm-lab-home.sh create "$LAB"
mkdir "$LAB/faultbin"
printf '# Synthetic handoff document\nNo outstanding synthetic orders.\n' > "$LAB/data/handoff.md"
for t in jq tmux codex; do ln -s "$(command -v "$t")" "$LAB/faultbin/$t"; done
cat > "$LAB/faultbin/rm" <<'EOF'
#!/bin/bash
for arg; do
  case "$arg" in
    */.handoff-launch-failed)
      if [ ! -e "$FM_HOME/state/clear-interrupted" ]; then
        touch "$FM_HOME/state/clear-interrupted"
        kill -TERM "$PPID"
      fi ;;
  esac
done
exec /bin/rm "$@"
EOF
chmod +x "$LAB/faultbin/rm"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
export FM_HOME=$LAB
bash bin/fm-lock.sh
printf 'at=1 pid=1 nonce=none attempt=0 reason=error\n' > "$LAB/state/.handoff-launch-failed"
rc=0
PATH=$LAB/faultbin:/usr/bin:/bin bash bin/fm-handoff-launch.sh --harness codex "$LAB/data/handoff.md" || rc=$?
printf 'Launcher exit after record-clear SIGTERM: %s\n' "$rc"
[ "$rc" -ne 0 ]
[ -f "$LAB/state/clear-interrupted" ]
cat "$LAB/state/.handoff-launch-failed"
grep -q 'nonce=none attempt=0 reason=interrupted$' "$LAB/state/.handoff-launch-failed"
printf 'RESULT: interruption at record removal leaves this launch failure receipt for the surviving owner.\n'
