---
name: wait-what
description: "Re-pitches the proposal the human lost track of: adds the missing context, uses the project's established vocabulary, and keeps every point that changes what the human would do. Use when the human says they do not follow where the agent has got to. Not for a human who follows the proposal and disagrees with it, and never a route to reopening the decision."
license: MIT
metadata:
  ak_catalog_id: wait-what
  ak:
    mode: autonomous
---

Re-explain the present proposal in established project vocabulary. Does not restart alignment or
change the decision.

## When to use

- The human says they do not follow where the agent has got to: "wait, what?", "I'm lost", "say
  that again plainly".
- A re-pitch did not land and the human asks again. The second pitch goes further back.

## Not for

- A human who understood the proposal and disagrees with it. Disagreement is not a comprehension
  failure, and this skill has no branch that revisits a decision.
- Restarting alignment. Reopening what was decided is `super-align`, which only the human
  starts.
- Explaining how existing code works, with evidence. That is `explain`, which the human starts.
- A request to make a message shorter. Wait is about the human's state, not the message's length.

## Authority

Authority: `model`. The agent starts it when the human's reply shows the last proposal did not
land; no slash command exposes it. No grant covers delegation here, because no phase operation
exposes this skill ([`policies/invocation.yaml`](../../references/shared/policies/invocation.yaml) records model-invoked skills as exposing none).

## Inputs

- What the human lost: by default the present proposal, however far back it started; or a passage
  or step the human names.
- The project's vocabulary: the knowledgebase glossary and its `concept` pages, through the
  adapter's `readContext`, for the terms the proposal uses. Unavailable: use the terms already
  established in the session and the repository, and say the glossary was not read.

## Workflow

1. **Resolve "that".** Decide how far back the human lost the thread. It is usually more than the
   last paragraph. If the human named a passage or a step, take only that. If the target is still
   unclear, ask one short question and stop.
2. **Load the vocabulary.** Look up the proposal's terms in the glossary and `concept` pages. Note
   each term the proposal used that the glossary does not hold.
3. **Find the missing premise.** Name the context the original message assumed and the human did
   not have.
4. **Re-pitch.** State the context first, then the proposal. Use a Simplified Technical English
   register: short sentences, one idea per sentence, active voice. Use the project's own nouns,
   and define once any term the glossary does not hold.
5. **Check against the source.** Every claim in the re-pitch is in the original or its evidence.
   Everything that changes what the human would do is kept, caveats included. If re-reading shows
   the original was wrong, say so and correct it, marked as a correction.
6. **Stop.** The decision stands as it was. No new options, no new alignment question.

## Hard gates

Gate: the decision does not change. A re-pitch that alters, reopens or re-scores the proposal is
refused; if the human wants it reopened, say that `super-align` is theirs to start, and stop.

Gate: no claim beyond the source. The re-pitch adds context from the session, the repository and
the glossary, and nothing the original did not rest on.

Gate: nothing that changes what the human would do is dropped. Shorter and clearer, never blunter.

Gate: a second request on the same proposal gets more context, not fewer words.

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "They asked again, so they want it shorter." | "Wait" reports that comprehension failed. A terser copy of what did not land fails the same way, and each repeat gets blunter. | Go further back and add the premise that is still missing. |
| "If it needs this much explaining, I should offer alternatives." | This skill re-explains a decision; it does not reopen one, and an option list is a new alignment round the human did not start. | Re-pitch the same proposal. Say that `super-align` is the human's to start if they want to revisit it. |
| "A plainer word than the project's term will land better." | An invented noun is a second name for one thing, and the next message will not match it. | Use the glossary term and define it once. |
| "To keep it simple I'll leave out the caveat." | A caveat changes what the human would do; dropping it makes the plain version wrong. | Keep it, in plain words. |

## Outputs

- The re-pitch, returned in the session. It is not project knowledge and is not published: no
  knowledgebase operation is called and no artifact is written
  (`docs/decisions/0001-kb-document-vocabulary.md` §3 lists no durable output for this skill).
- A correction, marked as one, when re-reading showed the original was wrong.

## Side effects

None. The re-pitch is returned in the session, and nothing is written to the repository, the
knowledgebase or the run's artifact store.

## Stop conditions

- `complete` — the re-pitch is returned and the decision is unchanged.
- `needs-input` — the target is unclear after reading the session; one short question is asked.

## Limits

- Clarifying questions before the re-pitch: 1 (gate).
- Sentence length in the re-pitch: short, one idea each (guidance).
