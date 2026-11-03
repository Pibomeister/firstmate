# Knowledgebase binding

What an agent needs, inside an installed plugin, to reach the project's central knowledgebase: how
to tell whether one is configured, the commands for the two operations that are carried, and what
each result obliges. The contract this condenses is [`adapters/knowledgebase/CONTRACT.md`](../../adapters/knowledgebase/CONTRACT.md) §1, §3 and
§7 and the `local-git` binding, which do not ship with the plugin (ruling
`kb-binding-is-a-locator`). A skill loads it before its first knowledgebase operation.

## Check first

```sh
ak kb check
```

Run it in the project folder, which may be a task copy. A current `ak` on `PATH` is a prerequisite:
a missing command, or a usage error from an older `ak`, is `needs-input` naming that prerequisite,
and is not an unavailable knowledgebase.

| Exit | Meaning | What the run does |
|---|---|---|
| 0 | bound: the output names the knowledgebase, its path and the project id | reads and publishes through the commands below |
| 3 | no knowledgebase configured | a read is **unavailable**, reported as a coverage limit, and the run continues to the point where it must read or publish; a publish **refuses** |
| 1 | a knowledgebase is configured and cannot be used | `failed`: stop and report the message, never proceed from memory |

Exit 3 has two causes and the output says which. Report it in these words rather than as a missing
adapter or a missing file:

- **`kb.unbound`** — the project commits no `ak.kb.yaml`. The setup step is committing one at the
  project root.
- **`kb.unregistered`** — the project is bound, and this machine has not been told where that
  knowledgebase is checked out. The setup step is `ak kb register <knowledgebase-id> <path>`.

Both are the operator's to do. An agent does not create a knowledgebase, write `ak.kb.yaml` or
register a path unless a human asks for exactly that. **`ak.install.yaml` is not a cause.** That
file sets which adapters an install attaches, which only decides packaged mode ceilings; its absence
is the default install and never makes a knowledgebase unavailable.

Unavailable never becomes a file in the working repository: no `docs/`, no ADR directory, no
scratch record standing in for a publish.

## The binding

`ak.kb.yaml` at the project root is committed and holds no secret and no machine path:

```yaml
backend: local-git
project: <project id>            # every record is filed under it
locator:
  knowledgebase: <id>            # an id in the operator's registry, never a path
```

Because it is committed, a task copy made as a git work tree binds what the main checkout binds
and needs no setup. The **project folder** is the nearest directory at or above the working
directory holding `ak.kb.yaml`, searching no higher than `git rev-parse --show-toplevel`.

## Reading: `readContext`

```sh
ak kb read --kind concept,system,adr --scope <scope>
```

`--kind` takes any of the nine kinds: `adr`, `concept`, `foundation`, `gotcha`, `pattern`, `prd`,
`process`, `sop`, `system`. `--scope` is the component the work is in, as kebab-case words joined
by `/` (`billing/exports`), or `project` for the whole project. It is never a path. The result is
JSON: the pages at that scope and every scope above it, most specific first, each with its `ref`,
`content_hash`, `revision`, `status` and `body`.

- **An empty `documents` list with exit 0 is a fact**: the project has recorded nothing there. Say
  so and continue; do not invent context.
- **`coverage`** names the kinds and scopes searched and any page that could not be read. Carry it
  into whatever consumes the read.
- Cite what was read by `ref` and `content_hash`, not by a file path in the knowledgebase.
- A page whose `status` is `proposed` or `unreviewed` has not been accepted by a human. It is
  context, not a settled decision.

## Publishing: `publishArtifact`

A curated page, one of the nine kinds:

```sh
ak kb publish document --kind adr --scope <scope> --id <kebab-id> --title "<one line>" \
  --file <page.md> [--run <run-id>]
```

A run artifact, one of the envelope schemas:

```sh
ak kb publish artifact --file <artifact.json> --run <run-id> [--link <record-ref>]…
```

For `trail` and `trail-audit`, use the work-trail protocol's publication boundary and resume rule.
Its non-blocking failure reporting and no-resend rule replace the retry and stop guidance below.

Write the page or artifact to a scratch file outside the repository and pass its path. Then:

- **Keep the returned `ref`, `content_hash` and `revision`.** They are the record reference the
  skill reports; `effect: none` means the same content was already published and nothing was
  written twice. The `idempotency_key` and `run` returned are the stored record's. Republishing an
  artifact after approvals were added stores the approved copy under the same `ref`; approvals
  already stored are added to, never dropped, and a copy that lacks one while bringing another is
  refused.
- **An `adr` is stored `proposed`** and other pages `unreviewed`. There is no way to publish one
  accepted, and a page body that begins with its own `---` header is refused. Acceptance is a
  human's edit in the knowledgebase.
- **A refusal is the answer, not an obstacle.** A kind outside the nine, a scope that is a path, an
  artifact failing its schema, a link that names no record, or changed content or changed links under an
  id already published all refuse. Fix the request, or publish the change under a new id; never edit the
  knowledgebase checkout by hand to get past one.
- **Exit 1 with `status: failed`** is the knowledgebase not doing what was asked. Stop and report
  it.

## The other five operations

`recordDecision`, `linkCodeEvidence`, `requestImpactAnalysis`, `linkPullRequests` and
`proposeLesson` are not carried by any binding yet: `ak kb record-decision` and its siblings refuse
and write nothing. Report the refusal by the operation's name. A decision card is the one case with
a path: it is a `decision` run artifact and publishes through `ak kb publish artifact`.
