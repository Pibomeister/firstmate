# worktree-ownership

Isolation plus disjoint write ownership. Two tasks that would write the same file, the same
generated artifact, the same global migration sequence or the same interface are serialized —
whether or not the ticket graph drew an edge between them. Every parallel set names one
integration owner.

Dependency edges say what must happen *before* what. They say nothing about what may happen *at
the same time*. That gap is where parallel work corrupts itself.

## When to use

`super-build` invokes this protocol before dispatching any ticket, and again before dispatching
two or more tickets together. `diagnose` and `ultraqa` invoke it when their work needs a
workspace the rest of the run is not writing into. Any skill that is about to start work in a
shared checkout enters here first.

## Not for

- Not for deciding what the tickets are or how they depend on each other. The dependency graph
  arrives on the approved tickets; this protocol reads it and finds what it does not cover.
- Not for the work inside the isolated workspace. `tdd` and the ticket's own scope govern that.
- Not for forge mechanics — fetching a pull request, tracking a remote branch, opening a PR.
  Those belong to the skill that talks to the forge.
- Not for non-git isolation. This protocol assumes a worktree and reports a blocker when the
  host offers none, rather than improvising a substitute.

## Invoked by

`super-build`, `diagnose` and `ultraqa`, and the `qa.cycle` and `ci.repair` phase operations
before they write. `bound.run` is not an invoker: it writes artifacts and scratch, never the
workspace, so it has nothing to isolate. A protocol holds no authority of its own and never
widens the authority it was called with (ruling `entrypoint-phase-operation-split`; protocol
`phase-operations`).

## Inputs

- The approved tickets to be dispatched, each with `write_ownership` — `paths`,
  `generated_artifacts`, `migration_sequence`, `interfaces` — and its `read_dependencies`
  ([`schemas/ticket.schema.json`](../../schemas/ticket.schema.json)).
- The dependency graph among them.
- The target branch or ref for each ticket.
- The host's native worktree capability, when one exists (`isolated-worktree` in
  `common#/$defs/capability`).

A ticket with no declared `write_ownership` cannot be scheduled against another ticket. Return
`needs-input` naming the ticket; an undeclared surface is not an empty surface.

## Workflow

1. Detect existing isolation before creating anything. Compare the **resolved absolute** git
   directory against the **resolved absolute** common git directory; comparing the unresolved
   forms gives a false answer, because git mixes absolute and relative forms by working
   directory. Equal: a normal checkout. Different: check for a superproject working tree —
   present means a submodule, which is treated as a normal checkout; absent means the caller is
   already isolated.
2. Already isolated: report the workspace path and branch and work in place. A worktree created
   from inside a worktree lands in the wrong tree and is invisible to the host that made the
   current one.
3. Verify the isolation directory is ignored by version control, with `git check-ignore -q` or
   the host's equivalent. Probe the path with its trailing slash: this check runs before the
   directory exists, and git tests a path that is not on disk as a file, so a directory-only
   rule does not match the bare name. Add the rule before creating anything, never after.
4. Check the ref: a branch can be checked out in only one worktree at a time. Already checked
   out elsewhere: report the path where it lives and stop. Do not create a second worktree for
   it.
5. Create the workspace through the host's native worktree capability where one exists. A
   worktree created behind the host's back is state the host cannot see, navigate to or clean
   up.
6. Compute the write-ownership overlap across every ticket about to run together, on four
   surfaces: file and symbol paths, shared generated artifacts, global migration sequence
   numbers, and interfaces one ticket defines and another consumes.
7. Serialize any pair that overlaps on any of the four, regardless of whether a dependency edge
   connects them. Record the serialization and its reason.
8. Assign exactly one integration owner for the parallel set and record it on the tickets.
9. Dispatch the non-overlapping tickets together, each with a self-contained prompt naming its
   own scope, its own expected output, and the ownership it holds.
10. Report the workspace path and branch for each dispatched ticket, or the blocker instead.

## Hard gates

Gate: two tickets whose write ownership overlaps on any of the four surfaces do not run
concurrently. A missing dependency edge is not permission; the edge describes ordering, not
exclusivity.

Gate: a parallel set with no integration owner does not dispatch. Someone owns the merge of the
results before the results exist.

Gate: worktree creation that fails for a sandbox or permission reason stops the run and surfaces
the choice. The requested isolation does not exist, and continuing in the shared checkout
defeats the reason it was requested. Alternative paths are not tried automatically.

Gate: a host with no worktree capability returns a blocker. This protocol does not simulate
isolation with a branch switch in the shared checkout.

Gate: the ignore rule is verified before creation, not after. A workspace created into a tracked
directory has already dirtied the repository by the time anyone notices.

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "These two tickets have no dependency edge, so they can run together." | An edge is an ordering constraint. Two independent tickets can still write the same generated file or claim the same migration number. | Compare their `write_ownership` on all four surfaces and serialize on any overlap. |
| "Creating the worktree directly with version control is the same thing and it is one command." | A workspace created behind the host's back is state the host cannot see, navigate to or clean up, and it outlives the run that made it. | Use the host's native worktree capability. Where none exists, report the blocker. |
| "I am already in a worktree; making another one keeps this task separate." | A worktree made from inside a worktree lands in the wrong tree and is invisible to whatever created the current one. | Report the current workspace path and branch and work in place. |
| "Isolation could not be created, but the change is small; the shared checkout is fine." | The isolation was requested for a reason that does not shrink with the diff, and a sandbox failure is not a signal that isolation was unnecessary. | Stop and surface the choice. Do not continue unisolated. |
| "That branch is checked out somewhere else, so I will make a second worktree for it." | A branch lives in one worktree at a time; forcing a second one produces two trees that disagree about the same ref. | Report the path where it is already checked out and let the caller decide. |
| "Both writers only touch that shared file a little." | Concurrent partial writes to one artifact produce a result neither writer intended and neither review covers. | Serialize them and record why. |

## Outputs

Per dispatched ticket: the workspace path, the branch, and the `write_ownership` it holds, all
recorded on the [`schemas/ticket.schema.json`](../../schemas/ticket.schema.json) record. Per parallel set: the `integration_owner`,
the serialization decisions with their reasons, and the overlap surfaces that produced them. On a
blocker: the blocker instead of a workspace, with what was attempted.

## Side effects

`workspace-write`, `branch-create`, `scratch-write`, `artifact-write`. No `remote-push`: this
protocol creates local isolation and never publishes it.

## Stop conditions

- `complete`: every dispatched ticket has an isolated workspace, a recorded branch, disjoint
  ownership, and the set has an integration owner.
- `needs-input`: a ticket declares no `write_ownership`, no integration owner can be assigned, or
  the requested ref is already checked out elsewhere.
- `cap-reached`: the invoking operation's dispatch budget was reached. Returns the tickets not
  yet dispatched.
- `failed`: worktree creation failed for a sandbox or permission reason, or the host offers no
  worktree capability.
- `cancelled`: the runner cancelled the run.

## Limits

- Worktrees per branch: 1 (gate).
- Integration owners per parallel set: exactly 1 (gate).
- Overlap surfaces checked: 4 (gate) — paths, generated artifacts, migration sequence,
  interfaces. Fewer is not a shorter check; it is an unchecked surface.
