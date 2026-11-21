# Stall watch verification

Audience: maintainer verification.

This record supports the opt-in `bin/fm-stall-watch.sh` contract owned by [`../configuration.md`](../configuration.md) ("Stall watch").
It records only facts that must be re-established when a classifier, its CLI, or the recorded screen shapes change.
The Jev API facts the stall watch relies on (the `POST /v1/systemone` Choice shape, error shapes, and observed latency) are recorded in [the typed dispatch resolution record](dispatch-resolve.md#the-api-the-tool-depends-on).

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

- The Jev classifier has no live run on record yet; run `classify` with `TYPESAFE_API_KEY` set to measure it.
- Six recorded screens are a smoke test of the classifier path, not a calibration of `confidence_floor`.
