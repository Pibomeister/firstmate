# RSI loop 2

This page is the loop-2 record for recursive self-improvement of the Firstmate and AgentKit harnesses.
Loop 2 targets the conflicted Firstmate pull-request backlog that [loop 1](loop-1.md) left as its input.
`docs/documentation-audiences.json` classifies this page as maintainer verification.
The page stores the before reading, the diagnosis, the candidates, the council ruling, the change, and the after-measurement definition.
Per-pull-request rows stay outside the repository.
`bin/fm-rsi-measure.sh` owns the median and aged-open calculation.
`bin/fm-rsi-conflicts.sh` owns the conflict report this loop adds.
Held work stays in the sample, and this loop lands, rebases or closes no other pull request to move a figure.

## Before

The open snapshot is `2026-11-28T12:29:50Z` (`--now 1795868990`).
Open rows are every open pull request on `Pibomeister/firstmate` at that instant, read with `gh-axi` GraphQL `pullRequests(states: OPEN)`.
Merged rows are the search `repo:Pibomeister/firstmate is:pr is:merged merged:2026-11-12..2026-11-28`, which returned 90 rows.
Review-round and intervention fields were left null, so those two instrument lines are missing rather than zero.
No status check reported on any open head, so every open row has `reported_checks` 0.

```
bin/fm-rsi-measure.sh --input <forge-input.json> --now 1795868990 --window-start 2026-11-20T06:00:00Z --window-end 2026-11-27T06:00:00Z
bin/fm-rsi-measure.sh --input <forge-input.json> --now 1795868990 --window-start 2026-11-21T06:00:00Z --window-end 2026-11-28T06:00:00Z
```

| Window (`merged_at`, end exclusive) | Firstmate median open-to-land | Aged open at snapshot |
| --- | --- | --- |
| Loop-1 window `[2026-11-20T06:00:00Z, 2026-11-27T06:00:00Z)` | 15.99 hours, n=28 | 25 of 32 |
| Loop-2 before window `[2026-11-21T06:00:00Z, 2026-11-28T06:00:00Z)` | 11.95 hours, n=28 | 25 of 32 |

The loop-1 window re-read reproduces the 15.99 hours, n=28 figure in `docs/rsi/loop-1.md`.
The loop-1 end-of-day reading had 24 of 30 aged open.
This snapshot is 13 hours later, and two more pull requests are open and one more has aged past 24 hours.
The trailing seven-day median is already under the 12-hour goal G1, before any loop-2 change.
No loop-2 change existed in that window, so the fall is consistent with the window moving; this loop did not isolate its cause.

The 25 aged rows class as 13 conflict, 11 pending-checks and 1 draft.
The 11 pending-checks rows are heads that GitHub reads as mergeable and on which no check reported.
All 13 conflicted rows are aged.

## Diagnosis

The conflicting paths come from a trial three-way combine of each head with the default-branch tip `deb597dfc4887e531d77aad8cd8d96fc94c1b378`.
That is the `bin/fm-rsi-conflicts.sh` reading in After, and it matches GitHub's `mergeable` state on all 32 heads.

| Path | Conflicted heads it blocks |
| --- | --- |
| `docs/scripts.md` | 4 |
| `bin/fm-classify-lib.sh` | 3 |
| `bin/fm-claude-seed.manifest` | 3 |
| `bin/fm-spawn.sh` | 3 |
| 12 other paths | 1 each |

Three causes show in the rows.

- Catalog rows: all four `docs/scripts.md` conflicts are a pull request rewriting one table row while the default branch inserted the next row, which Git treats as one overlapping change.
  Three of those heads conflict on nothing else.
- Derived content: `bin/fm-claude-seed.manifest` holds one blob hash per seed file, so two pull requests that edit the same skill always conflict on its line.
- Shared code: seven heads conflict on real code, led by `bin/fm-spawn.sh` and `bin/fm-classify-lib.sh`.

Six of the 13 conflict only on documentation or catalog paths.
The conflicted heads are 17 to 72 commits behind the default branch.

None of the 25 aged rows has a live task record or a contribution record in this home, and the home has no `config/pr-health-monitor`.
So no monitor in this home covers those rows, and before this loop no command named which path to resync first.

## Candidates

Each candidate is reversible.
The median estimates are drafts, not measurements.

- A. A read-only conflict report command: per open head, the paths that conflict with the base, computed in a scratch object directory, plus a tally of how many conflicted heads each path blocks.
  Revert by removing one script.
  Estimated median effect: none direct; it shows which one resync unblocks the most rows.
- B. Opt-in widening of the PR health monitor to open rows in this home's own repository that no task owns, with one notification per head when a row turns conflicted.
  Revert by removing a config flag.
  Estimated median effect: small, and only when resyncs follow; it may notify about rows another home or the owner is holding.
- C. A triage page only: each aged row with its class and conflicting paths, for an owner's keep, resync or close call.
  No code.
  Estimated median effect: none until acted on.

The drafted recommendation was A, because it is read-only, adds no notifications and leaves ownership rules unchanged.

## Council decision

The council ran once under task `fm-rsi-loop2` and key `rsi-loop2-improvement-pick`, at `2026-11-28T12:35:54Z`.
The home's watchdog config has `mode=act`, so the council convened live, unlike loop 1.

```
bin/fm-watchdog.sh council --task fm-rsi-loop2 --key rsi-loop2-improvement-pick --record-file <record>
council=ruled answer=PROCEED A record=<home>/data/watchdog/rulings/council-6caea02ae7450e7cadc3188999360bc9c4387efc.md prior=0 seats=seat1=PROCEED A seat2=PROCEED A
```

The ruling is PROCEED A, unanimous, from the two blind seats `claude:haiku` and `agy:gemini-3.8-flash-low`.
The ruling file's SHA-256 is `d7c71a0c83bbbd0ad80bd0c96e4a89846c07493389f76f9e5cdad1d960f40ccd`.
The submitted record's SHA-256 is `29001abd57c6baf080b713489627f9c3e250fd159458b63b40907077182e673e`.
The watchdog call log shows one metered seat at 0.0010409 USD and one unmetered seat.
A council ruling is evidence for the supervisor, never the owner's approval.

## Change

`bin/fm-rsi-conflicts.sh` is option A.
Its header owns the usage, the output lines and the refusals.
It never fetches, so a reader fetches the heads first.

## After

The after-measurement uses the same two queries and the same commands as Before, plus the conflict report.
The after window is `merged_at` in `[2026-11-28T06:00:00Z, 2026-12-05T06:00:00Z)`, the same seven-day length as the before window.
It is midnight to midnight in America/Chicago, from 28 Nov 2026 through 5 Dec 2026.
The full after window completes at `2026-12-05T06:00:00Z`, and the after reading is taken at or after that instant.
The after reading reports the median and n, aged open, the class counts, and the conflict report summary and tally.

The conflict report reading below is the conflict baseline for that after reading.
Its snapshot is `2026-11-28T12:40:47Z`.
The heads were fetched into a scratch bare repository, and that repository's files hashed the same before and after the report ran.

```
git -C <scratch> fetch https://github.com/Pibomeister/firstmate.git +refs/heads/main:refs/base/main +refs/pull/<n>/head:refs/pr/<n> ...
bin/fm-rsi-conflicts.sh --repo <scratch> --base deb597dfc4887e531d77aad8cd8d96fc94c1b378 <n>=<sha> ...
```

```
tally path=docs/scripts.md blocked=4
tally path=bin/fm-classify-lib.sh blocked=3
tally path=bin/fm-claude-seed.manifest blocked=3
tally path=bin/fm-spawn.sh blocked=3
summary conflicted=13 heads=32
```

Twelve further tally lines each read `blocked=1`.

What can be measured when this pull request opens is a partial after window.
At the `2026-11-28T12:29:50Z` snapshot it holds no merged row, so the after median is `none` with n=0.
That partial figure is not an after result.
This change adds a report and changes no landing path, so any median change in the after window is not attributable to it alone.
The after window also includes this pull request and every other pull request that lands in it, whatever its cause, so a lower after median is not by itself a loop-2 result.
