# Review: Escalation and quiet hours PRD (reviewer A)

- PRD: `docs/prd/supervision/escalation-quiet-hours.md` at commit `8963bced`
- Reviewer: Opus 5.5 (`claude-opus-5-5`, reasoning effort xhigh)
- Review type: adversarial, independent of the other reviewer
- Verdict: **block**

## Summary

The PRD sets a clear rule: only exceptions escalate, with one message per incident state, and Slack stays silent during quiet hours.
The window itself (EQ-9, EQ-10) is a decision already made, and this review does not reopen it.
The problem is that each owner the PRD names either does not exist or cannot do the job.
The repository has no Slack channel, only a generic command hook.
The named dedupe primitive is an in-memory collapse at drain time, over rows that are deleted when they are acknowledged.
The digest owner exists only in away and quiet modes, while quiet hours run every night.
The quiet-hours clock is owned by "this PRD", which is a document and not code.

Finding IDs use the prefix `A-EQ-` so they do not collide with the PRD's own `EQ-` requirement IDs.

## Findings

### A-EQ-1. BLOCKING, high: the Slack sender is not identified, so EQ-8 and EQ-15 cannot be enforced

- Dimension: duplicate ownership, safety.
- Evidence:
  - The Slack delivery owner (line 68) is "the configured alert channel path in `docs/wedge-alarm.md`".
  - That path's channels are `off`, `auto` or `default` (macOS Notification Center), `osascript`, `herdr`, `rex`, and `command:<cmd>` (`docs/wedge-alarm.md:9-21`). None of them is Slack.
  - Slack is reachable only when an operator writes a `command:` directive that posts there. The daemon's comment names Slack as one example of what a command might reach (`bin/fm-supervise-daemon.sh:1263`).
  - An absent `config/wedge-alarm` behaves as `auto`, a local banner (`docs/wedge-alarm.md:23`).
  - Other outbound paths exist that the PRD does not classify: the watchdog's permission page (`wd_page_permission`, `bin/fm-watchdog.sh:963`), the outer guard's page (`bin/fm-monitor-watchdog.sh:136-158`), Relay follow-ups (`fmx-respond`), and senders outside this repository, such as the external Orca loop named in `heartbeat-health.md`.
- Failure scenario: a home has a `command:` line that posts to Slack. Under EQ-15 the PRD does not say whether that line counts as "the Slack channel". An implementer gates nothing, and a permission page reaches Slack at 02:00. Or an implementer gates every `command:` line, and a pager that the owner wants at night goes quiet.
- Smallest fix:
  - Add an inventory table of every outbound sender. Give each one a channel label, either `slack` or `other`, and an owner.
  - Let a `command:` directive carry an explicit label, such as `command[slack]:`, so the quiet-hours gate can tell the destinations apart.
  - List senders outside this repository as dependencies to confirm with their owners, in the same way `heartbeat-health.md` treats the external loop.

### A-EQ-2. BLOCKING, high: "This PRD" owns the quiet-hours clock, so every sender will build its own

- Dimension: duplicate ownership, failure modes.
- Evidence:
  - The ownership row (line 69) names the document as the owner.
  - EQ-9 and EQ-10 (lines 54-55) set the window in `America/Costa_Rica` time. The hosts' system time zones are not part of any contract.
  - No library function or config key is named.
- Failure scenario: two senders implement the window separately. One uses the host's local time on a machine set to another zone, and the other uses UTC arithmetic. A Friday 17:00 message passes one gate and is held by the other. AT-EQ-5 and AT-EQ-6 pass on one host and fail on another.
- Smallest fix:
  - Name one function, for example `fm_quiet_hours_active <epoch>` in one shared library, and one config key that holds the window and the explicit time zone.
  - Every sender calls that function, and none computes the window itself.
  - Add boundary tests at 21:59, 22:00, 07:59, and 08:00 on a weekday; at Friday 16:59 and 17:00; and at Monday 07:59 and 08:00. Run them with the host time zone set to something other than `America/Costa_Rica`.

### A-EQ-3. BLOCKING, high: the named dedupe owner is per drain and in memory, so EQ-3 and EQ-7 cannot hold

- Dimension: duplicate ownership, restart loops.
- Evidence:
  - The ownership row (line 66) names "the wake and status dedupe primitives in `bin/fm-wake-lib.sh`".
  - `fm_wake_print_deduped` (`bin/fm-wake-lib.sh:2909-2929`) collapses rows inside one drain's output, in an `awk` pass keyed on kind and key. It keeps no state across drains.
  - Acknowledged wake rows are deleted from the queue (`bin/fm-wake-drain.sh:898-913`). So the next pass has nothing to compare against.
  - The status primitive (`bin/fm-wake-lib.sh:3137`) dedupes this home's own bookkeeping status lines. It does not dedupe escalations.
  - Other senders keep their own separate dedupe. The daemon uses its classified-through offset (`bin/fm-supervise-daemon.sh:402`, `:1604`). The quiet-mode summary is "throttled in memory ... with no durable marker" (`docs/wedge-alarm.md:7`). The watchdog keeps its own gap rows in `state/watchdog/actions.tsv`.
- Failure scenario: an exception is escalated at 21:00. The supervisor restarts at 21:30, a routine handoff (see the stall review, finding A-SC-1). The new session sees the same open incident with no record of the earlier send, and escalates again. EQ-7 and AT-EQ-4 fail.
- Smallest fix:
  - Add one durable incident ledger with these fields: incident key, current state, first seen, last state sent, channel, and sent time.
  - Put one escalation gate function in front of it, and have every sender call the gate.
  - Make the gate the owner of incident dedupe, in place of the drain-time primitives.
  - Require each signal PRD to define its incident key (report issue A-X4).

### A-EQ-4. BLOCKING, medium: the digest has no owner in attended mode and no retry

- Dimension: missed work.
- Evidence:
  - The digest owner (line 70) is "the away and quiet supervision path".
  - That path runs only while the away record exists (`AGENTS.md` section 5).
  - Quiet hours run every night (EQ-9) whether or not the home is away.
  - Channels are best-effort. A failed `command:` logs a warning and moves on (`docs/wedge-alarm.md:26-27`). No requirement retries a failed digest.
- Failure scenario: the owner leaves the home attended overnight without running `/afk`. An exception at 23:00 is held. At 08:00 there is no away path, so no digest is sent. The held exception surfaces only if someone reads the local record.
- Smallest fix:
  - Make the escalation gate from A-EQ-3 own the digest in every mode.
  - Write the digest to a durable record first, then send it with a bounded retry.
  - The return brief and session start read that record, so a failed send is still seen.

### A-EQ-5. BLOCKING: the token and message baseline is not measurable as written

- Dimension: token economics.
- Evidence:
  - The counters (line 96) are escalations sent per day, held messages per digest, and wake records drained per day.
  - No durable record of sent escalations exists. The quiet-mode summary throttle lives in memory (`docs/wedge-alarm.md:7`).
  - Wake rows are deleted on acknowledgement (`bin/fm-wake-drain.sh:898-913`).
  - "Message volume counts from channel records" (line 97) assumes records that no channel writes.
- Smallest fix: make the incident ledger from A-EQ-3 the counter source for sends and holds. Adopt the cross-PRD wake ledger (report issue A-X1).

### A-EQ-6. NON-BLOCKING, medium: state the maximum hold, and say which pages keep firing at night

- Dimension: safety, missed work.
- Evidence:
  - EQ-8 holds even destructive and security-sensitive exceptions, with no exception (line 53). The longest nightly hold is 10 hours. The weekend hold runs from Friday 17:00 to Monday 08:00, which is 63 hours.
  - EQ-15 limits quiet hours to Slack. So local banners, the permission page, and the outer guard page keep firing at night, unless their `command:` destination is Slack (A-EQ-1).
- Smallest fix:
  - Write the two maximum hold times into the PRD, so the cost of the decision is recorded.
  - List which pages still fire at night.
  - Have the digest show each held item's age.

### A-EQ-7. NON-BLOCKING, medium: the digest needs a redaction rule

- Dimension: safety.
- Evidence: the permission page carries no dialog text (`bin/fm-watchdog.sh:963`; `docs/watchdog.md:59`). The watchdog withholds text that looks like a secret. The digest gathers many held incidents into one message and has no stated content rule.
- Smallest fix: add EQ-16. "The digest carries the incident key, state, age, and a fixed summary only. It carries no dialog text, pane text, secret-looking strings, or private paths."

### A-EQ-8. NON-BLOCKING, low: say that EQ-1 does not change chat reporting

- Dimension: missed work.
- Evidence: `AGENTS.md` section 9 requires immediate reports for PRs ready for review, finished investigations, and needed credentials. A strict reading of "only exceptions escalate" could suppress those reports.
- Smallest fix: add one line: "This PRD governs alert-channel escalations from the supervision signals only. Chat reporting under `AGENTS.md` section 9 is unchanged."

### A-EQ-9. NON-BLOCKING, low: batching wakes during quiet hours is a possible follow-up, not scope

- Dimension: token economics.
- Evidence: EQ-14 keeps every wake and recovery on its normal cadence at night, so quiet hours save no supervisor tokens.
- Smallest fix: none for this PRD. Note it as a follow-up idea: delay non-urgent wakes at night to cut overnight supervisor turns. Measure it against the wake ledger first.

## Coverage

| Dimension | Result | Findings |
| --- | --- | --- |
| Failure modes | Clock skew between senders; best-effort channels with no retry | A-EQ-2, A-EQ-4 |
| Token economics | No send or wake records to count | A-EQ-5, A-EQ-9 |
| Safety | Unlabelled Slack senders; no digest redaction; long holds unstated | A-EQ-1, A-EQ-6, A-EQ-7 |
| Duplicate ownership | A clock owned by a document; four separate dedupes | A-EQ-2, A-EQ-3 |
| Quota exhaustion | Not in scope; quota exceptions route through the gate like any other | none here |
| Restart loops | A supervisor restart repeats escalations | A-EQ-3 |
| Missed work | No digest in attended mode; reporting may be over-suppressed | A-EQ-4, A-EQ-8 |

## What holds up

- The definitions (lines 37-42) are clear and fit for testing once keys exist.
- EQ-14 (quiet hours never delay a local record, a wake, or a recovery action) is the right safety default.
- EQ-8's "quiet hours never pre-authorize" clause keeps destructive actions behind a human decision.
- The window in EQ-9 and EQ-10 matches the recorded standing decision. This review does not reopen it.
