# Captain self-nudge SPEC (JSONL and beacon line)

This page is the single owner of the on-disk event formats emitted by `bin/fm-captain-nudge.sh`.
Behaviour, install, and hard limits live in [`captain-nudge.md`](captain-nudge.md).
The script header owns commands and files.

A box-side watchdog that can only `orca terminal read` a beacon pane should parse the compact line.
The JSONL file is for the host operator and for firstmate; it is not required on the far side of a title-matched tail pane.

## JSONL log

Path: config `jsonl_log`, default `<state_dir>/nudge.jsonl`.
One JSON object per line, UTF-8, no pane body and no secrets in any field.

Required keys:

| Key | Type | Meaning |
| --- | --- | --- |
| `ts` | string | ISO-8601 local time with numeric offset, `YYYY-MM-DDTHH:MM:SS±HH:MM` |
| `host` | string | Config `host` token (`m4`, `m3`, `studio`, `dev01`, `goodword-factory`) |
| `captain` | string | Config captain `id` |
| `event` | string | Decision name from the table below |
| `severity` | string | `info`, `low`, `medium`, or `high` |
| `owner` | string | Captain `owner` (`firstmate`, `abaco`, `casco`, `regulis`, `goodword`) |
| `reason` | string | Short machine-and-human reason; never pane text |
| `idle_min` | number | Observed idle minutes at decision time |
| `open_work` | string | Open-work summary (`none`, `2 open PR(s) (org/repo:2)`, `unreadable: ...`) |

Optional keys the current writer also sets: `epoch` (unix seconds), `should_send` (bool), `dry_run` (bool), `target` (pane/terminal handle), `backend` (`orca`/`herdr`/`fixture`).
Readers must ignore unknown keys.

### Events

| `event` | `severity` | When |
| --- | --- | --- |
| `nudge` | `info` | Typed (or would type, in dry-run) the fixed prompt |
| `skip_not_idle` | `info` | Idle below `idle_min` |
| `skip_no_open_work` | `info` | No proven open PRs or queue items |
| `skip_cooldown` | `info` | Per-captain cooldown still running |
| `skipped_input_not_empty` | `info` | Composer or Orca `draft` holds text |
| `blocker` | `medium` | Modal/picker/permission visible, composer unknown, pane send failed, or composer unproven |
| `skip_pane_missing` | `medium` | Configured terminal or pane not found |
| `skip_read_failed` | `medium` | Pane read failed |
| `nudge_no_progress` | `high` | Two consecutive nudges with no output/commit/heartbeat advance; nudging this captain stops until progress resumes |

Example:

```json
{"ts":"2026-11-09T14:56:00-06:00","host":"m4","captain":"m4main","event":"nudge","severity":"info","owner":"firstmate","reason":"idle with open work, composer empty, no modal","idle_min":25,"open_work":"2 open PR(s) (Pibomeister/firstmate:2)"}
```

## Beacon line (`NUDGE v1`)

Path: config `beacon_log`.
On M4 this is typically `~/orca/beacon/beacon.log` (same file the `orca-beacon` pane tails).
On the Abaco and Goodword relays it is the matching `abaco-beacon.log` / `gw-beacon.log` (or their M4/M3 mirror files).
The writer appends one line and keeps the last 500 lines.
Existing `BEACON v1` / `ABACO v1` / `GW v1` parsers that match on their own prefix keep working; they ignore `NUDGE v1`.

Format, single line, space-separated `key=value` tokens, no spaces inside values:

```
NUDGE v1 ts=<epoch> host=<host> captain=<id> event=<event> severity=<severity> owner=<owner> idle_min=<n> open_work=<0|1>
```

| Token | Meaning |
| --- | --- |
| `ts` | Unix epoch seconds of the decision |
| `host` | Same as JSONL `host` |
| `captain` | Same as JSONL `captain` |
| `event` | Same as JSONL `event` |
| `severity` | Same as JSONL `severity` |
| `owner` | Same as JSONL `owner` |
| `idle_min` | Same as JSONL `idle_min` |
| `open_work` | `1` when the JSONL summary is not `none` / empty / `0`, else `0` |

Example:

```
NUDGE v1 ts=1762721760 host=m4 captain=m4main event=nudge severity=info owner=firstmate idle_min=25 open_work=1
```

A remote parser should take the newest `NUDGE v1` line in the pane.
Treat `event=nudge_no_progress` with `severity=high` as a wake for that `owner` and for firstmate.
Missing or stale `NUDGE v1` lines are not a stall by themselves; the host heartbeat lines (`BEACON v1` / `ABACO v1` / `GW v1`) remain the liveness signal.

## Fixed prompt

The only legal typed payload is:

```
Continue open work: pick next item, reroute quota if exhausted, never park self-servable work
```

`bin/fm-captain-nudge-lib.sh`'s `fm_nudge_text` is the implementation of that string.
A send path that would type any other text must refuse.
