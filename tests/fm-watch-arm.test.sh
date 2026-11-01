#!/usr/bin/env bash
# tests/fm-watch-arm.test.sh - the arm layer's cycle-close contract when the arm
# did not own the cycle.
#
# The watcher prints its one reason line to its OWN stdout, so only the arm that
# forked it ever reads that line. An arm that ATTACHED to an existing cycle holds
# no handle on it and can observe only a released lock, which is why a completely
# successful cycle used to be reported as
# "watcher: FAILED - cycle ended without an actionable reason" on every harness
# whose protocol reads that line. These are real-process tests: a real
# bin/fm-watch.sh holds the singleton, a real bin/fm-watch-arm.sh attaches to it,
# and a real status change drives a real wake through the watcher-bound delivery
# record and durable queue.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-arm-tests)

# A re-arm does real work before and during its first poll: it steals the dead
# watcher's lock, publishes and announces the downtime marker, then surfaces the
# recovery wake. That is a long run of short-lived processes, which a contended
# host - a changed-suite run beside three other suites - can slow far more than
# this suite's mostly sleeping poll loops. One re-arm measured about 2s idle, 5-7s
# beside three concurrent copies, and past the arm's default 10s confirmation
# deadline when the case was held to 15% of one CPU. These cases assert recovery,
# not a deadline, so under the CONTRIBUTING.md fixture-budget rule the arm gets an
# explicit confirmation budget with headroom, and each wait on it is an
# iteration-counted ceiling that outlasts that budget. A passing case returns as
# soon as the arm reports or exits, and a watcher that never surfaces its
# recovery still fails once the ceiling is spent.
REARM_CONFIRM_SECONDS=30
# start_rearm_arm polls every 0.05s, so this outlasts the confirmation budget.
REARM_REPORT_POLLS=700
# wait_for_exit polls every 0.1s. The arm can spend its confirmation budget again
# waiting for a successor before it reports a failure, so this outlasts it too.
REARM_EXIT_POLLS=400

# Both starters background a real process the test later waits on, so they set a
# global instead of echoing: a command substitution would make the pid a child of
# a subshell this shell can no longer wait for.
SEED_PID=
ARM_PID=

# Start the real watcher as the singleton holder.
start_seed_watcher() {  # <state> <fakebin> <watch-out> [poll-seconds]
  local state=$1 fakebin=$2 out=$3 poll=${4:-5} i
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL="$poll" FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  SEED_PID=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
      && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
    || fail "seed watcher did not take the lock"
}

# Attach a real arm to the live cycle.
start_attached_arm() {  # <state> <fakebin> <arm-out> <confirm-timeout>
  local state=$1 fakebin=$2 armout=$3 confirm=$4 i
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 \
    FM_ARM_CONFIRM_TIMEOUT="$confirm" "$WATCH_ARM" > "$armout" &
  ARM_PID=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$SEED_PID" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$SEED_PID" "$armout" \
    || fail "arm did not attach to the live watcher: $(cat "$armout")"
}

sha256_file() {  # <path>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

write_remote_delta() {  # <result-path> <status-line>
  local result=$1 line=$2 payload empty payload_bytes payload_hash empty_hash
  payload="$result.payload"
  empty="$result.empty"
  printf '%s\n' "$line" > "$payload"
  : > "$empty"
  payload_bytes=$(LC_ALL=C wc -c < "$payload" | tr -d '[:space:]')
  payload_hash=$(sha256_file "$payload") || fail "could not hash remote delta payload"
  empty_hash=$(sha256_file "$empty") || fail "could not hash empty remote delta prefix"
  {
    printf 'schema=fm-remote-delta.v1\n'
    printf 'status=delta\n'
    printf 'path=state/parent-replies.status\n'
    printf 'from_offset=0\n'
    printf 'to_offset=%s\n' "$payload_bytes"
    printf 'from_prefix_sha256=%s\n' "$empty_hash"
    printf 'to_prefix_sha256=%s\n' "$payload_hash"
    printf 'payload_sha256=%s\n' "$payload_hash"
    printf 'payload_bytes=%s\n' "$payload_bytes"
    printf 'reason=fixture\n\n'
    cat "$payload"
  } > "$result"
  rm -f "$payload" "$empty"
}

status_signature() {  # <status-path>
  bash -c '
    . "$1"
    reported=$(status_observed_signature "$2") || exit 1
    size=$(_fm_status_file_size "$2") || exit 1
    ident=$(_fm_open_decisions_file_ident "$2") || exit 1
    printf "v2\t%s\t%s@%s" "$reported" "$size" "$ident"
  ' _ "$ROOT/bin/fm-classify-lib.sh" "$1"
}

wait_for_file_text() {  # <file> <fixed-text> [poll-limit]
  local file=$1 expected=$2 i=0 limit=${3:-100}
  while [ "$i" -lt "$limit" ]; do
    grep -F "$expected" "$file" >/dev/null 2>&1 && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

ack_wakes() {  # <state>
  local state=$1 sequence generation err
  err="$state/.test-ack.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  if [ -z "$sequence" ] || [ -z "$generation" ]; then
    [ ! -s "$state/.wake-queue" ] || return 1
    case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in pending:*|announced:*) return 1 ;; esac
    return 0
  fi
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

# Print "<sequence>\t<generation>" from the acknowledgement command a drain
# printed, so a case can replay that exact pair later.
drain_ack_pair() {  # <drain-stderr>
  local err=$1 sequence generation
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  printf '%s\t%s\n' "$sequence" "$generation"
}

start_rearm_arm() {  # <home> <state> <fakebin> <arm-out> [predecessor-arm-pid]
  local home=$1 state=$2 fakebin=$3 armout=$4 predecessor=${5:-} i
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT="$REARM_CONFIRM_SECONDS" \
    FM_WATCH_PREDECESSOR_ARM_PID="$predecessor" \
    "$WATCH_ARM" --restart > "$armout" &
  ARM_PID=$!
  # Wait for the arm to confirm its watcher or exit, within a ceiling that
  # outlasts its confirmation budget. A fixed short count let a slow start fall
  # through mid-confirmation, so the caller's next liveness check or exit wait
  # began from an unknown point in the cycle.
  i=0
  while [ "$i" -lt "$REARM_REPORT_POLLS" ]; do
    grep -q '^watcher: started ' "$armout" 2>/dev/null && return 0
    is_live_non_zombie "$ARM_PID" || return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 0
}

test_attached_arm_reports_the_delivered_wake() {
  local dir state fakebin out armout status
  dir=$(make_case attached-delivered-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  start_attached_arm "$state" "$fakebin" "$armout" 1

  # A real captain-relevant status change: the watcher records it in the durable
  # queue, prints its one reason line to its own stdout, and exits.
  printf 'done: fixture finished\n' > "$state/demo.status"
  wait_for_exit "$SEED_PID" 120
  grep -q '^signal:' "$out" || fail "seed watcher did not surface the signal wake: $(cat "$out")"

  wait_for_exit "$ARM_PID" 120
  status=$?
  grep -q 'demo.status' "$state/.wake-queue" \
    || fail "the wake was not durably recorded, so this case proves nothing"
  ! grep -qF 'watcher: FAILED' "$armout" \
    || fail "attached arm reported a delivered wake as a failed cycle: $(cat "$armout")"
  grep -q '^signal:' "$armout" \
    || fail "attached arm did not report the durably recorded wake reason: $(cat "$armout")"
  expect_code 0 "$status" "an attached arm whose cycle delivered a wake must close successfully"
  grep -q 'reason=attached-delivered-wake' "$state/.watch-cycle-exits.log" \
    || fail "the delivered-wake close was not classified in the lifecycle ledger"
  pass "watch-arm: an attached arm reports the wake its cycle delivered instead of a false failure"
}

test_attached_arm_reports_the_delivered_wake_after_drain() {
  local dir state fakebin out armout status
  dir=$(make_case attached-drained-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  # A wider confirmation budget keeps the arm in its successor wait while the
  # handling turn drains, which is the ordering this case exists to cover.
  start_attached_arm "$state" "$fakebin" "$armout" 5

  printf 'done: fixture finished\n' > "$state/demo.status"
  wait_for_exit "$SEED_PID" 120
  # The handling turn consumes the records before the attached arm closes: the
  # queue is empty again, while the watcher's identity-bound terminal record
  # still proves which cycle delivered the reason.
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "drain failed"
  ack_wakes "$state" || fail "handling acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledgement left records behind"

  wait_for_exit "$ARM_PID" 200
  status=$?
  ! grep -qF 'watcher: FAILED' "$armout" \
    || fail "attached arm reported an already-handled wake as a failed cycle: $(cat "$armout")"
  grep -q '^signal:' "$armout" \
    || fail "attached arm did not report the delivered reason after the queue drain: $(cat "$armout")"
  expect_code 0 "$status" "an attached arm whose wake was already drained must close successfully"
  pass "watch-arm: a delivered wake consumed by the handling turn still closes the attached arm cleanly"
}

test_attached_arm_still_fails_on_a_wake_it_did_not_deliver() {
  local dir state fakebin out armout status
  dir=$(make_case attached-no-delivery)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  start_attached_arm "$state" "$fakebin" "$armout" 1

  # A process-event producer advances the same home-wide queue while the
  # observed watcher remains uninvolved, so only watcher-bound evidence can
  # distinguish this from a delivered watcher cycle.
  append_wake "$state" check process-event "check: process-event result captured: fixture"
  kill "$SEED_PID" 2>/dev/null || true
  wait "$SEED_PID" 2>/dev/null || true
  wait_for_exit "$ARM_PID" 120
  status=$?
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" \
    || fail "a cycle that delivered nothing must still fail loudly: $(cat "$armout")"
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] \
    || fail "arm did not exit nonzero for a cycle that delivered nothing (status $status)"
  pass "watch-arm: a cycle that delivered no wake of its own still fails loudly"
}

# A slow cycle is not an ended cycle. The holder is frozen past the grace plus
# the successor confirmation window, which is where an attached arm used to
# declare the cycle over and fail while the holder was alive and still held the
# lock; the owner's retry then hit that live holder's refusal (the auto-arm
# FAILED notice), or, if the holder beat again first, nothing followed it at all.
test_attached_arm_follows_a_slow_live_holder() {
  local dir state fakebin out armout status i arm_followed armout_frozen ledger_frozen
  dir=$(make_case attached-slow-holder)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out" 1
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 \
    FM_ARM_CONFIRM_TIMEOUT=1 FM_GUARD_GRACE=4 FM_WATCHER_STALL_BOUND=600 "$WATCH_ARM" > "$armout" &
  ARM_PID=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$SEED_PID" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$SEED_PID" "$armout" \
    || fail "arm did not attach to the live watcher: $(cat "$armout")"

  kill -STOP "$SEED_PID"
  # Grace 4s plus the 1s confirmation window plus its rounding second is where
  # the old arm gave up; hold the holder well past that. Observe while frozen,
  # but resume before asserting so a failure never strands a stopped watcher.
  i=0
  while [ "$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_path_age "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$state/.last-watcher-beat")" -lt 10 ] \
    && [ "$i" -lt 300 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  arm_followed=0
  is_live_non_zombie "$ARM_PID" && arm_followed=1
  armout_frozen=$(cat "$armout")
  ledger_frozen=$(cat "$state/.watch-cycle-exits.log" 2>/dev/null || true)
  kill -CONT "$SEED_PID"
  [ "$arm_followed" = 1 ] || fail "attached arm ended while its holder was alive: $armout_frozen"
  assert_not_contains "$armout_frozen" 'watcher: FAILED' \
    "attached arm failed a live holder's slow cycle"
  assert_not_contains "$ledger_frozen" 'reason=attached-cycle-ended' \
    "attached arm closed a cycle that had not ended"

  # The holder resumes and delivers a wake: the arm that kept following it
  # reports that wake, so nothing is lost.
  printf 'needs-decision: which export format?\n' > "$state/demo.status"
  wait_for_exit "$SEED_PID" 150
  grep -q '^signal:' "$out" || fail "resumed holder did not surface the signal wake: $(cat "$out")"
  wait_for_exit "$ARM_PID" 150
  status=$?
  ! grep -qF 'watcher: FAILED' "$armout" \
    || fail "attached arm failed after its holder resumed: $(cat "$armout")"
  grep -q '^signal:' "$armout" \
    || fail "attached arm did not report the resumed holder's wake: $(cat "$armout")"
  expect_code 0 "$status" "an attached arm that followed a slow holder must close with its wake"
  pass "watch-arm: an attached arm keeps following a slow live holder and reports its wake"
}

# The stall bound is where following ends. A live holder whose beacon reaches it
# is what the watcher's own re-arm evicts, so the attached arm stops there with
# the typed stalled-holder line, and its owner's retry replaces the holder
# instead of being refused.
test_attached_arm_hands_a_stalled_holder_to_its_replacement() {
  local dir state fakebin armout rearmout holder identity status
  dir=$(make_case attached-stalled-holder)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  rearmout="$dir/rearm.out"
  # A live process the lock records under its real identity, which never beats:
  # the shape of a watcher wedged mid-cycle that still answers TERM.
  sleep 300 &
  holder=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$holder") \
    || fail "could not identify the fake holder"
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$holder" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  : > "$state/.last-watcher-beat"

  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 \
    FM_ARM_CONFIRM_TIMEOUT=1 FM_GUARD_GRACE=5 FM_WATCHER_STALL_BOUND=12 "$WATCH_ARM" > "$armout" &
  ARM_PID=$!
  wait_for_exit "$ARM_PID" 300
  status=$?
  grep -qF "watcher: attached pid=$holder" "$armout" \
    || fail "arm did not attach to the fresh holder: $(cat "$armout")"
  grep -E "^watcher: FAILED - attached watcher pid=$holder stalled \(beacon [0-9]+s at or past hard bound 12s\)\$" "$armout" >/dev/null \
    || fail "attached arm did not report the stalled holder: $(cat "$armout")"
  ! grep -qF 'cycle ended without an actionable reason' "$armout" \
    || fail "attached arm gave up on the live holder before the stall bound: $(cat "$armout")"
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] \
    || fail "stalled-holder close did not exit nonzero (status $status)"
  grep -q 'reason=attached-holder-stalled' "$state/.watch-cycle-exits.log" \
    || fail "the stalled-holder close was not classified in the lifecycle ledger"
  is_live_non_zombie "$holder" || fail "the attached arm signalled the holder it follows"

  # The owner's retry: a fresh arm reaches the watcher's eviction path, and the
  # replacement surfaces an ordinary wake instead of the refusal that used to
  # end in the auto-arm FAILED notice.
  append_wake "$state" check stalled-work 'check: work queued behind the stalled holder' \
    || fail "could not queue work for the replacement"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT=10 FM_GUARD_GRACE=5 FM_WATCHER_STALL_BOUND=12 "$WATCH_ARM" > "$rearmout" 2>&1 &
  ARM_PID=$!
  wait_for_exit "$ARM_PID" 300
  status=$?
  grep -qF "watcher: replaced stalled pid $holder " "$rearmout" \
    || fail "the retry did not replace the stalled holder: $(cat "$rearmout")"
  ! grep -qF 'watcher: FAILED' "$rearmout" \
    || fail "the retry failed instead of replacing the stalled holder: $(cat "$rearmout")"
  grep -Eq '^(signal|stale|check):' "$rearmout" \
    || fail "the replacement surfaced no ordinary wake: $(cat "$rearmout")"
  expect_code 0 "$status" "the retry that replaced a stalled holder must close with an ordinary wake"
  wait_for_pid_gone "$holder" 50 || fail "the stalled holder survived its replacement"
  wait "$holder" 2>/dev/null || true
  pass "watch-arm: an attached arm hands a holder stalled past the bound to its owner's replacement"
}

run_stalled_arm_preserves_delivered_wake() {
  local mode=$1 dir state fakebin owned attached='' watcher holder target i status=0
  dir=$(make_case "stalled-delivery-$mode")
  state="$dir/state"
  fakebin="$dir/fakebin"
  printf '%s\tunrelated-fixture\t%04096d\n' "$$" 0 > "$state/.watch-deliveries.log"
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
last=
for last in "$@"; do :; done
if [ "$last" = "$FM_HOME/state/.watch-deliveries.log" ]; then
  : > "$FM_HOME/delivery-ready"
  while [ ! -e "$FM_HOME/delivery-go" ] && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 0.05; done
fi
exec /bin/mv "$@"
SH
  chmod +x "$fakebin/mv"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_GUARD_GRACE=5 FM_WATCHER_STALL_BOUND=12 \
    FM_WATCHER_CLEANUP_LOCK_BOUND=30 FM_ARM_ATTACH_POLL=0.1 FM_WATCH_DELIVERY_MAX_BYTES=4096 \
    "$WATCH_ARM" > "$dir/owned.out" 2> "$dir/owned.err" &
  owned=$!
  i=0
  while ! grep -q '^watcher: started pid=' "$dir/owned.out" && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
  grep -q '^watcher: started pid=' "$dir/owned.out" || fail "stalled delivery fixture never started its watcher"
  watcher=$(cat "$state/.watch.lock/pid")
  target=$owned
  if [ "$mode" = attached ]; then
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=5 \
      FM_WATCHER_STALL_BOUND=12 FM_ARM_ATTACH_POLL=0.1 \
      "$WATCH_ARM" > "$dir/attached.out" 2> "$dir/attached.err" &
    attached=$!
    target=$attached
    i=0
    while ! grep -q "^watcher: attached pid=$watcher " "$dir/attached.out" && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
    grep -q "^watcher: attached pid=$watcher " "$dir/attached.out" || fail "stalled delivery observer never attached"
  fi
  printf 'done: wake before stalled cleanup\n' > "$state/stalled.status"
  i=0
  while [ ! -e "$dir/delivery-ready" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$dir/delivery-ready" ] || fail "watcher did not reach its delivery publication"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$STATE/.watcher-down.lock" || exit 1
    : > "$FM_HOME/cleanup-held"
    while [ ! -e "$FM_HOME/cleanup-release" ] && kill -0 "$2" 2>/dev/null \
      && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 0.05; done
    fm_lock_release "$STATE/.watcher-down.lock"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$watcher" &
  holder=$!
  i=0
  while [ ! -e "$dir/cleanup-held" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$dir/cleanup-held" ] || fail "stalled delivery fixture never held the recovery lock"
  : > "$dir/delivery-go"
  i=0
  while ! grep -qF "signal: $state/stalled.status" "$state/.watch-deliveries.log" 2>/dev/null \
    && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
  grep -qF "signal: $state/stalled.status" "$state/.watch-deliveries.log" \
    || fail "watcher did not publish its delivered reason before stalling"
  cp "$state/.wake-queue" "$dir/queued-before-stall"
  wait_for_exit "$target" 400 || status=$?
  : > "$dir/cleanup-release"
  wait_for_exit "$holder" 100 >/dev/null 2>&1 || fail "stalled delivery lock holder did not finish"
  [ -z "$attached" ] || wait_for_exit "$owned" 200 >/dev/null 2>&1 || true
  expect_code 1 "$status" "$mode stalled arm must retain its failure status"
  [ "$(grep -c '^signal: .*stalled.status' "$dir/$mode.out")" -eq 1 ] \
    || fail "$mode stalled arm lost or repeated its delivered reason: $(cat "$dir/$mode.out")"
  assert_grep 'watcher: FAILED -' "$dir/$mode.out" "$mode stalled arm lost its failure diagnostic"
  cmp -s "$dir/queued-before-stall" "$state/.wake-queue" || fail "$mode stalled arm changed the durable wake rows"
  if [ "$mode" = owned ]; then
    for i in "$state"/.watch-arm-output.*; do [ ! -e "$i" ] || fail "owned stalled arm left its capture unread"; done
  fi
  pass "$mode stalled arm preserves its delivered reason and durable queue while failing"
}

test_stalled_arms_preserve_delivered_wakes() {
  run_stalled_arm_preserves_delivered_wake owned
  run_stalled_arm_preserves_delivered_wake attached
}

test_rearm_resurfaces_durable_queue_and_remote_open_decision() {
  local dir home state fakebin result armout drainout status watcher_pid generation i
  dir=$(make_case rearm-resurface)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  result="$dir/remote.result"
  armout="$dir/arm.out"
  drainout="$dir/drain.out"
  mkdir -p "$home/data"

  # This is the real remote parent-reply ingest boundary. It writes the remote
  # secondmate's decision onto the parent status surface the shared fold owns.
  write_remote_delta "$result" \
    'needs-decision [key=remote-signoff]: remote secondmate is held for captain sign-off'
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-procevent-remote-reply.sh" ingest ios "$result" >/dev/null \
    || fail "remote parent-reply ingest failed"

  # Drain once before the outage to establish the incremental cursor and the
  # signal suppressor that a watcher had already observed. The decision remains
  # intentionally open across the watcher-down interval.
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/baseline-drain.out" \
    || fail "baseline drain failed"
  ack_wakes "$state" || fail "baseline handling acknowledgement failed"
  grep -F 'remote secondmate is held for captain sign-off' "$dir/baseline-drain.out" >/dev/null \
    || fail "baseline fold did not expose the remote decision"
  printf '%s' "$(status_signature "$state/ios.status")" > "$state/.seen-ios_status"

  # A real watcher is then interrupted before the next two durable updates.
  # This is the accepted blocking-tool shape: no watcher runs during the gap.
  start_rearm_arm "$home" "$state" "$fakebin" "$dir/down-arm.out"
  is_live_non_zombie "$ARM_PID" || fail "pre-outage watcher did not stay live"
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  kill -KILL "$watcher_pid" 2>/dev/null || fail "could not abruptly stop pre-outage watcher"
  wait "$ARM_PID" 2>/dev/null || true
  [ ! -e "$state/.watcher-down" ] || fail "abrupt watcher exit unexpectedly ran cleanup"

  # Two independent durable wakes arrive while no watcher exists. Neither gets
  # a later status change to rescue it, which is the down-window loss shape.
  append_wake "$state" check remote-reply-ios \
    'check: process-event result captured: remote-reply-ios:7'
  append_wake "$state" check startup-network 'check: startup-network'

  start_rearm_arm "$home" "$state" "$fakebin" "$armout"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS"
  status=$?
  [ "$status" -ne 124 ] \
    || fail "re-arm stayed live instead of surfacing durable wakes and the still-open remote decision"
  expect_code 0 "$status" "re-arm re-surface wake must close successfully"
  grep -F 'check: rearm-resurface' "$armout" >/dev/null \
    || fail "re-arm did not report the durable recovery wake: $(cat "$armout")"

  # The normal wake-handling drain is the one owner of both queue consumption
  # and the cursor-backed fold. It must expose every queued record and the
  # already-open remote decision without relying on another user message.
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drainout" \
    || fail "drain after re-arm recovery failed"
  grep "$(printf '\tcheck\tremote-reply-ios\t')" "$drainout" >/dev/null \
    || fail "remote-reply wake queued during downtime was not drained"
  grep "$(printf '\tcheck\tstartup-network\t')" "$drainout" >/dev/null \
    || fail "second durable wake queued during downtime was not drained"
  grep -F 'ios [key=remote-signoff] needs-decision: remote secondmate is held for captain sign-off' "$drainout" >/dev/null \
    || fail "remote parent-reply decision was not re-folded after watcher re-arm"
  ack_wakes "$state" || fail "recovery handling acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "re-arm recovery acknowledgement left durable wakes behind"

  # Persistent adapters establish a successor after the handling drain. Once
  # the durable wake is acknowledged, that successor must remain live instead
  # of replaying the completed recovery cycle.
  start_rearm_arm "$home" "$state" "$fakebin" "$dir/recovery-successor-arm.out"
  is_live_non_zombie "$ARM_PID" || fail "recovery successor did not stay live after the drain"

  # A later down interval can have no new queue rows at all. Nothing is
  # buried, so the re-arm retires that downtime episode silently and stays live
  # instead of waking for bookkeeping; the unchanged remote decision is still
  # folded by the next drain.
  kill "$ARM_PID" 2>/dev/null || true
  wait "$ARM_PID" 2>/dev/null || true
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  if [ -n "$watcher_pid" ] && kill -0 "$watcher_pid" 2>/dev/null; then
    kill -TERM "$watcher_pid" 2>/dev/null || true
    i=0
    while is_live_non_zombie "$watcher_pid" && [ "$i" -lt "$REARM_EXIT_POLLS" ]; do
      sleep 0.05
      i=$((i + 1))
    done
    ! is_live_non_zombie "$watcher_pid" || fail "recovery successor watcher did not stop"
  fi
  case "$(cat "$state/.watcher-down" 2>/dev/null)" in
    pending:downtime:*) ;;
    *) fail "the watcher close did not publish a pending downtime episode: $(cat "$state/.watcher-down" 2>/dev/null)" ;;
  esac
  [ ! -s "$state/.wake-queue" ] || fail "fixture: the down interval must have no queued rows"
  generation=$(cat "$state/.watcher-down")
  generation=${generation##*:}
  start_rearm_arm "$home" "$state" "$fakebin" "$dir/decision-only-arm.out"
  # A fresh previous-cycle beacon can confirm the new holder before startup
  # retires its recovery marker. Wait for the persisted transition itself.
  wait_for_file_text "$state/.watcher-down" "acked:downtime:$generation" "$REARM_REPORT_POLLS" \
    && [ "$(cat "$state/.watcher-down")" = "acked:downtime:$generation" ] \
    || fail "the empty-queue downtime episode was not retired on its own generation: $(cat "$state/.watcher-down")"
  is_live_non_zombie "$ARM_PID" \
    || fail "an empty-queue re-arm woke for bookkeeping: $(cat "$dir/decision-only-arm.out")"
  ! grep -F 'check: rearm-resurface' "$dir/decision-only-arm.out" >/dev/null \
    || fail "an empty-queue re-arm emitted a recovery wake"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/decision-only-drain.out" \
    2> "$dir/decision-only-drain.err" || fail "drain after a silent re-arm failed"
  grep -F 'ios [key=remote-signoff] needs-decision: remote secondmate is held for captain sign-off' \
    "$dir/decision-only-drain.out" >/dev/null \
    || fail "unchanged remote decision was not folded by the next drain"
  ! grep -F 'WAKE_ACK_REQUIRED' "$dir/decision-only-drain.err" >/dev/null \
    || fail "a retired empty-queue episode still demanded a bookkeeping acknowledgement"
  kill "$ARM_PID" 2>/dev/null || true
  wait "$ARM_PID" 2>/dev/null || true
  pass "watch-arm: re-arm surfaces every queued wake and an open remote decision after downtime"
}

# A re-arm with nothing queued is bookkeeping, not a wake: neither an ordinary
# watcher close nor a dead holder may turn an empty queue into a recovery turn,
# while a row appended to that live cycle still surfaces exactly once.
test_empty_queue_rearm_stays_silent() {
  local dir home state fakebin marker watcher_pid generation status i
  dir=$(make_case empty-queue-rearm)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/first-arm.out"
  is_live_non_zombie "$ARM_PID" || fail "fixture watcher did not stay live"
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  kill -TERM "$watcher_pid" 2>/dev/null || fail "could not stop the fixture watcher"
  wait "$ARM_PID" 2>/dev/null || true
  i=0
  while is_live_non_zombie "$watcher_pid" && [ "$i" -lt "$REARM_EXIT_POLLS" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  marker=$(cat "$state/.watcher-down" 2>/dev/null || true)
  case "$marker" in
    pending:downtime:*) ;;
    *) fail "an ordinary close did not publish pending downtime: $marker" ;;
  esac
  generation=${marker##*:}
  start_rearm_arm "$home" "$state" "$fakebin" "$dir/close-arm.out"
  wait_for_file_text "$state/.watcher-down" "acked:downtime:$generation" "$REARM_REPORT_POLLS" \
    && [ "$(cat "$state/.watcher-down")" = "acked:downtime:$generation" ] \
    || fail "the empty-queue episode was not retired on its own generation: $(cat "$state/.watcher-down")"
  is_live_non_zombie "$ARM_PID" \
    || fail "an empty-queue re-arm after an ordinary close woke: $(cat "$dir/close-arm.out")"
  ! grep -F 'check: rearm-resurface' "$dir/close-arm.out" >/dev/null \
    || fail "an empty-queue re-arm after an ordinary close emitted a recovery wake"

  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  kill -KILL "$watcher_pid" 2>/dev/null || fail "could not abruptly stop the re-armed watcher"
  wait "$ARM_PID" 2>/dev/null || true
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null)" = "$watcher_pid" ] \
    || fail "fixture: the dead holder's lock must survive for the next arm to recover"
  start_rearm_arm "$home" "$state" "$fakebin" "$dir/dead-holder-arm.out"
  wait_for_file_text "$state/.watcher-down" 'acked:downtime:' "$REARM_REPORT_POLLS" \
    || fail "the dead holder's empty-queue episode was not retired: $(cat "$state/.watcher-down")"
  is_live_non_zombie "$ARM_PID" \
    || fail "an empty-queue re-arm over a dead holder woke: $(cat "$dir/dead-holder-arm.out")"
  ! grep -F 'check: rearm-resurface' "$dir/dead-holder-arm.out" >/dev/null \
    || fail "an empty-queue re-arm over a dead holder emitted a recovery wake"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null)" != "$watcher_pid" ] \
    || fail "the re-arm did not recover the dead holder's lock"
  case "$(cat "$state/.watcher-down")" in
    acked:downtime:*) ;;
    *) fail "the dead holder's empty-queue episode was not retired: $(cat "$state/.watcher-down")" ;;
  esac

  append_wake "$state" check buried 'check: durable row after a silent re-arm' \
    || fail "could not append a durable row"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS"
  status=$?
  expect_code 0 "$status" "a row appended to the silent cycle must still wake"
  grep -F 'check: rearm-resurface' "$dir/dead-holder-arm.out" >/dev/null \
    || fail "a durable row appended after a silent re-arm did not surface: $(cat "$dir/dead-holder-arm.out")"
  pass "watch-arm: an empty-queue re-arm stays silent while a later durable row still wakes"
}

# A contended host starves the short-lived processes a recovery cycle runs while
# this suite's own poll loops, which mostly sleep, keep their pace, so a re-arm
# that is still surfacing its recovery can look like one that stayed live.
# Reproduce that on any host: once the re-armed watcher has published its
# liveness beacon, every mktemp and readlink it runs - the lock and marker steps
# of its first poll and its exit - is delayed, so the cycle outlasts the roughly
# 8s that a fixed 80-poll wait allows on an idle host.
test_slow_rearm_recovery_is_still_surfaced() {
  local dir home state fakebin armout first_arm watcher_pid tool real started status
  dir=$(make_case slow-rearm-recovery)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  mkdir -p "$home/data"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/first-arm.out"
  first_arm=$ARM_PID
  is_live_non_zombie "$first_arm" || fail "slow-recovery fixture watcher did not stay live"
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  kill -KILL "$watcher_pid" 2>/dev/null || fail "could not abruptly stop slow-recovery fixture watcher"
  wait "$first_arm" 2>/dev/null || true
  append_wake "$state" check startup-network 'check: startup-network before a slow re-arm'

  # Removing the dead watcher's beacon makes the delay start exactly when the
  # re-armed watcher publishes its own, so its startup and the arm's confirmation
  # stay at full speed and only the work after confirmation is slowed.
  rm -f "$state/.last-watcher-beat"
  for tool in mktemp readlink; do
    real=$(command -v "$tool") || fail "no $tool to delay"
    cat > "$fakebin/$tool" <<SH
#!/bin/sh
[ -e "$state/.last-watcher-beat" ] && sleep 0.6
exec "$real" "\$@"
SH
    chmod +x "$fakebin/$tool"
  done

  started=$(date +%s)
  start_rearm_arm "$home" "$state" "$fakebin" "$armout"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS"
  status=$?
  [ "$status" -ne 124 ] \
    || fail "slow re-arm stayed live instead of surfacing its recovery"
  expect_code 0 "$status" "slow re-arm recovery must close successfully"
  grep -F 'check: rearm-resurface' "$armout" >/dev/null \
    || fail "slow re-arm did not report the durable recovery wake: $(cat "$armout")"
  # Without this, a change that stopped the delay from applying would pass here
  # while no longer testing a slow cycle at all.
  [ $(( $(date +%s) - started )) -ge 12 ] \
    || fail "the delayed tools did not hold the re-arm past the old fixed wait"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" \
    || fail "slow re-arm recovery drain failed"
  grep "$(printf '\tcheck\tstartup-network\t')" "$dir/drain.out" >/dev/null \
    || fail "wake queued before the slow re-arm was not drained"
  ack_wakes "$state" || fail "slow re-arm handling acknowledgement failed"
  pass "watch-arm: a re-arm whose recovery cycle runs slowly still surfaces it"
}

test_marker_publish_failure_retains_recovery_evidence() {
  local dir home state fakebin first_arm watcher_pid armout
  dir=$(make_case downtime-marker-publish-failure)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/first-arm.out"
  first_arm=$ARM_PID
  is_live_non_zombie "$first_arm" || fail "marker-failure fixture watcher did not stay live"
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  mkdir "$state/.watcher-down"
  kill -TERM "$watcher_pid" 2>/dev/null || fail "could not stop marker-failure fixture watcher"
  wait "$first_arm" 2>/dev/null || true

  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$watcher_pid" ] \
    || fail "marker publication failure discarded stale-lock recovery evidence"
  ! is_live_non_zombie "$watcher_pid" \
    || fail "marker-failure fixture watcher remained live"

  rmdir "$state/.watcher-down"
  append_wake "$state" check marker-repaired 'check: real work after marker publication was repaired' \
    || fail "could not queue work after the marker repair"
  armout="$dir/recovery-arm.out"
  start_rearm_arm "$home" "$state" "$fakebin" "$armout"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "stale-lock recovery did not surface downtime"
  grep -F 'check: rearm-resurface' "$armout" >/dev/null \
    || fail "stale-lock recovery did not emit the recovery wake: $(cat "$armout")"
  pass "watch-arm: marker publication failure retains stale-lock recovery evidence"
}

test_delivery_gap_wake_is_recovered_once() {
  local dir home state fakebin first_arm
  dir=$(make_case delivery-gap-recovery)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/first-arm.out"
  first_arm=$ARM_PID
  is_live_non_zombie "$first_arm" || fail "delivery-gap fixture watcher did not stay live"
  printf 'done: first delivered wake\n' > "$state/first.status"
  wait_for_exit "$first_arm" "$REARM_EXIT_POLLS" || fail "first watcher did not deliver its status wake"
  grep -q '^signal:' "$dir/first-arm.out" \
    || fail "first watcher did not report its delivered wake"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/first-drain.out" \
    || fail "first handling drain failed"
  ack_wakes "$state" || fail "first handling acknowledgement failed"
  append_wake "$state" check startup-network 'check: startup-network during handling gap'

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/gap-arm.out"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "successor missed the wake queued in the delivery gap"
  grep -F 'check: rearm-resurface' "$dir/gap-arm.out" >/dev/null \
    || fail "delivery-gap successor did not emit one recovery wake: $(cat "$dir/gap-arm.out")"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/gap-drain.out" \
    || fail "delivery-gap recovery drain failed"
  grep "$(printf '\tcheck\tstartup-network\t')" "$dir/gap-drain.out" >/dev/null \
    || fail "wake queued in the delivery gap was not drained"
  ack_wakes "$state" || fail "delivery-gap handling acknowledgement failed"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/stable-successor.out"
  is_live_non_zombie "$ARM_PID" || fail "successor looped after the delivery gap was drained"
  kill "$ARM_PID" 2>/dev/null || true
  wait "$ARM_PID" 2>/dev/null || true
  pass "watch-arm: a wake queued after handling drain is recovered once at successor arm"
}

test_interrupted_handling_is_redrained_on_rearm() {
  local dir home state fakebin first_arm recovery_arm sequence generation handling_watcher_pid handling_generation generation_replay
  dir=$(make_case interrupted-handling-redrain)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/first-arm.out"
  first_arm=$ARM_PID
  is_live_non_zombie "$first_arm" || fail "interrupted-handling fixture watcher did not stay live"
  printf 'done: wake whose handling is interrupted\n' > "$state/interrupted.status"
  wait_for_exit "$first_arm" "$REARM_EXIT_POLLS" || fail "fixture watcher did not deliver its wake"
  grep "$(printf '\tsignal\tinterrupted.status\t')" "$state/.wake-queue" >/dev/null \
    || fail "delivered wake was not durable before handling"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/crash-gap-recovery-arm.out"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "re-arm after a pre-successor crash stranded the durable wake"
  recovery_arm=$ARM_PID
  grep -F 'check: rearm-resurface' "$dir/crash-gap-recovery-arm.out" >/dev/null \
    || fail "re-arm after a pre-successor crash did not re-surface the durable wake"
  grep "$(printf '\tsignal\tinterrupted.status\t')" "$state/.wake-queue" >/dev/null \
    || fail "pre-successor crash recovery removed the unacknowledged durable wake"
  case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in
    pending:downtime:*|announced:downtime:*) ;;
    *) fail "reason emission marked recovery handled before a successor was established" ;;
  esac
  generation_before=$(recovery_marker_generation "$state/.watcher-down")
  [ -n "$generation_before" ] || fail "crash-gap recovery left no recovery generation"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/reason-emit-crash-replay.out"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "a crash after reason emission stranded the durable wake"
  recovery_arm=$ARM_PID
  grep -F 'check: rearm-resurface' "$dir/reason-emit-crash-replay.out" >/dev/null \
    || fail "a crash after reason emission did not re-drain recovery"
  generation_replay=$(recovery_marker_generation "$state/.watcher-down")
  [ -n "$generation_replay" ] \
    || fail "reason-emission replay left no recovery generation"
  grep "$(printf '\tsignal\tinterrupted.status\t')" "$state/.wake-queue" >/dev/null \
    || fail "reason-emission replay removed the unacknowledged durable wake"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/handling-successor-arm.out" "$recovery_arm"
  is_live_non_zombie "$ARM_PID" \
    || fail "expected handling successor looped on the pending durable wake"
  case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in
    announced:downtime:*|pending:downtime:*) ;;
    *) fail "successor launch marked recovery handled before prompt delivery" ;;
  esac
  handling_generation=$(recovery_marker_generation "$state/.watcher-down")
  handling_watcher_pid=$(sed -n 's/^watcher: started pid=\([0-9][0-9]*\).* recovery-generation=.*$/\1/p' "$dir/handling-successor-arm.out")
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --handling-delivered "$handling_generation" \
    --watcher-pid "$handling_watcher_pid" \
    || fail "confirmed prompt delivery did not begin handling"
  case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in
    pending:handling:"$handling_generation"|announced:handling:"$handling_generation") ;;
    *) fail "confirmed prompt delivery did not transition its recovery generation" ;;
  esac
  ! grep -F 'check: rearm-resurface' "$dir/handling-successor-arm.out" >/dev/null \
    || fail "expected handling successor emitted a recursive recovery wake"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/interrupted-drain.out" \
    2> "$dir/interrupted-drain.err" || fail "handling drain did not expose the durable wake"
  grep "$(printf '\tsignal\tinterrupted.status\t')" "$dir/interrupted-drain.out" >/dev/null \
    || fail "handling drain did not present the durable wake"
  grep "$(printf '\tsignal\tinterrupted.status\t')" "$state/.wake-queue" >/dev/null \
    || fail "interrupted handling removed the unacknowledged durable wake"
  is_live_non_zombie "$ARM_PID" || fail "handling drain stopped its live successor"

  kill -TERM "$ARM_PID" 2>/dev/null || fail "could not interrupt the handling successor"
  wait "$ARM_PID" 2>/dev/null || true
  case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in
    pending:downtime:*|announced:downtime:*) ;;
    *) fail "interrupted pre-handling successor did not persist downtime recovery" ;;
  esac

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/recovery-arm.out"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "successor after interruption did not re-surface the pending wake"
  grep -F 'check: rearm-resurface' "$dir/recovery-arm.out" >/dev/null \
    || fail "successor after interruption did not emit durable recovery"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/replay-drain.out" \
    2> "$dir/replay-drain.err" || fail "successor could not re-drain the interrupted wake"
  grep "$(printf '\tsignal\tinterrupted.status\t')" "$dir/replay-drain.out" >/dev/null \
    || fail "successor did not re-drain the still-durable wake"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/replay-drain.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/replay-drain.err")
  [ -n "$sequence" ] && [ -n "$generation" ] \
    || fail "re-drain did not emit a generation-bound post-handling acknowledgement command"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" \
    || fail "completed replay could not acknowledge the handled wake"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledged replay remained in the durable queue"
  pass "watch-arm: interrupted handling leaves its wake durable for successor re-drain"
}

test_malformed_marker_is_quarantined_once() {
  local dir home state fakebin invalid_count
  dir=$(make_case malformed-downtime-marker)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data" "$state/.watcher-down"
  printf 'foreign state\n' > "$state/.watcher-down/payload"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/recovery-arm.out"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "malformed marker did not produce a bounded recovery wake"
  grep -F 'check: rearm-resurface' "$dir/recovery-arm.out" >/dev/null \
    || fail "malformed marker did not emit the recovery wake"
  invalid_count=$(find "$state" -maxdepth 1 -type d -name '.watcher-down.invalid.*' | wc -l | tr -d '[:space:]')
  [ "$invalid_count" -eq 1 ] || fail "malformed marker was not quarantined exactly once"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/recovery-drain.out" \
    || fail "malformed-marker recovery drain failed"
  ack_wakes "$state" || fail "malformed-marker handling acknowledgement failed"
  start_rearm_arm "$home" "$state" "$fakebin" "$dir/stable-successor.out"
  is_live_non_zombie "$ARM_PID" || fail "malformed marker caused a persistent recovery loop"
  kill "$ARM_PID" 2>/dev/null || true
  wait "$ARM_PID" 2>/dev/null || true
  pass "watch-arm: malformed recovery state is quarantined without a successor loop"
}

test_recovery_consumption_serializes_queue_publication() {
  local dir home state fakebin
  dir=$(make_case recovery-consumption-race)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  printf 'acked:handling:fixture\n' > "$state/.watcher-down"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/arm.out"
  is_live_non_zombie "$ARM_PID" || fail "acknowledged recovery fixture did not remain live"
  append_wake "$state" check startup-network 'check: concurrent startup-network' \
    || fail "concurrent queue publication failed"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" \
    || fail "watcher missed publication after an acknowledged recovery handoff"
  grep -F 'check: rearm-resurface' "$dir/arm.out" >/dev/null \
    || fail "publisher did not restore recovery evidence"
  grep "$(printf '\tcheck\tstartup-network\t')" "$state/.wake-queue" >/dev/null \
    || fail "publisher did not durably append its wake"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" \
    || fail "publisher recovery drain failed"
  grep "$(printf '\tcheck\tstartup-network\t')" "$dir/drain.out" >/dev/null \
    || fail "publisher wake was not surfaced and drained"
  ack_wakes "$state" || fail "publisher handling acknowledgement failed"
  pass "watch-arm: publication after recovery handoff is surfaced"
}

test_restart_preserves_recovery_across_reused_pid_lock() {
  local dir home state fakebin armout unrelated owner
  dir=$(make_case restart-reused-pid-recovery)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  owner="$state/.watch.lock.owner.fixture"
  mkdir -p "$home/data" "$owner"

  sleep 300 &
  unrelated=$!
  printf '%s\n' "$unrelated" > "$owner/pid"
  printf '%s\n' "$home" > "$owner/fm-home"
  printf '%s\n' "$WATCH" > "$owner/watcher-path"
  printf '%s\n' 'reused-pid-does-not-match' > "$owner/pid-identity"
  ln -s "$owner" "$state/.watch.lock"
  append_wake "$state" check reused-holder 'check: queued work behind a reused-pid lock' \
    || fail "could not queue work behind the reused-pid lock"

  start_rearm_arm "$home" "$state" "$fakebin" "$armout"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "restart did not surface recovery after clearing a reused-pid lock"
  grep -F 'check: rearm-resurface' "$armout" >/dev/null \
    || fail "restart cleared reused-pid lock evidence without a recovery wake: $(cat "$armout")"
  is_live_non_zombie "$unrelated" || fail "restart signaled the unrelated process whose pid was reused"
  kill "$unrelated" 2>/dev/null || true
  wait "$unrelated" 2>/dev/null || true
  pass "watch-arm: restart publishes recovery before clearing a reused-pid watcher lock"
}

test_markerless_legacy_queue_is_recovered_on_arm() {
  local dir home state fakebin row
  dir=$(make_case markerless-legacy-arm)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  row=$(printf '1700000000\t7\tcheck\tlegacy-process-event\tcheck: legacy process-event')
  printf '%s\n' "$row" > "$state/.wake-queue"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/arm.out"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "markerless legacy queue was stranded at re-arm"
  grep -F 'check: rearm-resurface' "$dir/arm.out" >/dev/null \
    || fail "markerless legacy queue did not trigger recovery"
  case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in
    pending:downtime:*|announced:downtime:*) ;;
    *) fail "markerless legacy queue was not adopted into downtime recovery" ;;
  esac
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" \
    || fail "adopted legacy queue could not be drained"
  grep -F "$row" "$dir/drain.out" >/dev/null \
    || fail "adopted legacy wake was not presented"
  ack_wakes "$state" || fail "adopted legacy wake could not be acknowledged"
  pass "watch-arm: markerless legacy queues are adopted and recovered"
}

test_idle_lavish_source_stays_quiet_until_result() {
  local dir home state fakebin source trigger idle_out i runner
  dir=$(make_case idle-lavish-source)
  home="$dir"
  state="$dir/state"
  fakebin="$dir/fakebin"
  source="$dir/lavish-source.sh"
  trigger="$dir/result-ready"
  idle_out="$dir/idle-arm.out"
  mkdir -p "$home/data"
  local FM_PROCEVENT_CLAIM_ROOT="$dir/claims"
  export FM_PROCEVENT_CLAIM_ROOT
  fm_test_track_procevent_home "$home" "$FM_PROCEVENT_CLAIM_ROOT"
  cat > "$source" <<'SH'
#!/usr/bin/env bash
set -u
trigger=$1
printf 'ready\n' > "$trigger.listening"
i=0
while [ ! -e "$trigger" ] && [ "$i" -lt 400 ]; do
  sleep 0.05
  i=$((i + 1))
done
[ -e "$trigger" ] || exit 1
cat <<'RESULT'
session:
  status: feedback
  session_ended: true
prompts[1]{tag,prompt}:
  feedback,"real review result"
RESULT
SH
  chmod +x "$source"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    "$ROOT/bin/fm-procevent.sh" register lavish idle-lavish -- "$source" "$trigger" \
    >/dev/null || fail "could not register the Lavish fixture source"
  # This case observes an already-listening source, not detached launch latency.
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    "$ROOT/bin/fm-procevent.sh" start idle-lavish >"$dir/source.out" 2>"$dir/source.err" &
  runner=$!
  wait_for_file_text "$trigger.listening" ready \
    || fail "the Lavish fixture source did not begin listening: $(cat "$dir/source.err")"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=1 \
    "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null \
    || fail "could not start the Lavish fixture source"
  # An already-announced episode with no rows must stay quiet while the
  # registered source is alive. Only its eventual result is a wake.
  printf 'announced:downtime:idle-lavish.1.fixture\n' > "$state/.watcher-down"
  [ ! -s "$state/.wake-queue" ] \
    || fail "the idle Lavish source produced a wake before any result"

  FM_ROOT_OVERRIDE="$ROOT" start_rearm_arm "$home" "$state" "$fakebin" "$idle_out"
  i=0
  while [ "$i" -lt 30 ] && is_live_non_zombie "$ARM_PID"; do
    sleep 0.1
    i=$((i + 1))
  done
  if ! is_live_non_zombie "$ARM_PID"; then
    : > "$trigger"
    wait "$ARM_PID" 2>/dev/null || true
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
      "$ROOT/bin/fm-procevent.sh" retire idle-lavish >/dev/null 2>&1 || true
    fail "an idle live Lavish source re-fired recovery with an empty queue: $(cat "$idle_out")"
  fi
  ! grep -F 'check: rearm-resurface' "$idle_out" >/dev/null \
    || fail "the idle live Lavish source emitted a repeated recovery wake"

  : > "$trigger"
  wait_for_exit "$ARM_PID" 120 \
    || fail "the live Lavish result did not wake the supervising arm"
  grep -F 'check: process-event result captured: procevent:idle-lavish:1' "$idle_out" >/dev/null \
    || fail "the live Lavish result did not surface promptly: $(cat "$idle_out")"
  grep "$(printf '\tcheck\tprocevent:idle-lavish:1\t')" "$state/.wake-queue" >/dev/null \
    || fail "the live Lavish result was not durable before its wake"
  wait_for_exit "$runner" 120 || fail "the Lavish fixture runner did not finish"
  pass "watch-arm: an idle Lavish source stays quiet and its real result wakes promptly"
}

test_append_wakes_live_announced_watcher() {
  local dir home state fakebin idle_out
  dir=$(make_case append-after-empty-recovery)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  idle_out="$dir/idle-arm.out"
  mkdir -p "$home/data"
  printf 'announced:downtime:append-after-empty.fixture\n' > "$state/.watcher-down"
  [ ! -s "$state/.wake-queue" ] \
    || fail "the empty recovery unexpectedly queued durable work"

  start_rearm_arm "$home" "$state" "$fakebin" "$idle_out"
  is_live_non_zombie "$ARM_PID" \
    || fail "the announced empty recovery did not leave a live watcher"
  append_wake "$state" check inbox:fixture 'check: captain inbox note fixture' \
    || fail "the generic producer could not append its wake"
  wait_for_exit "$ARM_PID" 80 \
    || fail "the live watcher stranded work appended after an empty recovery"
  grep -F 'check: rearm-resurface' "$idle_out" >/dev/null \
    || fail "the appended wake did not reopen recovery: $(cat "$idle_out")"
  grep "$(printf '\tcheck\tinbox:fixture\t')" "$state/.wake-queue" >/dev/null \
    || fail "the appended wake was not durable when recovery surfaced"
  pass "watch-arm: appending work reopens an announced empty recovery"
}

test_append_wakes_handling_successor() {
  local phase=$1 seq_state=${2:-intact} repeat=${3:-fresh}
  local dir home state fakebin predecessor successor generation watcher_pid pair sequence
  local new_key=inbox:second new_payload='check: captain inbox note second' datebin real_date inherited_row inherited_epoch
  dir=$(make_case "append-handling-$phase-$seq_state-$repeat")
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  append_wake "$state" check inbox:zeroth 'check: captain inbox note zeroth'
  append_wake "$state" check inbox:first 'check: captain inbox note first'
  inherited_row=$(head -n 1 "$state/.wake-queue")
  start_rearm_arm "$home" "$state" "$fakebin" "$dir/first.out"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "first inbox wake did not surface"
  predecessor=$ARM_PID
  start_rearm_arm "$home" "$state" "$fakebin" "$dir/successor.out" "$predecessor"
  successor=$ARM_PID
  generation=$(recovery_marker_generation "$state/.watcher-down")
  watcher_pid=$(cat "$state/.watch.lock/pid")
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --handling-delivered "$generation" \
    --watcher-pid "$watcher_pid" || fail "could not confirm first notification delivery"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err"
  pair=$(drain_ack_pair "$dir/drain.err") || fail "first drain supplied no acknowledgement"
  sequence=${pair%%$'\t'*}
  generation=${pair#*$'\t'}
  # Outlast two real polls: the inherited row alone must not loop.
  sleep 3
  is_live_non_zombie "$successor" || fail "successor repeated the inherited notification"
  if [ "$phase" = after-ack ]; then
    FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation"
    [ ! -s "$state/.wake-queue" ] || fail "inherited rows were not acknowledged"
  fi
  # A lost or unreadable counter must not let a new row look inherited.
  case "$seq_state" in
    missing) rm -f "$state/.wake-queue.seq" ;;
    malformed) printf 'not-a-sequence\n' > "$state/.wake-queue.seq" ;;
  esac
  datebin=
  if [ "$repeat" = identical ]; then
    # Re-append the first inherited row's kind, key, and payload inside its
    # epoch second, so the reused sequence makes the new row byte-identical.
    new_key=inbox:zeroth
    new_payload='check: captain inbox note zeroth'
    datebin="$dir/datebin"
    mkdir -p "$datebin"
    real_date=$(command -v date)
    inherited_epoch=${inherited_row%%$'\t'*}
    cat > "$datebin/date" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = +%s ]; then
  printf '%s\n' "$inherited_epoch"
else
  exec "$real_date" "\$@"
fi
SH
    chmod +x "$datebin/date"
  fi
  PATH="${datebin:+$datebin:}$PATH" append_wake "$state" check "$new_key" "$new_payload"
  if [ "$repeat" = identical ]; then
    [ "$(head -n 1 "$state/.wake-queue")" = "$inherited_row" ] \
      || fail "re-append was not byte-identical to the inherited row"
  fi
  if [ "$phase" = before-ack ]; then
    FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation"
  fi
  wait_for_exit "$successor" 100 || fail "handling successor stranded the second inbox wake ($phase)"
  grep -F 'check: rearm-resurface' "$dir/successor.out" >/dev/null \
    || fail "successor did not notify about new work"
  grep "$(printf '\tcheck\t%s\t' "$new_key")" "$state/.wake-queue" >/dev/null \
    || fail "notification or old acknowledgement consumed the second message"
  start_rearm_arm "$home" "$state" "$fakebin" "$dir/next.out" "$successor"
  ack_wakes "$state" || fail "could not acknowledge the second message"
  sleep 3
  is_live_non_zombie "$ARM_PID" || fail "next successor repeated already-handled work"
  [ ! -s "$state/.wake-queue" ] || fail "handled queue was not drained"
  kill -TERM "$ARM_PID"
  wait "$ARM_PID" 2>/dev/null || true
  pass "watch-arm: handling successor delivers $repeat new inbox work $phase ($seq_state counter) without consuming or looping"
}

# Exercise the handling-window recovery invariant owned by
# docs/watcher-continuity.md through real watcher processes.
test_handling_window_close_keeps_the_acknowledgement_valid() {
  local dir home state fakebin pair sequence generation
  dir=$(make_case handling-window-close-acknowledgement)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/first-arm.out"
  is_live_non_zombie "$ARM_PID" || fail "handling-window fixture watcher did not stay live"
  printf 'done: wake handled while a watcher cycle closes\n' > "$state/handled.status"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "fixture watcher did not deliver its wake"
  grep "$(printf '\tsignal\thandled.status\t')" "$state/.wake-queue" >/dev/null \
    || fail "delivered wake was not durable before handling"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" \
    || fail "handling drain did not present the durable wake"
  pair=$(drain_ack_pair "$dir/drain.err") \
    || fail "drain did not print a generation-bound acknowledgement command"
  sequence=${pair%%$'\t'*}
  generation=${pair##*$'\t'}

  # One full watcher cycle appends a wake and then closes inside the handling window.
  start_rearm_arm "$home" "$state" "$fakebin" "$dir/handling-window-arm.out"
  is_live_non_zombie "$ARM_PID" || fail "handling-window watcher did not stay live"
  printf 'done: wake published during handling\n' > "$state/during-handling.status"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "handling-window watcher did not deliver its wake"
  grep "$(printf '\tsignal\tduring-handling.status\t')" "$state/.wake-queue" >/dev/null \
    || fail "handling-window watcher did not durably append its wake"

  [ "$(cat "$state/.watcher-down" 2>/dev/null || true)" = "pending:downtime:$generation" ] \
    || fail "repeated publications during handling replaced the outstanding recovery generation"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" 2> "$dir/ack.err" \
    || fail "the printed acknowledgement was rejected after repeated publications: $(cat "$dir/ack.err")"
  ! grep "$(printf '\tsignal\thandled.status\t')" "$state/.wake-queue" >/dev/null \
    || fail "the acknowledged wake was not consumed"
  grep "$(printf '\tsignal\tduring-handling.status\t')" "$state/.wake-queue" >/dev/null \
    || fail "the newer handling-window wake was over-consumed"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/remaining-drain.out" \
    2> "$dir/remaining-drain.err" || fail "remaining wake could not be re-drained"
  pair=$(drain_ack_pair "$dir/remaining-drain.err") \
    || fail "remaining drain did not print an acknowledgement command"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "${pair%%$'\t'*}" \
    --recovery-generation "${pair##*$'\t'}" \
    || fail "remaining handling-window wake could not be acknowledged"
  [ ! -s "$state/.wake-queue" ] || fail "remaining wake was not consumed"
  case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in
    acked:*) ;;
    *) fail "the handled recovery episode was not retired" ;;
  esac

  # The next arm must supervise rather than spend its whole cycle on recovery.
  start_rearm_arm "$home" "$state" "$fakebin" "$dir/next-arm.out"
  is_live_non_zombie "$ARM_PID" \
    || fail "the watcher armed after acknowledgement died inside its first cycle"
  ! grep -F 'check: rearm-resurface' "$dir/next-arm.out" >/dev/null \
    || fail "the watcher armed after acknowledgement re-announced a retired recovery"
  printf 'blocked: a later wake the live watcher must still surface\n' > "$state/later.status"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "the live watcher did not surface a later wake"
  grep -q '^signal:' "$dir/next-arm.out" \
    || fail "the watcher armed after acknowledgement never reached real supervision work: $(cat "$dir/next-arm.out")"
  pass "watch-arm: a watcher close during handling keeps the printed acknowledgement valid"
}

# Exercise the moved-generation recovery invariant owned by
# docs/watcher-continuity.md through real watcher processes.
test_moved_generation_acknowledgement_is_self_healing() {
  local dir home state fakebin pair first_sequence first_generation second_generation
  dir=$(make_case moved-generation-acknowledgement)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/first-arm.out"
  is_live_non_zombie "$ARM_PID" || fail "moved-generation fixture watcher did not stay live"
  printf 'done: first handled wake\n' > "$state/first.status"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "fixture watcher did not deliver its first wake"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/first-drain.out" \
    2> "$dir/first-drain.err" || fail "first drain did not present the durable wake"
  pair=$(drain_ack_pair "$dir/first-drain.err") \
    || fail "first drain did not print a generation-bound acknowledgement command"
  first_sequence=${pair%%$'\t'*}
  first_generation=${pair##*$'\t'}
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$first_sequence" \
    --recovery-generation "$first_generation" \
    || fail "the first handled wake could not be acknowledged"

  # A retired episode does not freeze the generation: the next one is its own.
  start_rearm_arm "$home" "$state" "$fakebin" "$dir/second-arm.out"
  is_live_non_zombie "$ARM_PID" || fail "second fixture watcher did not stay live"
  printf 'done: second wake in a newer recovery episode\n' > "$state/second.status"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS" || fail "second fixture watcher did not deliver its wake"
  second_generation=$(sed -n 's/^pending:downtime:\(.*\)$/\1/p' "$state/.watcher-down")
  [ -n "$second_generation" ] || fail "a wake after acknowledgement did not open a recovery episode"
  [ "$second_generation" != "$first_generation" ] \
    || fail "an acknowledged episode kept its generation instead of opening a new one"

  # Replaying the stale pair must not fail, must not over-consume, and must not
  # retire the newer episode.
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$first_sequence" \
    --recovery-generation "$first_generation" 2> "$dir/stale-ack.err" \
    || fail "a replayed stale acknowledgement was rejected instead of degrading safely"
  if ! grep -F 'WAKE_ACK_REQUIRED' "$dir/stale-ack.err" >/dev/null \
    || ! grep -F 're-run' "$dir/stale-ack.err" >/dev/null; then
    fail "a moved recovery generation did not name its own remedy: $(cat "$dir/stale-ack.err")"
  fi
  grep "$(printf '\tsignal\tsecond.status\t')" "$state/.wake-queue" >/dev/null \
    || fail "a stale acknowledgement consumed a wake above its sequence"
  [ "$(cat "$state/.watcher-down" 2>/dev/null || true)" = "pending:downtime:$second_generation" ] \
    || fail "a stale acknowledgement retired the newer recovery episode"

  # The sequence alone owns consumption, so the handled rows go even while the
  # generation is stale, and only the episode stays pending.
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through 999 \
    --recovery-generation "$first_generation" 2> "$dir/stale-consume.err" \
    || fail "a stale acknowledgement refused to consume the rows it was given"
  [ ! -s "$state/.wake-queue" ] \
    || fail "a stale acknowledgement left its handled rows on the durable queue"
  [ "$(cat "$state/.watcher-down" 2>/dev/null || true)" = "pending:downtime:$second_generation" ] \
    || fail "row consumption under a stale generation retired the pending episode"

  # Following the printed remedy closes the episode, so the loop is self-healing.
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/redrain.out" \
    2> "$dir/redrain.err" || fail "the remedy re-drain did not run"
  pair=$(drain_ack_pair "$dir/redrain.err") \
    || fail "the remedy re-drain did not print the newer acknowledgement command"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "${pair%%$'\t'*}" \
    --recovery-generation "${pair##*$'\t'}" \
    || fail "the newer recovery episode could not be acknowledged"
  case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in
    acked:*) ;;
    *) fail "following the printed remedy did not retire the newer recovery episode" ;;
  esac
  pass "watch-arm: a moved recovery generation consumes handled rows and names its remedy"
}

# The supervision host ends its own cycle on purpose; --stop is the home-scoped
# stop without a re-arm, and the stopped watcher publishes downtime as any
# close does, so the owner's rewake can commit.
test_stop_ends_the_home_watcher_and_publishes_downtime() {
  local dir home state fakebin out status
  dir="$TMP_ROOT/stop-home-watcher"
  home="$dir/home"
  state="$home/state"
  fakebin=$(make_case stop-home-watcher-bin)/fakebin
  mkdir -p "$state"
  FM_HOME="$home" start_seed_watcher "$state" "$fakebin" "$dir/watch.out"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --stop 2>&1); status=$?
  expect_code 0 "$status" "--stop of a live home watcher must succeed"
  assert_contains "$out" "watcher: stopped pid=$SEED_PID" "--stop must name the watcher it stopped"
  wait_for_exit "$SEED_PID" 50 >/dev/null 2>&1 || true
  kill -0 "$SEED_PID" 2>/dev/null && fail "--stop left the home watcher running"
  case "$(cat "$state/.watcher-down" 2>/dev/null)" in
    pending:downtime:*|announced:downtime:*) ;;
    *) fail "--stop did not leave downtime published: $(cat "$state/.watcher-down" 2>/dev/null)" ;;
  esac
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --stop 2>&1); status=$?
  expect_code 0 "$status" "--stop with no watcher must succeed"
  assert_contains "$out" "watcher: none running" "--stop with no watcher must say so"
  pass "watch-arm: --stop ends only this home's watcher, publishes downtime, and reports when none runs"
}

# --take-over stops only a watcher that the named arm itself owns. The seed
# watcher here is this shell's child, so naming any other process leaves it
# running and the arm attaches to it exactly as a plain arm does.
test_take_over_attaches_to_a_cycle_the_named_arm_does_not_own() {
  local dir state fakebin armout other status
  dir=$(make_case take-over-not-owner)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  FM_HOME="$dir" start_seed_watcher "$state" "$fakebin" "$dir/watch.out"
  sleep 60 &
  other=$!
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --take-over 2>/dev/null
  status=$?
  expect_code 2 "$status" "--take-over without an arm pid must be refused"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 \
    "$WATCH_ARM" --take-over "$other" > "$armout" &
  ARM_PID=$!
  wait_for_file_text "$armout" "watcher: attached pid=$SEED_PID" \
    || fail "--take-over of a cycle the named arm does not own did not attach: $(cat "$armout")"
  sleep 1
  is_live_non_zombie "$SEED_PID" || fail "--take-over stopped a watcher the named arm does not own"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null)" = "$SEED_PID" ] || fail "--take-over moved a lock it does not own"
  kill -TERM "$ARM_PID" "$SEED_PID" "$other" 2>/dev/null || true
  wait_for_exit "$ARM_PID" 50 >/dev/null 2>&1 || true
  wait_for_exit "$SEED_PID" 50 >/dev/null 2>&1 || true
  wait "$other" 2>/dev/null || true
  pass "watch-arm: --take-over attaches to a cycle the named arm does not own and leaves it running"
}

# --take-over stops the named real arm's watcher, as it would a successor
# left for main, and owns a fresh cycle. The stop must not open recovery over an episode
# main already acknowledged, and must not hide work still queued.
test_take_over_owns_a_fresh_cycle_and_keeps_queued_work_surfacing() {
  local dir state fakebin armout status owner
  dir=$(make_case take-over-owner)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"

  # Main acknowledged everything: the fresh cycle stays quiet.
  start_rearm_arm "$dir" "$state" "$fakebin" "$dir/owner.out" "$$"
  owner=$ARM_PID
  SEED_PID=$(cat "$state/.watch.lock/pid")
  append_wake "$state" signal take-over "signal: fixture handled by main"
  ack_wakes "$state" >/dev/null || fail "fixture: main could not acknowledge the handled wake"
  case "$(cat "$state/.watcher-down" 2>/dev/null)" in acked:*) ;; *) fail "fixture: the episode was not acknowledged" ;; esac
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH_ARM" --take-over "$owner" > "$armout" &
  ARM_PID=$!
  wait_for_file_text "$armout" 'watcher: started pid=' \
    || fail "--take-over did not own a fresh cycle: $(cat "$armout")"
  wait_for_exit "$SEED_PID" 50 >/dev/null 2>&1 || true
  ! is_live_non_zombie "$SEED_PID" || fail "--take-over left the watcher it took over running"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null)" != "$SEED_PID" ] || fail "--take-over did not take the lock"
  sleep 3
  is_live_non_zombie "$ARM_PID" || fail "the taken-over cycle closed with no new work: $(cat "$armout")"
  case "$(cat "$state/.watcher-down" 2>/dev/null)" in
    acked:*) ;;
    *) fail "the takeover opened a downtime episode: $(cat "$state/.watcher-down" 2>/dev/null)" ;;
  esac
  grep -q 'reason=taken-over	.*successor=started:' "$state/.watch-cycle-exits.log" \
    || fail "the lifecycle ledger does not link the taken-over cycle to the one it started: $(cat "$state/.watch-cycle-exits.log")"
  kill -TERM "$ARM_PID" 2>/dev/null || true
  wait_for_exit "$ARM_PID" 50 >/dev/null 2>&1 || true

  # A wake still queued for main resurfaces from the cycle the arm took over.
  start_rearm_arm "$dir" "$state" "$fakebin" "$dir/owner2.out" "$$"
  owner=$ARM_PID
  SEED_PID=$(cat "$state/.watch.lock/pid")
  append_wake "$state" signal take-over "signal: fixture still queued for main"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT="$REARM_CONFIRM_SECONDS" "$WATCH_ARM" --take-over "$owner" > "$armout" &
  ARM_PID=$!
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS"
  status=$?
  expect_code 0 "$status" "a takeover that resurfaces queued work closes cleanly"
  grep -q '^check: rearm-resurface' "$armout" \
    || fail "work queued for main did not resurface after the takeover: $(cat "$armout")"
  ! is_live_non_zombie "$SEED_PID" || fail "--take-over left the second watcher running"
  pass "watch-arm: --take-over owns a fresh cycle without a recovery wake and still surfaces queued work"
}

# A fake herdr for one live, busy crew pane, plus an event reader that behaves
# like herdr-eventwait.py on a quiet fleet: it subscribes, then blocks for its
# whole timeout budget. Nothing here reaches a real herdr server.
make_event_wait_herdr() {  # <case-dir>
  local dir=$1
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_HERDR_LOG:-/dev/null}"
args=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = --session ]; then shift 2; continue; fi
  args+=("$1"); shift
done
set -- "${args[@]}"
case "${1:-} ${2:-}" in
  "status --json") printf '{"client":{"version":"0.7.3","protocol":16},"server":{"running":true}}\n' ;;
  "session list") printf '{"sessions":[{"name":"evt","running":true,"socket_path":"/nonexistent/evt.sock"}]}\n' ;;
  "agent get") printf '{"result":{"agent":{"agent":"claude","agent_status":"working"}}}\n' ;;
  "pane get") printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
  "pane process-info")
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_processes":[{"pid":%s,"name":"claude","argv":["claude"]}]}}}\n' \
      "${4:-}" "$PPID" "$PPID" ;;
  "pane read") printf 'fixture pane\n> \n' ;;
esac
exit 0
SH
  cat > "$dir/quiet-reader" <<'SH'
#!/usr/bin/env bash
printf '@subscribed\n'
sleep "$2"
SH
  chmod +x "$dir/fakebin/herdr" "$dir/quiet-reader"
}

# The watcher of a home with a herdr crew pane spends each idle poll inside its
# event wait, which blocks up to POLL. A take-over that lands there must still
# confirm its stop inside the arm's stop bound, put back the acknowledgement
# main already made, and leave the fresh cycle quiet. Run as a $(...) on bash
# 3.2, that wait held the TERM for the rest of the POLL, the stop went
# unconfirmed, and the fresh cycle resurfaced an episode main had acknowledged,
# which the supervision host passes straight back to main: a loop. The stopped
# wait's reader scratch must not be left behind either.
test_take_over_confirms_a_watcher_stopped_inside_its_event_wait() {
  local dir state armout owner watcher fresh acknowledged before i leftover
  dir=$(make_case take-over-event-wait)
  state="$dir/state"
  armout="$dir/arm.out"
  mkdir -p "$dir/tmp"
  make_event_wait_herdr "$dir"
  printf 'window=evt:wG:pQ\nbackend=herdr\nkind=ship\n' > "$state/demo.meta"
  event_arm() {  # <predecessor-or-empty> [arm-args...]
    local pred=$1
    shift
    exec env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
      -u HERDR_SOCKET_PATH -u HERDR_SESSION -u FM_BACKEND_HERDR_BIN \
      PATH="$dir/fakebin:$PATH" TMPDIR="$dir/tmp" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
      FM_POLL=40 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      FM_BUSY_TURN_MAX_SECS=999999 FM_STALE_ESCALATE_SECS=999999 \
      FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_BACKEND_HERDR_EVENT_READER="$dir/quiet-reader" \
      FM_FAKE_HERDR_LOG="$dir/herdr.log" FM_WATCH_PREDECESSOR_ARM_PID="$pred" \
      "$WATCH_ARM" "$@"
  }
  # The successor a pass-through leaves running for main; main acknowledges.
  event_arm "$$" > "$dir/owner.out" &
  owner=$!
  wait_for_file_text "$dir/owner.out" 'watcher: started pid=' \
    || fail "fixture: the successor did not start: $(cat "$dir/owner.out")"
  watcher=$(cat "$state/.watch.lock/pid")
  append_wake "$state" signal take-over "signal: fixture handled by main"
  ack_wakes "$state" >/dev/null || fail "fixture: main could not acknowledge the handled wake"
  acknowledged=$(cat "$state/.watcher-down")
  case "$acknowledged" in acked:*) ;; *) fail "fixture: the episode was not acknowledged: $acknowledged" ;; esac
  # Land the take-over a second into a fresh event wait (each begins with the
  # socket lookup), well inside its 40s budget. The budget must outlast the
  # arm's stop bound even when a loaded host stretches that bound, or a held
  # TERM is released in time and the case cannot catch the bug.
  before=$(grep -c '^session list' "$dir/herdr.log" 2>/dev/null) || before=0
  i=0
  while [ "$i" -lt 1000 ]; do
    [ "$(grep -c '^session list' "$dir/herdr.log" 2>/dev/null)" -gt "$before" ] && break
    sleep 0.05
    i=$((i + 1))
  done
  [ "$i" -lt 1000 ] || fail "fixture: the successor never entered its event wait: $(cat "$dir/herdr.log" 2>/dev/null)"
  sleep 1
  event_arm "" --take-over "$owner" > "$armout" &
  ARM_PID=$!
  i=0
  while [ "$i" -lt 400 ] && ! grep -q '^watcher: started pid=' "$armout" 2>/dev/null; do
    is_live_non_zombie "$ARM_PID" || break
    sleep 0.05
    i=$((i + 1))
  done
  grep -q '^watcher: started pid=' "$armout" \
    || fail "the take-over did not own a fresh cycle within 20s of a stop during the event wait: $(cat "$armout")"
  ! is_live_non_zombie "$watcher" || fail "the take-over left the watcher it stopped running"
  grep -q "^arm_pid=$ARM_PID	watcher_pid=$watcher	.*reason=taken-over	" "$state/.watch-cycle-exits.log" \
    || fail "the take-over did not confirm its stop: $(cat "$state/.watch-cycle-exits.log")"
  [ "$(cat "$state/.watcher-down")" = "$acknowledged" ] \
    || fail "the take-over reopened an acknowledged episode: $(cat "$state/.watcher-down")"
  fresh=$(cat "$state/.watch.lock/pid")
  sleep 3
  is_live_non_zombie "$ARM_PID" || fail "the fresh cycle closed with no new work: $(cat "$armout")"
  ! grep -q '^check: rearm-resurface' "$armout" || fail "the fresh cycle resurfaced an acknowledged episode"
  kill -TERM "$ARM_PID" 2>/dev/null || true
  wait_for_exit "$ARM_PID" 50 >/dev/null 2>&1 || true
  wait_for_exit "$owner" 50 >/dev/null 2>&1 || true
  i=0
  while [ "$i" -lt 50 ] && is_live_non_zombie "$fresh"; do
    sleep 0.1
    i=$((i + 1))
  done
  leftover=$(find "$dir/tmp" \( -name 'fm-herdr-eventwait.*' -o -name 'fm-watch-wait.*' \) -print 2>/dev/null)
  [ -z "$leftover" ] || fail "a stopped event wait left its scratch behind: $leftover"
  pass "watch-arm: --take-over of a watcher inside its herdr event wait confirms the stop and resurfaces nothing"
}

# Pause just after handover releases its snapshot locks, then fail the old
# watcher's secondmate tick write so it exits through cleanup before TERM lands.
# The ledger and recovery wake are public output contracts, not source probes.
test_take_over_preserves_downtime_from_watcher_self_exit() {
  local dir home state fakebin owner watcher armout acknowledged real_rm real_touch status i
  dir=$(make_case take-over-self-exit)
  home="$dir/home"
  mkdir -p "$home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  real_touch=$(command -v touch)
  printf '#!/usr/bin/env bash\nif [ "$*" = "%s/.secondmate-liveness-tick" ] && [ -e "%s/fail-tick" ]; then exit 1; fi\nexec "%s" "$@"\n' \
    "$state" "$dir" "$real_touch" > "$fakebin/touch"
  chmod +x "$fakebin/touch"
  FM_SECONDMATE_LIVENESS_SECS=1 start_rearm_arm "$home" "$state" "$fakebin" "$dir/owner.out" "$$"
  owner=$ARM_PID
  watcher=$(cat "$state/.watch.lock/pid")
  append_wake "$state" signal take-over "signal: fixture handled by main"
  ack_wakes "$state" >/dev/null || fail "fixture: could not acknowledge wake"
  acknowledged=$(cat "$state/.watcher-down")
  real_rm=$(command -v rm)
  # Only the taking arm gets this shim. Release the real queue lock before
  # exposing the barrier: the self-exiting watcher needs it for cleanup.
  mkdir -p "$dir/barrier-bin"
  printf '#!/usr/bin/env bash\n"%s" "$@"\n' "$real_rm" > "$dir/barrier-bin/rm"
  printf 'if [ "$*" = "-f %s/.wake-queue.lock" ]; then\n' "$state" >> "$dir/barrier-bin/rm"
  printf '  touch "%s/snapshot-read"\n  for ((i=0; i<700; i++)); do\n    [ -e "%s/release" ] && break\n    sleep 0.05\n  done\nfi\n' "$dir" "$dir" >> "$dir/barrier-bin/rm"
  chmod +x "$dir/barrier-bin/rm"
  PATH="$dir/barrier-bin:$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT="$REARM_CONFIRM_SECONDS" \
    "$WATCH_ARM" --take-over "$owner" > "$armout" &
  ARM_PID=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$dir/snapshot-read" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$dir/snapshot-read" ] || fail "takeover never reached its snapshot"
  touch "$dir/fail-tick"
  wait_for_exit "$owner" "$REARM_EXIT_POLLS"
  status=$?
  expect_code 1 "$status" "old watcher must fail through its own cleanup"
  ! is_live_non_zombie "$watcher" || fail "old watcher did not self-exit"
  grep -q "arm_pid=$owner	watcher_pid=$watcher.*exit_code=1	signal=none" "$state/.watch-cycle-exits.log" \
    || fail "owner did not record its watcher's non-signal failure"
  [ ! -s "$state/.wake-queue" ] || fail "self-exit unexpectedly queued a wake"
  ! grep -q "^$watcher	" "$state/.watch-deliveries.log" 2>/dev/null \
    || fail "self-exit unexpectedly delivered a wake"
  case "$(cat "$state/.watcher-down")" in pending:downtime:*) ;; *) fail "self-exit did not publish downtime" ;; esac
  rm -f "$dir/fail-tick"
  touch "$dir/release"
  i=0
  while [ "$i" -lt "$REARM_REPORT_POLLS" ]; do
    grep -qE '^watcher: started pid=|^check: rearm-resurface' "$armout" && break
    is_live_non_zombie "$ARM_PID" || break
    sleep 0.05
    i=$((i + 1))
  done
  [ "$(cat "$state/.watcher-down")" != "$acknowledged" ] || fail "takeover restored the old acknowledgement"
  is_live_non_zombie "$ARM_PID" || fail "empty-queue takeover did not keep supervising"
  assert_not_contains "$(cat "$armout")" 'check: rearm-resurface' "empty self-exit downtime must not wake for bookkeeping"
  append_wake "$state" check after-self-exit 'check: real work after watcher self-exit' \
    || fail "could not queue real work after watcher self-exit"
  wait_for_exit "$ARM_PID" "$REARM_EXIT_POLLS"
  status=$?
  expect_code 0 "$status" "fresh takeover must surface recovery cleanly"
  assert_contains "$(cat "$armout")" 'check: rearm-resurface' "work after self-exit downtime must surface as recovery"
  pass "watch-arm: takeover preserves self-exit evidence, stays quiet without rows, and surfaces later work"
}

test_downtime_marker_does_not_follow_symlink() {
  local dir home state fakebin armout watcher_pid sentinel
  dir=$(make_case downtime-marker-symlink)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  sentinel="$dir/sentinel"
  mkdir -p "$home/data"

  start_rearm_arm "$home" "$state" "$fakebin" "$armout"
  is_live_non_zombie "$ARM_PID" || fail "symlink fixture watcher did not stay live"
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  printf 'must remain intact\n' > "$sentinel"
  ln -s "$sentinel" "$state/.watcher-down"
  kill -TERM "$watcher_pid" 2>/dev/null || fail "could not stop symlink fixture watcher"
  wait "$ARM_PID" 2>/dev/null || true

  [ "$(cat "$sentinel")" = "must remain intact" ] \
    || fail "downtime marker publication followed and truncated a symlink"
  [ -f "$state/.watcher-down" ] && [ ! -L "$state/.watcher-down" ] \
    || fail "downtime marker was not safely published as a regular file"
  pass "watch-arm: downtime marker publication does not follow symlinks"
}

# The watcher validates FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS when it arms and
# refuses to arm on an unusable value. Under a running watcher that value would
# make every per-cycle reconcile refuse by name into a discarded stdout, so no
# source would ever start and the home would sit disarmed while presenting as
# supervised; refusing to arm is loud through the liveness guard instead. This
# drives the real arm entry and asserts the arm STOPPED - non-zero exit, no
# started line, no lock holder, no beacon - and that its refusal names the
# variable, so a validator that merely returned false somewhere would not pass.
test_arm_refuses_an_unusable_launch_confirm_window() {
  local dir home state fakebin armout status lock_pid
  dir=$(make_case confirm-window-refusal)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  mkdir -p "$home/data"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT=5 FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=5s \
    "$WATCH_ARM" > "$armout" 2>&1 &
  ARM_PID=$!
  wait_for_exit "$ARM_PID" 200
  status=$?
  [ "$status" -ne 124 ] || fail "arm with an unusable confirm window never stopped: $(cat "$armout")"
  [ "$status" -ne 0 ] || fail "arm reported success with an unusable confirm window: $(cat "$armout")"
  grep -q '^watcher: FAILED' "$armout" \
    || fail "arm did not report the typed failure line: $(cat "$armout")"
  grep -qF 'FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS' "$armout" \
    || fail "the refusal did not name the variable: $(cat "$armout")"
  grep -qF "must be whole seconds from 1 to 600" "$armout" \
    || fail "the refusal did not name the accepted range: $(cat "$armout")"
  ! grep -q '^watcher: started' "$armout" \
    || fail "arm reported a started watcher despite the refusal: $(cat "$armout")"
  [ ! -e "$state/.last-watcher-beat" ] \
    || fail "a refused watcher still published a liveness beacon"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ -z "$lock_pid" ] || ! kill -0 "$lock_pid" 2>/dev/null \
    || fail "a refused watcher is still running as pid $lock_pid"
  pass "watch-arm: an unusable launch confirm window refuses to arm by name"
}

# A watcher armed from a disposable no-mistakes validation checkout outlives the
# validation step and keeps writing the real home's state from a path about to be
# deleted (upstream #321). The arm must refuse before touching any state. The
# fixture reaches this checkout's real arm through a symlink whose logical path
# sits under .no-mistakes/worktrees/, with the test harness's own bypass cleared
# for this one launch.
test_arm_refuses_a_disposable_validation_checkout() {
  local dir home state fakebin armout status link
  dir=$(make_case disposable-checkout-refusal)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  link="$dir/.no-mistakes/worktrees/run-1/firstmate"
  mkdir -p "$home/data" "$(dirname "$link")"
  ln -s "$ROOT" "$link"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_GATE_REFUSE_BYPASS='' \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT=5 "$link/bin/fm-watch-arm.sh" > "$armout" 2>&1 &
  ARM_PID=$!
  wait_for_exit "$ARM_PID" 200
  status=$?
  [ "$status" -ne 124 ] || fail "arm from a disposable checkout never stopped: $(cat "$armout")"
  [ "$status" -ne 0 ] || fail "arm from a disposable checkout reported success: $(cat "$armout")"
  grep -q '^watcher: FAILED' "$armout" \
    || fail "arm did not report the typed failure line: $(cat "$armout")"
  grep -qF 'disposable validation checkout' "$armout" \
    || fail "the refusal did not name the disposable checkout: $(cat "$armout")"
  ! grep -q '^watcher: started' "$armout" \
    || fail "arm reported a started watcher despite the refusal: $(cat "$armout")"
  [ ! -e "$state/.last-watcher-beat" ] \
    || fail "a refused watcher still published a liveness beacon"
  [ ! -e "$state/.watch.lock" ] \
    || fail "a refused watcher still took the singleton lock"
  pass "watch-arm: a disposable validation checkout refuses to arm"
}

# The deletion cases need a watcher between polls, not an arm startup deadline.
# Hold its first terminal sleep until deletion, so first-poll writes cannot race
# the fixture's removal before the next home/state existence check.
WATCH_PID=
start_removal_watcher() {  # <home> <state> <fakebin> <watch-out>
  local home=$1 state=$2 fakebin=$3 armout=$4 i real_sleep
  real_sleep=$(command -v sleep)
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = 1 ] && [ "$PPID" = "$(cat "$FM_STATE_OVERRIDE/.watch.lock/pid" 2>/dev/null)" ]; then
  printf 'ready\n' > "$FM_STATE_OVERRIDE/.removal-poll-ready"
  while [ -d "$FM_HOME" ] && [ -d "$FM_STATE_OVERRIDE" ] && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do
    "$FM_TEST_REAL_SLEEP" 0.1
  done
fi
exec "$FM_TEST_REAL_SLEEP" "$@"
SH
  chmod +x "$fakebin/sleep"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_TEST_REAL_SLEEP="$real_sleep" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$armout" 2>&1 &
  WATCH_PID=$!
  i=0
  while [ "$i" -lt 100 ]; do
    [ -e "$state/.removal-poll-ready" ] && break
    is_live_non_zombie "$WATCH_PID" || break
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$state/.removal-poll-ready" ] \
    || fail "watcher did not finish its first poll: $(cat "$armout")"
}

# Start a real watcher through the real arm for a temporary home and set
# ARM_PID and WATCH_PID from the arm's started line. Both stdout and stderr land
# in <arm-out> so the watcher's own exit reason is readable there.
start_owned_watcher() {  # <home> <state> <fakebin> <arm-out>
  local home=$1 state=$2 fakebin=$3 armout=$4 i
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT=2 "$WATCH_ARM" > "$armout" 2>&1 &
  ARM_PID=$!
  i=0
  while [ "$i" -lt 100 ]; do
    grep -q '^watcher: started pid=' "$armout" 2>/dev/null && break
    is_live_non_zombie "$ARM_PID" || break
    sleep 0.1
    i=$((i + 1))
  done
  WATCH_PID=$(sed -n 's/^watcher: started pid=\([0-9][0-9]*\).*/\1/p' "$armout" | head -1)
  [ -n "$WATCH_PID" ] || fail "arm did not start a watcher: $(cat "$armout")"
}

# Also supports watchers owned by another arm, so wait on liveness only.
wait_for_pid_gone() {  # <pid> <polls>
  local pid=$1 limit=$2 i=0
  while [ "$i" -lt "$limit" ]; do
    is_live_non_zombie "$pid" || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# A running watcher whose state directory is deleted (a torn-down temporary
# home) must exit after noticing the deletion with a logged reason, not run on
# as an orphan (upstream #4760). Allow for a slow CI runner finishing the cycle
# already in progress before its next FM_POLL=1 tick. A busy poll may spend
# longer than ten seconds in subprocesses on a contended CI runner.
test_watcher_exits_when_its_state_directory_is_removed() {
  local dir home state fakebin armout
  dir=$(make_case state-dir-removed)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  mkdir -p "$home/data"
  start_removal_watcher "$home" "$state" "$fakebin" "$armout"

  rm -rf "$state"
  wait_for_pid_gone "$WATCH_PID" 400 \
    || { kill -TERM "$WATCH_PID" 2>/dev/null; fail "watcher pid $WATCH_PID outlived its deleted state directory"; }
  wait_for_exit "$WATCH_PID" 100 >/dev/null 2>&1 || true
  grep -qF 'watcher: exiting - state directory' "$armout" \
    || fail "watcher did not log the state-gone exit reason: $(cat "$armout")"
  ! grep -q '^signal:\|^check:\|^stale:\|^heartbeat' "$armout" \
    || fail "a state-gone exit was reported as an actionable wake: $(cat "$armout")"
  pass "watch-arm: a watcher exits when its state directory is removed"
}

# The same for a deleted home whose state directory still exists elsewhere: the
# lock is released through the ordinary cleanup so nothing stale is left behind.
test_watcher_exits_when_its_home_is_removed() {
  local dir home state fakebin armout
  dir=$(make_case home-removed)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  mkdir -p "$home/data"
  start_removal_watcher "$home" "$state" "$fakebin" "$armout"

  rm -rf "$home"
  wait_for_pid_gone "$WATCH_PID" 400 \
    || { kill -TERM "$WATCH_PID" 2>/dev/null; fail "watcher pid $WATCH_PID outlived its deleted home"; }
  wait_for_exit "$WATCH_PID" 100 >/dev/null 2>&1 || true
  grep -qF 'watcher: exiting - home no longer exists' "$armout" \
    || fail "watcher did not log the home-gone exit reason: $(cat "$armout")"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" != "$WATCH_PID" ] \
    || fail "the exited watcher left its lock in place"
  pass "watch-arm: a watcher exits when its home is removed"
}

# An arm whose repository root is deleted mid-flight - the temporary root of a
# torn-down test fixture - must exit within its stated bound with the typed
# ground-removed line instead of polling for a successor that cannot come. The
# owning arm first proves a state directory that does not exist yet is created,
# not mistaken for a removed one. The root's bin is a symlink to this checkout's
# bin, so removing the root removes the arm's script path too.
test_attached_arm_exits_when_its_root_is_removed() {
  local dir repo state fakebin ownerout armout owner attached status
  dir=$(make_case root-removed)
  repo="$dir/repo"
  state="$repo/state"
  fakebin="$dir/fakebin"
  ownerout="$dir/owner.out"
  armout="$dir/arm.out"
  mkdir -p "$repo/data"
  ln -s "$ROOT/bin" "$repo/bin"
  fm_test_track_watcher_state "$state"
  WATCH_ARM="$repo/bin/fm-watch-arm.sh" start_owned_watcher "$repo" "$state" "$fakebin" "$ownerout"
  owner=$ARM_PID
  [ -d "$state" ] || fail "the owning arm did not create the not-yet-existing state directory"
  PATH="$fakebin:$PATH" FM_HOME="$repo" FM_STATE_OVERRIDE="$state" FM_POLL=1 \
    FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=60 "$repo/bin/fm-watch-arm.sh" > "$armout" 2>&1 &
  attached=$!
  wait_for_file_text "$armout" "watcher: attached pid=$WATCH_PID" \
    || fail "second arm did not attach to the live watcher: $(cat "$armout")"

  rm -rf "$repo"
  # One 0.1s attach poll plus the 0.2s recheck, with headroom for a busy host;
  # far short of the 60s successor window the arm used to poll through.
  wait_for_exit "$attached" 50
  status=$?
  wait_for_exit "$owner" 400 >/dev/null 2>&1 || true
  expect_code 1 "$status" "an arm whose root was removed must exit 1: $(cat "$armout")"
  grep -qF "watcher: FAILED - arm ground removed: $repo/bin/fm-watch-arm.sh no longer exists" "$armout" \
    || fail "arm did not report its removed ground: $(cat "$armout")"
  pass "watch-arm: an attached arm exits within its bound when its root is removed"
}

# tests/lib.sh's exit-time reaper must stop a watcher a suite armed for a
# temporary home, through the home-scoped stop, so no test leaves one behind.
# The reaper is driven with a private registry so this suite's own registry
# keeps covering the other cases.
test_reaper_stops_a_tracked_watcher() {
  local dir state fakebin out
  dir=$(make_case reaper)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  printf '%s\n' "$state" > "$dir/registry"
  ( FM_TEST_WATCHER_REGISTRY="$dir/registry"; fm_test_reap_watchers )
  wait_for_exit "$SEED_PID" 100 >/dev/null 2>&1 || true
  ! is_live_non_zombie "$SEED_PID" \
    || { kill -TERM "$SEED_PID" 2>/dev/null; fail "reaper left the tracked watcher pid $SEED_PID running"; }
  [ ! -e "$dir/registry" ] || fail "reaper did not consume its registry"
  pass "watch-arm: the test reaper stops a watcher armed for a tracked temporary home"
}

# A handling-delivery confirmation for an episode the drain already
# acknowledged must succeed as a no-op when the generation matches: the pid is
# alive and holds the lock, so the handling is already retired, not rejected.
# A mismatched generation, a dead pid, and a lock mismatch stay rejections.
test_handling_delivered_accepts_already_acked_generation() {
  local dir home state pid identity generation status dead
  dir=$(make_case handling-delivered-acked)
  home="$dir/home"
  state="$dir/state"
  mkdir -p "$home/data" "$state/.watch.lock"
  sleep 60 &
  pid=$!
  identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid") \
    || fail "could not read the fixture watcher identity"
  printf '%s' "$home" > "$state/.watch.lock/fm-home"
  printf '%s' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s' "$identity" > "$state/.watch.lock/pid-identity"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_recovery_marker_publish "$2" downtime' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$state/.watcher-down" \
    || fail "could not publish the fixture downtime episode"
  generation=$(recovery_marker_generation "$state/.watcher-down")
  [ -n "$generation" ] || fail "published episode left no recovery generation"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --handling-delivered "$generation" \
    --watcher-pid "$pid" || fail "confirmed prompt delivery did not begin handling"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_recovery_marker_ack "$2" "$3"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$state/.watcher-down" "$generation" \
    || fail "could not acknowledge the fixture handling episode"
  case "$(cat "$state/.watcher-down")" in
    acked:handling:"$generation") ;;
    *) fail "acknowledged episode did not retire: $(cat "$state/.watcher-down")" ;;
  esac
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --handling-delivered "$generation" \
    --watcher-pid "$pid"
  expect_code 0 "$?" "an already-acknowledged confirmation must succeed as a no-op"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --handling-delivered "superseded.0.deadbeef" \
    --watcher-pid "$pid" 2>/dev/null
  expect_code 3 "$?" "a superseded generation must stay rejected"
  sleep 0 &
  dead=$!
  wait "$dead" 2>/dev/null || true
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --handling-delivered "$generation" \
    --watcher-pid "$dead" 2>/dev/null
  expect_code 1 "$?" "a dead watcher pid must stay rejected"
  printf 'foreign-identity\n' > "$state/.watch.lock/pid-identity"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --handling-delivered "$generation" \
    --watcher-pid "$pid" 2>/dev/null
  status=$?
  printf '%s' "$identity" > "$state/.watch.lock/pid-identity"
  expect_code 1 "$status" "a lock mismatch must stay rejected"
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "watch-arm: an already-acknowledged handling confirmation succeeds as a no-op"
}

# A non-successor arm start mints a fresh generation, and a confirmation for
# the churned generation reports a mismatch (status 3). The closing arm check
# without a reopen - the marker step a handling successor runs - keeps the
# churned generation. This characterizes existing marker behavior that the Pi
# superseded-delivery path relies on.
test_handling_delivered_rejects_a_superseded_generation() {
  local dir home state pid identity first second status
  dir=$(make_case handling-delivered-superseded)
  home="$dir/home"
  state="$dir/state"
  mkdir -p "$home/data" "$state/.watch.lock"
  sleep 60 &
  pid=$!
  identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid") \
    || fail "could not read the fixture watcher identity"
  printf '%s' "$home" > "$state/.watch.lock/fm-home"
  printf '%s' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s' "$identity" > "$state/.watch.lock/pid-identity"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_recovery_marker_publish "$2" downtime && fm_recovery_marker_arm_check "$2"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$state/.watcher-down" \
    || fail "could not announce the fixture downtime episode"
  first=$(recovery_marker_generation "$state/.watcher-down")
  case "$(cat "$state/.watcher-down")" in
    acked:downtime:"$first") ;;
    *) fail "empty episode was not retired silently: $(cat "$state/.watcher-down")" ;;
  esac
  # Reopening mints a fresh generation only when unrecovered work is queued:
  # after the empty episode retires, queue one wake and announce its episode.
  # Without queued work the reopen below is a no-op by design (no idle churn).
  append_wake "$state" check inbox:fixture 'check: manual-restart churn fixture' \
    || fail "could not queue the fixture wake for the manual restart"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_recovery_marker_arm_check "$2"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$state/.watcher-down" \
    || fail "could not re-announce the queued fixture episode"
  first=$(recovery_marker_generation "$state/.watcher-down")
  case "$(cat "$state/.watcher-down")" in
    announced:downtime:"$first") ;;
    *) fail "queued episode has the wrong shape: $(cat "$state/.watcher-down")" ;;
  esac
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_recovery_marker_reopen_announced "$2"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$state/.watcher-down" \
    || fail "a manual arm start could not reopen the announced episode"
  second=$(recovery_marker_generation "$state/.watcher-down")
  [ -n "$second" ] && [ "$second" != "$first" ] \
    || fail "a non-successor arm start did not mint a fresh generation: $(cat "$state/.watcher-down")"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --handling-delivered "$first" \
    --watcher-pid "$pid" 2>/dev/null
  expect_code 3 "$?" "a confirmation for the churned generation must report a mismatch"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_recovery_marker_arm_check "$2"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$state/.watcher-down" \
    || fail "the arm check after the reopen could not run"
  status=$(recovery_marker_generation "$state/.watcher-down")
  [ "$status" = "$second" ] \
    || fail "an arm check without a reopen minted another generation: $(cat "$state/.watcher-down")"
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "watch-arm: a churned generation's handling confirmation reports a mismatch and an arm check keeps it"
}

# The OpenCode arm plugin must decide whether to arm with the shared supervision
# predicate (bin/fm-supervision-lib.sh's fm_supervision_needed), the same
# condition owner bin/fm-turnend-guard.sh decides with, so the plugin and the
# guard can never disagree about whether a watcher is needed. The fixture is a
# minimal primary root carrying the real shared predicate, a home whose state
# directory receives each case's records, and a fake arm that records its own
# run; the plugin is exercised through its public coordinator interface.
make_arm_decision_fixture() {  # <name>
  local name=$1 dir repo home
  dir=$(make_case "$name")
  repo="$dir/repo"
  home="$dir/home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q -b main "$repo"
  : > "$repo/AGENTS.md"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$repo/bin/fm-supervision-lib.sh"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  printf '%s\n' "$dir"
}

test_opencode_arm_plugin_decides_with_the_shared_predicate() {
  command -v node >/dev/null 2>&1 || { printf 'skip: node not found\n'; return 0; }
  local driver case_name dir state config out status
  driver="$TMP_ROOT/arm-decision-driver.mjs"
  cat > "$driver" <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const state = `${process.env.FM_HOME}/state`;
const config = `${process.env.FM_HOME}/config`;
const armLog = process.env.FM_ARM_LOG;

// The shared predicate verdict over the same state directory and the same lib
// copy the delegation in the plugin sources.
const probe = spawnSync(
  "bash",
  [
    "-c",
    '. "$1/bin/fm-supervision-lib.sh"; if fm_supervision_needed "$2"; then printf arm; else printf no-arm; fi',
    "predicate-probe",
    process.env.FM_ROOT_OVERRIDE,
    state,
  ],
  { encoding: "utf8" },
);
const verdict = String(probe.stdout || "").trim();
if (verdict !== "arm" && verdict !== "no-arm") {
  console.error(`predicate probe failed (status ${probe.status}): ${probe.stderr}`);
  process.exit(1);
}

// The two local overrides: an away record declines even when the predicate
// reads needed, because away mode owns supervision through its daemon, and an
// x-mode home arms before its relay poll is registered. Every other state
// directory must match the shared verdict exactly.
let expected;
if (existsSync(`${state}/.afk`)) {
  if (verdict !== "arm") {
    console.error(`afk fixture lost its registered need: predicate said ${verdict}`);
    process.exit(1);
  }
  expected = "no-arm";
} else if (existsSync(`${config}/x-mode.env`)) {
  if (verdict !== "no-arm") {
    console.error(`x-mode fixture unexpectedly reads as needed: predicate said ${verdict}`);
    process.exit(1);
  }
  expected = "arm";
} else {
  expected = verdict;
}

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
await mod.FmPrimaryWatchArm({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const status = await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("session-test", client);
if (expected === "no-arm") {
  if (status !== "not-needed") {
    console.error(`expected a not-needed decline, got ${status}`);
    process.exit(1);
  }
  if (existsSync(armLog)) {
    console.error("the plugin declined but the arm ran");
    process.exit(1);
  }
  process.exit(0);
}
for (let i = 0; i < 250 && !existsSync(armLog); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(armLog)) {
  console.error(`the arm never ran (ensureArmed status ${status})`);
  process.exit(1);
}
process.exit(0);
EOF
  for case_name in source registered-check empty afk-with-source task-meta x-mode; do
    dir=$(make_arm_decision_fixture "opencode-arm-$case_name")
    state="$dir/home/state"
    config="$dir/home/config"
    case "$case_name" in
      source) mkdir -p "$state/procevent"; : > "$state/procevent/fixture.source" ;;
      registered-check) : > "$state/fixture.check.sh"; : > "$state/fixture.check-trust" ;;
      empty) : ;;
      afk-with-source)
        mkdir -p "$state/procevent"
        : > "$state/procevent/fixture.source"
        : > "$state/.afk"
        ;;
      task-meta) : > "$state/fixture.meta" ;;
      x-mode) : > "$config/x-mode.env" ;;
    esac
    out=$(FM_ROOT_OVERRIDE="$dir/repo" WORKTREE="$dir/repo" FM_HOME="$dir/home" \
      FM_ARM_LOG="$dir/arm.log" NODE_NO_WARNINGS=1 \
      PLUGIN="$ROOT/.opencode/plugins/fm-primary-watch-arm.js" node "$driver" 2>&1)
    status=$?
    expect_code 0 "$status" "OpenCode arm plugin must decide with the shared predicate ($case_name): $out"
    [ -z "$out" ] || fail "OpenCode arm predicate case $case_name printed output: $out"
  done
  pass "watch-arm: the OpenCode arm plugin decides with the shared supervision predicate"
}

# Two idle in-flight windows, pre-seeded so the next poll is already stale.
# The first notice exits the watcher; the second is still unreported.
seed_two_stale_windows() {  # <state> <capture-file>
  local state=$1 capture=$2 hash key window
  printf 'idle finished worker\n' > "$capture"
  if command -v md5 >/dev/null 2>&1; then
    hash=$(md5 -q "$capture")
  else
    hash=$(md5sum "$capture" | awk '{print $1}')
  fi
  for window in test:fm-a-first test:fm-b-second; do
    key=${window//[:\/.]/_}
    printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/${window#test:fm-}.meta"
    printf 'working [at=1]: in flight\n' > "$state/${window#test:fm-}.status"
    prime_status_seen "$state" "$state/${window#test:fm-}.status"
    printf '%s' "$hash" > "$state/.hash-$key"
    printf '1\n' > "$state/.count-$key"
  done
  touch "$state/.last-check" "$state/.last-heartbeat"
}

# A plain git primary whose bin is the copy under test, so the turn-end guard
# and the watcher lock name the same fm-watch.sh. This worktree is exempt.
make_grok_guard_primary() {  # <name>
  local dir=$1 primary
  primary="$dir/primary"
  stop_primary_watcher "$primary"
  rm -rf "$primary"
  mkdir -p "$primary/state" "$primary/docs"
  git init -q "$primary"
  git -C "$primary" commit -q --allow-empty -m init
  : > "$primary/AGENTS.md"
  cp -R "$ROOT/bin" "$primary/bin"
  cp -R "$ROOT/docs/supervision-protocols" "$primary/docs/supervision-protocols"
  fm_test_track_watcher_state "$primary/state"
  cd "$primary" && pwd
}

stop_primary_watcher() {  # <primary>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_ROOT_OVERRIDE="$1" \
    "$1/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
}

primary_watcher_healthy() {  # <primary>
  local primary=$1
  FM_STATE_OVERRIDE="$primary/state" bash -c '
    . "$1"
    fm_watcher_healthy "$2" "$3" 300 "$4"
  ' _ "$primary/bin/fm-wake-lib.sh" "$primary/state" "$primary/bin/fm-watch.sh" "$primary"
}

run_grok_turnend_guard() {  # <primary>
  local primary=$1 fakebin
  fakebin=$(fm_fakebin "$primary/guard-ancestry")
  fm_fake_blind_ancestry "$fakebin"
  # Model a Grok hook independently of the test runner's harness.
  printf '%s' '{"sessionId":"grok-stale","stopHookActive":false}' \
    | env -u GROK_TURNEND_GUARD_ACTIVE \
      PATH="$fakebin:$PATH" GROK_AGENT=1 \
      GROK_WORKSPACE_ROOT="$primary" \
      FM_HOME="$primary" \
      FM_ROOT_OVERRIDE="$primary" \
      FM_STATE_OVERRIDE="$primary/state" \
      bash "$primary/bin/fm-turnend-guard-grok.sh" 2>&1
}

# Run one arm against two already-stale windows. Echoes "pid status" after exit.
run_grok_arm_case() {  # <primary> <fakebin> <capture> <arm-out> <continuity 0|1> <afk 0|1|quiet>
  local primary=$1 fakebin=$2 capture=$3 armout=$4 continuity=$5 afk=$6 pid
  seed_two_stale_windows "$primary/state" "$capture"
  [ "$afk" = 1 ] && : > "$primary/state/.afk"
  [ "$afk" = quiet ] && printf 'quiet\n' > "$primary/state/.afk"
  PATH="$fakebin:$PATH" \
    FM_HOME="$primary" FM_STATE_OVERRIDE="$primary/state" FM_ROOT_OVERRIDE="$primary" \
    FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT=20 \
    FM_WATCH_GROK_CONTINUITY="$continuity" \
    "$primary/bin/fm-watch-arm.sh" > "$armout" &
  pid=$!
  wait_for_exit "$pid" 400
  printf '%s\n' "$?"
}

test_grok_one_stale_notice_leaves_the_watcher_holding_the_lock() {
  local dir fakebin capture primary armout guard_out status posture i
  dir=$(make_case grok-one-stale-notice)
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"
  primary=$(make_grok_guard_primary "$dir")
  armout="$dir/continuity.out"
  status=$(run_grok_arm_case "$primary" "$fakebin" "$capture" "$armout" 1 0)
  expect_code 0 "$status" "grok continuity arm must return the notice: $(cat "$armout" 2>/dev/null)"
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$armout" \
    || fail "grok continuity arm did not return an actionable notice: $(cat "$armout")"
  # Observe delivery before checking the turn-end gap; a loaded first poll can
  # take longer than the gap itself.
  i=0
  while ! grep -F 'stale: test:fm-b-second' "$primary/state/.wake-queue" >/dev/null 2>&1 && [ "$i" -lt 400 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  grep -F 'stale: test:fm-b-second' "$primary/state/.wake-queue" >/dev/null \
    || fail "the successor did not queue the second stale window: $(cat "$primary/state/.wake-queue" 2>/dev/null)"
  # A one-shot successor dies after that delivery. It must hold past the gap.
  sleep 4
  primary_watcher_healthy "$primary" \
    || fail "one actionable notice left no live watcher holding the lock: $(cat "$armout")"
  guard_out=$(run_grok_turnend_guard "$primary"); status=$?
  expect_code 0 "$status" "grok turn-end guard must allow a stop while the successor holds the lock: $guard_out"
  assert_not_contains "$guard_out" "no live watcher holds this home lock" \
    "grok turn-end guard reported supervision down while the successor held the lock: $guard_out"
  stop_primary_watcher "$primary"

  primary=$(make_grok_guard_primary "$dir")
  armout="$dir/plain.out"
  status=$(run_grok_arm_case "$primary" "$fakebin" "$capture" "$armout" 0 0)
  expect_code 0 "$status" "plain arm must still return the notice: $(cat "$armout" 2>/dev/null)"
  sleep 2
  if primary_watcher_healthy "$primary"; then
    stop_primary_watcher "$primary"
    fail "plain arm left a watcher holding the lock after one notice"
  fi
  guard_out=$(run_grok_turnend_guard "$primary"); status=$?
  expect_code 2 "$status" "plain arm must still make the grok turn-end guard block: $guard_out"
  assert_contains "$guard_out" "no live watcher holds this home lock" \
    "plain arm's turn-end block lost the unsupervised-lock line: $guard_out"
  stop_primary_watcher "$primary"

  for posture in 1 quiet; do
    primary=$(make_grok_guard_primary "$dir")
    armout="$dir/afk-$posture.out"
    status=$(run_grok_arm_case "$primary" "$fakebin" "$capture" "$armout" 1 "$posture")
    expect_code 0 "$status" "away/quiet-mode grok arm must still return the notice: $(cat "$armout" 2>/dev/null)"
    sleep 2
    if primary_watcher_healthy "$primary"; then
      stop_primary_watcher "$primary"
      fail "away/quiet mode ($posture) started a grok successor after one notice"
    fi
    stop_primary_watcher "$primary"
  done
  pass "grok: one stale notice leaves a successor holding the lock, and plain, away, and quiet arms stay one-shot"
}

# The process-event wake consumes its post-output callback, and the holding
# watcher's next wake must still read that variable under set -u.
test_grok_hold_survives_a_wake_after_a_process_event_wake() {
  local dir out status
  dir=$(make_case grok-procevent-then-stale)
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_WATCH_GROK_HOLD=1 bash -uc '
    . "$1"
    fm_wake_append check procevent:probe:1 "check: process-event result captured:procevent:probe:1"
    procevent_surface_queued
    wake "stale: second actionable event"
  ' _ "$WATCH" 2>&1)
  status=$?
  expect_code 0 "$status" "grok hold watcher must survive a wake after a process-event wake: $out"
  assert_not_contains "$out" "unbound variable" \
    "grok hold watcher read a consumed post-output callback as unbound: $out"
  assert_contains "$out" "stale: second actionable event" \
    "grok hold watcher did not report the wake after the process-event wake: $out"
  pass "grok: a holding watcher reports a second wake after a process-event wake"
}

test_grok_successor_holds_across_quiet_polls_after_a_process_event() {
  local dir primary status guard_out i arm_pid DRAIN
  dir=$(make_case grok-arm-procevent-quiet-stale)
  primary=$(make_grok_guard_primary "$dir")
  FM_STATE_OVERRIDE="$primary/state" bash -c '
    . "$1"
    fm_wake_append check procevent:probe:1 "check: process-event result captured:procevent:probe:1"
  ' _ "$primary/bin/fm-wake-lib.sh"
  # The seeded file hash includes a trailing newline; pane capture strips it.
  # The successor must reset the hash, poll quietly, then surface stale panes.
  status=$(run_grok_arm_case "$primary" "$dir/fakebin" "$dir/capture" "$dir/arm.out" 1 0)
  expect_code 0 "$status" "Grok arm must return the process-event wake: $(cat "$dir/arm.out")"
  assert_contains "$(cat "$dir/arm.out")" "check: process-event result captured:" \
    "Grok arm did not return the queued process-event wake"
  for ((i=0; i<200; i++)); do
    grep -F 'stale: test:fm-b-second' "$primary/state/.wake-queue" >/dev/null 2>&1 && break
    primary_watcher_healthy "$primary" || break
    sleep 0.1
  done
  primary_watcher_healthy "$primary" \
    || fail "actual Grok successor stopped holding the lock after a quiet poll"
  grep -F 'stale: test:fm-a-first' "$primary/state/.wake-queue" >/dev/null \
    || fail "Grok successor did not queue the first stale pane after quiet polls"
  grep -F 'stale: test:fm-b-second' "$primary/state/.wake-queue" >/dev/null \
    || fail "Grok successor did not queue the second stale pane after quiet polls"
  guard_out=$(run_grok_turnend_guard "$primary"); status=$?
  expect_code 0 "$status" "Grok turn-end guard must allow the holding successor: $guard_out"
  DRAIN="$primary/bin/fm-wake-drain.sh"
  FM_HOME="$primary" FM_ROOT_OVERRIDE="$primary" ack_wakes "$primary/state" \
    || fail "could not acknowledge the first Grok handling turn"
  PATH="$dir/fakebin:$PATH" \
    FM_HOME="$primary" FM_STATE_OVERRIDE="$primary/state" FM_ROOT_OVERRIDE="$primary" \
    FM_FAKE_TMUX_CAPTURE="$dir/capture" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT=20 FM_WATCH_GROK_CONTINUITY=1 \
    "$primary/bin/fm-watch-arm.sh" > "$dir/handoff.out" 2>&1 &
  arm_pid=$!
  for ((i=0; i<200; i++)); do
    grep -Eq '^watcher: (started|attached) pid=' "$dir/handoff.out" && break
    is_live_non_zombie "$arm_pid" || break
    sleep 0.1
  done
  for ((i=0; i<10; i++)); do
    if ! is_live_non_zombie "$arm_pid" || [ -s "$primary/state/.wake-queue" ]; then
      kill -TERM "$arm_pid" 2>/dev/null || true
      wait "$arm_pid" 2>/dev/null || true
      stop_primary_watcher "$primary"
      fail "Grok re-arm completed or queued a wake before new work arrived: $(cat "$dir/handoff.out")"
    fi
    sleep 0.1
  done
  printf 'done [at=2]: fresh tracked-arm wake\n' >> "$primary/state/a-first.status"
  wait_for_exit "$arm_pid" "$REARM_EXIT_POLLS"; status=$?
  expect_code 0 "$status" "the next tracked Grok arm did not complete for fresh work: $(cat "$dir/handoff.out")"
  grep -Eq '^(signal:|check:)' "$dir/handoff.out" \
    || fail "the next tracked Grok arm returned without an actionable notice"
  grep -F "signal: $primary/state/a-first.status" "$primary/state/.wake-queue" >/dev/null \
    || fail "the fresh Grok wake was not durable"
  primary_watcher_healthy "$primary" || fail "the next Grok notice left no healthy holding watcher"
  # The arm can return queued work before the holding watcher finishes its
  # signal-protected delivery. Stop only after that watcher resumes polling.
  touch "$dir/before-stop"
  for ((i=0; i<200; i++)); do
    [ "$primary/state/.last-watcher-beat" -nt "$dir/before-stop" ] && break
    sleep 0.1
  done
  [ "$primary/state/.last-watcher-beat" -nt "$dir/before-stop" ] \
    || fail "the Grok successor never resumed polling after its wake"
  FM_HOME="$primary" FM_STATE_OVERRIDE="$primary/state" FM_ROOT_OVERRIDE="$primary" \
    "$primary/bin/fm-watch-arm.sh" --stop > "$dir/stop.out" 2>&1
  status=$?
  expect_code 0 "$status" "explicit Grok stop failed: $(cat "$dir/stop.out")"
  if primary_watcher_healthy "$primary"; then
    fail "explicit stop left the Grok successor holding the home lock"
  fi
  pass "grok: the real arm holds across quiet polls and the next tracked arm delivers fresh work"
}

run_detach_hold() {  # <primary> [env assignment...]
  local primary=$1
  shift
  env -u TMUX -u TMUX_PANE -u HERDR_SESSION -u HERDR_PANE_ID "$@" \
    FM_HOME="$primary" FM_STATE_OVERRIDE="$primary/state" FM_ROOT_OVERRIDE="$primary" \
    FM_CONFIG_OVERRIDE="$primary/config" FM_ARM_CONFIRM_TIMEOUT="$REARM_CONFIRM_SECONDS" \
    "$primary/bin/fm-watch-arm.sh" --detach-hold
}

test_detach_hold_leaves_a_hold_behind_the_arm() {
  local dir primary out status pid
  dir=$(make_case detach-hold-real)
  primary=$(make_grok_guard_primary "$dir")
  out=$(run_detach_hold "$primary" PATH="$dir/fakebin:$PATH" 2>&1); status=$?
  expect_code 0 "$status" "detach-hold must confirm its hold: $out"
  assert_contains "$out" "watcher: started pid=" "detach-hold must report the started hold"
  primary_watcher_healthy "$primary" || fail "no healthy watcher holds the lock after the arm exited"
  pid=$(cat "$primary/state/.watch.lock/pid")
  assert_contains "$(ps -o args= -p "$pid")" "--grok-hold" "the surviving watcher must be the detached hold"
  out=$(run_detach_hold "$primary" PATH="$dir/fakebin:$PATH" 2>&1); status=$?
  expect_code 0 "$status" "detach-hold must attach to a healthy watcher: $out"
  assert_contains "$out" "watcher: attached pid=$pid" "detach-hold must report the attach"
  stop_primary_watcher "$primary"
  pass "detach-hold: the real arm exits 0, leaves a hold on the lock, and attaches on the next call"
}

test_detach_hold_refuses_away_mode_and_reports_failure() {
  local dir primary out status
  dir=$(make_case detach-hold-refuse)
  primary=$(make_grok_guard_primary "$dir")
  : > "$primary/state/.afk"
  out=$(run_detach_hold "$primary" 2>&1); status=$?
  expect_code 1 "$status" "detach-hold must refuse while state/.afk exists: $out"
  [ ! -e "$primary/state/.watch.lock/pid" ] || fail "away-mode detach-hold started a watcher"
  rm -f "$primary/state/.afk"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$primary/bin/fm-watch.sh"
  out=$(run_detach_hold "$primary" 2>&1); status=$?
  expect_code 1 "$status" "detach-hold must fail when its watcher dies: $out"
  assert_contains "$out" "watcher: FAILED" "detach-hold must print its typed failure"
  pass "detach-hold: state/.afk refuses it, and a dead watcher exits with a FAILED line"
}

test_detach_hold_leaves_a_hold_behind_the_arm
test_detach_hold_refuses_away_mode_and_reports_failure
test_grok_one_stale_notice_leaves_the_watcher_holding_the_lock
test_grok_hold_survives_a_wake_after_a_process_event_wake
test_grok_successor_holds_across_quiet_polls_after_a_process_event
test_append_wakes_handling_successor after-ack
test_append_wakes_handling_successor before-ack
test_append_wakes_handling_successor after-ack missing
test_append_wakes_handling_successor before-ack missing
test_append_wakes_handling_successor after-ack malformed
test_append_wakes_handling_successor before-ack malformed
test_append_wakes_handling_successor after-ack missing identical
test_append_wakes_handling_successor after-ack malformed identical
test_attached_arm_reports_the_delivered_wake
test_attached_arm_reports_the_delivered_wake_after_drain
test_arm_refuses_an_unusable_launch_confirm_window
test_arm_refuses_a_disposable_validation_checkout
test_watcher_exits_when_its_state_directory_is_removed
test_watcher_exits_when_its_home_is_removed
test_attached_arm_exits_when_its_root_is_removed
test_reaper_stops_a_tracked_watcher
test_attached_arm_still_fails_on_a_wake_it_did_not_deliver
test_attached_arm_follows_a_slow_live_holder
test_attached_arm_hands_a_stalled_holder_to_its_replacement
test_stalled_arms_preserve_delivered_wakes
test_rearm_resurfaces_durable_queue_and_remote_open_decision
test_empty_queue_rearm_stays_silent
test_slow_rearm_recovery_is_still_surfaced
test_marker_publish_failure_retains_recovery_evidence
test_delivery_gap_wake_is_recovered_once
test_interrupted_handling_is_redrained_on_rearm
test_malformed_marker_is_quarantined_once
test_recovery_consumption_serializes_queue_publication
test_restart_preserves_recovery_across_reused_pid_lock
test_markerless_legacy_queue_is_recovered_on_arm
test_idle_lavish_source_stays_quiet_until_result
test_append_wakes_live_announced_watcher
test_handling_window_close_keeps_the_acknowledgement_valid
test_moved_generation_acknowledgement_is_self_healing
test_downtime_marker_does_not_follow_symlink
test_stop_ends_the_home_watcher_and_publishes_downtime
test_handling_delivered_accepts_already_acked_generation
test_handling_delivered_rejects_a_superseded_generation
test_take_over_attaches_to_a_cycle_the_named_arm_does_not_own
test_take_over_owns_a_fresh_cycle_and_keeps_queued_work_surfacing
test_take_over_preserves_downtime_from_watcher_self_exit
test_take_over_confirms_a_watcher_stopped_inside_its_event_wait
test_opencode_arm_plugin_decides_with_the_shared_predicate
