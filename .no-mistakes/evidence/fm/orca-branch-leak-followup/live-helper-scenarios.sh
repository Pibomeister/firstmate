#!/usr/bin/env bash
# Drives fm_backend_orca_safe_delete_created_branch (bin/fm-backend.sh) against real disposable git repos.
set -u
BACKEND=$1
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-orca-live.XXXXXX"); trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
q() { git "$@" >/dev/null 2>&1; }
fresh() {  # new project with origin remote and origin/HEAD -> main
  rm -rf "$T/p" "$T/r.git" "$T/wt"
  q init -q --bare "$T/r.git" && q init -q -b main "$T/p"
  q -C "$T/p" commit -q --allow-empty -m base && q -C "$T/p" remote add origin "$T/r.git"
  q -C "$T/p" push -q origin main && q -C "$T/p" remote set-head origin main
}
run() {  # <label> <expect kept|deleted> <branch> <base>
  local out rc state
  out=$(bash -c '. "$1"; fm_backend_orca_safe_delete_created_branch "$2" "$3" "$4"' _ "$BACKEND" "${REPO:-$T/p}" "$3" "$4" 2>&1); rc=$?
  if git -C "$T/p" show-ref --verify --quiet "refs/heads/$3"; then state=kept; else state=deleted; fi
  printf '%-58s rc=%s branch=%-7s expect=%-7s %s | %s\n' "$1" "$rc" "$state" "$2" "$([ "$state" = "$2" ] && echo PASS || echo FAIL)" "${out:-<no output>}"
}
echo "== git $(git --version | cut -d' ' -f3), helper from $BACKEND"

fresh; q -C "$T/p" branch Pibomeister/fm-a main
run "1 pushed-at-base tip contained by origin/main" deleted Pibomeister/fm-a ""

fresh; q -C "$T/p" switch -q -c Pibomeister/fm-b; q -C "$T/p" commit -q --allow-empty -m w; q -C "$T/p" push -q origin Pibomeister/fm-b; q -C "$T/p" switch -q main
run "2 pushed work contained by origin/Pibomeister/fm-b" deleted Pibomeister/fm-b ""

fresh; q -C "$T/p" switch -q -c Pibomeister/fm-c; q -C "$T/p" commit -q --allow-empty -m unpushed; q -C "$T/p" branch keeper; q -C "$T/p" switch -q main
run "3 unpushed work, only a LOCAL branch contains it" kept Pibomeister/fm-c ""

fresh; q -C "$T/p" worktree add -q -b Pibomeister/fm-d "$T/wt" main; q -C "$T/wt" commit -q --allow-empty -m unpushed; q -C "$T/wt" checkout -q --detach
echo "   (worktree HEAD $(git -C "$T/wt" rev-parse --short HEAD) == branch tip $(git -C "$T/p" rev-parse --short Pibomeister/fm-d))"
REPO=$T/wt run "4 teardown shape: worktree detached AT unpushed tip, no upstream" kept Pibomeister/fm-d ""; unset REPO

fresh; q -C "$T/p" switch -q -c dev; q -C "$T/p" push -q origin dev; q -C "$T/p" switch -q main
run "5 recorded base branch 'dev', remote-contained" kept dev dev
run "5b same branch, no base recorded (counterfactual)" deleted dev ""

fresh
q -C "$T/p" switch -q -c side; q -C "$T/p" push -q origin side
run "6 default branch main, remote-contained" kept main ""

fresh; q -C "$T/p" branch Pibomeister/fm-e main; q -C "$T/p" worktree add -q "$T/wt" Pibomeister/fm-e
run "7 checked out in another worktree, remote-contained" kept Pibomeister/fm-e ""

fresh; q -C "$T/p" branch Pibomeister/fm-f main; q -C "$T/p" worktree add -q "$T/wt" Pibomeister/fm-f
printf 'x\n' > "$T/wt/f"; q -C "$T/wt" add f; q -C "$T/wt" commit -q -m a; q -C "$T/wt" push -q origin HEAD:refs/heads/Pibomeister/fm-f
q -C "$T/wt" switch -q -c up main; printf 'y\n' > "$T/wt/f"; q -C "$T/wt" add f; q -C "$T/wt" commit -q -m b; q -C "$T/wt" switch -q Pibomeister/fm-f
git -C "$T/wt" rebase up >/dev/null 2>&1
echo "   (rebase state in worktree: HEAD=$(git -C "$T/wt" rev-parse --abbrev-ref HEAD), head-name=$(cat "$(git -C "$T/wt" rev-parse --git-dir)"/rebase-merge/head-name 2>/dev/null))"
echo "   (git branch -d says: $(git -C "$T/p" branch -d Pibomeister/fm-f 2>&1 | head -1))"
run "8 remote-contained branch mid-rebase (detached HEAD)" kept Pibomeister/fm-f ""
q -C "$T/wt" rebase --abort
run "8b after rebase --abort (branch checked out again)" kept Pibomeister/fm-f ""
q -C "$T/wt" checkout -q --detach
run "8c same branch, worktree detached, no rebase (counterfactual)" deleted Pibomeister/fm-f ""

fresh; rm -rf "$T/p/.git/refs/remotes/origin/HEAD"; q -C "$T/p" remote remove origin; q -C "$T/p" branch -m main trunk
q -C "$T/p" remote add origin "$T/r.git"; q -C "$T/p" fetch -q origin; q -C "$T/p" remote set-head origin -d; q -C "$T/p" branch Pibomeister/fm-g trunk
run "9 unresolved default (no origin/HEAD, no main/master)" kept Pibomeister/fm-g ""
q -C "$T/p" branch main trunk
run "9b same, local main now resolves default (counterfactual)" deleted Pibomeister/fm-g ""
: 

fresh; q -C "$T/p" update-ref refs/heads/--delete main; echo "   (refs/heads/--delete exists: $(git -C "$T/p" show-ref --verify --quiet refs/heads/--delete && echo yes || echo no))"
run "10 invalid branch name '--delete'" kept --delete ""
