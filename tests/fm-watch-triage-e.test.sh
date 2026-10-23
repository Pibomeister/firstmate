#!/usr/bin/env bash
# One part of the watch-triage suite. Shared setup and cases live in
# tests/fm-watch-triage-common.sh. Every case runs in exactly one part.
set -u
# shellcheck source=tests/fm-watch-triage-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-watch-triage-common.sh"

test_busy_pane_default_turn_age_bound_is_3600s
test_busy_declared_pause_is_rechecked_not_wedge_escalated
test_afk_busy_declared_pause_hands_off_plain_stale
test_afk_busy_declared_pause_ticking_pane_hands_off_once
test_nonterminal_stale_not_working_surfaced
test_nonterminal_stale_paused_absorbed_then_resurfaced
test_exited_declared_pause_is_bounded_but_live_gate_surfaces
test_own_work_wait_keeps_first_alert_then_long_cadence
test_absorbed_replacement_wait_does_not_inherit_the_old_throttle
