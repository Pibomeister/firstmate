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
  mkdir -p "$h/state" "$h/art" "$h/read" "$h/alt"
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
  del "$h" $((T0 + 30)) deliver --task hermes-1 --path "$h/art/missing.txt" --hash "$good" >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" "a missing artifact deliver is refused"
  del "$h" $((T0 + 40)) view | grep -q "state=closed" && fail "a missing artifact closed the deliverable"
  del "$h" $((T0 + 50)) deliver --task hermes-1 --path "$h/art/out.txt" --hash "$good" >/dev/null \
    || fail "a verified deliver should close"
  assert_contains "$(del "$h" $((T0 + 60)) view)" "state=closed" "a verified receipt closes the deliverable"
  pass "a hash-mismatched or missing artifact cannot close the deliverable; a verified one does"
}

test_hidden_handoff_is_delivery_failure_until_mirrored() {
  local h hash out rc=0
  h=$(new_home hidden)
  hash=$(sha_of "$h/art/out.txt")
  del "$h" "$T0" handoff --id hf1 --receiver firstmate --path "$h/art/out.txt" \
    --hash "$hash" --read-dir "$h/read" --alt-dir "$h/alt" --location alt >/dev/null \
    || fail "handoff failed"
  out=$(del "$h" $((T0 + 10)) check) || fail "check failed"
  assert_contains "$out" "delivery-failure handoff=hf1" "a hidden handoff surfaces as a delivery failure naming it"
  del "$h" $((T0 + 20)) read --id hf1 >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" "a hidden handoff cannot be read as receipted"
  del "$h" $((T0 + 30)) mirror --id hf1 >/dev/null || fail "mirror failed"
  out=$(del "$h" $((T0 + 40)) check) || fail "check after mirror failed"
  case "$out" in
    *delivery-failure*) fail "a mirrored handoff must stop surfacing as a delivery failure: $out" ;;
  esac
  out=$(del "$h" $((T0 + 50)) read --id hf1) || fail "read after mirror failed"
  assert_contains "$out" "read-receipt handoff=hf1" "the receiver's read is receipted once mirrored"
  assert_contains "$out" "hash=$hash" "the read receipt carries the artifact hash"
  assert_contains "$(del "$h" $((T0 + 60)) view)" "handoff=hf1 state=read" "the view shows the read handoff"
  pass "a handoff filed only in the non-read location is a delivery failure until mirrored, then its read is receipted"
}

test_handoff_in_read_location_and_broken_artifact() {
  local h hash out rc=0
  h=$(new_home readloc)
  hash=$(sha_of "$h/art/out.txt")
  del "$h" "$T0" handoff --id hf1 --receiver firstmate --path "$h/art/out.txt" \
    --hash "$hash" --read-dir "$h/read" --alt-dir "$h/alt" --location read >/dev/null \
    || fail "handoff in read location failed"
  out=$(del "$h" $((T0 + 10)) check) || fail "check failed"
  case "$out" in
    *delivery-failure*) fail "a handoff in the read location is not a delivery failure: $out" ;;
  esac
  printf 'tampered\n' > "$h/art/out.txt"
  del "$h" $((T0 + 20)) read --id hf1 >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" "a read whose artifact hash now mismatches cannot be receipted"
  rc=0
  del "$h" $((T0 + 30)) handoff --id hf2 --receiver firstmate --path "$h/art/out.txt" \
    --hash "$hash" --read-dir "$h/read" --alt-dir "$h/alt" --location read >/dev/null 2>&1 || rc=$?
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

fm_test_run \
  test_dispatch_only_renders_dispatched_not_progressing \
  test_silent_task_escalates_exactly_once \
  test_heartbeat_resets_silence_and_progresses \
  test_hash_mismatch_and_missing_cannot_close \
  test_hidden_handoff_is_delivery_failure_until_mirrored \
  test_handoff_in_read_location_and_broken_artifact \
  test_register_validation

