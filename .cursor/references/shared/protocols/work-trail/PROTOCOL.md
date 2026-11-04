# work-trail

A work trail is the implementer's account of the working decisions it makes on one ticket, one
stretch per implementer seat, audited after the commit by a seat that is not the implementer.

## When to use

`super-build` follows it for every ticket it builds, for each implementer it seats and for the
audit once the ticket is committed. A later fix run keeps new stretches and gets its own audit.

## Not for

- Not evidence. A trail and its audit lift no ceiling, close no finding, replace no receipt and are
  attached to no checkpoint card (ruling `work-trail-is-account-not-evidence`).
- Not a gate. No gate record is written; a missing trail is reported, and nothing is refused for it
  (ruling `work-trail-is-account-not-evidence`).
- Not a review and not verification. The audit compares the trail with what the run left behind. It
  does not judge the change, and it cannot replay the run.

## Invoked by

`super-build` alone, for each ticket it builds. No other skill, no phase operation and no role
invokes this protocol, and no human starts it. A protocol holds no authority of its own and never
widens the authority it was called with (ruling `entrypoint-phase-operation-split`).

## Inputs

- The ticket ([`schemas/ticket.schema.json`](../../schemas/ticket.schema.json)) and its hash, and the run's id; per stretch, its
  starting revision, seat and order.
- Scratch space from the runner, outside the checkout, in which the runner provides a directory for
  the build that no implementer seat can write; and the knowledgebase adapter.
- For the audit: the committed revision, the ticket, the diff, the commits, the receipts
  ([`schemas/verification.schema.json`](../../schemas/verification.schema.json)) and the implementer's report. Never a transcript.
- The shapes [`schemas/trail.schema.json`](../../schemas/trail.schema.json) and [`schemas/trail-audit.schema.json`](../../schemas/trail-audit.schema.json), and
  [an example stretch](../../templates/trail.example.json).

An absent trail input fails closed: nothing is guessed, and its absence is not a build gate
(ruling `work-trail-is-account-not-evidence`). No ticket id or hash, or no scratch space: the
stretch is reported missing. No directory for the build, or a stretch index that cannot hold a
stretch's row: step 7 tells that stretch's state from its record, as for any stretch this run
formed, and the build's steps say what the index's failure leaves unpublished or unavailable. A
stretch index gone on a resumed run: the resume rule says what is reported. No knowledgebase
adapter: the build has already failed at its receipts, and no trail step is reached. A publish that
fails or cannot be read back: the record is reported with its location, its hash and the error, and
is not sent again. A missing audit input: the audit is unavailable, and the report names what is
missing.

## Workflow

Stretch record id: `<ticket-id>.<r>.<n>`, where r is the first 12 hex digits of the stretch's
`source_revision.revision` and n is its order among the ticket's stretches, counted from 1.
The build does not reuse an order held by its retained index or already formed by this live
invocation. Across an interruption, only retained rows supply that history; a row the index could
not hold gives no durable uniqueness guarantee. Lost state follows
the refusal and reporting boundary in the resume rule. Audit record id: `<ticket-id>.<r>`, where r is the first 12 hex digits of
the audited revision. The kind is not in the id: the knowledgebase files a run artifact as
`run:<run_id>/<schema>/<id>`, so the two never collide. Both ids must fit
`common#/$defs/artifact_id` (at most 128 characters); a ticket id too long for that (over about 115
characters) maps to outcomes that already exist: the stretch is reported missing, and the audit is
unavailable because its packet cannot be handed over.

A stretch is known by its ticket, starting revision and order, an audit by its ticket and audited
revision, so a later fix run publishes beside the earlier records, never over them. Publication
and replay follow the publication boundary and resume rule below.

The implementer, while it works (ruling `work-trail-is-account-not-evidence`):
1. On each working decision, a choice the ticket leaves open and the implementer settles (one
   approach over another, how a criterion is read, where the scope stops, an approach given up),
   write its entry when the decision is made, not at the end. The entry holds its id, when it was
   written, the decision, the alternatives considered, why, the pointers to its evidence and the
   result, and the id of any entry it supersedes.
2. Give evidence as a pointer, never as prose. A pointer names a file of the ticket's commit or a
   line of one, a commit of the ticket's branch, or a receipt of the run, and never anything else,
   a web address or a transcript included.
3. Keep every secret, credential, token and piece of personal data out of the stretch: where an
   entry needs one, write where the value lives, never the value.
4. Before returning the report, take such a value found in an entry of the stretch out of that
   entry in place, and write in it that a value was removed and where the value lives. This is the
   one case in which an entry is edited.
5. Otherwise correct a wrong entry with a new entry that supersedes it, never by editing or removing
   it. Keep entry ids unique within the stretch, and name as superseded only an entry that exists.
6. Write entries at decision points, not for every action, and in an empty stretch write why; an
   empty stretch that says why is valid. No count of entries is ever grounds for anything
   (ruling `numeric-heuristics-are-guidance`).
7. Still write and return the closing report, with a pointer to the stretch.

The build, for each ticket, in this order (ruling `work-trail-is-account-not-evidence`):
1. Before seating an implementer, form its stretch's id. Its order n is one more than the highest
   order among the rows of the ticket's stretch index and the stretches this run has formed for the
   ticket. This avoids those known orders, not an earlier order whose row could not be retained;
   report that index-write degradation without claiming uniqueness after its history is lost.
   A resumed ticket whose earlier index or attempt directory is gone does not allocate a
   replacement stretch or attempt directory for publication; the resume rule reports that loss.
   An id that does not fit is reported missing.
2. Prepare the stretch's record outside the checkout, in the runner's scratch space, never in the
   ticket's worktree or any tracked directory, at a location that holds that stretch alone, and
   take the record's hash as prepared. Before the implementer is seated, write the stretch's row
   into the stretch index: its id, its location, its prepared hash, the implementer seat it was
   prepared for and its order. The index is kept in the build's own directory of the runner's
   scratch space, apart from every stretch's location, under a name formed from the run id and the
   ticket id. The build writes the index only by replacing it whole with a complete new copy. Only
   the build writes its directory, the index and the kept audit record, and none of them is handed
   or named to an implementer. Create the index's attempt directory beside it, named
   `<stretch-index>.attempts`; it holds the per-record publish-attempt marks below and is part of
   the index handed back on resume.
3. Hand the implementer this protocol and the location of its stretch, which holds its stretch
   alone. Only the implementer it was prepared for writes to it afterwards. A replacing implementer
   is handed no earlier stretch (ruling `work-trail-is-account-not-evidence`).
4. When an implementer's report arrives, write into its stretch's row the stretch's hash at that
   report. A hash the index cannot hold is reported, and nothing stops the build (ruling
   `work-trail-is-account-not-evidence`); on a resumed run, that stretch is held back as the resume
   rule says.
5. Carry the stretch by reference: never open its entries and never rewrite its record. Handle it by
   its location, its hash, and the kind and the id its record names.
6. Wait for the ticket's commit, its receipts, its ticket result and its gate record when there is
   one; none of those waits on the trail steps that follow. A ticket that stops before its commit
   gets no audit and has no stretch published, and the report says so.
7. Tell each stretch's state. Missing: the record is gone, or its hash is still the prepared hash.
   Unpublished: the hash has changed and the knowledgebase holds no `trail` record of the run with
   that id and hash. Published: the knowledgebase holds one. A stretch the resume rule holds back is
   unpublished by this run, and its state is told without asking the knowledgebase.
8. Publish each unpublished stretch that the resume rule does not hold back, as written, when its
   record names kind `trail` and its id, through the publication boundary below as a run artifact
   of the run, and keep the ref it returns. A record that names another kind or id is reported and
   not sent.
9. Form the audit id from the committed revision. Mark the auditor's seat in the stretch index
   under that audit id, then seat the trail auditor once. A seat the index cannot mark is not made:
   the seat failed, and the audit is unavailable.
10. Hand the auditor the audit id, every stretch of the ticket by reference with its state and hash,
    and the ticket, the diff, the commits, the receipts and the implementer's report. No transcript.
11. Keep the audit record as returned in the build's own directory under the audit id, and write
    the kept record's hash into the index under that id, before checking or publishing it. A record
    the directory cannot keep, or a hash the index cannot hold, makes the audit unavailable, with
    that reason, and the record is neither checked nor sent.
12. Before sending the audit, confirm that the returned record names kind `trail-audit` and that
    id. A record that does not is reported and not sent.
13. When the resume rule permits, publish the audit as returned, through the same publication
    boundary as a run artifact of the run, and keep the ref it returns.
14. Report what Outputs lists.

The publication boundary for steps 8 and 13 is `ak kb publish artifact --file <record> --run <run-id>
--trail-attempts <stretch-index>.attempts`. Inside the knowledgebase lock, after checks that can
refuse without writing and immediately before writing the record, it creates the attempt mark
exclusively and flushes the mark and its directory to durable storage. The mark's filename is the
sha256 of the knowledgebase, project, run, kind and id
as joined in the command's record identity; it never depends on content or an attempt count.
An existing mark admits no new write. A mark that cannot be made durable also sends nothing:
preserve each stretch's missing, unpublished or published state, add that reason only to
unpublished stretches, and report an affected audit unavailable. Keep every mark, including after
a refused or failed publish and after an outcome the index cannot hold.

The trail steps are steps 7 to 13. After each, the build writes its outcome into the stretch index:
into a stretch's row, the ref its publish returned, why it was not sent, or the error; for the
audit, under its audit id, its ref, why it is unavailable or not sent, or the error. An outcome the
index cannot hold is reported, and nothing stops the build (ruling
`work-trail-is-account-not-evidence`).

The resume rule (ruling `work-trail-is-account-not-evidence`). At the start of a resumed build,
the build uses the approved ticket supplied to this invocation, committed or not, to locate its
stretch index by run id and ticket id. It reads the index before any build step writes it. For a
ticket whose trail runs, it reports each
recorded outcome as recorded and runs only the trail steps whose outcome the index does not hold.
The ticket and hash are already required inputs; checkpoint-ledger entries or a commit-only seat
record do not select tickets. A coordinator resumes each of its already assigned approved tickets
through that same ticket-bound invocation. If the ticket input is absent, report the trail missing
rather than guessing. It reads the auditor's seat mark, kept record and outcome only under the audit id formed from the
ticket's current committed revision, and no auditor is seated again for a seat the index marks
under that id. The rule decides what to run from the index alone and adds no knowledgebase read
beyond the publish's own read-back. It governs both publication steps, 8 and 13.
- A stretch or audit with an attempt mark and no recorded publish outcome is not sent. The earlier
  publish may have failed, even when its failure could not be recorded. Report a stretch as missing
  under step 7, or unpublished by this run; report the audit as unavailable. Give the reason that
  the publication outcome is unknown and the record may already be published. A secret noticed
  in such a stretch or audit is reported as exposed, for its owner to rotate, as for a published
  record. Recorded outcomes are still reported as recorded, and a recorded refusal or failure is
  never sent again.
  A recorded `kb.trail-publication-unknown` result carries the same possible-exposure warning,
  including when a write or its cleanup failed. A known no-send durability failure is reported as
  such; an uncertain retained mark is not proof that publication occurred.
- A record with no attempt mark can publish normally, subject to its state, identity and hash
  checks, even when another record of the ticket was attempted. Mark it at the shared publication
  boundary before sending it.
- A seat marked with no recorded audit outcome and no kept audit record failed with its seat: the
  audit is reported unavailable, with the reason that the run was interrupted during it, and no
  auditor is seated again.
- A kept audit record with no recorded audit outcome, whose publication the rule above permits,
  is checked and published as steps 12 and 13 say only when its hash still equals the hash the
  index recorded for it; otherwise the audit is reported unavailable, with the reason that the
  kept record is not the one the index recorded.
- A recorded stretch with no recorded publish outcome that is no longer at its location is reported
  missing.
- The hold-back. A stretch the index held on resume, with no attempt mark or recorded publish
  outcome and a hash that is no longer its prepared hash, is sent only when its row records a hash
  at its implementer's last report and the stretch's hash still equals it. Any other such stretch,
  one whose implementer never reported included, is held back: it is not sent, and it is reported
  unpublished by this run, with the reason that its implementer returned no report after its last
  write and the stretch was never sent. When the resumed run seats the trail auditor, it receives
  each unpublished stretch from its location with its reason, including one whose publication
  outcome is unknown.
- The rule depends on the runner handing the resumed run the scratch space the interrupted run used.
  An index row the scratch space cannot hold leaves that stretch reported missing. An index that is
  present but cannot be read in full, or whose attempt directory is gone, is gone. Where the index
  is gone, report its earlier stretches missing and its audit unavailable, with that reason;
  do not recreate an index or attempt directory to publish another stretch of that ticket in this
  run, and do not seat its auditor. No order uniqueness or safe resend can be established after
  losing the order source or fence. Existing knowledgebase identity/hash refusals remain in force;
  they do not recover the lost state. The ticket's implementation can continue without a trail,
  and a later separately identified run follows its own approved inputs.
  This loss rule requires known-resume invocation context or external evidence of a prior start.
  Without that evidence, lost state cannot reliably be distinguished from a first invocation;
  identity/hash refusals are degraded protection, not recovered fencing. A known resumed run
  with lost or uncertain state refuses reconstruction and resend (ruling
  `work-trail-is-account-not-evidence`).

## Hard gates

Gate: the wall (ruling `work-trail-is-account-not-evidence`). No seat whose output is a finding, a
receipt, a verdict or a signoff input is shown the trail, the trail audit or the attention list.
That covers the check seats, the verifier, the review panel, the challenger that QA signoff plans,
and any seat added later. A context that has seen a trail, a trail audit or an attention list sits
in no such seat for the same change. The context that seats them holds the wall, is not one of them,
and carries nothing it saw of a trail, a trail audit or an attention list into a ruling it writes, a
synthesis or verdict it sets, or a packet it hands a seat the wall covers, for the same change.

Gate: the trail auditor is never the implementer nor anyone in its lineage; if the seat cannot be
filled independently, the audit is unavailable, reported so, never backfilled, and blocks nothing
(ruling `work-trail-is-account-not-evidence`).

Gate: a trail is never a file in the project's tree (ruling `work-trail-is-account-not-evidence`).

Gate: a refused record is reported, and neither repaired nor sent again.

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "The trail says the suite passed, so the receipt can wait." | A trail is the implementer's account. A description of a green run is not a receipt, and the trail replaces none. | Run the check, record its receipt, and point the entry at the receipt. |
| "I will write the entries at the end, once I know how it came out." | An entry written after the result is a story fitted to it, and the alternatives that were live at the time are lost. | Write each entry when the decision is made. If the call changes, a later entry supersedes it. |
| "That entry is wrong; I will correct it in place." | An edited entry hides the call that was made. Taking out a secret is the one edit allowed. | Write a new entry that supersedes it. |
| "The reviewer would find the attention list useful." | A seat that has read the trail, the audit or the list judges the implementer's story along with the change. | Show none of them to a seat the wall covers. |
| "No independent seat is free, so the implementer can audit its own trail." | An implementer that checks its own account finds what it expects to find. | Report the audit unavailable. It blocks nothing. |
| "The audit flagged nothing, so the change is sound." | An empty attention list is evidence of nothing. The audit compares the trail with what the run left behind and never judges the change. | Rely on the receipts and the review, and report the audit's result as it stands. |
| "The knowledgebase refused the stretch; a small fix and a resend will get it in." | A refusal means changed content under an id already published, and a repaired record is the build's version, not the implementer's account. | Report the refusal and send nothing again. |

## Outputs

One `trail` record ([`schemas/trail.schema.json`](../../schemas/trail.schema.json), id `<ticket-id>.<r>.<n>`) per stretch and one
`trail-audit` record ([`schemas/trail-audit.schema.json`](../../schemas/trail-audit.schema.json), id `<ticket-id>.<r>`) per audited
revision, each published through the knowledgebase adapter's `publishArtifact` as a run artifact of
the run and carried by the ref it returns, with its hash: an account and its audit, never evidence
and never a file in the project's tree (ruling `work-trail-is-account-not-evidence`).

The build's report names each stretch's id and state, with the reason for an unpublished one; the
audit's ref, the revision it audited, its result and its items, or why it is unavailable; and each
refused record. A notice in the audit that something it read holds a secret, a credential, a token
or personal data is repeated as the audit gives it: where the value is, never the value. A secret
noticed in a stretch or an audit already published is reported as exposed, for rotation by whoever
owns it, because the record cannot be corrected.

Whoever reports onward carries the audit's reference unchanged, with the revision it was audited at,
and says so when the head has moved since. The attention list adds reasons to look and never removes
one, and an empty list is evidence of nothing (ruling `work-trail-is-account-not-evidence`).

## Side effects

`scratch-write` for the records the build prepares, and `kb-publish` for the stretches and the
audit. Each publish's idempotency key is derived from the run id, the operation id, the record's
knowledgebase identity and its content hash, and the record is read back before and after the
publish (the Idempotency section of [`adapters/runner-contract/CONTRACT.md`](../../adapters/runner-contract/CONTRACT.md)). No `workspace-write`,
`local-commit` or `remote-push`.

## Stop conditions

Trail outcomes are not build gates (ruling `work-trail-is-account-not-evidence`). A failed write
can nevertheless leave the shared knowledgebase file dirty and block later project publications,
including required receipts; see the [local-git write/cleanup boundary](../../adapters/knowledgebase/backends/local-git.md#5-publishartifact)
for the preservation limit and operator resolution.

- `complete`: every stretch has a state, and the audit is published or reported unavailable.
- `cap-reached`: the invoking operation's cap was reached. What stands is reported as it stands.
- `failed`: the scratch space could not hold a stretch's record, and that stretch is reported
  missing; or a publish failed or could not be read back, and that record is reported with its
  location, its hash and the error; or the stretch index could not hold a row, a report's hash, the
  publish-attempt mark, a seat mark or an outcome, or was gone on a resumed run, and that is reported
  as the build's steps and the resume rule say; or an audit record the build's directory cannot
  keep, or a hash the index cannot hold, made the audit unavailable, and that is reported with that
  reason.
- `cancelled`: the runner cancelled the run. Each stretch is reported in the state it was left in.

## Limits

- Stretches per implementer seat, writers per stretch, audits per audited revision: 1 each (gate).
- Record ids: at most 128 characters, `common#/$defs/artifact_id` (gate).
- Entries per stretch: no minimum, no maximum (guidance).
