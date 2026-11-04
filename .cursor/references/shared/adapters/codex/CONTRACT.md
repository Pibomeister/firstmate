# adapters/codex — host contract

Contract only. No implementation lives here.

The parallel host bundle. This file states what the Codex host provides, what the package requires,
which [`schemas/common.schema.json#/$defs/capability`](../../schemas/common.schema.json#/$defs/capability) values it can satisfy, precisely which of them
**differ from [`adapters/claude-code/CONTRACT.md`](../claude-code/CONTRACT.md)**, what degrades as a result, and how the bundle is
tested.

Observations marked **verified (donor)** were read from the pinned clone at
`compound-engineering@05c42da94fd318fa081f29d17bf947762aa477b1`. Observations marked
**verified (CLI)** were taken from `codex-cli 0.154.0` on this machine, except where §4 names a
later version for the install pair. Observations marked **verified (receipt)** come from the
host-fact receipts under `research/host-facts/2026-10-03/`, taken on `codex-cli 0.153.4` against
the `openai/codex` source tag `rust-v0.153.4` (`3d2ee51`) and the Codex docs fetched that day, and
added with ADR-0009 (`docs/decisions/0009-constitution-support.md`). Each receipt names its own
instrument; a receipt marked *not observed live* rests on source and docs alone, because no Codex
session ran (`research/host-facts/2026-10-03/README.md`, "Live sessions"). §3 and §6 cite each
receipt by path. A fact verified at 0.153.4 is not re-verified at 0.154.0 by being cited here.
Everything else is a requirement on the packager.

---

## 1. The multi-host manifest pattern

The donor pattern this package copies is **parallel per-host manifest directories at the repository
root, over one shared content tree**. Verified (donor) at the pin:

| Path | Contents |
|---|---|
| `.claude-plugin/plugin.json` | Identity only: `name`, `version`, `description`, `author`, `homepage`, `repository`, `license`, `keywords`. **No `skills` key** — the host discovers `skills/` |
| `.claude-plugin/marketplace.json` | `name`, `owner`, `metadata`, and one `plugins[]` entry with `source: "./"` |
| `.codex-plugin/plugin.json` | The same identity fields, **plus** `"skills": "./skills/"` and an `interface` block (display name, descriptions, category, capabilities, icon, brand color, default prompts) |
| `.cursor-plugin/plugin.json` | Identity fields plus `displayName`; different `keywords` |
| `plugin.json` (root), `.kimi-plugin/`, `.grok-plugin/`, `.devin-plugin/` | Further per-host copies of the same identity |

Two properties of the pattern matter more than the file list:

1. **The skill content tree is shared, not duplicated.** All manifests point at the same `skills/`.
2. **Identity parity is machine-enforced.** The donor's release validator reads each manifest and
   fails when a version disagrees with `package.json`
   (`compound-engineering@05c42da:src/release/components.ts`, the `does not match` checks around
   lines 197–213). The donor treats manifest drift as a release-blocking error, not a lint.

A third property is a deliberate divergence rather than a copy. The donor's Codex manifest registers
skills by **directory pointer** (`"skills": "./skills/"`) and its Claude manifest by **discovery**.
This package enumerates explicitly for claude-code ([`adapters/claude-code/CONTRACT.md`](../claude-code/CONTRACT.md) §1) because
its install set is profile-dependent. For codex the packager emits whichever form the target CLI
accepts, and `ak build --check` asserts that the set of skills the codex bundle exposes is identical
to the set the claude-code bundle exposes for the same profile. Divergence between the two bundles is
a build failure, not a host difference.

What this package does **not** copy: the `interface` display block (marketing metadata, out of scope
for a catalog of engineering instructions), and the further host manifests the donor ships for hosts
this package does not target.

**The current host command differs from the donor's comment.** The donor's converter describes
Codex's native plugin flow as
`codex plugin install` reading `.codex-plugin/plugin.json`
(`compound-engineering@05c42da:src/converters/claude-to-codex.ts`, the comment above
`includeSkills`). The installed CLI exposes **`codex plugin add`**, not `install`; an isolated
marketplace install confirmed `add` (§4). Check the target CLI again when its version changes.

---

## 2. Bundle shape

```text
dist/codex/
├── .claude-plugin/marketplace.json # local marketplace registration for Codex CLI
├── .codex-plugin/plugin.json   # identity, skill registration, no interface block
├── skills/<id>/SKILL.md        # generated keys plus Codex-native U explicit-start markers
├── skills/<id>/references/     # U explicit-start markers rendered here and in references/shared/
├── hooks/hooks.json            # the semantic lint Stop hook (§6)
├── LICENSES/                   # licence texts of packages in bin/ak and bin/ak-gate.mjs (NOTICE)
├── provenance/licenses/        # claude-mem licence and NOTICE
└── NOTICE, LICENSE
```

One canonical source tree, with host differences generated at the packaging boundary. Frontmatter
keys follow §3, and exact canonical U-command references are rendered as `$ak:<id>` for this host
(ADR-0011). Ordinary prose is unchanged.

---

## 3. Capabilities: what differs from claude-code

**Every `common#/$defs/capability` value carries the status
[`adapters/claude-code/CONTRACT.md`](../claude-code/CONTRACT.md) §3 gives it, with no per-capability difference on this host.**
That table is the single statement for both hosts and is not restated here — a copy would be a
second thing to keep in step, and the copy that decided would be whichever one the code read. It
was restated here once, as prose naming thirteen of the sixteen capabilities, and the three it
omitted (`isolated-worktree`, `isolated-review-context`, `independent-context`) had no stated
status on this host at all until a parse of the table went looking for them.

What differs on this host is not which capabilities are supplied but which **restrictions** the
host can enforce. None of the rows below is a `capability` value.

The review-session guard ([`templates/guard/review-session.policy.json`](../../templates/guard/review-session.policy.json), for
`ak guard hook pre-tool-use`) denies reads of Claude Code's session store. Codex guard support
is deferred to CS-12 (`research/briefs/constitution-support-plan.md`), so on this host the
transcript-on-disk channel stays uncovered: a review seat can still read the parent's session
transcript, and no package hook denies it. The guard is feedback, not a security boundary on
either host; a missing or crashing hook lets the call through.

Native child sessions are useful fresh execution contexts but do not attest what the child saw or
its excluded lineage. The inherited `independent-context: not-provided` status means host-only
verifier receipts are `host-unattested`; a runner supplies attested independence. The gate counts
such a receipt only in a run that never held a bypass or delegated grant.

| Restriction | claude-code | codex | Consequence |
|---|---|---|---|
| Per-skill suppression of model invocation | `disable-model-invocation: true`, documented host behavior; not emitted by this package (`docs/decisions/0003-model-invocation.md`) | Verified (receipt): `agents/openai.yaml` supports `policy.allow_implicit_invocation: false` at `codex-cli 0.153.4`. It **hides** the skill from the model's skill list and skill tools rather than denying it: an explicit `$<id>` still starts it, and the model can still read the `SKILL.md` through the shell. An `openai.yaml` that fails to parse is ignored with a warning and the policy is dropped silently, so the skill is listed again (`research/host-facts/2026-10-03/codex-7-manual-only-skills.md`). Not emitted by this package | ADR-0003 keeps every skill model-loadable, so the package deliberately relies on the U skill's authority check rather than either host key. See §3.1 |
| Tool restriction | `allowed-tools`, pre-approval only, denies nothing | Not emitted. The host has an OS-level sandbox instead, configured by the operator (`sandbox_permissions`, verified (CLI) in `codex plugin --help`) | Codex's confinement is real but **operator-owned and process-wide**, not per-skill. The package still declares side effects and still relies on neither |
| Bundled behavioral eval runner | `claude plugin eval`, `<eval dir>/**/case.yaml` | **None verified** | The eval corpus is not executable against this bundle by a host-native runner. See §5 |
| Manifest validator | `claude plugin validate --strict` | **None verified** | Bundle validation is `ak validate` plus an install smoke test |

### 3.1 The portable gate that matters: U skills remain model-loadable

Plan §1.3: "Do not assume that a host's manual-invocation flag is portable." Codex documents
`policy.allow_implicit_invocation: false` in `agents/openai.yaml`, but this package deliberately does
not emit it: ADR-0003 keeps every skill model-loadable, and the U skill's first-step authority check
is the portable gate. The key would not be the same restriction in any case: it hides a skill from
the model rather than refusing it, and a malformed `agents/openai.yaml` drops it without an error
(`research/host-facts/2026-10-03/codex-7-manual-only-skills.md`).

For every U skill in the codex bundle:

1. The `description`, rendered from the canonical `SKILL.md`, opens by naming the skill's
   typed command and its class — `Human-started command: it runs only when the human's message
   begins with $ak:<id>`, followed where the skill has phase operations by the other authority that
   may start it — and says what to do on any other request: do not load or follow it, tell the human
   to type that command. Because the package intentionally emits no host suppression key, the
   description is the first layer between a U skill and an unrequested start, so it is written to
   be read that way. `ak validate`'s `human-start` check fails a U skill whose description omits the command
   (`invocation.description-omits-command`) or the class (`invocation.description-omits-class`).
2. The skill's own `## Authority` section names the command and states that a prose request is
   not a start, and its first workflow step is the stop: it names `$ak:<id>`, and started without
   the human's message beginning with it — or, where the skill has phase operations, without a
   runner-validated grant covering the phase — the skill stops, names the command and does nothing
   else. `human-start` fails a U skill whose first workflow step does not name the command or does
   not say to stop (`invocation.first-step-not-stop`).
   Selecting the skill through `/skills` is explicit only when the resulting human turn delivered
   to the skill begins with that `$ak:<id>` mention (ADR-0011). Selection state without the marker, a
   later mention in prose, or the model choosing the skill from its description is not a start.

   The form is `$ak:<id>` because that is the name this host gives a plugin's skill. Probe, with no
   model turn, on `codex-cli 0.159.2`: `codex plugin marketplace add <dist/codex>` and `codex plugin
   add ak@agent-kit` in a scratch `CODEX_HOME`, then `codex debug prompt-input '$ak:super-align …'`.
   The rendered skill list names every skill `ak:<id>` and the user turn is delivered verbatim. The
   probe does not show mention resolution, so a bare `$<id>` resolving to a plugin skill is neither
   confirmed nor relied on: the packaged gate does not accept it.

   The eval harness's Codex cell does not observe this form as a mention. It launches the host with
   plugins disabled and installs the bundle's skills standalone, so a skill is listed there under
   its bare id and a typed `$ak:<id>` resolves to nothing: a typed case passes on the packaged
   prose matching the prefix. That is an accepted limit (ADR-0011); the plugin form rests on the
   probe above. Codex sessions recorded before this bundle gated on `$ak:<id>` are not rescorable
   under the new spelling.
3. The non-trigger eval case for that skill is a **required** gate for this bundle rather than an
   advisory one, because it is the only observation of the property in a live session: the checks
   above hold the text, not the behavior.

Every U skill's `packaging.hosts[]` entry for `adapter: codex` records this explicitly:
`mode: manual`, with the unsuppressed model invocation named in `unsupported`
([`schemas/skill.schema.json`](../../schemas/skill.schema.json)). A U skill declaring anything but `manual` on this host is an
`ak build` error, `packaging.u-skill-not-manual`, and is packaged `manual` regardless; `ak validate`
does not report it, because the packager's plan is where it is decided — the declaration is the
record that the weakening was noticed rather than absorbed.

And the general rule, unchanged from [`adapters/claude-code/CONTRACT.md`](../claude-code/CONTRACT.md) §4: a host that cannot
enforce a restriction an autonomous run requires exposes the skill in guided/manual mode and rejects
autonomous mode. The same section's amendment applies here unchanged: a capability this host does
not provide, but that an attached adapter supplies and fails closed on, is not silently absent and
does not cap the mode; `ak.install.yaml` decides attachment, and with no such file every fail-closed
adapter is attached (ruling `fail-closed-adapter-lifts-ceiling`). A supplier whose §1 names a
fallback lifts only where what it falls back on is available here too: `tracker-access`, with no
tracker backend configured, is lifted only while `kb-write` is ([`adapters/tracker/CONTRACT.md`](../tracker/CONTRACT.md) §1;
ruling `tracker-of-record-falls-back-to-kb`). That amendment reaches
capabilities only. It does not reach the manual-invocation restriction above, which is not a
capability and which no adapter supplies, so every U skill stays `mode: manual` on this host
whatever is attached; and it grants no delegated authority. `profiles/autonomy` does not install
against this host on its own, for the same missing `runner-grants` and `event-delivery`
capabilities.

---

## 4. Install

The command forms are verified against the installed Codex CLI; the isolated `CODEX_HOME` smoke
used a local publication candidate. The GitHub ref needs a post-publication smoke:

```bash
codex plugin marketplace add Pibomeister/agent-kit --ref published
codex plugin add ak@agent-kit
codex plugin list
codex plugin remove <plugin>
```

Verified (CLI), `codex-cli 0.159.2`, for this bundle as a local marketplace. The first command
reads `.claude-plugin/marketplace.json` at the marketplace root and fails without one:

```bash
codex plugin marketplace add <dist/codex>
codex plugin add ak@agent-kit
```

`codex plugin marketplace add` accepts `--ref` for Git sources. The generated `published` branch
contains `.agents/plugins/marketplace.json` pointing at `./dist/codex`. An isolated local
marketplace smoke confirmed add, install and an enabled `ak@agent-kit` in `codex plugin list
--json`. Codex exposes no project-scope option. `ak update` uses `codex plugin marketplace upgrade
agent-kit` followed by `codex plugin add ak@agent-kit`.

---

## 5. Testing

Tests this adapter owns. Item 6 is in `tests/packaging.test.ts`. Item 5 needs the host CLI and
the published branch, so `bun test` does not run it:

1. **Bundle parity** — the skill id set in `dist/codex` equals the skill id set in
   `dist/claude-code` for the same profile. Canonical content is equivalent after reversing the
   ADR-0011 U-command rendering; byte identity is required only where no host rendering applies.
2. **Manifest parity** — `version` and `license` agree across `package.json`,
   `dist/claude-code/.claude-plugin/plugin.json` and `dist/codex/.codex-plugin/plugin.json`.
   `name` and `description` agree between the two manifests and with `catalog.yaml`'s
   `package.id` and `package.description`, and **`package.json` is not a party to either**:
   `package.json` names and describes the npm package, a manifest names and describes what the
   host addresses. They are two names for two objects, so a check that forces them to agree can
   only be satisfied by renaming one of them to suit the check.

   The donor supports the `version` clause and no other. At
   `compound-engineering@05c42da:src/release/metadata.ts` the token `compoundPackage.` occurs
   exactly once — `:283`, comparing `package.json`'s version. Each manifest's description is
   *derived and written* rather than compared (`:259`, `:291-304`), which is why the donor ships
   one description in `package.json` and a different one in `.claude-plugin/plugin.json`; manifest
   `name` is compared manifest-to-manifest (`:403`); and the donor's own `package.json` carries no
   `license` key at all. The `license` clause is therefore this package's own release condition,
   `origin: conversation`, and is marked as such rather than attributed upstream.

   The Codex marketplace's plugin `name` and `metadata.version` agree with
   `dist/codex/.codex-plugin/plugin.json`.
3. **No leaked or suppressed host keys** — neither bundle contains `disable-model-invocation`
   (`docs/decisions/0003-model-invocation.md`), and the codex bundle contains no `allowed-tools`;
   the claude-code bundle contains `allowed-tools` where required. A key outside a host's generated
   set is a failure.
4. **Non-trigger corpus completeness** — every U skill in the codex bundle has a non-trigger eval
   case, and every such case's prompt is drawn from that skill's `## Not for` section.
5. **Install smoke test** — `codex plugin marketplace add Pibomeister/agent-kit --ref published`
   followed by `codex plugin add ak@agent-kit`, then confirming the plugin is enabled. Run against
   an isolated `CODEX_HOME` after the publication workflow has populated the branch.
   The local form, `codex plugin marketplace add <dist/codex>`, relies on the marketplace manifest
   the bundle carries.
6. **Explicit-start rendering** — a packaged U description and first workflow step accept a leading
   `$ak:<id>`, retain the ordinary-prose refusal, and contain no canonical `/ak:<id>` for that U skill.
   An M skill remains automatically discoverable and receives no U authority gate.

**Reported honestly, not worked around:** with no verified host-native eval runner for this host, the
behavioral corpus is executed against the claude-code bundle and, when a runner is attached, through
the host-neutral harness in [`adapters/runner-contract/CONTRACT.md`](../runner-contract/CONTRACT.md). Results for the codex bundle
alone are `not-run`, recorded as such in the release evidence rather than inferred from the
claude-code run.

---

## 6. The learning runtime's hooks

`ak learn setup wire` registers three hooks in `$CODEX_HOME` when it exists, and skips this host
with a message when it does not: `ak learn hook session-start --source codex` on `SessionStart`,
whose roster names human-only commands as `$ak:<id>` (ADR-0011),
`ak learn hook prompt` on `UserPromptSubmit`, which captures user corrections, and
`ak learn hook stop --source codex` on `Stop`. As on claude-code
([`adapters/claude-code/CONTRACT.md`](../claude-code/CONTRACT.md) §7), no skill requires a hook, the bundle ships none of them, and the
runtime's ledgers never live inside a project repository (ruling
`learning-runtime-is-host-adapter`).

The bundle's one hook is the advisory semantic lint. `hooks/hooks.json` runs
`"${PLUGIN_ROOT}/bin/ak" semantic-lint hook --host codex` on `Stop` with a 30-second timeout, which
prints only `{ "systemMessage": … }` or `{}` (`docs/semantic-lint.md`). Codex skips this hook until
the operator trusts it in `/hooks`, as point 1 below says of every non-managed hook. agent-kit
records no trust, writes no Codex settings and never passes `--dangerously-bypass-hook-trust`. The
bundle holds no key and sets no switch.

What the host does with those hooks, verified (receipt) at `codex-cli 0.153.4`:

1. **They are non-managed, and untrusted until someone trusts them.** `ak learn setup wire` writes
   them to `$CODEX_HOME/hooks.json`, the user layer, and records no trust. Codex registers a
   non-managed hook only once its current hash is trusted, and `codex exec` has no review step, so in
   a headless run a freshly wired hook is skipped without a message until it is trusted in the TUI's
   `/hooks`, by a hand-written `trusted_hash`, or by `--dangerously-bypass-hook-trust`. Only hooks
   from system, MDM, cloud or `requirements.toml` sources are trusted by policy
   (`research/host-facts/2026-10-03/codex-2-hook-trust.md`).
2. **Trust covers the hook definition, not the script.** The hash is taken over the normalized
   definition, which holds the command string and the timeout, and the trust record is keyed by the
   hook's file, event and position. A wire that changes any of them, such as a new `ak` path or the
   `Stop` timeout, leaves the hook untrusted or modified, and skipped, until it is trusted again. An
   upgrade that changes what the same `ak` command runs is never re-reviewed
   (`research/host-facts/2026-10-03/codex-2-hook-trust.md`).
3. **They fail open.** A callback error, a timeout or a malformed response marks the hook failed and
   blocks nothing (`research/host-facts/2026-10-03/codex-4-hook-failures.md`), and no hook can ask:
   a `PreToolUse` `permissionDecision: "ask"`, or an `allow` without `updatedInput`, fails the hook
   and the call runs (`research/host-facts/2026-10-03/codex-1-ask.md`). The learning hooks need
   neither a block nor an ask: they return no decision and exit 0 when they fail, so a failure costs
   a session its context, a captured correction or a review, never the session itself.
4. **Context over about 10,000 bytes is spilled to disk.** Codex limits each model-visible hook
   output to 2,500 tokens, estimated as bytes divided by four, per handler. Longer text is saved in
   full under `<temp_dir>/hook_outputs/` and the model receives a head-and-tail preview with that
   path (`research/host-facts/2026-10-03/codex-8-context-cap.md`). The session-start block's own cap,
   `AK_LEARN_MEMORY_TOKENS` (default 2,500 at four characters per token), covers the guardrails and
   the memory but not the status line or the skill roster, and counts characters rather than bytes,
   so a block at the default cap can cross the host's threshold and reach the model as a preview.
