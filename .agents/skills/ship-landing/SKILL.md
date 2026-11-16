---
name: ship-landing
description: Load when a ship reports a PR or ready branch, when deciding or monitoring landing, and before task cleanup.
user-invocable: false
metadata:
  internal: true
---

# Ship landing

For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` reports `done [at=<epoch>]: PR <url> checks green` after CI is green, while `direct-PR` reports `done [at=<epoch>]: PR <url>` after opening the PR, each only for a non-draft PR; a lane that deliberately holds a draft declares a wait instead, and `bin/fm-pr-check.sh` refuses to arm merge monitoring on a draft.
Run `bin/fm-pr-check.sh <id> <PR url>` with the URL copied from that ready signal or the resolved checks-green `fm-crew-state.sh` line - it records `pr=` and the forge's `pr_head=` when available in the task's meta and arms the watcher's merge poll.
That merge poll cannot wake firstmate for a named external PR check; firstmate arms the separate check watch and the paused worker does not poll, under `process-event-sources`.
`bin/fm-dod-lib.sh` owns the named-head gate on that ready signal: a ship `done:` whose named head exists only in the worker's disposable copy is not ready (`bin/fm-crew-state.sh` reports blocked, `bin/fm-pr-check.sh` refuses to register, and a secondmate does not publish that done upstream).
That blocked reading is the gate working, not a stuck worker, so steer the worker on the commit the refusal names rather than waiting.
A `forge=external` task reports `done [at=<epoch>]: review <url> uploaded for review` instead: run `bin/fm-review-check.sh <id> <review url>` rather than `bin/fm-pr-check.sh`, which arms no merge watch, then always escalate the review URL to the captain whatever the yolo setting, because firstmate can neither observe nor perform its approval or merge.
A direct-PR worker pushes that commit to its PR branch, and a local-only worker commits it on its ship branch.
A no-mistakes worker re-validates it with /no-mistakes so the pipeline stays the one publisher; it never pushes from its copy.
In no-mistakes mode the earlier `done [at=<epoch>]: {summary}` is the pipeline handoff and is not gated.
Tell the captain the PR's full `https://...` URL copied from the worker's ready line, the resolved checks-green crew-state line, or the task's `pr=` metadata, a concise outcome summary, and the no-mistakes risk level when applicable.
A captain instruction to merge is explicit authority; `yolo` is the only standing routine merge authority.
When `bin/fm-merge-review.sh covers <PR url>` exits 0, this home requires the two-model merge review for that repository ([`docs/configuration.md`](../../../docs/configuration.md) "Merge review").
Never run that review, a test, a build, or a verification step in the supervisor session, and never read the full reviews into it.
Dispatch a scout through `bin/fm-spawn.sh` whose brief names the PR URL and the full head commit; it fetches that commit into its own copy, runs any exact-head verification the task needs, and runs `bin/fm-merge-review.sh run` at that head.
The script, not the worker, writes the prompt, the snapshot, and every receipt, and a worker never edits a review or writes a verdict for a seat.
Read only the one `merge-review:` verdict line, from the scout's status or from `bin/fm-merge-review.sh check <PR url> --head <full-sha>`, which is safe in a supervisor session.
`approved` allows `bin/fm-pr-merge.sh <id> <PR url> --expected-head <full-sha>` under the merge authority that already exists; `blocked` is a dissent to relay as a finding, and only a new head with new reviews clears it; `incomplete` means a seat has no valid review yet.
A changed head has no reviews, so dispatch again for the new head, and never count a review of another head.
The supervisor runs that merge command itself unless a current captain order delegates the merge: then the worker's instructions record the existing authority for that PR and head, and the worker executes that recorded authority through the same command and never decides one.
For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file, print one line only when firstmate should wake, print nothing otherwise, finish before `FM_CHECK_TIMEOUT`, then bind its current bytes with `bin/fm-check-register.sh <id>` before the watcher may execute it.
Retire a custom check only through `bin/fm-check-unregister.sh <id>` (or `bin/fm-teardown.sh` for a spawned task); never hand-compose an `rm` with `$STATE`/`$ID`.

Tear down a ship task only after landing is confirmed.
A teardown refusal for uncommitted or unlanded work is a stop-and-investigate result, never an obstacle to bypass.
Never force teardown without explicit discard authority.
After successful teardown, record completion, retain only the configured recent Done history, and re-evaluate queued work whose blockers and time gates have cleared.

A secondmate is persistent and an empty queue is healthy.
Retire one only on an explicit captain or main-firstmate decision, after loading `secondmate-provisioning`; its home must contain no work under way, and forced discard still requires explicit captain authority.
<!-- goal-integrity-20261109 BEGIN: Eduardo's words, verbatim; only Eduardo can change this block -->
## Goal integrity rules (Eduardo, 2026-11-09)
How this applies here: reporting runbook for PR-ready and done claims: Rule D lines and Rule F self-audit before reporting or landing.
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
How this applies here: reporting runbook for PR-ready and done claims: G4 runnable proof, not labels; G6 ownership language.
These add to the goal-integrity Rules A-F and the six build-integrity rules (data/captain.md) and replace none of them. Canonical copy: /Users/eduardopicazo/orca/workspaces/firstmate/data/will-delivery-rules-20261109.md (sha256 a7ef57abcf74).

# Will delivery rules G1-G6 (from Eduardo, Nov 9 2026, via Regulis at 4:33 PM CST)

G1 Time constraints first. Before taking on any ticket, write down Eduardo's available time and any known time off in the brief. If the work doesn't fit, propose splitting it into smaller tickets before starting.
G2 Ask the owner before building a new pattern. If the work uses a pattern not yet built in this repo by us (e.g. a new V2 agent, a new codegen flow), the first step is a short question for Eduardo to ask Hyrum (or whoever built the reference, such as the DTI agent on V2). Do not start building until that answer is recorded in the brief. Copy an existing working reference; never improvise around it.
G3 Wednesday risk check. Every Wednesday by 12:00 CST, report each in-flight deliverable as on-track only with runnable proof (command + output), otherwise AT RISK. Anything AT RISK goes to Eduardo the same day with a handoff plan. Never surface risk for the first time on Thursday or Friday.
G4 Runnable proof, not labels. 'Done' or 'on track' requires a runnable checkpoint someone else can run (clean regen from committed inputs + fixtures passing, zero hand patches). Labels, version fields, or PR titles are not proof.
G5 Short handoffs. A handoff is at most one screen: what works, how to run it, what's left, who to ask. No long docs, no speculative rabbit-holes. If Eduardo has time off coming, the handoff is ready 2 working days before he leaves.
G6 Own it, no blaming tools. Reports to Eduardo and anything drafted for Will never blame Claude, agents, or tools; state what happened and what changes.
<!-- will-delivery-G1-G6-20261109 END -->
