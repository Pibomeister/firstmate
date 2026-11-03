# Transport: no-mistakes delivery handoff

Loaded by `super-ship` for no-mistakes delivery. Ruling `no-mistakes-as-ship-transport` and
ADR-0012 govern this path. no-mistakes owns the branch after handoff, including its Review, checks,
fixes, rebases, push, pull request and CI.

## Handoff

Commit the change before verification, review-readiness and the full or delta review. Record all
three at that committed handoff head, the review approved and current. Record ship-preflight at the same head with an empty working-tree diff. super-ship ends at
that record: it does not push or open a pull request and passes no `--skip`. No repository `auto_fix`
value is a precondition. The task's delivery contract starts no-mistakes after this handoff; the
pipeline runs unmodified and unskipped. Its Review may challenge a lifecycle-approved decision.

`--intent` carries only the captain's words. If those words expressly adopt source material by
reference, include the adopted substance in the captain's terms. Do not add a separate supervisor
decision, Firstmate's specification, the lifecycle plan or a worker summary. If no captain words
are available, stop for the supervisor rather than inventing intent.

no-mistakes turns `--intent` and the commit messages into the pull-request text. Before the handoff,
run `publish-scan` (workflow step 3) for the repository the pipeline publishes to, with
`--commits <base>..<handoff head>` and the `--intent` text as `--body-file`. A hit in a commit
message returns the head to build or repair, and the new head needs fresh gates; a hit in the
intent goes to the supervisor as needs-decision, because the intent is not the worker's to reword.

## Pipeline gates and adoption

Answer a parked gate inside the pipeline under the task's delivery contract. An `ask-user` finding,
including one that challenges a lifecycle-approved decision, goes to the supervisor as an ordinary
needs-decision. The supervisor supplies the answer; the pipeline applies any fix. The worker does
not edit the branch while a pipeline run is active.

After checks pass, identify the pushed head and attribute every change from the handoff to
no-mistakes. Adopt its attributable changes and re-run verification at the pushed head without
repeating review. An `unreviewed` commit, a `missing` handoff commit, an overridden Review step or
an unattributable change escalates to the supervisor as needs-decision. Use the existing
`--run <run>` selector when naming a run on a replaced branch. ADR-0012 records the accepted
review gap for pipeline fixes and CI-monitor rebases.

The pipeline never grants merge authority. The supervisor's delivery contract owns the push, pull
request, CI result and any later merge decision.

## Deprecated legacy patched-binding path for delivery mode agent-kit

The patched Firstmate binding and its transport remain available for existing delivery mode
`agent-kit` installations. They are deprecated and are not the no-mistakes delivery default.
no-mistakes v1.79 refuses to push a run whose Review step was skipped
(`internal/pipeline/steps/push.go` `assertReviewApprovedPushHead` at no-mistakes v1.79.0, verified
by reading source, not executed).

### Deprecated legacy publish procedure

Under a legacy `agent-kit` binding with `delivery.action: publish`, super-ship does not stop at the
handoff. In `publish`, after the steps up to open pull-request detection, the push and the pull
request go through no-mistakes with review, document and rebase skipped, and a parked gate returns
to the lifecycle rather than being answered in the pipeline. super-ship stays the single creator of
the pull request: no-mistakes opens it only because super-ship started the push.

Reconcile before every remote effect, per [`adapters/runner-contract/CONTRACT.md`](../../../references/shared/adapters/runner-contract/CONTRACT.md) §5:

1. Read the branch's open pull request, deterministically. Unknown is not none (workflow step 9).
2. Read the active no-mistakes run for the branch, if any.
3. Where the pull request exists and its head is the head being shipped, the push is already done:
   return it rather than pushing again.
4. Where a run is active on an older head, the new push supersedes it. That is the intended way to
   replace a parked run, not a conflict.

Then push through the transport with the deprecated skips below. `--intent` carries only the
captain's words, as in the handoff path.

Derive an idempotency key for each remote effect from the run id, the operation id, the target
identity and the input artifact hash, never from a timestamp, a random value, an attempt counter or
a session id. Read the target back before the effect and again after it. Emit ship-evidence with
the payload, the pre-flight record and the ship record. Draft the lesson candidate through the
knowledgebase adapter's draft operation; publishing it is a separate authority. Hand the open pull
request to the watch lane, and report the ship as prepared rather than finished until that lane
owns it. The run is complete when the pull request exists with its read-backs recorded and the
watch lane holds it.

### Deprecated skip transport

```
--skip review,document,rebase
```

The legacy transport skips Review because lifecycle review claimed the judgment, and skips
document and rebase because they can move the head after that judgment. A legacy push that cannot
carry those skips stops instead of silently changing its review contract.

### Deprecated auto-fix precondition

The legacy trusted no-mistakes config requires `auto_fix.test`, `auto_fix.lint` and `auto_fix.ci`
to be `0`. `checkNoMistakesConfig` and patched preflight enforce that legacy precondition; stock
preflight does not. A parked gate in this legacy path returns to lifecycle fix, verification and
delta review before another ship attempt, and the new push supersedes the parked run. Never answer
a parked gate from inside the pipeline on this path; at the fix-cycle cap the run stops with
`cap-reached` instead of pushing again. ADR-0002's “One owner per concern” decision describes
this superseded path.
