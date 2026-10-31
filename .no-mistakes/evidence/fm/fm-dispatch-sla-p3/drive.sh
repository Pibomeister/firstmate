#!/usr/bin/env bash
# Drives the real bin/fm-dispatch-log.sh against a disposable marked lab home.
set -u
W=/Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M69ZMH78WHJSXS8PWENA6KC4
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$W/bin/fm-lab-home.sh" create "$LAB" >/dev/null
trap 'rm -rf "$LAB"' EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_DISPATCH_SLA_MINUTES FM_DISPATCH_NOW
export FM_HOME="$LAB"
D="$W/bin/fm-dispatch-log.sh"; L="$LAB/state/dispatch-log.tsv"
T=1800000000
r(){ # label, then command
  echo "\$ $1"; shift; "$@" 2>&1 | sed "s#$LAB#<lab>#g"; echo "[exit ${PIPESTATUS[0]}]"; }
reset(){ rm -f "$L"; }
lines(){ [ -f "$L" ] && wc -l <"$L" | tr -d ' ' || echo 0; }
dl(){ FM_DISPATCH_NOW=$1; export FM_DISPATCH_NOW; shift; "$D" "$@"; local c=$?; unset FM_DISPATCH_NOW; return $c; }

echo "=== C-1 decimal SLA"
for v in 08 010 0 abc -5 1.5; do reset; dl $T received s --summary x >/dev/null
  echo "-- FM_DISPATCH_SLA_MINUTES=$v"
  for off in 480 481 600 601; do FM_DISPATCH_SLA_MINUTES=$v FM_DISPATCH_NOW=$((T+off)) "$D" overdue >/tmp/o.$$ 2>&1; echo "  +${off}s exit=$? $(head -1 /tmp/o.$$)"; done
done; rm -f /tmp/o.$$
reset; dl $T received s --summary x >/dev/null
r "SLA=08 dispatched at +481s (late mark expected at 8 min)" env FM_DISPATCH_SLA_MINUTES=08 FM_DISPATCH_NOW=$((T+481)) "$D" dispatched s --task t1
reset; dl $T received s --summary x >/dev/null
r "SLA=abc dispatched (refused, nothing written)" env FM_DISPATCH_SLA_MINUTES=abc FM_DISPATCH_NOW=$((T+481)) "$D" dispatched s --task t1
echo "ledger lines: $(lines) (want 1)"
r "SLA=abc received does not read the SLA" env FM_DISPATCH_SLA_MINUTES=abc "$D" received s2 --summary ok

echo; echo "=== C-2 blank values write nothing"
reset
for v in '' ' ' $'\t' $'\n' $' \t\r\n '; do printf -- '-- value=%q\n' "$v"
  "$D" received g --summary "$v" >/dev/null 2>&1; echo "  received exit=$? lines=$(lines)"; done
dl $T received g --summary ok >/dev/null; base=$(lines)
for v in '' ' ' $'\t\n'; do printf -- '-- value=%q\n' "$v"
  "$D" dispatched g --task "$v" >/dev/null 2>&1; echo "  dispatched exit=$? lines=$(lines)"
  "$D" queued g --reason "$v" >/dev/null 2>&1; echo "  queued exit=$? lines=$(lines)"
  "$D" blocked g --reason "$v" >/dev/null 2>&1; echo "  blocked exit=$? lines=$(lines)"; done
echo "ledger lines after refusals: $(lines) (want $base)"
echo "-- late-only values (recorded decision: task and reason refuse, summary accepts)"
"$D" dispatched g --task ' late=5m' >/dev/null 2>&1; echo "  task ' late=5m' exit=$? lines=$(lines)"
"$D" blocked g --reason ' late=5m' >/dev/null 2>&1; echo "  blocked reason ' late=5m' exit=$? lines=$(lines)"
"$D" queued g --reason ' late=5m' >/dev/null 2>&1; echo "  queued reason ' late=5m' exit=$? lines=$(lines)"
r "summary ' late=5m' accepted" dl $T received g2 --summary ' late=5m'
r "tab/newline folded in real text" dl $T received g3 --summary $'a\tb\nc'

echo; echo "=== PS-1 usage header and real overdue line"
"$D" --help | grep -n -A1 'OVERDUE <goal-id>'
reset; dl $T received p1 --summary 'with project' --project alpha >/dev/null; dl $T received p2 --summary 'no project' >/dev/null
r "overdue with and without project" dl $((T+901)) overdue

echo; echo "=== T-1 two goals at once"
reset; dl $T received open-1 --summary 'still open' >/dev/null; dl $T received done-1 --summary 'handled' >/dev/null; dl $((T+60)) dispatched done-1 --task t9 >/dev/null
r "overdue at +1000s" dl $((T+1000)) overdue

echo; echo "=== T-2 15-minute boundary"
reset; dl $T received b --summary x >/dev/null
r "at +900s" dl $((T+900)) overdue
r "at +901s" dl $((T+901)) overdue

echo; echo "=== T-3 / AN-5 show"
reset
r "bare show, no ledger file" "$D" show
r "show unknown, no ledger file" "$D" show nope
mkdir -p "$LAB/state"; : >"$L"
r "bare show, empty ledger file" "$D" show
r "show unknown, empty ledger file" "$D" show nope
dl $T received a --summary 'goal a' --project alpha >/dev/null; dl $T received b --summary 'goal b' >/dev/null; dl $((T+60)) queued a --reason busy >/dev/null; dl $((T+120)) dispatched a --task t1 >/dev/null
r "bare show" "$D" show
r "show a" "$D" show a
r "show b" "$D" show b
r "show unknown" "$D" show nope
r "show regex-looking id must not match" "$D" show 'a.*'
r "show extra arg" "$D" show a extra

echo; echo "=== AN-5 dash-leading flag values"
reset; dl $T received g --summary ok >/dev/null; base=$(lines)
for args in "received x --summary -bad" "received x --summary ok --project -bad" "dispatched g --task -bad" "dispatched g --task t --note -bad" "queued g --reason -bad" "blocked g --reason --bad"; do
  "$D" $args >/tmp/o.$$ 2>&1; echo "  $args -> exit=$? :: $(cat /tmp/o.$$)"; done; rm -f /tmp/o.$$
echo "ledger lines: $(lines) (want $base)"

echo; echo "=== M-1 FM_DISPATCH_LOG ignored"
reset; other="$LAB/other.tsv"
FM_DISPATCH_LOG="$other" "$D" received m --summary x >/dev/null; echo "exit=$? other_exists=$([ -e "$other" ] && echo yes || echo no) state_lines=$(lines)"
FM_DISPATCH_LOG="$other" "$D" show m | sed 's/^/  /'

echo; echo "=== Consumer: session start digest on the lab home (real clock)"
reset; dl $(( $(date +%s) - 1000 )) received digest-1 --summary 'old ask' --project alpha >/dev/null
env -u NO_MISTAKES_GATE "$W/bin/fm-session-start.sh" 2>&1 | grep -n -A3 'Dispatch ledger' | sed "s#$LAB#<lab>#g"; echo "[pipe ${PIPESTATUS[0]}]"
