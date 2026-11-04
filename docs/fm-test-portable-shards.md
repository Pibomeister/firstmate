# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

Balance hints come from serial runs of the real lanes on `ubuntu-24.04`.
The concurrent isolation proof in [fm-test-isolation-proof.md](fm-test-isolation-proof.md) establishes concurrency safety, not serial CI duration.
Local timings are not interchangeable with CI timings: platform and machine load can affect each script differently and change their relative weights.

The parallel hint table was refreshed on 2026-09-30 from five Ubuntu CI runs: [36583881812](https://github.com/kunchenguid/firstmate/actions/runs/36583881812), [36658498535](https://github.com/kunchenguid/firstmate/actions/runs/36658498535), [36663947738](https://github.com/kunchenguid/firstmate/actions/runs/36663947738), [36664663190](https://github.com/kunchenguid/firstmate/actions/runs/36664663190), and [36669175457](https://github.com/kunchenguid/firstmate/actions/runs/36669175457).
Use the slowest successful `duration_ms` per script across their uploaded portable timing artifacts and completed `FM_TEST_END` log markers.
All artifact records were cross-checked against the corresponding job's markers.
That covered all 24 parallel members at that refresh; an existing live-capability skip is a portable-runner measurement, not a timing claim for the unavailable live integration.

The serial hint table was refreshed on 2026-11-03 from the uploaded portable serial timing artifacts of four Ubuntu CI runs: [41583791860](https://github.com/Pibomeister/firstmate/actions/runs/41583791860) (all fifteen serial shards, coverage-guard red), [41572453952](https://github.com/Pibomeister/firstmate/actions/runs/41572453952), [41319546728](https://github.com/Pibomeister/firstmate/actions/runs/41319546728), and [41409020680](https://github.com/Pibomeister/firstmate/actions/runs/41409020680) (fourteen of fifteen serial shards).
It uses the slowest successful `duration_ms` per script for all 303 serial members, with the native-Windows exception below.
Observed maxima provide conservative packing weights, not an upper bound on future durations.

In the September baseline, two serial-5 jobs were cancelled at their 30-minute cap and uploaded no artifact.
Their completed log markers supplement the complete runs, but a cancelled job's wall time is only a lower bound and its unfinished or never-started scripts have no completed sample.
A failed script's duration is excluded even when its lane uploaded an artifact.
In particular, run 36664663190's serial 5 finished in 22m15s with an assertion failure, not a timeout; treating that as a healthy whole-lane sample would hide the failure.
Collect successful per-script measurements for every member before calculating a split.

The supervision-host suite is five serial members so no one file occupies a whole CI shard: `tests/fm-supervision-host-drain.test.sh` (report, dispatch, BRANCH OUTCOMES; hint 37062 ms), `tests/fm-supervision-host-hook.test.sh` (Claude Stop-hook re-arm and hand-back; hint 276183 ms), `tests/fm-supervision-host.test.sh` (host loop wakes, closes, return; hint 550000 ms), `tests/fm-supervision-host-mirror.test.sh` (dialog mirror and missing-mirror fallbacks; hint 500000 ms), and `tests/fm-supervision-host-park.test.sh` (latch, park boundary, compaction, lock ownership; hint 351454 ms).
The host and mirror hints are derived split estimates from the November 4 balance refresh below; before that split, the combined host file carried an 889727 ms hint from the 2026-11-03 refresh.
The drain, hook, and park packing weights are the slowest successful Ubuntu samples from runs [41583791860](https://github.com/Pibomeister/firstmate/actions/runs/41583791860), [41572453952](https://github.com/Pibomeister/firstmate/actions/runs/41572453952), [41319546728](https://github.com/Pibomeister/firstmate/actions/runs/41319546728), and [41409020680](https://github.com/Pibomeister/firstmate/actions/runs/41409020680).
`tests/fm-supervision-host-fork.test.sh` carries this fork's cases that upstream's split does not (cleanup ordering, lease-lock startup, Orca stale rows, attended pass-through successors, stalled-arm retirement, park readiness); its hint is the 144424 ms Ubuntu maximum from those same four runs.
The native-Windows-only `tests/fm-pi-windows-shell-invocation.test.sh` retains its separate 5121 ms measurement from 2026-09-06T21:02Z instead of a portable capability skip.
Former provisional local hints for polytoken, approval-failover, Kimi live-guard skip, tap-verify, read-repetition, Antigravity primary, worktree-cleanup, order, and watchdog-live now use Ubuntu timing-artifact maxima from the 2026-11-03 refresh.
`tests/fm-watchdog.test.sh` is 527813 ms from that refresh.
The wedge-cap suite is 356831 ms for `tests/fm-watch-wedge-cap.test.sh`, 241 ms for the live-guard skip, and 59892 ms for the unconfigured-parity suite.
`test_portable_serial_packing_budget_boundary` pins every other fixture script to 0 ms, so packing exactly at the 780000 ms budget is accepted and one millisecond above it is refused even when real serial members have no hint.
The coverage-guard test owns modeled real-hint headroom under that budget.
Do not discount a local speedup from CI packing weights.
The T3 Code backend suites carry the slowest successful Ubuntu samples from CI runs [39463576576](https://github.com/kunchenguid/firstmate/actions/runs/39463576576), [39814995718](https://github.com/kunchenguid/firstmate/actions/runs/39814995718), and [39883948163](https://github.com/kunchenguid/firstmate/actions/runs/39883948163) - 239245 ms for `tests/fm-backend-t3code.test.sh`, 57613 ms for `tests/fm-t3-mcp.test.sh`, 283 ms for `tests/fm-watch-inbox-meta.test.sh`, and the 51 ms and 52 ms live-guard skips for `tests/fm-backend-t3code-live-e2e.test.sh` and `tests/fm-backend-t3code-pr-tools-live-e2e.test.sh`.
`tests/fm-backend-t3code.test.sh` and `tests/fm-t3-mcp.test.sh` run in the portable parallel lanes, so those two values sit in `portable_parallel_weight_hints`: every case id the backend suite spawns carries a per-run suffix and its cleanup removes only the `/tmp/fm-<id>` directories that run created, and both suites passed running concurrently with each other and beside another parallel suite (see [`fm-test-isolation-proof.md`](fm-test-isolation-proof.md)).

## November 4 balance refresh

The 2026-11-04 refresh supplements the older hints with successful, non-skipped script maxima from runs [41699536822](https://github.com/Pibomeister/firstmate/actions/runs/41699536822), [41730727306](https://github.com/Pibomeister/firstmate/actions/runs/41730727306), and [41747763452](https://github.com/Pibomeister/firstmate/actions/runs/41747763452).
Failed script durations never become healthy packing measurements.
The native-Windows hint and unavailable live-capability measurements keep their previous provenance.
The last run was completely green at `cd6c5dee432476974ac00edd97b94cc13d8a2388`.
Its fifteen serial jobs took 16m56s to 19m50s, its parallel jobs took 16m58s and 20m55s, and lint took 16m28s to 23m34s (job start through completion, including setup).
Herdr took 12m02s and stock macOS Bash took 9m21s.
These are observed job durations, not queue delay or a percentile estimate.

The serial layout now packs twenty-four separate runners against a thirteen-minute script budget, leaving two minutes below the fifteen-minute healthy-job target for setup and variance.
The former 29-case host suite took 896663 ms in that green run.
Its five dialog-mirror cases now live in `tests/fm-supervision-host-mirror.test.sh`; every case and assertion is retained.
The per-case log timestamps attribute about 414 seconds to those cases and 483 seconds to the remainder, including final cleanup.
Their initial packing hints are conservatively rounded to 500000 ms and 550000 ms respectively; these are derived split estimates and must be replaced with completed script measurements.
Both portable parallel checks use three workers from the existing proven-isolated set, while their memberships remain disjoint.
Six canonical lint partitions retain every full-analysis root and the existing per-root limits.
No timeout is shortened to manufacture a faster result.

The executable coverage guard and CI matrix regression verify the new partition without dropping tests or lint roots.
The healthy-job target is not a claim about post-change hosted performance: include completed before/after run links and job durations in delivery evidence before claiming an improvement.
More jobs can increase queue delay at the account's shared runner limit.

## Recorded CI failures

[`tests/ci-flake-baseline.json`](../tests/ci-flake-baseline.json) is the tracked failure baseline for review rule rp-017.
[`bin/fm-test-flake-baseline.py`](../bin/fm-test-flake-baseline.py) owns the format and matching rules; the suite runner consults it when a script fails.
The diagnostic `FM_TEST_FAILURE` marker distinguishes a recorded signature from new evidence while preserving the failed count, nonzero exit, and required check verdict.
The runner regression covers unchanged signatures, changed sources, additional failures in the same script, and expiry.
An unchanged-source failure followed by a pass establishes intermittency, not a proven root cause or a waiver.
The focus sampler and host TERM wait still need investigation by the named owner before expiry.
The historical stock macOS cancellation was a runner-acquisition failure, with no test log; it is not a flaky-test baseline entry.
The workflow already uses Intel macOS runners for that check.

## Parallel lanes

The two parallel lanes use longest-processing-time assignment over those hints.
[`tests/fm-pi-primary-types.test.sh`](../tests/fm-pi-primary-types.test.sh) owns its typecheck dependencies independently of the lane's installed Pi runtime.
[`bin/fm-test-run.sh`](../bin/fm-test-run.sh) holds the duration values in `portable_parallel_weight_hints` and the ordered memberships and lane-specific prerequisite constraints beside `list_portable_parallel_1` and `list_portable_parallel_2`.
Read the derived packing estimates with that runner's `--check-coverage`; its header and `--help` own the output fields and the selection-specific `--list-scheduled` weight rules.
The largest individual hint sets a lower bound on the estimated duration of any split, regardless of how evenly the remaining work is assigned.
The CI cap follows the three-tier timeout policy in [Timeouts](#timeouts) below.

[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_parallel_lanes_stay_duration_balanced`, requires every parallel member to have a hint and the lane sums to differ by no more than five percent of the larger sum.
Its scheduling regressions also check stored parallel lane order and preserve serial-weight scheduling for other selections.
These checks do not detect a script outgrowing an existing hint or establish measured job headroom.
Refresh `portable_parallel_weight_hints` with the slowest completed `duration_ms` per script from several green CI runs' `fm-test-timing-portable-parallel-*` artifacts whenever the parallel set gains scripts or a member grows materially.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
[Verification inputs](#verification-inputs) owns the measurement provenance and exceptions.
A script with no hint gets the `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
`bin/fm-test-run.sh --check-coverage` reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`.
That catches missing hints, not stale existing hints: the host suite still had a 41512 ms hint after growing to over 1000 seconds in CI, so the old split placed it beside another 12 minutes of work while passing the guard.
Refresh the hints whenever a serial member grows materially or the lane gains scripts, rather than waiting for missing-hint coverage to trip.

`bin/fm-test-run.sh` owns the per-shard packing, so its `--check-coverage` output is the current account of lane size and coverage rather than a copied inventory.
Its header and `--help` own the modeled-budget check and output fields; read the current estimates from `--check-coverage` instead of retaining copied lane sums here.
[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_serial_packing_budget_boundary`, verifies acceptance exactly at the budget and refusal one millisecond above it through the executable runner.
The watch-triage suite is three serial members so no one file occupies a whole CI shard: `tests/fm-watch-triage.test.sh` (classifier, signal/turn-end absorb, wedge ladder, gone endpoints, TERM, busy-pane age, timer repair, procevent, heartbeat/afk hand-off, exit picker; hint 736368 ms), `tests/fm-watch-triage-pause.test.sh` (declared waits, captain-call holds, pause transitions, away/quiet holds, paused-until and background-job waits; hint 543517 ms), and `tests/fm-watch-triage-wedge-defer.test.sh` (wedge-threshold deferrals; hint 661765 ms).
Those packing weights are Ubuntu timing-artifact maxima from the 2026-11-03 refresh.
The estimates use per-file maxima from different runs, not measured rebalanced jobs or an end-to-end latency guarantee.
Even so, maxima from four runs do not establish a P95 or guarantee future headroom.
Job timeouts remain hang tripwires under the policy in [Timeouts](#timeouts) below; they are not the desired healthy duration.
`tests/fm-ci-workflow.test.sh` compares the parsed CI matrix to the executable runner lanes, and the runner rejects parallel `--jobs` on a serial lane even when that shard has only one member.

Refresh the CI-derived hints by downloading the per-shard timing artifacts from several green CI runs and replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`:

```sh
for run in <run-id> <run-id> <run-id>; do
  gh-axi run download "$run" -R kunchenguid/firstmate --dir "/tmp/fm-serial/$run"
done
jq -r '.scripts[] | select(.exit == 0) | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/fm-test-timing-portable-serial-*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

A timed-out shard may upload no artifact, so include a complete green run or the slowest scripts go unmeasured in exactly the shard that needs them most.
Completed shards from a partial run can supplement that complete baseline, but never treat missing tail scripts or the timeout duration as successful samples.
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable CI shards skip them.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
Its hint-coverage and modeled-budget checks are described in [Portable serial CI shards](#portable-serial-ci-shards); neither replaces inspection of actual CI timing artifacts.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Lint partitions and end-to-end latency

`bin/fm-lint.sh` owns the canonical CI partitions (CI runs six), each attempting full source-aware ShellCheck analysis and running workflow validation, backend-purity, and tmux-socket checks.
CI requires its per-root bounds, so an unenforceable deadline or address-space limit refuses lint rather than running uncapped; the script header owns the envelope, per-root execution contract, and memory fallback.
Its `--list-files` interface exposes partition membership; `tests/fm-lint.test.sh` verifies complete/disjoint executed roots, initial analysis flags, and fallback reporting.
The workflow uploads each partition's quiet telemetry plus its per-root lifecycle sidecar to distinguish analysis cost, memory use, and host contention.
No fast mode, path skips, or paid runner provisioning is part of this layout.

The longer-term performance objective remains a complete green run under fifteen minutes including start delay, but the three watch-triage members still sum to about 32 minutes of CI test time.
The immediate packing target is the runner's modeled script budget, not a claim that more shards alone can make an indivisible script faster.
The layout uses thirty-three long-lived Linux jobs (twenty-four serial, two parallel, Herdr, six lint), plus short checks and macOS; insufficient shared account capacity can erase the packing gain.
Compare complete before/after runs, preserve cancelled and partial-run evidence, and measure a representative normal-run sample before claiming a P95 improvement.
The workflow retains per-PR supersession and keeps only the newest of close main pushes' runs, without changing the compliance workflow's event semantics.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

CI job timeouts follow one three-tier policy, so the workflow reads as a policy rather than as a collection of per-job numbers.
Every tier is a hang tripwire with headroom above the healthy duration, never a packing estimate or a runtime target.
A lane that reaches its tier bound needs investigation and a distribution or runtime fix, not a larger timeout to fit the same work.

| Tier | Jobs | Bound | Rationale |
|---|---|---|---|
| Fast | coverage guard, repo invariants, timing aggregate, Full suite verdict | 5 minutes | Seconds-long local work, so the tripwire only catches a hung runner. |
| Normal | lint partitions, portable parallel shards, portable serial shards, macOS stock Bash | 30 minutes, one value shared by every job in the tier | One shared hang tripwire keeps every ordinary test and lint lane on the same policy instead of allowing per-lane packing estimates or one-off caps to set the bound. |
| Heavy | Herdr | family-run step 20 minutes under a 75-minute job-level last-resort backstop | Healthy runs finish in about 7-10 minutes, so the step tripwire fails a wedged suite while the `always()` cleanup and timing upload still run, and the job cap only catches a hang outside that step. |

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) holds the executable values and names each job's tier beside its `timeout-minutes`.
[`tests/fm-ci-workflow.test.sh`](../tests/fm-ci-workflow.test.sh) holds the policy against the parsed workflow: every job belongs to exactly one tier, the workflow carries exactly three distinct job-level values, the fast tier stays within 5-10 minutes, the normal jobs share one 30-minute budget, and the Herdr family-run step is the 20-minute tripwire below its job backstop with an `always()` teardown after it.
A passing coverage guard does not establish a healthy job duration; refresh the healthy figures above from the lanes' uploaded timing artifacts.
