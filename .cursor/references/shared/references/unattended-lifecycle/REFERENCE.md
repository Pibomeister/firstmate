# Unattended lifecycle policy

How a lifecycle phase runs when the repository or the runner's environment opts into the
`unattended` policy (ADR-0014): no
typed command and no grant starts a phase, every gate records evidence the gate tool ran itself,
and the human gate is the merge. Where nothing opts in, none of this applies and every phase
behaves exactly as its skill describes.

Every runner behaves the same way: a CI job, a scheduled job, a chat bot, a coding-agent platform
such as Niteshift, or a Firstmate worker. The policy names no runner.

## Selection

The policy is active when `AK_LIFECYCLE_POLICY=unattended` is set by the runner's operator, or
when `ak.lifecycle.json` on the repository's default branch (read at `refs/remotes/origin/HEAD`,
never the working tree) has `"policy": "unattended"`. Any other value of the variable is refused.
`open --ticket` stamps the run with the policy and its source, and a record or check under another
policy is refused. A bypass grant is refused under the policy.

## Starting a phase

From the project checkout run `node <bundle>/bin/ak-gate.mjs unattended check --phase <phase>`.
Exit 0 is the start for `super-align`, `super-bound` and `super-ship`; the four model-started
phases need no start under either policy. Exit 1 means the policy is not active: the phase needs
its typed command or a grant.

## Advancing without a human

Every point where a lifecycle skill waits for a human answer or approval proceeds with the answer
the skill itself recommends, recorded as an **unattended advance** that names the question and the
answer. It is never written as an approval, and nothing claims a human read it. The instances:
align's frontier rounds and its restatement approval; bound's approved-alignment precondition, open
document-review decisions, specification approval and ticket approvals; build's approved-ticket
precondition. A ticket whose delegation class makes a human the author is implemented by the agent
within its allowed changes, with the true class, floor and `author_kind: agent` recorded.

Every other stop still stops: a missing or unsupported prerequisite (for example bound without
project guidance), a blocking review finding, a prototype that needs a person, unprovable or
failed evidence, and every sensitive action, including production writes, deploys, releases,
destructive external operations and credential or protection changes. Merge is never the run's.

## Recording each phase

Every gate except `ship-preflight` is recorded with the evidence command after `--`; the tool runs
it in the project, stores the output by digest and records argv, exit status and times:

```sh
node <bundle>/bin/ak-gate.mjs record --gate <gate> -- <command> [args...]
```

| Phase | Gate | A command that shows it |
|---|---|---|
| align | `align` | `ak kb read` of the published concept and ADR |
| bound | `bound` | `ak kb read` of the published plan record and ticket |
| scout | `scout` | the dossier's read-back, or the bounded search that found nothing more to scout |
| build | `build-checks` | the project's test command |
| verify | `verify` | the verification command, with the receipts as `--receipt` |
| review | `review-full`, `review-delta`, `review-readiness` | the read-back of the review artifact |

A non-zero exit is recorded as failed evidence; a later passing run of the same argv replaces it.
A command that changes the working tree is refused. Align, bound and scout recorded before the run
opens land in the branch-named run, and `open --ticket` imports those at the opening revision with
their original times. A later read-back is a new record with its own time, never history relabelled.

## Shipping

`record --gate ship-preflight` runs the pre-ship check (all six earlier phases, current, passing),
then reads the target repository live and read-only, refuses with every unmet item, and on success
prints the disclosure and each gate's commands. Put that disclosure in the pull request text; under
no-mistakes delivery, edit the opened pull request's text once the pipeline returns. Then
`record --gate ship-preflight --pr <n>` records final ship success: it exits 3 while the independent
review is pending, and refuses a head that diverged from the shipped revision (open a new run at that
head). Commits after the shipped revision are listed and are covered by the merge gate only.

A host-unattested verifier is a recorded note rather than a refusal under this policy: the evidence
is worker-attested, and the trust boundary is the merge gate. Self-verification is still refused.

## Operator setup (once per repository)

Nothing here is done by an agent or by agent-kit.

1. Commit `ak.lifecycle.json` to the default branch, with canonical `provider/model` identities:

   ```json
   {
     "policy": "unattended",
     "human_reviewers": ["@alice", "@org/maintainers"],
     "independent_review": {
       "check": "agent-kit/independent-review",
       "environment": "independent-review",
       "key_secret": "AK_REVIEW_APP_KEY",
       "reviewer_model": "example-provider/reviewer-model",
       "author_models": ["example-provider/author-model"],
       "model_aliases": {}
     }
   }
   ```

2. Commit a code-owners file with a catch-all `*` rule whose owners are all in `human_reviewers`.
3. Protect the default branch (classic protection or a ruleset with an empty bypass list): require
   a pull request with one approval, code-owner review, dismissal of stale approvals, approval of
   the most recent push, required CI pinned to its app, the review check pinned to the review app,
   and enforcement for admins. Required CI pinned to GitHub Actions counts, but its workflow is
   editable in the change under review; code-owner review of the workflow files, which the
   catch-all rule covers, is what covers it.
4. Create a dedicated GitHub App (Checks write, Contents read, Pull requests read, Metadata read).
   Store its key only in a deployment environment whose policy is exactly the default branch; set
   `AK_REVIEW_APP_ID`, `AK_REVIEW_ENVIRONMENT` and `AK_REVIEW_COMMAND`, and the review command's
   provider credential as `AK_REVIEW_PROVIDER_TOKEN`. The review job holds that credential, so a
   reviewer steered by the diff can leak it; scope it to review calls. The reviewer command
   contract: the command reads the diff on standard input and writes its verdict JSON on standard
   output; its harness, not the model, writes the provider's reported model for the call to the
   metadata file (`$AK_REVIEW_METADATA_FILE`); the model has no shell or file tools.
5. Copy the workflow template the super-ship skill ships as `assets/independent-review.yml` to
   `.github/workflows/`, and allow `pull_request_target` for that file in the repository's Actions
   event policy. The template is not evidence that a review was installed or ran. Any earlier
   completed review-app run on a head that did not approve, an `unavailable` provider failure
   included, refuses that head even after an approving rerun; the gate does not tell
   infrastructure failures apart. Recovery is a new commit whose head gets its own current
   independent review and any required human approval; rerunning on the refused head is not.
6. Give the runner its own user account with role exactly `write` that is not a designated
   reviewer, and a fine-grained `AK_UNATTENDED_READ_TOKEN` with Administration, Secrets and
   Environments read. A runner that shares the operator's account or credentials does not meet
   the assumptions below; an app-token CI job needs a machine-user account.

## Limits

The forge does not show that a designated account is operated by a person, that the review
command used the model it reports (identity rests on operator configuration and the provider's
reported metadata, not on a cryptographic attestation), or that a fine-grained read credential is
read-only. Team membership is not verified. The runner's identity is read with the forge client's
active credential, on the assumption that the runner's push credential is the active one;
ship-preflight and review-status print these assumptions. A diff hides
binary files, large-file pointers and submodule contents, and text in it can steer the reviewer.
Local checks run with the task's privileges and guard against misconfiguration and accidents, not
a determined task on the same account; the forge enforces the merge gate either way.
