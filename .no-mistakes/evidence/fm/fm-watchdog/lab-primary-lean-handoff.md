# Watchdog restart handoff - fm-lab.qHagTO

- home: /private/var/folders/93/6w1bxqxn2yb92mt6rmt5zbzw0000gn/T/fm-lab.qHagTO
- reason: restart-requested
- at: 2026-11-01T22:49:28Z
- newest session handoff: /private/var/folders/93/6w1bxqxn2yb92mt6rmt5zbzw0000gn/T/fm-lab.qHagTO/data/handoff-firstmate.md
- owed input: 0 rows, oldest 0s
- away mode: 0

Start with the newest session handoff above when it exists, then run the session-start contract.

Pane tail at restart:

```

❯ : Firstmate operational input waiting: read
  '/private/var/folders/93/6w1bxqxn2yb92mt6rmt5zbzw0000gn/T/fm-lab.qHagTO/state/operational-inbox/1793573286-253ee1d3e4303a0a.msg' and handle its
  contents as Firstmate operational input.

  Read 1 file, ran 4 shell commands

⏺ I read the operational input and drained the wake queue. The watchdog reported one input waiting 33 minutes.

  The queue held one check: inbox wake, "captain note waiting". I checked the captain inbox, and it is empty (fm-inbox.sh list and drain both report
  no notes). So the wake had no note behind it, probably a stale one. I then acknowledged wake sequence 1 with the printed --ack-through command, and
  it returned no error.

  Nothing needs your decision. If the watchdog fires again with the inbox still empty, that points to a wake-writing problem and is worth a look.

✻ Cooked for 10s · done 4:48 PM

❯ : Firstmate operational input waiting: read
  '/private/var/folders/93/6w1bxqxn2yb92mt6rmt5zbzw0000gn/T/fm-lab.qHagTO/state/operational-inbox/1793573332-4e0128ebb02efb7b.msg' and handle its
  contents as Firstmate operational input.

  Read 1 file, ran 1 shell command

⏺ I wrote the handoff and created the restart request, as the watchdog asked.

  - Handoff: data/handoff-firstmate.md in the lab home. It records the session start, the empty fleet, the heartbeat, the inbox wake I drained and
    acked, and the next steps for the new session.
  - Restart request: state/.watchdog-restart-request is in place. The watchdog should now restart this session from that handoff.

  Nothing is pending on your side.

✻ Sautéed for 8s · done 4:49 PM
  #3 Reply with exactly the word DRAFTOK and nothing else.                                                                                        [-]
  ││┃││

──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ 
──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

  ⏵⏵ bypass permissions on (shift+tab to cycle)
```
