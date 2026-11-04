# The delta pass: packet, scope, continuity and the end of the loop

Loaded by `super-review delta`. The authority for every rule here is [`policies/review.yaml`](../../../references/shared/policies/review.yaml) and
[`schemas/review.schema.json`](../../../references/shared/schemas/review.schema.json); this file is the operating form of them.

## What the delta is not

It is not a second panel. Pass 1 convened seats from declared risk; the delta runs two lanes over one
fix inside the review run pass 1 opened.

## The packet

Persisted from pass 1: the finding list, the input hashes, the dispositions, the evidence.
Added for the delta: the latest fix diff, the touched dependencies, the verification receipts.

A delta invoked with no open review run does not open one. It stops with `needs-input` naming
`super-review full` as the next permitted action (ruling `entrypoint-phase-operation-split`).

## The two lanes

[`reviewer-spec`](../../../references/shared/roles/reviewer-spec/ROLE.md) — were the accepted findings and the ticket obligations actually addressed.
[`reviewer-standards`](../../../references/shared/roles/reviewer-standards/ROLE.md) — did the fixes introduce relevant regressions or new rule violations.

The two run independently and in parallel against the same snapshot. Per-ticket build checks are the
other ordering: there, spec compliance runs before standards review.

Unresolved security, data or API issues return to that specialist seat alone. They do not trigger
another full fan-out.

## Scope

The boundary is affected behavior, not changed lines. The delta reviews the impact neighbourhood of
the fix, and a serious newly discovered issue in an untouched affected caller stays reportable:
scope discipline is not a reason to suppress relevant evidence (ruling
`delta-scope-affected-behavior`).

A new finding requires novelty evidence — what changed, or what regressed, that makes this finding
new. Without it the finding is rejected as out of scope. Restarting discovery for unrelated
low-priority issues is forbidden; that is a new review scope, not a longer delta.

## Continuity

"Fresh" means independent of the author. It does not mean ignorant of prior findings (ruling
`reviewer-continuity-not-amnesia`).

Either a continuing specialist retains its earlier finding context, or a replacement receives a
durable prior-finding packet. In both cases the seat holds the old finding with its identity and
fingerprint, the new revision, and the disposition and evidence recorded when the finding was raised;
independence from the author is what is mandatory (ruling `reviewer-continuity-not-amnesia`).

The prior-finding packet carries `finding_id`, `fingerprint`, `severity`, `evidence`, `disposition`,
`input_hashes` and `source_revision`.

The fingerprint is rule-or-cause plus location-or-symbol plus evidence. It is not the line number, so
moving a line neither duplicates a finding nor falsely suppresses one.

## Closure

A finding closes on independent verification evidence that binds to the revision under review, plus a
policy rule saying that evidence is sufficient for that finding.

It does not close on reviewer confidence, classifier or triage confidence, the implementer's
statement that the fix landed, a green run recorded against a different revision, or agreement
between two seats. An author may never close their own finding and may never approve their own
change (ruling `closure-requires-independent-verification`).

## Cycles

At most two fix-and-verify cycles after the first pass. The third stops with an explicit
blocked-or-replan decision, and anything still open is reported rather than looped (ruling
`two-fix-cycles-then-stop`).

The decision takes one of four values in `fix_cycles.exhausted_action`:

| Open at the cap | Decision |
|---|---|
| Only P3 findings | `merge-with-follow-ups`: recommend merge, each P3 listed in `fix_cycles.follow_ups`; the verdict may be `approved` |
| A finding theme the last two cycles both reopened | `design-decision`: name the theme and the design question behind it; no further patch is proposed |
| Anything else | `blocked` or `replan` |

The theme is the cause the findings share, not their fingerprints: two cycles that each tighten a
different bound on the same input are one theme. A cycle a human authorizes after the decision is
recorded in `fix_cycles.extensions` with `authorized_by: human` and when; the operator attests the
human authorization, and the record does not prove it. The cycle is reviewed here, as a delta
over the commits since the last reviewed head, and that delta may approve. It never opens a new full
scope over the whole change, and a cycle past the cap with no extension entry is refused.

## Baseline reset

Where architecture, requirements, the comparison base or the affected surface changes materially, the
affected approvals are invalidated and a new baseline is deliberately established. That is a new
review scope with its own pass 1, not an unbounded third delta loop, and it is not the third cycle
the cap forbids wearing a different name (ruling `delta-baseline-reset-not-third-loop`). The fix
commits, a reached cap, a replan, and a rebase that leaves the patch and the requirements unchanged
are not material changes: each continues as a delta.

The run records its comparison base, its reviewed head and the last head verified in the delta loop,
so the three are never conflated (ruling `delta-baseline-reset-not-third-loop`). A verification
receipt names the head it verified and none of the other two.
