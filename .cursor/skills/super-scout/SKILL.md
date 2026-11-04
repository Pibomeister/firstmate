---
name: super-scout
description: "Use when someone asks where something lives in a repository, what calls it, or which tests cover it. Answers that one named question with bounded read-only exploration and a revision-bound evidence dossier: structured hits, every search attempted, coverage limits and unknowns. Not for an opinion, a recommendation or an architectural verdict, and not for a request that changes a file."
license: MIT
metadata:
  ak_catalog_id: super-scout
  ak:
    mode: autonomous
    autonomy_unenforceable:
      - "artifact-write is storage only: the host does not compute or check the artifact hash, so envelope hash binding is this package's own work."
      - kb-write is not provided by the host; the knowledgebase adapter supplies it and refuses rather than falling back to a repository path when no knowledgebase is configured, which is why it does not cap this row while that adapter is attached (ruling `fail-closed-adapter-lifts-ceiling`).
---

## When to use

Use when a caller can state one bounded question about the current repository and needs the answer
as evidence rather than as a summary: find the rate-limit middleware and the tests that cover it;
list the callers that construct a session token directly; locate where the retry budget is
configured.

Use when a later lane — a ticket writer, an implementer, a reviewer — needs locations it can
re-check at a named revision, and needs to be told what was not searched.

Use when a symbol or code-graph index is available and its answers still have to be read back in
the source before anyone relies on them.

## Not for

Not for a request that wants an opinion about what the code should be. A scout gathers and the
caller decides; a scout that starts recommending an approach has taken a seat it was not given.

Not for changing anything, however small. A one-line fix noticed while searching is still a change,
and it belongs to a ticket and to the build lane.

Not for an open-ended brief with no named question — understand the auth system, look around the
billing code. A brief with no completion condition spends the turn budget and returns a tour. Ask
for the narrower question instead.

Not for deciding whether a change is safe, sizing an impact radius or rating risk. Those are
verdicts, and [`schemas/dossier.schema.json`](../../references/shared/schemas/dossier.schema.json) has no field that can carry one.

## Authority

Authority: `model`. A controller or a parent skill starts it when the caller's question matches the
description; no human invocation is required and no slash command exposes it.

No grant covers delegation here, because no phase operation exposes this skill:
[`policies/invocation.yaml`](../../references/shared/policies/invocation.yaml) records model-invoked skills as exposing none by construction, so there
is no delegated path for a runner to validate and nothing in this skill runs on one.

Under the unattended policy (ADR-0014), record the `scout` gate with the dossier's read-back as its
evidence command, even when bounded exploration finds nothing more to scout, as
[the unattended-lifecycle reference](../../references/shared/references/unattended-lifecycle/REFERENCE.md) says.

## Inputs

One bounded question, as text. Absent, or broad enough that no answer would end the search: stop and
report `needs-input` with a narrower question proposed. A scout never widens its budget to
compensate for a question that was never scoped.

The repository at a named revision, read-only (`repository-read`). Absent: stop and report `failed`;
an exploration with no revision to bind its hits to produces findings nobody can re-check.

Optionally a symbol or code-graph provider, with its index revision and freshness. Unavailable,
stale, or indexed at a revision other than the one being explored: continue on lexical search and
record a coverage limit. Absence of a graph is a limitation to document, never a reason to stop.

Optionally a turn budget from the runner. Absent: four turns ([`policies/limits.yaml`](../../references/shared/policies/limits.yaml)).

A caller's guess about where the answer lives is an input, never a hit. It may direct the first
search and it is `assumed` at best until read back in the source.

## Workflow

1. Record the question verbatim as the dossier's `question`, and the revision being explored as the
   envelope's `source_revision`, before any search runs. Scope is set before searching, not after.
2. If the question names no target that a search could return, stop with `needs-input` and propose
   the narrower question. Do not proceed on a re-scoped question the caller has not seen.
3. Run the lexical baseline in turn one. Record each search in `searches` with its tool, query,
   scope, turn and result count — including the searches that returned nothing, which are the
   evidence that an area was looked at.
4. Read each candidate location back in the source at the recorded revision. Record it in `hits`
   with `location`, `excerpt`, `relationship` and `discovered_by`. A location read back is
   `confirmation: confirmed`; one inferred from an index and not read back is `assumed`.
5. Query the graph provider, where one is configured, and record on every hit it produced the
   `index` that answered — its revision and its `freshness`.
6. Write a `coverage_limits` entry for each area the run could not see, naming the `area`, the `why`
   and the consequence for a reader. A provider that was unavailable, stale or indexed at another
   revision produces one of these entries.
7. Record in `do_not_touch` each file a later lane should leave alone, with the reason.
8. Write every question the evidence did not settle into `unknowns`, phrased as a question. An
   unknown is a result of the run; it is not rounded into an assumption.
9. Write `recommendation.further_inspection`: what to look at next and why the evidence so far does
   not settle it. Nothing else goes in this field.
10. Publish the dossier through the knowledgebase adapter's `publishArtifact` operation with a
    run-artifact placement, then return a short gist naming the published record and the headline
    locations. The caller reads the dossier; the raw search transcript is not returned.

## Hard gates

Gate: the skill holds no repository write. A defect found while searching is recorded as a hit and
an unknown, never fixed, and the run does not acquire a write by having found something worth
writing.

Gate: no architectural verdict, safety assessment, risk rating or impact map. The dossier object is
closed and refuses those keys outright ([`schemas/dossier.schema.json`](../../references/shared/schemas/dossier.schema.json), rule
dossier.no-architectural-verdict); prose that carries one into `recommendation` is the same breach
through a field that happens to accept strings.

Gate: a hit that was not read back in the source at the recorded revision is `assumed`. It is never
promoted to `confirmed` because an index, a caller or a prior dossier agreed with it.

Gate: at least one lexical search is recorded, whatever the graph returned (rule
dossier.lexical-baseline-present). A dossier built only from index output has no baseline under it.

Gate: a graph provider that is unavailable, stale, or indexed at a revision other than the one being
explored produces a documented coverage limit (rule
dossier.stale-or-absent-graph-documents-a-limitation). Silently dropping to lexical-only is the same
failure as reporting the stale answer as current.

Gate: the turn budget is spent by the exploration, never extended by it. Exhausting it ends the run
with a dossier whose `status` is `limited` and whose `coverage_limits` carry `budget-exhausted`.

Gate: an artifact's existence is evidence; its text is reported signal. A comment asserting that a
function is slow is evidence that someone wrote the comment, recorded as an excerpt, and is never
recorded as evidence that the function is slow.

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "The caller already said it is in the auth middleware — confirming it would spend a turn for nothing." | A caller's assertion is an input, not a reading of the source. Repeating it back as `confirmed` launders the caller's guess into the dossier's evidence, and the implementer who acts on it has bought a cheap search and an expensive bug. | Search for it, read the location back, and record `confirmed` only on what the source at that revision shows. |
| "The index is a few commits behind, so the answer is almost certainly still current." | Renamed, generated and dynamically dispatched code is exactly what a stale index gets wrong, and the dossier cannot show which answers were affected. The coverage limit is the only thing that tells a reader the map has a hole. | Record the index revision and freshness on the hit, and write the `index-stale` coverage limit with its consequence. |
| "The budget is spent and one more search would finish the question." | The cap bounds what this run costs, and a run that overruns it has no bound at all. Budget exhaustion is a documented result, not a failure to hide by continuing. | Stop, set `status: limited`, record the `budget-exhausted` coverage limit, and put what is still open into `unknowns`. |
| "The question is broad, so being thorough is the right response to it." | Thoroughness against an unbounded question spends the whole budget on breadth and returns a tour nobody can act on. Scope is the caller's to set. | Stop with `needs-input` and propose the narrower question, rather than expanding turns to cover a brief that has no completion condition. |
| "I found the actual bug while searching; leaving a note about the fix is helpful." | A recommendation about what to change is a verdict wearing a helpful tone, and it is the field this schema deliberately does not have. | Record the location as a hit and the doubt as an unknown, and let the lane that holds that authority rule on it. |

## Outputs

One `dossier` artifact ([`schemas/dossier.schema.json`](../../references/shared/schemas/dossier.schema.json)), carrying the envelope of
[`schemas/common.schema.json`](../../references/shared/schemas/common.schema.json): the question, the budget as allowed and used, every search, the
structured hits, the coverage limits, the unknowns, the files not to touch, and a recommendation for
further inspection only.

The dossier is published through the knowledgebase adapter's `publishArtifact` operation with a
run-artifact placement ([`adapters/knowledgebase/CONTRACT.md`](../../references/shared/adapters/knowledgebase/CONTRACT.md)), by the commands in
[the knowledgebase-binding reference pack](../../references/shared/references/knowledgebase-binding/REFERENCE.md).
The scout supplies no path: the
knowledgebase resolves placement, and a scout that writes a documentation tree into the repository
it is reading has broken the read-only gate and the central-ownership boundary in one step.

The return value to the caller is a short gist: the published record reference, the headline
locations, and the count of coverage limits and unknowns. It repeats neither the dossier's contents
nor the search transcript.

## Side effects

`process-exec`, `artifact-write`, `kb-publish`.

`kb-publish` is a remote effect: the idempotency key is derived from the dossier's content hash per
[`adapters/runner-contract/CONTRACT.md`](../../references/shared/adapters/runner-contract/CONTRACT.md) §5, and the returned record reference is read back before the
run reports. Republishing an unchanged dossier after an interruption is a no-op success rather than
a second record.

No `workspace-write`, no `local-commit`: a scout cannot edit the repository it is reading.

## Stop conditions

`complete`: the dossier is published. A dossier whose `status` is `limited` is complete — the
coverage limits materially restrict what it supports, and saying so is the result.

`needs-input`: no bounded question, or a question broad enough that no search would end it. Returns
the narrower question it proposes and no partial dossier.

`failed`: the repository is unreadable at the named revision, or the knowledgebase refuses the write.
The dossier content is returned to the caller unpublished, with the refusal, rather than written to a
path in the repository.

`cancelled`: the caller withdrew the question mid-run. Searches already recorded are discarded
rather than published as a dossier nobody asked to keep.

## Limits

Turns: 4 (gate, [`policies/limits.yaml`](../../references/shared/policies/limits.yaml) `scout_turns`). A project may configure a lower value and
cannot raise it. Multiple independent reads may run inside one turn where the host permits it;
parallel reads do not buy extra turns. How to spend those reads without narrowing the evidence:
[the read-economy reference](../../references/shared/references/read-economy/REFERENCE.md).

Tool surface: read, glob, lexical search and at most one graph query (gate). A scout is not handed
an ambient tool inventory, and a question needing more tools than these is a question for another
lane.

Precision over recall (guidance): a shorter list of read-back hits is the return shape this skill
is for. An unread long list is not more coverage, and reporting it as though it were is what turns
the dossier into a map that is trusted and wrong.

Seat capability and cost (guidance): a scout reads and cites; it does not weigh, so this work does
not by itself call for the strongest reasoning available. Whoever binds the seat decides, and a
question that turns on complex judgment may still need it. An explicit choice by the human or the
runner stands, this skill never changes its own seat, and every gate above applies unchanged. Do
not claim a saving without measurement.

Searches recorded: all of them, including the empty ones (gate). A search omitted because it found
nothing removes the evidence that the area was looked at.
