# RSI loop 1

This page is the loop-1 record for recursive self-improvement of the Firstmate and AgentKit harnesses.
The change target is the harness: process, tools, memory, and review loops.
Model weights stay outside this loop.
`docs/documentation-audiences.json` classifies this page as maintainer verification.
The page stores the measurement window, the summary baselines, the drafted goals, the council result, and the before/after summary.
Per-pull-request rows stay outside the repository.
`bin/fm-rsi-measure.sh` owns the calculation.

## Baselines

Hermes reported these figures for the week of 20 Nov 2026 through 27 Nov 2026.
This page stores that summary only.
The command re-read of the same window is in Before and after.
That re-read does not replace this table.

| Repository | Median open-to-merge | Target | Open pull requests older than 24 hours | Target |
| --- | --- | --- | --- | --- |
| Firstmate (`Pibomeister/firstmate`) | 15.99 hours | 12 hours or less | 22 of 27 | 16 or fewer |
| AgentKit (`Pibomeister/agent-kit`) | 2.34 hours | 2 hours or less | 1 of 2 | zero unexplained |

## Measurement method

Every reading uses the same command and names its own snapshot time.
The baseline window is `merged_at` in `[2026-11-20T06:00:00Z, 2026-11-27T06:00:00Z)`.
That interval is midnight to midnight in America/Chicago, from 20 Nov 2026 through 27 Nov 2026, end exclusive.
The command calls the open-to-merge duration open-to-land.
The script header owns that calculation, the aged-open rule, the class order, and the two instrument counts.
A caller reads forge records with `gh-axi` and passes one JSON file.
The command does not contact a forge.
Held work stays in the sample.
This loop does not land a pull request to move a figure.

Review rounds in this loop's reading are the forge fallback.
One round is one submission whose state is `APPROVED`, `CHANGES_REQUESTED`, or `COMMENTED`.
The no-mistakes review-step source was not joined, so this count is not that source.
Intervention fields were left null.
The forge record does not carry steering messages or captain decisions.
The command keeps a null instrument field out of the rate.

The window-end open set is every pull request created before `2026-11-27T06:00:00Z` that was not closed before that instant.
A pull request that was closed and later reopened is outside that reconstruction.
Class fields for that set were left null, because the forge does not keep the check state from that instant.
The live class lines use the later snapshot, where unknown mergeability was read again from the pull-request record before the class was assigned.
A null status rollup was passed as zero reported checks.

## Goals

G1. Firstmate median open-to-land time is 12 hours or less.
G2. The Firstmate aged-open count is 16 or fewer.
G3. AgentKit median open-to-land time is 2 hours or less.
G4. AgentKit aged-open rows whose class is unexplained are zero.
G5. Each window reports the review-round median and the maximum.
G6. Each window reports intervention-free completion, and a null field stays missing.

## Candidates

Option A is `bin/fm-rsi-measure.sh`.
It prints the median, the aged-open fraction, one class per aged-open row, the review-round median and maximum, and the intervention-free counts.
Option B would only mark the review cap of 3 that is already on the default branch.
Option C would only read steering and decision records.
Option A is the drafted recommendation.
It is not a council pick.
Options B and C leave the aged-open pile unclassified.
At the 2026-11-27T20:02:45Z snapshot, 13 of the 23 aged Firstmate pull requests are conflicts.
That count is input for loop 2.
It is not a reason to change the command this loop ships.

## Council decision

`bin/fm-watchdog.sh council --help` exits 2.
Its message is `fm-watchdog: unknown council option: --help`.
`bin/fm-watchdog.sh --help` exits 0 and prints `council --task <id> --key <key> [--home <path>] [--record-file <file>] [--revisit]`.
That form has no switch that selects a live convening.
The same help text says dry-run never returns an answer.
A live convening requires the home `decisions` value to be `act`.
An unset `decisions` follows `mode`.
The shared home config is `mode=dry-run` and has no `decisions` key.
The council command therefore returns dry-run and calls no seats.
On the goals and the three options it printed `council=dry-run answer=none record=none prior=0 seats=none`.
A live convening would call seats `claude:sonnet` and `agy:gemini-4-argon-high`.
That call would spend, and this loop's limits forbid spend.
This task does not change the shared watchdog config.
No council pick exists.
There is no ruling path.
Option A remains the drafted recommendation this branch implemented.

## Before and after

Both command readings use the baseline window.
The live open snapshot is `2026-11-27T20:02:45Z`.
The median matches the Hermes summary on both readings.
This loop does not land pull requests, so that match is a re-read, not an effect of the new command.

| Reading | Firstmate median | AgentKit median | Firstmate aged open | AgentKit aged open |
| --- | --- | --- | --- | --- |
| Hermes summary | 15.99 hours | 2.34 hours | 22 of 27 | 1 of 2 |
| Command at `2026-11-27T06:00:00Z` | 15.99 hours, n=28 | 2.34 hours, n=13 | 23 of 28 | 1 of 2 |
| Command at `2026-11-27T20:02:45Z` | 15.99 hours, n=28 | 2.34 hours, n=13 | 23 of 29 | 0 of 1 |

One Firstmate row separates the reconstructed window-end count from the Hermes 22 of 27.
The command does not adjust either figure to force a match.
AgentKit's window-end aged-open count matches the Hermes 1 of 2.

At `2026-11-27T20:02:45Z` the 23 aged Firstmate rows class as 13 conflict, 9 pending-checks, and 1 draft.
None of those rows is unexplained.
The one open AgentKit row is younger than 24 hours, so it has no class line.
Window-end class lines are not listed here, because those class fields were null.

Forge review submissions for the window:
Firstmate median 0.00, maximum 1, n=28, missing 0.
AgentKit median 0.00, maximum 0, n=13, missing 0.
Intervention-free completion is missing for all 28 Firstmate rows and all 13 AgentKit rows.
That missing count is not a rate of zero.

No AgentKit code change is in this loop.
The command reads caller-supplied rows for any repository.
Joining no-mistakes review steps, and calling the command from the goal digest, are later work.
