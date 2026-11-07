# Adversarial Review: `docs/prd/supervision/heartbeat-health.md`

- **Reviewer**: Gemini Argon (`model_id=gemini-4-argon-high`, `reasoning_effort=high`, `Gemini 4 Argon (High)`, `harness=agy`)
- **Target PRD**: `docs/prd/supervision/heartbeat-health.md` (branch `fm/fm-supervision-prds`, commit `8963bcedb85e8cd6c3a9d140aed32df9fe6d4dd0`, https://github.com/Pibomeister/firstmate/pull/159)
- **Verdict**: **`block`**

---

## Summary Verdict & Axis Coverage

| Review Axis | Status | Primary Finding(s) |
|---|---|---|
| Failure modes | **BLOCKING** | Findings 1, 2, 4, 5 |
| Token economics (measurable vs estimated) | **BLOCKING** | Finding 3 |
| Safety | Pass with changes | Finding 7 |
| Duplicate ownership (1 owner per signal) | **BLOCKING** | Findings 1, 2 |
| Quota exhaustion | Pass with changes | Finding 6 |
| Restart loops | **BLOCKING** | Finding 1 |
| Missed work | **BLOCKING** | Findings 4, 5 |

---

## Numbered Findings

### Finding 1 — `[BLOCKING]` `[Severity: critical]`
**Title**: Fixed heartbeat stale bound (`HB-2`, `HB-3`) and unconditional 2-cycle watcher-progress recovery (`HB-7`, `HB-8`) conflict with `autoarm` mid-turn state and quiet-home heartbeat backoff (`FM_HEARTBEAT_MAX=7200`), causing false-stale alarms and watcher restart loops.

- **Category**: Failure modes / Restart loops / Duplicate ownership
- **Evidence**:
  - `docs/prd/supervision/heartbeat-health.md:49-50` (`HB-2`, `HB-3`): *"Each published heartbeat carries its timestamp and its stale bound"* and *"A heartbeat older than the stale bound reports `stale`."*
  - `docs/prd/supervision/heartbeat-health.md:54-55` (`HB-7`, `HB-8`): *"The outer guard checks that the watcher advances its polling progress within two guard cycles"* and *"A watcher process that lives without polling progress for two guard cycles is replaced by the existing recovery path."*
  - `bin/fm-watch.sh:432-433`: `FM_HEARTBEAT` defaults to `600` seconds and backs off exponentially up to `FM_HEARTBEAT_MAX=7200` (2 hours) on quiet homes (`cur_hb=$(( cur_hb * 2 )); [ "$cur_hb" -gt "$HEARTBEAT_MAX" ] && cur_hb=$HEARTBEAT_MAX`). `bin/fm-heartbeat.sh` is invoked by `bin/fm-watch.sh:506` only when a heartbeat cycle fires (`now - hb_last >= cur_hb`).
  - `bin/fm-watchdog.sh:371,1432-1434` (`docs/watchdog.md:73,233`): `fm-watchdog.sh` uses a fixed `watcher-stale-secs=900` (15m) against `state/heartbeat.json` age (`O_HB_AGE`), which is shorter than `FM_HEARTBEAT_MAX=7200` (120m).
  - `bin/fm-wake-lib.sh:252-269,300-311,520-530` and `bin/fm-monitor-watchdog.sh:172-186`:
    1. `bin/fm-monitor-watchdog.sh` ALREADY checks `.last-watcher-beat` freshness via `fm_watcher_healthy "$STATE" "$FM_HOME"` (`bin/fm-wake-lib.sh:252-269`, added in https://github.com/Pibomeister/firstmate/pull/61 commit `94311f2d`), and `bin/fm-watch.sh:229-236,424-431` and `bin/fm-supervise-daemon.sh:2331-2335` already evict a live watcher whose `.last-watcher-beat` stalls past `fm_watcher_stall_bound` (`3 * FM_GUARD_GRACE`, default `900s`).
    2. On `autoarm` harnesses (`claude`, `cursor`, `agy` — `bin/fm-wake-lib.sh:300-311`), the watcher is a one-shot turn-end hook process that exits on wake and is intentionally **absent** while the supervisor is mid-turn (`bin/fm-monitor-watchdog.sh:179-185`: `if [ "$MODEL" = autoarm ] && primary_agent_busy; then exit 0; fi`). During a long supervisor turn (>2 guard cycles) or when a home is legitimately idle with zero tasks (`has_open_work` false, `bin/fm-monitor-watchdog.sh:172-177`), `.last-watcher-beat` and `state/heartbeat.json` do not advance.
- **Impact**:
  1. On any quiet home where `bin/fm-watch.sh` backs off `cur_hb` above `900s` (up to `7200s`), `state/heartbeat.json` age exceeds `watcher-stale-secs=900` (`bin/fm-watchdog.sh:371,1432`), falsely marking the heartbeat `stale` (`HB-3`) and suppressing `O_CTX` context readings (`bin/fm-watchdog.sh:371`).
  2. If `HB-7`/`HB-8` require `.last-watcher-beat` to advance every 2 guard cycles (`2 * 180s = 360s`, `bin/fm-monitor-watchdog.sh:13`) without gating on `has_open_work`, `autoarm` mid-turn state, and `fm_watcher_stall_bound` (`900s`), `bin/fm-monitor-watchdog.sh` will repeatedly kill and respawn healthy watchers or fire false pages every 6 minutes.
- **Smallest Concrete Fix**:
  1. In `HB-2`/`HB-3`, define the published `stale_after_secs` in `state/heartbeat.json` dynamically from the active cadence (`max(watcher-stale-secs, current_heartbeat_interval + poll_grace)`), or bound `FM_HEARTBEAT_MAX` below `watcher-stale-secs` when the watchdog is active.
  2. In `HB-7`/`HB-8` and `AT-HB-4`, ground the polling-progress check in the existing `state/.last-watcher-beat` beacon and `fm_watcher_stalled` (`bin/fm-wake-lib.sh:271-298`), explicitly preserving the `has_open_work` and `autoarm` `primary_agent_busy` exemptions in `bin/fm-monitor-watchdog.sh:172-186`.

---

### Finding 2 — `[BLOCKING]` `[Severity: high]`
**Title**: Duplicate ownership of "Watcher freshness" and inaccurate inventory of `bin/fm-monitor-watchdog.sh` vs https://github.com/Pibomeister/firstmate/pull/61.

- **Category**: Duplicate ownership / Failure modes
- **Evidence**:
  - `docs/prd/supervision/heartbeat-health.md:31-32` lists `bin/fm-monitor-watchdog.sh` ("Outer guard for the away daemon and the watcher") and https://github.com/Pibomeister/firstmate/pull/61 ("Home watchdog restores lost watchers and pages after two failed cycles") as two separate rows, and Gap 3 (`docs/prd/supervision/heartbeat-health.md:42`) claims: *"The outer guard proves the watcher process lives but not that the watcher still polls | A running but wedged watcher reads as healthy."*
  - In the repository (`git show --stat 94311f2d`), https://github.com/Pibomeister/firstmate/pull/61 IS the commit that added `bin/fm-monitor-watchdog.sh`. Furthermore, `bin/fm-monitor-watchdog.sh:188,196,214` calls `fm_watcher_healthy "$STATE" "$FM_HOME"`, which checks `age=$(fm_path_age "$STATE/.last-watcher-beat")` against `grace` (`FM_GUARD_GRACE=300`, `bin/fm-wake-lib.sh:262-265`), NOT just `kill -0`.
  - `docs/prd/supervision/heartbeat-health.md:67-76` ("Ownership" table) assigns:
    - `Watcher freshness` -> `bin/fm-watchdog.sh`
    - `Watcher process and polling liveness` -> `bin/fm-monitor-watchdog.sh`
  - In actual code:
    - `bin/fm-watchdog.sh:1432-1434` checks `O_HB_AGE >= watcher-stale-secs` (which is the age of `state/heartbeat.json`, written by `bin/fm-heartbeat.sh`, NOT `.last-watcher-beat`) and only writes a passive status gap (`wd_gap "watcher heartbeat is ... old"`).
    - `bin/fm-monitor-watchdog.sh:188-228` checks `state/.last-watcher-beat` via `fm_watcher_healthy` and actively restarts the watcher via `bin/fm-watch-arm.sh` and pages after 2 failed cycles (`bin/fm-monitor-watchdog.sh:146-149`).
    - `bin/fm-supervise-daemon.sh:2331-2335` ALSO checks `fm_watcher_stalled` on its child `fm-watch.sh` and kills/restarts the watcher tree.
- **Impact**: Three different scripts (`bin/fm-watchdog.sh`, `bin/fm-monitor-watchdog.sh`, `bin/fm-supervise-daemon.sh`) evaluate overlapping "watcher freshness / polling liveness" signals with three different thresholds (`watcher-stale-secs=900` on `heartbeat.json`, `FM_GUARD_GRACE=300` on `.last-watcher-beat`, and `FM_WATCHER_STALL_BOUND=900` on `.last-watcher-beat`). Stage 3 implementers reading the Ownership table (`heartbeat-health.md:67-76`) will either add a duplicate watcher-restart path into `bin/fm-watchdog.sh` or duplicate `.last-watcher-beat` checks that already exist in `bin/fm-monitor-watchdog.sh`.
- **Smallest Concrete Fix**:
  1. Collapse rows 2 and 3 of "Already in place" (`docs/prd/supervision/heartbeat-health.md:31-32`) to accurately reflect that `bin/fm-monitor-watchdog.sh` (from https://github.com/Pibomeister/firstmate/pull/61) already checks `.last-watcher-beat` age via `fm_watcher_healthy` (`bin/fm-wake-lib.sh:252-269`).
  2. Partition the Ownership table (`docs/prd/supervision/heartbeat-health.md:67-76`) by exact file artifact and action:
     - `state/heartbeat.json` snapshot publication & `stale_after_secs` field -> `bin/fm-heartbeat.sh`
     - `state/heartbeat.json` age observation for supervisor-context trust & status display (`O_HB_AGE`) -> `bin/fm-watchdog.sh` (read-only gap, never restarts watcher)
     - `state/.last-watcher-beat` polling freshness & watcher replacement -> `bin/fm-supervise-daemon.sh` (when `/afk` daemon owns the child watcher) and `bin/fm-monitor-watchdog.sh` (when `/afk` daemon is dead or absent).

---

### Finding 3 — `[BLOCKING]` `[Severity: high]`
**Title**: Token economics baseline method (`state/watchdog/model-calls.tsv`) measures only watchdog judge calls, not supervisor wake or heartbeat tokens.

- **Category**: Token economics
- **Evidence**:
  - `docs/prd/supervision/heartbeat-health.md:107-112` ("Token economics"): *"Baseline method: Count supervisor wakes and model tokens before and after this work from `state/watchdog/actions.tsv`, `state/watchdog/model-calls.tsv`, and the wake logs across a comparable work window. Compare both wake count and total tokens using the token fields in `state/watchdog/model-calls.tsv`, not wake count alone."*
  - `bin/fm-watchdog.sh:49,544,588,592` (`docs/watchdog.md:142`): `state/watchdog/model-calls.tsv` only records `claude -p` / `agy -p` cheap-model judge and council invocations executed inside `bin/fm-watchdog.sh` (`wd_judge_one`).
  - Heartbeat health checks (`bin/fm-heartbeat.sh`, `bin/fm-monitor-watchdog.sh`, and `bin/fm-watchdog.sh`'s `O_HB_AGE` check) make **zero** calls to `wd_judge_one` (`docs/prd/supervision/heartbeat-health.md:109`: *"Expected model calls per pass: 0"*).
  - Meanwhile, when a heartbeat wake or stale-watcher escalation reaches the primary or secondmate supervisor session, those LLM turns are never logged in `state/watchdog/model-calls.tsv`.
- **Impact**: `state/watchdog/model-calls.tsv` will show `0` tokens both before and after this work for heartbeat passes, making the stated baseline method incapable of measuring supervisor token spend from heartbeat/wake turns (the actual token cost driver).
- **Smallest Concrete Fix**: Measure supervisor token consumption from the supervisor session transcripts (via the JSONL usage reader in `bin/fm-heartbeat.sh:172-215` / `bin/fm-compact-point-lib.sh`) paired with `state/context-burn.tsv` (`bin/fm-context-burn.sh:9-10`, `turn_type=heartbeat|wake|startup`) and `state/.supervise-daemon.log` (`wake:` vs `escalate:` counts), reserving `state/watchdog/model-calls.tsv` strictly for out-of-session watchdog judge calls.

---

### Finding 4 — `[BLOCKING]` `[Severity: high]`
**Title**: Second-mate endpoint mismatch check (`HB-4`, `HB-5`) fails to specify precedence when a second mate's `state/heartbeat.json` is absent, stale, or written by a prior session (`hb_sid != O_SESSION`), risking false `endpoint-mismatch` reports or overwriting valid routes during restart.

- **Category**: Failure modes / Missed work
- **Evidence**:
  - `docs/prd/supervision/heartbeat-health.md:41,51-52,61` (`HB-4`, `HB-5`, `AT-HB-2`): *"A second mate whose parent `state/<id>.meta` endpoint differs from the live endpoint reports `endpoint-mismatch`"* and *"Each mismatch record names both endpoints."*
  - `bin/fm-watchdog.sh:374-388`:
    ```bash
    meta=''
    [ "$parent" = - ] || meta=$parent/state/$id.meta
    if [ -n "$meta" ] && [ -f "$meta" ] && { [ -z "$O_TARGET" ] || [ -z "$O_SESSION" ] || [ "$hb_sid" != "$O_SESSION" ]; }; then
      O_BACKEND=$(fm_backend_of_meta "$meta" 2>/dev/null)
      O_TARGET=$(fm_backend_target_of_meta "$meta" 2>/dev/null)
      cb=$O_BACKEND ct=$O_TARGET
    ```
    In `bin/fm-watchdog.sh:378-381`, whenever a second mate's own `state/heartbeat.json` has not yet been rewritten by the new session (`hb_sid != O_SESSION`) or has no `O_TARGET`, `wd_observe` **overwrites** `O_BACKEND` and `O_TARGET` from `parent/state/<id>.meta`. Conversely, when `hb_sid == O_SESSION`, `O_BACKEND`/`O_TARGET` come from the second mate's `state/heartbeat.json` (`bin/fm-watchdog.sh:355-359`) and `parent/state/<id>.meta` is not even read!
  - Furthermore, for remote second mates (`bin/fm-secondmate-restart.sh:46-51`), the parent's `state/<id>.meta` holds the primary's route metadata while the remote host's `state/heartbeat.json` holds the host-local terminal target.
- **Impact**:
  1. Because `bin/fm-watchdog.sh:378` currently only reads `parent/state/<id>.meta` when `O_TARGET` is empty or `hb_sid != O_SESSION`, `wd_observe` never compares a live second mate's `heartbeat.json` terminal (`hb_backend:hb_target`) against `parent/state/<id>.meta` (`meta_backend:meta_target`) when `hb_sid == O_SESSION`.
  2. Conversely, if a naive check compares `heartbeat.json` against `parent/state/<id>.meta` *before* verifying that `hb_sid == O_SESSION` and `hb_at >= wd_lock_at` (`bin/fm-watchdog.sh:384-385`), every newly restarted second mate (via `bin/fm-secondmate-restart.sh:57-61` on a new endpoint) will falsely report `endpoint-mismatch` until its first heartbeat runs (up to `FM_HEARTBEAT=600s` later).
  3. On a remote second mate (`placement=remote`), `heartbeat.json`'s host-local terminal and `parent/state/<id>.meta`'s route target may differ by representation if not normalized through the same helper.
- **Smallest Concrete Fix**: Specify in `HB-4`/`HB-5` that `endpoint-mismatch` is evaluated in `bin/fm-watchdog.sh` (`wd_observe`) **only** when:
  1. Both `parent/state/<id>.meta` (`meta_backend:meta_target`) and the child home's `state/heartbeat.json` (`hb_backend:hb_target`) are non-empty, AND
  2. The child's `state/heartbeat.json` is proven to belong to the child's current live lock owner (`hb_sid == O_SESSION`, `hb_at >= wd_lock_at`, and fresh within `stale_after_secs`), AND
  3. While a mismatch is present, state which endpoint `wd_observe` uses to capture the pane (`hb_backend:hb_target` proven by the child lock owner vs `meta_backend:meta_target`) so the watchdog does not go blind to the second mate's pane.

---

### Finding 5 — `[BLOCKING]` `[Severity: medium]`
**Title**: `HB-6` ("A primary whose live pane differs from `state/watchdog/captain` updates that record on the next pass") is already implemented in https://github.com/Pibomeister/firstmate/pull/158 (`bin/fm-watchdog.sh:294-337`), but fails silently when `state/heartbeat.json` is stale or `hb_wpid`/`hb_wsid` is absent on non-Claude harnesses.

- **Category**: Failure modes / Missed work
- **Evidence**:
  - `docs/prd/supervision/heartbeat-health.md:33,40,53` (`HB-6`): lists https://github.com/Pibomeister/firstmate/pull/158 under "Already in place", then lists *"The captain terminal record can drift from the live pane after a move"* as Gap 1 and `HB-6` as a new requirement.
  - Inspecting `bin/fm-watchdog.sh:384-388`:
    ```bash
    elif [ "$hb_at" -ge "$(wd_lock_at "$st")" ] \
      && { { [ -n "$hb_wpid" ] && [ "$hb_wpid" = "$O_LOCK_PID" ]; } || { [ -n "$hb_wsid" ] && [ "$hb_wsid" = "$O_SESSION" ]; }; }; then
      # Only a heartbeat written inside the lock owner names the owner's terminal.
      cb=$O_BACKEND ct=$O_TARGET
    fi
    ```
  - And in `bin/fm-heartbeat.sh:349-363,604-615`: `primary.writer.anchor_pid` (`hb_wpid`) and `primary.writer.session_id` (`hb_wsid`) are only populated when `fm-heartbeat.sh` is invoked *inside* the primary's process tree or with `FM_SESSION_ID`. When `bin/fm-heartbeat.sh` is invoked by the background watcher (`bin/fm-watch.sh:506`) or `bin/fm-supervise-daemon.sh` (which runs in a separate process tree after `bin/fm-afk-launch.sh`), `writer.anchor_pid` is the watcher/daemon's anchor (or `null`), NOT `O_LOCK_PID`!
  - When `hb_wpid != O_LOCK_PID` and `hb_wsid != O_SESSION`, `cb` and `ct` remain empty (`bin/fm-watchdog.sh:342,384-388`), so `wd_publish_captain` (`bin/fm-watchdog.sh:313-320`) keeps the old `rb:rt` from `state/watchdog/captain` instead of updating it, or writes `backend=` `target=` (empty) when the lock changes!
- **Impact**: If the primary moves panes (or after `bin/fm-afk-launch.sh` starts the daemon in its own process tree), heartbeats generated by the watcher/daemon do not satisfy `hb_wpid = O_LOCK_PID || hb_wsid = O_SESSION` unless `bin/fm-heartbeat.sh` or `wd_observe` resolves the owner's terminal from `primary.session.trusted_id == O_SESSION`. Thus `HB-6` cannot pass when heartbeats are written by the background watcher/daemon rather than a hook child of the primary.
- **Smallest Concrete Fix**: In `HB-6`, specify the exact provenance condition for `wd_publish_captain` (`bin/fm-watchdog.sh:384-388`): when `hb_at >= wd_lock_at "$st"` and `hb_sid == O_SESSION` (`primary.session.trusted_id` matches the lock's recorded session id), or when `bin/fm-watchdog.sh pickup <token>` runs in the new terminal (`bin/fm-watchdog.sh:1550-1560`), `cb`/`ct` are trusted to update `state/watchdog/captain`.

---

### Finding 6 — `[NON-BLOCKING]` `[Severity: medium]`
**Title**: Quota exhaustion and subprocess timeouts inside `bin/fm-heartbeat.sh` during `stale` classification.

- **Category**: Quota exhaustion / Failure modes
- **Evidence**:
  - `bin/fm-heartbeat.sh:686` runs `bin/fm-ready-pr-discovery.sh` synchronously during every heartbeat generation with `FM_HEARTBEAT_DISCOVERY_TIMEOUT=60` seconds.
  - If `bin/fm-ready-pr-discovery.sh` takes its full 60s timeout (for instance, under `pr-check-monitoring.md` `PM-6` forge API reads or a slow `no-mistakes` SQLite lock), `bin/fm-heartbeat.sh` is delayed by 60s before writing `state/heartbeat.json` (`bin/fm-heartbeat.sh:702-799`).
- **Smallest Concrete Fix**: Note in `heartbeat-health.md` that `stale_after_secs` must account for `FM_HEARTBEAT_DISCOVERY_TIMEOUT` (60s) so a slow discovery pass does not push a normal heartbeat across the stale boundary.

---

### Finding 7 — `[NON-BLOCKING]` `[Severity: low]`
**Title**: Safety boundary (`HB-9`) should explicitly cite `bin/fm-monitor-watchdog.sh`'s `FM_HOME` isolation and `do-not-touch` rules.

- **Category**: Safety
- **Evidence**:
  - `docs/prd/supervision/heartbeat-health.md:56` (`HB-9`): *"No check in this slice sends keys to a pane or restarts a supervisor session."*
  - While `bin/fm-watchdog.sh`'s heartbeat age check only records a gap (`bin/fm-watchdog.sh:1432-1434`), `bin/fm-monitor-watchdog.sh:164,209` restarts the away daemon (`bin/fm-afk-start.sh`) and the watcher (`bin/fm-watch-arm.sh`), and `bin/fm-supervise-daemon.sh` injects into the supervisor pane.
- **Smallest Concrete Fix**: Clarify in `HB-9` that while `bin/fm-monitor-watchdog.sh` may re-arm `bin/fm-watch-arm.sh` or `bin/fm-afk-start.sh` (`HB-8`), it never kills or restarts the supervisor agent process (`state/.lock` owner) and respects `state/.subsuper-inject-wedged` (`bin/fm-monitor-watchdog.sh:160-163`).
