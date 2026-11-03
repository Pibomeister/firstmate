---
name: wayfind
description: "Human-started command: it runs only when the human's message begins with `/wayfind`, or under a validated grant. On any other request do not load or follow it; tell the human to type that command. Charts work too large for one session as a shared map of decision tickets, then resolves them one at a time until the way to the destination is clear. Use when a loose effort is wrapped in fog. Not for work whose route is already visible, and not for executing an agreed plan."
license: MIT
metadata:
  ak_catalog_id: wayfind
  ak:
    mode: manual
---

Map longer work into decision tickets and implementation tickets. A decision ticket can never be
dispatched to an implementer as though approved.

## When to use

- A loose effort has arrived that one session cannot hold, and the way from here to the destination
  is not visible yet.
- Several decisions are open, they depend on each other, and nobody can say which is takeable now.
- Work spans sessions or people and each session needs to orient without rereading everything.
- A delegated controller holds a charter naming the `ticket-approval` checkpoint and needs the
  effort decomposed before any of it is dispatched.

## Not for

- An effort whose route is already clear and small enough for one session. Charting it produces a
  map with no fog in it; say so and ask how the human wants to proceed.
- Turning an approved direction into a specification and tickets to build. That is `super-bound`.
- Resolving the alignment question a `grilling` ticket holds. That ticket goes back to a
  human-started run of the alignment skill; this skill charts the question and never answers it on
  the human's behalf (ruling `entrypoint-phase-operation-split`).
- Executing the destination. The pull to do the work rather than decide it is the signal the map has
  reached its edge and the effort is ready to hand off.
- Tracking ordinary delivery on an effort whose decisions are all made. That is the tracker's job,
  not a map's.

## Authority

Authority: `explicit` at the public entrypoint, `delegated-grant` at the phase operation
`wayfind.map`. A human starts the public entrypoint by typing `/wayfind`. A request in prose is
not a start, even when it names this skill or the command. A delegated controller starts
`wayfind.map` only under a runner-validated grant covering `ticket-approval`
([`adapters/runner-contract/CONTRACT.md`](../../references/shared/adapters/runner-contract/CONTRACT.md)). Where the host cannot validate that grant, the operation
stops for explicit invocation rather than dispatching what it mapped (ruling
`entrypoint-phase-operation-split`). This skill may start `/ak:research` and `/ak:prototype`, which
are model-invoked; it may not start a user-invoked skill, which is why a `grilling` ticket is handed
back rather than resolved here.

## Inputs

- At charting: a loose statement of the effort, from the human. Absent: `needs-input`.
- At working the map: the map's identity. Without one, this skill picks the next frontier ticket;
  the human is not asked to.
- The system of record for tickets, decided by configuration and never by reachability
  ([`adapters/tracker/CONTRACT.md`](../../references/shared/adapters/tracker/CONTRACT.md) §2; ruling `tracker-of-record-falls-back-to-kb`):
  - The project folder binds a tracker (`ak.tracker.yaml`) and the project record names the same
    system, or there is no record: that tracker.
  - A bound tracker whose system the project record does not name: `needs-input`. Obeying the
    binding would make a second system of record.
  - No binding, and the record names `knowledgebase` or there is no record: the knowledgebase,
    read through its adapter's `readContext`.
  - No binding while the record names an external tracker: `needs-input`. The knowledgebase does
    not stand in for an unreachable tracker of record.
  - Nothing available: `needs-input`, because a map nobody else can read is not a shared map. The
    map is never kept in the session or written into the working repository instead.
  The binding and its guarded invocation are in the
  [tracker-of-record reference pack](../../references/shared/references/tracker-of-record/REFERENCE.md).
- At `wayfind.map` only: a `charter` ([`schemas/charter.schema.json`](../../references/shared/schemas/charter.schema.json)) listing `ticket-approval`.
  Absent: `needs-input`.

## Workflow

1. Check how this run was started, before any other step and before any tool call. It is started
   only when the human's message begins with `/wayfind`, or when a controller started the phase
   operation `wayfind.map` under a validated grant. A request in prose is not a start, even when it
   names this skill or the command. With neither, stop here: make no tool call, say that this
   command is human-started, and give the human the line to type, `/wayfind` and their request.

**Chart the map.**

2. Name the destination: the specification, the decision or the change this effort is finding its
   way to. Grill it inline until it is one sentence a reader could hold the whole effort against.
   The destination fixes the scope, so it is settled first and everything else is measured from it.
3. Map the frontier breadth-first: fan out across the whole space rather than deep on one thread,
   surfacing the open decisions and the steps takeable now. If this surfaces no fog, stop: there is
   no map to draw. Say so and ask the human how they want to proceed.
4. Write the map with five parts: Destination, Notes, Decisions so far (empty at charting), Not yet
   specified, Out of scope. The map is an index, not a store: a decision lives in its ticket, and
   the map gists it and links.
5. Create the tickets you can state sharply now, then wire the blocking edges in a second pass,
   because a ticket needs an identity before another can reference it. Everything you cannot yet
   phrase sharply stays in Not yet specified.
6. Dispatch `/ak:research` for each research ticket created, in parallel, and link each finding from
   its ticket. Hand back every `grilling` ticket for a human-started alignment run.
7. Stop. Charting is one session's work and resolves nothing.

**Work through the map.**

8. Load the map at low resolution, not every ticket body, and orient to the destination before
   choosing anything.
9. Choose the ticket the human named, or the first frontier ticket in order — open, unblocked and
   unclaimed. Claim it before any work: the tracker's native assignment where a tracker is the
   system of record, and otherwise by asking the runner for exclusive access to the record, because
   the knowledgebase adapter implements no locking and neither does this body
   ([`adapters/knowledgebase/CONTRACT.md`](../../references/shared/adapters/knowledgebase/CONTRACT.md), "Known limitation").
10. Resolve it by its type: `research` alone, `prototype` by dispatching it and linking the
    artifact, `task` by doing the work that unblocks a decision, `grilling` never here.
11. Record the resolution on the ticket, close it, and append one line to Decisions so far: the gist
    and the link, referred to by name.
12. Graduate whatever fog the answer sharpened into new tickets, clearing each graduated patch from
    Not yet specified so it lives in one place only. Where the answer shows a ticket sits past the
    destination, close it and write one line in Out of scope: the gist and why, linking the closed
    ticket.

## Hard gates

Gate: a decision ticket is never dispatched to an implementer as though approved. An open decision
is open however obvious the answer looks; a ticket whose question is unresolved does not become
work by being handed to someone.

Gate: one ticket per session, research tickets excepted. A second decision resolved in the same
session is resolved with the first one's context still weighing on it.

Gate: a ticket is claimed before any work on it, never after.

Gate: ruling something out of scope requires the gist and the reason, written on the map. Out-of-
scope work never graduates; it returns only if the destination is redrawn, and then as a fresh
effort.

Gate: a human-in-the-loop ticket resolves only through the live exchange. An agent that answers the
human's side of a `grilling` or `prototype` ticket has broken the ticket, not resolved it.

Gate: charting requires a system of record other sessions can read. A human waiver does not create
one, and permission to copy a session-only map later does not make that session shared. When neither
the external tracker nor the knowledgebase can hold the map, stop before charting with `needs-input`
naming `tracker-access` and `kb-write`.

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "This decision is obvious — I'll hand the ticket straight to an implementer." | An open decision ticket carries no approval. Obvious to the mapper is not decided by the human who owns the destination. | Leave it on the frontier and route the question to a human-started alignment run. |
| "I know how the human would answer this grilling ticket, so I'll answer it and move on." | A human-in-the-loop ticket resolves only through the live exchange; an agent standing in for the human's side is the failure this type exists to prevent. | Hand the ticket back and let the human's own run resolve it. |
| "The first ticket went quickly — I'll take one more before the session ends." | The second decision is made with the first one's context still weighing on it, which is the bias the one-per-session rule exists to break. | Stop after the one. Research tickets are the only exception. |
| "This question is inconvenient and off the critical path — I'll mark it out of scope." | Scope, not convenience, puts work out of scope, and an unjustified closure hides an open decision behind a section that never graduates. | Either write the gist and the real reason it sits past the destination, or leave it on the frontier. |
| "I can see roughly four things coming — I'll pre-slice the fog into four tickets now." | The test is whether the question can be stated precisely now, not whether it can be answered. A fog patch may graduate into several tickets or none. | Leave it in Not yet specified until the frontier reaches it. |
| "The human said they will copy this map out of the chat later, so the session can be the record for now." | A promise to copy is not a record another session can read, claim or update, and a human waiver cannot supply either adapter capability. | Stop before charting with `needs-input` naming `tracker-access` and `kb-write`. |

## Outputs

- `map` ([`schemas/map.schema.json`](../../references/shared/schemas/map.schema.json)) — the five sections and the ticket set, published through the
  knowledgebase adapter's `publishArtifact` under a `run-artifact` placement, or written to the
  external tracker where the project has one. No documentation tree in the working repository and
  no hardcoded knowledgebase path (ruling `central-kb-owns-project-artifacts`).
- `ticket` ([`schemas/ticket.schema.json`](../../references/shared/schemas/ticket.schema.json)), `type: decision`, id shape `map-<effort>-<question>` —
  one per sharp open question, blocked by the tickets it waits on. Every ticket this skill cuts is
  a decision ticket, the `task` kind included: its manual work exists to unblock a decision. A map
  spans both ticket types, because the implementation tickets that come out of `super-bound` once
  a destination is specified hang off the decisions made here; this skill cuts the decision half
  and never the other.
- Resolution records — the answer on the resolved ticket plus its one-line gist on the map.
- At `wayfind.map`: the map and the ticket set as run artifacts only. That operation publishes
  nothing and dispatches nothing.

## Side effects

`artifact-write`, `scratch-write`, `kb-draft`, `kb-publish`, `tracker-write`. No `workspace-write`:
this skill decides and never builds.

`kb-publish` and `tracker-write` are remote side effects. The idempotency key for each derives from
the run, the operation, the record's stable remote identity and the artifact's hash; the read-back
is the record the write returns, read before the write and confirmed after it
([`adapters/runner-contract/CONTRACT.md`](../../references/shared/adapters/runner-contract/CONTRACT.md), "Idempotency"). A write whose read-back cannot be performed
is `failed`, never complete.

## Stop conditions

- `complete` — the frontier is empty, nothing remains in Not yet specified, and the way to the
  destination is clear with nothing left to decide.
- `complete` — charting surfaced no fog. The map is not drawn and the reason is reported.
- `needs-input` — a start by neither the typed command nor a validated grant, no effort statement,
  no system of record, a missing grant at `wayfind.map`, or a ticket whose resolution belongs to a
  human-started run. The first returns the command to type and nothing else. With no system of
  record it names both `tracker-access` and `kb-write`; a human waiver does not change that
  result.
- `cap-reached` — one ticket has been resolved this session. Returns the updated map and the
  frontier, and takes nothing further.
- `failed` — the system of record is unreachable, or a write's read-back cannot be performed.

## Limits

- Tickets resolved per session: 1 (gate). Research tickets do not count against it.
- Ticket size: one question that one session can hold (guidance).
- Blocking edges: the tracker's native dependency relationship where it has one, so the frontier
  renders in the tracker's own view; a body convention only where it does not (guidance).
- Claim atomicity: none. The claim narrows a race between concurrent sessions and does not close it;
  exclusive access is the runner's to grant.
