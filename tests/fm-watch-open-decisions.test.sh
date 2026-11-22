#!/usr/bin/env bash
# Opt-in record-age reminders through the watcher's real queue interface.
# No endpoint, harness process, model call, or remote host is needed.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-open-decisions)
export FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$TMP_ROOT/state"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE"
# shellcheck source=bin/fm-watch.sh
. "$ROOT/bin/fm-watch.sh"

FM_OPEN_DECISION_OVERDUE_SECS=100
FM_OPEN_DECISION_BACKOFF_MAX_SECS=400

reset_case() {
  rm -rf -- "$STATE/afk-contracts"
  rm -f -- "$STATE"/* "$STATE"/.[!.]* "$CONFIG"/*
  OPEN_DECISION_REMINDER=
}

count_wakes() {
  if [ -f "$FM_WAKE_QUEUE" ]; then wc -l < "$FM_WAKE_QUEUE" | tr -d ' '; else printf 0; fi
}

test_disabled() {
  reset_case
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 0 ] || fail "disabled flag queued a reminder"
  [ ! -e "$STATE/.worker.open-decisions-cursor.timed" ] || fail "disabled flag folded status"
  pass "absent flag emits nothing and does not fold status"
}

test_oldest_and_backoff() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=older]: choose\nworking: continuing\n' > "$STATE/z-worker.status"
  printf 'blocked [at=1050] [key=newer]: help\n' > "$STATE/a-worker.status"
  open_decision_reminder_tick 1099
  [ "$(count_wakes)" = 0 ] || fail "not-yet-overdue key queued a reminder"
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 1 ] || fail "oldest overdue key did not queue exactly one wake"
  [ "$OPEN_DECISION_REMINDER" = 'check: open decision overdue: z-worker key=older age=200s' ] \
    || fail "reminder did not select the oldest durable record: $OPEN_DECISION_REMINDER"
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 2 ] || fail "another overdue key inherited the oldest key's backoff"
  open_decision_reminder_tick 1299
  [ "$(count_wakes)" = 2 ] || fail "same key repeated before its first backoff"
  open_decision_reminder_tick 1300
  [ "$(count_wakes)" = 3 ] || fail "first repeat did not become due"
  open_decision_reminder_tick 1300
  [ "$(count_wakes)" = 4 ] || fail "second key did not repeat independently"
  open_decision_reminder_tick 1499
  [ "$(count_wakes)" = 4 ] || fail "repeat interval did not double"
  open_decision_reminder_tick 1500
  open_decision_reminder_tick 1500
  [ "$(count_wakes)" = 6 ] || fail "doubled backoff did not expire"
  open_decision_reminder_tick 1899
  [ "$(count_wakes)" = 6 ] || fail "capped interval fired early"
  open_decision_reminder_tick 1900
  open_decision_reminder_tick 1900
  open_decision_reminder_tick 2300
  open_decision_reminder_tick 2300
  [ "$(count_wakes)" = 10 ] || fail "backoff did not stay bounded at the cap"
  pass "oldest key surfaces once, and independent per-key backoff doubles up to its cap"
}

assert_distinct_reminder_identities() {  # <older-task> <older-key> <newer-task> <newer-key>
  local older_task=$1 older_key=$2 newer_task=$3 newer_key=$4 now count=0
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=%s]: choose\n' "$older_key" > "$STATE/$older_task.status"
  printf 'blocked [at=1050] [key=%s]: help\n' "$newer_key" >> "$STATE/$newer_task.status"
  for now in 1200 1300 1500 1900 2300; do
    if [ "$count" -gt 0 ]; then
      open_decision_reminder_tick "$((now - 1))"
      [ "$(count_wakes)" = "$count" ] || fail "numeric-looking identity repeated before its backoff"
    fi
    open_decision_reminder_tick "$now"
    count=$((count + 1))
    [ "$(count_wakes)" = "$count" ] || fail "older numeric-looking identity did not become due"
    [ "$OPEN_DECISION_REMINDER" = "check: open decision overdue: $older_task key=$older_key age=$((now - 1000))s" ] \
      || fail "older numeric-looking identity was not selected: $OPEN_DECISION_REMINDER"
    open_decision_reminder_tick "$((now + 1))"
    count=$((count + 1))
    [ "$(count_wakes)" = "$count" ] || fail "distinct numeric-looking identity inherited another identity's backoff"
    [ "$OPEN_DECISION_REMINDER" = "check: open decision overdue: $newer_task key=$newer_key age=$((now + 1 - 1050))s" ] \
      || fail "newer numeric-looking identity was not selected: $OPEN_DECISION_REMINDER"
    open_decision_reminder_tick "$((now + 1))"
    [ "$(count_wakes)" = "$count" ] || fail "numeric-looking identity repeated without waiting"
  done
}

test_numeric_keys_are_distinct() {
  assert_distinct_reminder_identities worker 1 worker 01
  pass "keys 1 and 01 receive separate reminders and retain independent bounded backoff"
}

test_numeric_tasks_are_distinct() {
  assert_distinct_reminder_identities 1 api 01 api
  pass "tasks 1 and 01 receive separate reminders and retain independent bounded backoff"
}

test_resolution_and_reopen() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200
  printf 'resolved [at=1201] [key=api]: answered\n' >> "$STATE/worker.status"
  open_decision_reminder_tick 1600
  [ "$(count_wakes)" = 1 ] || fail "resolved key kept generating reminders"
  printf 'blocked [at=1600] [key=api]: new episode\n' >> "$STATE/worker.status"
  open_decision_reminder_tick 1700
  [ "$(count_wakes)" = 2 ] || fail "reopened key inherited the resolved episode's backoff"
  pass "resolution stops reminders immediately and a later episode starts fresh"
}

test_wait_exemptions() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=api]: choose\npaused [at=1050]: validation in flight\n' > "$STATE/paused.status"
  printf 'needs-decision [at=1000] [key=api]: choose\ncaptain-held [at=1050] [key=api]: transferred\n' > "$STATE/transferred.status"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/backlog-held.status"
  # The watcher already delegates backlog ownership to this predicate.
  task_captain_call_open() { [ "$1" = backlog-held ]; }
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 0 ] || fail "a declared wait or captain hold queued a reminder"
  printf 'working [at=1201]: resumed\n' >> "$STATE/paused.status"
  open_decision_reminder_tick 1201
  [ "$(count_wakes)" = 1 ] || fail "ending a pause hid the still-open key"
  pass "paused waits, verified transfers, and backlog captain holds are exempt"
}

test_unknown_times_and_keyless() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [key=missing]: choose\nblocked [at=bad] [key=bad]: help\nblocked [at=1000]: legacy\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 0 ] || fail "unknown emission time or keyless record was inferred overdue"
  pass "only explicitly keyed records with valid source timestamps are aged"
}

test_timed_fold_is_incremental() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/worker.status"
  export FM_OPEN_DECISIONS_READ_PROBE="$TMP_ROOT/fold.reads"
  : > "$FM_OPEN_DECISIONS_READ_PROBE"
  open_decision_reminder_tick 1200
  open_decision_reminder_tick 1201
  [ "$(wc -l < "$FM_OPEN_DECISIONS_READ_PROBE" | tr -d ' ')" = 1 ] \
    || fail "unchanged poll reread the task's history"
  printf 'resolved [key=api]: answered\n' >> "$STATE/worker.status"
  open_decision_reminder_tick 1202
  [ "$(tail -1 "$FM_OPEN_DECISIONS_READ_PROBE" | cut -f2)" = 29 ] \
    || fail "resolution poll folded more than newly appended bytes"
  [ "$(count_wakes)" = 1 ] || fail "incremental resolution left a reminder live"
  unset FM_OPEN_DECISIONS_READ_PROBE
  pass "quiet polls reuse the timed fold and only new status bytes are folded"
}


test_p0_incremental_deadlines() {
  reset_case
  printf 'priority=0\nkind=ship\nwindow=test:worker\n' > "$STATE/worker.meta"
  printf 'blocked [at=1000]: credentials missing\n' > "$STATE/worker.status"
  P0_BLOCKER_ALARMS=
  export FM_OPEN_DECISIONS_READ_PROBE="$TMP_ROOT/p0-fold.reads"
  : > "$FM_OPEN_DECISIONS_READ_PROBE"
  FM_WATCH_NOW=1599 p0_blocker_alarm test:worker worker
  [ "$(count_wakes)" = 0 ] || fail 'keyless blocker alarmed early'
  FM_WATCH_NOW=1600 p0_blocker_alarm test:worker worker
  [ "$(count_wakes)" = 1 ] || fail 'due keyless blocker did not alarm'
  FM_WATCH_NOW=1700 p0_blocker_alarm test:worker worker
  printf 'resolved [key=default] [at=1800]: answered\nblocked [at=2000]: credentials missing\n' >> "$STATE/worker.status"
  FM_WATCH_NOW=2599 p0_blocker_alarm test:worker worker
  FM_WATCH_NOW=2600 p0_blocker_alarm test:worker worker
  [ "$(count_wakes)" = 2 ] || fail 'reopened keyless blocker did not get its own deadline'
  printf 'done [at=2700]: finished\n' >> "$STATE/worker.status"
  FM_WATCH_NOW=2800 p0_blocker_alarm test:worker worker
  printf 'needs-decision [key=region] [at=2900]: choose\n' >> "$STATE/worker.status"
  FM_WATCH_NOW=3600 p0_blocker_alarm test:worker worker
  [ "$(count_wakes)" = 2 ] || fail 'an ineligible blocker scan queued an alarm'
  [ "$(wc -l < "$FM_OPEN_DECISIONS_READ_PROBE" | tr -d ' ')" = 4 ] \
    || fail 'unchanged P0 scans reread status history'
  unset FM_OPEN_DECISIONS_READ_PROBE
  pass 'incremental P0 scans alarm only due unsurfaced blockers, including keyless reopens'
}

test_p0_keyed_note_updates_keep_first_opening() {
  reset_case
  printf 'priority=0\nkind=ship\nwindow=test:worker\n' > "$STATE/worker.meta"
  printf 'blocked [key=key] [at=1000]: attempt one\n' > "$STATE/worker.status"
  FM_WATCH_NOW=1500 p0_blocker_alarm test:worker worker
  printf 'blocked [key=key] [at=1500]: attempt two\n' >> "$STATE/worker.status"
  FM_WATCH_NOW=1599 p0_blocker_alarm test:worker worker
  [ "$(count_wakes)" = 0 ] || fail 'updated blocker alarmed early'
  FM_WATCH_NOW=1600 p0_blocker_alarm test:worker worker
  [ "$(count_wakes)" = 1 ] || fail 'note update restarted the unresolved keyed opening age'
  grep -F 'open for 600s: blocked [key=key] [at=1500]: attempt two' "$FM_WAKE_QUEUE" >/dev/null \
    || fail 'alarm did not retain opening age and show the latest blocker text'
  printf 'blocked [key=key] [at=1700]: attempt three\n' >> "$STATE/worker.status"
  FM_WATCH_NOW=1800 p0_blocker_alarm test:worker worker
  [ "$(count_wakes)" = 1 ] || fail 'a note update republished an already surfaced opening'
  pass 'unresolved keyed blocker age and once-only alarm survive note updates'
}

test_p0_keyless_repeats_keep_first_opening() {
  reset_case
  printf 'priority=0\nkind=ship\nwindow=test:worker\n' > "$STATE/worker.meta"
  printf 'blocked [at=1000]: need\tcredentials\n' > "$STATE/worker.status"
  FM_WATCH_NOW=1500 p0_blocker_alarm test:worker worker
  printf 'blocked [at=1500]: need\tcredentials\n' >> "$STATE/worker.status"
  FM_WATCH_NOW=1599 p0_blocker_alarm test:worker worker
  [ "$(count_wakes)" = 0 ] || fail 'repeated keyless blocker alarmed early'
  FM_WATCH_NOW=1600 p0_blocker_alarm test:worker worker
  [ "$(count_wakes)" = 1 ] || fail 'keyless repeat restarted the opening age'
  grep -F 'open for 600s: blocked [at=1500]: need credentials)' "$FM_WAKE_QUEUE" >/dev/null \
    || fail 'keyless repeat did not keep the age and latest declaration'
  printf 'blocked [at=1700]: need\tcredentials\n' >> "$STATE/worker.status"
  FM_WATCH_NOW=1800 p0_blocker_alarm test:worker worker
  [ "$(count_wakes)" = 1 ] || fail 'keyless repeat republished an already surfaced opening'
  pass 'keyless repeats keep their original age and declaration text'
}

test_p0_alarm_keeps_captured_declarations() {
  local declaration detail reopen_key
  for declaration in \
    'blocked [key=key] [at=1000]: original' \
    'blocked [at=1000]: original' \
    'blocked [key=key] [at=bad]: original' \
    'blocked [key=key] [at=2000]: original'; do
    reset_case
    printf 'priority=0\nkind=ship\nwindow=test:worker\n' > "$STATE/worker.meta"
    printf '%s\nblocked [key=sibling] [at=900]: original sibling\n' "$declaration" > "$STATE/worker.status"
    reopen_key=key
    detail='P0 blocker open for 600s'
    case "$declaration" in
      'blocked [at=1000]'*) reopen_key=default ;;
      *'[at=bad]'*) detail='P0 blocker opening timestamp missing or malformed' ;;
      *'[at=2000]'*) detail='P0 blocker opening timestamp is in the future' ;;
    esac
    (
      eval "snapshot_saved_$(declare -f fm_watch_now)"
      fm_watch_now() {
        snapshot_saved_fm_watch_now "$@"
        printf 'resolved [key=%s] [at=1600]: answered\nblocked [key=%s] [at=1600]: reopened\nblocked [key=sibling] [at=1600]: updated sibling\n' \
          "$reopen_key" "$reopen_key" >> "$STATE/worker.status"
      }
      FM_WATCH_NOW=1600 p0_blocker_alarm test:worker worker
    ) || fail 'concurrent reopen alarm failed'
    [ "$(count_wakes)" = 2 ] || fail 'captured blockers did not each alarm'
    grep -F "$detail: $declaration)" "$FM_WAKE_QUEUE" >/dev/null \
      || fail 'alarm mixed opening age with a later declaration'
    grep -F 'open for 700s: blocked [key=sibling] [at=900]: original sibling)' "$FM_WAKE_QUEUE" >/dev/null \
      || fail 'sibling alarm read a declaration after the captured fold'
    FM_WATCH_NOW=1700 p0_blocker_alarm test:worker worker
    [ "$(count_wakes)" = 2 ] || fail 'reopen inherited the previous opening deadline'
    FM_WATCH_NOW=2200 p0_blocker_alarm test:worker worker
    [ "$(count_wakes)" = 3 ] || fail 'captured alarm marked the later opening as surfaced'
    grep -F "open for 600s: blocked [key=$reopen_key] [at=1600]: reopened)" "$FM_WAKE_QUEUE" >/dev/null \
      || fail 'reopened blocker did not surface its own age and declaration'
    FM_WATCH_NOW=2300 p0_blocker_alarm test:worker worker
    [ "$(count_wakes)" = 3 ] || fail 'captured opening alarm repeated'
  done
  pass 'P0 alarms keep captured declarations and give concurrent reopens separate deadlines'
}

test_p0_old_cursor_rebuilds_declarations() {
  reset_case
  printf 'priority=0\nkind=ship\nwindow=test:worker\n' > "$STATE/worker.meta"
  printf 'blocked [key=key] [at=1000]: original\n' > "$STATE/worker.status"
  printf 'version=%s:ship:timed-all2\noffset=%s\nident=%s\nkey\tblocked\t1000\t-\told-opening\toriginal\n' \
    "$FM_OPEN_DECISIONS_FOLD_VERSION" "$(_fm_status_file_size "$STATE/worker.status")" \
    "$(_fm_open_decisions_file_ident "$STATE/worker.status")" > "$STATE/.worker.open-decisions-cursor.timed-all"
  FM_WATCH_NOW=1600 p0_blocker_alarm test:worker worker
  [ "$(count_wakes)" = 1 ] || fail 'old cursor prevented a due blocker alarm'
  grep -F 'open for 600s: blocked [key=key] [at=1000]: original)' "$FM_WAKE_QUEUE" >/dev/null \
    || fail 'old cursor note was presented as an exact declaration'
  pass 'P0 alarms rebuild older persisted cursors before presenting declarations'
}

test_p0_once_only_survives_endpoint_replacement() {
  reset_case
  printf 'priority=0\nkind=ship\nwindow=test:worker-a\n' > "$STATE/worker.meta"
  printf 'blocked [key=key] [at=1000]: deployment key missing\n' > "$STATE/worker.status"
  FM_WATCH_NOW=1600 p0_blocker_alarm test:worker-a worker
  [ "$(count_wakes)" = 1 ] || fail 'due blocker did not alarm on its first endpoint'
  printf 'priority=0\nkind=ship\nwindow=test:worker-b\n' > "$STATE/worker.meta"
  FM_WATCH_NOW=1700 p0_blocker_alarm test:worker-b worker
  [ "$(count_wakes)" = 1 ] || fail 'a replacement endpoint re-alarmed the same blocker opening'
  printf 'resolved [key=key] [at=1800]: answered\nblocked [key=key] [at=2000]: deployment key missing\n' >> "$STATE/worker.status"
  FM_WATCH_NOW=2600 p0_blocker_alarm test:worker-b worker
  [ "$(count_wakes)" = 2 ] || fail 'a new opening on the replacement endpoint did not alarm'
  pass 'a replacement endpoint keeps the task once-only alarm and still alarms a new opening'
}
test_p0_marker_survives_unreadable_status() {
  reset_case
  printf 'priority=0\nkind=ship\nwindow=test:worker\n' > "$STATE/worker.meta"
  printf 'blocked [key=key] [at=1000]: deployment key missing\n' > "$STATE/worker.status"
  FM_WATCH_NOW=1600 p0_blocker_alarm test:worker worker
  [ "$(count_wakes)" = 1 ] || fail 'due blocker did not alarm'
  chmod 000 "$STATE/worker.status"
  if [ -r "$STATE/worker.status" ]; then
    chmod 644 "$STATE/worker.status"
    pass 'skipped: this user can read a mode-000 file, so the status log cannot be made unreadable'
    return 0
  fi
  FM_WATCH_NOW=1700 p0_blocker_alarm test:worker worker
  chmod 644 "$STATE/worker.status"
  FM_WATCH_NOW=1800 p0_blocker_alarm test:worker worker
  [ "$(count_wakes)" = 1 ] || fail 'a momentarily unreadable status log re-alarmed the same opening'
  rm -f "$STATE/worker.status"
  FM_WATCH_NOW=1900 p0_blocker_alarm test:worker worker
  [ ! -e "$STATE/.p0-blocker-surfaced-worker" ] || fail 'an absent status log kept the surfaced marker'
  pass 'an unreadable status log keeps the once-only marker; an absent one clears it'
}
test_p0_marker_survives_status_read_failure() {
  local fail_reader="$TMP_ROOT/p0-failing-reader"
  printf '#!/bin/sh\nexit 1\n' > "$fail_reader"
  chmod +x "$fail_reader"
  reset_case
  printf 'priority=0\nkind=ship\nwindow=test:worker\n' > "$STATE/worker.meta"
  printf 'blocked [key=key] [at=1000]: deployment key missing\n' > "$STATE/worker.status"
  FM_WATCH_NOW=1600 p0_blocker_alarm test:worker worker
  [ "$(count_wakes)" = 1 ] || fail 'due blocker did not alarm'
  rm -f "$STATE"/.worker.open-decisions-cursor*
  ( FM_STATUS_IDENTITY_READER="$fail_reader" FM_WATCH_NOW=1700 p0_blocker_alarm test:worker worker ) 2>/dev/null || true
  [ -e "$STATE/.p0-blocker-surfaced-worker" ] || fail 'a failed status identity read with no cursor dropped the surfaced marker'
  printf 'not a cursor\n' > "$STATE/.worker.open-decisions-cursor.timed-all"
  ( FM_STATUS_SPAN_READER="$fail_reader" FM_WATCH_NOW=1750 p0_blocker_alarm test:worker worker ) 2>/dev/null || true
  [ -e "$STATE/.p0-blocker-surfaced-worker" ] || fail 'a failed status span read with an invalid cursor dropped the surfaced marker'
  FM_WATCH_NOW=1800 p0_blocker_alarm test:worker worker
  [ "$(count_wakes)" = 1 ] || fail 'a failed status read re-alarmed the same opening'
  pass 'a status log read failure with no trusted cursor keeps the once-only marker'
}
test_p0_invalid_opening_time_is_explicit_and_reopens() {
  local declaration diagnostic
  for declaration in \
    'blocked [key=key]: need key' \
    'blocked [key=key] [at=<epoch>]: need key' \
    'blocked [key=key] [at=10:30]: need key' \
    'blocked [key=key] [at=2000]: need key'; do
    reset_case
    printf 'priority=0\nkind=ship\nwindow=test:worker\n' > "$STATE/worker.meta"
    printf '%s\n' "$declaration" > "$STATE/worker.status"
    FM_WATCH_NOW=1600 p0_blocker_alarm test:worker worker
    [ "$(count_wakes)" = 1 ] || fail "invalid opening time silently suppressed the alarm: $declaration"
    diagnostic='P0 blocker opening timestamp missing or malformed'
    case "$declaration" in *'[at=2000]'*) diagnostic='P0 blocker opening timestamp is in the future' ;; esac
    grep -F "$diagnostic: $declaration" "$FM_WAKE_QUEUE" >/dev/null \
      || fail 'invalid opening did not surface explicitly with exact declaration text'
    grep -F 'open for ' "$FM_WAKE_QUEUE" >/dev/null && fail 'invalid opening invented an elapsed time'
    FM_WATCH_NOW=1700 p0_blocker_alarm test:worker worker
    [ "$(count_wakes)" = 1 ] || fail 'unchanged invalid opening repeated'
    printf 'resolved [key=key] [at=1800]: answered\n%s\n' "$declaration" >> "$STATE/worker.status"
    FM_WATCH_NOW=1900 p0_blocker_alarm test:worker worker
    [ "$(count_wakes)" = 2 ] || fail 'identical malformed reopen was mistaken for its resolved predecessor'
  done
  pass 'invalid timestamps surface explicitly once per opening without invented ages'
}

test_invalid_settings() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  if FM_OPEN_DECISION_OVERDUE_SECS=0 open_decision_reminder_tick 1200; then
    fail "zero threshold enabled an unbounded reminder loop"
  fi
  if FM_OPEN_DECISION_BACKOFF_MAX_SECS=99 open_decision_reminder_tick 1200; then
    fail "cap below the threshold was accepted"
  fi
  [ "$(count_wakes)" = 0 ] || fail "invalid settings queued a reminder"
  pass "invalid settings refuse the tick without queueing reminders"
}

test_timed_cursor_retirement() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200
  status_open_decisions_incremental "$STATE/worker.status" '' timed-all >/dev/null
  status_retire_presentation_task "$STATE" worker
  [ ! -e "$STATE/.worker.open-decisions-cursor.timed" ] || fail "task retirement left its timed cursor"
  [ ! -e "$STATE/.worker.open-decisions-cursor.timed-all" ] || fail "task retirement left its timed-all cursor"
  open_decision_reminder_tick 1600
  [ "$(count_wakes)" = 1 ] || fail "retired task kept generating reminders"
  pass "task retirement removes the timed cursor and ends reminders"
}

test_watcher_loop() {
  local dir="$TMP_ROOT/watcher-loop" pid i=0
  mkdir -p "$dir/state" "$dir/config"
  fm_test_track_watcher_state "$dir/state"
  touch "$dir/config/open-decision-reminders" "$dir/state/home-summary.json"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$dir/state/worker.status"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_OPEN_DECISION_OVERDUE_SECS=100 FM_OPEN_DECISION_BACKOFF_MAX_SECS=400 \
    bash "$ROOT/bin/fm-watch.sh" > "$dir/out" 2> "$dir/err" &
  pid=$!
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "real watcher failed to wake on an overdue record"
  fi
  wait "$pid" || fail "real watcher exited unsuccessfully: $(cat "$dir/err")"
  grep -F 'check: open decision overdue: worker key=api age=' "$dir/out" >/dev/null \
    || fail "real watcher did not print the reminder wake"
  [ "$(wc -l < "$dir/state/.wake-queue" | tr -d ' ')" = 1 ] \
    || fail "real watcher did not durably queue exactly one reminder"
  pass "the actual watcher wakes and exits on an overdue key without any recorded pane"
}

test_away_age_route() {
  reset_case
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/worker.status"
  away_decision_age_tick 2800
  [ "$(count_wakes)" = 0 ] || fail 'present posture age-routed a decision'
  FM_AFK_MODE=quiet bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'quiet test' >/dev/null
  away_decision_age_tick 2800
  [ "$(count_wakes)" = 0 ] || fail 'quiet posture age-routed a decision'
  FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'away test' >/dev/null
  away_decision_age_tick 2799
  [ "$(count_wakes)" = 0 ] || fail 'away decision routed before default 30 minutes'
  FM_WEDGE_ALARM_CHANNEL=off away_decision_age_tick 2800
  grep -q 'page-pending' "$STATE/.away-decision-age-claims" || fail 'away decision did not retain a pending page at 30 minutes'
  [ "$(count_wakes)" = 0 ] || fail 'absent council entrypoint queued a wake'
  away_decision_age_tick 2801
  [ "$(count_wakes)" = 0 ] || fail 'same decision generation queued a wake'
  rm -f -- "$STATE/.afk-contract"
  FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'new away session' >/dev/null
  away_decision_age_tick 2802
  [ "$(count_wakes)" = 0 ] || fail 'same decision generation queued a wake in a new away session'
  printf 'blocked [at=1050] [key=followup]: choose again\n' > "$STATE/second.status"
  FM_WEDGE_ALARM_CHANNEL=off away_decision_age_tick 2850
  [ "$(grep -c 'page-pending' "$STATE/.away-decision-age-claims")" = 2 ] \
    || fail 'claimed oldest decision hid a later due decision'
  [ "$(count_wakes)" = 0 ] || fail 'second decision queued a council wake'
  pass 'only away posture routes one decision at the default age'
}

test_away_age_page_and_staleness() {
  reset_case
  printf 'blocked [at=1000] [key=ship]: needs approval\n' > "$STATE/worker.status"
  FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'away test' >/dev/null
  FM_AWAY_DECISION_OVERDUE_SECS=60 away_decision_age_tick 1059
  [ ! -e "$STATE/.away-decision-age-claims" ] || fail 'early decision was claimed'
  FM_WEDGE_ALARM_CHANNEL=off FM_AWAY_DECISION_OVERDUE_SECS=60 away_decision_age_tick 1060
  grep -q 'page-pending' "$STATE/.away-decision-age-claims" \
    || fail 'overdue decision did not retain a pending page'
  [ "$(count_wakes)" = 0 ] || fail 'overdue decision reached the council'
  reset_case
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/worker.status"
  FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'away test' >/dev/null
  cat > "$STATE/resolve-before-action.sh" <<'SH'
#!/usr/bin/env bash
printf 'resolved [at=1100] [key=api]: answered\n' >> "$FM_STATE_OVERRIDE/worker.status"
SH
  chmod 0700 "$STATE/resolve-before-action.sh"
  FM_TEST_DECISION_ROUTE_BEFORE_ACTION="$STATE/resolve-before-action.sh" \
    FM_AWAY_DECISION_OVERDUE_SECS=60 away_decision_age_tick 1100
  [ "$(count_wakes)" = 0 ] || fail 'stale decision generation reached the council'
  grep -q 'stale' "$STATE/.away-decision-age-claims" || fail 'stale claim was not recorded'
  pass 'overdue decision pages and stale generation refuses route'
}

test_away_confirmation_change_keeps_decision_open() {
  reset_case
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/worker.status"
  FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'away test' >/dev/null
  cat > "$STATE/leave-away.sh" <<'SH'
#!/usr/bin/env bash
rm -f -- "$FM_STATE_OVERRIDE/.afk-contract"
SH
  chmod 0700 "$STATE/leave-away.sh"
  FM_TEST_DECISION_ROUTE_BEFORE_ACTION="$STATE/leave-away.sh" \
    FM_WEDGE_ALARM_CHANNEL=off FM_AWAY_DECISION_OVERDUE_SECS=60 away_decision_age_tick 1100
  [ ! -s "$STATE/.away-decision-age-claims" ] || fail 'changed confirmation claimed an open decision'
  FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'away again' >/dev/null
  FM_WEDGE_ALARM_CHANNEL=off FM_AWAY_DECISION_OVERDUE_SECS=60 away_decision_age_tick 1101
  grep -q 'page-pending' "$STATE/.away-decision-age-claims" \
    || fail 'open decision did not page after the confirmation changed'
  pass 'changed away confirmation leaves the open decision to page later'
}

test_interrupted_claim_retries_page() {
  reset_case
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/worker.status"
  FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'away test' >/dev/null
  printf 'worker\tapi\t1000\t1\tclaiming\t1100\n' > "$STATE/.away-decision-age-claims"
  FM_WEDGE_ALARM_EXEC='' FM_WEDGE_ALARM_CHANNEL=command:true \
    FM_AWAY_DECISION_OVERDUE_SECS=60 away_decision_age_tick 1159
  ! grep -q 'page-' "$STATE/.away-decision-age-claims" || fail 'interrupted claim retried before retry bound'
  FM_WEDGE_ALARM_EXEC='' FM_WEDGE_ALARM_CHANNEL=command:true \
    FM_AWAY_DECISION_OVERDUE_SECS=60 away_decision_age_tick 1160
  grep -q 'page-sent' "$STATE/.away-decision-age-claims" || fail 'interrupted claim never paged'
  [ "$(count_wakes)" = 0 ] || fail 'interrupted claim retry sent a council wake'
  pass 'claim interrupted before its page retries after the bound'
}

test_missing_council_entrypoint_pages() {
  local dir="$TMP_ROOT/missing-council"
  mkdir -p "$dir/state" "$dir/config"
  fm_test_track_watcher_state "$dir/state"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$dir/state/worker.status"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'away test' >/dev/null
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_WATCH_NOW=2800 FM_WATCH_ONCE=1 FM_WEDGE_ALARM_CHANNEL=off \
    bash "$ROOT/bin/fm-watch.sh" > "$dir/out" 2> "$dir/err" \
    || fail "real watcher failed: $(cat "$dir/err")"
  grep -F $'worker\tapi\t1000\t' "$dir/state/.away-decision-age-claims" | grep -F $'page-pending\t' >/dev/null \
    || fail 'missing council entrypoint did not retain a pending captain page'
  if [ -f "$dir/state/.wake-queue" ]; then
    ! grep -F 'away-decision:worker:api:1000' "$dir/state/.wake-queue" >/dev/null \
      || fail 'missing council entrypoint queued a council wake'
  fi
  pass 'real watcher pages the captain when council entrypoint is absent'
}

test_invalid_authority_config_still_pages() {
  local dir="$TMP_ROOT/invalid-authority"
  mkdir -p "$dir/state" "$dir/config"
  fm_test_track_watcher_state "$dir/state"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$dir/state/worker.status"
  printf 'worker\tapi\t1000\troutine\n' > "$dir/authority-target"
  ln -s "$dir/authority-target" "$dir/config/decision-age-authority"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'away test' >/dev/null
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_WATCH_NOW=2800 FM_WATCH_ONCE=1 FM_WEDGE_ALARM_CHANNEL=off \
    bash "$ROOT/bin/fm-watch.sh" > "$dir/out" 2> "$dir/err" \
    || fail "real watcher failed on an invalid authority file: $(cat "$dir/err")"
  grep -F $'worker\tapi\t1000\t' "$dir/state/.away-decision-age-claims" | grep -F $'page-pending\t' >/dev/null \
    || fail 'invalid authority file stopped the captain page'
  if [ -f "$dir/state/.wake-queue" ]; then
    ! grep -F 'away-decision:worker:api:1000' "$dir/state/.wake-queue" >/dev/null \
      || fail 'invalid authority file queued a council wake'
  fi
  pass 'real watcher still pages the captain with an invalid authority file'
}

test_away_page_retries_after_channel_configured() {
  reset_case
  printf 'needs-decision [at=1000] [key=approval]: choose\n' > "$STATE/worker.status"
  FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'away test' >/dev/null
  FM_WEDGE_ALARM_CHANNEL=off FM_AWAY_DECISION_OVERDUE_SECS=60 away_decision_age_tick 1060
  grep -q 'page-pending' "$STATE/.away-decision-age-claims" || fail 'missing channel was not pending'
  FM_WEDGE_ALARM_EXEC='' FM_WEDGE_ALARM_CHANNEL=command:true \
    FM_AWAY_DECISION_OVERDUE_SECS=60 away_decision_age_tick 1119
  ! grep -q 'page-sent' "$STATE/.away-decision-age-claims" || fail 'page retried before retry bound'
  FM_WEDGE_ALARM_EXEC='' FM_WEDGE_ALARM_CHANNEL=command:true \
    FM_AWAY_DECISION_OVERDUE_SECS=60 away_decision_age_tick 1120
  grep -q 'page-sent' "$STATE/.away-decision-age-claims" || fail 'configured channel did not retry pending page'
  [ "$(count_wakes)" = 0 ] || fail 'page retry sent a council wake'
  pass 'pending page retries when a channel becomes available'
}

# --- away gate council trigger ----------------------------------------------
# A stub ak records its arguments and writes a council record shaped like
# AgentKit's, so the trigger is exercised end to end without a model call.
gate_council_setup() {  # [project-dir-name]
  local project=${1:-allowed-proj}
  reset_case
  rm -rf -- "$FM_HOME/data" "$TMP_ROOT/bin-stub"
  mkdir -p "$FM_HOME/data/worker" "$TMP_ROOT/bin-stub"
  GATE_STUB="$TMP_ROOT/bin-stub/ak"
  cat > "$GATE_STUB" <<'SH'
#!/usr/bin/env bash
out=
prev=
for arg in "$@"; do
  [ "$prev" != --out ] || out=$arg
  prev=$arg
done
printf '%s\n' "$@" > "${out%/*}/stub-args"
outcome=${GATE_STUB_OUTCOME:-decline}
printf '{\n  "schema": "council-record",\n  "seats": [\n    {\n      "choice": "fix"\n    }\n  ],\n  "outcome": "%s",\n  "choice": "%s",\n  "grants": []\n}\n' \
  "$outcome" "${GATE_STUB_CHOICE:-decline}" > "$out"
echo "council $outcome: $out"
[ "$outcome" = approve ] || [ "$outcome" = decline ]
SH
  chmod +x "$GATE_STUB"
  printf '{}\n' > "$TMP_ROOT/roster.json"
  chmod 600 "$TMP_ROOT/roster.json"
  printf 'roster=%s\nprojects=other, allowed-proj\nak=%s\n' "$TMP_ROOT/roster.json" "$GATE_STUB" \
    > "$CONFIG/gate-council"
  printf 'project=/somewhere/projects/%s\nkind=ship\n' "$project" > "$STATE/worker.meta"
  printf 'F1 the finding text\n' > "$FM_HOME/data/worker/nm-r1-findings.txt"
  printf '# Task\n## Captain'"'"'s intent\nship the widget\n## Firstmate spec\nbuild it\n' \
    > "$FM_HOME/data/worker/brief.md"
  printf 'needs-decision [at=1000] [key=nm-r1-review]: ask-user findings=F1 file=%s\n' \
    "$FM_HOME/data/worker/nm-r1-findings.txt" > "$STATE/worker.status"
}

gate_council_wait_exit() {  # <run-dir>
  local i=0
  while [ "$i" -lt 100 ] && [ ! -f "$1/exit" ]; do sleep 0.1; i=$((i + 1)); done
  [ -f "$1/exit" ] || fail 'detached council run never finished'
}

test_gate_council_off_and_filters() {
  gate_council_setup
  rm -f -- "$CONFIG/gate-council"
  FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'away test' >/dev/null
  away_gate_council_tick 9000
  [ ! -e "$STATE/.away-gate-council-claims" ] || fail 'absent config started a council'
  gate_council_setup
  away_gate_council_tick 9000
  [ ! -e "$STATE/.away-gate-council-claims" ] || fail 'present posture started a council'
  FM_AFK_MODE=quiet bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'quiet test' >/dev/null
  away_gate_council_tick 9000
  [ ! -e "$STATE/.away-gate-council-claims" ] || fail 'quiet posture started a council'
  gate_council_setup not-listed
  FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'away test' >/dev/null
  away_gate_council_tick 9000
  [ ! -e "$STATE/.away-gate-council-claims" ] || fail 'project outside the allowlist started a council'
  gate_council_setup
  FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'away test' >/dev/null
  away_gate_council_tick 4599
  [ ! -e "$STATE/.away-gate-council-claims" ] || fail 'gate younger than one hour started a council'
  printf 'needs-decision [at=1000] [key=nm-r1-review]: ask-user findings=F1 file=%s\n' \
    "$TMP_ROOT/elsewhere.txt" > "$STATE/worker.status"
  printf 'x\n' > "$TMP_ROOT/elsewhere.txt"
  away_gate_council_tick 9000
  [ ! -e "$STATE/.away-gate-council-claims" ] || fail 'findings outside the task data started a council'
  printf 'needs-decision [at=1000] [key=api]: ask-user findings=F1 file=%s\nblocked [at=1000] [key=nm-r2-test]: ask-user findings=F1 file=%s\n' \
    "$FM_HOME/data/worker/nm-r1-findings.txt" "$FM_HOME/data/worker/nm-r1-findings.txt" > "$STATE/worker.status"
  away_gate_council_tick 9000
  [ ! -e "$STATE/.away-gate-council-claims" ] || fail 'a non-gate decision started a council'
  [ "$(count_wakes)" = 0 ] || fail 'filtered gates queued a wake'
  pass 'gate council stays off without config, away posture, allowlist, age, gate key, or task findings'
}

test_gate_council_runs_once_and_surfaces() {
  local dir status_before
  gate_council_setup
  FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'away test' >/dev/null
  status_before=$(cat "$STATE/worker.status")
  away_gate_council_tick 4600
  grep -q $'\trunning\t' "$STATE/.away-gate-council-claims" || fail 'hour-old gate did not start a council'
  [ -z "$GATE_COUNCIL_WAKE" ] || fail 'council start queued a wake before a ruling'
  dir="$FM_HOME/data/worker/gate-council-nm-r1-review-1000"
  gate_council_wait_exit "$dir"
  grep -qx -- '--council-config' "$dir/stub-args" || fail 'council run had no roster flag'
  grep -qx -- "$TMP_ROOT/roster.json" "$dir/stub-args" || fail 'council did not receive the configured roster'
  grep -qx -- "$FM_HOME/data/worker/nm-r1-findings.txt" "$dir/stub-args" || fail 'findings were not context'
  grep -qx -- "$dir/task-intent.md" "$dir/stub-args" || fail 'task intent was not context'
  grep -qx 'ship the widget' "$dir/task-intent.md" || fail 'task intent context lost the intent body'
  grep -q '^{"id":"gate-worker-nm-r1-review-1000","question":"[^"]*","options":\["fix","decline"\],"approve":"fix"}$' \
    "$dir/card.json" || fail "card does not match the council card shape: $(cat "$dir/card.json")"
  away_gate_council_tick 4700
  [ "$GATE_COUNCIL_WAKE" = "check: gate council ruled: worker key=nm-r1-review outcome=decline choice=decline record=$dir/record.json" ] \
    || fail "ruling surfaced wrong: $GATE_COUNCIL_WAKE"
  [ "$(count_wakes)" = 1 ] || fail 'ruling did not queue exactly one wake'
  away_gate_council_tick 4800
  [ -z "$GATE_COUNCIL_WAKE" ] || fail 'ruling surfaced twice'
  [ "$(count_wakes)" = 1 ] || fail 'ruling queued a second wake'
  [ "$(grep -c $'\trunning\t' "$STATE/.away-gate-council-claims")" = 1 ] || fail 'same gate episode got a second council'
  [ "$(cat "$STATE/worker.status")" = "$status_before" ] || fail 'trigger wrote to the gate status log'
  pass 'one council per gate episode, ruling surfaced once as evidence, gate left unanswered'
}

test_gate_council_closed_gate_and_failure() {
  local dir
  gate_council_setup
  FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'away test' >/dev/null
  away_gate_council_tick 4600
  dir="$FM_HOME/data/worker/gate-council-nm-r1-review-1000"
  gate_council_wait_exit "$dir"
  printf 'resolved [at=4650] [key=nm-r1-review]: answered\n' >> "$STATE/worker.status"
  away_gate_council_tick 4700
  [ -z "$GATE_COUNCIL_WAKE" ] || fail 'ruling for a closed gate surfaced'
  [ "$(count_wakes)" = 0 ] || fail 'ruling for a closed gate queued a wake'
  grep -q $'\tgate-closed\t' "$STATE/.away-gate-council-claims" || fail 'closed gate was not recorded'
  gate_council_setup
  FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'away test' >/dev/null
  away_gate_council_tick 4600
  gate_council_wait_exit "$dir"
  eval "gate_council_saved_$(declare -f status_open_decisions_incremental)"
  status_open_decisions_incremental() { return 1; }
  away_gate_council_tick 4700 2>/dev/null || true
  eval "$(declare -f gate_council_saved_status_open_decisions_incremental | sed '1s/^gate_council_saved_//')"
  [ -z "$GATE_COUNCIL_WAKE" ] || fail 'ruling surfaced while the status log was unreadable'
  ! grep -q $'\tgate-closed\t' "$STATE/.away-gate-council-claims" || fail 'status read failure recorded a closed gate'
  away_gate_council_tick 4800
  [ "$GATE_COUNCIL_WAKE" = "check: gate council ruled: worker key=nm-r1-review outcome=decline choice=decline record=$dir/record.json" ] \
    || fail "ruling was dropped after a status read failure: $GATE_COUNCIL_WAKE"
  gate_council_setup
  FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'away test' >/dev/null
  GATE_STUB_OUTCOME=escalate GATE_STUB_CHOICE=fix away_gate_council_tick 4600
  gate_council_wait_exit "$dir"
  [ "$(cat "$dir/exit")" = 1 ] || fail 'escalation exit status was not recorded'
  away_gate_council_tick 4700
  case "$GATE_COUNCIL_WAKE" in *'outcome=escalate choice=fix record='*) ;; *) fail "escalation surfaced wrong: $GATE_COUNCIL_WAKE" ;; esac
  gate_council_setup
  FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'away test' >/dev/null
  printf '#!/usr/bin/env bash\nexit 2\n' > "$GATE_STUB"
  away_gate_council_tick 4600
  gate_council_wait_exit "$dir"
  away_gate_council_tick 4700
  [ "$GATE_COUNCIL_WAKE" = "check: gate council ruled: worker key=nm-r1-review outcome=error exit=2 choice=- log=$dir/log" ] \
    || fail "usage failure surfaced wrong: $GATE_COUNCIL_WAKE"
  pass 'closed gates drop their ruling, read failures keep it, escalations and failed runs surface as evidence'
}

test_gate_council_unfinished_and_bad_config() {
  local dir
  gate_council_setup
  FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'away test' >/dev/null
  printf '#!/usr/bin/env bash\nexit 0\n' > "$GATE_STUB"
  dir="$FM_HOME/data/worker/gate-council-nm-r1-review-1000"
  printf 'worker\tnm-r1-review\t1000\trunning\t4600\t%s\n' "$dir" > "$STATE/.away-gate-council-claims"
  mkdir -p "$dir"
  away_gate_council_tick 11799
  [ -z "$GATE_COUNCIL_WAKE" ] || fail 'running council surfaced before its bound'
  away_gate_council_tick 11800
  [ "$GATE_COUNCIL_WAKE" = "check: gate council ruled: worker key=nm-r1-review outcome=unfinished choice=- log=$dir/log" ] \
    || fail "unfinished council surfaced wrong: $GATE_COUNCIL_WAKE"
  gate_council_setup
  FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'away test' >/dev/null
  printf 'projects=allowed-proj\n' > "$CONFIG/gate-council"
  ! away_gate_council_tick 4600 2>/dev/null || fail 'missing roster did not fail the tick'
  printf 'roster=%s\nprojects=allowed-proj\nafter-secs=0\n' "$TMP_ROOT/roster.json" > "$CONFIG/gate-council"
  ! away_gate_council_tick 4600 2>/dev/null || fail 'invalid after-secs did not fail the tick'
  printf 'roster=%s\nprojects=allowed-proj\nafter-secs=60\nak=%s\n' "$TMP_ROOT/roster.json" "$GATE_STUB" > "$CONFIG/gate-council"
  away_gate_council_tick 1060
  grep -q $'\trunning\t' "$STATE/.away-gate-council-claims" || fail 'after-secs did not set the gate age'
  grep -q 'has waited at least 60 seconds' "$FM_HOME/data/worker/gate-council-nm-r1-review-1000/card.json" \
    || fail "card did not state the configured gate age: $(cat "$FM_HOME/data/worker/gate-council-nm-r1-review-1000/card.json")"
  pass 'an unfinished council surfaces after its bound and invalid config fails the check'
}

# A fresh status log for one findings path. The timed fold reads an
# append-only log incrementally, so a case that changes the note starts over.
gate_council_fresh_status() {  # <findings-path>
  rm -f -- "$STATE/worker.status" "$STATE"/.worker.open-decisions-cursor*
  printf 'needs-decision [at=1000] [key=nm-r1-review]: ask-user findings=F1 file=%s\n' "$1" > "$STATE/worker.status"
}

test_gate_council_refuses_findings_outside_task_data() {
  local claims="$STATE/.away-gate-council-claims"
  gate_council_setup
  FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'away test' >/dev/null
  mkdir -p "$TMP_ROOT/outside"
  printf 'x\n' > "$TMP_ROOT/outside/nm-r1-findings.txt"
  ln -s "$TMP_ROOT/outside" "$FM_HOME/data/worker/linked"
  gate_council_fresh_status "$FM_HOME/data/worker/linked/nm-r1-findings.txt"
  away_gate_council_tick 9000
  [ ! -e "$claims" ] || fail 'findings behind a symlinked folder started a council'
  rm -rf -- "$FM_HOME/data/worker"
  mkdir -p "$TMP_ROOT/outside-task"
  printf 'x\n' > "$TMP_ROOT/outside-task/nm-r1-findings.txt"
  ln -s "$TMP_ROOT/outside-task" "$FM_HOME/data/worker"
  gate_council_fresh_status "$FM_HOME/data/worker/nm-r1-findings.txt"
  away_gate_council_tick 9000
  [ ! -e "$claims" ] || fail 'findings in a symlinked task data folder started a council'
  [ ! -e "$TMP_ROOT/outside-task/gate-council-nm-r1-review-1000" ] || fail 'council run wrote outside the task data'
  rm -f -- "$FM_HOME/data/worker"
  mkdir -p "$FM_HOME/data/worker/sub"
  printf 'x\n' > "$FM_HOME/data/worker/sub/nm-r1-findings.txt"
  gate_council_fresh_status "$FM_HOME/data/worker/sub/nm-r1-findings.txt"
  away_gate_council_tick 9000
  grep -q $'\trunning\t' "$claims" || fail 'findings in a real task data subfolder did not start a council'
  gate_council_wait_exit "$FM_HOME/data/worker/gate-council-nm-r1-review-1000"
  pass 'findings whose real path leaves the task data folder never start a council'
}

test_gate_council_hold_lookup_failure_counts_as_held() {
  local claims="$STATE/.away-gate-council-claims"
  gate_council_setup
  FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'away test' >/dev/null
  mkdir "$FM_HOME/data/backlog.md"
  away_gate_council_tick 4600 2>/dev/null || true
  [ ! -e "$claims" ] || fail 'council started while the captain-hold lookup failed'
  rmdir "$FM_HOME/data/backlog.md"
  away_gate_council_tick 4600
  grep -q $'\trunning\t' "$claims" || fail 'council did not start once the hold lookup answered not held'
  gate_council_wait_exit "$FM_HOME/data/worker/gate-council-nm-r1-review-1000"
  pass 'a failed captain-hold lookup counts as held and skips the council'
}

test_gate_council_held_task_does_not_block_other_task() {
  local claims="$STATE/.away-gate-council-claims"
  if ! command -v tasks-axi >/dev/null 2>&1; then
    pass 'held task with an older gate check skipped (tasks-axi is not installed)'
    return 0
  fi
  gate_council_setup
  FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'away test' >/dev/null
  mkdir -p "$FM_HOME/data/held"
  printf 'x\n' > "$FM_HOME/data/held/nm-r1-findings.txt"
  printf 'project=/somewhere/projects/allowed-proj\nkind=ship\n' > "$STATE/held.meta"
  printf 'needs-decision [at=500] [key=nm-r1-review]: ask-user findings=F1 file=%s\n' \
    "$FM_HOME/data/held/nm-r1-findings.txt" > "$STATE/held.status"
  "$ROOT/bin/fm-captain-hold.sh" hold held --title 'Held work' --reason 'captain call' >/dev/null \
    || fail 'could not place the test task on a captain hold'
  away_gate_council_tick 4600
  ! grep -q '^held'$'\t' "$claims" 2>/dev/null || fail 'a captain-held task started a council'
  grep -q '^worker'$'\t''nm-r1-review'$'\t''1000'$'\t''running' "$claims" \
    || fail 'an older gate on a held task blocked the council for an unheld task'
  gate_council_wait_exit "$FM_HOME/data/worker/gate-council-nm-r1-review-1000"
  pass 'a held task with an older gate does not block the council for another task'
}

test_gate_council_unreadable_status_keeps_ruling() {
  local dir="$FM_HOME/data/worker/gate-council-nm-r1-review-1000" claims="$STATE/.away-gate-council-claims"
  gate_council_setup
  FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'away test' >/dev/null
  away_gate_council_tick 4600
  gate_council_wait_exit "$dir"
  chmod 000 "$STATE/worker.status"
  away_gate_council_tick 4700 2>/dev/null || true
  chmod 600 "$STATE/worker.status"
  [ -z "$GATE_COUNCIL_WAKE" ] || fail 'ruling surfaced while the status file was unreadable'
  ! grep -q $'\tgate-closed\t' "$claims" || fail 'unreadable status file recorded a closed gate'
  away_gate_council_tick 4800
  [ "$GATE_COUNCIL_WAKE" = "check: gate council ruled: worker key=nm-r1-review outcome=decline choice=decline record=$dir/record.json" ] \
    || fail "ruling was dropped after an unreadable status file: $GATE_COUNCIL_WAKE"
  pass 'an unreadable status file counts as open and keeps the ruling'
}

test_gate_council_status_read_failure_keeps_ruling() {
  local dir="$FM_HOME/data/worker/gate-council-nm-r1-review-1000" claims="$STATE/.away-gate-council-claims"
  local fail_reader="$TMP_ROOT/gate-council-failing-reader"
  printf '#!/bin/sh\nexit 1\n' > "$fail_reader"
  chmod +x "$fail_reader"
  gate_council_setup
  FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'away test' >/dev/null
  away_gate_council_tick 4600
  gate_council_wait_exit "$dir"
  rm -f "$STATE"/.worker.open-decisions-cursor*
  FM_STATUS_IDENTITY_READER="$fail_reader" away_gate_council_tick 4700 2>/dev/null || true
  [ -z "$GATE_COUNCIL_WAKE" ] || fail 'ruling surfaced while the status log identity could not be read'
  ! grep -q $'\tgate-closed\t' "$claims" || fail 'a failed status identity read with no cursor recorded a closed gate'
  printf 'not a cursor\n' > "$STATE/.worker.open-decisions-cursor.timed"
  FM_STATUS_SPAN_READER="$fail_reader" away_gate_council_tick 4750 2>/dev/null || true
  [ -z "$GATE_COUNCIL_WAKE" ] || fail 'ruling surfaced while the status log bytes could not be read'
  ! grep -q $'\tgate-closed\t' "$claims" || fail 'a failed status span read with an invalid cursor recorded a closed gate'
  away_gate_council_tick 4800
  [ "$GATE_COUNCIL_WAKE" = "check: gate council ruled: worker key=nm-r1-review outcome=decline choice=decline record=$dir/record.json" ] \
    || fail "ruling was dropped after a failed status read: $GATE_COUNCIL_WAKE"
  pass 'a status log read failure with no trusted cursor counts as open and keeps the ruling'
}

test_invalid_gate_council_config_keeps_watcher_running() {
  local dir="$TMP_ROOT/invalid-gate-council"
  mkdir -p "$dir/state" "$dir/config"
  fm_test_track_watcher_state "$dir/state"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$dir/state/worker.status"
  printf 'projects=allowed-proj\n' > "$dir/config/gate-council"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_AFK_MODE=away bash "$ROOT/bin/fm-afk-contract.sh" enter --words 'away test' >/dev/null
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_WATCH_NOW=2800 FM_WATCH_ONCE=1 FM_WEDGE_ALARM_CHANNEL=off \
    bash "$ROOT/bin/fm-watch.sh" > "$dir/out" 2> "$dir/err" \
    || fail "real watcher stopped on an invalid gate council config: $(cat "$dir/err")"
  grep -F 'gate council roster is missing or unreadable' "$dir/err" >/dev/null \
    || fail "invalid gate council config left no diagnostic: $(cat "$dir/err")"
  [ ! -e "$dir/state/.away-gate-council-claims" ] || fail 'invalid gate council config started a council'
  grep -F $'worker\tapi\t1000\t' "$dir/state/.away-decision-age-claims" | grep -F $'page-pending\t' >/dev/null \
    || fail 'invalid gate council config stopped the captain page'
  pass 'real watcher logs an invalid gate council config, skips the council, and keeps running'
}

if [ "$#" -gt 0 ]; then
  fm_test_run "$@"
  exit
fi

fm_test_run test_disabled test_oldest_and_backoff test_numeric_keys_are_distinct \
  test_numeric_tasks_are_distinct test_resolution_and_reopen \
  test_wait_exemptions test_unknown_times_and_keyless test_timed_fold_is_incremental \
  test_p0_incremental_deadlines test_p0_keyless_repeats_keep_first_opening \
  test_p0_alarm_keeps_captured_declarations test_p0_old_cursor_rebuilds_declarations \
  test_p0_keyed_note_updates_keep_first_opening test_p0_once_only_survives_endpoint_replacement \
  test_p0_marker_survives_unreadable_status test_p0_marker_survives_status_read_failure \
  test_p0_invalid_opening_time_is_explicit_and_reopens \
  test_invalid_settings test_timed_cursor_retirement test_watcher_loop \
  test_away_age_route test_away_age_page_and_staleness \
  test_away_confirmation_change_keeps_decision_open test_interrupted_claim_retries_page \
  test_missing_council_entrypoint_pages test_invalid_authority_config_still_pages \
  test_away_page_retries_after_channel_configured \
  test_gate_council_off_and_filters test_gate_council_runs_once_and_surfaces \
  test_gate_council_closed_gate_and_failure test_gate_council_unfinished_and_bad_config \
  test_gate_council_refuses_findings_outside_task_data test_gate_council_hold_lookup_failure_counts_as_held \
  test_gate_council_held_task_does_not_block_other_task \
  test_gate_council_unreadable_status_keeps_ruling test_gate_council_status_read_failure_keeps_ruling \
  test_invalid_gate_council_config_keeps_watcher_running
