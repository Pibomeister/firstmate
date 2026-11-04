# Deepening

How to deepen a cluster of shallow modules safely, given what the cluster depends on. Assumes the
vocabulary in [`./REFERENCE.md`](./REFERENCE.md): **module**, **interface**, **seam**, **adapter**.

## Dependency categories

Classify a deepening candidate's dependencies before proposing anything. The category decides how
the deepened module is tested across its seam, and therefore whether a port belongs at the seam at
all.

**1. In-process.** Pure computation, in-memory state, no I/O. Always deepenable: merge the modules
and test through the new interface directly. No adapter is needed.

**2. Local-substitutable.** Dependencies with a local test stand-in — an embedded Postgres, an
in-memory filesystem. Deepenable when the stand-in exists. The deepened module is tested with the
stand-in running in the suite. The seam is internal, and no port appears at the module's external
interface.

**3. Remote but owned.** Services you own across a network boundary. Define a **port** at the seam:
the deep module owns the logic and the transport is injected as an **adapter**. Tests use an
in-memory adapter; production uses one that speaks the wire protocol. The recommendation has a fixed
shape — *define a port at the seam, implement a transport adapter for production and an in-memory
adapter for testing, so the logic sits in one deep module even though it is deployed across a
network.*

**4. True external.** Third-party services you do not control. The deepened module takes the
external dependency as an injected port; tests provide a mock adapter.

## Seam discipline

**One adapter means a hypothetical seam. Two adapters means a real one.** Do not introduce a port
unless at least two adapters are justified — typically production plus test. A single-adapter seam
is indirection wearing a design term.

**Internal seams are not external seams.** A deep module may have internal seams, private to its
implementation and used by its own tests, alongside the external seam at its interface. Do not
expose an internal seam through the interface merely because a test uses it; that is how a deep
module becomes a shallow one over a few changes.

## Testing strategy: replace, do not layer

- Old unit tests against the shallow modules become waste once tests exist at the deepened module's
  interface. Delete them rather than keeping both layers.
- Write the new tests at the deepened module's interface. The interface is the test surface.
- Assert on outcomes observable through the interface, never on internal state.
- Tests should survive an internal refactor, because they describe behaviour rather than structure.
  A test that has to change when the implementation changes is testing past the interface, and that
  is a finding about the module's shape.
