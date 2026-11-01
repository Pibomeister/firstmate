export CODEX_HOME="$BASE/codex-home"
mkdir -p "$CODEX_HOME"
cp "$ORIGINAL_HOME/.codex/auth.json" "$CODEX_HOME/auth.json"
echo 'SCENARIO: legacy Codex relaunch without a slot-owner claim ignores unrelated project allocation lock'
true # private server already started
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
