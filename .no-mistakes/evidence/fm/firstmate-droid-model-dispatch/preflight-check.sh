#!/bin/bash
set -u
ROOT=$PWD
EVID=/Users/eduardopicazo/.no-mistakes/evidence/01M5WJCS392N92QV6H2V3AMEH1
BASE="$ROOT/.test-droid-validation"
export HOME="$BASE/home" TMPDIR="$BASE/tmp" FACTORY_DROID_AUTO_UPDATE_ENABLED=false
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TASK_ID TASKS_AXI_FILE TASKS_AXI_BACKEND TMUX TMUX_PANE FACTORY_HOME_OVERRIDE
export FM_HOME="$BASE/preflight-lab"
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME" >"$EVID/lab-create.txt" || exit
trap 'rm -rf "$FM_HOME"' EXIT
project="$FM_HOME/projects/preflight"
mkdir -p "$project"
git -C "$project" init -qb main
git -C "$project" -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm init
for kind in invalid timeout; do
 id="droid-test-$kind"
 mkdir -p "$FM_HOME/data/$id"
 cat >"$FM_HOME/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Verify refusal before worker allocation.
## Firstmate spec
This preflight-only brief must never reach a model.
EOF
 if [ "$kind" = invalid ]; then model=definitely-not-a-model; bound=3; else model=claude-opus-5-5; bound=1; fi
 start=$SECONDS
 FM_SPAWN_NO_GUARD=1 FM_DROID_MODEL_PROBE_TIMEOUT="$bound" sandbox-exec -f "$BASE/read-only.sb" "$ROOT/bin/fm-spawn.sh" "$id" "$project" --scout --harness droid --model "$model" --backend tmux >"$EVID/$kind-spawn.txt" 2>&1
 rc=$?
 {
  printf 'model=%s\nconfigured_probe_bound=%s\nspawn_exit=%s\nelapsed_seconds=%s\n' "$model" "$bound" "$rc" "$((SECONDS-start))"
  if [ -e "$FM_HOME/state/$id.meta" ]; then echo task_metadata_created=yes; else echo task_metadata_created=no; fi
  if [ -d "$FM_HOME/state/treehouse-task-claims" ]; then echo slot_claims_created=yes; else echo slot_claims_created=no; fi
  cat "$EVID/$kind-spawn.txt"
 } >"$EVID/$kind-result.txt"
 cat "$EVID/$kind-result.txt"
done
