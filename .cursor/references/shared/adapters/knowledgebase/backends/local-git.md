# Binding `local-git` — a knowledgebase that is a git repository on this machine

A backend binding under [`adapters/knowledgebase/CONTRACT.md`](../CONTRACT.md) §7. Everything generic — the seven
operations, the two artifact classes, centrality — is the contract's; this document states only how
this one binding meets it (ruling `kb-binding-is-a-locator`). The code is `src/kb/local-git.ts`.

**Carries:** `readContext` and `publishArtifact`. The other five operations refuse (§6).

**Needs:** `git` on `PATH` and a git identity the knowledgebase repository can commit with. No
network, no service and no credential.

---

## 1. The binding

```yaml
# ak.kb.yaml, at the project root, committed
backend: local-git
project: billing-service       # the project_ref id; every record is filed under it
locator:
  knowledgebase: central       # an id in the operator's registry, never a path
```

`locator.knowledgebase` is the only key read ([`schemas/kb-backends/local-git.schema.json`](../../../schemas/kb-backends/local-git.schema.json), which
`ak kb check` applies after the generic [`schemas/kb-binding.schema.json`](../../../schemas/kb-binding.schema.json)). It is an id of lowercase
words joined by hyphens, so a path cannot be written there: the schema refuses a `/`.

Several projects may name the same knowledgebase. Each is filed under its own `project`, and no
operation reads or writes another project's records.

---

## 2. Setup, when a human asks

Setup is an operator task, not a skill. It is done once per knowledgebase and once per machine; a
task copy of a bound project needs none of it.

1. Create the knowledgebase where it should live, outside every application repository:
   `git init <path>`. Give it a remote or not; this binding never pushes.
2. Register it on this machine: `ak kb register <knowledgebase-id> <path>`. The registry is
   `~/.agent-kit/kb/registry.json`, or the file `AK_KB_REGISTRY` names.
3. Commit `ak.kb.yaml` (§1) at the project root.
4. Run `ak kb check` in the project. It prints `bound`, with the knowledgebase's path and the
   project id, and exits 0.

Another machine repeats steps 1 and 2 with its own path — typically a clone of the same
knowledgebase repository — and step 4. Step 3 is already in the project's history.

---

## 3. Layout

Scope resolves to a location here, which is why a caller never supplies one (ADR-0001 §7):

```text
projects/<project>/documents/[<scope segment>/…]<kind>/<id>.md      KB documents, one file each
projects/<project>/runs/artifacts.jsonl                             run artifacts, one line each
```

A **page** is its own markdown file, so a human accepts an ADR by editing that file (§5). A **run
artifact** is one line of the project's `artifacts.jsonl`: one JSON object holding the stored
record (ref, content hash, idempotency key, links) beside the artifact. The file is append-only. A
publish adds a line and never rewrites one, so git can delta successive versions of the file. A later
line for the same ref is a later copy of that record (the approved copy in §5) and is the one that
counts. A line that does not parse as a record names no ref.

The former `projects/<project>/runs/<run>/<schema>/<artifact id>.json` files are not read or
automatically migrated by this backend.

A **scope** is a component, written as kebab-case words joined by `/` (`billing/exports`), or
`project` for the whole project. A scope segment may not be one of the nine kinds, nor `project`,
`projects`, `documents` or `runs`, and a scope with an extension, a leading `/`, an uppercase letter
or `..` is refused as a computed path.

A **record ref** is the opaque handle the contract's `KBRecordRef` asks for:
`doc:<scope>/<kind>/<id>` for a page and `run:<run>/<schema>/<artifact id>` for a run artifact. A
caller passes back what it was given and does not build one. A ref is not a path: the layout above
can change while the refs stay the same.

---

## 4. `readContext`

`ak kb read --kind <kind>[,<kind>…] --scope <scope>`

Returns the pages of those kinds at the scope and at each scope above it, most specific first, each
with its record ref, content hash, the knowledgebase commit that last changed it, and its body.

- **Reads the committed tree, never the working files.** A page somebody is drafting in the
  checkout is not yet knowledge, and what a run read can be reproduced from the commit it names.
- **Empty is a result.** A project with no pages returns `complete` with an empty list.
- **Coverage is stated.** The result names the kinds and scopes searched, and any committed file
  under them that is not a record this binding wrote, by path, so a hand-written page is reported
  rather than silently skipped.
- **Not carried:** narrowing by tag, revision or recency, and selecting the run artifacts linked
  from a page. The result says `run_artifact_links: not-selected` rather than implying there were
  none.

---

## 5. `publishArtifact`

One publish is one commit in the knowledgebase repository that touches one file: the page's own
file, or `artifacts.jsonl` for a run artifact. It is made with the operator's git identity, is not
pushed, and is read back from the commit before it is reported. The record's body is in that
commit, so reading the commit returns what was published.

### `kb-document` placement

`ak kb publish document --kind <kind> --scope <scope> --id <id> --title <title> --file <page.md> [--run <run>]`

The page body is the file; the knowledgebase writes the header. A body that begins with a `---`
header of its own is refused, because the header carries the status.

- **A kind outside the nine is refused.**
- **An `adr` is stored `proposed`; every other kind is stored `unreviewed`.** There is no flag for
  the status and no operation that changes it. Accepting an ADR is a human's edit and commit in the
  knowledgebase repository (ADR-0001 §4).
- **The page is not an envelope artifact.** The contract's signature carries one; a curated page of
  the nine kinds has no schema in `common#/$defs/schema_id`, so this placement takes prose and the
  schema check of §5's other placement does not apply to it.

### `run-artifact` placement

`ak kb publish artifact --file <artifact.json> --run <run> [--link <record-ref>]… [--trail-attempts <directory>]`

- **Validated before any write** against the schema its envelope names. A failing artifact leaves
  the knowledgebase untouched.
- **Bound to its project and run.** An artifact whose `project.id` is not the binding's, or whose
  `run_id` is set and is not `--run`, is refused.
- **Appended, not filed.** The record becomes one new line at the end of `artifacts.jsonl`, and
  the commit touches that file alone. Lines already there are not changed.
- **Links resolve or the publish is refused.** Each `--link` must name a committed record: a page
  file, or a line of `artifacts.jsonl` that carries that ref.
- **Trail attempts are durable and per record.** A `trail` or `trail-audit` publication requires
  `--trail-attempts <directory>`, the existing attempt directory of the build's stretch index.
  Inside the knowledgebase lock, after the checks that can refuse or answer `effect: none`
  without writing, the command exclusively creates and flushes a mark for that knowledgebase,
  project, run, kind and id immediately before writing the record. A refusal from those checks
  consumes no mark. A mark already present when a write is due returns
  `kb.trail-publication-unknown` without sending anything; a mark that cannot be made durable
  returns `kb.trail-attempt-unrecorded` without sending anything. Neither result is itself a build gate.
  If creation succeeded before durability failed, the first response says that this call sent
  nothing and the mark remains. A later call conservatively reports publication-unknown; it does
  not establish that the earlier call published. Unsupported directory flushing refuses in the
  same way, without publishing or deleting the mark.
  The caller records the outcome in its index and replays a recorded outcome without invoking the
  publisher. It never removes marks or uses another directory to retry a record. Other artifact
  kinds and document publication do not accept this flag.
- **Write and cleanup failures are reported.** A record-write exception returns a structured
  failure. Cleanup is limited to that record, and restores it only while HEAD, working content
  and index state remain recognizable as the interrupted write. An incomplete write, concurrent
  content or a refused cleanup is left in place with its diagnostic; unrelated staged work is
  untouched. A trail whose cleanup cannot be confirmed returns `kb.trail-publication-unknown`
  and warns that content may have been published or exposed. Its mark stays. A confirmed restore
  still retains the mark and returns `kb.write-failed` or `kb.commit-failed`, not success.
  Partial or unrecognized content left in the shared `artifacts.jsonl` can make **all later
  project publications**, including required receipts, refuse with `kb.uncommitted-record`.
  The trail result is not a gate, but this shared-file refusal can stop later build work.
  An operator must preserve a copy, inspect the reported file against its committed content and
  deliberately resolve only its contents under normal ownership. Never automatically reset or
  delete concurrent changes, remove attempt marks, or resend an unknown publication outcome.

### Idempotency and read-back

Per [`adapters/runner-contract/CONTRACT.md`](../../runner-contract/CONTRACT.md) §5. The key is the digest of the run, the operation, the
record ref and the content hash.

Trail records follow the table too; only the rows that write pass the per-record attempt boundary
above first.

| The record at that ref | Result |
|---|---|
| does not exist | written, committed, read back: `effect: published` |
| exists with the same content hash | nothing written: `effect: none`, the existing commit returned |
| exists with a different content hash | refused; a changed page is published under a new id that supersedes the old one |
| is a run artifact with the same content hash and a different set of links | refused; a stored record's links are not rewritten |
| is a run artifact with the same content hash, and the request carries every stored approval plus at least one more | the approved copy is appended as a new line for the same ref: `effect: published`, a new commit on the same ref |
| is a run artifact with the same content hash, and every approval in the request is already stored | nothing written: `effect: none` |
| is a run artifact with the same content hash, and the request both lacks a stored approval and carries one not stored | refused; stored approvals are added to, never replaced |

Approvals are outside the content hash, so a draft and its approved copy share a ref, a hash and a
key. Publishing the approved copy after the draft stores it; the draft stays as the earlier line.
Approvals are compared entry by entry. A republish that carries none, or only some of
those stored, writes nothing, so a late retry of an earlier copy does not strip the approvals
already stored. This approval-superset append path does not override a `trail` or `trail-audit`
attempt mark: a later write, including an approval-only copy after successful publication, is
refused with `kb.trail-publication-unknown`. There is no approval exemption from that fence.

Every result reports what the knowledgebase holds: `content_hash`, `idempotency_key` and `run` are
read from the stored record. `effect: none` returns the commit that wrote the stored copy: for a
page, the last commit that changed its file; for a run artifact, the commit that added its line. A
page republished under another `--run` returns `effect: none` with the key and run it was first
published under.

A file the publish would write that has uncommitted changes in the checkout is refused with
`kb.uncommitted-record`, and nothing is written over it. For a run artifact that file is
`artifacts.jsonl`.

Two publishes at once are serialized by a lock in the knowledgebase's git directory, so the second
sees the first's record (contract §5).

---

## 6. What this binding does not carry

`recordDecision`, `linkCodeEvidence`, `requestImpactAnalysis`, `linkPullRequests` and
`proposeLesson` each refuse with `kb.operation-not-carried` and write nothing. A skill that needs
one reports the refusal; it does not approximate the operation with a publish, with the one
exception contract §7 states for a decision card.

Also absent, and worth knowing before relying on this binding:

- **No review workflow.** Nothing here enforces that a human reviewed a page; `unreviewed` and
  `proposed` are what was stored, and changing them is an ordinary commit by whoever may write to
  the repository.
- **No push.** A knowledgebase with a remote is synchronized by its operator.
- **No access control beyond the filesystem's.** Whoever can write the checkout can write the
  knowledgebase.

---

## 7. The knowledgebase is never the application repository

The registered checkout is refused on every operation, and at registration too when `ak kb register`
runs from a bound project, when it is the
project's own checkout, another work tree of the same repository, or a directory inside or around
the project's tree (contract §3). Every git call this binding makes drops the caller's `GIT_*`
environment first, so a hook's `GIT_DIR` cannot point a publish at the repository the run is
working in.
