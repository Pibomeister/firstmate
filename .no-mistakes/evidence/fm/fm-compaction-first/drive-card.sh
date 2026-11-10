#!/usr/bin/env bash
# Live CLI drive of bin/fm-sessionstart-run.sh (startup -> compact -> clear) and the
# handoff-successor notice, in a disposable lab home. One bash process named
# "claude" stands in only as the harness pid that owns the session lock.
set -u
W=/Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M71SVRQHVVKF6D5FRHPKV2CB
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); FX=$(mktemp -d); OUT=$(mktemp -d)
trap 'rm -rf "$LAB" "$FX" "$OUT"' EXIT
"$W/bin/fm-lab-home.sh" create "$LAB" >/dev/null
git init -q "$LAB"; git -C "$LAB" commit -q --allow-empty -m init; : > "$LAB/AGENTS.md"; mkdir -p "$LAB/bin"
ln -s /bin/bash "$FX/claude"
export FM_HOME="$LAB" W LAB OUT
printf 'project=/srv/projects/alpha\nspawn_gen=s%s\n' "$(date +%s)" > "$LAB/state/w1.meta"
printf 'working [at=1]: building\nneeds-decision [at=2] [key=db]: pick the database engine\n' > "$LAB/state/w1.status"
"$W/bin/fm-order.sh" send --from lab "merge the docs PR once green" >/dev/null 2>&1
FM_DISPATCH_NOW=$(($(date +%s) - 3600)) "$W/bin/fm-dispatch-log.sh" received alpha-202611091200 --summary "build the card" >/dev/null
echo "# handoff" > "$LAB/handoff.md"
"$FX/claude" -c '
  for step in startup @handoff compact clear; do
    case $step in
      @handoff) "$W/bin/fm-order.sh" handoff --doc "$LAB/handoff.md" >/dev/null 2>&1 ;;
      *) env -u NO_MISTAKES_GATE -u PI_CODING_AGENT -u GROK_AGENT CLAUDECODE=1 FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$LAB" \
           "$W/bin/fm-sessionstart-run.sh" --source $step </dev/null > "$OUT/$step.out" 2>&1 ;;
    esac
  done' 
echo "=== startup: first lines / lock"; grep -m2 -E "lock acquired|FIRSTMATE" "$OUT/startup.out"; echo "startup bytes: $(wc -c < "$OUT/startup.out")"
echo; echo "=== compact (auto-compaction re-entry card), bytes: $(wc -c < "$OUT/compact.out")"; cat "$OUT/compact.out"
echo; echo "=== .order-handoff after compact: $( [ -e "$LAB/state/.order-handoff" ] && echo present || echo cleared)"
echo; echo "=== clear: bytes $(wc -c < "$OUT/clear.out"); head:"; head -3 "$OUT/clear.out"; grep -c "COMPACT RE-ENTRY CARD" "$OUT/clear.out"
echo; echo "=== H2: successor opens while predecessor holds the lock"
"$FX/claude" -c "sleep 30; :" & PRED=$!; cp "$LAB/state/.lock" "$OUT/lock.bak" 2>/dev/null; printf '%s\n' "$PRED" > "$LAB/state/.lock"
env -u NO_MISTAKES_GATE CLAUDECODE=1 FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$LAB" FM_HANDOFF_PREDECESSOR_PID=$PRED "$W/bin/fm-sessionstart-run.sh" --source startup </dev/null > "$OUT/succ.out" 2>&1; echo "exit=$?"
echo "bytes: $(wc -c < "$OUT/succ.out")"; cat "$OUT/succ.out"; echo "lock still predecessor: $( [ "$(cat "$LAB/state/.lock")" = "$PRED" ] && echo yes || echo NO)"
kill $PRED; wait $PRED 2>/dev/null
echo; echo "=== H2b: predecessor ended -> successor gets full digest and takes lock"
"$FX/claude" -c 'env -u NO_MISTAKES_GATE CLAUDECODE=1 FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$LAB" FM_HANDOFF_PREDECESSOR_PID='"$PRED"' "$W/bin/fm-sessionstart-run.sh" --source startup </dev/null' > "$OUT/succ2.out" 2>&1
grep -m3 -E "lock acquired|FIRSTMATE SESSION|handoff successor" "$OUT/succ2.out"
