#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=/Users/eduardopicazo/.no-mistakes/evidence/01M653BBWZB0BAJGVK9G6EYEZE
BASE="$ROOT/.test-agy/live"
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
mkdir -p "$HOME/.gemini/antigravity-cli"
for item in antigravity-oauth-token settings.json installation_id jetski_state.pbtxt; do
  if [ -f "$ORIGINAL_HOME/.gemini/antigravity-cli/$item" ]; then
    cp "$ORIGINAL_HOME/.gemini/antigravity-cli/$item" "$HOME/.gemini/antigravity-cli/$item"
  fi
done
mkdir -p "$HOME/.gemini/antigravity-cli/cache"
cp "$ORIGINAL_HOME/.gemini/antigravity-cli/cache/onboarding.json" "$HOME/.gemini/antigravity-cli/cache/onboarding.json"
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
echo 'SCENARIO: unsupported Orca backend refuses without task or checkout'
brief agy-orca never
if spawn agy-orca orca; then exit 1; fi
test ! -e "$FM_HOME/state/agy-orca.meta"
test ! -d "$TREEHOUSE_ROOT"
echo 'PASS: refusal before allocation'
tmux new-session -d -s firstmate -x 120 -y 40
tmux send-keys -t firstmate 'printf "LAB_SHELL_HOME=%s\n" "$HOME"' Enter
echo 'SCENARIO: real tmux AGY receives brief'
brief agy-tmux "fresh-$$"
spawn agy-tmux tmux
export TMUX="$(tmux display-message -p '#{socket_path},#{pid},0')"
WT=$(sed -n 's/^worktree=//p' "$FM_HOME/state/agy-tmux.meta")
wait_report agy-tmux "fresh-$$" "$WT"
tmux capture-pane -p -t fm-agy-tmux > "$EVIDENCE/tmux-pane.txt" || true
echo 'SCENARIO: Treehouse 2.0.1 refuses before fresh endpoint creation and before stopping an existing AGY worker'
brief agy-old-treehouse no-launch
BEFORE=$(tmux list-windows -a -F '#{window_id}')
if PATH="$ROOT/.test-agy/treehouse-2:$PATH" spawn agy-old-treehouse tmux; then exit 1; fi
test ! -e "$FM_HOME/state/agy-old-treehouse.meta"
test "$(tmux list-windows -a -F '#{window_id}')" = "$BEFORE"
PID_BEFORE=$(tmux list-panes -t firstmate:fm-agy-tmux -F '#{pane_pid}')
if PATH="$ROOT/.test-agy/treehouse-2:$PATH" "$ROOT/bin/fm-control.sh" agy-tmux relaunch --note 'Capability guard must preserve this running worker'; then exit 1; fi
test "$(tmux list-panes -t firstmate:fm-agy-tmux -F '#{pane_pid}')" = "$PID_BEFORE"
kill -0 "$PID_BEFORE"
echo "PASS: old Treehouse preflight kept existing pane process $PID_BEFORE and created no endpoint"
retire agy-tmux
echo 'SCENARIO: failed readiness keeps record and lease, prevents steal, then relaunch executes fresh note'
brief agy-recover initial
if FM_AGY_READY_POLLS=1 FM_AGY_POLL_INTERVAL=0 spawn agy-recover tmux; then echo 'FAIL: expected readiness timeout'; exit 1; fi
test -f "$FM_HOME/state/agy-recover.meta"
WT=$(sed -n 's/^worktree=//p' "$FM_HOME/state/agy-recover.meta")
cat "$FM_HOME/state/agy-recover.status"
cat "$(dirname "$WT")/.fm-slot-owner"
(cd "$PROJECT" && treehouse status --json)
SECOND=$(cd "$PROJECT" && treehouse get --lease --lease-holder adversary --no-fetch)
test "$SECOND" != "$WT"
echo "Second allocation=$SECOND; preserved worktree=$WT"
(cd "$PROJECT" && treehouse return "$SECOND" --if-lease-holder adversary --force)
TOKEN="relaunch-$$-$RANDOM"
"$ROOT/bin/fm-control.sh" agy-recover relaunch --note "Overwrite the report at $FM_HOME/data/agy-recover/report.md with exactly: BRIEF_RECEIVED $TOKEN 80235 <your actual current working directory>. Then stop and wait."
test "$(sed -n 's/^worktree=//p' "$FM_HOME/state/agy-recover.meta")" = "$WT"
wait_report agy-recover "$TOKEN" "$WT"
retire agy-recover
echo 'PASS: real tmux launch and same-checkout recovery'
