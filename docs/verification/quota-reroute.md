# Quota reroute live verification

Audience: maintainer verification.

A usage-limit pane must move to another runtime without typing Enter into the picker.
Portable tests cover the classifier, the stop path, the tooling gate, and the watchdog naming the pick.
They cannot prove a live Herdr pane plus a Codex secondmate relaunch.

Run it on a box with Herdr, a logged-in Codex CLI, and a secondmate already bound to Herdr.

Do not run it on a Cloud Agent VM.

## What the live run proves

1. `fm-control.sh <id> relaunch --harness codex` closes a Herdr usage-limit pane without sending Enter.
2. The replacement agent starts on Codex in the same secondmate home, on the recorded Herdr backend.
3. `config/secondmate-harness` pointing at Claude does not block that move when the Claude config dir has no MCP servers.
4. A Claude config dir with at least one MCP server keeps the mate on Claude until reset.
5. The watchdog names the pick and does not relaunch.

## Setup

Use a disposable secondmate whose recorded backend is `herdr` and whose recorded harness is `claude`.
Keep `config/claude-account` and `config/pi-account` as they are. Do not remove those pins.

Confirm the recorded backend before anything else:

```sh
FM_HOME=<home> bin/fm-crew-state.sh <mate-id>
```

The line must name backend herdr.

Set an explicit candidate list in `config/watchdog`:

```text
reroute-candidates=codex:gpt-5.4,claude:sonnet
```

## Claude tooling gate

Empty MCP map (should allow the move):

```sh
bin/fm-quota-reroute.sh claude-tooling --config-dir "$HOME/.claude"
echo $?
```

Expected: exit 1 when `.claude.json` / `settings.json` has no MCP servers.

With an MCP server configured, the same command exits 0, and:

```sh
bin/fm-quota-reroute.sh suggest --from-harness claude --kind secondmate \
  --claude-config-dir "$HOME/.claude" \
  --candidate codex:gpt-5.4 --snapshot <quota-axi-output>
```

Expected: prints `none` and exit 1.
Do not relaunch in that state. Queue until reset.

## Watchdog names the pick

With the mate on a usage-limit pane and `quota-axi` able to see Codex headroom:

```sh
FM_HOME=<home> bin/fm-watchdog.sh once
```

Expected in `data/watchdog/status.md`:

```text
usage-limit on <mate>. Suggested pick: codex gpt-5.4. Supervisor relaunches. The watchdog does not change the runtime.
```

The ledger row is `quota suggest held`.
There is no `fm-control.sh relaunch` process and no new Codex pane yet.

## Supervisor relaunch

After the stale wake names the pick:

```sh
FM_HOME=<home> bin/fm-quota-reroute.sh suggest --from-harness claude --kind secondmate \
  --claude-config-dir "$HOME/.claude" \
  --candidate codex:gpt-5.4 --snapshot <quota-axi-output>
FM_HOME=<home> bin/fm-control.sh <mate-id> relaunch --harness codex
```

Expected:

```text
relaunched <mate-id> harness=codex from=claude model=default effort=<prior-effort> backend=herdr endpoint=<herdr-pane> worktree=<mate-home>
```

`effort=` must be the effort the mate was already running. Omitting `--effort` must not reset it to `default`.

`bin/fm-crew-state.sh <mate-id>` then names harness=codex and backend=herdr.
The Herdr pane is a new Codex session, not the old Claude picker.
The picker received no Enter: the old pane is gone, and Herdr session history does not show a selected "Switch to Sonnet" or "Wait" option as the last action.

## Interrupt stays refused

Before the relaunch, on the same usage-limit pane:

```sh
FM_HOME=<home> bin/fm-control.sh <mate-id> interrupt
```

Expected: nonzero, `usage-limit screen`, no Escape delivered.

## Not proved here

A weekly-limited Claude account against live `quota-axi`.
A Grok weekly-limit composer on Herdr.
The shipcontent-mate "could not be launched on codex" incident. If that relaunch fails after the endpoint is closed, keep the rollback and file it separately.
