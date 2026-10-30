#!/usr/bin/env bash
# Drives the real bin/fm-dispatch-log.sh against a disposable marked lab home.
cd "$1"; DL=bin/fm-dispatch-log.sh
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null
export FM_HOME="$LAB"; unset FM_STATE_OVERRIDE FM_ROOT_OVERRIDE
L="$LAB/state/dispatch-log.tsv"; T0=1800000000
d(){ n=$1; shift; echo "\$ [T0+$(( (n-T0)/60 ))m] fm-dispatch-log.sh $*"; FM_DISPATCH_NOW=$n bash $DL "$@"; echo "  -> exit $?"; }
m(){ echo $((T0+$1*60)); }
echo "### 1 on-time dispatch: no late mark, quiet overdue"
d $T0 received ontime-202701150800 --summary 'ship video' --project shipcontent
d $(m 10) overdue
d $(m 14) dispatched ontime-202701150800 --task t1 --note 'first pass'
d $(m 500) overdue
echo "### 2 SLA boundary: exactly 15m is on time, 15m+1s is not"
d $T0 received edge --summary e
d $((T0+900)) overdue
d $((T0+901)) overdue
d $((T0+900)) dispatched edge --task t
echo "### 3 late dispatch persists late=<m>m (AN-1)"
d $T0 received late1 --summary 'late one'
d $(m 16) overdue
d $(m 16) dispatched late1 --task t2
d $(m 17) overdue
d $(m 17) show late1
echo "### 4 late blocked persists; LATE window runs 24h from final line, even at 25h"
d $T0 received late2 --summary 'blocked late'
d $(m 20) blocked late2 --reason 'no quota'
d $T0 received weekend --summary 'weekend ask'
d $(m 1500) dispatched weekend --task t3
d $(m 1501) overdue
d $(m 2939) overdue
d $(m 2941) overdue
d $(m 2941) show weekend
echo "### 5 ids, duplicates, refusals write nothing (AN-2)"
b=$(wc -l < "$L")
d $T0 received 'bad id' --summary x
d $T0 received 'bad/id' --summary x
d $T0 received late1 --summary dup
d $T0 received nosum
d $T0 received nosum2 --summary
d $T0 received nosum3 --summary ''
d $T0 dispatched ghost --task t
d $T0 queued ghost --reason r
d $T0 blocked ghost --reason r
d $T0 dispatched late1
d $T0 blocked late1
d $T0 queued late1
d $T0 frobnicate x
echo "lines before=$b after=$(wc -l < "$L")"
echo "### 6 queued is not final, does not reset clock; blocked stops it (AN-3)"
d $T0 received q1 --summary 'waits'
d $(m 5) queued q1 --reason 'capacity full'
d $(m 10) overdue
d $(m 16) overdue
d $(m 16) queued q1 --reason 'still full'
d $(m 17) overdue
d $(m 18) dispatched q1 --task t4
d $(m 18) show q1
d $T0 received q2 --summary 'blocker'
d $(m 5) blocked q2 --reason 'no quota'
d $(m 500) overdue
echo "### 7 re-queue after final goes overdue from queued line; no second late mark (recorded decision)"
d $(m 600) queued q2 --reason 'quota back, capacity full'
d $(m 610) overdue
d $(m 616) overdue
d $(m 617) dispatched q2 --task t5
d $(m 618) show q2
echo "### 8 secondmate hand-off: parent records dispatched, mate has own ledger (AN-3)"
LAB2=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB2" >/dev/null
d $T0 received sm1 --summary 'routed'
d $(m 2) dispatched sm1 --task secondmate:mate-a
FM_HOME="$LAB2" d $(m 2) received sm1 --summary 'routed from parent'
FM_HOME="$LAB2" d $(m 20) overdue
FM_HOME="$LAB2" d $(m 21) dispatched sm1 --task t-in-mate
d $(m 21) show sm1
FM_HOME="$LAB2" d $(m 21) show sm1
echo "### 9 adversarial: callers cannot forge or suppress the late mark; TSV injection"
d $T0 received forge --summary 'x late=99m'
d $(m 1) dispatched forge --task t --note 'looks late=99m'
d $(m 2) overdue
d $T0 received forge2 --summary y
d $(m 30) dispatched forge2 --task t --note 'done late=1m late=2m'
d $T0 received inj --summary $'a\tb\nc'
d $(m 1) blocked inj --reason $'r\tdispatched\tinj\nz'
d $(m 1) show inj
echo "fields per line: $(awk -F'\t' '{print NF}' "$L" | sort -u | tr '\n' ' ')"
echo "### 10 real clock, no time override, SLA env override"
unset FM_DISPATCH_NOW
FM_DISPATCH_SLA_MINUTES=0 bash $DL received realclock --summary 'real clock'; sleep 2
FM_DISPATCH_SLA_MINUTES=0 bash $DL overdue | grep realclock; echo "  -> pipe statuses ${PIPESTATUS[*]}"
FM_DISPATCH_SLA_MINUTES=0 bash $DL dispatched realclock --task t
FM_DISPATCH_SLA_MINUTES=abc bash $DL overdue; echo "  -> bad SLA exit $?"
bash $DL overdue --minutes 5; echo "  -> removed flag exit $?"
echo "### 11 empty home"
LAB3=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB3" >/dev/null
FM_HOME="$LAB3" bash $DL overdue; echo "  -> exit $?"; FM_HOME="$LAB3" bash $DL show; echo "  -> exit $?"; ls "$LAB3/state"
rm -rf "$LAB" "$LAB2" "$LAB3"
