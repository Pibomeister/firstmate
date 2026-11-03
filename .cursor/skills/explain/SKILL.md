---
name: explain
description: "Human-started command: it runs only when the human's message begins with `/explain`. On any other request do not load or follow it; tell the human to type that command. Explains how and why existing behavior works, from repository and knowledgebase evidence, with every claim traced to a source, marked as inference, or marked unknown. Use when a human asks how or why something in the project works the way it does. Not for \"should we change it\", which is a judgment, and not for fixing a failure or planning a change."
license: MIT
metadata:
  ak_catalog_id: explain
  ak:
    mode: manual
---

Explain how and why existing behavior works from repository and KB evidence. A description is not
a recommendation or an implementation plan.

## When to use

- A human asks how a part of the project works, or why it works the way it does, and wants the
  answer grounded in the code and the project's records.
- A human is onboarding to an area and needs a description that separates what the evidence shows
  from what is inferred.

## Not for

- "Should we change X?" That is a judgment on adoption, and it belongs to `pov`, which the human
  starts. Explaining a historical choice is not endorsing it today.
- Capturing what was learned as durable project knowledge. That is `compound`, and an explanation
  does not authorize writing to the knowledgebase.
- Generating alternatives or scoping an implementation. That is `ideate`, `super-align` or
  `super-bound`, each started by the human.
- A reported failure to find and fix. That is `diagnose`. A factual account of current behavior
  stays here.
- Re-pitching the agent's own last message in plainer words. That is `wait-what`.

## Authority

Authority: `explicit`. A human starts it with `/explain`. No phase operation exposes it
([`policies/invocation.yaml`](../../references/shared/policies/invocation.yaml) lists it among the user-invoked skills that expose none), so no
controller can start it under a grant. Started any other way, it stops at step 1 and names the
command.

## Inputs

- The subject: a behavior, a file, a symbol or a past decision. Unclear: see step 2.
- The repository at a readable revision. Unreadable: `needs-input`.
- Knowledgebase context through the adapter's `readContext`: decision records, `concept` and
  `system` pages, the glossary. Optional. Unavailable: the explanation says so and rests on the
  repository alone.
- The intended readers, when the request names them. Depth follows the request, never the caller's
  identity alone.

## Workflow

1. **Check how this run was started**, before any other step and before any tool call. It is started
   only when the human's message begins with `/explain`; no grant starts it. A request in prose
   is not a start, even when it names this skill or the command. Otherwise, stop here: make no tool
   call, say that this command is human-started, and give the human the line to type, `/explain`
   and their request.
2. **Resolve the subject.** Resolve discoverable facts before asking. Ask only when the missing
   information changes the answer. With no one to ask, return the unresolved question and what it
   changes, rather than guessing.
3. **Gather evidence.** Read the implementation, not only its call sites. Read the decision records
   for the reasons. Record each source by path and line range, or by record id.
4. **Classify each claim.** Every claim is traced to a source, marked `inference` with what it rests
   on, or marked `unknown`. A function call does not establish guarantees about its uninspected
   implementation. Code shows behavior, not intent. A search that found no reason does not prove
   there was none. An outside concept with no source is labelled unverified.
5. **Write the explanation.** Load [the prose-quality reference pack](../../references/shared/references/prose-quality/REFERENCE.md)
   and write to it. Fit the depth to the readers. When the evidence is wider than the answer,
   say what was selected and what was left out.
6. **Check before delivery.** Check every factual claim against its source. Remove an unsupported
   claim or mark its uncertainty where it appears.
7. **Deliver and stop.** Return the explanation, its sources and the open questions in the session.
   End there: no recommendation, no plan. A follow-up "so what should we do?" is answered by naming
   `pov` as the human's to start.

## Hard gates

Gate: no recommendation and no implementation plan. A description that ends in a verdict or a list
of changes is refused, however the request is worded.

Gate: no claim about code that was not read. Where only a call site is available, the behavior
behind it is `unknown`, and the explanation says so.

Gate: no claim delivered as fact without a source. It is traced, marked `inference`, or marked
`unknown`.

Gate: nothing durable is written. The explanation is delivered in the session; publishing it is a
separate action and not this skill's.

Gate: no invented answer to an open question. With no one to ask, the question and its consequence
are returned.

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "The function is called `retryWithBackoff`, so it retries with backoff." | A name and a call site do not establish what an uninspected implementation guarantees. | Read the implementation, or mark the behavior `unknown`. |
| "They will want to know what to do next, so I'll add a suggestion at the end." | A description is not a recommendation; the suggestion is a judgment nobody asked this skill to make. | End with the evidence and the open questions. Name `pov` if a judgment is wanted. |
| "The commit message gives no reason, so there wasn't one." | Code shows behavior, not intent, and an empty search is not evidence of absence. | Mark the reason `unknown` and say where you looked. |
| "It was chosen deliberately, so it is still the right choice." | Explaining a historical choice is not endorsing it today. | Report the reason as it was recorded, with its date and source. |
| "This explanation is good; I'll save it as a doc for next time." | An explanation does not authorize a durable write, and project knowledge has its own owner. | Deliver it in the session. Name `compound` if it should be kept. |

## Outputs

- The explanation, returned in the session: each claim with its source, its `inference` marker or
  its `unknown` marker, plus the material open questions. It is not published: no knowledgebase
  operation is called (`docs/decisions/0001-kb-document-vocabulary.md` §3 lists no durable output
  for this skill).
- With no one to ask, the unresolved question and what its answer would change.

## Side effects

None. The explanation is returned in the session, and nothing is written to the repository, the
knowledgebase or the run's artifact store.

## Stop conditions

- `complete` — the explanation is delivered, with every claim traced, inferred or unknown.
- `needs-input` — started without an explicit `/explain`; or the repository is unreadable; or an
  open question changes the answer and no one can answer it, returned with its consequence.

## Limits

- Claims without a source, an `inference` marker or an `unknown` marker: 0 (gate).
- Clarifying questions: only those whose answer changes the explanation (guidance).
