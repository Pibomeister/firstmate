# Agent-kit Cursor overlay

This directory vendors the [agent-kit](https://github.com/Pibomeister/agent-kit) Cursor host bundle so Cursor Cloud Agents and Cursor IDE agents in this repository load catalog skills, custom subagents, and `/super-review`.

There is no `ak install --host cursor`.
Cursor discovers `.cursor/skills/<id>/SKILL.md`, `.cursor/agents/<slug>.md`, and `.cursor/rules/*.mdc`.
Start review with `/super-review` and a mode of `full`, `readiness`, or `delta`.
`delta` stays inside an open run.
This overlay does not replace Firstmate's supervisor contract in the repository-root `AGENTS.md`.

## Pin

- Package: agent-kit `0.1.86`
- Source: https://github.com/Pibomeister/agent-kit
- Commit: `ebb7f5f0de8d0ea247769e8649512cbe20f67cf2` (merge of PR #207)
- Host: `cursor`
- Profile: `core`

`isolated-review-context` is still `partial` upstream.
This overlay does not claim attested independent review or strict Cursor support.
Firstmate's tracked `.cursor/hooks.json` is not part of the bundle and must stay in place.

Recorded with `sha256sum .cursor/bin/ak .cursor/bin/ak-gate.mjs` at that commit.
`bin/fm-agent-kit-pin.sh` checks these two lines against the files on disk.

```
14ab6372ce2ee5d78bae94cffe2a9270b78b9ea963e959d92c599e859762f89d  .cursor/bin/ak
2311241a91dfa68c7cd5f838e248f0da776bcb001fbb0a033884f9d897cfc58b  .cursor/bin/ak-gate.mjs
```

## Licenses

Licence and attribution files ship at [`.cursor/licenses/`](licenses/) under their original paths: `LICENSE`, `NOTICE`, `LICENSES/*`, and `provenance/licenses/*`.
That tree includes the Apache-2.0 `thedotmack_claude-mem` license and notice.
Vendor steps never write this repository's root `LICENSE`, `NOTICE`, or `LICENSES/`.

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
Copy the overlay trees with `rsync -a` as `adapters/cursor/README.md` specifies (identical to CONTRACT §5): `skills/`, `agents/`, `rules/`, `roles/`, `references/`, `schemas/`, `templates/`, `bin/`, and `licenses/`.
Do not copy `.cursor/adapters/`; nothing in the vendored discovery trees links into that extra root.
The documented `cp -n` of `.cursor/catalog.yaml` will not replace an existing catalog; overwrite `.cursor/catalog.yaml` with the upstream file so the recorded version is not left stale.
Refresh the two `sha256sum` lines in this file from `.cursor/bin/ak` and `.cursor/bin/ak-gate.mjs`, then run `bin/fm-agent-kit-pin.sh`.
Merge a newly generated root `AGENTS.md` section rather than replacing Firstmate's supervisor contract.
Keep that overlay section a short pointer: it does not replace the supervisor contract, reviewer isolation is `partial`, and super-review runs as `/super-review full|readiness|delta`.
Do not copy `.cursor-plugin/`, `.cursor/hooks.json`, or `.cursor/environment.json`.
Check for path collisions with Firstmate's existing `.cursor/` files before copying, and keep Firstmate's copies on a conflict.
