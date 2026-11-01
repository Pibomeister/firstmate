# Orca runtime backend

Orca is an experimental macOS backend in which the Orca app owns both the task worktree and terminal endpoint.
The crewmate harness remains the agent process launched inside that endpoint.
Firstmate agents load [`firstmate-orca`](../.agents/skills/firstmate-orca/SKILL.md) before operating or recovering this backend.

## Setup

Pick Orca when you already use the Orca macOS app and want Orca-managed worktrees and terminals instead of Treehouse plus a session multiplexer.
Orca is macOS-only, explicit-only, and does not support secondmate spawns.

Prerequisites:

- `/Applications/Orca.app` installed, running, and ready.
- The `orca` CLI, installed with `brew install orca`.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Select Orca with local `config/backend` containing `orca`, `FM_BACKEND=orca` for one launch, or an explicit request to Firstmate.
It is never auto-detected.

Before any spawn mutates repository state, Firstmate requires `orca status --json` to report `reachable=true` and `state="ready"`.
The first task for a project registers that repository with `orca repo add --path` when needed.
No manual repository registration is required.

Open the Orca app to watch a task's terminal.
Routine supervision uses the recorded endpoint through `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'`.
Enter and Ctrl-C are supported for every harness.
Escape and Ctrl+U are verified for Droid on Orca 1.4.217 and 1.4.218 through raw terminal bytes; other harnesses do not inherit that lifecycle control capability.

`config/launch-env-allowlist` alone cannot scope worker credentials on Orca, because allowlisted values resolve from the Orca terminal's own environment.
When scoped worker credentials live in a tmux session, configure the [Orca environment source](configuration.md#orca-environment-source-configlaunch-env-tmux-session).

## Task shape and metadata

Each task has one Orca-managed git worktree and one Orca terminal.
`fm-spawn.sh` does not call Treehouse for Orca tasks.
The normal isolation and unlanded-work refusal rules still apply.

```text
backend=orca
window=fm-<id>
terminal=<orca terminal handle>
orca_worktree_id=<orca repo id>::<absolute worktree path>
orca_created_branch=<initial Orca-created git branch>
worktree=<absolute Orca worktree path>
```

`window=` remains the caller-facing Firstmate alias.
`terminal=` and `orca_worktree_id=` are the backend authority used by operation and cleanup paths.
Orca returns `orca_worktree_id=` as that composite of the Orca repo id and the worktree path, and cleanup validation requires both halves rather than treating the value as a simple name.

## Current lifecycle and safety

Spawn registers the repository, creates an independent worktree, reuses only the verified `result.terminal.handle` returned by Orca or creates a terminal explicitly, installs harness hooks, records metadata, and launches the selected harness.
Exact command flags and response parsing are owned by `bin/backends/orca.sh` and script help.

PR registration moves Orca cards to `in-review`; successful PR merge recording or local-only landing moves them to `completed` until teardown removes the card.
`bin/fm-orca-card.sh` bounds each best-effort update to five seconds plus termination grace and warns on failure without changing the caller's outcome; a hung merge-time update can stall the watcher for that bounded interval.
Spawn records the initial Orca-created branch, including the recorded base branch in abort-recovery metadata, and attempts guarded cleanup after removing the Orca worktree.
Teardown detaches the task worktree and uses the same guarded cleanup for the recorded Orca-created branch, even when that branch was checked out; a distinct worker branch keeps its existing teardown behavior.
The guard retains invalid, default, recorded-base, and observed checked-out or rebasing branches, and keeps uncontained work with a warning.
It removes the exact recorded branch tip only when a remote-tracking ref contains that tip, verifying that ref and the tip atomically with the delete; task or project `HEAD` and local branches never count as proof, so unpushed work is retained and an unresolved default or failed proof also retains the branch and warns.
A deletion through this proof leaves any `branch.<name>.*` config behind; that residue is harmless and intentionally not removed.
The real Orca card movement from `in-progress` through `in-review` to `completed`, and the branch name and upstream state real Orca gives the branch it creates, have not been observed in a live smoke; this behavior is covered only by deterministic fixtures, and the cleanup never consults branch upstream state.
Tasks waiting without a PR and existing leaked branches are not reconciled by these event hooks.

`fm-peek.sh` reads with `orca terminal read`.
An ordinary metadata-routed `fm-send.sh` text steer becomes a durable steering-inbox record, and only its best-effort constant doorbell passes through Orca's submit machinery.
On the typed plane, `fm-send.sh` verifies composer clearance through the fleet-wide classifier in `bin/fm-composer-lib.sh`, retrying Enter without retyping when a slash popup first fills an argument placeholder.
For a recorded Droid task, a matching post-Enter `UserPromptSubmit` receipt also confirms a typed send when the composer is temporarily unreadable during Droid's turn; the receipt binds the prompt digest and event sequence to the current task generation.
The composer read is one bounded tail of the live terminal and never pages backward into scrollback, so a stale startup banner cannot compete with the bottom-anchored composer.
Supported Grok send and queue footer evidence and its read-only refresh procedure are in [runtime backend verification](verification/runtime-backends.md#grok-send-and-queue-footer).
A bare shell row is `unknown`, not an empty agent composer.
The shared classifier owns plain-capture handling, including the exact per-glyph placeholder exception in `FM_COMPOSER_BARE_PLACEHOLDERS_DEFAULT`.
Plain-text captures degrade a glyph row carrying trailing text to `unknown` rather than a false `pending`.
The watcher has no native Orca busy signal, so each harness adapter's semantic lifecycle supplies worker state.
Grok alone retains its isolated rendered-tail fallback.

The away-mode daemon can supervise the captain's own Orca terminal; [supervisor backend configuration](configuration.md#away-mode-supervisor-backend-fm_supervisor_backend--fm_supervisor_target) owns its detection and refusal.
The daemon treats a `timeout` from `orca terminal wait --for tui-idle` as busy for the captain terminal, because a live Claude turn can render frames with no spinner row.
The daemon also holds an alert while the read result has a non-empty `draft`, because Orca lifts typed text out of `tail` into that field.
`draft` also carries Claude's ghost prompt suggestion, and Orca exposes nothing that separates the two, so the home's tracked `.claude/settings.json` sets `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false` to keep a Claude captain's composer free of ghosts.
Limitation: a captain session that started before that setting existed, or with suggestions forced back on by a higher-precedence setting, still holds alerts in the buffer until the captain acts or the wedge alarm fires.

Cleanup keeps all shared Firstmate safety checks.
A scout still requires its report and completed decision inventory.
A ship still refuses dirty or unlanded work.
Before releasing an existing worktree, cleanup resolves the recorded Orca worktree id and verifies its path matches the recorded worktree path.
A missing, unreadable, or mismatched identity preserves metadata and stops rather than deleting anything.
After those checks, Firstmate closes the exact terminal and releases the exact worktree with Orca's worktree command.
If that removal returns `selector_not_found`, cleanup treats the worktree as already removed only when the recorded path is confirmed absent.
An omitted recorded path, an existing path (including a dangling symlink), or a path lookup error refuses that recovery; other Orca removal errors also stop cleanup.
The same removal rule applies to forced secondmate child cleanup and spawn abort cleanup; `bin/backends/orca.sh` owns the implementation and `tests/fm-backend-orca.test.sh` pins the boundary.
It never raw-deletes an Orca worktree.
A close the CLI never attempted, because `orca` is not on the path, stops cleanup with the metadata intact even under `--force`: removing those records would leave nothing on disk naming a terminal that may still be live.
Reinstall the CLI and rerun; [`verification/runtime-backends.md`](verification/runtime-backends.md) "Endpoint close" owns what this arm can and cannot prove about its own close.

## Agent stop proof

`fm-control.sh` and `fm-spawn.sh --relaunch` read a recovery-grade agent state for an Orca task, so a stopped worker can be exited, relaunched, or moved to another harness in place.
Supervision and cleanup do not read it; for them Orca agent state stays unverified.
`bin/backends/orca.sh` owns the reads, and [`agent-control.md`](agent-control.md#reclaiming-a-task-whose-endpoint-is-gone) owns what each verdict licenses.

Orca's terminal API never names the processes behind a terminal, so the verdict joins three reads:

- `orca terminal show` says whether the recorded terminal is connected, and for a disconnected one whether Orca recorded an exit cause, on which execution host, and in which worktree.
  Orca keeps describing a closed terminal by its handle, so a closed terminal is a positive finding, not a failed read.
- `orca diagnostics memory` lists each live pty session with the local process that roots it.
  On macOS that root is `/usr/bin/login`, whose child is the login shell, whose children are whatever the terminal runs.
- The process table under that root is classified by the shared harness-process classifier in `bin/fm-agent-process-lib.sh`.

A connected terminal is `alive` when any process in its session tree is a verified harness, `dead` when the tree holds only shells besides the `login` root, and `ambiguous` otherwise.
A disconnected terminal with a recorded exit cause is `missing`, and the absence proof then decides whether it is gone.
That proof also requires that Orca's sweep no longer lists the session and that no process of this user that classifies as an agent has its working directory in the recorded worktree, read with `lsof`.
The working-directory read exists because an agent can outlive the terminal it started in; such a survivor returns `unproven` and refuses the relaunch, since lifecycle commands cannot reach it through the recorded terminal.
A remote execution host, a missing exit cause, a worktree mismatch, or any failed read refuses rather than proving absence.
For a Droid task, [`fm_control_droid_agent_absent` in `bin/fm-control-lib.sh`](../bin/fm-control-lib.sh) owns the shared marker and connected owned-shell stop proofs, including their refusal conditions, for `fm-control` and `fm-spawn --relaunch`.
After that proof, [`fm-spawn.sh`'s relaunch contract](../bin/fm-spawn.sh) requires terminal usability for adoption and replaces a closed or unwritable terminal in the recorded worktree.
A stale handle reads `unreadable`; only Orca's exact `ok:false` response with `error.code=terminal_handle_stale` is accepted as stale evidence, including when the CLI exits nonzero.
It proves absence only after a host reboot: the boot time read from the kernel must postdate the handle's recorded evidence (the record's spawn generation, or its mtime without one), Orca's process sweep must be readable from the post-boot runtime, and no agent process may be working in the recorded worktree.
Without that reboot proof a stale handle refuses exactly like any other unprovable read, so an Orca restart short of a reboot can never license a second agent.

A rebind creates the new terminal through the recorded `orca_worktree_id=`, and refuses unless that id names the recorded worktree.
The [Orca environment source](configuration.md#orca-environment-source-configlaunch-env-tmux-session) owns launch-environment handling for relaunches.
[`verification/runtime-backends.md`](verification/runtime-backends.md#orca-agent-stop-proof) records the observed Orca responses and process layout.

## Active limits

- Orca is macOS-only and explicit-only.
- The app must be running and report ready.
- Secondmate spawns are unsupported.
- Escape and Ctrl+U are verified for Droid only.
- Orca exposes no stable CLI version or protocol marker, so readiness is the compatibility gate rather than a version floor.
- Only the verified terminal-handle and worktree result fields are accepted; speculative response shapes are rejected.
- Orca's worktree shape is unverified against the spawn-time Claude workspace-trust check in `bin/fm-claude-trust.sh`, which refuses any path that is not a linked git worktree sharing the project's git common dir, so a claude spawn on Orca fails loudly at that check rather than launching if Orca clones instead of linking.

## Regression entry points

```sh
tests/fm-backend-orca.test.sh
tests/fm-spawn-orca-worktree.test.sh
tests/fm-control.test.sh
tests/fm-daemon.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
tests/fm-teardown-endpoint-safety.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#orca) records the real readiness and response-shape smoke.
