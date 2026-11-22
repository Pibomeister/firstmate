#!/usr/bin/env bash
set -u
. tests/lib.sh
TMP_ROOT=$(fm_test_tmproot fm-large-child-repro)
trap fm_test_cleanup EXIT
LARGE_CHILD_HOME="$TMP_ROOT/large-child-home"
LARGE_PARENT_HOME="$TMP_ROOT/large-parent-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
PARENT_CODE_ROOT="$TMP_ROOT/parent-code-root"
mkdir -p "$PARENT_CODE_ROOT"
WRITER="$ROOT/bin/fm-home-summary-refresh.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
NOW_ONE=2026-08-28T10:00:00Z
EPOCH_ONE=1787911200
large_id_suffix=$(printf 'i%.0s' $(seq 1 110))
mkdir -p "$LARGE_CHILD_HOME/state" "$LARGE_CHILD_HOME/data" \
  "$LARGE_CHILD_HOME/config" "$LARGE_CHILD_HOME/projects" "$LARGE_CHILD_HOME/bin"
printf '# Seeded Firstmate home\n' > "$LARGE_CHILD_HOME/AGENTS.md"
printf 'large-child\n' > "$LARGE_CHILD_HOME/.fm-secondmate-home"
{
  printf '%s\n' '## In flight'
  i=1
  while [ "$i" -le 600 ]; do
    printf '%s\n' "- [ ] orphan-$i-$large_id_suffix - Missing metadata (repo: firstmate) (kind: ship)"
    i=$((i + 1))
  done
  printf '%s\n' '' '## Queued' '' '## Done'
} > "$LARGE_CHILD_HOME/data/backlog.md"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LARGE_CHILD_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$WRITER" || fail "large child home-summary publication failed"
large_child_bytes=$(wc -c < "$LARGE_CHILD_HOME/state/home-summary.json")
[ "$large_child_bytes" -gt 131072 ] && [ "$large_child_bytes" -le 262144 ] \
  || fail "large child ledger did not cross only the per-argument limit: $large_child_bytes"
mkdir -p "$LARGE_PARENT_HOME/state" "$LARGE_PARENT_HOME/data" \
  "$LARGE_PARENT_HOME/config" "$LARGE_PARENT_HOME/projects"
printf -- '- large-child - fixture domain (home: %s; scope: fixture work; projects: firstmate; added 2026-08-28)\n' \
  "$LARGE_CHILD_HOME" > "$LARGE_PARENT_HOME/data/secondmates.md"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' \
  > "$LARGE_PARENT_HOME/data/backlog.md"
fm_write_secondmate_meta "$LARGE_PARENT_HOME/state/large-child.meta" \
  "$LARGE_CHILD_HOME" "fmtest:fm-large-child" firstmate claude
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$PARENT_CODE_ROOT" FM_HOME="$LARGE_PARENT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$SNAPSHOT" --json > "$TMP_ROOT/large-parent-snapshot.json" \
  || fail "parent fleet snapshot failed for a large child ledger"
cp "$LARGE_CHILD_HOME/state/home-summary.json" "$EVIDENCE/large-child-after.json"
cp "$TMP_ROOT/large-parent-snapshot.json" "$EVIDENCE/large-parent-after.json"
jq -e '.secondmate_current.records[0]
  | .provenance.summary_source == "local-ledger"
    and .invalidity.kind == "orphan_in_flight"
    and (.invalidity.ids | length) == 600' \
  "$TMP_ROOT/large-parent-snapshot.json" >/dev/null \
  || fail "parent fleet snapshot did not preserve the large child invalidity"
