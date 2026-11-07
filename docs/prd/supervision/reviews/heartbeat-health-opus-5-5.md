# Review: Heartbeat health PRD (reviewer A)

- PRD: `docs/prd/supervision/heartbeat-health.md` at commit `8963bced`
- Reviewer: Opus 5.5 (`claude-opus-5-5`, reasoning effort xhigh)
- Review type: adversarial, independent of the other reviewer
- Verdict: **block**

## Summary

The PRD picks the right problem: one health verdict per home, with one owner per signal.
As written it cannot be built without guesses.
It does not name which of three freshness records counts as the heartbeat.
It ignores the supervision model, so every long Claude turn would read as stale.
It assigns watcher freshness to two components that already overlap in code.
It also leaves two restart paths without a budget or an owner.
Every BLOCKING fix below is a text change to the PRD.
None needs new design work except the shared restart ledger in finding A-HB-5, which is also a cross-PRD issue.

Finding IDs use the prefix `A-HB-` so they do not collide with the PRD's own `HB-` requirement IDs.

## Findings

### A-HB-1. BLOCKING, high: "heartbeat age" and "watcher age" name no record

- Dimension: failure modes, missed work.
- Evidence:
  - Three freshness records exist, and each moves at a different rate.
  - `state/.last-watcher-beat` is touched once per watcher poll (`bin/fm-wake-lib.sh:180-182`; the watcher's poll is 15 seconds by default).
  - `state/heartbeat.json` carries its own `generated_epoch`. The watcher publishes it detached and single-flight, so one publish can run up to `FM_HEARTBEAT_DEADLINE` (240 seconds, `bin/fm-heartbeat.sh:1-21`) or fail.
  - `state/.last-heartbeat` marks the last `heartbeat:` wake. It backs off from 600 seconds up to 7200 seconds when the fleet is quiet.
  - HB-2 (line 56) says "heartbeat age" and "watcher age" and never says which record either one is.
  - HB-3 (line 57) has no stale bound. OQ-HB-1 (line 116) leaves the bound open.
- Failure scenario: an implementer reads `.last-heartbeat` as heartbeat age. A healthy idle home then reads `stale` for up to two hours, every time the backoff stretches. The reverse mistake is worse. If an implementer reads `.last-watcher-beat` as heartbeat age, a publisher that has hung for an hour still reads `ok`.
- Smallest fix:
  - In HB-2, define heartbeat age as `now - generated_epoch` from `state/heartbeat.json`.
  - Define watcher age as the age of `state/.last-watcher-beat`.
  - State that `state/.last-heartbeat` is wake bookkeeping and never a health input.
  - Close OQ-HB-1 with a provisional default: the stale bound equals `watcher-stale-secs` (900 seconds, `docs/watchdog.md:196-236`). The watchdog already uses that bound for heartbeat age (`bin/fm-watchdog.sh:371`).

### A-HB-2. BLOCKING, high: the verdict ignores the supervision model, so long Claude turns read as stale

- Dimension: failure modes, token economics.
- Evidence:
  - On Claude, the watcher runs only between turns. That is the `autoarm` model (`fm_supervision_model` notes, `bin/fm-wake-lib.sh:280-288`).
  - During a long turn, neither `.last-watcher-beat` nor `heartbeat.json` advances.
  - The code already handles this. `fm_watcher_supervision_verdict` (`bin/fm-wake-lib.sh:513`) is model-aware, and `fm_autoarm_midturn_healthy` (`:527`) treats a live mid-turn session as healthy.
  - HB-3 (line 57) says a heartbeat older than the bound "reports `stale` and never `ok`".
  - HB-8 (line 62) raises a gap after two lost poll cycles. That is 30 seconds at the default poll.
- Failure scenario: a Claude primary runs a 20-minute turn. Under HB-8 a gap fires after 30 seconds. Under HB-3 the verdict turns `stale` after 15 minutes. Either one drives an escalation, and on an attended home it drives a supervisor wake. Both repeat on most working turns. The false stale would happen often and would cost tokens.
- Smallest fix:
  - Add to HB-2: "Watcher age is judged through `fm_watcher_supervision_verdict`. A watcher that the supervision model expects to be paused mid-turn reports `ok`, not `stale`."
  - Make HB-8 apply only to the `persistent` and `extension` models, or to an `autoarm` watcher that is expected to be running.
  - Add an acceptance test: a Claude primary in a 30-minute turn with a live lock produces `ok` and no gap.

### A-HB-3. BLOCKING, high: watcher freshness has two owners, and gap G3 is factually wrong

- Dimension: duplicate ownership.
- Evidence:
  - The ownership table (line 72) names `bin/fm-watchdog.sh` as the owner of watcher freshness. Line 73 names the process-manager unit from `bin/fm-monitor-watchdog.sh` for watcher process liveness.
  - `bin/fm-monitor-watchdog.sh` already checks more than process presence. Its `status` command checks "the identity-matched watcher and fresh beacon" (help text at `:120`; refusal text at `:218`). Its run loop calls `fm_watcher_healthy` every second while the arm runs (`:187-193`).
  - After two unhealthy arm exits (`:196-201`) it pages through `bin/fm-supervise-daemon.sh page` (`watchdog_alert`, `:136-158`).
  - So gap G3 (line 42), "proves the watcher process lives but not that the watcher still polls", does not match the code.
  - The watchdog also raises a watcher-stale gap (`docs/watchdog.md:73`). One wedged watcher can therefore reach the owner twice, once as a page from the process manager and once as a watchdog gap.
- Failure scenario: the watcher wedges. The process manager pages once. The watchdog then raises its own gap, and the health verdict escalates a third time. HB-10 and line 77 ("No second component ... re-arms a layer another row owns") cannot both hold, because two rows already escalate the same fact.
- Smallest fix:
  - Rewrite G3: "The outer guard proves beacon freshness; nothing joins its alert with the watchdog's gap."
  - Name one escalation owner for watcher health. The recommended owner is the health-verdict owner. Have it read `state/.monitor-watchdog-alert` as an input, rather than having the process manager page on its own.
  - If the process-manager page must stay, state that the watchdog suppresses its own watcher gap while that alert file is present.

### A-HB-4. BLOCKING, high: the outer guard can restart forever with no budget

- Dimension: restart loops.
- Evidence:
  - The launchd plist sets `KeepAlive` true (`bin/fm-monitor-watchdog.sh:64`) with `ThrottleInterval` 1 (`:65`).
  - The systemd unit sets `Restart=always` (`:85`), `RestartSec=1s` (`:86`), and `StartLimitIntervalSec=0` (`:79`). The last setting turns off systemd's own start-rate limit.
  - Inside the service, `watchdog_run` restarts the arm after a one-second sleep (`:209`), with no cap.
  - The page is rate-limited (`FM_MONITOR_ALERT_RETRY_SECS`, default 60, `:137-144`). The restarts are not.
  - HB-9 (line 63) limits which layer restarts. It sets no count, window, or backoff.
- Failure scenario: a bad config line or a missing dependency makes the watcher exit at start. The arm restarts about once a second, around the clock, and each restart spawns a new arm process. Nothing marks the loop as escalated. The page repeats every minute until someone notices.
- Smallest fix: add HB-11.
  - "Each restarting layer has a restart budget (count per window) and exponential backoff."
  - "After the budget is spent, the layer writes one escalated marker and stops restarting until the marker clears."
  - Reuse the watchdog's existing shape: `max-restarts` 2 per `restart-secs` 7200, plus an escalated marker (`docs/watchdog.md:107-115`).
  - Add an acceptance test: an arm that exits at once stops restarting after the budget, writes one marker, and sends one page.

### A-HB-5. BLOCKING, high: self-heal of the outer guard has no owner, and its status is never read

- Dimension: missed work, failure modes.
- Evidence:
  - Gap G4 (line 43) states the problem, and no requirement closes it.
  - DR-HB-5 (line 97) only records "which external path notices".
  - No script in `bin/` calls `bin/fm-monitor-watchdog.sh status` or `manager-status`. Only the operator runs them (`docs/watcher-continuity.md:236-237`).
  - `bin/fm-watchdog.sh` has its own `manager-status` (`:1667`), but that command reports on the watchdog's own unit, not on the monitor unit.
  - The external Orca loop (lines 46-51) is an unconfirmed dependency by the PRD's own words.
- Failure scenario: the monitor unit is unloaded or disabled, for example after an OS update or a manual `launchctl` change. The watcher dies on the next Claude turn end and nothing re-arms it. No component reports this. The first signal is the owner noticing that work has stopped. On a machine where neither unit was ever installed, this is already the steady state.
- Smallest fix:
  - Add HB-12: "Each guard layer is checked by exactly one layer above it."
  - Write the chain explicitly. The OS manager keeps the monitor alive. `bin/fm-watchdog.sh` reads `fm-monitor-watchdog.sh manager-status` on each pass and folds `uncovered` or `disabled` into the health verdict. The top layer, the watchdog itself, is covered by its status file's "STALE IF NOT UPDATED BY" field (`docs/watchdog.md:147-148`), which session start reports. The external loop is an optional extra, not the top of the chain.
  - Add an acceptance test: a disabled monitor unit produces one `unknown` or `stale` health record that names the uncovered layer.

### A-HB-6. BLOCKING, high: restarting a dead primary has no owner in any PRD

- Dimension: duplicate ownership, missed work, safety.
- Evidence:
  - This PRD detects a dead lock owner (HB-4, line 58). It assigns no restart.
  - `stall-context-recovery.md` excludes dead owners from its scope (lines 13-14).
  - The watchdog's agent-gone row restarts a dead primary (`docs/watchdog.md:58`), but only when `restart` is on. The documented default is `restart` off, in `dry-run` mode (`docs/watchdog.md:196-236`).
  - `docs/watchdog.md:187` allows an external restarter, with its own contract.
- Failure scenario A: the watchdog is off or in dry-run mode, the default. The primary dies. HB-4 reports `dead`, one escalation fires, and nothing restarts the primary. The home stays down until a human acts. During quiet hours that can be 10 to 63 hours (see `escalation-quiet-hours.md` EQ-9 and EQ-10).
- Failure scenario B: both the watchdog restart path and an external restarter are enabled. Both launch a primary. The session lock picks one winner. The loser still spends a full startup and may touch the handoff document.
- Smallest fix:
  - Add an ownership row: "Dead primary restart: the watchdog agent-gone path when `restart` is on; otherwise the external restarter under the `docs/watchdog.md:187` contract; when neither is configured, one escalation and no restart."
  - State that the two restarters are never enabled together for one home.

### A-HB-7. BLOCKING, medium: the captain record's `none` verdict maps to no health verdict

- Dimension: missed work.
- Evidence:
  - The captain record publishes `live`, `dead`, `unconfirmed`, and `none` (line 28; `docs/watchdog.md:154-188`).
  - HB-1 (line 55) lists `ok`, `stale`, `dead`, `unconfirmed`, and `unknown`. It has no `none`.
  - HB-2 through HB-6 never say what `none` becomes.
  - `none` is the exact state after a handoff whose successor never took the lock (see `stall-context-recovery.md` SC-12 and SC-13).
- Failure scenario: a predecessor stops and its successor dies before session start. The lock has no holder. Open work and queued wakes sit untouched. The health verdict has no defined value, so it may read `unknown` and never escalate.
- Smallest fix: add to HB-2: "`none` with open work, or with the away record present, reports `dead`. `none` with no open work reports `ok` and names the home idle."

### A-HB-8. BLOCKING: the token baseline is not measurable as written

- Dimension: token economics.
- Evidence:
  - The counters (line 110) are "wake records drained per day" and "token fields in `state/watchdog/model-calls.tsv`".
  - Wake rows are deleted when they are acknowledged (`bin/fm-wake-drain.sh:898-913`). No durable record of drained wakes exists to count.
  - `model-calls.tsv` logs only the watchdog's own judge calls (`docs/watchdog.md:142`; columns at `bin/fm-watchdog.sh:23-24`). The supervisor's tokens are not in it. The file exists only when a judge model is configured, and judge models are off by default.
- Failure scenario: after 28 days, both counters read zero or are missing. The PRD then cannot show a saving or a cost.
- Smallest fix: adopt the cross-PRD instrumentation in the report (issue A-X1): a durable wake ledger written at acknowledgement, and a per-session token ledger built from transcript usage. Count heartbeat wakes and stale-handling turns separately. This PRD's main effect is fewer duplicate escalations and wakes, not fewer judge tokens.

### A-HB-9. NON-BLOCKING, medium: the captain record is fresh only while the watchdog runs

- Dimension: failure modes.
- Evidence: `state/watchdog/captain` is written on watchdog passes. HB-2 derives the lock verdict from that record. Line 71 names the shared lock contract as the true owner.
- Failure scenario: the watchdog stops. The captain record keeps its last value, `live`, while the primary dies. Readers other than the watchdog see `live`.
- Smallest fix: require readers to check the record's `checked_at` age against the stale bound and report `unknown` when it is too old. Or call the lock contract in `bin/fm-session-lock-lib.sh` directly.

### A-HB-10. NON-BLOCKING, medium: `ok` means alive, not able to work

- Dimension: quota exhaustion, missed work.
- Evidence: a primary on a usage-limit screen holds a live lock and a live process. Between turns, its watcher still beats. HB-1 reports `ok`. The watchdog's quota rows for the home pane only name a candidate (`docs/watchdog.md:77-88`).
- Failure scenario: the primary hits its provider limit at night. Health reads `ok` for hours while wakes queue.
- Smallest fix: state in the Scope section that `ok` proves liveness only. Add a pointer that a quota-limited primary is owned by the quota PRD (see the quota review, finding A-QA-5).

### A-HB-11. NON-BLOCKING, low: HB-10 names no record and no retention

- Dimension: duplicate ownership.
- Evidence: HB-10 (line 64) requires "one durable record" per transition but names no file, no schema, and no retention. `state/watchdog/actions.tsv` already records watchdog gaps and actions (`docs/watchdog.md:132`).
- Smallest fix: name the record. Prefer a row kind in `actions.tsv` or the shared incident ledger from the escalation review (finding A-EQ-3). Do not add a third ledger.

### A-HB-12. NON-BLOCKING, medium: drills that kill processes must name an isolated environment

- Dimension: safety.
- Evidence: DR-HB-1 kills the lock owner, DR-HB-3 stops the watcher, and DR-HB-5 kills the outer guard (lines 93-97). None names where they run. `docs/watchdog.md:240` shows the existing pattern: tests use a private tmux socket.
- Smallest fix: add one line: "Every drill runs on a fixture home with a private tmux socket or a named, non-default Herdr lab, never on a live home."

## Coverage

| Dimension | Result | Findings |
| --- | --- | --- |
| Failure modes | Gaps: undefined freshness records, false stale on long Claude turns, a stale captain record | A-HB-1, A-HB-2, A-HB-9 |
| Token economics | Baseline counters do not exist or do not hold supervisor tokens | A-HB-8, A-HB-2 |
| Safety | Two primaries possible; drills lack isolation | A-HB-6, A-HB-12 |
| Duplicate ownership | Watcher freshness has two escalating owners | A-HB-3, A-HB-11 |
| Quota exhaustion | A quota-limited primary reads `ok` | A-HB-10 |
| Restart loops | The outer guard restarts once a second with no budget | A-HB-4 |
| Missed work | Outer-guard death and the `none` lock state go unreported; a dead primary is never restarted by default | A-HB-5, A-HB-6, A-HB-7 |

## What holds up

- HB-5 matches the merged unconfirmed-owner rule: no typed signal and no restart.
- HB-6 keeps the heartbeat's `{unknown:true,reason}` contract.
- The external Orca loop is correctly treated as a dependency, not a claim.
- Every cited test suite exists: `tests/fm-heartbeat.test.sh` and `tests/fm-watchdog.test.sh`.
