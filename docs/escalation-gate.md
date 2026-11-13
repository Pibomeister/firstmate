# Escalation gate

The escalation gate (`bin/fm-escalate.sh`) is the one component that appends incident transitions to the incident ledger and decides which transitions are sent.
The requirements are EQ-1 to EQ-7, EQ-16 and EQ-22 in [`prd/supervision/escalation-quiet-hours.md`](prd/supervision/escalation-quiet-hours.md).
The script header owns the command, its flags and the decision procedure.
This page owns the behavior and the boundaries.

## What the gate guarantees

A signal owner reports each transition of one subject to the gate, and the gate alone writes it to `state/incident-ledger.tsv`.
The gate reads that ledger under its lock before every send.
It keeps no other dedupe state, so a supervisor restart between two reports changes nothing.

Only a state whose class is an exception class escalates.
The exception classes are the classes of [`bin/fm-escalation-class-map.tsv`](../bin/fm-escalation-class-map.tsv) other than `routine` and `closure`.
That one table gives every exception state of the four signal PRDs exactly one class.
A state the table does not name is routine, and `cleared` closes an open episode for every signal.
A routine recovery writes its record and sends nothing.

An episode runs from the first exception of a subject and signal to the routine state that closes it.
Within one episode:

- The first exception sends one escalation.
- A repeat of an unchanged state sends nothing.
- A change to a state not yet escalated sends one delta that names the old and new states.
- A return to a state already escalated writes a row and sends nothing, because a delta is an escalation.
- A routine state closes the episode and sends one closure record, and nothing follows it in that episode.

An exception after a closure opens a new episode and escalates once.

## One incident, two reports

An event can touch two incident keys, such as a dead primary and the stall it causes.
The effect names the cause with `--cause`, and the gate records one of the two as an escalation and the other without a send.
Both arrival orders give one escalation, because the gate reads only the ledger.
A producer that reports both sends the cause first.
When the episode that suppressed a report closes while the suppressed state persists, the next report of that state escalates once, so the condition still surfaces.

## Wakes

A report with `--wake` yields one supervisor wake for each new ledger row, routine or exception.
The wake has kind `incident`, key `incident-<transition-id>` and payload `transition=<id>`.
The gate enqueues it only when neither the wake queue nor the wake ledger holds that key.
A report retried after a crash therefore yields its one wake, and a report retried after the enqueue yields none.
Wake dedupe compares against the latest ledger row in any state, so a key that returns to an earlier state wakes again.
Quiet hours never hold or delay a wake.

No consumer handles an `incident` wake yet.
The away-mode daemon loop skips a row of that kind, and its acknowledgement consumes it.
The supervisor contract names no handling for it.
Nothing calls the gate yet.
No producer may call the gate with `--wake` until that handling lands, so that handling comes before any existing sender is routed through the gate.

## Delivery

The gate sends through `wedge_alarm_notify` in `bin/fm-notify-lib.sh`, so it uses the channels of [`wedge-alarm.md`](wedge-alarm.md).
The messages carry only key fields, states, class names, counts and times, plus any text or detail the caller passes.
A send that fails or finds no channel is reported on the result line, and the ledger row stays.

## Not built yet

This gate holds no quiet-hours window, withholds no secret text, retries no send and keeps no durable send record.
It builds no digest, and no existing sender routes through it yet.
Those belong to later work on the same PRD.

## Verification

`tests/fm-escalate.test.sh` covers dedupe, delta, closure, cause correlation in both orders and both crash points of the wake step.
`tests/fm-escalation-class-map.test.sh` checks the class map against the incident keys tables of the four signal PRDs.
`tests/fm-daemon.test.sh` covers the moved notifier functions through the daemon.
