# Adversarial Review: `docs/prd/supervision/quota-account-routing.md`

- **Reviewer**: Gemini Argon (`model_id=gemini-4-argon-high`, `reasoning_effort=high`, `Gemini 4 Argon (High)`, `harness=agy`)
- **Target PRD**: `docs/prd/supervision/quota-account-routing.md` (branch `fm/fm-supervision-prds`, commit `8963bcedb85e8cd6c3a9d140aed32df9fe6d4dd0`, https://github.com/Pibomeister/firstmate/pull/159)
- **Verdict**: **`block`**

---

## Summary Verdict & Axis Coverage

| Review Axis | Status | Primary Finding(s) |
|---|---|---|
| Failure modes | **BLOCKING** | Findings 1, 2, 3 |
| Token economics (measurable vs estimated) | **BLOCKING** | Finding 5 |
| Safety | **BLOCKING** | Finding 2 |
| Duplicate ownership (1 owner per signal) | **BLOCKING** | Finding 4 |
| Quota exhaustion | **BLOCKING** | Findings 1, 3 |
| Restart loops | **BLOCKING** | Finding 1 |
| Missed work | **BLOCKING** | Findings 2, 3, 4 |

---

## Numbered Findings

### Finding 1 — `[BLOCKING]` `[Severity: critical]`
**Title**: `QA-4` ("A candidate with unmeasured headroom stays eligible") directly contradicts `bin/fm-quota-choose.sh` (`status == "unknown" -> false`) and would cause blind relaunch loops onto exhausted/unmeasured accounts during unattended quota recovery.

- **Category**: Quota exhaustion / Restart loops / Failure modes
- **Evidence**:
  - `docs/prd/supervision/quota-account-routing.md:38` (Gap 2): *"Missing quota evidence keeps a candidate eligible by design | A move can land on an account whose headroom is unmeasured."*
  - `docs/prd/supervision/quota-account-routing.md:48` (`QA-4`): *"A candidate with unmeasured headroom stays eligible and the record marks the headroom unmeasured."*
  - `docs/prd/supervision/quota-account-routing.md:74-80` ("Ownership" table): assigns `Candidate order` to `bin/fm-quota-choose.sh` and `Quota snapshot and pick` to `bin/fm-quota-reroute.sh`.
  - Compare with the actual implementation in `bin/fm-quota-choose.sh` (added in https://github.com/Pibomeister/firstmate/pull/140 commit `bcb76a86`) and `bin/fm-quota-reroute.sh` (added in https://github.com/Pibomeister/firstmate/pull/142 commit `20092e86`):
    - `bin/fm-quota-choose.sh:13-15`: *"Eligibility requires status != exhausted, status != unknown, and a numeric effectivePercentRemaining > 0."*
    - `bin/fm-quota-choose.sh:49-52`: *"Note on omp: the live omp binary has models for anthropic, google-antigravity, and openai-codex. On this machine only openai-codex is configured (`~/.omp/agent/agent.db`), and `quota-axi` has no omp window, so `omp:*` is `unknown` and therefore not eligible for automatic quota moves."*
    - `bin/fm-quota-choose.sh:385-395`:
      ```jq
      def eligible:
        if .status == "exhausted" then false
        elif .status == "unknown" then false
        elif (.effectivePercentRemaining | type) != "number" then false
        elif .effectivePercentRemaining <= 0 then false
        else true
        end;
      ```
  - The PRD conflates two distinct rules:
    1. **New-work intake dispatch** (`AGENTS.md` section 4 / `.agents/skills/quota-array-dispatch/SKILL.md`), where unmeasured headroom keeps a candidate eligible for initial spawn with disclosed uncertainty; vs.
    2. **Unattended mid-task quota reroute** (`bin/fm-quota-choose.sh` + `bin/fm-quota-reroute.sh`), which moves an *already running task that just hit a quota wall* to another runtime/account, and therefore **must** require positive proof of remaining quota (`status != "unknown"` and `effectivePercentRemaining > 0`)!
- **Impact**: If Stage 3 changes `bin/fm-quota-choose.sh` or `bin/fm-quota-reroute.sh` to satisfy `QA-4` by making `status == "unknown"` eligible for automatic quota moves:
  1. Every existing unit test for `fm-quota-choose.sh` (`AT-QA-8`: `bash -n bin/fm-quota-choose.sh && tests/fm-quota-choose.test.sh`) will break because `omp` and unmeasured accounts are explicitly tested as ineligible (`status == "unknown"`).
  2. When a worker hits a quota floor, `bin/fm-quota-reroute.sh` will suggest an unmeasured candidate (such as `omp` or an account whose `quota-axi` probe failed/timed out). If that candidate is also exhausted or unconfigured, the relaunched worker will immediately hit a quota wall again and bounce back and forth in an unattended relaunch loop!
- **Smallest Concrete Fix**:
  1. Correct Gap 2 (`docs/prd/supervision/quota-account-routing.md:38`) and `QA-4` (`line 48`) to match `bin/fm-quota-choose.sh:13-15,385-395`: for **mid-task quota reroute** (`bin/fm-quota-choose.sh` / `bin/fm-quota-reroute.sh`), a candidate with `status == "unknown"` or non-numeric `effectivePercentRemaining` is **ineligible** (requires positive headroom `> 0`), whereas for **initial new-task intake** (`quota-array-dispatch`), unmeasured headroom stays eligible with disclosed uncertainty.

---

### Finding 2 — `[BLOCKING]` `[Severity: critical]`
**Title**: `QA-8` ("A pane-text usage-limit picker and a status-line floor follow one stated path per harness") contradicts the hard safety refusal in `bin/fm-control.sh:937-949` and `bin/fm-watchdog.sh:1137-1157` (https://github.com/Pibomeister/firstmate/pull/144).

- **Category**: Safety / Failure modes / Missed work
- **Evidence**:
  - `docs/prd/supervision/quota-account-routing.md:39` (Gap 3): *"Pane-text usage-limit pickers and status-line floors take different paths | Recovery behavior depends on how the harness renders the limit."*
  - `docs/prd/supervision/quota-account-routing.md:52` (`QA-8`): *"A pane-text usage-limit picker and a status-line floor follow one stated path per harness."*
  - Compare with `bin/fm-control.sh:29-31,43-45,106-109,937-949` and `bin/fm-watchdog.sh:1137-1157` (merged in https://github.com/Pibomeister/firstmate/pull/144 commit `187a6ddf`):
    - `bin/fm-control.sh:29-31`: *"A task whose pane shows an interactive usage-limit menu cannot take `/exit` in its composer: `/exit` lands in the menu, not a shell. Only the Grok weekly-limit choice composer has a live-verified close path (killing the endpoint and rebinding the task record to a fresh one)."*
    - `bin/fm-control.sh:937-945`:
      ```bash
      dialog=$(relaunch_pane_dialog)
      case "$dialog" in
        'Grok weekly-limit choice')
          relaunch_needs_fresh_endpoint=1 ;;
        *usage-limit*)
          die "task $ID is at a usage-limit screen that is not live-verified; refusing to close the endpoint or type Enter. Queue until reset." ;;
      esac
      ```
    - `bin/fm-watchdog.sh:1151-1157`:
      ```bash
      if wd_quota_relaunch_closes; then
        wd_rec "$1" quota suggest held "quota shows $pick eligible; supervisor relaunches, watchdog does not"
      else
        wd_rec "$1" quota suggest held "quota shows $pick eligible; queued until reset"
        wd_gap "usage-limit on $2. Suggested pick: $pick. Queue until reset. Relaunch closes only a verified Grok weekly-limit composer. The watchdog does not change the runtime."
      fi
      ```
- **Impact**: A status-line quota floor (where the worker appended `paused: quota ...` or `blocked: quota ...` to `state/<task>.status` and sits at an idle agent composer) can be cleanly stopped with `/exit` (`bin/fm-control.sh`), whereas a pane-text usage-limit modal picker on Claude (`Claude usage-limit choice`) or Codex (`Codex usage-limit choice`) traps keystrokes inside the modal menu—where typing `/exit` + `Enter` can select a menu option (including a paid overage / extra-usage purchase option, violating the hard no-spend boundary in `docs/watchdog.md:59,119`!). Unifying them into one path (`QA-8`) without live-verifying endpoint-kill + fresh-endpoint rebind for each harness's modal usage-limit picker either hits `die` in `bin/fm-control.sh:943` or risks confirming a paid usage-limit prompt.
- **Smallest Concrete Fix**: Rewrite `QA-8` and `AT-QA-3` so that:
  1. For a **status-line floor** (composer idle, no blocking usage-limit modal), `bin/fm-control.sh <id> relaunch` uses the standard graceful agent stop + relaunch path.
  2. For a **pane-text usage-limit modal picker**, `bin/fm-control.sh <id> relaunch` NEVER types `/exit` or `Enter` into the pane; it either uses the live-verified endpoint-kill + fresh-endpoint rebind path (`relaunch_needs_fresh_endpoint=1` in `bin/fm-control.sh:940`, once live-verified per harness) or fails closed to `queued until reset` (`bin/fm-control.sh:943`).

---

### Finding 3 — `[BLOCKING]` `[Severity: high]`
**Title**: `QA-10` ("When every candidate is at floor, the task queues until the earliest reset time") has no wake or timer mechanism to resume the task when `resetAt` arrives.

- **Category**: Missed work / Quota exhaustion / Failure modes
- **Evidence**:
  - `docs/prd/supervision/quota-account-routing.md:54,61` (`QA-10`, `AT-QA-4`): *"When every candidate is at floor, the task queues until the earliest reset time and no poll loop runs."*
  - Inspecting `bin/fm-watchdog.sh:1158-1183`:
    - When `wd_quota_pick` returns `none`, `wd_handle_quota` (`bin/fm-watchdog.sh:1181`) nudges the supervisor: `"task $task is parked at a quota floor. $(wd_quota_none_reason). Queue until reset; never pause or poll for quota."`
    - Neither `bin/fm-quota-choose.sh` (`lines 385-401`) nor `bin/fm-quota-reroute.sh` (`lines 515-559`) extracts or prints the earliest `resetAt` / `resetsAt` timestamp from the `quota-axi` snapshot when all candidates are exhausted! Instead, `bin/fm-quota-reroute.sh:558` simply prints `"error: no eligible reroute candidate in the quota-axi snapshot"` and exits `1`.
    - Furthermore, once a worker is queued/parked on a pane-text usage-limit screen (`O_DIALOG=usage-limit`), `wd_visit_worker_dialogs` (`bin/fm-watchdog.sh:1363-1370`) calls `wd_quota_name_pick_rated`, which only writes a passive gap in `data/watchdog/status.md` (`wd_gap`, `bin/fm-watchdog.sh:1153-1161`) and **never nudges the supervisor** (`wd_handle_quota` at `bin/fm-watchdog.sh:1173-1184` only scans `state/*.status` via `wd_quota_floors`, NOT panes stuck at `O_DIALOG=usage-limit` where the worker could not append to its `.status` file because the usage-limit dialog interrupted its turn!).
- **Impact**:
  1. A worker that hits an interactive usage-limit dialog mid-turn never appends a `quota` line to `state/<task>.status` (because the CLI blocked at the usage-limit screen before the agent could run a bash tool to write `.status`). `wd_handle_quota` (`bin/fm-watchdog.sh:218-228,1173-1184`) only checks `state/*.status`, so the supervisor is **never nudged** about a worker stuck at a usage-limit dialog!
  2. When all candidates are exhausted, `bin/fm-quota-reroute.sh` does not report the earliest `resetAt` timestamp from `quota-axi`, so the supervisor cannot even set a `paused [at=<epoch>]: quota floor until <YYYY-MM-DDTHH:MMZ>` recheck bound.
- **Smallest Concrete Fix**:
  1. Require `bin/fm-quota-choose.sh` / `bin/fm-quota-reroute.sh` to emit the earliest candidate `resetAt` ISO timestamp in its `none` diagnostic when all candidates are exhausted (`QA-10`).
  2. Require `bin/fm-watchdog.sh` (`wd_visit_worker_dialogs` at `bin/fm-watchdog.sh:1363-1370`) to also trigger a rate-limited supervisor nudge (not just a passive `wd_gap` line in `data/watchdog/status.md`) when a worker pane is stuck at `O_DIALOG=usage-limit`, or record a `paused ... until <resetAt>` wait so housekeeping's `pause` resurface (`bin/fm-supervise-daemon.sh:1554-1561`) wakes the supervisor after reset without a poll loop.

---

### Finding 4 — `[BLOCKING]` `[Severity: high]`
**Title**: Duplicate / split quota routing logic between `quota-array-dispatch` (`bin/fm-dispatch-resolve.sh`) and `bin/fm-quota-choose.sh` / `bin/fm-quota-reroute.sh`.

- **Category**: Duplicate ownership / Failure modes
- **Evidence**:
  - `docs/prd/supervision/quota-account-routing.md:37` (Gap 1): *"Quota array dispatch lives in skill prose as well as helper scripts | The agent still interprets candidate tables by hand on some paths."*
  - `docs/prd/supervision/quota-account-routing.md:45-47,74-80` (`QA-1`, `QA-2`, `QA-3`, Ownership table): lists `bin/fm-quota-choose.sh` as owner of `Candidate order` and `bin/fm-quota-reroute.sh` as owner of `Quota snapshot and pick`, while omitting `bin/fm-dispatch-resolve.sh` (`AGENTS.md` section 4) and `config/crew-dispatch` (`docs/configuration.md`).
  - In the codebase:
    - `bin/fm-quota-choose.sh:220-231` hardcodes its own catalog of harness/provider/tier rules in `jq` (`claude`, `codex`, `agy`, `cursor`, `grok`, `kimi`, `opencode`, `pi`, `pi-signed`, `omp`) and ranks by `tier -> spendPriority -> effectivePercentRemaining -> paceDeltaPercent -> resetAt` (`bin/fm-quota-choose.sh:15-17`).
    - Meanwhile, `config/crew-dispatch` profiles and `.agents/skills/quota-array-dispatch/SKILL.md` use profile names, `floor` hints, `approval: "captain"` gates, and reasoning-class pools (`AGENTS.md` section 4) that `bin/fm-quota-reroute.sh` (`config/watchdog` `reroute-candidates`, `bin/fm-watchdog.sh:1069`) does not read at all!
- **Impact**: `bin/fm-quota-reroute.sh` reads `reroute-candidates` from `config/watchdog` (`bin/fm-watchdog.sh:1069`) rather than `config/crew-dispatch`, so it can suggest a candidate that violates a task's `config/crew-dispatch` rule or `approval: "captain"` gate, creating two competing owners for candidate eligibility and ranking.
- **Smallest Concrete Fix**: State explicitly in the Ownership table (`docs/prd/supervision/quota-account-routing.md:74-80`) and `QA-1`–`QA-3` how `config/crew-dispatch` (`bin/fm-dispatch-resolve.sh`) and `bin/fm-quota-reroute.sh` / `bin/fm-quota-choose.sh` relate: either `bin/fm-quota-reroute.sh` resolves its candidate pool from `config/crew-dispatch` (falling back to `config/watchdog`'s `reroute-candidates`) while honoring `approval: "captain"`, or `bin/fm-quota-choose.sh` is the single shared ranking engine invoked by both initial intake and mid-task reroute.

---

### Finding 5 — `[BLOCKING]` `[Severity: high]`
**Title**: Token economics baseline method (`state/watchdog/model-calls.tsv`) cannot measure token savings from deterministic quota routing.

- **Category**: Token economics
- **Evidence**:
  - `docs/prd/supervision/quota-account-routing.md:99-103` ("Token economics"): *"Baseline method: Count supervisor wakes and model tokens before and after this work from `state/watchdog/actions.tsv`, `state/watchdog/model-calls.tsv`, and the wake logs across a comparable work window. Compare both wake count and total tokens using the token fields in `state/watchdog/model-calls.tsv`, not wake count alone."*
  - The token savings of `bin/fm-quota-choose.sh` and `bin/fm-quota-reroute.sh` come from **eliminating multi-thousand-token supervisor LLM turns** where firstmate manually runs `quota-axi` and reasons through `.agents/skills/quota-array-dispatch/SKILL.md` in its own conversation transcript (`Gap 1`, `docs/prd/supervision/quota-account-routing.md:37`).
  - Those supervisor LLM tokens are recorded in the supervisor's session transcript (`bin/fm-heartbeat.sh:172-215`), **never** in `state/watchdog/model-calls.tsv` (which only logs `bin/fm-watchdog.sh` `wd_judge_one` calls, where `quota-account-routing` makes `0` calls unless a `model-switch` dialog triggers `wd_judge dialog` at `bin/fm-watchdog.sh:938`).
- **Impact**: Using `state/watchdog/model-calls.tsv` as the token-measurement source misses 100% of the supervisor dispatch/reroute reasoning tokens this PRD aims to offload.
- **Smallest Concrete Fix**: Specify that the baseline and post-change token measurement reads supervisor turn token usage from the primary/secondmate session transcripts around `fm-spawn.sh` / `fm-control.sh relaunch` turns (plus `state/watchdog/model-calls.tsv` for `dialog` judge calls).
