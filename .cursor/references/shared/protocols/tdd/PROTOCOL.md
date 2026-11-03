# tdd

No production code for a behavior change without a failing test first. A violation is not patched
around: the violating code is deleted and the cycle restarted. Work that genuinely cannot be
red-green tested carries a recorded alternative verification plan — never a silent exemption.

Three donors converge on this independently, which is why it is stated without hedging: watch the
test fail for the reason you expect before you trust green, do not re-run an unchanged
verification command and call it new evidence, and test vertical slices rather than layers.

## When to use

`super-build` invokes this protocol inside every implementation ticket that changes behavior.
`diagnose` invokes it for the reproduction step of a bug, before any fix exists. `ultraqa` and
`super-verify` consume the receipts it produces but do not run the cycle themselves.

## Not for

- Not for a pure refactor with no behavior change. The existing suite staying green is the
  evidence; a new red step is not required.
- Not for closing a finding. A green receipt is an input to closure, and closure is
  `apply-findings`' step under its own rules (ruling `closure-requires-independent-verification`).
- Not for deciding what to build. Acceptance criteria arrive on the approved ticket.
- Not for writing the fix a diagnostic work packet already carried. Diagnosis emits either a
  verified bounded patch or a packet, never both, and a patch is never re-implemented from a
  packet that already held one (ruling `diagnose-patch-or-packet-never-both`).

## Invoked by

`super-build` and `diagnose`, and the `qa.cycle` and `ci.repair` phase operations where they
reach a behavior change. `bound.run` is not an invoker: it names verification commands and does
not run them, so it never reaches a behavior change. A protocol holds no authority of its own and
never widens the authority it was called with (ruling `entrypoint-phase-operation-split`;
protocol [`phase-operations`](../phase-operations/PROTOCOL.md)).

## Inputs

- An approved ticket ([`schemas/ticket.schema.json`](../../schemas/ticket.schema.json)) with `acceptance_criteria` and
  `allowed_changes`, or — for the bug path — a diagnosis naming the reported symptom and the
  hypothesis stated before any edit.
- The repository's actual verification command, discovered from the repository rather than
  assumed. A protocol that hardcodes a runner passes silently on a project that uses another
  one. No discoverable command: stop and return `needs-input`.
- The seam: the public boundary the tests will be written against, proposed and confirmed before
  the first test is written. An unconfirmed seam produces tests coupled to whatever the
  implementation happened to expose first.

## Workflow

1. Discover the verification command and record it with the ticket. Record the environment
   identity it runs in.
2. Propose the seam — the public interface under test — and get it confirmed. Record it.
3. Write one failing test against the seam, expressing one acceptance criterion or, on the bug
   path, reproducing the reported symptom.
4. Verify RED: run the command and read the failure. It must fail, and fail for the reason
   expected. A test that fails on a typo in the test, an import error or an unrelated defect is
   not a red step; fix the test and repeat.
5. Write the minimum production code that makes it pass. Nothing beyond the ticket's
   `allowed_changes`.
6. Verify GREEN: run the command again and read the pass. Confirm it passes because the new code
   path ran, not incidentally.
7. Refactor with the test green, re-running the command after each change.
8. Emit a [`schemas/verification.schema.json`](../../schemas/verification.schema.json) receipt carrying the command, exit status, output
   digest, source revision and environment identity, bound to the revision under test (ruling
   `closure-requires-independent-verification`).
9. Repeat from step 3 for the next criterion. One criterion per cycle.

## Hard gates

Gate: production code written before its failing test is deleted and the cycle restarted from
step 3. It is not kept as reference, not commented out and not grandfathered.

Gate: a red step that was never observed failing is not a red step. A test written after the
implementation is a regression test, and this protocol does not accept it as the cycle's
evidence.

Gate: a green run recorded against a different revision does not carry forward. A changed patch
does not inherit stale receipts (ruling `closure-requires-independent-verification`).

Gate: an agent's description of a green run is not a receipt. A receipt carries the command or
probe, exit status, output digest, revision and environment identity (ruling
`closure-requires-independent-verification`).

Gate: work that genuinely cannot be red-green tested emits a recorded alternative verification
plan — the probe, manual reproduction or inspection actually performed, as
[`schemas/verification.schema.json`](../../schemas/verification.schema.json) with `kind: probe` or `kind: manual`. An absent plan is a
stop, not an exemption.

Gate: mocks sit at system boundaries only — network, filesystem, external service. An internal
module boundary is not mocked. Preference order is real, then fake, then stub, then mock; a
heavier double is used only when the lighter one is genuinely unavailable.

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "The code is already written and obviously correct; I will add the test now." | The red step is the evidence that the test can fail at all. A test written against working code has never been observed failing, so it proves nothing about the behavior it claims to protect. | Delete the production code, write the failing test, watch it fail, then write the code again. |
| "It is green, so the cycle is done." | A test can pass without exercising the new path — wrong assertion, wrong fixture, unreached branch. Green for the wrong reason is the failure the verify step exists to catch. | Read the green output and confirm the new path ran. If it did not, the test is wrong, not the code. |
| "This is a spike / the deadline is today / I will backfill tests after." | Time pressure is the recorded condition under which this discipline is abandoned, which is why it is stated as an absolute rather than a preference. | Run the cycle. If the change genuinely cannot be tested, record the alternative verification plan; that is the only exemption and it is written down. |
| "This behavior cannot be tested, so no verification applies." | Untestable-by-unit-test and unverifiable are different claims. Every donor here assumes some verification artifact exists. | Record what was actually done — probe, manual reproduction, inspection — as a receipt with `kind: probe` or `kind: manual`. |
| "The bug report described the failure, so the reproduction is the fix's test." | A reproduction that fails for a different reason than reported hides the real defect and passes once something unrelated changes. | Watch the reproduction fail for the reported reason specifically, before writing the fix. |
| "The diagnosis packet already contains the fix; I will implement it here." | Diagnosis emits a bounded patch or a packet, never both, and a patch re-implemented from a packet that carried one is the same work done twice under two authorities (ruling `diagnose-patch-or-packet-never-both`). | Take a packet as a work source for a ticket; take a patch as already produced. Do not convert one into the other inside this protocol. |

## Outputs

One [`schemas/verification.schema.json`](../../schemas/verification.schema.json) receipt per cycle, bound to the revision under test and
linked to the ticket's acceptance criterion. Plus the tests themselves, inside the ticket's
`allowed_changes`. Receipts are recorded as artifacts; project-derived narrative about them is
published through the knowledgebase adapter, never to a path in the working repository
(ruling `central-kb-owns-project-artifacts`).

## Side effects

`workspace-write`, `process-exec`, `artifact-write`. No remote side effects: this protocol
commits nothing and pushes nothing.

## Stop conditions

- `complete`: every acceptance criterion in scope has an observed red step, an observed green
  step and a bound receipt.
- `needs-input`: no discoverable verification command, an unconfirmed seam, or a change that
  cannot be tested and for which no alternative verification plan was supplied.
- `cap-reached`: the invoking operation's cap was reached mid-cycle. Returns the cap and the
  partial receipts.
- `failed`: the verification command cannot run in the recorded environment.
- `cancelled`: the runner cancelled the run.

## Limits

- Criteria per cycle: one (gate). One failing test, one reason it fails.
- Receipt binding: one revision per receipt (gate). A receipt never spans revisions.
- Test shape: the project's configured unit/integration/end-to-end split is a configurable
  starting point, not a count to hit; exceptions are recorded rather than answered with
  meaningless tests (guidance, ruling `numeric-heuristics-are-guidance`).
