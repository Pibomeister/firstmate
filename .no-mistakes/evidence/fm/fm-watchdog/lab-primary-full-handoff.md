# Firstmate handoff

## Why this handoff
Watchdog reported low context and asked for a full handoff before a restart.

## Session state
- Session start ran once (`bin/fm-session-start.sh`). Lock acquired. Role: user (default).
- Home (`FM_HOME`): /private/var/folders/93/6w1bxqxn2yb92mt6rmt5zbzw0000gn/T/fm-lab.qHagTO
- Fleet: no work under way, no orphan status logs, no queued backlog. data/backlog.md, projects.md, secondmates.md, captain.md, captain-shared.md and learnings.md were ABSENT at start. AFK is absent.
- Network checks: finished with no problems.
- Heartbeat written once with `bin/fm-heartbeat.sh --write`.

## Operational inputs handled this session
1. Watchdog said 1 input had waited 33 minutes. Drained the wake queue: one `check: inbox` wake ("captain note waiting"). The captain inbox was empty (`fm-inbox.sh list` and `drain`). Acked wake sequence 1 with the printed `--ack-through 1 --recovery-generation 94029.1793573290.phV53Q` command. No error.
2. Watchdog reported low context and asked for this handoff, then a restart request.

## Open items
- None. No captain decisions pending. No PRs or projects touched.

## Next session should
- Run `bin/fm-session-start.sh` once and read its digest.
- Drain the wake queue before anything else.
