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
