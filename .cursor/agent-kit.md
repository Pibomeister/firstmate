# Agent-kit Cursor overlay

This directory vendors the [agent-kit](https://github.com/Pibomeister/agent-kit) Cursor host bundle so Cursor Cloud Agents and Cursor IDE agents in this repository load catalog skills, custom subagents, and `/super-review`.

There is no `ak install --host cursor`.
Cursor discovers `.cursor/skills/<id>/SKILL.md`, `.cursor/agents/<slug>.md`, and `.cursor/rules/*.mdc`.
Start review with `/super-review` and a mode of `full`, `readiness`, or `delta`.
`delta` stays inside an open run.
This overlay does not replace Firstmate's supervisor contract in the repository-root `AGENTS.md`.

## Pin

- Package: agent-kit `0.1.82`
- Source: https://github.com/Pibomeister/agent-kit
- Commit: `fb56d42d45dae453cb1dd76540b5b2d6ebc88ee0` (merge of PR #204, the Cursor host adapter)
- Host: `cursor`
- Profile: `core`

`isolated-review-context` is still `partial` upstream.
This overlay does not claim attested independent review or strict Cursor support.
Firstmate's tracked `.cursor/hooks.json` is not part of the bundle and must stay in place.

Recorded with `sha256sum .cursor/bin/ak .cursor/bin/ak-gate.mjs` at that commit.
`bin/fm-agent-kit-pin.sh` checks these two lines against the files on disk.

```
27b1bdc459ffd50cf62f21b2f2473f9d08f8935c6b63adb8fe33c0ffa9f1d1f3  .cursor/bin/ak
eaee112a741a085c9f6daa0eca4d6c161d65b694e36799a3b227fd04f1d51e79  .cursor/bin/ak-gate.mjs
```

## Licenses

The bundle's top-level `LICENSE`, `NOTICE`, `LICENSES/`, and `provenance/licenses/` live under [`.cursor/LICENSES/agent-kit/`](LICENSES/agent-kit/).
That tree includes the Apache-2.0 `thedotmack_claude-mem` license and notice.

## super-review on a branch or pull request

1. Open a Cloud Agent (or IDE Agent) on the branch or PR.
2. Start `/super-review` with the mode (`full`, `readiness`, or `delta` inside an open run).
   An agent doing the work may start `full` and `readiness` (ADR-0013); that start is not approval.
3. For each reviewer seat, dispatch the matching subagent under `.cursor/agents/` (for example `reviewer-standards.md`, `reviewer-spec.md`, `code-review-security.md`).
   Each subagent has its own context window.
   Reviewer files set `readonly: true`.
4. The parent must not paste the author's narrative into a reviewer prompt.
   Isolation is conventional: Cursor does not attest excluded lineage.
5. Close findings only with independent verification evidence.
   The author does not sit a reviewer seat.

Project skills live in `.cursor/skills/<id>/SKILL.md`.
Type `/` in Agent chat and pick the skill, or let Agent load it from the description.
Human-started skills still require the turn to begin with `/<id>`.
Every authored catalog skill is under `.cursor/skills/`.
Every authored catalog role is a `.cursor/agents/<id>.md` subagent.
`.cursor-plugin/` is not vendored; Cloud Automations load the repository `.cursor/` overlay, not a local plugin install.

## Refresh

Clone agent-kit at the desired commit outside this repository, install bun dependencies, and build into an empty directory:

```sh
bun run ak build --host cursor --out /tmp/ak-cursor
```

`--out` refuses a directory that already holds non-bundle files.
Copy the overlay trees with `rsync -a` as `adapters/cursor/CONTRACT.md` specifies: `skills/`, `agents/`, `rules/`, `roles/`, `references/`, `schemas/`, and `bin/`.
Also copy `templates/`: the Cursor host contract's rsync list omits it, but `.cursor/agents/trail-auditor.md` and `.cursor/roles/trail-auditor/ROLE.md` link to `.cursor/templates/trail-audit.example.json`.
Do not copy `.cursor/adapters/`; nothing in the vendored discovery trees links into that extra root.
Copy `catalog.yaml` with `cp -n` so an existing catalog is not overwritten.
Copy the bundle's top-level `LICENSE`, `NOTICE`, `LICENSES/`, and `provenance/licenses/` into `.cursor/LICENSES/agent-kit/`, keeping `NOTICE` alongside `LICENSE` and `provenance/licenses/` for the claude-mem texts.
Refresh the two `sha256sum` lines in this file from `.cursor/bin/ak` and `.cursor/bin/ak-gate.mjs`, then run `bin/fm-agent-kit-pin.sh`.
Merge a newly generated root `AGENTS.md` section rather than replacing Firstmate's supervisor contract.
Keep that overlay section a short pointer: it does not replace the supervisor contract, reviewer isolation is `partial`, and super-review runs as `/super-review full|readiness|delta`.
Do not copy `.cursor-plugin/`, `.cursor/hooks.json`, or `.cursor/environment.json`.
Check for path collisions with Firstmate's existing `.cursor/` files before copying, and keep Firstmate's copies on a conflict.
