# Review: PR and check monitoring PRD (reviewer A)

- PRD: `docs/prd/supervision/pr-check-monitoring.md` at commit `8963bced`
- Reviewer: Opus 5.5 (`claude-opus-5-5`, reasoning effort xhigh)
- Review type: adversarial, independent of the other reviewer
- Verdict: **block**

## Summary

The PRD keeps monitoring read-only and never lets it merge, which is right.
Its central new feature, early conflict detection, is given to an owner that does not exist: discovery makes no forge read.
Adding that read where the PRD puts it would place network calls on the heartbeat path.
The PRD also has no plan for forge rate limits. At today's poll cadence a modest number of watches can use up a user token's hourly budget. Then every watch ends with an error at the same moment.
Two of its requirements describe behavior that already ships, and two of its gaps do not match the code.

Finding IDs use the prefix `A-PM-` so they do not collide with the PRD's own `PM-` requirement IDs.

## Findings

### A-PM-1. BLOCKING, high: forge rate-limit exhaustion ends every watch at once

- Dimension: failure modes, quota exhaustion, restart loops.
- Evidence:
  - Each watch polls every 30 seconds until success or a 24-hour deadline (`bin/fm-pr-check-watch.sh:19-21`).
  - Each poll makes two GitHub REST reads: the PR read in `current_head` (`:116-121`) and the check-runs read in `check_current` (`:126-132`).
  - That is 240 reads per hour per watch, and up to 5,760 reads per watch over a full deadline.
  - GitHub's documented primary REST limit for a user token is 5,000 requests per hour. So about 20 concurrent watches use 4,800 reads per hour before any worker, `gh-axi` call, or pipeline shares the same token.
  - "Any forge read error ... ends the watch with condition-error at once" (`:24-25`). PM-4 (line 46) keeps that rule.
- Failure scenario: many PRs are open at once across projects, and every agent shares one token. The token hits its limit. Every live watch reads an error on its next poll and ends. Each ending is a supervisor wake. Each re-arm restarts polling as soon as the limit resets, so the cycle repeats every hour.
- Smallest fix: add two requirements.
  - PM-13: "A rate-limit response (HTTP 403 or 429 with rate-limit headers) is transient. The watch backs off until the stated reset time and stays live. Only a non-transient error ends the watch."
  - PM-14: "Watch and discovery reads share a stated per-forge read budget, in reads per hour. Arming a watch over the budget is refused with a reason."
  - Add a drill: simulate a rate-limit response and confirm that no watch ends and no wake storm follows.

### A-PM-2. BLOCKING, high: the conflict-state owner does not exist, and the proposed place puts forge reads on the heartbeat path

- Dimension: duplicate ownership, token economics, failure modes.
- Evidence:
  - The ownership row (line 64) names "the forge read inside discovery".
  - `bin/fm-ready-pr-discovery.sh` reads only local no-mistakes state. It reuses "only the read-only no-mistakes axi listing/status/log interfaces" (`:19-22`) and makes no `gh-axi`, `gh`, or HTTP call.
  - The heartbeat runs discovery on every publish under a 60-second bound (`bin/fm-heartbeat.sh:683-694`), and the watcher publishes on its poll.
  - The fleet view runs discovery too (`bin/fm-fleet-view.sh:107-112`).
  - PM-6 (line 48) and OQ-PM-1 (line 104) ask for conflict state "without adding a second poll loop". Putting it inside discovery adds a forge read to every heartbeat publish and every fleet-view render.
- Failure scenario: ten ready PRs across the fleet mean ten forge reads per heartbeat publish. The publish slows toward its deadline, the heartbeat goes stale (see `heartbeat-health.md` HB-3), and the read budget from A-PM-1 drains faster.
- Smallest fix:
  - For a watched PR, take conflict state from the PR read that the watch already makes. GitHub's `/pulls/N` response carries `mergeable` and `mergeable_state`. That costs no extra read.
  - For a ready PR with no watch, name a separate throttled reader with a cache keyed on head and base. It re-reads only when the head or base moves, or at most once every M minutes.
  - Discovery reads that cache and stays local-only.
  - GitHub computes `mergeable` lazily and can return null. Map null to `unknown` under PM-8.

### A-PM-3. BLOCKING, medium: PM-11 cannot be tested without a shared incident key, and PM-5 repeats unchanged state

- Dimension: duplicate ownership, token economics.
- Evidence:
  - PM-11 (line 53) wants one wake per PR state change across the watch path and the discovery path. The PRD defines no key that the two paths share.
  - PM-5 (line 47) lists each ready run "once per heartbeat". As data in `heartbeat.json` that is fine. If it is surfaced each time, it breaks `escalation-quiet-hours.md` EQ-4 ("a repeated pass over an unchanged state sends nothing") and spends a supervisor turn per heartbeat.
- Smallest fix:
  - Define the incident key as (forge, repository, PR number, head, state).
  - Both paths write and check that key in the shared incident ledger (see the escalation review, finding A-EQ-3).
  - State that discovery surfaces only changes. The listing stays in the heartbeat as data.

### A-PM-4. BLOCKING: the token baseline is not measurable as written

- Dimension: token economics.
- Evidence:
  - The counters (line 98) are PR wake records per day, "manual PR state reads per day where recorded", and `model-calls.tsv` tokens.
  - Nothing records manual PR reads.
  - Wake rows are deleted on acknowledgement (`bin/fm-wake-drain.sh:898-913`).
  - `model-calls.tsv` holds only watchdog judge calls (`docs/watchdog.md:142`).
  - "Forge reads per watch per day from the watch records" (line 99) assumes the watch record counts reads. It does not, although the count follows from the poll cadence.
- Smallest fix: adopt the cross-PRD instrumentation (report issue A-X1). Add a forge-read counter per watch and per discovery run. That counter also enforces the PM-14 budget in A-PM-1.

### A-PM-5. NON-BLOCKING, medium: the queue and gate gap has no requirement, and the merge queue is not covered

- Dimension: missed work.
- Evidence: gap row 39 says queue position and gate waits have no reporting owner. The Purpose (line 5) promises to watch merge queues. No requirement, owner, or test covers either.
- Smallest fix: add one requirement with an owner, or drop the merge queue from the Purpose and move the gap to open questions.

### A-PM-6. NON-BLOCKING, medium: PM-2 and PM-12 already ship, and automatic rebinding is a safety risk

- Dimension: safety, failure modes.
- Evidence:
  - `check_current` already ends a watch with `head-moved` when the PR head changes (`bin/fm-pr-check-watch.sh:128`). So gap row 37 ("can leave a watch bound to an old head") does not match the code, and PM-2 is existing behavior.
  - `retire` already refuses an unhandled result (`:16`), which is PM-12.
  - OQ-PM-2 (line 105) asks how a watch could rebind after a rebase with no supervisor action. An automatic rebind would carry trust to a head that nobody chose to watch.
- Smallest fix:
  - Mark PM-2 and PM-12 as "keep" requirements in the capability table, and correct gap row 37.
  - Answer OQ-PM-2 with "no automatic rebind".
  - If a rebind is ever added, it must bind the same producer App ID, re-read from scratch, and never carry an old result.

### A-PM-7. NON-BLOCKING, low: a closed or merged PR keeps its watch polling

- Dimension: token economics, quota exhaustion.
- Evidence: the watch reads only `.head.sha` from the PR read (`bin/fm-pr-check-watch.sh:119`). It never checks whether the PR is open. A PR that closes without a terminal check result keeps costing 240 reads per hour until the 24-hour deadline.
- Smallest fix: read `state` and `merged` from the same PR response. End the watch with one record when the PR is closed or merged.

### A-PM-8. NON-BLOCKING, low: "wait time" is ambiguous

- Dimension: failure modes.
- Evidence: discovery's `waited` is "the run's age since creation ... not the time since it became ready" (`bin/fm-ready-pr-discovery.sh:26-28`). PM-5 and AT-PM-6 say "wait time" and "wait" without a definition.
- Smallest fix: define the field. Either keep run age and name it that, or add a separate ready-since time.

### A-PM-9. NON-BLOCKING, medium: drills push to a forge and must name a sandbox

- Dimension: safety.
- Evidence: DR-PM-2 pushes a new head during a watch. DR-PM-3 makes a ready PR conflict with its base. DR-PM-1 fails a check. On a real project those drills change shared state and may notify reviewers.
- Smallest fix: add one line: "Forge drills run against a sandbox repository with no protected branches and no subscribers, never against a registered project."

## Coverage

| Dimension | Result | Findings |
| --- | --- | --- |
| Failure modes | Rate limits end every watch; mislabelled gaps; an undefined wait | A-PM-1, A-PM-6, A-PM-8 |
| Token economics | Discovery reads on the heartbeat path; zombie watches; no counters | A-PM-2, A-PM-4, A-PM-7 |
| Safety | Monitoring stays read-only; rebind and drills need limits | A-PM-6, A-PM-9 |
| Duplicate ownership | A conflict owner that does not exist; no shared incident key | A-PM-2, A-PM-3 |
| Quota exhaustion | Forge read budget is the quota here, and it is unmanaged | A-PM-1, A-PM-7 |
| Restart loops | A re-arm storm after each rate-limit reset | A-PM-1 |
| Missed work | Queue and gate state unowned; unwatched ready PRs get no conflict state | A-PM-5, A-PM-2 |

## What holds up

- PM-10 (never merge, mark ready, respond to a gate, or push) matches discovery's read-only contract and the guarded merge path.
- PM-8 (`unknown`, never `clean`) is the right default.
- The ambiguous-producer rule (AT-PM-3) matches the existing watch.
- Every cited test suite exists: `tests/fm-pr-check-watch.test.sh` and `tests/fm-pr-check-security.test.sh`.
