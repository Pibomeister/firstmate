# PR37: twice-cancelled Lint 2

The CI phase investigated PR37 at `c7606461d51aec061445e87473092d5200e13fa2`.
Both attempts exhausted the job budget on the same merge snapshot. The evidence
supports a partition imbalance, not a clean or failing lint verdict. The next
action belongs to the outer executor: reconcile onto current fork main through
the pipeline, then evaluate Lint 2 on that changed snapshot. No captain waiver is
requested before that required step.

## Phase boundary and state

- No tracked source, tests, workflow, timeout, or lint policy changed.
- No workflow was dispatched or rerun. No pipeline controls, commits, pushes,
  rebases, or merges were executed.
- Evidence writes are confined to `.ci-evidence/lint2/` in this worktree.
- This is an incomplete CI verdict. Neither cancellation proves lint success.
- Reconciliation was not performed here. The worktree is detached at the target
  revision. Its Git metadata belongs to the external gate repository. The task
  reserves pipeline control and the other delivery phases to the outer executor,
  and forbids intentional writes to that external repository.

## Revisions and jobs

| Observation | Revision / job | Result |
| --- | --- | --- |
| PR37 branch head | `c7606461d51aec061445e87473092d5200e13fa2` | Current worktree |
| Actual checkout in both cancelled attempts | `dcce345e006fd5dee6740b36c78ad29581a7bf52` | GitHub PR merge snapshot |
| Base of that merge snapshot | `0dc30b2652f1f7c22190cc0c4cb9de25ce44040d` | Older main |
| Attempt 1 | [122371172566](https://github.com/Pibomeister/firstmate/actions/runs/40555731948/job/122371172566) | Cancelled; 18:02:55–18:33:48 UTC |
| Attempt 2 | [122409915293](https://github.com/Pibomeister/firstmate/actions/runs/40555731948/job/122409915293) | Cancelled; 19:12:12–19:43:06 UTC |
| Green PR38 main baseline | `e32f4511c6adc8b2f3f67dd0e62bad329789731b` | [Lint 2: 122379669195](https://github.com/Pibomeister/firstmate/actions/runs/40558153055/job/122379669195), success |
| Latest fork main observed before handoff | `a1bd6650adca36aded317274c9b087719f3f1a35` | PR39 merged during investigation; parent is PR38 baseline |

The job metadata endpoint identifies the two attempt IDs separately. The wrapper
log request using the old job ID returned the latest attempt's log. The original
attempt's log was therefore retrieved directly from its job endpoint. Checkout
lines in both logs confirm the same merge snapshot. Several attempt-list API
requests returned HTTP 502; direct job metadata, logs, and artifacts succeeded.

## Observable timing evidence

| Lint 2 root | Attempt 1 seconds | Attempt 2 seconds | Green main seconds |
| --- | ---: | ---: | ---: |
| `tests/fm-pending-reply.test.sh` | 121.979 | 120.924 | 117.231 |
| `bin/fm-teardown.sh` | 99.433 | 97.131 | 100.613 |
| `tests/fm-launch-prompt-signals-live-e2e.test.sh` | 90.577 | 90.964 | 89.179 |
| `bin/fm-backlog-handoff.sh` | 73.988 | 74.368 | In main Lint 1 |
| `bin/fm-procevent-remote-reply.sh` | 68.379 | 67.534 | In main Lint 1 |
| `bin/fm-watch.sh` | 59.315 | 64.385 | 61.135 |
| `bin/fm-send.sh` | 62.975 | 62.124 | 62.035 |
| `bin/fm-spawn.sh` | 55.333 | 57.285 | 59.698 |

Attempt 1 completed 244 roots in 1,789.384 seconds. Attempt 2 completed the same
244 roots in 1,786.984 seconds. Both began `tests/fm-stat-shadowing.test.sh` next
and were cancelled before its end record. No completed root reports a nonzero
exit. This is not a verdict on the unfinished or unstarted roots.

The green main Lint 2 completed 259 roots in 1,687.718 seconds. Roots completed
in both snapshots cost 1,026.457 seconds on PR37 versus 1,021.758 on main. This
comparison does not support a broad per-file slowdown as the main cause.

## Partition diagnosis

`bin/fm-lint.sh` owns both canonical partition selection and worker assignment.
It packs roots largest-first using direct file bytes. `FM_LINT_JOBS=1` makes
the two internal workers serial within each hosted lint job. The required
invariants apply to both hosted partitions and both internal worker queues:
canonical roots must remain complete and disjoint, source analysis must retain
its existing policy, and the aggregate work must fit the job budget. None of the
per-root deadlines was reached in the completed records.

The merge snapshot's canonical inventory was obtained from the GitHub Git tree
API without fetching into or modifying the gate repository. Replaying the
existing byte-packing rule yields:

| Merge-snapshot partition | Roots | Direct bytes |
| --- | ---: | ---: |
| Lint 1 | 259 | 9,412,750 |
| Lint 2 | 258 | 9,412,782 |

The modeled Lint 1 manifest exactly equals its real completed-root manifest.
Every completed Lint 2 root is in the modeled Lint 2 manifest. Compared with
green main Lint 2, 131 roots move in and 132 move out. Equal byte totals do not
produce equal analysis time.

Counterfactual: applying green main's measured per-root durations to the
cancelled merge snapshot's Lint 2 manifest totals **1,875.681 seconds** (31m16s).
The partition assignment alone can exceed 30 minutes without slower analysis.
Adding main's timings for the 14 roots without an end record to attempt 2's
completed durations estimates **1,900.214 seconds** (31m40s). These are estimates,
not a completed lint run or a post-reconciliation prediction.

The PR's expanded `tests/fm-session-lock-ancestry.test.sh` belongs to Lint 1 and
completed in 2.183 seconds. No canonical shell root was added by this PR. Its
file-size changes can affect many assignments, so removing assertions from that
test would not be a justified remedy. No supported timing-weight override was
found in the existing owner. No new balancing mechanism was introduced.

## Evidence and verification

- `pr37-attempt1/partition-2.roots.tsv`: original attempt's artifact, ID
  `12760831416`; `pr37-attempt1/lint.log`: exact original job log.
- `pr37-attempt2/partition-2.roots.tsv`: rerun artifact, ID `12763679889`;
  `pr37-attempt2/lint.log`: rerun log with checkout and progress records.
- `pr37-partition1/`: successful sibling partition telemetry from the same run.
- `main/` and `main-partition1/`: green PR38 main telemetry and per-root records.
- `ci-merge-root-sizes.tsv`: canonical root paths and sizes from the actual
  cancelled merge snapshot's Git tree API response.
- `ci-merge-partition1-files.txt`, `ci-merge-partition2-files.txt`: full modeled
  manifests, checked against the executed-root records as described above.
- `root-comparison.tsv`: normalized per-root partition and timing comparison.
- `pr37-*-files.txt`: current worktree manifests from the real public
  `fm-lint.sh --list-files` interface. These are explicitly **branch-tree**
  manifests, not the different GitHub merge-snapshot manifests.

Local verification: the real public inventory commands exited 0. Their sets
contain 258 + 259 = 517 roots, with no overlap and complete canonical coverage.
The telemetry parser and merge-manifest replay assertions passed. These checks
validate evidence and inventory only. ShellCheck analysis was not run a third
time, and no other validation phase was executed.

## Required outer-executor action

1. Reconcile PR37 onto the latest fork main through its owned pipeline path.
   Recheck the remote head; it advanced during this investigation.
2. Record the new checkout revision and both canonical partition manifests.
   Lint 2 must run on that changed snapshot, not unchanged on `dcce345e` again.
3. If Lint 2 still reaches the job limit after reconciliation, retain the new
   roots sidecar and return **needs-decision** for the named Lint 2 waiver, as
   directed. Do not weaken tests, skip roots, raise timeouts, or repeat unchanged.

No waiver or green verdict can be inferred from this pre-reconciliation evidence.
