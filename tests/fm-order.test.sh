#!/usr/bin/env bash
# tests/fm-order.test.sh - durable captain orders (bin/fm-order.sh).
#
# Covers idempotency (a sender retry and a resend never make or run a second
# order, and concurrent acks yield exactly one reader), the two-stage ack
# (acked on read, then done or parked with an outcome), the captain handle
# resolved at send time, the restart gate, the leash sweep's re-delivery cap
# and one-time escalation, and backward compatibility: a legacy inbox note
# still works unchanged and can be recorded as a durable order.
# The mid-restart pickup by a new captain session is covered in
# tests/fm-session-start.test.sh, where the real session start runs.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-order)
trap fm_test_cleanup EXIT
ORDER_BIN="$ROOT/bin/fm-order.sh"
INBOX_BIN="$ROOT/bin/fm-inbox.sh"

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

run_order() {
  local home=$1
  shift
  env -u FM_ORDER_NUDGE_CMD FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" ${ORDER_ENV:+$ORDER_ENV} bash "$ORDER_BIN" "$@"
}

count_in() {  # <home> <state>
  find "$1/data/orders/$2" -maxdepth 1 -name '*.order' 2>/dev/null | wc -l | tr -d ' '
}

only_id() {  # <home> <state>
  find "$1/data/orders/$2" -maxdepth 1 -name '*.order' | sed 's#.*/##; s/\.order$//'
}

count_events() {  # <home> <event>
  awk -F '\t' -v e="$2" '$4 == e { n++ } END { print n + 0 }' "$1/data/orders/log.tsv"
}

order_wakes() {  # <home>
  if [ -f "$1/state/.wake-queue" ]; then
    grep -c 'order:' "$1/state/.wake-queue" || true
  else
    printf '0\n'
  fi
}

# A nudge stand-in that records which handle each doorbell reached.
NUDGE_LOG="$TMP_ROOT/nudges.log"
NUDGE_STUB="$TMP_ROOT/nudge-stub.sh"
cat >"$NUDGE_STUB" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "\$1" "\$2" >>"$NUDGE_LOG"
SH
chmod +x "$NUDGE_STUB"

write_handle() {  # <home> <backend> <target>
  printf 'backend=%s\ntarget=%s\nat=%s\n' "$2" "$3" "$(date +%s)" >"$1/state/captain-handle"
}

# --- (a) idempotency --------------------------------------------------------

test_send_retry_and_resend_never_run_twice() {
  local home out id i acked
  home=$(make_home idempotent)
  out=$(run_order "$home" send --no-nudge --from shipcontent "nightly: publish the report")
  assert_contains "$out" "queued " "a first send queues the order"
  id=$(only_id "$home" pending)
  case "$id" in [0-9]*-????????) ;; *) fail "order id must be <ts>-<sha8>, got $id" ;; esac
  out=$(run_order "$home" send --no-nudge --from shipcontent "nightly: publish the report")
  assert_contains "$out" "replay $id" "a retry of the same open order replays its id"
  assert_equals 1 "$(count_in "$home" pending)" "a retry must not create a second order"
  out=$(run_order "$home" resend --no-nudge "$id")
  assert_contains "$out" "resent $id" "a resend points at the same file"
  assert_equals 1 "$(count_in "$home" pending)" "a resend must not create a second order"
  assert_equals 2 "$(order_wakes "$home")" "send and resend each append one wake"

  out=$(run_order "$home" ack "$id")
  assert_contains "$out" "acked $id" "the first ack reads the order"
  assert_contains "$out" "nightly: publish the report" "ack prints the order body"
  out=$(run_order "$home" ack "$id")
  assert_contains "$out" "skip $id acked" "an id already in acked/ is skipped"
  out=$(run_order "$home" resend --no-nudge "$id")
  assert_contains "$out" "already acked" "resending an acked order delivers nothing"
  out=$(run_order "$home" send --no-nudge --from shipcontent "nightly: publish the report")
  assert_contains "$out" "replay $id" "a late retry of an acked order replays rather than re-running"
  assert_equals 1 "$(count_events "$home" acked)" "the order is acknowledged exactly once"

  home=$(make_home concurrent-ack)
  run_order "$home" send --no-nudge "one order, many readers" >/dev/null
  id=$(only_id "$home" pending)
  for i in 1 2 3 4 5 6; do
    run_order "$home" ack "$id" >"$TMP_ROOT/ack.$i" 2>&1 &
  done
  wait
  acked=$(cat "$TMP_ROOT"/ack.* | grep -c "^acked $id" || true)
  assert_equals 1 "$acked" "six concurrent acks must yield exactly one reader"
  pass "(a) a retry or resend never makes or runs a second order; concurrent acks read it once"
}

# --- (b) two-stage ack -------------------------------------------------------

test_two_stage_ack_separates_receipt_from_completion() {
  local home id out json
  home=$(make_home two-stage)
  run_order "$home" send --no-nudge --from bot "rotate the logs" >/dev/null
  id=$(only_id "$home" pending)
  json=$(run_order "$home" status --json "$id")
  assert_contains "$json" '"state":"pending"' "an unread order reports pending"
  if run_order "$home" finish "$id" done "too early" >/dev/null 2>&1; then
    fail "an order cannot be finished before it is acknowledged"
  fi
  run_order "$home" ack "$id" >/dev/null
  json=$(run_order "$home" status --json "$id")
  assert_contains "$json" '"state":"acked"' "a read order reports acked (receipt)"
  out=$(run_order "$home" finish "$id" done "logs rotated")
  assert_contains "$out" "done $id" "finish records completion"
  json=$(run_order "$home" status --json "$id")
  assert_contains "$json" '"state":"done"' "a finished order reports done (completion)"
  assert_contains "$(run_order "$home" show "$id")" "logs rotated" "show carries the outcome"

  run_order "$home" send --no-nudge "deploy friday" >/dev/null
  id=$(only_id "$home" pending)
  run_order "$home" ack "$id" >/dev/null
  run_order "$home" finish "$id" parked "waiting on the captain's merge call" >/dev/null
  assert_contains "$(run_order "$home" status "$id")" "$id parked" "parked is a distinct completion state"
  out=$(run_order "$home" send --no-nudge "deploy friday")
  assert_contains "$out" "queued " "the same text after completion is a new order"
  pass "(b) acked on read, then done or parked with an outcome; senders can tell them apart"
}

# --- (c) handle resolved at send time ----------------------------------------

test_handle_is_resolved_at_send_time() {
  local home id out
  home=$(make_home handle)
  : >"$NUDGE_LOG"
  out=$(ORDER_ENV="FM_ORDER_NUDGE_CMD=$NUDGE_STUB" run_order "$home" send --from leash "check the box")
  assert_contains "$out" "nudge=none" "with no captain handle recorded the order is still saved"
  id=$(only_id "$home" pending)
  write_handle "$home" orca term_old
  ORDER_ENV="FM_ORDER_NUDGE_CMD=$NUDGE_STUB" run_order "$home" resend "$id" >/dev/null
  write_handle "$home" orca term_new
  out=$(ORDER_ENV="FM_ORDER_NUDGE_CMD=$NUDGE_STUB" run_order "$home" resend "$id")
  assert_contains "$out" "nudge=sent" "a nudge reaches the recorded handle"
  assert_equals "orca term_old
orca term_new" "$(cat "$NUDGE_LOG")" "each delivery resolves the newest handle at send time"
  assert_equals "orca:term_new" "$(run_order "$home" handle)" "handle prints the current captain handle"
  out=$(FM_SUPERVISOR_TARGET=pane_7 FM_SUPERVISOR_BACKEND=tmux run_order "$home" claim-handle)
  assert_contains "$out" "handle: tmux:pane_7" "claim-handle records this session's terminal"
  assert_equals "tmux:pane_7" "$(run_order "$home" handle)" "the newest claim wins"
  pass "(c) one helper resolves the current captain handle at every send"
}

# --- restart gate -------------------------------------------------------------

test_restart_gate_requires_every_open_order_in_the_handoff() {
  local home rc=0 first second out
  home=$(make_home gate)
  run_order "$home" gate >/dev/null || fail "with no open orders the gate is clear"
  run_order "$home" send --no-nudge "first" >/dev/null
  first=$(only_id "$home" pending)
  run_order "$home" gate >/dev/null || rc=$?
  assert_equals 3 "$rc" "an open order with no handoff blocks the gate"
  out=$(run_order "$home" handoff)
  assert_contains "$out" "$first pending" "the handoff block lists the open order"
  run_order "$home" gate >/dev/null || fail "the gate clears once the handoff lists every order"
  sleep 1
  run_order "$home" send --no-nudge "second, after the handoff" >/dev/null
  second=$(find "$home/data/orders/pending" -name '*.order' | sed 's#.*/##; s/\.order$//' | grep -v "$first")
  rc=0
  out=$(run_order "$home" gate) || rc=$?
  assert_equals 3 "$rc" "an order that arrived after the handoff blocks the gate again"
  assert_contains "$out" "$second" "the gate names the missing order"
  assert_not_contains "$out" "$first" "the gate names only the missing order"
  pass "the restart gate passes only while the handoff lists every open order"
}

# --- (e) leash sweep cap -------------------------------------------------------

test_sweep_redelivers_twice_then_escalates_once() {
  local home id out filed="$TMP_ROOT/filed.log" stub="$TMP_ROOT/self-heal-stub.sh" i json
  home=$(make_home sweep)
  cat >"$stub" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$filed"
printf 'created 99 https://example.invalid/issues/99\n'
SH
  chmod +x "$stub"
  : >"$filed"
  run_order "$home" send --no-nudge "stuck order" >/dev/null
  id=$(only_id "$home" pending)
  out=$(ORDER_ENV="FM_ORDER_REDELIVER_SECS=3600" run_order "$home" sweep)
  assert_contains "$out" "nothing due" "a fresh order is not re-delivered"
  for i in 1 2 3 4 5; do
    ORDER_ENV="FM_ORDER_REDELIVER_SECS=0" FM_ORDER_SELF_HEAL_BIN="$stub" run_order "$home" sweep >/dev/null
  done
  assert_equals 2 "$(count_events "$home" redelivered)" "the sweep re-delivers at most twice"
  assert_equals 1 "$(count_events "$home" escalated)" "the sweep escalates exactly once"
  assert_equals 1 "$(wc -l <"$filed" | tr -d ' ')" "the self-heal issue is filed once"
  assert_contains "$(cat "$filed")" "--failure-class captain-order-undelivered" "the issue names the failure class"
  assert_not_contains "$(cat "$filed")" "stuck order" "the issue never carries the order body"
  json=$(run_order "$home" status --json "$id")
  assert_contains "$json" '"redeliveries":2' "status shows the re-delivery count"
  assert_contains "$json" '"redelivery_cap":2' "status shows the cap"
  assert_contains "$json" '"escalation":"escalated"' "status shows the escalation"

  home=$(make_home sweep-fail)
  run_order "$home" send --no-nudge "another stuck order" >/dev/null
  for i in 1 2 3 4; do
    ORDER_ENV="FM_ORDER_REDELIVER_SECS=0" FM_ORDER_SELF_HEAL_BIN=/bin/false run_order "$home" sweep >/dev/null
  done
  assert_equals 1 "$(count_events "$home" escalate-failed)" "a failed escalation is recorded once and not retried"
  assert_equals 2 "$(count_events "$home" redelivered)" "a failed escalation does not reopen re-delivery"
  pass "(e) the sweep re-delivers at most twice, then escalates once and never loops"
}

test_status_flags_resend_due_for_the_sender_recheck() {
  local home json
  home=$(make_home recheck)
  run_order "$home" send --no-nudge "re-check me" >/dev/null
  json=$(run_order "$home" status --json)
  assert_contains "$json" '"resend_due":false' "a fresh order is not due for a resend"
  json=$(ORDER_ENV="FM_ORDER_RECHECK_SECS=0" run_order "$home" status --json)
  assert_contains "$json" '"resend_due":true' "a pending order past the re-check window is due"
  pass "status tells a sender when its 15-minute re-check is due"
}

# --- (f) backward compatibility ------------------------------------------------

test_legacy_inbox_note_still_works() {
  local home out note_id rec again
  home=$(make_home legacy)
  run_order "$home" send --no-nudge "a durable order already open" >/dev/null
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$INBOX_BIN" note "legacy: restart the nightly")
  assert_contains "$out" "queued " "a legacy inbox note is still queued"
  assert_contains "$out" "firstmate will pick this up at its next check." "a legacy note keeps its announcement"
  note_id=$(printf '%s\n' "$out" | sed -n 's/^queued //p')
  grep -q "inbox:$note_id" "$home/state/.wake-queue" || fail "a legacy note still appends its own wake"
  [ -f "$home/state/inbox/$note_id.note" ] || fail "a legacy note still writes its record"
  assert_contains "$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$INBOX_BIN" list)" "legacy: restart the nightly" "the legacy note is listed"

  rec=$(run_order "$home" record-legacy --source "inbox:$note_id" "legacy: restart the nightly")
  assert_contains "$rec" "recorded " "the captain can give a legacy order an id"
  assert_contains "$rec" " acked" "a recorded legacy order is acknowledged on read"
  again=$(run_order "$home" record-legacy --source "inbox:$note_id" "legacy: restart the nightly")
  assert_contains "$again" "replay " "recording the same legacy order twice replays it"
  assert_equals 1 "$(count_in "$home" acked)" "a legacy order is recorded once"
  assert_equals 1 "$(count_in "$home" pending)" "recording a legacy order leaves durable orders alone"
  out=$(run_order "$home" record-legacy "typed straight into the captain terminal")
  assert_contains "$out" "recorded " "a typed legacy order can be recorded without a source"
  pass "(f) a legacy inbox note works unchanged and can become a durable order"
}

test_invalid_use() {
  local home rc=0
  home=$(make_home invalid)
  run_order "$home" send --no-nudge "   " >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "an empty order is invalid use"
  rc=0
  run_order "$home" ack "not-an-id" >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "a malformed id is invalid use"
  rc=0
  run_order "$home" ack "1700000000-deadbeef" >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" "an unknown id fails"
  pass "invalid use and unknown ids are refused"
}

test_send_retry_and_resend_never_run_twice
test_two_stage_ack_separates_receipt_from_completion
test_handle_is_resolved_at_send_time
test_restart_gate_requires_every_open_order_in_the_handoff
test_sweep_redelivers_twice_then_escalates_once
test_status_flags_resend_due_for_the_sender_recheck
test_legacy_inbox_note_still_works
test_invalid_use
