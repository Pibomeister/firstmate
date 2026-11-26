# Test-phase result

Target: e45b13147a8c7b91c3ef18409ea8f00283fd88fb, with test-only fixture fixes in the retained patch.
Verdict: no-go.

The real read-only snapshot creates state/ in a synthetic home that has no state directory. The base revision does not. The existing home-summary suite fails on the same contract. See live-boundaries.txt and stateless-{base,target}.json. No product repair was made.

Real local commands passed snapshot serialization/release, heartbeat load threshold and freshness-bound transitions, loaded change coalescing, re-arm anchoring, real home-summary publication, the attended open-goal wake cap, and failed-publication retry pacing. The private tmux pane and all disposable homes were stopped and removed. The CLI transcripts and generated JSON are the runtime evidence; mocked test fixtures were supplemental only.

The first summary driver reached its behavioral assertions but hit a process-group cleanup error. Its subsequent removal raced a finishing child. After cleanup, the summary check was rerun successfully with corrected driver shutdown; live-summary-rerun.txt is the final result. The original log is retained in live-secondary.txt.

Test-only changes: endpoint-rendering fixtures use a 20-second probe budget instead of depending on production's two-second deadline under host load. The re-arm fixture now uses a 40-second loaded cycle and a 25-second observation window. It passes current code and fails a temporary executable variant that disables the prior-publication anchor.

Checks:
- bash tests/fm-load-throttle.test.sh: exit 0.
- bash tests/fm-fleet-snapshot-contribution-input.test.sh: exit 0.
- bash tests/fm-fleet-snapshot-view.test.sh: initially failed endpoint rendering; both affected renderer functions passed after the test-only fix via driver-snapshot-fixed.test.sh.
- bash tests/fm-heartbeat.test.sh: stopped on the slow-snapshot wall-clock assertion (19s against a <8s bound); the same selector failed on base at 8s. Focused single-flight, loaded-change, retry, stale-bound, and corrected re-arm cases passed. The re-arm negative control failed as intended.
- bash tests/fm-home-summary-refresh.test.sh: stopped on the stateless-home regression. Both loaded idle/status pacing selectors passed separately.
- bash tests/fm-watch-triage.test.sh: stopped on the expired Pi stream inspection timer; the same selector fails on base. The attended open-work heartbeat selector passed separately.

No linters, formatters, full repository suite, push, PR, or pipeline control phases were run. No operator fleet or primary checkout was used.
