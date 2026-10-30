#!/usr/bin/env bash
# Drives the real bin/fm-dispatch-log.sh against a disposable FM_HOME.
unset FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_DISPATCH_SLA_MINUTES FM_DISPATCH_LOG FM_DISPATCH_NOW
S=$PWD/bin/fm-dispatch-log.sh
H=$(mktemp -d "${TMPDIR:-/tmp}/fm-dl.XXXXXX"); export FM_HOME=$H
L=$H/state/dispatch-log.tsv
r() { echo "\$ $*"; env "${E[@]}" bash "$S" "$@"; echo "[exit $?] ledger_lines=$( [ -f "$L" ] && wc -l <"$L" | tr -d ' ' || echo 0)"; }
E=(A=1)
T0=1800000000
echo "=== C-1 SLA decimal"
E=(FM_DISPATCH_NOW=$T0); r received c1 --summary "octal"
for sla in 08 010 09 ; do for off in 480 481 600 601 540 541; do E=(FM_DISPATCH_NOW=$((T0+off)) FM_DISPATCH_SLA_MINUTES=$sla); r overdue; done; done
E=(FM_DISPATCH_SLA_MINUTES=abc FM_DISPATCH_NOW=$T0); r overdue
E=(FM_DISPATCH_SLA_MINUTES=-5 FM_DISPATCH_NOW=$T0); r overdue
E=(FM_DISPATCH_SLA_MINUTES=99999999999999999999 FM_DISPATCH_NOW=$T0); r overdue
E=(FM_DISPATCH_NOW=$((T0+481)) FM_DISPATCH_SLA_MINUTES=08); r dispatched c1 --task t1
E=(FM_DISPATCH_NOW=$T0)
echo "=== C-2 whitespace"
r received w1 --summary " "
r received w1 --summary $'\t\n '
r received w1 --summary " late=5m"
r received w1 --summary ""
r received w2 --summary "real"
r dispatched w2 --task " "
r queued w2 --reason " "
r blocked w2 --reason $'\n'
r blocked w2 --reason " late=3m"
echo "=== AN-5 flag-looking values"
r received f1 --summary --project p
r received f1 --summary -x
r received f1 --summary ok --project --task
r dispatched w2 --task --note x
r dispatched w2 --task t --note --reason
r blocked w2 --reason --task
r received f1 --summary
r received f1 --bogus x
echo "=== AN-5 show"
r show nope
r show w2
E=(FM_DISPATCH_NOW=$((T0+10))); r dispatched w2 --task task-9 --note hi
r show w2
r show
r show 'a.*'
r show w
echo "=== exit 4 duplicate"
r received w2 --summary again
echo "=== M-1 FM_DISPATCH_LOG ignored"
E=(FM_DISPATCH_NOW=$T0 FM_DISPATCH_LOG=$H/split.tsv); r received m1 --summary x
ls $H/split.tsv 2>&1; r show m1
echo "=== PS-1 project form + header"
E=(FM_DISPATCH_NOW=$T0); r received p1 --summary "with proj" --project acme
E=(FM_DISPATCH_NOW=$((T0+901))); r overdue
bash "$S" --help | sed -n '/`overdue` prints/,/late marks stay/p'
echo "=== T-1 two goals, independent"
H2=$(mktemp -d "${TMPDIR:-/tmp}/fm-dl.XXXXXX"); export FM_HOME=$H2; L=$H2/state/dispatch-log.tsv
E=(FM_DISPATCH_NOW=$T0); r received a --summary a; r received b --summary b; r received c --summary c
E=(FM_DISPATCH_NOW=$((T0+60))); r dispatched b --task tb
E=(FM_DISPATCH_NOW=$((T0+1000))); r overdue
E=(FM_DISPATCH_NOW=$((T0+1000))); r dispatched c --task tc
E=(FM_DISPATCH_NOW=$((T0+1000))); r overdue
echo "=== T-2 boundary"
H3=$(mktemp -d "${TMPDIR:-/tmp}/fm-dl.XXXXXX"); export FM_HOME=$H3; L=$H3/state/dispatch-log.tsv
E=(FM_DISPATCH_NOW=$T0); r overdue; r show; r received z --summary z
E=(FM_DISPATCH_NOW=$((T0+900))); r overdue
E=(FM_DISPATCH_NOW=$((T0+901))); r overdue
echo "=== real clock"
E=(A=1); r received live --summary "wall clock"; r overdue; r show live
rm -rf "$H" "$H2" "$H3"
