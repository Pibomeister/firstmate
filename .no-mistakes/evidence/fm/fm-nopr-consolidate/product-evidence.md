# Watchdog product evidence

Target: `262b515b26b462c91840c9d90537720a1ffc04dd`. The targeted checks and isolated product probes passed. Source files were unchanged.

The real installed Claude 2.1.330 CLI ran in a private 140×38 tmux terminal with an isolated configuration and safe mode. Its login picker was opened without completing login. Other probes supplied synthetic terminal inputs to the real watchdog CLI, tmux backend, permission classifier, configured local alert command, and persisted ledgers. No watchdog clock, composer, control, model, or backend implementation was replaced in these manual probes. The real Saturday clock exercised weekend handoff; a deliberately unreadable quiet-hours zone exercised the documented daytime fallback. The default ten-minute grace was observed in the status; escalation probes set the supported `human-step-secs=0` configuration. Normal weekday timing and interval boundaries were also covered by the targeted deterministic tests.

## Installed Claude login picker

```text

 ▐▛███▛█   Claude Code v2.1.330
▝▜██████▀  Opus 5.5 · API Usage Billing
 ▝▝   ▝▝   ~/.no-mistakes/worktrees/075d7f40c28a/01M8038T7GV59P4S4C4H7SYECH

⚠ Safe mode: all customizations are off (CLAUDE.md, skills, plugins, hooks, MCP, agents, and more)
  Restart without --safe-mode to turn customizations back on

▎ Auto mode is now Claude Code's default permission mode.
▎ Auto mode lets Claude handle permission prompts automatically. Claude checks each tool call for risky actions and prompt injection before
▎ executing, runs the ones it assesses as lower-risk, and blocks the rest.
▎ https://code.claude.com/docs/en/permission-modes














▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
  Login

  Claude Code can be used with your Claude subscription or billed based on API usage through your Console account.

  Select login method:

  ❯ 1. Claude account with subscription · Individual, Team, or Enterprise
    2. Anthropic Console account · API usage billing
    3. 3rd-party platform · Bedrock, Microsoft Foundry, Google Vertex AI

  Esc to cancel
```

## Actual watchdog scan of the installed CLI

```text
subject .test-phase-lab ({run-worktree}/.test-phase-lab)
  endpoint=tmux:%0 session=11111111-1111-4111-8111-111111111111 lock_pid=79843 alive=1 instance=match owner=live
  captain=tmux:%0 moved_at=1795303641
  pane_static=0s dialog=question usage_limit_autowait=0 composer=pending turn_running=1 cpu_busy=unknown human_step=sign-in
  activity_age=unknowns loop=none/0 restart_requested=0 ctx=unknown [footer=unknown derived=unknown owner=none disagreement=-]
  owed=0 oldest=0s afk=0 daemon=unknown heartbeat_age=1s

exit=0
```

## Default grace period

```text

exit=0
```

## Weekend handoff persisted by the product

```text
1795303787	.test-phase-lab	sign-in	1795303654	morning-handoff
```

## One redacted local page after daytime fallback

```text
Firstmate watchdog: a human-only sign-in step has waited 2 minutes on .test-phase-lab, and only a person can complete it. Nothing was typed into it. The record is {run-worktree}/.test-phase-lab/state/watchdog/human-steps.tsv.
```

## Picker remains a human step after paging

```text
# Firstmate watchdog - Eduardos-MacBook-Pro-2
updated 2026-11-21T23:29:58Z, scan every 120s, mode act, restart off
STALE IF NOT UPDATED BY 2026-11-21T23:40:58Z (watchdog may be down)
models: none; spent 24h $0 of $1.00

## Homes
- .test-phase-lab: HUMAN-STEP, owed 0, ctx unknown; captain pid 79843 live on tmux:%0, moved 2026-11-21T23:27:21Z

## Actions since last read (2026-11-21T22:29:58Z)
- 23:29 .test-phase-lab handoff human-step done
- 23:29 .test-phase-lab page human-step done

## Open gaps
- .test-phase-lab: human-only sign-in step on .test-phase-lab for 2m; escalated, nothing is typed into it
- .test-phase-lab: no activity source; frozen, dead-holder, and low-context restarts are unavailable
- no model configured; judged symptoms are reported only
```

## Synthetic terminal input scans

These are the real `fm-watchdog.sh scan` worker observations.

```text
multiline-draft: worker auth endpoint=tmux:%1 dialog=none human_step=none
cropped-long-draft: worker auth endpoint=tmux:%1 dialog=none human_step=none
status-and-conversation: worker auth endpoint=tmux:%1 dialog=none human_step=none
numbered-draft: worker auth endpoint=tmux:%1 dialog=none human_step=none
expired-login: worker auth endpoint=tmux:%1 dialog=none human_step=sign-in
expired-oauth: worker auth endpoint=tmux:%1 dialog=none human_step=sign-in
otp: worker auth endpoint=tmux:%1 dialog=none human_step=otp
verification-code: worker auth endpoint=tmux:%1 dialog=none human_step=verification-code
captcha: worker auth endpoint=tmux:%1 dialog=none human_step=captcha
approval: worker auth endpoint=tmux:%1 dialog=none human_step=approval
```

## Replacing a tool approval clears its permission blocker

```text
1795303787	wd1795303787a91165	{run-worktree}/.test-phase-lab	.test-phase-lab	human-step	handoff	pending	sign-in step since 2026-11-21T23:27:34Z
1795303787	wd1795303787a91165	{run-worktree}/.test-phase-lab	.test-phase-lab	human-step	handoff	done	recorded for the morning handoff; not paged
1795303793	wd1795303793547f73	{run-worktree}/.test-phase-lab	.test-phase-lab	human-step	page	pending	sign-in step since 2026-11-21T23:27:34Z
1795303794	wd1795303793547f73	{run-worktree}/.test-phase-lab	.test-phase-lab	human-step	page	done	owner paged
1795303806	wd179530380654838a	{run-worktree}/.test-phase-lab	worker:auth	permission-prompt	report	done	blocked [key=permission-prompt-hardstop]: worker auth shows a sign-in prompt; nothing was answered, and the watchdog never answers credential, sign-in, spend, destructive, or reserved prompts
1795303813	wd1795303813a1d154	{run-worktree}/.test-phase-lab	worker:auth	permission-prompt	report	done	resolved [key=permission-prompt-hardstop]
1795303813	wd1795303813367ce9	{run-worktree}/.test-phase-lab	worker:auth	human-step	page	pending	sign-in step since 2026-11-21T23:30:13Z
1795303813	wd1795303813367ce9	{run-worktree}/.test-phase-lab	worker:auth	human-step	page	done	owner paged
```

## Other workers remain observable

```text
$ bash bin/fm-watchdog.sh scan
subject .test-phase-lab ({run-worktree}/.test-phase-lab)
  endpoint=tmux:%0 session=11111111-1111-4111-8111-111111111111 lock_pid=73408 alive=1 instance=match owner=live
  captain=tmux:%0 moved_at=1795303641
  pane_static=36s dialog=none usage_limit_autowait=0 composer=unknown turn_running=0 cpu_busy=0 human_step=none
  activity_age=unknowns loop=none/0 restart_requested=0 ctx=unknown [footer=unknown derived=unknown owner=none disagreement=-]
  owed=0 oldest=0s afk=0 daemon=unknown heartbeat_age=38s
  worker auth endpoint=tmux:%1 dialog=question human_step=sign-in
  worker other endpoint=tmux:%2 dialog=none human_step=none

exit=0
```

## A failed closure stays visible for retry

```text
# Firstmate watchdog - Eduardos-MacBook-Pro-2
updated 2026-11-21T23:33:39Z, scan every 120s, mode act, restart off
STALE IF NOT UPDATED BY 2026-11-21T23:44:39Z (watchdog may be down)
models: none; spent 24h $0 of $1.00

## Homes
- .test-phase-lab: NO-ACTIVITY-SOURCE, owed 0, ctx unknown; captain pid 73408 live on tmux:%0, moved 2026-11-21T23:27:21Z

## Actions since last read (2026-11-21T22:33:39Z)
- 23:29 .test-phase-lab handoff human-step done
- 23:29 .test-phase-lab page human-step done
- 23:30 worker:auth report permission-prompt done
- 23:30 worker:auth report permission-prompt done
- 23:30 worker:auth page human-step done
- 23:33 worker:auth handoff human-step done

## Open gaps
- .test-phase-lab: human-only otp step for worker:auth: the morning-handoff record could not be cleared; retried on the next pass
- .test-phase-lab: no activity source; frozen, dead-holder, and low-context restarts are unavailable
- no model configured; judged symptoms are reported only
```

## A recovered writer closes the handoff

```text
1795303787	.test-phase-lab	sign-in	1795303654	morning-handoff
1795303794	.test-phase-lab	sign-in	1795303654	page
1795303803	.test-phase-lab	sign-in	1795303654	cleared
1795303813	worker:auth	sign-in	1795303813	page
1795304000	worker:auth	otp	1795303998	morning-handoff
1795304028	worker:auth	otp	1795303998	cleared
```

## A failed page plus failed handoff append reports the missing record

```text
# Firstmate watchdog - Eduardos-MacBook-Pro-2
updated 2026-11-21T23:34:03Z, scan every 120s, mode act, restart off
STALE IF NOT UPDATED BY 2026-11-21T23:45:03Z (watchdog may be down)
models: none; spent 24h $0 of $1.00

## Homes
- .test-phase-lab: NO-ACTIVITY-SOURCE, owed 0, ctx unknown; captain pid 73408 live on tmux:%0, moved 2026-11-21T23:27:21Z

## Actions since last read (2026-11-21T22:34:03Z)
- 23:29 .test-phase-lab handoff human-step done
- 23:29 .test-phase-lab page human-step done
- 23:30 worker:auth report permission-prompt done
- 23:30 worker:auth report permission-prompt done
- 23:30 worker:auth page human-step done
- 23:33 worker:auth handoff human-step done
- 23:34 worker:auth page human-step failed
- 23:34 worker:auth handoff human-step failed

## Open gaps
- .test-phase-lab: human-only verification-code step on .test-phase-lab worker auth not paged (exit 2); the morning-handoff record could not be written, retried after nudge-secs
- .test-phase-lab: no activity source; frozen, dead-holder, and low-context restarts are unavailable
- no model configured; judged symptoms are reported only
```

## Recovered channel delivers the pending page

```text
1795303787	wd1795303787a91165	{run-worktree}/.test-phase-lab	.test-phase-lab	human-step	handoff	pending	sign-in step since 2026-11-21T23:27:34Z
1795303787	wd1795303787a91165	{run-worktree}/.test-phase-lab	.test-phase-lab	human-step	handoff	done	recorded for the morning handoff; not paged
1795303793	wd1795303793547f73	{run-worktree}/.test-phase-lab	.test-phase-lab	human-step	page	pending	sign-in step since 2026-11-21T23:27:34Z
1795303794	wd1795303793547f73	{run-worktree}/.test-phase-lab	.test-phase-lab	human-step	page	done	owner paged
1795303806	wd179530380654838a	{run-worktree}/.test-phase-lab	worker:auth	permission-prompt	report	done	blocked [key=permission-prompt-hardstop]: worker auth shows a sign-in prompt; nothing was answered, and the watchdog never answers credential, sign-in, spend, destructive, or reserved prompts
1795303813	wd1795303813a1d154	{run-worktree}/.test-phase-lab	worker:auth	permission-prompt	report	done	resolved [key=permission-prompt-hardstop]
1795303813	wd1795303813367ce9	{run-worktree}/.test-phase-lab	worker:auth	human-step	page	pending	sign-in step since 2026-11-21T23:30:13Z
1795303813	wd1795303813367ce9	{run-worktree}/.test-phase-lab	worker:auth	human-step	page	done	owner paged
1795303999	wd1795303999488226	{run-worktree}/.test-phase-lab	worker:auth	human-step	handoff	pending	otp step since 2026-11-21T23:33:18Z
1795304000	wd1795303999488226	{run-worktree}/.test-phase-lab	worker:auth	human-step	handoff	done	recorded for the morning handoff; not paged
1795304039	wd1795304039fcb7e0	{run-worktree}/.test-phase-lab	worker:auth	human-step	page	pending	verification-code step since 2026-11-21T23:33:59Z
1795304040	wd1795304039fcb7e0	{run-worktree}/.test-phase-lab	worker:auth	human-step	page	failed	no alert channel delivered the page (exit 2); retried after nudge-secs
1795304040	wd1795304039fcb7e0	{run-worktree}/.test-phase-lab	worker:auth	human-step	handoff	failed	the human-steps record could not be written
1795304050	wd1795304049645e15	{run-worktree}/.test-phase-lab	worker:auth	human-step	page	pending	verification-code step since 2026-11-21T23:33:59Z
1795304050	wd1795304049645e15	{run-worktree}/.test-phase-lab	worker:auth	human-step	page	failed	no alert channel delivered the page (exit 2); retried after nudge-secs
1795304058	wd17953040584adc02	{run-worktree}/.test-phase-lab	worker:auth	human-step	page	pending	verification-code step since 2026-11-21T23:33:59Z
1795304059	wd17953040584adc02	{run-worktree}/.test-phase-lab	worker:auth	human-step	page	done	owner paged
```

## Removed worker closes its handoff

```text
1795303787	.test-phase-lab	sign-in	1795303654	morning-handoff
1795303794	.test-phase-lab	sign-in	1795303654	page
1795303803	.test-phase-lab	sign-in	1795303654	cleared
1795303813	worker:auth	sign-in	1795303813	page
1795304000	worker:auth	otp	1795303998	morning-handoff
1795304028	worker:auth	otp	1795303998	cleared
1795304051	worker:auth	verification-code	1795304039	morning-handoff
1795304059	worker:auth	verification-code	1795304039	page
1795304066	worker:orphan	captcha	1795304066	morning-handoff
1795304075	worker:orphan	captcha	1795304066	cleared
```

## Reserved human-step key is held by the council command

```text
$ bash bin/fm-watchdog.sh council --task auth --key human-step-auth
council=held answer=none record=none prior=0 seats=none

exit=0
```

## Return brief publishes the handoff without holding the gate

```text
$ bash bin/fm-afk-return.sh begin
=== Return brief (away 2026-11-21T23:37:17Z -> 2026-11-21T23:37:27Z, 10s) ===
Supervisor health:
  - GAP: the away daemon was not running at return (the away flag stood with no live daemon)
Your instructions:
  your words at entry:
    Continue independent local work while authentication waits.
  the away session took no action under them.
Waiting on you:
  human-only steps recorded by the watchdog (nothing was typed into them):
    - worker:auth: verification-code step waiting since 2026-11-21T23:33:59Z; only a person can complete it
  - auth [key=human-step-auth] human-only step, other work continues: human-only step: sign in to the test service
Tried and failed, or could not be fixed:
  (nothing)
Landed, cleanup due:
  (nothing)
Handled while away:
  0 outcome(s) handled by the away session (0 routine, 0 escalated above)
  (no routine outcomes recorded in the store for this window)
Cost: 0 supervision outcome(s) recorded (0 routine, 0 captain); 2 task(s) live at return.
catch-up health: GAP: the away daemon was not running at return (the away flag stood with no live daemon)
catch-up wake: OPEN DECISIONS (still open, folded from the durable status logs - not just the latest line):
catch-up wake: auth [key=human-step-auth] blocked: human-only step: sign in to the test service
catch-up wake: OPEN DECISIONS: close one by answering it: bin/fm-send.sh <task> --resolve-key <key> '<answer>'
catch-up wake: OPEN DECISIONS: <key> is the [key=...] printed before the verb; a token inside a note is prose, not a key.
fm-afk-return: catch-up clear; ordinary captain work may proceed
fm-afk-launch: away-posture record archived at {run-worktree}/.test-phase-lab/state/afk-contracts/1795304237.afk-contract
fm-afk-launch: away mode stopped; no daemon terminal was running, .afk cleared, and the posture record archived
WARNING: watcher still down (same stale episode; last beat: 11s ago, grace 300s; down 97s) - full banner already printed this episode.

exit=0
```

## An ordinary blocker still holds the gate

```text
$ bash bin/fm-afk-return.sh check
=== Return brief ===
Supervisor health:
  - supervision ran through the away window with no detected gap (watcher beat 14s old at return)
Your instructions:
  (no away-posture record for this window; legacy away flag only)
Waiting on you:
  human-only steps recorded by the watchdog (nothing was typed into them):
    - worker:auth: verification-code step waiting since 2026-11-21T23:33:59Z; only a person can complete it
  - auth [key=human-step-auth] human-only step, other work continues: human-only step: sign in to the test service
Tried and failed, or could not be fixed:
  - other [key=ordinary-dependency] still blocked, firstmate remediates before ordinary work: firstmate must repair the local dependency
Landed, cleanup due:
  (nothing)
Handled while away:
  0 outcome(s) handled by the away session (0 routine, 0 escalated above)
  (no routine outcomes recorded in the store for this window)
Cost: 0 supervision outcome(s) recorded (0 routine, 0 captain); 2 task(s) live at return.
WARNING: watcher still down (same stale episode; last beat: 18s ago, grace 300s; down 105s) - full banner already printed this episode.
fm-afk-return: catch-up must finish before the captain request
catch-up health: supervision ran through the away window with no detected gap (watcher beat 14s old at return)
catch-up wake: OPEN DECISIONS (still open, folded from the durable status logs - not just the latest line):
catch-up wake: auth [key=human-step-auth] blocked: human-only step: sign in to the test service
catch-up wake: OPEN DECISIONS: close one by answering it: bin/fm-send.sh <task> --resolve-key <key> '<answer>'
catch-up wake: OPEN DECISIONS: <key> is the [key=...] printed before the verb; a token inside a note is prose, not a key.
firstmate-actionable blocker: other [key=ordinary-dependency] firstmate must repair the local dependency
fm-afk-return: handle each blocker now, or close it with resolved [key=...] and append a durable reclassification reason, then run bin/fm-afk-return.sh check

exit=3
```

## Resolving ordinary blockers clears the gate

```text
$ bash bin/fm-afk-return.sh check
=== Return brief ===
Supervisor health:
  - supervision ran through the away window with no detected gap (watcher beat 14s old at return)
Your instructions:
  (no away-posture record for this window; legacy away flag only)
Waiting on you:
  human-only steps recorded by the watchdog (nothing was typed into them):
    - worker:auth: verification-code step waiting since 2026-11-21T23:33:59Z; only a person can complete it
Tried and failed, or could not be fixed:
  (nothing)
Landed, cleanup due:
  (nothing)
Handled while away:
  0 outcome(s) handled by the away session (0 routine, 0 escalated above)
  (no routine outcomes recorded in the store for this window)
Cost: 0 supervision outcome(s) recorded (0 routine, 0 captain); 2 task(s) live at return.
catch-up health: supervision ran through the away window with no detected gap (watcher beat 14s old at return)
catch-up wake: OPEN DECISIONS (still open, folded from the durable status logs - not just the latest line):
catch-up wake: auth [key=human-step-auth] blocked: human-only step: sign in to the test service
catch-up wake: OPEN DECISIONS: close one by answering it: bin/fm-send.sh <task> --resolve-key <key> '<answer>'
catch-up wake: OPEN DECISIONS: <key> is the [key=...] printed before the verb; a token inside a note is prose, not a key.
fm-afk-return: catch-up clear; ordinary captain work may proceed
WARNING: watcher still down (same stale episode; last beat: 26s ago, grace 300s; down 112s) - full banner already printed this episode.

exit=0
```

## Emitted worker instructions

The real `fm-brief.sh` command wrote the public brief artifacts. Full emitted files: `generated-ship-brief.md` and `generated-scout-brief.md`.

### ship

```text
   `blocked [key=human-step-<slug>] [at=<epoch>]: human-only step: {what a person must do, and where}`.
   That key keeps the step visible to firstmate and the captain but never holds the away return; append `resolved [key=human-step-<slug>] [at=<epoch>]: {how}` only once a person has completed the step or it is no longer needed, never just to clear it.
```
### scout

```text
   `blocked [key=human-step-<slug>] [at=<epoch>]: human-only step: {what a person must do, and where}`.
   That key keeps the step visible to firstmate and the captain but never holds the away return; append `resolved [key=human-step-<slug>] [at=<epoch>]: {how}` only once a person has completed the step or it is no longer needed, never just to clear it.
```

## Targeted test evidence

All exited 0: the selected watchdog tests, and `tests/fm-permission-prompt.test.sh`, `tests/fm-afk-return.test.sh`, `tests/fm-brief.test.sh`, and `tests/fm-classify-decision-key.test.sh`. Logs are retained beside this report. The complete repository suite and non-Test pipeline phases were not invoked.

Probe-driver corrections affected only evidence scripts: normalize the optional status timestamp, ignore terminal trailing-space trimming, read the scaffolded public brief rather than its receipt, and scope return assertions to the current brief while retaining stderr diagnostics and historical wake evidence. Affected stages were re-driven. The final return driver exited 0.

Cleanup: the private tmux server stopped, its lab socket directory was removed by the lab helper, all recorded lab processes were absent, and the disposable worktree-local lab was removed.
