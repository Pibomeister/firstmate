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
The `bin/fm-quota-reroute.sh` header owns which account and worktree signals count, including marketplace clones and stale cache copies.

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

Status: PARTIAL (2026-11-05 America/Costa_Rica). Tooling gate and suggest proven live. Live Herdr Claude secondmate + relaunch refusal proven. Usage-limit relaunch (checklist 1–2 and naming-the-pick half of 5) not run: Claude was not at a usage limit (live quota-axi: ~76% weekly left). Empirical run on tip 9f3ad77f; post-rebase head c177fee6 carries the same gate (adv15 clean).

Date: 2026-11-05 ~09:50 America/Costa_Rica (UTC-6).

Herdr version: herdr 0.7.4

Codex CLI version: codex-cli 0.166.0 (Logged in using ChatGPT)

Claude Code version: 2.1.317 (loggedIn true, claude.ai)

quota-axi: 0.1.69 in ~/.local/bin (floor 0.1.51). Round 2 used a LIVE `quota-axi --provider claude,codex --json` snapshot (schemaVersion 5). Round 1 had used a hand-written fixture before quota-axi was installed.

Herdr default session: started headless (`herdr server`) only for the fm-herdr-lab tripwire; no agents attached. Stopped afterward (`herdr session stop default`). Before stop: running=true. After: running=false. Lab sessions were only `fm-lab-*`.

Exact commands (abbreviated; full logs on the box under /tmp/gs010-live/):

```sh
# Round 1: gate/suggest on clean worktree + throwaway config dirs
bin/fm-quota-reroute.sh claude-tooling --config-dir "$HOME/.claude" --worktree <clean-wt>
bin/fm-quota-reroute.sh suggest --from-harness claude --kind secondmate \
  --claude-config-dir "$HOME/.claude" --worktree <clean-wt> \
  --candidate codex:gpt-5.4 --snapshot <fixture-then>

# Round 2: lab + seeded secondmate + live snapshot
herdr server   # tripwire only; stop after
bin/fm-herdr-lab.sh provision fm-lab-gs010r2-…
FM_HOME=<lab> bin/fm-home-seed.sh labmate <sm-home> --no-projects
HERDR_SESSION=<lab> FM_HOME=<lab> bin/fm-spawn.sh labmate <sm-home> \
  --harness claude --backend herdr --secondmate
quota-axi --provider claude,codex --json > /tmp/gs010-live/quota-axi-live.json
bin/fm-quota-reroute.sh claude-tooling --config-dir "$HOME/.claude" --worktree <sm-home>
bin/fm-quota-reroute.sh suggest … --snapshot /tmp/gs010-live/quota-axi-live.json
FM_HOME=<lab> bin/fm-control.sh labmate relaunch --harness codex
FM_HOME=<lab> bin/fm-watchdog.sh once
bin/fm-herdr-lab.sh teardown <lab-session>
herdr session stop default
```

Observed output:

```text
# Round 1 (clean worktree)
claude-tooling real ~/.claude + clean wt     -> exit 1 (no signal)
suggest                                      -> "codex gpt-5.4" exit 0
claude-tooling MCP / hooks / marketplace flat .mcp.json / worktree .mcp.json / missing dir
  -> each exits 0 with the named signal; suggest -> none exit 1
prepare/provision with default stopped       -> tripwire refuse (fixed in round 2)

# Round 2 (seeded secondmate on Herdr lab)
provision fm-lab-…                           -> 0
spawn labmate harness=claude backend=herdr   -> pane w1:p2 (theme picker, not usage-limit)
claude-tooling on seeded sm-home             -> "worktree .claude/skills" exit 0
suggest with live quota-axi                  -> none exit 1 (names worktree .claude/skills)
relaunch --harness codex                     -> refuse exit 1; pane/harness unchanged
watchdog once                                -> 0; no pick named; no relaunch
default after stop                           -> running=false
```

Seeded-home product note: `fm-home-seed` plants worktree `.claude/` (skills symlink, settings.json, mods/firstmate-calm with plugin.json and hooks). Unchanged seed is identified by git blob identity against this tree's `HEAD:.claude`, not by path names, and is not a worktree signal. A user hook, a user edit of a seeded file, and user MCP config still refuse. Round 2 below recorded the pre-exemption live refusal; portable tests now cover the exemption.

Checklist (combined):

1. Relaunch closes a usage-limit pane without Enter: BLOCKED (no usage-limit screen; quota not burned to force one).
2. Replacement starts on Codex on Herdr: BLOCKED (no usage-limit screen). Unchanged seeded `.claude/` no longer refuses that move; a user hook, seed edit, or MCP config still would.
3. Claude harness pin with no other signal does not block: PARTIAL (gate+suggest on clean worktree in round 1; live relaunch not exercised without a signal).
4. Any Claude-specific signal keeps the mate on Claude: PROVEN (gate+suggest round 1; live `fm-control relaunch` refusal on a real Herdr Claude pane in round 2).
5. Watchdog names the pick and does not relaunch: PARTIAL (live no-op correct without a usage-limit pane; naming the pick needs that pane).

Cleanup: lab teardown 0; lab homes removed; Herdr default stopped; gs007 tmux sessions untouched; no commits from the proof runners.

## Out of scope for this run

A weekly-limited Claude account against live `quota-axi`.
A Grok weekly-limit composer on Herdr.
If the replacement cannot start after the old endpoint is closed, keep the rollback and file that separately.
