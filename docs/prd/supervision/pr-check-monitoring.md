# PRD: PR and check monitoring

## Purpose

This PRD defines how Firstmate watches pull requests, checks, and merge queues without polling by hand.
It covers named-check watches, ready validation-run discovery, check-state changes, and early conflict detection.
It changes no merge, release, or deploy gate and never merges on its own authority.

## Scope

- In scope: PRs and validation runs already created by a delivery path.
- In scope: discovery of ready runs that no task owns.
- Out of scope: creating PRs, responding to validation gates, and merging.
- Those actions keep their existing owners and gates.
- Escalation and quiet hours live in [escalation-quiet-hours.md](escalation-quiet-hours.md).

## Current capability

| Capability | Evidence in this repo | State |
| --- | --- | --- |
| A named check is bound to one PR head and one trusted producer | `bin/fm-pr-check-watch.sh arm` binds the current head and an explicit numeric GitHub App ID | Present |
| The watch polls on a fixed cadence to a deadline | The watch polls every 30 seconds until stable success or a 24-hour deadline | Present |
| A forge read error ends the watch at once | The `fm-pr-check-watch.sh` header ends the watch with `condition-error` on any forge read error | Present |
| Ready validation runs are discovered on heartbeat | Firstmate PR #142 discovers ready no-mistakes PRs across every registered repo on heartbeat | Merged |
| Discovery is read-only | `bin/fm-ready-pr-discovery.sh` never merges, marks ready, responds, or changes a project | Present |
| Unreadable repos report instead of skipping silently | The discovery output carries one `ready-pr-unreadable` line per unreadable repo | Present |
| Owned and orphan runs are distinguished | Discovery flags a run `owned=no` when no task record names its branch or PR | Present |
| Merge refuses a conflicted PR | `bin/fm-pr-merge.sh` refuses when `has_conflicts` is not false or the merge state is `DIRTY` | Present |
| External PR checks bind to a head and a trusted App | Firstmate PR #47 adds the named external check watch | Merged |

## Gaps

| Gap | Consequence |
| --- | --- |
| Conflict detection runs only at merge time | A PR conflicts for hours before anyone learns of it |
| Discovery reports ready runs but no conflict state | A conflicted ready PR reads the same as a clean ready PR |
| A changed PR head rebinds a check watch only by a fresh arm | A force-push or rebase can leave a watch bound to an old head |
| Check watches and discovery run on separate cadences | One incident can surface twice through two paths |
| A queue position or gate wait has no single reporting owner | Supervisors poll the PR by hand to learn the state |

## Requirements

- PM-1: Each watch binds one PR, one head, one check name, and one trusted producer.
- PM-2: A head change ends the old binding and reports the change once.
- PM-3: A terminal check state delivers exactly one result record.
- PM-4: A forge read error ends the watch with an error record and never reads as success.
- PM-5: Discovery lists each ready run once per heartbeat with its head and wait time, and surfaces only deltas.
- PM-6: Conflict state comes from the PR read the check watch already makes, and unwatched ready PRs read through a throttled cache keyed by repository, PR, head, and base head.
- A separate conflict-cache refresher, a mode of `bin/fm-pr-check-watch.sh` that the watcher runs on its own cadence, refreshes that cache with its own time bound and a cap of K PRs per pass, oldest invalidation first, within the PM-16 per-forge budget. K is provisionally 10 PRs per refresher pass, tunable at super-bound like the churn values.
- Discovery only reads the cache and stays local-only (`bin/fm-ready-pr-discovery.sh:19-22`).
- Discovery never makes a forge read.
- PM-7: A conflicted ready PR never reports `ready`, and its conflict is reported only under the Conflict state signal, so the Ready run signal carries no `conflicted` state and points at that Conflict state incident.
- PM-8: A computing mergeable state takes one bounded settle re-read, and only a read failure reports `unknown`.
- PM-9: A base-branch advance invalidates the cached conflict state for every PR against that base.
- PM-10: An orphan run is reported with the same fields as an owned run.
- PM-11: Monitoring never merges, marks ready, responds to a gate, or pushes.
- PM-12: One PR state change produces one supervisor wake across the watch and discovery paths.
- PM-13: The incident key is the key fields the Incident keys table lists for the signal, led by home, plus the signal and the state, a conflict from either path is keyed only as Conflict state, and both paths report transitions to the escalation gate, which alone writes them to the shared incident ledger.
- PM-14: Retiring a watch with an unhandled result is refused.
- PM-15: A rate-limit response is transient, backs off to the reset time, and never ends a watch.
- PM-16: One per-forge read budget bounds all watches and discovery reads together.
- PM-17: A slow forge read for one PR marks only that PR `unknown` under its own per-PR timeout.
- PM-18: Queue and gate wait state has one reporting owner, the ready-run discovery record.

## Incident keys

| Signal | Key fields | Exception states | Routine states |
| --- | --- | --- | --- |
| Check watch | home, forge, repo, PR, head, check | terminal failure, ambiguous identity | success as expected |
| Conflict state | home, forge, repo, PR, head, base head | `conflicted` | `clean`, `computing` |
| Ready run | home, repo, PR, head | orphan past bound | ready, owned |

## Owner absence

Watch owner is `bin/fm-pr-check-watch.sh` and discovery owner is `bin/fm-ready-pr-discovery.sh`.
A rate-limit response backs off to its reset time (PM-15), and any other read error ends the watch with an error record (PM-4).
When the forge cannot be read, discovery marks the affected PR `unknown`.
No path polls the forge by hand outside its budget.

## Ownership

| Signal | Single owner | Permitted action |
| --- | --- | --- |
| Named-check watch | `bin/fm-pr-check-watch.sh` | Poll the bound check and deliver one result |
| Ready-run discovery | `bin/fm-ready-pr-discovery.sh`, consumed by `bin/fm-heartbeat.sh` | List ready runs and point a conflicted one at its Conflict state incident |
| Merge decision | The existing guarded merge path and its configured authority | Merge or refuse |
| Gate response | The validation pipeline and the supervisor gate rules | Respond to a gate |
| Conflict state | The PR read inside `bin/fm-pr-check-watch.sh`, with the throttled cache refreshed by that separate refresher for unwatched PRs | Report `conflicted`, `clean`, `computing`, or `unknown` |
| Cross-path dedupe | The escalation gate, reading the shared incident ledger | Deliver one wake per transition |

## Acceptance tests

- AT-PM-1: An armed watch delivers one result when the bound check turns terminal.
- AT-PM-2: A second suite attempt of the same check resolves to the newest attempt.
- AT-PM-3: The same check from the same producer in two suites reports ambiguous and delivers no result.
- AT-PM-4: A head change ends the binding and emits one change record.
- AT-PM-5: A forge error ends the watch with an error record.
- AT-PM-6: Discovery lists a parked ready run with its head, wait, and owned flag.
- AT-PM-7: A conflicted ready PR reports `conflicted` under the Conflict state key, and its Ready run never reports `ready`.
- AT-PM-8: An unreadable repo reports once and the remaining repos still list.
- AT-PM-9: One state change across both paths produces one wake.
- AT-PM-10: Existing suites `tests/fm-pr-check-watch.test.sh` and `tests/fm-pr-check-security.test.sh` still pass.
- AT-PM-11: With 15 (K+5) invalidated PRs, one discovery pass finishes inside its bound, and the K oldest entries refresh on the next refresher pass.

## Failure-injection and recovery drills

Every drill runs in a sandbox repository or a fixture forge, never on a live project.

- DR-PM-1: Fail the bound check and confirm one failure result and no merge attempt.
- DR-PM-2: Push a new head during a watch and confirm the old binding ends with one record.
- DR-PM-3: Make a ready PR conflict with its base and confirm the Conflict state incident reports `conflicted` before any merge attempt.
- DR-PM-4: Block the forge read for one repo and confirm the other repos still report.
- DR-PM-5: Duplicate a check across two suites and confirm the ambiguous path delivers nothing.
- DR-PM-6: Retire a watch with an unhandled result and confirm the refusal.

## Escalation and quiet hours

This PRD escalates only on a terminal failure, a conflict, or an ambiguous check identity.
A green check that matches the expectation sends no escalation.
Quiet hours and dedupe follow [escalation-quiet-hours.md](escalation-quiet-hours.md).

## Token economics

Baseline method: count supervisor session tokens from transcript usage on PR-monitoring turns, plus check-watch wake counts from the durable wake ledger.
Polling cost counts forge reads per watch per day from the watch records against the per-forge budget.
Manual PR reads count only where a record exists, and that gap is stated in the first report.
Counts normalize per active task-hour.
The window is 14 consecutive days before the change and 14 consecutive days after it, on the same homes.
No savings figure is stated until both windows exist.

## Resolution of Stage 2 findings

| Finding | Reviewer | Resolution | Section changed |
| --- | --- | --- | --- |
| A-PM-1 | A opus-5-5 | Rate limits back off to reset and one per-forge read budget bounds all readers | PM-15, PM-16 |
| A-PM-2 | A opus-5-5 | Conflict state from the watch PR read plus a throttled head-keyed cache | PM-6, Ownership |
| A-PM-3 | A opus-5-5 | Shared incident key with delta-only surfacing | PM-13 |
| A-PM-4 | A opus-5-5 | Token baseline on session transcripts and the wake ledger | Token economics |
| PM-F1 | B gemini-argon | Conflict cache with a per-PR timeout so one slow read marks one PR unknown | PM-6, PM-17 |
| PM-F2 | B gemini-argon | Computing state split from unreadable with one settle re-read | PM-8 |
| PM-F3 | B gemini-argon | One dedupe owner with durable shared state | PM-13, Ownership |
| PM-F4 | B gemini-argon | Token baseline measures check wakes and session tokens | Token economics |
| PM-F5 | B gemini-argon | Conflict cache keyed by head and base head | PM-6, PM-9 |
| F-PM-1 | FINAL opus-5-5 | Separate conflict-cache refresher named with its own bound and a cap of K (provisionally 10) PRs per pass; discovery only reads the cache and stays local-only | PM-6, Ownership, AT-PM-11 |

Status: FINAL. Every BLOCKING finding from both Stage 2 reviews and the FINAL opus-5-5 review is closed above.

## Open questions

- OQ-PM-1: Closed. The separate conflict-cache refresher carries conflict state on its own cadence, and discovery only reads the cache.
- OQ-PM-2: How a watch rebinds after a routine rebase without supervisor action.
