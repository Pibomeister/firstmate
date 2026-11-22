# AGY-on-Herdr validation

Revision: df2a91ab296a821486572759bcf283f2129a9636.
Base: 2994d3ea2d1f640ababe1c8d434f5c6fd316d832.

Fresh live execution in this turn used real AGY 1.5.14 and Herdr in named session fm-lab-agy-final-48252-32450. Every scenario used disposable project/home data. No prior turn's live result is counted as new execution.

The acceptance oracle is the author's requirement: preserve a healthy AGY pane after brief processing starts. The reported failure specifically includes an active background task below a ruled composer. Guard oracles require trust authorization, no pending input, a current viewport, and a live agent. The worker and secondmate each independently computed 12345 + 67890 = 80235 and wrote their actual working directory to their report.

Fresh results are in final-results.log. They prove worker and secondmate full spawn exit 0 with live retained endpoints; completed-tool-turn acceptance; active-background-task acceptance despite unknown native busy classification; unanswered-trust and unstarted-idle refusal; pending-input refusal with the task panel present; returned-shell refusal despite prior progress in scrollback; and real command-error composer refusal. The same live completed-worker viewport failed the base readiness predicate and passed the target. Resetting both trust authorization facts still refused that live progress viewport.

The background panel replay against 8ee2414f failed and the current target passed (final-regression-replay.log). This replay is supporting regression evidence, not itself a live scenario.

Isolation used bin/fm-herdr-lab.sh fixture create/apply/start/check, provision (which owns prepare), viewer start, run, teardown, and fixture cleanup. The viewer owns a 120-column, 40-row PTY and drains its master. A disposable HOME has a read-only link to the normal login keychain; AGY writes were sandboxed to disposable development-toolchain paths. No credential changes, login, logout, production fleet mutations, or default-session operations were performed. The helper's fleet tripwire passed at teardown. The secondmate path used unchanged copies of bin under a disposable primary home to satisfy the secondmate nesting guard.

Setup retries: the initial fresh HOME showed first-run theme/data-use setup rather than folder trust. The trust probe was rerun only after completing that local setup with interaction-data collection disabled. The worker's local first-run setup was also completed before it processed its brief. An unsupported-model attempt selected AGY's default model instead of yielding an error, so it is not counted as an error test. The actual negative error scenario submitted an unknown slash command and inspected the resulting error composer. Its transcript and readiness refusal are retained separately.

This changes readiness classification, not UI rendering. Product evidence is the real terminal viewport text, CLI launch receipts, independently written reports, and process-liveness results. No native GUI screenshot is claimed; the controlled viewer is an offscreen PTY.

No full repository suite, linter, formatter, static analyzer, pipeline-control, push, PR, or CI command was run. The focused harness suite is the existing behavior suite for the changed AGY spawn surface; no tests/fm-spawn.test.sh exists. All captured helper scripts are retained in final-drivers.

Live lab teardown and fixture cleanup both returned 0 (final-teardown.log). Final suite completion and scratch cleanup are recorded below when complete.

Final result: the existing targeted AGY harness suite completed with exit 0, including its cleanup. All fresh live scenarios passed. Both live-lab and suite fixture paths were absent and had no matching processes. git status --short was empty and HEAD remained df2a91ab296a821486572759bcf283f2129a9636. No additional source or test changes were needed.
