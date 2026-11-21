#!/usr/bin/env bash
# Behavior coverage for the startup unpublished-task-branch backstop.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE

TMP_ROOT=$(fm_test_tmproot fm-unpushed-reconcile)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT
mkdir -p "$TMP_ROOT/fakebin"
cat > "$TMP_ROOT/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_GH_LOG"
[ -z "${FM_GH_PID:-}" ] || printf '%s\n' "$$" > "$FM_GH_PID"
[ "${FM_GH_FAIL:-0}" = 0 ] || exit 1
[ -z "${FM_GH_SLEEP:-}" ] || sleep "$FM_GH_SLEEP"
if [ "$1" = api ]; then
  # GitHub's head filter selects PRs whose head branch lives in that owner.
  [ "${FM_GH_API_FAIL:-0}" = 0 ] || exit 1
  case "$*" in
    *"head=${FM_GH_MERGED_OWNER:-example}:"*) shas=${FM_GH_MERGED_HEAD:-} ;;
    *) shas='' ;;
  esac
  if [ -n "$shas" ]; then printf 'api_response:\n  body: %s\n  truncated: false\n' "$shas"
  else printf 'api_response:\n  body: ""\n  truncated: false\n'; fi
elif [ "${FM_GH_OPEN:-0}" = 1 ]; then
  printf 'count: 1\npull_requests[1]{url}:\n  "https://github.com/example/demo/pull/12"\n'
else
  printf 'count: 0\npull_requests: []\n'
fi
SH
cat > "$TMP_ROOT/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
[ "$1" = show ] || exit 1
if grep -Fq -- "- [ ] $2 - " "$FM_HOME/data/backlog.md"; then
  printf 'task:\n  state: In flight\n  held: no\n  blocked: no\n'
else
  printf 'code: NOT_FOUND\n'
  exit 1
fi
SH
chmod +x "$TMP_ROOT/fakebin/gh-axi" "$TMP_ROOT/fakebin/tasks-axi"
export PATH="$TMP_ROOT/fakebin:$PATH"
export FM_GH_LOG="$TMP_ROOT/gh.log"

new_world() {
  FM_HOME="$TMP_ROOT/$1"
  export FM_HOME
  PROJECT="$FM_HOME/projects/demo"
  mkdir -p "$PROJECT" "$FM_HOME/data" "$FM_HOME/config" "$FM_HOME/state"
  printf '%s\n' '- demo [no-mistakes] - fixture' > "$FM_HOME/data/projects.md"
  printf '%s\n' '- [ ] task - example' > "$FM_HOME/data/backlog.md"
  git -C "$PROJECT" init -q -b main
  git -C "$PROJECT" -c user.name=Test -c user.email=test@example.com commit -qm base --allow-empty
  git -C "$PROJECT" remote add origin https://github.com/example/demo.git
  git -C "$PROJECT" update-ref refs/remotes/origin/main HEAD
  git -C "$PROJECT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$PROJECT" checkout -qb fm/task
  printf 'change\n' > "$PROJECT/change.txt"
  git -C "$PROJECT" add change.txt
  git -C "$PROJECT" -c user.name=Test -c user.email=test@example.com commit -qm change
  cat > "$FM_HOME/state/task.meta" <<EOF
project=$PROJECT
branch=fm/task
kind=ship
mode=no-mistakes
EOF
  printf 'blocked [at=100] [key=nm-daemon-gate-context]: startup timed out twice\n' > "$FM_HOME/state/task.status"
  : > "$FM_GH_LOG"
}

scan() { bash "$ROOT/bin/fm-unpushed-reconcile.sh" scan; }

new_world slow-content-proof
git -C "$PROJECT" branch fm/another
REAL_GIT=$(command -v git)
cat > "$TMP_ROOT/fakebin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' merge-tree '*)
    printf 'entered\n' > "$FM_CONTENT_PROOF_MARK"
    sleep 20
    ;;
esac
exec "$FM_CONTENT_PROOF_GIT" "$@"
SH
chmod +x "$TMP_ROOT/fakebin/git"
out=$(FM_UNPUSHED_TIMEOUT_SECS=5 FM_CONTENT_PROOF_GIT="$REAL_GIT" \
  FM_CONTENT_PROOF_MARK="$FM_HOME/proof-entered" scan)
rm "$TMP_ROOT/fakebin/git"
[ -f "$FM_HOME/proof-entered" ] || fail 'the delayed content proof was never entered'
assert_contains "$out" 'branch=fm/task' 'a content-proof timeout lost a known branch'
assert_contains "$out" 'branch=fm/another' 'a content-proof timeout lost the later known branch'
assert_contains "$out" 'incomplete' 'a content-proof timeout became success'
pass 'inventory survives a delayed first content proof before comparison starts'

new_world nested-directory
git -C "$FM_HOME" init -q -b main
git -C "$FM_HOME" -c user.name=Test -c user.email=test@example.com commit -qm base --allow-empty
git -C "$FM_HOME" remote add origin https://github.com/example/home.git
git -C "$FM_HOME" update-ref refs/remotes/origin/main HEAD
git -C "$FM_HOME" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$FM_HOME" checkout -qb fm/home-task
printf 'unpublished home task\n' > "$FM_HOME/change.txt"
git -C "$FM_HOME" add change.txt
git -C "$FM_HOME" -c user.name=Test -c user.email=test@example.com commit -qm change
mkdir -p "$FM_HOME/projects/container"
printf '%s\n' '- container [local-only] - nested directory' >> "$FM_HOME/data/projects.md"
printf 'project=%s\nbranch=fm/home-task\nkind=ship\nmode=no-mistakes\n' "$FM_HOME" > "$FM_HOME/state/home-task.meta"
out=$(scan)
assert_contains "$out" 'branch=fm/home-task' 'a nested directory consumed the home repository identity'
assert_contains "$out" 'task=home-task owner=recorded' 'the checkout root lost its recorded owner'
assert_not_contains "$out" 'project='"$FM_HOME/projects/container" 'a non-root directory was treated as a project checkout'
pass 'nested non-repository directories cannot hide a recorded checkout root'

new_world owned
before=$(git -C "$PROJECT" for-each-ref)
out=$(scan)
assert_contains "$out" 'branch=fm/task' 'missing branch'
assert_contains "$out" 'commits=1' 'wrong reachability count'
assert_contains "$out" 'task=task' 'missing task'
assert_contains "$out" 'owner=recorded' 'missing owner'
assert_contains "$out" 'ledger=In flight' 'missing ledger evidence'
assert_contains "$out" 'pr=none' 'wrong PR evidence'
assert_contains "$out" 'nm-daemon-gate-context' 'missing open blocker'
assert_contains "$out" 'escalate' 'missing action'
assert_equals "$before" "$(git -C "$PROJECT" for-each-ref)" 'scan changed refs'
assert_equals "$out" "$(scan)" 'repeat scan changed the finding'
pass 'unpublished blocked task is flagged on every startup without changing refs or its blocker'

new_world missing
rm "$FM_HOME/state/task.meta"
: > "$FM_HOME/data/backlog.md"
out=$(scan)
assert_contains "$out" 'branch=fm/task' 'missing orphan branch'
assert_contains "$out" 'owner=missing' 'invented owner'
assert_contains "$out" 'ledger=missing' 'missing orphan ledger evidence'
pass 'branch survives missing task metadata and ledger intake'

new_world open-pr
out=$(FM_GH_OPEN=1 scan)
assert_contains "$out" 'pr=open' 'missing open PR'
assert_contains "$out" 'https://github.com/example/demo/pull/12' 'missing PR URL'
assert_contains "$out" 'commits=1' 'PR hid local commits'
pass 'an open PR does not hide unpublished local follow-up commits'

new_world remote-covered
git -C "$PROJECT" update-ref refs/remotes/origin/task HEAD
assert_equals '' "$(scan)" 'published task was flagged'
assert_equals '' "$(cat "$FM_GH_LOG")" 'published task made an unnecessary forge read'
git -C "$PROJECT" update-ref -d refs/remotes/origin/task
git -C "$PROJECT" update-ref refs/remotes/backup/task HEAD
assert_equals '' "$(scan)" 'backup remote coverage was ignored'
borrowed_work="$TMP_ROOT/borrowed-inventory"
mkdir "$borrowed_work"
assert_equals '' "$(bash "$ROOT/bin/fm-unpushed-reconcile.sh" discover --work-dir "$borrowed_work")" 'inventory discovery printed an unverified publication claim'
assert_contains "$(bash "$ROOT/bin/fm-unpushed-reconcile.sh" pending --work-dir "$borrowed_work")" 'branch=fm/task' 'discovery did not retain the local identity'
assert_equals '' "$(bash "$ROOT/bin/fm-unpushed-reconcile.sh" scan --work-dir "$borrowed_work")" 'a published branch was reported during borrowed-work scanning'
assert_equals '' "$(bash "$ROOT/bin/fm-unpushed-reconcile.sh" pending --work-dir "$borrowed_work")" 'a verified published branch remained pending'
[ -d "$borrowed_work" ] || fail 'the scanner removed its caller-owned journal directory'
pass 'commits reachable from any publishing remote need no recovery finding'

squash_merge_into_origin_main() {
  local tree squash
  tree=$(git -C "$PROJECT" rev-parse "$1^{tree}")
  squash=$(printf 'squash\n' | git -C "$PROJECT" -c user.name=Test -c user.email=test@example.com \
    commit-tree "$tree" -p refs/remotes/origin/main)
  git -C "$PROJECT" update-ref refs/remotes/origin/main "$squash"
}

new_world squash-merged
git -C "$PROJECT" -c user.name=Test -c user.email=test@example.com commit -qm second --allow-empty
squash_merge_into_origin_main HEAD
assert_equals '' "$(scan)" 'squash-merged task head without a remote task branch was flagged'
assert_equals '' "$(cat "$FM_GH_LOG")" 'landed task made an unnecessary forge read'
pass 'a squash-merged task head whose remote task branch is gone is not flagged'

new_world follow-up
squash_merge_into_origin_main HEAD
printf 'follow-up\n' > "$PROJECT/follow-up.txt"
git -C "$PROJECT" add follow-up.txt
git -C "$PROJECT" -c user.name=Test -c user.email=test@example.com commit -qm follow-up
out=$(scan)
assert_contains "$out" 'branch=fm/task' 'a prior merge hid newer local commits'
assert_contains "$out" 'commits=2' 'wrong follow-up reachability count'
pass 'local commits newer than a merged head stay flagged'

squash_then_edit_same_hunk() {
  local tree commit
  squash_merge_into_origin_main HEAD
  git -C "$PROJECT" checkout -q refs/remotes/origin/main
  printf 'main edit\n' > "$PROJECT/change.txt"
  tree=$(git -C "$PROJECT" add change.txt && git -C "$PROJECT" write-tree)
  commit=$(printf 'main edit\n' | git -C "$PROJECT" -c user.name=Test -c user.email=test@example.com \
    commit-tree "$tree" -p refs/remotes/origin/main)
  git -C "$PROJECT" update-ref refs/remotes/origin/main "$commit"
  git -C "$PROJECT" checkout -qf fm/task
}

new_world merged-head-conflict
squash_then_edit_same_hunk
assert_contains "$(scan)" 'merged=none' 'a conflicting content proof without a merged head was not flagged'
assert_equals '' "$(FM_GH_MERGED_HEAD="$(git -C "$PROJECT" rev-parse HEAD)" scan)" \
  'a merged PR at the exact local head was flagged after main edited the same hunk'
pass 'a merged PR at the exact local head proves landing when the content proof conflicts'

new_world merged-older-head
squash_then_edit_same_hunk
merged_head=$(git -C "$PROJECT" rev-parse HEAD)
printf 'follow-up\n' > "$PROJECT/follow-up.txt"
git -C "$PROJECT" add follow-up.txt
git -C "$PROJECT" -c user.name=Test -c user.email=test@example.com commit -qm follow-up
out=$(FM_GH_MERGED_HEAD=$merged_head scan)
assert_contains "$out" 'branch=fm/task' 'an older merged head under the branch name hid newer local commits'
assert_contains "$out" 'merged=none' 'an older merged head was treated as this head'
pass 'local commits beyond a merged PR head stay flagged'

new_world merged-lookup-failure
squash_then_edit_same_hunk
out=$(FM_GH_API_FAIL=1 FM_GH_MERGED_HEAD="$(git -C "$PROJECT" rev-parse HEAD)" scan)
assert_contains "$out" 'branch=fm/task' 'a failed merged-proof read hid the branch'
assert_contains "$out" 'merged=unknown' 'a failed merged-proof read became a definite answer'
pass 'a failed merged-proof lookup keeps the branch flagged as unknown'

new_world merged-fork-head
git -C "$PROJECT" remote set-url origin https://github.com/forker/demo.git
git -C "$PROJECT" remote add upstream https://github.com/example/demo.git
squash_then_edit_same_hunk
merged_head=$(git -C "$PROJECT" rev-parse HEAD)
assert_equals '' "$(FM_GH_MERGED_OWNER=forker FM_GH_MERGED_HEAD=$merged_head scan)" \
  'a merged PR from the origin fork at the exact local head was flagged'
printf 'follow-up\n' > "$PROJECT/follow-up.txt"
git -C "$PROJECT" add follow-up.txt
git -C "$PROJECT" -c user.name=Test -c user.email=test@example.com commit -qm follow-up
out=$(FM_GH_MERGED_OWNER=forker FM_GH_MERGED_HEAD=$merged_head scan)
assert_contains "$out" 'branch=fm/task' 'a merged fork PR hid newer local commits'
assert_contains "$out" 'merged=none' 'an older merged fork head was treated as this head'
pass 'a fork PR head is looked up in origin and still binds to the exact local head'

new_world base-branch
git -C "$PROJECT" update-ref refs/remotes/origin/release refs/remotes/origin/main
printf 'base_branch=release\n' >> "$FM_HOME/state/task.meta"
squash_merge_into_origin_main HEAD
assert_contains "$(scan)" 'branch=fm/task' 'default branch content hid work owed to the recorded base branch'
git -C "$PROJECT" update-ref refs/remotes/origin/release refs/remotes/origin/main
assert_equals '' "$(scan)" 'work landed on the recorded base branch was flagged'
pass 'the landed proof uses the recorded base branch'

new_world proxy
git -C "$PROJECT" update-ref refs/remotes/no-mistakes/task HEAD
assert_contains "$(scan)" 'branch=fm/task' 'pipeline proxy hid unpublished commits'
pass 'a local no-mistakes proxy ref is not publication evidence'

new_world custom
printf '%s\n' '- demo [no-mistakes branch=work/] - fixture' > "$FM_HOME/data/projects.md"
git -C "$PROJECT" branch -m work/task
sed -i.bak 's@branch=fm/task@branch=work/task@' "$FM_HOME/state/task.meta"
assert_contains "$(scan)" 'branch=work/task' 'custom prefix was ignored'
rm "$FM_HOME/state/task.meta"
assert_contains "$(scan)" 'branch=work/task' 'custom prefix orphan was ignored'
pass 'registered task branch prefixes are respected'

new_world legacy-branch
git -C "$PROJECT" branch -m older/task
sed -i.bak 's@branch=fm/task@branch=older/task@' "$FM_HOME/state/task.meta"
assert_contains "$(scan)" 'owner=recorded' 'exact task metadata outside the current prefix was ignored'
pass 'recorded branches remain discoverable after a prefix change'

new_world wrong-owner
other="$FM_HOME/other-project"
mkdir -p "$other"
git -C "$other" init -q -b main
git -C "$other" -c user.name=Test -c user.email=test@example.com commit -qm base --allow-empty
printf 'project=%s\nbranch=fm/task\nkind=ship\nmode=local-only\n' "$other" > "$FM_HOME/state/task.meta"
out=$(scan)
assert_contains "$out" 'branch=fm/task' 'another project mode hid the branch'
assert_contains "$out" 'owner=missing' 'another repository claimed the branch by name alone'
pass 'identical branch names in distinct repositories cannot claim or suppress each other'

new_world local-only
printf '%s\n' '- demo [local-only] - fixture' > "$FM_HOME/data/projects.md"
assert_equals '' "$(scan)" 'local-only project was flagged'
assert_equals '' "$(cat "$FM_GH_LOG")" 'local-only project queried the forge'
printf '%s\n' '- demo [no-mistakes] - fixture' > "$FM_HOME/data/projects.md"
sed -i.bak 's/mode=no-mistakes/mode=local-only/' "$FM_HOME/state/task.meta"
assert_equals '' "$(scan)" 'local-only task was flagged'
pass 'local-only projects and per-task delivery choices are not asked to publish'

new_world lookup-failure
out=$(FM_GH_FAIL=1 scan)
assert_contains "$out" 'branch=fm/task' 'forge error hid the branch'
assert_contains "$out" 'pr=unknown' 'forge error became missing PR'
pass 'forge failure cannot masquerade as an absent PR'

new_world bounded
git -C "$PROJECT" branch fm/another
out=$(FM_UNPUSHED_TIMEOUT_SECS=20 FM_GH_SLEEP=60 scan)
assert_contains "$out" 'branch=fm/task' 'timeout hid the branch'
assert_contains "$out" 'branch=fm/another' 'slow comparison hid another local branch'
assert_contains "$out" 'incomplete' 'timeout became success'
pass 'a slow forge read retains all discovered branches and an incomplete scan'

new_world deadline
# As in the startup stage, inventory comes first so a deadline cut, however
# little time it leaves on a loaded host, still names the discovered branch.
deadline_work="$TMP_ROOT/deadline-work"
mkdir -m 700 "$deadline_work"
bash "$ROOT/bin/fm-unpushed-reconcile.sh" discover --work-dir "$deadline_work" >/dev/null
deadline=$(( $(date +%s) + 20 ))
# Time spent before the scan reaches its timer, as on a loaded host, must come
# out of the caller's deadline rather than extend past it.
sleep 4
out=$(FM_UNPUSHED_DEADLINE=$deadline FM_UNPUSHED_TIMEOUT_SECS=20 FM_GH_SLEEP=60 \
  bash "$ROOT/bin/fm-unpushed-reconcile.sh" scan --work-dir "$deadline_work")
finished=$(date +%s)
[ "$finished" -le "$deadline" ] || fail "the scan ended at $finished, after its deadline $deadline"
assert_contains "$out" 'branch=fm/task' 'the deadline hid the branch'
assert_contains "$out" 'incomplete' 'the deadline cut became success'
: > "$FM_GH_LOG"
out=$(FM_UNPUSHED_DEADLINE=$(( $(date +%s) - 1 )) scan)
assert_contains "$out" 'incomplete' 'a passed deadline became success'
assert_equals '' "$(cat "$FM_GH_LOG")" 'a passed deadline still read the forge'
rc=0
FM_UNPUSHED_DEADLINE=soon scan >/dev/null 2>&1 || rc=$?
assert_equals 2 "$rc" 'an invalid deadline was accepted'
pass 'a caller deadline bounds the scan from where its timer starts'

new_world stray-group
group_work="$TMP_ROOT/stray-group-work"
mkdir -m 700 "$group_work"
rm -f "$TMP_ROOT/gh.pid"
# The caller's kill reaches only the scanner, as when a stage bound fires
# while the timed scan is still reading the forge.
FM_UNPUSHED_TIMEOUT_SECS=60 FM_GH_SLEEP=60 FM_GH_PID="$TMP_ROOT/gh.pid" \
  bash "$ROOT/bin/fm-unpushed-reconcile.sh" scan --work-dir "$group_work" >/dev/null &
scan_pid=$!
for _ in $(seq 1 300); do
  [ ! -s "$TMP_ROOT/gh.pid" ] || break
  sleep 0.1
done
[ -s "$TMP_ROOT/gh.pid" ] || fail 'the scan never reached its forge read'
forge_pid=$(cat "$TMP_ROOT/gh.pid")
kill -KILL "$scan_pid"
wait "$scan_pid" 2>/dev/null || true
kill -0 "$forge_pid" 2>/dev/null || fail 'killing the scanner alone already ended its timed scan'
out=$(bash "$ROOT/bin/fm-unpushed-reconcile.sh" pending --work-dir "$group_work")
for _ in 1 2 3 4 5; do
  kill -0 "$forge_pid" 2>/dev/null || break
  sleep 0.2
done
if kill -0 "$forge_pid" 2>/dev/null; then
  kill "$forge_pid" 2>/dev/null || true
  fail 'the replay left the cut-short scan reading the forge'
fi
assert_contains "$out" 'branch=fm/task' 'the replay lost the discovered branch'
pass 'replaying a cut-short scan ends the timed scan its caller could not reach'

# A recorded group that is not this work directory's live scan is never ended.
printf '%s\n' "$(ps -o pgid= -p $$ | tr -d ' ')" > "$group_work/group"
bash "$ROOT/bin/fm-unpushed-reconcile.sh" pending --work-dir "$group_work" >/dev/null
if command -v perl >/dev/null 2>&1; then
  perl -MPOSIX=setpgid -e 'setpgid(0, 0); exec "sleep", "30"' &
  other=$!
  sleep 0.5
  printf '%s\n' "$other" > "$group_work/group"
  bash "$ROOT/bin/fm-unpushed-reconcile.sh" pending --work-dir "$group_work" >/dev/null
  kill -0 "$other" 2>/dev/null || fail 'the replay ended an unrelated process group'
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
fi
pass 'the replay never ends its own or an unrelated process group'

# A timed scan that starts after the caller's deadline reads nothing.
: > "$FM_GH_LOG"
rc=0
FM_UNPUSHED_WORK=$group_work FM_UNPUSHED_DEADLINE=$(( $(date +%s) - 1 )) \
  bash "$ROOT/bin/fm-unpushed-reconcile.sh" --scan "$group_work" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'a scan started after its deadline reported success'
assert_equals '' "$(cat "$FM_GH_LOG")" 'a scan started after its deadline still read the forge'
pass 'a timed scan that starts after its deadline stops before any read'

new_world resolved-blocker
printf 'resolved [at=101] [key=nm-daemon-gate-context]: retry authorized\n' >> "$FM_HOME/state/task.status"
out=$(scan)
assert_contains "$out" 'branch=fm/task' 'resolved blocker hid unpublished work'
if printf '%s\n' "$out" | grep -q 'nm-daemon-gate-context'; then
  fail 'resolved blocker was still reported as open'
fi
pass 'resolved blockers are folded by the existing status owner'

echo '# fm-unpushed-reconcile.test.sh: all assertions passed'
