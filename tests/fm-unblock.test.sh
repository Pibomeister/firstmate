#!/usr/bin/env bash
# tests/fm-unblock.test.sh - the dry-run auto-unblocker (bin/fm-unblock.sh) and
# the task snapshot it reads (bin/fm-task-snapshot.sh), on fixture homes.
# docs/supervision-events.md owns both contracts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-unblock)
NOW=1800000000   # 2027-01-15T08:00:00Z

# Sets HOME_DIR and LEDGER for one isolated case. The stub ledger prints the
# file next-item when it exists, and otherwise reports nothing ready.
make_home() {  # <name>
  HOME_DIR="$TMP_ROOT/$1"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
  LEDGER="$HOME_DIR/ledger"
  cat > "$LEDGER" <<SH
#!/usr/bin/env bash
[ -s "$HOME_DIR/next-item" ] || exit 3
printf 'NEXT %s project=demo kind=ship priority=1\n' "\$(cat "$HOME_DIR/next-item")"
SH
  chmod +x "$LEDGER"
}

# add_task <task> [spawn-gen]: a live ship task with an empty inbox.
add_task() {
  mkdir -p "$HOME_DIR/state/$1.inbox/handled"
  printf 'kind=ship\nproject=demo\nmode=no-mistakes\nyolo=off\nbackend=orca\nwindow=fm-%s\nterminal=term_%s\norca_worktree_id=wt-%s\nspawn_gen=%s\n' \
    "$1" "$1" "$1" "${2:-s1.1.1}" > "$HOME_DIR/state/$1.meta"
  printf 'working [at=1799000000]: under way\n' > "$HOME_DIR/state/$1.status"
}

# queue_msg <task> <name> <utc-at> [fire-and-forget]
queue_msg() {
  {
    printf 'schema=fm-task-inbox.v1\nat=%s\n' "$3"
    [ -z "${4:-}" ] || printf 'delivery=fire-and-forget\n'
    printf -- '--\nplease continue\n'
  } > "$HOME_DIR/state/$1.inbox/$2"
}

composer() {  # <task> <verdict> <epoch>
  printf '%s\t%s\n' "$2" "$3" > "$HOME_DIR/state/$1.inbox/.composer"
}

last_ring() {  # <task> <msg> <result> <epoch>
  printf '%s\t%s\t%s\n' "$2" "$3" "$4" > "$HOME_DIR/state/$1.inbox/.last-ring"
}

unblock() {  # <args...>: run in the case home; output in OUT, exit in RC
  OUT=$(FM_HOME="$HOME_DIR" FM_HOST_ID_OVERRIDE=test-host FM_UNBLOCK_NOW=$NOW FM_UNBLOCK_LEDGER="$LEDGER" \
    "$ROOT/bin/fm-unblock.sh" "$@" 2>"$HOME_DIR/stderr")
  RC=$?
}

verdicts() {  # -> one "<action> <verdict> <reason>" line per decision in OUT
  [ -z "$OUT" ] || printf '%s\n' "$OUT" | jq -r '"\(.action) \(.verdict) \(.reason)"'
}

test_a_stale_heartbeat_alone_names_no_action() {
  make_home stale-heartbeat
  add_task t1
  # Everything that looks dead: an ancient status line, beat, and live file.
  printf 'working [at=1000]: long ago\n' > "$HOME_DIR/state/t1.status"
  printf '1000\n' > "$HOME_DIR/state/.t1.fleet-ledger-beat"
  printf '{"v":1,"ts":1000,"task":"t1","kind":"ship","dialog":{"state":"none","at":1000}}\n' > "$HOME_DIR/state/t1.live.json"
  composer t1 unknown 1000
  unblock plan
  assert_equals 0 "$RC" "plan exit"
  assert_equals '' "$OUT" "decisions for a task with only a stale heartbeat"
  pass "unblock: a stale heartbeat, old status line, and old live file alone name no action"
}

test_a_stalled_message_on_a_proven_empty_input_line_is_a_resume_candidate() {
  make_home candidate
  add_task t1 s9.9.9
  queue_msg t1 004.msg 2027-01-15T07:00:00Z
  last_ring t1 004.msg composer-pending 1799999000
  composer t1 empty $((NOW - 30))
  unblock plan
  assert_equals 0 "$RC" "plan exit"
  assert_equals 'resume candidate stalled-on-unacknowledged-message' "$(verdicts)" "decision"
  assert_equals '["resume:t1:004.msg@s9.9.9","s9.9.9",3600,{"ring":"004.msg","draft_guard":"strict"},"dry-run"]' \
    "$(printf '%s\n' "$OUT" | jq -c '[.stall_key, .epoch, .waited_secs, .would, .mode]')" "candidate shape"
  assert_equals '["unblock.decision","test-host"]' \
    "$(printf '%s\n' "$OUT" | jq -c '[.event, (if .source.machine_id then "test-host" else null end)]')" "decision envelope"
  [ ! -e "$HOME_DIR/state/unblock.jsonl" ] && [ ! -e "$HOME_DIR/state/unblock" ] \
    || fail "plan wrote unblock records"
  pass "unblock: a stalled ordinary message on a freshly proven empty input line is one strict resume candidate, and plan writes nothing"
}

test_every_unsafe_or_ambiguous_stall_is_held() {
  local spec task want
  make_home holds
  # <task>|<expected decision>; each task differs from a candidate in one fact.
  for spec in \
    'rang|resume hold ambiguous-delivery:rang-without-pickup' \
    'sendfail|resume hold ambiguous-delivery:send-failed' \
    'unproven|resume hold ambiguous-delivery:input-line-unreadable' \
    'gone|resume hold endpoint-gone' \
    'draft|resume hold input-line-not-proven-empty' \
    'unread|resume hold input-line-not-proven-empty' \
    'oldread|resume hold input-line-reading-stale' \
    'decision|resume hold open-human-gate' \
    'paused|resume hold declared-wait' \
    'done|resume hold worker-reported-final-state' \
    'dialog|resume hold dialog-needs-answer' \
    'nogen|resume hold no-spawn-generation'; do
    task=${spec%%|*}
    add_task "$task"
    queue_msg "$task" 001.msg 2027-01-15T07:00:00Z
    composer "$task" empty $((NOW - 30))
  done
  last_ring rang 001.msg rang 1799999000
  last_ring sendfail 001.msg send-failed 1799999000
  last_ring unproven 001.msg composer-unproven 1799999000
  last_ring gone 001.msg endpoint-gone 1799999000
  composer draft pending $((NOW - 30))
  rm -f "$HOME_DIR/state/unread.inbox/.composer"
  composer oldread empty $((NOW - 600))
  printf 'needs-decision [key=shape] [at=1799990000]: pick one\n' >> "$HOME_DIR/state/decision.status"
  printf 'paused [at=1799990000]: waiting on the upstream release\n' >> "$HOME_DIR/state/paused.status"
  printf 'done [at=1799990000]: finished\n' >> "$HOME_DIR/state/done.status"
  printf '{"v":1,"ts":%s,"task":"dialog","kind":"ship","dialog":{"state":"permission","at":%s}}\n' "$NOW" "$NOW" \
    > "$HOME_DIR/state/dialog.live.json"
  sed -i.bak '/^spawn_gen=/d' "$HOME_DIR/state/nogen.meta"
  # Not stalls at all: a young message and a fire-and-forget one.
  add_task young
  queue_msg young 001.msg 2027-01-15T07:59:00Z
  composer young empty $((NOW - 30))
  add_task ff
  queue_msg ff 001.msg 2027-01-15T07:00:00Z fire-and-forget
  composer ff empty $((NOW - 30))
  unblock plan
  assert_equals 0 "$RC" "plan exit"
  for spec in \
    'rang|resume hold ambiguous-delivery:rang-without-pickup' \
    'sendfail|resume hold ambiguous-delivery:send-failed' \
    'unproven|resume hold ambiguous-delivery:input-line-unreadable' \
    'gone|resume hold endpoint-gone' \
    'draft|resume hold input-line-not-proven-empty' \
    'unread|resume hold input-line-not-proven-empty' \
    'oldread|resume hold input-line-reading-stale' \
    'decision|resume hold open-human-gate' \
    'paused|resume hold declared-wait' \
    'done|resume hold worker-reported-final-state' \
    'dialog|resume hold dialog-needs-answer' \
    'nogen|resume hold no-spawn-generation'; do
    task=${spec%%|*}
    want=${spec#*|}
    # shellcheck disable=SC2016 # $t is a jq variable.
    assert_equals "$want" "$(printf '%s\n' "$OUT" | jq -r --arg t "$task" 'select(.task == $t) | "\(.action) \(.verdict) \(.reason)"')" "decision for $task"
  done
  assert_equals 12 "$(printf '%s\n' "$OUT" | grep -c .)" "decision count (young and fire-and-forget messages are not stalls)"
  assert_equals '[]' "$(printf '%s\n' "$OUT" | jq -sc '[.[] | select(.would != null)]')" "held decisions name no action"
  pass "unblock: ambiguous deliveries, unproven input lines, gates, waits, final states, dialogs, and unbound epochs are all held"
}

test_a_fire_and_forget_message_ahead_never_hides_an_ordinary_stall() {
  make_home ff-ahead
  add_task t1 s3.3.3
  # A fire-and-forget nudge at a lower sequence number, then a stalled steer.
  queue_msg t1 001.msg 2027-01-15T06:00:00Z fire-and-forget
  queue_msg t1 002.msg 2027-01-15T07:00:00Z
  composer t1 empty $((NOW - 30))
  unblock plan
  assert_equals 0 "$RC" "plan exit"
  assert_equals 'resume candidate stalled-on-unacknowledged-message' "$(verdicts)" "decision"
  assert_equals '["002.msg","resume:t1:002.msg@s3.3.3",3600,{"ring":"002.msg","draft_guard":"strict"}]' \
    "$(printf '%s\n' "$OUT" | jq -c '[.msg, .stall_key, .waited_secs, .would]')" "the ordinary steer is the candidate"
  OUT=$(FM_HOME="$HOME_DIR" FM_HOST_ID_OVERRIDE=test-host "$ROOT/bin/fm-task-snapshot.sh" t1)
  assert_equals '["001.msg","fire-and-forget","002.msg",true]' \
    "$(printf '%s\n' "$OUT" | jq -c '[.queue.oldest, .queue.oldest_delivery, .queue.oldest_ordinary, (.queue.oldest_ordinary_queued_at | type == "number")]')" \
    "snapshot queue"
  pass "unblock: a fire-and-forget message queued ahead never hides a stalled ordinary steer"
}

test_observe_claims_one_epoch_bound_action_per_stall() {
  make_home observe
  add_task t1 s1.1.1
  queue_msg t1 002.msg 2027-01-15T07:00:00Z
  composer t1 empty $((NOW - 30))
  unblock observe
  assert_equals 3 "$RC" "observe without config/auto-unblock"
  assert_contains "$(cat "$HOME_DIR/stderr")" "refused" "refusal text"
  printf 'off\n' > "$HOME_DIR/config/auto-unblock"
  unblock observe
  assert_equals 3 "$RC" "observe while auto-unblock is off"
  printf 'observe\n' > "$HOME_DIR/config/auto-unblock"
  unblock observe
  assert_equals 0 "$RC" "first observe exit"
  assert_equals 'resume candidate stalled-on-unacknowledged-message' "$(verdicts)" "first observe decision"
  assert_equals 'unblock.decision' "$(printf '%s\n' "$OUT" | jq -r .event)" "printed event of a recorded candidate"
  assert_equals '["unblock.candidate","resume:t1:002.msg@s1.1.1"]' \
    "$(jq -c '[.event, .stall_key]' "$HOME_DIR/state/unblock.jsonl")" "recorded candidate"
  unblock observe
  assert_equals 'resume claimed already-claimed-this-epoch' "$(verdicts)" "second observe decision"
  assert_equals 'null' "$(printf '%s\n' "$OUT" | jq -c .would)" "a claimed stall names no action"
  assert_equals "$(jq -r .scope_id "$HOME_DIR/state/producer-identity.json")" \
    "$(printf '%s\n' "$OUT" | jq -r .claimed_by.scope_id)" "claim owner"
  assert_equals 1 "$(grep -c . "$HOME_DIR/state/unblock.jsonl")" "records after a repeat"
  # A relaunch is a new epoch for the same message.
  sed -i.bak 's/^spawn_gen=.*/spawn_gen=s2.2.2/' "$HOME_DIR/state/t1.meta"
  unblock observe
  assert_equals 'resume candidate stalled-on-unacknowledged-message' "$(verdicts)" "decision after a relaunch"
  assert_equals '["resume:t1:002.msg@s1.1.1","resume:t1:002.msg@s2.2.2"]' \
    "$(jq -sc '[.[].stall_key]' "$HOME_DIR/state/unblock.jsonl")" "records after a relaunch"
  # Claims of a task whose meta is gone are pruned.
  rm -f "$HOME_DIR/state/t1.meta"
  unblock observe
  assert_equals '' "$(find "$HOME_DIR/state/unblock" -name 'resume_*' -print)" "claims left after cleanup"
  pass "unblock: observe is opt-in, claims each stall once per epoch for one owner, never repeats it, and starts a new epoch on relaunch"
}

test_dispatch_names_only_the_next_ready_item() {
  make_home dispatch
  unblock plan
  assert_equals '' "$OUT" "decisions with nothing ready"
  printf 'item-7\n' > "$HOME_DIR/next-item"
  unblock plan
  assert_equals 'dispatch candidate ready-backlog-item' "$(verdicts)" "ready item decision"
  assert_equals '["dispatch:item-7",{"dispatch":"item-7","ledger":"NEXT item-7 project=demo kind=ship priority=1"}]' \
    "$(printf '%s\n' "$OUT" | jq -c '[.stall_key, .would]')" "dispatch candidate shape"
  add_task item-7
  unblock plan
  assert_equals 'dispatch hold task-already-live' "$(verdicts)" "ready item that is already live"
  rm -f "$HOME_DIR/state/item-7.meta" "$HOME_DIR/state/item-7.status"
  printf 'observe\n' > "$HOME_DIR/config/auto-unblock"
  unblock observe
  unblock observe
  assert_equals 'dispatch claimed already-claimed-this-epoch' "$(verdicts)" "repeat dispatch decision"
  assert_equals 1 "$(grep -c . "$HOME_DIR/state/unblock.jsonl")" "dispatch records"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$LEDGER"
  unblock plan
  assert_equals 'dispatch hold backlog-unreadable' "$(verdicts)" "unreadable backlog"
  pass "unblock: dispatch names only the ledger's next ready item, once, and holds when it is live or the backlog is unreadable"
}

test_enforce_is_always_refused() {
  local mode
  make_home enforce
  add_task t1
  queue_msg t1 001.msg 2027-01-15T07:00:00Z
  composer t1 empty $((NOW - 30))
  for mode in '' observe enforce; do
    if [ -n "$mode" ]; then printf '%s\n' "$mode" > "$HOME_DIR/config/auto-unblock"; fi
    unblock enforce
    assert_equals 3 "$RC" "enforce with auto-unblock '$mode'"
  done
  [ ! -e "$HOME_DIR/state/unblock.jsonl" ] || fail "enforce wrote a record"
  unblock plan --bogus
  assert_equals 2 "$RC" "unknown option"
  pass "unblock: enforce is refused under every configuration and writes nothing"
}

test_snapshot_keeps_the_native_incarnation_apart_from_the_spawn_generation() {
  local snap
  make_home snapshot
  add_task t1 s5.5.5
  queue_msg t1 003.msg 2027-01-15T07:00:00Z
  printf 'needs-decision [key=api] [at=1799990000]: pick a shape\n' >> "$HOME_DIR/state/t1.status"
  printf 'main\t4242\t1799000000\n' > "$HOME_DIR/state/.lease-t1"
  snap=$(FM_HOME="$HOME_DIR" FM_HOST_ID_OVERRIDE=test-host "$ROOT/bin/fm-task-snapshot.sh" t1) || fail "snapshot failed"
  assert_equals '{"spawn_gen":"s5.5.5","backend":"orca","endpoint":"fm-t1","native":{"terminal":"term_t1","worktree_id":"wt-t1"}}' \
    "$(jq -c .binding <<< "$snap")" "binding"
  assert_equals '["main","4242",1799000000]' "$(jq -c '[.ownership.lease.actor, .ownership.lease.pid, .ownership.lease.epoch]' <<< "$snap")" "lease"
  assert_equals '["needs-decision","api"]' "$(jq -c '[.state.state, .state.key]' <<< "$snap")" "current state"
  assert_equals '[{"key":"api","wait":"decision","state":"needs-decision"}]' \
    "$(jq -c '[.waits.human_gates[] | {key, wait, state}]' <<< "$snap")" "human gates"
  assert_equals '[1,"003.msg","ordinary",null,null]' \
    "$(jq -c '[.queue.queued, .queue.oldest, .queue.oldest_delivery, .queue.composer, .capabilities.composer_readable]' <<< "$snap")" "queue"
  assert_equals '[1799000000,"ship","no-mistakes","off"]' \
    "$(jq -c '[.progress.last_working_at, .authorization.kind, .authorization.mode, .authorization.yolo]' <<< "$snap")" "progress and authorization"
  FM_HOME="$HOME_DIR" FM_HOST_ID_OVERRIDE=test-host "$ROOT/bin/fm-task-snapshot.sh" missing >/dev/null 2>&1
  assert_equals 1 "$?" "snapshot of a task with no meta"
  pass "snapshot: binding keeps the native incarnation apart from the spawn generation, with ownership, state, gates, queue, and progress"
}

test_a_stale_heartbeat_alone_names_no_action
test_a_stalled_message_on_a_proven_empty_input_line_is_a_resume_candidate
test_every_unsafe_or_ambiguous_stall_is_held
test_a_fire_and_forget_message_ahead_never_hides_an_ordinary_stall
test_observe_claims_one_epoch_bound_action_per_stall
test_dispatch_names_only_the_next_ready_item
test_enforce_is_always_refused
test_snapshot_keeps_the_native_incarnation_apart_from_the_spawn_generation
