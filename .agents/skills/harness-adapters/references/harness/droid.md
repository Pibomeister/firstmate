# Factory Droid CLI

Droid is a verified crewmate and scout harness on the TUI path; it has no Firstmate primary supervision protocol and cannot run a secondmate.
`../../../bin/fm-spawn.sh` owns its launch and runtime settings file, while `../../../bin/fm-control-lib.sh` owns interrupt, exit, and relaunch mechanics.

## Operating facts

| Fact | Value |
| --- | --- |
| Start | `droid --settings <task-settings> --auto high "<launch-brief>"` starts an interactive TUI and submits the positional prompt. |
| Model | Interactive `droid --help` offers no `--model` flag; Firstmate writes the requested model to the per-task runtime settings file and validates it with `droid exec --model <id> --list-tools`. `droid exec --help` lists model IDs. |
| Effort | Interactive `droid --help` offers no reasoning flag; the runtime settings key `reasoningEffort` carries a supported shared effort. Factory's model catalog owns the model-specific level set. |
| Autonomy | `--auto high` plus `sessionDefaultSettings.autonomyLevel=high` in the per-task settings file keeps the interactive TUI at Auto (High), with commands allowed. |
| Status line | The per-task settings replace any user `statusLine` with the command `printf firstmate`. Runtime settings merge over user settings, so `null` or `{}` cannot unset it, and empty output draws a failure row. Below the tmux composer box, only Droid's own timer footer row, which starts with `[⏱ ` and ends in `TMUX ⧉`, and the `firstmate` row count as idle; any other row reads `unknown`. |
| Turn state | `UserPromptSubmit` opens a busy record; `Stop`, `Notification` with `idle_prompt`, and `SessionEnd` close it; `Stop` also touches the task's turn-ended marker. |
| Trust | A fresh worktree displays `Trust this folder?` with `Trust this folder` selected. Spawn reads the live viewport, answers the complete dialog once with Enter, and waits for the prompt hook to prove brief receipt. |
| Interrupt | One Escape cancels a running turn; Ctrl+U clears a prompt Droid restores from its steering queue. |
| Exit | `/exit` terminates the interactive TUI. |
| Resume | `droid --resume <sessionId>` resumes a native session, while Firstmate's deterministic `relaunch` starts from the brief and progress note. |
| Identity | The live process name is exactly `droid`, with no verified child environment marker; process ancestry identifies it. |
| Skill invocation | Use the TUI's slash command, such as `/no-mistakes`, when that skill is installed. |

The settings file lives under this task's Firstmate `state/` and is removed on relaunch or teardown.
No project `.factory/` file or user Factory hook configuration is changed.
Folder trust is an interactive Droid decision on the isolated worktree; the spawn does not write Factory's trust store.
Only backends with a verified viewport capture can launch Droid, because a history capture could replay a stale trust dialog and send Enter to a live composer.

The CLI and hook contracts come from `droid --help`, `droid exec --help`, and Factory's [CLI reference](https://docs.factory.com/droid-cli/cli-reference.md), [settings reference](https://docs.factory.com/droid-cli/settings.md), and [hooks reference](https://docs.factory.com/harness/hooks.md).
[`docs/verification/runtime-backends.md`](../../../../../docs/verification/runtime-backends.md#factory-droid-cli) records the current live evidence.
