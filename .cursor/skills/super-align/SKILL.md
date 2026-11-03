---
name: super-align
description: "Human-started command: it runs only when the human's message begins with `/super-align`, or under a validated grant, or when a supervisor's bypass grant passes the bundle's `ak-gate.mjs bypass check`, or when the repository or environment opts into the unattended policy and `ak-gate.mjs unattended check` exits 0. On any other request do not load or follow it; tell the human to type that command. When prose asks for this alignment work, do not answer its questions or inspect project context; tell the human to type `/super-align` followed by their request. Grills an unsettled request into agreed direction: a design tree worked in rounds, named terms, two or three approaches with a recommendation, and an explicit human yes before anything is built. Use when what to build is not yet agreed. Not for a request that already carries acceptance criteria, and not for a single-file fix with no decision in it."
license: MIT
metadata:
  ak_catalog_id: super-align
  ak:
    mode: manual
---

Grill the request, establish shared vocabulary, reach approved direction or an explicit unresolved
decision. Nothing is implemented before a human approves.

## When to use

- A human describes a feature, change or problem and the direction is not yet agreed: no acceptance
  criteria exist, and the approach is still open.
- The request bundles several outcomes and nobody has said which one this run owns.
- An approach question turns on where a seam or an interface goes and the project has recorded no
  decision for it.
- A term in the request means different things to different readers and the glossary does not
  settle it.
- A delegated controller holds a charter naming the `align-answer` checkpoint category and a
  bounded alignment question inside that charter is open.

## Not for

- A request that already states its acceptance criteria and names the existing pattern to follow.
  Confirm the understanding in two sentences, take the yes and hand off; a round-based interview
  re-decides what the human already decided.
- A single-file rename or typo fix with no decision in it. That work enters at build.
- Turning an approved direction into a specification and tickets. That is `super-bound`, which
  starts from this skill's approved result rather than reopening it.
- Reviewing a written specification, plan or ADR for coherence and decision readiness. That is
  `doc-review`.
- Resolving a decision ticket that belongs to a map. The map's owner brings the ticket to a fresh
  run of this skill that a human starts; a charting session may not start it (ruling
  `entrypoint-phase-operation-split`).

## Authority

Authority: `explicit` at the public entrypoint, `delegated-grant` at the phase operation
`align.run`. A human starts the public entrypoint by typing `/super-align`. A request in prose
is not a start, even when it names this skill or the command. A delegated controller starts
`align.run` only under a runner-validated grant covering `align-answer`
([`adapters/runner-contract/CONTRACT.md`](../../references/shared/adapters/runner-contract/CONTRACT.md)), and only for a bounded question inside the charter's work
source. Where the host cannot validate that grant, the operation stops for explicit invocation
rather than answering (ruling `entrypoint-phase-operation-split`). No skill starts this skill
directly.

Under a bypass grant (ADR-0008), a supervisor-held file stands in for the typed command for one
task. From the task's worktree, run `node <this skill's directory>/../../bin/ak-gate.mjs bypass check --grant <path> --task <id>
--phase super-align`: exit 0 is the start, and a refusal is a stop with
`needs-decision`. The grant starts the interview and nothing else. The explicit yes at step 11 still
comes from the supervisor through `needs-decision`; the worker never approves its own direction.

Under the unattended policy (ADR-0014), `node <this skill's directory>/../../bin/ak-gate.mjs unattended
check --phase super-align` exiting 0 is the start, with no command or grant (an exception to ruling
`entrypoint-phase-operation-split`). Each frontier round and the step 11 approval then proceed with your own recommended answers, recorded as unattended advances
and never as an approval; record the `align` gate as [the unattended-lifecycle reference](../../references/shared/references/unattended-lifecycle/REFERENCE.md) says.

## Inputs

- The request, as prose from the human. Absent: return `needs-input` and ask for one. A request
  inferred from repository state is not a request.
- Recorded project context, read through the knowledgebase adapter's `readContext`: the glossary,
  the `concept` and `system` pages in scope, and any `adr` that already settles part of the
  question. Load
  [the knowledgebase-binding reference pack](../../references/shared/references/knowledgebase-binding/REFERENCE.md)
  first and run its check: it gives the commands and tells an unconfigured knowledgebase from a
  broken one. An empty result is a fact, not an error — say the project has recorded none and
  continue. An unavailable adapter is a coverage limit: name missing `kb-read` and the cause the
  check printed — no committed `ak.kb.yaml`, or a knowledgebase this machine has not registered —
  never a missing `ak.install.yaml`, which no knowledgebase depends on. Continue the interview
  through the six-field restatement, then stop before publication with `needs-input` naming both
  `kb-read` and `kb-write` and that setup step. A configured knowledgebase that fails or cannot be
  reached returns `failed`; stop and report it rather than proceeding from memory.
- At `align.run` only: a `charter` ([`schemas/charter.schema.json`](../../references/shared/schemas/charter.schema.json)) listing the `align-answer`
  checkpoint category. Absent, or listing a different category: `needs-input`.
- Facts about the codebase are this skill's own job to find. A fact the agent could look up is
  never a question for the human, and looking it up never blocks a round.

## Workflow

1. Check how this run was started, before any other step and before any tool call. It is started
   only when the human's message begins with `/super-align`, when a controller started the phase
   operation `align.run` under a validated grant, when the bypass check in Authority exits 0, or
   when its unattended check exits 0. A
   request in prose is not a start, even when it names this skill or the command, or asks for this
   work without naming either. With neither, stop before answering the task, inspecting project
   context or checking inputs: the only response is to tell the human to type `/super-align`
   followed by their request.
2. Classify the work as **bounded**, **standard** or **architectural** from its ambiguity and how
   far it cuts across the system. Say which and why in one line. Uncertain lands on the heavier
   classification.
3. Run the coherent-work gate: list every outcome in the request that carries its own acceptance
   boundary and could be delivered without the others. More than one — propose a plain-language
   breakdown, state only the relationships the material supports, and ask which one this run owns.
   The rest are context, not scope.
4. State a hypothesis for what the human wants and a confidence number for it. Below roughly 70,
   state the reason on the same line.
5. Load [the domain-modeling reference pack](../../references/shared/references/domain-modeling/REFERENCE.md) before
   naming any term, and [the codebase-design reference pack](../../references/shared/references/codebase-design-vocabulary/REFERENCE.md)
   when the question turns on where a seam or an interface goes.
6. Build the design tree: each decision branches into the decisions that hang off it. The frontier
   is every decision whose prerequisites are already settled.
7. Ask the whole frontier in one round. Number each question and attach the answer you would give
   and the reason for it. Then stop and wait for the human.
8. When an answer names a convention rather than a want, probe once: ask what they would actually
   want if they did not have to justify the choice to anyone.
9. Recompute the frontier from the answers and run the next round. Stop asking when the frontier is
   empty and you can predict the human's answer to the next three questions you would ask.
10. Present two or three approaches with their trade-offs, leading with the one you recommend and
    why. A single option is not a choice; name what you rejected and on what grounds.
11. Restate the direction in six fields — Outcome, User, Why now, Success, Constraint, Out of scope
    — and ask for approval. Out of scope is never omitted. Under a bypass grant, ask by reporting
    `needs-decision` with the restatement and stop; only the supervisor's answer is a yes.
    Load [verification evidence](../../references/shared/references/verification-evidence/REFERENCE.md). For any
    success field describing a rendered interface or running service, name the observable surface,
    user path or request, and evidence kinds the project declares. Do not assume a browser, trace
    collector or running service.
12. On an explicit yes (under the unattended policy, the recorded step 11 advance), publish the settled vocabulary as a `concept` page and the direction as an
    `adr` with status `proposed`. On a fork the human cannot settle, publish a `type: decision`
    ticket instead and say what it blocks. If the knowledgebase adapter was unavailable, publish
    nothing and return `needs-input` naming `kb-read`, `kb-write` and the setup step the check
    printed; the completed interview is returned in the session so publication can resume without
    repeating it.

## Hard gates

Gate: nothing is implemented before approval. On every classification this skill writes no source
file, scaffolds no project and starts no implementation skill until the human has approved the
restated direction (under the unattended policy, until the step 11 unattended advance is recorded). The ceremony scales with the work; the gate does not.

Gate: approval is an explicit yes to the restatement. "Whatever you think is best", "sounds good",
"sure, let's go" and silence are not approval, nor is an unattended advance. Restate and ask again.

Gate: complexity found mid-run upgrades the classification, and nothing downgrades it. Say when it
moves and why.

Gate: a fork the human cannot settle in this session leaves as a `type: decision` ticket. A guess
recorded as a settled decision is the failure this skill exists to prevent.

Gate: at `align.run`, an unbounded or out-of-charter question returns `needs-input`, never a decided
answer, and no implementation file is written in that operation.

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "It's bounded and the design is obvious — I'll start while they read it." | The gate is the approval, not the design's length. | Present the design, then stop until you hear an explicit yes. |
| "This is too simple to need a design." | Simple means a short design, not no design. | Write the two sentences, then take the approval. |
| "They said 'whatever you think is best', so that is a yes." | That answer hands the decision back; it agrees to nothing, and the human has not yet seen a direction to agree to. | Restate the direction in the six fields and ask again for a yes or a change. |
| "It grew while I worked, but I'm nearly done — re-classifying now wastes a round." | Hidden complexity upgrades the classification and nothing downgrades it; "nearly done" is when the upgrade matters most. | Stop, say the classification moved and why, and run the heavier path. |
| "The ask is clear enough — more questions would waste their time." | An ask that is clear to the agent is the shape of an assumption, not of agreement. | Run the frontier round. If you can already predict the next three answers, say so and go to the restatement. |
| "The knowledgebase is not configured, so the interview cannot start." | Unavailable is not failed. The adapter contract makes missing `kb-read` a reported limitation, while the questions themselves need only the human channel. | Name missing `kb-read`, run the interview, and stop at publication with `needs-input` naming both `kb-read` and `kb-write`. |

## Outputs

- `concept` page — the settled vocabulary for this scope, published through the knowledgebase
  adapter's `publishArtifact` under a `kb-document` placement naming kind `concept` and the scope.
  The knowledgebase resolves the location and this skill supplies no path (ruling
  `central-kb-owns-project-artifacts`).
- `adr` page — the approved direction, published with status `proposed` through `publishArtifact`.
  This skill never accepts one: acceptance happens in review and never by the author
  (`docs/decisions/0001-kb-document-vocabulary.md`, "Authorship separation carries into the KB").
- `ticket` ([`schemas/ticket.schema.json`](../../references/shared/schemas/ticket.schema.json)), `type: decision`, id shape `align-<scope>-<topic>`,
  published through `publishArtifact` under a `run-artifact` placement when a fork is left open.
- At `align.run`: the alignment result as a run artifact carrying the approved direction or the
  open decision. That operation writes no knowledgebase page.

## Side effects

`artifact-write`, `scratch-write`, `kb-draft`, `kb-publish`. No `workspace-write`: this skill does
not edit the repository under discussion.

`kb-publish` is a remote side effect. Its idempotency key derives from the run, the operation, the
knowledgebase record identity and the published artifact's hash; the read-back is the record ref and
stored hash `publishArtifact` returns, read before the write and confirmed after it
([`adapters/runner-contract/CONTRACT.md`](../../references/shared/adapters/runner-contract/CONTRACT.md), "Idempotency"). A publication whose read-back cannot be
performed is `failed`, never complete.

## Stop conditions

- `complete` — the human approved the restated direction (under the unattended policy, a recorded
  unattended advance, never an approval), and every published artifact's read-back matched what was sent.
- `needs-input` — a start by neither the typed command nor a validated grant, no request, no
  explicit approval (outside the unattended policy, whose recorded advance stands in), a question outside the charter at `align.run`, a fork only the human can
  settle, or publication reached an unavailable knowledgebase adapter. The first returns the
  command to type and nothing else. The unavailable-adapter result names `kb-read` and `kb-write`
  and returns the completed interview without publishing it.
- `cap-reached` — the runner-supplied alignment budget is exhausted. Returns the settled part of the
  tree and the open frontier, and decides none of it.
- `cancelled` — the human ends the run. Nothing is published.
- `failed` — a configured knowledgebase is unreachable or returns an operation failure, or a
  publication's read-back cannot be performed.

## Limits

- Alignment exchanges: the runner-supplied `alignment-budget` (gate when supplied). A cap the runner
  did not supply is not enforced and not guessed; the run records that it was absent
  ([`policies/limits.yaml`](../../references/shared/policies/limits.yaml)).
- Questions per round: the whole frontier, asked once (gate). This skill caps the number of rounds
  at nothing of its own.
- Approaches offered per fork: two or three (guidance). A fork with one real option is presented as
  one and said to be one.
- Confidence below which a hypothesis carries its reason: roughly 70 (guidance).
