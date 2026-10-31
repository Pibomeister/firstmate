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
| `id` | Claim id: 16 lowercase hex characters derived from the task, the status line's number and bytes, and the kind, so the same claim keeps the same id on every scan. |
| `checked_at` | Unix time in seconds when this verdict was recorded. |
| `task` | The task id whose status log holds the claim. |
| `mate` | Who made the claim: the task id of the worker or second mate that writes that status log. |
| `mate_kind` | `ship`, `scout`, `secondmate`, or `null` when the task metadata is gone. |
| `harness` | The agent tool from the task metadata, or `null`. |
| `model` | The requested model from the task metadata, or `null`. |
| `spawn_gen` | The task's launch generation from its metadata, or `null`; it tells a reused task id's claims apart. |
| `time` | Unix time the claim was made, from the status line's `[at=<epoch>]` stamp, or `null` when the line has none. |
| `kind` | One of the claim kinds below. |
| `claim` | The status line's text after its first colon, on one line, with secret-shaped tokens replaced by `[redacted]`, capped at 200 characters. |
| `evidence` | Pointer to the claim: `{"source":"status","path":"state/<task>.status","line":<n>,"line_sha256":"<hex>","corr":<token or null>}`. |
| `subject` | What the claim is about: `{"sha":<commit or null>,"branch":<name or null>,"pr":<URL or null>}`. |
| `verdict` | `verified`, `refuted`, or `unverifiable`. |
| `checker` | The check that produced the verdict, such as `gh-remote-head` or `gh-pr-checks`; compound checks join names with `+`. |
| `reason` | One line explaining the verdict. |
| `attempt` | How many times this claim has been checked, starting at `1`. |
| `observed` | The derived facts the verdict rests on, such as a remote head, a PR state, check counts, or an output age; never raw command output. |

Readers must ignore members they do not recognize, so later versions can add members without breaking them.

## Verdicts

- `verified`: an independent source confirms the claim.
- `refuted`: an independent source contradicts the claim.
- `unverifiable`: no source could confirm or contradict it, for example because a network read timed out, a tool is missing, or the claim needs a deep check that has not been recorded.

A claim's current verdict is its newest record.
`verified` and `refuted` are final for that claim id.
An `unverifiable` claim may be checked again later and gain a newer record, up to the attempt limit in `bin/fm-claims.sh`.
A trust score that treats `unverifiable` as a failure reads the newest record, so a later `verified` replaces an earlier `unverifiable`.

## Claim kinds

| Kind | The mate claims | Carried by | Checked against |
| ---- | --------------- | ---------- | --------------- |
| `committed` | Its work is committed on its branch. | A `done:` that is not a PR report on a ship task, or a line saying `committed <sha>`. | `git rev-parse` in the task's local copy: the commit exists on the task branch, the branch is ahead of its base, and for a `done:` the local copy is clean. |
| `pushed` | Its commit is on the forge. | A PR-reporting `done:`, or a line saying `pushed`. | The task's custody gate in [`bin/fm-dod-lib.sh`](../bin/fm-dod-lib.sh), then the forge's branch head through `gh api` (or `git ls-remote` off GitHub). |
| `tests-green` | Its tests or CI pass. | A `done: PR <url> checks green`, or a line saying tests, checks, or CI passed. | `gh pr checks` at the PR head, else the no-mistakes run for the branch through [`bin/fm-nm-run-lib.sh`](../bin/fm-nm-run-lib.sh), else a current AgentKit super-verify record at the local copy's head. |
| `pr-opened` | It opened a PR. | A line naming a PR URL with `opened` or `created`. | `gh pr view`: the PR exists, is open or merged, and its head branch is the task branch. |
| `pr-ready` | Its PR is ready for review. | A PR-reporting `done:`, or a line naming a PR URL with `ready`. | `gh pr view`: open, not a draft, on the task branch, and at the expected head. |
| `order` | It followed its orders. | A ship `done:` that reports delivery, or an explicit check against a named order. | The mechanical rules recognized in the order text, diffed against the task's actions, plus a current AgentKit super-verify record for everything the rules cannot read. |
| `alive` | It is working or deliberately waiting. | The newest status line, when it is `working:` or `paused:`. | The agent endpoint, the age of the newest terminal output the monitor saw, CPU use by processes in the task's local copy, and the age of the oldest unread steering message. |

`tests-green`, `pr-ready`, `order`, and `alive` describe the present, so they are judged only while their line is the newest line of that kind.
A superseded present-tense claim that was never judged is skipped rather than judged against later work.
`committed`, `pushed`, and `pr-opened` describe facts that stay true, so they are judged whenever they are first seen.
A line that hedges its claim - for example with `will`, `before`, `until`, `not`, or `pending` - yields no free-text claim.

## Refuted claims

A `refuted` verdict has three durable consequences, written in this order:

1. The verdict record itself is appended to `state/<task>.claims.jsonl`; this is the record a mate's trust score reads.
2. A failure-class occurrence is appended to `data/failure-classes/claim-refuted-<kind>.jsonl`.
3. The task is reopened by appending a keyed blocker to its status log:
   `blocked [at=<epoch>] [key=claim-refuted-<id>]: claim-refuted-reopen: <kind> claim at line <n> is false: <reason>`.

The `claim-refuted-` key namespace is reserved to the claim verifier by the status fold in [`bin/fm-classify-lib.sh`](../bin/fm-classify-lib.sh), so a bare `resolved` line from the mate does not clear it.
It closes when the task reports a new terminal result, which is itself a new claim the verifier checks; when firstmate answers it with `fm-send --resolve-key claim-refuted-<id>`; or when firstmate runs `bin/fm-claims.sh clear`.
When the task's status log no longer exists, the reopen is skipped and the occurrence records that.

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
{"v":1,"id":"3f9c0a1b2c3d4e5f","checked_at":1793430000,"task":"fix-login","mate":"fix-login","mate_kind":"ship","harness":"claude","model":"claude-opus-5-5","spawn_gen":"s1793420000.123.456","time":1793429900,"kind":"pushed","claim":"first pushed commit 1a2b3c4 on fm/fix-login","evidence":{"source":"status","path":"state/fix-login.status","line":3,"line_sha256":"9d1e...","corr":null},"subject":{"sha":"1a2b3c4","branch":"fm/fix-login","pr":null},"verdict":"refuted","checker":"gh-remote-head","reason":"origin has no branch fm/fix-login","attempt":1,"observed":{"remote_head":null}}
{"v":1,"event":"occurrence","ts":1793430000,"key":"claim-refuted-pushed","task":"fix-login","mate":"fix-login","claim_id":"3f9c0a1b2c3d4e5f","kind":"pushed","reason":"origin has no branch fm/fix-login","evidence":"state/fix-login.status:3","ledger":"state/fix-login.claims.jsonl","reopen":"opened","reopen_key":"claim-refuted-3f9c0a1b2c3d4e5f"}
```

## Limits

- The verifier runs when it is invoked; it starts no daemon, timer, or watcher of its own.
- Every network read is bounded by a timeout, and a read that times out or fails yields `unverifiable`, never a hang or a guess.
- Claim text comes from status lines, which should hold no secrets; the verifier still replaces secret-shaped tokens and stores no command output, but give the ledger the same trust you give `state/`.
- Free-text claim recognition is deliberately narrow: a claim the patterns do not recognize is simply not recorded.
- An `order` check reads only the rules its patterns recognize; everything else needs a current AgentKit super-verify record at the head, or the claim stays `unverifiable`.
- Writes are plain appends under a per-task lock, with no forced flush to disk, so a machine crash can lose the newest records.
