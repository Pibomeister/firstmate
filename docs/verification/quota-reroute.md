# Quota reroute live verification

Audience: maintainer verification.

This is a runbook for a deferred live box run.
It is not evidence.
Portable tests cover the classifier, the stop path, the tooling gate, and the watchdog naming the pick.
They cannot prove a live Herdr pane plus a Codex secondmate relaunch.

The usage-limit pane-text live guard is `tests/fm-usage-limit-pane-live.test.sh`.
It is skip/pending by default and never passes on that path.
Classify only an existing already-limited pane named by `FM_USAGE_LIMIT_PANE` with `FM_USAGE_LIMIT_PANE_LIVE=1`.
That path is read-only capture and never types Enter.
The verb header in [`bin/fm-control.sh`](../../bin/fm-control.sh) owns close policy.
Dated Grok weekly-limit evidence is in [`runtime-backends.md`](runtime-backends.md) and does not cover the pane-picker classifier.
The box live Herdr plus Codex relaunch below remains the empirical proof for the tooling gate and suggest path.

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
The Signals paragraph in [`bin/fm-quota-reroute.sh`](../../bin/fm-quota-reroute.sh) owns which account and worktree signals count.

```sh
bin/fm-quota-reroute.sh claude-tooling --config-dir "$HOME/.claude" --worktree <mate-home>
echo $?
```

Record whether exit status is 1 when none of those signals are present.
A missing or unreadable `--config-dir` should exit 0 and print `unreadable Claude config dir`.
Omitting `--config-dir` resolves `config/claude-account` in `FM_HOME` (optional `--mate`).
Record the printed signal and exit for a broken pin.
`fm-control.sh <id> relaunch --harness <other>` of a Claude task should refuse on that signal, and on any `claude-tooling` exit other than 1, naming the reason.
The verb header in [`bin/fm-control.sh`](../../bin/fm-control.sh) owns that refusal.

With an MCP server configured, the same command should exit 0 and name `MCP servers in ...`.

Then:

```sh
bin/fm-quota-reroute.sh suggest --from-harness claude --kind secondmate \
  --claude-config-dir "$HOME/.claude" --worktree <mate-home> \
  --candidate codex:gpt-5.4 --snapshot <quota-axi-output>
```

Record whether stdout is `none`, exit status is 1, and stderr names the blocking signal.
Do not relaunch in that state.

### Watchdog names the pick

With the mate on a usage-limit pane and `quota-axi` able to see Codex headroom:

```sh
FM_HOME=<home> bin/fm-watchdog.sh once
```

Record whether `data/watchdog/status.md` contains:

```text
usage-limit on <mate>. Suggested pick: codex gpt-5.4. Queue until reset. Relaunch closes only a verified Grok weekly-limit composer. The watchdog does not change the runtime.
```

The ledger row should be `quota suggest held`.
There should be no `fm-control.sh relaunch` process and no new Codex pane yet.

### Supervisor relaunch

After the stale wake names the pick, a pane-text usage-limit relaunch is refused:

```sh
FM_HOME=<home> bin/fm-quota-reroute.sh suggest --from-harness claude --kind secondmate \
  --claude-config-dir "$HOME/.claude" \
  --candidate codex:gpt-5.4 --snapshot <quota-axi-output>
FM_HOME=<home> bin/fm-control.sh <mate-id> relaunch --harness codex
```

Record whether the command is nonzero, names `not live-verified`, says `Queue until reset`, and leaves the pane and harness unchanged.
The picker should have received no Enter.
The verb header in [`bin/fm-control.sh`](../../bin/fm-control.sh) owns close policy.

### Interrupt stays refused

On the same usage-limit pane:

```sh
FM_HOME=<home> bin/fm-control.sh <mate-id> interrupt
```

Record whether the command is nonzero, names `usage-limit screen`, says `Queue until reset`, and delivers no Escape.

### What this run is for

1. Observe pane-text relaunch refusal versus Grok weekly-limit close.
   The verb header in [`bin/fm-control.sh`](../../bin/fm-control.sh) owns close policy.
2. Observe a Grok weekly-limit close starting Codex in the same secondmate home, on the recorded Herdr backend.
3. Observe that `config/secondmate-harness` pointing at Claude does not block when Signals reports no tooling.
4. Observe that a Claude-specific signal keeps the mate on Claude.
   The Signals paragraph in [`bin/fm-quota-reroute.sh`](../../bin/fm-quota-reroute.sh) owns that list.
5. Observe that the watchdog names the pick and does not relaunch.

## Results

Status: PARTIAL (2026-11-05 America/Costa_Rica).
Tooling gate and suggest were proven live.
A live Herdr Claude secondmate relaunch refusal was proven.
Usage-limit relaunch (checklist 1-2 and the naming-the-pick half of 5) was not run because Claude was not at a usage limit.
Live quota-axi showed about 76% weekly remaining.

Date: 2026-11-05 ~09:50 America/Costa_Rica (UTC-6).

Herdr version: herdr 0.7.4

Codex CLI version: codex-cli 0.166.0 (Logged in using ChatGPT)

Claude Code version: 2.1.317 (loggedIn true, claude.ai)

quota-axi: 0.1.69 (floor 0.1.51).
The live snapshot used `quota-axi --provider claude,codex --json` (schemaVersion 5).

Commands that produced the still-valid evidence:

```sh
bin/fm-quota-reroute.sh claude-tooling --config-dir "$HOME/.claude" --worktree <clean-wt>
bin/fm-quota-reroute.sh suggest --from-harness claude --kind secondmate \
  --claude-config-dir "$HOME/.claude" --worktree <clean-wt> \
  --candidate codex:gpt-5.4 --snapshot <quota-axi-json>
bin/fm-herdr-lab.sh provision <lab-session>
FM_HOME=<lab> bin/fm-home-seed.sh labmate <sm-home> --no-projects
HERDR_SESSION=<lab> FM_HOME=<lab> bin/fm-spawn.sh labmate <sm-home> \
  --harness claude --backend herdr --secondmate
quota-axi --provider claude,codex --json
bin/fm-quota-reroute.sh claude-tooling --config-dir "$HOME/.claude" --worktree <sm-home>
bin/fm-quota-reroute.sh suggest --from-harness claude --kind secondmate \
  --claude-config-dir "$HOME/.claude" --worktree <sm-home> \
  --candidate codex:gpt-5.4 --snapshot <quota-axi-json>
FM_HOME=<lab> bin/fm-control.sh labmate relaunch --harness codex
FM_HOME=<lab> bin/fm-watchdog.sh once
bin/fm-herdr-lab.sh teardown <lab-session>
```

Observed output:

```text
claude-tooling real ~/.claude + clean wt     -> exit 1 (no signal)
suggest on that clean tree                   -> "codex gpt-5.4" exit 0
claude-tooling MCP / hooks / marketplace flat .mcp.json / worktree .mcp.json / missing dir
  -> each exits 0 with the named signal; suggest -> none exit 1
spawn labmate harness=claude backend=herdr   -> Herdr pane (theme picker, not usage-limit)
relaunch --harness codex on that live pane   -> refuse exit 1; pane/harness unchanged
watchdog once without a usage-limit pane     -> 0; no pick named; no relaunch
```

`fm-home-seed` plants worktree `.claude/` (skills symlink, settings.json, mods/firstmate-calm with plugin.json and hooks).
The Signals paragraph in [`bin/fm-quota-reroute.sh`](../../bin/fm-quota-reroute.sh) owns seed identity.
A live run on 2026-11-05 also refused on worktree `.claude/skills` under the pre-exemption rule.
That observation is historical only.
Portable tests cover the current catalog exemption.
Do not treat that refusal as live proof of current seed behavior.

Checklist:

1. Relaunch of a pane-text usage-limit screen: BLOCKED.
   No usage-limit screen was available, and quota was not burned to force one.
   Close policy is the [`bin/fm-control.sh`](../../bin/fm-control.sh) verb header.
   A dated picker capture is still pending in [`runtime-backends.md`](runtime-backends.md).
2. Replacement starts on Codex on Herdr: BLOCKED.
   No usage-limit screen was available.
   Unchanged seeded `.claude/` no longer refuses that move.
   The Signals paragraph in [`bin/fm-quota-reroute.sh`](../../bin/fm-quota-reroute.sh) owns which user edits still refuse.
3. Claude harness pin with no other signal does not block: PARTIAL.
   Gate and suggest were proven on a clean worktree.
   Live relaunch was not exercised without a signal.
4. Any Claude-specific signal keeps the mate on Claude: PROVEN.
   Gate and suggest refused.
   Live `fm-control relaunch` refused on a real Herdr Claude pane.
5. Watchdog names the pick and does not relaunch: PARTIAL.
   The live no-op was correct without a usage-limit pane.
   Naming the pick needs that pane.

## Out of scope for this run

A weekly-limited Claude account against live `quota-axi`.
A Grok weekly-limit composer on Herdr.
If the replacement cannot start after the old endpoint is closed, keep the rollback and file that separately.
