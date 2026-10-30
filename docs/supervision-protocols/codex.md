Mode: Codex foreground checkpoint.

A bounded checkpoint is a tool call, not a conversation turn.
When the checkpoint returns, control comes back to you inside the same turn, and that return does not end the turn.

In a secondmate home, apply the routed-work and return-channel rules in `data/charter.md` before the next supervision wait.

When this session owns supervision and no away daemon is active:
On a plain Codex/Herdr home the foreground checkpoint is the Herdr fallback, and it requires the turn to remain open: nothing resumes the conversation after the model returns, so ending the turn leaves supervision unwatched.
A fresh advancing beacon does not change this.
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
   When the call returns a still-running exec session, poll it with `write_stdin` (empty input) until it exits; never end the turn while your checkpoint runs, because nothing reads its wake or starts the next one once the turn ends.
4. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, acknowledge it, then start exactly one successor checkpoint after the previous command exits.
5. If the command exits 0 and prints `checkpoint: no actionable wake` with no wake, drain queued wakes anyway, process any queued user message now visible to Codex, then start the next checkpoint.
   In a secondmate home, `checkpoint: firstmate instruction waiting in the steering inbox` names records to read, act on and acknowledge now, before the next checkpoint.
6. While supervision is needed, send each captain-facing reply as an interim (commentary) message, then keep polling the running checkpoint or start the next one in the same turn.
   Never send it as the turn's final answer: a final answer ends the turn, and the turn-end guard then blocks it with a visible repair prompt.
   That interim message carries the whole reply and must stand alone exactly as a final reply would.
7. Never use shell `&` or Codex background tasks for firstmate watcher supervision.
8. Do not run `bin/fm-watch-arm.sh` as Codex's normal supervision command.
   If it is ever shelled anyway, a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.codex/hooks.json`.
9. Failure or missing cycle only: drain queued wakes, inspect the failure, then start a fresh foreground checkpoint.
   Keep the turn open while supervision is needed or wakes still need handling and acknowledgement.

Codex cannot reason while a foreground tool call is running.
The bounded checkpoint returns control regularly so user messages and queued wakes can be handled without relying on background-task wake semantics.
