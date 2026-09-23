#!/usr/bin/env bash
# Live drive: a firstmate primary home that is itself a linked git worktree
# (Orca-workspace shape), before and after writing .fm-primary-home.
set -u
SRC=${1:?source worktree}
LAB=$(mktemp -d /tmp/fm-linked-home-lab.XXXXXX)
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
git init -q -b main "$LAB/firstmate"
git -C "$LAB/firstmate" fetch -q "$SRC" HEAD && git -C "$LAB/firstmate" reset -q --hard FETCH_HEAD
git -C "$LAB/firstmate" worktree add -q -b Pibomeister/toadfish "$LAB/orca/workspaces/firstmate/toadfish"
HOME_DIR="$LAB/orca/workspaces/firstmate/toadfish"
mkdir -p "$HOME_DIR/state"; : > "$HOME_DIR/state/task.meta"   # one live task => supervision needed
FAKEBIN="$LAB/fakebin"; mkdir -p "$FAKEBIN"; ln -s /bin/bash "$FAKEBIN/claude"
# Only the watcher itself is replaced, so no real watcher/fleet is touched.
ARM_STUB='#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf "pending:downtime:lab\n" > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf "stale: lab-win actionable\n"'
printf '%s\n' "$ARM_STUB" > "$HOME_DIR/bin/fm-watch-arm.sh"; chmod +x "$HOME_DIR/bin/fm-watch-arm.sh"
git -C "$HOME_DIR" update-index --assume-unchanged bin/fm-watch-arm.sh

echo "home: $HOME_DIR"
echo "git-dir: $(git -C "$HOME_DIR" rev-parse --git-dir)"
echo "git-common-dir: $(git -C "$HOME_DIR" rev-parse --git-common-dir)"
echo "branch: $(git -C "$HOME_DIR" branch --show-current)"

run_hooks() {
  local label=$1 rc out
  echo; echo "================ $label ================"
  echo "--- SessionStart tangle check: bin/fm-guard.sh"
  out=$(cd "$HOME_DIR" && FM_HOME="$HOME_DIR" bin/fm-guard.sh 2>&1); rc=$?
  printf '%s\n' "$out" | grep -E 'TANGLE|checkout |expected|default branch' || echo "(no tangle banner)"; echo "rc=$rc"
  echo "--- SessionStart tangle check: bin/fm-bootstrap.sh (detect-only) TANGLE line"
  out=$(cd "$HOME_DIR" && FM_HOME="$HOME_DIR" FM_BOOTSTRAP_DETECT_ONLY=1 bin/fm-bootstrap.sh 2>/dev/null | grep '^TANGLE:'); echo "${out:-(no TANGLE line)}"
  echo "--- Claude Stop hook: fm-turnend-guard.sh --claude (exact settings.json command)"
  rm -f "$HOME_DIR/state/.lock"
  out=$(printf '{"session_id":"lab","stop_hook_active":false}\n' | CLAUDE_PROJECT_DIR="$HOME_DIR" FM_HOME="$HOME_DIR" "$FAKEBIN/claude" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      bash -c "[ -z \"\${GROK_AGENT:-}\${GROK_HOOK_EVENT:-}\" ] || exit 0; exec \"\$CLAUDE_PROJECT_DIR\"/bin/fm-turnend-guard.sh --claude"' 2>&1); rc=$?
  printf '%s\n' "$out" | head -4; echo "rc=$rc"
  echo "--- Claude Stop hook: fm-claude-stop-autoarm.sh (asyncRewake, exact settings.json command)"
  rm -f "$HOME_DIR/state/arm-ran" "$HOME_DIR/state/.claude-autoarm"* "$HOME_DIR/state/.watcher-down"
  out=$(printf '{"session_id":"lab","stop_hook_active":false}\n' | CLAUDE_PROJECT_DIR="$HOME_DIR" FM_HOME="$HOME_DIR" "$FAKEBIN/claude" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      bash -c "[ -z \"\${GROK_AGENT:-}\${GROK_HOOK_EVENT:-}\" ] || exit 0; exec \"\$CLAUDE_PROJECT_DIR\"/bin/fm-claude-stop-autoarm.sh"' 2>&1); rc=$?
  printf '%s\n' "$out" | head -4; echo "rc=$rc watcher-arm-invoked=$([ -e "$HOME_DIR/state/arm-ran" ] && echo yes || echo no)"
}

run_hooks "1. UNMARKED linked home on Pibomeister/toadfish (the reported bug)"
( cd "$HOME_DIR" && git branch --show-current > .fm-primary-home )
echo; echo "marker written: $(cat "$HOME_DIR/.fm-primary-home")   git status --short: [$(git -C "$HOME_DIR" status --short | tr '\n' ' ')]"
run_hooks "2. MARKED linked home on its marked branch"
git -C "$HOME_DIR" checkout -q -b feature/stray
run_hooks "3. MARKED home switched to another branch (tangle must still alarm)"
git -C "$HOME_DIR" checkout -q Pibomeister/toadfish
mv "$HOME_DIR/.fm-primary-home" "$LAB/marker"; ln -s "$LAB/marker" "$HOME_DIR/.fm-primary-home"
run_hooks "4. ADVERSARIAL: symlinked marker (must be ignored)"
rm "$HOME_DIR/.fm-primary-home"; printf 'bad branch;rm -rf\n' > "$HOME_DIR/.fm-primary-home"
run_hooks "5. ADVERSARIAL: malformed marker (must be ignored)"
rm "$HOME_DIR/.fm-primary-home"
echo; echo "================ 6. Crewmate task worktree (sibling, never marked) ================"
git -C "$LAB/firstmate" worktree add -q --detach "$LAB/task-wt"
mkdir -p "$LAB/task-wt/state"; : > "$LAB/task-wt/state/task.meta"
out=$(printf '{"session_id":"lab","stop_hook_active":false}\n' | FM_HOME="$LAB/task-wt" "$LAB/task-wt/bin/fm-turnend-guard.sh" --claude 2>&1); echo "turnend rc=$? out=[${out}]"
rm -rf "$LAB"; echo; echo "lab removed: $LAB"
