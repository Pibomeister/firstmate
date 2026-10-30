#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=/Users/eduardopicazo/.no-mistakes/evidence/01M653BBWZB0BAJGVK9G6EYEZE
BASE="$ROOT/.test-agy/legacy"
mkdir -p "$BASE"
ORIGINAL_HOME=$HOME
REAL_TMUX=$(command -v tmux)
REAL_HERDR=$(command -v herdr)
REAL_TREEHOUSE=$(command -v treehouse)
SOCKET="fm-lab-agy-$$"
export TMPDIR="$ROOT/.test-agy/tmp"
export FM_HERDR_LAB_STATE_DIR="$BASE/herdr-lab"
export HERDR_CONFIG_PATH="$BASE/herdr/config.toml"
SESSION=
cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  if [ -n "$SESSION" ]; then "$ROOT/bin/fm-herdr-lab.sh" teardown "$SESSION"; fi
  chmod -R u+w "$BASE" 2>/dev/null || true
  rm -r "$BASE"
}
trap cleanup EXIT
bin/fm-lab-home.sh create "$BASE/home"
export FM_HOME="$BASE/home" FM_ROOT_OVERRIDE="$ROOT"
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE
export HOME="$BASE/agent-home" TREEHOUSE_ROOT="$BASE/caller-pool"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME='AGY lab' GIT_AUTHOR_EMAIL='lab@example.invalid' GIT_COMMITTER_NAME='AGY lab' GIT_COMMITTER_EMAIL='lab@example.invalid'
mkdir -p "$HOME" "$BASE/shim" "$FM_HOME/projects/scratch" "$BASE/herdr"
export CODEX_HOME="$BASE/codex-home"
mkdir -p "$CODEX_HOME"
test -f "$ORIGINAL_HOME/.codex/auth.json"
cp "$ORIGINAL_HOME/.codex/auth.json" "$CODEX_HOME/auth.json"
cat > "$BASE/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -f /dev/null -L "$SOCKET" "\$@"
SH
cat > "$BASE/shim/herdr" <<SH
#!/usr/bin/env bash
exec "$ROOT/bin/fm-herdr-lab.sh" run "\${HERDR_SESSION:?}" "\$@"
SH
# The Herdr helper must see the real executable, not its own routing shim.
# Herdr calls already carry an explicit session in the product adapter.
rm "$BASE/shim/herdr"
chmod +x "$BASE/shim/tmux"
export PATH="$BASE/shim:$PATH" FM_SPAWN_NO_GUARD=1 FM_AGY_READY_POLLS=240
PROJECT="$FM_HOME/projects/scratch"
git -C "$PROJECT" init -q
git -C "$PROJECT" commit --allow-empty -qm 'Disposable AGY lab'
brief() {
  mkdir -p "$FM_HOME/data/$1"
  cat > "$FM_HOME/data/$1/brief.md" <<EOF
# Current worker role contract
You are a crewmate worker managed by Firstmate, not a supervisor.
Do this small task yourself. Do not delegate, commit, push, or publish.
# Task
Add 12345 and 67890. Write exactly one line to $FM_HOME/data/$1/report.md:
BRIEF_RECEIVED $2 <computed sum> <actual current working directory>
Overwrite any old report. Then stop and wait.
EOF
}
spawn() { "$ROOT/bin/fm-spawn.sh" "$1" "$PROJECT" --scout --harness agy --model gemini-3.8-flash-low --effort low --backend "$2"; }
wait_report() {
  for ((i=0;i<240;i++)); do
    if grep -Fxq "BRIEF_RECEIVED $2 80235 $3" "$FM_HOME/data/$1/report.md" 2>/dev/null; then
      cat "$FM_HOME/data/$1/report.md"; return 0
    fi
    sleep 0.5
  done
  echo 'FAIL: report did not match fresh token, sum and cwd'; return 1
}
retire() {
  "$ROOT/bin/fm-captain-hold.sh" complete "$1" --none
  "$ROOT/bin/fm-teardown.sh" "$1"
  test ! -e "$FM_HOME/state/$1.meta"
}

echo 'SCENARIO: legacy Codex relaunch without a slot-owner claim ignores unrelated project allocation lock'
tmux new-session -d -s firstmate -x 120 -y 40
export TMUX="$(tmux display-message -p '#{socket_path},#{pid},0')"
brief legacy-codex "legacy-initial-$$"
"$ROOT/bin/fm-spawn.sh" legacy-codex "$PROJECT" --scout --harness codex --backend tmux
WT=$(sed -n 's/^worktree=//p' "$FM_HOME/state/legacy-codex.meta")
wait_report legacy-codex "legacy-initial-$$" "$WT"
tmux kill-window -t firstmate:fm-legacy-codex
rm "$(dirname "$WT")/.fm-slot-owner"
. "$ROOT/bin/fm-wake-lib.sh"
LOCK=$(fm_treehouse_project_lock_path "$PROJECT")
fm_lock_try_acquire "$LOCK"
TOKEN="legacy-relaunch-$$-$RANDOM"
"$ROOT/bin/fm-control.sh" legacy-codex relaunch --note "Overwrite the report at $FM_HOME/data/legacy-codex/report.md with exactly: BRIEF_RECEIVED $TOKEN 80235 <your actual current working directory>. Then stop and wait."
wait_report legacy-codex "$TOKEN" "$WT"
fm_lock_release "$LOCK"
retire legacy-codex
echo 'PASS: legacy Codex control relaunch processes a new brief without a claim despite allocation lock contention'
