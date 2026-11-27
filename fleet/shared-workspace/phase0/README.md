# Fleet shared-workspace pilot - Phase 0

Phase 0 qualifies Factory-AI/vfs v1.1.1 (source revision `4852148c`) as the
workspace layer for the fleet shared-workspace pilot. The plan is the
revision-2 brief that Hermes reviewed. Phase 0 does not reopen the AgentFS
comparison.

The eventual host is the Mac Mini where the Hermes agent runs (macOS 26.3,
arm64). Native macOS supports stopped handoffs only. Linux FUSE and
live-checkpoint paths are qualified inside a free Linux container on the Mac
Mini (Colima/Docker). This branch's author has no Mac Mini access, so every
host step is a runnable script plus a "host run request" in the report.

## Deliverables

| # | File(s) | What |
|---|---------|------|
| 1 | `pin.md`, `pin.json`, `scripts/pin-vfs.sh` | Pin vfs at `4852148c`, confirm it is the `v1.1.1` tag, build it, record `vfs version --json`, binary sha256, OS/arch. |
| 2 | `fixture/` | Tiny stopped-session pack -> transfer -> adopt fixture (machine A to machine B, Mac to Linux container) with verification checks. |
| 3 | `inventory.md` | What is deployed, code-only, docs-only, or missing for the assignment store / Spynel and the Orca adapter, with evidence. |
| - | `qualification.md` | Checklist for the six Hermes refinements: check, how the fixture exercises it, status. |
| - | `host-run-requests.md` | Exact commands, access scope, and undo steps for everything that must run on the Mac Mini. |

## Six refinements (Hermes review)

1. Publication crash recovery: a crash mid-publish leaves no half-published state.
2. Check the existing assignment store / Spynel before adding another.
3. Shared/published context can never grant an agent authority.
4. Bounded artifact adoption: limits on taking over another machine's work.
5. Backup barrier: a backup counts only once it is complete.
6. Qualify the small stopped-session fixture first, and confirm whether the
   assignment API and the Orca adapter are actually deployed.

## Constraints

- No deploys, no spend or paid tools, no secrets, no new servers, no installs
  on the authoring machine. Anything that needs one is listed under
  "Needs Eduardo's named OK" and is not done.
- Work stays on branch `fleet/vfs-phase0` under `fleet/shared-workspace/phase0/`.
  The PR stays a draft and is not merged.
- Host steps request a minimal FUSE device/capability set (never an
  unrestricted privileged container), state their access scope, and include
  undo steps. The stopped fixture qualifies first.
- A Linux runtime being up does not qualify FUSE, live checkpoint,
  durability, or cross-machine continuation.
- The assignment API/store and the Orca adapter stay UNVERIFIED until there
  is evidence.
- Fixture data is capped at 10 GiB (the fixture itself is a few KiB).

## Layout

| Path | What |
|---|---|
| `pin.md`, `pin.json` | Pinned revision, release asset digests, recorded builds. |
| `scripts/pin-vfs.sh` | `release` / `fetch` / `source` / `record` the pinned vfs. |
| `fixture/` | Stopped-session fixture (`machine-a-pack.sh`, `transfer.sh`, `machine-b-adopt.sh`, `receiver-policy.env`), refinement checks (`negative-checks.sh`, `crash-recovery.sh`, `backup-barrier.sh`), Linux live leg (`live-checkpoint.sh`), one-host driver (`run-local-pair.sh`), container receiver (`container/`). |
| `host/` | Mac Mini scripts for the host run requests, plus `99-undo.sh`. |
| `host-run-requests.md` | R0-R3: exact commands, access scope, undo. |
| `qualification.md` | The six refinements as a checklist with status. |
| `inventory.md` | Assignment store / Spynel / Orca adapter inventory with evidence. |
| `evidence/wsl2-linux-x86_64/` | Results from the one-host Linux run on the authoring machine. |

## Results so far

- Pin: `4852148c` is the `v1.1.1` tag. The Linux x86_64 release binary (sha256 `59ad43e6…`) reports version 1.1.1 at that commit, artifact format 0.8.
- Stopped fixture, refinement checks and live checkpoint: all pass on Linux x86_64 under WSL2, with machine A and B as two homes on one host. Nothing has run on macOS, on arm64, or in the container yet.
- Finding: on Linux, `vfs run` needs shared mount propagation on `/`. WSL2 and Docker containers default to private, so the container tier that mounts FUSE must run `mount --make-rshared /` inside the container (needs `CAP_SYS_ADMIN`).
- Finding: vfs has no cross-machine lease. After `pack`, the sender's session stays resumable, so exclusivity must come from an assignment record.
- Inventory: Spynel not found in any searched repo (UNVERIFIED, pending identification via Hermes); the run assignment store in a private Pibomeister repo is code only; Orca orchestration runs only on the Windows coordinator machine with no paired Mac host; no fleet assignment API exists.

## Open items

- What and where Spynel is: not found in any searched repo, pending identification via Hermes (UNVERIFIED).
- Independent backup destination (none chosen; the fixture uses a local stand-in).
- Sender authentication for bundles (checksums prove integrity, not origin).
- The revision-2 brief itself was not available to this worker; this branch follows the task's summary of it.
- Evidence note: `evidence/wsl2-linux-x86_64/uname.txt` had the authoring machine hostname in commits 6ce6465b and 8a0fdfe3; it is replaced with `<host>` from the next commit on (history not rewritten).

## Needs Eduardo's named OK

Nothing below has been done.

1. Installing the Rust `nightly-2026-08-07` toolchain anywhere, to run `pin-vfs.sh source` and compare a source build against the release binary.
2. R2: creating and starting the new Colima VM profile `factory-vfs-pilot` on the Mac Mini (free, local, but a new long-lived VM; it downloads a VM image).
3. R3 tier 1: running the receiver container with `--device /dev/fuse --cap-add SYS_ADMIN` (and, only if needed, Docker's default caps or `apparmor=unconfined`).
4. Choosing an independent backup destination, and any spend or credentials it needs.
5. Any deployment of an assignment API or lease service, or enabling firstmate's Orca backend on the Mac Mini.
