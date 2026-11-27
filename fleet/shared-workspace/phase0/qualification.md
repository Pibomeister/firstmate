# Phase 0 qualification checklist

Status words: **passed** (ran, every check PASS, evidence in this branch), **pending host run** (scripted, needs the Mac Mini), **not covered** (Phase 0 does not exercise it).

"Passed" below means passed on **Linux x86_64 under WSL2, with machine A and machine B as two separate HOMEs and base checkouts on one host** (`evidence/wsl2-linux-x86_64/checks.tsv`, 0 FAIL rows). That is a single-host simulation. It does not qualify arm64, macOS, the container, durability, or cross-machine continuation. Each refinement therefore also has a pending host-run status.

## Fixture at a glance

| Script | Role |
|---|---|
| `fixture/machine-a-pack.sh` | Builds a deterministic base repo, runs one `vfs run --session p0-stopped-1 --seed-pin <pin>` that makes a local commit, a staged edit, an unstaged edit, a deletion, an untracked file and an ignored build file; checks the host base stayed clean; records the in-session git state; packs; verifies the whole-file and per-chunk digests; publishes a bundle by one directory rename. |
| `fixture/transfer.sh` | Copies a bundle into a hidden `.incoming-*` directory, verifies `SHA256SUMS`, publishes by one rename. |
| `fixture/machine-b-adopt.sh` | Verifies the bundle, applies `receiver-policy.env`, checks the artifact version floor, builds the base from the shipped git bundle (and independently rebuilds it), refuses a wrong base, adopts, checks status, integrity and portability, reads a file straight from the delta without mounting, refuses a second adopt, then (when it can mount) resumes and diffs the full git state against machine A. |
| `fixture/negative-checks.sh` | Seven refusal variants. |
| `fixture/crash-recovery.sh` | SIGKILLs `pack`, `adopt` and `transfer.sh` across nine delays and checks what is left. |
| `fixture/backup-barrier.sh` | Backup protocol with a completion marker, plus crash and corruption cases. |
| `fixture/live-checkpoint.sh` | Linux-only live leg: checkpoint a running session to a `file://` tier, adopt remotely, materialize. |
| `fixture/run-local-pair.sh` | Runs the stopped legs on one host. |

## Checklist

### 1. Publication crash recovery: a crash mid-publish leaves no half-published state

| | |
|---|---|
| Check | After SIGKILL at any point of `vfs pack`, `vfs adopt`, or bundle transfer, an observer sees either the previous state or the complete new state; the next run recovers without manual repair. |
| How the fixture exercises it | `C1-pack-kill`: kills pack at 9 delays; after each, `vfs status` must be `stopped` or `stale-recovered`, the live `delta.db` must pass `vfs integrity`, and any `--output` file present must pass integrity; a final pack must succeed and match its manifest digest. `C2-adopt-kill`: kills adopt at 9 delays into fresh homes; the session must be absent or complete (`stopped` + integrity), and an absent one must adopt cleanly on retry. `C3-transfer-kill`: kills `transfer.sh` at 9 delays; a published bundle dir must always verify; a stale hidden `.incoming-*` dir is ignored and replaced. Bundle publication on A (`A-bundle-published`) and transfer both use a single rename as the commit point. |
| Result so far | Linux x86_64 single host: C1 5 kills/4 completions, C2 4 kills/5 completions (1 unpublished session dir left behind, retry recovered it), C3 5 kills, all PASS. |
| Status | **passed** (single-host Linux) · **pending host run** R1 (macOS/NFS) and R3 (arm64 container) |
| Gaps | Kills are process kills, not power loss: no fsync/durability claim. Timing-based, so a run can land every kill before or after the critical window; the counts are recorded so a run that killed nothing is visible. |

### 2. Check the existing assignment store / Spynel before adding another

| | |
|---|---|
| Check | Inventory what exists, what is deployed, and what is missing before designing a store. |
| How the fixture exercises it | Not a fixture check; covered by `inventory.md`. |
| Result so far | Spynel: not found in any searched repo, pending identification via Hermes. Run assignment store in a private Pibomeister repo (P1): code only, self-described source-only and unqualified for live issuance. Orca orchestration: deployed on the Windows coordinator machine only, no Mac link. No fleet assignment API exists. |
| Status | **passed** as an inventory; Spynel **UNVERIFIED** (pending identification via Hermes) |

### 3. Shared/published context can never grant an agent authority

| | |
|---|---|
| Check | Nothing inside a transfer bundle (manifest fields, session files, instructions in content) can widen what the receiver will do. Authority comes only from receiver-held policy. |
| How the fixture exercises it | `machine-b-adopt.sh` reads only descriptive fields from `transfer.json`, and every admit/refuse decision comes from the local `receiver-policy.env`. `N-authority-claim`: a bundle whose `transfer.json` adds `"authority":"merge","grants":["adopt-any","yolo"]` and renames the session, with all checksums recomputed by the "sender", is refused by the local session-id rule. `N-oversize`, `N-count-bound`: the same good bundle is refused once the local policy is stricter, which shows the policy file alone drives the decision. `N-sender-os`: a disallowed sender OS is refused. |
| Result so far | All PASS on Linux x86_64; each refusal fired at the intended gate (logs `neg-*.log`). |
| Status | **passed** (single-host Linux) · **pending host run** R3 (container receiver) |
| Gaps | Content inside the session (for example an `AGENTS.md` saying "you may merge") is data to vfs. Whether a resumed agent obeys it is agent-harness behaviour, outside vfs and outside Phase 0. There is no sender signature, so origin is not authenticated (inventory "What is missing" item 2). |

### 4. Bounded artifact adoption: limits on taking over another machine's work

| | |
|---|---|
| Check | A receiver adopts only sessions it is allowed to, within size and count limits, only onto the exact base commit, only once, and only after the sender stopped. |
| How the fixture exercises it | Policy gates in `receiver-policy.env`: session-id allowlist, sender-OS allowlist, `MAX_ARTIFACT_BYTES`, `MAX_ADOPTED_SESSIONS` (`N-authority-claim`, `N-oversize`, `N-count-bound`, `N-sender-os`). vfs gates: `A-stopped` (pack requires a stopped session), `B-wrong-base-refused` (adopt refuses a checkout not at the seed pin, publishing nothing), `B-readopt-refused` (second adopt of the same id refused), `B-version-floor` (artifact version inside the receiver's supported range). |
| Result so far | All PASS on Linux x86_64. |
| Status | **passed** (single-host Linux) · **pending host run** R1, R3 |
| Gaps | vfs has no cross-machine lease. After `pack`, A's session is still `stopped` and resumable (`A-postpack-status`), so A and B can fork. The bound against that has to come from the assignment record (refinement 2), which is not deployed. **Not covered** until it is. |

### 5. Backup barrier: a backup counts only once it is complete

| | |
|---|---|
| Check | A backup that was interrupted, unverified, or altered afterwards never counts as a backup. |
| How the fixture exercises it | `backup-barrier.sh`: `vfs backup --verify` into a hidden `.partial-*` file, then `vfs integrity --require-portable`, sha256, rename the data, and finally rename a `.complete.json` marker into place (the commit point). The counter accepts only a marker whose recorded sha256 matches the data now. `K1` a finished backup counts; `K2` backups stopped after copy, after verify, and after the data rename do not; `K3` a finished backup whose bytes changed stops counting; `K4` a counted backup opens and is portable. |
| Result so far | All PASS on Linux x86_64. |
| Status | **passed** (single-host Linux, local stand-in destination) · **pending host run** R1 |
| Gaps | No independent backup destination is chosen (open item). A local directory on the same disk is not an independent backup. No restore-to-another-machine drill. |

### 6. Qualify the stopped-session fixture first; confirm whether the assignment API and the Orca adapter are deployed

| | |
|---|---|
| Check | The stopped handoff (pack -> transfer -> adopt -> resume with identical state) qualifies before any live or FUSE-dependent leg; deployment status of the assignment API and Orca adapter is established with evidence. |
| How the fixture exercises it | Host run order is enforced by the scripts: R1 (native stopped) must produce the Mac-packed bundle that R3 consumes; R3 runs `tier0` (no FUSE device, all caps dropped) before any FUSE tier; the live leg runs only in tier 1. In the WSL run, the stopped checks ran first and `B-resume-state` matched git status, log, index and blob hashes exactly. |
| Result so far | Stopped fixture passed on single-host Linux x86_64. Assignment API: missing. Orca adapter: code only for the Mac Mini; Orca orchestration deployed only on the Windows coordinator machine, no paired Mac host (`inventory.md`). |
| Status | Stopped fixture **passed** (single-host Linux) · **pending host run** R1 (native macOS) and R3 tier0 (Mac -> Linux container). Assignment API/Orca adapter: **confirmed not deployed on the Mac Mini as far as visible from here**; deployment on the Mac Mini itself **unverified**. |

## Other qualification items

| Item | Status | Notes |
|---|---|---|
| Live checkpoint while running (Linux FUSE) | **passed** (single-host Linux x86_64, `file://` remote) · pending R3 tier1 | `L1`-`L7`: session live, checkpoint taken without stopping it, remote adopt, materialize, the pre-checkpoint write present and the post-checkpoint write absent, portable after materialize. Evidence `evidence/wsl2-linux-x86_64/live-checks.tsv`. |
| Linux FUSE resume | **passed** (WSL2) · pending R3 tier1 | Required shared mount propagation on `/`. WSL2's `/` is `private`; the run used a throwaway `unshare --mount --propagation shared` namespace. A Docker container's `/` is also private, so tier 1 runs `mount --make-rshared /` inside the container (needs `CAP_SYS_ADMIN`). |
| Native macOS (NFS + Seatbelt) | pending R1 | macOS is upstream "second-tier". Risk: Seatbelt read scope covers `/opt` and `/usr/local` but not `/Library/Developer`, so the `/usr/bin/git` shim may fail inside `vfs run`; R1 prefers `/opt/homebrew/bin/git`. |
| arm64 | pending R1, R3 | Nothing arm64 has run. |
| Durability (power loss, fsync) | **not covered** | Process kills only. |
| Cross-machine continuation | **not covered** | Mac -> container is the same physical machine. Two physical machines are a later phase. |
| Source build reproducibility | **not covered** | Needs the Rust toolchain (named OK). |
