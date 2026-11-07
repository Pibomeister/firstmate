# PRD: Heartbeat health

## Purpose

This PRD defines how Firstmate proves that a home is alive.
It covers heartbeat freshness, session-lock freshness, dead lock owners, watcher freshness, and self-heal of the outer guard.
It changes no merge, release, or deploy gate.

## Scope

- In scope: the signals that prove a supervisor session, its watcher, and its lock are alive or dead.
- In scope: the single owner of each signal and the action that owner may take.
- Out of scope: stall recovery inside a live session.
- Out of scope: quota routing, PR checks, and implementation.
- Stall and context recovery live in [stall-context-recovery.md](stall-context-recovery.md).
- Escalation and quiet hours live in [escalation-quiet-hours.md](escalation-quiet-hours.md).

## Current capability

| Capability | Evidence in this repo | State |
| --- | --- | --- |
| The watcher publishes a fleet heartbeat ledger each poll | `bin/fm-heartbeat.sh --write` writes `state/heartbeat.json` with schema `fm-heartbeat.v1` | Present |
| Each heartbeat read has its own time bound | `FM_HEARTBEAT_READ_TIMEOUT` defaults to 3 seconds and `FM_HEARTBEAT_NM_TIMEOUT` defaults to 2 seconds | Present |
| The snapshot read is bounded at fleet scale | `FM_HEARTBEAT_SNAPSHOT_TIMEOUT` defaults to 120 seconds and `FM_HEARTBEAT_DEADLINE` defaults to 240 seconds | Present |
| Unread fields report unknown instead of guessing | The `fm-heartbeat.sh` header states that unread fields carry `{unknown:true,reason}` | Present |
| Backend endpoint probes are bounded | Firstmate PR #140 bounds backend endpoint probes so the fleet snapshot stops timing out | Merged |
| The session lock records an anchor pid and a trusted session id | `bin/fm-lock.sh` and `bin/fm-session-lock-lib.sh` own the anchor and the `state/.lock-session` sidecar | Present |
| The watchdog publishes a durable captain record | Firstmate PR #147 publishes `state/watchdog/captain` with `live`, `dead`, `unconfirmed`, and `none` verdicts | Merged |
| The watchdog detects a dead lock owner | The agent-gone row in `docs/watchdog.md` restarts only after the transcript stays quiet for `frozen-secs` | Present |
| A watcher heartbeat older than a bound is a gap | `watcher-stale-secs` defaults to 900 seconds in `docs/watchdog.md` | Present |
| An outer process manager keeps one watcher arm alive | `bin/fm-monitor-watchdog.sh` runs under launchd or systemd and owns `run`, `status`, and `manager-status` | Present |
| A home watchdog restores lost watchers | Firstmate PR #61 adds the home watchdog that restores lost watchers | Merged |
| A second mate whose endpoint vanished on restart respawns on its recorded backend | `respawn_gone_mate` in `bin/fm-secondmate-restart.sh` takes the mate through the secondmate respawn path, and `bin/fm-spawn.sh --secondmate` keeps the backend its record names; Firstmate PR #158 added it | Merged |
| The assistant watchdog recovers stalled supervisors | Firstmate PR #121 adds `bin/fm-watchdog.sh` as an opt-in per-machine watchdog | Merged |

## Gaps

| Gap | Consequence |
| --- | --- |
| No single health verdict combines heartbeat age, lock verdict, and watcher age | A reader checks three records and can still miss a dead home |
| A stale heartbeat and a dead lock owner surface through different paths | The same failure can raise two escalations or none |
| Three freshness records move at different rates and the PRD names none of them | Each reader picks a different record and a different stale verdict |
| A long supervisor turn stops the between-turn watcher without any failure | The watcher reads stale during healthy long turns |
| The outer guard can restart with no budget or backoff | A failing watcher arm can restart about once a second forever |
| Self-heal of the outer guard itself has no stated owner | A dead outer guard has no defined recovery path inside this repo |
| Restarting a dead primary has no single owner | With no restarter nothing restarts it, and with two both can launch |
| The captain record has no verdict when no lock holder is recorded | A failed successor leaves a state no reader maps to a verdict |

## External dependency

An external Orca watchdog runs outside this repo.
It polls for missing AI activity on a five-minute loop and uses beacons from the m4, abaco, and gw hosts.
This PRD depends on that loop as an outer guard and does not own it.
Any requirement on that loop is a dependency to confirm with its owner, not a claim about this repo.

## Requirements

- HB-1: One health verdict per home reports `ok`, `stale`, `dead`, `unconfirmed`, or `unknown`.
- HB-2: The verdict derives only from three named records: the heartbeat age from `generated_epoch` in `state/heartbeat.json`, the lock verdict in `state/watchdog/captain`, and the watcher age from `state/.last-watcher-beat`.
- HB-3: The heartbeat publisher computes `stale_after_secs` from the active heartbeat interval plus a grace and publishes it in `state/heartbeat.json`.
- HB-4: A heartbeat older than `stale_after_secs` reports `stale` and never `ok`.
- HB-5: The stale judgment uses the watcher supervision verdict, so a watcher that runs only between turns never reads stale during a long turn.
- HB-6: A dead lock owner reports `dead` even when the last heartbeat still reads fresh.
- HB-7: An unconfirmed lock owner reports `unconfirmed` and receives no typed signal and no restart.
- HB-8: A captain record of `none` with open work or an away record maps to `dead`.
- HB-9: An unread heartbeat field reports `unknown` for that field and never upgrades the verdict.
- HB-10: The named record `.last-heartbeat` never feeds the verdict.
- HB-11: Watcher polling progress comes from `state/.last-watcher-beat`, with the mid-turn and idle-home exemptions preserved.
- HB-12: Loss of polling progress for two poll cycles raises one gap record and no duplicate.
- HB-13: One escalation owner reads `state/.monitor-watchdog-alert` for watcher freshness and no second path pages for the same signal.
- HB-14: The outer guard restarts under a budget with backoff, and an exhausted budget writes one escalated marker and stops.
- HB-15: Each layer is checked by exactly one layer above it, and the outer guard status has one named reader.
- HB-16: Exactly one restarter owns a dead primary per home, and every restarter checks the shared restart ledger before acting.
- HB-17: Self-heal restarts only the failed layer and never restarts a healthy session above it.
- HB-18: Every health transition is reported to the escalation gate, which writes one row to the shared incident ledger that a later pass can dedupe against.
- HB-19: A heartbeat that names the lock session and is no older than the lock write updates the captain record even when a watcher or daemon wrote it.
- HB-20: Second-mate endpoint comparison runs whenever the parent record and a fresh child heartbeat both exist.

## Incident keys

| Signal | Key fields | Exception states | Routine states |
| --- | --- | --- | --- |
| Health verdict | home, verdict | `dead`, `unconfirmed` past one pass | `ok`, `stale` first pass |
| Watcher freshness | home | progress lost past two cycles | progress advancing |
| Outer guard restarts | home | budget exhausted | restart inside budget |
| Captain record | home, session | `none` with open work | `live` |

## Owner absence

The health verdict owner is `bin/fm-watchdog.sh`, which is opt-in per home.
When it does not run on a home, session start reports each uncovered signal once.
The verdict for that home reads `unknown` with the reason `watchdog absent`.
The escalation gate escalates that absence once per home, reading the shared incident ledger.
Rollout per host requires the watchdog in `act` mode with its status reader enabled.

## Ownership

| Signal | Single owner | Permitted action |
| --- | --- | --- |
| Heartbeat publication and `stale_after_secs` | `bin/fm-heartbeat.sh --write`, started by the watcher poll | Publish `state/heartbeat.json` |
| Lock liveness verdict | The shared lock contract in `bin/fm-session-lock-lib.sh`, surfaced by `state/watchdog/captain` | Report `live`, `dead`, `unconfirmed`, or `none` |
| Watcher polling liveness | `bin/fm-supervise-daemon.sh` and the process manager unit from `bin/fm-monitor-watchdog.sh` | Restart the watcher arm only |
| Watcher freshness escalation | The one reader of `state/.monitor-watchdog-alert` | Report one gap per home |
| Health verdict | `bin/fm-watchdog.sh` | Record the verdict and at most one escalation |
| Dead primary restart | The watchdog agent-gone restart in `bin/fm-watchdog.sh`, which launches the successor through `restart-command`, when `restart` is on; otherwise an external restarter under the `docs/watchdog.md` captain-record contract for a supervisor that restarts captains itself; when neither is configured, one escalation and no restart. The two restarters are never enabled together for one home, and the acting one is named in the restart ledger owner field | Restart once inside budget |
| External poll loop | The external Orca watchdog owner | Poll and beacon only |

No second component restarts, types into, or re-arms a layer another row owns.

## Acceptance tests

- AT-HB-1: A fresh heartbeat, a live lock, and a fresh watcher produce `ok`.
- AT-HB-2: A heartbeat older than its published `stale_after_secs` produces `stale` with the measured age in the record.
- AT-HB-3: A dead lock pid with a fresh heartbeat produces `dead`.
- AT-HB-4: A live pid that does not match its recorded instance produces `unconfirmed` and no action.
- AT-HB-5: A missing heartbeat file produces `unknown`, not `dead`.
- AT-HB-6: Two passes over the same stale state produce one gap record.
- AT-HB-7: A watcher process that stops advancing its poll marker produces one gap after two cycles.
- AT-HB-8: Recovery of each layer returns the verdict to `ok` without a manual record edit.
- AT-HB-9: A supervisor turn longer than the stale bound produces no stale verdict and no gap.
- AT-HB-10: A captain record of `none` with open work produces `dead`.
- AT-HB-11: Outer guard restarts stop at the budget and write one escalated marker.
- AT-HB-12: Two restarter paths armed on one dead primary produce exactly one restart.
- AT-HB-13: Existing suites `tests/fm-heartbeat.test.sh` and `tests/fm-watchdog.test.sh` still pass.

## Failure-injection and recovery drills

Every drill runs in a fixture home with a private terminal socket or a named non-default lab, never on a live home.

- DR-HB-1: Kill the lock owner process and confirm the verdict becomes `dead` and no text is typed into its endpoint.
- DR-HB-2: Freeze heartbeat publication and confirm `stale` fires once at the bound and clears on the next publish.
- DR-HB-3: Stop the watcher process and confirm the process manager restarts only the watcher arm.
- DR-HB-4: Keep the watcher process alive and block its poll step and confirm the polling-progress gap fires.
- DR-HB-5: Kill the outer guard and record which external path notices, with its measured detection time.
- DR-HB-6: Restore each layer in turn and confirm the verdict returns to `ok` with no leftover gap.

## Escalation and quiet hours

This PRD escalates only on a health-verdict transition.
A repeated pass over an unchanged verdict sends nothing.
Quiet hours and dedupe follow [escalation-quiet-hours.md](escalation-quiet-hours.md).

## Token economics

Baseline method: count supervisor session tokens from transcript usage, split into fresh input, cache reads, and output, by turn type.
The context-burn record carries the turn type for each supervisor turn.
Wake counts come from the durable wake ledger that the shared escalation design adds, never from the drained queue.
Judge spend comes from `state/watchdog/model-calls.tsv` where the watchdog runs, and reads as absent where it does not.
Counts normalize per active task-hour.
The window is 14 consecutive days before the change and 14 consecutive days after it, on the same homes.
Wake-based before-windows start only after the wake ledger exists.
No savings figure is stated until both windows exist.

## Resolution of Stage 2 findings

| Finding | Reviewer | Resolution | Section changed |
| --- | --- | --- | --- |
| A-HB-1 | A opus-5-5 | Named the three freshness records and excluded `.last-heartbeat` | HB-2, HB-10 |
| A-HB-2 | A opus-5-5 | Stale judgment uses the watcher supervision verdict with a long-turn test | HB-5, AT-HB-9 |
| A-HB-3 | A opus-5-5 | One watcher-freshness escalation owner reads the monitor alert record | HB-13, Ownership |
| A-HB-4 | A opus-5-5 | Outer guard restart budget with backoff and an escalated marker | HB-14, AT-HB-11 |
| A-HB-5 | A opus-5-5 | Each layer checked by one layer above with a named status reader | HB-15 |
| A-HB-6 | A opus-5-5 | One dead-primary restarter per home under the shared restart ledger | HB-16, Ownership |
| A-HB-7 | A opus-5-5 | Captain record `none` with open work maps to `dead` | HB-8, AT-HB-10 |
| A-HB-8 | A opus-5-5 | Token baseline rebuilt on transcript usage and the wake ledger | Token economics |
| HB-F1 | B gemini-argon | `stale_after_secs` published from the active interval and polling progress grounded in `.last-watcher-beat` | HB-3, HB-11 |
| HB-F2 | B gemini-argon | Ownership partitioned by exact signal across watchdog, daemon, and monitor | Ownership |
| HB-F3 | B gemini-argon | Token baseline measures session transcript tokens by turn type | Token economics |
| HB-F4 | B gemini-argon | Endpoint comparison runs whenever both records exist with fresh child heartbeat | HB-20 |
| HB-F5 | B gemini-argon | Heartbeat naming the lock session updates the captain record | HB-19 |

Status: FINAL. Every BLOCKING finding from both Stage 2 reviews is closed above.
