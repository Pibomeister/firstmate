# Adversarial Review: `docs/prd/supervision/pr-check-monitoring.md`

- **Reviewer**: Gemini Argon (`model_id=gemini-4-argon-high`, `reasoning_effort=high`, `Gemini 4 Argon (High)`, `harness=agy`)
- **Target PRD**: `docs/prd/supervision/pr-check-monitoring.md` (branch `fm/fm-supervision-prds`, commit `8963bcedb85e8cd6c3a9d140aed32df9fe6d4dd0`, https://github.com/Pibomeister/firstmate/pull/159)
- **Verdict**: **`block`**

---

## Summary Verdict & Axis Coverage

| Review Axis | Status | Primary Finding(s) |
|---|---|---|
| Failure modes | **BLOCKING** | Findings 1, 2, 3, 5 |
| Token economics (measurable vs estimated) | **BLOCKING** | Finding 4 |
| Safety | Pass with changes | Finding 6 |
| Duplicate ownership (1 owner per signal) | **BLOCKING** | Finding 3 |
| Quota exhaustion (Forge API rate limits) | **BLOCKING** | Finding 1 |
| Restart loops | **BLOCKING** | Finding 2 |
| Missed work | **BLOCKING** | Findings 1, 2, 5 |

---

## Numbered Findings

### Finding 1 — `[BLOCKING]` `[Severity: critical]`
**Title**: Per-heartbeat live forge reads for conflict state (`PM-6`) in `bin/fm-ready-pr-discovery.sh` risk exhausting `FM_HEARTBEAT_DISCOVERY_TIMEOUT=60s` and forge API rate limits, blinding all ready-PR discovery on timeout.

- **Category**: Quota exhaustion (Forge API & timeout budget) / Failure modes / Missed work
- **Evidence**:
  - `docs/prd/supervision/pr-check-monitoring.md:36` (Gap 1): *"Ready-PR discovery does not report merge conflicts | A conflicted PR can look ready until merge time."*
  - `docs/prd/supervision/pr-check-monitoring.md:47-49` (`PM-6`, `PM-7`, `PM-8`):
    - `PM-6`: *"Discovery reports the conflict state of each ready PR from the forge read."*
    - `PM-7`: *"A conflicted PR is excluded from the ready-to-merge list and reported as `conflicted`."*
    - `PM-8`: *"An unreadable conflict state reports `unknown` and is not reported as `clean`."*
  - Compare with `bin/fm-ready-pr-discovery.sh:1-90` and `bin/fm-heartbeat.sh:683-700`:
    - Today, `bin/fm-ready-pr-discovery.sh` performs **zero network/forge API calls**: it queries local `no-mistakes` SQLite state (`state_db_live_rows`, `sibling_live_rows` in `bin/fm-ready-pr-discovery.sh:19-20,180-320`) across every registered project and every sibling checkout.
    - `bin/fm-heartbeat.sh:686-699` runs `bin/fm-ready-pr-discovery.sh` under a hard `FM_HEARTBEAT_DISCOVERY_TIMEOUT=60` second budget (`FM_READY_PR_TIMEOUT=55` inside `bin/fm-ready-pr-discovery.sh:34`). If `bin/fm-ready-pr-discovery.sh` exits non-zero or times out, `bin/fm-heartbeat.sh:695-699` replaces the **entire** `ready_pr_discovery` payload with:
      ```json
      {"unknown":true,"reason":"ready-pr discovery unreadable"}
      ```
    - Adding a live forge CLI network call (`gh-axi` / `glab` / `tea` per `bin/fm-pr-merge.sh:21-30`) per ready/parked PR inside `bin/fm-ready-pr-discovery.sh` on every heartbeat (across primaries and secondmates sharing the same `gh` token and `55s` timeout) has no caching by `(repo, pr_number, head_sha, base_ref_oid)` and no per-PR network timeout budget.
- **Impact**:
  1. When multiple PRs are parked across projects (or when GitHub/GitLab API latency spikes), serial forge CLI reads inside `bin/fm-ready-pr-discovery.sh` will exceed the `55s` timeout, causing `bin/fm-heartbeat.sh:695` to mark the **entire** `ready_pr_discovery` object `unknown: true` and hiding *all* ready PRs (missed work).
  2. Multiple homes (primary + secondmates) polling forge conflict state on every heartbeat will burn GitHub REST/GraphQL rate limits unnecessarily when neither the PR's `headRefOid` nor the target branch's `baseRefOid` has changed.
- **Smallest Concrete Fix**:
  1. Cache the forge conflict verdict under `state/` keyed by `(repo, pr_url, head_sha, base_sha)` (or TTL with ETag/base-ref check) so `bin/fm-ready-pr-discovery.sh` only queries the forge when a PR first enters `ready` or its `head_sha` / target branch head changes.
  2. Enforce a strict per-PR forge read timeout (e.g., `5s` via `fm_run_timed`) inside `bin/fm-ready-pr-discovery.sh` so one slow forge response marks only that single PR's conflict state `unknown` (`PM-8`) instead of timing out the entire `55s` `fm-ready-pr-discovery.sh` pass.

---

### Finding 2 — `[BLOCKING]` `[Severity: high]`
**Title**: GitHub's asynchronous `mergeable: UNKNOWN` state after a base-branch push is conflated with forge read failure (`PM-6`, `PM-7`, `PM-8`), causing transient `UNKNOWN` states to either drop ready PRs or churn wakes.

- **Category**: Failure modes / Restart loops / Missed work
- **Evidence**:
  - `docs/prd/supervision/pr-check-monitoring.md:47-49` (`PM-6`, `PM-7`, `PM-8`): defines three states: `conflicted`, `clean`, and `unknown` (*"An unreadable conflict state reports `unknown` and is not reported as `clean`"*).
  - Inspecting `bin/fm-pr-merge.sh:26-30,205-245`:
    - *"On GitHub, mergeable and mergeStateStatus are consulted once before gh pr merge; CONFLICTING/DIRTY classifies as conflict immediately, while UNKNOWN falls through to the merge call because GitHub computes mergeability asynchronously."*
    - Whenever any PR merges to `main`, GitHub resets `mergeable` to `UNKNOWN` (and `mergeStateStatus` to `UNKNOWN`) on **every other open PR targeting `main`** until a background job recomputes mergeability on the next read or after several seconds.
- **Impact**: If `PM-6`/`PM-8` maps GitHub's `mergeable == "UNKNOWN"` to `unknown` ("not reported as `clean`") without a bounded retry or distinction between `computing` (`mergeable: UNKNOWN`) and `unreadable` (network/auth error), then immediately after landing one PR in a train, every other ready PR in the repo will flip from `clean` -> `unknown` -> `clean`, either suppressing ready-to-merge visibility or firing spurious state-change wakes (`PM-11`).
- **Smallest Concrete Fix**: Specify in `PM-6` and `PM-8` how GitHub's `mergeable: UNKNOWN` / `mergeStateStatus: UNKNOWN` is handled: perform one bounded re-read after a short settle delay (matching `bin/fm-pr-merge.sh` semantics) or distinguish `computing` from `unreadable`, and do not emit a conflict wake on transient `UNKNOWN`.

---

### Finding 3 — `[BLOCKING]` `[Severity: high]`
**Title**: `PM-11` ("One PR state change produces one supervisor wake across the watch and discovery paths") has no shared deduplication owner or state file between `bin/fm-pr-check-watch.sh` and `bin/fm-ready-pr-discovery.sh`.

- **Category**: Duplicate ownership / Failure modes
- **Evidence**:
  - `docs/prd/supervision/pr-check-monitoring.md:38` (Gap 3): *"Check watch and ready-PR discovery can surface the same PR twice | Duplicate supervisor wakes on one PR transition."*
  - `docs/prd/supervision/pr-check-monitoring.md:52,61` (`PM-11`, `AT-PM-4`): *"One PR state change produces one supervisor wake across the watch and discovery paths."*
  - `docs/prd/supervision/pr-check-monitoring.md:67-74` ("Ownership" table):
    - `External check watch` -> `bin/fm-pr-check-watch.sh`
    - `Ready-PR discovery` -> `bin/fm-ready-pr-discovery.sh`
    - `Merge preflight and merge` -> `bin/fm-pr-merge.sh`
    - Notice there is **no owner** in the Ownership table for cross-path PR wake deduplication (`PM-11`)!
  - In the codebase:
    - `bin/fm-pr-check-watch.sh:1-45,230-280` is a `process-event` source adapter (`bin/fm-procevent-watch.sh`) that writes JSON events into `state/procevent-inbox/` and triggers a `check: procevent github-pr-check <source-id> <seq>` wake (`bin/fm-watch.sh`).
    - `bin/fm-ready-pr-discovery.sh:73` is a stateless snapshot script invoked by `bin/fm-heartbeat.sh:686` that writes only to `TMPDIR` and prints JSON to stdout; `bin/fm-ready-pr-discovery.sh` **never** reads `state/procevent-inbox/` or `state/procevent-sources/`, and `bin/fm-heartbeat.sh` does not enqueue per-PR wakes directly (`bin/fm-watch.sh` enqueues `heartbeat` wakes).
- **Impact**: Because `bin/fm-pr-check-watch.sh` (which watches a specific `(repo, pr, head_sha, app_id, check_name)`) and `bin/fm-ready-pr-discovery.sh` (which scans `no-mistakes` parked/orphan runs during `bin/fm-heartbeat.sh`) have no shared state marker and emit completely different wake types (`check: procevent ...` vs `heartbeat.json` `ready_pr_discovery` fields), `PM-11` and `AT-PM-4` are unimplementable without defining which script owns the shared dedupe key `(pr_url, head_sha, state_transition)` and where that state file lives under `state/`.
- **Smallest Concrete Fix**: Add a row to the Ownership table (`docs/prd/supervision/pr-check-monitoring.md:67-74`) naming the single owner of cross-path PR transition deduplication (e.g., `state/pr-transition-seen/<pr-key>` owned by `bin/fm-wake-lib.sh` or `bin/fm-ready-pr-discovery.sh`), specifying the exact dedupe tuple `(pr_url, head_sha, check_or_conflict_state)` so a PR transition already surfaced by `bin/fm-pr-check-watch.sh` is marked seen in discovery (and vice versa).

---

### Finding 4 — `[BLOCKING]` `[Severity: high]`
**Title**: Token economics baseline method (`state/watchdog/model-calls.tsv`) is always zero for PR check monitoring and discovery.

- **Category**: Token economics
- **Evidence**:
  - `docs/prd/supervision/pr-check-monitoring.md:95-100` ("Token economics"): *"Baseline method: Count supervisor wakes and model tokens before and after this work from `state/watchdog/actions.tsv`, `state/watchdog/model-calls.tsv`, and the wake logs across a comparable work window. Compare both wake count and total tokens using the token fields in `state/watchdog/model-calls.tsv`, not wake count alone."*
  - Neither `bin/fm-pr-check-watch.sh`, `bin/fm-ready-pr-discovery.sh`, nor `bin/fm-pr-merge.sh` ever invokes `bin/fm-watchdog.sh` or writes to `state/watchdog/model-calls.tsv`. Every token saved or spent by `pr-check-monitoring.md` is in the **supervisor session's** LLM turns (wakes triggered by `check: procevent github-pr-check ...` or `heartbeat` turns inspecting PR mergeability).
- **Impact**: `state/watchdog/model-calls.tsv` contains zero rows for PR check monitoring both before and after this work, rendering the baseline method unmeasurable as written.
- **Smallest Concrete Fix**: Measure `check: procevent github-pr-check` wake counts in `state/.wake-queue` / `state/.supervise-daemon.log` paired with supervisor session transcript token usage (`bin/fm-heartbeat.sh:172-215` / `state/context-burn.tsv` `turn_type=wake|heartbeat`).

---

### Finding 5 — `[BLOCKING]` `[Severity: medium]`
**Title**: `PM-9` and `PM-10` ("A push to the PR branch clears the prior conflict record and re-evaluates on the new `head` SHA") do not handle target-branch (`base`) advances when the PR's `head` SHA is unchanged.

- **Category**: Missed work / Failure modes
- **Evidence**:
  - `docs/prd/supervision/pr-check-monitoring.md:50-51` (`PM-9`, `PM-10`):
    - `PM-9`: *"A push to the PR branch clears the prior conflict record and re-evaluates on the new `head` SHA."*
    - `PM-10`: *"A check event for an older `head` SHA is ignored and logged as `stale-sha`."*
  - What if a PR becomes `conflicted` (or `clean` -> `conflicted`) because **`main` (the base branch) advanced**, or conversely a conflict is resolved because a reverting commit landed on `main`, while the PR's `head` SHA stayed the same?
- **Impact**: If conflict state is keyed and invalidated *only* on the PR's `head` SHA (`PM-9`), a PR that was previously `clean` at `head=abc` will never re-evaluate conflict state when `main` advances to `base=def` and introduces a merge conflict! That reintroduces Gap 1 (*"A conflicted PR can look ready until merge time"*).
- **Smallest Concrete Fix**: Amend `PM-9` so conflict records are keyed by `(pr_url, head_sha, base_branch_head_sha)`: a change to *either* the PR's `head` SHA or the target base branch's tip SHA invalidates the cached conflict state and triggers re-evaluation.

---

### Finding 6 — `[NON-BLOCKING]` `[Severity: low]`
**Title**: `PM-3` (`producer=app:<id>`) only covers GitHub App check suites (`bin/fm-pr-check-watch.sh:14-18`), not legacy GitHub commit status contexts (`statusContext`) or non-GitHub forges (`glab`, `tea`).

- **Category**: Safety / Failure modes
- **Evidence**:
  - `docs/prd/supervision/pr-check-monitoring.md:44` (`PM-3`): *"Each check watch binds to `check-watch=<watch-ref>`, `head=<bound-sha>`, and `producer=app:<id>`."*
  - `bin/fm-pr-check-watch.sh:14-18,170-215` queries GitHub `check-runs` filtered by `app.id` (`producer=app:<id>`). Commit statuses posted via the GitHub Statuses API (which have no `app.id`) or GitLab/Gitea pipelines (`bin/fm-pr-merge.sh:21-25`) cannot match `producer=app:<id>`.
- **Smallest Concrete Fix**: Note in `PM-3` and "Out of scope" (`docs/prd/supervision/pr-check-monitoring.md:83-87`) that `bin/fm-pr-check-watch.sh` is scoped to GitHub Check Runs (`app:<id>`), while `bin/fm-pr-merge.sh` and `bin/fm-ready-pr-discovery.sh` handle `gh`, `glab`, and `tea`.
