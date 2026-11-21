# Stall watch verification

Audience: maintainer verification.

This record supports the opt-in `bin/fm-stall-watch.sh` contract owned by [`../configuration.md`](../configuration.md) ("Stall watch").
It records only facts that must be re-established when a classifier, its CLI, or the recorded screen shapes change.
The Jev API facts the stall watch relies on (the `POST /v1/systemone` Choice shape, error shapes, and observed latency) are recorded in [the typed dispatch resolution record](dispatch-resolve.md#the-api-the-tool-depends-on).

## Live Grok fallback run

Run 2026-11-21 on macOS (Darwin 25.5.0) with `grok 1.0.92 (b06756fd6256) [stable]`, no TypeSafe key, `classifier=jev` (the default), and `grok_model=grok-4.7-build-fast`.
Each recorded screen in `tests/fixtures/stall-watch/` was judged from the repository root with this command, adding `--status '<line>'` where the table names one:

```sh
FM_HOME=<home> bash bin/fm-stall-watch.sh classify < tests/fixtures/stall-watch/<screen>
```

| Screen | Status line given | Verdict | Source | Confidence | Latency | Reported cost |
| --- | --- | --- | --- | --- | --- | --- |
| `working.screen` | none | `working` | grok | 0.94 | 11.3 s | $0.0637 |
| `rate-limited.screen` | none | `rate_limit` | rule | - | - | - |
| `waiting-on-human.screen` | none | `waiting_on_human` | grok | 0.97 | 12.4 s | $0.0633 |
| `stalled.screen` | `working: wiring the parser` | `idle_with_goals` | grok | 0.86 | 18.7 s | $0.0671 |
| `idle-done.screen` | `working: final checks` | `idle_done` | grok | 0.93 | 10.9 s | $0.0644 |
| `api-error.screen` | `working: running the suite` | `api_error` | grok | 0.93 | 10.5 s | $0.0644 |

Every verdict matched the screen's hand label.
The exact output lines were:

```text
stall-watch: jev unavailable (no TypeSafe key in the environment, .env, or a declared source); using the deterministic result plus grok
stall-watch target=classify verdict=working stalled=no source=grok confidence=0.94 latency_ms=11297 cost_usd=0.06367384 action=none note=jev:no-key
stall-watch target=classify verdict=rate_limit stalled=yes source=rule confidence=- latency_ms=- cost_usd=- action=none
stall-watch target=classify verdict=waiting_on_human stalled=yes source=grok confidence=0.97 latency_ms=12402 cost_usd=0.06333248 action=none note=jev:no-key
stall-watch target=classify verdict=idle_with_goals stalled=yes source=grok confidence=0.86 latency_ms=18669 cost_usd=0.06713096 action=none note=jev:no-key
stall-watch target=classify verdict=idle_done stalled=no source=grok confidence=0.93 latency_ms=10861 cost_usd=0.06440552 action=none note=jev:no-key
stall-watch target=classify verdict=api_error stalled=yes source=grok confidence=0.93 latency_ms=10547 cost_usd=0.06440552 action=none note=jev:no-key
```

Every model-judged screen printed the same `jev unavailable` line shown once above.
`working.screen` shows a busy footer, which is never decided by rule, so the model judged it.
The Claude permission box in `waiting-on-human.screen` has no picker footer row, so the watchdog dialog rule does not recognize it and the model decided it.
The reported cost is the `total_cost_usd` the `grok` CLI prints for the call.

## Live dry-run check

Run 2026-11-21 under `time` against a live Droid 1.17.0 worker in an Orca terminal:

```sh
FM_HOME=<home> bash bin/fm-stall-watch.sh check <task-id> --dry-run
```

```text
stall-watch target=<task-id> verdict=working stalled=no source=busy confidence=- latency_ms=- cost_usd=- action=dry-run note=fingerprint=changed

real	0m1.036s
user	0m0.536s
sys	0m0.482s
```

It read the screen through the Orca backend, took `working` from the task's busy semantic record with no model call, and wrote no record.

## Limitations

- The Jev path has no live run on record yet; re-run the table above with `TYPESAFE_API_KEY` set to measure it.
- Six recorded screens are a smoke test of the classifier path, not a calibration of `confidence_floor`.
- A Grok call takes 10 to 19 s, so `timeout` should stay well above 20 s.
