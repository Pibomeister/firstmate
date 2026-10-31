#!/usr/bin/env bash
# Behavioral coverage for automatic linked-worktree cleanup.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLEAN="$ROOT/bin/fm-worktree-cleanup.sh"
TMP_ROOT=$(fm_test_tmproot fm-worktree-cleanup)
SECRET='FM_ENV_SECRET_9f3a'
PR_URL='https://github.com/example/repo/pull/7'

make_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/bin"
  printf '%s\n' "$dir"
}

install_gh() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_GH_LOG:?}"
if [ "${FM_TEST_GH_RC:-0}" != 0 ]; then
  exit "$FM_TEST_GH_RC"
fi
cat "${FM_TEST_GH_JSON_FILE:?}"
SH
  chmod +x "$dir/gh"
}

install_failing_lsof() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/lsof" <<'SH'
#!/bin/sh
exit 1
SH
  chmod +x "$dir/lsof"
}

# repo, linked worktree, and branch. The branch commit is the pull-request head
# unless a case adds commits afterward.
make_linked() {
  local dir=$1 branch=$2 repo wt
  repo="$dir/repo"
  wt="$dir/linked"
  fm_git_worktree "$repo" "$wt" "$branch"
  printf '%s\n' "$repo" "$wt"
}

commit_ignore_rules() {
  local repo=$1 wt=$2
  printf '.env\n.work\n.omc\n' > "$repo/.gitignore"
  git -C "$repo" add .gitignore
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'ignore private files'
  git -C "$wt" merge --ff-only --quiet main
}

pr_json() {
  local file=$1 state=$2 head=$3
  printf '[{"number":7,"state":"%s","headRefOid":"%s","url":"%s"}]\n' \
    "$state" "$head" "$PR_URL" > "$file"
}

run_clean() {
  local dir=$1 repo=$2
  shift 2
  PATH="$dir/bin:$PATH" \
    FM_TEST_GH_LOG="$dir/gh.log" \
    FM_TEST_GH_JSON_FILE="$dir/pr.json" \
    FM_TEST_GH_RC="${FM_TEST_GH_RC:-0}" \
    FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$dir/state" \
    FM_PROJECTS_OVERRIDE="$dir/projects" \
    "$CLEAN" "$@" "$repo"
}

begin_case() {
  local name=$1 branch=${2:-feature} pair
  CASE_DIR=$(make_case "$name")
  install_gh "$CASE_DIR/bin"
  pair=$(make_linked "$CASE_DIR" "$branch") || fail "could not create the linked worktree"
  CASE_REPO=$(printf '%s\n' "$pair" | sed -n '1p')
  CASE_WT=$(printf '%s\n' "$pair" | sed -n '2p')
  [ -d "$CASE_REPO" ] || fail "repo was not created"
  [ -d "$CASE_WT" ] || fail "worktree was not created"
}

publish_pr() {
  local state=$1 sha
  sha=$(git -C "$CASE_WT" rev-parse HEAD) || fail "could not read the worktree head"
  pr_json "$CASE_DIR/pr.json" "$state" "$sha"
}

capture_clean() {
  local dir=$1
  shift
  : > "$dir/stderr"
  CAP_OUT=$(run_clean "$dir" "$CASE_REPO" "$@" 2>"$dir/stderr") || fail "cleanup exited nonzero"
  if [ -s "$dir/stderr" ]; then
    if grep -F "$SECRET" "$dir/stderr" >/dev/null; then
      fail "cleanup stderr included private file contents"
    fi
    fail "cleanup wrote to stderr: $(cat "$dir/stderr")"
  fi
}

assert_branch() {
  local repo=$1 branch=$2
  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" \
    || fail "branch $branch was deleted"
}

assert_no_secret() {
  local dir=$1 text=$2 file
  case "$text" in
    *"$SECRET"*) fail "decision output included private file contents" ;;
  esac
  for file in "$dir/state/worktree-cleanup.log" "$dir/stderr" "$dir/gh.log"; do
    [ -f "$file" ] || continue
    if grep -F "$SECRET" "$file" >/dev/null; then
      fail "cleanup record included private file contents"
    fi
  done
  if [ -f "$dir/gh.log" ] && grep -E 'branch -D|--delete' "$dir/gh.log" >/dev/null; then
    fail "pull request lookup asked to delete a branch"
  fi
}

assert_out() {
  local needle=$1
  case "$CAP_OUT" in
    *"$needle"*) ;;
    *) fail "missing [$needle] in decision output: $CAP_OUT" ;;
  esac
}

assert_kept() {
  [ -d "$CASE_WT" ] || fail "worktree was removed"
}

assert_removed() {
  [ ! -e "$CASE_WT" ] || fail "worktree was not removed"
}

add_stale_worktree() {
  local repo=$1 dir=$2 stale
  stale="$dir/stale-marker"
  git -C "$repo" worktree add --quiet -b stale-marker "$stale"
  rm -rf -- "$stale"
  git -C "$repo" worktree list --porcelain | grep -q 'stale-marker' \
    || fail "stale worktree registration was not created"
}

test_merged_pr_removes_worktree_keeps_branch_and_prunes() {
  begin_case merged
  publish_pr MERGED
  add_stale_worktree "$CASE_REPO" "$CASE_DIR"
  capture_clean "$CASE_DIR"
  assert_removed
  assert_branch "$CASE_REPO" feature
  assert_branch "$CASE_REPO" stale-marker
  assert_branch "$CASE_REPO" main
  if git -C "$CASE_REPO" worktree list --porcelain | grep -q 'stale-marker'; then
    fail "stale worktree registration remained after removal"
  fi
  assert_out "remove "
  assert_out "pull request MERGED $PR_URL"
  assert_no_secret "$CASE_DIR" "$CAP_OUT"
  pass "merged pull request removes the worktree, keeps the branch, and prunes"
}

test_closed_pr_removes_worktree_keeps_branch() {
  begin_case closed
  publish_pr CLOSED
  capture_clean "$CASE_DIR"
  assert_removed
  assert_branch "$CASE_REPO" feature
  assert_branch "$CASE_REPO" main
  assert_out "pull request CLOSED $PR_URL"
  assert_no_secret "$CASE_DIR" "$CAP_OUT"
  pass "closed pull request removes the worktree and keeps the branch"
}

test_tracked_changes_are_reported() {
  begin_case tracked
  publish_pr MERGED
  printf 'edit\n' >> "$CASE_WT/README.md"
  capture_clean "$CASE_DIR"
  assert_kept
  assert_branch "$CASE_REPO" feature
  assert_out "uncommitted tracked changes"
  pass "uncommitted tracked changes are reported"
}

test_untracked_files_are_reported() {
  begin_case untracked
  publish_pr MERGED
  printf 'note\n' > "$CASE_WT/notes.txt"
  capture_clean "$CASE_DIR"
  assert_kept
  assert_branch "$CASE_REPO" feature
  assert_out "untracked files"
  pass "non-ignored untracked files are reported"
}

test_ignored_private_files_do_not_block_removal() {
  begin_case ignored
  commit_ignore_rules "$CASE_REPO" "$CASE_WT" || fail "could not commit ignore rules"
  printf '%s\n' "$SECRET" > "$CASE_WT/.env"
  mkdir -p "$CASE_WT/.work" "$CASE_WT/.omc"
  printf '%s\n' "$SECRET" > "$CASE_WT/.work/x"
  printf '%s\n' "$SECRET" > "$CASE_WT/.omc/y"
  publish_pr MERGED
  capture_clean "$CASE_DIR"
  assert_removed
  assert_branch "$CASE_REPO" feature
  assert_no_secret "$CASE_DIR" "$CAP_OUT"
  pass "ignored private files do not block removal"
}

test_dry_run_changes_nothing() {
  begin_case dry
  publish_pr MERGED
  add_stale_worktree "$CASE_REPO" "$CASE_DIR"
  capture_clean "$CASE_DIR" --dry-run
  assert_kept
  assert_branch "$CASE_REPO" feature
  assert_branch "$CASE_REPO" stale-marker
  assert_out "dry-run "
  assert_out "pull request MERGED $PR_URL"
  case "$CAP_OUT" in
    *"remove "*) fail "dry-run recorded a removal" ;;
  esac
  git -C "$CASE_REPO" worktree list --porcelain | grep -q 'stale-marker' \
    || fail "dry-run pruned a stale worktree registration"
  assert_no_secret "$CASE_DIR" "$CAP_OUT"
  pass "dry-run records the removal and changes nothing"
}

test_main_checkout_is_skipped() {
  local main_phys
  begin_case mainkeep
  printf '[]\n' > "$CASE_DIR/pr.json"
  main_phys=$(CDPATH='' cd -- "$CASE_REPO" && pwd -P) || fail "could not resolve the main checkout"
  capture_clean "$CASE_DIR"
  assert_kept
  [ -d "$main_phys" ] || fail "main checkout was removed"
  assert_branch "$CASE_REPO" feature
  assert_branch "$CASE_REPO" main
  assert_out "skip $main_phys main checkout"
  assert_out "no pull request"
  pass "a main checkout is skipped"
}

test_live_process_is_skipped() {
  local pid ready i
  begin_case live
  publish_pr MERGED
  bash -c 'cd "$1" && sleep 120' _ "$CASE_WT" &
  pid=$!
  ready=0
  i=0
  while [ "$i" -lt 25 ]; do
    if lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | grep -F "$CASE_WT" >/dev/null; then
      ready=1
      break
    fi
    sleep 0.1
    i=$((i + 1))
  done
  if [ "$ready" -ne 1 ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "live process was not visible in its worktree"
  fi
  capture_clean "$CASE_DIR"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_kept
  assert_branch "$CASE_REPO" feature
  assert_out "live process"
  pass "a live process keeps the worktree"
}

test_commits_not_on_pr_head_are_reported() {
  local sha
  begin_case ahead
  sha=$(git -C "$CASE_WT" rev-parse HEAD) || fail "could not read the worktree head"
  printf 'later\n' >> "$CASE_WT/README.md"
  git -C "$CASE_WT" add README.md
  git -C "$CASE_WT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm later \
    || fail "could not add a commit past the pull request head"
  pr_json "$CASE_DIR/pr.json" MERGED "$sha"
  capture_clean "$CASE_DIR"
  assert_kept
  assert_branch "$CASE_REPO" feature
  assert_out "commits not on PR head"
  pass "commits that are not on the pull request head are reported"
}

test_open_pr_is_kept() {
  begin_case openpr
  publish_pr OPEN
  capture_clean "$CASE_DIR"
  assert_kept
  assert_branch "$CASE_REPO" feature
  assert_out "pull request is open"
  pass "an open pull request keeps the worktree"
}

test_unknown_process_scan_removes_nothing() {
  begin_case nolsof
  install_failing_lsof "$CASE_DIR/bin"
  publish_pr MERGED
  capture_clean "$CASE_DIR"
  assert_kept
  assert_branch "$CASE_REPO" feature
  assert_out "cannot tell whether a process is using it"
  pass "an unknown process scan removes nothing"
}

test_scan_is_silent_and_logged() {
  local log
  begin_case scanlog
  publish_pr MERGED
  : > "$CASE_DIR/stderr"
  CAP_OUT=$(run_clean "$CASE_DIR" "$CASE_REPO" scan 2>"$CASE_DIR/stderr") || fail "scan exited nonzero"
  [ -z "$CAP_OUT" ] || fail "scan printed a decision: $CAP_OUT"
  [ ! -s "$CASE_DIR/stderr" ] || fail "scan wrote to stderr: $(cat "$CASE_DIR/stderr")"
  [ -f "$CASE_DIR/state/worktree-cleanup.log" ] || fail "scan did not write a log"
  log=$(cat "$CASE_DIR/state/worktree-cleanup.log")
  case "$log" in
    *"remove "*) ;;
    *) fail "scan log has no removal" ;;
  esac
  case "$log" in
    *"pull request MERGED $PR_URL"*) ;;
    *) fail "scan log omitted the pull request" ;;
  esac
  assert_removed
  assert_branch "$CASE_REPO" feature
  assert_no_secret "$CASE_DIR" "$log"
  pass "scan is silent and logs the removal"
}

test_pull_request_lookup_failure_removes_nothing() {
  begin_case ghfail
  publish_pr MERGED
  FM_TEST_GH_RC=1 capture_clean "$CASE_DIR"
  assert_kept
  assert_branch "$CASE_REPO" feature
  assert_out "pull request lookup failed"
  pass "a failed pull request lookup removes nothing"
}

test_locked_worktree_is_not_removed() {
  begin_case locked
  publish_pr MERGED
  git -C "$CASE_REPO" worktree lock "$CASE_WT" || fail "could not lock the worktree"
  capture_clean "$CASE_DIR"
  assert_kept
  assert_branch "$CASE_REPO" feature
  assert_out "worktree is locked"
  pass "a locked worktree is not removed"
}

test_disabled_scan_leaves_the_worktree() {
  begin_case disabled
  publish_pr MERGED
  : > "$CASE_DIR/stderr"
  CAP_OUT=$(FM_WORKTREE_CLEANUP=0 run_clean "$CASE_DIR" "$CASE_REPO" scan 2>"$CASE_DIR/stderr") \
    || fail "disabled scan exited nonzero"
  [ -z "$CAP_OUT" ] || fail "disabled scan printed a decision: $CAP_OUT"
  [ ! -s "$CASE_DIR/stderr" ] || fail "disabled scan wrote to stderr: $(cat "$CASE_DIR/stderr")"
  [ ! -f "$CASE_DIR/state/worktree-cleanup.log" ] || fail "disabled scan wrote a log"
  assert_kept
  assert_branch "$CASE_REPO" feature
  pass "a disabled scan leaves the worktree"
}

fm_test_run \
  test_merged_pr_removes_worktree_keeps_branch_and_prunes \
  test_closed_pr_removes_worktree_keeps_branch \
  test_tracked_changes_are_reported \
  test_untracked_files_are_reported \
  test_ignored_private_files_do_not_block_removal \
  test_dry_run_changes_nothing \
  test_main_checkout_is_skipped \
  test_live_process_is_skipped \
  test_commits_not_on_pr_head_are_reported \
  test_open_pr_is_kept \
  test_unknown_process_scan_removes_nothing \
  test_scan_is_silent_and_logged \
  test_pull_request_lookup_failure_removes_nothing \
  test_locked_worktree_is_not_removed \
  test_disabled_scan_leaves_the_worktree
