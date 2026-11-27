# Local Test evidence

Revision: c1296e7b77f63453c6ebd9c3e2415e637c501c37 against 49080c0deff1b6ab4583acd6bb5024f398758307.

The seven live scenarios execute the real local Firstmate CLI in disposable marked lab homes. Inputs, state and auxiliary user configuration are isolated. No harness login, production fleet, terminal closure or upstream write was exercised. This delta changes monitoring, not finished-worker cleanup.

The final watcher observer logs public command starts and then continues the real scripts. It does not replace their output or skip their work. Start records are unique by process id. Real heartbeat and summary ledgers corroborate publication. The fixed fourfold policy and threshold above 200 are the scheduling oracle; these are correctness checks, not CPU or throughput benchmarks.

Earlier observer attempts are retained in the transcript. They were repeated after isolating HOME, fixing macOS Bash trace expansion and mixed UTF-8 decoding, replacing stderr tracing (the ticker discards stderr), and deduplicating shell-start notifications. The initial cadence window sampled before a completed poll. The initial write-failure assertion incorrectly assumed a nonzero exit; the supported command logs its inability to publish and exits zero. The final live-results.json contains the seven completed results after those setup corrections.

The real publishers sometimes report an unknown primary anchor after their three-second read bound. The ungated-repository unit assertion fails for that same reason on both base and target; those facts do not establish a change regression. The busy-lock timing assertion also fails at both revisions; direct comparison retained the old ledger and logged its deadline in every run.

Final result: all seven live scenarios passed; required targeted tests remain red. See validation-report.md and scheduling-selector-results.json. All started commands have retained exit results.
