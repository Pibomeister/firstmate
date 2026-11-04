# evidence-gate

What the learning runtime may admit into its ledgers from a judge's reply. A judge proposes; this
gate decides what survives, and the runtime, never the judge, does every count that decides it.
The gate exists because the judge is the one part of the loop that can invent, and an invented
lesson that reaches the knowledgebase is release scenario 23 with a history behind it.

The design follows a three-layer split: what happened, what was learned from it, and what is
currently deployed are kept apart, and nothing crosses from one layer to the next without
evidence the layer below can show (research/dossiers/learning.md).

## When to use

- The `ak learn` runtime applies it to every judge reply before writing a pattern page, a working
  memory, a lesson or a skill candidate.
- `compound` applies it when it reads ledger patterns and lessons as evidence for a lesson it is
  capturing: a ledger entry supports a lesson only where it passed this gate.
- `compound-refresh` applies it when it keeps, merges or retires a ledger lesson or guardrail.

## Not for

- Not for deciding whether a lesson is worth having. The counterfactual bar in `compound` decides
  that; this gate decides only whether the evidence cited for it is real and sufficient.
- Not for publishing. A lesson that passes this gate is a `proposeLesson` candidate draft and
  nothing more (ruling `learning-drafts-not-publishes`).
- Not for judging whether an evidence id was attributed to the right claim. See Limits.

## Invoked by

The `ak learn` runtime under the opt-in `learning` profile (ruling
`learning-runtime-is-host-adapter`), and the skills `compound` and `compound-refresh` when that
profile is installed. A protocol holds no authority of its own and never widens the authority it
was called with (ruling `entrypoint-phase-operation-split`; protocol [`phase-operations`](../phase-operations/PROTOCOL.md)).

## Inputs

- The judge's reply, parsed against the output contract the runtime appended to the role prompt.
- The input set: every evidence id the judge was shown for this call. Review event hashes for the
  pattern maintainer; `obs:<n>` observation ids and `S<8 hex>` session ids for the memory roles.
- The ledger as it stands: existing pattern pages, the previous working memory, lesson pages.
- The thresholds, from the runtime's configuration: `AK_LEARN_ACTIVE_AT` (default 2) and
  `AK_LEARN_PROMOTE_AT` (default 3), and the token cap the reflect job was run with.

## Workflow

1. **Parse or fail.** A reply that is empty or that the output contract rejects fails the job. The
   failure is recorded in the ledger's run log and nothing is written from the reply.
2. **Check every cited id against the input set.** An id the judge was not shown is dropped with the
   claim it carries. A new pattern citing no event, or any hash outside the input, is refused whole.
   A memory bullet with no surviving id is dropped. A lesson with no surviving evidence is dropped.
   For the working memory, an observation the reflector flagged in `security_notes` is then
   quarantined, as is a shown observation that a bullet describing an instruction aimed at the agent
   cites; that wording is a backstop, never the primary signal. Every bullet citing a quarantined
   observation is dropped, and so is any bullet, in any section and under any citation, carrying
   text that only a quarantined observation or the summary of its session holds, matched after
   case, punctuation, spacing and Unicode are normalized and across bullet boundaries. The runtime
   writes one fixed `## Unresolved` bullet covering every quarantined observation, from the ids,
   their sessions and the kinds. These drops are counted apart from the id check's.
3. **Count in the runtime.** Pattern counts, sources, pull requests, reviewers and sessions are
   recomputed from the events the gate kept, never read from the reply. An event counted once
   against a page is not counted again on replay.
4. **Set status in the runtime.**
   - A pattern is `active` when its count reaches the active threshold and its events include
     a direct user correction; two distinct reviewers across at least two distinct pull requests
     or two distinct source families; or sightings from at least two distinct sessions.
     Otherwise it is `candidate`. Bots and the runtime's own author labels do not count as
     reviewers. One account repeating a comment on several pull requests is one reviewer.
     The three primary families are review threads (`github`, including replies and reports),
     user corrections (`correction`) and committed knowledgebase findings (`kb-finding`). Other
     sources add no family, pull request or reviewer. Session witnesses come only from
     `claude-mem`, `learn-memory` and `kb-finding`; two collectors of the same session still
     supply one witness. Nightly findings carry their evidence's native session ids, split into
     one event per session; a knowledgebase finding uses its review run id. Missing session ids
     supply no session witness.
   - A resolution event leaves an evidence line and nothing else. It changes no count, source, pull
     request or status, because a reply saying a finding was handled is not a second sighting.
   - An active pattern is promoted to a guardrail draft when its count reaches the promote
     threshold. Only an active pattern promotes; event count alone is insufficient.
   - A lesson is `confirmed` when its surviving evidence spans at least two sessions, and
     `hypothesis` otherwise.
   - A lesson equal to a live lesson in statement and scope, or a pattern equal to another in
     problem, root cause and fix, once case, sentence punctuation, spacing and Unicode are normalized
     (operators and signs such as `!=` and `-1` still count), is a
     repeat: it raises that record's count and `last_seen` and adds its evidence. No second record,
     no match on a title, nothing overwritten. A retired pattern is not a repeat target; restating
     it creates a new pattern page. A new lesson, pattern or guardrail draft lists the
     records its content resembles in the run's result, to amend or supersede; advisory. A
     knowledgebase proposal record keeps them beside the draft, never inside it and never as a relation.
   - A lesson supersedes a `hypothesis` whatever its own status, and a `confirmed` lesson only
     when it is itself `confirmed`. A lesson that is not `confirmed` and names a `confirmed` one
     in `supersedes` leaves both `conflict`, with neither superseded. A target in any other
     status is left as it is.
   - `retired` is sticky: only a human, through `compound-refresh`, retires or revives.
5. **Screen and, where possible, trim the working-memory rewrite.** The prompt targets
   `floor(cap * 0.75)` tokens. After step 2, an otherwise valid rewrite above the cap and at or
   below 1.5 times the cap is trimmed deterministically. The trimmer removes the last bullet
   from the section with the most bullets, choosing the later section on a tie, until it fits.
   It preserves all six headings. Size includes the exact serialized text, its final newline
   and the runtime's security bullet. Reject a trim that cannot fit or fails a validity gate;
   there is no fallback to the untrimmed reply. After this rescue, text above 1.3 times the cap
   is rejected. Reject the rewrite whole when any validity gate fails:
   - any non-heading line appears three or more times;
   - it collapsed below 0.3 of the previous memory's length from under 5,000 input tokens;
   - any of the six required sections is missing;
   - the id check and the quarantine's text scan together dropped more than half of the bullets
     the judge meant as memory. Bullets citing a quarantined observation are left out of both
     counts, since the runtime's bullet replaces them.
   Repetition and collapse checks use the judge's kept text without the runtime's security bullet,
   so that bullet cannot hide a gutted rewrite. A rejected rewrite leaves the previous memory
   in place, does not advance the watermark, and is recorded with its reason.
6. **Hand promotions on as drafts.** A promoted guardrail and a newly confirmed lesson go to the
   knowledgebase as `proposeLesson` candidates (ruling `learning-drafts-not-publishes`).

## Hard gates

Gate: an id the judge was not shown never carries a claim into a ledger. It is dropped with the
claim, never repaired, guessed or matched to the nearest real id.

Gate: the judge never sets a count, a status, an id or a rate (ruling
`learning-judge-is-runner-bound`). A value of that kind in a reply is ignored, not trusted.

Gate: activation requires the count and witness conditions in step 4; promotion also requires its
own count threshold.

Gate: a degenerate rewrite is rejected whole. A gutted memory is worse than a stale one.

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "The judge cited `obs:1204` and the input had `obs:1240`; it obviously meant that one." | Repairing an id is inventing evidence with extra steps, and the gate cannot tell a typo from a fabrication. | Drop the bullet. The next run can cite it correctly. |
| "Five events all say the same thing; that is plenty to make the pattern active." | Event count alone does not establish independent witnesses (step 4). | Keep it a candidate until step 4's condition holds. |
| "The reply already says count 4 and status active; recomputing is redundant." | A count the judge set is a count nobody checked. | Recompute from the kept events and ignore the reply's value. |
| "The rewrite is only missing one section; keeping the rest is better than nothing." | A partial memory silently loses whatever that section held, and the next rewrite builds on the loss. | Reject it, keep the previous memory, record the reason. |
| "This lesson is clearly right; it only has one session behind it." | One session is a hypothesis however confident it reads. | Record it as `hypothesis`. It is confirmed when a second session supports it. |

## Outputs

Only what passed: pattern pages with runtime-computed counts and status, a working memory whose
every bullet cites a shown id and repeats nothing a quarantined observation alone said, lesson pages whose evidence is a subset of the input, and a run-log
line ([`schemas/memory-run.schema.json`](../../schemas/memory-run.schema.json)) naming what was dropped or why the reply was rejected.
Promotions leave as candidate drafts through the knowledgebase adapter's `proposeLesson`. Nothing
is written inside a project repository.

## Side effects

`artifact-write`, confined to the runtime's ledgers, and `kb-draft` for promotions. Never
`kb-publish`.

## Stop conditions

- `complete`: every claim in the reply was checked and the survivors written.
- `failed`: the reply was empty or unparseable. Recorded, nothing written.
- `blocked`: a working-memory rewrite was rejected as degenerate. Recorded with its reason; the
  previous memory stands.

## Limits

- Active threshold: `AK_LEARN_ACTIVE_AT`, default 2 events, under the independence condition of step 4 (gate).
- Promote threshold: `AK_LEARN_PROMOTE_AT`, default 3 events (gate).
- Confirmation: evidence from at least 2 sessions (gate).
- Known ceiling: the gate catches invented ids, not misattributed ones. A judge that cites a real
  id it was shown, in support of a claim that id does not support, passes. The session threshold
  narrows this, because a misattribution has to recur across sessions to be confirmed; it does not
  close it. Closing it would need a second, independent judge per claim, which this runtime does
  not run.
