# Monitoring validation at d7ab247e

The nine local live scenarios passed. Scoped monitoring checks completed; the full summary suite has a baseline timing flake. This validates monitoring throttling and snapshot serialization in disposable homes. It does not claim that production workers were closed.

## Product evidence

- Real overlapping full snapshots: exit 75 with empty stdout; cheap contribution reads remain available. A waiting snapshot succeeds after the real holder resumes. Normal exits release the lock.
- At synthetic load 200 the real heartbeat published `throttled:false`; at 300 it published `throttled:true`. For a 100-second base cycle the bound changed from 571 to 871 seconds. Repeated early launches preserved the ledger bytes. A launch one second short of the loaded cycle republished. Calm load restored the ordinary bound.
- A real watcher at load 300 and a 10-second base cycle republished after a 45-second generated-epoch gap, inside the previous 511-second freshness bound. A durable wake did not start an early publication.
- Re-arm: a synthetic previous launch 60 seconds old in a 120-second loaded cycle was preserved on the immediate invocation. The next generated-epoch gap was 123 seconds, inside the published bound.
- Real summary generations advanced after the loaded idle interval. Status activity did not bypass the hot minimum. Watcher liveness advanced and calm status activity led to a new real summary.
- A filesystem-immutable ledger rejected publication. Real collection retries stayed 20.74 and 22.82 seconds apart for a 20-second loaded interval; old JSON remained intact.
- An open goal with a 901-second-old wake heartbeat queued a durable heartbeat despite load 300.
- Both `--json` and `--secondmate-home-summary` preserved an absent state directory. The previous revision e45b1314 created it in both modes; d7ab247e created it in neither.
- Three synthetic secondmate records retained endpoint-presence observations of an actual private tmux pane. The private server was stopped.

These are individual local observations, not throughput or speedup measurements. Synthetic load is supplied through the documented test seam; the product scripts and collection/publication paths are real. Fleet, forge, quota, and harness tools are absent from the live driver's tool path.

## Scenario receipts

- Concurrent full snapshots serialize; cheap reads remain available and normal exits release the lock: **pass**. `live-monitoring.txt`
- Real snapshot-backed heartbeat throttles above 200, tolerates startup jitter, and restores calm bounds: **pass**. `live-monitoring.txt`
- Real watcher defers a loaded change to the throttled due and resumes calm change-driven publication: **pass**. `live-monitoring.txt`
- Re-arming a real watcher anchors the next loaded publication to the prior ledger after its immediate launch skips: **pass**. `live-rearm-rerun.txt`
- Real home summaries coalesce synthetic status activity above load 200, keep liveness beats, and resume calm publication: **pass**. `live-secondary-rerun.txt`
- A real watcher with an open goal still queues its heartbeat within the 15-minute cap under load 300: **pass**. `live-secondary.txt`
- A real watcher retries filesystem-rejected heartbeat publications at the loaded interval without a retry storm: **pass**. `live-secondary.txt`
- A read-only full snapshot preserves a synthetic stateless home without creating operational state: **pass**. `live-boundaries.txt`
- Full snapshot reports presence of a real private tmux pane for synthetic secondmate records: **pass**. `live-boundaries.txt`

## Setup corrections

The initial re-arm observation window expired before a loaded collection finished. The re-run used a wider cycle that separates anchored scheduling from a reset interval. The first summary observer checked the next liveness beat before a long watcher iteration completed; its re-run waited for that beat. Initial shell-suite homes inside the repository triggered the intended nested-secondmate-home refusal. Normal test-owned ephemeral directories fixed that setup without product changes. A synthetic-monitoring driver's cleanup initially raced late timeout-status files; final process and directory cleanup is recorded separately.

The clean-ledger test fixture now explicitly allows a 15-second ancestry read. It still asserts a complete, error-free ledger. Its original three-second production read bound expired on this host. The modified selector passed (exit 0); no product deadline changed. The whole-run-bound tests kept their original budgets and passed.

The broader home-summary suite exited 1 at its unchanged three-second slow-stage diagnostic. It expected `task-observation`; a comparison running that existing fixture against d3d97c97 instead expired at `backlog`. The target's isolated fixture passed unchanged. This is a baseline timing flake, not evidence of a changed monitoring failure. The complete suite did not reach its later cases, so they are not claimed as passed.

The snapshot/view suite completed with exit 0 using endpoint and crew-state read budgets of 20 seconds and a registry-read budget of 10 seconds. Those fixture invocations do not change production defaults.

Completed checks: load-throttle suite; eight focused heartbeat behaviors (including the revised clean-ledger fixture and the whole stale-bound sweep); summary idle/status scheduling, jitter and failure backoff; snapshot contribution-input and snapshot/view suites; attended open-work wake cap. Exit receipts are retained in the corresponding `*-result.json` files. The full home-summary suite's exit 1 is retained and is not claimed as a pass. The initial heartbeat-bound driver limit of 240 seconds was too short for the multi-publication selector; the re-run completed in 395.48 seconds with exit 0.

All disposable process groups and the private tmux server have stopped. No surviving processes name the worktree scripts or fixture roots. Transient worktree files and generated test fixtures were removed. Only the intended change to `tests/fm-heartbeat.test.sh` remains. See `process-cleanup.json` and `test-fixture-fix.patch`.

The changed surface is CLI monitoring. JSON documents, durable wake rows and CLI transcripts are the product evidence; there is no changed rendered UI to capture.
