# Transport: direct

Loaded by `super-ship publish` when the push and the pull request go straight to the forge through
`git` and the forge's command-line client, with no gate and no supervisor between them. The authority
for every rule here is ruling `direct-push-as-ship-transport` and
[`adapters/runner-contract/CONTRACT.md`](../../../references/shared/adapters/runner-contract/CONTRACT.md) §5; this file is the operating form of them. The commands are
GitHub's `gh`. Another forge's client stands in only where it gives the same exit-status guarantees;
where it does not, every lookup below is unknown and the run stops.

## Contents

- What the transport is
- Choosing it
- Before any remote call
- The commit
- The push
- The pull request
- What it never does

## What the transport is

super-ship has already decided: receipts and a verdict bind to the head being shipped. This transport
pushes the checkpointed commit and opens the pull request. Commit preparation below belongs to build
or repair, before verification, review and ship approval. No pipeline re-runs the project's checks
on the head afterwards, so the re-check is super-ship's own: the release checks of workflow step 4,
each recorded against this head, with a check that did not run recorded as not run. super-ship stays
the single creator of the pull request. Under a bypass grant every remote effect below still waits
for the supervisor's answer to a `needs-decision`, as the skill's Authority section requires.

## Choosing it

The transport is named, never inferred from whichever one happens to work. The first of these that
names one decides:

1. The task's delivery contract: the mode a supervisor's brief gives the task, `no-mistakes` or
   `direct-PR`, or a deprecated legacy binding's `delivery.transport`, which is always
   `no-mistakes`. A task whose contract names no-mistakes never ships direct.
2. The project's own conventions: its instruction files, and the conventions the knowledgebase
   adapter's `readContext` returns. A project that routes its changes through a gate is never pushed
   around it, whoever asks, and a gate this package has no transport for stops the ship with
   `needs-input`. Where `readContext` is unavailable, the instruction files are the conventions and
   the ship record says the knowledgebase went unread.
3. The caller's `transport` input: `direct` or `no-mistakes`.
4. None of them: stop with `needs-input` naming the choice. No gate in sight is not a choice of
   direct; a transport nothing names is unknown, and unknown is not direct.

The choice holds for the run. A chosen no-mistakes transport ends the ship at its handoff
(workflow step 8); a gate that was chosen but is not configured stops the ship with
`needs-input`. Neither ever falls back to this one. In
`dry-run` the choice is made from local reads alone, so the report can name where the payload would
have gone.

## Before any remote call

1. The branch: `git branch --show-current`. Empty output is a detached head and stops with
   `needs-input` naming the branch to create. The lookup
   below with an empty branch drops its filter and lists unrelated pull requests.
2. The remote, `<remote>`: `origin`, unless the conventions name another. Resolve its destination
   with `git remote get-url --push --all <remote>`, including Git's URL rewrites. Require exit 0 and
   exactly one URL, `<push-url>`; otherwise stop with `needs-input`. Resolve the Git transport
   endpoint, including an SSH alias's effective hostname and port from local configuration.
   Resolve canonical `<forge-host>` separately, using an explicit project binding between that
   endpoint and the forge, or a documented provider mapping. GitHub's SSH endpoint
   `ssh.github.com:443` maps to `github.com`, including aliases that resolve to that endpoint
   ([provider documentation](https://docs.github.com/en/authentication/troubleshooting-ssh/using-ssh-over-the-https-port)).
   Normal URLs whose endpoint is also the canonical forge host keep that host, such as
   `github.com` or a project's Enterprise host. Other SSH-only endpoints require an explicit
   binding; an unresolved, conflicting or ambiguous mapping stops with `needs-input` before any
   forge call. Never infer the binding from `GH_HOST`, authentication or a client default.
   Keep `<push-url>` unchanged for Git; use canonical `<forge-host>` for every forge call and
   effect identity. Apply the same mapping when identifying the remote that fetches the base
   repository, rather than comparing raw SSH endpoint names. Resolve its repository,
   `<head-owner>/<head-repo>`, from conventions and in `publish` confirm it with `gh repo view
   <forge-host>/<head-owner>/<head-repo> --json id,nameWithOwner,isFork,parent`. Record its node ID as `<head-id>`.
   Require a successful lookup that confirms the identity and a non-empty ID; otherwise stop.
   The fetch URL never decides the head repository or owner. The base repository is the pull
   request's target, `<base-owner>/<repo>`: named by conventions, else the push repository's fork
   parent from that metadata, else the push repository itself. Every PR lookup and edit passes
   `-R <forge-host>/<base-owner>/<repo>`; creation uses the resolved repository IDs and
   `--hostname <forge-host>`. A base repository on another forge host stops with `needs-input`.
   A local base-branch lookup uses only a remote that fetches that repository on `<forge-host>`.
3. The base: the branch the conventions name for this one, which may depend on its prefix. Where
   they name none, the base repository's default branch — `git symbolic-ref --short
   refs/remotes/<base-remote>/HEAD` locally, for the remote that fetches the base repository, with
   its `<base-remote>/` prefix stripped so the base is the bare branch name, and `gh repo view
   <forge-host>/<base-owner>/<repo> --json defaultBranchRef` in `publish`. A fork's own default branch is never
   the base. With neither, stop with `needs-input`; a base is never guessed. The ship record says
   which source gave it. In `publish`, also resolve `<base-id>` with `gh repo view
   <forge-host>/<base-owner>/<repo> --json id,nameWithOwner`, regardless of the branch's source. Require a
   successful lookup confirming that repository and a non-empty node ID before any push.
   After resolving both repositories and the base, stop with `needs-input` if the head repository
   is the base repository and `<branch>` equals `<base>`; in `publish`, compare `<head-id>` and
   `<base-id>` for repository identity. Equal branch names in different repositories are allowed.
4. The assignee and the body shape: a required assignee, and the template the body must follow — the
   repository's own pull-request template, or the shape the conventions give. Where the conventions
   require no assignee, nothing is assigned. Nothing here is a package default.
5. The publish scan of workflow step 3, once per repository the text reaches: the base, and the
   head repository where it differs. Prepare the title and body file first. In `publish`, read
   `<v>` with `gh repo view <forge-host>/<owner>/<repo> --json visibility --jq .visibility`; in
   `dry-run`, or when that lookup fails, omit `--visibility`, which scans as public. Run
   `node <skill directory>/../../bin/ak-gate.mjs publish-scan --repo <owner>/<repo> --visibility <v>
   --title <title> --body-file <body-file> --commits <base-remote>/<base>..<shipped-commit>`.
   A hit is `failed` before any push. A rewritten commit message is a new head and a new run.

## The commit

Prepare the commit during build or repair, before collecting verification, review, readiness and
ship approval for it. Under the runner this is the existing `local-commit` operation, permitted only
in build or repair. Sync the committed revision before collecting evidence. At direct publish,
require that same committed revision, current gates and an empty diff. Never commit after
`ship-preflight`, even when the committed blobs would be unchanged: a new commit changes the
revision and invalidates the checkpoint. Missing or stale evidence stops publication.

Named paths are literal filenames. When staging during build or repair, use
`git add -- ':(literal)<path>'...`. Pass each path as a separate literal argument with this prefix,
including names containing brackets, wildcards or pathspec magic. Keep the prefix on every
path-taking inspection and commit below; do not change the pathspec environment inherited by hooks.

1. Record what is staged for the named paths: `git ls-files --stage -- ':(literal)<path>'...` gives each one's
   mode and blob.
2. Require the working tree to match the index for those paths: `git diff --quiet -- ':(literal)<path>'...`.
   Exit 0 is a match. Exit 1 is a path partially staged or edited after staging, and stops with
   `needs-input` naming the paths `git diff --name-only -- ':(literal)<path>'...` lists; any other exit is
   unknown: stop. The commit below takes the working-tree content of the paths it names, so a
   difference here would replace what was staged.
3. Commit only those paths: `git commit -F <message-file> -- ':(literal)<path>'...`. The trailing path list keeps
   anything else already in the index out of the commit.
4. The project's hooks run. Never pass `--no-verify`: a hook is one of the project's own checks.
5. Compare what the commit holds. `git ls-tree -r HEAD -- ':(literal)<path>'...` must list the modes and blobs
   step 1 recorded, and `git diff --name-only HEAD^ HEAD` must name no path outside the named ones,
   compared as literal filenames rather than patterns.
   Equal: collect verification and review against this committed head. Different: the commit no longer holds what was staged — a
   hook that reformats and restages files is the usual cause, though not the only one — and the
   commit is a new head that no prior receipt or verdict binds to. Stop publication with
   `needs-input`. The commit stays local and is neither amended nor pushed. `open` a new lifecycle
   run for this head, even if the prior run is still active. Re-run super-build, super-verify and
   super-review and obtain every gated phase's approval before a fresh ship checkpoint. Never
   continue the prior run for a rewritten commit or inherit the previous head's evidence.
6. A hook that changes files without staging them leaves the working tree changed. Report those
   paths and leave them uncommitted; publication waits for an empty diff and current gates.

A project whose hooks format on commit ships cleanly when those formatters run before super-verify,
so the hook has nothing left to rewrite.

## The push

Reconcile before the effect, per [`adapters/runner-contract/CONTRACT.md`](../../../references/shared/adapters/runner-contract/CONTRACT.md) §5:

1. Re-read `git branch --show-current` and `git remote get-url --push --all <remote>`. They must
   still be the resolved branch and sole `<push-url>`; a changed target stops with `needs-input`.
2. Read the destination branch: `git ls-remote --exit-code <push-url> refs/heads/<branch>`.
   Exit 0 prints its commit, exit 2 means it does not exist there, and any other exit is unknown: stop.
3. The remote branch already at the shipped commit: the push is done. Record it and do not push again.
4. The remote branch at another commit: fetch it (`git fetch <push-url> refs/heads/<branch>`)
   where it is not local, then `git merge-base --is-ancestor <remote-commit> HEAD`. Exit 0 is a fast-forward.
   Exit 1 is a diverged branch, and any other exit is unknown; both stop with `needs-input`. A
   diverged branch is never forced into line: force-push is a sensitive action (ruling
   `sensitive-actions-need-approved-charter-entry`).
5. Immediately before the push, run the pull-request section's shared lookup and checks in
   steps 1–3. Unknown, incomplete, ambiguous or differing-base PR state stops before the effect.
   Push: `git push -u --no-follow-tags --no-recurse-submodules <remote> refs/heads/<branch>:refs/heads/<branch>`.
   The explicit refspec updates only the branch reconciled above, regardless of configured push
   mappings; `--no-follow-tags` prevents configured tag publication, and `--no-recurse-submodules`
   prevents inherited settings from pushing child repositories. Never `--force`,
   `--force-with-lease` or `--no-verify`. A
   rejected push, including a pre-push hook that fails, is `failed` with the reason, and the run stays
   resumable.
6. Read back with the step 2 command. It must print the shipped commit; anything else is `failed`,
   never complete.

## The pull request

Under the runner, execute this entire section inside its existing keyed `pr-open` operation.
The desired payload includes the resolved base, shipped head, title, body and required assignee.
Prepare the literal title and body file before reconciliation; use these same values for creation
and comparison on every path. The operation's reconciliation callback returns its input hash only
when one matching PR has that base, head, title, body and required assignee. Unknown, ambiguous or
incompatible state refuses. A title or body mismatch refuses without editing either. A missing PR
or missing required assignee is incomplete, so the callback returns no confirmed hash and the
operation's action reconciles again, creates only if absent, and assigns only if needed. Final
read-back confirms the complete payload before the runner records `pr-open`. A create that
succeeded before assignment failed stays unconfirmed; retry the same operation and key, reuse
that PR and finish assignment. Never issue a second effect or key for assignment, and never
confirm `pr-open` before assignment. No effect vocabulary or runner state transition changes.

1. Look it up: `gh pr list -R <forge-host>/<base-owner>/<repo> --head <branch> --state open --limit 30 --json
   number,url,headRefName,headRefOid,headRepository,headRepositoryOwner,baseRefName,title,body`.
   Pass the branch name only:
   `--head <owner>:<branch>` is not accepted and returns `[]`, which reads as none.
   At every lookup — initial, before push, before creation and final read-back — require exit 0
   and a JSON array with fewer than 30 rows before filtering by head. A saturated result may omit
   an existing or conflicting PR; it is unknown and stops the run before any push, create or return.
   Malformed output is also unknown. Never accept a match from a partial list.
2. Only exit 0 with `[]` means none (workflow step 9). Any other exit is unknown: stop.
3. Match `headRepository.nameWithOwner` to `<head-owner>/<head-repo>`, `headRepositoryOwner.login`
   to `<head-owner>` and `headRefName` to `<branch>`. A different repository, owner or branch is
   another head. More than one matching row is ambiguous: stop and list them rather than taking the first.
   A matching row's `baseRefName` must equal the resolved base; otherwise stop with `needs-input`
   before the next effect, without changing its base. Apply this check on every
   lookup, including the initial detection, the pre-push check, pre-create reconciliation and final read-back.
4. One match: skip creation and continue to step 7; never open a second.
5. None: repeat the lookup immediately before creation. A pull request that appeared since step 1
   takes the one-match path. Apply steps 2–3 again before any create.
6. Still none: use the prepared body file and the same repository-ID mutation for a
   head in the base repository, a user-owned fork or an organization-owned fork:

   ```sh
   gh api graphql --hostname <forge-host> \
     -f query='mutation($input: CreatePullRequestInput!) { createPullRequest(input: $input) { pullRequest { number url } } }' \
     -f 'input[repositoryId]=<base-id>' \
     -f 'input[headRepositoryId]=<head-id>' \
     -f 'input[baseRefName]=<base>' \
     -f 'input[headRefName]=<branch>' \
     -f 'input[title]=<title>' \
     -F 'input[body]=@<body-file>'
   ```

   Substitute the resolved values as literal arguments. The explicit `headRepositoryId` selects
   the head repository, so `headRefName` is the bare branch, never `owner:branch`.
   `-F` reads the body file; never use standard input. Require exit 0, no GraphQL errors and a
   non-null `data.createPullRequest.pullRequest`; otherwise stop with `failed` and reconcile on
   resume before another create. This avoids `gh pr create --head`'s organization-owner limit
   ([CLI manual](https://cli.github.com/manual/gh_pr_create),
   [API contract](https://docs.github.com/en/graphql/reference/pulls#createpullrequestinput)).
7. For every path — existing, discovered before creation or newly created — read back with the
   steps 1–3 lookup and completeness check. Require exactly one matching row; otherwise stop with `failed`.
   Its `headRefOid` must equal the shipped commit; a mismatch stops with `failed`.
   Its JSON-decoded `title` and `body` must exactly equal the prepared title and body file's text,
   including whitespace and trailing newlines. Missing fields or mismatches stop with `failed`;
   never edit the title or body to make them match, and never return the payload hash on mismatch.
8. Within the same `pr-open` action, after step 7 passes, satisfy any required assignee. Read `gh pr view <number>
   -R <forge-host>/<base-owner>/<repo> --json assignees`; unknown stops the run. If the required login is absent,
   add it with `gh pr edit <number> -R <forge-host>/<base-owner>/<repo> --add-assignee <who>`, then read back with
   the same view command and require that login. Assignment is part of the existing PR publication
   operation and its authority, reconciliation and key, not a separate effect. A failed assignment
   or missing read-back is `failed`; a resumed operation uses this step for the existing PR and
   does not create another. Repeat step 7 and the assignee read-back after assignment, and confirm only
   when base, shipped head, title, body and required login all match. With no required assignee, omit the edit.
   Return only after the operation's final read-back confirms the payload.

The ship record carries each effect's idempotency key and its read-backs. The push target identity
is the resolved forge host, head repository and branch; the PR target includes that host, head and
the base repository and branch. The PR input hash covers the base, shipped head, title, body and any required login.
A resumed run re-derives the same keys. A head that already carries the commit is past
the commit, and the push and pull-request reconciles return an effect already made rather than repeating it.

## What it never does

It never merges, never deploys, never force-pushes, never rewrites history on the remote and never
pushes the base branch in the base repository. It never skips a hook and never falls back from a gate that was chosen. Merge
authority stays with whoever holds it: standalone, the person.
