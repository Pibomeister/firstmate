# Design it twice

A procedure for exploring alternative interfaces for a chosen deepening candidate, on the premise
that a first idea is unlikely to be the best one. Uses the vocabulary in
[`./REFERENCE.md`](./REFERENCE.md): **module**, **interface**, **seam**, **adapter**, **leverage**.

This is a deliberate detour and it is not free. Run it when the interface under design is one the
deletion test says is load-bearing, and skip it when a single obvious shape already satisfies the
three questions in the glossary file.

## 1. Frame the problem space

Before dispatching anything, write the problem space out for the human:

- The constraints any new interface would have to satisfy.
- The dependencies it would rely on, and which category each falls into
  ([`./DEEPENING.md`](./DEEPENING.md)).
- A rough illustrative sketch to make the constraints concrete. It is not a proposal, and saying so
  is part of showing it.

Show this to the human and proceed immediately. They read while the explorations run.

## 2. Explore in parallel

Dispatch three or more independent explorations, each producing a **radically different** interface
for the deepened module. Each brief is technical and self-contained — file paths, coupling details,
the dependency category, and what sits behind the seam — and is independent of the human-facing
framing from step 1. Give each exploration a different design constraint:

- Minimise the interface: one to three entry points, maximum leverage per entry point.
- Maximise flexibility: many use cases, room for extension.
- Optimise for the most common caller: make the default case trivial.
- Where dependencies cross a seam: design around ports and adapters.

Each brief carries both this pack's vocabulary and the project's own domain language, so that the
returned designs name things consistently with both. The project's terms come from the
knowledgebase glossary, read through the KB adapter, not from a file in the working repository.

Each exploration returns:

1. The interface — types, entry points, parameters, plus invariants, ordering and error modes.
2. A usage example showing how a caller uses it.
3. What the implementation hides behind the seam.
4. The dependency strategy and its adapters.
5. Trade-offs: where leverage is high, and where it is thin.

## 3. Present and compare

Present the designs one at a time so the human can absorb each before the next, then compare them in
prose on three axes: **depth** (leverage at the interface), **locality** (where change concentrates),
and **seam placement**.

Finish with a recommendation — which design is strongest and why. Where elements of two would
combine well, propose the hybrid explicitly. A menu is not a recommendation.
