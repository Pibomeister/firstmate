# Fresh test-phase evidence

TL;DR: The Firstmate fork carry-over at 52054826 passes the selected regression checks and live Codex checks. Two isolated Orca startup attempts fail before an endpoint exists. Three authenticated Grok startup modes do not expose the requested historical surfaces. Live acceptance remains incomplete. The outer executor owns the next decision.

## Orca exit and relaunch preserving local files

Exact blocking command:

```text
sandbox-exec -f /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5TWX28QV7MK1HBVJB807Z3Q/.r/fm-lab-exit-relaunch/boundary.sb orca serve --project-root /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5TWX28QV7MK1HBVJB807Z3Q/.r/fm-lab-exit-relaunch --no-pairing --json
```

Exit 1: `runtime_serve_failed: Orca serve aborted with SIGABRT on macOS.` The named, marked lab could not create an endpoint. The policy confines writes to the worktree and denies service-mediated external mutations. The packaged Electron runtime reports startup registration failure. No shared Orca runtime was mutated. A macOS runtime able to start with workspace-contained state, or authority for a disposable external runtime and its Launch Services registration, is needed. The tested restricted route failed; this does not establish that all possible isolation routes are impossible.

Fixture substitution: `test_orca_relaunch_rebinds_a_closed_terminal_in_the_recorded_worktree` and `test_orca_relaunch_adopts_a_dead_connected_terminal` pass; closed endpoint control cases also pass. These cannot prove real Orca local-file preservation.

## Orca surviving-agent and unreadable-endpoint refusal

Exact blocking command:

```text
sandbox-exec -f /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5TWX28QV7MK1HBVJB807Z3Q/.r/fm-lab-refuse-duplicate/boundary.sb orca serve --project-root /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5TWX28QV7MK1HBVJB807Z3Q/.r/fm-lab-refuse-duplicate --no-pairing --json
```

Exit 1: `runtime_serve_failed: Orca serve aborted with SIGABRT on macOS.` This separately named lab also failed before an endpoint existed. No real survivor/refusal transition could be driven. The same workspace-contained runtime capability or bounded external-runtime authority is needed.

Fixture substitution: `test_orca_relaunch_refuses_without_proof_of_a_stopped_agent`, backend session-tree/unreadable/absence-proof cases, and closed-terminal unreadable-scan exit cases pass. Fixture assertions refuse before creating another terminal and preserve metadata. These are not live Orca proofs.

## Grok idle bordered composer with adjacent hint

Exact prompt-free startup commands:

```text
grok --cwd /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5TWX28QV7MK1HBVJB807Z3Q/.r/grok --no-alt-screen --leader-socket /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5TWX28QV7MK1HBVJB807Z3Q/.r/g
grok --cwd /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5TWX28QV7MK1HBVJB807Z3Q/.gf/grok --fullscreen --leader-socket /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5TWX28QV7MK1HBVJB807Z3Q/.gf/g
grok --cwd /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5TWX28QV7MK1HBVJB807Z3Q/.gm/grok --minimal --leader-socket /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5TWX28QV7MK1HBVJB807Z3Q/.gm/g
```

Existing supported credentials were copied into disposable Grok homes, then deleted. The original credential bytes were unchanged. Grok 1.0.70 authenticated in all three modes. Inline and fullscreen draw `Weekly limit left: 0% · Grok 4.7 (high)` with no adjacent hint row. Minimal draws `Grok 4.7 (high) · 1.9K / 256K (1%) · ctrl+o transcript`. All classify unknown. The actual inline capture classifies unknown on both untouched base and target. No compatible 1.0.62 executable/artifact is supplied on PATH or at a repository-local path; historical UI cannot be recreated by changing these presentation options. Provide a workspace-local compatible Grok binary and existing authenticated test credentials to drive that precise layout. No historical capture is claimed live.

Fixture substitution: `test_matrix_grok_middle_dot_title`, `test_matrix_grok_hint_row_flush_under_box`, `test_composer_state_grok_middle_dot_title`, and `test_composer_state_grok_flush_hint_row` pass, including typed-input negatives.

## Grok weekly-limit choice

The same three prompt-free startups above show no weekly-limit choice. The inline/footer reports 0% remaining, but detection finds no dialog (exit 1). This cached label does not authorize a billable request. No prompt, purchase, authentication change, or training choice was sent. A pre-existing account/session already displaying the real choice, or a documented zero-spend way to surface it, is needed.

Fixture substitution: `test_grok_weekly_limit_choice_is_named_only_in_its_recorded_structure` passes. The recorded choice is named and remains non-empty; incomplete-choice and quoted-transcript negatives do not match.

## Live Codex and exact historical regression

Codex 0.163.0 runs in a hook-free nested project with a private 116x36 terminal and isolated CODEX_HOME. Idle is empty through plain, cursorless styled, and cursor-anchored tmux reads. Footer-prefix, complete-looking footer followed by prose, duplicate hint, context-looking continuation, and placeholder-extension drafts are unknown on plain capture, pending on styled/tmux capture, and retained during extraction. `fm-control.sh codexcheck exit` returns 1, retains `Context 77% left`, and does not insert `/quit`. See `codex-receipt.json` and capture files.

The installed Codex draws a model/path footer rather than the exact historical hint-only layout. The exact `›\n Context 77% left\n ← for agents · ? for shortcuts` fixture is therefore not a live proof. Its production classifier/extractor reproducer reads empty and loses content on 4ffbc145; target 52054826 reads unknown and extracts `Context 77% left`. Existing tests cover styled, cursor, extraction and C-locale variants. The accepted exact-placeholder ambiguity remains unchanged.

## Focused checks and baseline

- tests/fm-spawn-orca-worktree.test.sh: `test_orca_relaunch_rebinds_a_closed_terminal_in_the_recorded_worktree`, `test_orca_relaunch_adopts_a_dead_connected_terminal`, `test_orca_relaunch_refuses_without_proof_of_a_stopped_agent`; exit 0.
- tests/fm-control.test.sh: `test_closed_orca_terminal_exit_reports_endpoint_gone`, `test_closed_orca_terminal_exit_refuses_without_the_worktree_scan`; exit 0.
- tests/fm-backend-orca.test.sh: `test_orca_agent_state_reads_the_session_tree`, `test_orca_agent_state_unprovable_reads_are_unreadable`, `test_orca_absence_proof_refuses_without_every_fact`, `test_composer_state_grok_middle_dot_title`, `test_composer_state_grok_flush_hint_row`; exit 0.
- tests/fm-composer-lib.test.sh: `test_matrix_codex_0162_placeholder_on_plain_capture`, `test_codex_footer_requires_complete_rows`, `test_codex_footer_run_preserves_following_draft`, `test_codex_footer_order_and_multiplicity`, `test_matrix_grok_middle_dot_title`, `test_matrix_grok_hint_row_flush_under_box`, `test_grok_weekly_limit_choice_is_named_only_in_its_recorded_structure`; exit 0.

No full repository suite, linter, formatter, static analysis, pipeline control, push, PR, or CI action ran. Earlier full-file targeted baseline receipts remain in `../validation-receipt.json`; this run reselected only affected functions. The absent-pi and repository-root Codex hook-modal failures are recorded pre-existing exceptions, not new regressions.

## Visual evidence and cleanup

`terminal-captures.html` and `.png` render the actual tmux text. They are labeled transcript renderings, not native application screenshots: private detached tmux sessions expose a terminal grid, not a visible native GUI window. Raw styled and plain captures are retained. Private tmux servers, copied credentials, the private Codex daemon, Chrome session/profile, generated runners and all worktree test data were removed. `cleanup.json` records an empty git status and no owned lab process left. No source or test changes were made.
