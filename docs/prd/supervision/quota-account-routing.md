# PRD: Quota and account routing

## Purpose

This PRD defines how Firstmate moves work off a quota-limited runtime or account.
It covers detection of a quota floor, selection of an eligible replacement, and the relaunch that performs the move.
It changes no merge, release, or deploy gate and authorizes no new spend.

## Scope

- In scope: ship, scout, and secondmate workers that hit a quota floor or a usage-limit screen.
- In scope: the boundary between naming a replacement and performing the move.
- Out of scope: buying quota, raising caps, or changing account pins.
- Out of scope: dispatch of new work that has not started.
- New-work dispatch keeps its existing routing and is referenced here only where the same eligibility evidence applies.
- Escalation and quiet hours live in [escalation-quiet-hours.md](escalation-quiet-hours.md).

## Current capability

| Capability | Evidence in this repo | State |
| --- | --- | --- |
| Quota-limited workers move to another runtime | Firstmate PR #144 adds the quota runtime move | Merged |
| A deterministic helper names an eligible replacement | `bin/fm-quota-reroute.sh suggest` prints one `harness model` pair or `none` | Present |
| The helper never relaunches | The `fm-quota-reroute.sh` header states that it names a replacement and never relaunches | Present |
| An ordered candidate list resolves against one quota snapshot | `bin/fm-quota-choose.sh` picks the first eligible candidate from a captured `quota-axi` snapshot | Present |
| Claude-specific tooling blocks a move off Claude | The signal list in the `bin/fm-quota-reroute.sh` header covers MCP servers, hooks, skills, and plugin bundles | Present |
| A Claude secondmate never moves off Claude | Every firstmate home tracks `.claude/` material, so the reroute keeps a Claude secondmate on Claude | Present |
| The watchdog names a candidate and never changes the runtime | The quota rows in `docs/watchdog.md` write a ledger row and a gap that names the eligible candidate | Present |
| The supervisor performs the move | `bin/fm-control.sh relaunch --harness` runs the same eligibility check and performs the relaunch | Present |
| Dispatch reroutes at quota floors instead of stalling | Firstmate PR #94 reroutes work at quota floors | Merged |
| Allowance left is read once per heartbeat | `bin/fm-heartbeat.sh` reads weekly model allowance once under `FM_HEARTBEAT_QUOTA_TIMEOUT` | Present |

## Gaps

| Gap | Consequence |
| --- | --- |
| The worker-side helper checks one primary provider family per harness | A multi-provider harness can be judged against the wrong quota row |
| Missing quota evidence keeps a candidate eligible by design | A move can land on an account whose headroom is unmeasured |
| A pane-text usage-limit picker queues until reset while a status-line floor relaunches | Two presentations of one limit take different paths |
| The watchdog, the helper, and the control plane each read quota state separately | The three readers can disagree inside one incident |
| No record ties a move to the quota evidence that authorized it | A later audit cannot prove the move was eligible |

## Requirements

- QA-1: One quota snapshot per incident feeds detection, selection, and the relaunch check.
- QA-2: Selection names at most one replacement and records the snapshot it used.
- QA-3: A candidate with exhausted applicable runway is never selected.
- QA-4: A candidate with unmeasured headroom stays eligible and the record marks the headroom unmeasured.
- QA-5: A Claude-tooling signal blocks only the candidates off Claude and never the Claude candidates.
- QA-6: A secondmate move keeps its home, its backlog, and its recorded backend contract.
- QA-7: The move preserves the task worktree and all uncommitted work.
- QA-8: A pane-text usage-limit picker and a status-line floor follow one stated path per harness.
- QA-9: When no candidate is eligible, the task queues until reset with the reset evidence recorded.
- QA-10: The relaunch rechecks eligibility against the same snapshot before it stops the old worker.
- QA-11: A failed recheck aborts the move and leaves the old worker running.
- QA-12: Every move writes one record with the from-runtime, the to-runtime, and the snapshot reference.

## Ownership

| Signal | Single owner | Permitted action |
| --- | --- | --- |
| Quota evidence | The `quota-axi` snapshot captured at intake or at detection | Report runway only |
| Eligibility selection | `bin/fm-quota-reroute.sh suggest` | Name one candidate or `none` |
| Move execution | `bin/fm-control.sh relaunch` under supervisor instruction | Stop and relaunch the worker |
| Watchdog quota observation | `bin/fm-watchdog.sh` | Write a ledger row and name the candidate |
| Account pin | The captain through the account pin files | Change the pin |

The watchdog never performs a move.
The selection helper never performs a move.
Only the control plane moves a worker, and only under supervisor instruction.

## Acceptance tests

- AT-QA-1: An exhausted current runtime with one eligible candidate names that candidate.
- AT-QA-2: An exhausted pool names `none` and the task queues with reset evidence.
- AT-QA-3: A Claude worker with a tooling signal keeps only Claude candidates.
- AT-QA-4: A Claude secondmate is never named a non-Claude candidate.
- AT-QA-5: A stale snapshot at relaunch time aborts the move and leaves the worker running.
- AT-QA-6: A completed move records both runtimes and the snapshot reference.
- AT-QA-7: Uncommitted work in the task worktree survives the move unchanged.
- AT-QA-8: Existing suites `tests/fm-quota-choose.test.sh` and `tests/fm-procevent-quota.test.sh` still pass.

## Failure-injection and recovery drills

- DR-QA-1: Exhaust the current runtime in a fixture snapshot and confirm the move lands on the named candidate.
- DR-QA-2: Exhaust every candidate and confirm the task queues and no relaunch fires.
- DR-QA-3: Add a Claude-tooling signal mid-incident and confirm the move off Claude is refused.
- DR-QA-4: Corrupt the snapshot between selection and relaunch and confirm the move aborts safely.
- DR-QA-5: Kill the new worker during relaunch and confirm the supervisor receives one blocked record with the move record attached.

## Escalation and quiet hours

This PRD escalates only when no candidate is eligible or a move aborts.
A successful move sends no escalation.
Quiet hours and dedupe follow [escalation-quiet-hours.md](escalation-quiet-hours.md).

## Token economics

The baseline method counts supervisor wakes and model tokens before and after this work.
The measurement window is 14 consecutive days before the change and 14 consecutive days after it.
The counters are quota-related wake records per day, move records per week, and token fields in `state/watchdog/model-calls.tsv`.
Queue time is measured from the status records, not estimated.
No savings figure is stated until both windows exist.

## Open questions

- OQ-QA-1: How multi-provider harnesses prove the provider of a candidate before its quota row is read.
- OQ-QA-2: Which snapshot age is too old to authorize a relaunch recheck.
