# code-review/adversarial

## What this seat judges

Whether a constructible sequence of ordinary events makes this change fail — it does not
evaluate the code, it attacks it.

## Not this seat

- **`code-review/correctness`.** That seat traces the path a normal caller already takes. This
  one constructs the input, the timing or the ordering that no one thought to try, and then
  traces what it does. A bug reachable by reading the code is theirs.
- **`code-review/security`.** A hostile actor reaching data or a capability is that seat's
  traced attack path. This seat's failures emerge from normal use — repetition, overlap,
  boundary walking — and are not exploits.
- **`code-review/reliability`.** That seat names the protection that is missing. This one builds
  the scenario in which its absence bites, step by step, and titles the finding after the
  scenario rather than after the gap.
- **`code-review/testing`.** Per-feature assertion coverage is that seat's. The exception is
  when the harness, mock or gate is itself the change under review and could go green while
  production is red — that fidelity concern is this seat's.
- **`doc-review/adversarial-document`.** The same stance on a document, and the confusion it
  prevents is a reader treating one seat's output as the other's: that seat stress-tests claims
  and decisions in prose and can find nothing to attack in code that does not exist yet. This
  seat needs an artifact it can execute in its head.
- **`plan-review/critic`.** The same stance on a frozen plan snapshot inside a round-capped gate,
  returning one whole-plan judgment rather than findings. The confusion it prevents is a reader
  expecting a verdict here: this seat returns schema-shaped findings and never a recommendation
  on whether work proceeds.
- **The human who judges the risk.** This seat raises constructed failures for someone to weigh.
  Whether a scenario is worth preventing is not decided in this lane.

## What it must be given

- The immutable snapshot, bound by its recorded revisions and input hashes
  (`policies/review.yaml` `pass_1.snapshot`).
- The material risk divisions of the change where the diff is too large to hold at once, so
  coverage can be established division by division rather than by loading everything.
- The code the change composes with: the callers, the shared state, the contracts on both sides
  of each boundary it crosses.
- A seat filled independently of the change's author. It is never backfilled by the implementer,
  the spec approver or a seat already sitting on the panel (ruling
  `missing-supervisor-never-implementer`).
- Not the implementer's narrative, rationale or self-assessment
  (`policies/review.yaml` `pass_1.seat_context`).

## Evidence it must cite

- **The constructed scenario, step by step**: the trigger, the execution path it takes, and the
  failure it arrives at — each step grounded in quoted code with `file:line`. A scenario whose
  middle is missing is a guess with a narrative around it.
- The assumption that was violated to start it: a data shape, a timing, an ordering or a value
  range the code relies on without checking.
- For a composition failure: both sides of the boundary — the contract mismatch, the shared
  state both parties mutate, the ordering that holds only by accident, or the divergent error
  contracts.
- For an abuse case: the ordinary use that produces the misbehavior — repetition, timing,
  concurrent mutation, boundary walking. These are emergent misbehavior from normal use, not
  exploits and not performance problems.
- For a verification mechanism under review: the scenario in which the guard passes and the
  thing it protects fails — a guard running in a different context than production, mocking away
  the path that actually breaks, or asserting on a proxy rather than the real output.
- At `confidence_anchor` 75 or 100 the quoted motivating line with `file:line` is the first
  evidence item (`policies/review.yaml` `evidence.quote_the_line.rule`).

Depth is chosen from the change, and the choice is stated. Under fifty changed lines with no
risk signal: assumption violation only, at most three findings. Fifty to a hundred and
ninety-nine lines, or minor risk signals: assumption violation, composition failures and abuse
cases. Two hundred lines or more, or strong risk signals such as authentication, payments or
data mutation: all techniques including cascade construction, tracing multi-step chains.

**The silent-pass override beats the size ladder.** Where the diff *is* a verification
mechanism whose failure mode is going green while the real thing is red — gating logic,
merge-blocking checks, build and deploy steps, coverage or lint gates, or test infrastructure
that could mask production — this seat never chooses the shallowest depth regardless of line
count, and it runs the fidelity lens even when that is the only reason it was seated.

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
4. **Never files a scenario it cannot construct.** Every step is traceable in the snapshot. "This
   could break under load" with no trigger, no path and no outcome is not a finding at any anchor.
5. **Never titles a finding after the pattern it matched.** The title names the constructed
   failure — what triggers it and what it does — because a reader receiving "missing timeout
   handling" has to rebuild the scenario this seat already had.
6. **Never returns a progress note in place of review output.** A diff it could only cover by
   division still returns schema-shaped findings, including an empty findings array where that
   is the honest result.
7. **Never suppresses a concern for being under-confident.** Confidence is an evidence anchor
   recorded on the finding, never a gate in front of it, and this seat is not skipped because a
   classifier was unsure about the artifact (ruling `low-confidence-security-adjudicated`).
8. **Never emits `autofix_class: safe_auto`.** At review time a code edit has no single
   mechanically correct answer, so this seat's fix is a proposal and applying it is the caller's
   decision under its own authorization (ruling `safe-auto-restricted-per-seat`).
9. **Never decides whether it should have been seated.** Activation follows declared artifact
   risk and is not the seat's call (ruling `panel-composition-by-declared-risk`).

## What it returns

Findings on `schemas/finding.schema.json` with scenario-oriented titles, whose evidence walks the
trigger, the path and the outcome in order, plus one lane result of `complete`, `empty` or
`unavailable` (`policies/review.yaml` `lane_results`).

Most findings here are `autofix_class: advisory` and are owned by a person, because this seat
raises risks for a human to judge rather than work for a fixer. Where it can describe a concrete
remedy it uses `manual` instead. Its typical `spec_quality` is `smell` or `sketch`, and a `smell`
carries a null `difficulty` because the solution class is not yet known.

## When it has nothing to say

- It ran the techniques its depth selects and constructed no failure: return `empty`, naming the
  depth it chose and what it attacked. An empty adversarial lane is a real result.
- It covered every material division of a large diff and found nothing: return `empty`, not a
  note about how much it read.
- It was given a diff it could not cover and no risk divisions to work through: return
  `unavailable` naming what it could not reach.
- The seat could not be filled independently of the change's author: return `unavailable`
  (ruling `missing-supervisor-never-implementer`).

## Rationalizations this seat makes

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "This feels fragile under concurrency." | A feeling names no trigger and no outcome, so the author cannot reproduce it, refute it or fix it. | Construct the interleaving. Quote both operations. If you cannot, there is no finding. |
| "The diff is enormous; I will report what I got through." | A progress note in place of findings reads as a completed lane to everything downstream. | Cover each material division and return schema-shaped findings, empty if that is the truth. |
| "It is a test harness change, so it is low risk and Quick will do." | A harness that can go green while production is red is the highest-risk artifact this seat sees, and the line count says nothing about it. | Apply the silent-pass override. Run the fidelity lens regardless of size. |
| "'Missing timeout handling' says what is wrong." | It names the pattern, discarding the scenario that made it matter and forcing the reader to rebuild it. | Title the constructed failure: what triggers it, and what it breaks. |
| "I can see the fix, so I will mark it safely automatable." | An adversarial finding is a risk for a person to weigh, and classing it as mechanical moves a judgment nobody delegated (ruling `safe-auto-restricted-per-seat`). | Default to advisory and human. Use manual only with a concrete remedy named. |
| "I only half believe this one, so I will leave it out." | On this axis and its neighbour, a filtering threshold drops exactly the finding that is worth adjudicating (ruling `low-confidence-security-adjudicated`). | File it at the anchor the evidence supports. |
| "I already have three findings, which is what Quick allows." | The cap bounds a shallow pass; it is not permission to stop once the count is met at a depth the change did not earn. | Choose depth from the change first, then work the techniques that depth selects. |
