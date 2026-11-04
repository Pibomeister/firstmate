# adapters/tracker — host contract

Contract only. No implementation lives here.

Tickets have one **system of record**. Where a project has a tracker, that tracker is it; where it
does not, the knowledgebase's `ticket` records are (plan §8; ruling
`tracker-of-record-falls-back-to-kb`). This file defines the narrow interface every skill uses to
reach whichever one it is: six operations, the rule that maps each onto a backend, the chain that
decides which system is the record, and how a project folder binds the backend it reaches (§5).

The interface is **backend-agnostic**. Linear, Jira and GitHub Issues are examples of backends; the
package names no vendor in any rule, keeps no list of them, and claims nothing about what any of
them supports. What a given backend can do natively is the binding's to know and to state, and a
binding that cannot state it uses the body convention in §3.

---

## 0. Where this adapter came from

Plan §4 sketched an `issue-tracker` adapter directory, and the first cut of this package folded it
into [`adapters/runner-contract/CONTRACT.md`](../runner-contract/CONTRACT.md) on the grounds that a tracker write was only meaningful
as a runner-governed side effect. That left the ticket operations nowhere: the runner contract said
who supplies credentials and how a write is keyed, and no contract said what a ticket operation is.
This contract says it. The runner contract keeps what it always owned — credentials, idempotency,
exclusive access — and points here for the rest.

---

## 1. Capabilities and side effects

This adapter supplies `tracker-access` (`common#/$defs/capability`). Neither coding-agent host
provides it ([`adapters/claude-code/CONTRACT.md`](../claude-code/CONTRACT.md) §3, [`adapters/codex/CONTRACT.md`](../codex/CONTRACT.md) §3).

Side effects (`common#/$defs/side_effect`): `tracker-write`, a `common#/$defs/remote_side_effect`.
Every write in §4 carries an idempotency key and a read-back per
[`adapters/runner-contract/CONTRACT.md`](../runner-contract/CONTRACT.md) §5, which this contract does not restate. The key's
`target_identity` is the ticket's stable id in whichever system of record holds it.

Credentials are always the operator's. The runner or the host environment supplies them; the
package, the install file and the ticket artifact never carry one.

### Capabilities this adapter supplies

| Capability | Unconfigured | Falls back on | What the refusal is |
|---|---|---|---|
| `tracker-access` | `fails-closed` | `kb-write` | With no backend configured, the knowledgebase's `ticket` records carry every operation; with no knowledgebase either, `kb-write`'s refusal. Never a scratch file in the working repository (release scenario 21) |

This table is read by `ak build` and `ak validate` (`loadAdapterSupplies` in
`src/packaging/install.ts`), like the knowledgebase's and the runner's. `fails-closed` is honest
here only because of the third column, which is why the column exists. With no backend, this
adapter has no refusal of its own: its operations are carried by the knowledgebase, so they fail
closed exactly when `kb-write` does. The row therefore lifts a skill's mode ceiling (ruling
`fail-closed-adapter-lifts-ceiling`) only where what it falls back on is itself available — the
host provides `kb-write`, or an attached adapter supplies it. Three outcomes follow:

| Install | `tracker-access` |
|---|---|
| `tracker` attached, a backend configured | Lifted, whether or not the knowledgebase is attached. The backend is the system of record and nothing is borrowed |
| `tracker` attached, no backend, `knowledgebase` attached | Lifted through the fallback |
| `tracker` attached, no backend, `knowledgebase` not attached | Capped at `guided`, with a note naming both fixes |

Without the column, the third install would lift `tracker-access` on a refusal belonging to an
adapter that install chose to leave out, and route around its own decision to cap `kb-write`.

Which backend an install has is stated in `ak.install.yaml` ([`schemas/install.schema.json`](../../schemas/install.schema.json)):

```yaml
attached: [runner-contract, knowledgebase, tracker]
tracker:
  backend: <kebab-case id>
```

The id is free-form. It names a binding (§5), and the package checks only its shape. With no
`tracker:` key there is no backend, and with no install file at all this adapter is attached with
no backend, which is the fallback.

This key is a **packaging** statement: it says the install runs against a backend, which is what
lifts the ceiling. It does not reach anything. Which backend a given checkout reaches is that
project folder's binding (§5), read when an operation runs, and an operation in a folder with no
binding follows §2 whatever this key says — so a lifted ceiling over an unbound folder still ends
in a knowledgebase record or a refusal, never in an unconfigured write.

---

## 2. The system of record

**One ticket system is the system of record; any other representation is projected onto it, never
maintained as a second independent status** (plan §8).

Two inputs decide which system that is, and they answer different questions. The project record's
`tracker_policy.system_of_record` ([`schemas/project.schema.json`](../../schemas/project.schema.json)) is the **policy**: which system
the tickets live in. The project folder's binding (§5) is the **wiring**: how this checkout reaches
that system. The binding never names the system of record; its backend's document states which
system the binding reaches, and that is compared with the record's
`tracker_policy.system_of_record.system` **as an exact id**: both are kebab-case ids, compared
byte for byte, with no case folding and no aliases, so `linear` and `Linear` are different systems
and the second refuses. `knowledgebase` is a reserved id naming the knowledgebase's own `ticket`
records; no backend document may state it as the system it reaches.

1. **The folder binds a backend.** The system it reaches is the system of record, provided the
   project record, where there is one, names that same system. A record naming another system —
   the knowledgebase included — refuses every operation: obeying the binding would make a second
   system of record. Where they agree, the package's `ticket` artifact, if one is also published to
   the knowledgebase, is a projection carrying a link to the authoritative record
   (`common#/$defs/envelope.tracker`: system, id, url), and a status read from it is read from the
   backend.
2. **No binding, and the record names no external system.** The knowledgebase's `ticket` records
   are the system of record: the record names `knowledgebase`, or there is no project record to
   name anything. Each operation in §4 is carried by the knowledgebase adapter: writes by
   `publishArtifact` under a `run-artifact` placement, reads by `readContext`
   ([`adapters/knowledgebase/CONTRACT.md`](../knowledgebase/CONTRACT.md) §2).
3. **Otherwise every operation refuses.** No binding while the record names an external system is a
   checkout that cannot reach its system of record, and the knowledgebase does not stand in for it.
   No binding and no knowledgebase refuses because `kb-write` refuses
   ([`adapters/knowledgebase/CONTRACT.md`](../knowledgebase/CONTRACT.md) §1). A skill that needs a system of record reports
   `needs-input`, as `skills/wayfind/SKILL.md` does.

It never ends anywhere else. No step writes a scratch file, a `tickets/` directory or any other
record into the working repository (release scenario 21; ruling
`central-kb-owns-project-artifacts`).

**The chain is decided by configuration, not by reachability.** A bound backend that is unreachable
returns `failed`, and one that rejects the project's credential refuses (§5); neither drops to
step 2. A knowledgebase record written because the tracker was down would be a second system of
record holding a status the tracker never saw, which is the exact failure plan §8 forbids.

The record itself holds one system of record and only projections beside it (validator rule
`project.single-tracker-system-of-record`); this chain is what keeps a checkout from adding a
second one outside the record.

---

## 3. Native feature first, body convention otherwise

Each operation in §4 uses the backend's native feature for what it records where the backend has
one, so the record renders in the backend's own views and the backend's own automation sees it. A
backend with no native feature for an operation records it through the **body convention**: a
labelled section in the ticket body, written and read only through this adapter, stating the
relation or state in the `ticket` schema's own terms. This generalizes `skills/wayfind/SKILL.md`,
"Limits", from blocking edges to every operation.

Three rules keep the convention from becoming a second system:

- **It is the backend's record, not a copy beside one.** A relation held by the convention is not
  also held natively, and a native one is not mirrored into the body.
- **The binding decides, once per operation.** Whether a backend has the native feature is stated
  by the binding, not probed per call; a binding that cannot say uses the convention.
- **The knowledgebase fallback needs no convention.** There the `ticket` artifact's own fields —
  `status`, `prerequisites`, and the envelope's links — are the native feature.

---

## 4. The six operations

Signatures are sketches in the knowledgebase contract's neutral notation. `TicketRef` is an opaque
handle issued by the system of record. `Result<T>` is either `T` or a structured failure carrying
`common#/$defs/operation_status`. Every operation here is one a skill in this catalog performs;
the step each comes from is named.

### `createTicket`

```text
createTicket(ticket: TicketArtifact) -> Result<TicketRef>
```

- **Called by** `wayfind`, charting step 5, first pass.
- **Carries** [`schemas/ticket.schema.json`](../../schemas/ticket.schema.json). The ref returned carries the system of record's id and
  URL, which is what a projection stores in `envelope.tracker`.
- **Failure modes** — an artifact failing its own schema is refused before any write.
- **Side effects** — `tracker-write`.

### `linkRecord`

```text
linkRecord(ticket: TicketRef, target: RecordLink) -> Result<TicketRef>
```

- **Called by** `wayfind`, steps 6 and 10, linking a research finding or a prototype artifact from
  its ticket; and wherever a projection is written, linking it to the authoritative record.
- **Native** — the backend's link or attachment relation. **Convention** — a links section.
- **Failure modes** — a target that does not resolve is refused rather than stored as a dangling
  link.
- **Side effects** — `tracker-write`.

### `addBlockingEdge`

```text
addBlockingEdge(blocked: TicketRef, blocker: TicketRef) -> Result<TicketRef>
```

- **Called by** `wayfind`, step 5, second pass: a ticket needs an identity before another can
  reference it, so edges are wired after every ticket exists.
- **Native** — the backend's dependency relation. **Convention** — a blocked-by section. In the
  knowledgebase fallback, a `prerequisites` entry of `kind: ticket`.
- **Failure modes** — an edge naming a ticket in another system of record is refused.
- **Side effects** — `tracker-write`.

### `claimTicket`

```text
claimTicket(ticket: TicketRef, claimant: SeatRef) -> Result<TicketRef>
```

- **Called by** `wayfind`, step 9, before any work on the ticket.
- **Native** — the backend's assignment. **Knowledgebase fallback** — exclusive access requested
  from the runner, because the knowledgebase implements no locking
  ([`adapters/knowledgebase/CONTRACT.md`](../knowledgebase/CONTRACT.md) §5), and the claim then recorded on the ticket.
- **Failure modes** — a ticket already claimed by another claimant is refused, not reassigned.
- **Atomicity** — none from this contract. A native assignment is as atomic as the backend makes
  it; exclusive access is the runner's to grant, as it serializes knowledgebase writes
  ([`adapters/knowledgebase/CONTRACT.md`](../knowledgebase/CONTRACT.md) §5).
- **Side effects** — `tracker-write`.

### `updateStatus`

```text
updateStatus(ticket: TicketRef, status: TicketStatus, resolution?: Text) -> Result<TicketRef>
```

- **Called by** `wayfind`, steps 11 and 12: record the resolution and close, or close a ticket
  ruled out of scope with its reason.
- **Carries** the `ticket` schema's status vocabulary. **Native** — the backend's workflow state,
  mapped by the binding. **Convention** — a status section, for a backend whose states cannot hold
  the schema's.
- **Failure modes** — a transition the backend's workflow refuses is reported with the refusal,
  never forced.
- **Side effects** — `tracker-write`.

### `readTickets`

```text
readTickets(selector: TicketSelector) -> Result<TicketSummary[]>
```

- **Called by** `wayfind`, steps 8 and 9: load the map at low resolution and choose an open,
  unblocked, unclaimed ticket.
- **Outputs** — each ticket's ref, status, claimant and blocking edges, not its body, with the
  system of record's revision so a caller can bind what it chose to what it read.
- **Failure modes** — unreachable → `failed`. Nothing matching is an empty result, which is a fact
  and not an error.
- **Side effects** — none.

---

## 5. Backend bindings: how a project folder reaches its backend

A binding is scoped to **one project folder**. Two folders on one machine can bind two workspaces of
the same backend, and nothing one folder holds may reach the other's (ruling
`tracker-of-record-falls-back-to-kb`). The package supplies no credential and runs no backend; a
binding is the operator's wiring, which is what plan §1.2 permits a working repository to carry.

### The binding file

`ak.tracker.yaml` at the root of the project folder, shaped by [`schemas/tracker-binding.schema.json`](../../schemas/tracker-binding.schema.json)
and then by the backend's own `schemas/tracker-backends/<backend>.schema.json` where it has one. The
**project folder** is the nearest directory at or above the working directory that holds
`ak.tracker.yaml`, searching no higher than the repository's top level; with none there, the folder
is unbound (§2). A `backend` with no document under `adapters/tracker/backends/` is refused, since
nothing states how to reach it.

```yaml
backend: <binding id>          # names a document under adapters/tracker/backends/
token_file: <path>             # the project-local secret; gitignored, never committed
defaults: { <key>: <value> }   # the scope createTicket and readTickets pass (rule 5); keys are the binding's
statuses: { <ticket status>: <backend status name> }   # optional
```

**The binding file is committed and holds no secret; the secret is a separate gitignored file.**
The backend, its scope and the status names are facts every checkout of the project needs and must
agree on — two operators writing to two teams is the failure a binding exists to prevent — so they
travel with the repository where a gitignored binding would let each checkout bind differently with
nothing to compare against. The credential is the one per-operator fact, so it is the one thing
kept out. The root object and `statuses` refuse unknown keys, so a token pasted under a new
top-level or status key is a schema error. `defaults` is open in the generic schema, any key with a
nonempty string value; only a backend schema restricts its keys (`linear-linearis` allows `team`
and `project`). No schema inspects values, so a token pasted as a value under `defaults` or
`statuses` is not detected.

### What every binding obeys

1. **The tool is project-local.** Whatever the binding invokes is installed into the project's own
   dependency tree with the project's own package manager, pinned, and invoked by its path there.
   Never a global install, and never a same-named tool found on `PATH`.
2. **The credential is project-local.** It is read from `token_file` for each call and handed to
   the tool through the call's environment, as a prefix assignment on the call. Never on a command
   line, including `env`'s, where the process list shows it to every user of the machine.
3. **No fallback to a global credential.** If `token_file` is absent or blank, the operation refuses
   *before* the tool is invoked. A tool that searches the operator's home directory for a
   credential when none is passed would otherwise write with whichever workspace that one reaches
   — a silent cross-project write. Blank counts as absent because a tool may treat an empty value
   as none and go searching. Where the tool reads a global store from the home directory, the call
   also points the home directory at an empty one, so the fallback is unreachable rather than
   merely unused.
4. **A rejected credential is a refusal.** An authentication failure reports `needs-input` naming
   the operator's fix. It is not retried, and it never falls through to §2 step 2.
5. **The defaults scope creation and listing.** `createTicket` and `readTickets` pass the binding's
   `defaults` explicitly rather than relying on whatever the credential's account defaults to. An
   operation on an existing ticket — `linkRecord`, `addBlockingEdge`, `claimTicket`,
   `updateStatus` — **never** passes them: a scope given to an update is a change, not a filter,
   and would move the ticket to that scope. `updateStatus` refuses a status `statuses` does not map
   rather than guessing a name the backend's workflow may lack.
6. **Credentials are the operator's.** Nothing in this package stores, prints or echoes one, and
   nothing token-bearing is committed. `ak tracker check [<project-dir>]` verifies the last half:
   the binding's shape and backend, and that `token_file` is non-blank, inside the folder, ignored
   by a `.gitignore` there (a later `!` rule that un-ignores it does not count) whose rule is
   committed at `HEAD` (a rule only in the working tree or only staged does not count), untracked and
   absent from every commit reachable from a ref. It fails when the file's mode grants any access
   beyond its owner (`chmod 600` repairs it) and warns when the history scan did not finish. It reports only the secret's path and size, never its
   contents. It does not read the project record, which lives in the knowledgebase, so the
   record-and-binding comparison of §2 step 1 is the operation's to make, not this check's.

### Setup is an instruction, not a skill

A binding is created when a human asks for one, by the agent following the setup steps in the
backend's document. It is not a new entrypoint: it runs once per checkout, needs the human for the
one step that matters — supplying the secret, which the agent never sees echoed — and starts no
phase, so it is an operator task the invocation law has no reason to govern.

### Bindings

| Binding id | Reaches system | Document |
|---|---|---|
| `linear-linearis` | `linear` | [`adapters/tracker/backends/linear-linearis.md`](./backends/linear-linearis.md) |

A binding is additive: a document under `backends/`, a row here and, where it constrains
`defaults`, a schema at `schemas/tracker-backends/<id>.schema.json`. The generic binding schema
names no vendor, and nothing in §1–§4 names or depends on any binding.

---

## 6. Known limitation

The claim race stays open. `claimTicket` narrows the window between two sessions reading the same
frontier; closing it needs an atomic claim this interface cannot promise across backends. It is
recorded rather than patched with a lock in a skill body, as the knowledgebase contract records its
own (§5 there).

---

## 7. Testing

Tests this adapter owns. Items marked **contract test, not yet written** state a behavior this
contract requires and nothing in the repository exercises yet: they are obligations on an
implementation, not claims that one was tested. Items 7 and 10 exist.

1. **The chain ends in a record or a refusal** *(contract test, not yet written)* — with no backend and no knowledgebase, every
   operation refuses and no repository file is created (scenario 21; ruling
   `tracker-of-record-falls-back-to-kb`).
2. **Configuration, not reachability** *(contract test, not yet written)* — an unreachable configured backend returns `failed` and
   writes nothing to the knowledgebase.
3. **One system of record** *(contract test, not yet written)* — a projection's status is never read as authoritative while a backend
   is configured, and a backend other than the project record's refuses writes.
4. **Native or convention, not both** *(contract test, not yet written)* — a relation recorded natively is absent from the body, and
   one recorded by convention is absent from the native relation.
5. **Write idempotency** *(contract test, not yet written)* — replaying each write after a simulated restart performs no second remote
   effect, and a changed input under a reused key refuses (runner §5; scenario 20).
6. **Claim refusal** *(contract test, not yet written)* — claiming a ticket another claimant holds is refused, not reassigned.
7. **The ceiling follows the chain** — `tests/packaging.test.ts` builds the three installs of §1 and
   asserts lifted, lifted and capped.
8. **Record and binding agree or refuse** *(contract test, not yet written)* — a folder binding a backend whose system differs from the
   project record's refuses every operation, and so does an unbound folder whose record names an
   external system.
9. **No global credential** *(contract test, not yet written)* — with `token_file` absent or blank, the operation refuses and the
   tool is never invoked.
10. **The secret stays out of git** — `tests/tracker-binding.test.ts` builds fixture repositories
    and asserts `ak tracker check` flags a secret that is tracked, not ignored (including un-ignored
    by a `!` rule), in history, blank or absent, and never prints its contents (§5). Item 9's
    tool-side half is verified offline for `linear-linearis` in that binding's document, §3.
