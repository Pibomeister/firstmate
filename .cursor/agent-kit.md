# Agent-kit Cursor overlay

This directory vendors the [agent-kit](https://github.com/Pibomeister/agent-kit) Cursor host bundle so Cursor Cloud Agents and Cursor IDE agents in this repository load catalog skills, custom subagents, and `/super-review`.

There is no `ak install --host cursor`.
Cursor discovers `.cursor/skills/<id>/SKILL.md`, `.cursor/agents/<slug>.md`, and `.cursor/rules/*.mdc`.
Start review with `/super-review` and a mode of `full`, `readiness`, or `delta`.
`delta` stays inside an open run.
This overlay does not replace Firstmate's supervisor contract in the repository-root `AGENTS.md`.

## Pin

- Package: agent-kit `0.1.106`
- Source: https://github.com/Pibomeister/agent-kit
- Commit: `e1716acfc4be6691a6462dc77cba727a11d8d77e` (`v0.1.106`)
- Host: `cursor`
- Profile: `core`

`isolated-review-context` is still `partial` upstream.
This overlay does not claim attested independent review or strict Cursor support.
Firstmate's tracked `.cursor/hooks.json` is not part of the bundle and must stay in place.

Recorded with `sha256sum .cursor/bin/ak .cursor/bin/ak.js .cursor/bin/ak-gate.mjs .cursor/environment.json tools/cursor/install.sh tools/cursor/bun-v1.3.14.sha256` at that commit.
`bin/fm-agent-kit-pin.sh` checks these six lines against the files on disk.

```
6df9b52c31bbd16e199349cee2c0ad33355e528199d978e88193ade79c63cfbc  .cursor/bin/ak
ff0855da89386fda752efb20d56b884c8ad5ceb5260a3fb1847ee270864fd506  .cursor/bin/ak.js
b1615ebfe0f15cbcd7b99e3efa4b8f7265b47279ddda50d4abd04ce614de6a9a  .cursor/bin/ak-gate.mjs
edb46699507fe67aa5c0b73c82dcaa4aaa9b5abf1ba2a9b1a54a01c663a96a58  .cursor/environment.json
3e343b3d74a15d1240da284f4cc90c72f27741db4df6abf650270afa42ef7020  tools/cursor/install.sh
3d622cb47b53a08e66f9e0d6c81186cd179c6f90917c07f9cf7a55800e49cd37  tools/cursor/bun-v1.3.14.sha256
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

## Review settings

This repository's agent-kit project record is [`ak.project.json`](../ak.project.json).
Pass that path as `--project` only to `.cursor/bin/ak delegation`.
The runner names `ak.project.json` as the project record in the `/doc-review` prompt, with no CLI flag.
The GS-003a dogfood confirms whether `/doc-review` honors that record.
`/super-bound` cold_read reads only the indexed project record (vendored [super-bound SKILL.md](skills/super-bound/SKILL.md) lines 142-143), so it is expected to stay off until a kb index exists.
The GS-003a run will confirm this.
There is no knowledgebase index, and an unindexed project counts as off.
The Cursor overlay `ak` does not auto-discover a project file and does not expose `ak validate`.
Keep `review.cold_read` off `on` until GS-004k ships.

## Bun

The overlay launcher `.cursor/bin/ak` requires bun `1.3.14`.
`tools/cursor/install.sh` is for Linux and Cursor cloud agents only.
On Apple-silicon macOS it would install a Linux ELF.
For macOS, install exactly bun `1.3.14` with `curl -fsSL https://bun.com/install | bash -s "bun-v1.3.14"` ([Bun docs: Installing Older Versions](https://bun.com/docs/installation#installing-older-versions); the documented example uses `bun-v1.3.3` and the same `bash -s` tag form).
The bun.com installer has no checksum pin, unlike the Linux route, and it replaces any existing `~/.bun/bin/bun`.
`tools/cursor/install.sh` and `tools/cursor/bun-v1.3.14.sha256` are vendored from agent-kit `v0.1.106` (`e1716acf`).
The Linux install puts bun `1.3.14` at `~/.bun/bin/bun`.
It skips `bun install --frozen-lockfile` because this repository has no `bun.lock`.

## Refresh

Clone agent-kit at the desired commit outside this repository, install bun dependencies, and build into an empty directory:

```sh
bun run ak build --host cursor --out /tmp/ak-cursor
```

`--out` refuses a directory that already holds non-bundle files.
Copy the overlay trees with `rsync -a` as `adapters/cursor/README.md` specifies (identical to CONTRACT §5): `skills/`, `agents/`, `rules/`, `roles/`, `references/`, `schemas/`, `templates/`, `bin/`, and `licenses/`.
Do not copy `.cursor/adapters/`; nothing in the vendored discovery trees links into that extra root.
The documented `cp -n` of `.cursor/catalog.yaml` will not replace an existing catalog; overwrite `.cursor/catalog.yaml` with the upstream file so the recorded version is not left stale.
Copy `.cursor/environment.json`, `tools/cursor/install.sh`, and `tools/cursor/bun-v1.3.14.sha256`.
Keep Firstmate's `.cursor/hooks.json`.
Do not copy `.cursor-plugin/`.
This repository has no `bun.lock`, so after a refresh keep the `install.sh` skip of `bun install --frozen-lockfile`.
Refresh the six `sha256sum` lines in this file from `.cursor/bin/ak`, `.cursor/bin/ak.js`, `.cursor/bin/ak-gate.mjs`, `.cursor/environment.json`, `tools/cursor/install.sh`, and `tools/cursor/bun-v1.3.14.sha256`, then run `bin/fm-agent-kit-pin.sh`.
Merge a newly generated root `AGENTS.md` section rather than replacing Firstmate's supervisor contract.
Keep that overlay section a short pointer: it does not replace the supervisor contract, reviewer isolation is `partial`, and super-review runs as `/super-review full|readiness|delta` in Cursor sessions only.
Check for path collisions with Firstmate's existing `.cursor/` files before copying, and keep Firstmate's copies on a conflict.
