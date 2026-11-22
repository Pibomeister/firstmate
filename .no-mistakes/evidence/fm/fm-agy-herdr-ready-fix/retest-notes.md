# AGY-on-Herdr readiness validation

Product revision: 0e4493fc18bd11d8b68649de3528c393a5ea3d31.
Base: 2994d3ea2d1f640ababe1c8d434f5c6fd316d832.
Date: 2026-11-22.
Real tools: AGY 1.5.14, Herdr 0.8.2, and Treehouse on macOS.

## Live oracle and results

The requested contract is to keep a healthy AGY pane when it has begun processing its brief.
A completed tool turn and an active background task must count, while unanswered trust, unsent input, unstarted prompts, and stale shell scrollback must not count.

The disposable named session was fm-lab-agy-retest-42269-29308.
Herdr lifecycle used bin/fm-herdr-lab.sh fixture create/apply/start/check, provision (which owns prepare), viewer start, run, teardown, and fixture cleanup.
The viewer provided a 120-column, 40-row PTY and drained its master.
The current readiness functions were executed with the real backend, visible capture, native busy classifier, and process-liveness reader; none of those interfaces was mocked.
Full launches used FM_AGY_READY_POLLS=240 and FM_AGY_POLL_INTERVAL=0.5 to allow cold startup.
The settled progress/background/negative probes used a single readiness poll; the initial trust-answer loop used eight polls.

- Actual folder-trust dialog: predicate exit 1; wait loop answered it once; an unstarted idle composer still returned 1.
- Actual completed terminal/edit turn: report contained the independently computed sum 80235; wait exit 0 and agent alive.
- Actual background terminal task: the pane displayed sleep 180, an empty composer, an intervening task panel, and the current shortcuts footer with 1 task(s) · /tasks; wait exit 0 while native classification was unknown agy-regex and agent was alive.
- Actual unsent progress-like composer text: wait exit 1, including while the background task panel was present.
- After /quit returned to a real shell with the old AGY output retained: wait exit 1 and agent dead.
- On the same live completed-worker viewport, the base predicate returned 1 and the target predicate returned 0.
- The live progress pane still returned 1 when neither pre-registration nor an observed trust answer authorized readiness.
- Full fm-spawn worker launch exited 0, produced WORKER_RECEIVED with 80235 and its actual isolated worktree, and kept a live endpoint.
- Full fm-spawn secondmate launch exited 0, produced SECOND_MATE_RECEIVED with 80235 and its actual isolated home, and kept a live endpoint.

## Isolation and setup retries

The normal login keychain was used read-only through a disposable HOME symlink; no sign-in, sign-out, or credential-store mutation occurred.
AGY ran under sandbox-exec with writes restricted to the disposable tree and test temporary paths.
The worker launch was repeated with HOME explicitly pinned at the CLI wrapper, because Herdr's shell retained its server's HOME; the write sandbox refused out-of-tree writes during that first launch.
Only the isolated repeat is used as the final worker evidence.
The initial lab attempt ended with its command process group and was restarted under a retained driver until explicit teardown.
An initial separate prepare call was redundant because provision owns prepare; guarded teardown cleared that owned tripwire before provision.
Secondmate setup first hit the nested-code-root guard and then the missing-AGENTS home guard.
The successful retry used an unchanged copy of bin under the disposable primary home, a sibling disposable secondmate home, and an unchanged copy of the repository's AGENTS.md as fixture data.
No supervisor, fleet, default Herdr session, or production project state was changed.
The firstmate-home fixture warnings about sync and agent-kit declarations do not participate in readiness.

## Targeted tests and repair

The colocated behavior suite is tests/fm-agy-harness.test.sh; no tests/fm-spawn.test.sh exists.
No full repository suite, linter, formatter, static analyzer, pipeline-control, push, PR, or CI command was run.
An initial suite attempt was stopped during stale-fixture sweeping, then restarted with FM_TEST_SKIP_ORPHAN_REAP=1.
The restarted suite passed its prefix but failed the existing whole-spawn wall-clock assertion in test_agy_hung_listing_is_cut_off_and_launches (71 seconds against 20).
That assertion included unrelated spawn setup.
Process inspection during the remaining suite showed `git check-ref-format --branch fm/agy-failure-backlog-63041` waiting on `/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -license check`.
The system toolchain and license state were left unchanged.
Only this test was repaired: it now checks the existing fake model process's completion marker is absent, still checks the one-second timeout notice, and still requires successful launch with the requested model.
A missing timeout would let the fake command finish and write the marker, so this rejects the intended wrong behavior without measuring unrelated work.
The neighboring zero-timeout test already uses the same lifecycle oracle.
The repaired hung-listing case and all remaining original suite entries are run in tests/.agy-phase-tail.sh, generated from the suite's declarations and original invocation list starting at that case.
The original prefix log is retest-agy-harness.log; the remaining-case log is retest-agy-tail.log.
That remaining-case run passed through the missing-binary case, then hit the secondmate nested-home guard because its TMPDIR was inside the repository.
The secondmate case and all subsequent original entries are rerun with TMPDIR=/tmp in tests/.agy-phase-final.sh; this is disposable development-toolchain temporary state.
Their log is retest-agy-final.log.
The final driver is also retained in retest-drivers.
No product code changed after the live checks.

## Evidence and cleanup

retest-results.log records live gate return codes, native states, endpoint identities, and report checks.
retest-background.txt and retest-completed-turn.txt preserve the actual viewport text with the account identifier redacted.
retest-worker-isolated-report.md and retest-secondmate-report.md preserve the independent reports.
retest-unsubmitted.txt, retest-returned-shell.txt, retest-scrollback.txt, and retest-trust-dialog.txt preserve the adversarial surfaces.
This change affects readiness classification, not rendering; terminal viewport transcripts are the product evidence, with no screenshot claim.
retest-teardown.log records guarded session teardown exit 0 and fixture cleanup exit 0.
retest-cleanup.log confirms the fixture was absent, no owned lab processes remained, and the transient lab tree was removed.
The focused drivers are retained in retest-drivers; setup and retry details remain visible rather than being hidden from the evidence.
