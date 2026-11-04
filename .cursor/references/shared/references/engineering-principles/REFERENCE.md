# Engineering principles

The principles an implementer builds under and a reviewer reads a change against: four operating
principles, four standards (observable behavior, the fence, code as liability, the test pyramid),
the two numeric heuristics and what they are not, and the rebuttals to the excuses each principle
attracts.

Three skills declare it. `super-build` loads it while a ticket is being implemented, `super-review`
loads it when a seat needs the standard a change is read against, and `simplify` loads it before
anything is deleted or shrunk. It is loaded on demand by the skills that name it rather than copied
into each of them (ruling `full-catalog-opt-in-profiles`), and every one of them pays for the whole
of it at the moment of loading.

A principle here says what to look for. It is not a finding. A finding raised with one of these in
mind still carries its own evidence in the shape [`schemas/finding.schema.json`](../../schemas/finding.schema.json) requires, and a
principle named without that evidence is an opinion. The domain packs apply the four standards
below as constraints when the artifact earns them ([`protocols/attach-pack/PROTOCOL.md`](../../protocols/attach-pack/PROTOCOL.md)): `pack-api`
the first, `pack-delete` the fence and the liability, `pack-test` the last. This pack explains the
standards and does not attach anything.

## Operating principles

### Evidence over assertion

State the assumptions a change rests on before building on them: what the requirement is taken to
mean, what the architecture is taken to allow, what the scope is taken to cover. An assumption left
silent is the commonest way a change goes wrong, and it is cheaper to have it corrected before the
work than after.

When the specification, the code and the ticket disagree, stop. Name the specific inconsistency and
ask which one governs. Picking one reading and proceeding is a guess presented as a decision.

- Bad: silently choosing one interpretation of a conflicting requirement.
- Good: "The ticket says X; the existing handler does Y. Which one governs?"

A claim about the code carries its evidence with it: the file and the line, the command and its
output, the search and what it returned. "This is unused" without the search that showed it is an
assertion.

### Verification before claims

No completion claim without fresh verification evidence. If the command that proves the claim has
not been run for the revision being described, the claim cannot be made. The mechanism is five
steps, and skipping any of them makes the claim unsupported:

1. Identify the command or probe that would prove the claim.
2. Run it in full, against the current revision.
3. Read the whole output: exit status, failure count, warnings.
4. Check that the output confirms the claim. If it does not, report the actual state with that
   output.
5. Only then make the claim, and carry the evidence with it.

| Claim | Requires | Not sufficient |
|---|---|---|
| Tests pass | The test command's output, zero failures | A previous run; "should pass" |
| Build succeeds | The build command, exit 0 | A clean lint; logs that look fine |
| Bug fixed | The original symptom, re-run and passing | The code changed |
| Regression test works | The test failing without the fix and passing with it | The test passing once |
| Delegated work done | The diff, read, and its verification re-run | The worker reporting success |
| Requirements met | Each requirement checked against the change | The tests passing |

An agent's description of a green run is not a receipt, and reviewer confidence closes nothing:
only independent verification evidence, plus a policy rule saying that evidence is sufficient for
the finding, closes a finding (ruling `closure-requires-independent-verification`). A receipt
carries the command or probe, its exit status, an output digest, the revision and the environment
identity (ruling `closure-requires-independent-verification`). A changed patch does not inherit the
receipts of the patch before it (ruling `closure-requires-independent-verification`).

"Should", "probably" and "seems to" in a status line are the signal that step 2 was skipped.

### Smallest correct change

Build the least code that meets the requirement and its verification. Before calling an
implementation finished, ask whether it can be done with less code, whether each abstraction earns
its complexity, and whether a reader would ask why the obvious version was not written. The boring
solution is the default; a clever one has to justify its cost.

When a suggestion asks for something to be implemented "properly", check whether anything uses it
first. Search the codebase for callers. If nothing calls it, the smallest correct change is to
propose removing it rather than hardening it. If something does, implement it properly.

Smallest correct change is not smallest diff. A change that is too small to be correct is not the
smaller option, and splitting a change to shrink it is not simplification: a line target is
guidance, never grounds for a split that cannot be verified alone (ruling
`numeric-heuristics-are-guidance`).

### Explicit authority

Touch only what the task authorizes. Absent that authorization, none of these is part of a change:

- removing a comment whose purpose is not understood
- cleaning up code orthogonal to the task
- refactoring an adjacent system as a side effect
- deleting code that seems unused without an explicit approval to delete it
- adding a feature the specification does not ask for because it seems useful

Work that is out of scope is reported, not done. Scope expansion is never granted by default: it
needs an explicit charter entry a human approved up front, naming the action and exactly what is
permitted, with an explicit human approval bound to that charter's hash and any expiry or
single-use bound. A run may never enlarge its own authority mid-flight (ruling
`sensitive-actions-need-approved-charter-entry`).

## The standards

### Every observable behavior will be depended on

Given enough consumers, every observable behavior of an interface becomes something somebody
depends on, whatever the contract promises. That includes error-message text, ordering, timing and
undocumented quirks. Hyrum's Law is the name for it. Three consequences follow:

- Expose deliberately. Every behavior a consumer can observe is a potential commitment.
- Do not leak implementation detail. If a consumer can see it, a consumer will rely on it.
- Tests are not enough. A change can pass every contract test and still break a consumer who relied
  on something the tests never pinned.

This is why an additive change to a public surface carries less risk than a change to an existing
shape, and why removal takes migration rather than an announcement.

### Understand a fence before removing it

Before changing or removing anything, find out why it exists: what it is responsible for, what calls
it, what it calls, which edge cases and error paths it covers. If the reason cannot be found, the
thing stays until it can. Once the reason is known, decide whether it still applies. This is
Chesterton's Fence, and it binds `simplify` hardest: a deletion with no answer to "why is this
here?" is not a simplification.

### Code is a liability

Every line carries ongoing cost: tests, documentation, security patches, dependency upgrades, and
the attention of everyone working nearby. The value is the behavior the code provides, not the code.
When the same behavior can be had with less code, the old code should go. Deleting is first-class
work, and a loop that only ever adds is accumulating liability.

The fence and the liability pull against each other on purpose. The liability argues for deleting;
the fence says what has to be known first.

### Test what you rely on

If behavior matters, a test holds it. A refactor, a migration or an infrastructure change is not
responsible for catching a regression in behavior nobody tested; the missing test is.

Most tests should be small and fast, with fewer at each level up:

| Level | Resources | Holds |
|---|---|---|
| Unit (small) | One process, no I/O, no network | Pure logic, data transforms |
| Integration (medium) | Localhost only, no external services | Component interactions, API boundaries |
| End to end (large) | External services allowed | Full user flows |

The shape is the point: cheap, reliable tests carry most of the weight, and the slow ones are
reserved for what only they can show. The proportions are a configurable starting point set per
project, never a count to hit (ruling `numeric-heuristics-are-guidance`).

## The numeric heuristics

Two numbers travel with these principles: a change of roughly a hundred lines, and a test mix of
roughly 80 unit, 15 integration and 5 end to end.

Both are configurable starting points, established per project and carried in the project record,
and this pack is where they are explained (ruling `numeric-heuristics-are-guidance`). Neither is
validated or enforced here, and neither is grounds for a finding on its own (ruling
`numeric-heuristics-are-guidance`). Real constraints are set per project, and an exception is
recorded rather than answered by forcing an artificial file split or a meaningless test (ruling
`numeric-heuristics-are-guidance`).

| Heuristic | Starting point | Configured in | What it is for |
|---|---|---|---|
| Change size | About 100 changed lines, where that is natural | [`schemas/project.schema.json`](../../schemas/project.schema.json) `guidance.pr_size` | Changes a reviewer can hold in their head |
| Test mix | About 80 / 15 / 5 unit / integration / end to end | [`schemas/project.schema.json`](../../schemas/project.schema.json) `guidance.test_pyramid` | Most confidence from the cheapest tests |

The project record pins both to `enforcement: advisory`, and a departure goes in its `exceptions`
list with a reason. A policy may read a configured value as one input among others;
[`policies/limits.yaml`](../../policies/limits.yaml) `not_gates` records each such use, and none of them makes the number grounds
for a finding on its own (ruling `numeric-heuristics-are-guidance`).

What this means where each loader meets it:

- **Building.** A ticket whose correct change runs to 300 lines is 300 lines. Split it only where
  each piece verifies alone; otherwise keep it whole and record the exception (ruling
  `numeric-heuristics-are-guidance`).
- **Reviewing.** "This change is too large" and "this suite is too end-to-end heavy" are not
  findings on their own (ruling `numeric-heuristics-are-guidance`). A finding names a behavior: a
  path with no test holding it, a change a reviewer could not trace. Size or mix may be why the
  problem was hard to see; it is not grounds for a finding on its own (ruling
  `numeric-heuristics-are-guidance`).
- **Simplifying.** Less code for the same behavior is the aim of the liability standard, and the
  line target plays no part in it (ruling `numeric-heuristics-are-guidance`). A deletion is
  justified by the fence and the liability, never by a line target.

## Rebuttals

The thoughts these principles exist to catch, each recorded as a failure in the material this pack
adapts, in the three-column shape `AUTHORING.md` gives a skill body's anti-rationalization table.

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "It should work now." | Nothing was run, so nothing is known. | Run the verification and quote its output. |
| "I'm confident." | Confidence is not evidence. | Run the command that would prove it. |
| "The worker reported success." | A report of a green run is not a receipt (ruling `closure-requires-independent-verification`). | Read the diff and verify independently. |
| "A partial check is enough." | It proves the part it checked and nothing else. | Run the full check, or claim only the part checked. |
| "The requirement was obvious, so I didn't ask." | An unstated assumption is the commonest way a change goes wrong. | State the assumption before building on it. |
| "I cleaned up a few things nearby while I was there." | An out-of-scope edit is an unauthorized edit. | Revert it and report it as a separate item. |
| "Nothing uses this, so I deleted it." | Without the search, "unused" is an assertion; without approval, the deletion is out of scope. | Show the search that found no callers, and get the approval to delete. |
| "I don't know why this is here, but it looks unnecessary." | Not knowing the reason is not evidence that there is none. | Leave it until the reason is found, then decide. |
| "It's internal, so changing its behavior is safe." | If anything outside can observe it, something outside depends on it. | Check what can observe it before changing it. |
| "The tests still pass, so no consumer breaks." | Tests pin what they pin; consumers depend on what they observe. | Treat an observable change as a contract change. |
| "It's only a refactor, so no test is needed." | A refactor claims behavior was preserved, and the test is what shows it. | Keep or add the test that holds the behavior. |
| "The change is over the line target, so I split it." | The target is guidance (ruling `numeric-heuristics-are-guidance`), and a piece that cannot be verified alone is worse than a large change. | Split only where each piece verifies alone; otherwise keep the change whole and record the exception (ruling `numeric-heuristics-are-guidance`). |
| "The suite misses the pyramid ratio, so add tests." | The ratio is guidance (ruling `numeric-heuristics-are-guidance`), and a test written to move it holds nothing. | Add a test for a behavior nothing holds, or none. |
