# Adversarial Review: `docs/prd/supervision/stall-context-recovery.md`

- **Reviewer**: Gemini Argon (`model_id=gemini-4-argon-high`, `reasoning_effort=high`, `Gemini 4 Argon (High)`, `harness=agy`)
- **Target PRD**: `docs/prd/supervision/stall-context-recovery.md` (branch `fm/fm-supervision-prds`, commit `8963bcedb85e8cd6c3a9d140aed32df9fe6d4dd0`, https://github.com/Pibomeister/firstmate/pull/159)
- **Verdict**: **`block`**

---

## Summary Verdict & Axis Coverage

| Review Axis | Status | Primary Finding(s) |
|---|---|---|
| 2026-11-06 18:13 CR Cost-Rollout Startup/Handoff Budget Requirement | **BLOCKING** | Finding 1 |
| Failure modes | **BLOCKING** | Findings 2, 3, 4, 6 |
| Token economics (measurable vs estimated) | **BLOCKING** | Findings 1, 5 |
| Safety | **BLOCKING** | Finding 6 |
| Duplicate ownership (1 owner per signal) | **BLOCKING** | Finding 3 |
| Quota exhaustion | **BLOCKING** | Finding 7 |
| Restart loops | **BLOCKING** | Findings 1, 2, 3 |
| Missed work | **BLOCKING** | Findings 2, 4 |

---

## Numbered Findings

### Finding 1 — `[BLOCKING]` `[Severity: critical]`
**Title**: Missing mandatory cost-rollout requirements (2026-11-06 18:13 CR): bounded total startup/context token load, capped `data/handoff-*.md` size, anti-hourly-handoff churn guard, and AFK handoff/startup-token acceptance test.

- **Category**: Token economics / Restart loops / Failure modes (2026-11-06 18:13 CR cost rollout)
- **Evidence**:
  - Added acceptance requirement (`2026-11-06 18:13 CR`): supervisor context turnover is a primary cost driver (two M4 handoffs in ~1h at 17:47 and 18:12). `docs/prd/supervision/stall-context-recovery.md` (lines 1–135) contains **zero** requirements, bounds, or acceptance tests for:
    1. Measuring and budgeting total tokens consumed by session startup (`bin/fm-session-start.sh` output + successor handoff prompt + initial context load).
    2. Sizing `data/handoff-*.md` (`bin/fm-handoff-trigger.sh:74,209` and `bin/fm-watchdog.sh:740-778,1252`) to a hard byte/token cap.
    3. Preventing hourly handoff/startup churn under normal load.
    4. Acceptance test: *N hours AFK with handoffs <= target and startup tokens <= budget, measured vs baseline*.
  - Grounding in actual code:
    - `bin/fm-startup-memory-budget-lib.sh:11-18` (called by `bin/fm-bootstrap.sh:79-83,206`) only budgets static memory files (`config/startup-memory-budget`, default `7500` estimated tokens across `data/captain.md`, `data/captain-shared.md`, `data/secondmates.md`, and `data/learnings.md`). It does **not** measure or bound the full `bin/fm-session-start.sh` digest (supervision operating instructions, backlog, fleet status, wake drain, network checks) OR the `data/handoff-*.md` file read at startup (`bin/fm-handoff-trigger.sh:169`, `bin/fm-watchdog.sh:767,823`).
    - `bin/fm-handoff-trigger.sh:67-77,207-221` (merged in https://github.com/Pibomeister/firstmate/pull/156 commit `7a050002`) instructs the predecessor to write a *"full session handoff to `data/handoff-<timestamp>-<topic>.md`"* (`bin/fm-handoff-trigger.sh:209`) with **no size cap** and **no minimum inter-handoff cooldown** across sessions (only per-session `state/handoff-triggered/<session-id>` in `bin/fm-handoff-trigger.sh:64,132`). If each successor session starts with a huge `fm-session-start.sh` digest plus an uncapped `data/handoff-*.md` plus active fleet wakes, it burns through the `autoCompactWindow` rapidly and triggers `bin/fm-handoff-trigger.sh` again within ~25–60 minutes (reproducing the 17:47 and 18:12 M4 double handoff).
    - `bin/fm-context-burn.sh:9-33` (merged in https://github.com/Pibomeister/firstmate/pull/102 commit `a34277d6`) already classifies `turn_type=startup` and records `state/context-burn.tsv`, and `bin/fm-heartbeat.sh:172-215` reads exact JSONL transcript token usage (`input_tokens + cache_creation_input_tokens + cache_read_input_tokens + output_tokens`), providing the exact primitives needed to measure startup token load.
- **Impact**: Without a startup token budget, a `data/handoff-*.md` cap, and a cross-session handoff-rate guard, auto-handoff (`bin/fm-handoff-trigger.sh`) and watchdog low-context restart (`bin/fm-watchdog.sh:1243-1273`) amplify token spend by cycling fresh sessions through expensive startups every hour.
- **Smallest Concrete Fix**: Add to `docs/prd/supervision/stall-context-recovery.md`:
  1. **Requirement `SC-15` (Startup token measurement & budget)**: Measure actual startup turn token consumption (`used_tokens` after the `turn_type=startup` turn in the session transcript / `state/context-burn.tsv`) and enforce a configurable startup token budget (e.g., `config/startup-token-budget`), surfacing a deterministic diagnostic when startup output + handoff exceeds the budget.
  2. **Requirement `SC-16` (Handoff document cap)**: Enforce a hard byte/token cap on `data/handoff-*.md` (e.g., max `16 KiB` / `4000` tokens) in both `bin/fm-handoff-trigger.sh` and `bin/fm-watchdog.sh` (`wd_write_handoff`), truncating or rejecting oversized handoff payloads and requiring pointer references (`bin/fm-context-burn.sh report <file-under-data>`) for long artifacts.
  3. **Requirement `SC-17` (Anti-hourly handoff churn guard)**: Enforce a minimum inter-handoff interval across consecutive sessions of the same home ( matching `bin/fm-watchdog.sh`'s `restart-secs=7200` at `bin/fm-watchdog.sh:696,734`) in `bin/fm-handoff-trigger.sh`, so a home cannot auto-spawn a successor more than once per cooldown window under normal load; if context hits the threshold inside the cooldown window, record a `context-churn` alert instead of spinning another M4 handoff.
  4. **Acceptance Test `AT-SC-6`**: Run an `N`-hour AFK supervision window and verify against baseline that (a) handoff count `<= target` (no hourly handoff churn, `<= 1` handoff per `restart-secs` window) and (b) measured startup tokens (`turn_type=startup` transcript usage + `data/handoff-*.md` bytes) `<= budget`.

---

### Finding 2 — `[BLOCKING]` `[Severity: critical]`
**Title**: Successor liveness recheck (`SC-11`, `SC-12`, `SC-13`) has no owner, no timing mechanism after predecessor exit, no parent supervisor for a primary home, and leaves a predecessor-termination / watchdog double-spawn race.

- **Category**: Failure modes / Restart loops / Missed work
- **Evidence**:
  - `docs/prd/supervision/stall-context-recovery.md:57-59` (`SC-11`, `SC-12`, `SC-13`):
    - `SC-11`: *"A handoff completes only after the successor session proves liveness."*
    - `SC-12`: *"Successor liveness is rechecked once after the predecessor stops."*
    - `SC-13`: *"A successor that fails the recheck raises one blocked record for the parent supervisor."*
  - `docs/prd/supervision/stall-context-recovery.md:85-94` ("Ownership" table) lists **no owner** for `SC-12` or `SC-13`.
  - In `bin/fm-handoff-trigger.sh:78-87,175-184` (merged in https://github.com/Pibomeister/firstmate/pull/156 commit `7a050002`):
    1. `fm-handoff-trigger.sh` runs inside the **predecessor's** Claude `Stop` hook. It spawns the successor terminal (`bin/fm-handoff-trigger.sh:170-173`), sleeps `FM_HANDOFF_VERIFY_SECS=2`, checks `kill -0 "$SUCC_PID"` **while the predecessor is still alive and holding `state/.lock`**, and then exits (`bin/fm-handoff-trigger.sh:175-184`).
    2. Because the predecessor is dead once it stops, `bin/fm-handoff-trigger.sh` **cannot** run `SC-12` ("rechecked once after the predecessor stops").
    3. Worse, `bin/fm-handoff-trigger.sh:81-84,212-220` never stops the predecessor itself (*"The predecessor process is then ended by the captain, by a leash or operator /exit in its pane, or by the watchdog restart path"*), nor does it create `state/.watchdog-restart-request`! So in an unattended AFK session, after the predecessor writes `data/handoff-*.md`, nothing terminates the predecessor until context drops further to `restart-at-percent=8` (`bin/fm-watchdog.sh:1401`)—at which point `bin/fm-watchdog.sh` (`wd_restart`, `bin/fm-watchdog.sh:825-831`) kills the predecessor and **spawns a SECOND successor terminal**, duplicating the successor already spawned by `bin/fm-handoff-trigger.sh:170`!
    4. Even if the predecessor exits cleanly, until the successor finishes `bin/fm-session-start.sh` and acquires `state/.lock`, `O_LOCK_PID` in `state/.lock` is dead (`O_ALIVE=0`). If `bin/fm-watchdog.sh` runs `wd_handle_subject` (`bin/fm-watchdog.sh:1390-1397`), it sees `agent-gone`!
    5. Finally, `SC-13` states *"raises one blocked record for the parent supervisor"*, but `bin/fm-handoff-trigger.sh` runs on a **primary** firstmate (`docs/prd/supervision/stall-context-recovery.md:91`: *"Context handoff (Claude primary) | `bin/fm-handoff-trigger.sh`"*). A primary firstmate has **no parent supervisor** (`O_PARENT=-` in `bin/fm-watchdog.sh:123`)! Writing a `blocked` record into `state/*.status` when the primary successor is dead wakes nobody because the primary supervisor itself is the dead process.
- **Impact**:
  - Unattended `fm-handoff-trigger.sh` handoffs either leave both predecessor and successor running concurrently (with the successor failing session-lock acquisition in `bin/fm-session-start.sh` because the predecessor still holds `state/.lock`!) or cause `bin/fm-watchdog.sh` to spawn a second conflicting successor when context reaches 8%.
  - If a primary's successor dies after the predecessor stops, a `blocked` record in `state/` is never read by any parent supervisor (`SC-13`).
- **Smallest Concrete Fix**:
  1. Assign post-stop successor pickup verification (`SC-12`, `SC-13`) to `bin/fm-watchdog.sh` (`wd_reconcile_pending` at `bin/fm-watchdog.sh:854-873` using `state/watchdog/pickups/<token>`), which already runs outside every session.
  2. Have `bin/fm-handoff-trigger.sh` coordinate with `bin/fm-watchdog.sh` instead of spawning an untracked parallel terminal while the predecessor still holds `state/.lock`: either `bin/fm-handoff-trigger.sh` writes `state/.watchdog-restart-request` once `data/handoff-*.md` is written so `bin/fm-watchdog.sh` performs the single atomic `TERM predecessor -> spawn successor -> verify pickup token` transition (`bin/fm-watchdog.sh:810-873`), OR `bin/fm-handoff-trigger.sh` records a pending restart row/token in `state/watchdog/` before stopping the predecessor so `bin/fm-watchdog.sh` suppresses duplicate spawns (`restart-awaiting-pickup`, `bin/fm-watchdog.sh:1383-1386`) and verifies pickup within `pickup-secs=600`.
  3. In `SC-13`, distinguish subject types: for a second mate, a failed relaunch raises a `blocked` record / parent wake AND `wd_self_heal` (`bin/fm-watchdog.sh:793-795`); for a primary firstmate (which has no parent supervisor), `bin/fm-watchdog.sh` runs `wd_self_heal` / pages via `fm-supervise-daemon.sh page` (`bin/fm-watchdog.sh:870-873`).

---

### Finding 3 — `[BLOCKING]` `[Severity: critical]`
**Title**: Context percentage disagreement rule (`SC-7`, `SC-8`, `SC-9`) fails to resolve duplicate ownership on a Claude primary session because `bin/fm-watchdog.sh` and `bin/fm-handoff-trigger.sh` both act on the same Claude primary using different percentages.

- **Category**: Duplicate ownership / Restart loops / Failure modes
- **Evidence**:
  - `docs/prd/supervision/stall-context-recovery.md:39` (Gap 1): *"Pane footer context percentage and derived token percentage can disagree on a 1M window | Low-context handoff can fire early or late."*
  - `docs/prd/supervision/stall-context-recovery.md:53-55` (`SC-7`, `SC-8`, `SC-9`):
    - `SC-7`: *"The derived token percentage owns the Claude primary handoff decision."*
    - `SC-8`: *"The pane footer percentage owns the watchdog restart decision for sessions with no derived reading."*
    - `SC-9`: *"When both readings exist and differ by more than the disagreement bound, the reading of the owning path acts and the record names both values."*
  - Compare with actual code:
    - `bin/fm-handoff-trigger.sh:14-17,114-127,196-200` computes the derived auto-compact remaining percentage from the Claude transcript usage and `autoCompactWindow` (`fm_compact_left_percent`, firing at `FM_HANDOFF_THRESHOLD=15`). It explicitly distrusts `context_window.remaining_percentage` because on a 1M model with `autoCompactWindow=250000`, `remaining_percentage` reports `78%` right as auto-compact fires (`bin/fm-handoff-trigger.sh:14-17`)!
    - Meanwhile, `bin/fm-watchdog.sh:357,371-373,415-416,1401` reads `O_CTX` for **every** home (including a Claude primary!) from `state/heartbeat.json`'s `.primary.context_left.remaining.percent` (`bin/fm-heartbeat.sh:254-264`, which parses the pane footer via `fm_context_footer_percent_from_text` in `bin/fm-context-footer-lib.sh:12-24`) or directly from `fm_wd_footer_percent "$O_PANE"`.
    - Furthermore, as noted in `bin/fm-context-burn.sh:15-19`, *"Claude Code draws that footer only in the last 20000 tokens before auto-compact"*.
  - Look at what happens under `SC-7`, `SC-8`, and `SC-9`:
    1. `SC-9` says *"When both readings exist and differ by more than the disagreement bound, the reading of the owning path acts"*. Because `bin/fm-handoff-trigger.sh` is one path and `bin/fm-watchdog.sh` is a second path, and **both run against the Claude primary**, saying "the reading of the owning path acts" means `fm-handoff-trigger.sh` acts on derived `%` while `fm-watchdog.sh` acts on footer `%`!
    2. Worse, when a Claude primary has >20,000 tokens left before auto-compact, the pane footer is not drawn (`O_CTX` is empty in `bin/fm-watchdog.sh`), OR if `bin/fm-heartbeat.sh:255` publishes `used_tokens` without a derived percentage in `.primary.context_left.remaining.percent`, `bin/fm-watchdog.sh` has no reading until the last 20k tokens. Conversely, if a non-Claude or 1M session displays a full-window `%` in the footer while `fm-handoff-trigger.sh` uses `autoCompactWindow`, both paths act at different times on the same session.
- **Impact**: A Claude primary is still subject to two independent low-context handoff/restart controllers (`bin/fm-handoff-trigger.sh` at `15%` derived vs `bin/fm-watchdog.sh` at `8%` footer) that do not share a single context-remaining metric in `state/heartbeat.json`.
- **Smallest Concrete Fix**:
  1. Have `bin/fm-heartbeat.sh` (`primary_context_json`, `bin/fm-heartbeat.sh:250-266`) compute and publish both `footer_percent` and `derived_autocompact_percent` (via `bin/fm-compact-point-lib.sh`) in `state/heartbeat.json`, with a single authoritative `effective_percent` (`derived_autocompact_percent` when a Claude transcript + compact window exist, else `footer_percent`).
  2. Replace `SC-7`/`SC-8`/`SC-9` with a single-source rule: for any session where `derived_autocompact_percent` exists, **both** `bin/fm-handoff-trigger.sh` and `bin/fm-watchdog.sh` read `derived_autocompact_percent` (never raw `context_window.remaining_percentage`), and when `footer_percent` is also visible and differs by more than `disagreement_bound`, log both values while gating exclusively on `derived_autocompact_percent`.

---

### Finding 4 — `[BLOCKING]` `[Severity: high]`
**Title**: `SC-5`, `SC-6`, and `AT-SC-2` leave a 100% blind spot for non-Claude supervisor harnesses (`codex`, `agy`, `cursor`, `muse`, `opencode`, `pi`, `grok`, `kimi`) where `wd_transcript` finds no Claude transcript (`O_TR_AGE=unknown`).

- **Category**: Missed work / Failure modes
- **Evidence**:
  - `docs/prd/supervision/stall-context-recovery.md:40,51-52,65` (`SC-5`, `SC-6`, `AT-SC-2`):
    - Gap 2: *"A frozen check without a transcript source cannot prove quiet | The check refuses rather than guessing."*
    - `SC-5`: *"A stall check that lacks a transcript or activity source records `no-activity-source` and takes no destructive action."*
    - `SC-6`: *"When an activity source is absent, the status file names the missing source."*
  - Inspecting `bin/fm-watchdog.sh:191-200,418-426,726,1393,1411,1444-1446`:
    - `wd_transcript` (`bin/fm-watchdog.sh:191-200`) **only** searches `CLAUDE_CONFIG_DIR` (`$d/projects` via `fm_warm_compact_engine_transcript`).
    - For **every** primary or secondmate running on `codex`, `agy`, `cursor`, `muse`, `opencode`, `pi`, `grok`, or `kimi`, `wd_transcript` always returns `1`, so `O_TR_AGE` is permanently `unknown`!
    - When `O_TR_AGE=unknown`, `bin/fm-watchdog.sh:726,1393,1411,1445` disables **all** `agent-gone` dead-holder restarts, **all** `frozen` nudges and restarts, and **all** `restart-requested` / low-context restarts (`wd_gap "no activity source; frozen, dead-holder, and low-context restarts are unavailable"`).
- **Impact**: Codifying `O_TR_AGE=unknown -> no-activity-source` (`SC-5`, `SC-6`) without providing a fallback activity source (or even a nudge-only path on `frozen`) permanently disables dead-lock-holder recovery (`agent-gone`), `frozen` recovery, and low-context restarts for every non-Claude supervisor harness, even when `O_ALIVE=0` (kernel proof that the lock PID is dead) and `O_PANE_STATIC >= frozen-secs` (rendered proof that the terminal has not changed for 15+ minutes) and `state/.lock` / `state/*.status` mtimes are older than `frozen-secs`!
- **Smallest Concrete Fix**:
  1. For `agent-gone` (`O_ALIVE=0`, lock holder process is dead in kernel) and `frozen` nudges (which are non-destructive doorbells, `SC-5` only forbids *destructive* actions), allow fallback filesystem activity proof when no Claude transcript exists (e.g., max mtime across `state/.wake-queue` acks, `state/.last-SessionStart`, `state/context-burn.tsv`, and `O_PANE_STATIC >= frozen-secs` with `O_TURN=0` and `O_CPU_BUSY=0`).
  2. At minimum, allow non-destructive `wd_nudge frozen` when `O_PANE_STATIC >= frozen-secs && O_OWED_N > 0 && O_OWED_AGE >= frozen-secs && O_TURN = 0 && O_CPU_BUSY = 0` even when `O_TR_AGE=unknown` (`SC-5` explicitly says *"takes no destructive action"*, whereas `bin/fm-watchdog.sh:1411` currently blocks even the non-destructive nudge!).

---

### Finding 5 — `[BLOCKING]` `[Severity: high]`
**Title**: Token economics baseline method (`state/watchdog/model-calls.tsv`) fails to measure supervisor context burn, handoff cost, or wake tokens.

- **Category**: Token economics
- **Evidence**:
  - `docs/prd/supervision/stall-context-recovery.md:124-129` ("Token economics"): *"Baseline method: Count supervisor wakes and model tokens before and after this work from `state/watchdog/actions.tsv`, `state/watchdog/model-calls.tsv`, and the wake logs across a comparable work window. Compare both wake count and total tokens using the token fields in `state/watchdog/model-calls.tsv`, not wake count alone."*
  - `bin/fm-watchdog.sh:49,538-594`: `state/watchdog/model-calls.tsv` only logs `wd_judge_one` calls (`claude:haiku` / `agy:gemini-3.8-flash-low` with `--max-budget-usd 0.05` on `near-loop`, `dialog`, and `council`).
  - It logs **zero** tokens when a supervisor session loops on wakes, writes a `data/handoff-*.md` document, or boots a new successor session (`bin/fm-session-start.sh`)—which costs tens or hundreds of thousands of Opus/Argon/Sonnet tokens per handoff!
- **Impact**: Measuring `stall-context-recovery` token economics solely via `state/watchdog/model-calls.tsv` is blind to the actual token cost of supervisor stalls, handoffs, and restarts.
- **Smallest Concrete Fix**: Require the baseline and post-change measurement in `stall-context-recovery.md:125-128` to measure:
  1. Supervisor session token usage from session transcripts (`input_tokens + cache_creation_input_tokens + cache_read_input_tokens + output_tokens` via `bin/fm-heartbeat.sh:172-215`) and `state/context-burn.tsv` (`bin/fm-context-burn.sh`), broken down by `turn_type` (`startup`, `wake`, `heartbeat`, `captain`),
  2. Handoff frequency (`ls -l data/handoff-*.md`, `state/handoff-triggered/`, and `restart` rows in `state/watchdog/actions.tsv`), AND
  3. Out-of-session judge tokens in `state/watchdog/model-calls.tsv`.

---

### Finding 6 — `[BLOCKING]` `[Severity: high]`
**Title**: `bin/fm-watchdog.sh` `wd_restart` (`SC-4`, `SC-10`) forcefully `kill -TERM`s the primary lock holder without checking `O_TURN` or active tool execution if `restart-requested` fires right as a new turn begins.

- **Category**: Safety / Failure modes
- **Evidence**:
  - `docs/prd/supervision/stall-context-recovery.md:50,56` (`SC-4`, `SC-10`): *"A restart runs only after two independent stall signals agree and the nudge ladder is exhausted"* and *"A handoff writes a durable handoff file before the old session stops."*
  - In `bin/fm-watchdog.sh:1401-1403` and `1243-1273`:
    ```bash
    elif { [ "$O_RESTART_REQ" = 1 ] || { [ -n "$O_CTX" ] && [ "$O_CTX" -le "$(cfgi restart-at-percent 8)" ]; }; } && wd_restart_available && ! wd_handoff_undeliverable; then
      symptom='restart-requested'
      wd_requested_restart "$quiet"
    ```
    In `wd_requested_restart` (`bin/fm-watchdog.sh:1268-1270`):
    ```bash
    if [ "$O_TR_AGE" != unknown ] && [ "$O_TR_AGE" -ge "$quiet" ]; then
      wd_restart restart-requested filesystem records
    ```
    Notice that `wd_restart` passes `filesystem records` to `wd_restart_gate` (`bin/fm-watchdog.sh:699`: `fm_wd_stall_proof "$O_TURN" "$O_CPU_BUSY" "$@"`). While `fm_wd_stall_proof` checks `O_TURN` at observation time (`wd_observe`), `wd_observe` ran before any earlier subject actions, and for a non-Claude transcript or a tool call that has not flushed to the transcript for `restart-quiet-secs=120` (e.g. a 120s foreground `gh-axi` or `fm-session-start.sh` command), `O_TR_AGE >= 120` can be true while `O_COMPOSER=pending` (a human or operator is actively typing in the primary pane!).
    Unlike `wd_nudge` (`bin/fm-watchdog.sh:496`: refuses when `O_COMPOSER != empty`), `wd_restart` (`bin/fm-watchdog.sh:781-833`) only attempts to copy the draft into `$handoff` (`wd_write_handoff`, losing paste placeholders or unreadable drafts at `bin/fm-watchdog.sh:752,762`) and then immediately sends `kill -TERM "$pid"` (`bin/fm-watchdog.sh:815`)!
- **Impact**: If an operator or the user has half-typed an instruction or paste placeholder in the primary composer when `handoff-wait-secs` expires (`bin/fm-watchdog.sh:1259-1266`), `wd_restart` kills the session and loses the unsent paste (`GAP: an unsent draft could not be read in full ... and its hidden text is lost with this restart`, `bin/fm-watchdog.sh:769`).
- **Smallest Concrete Fix**: Require in `SC-10` / `SC-14` that a low-context restart (`restart-requested`) defers `kill -TERM` while `O_COMPOSER=pending` (unsubmitted human draft in the live composer) unless the session is confirmed dead (`agent-gone`), preserving the composer-empty safety boundary (`docs/watchdog.md:116`).

---

### Finding 7 — `[BLOCKING]` `[Severity: medium]`
**Title**: Quota / credit exhaustion on `bin/fm-handoff-trigger.sh` and `bin/fm-watchdog.sh` restarts when the configured model/account is at a quota floor.

- **Category**: Quota exhaustion / Restart loops
- **Evidence**:
  - `bin/fm-handoff-trigger.sh:170-173` launches a new `claude` session using `build_claude_cmd` (`bin/fm-handoff-trigger.sh:149-166`) on the exact same account and model, and `bin/fm-watchdog.sh:825-831` launches `cfg restart-command` on the same account/model.
  - Neither `bin/fm-handoff-trigger.sh` nor `bin/fm-watchdog.sh` checks whether the subject's current pane shows a `usage-limit` dialog (`O_DIALOG=usage-limit`) before triggering a low-context or frozen restart, EXCEPT that in `bin/fm-watchdog.sh:1398-1401`, `elif [ -n "$O_DIALOG" ]` precedes `restart-requested` (line 1401) and `frozen` (line 1411), **but NOT `agent-gone` (line 1391)**, and `bin/fm-handoff-trigger.sh` has no dialog or quota check at all.
- **Impact**: If a Claude session hits its usage limit on the same turn that crosses the 15% derived handoff threshold, `bin/fm-handoff-trigger.sh` spawns a successor onto the exhausted account, which immediately fails to run `bin/fm-session-start.sh`.
- **Smallest Concrete Fix**: Add a requirement to `stall-context-recovery.md` that `bin/fm-handoff-trigger.sh` skips spawning a successor when the transcript's latest assistant/error event is a usage-limit / rate-limit refusal, leaving quota recovery to `quota-account-routing.md`.
