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
| The watchdog pages the owner when a permission dialog blocks an away session | `wd_page_permission` in `bin/fm-watchdog.sh` pages the home's alert channels with no dialog text; Firstmate PR #146 added it for the home pane | Merged |
| The same permission page covers away worker panes | Firstmate PR #154 reads each recorded ship or scout worker pane for a permission dialog, with its own `nudge-secs` window, per the blocking-dialog row in `docs/watchdog.md` | Merged |
| The heartbeat publishes unread captain inbox age | `bin/fm-heartbeat.sh` writes `unread_inbox_age_seconds` from `fm_captain_inbox_unread_age_seconds` in `bin/fm-captain-inbox-lib.sh`; Firstmate PR #157 added it | Merged |
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

Four readings exist today and they measure different points.
The table gives each reading its target role.

| Reading | Source | Role |
| --- | --- | --- |
| Pane footer percentage | The harness pane text, parsed by one shared parser | Input to the heartbeat record |
| Watchdog footer copy | A second parser inside the watchdog | To be removed in favor of the shared parser |
| Derived token percentage | Transcript usage against the compact point in `bin/fm-handoff-trigger.sh` | Handoff decision where a transcript and window exist |
| Full-window status percentage | The harness status line | Display only, never a decision |

The heartbeat publishes both the footer percentage and the derived percentage side by side.
Where a transcript and an auto-compact window exist, both the handoff trigger and the watchdog restart gate on the derived percentage.
Where no derived percentage exists, the watchdog restart gates on the footer percentage.
The status-line percentage never gates anything.

## Requirements

- SC-1: `input-swallowed` is detected when accepted input starts no turn within the swallow bound.
- SC-2: The default swallow bound is stated in one config owner and applies per harness.
- SC-3: Detection reads harness turn activity, not pane motion alone.
- SC-4: A running turn never counts as swallowed, frozen, or looped.
- SC-5: The first recovery step is one nudge through the record-backed input path.
- SC-6: A second detection after the nudge escalates to a restart through `bin/fm-control.sh`.
- SC-7: Where a transcript and window exist, the derived percentage gates both the handoff trigger and the watchdog restart, so one session has one low-context trigger.
- SC-7a: One shared parser owns the pane footer text for every reader, and the watchdog footer copy is removed.
- SC-8: Where no derived reading exists, the pane footer percentage owns the watchdog restart decision.
- SC-9: When both readings exist and differ by more than the disagreement bound, the derived percentage acts and the record names both values.
- SC-10: A missing owning reading reports unknown and never triggers a restart by itself, and a non-destructive nudge stays allowed on filesystem activity evidence.
- SC-11: A handoff completes only while a live successor is recorded in `state/.handoff-successor`.
- SC-12: One launcher owns successor launch per restart path: the predecessor self-launch for a Claude low-context handoff, the watchdog restart path for primaries that cannot launch themselves, and `bin/fm-control.sh relaunch` for workers and second mates; the watchdog restart path reads `.handoff-successor` and launches nothing when it names a live successor.
- SC-13: One ender owns predecessor termination; on the handoff path it ends the predecessor only when a live successor is recorded, and on the frozen, agent-gone, and restart-requested paths it ends the predecessor before it launches the successor.
- SC-14: A successor wait is bounded, and an expired wait raises one blocked record with no second launch.
- SC-15: Post-stop successor pickup verification belongs to the watchdog reconcile path, and its failure verdict rides the heartbeat `dead` verdict after the pickup bound.
- SC-16: A failed primary successor pages through the shared escalation gate, because a primary has no parent supervisor.
- SC-17: Recovery never discards uncommitted work and never removes a worktree.
- SC-18: A restart defers while the composer holds a pending unsent draft on a live session.
- SC-19: Every restart and successor launch checks the shared restart ledger and its per-subject budget first.
- SC-20: A handoff or successor launch first checks for a usage-limit refusal on the target account and never spawns onto a refused account.

## Startup and handoff churn

- SC-21: Startup tokens are measured per session from transcript usage, with the startup turns flagged in a per-session token ledger.
- SC-22: One config owner sets the startup token budget, and a session over budget reports one gap with the measured value.
- SC-23: The levers on startup load are the fixed instruction prefix and the session-start digest, and each change reports its measured token delta.
- SC-24: A handoff document is capped in size at the handoff record point, and an over-cap record refuses until the document fits.
- SC-25: A cross-session minimum handoff interval stops hourly churn under normal load, and only a dead-session verdict bypasses it.
- SC-26: Every handoff writes one row to the restart ledger, so churn is countable per home per day.

## Incident keys

| Signal | Key fields | Exception states | Routine states |
| --- | --- | --- | --- |
| Stall detection | home, task if any, symptom | second detection, restart failed | first nudge |
| Input swallowed | home, task, input record | bound expired twice | turn started in bound |
| Successor lifecycle | home, successor | pickup failed, wait expired | pickup proven |
| Startup budget | home, session | over budget | inside budget |

## Owner absence

Stall detection owner is `bin/fm-watchdog.sh`, which reads Claude transcripts only today.
A subject with no readable transcript reports `no-activity-source` and keeps detection at `unknown`.
Detection never acts on `unknown`.
A filesystem activity fallback from wake, status, and context-burn record ages may prove activity for non-Claude subjects.
Session start reports each uncovered harness once per home.

## Ownership

| Signal | Single owner | Permitted action |
| --- | --- | --- |
| Frozen, loop, unread, and unsent detection | `bin/fm-watchdog.sh` for Claude subjects, filesystem activity evidence otherwise | Nudge, then request restart |
| Accepted-without-a-turn detection | The steering inbox re-ring ladder for workers, `bin/fm-watchdog.sh` for supervisor sessions with a proven turn signal | Nudge once, then escalate |
| Successor launch | The predecessor self-launch in `bin/fm-handoff-trigger.sh` (Firstmate PR #156) for a Claude primary low-context handoff that can still take a turn; the watchdog restart path in `bin/fm-watchdog.sh`, through `restart-command`, for frozen, agent-gone, and restart-requested primaries that cannot launch themselves; `bin/fm-control.sh relaunch` for workers and second mates | Launch one successor and name the launching component in the restart ledger owner field |
| Predecessor termination | The watchdog restart path for primaries | On the handoff path, end only with a live successor recorded; otherwise end before the watchdog launches the successor |
| Post-stop pickup verification | The watchdog reconcile path | Report the `dead` verdict on failure |
| Claude primary handoff percentage | `bin/fm-handoff-trigger.sh`, acting on the derived token percentage | Ask for a handoff |
| Restart percentage for sessions with no derived reading | The watchdog restart path, acting on the pane footer percentage | Ask for a handoff, then request restart |
| Successor gate | The `state/.handoff-successor` record and its stop gate | Hold the stop until a live successor exists |
| Restart execution | `bin/fm-control.sh relaunch` for workers and second mates; the watchdog restart path for primaries | Stop the old process, and open the successor only where the Successor launch row names this component |
| Current-state read | `bin/fm-crew-state.sh` | Report state only |

## Acceptance tests

- AT-SC-1: Accepted input with no turn start inside the bound produces one `input-swallowed` record.
- AT-SC-2: A turn that starts inside the bound produces no record.
- AT-SC-3: A busy pane with a running turn produces no stall action.
- AT-SC-4: One nudge follows the first detection and one restart follows the second.
- AT-SC-5: A derived reading at the threshold fires the handoff while a higher pane reading does not cancel it.
- AT-SC-6: A disagreement past the bound records both percentages and acts on the reading of the owning path.
- AT-SC-7: A stop with no live successor stays blocked and the session keeps running.
- AT-SC-8: A stop with a live successor completes and the recheck passes.
- AT-SC-9: A successor that exits before the recheck raises exactly one blocked record.
- AT-SC-10: Both low-context paths armed on one Claude primary produce one handoff, not two.
- AT-SC-11: An N-hour away-mode soak holds handoffs at or under the target and startup tokens at or under the budget, both measured against the recorded baseline.
- AT-SC-12: A pending unsent draft defers a restart and loses no draft text.
- AT-SC-13: Existing suites `tests/fm-handoff-trigger.test.sh` and `tests/fm-crew-state.test.sh` still pass.

## Failure-injection and recovery drills

Every drill runs in a fixture home with a private terminal socket or a named non-default lab, never on a live home.

- DR-SC-1: Submit input to a test session and suppress the turn start and confirm detection at the bound.
- DR-SC-2: Freeze a test pane with a running turn and confirm no action fires.
- DR-SC-3: Drive context to the threshold and confirm the handoff names a live successor before any stop.
- DR-SC-4: Kill the successor after the stop and confirm one blocked record through the shared gate.
- DR-SC-5: Force the two context readings apart and confirm the derived reading acts and both values are recorded.
- DR-SC-6: Remove the owning context reading and confirm no restart fires on unknown.

## Escalation and quiet hours

This PRD escalates only when a recovery step fails or a successor check fails.
A stall that the nudge clears sends no escalation.
Quiet hours and dedupe follow [escalation-quiet-hours.md](escalation-quiet-hours.md).

## Token economics

Baseline method: count supervisor session tokens from transcript usage by turn type, with startup turns flagged separately.
Handoff counts and sizes come from the handoff records and the restart ledger.
Wake counts come from the durable wake ledger, never from the drained queue.
Counts normalize per active task-hour.
The window is 14 consecutive days before the change and 14 consecutive days after it, on the same homes.
Token history rebuilds from transcripts, and wake-based windows start only after the wake ledger exists.
No savings figure is stated until both windows exist.

## Resolution of Stage 2 findings

| Finding | Reviewer | Resolution | Section changed |
| --- | --- | --- | --- |
| A-SC-1 | A opus-5-5 | Startup ledger, budget, handoff cap, churn limit, and N-hour soak added | SC-21 to SC-26, AT-SC-11 |
| A-SC-2 | A opus-5-5 | One launcher, one ender, bounded successor wait | SC-12 to SC-14 |
| A-SC-3 | A opus-5-5 | Four readings listed, one parser, derived percentage gates both paths | Context readings, SC-7, SC-7a |
| A-SC-4 | A opus-5-5 | Swallow ownership split by subject with `unknown` until a turn signal is proven | Ownership, Owner absence |
| A-SC-5 | A opus-5-5 | Pickup verification delegated to the watchdog reconcile path and the heartbeat verdict | SC-15, SC-16 |
| A-SC-6 | A opus-5-5 | Token baseline rebuilt on transcript usage by turn type | Token economics |
| SC-F1 | B gemini-argon | Startup measurement, budget, handoff cap, cooldown, and AFK acceptance test added | SC-21 to SC-26, AT-SC-11 |
| SC-F2 | B gemini-argon | Pickup verification owned by the watchdog path with a primary page through the shared gate | SC-15, SC-16 |
| SC-F3 | B gemini-argon | Both context numbers published and the derived percentage gates both triggers | Context readings, SC-7 |
| SC-F4 | B gemini-argon | Filesystem activity fallback and non-destructive nudge on unknown transcript | SC-10, Owner absence |
| SC-F5 | B gemini-argon | Token baseline measures session transcripts by turn type | Token economics |
| SC-F6 | B gemini-argon | Restart defers on a pending unsent draft | SC-18, AT-SC-12 |
| SC-F7 | B gemini-argon | Usage-limit check before any successor spawn | SC-20 |

Status: FINAL. Every BLOCKING finding from both Stage 2 reviews is closed above.
