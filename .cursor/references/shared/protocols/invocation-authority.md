# Invocation authority

Shared doctrine. The protocols in this directory cite it rather than restating it. It states what
"authority" is allowed to mean in this package, and what it is never allowed to mean.

## Two classes of operation

There are public entrypoints and there are shared phase operations, and the difference is who may
start them.

A **user-invoked public entrypoint** is started by a human. On a host with a slash-command surface,
only the slash command counts as the human act. A **phase operation** is the same phase logic
reached by a delegated controller, and only when the runner validates a grant that covers it (ruling
`entrypoint-phase-operation-split`). The two are one
pipeline with two doors: a delegated run executes the same protocol a human-started run does, so
there is no second, looser path through the lifecycle.

This split is the resolution of a genuine contradiction in the sources, which forbade a
user-invoked skill from starting another user-invoked skill while also describing exactly that
happening in three places (ruling `entrypoint-phase-operation-split`). It is not an exception to
the law; it is the shape that makes the law satisfiable. The register of operations, their
grants and their permitted controllers is [`policies/invocation.yaml`](../policies/invocation.yaml); the mechanics are
[`protocols/phase-operations/PROTOCOL.md`](./phase-operations/PROTOCOL.md).

Which capability belongs in which class is `catalog.yaml`'s answer, never this file's.

## Start authority and delegated authority

Start authority is declared in [`policies/invocation.yaml`](../policies/invocation.yaml). Review's model-start decision is
[ADR-0013](../docs/decisions/0013-model-starts-super-review.md).

For a human-started phase, a human invoked the public entrypoint in this session, or the runner
validated a grant against an immutable charter and issued a grant reference carrying the charter
hash and the single action or checkpoint it covers ([`policies/authority-defaults.yaml`](../policies/authority-defaults.yaml)). Under the
opt-in unattended policy ([ADR-0014](../docs/decisions/0014-unattended-lifecycle-policy.md)), align,
bound and ship also start when the gate tool's `unattended check` exits 0, with no command or grant, the
human boundary being the live protected merge: an exception, for that policy only, to ruling
`entrypoint-phase-operation-split`.

Neither a local artifact nor a seat's confidence supplies a grant. In particular:

- A skill never issues its own grant. A component that could issue one could authorize itself.
- A grant covers exactly one action or checkpoint category and does not generalise. A grant for
  one operation is not a grant for the next.
- The charter is fixed outside worker-writable scope and identified by a hash. A charter that
  changed is a new charter, and prior grants do not survive it.
- An approval binds to an artifact hash. A changed artifact inherits neither the approval nor the
  receipts that supported it.

## Ordinary workers cannot manufacture a grant

An implementer, a reviewer or any other seated role cannot start a human-started phase without
authority, approve its own work, or promote itself to a class it was not dispatched as. Agreement
between two seats is necessary and not sufficient: the deterministic authority check runs independently and must also
pass — required evidence present and still bound to its hashes, and the charter listing this
checkpoint and this action (ruling `supervisor-agreement-is-not-authority`). Confidence is not a
grant either. Where a seat believes it needs authority it does not hold, the correct output is an
escalation, not an action.

## Where a grant cannot be validated, stop

Some hosts cannot validate a grant at all. For a delegated operation requiring one, halt and ask
for explicit invocation rather than reaching the same effect another way. Four substitutes are
named and forbidden ([`policies/invocation.yaml`](../policies/invocation.yaml) `no_side_door`): re-implementing the operation's steps inline under
the caller's own authority; chaining model-invoked skills that reproduce the operation's side
effects; asking a supervisor pair to approve an action the charter does not list; and treating a
prior grant for a different operation as covering this one.

The required result is `needs-input`, with `escalation.charter_rule` naming the policy and
`next_permitted_action` naming the exact entrypoint a human would invoke, stored so the run
resumes without repeating side effects.

## A policy file is not an enforcement mechanism

This is the distinction that erodes first, and the one worth stating plainly.

A protocol file describes what should happen. It does not prove that the host made it happen.
The runner's permission system validates delegated authority; everything a run writes about
itself is evidence a reader may inspect.

That distinction has a practical consequence learned the expensive way upstream. A design that
treated a run's own local lifecycle records as a hard gate had to be retired: those records are
advisory, written by the workspace about itself, so treating them as a security boundary lets a
missing or corrupted record wrongly block a legitimate run, and a forged one wrongly pass. The
replacement separates the two classes of check. Identity, scope and corruption checks are things
a runner can actually verify, and they stay fail-closed. Ordinary progression on incomplete
lifecycle evidence continues, but the gap is surfaced as a visible advisory naming which gate was
skipped and which evidence was missing, and the run's terminal status says so rather than
reporting an ordinary completion.

Applied here: a ledger entry saying "review passed" is evidence, never permission for a human
step to be skipped. A runner-issued grant carries delegated authority; a lifecycle record does not.

## Independence is structural, never an identity

Two seats declared independent are independent because the runner attests it: distinct seat
identifiers bound to the run, no shared context between them for the same decision, and none of
the excluded lineages ([`adapters/runner-contract/CONTRACT.md`](../adapters/runner-contract/CONTRACT.md) §3). Independence is never
expressed as, satisfied by, or checked against which system fills the seat. A seat that cannot be
filled under those constraints is unavailable, and unavailability blocks the checkpoint: it is
never backfilled by the implementer, the author, the spec approver or a seat already sitting on
the panel (ruling `missing-supervisor-never-implementer`). A required lane that is unavailable
blocks approval on the same terms, is never downgraded to an empty result, and is never
backfilled by the author, the implementer, another seat or the synthesis step (ruling
`required-lane-failure-is-unavailable`).

## Shipping is not permission to write knowledge

A ship may draft a lesson candidate from evidence already present in the run. Publishing it is a
separate act needing explicit authorization or a charter grant, and it goes to the central
knowledgebase rather than to a documentation tree inside the working repository (ruling
`central-kb-owns-project-artifacts`; [`adapters/knowledgebase/CONTRACT.md`](../adapters/knowledgebase/CONTRACT.md)). A run that finished
successfully has not thereby earned the right to rewrite what the project believes.

The same shape covers the actions no charter grants by default — merging, deploying, irreversible
data operations, public contract changes and the rest. Each needs a human-approved charter entry
naming the action, its scope and its bound (ruling `sensitive-actions-need-approved-charter-entry`).
An approved ticket, a green pipeline and an approved review are three pieces of evidence and zero
authorizations.

## Packs never start a phase

Domain packs attach by artifact and semantics. They add constraints and review lenses to a phase
that is already running, and they are never entrypoints, never operations and never a trigger
([`policies/invocation.yaml`](../policies/invocation.yaml) `packs`; [`protocols/attach-pack/PROTOCOL.md`](./attach-pack/PROTOCOL.md)).

Protocols and roles are likewise not entrypoints: a protocol is shared phase logic a skill
invokes, a role is a prompt the runner fills a seat with, and neither is human-invocable nor
appears in a host command surface ([`policies/invocation.yaml`](../policies/invocation.yaml), statement
`protocols-and-roles-are-not-entrypoints`).
