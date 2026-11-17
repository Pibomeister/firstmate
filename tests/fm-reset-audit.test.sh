#!/usr/bin/env bash
# Hermetic mission continuity checks through the snapshot/compare public CLI.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUDIT="$ROOT/bin/fm-reset-audit.sh"
TASKS="$ROOT/bin/fm-tasks-axi.sh"
HOLD="$ROOT/bin/fm-captain-hold.sh"
DISPATCH="$ROOT/bin/fm-dispatch-log.sh"
TMP_ROOT=$(fm_test_tmproot fm-reset-audit)
unset FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE
command -v tasks-axi >/dev/null 2>&1 || fail 'tasks-axi is required'

new_home() {
  TEST_HOME="$TMP_ROOT/$1"
  mkdir -p "$TEST_HOME/data" "$TEST_HOME/state" "$TEST_HOME/config"
  printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 100\n' > "$TEST_HOME/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$TEST_HOME/data/backlog.md"
}
audit() { FM_HOME="$TEST_HOME" bash "$AUDIT" "$@"; }
tasks() { FM_HOME="$TEST_HOME" bash "$TASKS" "$@"; }
hold() { FM_HOME="$TEST_HOME" bash "$HOLD" "$@"; }
goal() { FM_HOME="$TEST_HOME" bash "$DISPATCH" "$@"; }
seed() {
  goal received goal-open --summary 'open goal' >/dev/null || fail 'seed goal'
  tasks add queued-one 'queued item, with punctuation' --queue >/dev/null || fail 'seed queued'
  tasks add ship-one 'in flight' --queue >/dev/null || fail 'seed ship'
  tasks start ship-one >/dev/null || fail 'start ship'
  printf 'branch=fm/test\npr=https://github.com/example/project/pull/1\nspawn_gen=123\n' > "$TEST_HOME/state/ship-one.meta"
  hold hold hold-one --title 'Choose the approach' --reason 'decision needed' >/dev/null || fail 'seed hold'
}
snapshot() { audit snapshot --out "$TEST_HOME/$1.json" || fail "snapshot $1"; }
expect_drift() {
  local out rc id
  out=$(audit compare --before "$TEST_HOME/before.json" 2>&1); rc=$?
  expect_code 1 "$rc" 'silent loss fails strict comparison'
  assert_contains "$out" FAIL 'comparison verdict'
  assert_contains "$out" DRIFT 'comparison diagnostic'
  for id in $MISSING; do
    assert_contains "$out" "$id" 'stdout identifies the missing item'
    assert_contains "$(tail -1 "$TEST_HOME/state/reset-audit.tsv")" "$id" 'audit row identifies the missing item'
  done
}

new_home clean
seed
snapshot before
snapshot repeat
cmp -s "$TEST_HOME/before.json" "$TEST_HOME/repeat.json" || fail 'snapshots are not deterministic'
out=$(audit compare --before "$TEST_HOME/before.json" --kind compaction)
expect_code 0 $? 'unchanged compaction'
assert_contains "$out" PASS 'unchanged compaction passes'
out=$(audit compare --before "$TEST_HOME/before.json" --after "$TEST_HOME/repeat.json" --kind handoff)
expect_code 0 $? 'unchanged handoff'
assert_contains "$out" PASS 'unchanged handoff passes'
assert_contains "$(cat "$TEST_HOME/before.json")" '"branch": "fm/test"' 'branch captured'
assert_contains "$(cat "$TEST_HOME/before.json")" 'https://github.com/example/project/pull/1' 'PR captured'
pass 'deterministic snapshots preserve the four mission inventories across both reset kinds'

new_home complete
seed
snapshot before
goal dispatched goal-open --task ship-one >/dev/null || fail 'dispatch transition'
tasks 'done' ship-one >/dev/null || fail 'Done transition'
mv "$TEST_HOME/state/ship-one.meta" "$TEST_HOME/retired-meta"
printf 'Use the first approach.\n' > "$TEST_HOME/answer"
hold answer hold-one --decision-file "$TEST_HOME/answer" >/dev/null || fail 'answer transition'
tasks start queued-one >/dev/null || fail 'queued to in flight'
out=$(audit compare --before "$TEST_HOME/before.json" --kind handoff)
expect_code 0 $? 'accounted transitions'
assert_contains "$out" PASS 'dispatch, Done, answered hold, and queue progress pass'
pass 'durable dispatch, task Done, recorded answer, and queue progress account for open work'

new_home blocked-goal
goal received waiting --summary waiting >/dev/null
snapshot before
goal blocked waiting --reason 'dependency unavailable' >/dev/null
out=$(audit compare --before "$TEST_HOME/before.json")
expect_code 0 $? 'blocked dispatch goal is accounted for'
pass 'a durably blocked goal is an accounted dispatch-ledger terminal transition'

new_home rollback
goal received goal-open --summary 'first attempt' >/dev/null
goal dispatched goal-open --task first-attempt >/dev/null
goal queued goal-open --reason 'retry needed' >/dev/null
snapshot before
head -n 2 "$TEST_HOME/state/dispatch-log.tsv" > "$TEST_HOME/older-ledger"
mv "$TEST_HOME/older-ledger" "$TEST_HOME/state/dispatch-log.tsv"
MISSING=goal:goal-open
expect_drift
goal dispatched goal-open --task second-attempt >/dev/null
out=$(audit compare --before "$TEST_HOME/before.json")
expect_code 0 $? 'a new terminal dispatch record accounts for the retry'
pass 'ledger tail loss cannot reuse an older dispatched event to hide a queued retry'

new_home missing-task
seed
snapshot before
printf 'done: worker finished implementation\n' > "$TEST_HOME/state/ship-one.status"
mv "$TEST_HOME/state/ship-one.meta" "$TEST_HOME/lost-meta"
MISSING=task:ship-one
expect_drift
pass 'a vanished in-flight meta fails even when the worker status says done'

new_home missing-goal
seed
snapshot before
mv "$TEST_HOME/state/dispatch-log.tsv" "$TEST_HOME/lost-goals"
MISSING=goal:goal-open
expect_drift
out=$(audit compare --before "$TEST_HOME/before.json" --no-strict)
expect_code 0 $? 'non-strict loss is report-only'
assert_contains "$out" FAIL 'non-strict still reports failure'
pass 'a lost goal fails strict mode and remains a recorded failure in report-only mode'

new_home missing-hold
seed
snapshot before
tasks unhold hold-one >/dev/null || fail 'lose hold'
MISSING=hold:hold-one
expect_drift
tasks 'done' hold-one >/dev/null || fail 'close without an answer'
expect_drift
pass 'unholding or closing a captain call without its decision record fails'

new_home released
seed
snapshot before
printf 'Resume work. %0700d\n' 0 > "$TEST_HOME/answer"
hold answer hold-one --decision-file "$TEST_HOME/answer" --release >/dev/null || fail 'release with answer'
out=$(audit compare --before "$TEST_HOME/before.json")
expect_code 0 $? 'recorded hold release'
hold hold hold-one --reason 'another decision' >/dev/null || fail 'rehold'
snapshot before
tasks unhold hold-one >/dev/null || fail 'silent second release'
MISSING=hold:hold-one
expect_drift
pass 'a recorded release passes and its stale answer cannot conceal loss of a later hold'

new_home archive
seed
snapshot before
tasks 'done' ship-one >/dev/null || fail 'complete ship'
mv "$TEST_HOME/state/ship-one.meta" "$TEST_HOME/retired-meta"
printf 'Approved.\n' > "$TEST_HOME/answer"
hold answer hold-one --decision-file "$TEST_HOME/answer" >/dev/null || fail 'answer'
# Model tasks-axi retention by moving the Done section to its configured archive.
awk '/^## Done/ { done=1 } done' "$TEST_HOME/data/backlog.md" > "$TEST_HOME/data/done-archive.md"
awk '/^## Done/ { exit } { print }' "$TEST_HOME/data/backlog.md" > "$TEST_HOME/open-only"
mv "$TEST_HOME/open-only" "$TEST_HOME/data/backlog.md"
out=$(audit compare --before "$TEST_HOME/before.json")
expect_code 0 $? 'archived Done and hold answer'
pass 'Done retention preserves completion and captain-answer evidence'

new_home reused
seed
cat > "$TEST_HOME/data/done-archive.md" <<'EOF'
## Done
- [x] ship-one - old finished task (closed 2026-01-01)
- [x] hold-one - old answered call (closed 2026-01-01)
  Resolution recorded by fm-captain-hold.
  Captain decision:
  An old answer.
EOF
snapshot before
mv "$TEST_HOME/state/ship-one.meta" "$TEST_HOME/lost-meta"
tasks 'rm' ship-one >/dev/null || fail 'lose reused task'
tasks 'rm' hold-one >/dev/null || fail 'lose reused hold'
MISSING='task:ship-one hold:hold-one backlog:ship-one backlog:hold-one'
expect_drift
# A new retained close of the same ID is distinct even with identical bytes.
cat >> "$TEST_HOME/data/done-archive.md" <<'EOF'
- [x] ship-one - old finished task (closed 2026-01-01)
EOF
out=$(audit compare --before "$TEST_HOME/before.json" --no-strict)
case "$out" in *task:ship-one*|*backlog:ship-one*) fail 'a new archive occurrence did not account for task completion' ;; esac
assert_contains "$out" hold:hold-one 'old hold answer is still stale'
pass 'stale archive evidence cannot hide deleted reused task IDs or captain holds'

new_home missing-backlog
seed
snapshot before
tasks rm queued-one >/dev/null || fail 'remove queued record'
MISSING=backlog:queued-one
expect_drift
pass 'silent deletion of a queued backlog item fails with its exact ID'

new_home scope
seed
snapshot before
snapshot after
mv "$TEST_HOME/state/dispatch-log.tsv" "$TEST_HOME/lost-goals"
out=$(audit compare --before "$TEST_HOME/before.json" --after "$TEST_HOME/after.json")
expect_code 0 $? 'saved after is independent of live state'
out=$(FM_STATE_OVERRIDE="$TMP_ROOT/other-state" FM_DATA_OVERRIDE="$TMP_ROOT/other-data" audit compare --before "$TEST_HOME/before.json" 2>&1); rc=$?
expect_code 1 "$rc" 'external directory overrides cannot hide live loss'
assert_contains "$out" goal:goal-open 'audit still reads its own home'
new_home other
out=$(audit compare --before "$TMP_ROOT/scope/before.json" 2>&1); rc=$?
expect_code 2 "$rc" 'cross-home comparison refused'
assert_contains "$out" mismatch 'cross-home diagnostic'
printf '{"version":1}\n' > "$TEST_HOME/bad.json"
audit compare --before "$TEST_HOME/bad.json" >/dev/null 2>&1; rc=$?
expect_code 2 "$rc" 'invalid manifest refused'
[ ! -e "$TEST_HOME/state/reset-audit.tsv" ] || fail 'invalid input recorded success'
pass 'offline comparison, home isolation, and manifest validation fail closed'

new_home path-scope
ln -s "$TMP_ROOT/clean/data/backlog.md" "$TEST_HOME/data/linked-backlog"
mv "$TEST_HOME/data/backlog.md" "$TEST_HOME/original-backlog"
mv "$TEST_HOME/data/linked-backlog" "$TEST_HOME/data/backlog.md"
out=$(audit snapshot 2>&1); rc=$?
expect_code 2 "$rc" 'a symlink to another home is refused'
assert_contains "$out" 'outside FM_HOME' 'scope refusal names the boundary'
new_home remote-backend
printf 'backend = "remote"\n' > "$TEST_HOME/.tasks.toml"
out=$(audit snapshot 2>&1); rc=$?
expect_code 2 "$rc" 'a network-capable backend is refused before invocation'
assert_contains "$out" 'non-local or unsupported' 'backend refusal is explicit'
pass 'external symlink targets and unsupported backlog backends cannot escape the local audit'

new_home beads-without-data
printf 'backend = "beads"\n' > "$TEST_HOME/.tasks.toml"
mv "$TEST_HOME/data" "$TEST_HOME/unused-data"
out=$(audit snapshot 2>&1); rc=$?
expect_code 2 "$rc" 'a Beads home without the addressing data directory fails explicitly'
assert_contains "$out" 'data directory is required' 'unsupported home layout cannot emit empty inventories'

new_home partial-list
mkdir -p "$TMP_ROOT/fakebin"
cat > "$TMP_ROOT/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
printf 'count: 2\ntasks[2]{id,state,body,hold_kind,held}:\n  only,queued,"","-",no'
EOF
chmod +x "$TMP_ROOT/fakebin/tasks-axi"
out=$(PATH="$TMP_ROOT/fakebin:$PATH" audit snapshot 2>&1); rc=$?
expect_code 2 "$rc" 'truncated TOON without a final newline is refused'
assert_contains "$out" 'incomplete backlog listing' 'partial listing names the failure'
cat > "$TMP_ROOT/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ -n "${BEADS_DIR+x}${BEADS_DB+x}${BD_DB+x}${TASKS_AXI_OTHER+x}${FM_ROOT_OVERRIDE+x}" ]; then
  printf 'addressing environment leaked\n' >&2
  exit 9
fi
printf 'count: 0\ntasks: 0 tasks in this backlog\n'
EOF
out=$(PATH="$TMP_ROOT/fakebin:$PATH" BEADS_DIR=/elsewhere BEADS_DB=/elsewhere/db BD_DB=/elsewhere/other TASKS_AXI_OTHER=elsewhere FM_ROOT_OVERRIDE=/elsewhere audit snapshot 2>&1); rc=$?
expect_code 0 "$rc" 'inherited addressing is removed before any backlog subprocess'
pass 'partial TOON, unsupported Beads layouts, and inherited adapter redirects fail closed'

new_home retention
snapshot before
{
  for ((i=1; i<=105; i++)); do printf '%s\tcompaction\tPASS\t-\n' "$i"; done
} > "$TEST_HOME/state/reset-audit.tsv"
audit compare --before "$TEST_HOME/before.json" >/dev/null || fail 'bounded log compare'
expect_code 100 "$(wc -l < "$TEST_HOME/state/reset-audit.tsv" | tr -d ' ')" '100 audit rows retained'
expect_code 7 "$(head -1 "$TEST_HOME/state/reset-audit.tsv" | cut -f1)" 'oldest rows pruned'
printf 'held\n' > "$TEST_HOME/state/.reset-audit.lock"
audit compare --before "$TEST_HOME/before.json" >/dev/null 2>&1; rc=$?
expect_code 2 "$rc" 'concurrent writer refused'
expect_code 100 "$(wc -l < "$TEST_HOME/state/reset-audit.tsv" | tr -d ' ')" 'refusal leaves log intact'
pass 'audit log retention is bounded and concurrent writers cannot overwrite it'
