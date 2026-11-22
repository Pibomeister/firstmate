# Test repair completion

Product revision: 0e4493fc18bd11d8b68649de3528c393a5ea3d31.
Only the existing uncommitted timeout-test repair remains in the source diff.

The specific failure was reproduced first by executing the pre-repair readiness functions from 8ee2414f against the task-panel regression case: refused (exit 1).
The current functions accepted it (exit 0) and refused pending input, stale frames, unanswered trust, dead agents, unknown liveness, and unsupported composers.
Replaying the actual recorded AGY background viewport from retest-background.txt independently gave pre-repair exit 1 and current exit 0.

Fresh verification: FM_TEST_SKIP_ORPHAN_REAP=1 TMPDIR=/tmp bash tests/.agy-repair-spawn.sh, exit 0, including cleanup.
The disposable runner used the declarations in tests/fm-agy-harness.test.sh and invoked only these existing tests:
- test_agy_hung_listing_is_cut_off_and_launches
- test_agy_herdr_ready_accepts_confirmed_brief_progress_and_background_tasks
- test_agy_herdr_ready_refuses_unstarted_unsubmitted_errored_and_untrusted_prompts
- test_agy_herdr_ready_refuses_stale_and_unsupported_frames
The runner is retained as repair-focused-tests.sh; its output is repair-focused-tests.log.

The timeout-test failure in retest-agy-harness.log included all spawn setup in its 20-second bound, and reported 71 seconds.
The retained repair checks the model command completion marker instead, the one-second timeout diagnostic, successful launch, and the requested model.
This tests the command timeout independently of unrelated setup latency.

Live evidence is reused from the preceding Test turn on this exact unchanged product revision, rather than claimed as newly driven live in this turn.
Checked retest-results.log, the worker and secondmate arithmetic reports, the live capture drivers, and teardown and cleanup logs.
These record completed-turn acceptance, background-task acceptance, full worker and secondmate launches, trust and idle refusal, unsent-input refusal, and returned-shell refusal.
The live background task returned wait_exit=0 with unknown native classification and a proven live AGY process.
Both arithmetic reports contained 80235; the worker report named its isolated worktree and the secondmate report named its isolated home.
The retained Herdr session teardown and fixture cleanup both exited 0, with zero owned lab processes remaining.
No new lab, browser, or server was started this turn.

The stale .test-agy-tail directory and tests/.agy-phase-final.sh and tests/.agy-phase-tail.sh probes were removed.
New disposable runners and replay files were also removed after verification.
No full repository suite, linter, formatter, static analyzer, pipeline-control, push, PR, or CI command was run.
