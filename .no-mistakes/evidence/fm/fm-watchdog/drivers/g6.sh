. /tmp/wdt/lib.sh
clearpane() { tmux send-keys -t "$T" Escape; sleep 1; tmux send-keys -t "$T" C-c; sleep 2; }
settle() { for i in 1 2 3 4 5 6 7 8; do s=$(wd scan | awk -v sub_="$1" '$1=="subject"&&$2==sub_{f=1;next} $1=="subject"{f=0} f&&/pane_static/{print $1}'); s=${s#pane_static=}; s=${s%s}; echo "  scan $i static=${s}s"; [ "${s:-0}" -ge 6 ] && return 0; sleep 4; done; return 1; }
A="still waiting on the timer armed alpha"; B="still waiting on the timer armed beta"; C="still waiting on the timer armed gamma"
hdr "S10b adversarial: no model; near loop + static pane reaches frozen recovery"
mkr nl9; transcript 3000 600 "$A" "$B" "$C"; owe 3000; settle nl9; pass_once; led; stat_ | sed -n 1,2p; stat_ | grep -i 'unconfirmed'; typed
hdr "S10c near repeats showing real progress, real haiku"
mkr nl10 "models=claude:haiku"; transcript 3000 600 "Waiting for the CI run now: build job passed" "Waiting for the CI run now: test job passed, lint running" "Waiting for the CI run now: every job passed, opening the PR and picking up the next ticket"; owe 3000; settle nl10; pass_once; led; calls; stat_ | sed -n 1,2p; typed
hdr "S15 recurrence files a self-heal issue through the real script; gh is a logging shim on PATH, nothing is published"
mkr sh7 "issue-repo=Pibomeister/agent-kit"; mkdir -p "$H/shim"; cat > "$H/shim/gh" <<SH
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >> "$H/gh.log"; case "\$*" in *"issue list"*) ;; *"issue create"*) echo https://example.invalid/issues/1;; esac; exit 0
SH
chmod +x "$H/shim/gh"; transcript 3000 60 "Working."; owe 3000
for i in 1 2 3 4; do PATH="$H/shim:$PATH" pass_once; sleep 2; clearpane; done; led | cut -c1-120; grep 'issue' "$H/gh.log" | cut -c1-170
hdr "S15b no issue-repo: recurrence becomes a gap, nothing filed"
mkr sh8; transcript 3000 60 "Working."; owe 3000; for i in 1 2 3 4; do pass_once; echo "-- pass $i: $(led | grep -c 'nudge.pending') nudges; gaps: $(stat_ | grep -iE 'issue|self-heal' | cut -c1-120)"; sleep 2; clearpane; done; led | grep -c self-heal
hdr "S16b second mate frozen: restart goes through the parent's real fm-control relaunch"
mkr sm6; SMT=$T; SMH=$H; SMS=$SID; transcript 3000 60 "Working."; owe 3000; rm -f "$H/state/heartbeat.json"
mk par6 "x" "restart=on
restart-secs=1
max-nudges=0
relaunch-timeout-secs=60"; transcript 100 60 "Working."; printf -- '- mate1 - helper (home: %s; project: x)\n' "$SMH" > "$H/data/secondmates.md"
printf 'backend=tmux\nwindow=%s\ntarget=%s\n' "$SMT" "$SMT" > "$H/state/mate1.meta"; cfgadd "claude-config-dirs=$H/claude,$SMH/claude"
settle sm6; pass_once; led | cut -c1-200; stat_ | cut -c1-170; wd scan | sed -n 8p
