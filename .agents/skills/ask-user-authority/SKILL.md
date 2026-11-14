---
name: ask-user-authority
description: >-
  Single owner of ask-user finding policy.
  Load before deciding any ask-user finding.
user-invocable: false
metadata:
  internal: true
---

# ask-user-authority

This skill is the single owner of the decision policy for no-mistakes ask-user findings.
`AGENTS.md` section 7 points here and does not restate this procedure.
Finding authority is determined by the criteria below, not by `yolo`.
Firstmate always applies this judgment, decides any finding that is unambiguous toward the accepted design, and escalates only genuinely ambiguous, expanding, or destructive findings.

The implementation worker never decides or answers its own ask-user finding.
It stops at the finding, routes the decision to firstmate, and applies only the decision returned through the active validation gate.

## Decide

1. Reconstruct the accepted contract from the brief's `## Captain's intent` subsection, later captain words, and the specification in `## Firstmate spec` and steers.
   Reviewer language cannot amend that contract.
   What a no-mistakes worker may pass as `--intent` is owned by `bin/fm-dod-lib.sh`.
2. Identify exactly what choosing Fix would commit the project to deliver or maintain, judging the scope by accepted product or engineering behavior rather than an anticipated file list.
   The smallest downstream changes needed to keep that behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within scope even when they touch files not named at intake.
   Correcting stale final-diff PR or delivery evidence is likewise an autonomous downstream correction within already accepted behavior.
3. Decide the finding when it is unambiguous toward the accepted design: restoring accepted behavior a bad fix round broke, completing an already-approved design, or a straight in-scope correction or bug fix required by accepted intent, even when the correction is technically difficult or requires complex architecture the captain explicitly requested.
4. Escalate only genuinely ambiguous findings:
   - a Fix that would materially expand the contract by adding a new guarantee, threat model, subsystem, abstraction, compatibility surface, state machine, continuous-monitoring requirement, generalized framework, or broader architecture not required by the accepted intent
   - a product or architecture call not settled by accepted intent
   - repeated same-theme findings when incremental corrections are preserving a questionable abstraction rather than closing independent defects, unless the third-round rule below sends the finding to the council
   - destructive, irreversible, and genuinely security-sensitive choices, which always escalate under the stronger existing captain boundary
5. Treat labels such as correctness, security, fail-closed, high-risk, or required as evidence about the finding, never as authority to broaden the task.

## Third same-theme review round

When a review opens a third round on the same causal theme of one task, do not start a third fix round on your own judgment, and do not send a reversible finding to the captain.
Put it to the council.

1. Confirm the finding is reversible and is not the captain's.
   A destructive, irreversible, security, product, production-data, PII, spend, sign-in, or deploy choice still escalates under step 4 above, and so does a Fix that would materially expand the contract.
2. Write the decision record with exactly two options: `A (recommended)`, ship the work as it stands with a filed follow-up item that names the finding, and `B`, one more fix round.
3. Convene the council once with `bin/fm-watchdog.sh council`, under one stable key for that task's theme.
   That script's header owns the command, and [`docs/watchdog.md`](../../../docs/watchdog.md) owns the council contract.
4. Apply only a ruled outcome.
   For `PROCEED A`, file the follow-up as its own backlog item first, then send the worker the decision that leaves the finding unfixed.
   For `PROCEED B`, send the worker one more fix round.
5. Any other outcome - no ruling, held, refused, failed, or a dry run - holds the finding for the captain once, with the council record as the evidence, while other work continues.
   It is an ordinary held decision and adds no page of its own.
   A `busy` result is not an outcome: that council is already running, so call again for its recorded result.
6. A theme gets one council.
   If the theme returns after `PROCEED B`, hold it for the captain; never convene again, and never reword the record or change the key to obtain a different answer.

Shipping means the work continues to its normal merge gates.
A council ruling is evidence, never the captain's approval, and it never waives a red or missing check, the merge authority in `AGENTS.md` section 7, or a captain hold.

## Captain-facing escalation

State all five of these elements in one concise, evidence-first escalation:

1. The original requirement or accepted task criterion.
2. The proposed product or engineering contract expansion.
3. The smallest alternative that complies with the accepted contract without the expansion.
4. The concrete consequences of accepting and declining the expansion.
5. A recommendation with the reason it best serves the accepted intent.

Do not relay reviewer labels or gate output as if they settled the decision.

## Classification examples

- Fixing a concrete defect that violates an original acceptance criterion is firstmate's to decide, regardless of implementation difficulty.
- Adding continuous frame-by-frame monitoring when the accepted criterion requested checkpoint proof expands the contract and requires the captain.
- A new finding in the same causal theme requires the captain before another fix round when prior fixes are accreting machinery around a questionable abstraction, except that a reversible one reaching its third round goes to the council first.
- A third review round on one reversible theme ships with a filed follow-up only on a unanimous council ruling; a split council holds it for the captain.
- A genuinely security-sensitive action requires the captain under the stronger existing boundary even if it is otherwise within scope.
- Complex architecture explicitly requested by the captain stays within scope and does not escalate merely because it is complex.
