# consensus-plan-gate

Planner snapshot, then architect, then critic on that same fixed snapshot without either seeing
the other's analysis, then synthesis into one whole-plan result. Five rounds maximum.

The independence here is **sequential**: the critic must not be anchored on the architect's
argument. That is the opposite mechanism from `review-delta`, whose two axes run in **parallel**
precisely so neither inherits the other's dispatch context. Both are real; conflating them
breaks one of the two.

## When to use

`super-bound` invokes this protocol at its planning checkpoint, and only for the three cases
[`policies/review.yaml`](../../policies/review.yaml) `consensus_plan_gate.invoked_for` names: genuine architectural
disagreement, high-risk planning, or a review-driven replan. Any skill that reaches a plan whose
direction is contested — rather than whose prose is untidy — reaches it here.

## Not for

- Not automatic on every `super-bound` invocation. A bounded, low-risk plan does not enter this
  gate ([`policies/review.yaml`](../../policies/review.yaml) `consensus_plan_gate.not_invoked`).
- Not for a plan that is merely sloppy, contradictory or missing test scenarios. That is a
  findings pass over a document that is allowed to live; this gate exists for a plan that must
  be allowed to die.
- Not for diff quality. `review-delta` judges a change; this judges a plan. The `architect` seat
  here is [`plan-review/architect`](../../roles/plan-review/architect/ROLE.md), a different seat from any code-review architect lane.
- Not a second planning lifecycle. It produces a verdict on a snapshot `super-bound` owns; it
  never becomes a default step beside it.

## Invoked by

`super-bound`, and the `bound.run` phase operation when a controller advances that phase. A
protocol holds no authority of its own and never widens the authority it was called with (ruling
`entrypoint-phase-operation-split`; protocol [`phase-operations`](../phase-operations/PROTOCOL.md)).

## Inputs

- A plan snapshot produced by [`roles/plan-review/planner`](../../roles/plan-review/planner/ROLE.md), frozen and bound to its
  `common#/$defs/hash`. It states the principles in force, the decision drivers, and the viable
  options actually considered — not a single recommendation with supporting prose.
- The source revision the plan is written against.
- The charter or project record that declares the risk class triggering this gate.

A snapshot with no named alternatives is not ready for this gate: it gives the critic nothing
concrete to attack. Return `needs-input` naming the missing options rather than gating a
recommendation.

## Workflow

1. Freeze the snapshot: record its artifact hash and source revision. Every seat in this round
   reads that hash, never the live plan file.
2. Seat [`plan-review/architect`](../../roles/plan-review/architect/ROLE.md). Its input contains the snapshot and nothing produced by the
   critic seat — the critic has not run.
3. Collect the architect's structural judgment against the frozen hash.
4. Seat [`plan-review/critic`](../../roles/plan-review/critic/ROLE.md). Its input contains the same snapshot hash and **not** the
   architect's output.
5. Collect the critic's pass-or-kill judgment.
6. Synthesize one whole-plan result — `approve`, `iterate` or `reject` — from the two
   independent judgments. Synthesis reconciles; it does not negotiate between the seats and does
   not add a third judgment.
7. On `iterate`, return to the planner for a new snapshot and start a new round at step 1. The
   architect re-runs before the critic in every round; the critic never reviews a plan the
   architect has not seen.
8. On the fifth round without `approve` or `reject`, stop and escalate the unresolved
   architectural question as a `plan-conflict-ruling` checkpoint.

## Hard gates

Gate: the architect and the critic never run in parallel, and neither seat's input ever contains
the other's analysis for the same snapshot ([`policies/review.yaml`](../../policies/review.yaml) `consensus_plan_gate.forbidden`).

Gate: a snapshot mutated between the architect and the critic invalidates the round. The round
restarts on the new hash; it does not continue with two seats judging different plans.

Gate: no mutation of the target repository happens inside this protocol. The gate produces a
verdict; execution waits for the approval the verdict feeds.

Gate: an exploratory or advisory run of this protocol emits no approval. It never completes a
host gate, never authorizes execution, and is never recorded as a passed plan gate.

Gate: a persistent disagreement is not resolved by adding a third seat. The cap stops the loop
and the question goes to a human.

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "Running both seats at once would be faster, and they still answer separately." | Parallel dispatch is forbidden here, and separateness is not the point: the critic's judgment has to be formed without the architect's argument in front of it. | Run the architect to completion, collect its judgment, then seat the critic on the snapshot alone. |
| "The planner already fixed that while the architect was reading; the critic should see the better version." | A snapshot that moved mid-round means the two seats judged different plans, and the verdict covers neither. | Invalidate the round, freeze the new hash, and start round *n*+1 from the architect. |
| "They disagree after five rounds; one more seat would settle it." | A third judgment converts a deadlock into a majority that nobody authorized. The cap exists because repeated disagreement is information about the plan. | Return `cap-reached` and escalate the unresolved question as a `plan-conflict-ruling` checkpoint. |
| "The architect found nothing wrong, so the critic pass is a formality." | The architect is deliberately generous — it builds the strongest version of the plan. A clean steelman is the critic's target, not a substitute for it. | Seat the critic anyway. A round with one seat is an incomplete round, not an approval. |
| "This plan is contested enough that we should gate every plan this project produces." | The gate is invoked for architectural disagreement, high-risk planning or a review-driven replan — not by default. | Route an untidy but uncontested plan to a document findings pass and leave this gate for the cases that name it. |

## Outputs

One whole-plan result bound to the snapshot hash: the verdict, the round number, the architect's
judgment, the critic's judgment, and the decision record the synthesis produced. It carries no
finding buckets. The decision record is published through the knowledgebase adapter's
`recordDecision` in the proposed state, never written to a path in the working repository
(ruling `central-kb-owns-project-artifacts`; [`adapters/knowledgebase/CONTRACT.md`](../../adapters/knowledgebase/CONTRACT.md)).

## Side effects

`artifact-write`, `scratch-write`, `kb-draft`. No `workspace-write`: nothing in the target
repository is mutated by this protocol.

## Stop conditions

- `complete`: synthesis produced `approve` or `reject` on a frozen snapshot within the cap.
- `needs-input`: the snapshot names no viable alternatives, a seat could not be filled
  independently, or the plan's risk class is undeclared.
- `cap-reached`: five rounds without a terminal verdict. Returns the cap object and escalates
  the architectural question.
- `failed`: a seat returned nothing usable against the frozen hash.
- `cancelled`: the runner cancelled the run.

## Limits

- Rounds: 5 (gate, [`policies/limits.yaml`](../../policies/limits.yaml) `consensus_rounds`).
- Judgments per round: two — one architect, one critic (gate). There is no third seat.
- Snapshots per round: one (gate). A new snapshot is a new round.
