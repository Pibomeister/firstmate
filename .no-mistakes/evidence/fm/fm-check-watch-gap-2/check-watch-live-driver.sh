#!/usr/bin/env bash
# Live driver: real fm-pr-check-watch.sh + real fm-procevent.sh runner against a fixture forge.
set -u
ROOT=$1; LAB=$2; FIX=$LAB/forge
export FM_HOME=$LAB FM_PROCEVENT_CLAIM_ROOT=$LAB/claims FM_PR_CHECK_WATCH_INTERVAL=0.5
export PATH="$FIX/bin:$PATH" FIX
STATE=$LAB/state; W=$ROOT/bin/fm-pr-check-watch.sh; PE=$ROOT/bin/fm-procevent.sh
mkdir -p "$FIX/bin"
cat > "$FIX/bin/gh-axi" <<'SH'
#!/usr/bin/env bash
a="$*"; printf '%s\n' "$a" >> "$FIX/gh.log"
case "$a" in
  *'/repos/acme/widget/pulls/'*) n=${a#*/pulls/}; n=${n%% *}; body=$(printf '{"head":{"sha":"%s"}}' "$(cat "$FIX/head-$n")") ;;
  *'/commits/'*'/check-runs'*) s=${a#*/commits/}; s=${s%%/*}; body=$(cat "$FIX/checks-$s.json") ;;
  *) exit 1 ;;
esac
[ "${4:-}" = --jq ] && printf '%s\n' "$body" | jq -r "$5"
SH
chmod +x "$FIX/bin/gh-axi"
say() { printf '\n### %s\n' "$*"; }
sha() { printf '%040d' "$1" | tr 0 a | sed "s/^a/$1/" | cut -c1-40; }
setup() { # <n> <checks-json>
  local n=$1 h; h=$(printf '%s' "$n" | sed 's/./&/'); h=$(printf "%039d%s" 0 "$n" | tail -c 40)
  printf '%s\n' "$h" > "$FIX/head-$n"; printf '%s\n' "$2" > "$FIX/checks-$h.json"
  printf 'kind=ship\nmode=direct-PR\npr=https://github.com/acme/widget/pull/%s\n' "$n" > "$STATE/t$n.meta"; chmod 600 "$STATE/t$n.meta"
}
checks() { printf '%s\n' "$2" > "$FIX/checks-$(cat "$FIX/head-$1").json"; }
arm() { "$W" arm "t$1" "https://github.com/acme/widget/pull/$1" Build --producer-app 42; }
results() { ls "$STATE/procevent-inbox/$1".*.result 2>/dev/null; }
wait_result() { local i; for i in $(seq 1 ${2:-60}); do "$PE" reconcile >/dev/null 2>&1; [ -n "$(results "$1")" ] && return 0; sleep 0.5; done; return 1; }
show() { local r; for r in $(results "$1"); do echo "result=$r class=$("$ROOT/bin/fm-procevent-when.sh" classify "$r")"; sed 's/^/  | /' "$r" | head -12; done; }
G='"status":"completed","conclusion":"success"'; P='"status":"in_progress","conclusion":null'; F='"status":"completed","conclusion":"failure"'
run() { printf '{"id":%s,"name":"Build",%s,"app":{"id":%s},"check_suite":{"id":%s}}' "$1" "$2" "$3" "$4"; }
js() { local IFS=,; printf '{"total_count":%s,"check_runs":[%s]}' "$#" "$*"; }

say "S1 green check -> one fired result, ack -> ended, reconciles do not refire"
setup 1 "$(js "$(run 11 "$G" 42 1)")"
out=$(arm 1); echo "$out"; ref=$(sed -n 's/^watch_ref=//p' <<<"$out")
wait_result "$ref" && show "$ref" || echo "NO RESULT"
sleep 1; echo "source file present after terminal: $([ -f "$STATE/procevent/$ref.source" ] && echo yes || echo no)"
"$W" status "$ref"
seq=$(results "$ref" | head -1); seq=${seq%.result}; seq=${seq##*.}
"$PE" handled "$ref" "$seq"; "$W" status "$ref" | head -1
for i in 1 2; do echo "reconcile $i: $("$PE" reconcile 2>&1)"; sleep 1; done
echo "result count=$(results "$ref" | wc -l | tr -d ' ')"

say "S2 rerun: failed attempt + pending rerun in same suite waits, then fires when rerun is green"
setup 2 "$(js "$(run 22 "$P" 42 2)" "$(run 21 "$F" 42 2)")"
out=$(arm 2); ref=$(sed -n 's/^watch_ref=//p' <<<"$out"); echo "watch_ref=$ref"
for i in $(seq 1 8); do "$PE" reconcile >/dev/null 2>&1; sleep 0.5; done
echo "after ~4s pending rerun: results=$(results "$ref" | wc -l | tr -d ' ') status=$("$W" status "$ref" | head -1)"
checks 2 "$(js "$(run 22 "$G" 42 2)" "$(run 21 "$F" 42 2)")"
wait_result "$ref" && show "$ref" || echo "NO RESULT"

say "S3a adversarial: same check+App in two suites -> ambiguous, not green"
setup 3 "$(js "$(run 31 "$G" 42 3)" "$(run 32 "$G" 42 4)")"
out=$(arm 3); ref=$(sed -n 's/^watch_ref=//p' <<<"$out"); wait_result "$ref" && show "$ref" || echo "NO RESULT"

say "S3b adversarial: green run only from another App -> producer-mismatch, not green"
setup 4 "$(js "$(run 41 "$G" 99 5)")"
out=$(arm 4); ref=$(sed -n 's/^watch_ref=//p' <<<"$out"); wait_result "$ref" && show "$ref" || echo "NO RESULT"

say "S3c adversarial: bound App newest attempt failed, competing App green -> failed, not green"
setup 5 "$(js "$(run 52 "$F" 42 6)" "$(run 51 "$G" 42 6)" "$(run 53 "$G" 99 7)")"
out=$(arm 5); ref=$(sed -n 's/^watch_ref=//p' <<<"$out"); wait_result "$ref" && show "$ref" || echo "NO RESULT"

say "S4 adversarial: PR head moves while pending -> head-moved condition-error"
setup 6 "$(js "$(run 61 "$P" 42 8)")"
out=$(arm 6); ref=$(sed -n 's/^watch_ref=//p' <<<"$out")
for i in 1 2 3; do "$PE" reconcile >/dev/null 2>&1; sleep 0.5; done
echo "pending before move: results=$(results "$ref" | wc -l | tr -d ' ')"
printf '%s\n' ffffffffffffffffffffffffffffffffffffffff > "$FIX/head-6"
wait_result "$ref" && show "$ref" || echo "NO RESULT"

say "S5 forge read error -> immediate condition-error (fail-fast, as decided)"
setup 7 "$(js "$(run 71 "$P" 42 9)")"
out=$(arm 7); ref=$(sed -n 's/^watch_ref=//p' <<<"$out")
printf '{malformed\n' > "$FIX/checks-$(cat "$FIX/head-7").json"
wait_result "$ref" && show "$ref" || echo "NO RESULT"
echo; echo "DRIVER-DONE"
