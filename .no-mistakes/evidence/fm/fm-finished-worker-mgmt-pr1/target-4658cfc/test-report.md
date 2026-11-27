# Scoped Test evidence at 4658cfcc

Seven real local CLI scenarios passed in disposable, marked lab homes with synthetic load and task state. Targeted shell checks still have unresolved failures. No tracked source or test files were changed.

## Live product behavior

- Concurrent real full snapshots refused or waited behind a stopped real holder. Cheap contribution output stayed available. Both completing snapshots released their lock.
- Both full snapshot modes returned valid JSON without creating an absent state directory.
- Real snapshot-backed heartbeat publication used the ordinary freshness bound at load 200 and extended it above 200. It suppressed a repeated hot launch, published near the due despite one second of jitter, honored the launch factor despite a calm probe, and restored the calm bound.
- A real watcher deferred an injected durable wake under load. Its next launch was 41 seconds after the prior launch for a 40-second loaded interval. The prior freshness bound covered that gap. Calm input resumed publication.
- The real home-summary producer coalesced a status update under load, published again after 50 seconds for a 32-second loaded minimum, and resumed after a calm status update. The watcher liveness beat advanced.
- A real attended watcher with a synthetic open goal and a heartbeat age of 901 seconds queued a durable heartbeat at load 300, preserving the 15-minute cap.
- An immutable file inside the disposable home rejected real atomic heartbeat publication. The prior ledger stayed intact through three collection attempts spaced 61.38 and 64.81 seconds apart for a 60-second loaded interval.

These observations prove local scheduling and CLI behavior with synthetic inputs. They do not measure fleet-wide process or CPU savings. No production fleet panes, homes, credentials, or terminal cleanup were touched.

## Remaining test failures

`tests/fm-heartbeat.test.sh test_unchanged_home_collects_once_per_idle_interval` failed its beacon sampling assertion: five observed advances across ten three-second samples, below its minimum of eight. The same fixture passed against the base revision in a separate control. This leaves a host-timing-sensitive targeted check unresolved; collection scheduling itself passed in the live watcher scenarios. The test should synchronize with completed polls while retaining its independent collection-gap assertions.

`tests/fm-fleet-snapshot-view.test.sh` stopped in `test_backlog_tasks_axi_forms_and_overrides`: the rendered task state was `unknown / none` instead of `done / status-log`. The identical case passed separately with unchanged defaults. The two remaining renderer checks also passed. This is an intermittent observation/classification result; its exact causal boundary was not established. Retain diagnostic output and stabilize that existing fixture without tuning product behavior to the case.

The full heartbeat suite also reproduced the previously declined detached-worktree timeout. That decision was respected. The existing selector passed when invoked with the supported `FM_HEARTBEAT_READ_TIMEOUT=15` setting. This failure is not raised as a new finding.

## Driver setup and teardown

The first retry scenario attempt stopped before exercising the publication failure because its driver lacked a Python import. The corrected scenario then passed. Its cleanup initially raced with late timeout-status files after its owned process groups stopped. Those transient files were removed explicitly. Final teardown and process checks are recorded separately. These were driver setup/cleanup issues, not product scenario failures.

## Completed checks and teardown

The full `tests/fm-home-summary-refresh.test.sh` suite exited 0. The new clock-controlled loaded-change selector passed; loaded home-summary selectors, re-arm anchoring, failed-publication retry spacing, watcher single-flight, slow-loop independence, poll progress, jitter, calm changes, attended wake-cap, and contribution-input checks passed. The initial full heartbeat and snapshot-view suite failures remain recorded above. The summary supervisor budget was extended while its same real child continued; after that child exited, the supervisor resumed and read its actual exit status. See summary-supervision.json.

The final scoped process audit found no driver-owned product processes. All transient homes, fixture repositories, caches, baseline copies, and selector wrappers were removed. The final worktree status is recorded in teardown.json. No tracked files changed.

## Commands and results

- Exit 0: `env FM_TEST_ONLY=test_attended_open_work_heartbeat_floor bash tests/fm-watch-triage.test.sh` — [attended-wake-cap](../attended-wake-cap.log)
- Exit 0: `bash tests/fm-heartbeat.test.sh test_a_relevant_change_collects_without_waiting_for_idle` — [calm-change](../calm-change.log)
- Exit 0: `bash tests/fm-fleet-snapshot-contribution-input.test.sh` — [contribution](../contribution.log)
- Exit 1: `python3 .test-validation/live-driver.py` — [current-live](../current-live.log)
- Exit 0: `env FM_HEARTBEAT_READ_TIMEOUT=15 bash tests/fm-heartbeat.test.sh test_worktree_off_recorded_branch_is_unknown` — [detached-selection-host-budget](../detached-selection-host-budget.log)
- Exit 0: `bash tests/fm-heartbeat.test.sh test_failed_heartbeat_publications_keep_retry_interval` — [failed-retry](../failed-retry.log)
- Exit 1: `bash tests/fm-heartbeat.test.sh` — [heartbeat-suite](../heartbeat-suite.log)
- Exit 0: `env FM_TEST_CODE_ROOT={run-worktree}/.test-validation/baseline bash tests/.validation-fm-heartbeat.sh test_unchanged_home_collects_once_per_idle_interval` — [idle-base-control](../idle-base-control.log)
- Exit 1: `bash tests/fm-heartbeat.test.sh test_unchanged_home_collects_once_per_idle_interval` — [idle-cadence](../idle-cadence.log)
- Exit 0: `bash tests/fm-heartbeat.test.sh test_jittered_idle_gaps_stay_within_the_interval` — [idle-jitter](../idle-jitter.log)
- Exit 0: `bash tests/fm-load-throttle.test.sh` — [load-throttle-suite](../load-throttle-suite.log)
- Exit 0: `bash tests/fm-heartbeat.test.sh test_a_change_under_load_waits_for_the_throttled_idle_due` — [loaded-clock](../loaded-clock.log)
- Exit 0: `bash tests/fm-heartbeat.test.sh test_rearmed_ticker_anchors_due_to_last_publication` — [rearm-anchor](../rearm-anchor.log)
- Exit 1: `python3 .test-validation/retry-live.py` — [retry-live](../retry-live.log)
- Exit 0: `bash tests/fm-heartbeat.test.sh test_watcher_publishes_every_cycle_whatever_its_loop_work` — [slow-watcher-loop](../slow-watcher-loop.log)
- Exit 0: `bash tests/.validation-fm-fleet-snapshot-view.sh test_backlog_tasks_axi_forms_and_overrides` — [snapshot-override-target-control](../snapshot-override-target-control.log)
- Exit 0: `bash tests/.validation-fm-fleet-snapshot-view.sh test_view_renders_snapshot test_view_renders_dead_secondmate_agent_status` — [snapshot-render-tail](../snapshot-render-tail.log)
- Exit 1: `bash tests/fm-fleet-snapshot-view.test.sh` — [snapshot-view-suite](../snapshot-view-suite.log)
- Exit 0: `bash tests/fm-home-summary-refresh.test.sh test_summary_idle_pacing_follows_load test_summary_status_pacing_follows_load test_snapshot_preserves_absent_state` — [summary-loaded](../summary-loaded.log)
- Exit 0: `bash tests/fm-home-summary-refresh.test.sh` — [summary-suite](../summary-suite.log)
- Exit 0: `bash tests/fm-heartbeat.test.sh test_watcher_poll_does_not_wait_for_heartbeat` — [watcher-poll-progress](../watcher-poll-progress.log)
- Exit 0: `bash tests/fm-heartbeat.test.sh test_watcher_runs_one_heartbeat_at_a_time` — [watcher-single-flight](../watcher-single-flight.log)
