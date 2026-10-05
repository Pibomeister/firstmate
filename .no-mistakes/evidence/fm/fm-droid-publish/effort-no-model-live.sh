#!/usr/bin/env bash
# Live: fm-spawn --harness droid --effort high (no --model) must keep the request
# in metadata but write no reasoningEffort/model into Droid's runtime settings.
set -u
ROOT=$1; export FM_GATE_REFUSE_BYPASS=1
REAL_TMUX=$(command -v tmux); SOCKET=fm-droid-effort-$$
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-droid-effort.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
ID=droid-effort; HOME_DIR="$LAB/home"; PROJECT="$HOME_DIR/projects/scratch"
export FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" TREEHOUSE_ROOT="$LAB/pool"
mkdir -p "$LAB/shim" "$PROJECT" "$HOME_DIR/data/$ID" "$HOME_DIR/state" "$HOME_DIR/config" "$LAB/pool"
printf '#!/usr/bin/env bash\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" >"$LAB/shim/tmux"; chmod +x "$LAB/shim/tmux"
export PATH="$LAB/shim:$PATH"
git -C "$PROJECT" init -q; git -C "$PROJECT" -c user.name=s -c user.email=s@example.invalid commit --allow-empty -qm init
printf '# Task\nReply DONE and stop. Do not edit files.\n' >"$HOME_DIR/data/$ID/brief.md"
echo '$ fm-spawn.sh droid-effort <project> --scout --harness droid --effort high --backend tmux'
FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJECT" --scout --harness droid --effort high --backend tmux 2>&1
echo "--- task metadata (model/effort lines)"; grep -E '^(harness|model|effort)=' "$HOME_DIR/state/$ID.meta"
echo "--- Droid runtime settings keys"; jq -c 'keys' "$HOME_DIR/state/$ID.droid-settings.json"
echo "--- reasoningEffort / model in settings:"; jq -c '{reasoningEffort, model}' "$HOME_DIR/state/$ID.droid-settings.json"
sleep 8; echo "--- Droid header"; tmux capture-pane -p -t firstmate:fm-$ID | grep -E 'Auto|·' | tail -1
"$ROOT/bin/fm-control.sh" "$ID" exit 2>&1 | tail -1
"$ROOT/bin/fm-captain-hold.sh" complete "$ID" --none 2>&1 | tail -2
"$ROOT/bin/fm-teardown.sh" "$ID" 2>&1 | tail -4; echo "teardown exit=${PIPESTATUS[0]}"
"$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1; chmod -R u+w "$LAB"; rm -rf "$LAB"
