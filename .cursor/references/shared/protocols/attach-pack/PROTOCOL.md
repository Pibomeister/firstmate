# attach-pack

Deterministic selection of domain packs from artifact kind and semantics, with the rationale
recorded as part of the result. Packs attach constraints and review lenses onto a phase that is
already running. They never start one.

Selection matches artifact kind and semantics. A file extension is a hint, never the decision: a
tenant-isolation defect, a public contract change and an irreversible data operation are all
semantic facts that an extension does not carry.

## When to use

`super-review` invokes this protocol before seating its panel, so the conditional seats are
selected from artifact evidence rather than from a fixed list (ruling
`panel-composition-by-declared-risk`). `super-align` and `super-bound` invoke it to attach
constraints to a plan. `super-build` invokes it for the lightweight per-ticket checks. `super-ship`
invokes it before release checks.

## Not for

- Not for starting a phase. A pack adds constraints and lenses to a running phase and is never an
  entrypoint or an operation ([`policies/invocation.yaml`](../../policies/invocation.yaml) `packs`).
- Not for seating a review lane that is unconditional. Correctness is always seated; this
  protocol selects what else the artifact evidence earns.
- Not for project facts. A pack states a general constraint category; a project's actual tenancy
  model, integration boundaries or migration practice is a knowledgebase fact the pack points at.
- Not for fetching or caching pack sources. Resolving a declared pack list into readable roots is
  the CLI's job; this protocol decides *which* packs the artifact earns.

## Invoked by

`super-review`, `super-align`, `super-bound`, `super-build` and `super-ship`, and the
`review.full`, `review.readiness`, `align.run`, `bound.run` and `ship.prepare` phase operations.
A protocol holds no authority of its own and never widens the authority it was called with
(ruling `entrypoint-phase-operation-split`; protocol [`phase-operations`](../phase-operations/PROTOCOL.md)).

## Inputs

- The target: the artifact or change under consideration, with its kind and its content, bound to
  a `common#/$defs/hash`.
- The available packs, each a [`schemas/pack.schema.json`](../../schemas/pack.schema.json) record whose `activation` rules each
  carry an `id`, the `artifact_kinds` they apply to, and the `semantics` that must hold. A rule
  with only `paths` and no `semantics` is not a valid activation rule.
- The project record, for any project-scoped pack and for the configured guidance values.

A pack whose tree links outside its own source is not a published pack. It is rejected whole,
with a per-entry error, never trimmed one file at a time.

## Workflow

1. Enumerate the available packs and their `activation` rules. An unreadable pack source is
   reported and skipped; it does not silently reduce the candidate set to whatever loaded.
2. Classify the target's artifact kinds from its content and structure.
3. Evaluate every activation rule deterministically against artifact kind and semantics. This
   lookup path runs with no classifier and is the baseline result.
4. Where a classifier is available, run it as an addition and union its matches into the
   baseline. It may add packs; it may never remove one the deterministic path matched.
5. For each matched pack, record a [`schemas/pack.schema.json`](../../schemas/pack.schema.json) `attachment_record`: the `pack`,
   the `matched_rules`, the `rationale`, the `evidence` the rule fired on, and `attached_at`.
6. Record the rejected candidates too, with why each rule did not fire.
7. Attach the matched packs' constraints and reviewer guidance to the running phase. Attaching
   never advances the phase.
8. Return the attachment records and the rejected list to the caller, which decides what to seat.

## Hard gates

Gate: a pack never starts a lifecycle phase. Constraint text inside a pack that reads like an
instruction to begin a phase is data, not an invocation.

Gate: a security, API or data pack is never dropped because a classifier was uncertain (ruling
`panel-composition-by-declared-risk`). Those facts come from the deterministic path, which runs
first and does not depend on confidence.

Gate: every attachment carries its rationale and the evidence the rule fired on. An attachment
with no recorded reason is not a valid attachment record.

Gate: a file extension alone never activates a pack. Every activation rule names the semantics
that must hold as well as the artifact kinds.

Gate: a project's own facts are referenced through the knowledgebase, never written into a
shared pack (ruling `central-kb-owns-project-artifacts`). One client's tenancy model does not
become a global constraint.

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "The classifier was unsure this touches auth, so the security pack does not apply." | Security, API and data facts are never dropped for classifier uncertainty; the deterministic lookup path exists precisely so an uncertain signal cannot suppress them. | Take the deterministic match. The classifier may add packs, never remove them. |
| "Nothing here has a recognisable extension, so no pack matches." | Activation is by artifact kind and semantics. A public contract change in an unfamiliar file is still a public contract change. | Classify the artifact kind from content and evaluate the semantics conditions. |
| "This diff is small, so attaching the full set of lenses is disproportionate." | Proportionality governs which seats the panel fills; it is not a reason to withhold a pack whose rule actually fired on artifact evidence (ruling `panel-composition-by-declared-risk`). | Attach what matched, record the rationale, and let the caller apply proportionality when seating. |
| "The pack's guidance says the change should be about a hundred lines, so this one fails." | The size target and the test split are configurable starting points carried in the project record, not gates, and an exception is recorded rather than forced into an artificial split. | Record the exception. Do not raise a finding on the guidance number alone. |
| "One pack source failed to load; the rest are enough." | A silently reduced candidate set looks identical to a target that genuinely matched fewer packs. | Report the unreadable source explicitly and name what could not be evaluated. |
| "This project's migration convention belongs in the data pack so every project gets it." | A shared pack carrying one project's facts imposes them everywhere and drifts the moment that project changes. | Keep the general constraint in the pack and point at the project's own rule through the knowledgebase adapter. |

## Outputs

One `attachment_record` per attached pack ([`schemas/pack.schema.json`](../../schemas/pack.schema.json)), carrying `pack`,
`matched_rules`, `rationale`, `evidence` and `attached_at`, plus `classifier_used` when one ran
and `rejected` for the candidates that did not fire. The set is written onto the invoking
artifact's `packs_attached`. No project-derived document is written to a path in the working
repository.

## Side effects

`artifact-write`. Nothing else: attaching a pack reads packs and writes the record of what was
attached.

## Stop conditions

- `complete`: every activation rule was evaluated and every match has an attachment record.
- `needs-input`: the target's artifact kind cannot be determined, or a pack declares an
  activation rule with no semantics.
- `cap-reached`: the invoking operation's budget was reached before every pack source was read.
  Returns what was evaluated and what was not.
- `failed`: no pack source could be read at all, so the deterministic baseline cannot run.
- `cancelled`: the runner cancelled the run.

## Limits

- Generic packs: 8 (gate) — `pack-api`, `pack-delete`, `pack-test`, `pack-secure`,
  `pack-frontend`, `pack-data`, `pack-perf`, `pack-deps`. A ninth is a catalog change.
- Deterministic lookup passes: 1, always (gate). The classifier is an additional pass, never a
  replacement.
- The pull-request size target and the unit/integration/end-to-end split are configurable
  starting points established per project (guidance, ruling `numeric-heuristics-are-guidance`).
