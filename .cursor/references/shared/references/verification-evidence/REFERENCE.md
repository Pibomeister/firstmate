# Verification evidence

This reference supplies the shared vocabulary for observable runtime success. Projects declare the
facilities they actually have; tickets select from those declarations; verifier receipts report what
ran. No skill assumes a browser, service, trace collector or command from a framework convention.

## Recipes

A verification recipe is host-neutral and content-addressed. It names its scope, environment,
surfaces, available evidence kinds and permitted steps in this order:

1. `setup` prepares declared dependencies without changing product source.
2. `build` produces the runnable artifact.
3. `launch` starts the application or service.
4. `readiness` proves that the launched subject is ready to be driven.
5. `drive` exercises the named user path or request.
6. `cleanup` ends the launched processes and removes scratch state.

A project declaration may contain several recipes with different scopes. A missing step or facility
is a visible gap. Discovery may form a candidate from project files, but the candidate becomes a
published recipe only after the complete path succeeds. The artifact is published through the
central knowledgebase; it is never written to a host-specific path in the application tree (ruling
`central-kb-owns-project-artifacts`).

## Criterion binding

`ticket.acceptance_criteria[].surface` is `frontend`, `backend` or `none`. A `frontend` or
`backend` criterion needs at least one supporting check that declares `evidence_required`; a ticket
that declares no surface is treated as `none`. Each named verification check binds its supported criteria to one recipe id and hash plus one or more `evidence_required`
kinds. The recipe declaration must advertise every selected kind. An undeclared facility does not
become available because a check can approximate it.

The recipe hash is evidence input. A changed recipe or project declaration requires a new ticket
binding and new receipts; an older receipt does not inherit the new path.

## Evidence kinds

| Surface | Evidence kind | Receipt representation |
|---|---|---|
| frontend | `rendered-screenshot` | `artifacts[].kind: screenshot` and its digest |
| frontend | `user-path-trial` | Command or probe outcome plus the driven path in probe parameters |
| frontend/backend | `trace` | `artifacts[].kind: trace` and its digest |
| frontend/backend | `log` | `artifacts[].kind: log` and its digest |
| backend | `api-response` | Numeric response status, complete body digest and a `response` artifact |
| backend | `dry-run` | Command or probe with complete output digest |
| backend | `smoke-test` | Command or probe with complete output digest against the running service |

The table is a vocabulary, not a universal checklist. A project chooses the kinds each check needs.
Tests, type checks and builds may support a runtime receipt but never substitute for a required kind.

## Receipt and seat lineage

A surface receipt binds the source revision and diff hash, environment, ticket check, recipe id and
hash, evidence kind, every artifact digest, and the verifier seat. `api-response` also binds status
and body digest. Narrative is not evidence (ruling `closure-requires-independent-verification`).

The verifier seat record names its id, the implementer seat, and one isolation state:

- `runner-attested`: the runner recorded distinct context and excluded lineage outside the worker's
  writable scope. This is eligible for autonomous closure.
- `host-unattested`: the host created a fresh context but cannot attest what it saw or its lineage.
  This remains useful guided evidence and never claims autonomous independence. The gate counts it
  only for a human-typed ship, with a visible note, as worker-attested evidence. It refuses it once
  the build gate records the implementer seat, or once the run holds any bypass or delegated grant
  record, and the refusal names the record. Under the opt-in unattended policy (ADR-0014) it is
  counted with a recorded note instead, whose boundary is the live merge-gate read (an exception to
  ruling `closure-requires-independent-verification`). A bypass check made before the lifecycle run
  is opened does not mark that run. A delegated grant is found through the binding
  the run was opened with (`open --binding <binding file>`): the run record keeps the binding's run
  id and evidence store, and the gate reads the grant records there whatever store the run itself
  uses. A run opened without it does not see the binding's grants. The mark holds for the rest of the run, even after a person takes over:
  guided shipping by hand needs a fresh run. It is never relabeled `runner-attested`.

The local lifecycle gate checks the attestation's shape only: an id and hash are present and the
seat ids differ. It does not resolve the attestation, and it cannot tell a runner-written record from
one a worker wrote. The runner's enforcement of seat identity, excluded lineage and storage outside
the worker's writable scope is what makes an attestation trustworthy; without a runner, a
`runner-attested` receipt is only the worker's claim.

Independent verification is declared available when the build gate records the implementer seat.
Then every counted receipt, `surface: none` included, must name a runner-attested verifier seat
distinct from that seat (under the unattended policy, a distinct host-unattested seat with its recorded
note; never the implementer's own). Without that record, only checks bound to a recipe require a verifier seat,
which keeps older tickets and receipts compatible. A seat recorded at one commit stays declared for
its descendants; a record whose commit an amend or rebase removed from history no longer counts, so
the build gate is recorded with the seat again after a history rewrite.

The verifier is never the implementer, change author, spec approver, recipe author for the change or
a seat already used on the same decision. An ineligible or unfillable seat is `unavailable`; it is
not backfilled (ruling `missing-supervisor-never-implementer`).

## Completion predicate

A criterion is covered only when current passed receipts carry every kind its ticket check requires,
all corresponding artifacts are present and digest-valid, the recipe binding matches, and the
verifier seat is eligible for the requested mode. One generic passing test cannot cover a missing
screenshot, trace, API response or running-service trial. A recorded failure bound to the current
revision and diff remains evidence even when malformed; a passing receipt re-recorded under its id
cannot erase it. Changed code needs fresh evidence.
