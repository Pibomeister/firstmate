#!/usr/bin/env bash
# Drives the real bin/fm-dispatch-log.sh against disposable homes. Prints a transcript.
S="$PWD/bin/fm-dispatch-log.sh"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DISPATCH_SLA_MINUTES FM_DISPATCH_NOW FM_DISPATCH_LOG
new() { H=$(mktemp -d "${TMPDIR:-/tmp}/fm-dl.XXXXXX"); export FM_HOME="$H"; L="$H/state/dispatch-log.tsv"; HOMES+=("$H"); }
run() { echo "\$ $*"; "$@" 2>&1 | sed 's/^/  /'; echo "  [exit ${PIPESTATUS[0]}]"; }
fl() { [ -f "$L" ] && wc -l <"$L" | tr -d ' ' || echo absent; }
d() { "$S" "$@"; }
T0=1800000000

echo "=== C-1 decimal SLA"; new
FM_DISPATCH_NOW=$T0 d received a --summary s >/dev/null
for pair in "08 480 0" "08 481 3" "010 600 0" "010 601 3" "010 481 0" "15x 1 1" "-5 1 1"; do set -- $pair
  echo "\$ FM_DISPATCH_SLA_MINUTES=$1 NOW=T0+$2 overdue (want exit $3)"
  FM_DISPATCH_SLA_MINUTES=$1 FM_DISPATCH_NOW=$((T0+$2)) "$S" overdue 2>&1 | sed 's/^/  /'; echo "  [exit ${PIPESTATUS[0]}]"
done
echo "\$ FM_DISPATCH_SLA_MINUTES=08 dispatched at T0+481 (late mark must use 8m SLA)"
FM_DISPATCH_SLA_MINUTES=08 FM_DISPATCH_NOW=$((T0+481)) "$S" dispatched a --task t1 2>&1 | sed 's/^/  /'; echo "  [exit ${PIPESTATUS[0]}]"

echo; echo "=== C-2 blank text writes nothing"; new
run d received g --summary '   '; echo "  ledger=$(fl)"
run d received g --summary $'\t\n '; echo "  ledger=$(fl)"
FM_DISPATCH_NOW=$T0 d received g --summary real >/dev/null; echo "  seeded ledger=$(fl)"
run d dispatched g --task $' \t'; echo "  ledger=$(fl)"
run d queued g --reason $'\n\n'; echo "  ledger=$(fl)"
run d blocked g --reason '  '; echo "  ledger=$(fl)"
echo "-- recorded decision: late-mark-only refused for task/reason, not summary"
run d dispatched g --task ' late=5m'; echo "  ledger=$(fl)"
run d blocked g --reason ' late=5m'; echo "  ledger=$(fl)"
run d received h --summary ' late=5m'; echo "  ledger=$(fl)"
run d received i --summary $'two\tword\nsummary'; tail -1 "$L" | sed 's/^/  tail: /'

echo; echo "=== PS-1 overdue line with and without project; usage header"; new
FM_DISPATCH_NOW=$T0 d received p1 --summary 'with proj' --project alpha >/dev/null
FM_DISPATCH_NOW=$T0 d received p2 --summary 'no proj' >/dev/null
FM_DISPATCH_NOW=$((T0+1000)) run d overdue
run bash -c "'$S' --help | grep -A1 'OVERDUE <goal-id>'"

echo; echo "=== T-1 two goals at once"; new
FM_DISPATCH_NOW=$T0 d received open1 --summary o >/dev/null
FM_DISPATCH_NOW=$T0 d received done1 --summary d >/dev/null
FM_DISPATCH_NOW=$((T0+60)) d dispatched done1 --task t >/dev/null
FM_DISPATCH_NOW=$((T0+1000)) run d overdue

echo; echo "=== T-2 15-minute boundary"; new
FM_DISPATCH_NOW=$T0 d received b --summary b >/dev/null
FM_DISPATCH_NOW=$((T0+900)) run d overdue
FM_DISPATCH_NOW=$((T0+901)) run d overdue

echo; echo "=== T-3 bare show"; new
run d show
FM_DISPATCH_NOW=$T0 d received s1 --summary one >/dev/null
FM_DISPATCH_NOW=$((T0+5)) d dispatched s1 --task t1 >/dev/null
run d show; echo "  ledger bytes match: $(d show | cmp - "$L" && echo yes)"

echo; echo "=== M-1 FM_DISPATCH_LOG ignored; state dir selects path"; new
STRAY="$H/stray.tsv"
FM_DISPATCH_LOG="$STRAY" FM_DISPATCH_NOW=$T0 d received m --summary x >/dev/null
echo "  stray exists: $([ -e "$STRAY" ] && echo yes || echo no); state ledger=$(fl)"
ALT="$H/alt"; FM_STATE_OVERRIDE="$ALT" FM_DISPATCH_NOW=$T0 "$S" received m2 --summary y >/dev/null
echo "  FM_STATE_OVERRIDE ledger: $(wc -l <"$ALT/dispatch-log.tsv" | tr -d ' ')"

echo; echo "=== AN-5 show by id, unknown id, dash flag"; new
run d show ghost
run d show
FM_DISPATCH_NOW=$T0 d received an --summary 'sum' --project pj >/dev/null
FM_DISPATCH_NOW=$T0 d received other --summary 'noise' >/dev/null
FM_DISPATCH_NOW=$((T0+30)) d dispatched an --task tk --note 'nn' >/dev/null
run d show an
run d show ghost
for args in "received z --summary -x" "received z --summary s --project -p" "dispatched an --task -t" "dispatched an --task t --note -n" "queued an --reason -r" "blocked an --reason --foo"; do
  run d $args; echo "  ledger=$(fl)"
done

echo; echo "=== Regression: real clock, no test overrides"; new
run d received live-1 --summary 'real clock'
sleep 2
FM_DISPATCH_SLA_MINUTES=0 run d overdue
FM_DISPATCH_SLA_MINUTES=0 run d dispatched live-1 --task tk
run d overdue
run d received live-1 --summary dup
run d nope
run bash -c "'$S' received 'bad id' --summary s"
rm -rf "${HOMES[@]}"
