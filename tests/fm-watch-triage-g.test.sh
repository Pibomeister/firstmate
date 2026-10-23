#!/usr/bin/env bash
# One part of the watch-triage suite. Shared setup and cases live in
# tests/fm-watch-triage-common.sh. Every case runs in exactly one part.
set -u
# shellcheck source=tests/fm-watch-triage-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-watch-triage-common.sh"

test_wedge_threshold_defers_to_a_worker_blocker
test_wedge_threshold_worker_wait_is_off_until_armed
test_wedge_defer_refuses_a_half_filled_wait_record
test_open_captain_call_bounds_stale_churn
test_stale_churn_without_a_captain_call_still_alarms
test_failed_wake_append_does_not_arm_the_captain_hold_throttle
test_reheld_captain_call_starts_its_own_resurface_window
test_secondmate_paused_resurfaces_in_normal_mode
