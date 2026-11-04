---
name: visual-edit
description: "Human-started command: it runs only when the human's message begins with `/visual-edit`. On any other request do not load or follow it; tell the human to type that command. Opens named routes from a running local app as URL-backed frames, then applies pending visual revisions through source. Use when a human asks to compare or visually edit real routes. Not for static mock-ups, unimplemented product alternatives, or behavior changes."
license: MIT
metadata:
  ak_catalog_id: visual-edit
  ak:
    mode: manual
    autonomy_unenforceable:
      - "artifact-write is storage only: the host does not compute or check the receipt hash, so envelope hash binding is this package's own work."
---

## When to use

- A human wants to compare real routes or responsive states from a running local app on a visual canvas.
- A human wants style, text or layout edits made visually and then applied to the app's source.

## Not for

- Static mock-ups, copied markup or screenshots. The running routes are the source of truth.
- Comparing unimplemented product alternatives; hand that bounded question to `prototype`.
- Behavior, state-model or cross-file changes; those require an approved ticket for `super-build`.
- Runtime verification without a visual editing session; that belongs to `verify` or `super-verify`.

## Authority

Authority: `explicit`. A human starts it with `/visual-edit`; no grant or prose request starts it.

## Inputs

- The Design editor hosted at `https://design.agent-native.com`, reached through its MCP connector
  or WebMCP; no local editor is started. Unavailable: `missing-prerequisite:editor-connector`.
  It opens designs and pulls handoffs; only the MCP connector returns a revision and takes its
  acknowledgment. Applying a supplied handoff needs it only to acknowledge.
- The `@agent-native/core` CLI. Missing: `missing-prerequisite:bridge-cli`. The bridge token and
  the daemon on `127.0.0.1:7331` are made by the run, not brought to it.
- Only to save or share the design: an account on the editor. Opening routes, comparing
  viewports and applying pending edits run signed out. Missing when a save or share is asked for:
  `missing-prerequisite:editor-account`.
- A local dev server, repository root, requested route paths and named viewports. A server that is
  down is started with the project's own dev command; a route that still does not respond is
  `missing-prerequisite:dev-server`, with that route named.
- Optional named acceptance criteria. They let the resulting receipt enter `super-verify`'s matrix;
  without them the batch is still applied and receipted.

## Workflow

1. Check how the run started before any tool call. If the message does not begin with
   `/visual-edit`, stop and return that exact command.
2. Freeze the repository root, dev-server URL, ordered routes and viewports. If the
   request is for a not-yet-built alternative, hand the bounded question to `prototype` and stop.
3. Check the editor connector, the CLI and the dev server by using them; an address or status
   declared in a project file is configuration, not evidence. Stop on the first missing id; never
   replace a missing editor, bridge or dev server with a static preview. When the human supplies
   an already pulled handoff, check only the dev server here and go to step 9.
4. Probe every requested route at the dev-server URL. Preserve the human's route labels, order and
   viewports; discover routes, from the CLI's manifest, only when none were supplied.
5. Open the design with the exact routes and viewports. The MCP connector's open call mints the
   bridge token, then step 6 starts the bridge with it. Signed-out WebMCP runs the other order:
   generate the token locally, do step 6 with it, then call `open-visual-edit` with that same
   token. Each screen stays a URL-backed frame with route, URL, bridge and viewport metadata.
6. Start the durable bridge, or reuse a healthy matching one on 7331, with the token in the
   environment: `AGENT_NATIVE_BRIDGE_TOKEN=<token> npx @agent-native/core@latest design connect
   --url <dev-server> --root <root> --daemon`, never `--json`. Not up: `missing-prerequisite:bridge-daemon`.
7. Before handing over the canvas, verify the connection, every requested route and viewport, each
   frame's `src` rather than `srcdoc`, and the Code panel's local source root plus one opened file.
   A failed check stops with its name; a returned link alone is not readiness.
8. Hand the verified canvas to the human. Visual changes remain pending and never write source from
   the canvas. Preserve the pending batch until it is applied or explicitly discarded. A save or
   share asked for without the account stops with its id and leaves the session as it is.
9. Pull the pending handoff; nothing else pulls. The MCP connector's `get-visual-edit-pending`
   returns it with a revision and `acknowledge-visual-edit-pending` takes that revision. WebMCP's
   `get-visual-edit-prompt` returns it with no revision and has no acknowledgment. A handoff the
   human supplies with its revision is applied and receipted without the connector, which step 11
   still requires to acknowledge. For a compiled route, edit authored source through the coding
   agent. A change beyond style, literal text or local layout stops for an approved ticket, then
   hands the handoff to `super-build`; no partial apply here.
10. A handoff already receipted, its artifact digests still matching source, is never applied
    again: go to step 11. Otherwise read every target file before writing, apply the batch to
    source, and confirm the dev server refreshes each affected route at its named viewport. A
    version conflict is re-read and re-planned, never overwritten.
11. Emit the receipt in Outputs unless it exists. A handoff with no revision ends there. Otherwise
    acknowledge the exact revision, then pull once more; a non-empty pull is another batch. An
    acknowledgment the connector cannot take stops with `missing-prerequisite:editor-connector`;
    the receipt stands and the revision stays pending.
12. When acceptance criteria were supplied, pass the receipt to `super-verify`; it decides whether
    the receipt covers them or whether another check is required.

## Hard gates

Gate: a missing editor connector, CLI, dev server or route stops with its named prerequisite, as
does a bridge that does not come up, and a missing account stops a save or share. For a supplied
handoff the connector stop comes at acknowledgment, after apply and receipt. Never generated markup.

Gate: the running app is the source of truth. Requested screens are URL-backed frames at the named
viewports, never copied markup or static snapshots.

Gate: the connection, frames and Code panel are verified before the human receives the canvas.

Gate: canvas changes remain pending. Compiled routes and source files change only through the coding
agent; a revision is acknowledged only after source application and dev-server confirmation.

Gate: a change beyond style, literal text or local layout is not absorbed here. It requires an
approved implementation ticket and `super-build`.

Gate: an applied batch has a schema-valid receipt bound to source revision and environment, before
any acknowledgment. Narrative is not a receipt (ruling `closure-requires-independent-verification`).

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "The route is down, so a static page is close enough." | It removes the running app from the loop. | Name `missing-prerequisite:dev-server` and stop. |
| "The canvas looks right, so I can acknowledge now." | Pending edits are not source changes. | Apply, confirm the dev server, write the receipt, then acknowledge. |
| "This compiled screen can apply itself." | Canvas edits cannot safely locate authored source. | Pull the handoff and change source through the coding agent. |

## Outputs

- Returned canvas session data: design URL, design and connection ids, ordered routes, named
  viewports, and the completed pre-handoff checklist. Tokens are excluded.
- For each applied handoff, a `verification` receipt ([`schemas/verification.schema.json`](../../references/shared/schemas/verification.schema.json)) made from
  [the receipt template](assets/receipt.example.json) under [its rules](references/receipt.md):
  probe parameters name route, viewport and the revision or, where the channel returned none, the
  handoff digest and that no acknowledgment channel exists; `artifacts` names every changed source
  file with its digest; `source_revision` binds the code; `observed` records the dev-server
  confirmation. `supports` lists supplied criteria; with none, `no_criteria` names what the app showed.
- When the edit exceeds this skill's boundary, the unchanged pending revision and the approved
  ticket requirement are handed to `super-build`; no partial source edit is an output.

## Side effects

`workspace-write`, `process-exec`, `artifact-write`, `external-fetch`. No commit, push or direct
canvas-to-source write. Account and bridge secrets stay process-local and never enter outputs.

## Stop conditions

- `complete`: the verified canvas is ready with no pending batch, or one batch is applied, confirmed
  and receipted, and acknowledged when its pull returned a revision.
- `needs-input`: invocation or a named prerequisite is missing, or a non-style change lacks an
  approved implementation ticket.
- `failed`: the editor or bridge rejects the connection, source conflicts cannot be reconciled, the
  dev server does not reflect the write, or the receipt cannot validate. Leave the revision pending.
- `cancelled`: stop before the next write and leave any unapplied revision pending and unacknowledged.

## Limits

- Missing prerequisites: 0 (gate). Static output never substitutes for a missing prerequisite.
- Frames per focused batch: 3-7 (guidance). Use exactly the requested routes and viewports; expand
  beyond seven only for an explicit exhaustive request.
- Direct application: style, literal text and local layout only (gate). Broader work enters
  `super-build`; alternatives enter `prototype`; acceptance evidence enters `super-verify`.
