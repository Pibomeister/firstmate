# Quota reroute live verification

Audience: maintainer verification.

This is a runbook for a deferred live box run.
It is not evidence.
Portable tests cover the classifier, the stop path, the tooling gate, and the watchdog naming the pick.
They cannot prove a live Herdr pane plus a Codex secondmate relaunch.

The usage-limit classification live guard, if any, lives in [`runtime-backends.md`](runtime-backends.md) and the `live-harness-optin` family.
This change does not add a new `fm_live_gate`.
The box live Herdr plus Codex relaunch below is the empirical proof for this change.

Run it on a box with Herdr, a logged-in Codex CLI, and a secondmate already bound to Herdr.

Do not run it on a Cloud Agent VM.

## Procedure

Use a disposable secondmate whose recorded backend is `herdr` and whose recorded harness is `claude`.
Keep `config/claude-account` and `config/pi-account` as they are.
Do not remove those pins.

Confirm the recorded backend before anything else.

```sh
FM_HOME=<home> bin/fm-crew-state.sh <mate-id>
```

The line must name backend herdr.

Set an explicit candidate list in `config/watchdog`.

```text
reroute-candidates=codex:gpt-5.4,claude:sonnet
```

### Claude tooling gate

Empty MCP map, no account hooks, and no worktree signals should allow the move.
Account-wide skills, agents, commands, plugins, and enabledPlugins do not block.

```sh
bin/fm-quota-reroute.sh claude-tooling --config-dir "$HOME/.claude" --worktree <mate-home>
echo $?
```

Record whether exit status is 1 when none of the signals in the `bin/fm-quota-reroute.sh` header are present.
A missing or unreadable `--config-dir` should exit 0 and print `unreadable Claude config dir`.
Omitting `--config-dir` resolves `config/claude-account` in `FM_HOME` (optional `--mate`).
A broken pin is a signal.
`fm-control.sh <id> relaunch --harness <other>` of a Claude task should refuse on that signal, and on any `claude-tooling` exit other than 1, naming the reason.
There is no override flag.

With an MCP server configured, the same command should exit 0 and name `MCP servers in ...`.

Then:

```sh
bin/fm-quota-reroute.sh suggest --from-harness claude --kind secondmate \
  --claude-config-dir "$HOME/.claude" --worktree <mate-home> \
  --candidate codex:gpt-5.4 --snapshot <quota-axi-output>
```

Record whether stdout is `none`, exit status is 1, and stderr names the blocking signal.
Do not relaunch in that state.
Queue until reset.

### Watchdog names the pick

With the mate on a usage-limit pane and `quota-axi` able to see Codex headroom:

```sh
FM_HOME=<home> bin/fm-watchdog.sh once
```

Record whether `data/watchdog/status.md` contains:

```text
usage-limit on <mate>. Suggested pick: codex gpt-5.4. Supervisor relaunches. The watchdog does not change the runtime.
```

The ledger row should be `quota suggest held`.
There should be no `fm-control.sh relaunch` process and no new Codex pane yet.

### Supervisor relaunch

After the stale wake names the pick:

```sh
FM_HOME=<home> bin/fm-quota-reroute.sh suggest --from-harness claude --kind secondmate \
  --claude-config-dir "$HOME/.claude" \
  --candidate codex:gpt-5.4 --snapshot <quota-axi-output>
FM_HOME=<home> bin/fm-control.sh <mate-id> relaunch --harness codex
```

Record whether stdout matches:

```text
relaunched <mate-id> harness=codex from=claude model=default effort=<prior-effort> backend=herdr endpoint=<herdr-pane> worktree=<mate-home>
```

`effort=` should be the effort the mate was already running.
Omitting `--effort` must not reset it to `default`.

`bin/fm-crew-state.sh <mate-id>` should then name harness=codex and backend=herdr.
The Herdr pane should be a new Codex session, not the old Claude picker.
The picker should have received no Enter.
The old pane should be gone.
Herdr session history should not show a selected "Switch to Sonnet" or "Wait" option as the last action.

### Interrupt stays refused

Before the relaunch, on the same usage-limit pane:

```sh
FM_HOME=<home> bin/fm-control.sh <mate-id> interrupt
```

Record whether the command is nonzero, names `usage-limit screen`, and delivers no Escape.

### What this run is for

1. `fm-control.sh <id> relaunch --harness codex` closes a Herdr usage-limit pane without sending Enter.
2. The replacement agent starts on Codex in the same secondmate home, on the recorded Herdr backend.
3. `config/secondmate-harness` pointing at Claude does not block that move when no Claude-specific signal is present.
4. Any Claude-specific signal keeps the mate on Claude until reset.
   The `bin/fm-quota-reroute.sh` header owns the list, including a missing or unreadable config dir.
   Resolve that dir from `config/claude-account`, not from `claude-config-dirs`.
5. The watchdog names the pick and does not relaunch.

## Results

Status: NOT YET RUN.

Date:

Herdr version:

Codex CLI version:

Claude Code version:

Exact commands:

Observed output:

## Out of scope for this run

A weekly-limited Claude account against live `quota-axi`.
A Grok weekly-limit composer on Herdr.
If the replacement cannot start after the old endpoint is closed, keep the rollback and file that separately.
