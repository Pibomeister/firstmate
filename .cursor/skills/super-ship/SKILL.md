---
name: super-ship
description: "Human-started command: it runs only when the human's message begins with `/super-ship`, or under a validated grant, or when a supervisor's bypass grant passes the bundle's `ak-gate.mjs bypass check`, or when the repository or environment opts into the unattended policy and `ak-gate.mjs unattended check` exits 0. On any other request do not load or follow it; tell the human to type that command. When prose asks for this publication work on a reviewed change, do not inspect the branch or act; tell the human to type `/super-ship` followed by their request. Prepares a verified, reviewed commit for publication: release checks, a sensitive-data scan, the pull-request payload and the linked knowledgebase draft. Runs dry, generating the payload locally and pushing nothing, or publishes under a grant. Use when a reviewed, verified change must become a committed handoff or pull request. Not for merging, not for deploying, and not for deciding whether the change is correct."
license: MIT
metadata:
  ak_catalog_id: super-ship
  ak:
    mode: manual
    autonomy_unenforceable:
      - suppression of model invocation, which this package no longer requests on this host (docs/decisions/0003-model-invocation.md). The authority step is the gate.
      - idempotency is not provided by the host. The key is derived and the read-back performed by this package; the host neither stores the key nor refuses a duplicate effect.
      - grant validation is the runner's. Where the host cannot validate a grant, the entrypoint stops for explicit invocation rather than running on an unchecked claim.
      - kb-draft is not provided by the host; the knowledgebase adapter supplies it and refuses rather than falling back to a repository path when no knowledgebase is configured.
      - "trusted evidence is not provided by the host: the worker can write every record the gate reads. The autonomous form stops with needs-input there, and the manual form remains open."
---

## When to use

Use when the committed change has current verification and review records and needs a no-mistakes
handoff, or a pull request under a delivery path that super-ship owns.

Use when a caller wants the pull-request payload without publishing it: the title, the description,
the linked evidence and the branch plan, generated locally and pushed nowhere.

Use when a change is about to become public and the pre-flight checks — secrets, dependencies, the
project's own release gates — have not been run and recorded against this head.

Use when an interrupted ship has to be resumed and the question is whether the remote effect already
landed.

## Not for

Not for merging and not for deploying. Both are sensitive actions that are never granted by default:
each needs an explicit charter entry a human approved up front, naming the action and exactly what is
permitted, bound to that charter's hash (ruling `sensitive-actions-need-approved-charter-entry`). A
run approved to open a pull request has not been approved to finish the job.

Not for deciding whether the change is correct. This skill reads the review verdict and the
verification receipts; it does not form its own opinion about the code and never ships around a
missing one.

Not for watching the pull request once it is open. CI results, review comments and base-branch
changes belong to the watch lane, and a ship that opened a PR is not finished until that lane owns
it.

Not for writing project knowledge into the repository. Decisions, lessons, reviews and sanitized run
receipts are owned centrally; this package owns reusable instructions and templates only, and a completed ship is
not permission to rewrite project knowledge (ruling `central-kb-owns-project-artifacts`).

Not for force-pushing or rewriting history to make a branch land. Both are sensitive actions with the
same charter requirement as merge.

## Authority

Authority `explicit-or-delegated`, invocation U. A human starts it by typing `/super-ship`, or a
delegated controller starts the same protocol through the declared phase operation `ship.prepare`
under a runner-validated grant covering `ship-pr`. A request in prose is not a start, even when it
names this skill or the command.

There is one protocol behind both doors. Where the host cannot validate a grant, the entrypoint stops
for explicit invocation rather than reproducing the delegated effect through a side door (ruling
`entrypoint-phase-operation-split`). A lesson candidate may be drafted inside the run; publishing it
needs explicit authority or a charter grant.

Under a Firstmate binding, Firstmate is the delegated controller and the host validates the grant with
`ak firstmate grant --binding <path> --operation ship.prepare`. Exit 0 is the grant: cite the record it
prints in the ship record. A refusal means stop and report `needs-decision` to Firstmate. The grant
covers the binding's delivery action and nothing more; merge is never on it (ADR-0004).

Under a bypass grant (ADR-0008), a supervisor-held file stands in for the typed command for one
task. From the task's worktree, run `node <this skill's directory>/../../bin/ak-gate.mjs bypass check --grant <path> --task <id>
--phase super-ship`: exit 0 is the start, and a refusal is a stop with
`needs-decision`. The grant starts the ship and nothing else: it runs as the explicit form up to the
first remote call, as in `dry-run`, and every remote effect waits for the supervisor's answer to a
`needs-decision`. Record `ship-preflight` with `--bypass <path> --task <id>`. Merge and deploy are never on it.

Under the unattended policy (ADR-0014), `node <this skill's directory>/../../bin/ak-gate.mjs unattended
check --phase super-ship` exiting 0 is the start (an exception to ruling `entrypoint-phase-operation-split`). `record --gate ship-preflight` then reads the merge
gate live and closes the run only when it holds. Put the disclosure it prints in the pull request text
(under no-mistakes delivery, by editing the opened pull request's text once the pipeline returns, the
only pull-request write) and record final ship success with `--pr <n>`, as
[the unattended-lifecycle reference](../../references/shared/references/unattended-lifecycle/REFERENCE.md) says.

For the autonomous form, `ship.prepare` delegated under a grant, exit 0 is necessary and not
sufficient. That form also needs trusted evidence: gate evidence the runner recorded into the run's
evidence store, outside this worker's reach ([`adapters/runner-contract/CONTRACT.md`](../../references/shared/adapters/runner-contract/CONTRACT.md) §2). Gate records
this worker wrote are worker-attested, and no grant turns them into trusted evidence.

## Inputs

The head being shipped, named. Verification receipts that bind to that head
([`schemas/verification.schema.json`](../../references/shared/schemas/verification.schema.json)), and a review verdict that binds to that head's artifact hash
([`schemas/review.schema.json`](../../references/shared/schemas/review.schema.json)). Any of the three missing or bound to a different revision: stop with
`needs-input` naming which.

The mode: `dry-run` or `publish`. `dry-run` is a supported mode of this skill, not a flag an operator
has to remember; it is the mode in which nothing leaves the machine. The transport, `direct` or
`no-mistakes`: the task's delivery contract's, else the project conventions', else the caller's;
named by none, the run stops with `needs-input` naming the choice (ruling
`direct-push-as-ship-transport`).

The charter, where one exists ([`schemas/charter.schema.json`](../../references/shared/schemas/charter.schema.json)), with the actions it names and the
approval bound to its hash. Absent, the run has no sensitive-action authority and does not acquire
any by running.

The idempotency inputs the runner supplies: the run id, the operation id, the target identity and the
input artifact hash ([`adapters/runner-contract/CONTRACT.md`](../../references/shared/adapters/runner-contract/CONTRACT.md) §5).

The project's own release checks, discovered rather than assumed.

## Workflow

1. Check how this run was started, before any other step and before any tool call but the grant
   check. It is started only when the human's message begins with `/super-ship`, or when a
   controller started the phase operation `ship.prepare` under a validated grant; under a Firstmate
   binding the grant check is the `ak firstmate grant` call in Authority, and under a bypass grant
   it is the bypass check there; under the unattended policy it is the unattended check there; a
   refusal is a stop. A request in prose is not a start, even when
   it names this skill or the command, or asks for this work without naming either. With neither,
   stop before inspecting the branch, checking prerequisites or answering the task: the only
   response is to tell the human to type `/super-ship` followed by their request.
2. Resolve the mode. `dry-run` and `publish` follow the same steps up to the first remote call;
   `dry-run` stops there.
3. Run the sensitive-data scan over what would be committed. A candidate secret stops the run;
   where one was already committed, report it for rotation. Before any text goes to the forge, run
   `node <this skill's directory>/../../bin/ak-gate.mjs publish-scan --repo <owner/name> --visibility
   <v> --title <title> --body-file <file> --commits <base>..<head>` on the pull-request text: a hit
   on the operator's internal markers stops the run; no markers file is recorded as not run.
4. Run the dependency-audit triage and the project's release checks. Record each outcome against
   the head, including checks that did not run.
5. Require build or repair to have committed the named owned paths before verification and review.
   Direct publication uses `./references/transport-direct.md`'s commit preparation there; it never
   creates a commit after the ship checkpoint. A missing commit returns to build or repair.
6. For either transport, require a committed head, verify, readiness and an approved full or
   delta review recorded after its commit, and an empty diff; otherwise stop.
7. At that snapshot, run `node <this skill's directory>/../../bin/ak-gate.mjs check` for current
   verify, readiness and approved full or delta review. A refusal is `needs-input`; delegated
   authority also requires runner-recorded trusted evidence. Load
   [verification evidence](../../references/shared/references/verification-evidence/REFERENCE.md) and re-hash any
   declared surface artifacts. On pass, record `ship-preflight` there, with an empty diff for
   either transport. A binding supplies its evidence directory; a bypass uses `--bypass <path>
   --task <id>`. Recording closes the run; a changed head needs a new run
   and fresh gates. Compose any PR payload from the ticket, receipts and verdict, linking the recipe,
   acceptance-to-evidence matrix and evidence digests with the delegation class, sensitive factors,
   risks and rollback fields.
8. For no-mistakes delivery, stop at this immutable handoff (under the unattended policy an intermediate one). Do not push, open a PR or pass a skip;
   the task's no-mistakes delivery contract owns the branch from here. Follow
   `./references/transport-no-mistakes.md` (ruling `no-mistakes-as-ship-transport`). A deprecated
   legacy `agent-kit` publish binding follows that reference's legacy publish procedure instead.
9. For a direct publication path, reconcile open PRs against the resolved forge host, repository,
   branch and base before any push, using `./references/transport-direct.md`'s shared lookup.
   Only an exit-0 empty result means none; unknown or incomplete lookups stop the run.
10. In `dry-run`, emit the ship evidence record with the payload and check results, then stop.
11. In direct `publish`, a fix that moves the head needs a new run: `open` again and re-run every
    gated phase for it. Derive each effect's idempotency key from the run id,
    operation id, target identity and input artifact hash. Read the target before and after it.
    The direct transport pushes the checkpointed commit and opens the pull request with `git` and
    `gh`; commit preparation precedes the gates (ruling `direct-push-as-ship-transport`):
    `./references/transport-direct.md`.
12. Draft the lesson candidate through the knowledgebase adapter; publication needs separate
    authority.
13. Hand a directly opened pull request to the watch lane and report the ship as prepared until
    that lane owns it. Report every skipped action and why.

## Hard gates

Gate: merge, deploy, production credentials, destructive data operations, new dependencies,
public-contract redesign, sensitive trust-boundary changes, scope expansion, force-push and history
rewrite are never granted by default. Each requires an explicit charter entry a human approved up
front, naming the action and exactly what is permitted, and an explicit human approval bound to that
charter's hash, with any expiry or single-use bound. An approval whose charter was amended afterwards
no longer binds, and this run may never enlarge its own authority (ruling
`sensitive-actions-need-approved-charter-entry`).

Gate: the autonomous form, `ship.prepare` delegated under a grant, proceeds past workflow step 7 only
on trusted evidence: gate evidence the runner recorded into the run's evidence store outside the
worker's reach. Gate records the worker itself wrote are worker-attested, not trusted evidence, and
neither a grant nor a host permission makes them so.

Gate: no ship begins with an uncovered criterion, an implementer-authored receipt where independent
verification is declared or a recipe binds the check, a host-unattested verifier where a seat is recorded or the run ever held a grant (under the unattended policy, a recorded note instead, whose boundary is the live merge-gate read; an exception to ruling `closure-requires-independent-verification`), or a missing project-declared surface evidence kind. The run
stops with `needs-input` naming the criterion, seat or kind before any remote effect.

Gate: under either transport, an uncommitted head, a stale verify, review-readiness or approved
full or delta review record, or a non-empty working-tree diff refuses the ship before `ship-preflight` and any remote effect.

Gate: `dry-run` makes no remote call. Not a reduced one, not a single harmless one — none. A run that
pushed a branch to show what the push would look like was not a dry run.

Gate: every remote effect carries an idempotency key derived from the run id, the operation id, the
target identity and the input artifact hash, with a read-back before and after
([`adapters/runner-contract/CONTRACT.md`](../../references/shared/adapters/runner-contract/CONTRACT.md) §5). A restart re-derives the same key and returns the
existing record rather than creating a second one.

Gate: staging is by named path. The whole tree is never staged and a wildcard is never used, because
what a wildcard adds is decided by the working directory rather than by this change.

Gate: a candidate secret in what would be committed stops the run. A secret already in history is
reported for rotation; removing it from the payload does not un-leak it.

Gate: pull-request text passes `publish-scan` before it reaches a repository that is public or
outside the configured owners. Title, body and commit messages carry no internal marker and no
copied instruction text; a hit stops the run until the text is rewritten.

Gate: no project-derived artifact is written to a repository path. Decisions, lessons, reviews and
sanitized run receipts go through the knowledgebase adapter, and no application-local documentation tree is created
as a substitute (ruling `central-kb-owns-project-artifacts`).

Gate: the run asks no blocking question mid-flight. Where a decision is genuinely required, it stops
with `needs-input` and the decision named, rather than waiting on a prompt nobody is there to answer.

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "The PR is open and CI is green — the change is effectively merged, so merging it finishes the job." | Approval to prepare a pull request is not approval to land one, and the run cannot grant itself the difference (ruling `sensitive-actions-need-approved-charter-entry`). | Stop at the open pull request, report it as prepared, and name merge as the action that needs its own charter entry. |
| "It is only a dry run, so one push to a scratch branch to check the payload is harmless." | A push is a remote effect whether or not the branch matters, and a dry run that pushes has already broken the only promise it makes. | Emit the payload as a run artifact, and say in the report what would have been sent and to where. |
| "`git add -A` is faster and the working tree only has this change in it." | What a wildcard stages is decided by the working directory, not by the change, and the one time that is false is the time a secret or another lane's file ships. | Stage the paths this change owns, named one by one, and let an unexpected path be a stop rather than a surprise. |
| "The PR lookup errored, so there is probably no open PR — open one." | An error is not an empty result; treating unknown as none is how a second pull request for the same branch gets created. | Treat only an exit-0 empty result as none. On any other outcome, stop and report the lookup as unknown. |
| "The run was interrupted after the push, so push again to be sure." | A second push without the key creates a second effect, and "to be sure" is the sentence that turns one action into two. | Re-derive the idempotency key from the same run id, operation id, target identity and input hash, read the target back, and let the unchanged result be the success. |
| "The secret is in an old commit, so scrubbing it from this one is enough." | The value is already out; removing it from the payload changes what is visible next, not what was exposed. | Stop the run, report the exposure for rotation, and do not treat a clean payload as a closed incident. |
| "The lesson is written — publish it while the knowledgebase call is already open." | Drafting is inside this run's authority and publishing is not, and doing both because the connection was open is the side door the split exists to close (ruling `entrypoint-phase-operation-split`). | Leave the candidate as a draft and name the authority that would publish it. |
| "The PR is open, so this skill is done and the watch can be started later." | An open pull request with nobody watching it is where CI failures and review comments go unread, and "later" has no owner. | Hand the pull request to the watch lane as part of this run, and report the ship as prepared until that lane owns it. |

## Outputs

No-mistakes delivery outputs the committed head and `ship-preflight`. It requires no PR payload,
`ship-evidence` or lesson draft. Direct publication and `dry-run` emit `ship-evidence`
([`schemas/ship-evidence.schema.json`](../../references/shared/schemas/ship-evidence.schema.json)) with three parts.

The pull-request payload: title, description, the linked ticket, the receipts and the review verdict
it rests on, and the branch it would be opened from. In `dry-run` the record holds this payload and
the pre-flight record, and no remote effect.

The pre-flight record: the sensitive-data scan, the dependency-audit triage and each project release
check, with its outcome against this head and a reason wherever it did not run.

The ship record: which remote effects were performed, the idempotency key each carried, and the
read-back result before and after.

Direct paths record declined actions (even when empty); publication drafts an unpublished lesson
candidate through the knowledgebase adapter.

## Side effects

`local-commit`, `branch-create`, `remote-push`, `pr-open`, `kb-draft`, `artifact-write`.

`remote-push` and `pr-open` are remote effects and occur only in `publish`. Each carries an
idempotency key derived per [`adapters/runner-contract/CONTRACT.md`](../../references/shared/adapters/runner-contract/CONTRACT.md) §5 and is read back before and
after, so a resumed run returns the existing branch or pull request rather than creating a second.

Under no-mistakes delivery, super-ship performs neither effect. It records the committed handoff;
the task's no-mistakes pipeline later owns push and pull request (ruling
`no-mistakes-as-ship-transport`). No merge is among this skill's effects.

`kb-draft` writes a draft and nothing else; `kb-publish` is not in this skill's envelope.

No `pr-comment`, no `pr-thread-resolve`: replying on a pull request and resolving its threads are
separately granted actions belonging to the feedback lane.

In `dry-run` the effects performed are `artifact-write` alone.

## Stop conditions

`complete`: under no-mistakes delivery, the committed handoff head and ship-preflight are recorded
with an empty diff and no remote effect; under the unattended policy, only once the pipeline's pull request carries the disclosure and `ship-preflight --pr <n>` succeeded. In direct `dry-run`, the payload and pre-flight record are
emitted. In direct `publish`, the branch and PR exist with read-backs, the lesson candidate is
drafted, and the watch lane holds the PR (under the unattended policy, also the disclosure and a successful `--pr` check).

`needs-input`: the run was started by neither the typed command nor a validated grant, receipts or
the review verdict are missing or bound to another revision, the mode was not named, or a sensitive
action lacks a charter entry. Either transport with an uncommitted head, non-empty diff or stale
verify, readiness or review record also stops here. Returns what it would need, which for the first
is the command to type, and performs no remote effect. Also when the autonomous form has no trusted
evidence: the message names trusted evidence as unavailable and says the manual form remains open.

`failed`: a candidate secret or an internal marker was found, a required release check failed, or
the pull-request lookup returned an outcome that is neither success nor an empty list. The reason is
named and the run stays resumable.

`cancelled`: the caller withdrew mid-run. Effects already performed are reported with their
idempotency keys so a resumed run recognises them.

## Limits

Remote effects per operation: one (gate). Repetition is prevented by the idempotency key, not by
counting attempts.

Sensitive actions: zero without a charter entry (gate). The count does not rise because the run is
going well.

Staged paths: named, never wildcarded (gate). There is no threshold at which a wildcard becomes
acceptable.

Pull-request size: not a gate (guidance). Size targets are configurable starting points and are never
a reason to withhold a prepared change.

Runner budgets: a cap the runner did not supply is not enforced and not guessed
([`policies/limits.yaml`](../../references/shared/policies/limits.yaml)).
