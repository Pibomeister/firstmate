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

new_home provider-switch
goal received switched --summary switched >/dev/null
goal dispatched switched --task ship-switch >/dev/null
goal received waiting --summary waiting >/dev/null
snapshot before
goal failover --task ship-switch --from claude --to codex --reason rate_limit >/dev/null || fail 'record the switch'
goal failover --task captain --from claude --to codex --reason billing >/dev/null || fail 'record the captain switch'
goal failover-skip --task ship-switch --from claude --to codex@hetzner --reason 'host worktree handoff not implemented' >/dev/null || fail 'record the host skip'
out=$(audit compare --before "$TEST_HOME/before.json" 2>&1)
expect_code 0 $? "provider switches keep the ledger readable: $out"
snapshot after
assert_not_contains "$(cat "$TEST_HOME/after.json")" '"captain"' 'a switch adds no goal'
mv "$TEST_HOME/state/dispatch-log.tsv" "$TEST_HOME/lost-goals"
grep -v $'\treceived\twaiting\t' "$TEST_HOME/lost-goals" > "$TEST_HOME/state/dispatch-log.tsv"
MISSING=goal:waiting
expect_drift
pass 'a provider switch neither breaks the dispatch ledger nor hides a lost goal'

new_home rollback
goal received goal-open --summary 'first attempt' >/dev/null
goal dispatched goal-open --task first-attempt >/dev/null
goal queued goal-open --reason 'retry needed' >/dev/null
snapshot before
head -n 2 "$TEST_HOME/state/dispatch-log.tsv" > "$TEST_HOME/older-ledger"
mv "$TEST_HOME/older-ledger" "$TEST_HOME/state/dispatch-log.tsv"
MISSING=goal:goal-open
expect_drift
tail -n 1 "$TEST_HOME/state/dispatch-log.tsv" > "$TEST_HOME/shifted-ledger"
mv "$TEST_HOME/shifted-ledger" "$TEST_HOME/state/dispatch-log.tsv"
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
# Dropping a later archived incarnation must not make an earlier one new.
head -n 2 "$TEST_HOME/data/done-archive.md" > "$TEST_HOME/old-archive"
mv "$TEST_HOME/old-archive" "$TEST_HOME/data/done-archive.md"
MISSING='task:ship-one backlog:ship-one hold:hold-one'
expect_drift
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
printf 'count: 0\ntasks[0]{id,state,body,hold_kind,held}:\n  hidden,queued,"",captain,yes\n'
EOF
out=$(PATH="$TMP_ROOT/fakebin:$PATH" audit snapshot 2>&1); rc=$?
expect_code 2 "$rc" 'TOON rows exceeding the declared count are refused'
cat > "$TMP_ROOT/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
printf 'count: 2\ntasks[1]{id,state,body,hold_kind,held}:\n  only,queued,"","-",no\n'
EOF
out=$(PATH="$TMP_ROOT/fakebin:$PATH" audit snapshot 2>&1); rc=$?
expect_code 2 "$rc" 'inconsistent TOON count declarations are refused'
cat > "$TMP_ROOT/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
printf 'count: 0\ntasks: 0 tasks in this backlog\n\n  hidden,queued,"",captain,yes\n'
EOF
out=$(PATH="$TMP_ROOT/fakebin:$PATH" audit snapshot 2>&1); rc=$?
expect_code 2 "$rc" 'blank lines cannot hide rows after an empty listing'
cat > "$TMP_ROOT/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
printf 'count: 0\ntasks[0]{id,state,body,hold_kind,held}:\n\n  hidden,queued,"",captain,yes\n'
EOF
out=$(PATH="$TMP_ROOT/fakebin:$PATH" audit snapshot 2>&1); rc=$?
expect_code 2 "$rc" 'blank lines cannot hide rows after a zero-row table'
cat > "$TMP_ROOT/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
printf 'count: 0\n  hidden,queued,"",captain,yes\ntasks[0]{id,state,body,hold_kind,held}:\n'
EOF
out=$(PATH="$TMP_ROOT/fakebin:$PATH" audit snapshot 2>&1); rc=$?
expect_code 2 "$rc" 'rows before the table header are refused'
cat > "$TMP_ROOT/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
printf 'count: 0\n  hidden,queued,"",captain,yes\ntasks: 0 tasks in this backlog\n'
EOF
out=$(PATH="$TMP_ROOT/fakebin:$PATH" audit snapshot 2>&1); rc=$?
expect_code 2 "$rc" 'rows before the empty-list representation are refused'
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

# --- The reset lifecycle: one row per handoff and per compaction ------------
at() { local now=$1; shift; FM_TEST_SEAM=1 FM_NOW="$now" audit "$@"; }
waiting() { find "$TEST_HOME/state/reset-audit-pending" -maxdepth 1 -name "*-$1-*.json" 2>/dev/null | wc -l | tr -d ' '; }
rows() { if [ -f "$TEST_HOME/state/reset-audit.tsv" ]; then wc -l < "$TEST_HOME/state/reset-audit.tsv" | tr -d ' '; else echo 0; fi; }
T=1700000000

new_home at-epoch
snapshot before
audit compare --before "$TEST_HOME/before.json" --kind handoff --at 12345 >/dev/null || fail 'compare --at'
[ "$(cat "$TEST_HOME/state/reset-audit.tsv")" = "12345"$'\t'"handoff"$'\t'"PASS"$'\t'"-" ] || fail 'compare --at did not record the given epoch'
audit compare --before "$TEST_HOME/before.json" --at soon >/dev/null 2>&1; rc=$?
expect_code 2 "$rc" 'a non-numeric --at is refused'
expect_code 1 "$(rows)" 'a refused --at records no row'
pass 'compare --at records the reset time rather than the compare time'

new_home handoff-life
seed
audit stage || fail 'stage'
assert_present "$TEST_HOME/state/reset-audit-staged.json" 'stage did not save the snapshot'
tasks add late-item 'filed before the handoff' --queue >/dev/null || fail 'late item'
audit stage --if-absent || fail 'stage --if-absent'
assert_not_contains "$(cat "$TEST_HOME/state/reset-audit-staged.json")" late-item '--if-absent replaced a staged snapshot'
audit stage || fail 'restage'
assert_contains "$(cat "$TEST_HOME/state/reset-audit-staged.json")" late-item 'a later stage did not replace the snapshot'
at "$T" begin --kind handoff --if-staged || fail 'begin handoff'
assert_absent "$TEST_HOME/state/reset-audit-staged.json" 'begin left the staged snapshot behind'
expect_code 1 "$(waiting handoff)" 'the handoff waits for its settle time'
at $((T + 5)) begin --kind handoff --if-staged || fail 'second begin'
expect_code 1 "$(waiting handoff)" 'a second caller recorded the same handoff again'
out=$(at $((T + 599)) settle 2>&1) || fail 'settle before the window'
[ -z "$out" ] || fail "an early settle printed: $out"
expect_code 0 "$(rows)" 'a reset was compared before its settle time'
tasks start queued-one >/dev/null || fail 'the new session dispatches queued work'
out=$(at $((T + 600)) settle 2>&1) || fail 'settle at the window'
[ -z "$out" ] || fail "a passing settle printed: $out"
[ "$(cat "$TEST_HOME/state/reset-audit.tsv")" = "$T"$'\t'"handoff"$'\t'"PASS"$'\t'"-" ] || fail "unexpected row: $(cat "$TEST_HOME/state/reset-audit.tsv")"
expect_code 0 "$(waiting handoff)" 'a settled reset still waits'
at $((T + 1200)) settle >/dev/null 2>&1 || fail 'idle settle'
expect_code 1 "$(rows)" 'one handoff produced more than one row'
out=$(at "$T" begin --kind handoff --if-staged 2>&1) || fail 'begin with nothing staged'
expect_code 0 "$(waiting handoff)" '--if-staged recorded a handoff that nobody staged'
pass 'a staged handoff becomes exactly one PASS row stamped with the time of the reset'

new_home stale-stage
seed
audit stage || fail 'stage'
touch -t 202001010000 "$TEST_HOME/state/reset-audit-staged.json"
tasks add later-item 'filed long after that handoff was written' --queue >/dev/null || fail 'later item'
audit stage --if-absent || fail 'stage --if-absent over an old snapshot'
assert_contains "$(cat "$TEST_HOME/state/reset-audit-staged.json")" later-item '--if-absent kept a snapshot too old to be this handoff'
touch -t 202001010000 "$TEST_HOME/state/reset-audit-staged.json"
at "$T" begin --kind handoff --if-staged || fail 'begin over an old staged snapshot'
expect_code 0 "$(waiting handoff)" 'a handoff that never happened was recorded from its old snapshot'
assert_absent "$TEST_HOME/state/reset-audit-staged.json" 'the old staged snapshot was left to be recorded later'
assert_absent "$TEST_HOME/state/reset-audit.check.sh" 'the check was armed with nothing waiting'
pass 'a staged snapshot older than 30 minutes is replaced by the launcher and never recorded as a handoff'

new_home compaction-loss
seed
at "$T" begin --kind compaction || fail 'begin compaction'
at $((T + 300)) begin --kind compaction || fail 'second compaction'
expect_code 2 "$(waiting compaction)" 'back-to-back compactions wait separately'
tasks rm queued-one >/dev/null || fail 'lose the queued item'
out=$(at $((T + 600)) settle 2>&1); rc=$?
expect_code 0 "$rc" 'a FAIL verdict is reported, not an error'
[ "$out" = "reset audit: open work went missing across the compaction at $T: backlog:queued-one (state/reset-audit.tsv)" ] \
  || fail "unexpected FAIL line: $out"
expect_code 1 "$(rows)" 'the later compaction settled before its own time'
assert_contains "$(cat "$TEST_HOME/state/reset-audit.tsv")" "$T"$'\t'"compaction"$'\t'"FAIL"$'\t'"backlog:queued-one" 'FAIL row'
out=$(at $((T + 900)) settle 2>&1)
assert_contains "$out" "across the compaction at $((T + 300)): backlog:queued-one" 'the second compaction reports its own loss'
expect_code 2 "$(rows)" 'two compactions did not produce two rows'
expect_code 0 "$(waiting compaction)" 'settled compactions still wait'
pass 'each compaction settles at its own time and a loss is one FAIL row plus one line'

new_home verdict-now
seed
at "$T" begin --kind compaction || fail 'begin'
at "$T" begin --kind handoff || fail 'a handoff with nothing staged snapshots now'
out=$(at $((T + 1)) settle --now 2>&1); rc=$?
expect_code 0 "$rc" 'settle --now'
assert_contains "$out" "PASS kind=compaction at=$T" '--now prints the compaction verdict'
assert_contains "$out" "PASS kind=handoff at=$T" '--now prints the handoff verdict'
expect_code 2 "$(rows)" '--now did not settle every waiting reset'
printf 'not a manifest\n' > "$TEST_HOME/state/reset-audit-pending/$T-compaction-1.json"
out=$(at $((T + 1)) settle --now 2>&1); rc=$?
expect_code 1 "$rc" '--now reports a reset it could not compare'
assert_contains "$out" "the compaction at $T could not be audited" 'the unreadable reset is named'
out=$(at $((T + 600)) settle 2>&1) || fail 'settle with an unreadable reset'
[ -z "$out" ] || fail "an unreadable reset inside its grace printed: $out"
assert_present "$TEST_HOME/state/reset-audit-pending/$T-compaction-1.json" 'an unreadable reset was dropped inside its grace'
out=$(at $((T + 4200)) settle 2>&1) || fail 'settle past the grace'
assert_contains "$out" "reset audit: the compaction at $T could not be audited" 'giving up is reported once'
assert_present "$TEST_HOME/state/reset-audit-pending/unreadable/$T-compaction-1.json" 'the unreadable snapshot was not kept'
expect_code 0 "$(waiting compaction)" 'the unreadable reset still waits'
out=$(at $((T + 4800)) settle 2>&1) || fail 'settle after giving up'
[ -z "$out" ] || fail "a given-up reset was reported again: $out"
expect_code 2 "$(rows)" 'an unreadable reset recorded a row'
pass 'settle --now prints every verdict, and an unreadable reset is kept, reported once, and never recorded'

new_home many
seed
snapshot before
mkdir -p "$TEST_HOME/state/reset-audit-pending"
for ((i=1; i<=20; i++)); do cp "$TEST_HOME/before.json" "$TEST_HOME/state/reset-audit-pending/$((T + i))-compaction-$i.json"; done
at $((T + 30)) begin --kind compaction >/dev/null 2>&1; rc=$?
expect_code 1 "$rc" 'a snapshot beyond the cap'
expect_code 20 "$(waiting compaction)" 'a reset beyond the cap was recorded'
expect_code 0 "$(rows)" 'begin settled waiting resets itself'
[ -x "$TEST_HOME/state/reset-audit.check.sh" ] || fail 'a refused reset did not arm the check that settles the others'
audit stage || fail 'stage at the cap'
at $((T + 31)) begin --kind handoff --if-staged || fail 'a staged handoff at the cap'
expect_code 1 "$(waiting handoff)" 'a staged handoff was dropped at the cap'
at $((T + 700)) settle >/dev/null 2>&1 || fail 'settle the waiting resets'
expect_code 21 "$(rows)" 'the waiting resets did not each settle as one row'
at $((T + 701)) begin --kind compaction || fail 'begin after the resets settled'
expect_code 1 "$(waiting compaction)" 'a reset after the cap cleared was not recorded'
pass 'at most 20 resets wait: a further snapshot is refused until one settles, and a staged handoff is still taken'

new_home closing
seed
at "$T" begin --kind compaction || fail 'begin'
: > "$TEST_HOME/state/t-1.backlog-close"
out=$(at $((T + 600)) settle 2>&1) || fail 'settle during a task close'
[ -z "$out" ] || fail "settle during a task close printed: $out"
expect_code 0 "$(rows)" 'a reset was judged while a task close was in progress'
expect_code 1 "$(waiting compaction)" 'the reset no longer waits'
mv "$TEST_HOME/state/t-1.backlog-close" "$TEST_HOME/closed-marker"
at $((T + 660)) settle >/dev/null 2>&1 || fail 'settle after the close'
expect_code 1 "$(rows)" 'the reset did not settle once the close finished'
at "$T" begin --kind compaction || fail 'begin'
printf 'held\n' > "$TEST_HOME/state/.reset-audit.lock"
out=$(at $((T + 600)) settle 2>&1) || fail 'settle beside a held row lock'
[ -z "$out" ] || fail "settle beside a held row lock printed: $out"
expect_code 1 "$(rows)" 'a row was written under a lock another writer holds'
expect_code 1 "$(waiting compaction)" 'a reset that could not be recorded was dropped'
touch -t 202001010000 "$TEST_HOME/state/.reset-audit.lock"
at $((T + 660)) settle >/dev/null 2>&1 || fail 'settle past an orphaned row lock'
expect_code 2 "$(rows)" 'an orphaned row lock still blocked the audit'
pass 'settle waits out a task close in progress, respects a held row lock, and removes an orphaned one'

new_home check
seed
check="$TEST_HOME/state/reset-audit.check.sh"
audit arm --if-needed >/dev/null || fail 'arm --if-needed'
assert_absent "$check" 'the check was armed in a home where nothing waits'
at "$T" begin --kind handoff || fail 'begin'
[ -x "$check" ] || fail 'recording a reset did not install an executable check'
assert_present "$TEST_HOME/state/reset-audit.check-trust" 'recording a reset did not register the check'
audit arm >/dev/null || fail 'arm is not repeatable'
out=$(FM_STATE_OVERRIDE="$TMP_ROOT/elsewhere" FM_TEST_SEAM=1 FM_NOW=$((T + 599)) "$check" 2>&1); rc=$?
expect_code 0 "$rc" 'the check before the settle time'
assert_present "$check" 'the check was retired while a reset still waits'
out=$(FM_STATE_OVERRIDE="$TMP_ROOT/elsewhere" FM_TEST_SEAM=1 FM_NOW=$((T + 600)) "$check" 2>&1); rc=$?
expect_code 0 "$rc" 'the check on a healthy home'
[ -z "$out" ] || fail "the check printed on a healthy home: $out"
[ "$(cat "$TEST_HOME/state/reset-audit.tsv")" = "$T"$'\t'"handoff"$'\t'"PASS"$'\t'"-" ] || fail 'the check did not settle the due reset'
assert_absent "$check" 'the check stayed armed with nothing left to settle'
assert_absent "$TEST_HOME/state/reset-audit.check-trust" 'the retired check stayed registered'
at "$T" begin --kind compaction || fail 'begin'
tasks rm queued-one >/dev/null || fail 'lose the queued item'
out=$(FM_TEST_SEAM=1 FM_NOW=$((T + 600)) "$check" 2>&1)
assert_contains "$out" 'reset audit: open work went missing across the compaction' 'the check reports a loss'
assert_absent "$check" 'the check stayed armed after its last reset settled'
printf 'HANDOFF v1 ts=%s event=handoff_started nonce=0123456789abcdef0123456789abcdef attempt=1 pid=0 handle=%%1 reason=awaiting_ack\n' \
  "$(date +%s)" > "$TEST_HOME/state/handoff-events.log"
printf 'HANDOFF v1 ts=%s event=handoff_reject nonce=0123456789abcdef0123456789abcdef attempt=0 pid=0 handle=%%9 reason=expired_claim\n' \
  "$(date +%s)" >> "$TEST_HOME/state/handoff-events.log"
audit arm --if-needed >/dev/null || fail 'arm --if-needed for a late successor'
[ -x "$check" ] || fail 'a refused late successor did not arm the check'
out=$("$check" 2>&1); rc=$?
expect_code 0 "$rc" 'the check with a late successor'
assert_contains "$out" 'a late successor terminal %9 of a failed handoff attempt was left open (backend_not_orca)' 'the check reports the late successor'
assert_absent "$check" 'the check stayed armed after the late successor was decided'
printf '#!/usr/bin/env bash\necho task-owned\n' > "$check"
audit arm >/dev/null 2>&1; rc=$?
expect_code 2 "$rc" 'arm over a check it did not write'
at "$T" begin --kind compaction || fail 'begin beside a foreign check'
expect_code 1 "$(waiting compaction)" 'a foreign check stopped the reset from being recorded'
audit sweep >/dev/null 2>&1 || fail 'sweep beside a foreign check'
audit disarm >/dev/null 2>&1 || fail 'disarm beside a foreign check'
assert_contains "$(cat "$check")" task-owned 'a check this script did not write was changed'
pass 'the check is armed only while a reset or a late successor waits, stays silent on PASS, and never touches a foreign check'

new_home foreign-dirs
seed
mkdir -p "$TMP_ROOT/elsewhere"
for name in FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE; do
  for command in stage 'begin --kind compaction' 'settle --now' sweep arm; do
    # shellcheck disable=SC2086 # The command words split on purpose.
    out=$(env "$name=$TMP_ROOT/elsewhere" FM_HOME="$TEST_HOME" bash "$AUDIT" $command 2>&1); rc=$?
    expect_code 0 "$rc" "$command under a foreign $name"
    [ -z "$out" ] || fail "$command under a foreign $name printed: $out"
  done
done
assert_absent "$TEST_HOME/state/reset-audit-staged.json" 'a foreign directory override staged a snapshot'
assert_absent "$TEST_HOME/state/reset-audit-pending" 'a foreign directory override recorded a reset'
assert_absent "$TEST_HOME/state/reset-audit.check.sh" 'a foreign directory override armed the check'
FM_STATE_OVERRIDE="$TEST_HOME/state" FM_DATA_OVERRIDE="$TEST_HOME/data" FM_CONFIG_OVERRIDE="$TEST_HOME/config" audit stage || fail 'stage with this home named'
assert_present "$TEST_HOME/state/reset-audit-staged.json" "naming this home's own directories must not disable the audit"
audit begin >/dev/null 2>&1; rc=$?
expect_code 2 "$rc" 'begin without a kind'
audit begin --kind clear >/dev/null 2>&1; rc=$?
expect_code 2 "$rc" 'begin with an unknown kind'
audit begin --kind compaction --if-staged >/dev/null 2>&1; rc=$?
expect_code 2 "$rc" '--if-staged on a compaction'
pass 'the lifecycle commands do nothing for directories outside this home and refuse malformed calls'
