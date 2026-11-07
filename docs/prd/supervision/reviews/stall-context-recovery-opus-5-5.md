# Review: Stall and context recovery PRD (reviewer A)

- PRD: `docs/prd/supervision/stall-context-recovery.md` at commit `8963bced`
- Reviewer: Opus 5.5 (`claude-opus-5-5`, reasoning effort xhigh)
- Review type: adversarial, independent of the other reviewer
- Verdict: **block**

## Summary

The PRD names a real state, `input-swallowed`, and asks the right question about which context reading acts.
It misses the largest cost in this area: session turnover.
Each primary handoff pays a full startup load, and nothing measures or budgets that load.
It also leaves two successor launchers and up to three predecessor enders without one owner.
It lists two context readings where four exist.
And it gives the swallow signal to a component that cannot see or touch the sessions where the example happens.
The Stage 2 order adds a turnover acceptance requirement. Finding A-SC-1 states it, because no PRD covers it.

Finding IDs use the prefix `A-SC-` so they do not collide with the PRD's own `SC-` requirement IDs.

## Findings

### A-SC-1. BLOCKING, high: context turnover cost is not bounded, measured, or tested

- Dimension: token economics, restart loops.
- Requirement source: the Stage 2 order. A primary that hands off more than once an hour is a cost issue. The order reports two primary handoffs within about an hour on 2026-11-06. It requires four things: a bounded and measured startup and context load, a cap on handoff document size, no hourly startup churn under normal load, and an N-hour away-mode acceptance test measured against a baseline.
- Evidence in the PRD: no requirement, acceptance test, or token-economics counter covers startup load, handoff size, or handoff rate. The token section (lines 123-129) counts only stall wakes, watchdog restarts, and judge tokens.
- Evidence in code:
  - `bin/fm-startup-memory-budget.sh:7-9` reports a "stable local estimate" for three files only: `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md`. It is a byte estimate, not a token measurement.
  - `bin/fm-startup-growth-check.sh` is a daily byte-size check.
  - Neither tool counts the largest startup inputs. Those are `AGENTS.md` (about 55.6 KB at this commit, loaded into every session), the session-start digest, session-start hook output, and the handoff document.
  - Transcript usage is already readable. `fm_warm_compact_context_tokens` (`bin/fm-warm-compact-lib.sh:65`) sums `input + cache_read + cache_creation` for the handoff trigger.
- Evidence measured on one operating home, 2026-11-06, from local transcript usage (Claude primaries only):
  - Context at the first assistant turn grew from about 74,500 tokens (2026-11-02) to about 82,200 tokens (2026-11-06).
  - The session-start digest added about 8,000 to 23,000 tokens in 11 of 13 sampled sessions. That puts the typical post-startup context at 85,000 to 100,000 tokens.
  - Sessions ran to 185,000 to 215,000 tokens before their handoffs. That fits a compaction point of about 217,000 tokens (a 250,000-token window minus the 20,000 and 13,000 reserves, `bin/fm-handoff-trigger.sh:1-60`).
  - So startup used about 40 percent of the usable context before any work began. The working room before the 15 percent trigger was about 94,000 tokens.
  - Eight handoff documents were written between 00:37 and 18:00 local time. Session lengths ranged from about 0.5 to 5 hours, and most were 2 to 3 hours.
  - Handoff documents had a median size of about 5.2 KB (largest 26 KB). That is about 1,300 tokens, small next to the fixed startup load.
- Consequence: turnover is set mostly by the fixed startup load, not by the work. Each 10,000 tokens added to startup cuts about 10 percent of each session's working room and raises the handoff rate. A cap on handoff documents alone will not move the cost much. The fixed prefix and the digest are the main levers.
- Smallest fix: add four requirements and one acceptance test.
  - SC-15: Each primary session start writes one ledger row. The row holds the session id, harness, context tokens at the first turn, context tokens after the digest, and the handoff document's byte size. The values come from transcript usage, not from estimates. A harness with no usage record reports `unknown`.
  - SC-16: A startup token budget lives in one config owner. Extend `config/startup-memory-budget` or add one key next to it. The budget covers everything the session loads before its first work action. Session start reports a breach once.
  - SC-17: A handoff document has a size cap. The cap is enforced where the handoff is recorded (`bin/fm-order.sh handoff --doc`). A document over the cap is refused or trimmed with a warning.
  - SC-18: Under normal load, a primary hands off no more than a target number of times per N hours. A session start less than a minimum interval after the previous one writes one churn record.
  - AT-SC-11: Run an N-hour away-mode soak on a fixture or live home. It passes when handoffs are at or below the target and every startup is at or below the budget. Both are compared with a measured baseline window taken before the change.
  - Set provisional numbers now so the test can run. They can be tuned after the baseline window.

### A-SC-2. BLOCKING, high: two successor launchers and three predecessor enders, with no single owner

- Dimension: duplicate ownership, restart loops, missed work.
- Evidence:
  - Since Firstmate PR #156, the predecessor launches its own successor and records it in `state/.handoff-successor` (`bin/fm-handoff-trigger.sh:172-185`).
  - The gate text (`:181`) says the predecessor "cannot exit itself". It is ended "by the captain, by a leash or operator /exit in its pane, or by the watchdog restart path". The successor waits for the predecessor's pid to die before session start.
  - The watchdog restart path launches a successor too. It fires on a restart request or on context at or below `restart-at-percent` 8 (`bin/fm-watchdog.sh:1401`).
  - Neither `bin/fm-watchdog.sh` nor `bin/fm-watchdog-lib.sh` reads `state/.handoff-successor`.
  - The ownership row for restart execution (line 92) names the watchdog restart path for primaries. That contradicts the self-launch from PR #156.
- Failure scenario A (two successors): a Claude primary at 15 percent left launches successor S1. Its context keeps falling while it finishes the handoff. At 8 percent left, the watchdog restart path ends it and launches S2. Two successors race for the lock. One wins. The other pays a full startup (A-SC-1: about 90,000 tokens) and may act on the same handoff document.
- Failure scenario B (no ender): the watchdog is off (the documented default), the home is away, and no external ender is set up. S1 waits for a predecessor that cannot exit itself. Neither session works. Queued wakes wait until a human acts.
- Smallest fix:
  - Name one launch owner: the predecessor's self-launch from PR #156.
  - When `state/.handoff-successor` names a live pid that is newer than the handoff marker, the watchdog restart path only ends the predecessor. It never launches a second successor.
  - Name one ender per home configuration. When no ender is configured, the successor's wait has a bound. At that bound it writes one blocked record instead of waiting forever.
  - Add acceptance tests. One: a full handoff produces exactly one successor and one lock holder. Two: a home with no ender produces one blocked record within the bound.

### A-SC-3. BLOCKING, high: four context readings exist, not two, and the restart reading for a Claude primary is unstated

- Dimension: duplicate ownership, failure modes.
- Evidence:
  - Reading 1, the pane footer: `bin/fm-context-footer-lib.sh` calls itself the "Single owner of the external auto-compact footer parse". The heartbeat and `fm-context-burn.sh` use it. It rejects values above 100.
  - Reading 2, a second footer parser: `fm_wd_footer_percent` (`bin/fm-watchdog-lib.sh:339-344`) reads only the last 10 rows. It allows any whitespace after `auto-compact:` and has no guard against values above 100. The watchdog uses it (`bin/fm-watchdog.sh:415-416`) when the heartbeat value is missing, belongs to another session, or is older than `watcher-stale-secs` (`:371-373`).
  - Reading 3, the derived transcript value: the handoff trigger computes it (`bin/fm-handoff-trigger.sh:1-60`).
  - Reading 4, the status line's `remaining_percentage`: it measures the full model window, not the compaction point. For a 1M-token model with a 250,000-token compaction window, it still shows about 78 percent at compaction time (`bin/fm-handoff-trigger.sh:14-17`).
  - The watchdog restart path acts at 8 percent or less on readings 1 or 2 (`bin/fm-watchdog.sh:1401`), including for a Claude primary that also has reading 3. SC-8 (line 75) covers only sessions with no derived reading, so this case has no rule. Gap row 41 names the conflict, and no requirement closes it.
- Failure scenario: the footer shows 7 percent while the derived value shows 20 percent. The watchdog restarts a session that the handoff trigger still considers healthy. A second case: an operator or a future reader trusts the status-line value and sees 78 percent at the moment of compaction.
- Smallest fix:
  - List all four readings in the table (lines 56-59).
  - State that the status-line value is display-only and never acts.
  - Require the watchdog to source `bin/fm-context-footer-lib.sh` and drop its own parser.
  - Add a table of acting path by harness. For a Claude primary, the derived reading owns both the handoff and the restart decision. The footer reading acts only where no derived reading exists.

### A-SC-4. BLOCKING, high: the swallow owner cannot see or act on the sessions in the example

- Dimension: duplicate ownership, failure modes.
- Evidence:
  - The ownership row (line 88) names `bin/fm-watchdog.sh`.
  - The watchdog never nudges or restarts worker panes (`docs/watchdog.md:34`). It reads only the Claude transcript layout (`docs/watchdog.md:66`).
  - The PRD's own example of the state is a Codex session (line 48).
  - SC-6 (line 73) restarts through `bin/fm-control.sh`. That script takes a `<task-id>` (`bin/fm-control.sh:5-7`), so it acts on workers and second mates, not on primaries.
  - Worker steers already have an owner for "delivered but never acted on". The steering inbox re-ring ladder (`bin/fm-task-inbox-lib.sh:60-79`) re-rings an unacknowledged message and escalates after `FM_TASK_INBOX_RING_MAX` attempts. A worker that accepts input and starts no turn never acknowledges, so it reaches that ladder.
  - The word "swallow" already has another meaning in the code. `bin/fm-composer-lib.sh:2664` calls Enter that was not accepted a "genuine swallow", where the text is still pending. The PRD's state is the reverse: the input was accepted and no turn started.
- Failure scenario: a Codex worker accepts a steer and shows a working indicator with no turn. The watchdog never sees it. The inbox ladder escalates on its own schedule. If the watchdog is later extended to workers, both paths escalate the same incident.
- Smallest fix:
  - Split the owner by subject. For workers, the inbox ladder owns detection. Its escalation reaches firstmate, which uses `bin/fm-control.sh relaunch`. For primaries, the watchdog owns detection, and only for harnesses whose turn-start signal is proven (OQ-SC-3).
  - Until a harness's turn signal is proven, its state is `unknown`, in the same way as SC-10.
  - Rename the state, or define it against the existing "unsent input" row and the composer's "swallow", so one word has one meaning.

### A-SC-5. BLOCKING, medium: the post-stop successor recheck has no owner

- Dimension: missed work, duplicate ownership.
- Evidence:
  - SC-12 and SC-13 (lines 79-80) require one recheck after the predecessor stops, and a blocked record "for the parent supervisor".
  - After the stop, the predecessor is gone and the successor is the subject. A primary has no parent supervisor.
  - The watchdog's pickup check (`pickup-secs` 600, `docs/watchdog.md:107-115`) covers only restarts the watchdog itself started.
  - `heartbeat-health.md` HB-4 already reports a dead or absent lock owner. That PRD has its own gap for the `none` state (see the heartbeat review, finding A-HB-7).
- Failure scenario: the successor dies right after the predecessor stops. No component is assigned to run the recheck, so no blocked record appears.
- Smallest fix: replace SC-12 and SC-13 with a pointer. "A successor that does not hold the lock within `pickup-secs` after the predecessor stops is a `dead` home under `heartbeat-health.md`. That PRD owns the escalation." Second mates keep their parent's relaunch path.

### A-SC-6. BLOCKING: the token baseline is not measurable as written

- Dimension: token economics.
- Evidence:
  - "Stall-related wake records per day" has no durable source. Wake rows are deleted on acknowledgement (`bin/fm-wake-drain.sh:898-913`).
  - `state/watchdog/actions.tsv` exists only on homes where the watchdog runs. On the operating home it holds only two days of rows.
  - `state/watchdog/model-calls.tsv` holds only watchdog judge calls (`docs/watchdog.md:142`) and is absent when judge models are off.
  - Transcript usage, the one measurable token source (A-SC-1), is not named.
- Smallest fix: adopt the cross-PRD instrumentation (report issue A-X1). Name the startup ledger from A-SC-1 as a counter. Count restarts from one restart ledger shared by every restarter.

### A-SC-7. NON-BLOCKING, medium: a stall restart costs a full startup and should count toward the turnover budget

- Dimension: token economics, restart loops.
- Evidence: SC-6 restarts after one failed nudge. At the measured load, every restart pays about 85,000 to 100,000 context tokens before work resumes (A-SC-1).
- Smallest fix: count each stall restart against the turnover budget in SC-18. Prefer a handoff over a cold restart when the session can still write one.

### A-SC-8. NON-BLOCKING, medium: no guard against a handoff loop when startup load reaches the trigger point

- Dimension: restart loops.
- Evidence: the trigger claims one firing per context cycle (`bin/fm-handoff-trigger.sh`, the noclobber marker). Each new session is a new cycle. If startup load ever reaches the trigger point, for example after `AGENTS.md` or the digest grows or a model with a smaller window is used, a new session fires its handoff on its first turns. Its successor then does the same.
- Smallest fix: add to SC-16: "A session whose post-startup context already sits at or below the trigger threshold writes one over-budget record and does not fire the handoff trigger."

### A-SC-9. NON-BLOCKING, low: the swallow and disagreement bounds have no provisional defaults

- Dimension: failure modes.
- Evidence: SC-2 requires one config owner for the swallow bound but sets no value. OQ-SC-1 and OQ-SC-2 leave both bounds open. Without values, AT-SC-1 and AT-SC-6 cannot run.
- Smallest fix: set provisional defaults now. Add a calibration step that reads first-turn latency per harness from existing transcripts or status records.

### A-SC-10. NON-BLOCKING, low: the fast-burn alert is an escalation path the PRD does not list

- Dimension: duplicate ownership.
- Evidence: Firstmate PR #102 alerts on fast context burn (line 32). The escalation section (lines 117-121) lists only failed recoveries and failed successor checks.
- Smallest fix: list the fast-burn alert as an exception or a routine record under `escalation-quiet-hours.md`, with its incident key.

### A-SC-11. NON-BLOCKING, medium: drills must name an isolated environment

- Dimension: safety.
- Evidence: DR-SC-4 kills a successor. DR-SC-1 and DR-SC-2 suppress turn starts in a test session. None names where it runs.
- Smallest fix: add one line: "Every drill runs on a fixture home with a private tmux socket or a named, non-default Herdr lab, never on a live home."

## Coverage

| Dimension | Result | Findings |
| --- | --- | --- |
| Failure modes | Four readings, one undefined restart reading, a mis-owned swallow signal | A-SC-3, A-SC-4, A-SC-9 |
| Token economics | Turnover cost is not covered; the baseline counters do not exist | A-SC-1, A-SC-6, A-SC-7 |
| Safety | SC-14 holds; drills lack isolation | A-SC-11 |
| Duplicate ownership | Two launchers, three enders, two footer parsers, two swallow paths | A-SC-2, A-SC-3, A-SC-4, A-SC-10 |
| Quota exhaustion | Not in scope; a quota-limited primary is covered in the quota review (A-QA-5) | none here |
| Restart loops | Double successor; possible handoff loop; stall restarts outside any budget | A-SC-2, A-SC-7, A-SC-8 |
| Missed work | Successor deadlock with no ender; an unowned post-stop recheck | A-SC-2, A-SC-5 |

## What holds up

- SC-4 (a running turn is never a stall) is the right default and matches the watchdog's quiet-pane rule.
- SC-10 (a missing reading never triggers a restart) is the right default.
- SC-14 (never discard uncommitted work or remove a worktree) matches hard rule 3.
- Every cited test suite exists: `tests/fm-handoff-trigger.test.sh` and `tests/fm-crew-state.test.sh`.
