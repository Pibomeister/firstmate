# Feedback loops for diagnosis

Loaded on demand by `diagnose`'s Phase 1. The body carries the gate — no red-capable command, no
hypothesis — and this file carries the catalog behind it.

## Ways to construct one, in roughly this order

1. **A failing test** at whatever seam reaches the bug: unit, integration or end-to-end. Cheapest
   to run and the only technique that leaves the regression test behind as a by-product.
2. **An HTTP script** against a running development server, asserting on status, body or headers.
3. **A command-line invocation** with a fixture input, diffing its output against a known-good
   snapshot.
4. **A headless browser script** that drives the interface and asserts on the document, the console
   or the network.
5. **A replay of a captured trace.** Save a real request, payload or event log to disk and replay it
   through the code path in isolation.
6. **A throwaway harness.** Stand up the smallest subset of the system — one service, its
   dependencies faked — that reaches the bug's code path in a single call.
7. **A property or fuzz loop.** Where the symptom is "sometimes wrong output", run many generated
   inputs and look for the failure mode rather than for a specific input.
8. **A bisection harness.** Where the bug appeared between two known states — a commit, a dataset,
   a dependency version — automate "restore state X, check, repeat" so the search runs unattended.
9. **A differential loop.** Run one input through two versions or two configurations and diff the
   outputs; the diff is the signal.
10. **A human in the loop.** Last resort, and still structured: the person performs the step the
    automation cannot, and their captured output feeds the same loop. A step a person performs is
    recorded like any other, with what was done and what came back.

## Tightening

Once any loop exists, treat it as the thing being built:

- **Faster.** Cache the setup, skip unrelated initialisation, narrow the scope to the failing path.
- **Sharper.** Assert on the reported symptom, not on the absence of a crash. A loop that goes green
  on a different bug is a loop that lies twice.
- **More deterministic.** Pin the clock, seed the generator, isolate the filesystem, freeze the
  network. A flaky thirty-second loop is barely better than no loop; a deterministic two-second one
  changes what the rest of the run can do.

## Bugs that do not reproduce every time

The target is not a clean reproduction but a **higher reproduction rate**. Loop the trigger, run it
in parallel, add load, narrow the timing window, inject delays. Raise the rate until the loop is
worth consuming, and record the rate achieved: a loop that goes red one run in fifty is evidence
about the bug and not yet an instrument for finding it.

## Performance regressions

Logs are usually the wrong instrument. Establish a baseline measurement first — a timing harness, a
profiler, a query plan — then bisect against it. Measure before changing anything, or there is
nothing to compare the change against.

## When no loop can be built

Stop and say so, listing what was tried. What would unblock it is one of: access to an environment
that reproduces the failure, a captured artifact with its secrets redacted, or permission to add
temporary instrumentation where the failure occurs. None of those is something this skill grants
itself, and none of them is a reason to proceed to a hypothesis without a loop.
