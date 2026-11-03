# Agent-kit Cursor overlay

This directory vendors the [agent-kit](https://github.com/Pibomeister/agent-kit) Cursor host bundle so Cursor Cloud Agents and Cursor IDE agents in this repository load catalog skills, custom subagents, and `/super-review`.

There is no `ak install --host cursor`.
Cursor discovers `.cursor/skills/<id>/SKILL.md`, `.cursor/agents/<slug>.md`, and `.cursor/rules/*.mdc`.
Start review with `/super-review` and a mode of `full`, `readiness`, or `delta`.
`delta` stays inside an open run.

## Pin

- Package: agent-kit `0.1.82`
- Source: https://github.com/Pibomeister/agent-kit
- Commit: `fb56d42d45dae453cb1dd76540b5b2d6ebc88ee0` (merge of PR #204, the Cursor host adapter)
- Host: `cursor`
- Profile: `core`

`isolated-review-context` is still `partial` upstream.
This overlay does not claim attested independent review or strict Cursor support.
Firstmate's tracked `.cursor/hooks.json` is not part of the bundle and must stay in place.

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
Merge a newly generated root `AGENTS.md` section rather than replacing Firstmate's supervisor contract.
Do not copy `.cursor-plugin/`, `.cursor/hooks.json`, or `.cursor/environment.json`.
Check for path collisions with Firstmate's existing `.cursor/` files before copying, and keep Firstmate's copies on a conflict.
