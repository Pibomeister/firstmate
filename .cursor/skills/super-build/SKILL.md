---
name: super-build
description: Executes one approved implementation ticket in a worktree the ticket owns, test first, then has the result checked on two independent axes before the ticket is reported done. Use when asked to build, implement or execute a ticket ("build ticket T2", "implement AK-214"), including as a worker's task-local implementer, and the ticket names its acceptance criteria and the verification that shows each one met. Not for a decision ticket, an unapproved draft, a finding too vague to specify, or a quick fix with no ticket behind it.
license: MIT
metadata:
  ak_catalog_id: super-build
  ak:
    mode: autonomous
    autonomy_unenforceable:
      - "artifact-write is storage only: the host does not compute or check the artifact hash, so envelope hash binding is this package's own work."
      - kb-write is not provided by the host; the knowledgebase adapter supplies it and refuses rather than falling back to a repository path when no knowledgebase is configured, which is why it does not cap this row while that adapter is attached (ruling `fail-closed-adapter-lifts-ceiling`).
      - "independent-context is not provided by the host: a fresh subagent context exists, but the host does not attest that two contexts are independent, so seat independence is recorded by this package and checked against the ticket's authorship rather than assumed from the host."
---

## When to use

Use when a ticket exists, is approved, is typed `implementation`, and names its acceptance criteria
and the verification that will show each one met. The ticket is the unit of work: one ticket, one
worktree, one implementer, one pass of checks, one commit.

Use when a run has reached its build phase and the ticket at the head of the ready set has no
unfinished dependency — including the dependencies a dependency edge does not express.

Use when a finding from a review lane or a diagnostic packet has already been sharpened into such a
ticket. What decides whether it could be is the finding's own grading, not how actionable its prose
reads.

## Not for

Not for a ticket typed `decision`. A decision ticket asks which of two things to do; executing one of
them answers the question by doing it and calls the answer an implementation. The type field settles
this ([`schemas/ticket.schema.json`](../../references/shared/schemas/ticket.schema.json)), and implementation-shaped prose in the body does not reopen it.

Not for an unapproved or draft ticket. Approval binds to the ticket's artifact hash, so a ticket
edited after approval is unapproved again and re-enters the step that approves it.

Not for a finding that is not yet a ticket. A finding graded `spec_quality: smell`, or carrying
`difficulty: null`, names a doubt rather than a change; sharpening it is a separate act by a lane
that holds that authority, and narrowing it here to something a fixer can act on invents the
specification the grading says is missing.

Not for a bug report with a reproduction and no diagnosis behind it. A bug enters through `diagnose`,
and what reaches this lane is the diagnosed result. A packet that already carried a verified bounded
patch is finished work, and re-implementing it here is the same patch written twice (ruling
`diagnose-patch-or-packet-never-both`).

Not for "just fix this quickly" with no ticket at all. The ticket is what carries the acceptance
criteria, the allowed changes and the write ownership, and a run that improvises them has nothing to
check the result against.

## Authority

Authority: `model`. A controller or a parent skill starts it when an approved ticket is ready; no
slash command exposes it and no human act is required to start it.

No grant covers delegation, because no phase operation exposes this skill —
[`policies/invocation.yaml`](../../references/shared/policies/invocation.yaml) records model-invoked skills as exposing none by construction. What
authority governs here is the ticket rather than the caller: the approval the ticket carries, and the
charter checkpoint the run took before its build phase opened. A skill that cannot see either stops
rather than treating its own invocation as the approval. Under the unattended policy (ADR-0014) that approval is a recorded unattended advance, a ticket whose class makes a human the author is built by the agent with its true class recorded (an exception to ruling `delegation-class-is-authority-not-finding`), and each gate is recorded with its evidence command, as [the unattended-lifecycle reference](../../references/shared/references/unattended-lifecycle/REFERENCE.md) says.

## Inputs

One approved ticket typed `implementation` ([`schemas/ticket.schema.json`](../../references/shared/schemas/ticket.schema.json)), with its
`acceptance_criteria`, `verification`, `allowed_changes`, `read_dependencies`, `write_ownership` and
`integration_owner`. Absent, unapproved, or typed `decision`: stop and report `needs-input` naming
the field that decided it.

A writable checkout the run owns, and a worktree this ticket alone holds (`repository-write`,
`isolated-worktree`, `vcs-local`). Unavailable, or the branch is already checked out elsewhere: stop
and report `failed`.

Two independent contexts for the check seats (`independent-context`). A seat that cannot be filled
independently is `unavailable`, and unavailability blocks the ticket; it is never backfilled by the
implementer, by the author, by whoever approved the spec, or by the other seat (ruling
`missing-supervisor-never-implementer`).

The source finding, where the ticket came from one ([`schemas/finding.schema.json`](../../references/shared/schemas/finding.schema.json)). A finding
arriving from a peer review lane graded `autofix_class: safe_auto` is remapped to `gated_auto` on
intake and is never dropped for its class: the restriction is on emission by a seat, never on the
vocabulary (ruling `safe-auto-restricted-per-seat`).

Optionally a ticket budget from the runner. Absent: the cap is not enforced and not guessed, and the
absence is recorded ([`policies/limits.yaml`](../../references/shared/policies/limits.yaml)).

## Workflow

1. Read the ticket and refuse what this lane does not execute — `decision` type, missing approval, or
   a source finding graded `smell` or carrying `difficulty: null`. Record the refusal with the field
   that decided it. Do not re-grade the finding to make it executable.
2. Decide parallelism by inspection, not by the absence of a dependency edge. For each pair of
   tickets with no edge between them, read the declared write ownership, generated artifacts,
   migration sequence and interfaces, and read the files themselves where a declaration is silent.
   Contention that survives inspection serializes exactly the contending tickets; the rest of the
   layer still dispatches together.
3. Record the base commit, then open the worktree this ticket owns
   ([`protocols/worktree-ownership/PROTOCOL.md`](../../references/shared/protocols/worktree-ownership/PROTOCOL.md)). The worktree handle is bound to this ticket and is
   retired when the ticket integrates, never retasked.
   On the standalone path, open the task-bound run next, from inside that worktree with the
   ticket's branch checked out and before implementation:
   `node <this skill's directory>/../../bin/ak-gate.mjs open --ticket <ticket-file>`. A worker that
   holds a Firstmate binding opens the run with the command its brief gives, which appends
   `--binding <binding file> --dir <evidence store>`, so the run records the binding and the gate
   finds its delegated grants. The run binds
   to the branch checked out where it runs, and later gate commands on that branch resolve the
   pointer it writes. A run never closed by `ship-preflight` stays the branch's default until a
   new `open`, and the gate does not tell an earlier task's unclosed run from this one, so every
   new task opens a new run, even on a branch that already has one.
4. Dispatch one implementer ([`roles/implementer/ROLE.md`](../../references/shared/roles/implementer/ROLE.md)) with the ticket as its single source of
   requirements. It spawns no implementers of its own, and no second implementer runs against this
   worktree. Hand each implementer [the work-trail protocol](../../references/shared/protocols/work-trail/PROTOCOL.md)
   and the location of its own stretch, prepared in the runner's scratch space as that protocol
   says, and no earlier stretch or pointer to one (ruling `work-trail-is-account-not-evidence`).
5. Work the ticket test first ([`protocols/tdd/PROTOCOL.md`](../../references/shared/protocols/tdd/PROTOCOL.md)): a failing test that names the behaviour,
   then the change that passes it. Where the behaviour is genuinely not testable, record the
   alternative verification plan in the ticket rather than proceeding with neither. Load
   [the engineering-principles reference pack](../../references/shared/references/engineering-principles/REFERENCE.md) for the standards the change is held to.
6. Handle the implementer's report by what it says. Concerns about correctness or scope are addressed
   before any check runs; missing context is supplied and the same implementer re-dispatched; a
   blocker is assessed, not returned to the implementer as another attempt at the same wall.
7. Record what was noticed and not touched — file and line, the observation, why it is out of scope.
   Each entry is a candidate ticket, never an edit inside this one.
8. Hand the diff to both check seats at once, as a file, with the ticket's constraints copied
   verbatim from the ticket. Neither prompt carries the implementer's account of the work or any
   expectation of what the seat will find.
9. Keep the axes separate: [`reviewer-spec`](../../references/shared/roles/reviewer-spec/ROLE.md) checks whether the ticket's obligations were met,
   [`reviewer-standards`](../../references/shared/roles/reviewer-standards/ROLE.md) checks the result against the project's own designated rules, rule by rule.
   Findings are not merged or re-ranked across the two; one axis passing does not cover the other.
10. Fix and re-check, at most five rounds per ticket. Rounds one to three resume the implementer that
    already holds the context; rounds four and five dispatch a fresh implementer told how many
    attempts preceded it and that it owns the task from here, and told nothing of their framing. Each
    re-check is scoped per finding — addressed or not addressed — plus the fix diff read for new
    breakage. A resumed implementer continues its own stretch; a fresh one is seated as step 4 says.
11. At the round cap, adjudicate every finding still open, one at a time: park it with a written
    ruling naming why the code stands and what it costs if that is wrong, or rule it load-bearing and
    stop. A silent discard is forbidden.
12. Load [verification evidence](../../references/shared/references/verification-evidence/REFERENCE.md), run the
    ticket's named checks as implementer self-checks and record each receipt with
    `created_by.role: implementer`. They are self-check evidence: once the build gate records the
    implementer seat (step 13) they never satisfy the verify gate, and without it they count only
    for checks no recipe binds. Hand the claim, criteria, frozen revision, project
    recipe and permitted commands to `super-verify`; its verifier seat reruns them and produces
    gate-eligible receipts. Commit the work on the ticket's own branch, then publish the receipts and
    ticket result through the knowledgebase adapter's `publishArtifact` operation.
13. When both check seats pass, record the gate: `node <this skill's directory>/../../bin/ak-gate.mjs record --gate build-checks`
    (the bundle's `bin/`, two directories above this skill). super-ship refuses to ship without it.
    When a runner assigned the implementer seat, declare it by appending
    `--class <delegation class> --author-kind <human|agent> --host <host adapter id> --seat-id <implementer seat>`;
    the seat is recorded on this gate, not on a receipt, and stays declared for commits descended
    from the recorded one. After an amend or rebase, pass the flags again.
    Run it from the project checkout; the run defaults to the branch's opened-run pointer (or the
    branch-named v1 run when none was opened) and records default to the repository's git directory.
    A binding's brief supplies `--dir` for the run opened with it.
14. A committed ticket then runs the trail, steps 14 to 16, a resumed run by the work-trail
    protocol's resume rule; steps 12 and 13 never wait on it (ruling
    `work-trail-is-account-not-evidence`). One stopped before its commit gets no audit or published
    stretch, as the report says; a failed receipt publish stops the build as before, short of the
    trail. Each prepared stretch is handled and sent as the work-trail protocol's build steps say;
    none it holds back is sent. A refused or failed trail publish is never repaired or resent and is
    not itself a build gate; the protocol's stop conditions describe shared-file failures that
    can block later required receipts. The trail writes no gate record; `complete` does not depend on it.
15. Seat [the trail auditor](../../references/shared/roles/trail-auditor/ROLE.md) once, even for an empty or missing
    stretch, in a context that filled no other seat on the ticket and is not the build's own; hand
    it its packet, each unpublished stretch named so, from its location. The audit is unavailable
    with no such context, a binding not permitting the role, a packet it cannot be handed, a failed
    seat, or a returned record not naming kind `trail-audit` and the id it was handed: withhold the
    audit record, not the stretches, block nothing and let no seat fill in, the implementer included
    (ruling `work-trail-is-account-not-evidence`). Otherwise publish the audit exactly as returned.
16. Report every written ruling and out-of-scope observation last, the only existing act waiting on
    the trail, with the audit's reference, result and items or why it is unavailable or unpublished,
    and each missing or unpublished stretch, an unpublished one with its reason. Repeat as given an
    audit notice that something read holds a secret, credential, token or personal data: where it
    is, never the value. For a published stretch or audit, add that it cannot be corrected and the
    value is exposed, for its owner to rotate, as `super-ship` does for a secret in history. The
    attention list and that notice go only in the report and audit record, never in a receipt, check
    result, finding, gate record or checkpoint card (ruling `work-trail-is-account-not-evidence`).

## Hard gates

Gate: a ticket typed `decision` is never executed as implementation work, and never re-typed here to
make it executable. It returns to the lane that resolves decisions.

Gate: a finding graded `smell`, or carrying `difficulty: null`, is refused as an implementation
ticket ([`schemas/finding.schema.json`](../../references/shared/schemas/finding.schema.json)); the shared rule for applying a finding at all is
[`protocols/apply-findings/PROTOCOL.md`](../../references/shared/protocols/apply-findings/PROTOCOL.md). Difficulty without a solution class is not a specification,
and a re-grading performed by the lane that wants to execute it is the refusal being routed around.

Gate: a receipt created by the implementer, change author, spec approver or recipe author is
self-check evidence only. It never fills or substitutes for the verifier seat, even when its command
and output are identical to the later independent run (ruling
`missing-supervisor-never-implementer`).

Gate: neither check seat emits `autofix_class: safe_auto`. At review time a code edit has no single
mechanically correct answer, so a seat's classification is a proposal and applying it is the caller's
decision under its own authorization; `gated_auto`, `manual` and `advisory` are what a seat here may
emit (ruling `safe-auto-restricted-per-seat`).

Gate: the implementer never sits on the panel that checks its work, and no seat approves a patch it
produced. Two seats that are the same context in sequence are one seat (ruling
`missing-supervisor-never-implementer`).

Gate: only independent verification evidence, plus a policy rule saying that evidence suffices for
that finding, closes a finding. A description of a green run is not a receipt — a receipt carries the
command or probe, exit status, output digest, revision and environment identity — and a patch that
changed after a receipt was taken does not inherit it (ruling
`closure-requires-independent-verification`).

Gate: writes stay inside the ticket's `allowed_changes` and its declared ownership. A write outside
every worker's declared exclusive set aborts the wave, and a change no worker accounts for may be the
user's: it is preserved and reconciled, never discarded to get the tree clean.

Gate: a stubbed test, a skipped test, an unimplemented branch or a marker left in place of the work
is a blocker, not progress. The ticket is reported blocked with what is missing.

Gate: the round cap ends the loop, not the adjudication. Reaching it with findings open is a
`cap-reached` result carrying each one and its ruling.

Gate: the wall (ruling `work-trail-is-account-not-evidence`). No seat whose output is a finding, a
receipt, a verdict or a signoff input is shown the trail, the trail audit or the attention list.
Nothing from them reaches a check seat or the verification hand-off, quoted, summarized or as a
pointer, and the build's context carries nothing it saw of them into a ruling it writes, a synthesis
or verdict it sets, or a packet it hands a seat the wall covers, for the same change.

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "The implementer just fixed it and is sitting right there — having it confirm the fix is faster than dispatching a seat." | A seat that cannot be filled independently is unavailable, and unavailability blocks; it is never backfilled by the implementer (ruling `missing-supervisor-never-implementer`). The context that produced the change is the one context that cannot tell you whether it is right. | Mark the seat `unavailable`, stop with `needs-input` naming which seat and why, and report the ticket as not done. |
| "The implementer's report says the tests passed, so the criterion is met." | An agent's description of a green run is not a receipt (ruling `closure-requires-independent-verification`). The report is the author's account of its own work, and it is the thing the receipt exists to replace. | Run the ticket's named verification, record command, exit status, output digest, revision and environment, and bind each receipt to the criteria it supports. |
| "The finding is only a smell, but I can see what it means — I will write the ticket from it." | Difficulty without a solution class is not a specification, and reading a change out of a smell is inventing the one the grading says is missing. The invented specification is then checked against itself. | Refuse it as an implementation ticket, and return it for sharpening, diagnosis or escalation with the field that decided it. |
| "Round five ended with two small findings open; they are minor and the ticket is otherwise done." | A silent discard is exactly what the round cap exists to prevent, and the findings least likely to be written down are the ones a later reader most needs. | Park each one with a written ruling naming what it costs if wrong, or rule it load-bearing and stop; return `cap-reached` with both attached. |
| "These two tickets have no dependency edge, so they can run in parallel." | An edge records a declared dependency, not shared write surface. A shared generated artifact, a migration sequence or one exported interface makes two edgeless tickets contending writers, and the DAG cannot see it. | Read the ownership declarations and the files, serialize exactly the contending pair, and dispatch the rest of the layer together. |
| "The seat should know I already considered the null case, so I will say so in the prompt." | A prompt that says what to expect tells the seat where to stop looking, and the axis returns the author's confidence in the author's own words. | Hand over the diff and the ticket's verbatim constraints, and nothing about what the previous attempt believed. |

## Outputs

One commit per ticket, on the branch that ticket owns, recorded against the ticket by id. The commit
is the patch link the lane's result carries; nothing is merged here.

Verification receipts ([`schemas/verification.schema.json`](../../references/shared/schemas/verification.schema.json)), one per acceptance criterion the ticket
names, each naming the criteria it supports and bound to the revision it describes.

The per-ticket check result: the findings each axis raised ([`schemas/finding.schema.json`](../../references/shared/schemas/finding.schema.json)), their
disposition, and every ruling written at the round cap. A per-ticket check is a lighter instrument
than a review panel — it emits no `review` artifact, and a later panel never reads it as a lane it no
longer has to cover.

All of it is published through the knowledgebase adapter's `publishArtifact` operation with a
run-artifact placement ([`adapters/knowledgebase/CONTRACT.md`](../../references/shared/adapters/knowledgebase/CONTRACT.md)); the commands are in
[the knowledgebase-binding reference pack](../../references/shared/references/knowledgebase-binding/REFERENCE.md).
This skill names no repository path for project-derived content. Each implementer seat's stretch
([`schemas/trail.schema.json`](../../references/shared/schemas/trail.schema.json)) and the trail audit ([`schemas/trail-audit.schema.json`](../../references/shared/schemas/trail-audit.schema.json)) go through
`publishArtifact` too, as an account, never evidence (ruling `work-trail-is-account-not-evidence`).

## Side effects

`workspace-write`, `branch-create`, `local-commit`, `process-exec`, `artifact-write`, `kb-publish`,
`scratch-write`.

`kb-publish` is a remote effect: the idempotency key is derived from the content hash of the
published set per [`adapters/runner-contract/CONTRACT.md`](../../references/shared/adapters/runner-contract/CONTRACT.md) §5, and the returned record reference is
read back before the ticket reports. Republishing unchanged receipts, ticket results and check
results after an interruption is a no-op success. Trail and trail-audit records instead follow the
attempt-mark and resume rules in [the work trail protocol](../../references/shared/protocols/work-trail/PROTOCOL.md).

No `remote-push`, no `pr-open`: a commit on an owned branch is where this lane ends.

## Stop conditions

`complete`: the ticket is committed, every acceptance criterion has a receipt bound to the committed
revision, and every finding either closed on that evidence or parked with a written ruling.

`cap-reached`: the fifth fix round ended with findings still open. Returns the cap, the commit as it
stands, and every open finding with its adjudication. It is not a pass and the ticket is not done.

`needs-input`: no approved ticket, a ticket typed `decision`, a source finding too vague to specify,
or a check seat that cannot be filled independently. Returns what is missing and the lane that owns
it, never a narrowed version of the work.

`failed`: no writable worktree, the branch is checked out elsewhere, or the knowledgebase refuses a
receipt, ticket result or check result. The worktree and the ledger are left intact for the resume.

`cancelled`: the caller withdrew the ticket mid-run. The branch, the worktree and the recorded
rulings are kept rather than cleaned up, because the next run reads them instead of re-deriving them.

## Limits

Fix rounds: 5 per ticket (gate). Rounds one to three resume the same implementer; four and five
dispatch a fresh one. This is the per-ticket implementer-and-check loop, and it is not
[`policies/limits.yaml`](../../references/shared/policies/limits.yaml)'s `fix_cycles`, which bounds the fix-and-verify cycles that follow a review
run's first pass and does not name this skill. Two caps, two scopes, and neither relaxes the other.

Implementers per worktree: 1 (gate). Parallel dispatch is across tickets, never inside one.

Parallel tickets: a bounded batch rather than every independent ticket at once (guidance). A unit too
small to outweigh its own dispatch runs inline or batched with related units; the runner's ticket
budget is the only cap this skill enforces on how many start.

Changed-line target and test-pyramid shape: guidance, not a gate; configurable per project, neither
validated nor enforced, not on its own grounds for a finding, an exception recorded rather than an artificial
split or a meaningless test. [The reference loaded at step 5](../../references/shared/references/engineering-principles/REFERENCE.md)
states each (ruling `numeric-heuristics-are-guidance`). Reads of the calling agent: [read-economy](../../references/shared/references/read-economy/REFERENCE.md).
