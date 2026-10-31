#!/usr/bin/env bash
# Behavioral coverage for bin/fm-heartbeat.sh: snapshot-backed assembly, atomic
# --write publication, explicit unknowns, bounded reads, and watcher poll safety.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HEARTBEAT="$ROOT/bin/fm-heartbeat.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-heartbeat)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
WATCH_PID=

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

cleanup() {
  [ -z "$WATCH_PID" ] || kill -KILL "$WATCH_PID" >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%1\n' ;;
  capture-pane) printf 'fixture pane\n> \n' ;;
esac
exit 0
SH
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/no-mistakes"

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects/ship"
  printf '# fixture home\n' > "$home/AGENTS.md"
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

test_unreadable_fields_report_unknown() {
  local home out
  home=$(make_home unknown-fields)
  fm_write_meta "$home/state/no-wt.meta" \
    "window=fmtest:nwt" \
    "worktree=$home/projects/missing-tree" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "spawn_gen=fm.hb999999"
  printf 'working: no worktree\n' > "$home/state/no-wt.status"
  out=$(FM_HOME="$home" FM_HEARTBEAT_NOW=2026-10-30T12:00:00Z FM_HEARTBEAT_NOW_EPOCH=1761825600 \
    "$HEARTBEAT" --json) || fail "heartbeat --json failed"
  jq -e '
    (.tasks[] | select(.id == "no-wt") | .last_commit.unknown) == true
    and (.tasks[] | select(.id == "no-wt") | .last_push.unknown) == true
    and .primary.last_turn.unknown == true
  ' <<< "$out" >/dev/null || fail "unreadable fields did not report unknown: $out"
  pass "unreadable task and primary fields stay explicitly unknown"
}

test_slow_snapshot_is_bounded() {
  local home slow out started elapsed
  home=$(make_home slow-snap)
  slow="$TMP_ROOT/slow-snapshot.sh"
  cat > "$slow" <<'SH'
#!/usr/bin/env bash
sleep 120
exit 0
SH
  chmod +x "$slow"
  started=$(date +%s)
  out=$(FM_HOME="$home" FM_HEARTBEAT_SNAPSHOT_TIMEOUT=1 FM_HEARTBEAT_SNAPSHOT_SCRIPT="$slow" \
    "$HEARTBEAT" --json) || fail "bounded slow snapshot should still exit 0"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 8 ] || fail "heartbeat waited ${elapsed}s for a slow snapshot"
  jq -e '.snapshot.ok == false and .snapshot.failure.reason != null' <<< "$out" >/dev/null \
    || fail "slow snapshot did not record failure: $out"
  pass "a slow snapshot read is bounded and recorded as failure"
}

test_watcher_poll_survives_slow_heartbeat() {
  local home slow started elapsed
  home=$(make_home watch-slow)
  mkdir -p "$home/projects"
  slow="$TMP_ROOT/watch-slow-snapshot.sh"
  cat > "$slow" <<'SH'
#!/usr/bin/env bash
sleep 120
exit 0
SH
  chmod +x "$slow"
  started=$(date +%s)
  PATH="$FAKEBIN:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_HEARTBEAT_SNAPSHOT_TIMEOUT=1 FM_HEARTBEAT_SNAPSHOT_SCRIPT="$slow" \
    FM_WATCH_ONCE=1 \
    "$WATCH" > "$TMP_ROOT/watch-slow.out" 2> "$TMP_ROOT/watch-slow.err" &
  WATCH_PID=$!
  wait "$WATCH_PID"; local rc=$?
  WATCH_PID=
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -eq 0 ] || fail "watcher poll exited $rc on slow heartbeat: $(cat "$TMP_ROOT/watch-slow.err")"
  [ "$elapsed" -lt 15 ] || fail "watcher poll waited ${elapsed}s on slow heartbeat"
  [ -e "$home/state/.last-watcher-beat" ] || fail "watcher never advanced its liveness beacon"
  [ -f "$home/state/heartbeat.json" ] || fail "watcher poll did not publish heartbeat.json"
  jq -e '.snapshot.ok == false' "$home/state/heartbeat.json" >/dev/null \
    || fail "slow heartbeat did not record snapshot failure in the ledger"
  pass "a slow heartbeat does not block or kill a watcher poll"
}

test_json_schema_and_task_fields
test_write_is_atomic
test_snapshot_failure_is_recorded
test_unreadable_fields_report_unknown
test_slow_snapshot_is_bounded
test_watcher_poll_survives_slow_heartbeat

printf 'ok - %s tests passed\n' 6
