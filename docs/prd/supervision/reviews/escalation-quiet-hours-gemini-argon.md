# Adversarial Review: `docs/prd/supervision/escalation-quiet-hours.md`

- **Reviewer**: Gemini Argon (`model_id=gemini-4-argon-high`, `reasoning_effort=high`, `Gemini 4 Argon (High)`, `harness=agy`)
- **Target PRD**: `docs/prd/supervision/escalation-quiet-hours.md` (branch `fm/fm-supervision-prds`, commit `8963bcedb85e8cd6c3a9d140aed32df9fe6d4dd0`, https://github.com/Pibomeister/firstmate/pull/159)
- **Verdict**: **`block`**

---

## Summary Verdict & Axis Coverage

| Review Axis | Status | Primary Finding(s) |
|---|---|---|
| Failure modes | **BLOCKING** | Findings 1, 2, 3, 4 |
| Token economics (measurable vs estimated) | **BLOCKING** | Finding 5 |
| Safety | Pass with changes | Finding 6 |
| Duplicate ownership (1 owner per signal) | **BLOCKING** | Findings 1, 3 |
| Quota exhaustion | Pass | Covered by `EQ-3` (`quota-all-at-floor`) |
| Restart loops | Pass | Covered by `EQ-3` (`restart-loop`) |
| Missed work | **BLOCKING** | Findings 2, 4 |

---

## Numbered Findings

### Finding 1 — `[BLOCKING]` `[Severity: critical]`
**Title**: `config/wedge-alarm` has no `slack` channel type (`command:<cmd>` is opaque), and direct page callers (`bin/fm-watchdog.sh` `wd_page_permission` and `bin/fm-monitor-watchdog.sh`) bypass `bin/fm-wake-lib.sh` and the away digest buffer.

- **Category**: Failure modes / Duplicate ownership
- **Evidence**:
  - `docs/prd/supervision/escalation-quiet-hours.md:50,53-57` (`EQ-5`, `EQ-8`, `EQ-10`, `EQ-14`, `EQ-15`):
    - `EQ-8`: *"Slack escalation stays off during quiet hours with no exception."*
    - `EQ-14`: *"Non-Slack local records (`data/watchdog/status.md`, `state/watchdog/actions.tsv`, and the wake queue) continue to update during quiet hours."*
    - `EQ-15`: *"Quiet hours apply to the Slack channel only unless `config/quiet-hours` names additional channels."*
  - `docs/prd/supervision/escalation-quiet-hours.md:64-72` ("Ownership" table):
    - `Quiet-hours gate` -> `bin/fm-supervise-daemon.sh`
    - `Incident dedupe` -> `bin/fm-wake-lib.sh`
    - `Digest` -> `The away and quiet supervision path`
  - Compare with the actual implementation in `docs/wedge-alarm.md:15-23`, `bin/fm-supervise-daemon.sh:1076-1107,1262-1344,2353-2361`, `bin/fm-watchdog.sh:963-991`, and `bin/fm-monitor-watchdog.sh:146-149`:
    1. **No `slack` channel directive exists in `config/wedge-alarm`**: `bin/fm-supervise-daemon.sh:1320-1330` and `docs/wedge-alarm.md:15-22` support only `off`, `auto`, `default`, `osascript`, `herdr`, `rex`, and generic `command:<cmd>`! Slack notifications are configured by the operator as a generic `command:<cmd>` line, and `bin/fm-supervise-daemon.sh:1276,1329` explicitly treats `<cmd>` as opaque/redacted (`log "wedge alarm: command channel exited $rc (command redacted)"`). Without a `slack:<cmd>` directive or channel tag in `config/wedge-alarm` / `config/quiet-hours`, `bin/fm-supervise-daemon.sh` cannot distinguish a Slack `command:` channel from a non-Slack `command:` channel (or `osascript`/`herdr`/`rex`) to enforce `EQ-15`!
    2. **Direct `page` invocations bypass `bin/fm-wake-lib.sh` and the digest buffer**:
       - `bin/fm-watchdog.sh:979-980` (`wd_page_permission`, added in https://github.com/Pibomeister/firstmate/pull/146 commit `f923d258` and https://github.com/Pibomeister/firstmate/pull/154 commit `d7723452`) and `bin/fm-monitor-watchdog.sh:148` invoke `bash bin/fm-supervise-daemon.sh page "$summary" "$marker"` directly (`bin/fm-supervise-daemon.sh:2353-2361`), which immediately calls `wedge_alarm_notify "$2" "$3" strict` without consulting `bin/fm-wake-lib.sh` or any durable digest buffer!
       - If `wedge_alarm_notify` suppresses Slack during quiet hours and returns `0` (`sent` on `osascript`) or `2` (`off`), `wd_page_permission` (`bin/fm-watchdog.sh:983`) marks the ledger row `done` (`owner paged`) or `refused`—and if the held Slack message is not written to a durable quiet-hours queue by `wedge_alarm_notify` itself, the permission page is **lost** from the 08:00 Slack digest (`EQ-11`)!
- **Impact**:
  1. `EQ-15` ("Quiet hours apply to the Slack channel only") cannot be implemented on the existing `config/wedge-alarm` schema (`off|auto|osascript|herdr|rex|command:<cmd>`) without either suppressing *all* `command:` channels or adding a named `slack:<cmd>` / `channel-name` syntax.
  2. Assigning `Incident dedupe` to `bin/fm-wake-lib.sh` (`escalation-quiet-hours.md:69`) misses `bin/fm-watchdog.sh` (`wd_page_permission` uses `fm_wd_rate_ok` on `state/watchdog/actions.tsv` at `bin/fm-watchdog.sh:967`) and `bin/fm-monitor-watchdog.sh:146-149` (which uses `state/.monitor-watchdog-failures`), neither of which calls `bin/fm-wake-lib.sh` for incident deduplication!
- **Smallest Concrete Fix**:
  1. Specify the exact channel identification syntax in `config/wedge-alarm` and `config/quiet-hours` (e.g., `slack:<cmd>` or `command[slack]:<cmd>`, or default `channels=command` in `config/quiet-hours`).
  2. Place both the **quiet-hours hold queue** (`state/.quiet-hours-held` or `state/quiet-hours/`) and **outbound page incident dedupe** inside `wedge_alarm_notify` / `bin/fm-supervise-daemon.sh` (`page` entrypoint + `inject_wedge_alarm`), which is the single chokepoint through which `bin/fm-supervise-daemon.sh`, `bin/fm-watchdog.sh` (`wd_page_permission`), and `bin/fm-monitor-watchdog.sh` all send external alerts.

---

### Finding 2 — `[BLOCKING]` `[Severity: high]`
**Title**: Held quiet-hours messages (`EQ-10`, `EQ-11`, `EQ-12`) have no process to flush the 08:00 digest when the home is not running `bin/fm-supervise-daemon.sh` at 08:00 (or when the captain returns before 08:00).

- **Category**: Missed work / Failure modes
- **Evidence**:
  - `docs/prd/supervision/escalation-quiet-hours.md:54-56,70` (`EQ-10`, `EQ-11`, `EQ-12`, Ownership table):
    - `EQ-10`: *"Messages held during quiet hours queue for the next digest."*
    - `EQ-11`: *"One digest sends at the end of quiet hours (`08:00` in the configured timezone) when the queue is non-empty."*
    - `EQ-12`: *"An empty queue at `08:00` sends nothing."*
    - Ownership table (`line 70`): assigns `Digest` to *"The away and quiet supervision path"*.
  - Compare with how `bin/fm-supervise-daemon.sh` runs in the codebase (`bin/fm-supervise-daemon.sh:19-26,2268-2349` and `bin/fm-monitor-watchdog.sh:172-186`):
    1. `bin/fm-supervise-daemon.sh` runs **only** while `state/.afk` exists (`/afk` or `/quiet` posture). If the user exited `/afk` before 08:00, or if a `page` was held during quiet hours on a home where `state/.afk` was cleared (or on a home monitored by `bin/fm-watchdog.sh` / `bin/fm-monitor-watchdog.sh`), `bin/fm-supervise-daemon.sh` is **not running at 08:00**!
    2. Even when `state/.afk` *is* active at 08:00, `housekeeping` (`bin/fm-supervise-daemon.sh:1423-1642`) has no quiet-hours end check; and if `bin/fm-supervise-daemon.sh` is shut down on `/afk` return (`bin/fm-afk-return.sh`), any held Slack messages sitting in a quiet-hours queue would be stranded unless flushed or cleared on return.
- **Impact**: Held quiet-hours alerts queued overnight or over a weekend (`EQ-9`) will never be sent at `08:00` if `bin/fm-supervise-daemon.sh` is not running at `08:00`, or will fire stale alerts at `08:00` Monday for incidents the user already resolved interactively on Sunday.
- **Smallest Concrete Fix**:
  1. Have **both** `bin/fm-supervise-daemon.sh` (`housekeeping` tick) **and** `bin/fm-monitor-watchdog.sh` / `bin/fm-watchdog.sh` check the durable quiet-hours hold queue once quiet hours end (`>= 08:00` on a non-weekend day in the configured `TZ`) and flush the single digest under an atomic lock.
  2. When the user exits `/afk` / `/quiet` (`bin/fm-afk-return.sh`) or resolves an incident before `08:00`, clear or reconcile the held Slack queue so resolved incidents are not paged at `08:00` (`EQ-4`).

---

### Finding 3 — `[BLOCKING]` `[Severity: high]`
**Title**: Quiet-mode alert throttling in `bin/fm-supervise-daemon.sh` is currently in-memory only (`WEDGE_ALARM_LAST_EPOCH`), violating `EQ-7` ("The dedupe record survives a supervisor restart").

- **Category**: Failure modes / Duplicate ownership
- **Evidence**:
  - `docs/prd/supervision/escalation-quiet-hours.md:51-52` (`EQ-6`, `EQ-7`):
    - `EQ-6`: *"One incident key produces one escalation until the incident resolves or its state changes."*
    - `EQ-7`: *"The dedupe record survives a supervisor restart."*
  - Inspecting `docs/wedge-alarm.md:7` and `bin/fm-supervise-daemon.sh:70-71,255,1364,1448-1453`:
    - `docs/wedge-alarm.md:7`: *"In quiet mode (`/quiet`), the daemon never retries composer delivery; past `FM_MAX_DEFER_SECS` it emits only a summary alert (`quiet supervision retained escalations <N>s - run bin/fm-afk-return.sh`), throttled in memory to once per max-defer window, with no durable marker."*
    - `bin/fm-supervise-daemon.sh:255,1448`: `WEDGE_ALARM_LAST_EPOCH=0` is an in-memory bash global variable! Whenever `bin/fm-supervise-daemon.sh` restarts (e.g., via `bin/fm-monitor-watchdog.sh:164`), `WEDGE_ALARM_LAST_EPOCH` resets to `0` and re-fires the alert immediately.
    - Furthermore, `EQ-6` requires deduplication per `(home, subject, symptom, target_state)` incident key until resolution or state change (`EQ-4`), whereas `bin/fm-watchdog.sh:967` (`wd_page_permission`) and `bin/fm-supervise-daemon.sh:1360,1448` currently rate-limit by time window (`nudge-secs=900` or `FM_MAX_DEFER_SECS=300`), meaning an unresolved permission dialog or wedge re-pages every 5–15 minutes indefinitely!
- **Impact**:
  1. Time-window throttling (`nudge-secs=900` in `bin/fm-watchdog.sh:967` and `max_defer=300` in `bin/fm-supervise-daemon.sh:1360`) violates `EQ-2` and `EQ-6` (*"One incident key produces one escalation until the incident resolves or its state changes"*), paging the operator repeatedly for the same unchanged incident.
  2. In-memory `WEDGE_ALARM_LAST_EPOCH` (`bin/fm-supervise-daemon.sh:255,1448`) violates `EQ-7` across daemon restarts.
- **Smallest Concrete Fix**: Replace time-window repeat paging (`WEDGE_ALARM_LAST_EPOCH` and `nudge-secs` repeat pages on unchanged dialog text) with a durable incident-key ledger under `state/` (e.g., `state/escalated-incidents.tsv` keyed by `home\tsubject\tsymptom\ttarget_state_hash`) that persists across supervisor and daemon restarts (`EQ-7`) and suppresses repeat outbound pages until the incident key clears or its `target_state` changes (`EQ-4`, `EQ-6`).

---

### Finding 4 — `[BLOCKING]` `[Severity: medium]`
**Title**: `EQ-3` defines six allowed outbound exception classes (`permission-dialog`, `unconfirmed-restart`, `restart-loop`, `quota-all-at-floor`, `conflicted-pr`, `blocked-decision`), but four of those six are not currently wired to any outbound alert/page path in `bin/fm-watchdog.sh` or `bin/fm-supervise-daemon.sh`.

- **Category**: Missed work / Failure modes
- **Evidence**:
  - `docs/prd/supervision/escalation-quiet-hours.md:46-48` (`EQ-1`, `EQ-2`, `EQ-3`):
    - `EQ-3`: *"The exception classes are: `permission-dialog`, `unconfirmed-restart`, `restart-loop`, `quota-all-at-floor`, `conflicted-pr`, and `blocked-decision`."*
  - Compare with what actually calls `fm-supervise-daemon.sh page` or `wedge_alarm_notify` in the repository today:
    1. `permission-dialog`: calls `fm-supervise-daemon.sh page` in `bin/fm-watchdog.sh:980` (`wd_page_permission`).
    2. `unconfirmed-restart`: calls `wd_self_heal` (files a GitHub issue via `bin/fm-self-heal-issue.sh`, `bin/fm-watchdog.sh:872`), **never** calls `fm-supervise-daemon.sh page`!
    3. `restart-loop`: calls `wd_self_heal` (`bin/fm-watchdog.sh:709`), **never** calls `fm-supervise-daemon.sh page`!
    4. `quota-all-at-floor`: writes `wd_gap` (`bin/fm-watchdog.sh:1161`) or `wd_nudge` into the supervisor pane (`bin/fm-watchdog.sh:1181`), **never** calls `fm-supervise-daemon.sh page`!
    5. `conflicted-pr`: not wired to `page` anywhere.
    6. `blocked-decision`: writes `wd_gap` / `wd_nudge` (`bin/fm-watchdog.sh:1017,1022,1038`), **never** calls `fm-supervise-daemon.sh page`!
    7. Conversely, `bin/fm-monitor-watchdog.sh:148` (watcher recovery failure after 2 cycles) and `bin/fm-supervise-daemon.sh:1391,1451` (`inject_wedge_alarm`) DO call `wedge_alarm_notify`, yet neither `watcher-recovery-failed` nor `inject-wedged` is listed in `EQ-3`!
- **Impact**:
  1. If `EQ-1` ("Only exceptions escalate") and `EQ-3` are enforced literally on outbound pages (`wedge_alarm_notify`), `inject-wedged` (`bin/fm-supervise-daemon.sh:1391`) and `watcher-recovery-failed` (`bin/fm-monitor-watchdog.sh:148`) would be suppressed because they are missing from `EQ-3`!
  2. Conversely, if `EQ-3` is meant to govern which wakes `bin/fm-supervise-daemon.sh` injects into the supervisor pane, `EQ-3` omits `done` / ready-PR completion wakes and `check:` wakes (`bin/fm-classify-lib.sh`).
- **Smallest Concrete Fix**: Clarify whether `EQ-1`–`EQ-3` govern **outbound operator pages** (`wedge_alarm_notify` / Slack) or **supervisor pane injections** (`escalate_flush`):
  - For outbound operator pages, include `inject-wedged` and `watcher-recovery-failed` in `EQ-3`, and wire `unconfirmed-restart`, `restart-loop`, `quota-all-at-floor`, `conflicted-pr`, and `blocked-decision` (held for owner) to the shared outbound page/digest helper.

---

### Finding 5 — `[BLOCKING]` `[Severity: high]`
**Title**: Token economics section (`docs/prd/supervision/escalation-quiet-hours.md:94-97`) omits a baseline measurement method entirely, and any supervisor wake-token reduction must be measured from session transcripts rather than `state/watchdog/model-calls.tsv`.

- **Category**: Token economics
- **Evidence**:
  - `docs/prd/supervision/escalation-quiet-hours.md:94-97` ("Token economics"):
    - *"Expected model calls per pass: 0."*
    - *"Worst-case daily cap: $0 from this slice."*
    - *"Rule: Dedupe, quiet-hours gating, and digest assembly are deterministic file checks."*
  - Unlike the other four PRDs, `escalation-quiet-hours.md:94-97` omits the `Baseline method:` paragraph entirely. Furthermore, if incident deduplication (`EQ-6`) applies to supervisor wakes (`bin/fm-wake-lib.sh`), its token impact is on supervisor session wake turns (`state/context-burn.tsv` and session transcript token usage), whereas if it applies to outbound Slack pages (`wedge_alarm_notify`), its impact is on page count (`state/.monitor-watchdog-page.log` and `state/watchdog/actions.tsv` `page` rows).
- **Smallest Concrete Fix**: Add a concrete, measurable `Baseline method:` to `docs/prd/supervision/escalation-quiet-hours.md:94-97` that counts outbound pages (`state/watchdog/actions.tsv` `action == "page"` + `state/.monitor-watchdog-page.log`) and supervisor wake turns/tokens (`state/.supervise-daemon.log` `escalate:` lines + session transcript token usage via `bin/fm-heartbeat.sh:172-215`) before and after this slice.

---

### Finding 6 — `[NON-BLOCKING]` `[Severity: low]`
**Title**: Portable timezone calculation for `08:00`–`22:00` and weekend quiet hours (`EQ-8`, `EQ-9`, `EQ-13`) on macOS (`BSD date`) vs Linux (`GNU date`).

- **Category**: Safety / Failure modes
- **Evidence**:
  - `docs/prd/supervision/escalation-quiet-hours.md:53,57` (`EQ-8`, `EQ-9`, `EQ-13`): *"Quiet hours default to `22:00`–`08:00` local time and all day Saturday and Sunday"* and *"The timezone comes from `config/quiet-hours` or the host local timezone when unset."*
  - On macOS (`Darwin`), `TZ=<zone> date +%H:%u` works cleanly for evaluating current hour (`00`..`23`) and ISO weekday (`1`..`7`, where `6` and `7` are Saturday/Sunday), whereas `date -d` (GNU) is unavailable.
- **Smallest Concrete Fix**: Note in `escalation-quiet-hours.md` that quiet-hours window evaluation must use portable `TZ="$tz" date '+%H %M %u'` (with `FM_QUIET_HOURS_NOW` epoch override via `date -r "$now"` on Darwin / `date -d "@$now"` on Linux) so `AT-EQ-2` and `AT-EQ-3` pass on both macOS and Linux without GNU `date` dependencies.
