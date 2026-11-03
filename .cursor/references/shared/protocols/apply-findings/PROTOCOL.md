# apply-findings

Apply only accepted findings that are specified well enough to implement once, each carrying an
authorization that was granted rather than inferred. A `smell` is never an automatic fixer
ticket. Independent verification closes a finding; the applier's report never does.

## When to use

`super-build` invokes this protocol on the findings its per-ticket checks raised.
`super-review` invokes it between pass 1 and the delta pass, on the findings a disposition
accepted. `babysit-pr` and `receiving-review` invoke it on feedback already assessed into
findings. It runs after a disposition exists and before the delta pass that closes anything.

## Not for

- Not for deciding whether a finding is valid. That judgment belongs to the seat that raised it
  and to the adjudication step; this protocol acts on findings already accepted.
- Not for re-reviewing the result. `review-delta` runs the scoped re-review; this protocol
  applies and verifies one finding at a time.
- Not for raising new findings. Something noticed while applying is reported, not folded into
  the patch.
- Not for producing a fix a diagnostic work packet already carried (ruling
  `diagnose-patch-or-packet-never-both`).

## Invoked by

`super-build`, `super-review`, `babysit-pr` and `receiving-review`. No phase operation invokes
this protocol. A review operation adjudicates a finding and the caller applies it under its own
authorization, which is why `review.full` can hold reviewers to not editing source while this
protocol writes the workspace: they are two authorities, not one widened. A protocol holds no
authority of its own and never widens the authority it was called with (ruling
`entrypoint-phase-operation-split`; protocol [`phase-operations`](../phase-operations/PROTOCOL.md)).

## Inputs

- Findings under [`schemas/finding.schema.json`](../../schemas/finding.schema.json) with `status: accepted`, each carrying
  `spec_quality`, `difficulty`, `autofix_class`, `evidence` and `authorization_ref`. A finding
  arriving from a peer lane with `autofix_class: safe_auto` is remapped to `gated_auto` on intake
  and never dropped — the action class is not a claim about whether the finding is true (ruling
  `safe-auto-restricted-per-seat`).
- The prior-finding packet when this is not the first cycle: `finding_id`, `fingerprint`,
  `severity`, `evidence`, `disposition`, `input_hashes`, `source_revision`
  ([`policies/review.yaml`](../../policies/review.yaml) `continuity`). The seat that closes a finding sees the old finding and
  the new revision; independence is from the author, never amnesia (ruling
  `reviewer-continuity-not-amnesia`).
- The snapshot: comparison base, reviewed head and input hashes.
- The verification command and environment the receipts will bind to.

A finding with no `authorization_ref` is not eligible. Authorization exists only when a human
asked this run to apply its findings, or a runner-validated grant covering `adjudicate-finding`
is in force. It is never inferred from `autofix_class`, from a clean working tree, from how
actionable the finding looks, or from the fact that some later workflow might apply it anyway.

## Workflow

1. Gate on `spec_quality`. `patch` and `sketch` are eligible. `smell` is not: sharpen it, send it
   to diagnosis, or escalate. A `smell` never enters the apply queue.
2. Gate on `authorization_ref`. Absent: return `needs-input` naming the finding, not the fix.
3. Order the eligible findings. Where two would write the same file or symbol, serialize them.
4. For each finding: state the intended change, apply it inside the finding's own scope, and
   nothing else. An adjacent improvement noticed while applying is reported under a
   noticed-but-not-touching heading, never applied.
5. Run the affected tests and checks for that finding, producing a
   [`schemas/verification.schema.json`](../../schemas/verification.schema.json) receipt bound to the new revision.
6. If the receipt fails, revert that fix and re-report it as a finding with the failure as
   evidence. An unverified fix is not finished, and the tree is not left red.
7. Hand the finding to an independent seat for closure. The applier does not close its own work.
8. Return the cycle result: what was applied, what was reverted, what remains open, and the
   receipts.

## Hard gates

Gate: a `smell` is never handed to an automatic fixer. Under-specified work is sharpened,
diagnosed or escalated, and is not guessed at by a second implementer.

Gate: only independent verification evidence, plus a policy rule saying that evidence is
sufficient for this finding, closes it. Reviewer confidence, classifier output, the implementer's
statement that the fix landed, a green run against a different revision, and agreement between
two seats each fail to close it (ruling `closure-requires-independent-verification`).

Gate: a divert — declining to apply an accepted finding — cites which of the four reasons applies
and the specific evidence for it: the finding does not hold, it is no longer relevant, applying
it would make the code worse, or it buys nothing real. A verdict without its evidence class is
not a divert.

Gate: reversing a behavior that a concrete artifact shows was a considered choice requires both
halves of the guard — an artifact proving intent, such as a comment, a test asserting the
behavior or a recorded rationale, *and* a question competent engineers could reasonably answer
differently. "The code currently does X" is not an artifact. With both halves present, escalate;
with one, apply.

Gate: at most two fix-and-verify cycles follow the first pass. The third stops with an explicit
blocked-or-replan decision and the open findings attached (ruling `two-fix-cycles-then-stop`).

Gate: exactly four conditions justify blocking on a human rather than recording a ruling and
continuing — an irreversible or destructive operation, a security-sensitive action, a side effect
outside the isolated workspace, or a plan broken enough that every path forward is a guess.
Everything else gets a recorded ruling; a stall is not a safe default.

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "The finding is vague, but the intent is obvious and the fix is one line." | A `smell` is under-specified by definition; obviousness to the applier is exactly the confidence the grade exists to distrust. | Sharpen the finding to `sketch` or `patch`, or route it to diagnosis. Do not apply it. |
| "This finding is clearly actionable and the tree is clean, so applying it is authorized." | Actionability, a clean tree, the `autofix_class` value and a later workflow's existence are each named as signals that do *not* confer authorization. | Check for an explicit request or a validated grant. Absent both, return `needs-input`. |
| "I applied the fix and read the diff; it is correct." | Reading the patch is the author's confidence, not a receipt, and an author may never close their own finding (ruling `closure-requires-independent-verification`). | Produce the receipt, then hand closure to an independent seat. |
| "Tests fail after the fix, but they were already flaky; keep the fix and move on." | An unverified fix is not finished, and leaving the tree red hides which change broke it. | Revert that fix and re-report it as a finding with the failing output as evidence. |
| "Two seats agreed this is a nit, so I can raise the severity / lower the specificity to make it applyable." | Synthesis may deduplicate, conservatively downgrade specification quality and conservatively raise difficulty. It may never make a ticket easier, more specified or more authorized, and never raises a nit's severity on agreement ([`policies/review.yaml`](../../policies/review.yaml) `synthesis`). | Keep the originating seat's grade. A grade only ever moves in the harder direction. |
| "The third cycle would finish it; we are close." | Repeated failure is a signal about the plan, not an invitation to another loop (ruling `two-fix-cycles-then-stop`). | Stop at two, return `cap-reached` with the open findings and their evidence, and take the blocked-or-replan decision. |
| "The reviewer for this cycle should start clean so it is not biased by the old finding." | Fresh means independent of the author, not ignorant of prior findings; resetting every closure check to amnesia is forbidden (ruling `reviewer-continuity-not-amnesia`). | Hand the seat the prior-finding packet with the fingerprint, evidence and disposition, plus the new revision. |

## Outputs

An updated [`schemas/finding.schema.json`](../../schemas/finding.schema.json) record per finding: `status`, the applied change,
`closure_receipt` with `independent: true` when an independent seat closed it, and
`novelty_evidence` for anything re-reported. One [`schemas/verification.schema.json`](../../schemas/verification.schema.json) receipt per
applied finding. A `common#/$defs/escalation` when the run blocks — need, options, tried,
default, charter rule, blocked finding id — in the same shape every phase operation escalates
with. Recorded rulings and lessons are published through the knowledgebase adapter's
`recordDecision` and `proposeLesson`, never to a path in the working repository (ruling
`central-kb-owns-project-artifacts`).

## Side effects

`workspace-write`, `process-exec`, `artifact-write`, `kb-draft`. No remote side effects: this
protocol does not commit, push, comment or resolve threads.

## Stop conditions

- `complete`: every eligible finding was applied and verified, or reverted and re-reported, and
  nothing eligible remains in the queue.
- `needs-input`: a finding lacks `authorization_ref`, a settled-decision reversal cleared both
  halves of the guard, or one of the four hard-stop conditions was reached.
- `cap-reached`: the second fix cycle finished with findings still open. Returns the cap object,
  the open findings and their evidence.
- `failed`: the verification command cannot run, so no receipt can bind.
- `cancelled`: the runner cancelled the run.

## Limits

- Fix cycles: 2 (gate, [`policies/limits.yaml`](../../policies/limits.yaml) `fix_cycles`).
- Hard-stop conditions: 4 (gate). Everything else is a recorded ruling.
- Divert reasons: 4 (gate), each requiring its own evidence class.
- Findings applied per verification receipt: one (gate). A receipt covering several fixes cannot
  close any of them.
