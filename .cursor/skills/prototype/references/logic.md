# Logic branch

Used from `../SKILL.md`, step 3, when the question is about business logic, state transitions or
data shape: something that looks reasonable on paper and feels wrong once real cases go through it.
If the question is what something should look like, this is the wrong branch; take the UI branch.

The artifact is one self-contained page that lets anyone drive a state model by pressing buttons.
It needs nothing installed, so a designer or a domain expert can drive it too, and it speaks their
language rather than the code's.

## When this is the right shape

- Whether a state machine handles the case where X happens and then Y.
- Whether a data model can represent a particular awkward case at all.
- How an interface should feel to call, before anyone writes it.
- Anything where the evaluator wants to press buttons and watch state change.

## Build

1. **State the question.** One paragraph, visible at the top of the page and not only in a
   comment, with the evaluator named beside it. A prototype that answers the wrong question is
   waste, and a stated question can be checked later by whoever evaluates it.
2. **Isolate the logic in a pure module.** Put the part that answers the question in one script
   block, written as a small pure module. Pick the shape the question needs, not the one easiest
   to wire to a page:
   - a reducer, `(state, action) => state`, when actions are discrete events;
   - a state machine, when which actions are legal right now is part of the question;
   - a few pure functions over a plain data type, when there is no current state;
   - a class with a clear method surface, when the logic owns ongoing state.
   No DOM access, no `document`, no handlers reaching in. The page calls the module; nothing flows
   back. This is what lets automated acceptance criteria drive the module directly for a
   technical question.
3. **Build the page.** Plain HTML, CSS and script inline in one file: no framework, no bundler, no
   server. Every label in domain language. Top to bottom:
   1. Title and one line on what the page explores (the question).
   2. The current state as a readable panel of labelled fields, not a raw dump, re-rendered after
      every action, with what just changed called out.
   3. Free-play buttons, one per action, always available.
   4. Guided walkthroughs, one per tab: a plain description of the scenario and what to watch
      for, then the ordered buttons to press. Starting one resets to a known initial state. Cover
      the happy path, an awkward edge case, and an attempt at something that should be illegal.
   Restrained styling: clean type, generous spacing, one accent colour, no animation.
4. **Hand it to the evaluator.** For a technical question, run the acceptance criteria against the
   module and show which passed. For a question a person settles, give them the file. The useful
   moments are "that should not be possible" and "I assumed that would be different": bugs in the
   idea, which is the point.
5. **Capture the answer.** The answer and the validated shape of the module go into the evaluation
   record. The page stays in the workspace as the primary source. The module is evidence for the
   real design; the lane that owns the change rewrites it under the project's standards rather
   than copying it in.

## Anti-patterns

- **Tests.** A prototype that needs tests is no longer a prototype. Acceptance criteria for a
  technical question are the evaluator, not a test suite that ships.
- **The real database.** In-memory state unless persistence is the question.
- **Generalising.** No support for what might be wanted later. One question.
- **Logic blurred into the page.** A module that touches the DOM cannot be driven on its own.
- **A framework, bundler or server.** One file that opens by itself.
- **Shipping the page.** It is built to be clicked through by hand, never to reach production.
