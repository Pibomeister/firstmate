. /tmp/wdt/lib.sh
# A pane that clears when it takes a key, like a real dialog.
keypane() { cat > "$H/agent.sh" <<SH
#!/usr/bin/env bash
cat "$H/screen.txt"; stty -echo -icanon min 1; while IFS= read -r -n1 k; do printf '%s' "\$k" >> "$H/typed.log"; clear; printf 'dismissed\n\n$RULE\n❯ \n$RULE\n'; done
SH
tmux respawn-pane -k -t "$T" "$H/agent.sh"; sleep 0.7; }
hdr "S6 feedback survey: key 0 clears it"
mk fb $'some work\n● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss'; keypane; transcript 100 60 "Working."; pass_once; led; typed
hdr "S7 model picker: real haiku picks a non-spending option; digit reaches the pane"
mk pick $'You have hit your weekly limit for Opus.\n\n ❯ 1. Buy more credits\n   2. Switch to Sonnet\n   3. Stop\n\nEnter to confirm · Esc to cancel' "models=claude:haiku"; keypane; transcript 100 60 "Working."; pass_once; led; calls; typed
hdr "S8 reserved picker: held, no model call, no key"
mk pickr $'You have hit your limit. Do not merge the release yet.\n\n ❯ 1. Switch to Sonnet\n   2. Stop\n\nEnter to confirm · Esc to cancel' "models=claude:haiku"; transcript 100 60 "Working."; pass_once; led; calls; stat_ | grep -i held; typed
hdr "S9 unproven question dialog: no key, gap"
mk q $'Which plan should I follow?\n ❯ 1. Plan A (Recommended)\n   2. Plan B\n\nEnter to select · ↑/↓ to navigate · Esc to cancel' "models=claude:haiku"; transcript 100 60 "Working."; pass_once; led; calls; stat_ | grep -i question; typed

EMPTY="$RULE"$'\n❯ \n'"$RULE"$'\n  ? for shortcuts'
hdr "S10 near loop, real haiku: reworded re-arms and only timer tools -> LOOP -> ladder nudge"
mkr nl "models=claude:haiku"; transcript 3000 600 "Still waiting on the timer, armed job alpha." "Timer re-armed as job beta, still waiting." "Waiting again, re-armed job gamma." "I re-armed the wake as delta and keep waiting."; owe 3000; wd scan | sed -n 4p; pass_once; led; calls; typed | cut -c1-180; stat_ | sed -n 1,2p
hdr "S10b adversarial: no model; near loop plus frozen pane still reaches frozen recovery"
mkr nl2; transcript 3000 600 "Still waiting on the timer, armed job alpha." "Timer re-armed as job beta, still waiting." "Waiting again, re-armed job gamma." "I re-armed the wake as delta and keep waiting."; owe 3000; sleep 6; pass_once; pass_once >/dev/null; sleep 6; pass_once; led; stat_ | sed -n 1,2p; typed | cut -c1-180

hdr "S11 decisions: nudge first, then real two-seat council on a benign choice; reserved ones held with no model"
mkr dec "models=claude:haiku
council-seats=claude:haiku,agy:gemini-3.8-flash-low"; transcript 100 60 "Working."
now=$(date +%s); { printf 'needs-decision [at=%s] [key=captain-hold-pricing]: pick a price tier\n' $((now-9000)); printf 'needs-decision [at=%s] [key=ship-it]: merge PR #5 now or wait?\n' $((now-9000)); printf 'needs-decision [at=%s] [key=cache-size]: A (recommended, the existing default and reversible) keep a 64 MB cache, or B use 128 MB. Both are fine and easily changed later.\n' $((now-9000)); } > "$H/state/t1.status"
pass_once; led; sleep 2; pass_once; led; calls; ls "$H/data/watchdog/rulings/" 2>/dev/null; cat "$H"/data/watchdog/rulings/* 2>/dev/null | cut -c1-160 | head -12; stat_ | grep -iE 'held|council'; typed | cut -c1-300

hdr "S12 quota floor and dead away daemon get nudges"
mkr qa; transcript 100 60 "Working."; now=$(date +%s); printf 'paused [at=%s]: hit the quota floor\n' $((now-9000)) > "$H/state/t9.status"; : > "$H/state/.afk"; pass_once; led; stat_ | sed -n 1,2p; typed | cut -c1-260; ls "$H/state/operational-inbox/" | wc -l

hdr "S13 do-not-touch: frozen + owed; nothing typed, refusal recorded"
mkr dnt "do-not-touch=dnt
restart=on
restart-secs=1
max-nudges=0"; transcript 3000 60 "Working." ; owe 3000; sleep 6; pass_once; pass_once >/dev/null; sleep 6; pass_once; led; typed; kill -0 $LOCKPID && echo holder alive

hdr "S14 stale watcher reported; stale heartbeat percent ignored"
mk st "x" "watcher-stale-secs=60"; transcript 100 60 "Working."; jq --argjson e $(( $(date +%s)-3000 )) '.generated_epoch=$e' "$H/state/heartbeat.json" > x.tmp && mv x.tmp "$H/state/heartbeat.json"; pass_once; stat_ | grep -i heartbeat

hdr "S15 recurrence files a self-heal issue through the real script; gh is a logging shim on PATH, nothing is published"
mkr sh "issue-repo=Pibomeister/agent-kit"; mkdir -p "$H/shim"; cat > "$H/shim/gh" <<SH
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >> "$H/gh.log"; case "\$*" in *"issue list"*) echo '[]';; *"issue create"*) echo https://example.invalid/issues/1;; esac; exit 0
SH
chmod +x "$H/shim/gh"; transcript 3000 60 "Working."; owe 3000
for i in 1 2 3 4; do PATH="$H/shim:$PATH" pass_once; sleep 2; done; led | grep -E 'self-heal|^unread.*pending' | cut -c1-160; cut -c1-160 "$H/gh.log" 2>/dev/null | head -6
hdr "S15b no issue-repo: recurrence becomes a gap, nothing filed"
mkr sh2; transcript 3000 60 "Working."; owe 3000; for i in 1 2 3 4; do pass_once; sleep 2; done; stat_ | grep -iE 'issue|self-heal'

hdr "S16 second mate: nudged on the parent's recorded endpoint"
mkr sm; SMT=$T; SMH=$H; SMS=$SID; transcript 3000 60 "Working."; owe 3000; rm -f "$H/state/heartbeat.json"
mk par "x"; transcript 100 60 "Working."; printf -- '- mate1 - helper (home: %s; project: x)\n' "$SMH" > "$H/data/secondmates.md"
printf 'backend=tmux\nwindow=%s\ntarget=%s\n' "$SMT" "$SMT" > "$H/state/mate1.meta"; cfgadd "claude-config-dirs=$H/claude,$SMH/claude"
wd scan | cut -c1-150; pass_once; led; stat_ | sed -n 1,4p; echo "mate $(tmux capture-pane -p -J -S -80 -t "$SMT" | grep -c 'operational input waiting')"; ls "$SMH/state/operational-inbox" 2>/dev/null | wc -l

hdr "S17 status reader contract and single instance"
H=$LAB/homes/qa; wc -l < "$H/data/watchdog/status.md"; sed -n 1,5p "$H/data/watchdog/status.md"; wd ack-read; sleep 1; pass_once; sed -n '/^## Actions/,/^## Open/p' "$H/data/watchdog/status.md" | cut -c1-120
FM_HOME=$H "$WD" run --interval 3 > "$H/run1.log" 2>&1 & R=$!; sleep 2; FM_HOME=$H "$WD" run --interval 3 ; echo "second run rc=$?"; before=$(stat -f %m "$H/data/watchdog/status.md"); sleep 7; after=$(stat -f %m "$H/data/watchdog/status.md"); echo "status advanced: $((after-before))s"; kill $R; wd manager-name; wd manager-status | head -3; wd render-systemd | sed -n 1,12p; plutil -lint "$LAB/homes/j1/unit.plist" | cut -d: -f2
