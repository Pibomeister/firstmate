# Test-phase evidence

The monitoring runtime was driven through seven isolated local scenarios at target `01f00bd6ec89c3a8fa784e5a491087b56be75090`, compared with base `49080c0deff1b6ab4583acd6bb5024f398758307`. All seven live scenarios passed. They use synthetic homes, records, load files and timestamps. They do not claim that the operator's finished workers were closed. No live fleet endpoint or credential was changed.

`live-validation-transcript.log` contains the actual CLI results and persisted ledger observations. `scenarios.json` maps each scenario to individual evidence files. `live-monitoring.py`, `live-watcher.py` and `live-cap.py` retain the executable drivers.

## Targeted commands

| Command | Result / retained log |
| --- | --- |
| `bash tests/fm-load-throttle.test.sh` | Exit 0; `load-throttle.log` |
| `bash tests/fm-fleet-snapshot-contribution-input.test.sh` | Exit 0; `contribution-input.log` |
| `FM_TEST_ONLY=test_attended_open_work_heartbeat_floor bash tests/fm-watch-triage.test.sh` | Exit 0; `attended-cap-focused.log` |
| `bash tests/fm-fleet-snapshot-view.test.sh test_fixture_snapshot_json` | Exit 0; `snapshot-fixture-control.log` |
| `bash tests/fm-fleet-snapshot-view.test.sh` | Initial endpoint-read flake, then a crew-state-read flake; `snapshot-view.log`, `snapshot-view-repaired.log`. The second run completed the first thirteen registered cases. |
| `bash tests/fm-fleet-snapshot-view.test.sh test_completed_scout_report_is_pointer_not_pending test_parked_scout_decision_stays_pending test_scout_reports_include_teardown_reports test_backlog_tasks_axi_forms_and_overrides test_view_renders_snapshot test_view_renders_dead_secondmate_agent_status` | Exit 0; `snapshot-remaining-repaired.log`. Completes the remaining six cases after fixture repair. |
| `bash tests/fm-heartbeat.test.sh` | Exit 1 at the previously declined detached-worktree baseline case; `heartbeat.log`. Its accepted disposition was preserved. |
| `bash tests/fm-heartbeat.test.sh test_unchanged_home_collects_once_per_idle_interval test_a_change_under_load_waits_for_the_throttled_idle_due test_rearmed_ticker_anchors_due_to_last_publication test_failed_heartbeat_publications_keep_retry_interval` | Exit 0; `heartbeat-changed-scheduling.log` |
| `bash tests/fm-heartbeat.test.sh test_stale_bound_is_the_watcher_cycle_plus_the_grace test_watcher_runs_one_heartbeat_at_a_time test_watcher_poll_does_not_wait_for_heartbeat` | Freshness-bound selector passed; four-second poll observation failed; `heartbeat-bound-and-isolation.log` |
| `bash tests/fm-heartbeat.test.sh test_watcher_runs_one_heartbeat_at_a_time test_watcher_poll_does_not_wait_for_heartbeat` | Exit 0 after fixture repair; `heartbeat-isolation-repaired.log` |
| `bash tests/fm-home-summary-refresh.test.sh` | Exit 1 at cancellation lock cleanup; `home-summary.log`. Earlier publication, stateless, large-input, cadence, jitter, backoff and timer-fallback checks completed. |
| `bash tests/fm-home-summary-refresh.test.sh test_parent_cancellation` | Exit 0 on target and on the base scripts in a disposable worktree-local source fixture; `summary-cancellation-target.log`, `summary-cancellation-base.log` |
| `bash tests/fm-home-summary-refresh.test.sh test_summary_idle_pacing_follows_load test_summary_status_pacing_follows_load` | First combined run hit the clock-domain fixture defect; `summary-load-selectors.log`. Isolated status selector passed in `summary-status-diagnostic.log`. |
| `bash tests/fm-home-summary-refresh.test.sh test_summary_idle_pacing_follows_load test_summary_status_pacing_follows_load test_parent_cancellation` | Final clock-repaired result is recorded in `summary-clock-repaired.log` and `test-exits.json`. |
| `python3 <evidence>/live-monitoring.py` | Exit 0; actual heartbeat, snapshot contention/recovery, contribution and stateless CLI checks |
| `python3 <evidence>/live-watcher.py` | Real pacing checks passed. Initial retry observer counted a forked heartbeat subshell as a new launch; that observer result was discarded. |
| `python3 <evidence>/live-watcher.py retry` | Exit 0 after selecting direct watcher/ticker children only; actual process-crash retries retained the prior ledger |
| `python3 <evidence>/live-cap.py` | Exit 0; real one-poll primary watcher surfaced and persisted an open-work heartbeat under high load |

One initial triage invocation used an unsupported positional selector and was stopped (exit 143). It was replaced with the documented `FM_TEST_ONLY` invocation above. No result is inferred from that stopped run.

## Test-only repairs

- Snapshot semantic fixtures now allow nested endpoint and crew-state probes to complete on this loaded host. A focused selector interface and failure output support direct reproduction. The public state/rendering assertions remain intact.
- Heartbeat single-flight coverage observes two completed polls within wider bounded waits. Its slow snapshot remains in flight throughout those observations, which is now explicitly asserted. The eventual timeout publication is still required.
- Loaded summary fixtures seed `.last-heartbeat` in the same clock domain as `FM_WATCH_NOW`. Otherwise a real startup mtime can lie in the frozen clock's future; the product deliberately treats that as due and the attended open-work heartbeat ends the fixture. Captured `stdout: heartbeat` exposed this cause.
- Cancellation still must return the expected signal status promptly and must preserve the prior ledger. Its owned-child/lock cleanup observation now allows scheduling margin around the fixture's forced five-second process-probe delay.

No production code, agent memory, documentation, global configuration or installed package was changed. No linter, formatter, broad repository suite, pipeline-control, push, PR or CI phase was run.

The load intervals in the transcript are single local scheduling observations, not a throughput or speedup benchmark. Persisted generation stamps show actual publications; no claim is made about fleet CPU reduction. The corrected retry process observer has startup/sampling jitter, while the targeted scheduling tests check the deterministic interval policy.

## Final result

The final repaired selectors exited 0. All seven local live scenarios passed. The previously declined heartbeat baseline failure remains under its recorded disposition. All started runners were awaited, all disposable labs and the base-control source fixture were removed, and the final process/path audit found no remaining owned product process or transient fixture. See `test-exits.json` and `cleanup.json`.
