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
- An incident key names one signal on one subject in one home, plus its state, and stays stable across passes.

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

## Shared ledgers

This PRD owns three shared records that the four signal PRDs reference and never restate.

The escalation gate wraps `wedge_alarm_notify`, reached externally through `fm-supervise-daemon.sh page` (`bin/fm-supervise-daemon.sh:1305`, `:2353-2359`).

| Ledger | Record | Rule |
| --- | --- | --- |
| Incident ledger | One append-only row per incident transition, keyed by home, subject, signal, and state, at `state/incident-ledger.tsv` | The escalation gate is its only writer, and dedupe reads it before any send |
| Wake ledger | One append-only row per wake at acknowledgement time, at `state/wake-ledger.tsv` | `bin/fm-wake-drain.sh` writes it at acknowledgement, and wake counts read it, never the drained queue |
| Restart ledger | One append-only row per restart, handoff, or quota move, keyed by subject, with a `kind` field of `handoff` or `restart` and an owner field naming the component that acted or launched the successor, at `state/restart-ledger.tsv` | Every forced restart or relaunch checks the per-subject restart budget before acting and refuses over budget with one escalation. Only `restart` rows count against that budget; planned handoffs inside the SC-25 interval rule are bounded by that rule instead. Each writer appends under a lock. The budget default is 2 per day, at least 7200 s apart. The SC-25 handoff interval uses its own `handoff-interval-secs` key (default 7200), and a bypass of that interval never bypasses this restart spacing |

## Shared requirements

- EQ-16: Every signal owner reports its transitions to the escalation gate, which alone appends them to the incident ledger, and the gate reads that ledger before escalating.
- EQ-17: The escalation gate owns dedupe, quiet-hours holding, and the digest in every mode, attended or away.
- EQ-18: A failed send writes its durable record first, then retries under a bound, and never drops silently.
- EQ-19: The digest flush runs at window end even when the away daemon is not running, under an atomic lock, and resolved incidents clear on flush.
- The monitor unit loop runs that flush, kept alive by launchd or systemd without the away daemon.
- Session start and the return brief read the held digest record and show any unsent entries.
- EQ-20: Every outbound sender is inventoried with a channel label, and external senders list as dependencies rather than capability.
- A `command:` channel carries its label as `command[slack]:<cmd>`.
- An unlabeled `command:` channel counts as `other`, which quiet hours do not hold.

| Sender | Location | Channel | Label | Gate path |
| --- | --- | --- | --- | --- |
| `wedge_alarm_notify` | `bin/fm-supervise-daemon.sh:1305` | Configured alert channels | Per-channel label | The gate itself |
| External `page` entry | `bin/fm-supervise-daemon.sh:2353-2359` | Configured alert channels | Per-channel label | Through `wedge_alarm_notify` |
| Watchdog permission page `wd_page_permission` | `bin/fm-watchdog.sh:963`, `:980` | Via `page` | Per-channel label | Through `page` |
| Monitor `watchdog_alert` | `bin/fm-monitor-watchdog.sh:136-158`, `:148` | Via `page` | Per-channel label | Through `page` |
| Watcher away-decision pager | `bin/fm-watch.sh:2990`, `:3087` | Via `page` | Per-channel label | Through `page` |
| Usage warner | `bin/fm-usage-warner.sh:236` | `osascript` desktop notice | `other` | Through the gate |
| Relay follow-ups | `fmx-respond`, external | Relay | External dependency | Listed as a dependency, not capability |
| External Orca poll loop | External to this repo | External beacons | External dependency | Listed as a dependency, not capability |
- EQ-21: Direct page callers route through the one gate, so no caller bypasses dedupe or quiet hours.
- EQ-22: The exception classes include inject-wedged and watcher-recovery-failed alongside permission-dialog, unconfirmed-restart, restart-loop, quota-all-at-floor, conflicted-pr, and blocked-decision.
- EQ-23: The quiet-hours clock is one function behind one config key with an explicit `America/Costa_Rica` time zone.
- EQ-24: Boundary behavior at 22:00, 08:00, and Friday 17:00 holds on a host in any time zone.
- EQ-25: The longest quiet-hours hold is the weekend span, and the digest time states it.
- EQ-26: No Slack sender exists in this repo today, so Slack delivery lists as an external dependency until a channel lands.

## Ownership

| Signal | Single owner | Permitted action |
| --- | --- | --- |
| Incident dedupe | The escalation gate, sole writer of the incident ledger | Collapse repeats of one incident key |
| Escalation decision | The signal owner named in each PRD | Escalate an exception only |
| Slack delivery | External dependency: no Slack sender exists in this repo (EQ-26), and the escalation gate hands each released message to it | Send or hold one message |
| Quiet-hours clock | The one quiet-hours function behind the one config key, in `America/Costa_Rica` (EQ-23) | Define the window for every consumer |
| Digest | The escalation gate, in every mode, attended or away (EQ-17, EQ-19) | Send one digest at window end |

## Acceptance tests

- AT-EQ-1: Three passes over one unchanged exception produce one escalation.
- AT-EQ-2: A nudge that clears a stall produces no escalation.
- AT-EQ-3: A state change on an open incident produces one delta with both states.
- AT-EQ-4: A restart of the supervisor mid-incident produces no duplicate escalation.
- AT-EQ-5: An exception at 23:00 on a Tuesday sends no Slack message and appears in the 08:00 digest.
- AT-EQ-6: An exception at 18:00 on a Friday appears in the Monday 08:00 digest.
- AT-EQ-7: A destructive or security-sensitive exception during quiet hours sends no Slack message and appears in the next digest or the return brief.
- AT-EQ-8: An incident that clears overnight appears once in the digest as cleared.
- AT-EQ-9: Recovery actions during quiet hours run on their normal cadence with no Slack message.
- AT-EQ-10: With the away daemon stopped, a message held at 23:00 appears in exactly one digest at 08:00.

## Failure-injection and recovery drills

- DR-EQ-1: Replay one wake three times and confirm one escalation leaves the system.
- DR-EQ-2: Open an incident before quiet hours and hold it open and confirm one digest entry at window end.
- DR-EQ-3: Clear an incident during quiet hours and confirm the digest marks it cleared with no separate message.
- DR-EQ-4: Restart the supervisor during an open incident and confirm the dedupe record prevents a repeat.
- DR-EQ-5: Raise a security-sensitive exception at night and confirm no Slack message leaves before the window ends, the item appears in the next digest, and no action on it runs without a captain decision.

## Token economics

Baseline method: count outbound pages from the watchdog action rows and the monitor page log.
Count supervisor wake tokens from session transcript usage by turn type.
Count held messages per digest from the quiet-hours queue records.
Counts normalize per active task-hour.
The window is 14 consecutive days before the change and 14 consecutive days after it, on the same homes.
Wake-based before-windows start only after the wake ledger exists.
No savings figure is stated until both windows exist.

## Resolution of Stage 2 findings

| Finding | Reviewer | Resolution | Section changed |
| --- | --- | --- | --- |
| A-EQ-1 | A opus-5-5 | Sender inventory with channel labels and external senders as dependencies | EQ-20, EQ-26 |
| A-EQ-2 | A opus-5-5 | One quiet-hours function behind one config key with explicit zone | EQ-23, EQ-24 |
| A-EQ-3 | A opus-5-5 | One durable incident ledger behind one escalation gate | Shared ledgers, EQ-16 |
| A-EQ-4 | A opus-5-5 | Gate owns the digest in every mode with durable record and bounded retry | EQ-17 to EQ-19 |
| A-EQ-5 | A opus-5-5 | Baseline counts pages, queue records, and session tokens | Token economics |
| EQ-F1 | B gemini-argon | Named channel syntax and one gate for every page caller | EQ-21, EQ-26 |
| EQ-F2 | B gemini-argon | Window-end flush under lock even with the daemon down | EQ-19 |
| EQ-F3 | B gemini-argon | Durable dedupe keyed by home, subject, signal, and state | Shared ledgers |
| EQ-F4 | B gemini-argon | Inject-wedged and watcher-recovery-failed added to the exception classes | EQ-22 |
| EQ-F5 | B gemini-argon | Baseline method added with page and wake counters | Token economics |
| F-EQ-1 | FINAL opus-5-5 | Sender inventory with channel labels added and `command[slack]:<cmd>` defined; an unlabeled command counts as `other` | EQ-20, sender inventory |
| F-EQ-2 | FINAL opus-5-5 | Gate wraps `wedge_alarm_notify` / `fm-supervise-daemon.sh page`; ledgers placed under `state/` with named writers; budget default 2 per day, at least 7200 s apart | Shared ledgers, EQ-16 |
| F-EQ-3 | FINAL opus-5-5 | Monitor unit loop named as the window-end flush runner under the lock; session start and the return brief read the held digest record | EQ-19, AT-EQ-10 |

Status: FINAL. Every BLOCKING finding from both Stage 2 reviews and the FINAL opus-5-5 review is closed above.

## Open questions

- OQ-EQ-1: Which channel list beyond Slack inherits the quiet-hours window.
