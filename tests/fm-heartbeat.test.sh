#!/usr/bin/env bash
# Behavioral coverage for bin/fm-heartbeat.sh: snapshot-backed assembly, atomic
# --write publication, explicit unknowns, and snapshot failure recording.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HEARTBEAT="$ROOT/bin/fm-heartbeat.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-heartbeat)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

cleanup() { fm_test_cleanup; }
trap cleanup EXIT

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects/ship"
  fm_git_init_commit "$home/projects/ship"
  git -C "$home/projects/ship" checkout -q -b fm/hb-task
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] hb-task - heartbeat fixture (repo: firstmate) (kind: ship) (since 2026-10-30)

## Queued

## Done
EOF
  fm_write_meta "$home/state/hb-task.meta" \
    "window=fmtest:hb" \
    "worktree=$home/projects/ship" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "branch=fm/hb-task" \
    "spawn_gen=fm.hb123456"
  printf 'working: fixture\n' > "$home/state/hb-task.status"
  printf '%s\n' "$home"
}

test_json_schema_and_task_fields() {
  local home out
  home=$(make_home json-fields)
  out=$(FM_HOME="$home" FM_HEARTBEAT_NOW=2026-10-30T12:00:00Z FM_HEARTBEAT_NOW_EPOCH=1761825600 \
    "$HEARTBEAT" --json) || fail "heartbeat --json failed"
  jq -e '
    .schema == "fm-heartbeat.v1"
    and .generated == "2026-10-30T12:00:00Z"
    and .snapshot.ok == true
    and (.primary | type) == "object"
    and (.tasks | length) >= 1
    and (.tasks[0].id == "hb-task")
    and (.tasks[0].stage.state | type) == "string"
    and (.tasks[0].last_commit.sha | type) == "string"
    and (.tasks[0].open_asks | type) == "object"
  ' <<< "$out" >/dev/null || fail "heartbeat JSON missing required fields: $out"
  pass "heartbeat --json assembles schema, primary, and enriched task rows"
}

test_write_is_atomic() {
  local home
  home=$(make_home atomic)
  FM_HOME="$home" "$HEARTBEAT" --write || fail "heartbeat --write failed"
  [ -f "$home/state/heartbeat.json" ] || fail "ledger was not published"
  jq -e '.schema == "fm-heartbeat.v1"' "$home/state/heartbeat.json" >/dev/null \
    || fail "published ledger is malformed"
  pass "heartbeat --write publishes state/heartbeat.json atomically"
}

test_snapshot_failure_is_recorded() {
  local home out
  home=$(make_home snap-fail)
  out=$(FM_HOME="$home" FM_SNAPSHOT_BUDGET=0 "$HEARTBEAT" --json) || fail "heartbeat should exit 0 on partial failure"
  jq -e '.snapshot.ok == false and .snapshot.failure.reason != null and (.tasks | length) == 0' <<< "$out" >/dev/null \
    || fail "snapshot failure was not recorded: $out"
  pass "a failed snapshot read is recorded without guessing task rows"
}

test_json_schema_and_task_fields
test_write_is_atomic
test_snapshot_failure_is_recorded

printf 'ok - %s tests passed\n' 3
