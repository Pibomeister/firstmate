. /tmp/wdt/lib.sh
keys() { echo "keys reaching pane: [$(cat "$H/typed.log")]"; }
keypane() { cat > "$H/agent.sh" <<SH
#!/usr/bin/env bash
cat "$H/screen.txt"; stty -echo -icanon min 1; while IFS= read -r -n1 k; do printf '%s' "\$k" >> "$H/typed.log"; clear; printf 'dismissed\n'; done
SH
tmux respawn-pane -k -t "$T" "$H/agent.sh"; sleep 0.7; }
clearpane() { tmux send-keys -t "$T" Escape; sleep 1; tmux send-keys -t "$T" C-u; sleep 1; }
hdr "S6 feedback survey: key 0 clears it"
mk fb2 $'some work\n● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss'; keypane; transcript 100 60 "Working."; pass_once; led; keys
hdr "S7 model picker: real haiku avoids the buy option; only that digit reaches the pane"
mk pick2 $'You have hit your weekly limit for Opus.\n\n ❯ 1. Buy more credits\n   2. Switch to Sonnet\n   3. Stop\n\nEnter to confirm · Esc to cancel' "models=claude:haiku"; keypane; transcript 100 60 "Working."; pass_once; led; calls; keys
hdr "S8 reserved picker: held, no model call, no key"
mk pickr2 $'You have hit your limit. Do not merge the release yet.\n\n ❯ 1. Switch to Sonnet\n   2. Stop\n\nEnter to confirm · Esc to cancel' "models=claude:haiku"; transcript 100 60 "Working."; pass_once; echo "ledger rows: $(led | wc -l)  model calls: $(calls | wc -l)"; stat_ | grep -i held; keys
hdr "S9 unproven question: no key, gap"
mk q2 $'Which plan should I follow?\n ❯ 1. Plan A (Recommended)\n   2. Plan B\n\nEnter to select · ↑/↓ to navigate · Esc to cancel' "models=claude:haiku"; transcript 100 60 "Working."; pass_once; echo "ledger rows: $(led | wc -l)  model calls: $(calls | wc -l)"; stat_ | grep -i question; keys

A="I re-armed the wake as job b6vfy20jj. Still waiting."; B="I re-armed the wake as job k2c9x1aa. Still waiting."; C="I re-armed the wake as job z81q0pp4. Still waiting."
hdr "S10 near loop, real haiku on a real TUI pane: LOOP -> ladder nudge; no second model call in the same window"
mkr nl3 "models=claude:haiku"; transcript 3000 600 "$A" "$B" "$C"; owe 3000; wd scan | sed -n 4p; pass_once; led; calls; typed; stat_ | sed -n 1,2p; clearpane; pass_once; echo "model calls now: $(calls | wc -l)"
hdr "S10b adversarial: no model; near loop + static pane still reaches frozen recovery"
mkr nl4; transcript 3000 600 "$A" "$B" "$C"; owe 3000; pass_once; sleep 7; wd scan | sed -n 3,4p; pass_once; led; stat_ | sed -n 1,2p; stat_ | grep -i 'possible loop\|unconfirmed'; typed
hdr "S10c near repeats with real work between them, real haiku: WORK, no timer-loop"
mkr nl5 "models=claude:haiku"; f=$H/claude/projects/p/$SID.jsonl; now=$(date +%s); for i in 1 2 3; do iso=$(date -u -r $((now-3000-(3-i)*600)) +%Y-%m-%dT%H:%M:%SZ); jq -cn --arg ts "$iso" --arg t "Fixed test $i of the parser suite, moving to the next failure." '{type:"assistant",timestamp:$ts,message:{content:[{type:"text",text:$t},{type:"tool_use",name:"Edit",input:{file_path:"src/parser.ts"}}]}}' >> "$f"; done; touch -t "$(date -r $((now-3000)) +%Y%m%d%H%M.%S)" "$f"; owe 3000; wd scan | sed -n 4p; pass_once; led; calls; stat_ | sed -n 1,2p

hdr "S11 decisions: nudge, then after the window a real two-seat council; reserved held and never sent to a model"
mkr dec2 "models=claude:haiku
council-seats=claude:haiku,claude:haiku
decision-secs=25"; transcript 100 60 "Working."
now=$(date +%s); { printf 'needs-decision [at=%s] [key=captain-hold-pricing]: pick a price tier\n' $((now-9000)); printf 'needs-decision [at=%s] [key=ship-it]: merge PR #5 now or wait?\n' $((now-9000)); printf 'needs-decision [at=%s] [key=cache-size]: A (recommended, the existing default and fully reversible) keep the local test cache at 64 MB, or B use 128 MB. Both are fine.\n' $((now-9000)); } > "$H/state/t1.status"
pass_once; led; stat_ | grep -i held; clearpane; sleep 26; clearpane; pass_once; echo "-- after window"; led; calls; ls "$H/data/watchdog/rulings/" 2>/dev/null; cat "$H"/data/watchdog/rulings/* 2>/dev/null | cut -c1-170 | head -12; stat_ | grep -iE 'held|council'; grep -c 'ship-it\|pricing' "$H/state/watchdog/model-calls.tsv"; echo "reserved keys in ledger action rows:"; cut -f5 "$H/state/watchdog/actions.tsv" | grep -cE 'ship-it|pricing'

hdr "S13 do-not-touch on real TUI: frozen + owed"
mkr dnt2 "do-not-touch=dnt2
restart=on
restart-secs=1
max-nudges=0"; transcript 3000 60 "Working."; owe 3000; pass_once; sleep 7; wd scan | sed -n 3p; pass_once; sleep 7; pass_once; led; typed; kill -0 $LOCKPID && echo holder alive

hdr "S15 recurrence files a self-heal issue through the real script; gh is a logging shim on PATH, nothing is published"
mkr sh3 "issue-repo=Pibomeister/agent-kit"; mkdir -p "$H/shim"; cat > "$H/shim/gh" <<SH
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >> "$H/gh.log"; case "\$*" in *"issue list"*) echo '[]';; *"issue create"*) echo https://example.invalid/issues/1;; esac; exit 0
SH
chmod +x "$H/shim/gh"; transcript 3000 60 "Working."; owe 3000
for i in 1 2 3; do PATH="$H/shim:$PATH" pass_once; sleep 2; clearpane; done; led | cut -c1-140; cut -c1-170 "$H/gh.log" 2>/dev/null | head -6
hdr "S15b no issue-repo: recurrence becomes a gap, nothing filed"
mkr sh4; transcript 3000 60 "Working."; owe 3000; for i in 1 2 3; do pass_once; sleep 2; clearpane; done; stat_ | grep -iE 'issue|self-heal'; led | grep -c self-heal

hdr "S16b second mate frozen: restart goes through its parent's real fm-control relaunch"
mkr sm3 "x=1"; SMT=$T; SMH=$H; SMS=$SID; transcript 3000 60 "Working."; owe 3000; rm -f "$H/state/heartbeat.json"
mk par3 "x" "restart=on
restart-secs=1
max-nudges=0
relaunch-timeout-secs=60"; transcript 100 60 "Working."; printf -- '- mate1 - helper (home: %s; project: x)\n' "$SMH" > "$H/data/secondmates.md"
printf 'backend=tmux\nwindow=%s\ntarget=%s\n' "$SMT" "$SMT" > "$H/state/mate1.meta"; cfgadd "claude-config-dirs=$H/claude,$SMH/claude"
pass_once; sleep 7; pass_once; led; stat_ | cut -c1-170; ls "$SMH/data/watchdog/handoffs" "$H/data/watchdog/handoffs" 2>/dev/null
