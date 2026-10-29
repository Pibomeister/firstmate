#!/usr/bin/env bash
# Live driver: real fm-pr-check-watch.sh + real fm-procevent runner + real GitHub (PR 47).
set -u
BIN=$1; LABEL=$2; ROOT=$(cd "$BIN/.." && pwd)
H=$(mktemp -d /tmp/fmcw-home.XXXXXX)
export FM_HOME=$H FM_STATE_OVERRIDE=$H/state FM_PROCEVENT_CLAIM_ROOT=$H/claims FM_PR_CHECK_WATCH_INTERVAL=1
mkdir -p "$FM_STATE_OVERRIDE"
PR=https://github.com/Pibomeister/firstmate/pull/47
meta() { printf 'kind=ship\nmode=direct-PR\npr=%s\n' "$PR" > "$FM_STATE_OVERRIDE/$1.meta"; chmod 600 "$FM_STATE_OVERRIDE/$1.meta"; }
W="$BIN/fm-pr-check-watch.sh"
ref_of() { sed -n 's/^watch_ref=//p'; }
result_of() { ls "$FM_STATE_OVERRIDE/procevent-inbox/$1".*.result 2>/dev/null | head -1; }
wait_result() { for _ in $(seq 1 ${2:-40}); do r=$(result_of "$1"); [ -n "$r" ] && { echo "$r"; return; }; sleep 0.5; done; }
echo "===== [$LABEL] bin=$BIN home=$H ====="

echo "--- S1 green check on real PR head fires ---"
meta t-green
out=$("$W" arm t-green "$PR" "Repo invariants" --producer-app 15368); echo "$out"; g=$(echo "$out" | ref_of)
"$ROOT/bin/fm-procevent.sh" reconcile >/dev/null
r=$(wait_result "$g"); echo "result=$r class=$("$ROOT/bin/fm-procevent-when.sh" classify "$r" 2>&1)"
"$W" status "$g" | grep -E '^state='

echo "--- S2 record deleted while watch polls a missing check ---"
meta t-del
out=$("$W" arm t-del "$PR" "No such check" --producer-app 15368); d=$(echo "$out" | ref_of); echo "watch_ref=$d"
"$ROOT/bin/fm-procevent.sh" reconcile >/dev/null; sleep 4
echo "before delete: $("$W" status "$d" | grep '^state=')"
rm -f "$FM_STATE_OVERRIDE/pr-check-watch/$d.json"; t0=$(date +%s)
r=$(wait_result "$d" 30)
if [ -n "$r" ]; then echo "after delete: terminal after $(( $(date +%s)-t0 ))s class=$("$ROOT/bin/fm-procevent-when.sh" classify "$r" 2>&1)"; grep -ho 'watch record[^"]*\|state=absent[^"]*' "$r" | head -2
else echo "after delete: NO terminal result after 15s; source still registered: $([ -f "$FM_STATE_OVERRIDE/procevent/$d.source" ] && echo yes || echo no)"; fi

echo "--- S3 record tampered while watch polls ---"
meta t-tamp
out=$("$W" arm t-tamp "$PR" "No such check" --producer-app 15368); tp=$(echo "$out" | ref_of); echo "watch_ref=$tp"
"$ROOT/bin/fm-procevent.sh" reconcile >/dev/null; sleep 4
f=$FM_STATE_OVERRIDE/pr-check-watch/$tp.json; jq '.check="Repo invariants"' "$f" > "$f.new"; chmod 600 "$f.new"; mv "$f.new" "$f"; t0=$(date +%s)
r=$(wait_result "$tp" 30)
if [ -n "$r" ]; then echo "after tamper: terminal after $(( $(date +%s)-t0 ))s class=$("$ROOT/bin/fm-procevent-when.sh" classify "$r" 2>&1)"; grep -ho 'watch record changed' "$r" | head -1
else echo "after tamper: NO terminal result after 15s"; fi

echo "--- S4 retire with absent record retires the registered source ---"
meta t-orph
out=$("$W" arm t-orph "$PR" "No such check" --producer-app 15368); o=$(echo "$out" | ref_of); echo "watch_ref=$o"
"$ROOT/bin/fm-procevent.sh" reconcile >/dev/null; sleep 2
rm -f "$FM_STATE_OVERRIDE/pr-check-watch/$o.json"
"$W" retire "$o"; echo "retire rc=$?"
echo "source registered after retire: $([ -e "$FM_STATE_OVERRIDE/procevent/$o.source" ] && echo YES-orphaned || echo no)"

echo "--- S5 rearm through a script path containing a space ---"
seq=${r:-}; gr=$(result_of "$g"); s=${gr%.result}; s=${s##*.}
"$ROOT/bin/fm-procevent.sh" handled "$g" "$s" >/dev/null && echo "handled $g seq=$s"
ln -s "$BIN" "$H/bin dir"
out=$("$H/bin dir/fm-pr-check-watch.sh" rearm "$g" 2>&1); echo "rearm rc=$?"; echo "$out"
n=$(echo "$out" | ref_of); [ -n "$n" ] && echo "new generation differs: $([ "$n" != "$g" ] && echo yes)" && "$W" status "$n" | grep '^state='

echo "--- cleanup ---"
for f in "$FM_STATE_OVERRIDE"/pr-check-watch/*.json; do [ -f "$f" ] || continue; x=${f##*/}; "$W" retire "${x%.json}" >/dev/null 2>&1; done
for f in "$FM_STATE_OVERRIDE"/procevent/when-*.source; do [ -f "$f" ] || continue; x=${f##*/}; x=${x%.source}; "$ROOT/bin/fm-procevent-when.sh" retire "${x#when-}" >/dev/null 2>&1; done
pkill -f "$H" 2>/dev/null; sleep 1; echo "leftover procs: $(pgrep -f "$H" | wc -l | tr -d ' ')"; rm -rf "$H"
