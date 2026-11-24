#!/usr/bin/env bash
# tests/fm-delegated.test.sh - the delegated-agent progress contract
# (bin/fm-delegated.sh, tickets 3a and 9b): a dispatch-only receipt renders
# as dispatched-not-progressing and never as progress; a task silent past
# its window escalates exactly once naming task, age, and last receipt; a
# missing or hash-mismatched artifact cannot close the deliverable; a
# handoff filed only outside the receiver's read location surfaces as a
# delivery failure until mirrored, and once mirrored the receiver's read
# is receipted against path plus hash.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BIN="$ROOT/bin/fm-delegated.sh"
TMP_ROOT=$(fm_test_tmproot fm-delegated)
T0=1800000000

new_home() {  # <name>: fresh home plus artifact/read/alt dirs; prints home
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/state" "$h/config" "$h/art" "$h/read" "$h/alt"
  touch "$h/state/worker.meta"
  printf 'deliverable body\n' > "$h/art/out.txt"
  printf '%s\n' "$h"
}

sha_of() {  # <file>
  shasum -a 256 "$1" | awk '{print $1}'
}

del() {  # <home> <now> <args...>
  local home=$1 now=$2
  shift 2
  env FM_HOME="$home" FM_TEST_SEAM=1 FM_DELEGATED_NOW="$now" bash "$BIN" "$@"
}

register_task() {  # <home> <now> <task>
  del "$1" "$2" register --task "$3" --deliverable postmortem \
    --artifact "$1/art/out.txt" --heartbeat-secs 60 --silence-secs 300 >/dev/null
}

test_dispatch_only_renders_dispatched_not_progressing() {
  local h out
  h=$(new_home dispatch-only)
  register_task "$h" "$T0" hermes-1 || fail "register failed"
  del "$h" $((T0 + 10)) dispatch --task hermes-1 >/dev/null || fail "dispatch failed"
  out=$(del "$h" $((T0 + 20)) view) || fail "view failed"
  assert_contains "$out" "task=hermes-1 state=dispatched-not-progressing" \
    "a dispatch-only receipt renders as dispatched-not-progressing"
  case "$out" in
    *"state=progressing"*) fail "dispatch-only must never render as progressing: $out" ;;
  esac
  pass "a dispatch-only receipt renders as dispatched-not-progressing, never progress"
}

test_silent_task_escalates_exactly_once() {
  local h out1 out2
  h=$(new_home silent)
  register_task "$h" "$T0" hermes-1 || fail "register failed"
  del "$h" $((T0 + 10)) dispatch --task hermes-1 >/dev/null || fail "dispatch failed"
  out1=$(del "$h" $((T0 + 400)) check) || fail "first check failed"
  assert_contains "$out1" "escalation task=hermes-1" "the escalation names the task"
  assert_contains "$out1" "age=390" "the escalation names the silence age"
  assert_contains "$out1" "last_receipt=dispatch@$((T0 + 10))" "the escalation names the last receipt"
  out2=$(del "$h" $((T0 + 500)) check) || fail "second check failed"
  case "$out2" in
    *escalation*) fail "a silent task must escalate exactly once, got a second: $out2" ;;
  esac
  pass "a task silent past its window escalates exactly once naming task, age, and last receipt"
}

test_heartbeat_resets_silence_and_progresses() {
  local h out
  h=$(new_home heartbeat)
  register_task "$h" "$T0" hermes-1 || fail "register failed"
  del "$h" $((T0 + 10)) dispatch --task hermes-1 >/dev/null || fail "dispatch failed"
  del "$h" $((T0 + 200)) heartbeat --task hermes-1 >/dev/null || fail "heartbeat failed"
  out=$(del "$h" $((T0 + 400)) check) || fail "check failed"
  case "$out" in
    *escalation*) fail "a heartbeat inside the window must not escalate: $out" ;;
  esac
  out=$(del "$h" $((T0 + 400)) view) || fail "view failed"
  assert_contains "$out" "state=progressing" "a heartbeat renders as progressing"
  pass "a heartbeat inside the silence window prevents escalation and renders as progressing"
}

test_hash_mismatch_and_missing_cannot_close() {
  local h rc=0 good bad=0000000000000000000000000000000000000000000000000000000000000000
  h=$(new_home mismatch)
  register_task "$h" "$T0" hermes-1 || fail "register failed"
  good=$(sha_of "$h/art/out.txt")
  del "$h" $((T0 + 10)) deliver --task hermes-1 --path "$h/art/out.txt" --hash "$bad" >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" "a hash-mismatched deliver is refused"
  del "$h" $((T0 + 20)) view | grep -q "state=closed" && fail "a hash mismatch closed the deliverable"
  rc=0
  mv "$h/art/out.txt" "$h/art/saved.txt"
  del "$h" $((T0 + 30)) deliver --task hermes-1 --path "$h/art/out.txt" --hash "$good" >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" "a missing artifact deliver is refused"
  del "$h" $((T0 + 40)) view | grep -q "state=closed" && fail "a missing artifact closed the deliverable"
  mv "$h/art/saved.txt" "$h/art/out.txt"
  del "$h" $((T0 + 50)) deliver --task hermes-1 --path "$h/art/out.txt" --hash "$good" >/dev/null \
    || fail "a verified deliver should close"
  assert_contains "$(del "$h" $((T0 + 60)) view)" "state=closed" "a verified receipt closes the deliverable"
  pass "a hash-mismatched or missing artifact cannot close the deliverable; a verified one does"
}

test_hidden_handoff_is_delivery_failure_until_mirrored() {
  local h hash out
  h=$(new_home hidden)
  register_task "$h" "$T0" hermes-1 || fail "register failed"
  hash=$(sha_of "$h/art/out.txt")
  del "$h" "$T0" handoff --task hermes-1 --id hf1 --receiver worker --path "$h/art/out.txt" \
    --hash "$hash" --read-dir "$h/state/worker.inbox" --alt-dir "$h/alt.inbox" --location alt >/dev/null \
    || fail "handoff failed"
  del "$h" "$T0" dispatch --task hermes-1 >/dev/null || fail "dispatch failed"
  out=$(del "$h" $((T0 + 400)) check) || fail "check failed"
  case "$out" in *escalation*) fail "a hidden answer was classified as silence" ;; esac
  assert_contains "$out" "delivery-failure handoff=hf1" "a hidden handoff surfaces as a delivery failure naming it"
  assert_contains "$(del "$h" $((T0 + 20)) view)" "handoff=hf1 state=delivery-failure" "a hidden handoff is unread"
  mkdir -p "$h/state/worker.inbox"
  : > "$h/state/worker.inbox/001.msg"
  del "$h" $((T0 + 30)) mirror --id hf1 >/dev/null || fail "mirror failed"
  out=$(del "$h" $((T0 + 40)) check) || fail "check after mirror failed"
  case "$out" in
    *delivery-failure*) fail "a mirrored handoff must stop surfacing as a delivery failure: $out" ;;
  esac
  assert_contains "$(del "$h" $((T0 + 45)) view)" "handoff=hf1 state=mirrored" "enqueue alone is not a read"
  mv "$h/state/worker.inbox/002.msg" "$h/state/worker.inbox/handled/" || fail "receiver acknowledgement failed"
  out=$(del "$h" $((T0 + 50)) view) || fail "view failed"
  assert_contains "$out" "handoff=hf1 state=read" "the receiver acknowledgement receipts the read"
  assert_contains "$out" "hash=$hash" "the read receipt carries the artifact hash"
  assert_contains "$(del "$h" $((T0 + 60)) view)" "handoff=hf1 state=read" "the view shows the read handoff"
  pass "a handoff filed only in the non-read location is a delivery failure until mirrored, then its read is receipted"
}

test_handoff_in_read_location_and_broken_artifact() {
  local h hash out rc=0
  h=$(new_home readloc)
  register_task "$h" "$T0" hermes-1 || fail "register failed"
  hash=$(sha_of "$h/art/out.txt")
  del "$h" "$T0" handoff --task hermes-1 --id hf1 --receiver worker --path "$h/art/out.txt" \
    --hash "$hash" --read-dir "$h/state/worker.inbox" --alt-dir "$h/alt.inbox" --location read >/dev/null \
    || fail "handoff in read location failed"
  out=$(del "$h" $((T0 + 10)) check) || fail "check failed"
  case "$out" in
    *delivery-failure*) fail "a handoff in the read location is not a delivery failure: $out" ;;
  esac
  printf 'tampered\n' > "$h/art/out.txt"
  mv "$h/state/worker.inbox/001.msg" "$h/state/worker.inbox/handled/" || fail "ack failed"
  assert_contains "$(del "$h" $((T0 + 20)) view)" "handoff=hf1 state=delivery-failure" "a tampered artifact cannot receipt a read"
  rc=0
  del "$h" $((T0 + 30)) handoff --task hermes-1 --id hf2 --receiver worker --path "$h/art/out.txt" \
    --hash "$hash" --read-dir "$h/state/worker.inbox" --alt-dir "$h/alt.inbox" --location read >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" "a handoff with a mismatched artifact receipt is refused at filing"
  pass "a read-location handoff is no failure, and a tampered artifact receipts nothing"
}

test_register_validation() {
  local h rc=0
  h=$(new_home validation)
  del "$h" "$T0" register --task t1 --deliverable postmortem --artifact "$h/art/out.txt" \
    --heartbeat-secs 300 --silence-secs 60 >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "a silence window not exceeding the heartbeat is a usage refusal"
  rc=0
  del "$h" "$T0" register --task 'bad/id' --deliverable postmortem --artifact "$h/art/out.txt" \
    --heartbeat-secs 60 --silence-secs 300 >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "an invalid task id is a usage refusal"
  [ ! -f "$h/state/delegated/t1.record" ] || fail "a refused register wrote a record"
  del "$h" "$T0" view >/dev/null || fail "view over an empty registry should succeed"
  pass "register refuses a window that cannot work and an invalid id, writing nothing"
}

test_wrong_artifact_cannot_close() {
  local h hash
  h=$(new_home wrong-artifact)
  register_task "$h" "$T0" hermes-1 || fail 'register failed'
  cp "$h/art/out.txt" "$h/art/unrelated.txt"
  hash=$(sha_of "$h/art/unrelated.txt")
  if del "$h" "$T0" deliver --task hermes-1 --path "$h/art/unrelated.txt" --hash "$hash"; then
    fail 'an unrelated artifact closed the task'
  fi
  assert_contains "$(del "$h" "$T0" view)" 'state=registered' 'wrong artifact leaves task open'
  pass 'closing requires the registered artifact identity, even for identical bytes'
}

test_concurrent_transactions() {
  local h hash pids='' pid i
  h=$(new_home concurrent)
  register_task "$h" "$T0" hermes-1 || fail 'register failed'
  del "$h" "$T0" dispatch --task hermes-1 >/dev/null
  hash=$(sha_of "$h/art/out.txt")
  for i in 1 2 3 4; do
    del "$h" $((T0 + 400)) check > "$h/check-$i" &
    pids="$pids $!"
  done
  for pid in $pids; do wait "$pid" || fail 'concurrent check failed'; done
  assert_equals 1 "$(cat "$h"/check-* | grep -c '^escalation ')" 'concurrent checks emit exactly one escalation'
  pids=''
  for i in 1 2 3 4; do
    del "$h" $((T0 + 500)) heartbeat --task hermes-1 >/dev/null &
    pids="$pids $!"
  done
  for pid in $pids; do wait "$pid" || fail 'heartbeat failed'; done
  del "$h" $((T0 + 900)) check > "$h/after"
  [ ! -s "$h/after" ] || fail 'heartbeat lost the escalation marker'
  del "$h" $((T0 + 1000)) deliver --task hermes-1 --path "$h/art/out.txt" --hash "$hash" >/dev/null &
  pid=$!
  del "$h" $((T0 + 1100)) check >/dev/null || fail 'racing check failed'
  wait "$pid" || fail 'racing deliver failed'
  assert_contains "$(del "$h" $((T0 + 1200)) view)" 'state=closed' 'check cannot overwrite completion'
  pass 'concurrent checks, heartbeats and delivery preserve state'
}

test_concurrent_mirror_and_ack() {
  local h hash p1 p2
  h=$(new_home concurrent-mirror)
  register_task "$h" "$T0" hermes-1 || fail 'register failed'
  hash=$(sha_of "$h/art/out.txt")
  del "$h" "$T0" handoff --task hermes-1 --id hf1 --receiver worker \
    --path "$h/art/out.txt" --hash "$hash" --read-dir "$h/state/worker.inbox" \
    --alt-dir "$h/alt.inbox" --location alt >/dev/null || fail 'handoff failed'
  del "$h" "$T0" mirror --id hf1 >/dev/null & p1=$!
  del "$h" "$T0" mirror --id hf1 >/dev/null & p2=$!
  wait "$p1" || fail 'first mirror failed'
  wait "$p2" || fail 'second mirror failed'
  set -- "$h/state/worker.inbox/"*.msg
  assert_equals 1 "$#" 'racing mirrors enqueue one message'
  mv "$1" "$h/state/worker.inbox/handled/" || fail 'ack failed'
  del "$h" "$T0" mirror --id hf1 >/dev/null || fail 'mirror after ack failed'
  assert_contains "$(del "$h" "$T0" view)" 'handoff=hf1 state=read' 'mirror preserves acknowledged receipt'
  pass 'mirrors share one numbered inbox message and preserve its acknowledgement'
}

test_watcher_routes_silence() {
  local h pid i=0
  h=$(new_home watcher)
  mkdir -p "$h/config"
  touch "$h/state/home-summary.json"
  register_task "$h" "$T0" hermes-1 || fail 'register failed'
  del "$h" "$T0" dispatch --task hermes-1 >/dev/null
  FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" FM_CONFIG_OVERRIDE="$h/config" \
    FM_DELEGATED_NOW=$((T0 + 400)) bash "$ROOT/bin/fm-watch.sh" > "$h/out" 2> "$h/err" &
  pid=$!
  fm_test_track_watcher_state "$h/state"
  while [ "$i" -lt 300 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"; wait "$pid" 2>/dev/null || true
    fail "watcher failed to wake: $(cat "$h/err")"
  fi
  wait "$pid" || fail "watcher failed: $(cat "$h/err")"
  assert_contains "$(cat "$h/state/.wake-queue")" 'escalation task=hermes-1 age=400 last_receipt=dispatch@' 'real watcher routes silence through durable wake queue'
  assert_contains "$(cat "$h/state/.wake-queue")" 'supervisor=firstmate' 'wake names the stored supervisor'
  pass 'the production watcher automatically routes delegated silence to the supervisor'
}

test_named_supervisor_receives_escalation() {
  local h out
  h=$(new_home supervisor)
  touch "$h/state/supervisor.meta"
  del "$h" "$T0" register --task hermes-1 --deliverable postmortem --artifact "$h/art/out.txt" \
    --heartbeat-secs 60 --silence-secs 300 --supervisor supervisor >/dev/null || fail 'register failed'
  del "$h" "$T0" dispatch --task hermes-1 >/dev/null || fail 'dispatch failed'
  del "$h" $((T0 + 400)) check >/dev/null || fail 'check failed'
  [ -f "$h/state/supervisor.inbox/001.msg" ] || fail 'named supervisor received no inbox notification'
  out=$(FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" bash -c '. "$1"; fm_task_inbox_body "$2"' _ \
    "$ROOT/bin/fm-task-inbox-lib.sh" "$h/state/supervisor.inbox/001.msg")
  assert_contains "$out" 'escalation task=hermes-1 age=400 last_receipt=dispatch@' 'supervisor reads the actual escalation'
  del "$h" $((T0 + 500)) check >/dev/null || fail 'repeat check failed'
  set -- "$h/state/supervisor.inbox/"*.msg
  assert_equals 1 "$#" 'supervisor receives exactly one escalation'
  pass 'silence reaches the named supervisor through the existing numbered inbox'
}

test_primary_handoff_uses_wake_channel() {
  local h hash out seq generation
  h=$(new_home primary-handoff)
  register_task "$h" "$T0" hermes-1 || fail 'register failed'
  hash=$(sha_of "$h/art/out.txt")
  del "$h" "$T0" handoff --task hermes-1 --id answer --receiver firstmate \
    --path "$h/art/out.txt" --hash "$hash" --alt-dir "$h/hosted.inbox" --location alt >/dev/null || fail 'hidden answer failed'
  assert_contains "$(del "$h" $((T0 + 400)) check)" 'delivery-failure handoff=answer' 'hidden primary answer is a delivery failure'
  del "$h" "$T0" mirror --id answer >/dev/null || fail 'primary mirror failed'
  [ ! -e "$h/state/firstmate.inbox" ] || fail 'primary answer was placed in an unread task inbox'
  FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" FM_CONFIG_OVERRIDE="$h/config" \
    bash "$ROOT/bin/fm-wake-drain.sh" > "$h/drained" 2> "$h/drain.err" || fail "drain failed: $(cat "$h/drain.err")"
  out=$(cat "$h/drained")
  assert_contains "$out" "handoff=answer task=hermes-1 receiver=firstmate artifact=$h/art/out.txt hash=$hash" 'the real primary read channel presents the artifact receipt'
  assert_contains "$(del "$h" "$T0" view)" 'handoff=answer state=mirrored' 'presentation alone does not acknowledge consumption'
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$h/drain.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$h/drain.err")
  [ -n "$seq" ] && [ -n "$generation" ] || fail 'primary drain produced no acknowledgement token'
  FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" FM_CONFIG_OVERRIDE="$h/config" \
    bash "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$generation" >/dev/null || fail 'primary acknowledgement failed'
  assert_contains "$(del "$h" "$T0" view)" 'handoff=answer state=read' 'primary acknowledgement receipts the handoff'
  rm -f "$h/art/out.txt"
  del "$h" "$T0" mirror --id answer >/dev/null || fail 'mirror lost the consumed primary receipt'
  out=$(del "$h" $((T0 + 500)) check)
  case "$out" in *delivery-failure*) fail 'consumed primary answer re-alerted after artifact cleanup' ;; esac
  pass 'primary handoffs are presented and acknowledged through the actual wake channel'
}

test_completed_report_operations_preserve_receipt() {
  local h hash report
  h=$(new_home completed-report)
  register_task "$h" "$T0" hermes-1 || fail 'register failed'
  hash=$(sha_of "$h/art/out.txt")
  del "$h" "$T0" deliver --task hermes-1 --path "$h/art/out.txt" --hash "$hash" >/dev/null || fail 'deliver failed'
  cp "$h/state/delegated/hermes-1.record" "$h/completed.record"
  printf 'kind=ship\npromoted_status_lines=1\n' > "$h/state/hermes-1.meta"
  del "$h" $((T0 + 10)) heartbeat --task hermes-1 >/dev/null || fail 'promoted worker heartbeat refused'
  del "$h" $((T0 + 20)) dispatch --task hermes-1 >/dev/null || fail 'replacement launch refused'
  printf 'ship outcome\n' > "$h/art/out.txt"
  report=$(sha_of "$h/art/out.txt")
  del "$h" $((T0 + 30)) deliver --task hermes-1 --path "$h/art/out.txt" --hash "$report" >/dev/null || fail 'promoted worker delivery refused'
  cmp -s "$h/completed.record" "$h/state/delegated/hermes-1.record" || fail 'lifecycle operation discarded the completed report receipt'
  assert_contains "$(del "$h" $((T0 + 40)) view)" 'state=closed' 'fulfilled report remains closed across promotion and relaunch'
  pass 'completed report receipts remain immutable across repeated worker lifecycle operations'
}

test_read_receipt_survives_cleanup() {
  local h hash mode out
  for mode in check view mirror receipt; do
    h=$(new_home "durable-$mode")
    register_task "$h" "$T0" hermes-1 || fail 'register failed'
    hash=$(sha_of "$h/art/out.txt")
    del "$h" "$T0" handoff --task hermes-1 --id answer --receiver worker \
      --path "$h/art/out.txt" --hash "$hash" --alt-dir "$h/hosted.inbox" --location read >/dev/null || fail 'handoff failed'
    mv "$h/state/worker.inbox/001.msg" "$h/state/worker.inbox/handled/" || fail 'acknowledgement failed'
    case "$mode" in
      check|view) del "$h" "$T0" "$mode" >/dev/null || fail 'receipt observation failed' ;;
      mirror) del "$h" "$T0" mirror --id answer >/dev/null || fail 'mirror observation failed' ;;
      receipt) del "$h" "$T0" receipt --receiver worker || fail 'pre-cleanup receipt failed' ;;
    esac
    del "$h" "$T0" deliver --task hermes-1 --path "$h/art/out.txt" --hash "$hash" >/dev/null || fail 'deliver failed'
    rm -rf "$h/state/worker.inbox"
    rm -f "$h/state/worker.meta" "$h/art/out.txt"
    out=$(del "$h" $((T0 + 400)) check) || fail 'post-cleanup check failed'
    case "$out" in *delivery-failure*) fail "$mode lost verified consumption during normal inbox cleanup" ;; esac
    out=$(del "$h" $((T0 + 500)) view)
    assert_contains "$out" 'handoff=answer state=read' 'durable receipt survives receiver cleanup'
    assert_contains "$out" "hash=$hash" 'durable read receipt retains the content hash'
    del "$h" "$T0" mirror --id answer >/dev/null || fail 'mirror forgot the durable receipt'
    [ ! -d "$h/state/worker.inbox" ] || fail 'mirror recreated a retired receiver inbox'
  done
  pass 'every consumption observer persists the path-and-hash receipt before inbox cleanup'
}

ack_primary() {
  local h=$1 seq generation
  FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" FM_CONFIG_OVERRIDE="$h/config" \
    bash "$ROOT/bin/fm-wake-drain.sh" > "$h/drained" 2> "$h/drain.err" || fail "drain failed: $(cat "$h/drain.err")"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$h/drain.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$h/drain.err")
  [ -n "$seq" ] && [ -n "$generation" ] || fail 'missing acknowledgement token'
  FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" FM_CONFIG_OVERRIDE="$h/config" \
    bash "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$generation" >/dev/null || fail 'acknowledgement failed'
}

test_unverified_artifacts_cannot_be_read() {
  local h hash receiver damage out
  for receiver in firstmate worker; do
    for damage in missing mismatch; do
      h=$(new_home "unverified-$receiver-$damage")
      register_task "$h" "$T0" hermes-1 || fail 'register failed'
      hash=$(sha_of "$h/art/out.txt")
      del "$h" "$T0" handoff --task hermes-1 --id answer --receiver "$receiver" \
        --path "$h/art/out.txt" --hash "$hash" --alt-dir "$h/hosted" --location read >/dev/null || fail 'handoff failed'
      cp "$h/art/out.txt" "$h/saved-artifact"
      case "$damage" in
        missing) rm "$h/art/out.txt" ;;
        mismatch) printf 'changed before acknowledgement\n' > "$h/art/out.txt" ;;
      esac
      assert_contains "$(del "$h" "$T0" view)" 'handoff=answer state=delivery-failure' 'unverified queued artifacts are delivery failures for either receiver'
      if [ "$receiver" = firstmate ]; then
        ack_primary "$h"
      else
        mv "$h/state/worker.inbox/001.msg" "$h/state/worker.inbox/handled/" || fail 'ack failed'
      fi
      del "$h" "$T0" receipt --receiver "$receiver" || fail 'receipt check failed'
      out=$(del "$h" "$T0" check) || fail 'check failed'
      assert_contains "$out" 'delivery-failure handoff=answer' 'acknowledgement cannot receipt an unverified artifact'
      if del "$h" "$T0" mirror --id answer >/dev/null 2>&1; then fail 'mirror accepted an unverified artifact'; fi
      assert_contains "$(del "$h" "$T0" view)" 'handoff=answer state=delivery-failure' 'every receipt consumer rejects missing or changed bytes'
      cp "$h/saved-artifact" "$h/art/out.txt"
      assert_contains "$(del "$h" "$T0" view)" 'handoff=answer state=read' 'a valid acknowledged artifact still receipts normally'
    done
  done
  pass 'both receiver paths verify unreceipted artifacts before every read classification'
}

test_silence_notification_replays_after_partial_failure() {
  local h stage rc out
  local real_mv
  real_mv=$(command -v mv)
  for stage in inbox wake record; do
    h=$(new_home "notification-$stage")
    touch "$h/state/supervisor.meta"
    del "$h" "$T0" register --task hermes-1 --deliverable report --artifact "$h/art/out.txt" \
      --heartbeat-secs 60 --silence-secs 300 --supervisor supervisor >/dev/null || fail 'register failed'
    del "$h" "$T0" dispatch --task hermes-1 >/dev/null || fail 'dispatch failed'
    case "$stage" in
      inbox) : > "$h/state/supervisor.inbox" ;;
      wake) mkdir "$h/state/.wake-queue" ;;
      record)
        mkdir "$h/fakebin"
        cat > "$h/fakebin/mv" <<'SH'
#!/usr/bin/env bash
for destination in "$@"; do :; done
case "$destination" in
  */delegated/hermes-1.record) [ "${FM_TEST_REFUSE_RECORD:-}" != 1 ] || exit 1 ;;
esac
exec "$REAL_MV_FOR_DELEGATED" "$@"
SH
        chmod +x "$h/fakebin/mv"
        ;;
    esac
    rc=0
    if [ "$stage" = record ]; then
      PATH="$h/fakebin:$PATH" REAL_MV_FOR_DELEGATED="$real_mv" FM_TEST_REFUSE_RECORD=1 \
        del "$h" $((T0 + 400)) check > "$h/first.out" 2> "$h/first.err" || rc=$?
    else
      del "$h" $((T0 + 400)) check > "$h/first.out" 2> "$h/first.err" || rc=$?
    fi
    assert_equals 1 "$rc" 'the injected delivery or marker failure must be observable'
    case "$stage" in
      inbox) rm "$h/state/supervisor.inbox" ;;
      wake) rmdir "$h/state/.wake-queue" ;;
      record) ack_primary "$h" ;;
    esac
    del "$h" $((T0 + 500)) check >/dev/null || fail 'notification replay failed'
    del "$h" $((T0 + 600)) check >/dev/null || fail 'later check failed'
    set -- "$h/state/supervisor.inbox/"*.msg
    assert_equals 1 "$#" 'partial failure produces exactly one supervisor message'
    out=$(FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" bash -c '. "$1"; fm_task_inbox_body "$2"' _ \
      "$ROOT/bin/fm-task-inbox-lib.sh" "$1")
    assert_contains "$out" 'escalation task=hermes-1' 'the supervisor receives the escalation'
    if [ "$stage" = record ]; then
      [ ! -s "$h/state/.wake-queue" ] || fail 'retry recreated an acknowledged escalation wake'
      assert_contains "$out" 'age=400' 'replay retains the original notification payload'
    else
      assert_equals 1 "$(awk -F '\t' '$4 == "delegated:supervisor:silence:hermes-1" { n++ } END { print n+0 }' "$h/state/.wake-queue")" 'one escalation wake is published across retries'
    fi
  done
  pass 'silence notifications survive inbox, wake and marker failures without duplicate delivery'
}

test_delivered_handoff_does_not_exempt_silence() {
  local h hash state out
  for state in mirrored read; do
    h=$(new_home "handoff-silence-$state")
    register_task "$h" "$T0" hermes-1 || fail 'register failed'
    del "$h" "$T0" dispatch --task hermes-1 >/dev/null || fail 'dispatch failed'
    hash=$(sha_of "$h/art/out.txt")
    del "$h" "$T0" handoff --task hermes-1 --id note --receiver worker \
      --path "$h/art/out.txt" --hash "$hash" --alt-dir "$h/hosted" --location read >/dev/null || fail 'handoff failed'
    if [ "$state" = read ]; then mv "$h/state/worker.inbox/001.msg" "$h/state/worker.inbox/handled/" || fail 'ack failed'; fi
    del "$h" $((T0 + 100)) heartbeat --task hermes-1 >/dev/null || fail 'heartbeat failed'
    out=$(del "$h" $((T0 + 500)) check) || fail 'silence check failed'
    assert_contains "$out" 'escalation task=hermes-1 age=400 last_receipt=heartbeat@' 'a delivered handoff does not excuse later task silence'
    case "$out" in *delivery-failure*) fail 'delivered handoff was classified as hidden' ;; esac
    out=$(del "$h" $((T0 + 600)) check) || fail 'repeat check failed'
    case "$out" in *escalation*) fail 'task escalated twice' ;; esac
  done
  pass 'mirrored and read handoffs preserve the task silence escalation contract'
}

test_handoff_can_carry_separate_evidence() {
  local h hash out
  h=$(new_home separate-evidence)
  register_task "$h" "$T0" hermes-1 || fail 'register failed'
  printf 'supporting evidence\n' > "$h/art/evidence.txt"
  hash=$(sha_of "$h/art/evidence.txt")
  del "$h" "$T0" handoff --task hermes-1 --id evidence --receiver worker \
    --path "$h/art/evidence.txt" --hash "$hash" --alt-dir "$h/hosted" --location read >/dev/null || fail 'separate evidence was refused'
  mv "$h/state/worker.inbox/001.msg" "$h/state/worker.inbox/handled/" || fail 'ack failed'
  out=$(del "$h" "$T0" view)
  assert_contains "$out" "handoff=evidence state=read receiver=worker artifact=$h/art/evidence.txt hash=$hash" 'handoff receipts bind to their own artifact'
  if del "$h" "$T0" deliver --task hermes-1 --path "$h/art/evidence.txt" --hash "$hash" >/dev/null 2>&1; then fail 'supporting evidence closed the final deliverable'; fi
  assert_contains "$(del "$h" "$T0" view --task hermes-1)" 'state=registered' 'handoffs do not substitute for final delivery'
  pass 'handoffs carry independent verified evidence while final delivery keeps its identity check'
}

test_non_read_location_uses_supplied_directory() {
  local h hash out body
  h=$(new_home supplied-directory)
  register_task "$h" "$T0" hermes-1 || fail 'register failed'
  hash=$(sha_of "$h/art/out.txt")
  del "$h" "$T0" handoff --task hermes-1 --id answer --receiver worker \
    --path "$h/art/out.txt" --hash "$hash" --alt-dir "$h/hosted/answers" --location alt >/dev/null || fail 'ordinary directory was refused'
  [ -f "$h/hosted/answers/001.msg" ] || fail 'handoff was not filed in the supplied directory'
  [ ! -e "$h/hosted/answers.inbox" ] || fail 'filing invented a different directory'
  body=$(FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" bash -c '. "$1"; fm_task_inbox_body "$2"' _ \
    "$ROOT/bin/fm-task-inbox-lib.sh" "$h/hosted/answers/001.msg")
  assert_contains "$body" "handoff=answer task=hermes-1 receiver=worker artifact=$h/art/out.txt hash=$hash" 'the non-read placement carries the artifact receipt'
  assert_contains "$(del "$h" "$T0" check)" 'delivery-failure handoff=answer' 'filing outside the read channel remains a delivery failure'
  del "$h" "$T0" mirror --id answer >/dev/null || fail 'mirror failed'
  assert_contains "$(del "$h" "$T0" view)" 'handoff=answer state=mirrored' 'the same answer mirrors into the actual read channel'
  pass 'non-read handoffs use the exact supplied directory without a suffix convention'
}

fm_test_run \
  test_dispatch_only_renders_dispatched_not_progressing \
  test_silent_task_escalates_exactly_once \
  test_heartbeat_resets_silence_and_progresses \
  test_hash_mismatch_and_missing_cannot_close \
  test_hidden_handoff_is_delivery_failure_until_mirrored \
  test_handoff_in_read_location_and_broken_artifact \
  test_register_validation \
  test_wrong_artifact_cannot_close \
  test_concurrent_transactions \
  test_concurrent_mirror_and_ack \
  test_watcher_routes_silence \
  test_named_supervisor_receives_escalation \
  test_primary_handoff_uses_wake_channel \
  test_completed_report_operations_preserve_receipt \
  test_read_receipt_survives_cleanup \
  test_unverified_artifacts_cannot_be_read \
  test_silence_notification_replays_after_partial_failure \
  test_delivered_handoff_does_not_exempt_silence \
  test_handoff_can_carry_separate_evidence \
  test_non_read_location_uses_supplied_directory

