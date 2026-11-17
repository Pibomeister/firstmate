# Fleet activity ledger

The fleet activity ledger is an opt-in, append-only file that outside tools can read to follow what a firstmate home is doing: which tasks were dispatched, when their workers started, whether they are progressing, blocked, or stalled, what they reported, when they finished, the evidence behind each verified outcome, when their work merged, and when they were cleaned up.
It is the stable, documented hook for firstmate status; this page is its contract.

## Turning it on and off

Create the presence flag `config/fleet-ledger` in a firstmate home to turn the ledger on, and delete it to turn the ledger off.
The flag is local, gitignored, per home, and not inherited by second mate homes, so each home that should publish a ledger needs its own flag.
While the flag is absent, each producer performs one file-existence test and nothing else: no process starts and nothing is written.

## The file

The ledger is `state/fleet-ledger.jsonl` in that home, in JSON Lines format: one JSON object per line, each ending in a newline.
Records are only ever appended, in the order they are written.

Every record carries these members:

| Member  | Meaning                                                   |
| ------- | --------------------------------------------------------- |
| `v`     | Record format version, currently `1`                      |
| `ts`    | Unix time in seconds when the record was written          |
| `event` | One of the event names below                              |
| `task`  | The firstmate task id the record is about                 |
| `event_id` | `<scope_id>:<seq>`, unique across homes and hosts      |
| `seq`   | This home's record number: 1 for the first record, then one more for each record |
| `task_rev` | The task's own record number, restarting at 1 when the task is dispatched |
| `source` | Who wrote the record: machine, home, actor, and session ([producer identity](supervision-events.md#producer-identity)) |
| `binding` | The task's spawn generation, runtime, endpoint, and native terminal session, kept apart |

`binding` has the members `spawn_gen`, `backend`, `endpoint` (the recorded window or label), and `native`, which is `{"terminal": ..., "worktree_id": ...}` for a runtime with its own terminal sessions, or `null`.
Each is `null` when the task records none.
[`supervision-events.md`](supervision-events.md) owns the meaning of `source` and `binding`; a record whose producer identity cannot be loaded is not written.

Readers must ignore members and events they do not recognize, so later versions can add them without breaking existing readers.

## Events

| Event              | Extra members                                  | Written when |
| ------------------ | ---------------------------------------------- | ------------ |
| `task.dispatched`  | `kind`, `project`, `harness`, `model`          | A new worker or second mate is launched. A relaunch of an existing task is not recorded. |
| `task.status`      | `state`, `key`, `text`                         | A complete, nonblank line in the task's status log is captured. |
| `task.pr_ready`    | `pr`                                           | Firstmate records the task's PR as ready for review. |
| `task.merged`      | `via` (`"pr"` or `"local"`), plus `pr` when `via` is `"pr"` | The task's PR merge is recorded, or its local-only branch landed. |
| `task.cleaned_up`  | none                                           | The task's worker and local copy were removed. |
| `task.started`     | `signal`, `spawn_gen`                          | A worker incarnation shows its first sign of work. |
| `task.heartbeat`   | `signal`, `text`                               | A worker reports `working`, or its screen changes while it is busy. |
| `task.blocked`     | `wait`, `state`, `key`, `text`                 | A worker reports `paused`, `blocked`, or `needs-decision`. |
| `task.stalled`     | `reason`                                       | The supervision monitor queues a stale notice for the task. |
| `task.finished`    | `outcome`, `pr`, `text`                        | A worker reports `done` or `failed`. |
| `task.verified_outcome` | `outcome`, `checker`, `evidence`          | Firstmate checked an outcome against evidence it can name. |

`task.dispatched` members: `kind` is `ship`, `scout`, or `secondmate`; `project` is the project directory name, or `null` for a remote second mate; `harness` names the agent tool; `model` is the requested model, or `null` for the tool's default.

`task.pr_ready` members: `pr` is the PR's full URL.
It is written each time firstmate records a PR for the task, so registering a replacement PR, or the same PR again, writes another record; recording the PR again as part of merging it writes none.

`task.status` members: `state` is the status line's leading word, such as `working`, `needs-decision`, `blocked`, `paused`, `done`, `failed`, or `resolved`, or `null` when the line has none.
`key` is the line's `[key=...]` decision key, or `null`.
`text` is the status line after its first colon, verbatim, capped at 2000 characters; if the line has no colon, it is the whole line.

### Derived events

Workers gain no new duty: every event below is derived from a status line, from the supervision monitor's own observations, or from the producers above.
Each derived record follows the `task.status` record of the line it came from.

`task.started` is written once per worker incarnation, the incarnation being the task's recorded spawn generation.
`signal` is `"status"` when the first sign is a status line other than `resolved`, or `"pane"` when it is the worker's screen changing while busy.
`spawn_gen` is the recorded spawn generation, or `null` when the task records none.
A relaunch starts a new incarnation, so it can add another `task.started`.

`task.heartbeat` is a progress beat.
`signal` is `"status"` for a `working` line, with `text` as in `task.status`.
`signal` is `"pane"` when the monitor saw the busy worker's screen change, with `text` `null`.
Screen beats for one task are at least `FM_FLEET_LEDGER_HEARTBEAT_SECS` seconds apart (default 300), and the first screen sign of an incarnation is recorded as `task.started` instead.

`task.blocked` members: `wait` is `"dependency"` for `paused`, `"blocker"` for `blocked`, and `"decision"` for `needs-decision`; `state`, `key`, and `text` are as in `task.status`.

`task.stalled` members: `reason` is the stale notice's text, capped at 2000 characters.
It is written when the monitor queues the notice, before firstmate reads it.

`task.finished` members: `outcome` is `"done"` or `"failed"`; `pr` is the first PR or merge request URL in the line, or `null`; `text` is as in `task.status`.
A worker can report `done` more than once, for example when it hands its branch over and again when its PR is ready, so a task can have several `task.finished` records; the last one is current.

`task.verified_outcome` members: `outcome` names what was checked, `checker` names the firstmate script that checked it, and `evidence` is an object whose members depend on `outcome`:

| `outcome`    | `checker`          | `evidence` members |
| ------------ | ------------------ | ------------------ |
| `"pr_ready"` | `"fm-pr-check"`    | `pr`, the PR's full URL; `head`, the head commit firstmate recorded from the forge, or `null` when the forge could not be read |
| `"merged"`   | `"fm-merge-outcome"` | `via` `"pr"`, and `pr`, the merged PR's full URL |
| `"merged"`   | `"fm-merge-local"` | `via` `"local"`, and `head`, the landed branch head the worker recorded, or `null` |
| `"report"`   | `"fm-fleet-ledger"` | `report`, the scout report's path relative to the home (`data/<task>/report.md`); `sha256`, the report's SHA-256 when the scout's `done` line was captured |

A `"pr_ready"` record follows each `task.pr_ready`, and a `"merged"` record follows each `task.merged`.
A `"report"` record follows a scout's `task.finished` with outcome `done` only when the report file exists then.

Example, with the envelope members left out of each line for brevity:

```json
{"v":1,"ts":1790132857,"event":"task.dispatched","task":"fix-login","kind":"ship","project":"webapp","harness":"claude","model":null}
{"v":1,"ts":1790132870,"event":"task.status","task":"fix-login","state":"working","key":null,"text":" bug reproduced"}
{"v":1,"ts":1790132870,"event":"task.started","task":"fix-login","signal":"status","spawn_gen":"s1790132857.4242.17"}
{"v":1,"ts":1790132870,"event":"task.heartbeat","task":"fix-login","signal":"status","text":" bug reproduced"}
{"v":1,"ts":1790133400,"event":"task.status","task":"fix-login","state":"done","key":null,"text":" PR https://github.com/acme/webapp/pull/7 checks green"}
{"v":1,"ts":1790133400,"event":"task.finished","task":"fix-login","outcome":"done","pr":"https://github.com/acme/webapp/pull/7","text":" PR https://github.com/acme/webapp/pull/7 checks green"}
{"v":1,"ts":1790133410,"event":"task.pr_ready","task":"fix-login","pr":"https://github.com/acme/webapp/pull/7"}
{"v":1,"ts":1790133410,"event":"task.verified_outcome","task":"fix-login","outcome":"pr_ready","checker":"fm-pr-check","evidence":{"pr":"https://github.com/acme/webapp/pull/7","head":"3f2c9a1d0b7e4c5a8f6e2d1c0b9a8f7e6d5c4b3a"}}
{"v":1,"ts":1790133900,"event":"task.merged","task":"fix-login","via":"pr","pr":"https://github.com/acme/webapp/pull/7"}
{"v":1,"ts":1790133900,"event":"task.verified_outcome","task":"fix-login","outcome":"merged","checker":"fm-merge-outcome","evidence":{"via":"pr","pr":"https://github.com/acme/webapp/pull/7"}}
{"v":1,"ts":1790133960,"event":"task.cleaned_up","task":"fix-login"}
```

The first record of that example, with its envelope:

```json
{"v":1,"ts":1790132857,"event":"task.dispatched","task":"fix-login","kind":"ship","project":"webapp","harness":"claude","model":null,
 "event_id":"e06103f5-8bd2-41ab-8e19-426c86129c88:41","seq":41,"task_rev":1,
 "source":{"machine_id":"5de35e49-0ab5-bf30-0c4b-adfa070db385","scope_id":"e06103f5-8bd2-41ab-8e19-426c86129c88","assurance":"host-match","actor":"main","session_pid":4242,"producer":"fm-fleet-ledger"},
 "binding":{"spawn_gen":"s1790132857.4242.17","backend":"tmux","endpoint":"fm-fix-login","native":null}}
```

## Limits

- A worker using the current status command in its instructions records its line immediately after appending it, while the ledger is enabled.
  The supervision monitor's regular poll is the backstop: it records any line the immediate write missed, and does not record again a line that write already recorded.
  These lines still trail the status log by up to one poll interval, or until the monitor next runs when none is running:
  - lines firstmate itself writes to a task's status log, such as a recorded answer, a failed launch, a relayed pending reply, or a second mate's report line;
  - lines from workers whose instructions predate this, or that append without running the instruction's full command;
  - lines a remote second mate reports, which reach this home through firstmate's relay;
  - lines written while the immediate record fails, for example when the ledger file cannot be written.
  Recording `task.pr_ready`, `task.merged`, `task.stalled`, a screen heartbeat, or `task.cleaned_up` first records that task's pending status lines.
- Screen heartbeats and `task.stalled` come from the supervision monitor, so none are written while it is not running, and screen heartbeats need a worker tool whose busy state the monitor can read.
- Captured status lines are delivered at least once unless a write fails or a crash loses unflushed records: an interrupted capture can repeat records, so a reader that must not double-count should tolerate duplicates.
- A status record can appear just before its task's `task.dispatched` record when the worker writes a status line in the moment between its launch and that record.
- When a home turns the ledger on, status lines already in a live task's log are recorded on that task's next capture (which may be a worker status command, PR registration, merge, cleanup, or monitor poll); tasks dispatched or cleaned up while the flag was absent have no record of that.
- `seq` has no gaps within one file, so a reader that sees `seq` jump knows records were lost, and a reader that sees it repeat knows a write was retried.
  The counter lives in `state/.fleet-ledger.seq` and is saved only after its record is appended; a lost or older counter resumes after the file's last record.
  Truncating the file keeps the counter, so the emptied file continues from the next `seq`.
  `task_rev` is gapless for one task between its dispatch and its cleanup.
- Writes are plain appends with no forced flush to disk, so a machine crash can lose the newest records.
- The file is never rotated and grows until truncated.
  To truncate it, stop reading, then empty it with `: > state/fleet-ledger.jsonl`; later records append to the empty file.
- The ledger copies status text verbatim from the home's `state/` directory and adds no scrubbing, so give its readers exactly the trust you give `state/`.

## Not included

These are possible follow-ups, deliberately left out of this version:

- session start, away-mode, and quiet-mode events;
- relaunch events;
- when a turn ends, and an idle beat for a worker that is not busy; see the [runtime backend event sources](architecture.md#runtime-session-backends) for native activity observations;
- the input-line, steering-inbox, and dialog state of a task, which the [task live status file](configuration.md#task-live-status) exposes instead;
- rotation and continuity across rotated files;
- backfill or replay of events from before the ledger was turned on;
- secret scrubbing beyond what status lines already contain, and privacy guarantees stronger than those of `state/`.

`bin/fm-fleet-ledger.sh`'s header owns the writer mechanics and lists every producer.
