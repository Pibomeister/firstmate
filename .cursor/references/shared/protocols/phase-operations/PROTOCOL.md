# phase-operations

The split that satisfies the invocation law. A user-invoked public entrypoint is started by a human;
a phase operation is that same phase logic reached by a delegated controller, and only when the
runner validates a grant covering it (ruling `entrypoint-phase-operation-split`). One pipeline, two
doors: a delegated run never takes a path a human-started run does not.

## When to use

[`policies/invocation.yaml`](../../policies/invocation.yaml) `operations` is the register. Each entry names the skill that exposes
it, its authority requirements and the controllers that may call it. A controller enters this
protocol to run a declared operation. For review's model-started public entrypoints, see
[ADR-0013](../../docs/decisions/0013-model-starts-super-review.md).

A human invoking a user-invoked public entrypoint runs the same steps under `authority: explicit`.

## Not for

- Not for deciding whether a phase should run at all. That trigger belongs to the calling skill.
- Not for the phase's domain work. `tdd`, `apply-findings`, `review-delta`, `consensus-plan-gate`,
  `worktree-ownership` and `attach-pack` each hold one phase's mechanics; this protocol holds
  only what is identical across all of them.
- Not for the skills in [`policies/invocation.yaml`](../../policies/invocation.yaml) `no_operation_exposed`. They expose
  no operation; a controller that needs their effect stops and names the slash command.
- Not a command surface. An operation has no host command, no description a model matches
  against and no path to a human ([`policies/invocation.yaml`](../../policies/invocation.yaml), statement
  `protocols-and-roles-are-not-entrypoints`).

## Invoked by

The skills named in `operations[].exposed_by`, through the controllers named in `callable_by` on
the same entry. A protocol holds no authority of its own and never widens the authority it was
called with (ruling `entrypoint-phase-operation-split`; protocol [`phase-operations`](./PROTOCOL.md)).

## Inputs

- The operation id, matching `common#/$defs/operation_id` and declared in
  [`policies/invocation.yaml`](../../policies/invocation.yaml). An undeclared id does not run.
- A `common#/$defs/grant_ref` when the entry's `authority` is `delegated-grant` or
  `explicit-or-delegated`. Absent, refused or unvalidatable: stop and return `needs-input`; a
  controller's belief that it is authorized is not a grant.
- Every artifact named in that entry's `preconditions`, each bound to its
  `common#/$defs/hash`. A precondition artifact whose hash no longer binds is absent. A precondition
  that names `trusted-evidence` is the signal in [`adapters/runner-contract/CONTRACT.md`](../../adapters/runner-contract/CONTRACT.md) §2, not an
  artifact hash.
- The runner-supplied budgets. A cap the runner did not supply is not enforced and not guessed
  ([`policies/limits.yaml`](../../policies/limits.yaml) `runner_supplied`).

## Workflow

1. Resolve the operation id against [`policies/invocation.yaml`](../../policies/invocation.yaml) `operations`. Not declared there:
   return `needs-input` naming the public entrypoint as `next_permitted_action`.
2. Check the caller against that entry's `callable_by`. Record the caller, skill, entrypoint and
   operation in the artifact's `common#/$defs/creator`.
3. Have the runner validate the grant against the immutable charter hash and the entry's
   `grant.covers` value ([`adapters/runner-contract/CONTRACT.md`](../../adapters/runner-contract/CONTRACT.md) §2).
4. Check preconditions in this order and stop at the first failure: prerequisites present;
   evidence freshness — every approval and receipt binds to the current artifact hash and source
   revision, and a changed artifact inherits neither; authority — the charter lists this
   checkpoint category and this action; budgets not already exhausted. Where the entry requires
   `trusted-evidence`, that check is [`adapters/runner-contract/CONTRACT.md`](../../adapters/runner-contract/CONTRACT.md) §2, and worker-attested
   gate records do not pass it.
5. For each declared `common#/$defs/remote_side_effect`, derive the idempotency key
   `sha256(run_id · operation_id · target_identity · input_artifact_hash)` and read the remote
   for it. Found with a matching input hash: record success without repeating the effect. Found
   with a different input hash: refuse and escalate.
6. Run the phase logic the entry names, inside the entry's own `hard_gates`.
7. Read the remote back after each remote effect and confirm the observed state matches intent.
8. Return exactly one `common#/$defs/operation_result` and persist the restart record: the
   `next_permitted_action`, the checkpoints reached and the idempotency keys already spent.

## Hard gates

Gate: a grant the runner cannot validate stops the operation for explicit invocation. It never
degrades to best effort ([`policies/invocation.yaml`](../../policies/invocation.yaml) `no_side_door`).

Gate: a remote effect whose idempotency key is not reproducible from persisted state does not
run at all. A key that incorporates a timestamp, a random value, an attempt counter or a
session-scoped identifier is not an idempotency key.

Gate: an effect whose read-back cannot be performed returns `failed` with the error. It is never
recorded as `complete`.

Gate: `complete` from a non-terminal operation hands control to the next phase. It is not the
run ending, and the operation never reports the lifecycle as done on its own scope finishing.

Gate: the returned status is one of the five `common#/$defs/operation_status` values. An ad hoc
string is not a status.

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "Grant validation is unavailable, so I will run the steps myself under my own authority." | Re-implementing the operation's steps inline is the first named forbidden substitute ([`policies/invocation.yaml`](../../policies/invocation.yaml) `no_side_door`). Where a host cannot validate a grant, the skill stops (ruling `entrypoint-phase-operation-split`). | Return `needs-input` with `escalation.charter_rule: policy:invocation/no_side_door` and the exact entrypoint a human must invoke. |
| "The run's own record says this phase passed, so the gate is satisfied." | A lifecycle record the workspace wrote about itself is worker-attested. It is not host-issued authority, and it does not satisfy `trusted-evidence` on an autonomous evidence-consuming operation ([`adapters/runner-contract/CONTRACT.md`](../../adapters/runner-contract/CONTRACT.md) §2). | Read the record as evidence. Name a missing grant, or name trusted evidence as unavailable, and stop with `needs-input`. |
| "This branch was already pushed once; pushing again is harmless." | A restart that repeats a remote effect is exactly what the key-plus-read-back rule exists to prevent. | Derive the key, read the remote for it, and record success without repeating the effect. |
| "I hold a grant for the full review, so the delta pass is covered." | A grant covers exactly one action or checkpoint and does not generalise ([`policies/authority-defaults.yaml`](../../policies/authority-defaults.yaml) `invariants`). Treating a prior grant as covering this one is a named forbidden substitute. | Request the grant this entry declares, or stop for explicit invocation. |

## Outputs

One `common#/$defs/operation_result` carrying `operation`, `status`, `next_permitted_action`,
and — when the status is not `complete` — a `common#/$defs/escalation` or the cap object. Plus
the artifacts the phase's own protocol emits, each under its schema in `schemas/`. Project-derived
content is published through the knowledgebase adapter's `publishArtifact`, never to a path in
the working repository (ruling `central-kb-owns-project-artifacts`;
[`adapters/knowledgebase/CONTRACT.md`](../../adapters/knowledgebase/CONTRACT.md)).

## Side effects

Exactly the entry's own `side_effects` list, and nothing beyond it. Every member of
`common#/$defs/remote_side_effect` carries its key source — `sha256(run_id · operation_id ·
target_identity · input_artifact_hash)`, where `target_identity` is the stable remote identity —
and its read-back, before and after the effect ([`adapters/runner-contract/CONTRACT.md`](../../adapters/runner-contract/CONTRACT.md) §5).

## Stop conditions

- `complete`: the operation's own scope finished. Control passes to the `next_permitted_action`.
- `needs-input`: a grant could not be validated, a precondition artifact was absent or no longer
  bound, trusted evidence was unavailable where the entry requires it, or the operation is
  undeclared. Returns the full `escalation` — need, options, tried, default, charter rule, blocked
  artifact id.
- `cap-reached`: a cap in [`policies/limits.yaml`](../../policies/limits.yaml) was reached. Returns the cap object and the
  next permitted action; it never continues under a relaxed bound.
- `failed`: the phase logic errored, or a read-back could not be performed. Returns the error.
- `cancelled`: the runner cancelled the run. The restart record is persisted regardless.

## Limits

- Caps: whatever [`policies/limits.yaml`](../../policies/limits.yaml) `enforced` names for this operation (gate). This
  protocol enforces the cap it was handed and invents none.
- Escalations per block: exactly one (gate, [`policies/authority-defaults.yaml`](../../policies/authority-defaults.yaml)
  `checkpoints.on_block`).
- Budgets: runner-supplied (gate as handed). An absent budget is recorded as absent, never
  substituted with a number.
