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
| The supervisor performs the move | `bin/fm-control.sh relaunch --harness` performs the relaunch and runs the kind and Claude-tooling checks, and runs no quota check today | Present with gap |
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

- QA-2: Selection names at most one replacement and records the snapshot it used.
- QA-3: A candidate with exhausted applicable runway is never selected.
- QA-4: A mid-task move requires proven positive headroom, and a candidate with unknown status is never selected for a move.
- QA-4b: Unknown-headroom eligibility applies only at new-task intake, never to a move of running work.
- QA-5: A Claude-tooling signal blocks only the candidates off Claude and never the Claude candidates.
- QA-6: A secondmate move keeps its home, its backlog, and its recorded backend contract.
- QA-7: The move preserves the task worktree and all uncommitted work.
- QA-8: A status-line floor uses graceful stop plus relaunch, and an interactive usage-limit modal uses only a live-verified fresh-endpoint rebind or queues until reset.
- QA-9: No key is ever typed into an unverified usage-limit modal.
- QA-10: When no candidate is eligible, selection emits the earliest reset time and the task queues until that time.
- QA-11: A worker pane at a usage-limit modal produces one supervisor nudge or one bounded pause record naming the reset time.
- QA-12: The relaunch reads quota fresh past a maximum snapshot age, reselects once on a changed answer, then queues.
- QA-13: A failed fresh recheck aborts the move and leaves the old worker running.
- QA-14: Every move writes one record with the from-runtime, the to-runtime, and the snapshot reference.
- QA-15: One per-task move budget bounds moves, and no move returns to a runtime before its reset.
- QA-16: The provider of a candidate comes from the harness catalog, and an unproven provider reads as unmeasured headroom.
- QA-17: One snapshot file per incident serves detection and selection, and one separate recheck snapshot file serves each fresh recheck.
- The detection snapshot is `state/quota-incidents/<incident-key>.json`, written once by the detecting owner at detection.
- Each recheck snapshot is `state/quota-incidents/<incident-key>.<n>.json`, where `<n>` increases per recheck, and no snapshot is edited after it is written.
- The QA-14 move record references the snapshot that authorized the move, whether that snapshot is the detection snapshot or a recheck snapshot.
- Selection and the relaunch check read the snapshot named by the move record, and a fresh recheck (QA-12) writes a new recheck snapshot rather than editing any earlier snapshot.
- The heartbeat allowance read (`bin/fm-heartbeat.sh:642`) is display-only and never drives a move.
- QA-18: Dispatch rules and watchdog reroute candidates read one candidate source, and captain-approval rules keep their gate on every path.
- The candidate source is crew-dispatch resolution (`bin/fm-dispatch-resolve.sh`).
- `reroute-candidates` is read only on a home with no crew-dispatch configuration, and never moves a task whose rule carries `approval: "captain"`.
- QA-19: A quota-limited primary raises one exception that names the reset time and the pin decision, and no automated move touches it.
- QA-20: Every move is a relaunch under SC-19, checks the per-subject restart budget first, and writes one `restart` row to the shared restart ledger that counts against that budget.

## Incident keys

| Signal | Key fields | Exception states | Routine states |
| --- | --- | --- | --- |
| Quota floor | home, task, runtime | all candidates at floor | candidate named |
| Move | home, task, from-runtime, to-runtime | recheck failed, budget exhausted | move completed |
| Primary at floor | home | at floor past one pass | reset reached |

## Owner absence

Selection owner is `bin/fm-quota-reroute.sh` and move execution owner is `bin/fm-control.sh relaunch`.
When quota evidence cannot be read, selection names `none` with the reason recorded.
No path guesses headroom from a harness or model name.

## Ownership

| Signal | Single owner | Permitted action |
| --- | --- | --- |
| Quota evidence | The `quota-axi` snapshot captured at detection | Report runway only |
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
- AT-QA-5: A snapshot past the maximum age at relaunch time triggers one fresh read, and a failed fresh recheck aborts the move and leaves the worker running.
- AT-QA-6: A completed move records both runtimes and the snapshot reference.
- AT-QA-7: Uncommitted work in the task worktree survives the move unchanged.
- AT-QA-8: Existing suites `tests/fm-quota-choose.test.sh` and `tests/fm-procevent-quota.test.sh` still pass.

## Failure-injection and recovery drills

Every drill runs in a fixture home with a private terminal socket or a named non-default lab, never on a live home.

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

Baseline method: count supervisor session tokens from transcript usage on dispatch and quota-relaunch turns.
Move cost counts the startup tokens of the new worker from the per-session token ledger.
Move counts and queue time come from move records and status records, never from an estimate.
Counts normalize per active task-hour.
The window is 14 consecutive days before the change and 14 consecutive days after it, on the same homes.
No savings figure is stated until both windows exist.

## Resolution of Stage 2 findings

| Finding | Reviewer | Resolution | Section changed |
| --- | --- | --- | --- |
| A-QA-1 | A opus-5-5 | Per-task move budget with no return before reset | QA-15 |
| A-QA-2 | A opus-5-5 | Capability corrected and fresh recheck with one reselect then queue | QA-12, QA-13 |
| A-QA-3 | A opus-5-5 | Provider from the harness catalog, never inferred from a name | QA-16 |
| A-QA-4 | A opus-5-5 | One snapshot file per incident referenced by every step | QA-17 |
| A-QA-5 | A opus-5-5 | Quota-limited primary exception with reset time and pin decision | QA-19 |
| A-QA-8 | A opus-5-5 | Token baseline counts move cost from the session token ledger | Token economics |
| QA-F1 | B gemini-argon | Mid-task moves require proven positive headroom | QA-4, QA-4b |
| QA-F2 | B gemini-argon | Modal path split with no key into an unverified modal | QA-8, QA-9 |
| QA-F3 | B gemini-argon | Earliest reset emitted and worker modal panes nudged once | QA-10, QA-11 |
| QA-F4 | B gemini-argon | One candidate source for dispatch and watchdog paths | QA-18 |
| QA-F5 | B gemini-argon | Token baseline measures dispatch and relaunch session turns | Token economics |
| F-QA-1 | FINAL opus-5-5 | Crew-dispatch resolution named as the candidate source with `reroute-candidates` only as a fallback that never moves a captain-approval task; snapshot at `state/quota-incidents/<key>.json` written at detection; heartbeat allowance display-only | QA-17, QA-18, Ownership |

Status: FINAL. Every BLOCKING finding from both Stage 2 reviews and the FINAL opus-5-5 review is closed above.

## Open questions

- OQ-QA-1: Which maximum snapshot age fits each provider reset cadence.
- OQ-QA-2: Which snapshot age is too old to authorize a relaunch recheck.
