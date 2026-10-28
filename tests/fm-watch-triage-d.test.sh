#!/usr/bin/env bash
# One part of the watch-triage suite. Shared setup and cases live in
# tests/fm-watch-triage-common.sh. Every case runs in exactly one part.
set -u
# shellcheck source=tests/fm-watch-triage-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-watch-triage-common.sh"

test_external_pr_check_pause_requires_watch() {
  local dir state fakebin out capture_file window sig pid
  dir=$(make_case external-pr-check-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-check-pause"
  printf 'idle awaiting external check\n' > "$capture_file"
  printf 'window=%s\nkind=ship\npr=https://github.com/acme/widget/pull/7\n' "$window" > "$state/check-pause.meta"
  printf 'paused: awaiting PR check Build\n' > "$state/check-pause.status"
  sig=$(seen_sig "$state/check-pause.status"); printf '%s' "$sig" > "$state/.seen-check-pause_status"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_ONCE=1 FM_WATCH_NOW="$(watch_clock_now)" "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail 'external-check pause watcher cycle did not finish'
  assert_grep 'PR check pause has no registered watch' "$state/.wake-queue" 'free-text external check pause warns immediately'
  unset FM_FAKE_CREW_STATE
  pass 'a paused external PR check without a watch wakes supervision'
}

test_external_pr_check_reference_states() {
  local dir state fakebin out capture_file window sig pid ref arm status mismatch_line before after
  dir=$(make_case external-pr-check-reference); state="$dir/state"; fakebin="$dir/fakebin"
  fm_test_track_procevent_home "$dir"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-check-reference"
  printf 'idle awaiting external check\n' > "$capture_file"
  printf 'window=%s\nkind=ship\npr=https://github.com/acme/widget/pull/7\npr_head=0123456789abcdef0123456789abcdef01234567\n' "$window" > "$state/check-reference.meta"
  chmod 0600 "$state/check-reference.meta"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'/repos/acme/widget/pulls/7'*) printf '%s\n' 0123456789abcdef0123456789abcdef01234567 ;;
  *'/check-runs'*) printf '%s\n' pending ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/gh-axi"
  arm=$(PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    "$ROOT/bin/fm-pr-check-watch.sh" arm check-reference https://github.com/acme/widget/pull/7 Build --producer-app 42) \
    || fail 'private named-check watch must arm'
  ref=$(printf '%s\n' "$arm" | sed -n 's/^watch_ref=//p')
  [ -n "$ref" ] || fail 'arm must supply a watch reference'
  printf 'paused: external PR check Build check-watch=%s head=0123456789abcdef0123456789abcdef01234567 producer=app:42\n' "$ref" > "$state/check-reference.status"
  sig=$(seen_sig "$state/check-reference.status"); printf '%s' "$sig" > "$state/.seen-check-reference_status"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_ONCE=1 FM_WATCH_NOW="$(watch_clock_now)" "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail 'live reference watcher cycle did not finish'
  if [ -f "$state/.wake-queue" ] && grep -q 'PR check pause has no' "$state/.wake-queue"; then
    fail 'a matching live watch must cover its worker pause'
  fi
  status=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-pr-check-watch.sh" status "$ref") || fail 'watch status must remain readable'
  assert_contains "$status" 'state=live' 'private fixture has a live registration'

  printf 'paused: external PR check Other check-watch=%s head=0123456789abcdef0123456789abcdef01234567 producer=app:42\n' "$ref" > "$state/check-reference.status"
  sig=$(seen_sig "$state/check-reference.status"); printf '%s' "$sig" > "$state/.seen-check-reference_status"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_ONCE=1 FM_WATCH_NOW="$(watch_clock_now)" "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail 'other-check reference watcher cycle did not finish'
  assert_grep 'no matching live or unhandled watch' "$state/.wake-queue" 'reference for another check must not cover the pause'
  ack_stopped_cycle "$state" >/dev/null || fail 'other-check wake must be acknowledged before the next cycle'
  for mismatch_line in \
    "Build check-watch=$ref head=fedcba9876543210fedcba9876543210fedcba98 producer=app:42" \
    "Build check-watch=$ref head=0123456789abcdef0123456789abcdef01234567 producer=app:99"; do
    before=$(grep -c 'no matching live or unhandled watch' "$state/.wake-queue" || true)
    printf 'paused: external PR check %s\n' "$mismatch_line" > "$state/check-reference.status"
    sig=$(seen_sig "$state/check-reference.status"); printf '%s' "$sig" > "$state/.seen-check-reference_status"
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_ONCE=1 FM_WATCH_NOW="$(watch_clock_now)" "$WATCH" > "$out" &
    pid=$!
    wait_for_exit "$pid" 100 || fail 'mismatched identity watcher cycle did not finish'
    after=$(grep -c 'no matching live or unhandled watch' "$state/.wake-queue" || true)
    [ "$after" -gt "$before" ] || fail "another head or producer must not cover the pause (before=$before after=$after output=$(cat "$out"))"
    ack_stopped_cycle "$state" >/dev/null || fail 'identity-mismatch wake must be acknowledged before the next cycle'
  done
  printf 'paused: external PR check Build check-watch=%s head=0123456789abcdef0123456789abcdef01234567 producer=app:42\n' "$ref" > "$state/check-reference.status"
  sig=$(seen_sig "$state/check-reference.status"); printf '%s' "$sig" > "$state/.seen-check-reference_status"
  prior_warnings=$(grep -c 'no matching live or unhandled watch' "$state/.wake-queue" || true)

  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-procevent-when.sh" retire "${ref#when-}" >/dev/null \
    || fail 'private fixture must retire its listener before fabricating a captured result'
  mv "$state/procevent" "$dir/suppressed-procevent"
  mkdir -p "$state/procevent-inbox"
  printf 'captured fixture result\n' > "$state/procevent-inbox/$ref.1.result"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_ONCE=1 FM_WATCH_NOW="$(watch_clock_now)" "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail 'unhandled-result watcher cycle did not finish'
  warning_count=$(grep -c 'no matching live or unhandled watch' "$state/.wake-queue" || true)
  if [ "$warning_count" -gt "$prior_warnings" ]; then
    fail 'a matching unhandled terminal result must cover its worker pause'
  fi

  : > "$state/procevent-inbox/$ref.1.handled"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_ONCE=1 FM_WATCH_NOW="$(watch_clock_now)" "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail 'ended-reference watcher cycle did not finish'
  assert_grep 'no matching live or unhandled watch' "$state/.wake-queue" 'handled result no longer covers the pause'
  ack_stopped_cycle "$state" >/dev/null || fail 'ended-reference wake must be acknowledged before the next cycle'
  before=$(grep -c 'no matching live or unhandled watch' "$state/.wake-queue" || true)
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_ONCE=1 FM_WATCH_NOW="$(watch_clock_now)" "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail 'identical ended-reference watcher cycle did not finish'
  after=$(grep -c 'no matching live or unhandled watch' "$state/.wake-queue" || true)
  [ "$after" -eq "$before" ] || fail 'an unchanged bad pause must not warn on every watcher cycle'
  printf 'paused: no-mistakes PR check monitor\n' > "$state/check-reference.status"
  sig=$(seen_sig "$state/check-reference.status"); printf '%s' "$sig" > "$state/.seen-check-reference_status"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_ONCE=1 FM_WATCH_NOW="$(watch_clock_now)" "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail 'no-mistakes own-wait watcher cycle did not finish'
  after=$(grep -c 'no matching live or unhandled watch' "$state/.wake-queue" || true)
  [ "$after" -eq "$before" ] || fail 'worker-owned no-mistakes wait must not require an external check watch'
  unset FM_FAKE_CREW_STATE
  pass 'live and unhandled references cover; mismatches warn once; no-mistakes stays separate'
}

test_external_pr_check_pause_requires_watch
test_external_pr_check_reference_states
if [ "${FM_TEST_ONLY_EXTERNAL_PR_CHECK:-}" = 1 ]; then exit 0; fi
test_secondmate_captain_held_resurfaces_in_normal_mode
test_secondmate_nonpaused_stale_remains_suppressed
test_secondmate_unpause_clears_pause_tracking
test_nonterminal_stale_pause_transitions_reclassify_unchanged_hash
test_nonterminal_paused_rechecks_authoritative_state
test_paused_authoritative_working_preserves_wedge_timer
test_nonterminal_stale_repairs_missing_or_corrupt_timer
test_wedge_escalation_deferred_while_worktree_is_written
test_write_deferral_resurfaces_on_the_bounded_cadence
test_secondmate_home_supervision_churn_is_not_write_evidence
test_timer_repair_drops_a_finished_write_deferral_chain
test_terminal_first_sight_drops_a_finished_write_deferral_chain
test_triage_log_size_cap_accepts_spaced_wc_counts
test_procevent_captured_result_surfaces_proactively
test_procevent_unacknowledged_result_redrains_until_handled
test_procevent_marker_keys_are_injective
test_procevent_headlines_classify_queue_keys
test_procevent_launch_failed_episodes_are_each_delivered
test_procevent_surface_serializes_with_drain
test_procevent_surface_crash_boundaries
test_procevent_marker_failure_exits_and_replays
test_heartbeat_no_change_absorbed
test_heartbeat_backstop_surfaces_unsurfaced_status
test_heartbeat_backstop_surfaces_a_masked_status
test_beacon_stays_fresh_while_absorbing
test_afk_signal_records_heartbeat_endpoint
test_afk_present_reverts_watcher_to_one_shot
test_afk_paused_changed_pane_hands_off_plain_stale
test_afk_declared_pause_on_an_ask_user_gate_is_handed_off_as_a_gate
test_afk_declared_pause_on_a_worker_gate_rings_only_the_worker
test_afk_declared_pause_on_an_executing_run_stays_handed_off_once
test_afk_parked_gate_read_is_bounded_when_no_mistakes_hangs
test_afk_parked_gate_read_goes_to_the_pane_read_least_recently
test_captain_held_never_rechecked_while_away_record_exists
test_live_captain_held_first_sight_silenced_by_away_record
test_backlog_hold_never_rechecked_while_away_record_exists
test_afk_one_shot_never_hands_off_captain_held_under_away_record
test_captain_held_rechecked_under_a_quiet_record
test_paused_until_near_future_is_quiet_before_the_cadence
test_paused_until_wrong_year_is_bounded_by_the_cadence
test_paused_until_that_passed_is_rechecked_before_the_cadence
test_firstmate_park_absorbs_a_quiet_pane_until_its_time
test_paused_bg_job_without_until_stays_silent_after_the_job_ends
test_paused_bg_job_until_timeout_rechecks_after_the_job_ends
test_exit_picker_stale_names_the_dialog
test_exit_picker_wedge_keeps_climbing
test_quoted_exit_picker_stays_ordinary_stale
test_secondmate_exit_picker_stays_quiet
test_closed_exit_picker_drops_saved_dialog_name
