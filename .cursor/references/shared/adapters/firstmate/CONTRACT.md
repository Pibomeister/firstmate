# adapters/firstmate — supervisor contract

Firstmate supervises. agent-kit judges through the runner, inside a normal crewmate task. The
task's existing no-mistakes or direct-PR mode delivers. This file describes the stock integration
and retains the deprecated patched binding interface for existing users (ruling
`firstmate-outer-loop-agent-kit-inner`).

Firstmate is the only outer supervisor. Nothing here makes agent-kit a second one: it adds no
dispatcher, no watcher and no merge path, and it never writes Firstmate's state files. The runner
and run ledger live in `src/runner/`; this binding adapter does not start that service or dispatch
its supervisor seats. Firstmate may operate it separately through `ak runner` as described in
[`adapters/runner-contract/CONTRACT.md`](../runner-contract/CONTRACT.md) §9.

## Stock Firstmate path

`ak firstmate preflight --fm-home <home> --project <worktree> --host claude-code|codex` checks the
unmodified home's normal brief and spawn commands, the checkout, host and skill bundle. It does not
require patches 0001/0002, an upstream commit or no-mistakes `auto_fix` values. Without a runner
socket it reports `mode: guided`; with a socket it reports `runner-candidate`, leaving the standing
grant, seat and evidence checks to that run's runner.

Firstmate starts a task-scoped runner outside the worker worktree and shared Git directory, then
uses `ak firstmate brief` to render a section into an ordinary Firstmate brief. The task is spawned
with an existing `--mode no-mistakes`, `direct-PR` or `local-only`, never an `agent-kit` mode. The
worker reads the runner's start attestation, runs autopilot, and reports escalations through its
normal status and inbox. Firstmate dispatches the two supervisor seats as separate ordinary
crewmates; they are not children of the implementing worker. The runner records their distinct
dispatches and verdicts before deciding a checkpoint.

If no-mistakes changes the head after handoff, the worker adopts attributable pipeline changes and
re-verifies at the pushed head before reporting done. A change it cannot attribute escalates to the
supervisor. The pipeline's Review may challenge lifecycle-approved decisions. Disabling auto-fix is
optional project policy, not an installation prerequisite.
Publishing runner-owned evidence through the knowledgebase adapter remains a separate follow-up; it
stays in a configurable private store until that is wired.

The files beside this one:

| File | For whom | What it is |
|---|---|---|
| `SUPERVISOR.md` | Firstmate | A compact index of what agent-kit offers a supervisor, loaded on demand |
| `WORKER.md` | The worker | The brief section `ak firstmate bind` renders into a Firstmate brief |
| `CHILD-ROLES.md` | The worker's children | The envelope a task-local child runs inside |
| `hooks/child-guard.sh` | The Claude Code host | The PreToolUse hook that enforces part of that envelope |
| `upstream/a5d78f8/0001-agent-kit-mode.patch` | A Firstmate maintainer | The opt-in delivery mode this adapter depends on |
| `upstream/a5d78f8/0002-agent-kit-audit.patch` | A Firstmate maintainer | Applied after 0001: the dry-run definition of done, Firstmate's audit of a worker's `done:`, and the optional worker budget |

---

## 1. Capabilities and side effects

Firstmate is optional. agent-kit runs two ways, and standalone is the default: you open one or more
sessions yourself, each in its own worktree, and run the super-* lifecycle in each. Every lifecycle
check, including the pre-ship gate check, lives in core and needs nothing from Firstmate. Firstmate is
the opt-in for supervised multi-agent work, and this adapter only calls into core. No core command,
test or CI job needs Firstmate installed (ADR 0002).

This adapter supplies `firstmate-supervision` (`common#/$defs/capability`): a supervisor outside
the worker that dispatched the task, holds its steering inbox, watches its PR and owns merge.
Neither coding-agent host provides it.

### Capabilities this adapter supplies

| Capability | Unconfigured | What the refusal is |
|---|---|---|
| `firstmate-supervision` | `fails-closed` | Stock preflight refuses a home without its normal brief and spawn commands; the runner refuses a standing start without the approved charter and Firstmate controller. Legacy bind retains its own patch checks |

This adapter does **not** supply `kb-write`, and nothing about running under Firstmate lifts a
skill that requires it. Evidence that must reach the knowledgebase fails closed here until this
adapter publishes through one ([`adapters/knowledgebase/CONTRACT.md`](../knowledgebase/CONTRACT.md) §1, §7). The one exception is a binding whose evidence store
is a labeled `mock`, which the binding schema forces to `dry-run` so it can never back a publish
([`schemas/firstmate-binding.schema.json`](../../schemas/firstmate-binding.schema.json)).

Side effects this adapter adds: none. Under no-mistakes delivery, super-ship stops at the committed
handoff. The existing Firstmate delivery contract starts the unmodified no-mistakes pipeline,
which owns push and pull request (ADR-0012).

---

## 2. Deprecated legacy patched-binding ownership for delivery mode agent-kit

One owner per concern. Where two parties could act, the one named here acts and the other does not.

| Concern | Owner |
|---|---|
| Intake, dispatch, worktree, steering, recovery, PR watch, merge (yolo only), teardown | Firstmate, unchanged |
| Scout, build, verify, specialist review, fixes, delta review, the fix-cycle cap, the ship decision | agent-kit, inside the worker |
| Deterministic re-check of the shipped head (test, lint), push, PR, CI | no-mistakes, started by super-ship as its transport |
| Review judgment | agent-kit only |

no-mistakes runs with `--skip review,document,rebase` on every push, so there is no second review
pipeline and no commit the lifecycle did not review. The mechanics are in
`skills/super-ship/references/transport-no-mistakes.md` (ruling `no-mistakes-as-ship-transport`).

### Fleet agent and task-local child

These are different things, and confusing them is what the worker-role patch exists to prevent
(ruling `task-local-child-not-fleet-task`).

| | Fleet agent | Task-local child |
|---|---|---|
| Started by | Firstmate | The worker, inside its own task |
| Owns | A task | Nothing; the worker keeps ownership |
| Visible to Firstmate | Yes: a status file, an inbox, a worktree | No |
| Depth | Any Firstmate allows | 1 (`common#/$defs/child`) |
| Scope | Its brief | A subset of the worker's bound scope |
| May push, merge, open a PR, dispatch, contact a human | Per its brief | Never |
| Budget | Its own | Charged to the parent's persistent budget |

When autopilot needs two independent supervisor judgments, Firstmate arranges them as separately
dispatched agents. A worker's own children are never those judges: a judgment made by a helper the
worker started is not independent of the worker (ruling `missing-supervisor-never-implementer`).

---

## 3. Deprecated legacy compatibility

| Firstmate | What works |
|---|---|
| **Unmodified Firstmate** | The stock path above: normal brief, spawn, status, inbox and delivery mode, with runner-validated standing start. `ak firstmate preflight` passes compatibility checks without a patch; no runner means guided checkpoints |
| **Upstream `a5d78f8` with patches 0001 then 0002** | Delivery mode `agent-kit` for Claude Code workers with the child guard enforced; other harnesses with the guard declared but not enforced (§5). Everything in §2 and §4. With 0002, a `dry-run` binding's worker publishes nothing, and Firstmate itself runs `ak firstmate status <binding> --verify` on every agent-kit `done:` and keeps it only on exit 0 |
| **Upstream `a5d78f8` with patch 0001 only** | Legacy patched mode is unavailable: `ak firstmate preflight --legacy-patched` refuses it and names 0002; the stock path above still works |
| **Not wired by these patches** | Evidence published to a knowledgebase (this adapter publishes to none); automatic startup of the separate runner service and seat launchers; any Firstmate commit the patches do not apply to cleanly. A Firstmate supervisor can start the runner and pass its worker token and socket without changing this binding adapter |

The patches are version-bound and form a stack: 0002 rewrites lines 0001 added, so it applies only
on top of 0001. They are carried here, under the upstream commit they were made against, and never
applied to a live Firstmate home by any `ak` command. `ak firstmate preflight --legacy-patched` checks that the home
contains the upstream commit and that every patch in the stack is already applied, by reverse
`git apply --check` from the top patch down. It peels each checked patch off in a scratch git index
built from the home's working tree, so the home's own index and files are never changed.
`ak firstmate install` refuses on a home where the stack is not applied.

`ak firstmate install` writes into the home's `config/` only: `agent-kit.env`, which holds exactly
the three keys 0001 requires (`AK_FIRSTMATE_BIN`, `AK_FIRSTMATE_PATCH`,
`AK_FIRSTMATE_WORKER_SETTINGS`), which the patched parser refuses if it holds any other key but
0002's optional `AK_FIRSTMATE_WORKER_BUDGET_USD` (install never writes that one; a maintainer adds it);
`agent-kit/worker-settings.json`, whose `PreToolUse` hook command carries `'__AK_FIRSTMATE_BINDING__'`, in
single quotes, for the patch to replace with the task's bare binding path, and whose `Stop` hook runs
`bun '<ak root>/tools/hooks/semantic-lint.ts' hook` with a 30-second timeout, the advisory semantic
lint of `docs/semantic-lint.md`, holding no key and setting no switch; and, when an evidence store is given,
`agent-kit/evidence.env`, which only `ak` reads. It is idempotent and `ak firstmate remove` deletes
exactly those.

---

## 4. Deprecated legacy binding status lines

The worker reports to Firstmate the way every Firstmate worker does: by appending one line to its
status file. agent-kit maps its run outcome onto Firstmate's verbs and writes nothing else. It never
reads or writes `state/`, never edits the brief, and never touches another task's files.

| `run_state` | Status line |
|---|---|
| `complete` (PR open, checks green) | `done [at=<epoch>]: PR <url> checks green evidence=<ref>,<ref>` |
| `complete` in `dry-run` | `done [at=<epoch>]: dry-run ship prepared, nothing published evidence=<ref>` |
| `needs-input` | `needs-decision [at=<epoch>]: <the decision, named>` |
| `cap-reached` | `needs-decision [at=<epoch>] [key=fix-cap-<run>]: fix-cycle cap reached; blocked or replan; open findings=<ids>` |
| `failed` | `failed [at=<epoch>]: <reason>` |
| `cancelled` | `failed [at=<epoch>]: cancelled: <by whom>` |
| any state, with a child whose outcome is unknown | `blocked [at=<epoch>]: child <id> state unknown` |

The last row wins over every other. A worker that cannot say what one of its children did has not
finished, and it keeps ownership of the task rather than reporting `done` and leaving the child's
effects unowned. `ak firstmate status <binding> <outcome>` prints these lines; it writes nothing.

`evidence=` refs are the verification receipts and the review the ship rested on, by artifact id.
Under a `mock` evidence store they point into that labeled store, and the line says `dry-run`.

`complete` is audited before its line is printed, by the same core check a standalone super-ship runs
(`src/lifecycle/gate.ts`, `ak lifecycle check`). Every gate in the binding's `required_gates`, which
`bind` sets to `build-checks, verify, review-full, review-readiness, ship-preflight`, needs a gate
record in the binding's evidence store, for the lifecycle run the worker opened with this binding
(`open --ticket <ticket-file> --binding <binding file> --dir <evidence store>`; the latest one when it
opened more than one, and the binding's own run id when it opened none), current for the head the latest `ship-preflight`
record names. `build-checks` and `review-full` may sit on an earlier head in that head's history; a
`review-full` on an earlier head, or one that requested changes, also needs a `review-delta` at this
one recorded after it. That history is bounded
by ancestry alone. The fork-point bound applies only to a standalone run named after its branch (no
`--run` and no opened run): there, a record whose snapshot is already on the default branch
(`origin/HEAD`, else `main`, else `master`) does not count unless it is at the head's own revision,
so a reused branch does not inherit an old run's records. An opened run's id is unique per run and
the audit names it explicitly, so the audit keeps counting a run's records after the supervisor merges
it, and `--run` opts a standalone check out of the bound the same way. The bound's known limit on a
reused branch, and the task-bound run `ak lifecycle open` mints, are described in the header of
`src/lifecycle/gate.ts`. A bound worker opens its run with `--binding`, records and checks against
that opened run, and the run record keeps the binding's run id and evidence store, which is where the
worker's own `check` looks for the binding's grant records. Then every
grant the run needed must have left a grant record naming this binding by path and by the hash the ledger registered,
and the binding must still hash to it. Any refusal prints `refused: …` lines and a `needs-decision`
hint, exits 1, and prints no `done` line. `ak firstmate status <binding> --verify` runs the same audit
on its own, for a supervisor that wants to check a `done` it was handed; with patch 0002 Firstmate
runs it on every agent-kit `done:` (§3). A knowledgebase store fails
closed here too: the audit cannot read it, so it refuses.

---

## 5. Deprecated legacy trust boundary

The stock path's grant, state, evidence and seat records are held by the task-scoped runner,
outside the worker worktree and Git common directory. Firstmate's normal task brief, status and
inbox remain its own endpoints; the runner never writes them. The legacy binding checks below do
not substitute for a runner on an autonomous stock task.

A declaration is not enforcement (plan §1.2). The table below is for the legacy patched binding;
the stock runner boundary is described above and in [`adapters/runner-contract/CONTRACT.md`](../runner-contract/CONTRACT.md) §9.

| Claim | Enforced by | Where not enforced |
|---|---|---|
| The worker cannot widen its binding | The binding lives in `data/<task-id>/` in the Firstmate home, outside the worktree | A harness running outside Firstmate's worktree isolation |
| The worker runs the pinned bundle | The bundle is content-addressed under `~/.agent-kit/pins/<sha256>/`, and the binding names the hash | Nothing stops a worker reading another copy; the review of its receipts is what catches it |
| A child does not push, merge, open a PR, run `fm-*` or no-mistakes, or write outside its destination | `hooks/child-guard.sh`, on Claude Code | Every other harness: the rule is prose in the brief and nothing more |
| A child does not run `ak firstmate bind`, `install` or `remove`, or name the binding ledger | `hooks/child-guard.sh`, on Claude Code, as a token-matching tripwire (§6) | Shell indirection; the main-thread worker; every other harness |
| The pipeline creates no unreviewed commit | Legacy transport uses `--skip review,document,rebase` plus `auto_fix.{test,lint,ci}: 0`, which legacy preflight requires | A repository whose trusted config is changed after preflight |
| The ship decision is the lifecycle's | super-ship's preconditions: receipts and a verdict bound to the shipped snapshot, and, for the autonomous form, trusted evidence ([`adapters/runner-contract/CONTRACT.md`](../runner-contract/CONTRACT.md) §2) | A worker that pushes by hand; Firstmate's done gate then sees a head with no receipts |

The child guard can tell a child from its parent only because the host says so. Claude Code's
PreToolUse input carries `agent_id` and `agent_type` for a call made inside a subagent and omits
both for the main thread; that was observed on Claude Code 2.1.281, and the guard acts on no other
signal. A host version that stops sending those fields turns the guard into a no-op, so
`ak firstmate preflight` names the host version it last verified and the guard's tests pin the
input shape.

---

## 6. Deprecated legacy binding delegated authority

For review-start authority, see [ADR-0013](../../docs/decisions/0013-model-starts-super-review.md).
super-ship stays `explicit-or-delegated`: a human starts it,
or a delegated controller does under a validated grant. Under Firstmate, Firstmate is that controller
and the binding it wrote is the grant (ADR-0004). `ak firstmate grant --binding <path> --operation
<op>` validates it and prints a grant record, or refuses with a reason and a `needs-decision` hint.
With a `mock` evidence store it also keeps that record at `<store>/<run_id>/grants/<operation>.json`,
where the §4 audit reads it.

| Operation | Granted when the binding requires |
|---|---|
| `review.full` | `review-full` |
| `review.readiness` | `review-readiness` |
| `ship.prepare` | `ship-preflight`; the grant authorizes the binding's `delivery.action` and never a merge. The autonomous form still requires trusted evidence and stops without it |

Every grant also requires that the binding validates against its schema; that it is the binding
`ak firstmate bind` registered, unmodified, in agent-kit's ledger at
`~/.agent-kit/firstmate/bindings/<run_id>.json` (same real path, same sha256); that it lies outside
the worktree the grant is asked from and outside the bound project; and that the pinned bundle still
hashes to the bound hash. A same-user worker can still run bind itself or edit the ledger, which
the brief forbids; the child guard's denial of both is a tripwire for subagents, not a boundary, and
does not cover the main thread. `ak firstmate status complete` and `status --verify` detect it by
comparing each kept grant record's `binding_sha256` and `binding` path with the ledger entry (§4); a
worker that rewrites the ledger and the grant records consistently still passes. Preventing it needs the
runner's validated grants (ADR-0004). Any other operation, merge and scope changes included, is
refused. The worker then reports `needs-decision` and Firstmate decides or asks the captain.

### Bypass, for one task

A bypass grant is the other route, and it needs neither a binding nor the patches (ADR-0008).
Firstmate writes it with the bundle's gate script, run by `node` with its home as the working directory:
`node <agent-kit bundle>/bin/ak-gate.mjs bypass grant --task <id> --by <who> --reason <why> --out
data/<task-id>/bypass.json --project <repo> --worktree <task worktree> --hours 12`, and pastes the
section it prints
into the brief. Never run it through `bun` or from a project directory: `bun` loads the working
directory's `bunfig.toml` and `.env` first, which a worker can write (SUPERVISOR.md). The worker runs
`node <agent-kit bundle>/bin/ak-gate.mjs bypass check --grant <path> --task <id> --phase <phase>` before
the human-started phases covered by ADR-0008; exit 0 is the start. Review may also use that route,
but does not require it (ADR-0013).
The grant is start-only: every approval inside those phases still reaches Firstmate as
`needs-decision`, and merge and deploy are never on it. The task id must equal the grant's, and the
check must run from inside the task's worktree the grant names (`--project` cannot stand in for it);
a grant holds in each run of its task while that run is its branch's current run, the ticket's run
super-build opens included, until it expires at most 12 hours after it was issued. Gate records made
with `--bypass <path> --task <id>` carry
`authority.mode: bypass` and who authorized it. A phase started under a grant that has since expired
continues under a fresh grant for the same task and worktree in the same run, whose record names the
one it supersedes, or under the typed command, which records `authority.mode: explicit` with
`superseded_grant_id` and ends the bypass for that phase in the run. The end is read from the run's
use records in the evidence store, which the worker can write, so it guards against accidents, not a
determined worker; the worker never writes `~/.agent-kit`. A grant for another task or worktree is
refused, and a gate recorded
by hand cannot be relabelled with `--bypass` at the same snapshot.

`grant` refuses to run from inside any worktree of the repository or under the home's `projects/`,
or to write inside a worktree or the git directory, and it records the issuing directory, host and
home. `check` refuses a grant that is unregistered, copied, edited, expired, for another repository
or inside a worktree, and judges only the bytes it opened. A same-user worker can still issue a grant
from elsewhere: this guards against accidents and shortcuts, not a determined worker. Firstmate
accepted that limit on the captain's behalf on 2026-10-01 (ADR-0008); an out-of-account issuer is
the follow-up.
