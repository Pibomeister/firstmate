# Codebase design

Shared vocabulary for designing **deep modules**: a large amount of behaviour behind a small
interface, placed at a clean seam, testable through that interface. The aim is leverage for callers,
locality for maintainers, and testability for everyone.

`codebase-design` loads this for a bounded reference answer or to state the vocabulary and stop.
`super-align` loads it to keep an alignment conversation precise about what a module is and where a
seam goes, before any of it is built. `improve-architecture` loads the same language plus the
deepening material below to restructure code that already exists. The glossary is the part all
three need; the two files under "Going deeper" are loaded only for the relevant question or
deepening work.

## Glossary

Use these terms exactly. Do not substitute "component", "service", "API" or "boundary" — consistent
language is the whole point, and a conversation carrying four names for a seam has stopped being a
design conversation.

**Module**: anything with an interface and an implementation. Deliberately scale-agnostic: a
function, a class, a package, or a tier-spanning slice. _Avoid_: unit, component, service.

**Interface**: everything a caller must know to use the module correctly — the type signature, and
also the invariants, ordering constraints, error modes, required configuration and performance
characteristics. _Avoid_: API, signature; both are too narrow, naming only the type-level surface.

**Implementation**: what is inside a module, its body of code. Distinct from **adapter**: the same
module can be a small adapter with a large implementation (a Postgres repository) or a large adapter
with a small implementation (an in-memory fake). Reach for "adapter" when the seam is the topic,
"implementation" otherwise.

**Depth**: leverage at the interface — the amount of behaviour a caller or a test can exercise per
unit of interface it has to learn. A module is **deep** when a large amount of behaviour sits behind
a small interface, and **shallow** when the interface is nearly as complex as the implementation.

**Seam** _(Michael Feathers)_: a place where you can alter behaviour without editing in that place;
the *location* at which a module's interface lives. Where to put the seam is its own design
decision, distinct from what goes behind it. _Avoid_: boundary, which is overloaded with the bounded
context of domain-driven design.

**Adapter**: a concrete thing that satisfies an interface at a seam. Names a *role* — which slot it
fills — not a substance.

**Leverage**: what callers get from depth. More capability per unit of interface they learn. One
implementation pays back across N call sites and M tests.

**Locality**: what maintainers get from depth. Change, bugs, knowledge and verification concentrate
in one place instead of spreading across callers. Fixed once is fixed everywhere.

## Deep and shallow

| | Interface | Implementation |
|---|---|---|
| Deep | Few entry points, simple parameters | Large; the complexity sits behind them |
| Shallow | Many entry points, complex parameters | Thin; it mostly passes through |

Three questions to ask of an interface under design:

- Can the number of entry points come down?
- Can the parameters be simpler?
- Can more complexity move inside?

## Principles

**Depth is a property of the interface, not of the implementation.** A deep module can be internally
composed of small, substitutable parts; they are simply not part of its interface. A module can have
**internal seams**, private to its implementation and used by its own tests, as well as the
**external seam** at its interface.

**The deletion test.** Imagine deleting the module. If complexity vanishes, it was a pass-through.
If complexity reappears across N callers, it was earning its keep.

**The interface is the test surface.** Callers and tests cross the same seam. Wanting to test *past*
the interface is evidence that the module is the wrong shape, not a reason to widen the interface.

**One adapter means a hypothetical seam. Two adapters means a real one.** Do not introduce a seam
unless something actually varies across it.

## Designing for testability

1. **Accept dependencies, do not create them.** A routine handed its payment gateway is testable;
   one that constructs the gateway inside itself is not.
2. **Return results, do not produce side effects.** A calculation that returns a discount is
   testable; one that mutates the cart in place is not.
3. **Keep the surface small.** Fewer entry points mean fewer tests, and fewer parameters mean
   simpler setup.

## How the terms relate

- A **module** has exactly one **interface**: the surface it presents to callers and to tests.
- **Depth** is a property of a module, measured against its interface.
- A **seam** is where a module's interface lives.
- An **adapter** sits at a seam and satisfies the interface.
- Depth produces **leverage** for callers and **locality** for maintainers.

## Rejected framings

These were considered and are not used here. A design conversation reaching for one of them is
re-opening a settled question, and the reason it was settled is recorded so it does not have to be
re-derived each time.

- **Depth as the ratio of implementation lines to interface lines.** It rewards padding the
  implementation. Depth here is leverage, which a line count does not measure.
- **"Interface" as a language keyword, or as a class's public methods.** Too narrow: interface here
  includes every fact a caller must know, among them invariants and error modes that no type
  signature carries.
- **"Boundary".** Overloaded with the bounded context of domain-driven design. Say **seam**, or say
  **interface**.

## Going deeper

Both files below are loaded on demand rather than carried by every skill that needs the vocabulary
above. Long material reaches a skill through a reference pack loaded at the moment it is needed
(ruling `full-catalog-opt-in-profiles`), and the cost of this pack is paid once by each skill in its
`loaded_by` list — so material earns its place against those skills or it does not belong here.

- [`./DEEPENING.md`](./DEEPENING.md) — dependency categories, seam discipline, and replace-rather-
  than-layer testing. How to deepen a cluster of shallow modules safely, given what it depends on.
- [`./DESIGN-IT-TWICE.md`](./DESIGN-IT-TWICE.md) — exploring several radically different interfaces
  for one deepening candidate, then comparing them on depth, locality and seam placement.
