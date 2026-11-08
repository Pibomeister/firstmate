#!/usr/bin/env bash
# Live drive of window edges with the fm_now seam: a wake still queued at a window end,
# and a minted-but-never-written sequence number.
set -u
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null
export FM_HOME="$LAB"; unset FM_STATE_OVERRIDE FM_ROOT_OVERRIDE NO_MISTAKES_GATE
S="$LAB/state"
enq() { STATE="$S" FM_WAKE_QUEUE="$S/.wake-queue" bash -c '. bin/fm-wake-lib.sh; fm_wake_append "$@"' _ "$@"; }
drain() { local now=$1; shift; FM_TEST_SEAM=1 FM_NOW=$now bin/fm-wake-drain.sh "$@"; }
ackall() { local now=$1; drain "$now" >/dev/null 2>"$LAB/err"
  set -- $(sed -n 's/.*--ack-through \([0-9]*\) --recovery-generation \([^ ]*\)$/\1 \2/p' "$LAB/err")
  drain "$now" --ack-through "$1" --recovery-generation "$2" >/dev/null 2>&1; echo "ack-through $1 at t=$now exit=$?"; }
echo "== window A [1000,2000): wakes 1,2 acked at t=1000"
enq signal x1 a; enq signal x2 b; ackall 1000
echo "== sequence 3 minted but never written (counter bumped, no queue row)"
echo 3 > "$S/.wake-queue.seq"
echo "== wake 4 queued before window A end, acked only at t=2500 (window B)"
enq check inbox c
cut -f2-4 "$S/.wake-queue"
echo "count A (before wake 4 is acked):"; bin/fm-wake-ledger.sh count --since 1000 --until 2000
ackall 2500
cat "$S/wake-ledger.tsv" | cut -f1-5
echo "count A (after):  $(bin/fm-wake-ledger.sh count --since 1000 --until 2000)"
echo "count B [2000,3000): $(bin/fm-wake-ledger.sh count --since 2000 --until 3000)"
echo "count A+B [1000,3000): $(bin/fm-wake-ledger.sh count --since 1000 --until 3000)"
rm -rf "$LAB"; echo "lab removed"
