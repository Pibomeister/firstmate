#!/usr/bin/env bash
# Opt-in live agy worker guard through the real spawn path on tmux: trust
# pre-registration, the launch readiness gate, a kept record after a forced
# readiness failure, fm-control relaunch of that record, and teardown.
# Opt-in because it submits real prompts (no echo provider exists for agy).
set -u

# shellcheck source=tests/lib.sh
. "$PWD/tests/lib.sh"

fm_live_gate opt-in FM_AGY_SPAWN_LIVE codex tmux treehouse

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
ORIGINAL_HOME=$HOME
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
  "$ROOT/bin/fm-teardown.sh" "$1" || fail "agy scout teardown failed for $1"
  [ ! -e "$HOME_DIR/state/$1.meta" ] || fail "agy task metadata survived teardown for $1"
}

EVIDENCE=/Users/eduardopicazo/.no-mistakes/evidence/01M653BBWZB0BAJGVK9G6EYEZE
export CODEX_HOME="$LAB/codex-home"
mkdir -p "$CODEX_HOME"
[ ! -f "$ORIGINAL_HOME/.codex/auth.json" ] || cp "$ORIGINAL_HOME/.codex/auth.json" "$CODEX_HOME/auth.json"
ID=legacy-codex
write_brief "$ID"
FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJECT" --scout --harness codex --backend tmux || fail 'initial Codex spawn failed'
TMUX="$(tmux display-message -p '#{socket_path},#{pid},0')"
export TMUX
WT=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$ID.meta")
wait_for 'initial Codex report' "grep -Fq '80235' '$HOME_DIR/data/$ID/report.md'"
cp "$HOME_DIR/data/$ID/report.md" "$EVIDENCE/legacy-codex-initial-report.txt"
tmux kill-window -t "firstmate:fm-$ID"
rm "$(dirname "$WT")/.fm-slot-owner"
. "$ROOT/bin/fm-wake-lib.sh"
lock=$(fm_treehouse_project_lock_path "$PROJECT")
fm_lock_try_acquire "$lock" || fail 'could not hold project lock'
TOKEN="legacy-codex-relaunch-$$"
"$ROOT/bin/fm-control.sh" "$ID" relaunch --note "Overwrite the report at $HOME_DIR/data/$ID/report.md with exactly: LEGACY_RELAUNCH $TOKEN 80235 $WT. Then stop and wait." || fail 'legacy Codex control relaunch refused without an owner claim'
wait_for 'fresh Codex recovery report' "grep -Fxq 'LEGACY_RELAUNCH $TOKEN 80235 $WT' '$HOME_DIR/data/$ID/report.md'"
cp "$HOME_DIR/data/$ID/report.md" "$EVIDENCE/legacy-codex-relaunch-report.txt"
[ "$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$ID.meta")" = "$WT" ] || fail 'legacy control relaunch changed checkout'
printf 'Real Codex control relaunch preserved the checkout without an owner claim while the project lock was held.\n'
tmux kill-window -t "firstmate:fm-$ID"
"$ROOT/bin/fm-spawn.sh" "$ID" --relaunch --harness codex || fail 'legacy direct relaunch refused without owner claim'
[ "$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$ID.meta")" = "$WT" ] || fail 'legacy direct relaunch changed checkout'
printf 'Real direct Codex relaunch also accepted the same legacy record under the held project lock.\n'
fm_lock_release "$lock"
retire "$ID"
