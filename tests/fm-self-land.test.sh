#!/usr/bin/env bash
# Tests for bin/fm-self-land.sh: the guarded wrapper a lane owner uses to land
# its own approved pull request through bin/fm-pr-merge.sh.
#
# Every case runs the real wrapper, the real merge gate, and the real merge
# review check against a stand-in forge, so a refusal is proved by the absence
# of a merge command and a landing by the exact command the gate sent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SELF_LAND="$ROOT/bin/fm-self-land.sh"
TMP_ROOT=$(fm_test_tmproot fm-self-land-tests)
command -v jq >/dev/null 2>&1 || fail "these tests read forge JSON with the real jq, which was not found"

REPO_URL=https://github.com/example/repo
BASE_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
MERGE_SHA=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
OTHER_SHA=dddddddddddddddddddddddddddddddddddddddd

# A fresh home for one case: task record, backlog, an empty forge log, and a
# git copy whose HEAD is on a remote-tracking ref. Echoes the case directory.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/home/data" "$case_dir/home/config" "$case_dir/fakebin"
  fm_git_init_commit "$case_dir/wt"
  git -C "$case_dir/wt" update-ref refs/remotes/origin/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
  fm_test_tasks_toml "$case_dir/home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$case_dir/home/data/backlog.md"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  : > "$case_dir/gh.log"
  printf '%s\n' "$case_dir"
}

# The owner's grant. Args: case_dir [config line]...
write_grant() {
  local case_dir=$1
  shift
  printf '%s\n' "$@" > "$case_dir/home/config/self-land"
}

# Record a two-model review of <url> at a new commit and echo that commit. The
# reviewers are stand-ins; the receipts and the verdict rule are the real ones.
seed_review() {
  local case_dir=$1 url=$2 verdict=$3 head tool
  printf '%s\n' \
    'seat=anthropic:claude:claude-test-1' \
    'seat=google:agy:gemini-test-high' \
    'require=github.com/example/repo' > "$case_dir/home/config/merge-review"
  printf 'reviewed change for %s\n' "$url" >> "$case_dir/wt/change.txt"
  git -C "$case_dir/wt" add change.txt
  git -C "$case_dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "reviewed change for $url"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  mkdir -p "$case_dir/reviewbin"
  for tool in claude agy; do
    cat > "$case_dir/reviewbin/$tool" <<'SH'
#!/usr/bin/env bash
tool=${0##*/}
[ "${1:-}" != --version ] || { echo "$tool 9.9.9"; exit 0; }
verdict=APPROVE
[ "$tool" != agy ] || verdict=$FM_TEST_AGY_VERDICT
text="Summary: the change adds one text file and nothing reads it.
Files read: diff.patch and snapshot/change.txt.
Findings: the file is plain text, no script sources it, and no document or test contradicts it.
This stand-in review is long enough to clear the floor that keeps a bare verdict from counting.
VERDICT: $verdict $FM_TEST_REVIEW_HEAD"
if [ "$tool" = claude ]; then
  jq -n --arg t "$text" '{result: $t, modelUsage: {"claude-test-1": {}}}'
else
  jq -n --arg t "$text" '{status: "SUCCESS", response: $t}'
fi
SH
    chmod +x "$case_dir/reviewbin/$tool"
  done
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" FM_TASK_ID=task-x1 \
    FM_TEST_AGY_VERDICT="$verdict" FM_TEST_REVIEW_HEAD="$head" \
    PATH="$case_dir/reviewbin:$PATH" \
    "$ROOT/bin/fm-merge-review.sh" run "$url" --head "$head" --repo "$case_dir/wt" --base origin/main \
    > "$case_dir/review.out" 2> "$case_dir/review.err" || true
  printf '%s\n' "$head"
}

# The pull request as the forge reports it. Args: case_dir number head [files] [base]
write_pull() {
  local case_dir=$1 number=$2 head=$3 files=${4:-1} base=${5:-main}
  printf '{"state":"open","merged":false,"head":{"sha":"%s"},"base":{"ref":"%s"},"changed_files":%s,"merge_commit_sha":null}\n' \
    "$head" "$base" "$files" > "$case_dir/pull-$number.json"
}

# The pull request's file list. Args: case_dir number <jq array literal>
write_files() {
  jq -c -n "$3" > "$1/files-$2.json"
}

# A stand-in forge for one case: the reads and the merge command of
# bin/fm-pr-merge.sh, plus the reads bin/fm-self-land.sh adds. A merge that
# takes effect rewrites the pull request the way the forge would.
# Args: case_dir number head
add_forge() {
  local case_dir=$1 number=$2 head=$3
  printf '%s\n' "$head" > "$case_dir/github-head"
  cat > "$case_dir/github-view.json" <<JSON
{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"$head","baseRefName":"main","baseRefOid":"$(git -C "$case_dir/wt" rev-parse origin/main)","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}
JSON
  printf '%s\n' 'state=OPEN' 'merged=false' 'queued=false' 'base=main' > "$case_dir/github-outcome"
  : > "$case_dir/github-rules"
  printf '{"name":"main","protected":false,"commit":{"sha":"%s"},"protection":{"enabled":false,"required_status_checks":{"enforcement_level":"off","contexts":[],"checks":[]}}}\n' \
    "$BASE_SHA" > "$case_dir/github-branch.json"
  printf '[{"type":"deletion"}]\n' > "$case_dir/github-required-rules.json"
  printf '%s\n' "$BASE_SHA" > "$case_dir/base-sha"
  printf '{"total_count":1,"check_runs":[{"name":"ci","status":"completed","conclusion":"success"}]}\n' \
    > "$case_dir/base-check-runs.json"
  printf '{"state":"success","statuses":[]}\n' > "$case_dir/base-status.json"
  write_pull "$case_dir" "$number" "$head"
  write_files "$case_dir" "$number" '[{filename: "change.txt", status: "added"}]'
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_CASE_DIR/gh-axi.log"
case "${1:-} ${2:-}" in
  "pr view")
    [ "$#" -eq 5 ] && [ "${4:-}" = --repo ] || exit 2
    printf 'pull_request:\n  number: %s\n  state: merged\n' "$3"
    ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
d=$FM_TEST_CASE_DIR
printf '%s\n' "$*" >> "$d/gh.log"
pull_number() {
  local arg number=
  for arg in "$@"; do
    case "$arg" in
      repos/*/pulls/*)
        number=${arg#*/pulls/}
        number=${number%%[/?]*}
        ;;
    esac
  done
  printf '%s\n' "$number"
}
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *statusCheckRollup*) cat "$d/github-view.json"; exit 0 ;;
      *headRefOid*) cat "$d/github-head"; exit 0 ;;
      *isDraft*) cat "$d/github-view.json"; exit 0 ;;
    esac
    ;;
  "pr merge")
    number=${3:-}
    : > "$d/merge-entered"
    if [ -e "$d/merge-block" ]; then
      waited=0
      while [ ! -e "$d/merge-release" ] && [ "$waited" -lt 9000 ]; do
        sleep 0.1
        waited=$((waited + 1))
      done
    fi
    rc=0
    [ ! -f "$d/merge-rc" ] || rc=$(cat "$d/merge-rc")
    effect=none
    [ "$rc" -ne 0 ] || effect=merged
    [ ! -f "$d/merge-effect" ] || effect=$(cat "$d/merge-effect")
    if [ "$effect" = merged ]; then
      jq -c --arg sha "$FM_TEST_MERGE_SHA" \
        '.state = "closed" | .merged = true | .merge_commit_sha = $sha' \
        "$d/pull-$number.json" > "$d/pull-$number.json.new" \
        && mv "$d/pull-$number.json.new" "$d/pull-$number.json"
      printf '%s\n' 'state=MERGED' 'merged=true' 'queued=false' 'base=main' > "$d/github-outcome"
    fi
    [ ! -e "$d/pull-read-fail-after-merge" ] || : > "$d/pull-read-fail"
    if [ "$rc" -eq 0 ]; then
      printf 'merged:\n  number: %s\n  status: ok\n' "$number"
    else
      printf 'error: the connection to the forge was reset\n' >&2
    fi
    exit "$rc"
    ;;
  "api graphql")
    cat "$d/github-outcome"
    exit 0
    ;;
  api\ *)
    case " $* " in
      *" repos/"*"/compare/"*)
        git -C "$d/wt" rev-parse origin/main
        exit 0
        ;;
      *" repos/"*"/pulls/"*"/files"*)
        [ ! -e "$d/files-read-fail" ] || exit 1
        cat "$d/files-$(pull_number "$@").json"
        exit $?
        ;;
      *" repos/"*"/pulls/"*)
        [ ! -e "$d/pull-read-fail" ] || exit 1
        cat "$d/pull-$(pull_number "$@").json"
        exit $?
        ;;
      *" repos/"*"/commits/"*"/check-runs"*)
        case "$*" in
          *"/commits/$(cat "$d/base-sha")/check-runs"*)
            cat "$d/base-check-runs.json"
            exit $?
            ;;
        esac
        cat "$d/github-runs.json"
        exit $?
        ;;
      *" repos/"*"/commits/"*"/status "*)
        cat "$d/base-status.json"
        exit $?
        ;;
      *" repos/"*"/rules/branches/"*merge_queue*) ;;
      *" repos/"*"/rules/branches/"*)
        cat "$d/github-required-rules.json"
        exit 0
        ;;
      *" repos/"*"/branches/"*)
        [ ! -e "$d/branch-read-fail" ] || exit 1
        # GitHub reads the branch as one URL path segment: a name sent with a
        # bare slash is another route, and it answers 404.
        for arg in "$@"; do
          case "$arg" in
            repos/*/branches/*/*)
              printf 'gh: Not Found (HTTP 404)\n' >&2
              exit 1
              ;;
          esac
        done
        cat "$d/github-branch.json"
        exit 0
        ;;
    esac
    cat "$d/github-rules"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

run_self_land() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_CASE_DIR="$case_dir" \
  FM_TEST_MERGE_SHA="$MERGE_SHA" \
  FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=0 \
  HOME="$case_dir/user-home" \
  PATH="$case_dir/fakebin:$PATH" \
    "$SELF_LAND" "$@"
}

# Run a landing and keep its streams and exit status for the assertions.
land() {  # <case_dir> <args...>
  local case_dir=$1 rc=0
  shift
  run_self_land "$case_dir" "$@" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  printf '%s\n' "$rc" > "$case_dir/rc"
}

merge_calls() {  # <case_dir> -> number of merge commands the forge received
  grep -c '^pr merge ' "$1/gh.log" || true
}

repo_dir() {  # <case_dir>
  printf '%s\n' "$1/state/self-land/github/github.com/example/repo"
}

# Outcome records supervision received for a merge of <url>.
outcome_count() {  # <case_dir> <url>
  local count=0
  if [ -f "$1/state/.wake-queue" ]; then
    count=$(grep -cF -- "merge landed: task-x1 $2" "$1/state/.wake-queue" || true)
  fi
  printf '%s\n' "$count"
}

assert_refused() {  # <case_dir> <reason> <label>
  local case_dir=$1 reason=$2 label=$3
  expect_code 1 "$(cat "$case_dir/rc")" "$label: a refusal exits 1: $(cat "$case_dir/stderr")"
  assert_grep "self-land: refused ($reason)" "$case_dir/stderr" \
    "$label: expected a ($reason) refusal, got: $(cat "$case_dir/stderr")"
  [ "$(merge_calls "$case_dir")" -eq 0 ] \
    || fail "$label: a merge command reached the forge despite the refusal"
  assert_absent "$(repo_dir "$case_dir")/pending" "$label: a refusal left a pending record"
  assert_absent "$(repo_dir "$case_dir")/landed.tsv" "$label: a refusal was logged as landed"
}

# A case that is ready to land: allowlisted, approved at its head, green.
# Echoes "<case_dir> <head>". Args: name number
ready_case() {
  local name=$1 number=$2 case_dir head
  case_dir=$(make_case "$name")
  write_grant "$case_dir" 'allow=github.com/example/repo'
  head=$(seed_review "$case_dir" "$REPO_URL/pull/$number" APPROVE)
  assert_grep "merge-review: approved head=$head" "$case_dir/review.out" \
    "$name: the seeded review did not approve: $(cat "$case_dir/review.err")"
  add_forge "$case_dir" "$number" "$head"
  printf '%s %s\n' "$case_dir" "$head"
}

test_lands_an_allowlisted_repository_at_the_approved_head() {
  local case_dir head url=$REPO_URL/pull/301
  read -r case_dir head <<< "$(ready_case lands 301)"

  run_self_land "$case_dir" covers "$url" \
    || fail "lands: covers must accept a repository the grant names"
  if run_self_land "$case_dir" covers https://github.com/example/other/pull/1; then
    fail "lands: covers accepted a repository the grant does not name"
  fi

  land "$case_dir" task-x1 "$url" --head "$head"
  expect_code 0 "$(cat "$case_dir/rc")" "lands: an approved head must land: $(cat "$case_dir/stderr")"
  grep -qxF "pr merge 301 --repo example/repo --match-head-commit $head --squash" "$case_dir/gh.log" \
    || fail "lands: the merge was not bound to the approved head: $(grep '^pr merge ' "$case_dir/gh.log" || true)"
  [ "$(merge_calls "$case_dir")" -eq 1 ] || fail "lands: expected exactly one merge command"
  assert_grep "self-land: landed $url head=$head merge=$MERGE_SHA" "$case_dir/stdout" \
    "lands: the landing was not reported: $(cat "$case_dir/stdout")"
  assert_absent "$(repo_dir "$case_dir")/pending" "lands: the pending record outlived a known outcome"
  [ "$(wc -l < "$(repo_dir "$case_dir")/landed.tsv" | tr -d ' ')" -eq 1 ] \
    || fail "lands: expected one landed line"
  assert_grep "$head	$MERGE_SHA	landed" "$(repo_dir "$case_dir")/landed.tsv" \
    "lands: the landed line does not name the head and merge commit"
  [ "$(outcome_count "$case_dir" "$url")" -eq 1 ] \
    || fail "lands: supervision did not receive exactly one outcome"

  # The pull request is merged now: a repeat finds nothing to land.
  land "$case_dir" task-x1 "$url" --head "$head"
  expect_code 1 "$(cat "$case_dir/rc")" "lands: a merged pull request must not land again"
  [ "$(merge_calls "$case_dir")" -eq 1 ] || fail "lands: a repeat sent a second merge command"
  pass "lands only an allowlisted repository at the approved exact head"
}

test_refuses_a_repository_the_grant_does_not_name() {
  local case_dir head url=$REPO_URL/pull/302
  read -r case_dir head <<< "$(ready_case not-allowlisted 302)"

  rm -f "$case_dir/home/config/self-land"
  land "$case_dir" task-x1 "$url" --head "$head"
  assert_refused "$case_dir" config "grant-absent"
  [ ! -s "$case_dir/gh.log" ] || fail "grant-absent: the forge was read with self-landing off"

  write_grant "$case_dir" '# another repository' 'allow=github.com/example/other'
  land "$case_dir" task-x1 "$url" --head "$head"
  assert_refused "$case_dir" not-allowlisted "grant-other-repo"

  write_grant "$case_dir" 'allow=*'
  land "$case_dir" task-x1 "$url" --head "$head"
  assert_refused "$case_dir" config "grant-wildcard"

  write_grant "$case_dir" 'allow=github.com/example/repo' 'waive=protected-path'
  land "$case_dir" task-x1 "$url" --head "$head"
  assert_refused "$case_dir" config "grant-unknown-key"

  # The grant is a repository allowlist only: it cannot change the protected paths.
  write_grant "$case_dir" 'allow=github.com/example/repo' 'protect=deploy/'
  land "$case_dir" task-x1 "$url" --head "$head"
  assert_refused "$case_dir" config "grant-protect-key"
  [ ! -s "$case_dir/gh.log" ] || fail "grant: the forge was read under a grant that refuses"

  # Letter case does not select another repository.
  write_grant "$case_dir" 'allow=GitHub.com/Example/Repo'
  land "$case_dir" task-x1 "$url" --head "$head"
  expect_code 0 "$(cat "$case_dir/rc")" "grant-case: the named repository must land: $(cat "$case_dir/stderr")"
  pass "refuses every repository the grant does not name"
}

test_refuses_without_an_approved_review_at_the_head() {
  local case_dir head url

  # The repository is covered, but nothing reviewed this pull request.
  url=$REPO_URL/pull/311
  read -r case_dir head <<< "$(ready_case evidence-none 311)"
  rm -rf "$case_dir/home/data/merge-review"
  land "$case_dir" task-x1 "$url" --head "$head"
  assert_refused "$case_dir" evidence "evidence-none"

  # Approved, but at another commit than the one named.
  url=$REPO_URL/pull/312
  read -r case_dir head <<< "$(ready_case evidence-other-head 312)"
  land "$case_dir" task-x1 "$url" --head "$OTHER_SHA"
  assert_refused "$case_dir" evidence "evidence-other-head"

  # One of the two models blocked.
  url=$REPO_URL/pull/313
  case_dir=$(make_case evidence-blocked)
  write_grant "$case_dir" 'allow=github.com/example/repo'
  head=$(seed_review "$case_dir" "$url" BLOCK)
  add_forge "$case_dir" 313 "$head"
  land "$case_dir" task-x1 "$url" --head "$head"
  assert_refused "$case_dir" evidence "evidence-blocked"

  # No review is required for the repository, so no approval can prove the head.
  url=$REPO_URL/pull/314
  read -r case_dir head <<< "$(ready_case evidence-uncovered 314)"
  rm -f "$case_dir/home/config/merge-review"
  land "$case_dir" task-x1 "$url" --head "$head"
  assert_refused "$case_dir" evidence "evidence-uncovered"
  pass "refuses a landing with missing review evidence"
}

test_refuses_a_diff_that_touches_a_protected_path() {
  local case_dir head url=$REPO_URL/pull/321
  read -r case_dir head <<< "$(ready_case protected 321)"

  write_pull "$case_dir" 321 "$head" 2
  write_files "$case_dir" 321 '[{filename: "change.txt"}, {filename: ".github/workflows/ci.yml"}]'
  land "$case_dir" task-x1 "$url" --head "$head"
  assert_refused "$case_dir" protected-path "protected-workflow"
  assert_grep '.github/workflows/ci.yml' "$case_dir/stderr" "protected-workflow: the path was not named"

  write_files "$case_dir" 321 '[{filename: "change.txt"}, {filename: "bin/fm-pr-merge.sh"}]'
  land "$case_dir" task-x1 "$url" --head "$head"
  assert_refused "$case_dir" protected-path "protected-gate"

  # A gate moved away is a gate removed.
  write_files "$case_dir" 321 \
    '[{filename: "change.txt"}, {filename: "bin/renamed.sh", previous_filename: "bin/fm-merge-review.sh"}]'
  land "$case_dir" task-x1 "$url" --head "$head"
  assert_refused "$case_dir" protected-path "protected-rename"

  # The wrapper protects itself.
  write_files "$case_dir" 321 '[{filename: "change.txt"}, {filename: "bin/fm-self-land.sh"}]'
  land "$case_dir" task-x1 "$url" --head "$head"
  assert_refused "$case_dir" protected-path "protected-self"

  # The libraries the gates load, and the poll script the pull request check
  # publishes, decide a merge as much as the gates do. The refusal names every
  # protected path of the diff, so one landing proves each of them.
  local lib libs='fm-timeout-lib.sh fm-dod-lib.sh fm-pr-poll.sh fm-classify-lib.sh fm-tasks-axi-lib.sh
    fm-hold-reason-lib.sh fm-parent-channel-lib.sh fm-bash-compat-lib.sh fm-path-lib.sh fm-session-lock-lib.sh'
  # shellcheck disable=SC2086 # The list is split into one argument per library.
  write_files "$case_dir" 321 "$(printf '{filename: "bin/%s"}\n' $libs | jq -R -s -r '
    "[{filename: \"change.txt\"}, " + (split("\n") | map(select(length > 0)) | join(", ")) + "]"')"
  write_pull "$case_dir" 321 "$head" 11
  land "$case_dir" task-x1 "$url" --head "$head"
  assert_refused "$case_dir" protected-path "protected-gate-libs"
  for lib in $libs; do
    grep -Fq "self-land: protected path: \"bin/$lib\"" "$case_dir/stderr" \
      || fail "protected-gate-libs: bin/$lib is loaded by a merge gate and was not refused: $(cat "$case_dir/stderr")"
  done
  grep -Fq 'protected path: "change.txt"' "$case_dir/stderr" \
    && fail "protected-gate-libs: an ordinary file was named as protected"

  # A file list that is shorter than the pull request says is not trusted.
  write_pull "$case_dir" 321 "$head" 3
  write_files "$case_dir" 321 '[{filename: "change.txt"}, {filename: "notes.md"}]'
  land "$case_dir" task-x1 "$url" --head "$head"
  assert_refused "$case_dir" forge-read "protected-incomplete"

  : > "$case_dir/files-read-fail"
  land "$case_dir" task-x1 "$url" --head "$head"
  assert_refused "$case_dir" forge-read "protected-unreadable"
  rm -f "$case_dir/files-read-fail"

  # The same pull request without a protected path lands.
  write_pull "$case_dir" 321 "$head" 2
  land "$case_dir" task-x1 "$url" --head "$head"
  expect_code 0 "$(cat "$case_dir/rc")" "protected-clear: an unprotected diff must land: $(cat "$case_dir/stderr")"
  pass "refuses a diff that touches the merge gates or the workflows"
}

test_stop_file_refuses_every_landing() {
  local case_dir head url=$REPO_URL/pull/331
  read -r case_dir head <<< "$(ready_case stop-file 331)"
  : > "$case_dir/state/.self-land-off"
  land "$case_dir" task-x1 "$url" --head "$head"
  assert_refused "$case_dir" stop-file "stop-file"
  [ ! -s "$case_dir/gh.log" ] || fail "stop-file: the forge was read while self-landing was stopped"

  rm -f "$case_dir/state/.self-land-off"
  land "$case_dir" task-x1 "$url" --head "$head"
  expect_code 0 "$(cat "$case_dir/rc")" "stop-file: removing the file must resume landing: $(cat "$case_dir/stderr")"
  pass "refuses every landing while the stop file exists"
}

test_captain_hold_refuses_the_landing() {
  local case_dir head url=$REPO_URL/pull/341
  read -r case_dir head <<< "$(ready_case hold 341)"
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-tasks-axi.sh" add task-x1 "Held merge" --kind ship --repo example \
    > "$case_dir/hold-add.out" 2> "$case_dir/hold-add.err" \
    || fail "hold: could not add the task: $(cat "$case_dir/hold-add.err")"
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-captain-hold.sh" hold task-x1 --reason "captain merge approval pending" \
    > "$case_dir/hold.out" 2> "$case_dir/hold.err" \
    || fail "hold: could not hold the task: $(cat "$case_dir/hold.err")"
  land "$case_dir" task-x1 "$url" --head "$head"
  assert_refused "$case_dir" hold "hold"
  pass "refuses a task that is held for the captain"
}

test_second_merge_in_flight_is_refused() {
  local case_dir head url=$REPO_URL/pull/351 first_pid waited=0 rc=0
  read -r case_dir head <<< "$(ready_case in-flight 351)"
  : > "$case_dir/merge-block"

  run_self_land "$case_dir" task-x1 "$url" --head "$head" \
    > "$case_dir/first.out" 2> "$case_dir/first.err" &
  first_pid=$!
  while [ ! -e "$case_dir/merge-entered" ]; do
    kill -0 "$first_pid" 2>/dev/null \
      || fail "in-flight: the first landing ended before its merge: $(cat "$case_dir/first.err")"
    [ "$waited" -lt 6000 ] || fail "in-flight: the first landing never reached its merge"
    sleep 0.1
    waited=$((waited + 1))
  done
  assert_present "$(repo_dir "$case_dir")/pending" \
    "in-flight: no pending record existed while the merge was at the forge"

  # A second landing in the same repository, for another pull request.
  run_self_land "$case_dir" task-x1 "$REPO_URL/pull/352" --head "$head" \
    > "$case_dir/second.out" 2> "$case_dir/second.err" || rc=$?
  : > "$case_dir/merge-release"
  wait "$first_pid" || fail "in-flight: the first landing failed: $(cat "$case_dir/first.err")"
  expect_code 1 "$rc" "in-flight: the second landing must be refused: $(cat "$case_dir/second.err")"
  assert_grep 'self-land: refused (in-flight)' "$case_dir/second.err" \
    "in-flight: expected an in-flight refusal, got: $(cat "$case_dir/second.err")"
  assert_grep 'one merge at a time' "$case_dir/second.err" \
    "in-flight: the refusal did not come from the repository lock: $(cat "$case_dir/second.err")"
  [ "$(merge_calls "$case_dir")" -eq 1 ] || fail "in-flight: the forge received more than one merge command"
  assert_no_grep 'pr merge 352' "$case_dir/gh.log" "in-flight: the second pull request was merged"
  assert_grep "self-land: landed $url" "$case_dir/first.out" "in-flight: the first landing did not finish"

  # The repository is free again once the first run ends.
  land "$case_dir" task-x1 "$url" --head "$head"
  assert_no_grep '(in-flight)' "$case_dir/stderr" "in-flight: a finished run still held the repository"
  pass "refuses a second merge while one is in flight for the repository"
}

test_red_base_trips_the_breaker_and_it_stays_tripped() {
  local case_dir head url=$REPO_URL/pull/361
  read -r case_dir head <<< "$(ready_case breaker 361)"
  # A green run does not replace a failed run of the same name that started
  # after it, and nothing replaces a failed run that reports no start time.
  jq -c -n '{total_count: 5, check_runs: [
    {name: "ci", status: "completed", conclusion: "success", started_at: "2026-11-17T10:00:00Z"},
    {name: "ci", status: "completed", conclusion: "failure", started_at: "2026-11-17T10:05:00Z"},
    {name: "lint", status: "completed", conclusion: "failure"},
    {name: "lint", status: "completed", conclusion: "success", started_at: "2026-11-17T10:05:00Z"},
    {name: "docs", status: "completed", conclusion: "success", started_at: "2026-11-17T10:00:00Z"}]}' \
    > "$case_dir/base-check-runs.json"
  land "$case_dir" task-x1 "$url" --head "$head"
  expect_code 1 "$(cat "$case_dir/rc")" "breaker-trip: a red base must refuse"
  assert_grep 'self-land: refused (red-base)' "$case_dir/stderr" \
    "breaker-trip: expected a red-base refusal, got: $(cat "$case_dir/stderr")"
  assert_present "$(repo_dir "$case_dir")/breaker" "breaker-trip: no breaker record was written"
  assert_grep "sha=$BASE_SHA" "$(repo_dir "$case_dir")/breaker" "breaker-trip: the record does not name the red commit"
  grep -Fxq 'red=ci, lint' "$(repo_dir "$case_dir")/breaker" \
    || fail "breaker-trip: the record must name exactly the red checks ci and lint: $(cat "$(repo_dir "$case_dir")/breaker")"
  [ "$(merge_calls "$case_dir")" -eq 0 ] || fail "breaker-trip: a merge was sent onto a red base"

  # The base is green again, but nobody has reset the breaker.
  printf '{"total_count":1,"check_runs":[{"name":"ci","status":"completed","conclusion":"success"}]}\n' \
    > "$case_dir/base-check-runs.json"
  : > "$case_dir/gh.log"
  land "$case_dir" task-x1 "$url" --head "$head"
  assert_refused "$case_dir" breaker "breaker-tripped"
  [ ! -s "$case_dir/gh.log" ] || fail "breaker-tripped: the forge was read with the breaker tripped"

  rm -f "$(repo_dir "$case_dir")/breaker"
  land "$case_dir" task-x1 "$url" --head "$head"
  expect_code 0 "$(cat "$case_dir/rc")" "breaker-reset: a reset breaker on a green base must land: $(cat "$case_dir/stderr")"

  # A failed commit status is red too. A failed check that was run again to
  # green on the same commit is not red, and a failed check with no name is
  # reported and never replaced.
  url=$REPO_URL/pull/362
  read -r case_dir head <<< "$(ready_case breaker-status 362)"
  jq -c -n '{total_count: 4, check_runs: [
    {name: "ci", status: "completed", conclusion: "failure", started_at: "2026-11-17T10:00:00Z"},
    {name: "ci", status: "completed", conclusion: "success", started_at: "2026-11-17T10:05:00Z"},
    {name: "", status: "completed", conclusion: "failure", started_at: "2026-11-17T10:00:00Z"},
    {name: "", status: "completed", conclusion: "success", started_at: "2026-11-17T10:05:00Z"}]}' \
    > "$case_dir/base-check-runs.json"
  printf '{"state":"failure","statuses":[{"context":"deploy/preview","state":"failure"}]}\n' \
    > "$case_dir/base-status.json"
  land "$case_dir" task-x1 "$url" --head "$head"
  assert_grep 'self-land: refused (red-base)' "$case_dir/stderr" \
    "breaker-status: expected a red-base refusal, got: $(cat "$case_dir/stderr")"
  grep -Fxq 'red=(unnamed check), deploy/preview' "$(repo_dir "$case_dir")/breaker" \
    || fail "breaker-status: the record must name the unnamed check and the red status, and not the rerun ci: $(cat "$(repo_dir "$case_dir")/breaker")"

  # A rerun to green on the same commit leaves the base green, so the landing goes through.
  rm -f "$(repo_dir "$case_dir")/breaker"
  jq -c -n '{total_count: 2, check_runs: [
    {name: "ci", status: "completed", conclusion: "failure", started_at: "2026-11-17T10:00:00Z"},
    {name: "ci", status: "completed", conclusion: "success", started_at: "2026-11-17T10:05:00Z"}]}' \
    > "$case_dir/base-check-runs.json"
  printf '{"state":"success","statuses":[]}\n' > "$case_dir/base-status.json"
  land "$case_dir" task-x1 "$url" --head "$head"
  expect_code 0 "$(cat "$case_dir/rc")" "breaker-rerun: a check rerun to green must not hold the landing: $(cat "$case_dir/stderr")"
  assert_absent "$(repo_dir "$case_dir")/breaker" "breaker-rerun: a rerun to green tripped the breaker"

  # A base branch whose name has a slash is read as one URL path segment.
  url=$REPO_URL/pull/364
  read -r case_dir head <<< "$(ready_case breaker-slashed-base 364)"
  write_pull "$case_dir" 364 "$head" 1 release/v1
  printf '{"total_count":1,"check_runs":[{"name":"ci","status":"completed","conclusion":"failure"}]}\n' \
    > "$case_dir/base-check-runs.json"
  land "$case_dir" task-x1 "$url" --head "$head"
  assert_grep 'self-land: refused (red-base)' "$case_dir/stderr" \
    "breaker-slashed-base: the base branch release/v1 must be read, got: $(cat "$case_dir/stderr")"
  assert_grep 'base=release/v1' "$(repo_dir "$case_dir")/breaker" \
    "breaker-slashed-base: the record does not name the base branch"

  url=$REPO_URL/pull/363
  read -r case_dir head <<< "$(ready_case breaker-unreadable 363)"
  : > "$case_dir/branch-read-fail"
  land "$case_dir" task-x1 "$url" --head "$head"
  assert_refused "$case_dir" forge-read "breaker-unreadable"
  assert_absent "$(repo_dir "$case_dir")/breaker" "breaker-unreadable: an unreadable base tripped the breaker"
  pass "trips the breaker on a red base and stays tripped until it is reset"
}

test_lost_forge_response_reconciles_without_a_second_merge() {
  local case_dir head url

  # The forge merged, but the merge command reported a failure.
  url=$REPO_URL/pull/371
  read -r case_dir head <<< "$(ready_case lost-same-run 371)"
  printf '1\n' > "$case_dir/merge-rc"
  printf 'merged\n' > "$case_dir/merge-effect"
  land "$case_dir" task-x1 "$url" --head "$head"
  expect_code 0 "$(cat "$case_dir/rc")" "lost-same-run: a merged pull request must reconcile: $(cat "$case_dir/stderr")"
  assert_grep "self-land: landed $url head=$head merge=$MERGE_SHA (reconciled)" "$case_dir/stdout" \
    "lost-same-run: the reconciliation was not reported: $(cat "$case_dir/stdout")"
  [ "$(merge_calls "$case_dir")" -eq 1 ] || fail "lost-same-run: expected exactly one merge command"
  assert_absent "$(repo_dir "$case_dir")/pending" "lost-same-run: the pending record outlived the reconciliation"
  assert_grep "$MERGE_SHA	reconciled" "$(repo_dir "$case_dir")/landed.tsv" "lost-same-run: no reconciled line was logged"
  [ "$(outcome_count "$case_dir" "$url")" -eq 1 ] \
    || fail "lost-same-run: supervision did not receive exactly one outcome"

  # The forge merged, and nothing could be read back in the same run.
  url=$REPO_URL/pull/372
  read -r case_dir head <<< "$(ready_case lost-next-run 372)"
  printf '1\n' > "$case_dir/merge-rc"
  printf 'merged\n' > "$case_dir/merge-effect"
  : > "$case_dir/pull-read-fail-after-merge"
  land "$case_dir" task-x1 "$url" --head "$head"
  [ "$(cat "$case_dir/rc")" -ne 0 ] || fail "lost-next-run: an unknown outcome must not report success"
  assert_grep 'self-land: outcome unknown' "$case_dir/stderr" \
    "lost-next-run: the unknown outcome was not reported: $(cat "$case_dir/stderr")"
  assert_present "$(repo_dir "$case_dir")/pending" "lost-next-run: the pending record was dropped with the outcome unknown"
  assert_absent "$(repo_dir "$case_dir")/landed.tsv" "lost-next-run: an unknown outcome was logged as landed"
  [ "$(outcome_count "$case_dir" "$url")" -eq 0 ] || fail "lost-next-run: an unknown outcome was reported to supervision"

  # The forge is still unreadable: nothing changes and nothing is sent.
  land "$case_dir" task-x1 "$url" --head "$head"
  expect_code 1 "$(cat "$case_dir/rc")" "lost-next-run: an unreadable pull request must refuse"
  assert_present "$(repo_dir "$case_dir")/pending" "lost-next-run: the pending record was dropped while unreadable"

  # The forge answers again: the same command settles it with no second merge.
  rm -f "$case_dir/pull-read-fail" "$case_dir/pull-read-fail-after-merge"
  land "$case_dir" task-x1 "$url" --head "$head"
  expect_code 0 "$(cat "$case_dir/rc")" "lost-next-run: the rerun must reconcile: $(cat "$case_dir/stderr")"
  assert_grep "self-land: landed $url head=$head merge=$MERGE_SHA (reconciled)" "$case_dir/stdout" \
    "lost-next-run: the reconciliation was not reported: $(cat "$case_dir/stdout")"
  [ "$(merge_calls "$case_dir")" -eq 1 ] || fail "lost-next-run: the rerun sent a second merge command"
  assert_absent "$(repo_dir "$case_dir")/pending" "lost-next-run: the pending record outlived the reconciliation"
  [ "$(wc -l < "$(repo_dir "$case_dir")/landed.tsv" | tr -d ' ')" -eq 1 ] \
    || fail "lost-next-run: expected one landed line"
  [ "$(outcome_count "$case_dir" "$url")" -eq 1 ] \
    || fail "lost-next-run: supervision did not receive exactly one outcome"

  # Another run changes nothing more.
  land "$case_dir" task-x1 "$url" --head "$head"
  [ "$(merge_calls "$case_dir")" -eq 1 ] || fail "lost-next-run: a later run sent a second merge command"
  [ "$(wc -l < "$(repo_dir "$case_dir")/landed.tsv" | tr -d ' ')" -eq 1 ] \
    || fail "lost-next-run: a later run logged the landing twice"
  [ "$(outcome_count "$case_dir" "$url")" -eq 1 ] \
    || fail "lost-next-run: a later run reported the outcome twice"

  # A merge sent a moment ago that is still unmerged is in flight, not lost.
  url=$REPO_URL/pull/373
  read -r case_dir head <<< "$(ready_case pending-young 373)"
  bash -c '. "$1/bin/fm-merge-authority-lib.sh" && fm_self_land_pending_write "$2" task-x1 "$3" "$4" attended' \
    _ "$ROOT" "$(repo_dir "$case_dir")" "$url" "$head" \
    || fail "pending-young: could not write the pending record"
  land "$case_dir" task-x1 "$url" --head "$head"
  expect_code 1 "$(cat "$case_dir/rc")" "pending-young: a fresh pending merge must refuse"
  assert_grep 'self-land: refused (in-flight)' "$case_dir/stderr" \
    "pending-young: expected an in-flight refusal, got: $(cat "$case_dir/stderr")"
  [ "$(merge_calls "$case_dir")" -eq 0 ] || fail "pending-young: a merge was sent over a pending one"
  assert_present "$(repo_dir "$case_dir")/pending" "pending-young: the pending record was dropped inside its grace"

  # Past the grace the record is dropped and the guarded landing runs afresh.
  FM_SELF_LAND_PENDING_GRACE=0 land "$case_dir" task-x1 "$url" --head "$head"
  expect_code 0 "$(cat "$case_dir/rc")" "pending-old: an expired pending record must not block: $(cat "$case_dir/stderr")"
  [ "$(merge_calls "$case_dir")" -eq 1 ] || fail "pending-old: expected exactly one merge command"

  # A pending record that cannot be read is never guessed at.
  url=$REPO_URL/pull/374
  read -r case_dir head <<< "$(ready_case pending-garbled 374)"
  mkdir -p "$(repo_dir "$case_dir")"
  printf 'not a pending record\n' > "$(repo_dir "$case_dir")/pending"
  land "$case_dir" task-x1 "$url" --head "$head"
  expect_code 1 "$(cat "$case_dir/rc")" "pending-garbled: an unreadable pending record must refuse"
  assert_grep 'self-land: refused (pending)' "$case_dir/stderr" \
    "pending-garbled: expected a pending refusal, got: $(cat "$case_dir/stderr")"
  [ "$(merge_calls "$case_dir")" -eq 0 ] || fail "pending-garbled: a merge was sent over an unreadable pending record"
  pass "reconciles a lost forge response without a duplicate merge"
}

test_takes_no_waiver_or_forge_option() {
  local case_dir head url=$REPO_URL/pull/381 rc
  read -r case_dir head <<< "$(ready_case no-waiver 381)"
  : > "$case_dir/gh.log"
  for extra in --allow-red --allow-protected-path --admin --merge --force; do
    rc=0
    run_self_land "$case_dir" task-x1 "$url" --head "$head" "$extra" \
      > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 2 "$rc" "no-waiver: $extra must be an invalid request"
  done
  rc=0
  run_self_land "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 2 "$rc" "no-waiver: a landing without --head must be invalid"
  rc=0
  run_self_land "$case_dir" task-x1 "$url" --head abc1234 > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 2 "$rc" "no-waiver: a short commit id must be invalid"
  rc=0
  run_self_land "$case_dir" task-x1 "$url" --expected-head "$head" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 2 "$rc" "no-waiver: only --head names the commit"
  [ ! -s "$case_dir/gh.log" ] || fail "no-waiver: an invalid request reached the forge"
  pass "takes no waiver flag and passes no option to the forge"
}

test_merge_gate_refusal_stays_a_refusal() {
  local case_dir head url=$REPO_URL/pull/391
  read -r case_dir head <<< "$(ready_case gate-refusal 391)"
  # The pull request's own check is red: bin/fm-pr-merge.sh refuses it.
  cat > "$case_dir/github-view.json" <<JSON
{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"$head","baseRefName":"main","baseRefOid":"$(git -C "$case_dir/wt" rev-parse origin/main)","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"FAILURE"}]}
JSON
  land "$case_dir" task-x1 "$url" --head "$head"
  [ "$(cat "$case_dir/rc")" -ne 0 ] || fail "gate-refusal: a red pull request must not land"
  assert_grep 'bin/fm-pr-merge.sh refused' "$case_dir/stderr" \
    "gate-refusal: the refusal did not come from the merge gate: $(cat "$case_dir/stderr")"
  [ "$(merge_calls "$case_dir")" -eq 0 ] || fail "gate-refusal: a merge command was sent for a red pull request"
  assert_absent "$(repo_dir "$case_dir")/pending" "gate-refusal: a refused merge left a pending record"
  assert_absent "$(repo_dir "$case_dir")/landed.tsv" "gate-refusal: a refused merge was logged as landed"
  pass "keeps every refusal of the merge gate it wraps"
}

fm_test_run \
  test_lands_an_allowlisted_repository_at_the_approved_head \
  test_refuses_a_repository_the_grant_does_not_name \
  test_refuses_without_an_approved_review_at_the_head \
  test_refuses_a_diff_that_touches_a_protected_path \
  test_stop_file_refuses_every_landing \
  test_captain_hold_refuses_the_landing \
  test_second_merge_in_flight_is_refused \
  test_red_base_trips_the_breaker_and_it_stays_tripped \
  test_lost_forge_response_reconciles_without_a_second_merge \
  test_takes_no_waiver_or_forge_option \
  test_merge_gate_refusal_stays_a_refusal
