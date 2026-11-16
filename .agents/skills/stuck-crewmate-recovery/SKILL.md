---
name: stuck-crewmate-recovery
description: >-
  Load when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, or a failed steer, after observing a defeated Claude or Codex bypass, and when a live crewmate reports its no-mistakes pipeline dead, unreachable, or timed out.
user-invocable: false
metadata:
  internal: true
---

# stuck-crewmate-recovery

Use this playbook when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, or when a direct report is stale, looping, repeatedly confused, asking a question its brief already answers, unresponsive, or when a steer failed to land.
A stale or dead-endpoint report for a worker whose pull request has already landed is not a recovery case: the work is finished, so close the task through ordinary teardown (`AGENTS.md` section 7 for firstmate, the landed-work rule in `bin/fm-branch-prompt.sh` for the supervision branch) instead of this playbook, never with `--force`.

Follow the crew-hosted Lavish board contract in [`docs/configuration.md`](../../../docs/configuration.md#crew-hosted-lavish-review-boards) when recovering a worker that hosts a board.

Interrupt, stop, and relaunch a worker through `bin/fm-control.sh <task-id> interrupt|exit|relaunch`, which resolves the recorded runtime itself, verifies each action, and never tears down or discards anything ([`docs/agent-control.md`](../../../docs/agent-control.md)).
That plane covers workers running in this home; a remotely placed secondmate is refused by name and reconciled through `secondmate-provisioning` instead.
Load `harness-adapters` before a resume command or a harness-specific skill invocation, and whenever the adapter's own quirks matter.
The target window's harness is recorded as `harness=` in `state/<id>.meta`.

## Managed approval failover

After observing a Codex command-approval prompt under bypass or a Claude policy refusal of a bypass session, ask the captain for explicit approval to change the owning home's worker permission posture and relaunch the worker.
Only after that explicit word, load `harness-adapters` and use `FM_HOME=<owning-home> bin/fm-approval-failover.sh apply <id>`; its header owns persistent configuration and guarded recovery, with no automatic detection.
Report the saved model-reviewed remedy and actual recovery result, preserving explicit settings and work rather than changing vendor policy or answering approval or hook-trust prompts.
A `backend=t3code` worker already runs at T3's `full-access` runtime mode, so the command refuses it before changing anything; approve its pending request in T3 Code itself ([T3 pending-request procedure](../../../docs/t3code-backend.md#push-events-and-polling-fallback)) or move the work to another backend.

## Session-start reconciliation for a dead ordinary direct report

This procedure covers ordinary `kind=ship` and `kind=scout` direct reports.
Load `secondmate-provisioning` instead for `kind=secondmate` recovery.

For a REMOTE secondmate, `fm-crew-state` and `fm-peek` read the actual remote endpoint over `fm-on.sh`, and `fm-send` reports a delivered-with-pending-confirmation steer as delivered (their headers own the contracts); an `unknown-remote` read or unreachable-host failure means the remote state could not be read, never that the mate is dead or the send failed.
Recover a genuinely stuck remote mate only through `bin/fm-spawn.sh <id> --secondmate`, never raw herdr pane close/kill surgery, which strands the endpoint binding.

Treat the digest's endpoint result as a presence signal, not proof that the task's work or validation run is gone.
Read the targeted current state with `bin/fm-crew-state.sh <id>` before deciding to relaunch.
A no-mistakes run matched to the crew's branch and current code remains authoritative when the endpoint is dead: handle a terminal or parked run through the normal lifecycle, and keep supervising an active run instead of creating a duplicate worker.

When no authoritative run accounts for the task, inspect only its recorded backend and worktree inventory.
Use `treehouse status` for treehouse-backed tmux, herdr, zellij, cmux, Paseo, Rex, t3code, or tern tasks, and use the recorded `orca_worktree_id=` and `terminal=` for Orca tasks.
Do not sweep another home's endpoints or infer ownership from a matching window label.

Before relaunch, prove that no live agent still owns the recorded task and that the existing worktree remains available.
Preserve its uncommitted changes and commits, keep the same task identity, and resume or relaunch the recorded harness in that existing worktree with the same brief plus a concise progress note.
A HERDR endpoint that is not merely idle but destroyed - a pane or workspace removed in Herdr churn - is recovered by that same relaunch, which creates one fresh endpoint in the existing worktree and rebinds the task's record to it; nothing special is needed, and the worktree is untouched ([`docs/agent-control.md`](../../../docs/agent-control.md) "Reclaiming a task whose endpoint is gone").
That relaunch proves the endpoint is destroyed before it rebinds, so a Herdr server that was merely stopped is adopted back rather than duplicated.
On tmux the same relaunch reclaims a destroyed window only when the task record carries the tmux server identity a spawn now records; an older record cannot tell a `missing` window from one on a tmux server this seat cannot address, so both `exit` and `relaunch` refuse.
On T3 Code there is no replacement relaunch: the thread keeps its conversation, so a turn or provider change continues the same agent; preserve the task record and worktree and follow [`docs/t3code-backend.md`](../../../docs/t3code-backend.md#restart-and-liveness-behavior) instead of trying to respawn it.
Do not work around these refusals by respawning; preserve the recorded task and follow the backend's recovery contract.
That reclaim is the owning home's operation only, and a secondmate is the one exception: recover it through `bin/fm-spawn.sh <id> --secondmate` as above.
Do not use a fresh generic spawn while the recorded worktree is unaccounted for, because allocating another worktree can split one task across two copies.
If the worktree or ownership cannot be reconciled safely, leave all state intact and report the task failed or blocked with the conflicting evidence.

## A live crewmate claiming the pipeline is dead

This is the inverse of the dead-endpoint case above: the worker is alive and the pipeline it declares dead usually is too.
A drive call blocks until the next gate or outcome, far longer than a harness lets one command run, and the daemon accepts a response immediately and runs the round in the background.
So a crewmate's timed-out, killed, or errored drive call leaves it waiting on a read it never got, and the "the daemon is gone" conclusion it draws from that is a guess, not evidence.

Read the two authoritative sources yourself before believing the claim:

1. `no-mistakes daemon status` for the socket.
2. `no-mistakes axi status --run <id>` for the run, or `bin/fm-crew-state.sh <id>`, which already folds this contradiction in and reports a non-socket daemon-or-timeout `blocked:` line over a running or fixing run with fresh activity as superseded because the run is alive.

A refused connection or missing socket from `daemon status` is positive daemon-down evidence and must be escalated even if the persisted run record still says running or fixing; that record can be stale after the daemon exits.
Otherwise, if the run is still running or fixing with recent activity, the claim is wrong: steer the crewmate to reattach with `no-mistakes axi run` from its own worktree, which is safe and idempotent while the run still matches its `HEAD`, and tell it a timeout is not daemon death.
Nothing reaches the captain in that case.

Never restart, stop, or update the shared daemon on a crewmate's claim.
It is one instance serving every lane and home, so a restart kills other lanes' in-flight runs.
Only positive socket refusal or absence is a daemon-down finding; escalate that finding, or a failed run record that names a daemon error, to the captain.

## Live-endpoint escalation

Escalate in order:

1. Peek the pane, and check the task's steering inbox (`state/<id>.inbox/`) for unhandled `*.msg` records - a stale wake naming an unread firstmate instruction means the worker never acknowledged a durable steer, and the record itself shows exactly what was intended.
   A worker whose current state is a declared `paused:` wait has only said what it is waiting for, so verify the condition it names - its own background job's terminal record or process, for example - and when that condition has already cleared, steer the worker to read the result and resume instead of reporting the wait as healthy.
   The verb header in [`bin/fm-control.sh`](../../../bin/fm-control.sh) owns the close policy.
   The watchdog only names the pick.
   This step runs here.
   When the worker cannot declare its own wait, use [`bin/fm-park.sh`](../../../bin/fm-park.sh) with this firstmate's home selected explicitly; its header and help own the invocation and bounded-wait contract.
2. If the crewmate is waiting on a question its brief already answers, follow the [T3 pending-request procedure](../../../docs/t3code-backend.md#push-events-and-polling-fallback) for a T3 runtime request.
   On pane backends, answer in one line via `FM_HOME=<this-firstmate-home> bin/fm-send.sh` from an active firstmate session unless `FM_HOME` is already set to the active firstmate home.
3. If the crewmate is confused or looping, interrupt with `FM_HOME=<this-firstmate-home> bin/fm-control.sh <task-id> interrupt`, then redirect with one corrective line through `fm-send`.
4. If the crewmate is genuinely wedged after redirection and its backend supports a replacement, relaunch it with `FM_HOME=<this-firstmate-home> bin/fm-control.sh <task-id> relaunch --note '<progress so far>'`, which stops the agent, carries the brief plus that note into a replacement in the same local copy, and restores the prior record if the replacement cannot start.
   On T3 Code, do not relaunch; preserve the task and report the stuck thread with its current server status for operator action.
   Pass `--harness`, `--model`, or `--effort` on that same command when the worker should come back on a different runtime.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; modern harnesses auto-compact and keep going.
   The worktree and commits persist, so relaunch is cheap.
5. If a second relaunch fails too, write `failed` to the backlog and tell the captain the plain failure, preserved work, and consequence using `AGENTS.md` section 9; do not mention metadata, harness, window, or worktree unless the path itself is needed for action.
<!-- goal-integrity-20261109 BEGIN: Eduardo's words, verbatim; only Eduardo can change this block -->
## Goal integrity rules (Eduardo, 2026-11-09)
How this applies here: brief and course-correction runbook: every steer, correction, re-brief or relaunch opens with "GOAL (Eduardo, verbatim): ..." and the full goal file; a steer that would narrow the goal is a Rule C conflict.
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
How this applies here: brief and course-correction runbook: every brief records Eduardo's available time and time off (G1) and, for a new pattern, the recorded Hyrum/owner answer before any build (G2).
These add to the goal-integrity Rules A-F and the six build-integrity rules (data/captain.md) and replace none of them. Canonical copy: /Users/eduardopicazo/orca/workspaces/firstmate/data/will-delivery-rules-20261109.md (sha256 a7ef57abcf74).

# Will delivery rules G1-G6 (from Eduardo, Nov 9 2026, via Regulis at 4:33 PM CST)

G1 Time constraints first. Before taking on any ticket, write down Eduardo's available time and any known time off in the brief. If the work doesn't fit, propose splitting it into smaller tickets before starting.
G2 Ask the owner before building a new pattern. If the work uses a pattern not yet built in this repo by us (e.g. a new V2 agent, a new codegen flow), the first step is a short question for Eduardo to ask Hyrum (or whoever built the reference, such as the DTI agent on V2). Do not start building until that answer is recorded in the brief. Copy an existing working reference; never improvise around it.
G3 Wednesday risk check. Every Wednesday by 12:00 CST, report each in-flight deliverable as on-track only with runnable proof (command + output), otherwise AT RISK. Anything AT RISK goes to Eduardo the same day with a handoff plan. Never surface risk for the first time on Thursday or Friday.
G4 Runnable proof, not labels. 'Done' or 'on track' requires a runnable checkpoint someone else can run (clean regen from committed inputs + fixtures passing, zero hand patches). Labels, version fields, or PR titles are not proof.
G5 Short handoffs. A handoff is at most one screen: what works, how to run it, what's left, who to ask. No long docs, no speculative rabbit-holes. If Eduardo has time off coming, the handoff is ready 2 working days before he leaves.
G6 Own it, no blaming tools. Reports to Eduardo and anything drafted for Will never blame Claude, agents, or tools; state what happened and what changes.
<!-- will-delivery-G1-G6-20261109 END -->
