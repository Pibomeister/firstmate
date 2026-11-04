---
name: doc-review
description: Use when a drafted requirements document, implementation plan, decision record or context page needs its decisions checked for coherence and readiness before anyone acts on it. Reviews what the document decides, not how it reads. Not for reviewing code or a diff, not for prose quality, and not for settling what the document should say.
license: MIT
metadata:
  ak_catalog_id: doc-review
  ak:
    mode: manual
---

Review requirements, plans, ADRs or context for coherence and decision readiness. Its persona
catalog differs from code review; meaning-changing forks cannot be silently settled.

## When to use

- A caller has a drafted specification, requirements page or decision record and needs to know
  whether its decisions are executable before work is cut from it.
- A document states two things that cannot both be true, and someone has to find out which parts
  of it a reader would diverge on.
- A later round of an open review run: the document changed and the retained findings need
  re-checking against it.
- A plan needs its approach checked against the codebase it will actually land in.

## Not for

- Reviewing code, a diff or a branch. That is `super-review`, whose persona catalog is a different
  set of seats reading a different kind of evidence.
- Prose quality, voice or house style. That work belongs to
  [the prose-quality reference pack](../../references/shared/references/prose-quality/REFERENCE.md); this skill reads
  for what the document decides, not for how it reads.
- Deciding what the document should say. A document whose direction is unsettled goes back to a
  human-started alignment run, not to a review panel.
- A document that has not been drafted. There is nothing to review, and an outline is not a draft.
- A third fix round on a document whose forks keep bouncing, with no recorded human extension.
  Two rounds is the cap; a cycle past it is a human's call, recorded and reviewed as a delta.

## Authority

Authority: `model`. A parent skill starts it when its description matches the work in hand — in
this catalog that is `super-bound`, before any ticket is cut from the specification. It is not
offered as a slash command and a human does not start it directly. No delegation grant is
involved: this skill opens its own review run and takes no checkpoint on anyone's behalf. The
authority to apply a correction rides on the caller's authorization, recorded on the finding as
`authorization_ref`, never on this skill's own.

## Inputs

- The document under review, with its identity: artifact id and content hash. Absent, or an
  identity that cannot be computed: `needs-input`. A review that cannot name what it reviewed
  cannot be re-checked in a later round.
- Origin: the upstream provenance the document derives from, as an artifact reference or the value
  `none`. Absent is not a stop — `none` is a real value and it changes which persona sections run.
- Prior round state, at a later round: the open `review` run, its findings and their dispositions.
- Recorded context: the settled decision pages and the glossary whose vocabulary the document is
  supposed to be using, read through the knowledgebase adapter's `readContext`.
- Declared risk, where the project declares it. Absent, the conditional lanes are selected from
  artifact evidence alone.

## Workflow

1. Classify the document from its content: requirements, or plan. A page carrying only a product
   contract is requirements and its missing implementation sections are expected; any
   implementation planning makes it a plan. Classify by content, never by filename, readiness
   label or location.
2. Compute the document's identity, record it as the reviewed head, and pin the snapshot. Every
   lane reads that snapshot and nothing else — not the author's narrative, not another lane's
   judgment.
3. At a later round, load the prior round's primer: what was applied, what was rejected, and what
   is provisional pending a re-check. Decisions do not persist across sessions; a fresh review of
   the same document starts at round one with no primer.
4. Compose the panel. Selection is layered: a seat runs when the artifact's own evidence and the
   declared risk earn it, never off a fixed roster (ruling `panel-composition-by-declared-risk`).
   [`doc-review/coherence`](../../references/shared/roles/doc-review/coherence/ROLE.md) and [`doc-review/feasibility`](../../references/shared/roles/doc-review/feasibility/ROLE.md) declare no activation signal and so reach
   every document; [`doc-review/product-lens`](../../references/shared/roles/doc-review/product-lens/ROLE.md), [`doc-review/design-lens`](../../references/shared/roles/doc-review/design-lens/ROLE.md), [`doc-review/security-lens`](../../references/shared/roles/doc-review/security-lens/ROLE.md),
   [`doc-review/scope-guardian`](../../references/shared/roles/doc-review/scope-guardian/ROLE.md) and [`doc-review/adversarial-document`](../../references/shared/roles/doc-review/adversarial-document/ROLE.md) each state their own signal,
   which this skill reads from the seat rather than restating. Uncertainty is not a missing signal:
   where the classification or the artifact's evidence is unclear, [`doc-review/security-lens`](../../references/shared/roles/doc-review/security-lens/ROLE.md) and
   [`doc-review/adversarial-document`](../../references/shared/roles/doc-review/adversarial-document/ROLE.md) run rather than being skipped (ruling
   `low-confidence-security-adjudicated`). Record every lane in the lane table, including the ones
   that did not activate and why.
5. Dispatch each selected lane into its own independent context with the snapshot, its own
   relevant context and the shell rule: deletes and container removals run standalone on literal
   scratch paths, or as `docker run --rm`, never inside a compound command or script. A lane's suppressed sections come from that lane's own rules — a plan with a
   validated origin suppresses different sections in each seat, and they are not flattened into
   one shared rule.
6. Collect results. A lane that returned no finding is `covered` with no finding. A lane that could
   not run, or could not be given its context, is `unavailable` with a reason (ruling
   `required-lane-failure-is-unavailable`).
7. Match each finding against the prior rounds': the fingerprint is the normalized section plus the
   normalized title, and a match additionally needs the evidence substrings to overlap the prior
   finding's by more than half. Suppress a re-raised rejected finding only while the evidence and
   assumptions behind that rejection are still current.
8. Check fix-landed on the same match. A later round quoting the text a prior finding was marked
   fixed against is reported as a fix that did not land, not as a new finding; a later round's
   observation that a fix did land is logged in coverage and not presented.
9. Gate on the confidence anchor before bucketing: anchors 0 and 25 are dropped, anchor 50 is
   observation that never enters the walk-through, and 75 and 100 are actionable. A finding from
   [`doc-review/security-lens`](../../references/shared/roles/doc-review/security-lens/ROLE.md) is never dropped by that gate — it stays visible and is adjudicated
   (ruling `low-confidence-security-adjudicated`).
10. Assign the action class per seat and sort every finding into its bucket. The result takes
    exactly this form, in this order, with every heading present even when its bucket is empty:

    ```text
    Verdict: <approved, changes-requested, blocked or unavailable>
    ## Applied
    <items or None.>
    ## Proposed fixes
    <items or None.>
    ## Decisions
    <items or None.>
    ## FYI
    <items or None.>
    ```

    Applied is what was routed automatic and actually applied; Proposed fixes is the one grouped
    confirmation; Decisions holds the forks the document does not resolve and every blocking
    finding; FYI holds the rest. The verdict line prints the `review` artifact's own verdict;
    `blocked` is a verdict, never a fifth bucket. This step assigns the buckets and fixes the
    form; the form is printed in the final reply after steps 11 and 12, so Applied lists only
    the edits whose read-back succeeded and the verdict line matches the written `review`
    artifact.
11. Apply the Applied bucket to the document, then read each edit back out of the document. An
    edit whose read-back does not show it is recorded as failed, never as applied.
12. Write the `review` artifact and publish the durable disposition record, so a later session can
    see what was settled here even though this session's primer is gone.

## Hard gates

Gate: a correction that changes what the document *decides*, rather than how it says it, is never
applied on one lane's say-so. It needs a second lane that found the same thing independently, or
it is a Decision and goes to the human as one question.

Gate: `safe_auto` is emitted by [`doc-review/coherence`](../../references/shared/roles/doc-review/coherence/ROLE.md) only, for its own closed pattern list, and
only where `spec_quality: patch`, `difficulty: mechanical` and a `suggested_fix` all hold. A
`safe_auto` arriving from any other lane is remapped to `gated_auto`; it is never dropped (ruling
`safe-auto-restricted-per-seat`).

Gate: a required lane that is `unavailable` blocks the approval verdict. It is never downgraded to
an empty result and never backfilled by another seat or by the synthesis step (ruling
`required-lane-failure-is-unavailable`).

Gate: a previously rejected finding is re-raised only on changed evidence. An unchanged document
quote does not establish unchanged evidence, and neither does a differently worded restatement of
the same concern.

Gate: at most two fix rounds. The third request stops with the open forks attached
([`schemas/review.schema.json`](../../references/shared/schemas/review.schema.json), `fix_cycles`). A cycle a human authorizes after the cap is recorded
in `fix_cycles.extensions` (`authorized_by: human`, operator-attested, and when) and reviewed as a
`delta`; without that entry it is refused.

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "Both sides of the contradiction are in the document, and one is obviously right — I'll apply it." | Choosing which side wins changes what the document decides. Obvious to a reviewer is not decided by the people who own the document. | Raise it as a Decision with one question naming both sides. |
| "One lane timed out and the other five agree, so the review is effectively complete." | A lane that did not run produced no evidence, and five agreements about other things are not that lane's result. | Record it `unavailable` with the reason and let it block the approval verdict. |
| "We rejected this in round one and the document still says the same thing, so I'll suppress it again." | Suppression rides on the rejection's evidence still being current, not on the document being unchanged. The constraints or the facts may have moved under it. | Check what the rejection rested on. If any of it moved, re-raise the finding. |
| "This is a clean one-line patch with an obvious fix, so I'll mark it automatic from the feasibility lane." | The restriction is on emission by a seat, not on how tidy the fix looks. Only [`doc-review/coherence`](../../references/shared/roles/doc-review/coherence/ROLE.md)'s own closed pattern list qualifies. | Emit it `gated_auto` and let it go through the grouped confirmation. |
| "Round two did not settle the fork, but it is close — one more round will finish it." | A fork that survived two rounds is not converging; it is a decision nobody in the run has the authority to make. | Stop at two and return the open fork, unless a recorded human extension authorizes a delta. |

## Outputs

- `review` ([`schemas/review.schema.json`](../../references/shared/schemas/review.schema.json)) — the run artifact: mode `full` at round one and `delta`
  at a later round, the snapshot hash, the reviewed head, the full lane table with a reason on
  every skipped and unavailable lane, the verdict, and `fix_cycles`. Published through the
  knowledgebase adapter's `publishArtifact` under a run-artifact placement; no repository path is
  written (ruling `central-kb-owns-project-artifacts`).
- `finding` ([`schemas/finding.schema.json`](../../references/shared/schemas/finding.schema.json)) — one per retained observation, each carrying its lane,
  its fingerprint, severity, `confidence_anchor`, `spec_quality`, `difficulty`, `autofix_class`,
  evidence and verification.
- The fixed presented form, printed in the final reply after the edits are read back and the
  `review` artifact is written: one `Verdict:` line matching the written artifact's verdict, then
  `## Applied`, `## Proposed fixes`, `## Decisions` and `## FYI`, in that order and each present
  even when empty. Applied lists only edits whose read-back succeeded, annotated as settled in
  this session; Proposed fixes is one grouped confirmation; Decisions asks one question per fork
  and contains every blocking finding; FYI asks nothing of anyone.
- Durable disposition record — what was rejected here and on what evidence, published so a later
  session can see it. This skill authors no knowledgebase document of its own kind; it reviews the
  documents other skills author (`docs/decisions/0001-kb-document-vocabulary.md`).
- Edits to the document under review, for the Applied bucket and nothing else.

## Side effects

`artifact-write`, `scratch-write`, `kb-draft`, `kb-publish`. No `workspace-write`: this skill edits
the document under review and never the source the document describes.

`kb-publish` is a remote effect. Its idempotency key derives from the run, the operation, the
record's stable identity and the artifact's hash, and the read-back is the record the write
returns, read before the write and confirmed after it ([`adapters/runner-contract/CONTRACT.md`](../../references/shared/adapters/runner-contract/CONTRACT.md),
"Idempotency"). A publish whose read-back cannot be performed is recorded as failed.

## Stop conditions

- `complete` — every selected lane is accounted for in the lane table, every retained finding has a
  stated consequence for the work, and every authorized Apply was made and read back. A verdict of
  `blocked` is a completed review with a blocking result, not an incomplete one.
- `needs-input` — there is no document, its identity cannot be computed, or a later round was
  started without the prior round's findings.
- `cap-reached` — two fix rounds are used, a Decision is still open, and no recorded human
  extension authorizes another. Returns the open forks and the review as it stands.
- `cancelled` — the caller ended the run before the panel returned.
- `failed` — the knowledgebase is unreachable, or a publication's read-back cannot be performed.

## Limits

- Fix rounds: 2 (gate). [`schemas/review.schema.json`](../../references/shared/schemas/review.schema.json) `fix_cycles`. `allowed` admits no value above
  two, so no configuration raises the cap; a third cycle runs only on a recorded human extension
  in `fix_cycles.extensions`, reviewed as a `delta`.
- Confidence anchors: 0 and 25 are dropped before any bucket, 50 never enters the walk-through,
  and the security exception above overrides both.
- Evidence overlap for a fingerprint match: more than half. The figure calibrates a matching
  heuristic and decides nothing on its own; a match still has to survive the changed-evidence test.
- Panel size: no number. The panel is what the declared risk and the artifact's own evidence earn
  (ruling `panel-composition-by-declared-risk`); a substantive document reaches most of the seat
  catalog and a small correction does not.
- Session scope: the primer is intra-session. A later review of the same document starts at round
  one and reads the durable disposition record instead.
- Seat capability and cost (guidance): [`doc-review/coherence`](../../references/shared/roles/doc-review/coherence/ROLE.md), [`doc-review/feasibility`](../../references/shared/roles/doc-review/feasibility/ROLE.md),
  [`doc-review/product-lens`](../../references/shared/roles/doc-review/product-lens/ROLE.md), [`doc-review/design-lens`](../../references/shared/roles/doc-review/design-lens/ROLE.md) and [`doc-review/scope-guardian`](../../references/shared/roles/doc-review/scope-guardian/ROLE.md) read a pinned
  snapshot against recorded context, so the lane does not by itself call for the strongest
  reasoning available; a document that turns on complex judgment may still need it. Whoever binds a
  seat decides, an explicit choice by the human or the runner stands, and this skill never changes
  a seat on its own. Lane independence, the unavailable-lane rule, [`doc-review/security-lens`](../../references/shared/roles/doc-review/security-lens/ROLE.md) and
  [`doc-review/adversarial-document`](../../references/shared/roles/doc-review/adversarial-document/ROLE.md) are untouched. Do not claim a saving without measurement.
