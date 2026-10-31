# Claim ledger

Firstmate does not take a mate's word for its own progress.
Each claim a mate makes in its status log is checked against an independent source - git, the forge, the no-mistakes run, AgentKit's verify record, or the terminal - and the verdict is appended to that task's claim ledger.
A refuted claim reopens the task, counts against the mate, and opens a failure-class record that self-repair reads.
This page is the record contract; [`bin/fm-claims.sh`](../bin/fm-claims.sh) owns the commands, the checks, and the tunables.

## Where claims come from

Claims are read only from the task's own status log, `state/<task>.status`.
A line in another task's log never counts, even when it quotes or echoes this task's words.
The verifier never reads a mate's chat or terminal text.
When a line carries a `corr=<16 hex>` correlation token from a marked firstmate request, the token is kept as part of the claim's evidence, the same correlation rule [`bin/fm-pending-reply-lib.sh`](../bin/fm-pending-reply-lib.sh) applies to secondmate replies.
The verifier's own `claim-refuted-` blockers are never claims.
A scout's `done:` carries none, and neither does a `done:` written before a scout was promoted to a ship.
The evidence pointer names the status log as it was when the claim was judged; cleanup may later archive or remove that log, and `line_sha256` still identifies the exact line.

## Files

| File | Written by | Lifetime |
| ---- | ---------- | -------- |
| `state/<task>.claims.jsonl` | `bin/fm-claims.sh` | One append-only ledger per task id; cleanup leaves it in place so a trust score can read finished tasks. |
| `data/failure-classes/<key>.jsonl` | `bin/fm-claims.sh` | One append-only file per failure class, shared by every task in the home. |

Both files are JSON Lines: one JSON object per line, each ending in a newline.
Records are only ever appended.

## Claim records

Every claim record carries these members:

| Member | Meaning |
| ------ | ------- |
| `v` | Record format version, currently `1`. |
| `id` | Claim id: 16 lowercase hex characters derived from the task, the first line of its status log, the status line's number and bytes, and the kind, so the same claim keeps the same id on every scan and a reused task id, which starts a fresh status log, gets new ids. |
| `checked_at` | Unix time in seconds when this verdict was recorded. |
| `task` | The task id whose status log holds the claim. |
| `mate` | Who made the claim: the task id of the worker or second mate that writes that status log. |
| `mate_kind` | `ship`, `scout`, `secondmate`, or `null` when the task metadata is gone. |
| `harness` | The agent tool from the task metadata, or `null`. |
| `model` | The requested model from the task metadata, or `null`. |
| `spawn_gen` | The task's launch generation from its metadata when the verdict was recorded, or `null`. |
| `time` | Unix time the claim was made, from the status line's `[at=<epoch>]` stamp, or `null` when the line has none. |
| `kind` | One of the claim kinds below. |
| `claim` | The status line's text after its first colon, on one line, with secret-shaped tokens replaced by `[redacted]`, capped at 200 characters; `reason`, `subject.pr`, and every `observed` string get the same treatment. |
| `evidence` | Pointer to the claim: `{"source":"status","path":"state/<task>.status","line":<n>,"line_sha256":"<hex>","corr":<token or null>}`. |
| `subject` | What the claim is about: `{"sha":<commit or null>,"branch":<name or null>,"pr":<URL or null>}`. |
| `verdict` | `verified`, `refuted`, or `unverifiable`. |
| `checker` | The check that produced the verdict, such as `gh-remote-head` or `gh-pr-checks`; compound checks join names with `+`. |
| `reason` | One line explaining the verdict. |
| `attempt` | How many records this claim has, starting at `1`. |
| `observed` | The derived facts the verdict rests on, such as a remote head, a PR state, check counts, or an output age; never raw command output. |

Readers must ignore members they do not recognize, so later versions can add members without breaking them.

## Verdicts

- `verified`: an independent source confirms the claim.
- `refuted`: an independent source contradicts the claim.
- `unverifiable`: no source could confirm or contradict it, for example because a network read timed out, a tool is missing, or the claim needs a deep check that has not been recorded.

A claim's current verdict is its newest record.
`verified` and `refuted` are final for that claim id, except for `alive`.
An `unverifiable` claim may be checked again later and gain a newer record, up to the attempt limit in `bin/fm-claims.sh`.
An `alive` claim is judged again on every scan while its line is the newest mate line.
A trust score that treats `unverifiable` as a failure reads the newest record, so a later `verified` replaces an earlier `unverifiable`.

## Claim kinds

| Kind | The mate claims |
| ---- | --------------- |
| `committed` | Its work is committed on its branch. |
| `pushed` | Its commit is on the forge. |
| `tests-green` | Its tests or CI pass. |
| `pr-opened` | It opened a PR. |
| `pr-ready` | Its PR is ready for review. |
| `order` | It followed its orders. |
| `alive` | It is working or deliberately waiting. |

The header of [`bin/fm-claims.sh`](../bin/fm-claims.sh) owns which status lines carry each kind, how each kind is checked, which lines count as mate lines, when a claim is due, which hedged lines yield no claim, and how a failed blocker append is recovered.

## Refuted claims

A `refuted` verdict has three durable consequences, written in this order:

1. The verdict record itself is appended to `state/<task>.claims.jsonl`; this is the record a mate's trust score reads.
2. The task is reopened by appending a keyed blocker to its status log:
   `blocked [at=<epoch>] [key=claim-refuted-<id>]: claim-refuted-reopen: <kind> claim at line <n> is false: <reason> (ledger state/<task>.claims.jsonl)`.
3. A failure-class occurrence is appended to `data/failure-classes/claim-refuted-<kind>.jsonl`, recording whether the reopen happened.

The `claim-refuted-` key namespace is reserved to the claim verifier by the status fold in [`bin/fm-classify-lib.sh`](../bin/fm-classify-lib.sh), so a bare `resolved` line from the mate does not clear it.
The reservation is a vocabulary rule, not authentication: a writer that copies the close words can still close the blocker.
It closes when the task reports a new terminal result, which is itself a new claim the verifier checks; when firstmate answers it with `fm-send --resolve-key claim-refuted-<id>`; or, for an `alive` claim, when a later scan reads the agent alive again.
Closing the blocker leaves the refuted record in the ledger.
When the task's status log no longer exists, or a newer `done:` line arrived while the claim was being judged, the reopen is skipped and the occurrence records that.

## Failure-class records

Each line of `data/failure-classes/<key>.jsonl` carries these members:

| Member | Meaning |
| ------ | ------- |
| `v` | Record format version, currently `1`. |
| `event` | `occurrence` for every record this verifier writes. |
| `ts` | Unix time in seconds when the record was written. |
| `key` | The failure-class key, `claim-refuted-<kind>`, which self-repair uses to deduplicate. |
| `task`, `mate` | As in the claim record. |
| `claim_id` | The refuted claim's `id`. |
| `kind` | The refuted claim's kind. |
| `reason` | The refuted verdict's reason. |
| `evidence` | `state/<task>.status:<line>`. |
| `ledger` | `state/<task>.claims.jsonl`. |
| `reopen` | `opened` when the reopening blocker was appended, else `skipped`. |
| `reopen_key` | The status-log key of that blocker, or `null` when skipped. |

Later self-repair stages may append other events to the same file; readers must ignore events and members they do not recognize.

Example:

```json
{"v":1,"id":"3f9c0a1b2c3d4e5f","checked_at":1793430000,"task":"fix-login","mate":"fix-login","mate_kind":"ship","harness":"claude","model":"claude-opus-5-5","spawn_gen":"s1793420000.123.456","time":1793429900,"kind":"pushed","claim":"first pushed commit 1a2b3c4 on fm/fix-login","evidence":{"source":"status","path":"state/fix-login.status","line":3,"line_sha256":"9d1e...","corr":null},"subject":{"sha":"1a2b3c4","branch":"fm/fix-login","pr":null},"verdict":"refuted","checker":"gh-remote-head","reason":"origin has no branch fm/fix-login","attempt":1,"observed":{"sha":"1a2b3c4","remote_head":null,"dod_refusal":null}}
{"v":1,"event":"occurrence","ts":1793430000,"key":"claim-refuted-pushed","task":"fix-login","mate":"fix-login","claim_id":"3f9c0a1b2c3d4e5f","kind":"pushed","reason":"origin has no branch fm/fix-login","evidence":"state/fix-login.status:3","ledger":"state/fix-login.claims.jsonl","reopen":"opened","reopen_key":"claim-refuted-3f9c0a1b2c3d4e5f"}
```

## Limits

- The verifier runs when it is invoked; it starts no daemon, timer, or watcher of its own.
- Every network read is bounded by a timeout, and a read that times out or fails yields `unverifiable`, never a hang or a guess.
- Claim text comes from status lines, which should hold no secrets; the verifier still replaces secret-shaped tokens and stores no command output, but give the ledger the same trust you give `state/`.
- A task promoted before `promoted_status_lines` was recorded may have a scout-time `done:` line read as a ship claim.
- Free-text claim recognition is deliberately narrow: a claim the patterns do not recognize is simply not recorded.
- An `order` check reads only the rules its patterns recognize; everything else needs a current AgentKit super-verify record at the head, or the claim stays `unverifiable`.
- An AgentKit record that carries notes, such as a marker-only record, never counts as proof.
- The AgentKit checks run only when the home names its AgentKit gate script ([`docs/configuration.md`](configuration.md) owns `config/agentkit-gate`); without it they cannot verify anything.
- Writes are plain appends under a per-task lock, with no forced flush to disk, so a machine crash can lose the newest records.
