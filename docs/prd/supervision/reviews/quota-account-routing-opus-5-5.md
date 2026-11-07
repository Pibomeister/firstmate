# Review: Quota and account routing PRD (reviewer A)

- PRD: `docs/prd/supervision/quota-account-routing.md` at commit `8963bced`
- Reviewer: Opus 5.5 (`claude-opus-5-5`, reasoning effort xhigh)
- Review type: adversarial, independent of the other reviewer
- Verdict: **block**

## Summary

The PRD keeps the right boundaries. The watchdog and the selection helper never move a worker, and only the control plane does.
It rests on one capability claim that the code does not support: that the relaunch rechecks quota eligibility.
It sets no limit on how often one task may move, so a task can bounce between runtimes, and each move pays a full worker startup.
It maps a harness to one provider, which the dispatch rules in `AGENTS.md` forbid.
It also leaves the quota-limited primary, and the wake at quota reset, without an owner.

Finding IDs use the prefix `A-QA-` so they do not collide with the PRD's own `QA-` requirement IDs.

## Findings

### A-QA-1. BLOCKING, high: no move budget, so a task can bounce between runtimes

- Dimension: restart loops, token economics, quota exhaustion.
- Evidence:
  - QA-4 (line 48) keeps a candidate with unmeasured headroom eligible.
  - QA-3 (line 47) excludes only candidates whose applicable runway is known to be exhausted.
  - No requirement limits moves per task, or blocks a return to a runtime that limited this task before its reset.
  - Each move stops one worker and cold-starts another. The new worker reloads its instructions and rebuilds context from the task copy.
- Failure scenario: task T hits its Claude limit and moves to a candidate whose headroom is unmeasured. That candidate shows its own limit on screen, and `quota-axi` cannot see that limit, so the candidate stays "eligible" under QA-4. T moves again, perhaps back toward a runtime whose snapshot row has refreshed. Every hop spends a supervisor wake and a full worker startup, and no work lands.
- Smallest fix: add QA-13.
  - "A task moves at most N times per reset window. The provisional default is 2."
  - "A task never returns to a runtime that limited it before that runtime's recorded reset."
  - "A task over budget queues under QA-9 and raises one escalation."
  - Add an acceptance test: two forced limits in a row end in a queue, not a third move.

### A-QA-2. BLOCKING, high: the relaunch does not recheck quota, and "the same snapshot" cannot catch a stale one

- Dimension: failure modes, safety.
- Evidence:
  - The capability row (line 29) says `bin/fm-control.sh relaunch --harness` "runs the same eligibility check".
  - The source sentence in `bin/fm-quota-reroute.sh:21-23` says the relaunch "runs the same check", meaning the Claude-tooling check. `docs/watchdog.md:84` uses the phrase the same way.
  - Before stopping the old agent, `bin/fm-control.sh:1310-1334` runs two checks: the harness-kind support check and the Claude-tooling check. It makes no `quota-axi` read and calls no eligibility helper.
  - QA-10 (line 54) rechecks "against the same snapshot". A recheck on unchanged input always returns the first answer, so it proves nothing.
  - AT-QA-5 (line 78) expects a stale snapshot to abort the move. QA-10 as written cannot detect staleness. The test and the requirement contradict each other.
  - QA-11 (line 55) leaves the old worker running after an abort. That worker is already at its quota floor, so it stays stuck.
- Failure scenario: selection runs at 09:00 on a snapshot from 08:40. By 09:05 the candidate's weekly window is exhausted. The relaunch "rechecks" the 08:40 snapshot, passes, stops the old worker, and starts a new one that hits its limit on its first turn.
- Smallest fix:
  - Correct the capability row: "relaunch runs the kind check and the Claude-tooling check; it does not read quota".
  - Rewrite QA-10: "Before it stops the old worker, the move takes a fresh quota read when the incident snapshot is older than the maximum snapshot age. The new read is recorded under the incident."
  - Close OQ-QA-2 with a provisional maximum snapshot age. The watchdog's `quota-secs` (600) is a ready candidate.
  - Rewrite QA-11: "A failed recheck reselects once. If the reselect also fails, the task queues under QA-9. The old worker is never left on a floor with no record."

### A-QA-3. BLOCKING, high: one primary provider per harness is an inference that `AGENTS.md` forbids

- Dimension: failure modes, quota exhaustion.
- Evidence:
  - `bin/fm-quota-choose.sh:10-12` "maps `<harness>` to its primary provider family" and applies that family's quota rows.
  - `AGENTS.md` section 4 requires the provider family to come from the harness's own authoritative catalog. It says to never infer a provider family from a harness or model name.
  - Some verified harnesses serve models from more than one provider family. Their quota row depends on the chosen model, not on the harness.
  - The PRD names this as gap G1 (line 37) and OQ-QA-1 (line 107). No requirement closes it.
- Failure scenario: a candidate `harness:model` on a multi-provider harness is checked against the harness's primary provider, which has headroom. The model's real provider is exhausted. The move lands on an exhausted account.
- Smallest fix: add QA-14.
  - "The provider family of each candidate comes from the harness's catalog entry for that model."
  - "When the catalog cannot prove it, the candidate's headroom is unmeasured under QA-4, and the record says why."
  - With A-QA-1's budget in place, a wrong guess costs at most one move.

### A-QA-4. BLOCKING, medium: "one snapshot per incident" has no store, and three readers capture quota on their own

- Dimension: duplicate ownership, token economics.
- Evidence:
  - The ownership row for quota evidence (line 62) names a snapshot "captured at intake or at detection". That is two capture points for one signal.
  - The heartbeat makes one `quota-axi` read per run (`bin/fm-heartbeat.sh:642`), and the watcher publishes the heartbeat on its poll.
  - The watchdog keeps its own snapshot file and its own candidate list. It reads `reroute-candidates` from its config and passes them to `bin/fm-quota-reroute.sh suggest` (`bin/fm-watchdog.sh:1069-1122`; `docs/watchdog.md:212`).
  - Dispatch intake takes its own `quota-axi` read (`AGENTS.md` section 4).
  - QA-1, QA-2, and QA-12 refer to "the snapshot" but name no file, no incident key, and no retention.
- Failure scenario: the watchdog names candidate X from its snapshot and its own list. The supervisor runs `suggest` on a fresh read with the dispatch list and gets Y. The move record (QA-12) cannot say which evidence authorized the move. That is exactly gap G4 (line 40).
- Smallest fix:
  - Name one snapshot store, such as one file per incident, written once at detection.
  - The detection gap, the `suggest --snapshot` call, the relaunch recheck, and the move record all reference that file by path or digest.
  - Name one candidate list for the supervisor path, and state how it relates to the watchdog's `reroute-candidates`.
  - The heartbeat's allowance figure is display-only and never authorizes a move.

### A-QA-5. BLOCKING, medium: a quota-limited primary has no owner in any PRD

- Dimension: quota exhaustion, missed work.
- Evidence:
  - Scope (line 11) covers ship, scout, and second mate workers only.
  - For the home pane, the watchdog's quota rows write a ledger row and a gap that names a candidate. They never change the runtime (`docs/watchdog.md:77-88`).
  - A Claude primary cannot move off Claude, because every home tracks `.claude/` material (line 27). Account pins are captain-only (`AGENTS.md` section 4).
  - `heartbeat-health.md` reports such a primary as `ok` (see the heartbeat review, finding A-HB-10).
- Failure scenario: the primary hits its limit during quiet hours. Health reads `ok`. Wakes queue, and nothing reports that supervision is paused until the reset.
- Smallest fix: add a scope line and one requirement. "A quota-limited primary raises one exception that names the reset time and the account-pin decision. It is never moved by automation." Wakes stay durable, so nothing is lost. The cost is the delay, and the delay must be visible.

### A-QA-6. NON-BLOCKING, medium: the "account" half of the title is out of scope, and the PRD should say so

- Dimension: safety.
- Evidence: changing account pins is out of scope (line 13). `bin/fm-quota-reroute.sh:62` excludes a pinned account's whole harness from `suggest`. So no requirement in this PRD routes between accounts.
- Smallest fix: state plainly that this PRD never switches accounts, and that a pinned harness at its floor queues and escalates for a pin decision. Or rename the PRD to "Quota runtime routing".

### A-QA-7. NON-BLOCKING, medium: the ranking rule among eligible candidates is unstated

- Dimension: failure modes.
- Evidence:
  - `bin/fm-quota-choose.sh:2` and `:17` print the first eligible candidate in list order.
  - New-work dispatch ranks with `spendPriority` under the `quota-array-dispatch` skill (`AGENTS.md` section 4).
  - QA-2 says "at most one replacement" but not how it is picked.
- Smallest fix: state the ranker. Use either the `spendPriority` procedure or the configured list order, with the reason for the choice. State it once, for both the watchdog path and the supervisor path.

### A-QA-8. BLOCKING: the token baseline is not measurable as written, and the cost of a move is not counted

- Dimension: token economics.
- Evidence:
  - The counters (line 101) are quota wakes per day, moves per week, and `model-calls.tsv` tokens.
  - Wake rows are deleted on acknowledgement (`bin/fm-wake-drain.sh:898-913`), so quota wakes per day has no durable source.
  - `model-calls.tsv` holds only watchdog judge calls (`docs/watchdog.md:142`). It is absent when judge models are off.
  - No move record exists yet (QA-12 creates it), so moves per week has no baseline window.
  - A move costs a supervisor turn plus a full worker startup. None of the counters sees either cost.
- Smallest fix: adopt the cross-PRD instrumentation in the report (issue A-X1). Count each move's worker startup tokens from transcript usage where the harness records it, and report `unknown` otherwise. Start the before-window only after the counters exist.

### A-QA-9. NON-BLOCKING, medium: no owner wakes queued work at reset

- Dimension: missed work.
- Evidence: QA-9 (line 53) queues a task "until reset with the reset evidence recorded". Nothing schedules the re-check. Queued work is re-evaluated after teardowns and heartbeats (`AGENTS.md` section 10). When the fleet is quiet, heartbeat wakes back off to as long as 7200 seconds.
- Failure scenario: the reset passes at 03:00. The next heartbeat wake comes up to two hours later, so the task waits with headroom available.
- Smallest fix: record the reset time as the backlog item's time gate, so the backlog re-evaluation picks it up. Or name the heartbeat as the owner and accept the bound in writing.

### A-QA-10. NON-BLOCKING, low: QA-8 asks for a per-harness path but does not give it

- Dimension: failure modes.
- Evidence:
  - Today, `bin/fm-control.sh:100-118` refuses a pane-text usage-limit verdict, because that classifier is not live-verified.
  - It closes a Grok weekly-limit composer by destroying the endpoint.
  - `bin/fm-quota-reroute.sh:16-17` queues on an unknown signal.
  - QA-8 (line 52) asks for "one stated path per harness" but the PRD states none.
- Smallest fix: write the table now, one row per verified harness, with its current path. The open question then becomes which rows to change.

### A-QA-11. NON-BLOCKING, medium: drills must name an isolated environment

- Dimension: safety.
- Evidence: DR-QA-5 kills a new worker mid-relaunch. DR-QA-1 through DR-QA-4 run real relaunches. None names where they run.
- Smallest fix: add one line: "Drills run on a fixture home with fixture snapshots and a private tmux socket or a named, non-default Herdr lab, never on live workers."

## Coverage

| Dimension | Result | Findings |
| --- | --- | --- |
| Failure modes | The recheck cannot detect staleness; provider inference; no stated ranker | A-QA-2, A-QA-3, A-QA-7, A-QA-10 |
| Token economics | Move cost is not counted; the baseline counters do not exist | A-QA-8, A-QA-1 |
| Safety | Boundaries hold; account scope is unstated; drills lack isolation | A-QA-6, A-QA-11 |
| Duplicate ownership | Three quota readers and two candidate lists | A-QA-4 |
| Quota exhaustion | Unmeasured candidates stay eligible without a budget; the primary is unowned | A-QA-1, A-QA-3, A-QA-5 |
| Restart loops | Moves have no budget | A-QA-1 |
| Missed work | No wake at reset; a quota-limited primary is invisible | A-QA-5, A-QA-9 |

## What holds up

- The rule that only the control plane moves a worker matches the code. The watchdog and `suggest` never relaunch (`bin/fm-quota-reroute.sh:58-60`).
- QA-5 and QA-6 match the Claude-tooling rule and the second mate backend rule.
- QA-7 (preserve the task copy and its uncommitted work) matches hard rule 3.
- Every cited test suite exists: `tests/fm-quota-choose.test.sh` and `tests/fm-procevent-quota.test.sh`.
