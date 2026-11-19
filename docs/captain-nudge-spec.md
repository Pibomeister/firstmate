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

Optional keys the current writer also sets: `epoch` (unix seconds), `should_send` (bool), `prompt` (the prompt kind typed, or empty), `dry_run` (bool), `target` (pane/terminal handle), `backend` (`orca`/`herdr`/`fixture`), `lanes` (the lane table), and on merge-ready rows `pr` (PR URL, comma-separated when several) and `run` (`<run_id>@<head>`).
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
| `stall_escalate` | `medium` | Second wake of a stall: typed (or would type) the relaunch-or-replace prompt |
| `stall_council` | `high` | Stall reached `council_min`; nothing typed, the owner's council should rule |
| `stall_acked` | `info` | The captain progressed after a wake; the ladder resets |
| `merge_ready` | `info` | A PR head was first seen merge-ready |
| `merge_ready_wait` | `info` | A merge-ready PR head waited `merge_ready_min`; typed (or would type) the merge prompt |
| `merge_ready_cleared` | `info` | A PR head left the merge-ready list |

Example:

```json
{"ts":"2026-11-09T14:56:00-06:00","host":"m4","captain":"m4main","event":"nudge","severity":"info","owner":"firstmate","reason":"idle with open work, composer empty, no modal","idle_min":25,"open_work":"2 open PR(s) (Pibomeister/firstmate:2)"}
```

## Beacon line (`NUDGE v1`)

Path: config `beacon_log`.
On M4 this is typically `~/orca/beacon/beacon.log` (same file the `orca-beacon` pane tails).
On the Abaco and Goodword relays it is the matching `abaco-beacon.log` / `gw-beacon.log` (or their M4/M3 mirror files).
The writer appends one line and keeps the last 500 lines.
A parser that wrap-joins pane rows and splits on its own prefix must cut each piece at the next `NUDGE v1` (or other beacon prefix) before matching keys; otherwise a later `NUDGE v1` line's `ts=` and `host=` overwrite its record.
On a host whose beacon log is relayed by `tail -n 1` (the Abaco and Goodword relays), point `beacon_log` at a separate `~/orca/beacon/nudge-beacon.log` and relay its new `NUDGE v1` lines separately, so a `NUDGE v1` line never displaces the heartbeat line the relay copies.

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

## Fixed prompts

The legal typed payloads are these strings, by prompt kind:

| Kind | Text |
| --- | --- |
| `continue` | `Continue open work: pick next item, reroute quota if exhausted, never park self-servable work` |
| `escalate` | `Still stalled with open work: relaunch or replace the stalled worker, then continue open work` |
| `merge` | `A PR is merge-ready and unmerged: dispatch the merge or record why` |

A `continue` or `escalate` prompt may end with one space and one lane table: `Stalled lanes: ` then one to five `<subject> <age>m` entries separated by `, `, an optional ` (+<n> more)`, and a final `.`.
A subject is 1 to 64 characters from `[A-Za-z0-9._-]`, and an age is whole minutes.
For example: `Stalled lanes: fm-a 25m, fm-b 21m.`

`bin/fm-captain-nudge-lib.sh`'s `fm_nudge_text` and `fm_nudge_prompt_text` implement these strings.
A send path that would type any other text must refuse.
