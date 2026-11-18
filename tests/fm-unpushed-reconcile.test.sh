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
[ "${FM_GH_FAIL:-0}" = 0 ] || exit 1
[ -z "${FM_GH_SLEEP:-}" ] || sleep "$FM_GH_SLEEP"
if [ "${FM_GH_OPEN:-0}" = 1 ]; then
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
out=$(FM_UNPUSHED_TIMEOUT_SECS=2 FM_GH_SLEEP=5 scan)
assert_contains "$out" 'branch=fm/task' 'timeout hid the branch'
assert_contains "$out" 'branch=fm/another' 'slow comparison hid another local branch'
assert_contains "$out" 'incomplete' 'timeout became success'
pass 'a slow forge read retains all discovered branches and an incomplete scan'

new_world resolved-blocker
printf 'resolved [at=101] [key=nm-daemon-gate-context]: retry authorized\n' >> "$FM_HOME/state/task.status"
out=$(scan)
assert_contains "$out" 'branch=fm/task' 'resolved blocker hid unpublished work'
if printf '%s\n' "$out" | grep -q 'nm-daemon-gate-context'; then
  fail 'resolved blocker was still reported as open'
fi
pass 'resolved blockers are folded by the existing status owner'

echo '# fm-unpushed-reconcile.test.sh: all assertions passed'
