---
name: prototype
description: "Builds a bounded, throwaway prototype that answers one question discussion cannot settle: how a state model or flow behaves when driven, or how a screen reads when seen. The evaluator is named before anything is built. Use when committing the wrong answer would be expensive to unravel and a cheap sketch cannot settle it. Not for deciding what to build, not for polishing working code, and not for implementing the real thing."
license: MIT
metadata:
  ak_catalog_id: prototype
  ak:
    mode: autonomous
    autonomy_unenforceable:
      - "artifact-write is storage only: the host does not compute or check the artifact hash, so envelope hash binding is this package's own work."
      - kb-write is not provided by the host; the knowledgebase adapter supplies it and refuses rather than falling back to a repository path when no knowledgebase is configured, which is why it does not cap this row while that adapter is attached (ruling `fail-closed-adapter-lifts-ceiling`).
---

A bounded throwaway artifact answering a question discussion cannot settle. The evaluator is named
in advance; human-experience questions stay blocked without a human.

## When to use

- A technical question: whether a reducer, state machine or data shape handles the awkward cases.
  Its evaluator may be automated acceptance criteria, and it may run unattended.
- A human-experience question: how a layout reads, how dense a screen feels, how a flow answers a
  person moving through it. Its evaluator is a named human, and without one it does not run (ruling
  `prototype-human-experience-needs-human`).
- A caller such as `wayfind`, `pov` or `ideate` holds a question of either kind and needs an
  artifact to settle it.

## Not for

- Deciding what to build. That is alignment's work, not an artifact's.
- A decision a cheap sketch or a conversation already settles.
- Polishing a feature that works, or implementing the real thing. Prototype code is never the
  production change.

## Authority

Authority: `model`. A controller or a parent skill starts it when the caller's question matches the
description; no human invocation is required and no slash command exposes it.

No grant covers delegation here, because no phase operation exposes this skill:
[`policies/invocation.yaml`](../../references/shared/policies/invocation.yaml) records model-invoked skills as exposing none by construction, so there
is no delegated path for a runner to validate. Starting a prototype grants no authority over the
working tree: the prototype lives in its own workspace and changes nothing a later lane relies on.

## Inputs

- The question, stated in one paragraph. Absent, or a request to build a feature: `needs-input`.
- The evaluator, named before anything is built: the automated acceptance criteria for a technical
  question, or the human who will judge a human-experience one. Unnamed: `needs-input`. A
  human-experience question on a run with no human present stops and escalates rather than
  substituting an automated verdict (ruling `prototype-human-experience-needs-human`).
- A workspace from the runner: runner-owned scratch for a self-contained artifact, an isolated
  worktree where the variants must sit inside an existing page. Never the working tree.
- Any earlier evaluation record for a related question, read before building.

## Workflow

1. Write down the question and the evaluator. Decide whether the question is technical or about
   human experience; if the latter and no human is present, stop here and escalate (ruling
   `prototype-human-experience-needs-human`).
2. Apply the one rule: do not fake the dimension being tested. A question settled by driving needs
   something that can be driven, so a screen that only looks right does not answer it. A question
   settled by seeing needs the real finish, so a thin sketch does not answer it either.
3. Pick the branch. Logic, state or data shape: follow `./references/logic.md`. What something
   should look like: follow `./references/ui.md`. Genuinely ambiguous with no one to ask: pick the
   branch the surrounding code suggests and state the assumption at the top of the prototype.
4. Build under the six rules (see Hard gates), in the workspace from Inputs.
5. For the UI branch, build three variants by default and never more than five. Each differs in
   structure, hierarchy or primary affordance, not colour or copy. The variant switcher is gated
   out of production builds (see Hard gates).
6. Hand the prototype to the named evaluator. For a technical question, run the acceptance criteria
   and show their results. For a human-experience question, the human's own judgment settles it
   (ruling `prototype-human-experience-needs-human`).
7. If the evaluator's answer changed what they want to build rather than answering the question,
   stop and hand back what was learned. Do not build for a question that has moved.
8. Publish the evaluation record (see Outputs), `settled` or `stopped`; return it to the caller.

## Hard gates

Gate: the evaluator is named before anything is built, and only that evaluator settles the
question. The builder's own view of its artifact is not a verdict (ruling
`prototype-human-experience-needs-human`).

Gate: a human-experience question is never answered by an automated verdict. With no human
present, the run stops and escalates (ruling `prototype-human-experience-needs-human`).

Gate: the six rules.
1. Throwaway from the first line, and marked as a prototype where a reader would see it.
2. Trivial to run: one command, or one file opened directly.
3. No persistence unless persistence is the question; then a scratch store named as disposable.
4. No polish: no tests, no error handling beyond what makes it runnable, no abstractions.
5. Surface the state: after every action or variant switch, render the full relevant state.
6. Capture it when done: the answer goes into the evaluation record, the code stays in its
   workspace, and only the validated decision moves on.

Gate: UI variants differ in structure, hierarchy or primary affordance, never only in colour or
copy, and the variant switcher is gated out of production builds.

Gate: prototype code is never merged as-is. Whatever is folded into the real code is rewritten under
the project's own standards by the lane that owns that change.

Gate: a recommendation is not authorization. A settled question tells the caller what was learned;
it starts no build and changes nothing outside the prototype's workspace.

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "No one is watching, but I can tell which layout is least cluttered." | The question is how it reads to a person. The builder's reading is a guess about their experience. | Stop, report that a human evaluator is needed, and escalate. |
| "Variant B won; the component already works, so merge it." | It was built with no tests and minimal error handling, to be compared, not shipped. | Record the decision. The owning lane rewrites it properly. |
| "A static mock-up is quicker and shows the flow well enough." | A flow is judged by driving it. A picture of it fakes the dimension under test. | Build something the evaluator can drive. |
| "These three card grids differ in colour; that's three variants." | Variants that agree on structure answer nothing about structure. | Redraft one with a different layout or primary affordance. |

## Outputs

- The prototype, in its workspace, with the question and the evaluator stated at its top.
- The evaluation record, an `evaluation` ([`schemas/evaluation.schema.json`](../../references/shared/schemas/evaluation.schema.json)) with `kind:
  prototype`: the question, `question_kind` (`technical` or `human-experience`) and the evaluator
  as named. `settled` adds what was built and where, the options shown, the choice and any
  adjustments, the answer, `settled_by`, the acceptance results for a technical question, and what
  remains open. A human-experience question has a human evaluator and is `settled_by: human`
  (ruling `prototype-human-experience-needs-human`). `stopped` adds the stop, `no-human-present`
  or `question-moved`, and what was learned. No question or evaluator named: nothing is recorded.
- Published through the knowledgebase adapter's `publishArtifact` under a `run-artifact`
  placement, never written to a repository path (ruling `central-kb-owns-project-artifacts`). The
  record is continuity, not a plan.

## Side effects

`scratch-write`, `process-exec`, `artifact-write`, `kb-publish`. `process-exec` runs the prototype
and its acceptance criteria inside its workspace. No `workspace-write`: the prototype is built in
its own workspace and never in the working tree.

`kb-publish` is a remote side effect. Its idempotency key derives from the run, the operation, the
record's identity and its content hash; the read-back is the record `publishArtifact` returns,
read before the write and confirmed after it ([`adapters/runner-contract/CONTRACT.md`](../../references/shared/adapters/runner-contract/CONTRACT.md),
"Idempotency"). A write whose read-back cannot be performed is `failed`, never complete.

## Stop conditions

- `complete` — the named evaluator settled the question and the `settled` record is published.
- `needs-input` — no question, no named evaluator, or a question that moved and is handed back.
- `needs-input` — a human-experience question on a run with no human present. The run stops and
  escalates; it never substitutes an automated verdict (ruling
  `prototype-human-experience-needs-human`).
- `needs-input` — no knowledgebase to publish the record to. The answer is returned to the caller
  and nothing is written to the repository instead.
- `failed` — the record's read-back could not be performed.

## Limits

- UI variants: 3 by default (guidance), never more than 5 (gate).
- Questions per prototype: 1 (gate). A second question is a second prototype.
