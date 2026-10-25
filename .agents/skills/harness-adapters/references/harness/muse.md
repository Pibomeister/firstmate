# Muse Code

Verified 2026-10-24 on Muse Code 1.4.13-R6996.1, build sha 39490bd065.
The router owns Muse's task-kind boundary.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute `muse` from `PATH`, refused if absent; launcher `~/.local/bin/muse` execs versioned `muse-bin-<version>`, so live process name changes on update. |
| Launch | Positional instructions, like Grok or Pi. |
| Models | `--model <model>`; only provider `meta`; the live catalog resolves `muse-wonder-1.0` and `muse-spark-1.3` through `muse model-profile show`. |
| Busy | Durable session event log folded by `../../../bin/fm-busy-lib.sh`; no hook or plugin writer, arming, or seeded busy record. |
| Exit | `/exit`, one Enter; prints `To continue this session, run muse resume <session-uuid>`. |
| Interrupt | Single Escape records `terminal: cancelled` and restores bright prompt text, so control follows with `Ctrl+U`; the legacy typed key path uses the same clear table. |
| Skill | `/<skill>`, the Claude or Grok form. |
| Resume | `muse resume --last` or `muse resume <session-uuid>`; bare `muse resume` opens a picker. |
| Autonomy | `--yolo` disables approval and sandbox and trusts the workspace. |
| Trust | Dialog `Do you trust this workspace?`, choice `1 Trust and continue` preselected for Enter; `--yolo` suppresses it, which fresh task paths require. |
| Marker | None; identity comes from anchored `muse-bin-*` ancestry, which `../../../bin/fm-harness.sh` keeps a retained foreign marker from overriding, while `MUSE_CURRENT_SESSION_LOG` is a path rather than identity and its export to tools is unverified. |
| Composer | Bordered `❯` (U+276F, changed from `⟩` in 0.1.0), truecolor `38;2;90;160;255`, luminance about 149.9 and narrowly above ghost threshold 128; typed text is `38;2;204;211;219`, about 209.8, with no observed placeholder or ghost. |
| Effort | `--reasoning-effort`, default `high`, accepts `none\|minimal\|low\|medium\|high\|xhigh\|max\|ultra`; shared values expose low through xhigh, explicit captain `max` still maps to `ultra` because `ultra` remains the top level above native `max`, and `none` or `minimal` remain unreachable. |

## Credential preflight

Muse reads winning `META_API_KEY` or `${XDG_CONFIG_HOME:-$HOME/.config}/muse/auth.json` written by OIDC device-code `muse login` or `muse auth set --api-key-stdin`.
The spawn accepts the environment key only if the backend worker already has it: caller-only variables do not cross a long-lived daemon, and secrets never enter argv.
Stored credentials are the supported fleet path.
It resolves non-secret `XDG_CONFIG_HOME` and `XDG_DATA_HOME` absolutely before preflight and forwarding, keeping auth and logs aligned.

With neither worker-reachable credential, spawn refuses.
Unauthenticated Muse otherwise waits forever at `Sign in at this page: https://auth.meta.com/oauth/device/?code=XXXX-XXXX` and `Waiting for approval…`, which resembles a wedge.
Before escalating the refusal as a needed credential, check the [worker launch environment contract](../../../../../docs/configuration.md#worker-launch-environment-configlaunch-env-allowlist) for a withheld environment grant.

## Foreign personal context

Muse sends operator rules from `~/.claude` to Meta-hosted inference on every run.
Its notice names Claude personal rules and `/settings` but appears only once through `tui.foreign_context_notice_shown`, so later silence proves nothing; isolated `XDG_CONFIG_HOME` does not prevent loading.

Interactive Muse rejects exec-only `--no-foreign-personal-context`.
The pane control is `MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on`, set on every spawn and verified to remove foreign `rules_file` while retaining project `AGENTS.md`.

## Session event log

Logs live at `${XDG_DATA_HOME:-$HOME/.local/share}/muse/sessions/YYYY/MM/DD/<session-uuid>/session.jsonl`.
Binding scans early flat records for workspace metadata; [the verification record](../../../../../docs/verification/muse.md#turn-lifecycle) owns the observed log shape.
The spawn writes `state/<id>.muse-session` with root, worktree, binding incarnation, and pre-existing matching main logs, then unique resolution pins `state/<id>.muse-session-current`.
It folds that path while the set of workspace-matching main logs across every date directory is unchanged and resolves again if that set changes, the path disappears, or a newer binding wins.
The namespace signature tracks metadata readiness rather than run or tool content, so a competing log becomes visible when its workspace metadata becomes readable, including after a date rollover.

Turns are bracketed by `{"payload":{"kind":"run","run_id":"<uuid>","event":{"kind":"started"` and matching `"event":{"kind":"terminal"`, observed as `completed` or `cancelled`.
Interrupt therefore has a real terminal, unlike Claude Stop.
Never use `--no-session-log`, which removes Muse's only busy source.

The fold must reject nested `"record":{"kind":"terminal"}` cleanup effects and depth-bound away native sub-agent logs under `subagent/<child-session-id>/session.jsonl`.
The recorded resolved `XDG_DATA_HOME` is also forwarded to the worker, preserving daemon alignment.
An open run is trusted busy and settled log trusted idle; missing binding or match, unreadable log, or run-free log is unknown.
`../../../docs/verification/muse.md` owns credentialed idle evidence and refresh.

## Native sub-agents and worktrees

Native children use per-child worktrees only with opt-in `--subagent-worktree-isolation`; capability says default-on while omission stays shared, and verified labs produced no nested copy.
`../../../bin/fm-teardown.sh` excludes no Muse path.
It excludes `.claude/settings.local.json` because Firstmate writes it, but Muse scratch is worker output and must refuse cleanup when uncommitted.
Inspect, never force past, that refusal.

## Maturity and primary boundary

Muse 1.4.13 still auto-updates through its hourly channel poll, which can replace the binary and process name.
The captain accepted this, so Firstmate does not set `MUSE_NO_AUTO_UPDATE=1`; a fleet may set it without adapter change.
Plugins report unavailable unless `MUSE_EXPERIMENTAL_PLUGINS=on`, so busy state uses logs.
The compatibility dialect explicitly lacks `asyncRewake` as a hook, and Muse exposes no Stop, turn-end, or PreToolUse hook in the default build.
Primary supervision therefore uses Muse's tracked background-task completion as the model wake, verified live on 1.4.13 in [`docs/verification/muse.md`](../../../../../docs/verification/muse.md).
[`docs/supervision-protocols/muse.md`](../../../../../docs/supervision-protocols/muse.md) owns that one wait shape.
Session start is nudge-tier: Muse loads project `AGENTS.md` natively and has no tracked SessionStart hook, so section 3's instruction itself is the transport.
No turn-end hook can block a blind turn end on Muse; the tracked background cycle is the mechanism and [`docs/turnend-guard.md`](../../../../../docs/turnend-guard.md) owns the tradeoff.
Secondmate on Muse remains refused in `bin/fm-spawn.sh` until the primary protocol is proven in a secondmate home.
