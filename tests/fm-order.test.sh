#!/usr/bin/env bash
# tests/fm-order.test.sh - durable captain orders (bin/fm-order.sh).
#
# Covers idempotency (a sender retry and a resend never make or run a second
# order, and concurrent acks yield exactly one reader), the two-stage ack
# (acked on read, then done or parked with an outcome), the captain handle
# resolved at send time and a doorbell that never rings over an unproven
# composer, the restart gate read from the handoff document, standing holds
# that override older orders, the leash sweep's re-delivery cap and one-time
# escalation (a sender resend never starves it), and backward compatibility:
# a legacy inbox note still works unchanged and is never rewritten.
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
  if run_order "$home" finish "$id" "done" "too early" >/dev/null 2>&1; then
    fail "an order cannot be finished before it is acknowledged"
  fi
  run_order "$home" ack "$id" >/dev/null
  json=$(run_order "$home" status --json "$id")
  assert_contains "$json" '"state":"acked"' "a read order reports acked (receipt)"
  out=$(run_order "$home" finish "$id" "done" "logs rotated")
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
  out=$(FM_SUPERVISOR_TARGET=pane_7 FM_SUPERVISOR_BACKEND=tmux run_order "$home" claim-handle)
  assert_contains "$out" "handle: tmux:pane_7" "claim-handle records this session's terminal"
  : >"$NUDGE_LOG"
  ORDER_ENV="FM_ORDER_NUDGE_CMD=$NUDGE_STUB" run_order "$home" resend "$id" >/dev/null
  assert_equals "tmux pane_7" "$(cat "$NUDGE_LOG")" "the newest claim wins at the next send"
  pass "(c) one helper resolves the current captain handle at every send"
}

# The doorbell rings only into a composer proven empty. A terminal whose
# composer state cannot be proven (here a backend this host cannot read) may
# hold a draft, so the doorbell defers and the order stays durable.
test_doorbell_defers_over_an_unproven_composer() {
  local home out
  home=$(make_home unproven-composer)
  write_handle "$home" no-such-backend term_x
  out=$(run_order "$home" send --from leash "do not type over my draft")
  assert_contains "$out" "nudge=deferred" "an unproven composer defers the doorbell"
  assert_equals 1 "$(count_in "$home" pending)" "the deferred order is still saved"
  assert_equals 1 "$(order_wakes "$home")" "the deferred order still appends its wake"
  pass "(c) the doorbell never rings over a composer it cannot prove empty"
}

# --- restart gate -------------------------------------------------------------

test_restart_gate_requires_every_open_order_in_the_handoff() {
  local home rc=0 first second out doc
  home=$(make_home gate)
  run_order "$home" gate >/dev/null || fail "with no open orders the gate is clear"
  run_order "$home" send --no-nudge "first" >/dev/null
  first=$(only_id "$home" pending)
  out=$(run_order "$home" gate) || rc=$?
  assert_equals 3 "$rc" "an open order with no recorded handoff blocks the gate"
  assert_contains "$out" "wrote no handoff" "the gate says this session wrote no handoff"
  # A document that names the order but was not recorded by this session's
  # handoff never satisfies the gate.
  printf 'an earlier handoff that lists %s\n' "$first" >"$home/data/handoff-20261030-0900-captain-restart.md"
  rc=0
  run_order "$home" gate >/dev/null || rc=$?
  assert_equals 3 "$rc" "an unrecorded handoff document does not satisfy the gate"
  rc=0
  run_order "$home" handoff >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "handoff without --doc is invalid use"

  # Any document path works, not only data/handoff-*.md.
  doc="$home/data/session-handoff.md"
  printf '# Handoff\n\nWork under way: none.\n' >"$doc"
  out=$(run_order "$home" handoff --doc "$doc")
  assert_contains "$out" "wrote 1 open order(s)" "handoff --doc reports what it wrote"
  assert_contains "$(cat "$doc")" "Work under way: none." "handoff --doc keeps the document's own text"
  assert_contains "$(cat "$doc")" "$first pending" "handoff --doc appends the open order"
  out=$(run_order "$home" gate) || fail "the gate clears once the recorded handoff lists every order"
  assert_contains "$out" "gate: clear (1 open order(s)" "the gate reports a clear verdict"

  sleep 1
  run_order "$home" send --no-nudge "second, after the handoff" >/dev/null
  second=$(find "$home/data/orders/pending" -name '*.order' | sed 's#.*/##; s/\.order$//' | grep -v "$first")
  rc=0
  out=$(run_order "$home" gate) || rc=$?
  assert_equals 3 "$rc" "an order that arrived after the handoff blocks the gate again"
  assert_contains "$out" "$second" "the gate names the missing order"
  assert_not_contains "$out" "$first" "the gate names only the missing order"
  run_order "$home" handoff --doc "$doc" >/dev/null
  run_order "$home" gate >/dev/null || fail "a fresh handoff --doc clears the gate again"

  mv "$doc" "$doc.moved"
  rc=0
  out=$(run_order "$home" gate) || rc=$?
  assert_equals 3 "$rc" "a recorded handoff document that is gone blocks the gate"
  assert_contains "$out" "is gone" "the gate says the recorded document is gone"
  mv "$doc.moved" "$doc"
  run_order "$home" gate >/dev/null || fail "the restored document clears the gate"

  # A new session start clears the record, so the old session's document
  # never clears the new session's gate.
  run_order "$home" claim-handle >/dev/null
  rc=0
  out=$(run_order "$home" gate) || rc=$?
  assert_equals 3 "$rc" "after a new session start the previous handoff no longer counts"
  assert_contains "$out" "wrote no handoff" "the new session has written no handoff yet"
  rc=0
  run_order "$home" gate --doc "$doc" >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "gate takes no document argument"
  pass "the restart gate passes only while this session's recorded handoff lists every open order"
}

# --- holds ---------------------------------------------------------------------

test_hold_overrides_older_orders_and_travels_with_relays() {
  local home older hold newer out
  home=$(make_home holds)
  out=$(run_order "$home" holds --relay)
  assert_equals "" "$out" "with no hold in force the relay block is empty"
  assert_contains "$(run_order "$home" holds)" "no holds in force" "holds says when none is in force"
  run_order "$home" send --no-nudge --from council "close the stale PRs" >/dev/null
  older=$(only_id "$home" pending)
  sleep 1
  out=$(run_order "$home" send --hold --no-nudge --from captain "close nothing")
  assert_contains "$out" "kind=hold" "a hold is sent as kind=hold"
  hold=$(find "$home/data/orders/pending" -name '*.order' | sed 's#.*/##; s/\.order$//' | grep -v "$older")
  out=$(run_order "$home" send --no-nudge --from captain "close nothing")
  assert_contains "$out" "queued " "an order with a hold's text is a separate order, not a hold replay"
  newer=$(find "$home/data/orders/pending" -name '*.order' | sed 's#.*/##; s/\.order$//' | grep -v "$older" | grep -v "$hold")
  [ -n "$newer" ] && [ "$newer" != "$hold" ] || fail "an order with a hold's text must get its own id, got hold=$hold newer=$newer"
  assert_equals 3 "$(count_in "$home" pending)" "the hold and the order with its text are both kept"
  assert_contains "$(run_order "$home" send --hold --no-nudge "close nothing")" "replay $hold" "a hold retry replays the open hold"

  out=$(run_order "$home" ack "$older")
  assert_contains "$out" "$hold NEWER - overrides this order" "acking an older order names the newer hold over it"
  out=$(run_order "$home" ack "$newer")
  assert_contains "$out" "$hold older - still in force" "acking a newer order still lists the older hold"
  out=$(run_order "$home" pickup)
  case "$out" in
    "Holds in force"*) ;;
    *) fail "pickup must list holds first, got: $out" ;;
  esac
  assert_contains "$out" "$hold pending kind=hold" "pickup lists the hold as an open item too"
  out=$(run_order "$home" holds --relay)
  assert_contains "$out" "Standing captain holds" "the relay block opens with its heading"
  assert_contains "$out" "- hold $hold" "the relay block names the hold id"
  assert_contains "$out" "close nothing" "the relay block carries the hold text"
  assert_not_contains "$out" "close the stale PRs" "the relay block carries holds only"

  out=$(run_order "$home" ack "$hold")
  assert_contains "$out" "stays in force until lifted" "an acked hold stays in force"
  assert_contains "$(run_order "$home" holds --relay)" "$hold" "an acked hold still travels with relays"
  run_order "$home" finish "$hold" "done" "lifted by the captain" >/dev/null
  assert_equals "" "$(run_order "$home" holds --relay)" "a lifted hold no longer travels"
  assert_not_contains "$(run_order "$home" show "$older")" "$hold" "a lifted hold no longer overrides"
  pass "a hold overrides older orders, is listed first, and travels with every relay until lifted"
}

# Finishing an order frees its idempotency reservation only when that
# reservation still names it, so a retry of another open order never duplicates.
test_finish_frees_only_its_own_reservation() {
  local home first second
  home=$(make_home reservation)
  run_order "$home" send --no-nudge "same text" >/dev/null
  first=$(only_id "$home" pending)
  run_order "$home" ack "$first" >/dev/null
  run_order "$home" finish "$first" "done" "finished once" >/dev/null
  sleep 1
  run_order "$home" send --no-nudge "same text" >/dev/null
  second=$(only_id "$home" pending)
  [ "$second" != "$first" ] || fail "the same text after completion must be a new order"
  # Re-finishing the old order is a no-op and must not free the new reservation.
  run_order "$home" finish "$first" "done" "again" >/dev/null
  assert_contains "$(run_order "$home" send --no-nudge "same text")" "replay $second" \
    "a retry of the open order still replays after an old order was finished again"
  assert_equals 1 "$(count_in "$home" pending)" "no duplicate order was created"
  pass "finishing an order frees only the reservation that names it"
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

# A sender's resend must not reset the leash clock: a sender that re-checks and
# resends forever would otherwise keep the sweep from ever re-delivering.
test_sender_resend_never_starves_the_sweep() {
  local home id out
  home=$(make_home starve)
  run_order "$home" send --no-nudge "keep resending me" >/dev/null
  id=$(only_id "$home" pending)
  # Age the send: rewrite the delivered event 2 hours into the past.
  awk -F '\t' -v OFS='\t' -v old=$(( $(date +%s) - 7200 )) '$4 == "delivered" || $4 == "sent" { $2 = old } { print }' \
    "$home/data/orders/log.tsv" >"$home/data/orders/log.tsv.new"
  mv "$home/data/orders/log.tsv.new" "$home/data/orders/log.tsv"
  run_order "$home" resend --no-nudge "$id" >/dev/null
  out=$(ORDER_ENV="FM_ORDER_REDELIVER_SECS=1800" run_order "$home" sweep)
  assert_contains "$out" "redelivered $id" "a fresh sender resend does not hold back a due re-delivery"
  assert_equals 1 "$(count_events "$home" redelivered)" "the sweep re-delivered once"
  pass "(e) a sender's resend never resets the sweep's re-delivery clock"
}

# The supervision watcher runs the sweep on its own poll while an order is
# pending, so re-delivery needs no separate leash process.
test_watcher_poll_runs_the_sweep() {
  local home i=0
  home=$(make_home watcher-sweep)
  run_order "$home" send --no-nudge "re-deliver me from the watcher" >/dev/null
  rm -f "$home/state/.wake-queue"
  env -u FM_DATA_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$home" FM_WATCH_ONCE=1 \
    FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 FM_POLL=1 FM_ORDER_REDELIVER_SECS=0 \
    FM_ORDER_SELF_HEAL_BIN=/bin/false bash "$ROOT/bin/fm-watch.sh" >"$home/watch.out" 2>&1 || true
  while [ "$(count_events "$home" redelivered)" -lt 1 ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  assert_equals 1 "$(count_events "$home" redelivered)" "one watcher poll re-delivers the due order"
  [ -e "$home/state/.order-sweep" ] || fail "the watcher records when it last ran the sweep"
  pass "the supervision watcher runs the order sweep while an order is pending"
}

# Two sweep runners (the watcher and an external leash) must never both read
# the same re-delivery count: only one sweep runs at a time, and a lock left by
# a dead sweep does not block the next one.
test_one_sweep_runs_at_a_time() {
  local home id lock ready holder out i=0
  home=$(make_home sweep-lock)
  run_order "$home" send --no-nudge "sweep me once" >/dev/null
  id=$(only_id "$home" pending)
  lock="$home/data/orders/.sweep.lock"
  ready="$home/holder.ready"
  FM_ROOT_OVERRIDE="$ROOT" STATE="$home/state" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2" || exit 1; : >"$3"; exec sleep 60' \
    _ "$ROOT" "$lock" "$ready" &
  holder=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$ready" ] || fail "the test could not take the sweep lock"
  out=$(ORDER_ENV="FM_ORDER_REDELIVER_SECS=0" run_order "$home" sweep)
  assert_contains "$out" "another sweep is running" "a second sweep stands down"
  assert_equals 0 "$(count_events "$home" redelivered)" "the standing-down sweep re-delivered nothing"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  out=$(ORDER_ENV="FM_ORDER_REDELIVER_SECS=0" run_order "$home" sweep)
  assert_contains "$out" "redelivered $id" "a lock left by a dead sweep does not block the next one"
  assert_equals 1 "$(count_events "$home" redelivered)" "the next sweep re-delivered once"
  [ ! -e "$lock" ] || fail "a finished sweep releases its lock"
  pass "(e) one sweep runs at a time, so two runners never exceed the re-delivery cap"
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
  local home out note_id
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
  assert_equals 1 "$(count_in "$home" pending)" "a legacy note never becomes or alters a durable order"
  assert_equals 0 "$(count_in "$home" acked)" "a legacy note acknowledges nothing"
  run_order "$home" gate >/dev/null 2>&1 && fail "the durable order still gates a restart"
  assert_not_contains "$(run_order "$home" pickup)" "legacy: restart the nightly" "pickup lists durable orders only"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$INBOX_BIN" drain --ack "$note_id" >/dev/null \
    || fail "a legacy note is still acknowledged through fm-inbox"
  assert_not_contains "$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$INBOX_BIN" list)" "legacy: restart the nightly" "an acknowledged legacy note leaves the list"
  pass "(f) a legacy inbox note works unchanged beside durable orders"
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
test_doorbell_defers_over_an_unproven_composer
test_restart_gate_requires_every_open_order_in_the_handoff
test_one_sweep_runs_at_a_time
test_hold_overrides_older_orders_and_travels_with_relays
test_finish_frees_only_its_own_reservation
test_sweep_redelivers_twice_then_escalates_once
test_sender_resend_never_starves_the_sweep
test_watcher_poll_runs_the_sweep
test_status_flags_resend_due_for_the_sender_recheck
test_legacy_inbox_note_still_works
test_invalid_use
