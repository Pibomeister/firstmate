#!/usr/bin/env bash
# Opt-in live agy worker guard through the real spawn path on tmux: trust
# pre-registration, the launch readiness gate, a kept record after a forced
# readiness failure, fm-control relaunch of that record, and teardown.
# Opt-in because it submits real prompts (no echo provider exists for agy).
set -u

# shellcheck source=tests/lib.sh
. "$PWD/tests/lib.sh"

fm_live_gate opt-in FM_AGY_SPAWN_LIVE agy tmux treehouse

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

REAL_TMUX=$(command -v tmux)
SOCKET="fm-agy-spawn-$$"
mkdir -p "$ROOT/.test-tmp"
LAB=$(mktemp -d "$ROOT/.test-tmp/fm-agy-spawn.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
HOME_DIR="$LAB/home"
PROJECT="$HOME_DIR/projects/scratch"
MODEL=${FM_AGY_LIVE_MODEL:-gemini-3.8-flash-low}

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  chmod -R u+w "$LAB" 2>/dev/null || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup EXIT

# The worker runs under a throwaway HOME holding a copy of ~/.gemini, so trust
# pre-registration writes the copy's store and never the operator's own.
AGY_HOME="$LAB/agy-home"
[ -d "$HOME/.gemini" ] || fail "no ~/.gemini to stage for the throwaway agy HOME"
mkdir -p "$AGY_HOME" "$LAB/shim" "$PROJECT" "$HOME_DIR/state" "$HOME_DIR/config" "$LAB/pool"
cp -R "$HOME/.gemini" "$AGY_HOME/.gemini" || fail "could not stage the throwaway agy credential copy"
[ -f "$HOME/.gitconfig" ] && cp "$HOME/.gitconfig" "$AGY_HOME/.gitconfig"
cat >"$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
export HOME="$AGY_HOME" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" TREEHOUSE_ROOT="$LAB/pool"
PATH="$LAB/shim:$PATH"
export PATH
STORE="$AGY_HOME/.gemini/antigravity-cli/settings.json"

git -C "$PROJECT" init -q || fail "could not initialize the agy smoke repository"
git -C "$PROJECT" -c user.name='Agy Smoke' -c user.email='smoke@example.invalid' \
  commit --allow-empty -qm 'Initialize disposable scout repository' \
  || fail "could not commit the agy smoke repository"

write_brief() {  # <id>
  local id=$1 report="$HOME_DIR/data/$1/report.md"
  mkdir -p "$HOME_DIR/data/$id"
  cat >"$HOME_DIR/data/$id/brief.md" <<EOF
# Current worker role contract
You are a crewmate worker managed by Firstmate, not a supervisor.
Do this bounded smoke task yourself and report through the task report only.

# Task
## Captain's intent
Prove that the agy worker receives its launch brief.

## Firstmate spec
Add 12345 and 67890.
Create a report at the absolute path $report with one line beginning BRIEF_RECEIVED, the sum, and your current working directory, unless the existing report already contains that line.
Then stop and wait.
Do not commit, push, or publish anything.
EOF
}

wait_for() {  # <description> <shell command> [polls]
  local label=$1 command=$2 max=${3:-240} count=0
  while [ "$count" -lt "$max" ]; do
    bash -c "$command" && return 0
    count=$((count + 1))
    sleep 0.5
  done
  fail "$label did not appear within $((max / 2)) seconds"
}

# agy's bare composer row never reads empty, so fm-control refuses to type its
# exit command; teardown closes the task's own window instead.
retire() {  # <id>
  "$ROOT/bin/fm-captain-hold.sh" complete "$1" --none || fail "agy scout completion inventory failed for $1"
  "$ROOT/bin/fm-teardown.sh" "$1" --force || fail "agy scout teardown failed for $1"
  [ ! -e "$HOME_DIR/state/$1.meta" ] || fail "agy task metadata survived teardown for $1"
}

EVIDENCE=/Users/eduardopicazo/.no-mistakes/evidence/01M653BBWZB0BAJGVK9G6EYEZE
export REAL_TMUX SOCKET LAB
cat > "$LAB/shim/tmux" <<'WRAP'
#!/usr/bin/env bash
set -u
launch=0
if [ "${1:-}" = send-keys ]; then
  for arg in "$@"; do
    case "$arg" in
      *--prompt-interactive*) launch=1 ;;
      ". '"*"'")
        file=${arg#". '"}; file=${file%"'"}
        if [ -f "$file" ] && grep -Fq -- --prompt-interactive "$file"; then launch=1; fi
        ;;
    esac
  done
fi
"$REAL_TMUX" -L "$SOCKET" "$@"
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
if [ "$launch" = 1 ]; then
  touch "$LAB/launch-typed"
  [ "${FM_INJECT_FAIL:-}" != literal ] || exit 1
elif [ "${1:-}" = send-keys ] && [ "${!#}" = Enter ] && [ -f "$LAB/launch-typed" ]; then
  touch "$LAB/launch-submitted"
  [ "${FM_INJECT_FAIL:-}" != enter ] || exit 1
fi
exit 0
WRAP
chmod +x "$LAB/shim/tmux"
REAL_TASKS=$(command -v tasks-axi)
export REAL_TASKS
cat > "$LAB/shim/tasks-axi" <<'WRAP'
#!/usr/bin/env bash
if [ "${FM_INJECT_FAIL:-}" = backlog ] && [ "${1:-}" = start ]; then exit 1; fi
exec "$REAL_TASKS" "$@"
WRAP
chmod +x "$LAB/shim/tasks-axi"
mkdir -p "$HOME_DIR/data"
fm_test_tasks_toml "$HOME_DIR/.tasks.toml"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
for mode in literal enter signal backlog; do
  ID="agy-fault-$mode"
  write_brief "$ID"
  (cd "$HOME_DIR" && "$REAL_TASKS" add "$ID" 'AGY fault probe' --kind scout --file "$HOME_DIR/data/backlog.md") >/dev/null
  rm -f "$LAB/launch-typed" "$LAB/launch-submitted"
  rc=0
  if [ "$mode" = signal ]; then
    FM_INJECT_FAIL="$mode" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJECT" --scout --harness agy --model "$MODEL" --effort low --backend tmux > "$LAB/output" 2>&1 &
    spawn_pid=$!
    count=0
    until [ -f "$LAB/launch-submitted" ]; do
      kill -0 "$spawn_pid" 2>/dev/null || break
      count=$((count+1)); [ "$count" -lt 2000 ] || break
      sleep 0.05
    done
    [ -f "$LAB/launch-submitted" ] || fail 'signal probe did not reach launch submission'
    kill -TERM "$spawn_pid"
    wait "$spawn_pid" || rc=$?
  else
    FM_INJECT_FAIL="$mode" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJECT" --scout --harness agy --model "$MODEL" --effort low --backend tmux > "$LAB/output" 2>&1 || rc=$?
  fi
  printf '\nfault=%s exit=%s\n' "$mode" "$rc"
  cat "$LAB/output"
  [ "$rc" -ne 0 ] || fail "fault=$mode did not fail"
  [ -f "$HOME_DIR/state/$ID.meta" ] || fail "fault=$mode lost its task record"
  WT=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$ID.meta")
  [ -d "$WT" ] || fail "fault=$mode lost its checkout"
  cp "$HOME_DIR/state/$ID.meta" "$EVIDENCE/$ID-meta.txt"
  printf 'Preserved task=%s worktree=%s\n' "$ID" "$WT"
  TMUX="$(tmux display-message -p '#{socket_path},#{pid},0')"
  export TMUX
  retire "$ID"
  printf 'Task teardown verified: %s\n' "$ID"
done
