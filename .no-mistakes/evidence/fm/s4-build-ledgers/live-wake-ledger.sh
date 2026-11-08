#!/usr/bin/env bash
# Live drive: lab home, real wake producer, real drain, real prune, real ledger CLI, real clock.
set -u
ROOT=$PWD
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
export FM_HOME="$LAB"
unset FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE NO_MISTAKES_GATE
S="$LAB/state"
enq() { STATE="$S" FM_WAKE_QUEUE="$S/.wake-queue" bash -c '. bin/fm-wake-lib.sh; fm_wake_append "$@"' _ "$@"; }
say() { printf '\n$ %s\n' "$*"; }
T_START=$(date +%s)
say "enqueue 3 wakes (two duplicate signals for task-a, one check) and 1 signal for task-b"
enq signal "$S/task-a.status" "first";  enq signal "$S/task-a.status" "dup"
enq check "inbox" "note";               enq signal "$S/task-b.status" "b"
cat "$S/.wake-queue" | cut -f2-4
say "drain (presentation)"
bin/fm-wake-drain.sh >/dev/null 2>"$LAB/err"; ACK=$(grep WAKE_ACK_REQUIRED "$LAB/err"); echo "$ACK"
THR=$(sed -n 's/.*--ack-through \([0-9]*\) --recovery-generation \([^ ]*\)$/\1/p' "$LAB/err")
GEN=$(sed -n 's/.*--ack-through \([0-9]*\) --recovery-generation \([^ ]*\)$/\2/p' "$LAB/err")
say "prune task-b before ack (fm_wake_queue_prune_task)"
bash -c '. bin/fm-wake-lib.sh; fm_wake_queue_prune_task "$1" task-b' _ "$S"; echo "exit=$?"
say "ack-through $THR"
bin/fm-wake-drain.sh --ack-through "$THR" --recovery-generation "$GEN" >/dev/null 2>&1; echo "exit=$?"
say "queue after ack (should be empty)"; wc -l < "$S/.wake-queue"
say "repeat ack (removes nothing) -> ledger row count unchanged"
before=$(wc -l < "$S/wake-ledger.tsv")
bin/fm-wake-drain.sh --ack-through "$THR" --recovery-generation "$GEN" >/dev/null 2>&1; echo "exit=$?"
after=$(wc -l < "$S/wake-ledger.tsv"); echo "ledger rows before=$before after=$after"
say "cat state/wake-ledger.tsv"; cat "$S/wake-ledger.tsv"
T_END=$(( $(date +%s) + 1 ))
say "bin/fm-wake-ledger.sh count --since $T_START --until $T_END"
bin/fm-wake-ledger.sh count --since "$T_START" --until "$T_END"
say "bin/fm-wake-ledger.sh rows --since $T_START --until $T_END"
bin/fm-wake-ledger.sh rows --since "$T_START" --until "$T_END"
say "adversarial: window entirely before activity"
bin/fm-wake-ledger.sh count --since 0 --until "$T_START"
say "adversarial: bad args"
bin/fm-wake-ledger.sh count --since 5 --until 2; echo "exit=$?"
bin/fm-wake-ledger.sh count --since x --until 2; echo "exit=$?"
bin/fm-wake-ledger.sh bogus >/dev/null 2>&1; echo "exit=$?"
rm -rf "$LAB"; echo; echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
