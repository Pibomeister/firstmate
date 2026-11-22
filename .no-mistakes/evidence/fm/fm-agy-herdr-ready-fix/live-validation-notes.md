# AGY readiness live validation

Target: 8ee2414f87dd2be3f059e080e5aedc5664a5b391. Base: 2994d3ea2d1f640ababe1c8d434f5c6fd316d832.

Real AGY 1.5.14 used the existing login, a disposable HOME, and a write sandbox. The synthetic profile had onboarding marked complete. Live probes executed the target readiness functions with the real backend and busy libraries. No CLI, capture, native status, or process view was mocked. Separate full spawn checks received worker and secondmate arithmetic reports. The secondmate test used a disposable copy of the unchanged bin directory to keep the separate-home topology inside the worktree.

Herdr lifecycle used bin/fm-herdr-lab.sh fixture create/apply/start, provision, viewer start, run, teardown, and fixture cleanup. Final named session: fm-lab-agy-final-92164-28357. The viewer had a 120-column by 40-row PTY. All lab and browser children were stopped.

Default startup windows timed out during two full spawn attempts. Retrying with FM_AGY_READY_POLLS=180 and FM_AGY_POLL_INTERVAL=0.5 completed both checks. Reports contain the independent arithmetic result 80235. The worker report also names its actual isolated worktree.

The oracle is the requested behavior: accept healthy AGY after brief processing or while a background task runs; refuse an unstarted prompt, unsent input, unanswered trust dialog, or returned shell. On the same live completed-tool-turn capture, the base predicate returned 1 and target returned 0. On the active background-task capture, target returned 1 while the agent was alive and the footer displayed 1 task(s) · /tasks. The real task panel adds rows between the composer and footer, which the fixed four-row layout condition rejects before checking the task count.

The HTML retains the failed terminal capture with the account identifier redacted. Chrome screenshot capture was blocked because chrome-devtools-axi could not start its bridge within 30 seconds; its isolated session was stopped. No product or test source was changed.
