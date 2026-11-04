---
name: compound
description: "Human-started command: it runs only when the human's message begins with `/compound`, or when a shipping or autopilot run reaches its lesson operation. On any other request do not load or follow it; tell the human to type that command. Captures one reusable lesson from a real failure, a correction or a surprising review result, as a candidate in the central knowledgebase. Use when verified work produced reasoning that the final code, tests and existing lessons do not already carry. Not for routine runs that simply ended."
license: MIT
metadata:
  ak_catalog_id: compound
  ak:
    mode: manual
---

Capture a reusable lesson tied to a real failure, correction or surprising review result. No
manufactured lesson just because a run ended.

## When to use

- A problem was solved and verified, and the reasoning that solved it is not recoverable from the
  final code, tests, types or the project's existing lessons.
- A human corrected the agent's approach, and the correction would apply to future work.
- A review raised something nobody expected, and the surprise is about the project rather than
  about one line.
- An existing lesson turned out to be materially wrong or incomplete in the work just done: update
  it rather than adding a second one.

## Not for

- A run that went as planned. Completion, effort and diff size do not make a lesson.
- Auditing, merging or retiring lessons already captured. That is `compound-refresh`, a separate
  human-started run.
- Writing anything into the working repository. Lessons are project knowledge and the central
  knowledgebase owns them (ruling `central-kb-owns-project-artifacts`).
- Promoting the learning runtime's ledger entries wholesale. A confirmed ledger lesson is evidence
  for a capture, never a substitute for one (ruling `learning-drafts-not-publishes`).

## Authority

Authority: `explicit` at the public entrypoint, `model` at the phase operation lesson.capture, and
`explicit-or-delegated` at `lesson.publish`. A human starts the public entrypoint by typing
`/compound`. A request in prose is not a start, even when it names this skill or the command.
`super-ship` and `autopilot` reach this skill only through lesson.capture, which drafts a candidate
from evidence already in the run and never publishes. Publishing runs through
`lesson.publish`: a human's explicit say-so in the session, or a runner-validated grant covering
`publish-lesson`. Where the host cannot validate that grant, publishing stops for explicit
invocation and the candidate stays a draft (ruling `entrypoint-phase-operation-split`).

## Inputs

- The run's evidence: the failure, the correction or the review finding, referenced by artifact id
  and hash. Absent: `complete` with no lesson, and the report says there was no trigger.
- The knowledgebase adapter's `readContext`, to find an existing lesson on the same subject.
  Unavailable: `needs-input`.
- Optional, under the `learning` profile: `ak learn review report` for the repository's active
  review patterns and guardrail drafts, and `ak learn memory show` for its working memory and
  confirmed lessons. A pattern or lesson there is admitted as supporting evidence only where the
  evidence gate admitted it (protocol [`evidence-gate`](../../references/shared/protocols/evidence-gate/PROTOCOL.md)); a `candidate` pattern or a `hypothesis`
  lesson is context, not support. These are runtime commands, not skills, and the runtime is an
  optional host adapter; its absence changes nothing below (ruling
  `learning-runtime-is-host-adapter`).

## Workflow

1. **Check how this run was started**, before any other step and before any tool call. It is started
   only when the human's message begins with `/compound`, when a `super-ship` or `autopilot` run
   reached lesson.capture, or when `lesson.publish` runs under a validated grant. A request in prose
   is not a start, even when it names this skill or the command, or asks for this work without
   naming either. With none of the three, stop before reading the artifacts, checking inputs or
   answering the task: the only response is to tell the human to type `/compound` followed by
   their request.
2. **Find the trigger.** Name the failure, correction or surprising review result, and the artifact
   where it happened. No trigger: stop with no lesson and say so.
3. **Apply the counterfactual.** If this lesson disappeared, would a future engineer reading the
   final implementation still be likely to repeat the mistake or redo substantial investigation? If
   not, write nothing and report why. An explicit invocation asks for the judgment now; it does not
   lower the bar.
4. **Look for the lesson already written.** Search the knowledgebase for the subject, and the
   runtime's ledgers when the profile is installed. A matching lesson that is still right means
   nothing to capture. A matching lesson made wrong or incomplete by this work is superseded: the
   new candidate names it in `supersedes`.
5. **Draft one lesson.** A statement that applies to future work, its trigger bound to the
   occurrence, the evidence that shows it is real, and where it applies. One lesson per run: a
   session that produced several gets several runs, because a batched capture blurs which evidence
   supports which statement. Load
   [the prose-quality reference pack](../../references/shared/references/prose-quality/REFERENCE.md) before wording it.
6. **Propose it** through the adapter's `proposeLesson` as a `candidate`
   ([`schemas/lesson.schema.json`](../../references/shared/schemas/lesson.schema.json)).
7. **Publish only on authority.** At the public entrypoint, publish when the human says so in this
   session. At lesson.capture, never. At `lesson.publish`, only under the grant.

## Hard gates

Gate: no lesson without a trigger. A run that simply ended produces nothing, and the report says
so (release scenario 23).

Gate: a candidate is a draft. Proposing it is not publishing it, and a completed ship is not
permission to rewrite project knowledge (ruling `learning-drafts-not-publishes`).

Gate: one lesson per run.

Gate: nothing is written into the working repository, whatever the knowledgebase's availability.

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "The run went smoothly, but it was long; there must be something worth recording." | Effort is not evidence, and a lesson with no trigger is the manufactured output scenario 23 forbids. | Report that nothing qualifies and stop. |
| "The ledger says this pattern is active, so the lesson is proven." | Active is a count of events, not a statement that holds for future work, and a ledger entry is a draft. | Cite the pattern as evidence and apply the counterfactual to the statement you draft. |
| "Ship finished and the human seemed pleased; I'll publish the lesson." | Publishing needs explicit authorization or a `publish-lesson` grant; approval of the ship is neither. | Propose the candidate and report that it awaits publication. |
| "The knowledgebase is down; I'll save the lesson under docs in the repo for now." | Project knowledge written into the repository is the failure the central knowledgebase exists to prevent. | Stop with `needs-input` and hand back the drafted text. |
| "These three things all came out of one session; one lesson can cover them." | A batched lesson loses which evidence supports which claim, and it will be refreshed as one unit. | Capture one. Recommend a separate run for each of the others. |

## Outputs

- `lesson` ([`schemas/lesson.schema.json`](../../references/shared/schemas/lesson.schema.json)), status `candidate`, through `proposeLesson`, with its
  trigger, evidence, where it applies and anything it supersedes.
- On explicit authorization or under the grant, the same lesson published.
- A report: the trigger, the counterfactual answer, the lesson or the reason there is none, and
  whether it was published or awaits publication.

## Side effects

`artifact-write`, `scratch-write`, `kb-draft`, `kb-publish`. No `workspace-write`: this skill
never edits the repository it learned from.

`kb-publish` is a remote side effect. Its idempotency key derives from the run, the operation, the
lesson's identity and its artifact hash, and the read-back is the lesson as the knowledgebase
returns it ([`adapters/runner-contract/CONTRACT.md`](../../references/shared/adapters/runner-contract/CONTRACT.md)). A publish whose read-back cannot be performed
is `failed`, never complete.

## Stop conditions

- `complete` — one candidate proposed, published where authorized; or no trigger, or the
  counterfactual failed, and the report says which.
- `needs-input` — the run was started by neither the typed command, a phase operation nor a
  validated grant, which returns the command to type and nothing else; the knowledgebase adapter
  is unavailable; or publishing was asked for without authority the host can validate.
- `failed` — a write's read-back could not be performed.

## Limits

- Lessons per run: 1 (gate).
- Ledger evidence: only what passed the evidence gate counts as support (gate).
- Lesson statement length: short enough to apply without rereading the session (guidance).
