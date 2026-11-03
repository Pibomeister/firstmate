# ADR-0013 — An agent starts super-review

**Status:** Accepted.
**Date:** 2026-10-23.
**Authority:** the captain's request that an agent start super-review as part of the work, and that a
human gate on that start blocks work unnecessarily.
**Prior art read:** ADR-0003, ADR-0007, ADR-0008, [`policies/invocation.yaml`](../../policies/invocation.yaml), `skills/super-review/`.

## Context

The invocation law makes a user-invoked skill human-started. `super-review` `full` and `readiness`
were in that class. An agent that had just finished a change stopped and told the captain to type
`/ak:super-review`. The review then waited on a person who had already asked for the work.

The stop was doing no safety work. Reviewers still cannot edit the snapshot. An author still cannot
close a finding or sit a seat. A required lane that cannot be filled is still `unavailable`. Those
rules are what keep a review independent. The typed command was only a start.

Autopilot and a Firstmate worker could already reach the same protocol through `review.full` and
`review.readiness` under a runner-validated grant. A bypass grant could stand in for the typed
command. An ordinary agent, doing ordinary work, had neither, so the review did not run.

## Decision

`super-review` is model-invoked. `full` and `readiness` have authority `model`. The agent doing the
work starts either when a change needs judgment. No slash command and no human act is required.
`delta` stays `active-review-run` and still refuses to open a review run.

The phase operations `review.full`, `review.delta` and `review.readiness` stay as they are.
For each operation's authority and permitted callers, see [`policies/invocation.yaml`](../../policies/invocation.yaml). A bypass
grant remains a valid start for one task and is not required. Where a host cannot validate a grant,
a controller still stops. That stop does not apply to the model start: the model start is the
declared authority, not a side door around the grant.

Starting the review is not approval. The author of the change does not sit a seat, does not close a
finding, and does not supply the verdict.

Align, bound, ship, wayfind and compound stay human-started. This decision does not move them.

## Consequences

- `catalog.yaml` and [`policies/invocation.yaml`](../../policies/invocation.yaml) list `super-review` under model-invoked skills.
- The skill text no longer tells the agent to stop and name a command to type.
- A human may still ask for a review in ordinary language. The agent starts it.
- Seat independence, the immutable snapshot, and the two-cycle cap are unchanged.
- The bypass phases still include `super-review:full` and `super-review:readiness`, so a grant
  already issued keeps working.
