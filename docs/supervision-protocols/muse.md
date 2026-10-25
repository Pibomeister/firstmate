Mode: Muse tracked-background supervision.

In a secondmate home, apply the routed-work and return-channel rules in `data/charter.md` before the next supervision wait.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. First cycle: arm exactly one watcher cycle with `bin/fm-watch-arm.sh` as its own tracked background call, and nothing else in that call.
   In Muse that is one shell call left running past its foreground wait so the runtime keeps it as a tracked background task and delivers its completion as a model wake after the turn ends.
   Never bundle the arm onto another command, never add a bounded foreground wait or polling loop around it, and never use shell `&`.
3. Trust only the arm's one-line status.
   `watcher: started ...` or `watcher: attached ...` means one live cycle exists.
4. After a successful start or attach status, end the turn.
   The tracked background arm remains the live wait until it exits with an actionable wake or failure, and its completion wakes the model between turns.
   Because the turn ends promptly, a captain message sent while supervised work runs is accepted at the next turn boundary instead of waiting behind a foreground wait.
5. Waiting is silent.
6. Failure or missing cycle only: `watcher: FAILED ...` means supervision is down; drain, inspect the failure, and re-arm one cycle in the same shape.

When a background-task completion wake arrives for the arm:
1. Run `bin/fm-wake-drain.sh` first.
2. Handle `signal`, `stale`, `check`, or `heartbeat` using the harness-neutral contract in `AGENTS.md`.
3. Ordinary wake: after handling and acknowledgement, re-arm exactly one successor cycle with the same tracked background `bin/fm-watch-arm.sh` call if the home still needs supervision, as `bin/fm-supervision-lib.sh` defines it.
4. Do not invent a wake from an attach-status line alone.
   Drain the queue and act only on real wake records, the drain's `OPEN DECISIONS` and `UNREAD STATUS` entries, or a real watcher reason line.
   Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
   See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.

Muse exposes no Stop, turn-end, or PreToolUse hook in the default build, so no hook blocks a blind turn end or denies a watcher-arm anti-pattern before execution.
The tracked background cycle above is therefore the primary mechanism, not a backstop shape.
[`turnend-guard.md`](../turnend-guard.md) owns that honest limit.
Interactive TUI sessions are the supported Muse primary surface.
