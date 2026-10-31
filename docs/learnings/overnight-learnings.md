# Fleet learnings (append-only, dated)

Format per entry: Lesson | Failure | Check/rule | Issue (when one exists).
Never edit or delete old entries; add a new dated entry to supersede one.
Keep every entry general: no person, company, project, customer, host, account, or terminal names, and no credential details.

## 2026-10-31 (from an overnight AFK scorecard)

### 1. Preflight readiness was guessed
- Failure: an AFK preflight reported ready without testing. Hard dependencies surfaced hours later: missing repo config and credentials, undeployed prerequisites, an outdated tool, and a score bar that current output could not reach.
- Rule: before the captain logs off, dry-run every goal's hard dependencies and record PASS/FAIL with evidence: tokens and credentials exist (never print values), installs and versions, deploys landed, repo config (required approvals and owners), sign-ins, and whether the score bar is reachable on current output. No PASS means not ready; batch every FAIL to the captain before AFK starts.
- Issue: https://github.com/Pibomeister/firstmate/issues/77

### 2. Self-servable work was parked for the captain
- Failure: a project missed its whole bar because a tool upgrade, a local runner setup, and work possible through an installed CLI were all parked as needing the captain, and supervision accepted those parks.
- Rule (park challenge): before parking, try with the tools and authority you have and record what you tried. Installed CLIs, tool upgrades and installs on dev machines, local credentials, sockets and daemons a tool can create or start, opening PRs, reruns and reroutes are NOT sign-ins. True SSO/2FA sign-ins, credentials no tool can supply, new spend, releases, merges outside existing rules, and anything destructive, irreversible, or security-sensitive go to the captain; the captain escalation list in AGENTS.md still applies in full. Supervisors challenge every park ("could this be self-served?"). Blocked for more than 1 h means a self-serve path, a reroute, or an escalation to the captain.
- Issues: https://github.com/Pibomeister/firstmate/issues/78 and https://github.com/Pibomeister/firstmate/issues/63

### 3. Captain context churn
- Failure: captains restarted repeatedly overnight and auto-compacted, and one captain's self-estimate of remaining context was about five times too high.
- Rule: hand off at 15% context left or more, measured externally (footer or auto-compact percentage, read by the watcher or leash), never by self-estimate. The new session confirms a full handoff before the old one stops; never /compact.
- Issues: https://github.com/Pibomeister/firstmate/issues/65 and https://github.com/Pibomeister/firstmate/issues/70

### 4. Late starts on one overloaded host
- Failure: work piled onto one machine until load was far above its ceiling, orphaned browser processes accumulated, and free disk ran low, while other capacity sat underused.
- Rule: distribute lanes across available machines and cloud at kickoff; set per-host caps on load, free disk and terminals; reap orphan processes each pass; disk under the floor pauses new launches.
- Issues: https://github.com/Pibomeister/firstmate/issues/79 , https://github.com/Pibomeister/firstmate/issues/67 and https://github.com/Pibomeister/firstmate/issues/68

### 5. Watchdog restart loop
- Failure: a network watchdog looped through 20+ restarts; an earlier version could not see a dead data plane behind a live daemon.
- Rule: test every watchdog against the failure modes it claims to catch before enabling it; use exponential backoff; cap restarts per window, then page instead of restarting.
- Issue: https://github.com/Pibomeister/firstmate/issues/80

### 6. Supervision gaps (heartbeat, stop verification, receipts)
- Failure: a required supervisor seat sat empty for hours, a worker kept pushing after a stop order while its captain reported it stopped, and a change merged without receipts or a tag before a release.
- Rules: required supervisor seats write heartbeats and the watcher alerts or relaunches when they go stale; verify a stop with gh (branch and PR heads unchanged) and process checks (pid gone) before reporting it done; no merge or publish without receipts for the exact head SHA; no release publish without a matching tag. Never push to upstream remotes from a fork run.
- Issues: https://github.com/Pibomeister/firstmate/issues/81 , https://github.com/Pibomeister/firstmate/issues/82 , https://github.com/Pibomeister/firstmate/issues/72 and https://github.com/Pibomeister/firstmate/issues/74

### 7. Gate-lock serialization and unpushed commits
- Failure: one global gate lock serialized every lane, committed work sat unpushed for over an hour, and reviews then hit stale heads.
- Rule: use gate locks per lane or a bounded pool; push committed work promptly even while its gate is queued; alert when a commit stays unpushed for more than 30 min.

### 8. Verdict script reported a pass on a rejection
- Failure: a review script's summary reported a pass while the final verdict was a rejection.
- Rule: parse verdicts strictly from one structured final field (exact enum); missing or ambiguous means reject; tests include a transcript that mentions a pass early and ends in rejection.

### 9. Input jams and a fix that never landed
- Failure: a captain's wake-ups sat unsent in its composer, and the push of the fix was rejected, so the fix stayed local.
- Rule: every doorbell or prompt send verifies submission (turn started) and retries; escalate and reroute a failed push of a fix (other remote, account or PR path) within 1 h, never leave it local.
- Issue: https://github.com/Pibomeister/firstmate/issues/64

### 10. Prompts lost during restarts
- Failure: a nightly order landed during a captain restart and was never delivered, so its goals started hours late.
- Rule: queue inbound prompts durably; the new session drains and acks the queue on pickup; senders verify the ack and redeliver after any restart.
- Issue: https://github.com/Pibomeister/firstmate/issues/83
