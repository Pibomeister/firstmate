# Captain self-nudge (no AI)

`bin/fm-captain-nudge.sh` is a host-local, model-free typer for long-running firstmate captains.
It runs under launchd on macOS or a systemd user timer (cron fallback) on Linux, and it sends **one fixed prompt** when a configured captain has been idle long enough and still has open work.

This is not the assistant watchdog.
[`watchdog.md`](watchdog.md) owns the per-home watchdog that can nudge, settle dialogs, or restart a session and may call a cheap model for a judgment a script cannot make.
This tool never calls a model, never restarts a captain, and never types anything except the prompt below.

The JSONL object and the `NUDGE v1` beacon line are owned by [`captain-nudge-spec.md`](captain-nudge-spec.md).
The config file schema is owned by [`configuration.md`](configuration.md#captain-self-nudge-configfirstmatecaptain-nudgejson).
The script header owns commands, flags, files, and the send/guard mechanics.

## When it types

For each configured captain on this host, one pass fires the prompt only when every gate holds:

1. Idle at least `idle_min` minutes (default 20), from the newer of Orca `lastOutputAt` and `state/heartbeat.json` `generated_epoch`.
2. Open work is proven: GitHub open PRs via read-only `gh pr list` for configured repos, and/or a local queue file, and/or an allowlisted `gh` read command.
3. The visible screen has no modal, picker, permission prompt, or Yes/No choice.
4. The composer is proven empty (and Orca's `draft` field is empty).
5. The per-captain cooldown (default 30 minutes) has elapsed.
6. The captain is not in the no-progress stop: after two consecutive nudges whose output, heartbeat, and commit fingerprint did not move, the tool emits `nudge_no_progress` at high severity and stops until progress resumes.

If a modal is visible it logs `blocker` and types nothing.
If the input line is not empty it logs `skipped_input_not_empty` and types nothing.
Unknown or unproven composer state is a `blocker`: the tool never overwrites or clears typed text.

The only payload, then Enter:

```
Continue open work: pick next item, reroute quota if exhausted, never park self-servable work
```

## Hard limits

The tool never merges, deploys, spends, runs git or gh mutations, kills or restarts a captain, or runs `herdr server stop`.
The outer guard may restart only this tool's own loop process, and only after the pid file's command line still names `fm-captain-nudge`.

## Install

Copy a host example from [`docs/examples/captain-nudge.md`](examples/captain-nudge.md) to `~/.config/firstmate/captain-nudge.json` and fill pane titles or handles.

macOS (launchd loop plus a 60s outer guard):

```sh
bin/fm-captain-nudge.sh install --config ~/.config/firstmate/captain-nudge.json
```

Linux with a systemd user bus (service plus guard timer):

```sh
bin/fm-captain-nudge.sh install --config ~/.config/firstmate/captain-nudge.json
```

Linux without systemd user (cron every 5 minutes plus a 1-minute guard):

```sh
bin/fm-captain-nudge.sh install --config ~/.config/firstmate/captain-nudge.json
```

Uninstall is the same command with `uninstall` and is idempotent on both platforms.
`install --dry-run` prints the units or cron lines without loading them.

## Commands

```sh
bin/fm-captain-nudge.sh once --config ~/.config/firstmate/captain-nudge.json
bin/fm-captain-nudge.sh once --config ~/.config/firstmate/captain-nudge.json --dry-run
bin/fm-captain-nudge.sh test-nudge --captain m4main --config ~/.config/firstmate/captain-nudge.json
bin/fm-captain-nudge.sh status --config ~/.config/firstmate/captain-nudge.json
```

`once` is one pass.
`run` is the KeepAlive loop.
`guard` restarts that loop when `loop.heartbeat` is older than `guard_stale_secs` (default 660).
`test-nudge` skips idle, open-work, and cooldown gates for one captain so you can prove the send path; it still refuses a modal or a non-empty input line, and it still sends only the fixed prompt.
`decide` reads one observation JSON object on stdin and prints the decision; tests use this.

## Config paths to fill on each host

| Host | Example | Config path | Captains |
| --- | --- | --- | --- |
| M4 Max | `docs/examples/captain-nudge/m4.json` | `~/.config/firstmate/captain-nudge.json` | m4main, m4ops, casco |
| M3 Max MBP | `docs/examples/captain-nudge/m3.json` | `~/.config/firstmate/captain-nudge.json` | m3 |
| Mac Studio | `docs/examples/captain-nudge/studio.json` | `~/.config/firstmate/captain-nudge.json` | studio (owner regulis) |
| dev01 (Abaco) | `docs/examples/captain-nudge/dev01.json` | `~/.config/firstmate/captain-nudge.json` | abaco (herdr `w1:pG`) |
| goodword-factory | `docs/examples/captain-nudge/goodword-factory.json` | `~/.config/firstmate/captain-nudge.json` | factory |

Fill `handle` or `title` (Orca) / `pane` or `title` (Herdr), `fm_home`, `open_work.repos`, and `beacon_log` so `NUDGE v1` lines land in the pane the box-side watchdog already tails (`orca-beacon`, `abaco-beacon`, `gw-beacon`).

Host notes:

- Prefer an Orca terminal `handle` over `title`: successor captains often reuse a title, and `title` picks the first match. Update the handle when a captain is replaced.
- macOS launchd jobs cannot read `~/Documents` without Full Disk Access, so keep the firstmate checkout that runs this tool outside `~/Documents`; a `fm_home` or `queue_file` there reads as absent under launchd, and open work then has to come from `open_work.repos`.
- Herdr refuses a client whose protocol is newer than the running server. Install with `PATH` putting the herdr binary that matches the server first (for example `PATH="$HOME/.local/bin:$PATH" bin/fm-captain-nudge.sh install ...`); the unit records that `PATH`.
- Herdr has no last-output time, so a Herdr captain's idle time is how long its visible screen has been unchanged (tracked in `state_dir/captains/<id>.screen`). The first pass after install starts that clock.
