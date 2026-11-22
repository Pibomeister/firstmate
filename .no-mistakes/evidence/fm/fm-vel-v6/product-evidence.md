# Local watchdog product evidence

The real watchdog ran against disposable homes and synthetic task records. Pages went to a local command channel. No production fleet or forge was exercised.

## Input page

Captured output: `input-aged-pages.txt`

```text
Firstmate watchdog: input has 1 unhandled inputs, the oldest 16 minutes old, while 1 tasks are in flight. Its supervisor is not handling them, whatever its process or heartbeat shows. The watchdog restarted nothing. Check the supervisor terminal; the captain record is {run-worktree}/.stall-validation-lab/input/state/watchdog/captain and the ledger is {run-worktree}/.stall-validation-lab/input/state/watchdog/actions.tsv.

```

## Delivered PR page

Captured output: `pr-delivered-pages.txt`

```text
Firstmate watchdog: 1 ready PRs on pr have waited up to 16 minutes without landing under standing authority: https://github.com/synthetic/repo/pull/7. The watchdog landed and restarted nothing. Check the supervisor terminal; the ledger is {run-worktree}/.stall-validation-lab/pr/state/watchdog/actions.tsv.

```

## Captain hold status

Captured output: `held-owner-wait-status.md`

```text
# Firstmate watchdog - Eduardos-MacBook-Pro-2
updated 2026-11-22T20:21:38Z, scan every 120s, mode act, restart off
STALE IF NOT UPDATED BY 2026-11-22T20:32:38Z (watchdog may be down)
models: none; spent 24h $0 of $1.00

## Homes
- held: NO-ENDPOINT, owed 0, ctx unknown; captain pid 61760 live on an unknown terminal, moved 2026-11-22T20:21:24Z

## Actions since last read (2026-11-22T19:21:38Z)

## Open gaps
- held: no activity source; frozen, dead-holder, and low-context restarts are unavailable
- held: no recorded terminal endpoint; the pane cannot be read or typed into
- no model configured; judged symptoms are reported only

```

## Restart pickup pages

Captured output: `pickup-pending-pages.txt`

```text
Firstmate watchdog: pickup has 1 unhandled inputs, the oldest 16 minutes old, while 1 tasks are in flight. Its supervisor is not handling them, whatever its process or heartbeat shows. The watchdog restarted nothing. Check the supervisor terminal; the captain record is {run-worktree}/.stall-validation-lab/pickup/state/watchdog/captain and the ledger is {run-worktree}/.stall-validation-lab/pickup/state/watchdog/actions.tsv.
Firstmate watchdog: 1 ready PRs on pickup have waited up to 16 minutes without landing under standing authority: https://github.com/synthetic/repo/pull/7. The watchdog landed and restarted nothing. Check the supervisor terminal; the ledger is {run-worktree}/.stall-validation-lab/pickup/state/watchdog/actions.tsv.

```

## Restart pickup status

Captured output: `pickup-pending-status.md`

```text
# Firstmate watchdog - Eduardos-MacBook-Pro-2
updated 2026-11-22T20:23:24Z, scan every 120s, mode act, restart off
STALE IF NOT UPDATED BY 2026-11-22T20:34:24Z (watchdog may be down)
models: none; spent 24h $0 of $1.00

## Homes
- pickup: RESTART-AWAITING-PICKUP, owed 1, ctx unknown; captain pid 59296 live on an unknown terminal, moved 2026-11-22T20:23:20Z

## Actions since last read (2026-11-22T19:23:24Z)
- 20:23 pickup page stall-input done
- 20:23 pickup page stall-pr done

## Open gaps
- no model configured; judged symptoms are reported only
- pickup: stalled: 1 inputs unhandled for 16m while 1 tasks are in flight
- pickup: stalled: 1 ready PRs unlanded for up to 16m: https://github.com/synthetic/repo/pull/7

```

The first manual decision-closer check incorrectly expected a latest captain-held status to page. That status is a declared wait. The corrected run verifies silence while held and paging after a later resolved event. See handoffs-redrive.log.
