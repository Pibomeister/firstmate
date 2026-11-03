# adapters/knowledgebase — host contract

The contract, plus the documents of the backends that meet it (§7). The code that carries the
operations is `src/kb/`.

Project-derived material — context, standards, decisions, requirements, plans, ticket artifacts, trail and trail-audit records,
review ledgers, solutions and lessons — is owned by a **central knowledgebase**, not by the
application repository and not by this package (plan §1.2, §8; ruling
`central-kb-owns-project-artifacts`). This file defines the narrow
interface every skill uses to reach it: seven operations, their guarantees, their failure modes, and
the two release scenarios they exist to satisfy.

---

## 0. The vocabulary, and where it is defined

The authority is `docs/decisions/0001-kb-document-vocabulary.md` (**ADR-0001**, Accepted
2026-09-19). This contract is written against it and restates only what an implementer of these
operations needs; the ADR governs where the two disagree.

### Two artifact classes, one adapter

ADR-0001 §2. The distinction is load-bearing and decides which operation a skill calls.

| | **KB documents** | **Run artifacts** |
|---|---|---|
| What | Curated, human-readable, long-lived pages | Revision-bound, schema-validated operational records |
| Vocabulary | The nine `KBDocumentType` kinds below | `common#/$defs/schema_id` |
| Validated by | The KB's own templates and review | `schemas/*.schema.json` plus the plan §5.2 envelope (`common#/$defs/envelope`) |
| Reviewed | By a human | Not prose; proof |
| Stored | As KB pages | In the KB's run-scoped storage, **linked from** pages, never rendered as curated prose |

A `gotcha` says *why* something is true and a human reviews it. A verification receipt says *what
happened at a revision* and is proof. Neither converts into the other.

### `KBDocumentType` — the nine kinds

```text
adr · concept · foundation · gotcha · pattern · prd · process · sop · system
```

These are the kinds the KB implementation already has. **agent-kit adds no tenth kind** — inventing
one would fork a working tool's vocabulary for no behavioral gain, and `ak validate` rejects a kind
outside this set.

Two consequences a writer gets wrong if left implicit:

- **A skill does not choose a kind freely.** ADR-0001 §3 is a per-skill emission table fixing which
  kind and which run artifact each skill may write. A skill absent from that table writes nothing
  durable. The table is the authority; this contract does not copy it.
- **A skill does not compute a KB path.** ADR-0001 §7: placement is by **scope**, resolved against
  the KB's component model most-specific-match-first. A skill passes a scope through the adapter.
  Directory names stay configurable (plan §8); central ownership does not.

### The application-local paths do not survive

ADR-0001 §1 replaces the design brief's repository-local targets with central equivalents: the
glossary and `concept`/`system` pages replace the app-local context file, `gotcha` and `pattern`
replace the app-local solutions tree, and `adr` (created `proposed`) replaces app-local decision
records. `ak validate` scans skill bodies for the retired write targets (`src/denylist.ts`,
`LOCAL_DOC_TARGET_TERMS`).

### Substitutability

agent-kit does not depend on one KB implementation. The adapter is the boundary: any KB satisfying
the seven operations in §2 and supporting the nine kinds is substitutable.

---

## 1. Capabilities and side effects

This adapter supplies `kb-read` and `kb-write` (`common#/$defs/capability`). Neither coding-agent
host provides them ([`adapters/claude-code/CONTRACT.md`](../claude-code/CONTRACT.md) §3, [`adapters/codex/CONTRACT.md`](../codex/CONTRACT.md) §3); the host
supplies transport only.

Side effects (`common#/$defs/side_effect`): `kb-draft` and `kb-publish`. `kb-publish` is a
`common#/$defs/remote_side_effect`, so every publishing operation carries an idempotency key and a
read-back per [`adapters/runner-contract/CONTRACT.md`](../runner-contract/CONTRACT.md) §5.

With no KB configured, `kb-read` operations return an explicit **unavailable** result and `kb-write`
operations refuse. They never fall back to writing the working repository — that failure is release
scenario 21, and it is the single most common way a donor's behavior survives where it should not.

**Configured** means two things, both stated in §7: the project folder commits a binding,
`ak.kb.yaml`, and the machine has registered where that knowledgebase is checked out. Either one
missing is the unconfigured case, and the result says which and names the step that supplies it.
`ak.install.yaml` is neither: it decides which adapters an install *attaches*, which sets packaged
mode ceilings (the table below), and it never makes a knowledgebase reachable. A checkout with no
`ak.install.yaml` is the default install, not a broken one.

A knowledgebase that is configured and cannot be used — a binding that does not parse, a registered
checkout that is gone — is `failed`, not unavailable, and a run stops on it rather than continuing
past a read.

### Capabilities this adapter supplies

| Capability | Unconfigured | What the refusal is |
|---|---|---|
| `kb-write` | `fails-closed` | A refusal; never a write to the working repository (release scenario 21) |

This table is read by `ak build` and `ak validate` (`loadAdapterSupplies` in
`src/packaging/install.ts`), the way §3 of each host contract is read for what the host provides. A
row is a claim that this adapter refuses rather than degrades when it is not configured, and that
claim is what lets an install that attaches the adapter package a skill requiring the capability at
`autonomous` although neither host provides it: the capability is then not silently absent, because
an operation needing it refuses instead of proceeding without it (ruling
`fail-closed-adapter-lifts-ceiling`). Whether this adapter is attached is the install's decision,
stated in `ak.install.yaml`; with no such file, it is.

`kb-read` is deliberately **not** a row, although this adapter supplies it. Unconfigured, it returns
an explicit unavailable result and the run continues past it, so its absence is reported rather than
refused. That is honest, but it is not failing closed, and a skill requiring `kb-read` stays capped
at `guided` on a host that lacks it, attached knowledgebase or not.

---

## 2. The seven operations

Signatures are sketches in a neutral notation; the wire form belongs to the implementation. `Ref`
types are opaque handles the KB issues. `Result<T>` is either `T` or a structured failure carrying
`common#/$defs/operation_status` and, for `needs-input`, an `escalation`.

Which operation a skill calls follows from §0's two classes: `publishArtifact` writes both, and its
`placement` argument is what declares the class. `recordDecision` writes the `decision` **run
artifact** — the decision card, with its options and evidence. An `adr` **page** is a different
thing and takes the `publishArtifact` KB-document path; a decision card is frequently the evidence a
proposed `adr` cites, which is why both exist.

### `readContext`

```text
readContext(project: ProjectRef, selector: ContextSelector) -> Result<KBDocument[]>
```

- **Inputs** — `project` is `common#/$defs/project_ref`. `selector` names one or more of the nine
  `KBDocumentType` kinds and a scope, optionally narrowed by tag, revision or recency. It may also
  select run artifacts linked from those pages, which return as links, not as page bodies.
- **Outputs** — zero or more documents, each with its KB record id, content hash and last-modified
  revision, so a caller can bind evidence to what it actually read.
- **Failure modes** — KB unreachable → `failed` with the error. KB reachable but the project has no
  record → an **empty result**, which is a fact, not an error; a skill that needs context and finds
  none stops rather than inventing it. Partial results (some types unavailable) are returned with an
  explicit coverage limitation, never silently truncated.
- **Side effects** — none. Read-only.

### `recordDecision`

```text
recordDecision(decision: DecisionArtifact) -> Result<KBRecordRef>
```

- **Carries** [`schemas/decision.schema.json`](../../schemas/decision.schema.json), envelope-bearing per `common#/$defs/envelope`. This is
  a **run artifact** (§0), not a page.
- **Inputs** — the decision with its question, bounded options, chosen option, evidence references
  and affected artifact hashes.
- **Outputs** — the KB record ref plus the stored content hash, for the caller's own evidence chain.
- **Failure modes** — a decision whose evidence references do not resolve is refused. A decision that
  supersedes an existing one must name it in `envelope.supersedes`; an unnamed conflict is refused
  rather than merged.
- **Side effects** — `kb-draft`, then `kb-publish` when authority permits.
- **Note** — recording the applicable **existing** decision, or an explicit no-new-decision result,
  is a valid outcome. A mechanical fix does not force a fresh ADR: absence of a decision is a
  recordable outcome, not a gap to fill with prose (plan §8, ADR-0001 §5).

### `publishArtifact`

```text
publishArtifact(artifact: EnvelopeArtifact, placement: Placement) -> Result<KBRecordRef>

Placement = { class: "kb-document", kind: KBDocumentType, scope: Scope }
          | { class: "run-artifact", run: RunRef, links: KBRecordRef[] }
```

- **Carries** any artifact whose `envelope.schema` is in
  [`schemas/common.schema.json#/$defs/schema_id`](../../schemas/common.schema.json#/$defs/schema_id).
- **Inputs** — the artifact, plus the `placement` that declares its §0 class. A `kb-document`
  placement names one of the nine kinds and a **scope**; the KB resolves the scope to a location
  (ADR-0001 §7) and the caller supplies no path. A `run-artifact` placement names the run and the KB
  records the artifact should be linked from.
- **Outputs** — the KB record ref and stored content hash.
- **Failure modes** — an artifact failing its own schema is refused before any write. A `kind` outside
  the nine is refused; the caller does not invent a tenth. Whether a `kb-document` placement's kind
  is one ADR-0001 §3 assigns to the calling skill is not enforced: that table is prose, and no check
  reads it (`AUTHORING.md` §4.1).
- **ADR lifecycle** — an `adr` is published with status `proposed`. **No operation in this contract
  accepts one**, and no skill may call one that appears to: acceptance happens in review and never by
  the author (ADR-0001 §4). [`policies/authority-defaults.yaml`](../../policies/authority-defaults.yaml) treats KB acceptance as an authority a
  skill does not hold, which is the same principle as this package's review independence and its rule
  that an author may not close their own finding.
- **Side effects** — `kb-publish`. Idempotency key derived per runner-contract §5 from the artifact
  hash. Publication admission and read-back follow the binding's idempotency rules; for `local-git`,
  see [publishArtifact](backends/local-git.md#5-publishartifact).

### `linkCodeEvidence`

```text
linkCodeEvidence(record: KBRecordRef, evidence: CodeLocation[]) -> Result<KBRecordRef>
```

- **Inputs** — `evidence` entries are `common#/$defs/code_location`: repository, revision, path,
  optional symbol and line range. The revision is mandatory, which is what makes the link survive a
  later edit.
- **Outputs** — the updated record ref.
- **Failure modes** — a location whose revision the KB cannot resolve is refused rather than stored
  as a dangling pointer. Moving a line number does not create a new link or invalidate an existing
  one, because links bind to revision plus symbol, not to a line alone (release scenario 9).
- **Side effects** — `kb-publish`.

### `requestImpactAnalysis`

```text
requestImpactAnalysis(project: ProjectRef, query: ImpactQuery) -> Result<ImpactReport>
```

- **Inputs** — a subject (a symbol, a public contract, a document, a decision) and the scope to
  consider.
- **Outputs** — an `ImpactReport` listing affected records and code locations **with an explicit
  coverage statement**: what the analysis covered, what it could not, and how current its graph is.
- **Failure modes** — a stale or partial graph produces an explicit coverage limitation, never a
  confident-looking empty answer (release scenario 14). Unavailable analysis returns unavailable; a
  caller that needed it stops rather than substituting its own guess at consumer counts.
- **Side effects** — none. Read-only.

### `linkPullRequests`

```text
linkPullRequests(source: PullRequestRef, kb: PullRequestRef) -> Result<PairedPRLink>
```

- **Inputs** — the source-repository PR and the paired KB PR.
- **Outputs** — the `PairedPRLink` with both refs, the link state, and the KB PR's current check
  status.
- **Failure modes** — see §4. A link that cannot be established is reported, not assumed.
- **Side effects** — `kb-publish` and, where the link is written back onto the source PR,
  `pr-comment`. Both are remote effects under runner-contract §5.
- **Availability** — optional. Where no KB integration is configured, a shipping skill populates
  nothing and does not fail; the paired-PR path is exercised only when a KB is present.

### `proposeLesson`

```text
proposeLesson(lesson: LessonArtifact) -> Result<KBProposalRef>
```

- **Carries** [`schemas/lesson.schema.json`](../../schemas/lesson.schema.json).
- **Inputs** — the lesson, its supporting evidence references, and any lesson it supersedes.
- **Outputs** — a **proposal** ref. `proposeLesson` proposes; it does not publish.
- **Failure modes** — a lesson with no resolvable supporting evidence is refused. A successful
  routine run that produced no new knowledge proposes nothing; inventing a lesson to have an output
  is release scenario 23.
- **Authority** — publication requires explicit authorization or a charter grant covering
  `publish-lesson` (`common#/$defs/grantable_action`). "Ship happened" is not permission to rewrite
  project knowledge (plan §7.1, ruling `entrypoint-phase-operation-split`).
- **Side effects** — `kb-draft`. `kb-publish` only on the authorized promotion step.
- **Learning runtime** — under the opt-in `learning` profile, a review pattern promoted to a
  guardrail and a lesson the runtime confirmed both arrive here as `candidate` proposals and
  nothing more. A ledger status such as `active` or `confirmed` is a count the runtime kept, not an
  authorization, so it never reaches `kb-publish` on its own (ruling
  `learning-drafts-not-publishes`).

---

## 3. Centrality (release scenario 21)

A KB write stays central (ruling `central-kb-owns-project-artifacts`, ADR-0001 §1). No operation in
this contract, and no skill calling one, may create or
extend a documentation tree inside the application repository — no `docs/`, no `CONTEXT.md`, no
`plans/`, no ADR directory, no `.scratch/` artifact store.

What the working repository may contain is fixed and small (plan §1.2): source, tests, a KB locator,
the package pin, and the necessary host/CI wiring.

Transient run material — parallel-agent notes, sandbox output, checkpoints — lives in the
runner-owned workspace, not in the repository and not in the KB. Sanitized durable receipts are
published to the KB afterwards.

`ak validate` fails a skill whose outputs name a repository path where a KB operation belongs; the
corresponding eval case asserts that no application-local docs tree appears.

The KB locator is the binding file of §7 and holds no project knowledge. A binding whose
knowledgebase resolves to the application repository — its checkout, any of its work trees, or a
directory inside its tree — is refused on every operation, because a publish through it would be
the write this section forbids.

---

## 4. The paired-PR requirement (release scenario 22)

Preserved exactly as stated in plan §8 and reaffirmed by ADR-0001 §6, including what it is **not**.
The authority split is the model: the KB owns git-backed decisions and reviewed history, the runner
owns command authorization and receipts, and neither claims the other's surface.

1. A source PR links to its associated KB PR through `linkPullRequests`.
2. A **source merge event** — delivered by the runner as an `event` artifact
   ([`adapters/runner-contract/CONTRACT.md`](../runner-contract/CONTRACT.md) §6) — activates the existing KB merge coordinator. The
   package activates the coordinator; it does not reimplement it.
3. The coordinator still honors the KB's own checks, branch-protection rules, all related source
   dependencies, and retry and idempotency rules. Activation never bypasses a KB check.
4. **This is not an atomic cross-repository merge.** No operation here makes the source merge and the
   KB merge succeed or fail together, and no skill may describe it as though it did.
5. **A blocked KB merge stays visible and retryable.** It is reported with its blocking reason and
   remains in a retryable state. It is never reported as complete, never closed to make a ship
   summary read cleanly, and never silently dropped because the source side merged.

The state a skill reports after a source merge is the state the read-back observed: source merged,
KB merge pending or blocked with its reason. A ship report that says "shipped" while a paired KB
merge is blocked is a false completion.

---

## 5. Known limitation

The seven operations contain no atomic claim primitive: two runs writing the same KB record
concurrently are serialized by the KB, not by this interface. This is recorded rather than patched
with an eighth operation. In practice the gap is covered by runner-contract §5 — a `kb-publish` key
derived from the artifact hash makes a concurrent duplicate a detectable conflict at read-back rather
than a silent overwrite, and a changed input hash under a reused key refuses. A skill that needs
exclusive access to a KB record requests it from the runner, which owns serialization; it does not
implement locking in its body.

---

## 6. Testing

Tests this adapter owns. `tests/kb-adapter.test.ts` holds 2, 4, 5, 6, 7 and 9 against the
`local-git` backend of §7, and the binding's own rules; the rest test operations no backend carries
yet, or skill behavior, and are not held there:

1. **No local docs tree** — for every skill whose outputs are project-derived, a fixture run leaves
   the working repository free of any documentation directory (scenario 21).
2. **No tenth kind** — a publish naming a `kind` outside the nine is refused, and `ak validate` fails
   a skill declaring one.
3. **Emission-table conformance** — not enforced. ADR-0001 §3 is prose, so nothing checks that a
   skill publishes only the kinds it assigns, or that a skill absent from it publishes no KB
   document. [`schemas/skill.schema.json`](../../schemas/skill.schema.json) holds a tagged output to the nine kinds and no further
   (`AUTHORING.md` §4.1).
4. **An ADR is proposed, never accepted** — publishing an `adr` yields status `proposed`, and no
   operation or skill path reaches acceptance (ADR-0001 §4).
5. **Scope, not path** — a publish carrying a computed KB path rather than a scope is refused
   (ADR-0001 §7).
6. **Unavailable KB refuses, never falls back** — with no KB configured, `kb-write` operations refuse
   and no repository file is created.
7. **Empty is not an error** — `readContext` against a project with no records returns an empty
   result, and the calling skill stops rather than proceeding on invented context.
8. **Coverage limitation surfaces** — a stale impact graph produces an explicit limitation in the
   report and in whatever artifact consumes it (scenario 14).
9. **Publish idempotency** — republishing an unchanged artifact after a simulated restart performs no
   second remote effect; a changed artifact under a reused key refuses (scenario 20).
10. **Paired-PR honesty** — a blocked KB merge is reported blocked and retryable, and the ship report
    does not read as complete (scenario 22).
11. **Lesson restraint** — a successful routine run with no new knowledge proposes no lesson
    (scenario 23); an unauthorized promotion of a proposed lesson is refused (plan §7.1).
12. **Rollback independence** — rolling back a published skill revision leaves the supporting lesson
    and evidence history intact (scenario 24), because lessons are KB pages with supersession and
    skills are package files.

---

## 7. Bindings: how a project folder reaches its knowledgebase

A binding is the **KB locator** plan §1.2 lets a working repository hold. It says which
knowledgebase a project uses and which project it is there. It does not say where that
knowledgebase is on a machine, because that differs per machine and a path in a committed file is
wrong for everyone but its author (ruling `kb-binding-is-a-locator`).

### The binding file

`ak.kb.yaml` at the root of the project folder, shaped by [`schemas/kb-binding.schema.json`](../../schemas/kb-binding.schema.json) and then
by the backend's own `schemas/kb-backends/<backend>.schema.json`:

```yaml
backend: <binding id>            # names a document under adapters/knowledgebase/backends/
project: <project id>            # the project_ref id this folder's records are filed under
locator: { <key>: <value> }      # how the backend finds the knowledgebase; the keys are the backend's
```

**The binding file is committed and holds neither a secret nor a machine path.** It is committed so
that every checkout of the project binds the same knowledgebase: a task copy made as a git work
tree carries the file because it carries the commit, and needs no setup of its own. The **project
folder** is the nearest directory at or above the working directory that holds `ak.kb.yaml`,
searching no higher than the repository's top level; with none there, the folder is unbound and §1's
unconfigured case applies. A `backend` with no document under `backends/` is refused, since nothing
states how to reach it.

### The registration

Where a knowledgebase is checked out is recorded once per machine, outside every checkout, in the
operator's registry: `~/.agent-kit/kb/registry.json`, or the file `AK_KB_REGISTRY` names.

```sh
ak kb register <knowledgebase-id> <path>
```

It is the operator's step and starts no phase. It refuses a path that is not the top of a git work
tree, and, run from a bound project, one that is that project's application repository (§3); every
operation refuses such a registration wherever it was made. A binding that names a knowledgebase the
machine has not registered is unconfigured, not failed: the project is bound correctly and this
machine has not been told where the knowledgebase is.

### The commands

| Operation | Command | Carried |
|---|---|---|
| `readContext` | `ak kb read --kind <kind>[,<kind>…] --scope <scope>` | yes |
| `publishArtifact`, `kb-document` placement | `ak kb publish document --kind <kind> --scope <scope> --id <id> --title <title> --file <page>` | yes |
| `publishArtifact`, `run-artifact` placement | `ak kb publish artifact --file <artifact.json> --run <run> [--link <record-ref>]…` | yes |
| `recordDecision`, `linkCodeEvidence`, `requestImpactAnalysis`, `linkPullRequests`, `proposeLesson` | `ak kb record-decision` and its four siblings | no: each refuses and writes nothing |

`ak kb check [<project-dir>]` reports the binding, the registration and which of these can run.
The [local-git binding](backends/local-git.md#5-publishartifact) owns the additional publication
options and requirements for trail records.
`read`, `publish` and the five refusing commands print one JSON result; `check` and `register` print
lines for a person. Every command exits 0 when the operation completed, 1 when it failed or
was refused, 2 on a usage error and 3 when no knowledgebase is configured, so a caller can tell an
empty knowledgebase (0, an empty list) from an absent one (3).

A decision card is a run artifact, so until a backend carries `recordDecision` it travels as a
`decision` through `publishArtifact`'s run-artifact placement, which validates it against
[`schemas/decision.schema.json`](../../schemas/decision.schema.json) like any other. What that path does not do is resolve the card's
evidence references or its supersession, which is `recordDecision`'s own guarantee and stays
unmet.

### Bindings

| Binding id | The knowledgebase is | Document |
|---|---|---|
| `local-git` | a git repository of files on this machine | [`adapters/knowledgebase/backends/local-git.md`](./backends/local-git.md) |

A binding is additive: a document under `backends/`, a row here, a schema at
`schemas/kb-backends/<id>.schema.json` and the code that carries its operations under `src/kb/`.
The generic binding schema names no backend, and nothing in §1–§6 depends on any one of them.
Building a backend in this package rather than calling an existing knowledgebase tool is the
decision recorded in `docs/decisions/0010-file-backed-knowledgebase.md`.
