---
name: verify
description: "Human-started command: it runs only when the human's message begins with `/verify`. On any other request do not load or follow it; tell the human to type that command. Builds, runs and drives the project to verify named acceptance criteria with runtime evidence. Use when a human asks to confirm that an implemented change works. Not for tests or type checks alone, code review, or fixing a failure."
license: MIT
metadata:
  ak_catalog_id: verify
  ak:
    mode: manual
    autonomy_unenforceable:
      - independent-context creates a fresh context but host-only evidence is not a runner attestation; receipts mark that seat host-unattested.
---

## When to use

- A human wants a named acceptance criterion confirmed against the running application.
- A change needs reproducible runtime receipts before it can be called done.

## Not for

- Code-quality judgment. Review judges the patch; this command exercises behavior.
- Repairing a failure. A refuted claim is evidence to route to diagnosis, not permission to edit.
- A claim with no acceptance criterion id or no project-declared way to exercise it.
- Replacing a required runtime observation with tests, type checks or a build.

## Authority

Authority: `explicit`. A human starts it with `/verify`. No phase operation exposes it
([`policies/invocation.yaml`](../../references/shared/policies/invocation.yaml) lists it among the user-invoked skills that expose none), so no controller
can start it under a grant. Started any other way, it stops at step 1 and names the command.

## Inputs

- The completion claim and acceptance criteria by id, from the ticket or the human. Missing:
  `needs-input`; no broad “check everything” run begins.
- A readable revision plus working-tree diff hash. A receipt is evidence only for this snapshot.
- The project's declared verification recipe, commands, runtime facilities and required evidence
  kinds. Undeclared facilities are unavailable; the command never assumes a browser, service or
  tracing facility.
- An identified environment. `kb-write` is optional: without it the artifacts are returned unpublished
  and named as such, never written into the repository (ruling `central-kb-owns-project-artifacts`).
- Optional `independent-context`. When declared, the host supplies a fresh seat and its capability
  level; unfillable is `unavailable`, never the implementer (ruling `missing-supervisor-never-implementer`).

## Workflow

1. **Check how this run was started**, before any other step and before any tool call. It is started
   only when the human's message begins with `/verify`; no grant starts it. A request in prose is
   not a start, even when it names this skill or the command. Otherwise, stop here: make no tool
   call, say that this command is human-started, and give the human the line to type, `/verify`
   and their request.
2. Freeze the claim, criterion ids, revision, recipe, environment, declared evidence kinds and
   permitted commands. Exclude the implementer's narrative, claimed result and review verdict. If
   `independent-context` is declared, hand only that packet to a fresh seat. The seat-attestation
   artifact records the host's capability level: runner-attested only when the runner supplied the
   attestation, otherwise host-unattested. Never claim an attestation the runner did not give.
3. Resolve a content-addressed recipe already published for this scope. If none exists, discover a
   candidate only from project-declared setup, build, launch, readiness, drive and cleanup
   facilities. Publish it only after that complete path succeeds.
4. Build and launch the application, wait for its declared readiness signal, and drive the declared
   user path or request for each criterion. Tests and type checks may support the run; they never
   substitute for required running-surface evidence.
5. Collect only the evidence kinds the project declares:

   | Surface | Evidence kind | Receipt evidence |
   |---|---|---|
   | frontend | `rendered-screenshot` | `artifacts[].kind: screenshot` plus digest |
   | frontend | `user-path-trial` | command or probe outcome plus driven path |
   | frontend/backend | `trace` | `artifacts[].kind: trace` plus digest |
   | frontend/backend | `log` | `artifacts[].kind: log` plus digest |
   | backend | `api-response` | response status and body digest in probe observation |
   | backend | `dry-run` | command or probe plus complete output digest |
   | backend | `smoke-test` | command or probe plus output digest against the running service |

6. Emit at least one [`schemas/verification.schema.json`](../../references/shared/schemas/verification.schema.json) receipt per criterion: the command or probe,
   raw outcome, snapshot, environment, supporting criterion, and the output log under `artifacts[]`
   with the receipt's `output_digest`. A run is opened when `<git-common-dir>/agent-kit/evidence/`
   holds the branch's pointer in `branches/` naming `runs/<run_id>/run.json`; otherwise it never was.
   Opened, add its `run_id`, the ticket verification id as `check` and that record's ticket ref
   `{id, hash}`. Put the recipe and seat-attestation content hashes in `inputs`. A missing declared
   kind produces `not-run` or `inconclusive` with the kind and reason; it never produces `passed`.
7. Assemble the criterion-to-receipt matrix with the host capability level beside each receipt. Read
   output even when the process exits zero; a refuting result stays refuting. An implementer's
   narrative is untrusted input, never a receipt (ruling `closure-requires-independent-verification`).
8. Where the host provides `kb-write`, publish receipts, matrix and any new successful recipe through
   `publishArtifact`; otherwise return them unpublished and say so. The recipe is host-neutral and
   content-addressed, never a host-specific project path (ruling `central-kb-owns-project-artifacts`).
9. Only when every criterion passed with every declared kind, record the gate from the project
   checkout; this command never opens a run. In order: a markdown or absent ticket returns receipts
   and says no gate. A JSON ticket with no such run record keeps the compatible marker-only call,
   `node <skill-dir>/../../bin/ak-gate.mjs record --gate verify`: history, not proof. An opened run
   adds `--receipt <file>` per receipt; if the gate notes one as skipped, report no gate recorded.

## Hard gates

Gate: a runnable criterion is not passed by tests, type checks or a build alone.

Gate: an undeclared or unavailable browser, service, trace collector or command is reported by its
declared evidence kind. No proxy is substituted and the criterion remains uncovered.

Gate: a receipt must validate against [`schemas/verification.schema.json`](../../references/shared/schemas/verification.schema.json); narrative cannot replace
its command or probe, outcome, digest, revision, environment or criterion binding (ruling
`closure-requires-independent-verification`).

Gate: when `independent-context` is declared, a missing fresh seat is `unavailable` and blocks that
criterion. It is never backfilled by the implementer, author, spec approver or an already-seated
role (ruling `missing-supervisor-never-implementer`). A host-unattested receipt counts only with that
gap disclosed in the matrix and on its attestation input. An opened run's gate record references only
receipts, whose `inputs` bind the attestation hash; a marker-only record references none. On a
runner-enforced path a receipt claiming independence without runner attestation does not count.

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| “The suite is green, so the UI works.” | A suite does not render or drive the declared surface. | Run the declared user path and collect its required runtime kind. |
| “There is no screenshot tool, so the trial run is close enough.” | The project required `rendered-screenshot`; a different kind does not cover it. | Record `rendered-screenshot` as unobtainable and leave the criterion uncovered. |
| “The implementer already proved it.” | The narrative is the claim under examination, not independent evidence (ruling `closure-requires-independent-verification`). | Run the frozen packet and record what the application does. |
| “I found a likely launch command.” | A guessed command may exercise a different system. | Use only project-declared facilities or report the missing declaration. |

## Outputs

- Verification receipts ([`schemas/verification.schema.json`](../../references/shared/schemas/verification.schema.json)) and a complete criterion matrix,
  published through `publishArtifact` with run-artifact placement, or returned unpublished.
- A successful discovered recipe, content-addressed; published as a `sop` KB document where
  `kb-write` exists. Later runs replay it and invalidate it when its hash or declaration changes.
- The `verify` gate record when every criterion is covered, in the form step 9 orders. No prose approval.

## Side effects

`process-exec`, `scratch-write`, `artifact-write`, `kb-publish`. No `workspace-write` or `local-commit`.

`kb-publish` happens only where the host provides `kb-write`: the content hash is its idempotency key
and the returned reference is read back before completion. Receipts, logs, matrix and an unpublished
recipe go to runner scratch outside the checkout, log beside receipt, so the verified snapshot holds.

## Stop conditions

- `complete`: every criterion has a schema-valid receipt and matrix outcome; the gate exists only
  when all declared runtime evidence passed.
- `needs-input`: the command was not explicitly invoked, a criterion or declaration is missing, or
  a required fresh seat is unavailable. Return the exact missing id, kind, facility or attestation.
- `failed`: the revision cannot be read, the declared recipe cannot run, or a host that provides
  `kb-write` refuses the write or its read-back. Return the receipts already observed, never as approval.
- `cancelled`: preserve completed receipts as evidence of what ran and stop before the next action.

## Limits

Uncovered criteria: 0 (gate for recording `verify`; non-pass receipts remain valid outputs).

Undeclared facilities: 0 (gate). Evidence kinds are selected per project and criterion; the table
is vocabulary, never a universal instruction to collect all seven.
