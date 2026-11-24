# Watchdog publication: product evidence

The real bin/fm-watchdog.sh once --dry-run ran against disposable homes. Terminal readers, outward tools, replacement failures, and the clock were synthetic. This proves the local publication contract. It does not prove live-runtime causation or adoption.

Revision: 2b27a08454d55e510b9dbb809e753b61c8fa0886. Interpreter: stock /bin/bash 3.2.57.

Fixture paths and host identity are redacted in retained product output.

## Cumulative read observations

The oracle parses the expiry printed by the product and compares it to each simulated read time. It independently requires the prior complete body to remain unchanged and the completed count to exclude the current worker. Each read advances the synthetic clock by 14 seconds; these are simulated seconds, not host performance measurements.

| Reader | Read epoch | Published expiry epoch | Expired | Observed product header |
|---|---:|---:|---|---|
| term-fixture-1 | 1700000134 | 1700000660 | False | updated 2023-11-14T22:13:20Z, scan every 120s, mode dry-run, restart off |
| term-fixture-14 | 1700000274 | 1700000920 | False | updated 2023-11-14T22:17:40Z, scan every 120s, mode dry-run, restart off; scan incomplete; completed worker checks 5; last complete 2023-11-14T22:13:20Z |
| term-fixture-19 | 1700000414 | 1700001060 | False | updated 2023-11-14T22:20:00Z, scan every 120s, mode dry-run, restart off; scan incomplete; completed worker checks 10; last complete 2023-11-14T22:13:20Z |
| term-fixture-4 | 1700000554 | 1700001200 | False | updated 2023-11-14T22:22:20Z, scan every 120s, mode dry-run, restart off; scan incomplete; completed worker checks 15; last complete 2023-11-14T22:13:20Z |
| term-fixture-9 | 1700000694 | 1700001340 | False | updated 2023-11-14T22:24:40Z, scan every 120s, mode dry-run, restart off; scan incomplete; completed worker checks 20; last complete 2023-11-14T22:13:20Z |

Final complete publication:

```text
# Firstmate watchdog - isolated-test-host
updated 2023-11-14T22:25:08Z, scan every 120s, mode dry-run, restart off
STALE IF NOT UPDATED BY 2023-11-14T22:36:08Z (watchdog may be down)
models: none; spent 24h $0 of $1.00

## Homes
- cumulative: NO-ENDPOINT, owed 1, ctx unknown; no lock holder

## Actions since last read (2023-11-14T21:25:08Z)

## Open gaps
- cumulative: no activity source; frozen, dead-holder, and low-context restarts are unavailable
- cumulative: no recorded terminal endpoint; the pane cannot be read or typed into
- no model configured; judged symptoms are reported only
```

## Fast control

```text
# Firstmate watchdog - isolated-test-host
updated 2023-11-14T22:15:48Z, scan every 120s, mode dry-run, restart off
STALE IF NOT UPDATED BY 2023-11-14T22:26:48Z (watchdog may be down)
models: none; spent 24h $0 of $1.00

## Homes
- control: NO-ENDPOINT, owed 1, ctx unknown; no lock holder

## Actions since last read (2023-11-14T21:15:48Z)

## Open gaps
- control: no activity source; frozen, dead-holder, and low-context restarts are unavailable
- control: no recorded terminal endpoint; the pane cannot be read or typed into
- no model configured; judged symptoms are reported only
```

## Blocked reader

The public regression waited for the reader to enter, advanced the simulated clock past the prior expiry, and compared the persisted publication byte-for-byte before releasing the reader. The comparison passed. The retained prior publication is publication/blocked/status.good; no timer-only rewrite was accepted.

## Final replacement refused

```text
fixture status replacement refused
fm-watchdog: complete publication failed
public_exit=73; previous publication retained byte-for-byte
```

## Filtered scan: progress replacement refused, final replacement succeeds

Workers: 1; public exit: 1.

```text
fixture status replacement refused
fm-watchdog: progress publication failed
progress refused
complete replaced
```

Workers: 2; public exit: 1.

```text
fixture status replacement refused
fm-watchdog: progress publication failed
fixture status replacement refused
fm-watchdog: progress publication failed
progress refused
progress refused
complete replaced
```

Each case retained the unhandled wake queue and held decision byte-for-byte. No outward or model action was accepted.

## Regression controls

On base d3d97c97d7bcd7dac112f0167186502a11373152, the same cumulative-read oracle observed expired reads, and the final-replacement regression observed public exit 0 after replacement refusal. Both test selections exited 1 as expected.

On pre-R1 revision 77c67aa3, the filtered scan returned public exit 0 despite a progress failure and final success. Its regression exited 1 as expected. The target returned 1 for both one-worker and two-worker cases.
