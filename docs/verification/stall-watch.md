# Stall watch verification

Audience: maintainer verification.

This record supports the opt-in `bin/fm-stall-watch.sh` contract owned by [`../configuration.md`](../configuration.md) ("Stall watch").
It records only facts that must be re-established when a classifier, its CLI, or the recorded screen shapes change.

## Which model "JEV" means

The request named a cheap classifier called "JEV" and could not be clarified with its author.
It is interpreted as TypeSafe Jev (`jev-latest`), the decision model this repository already calls for typed dispatch resolution, so `classifier=jev` is the default.
The Jev API facts the stall watch relies on (the `POST /v1/systemone` Choice shape, error shapes, and 123 to 348 ms observed latency) are recorded in [the typed dispatch resolution record](dispatch-resolve.md#the-api-the-tool-depends-on).
No TypeSafe key was available on the verification host, so the Jev path is covered by the test suite's recorded request and answer shapes, not by a live call.

## Live Grok fallback run

Run 2026-11-21 on macOS with no TypeSafe key, `classifier=jev` (the default), `grok_model=grok-4.7-build-fast`, and the installed `grok` CLI, through `bin/fm-stall-watch.sh classify` on each recorded screen in `tests/fixtures/stall-watch/`.
Every model-judged screen logged `jev unavailable (no TypeSafe key in the environment, .env, or a declared source); using the deterministic result plus grok` and carried `note=jev:no-key`.

| Screen | Status line given | Verdict | Source | Confidence | Latency | Reported cost |
| --- | --- | --- | --- | --- | --- | --- |
| `working.screen` | none | `working` | rule | - | - | - |
| `rate-limited.screen` | none | `rate_limit` | rule | - | - | - |
| `waiting-on-human.screen` | none | `waiting_on_human` | grok | 0.97 | 12.4 s | $0.0633 |
| `stalled.screen` | `working: wiring the parser` | `idle_with_goals` | grok | 0.86 | 18.7 s | $0.0671 |
| `idle-done.screen` | `working: final checks` | `idle_done` | grok | 0.93 | 10.9 s | $0.0644 |
| `api-error.screen` | `working: running the suite` | `api_error` | grok | 0.93 | 10.5 s | $0.0644 |

Every verdict matched the screen's hand label.
The Claude permission box in `waiting-on-human.screen` has no picker footer row, so the watchdog dialog rule does not recognize it and the model decided it, which is the case the classifier exists for.
The reported cost is the `total_cost_usd` the `grok` CLI prints for the call.

## Live dry-run check

`bin/fm-stall-watch.sh check <task-id> --dry-run` against a live Droid worker in an Orca terminal read its screen through the backend, returned `verdict=working stalled=no source=busy` in about 1 s with no model call, and wrote no record.
That screen showed Droid's `Executing...  (Press ESC to stop)` row, which the activity rule now also recognizes.

## Limitations

- The Jev path has no live run on record yet; re-run the table above with `TYPESAFE_API_KEY` set to measure it.
- Six recorded screens are a smoke test of the classifier path, not a calibration of `confidence_floor`.
- A Grok call takes 10 to 19 s, so `timeout` should stay well above 20 s.
