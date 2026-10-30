#!/usr/bin/env bash
set -eu
. "$PWD/tests/lib.sh"
ORIGINAL_HOME=$HOME
ORIGINAL_PATH=$PATH
REAL_HERDR=$(command -v herdr)
SESSION=fm-lab-agy-mismatch-01m653
EVIDENCE=/Users/eduardopicazo/.no-mistakes/evidence/01M653BBWZB0BAJGVK9G6EYEZE
mkdir -p "$ROOT/.test-tmp"
LAB=$(mktemp -d "$ROOT/.test-tmp/agy-herdr.XXXXXX")
export FM_HERDR_LAB_STATE_DIR="$ROOT/.test-tmp/herdr-state"
cleanup() {
  HOME="$ORIGINAL_HOME" PATH="$ORIGINAL_PATH" "$ROOT/bin/fm-herdr-lab.sh" teardown "$SESSION" >> "$EVIDENCE/herdr-lab.txt" 2>&1 || return 1
  rm -rf "$LAB"
}
trap cleanup EXIT
HOME="$ORIGINAL_HOME" "$ROOT/bin/fm-herdr-lab.sh" provision "$SESSION"
mkdir -p "$LAB/agy-home" "$LAB/shim"
cp -R "$ORIGINAL_HOME/.gemini" "$LAB/agy-home/.gemini"
"$ROOT/bin/fm-lab-home.sh" create "$LAB/home" >/dev/null
export LAB ORIGINAL_HOME ORIGINAL_PATH REAL_HERDR SESSION ROOT
cat > "$LAB/shim/herdr" <<'WRAPPER'
#!/usr/bin/env bash
set -eu
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --session) [ "$2" = "$SESSION" ] || exit 81; shift 2 ;;
    --session=*) [ "${1#*=}" = "$SESSION" ] || exit 82; shift ;;
    *) args+=("$1"); shift ;;
  esac
done
export HOME="$ORIGINAL_HOME" PATH="$ORIGINAL_PATH"
case "${args[0]:-}" in --version|--help) exec "$REAL_HERDR" "${args[@]}" ;; esac
if { [ "${args[0]:-}" = workspace ] || [ "${args[0]:-}" = tab ]; } && [ "${args[1]:-}" = create ]; then
  args+=(--env "HOME=$LAB/agy-home" --env "ZDOTDIR=$LAB/agy-home" --env "TREEHOUSE_ROOT=$LAB/worker-pool" --env "PATH=$LAB/shim:$ORIGINAL_PATH" --env "GIT_CONFIG_GLOBAL=/dev/null" --env "GIT_CONFIG_NOSYSTEM=1")
fi
printf '%s\n' "${args[*]}" >> "$LAB/herdr.calls"
exec "$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" "${args[@]}"
WRAPPER
chmod +x "$LAB/shim/herdr"
export HOME="$LAB/agy-home" FM_HOME="$LAB/home" TREEHOUSE_ROOT="$LAB/pool" PATH="$LAB/shim:$PATH" HERDR_SESSION="$SESSION"
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_ROOT_OVERRIDE TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH
PROJECT="$FM_HOME/projects/scratch"
mkdir -p "$PROJECT"
git -C "$PROJECT" init -q
git -C "$PROJECT" -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm fixture
id=agy-herdr-live
mkdir -p "$FM_HOME/data/$id"
cat > "$FM_HOME/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Verify the AGY launch brief on Herdr in an isolated lab.
## Firstmate spec
Add 12345 and 67890. Write exactly one line to $FM_HOME/data/$id/report.md:
BRIEF_RECEIVED herdr-gate <computed sum> <actual current working directory>
Then stop and wait. Do not commit, push, or publish.
EOF
rc=0
FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$id" "$PROJECT" --scout --harness agy --model gemini-3.8-flash-low --effort low --backend herdr > "$LAB/output" 2>&1 || rc=$?
printf 'spawn_exit=%s\n' "$rc"
cat "$LAB/output"
printf 'task_record_present=%s\n' "$([ -f "$FM_HOME/state/$id.meta" ] && echo true || echo false)"
rc=0
"$ROOT/bin/fm-control.sh" "$id" relaunch --note 'Recover after Treehouse custody failure' > "$LAB/recovery-output" 2>&1 || rc=$?
printf 'supported_relaunch_exit=%s\n' "$rc"
cat "$LAB/recovery-output"
cp "$LAB/herdr.calls" "$EVIDENCE/herdr-mismatch-calls.txt"
rg --files --hidden --no-ignore "$LAB/worker-pool" -g .fm-slot-owner | while IFS= read -r claim; do
  printf 'remaining_claim=%s\n' "$claim"
  cat "$claim"
done
