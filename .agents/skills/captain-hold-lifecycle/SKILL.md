---
name: captain-hold-lifecycle
description: >-
  Load before treating an investigation, scout report, structured review, or Lavish review as complete, before ending a visual review that exposed a captain decision, when recording or routing the captain's answer, and on any RECORD DIVERGENCE line the wake drain prints.
user-invocable: false
metadata:
  internal: true
---

# Captain-hold lifecycle

A decision is not a separate thing: it is simply a task waiting on the captain.
The one primitive is an ordinary backlog task held for the captain through `bin/fm-captain-hold.sh hold`; its identity is the task id, and that wrapper owns the deterministic mechanics this policy relies on.
The agent performs the semantic inventory because scripts must not infer captain calls from report prose, visual-review artifacts, terminal output, or chat.

## Policy

Every unresolved question that belongs to the captain and is discovered while producing, reading, presenting, or ending an investigation or visual review must be carried by a captain-held task in the authoritative backlog of the home that owns the originating work before that work or review may be treated as complete.
For a Lavish board-backed handoff, pass the reply through `bin/fm-procevent-lavish.sh arm --agent-reply-file` before appending the status; the adapter owns version-specific acceptance ordering.
Prefer holding the work item the question gates over minting a new row; create a new task only when no work item exists to hold.
The originating investigation or review is never its own inventory entry, so hold a separate task for the call and pass `--origin <origin-id>` so `complete` can check it.
Put the question and its options in the hold reason, and keep one held task per genuine gate: a multi-question review is one held task pointing at its report, not a row per question. Represent that task with exactly one board card that consolidates its questions and options; never fan one task id into duplicate same-key cards.
Register or re-hold through `bin/fm-captain-hold.sh hold`, which is idempotent per task id.
After inventorying the whole report and review surface, firstmate runs `bin/fm-captain-hold.sh complete` with every captain-held task id, or with `--none` when nothing waits on the captain.
A scout may attest its own empty inventory only through the narrow command exception in its generated brief's Definition of done.
For a non-empty inventory or a refused command, the scout reports to firstmate rather than writing metadata or backlog records.
A completed investigation and an ended visual review use this same owner and completion command; a visual tool, including Lavish, never owns a parallel completion policy.
Run the command in the originating work's authoritative `FM_HOME`; secondmate-owned work registers in that secondmate home's backlog, and a question already held anywhere is never re-registered as a second row.
When the report inventories a call already held for a different origin in the same home, list that existing task id with `complete --cross-origin <task-id>` instead of holding a duplicate; the call keeps its recorded origin.
Do not close a captain-held task merely because the originating investigation completed, its report was archived, its visual review ended, or its task was torn down.
Holding the work item the question gates is safe for exactly that reason: cleanup keeps such a row open with the finished work's deliverable recorded and returns it to the queue, so it still reads as the captain's own call.
Only `answer` with the captain's words or an evidence-backed `reconcile close` may resolve it.

Never close anything the captain owns without recording what he actually said: `bin/fm-captain-hold.sh answer` writes his exact words into the task and closes a question-shaped call, while `--release` frees a captain-gated work item to proceed.
A merge approval uses that existing release path because approval permits the merge to proceed; cleanup closes the work only after it lands and records what shipped.
Closing a held row at merge approval instead records completion before landing, so the backlog claims completion before the work actually ships.
When the answer changes what a task must build, follow `AGENTS.md` section 7's mid-task ask rule to preserve the captain's words in the brief and steer the worker.
When the captain says "later", that is an answer too: re-hold with `bin/fm-captain-hold.sh hold <id> --reason "<reason>" --until <date>` so the item leaves the live Captain's Call and resurfaces on its date, instead of leaving a live-looking card or fabricating a closure.
"A keyed answer resolves its matching captain-held task" is one capability with one owner, `bin/fm-captain-hold.sh answers`, and every channel that carries a captain answer feeds it the same task id and answer; a channel never maps keys to tasks, records a decision, or resolves anything itself.
Chat already feeds it through `bin/fm-send.sh --resolve-key`, and a captured-answer source feeds it once bound with `bin/fm-captain-hold.sh bind <source-id>`; bind before arming the source, and key each structured question by the held task's id.
An unbound source and a key that names no captain-held task both simply feed nothing: the answer is still captured and firstmate is still woken, and closing falls back to the direct command above.
One answer value is reserved and closes nothing: `reconcile` means "go re-check reality", never "the captain answered", so the shared intake refuses it from every channel and creates nothing.
A bound captured source uses a separate seam: its adapter omits reconcile from keyed answers and emits the selected task id through `reconciles`, the generic runner feeds that into `reconcile-requests`, and the intake verifies the source binding and the local captain-held task before filing the durable board request.
A remote-secondmate card whose task is absent from the main backlog therefore remains announced but cannot create a main-home request; owner-aware request and mutation routing to the authoritative secondmate home is a separate follow-up.
That board-created request is yours to work off in the turn that receives it: `bin/fm-captain-hold.sh reconcile close <id> --evidence-file <path>` records the EVIDENCE and closes a moot call, while `reconcile note <id> --note-file <path>` annotates a genuinely active call and leaves it held.
Both outcomes refuse unless that task still has the pending request created by the captain's board selection, so neither is a standalone way to mutate a captain call.
A normal captain answer also retires any pending request because the call is settled, including close, release, and idempotent replay paths.
A retirement failure makes the command fail without reversing the already-durable answer, close, or note, and `reconcile list` keeps the surviving request visible for retry.
`reconcile list` names every request still outstanding.
Never use `answer` for an evidence-only moot call: `answer` records what the captain said, while `reconcile close` records verified evidence.
A captain-held task closed outside this owner leaves no durable answer, so the completion gate keeps failing until `answer` records the decision the captain actually gave.
Resolved findings, recommendations that need no captain choice, and prose that merely sounds decision-like do not create held tasks.
Bearings reads the resulting structured state and must never compensate by scraping historical reports, visual-review artifacts, terminal output, chat, or other prose.

A captain call can be written down twice - as the keyed status decision the fold reads, and as the backlog task held for the captain - and those two records can disagree without either surface saying so.
`bin/fm-captain-hold.sh diverged` reports that contradiction and the wake drain prints it as `RECORD DIVERGENCE`; it closes nothing, because a captain call closed wrongly leaves review entirely, which is worse than the noise.
Read such a line as "these two records disagree", never as "the captain ruled and someone forgot to file it": a call can dissolve because its premise was false, or turn out to have been a question of fact rather than the captain's to answer.
Reconcile it with what actually happened - `answer` when the captain's own words exist to record, and a fresh `needs-decision` line re-opening the status decision when that resolution was not the captain's word.
The absence of a routed work item is not a divergence and the guard never requires one: when the decision IS the deliverable there is nothing to route.

## Operating sequence

1. Read the complete investigation result and complete the visual review before declaring either complete.
2. Inventory only genuine unresolved choices that require the captain, and find the task each one gates.
3. Firstmate holds that task - or creates one captain-held task for the review's open questions - with a concise reason carrying the question and options.
4. Attest the full inventory for that review pass under the caller authority in Policy above.
5. Relay the choices to the captain as decisions from Bearings' Captain's Call section under `AGENTS.md` section 9; do not use the word hold in captain chat.
6. Close each call only through `answer` (or a channel that feeds `answers`), close a board-requested moot call through evidence-backed `reconcile close`, record a still-active reconciliation through `reconcile note`, use `--until` when the captain defers it, or confirm a channel already closed it.
7. Confirm Bearings reflects the outcome: answered or reconciled-moot calls leave Captain's Call, released work resumes, active reconciliations remain held, and deferred calls sit in Charted Next with their date.

`bin/fm-captain-hold.sh --help` owns command syntax, close modes, legacy-identity compatibility, completion attestation, retry behavior, and close ordering.
`docs/captain-hold-lifecycle.md` records the mechanism and regression evidence without restating this policy.
<!-- goal-integrity-20261109 BEGIN: Eduardo's words, verbatim; only Eduardo can change this block -->
## Goal integrity rules (Eduardo, 2026-11-09)
How this applies here: reporting and status runbook: every report and done claim ends with GOAL CHECK / DEVIATIONS / PROOF; partly or any deviation is not done (Rule D).
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
How this applies here: reporting and status runbook: Wednesday 12:00 CST risk check (G3), runnable proof not labels (G4), no blaming tools (G6).
These add to the goal-integrity Rules A-F and the six build-integrity rules (data/captain.md) and replace none of them. Canonical copy: /Users/eduardopicazo/orca/workspaces/firstmate/data/will-delivery-rules-20261109.md (sha256 a7ef57abcf74).

# Will delivery rules G1-G6 (from Eduardo, Nov 9 2026, via Regulis at 4:33 PM CST)

G1 Time constraints first. Before taking on any ticket, write down Eduardo's available time and any known time off in the brief. If the work doesn't fit, propose splitting it into smaller tickets before starting.
G2 Ask the owner before building a new pattern. If the work uses a pattern not yet built in this repo by us (e.g. a new V2 agent, a new codegen flow), the first step is a short question for Eduardo to ask Hyrum (or whoever built the reference, such as the DTI agent on V2). Do not start building until that answer is recorded in the brief. Copy an existing working reference; never improvise around it.
G3 Wednesday risk check. Every Wednesday by 12:00 CST, report each in-flight deliverable as on-track only with runnable proof (command + output), otherwise AT RISK. Anything AT RISK goes to Eduardo the same day with a handoff plan. Never surface risk for the first time on Thursday or Friday.
G4 Runnable proof, not labels. 'Done' or 'on track' requires a runnable checkpoint someone else can run (clean regen from committed inputs + fixtures passing, zero hand patches). Labels, version fields, or PR titles are not proof.
G5 Short handoffs. A handoff is at most one screen: what works, how to run it, what's left, who to ask. No long docs, no speculative rabbit-holes. If Eduardo has time off coming, the handoff is ready 2 working days before he leaves.
G6 Own it, no blaming tools. Reports to Eduardo and anything drafted for Will never blame Claude, agents, or tools; state what happened and what changes.
<!-- will-delivery-G1-G6-20261109 END -->
