# Kimi launch validation

Target revision: e153b5253a07dfe7ca31ba797ab57132488623d2
Base revision: 12f37598333ec5223bedbd09b339a392e39de6f6

All real Firstmate lifecycle calls used marked disposable homes under `.kimi-validation/` in the gate worktree. All real Herdr calls used `bin/fm-herdr-lab.sh` and named `fm-lab-*` sessions. Kimi was the real PATH executable, version 2.4.0; no CLI, model, or login was faked in live checks.

## Commands executed

- `bash tests/fm-kimi-harness.test.sh`: baseline stopped at the missing Python tomllib prerequisite on system Python 3.9.6.
- `uv python install 3.12 --install-dir "$PWD/.kimi-validation/python" --no-bin --no-config`: downloaded Python 3.12.12 into this worktree only.
- `PATH="$PWD/.kimi-validation/python/cpython-3.12.12-macos-aarch64-none/bin:$PATH" bash tests/fm-kimi-harness.test.sh`: initial scoped suite passed its installer and initial spawn checks; intentionally stopped its process group to replace the wider adapter run with the change-specific selectors below. This is not a claim that the full file passed.
- Generated `tests/.kimi-intent-validation.test.sh` by retaining the existing suite's function definitions and invoking only these existing tests, then ran it with workspace Python first on PATH:
  - `test_kimi_hook_install_selects_a_tomllib_python_deterministically`
  - `test_kimi_hook_install_refusal_names_every_searched_python`
  - `test_kimi_answers_the_2_4_0_dialog_below_a_shell_preamble`
  - `test_kimi_refusal_records_a_dialog_with_an_unverified_option`
  - `test_kimi_failed_viewport_read_fails_readiness_at_once`
- `bash .kimi-validation/check-installer.sh`: actual installer install/install/remove with system Python 3.9.6 plus real workspace uv Python fallback; byte comparisons; malformed TOML refusal. Driver copied alongside this record.
- `bash .kimi-validation/python-regression.sh`: executed the base installer plus its base compatibility helper, then the target installer in the same isolated environment. The base failed; target succeeded. Driver copied alongside this record.
- `bash .kimi-validation/live-tmux.sh`: actual scout scaffold, real disposable Git project, real Treehouse worktree, private 80x24 tmux server, prelaunch refusal without a qualifying Python, and real Kimi spawn using workspace uv fallback. Driver copied alongside this record.
- `bash .kimi-validation/live-clipped.sh`: actual second Git project/worktree; resized only the exact owned window to 80x10 before Kimi launch. Readiness refused with zero trust Enter keys, retained the exact viewport/missing signals, and removed the provisional pane and record. Driver copied alongside this record.
- `bash .kimi-validation/live-herdr.sh`: actual `--herdr-lab` scout scaffold and Kimi spawn through a session-enforcing CLI wrapper that forwards every operation to the real guarded lab helper. The first wrapper was too strict for the public preflight's session-less status call; adjusted it to route those calls to the same named lab and reran. No backend was mocked. Driver copied alongside this record.
- `bin/fm-herdr-lab.sh run fm-lab-kimigate2-649 pane read w1:p2 --source visible`: recorded the real Kimi composer and missing-model error.
- Rendered exact captured CLI text into `kimi-live-captures.html`. Attempted screenshot capture with isolated `chrome-devtools-axi` profile/session; its bridge failed to start within 30 seconds. Stopped that browser session afterward.

## Scope of the live result

Both real backends accepted a fresh Kimi trust dialog and reached the composer. Both failed delivery confirmation after Kimi reported `Error: LLM not set, send "/login" to login`. These homes intentionally contain no operator configuration or credentials. This does not establish that the operator's normal login is unavailable. Using or copying that private configuration, signing in, and editing real credential stores were outside this gate's authority. Full model-backed brief execution needs an authorized authenticated disposable Kimi home inside the worktree.

The rendered viewer contains actual terminal transcripts, not native application screenshots. This change alters CLI readiness and diagnostics, with no visual layout changes.

## Completion and cleanup

The five selected behavior tests exited 0. The malformed-config, unavailable-Python, and clipped-dialog negative checks refused as expected. Both real tmux and Herdr brief deliveries remained unconfirmed because the isolated real Kimi CLI reported no model/login; neither is claimed as a successful worker turn.

The Herdr helper completed teardown for both provisioned lab sessions and verified its default-session tripwire. The private tmux server was stopped with the lab runner and its private socket directory was retired by the lab helper. The failed browser session was stopped. Workspace-local Python, fixture repositories, runtime homes, browser profile, and temporary selector script were removed. No tracked source or test file changed.
