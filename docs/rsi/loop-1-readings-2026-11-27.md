# Loop 1 readings on 2026-11-27

This file is the end-of-day command reading for the baseline window in `docs/rsi/loop-1.md`.
`docs/documentation-audiences.json` classifies this page as maintainer verification.
The before figures are the Hermes summary and the two command rows already on that page.
This reading does not replace those rows.
`docs/rsi/loop-1.md` has no empty after cell, so that page is unchanged.

## Command

The snapshot instant is `2026-11-27T23:27:43Z` (`--now 1795822063`).
The window is `merged_at` in `[2026-11-20T06:00:00Z, 2026-11-27T06:00:00Z)`.
Both commands were read-only.
The instrument command wrote its object to stdout, and that object was the measure input.
Its SHA-256 is `343c2406b08ee13a2da1c4a0d652cc75d47e015f7d572f9dcc7c6d8557fc759c`.

```
bin/fm-rsi-instrument.sh --input /Users/eduardopicazo/orca/projects/firstmate/data/fm-rsi-loop1-measure/forge-input.json --home /Users/eduardopicazo/orca/projects/firstmate --nm-db /Users/eduardopicazo/.no-mistakes/state.sqlite
bin/fm-rsi-measure.sh --input /Users/eduardopicazo/orca/projects/firstmate/data/fm-rsi-loop1-measure/instrument-output.json --now 1795822063 --window-start 2026-11-20T06:00:00Z --window-end 2026-11-27T06:00:00Z
```

The forge file has 28 merged Firstmate rows, 13 merged AgentKit rows, 30 open Firstmate rows, and 2 open AgentKit rows.
Merged rows are the search `repo:<owner>/<name> is:pr is:merged merged:2026-11-19..2026-11-27`, kept only when `merged_at` is inside the window.
A forge review round is one submission whose state is `APPROVED`, `CHANGES_REQUESTED`, or `COMMENTED`.
Open rows are the search `repo:<owner>/<name> is:pr is:open` at the snapshot.
`conflict` is true when `mergeable` is `CONFLICTING` and false when it is `MERGEABLE`.
No open row was still `UNKNOWN` after a re-read.
`changes_requested` is true when `reviewDecision` is `CHANGES_REQUESTED`.
A null status rollup is `failing_checks` 0, `pending_checks` 0, and `reported_checks` 0.
A completed check run counts as failing when its conclusion is `FAILURE`, `TIMED_OUT`, `STARTUP_FAILURE`, or `ACTION_REQUIRED`.
A check run whose status is not `COMPLETED` counts as pending.
A status context counts as failing for `FAILURE` or `ERROR`, and as pending for `PENDING` or `EXPECTED`.
Every context counts as reported.
`bin/fm-rsi-instrument.sh` then replaced a forge review count where a no-mistakes run named the pull request and its review step ran.

## Raw output

```
median repo=Pibomeister/agent-kit hours=2.34 n=13
aged repo=Pibomeister/agent-kit numerator=0 denominator=2
review_rounds repo=Pibomeister/agent-kit median=0.00 max=13 n=13 missing=0
intervention_free repo=Pibomeister/agent-kit free=0 completed=0 missing=13
median repo=Pibomeister/firstmate hours=15.99 n=28
aged repo=Pibomeister/firstmate numerator=24 denominator=30
review_rounds repo=Pibomeister/firstmate median=3.00 max=23 n=28 missing=0
intervention_free repo=Pibomeister/firstmate free=0 completed=1 missing=27
class repo=Pibomeister/firstmate number=231 class=conflict age_hours=381.45
class repo=Pibomeister/firstmate number=250 class=conflict age_hours=317.41
class repo=Pibomeister/firstmate number=276 class=pending-checks age_hours=241.77
class repo=Pibomeister/firstmate number=279 class=conflict age_hours=240.86
class repo=Pibomeister/firstmate number=281 class=conflict age_hours=236.59
class repo=Pibomeister/firstmate number=282 class=conflict age_hours=235.49
class repo=Pibomeister/firstmate number=283 class=conflict age_hours=234.76
class repo=Pibomeister/firstmate number=291 class=pending-checks age_hours=193.87
class repo=Pibomeister/firstmate number=292 class=conflict age_hours=193.13
class repo=Pibomeister/firstmate number=295 class=conflict age_hours=191.19
class repo=Pibomeister/firstmate number=296 class=conflict age_hours=190.79
class repo=Pibomeister/firstmate number=297 class=conflict age_hours=190.15
class repo=Pibomeister/firstmate number=301 class=pending-checks age_hours=188.05
class repo=Pibomeister/firstmate number=302 class=pending-checks age_hours=185.88
class repo=Pibomeister/firstmate number=303 class=conflict age_hours=182.12
class repo=Pibomeister/firstmate number=305 class=conflict age_hours=176.56
class repo=Pibomeister/firstmate number=311 class=pending-checks age_hours=170.56
class repo=Pibomeister/firstmate number=324 class=pending-checks age_hours=129.35
class repo=Pibomeister/firstmate number=326 class=draft age_hours=82.87
class repo=Pibomeister/firstmate number=333 class=conflict age_hours=65.56
class repo=Pibomeister/firstmate number=334 class=pending-checks age_hours=62.81
class repo=Pibomeister/firstmate number=335 class=pending-checks age_hours=50.83
class repo=Pibomeister/firstmate number=337 class=pending-checks age_hours=30.81
class repo=Pibomeister/firstmate number=340 class=pending-checks age_hours=24.65
```

The measure command exited 0.

## Before and after

Both command readings use the baseline window.
The median matches the Hermes summary on this reading.
This loop does not land pull requests, so that match is a re-read, not an effect of the new command.

| Reading | Firstmate median | AgentKit median | Firstmate aged open | AgentKit aged open |
| --- | --- | --- | --- | --- |
| Hermes summary | 15.99 hours | 2.34 hours | 22 of 27 | 1 of 2 |
| Command at `2026-11-27T06:00:00Z` | 15.99 hours, n=28 | 2.34 hours, n=13 | 23 of 28 | 1 of 2 |
| Command at `2026-11-27T20:02:45Z` | 15.99 hours, n=28 | 2.34 hours, n=13 | 23 of 29 | 0 of 1 |
| Command at `2026-11-27T23:27:43Z` | 15.99 hours, n=28 | 2.34 hours, n=13 | 24 of 30 | 0 of 2 |

The first three rows are the table already in `docs/rsi/loop-1.md`.
The last row is this command.

The 24 aged Firstmate rows class as 13 conflict, 10 pending-checks, and 1 draft.
None of those rows is unexplained.
Both open AgentKit rows are younger than 24 hours, so this reading has no AgentKit class line.

| Instrument | Firstmate | AgentKit |
| --- | --- | --- |
| Review rounds, median and maximum | 3.00 and 23, n=28 | 0.00 and 13, n=13 |
| Rows with a run whose review step ran | 24 of 28 | 4 of 13 |
| Rows on the forge fallback | 4 of 28 | 9 of 13 |
| Intervention-free completion | 0 free of 1 completed, 27 missing | 0 free of 0 completed, 13 missing |

The instrument object names one completed Firstmate row, pull request 298, with 7 interventions before green.
The other rows are missing because their task records are not in this home.
That missing count is not a rate of zero.
