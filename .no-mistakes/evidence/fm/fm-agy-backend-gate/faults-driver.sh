#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=/Users/eduardopicazo/.no-mistakes/evidence/01M653BBWZB0BAJGVK9G6EYEZE
BASE="$ROOT/.test-agy/faults"
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

tmux new-session -d -s firstmate -x 120 -y 40
export TMUX="$(tmux display-message -p '#{socket_path},#{pid},0')"
echo 'SCENARIO: unsupported terminal backends refuse before allocation'
for backend in zellij cmux paseo; do
  brief "agy-$backend" no-launch
  if spawn "agy-$backend" "$backend"; then exit 1; fi
  test ! -e "$FM_HOME/state/agy-$backend.meta"
  test ! -d "$TREEHOUSE_ROOT"
done
# Inject one failed transport operation, keeping the real product and private
# tmux server running. No harness or product command is simulated.
cat > "$BASE/shim/tmux" <<SH
#!/usr/bin/env bash
case "\${FM_LIVE_FAULT:-}" in
  cd)
    if [ "\${1:-}" = send-keys ]; then
      for arg in "\$@"; do
        case "\$arg" in 'cd -- '*) echo 'INJECTED: cwd transport failure' >&2; exit 1 ;; esac
      done
    fi ;;
  literal|enter|signal)
    if [ "\${1:-}" = send-keys ]; then
      for arg in "\$@"; do
        case "\$arg" in '. '*'/launch.'*'.sh'*)
          touch '$BASE/launch-seen'
          if [ "\$FM_LIVE_FAULT" = literal ]; then echo 'INJECTED: launch-text transport failure' >&2; exit 1; fi ;;
        esac
      done
      if [ "\$FM_LIVE_FAULT" = enter ] && [ -f '$BASE/launch-seen' ] && [ "\${*: -1}" = Enter ]; then
        echo 'INJECTED: launch-submit transport failure' >&2; exit 1
      fi
    fi ;;
esac
exec '$REAL_TMUX' -f /dev/null -L '$SOCKET' "\$@"
SH
chmod +x "$BASE/shim/tmux"
echo 'SCENARIO: pre-publication cwd failure returns its durable lease and closes endpoint'
brief agy-unpublished no-agent
if FM_LIVE_FAULT=cd spawn agy-unpublished tmux; then exit 1; fi
test ! -e "$FM_HOME/state/agy-unpublished.meta"
! tmux list-windows -a -F '#{window_name}' | grep -Fxq fm-agy-unpublished
NEXT=$(cd "$PROJECT" && treehouse get --lease --lease-holder cleanup-probe --no-fetch)
test ! -e "$(dirname "$NEXT")/.fm-slot-owner"
echo "Returned unpublished slot is allocatable: $NEXT"
(cd "$PROJECT" && treehouse status --json)
(cd "$PROJECT" && treehouse return "$NEXT" --if-lease-holder cleanup-probe --force)
for mode in literal enter; do
  echo "SCENARIO: post-publication $mode delivery failure retains a teardown-resolvable record"
  [ ! -e "$BASE/launch-seen" ] || rm "$BASE/launch-seen"
  ID="agy-fail-$mode"
  brief "$ID" no-agent
  if FM_LIVE_FAULT="$mode" spawn "$ID" tmux; then exit 1; fi
  test -f "$FM_HOME/state/$ID.meta"
  WT=$(sed -n 's/^worktree=//p' "$FM_HOME/state/$ID.meta")
  test -d "$WT"
  echo "Kept $ID worktree=$WT"
  tmux send-keys -t "firstmate:fm-$ID" C-c
  retire "$ID"
done
echo 'SCENARIO: termination during readiness retains published task'
[ ! -e "$BASE/launch-seen" ] || rm "$BASE/launch-seen"
brief agy-signal initial
FM_LIVE_FAULT=signal FM_AGY_POLL_INTERVAL=10 "$ROOT/bin/fm-spawn.sh" agy-signal "$PROJECT" --scout --harness agy --model gemini-3.8-flash-low --effort low --backend tmux &
SPAWN_PID=$!
for ((i=0;i<600;i++)); do
  if [ -f "$BASE/launch-seen" ] && [ -f "$FM_HOME/state/agy-signal.meta" ]; then break; fi
  sleep 0.1
done
test -f "$BASE/launch-seen"
sleep 1
kill -TERM "$SPAWN_PID"
rc=0
wait "$SPAWN_PID" || rc=$?
test "$rc" -ne 0
test -f "$FM_HOME/state/agy-signal.meta"
echo "Signal exit=$rc; task record preserved"
retire agy-signal
echo 'PASS: pre-publication cleanup and post-publication delivery/signal retention'
