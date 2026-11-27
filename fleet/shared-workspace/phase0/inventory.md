# Inventory: assignment store, Spynel, Orca adapter

Feeds refinements 2 and 6. Gathered 2026-11-27 from the Windows authoring machine.

This is the **redacted public version**. This repository is public, so private Pibomeister repositories are named only as "a private Pibomeister repo" with a label (P1-P5). There are no quotes, paths or schema text from them here. The coordinator holds the unredacted inventory with full evidence (file paths, commits, quotes) outside git.

Sources:

- GitHub code search over the Pibomeister account for `spynel`, `Spynel`, `spinel`, `Spinel`, `spynl`, `assignment store`, `assignment api`, `orca adapter`, `orca orchestration`, `assignments`. Later queries hit GitHub's code-search rate limit and were replaced by local `git grep`. Code search covers default branches only.
- Shallow clones (all branches) of the seven repositories most likely to hold an assignment store or bridge: five private Pibomeister repos (P1-P5) and two public ones (`agent-kit`, `command-center`). Searched with `grep -r` and `git grep` across every remote branch tip.
- This repository (`Pibomeister/firstmate`, base `7a1de464`).
- The local Orca CLI 1.4.278, read-only commands only: `orca --help`, `orca status --json`, `orca host list --json`, `orca environment list --json`, `orca orchestration run-list --json`, `orca orchestration task-list --help`.

No server, database, or Mac Mini was reachable from here. Nothing below is marked deployed unless a live command showed it.

Status words: **deployed** (seen running by a live command), **code** (source and tests exist, no evidence it runs anywhere), **docs** (described, no implementation), **missing** (searched for, not found), **unverified** (could not be checked from here).

## Summary

| Component | Status | Evidence (redacted) |
|---|---|---|
| Spynel | **UNVERIFIED**: not found in any searched repo, pending identification via Hermes | No hits for five spellings in code search or in any branch of the seven cloned repos. The only grep match was a false positive inside a lockfile integrity hash. |
| Run assignment store (P1, a private Pibomeister repo) | **code** | A storage domain plus tests. Its own documentation calls it source-only and says live issuance and server activation are unqualified. |
| Operator issuance tool (P1) | **code** | An operator-run script, kept out of the built server output. |
| P1 production service | **code**, not deployed per its own evidence docs | Its evidence docs say service setup is source preparation only and nothing was started. Whether anything runs now is **unverified** (no host access). |
| Orca orchestration (Runs, tasks, dispatches, worker fencing) | **deployed on the Windows coordinator machine** | This task is Dispatch `ctx_abcd0ce627be` in Run `run_9cf589ce842b`. `orca status --json` reports runtime `ready`, app 1.4.278. |
| Orca link to the Mac Mini | **missing** | `orca host list --json` lists only the local Windows host. `orca environment list --json` returns an empty list. |
| Firstmate Orca runtime backend (`bin/backends/orca.sh`) | **code**, experimental | `docs/orca-backend.md` describes it as experimental. Its recorded verification (`docs/verification/runtime-backends.md`, "Orca") was on macOS with Orca 1.4.116. Whether it is enabled on the Mac Mini is **unverified**. |
| A fleet assignment API | **missing** | No HTTP or RPC assignment API in any searched repo. The nearest are P1's in-process storage domain (code) and Orca orchestration (deployed only on the Windows machine). |
| P2 (a private Pibomeister repo, mission planning) | **missing** (empty) | Its only branch is one commit with an empty tree. |
| P3 (a private Pibomeister repo, relay-to-inbox bridge) | **code**, not an assignment store | Bridges a relay channel to a firstmate inbox. It holds no assignments. |
| P4 (a private Pibomeister repo, agent bridge) | **code**, not an assignment store | Message routing plus a key-value store any agent can write. That is the pattern refinement 3 rules out as a source of authority. |
| P5 (a private Pibomeister repo, factory monorepo) | **code**, no assignment store found | Has a machine bridge and macOS deploy material. "Lease" appears only in a provider-admission sense. Deployment **unverified**. |
| `command-center` (public) | **code**, different concept | Its task role assignments map people and roles to board tasks, not runs to machines. |

## Orca detail

- Orchestration surface (`orca --help`): `run-create/run-list/run-show`, `task-create/task-list/task-update`, `dispatch`, `worker-start`, `worker-stop` ("Fence one Dispatch; stop its supervised worker"), `worker-abandon` ("Fence an uncertain worker without claiming it stopped"). Fencing a dispatch is the primitive refinement 4 needs before a second machine adopts work.
- `orca orchestration task-list` refuses from a worker (`run_required`), so task records were not read.
- Firstmate's Orca adapter drives `orca terminal` and `orca worktree` for crew endpoints. It is a runtime backend, not an assignment store.

## What is missing for the pilot

1. A cross-machine lease or fence. vfs has none: after `pack`, machine A's session is still `stopped` and resumable (fixture check `A-postpack-status`), so A and B can both continue and silently fork. Only an external assignment record (a generation the receiver checks, revoked on handoff) can stop that.
2. An authenticated sender identity. Bundle checksums and vfs's own `dbSha256` prove integrity, not origin. A sender that recomputes every checksum passes them (`N-authority-claim` is refused only by local policy). Signing is not in Phase 0.
3. An assignment API reachable from both machines. Neither P1's storage domain (in-process, unqualified live) nor Orca orchestration (Windows-local, no Mac link) is that today.
4. An independent backup destination (open item; `backup-barrier.sh` uses a local stand-in).

Recommendation for refinement 2: do not add a third store. Reuse P1's run-assignment model (generation compare-and-set, operator-only issuance, irreversible revocation) as the lease of record, and use Orca dispatch fencing as the per-worker stop signal. Both need qualification before either counts as deployed.
