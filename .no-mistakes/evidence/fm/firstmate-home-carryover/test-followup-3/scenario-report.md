# Follow-up test evidence

All 14 selected behavioral test entrypoints pass. Two separate restricted Orca launches produced concrete startup failures. Copied existing Grok credentials reached current idle UI, replacing the prior login-blocker assumption; its different footer is unknown on untouched base and target. Weekly-limit choice was not forced because zero spend could not be guaranteed. No source fix is warranted by the observed results.

Revision: 520548269ffccf3553b8d0d4982283753a30fed8

Each live limitation below is accounted for separately. Fixtures are substitutions, not live proofs.

## 1. Orca exit and relaunch preserves files and reuses or replaces terminal

blocked before live setup

Exact attempted command:

```text
sandbox-exec -f /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5TWX28QV7MK1HBVJB807Z3Q/.t3/orca-exit-relaunch/boundary.sb orca serve --project-root /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5TWX28QV7MK1HBVJB807Z3Q/.t3/orca-exit-relaunch --no-pairing --json
```

runtime_serve_failed: Orca serve aborted with SIGABRT on macOS.

The write-restricted named lab could not start packaged Electron Orca. The policy allows file writes only inside this worktree (plus /dev/null), and denies Mach service lookup to prevent writes mediated by external services. The runtime itself reported startup-registration failure. This is a limitation of the restricted launch tested, not proof that every possible Orca isolation method is unavailable. No shared-runtime terminal was created.

Fixture substitution: pass; disconnected replacement keeps the recorded worktree, connected dead terminal reuse keeps its handle; closed endpoint exit sends nothing. These are fixture proofs, not a live proof of local-file preservation.

Evidence: orca-exit-relaunch-restricted-launch.log, orca-exit-relaunch.sb, orca-exit-relaunch-supervisor-journal.json, orca-restricted-launches.json

## 2. Orca relaunch refuses surviving agent or unreadable endpoint without duplicate launch

blocked before live setup

Exact attempted command:

```text
sandbox-exec -f /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5TWX28QV7MK1HBVJB807Z3Q/.t3/orca-refuse-duplicate/boundary.sb orca serve --project-root /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5TWX28QV7MK1HBVJB807Z3Q/.t3/orca-refuse-duplicate --no-pairing --json
```

runtime_serve_failed: Orca serve aborted with SIGABRT on macOS.

A separately named, write-restricted duplicate-refusal lab failed before a runtime endpoint existed. No fleet endpoint was used and no mutation command was sent to the shared running app.

Fixture substitution: pass; live-agent, agent-in-worktree, unreadable, ambiguous and failed scan all refuse before terminal creation and retain existing task metadata. Real stand-in process cases ran without skips.

Evidence: orca-refuse-duplicate-restricted-launch.log, orca-refuse-duplicate.sb, orca-refuse-duplicate-supervisor-journal.json, orca-restricted-launches.json

## 3. Grok idle bordered composer with adjacent hint row reads empty

live attempted; required historical layout unavailable

Exact attempted command:

```text
grok --cwd /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5TWX28QV7MK1HBVJB807Z3Q/.t3/grok --no-alt-screen --leader-socket /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5TWX28QV7MK1HBVJB807Z3Q/.t3/g
```



Using a COPY of the existing supported auth file reached Grok Build 1.0.70 idle. Its actual footer is Weekly limit left: 0% · Grok 4.7 (high), with no adjacent key-hint row. It displays the default-off training banner; neither option was selected. The classifier returns unknown for this shape on BOTH untouched base and target, so this is not a regression introduced by the carry-over. This does not establish empty recognition for the requested 1.0.62 layout.

Fixture substitution: pass; recorded 1.0.62 middle-dot title and adjacent hint classify empty when idle and pending when typed through production classifier and Orca adapter.

Evidence: grok-existing-auth-20s.txt, grok-tmux.json, grok-base-target-comparison.json

## 4. Grok weekly-limit choice is a blocking dialog without purchase

not safely reachable; fixture substituted

Exact attempted command:

```text
grok --cwd /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5TWX28QV7MK1HBVJB807Z3Q/.t3/grok --no-alt-screen --leader-socket /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5TWX28QV7MK1HBVJB807Z3Q/.t3/g
```



Authenticated startup shows Weekly limit left: 0% but no weekly-limit choice. Production dialog detection returns exit 1 on the actual capture on base and target. A cached 0% label does not guarantee a new submitted request cannot consume credits. No request was submitted, no training/privacy preference selected, no authentication approval sent, no quota consumed intentionally and no purchase confirmed. Triggering a server-side rejection to force the choice was not attempted under the zero-spend/account-state constraint.

Fixture substitution: pass; exact recorded dialog is named Grok weekly-limit choice and cannot read empty; missing-choice and quoted-transcript variants do not match.

Evidence: grok-existing-auth-20s.txt, grok-tmux.json, grok-base-target-comparison.json, fm-composer-lib-focused.log

## Scope and interpretation

The sandbox launch errors show the tested restricted route is unavailable. They do not establish that an unrestricted launch is safe or that an isolated runtime is impossible. HOME and XDG overrides plus the exact sandbox policy are recorded in orca-restricted-launches.json and the .sb artifacts. The first preflight blocked /dev/null redirection; that setup issue was corrected before the recorded restricted launch errors. The initial direct PTY produced no usable capture and is not counted as live validation. The private tmux run produced the authenticated screen.

No repository source or tests were changed. The accepted exact Codex placeholder exception remains untouched. The selected Codex regression includes the exact Context 77% left continuation and passes.

Cleanup completed. No owned lab process remains. All disposable files and copied credentials were removed from the worktree. `git status --short --untracked-files=all` is empty and `git diff --exit-code` returns 0.
