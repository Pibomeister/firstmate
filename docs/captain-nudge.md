# Captain self-nudge (no AI)

`bin/fm-captain-nudge.sh` is a host-local, model-free typer for long-running firstmate captains.
It runs under launchd on macOS or a systemd user timer (cron fallback) on Linux, and it types one of a few **fixed prompts** when a configured captain has stalled with open work or a merge-ready PR has waited too long.

This is not the assistant watchdog.
[`watchdog.md`](watchdog.md) owns the per-home watchdog that can nudge, settle dialogs, or restart a session and may call a cheap model for a judgment a script cannot make.
This tool never calls a model, never restarts a captain, and never types anything except its fixed prompts.

The JSONL object and the `NUDGE v1` beacon line are owned by [`captain-nudge-spec.md`](captain-nudge-spec.md).
The config file schema is owned by [`configuration.md`](configuration.md#captain-self-nudge-configfirstmatecaptain-nudgejson).
The script header owns commands, flags, files, and the send/guard mechanics.

## When it types

For each configured captain on this host, one pass fires the first wake only when every gate holds:

1. Idle at least `idle_min` minutes (default 15), from the newer of Orca `lastOutputAt` and `state/heartbeat.json` `generated_epoch`, or a lane stalled at least `lane_stall_min` minutes (default 20).
2. Open work is proven: GitHub open PRs via read-only `gh pr list` for configured repos, and/or a local queue file, and/or an allowlisted `gh` read command, and/or a stalled lane.
3. The visible screen has no modal, picker, permission prompt, or Yes/No choice.
4. The composer is proven empty (and Orca's `draft` field is empty).
5. The per-captain cooldown (default 30 minutes) has elapsed; the second wake ignores it (see the stall ladder below).
6. The captain is not in the no-progress stop: after two consecutive nudges whose output, heartbeat, and commit fingerprint did not move, the tool emits `nudge_no_progress` at high severity and stops until progress resumes.

If a modal is visible it logs `blocker` and types nothing.
If the input line is not empty it logs `skipped_input_not_empty` and types nothing.
Unknown or unproven composer state is a `blocker`: the tool never overwrites or clears typed text.

The typed payloads, each followed by Enter, are the fixed prompts that [`captain-nudge-spec.md`](captain-nudge-spec.md#fixed-prompts) lists.

## Who it types to

An Orca captain with `fm_home` set is whoever holds that home's session lock right now, as [`bin/fm-captain-locate.sh`](../bin/fm-captain-locate.sh) reports it, not the configured `handle` or `title`.
The tool reads the lock owner's terminal at the start of each pass and reads it again just before it types, so a handoff in between stops the send with a `blocker`.
When the lock is free, stale, mid-handoff, or unreadable, the row is `captain_unknown`: the captain is unknown, not down, and nothing is typed.
A Herdr captain, or an Orca captain without `fm_home`, still uses its configured pane or handle.
Give each Orca captain its own `fm_home`: two captains that name one home both reach that home's single lock owner.

## Stall ladder

A stall runs on the older of two clocks: the captain's idle time and the age of its oldest stalled lane.
A stalled lane is a worker or secondmate stall that the captain home's stall ledger ([`bin/fm-stall-ledger.sh`](../bin/fm-stall-ledger.sh)) still holds open.
The ladder climbs once per stall:

| Stall age | Event | Typed |
| --- | --- | --- |
| `idle_min`, or a lane at `lane_stall_min` | `nudge` | The continue prompt, plus the lane table when a lane is stalled |
| `escalate_min` (default 40), after a first wake | `stall_escalate` | The relaunch-or-replace prompt, plus the lane table |
| `council_min` (default 60) | `stall_council` | Nothing; the row asks the owner's council to rule, even behind a modal |

The ack is the captain's own progress after a wake: new output, a new heartbeat, or a new commit.
The next pass records it as `stall_acked` and resets the ladder.
A prompt this tool types is not an ack: after each send it stores what the pane shows, and the stall age keeps counting from the start of the stall.
A `0` for `escalate_min`, `council_min`, or `lane_stall_min` turns that step off.

## Stall ledger

Each pass runs `fm-stall-ledger.sh observe` for every captain whose `fm_home` is set, so that home's `state/stall-ledger.tsv` keeps recording while its own watcher is quiet.
The ledger's row schema and score bars stay with the stall-ledger script.

## Merge-ready wake

A PR is merge-ready when [`bin/fm-ready-pr-discovery.sh`](../bin/fm-ready-pr-discovery.sh) reports its validation run parked at the ci step with the PR ready (`kind=ci-ready`).
The first pass that sees a PR head merge-ready records `merge_ready` and starts its clock.
After `merge_ready_min` minutes (default 15) the captain gets the merge prompt once for that head, under the same modal and composer gates, and the row is `merge_ready_wait`.
A head that leaves the list records `merge_ready_cleared`.
A run parked at an approval gate is a decision, not merge-ready.

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
`test-nudge` skips idle, open-work, cooldown, ladder, and merge-ready gates for one captain so you can prove the send path; it still refuses a modal or a non-empty input line, and it still sends only the continue prompt.
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

- Set `fm_home` for every Orca captain so the tool follows the lock owner; a configured `handle` or `title` then only names the captain until a successor takes the lock.
- Without `fm_home`, prefer an Orca terminal `handle` over `title`: successor captains often reuse a title, and `title` picks the first match. Update the handle when a captain is replaced.
- macOS launchd jobs cannot read `~/Documents` without Full Disk Access, so keep the firstmate checkout that runs this tool outside `~/Documents`; a `queue_file` there reads as absent under launchd, and an Orca captain whose `fm_home` is there reads as `captain_unknown` on every pass.
- Herdr refuses a client whose protocol is newer than the running server. Install with `PATH` putting the herdr binary that matches the server first (for example `PATH="$HOME/.local/bin:$PATH" bin/fm-captain-nudge.sh install ...`); the unit records that `PATH`.
- Herdr has no last-output time, so a Herdr captain's idle time is how long its visible screen has been unchanged (tracked in `state_dir/captains/<id>.screen`). The first pass after install starts that clock.
