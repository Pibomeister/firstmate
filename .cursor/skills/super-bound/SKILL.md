---
name: super-bound
description: "Human-started command: it runs only when the human's message begins with `/super-bound`, or under a validated grant, or when a supervisor's bypass grant passes the bundle's `ak-gate.mjs bypass check`, or when the repository or environment opts into the unattended policy and `ak-gate.mjs unattended check` exits 0. On any other request do not load or follow it; tell the human to type that command. Turns an approved direction into a decision-level specification, a reviewed plan and a dependency graph of zero-context implementation tickets with named verification. Use when the direction is agreed and the work needs bounding. Not for deciding what to build, and not for a reviewed ticket that already carries its acceptance criteria."
license: MIT
metadata:
  ak_catalog_id: super-bound
  ak:
    mode: manual
---

Requirements and specification, implementation plan, dependency graph, ownership boundaries,
acceptance criteria and verification commands. A decision ticket is never an implementation ticket.

## When to use

- An approved direction exists and the work needs a specification, a plan and tickets before anyone
  builds.
- A specification exists but nobody has settled the slicing, the blocking edges or which ticket owns
  which file.
- The approved direction covers several modules and no capability map has been drawn.
- A delegated controller holds a charter naming the `spec-approval` checkpoint and an approved
  alignment result binds to the current source revision.

## Not for

- Deciding what to build. An unsettled direction goes back to a human-started alignment run; this
  skill starts from an approved result and does not reopen it.
- A reviewed ticket that already carries its acceptance criteria and verification command. That
  work enters at build, and re-bounding it re-decides what a reviewer already accepted.
- Charting a multi-session effort into decision tickets and fog. That is `wayfind`.
- Reviewing the specification for coherence or decision readiness. This skill calls `/ak:doc-review`
  for that rather than grading its own artifact.
- A single mechanical rename with one call site and one test.

## Authority

Authority: `explicit` at the public entrypoint, `delegated-grant` at the phase operation
`bound.run`. A human starts the public entrypoint by typing `/super-bound`. A request in prose
is not a start, even when it names this skill or the command. A delegated controller starts
`bound.run` only under a runner-validated grant covering `spec-approval`, and only with a second
grant covering `ticket-approval` when the operation emits implementation tickets
([`adapters/runner-contract/CONTRACT.md`](../../references/shared/adapters/runner-contract/CONTRACT.md)). Where the host cannot validate a grant, the operation
stops for explicit invocation rather than approving on the controller's word (ruling
`entrypoint-phase-operation-split`). No skill starts this skill directly; it calls `doc-review`,
which is model-invoked, and that direction is the legal one.

Under a bypass grant (ADR-0008), a supervisor-held file stands in for the typed command for one
task. From the task's worktree, run `node <this skill's directory>/../../bin/ak-gate.mjs bypass check --grant <path> --task <id>
--phase super-bound`: exit 0 is the start, and a refusal is a stop with
`needs-decision`. The grant starts the phase and nothing else. The specification approval at step 8
and every ticket approval still come from the supervisor through `needs-decision`; the worker never
approves its own specification or tickets.

Under the unattended policy (ADR-0014), `node <this skill's directory>/../../bin/ak-gate.mjs unattended
check --phase super-bound` exiting 0 is the start, with no command or grant (an exception to ruling
`entrypoint-phase-operation-split`). The approved-alignment input, open document-review decisions, the specification approval and the ticket approvals then
proceed with your own recommended answers, recorded as unattended advances and never as approvals;
a ticket whose class makes a human the author keeps that class. Record the `bound` gate as
[the unattended-lifecycle reference](../../references/shared/references/unattended-lifecycle/REFERENCE.md) says.

## Inputs

- An approved alignment result that binds to the current source revision. Absent, or bound to a
  different revision: return `needs-input`. A direction approved against other code is not an
  approval of this one.
- Recorded project context, read through the knowledgebase adapter's `readContext`: the `prd` in
  scope, the settled `adr` pages, and the glossary the vocabulary was agreed in. An empty result is
  a fact; an unreachable knowledgebase returns `failed`. The commands, and what an unconfigured
  knowledgebase obliges, are in
  [the knowledgebase-binding reference pack](../../references/shared/references/knowledgebase-binding/REFERENCE.md).
- The project record's configured guidance ([`schemas/project.schema.json`](../../references/shared/schemas/project.schema.json)) for change size and test
  shape. Absent: the starting points below are advisory and nothing enforces them.
- Delegation guidance on that same project record. Missing it is `needs-input`; scorer inputs are
  never invented.
- The project's verification recipes and surface declarations ([`schemas/project.schema.json`](../../references/shared/schemas/project.schema.json)).
  Absent or empty: record the gap; never assume a browser, running service, trace collector or
  command the project did not declare.
- At `bound.run` only: a `charter` ([`schemas/charter.schema.json`](../../references/shared/schemas/charter.schema.json)) listing `spec-approval`, and
  `ticket-approval` where tickets will be emitted. Absent: `needs-input`.

## Workflow

1. Check how this run was started, before any other step and before any tool call. It is started
   only when the human's message begins with `/super-bound`, when a controller started the phase
   operation `bound.run` under a validated grant, when the bypass check in Authority exits 0, or
   when its unattended check exits 0. A
   request in prose is not a start, even when it names this skill or the command, or asks for this
   work without naming either. With neither, stop before reading the repository, checking inputs or
   answering the task: the only response is to tell the human to type `/super-bound` followed by
   their request.
2. Detect before you ask. Read what the repository already states — its dependency manifest, its
   test runner, its lint configuration, its continuous-integration configuration — report what you
   found in two lines, and ask only what is left.
3. When the approved direction spans more than one module, draw the capability map first: a table of
   stable kebab-case module ids, each with its responsibility and what it depends on. The map is
   gated like every other step; a human reviews it before any module's specification is written.
4. Write the specification at decision level: problem, solution, non-goals, acceptance criteria,
   test seams, verification commands, out of scope. No file paths and no code, except a fragment a
   prototype already settled exactly — a state machine, a reducer, a schema, a type shape. Turn
   each vague criterion into a frontier question that proposes how the answer would be verified.
   For each criterion, record its surface and required evidence kinds from the project declaration.
   Load [verification evidence](../../references/shared/references/verification-evidence/REFERENCE.md) for the
   vocabulary; an undeclared facility becomes a visible gap, never an invented check.
5. Choose the test seams before the slices. The fewer seams the feature is verified across the
   better, and the ideal number is one; name the seam you chose and why it is the highest one
   available. Use the vocabulary the alignment run already established with
   [the domain-modeling reference pack](../../references/shared/references/domain-modeling/REFERENCE.md) rather than
   renaming the same things here.
6. When the caller supplies a draft ticket or scorer input, load the delegation reference and run
   `ak delegation <ticket> --project <project-record>` now. A current `ak` on `PATH` is a
   prerequisite: a missing command, or a usage error from an older `ak`, is reported as
   `needs-input` naming that prerequisite, not as a scoring failure. Persist the scorer output,
   readiness and assumptions on the evidence-bearing draft before document review; the draft is not
   an approved implementation ticket.
7. Run `/ak:doc-review` on the specification and resolve everything it returns before cutting a
   ticket. A current review receipt bound to this specification with every decision answered
   satisfies this step; otherwise open decisions return to the human and stop the run.
   For a single-slice ticket whose every changed path the author claims is text-only, the light
   route defined in [the delegation reference](../../references/shared/references/delegation/REFERENCE.md) under
   "Light route for a text-only single-slice ticket" governs.
   While a specification or review decision is open, an evidence-bearing draft, where one exists, is
   kept and retyped `decision`, and no implementation ticket exists. An open assumption is per
   slice; that slice becomes a decision ticket at the zero-context gate and unrelated slices
   proceed.
8. Take the specification approval. A recorded human approval whose artifact hash equals the
   current specification hash satisfies this step. Otherwise the plan record takes approval as
   `specification_approval`, bound to `specification_hash`, so later slicing does not void it.
   Under a bypass grant, report `needs-decision` naming the specification hash and stop; only the
   supervisor's answer is the approval.
9. Load [the delegation reference pack](../../references/shared/references/delegation/REFERENCE.md) and follow its
   ordered stack, readiness, assumptions, authorship-boundary and advisor procedures for every
   zero-context slice.
10. Run `ak delegation <ticket> --project <project-record>` after populating its floor, evidenced
   factors and the `class` seed the reference names; persist its complete JSON with `readiness` and
   `assumptions` before returning, including on `needs-input`. Never derive the class in this body.
11. Give every ticket its interfaces: what it consumes from earlier tickets with exact signatures,
    and what it produces that later tickets rely on with exact names, parameters and return types.
    Write for a skilled developer who knows almost nothing about this toolset or problem domain.
12. Declare the blocking edges, and then declare what the edges do not cover: exclusive file
    ownership per ticket, shared generated artifacts, and global migration numbering. Two tickets
    with no edge between them are still unsafe in parallel when they write the same file.
13. Type-check every ticket. An implementer opening it with an empty context window who still
    cannot do it is not holding an implementation ticket: reshape it, or reclassify it
    `type: decision` and send it back.
14. Self-review, then publish: every acceptance criterion is covered by a ticket, no ticket carries
    an unfinished-content marker or a "same as the earlier ticket" instruction, and each ticket's
    produced names and types match the next one's consumed names exactly. Under a bypass grant,
    report `needs-decision` listing the tickets and their hashes and stop before publishing; only
    the supervisor's answer approves them.

## Hard gates

Gate: a decision ticket is never emitted as executable work. A ticket that fails the zero-context
check is reclassified, never shipped as an implementation ticket because the deadline is close.

Gate: every ticket carries exact scorer output, all six named `readiness` criteria plus
`vague_terms`, and `assumptions` items using `text` and `resolved_as`. Vagueness, an open assumption
or scorer failure stops it; no total, hand-derived class or request to delegate substitutes (ruling
`delegation-class-is-authority-not-finding`). No factor or lowering crosses the sensitive floor
(ruling `sensitive-surface-sets-the-floor`).

Gate: each readiness criterion's evidence states what was checked and where. No readiness or stop
flag is persisted outside the schema: readiness is the six scored criteria with evidence, and the
stop is stated in the result.

Gate: on a ticket whose class makes a human the author, `allowed_changes` remains the full write
scope for the implementer. Name the agent's permitted file and symbol subset in text, in `goal` or
`stop_conditions`, alongside non-file assistance such as research; put prohibited agent work in
`non_goals`. On a decision ticket the boundary lives in `goal` and `non_goals`. Naming a human owner
alone is not that boundary.

Gate: each unresolved vague term becomes a frontier question that proposes the observable, the
workload or fixture, the measurement or oracle and the pass condition, as applicable, that would
verify the answer. Express the pass condition against the value the human supplies, for example
`p95 of <observable> on <workload> is at or below the target you name`; never choose a number or
otherwise invent the missing target.

Gate: a direction spanning independently deployable stack phases is split in the reference's order,
with schema contract separate. Refusal to split emits a decision ticket that itself carries the full
ordered stack as the recommended option, in its `decision` question or its `goal`, with no exception
alternative; size alone is guidance.

Gate: on a supporting host, a ticket whose class requires consultation is not approved until its
`kb_refs` cites the consultation artifact as the delegation reference defines: a `transcript` or
`receipt` evidence reference whose one-line `note` names it judgment evidence and says what it was
used for. A bare path, name or URL is not evidence; an unsupported host cites none (ruling
`advisor-consultation-follows-class`).

Gate: approval binds to the specification's hash, not the whole plan's. A changed specification
does not inherit the old approval; take it again.

Gate: while a specification or review decision is open, an evidence-bearing draft, where one exists,
is kept and retyped `decision`, and no implementation ticket exists. An open assumption is per
slice; that slice becomes a decision ticket at the zero-context gate and unrelated slices proceed.

Gate: no ticket ships with an unfinished-content marker, with "add appropriate error handling" or
"handle the edge cases" in place of the specifics, or with a pointer to another ticket in place of
the work.

Gate: evidence that invalidates a decision settled earlier in this session stops the write. Return a
blocked-or-replan result naming the settled decision and the new evidence; never resolve it
silently.

Gate: the consensus plan gate is entered only on genuine architectural disagreement, declared high
risk, or a review-driven replan — never automatically on a routine breakdown. It is a protocol this
skill enters, not a skill it starts:
[the consensus plan gate protocol](../../references/shared/protocols/consensus-plan-gate/PROTOCOL.md).

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "The ticket is obvious to me, so it is written clearly enough." | The implementer knows almost nothing about this toolset or problem domain. "Obvious to the author" names exactly the context the ticket fails to carry. | Write the consumed and produced signatures and the verification command, then reread the ticket as someone who has seen nothing else. |
| "This ticket is basically the earlier one — I'll say 'similar to' and save the repetition." | A pointer to another ticket is context the implementer's window does not contain. | Repeat the specifics in full in this ticket. |
| "I'll put the file paths in the specification so nobody has to guess." | A path in the specification settles an implementation decision the specification has not made, and the first refactor makes it wrong while it still reads authoritative. | Keep the specification at decision level; paths belong in the ticket, and only where a prototype settled them. |
| "New evidence contradicts what we settled an hour ago — I'll just take the better answer." | A decision settled earlier in the session is not the planner's to overturn quietly; the human who settled it is not in the write. | Stop the write and return a blocked-or-replan result naming the settled decision and the evidence against it. |
| "Their guidance is about a hundred lines a change, so this has to become three tickets." | Change size is a configurable starting point, not a gate, and neither it nor the test split is grounds for a finding on its own (ruling `numeric-heuristics-are-guidance`). | Slice on verifiable behavior. Where the natural slice exceeds the project's own guidance, record the exception in the project record. |
| "They insist on one ticket for the whole migration, so I'll keep it together." | Refactor, expand, flagged behavior, consumer, backfill and contract are independently deployable delivery boundaries; a request cannot collapse them. | Order the stack with contract separate. On refusal, emit a decision ticket that itself carries the full ordered stack as the recommended option, with no exception alternative. |
| "The readiness flag is enough." | A flag hides what was checked, and the ticket schema has no field for it. | Persist the six scored criteria with their evidence and state the stop in the result. |
| "The owner is human, so authorship is clear." | Ownership does not say what agent work is allowed. | Keep `allowed_changes` the implementer's full write scope; name the agent's permitted file and symbol subset and any non-file assistance in `goal` or `stop_conditions`, and prohibited agent work in `non_goals`. |

## Outputs

- `prd` page — the requirements when they are newly stated, published through the knowledgebase
  adapter's `publishArtifact` under a `kb-document` placement naming kind `prd` and the scope. The
  knowledgebase resolves the location and this skill supplies no path (ruling
  `central-kb-owns-project-artifacts`).
- Plan record, a run artifact with envelope schema `plan-record`
  ([`schemas/plan-record.schema.json`](../../references/shared/schemas/plan-record.schema.json)) — the specification, the seams, the slicing and the dependency
  graph, published under a `run-artifact` placement and linked from the `prd`.
- `ticket` ([`schemas/ticket.schema.json`](../../references/shared/schemas/ticket.schema.json)), `type: implementation`, id `bound-<spec>-<slice>` — one
  per slice, with interfaces, ownership, edges, criteria, verification, `readiness`, resolved
  `assumptions` and the exact ticket-time `delegation` output.
- `ticket`, `type: decision` — emitted for an open fork, with the three evidence blocks persisted in
  place of the implementation ticket that could not be written.
- At `bound.run`: the same artifacts as drafts. That operation drafts to the knowledgebase and does
  not publish.

## Side effects

`artifact-write`, `scratch-write`, `kb-draft`, `kb-publish`. No `workspace-write`: this skill plans
the change and never makes it.

`kb-publish` is a remote side effect. Its idempotency key derives from the run, the operation, the
knowledgebase record identity and the published artifact's hash; the read-back is the record ref and
stored hash `publishArtifact` returns, read before the write and confirmed after it
([`adapters/runner-contract/CONTRACT.md`](../../references/shared/adapters/runner-contract/CONTRACT.md), "Idempotency"). A publication whose read-back cannot be
performed is `failed`, never complete.

## Stop conditions

- `complete` — the specification is approved at its hash, every acceptance criterion is covered by a
  ticket, every implementation ticket carries the three evidence blocks, and every published
  artifact's read-back matched what was sent.
- `needs-input` — a start by neither the typed command nor a validated grant, which returns the
  command to type and nothing else; no approved alignment result, an approval bound to a different
  revision, missing project guidance or grant at `bound.run`, a failed scorer, an unresolved
  assumption or vague criterion, a document-review decision left open, or a settled decision that
  new evidence invalidated.
  When assessment ran, the returned draft retains `delegation`, `readiness` and `assumptions`.
- `cap-reached` — the consensus plan gate reached its round cap, or the runner-supplied ticket
  budget ran out. Returns the unresolved architectural question or the undecomposed remainder.
- `cancelled` — the human ended the run before approving the specification.
- `failed` — the knowledgebase is unreachable, or a publication's read-back cannot be performed.

## Limits

- Consensus plan-gate rounds: 5 (gate, [`policies/limits.yaml`](../../references/shared/policies/limits.yaml)).
- Implementation tickets started per run: the runner-supplied `ticket-budget` (gate when supplied).
  A cap the runner did not supply is not enforced and not guessed; the run records that it was
  absent.
- Test seams a feature is verified across: as few as the feature allows, ideally one (guidance).
- Change size: roughly one hundred lines where that is natural, and test shape: roughly 80 / 15 / 5
  across unit, integration and end-to-end tests. Both are configurable starting points carried in
  the project record, neither is enforced here, and neither is grounds for a finding on its own
  (ruling `numeric-heuristics-are-guidance`).
