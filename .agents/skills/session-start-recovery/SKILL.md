---
name: session-start-recovery
description: Load when the session-start digest reports unfinished checks, actionable diagnostics, recovery inputs, or output requiring interpretation.
user-invocable: false
metadata:
  internal: true
---

# Session-start recovery

The digest itself makes no external-network call and never waits for one.
Every network check a session start owes - GitHub auth, home code drift, secondmate recovery, secondmate convergence, pending handoff delivery, and project clone refresh - runs off the digest's blocking path in a bounded worker owned by `bin/fm-startup-network.sh` and is reported in the digest's own `NETWORK CHECKS` section.
The locked startup inactive-outcome scan joins that worker so a slow local current-state read cannot block the digest; its findings use the ordinary durable wake queue.

1. **Lock** - acquires the per-home session lock first, before anything mutates shared state, then starts the deferred startup stage above.
2. **Bootstrap** - detect-only checks (tool/version problems, the worktree-tangle check, harness override, dispatch-profile validation, backlog-backend status) always run, but routine confirmations stay silent by default.
   When the lock could not be acquired, the worktree-tangle check uses read-only advisory wording without a checkout repair command.
   Home-local stale Herdr projection cleanup and the seven bootstrap MUTATING sweeps - same-home backlog reconciliation, home code drift fast-forward, fleet sync, secondmate convergence, secondmate liveness, pending remote handoff retry, and Relay artifact writes - run only when this session actually holds the lock from step 1; the five network ones among them run in the deferred stage rather than in this section.
   The secondmate liveness sweep accounts for every registered secondmate and reports skipped or failed recovery as `SECONDMATE_LIVENESS:` lines.
   The sweep and the watcher's cadence-gated tick share the [recovery contract](../../../bin/fm-secondmate-liveness-lib.sh); for T3 threads, follow the [native recovery guide](../../../docs/t3code-backend.md#restart-and-liveness-behavior).
3. **Wake queue** - when locked, drains and presents the durable wake queue without running the inactive-outcome scan inline, and prints the raw records prominently as this turn's first work queue; a clearly labeled status-event annotation may follow a valid `signal` record and includes every status line still unread at the presentation cursor, but never replaces the raw record or current-state reconciliation, and a lapsed watcher chain still surfaces here via the same guard alarm.
   Presented records remain durable until the handling turn runs the generation-bound acknowledgement printed by the drain.
   When the presentation is large, session start saves it whole to `state/.session-start-wake-presentation` and keeps inline one non-historical latest-event annotation line per status file, cut at 320 characters, and leaves out inline only the earlier unread, repeated, and historical annotation lines and the `OPEN DECISIONS` and `STATUS OUTCOME BACKSTOP` items past the first five of each, with a disclosure line naming that file; read the file before handling a `signal` record or reconciling the left-out items.
   Every locked drain also prints a bounded fleet-wide `OPEN DECISIONS` section when durable decision records remain open, including when the queue itself is empty; reconcile those entries before continuing.
   A main drain may also print a bounded, one-shot `STATUS OUTCOME BACKSTOP` when a task's newest captain-facing status event has no covering supervision-branch outcome; handle it as a recovered wake even when no queue row remains.
   The same drain prints every still-unread `note:` line and reserved-key resolution since the last presentation in an unbounded `UNREAD STATUS` section, so an answer buried under a later routine line is not dropped; those lines are not re-printed after that presentation.
   It also prints a bounded `RECORD DIVERGENCE` section naming every captain call the status log reads as resolved while its backlog task is still held; nothing is closed for you, and `captain-hold-lifecycle` owns the reconciliation.
   When the lock could not be acquired and verified, the queue is left untouched because no session mutation is authorized, and the guard's tangle/watcher-liveness alarms still print in read-only advisory mode without drain, supervision repair, or checkout repair commands.
4. **Supervision operating instructions** - after the wake queue and before both digests, the digest emits exactly one operating block for the detected primary harness, followed by the read-once contract that governs them.
   The script itself never starts supervision; the emitted harness protocol owns the exact wait or wake mechanism.
5. **Fleet-state digest** - after that read-once contract and ahead of the context digest, the compact backlog listing owned by `bin/fm-session-start.sh`, whose disclosure lines name by id every in-flight row it lists elsewhere; one line per live task in `state/<id>.meta` (id, project, last recorded status-event word, recorded PR URL, age, and an `endpoint=` field from one cheap alive/dead read of the task's recorded backend endpoint), with a pointer to `bin/fm-crew-state.sh <id>` for full detail, and old dead-endpoint tasks with no PR condensed to one shared line of `id:state:age:endpoint` entries; the away or quiet posture (`state/.afk-contract`, plus the `state/.afk` daemon flag where a daemon runs).
   The state word is the last wake EVENT, not current state, and the `endpoint=` field is a fast presence check only, not a full state read - when you need a crew's actual current state (a run-step, not just "is the pane there"), read it with `bin/fm-crew-state.sh <id>` as before; the digest deliberately skips that deeper, slower read for every task so it stays fast and bounded.
6. **Network checks** - after the fleet-state digest, the deferred stage's result, or an explicit statement of what it has not confirmed yet.
   A read-only session runs no network checks at all and says so.
7. **Context digest and next step** - last of the bulk sections, the tracked `docs/learnings/overnight-learnings.md`, `data/projects.md`, `data/secondmates.md`, `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md`, each clearly delimited, followed by the closing reminder.
   A small file prints in full; a large one prints `INDEXED` with its absolute path, size, and a line-numbered outline (a pointer alone for the learnings files), so read an indexed captain file, or the sections its outline names, before the first dispatch, merge, or escalation call that depends on it.
   A file that does not exist prints an explicit `ABSENT` marker, never confused with an empty-but-present file: absence is meaningful (`captain.md` absent means use the firstmate repo's built-in defaults, `projects.md` absent means rebuild it from the clones under `projects/`, etc.).
   The closing reminder points back to the emitted supervision block and preserves only the lock, afk, Relay, and read-once reminders.

Bootstrap detects first, asks for consent, and installs or upgrades only after the captain approves in the current session.
Do not dispatch until the essential launch tools are present and GitHub authentication is good; presentation availability follows `bootstrap-diagnostics` and does not block nonvisual work.
`AGENTS.md` section 1 owns which tool to use for GitHub, browser, desktop-app, and visual work.
A silent bootstrap section needs no action; for any printed actionable diagnostic line, load `bootstrap-diagnostics` and follow its owner procedure.
`BOOTSTRAP_INFO:` lines are completed no-action facts and do not require loading a skill.
`secondmate-provisioning` owns startup secondmate sync, liveness, and inherited local-material convergence.
