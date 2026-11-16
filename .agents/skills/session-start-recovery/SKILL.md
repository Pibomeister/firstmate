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
<!-- goal-integrity-20261109 BEGIN: Eduardo's words, verbatim; only Eduardo can change this block -->
## Goal integrity rules (Eduardo, 2026-11-09)
How this applies here: handoff and restart runbook: a restarted captain re-reads every state/goals/<task-id>.md and its drift log before acting on any task.
These rules add to the six 2026-11-09 build-integrity rules (data/captain.md) and do not replace them. Canonical copy: /Users/eduardopicazo/orca/workspaces/firstmate/data/goal-integrity-rules-20261109.md (sha256 ac3e5610010e). Goal files: `state/goals/<task-id>.md`; drift logs: `state/goals/<task-id>.drift.md` (both under /Users/eduardopicazo/orca/workspaces/firstmate).

# Goal integrity rules for the Regulis captain and its crewmates (from Eduardo, Nov 9 2026)

Firstmate, this comes from Eduardo directly, through Regulis. Write it into the Mac Studio Regulis captain's memories, runbooks, skills and local CLAUDE.md files, word for word, and don't narrow or reinterpret any of it. It adds to the six build-integrity rules you wrote today and doesn't replace them.

## Why this exists

On the Lawrence build (Oct 27–29), Eduardo asked for one thing: build the RoadOne log-gap agent through CodeGen V2. What he got was hand-patched primitives, written straight into the database, and reused legacy V1 components, all still labeled "V2". Here's how it went wrong:
- At 16:49 on Oct 27, the captain wrote "this replaces the earlier 'fix only by refining inputs and regenerating' rule", and then put the same thing into the codegen-v2-generate skill at 17:11.
- It read a passing remark ("launch everything") as permission to stop regenerating.
- The crewmate patched agent_primitives in the database, and the #2470 brief said "Reuse the legacy components".
- No agent ever said that this conflicted with the original ask.
- Status went out saying "codegen straight to working" when it wasn't.

Eduardo then had to apologize to Will, and Will had to throw the work away and rebuild the agent from scratch. In Eduardo's words: "This can't ever happen again. If it changes the requirements on the fly, or if it misinterprets one of my prompts and that goes directly against the initial ask, it should catch that."

## Rule A: the goal is written down once and kept word for word
1. At the start of any task, write Eduardo's stated goal, exactly as he wrote it, to a goal file, one per task (for example `state/goals/<task-id>.md`). Include the date, where it came from (the message or link), and any hard constraints he named (for example "through CodeGen V2", "no hand patches", "don't touch legacy").
2. Only Eduardo can change that file, in his own words. Neither the captain nor a crewmate may edit, paraphrase, summarize, narrow or "clarify" it. If he changes the goal, add his new words with a date below the old ones, and keep the old ones.
3. Every brief, course correction, re-brief and handoff to a crewmate starts with a line that reads "GOAL (Eduardo, verbatim): …", followed by the full text of the goal file.

## Rule B: a later message never quietly overrides the goal
4. A later prompt, a passing remark, a time-pressure phrase ("launch everything", "just ship it", "whatever's faster"), a reviewer comment or a different agent's idea is never permission to drop, weaken or redefine the goal or its constraints.
5. When a later instruction could be read in a way that conflicts with the goal, use the reading that keeps the goal intact. If no reading keeps it intact, it counts as a conflict (Rule C).
6. Never write a rule that "replaces", "supersedes" or "relaxes" one of Eduardo's constraints unless his own words in the goal file say so. That goes for memories, skills, runbooks and briefs.

## Rule C: a conflict stops the work and goes to Eduardo
7. A conflict is anything where meeting a deadline, a shortcut, a reviewer's request or a technical limit would mean not meeting the goal as written. Examples are hand-patching instead of regenerating, reusing V1 code, labeling something V2 that isn't, or skipping a step he named.
8. On a conflict, stop that line of work and send Eduardo, through Regulis, one short trade-off message. It quotes the goal, says plainly what conflicts with it, and gives the two or three real options with their cost. Then wait for his answer in his own words.
9. A crewmate that spots a conflict stops and reports it to the captain, and the captain escalates it. Neither one may resolve it alone.

## Rule D: every report checks itself against the goal
10. Every status report, progress note, PR description and "done" claim ends with these three lines:
   - `GOAL CHECK: meets goal as written — yes / no / partly`
   - `DEVIATIONS: none` (or list every one: patches, reused legacy code, skipped steps, relaxed tests)
   - `PROOF:` a runnable command, a version id, fixture counts, a link, or a SHA
11. "Partly" or any deviation means the work isn't done. Don't call it on track, ready or working, and flag the gap in the first line of the report, not the last.
12. Never word a report so a reader would assume more than is true. If something was hand-patched, demoed locally only, or tested against synthetic data only, say so up front, in plain words.

## Rule E: ask the right humans first when the pattern is new
13. When the task builds something the team hasn't built this way before (a new agent type, a new channel such as voice, a new CodeGen V2 pattern), the first report says whether Hyrum or Will was asked how they'd approach it, and what they said. If nobody was asked, say "not yet consulted" and suggest Eduardo ask before building.
14. Don't guess at the team's conventions. Find where they're written down (SOPs, technical guidance, the MCP server, how existing agents were built) and cite it.

## Rule F: self-audit before each handoff
15. Before any brief goes out and before any work is reported done, re-read the goal file and answer one question in writing: "If Eduardo read only his original ask and then looked at this, would he say it's what he asked for?" Anything short of yes is a conflict (Rule C).
16. Keep a short drift log per task (`state/goals/<task-id>.drift.md`). Every time the plan moves away from the literal goal, add a line saying what changed, why, and whether Eduardo approved it in his own words.

## Where it goes (all of it, word for word)
- **Memories:** the captain's durable memory and standing rules (`data/captain.md`), as one entry dated 2026-11-09 and titled "Goal integrity rules".
- **Local .md files:** the CLAUDE.md that the Regulis captain and crewmates load in their workspaces and worktrees, including the compliance_frontend worktrees' local, uncommitted CLAUDE.md (or the equivalent local agent file).
- **Runbooks:** the brief and course-correction runbook, the handoff and restart runbook (a restarted captain has to reload the goal files), and the reporting and status runbook.
- **Skills:** codegen-v2-generate (already regenerate-only), plus any skill used to brief crewmates or write status, so that each one points to and enforces Rules A–F.
- **Brief template:** `config/brief-include.md` and `fm-brief.sh`. Raise this section's precedence so it's at the top and can't be overridden by the rest of the brief, and make fm-brief.sh refuse to send a brief that has no "GOAL (Eduardo, verbatim)" line.

## Boundaries
- These edits only touch Firstmate and captain config, memory, skill and runbook files. Make no commits, pushes, merges or Mergify labels on regulis-dev-team repos as part of this.
- Keep backups of every file you change, as you did today.

## What to send back (to Regulis, as one message)
1. The path and a diff for every file you changed.
2. A dry run: generate one sample brief for an imaginary task with the goal "Build the Transit Solutions ETA agent through CodeGen V2, zero hand patches", and show that it starts with the goal written word for word.
3. A conflict test: give the captain the follow-up "just get it working by tomorrow, whatever's fastest" on that imaginary task, and show that it stops and writes a Rule C trade-off message instead of switching to patching.
4. The captain's "RULES ACK" for both today's six rules and these, plus confirmation that they were forwarded to every running crewmate.
<!-- goal-integrity-20261109 END -->

<!-- will-delivery-G1-G6-20261109 BEGIN: Eduardo's words (Will's delivery feedback), verbatim; only Eduardo can change this block -->
## Will delivery rules G1-G6 (Eduardo, 2026-11-09)
How this applies here: handoff and restart runbook: a restarted captain checks whether a Wednesday 12:00 CST risk check (G3) is due and keeps handoffs to one screen (G5).
These add to the goal-integrity Rules A-F and the six build-integrity rules (data/captain.md) and replace none of them. Canonical copy: /Users/eduardopicazo/orca/workspaces/firstmate/data/will-delivery-rules-20261109.md (sha256 a7ef57abcf74).

# Will delivery rules G1-G6 (from Eduardo, Nov 9 2026, via Regulis at 4:33 PM CST)

G1 Time constraints first. Before taking on any ticket, write down Eduardo's available time and any known time off in the brief. If the work doesn't fit, propose splitting it into smaller tickets before starting.
G2 Ask the owner before building a new pattern. If the work uses a pattern not yet built in this repo by us (e.g. a new V2 agent, a new codegen flow), the first step is a short question for Eduardo to ask Hyrum (or whoever built the reference, such as the DTI agent on V2). Do not start building until that answer is recorded in the brief. Copy an existing working reference; never improvise around it.
G3 Wednesday risk check. Every Wednesday by 12:00 CST, report each in-flight deliverable as on-track only with runnable proof (command + output), otherwise AT RISK. Anything AT RISK goes to Eduardo the same day with a handoff plan. Never surface risk for the first time on Thursday or Friday.
G4 Runnable proof, not labels. 'Done' or 'on track' requires a runnable checkpoint someone else can run (clean regen from committed inputs + fixtures passing, zero hand patches). Labels, version fields, or PR titles are not proof.
G5 Short handoffs. A handoff is at most one screen: what works, how to run it, what's left, who to ask. No long docs, no speculative rabbit-holes. If Eduardo has time off coming, the handoff is ready 2 working days before he leaves.
G6 Own it, no blaming tools. Reports to Eduardo and anything drafted for Will never blame Claude, agents, or tools; state what happened and what changes.
<!-- will-delivery-G1-G6-20261109 END -->
