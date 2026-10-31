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

install_orca() {
  local dir=$1
  mkdir -p "$dir/bin"
  cat > "$dir/bin/orca" <<'SH'
#!/usr/bin/env bash
if [ "${FM_TEST_ORCA_RC:-0}" != 0 ]; then
  exit "$FM_TEST_ORCA_RC"
fi
case "$1 $2" in
  'worktree rm')
    printf '%s\n' "$*" >> "${FM_TEST_ORCA_JSON_FILE:?}.rm"
    [ "${FM_TEST_ORCA_RM_RC:-0}" = 0 ] || exit "$FM_TEST_ORCA_RM_RC"
    target=${4#path:}
    exec git -C "$target" worktree remove "$target"
    ;;
esac
cat "${FM_TEST_ORCA_JSON_FILE:?}"
SH
  chmod +x "$dir/bin/orca"
  orca_json "$dir/orca.json" false
}

orca_json() {
  local file=$1 truncated=$2 worktree=${3:-} terminal=${4:-}
  jq -n --arg worktree "$worktree" --arg terminal "$terminal" --argjson truncated "$truncated" '
    {ok: true, result: {
      worktrees: (if $worktree == "" then [] else [{path: $worktree}] end),
      terminals: (if $terminal == "" then [] else [{worktreePath: $terminal}] end),
      truncated: $truncated
    }}' > "$file"
}

# Time advances past the pass budget once the fake gh has run.
install_budget_clock() {
  local dir=$1
  cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_GH_LOG:?}"
: > "${FM_TEST_BUDGET_FLAG:?}"
cat "${FM_TEST_GH_JSON_FILE:?}"
SH
  cat > "$dir/bin/date" <<'SH'
#!/bin/sh
if [ "${1:-}" = '+%s' ] && [ -n "${FM_TEST_BUDGET_FLAG:-}" ]; then
  if [ -e "$FM_TEST_BUDGET_FLAG" ]; then
    echo 2000000000
  else
    echo 1000
  fi
  exit 0
fi
exec /bin/date "$@"
SH
  chmod +x "$dir/bin/gh" "$dir/bin/date"
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
  printf '[%s]\n' "$(pr_row 7 "$state" "$head")" > "$file"
}

pr_row() {
  local number=$1 state=$2 head=$3 owner=${4:-example}
  printf '{"number":%s,"state":"%s","headRefOid":"%s","url":"https://github.com/example/repo/pull/%s","headRepositoryOwner":{"login":"%s"}}' \
    "$number" "$state" "$head" "$number" "$owner"
}

run_clean() {
  local dir=$1 repo=$2
  shift 2
  PATH="$dir/bin:$PATH" \
    FM_TEST_GH_LOG="$dir/gh.log" \
    FM_TEST_GH_JSON_FILE="$dir/pr.json" \
    FM_TEST_GH_RC="${FM_TEST_GH_RC:-0}" \
    FM_TEST_ORCA_JSON_FILE="$dir/orca.json" \
    FM_TEST_ORCA_RC="${FM_TEST_ORCA_RC:-0}" \
    FM_TEST_ORCA_RM_RC="${FM_TEST_ORCA_RM_RC:-0}" \
    FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$dir/state" \
    FM_PROJECTS_OVERRIDE="$dir/projects" \
    "$CLEAN" "$@" "$repo"
}

begin_case() {
  local name=$1 branch=${2:-feature} pair
  CASE_DIR=$(make_case "$name")
  install_gh "$CASE_DIR/bin"
  install_orca "$CASE_DIR"
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

test_task_record_keeps_the_worktree() {
  begin_case taskrecord
  publish_pr CLOSED
  fm_write_meta "$CASE_DIR/state/t1.meta" "worktree=$CASE_WT"
  capture_clean "$CASE_DIR"
  assert_kept
  assert_out "task record owns it"
  pass "a worktree a task record names is reported"
}

test_unreadable_task_records_keep_the_worktree() {
  begin_case taskunreadable
  publish_pr MERGED
  mkdir -p "$CASE_DIR/data"
  printf 'not a registry line\n- malformed\n' > "$CASE_DIR/data/secondmates.md"
  capture_clean "$CASE_DIR"
  assert_kept
  assert_out "cannot read task records"
  pass "unreadable task records remove nothing"
}

test_treehouse_pool_slot_is_reported() {
  local slot
  begin_case poolslot
  slot="$CASE_DIR/pool/slot-1/repo"
  mkdir -p "$CASE_DIR/pool/slot-1"
  printf '{}\n' > "$CASE_DIR/pool/treehouse-state.json"
  git -C "$CASE_REPO" worktree remove "$CASE_WT" || fail "could not remove the default worktree"
  git -C "$CASE_REPO" worktree add --quiet -B feature "$slot" || fail "could not create the pool slot"
  CASE_WT=$slot
  publish_pr MERGED
  capture_clean "$CASE_DIR"
  assert_kept
  assert_out "Treehouse pool owns it"
  pass "a Treehouse pool slot is reported"
}

test_orca_listed_worktree_is_removed_through_orca() {
  begin_case orcalisted
  publish_pr MERGED
  add_stale_worktree "$CASE_REPO" "$CASE_DIR"
  orca_json "$CASE_DIR/orca.json" false "$CASE_WT"
  capture_clean "$CASE_DIR"
  assert_removed
  grep -F "worktree rm --worktree path:" "$CASE_DIR/orca.json.rm" >/dev/null \
    || fail "removal did not go through Orca"
  if grep -F -- "--force" "$CASE_DIR/orca.json.rm" >/dev/null; then
    fail "Orca removal was forced"
  fi
  if git -C "$CASE_REPO" worktree list --porcelain | grep -q 'stale-marker'; then
    fail "stale worktree registration remained after Orca removal"
  fi
  assert_out "pull request MERGED $PR_URL"
  pass "a worktree Orca lists is removed through Orca"
}

test_orca_listed_dirty_worktree_is_reported() {
  begin_case orcadirty
  publish_pr MERGED
  printf 'note\n' > "$CASE_WT/notes.txt"
  orca_json "$CASE_DIR/orca.json" false "$CASE_WT"
  capture_clean "$CASE_DIR"
  assert_kept
  [ ! -e "$CASE_DIR/orca.json.rm" ] || fail "Orca was asked to remove a dirty worktree"
  assert_out "untracked files"
  pass "a dirty worktree Orca lists is reported"
}

test_orca_dry_run_changes_nothing() {
  begin_case orcadry
  publish_pr MERGED
  orca_json "$CASE_DIR/orca.json" false "$CASE_WT"
  capture_clean "$CASE_DIR" --dry-run
  assert_kept
  [ ! -e "$CASE_DIR/orca.json.rm" ] || fail "dry-run asked Orca to remove the worktree"
  assert_out "dry-run "
  pass "dry-run does not ask Orca to remove a worktree"
}

test_orca_refusal_is_reported() {
  begin_case orcarefuse
  publish_pr MERGED
  orca_json "$CASE_DIR/orca.json" false "$CASE_WT"
  FM_TEST_ORCA_RM_RC=1 capture_clean "$CASE_DIR"
  assert_kept
  assert_out "removal refused"
  pass "an Orca refusal is reported"
}

test_live_orca_terminal_keeps_the_worktree() {
  begin_case orcaterminal
  publish_pr MERGED
  orca_json "$CASE_DIR/orca.json" false "$CASE_WT" "$CASE_WT"
  capture_clean "$CASE_DIR"
  assert_kept
  [ ! -e "$CASE_DIR/orca.json.rm" ] || fail "Orca was asked to remove a worktree with a live terminal"
  assert_out "Orca terminal is live"
  pass "a live Orca terminal keeps the worktree"
}

test_unreadable_orca_list_keeps_the_worktree() {
  begin_case orcafail
  publish_pr MERGED
  FM_TEST_ORCA_RC=1 capture_clean "$CASE_DIR"
  assert_kept
  assert_out "cannot read Orca"
  pass "a failed Orca lookup removes nothing"
}

test_truncated_orca_list_keeps_the_worktree() {
  begin_case orcatrunc
  publish_pr MERGED
  orca_json "$CASE_DIR/orca.json" true
  capture_clean "$CASE_DIR"
  assert_kept
  assert_out "cannot read Orca"
  pass "a truncated Orca list removes nothing"
}

test_worktree_containing_a_dirty_worktree_is_kept() {
  local child
  begin_case nested
  child="$CASE_WT/.worktrees/child"
  printf '.worktrees\n' > "$CASE_WT/.gitignore"
  git -C "$CASE_WT" add .gitignore
  git -C "$CASE_WT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'ignore nested worktrees' \
    || fail "could not commit the ignore rule"
  git -C "$CASE_REPO" worktree add --quiet -b child "$child" || fail "could not add the nested worktree"
  printf 'keep\n' > "$child/notes.txt"
  [ -z "$(git -C "$CASE_WT" status --porcelain)" ] || fail "the parent is not clean"
  publish_pr MERGED
  capture_clean "$CASE_DIR"
  assert_kept
  [ -f "$child/notes.txt" ] || fail "the nested worktree lost its untracked file"
  git -C "$CASE_REPO" worktree list --porcelain | grep -F "/.worktrees/child" >/dev/null \
    || fail "the nested worktree registration was pruned"
  assert_out "contains another worktree"
  assert_out "untracked files"
  pass "a worktree that contains another worktree is reported"
}

test_missing_pr_head_is_fetched_from_the_pull_ref() {
  local gate sha
  begin_case pipelinehead
  gate="$CASE_DIR/gate"
  git clone --quiet "$CASE_REPO.origin.git" "$gate" || fail "could not clone origin"
  git -C "$gate" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit --allow-empty -qm 'pipeline fix' \
    || fail "could not add the pipeline commit"
  git -C "$gate" push --quiet origin HEAD:refs/pull/7/head || fail "could not publish the pull ref"
  sha=$(git -C "$gate" rev-parse HEAD) || fail "could not read the pipeline head"
  if git -C "$CASE_REPO" cat-file -e "$sha^{commit}" 2>/dev/null; then
    fail "the pipeline head was already local"
  fi
  pr_json "$CASE_DIR/pr.json" MERGED "$sha"
  capture_clean "$CASE_DIR"
  assert_removed
  assert_branch "$CASE_REPO" feature
  assert_out "pull request MERGED $PR_URL"
  pass "a pipeline head that is missing locally is fetched"
}

test_failed_head_fetch_is_reported() {
  begin_case nopullref
  pr_json "$CASE_DIR/pr.json" MERGED 0123456789012345678901234567890123456789
  capture_clean "$CASE_DIR"
  assert_kept
  assert_out "pull request head is not in this repository"
  pass "a failed head fetch removes nothing"
}

test_newest_terminal_pr_decides() {
  local sha
  begin_case multiterminal
  sha=$(git -C "$CASE_WT" rev-parse HEAD) || fail "could not read the worktree head"
  printf '[%s,%s]\n' \
    "$(pr_row 9 MERGED "$sha")" \
    "$(pr_row 4 CLOSED 0123456789012345678901234567890123456789)" > "$CASE_DIR/pr.json"
  capture_clean "$CASE_DIR"
  assert_removed
  assert_out "pull request MERGED https://github.com/example/repo/pull/9"
  pass "the newest of several terminal pull requests decides removal"
}

test_commits_off_the_newest_terminal_head_are_reported() {
  local sha
  begin_case multiahead
  sha=$(git -C "$CASE_WT" rev-parse HEAD) || fail "could not read the worktree head"
  git -C "$CASE_WT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit --allow-empty -qm later \
    || fail "could not add a later commit"
  printf '[%s,%s]\n' \
    "$(pr_row 9 CLOSED "$sha")" \
    "$(pr_row 4 MERGED "$(git -C "$CASE_WT" rev-parse HEAD)")" > "$CASE_DIR/pr.json"
  capture_clean "$CASE_DIR"
  assert_kept
  assert_out "commits not on PR head"
  pass "commits that are not on the newest terminal head are reported"
}

test_fork_pull_requests_do_not_count() {
  local sha
  begin_case forks
  sha=$(git -C "$CASE_WT" rev-parse HEAD) || fail "could not read the worktree head"
  printf '[%s,%s]\n' \
    "$(pr_row 12 OPEN "$sha" stranger)" \
    "$(pr_row 7 MERGED "$sha" EXAMPLE)" > "$CASE_DIR/pr.json"
  capture_clean "$CASE_DIR"
  assert_removed
  assert_out "pull request MERGED $PR_URL"

  begin_case forkonly
  sha=$(git -C "$CASE_WT" rev-parse HEAD) || fail "could not read the worktree head"
  printf '[%s]\n' "$(pr_row 12 MERGED "$sha" stranger)" > "$CASE_DIR/pr.json"
  capture_clean "$CASE_DIR"
  assert_kept
  assert_out "no pull request"
  pass "pull requests from another owner do not count"
}

scan_pass() {
  rm -f "$CASE_DIR/spent" "$CASE_DIR/gh.log"
  PATH="$CASE_DIR/bin:$PATH" \
    FM_TEST_GH_LOG="$CASE_DIR/gh.log" \
    FM_TEST_GH_JSON_FILE="$CASE_DIR/pr.json" \
    FM_TEST_BUDGET_FLAG="$CASE_DIR/spent" \
    FM_TEST_ORCA_JSON_FILE="$CASE_DIR/orca.json" \
    FM_HOME="$CASE_DIR" \
    FM_STATE_OVERRIDE="$CASE_DIR/state" \
    FM_PROJECTS_OVERRIDE="$CASE_DIR/projects" \
    "$CLEAN" "$@" || fail "cleanup pass exited nonzero"
}

assert_scanned_only() {
  local branch=$1
  [ "$(wc -l < "$CASE_DIR/gh.log" | tr -d '[:space:]')" = 1 ] \
    || fail "pass looked up more than one branch: $(cat "$CASE_DIR/gh.log")"
  grep -F -- "--head $branch " "$CASE_DIR/gh.log" >/dev/null \
    || fail "pass did not reach branch $branch: $(cat "$CASE_DIR/gh.log")"
}

test_budget_stops_rotate_through_every_worktree() {
  local repo sha cursor
  CASE_DIR=$(make_case rotate)
  install_orca "$CASE_DIR"
  install_budget_clock "$CASE_DIR"
  repo="$CASE_DIR/projects/repo"
  fm_git_worktree "$repo" "$CASE_DIR/wt-a" branch-a
  git -C "$repo" worktree add --quiet -b branch-b "$CASE_DIR/wt-b" || fail "could not add wt-b"
  git -C "$repo" worktree add --quiet -b branch-c "$CASE_DIR/wt-c" || fail "could not add wt-c"
  sha=$(git -C "$repo" rev-parse HEAD) || fail "could not read the head"

  pr_json "$CASE_DIR/pr.json" MERGED "$sha"
  scan_pass scan
  assert_scanned_only branch-a
  [ ! -e "$CASE_DIR/wt-a" ] || fail "first pass did not remove wt-a"

  pr_json "$CASE_DIR/pr.json" OPEN "$sha"
  scan_pass scan
  assert_scanned_only branch-b
  grep -F "stop budget reached" "$CASE_DIR/state/worktree-cleanup.log" >/dev/null \
    || fail "the budget stop was not logged"
  cursor=$(cat "$CASE_DIR/state/worktree-cleanup.cursor")

  scan_pass --dry-run
  assert_scanned_only branch-c
  [ "$(cat "$CASE_DIR/state/worktree-cleanup.cursor")" = "$cursor" ] \
    || fail "dry-run moved the cursor"

  scan_pass scan
  assert_scanned_only branch-c
  scan_pass scan
  assert_scanned_only branch-b
  pass "budget stops rotate through every worktree, past a removed cursor path"
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
  test_disabled_scan_leaves_the_worktree \
  test_task_record_keeps_the_worktree \
  test_unreadable_task_records_keep_the_worktree \
  test_treehouse_pool_slot_is_reported \
  test_orca_listed_worktree_is_removed_through_orca \
  test_orca_listed_dirty_worktree_is_reported \
  test_orca_dry_run_changes_nothing \
  test_orca_refusal_is_reported \
  test_live_orca_terminal_keeps_the_worktree \
  test_worktree_containing_a_dirty_worktree_is_kept \
  test_unreadable_orca_list_keeps_the_worktree \
  test_truncated_orca_list_keeps_the_worktree \
  test_missing_pr_head_is_fetched_from_the_pull_ref \
  test_failed_head_fetch_is_reported \
  test_newest_terminal_pr_decides \
  test_commits_off_the_newest_terminal_head_are_reported \
  test_fork_pull_requests_do_not_count \
  test_budget_stops_rotate_through_every_worktree
