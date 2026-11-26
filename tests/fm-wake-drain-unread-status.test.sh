#!/usr/bin/env bash
# tests/fm-wake-drain-unread-status.test.sh - drain must surface every still-
# unread informational status line since the last presentation, not only the
# newest line. This is a portable tests/ regression: the drain decides WHICH
# status lines to surface, so the real drain/classify functions over crafted
# status logs are sufficient (no harness). The incident this pins: a `note:`
# answer immediately followed by a routine `note:` was buried because the
# annotation kept only the newest line and `note:` never folds into OPEN
# DECISIONS.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-unread-status-tests)

# These regressions exercise status presentation on a home that does not run
# the supervision host, so its BRANCH OUTCOMES section stays out of the drain;
# the explicit off file pins that posture on every primary instead of reading
# the code root's config (bin/fm-supervision-engine-lib.sh owns the gate).
mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"

# Establish the durable last-presentation cursor by draining once over a
# bootstrap line so later appends are "new since last drain".
prime_cursor() {  # <state> <status-file>
  local state=$1 status=$2
  printf 'note: bootstrap cursor line\n' > "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null \
    || fail "bootstrap drain failed while priming the unread cursor"
}

test_incident_note_answer_buried_under_routine_note_surfaces_both() {
  local dir state out status
  dir=$(make_case incident-buried-note)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task1.status"
  prime_cursor "$state" "$status"

  printf 'note: captain said use REST not RPC\n' >> "$status"
  printf 'note: re-read acknowledgement\n' >> "$status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on the incident shape"

  grep -F 'UNREAD STATUS' "$out" >/dev/null \
    || fail "the incident shape produced no UNREAD STATUS section: $(cat "$out")"
  grep -F 'task1 note: captain said use REST not RPC' "$out" >/dev/null \
    || fail "the buried answer note was not surfaced: $(cat "$out")"
  grep -F 'task1 note: re-read acknowledgement' "$out" >/dev/null \
    || fail "the newest routine note was dropped while surfacing the answer: $(cat "$out")"
  pass "a note: answer buried under a later routine note: is surfaced with both lines"
}

test_failed_output_preserves_unread_notes_without_a_receipt() {
  local dir state status posture
  # An unread note must survive a failed transfer on both a fresh home and
  # one with an earlier receipt. Folding decisions is not presentation.
  for posture in fresh primed; do
    dir=$(make_case "failed-output-$posture")
    state="$dir/state"
    status="$state/task.status"
    if [ "$posture" = primed ]; then prime_cursor "$state" "$status"; fi
    printf 'note: answer retained after failed output\n' >> "$status"
    cp "$status" "$dir/status.before"
    # Close the actual output descriptor; no product executable is replaced.
    FM_STATE_OVERRIDE="$state" "$DRAIN" >&- 2> "$dir/failed.err" || true
    append_wake "$state" check output 'unhandled output recovery wake' \
      || fail 'could not queue output recovery wake'
    cp "$state/.wake-queue" "$dir/queue.before"
    FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/retry.out" 2> "$dir/retry.err" \
      || fail "$posture retry failed after the output consumer recovered"
    assert_grep 'task note: answer retained after failed output' "$dir/retry.out" \
      "$posture retry lost an unread note after the failed transfer"
    cmp "$dir/status.before" "$status" || fail 'output recovery changed status bytes'
    cmp "$dir/queue.before" "$state/.wake-queue" || fail 'output recovery acknowledged a wake'
    FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/repeat.out" 2> "$dir/repeat.err" \
      || fail 'drain failed after successful retry'
    assert_no_grep 'answer retained after failed output' "$dir/repeat.out" \
      'successful retry did not commit its presentation receipt'
  done
  pass 'failed output preserves unread notes until a successful presentation'
}

test_already_presented_notes_are_not_replayed() {
  local dir state out status
  dir=$(make_case no-replay)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task2.status"
  prime_cursor "$state" "$status"

  printf 'note: captain said use REST not RPC\n' >> "$status"
  printf 'note: re-read acknowledgement\n' >> "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "first drain of unread notes failed"
  grep -F 'captain said use REST not RPC' "$out" >/dev/null \
    || fail "setup error: first drain did not surface the answer note"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second drain after presentation failed"
  if grep -F 'captain said use REST not RPC' "$out" >/dev/null; then
    fail "an already-presented answer note was replayed as new: $(cat "$out")"
  fi
  if grep -F 're-read acknowledgement' "$out" >/dev/null; then
    fail "an already-presented routine note was replayed as new: $(cat "$out")"
  fi
  if grep -F 'UNREAD STATUS' "$out" >/dev/null; then
    fail "the second drain reprinted an UNREAD STATUS section with no new lines: $(cat "$out")"
  fi
  pass "already-presented note: lines are not re-surfaced on the next drain"
}

test_brand_new_note_after_presentation_is_surfaced() {
  local dir state out status
  dir=$(make_case brand-new-note)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task3.status"
  prime_cursor "$state" "$status"

  printf 'note: first answer\n' >> "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain of the first note failed"
  grep -F 'task3 note: first answer' "$out" >/dev/null \
    || fail "setup error: first note was not presented"

  printf 'note: follow-up after ack\n' >> "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain of the brand-new note failed"
  grep -F 'task3 note: follow-up after ack' "$out" >/dev/null \
    || fail "a brand-new note after presentation was not surfaced: $(cat "$out")"
  if grep -F 'task3 note: first answer' "$out" >/dev/null; then
    fail "the already-presented first note was replayed next to the new one: $(cat "$out")"
  fi
  pass "a brand-new note: after presentation is surfaced without replaying handled lines"
}

test_signal_annotation_surfaces_every_unread_note_not_only_the_newest() {
  local dir state out err status
  dir=$(make_case signal-annotation)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"
  status="$state/task4.status"
  prime_cursor "$state" "$status"

  printf 'note: captain said use REST not RPC\n' >> "$status"
  printf 'note: re-read acknowledgement\n' >> "$status"
  append_wake "$state" signal task4.status "signal: task4.status" \
    || fail "queueing the incident-shape status signal failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" \
    || fail "signal drain failed on the incident shape"

  grep -F 'unread wake-EVENT since last drain, not current state: task4.status: note: captain said use REST not RPC' "$out" >/dev/null \
    || fail "the signal annotation dropped the buried answer note: $(cat "$out")"
  grep -F 'latest wake-EVENT observed at drain, not current state: task4.status: note: re-read acknowledgement' "$out" >/dev/null \
    || fail "the signal annotation dropped the newest routine note: $(cat "$out")"
  grep "$(printf '\tsignal\ttask4.status\t')" "$out" >/dev/null \
    || fail "surfacing unread notes hid the authoritative raw wake row"
  pass "a queued status signal annotates every unread note, not only the newest"
}

test_pending_reply_resolution_surfaces_once() {
  local dir state out status
  dir=$(make_case pending-reply-resolution)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task5.status"
  prime_cursor "$state" "$status"

  printf 'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=task5 pending-reply-id=abcdef0123456789 request=ship it\n' >> "$status"
  append_wake "$state" signal task5.status "signal: task5.status" \
    || fail "queueing the pending-reply request signal failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null \
    || fail "drain failed while acknowledging the pending-reply request"
  {
    printf 'resolved [key=pending-reply-abcdef0123456789]: pending-reply-resolved: task=task5 pending-reply-id=abcdef0123456789 via=status\n'
    printf 'note: re-read acknowledgement\n'
  } >> "$status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a pending-reply resolution"

  grep -F 'pending-reply-resolved: task=task5 pending-reply-id=abcdef0123456789 via=status' "$out" >/dev/null \
    || fail "the pending-reply resolution was buried under the later note: $(cat "$out")"
  grep -F 'task5 note: re-read acknowledgement' "$out" >/dev/null \
    || fail "the trailing note was not surfaced with the pending-reply resolution: $(cat "$out")"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the pending-reply resolution did not close its open decision: $(cat "$out")"
  fi

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second drain after pending-reply presentation failed"
  if grep -F 'pending-reply-resolved:' "$out" >/dev/null; then
    fail "an already-presented pending-reply resolution was replayed: $(cat "$out")"
  fi
  pass "a pending-reply resolution buried under a later note surfaces once and closes OPEN DECISIONS"
}

# The watcher's pending-reply close goes through the self-announced append, so
# it records its bytes as this home's own and never wakes. The drain must still
# present that reserved-key resolution in UNREAD STATUS, its only guaranteed
# presentation.
test_self_announced_pending_reply_close_still_surfaces() {
  local dir state out status corr
  dir=$(make_case self-announced-pending-reply)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task6.status"

  run_pending_reply() {
    FM_STATE_OVERRIDE="$state" FM_PENDING_REPLY_NOW=5000 bash -c '
      . "$1"; . "$2"; shift 2; "$@"
    ' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$ROOT/bin/fm-wake-lib.sh" "$@"
  }

  corr=$(run_pending_reply fm_pending_reply_create "$dir" "$state" task6 "ship it") \
    || fail "could not create the pending-reply record"
  run_pending_reply fm_pending_reply_mark_delivered "$state" "$corr" \
    || fail "could not mark the pending-reply request delivered"
  FM_STATE_OVERRIDE="$state" FM_PENDING_REPLY_NOW=5000 bash -c '
    . "$1"; rec=$(fm_pending_reply_path "$2" "$3")
    fm_pending_reply_set "$rec" phase escalated && fm_pending_reply_set "$rec" escalated_epoch 4950
  ' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$state" "$corr" \
    || fail "could not mark the pending-reply request escalated"

  printf 'blocked [key=pending-reply-%s]: pending-reply-missed: task=task6 pending-reply-id=%s request=ship it\n' \
    "$corr" "$corr" > "$status"
  prime_status_seen "$state" "$status" || fail "could not mark the status file surfaced"
  append_wake "$state" signal task6.status "signal: task6.status" \
    || fail "queueing the pending-reply escalation signal failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null || fail "drain of the escalation failed"
  printf 'done [corr=%s]: shipped after all\n' "$corr" >> "$status"
  prime_status_seen "$state" "$status" || fail "could not mark the status file surfaced"
  append_wake "$state" signal task6.status "signal: task6.status" \
    || fail "queueing the delayed reply signal failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null || fail "drain of the delayed reply failed"

  run_pending_reply fm_pending_reply_try_resolve "$state" "$corr" \
    || fail "the delayed reply did not resolve the pending-reply record"
  sed -E 's/ \[at=[0-9]+\]//' "$status" \
    | grep -F "resolved [key=pending-reply-$corr]: pending-reply-resolved:" >/dev/null \
    || fail "the resolve did not append the escalation close: $(cat "$status")"
  [ -s "$state/.task6.home-appends" ] \
    || fail "the escalation close did not go through the self-announced append"
  run_pending_reply fm_wake_signal_seen_current "$state" "$status" \
    || fail "the self-announced escalation close was left to re-wake this home"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain after the escalation close failed"
  sed -E 's/ \[at=[0-9]+\]//' "$out" \
    | grep -F "task6 resolved [key=pending-reply-$corr]: pending-reply-resolved: task=task6 pending-reply-id=$corr" >/dev/null \
    || fail "the self-announced pending-reply resolution was hidden from UNREAD STATUS: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second drain after the escalation close failed"
  if grep -F 'pending-reply-resolved:' "$out" >/dev/null; then
    fail "an already-presented self-announced resolution was replayed: $(cat "$out")"
  fi
  pass "a self-announced pending-reply close does not wake yet still surfaces once in UNREAD STATUS"
}

test_unread_output_over_cap_remains_recoverable() {
  local dir state out status i payload
  dir=$(make_case unread-over-cap)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task-cap.status"
  prime_cursor "$state" "$status"
  payload=$(printf '%0180d' 0)
  i=1
  while [ "$i" -le 30 ]; do
    printf 'note: overflow-%02d %s\n' "$i" "$payload" >> "$status"
    i=$((i + 1))
  done

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed for unread output over the former cap"
  grep -F 'task-cap note: overflow-01' "$out" >/dev/null \
    || fail "the first over-cap note was not surfaced"
  grep -F 'task-cap note: overflow-30' "$out" >/dev/null \
    || fail "a later note vanished behind the unread byte cap: $(cat "$out")"
  if grep -F 'more omitted' "$out" >/dev/null; then
    fail "the unread section still omitted complete lines: $(cat "$out")"
  fi
  pass "unread status over the former byte cap preserves every line"
}

test_snapshot_does_not_ack_a_later_append() {
  local dir state status first second
  dir=$(make_case snapshot-append)
  state="$dir/state"
  status="$state/task-race.status"
  prime_cursor "$state" "$status"
  printf 'note: included in presentation snapshot\n' >> "$status"

  FM_STATE_OVERRIDE="$state" bash -c '
    set -u
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-classify-lib.sh"
    snapshot=$(status_presentation_snapshot "$STATE")
    scan_unread_surface_snapshot "$STATE" "$snapshot" > "$2"
    printf "note: appended after presentation snapshot\n" >> "$STATE/task-race.status"
    scan_open_decisions_snapshot "$STATE" "$snapshot" >/dev/null
    status_commit_presentation_snapshot "$STATE" "$snapshot"
    scan_unread_surface_lines "$STATE" > "$3"
  ' _ "$ROOT" "$dir/first" "$dir/second" || fail "snapshot race exercise failed"
  first=$(cat "$dir/first")
  second=$(cat "$dir/second")
  case "$first" in *'included in presentation snapshot'*) ;; *) fail "snapshot omitted the line it captured: $first" ;; esac
  case "$first" in *'appended after presentation snapshot'*) fail "snapshot read beyond its endpoint: $first" ;; esac
  case "$second" in *'appended after presentation snapshot'*) ;; *) fail "fold advancement swallowed a post-snapshot append: $second" ;; esac
  case "$second" in *'included in presentation snapshot'*) fail "the next scan replayed a presented line: $second" ;; esac
  pass "presentation cursor advances only through its captured endpoint"
}

test_retired_task_id_starts_new_status_unread() {
  local dir state out offset event old_ident
  dir=$(make_case retired-task-reuse)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'note: old reused-task history\n' > "$state/reused.status"
  printf 'note: stable neighboring history\n' > "$state/neighbor.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null \
    || fail "drain failed while acknowledging pre-retirement histories"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-classify-lib.sh"
    _fm_open_decisions_file_ident "$STATE/reused.status" > "$2"
    printf "40@$(cat "$2")" > "$(status_signal_seen_marker_path "$STATE" reused)"
    printf "40@$(cat "$2")" > "$(status_heartbeat_seen_marker_path "$STATE" reused)"
    printf "40@$(cat "$2")" > "$(status_daemon_seen_marker_path "$STATE" reused)"
    ledger=$(status_home_appends_path "$STATE/reused.status")
    status_home_appends_record "$STATE/reused.status" 0 12 || exit 1
    [ -f "$ledger" ] || exit 1
    mkdir -p "$ledger.lock" || exit 1
    printf "%s\n" 2147483646 > "$ledger.lock/pid" || exit 1
    status_retire_presentation_task "$STATE" reused || exit 1
    for marker in \
      "$(status_signal_seen_marker_path "$STATE" reused)" \
      "$(status_heartbeat_seen_marker_path "$STATE" reused)" \
      "$(status_daemon_seen_marker_path "$STATE" reused)" \
      "$ledger" "$ledger.lock"; do
      [ ! -e "$marker" ] && [ ! -L "$marker" ] || exit 1
    done
  ' _ "$ROOT" "$dir/old-ident" || fail "retiring the reused task presentation state failed"
  printf 'blocked: release host unavailable\nworking: routine padding after the reused task started again\nnote: first event from reused task id\n' \
    > "$state/reused.status"
  old_ident=$(cat "$dir/old-ident")
  printf '40@%s' "$old_ident" > "$state/.seen-reused_status"
  offset=$(bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-classify-lib.sh"
    fm_wake_signal_seen_size "$2" "$2/reused.status"
  ' _ "$ROOT" "$state")
  [ "$offset" = 0 ] || fail "a retired file identity restored a stale offset after task reuse"
  event=$(bash -c '
    . "$1/bin/fm-classify-lib.sh"
    status_span_first_actionable "$2/reused.status" "$3"
  ' _ "$ROOT" "$state" "$offset")
  [ "$event" = 'blocked: release host unavailable' ] \
    || fail "retired supervision offsets hid the replacement task blocker: $event"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain failed after reusing a retired task id"
  grep -F 'reused note: first event from reused task id' "$out" >/dev/null \
    || fail "the retired manifest row skipped the new task prefix: $(cat "$out")"
  if grep -F 'stable neighboring history' "$out" >/dev/null; then
    fail "retiring one task replayed a neighboring task's handled history: $(cat "$out")"
  fi
  pass "a reused task id starts its replacement status log unread at byte zero"
}

test_weak_identity_still_presents_and_advances() {
  local dir state out second reader
  dir=$(make_case weak-identity); state="$dir/state"
  out="$dir/first.out"; second="$dir/second.out"; reader="$dir/identity-reader"
  printf '#!/usr/bin/env bash\nprintf "weak:7:8"\n' > "$reader"; chmod +x "$reader"
  printf 'needs-decision [key=release]: choose target\nnote: release context attached\n' > "$state/weak.status"
  FM_STATUS_IDENTITY_READER="$reader" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain failed with the platform-strength fallback identity"
  grep -F 'weak [key=release] needs-decision: choose target' "$out" >/dev/null \
    || fail "weak identity omitted OPEN DECISIONS: $(cat "$out")"
  grep -F 'weak note: release context attached' "$out" >/dev/null \
    || fail "weak identity omitted unread status: $(cat "$out")"
  FM_STATUS_IDENTITY_READER="$reader" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$second" \
    || fail "second drain failed with the platform-strength fallback identity"
  grep -F 'release context attached' "$second" >/dev/null \
    && fail "weak identity did not advance the presented-status cursor"
  pass "fallback identity still presents and advances status state"
}

test_snapshot_failure_is_visible() {
  local dir state out reader
  dir=$(make_case snapshot-failure); state="$dir/state"; out="$dir/drain.out"; reader="$dir/identity-reader"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$reader"; chmod +x "$reader"
  printf 'needs-decision: choose target\n' > "$state/fail.status"
  FM_STATUS_IDENTITY_READER="$reader" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain aborted instead of reporting its incomplete status surface"
  grep -F 'STATUS PRESENTATION INCOMPLETE:' "$out" >/dev/null \
    || fail "snapshot failure produced a silently incomplete drain: $(cat "$out")"
  pass "snapshot failures are reported visibly"
}

test_open_decisions_fold_is_unchanged() {
  local dir state out
  dir=$(make_case open-decisions-regression)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task6.status"
  printf 'working: continuing other work\n' >> "$state/task6.status"
  printf 'note: re-read acknowledgement\n' >> "$state/task6.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a buried needs-decision plus a note"

  grep -F 'task6 [key=api-shape] needs-decision: pick REST or RPC' "$out" >/dev/null \
    || fail "OPEN DECISIONS no longer surfaces a buried needs-decision: $(cat "$out")"
  grep -F 'task6 note: re-read acknowledgement' "$out" >/dev/null \
    || fail "the unread note was not surfaced alongside the still-open decision: $(cat "$out")"
  grep -F "close one by answering it: bin/fm-send.sh <task> --resolve-key <key>" "$out" >/dev/null \
    || fail "OPEN DECISIONS lost its answerer-closes hint"

  printf 'resolved [key=api-shape]: went with REST\n' >> "$state/task6.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after resolving the keyed decision"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "an explicitly resolved decision still printed as open: $(cat "$out")"
  fi
  if grep -F 'pick REST or RPC' "$out" >/dev/null; then
    fail "a resolved decision leaked back through the unread surface: $(cat "$out")"
  fi
  pass "OPEN DECISIONS still folds needs-decision/blocked independently of unread notes"
}

test_empty_queue_does_not_swallow_later_signal_annotation() {
  local dir state out status
  dir=$(make_case delayed-signal-annotation)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task-delayed.status"
  printf 'done: shipped before watcher published signal\n' > "$status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "empty-queue drain failed before delayed signal publication"
  grep -F 'task-delayed done: shipped before watcher published signal' "$out" >/dev/null \
    || fail "the main-drain loss backstop did not surface the terminal event before its delayed signal: $(cat "$out")"

  append_wake "$state" signal task-delayed.status "signal: task-delayed.status" \
    || fail "publishing the delayed status signal failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain failed after delayed signal publication"
  grep -F 'latest wake-EVENT observed at drain, not current state: task-delayed.status: done: shipped before watcher published signal' "$out" >/dev/null \
    || fail "the empty-queue drain acknowledged an event before its signal annotation: $(cat "$out")"
  pass "an empty-queue backstop presentation still preserves the status for its later signal annotation"
}

test_routine_working_and_covered_done_stay_silent_on_the_empty_queue() {
  local dir state out old
  dir=$(make_case silent-working)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'working: on it\n' > "$state/task7.status"
  printf 'done: shipped clean\n' > "$state/task8.status"
  old=$(( $(date +%s) - 20 ))
  perl -e 'utime($ARGV[0], $ARGV[0], $ARGV[1]) or exit 1' "$old" "$state/task8.status" \
    || fail "could not age the covered done fixture"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task8 --verdict captain --summary 'shipped clean was handled' >/dev/null \
    || fail "could not record the newer branch outcome fixture"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with routine working and covered done lines"

  if grep -F 'UNREAD STATUS' "$out" >/dev/null; then
    fail "routine working/covered done lines printed an UNREAD STATUS section: $(cat "$out")"
  fi
  if grep -F 'STATUS OUTCOME BACKSTOP' "$out" >/dev/null; then
    fail "a covered done line printed the outcome backstop: $(cat "$out")"
  fi
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "routine working/covered done lines printed OPEN DECISIONS: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the empty-queue covered routine case was not silent: $(cat "$out")"
  pass "routine working and branch-covered done lines print nothing on an empty-queue drain"
}

# Opt one case's home into the supervision host, record one visible routine
# outcome, which the drain presents once in BRANCH OUTCOMES and then marks read,
# and give the liveness guard an in-flight task to supervise.
seed_routine_branch_outcome() {  # <case-dir> <task>
  local dir=$1 task=$2
  mkdir -p "$dir/config"
  : > "$dir/config/supervision-host"
  # An in-flight task makes the liveness guard report the unwatched queue.
  printf 'kind=ship\n' > "$dir/state/inflight.meta"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task "$task" --verdict routine --summary 'routine outcome fixture' >/dev/null \
    || fail 'could not record a routine branch outcome'
}

test_presentation_deadline_preserves_pending_data_and_recovers() {
  local dir state status rc=0
  dir=$(make_case presentation-deadline)
  state="$dir/state"
  status="$state/task-deadline.status"
  printf 'note: answer must remain unread until presented\nneeds-decision [key=held]: retain this decision\n' > "$status"
  # More than one 64-line fold checkpoint, so the fold has a place to stop.
  awk 'BEGIN { for (i=0;i<200;i++) print "working: routine deadline context" }' >> "$status"
  cp "$status" "$dir/status.before"
  append_wake "$state" check deadline 'unhandled deadline fixture' || fail 'could not seed deadline wake'
  cp "$state/.wake-queue" "$dir/queue.before"
  seed_routine_branch_outcome "$dir" deadline
  # Only the decision fold's span read is slow, so the fold - the one bounded
  # phase - passes its one-second bound before its first checkpoint.
  cat > "$dir/slow-fold-reader" <<'SH'
#!/usr/bin/env bash
for base in "$FM_STATE_OVERRIDE" "$FM_STATE_OVERRIDE"/.wake-drain-presentation.*; do
  for chunk in "$base"/.*.open-decisions-cursor.read.*; do
    [ -f "$chunk" ] || continue
    sleep 3
    break 2
  done
done
exec perl -e '
  my ($path, $start, $length) = @ARGV;
  open my $f, "<", $path or die $!;
  binmode $f;
  seek $f, $start, 0 or die $!;
  read($f, my $bytes, $length) == $length or die "short read";
  print $bytes;
' "$@"
SH
  chmod +x "$dir/slow-fold-reader"
  # A drain whose backlog reports one record divergence, so the bounded fold
  # can be seen not to withhold it.
  cp -R "$ROOT/bin" "$dir/bin"
  cat > "$dir/bin/fm-captain-hold.sh" <<'SH'
#!/bin/sh
[ "$1" = diverged ] || exit 2
printf 'held-task\tdeadline\theld-key\tdeadline divergence fixture\n'
SH
  chmod +x "$dir/bin/fm-captain-hold.sh"
  fm_run_timed 75 env FM_STATE_OVERRIDE="$state" FM_WAKE_DRAIN_PRESENTATION_TIMEOUT=1 \
    FM_STATUS_SPAN_READER="$dir/slow-fold-reader" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_TEST_SEAM=1 FM_TEST_HARNESS=claude \
    "$BASH" "$dir/bin/fm-wake-drain.sh" > "$dir/timed.out" 2> "$dir/timed.err" || rc=$?
  assert_equals 124 "$rc" "a fold past its bound must report incomplete execution: $(cat "$dir/timed.err")"
  assert_grep 'WAKE DRAIN INCOMPLETE:' "$dir/timed.err" 'product did not report its own deadline'
  assert_grep 'phase=status-open-decisions exceeded' "$dir/timed.err" 'deadline did not identify the decision fold'
  assert_grep 'WAKE_ACK_REQUIRED:' "$dir/timed.err" 'bounded presentation hid the queue acknowledgement token'
  assert_grep '[seq 1] deadline: routine outcome fixture' "$dir/timed.out" 'a fold deadline skipped branch outcomes'
  assert_grep 'WARNING: queued wakes pending' "$dir/timed.err" 'a fold deadline skipped the liveness check'
  assert_grep 'held-task [key=held-key] reads resolved in deadline' "$dir/timed.out" 'a fold deadline withheld record divergence'
  cmp "$dir/queue.before" "$state/.wake-queue" || fail 'deadline consumed an unhandled wake'
  cmp "$dir/status.before" "$status" || fail 'deadline changed a status source'
  FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" FM_TEST_SEAM=1 FM_TEST_HARNESS=claude \
    "$BASH" "$DRAIN" > "$dir/retry.out" 2> "$dir/retry.err" \
    || fail "a drain after the failed presentation could not recover: $(cat "$dir/retry.err")"
  assert_no_grep 'routine outcome fixture' "$dir/retry.out" 'a fold deadline left presented branch outcomes unread'
  assert_grep 'answer must remain unread until presented' "$dir/retry.out" 'failed presentation advanced the unread receipt'
  assert_grep '[key=held]' "$dir/retry.out" 'failed presentation lost an open decision'
  cmp "$dir/queue.before" "$state/.wake-queue" || fail 'recovery acknowledged a still-unhandled wake'
  pass 'a decision fold past its bound names its phase, still presents outcomes, divergence and liveness, preserves pending data and recovers'
}

test_large_unpresented_span_completes_without_a_presentation_deadline() {
  local dir state status rc=0 i
  dir=$(make_case large-unpresented-span)
  state="$dir/state"
  status="$state/task-span.status"
  printf 'kind=ship\n' > "$state/task-span.meta"
  : > "$status"
  i=0
  while [ "$i" -lt 20 ]; do
    printf 'note: unpresented answer %03d\n' "$i" >> "$status"
    i=$((i + 1))
  done
  awk 'BEGIN { for (i=0;i<3000;i++) print "working: unpresented routine context" }' >> "$status"
  # Warm only the decision fold, so the one bounded phase has nothing left to
  # do and all remaining work is the unbounded presentation of the span.
  FM_STATE_OVERRIDE="$state" /bin/bash -c '. "$1"; status_open_decisions_incremental "$2"' \
    _ "$ROOT/bin/fm-classify-lib.sh" "$status" > /dev/null || fail 'could not warm the decision fold'
  # Every span read takes longer than the whole one-second bound, the way a
  # loaded host makes a large span slow to classify.
  cat > "$dir/slow-reader" <<'SH'
#!/usr/bin/env bash
sleep 3
exec perl -e '
  my ($path, $start, $length) = @ARGV;
  open my $f, "<", $path or die $!;
  binmode $f;
  seek $f, $start, 0 or die $!;
  read($f, my $bytes, $length) == $length or die "short read";
  print $bytes;
' "$@"
SH
  chmod +x "$dir/slow-reader"
  fm_run_timed 75 env FM_STATE_OVERRIDE="$state" FM_WAKE_DRAIN_PRESENTATION_TIMEOUT=1 \
    FM_STATUS_SPAN_READER="$dir/slow-reader" "$BASH" "$DRAIN" \
    > "$dir/slow.out" 2> "$dir/slow.err" || rc=$?
  assert_equals 0 "$rc" "a slow unpresented span did not complete under a one-second bound: $(cat "$dir/slow.err")"
  i=0
  while [ "$i" -lt 20 ]; do
    assert_grep "$(printf 'unpresented answer %03d' "$i")" "$dir/slow.out" "the slow span lost note $i"
    i=$((i + 1))
  done
  FM_STATE_OVERRIDE="$state" "$BASH" "$DRAIN" > "$dir/repeat.out" 2> "$dir/repeat.err" \
    || fail "the drain after the slow span failed: $(cat "$dir/repeat.err")"
  assert_no_grep 'unpresented answer' "$dir/repeat.out" 'the slow span did not commit its presentation receipt'
  pass 'a large unpresented span completes and commits even when it takes longer than the bound'
}

check_attempt_owned_presentation_scratch() {
  local mode=$1 expected_rc=124 dir state stage stages='preparation fold' rc scratch peer_pid peer_shell i peer_scratch reader_pid
  case "$mode" in TERM) expected_rc=143 ;; INT) expected_rc=130 ;; esac
  # Only the decision fold carries a deadline, so a timeout can occur only there.
  [ "$mode" != timeout ] || stages='fold'
  for stage in $stages; do
    dir=$(make_case "scratch-$mode-$stage")
    state="$dir/state"
    printf 'note: retained note\nneeds-decision [key=held]: retained decision\n' > "$state/task.status"
    awk 'BEGIN { for (i=0;i<200;i++) print "working: retained routine context" }' >> "$state/task.status"
    cp "$state/task.status" "$dir/status.before"
    if [ "$mode" = timeout ]; then
      : > "$state/.wake-queue"
    else
      append_wake "$state" check scratch 'unhandled scratch fixture' || fail 'could not seed scratch wake'
    fi
    cp "$state/.wake-queue" "$dir/queue.before"
    cat > "$dir/reader" <<'SH'
#!/usr/bin/env bash
if [ "${FM_PEER_READER:-0}" = 1 ]; then
  printf '%s\n' "$$" > "$FM_READER_PID"
  exec sleep 90
fi
for base in "$FM_STATE_OVERRIDE" "$FM_STATE_OVERRIDE"/.wake-drain-presentation.*; do
  [ -d "$base" ] || continue
  case "$FM_BLOCK_STAGE" in
    preparation) pattern="$base/.status-presentation.prepared." ;;
    fold) pattern="$base/.task.open-decisions-cursor.read." ;;
  esac
  for scratch in "$pattern"*; do
    [ -f "$scratch" ] || continue
    [ "${FM_INTERRUPT_TEST:-0}" != 1 ] || trap '' TERM
    printf '%s\n' "$$" > "$FM_READER_PID"
    # A timeout needs a slow fold that reaches its next checkpoint, not a stuck one.
    [ "${FM_SLOW_FOLD:-0}" = 1 ] || exec sleep 90
    sleep 3
    break 2
  done
done
exec perl -e '
  my ($path, $start, $length) = @ARGV;
  open my $f, "<", $path or die $!;
  binmode $f;
  seek $f, $start, 0 or die $!;
  read($f, my $bytes, $length) == $length or die "short read";
  print $bytes;
' "$@"
SH
    chmod +x "$dir/reader"
    cp "$state/task.status" "$state/peer.status"
    FM_STATE_OVERRIDE="$state" FM_PEER_READER=1 FM_READER_PID="$dir/peer.pid" \
      FM_STATUS_SPAN_READER="$dir/reader" /bin/bash -c '
        . "$1/bin/fm-classify-lib.sh"
        status_open_decisions_incremental "$2"
      ' _ "$ROOT" "$state/peer.status" > "$dir/peer.out" &
    peer_shell=$!
    i=0
    while [ ! -s "$dir/peer.pid" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
    [ -s "$dir/peer.pid" ] || fail 'concurrent reader did not start'
    peer_pid=$(cat "$dir/peer.pid")
    peer_scratch="$state/.peer.open-decisions-cursor.read.$peer_shell"
    [ -f "$peer_scratch" ] || fail 'concurrent reader did not create its scratch'
    cp "$peer_scratch" "$dir/peer.before"
    rm "$state/peer.status"
    rc=0
    if [ "$mode" = timeout ]; then
      fm_run_timed 75 env FM_STATE_OVERRIDE="$state" FM_WAKE_DRAIN_PRESENTATION_TIMEOUT=1 \
        FM_STATUS_SPAN_READER="$dir/reader" FM_BLOCK_STAGE="$stage" FM_READER_PID="$dir/drain.pid" \
        FM_SLOW_FOLD=1 "$BASH" "$DRAIN" > "$dir/timed.out" 2> "$dir/timed.err" || rc=$?
    else
      FM_STATE_OVERRIDE="$state" FM_STATUS_SPAN_READER="$dir/reader" FM_BLOCK_STAGE="$stage" \
        FM_READER_PID="$dir/drain.pid" FM_INTERRUPT_TEST=1 \
        python3 - "$BASH" "$DRAIN" "$dir" "$mode" <<'PY_SIGNAL' || rc=$?
import pathlib
import signal
import subprocess
import sys
import time
bash, drain, directory, requested_signal = sys.argv[1:]
case = pathlib.Path(directory)
with (case / 'timed.out').open('wb') as out, (case / 'timed.err').open('wb') as err:
    # A background test runner may inherit SIGINT ignored. Bash cannot install
    # its INT trap unless the disposition is restored before it starts.
    child = subprocess.Popen([bash, drain], stdout=out, stderr=err,
                             preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
    try:
        # Reaching the blocked reader is fixture setup, not the bound under
        # test; a loaded host can take far longer than 20s to start a drain.
        deadline = time.monotonic() + 90
        pid_file = case / 'drain.pid'
        while not (pid_file.exists() and pid_file.stat().st_size > 0):
            if child.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError('drain never reached the blocked reader: ' + (case / 'timed.err').read_text())
            time.sleep(0.05)
        child.send_signal(getattr(signal, 'SIG' + requested_signal))
        rc = child.wait(timeout=60)
    finally:
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=35)
sys.exit(rc)
PY_SIGNAL
    fi
    kill -0 "$peer_pid" || fail 'drain stopped a concurrent reader'
    cmp "$dir/peer.before" "$peer_scratch" || fail 'drain removed or changed concurrent scratch'
    kill "$peer_pid" 2>/dev/null || true
    wait "$peer_shell" 2>/dev/null || true
    rm -f "$peer_scratch"
    assert_equals "$expected_rc" "$rc" 'presentation must preserve its terminal status'
    reader_pid=$(cat "$dir/drain.pid")
    if /bin/bash -c '. "$1"; fm_pid_alive "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$reader_pid"; then
      fail 'presentation exited before stopping its reader'
    fi
    [ -s "$dir/drain.pid" ] || fail "timeout did not reach $stage"
    if [ "$mode" = timeout ]; then
      assert_grep 'phase=status-open-decisions' "$dir/timed.err" "fold timeout did not reach open decisions: $(cat "$dir/timed.err")"
    fi
    for scratch in "$state"/.wake-drain-presentation.* "$state"/.status-presentation.prepared.* \
      "$state"/.*.open-decisions-cursor.read.* "$state"/.*.open-decisions-cursor.unread.* \
      "$state"/.*.open-decisions-cursor.span.* "$state"/.*.open-decisions-cursor.tmp.* \
      "$state"/.status-presentation-cursor.tmp.*; do
      [ ! -e "$scratch" ] || fail "timed-out drain leaked scratch: $scratch"
    done
    cmp "$dir/status.before" "$state/task.status" || fail 'scratch cleanup changed durable status'
    cmp "$dir/queue.before" "$state/.wake-queue" || fail 'scratch cleanup acknowledged an unhandled wake'
    FM_STATE_OVERRIDE="$state" "$BASH" "$DRAIN" > "$dir/retry.out" 2> "$dir/retry.err" || fail 'retry failed after scratch cleanup'
    assert_grep 'retained note' "$dir/retry.out" 'scratch cleanup lost unread status'
    assert_grep '[key=held]' "$dir/retry.out" 'scratch cleanup lost an open decision'
  done
  pass "$mode during $(printf '%s' "$stages" | sed 's/ / and /') cleans owned scratch and preserves a concurrent reader"
}

test_timeout_cleans_only_attempt_owned_presentation_scratch() {
  check_attempt_owned_presentation_scratch timeout
}

test_term_cleans_only_attempt_owned_presentation_scratch() {
  check_attempt_owned_presentation_scratch TERM
}

test_int_cleans_only_attempt_owned_presentation_scratch() {
  check_attempt_owned_presentation_scratch INT
}

test_invalid_presentation_bound_falls_back_to_the_default() {
  local dir state rc=0
  dir=$(make_case invalid-presentation-bound)
  state="$dir/state"
  printf 'note: invalid bound fixture\n' > "$state/task-bound.status"
  FM_STATE_OVERRIDE="$state" FM_WAKE_DRAIN_PRESENTATION_TIMEOUT=soon "$BASH" "$DRAIN" \
    > "$dir/drain.out" 2> "$dir/drain.err" || rc=$?
  assert_equals 0 "$rc" "an invalid presentation bound stopped the drain: $(cat "$dir/drain.err")"
  assert_grep 'using 30' "$dir/drain.err" 'an invalid presentation bound was not reported'
  assert_grep 'invalid bound fixture' "$dir/drain.out" 'the fallback bound did not present status'
  pass 'an invalid presentation bound falls back to the default and still presents'
}

test_unwritable_presentation_scratch_still_presents_outcomes_and_liveness() {
  local dir state fake rc=0 real
  dir=$(make_case unwritable-presentation-scratch)
  state="$dir/state"
  fake="$dir/no-scratch-bin"
  mkdir -p "$fake"
  real=$(command -v mktemp)
  printf '#!/bin/sh
case "$*" in *.wake-drain-presentation.*) exit 1 ;; esac
exec %s "$@"\n' "$real" > "$fake/mktemp"
  chmod +x "$fake/mktemp"
  printf 'note: scratch failure fixture\n' > "$state/task-scratch.status"
  append_wake "$state" check scratch 'unhandled scratch fixture' || fail 'could not seed scratch wake'
  seed_routine_branch_outcome "$dir" scratch
  PATH="$fake:$PATH" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_TEST_SEAM=1 FM_TEST_HARNESS=claude "$BASH" "$DRAIN" \
    > "$dir/drain.out" 2> "$dir/drain.err" || rc=$?
  assert_equals 1 "$rc" 'a drain without presentation scratch did not report failure'
  assert_grep 'STATUS PRESENTATION INCOMPLETE:' "$dir/drain.out" 'a scratch failure was silent'
  assert_grep '[seq 1] scratch: routine outcome fixture' "$dir/drain.out" 'a scratch failure skipped branch outcomes'
  assert_grep 'WARNING: queued wakes pending' "$dir/drain.err" 'a scratch failure skipped the liveness check'
  FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" FM_TEST_SEAM=1 FM_TEST_HARNESS=claude \
    "$BASH" "$DRAIN" > "$dir/repeat.out" 2> "$dir/repeat.err" \
    || fail "a drain after the scratch failure did not complete: $(cat "$dir/repeat.err")"
  assert_no_grep 'routine outcome fixture' "$dir/repeat.out" 'a scratch failure left presented branch outcomes unread'
  pass 'a presentation scratch failure still presents branch outcomes and liveness'
}

test_presentation_runner_start_failure_is_not_a_fold_timeout() {
  local dir state rc=0
  dir=$(make_case presentation-runner-start-failure)
  state="$dir/state"
  printf 'note: runner start fixture\n' > "$state/task-runner.status"
  append_wake "$state" check runner 'unhandled runner fixture' || fail 'could not seed runner wake'
  seed_routine_branch_outcome "$dir" runner
  TMPDIR="$dir/missing-tmp" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_TEST_SEAM=1 FM_TEST_HARNESS=claude "$BASH" "$DRAIN" \
    > "$dir/drain.out" 2> "$dir/drain.err" || rc=$?
  [ "$rc" -ne 124 ] || fail "a runner start failure reported the fold bound status: $(cat "$dir/drain.err")"
  assert_no_grep 'decision-fold bound' "$dir/drain.err" 'a runner start failure was blamed on the decision fold'
  assert_grep 'runner could not start' "$dir/drain.err" 'a runner start failure was silent'
  assert_grep 'runner start fixture' "$dir/drain.out" 'a runner start failure skipped unread status'
  assert_grep '[seq 1] runner: routine outcome fixture' "$dir/drain.out" 'a runner start failure skipped branch outcomes'
  assert_grep 'WARNING: queued wakes pending' "$dir/drain.err" 'a runner start failure skipped the liveness check'
  pass 'a presentation runner start failure still presents and is not reported as a fold timeout'
}

# A drain killed with KILL leaves its presentation worker running until the
# worker's watchdog notices. A drain started in that window must keep the
# scratch that live worker is still using, and remove it once the worker is gone.
test_presentation_scratch_of_a_live_worker_outlives_its_dead_owner() {
  local dir state dead worker scratch
  dir=$(make_case live-worker-presentation-scratch)
  state="$dir/state"
  sleep 0 &
  dead=$!
  wait "$dead" 2>/dev/null || true
  sleep 60 &
  worker=$!
  scratch="$state/.wake-drain-presentation.$dead.worker1"
  mkdir "$scratch"
  printf '%s\n' "$worker" > "$scratch/worker.pid"
  printf 'chunk\n' > "$scratch/chunk"
  FM_STATE_OVERRIDE="$state" "$BASH" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" \
    || { kill "$worker" 2>/dev/null; fail "drain failed: $(cat "$dir/drain.err")"; }
  if [ ! -f "$scratch/chunk" ]; then
    kill "$worker" 2>/dev/null || true
    fail 'a drain removed presentation scratch that a live worker still used'
  fi
  kill "$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true
  FM_STATE_OVERRIDE="$state" "$BASH" "$DRAIN" > "$dir/again.out" 2> "$dir/again.err" \
    || fail "drain after the worker ended failed: $(cat "$dir/again.err")"
  [ ! -e "$scratch" ] || fail 'scratch of a dead owner and dead worker was kept'
  pass 'presentation scratch of a live worker outlives its dead owner and is removed after the worker ends'
}

# A worker records its pid just after it starts, so scratch whose owner died in
# that gap has no recorded worker yet. A drain must not remove it while it is
# fresh, and removes it once it is old enough that no worker can still start.
test_fresh_unregistered_scratch_of_a_dead_owner_is_kept() {
  local dir state dead scratch
  dir=$(make_case fresh-unregistered-presentation-scratch)
  state="$dir/state"
  sleep 0 &
  dead=$!
  wait "$dead" 2>/dev/null || true
  scratch="$state/.wake-drain-presentation.$dead.fresh01"
  mkdir "$scratch"
  printf 'chunk\n' > "$scratch/chunk"
  FM_STATE_OVERRIDE="$state" "$BASH" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" \
    || fail "drain failed: $(cat "$dir/drain.err")"
  [ -f "$scratch/chunk" ] || fail 'a drain removed fresh scratch whose worker had not yet recorded its pid'
  touch -t 202001010000 "$scratch"
  FM_STATE_OVERRIDE="$state" "$BASH" "$DRAIN" > "$dir/again.out" 2> "$dir/again.err" \
    || fail "drain on aged scratch failed: $(cat "$dir/again.err")"
  [ ! -e "$scratch" ] || fail 'aged scratch of a dead owner with no recorded worker was kept'
  pass 'fresh scratch of a dead owner with no recorded worker is kept until it is old'
}

test_orphaned_presentation_scratch_of_a_dead_owner_is_removed() {
  local dir state dead
  dir=$(make_case orphan-presentation-scratch)
  state="$dir/state"
  sleep 0 &
  dead=$!
  wait "$dead" 2>/dev/null || true
  mkdir "$state/.wake-drain-presentation.$dead.orphan1" "$state/.wake-drain-presentation.$$.live001" \
    "$state/.wake-drain-presentation.legacy1"
  touch -t 202001010000 "$state/.wake-drain-presentation.$dead.orphan1"
  FM_STATE_OVERRIDE="$state" "$BASH" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" \
    || fail "drain failed: $(cat "$dir/drain.err")"
  [ ! -e "$state/.wake-drain-presentation.$dead.orphan1" ] || fail 'a dead owner left its presentation scratch behind'
  [ -d "$state/.wake-drain-presentation.$$.live001" ] || fail 'a live owner lost its presentation scratch'
  [ -d "$state/.wake-drain-presentation.legacy1" ] || fail 'scratch without an owner pid was removed'
  pass 'presentation scratch of a dead owner is removed and live scratch is kept'
}

test_mixed_tasks_preserve_routine_presentation_ownership() {
  local dir state offset
  dir=$(make_case mixed-presentation-ownership)
  state="$dir/state"
  printf 'working: delayed routine context\n' > "$state/task.status"
  printf 'note: first task answer\n' > "$state/task-1.status"
  printf 'note: second task answer\n' > "$state/task-2.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/first.out" 2> "$dir/first.err" || fail 'mixed-task drain failed'
  assert_grep 'task-1 note: first task answer' "$dir/first.out" 'first informational task was lost'
  assert_grep 'task-2 note: second task answer' "$dir/first.out" 'second informational task was lost'
  offset=$(FM_STATE_OVERRIDE="$state" /bin/bash -c '. "$1"; status_presentation_cursor_offset "$2"' \
    _ "$ROOT/bin/fm-classify-lib.sh" "$state/task.status")
  assert_equals 0 "$offset" 'presenting other tasks acknowledged routine-only context'

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/repeat.out" 2> "$dir/repeat.err" || fail 'mixed-task repeat failed'
  assert_no_grep 'task answer' "$dir/repeat.out" 'a successfully presented informational task replayed'
  append_wake "$state" signal task.status 'signal: task.status' || fail 'could not queue delayed routine signal'
  cp "$state/.wake-queue" "$dir/queue.before"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/signal.out" 2> "$dir/signal.err" || fail 'delayed routine signal failed'
  assert_grep 'delayed routine context' "$dir/signal.out" 'other tasks consumed delayed signal context'
  cmp "$dir/queue.before" "$state/.wake-queue" || fail 'presentation acknowledged the delayed wake'
  pass 'mixed tasks present informational rows once while preserving routine-only context'
}

test_warm_routine_history_is_bounded_without_acknowledging_it() {
  local dir state status i epoch rc=0 offset
  dir=$(make_case warm-routine-history)
  state="$dir/state"
  status="$state/task-history.status"
  printf 'kind=ship\n' > "$state/task-history.meta"
  printf 'working: initial routine context\n' > "$status"
  FM_STATE_OVERRIDE="$state" "$BASH" "$DRAIN" > /dev/null 2> /dev/null || fail 'could not establish a routine-only presentation'
  : > "$dir/expected"
  i=0
  while [ "$i" -lt 130 ]; do
    printf 'needs-decision [key=k%03d]: exact decision %03d\n' "$i" "$i" >> "$status"
    printf 'k%03d\tneeds-decision\texact decision %03d\n' "$i" "$i" >> "$dir/expected"
    i=$((i + 1))
  done
  awk 'BEGIN { for (i=0;i<10000;i++) print "working: historical routine context" }' >> "$status"
  cp "$status" "$dir/history.before"
  # Warm only the decision fold through its real interface. The independent
  # presentation receipt must still retain the earlier routine context.
  FM_STATE_OVERRIDE="$state" /bin/bash -c '. "$1"; status_open_decisions_incremental "$2"' \
    _ "$ROOT/bin/fm-classify-lib.sh" "$status" | LC_ALL=C sort > "$dir/open.before"
  cmp "$dir/expected" "$dir/open.before" || fail 'history fixture lost a decision while warming its fold'
  epoch=$(( $(date +%s) - 1800 ))
  i=12328
  while [ "$i" -le 12334 ]; do
    printf '%s\t%s\tcheck\tfixture-%s\tunhandled fixture wake\n' "$epoch" "$i" "$i" >> "$state/.wake-queue"
    i=$((i + 1))
  done
  cp "$state/.wake-queue" "$dir/queue.before"
  # Exercise the production presentation deadline, not a shorter test-only
  # latency target. The outer guard leaves room for setup and timeout cleanup
  # under host contention; it does not extend the drain's own deadline.
  fm_run_timed 75 env -u FM_WAKE_DRAIN_PRESENTATION_TIMEOUT FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" "$BASH" "$DRAIN" \
    > "$dir/warm.out" 2> "$dir/warm.err" || rc=$?
  assert_equals 0 "$rc" "a warm routine-only history still held the full drain past its presentation budget: $(cat "$dir/warm.err")"
  cmp "$dir/history.before" "$status" || fail 'fast presentation rewrote history'
  cmp "$dir/queue.before" "$state/.wake-queue" || fail 'fast presentation consumed queued wakes'
  offset=$(FM_STATE_OVERRIDE="$state" /bin/bash -c '. "$1"; status_presentation_cursor_offset "$2"' \
    _ "$ROOT/bin/fm-classify-lib.sh" "$status")
  assert_equals 0 "$offset" 'fast classification acknowledged routine context needed by a later signal'
  FM_STATE_OVERRIDE="$state" /bin/bash -c '. "$1"; status_open_decisions_incremental "$2"' \
    _ "$ROOT/bin/fm-classify-lib.sh" "$status" | LC_ALL=C sort > "$dir/open.after"
  cmp "$dir/expected" "$dir/open.after" || fail 'fast presentation changed the 130 open decisions'
  pass 'warm routine-only history completes without changing wake, decision or presentation ownership'
}

test_cold_decision_fold_progresses_across_presentation_deadlines() {
  local dir state status i rc attempt=0 offset previous=0 size
  dir=$(make_case cold-decision-fold)
  state="$dir/state"
  status="$state/task-cold.status"
  printf 'kind=ship\n' > "$state/task-cold.meta"
  : > "$status"
  : > "$dir/expected"
  i=0
  while [ "$i" -lt 40 ]; do
    printf 'needs-decision [key=k%03d]: exact decision %03d\n' "$i" "$i" >> "$status"
    printf 'k%03d\tneeds-decision\texact decision %03d\n' "$i" "$i" >> "$dir/expected"
    i=$((i + 1))
  done
  awk 'BEGIN { for (i=0;i<2000;i++) print "working: historical presented context" }' >> "$status"
  cp "$status" "$dir/history.before"
  size=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  # Present the history once without folding it, so every bounded attempt
  # reaches the cold fold quickly and the shortest legal bound tests its progress.
  FM_STATE_OVERRIDE="$state" /bin/bash -c '
    . "$1"
    snapshot=$(status_presentation_snapshot "$2") || exit 1
    status_commit_presentation_snapshot "$2" "$snapshot"
  ' _ "$ROOT/bin/fm-classify-lib.sh" "$state" || fail 'could not record the presentation receipt'
  while :; do
    rc=0
    fm_run_timed 60 env FM_STATE_OVERRIDE="$state" FM_WAKE_DRAIN_PRESENTATION_TIMEOUT=2 \
      "$BASH" "$DRAIN" > "$dir/attempt.out" 2> "$dir/attempt.err" || rc=$?
    attempt=$((attempt + 1))
    offset=$(FM_STATE_OVERRIDE="$state" /bin/bash -c '. "$1"; status_open_decisions_cursor_offset "$2"' \
      _ "$ROOT/bin/fm-classify-lib.sh" "$status")
    [ "$rc" -ne 0 ] || break
    assert_equals 124 "$rc" "a cold fold attempt failed for a reason other than its deadline: $(cat "$dir/attempt.err")"
    [ "$offset" -ge "$previous" ] || fail "a bounded attempt moved the fold cursor back from $previous to $offset"
    [ "$offset" -lt "$size" ] || break
    previous=$offset
    [ "$attempt" -lt 60 ] || fail "a cold fold never finished across $attempt bounded attempts"
  done
  cmp "$dir/history.before" "$status" || fail 'bounded folding rewrote history'
  rc=0
  fm_run_timed 75 env -u FM_WAKE_DRAIN_PRESENTATION_TIMEOUT FM_STATE_OVERRIDE="$state" \
    "$BASH" "$DRAIN" > "$dir/final.out" 2> "$dir/final.err" || rc=$?
  assert_equals 0 "$rc" "the drain after checkpointed folding did not complete: $(cat "$dir/final.err")"
  i=0
  while [ "$i" -lt 40 ]; do
    assert_grep "$(printf '[key=k%03d]' "$i")" "$dir/final.out" "the completed drain did not present open decision $i"
    i=$((i + 1))
  done
  FM_STATE_OVERRIDE="$state" /bin/bash -c '. "$1"; status_open_decisions_incremental "$2"' \
    _ "$ROOT/bin/fm-classify-lib.sh" "$status" | LC_ALL=C sort > "$dir/open.after"
  cmp "$dir/expected" "$dir/open.after" || fail 'checkpointed folding changed the open decisions'
  pass "a cold decision fold keeps its progress across $attempt two-second presentation deadlines"
}

# Short task logs never reach a 64-line checkpoint, so the fleet scans' own
# between-task stop holds the fold to its bound. A scan called with a deadline
# that has already passed must still fold one changed task per call, past any
# prefix of unchanged ones, so retries always converge.
test_open_decision_scans_past_the_deadline_fold_one_changed_task_per_call() {
  local dir state mode i rc call folded previous task tasks=8 warm=4
  for mode in incremental snapshot; do
    dir=$(make_case "past-deadline-scan-$mode")
    state="$dir/state"
    i=0
    while [ "$i" -lt "$tasks" ]; do
      task=$(printf 'task-short-%03d' "$i")
      printf 'kind=ship\n' > "$state/$task.meta"
      {
        printf 'needs-decision [key=s%03d]: short decision %03d\n' "$i" "$i"
        printf 'working: short historical context\n'
      } > "$state/$task.status"
      # The first tasks are warm: their cursors already cover every line.
      if [ "$i" -lt "$warm" ]; then
        FM_STATE_OVERRIDE="$state" /bin/bash -c '. "$1"; status_open_decisions_incremental "$2" >/dev/null' \
          _ "$ROOT/bin/fm-classify-lib.sh" "$state/$task.status" || fail "could not warm $task"
      fi
      i=$((i + 1))
    done
    previous=$warm
    call=0
    while :; do
      call=$((call + 1))
      rc=0
      FM_STATE_OVERRIDE="$state" /bin/bash -c '
        . "$1"
        _FM_OPEN_DECISIONS_DEADLINE=0
        if [ "$3" = snapshot ]; then
          snapshot=$(status_presentation_snapshot "$2") || exit 1
          scan_open_decisions_snapshot "$2" "$snapshot"
        else
          scan_open_decisions_incremental "$2"
        fi
      ' _ "$ROOT/bin/fm-classify-lib.sh" "$state" "$mode" > "$dir/scan.out" 2> "$dir/scan.err" || rc=$?
      folded=0
      i=0
      while [ "$i" -lt "$tasks" ]; do
        task=$(printf 'task-short-%03d' "$i")
        [ "$(FM_STATE_OVERRIDE="$state" /bin/bash -c '. "$1"; status_open_decisions_cursor_offset "$2"' \
          _ "$ROOT/bin/fm-classify-lib.sh" "$state/$task.status")" = \
          "$(LC_ALL=C wc -c < "$state/$task.status" | tr -d '[:space:]')" ] && folded=$((folded + 1))
        i=$((i + 1))
      done
      assert_equals $((previous + 1)) "$folded" "$mode scan call $call past its deadline did not fold exactly one more changed task (rc=$rc): $(cat "$dir/scan.err")"
      previous=$folded
      if [ "$folded" -lt "$tasks" ]; then
        assert_equals 124 "$rc" "$mode scan call $call past its deadline did not stop after one changed task: $(cat "$dir/scan.err")"
        continue
      fi
      assert_equals 0 "$rc" "$mode scan call that folded the last changed task did not complete: $(cat "$dir/scan.err")"
      break
    done
    i=0
    while [ "$i" -lt "$tasks" ]; do
      assert_grep "$(printf '%s\ts%03d\t' "task-short-$(printf '%03d' "$i")" "$i")" "$dir/scan.out" \
        "the completed $mode scan did not list short decision $i"
      i=$((i + 1))
    done
  done
  pass "both open-decision scans past their deadline fold one changed task per call past an unchanged prefix and then complete"
}

if [ "$#" -gt 0 ]; then
  fm_test_run "$@"
  exit "$?"
fi

test_incident_note_answer_buried_under_routine_note_surfaces_both
test_failed_output_preserves_unread_notes_without_a_receipt
test_already_presented_notes_are_not_replayed
test_brand_new_note_after_presentation_is_surfaced
test_signal_annotation_surfaces_every_unread_note_not_only_the_newest
test_pending_reply_resolution_surfaces_once
test_self_announced_pending_reply_close_still_surfaces
test_unread_output_over_cap_remains_recoverable
test_snapshot_does_not_ack_a_later_append
test_retired_task_id_starts_new_status_unread
test_weak_identity_still_presents_and_advances
test_snapshot_failure_is_visible
test_open_decisions_fold_is_unchanged
test_empty_queue_does_not_swallow_later_signal_annotation
test_routine_working_and_covered_done_stay_silent_on_the_empty_queue
test_presentation_deadline_preserves_pending_data_and_recovers
test_large_unpresented_span_completes_without_a_presentation_deadline
test_timeout_cleans_only_attempt_owned_presentation_scratch
test_term_cleans_only_attempt_owned_presentation_scratch
test_int_cleans_only_attempt_owned_presentation_scratch
test_mixed_tasks_preserve_routine_presentation_ownership
test_warm_routine_history_is_bounded_without_acknowledging_it
test_invalid_presentation_bound_falls_back_to_the_default
test_unwritable_presentation_scratch_still_presents_outcomes_and_liveness
test_presentation_runner_start_failure_is_not_a_fold_timeout
test_presentation_scratch_of_a_live_worker_outlives_its_dead_owner
test_fresh_unregistered_scratch_of_a_dead_owner_is_kept
test_orphaned_presentation_scratch_of_a_dead_owner_is_removed
test_cold_decision_fold_progresses_across_presentation_deadlines
test_open_decision_scans_past_the_deadline_fold_one_changed_task_per_call
