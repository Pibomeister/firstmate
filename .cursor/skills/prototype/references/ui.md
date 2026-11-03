# UI branch

Used from `../SKILL.md`, step 3, when the question is what something should look like. If it is
about logic or state, this is the wrong branch; take the logic branch.

The artifact is several structurally different variations of one screen, switchable from a
floating bar. The evaluator flips between them, picks one or takes parts from several, and the rest
is thrown away. A question about how a screen reads is a human-experience question: its evaluator
is a named human, and with none present the run stops before this branch starts (ruling
`prototype-human-experience-needs-human`).

## When this is the right shape

- What a page should look like.
- A few options for a dashboard before committing to one.
- A different layout for an existing screen.

## Where the variants live

Variants are far easier to judge beside the rest of the app: real header, real data, real density.
Alone on an empty route, every variant looks fine.

- **Inside an existing page (preferred).** Variants render on the same route, chosen by a
  `?variant=` parameter. Data fetching, parameters and auth stay; only the rendered subtree
  changes. Something that would naturally sit inside an existing page (a new section, card or
  step) still goes here. This needs an isolated worktree from the runner, never the working tree.
- **A new throwaway route (last resort).** Only when nothing existing could host it. Follow the
  project's routing convention and put `prototype` in the path or file name. Check first that no
  existing page could host it; an empty route hides the problems a populated one exposes.

## Build

1. **State the question and the count.** Three variants by default, five at most; beyond five they
   stop being different and become noise. Write the plan in one line at the top of the prototype,
   with the evaluator named.
2. **Draft structurally different variants.** Each keeps the page's purpose, the data it can reach,
   and the project's own component library, under a clear name such as `VariantA`. They must
   differ in layout, information hierarchy or primary affordance. Two drafts that came out alike:
   redo one with the shared structure explicitly ruled out.
3. **Wire one switcher** on the route that renders the chosen variant from the parameter, with the
   existing data fetching kept above it.
4. **Build the floating bar.** Fixed at the bottom centre: a previous arrow, the current variant's
   key and name, a next arrow, both wrapping. Arrows update the URL parameter through the
   project's router so a variant is shareable and survives reload; the left and right keys cycle
   too, except while a text field or editable region has focus. It looks plainly unlike the
   design under evaluation. It is gated out of production builds (`NODE_ENV !== 'production'` or
   the project's equivalent), so a stray merge cannot ship it.
5. **Hand it to the evaluator.** Give the URL and the variant keys. The useful answer is often a
   combination: the header from B with the sidebar from C.
6. **Capture the answer.** Which variant won, why, and what the evaluator combined goes into the
   evaluation record. The variants and the switcher stay in the workspace as the primary source and
   never reach main. The lane that owns the change rewrites the winner properly.

## Anti-patterns

- **Variants that differ only in colour or copy.** A tweak, not a prototype.
- **Sharing a layout between variants.** A shared header is fine; a shared layout defeats the
  point.
- **Real mutations.** Read-only, or pointed at a stub. The question is how it looks, not whether the
  backend works.
- **Promoting the prototype to production.** It was written with no tests and minimal error
  handling. Rewrite it when it is folded in.
