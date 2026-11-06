# PRD: Escalation and quiet hours

## Purpose

This PRD defines the cross-cutting escalation contract for the supervision PRDs.
It covers delta dedupe, exception-only escalation, and Slack quiet hours.
It applies to [heartbeat-health.md](heartbeat-health.md), [stall-context-recovery.md](stall-context-recovery.md), [quota-account-routing.md](quota-account-routing.md), and [pr-check-monitoring.md](pr-check-monitoring.md).
It changes no merge, release, or deploy gate.

## Scope

- In scope: what counts as an escalation, when one fires, and when one stays silent.
- In scope: the Slack quiet-hours window and the digest that replaces held messages.
- Out of scope: the detection logic of each signal.
- Each signal keeps its owner in its own PRD.

## Current capability

| Capability | Evidence in this repo | State |
| --- | --- | --- |
| Wake presentation dedupes repeated rows | `fm_wake_print_deduped` in `bin/fm-wake-lib.sh` collapses duplicate wake rows at drain time | Present |
| Status appends dedupe through one primitive | The guarded status append in `bin/fm-wake-lib.sh` is the single dedup primitive for status lines | Present |
| The away daemon dedupes escalation digests | The dedup state in `bin/fm-supervise-daemon.sh` layers on its classified-through offset | Present |
| Away and quiet modes buffer escalations | `docs/wedge-alarm.md` defines buffered escalation and rate-limited alarms for away and quiet modes | Present |
| Alert channels are configurable and rate-limited | `config/wedge-alarm` lists channels and each alert is bounded by the max-defer window | Present |
| The watchdog records every action and gap | `state/watchdog/actions.tsv` records pending, done, failed, and refused actions | Present |

## Gaps

| Gap | Consequence |
| --- | --- |
| Dedupe runs per surface rather than per incident | One incident can still escalate once per surface |
| No contract states that only exceptions escalate | Routine recoveries still reach the owner |
| No Slack quiet-hours window exists | Night and weekend messages carry no suppression rule |
| Held messages have no stated digest time | A suppressed incident can wait without a defined surfacing point |

## Definitions

- An exception is a state that needs a human decision, a failed recovery, or a hard boundary.
- A routine recovery is a nudge, restart, move, or watch result that clears without a human.
- A delta is a change of state since the last reported state of the same incident.
- An incident key names one signal on one subject and stays stable across passes.

## Requirements

- EQ-1: Only exceptions escalate.
- EQ-2: A routine recovery writes its record and sends no escalation.
- EQ-3: One incident key produces at most one escalation per state.
- EQ-4: A repeated pass over an unchanged state sends nothing.
- EQ-5: A state change on a known incident sends one delta escalation with the old and new states.
- EQ-6: A cleared incident sends one closure record and no further messages.
- EQ-7: The dedupe record survives a supervisor restart.
- EQ-8: Slack escalation stays off during quiet hours with no exception. A destructive, irreversible, or security-sensitive exception holds for the next allowed window or the return brief, and quiet hours never pre-authorize it.
- EQ-9: Quiet hours run from 22:00 to 08:00 every night in `America/Costa_Rica` time.
- EQ-10: The weekend window runs from Friday 17:00 to Monday 08:00 in `America/Costa_Rica` time and replaces the nightly window inside that span.
- EQ-11: Held messages collect into one digest at the next window end.
- EQ-12: The digest lists each held incident once with its current state.
- EQ-13: An incident that clears during quiet hours appears in the digest as cleared and sends nothing else.
- EQ-14: Quiet hours never delay a local durable record, a wake, or a recovery action.
- EQ-15: Quiet hours apply to the Slack channel only unless a later decision names another channel.

## Ownership

| Signal | Single owner | Permitted action |
| --- | --- | --- |
| Incident dedupe | The wake and status dedupe primitives in `bin/fm-wake-lib.sh` | Collapse repeats of one incident key |
| Escalation decision | The signal owner named in each PRD | Escalate an exception only |
| Slack delivery | The configured alert channel path in `docs/wedge-alarm.md` | Send or hold one message |
| Quiet-hours clock | This PRD | Define the window for every consumer |
| Digest | The away and quiet supervision path | Send one digest at window end |

## Acceptance tests

- AT-EQ-1: Three passes over one unchanged exception produce one escalation.
- AT-EQ-2: A nudge that clears a stall produces no escalation.
- AT-EQ-3: A state change on an open incident produces one delta with both states.
- AT-EQ-4: A restart of the supervisor mid-incident produces no duplicate escalation.
- AT-EQ-5: A non-urgent exception at 23:00 on a Tuesday sends no Slack message and appears in the 08:00 digest.
- AT-EQ-6: A non-urgent exception at 18:00 on a Friday appears in the Monday 08:00 digest.
- AT-EQ-7: A destructive or security-sensitive exception during quiet hours sends no Slack message and appears in the next digest or the return brief.
- AT-EQ-8: An incident that clears overnight appears once in the digest as cleared.
- AT-EQ-9: Recovery actions during quiet hours run on their normal cadence with no Slack message.

## Failure-injection and recovery drills

- DR-EQ-1: Replay one wake three times and confirm one escalation leaves the system.
- DR-EQ-2: Open an incident before quiet hours and hold it open and confirm one digest entry at window end.
- DR-EQ-3: Clear an incident during quiet hours and confirm the digest marks it cleared with no separate message.
- DR-EQ-4: Restart the supervisor during an open incident and confirm the dedupe record prevents a repeat.
- DR-EQ-5: Raise a security-sensitive exception at night and confirm no Slack message leaves before the window ends, the item appears in the next digest, and no action on it runs without a captain decision.

## Token economics

The baseline method counts supervisor wakes and model tokens before and after this work.
The measurement window is 14 consecutive days before the change and 14 consecutive days after it.
The counters are escalations sent per day, held messages per digest, and wake records drained per day.
Message volume counts from channel and wake records, never from an estimate.
No savings figure is stated until both windows exist.

## Open questions

- OQ-EQ-1: Which channel list beyond Slack inherits the quiet-hours window.
- OQ-EQ-2: Whether the digest rides the existing away digest or stands alone.
