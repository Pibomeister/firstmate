# Kimi launch validation at e41600049d22a4b4be7399d8643877d349eb5ba1

The targeted harness suite passed. Five live checks passed: real Python fallback, no-compatible-Python refusal, complete 80x24 trust handling, incomplete 80x7 trust refusal, and project MCP refusal. Full worker completion remains unverified. No source or test files changed.

## Live product evidence

- `python-live.log`: `/usr/bin/python3` reports 3.9.6. The real installer found an installed uv CPython, installed twice, and removed the hook while restoring original config bytes. With an absent uv root it refused without a config write and listed searched interpreters and remedies. No interpreter was installed for this run.
- `e416-python-regression.log`: the base installer exited 1 in the same real Python environment; the target installer and removal exited 0.
- `normal-trust.txt`, `normal-viewport-transcript.json`: real Kimi 2.4.0 trust dialog under the real wrapped shell preamble. The real tmux spawn answered it; Kimi persisted the worktree trust record and reached its composer. `normal-model-unavailable.txt` then shows `LLM not set`. Spawn returned 1 for unconfirmed delivery, not for trust recognition.
- `short-grid.txt`, `short-readiness-refusal.txt`: the owned worker pane was resized to 80x7 before Kimi launch. It displayed `Enlarge terminal to review sources`. Spawn refused with zero trust submissions, no trust record, exact missing dialog elements, version, poll count, and the last viewport saved before cleanup. Initial resize attempts left new worker windows at 80x24; those were setup attempts, corrected by resizing the exact owned worker pane. Only the final 80x7 result supports this scenario.
- `mcp-readiness-refusal.txt`, `mcp-viewport-transcript.json`: the real dialog disclosed a project MCP server. Spawn refused with zero trust submissions; the marker command never ran and the MCP worktree was never trusted.

## Checks run

- `PATH="/Users/eduardopicazo/.local/share/uv/python/cpython-3.12.12-macos-aarch64-none/bin:$PATH" TMPDIR="$PWD/.test-kimi-lab" bash tests/fm-kimi-harness.test.sh` exited 0. This is one targeted adapter suite, not the full repository suite. Its backend and interpreter simulations are supporting behavioral tests, not live evidence.
- `bash live-kimi.sh`: real installer roundtrip and tmux scout spawn from marked disposable home and fresh Git project.
- `python3 live-tui.py`: captured real tmux worker viewports for complete trust, short-pane setup attempts, and project MCP refusal.
- `LIVE_KIMI_ONLY=short LIVE_KIMI_RUN=short-v3 python3 live-tui.py`: final real 80x7 short-pane check, with an empty trust registry.
- Ran the base and target public installer scripts against the same isolated config and actual Python interpreters.
- Asserted the generated trust registry results, MCP non-execution, recorded grid, refusal records, and missing-model output.

## Untested scope

A tmux worker could not complete its brief because its disposable Kimi home has no model/login. No operator Kimi configuration or credentials were read, copied, or changed. This is the credential limitation already accepted in the prior test round. Supply an authenticated disposable Kimi home inside the worktree to prove model-backed completion.

For Herdr, `HERDR_CONFIG_PATH` and the lab-helper state directory were placed inside the worktree. With an isolated HOME, `fm-herdr-lab.sh prepare fm-lab-kimi-private-01` refused because its required running-default-session tripwire was absent (`herdr-isolated-prepare.log`). With the normal HOME, prepare can read the existing default tripwire, but provisioning would write named-session user data outside the allowed worktree. The advertised config override does not move the HOME-based session namespace. No Herdr server or session was created. To drive it here, provide authority for the helper's disposable named-session files in the normal Herdr namespace, or a supported isolated namespace that retains the required read-only default tripwire. An authenticated disposable Kimi home is also required for brief completion. No previous-round Herdr artifact is claimed as live evidence for this run.

## Evidence and cleanup

The code changes CLI readiness and refusal diagnostics; terminal viewport captures and refusal records show the actual user surface. No GUI or visual layout was changed, so no GUI screenshot was produced. Private tmux servers were stopped and their lab socket directories retired by the repository helper. Disposable workspace data was removed after evidence collection. Existing evidence from earlier rounds was not used as current live proof.
