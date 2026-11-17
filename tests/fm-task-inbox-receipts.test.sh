#!/usr/bin/env bash
# tests/fm-task-inbox-receipts.test.sh - steering-message result receipts
# (bin/fm-task-inbox-lib.sh "Result receipts") and the per-task live status
# file the watcher writes (docs/configuration.md "Task live status"):
#   1. A message gets a queued receipt when written, picked_up once the worker
#      moves it into handled/, and finished with the outcome of the first
#      settled status line written after it was queued; a removed record is
#      dropped without a further receipt, and the handled/ move stays the
#      acknowledgement.
#   2. Every delivery attempt records its result and the input-line verdict it
#      read, so a skipped delivery behind stray input-line text is visible.
#   3. The live status file reports the input-line reading, the queued steering
#      count and last delivery, and an open dialog, from a real steer check.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=tests/task-inbox-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/task-inbox-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-inbox-receipts)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# The receipt sync needs the status-line grammar, as it has inside the watcher.
receipts_sync() {  # <state>
  # shellcheck disable=SC2016 # The inner shell expands its own arguments.
  FM_STATE_OVERRIDE="$1" bash -c '. "$1" && . "$2" && fm_task_inbox_receipts_sync "$3" t1' \
    _ "$ROOT/bin/fm-classify-lib.sh" "$ROOT/bin/fm-task-inbox-lib.sh" "$1"
}

receipt_rows() {  # <state>
  jq -c '[.msg, .receipt, .outcome, .text, .status_at]' "$1/t1.inbox/receipts.jsonl"
}

test_receipts_follow_a_message_to_its_outcome() {
  local dir state rec rec2 name name2
  dir="$TMP_ROOT/receipts"
  state="$dir/state"
  mkdir -p "$state"
  printf 'working: earlier work\n' > "$state/t1.status"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please rebase")
  name=${rec##*/}
  jq -e -s 'all(.[]; .v == 1 and (.ts | type) == "number")' "$state/t1.inbox/receipts.jsonl" >/dev/null \
    || fail "every receipt must carry v and ts: $(cat "$state/t1.inbox/receipts.jsonl")"
  assert_equals "[\"$name\",\"queued\",null,null,null]" "$(receipt_rows "$state")" "receipts after the write"

  receipts_sync "$state" || fail "sync before pickup failed"
  assert_equals 1 "$(wc -l < "$state/t1.inbox/receipts.jsonl" | tr -d ' ')" "receipts before pickup"

  mv "$rec" "$state/t1.inbox/handled/"
  receipts_sync "$state" || fail "sync after pickup failed"
  printf 'working [at=1790000100]: rebasing\npartial' >> "$state/t1.status"
  receipts_sync "$state" || fail "sync on a working line failed"
  assert_equals "$(printf '%s\n' "[\"$name\",\"queued\",null,null,null]" "[\"$name\",\"picked_up\",null,null,null]")" \
    "$(receipt_rows "$state")" "receipts while the worker is still working"

  printf ' line\ndone [at=1790000123]: rebased and pushed\n' >> "$state/t1.status"
  rec2=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "never mind")
  name2=${rec2##*/}
  rm -f "$rec2"
  receipts_sync "$state" || fail "sync after the settled line failed"
  assert_equals "$(printf '%s\n' \
    "[\"$name\",\"queued\",null,null,null]" \
    "[\"$name\",\"picked_up\",null,null,null]" \
    "[\"$name2\",\"queued\",null,null,null]" \
    "[\"$name\",\"finished\",\"done\",\" rebased and pushed\",1790000123]")" \
    "$(receipt_rows "$state")" "receipts after the settled line"
  assert_absent "$state/t1.inbox/.receipt-open" "no receipt is still owed"
  assert_present "$state/t1.inbox/handled/$name" "the worker's acknowledgement stays in handled/"
  receipts_sync "$state" || fail "an idle sync failed"
  assert_equals 4 "$(wc -l < "$state/t1.inbox/receipts.jsonl" | tr -d ' ')" "receipts after an idle sync"
  pass "receipts: a message is queued, picked up, and finished with the first settled outcome after it; a removed record gets no more"
}

test_delivery_attempts_record_their_result_and_input_line() {
  local dir state rec log composer rc name
  dir="$TMP_ROOT/delivery"
  state="$dir/state"
  mkdir -p "$state"
  make_composer_stub "$dir"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  name=${rec##*/}
  log="$dir/send.log"; composer="$dir/composer"; : > "$log"
  printf 'a half-typed draft' > "$composer"
  rc=0
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$log" FM_FAKE_COMPOSER="$composer" FM_FAKE_DROP_ENTERS="$dir/drops" \
    inbox_lib "$state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 || rc=$?
  [ "$rc" = 1 ] || fail "stray input-line text should skip the ring, got rc $rc"
  assert_equals "$name composer-pending" "$(cut -f1,2 "$state/t1.inbox/.last-ring" | tr '\t' ' ')" "skipped delivery record"
  assert_equals pending "$(cut -f1 "$state/t1.inbox/.composer")" "input-line verdict"
  : > "$composer"
  rc=0
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$log" FM_FAKE_COMPOSER="$composer" FM_FAKE_DROP_ENTERS="$dir/drops" \
    inbox_lib "$state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 || rc=$?
  [ "$rc" = 0 ] || fail "an empty input line should be rung, got rc $rc"
  assert_equals "$name rang" "$(cut -f1,2 "$state/t1.inbox/.last-ring" | tr '\t' ' ')" "rung delivery record"
  assert_equals empty "$(cut -f1 "$state/t1.inbox/.composer")" "input-line verdict after the ring"
  pass "delivery: each attempt records its result and the input-line verdict it read"
}

test_live_status_reports_what_holds_up_steering() {
  local dir state rec name screen expected live_json
  dir="$TMP_ROOT/live"
  state="$dir/state"
  mkdir -p "$state"
  make_composer_stub "$dir"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  name=${rec##*/}
  printf 'a half-typed draft' > "$dir/composer"
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" FM_FAKE_COMPOSER="$dir/composer" \
    FM_FAKE_DROP_ENTERS="$dir/drops" inbox_lib "$state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 || true
  screen=$'Bash command\n  rm -rf build\n\nDo you want to proceed?\n❯ 1. Yes\n  2. No\n\nEsc to cancel'
  live() {  # <snippet>
    # shellcheck disable=SC2016 # The inner shell expands its own arguments.
    FM_STATE_OVERRIDE="$state" bash -c '. "$1" && eval "$2"' _ "$WATCH" "$1" \
      || fail "live status refresh failed"
  }
  live "live_status_refresh t1 ship h1 \"\$(printf '%s' \"$screen\")\""
  live_json="$state/t1.live.json"
  expected=$(jq -cn --arg oldest "$name" \
    '{v: 1, task: "t1", kind: "ship", composer: "pending", queued: 1, oldest: $oldest, result: "composer-pending", dialog: "permission"}')
  assert_equals "$expected" \
    "$(jq -c '{v, task, kind, composer: .composer.state, queued: .inbox.queued, oldest: .inbox.oldest, result: .inbox.last_delivery.result, dialog: .dialog.state}' "$live_json")" \
    "live status while a draft and a prompt block steering"
  jq -e '(.ts | type) == "number" and (.composer.at | type) == "number" and (.inbox.oldest_queued_at | type) == "string" and (.dialog.at | type) == "number"' \
    "$live_json" >/dev/null || fail "live status times are missing: $(cat "$live_json")"
  mv "$rec" "$state/t1.inbox/handled/"
  live "live_status_refresh t1 ship"
  assert_equals '{"queued":0,"oldest":null,"dialog":"not-read","at":null}' \
    "$(jq -c '{queued: .inbox.queued, oldest: .inbox.oldest, dialog: .dialog.state, at: .dialog.at}' "$live_json")" \
    "live status after the acknowledgement with no screen read"
  live "live_status_refresh 't1\"x' ship"
  assert_absent "$state/t1\"x.live.json" "a task id unsafe for JSON wrote a live status file"
  pass "live status: input-line reading, queued steering, last delivery, and an open approval prompt are readable outside the pane"
}

test_watcher_poll_writes_live_status() {
  local dir state out pid i=0
  dir=$(setup_watch_case live-watch)
  state="$dir/state"; out="$dir/watch.out"
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" FM_SEND_LOG="$dir/send.log" \
    "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  while [ "$i" -lt 100 ]; do
    [ -s "$state/t1.live.json" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  assert_present "$state/t1.live.json" "the watcher poll wrote no live status"
  assert_equals '{"task":"t1","kind":"ship","composer":"not-read","queued":0,"dialog":"none"}' \
    "$(jq -c '{task, kind, composer: .composer.state, queued: .inbox.queued, dialog: .dialog.state}' "$state/t1.live.json")" \
    "live status from a watcher poll"
  pass "watcher: an ordinary poll refreshes the task's live status file"
}

test_receipts_follow_a_message_to_its_outcome
test_delivery_attempts_record_their_result_and_input_line
test_live_status_reports_what_holds_up_steering
test_watcher_poll_writes_live_status
