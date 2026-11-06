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
| The assistant watchdog recovers stalled supervisors | Firstmate PR #121 adds `bin/fm-watchdog.sh` as an opt-in per-machine watchdog | Merged |

## Gaps

| Gap | Consequence |
| --- | --- |
| No single health verdict combines heartbeat age, lock verdict, and watcher age | A reader checks three records and can still miss a dead home |
| A stale heartbeat and a dead lock owner surface through different paths | The same failure can raise two escalations or none |
| The outer guard proves the watcher process lives but not that the watcher still polls | A running but wedged watcher reads as healthy |
| Self-heal of the outer guard itself has no stated owner | A dead outer guard has no defined recovery path inside this repo |
| Heartbeat freshness has no stated stale threshold for the primary session | Readers apply local judgment instead of one bound |

## External dependency

An external Orca watchdog runs outside this repo.
It polls for missing AI activity on a five-minute loop and uses beacons from the m4, abaco, and gw hosts.
This PRD depends on that loop as an outer guard and does not own it.
Any requirement on that loop is a dependency to confirm with its owner, not a claim about this repo.

## Requirements

- HB-1: One health verdict per home reports `ok`, `stale`, `dead`, `unconfirmed`, or `unknown`.
- HB-2: The verdict derives only from the heartbeat age, the captain-record lock verdict, and the watcher age.
- HB-3: A heartbeat older than the stale bound reports `stale` and never `ok`.
- HB-4: A dead lock owner reports `dead` even when the last heartbeat still reads fresh.
- HB-5: An unconfirmed lock owner reports `unconfirmed` and receives no typed signal and no restart.
- HB-6: An unread heartbeat field reports `unknown` for that field and never upgrades the verdict.
- HB-7: The outer guard proves polling progress, not only process presence.
- HB-8: Loss of polling progress for two poll cycles raises one gap record and no duplicate.
- HB-9: Self-heal restarts only the failed layer and never restarts a healthy session above it.
- HB-10: Every health transition writes one durable record that a later pass can dedupe against.

## Ownership

| Signal | Single owner | Permitted action |
| --- | --- | --- |
| Heartbeat publication | `bin/fm-heartbeat.sh --write`, started by the watcher poll | Publish `state/heartbeat.json` |
| Lock liveness verdict | The shared lock contract in `bin/fm-session-lock-lib.sh`, surfaced by `state/watchdog/captain` | Report `live`, `dead`, `unconfirmed`, or `none` |
| Watcher freshness | `bin/fm-watchdog.sh` | Report one gap per home |
| Watcher process liveness | The process manager unit from `bin/fm-monitor-watchdog.sh` | Restart the watcher arm only |
| Health verdict | `bin/fm-watchdog.sh` | Record the verdict and at most one escalation |
| External poll loop | The external Orca watchdog owner | Poll and beacon only |

No second component restarts, types into, or re-arms a layer another row owns.

## Acceptance tests

- AT-HB-1: A fresh heartbeat, a live lock, and a fresh watcher produce `ok`.
- AT-HB-2: A heartbeat older than the stale bound produces `stale` with the measured age in the record.
- AT-HB-3: A dead lock pid with a fresh heartbeat produces `dead`.
- AT-HB-4: A live pid that does not match its recorded instance produces `unconfirmed` and no action.
- AT-HB-5: A missing heartbeat file produces `unknown`, not `dead`.
- AT-HB-6: Two passes over the same stale state produce one gap record.
- AT-HB-7: A watcher process that stops advancing its poll marker produces one gap after two cycles.
- AT-HB-8: Recovery of each layer returns the verdict to `ok` without a manual record edit.
- AT-HB-9: Existing suites `tests/fm-heartbeat.test.sh` and `tests/fm-watchdog.test.sh` still pass.

## Failure-injection and recovery drills

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

The baseline method counts supervisor wakes and model tokens before and after this work.
The measurement window is 14 consecutive days before the change and 14 consecutive days after it.
The counters are the wake records drained per day and the token fields in `state/watchdog/model-calls.tsv`.
A result counts only when both windows use the same counters on the same homes.
No savings figure is stated until both windows exist.

## Open questions

- OQ-HB-1: Which stale bound applies to the primary session heartbeat when open work exists.
- OQ-HB-2: Which record carries the combined health verdict so existing readers keep working.
