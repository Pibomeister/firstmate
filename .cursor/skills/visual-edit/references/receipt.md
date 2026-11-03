# The applied-edit receipt

Used from `../SKILL.md`, step 11 and Outputs. One `verification` receipt is written per applied
handoff. Start from [the template](../assets/receipt.example.json): keep every member, replace
every value with what this run observed, and write the result as JSON.

Check the finished receipt against the rules below before any acknowledgment. They restate
[`schemas/verification.schema.json`](../../../references/shared/schemas/verification.schema.json) for the members this skill writes, so the check does not depend
on that file being at hand. A receipt that breaks a rule does not validate, and the run ends `failed`.

| Member | Rule |
|---|---|
| `schema`, `schema_version`, `kind` | Exactly `verification`, `1` and `probe`. |
| `id`, `run_id` | Letters, digits, `.`, `_`, `:` and `-`, starting with a letter or digit, at most 128 characters. |
| `project.id`, `environment.id` | Lowercase letters and digits in words joined by single hyphens, at most 64 characters. No dot, colon or slash: an address belongs in `probe.target`. |
| `project.repo`, `source_revision.repo` | The repository's identity, the same value in both. |
| `created_by` | `role`, `skill` and `entrypoint` as the template has them. |
| `inputs` | An empty list, unless the run was handed schema-bound artifacts. |
| `source_revision.revision` | The full commit id of `HEAD`, 40 hexadecimal characters. |
| `source_revision.diff_hash` | The applied edit is uncommitted, so this is present: sha256 over `git diff --no-ext-diff --binary <revision>`, untracked files included as intent-to-add. |
| `created_at` | The time of writing as an RFC 3339 timestamp, such as `2026-10-02T09:00:00Z`. |
| `status` | `passed` only when the dev server showed the edit on every affected route; `failed` otherwise. |
| `output_digest` | Digest of the response the dev server returned. Required with either status. |
| `probe` | `name` and `target` are non-empty strings, `parameters` is an object and `observed` is a string. Nothing else goes inside it. |
| `probe.parameters` | `route`, `viewport` and `revision`. Where the pull returned no revision: `handoff_digest` in its place, and `acknowledgment: none`. |
| `artifacts` | One entry per changed source file: `path` relative to the repository root, with no leading slash and no `..`; `digest` of the file as written; `kind` is `artifact`. |
| `environment` | `id`, `isolated` as a boolean and `secrets_policy`, which is `none` for a local dev server holding no credentials. Nothing else is needed. |
| `supports` or `no_criteria` | Exactly one of them. `supports` is a non-empty list of supplied criterion ids of the form `AC-1`. With no criteria supplied, leave `supports` out and write `no_criteria` as a sentence naming what the running app showed. An empty `supports` list is refused, and so are both together. |
| Every digest | `sha256:` followed by 64 lowercase hexadecimal characters. |
| Anything else | A top-level member the template does not carry is refused. Narrative goes in an optional `notes` string, which is not evidence. |
