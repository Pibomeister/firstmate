---
name: ship-landing
description: Load when a ship reports a PR or ready branch, when deciding or monitoring landing, and before task cleanup.
user-invocable: false
metadata:
  internal: true
---

# Ship landing

For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` reports `done [at=<epoch>]: PR <url> checks green` after CI is green, while `direct-PR` reports `done [at=<epoch>]: PR <url>` after opening the PR, each only for a non-draft PR; a lane that deliberately holds a draft declares a wait instead, and `bin/fm-pr-check.sh` refuses to arm merge monitoring on a draft.
Run `bin/fm-pr-check.sh <id> <PR url>` with the URL copied from that ready signal or the resolved checks-green `fm-crew-state.sh` line - it records `pr=` and the forge's `pr_head=` when available in the task's meta and arms the watcher's merge poll.
That merge poll cannot wake firstmate for a named external PR check; firstmate arms the separate check watch and the paused worker does not poll, under `process-event-sources`.
`bin/fm-dod-lib.sh` owns the named-head gate on that ready signal: a ship `done:` whose named head exists only in the worker's disposable copy is not ready (`bin/fm-crew-state.sh` reports blocked, `bin/fm-pr-check.sh` refuses to register, and a secondmate does not publish that done upstream).
That blocked reading is the gate working, not a stuck worker, so steer the worker on the commit the refusal names rather than waiting.
A `forge=external` task reports `done [at=<epoch>]: review <url> uploaded for review` instead: run `bin/fm-review-check.sh <id> <review url>` rather than `bin/fm-pr-check.sh`, which arms no merge watch, then always escalate the review URL to the captain whatever the yolo setting, because firstmate can neither observe nor perform its approval or merge.
A direct-PR worker pushes that commit to its PR branch, and a local-only worker commits it on its ship branch.
A no-mistakes worker re-validates it with /no-mistakes so the pipeline stays the one publisher; it never pushes from its copy.
In no-mistakes mode the earlier `done [at=<epoch>]: {summary}` is the pipeline handoff and is not gated.
Tell the captain the PR's full `https://...` URL copied from the worker's ready line, the resolved checks-green crew-state line, or the task's `pr=` metadata, a concise outcome summary, and the no-mistakes risk level when applicable.
A captain instruction to merge is explicit authority; `yolo` is the only standing routine merge authority.
When `bin/fm-merge-review.sh covers <PR url>` exits 0, this home requires the two-model merge review for that repository ([`docs/configuration.md`](../../../docs/configuration.md) "Merge review").
Never run that review, a test, a build, or a verification step in the supervisor session, and never read the full reviews into it.
Dispatch a scout through `bin/fm-spawn.sh` whose brief names the PR URL and the full head commit; it fetches that commit into its own copy, runs any exact-head verification the task needs, and runs `bin/fm-merge-review.sh run` at that head.
The script, not the worker, writes the prompt, the snapshot, and every receipt, and a worker never edits a review or writes a verdict for a seat.
Read only the one `merge-review:` verdict line, from the scout's status or from `bin/fm-merge-review.sh check <PR url> --head <full-sha>`, which is safe in a supervisor session.
`approved` allows `bin/fm-pr-merge.sh <id> <PR url> --expected-head <full-sha>` under the merge authority that already exists; `blocked` is a dissent to relay as a finding, and only a new head with new reviews clears it; `incomplete` means a seat has no valid review yet.
A changed head has no reviews, so dispatch again for the new head, and never count a review of another head.
The supervisor runs that merge command itself unless a current captain order delegates the merge: then the worker's instructions record the existing authority for that PR and head, and the worker executes that recorded authority through the same command and never decides one.
For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file, print one line only when firstmate should wake, print nothing otherwise, finish before `FM_CHECK_TIMEOUT`, then bind its current bytes with `bin/fm-check-register.sh <id>` before the watcher may execute it.
Retire a custom check only through `bin/fm-check-unregister.sh <id>` (or `bin/fm-teardown.sh` for a spawned task); never hand-compose an `rm` with `$STATE`/`$ID`.

Tear down a ship task only after landing is confirmed.
A teardown refusal for uncommitted or unlanded work is a stop-and-investigate result, never an obstacle to bypass.
Never force teardown without explicit discard authority.
After successful teardown, record completion, retain only the configured recent Done history, and re-evaluate queued work whose blockers and time gates have cleared.

A secondmate is persistent and an empty queue is healthy.
Retire one only on an explicit captain or main-firstmate decision, after loading `secondmate-provisioning`; its home must contain no work under way, and forced discard still requires explicit captain authority.
