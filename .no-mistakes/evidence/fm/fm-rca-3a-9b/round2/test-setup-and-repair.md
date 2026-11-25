# Test setup and repair

The endpoint-safety baseline initially failed because its unrelated publisher ended after a fixed 30-second sleep. The reproduction records publisher-ready at 1795584880, publisher-exit at 1795584910, and teardown returning at 1795584910 with holder-live=no. The fixed test keeps that publisher alive while its fixture owner exists, then stops and awaits it explicitly. The expected public behavior remains unchanged: unrelated task publication must not block non-pool cleanup or lose its live lock.

A subsequent metadata-lock fixture failed because this run set TMPDIR inside the gate Git worktree. Its intentionally plain worktree directory inherited the outer Git repository; git clean then refused removal of ./ instead of exercising the intended non-repository fixture. The same selected test passed with standard /tmp toolchain isolation. The full endpoint-safety suite was restarted with that isolation. No product code was changed for either issue.

All live product scenarios used marked, disposable local homes, actual CLI commands, synthetic artifacts and wall-clock intervals. The scout launch used the real authenticated Codex executable. Its result and exit status were awaited. No external named agent was controlled.

The network nonblocking fixture originally used an elapsed 12-second sleep. It failed while unrelated local startup work took 92 seconds. The repair holds the fake probe until the digest returns, then releases it and waits for the deferred auth and relaunch results. The selected repaired case passed.

The inactive-reconciliation test still fails when run alone with its original 120-second startup and 30-second scan budgets. The deferred reader was called; its durable inactive-outcome wake was absent and the status remained working. A larger inactive budget is unsupported (the product accepts at most 30 seconds); that exploratory edit was reverted. The original inactive test remains unchanged.

Remaining startup and teardown baseline batches were stopped with SIGTERM inside the phase budget. Their actual exit statuses and exact unfinished selectors are retained. They are incomplete, not passing.
