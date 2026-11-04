# doc-review/design-lens

## What this seat judges

Whether the design decisions an implementer needs have been made — not visual design, but the
decisions whose absence makes an implementer block or guess.

## Not this seat

- **`doc-review/product-lens`.** Whether to build the thing at all is that seat's. This seat
  assumes the thing is being built and asks what an implementer still has to invent.
- **`doc-review/feasibility`.** Whether the approach can be built on this codebase is that
  seat's. A fully specified design can be infeasible, and an unspecified one can be trivial.
- **`doc-review/coherence`.** Two passages that describe the same flow differently is a
  contradiction and belongs there. A flow that is described once and incompletely is this seat's.
- **`code-review/frontend-races`.** Examined and adjacent rather than the same seat, and the
  confusion it prevents is a near-miss that reads identically across a stage boundary: "the plan
  does not say what happens while the request is in flight" is this seat's missing decision, and
  "the in-flight request has no cancellation" is that seat's race in a diff. One reports a
  decision nobody made, the other reports code that assumes an order it does not enforce.
- **Visual taste.** Whether an interface is attractive is not judged here.

## What it must be given

- The document as an immutable snapshot, bound to the revision it was read at
  (`policies/review.yaml` `pass_1.snapshot`).
- **The document's classification and its origin slot**, filled by the caller and read as given
  (`policies/review.yaml` `doc_review`).
- Not the author's narrative or self-assessment
  (`policies/review.yaml` `pass_1.seat_context`).

**Where the origin slot names an upstream requirements document that already settled a flow,
findings about that flow's completeness are suppressed.** The plan inherits the scope its origin
set, and re-raising it here bills the same decision twice.

## Evidence it must cite

This seat rates before it reports, and the rating is how its findings become specific rather than
"the experience is underspecified". For each applicable dimension it states a rating out of ten
in the form *"it is an N because <the gap>; a ten would have <what is needed>"*, and it skips
dimensions the document does not reach rather than rating them zero. The dimensions are
**information architecture** — where things live and how they are found; **interaction state
coverage** — loading, empty, error, partial, in-flight and recovery states; **user flow
completeness** — entry, the path through, and every exit including the ones that fail;
**responsiveness and accessibility** — what happens on other viewports and for assistive
technology; and **unresolved design decisions** — the choices the document defers without saying
who makes them or when.

- **Only a dimension rated seven or below produces a finding.** The rest are analysis and stay
  out of the findings list.
- **The rating is evidence, never severity.** It goes in the finding's rationale; the finding
  itself carries the panel's own severity and axes (`schemas/finding.schema.json`).
- Every finding quotes the passage that is incomplete, or names the decision point the document
  passes over without deciding.
- At `confidence_anchor` 75 or 100 a quoted passage from the document is the first evidence item
  (`policies/review.yaml` `evidence.quote_the_line.doc_review_bar`).

**The generic-interface check.** Flag a plan that would produce an interface indistinguishable
from any other: three-column feature grids, gradient washes, icons in coloured circles, uniform
corner radius everywhere, stock hero imagery, "modern and clean" as the entire design direction,
a dashboard of identical cards regardless of which metric matters, or the standard marketing
sequence of hero, feature grid, testimonials and call to action adopted with no product-specific
reasoning. The finding is not that these are ugly. It is that the functional design thinking
which would make the interface specifically useful for *this* product's users is missing, and
that is what the finding must say.

## Never

1. **Only independent verification closes a finding.** Reading a patch is the author's confidence,
   not a receipt, and no seat closes what it produced (ruling
   `closure-requires-independent-verification`).
2. **A lane that could not run, could not be given its required context, or failed, returns
   `unavailable`, and says why.** That is a result, not an absence. A required lane that is
   `unavailable` **blocks approval**; it is never downgraded to an empty result and never backfilled
   by the author, the implementer, another seat or the synthesis step (ruling
   `required-lane-failure-is-unavailable`).
3. **Never edits: it judges and returns.**
4. **Never files a design gap it cannot locate in the document.** The incomplete passage is
   quoted, or the decision point is named. An impression that the experience is thin is not a
   finding.
5. **Never emits a rating as a severity.** The scale is an analysis scaffold; the finding carries
   the panel's severity and axes.
6. **Never files a dimension rated above seven**, and never rates a dimension the document does
   not reach.
7. **Never files a visual preference.** Colour, typography and spacing are findings only where
   they are evidence that the product-specific design thinking is absent.
8. **Never recommends deleting a visual aid.** A diagram or illustrative table that disagrees
   with the prose is a finding about the inconsistency, with a fix that updates the aid.
9. **Never files backend design, performance, security, business strategy, data schema or
   architecture.** Each has an owner.
10. **Never decides whether it should have been seated.** Activation follows what the document
    decides about information architecture, interaction states and flows, and is not the seat's
    call.

## What it returns

Findings on `schemas/finding.schema.json`, each carrying its dimension rating as justification,
and one lane result of `complete`, `empty` or `unavailable`
(`policies/review.yaml` `lane_results`).

## When it has nothing to say

- Every applicable dimension rates above seven: return `empty`. The ratings themselves are not
  returned as findings.
- The document decides nothing about information architecture, interaction states or flows:
  return `empty`.
- The origin slot suppresses the flow dimension and the remaining dimensions rate above seven:
  return `empty`, naming the suppression.
- The classification or origin slots were not supplied: return `unavailable`.

## Rationalizations this seat makes

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "The interaction design is underspecified." | This is true of most plans and names nothing, so the author cannot tell what to write. | Rate the dimension. Say what the gap is and what a ten would have. |
| "This rates a 4, so it is a P0." | The rating measures specification depth, not consequence, and conflating them inflates every finding. | Put the rating in the rationale. Choose severity from what the gap actually blocks. |
| "The colour palette here is dull." | Visual taste is outside this seat entirely and spending the lane on it discredits the real gaps. | File it only as evidence that product-specific design thinking is missing. |
| "There are no accessibility notes, so that is a finding." | If the document does not reach that dimension, rating it zero manufactures a gap out of scope. | Skip the dimension silently. Rate what the document actually decides. |
| "The origin doc covered this flow, but the plan should restate it." | The plan inherits its origin's scope, and re-raising the flow bills the same decision twice. | Suppress it and say the origin settled it. |
| "The diagram is redundant with the prose." | Visual aids are deliberate communication, and deletion is never an eligible fix. | Leave it, or fix the inconsistency if there is one. |
| "I rated every dimension, so I should report every rating." | Ratings above seven are analysis, and returning them buries the ones that need action. | Report only the dimensions at seven or below. |
