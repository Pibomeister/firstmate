# adapters/runner-contract — host-neutral runner contract

The local implementation is `src/runner/`; this file remains the host-neutral contract. The
implementation exposes a supervisor-owned service and a worker-facing `ak runner call` client.
Its service must run with a state directory and charter outside the worker's writable scope.

Neither coding-agent host this package targets can validate a delegated grant, attest that two seats
were independent, deliver a durable event, or carry a run across a restart
([`adapters/claude-code/CONTRACT.md`](../claude-code/CONTRACT.md) §3, [`adapters/codex/CONTRACT.md`](../codex/CONTRACT.md) §3). Every autonomous behavior
in this catalog therefore rests on a **runner**: an existing workflow runner that owns execution,
isolation, credentials, scheduling and durable state (plan §1.2).

This file is the contract that runner must satisfy. It owns six things — grant validation, seat
independence, budgets, idempotency, run state, and evidence collection outside worker-writable
scope — plus one capability folded in from arch §4.

**The fold.** Plan §4 sketched separate `issue-tracker` and `repository-events` adapter directories.
`repository-events` is folded into this contract, because it owns the `event-delivery` capability
([`schemas/common.schema.json#/$defs/capability`](../../schemas/common.schema.json#/$defs/capability)) and has no independent contract: an event is only
meaningful as an input to the run-state machine defined here. `issue-tracker` was folded here too at
first, and is now its own adapter, [`adapters/tracker/CONTRACT.md`](../tracker/CONTRACT.md): a tracker write is governed by
§5, but what a ticket operation *is*, and which system holds the ticket, is a contract of its own
that must hold across trackers (ruling `tracker-of-record-falls-back-to-kb`). This is recorded in
`catalog.yaml`'s `adapters:` header comment.

---

## 1. Division of responsibility

| The runner provides | The package provides |
|---|---|
| Agent sessions, isolation, allowed tools, process execution, credentials | Skill bodies, protocols, roles, schemas, policies |
| Grant validation against the charter | The `authority` declaration each operation is checked against |
| Seat assignment and the independence attestation | The structural constraints the assignment must satisfy |
| Budgets and resource accounting | Enforcement of the cap it was handed, and nothing else |
| Durable run state across restarts | The state machine, and the record that makes a restart safe |
| Evidence collection outside worker-writable scope | Evidence predicates and the explicit `trusted-evidence` requirement on consuming operations |
| Durable event delivery; tracker credentials | The event and ticket artifact shapes, and what may be done on receipt |

The package computes no prices, selects nothing, and schedules nothing.

### Capabilities this adapter supplies

| Capability | Unconfigured | What the refusal is |
|---|---|---|
| `runner-grants` | `fails-closed` | `delegated-grant` operations are unavailable and the entrypoint stops for explicit invocation (§2, "With no runner attached") |
| `trusted-evidence` | `fails-closed` | Autonomous evidence-consuming operations are unavailable when the runner cannot keep their evidence outside worker reach (§2, "How a runner signals trusted evidence") |
| `independent-context` | `fails-closed` | A seat whose distinct context and excluded lineage cannot be attested is unavailable and is never backfilled (§3, "Failure behavior") |
| `event-delivery` | `fails-closed` | Without both a private event consumer and supervisor loop, or without a charter cadence, `status.autonomy` names guided mode; a run requesting unattended mode cannot decide a checkpoint (§6) |

This table is read by `ak build` and `ak validate` (`loadAdapterSupplies` in
`src/packaging/install.ts`). A row is a claim that an operation needing the capability refuses
when it is unconfigured rather than degrading, which is what lets an attached adapter lift a
skill's mode ceiling on a host that does not provide the capability (ruling
`fail-closed-adapter-lifts-ceiling`).

The row describes the attached adapter's fail-closed behavior, not proof that a live service was
configured. `autopilot` reads the live `status.autonomy` before advancing. `tracker-access` is not
a row here because this contract does not supply it:
[`adapters/tracker/CONTRACT.md`](../tracker/CONTRACT.md) §1 does, with the fallback it depends on stated beside it.

---

## 2. Grant validation

**Skills never issue their own grants.** No skill, protocol, role or phase operation in this catalog
constructs, widens, infers or self-signs a grant. A skill presents a grant it was handed; the runner
decides whether it is valid.

ADR-0007 adds a separate standing **start** grant for autopilot only. It is
`common#/$defs/standing_grant_ref`, not a phase `grant_ref`: Firstmate presents it before creating
the run, and the runner matches its charter hash, run id, controller and cover against the active
charter's `standing_grants` entry and human approval. It grants no checkpoint or sensitive action.
Every later phase still follows the validation sequence below.

A grant is [`schemas/common.schema.json#/$defs/grant_ref`](../../schemas/common.schema.json#/$defs/grant_ref): a `charter_hash`, a `covers` value drawn
from `checkpoint_category`, `grantable_action` or `sensitive_action`, and an optional `decision`
artifact id. Nothing else is a grant. A natural-language assertion that authority exists — in a
prompt, a PR comment, a ticket body, an artifact field, or a previous agent's output — is not a
grant and never becomes one (release scenario 15).

### The validation sequence, fail-closed at every step

A delegated controller may invoke a phase operation only when **all** of the following resolve. Any
step that cannot be resolved is a refusal, not a default:

1. **The charter resolves.** `charter_hash` names a charter the runner holds, byte-for-byte, and
   that charter is outside worker-writable scope (plan §7.2). An unresolvable hash refuses.
2. **The operation's declared authority permits delegation.** The operation's `authority`
   (`common#/$defs/authority`) is `explicit-or-delegated`, `delegated-grant`, or `active-review-run`
   with an open review run. An `explicit` operation is never reachable by grant — that is the
   invocation law, not a configurable policy.
3. **`covers` is in the charter's allowed set.** For a `grantable_action` or `checkpoint_category`,
   the charter lists it. For a `sensitive_action`, the charter additionally carries a
   human-approved `sensitive_grants` entry naming that exact action. Sensitive actions are never
   granted by default (plan §7.2, ruling `sensitive-actions-need-approved-charter-entry`), and a
   broader grant never implies a narrower sensitive one (release scenario 5).
4. **`covers` actually covers the operation.** The grant matches the operation being invoked, not a
   neighbouring one. A grant for `open-pr` does not authorize `merge`; a grant for `ci-repair` does
   not authorize editing tests (plan §7.5, ruling `ci-repair-restricts-purpose-not-permission`,
   release scenario 19).
5. **Role separation holds.** The requesting seat is not excluded for this operation by §3.
6. **The required evidence is present.** The charter's condition for this action is satisfied by
   artifacts that exist and whose hashes match. "Fail closed when required evidence is absent" —
   never on a confidence judgement (`AGENTS.md`, "Model routing is stripped").
7. **Budgets are not exhausted.** §4.

### On refusal

The operation returns an `operation_result` (`common#/$defs/operation_result`) with
`status: needs-input` and an `escalation` (`common#/$defs/escalation`) naming the one decision
needed, the bounded options, the evidence already gathered, the recommended default, the triggering
charter rule, and the blocked ticket or finding. New writes and shipping stop; explicitly permitted
read-only work may continue within budget. Control returns to the runner. No agent polls (plan §7.4).

### With no runner attached

`delegated-grant` operations are unavailable. `explicit-or-delegated` operations install and run in
their explicit form only. A human-started public entrypoint **stops for explicit invocation**
rather than reproducing a forbidden command's effect through a side door (`AGENTS.md`, "The invocation law";
ruling `entrypoint-phase-operation-split`).
Under the opt-in unattended policy ([ADR-0014](../../docs/decisions/0014-unattended-lifecycle-policy.md)),
align, bound and ship start instead when the gate tool's `unattended check` exits 0, the human boundary
being the live protected merge: an exception, for that policy only, to ruling
`entrypoint-phase-operation-split`.
For model-started review, see [ADR-0013](../../docs/decisions/0013-model-starts-super-review.md).

### How a runner signals trusted evidence

By recording the gate evidence itself, into the run's evidence store for the opened run, where the
worker cannot write. That recording is the whole signal: evidence is trusted because of who wrote it
and where, never because a record, a grant or a host permission says so. Gate records the worker
wrote are worker-attested, and they satisfy the explicit form of an operation only.

With this contract attached and no real runner behind it, no such evidence exists, and the autonomous
form of an evidence-consuming operation stops with `status: needs-input` naming trusted evidence as
unavailable. That stop is the `fails-closed` row in §1. The explicit form is unaffected.

The one exception is the opt-in unattended policy (ADR-0014): there the worker-attested gate records
count, labelled so, and the boundary is the live merge-gate read with its residual assumptions
stated. Work outside that opt-in keeps both restrictions above.

---

## 3. Seat independence

A **seat** is a run-scoped role assignment the runner makes and attests. `roles/` supplies the
prompt for a seat; the runner supplies who fills it.

**Independence is a runner-enforced structural constraint, never a model identity.** It is never
expressed as, satisfied by, or checked against a different model, provider or family. The one scoped
exception is the forge-side independent review check under the opt-in unattended policy
([ADR-0014](../../docs/decisions/0014-unattended-lifecycle-policy.md)), whose reviewer must be a
canonical model identity different from every configured author model; the seats this contract fills
and every run outside that policy are unchanged. What the runner
must attest for two seats declared independent:

- **Distinct seat identifiers** bound to the run, recorded in the decision card.
- **No shared context.** Neither seat's input contains the other's transcript, draft, rationale or
  verdict for the same decision.
- **No shared lineage with the excluded roles**, per the exclusions below.

### Required exclusions

| Seat | May not be filled by | Source |
|---|---|---|
| Either [`supervisor`](../../roles/supervisor/ROLE.md) at a checkpoint | The [`implementer`](../../roles/implementer/ROLE.md) of the artifact under decision | plan §7.3, ruling `missing-supervisor-never-implementer` |
| The security review seat | The [`implementer`](../../roles/implementer/ROLE.md), or the seat that approved the spec | `AGENTS.md`, model-routing strip |
| Any reviewer | The author of the change under review | ruling `missing-supervisor-never-implementer` |
| A [`verifier`](../../roles/verifier/ROLE.md) | The implementer, change author, spec approver, recipe author for this change, or a seat already used on the same decision | ruling `missing-supervisor-never-implementer` |
| The second [`supervisor`](../../roles/supervisor/ROLE.md) | The first [`supervisor`](../../roles/supervisor/ROLE.md) | plan §7.3 |

The supervisor exclusion is symmetric: neither supervisor's lineage may contain the other
supervisor's actor.

Independence means independent **of the author**, not amnesiac between cycles: reviewer continuity
through a prior-review dossier is desirable and permitted (ruling `reviewer-continuity-not-amnesia`).

### Failure behavior

- A seat the runner cannot fill under these constraints makes the checkpoint **blocked**. It is not
  filled by the implementer (release scenario 17), and not filled by a seat already used elsewhere in
  the same decision.
- Supervisor disagreement, a supervisor failure, missing evidence, or an out-of-charter action blocks
  the checkpoint and produces **one** escalation — not repeated internal debate (release scenario 16).
- **No tie-breaking third supervisor.** Adding one to avoid asking the human is prohibited
  (plan §7.3). Agreement supports a decision only when the required evidence is present and the
  charter permits it; agreement alone grants nothing (ruling `supervisor-agreement-is-not-authority`).
- A reviewer failure is `unavailable`, which blocks approval. It never becomes approval
  (ruling `required-lane-failure-is-unavailable`, release scenario 4).

---

## 4. Budgets

Budgets are **passed in by the runner**. The package enforces only the cap it was handed and computes
nothing: no provider prices, no token accounting, no effort estimate.

The runner supplies, per run: stage and loop limits, elapsed-time caps, alignment-question and ticket
caps, and any host-provided resource cap it wants honored (plan §7.2). The package supplies the
structural limits that are part of the engineering contract and not negotiable by budget —
two fix cycles, three bounded CI-repair attempts ([`policies/limits.yaml`](../../policies/limits.yaml), ruling
`two-fix-cycles-then-stop`).

When a cap is reached, the operation returns `operation_result` with `status: cap-reached` and a
`cap` object naming the `limit` and its `value`. The work completed so far is reported with its
evidence. A cap is never raised from inside the run, and a cap-reached result is never retried by
the same controller without a new runner decision (release scenario 18).

Cost accounting, where the runner has it, is recorded as a receipt. It is never an input to any
decision this package makes.

---

## 5. Idempotency

Every `common#/$defs/remote_side_effect` — `remote-push`, `pr-open`, `pr-comment`,
`pr-thread-resolve`, `kb-publish`, `tracker-write` — requires an **idempotency key plus a read-back**
(plan §7.4). A restart must not repeat a commit, a push, a comment, a thread resolution, a PR
creation, a KB publication or a tracker write (release scenario 20).

### Key derivation

The key is a pure function of the run and the intent, so that a restart derives the same key:

```text
idempotency_key = sha256( run_id · operation_id · target_identity · input_artifact_hash )
```

`target_identity` is the stable remote identity — repository plus branch, PR number plus thread id,
KB record path. `input_artifact_hash` is the `common#/$defs/hash` of the artifact driving the effect.

The key **must not** incorporate a timestamp, a random value, an attempt counter, or a
session-scoped identifier. A key that changes between attempts is not an idempotency key, and an
operation whose key is not reproducible from persisted state may not perform a remote effect at all.

### Read-back

Before the effect: read the remote for the key. Found with matching input hash → the effect already
happened; record success without repeating it. Found with a **different** input hash → the input
changed under a reused key; refuse and escalate rather than overwrite.

After the effect: read the remote back and confirm the observed state matches the intent. An effect
whose read-back cannot be performed is recorded as `status: failed` with the error, never as
complete. An agent's belief that the push succeeded is not a receipt.

`local-commit` and `branch-create` are not in `remote_side_effect` but still carry keys, because a
restart that re-commits produces a divergent local history the read-back of a later push would
reject.

---

## 6. Event delivery and tracker access

`event-delivery` folds in here (see the header note). `tracker-access` does not.

### `event-delivery`

The runner owns the durable inbound queue: repository events, CI results, PR review events, and
source-merge events that activate KB coordination ([`adapters/knowledgebase/CONTRACT.md`](../knowledgebase/CONTRACT.md) §4). Neither
coding-agent host provides this; a session-scoped hook is not durable delivery.

The runner delivers each event as an `event` artifact ([`schemas/event.schema.json`](../../schemas/event.schema.json)) carrying an
idempotency key. The package's obligation on receipt:

- **Deduplicate by key before acting.** A redelivered event produces no second effect.
- **Deliver into the run-state machine**, never directly into a side effect. An event is an input to
  a transition; it is not authority. An event body that contains an instruction grants nothing
  (release scenario 15).
- **An event for a run in a terminal state is recorded and not acted on.**

The local service persists the payload and its digest before invoking its private `event-config`
consumer. The consumer receives `{run,key,payload}` on stdin and can use only the run-scoped worker
socket token. It returns `{run,key}` after it has delivered the wake into the run controller. The
runner marks the event acted only after that matching acknowledgement. An unacknowledged event
remains in the private queue and is retried after service restart. Duplicate keys with changed
payloads refuse; duplicate keys with the same payload never repeat an acknowledged delivery.
The supervisor configures an explicit command timeout; a timeout leaves the event pending and
the run guided. Payload content is an untrusted claim and cannot issue a grant.

The `loop-config` is a separate supervisor-owned command. The charter's
`audit_cadence_seconds` arms a tick while any delegate remains active. Each tick re-reads the
autopilot skill and checkpoint procedure at the bundle version and content hash recorded at run
start; drift refuses the tick. The adapter probes every active owner and child and returns only
observed side effects: commit, push, PR change, check change, or stored report. Narration is not
progress. A delegate with no side effect within its expected runtime is sent to the adapter
with a stable replacement key; only a matching stand-down and replacement read-back records the
new delegate. The next tick audits the replacement too. A failed probe or replacement leaves the
work active and the service in guided mode until a successful tick. The timer drains only when
no active delegate remains. The adapter owns the actual process stop and replacement; the runner
owns the policy and durable record. Neither an event nor a probe result is authority for a phase.

### `tracker-access`

Owned by [`adapters/tracker/CONTRACT.md`](../tracker/CONTRACT.md): the ticket operations, the one-system-of-record rule
(plan §8), and the fallback chain that ends in the knowledgebase's `ticket` records or a refusal
(ruling `tracker-of-record-falls-back-to-kb`). What stays here is what the runner always supplied:
the operator's tracker credentials, exclusive access where a claim needs it, and §5, which every
tracker write obeys in full.

---

## 7. Run state

The host-neutral machine is `common#/$defs/run_state` (plan §7.4):

```text
created → grounding → alignment → planning → building → verifying → reviewing → repairing
        → ready-to-ship → pr-open → complete
```

Bugs route through diagnosis and may enter at an appropriate intermediate state; `repairing` returns
to `verifying`, and a delta review returns to `reviewing`. From **any** state the run may reach one
of the four non-complete results: `needs-input`, `cap-reached`, `failed`, `cancelled`.

Every transition validates, in this order, and refuses on the first failure:

1. **Prerequisites** — the artifacts the next state consumes exist.
2. **Evidence freshness** — every receipt is bound to the current revision. A code change invalidates
   older green verification evidence (release scenario 10); a changed artifact does not inherit the
   previous artifact's approval (plan §5.2).
3. **Authority** — §2, for anything delegated.
4. **Budgets** — §4.

An evidence-consuming autonomous operation adds the trusted-evidence refusal in §2 ("How a runner
signals trusted evidence") before it runs. The four checks above do not treat worker-attested gate
records as that signal.

### The restart record

The runner persists, per run, and the package requires to be handed back on resume:

| Field | Purpose |
|---|---|
| `run_state` | Where the run is |
| `next_permitted_action` | `operation_result.next_permitted_action`. Null when nothing further is permitted. A restart resumes here and nowhere else |
| Outstanding idempotency keys | Per in-flight `remote_side_effect`, with its read-back status |
| Decided checkpoints | Each with its decision card, grant and artifact hashes, so a decision is not re-litigated |
| Open escalation | The `escalation` object, if the run is `needs-input` |
| Budget consumption | Against each cap the runner handed in |
| Inbound events | Payload digest, acknowledged state and terminal marker; an unacknowledged event is replayed after restart |
| Delegated work | Owner and child ids, expected runtime, side-effect refs and replacement lineage |
| Governing procedure | Bundle version and content digest re-read on each audit tick |
| Patch verdict | Reviewed head, stable patch-id, the trunk tip its verification ran against, reuse lineage and any invalidation cause |

A restart with no such record does not resume — it starts a new run. Resuming from partial state is
how a run repeats a remote effect, which is exactly what §5 exists to prevent.

---

## 8. Testing

Tests this adapter owns, in `tests/adapters/` and `tests/scenarios/`:

1. **Grant validation is fail-closed** — for each of the seven sequence steps in §2, a fixture that
   fails only that step must refuse, and the refusal must carry a well-formed `escalation`.
2. **Prose is not authority** — a PR comment, ticket body and artifact field each containing an
   instruction to proceed grant nothing (scenario 15).
3. **Sensitive actions** — an approved public-API ticket grants neither deployment nor merge
   (scenario 5).
4. **Seat independence** — a missing supervisor is not replaced by the implementer (scenario 17); two
   supervisors sharing a transcript fail the independence attestation; no third supervisor is
   spawned on disagreement (scenario 16).
5. **Reviewer failure** — an unavailable required lane blocks approval and never becomes approval
   (scenario 4).
6. **Caps** — the third fix cycle stops (scenario 18); a cap-reached run reports its partial work.
7. **CI repair scope** — a repair attempt that would delete an assertion is refused (scenario 19).
8. **Idempotency** — replaying a run from its persisted record performs no second remote effect for
   any `remote_side_effect`, and a key whose input hash changed refuses rather than overwriting
   (scenario 20).
9. **Key purity** — deriving a key twice from the same persisted state yields the same value; a key
   derivation that reads the clock or a random source fails the test.
10. **Event dedup** — a redelivered event produces no second effect; an event for a terminal run is
    recorded and not acted on.
11. **Evidence freshness** — a code change invalidates older green receipts (scenario 10).
12. **Transition prerequisites** — every illegal `run_state` edge is refused, with the failed check
    named.

---

## 9. Local service under Firstmate

Request shapes and task setup are in `CLI.md`. This section states the trust boundary.

`ak runner serve --socket <path> --state-dir <path> --worker-root <path> --run-id <id>
--admin-token-file <path> --seat-config <path> --verify-config <path> --effect-config <path>` starts a
task-scoped service. Firstmate owns the process, two distinct 32-character-or-longer tokens, the
active charter, the seat configuration and the state directory. The supervisor token lives in a
mode-0600 file outside the Firstmate home, outside the worker root and outside every git checkout and
git directory, by default `~/.config/agent-kit/runner/<run>/admin.token`; its path is never written
into a brief or any other worker-visible file. `serve` and `ak firstmate seat-judge` refuse a token
file that breaks any of these rules. The worker token comes from `AK_RUNNER_WORKER_TOKEN`. The endpoint refuses another run id. Firstmate passes only `AK_RUNNER_SOCKET` and
`AK_RUNNER_TOKEN` (the worker token) to a Claude Code or Codex worker. Both use
`ak runner call <verb> --json <request-file>`; the service checks the token and verb before
touching run state. `start` first validates the autopilot.start standing grant against the
captain-approved charter (ADR-0007) and records `start_authority` before any seat dispatch.
`start`, `collect`, `revision`, `judge`, `answer`, `cancel`, `verify`, `charge`, `effect`, `event` and
`complete` require the supervisor token. A worker can read `status` and `ledger`, freeze a `prepare`
card and ask `decide` to apply the next validated grant. `sync` observes the worker's current Git
revision and diff; `run-verify` executes only the supervisor-configured command and stores its
output privately.

The runner's Git snapshot hashes raw worktree bytes, symlink targets, executable bits and index
entries instead of trusting a Git text diff. At service start it pins an absolute Git executable
outside the worker root; nested repositories use the same executable and a runner-private Git home.
Its Git calls disable fsmonitor, hooks and the global excludes file, run with a filtered `PATH`,
have a ten-second timeout with a kill signal, and do not invoke textconv or attribute clean filters.
A nonregular Git index or HEAD refuses the snapshot. A tracked edit in an inspected repository
therefore changes the runner's `diff_hash` even when worker Git config claims the tree is clean.
An attached submodule or embedded repository with a `.git` entry is hashed recursively the same
way, together with its `HEAD` (or `unborn`),
and an entry the runner cannot read, such as a nested repository whose Git fails or a socket,
refuses the snapshot instead of being skipped. Git's untracked-file selection still applies:
`.git/info/exclude` can hide a top-level untracked file, nested repository ignores can hide nested
edits, and a gitlink with no `.git` entry is not traversed. The raw fingerprint also omits
**untracked** `.omc/` and `.omx/` harness scratch; tracked files in those paths count.
Recursively hashing raw bytes costs I/O proportional to the selected files, including attached
nested repositories. Standalone lifecycle snapshots retain
their original Git-diff behavior. This change in runner fingerprint format makes evidence from an
older runner binary stale on upgrade: sync, recollect and verify it before proceeding.

At `decide`, the service checks the charter, grant, current state, evidence and cap before invoking
the two configured launchers. It sends each launcher the same frozen question, option ids and
evidence hashes, operation and approving option on stdin, without either judgment. The service runs
seat launchers from its private state directory, with runner tokens, runtime preloads and worker-root
`PATH` entries removed from their environment. Under stock Firstmate, the launchers dispatch
separate ordinary crewmates through its normal brief/spawn path; the implementing worker never
spawns them. Each launcher returns a JSON object containing
`choice` and `rationale`. The service strips runner tokens from the launched environment, records
distinct actors, dispatch ids and lineages, and refuses a missing or ineligible seat. A launcher that
exits non-zero, prints unparseable output, or returns an invalid answer or a choice outside the card's
options refuses the card: the run goes to `needs-input` with a `runner:seat-independence` escalation
that carries each launcher's error, and the seat is not relaunched. Without a seat configuration the
supervisor may submit separate judgments with `judge`, and a missing judgment blocks the card.

When the charter carries `council.blind_veto: required` (ADR-0015), an approval the pair agrees on
stands only after a blind veto seat also approves it. After the pair agrees on the approving option
and before `decide` accepts it, the service runs the outbound gate on the same frozen packet and
sends it to the veto seat named in the private `--council-config`. No judgment is in that input.
The service tries the seat's substitutes in order, only when a launcher fails or returns no valid
answer, and records the result on the card apart from the two judgments. A missing configuration,
an exhausted chain, a refused payload, a veto that shares a lineage with either primary seat or an
excluded actor, or a non-approving veto returns `needs-input` with a `runner:council-veto`
escalation. The veto is not a third seat or a third judgment, and it never approves alone.

Every card names its approving option in `approve`, one of its `options`; `prepare` refuses a card
without it and refuses `no` or `retry` as approving options. The runner adds `no` as a refusal to
every human escalation even if the worker omitted it, and recommends it as the default. Only the
card's non-reserved approving choice advances the run, whether two seats agree on it or a human
answers with it. Any other choice (no, revise, hold, reject) is recorded as the ruling, leaves the run at the same
stage with that operation as its next permitted action, issues no grant and authorizes no effect: a
non-approving `ship.prepare` never unlocks `pr-open` or a push. The way forward is a revised card that
an approving decision then settles. The packet and escalation name both the operation and its
approving option, so a seat or human can see which choice would advance. An identical artifact after
a non-approving seat ruling is not re-dispatched; a revised artifact may return to the seats.

`answer` settles the escalated card with the human's or supervisor's ruling: the `card_id`, a
`choice` from the card's options or the runner's `no`, the `actor` who ruled and a `rationale`. An excluded actor cannot
answer. The card becomes decided with that choice, so `decide` replays the ruling and no seat is
relaunched, and the run moves exactly as an agreeing pair of seats with that choice would move it.
The ledger entry is marked answered and carries the choice, actor, rationale and time; the card's
decision artifact keeps the refusal, because a `decided` artifact needs two seat judgments. A
resubmitted card cannot override the ruling: `prepare` refuses the same operation and artifact at
the same revision and diff. After a human non-approving answer, even a revised artifact or changed
worker revision remains human-gated for that operation until a human approves; `decide` escalates
before launching seats. A `retry` option, when the card lists one, reopens the checkpoint but is
itself non-approving, so the next card still needs a human. A supervisor `cancel` with actor and
rationale moves any run state, including `needs-input` or `cap-reached`, to the durable `cancelled`
stop. Cancellation does not undo confirmed remote effects.
`decide` rejects a card that is not the next permitted action with an error and leaves the run as it
was, so no escalation is ever opened for a checkpoint the run has not reached and every escalation's
options are exactly the choices `answer` accepts. An approving answer is held to the same elapsed and
budget caps as `decide`: at a cap the run goes to `cap-reached` instead of advancing. A
`cap-reached` run is not answerable, because raising a cap needs a new human-approved charter.
`cancel` refuses a completed run and records actor, rationale and time in the run ledger. A
performed remote effect that was pending read-back when cancellation occurred remains unconfirmed;
cancellation does not reconcile or undo it. Firstmate must inspect the remote system separately.

The service checks the active charter schema, recomputes its canonical hash, verifies its human
approval and refuses any changed charter on resume. `collect` snapshots only files outside the
worker root into the private file store in `src/runner/evidence.ts`, and every consumer re-reads and
re-hashes the stored bytes. A KB-backed store is a follow-up. `verify` and autonomous ship consume the runner-owned snapshot at the current
revision. The service writes a decision artifact per checkpoint and a schema-checked run ledger
beside the restart record. A restart reads the next permitted action and returns prior decisions
without redispatching them. `effect` resolves its read-back and perform command arrays only from a
supervisor-owned service configuration, never from a request file: it reads before and after,
persists its deterministic key before performing the effect, and never reports completion without
matching read-back. Both commands run from the private state directory with the same sanitized
environment as the seat launchers. A remote effect requires the most recent ship decision to approve
the current snapshot; an older approval cannot outvote a later refusal. The worker cannot supply
these commands, even through an admin call that reads
a worker-authored request file. Repository effects also refuse a target outside the charter's
repository list. `ship.prepare` leaves the run `ready-to-ship`; only a confirmed PR-open read-back
transitions it to `pr-open`. A changed head requires a new verification and review before completion.

The path checks reject a state, socket, charter, seat configuration or source gate record that
resolves inside the worker root. The state check also rejects Git's common directory for a linked
worktree, including the primary checkout's shared `.git/agent-kit/evidence` path. These checks
and the token-file rules guard against accidental exposure; they are not isolation. On a same-user
install a deliberately adversarial worker can still read the token file, the state directory and the
evidence store, because nothing here changes operating-system permissions. A charter that omits
`runner-grants` or `trusted-evidence` cannot gain either merely because a service was started; a new
human-approved charter is needed.

`run-verify` is the deliberate exception to the private child directory: it runs the worker's own
verification command from the worker root and strips runner tokens. The verifier therefore executes
worker-controlled code under the service's OS identity; an adversarial deployment must isolate that
identity from supervisor credentials and private files outside the process environment too.
