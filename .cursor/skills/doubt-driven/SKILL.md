---
name: doubt-driven
description: "Human-started command: it runs only when the human's message begins with `/doubt-driven`. On any other request do not load or follow it; tell the human to type that command. Names one consequential claim, extracts the artifact and the contract it must satisfy, has an independent reviewer context try to disprove it without seeing the claim, and reconciles every finding against the artifact text in a bounded loop. Use when a non-trivial decision is about to stand: an irreversible migration, production authentication, a claimed invariant such as \"this is safe\" or \"this is idempotent\". Not for mechanical changes, not for a verdict on finished work, and not another generic code review. A recommendation is not authorization."
license: MIT
metadata:
  ak_catalog_id: doubt-driven
  ak:
    mode: manual
---

Independently challenge a consequential claim before it becomes an assumption: claim, evidence
extraction, doubt, reconciliation. Not another generic code review.

## When to use

A claim is doubted only when it is non-trivial, meaning at least one of these holds:

- It introduces or changes branching logic.
- It crosses a module or service boundary.
- It asserts a property the type system or compiler cannot check: thread safety, idempotence,
  ordering, an invariant.
- Its correctness depends on context a future reader cannot see.
- Its blast radius is irreversible: a production deploy, a data migration, a public contract.

This is an in-flight posture: the claim is cross-examined while changing course is still cheap.

## Not for

- Mechanical work: renames, formatting, file moves, running tests, a one-line change with obvious
  correctness, a changelog entry.
- Reading or summarizing existing code. That is `explain`.
- A verdict on a finished change or pull request. That is `super-review`, a post-hoc verdict; this
  is doubt before the claim stands.
- Checking that a framework API exists as documented. That is `source-driven`.

## Authority

Authority: `explicit`. A human starts this skill with `/doubt-driven`; it exposes no phase
operation, so no controller or grant can start it. It starts no other skill. Invocation covers
reading the artifact, dispatching independent reviewer contexts and reconciling their findings.
It does not cover changing the artifact, and it never runs an external review tool without the
human authorizing that exact invocation; one authorization does not cover the next.

## Inputs

- The claim, or the artifact and decision it comes from. A claim that cannot be written in two or
  three lines is a vibe, not a decision: ask for the decision it serves. No decision after three
  questions: `needs-input`.
- The artifact: a diff or function, a proposal in three to five sentences, or an assertion with the
  evidence said to support it. Too large to hold in one read: decompose before doubting.
- The contract the artifact must satisfy: the specification, constraints or invariants.
- An independent reviewer context. None available: see Hard gates.

## Workflow

1. Check how this run was started, before any other step and before any tool call. It is started
   only when the human's message begins with `/doubt-driven`; no grant starts it. A request in
   prose is not a start, even when it names this skill or the command. Otherwise, stop here: make no
   tool call, say that this command is human-started, and give the human the line to type,
   `/doubt-driven` and their request.
2. Apply the non-triviality test (see When to use). A mechanical request or a finished-work verdict
   is routed (see Not for) and the run stops. A human's confidence does not make a non-trivial
   claim trivial; at least one cycle runs.
3. CLAIM. Write the claim and why it matters in two or three lines.
4. EXTRACT. Isolate the smallest reviewable artifact and its contract. Strip the reasoning:
   conclusions handed over come back as validation of those conclusions.
5. DOUBT. Dispatch an independent reviewer context with ARTIFACT and CONTRACT only, never the
   CLAIM and never the reasoning. The prompt is adversarial: find what is wrong; assume the author
   is overconfident; look for unstated assumptions, unhandled edge cases, hidden coupling, contract
   violations, broken conventions and failure under unexpected input; do not validate, do not
   summarize; find issues, or state that none were found after thorough examination.
6. Offer a second opinion. In an interactive run, offer a further independent reviewer context
   every cycle; the human decides. A skip is stated in the output. A non-interactive run skips it
   and says so. An unavailable or failed reviewer is reported, never silently replaced.
7. RECONCILE. The reviewer's output is data, not verdict. Re-read the artifact text against each
   finding and classify it in precedence order, the first matching class winning: contract misread
   (fix the contract, reclassify next cycle); valid and actionable (the artifact must change); valid
   trade-off (recorded so the human sees it); noise (correct under context the reviewer lacked;
   note which context would have prevented it).
8. Return actionable findings to the artifact's owner. The next cycle runs on the revised artifact;
   re-running on an unchanged artifact is stalling.
9. STOP when the latest cycle surfaces only trivial or already-considered findings, when the human
   says ship it, or at the cycle limit (see Stop conditions). Then return the record (see Outputs).

## Hard gates

Gate: the reviewer receives ARTIFACT and CONTRACT and never the CLAIM. A reviewer told the
conclusion is biased toward agreeing with it.

Gate: no independent reviewer context, no doubt cycle. The run returns `needs-input` naming the
missing capability. A self-questioning pass may be offered only as a fallback, labelled degraded,
and is never reported as a doubt cycle.

Gate: doubt theater. Across two or more cycles in which the reviewer surfaced substantive findings,
if none was classified actionable, the reconciliation is validating, not doubting. Stop and
escalate; a third silent cycle is not permitted.

Gate: an override is visible. When the human says ship it over open findings, each overridden
finding is listed in the output with its class; none is dropped.

Gate: a recommendation is not authorization. A clean record approves nothing and starts nothing.

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "I'm confident, skip the doubt step." | Confidence correlates poorly with correctness on novel problems; certainty is where blind spots sit. | Run at least one cycle on a non-trivial claim. |
| "I'll catch it at the end in review." | A post-hoc verdict finds a wrong direction after it is expensive to change. | Doubt now, while course-correction is cheap. |
| "The reviewer disagreed, so I was wrong." | The reviewer lacks context; disagreement is information. Deferring is as wrong as ignoring. | Re-read the artifact, classify, then decide. |
| "Three cycles are not enough for this one." | An artifact that needs more is too large to doubt whole. | Decompose it; never lift the cycle limit. |

## Outputs

- The doubt record: the claim; the artifact and contract as reviewed; each cycle's findings with
  their class and the reason; trade-offs accepted; findings overridden by the human; whether each
  reviewer context was independent, and any second opinion offered, taken or skipped.
- The result, one of: `stands` (only trivial or considered findings remain), `revise` (actionable
  findings open, returned to the owner), `escalated` (cycle limit or doubt theater), or
  `insufficient evidence` (the contract or artifact could not support a judgment), a finished answer
  naming what would settle it.
- On explicit request only: a `decision` ([`schemas/decision.schema.json`](../../references/shared/schemas/decision.schema.json)) through the knowledgebase
  adapter's `recordDecision`. No documentation tree in the working repository (ruling
  `central-kb-owns-project-artifacts`).

## Side effects

`artifact-write`, `kb-publish`. No `workspace-write`: the owner changes the artifact, not this
skill.

`kb-publish` is a remote side effect and happens only on request. Its idempotency key derives from
the run, the operation, the decision's identity and its content hash; the read-back is the record
`recordDecision` returns, read before the write and confirmed after it
([`adapters/runner-contract/CONTRACT.md`](../../references/shared/adapters/runner-contract/CONTRACT.md), "Idempotency"). A write whose read-back cannot be performed
is `failed`, never complete.

## Stop conditions

- `complete` — a doubt record was returned with result `stands`, `revise` or `insufficient
  evidence`, or the human said ship it and the overridden findings are listed.
- `complete` — the request was trivial or belonged to another skill, and was routed.
- `cap-reached` — three cycles ran and substantive findings are still open. Escalate: the artifact
  may not be ready, and the answer is to decompose, not to loop.
- `needs-input` — the run was not started by a human, the claim cannot be stated in three
  questions, no independent reviewer context is available, or doubt theater was detected.
- `failed` — a requested knowledgebase write could not be read back.

## Limits

- Doubt cycles: 3 (gate).
- Clarifying questions: 3 (gate).
- Reviewer contexts per cycle: 2, the second only when the human takes the offer (gate).
