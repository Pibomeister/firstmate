#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=/Users/eduardopicazo/.no-mistakes/evidence/01M653BBWZB0BAJGVK9G6EYEZE
BASE="$ROOT/.test-agy/herdr"
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
  if [ -n "$SESSION" ]; then HOME="$ORIGINAL_HOME" PATH="${PATH#"$BASE/shim:"}" "$ROOT/bin/fm-herdr-lab.sh" teardown "$SESSION"; fi
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

cat > "$BASE/endpoint-shell" <<SH
#!/usr/bin/env bash
export HOME='$HOME' TREEHOUSE_ROOT='$BASE/endpoint-pool'
exec /bin/bash --noprofile --norc -i
SH
chmod +x "$BASE/endpoint-shell"
cat > "$HERDR_CONFIG_PATH" <<TOML
onboarding = false
[terminal]
default_shell = "$BASE/endpoint-shell"
shell_mode = "non_login"
[update]
version_check = false
manifest_check = false
TOML
echo 'SCENARIO: Herdr caller and endpoint shell use different Treehouse roots'
LAB_NAME=$("$ROOT/bin/fm-herdr-lab.sh" name agy-pool)
HOME="$ORIGINAL_HOME" TREEHOUSE_ROOT="$BASE/endpoint-pool" "$ROOT/bin/fm-herdr-lab.sh" provision "$LAB_NAME"
SESSION=$LAB_NAME
export HERDR_SESSION="$SESSION"
# Route every product Herdr operation through the lab helper. Its own calls use
# the original PATH, avoiding wrapper recursion.
ORIGINAL_PATH=$PATH
cat > "$BASE/shim/herdr" <<SH
#!/usr/bin/env bash
set -eu
args=()
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --session) test "\$2" = '$SESSION'; shift 2 ;;
    --session=*) test "\${1#*=}" = '$SESSION'; shift ;;
    *) args+=("\$1"); shift ;;
  esac
done
if [ "\${args[0]:-}" = --version ]; then exec '$REAL_HERDR' --version; fi
HOME='$ORIGINAL_HOME' PATH='' exec '$ROOT/bin/fm-herdr-lab.sh' run '$SESSION' "\${args[@]}"
SH
# Expand the original tool PATH only after excluding this new wrapper directory.
python3 - "$BASE/shim/herdr" "$ORIGINAL_PATH" "$BASE/shim:" <<'PYS'
import sys
p=sys.argv[1]
s=open(p).read().replace("PATH=''", "PATH='"+sys.argv[2].replace(sys.argv[3], '', 1)+"'")
open(p,'w').write(s)
PYS
chmod +x "$BASE/shim/herdr"
printf 'off\n' > "$FM_HOME/config/herdr-presentation-spaces"
brief agy-herdr initial
if FM_AGY_READY_POLLS=1 FM_AGY_POLL_INTERVAL=0 spawn agy-herdr herdr; then echo 'FAIL: readiness fault did not fire'; exit 1; fi
test -f "$FM_HOME/state/agy-herdr.meta"
WT=$(sed -n 's/^worktree=//p' "$FM_HOME/state/agy-herdr.meta")
case "$WT" in "$BASE/caller-pool/"*) ;; *) echo "FAIL: wrong allocation pool $WT"; exit 1 ;; esac
test ! -d "$BASE/endpoint-pool/.treehouse"
echo "Recorded caller-pool checkout=$WT; endpoint pool is unused"
cat "$FM_HOME/state/agy-herdr.status"
(cd "$PROJECT" && treehouse status --json)
SECOND=$(cd "$PROJECT" && treehouse get --lease --lease-holder second-dispatch --no-fetch)
test "$SECOND" != "$WT"
echo "Second dispatch obtained $SECOND rather than $WT"
(cd "$PROJECT" && treehouse return "$SECOND" --if-lease-holder second-dispatch --force)
TOKEN="herdr-relaunch-$$-$RANDOM"
"$ROOT/bin/fm-control.sh" agy-herdr relaunch --note "Overwrite the report at $FM_HOME/data/agy-herdr/report.md with exactly: BRIEF_RECEIVED $TOKEN 80235 <your actual current working directory>. Then stop and wait."
test "$(sed -n 's/^worktree=//p' "$FM_HOME/state/agy-herdr.meta")" = "$WT"
wait_report agy-herdr "$TOKEN" "$WT"
"$ROOT/bin/fm-peek.sh" agy-herdr > "$EVIDENCE/herdr-pane.txt"
retire agy-herdr
echo 'PASS: Herdr mismatch cannot lose custody and recovery processes a fresh brief in the original checkout'
