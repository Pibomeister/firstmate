# Verification: the muse (Muse Code) crewmate adapter

Active empirical evidence for firstmate's muse adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts; this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `Muse Code 1.4.13 (1.4.13-R6996.1)`, build sha `39490bd065` |
| Verified | 2026-10-24, refreshing the 2026-08-05 and 2026-08-06 evidence for 0.1.0 |
| Artifact | Installed `muse-bin-1.4.13-R6996.1`, sha256 `9fd40ae9c6dfb847e3ef58b61405c004d0ebbf19ceb0297be966f750b3b84aa0` |
| Platform | macOS arm64 (Darwin 25.5.0) |

The installed binary was reported by the live binary itself before any refreshed run:

```
$ muse --version
Muse Code 1.4.13 (1.4.13-R6996.1)

$ shasum -a 256 ~/.local/bin/muse-bin-1.4.13-R6996.1
9fd40ae9c6dfb847e3ef58b61405c004d0ebbf19ceb0297be966f750b3b84aa0  muse-bin-1.4.13-R6996.1
```

The session metadata in a live 1.4.13 log carries the same build identity:

```
"build": {"sha": "39490bd065", "semver": "1.4.13"}
```

The original 0.1.0 runs used an isolated `XDG_CONFIG_HOME` and `XDG_DATA_HOME` in a scratch directory and a throwaway git workspace, driven through tmux the way firstmate drives a crewmate pane.
The 2026-10-24 refresh kept that isolation for the echo-provider signal guard and used the installed launcher and stored credential for the real-model smoke in throwaway git workspaces.

## What the model provider limits

Live TUI and session behavior below was observed against the built-in `--provider echo` startup provider, except for the provider-authentication prompt.
The credential paths and unauthenticated wait were probed separately against the default `meta` provider.
Turn-boundary structure, the trust dialog, interrupt, exit, composer rendering, credential behavior, and the event-log schema are real and verified.
Busy-state behavior under a genuine multi-step, real-model tool loop was verified on 2026-08-06 and refreshed on 2026-10-24 against the default `meta` provider with a live model, and is recorded under [the credentialed multi-step smoke](#the-credentialed-multi-step-smoke).

## Verified facts

### Process identity

The published launcher `exec`s a version-suffixed binary, so the live process name changes on every auto-update:

```
$ grep -nE 'muse-bin|exec ' launcher.sh
969:  candidate="$work/muse-bin"
977:  target="$dir/muse-bin-$version"
1035:  printf '%s/muse-bin-%s\n' "$dir" "$version"
1135:  exec "$binary" "$@"
```

`ps -o comm= -p <pid>` returns the full executable path, whose basename is `muse-bin-<version>`.
That is why both `bin/fm-harness.sh` and `bin/backends/tmux.sh` match the anchored prefix `muse-bin-*` rather than an exact name, and why neither can rely on an install-path component: `~/.local/bin/muse-bin-<version>` contains no `muse` path component.
The Muse launch clears `CLAUDECODE`, `PI_CODING_AGENT`, `GROK_AGENT`, `FM_PI_HARNESS`, `CURSOR_AGENT`, and `CURSOR_INVOKED_AS` before the worker starts, which is the verified launch behavior rather than what detection depends on.
[Harness detection precedence](runtime-backends.md#harness-detection-precedence) owns why a retained foreign marker cannot override the versioned ancestry.

[`runtime-backends.md`](runtime-backends.md#agent-liveness-name-sources) owns the resulting tmux liveness verdict and its relationship to the portable decoy regression.

### Models and effort

The live catalog on 1.4.13 resolves both current models:

```
$ muse model-profile show muse-wonder-1.0
model:  muse-wonder-1.0
default_reasoning_effort   high

$ muse model-profile show muse-spark-1.3
model:  muse-spark-1.3
default_reasoning_effort   high
```

`muse --help` on 1.4.13 reports `--reasoning-effort` accepting `none|minimal|low|medium|high|xhigh|max|ultra` with default `high`.
Native `max` is new since 0.1.0, which accepted no `max`.
Firstmate keeps mapping its explicit `max` to `ultra`, because `ultra` remains the top level above native `max` in that list and firstmate `max` names the captain's explicit top class.
Mapping to native `max` would silently lower that class.

### Turn lifecycle

A two-turn session produced exactly two run brackets, the second closed by an Escape interrupt:

```
9  {"kind":"run","run_id":"d352a097-...","event":{"kind":"started","prompt":"hello from firstmate"}}
45 {"kind":"run","run_id":"d352a097-...","event":{"kind":"terminal","terminal":"completed","turn_duration_ms":8152}}
49 {"kind":"run","run_id":"b50dac92-...","event":{"kind":"started","prompt":"second turn to interrupt"}}
78 {"kind":"run","run_id":"b50dac92-...","event":{"kind":"terminal","terminal":"cancelled","reason":"cancelled during model step"}}
```

In 0.1.0 the log's first record carried the workspace binding key.
In 1.4.13 the first line is a `retained_frame` permission transaction and the metadata record follows it:

```
{"retained_frame":"session_permission_transaction","children":[{"record_json":"{\"payload_type\":\"runtime.session.permission_format_declared\",...}"}]}
{"payload_type":"runtime.session.metadata","payload":{"kind":"metadata","record":{"workspace_root":".../ws1","provider_id":"echo","build":{"sha":"39490bd065","semver":"1.4.13"}}}}
```

That prefix broke workspace binding on 1.4.13 because the classifier read only the first line.
`bin/fm-busy-lib.sh` now scans the early lines and any `retained_frame` children for the metadata record, and `tests/fm-muse-harness.test.sh` pins that shape.
The run lifecycle records themselves remain flat `runtime.session` records, so the run fold is unchanged.

The fold transitions live, sampled during a 25-second in-flight turn:

```
T+ 5s fold=busy
T+10s fold=busy
T+15s fold=busy
T+20s fold=busy
T+25s fold=busy
T+30s fold=settled
```

Two decoys were observed in real logs and are pinned by regressions in `tests/fm-muse-harness.test.sh`:
a nested `"record":{"kind":"terminal"}` cleanup-effect payload that is not a run terminal, and independent sub-agent run lifecycles under `subagent/<child-session-id>/session.jsonl`.
The same regression suite verifies that unique resolution is cached, a changed current-day main-session namespace restores ambiguity to unknown, a replacement spawn binding selects its fresh main log, missing cached logs fail closed, and cached sub-agent paths are rejected.

### Autonomy, trust, and sandbox

A fresh untrusted workspace shows the trust dialog with option 1 preselected:

```
Do you trust this workspace?
> 1  Trust and continue
  2  Quit
Use Up/Down or 1/2, then Enter. Esc quits.
```

`--yolo` suppresses it entirely and the status bar reports `echo · <workspace> · YOLO`.
This matters because approval and the sandbox are ON by default and `--sandbox-network` defaults to `proxy-only`, which the binary reports as requiring managed shell sandboxing - a crewmate needs ordinary git and network access.

### Credentials

`muse auth set --provider` accepts only `meta`.
An unauthenticated launch does not exit; it waits indefinitely:

```
  Sign in at this page:
    https://auth.meta.com/oauth/device/?code=DGXZ-NRPR
  Waiting for approval…
  Esc cancel
```

That is why `bin/fm-spawn.sh` preflights worker-reachable `META_API_KEY` or `<config>/muse/auth.json` and refuses before creating an endpoint.
A caller-only `META_API_KEY` is refused because a long-lived backend daemon does not inherit it, while the non-secret `XDG_CONFIG_HOME` and `XDG_DATA_HOME` roots are resolved to absolute paths before preflight and forwarding so the stored credential and session-log binding reach the same worker environment.

### Foreign personal context

The interactive TUI rejects the `exec`-only flag:

```
$ muse --no-foreign-personal-context --provider echo hi
invalid TUI options: error: unexpected argument '--no-foreign-personal-context' found
  tip: a similar argument exists: '--no-session-log'
```

`MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL` is the control that works in TUI mode.
Comparing the `context_block_diagnostic` block ids emitted by otherwise identical runs, with the operator's real `~/.claude` rules present and no project `AGENTS.md`:

```
base     blocks=rules_file,workspace_identity,security_mode,skills_catalog,session_identity,subagent_delegation
killon   blocks=workspace_identity,security_mode,skills_catalog,session_identity,subagent_delegation
kill1    blocks=workspace_identity,security_mode,skills_catalog,session_identity,subagent_delegation
```

Repeating the comparison with a project `AGENTS.md` present confirms the kill switch drops only the FOREIGN rules:

```
a4base   blocks=rules_file,workspace_identity,security_mode,skills_catalog,session_identity,subagent_delegation
a4kill   blocks=rules_file,workspace_identity,security_mode,skills_catalog,session_identity,subagent_delegation
```

The `tui.foreign_context_notice_shown` flag in `settings.json` suppresses only the notice, never the loading, so a quiet later launch is not evidence of a clean context.

### Composer rendering

Captured with `tmux capture-pane -p -e` on 1.4.13:

```
^[[38;2;90;160;255m^[[48;2;38;56;84m❯ ^[[38;2;204;211;219mhello from firstmate^[[39m
^[[0m^[[38;2;90;160;255m❯ ^[[39m
```

The prompt glyph changed from `⟩` (U+27E9) in 0.1.0 to `❯` (U+276F) in 1.4.13, at the same truecolor `38;2;90;160;255` and luminance ~149.9 against the 128 default ghost threshold; typed text remains `38;2;204;211;219` at ~209.8.
The shared composer classifier already treats `❯` as an agent prompt glyph, so its empty verdict is unchanged.
The live signal guard now accepts either glyph while still rejecting dark or malformed foregrounds.
After a single Escape the interrupted prompt is restored into the composer at the same bright ~209.8, and `C-u` clears it.

## The credentialed multi-step smoke

This smoke decides whether a settled log may classify `idle`.
An open run was always positive proof of a turn in flight, but a settled log only proves no run is open at that instant, so the classifier held idle behind an opt-in in case a real turn spanned several runs.
The smoke answered that: one run brackets a whole multi-step turn, and an Escape interrupt closes that run with `terminal=cancelled` rather than leaving the turn to continue in another run.
The credentialed result gives a settled Muse log the same idle trust as the Claude and Pi push sources, so the opt-in was removed and `bin/fm-busy-lib.sh` classifies a settled log `idle` outright.
Muse auto-updates its vendor binary underneath the fleet, firstmate normalizes the versioned process identity to the `muse` harness before busy classification, and the session log's own metadata carries semver plus a build SHA that cannot be matched to that normalized identity.
A verified-build allowlist against this coarse identity would be false precision because it could not distinguish the running build, as well as a maintenance treadmill against the auto-updating binary.

It was first verified on 2026-08-06 on 0.1.0 with model `muse-spark-1.2-contributor`.
It was refreshed on 2026-10-24 on 1.4.13 with model `muse-wonder-1.0`, authenticated through the stored `~/.config/muse/auth.json` so the key never entered `argv`.

### One turn stays inside one run

A single multi-step tool loop - create `smoke.txt`, read it, append a line, read it again, and list the workspace - ran as one submitted turn in session `01a16f4b-7231-7c93-9acb-5bfc0587d302`.
Filtering the log to `runtime.session` run lifecycle records gives exactly one started and one terminal record with the same run id:

```
started count 1 terminal count 1
run lifecycle [('01a16f4b', 'started', None), ('01a16f4b', 'terminal', 'completed')]
$ grep -c '"payload_type":"tool_batch.effect.started"' session.jsonl
5
```

Scope the count to run lifecycle records as above.
A bare search for `"kind":"run"` also matches context and tool records that reuse that inner shape.

### Busy sampling and interrupt

Session `01a16f4b-d32e-79e0-8f9a-3a0f754fe59c` sampled the fold while a multi-step turn was in flight, then interrupted it with Escape mid tool loop.
Repeated samples of `fm_busy_muse_run_state` on the bound log returned `busy`; the fold settled immediately after the interrupt.
Its run closed as cancelled rather than staying open:

```
run lifecycle [('01a16f4b', 'started', None, None), ('01a16f4b', 'terminal', 'cancelled', 'cancelled during model step')]
```

That is the same terminal shape the `echo`-provider interrupt produced, now confirmed against a live model mid tool loop.

`tests/fm-muse-harness.test.sh` pins the resulting classifier behavior: a log settled by either terminal reads `idle`, an open run reads `busy`, and only a resolution failure reads `unknown`.

## Refreshing this record

Run both live guards after any muse upgrade, because the version-suffixed process name, session protocol, and styled composer are vendor-controlled surfaces:

```
FM_HARNESS_LIVENESS_DRIFT=1 bin/fm-test-run.sh tests/fm-harness-liveness-drift-live-e2e.test.sh
FM_MUSE_SIGNALS_LIVE=1 bin/fm-test-run.sh tests/fm-muse-signals-live-e2e.test.sh
```

The Muse signals guard requires a real `muse` binary and tmux but uses `--provider echo`, so it does not require `META_API_KEY` and cannot re-check the real-model turn-to-run relationship on its own.
The guard follows SGR state through the final prompt glyph and rejects both bright-then-dark and malformed-RGB negative controls before accepting that glyph's effective luminance.

Both guards passed on 1.4.13 on 2026-10-24.
The liveness guard checked 8 installed harnesses and reported muse as `title='muse-bin-1.4.13'` with ancestry `comm muse`.
The signals guard reported busy in flight, one matched run bracket, and a bright prompt glyph classifying as an empty composer.

muse's launcher can replace the running binary underneath the fleet, so an upgrade that changes the session protocol also invalidates the credentialed evidence above.
Repeat that smoke after a protocol-affecting upgrade: run one real multi-step tool-loop turn with credentials in place, confirm the run-scoped `started`/`terminal` counts are still exactly one each, and confirm an Escape still yields `terminal` with `cancelled`.
A build that ever split one turn across several runs would make a settled log ambiguous, which is a classifier change rather than a note in this file.

The portable counterparts that run in ordinary CI are `tests/fm-muse-harness.test.sh`, `tests/fm-tmux-agent-liveness.test.sh`, `tests/fm-composer-lib.test.sh`, and `tests/fm-composer-ghost.test.sh`.
