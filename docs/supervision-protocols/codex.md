Mode: Codex Stop hook.

A bounded checkpoint is a tool call, not a conversation turn.
When a checkpoint you already started is still running, poll it with `write_stdin` (empty input) until it exits, handle its wake, and do not end the turn while it runs.
Do not start another `bin/fm-watch-checkpoint.sh` after it exits.

In a secondmate home, apply the routed-work and return-channel rules in `data/charter.md` before the next supervision wait.

When this session owns supervision and no away daemon is active:
The Stop hook re-arms a persistent watcher or allows this turn to end.
That watcher has no doorbell, so its wakes wait for the captain's next message.
A secondmate home keeps one outside-turn watcher instead of another checkpoint.
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`.
   Until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. Poll a checkpoint only while it is still running.
   When the call returns a still-running exec session, poll it with `write_stdin` (empty input) until it exits.
4. Ordinary wake: if a running checkpoint prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, acknowledge it, then end the turn.
   Do not start another foreground checkpoint.
5. If the checkpoint exits 0 and prints `checkpoint: no actionable wake`, drain queued wakes anyway, process any queued user message now visible to Codex, then end the turn.
   In a secondmate home, `checkpoint: firstmate instruction waiting in the steering inbox` names records to read, act on and acknowledge now, then stop.
6. Send a reply as an interim message only while a checkpoint of yours is still running.
   Once the queue is drained and no checkpoint of yours is running, the final answer may end the turn.
7. Never use shell `&` or Codex background tasks for firstmate watcher supervision.
8. Do not run `bin/fm-watch-arm.sh` as Codex's normal supervision command.
   If it is ever shelled anyway, a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.codex/hooks.json`.
9. On a failure or a missing cycle, drain queued wakes, then end the turn so the Stop hook can re-arm or allow the stop.
   Do not start a fresh foreground checkpoint to keep the turn open.

Codex cannot reason while a foreground tool call is running.
The bounded checkpoint returns control so a checkpoint that is already running can be polled.
