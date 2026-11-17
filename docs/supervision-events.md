# Supervision events contract

This page is the contract for the records a tool outside the worker's terminal can use to find a stalled task and to decide whether one safe action may unblock it.
It covers who produced a record, the fleet ledger envelope, the typed steering receipts, the input-line guard, the task snapshot, and the dry-run unblocker.
Each script's header owns its mechanics; this page owns the shared schema and the safety rules.

## Producer identity

Every record names its producer in a `source` member:

```json
{"machine_id":"5de35e49-0ab5-bf30-0c4b-adfa070db385","scope_id":"e06103f5-8bd2-41ab-8e19-426c86129c88",
 "assurance":"host-match","actor":"main","session_pid":4242,"producer":"fm-fleet-ledger"}
```

| Member | Meaning |
| ------ | ------- |
| `machine_id` | A UUID derived from the operating system's host id (`IOPlatformUUID` on macOS, `/etc/machine-id` elsewhere), hashed with a fixed prefix. Every home on one host reports the same value. The raw host id and the host name are never recorded. `null` when no host id is readable. |
| `scope_id` | A random UUID that names one firstmate home. It is created once in `state/producer-identity.json` by exclusive create and never rewritten. |
| `assurance` | `host-match` when the home still sits on the host that created its identity file, `host-mismatch` when the home was copied or moved, `host-unknown` when either host id is missing. |
| `actor` | `main` or `branch` for a supervisor session, or `worker` for a line a worker wrote through its status command. |
| `session_pid` | The pid in the home's session lock, or `null`. |
| `producer` | The script that wrote the record. |

This is a cooperative binding for processes that run as the same user, never authentication.
Any process running as the home's user can read or replace these files, so give `source` exactly the trust you give the home's `state/`.
`host-match` is deliberately not called `bound`: it proves only where the home lives, not who wrote a record.
`bin/fm-producer-identity-lib.sh` owns the identity file and these values.

## Ledger envelope

When the [fleet activity ledger](fleet-ledger.md) is on, every record also carries `event_id`, a home-wide gapless `seq`, a per-task `task_rev`, `source`, and `binding`.
`binding` keeps the process anchor generation apart from the runtime's own terminal session:

```json
{"spawn_gen":"s1790132857.4242.17","backend":"orca","endpoint":"fm-fix-login",
 "native":{"terminal":"term_0000aaaa","worktree_id":"wt-9"}}
```

`spawn_gen` is the generation firstmate minted at launch, and a relaunch mints a new one.
`native` is the runtime's terminal handle and worktree id, or `null` for a runtime that has none.
Neither proves the other: a native session can be replaced under one generation, and a handle means something only inside the runtime that issued it.
[`fleet-ledger.md`](fleet-ledger.md) owns the envelope's members and gap detection.

## Steering inbox

A steer is a durable record in `state/<task>.inbox/`.
The worker's terminal receives only a constant doorbell line, never the message body, and the worker acknowledges a message by moving it into `handled/`.

### Typed receipts

`state/<task>.inbox/receipts.jsonl` holds one JSON object per line, only appended, in this order for one message:

| `receipt` | Written when |
| --------- | ------------ |
| `accepted` | The record is written, under the inbox lock, so a record that exists always has it. |
| `picked_up` | The monitor first sees the record in `handled/`. It trails the worker's move by up to one poll. |
| `started` | The first `working` or settled status line the task appended after acceptance. |
| `progress` | Each later `working` line. |
| `result` | The first settled line, with `outcome` set to `done`, `failed`, `blocked`, `needs-decision`, or `paused`. |

`started`, `progress`, and `result` carry the line's `state`, `text`, and `status_at`.
The correlation is positional, not causal: a worker does not name the message a line is about.
No receipt proves delivery beyond the move into `handled/`.
The `bin/fm-task-inbox-lib.sh` header owns the exact schema.

### Input-line guard

Before it rings, the inbox reads the worker's input line through the shared classifier in `bin/fm-composer-lib.sh`, which answers `empty`, `pending`, `pending-unproven`, or `unknown`.
A `pending` line holds someone's draft, so the doorbell is skipped and the draft is kept.
The draft guard decides what happens on `pending-unproven` and `unknown`:

- `advisory`, the default, rings anyway, as firstmate always has.
- `strict` skips the ring and records `composer-unproven` as the last delivery, so nothing is typed into a line that could not be proved free.

Set it with the first line of `config/inbox-draft-guard`, or for one process with `FM_TASK_INBOX_DRAFT_GUARD`.
One race remains under either setting: text typed between the read and the doorbell's Enter is submitted with the doorbell.
`tests/fm-task-inbox-receipts.test.sh` reproduces that race and records it as the known residual, while proving `strict` never types into an unproven line.

The classifier must also refuse a composer taller than the rows it reads.
An external send guard showed the failure: an 18-row scan missed the opening prompt glyph of a 34-row pasted composer, read the composer as empty, and safely reported the send as not delivered; an 80-row scan fixed it.
That guard is `steer.sh` (SHA-256 `79ce723d9d52963ab5d738d60eecdeccfa0eece6cb98d7a2f4ef8847a08c3728`) with its retry loop `sendloop.sh` (SHA-256 `6fd39bd0f6541f1c7dc822165ee04617e05a494776eb23cf325c89d91262667a`).
It counts a send as delivered only after a read-back shows an empty input line and a started turn.
Firstmate reads a 20-row window (`FM_COMPOSER_CAPTURE_LINES`), so `tests/fm-composer-lib.test.sh` proves that a bare, a rule-bounded, and a boxed composer cut by that window never read `empty`, while the same shapes with nothing typed still do.

## Task snapshot

`bin/fm-task-snapshot.sh <task>...` or `--all` prints one JSON object per task on one line.
It is read-only, makes no network call, and with `--probe-composer` takes one fresh read of each input line.

| Member | Meaning |
| ------ | ------- |
| `source`, `binding` | As above. |
| `ownership` | `scope_id`, and the supervision `lease` (`actor`, `pid`, `epoch`) or `null`. |
| `authorization` | The task's recorded `kind`, `project` (the project directory's name), delivery `mode`, `yolo` merge posture, and `approval_mode` (the worker tool's own permission mode), or `null` for each one the task does not record. |
| `queue` | `queued`, `oldest`, `oldest_queued_at`, `oldest_delivery` (`ordinary` or `fire-and-forget`), `last_delivery` (`msg`, `result`, `at`), `composer` (`state`, `at`, `probed`) or `null`, and `draft_guard`. |
| `state` | The task's current declaration: `state`, `key`, `text`, as `bin/fm-crew-state.sh` reads it. |
| `progress` | `last_working_at`, `last_status_state`, `last_status_at`, `status_log_mtime`, `screen_beat_at`, `last_receipt`, and `live_ts`. |
| `waits` | `dependency` (a declared wait, with `until`), `human_gates` (each open decision or blocker), and `dialog` (`permission`, `question`, `feedback`, `usage-limit`, `model-switch`, `none`, or `not-read`). |
| `capabilities` | `composer_readable`, `dialog_readable`, `endpoint_recorded`, `backend`, and `strict_draft_guard`. |

The monitor's [task live status file](configuration.md#task-live-status) gives the same input-line, queue, and dialog facts without a command.
Readers must ignore members they do not recognize.

## Unblocker

`bin/fm-unblock.sh` decides; it never acts.
It is a command, not a daemon, and in this version it runs only in dry run.

| Command | Effect |
| ------- | ------ |
| `plan` | Print one decision per stall. Write nothing. |
| `observe` | Also claim each new candidate and record it in `state/unblock.jsonl`. Needs `observe` as the first line of `config/auto-unblock`. |
| `enforce` | Always refused. No setting enables it. |

It can name only two actions:

- `resume`: ring the doorbell again, under the strict draft guard, for the oldest ordinary message a task has left unacknowledged for at least `FM_UNBLOCK_STALL_SECS` (default 900).
- `dispatch`: start the ready backlog item that `bin/fm-ledger.sh next` names, which is already filed and so already authorized.

It never names an approval, merge, deploy, spend, account, authentication, permission, restart, kill, or shell command.

A resume is a candidate only when the task has reported no final state, has no open human gate or declared wait, shows no dialog that needs an answer, records a spawn generation, and its input line read `empty` within `FM_UNBLOCK_COMPOSER_MAX_AGE` seconds (default 120).
A delivery whose outcome is unknown is never repeated blindly: if the same message last rang without pickup, failed to send, met an unreadable input line, or found its endpoint gone, the stall is held.
Every hold names its reason.

Each stall has one key bound to its epoch: `resume:<task>:<msg>@<spawn_gen>` or `dispatch:<item>`.
`observe` claims a candidate by creating `state/unblock/<key>.claim` exclusively.
The first claimer owns that stall for that epoch, and later runs report it as `claimed` and record nothing.
A relaunch mints a new generation and so a new epoch.

The unblocker never reads heartbeat age, a runtime's visibility or orphaned-layout flag, or any other guess about whether a worker is alive.
A quiet worker is not a stalled one, so heartbeat expiry never leads to a takeover, and an orphaned terminal is never treated as dead.
`tests/fm-unblock.test.sh` proves that a stale heartbeat alone produces no decision.

Each decision is one JSON object:

```json
{"v":1,"ts":1800000000,"event":"unblock.decision","mode":"dry-run","source":{"...":"..."},
 "action":"resume","task":"fix-login","msg":"004.msg","item":null,"epoch":"s9.9.9",
 "stall_key":"resume:fix-login:004.msg@s9.9.9","waited_secs":3600,
 "verdict":"candidate","reason":"stalled-on-unacknowledged-message",
 "would":{"ring":"004.msg","draft_guard":"strict"}}
```

`verdict` is `candidate`, `hold`, or `claimed`; `would` is `null` unless the verdict is `candidate`.
A recorded line in `state/unblock.jsonl` has `event` `unblock.candidate`.
The `bin/fm-unblock.sh` header owns the full list of hold reasons.

## Relation to the identity design

These records follow the generic identity design's rules:

- The machine, home, and role are separate identifiers.
- The process, terminal session, and role incarnation have separate lifecycles, and none infers another's state.
- A lapsed lease or an old heartbeat only downgrades confidence and never proves death.
- Identity grants nothing.

The `off`, `observe`, and `enforce` modes match that design's modes, and only `off` and `observe` exist here.
A fencing generation issued by a sealed chain, and authentication beyond one user, are not part of this contract.
