# Handoff: primary firstmate, disposable lab home

Written on 2026-11-01 because the watchdog reported low context and asked for a handoff and restart.
The watchdog message came through the operational inbox. It did not come from the captain.

## Captain's ask

The captain said this is a disposable lab home.
The ask was: run `bin/fm-session-start.sh` once, then `bin/fm-heartbeat.sh --write`, do nothing else, and reply in one sentence.
Both commands ran and exited 0. The captain received that reply.

## Current state

- No work is under way. There are no task records and no workers.
- `data/backlog.md`, `data/projects.md`, `data/secondmates.md`, `data/captain.md` and `data/learnings.md` are absent.
- The wake queue was empty at the last drain. Sequence 1 is acknowledged.
- The inbox is empty and the dispatch ledger has no overdue goals.
- Away mode and quiet mode are inactive.

## Events since the ask

1. A watchdog message said one input had waited 16 minutes.
2. The drain showed one wake: `check inbox captain note waiting`.
3. `bin/fm-inbox.sh drain` and `list` both showed an empty inbox, so no note text could be read.
4. I acknowledged the wake and told the captain to resend the note if they sent one.

## Open items

- The captain has not answered about the missing note. If a note arrives, handle it as a new goal.
- The cause of a wake with no matching note is not investigated. The captain did not ask for that.
- Startup printed an information line: an older `lavish-axi` version keeps the legacy reply path. No action was taken.

## Instructions for the next session

- Run `bin/fm-session-start.sh` once and confirm that the digest is present.
- Start no new work. The captain's scope for this home was "do nothing else".
