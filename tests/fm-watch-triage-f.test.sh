#!/usr/bin/env bash
# One part of the watch-triage suite. Shared setup and cases live in
# tests/fm-watch-triage-common.sh. Every case runs in exactly one part.
set -u
# shellcheck source=tests/fm-watch-triage-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-watch-triage-common.sh"

test_live_declared_wait_churn_honors_the_resurface_throttle
test_live_paused_until_controls_recheck_time
test_wedge_threshold_defers_to_a_declared_wait_under_a_working_verdict
test_wedge_threshold_keeps_a_wait_past_a_default_key_answer
test_wedge_threshold_recheck_names_the_captain_for_a_held_lane
test_wedge_threshold_defers_to_a_backlog_captain_hold
test_wedge_threshold_defers_to_a_parked_gate_awaiting_a_human
test_wedge_threshold_parked_gate_needs_an_unanswered_decision
test_wedge_threshold_parked_gate_is_off_until_armed
