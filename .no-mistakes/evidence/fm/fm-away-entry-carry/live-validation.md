# Away-entry live validation

Revision: `53bfdce61369885ecf94e57541524c12fd0830ce`.

The real CLI ran against disposable lab homes with synthetic task statuses, recovery records, and health ledgers. A real Claude primary and supervision engine handled the natural wake on a private tmux server. All seven scoped live scenarios passed. This is local product validation.

## CLI evidence

### Away entry carries blockers and return resolves each key separately

[Full transcript](entry-carry-and-key-resolution.log)

```text
  - demo [key=artifact] still blocked, firstmate remediates before ordinary work: local artifact is unavailable
  - demo [key=token] still blocked, firstmate remediates before ordinary work: local token needs repair
firstmate-actionable blocker: demo [key=artifact] local artifact is unavailable
firstmate-actionable blocker: demo [key=token] local token needs repair
    - demo [key=artifact] local artifact is unavailable
    - demo [key=token] local token needs repair
  - demo [key=artifact] local artifact is unavailable
  - demo [key=token] local token needs repair
catch-up retained-health: supervision ran through the away window with no detected gap (watcher beat 7s old at return)
fm-afk-return: catch-up clear; ordinary captain work may proceed
```

### Refresh preserves the mandate and updates carried keys without duplication

[Full transcript](refresh-carried-keys.log)

```text
    - demo [key=build] original reason
    - demo [key=build] updated reason
    - second [key=deploy] local deployment waits
  - demo [key=build] updated reason
fm-afk-return: catch-up clear; ordinary captain work may proceed
```

### Repeated entry retains missing or corrupt archive recovery obligations

[Full transcript](repeated-archive-recovery.log)

```text
fm-afk-return: catch-up clear; ordinary captain work may proceed
catch-up lifecycle: retained away-posture record missing: {run-worktree}/.test-away-live/repeated-archive-recovery/state/afk-contracts/1795578115.afk-contract; catch-up stays gated
catch-up retained-health: supervision ran through the away window with no detected gap (watcher beat 23s old at return)
catch-up retained-health: supervision ran through the away window with no detected gap (watcher beat 31s old at return)
catch-up lifecycle: retained away-posture record unreadable: {run-worktree}/.test-away-live/repeated-archive-recovery/state/afk-contracts/1795578115.afk-contract; catch-up stays gated
```

### Rollback cannot bypass retained recovery through an old quiet receipt

[Full transcript](rollback-without-contract.log)

```text
catch-up retained: retained away-posture record requires validation: {run-worktree}/.test-away-live/rollback-without-contract/state/afk-contracts/1700000000.afk-contract
catch-up retained: superseded away-posture record requires validation: {run-worktree}/.test-away-live/rollback-without-contract/state/afk-contracts/1700000000-superseded-1.afk-contract
catch-up lifecycle: retained away-posture record missing: {run-worktree}/.test-away-live/rollback-without-contract/state/afk-contracts/1700000000.afk-contract; catch-up stays gated
catch-up lifecycle: superseded away-posture record missing: {run-worktree}/.test-away-live/rollback-without-contract/state/afk-contracts/1700000000-superseded-1.afk-contract; catch-up stays gated
catch-up lifecycle: superseded away-posture record unreadable: {run-worktree}/.test-away-live/rollback-without-contract/state/afk-contracts/1700000000-superseded-1.afk-contract; catch-up stays gated
fm-afk-return: catch-up clear; ordinary captain work may proceed
```

### Interrupted handoff selects the new mandate and window

[Full transcript](interrupted-handoff.log)

```text
  - demo [key=before-retain] still blocked, firstmate remediates before ordinary work: local handoff remains open
firstmate-actionable blocker: demo [key=before-retain] local handoff remains open
    - demo [key=before-retain] local handoff remains open
  - demo [key=before-retain] local handoff remains open
catch-up retained-health: supervision ran through the away window with no detected gap (watcher beat 5s old at return)
catch-up lifecycle: retained away-posture record missing: {run-worktree}/.test-away-live/interrupted-handoff/state/afk-contracts/1795578256.afk-contract; catch-up stays gated
fm-afk-return: catch-up clear; ordinary captain work may proceed
  - demo [key=before-delete] still blocked, firstmate remediates before ordinary work: local handoff remains open
firstmate-actionable blocker: demo [key=before-delete] local handoff remains open
    - demo [key=before-delete] local handoff remains open
  - demo [key=before-delete] local handoff remains open
catch-up retained-health: supervision ran through the away window with no detected gap (watcher beat 73s old at return)
catch-up lifecycle: retained away-posture record missing: {run-worktree}/.test-away-live/interrupted-handoff/state/afk-contracts/1795578324.afk-contract; catch-up stays gated
```

### Each window snapshots fresh health and engine state

[Full transcript](fresh-window-health.log)

```text
  - demo [key=health] still blocked, firstmate remediates before ordinary work: local dependency waits
firstmate-actionable blocker: demo [key=health] local dependency waits
    - demo [key=health] local dependency waits
  - demo [key=health] local dependency waits
catch-up retained-health: supervision ran through the away window with no detected gap (watcher beat 13s old at return)
catch-up retained-health: GAP: watcher downtime was detected during the away window (recovery marker present)
catch-up retained-engine: the supervision session latched at 2026-11-25T03:46:41Z after 2 consecutive engine errors and paused away supervision (last cooldown 300s); not paused at return
fm-afk-return: catch-up clear; ordinary captain work may proceed
```

### Real watcher and Claude engine handle and record an away wake

[Full transcript](natural-wake.log)

```text
1795578334	handled	turn=host-56181-1795578254.1	posture=away	rc=0	reports=1	error=0 cost=0.114293 conversation_cost=0.114293 input=14 cache_read=125913 cache_write=22321 output=1239 turns=8	signal: /private/tmp/fm-lab.beo8o95t/state/demo.status
1795578334	boundary	after 80s
{"seq":1,"epoch":1795578326,"task":"demo","wake":"signal: /private/tmp/fm-lab.beo8o95t/state/demo.status","verdict":"captain","summary":"per your away instructions: \"Watch the isolated local demo status. When demo finished, inspect and record that outcome... leave the demo records\": the demo scout finished (\"local demo verification completed; no work remains\"). It has no PR and no report beyond that line. I merged, dispatched, sent and tore down nothing, and left the demo records in place. Teardown is left for you.","silent":false,"statusEndpoint":73,"statusIdent":"strong:16777232:1496984288:1795578259.215865522"}
```

## Isolation and cleanup

The lab primary used a 140-column by 40-row private tmux terminal. Its host exited with status 0 and its private tmux server was stopped. The disposable lab homes were removed. No source or test files changed.

The first natural-wake attempt stopped before watcher readiness because the temporary home used a noncanonical path. The rerun used the canonical lab path and passed the existing guard without a bypass.

## Targeted regression checks

All commands completed with exit status 0:

- `bash tests/fm-afk-contract.test.sh`
- `bash tests/fm-afk-launch.test.sh`
- `bash tests/fm-afk-return.test.sh`

The launch suite exercised its isolated Herdr and tmux paths. Its optional Rex topology case skipped because the Rex CLI is unavailable. The changed behavior has separate successful live lab evidence above. No full repository suite, linter, formatter, pipeline control, push, or PR phase ran. The worktree is clean at the target revision.
