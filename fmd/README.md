# fmd: the opt-in Firstmate supervision sidecar

fmd is a separate Rust program that reads the same state files the bash scripts write.
Bash stays the default and the fallback.
Nothing in this directory is needed to run Firstmate.
The crate uses only the Rust standard library, so a build needs cargo and no network.

## Build

Run `cargo build --release --manifest-path fmd/Cargo.toml` on each host that will run fmd.
The binary lands at `fmd/target/release/fmd`.
Binaries built on the host need no distribution step.
Do not commit `fmd/target/`.

## Modes

The home-local file `config/supervision` holds one line: `legacy`, `shadow`, or `fmd`.
A missing file or any other value means `legacy`.
`bin/fm-fmd-seam.sh` is the single reader of that file for bash callers.
`fmd mode --home <FM_HOME>` prints the same verdict from the Rust side.
Both readers take the raw first line with no trimming and honor `$FM_CONFIG_OVERRIDE`.

In `legacy`, the bash watcher is the only supervision path.
In `shadow`, bash stays authoritative and fmd output may be compared against it.
In `fmd`, a caller may defer to fmd only when `fm_fmd_defer` also finds a usable binary.
When the binary is absent, callers stay on bash.

## What this slice provides

`fmd open-decisions`, `fmd last-event`, `fmd meta`, `fmd snapshot`, `fmd beat`, and `fmd check` read `state/<id>.status`, `state/<id>.meta`, and `state/.last-watcher-beat`.
This slice is read-only: no command writes to a home.
The binary counts for the seam only through `$FM_FMD_BIN` or this repo's `fmd/target/` builds, never through `PATH`.
Parity fixtures live under `fmd/fixtures/`.
They cover each rule where a looser reader would disagree with bash: exact correlation tokens, complete key tokens, empty `kind=`, symlinked status and meta files, CR bytes, and the `FM_CLASSIFY_*` verb and prefix overrides.

## Upstream sync

Run `bin/fm-fmd-check.sh` for every upstream sync batch before the batch merges.
The check bounds each upstream-owned script to at most one seam line.
The check compares fmd output with `bin/fm-classify-lib.sh` on the same fixtures.
The check runs `fmd check` on a fixture home, never on live fleet state.
Do not rewrite `fm-watch.sh`, `fm-crew-state.sh`, or `fm-spawn.sh` in place.

## Later slices

S11 and S12 add the event-driven daemon that replaces per-home polling loops.
S13 moves the admission gate into fmd.
S14 compiles only the paths that run per tick, per worker, or per tool call.
S15 adds the soak harness that scores wake precision and recall against injected events.
Bash-only fixes such as S5, S9, and S10 stay upstream-compatible plain bash.
S9 conditional requests use ETags on REST only, because the GraphQL API has no conditional requests.

## Gates that stay in force

Host caps stay at the scale plan's After-P1 numbers until fmd lands and its gate passes.
Those numbers are M4 28 and M3 15 to 18.
The goodword host is 20 to 24 while it also serves as the test runner.
The P0 gate carries a Mac Studio swap target alongside its disk and record targets.
Task teardown must kill the task's whole process group on finish.
That teardown change belongs to the bash teardown slice, not to this scaffold.
