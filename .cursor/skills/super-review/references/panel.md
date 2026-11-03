# Pass 1: the panel, its seats, and what each seat is given

Loaded when `super-review full` selects seats, and when a reader needs to know why a particular seat
did or did not run. The authority for every rule here is [`policies/review.yaml`](../../../references/shared/policies/review.yaml); this file is the
operating form of it.

## Selection

The panel is layered, not a roster. Composition follows declared risk and the artifact evidence in
front of the run — in practice the attached packs — so a substantive feature lands at the six-ish
panel the design preserves and a documentation typo does not (ruling
`panel-composition-by-declared-risk`).

| Seat | Tier | What activates it | Pack signal |
|---|---|---|---|
| [`code-review/correctness`](../../../references/shared/roles/code-review/correctness/ROLE.md) | always-on | every pass-1 review, without exception | — |
| [`code-review/project-standards`](../../../references/shared/roles/code-review/project-standards/ROLE.md) | standards-gate | the project declares standards files, or standards discovery returned an uncertain result | — |
| [`code-review/testing`](../../../references/shared/roles/code-review/testing/ROLE.md) | generic-conditional | the change adds or alters behavior | `pack-test` |
| [`code-review/maintainability`](../../../references/shared/roles/code-review/maintainability/ROLE.md) | generic-conditional | the change introduces, moves or removes structure rather than only text | — |
| [`code-review/agent-native`](../../../references/shared/roles/code-review/agent-native/ROLE.md) | generic-conditional | the change adds or alters an action surface a user can take | — |
| [`code-review/learnings`](../../../references/shared/roles/code-review/learnings/ROLE.md) | generic-conditional | the captured-lesson corpus is non-empty and has hits on the touched surface | — |
| [`code-review/security`](../../../references/shared/roles/code-review/security/ROLE.md) | conditional | trust boundaries, authentication, authorization, tenancy, secrets, payments, money movement, user-controlled input reaching a privileged path, or a declared risk in the project's own standards | `pack-secure` |
| [`code-review/adversarial`](../../../references/shared/roles/code-review/adversarial/ROLE.md) | conditional | the same evidence that activates the security seat, or a change large enough that the project's configured size guidance was exceeded and the exception was recorded | `pack-secure` |
| [`code-review/api-contract`](../../../references/shared/roles/code-review/api-contract/ROLE.md) | conditional | an externally consumed boundary changes and downstream callers are evidenced | `pack-api` |
| [`code-review/data-migration`](../../../references/shared/roles/code-review/data-migration/ROLE.md) | conditional | migration or schema artifacts are present; model-only or query-only changes do not activate it | `pack-data` |
| [`code-review/performance`](../../../references/shared/roles/code-review/performance/ROLE.md) | conditional | a stated performance budget exists, or a performance problem was measured | `pack-perf` |
| [`code-review/reliability`](../../../references/shared/roles/code-review/reliability/ROLE.md) | conditional | error handling, retries, breakers, timeouts, background jobs or health checks | — |
| [`code-review/previous-comments`](../../../references/shared/roles/code-review/previous-comments/ROLE.md) | conditional | the review target is a PR that already carries review comments or threads | — |
| [`code-review/frontend-races`](../../../references/shared/roles/code-review/frontend-races/ROLE.md) | stack-conditional | DOM event wiring, timers or async UI flows with race potential | `pack-frontend` |
| [`code-review/swift-ios`](../../../references/shared/roles/code-review/swift-ios/ROLE.md) | stack-conditional | SwiftUI state, concurrency, Core Data threading, entitlements, accessibility | — |

[`code-review/correctness`](../../../references/shared/roles/code-review/correctness/ROLE.md) and [`code-review/project-standards`](../../../references/shared/roles/code-review/project-standards/ROLE.md) are required lanes. [`code-review/security`](../../../references/shared/roles/code-review/security/ROLE.md)
and [`code-review/adversarial`](../../../references/shared/roles/code-review/adversarial/ROLE.md) are required once activated.

The lean panel is what a pass-1 change within the project's configured size guidance seats:
correctness, the standards gate, testing when the change adds or alters behavior,
and the conditional seats the change's own risk evidence or packs activate. Maintainability,
agent-native and learnings sit only above the size guidance; below it, correctness covers their
axes. Leaner never drops a risk seat the evidence activated ([`policies/review.yaml`](../../../references/shared/policies/review.yaml)
`proportionality.lean_panel`). A delta seats its two core lanes, plus a specialist seat only when
an unresolved prior finding of that seat's type exists or the delta diff itself triggers that
seat's risk evidence; it never seats the pass-1 panel or the lean panel.

Discovery uncertainty runs the standards gate rather than skipping it, so that a failed lookup never
becomes a silent pass.

Forbidden: spawning the full catalog on a small low-risk change; hardcoding a fixed six seats
regardless of the artifact; dropping the security or adversarial seat because a classifier was
uncertain.

## What a seat receives

Receives: the immutable snapshot; the requirements and acceptance criteria the change claims to
satisfy; the project standards files relevant to that seat; the tests and verification receipts bound
to the reviewed head; the dependency context the seat needs to judge impact.

Never receives: the implementer's narrative, rationale or self-assessment; another reviewer's
findings, judgments or dispositions; any approval context produced by the author lane.

Every packet also carries the shell rule. An unattended host stops on a permission prompt that no
one is there to answer, and a delete inside a compound command is what raises one. So a delete or a
container removal runs as its own standalone command on a literal path under the seat's scratch
folder (`rm -rf .work/<seat>/probe`, `docker rm -f <literal-name>`), or the container starts with
`docker run --rm`. Never `rm` on a variable path, and never `rm` or `docker rm -f` inside a compound
command, a loop or a multi-line script. Leaving scratch files for cleanup is always allowed.

Independence comes from isolated evidence packets, not from scheduling. Two seats that share a
scratchpad are one seat, and a seat that cannot be filled independently of the author is unavailable
rather than filled from the author lane (ruling `missing-supervisor-never-implementer`).

## Standards output contract

The standards seat cites actual rules, rule by rule, with the file and rule identifier. Where the
project declares no standards it returns an empty result. Absent standards never become invented
preferences: a seat that cannot cite a rule returns empty rather than substituting its own taste for
the project's.

## Lane results

Two vocabularies, one per layer. A seat returns a lane result from [`policies/review.yaml`](../../../references/shared/policies/review.yaml)
`lane_results`; the review records a lane state from [`schemas/review.schema.json`](../../../references/shared/schemas/review.schema.json). The review never
records a seat's result verbatim.

| Seat returned | Review records | Meaning |
|---|---|---|
| `complete` | `covered` | The seat ran on the snapshot and returned its findings, possibly none |
| `empty` | `covered`, no findings, reason kept | The seat ran and its axis did not apply, such as standards where the project declares none |
| `unavailable` | `unavailable`, reason kept | The seat could not run, could not be given its required context, or failed |
| (not dispatched) | `skipped`, reason kept | A conditional seat whose selection signal was absent |

Every `covered` lane carries the seat's raw output, preserved as a run artifact before synthesis
reads it.

A required lane is never `skipped`. A required lane that is `unavailable` blocks approval, is never
downgraded to `covered` or `skipped`, and is never backfilled by the author, the implementer,
another seat or the synthesis step. "We could not look"
and "we looked and found nothing" are different claims, and the review reports which lane was
unavailable and why while staying resumable (ruling `required-lane-failure-is-unavailable`).

A seat that suppressed every candidate on its axis returns `complete` with no findings, never
`empty`: `empty` says the axis did not apply. Both are recorded as `covered`, so the seat's result
is kept as the lane's reason and its raw output shows what it suppressed.

In a delta, a regression found in a caller the fix never touched is still reported when it is
affected behavior: the novelty evidence is the fix that reached it, and scope discipline is not a
reason to drop it (ruling `delta-scope-affected-behavior`).

## Evidence

Before a finding is anchored at 75 or 100, its first evidence item is the verbatim line or lines,
with `file:line`, that make the claim true. A seat that cannot quote the motivating line anchors at
50 — a recorded anchor, not a discarded finding. Fabricating an excerpt to reach 75 is worse than the
honest anchor the vocabulary already provides.

A search that returned nothing is evidence about the search, not evidence that a symbol does not
exist. Absence is established from the construct that would define the symbol. Where a symbol is
generated by a framework metaclass, an ORM declaration, a decorator or migration history, the seat
quotes the construct that generates it.

Line provenance is an additional evidence item, never a substitute, and is attached only where the
claim depends on line history.

## Suppression

These are non-findings, not weak findings, and a seat emits them at no anchor: pre-existing issues
unrelated to this diff; pedantic style nitpicks a linter would catch; code that looks wrong but is
intentional; issues already handled by callers, guards, middleware or framework defaults;
suggestions that restate what the code already does; generic "consider adding" advice with no named
failure mode; issues carrying a relevant lint-ignore comment; general code-quality concerns with no
rule behind them; speculative future-work with no current signal.

No suppression category reaches a security observation. One that matches a category here is still
emitted and adjudicated at the finding adjudication checkpoint (ruling
`low-confidence-security-adjudicated`).

## Suggested fix

One committed recommendation, not a menu. Lettered option lists, "either X or Y" and "consider A, B
or C" all defer the choice to apply time, which is the decision the field exists to make. Where the
alternatives are genuinely independent, the seat emits one finding per alternative.

"I need further input before I can commit to a fix" is a deferral wearing a fix's clothes: the seat
proposes what it would choose now and names the assumption it rests on.

A `suggested_fix` carries no permission to apply it. Permission is the action class plus policy, and
eligibility is gated by the apply-findings protocol.

## Synthesis

May: deduplicate findings that share a fingerprint; conservatively downgrade a finding's
specification quality; conservatively raise its difficulty; retain conflicting evidence from two
seats as conflicting.

May not: make a ticket easier, more specified or more authorized than its originating seat said;
raise a nit's severity because several seats agreed on it; drop a low-confidence security finding,
which is adjudicated rather than filtered (ruling `low-confidence-security-adjudicated`); change a
lane result; drop a finding because of its action class.

An inbound `safe_auto` from a peer lane is remapped to `gated_auto` and kept. No code-review seat
emits `safe_auto` itself (ruling `safe-auto-restricted-per-seat`).

Canonical severities are P0, P1, P2 and P3. Critical, Nit and FYI are presentation and disposition
labels, not a replacement for severity.
