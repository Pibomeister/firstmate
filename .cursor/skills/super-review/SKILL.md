---
name: super-review
description: Convenes an independent specialist panel for a first pass, a bounded second look at an accepted fix, or the readiness gate. The agent doing the work starts the first pass or the readiness gate when a change needs judgment against requirements, the project's declared standards and its tests. No slash command and no human act is required. Reviewers cannot edit source, and the author of the change does not sit a seat or close a finding. Not for writing the fix, not for running acceptance checks, and not for repairing a red pipeline.
license: MIT
metadata:
  ak_catalog_id: super-review
  ak:
    mode: manual
    autonomy_unenforceable:
      - suppression of model invocation. This package does not request it (docs/decisions/0003-model-invocation.md). An agent starts full and readiness (ADR-0013).
      - seat isolation is not attested by the host. This package assembles one evidence packet per seat and records what it withheld; it cannot prove the host kept two contexts apart.
      - grant validation is the runner's. A controller that cannot validate a grant for the delegated operation stops. An agent start of the model entrypoint does not need that grant (ADR-0013).
      - "artifact-write is storage only: the host does not compute or check the artifact hash, so binding a finding to the snapshot hash is this package's own work."
---

## When to use

Use `full` when a change is ready for judgment and nothing has reviewed it yet: a panel of seats
reads one immutable snapshot against requirements, the project's declared standards, and the tests.
The agent that produced the change starts this itself, as part of the work.

Use `delta` when a finding was accepted, a fix landed, and the fix needs a bounded second look inside
the review run that is already open. After the first `full`, every later review of the change is a
`delta` over the commits since the last reviewed head, past the fix-cycle cap included.

Use `readiness` when a change is otherwise ready to ship and the question is whether the evidence
behind it holds up — not what is wrong with the diff, but whether anything required is missing.

Use it when a caller asks whether a change is safe to merge and the honest answer depends on evidence
a reviewer has not yet read.

## Not for

Not for producing the fix. Reviewers do not edit the source they review ([`policies/review.yaml`](../../references/shared/policies/review.yaml));
accepted findings leave this skill and enter the apply-findings protocol, which is where an
implementer with write authority acts on them.

Not for establishing that the code works. A review reads a change; it does not run the project's
acceptance checks and does not produce receipts. Closure needs independent verification evidence
plus a policy rule saying that evidence suffices for that finding, and reviewer confidence stays
advisory (ruling `closure-requires-independent-verification`).

Not for repairing a red pipeline. A failing required check is CI repair's bounded operation, whose
rule restricts the purpose and scope of the repair and never the standard the change has to meet
(ruling `ci-repair-restricts-purpose-not-permission`). A product-code change discovered there
re-enters diagnosis, a bounded patch, new verification and affected delta review — this skill's
`delta` mode over the affected behavior, never a second full panel.

Not for failing a change on its size or its test-ratio shape. A roughly-hundred-line target and a
test pyramid are configurable starting points carried in [`engineering-principles`](../../references/shared/references/engineering-principles/REFERENCE.md), not
grounds for a finding on their own (ruling `numeric-heuristics-are-guidance`).

Not for reviewing a requirements document, a plan or an ADR. Those have their own persona catalog and
their own failure modes, and they enter through `doc-review`.

## Authority

`full` and `readiness`: authority `model`, invocation M. The agent doing the work starts either
when a change needs that judgment. No slash command and no human act is required (ADR-0013). A
delegated controller may also start the same protocol through `review.full` and `review.readiness`
under a runner-validated grant covering finding-adjudication. A bypass grant (ADR-0008) remains a
valid start and is not required. `delta`: authority `active-review-run`, invocation M, through
`review.delta`.

Starting the review is not approval. The author of the change does not sit a seat and does not
supply the verdict (ruling `missing-supervisor-never-implementer`). The author does not close a
finding (ruling `closure-requires-independent-verification`).

There is one protocol. Where the host cannot validate a grant, a controller stops rather than
inventing a second pipeline (ruling `entrypoint-phase-operation-split`). An agent start does not
need that grant.

Under a Firstmate binding, cite `ak firstmate grant --binding <path> --operation review.full` (or
`review.readiness`) when it exits 0. A refusal means the binding does not cover the delegated
operation. It does not stop the model start.

Under a bypass grant, `node <this skill's directory>/../../bin/ak-gate.mjs bypass check --grant
<path> --task <id> --phase super-review:full` (or `super-review:readiness`) exits 0 as one valid
start. Record the gate with `--bypass <path> --task <id>` so it carries the attribution. Under the unattended policy (ADR-0014), record each review gate with its evidence command after `--`, as [the unattended-lifecycle reference](../../references/shared/references/unattended-lifecycle/REFERENCE.md) says; a blocking finding still stops.

`review.delta` does not open a review run. Invoked where none is open, it stops with `needs-input`
naming `super-review full` as the next permitted action.

## Inputs

The comparison base and the reviewed head, both named. Absent, stop with `needs-input`: a review with
no comparison base is an opinion about a file tree.

The requirements the change claims to satisfy, by id, for the spec axis. Where none can be resolved,
the spec lane returns `unavailable` rather than inventing an intent to review against.

The project's declared standards, discovered from the project's own record. Where a project declares
none, the standards seat returns an empty result; absent standards never become invented preferences
([`policies/review.yaml`](../../references/shared/policies/review.yaml)).

The test evidence that exists for the change, and the packs the change earned. Packs are the artifact
evidence that selects conditional seats; they are read, never guessed at from file names alone.

For `delta` only: the open review run, its persisted finding list with fingerprints and dispositions,
its input hashes, and the fix diff ([`schemas/review.schema.json`](../../references/shared/schemas/review.schema.json) `packet`).

## Workflow

1. Name the comparison base and the reviewed head before any other work. Absent either, stop with
   `needs-input` and do not convene a panel. For `delta`, confirm a review run is open; if not, stop
   with `needs-input` naming `full` as the next action. Do not stop because a person did not type a
   command, and do not send the caller away to type one.
2. Build the snapshot and freeze it: its hash, the comparison base, the reviewed head, the source
   revision and the input hashes. Every seat reads this one object and no seat may edit it.
3. Select the panel from declared risk rather than from a fixed roster. Correctness is the only
   unconditional seat; the standards gate runs when the project declares standards or when discovery
   was uncertain; testing, maintainability, agent-native and learnings fire when the diff earns them;
   security, adversarial and the remaining conditional and stack seats are selected from artifact
   evidence, in practice from the attached packs. A substantive feature lands at the six-ish panel;
   a documentation typo does not; and security, API and data facts are never dropped because a
   classifier was uncertain (ruling `panel-composition-by-declared-risk`). A change within the
   project's size guidance seats the lean panel. The catalog of seats, their selection signals and
   the lean panel are in `./references/panel.md`.
4. Assemble one context packet per seat: the frozen snapshot plus that seat's own requirements,
   standards and test context. No packet carries the implementer's narrative, rationale or
   self-assessment, another reviewer's findings or dispositions, or any approval context produced by
   the author lane. Every packet carries the shell rule in `./references/panel.md`. Two seats
   sharing a scratchpad are one seat.
5. Check the exclusions before dispatch. A seat that cannot be filled independently of the author is
   `unavailable`, and the security seat is filled by neither the implementer of the change nor
   whoever approved its spec (ruling `missing-supervisor-never-implementer`).
6. Dispatch the selected seats concurrently within the turn, each in its own isolated review context.
   Every finding quotes the line it is about.
7. Record each lane's state as `covered`, `skipped` or `unavailable` ([`schemas/review.schema.json`](../../references/shared/schemas/review.schema.json));
   the mapping from a seat's own result is in `./references/panel.md`. A lane that could not run,
   could not be given its required context, or failed, is `unavailable` with the reason named — a
   result, not an absence (ruling `required-lane-failure-is-unavailable`). Store each covered seat's
   output exactly as it returned, as a run artifact referenced by hash, before synthesis reads it.
8. Synthesize without merging: deduplicate by fingerprint, keep each seat's evidence attached to its
   finding, and never rewrite a severity to reconcile two seats. Suppression is by the catalogued
   reasons only, and a suppressed finding stays readable with its reason.
9. For `delta`: first test whether architecture, requirements, the comparison base or the affected
   surface changed materially. Where any did, invalidate the affected approvals and establish a new
   baseline — a new scope with its own pass 1 — instead of continuing this loop (ruling
   `delta-baseline-reset-not-third-loop`). Fix commits, a reached cap, a replan and a rebase that
   leaves the patch unchanged are not material. Otherwise build the packet, run the spec and standards
   lanes over the fix, and bound the scope by affected behavior rather than by changed lines (ruling
   `delta-scope-affected-behavior`). A
   continuing seat keeps its earlier finding context, or a replacement receives the durable
   prior-finding packet; independence from the author is mandatory and amnesia is not (ruling
   `reviewer-continuity-not-amnesia`). The mechanics are in `./references/delta.md`.
10. For `readiness`: run the two independent lanes as a gate over the panel's synthesized verdict,
    not as a substitute for it. A missing lane is `unavailable`, and a blocking lane result vetoes
    approval no matter what the panel concluded. Load
    [verification evidence](../../references/shared/references/verification-evidence/REFERENCE.md), then, where the build
    gate records an implementer seat, require each criterion's current receipt to name a
    runner-attested verifier seat distinct from it (without that record, only recipe-bound checks
    need one, and a `host-unattested` seat counts, disclosed as worker-attested, only in a run that never held a grant; under the unattended policy (ADR-0014) a distinct `host-unattested` seat counts as a recorded note, whose boundary is the live merge-gate read, an exception to ruling `closure-requires-independent-verification`). Each `frontend` or `backend` criterion needs a supporting check that declares
    `evidence_required`, and receipts carrying every declared kind. A missing required attestation, a
    missing declaration or a missing kind makes the verification lane `unavailable`; name the gap.
11. Set the verdict from the lane results: `approved`, `changes-requested`, `blocked` or
    `unavailable`. Emit the review and its findings, and report what is still open.
12. On `approved`, record the gate for this mode: `node <this skill's directory>/../../bin/ak-gate.mjs record
    --gate review-full`, `review-delta` or `review-readiness` (the bundle's `bin/`). A `full` that returned
    `changes-requested` records `review-full --verdict changes-requested`; no other verdict is recorded. A
    full record on an earlier head, or one that requested changes, counts once an approved delta recorded
    after it covers the head. Run it from the project checkout; the run defaults to the branch's opened-run
    pointer (or the branch-named v1 run) and records to the git directory. A binding's brief supplies
    `--dir`. A record on a run that `ship-preflight` has closed is refused; the task needs a new `open`.

## Hard gates

Gate: reviewers cannot edit source ([`policies/review.yaml`](../../references/shared/policies/review.yaml) `reviewers_may_edit_source: false`), and
the snapshot is immutable for the length of the run. A reviewer that changed what it was reviewing
has reviewed nothing.

Gate: a required lane that returns `unavailable` blocks approval. It is never downgraded to an empty
result, never backfilled by the author, the implementer, another seat or the synthesis step, and
never replaced by self-review. The review names the lane and why, and stays resumable (ruling
`required-lane-failure-is-unavailable`).

Gate: a seat that cannot be filled independently of the author is unavailable, and unavailability
blocks the checkpoint rather than falling to whoever is still there (ruling
`missing-supervisor-never-implementer`).

Gate: an author may never close their own finding, and a finding closes only on independent
verification evidence plus a policy rule saying that evidence is sufficient for it. A receipt is the
unit of that evidence: it carries the command or probe, its exit status, the output digest, the
revision and the environment identity ([`schemas/verification.schema.json`](../../references/shared/schemas/verification.schema.json)). An agent's description of
a green run is not a receipt. A classifier's output and a reviewer's confidence are recorded as
advisory, and a changed patch does not inherit stale receipts (ruling
`closure-requires-independent-verification`). A receipt or a verdict is stale once the revision or
the working-tree diff hash it names differs from the snapshot being judged; either one moving is
enough.

Gate: at most two fix-and-verify cycles after the first pass. The third request stops with the cap
decision and the open findings attached; repeated failure is a signal about the plan, not an
invitation to a third loop (ruling `two-fix-cycles-then-stop`). With only P3 findings open it is
`merge-with-follow-ups`, listing them in `fix_cycles.follow_ups`, and the verdict may be `approved`.
When two consecutive cycles reopened the same finding theme it is `design-decision`, naming it. A
cycle a human authorizes after the decision is recorded in `fix_cycles.extensions` (`authorized_by:
human`, operator-attested, and when) and reviewed as a `delta` that may approve, never as a new
`full`; without that entry it is refused.

Gate: where architecture, requirements, the comparison base or the affected surface changes
materially, the affected approvals are invalidated and a new baseline is deliberately established —
a new review scope with its own pass 1, never an unbounded third delta loop. The run records its
comparison base, its reviewed head and the last head verified in the delta loop so the three are
never conflated (ruling `delta-baseline-reset-not-third-loop`).

Gate: a finding whose solution space is still open is never handed to an automatic fixer. A `smell`
carries a null difficulty, because inventing a difficulty before the solution class is known is the
error the axis exists to prevent; its action class is never automatic; and its dispatch is to
sharpen, to diagnose or to escalate, never a fixer ticket ([`schemas/finding.schema.json`](../../references/shared/schemas/finding.schema.json), ruling
`safe-auto-restricted-per-seat`). Pressure to hand it over anyway is not a reason it became
specified.

Gate: a standards finding cites the project rule it rests on, rule by rule, with the file and the
rule identifier. Where the project declares no standards the seat returns an empty result: absent
standards never become invented preferences, and a seat that cannot cite a rule returns empty
([`policies/review.yaml`](../../references/shared/policies/review.yaml)).

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "The security seat could not be seated, but the implementer knows this code best and can look at it." | Backfilling a seat from the author lane produces an approval no independent evidence supports, which is the one thing an unavailable lane must never become (ruling `missing-supervisor-never-implementer`). | Record the lane as `unavailable` with the reason, block approval, and leave the run resumable for when the seat can be filled. |
| "Autopilot needs two independent judgments; I will start two reviewers myself, or reuse the standards seat I already started." | A helper this run started is not independent of this run, whoever it is told to be (ruling `missing-supervisor-never-implementer`), and the supervisor judgments are not seats of this panel (ruling `firstmate-outer-loop-agent-kit-inner`). | Finish the panel's own lanes, and return the request for the two judgments to the supervisor that owns the task (Firstmate, where one supervises), which dispatches them as separate agents. |
| "Only one lane is missing and everything else came back clean, so the verdict is approved with a note." | A required lane's absence is a result, not a footnote; an approval with a note reads downstream as an approval (ruling `required-lane-failure-is-unavailable`). | Set the verdict to `unavailable` or `blocked`, name the lane, and say what would make it runnable. |
| "It is a one-line change, so spawn the standard panel anyway — it is cheaper than deciding." | A fixed roster is the position this package refused; it spends seats on a typo and teaches readers that panel size means nothing (ruling `panel-composition-by-declared-risk`). | Select from declared risk and attached packs, and record which seats were selected and which signals selected them. |
| "The fix only touched three lines, so the delta reviews those three lines." | The impact of a fix reaches callers the fix never touched, and a line-based boundary suppresses exactly the class of issue the delta exists to catch (ruling `delta-scope-affected-behavior`). | Bound the delta by affected behavior, and report a serious issue in an untouched affected caller with its novelty evidence. |
| "Give the reviewer the implementer's summary so it knows what the change was trying to do." | The narrative is the author's account of their own work, and a seat that reads it is judging the account rather than the change ([`policies/review.yaml`](../../references/shared/policies/review.yaml)). | Hand the seat the frozen snapshot and its own requirements, standards and test context, and nothing produced by the author lane. |
| "The finding is vague, but the fixer is good at this — hand it over and let it work out the details." | A smell is a problem whose solution space is still open, and handing it to an automatic fixer buys a change nobody specified against a difficulty nobody could yet know (ruling `safe-auto-restricted-per-seat`). | Keep the difficulty null, sharpen the finding into a bounded one, diagnose it, or escalate it — and record which of the three the dispatch was. |
| "The reviewer rated the fix high-confidence, so the finding can be marked resolved." | Confidence is a property of the judge; closure is a property of the evidence (ruling `closure-requires-independent-verification`). | Record the confidence as advisory, and close only on independent verification evidence for the revision the fix is at. |
| "The base moved and the requirements were rewritten, but the delta loop still has a cycle left." | Continuing a loop whose comparison base no longer means what it meant spends a cycle comparing against a baseline nobody approved, and the approvals it carries forward were given for a different change (ruling `delta-baseline-reset-not-third-loop`). | Invalidate the affected approvals, record what changed materially, and open a new scope at pass 1 rather than spending the remaining cycle. |
| "The cap is reached, so replan and open a new full scope over the whole change." | A full pass over a change already reviewed re-litigates settled code and finds new nits each round, so the loop never ends (ruling `two-fix-cycles-then-stop`). | Review the new commits as a `delta` against the last reviewed head. |
| "The third cycle is nearly there — one more round and it is clean." | Two cycles that did not converge are evidence about the plan, and a third loop spends the budget that the cap decision exists to protect (ruling `two-fix-cycles-then-stop`). | Stop, emit the cap decision, attach every open finding, and report what is unresolved. |
| "The diff is 400 lines, which the engineering principles call too large, so that is a finding." | Size targets and test ratios are configurable starting points, and a finding written from one is a finding about a number nobody agreed to (ruling `numeric-heuristics-are-guidance`). | Review what the change does. Raise size only where it names a concrete review or maintenance consequence in this change. |

## Outputs

The review ([`schemas/review.schema.json`](../../references/shared/schemas/review.schema.json)): mode, comparison base, reviewed head, the snapshot with
its hash and exclusions, the authorship record, one entry per lane with its state and verdict, the
fix-cycle count, the verdict, and — where a baseline was reset — what changed materially, which
approvals it invalidated and the new comparison base.

The findings ([`schemas/finding.schema.json`](../../references/shared/schemas/finding.schema.json)), each with its evidence quoting the line it is about,
its fingerprint — rule-or-cause plus location-or-symbol plus evidence, never the line number — and
its action class. No code-review seat emits `safe_auto`: at review time a code edit has no single
mechanically correct answer, so classification is a proposal and applying it is the caller's decision
under its own authorization. A `safe_auto` arriving from a peer lane is remapped to `gated_auto` and
never dropped (ruling `safe-auto-restricted-per-seat`). A finding's dispatch is single-valued and a
`smell` is dispatched only to sharpening, diagnosis or escalation, so the review records which of the
three it took and never a fixer ticket.

A lesson candidate marked on any finding that teaches a durable rule. This skill marks it and
publishes nothing: the knowledgebase write is not inside the envelope the review operations declare.

All of it is emitted as run artifacts under `artifact-write`. This skill names no repository path for
project-derived content.

## Side effects

`artifact-write`.

No `workspace-write`, no `local-commit`, no `remote-push`: the review operations declare one effect,
and a seat that edits, commits or pushes has left the envelope the runner validated.

No `pr-comment`: posting a review onto a pull request is a separate granted action and belongs to the
skill that holds it.

## Stop conditions

`complete`: every selected lane has a state, every required lane is `covered`, the
verdict is set, and the review and findings are emitted. A run whose verdict is `blocked` is
complete; the block is the result. A delta that ends by establishing a new baseline is complete too:
the reset closes this scope and the new scope opens at pass 1, which is not a third loop (ruling
`delta-baseline-reset-not-third-loop`).

`needs-input`: no comparison base or reviewed head was named, or `delta` was invoked with no open
review run. Returns what it would need, and no partial verdict. A missing typed command is not
this stop.

`cap-reached`: a third fix cycle was requested. Stops with the cap decision (blocked, replan,
merge-with-follow-ups or design-decision) and every open finding attached.

`failed`: a required lane returned `unavailable` and the run cannot proceed, or the snapshot could
not be frozen. The lane and the reason are named, and the run stays resumable.

`cancelled`: the caller withdrew mid-run. Lane results already collected are kept and emitted as
what they are.

## Limits

Fix cycles: 2 (gate). [`policies/limits.yaml`](../../references/shared/policies/limits.yaml) `fix_cycles`. The third stops with the cap decision
rather than another pass.

Review rounds: 3 (gate). [`policies/limits.yaml`](../../references/shared/policies/limits.yaml) `review_rounds`, counted across the run.

Panel size: no cap (guidance); the count follows declared risk. Small pass-1 diffs seat the lean
panel; a delta seats its two core lanes plus only the specialist seats a prior finding or its diff triggers.

Change size and test ratios: not gates (guidance). Carried in [`engineering-principles`](../../references/shared/references/engineering-principles/REFERENCE.md),
set per project, and never grounds for a finding on their own.

Runner budgets: a cap the runner did not supply is not enforced and not guessed
([`policies/limits.yaml`](../../references/shared/policies/limits.yaml)).
