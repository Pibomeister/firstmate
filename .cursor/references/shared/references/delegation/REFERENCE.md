# Delegation records

Load this reference when a lifecycle body creates or consumes a ticket's `delegation`, `readiness`
or `assumptions` fields. The record controls which already-chartered checkpoints may be delegated;
it is evidence, not a finding and not a source of authority.

## Classes and checkpoint authority

The closed class vocabulary is `green`, `yellow-agent`, `yellow-owner` and `red`.

| Class | Authorship meaning |
| --- | --- |
| `green` | An agent may author the bounded implementation. |
| `yellow-agent` | An agent may author the implementation, with the human involvement the policy reserves. |
| `yellow-owner` | An agent drafts while a named human owns the work and approves the ticket before build. |
| `red` | A human authors the implementation; an agent may assist with bounded research or regression tests. |

The authoritative class-to-checkpoint map is
[`delegation_classes`](../../policies/authority-defaults.yaml). Read it at the checkpoint; do not
copy its lists into a skill. A class only narrows checkpoint authority already present in a
runner-validated charter. It never grants authority, and it is never a finding. Project guidance
may raise the class without producing a finding (ruling
`delegation-class-is-authority-not-finding`). Record downstream authorship as author kind plus host,
never as an implementation identity.

The class changes authorship and checkpoint authority, not whether bounding produces a ticket. A
`red` result produces a human-owned implementation ticket and limits agent participation to the
bounded assistance the ticket names. Under the opt-in unattended policy (ADR-0014,
`docs/decisions/0014-unattended-lifecycle-policy.md`) the agent implements a ticket whose class makes
a human the author, within its allowed changes, with the true class, floor and `author_kind: agent`
recorded and no approval written, the human boundary being the live protected merge: an exception to
ruling `delegation-class-is-authority-not-finding` for that policy only. A ticket whose class makes a human the author states the
authorship boundary in existing fields. `allowed_changes` remains the ticket's
full write scope for the implementer. Name the agent's permitted file and symbol subset in text, in
`goal` or `stop_conditions`, alongside non-file assistance such as research; put prohibited agent
work, including authoring the implementation outside the unattended policy, in `non_goals`. Under that
policy the agent may author only the ticket-scoped implementation, its author kind recorded as `agent`. On a decision ticket the boundary
lives in `goal` and `non_goals`. Naming a human owner alone is not that boundary.

`merge` and `deploy` remain sensitive actions for every class, and a human merges every class. A
never-dropped pack or required sensitive action sets a floor that no factor or lowering may cross;
re-evaluate that floor from the actual diff before closure (ruling
`sensitive-surface-sets-the-floor`).

## Two snapshots and lowering

The ticket-time snapshot carries `stage: ticket`. It predicts the work from the approved scope,
attached packs, required sensitive actions, expected size, known history, specification and planned
verification. It decides how the work may be staffed before implementation.

The merge-time snapshot carries `stage: merge`. It uses the actual diff and verification evidence.
It may raise the class automatically. It does not inherit a lower ticket-time result when the diff
requires a higher one (ruling `delegation-class-is-authority-not-finding`).

`lowered_by` is normally `null`. A lowering records:

- `human`: the named person who made the decision;
- `reason`: evidence for the exception;
- `at`: the decision timestamp;
- `from`: the computed class that was lowered.

A later computed class above `from` supersedes the lowering and records `superseded: true`. A
lowering never crosses the sensitive floor. An instruction to delegate, a confidence statement, or
an advisor opinion is not lowering evidence.

## Obtain the record from the scorer

First write the ticket's evidenced `floor`, five factors, `stage`, `lowered_by` and a `class` seed,
and ensure both the ticket and project record validate. The seed is an input the schema requires,
not a judgment: a first ticket-time block seeds `class` at `green`, and a re-run carries the class
the previous run persisted. When `lowered_by` records a named human's lowering, the seed is the
class that person lowered to; the scorer still holds the floor and supersedes the lowering when a
later computed class exceeds `from`. The scorer only raises the seed, so any seed outside these
three cases is a hand-derived class. Then run:

```text
ak delegation <ticket> --project <project-record>
```

Persist the command's complete JSON output as the ticket's `delegation` block. Cite the ticket and
project artifact references used for the run wherever another artifact consumes the result. A body
must not reproduce the formula, weights, cut points, floor table or lowering logic. A missing or
failed scorer run leaves no delegation record and blocks the checkpoint.

## Factor evidence

Every factor carries a project-guided score and at least one evidence string. The meanings are
central; weights and cut points are project-configurable, advisory starting points. A score is an
integer from 0 to 3. For `reversibility`, `size`, `complexity` and `spec` a higher score records
more risk. `verification` records strength: a higher score means stronger verification, and a
ticket with no tests scores 0.

| Factor | Evidence expected at ticket time | Evidence expected at merge time |
| --- | --- | --- |
| `reversibility` | Flags, user visibility, data writes, external effects and consuming services. | Actual flag, migration, contract and external-effect behavior. |
| `size` | Estimated changed lines, files, modules and generated exclusions. | Measured diffusion across changed non-generated code. |
| `complexity` | Concurrency, caching, distributed state, known hotspots and prior fixes. | Complexity delta, churn, prior-fix evidence and new stateful constructs. |
| `spec` | The six readiness criteria, vague terms and unresolved assumptions below. | Decisions exposed by the diff that the approved ticket did not settle. |
| `verification` | Existing tests, the planned oracle and named verification path. | Receipts for tests, fail-before evidence, static checks and integration coverage. |

Hotspot overlap and prior-fix density are transparent evidence when a project can supply them. Their
absence is recorded; a body does not invent either measurement.

## Readiness and vague terms

Every ticket records all six criteria separately. Each criterion carries its own score and evidence;
a total never substitutes for a failed criterion. The evidence states what was checked and the
artifact, field, command or repository location checked; a boolean or status word never substitutes
for it. No readiness or stop flag is persisted outside the schema: readiness is the six scored
criteria with evidence, and the stop is stated in the result. A criterion score is an integer from
0 to 2, where a higher score means the criterion is more fully met and 0 means it is absent.

| Criterion | Evidence expected |
| --- | --- |
| `acceptance_criteria` | Each outcome is observable and checkable. |
| `interfaces` | Files, functions, routes, types or schemas are named at the appropriate boundary. |
| `examples` | A happy path and at least one relevant edge or error case are stated. |
| `non_goals` | Excluded behavior is explicit. |
| `existing_pattern` | The file or module to imitate is identified, or absence is evidenced. |
| `verification_path` | The test level and fixture or data source are named. |

`vague_terms` records each detected word or phrase, including terms such as “fast”, “clean up” and
“as needed”. Turn every unresolved hit into a frontier question that asks for the missing boundary
and proposes a concrete verification path: observable, workload or fixture, measurement or oracle,
and pass condition as applicable. Express the pass condition against the value the human supplies,
for example `p95 of <observable> on <workload> is at or below the target you name`; never choose a
number or otherwise invent the missing target. A criterion that remains ambiguous fails on its own
evidence; do not turn a readiness total into a finding or use it to fill in the missing decision.

## Assumptions

Record every assumption and resolve it as exactly one of:

- `criterion` when it changes behavior that users or consumers can observe;
- `non-goal` when the approved scope deliberately excludes it;
- `open` when a decision is still missing.

An `open` assumption is not implementation latitude. Resolve it before implementation, or emit a
decision ticket and stop the affected slice at the zero-context gate.

Persist `delegation`, `readiness` and `assumptions` on the draft ticket before any `needs-input`
return reached after this assessment. The stop carries the evidence that justified it; it does not
erase the draft or reduce the result to prose. It is stated in the result and cites the failed
criteria and their evidence.
While a specification or review decision is open, an evidence-bearing draft, where one exists, is
kept and retyped `decision`, and no implementation ticket exists. An open assumption is per slice;
that slice becomes a decision ticket at the zero-context gate and unrelated slices proceed.
Retyping is more than the `type` value: add the `decision` object the ticket schema requires,
carrying the open question, and drop `allowed_changes`, `write_ownership` and `integration_owner`,
which a decision ticket may not carry. `delegation`, `readiness` and `assumptions` stay.

## Stack construction

Slice on independently verifiable behavior, not on a universal line count. Each slice is a narrow
but complete path through every layer, independently verifiable and sized for one fresh context
window. Order a stack as pure refactor, additive schema expand, behavior behind a flag, consumer,
backfill, then schema contract. The schema-contract change is a separate ticket. Where one
mechanical change breaks call sites across the tree and no vertical slice can land green, use the
wide-refactor shape instead: expand, then migrate in batches with each batch its own ticket blocked
by the expand, then contract, blocked by every batch. Each ticket names its criteria, interfaces,
ownership and verification.
When the direction already spans these independently deployable phases, their boundaries require
the ordered stack. A request to keep them in one ticket becomes an open decision; it does not erase
the boundaries. The decision ticket itself carries the full ordered stack as the recommended option,
in its `decision` question or its `goal`, with no exception alternative.

## Advisor consultation

On a host that offers an advisor facility, consultation is required and recorded as judgment
evidence for `yellow-owner` and `red`, recommended for `yellow-agent`, and silent for `green`.
The record surface is the knowledgebase consultation artifact: store the advisor's result there, and
cite it from the ticket's `kb_refs` as an evidence reference of kind `transcript` or `receipt` whose
`note` names it judgment evidence. Its `ref` is the artifact's reference and its one-line `note`
also says what it was used for. A filesystem path, document name or URL by itself is not evidence.
The ticket carries the citation, never the consultation itself.
Consultation adds judgment evidence only: it never lowers `delegation.class`, authorizes a sensitive
action, closes a finding or substitutes for a required independent lane. A host without the
facility remains valid and records no invented consultation evidence (ruling
`advisor-consultation-follows-class`).

## Light route for a text-only single-slice ticket

Load this section at super-bound step 7 when the author claims a single-slice ticket is text-only.
It is the single normative definition of that route; super-bound step 7 holds only a pointer here.

**Eligibility.** The route is open only to a single-slice ticket whose every changed path the
author claims, path by path, changes no required behavior. An eligible path is non-normative
documentation, or explanatory or optional guidance prose in an existing skill or reference, that
changes no required action, trigger, process ordering, acceptance criterion, limit, model routing,
independence, permission, authority or trust rule, gate or receipt rule, publication guarantee or
destructive guarantee. Executable, source, configuration, schema, API-contract, policy, adapter,
role, protocol, test and tooling surfaces stay excluded, and the exclusions always win: clarifying
prose cannot amend a rule by calling itself clarification, and a disputed or uncertain restatement
takes the normal path. Extension alone and a green class alone never establish eligibility, and
doubt takes the normal path. A restated rule needs the exact pinned settled-source quote with its
context and a no-looser comparison.

**The claim.** The claim is written before review, in existing ticket, specification, readiness
and verification fields only: the per-path semantic explanations, the integration owner named in
the existing `integration_owner` field and, for any restated rule, the pinned quote with context
and the no-looser comparison. The claim is not an approval, and no field is added for it.

**Preparation.** The one real saving is bounded compact preparation: one compact content is
written once and the complete existing-schema specification and ticket are both prepared from it
before the review snapshot, and the route has no light correction loop, so any correction takes
the normal path. The plan record is still produced. The capability map, consensus gate and
multi-slice slicing are already skipped for this ticket shape on the normal path and are not
savings. For an eligible candidate only, the complete ticket — interfaces, edges, readiness, the
zero-context details and the persisted real scorer output — is prepared before the step 7
snapshot; this narrow ordering exception leaves the non-eligible path's steps in their current
order. Persisting the real scorer output is part of that preparation, never a post-snapshot edit.

**Review.** One unchanged full first-pass document review reads the derived specification as the
document. The specification is the one reviewed document: the eligibility claim, the per-path
semantic explanations and any pinned settled-source quotes are written in the specification's
existing fields, so they sit under the reviewed hash. The complete ticket is pinned in the
review's `inputs` as provenance of the frozen second hash; it is not presented to seats as settled
recorded context, and no seat is promised ticket text that is not in the specification. Both exact
specification and ticket hashes are frozen at the snapshot; steps 10 to 13 then only check the
already-prepared content, any semantic change they would need takes the normal fallback, and any
later ticket edit invalidates eligibility normally.

**Exits.** The route is left on any verdict other than approved, any non-empty Proposed fixes or
Decisions bucket, any unavailable required lane, any reported finding in any bucket including FYI,
or any semantic edit after the snapshot, including an Applied edit. An eligibility doubt is a
finding a seat files at anchor 50 or above. Preserved lane raw outputs are an audit surface only:
a doubt reaches this exit only as a filed finding, and no exit is promised on a doubt a seat does
not file. Leaving
the route keeps the real first-pass receipt for its original hashes and roster and the review's
run, cycle and counter history; it never declares changed hashes reviewed, never drops a newly
required lane and never repeats a valid seat without cause. The existing delta, primer and
required-lane rules in the review policy govern continuation.

**Approvals.** The supervisor's existing specification stop and ticket stop approve or refuse the
eligibility claim bound to those exact hashes; both approval requests state that the light route
was taken and enumerate the per-path claims and the exact input hashes. There is no earlier gate
and no inherited approval.

**Before closure.** A manual semantic comparison of the actual exact-head diff against the pinned
settled rule and each per-path claim is additional closure evidence on this route: the independent
code-review actor receives the pinned quote, the per-path claims and the diff and
reports the comparison, and the ticket's integration owner accepts or refuses it. With no actual
manual comparison the ticket is not eligible and takes the normal path. A normative or
required-action change leaves the route, and the existing class rules decide whether the class
raises. A series that raises uncertainty takes the normal path with no new counter or monitor.
