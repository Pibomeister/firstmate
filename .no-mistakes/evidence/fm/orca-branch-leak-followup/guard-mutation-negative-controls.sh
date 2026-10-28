#!/usr/bin/env bash
# Negative controls: revert each guard in a scratch export of the commit and require the focused test to FAIL.
set -u
SRC=$1; REV=$2
S=$(mktemp -d "${TMPDIR:-/tmp}/fm-mut.XXXXXX"); trap 'rm -rf "$S"' EXIT
fresh() { rm -rf "$S/r"; mkdir -p "$S/r"; git -C "$SRC" archive "$REV" | tar -x -C "$S/r"
  git -C "$S/r" init -q && git -C "$S/r" add -A && git -C "$S/r" -c user.name=t -c user.email=t@t commit -qm x
  # keep only the branch-cleanup tests in each focused file
  sed -i '' -E '/^test_[a-z_]+$/{/^test_(teardown_deletes_only_safe_recorded_orca_branch|orca_branch_cleanup_protects_refs_and_races|orca_aborted_spawn_safe_deletes_or_records_its_created_branch)$/!s/^/: /;}' \
    "$S/r/tests/fm-backend-orca.test.sh" "$S/r/tests/fm-spawn-orca-worktree.test.sh"; }
mutate() {  # <label> <file> <perl-substitution> <test-file>
  fresh
  perl -0pi -e "$3" "$S/r/$2"
  if git -C "$S/r" diff --quiet; then printf '%-44s MUTATION-NOT-APPLIED\n' "$1"; return; fi
  local out rc; out=$(cd "$S/r" && bash "$4" 2>&1); rc=$?
  printf '%-44s rc=%s %s  first failure: %s\n' "$1" "$rc" "$([ $rc -ne 0 ] && echo 'TEST FAILS (guard is pinned)' || echo 'TEST STILL GREEN (VACUOUS)')" \
    "$(printf '%s\n' "$out" | grep -m1 -iE 'not ok|fail' | cut -c1-140)"
}
B=bin/fm-backend.sh; TB=tests/fm-backend-orca.test.sh; TS=tests/fm-spawn-orca-worktree.test.sh
fresh; (cd "$S/r" && bash $TB >/dev/null 2>&1 && bash $TS >/dev/null 2>&1) && echo "unmutated baseline: both focused tests GREEN" || echo "unmutated baseline: RED"
mutate "default-branch guard removed"      $B 's/\[ "\$branch" = "\$default" \] \|\| //' $TB
mutate "base-branch guard removed"         $B 's/\{ \[ -n "\$base" \] && \[ "\$branch" = "\$base" \]; \}/false/' $TB
mutate "unresolved-default guard removed"  $B 's/\[ -z "\$default" \] \|\| //' $TB
mutate "checked-out guard removed"         $B 's/printf .%s\\n. "\$listed" \| grep -Fx -- "branch refs\/heads\/\$branch" >\/dev\/null \|\|\n\s*//' $TB
mutate "empty worktree-listing guard removed" $B 's/\[ -z "\$listed" \] \|\| //' $TB
mutate "unresolved common-dir guard removed" $B 's/\[ -z "\$common" \] \|\|\n\s*//' $TB
mutate "rebase-state guard removed"        $B 's/\|\|\n\s*fm_backend_orca_branch_rebasing "\$common" "\$branch"; then/; then/' $TB
mutate "local branch accepted as proof"    $B 's/refs\/remotes 2>/refs\/heads refs\/remotes 2>/' $TB
mutate "teardown stops threading base"     bin/fm-teardown.sh 's/"\$orca_created_branch" "\$BASE_BRANCH" \|\| true/"\$orca_created_branch" "" || true/' $TB
mutate "spawn abort stops threading base"  bin/fm-spawn.sh 's/"\$ORCA_CREATED_BRANCH" "\$BASE_BRANCH" \|\| true/"\$ORCA_CREATED_BRANCH" "" || true/' $TS
mutate "spawn recovery drops base_branch=" bin/fm-spawn.sh 's/\n\s*\[ -z "\$\{BASE_BRANCH:-\}" \] \|\| echo "base_branch=\$BASE_BRANCH"//' $TS
