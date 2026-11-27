# RSI loop 1

This page is the loop-1 record for recursive self-improvement of the Firstmate and AgentKit harnesses.
The change target is the harness: process, tools, memory, and review loops.
Model weights stay outside this loop.
`docs/documentation-audiences.json` classifies this page as maintainer verification.
The page stores the measurement method, the summary baselines, the missing instruments, the drafted goals, the council record, and the before/after summary.
Per-pull-request rows stay outside the repository.

## Baselines

Hermes reported these figures for the week of 20 Nov 2026 through 27 Nov 2026.
This page stores that summary only.

| Repository | Median open-to-merge | Target | Open pull requests older than 24 hours | Target |
| --- | --- | --- | --- | --- |
| Firstmate (`Pibomeister/firstmate`) | 15.99 hours | 12 hours or less | 22 of 27 | 16 or fewer |
| AgentKit (`Pibomeister/agent-kit`) | 2.34 hours | 2 hours or less | 1 of 2 | zero unexplained |

Review rounds per pull request are not instrumented.
Intervention-free completion is not instrumented.

## Measurement method

Every reading uses this method.
A later reading names its own window and its own snapshot time.
It does not copy the baseline summary forward as if it were a new sample.

The Firstmate repository is `Pibomeister/firstmate`.
The AgentKit repository is `Pibomeister/agent-kit`.

The baseline window is `merged_at` in `[2026-11-20T06:00:00Z, 2026-11-27T06:00:00Z)`.
That interval is midnight to midnight in America/Chicago, from 20 Nov 2026 through 27 Nov 2026, end exclusive.
The baseline open-pull-request counts are the Hermes snapshot at the end of that window.
A fresh reading counts the pull requests that are open at the measurement instant.

Open-to-merge duration is `merged_at` minus `created_at`, in hours.
The population is every pull request in that repository whose `merged_at` falls inside the window.
Sort the durations ascending.
When the count is odd, the median is the middle duration.
When the count is even, the median is the mean of the two middle durations.
A pull request that was held stays in the sample.
Held work is not merged to move this number.

The aged-open count uses one snapshot instant.
The denominator is every open pull request, including drafts.
The numerator is every open pull request whose `created_at` is more than 24 hours before that instant.
The report is the numerator, the denominator, and the phrase `numerator of denominator`.

Read `createdAt`, `mergedAt`, and `state` with `gh-axi` from the forge pull-request record.
Do not assemble a median from memory.
Keep the raw rows in the task proof directory.
This page receives the summary only.

## Missing instruments

### Review rounds per pull request

A review round is one completed review pass on a pull request.
The preferred source is the no-mistakes run bound to that pull request.
One round is one completed review step that returned a verdict.
When no run record exists, the fallback is one GitHub review submission whose state is `APPROVED`, `CHANGES_REQUESTED`, or `COMMENTED`.
Pending reviews do not count.
Empty submissions do not count.
For a window, record the round count on each merged pull request, then the median and the maximum of those counts.
This instrument does not exist yet.
Loop 1 adds it.

### Intervention-free completion

A completed ship is intervention-free when no steering message and no captain decision occurred between dispatch and a green pull request.
A captain merge approval after the pull request is already green stays outside this count.
The report for a window is intervention-free completions divided by completed ships.
This instrument does not exist yet.
Loop 1 adds it.

## Goals

Not drafted yet.

## Candidates

Not drafted yet.

## Council decision

Not convened yet.

## Before and after

Not measured yet.
