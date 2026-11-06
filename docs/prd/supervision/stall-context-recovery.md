# PRD: Stall and context recovery

## Purpose

This PRD defines how Firstmate recovers a live session that stops making progress.
It covers stalled sessions, low-context handoff, the live-successor rule, an input that a harness accepts without starting a turn, and disagreement between two context readings.
It changes no merge, release, or deploy gate.

## Scope

- In scope: frozen panes, timer loops, unread and unsent input, low context, and successor liveness.
- In scope: the context percentage a supervisor acts on when two readings disagree.
- Out of scope: homes with a dead lock owner.
- Dead lock owners live in [heartbeat-health.md](heartbeat-health.md).
- Escalation and quiet hours live in [escalation-quiet-hours.md](escalation-quiet-hours.md).

## Current capability

| Capability | Evidence in this repo | State |
| --- | --- | --- |
| The watchdog nudges then restarts a frozen session | The frozen row in `docs/watchdog.md` requires pane and transcript quiet for `frozen-secs`, default 900 | Present |
| The watchdog detects a timer loop | Three of the last five assistant texts repeating with only timer tools between them counts as a loop | Present |
| The watchdog detects unread and unsent input | The unread-input and unsent-input rows in `docs/watchdog.md` own both reads | Present |
| A low-context nudge asks for a handoff before restart | The restart-requested row in `docs/watchdog.md` requires a `data/handoff-*.md` file and `state/.watchdog-restart-request` | Present |
| An early handoff trigger fires before auto-compact | `bin/fm-handoff-trigger.sh` fires at a default of 15 percent left for Claude primary sessions | Present |
| A handoff session stops only with a live successor | Firstmate PR #156 requires a live successor recorded in `state/.handoff-successor` before the session stops | Merged |
| Lifecycle actions run through one control plane | `bin/fm-control.sh` owns `interrupt`, `exit`, and `relaunch` with a verified postcondition | Present |
| Current state reads reconcile the status log | `bin/fm-crew-state.sh` reads the run step or pane instead of the tail of the status log | Present |
| The external auto-compact percentage is recorded each turn | Firstmate PR #102 records the footer percentage and alerts on fast context burn | Merged |

## Gaps

| Gap | Consequence |
| --- | --- |
| No signal covers a harness that accepts input and never starts a turn | The input reads as delivered while no work starts |
| That state has no name, no bound, and no owner | Each supervisor improvises a wait or a restart |
| Two context readings can disagree with no stated winner | A handoff fires too late or a healthy session restarts early |
| The watchdog restart path and the early handoff trigger use different context sources | The two paths can act on different percentages in the same session |
| Successor liveness is proven at stop time only | A successor that dies right after the stop leaves no session running |

## The accepted-without-a-turn state

This PRD names that state `input-swallowed`.
It means the harness reports the input accepted and no turn starts within the bound.
A Codex session that shows a working indicator with no turn activity is one presentation of this state.
The state is a stall, not a delivery success.
Delivery success requires a started turn.

## Context readings

Two readings exist today and they measure different points.

| Reading | Source | Measures |
| --- | --- | --- |
| Pane footer percentage | The harness pane text `N% until auto-compact`, parsed by `bin/fm-context-footer-lib.sh` | Context left before auto-compact as the harness renders it |
| Derived token percentage | Transcript usage against the compact point, derived in `bin/fm-handoff-trigger.sh` | Context left before the derived auto-compact point |

The heartbeat publishes the pane reading in `context_left`.
The handoff trigger acts on the derived reading.
Neither reading is wrong by itself.
The gap is the missing rule for which one acts.

## Requirements

- SC-1: `input-swallowed` is detected when accepted input starts no turn within the swallow bound.
- SC-2: The default swallow bound is stated in one config owner and applies per harness.
- SC-3: Detection reads harness turn activity, not pane motion alone.
- SC-4: A running turn never counts as swallowed, frozen, or looped.
- SC-5: The first recovery step is one nudge through the record-backed input path.
- SC-6: A second detection after the nudge escalates to a restart through `bin/fm-control.sh`.
- SC-7: The derived token percentage owns handoff and restart decisions.
- SC-8: The pane footer percentage owns display and fast-burn alerts only.
- SC-9: When the two readings differ by more than the disagreement bound, the lower reading acts and the record names both values.
- SC-10: A missing reading reports unknown and never triggers a restart by itself.
- SC-11: A handoff completes only while a live successor is recorded in `state/.handoff-successor`.
- SC-12: Successor liveness is rechecked once after the predecessor stops.
- SC-13: A successor that fails the recheck raises one blocked record for the parent supervisor.
- SC-14: Recovery never discards uncommitted work and never removes a worktree.

## Ownership

| Signal | Single owner | Permitted action |
| --- | --- | --- |
| Frozen, loop, unread, and unsent detection | `bin/fm-watchdog.sh` | Nudge, then request restart |
| Accepted-without-a-turn detection | `bin/fm-watchdog.sh` | Nudge once, then escalate |
| Handoff decision percentage | `bin/fm-handoff-trigger.sh` for Claude primaries, the watchdog restart path otherwise | Ask for a handoff |
| Successor gate | The `state/.handoff-successor` record and its stop gate | Hold the stop until a live successor exists |
| Restart execution | `bin/fm-control.sh relaunch` for workers and second mates, the watchdog restart path for primaries | Stop the old process and open the successor |
| Current-state read | `bin/fm-crew-state.sh` | Report state only |

## Acceptance tests

- AT-SC-1: Accepted input with no turn start inside the bound produces one `input-swallowed` record.
- AT-SC-2: A turn that starts inside the bound produces no record.
- AT-SC-3: A busy pane with a running turn produces no stall action.
- AT-SC-4: One nudge follows the first detection and one restart follows the second.
- AT-SC-5: A derived reading at the threshold fires the handoff while a higher pane reading does not cancel it.
- AT-SC-6: A disagreement past the bound records both percentages and acts on the lower one.
- AT-SC-7: A stop with no live successor stays blocked and the session keeps running.
- AT-SC-8: A stop with a live successor completes and the recheck passes.
- AT-SC-9: A successor that exits before the recheck raises exactly one blocked record.
- AT-SC-10: Existing suites `tests/fm-handoff-trigger.test.sh` and `tests/fm-crew-state.test.sh` still pass.

## Failure-injection and recovery drills

- DR-SC-1: Submit input to a test session and suppress the turn start and confirm detection at the bound.
- DR-SC-2: Freeze a test pane with a running turn and confirm no action fires.
- DR-SC-3: Drive context to the threshold and confirm the handoff names a live successor before any stop.
- DR-SC-4: Kill the successor after the stop and confirm the parent receives one blocked record.
- DR-SC-5: Force the two context readings apart and confirm the lower one acts and both values are recorded.
- DR-SC-6: Remove both context readings and confirm no restart fires on unknown.

## Escalation and quiet hours

This PRD escalates only when a recovery step fails or a successor check fails.
A stall that the nudge clears sends no escalation.
Quiet hours and dedupe follow [escalation-quiet-hours.md](escalation-quiet-hours.md).

## Token economics

The baseline method counts supervisor wakes and model tokens before and after this work.
The measurement window is 14 consecutive days before the change and 14 consecutive days after it.
The counters are stall-related wake records per day, restart counts in `state/watchdog/actions.tsv`, and token fields in `state/watchdog/model-calls.tsv`.
A avoided-restart count is reported only from those records, never from an estimate.
No savings figure is stated until both windows exist.

## Open questions

- OQ-SC-1: What swallow bound fits each harness without flagging slow first turns.
- OQ-SC-2: What disagreement bound separates reading noise from a real conflict.
- OQ-SC-3: Which harnesses expose a turn-started signal strong enough for SC-3.
