# Live watcher validation

Production revision: `db0511b9b046f06dde5655ace113960421fbf195`.

The installed Codex 0.163.0 ran in a disposable marked home on a private tmux socket with a 140 by 45 grid. Commands ran through Codex shell mode. Hooks were disabled for this lab to avoid changing hook trust. The exact test drivers and Codex transcript are saved beside this report. The lab was torn down.

## Quiet checkpoints

Source: `live-quiet.stdout`

```text
checkpoint: no actionable wake within 2s
```

## Quiet host checkpoint

Source: `live-host-quiet.stdout`

```text
checkpoint: no actionable wake within 4s
```

## Empty queue recovery generation

Source: `live-empty-recovery.state`

```text
before=pending:downtime:14671.1793059019.2hkvS7
after=acked:downtime:14671.1793059019.2hkvS7
queue_bytes=0
```

## Concurrent durable wake

Source: `live-empty-arm.stdout`

```text
watcher: started pid=14897 (beacon fresh)
check: rearm-resurface
```

## Buried wake announced once

Source: `live-buried-first.stdout`

```text
check: rearm-resurface
```

## Next announced checkpoint stays quiet

Source: `live-buried-second.stdout`

```text
checkpoint: no actionable wake within 2s
```

## Bounded interrupted startup

Source: `live-interrupted.stderr`

```text
watcher: recovery state could not be persisted; retaining stale lock evidence
```

## Interrupted startup state

Source: `live-interrupted.state`

```text
elapsed_seconds=3
lock_pid=25299
beacon_exists=no
```

## Owned arm stalled after delivery

Source: `live-owned-stall.stdout`

```text
watcher: started pid=82207 (beacon fresh)
check: rearm-resurface
watcher: FAILED - started watcher pid=82207 stalled (beacon 12s at or past hard bound 12s)
```

## Attached arm stalled after delivery

Source: `live-attached-stall.stdout`

```text
watcher: attached pid=82207 (beacon 0s)
check: rearm-resurface
watcher: FAILED - attached watcher pid=82207 stalled (beacon 12s at or past hard bound 12s)
```

## Completed cleanup failure reaches the host

Source: `live-host-completed.stdout`

```text
watcher: started pid=36544 (beacon fresh)
supervision-host: watcher: recovery state could not be persisted; retaining stale lock evidence
supervision-host: watcher: recovery state could not be persisted; retaining stale lock evidence
signal: /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5WPXNZDE1WCTBNY9HZY8TTC/.test-phase-tmp/live-host-completed-failure/state/demo.status
```

## Forced retirement retains the wake and diagnostic

Source: `live-host-retired.stdout`

```text
watcher: started pid=43976 (beacon fresh)
supervision-host: watcher: recovery state could not be persisted; retaining stale lock evidence
signal: /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5WPXNZDE1WCTBNY9HZY8TTC/.test-phase-tmp/live-host-retired-failure/state/demo.status
supervision-host: watcher: recovery state could not be persisted; retaining stale lock evidence
supervision-host: cycle boundary - the host ended its park at its bound; drain, acknowledge, and end the turn, and the next park starts on its own
```

## Predecessor recovery retains the wake and diagnostic

Source: `live-host-predecessor-replacement.stdout`

```text
supervision-host: watcher: recovery state could not be persisted; retaining stale lock evidence
signal: /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5WPXNZDE1WCTBNY9HZY8TTC/.test-phase-tmp/live-host-predecessor-failure/state/demo.status
supervision-host: watcher: recovery state could not be persisted; retaining stale lock evidence
supervision-host: the host could not finish predecessor cleanup or write its record
```

## Pre-confirmation retirement after exec identity changes

Source: `live-predecessor-replacement.stdout`

```text
supervision-host: watcher: recovery state could not be persisted; retaining stale lock evidence
supervision-host: the host could not finish predecessor cleanup or write its record
```

## Healthy attended successor

Source: `live-attended.stdout`

```text
watcher: started pid=39668 (beacon fresh)
signal: /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5WPXNZDE1WCTBNY9HZY8TTC/.test-phase-tmp/live-attended/state/demo.status
```

## Successor remains alive at handback

Source: `live-attended.state`

```text
successor_pid=47511
successor_alive=yes
```

## Recovery after interrupted lock handoff

Source: `live-takeover-recovered.stdout`

```text
watcher: started pid=64599 (beacon fresh)
supervision-host: cycle boundary - the host ended its park at its bound; drain, acknowledge, and end the turn, and the next park starts on its own
```

## Invalid startup is refused

Source: `live-invalid-startup.stdout`

```text
supervision-host: watcher: FAILED - FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS must be whole seconds from 1 to 600
```

## Unowned singleton is refused

Source: `live-singleton-refusal.stderr`

```text
checkpoint: watcher is already running outside this foreground checkpoint
```

## Targeted test correction

The initial checkpoint run and a separate reproduction failed because a test required the retired watcher itself to print a diagnostic on its original stderr. The captured host output already reported the required cleanup failure and retained matching lock evidence. The test now checks the host failure contract; mismatched identity cases still require the original watcher diagnostic. See `test-assertion-fix.diff` and the preserved before-fix transcripts.

## Final targeted results

All four requested scripts exited 0: `fm-watch-checkpoint`, `fm-watch-arm`, `fm-supervision-host`, and `fm-watcher-lock`. The checkpoint script passed after the test-only assertion correction. The lock script passed after removing the outer test runner’s `FM_HOME` override. The initial outputs and setup attempts remain available; `test-results.json` records the commands and outcomes.

The away-entry and generated protocol outputs are in `live-afk-transcript.log`; the inactive note appears before a healthy watcher and is omitted on refresh while it is healthy.
