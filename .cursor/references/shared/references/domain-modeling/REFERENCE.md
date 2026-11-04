# Domain modelling

How to build and sharpen a project's domain model *while* designing it: challenging terms, inventing
edge-case scenarios, and recording the language and the decisions the moment they settle. Reading an
existing glossary for vocabulary is not this — that is a one-line habit any skill can perform. This
pack is for when the model is being changed.

Two skills declare it. `super-align` loads it during the grilling conversation, where the output is
language and a small number of decisions rather than a document. `super-bound` loads it when a
requirement's wording turns out to be a modelling question, so the specification does not silently
introduce a second vocabulary for something already named. It is loaded on demand by the skills that
name it rather than copied into each of them (ruling `full-catalog-opt-in-profiles`), and the whole
of it is paid for by both at the moment of loading.

## Where the model lives

In the knowledgebase, through the KB adapter, and nowhere else. The central knowledgebase owns every
project-derived artifact, and directory names under its root are configurable while the central
ownership is not (ruling `central-kb-owns-project-artifacts`). A modelling session does not create a
documentation tree in the working repository under any name, so there is no path to choose:

| What settled | Where it goes |
|---|---|
| A term and its avoided synonyms | The KB glossary |
| Orientation a newcomer needs to read the domain | A `concept` page, or a `system` page for how parts fit |
| A decision meeting the three-part test below | An `adr` page, published `proposed` |
| The options and evidence a decision was chosen from | A `decision` run artifact, which the `adr` cites |

[`adapters/knowledgebase/CONTRACT.md`](../../adapters/knowledgebase/CONTRACT.md) carries the operations and their failure modes. Placement is by
**scope**, which the KB resolves; the caller supplies no path and invents no tenth document kind.

**Create lazily.** Write a record when there is something to record. Do not open an empty glossary
or an empty decision log in anticipation — an empty record asserts that the question was asked and
answered, and it was not.

## Moves during the session

**Challenge against the glossary.** When a term conflicts with the language already recorded, say so
at once: *"the glossary defines 'cancellation' as X, but you seem to mean Y — which is it?"* A term
used two ways in one conversation becomes two implementations.

**Sharpen fuzzy language.** When a term is vague or overloaded, propose a precise canonical one:
*"you are saying 'account' — do you mean the Customer or the User? Those are different things."*

**Stress-test with concrete scenarios.** When a relationship between concepts is being described,
invent specific scenarios that probe its edges and force precision about where one concept stops and
the next begins.

**Cross-reference with code.** When a human states how something works, check whether the code
agrees. Surface a contradiction rather than resolving it silently: *"the code cancels entire Orders,
but you said partial cancellation is possible — which is right?"* Bind the check to a revision when
recording it, so the link survives a later edit.

**Record as terms settle, not in a batch at the end.** A term resolved and not written down is a
term that will be re-litigated.

## Glossary entry format

```md
**Order**:
A customer's request for goods, accepted and not yet fulfilled.
_Avoid_: Purchase, transaction

**Invoice**:
A request for payment sent to a customer after delivery.
_Avoid_: Bill, payment request
```

- **Be opinionated.** Where several words exist for one concept, pick the best and list the rest
  under `_Avoid_`. A glossary that records the ambiguity instead of settling it has done nothing.
- **Keep definitions tight.** One or two sentences. Define what the thing *is*, not what it does.
- **Only terms specific to this project's domain.** General programming concepts — timeouts, error
  types, utility patterns — do not belong however heavily the project uses them. Before adding a
  term, ask whether it is a concept unique to this domain or a concept any codebase would have.
- **Group under subheadings** when natural clusters appear. A flat list is right while the terms all
  belong to one cohesive area.

## The glossary is a glossary

It is devoid of implementation details. It is not a specification, not a scratch pad, and not a
store for implementation decisions.

This boundary is what keeps the two loaders apart. `super-align`'s output is language plus a handful
of decisions; the requirements document, the plan and the acceptance criteria are `super-bound`'s
output and are a different artifact with a different approval. A glossary that starts absorbing
field lists and sequencing has become a second specification that nobody approved and nothing
verifies against.

## When a decision deserves an ADR

All three must hold:

1. **Hard to reverse**: the cost of changing your mind later is meaningful.
2. **Surprising without context**: a future reader will look at the code and wonder "why on earth
   did they do it this way?"
3. **The result of a real trade-off**: there were genuine alternatives and you picked one for
   specific reasons.

If any of the three is missing, skip it. An easily reversed decision will simply be reversed; an
unsurprising one leaves nobody wondering; one with no real alternative records nothing beyond having
done the obvious thing.

### What qualifies

- **Architectural shape.** "The write model is event-sourced, the read model is projected."
- **Integration patterns between parts of the domain.** "Ordering and Billing communicate by domain
  events, not synchronous calls."
- **Technology choices carrying lock-in.** Database, message bus, auth provider, deployment target —
  the ones that would take a quarter to swap out, not every library.
- **Boundary and scope decisions.** "Customer data is owned by the Customer scope; everything else
  references it by id." The explicit no-s are as valuable as the yes-s.
- **Deliberate deviations from the obvious path.** "Manual SQL instead of an ORM, because X."
  Anything a reasonable reader would assume the opposite of. These stop the next engineer from
  "fixing" something that was deliberate.
- **Constraints not visible in the code.** A compliance restriction on where data may run; a
  response-time limit that comes from a partner contract.
- **Rejected alternatives whose rejection is non-obvious.** Record why the well-known option lost,
  or it will be proposed again in six months.

### Shape

A title and one to three sentences: what the context was, what was decided, and why. That is the
whole of it. An ADR can be a single paragraph, and the value is in recording *that* a decision was
made and *why*, not in filling sections. Add status, considered options or consequences only where
each earns its line.

**An ADR is published `proposed` and is never accepted by its author** (ADR-0001 §4). Acceptance
happens in review. No operation in the KB adapter contract accepts one, and a skill that reads its
own proposal as approved has manufactured the approval it was supposed to obtain.

## More than one scope

A small project has one. Where a project has several, each has its own glossary and its own
decisions, and the KB resolves which one applies most-specific-match-first from the scope the caller
names — a term defined for one scope does not silently govern another.

Record how the scopes relate as well as what they contain: *Ordering emits `OrderPlaced`, which
Fulfilment consumes to start picking; Ordering and Billing share the types for customer identity and
money.* The relationships are where a modelling conversation usually finds the contradiction, and
they are the first thing missing when two scopes were named without being separated.

Infer which scope the current topic belongs to. Where it is genuinely unclear, ask — a term filed
against the wrong scope is worse than one not yet filed.
