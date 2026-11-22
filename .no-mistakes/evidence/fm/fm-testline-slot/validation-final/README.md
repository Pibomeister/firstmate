# Targeted live validation

Revision: `465e35bbdcea87d27050220983ca5c6ef7a1b3db`.
Base: `88ee1f6152e3bb52746e951b63505de1597ff4ac`.

`live-transcript.log` records real queue, refresh, and snapshot commands against disposable homes. Queue load 200 and 95, refresh clock epochs, invalid snapshot budget values, and a FIFO failure log are synthetic inputs. No replacement product or producer is used. `recovered-ledger.json` is the real producer's published output.

`watcher-retry.log` records the real watcher on a private tmux socket. The first attempt used a socket path beyond the Unix socket length limit. The retry used a shorter path inside the worktree, passed, and stopped the server. `live-results-final.json` includes the corrected setup result.

The backoff oracle is the approved fixed sequence: 30, 60, 120, 240, 480, 960, 1800, 1800 seconds. Pre-expiry calls must leave the failure log and record unchanged. Direct successful publication must clear backoff. FIFO stalls must preserve the previous ledger and return best-effort success within the bounded refresh and diagnostic budgets. Queue admission must preserve FIFO order, keep one slot available at high load, and hold a second slot until load falls below 96.

`home-summary-suite.log` and `test-queue-suite.log` retain the required colocated suite runs; their `.exit` files contain the actual final statuses. They are supplemental regression evidence, not substitutes for the direct product transcript. The home-summary suite also controls validator and filesystem boundaries to exercise delayed-overwrite and lock-held deadline regressions.

All disposable data stayed under the run worktree. The direct driver removed its homes and reaped its processes. No source changes were made.

Both colocated suites completed with exit status 0. All six direct live scenarios passed after correcting the socket setup. The final process check found no remaining test processes. Temporary worktree files were removed.
