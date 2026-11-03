---
name: simplify
description: Cleans up a settled scope of recently changed code through reuse, quality and efficiency lenses, explaining existing behavior before removing any of it and verifying after every pass. Use when working code has accreted duplication, dead paths or wasted work. Not for adding features, not for structural redesign, and never for changing what the product does.
license: MIT
metadata:
  ak_catalog_id: simplify
  ak:
    mode: autonomous
    autonomy_unenforceable:
      - "artifact-write is storage only: the host does not compute or check the artifact hash, so envelope hash binding is this package's own work."
---

Reduce complexity with behavioral evidence. Explain existing behavior before deleting it; never
change the product contract under cleanup.

## When to use

- A change is working and its diff has accreted duplicated helpers, dead imports, redundant checks
  or wasted work that a reader will pay for.
- A named file set or a branch diff needs a cleanup pass before review, with its behavior unchanged.
- A review lane or the human points at a scope and asks for it to be made simpler, not different.

## Not for

- Adding or changing behavior. A feature is `super-build`; cleanup that changes an output, an error,
  a side effect or an ordering has become a feature without a specification.
- Redesigning module boundaries or deepening an interface. That is `improve-architecture`,
  which a human starts; this skill names the finding and hands it off.
- Fixing a defect. A behavior that is wrong goes to `diagnose`.
- Retiring a surface other code consumes. Removing a public interface is `deprecate`.
- A scope of documentation, generated files or lockfiles only. Report nothing to simplify.

## Authority

Authority: `model`. The model starts this skill on a settled scope, and a human may ask for it by
name. It starts no user-invoked skill: an architectural finding is named for a human-started run.

## Inputs

- The scope, in this order: the scope the caller named, which is authoritative and never widened;
  else the branch diff against its base; else, only when no usable base exists, the staged and
  unstaged changes. None resolvable: `needs-input`. Docs, generated or lockfile-only: `complete`,
  nothing to simplify.
- The project's verification commands (type check, lint, tests). Where one is absent, the summary
  says so rather than implying it ran.
- Project constraints from the project record. Size targets and test-shape ratios there are
  configurable starting points and never grounds for a finding on their own (ruling
  `numeric-heuristics-are-guidance`); the fence, code as liability and observable behavior are in
  [the engineering-principles reference pack](../../references/shared/references/engineering-principles/REFERENCE.md).

## Workflow

1. **Resolve and preflight the scope.** Take the first scope in Inputs order. Stop on a docs-only
   scope. Record the revision and the file set.
2. **Explain before touching.** For each candidate removal, state what it does, why it was written
   (read its history), what calls it, and what would break without it. An answer you cannot give is
   a reason not to change it yet.
3. **Lock behavior.** Run the covering tests and record a green baseline. Where a candidate has no
   behavioral coverage, write the narrowest test that pins its current observable behavior first.
   A red baseline stops the run: cleanup on a failing scope cannot show it preserved anything.
4. **Run the three lenses.** Pass each reviewer its rubric in full, unparaphrased, with the whole
   scope: [code reuse](references/personas/code-reuse.md),
   [code quality](references/personas/code-quality.md) and
   [efficiency](references/personas/efficiency.md). Each returns findings or says nothing to flag.
5. **Classify fallbacks.** A fallback that hides a failure (a swallowed error, a silent default, a
   catch-all that returns success) is masking; one that implements a documented degradation is
   grounded. Masking fallbacks are reported, never tidied into a quieter form.
6. **Apply one change at a time**, in passes: dead code, then duplication, then naming and error
   handling, then test cleanup. Edit only the scope plus the import and export lines a change
   forces. Skip any fix whose equivalence you cannot show, and record it as skipped.
7. **Verify after each pass.** Type check and lint project-wide; tests by blast radius. A pass that
   turns anything red is reverted, not patched forward.
8. **Summarize.** Counts of fixes by lens, what was skipped and why, the verification commands with
   their results, which checks were absent, and any architecture finding named for
   `improve-architecture`. No net-lines figure: fewer lines is not the goal.

## Hard gates

Gate: explain before removing. Code whose purpose, callers and failure mode you cannot state stays
as it is, and the summary says why it stayed.

Gate: behavior is preserved exactly. Outputs, errors, side effects and ordering are the same before
and after; a cleanup that changes any of them is refused, not relabelled.

Gate: no safety check is simplified away. Trust-boundary validation, authorization, data-loss
protection, bounds checks, locks, error propagation and accessibility affordances stay, however
redundant they look from inside the scope.

Gate: an interface outside the scope keeps its shape. An export, a serialized field or a
compatibility path is removed only when it was never deployed, persisted, public or consumed, and
that is shown, not assumed.

Gate: verification is never weakened to make a pass green. No assertion relaxed, no test deleted,
no check skipped, no threshold lowered.

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "It's obviously dead — delete it." | Code that looks unused may be reached by a dynamic import, a framework convention or a consumer outside the repo. | Show non-use project-wide first; if uncertain, skip it. |
| "We're in a hurry; I'll clean up and run the tests after." | A batch of unverified edits leaves no way to tell which one broke the behavior. | Lock behavior first and verify after every pass. |
| "This fallback is ugly; I'll make it a cleaner default." | A masking fallback made quieter hides the failure better. | Classify it and report it as masking. |
| "The test fails after my change, so the test is out of date." | The test described the behavior this skill must preserve. | Revert the change; the test wins. |
| "While I'm here, this module should be split." | Structural redesign is a different, human-started run. | Name the finding for `improve-architecture`. |
| "The project's size target says this file is too long." | A size or ratio number is guidance, never a finding on its own (ruling `numeric-heuristics-are-guidance`). | Find the behavior-level problem, or leave it. |

## Outputs

- The simplified scope in the workspace, left for the lane that owns integration.
- A cleanup summary as a run artifact: fixes by lens, skipped fixes with reasons, masking fallbacks
  found, verification commands with exit status, absent checks, and handed-off architecture
  findings. A finding in it rests on behavioral evidence; a size target or a test-shape ratio is
  never grounds for one on its own (ruling `numeric-heuristics-are-guidance`).
- This skill publishes nothing to the knowledgebase and opens no ticket.

## Side effects

`workspace-write`, `process-exec`, `scratch-write`, `artifact-write`. No commit, no push: the
changes stay in the workspace for whoever owns integration. No remote side effect.

## Stop conditions

- `complete` — the passes are applied and verified, and the summary is returned.
- `complete` — the scope held nothing to simplify, or was docs, generated or lockfile only.
- `needs-input` — no scope can be resolved, or the baseline is red before any change.
- `failed` — a pass broke verification and could not be reverted to green.
- `cancelled` — the caller withdrew; any unverified pass is reverted first.

## Limits

- Scope: the resolved file set plus forced import and export lines (gate).
- Changes per verification: one pass at a time, verified before the next (gate).
- Size targets and test-shape ratios: configurable per project, never a finding alone (guidance).
