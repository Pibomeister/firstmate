# Antigravity CLI

Antigravity's `agy` TUI, verified end to end on 2026-09-10 with agy 1.2.0 on Linux through the Herdr backend, and through the spawn path on 2026-10-29 with agy 1.4.10 on macOS through the tmux backend.
Verified as a CREWMATE and SCOUT adapter only; `../../../../../bin/fm-spawn.sh` refuses a secondmate launch on it because `../../../../../docs/supervision-protocols/` carries no agy wake protocol.
`../../../../../docs/verification/agy.md` owns how every fact below was established and what is still unproven.

## Operating facts

| Fact | Value |
|---|---|
| Backends | tmux and Herdr only, because the readiness gate is proven only where the pane capture shows the pinned busy row. When the backend comes only from `config/backend` or runtime detection and is neither, `../../../../../bin/fm-spawn.sh` runs that one agy task on Herdr if its tools pass, else tmux, and prints a notice naming both; the task record names the backend it really runs on. An explicit `--backend` or `FM_BACKEND`, or a relaunch, onto any other backend is refused before anything launches, and so is a spawn with neither Herdr nor tmux available. |
| Treehouse | Fresh spawns require the custody capabilities documented in `../../../../../bin/fm-spawn.sh`'s header; the check refuses before endpoint creation and names the missing capability. The general Treehouse version floor alone does not establish AGY compatibility. |
| Binary | Absolute `agy` from `PATH`, refused if absent; a Go-compiled single binary, so the live process name is exactly `agy` with `argv[0]=agy`. |
| Launch | `agy --prompt-interactive "<brief>" --model <id> --effort <level> --dangerously-skip-permissions`, with the resolved absolute binary; the brief auto-submits with no extra Enter. The spawn pre-registers the worktree in agy's trust store first, then waits for a busy turn (answering the folder-trust dialog if it renders anyway) before reporting success. |
| Busy state | No hook or plugin writer, so nothing is armed and no record is seeded; on Herdr the native `working` status classifies busy, and everywhere else the `agy-regex` rendered-tail fallback in `../../../../../bin/fm-busy-lib.sh` does. |
| Rendered tail | Busy status row carries `esc to cancel` on the left; the idle row shows `? for shortcuts` instead. The `Generating...` word beside the braille spinner is free-floating output and is not a signal. |
| Turn end | No turn-end hook or notification touch exists; completion arrives through the worker status protocol and, on Herdr, the native return to `idle`. |
| Exit | `/quit`, one Enter; the process exits. `../../../../../bin/fm-control.sh` types it only after the composer reads `empty` (see Composer). |
| Interrupt | Single `Escape`, which prints the Interrupted row and leaves an idle composer with no repollution, so no clear key follows. |
| Skill | No verified slash-skill form; use natural language. |
| Autonomy | `--dangerously-skip-permissions` auto-approves tool calls for the run. |
| Marker | None; a live TUI carries no `AGY_*` or `ANTIGRAVITY_*` variable. |
| Resume | `--continue` and `--conversation` exist but carry no verified pane-resume contract; use deterministic relaunch. |
| Model | `--model <id>` with the bare catalog id from `agy models` (for example `gemini-4-argon-high`); `bin/fm-spawn.sh` refuses a requested id a reachable listing omits. The listing is a remote fetch, so the probe runs stdin-detached under the shared hard bound and a failed or hung listing launches unvalidated with a notice. An empty catalog with exit 0 is how a signed-out agy answers, so it refuses with the sign-in step. |
| Effort | `--effort low\|medium\|high` always; `xhigh` and `max` pass only when the build's own `--effort` help line lists them (agy 1.4.10 does; it prints help on stderr), and otherwise stay in task metadata under the record-and-omit contract. |
| Composer | A `>` prompt row between two full-width rules, with `? for shortcuts` on the row below: the separated shape pi and polytoken share. The shared classifier reads it only under an identified agy owner (the tmux process probe or Herdr's native `agy`): text after `>` is `pending`, the idle footer proves `empty`, and a busy row or any other footer stays `unknown`. agy's native status is not trusted for `empty`. |

## Trust, and where the decision persists

Every task worktree is a path agy has never seen, so an unregistered launch stops on `Do you trust the contents of this project?` with the safe choice `Yes, I trust this folder` preselected, and an unanswered dialog sends the turn into agy's scratch directory instead of the worktree.
There is no launch flag that suppresses the dialog, but agy honours a `trustedWorkspaces` entry in the captain's own `~/.gemini/antigravity-cli/settings.json` written ahead of launch (verified live), so `../../../../../bin/fm-spawn.sh` pre-registers the worktree through `../../../../../bin/fm-agy-trust.sh` before launch, the claude shape: the helper refuses anything but a linked worktree of the spawning project, records both the logical pane path and its resolved form because agy compares the logical cwd, and preserves every other key in the store.
The post-launch readiness gate is the backstop: it answers a dialog that renders anyway with a single Enter, then requires a busy verdict (Herdr's native `working` status or the pinned `esc to cancel` row) before the spawn reports success, and on a path that was not pre-registered it never counts a busy verdict as ready until the dialog has been answered, because Herdr's native verdict can precede the dialog.
A pane whose brief cannot be confirmed to run in the worktree fails the spawn, records the failure in the task status, and closes only its own endpoint.
Once an AGY task record is published, a failed spawn keeps that record and its worktree, including launch-send, termination-during-readiness, and backlog-transition failures.
The brief rides the launch command, so a readiness timeout cannot prove it never ran.
Recover the recorded task with `../../../../../bin/fm-control.sh <id> relaunch --note ...` or clean it up with `../../../../../bin/fm-teardown.sh <id>`.
Its durable Treehouse lease survives endpoint close, so another allocation cannot reuse the slot while the task is kept.
For a pooled ship or scout relaunch whose recorded or replacement harness is AGY, the control plane checks Treehouse capabilities and slot ownership before stopping the old worker.
The launch owner rechecks capabilities, then takes the project allocation lock to verify ownership and preserve the lease.
These extra custody checks do not apply to relaunches between non-AGY harnesses.
Never steer into a pane still showing the dialog; a spawn that reported success has already cleared it.

## Credential precondition

A verified agy worker ran under a signed-in Google account with no key export and no dialog.
On macOS the sign-in lives in the login keychain, which macOS finds through `HOME`.
Under a `HOME` with no `Library/Keychains/login.keychain-db`, agy runs signed out and saving a sign-in makes macOS show its modal "A keychain cannot be found" dialog, so `../../../../../bin/fm-spawn.sh` refuses that `HOME` before anything launches.
Launch agy from the account's real `HOME`; never substitute a throwaway one on macOS.
A signed-out agy answers `agy models` with an empty catalog, and the spawn refuses with the sign-in step.
Treat that refusal, and any auth prompt, as a credential blocker under `../../../../../AGENTS.md` section 9: the captain runs `agy` once in a normal terminal and signs in.
Never type into a pane that shows an auth prompt; retire the endpoint instead.

## Detection

Detected by ancestry alone: `../../../../../bin/fm-harness.sh` matches the anchored process name `agy`, never `*agy*`.
No environment marker is promoted: `AGENT=1` observed on a live TUI is an inherited launcher value, not an agy identity, and agy does not clear an inherited `CLAUDECODE` - but a structural agy ancestor now outranks that retained marker, which `../../../../../bin/fm-harness.sh` decides without depending on the spawn's own launch-boundary marker clearing.
agy is deliberately absent from the session-lock name vocabulary owned by `../../../../../bin/fm-session-lock-lib.sh`, so agy cannot own a home session lock.

## Worker busy state and turn end

`../../../../../bin/fm-spawn.sh` arms no busy generation for agy and writes no sidecar, exactly because no writer could ever clear a seeded record.
`fm_busy_agy_tail_busy` matches the pinned `esc to cancel` status row alone, hardcoded with no environment override, and `fm_busy_classify` reports `unknown agy-regex` rather than idle when it is absent, because a long turn can scroll the marker out of the captured tail.
Teardown removes nothing agy-specific because the spawn leaves nothing behind.

## Primary integration

Unsupported and unverified.
`../../../../../docs/supervision-protocols/` carries no agy protocol, no turn-end guard adapter exists for it, and this adapter verified only the crewmate-side launch, busy state, interrupt, and exit.
`references/common/primary-hooks.md`'s unsupported-boundary rule applies: never invent a wake protocol from a similar TUI.
