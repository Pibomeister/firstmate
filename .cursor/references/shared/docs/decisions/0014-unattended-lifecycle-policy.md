# ADR-0014 — An opt-in unattended policy runs the lifecycle; merge is the human gate

**Status:** Accepted.
**Date:** 2026-10-29.
**Authority:** the project owner's decision that runners with no human present run the whole lifecycle
without human gates, that the only human gate is merging the pull request, and that the mode serves any
runner. The specification and implementation were approved under delegated authority by the
supervising orchestrator, not by a human reading the generated artifacts.
**Prior art read:** ADR-0003, ADR-0007, ADR-0008, ADR-0013, [`policies/invocation.yaml`](../../policies/invocation.yaml),
`src/lifecycle/gate.ts`, [`adapters/runner-contract/CONTRACT.md`](../../adapters/runner-contract/CONTRACT.md).

## Context

A human-started phase starts by a typed command, a delegated grant, the standing autopilot grant of
ADR-0007 or a supervisor's bypass grant. A CI job, a scheduled job, a chat bot, a coding-agent
platform or a supervised worker with nobody watching holds none of them honestly. Autonomous ship also
refuses a host-unattested verifier once a seat or grant is recorded, and the runner-attested path that
would lift that refusal does not exist. Such a runner therefore cannot finish the lifecycle at all.

## Decision

A named policy, `unattended`, selected only by explicit opt-in: `AK_LIFECYCLE_POLICY=unattended` in the
runner's environment, or `ak.lifecycle.json` naming it on the repository's default branch. Absent both,
every record, decision and exit status is unchanged. The policy is runner-neutral. Its behaviour is
[`references/unattended-lifecycle/REFERENCE.md`](../../references/unattended-lifecycle/REFERENCE.md); the decisions it rests on are:

- **Start.** align, bound and ship start through the gate tool's `unattended check`; scout, build, verify and
  review were already model-started. A typed command still starts a phase. A bypass grant is refused, so
  a record never carries both authorities.
- **Advance.** A wait for a human answer or approval proceeds with the skill's own recommendation,
  recorded as an unattended advance and never as an approval. A ticket whose class makes a human the
  author is implemented by the agent with its true class, floor and author kind recorded. Every other
  stop, every sensitive action included, still stops.
- **Evidence.** Every gate records the policy and the commands the gate tool ran, with exit status,
  output digest, revision and times. Align, bound and scout gain gates under this policy, recorded
  before the run opens and imported into it with their original times. The pre-ship check requires all
  six earlier phases current and passing. The evidence is worker-attested and labelled so.
- **Trust moves to the merge.** A host-unattested verifier is a recorded note instead of a refusal; an
  implementer still cannot verify its own work. In exchange, ship-preflight reads the target repository
  live and read-only and refuses unless its default branch requires code-owner review by operator-
  designated human reviewers with stale approvals dismissed and last-push approval, required CI pinned to
  an app, and the independent review check pinned to an app that is not GitHub Actions, with no bypass;
  and unless the runner is a non-admin, non-designated user account. Final ship success needs the posted
  review valid at the pull request's exact head, the head descended from the shipped revision, and the
  disclosure in the pull request text.
- **Independence.** The independent review is a required check posted from outside the task by a pinned
  app, from the head-bound diff only. The reviewer's canonical `provider/model` identity is stamped from
  operator configuration and the provider's call metadata, never from the review's own text, and must
  differ from every configured author model; the same provider is allowed. This is a deterministic check
  against operator-declared evidence. The catalog names no model, provider or route.

For this policy only, this amends: the invocation law's start rule for align, bound and ship, with the
ordinary-workers clause of ruling `entrypoint-phase-operation-split` and the start-path statements of
[`protocols/invocation-authority.md`](../../protocols/invocation-authority.md) and the runner contract; the maintainer guide's statement that
worker-attested evidence never lifts an autonomy ceiling; the host-unattested verifier refusal in
super-ship, super-verify, super-review and the verification-evidence reference, an exception to ruling
`closure-requires-independent-verification`; the delegation reference's rule that a human-author class
makes a human the author, an exception to ruling `delegation-class-is-authority-not-finding`; and the
rule that seat independence is never a model identity (`AUTHORING.md` section 7,
[`adapters/runner-contract/CONTRACT.md`](../../adapters/runner-contract/CONTRACT.md) section 3), for the forge-side review check alone. Each rule's
text carries its scoped exception beside it; runner-filled seats and every run outside the policy are
unchanged. Merge and deploy stay outside every policy.

## Consequences

- A repository without the enforced merge gate cannot finish an unattended ship; the refusal names
  every missing item.
- The forge cannot show that a designated account is operated by a person, that a review used the model
  it reports, or that a fine-grained read credential is read-only. A runner sharing the operator's account
  or credentials does not meet the policy's assumptions.
- A pull request head rewritten after ship-preflight needs a new run; old phase evidence never covers it.
- The signed-issuer and runtime-attested paths are unchanged and not required by this policy.
