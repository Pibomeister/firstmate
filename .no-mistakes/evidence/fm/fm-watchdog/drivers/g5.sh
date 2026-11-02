. /tmp/wdt/lib.sh
clearpane() { tmux send-keys -t "$T" Escape; sleep 1; tmux send-keys -t "$T" C-c; sleep 2; }
A="still waiting on the timer armed alpha"; B="still waiting on the timer armed beta"; C="still waiting on the timer armed gamma"
hdr "S10 near loop, real haiku on a real TUI pane: LOOP -> ladder nudge; no second model call in the window"
mkr nl6 "models=claude:haiku"; transcript 3000 600 "$A" "$B" "$C"; owe 3000; wd scan | sed -n 4p; pass_once; led; calls; typed; stat_ | sed -n 1,2p; clearpane; pass_once; echo "model calls now: $(calls | wc -l)"
hdr "S10b adversarial: no model; near loop + static pane reaches frozen recovery"
mkr nl7; transcript 3000 600 "$A" "$B" "$C"; owe 3000; wd scan >/dev/null; sleep 7; wd scan | sed -n 3,4p; pass_once; led; stat_ | sed -n 1,2p; stat_ | grep -i 'unconfirmed'; typed
hdr "S10c real-work near repeats: real haiku says WORK; symptoms below still run"
mkr nl8 "models=claude:haiku"; A2="Fixed one more parser failure armed alpha"; f=$H/claude/projects/p/$SID.jsonl; now=$(date +%s); transcript 3000 600 "still working on the parser armed alpha" "still working on the parser armed beta" "still working on the parser armed gamma"; python3 - "$f" <<'PY'
import json,sys
p=sys.argv[1]; L=[json.loads(x) for x in open(p)]; out=[]
for r in L:
    out.append(json.dumps(r))
    out.append(json.dumps({"type":"assistant","timestamp":r["timestamp"],"message":{"content":[{"type":"tool_use","name":"ScheduleWakeup","input":{}},{"type":"text","text":"Edited src/parser.ts, ran 212 tests, 4 failures left; refactoring the tokenizer next."}]}}))
open(p,'w').write("\n".join(out[:-1])+"\n")
PY
touch -t "$(date -r $((now-3000)) +%Y%m%d%H%M.%S)" "$f"; owe 3000; wd scan | sed -n 4p; pass_once; led; calls; stat_ | sed -n 1,2p

hdr "S11b unanimous council ruling reaches the session once the composer is empty"
mkr dec3 "models=claude:haiku
council-seats=claude:haiku,claude:haiku
decision-secs=25"; transcript 100 60 "Working."; now=$(date +%s); printf 'needs-decision [at=%s] [key=cache-size]: A (recommended, the existing default and fully reversible) keep the local test cache at 64 MB, or B use 128 MB. Both are fine.\n' $((now-9000)) > "$H/state/t1.status"
pass_once; clearpane; sleep 26; clearpane; pass_once; led | cut -c1-130; calls; cat "$H"/state/operational-inbox/*.msg | cut -c1-210

hdr "S15 recurrence files a self-heal issue through the real script; gh is a logging shim on PATH, nothing is published"
mkr sh5 "issue-repo=Pibomeister/agent-kit"; mkdir -p "$H/shim"; cat > "$H/shim/gh" <<SH
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >> "$H/gh.log"; case "\$*" in *"issue list"*) echo '[]';; *"issue create"*) echo https://example.invalid/issues/1;; esac; exit 0
SH
chmod +x "$H/shim/gh"; transcript 3000 60 "Working."; owe 3000
for i in 1 2 3 4; do PATH="$H/shim:$PATH" pass_once; sleep 2; clearpane; done; led | cut -c1-120; cut -c1-170 "$H/gh.log" 2>/dev/null | head -6
hdr "S15b no issue-repo: recurrence becomes a gap, nothing filed"
mkr sh6; transcript 3000 60 "Working."; owe 3000; for i in 1 2 3 4; do pass_once; sleep 2; clearpane; done; led | grep -c 'pending.*Watchdog'; stat_ | grep -iE 'issue|self-heal'

hdr "S16b second mate frozen: restart goes through the parent's real fm-control relaunch"
mkr sm5; SMT=$T; SMH=$H; SMS=$SID; transcript 3000 60 "Working."; owe 3000; rm -f "$H/state/heartbeat.json"
mk par5 "x" "restart=on
restart-secs=1
max-nudges=0
relaunch-timeout-secs=60"; transcript 100 60 "Working."; printf -- '- mate1 - helper (home: %s; project: x)\n' "$SMH" > "$H/data/secondmates.md"
printf 'backend=tmux\nwindow=%s\ntarget=%s\n' "$SMT" "$SMT" > "$H/state/mate1.meta"; cfgadd "claude-config-dirs=$H/claude,$SMH/claude"
wd scan >/dev/null; sleep 7; wd scan | sed -n 8p; pass_once; led | cut -c1-200; stat_ | cut -c1-170
