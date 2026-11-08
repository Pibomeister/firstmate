#!/usr/bin/env bash
set -u
R=/Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M6WS7VKDNPNA6MBWP6BTTH40
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$R/bin/fm-lab-home.sh" create "$LAB" >/dev/null
SOCK=fmlabdrv$$
REAL_TMUX=$(command -v tmux)
FB=$LAB/fakebin; mkdir -p "$FB"
printf '#!/usr/bin/env bash\nexec %s -f /dev/null -L %s "$@"\n' "$REAL_TMUX" "$SOCK" > "$FB/tmux"; chmod +x "$FB/tmux"
trap '"$REAL_TMUX" -f /dev/null -L $SOCK kill-server 2>/dev/null; kill $LOCKPID 2>/dev/null; rm -rf "$LAB"' EXIT
SID=11111111-2222-4333-8444-555555555555
mkdir -p "$LAB/claude/projects/p" "$LAB/primary/state" "$LAB/primary/config" "$LAB/primary/bin"
T=$LAB/claude/projects/p/$SID.jsonl
NOWISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{ echo '{"type":"user","message":{"content":"hi"}}'
  jq -nc --arg ts "$NOWISO" '{type:"assistant",timestamp:$ts,message:{model:"claude-test",content:[{type:"text",text:"Working."}],usage:{input_tokens:2,cache_read_input_tokens:91998,cache_creation_input_tokens:1000,output_tokens:50}}}'; } > "$T"
echo "### Scenario 1: handoff trigger publishes its compact point (pin 100000) for the session"
printf 'compact-at-tokens=100000\n' > "$LAB/config/handoff-trigger"
# The hook only runs in a genuine primary root: use a plain git checkout whose state is the lab state.
git init -q "$LAB/primary"; : > "$LAB/primary/AGENTS.md"
jq -nc --arg s "$SID" --arg t "$T" '{session_id:$s,transcript_path:$t,hook_event_name:"PostToolUse",tool_name:"Bash"}' \
 | env -u CLAUDE_AUTOCOMPACT_PCT_OVERRIDE -u FM_HOME FM_ROOT_OVERRIDE="$LAB/primary" FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config" CLAUDE_CONFIG_DIR="$LAB/claude" CLAUDE_PROJECT_DIR="$LAB/primary" bash "$R/bin/fm-handoff-trigger.sh" | jq -r '.hookSpecificOutput.additionalContext // "(no output)"' | cut -c1-200
echo "state/compact-point: $(cat "$LAB/state/compact-point")"
ls "$LAB/state" | grep -c '^compact-point\.' | sed 's/^/leftover temp files: /'
echo
echo "### Scenario 2: watchdog scan reads the published window and a real tmux pane footer"
P=$("$FB/tmux" new-session -d -P -F '#{pane_id}' -s cap -x 120 -y 30 "printf 'Captain session\n> \n  30%% until auto-compact\n'; exec cat >/dev/null")
sleep 1
( sleep 100000 >/dev/null 2>&1 & echo $! > "$LAB/lockpid" ); LOCKPID=$(cat "$LAB/lockpid")
echo "$LOCKPID" > "$LAB/state/.lock"; echo "$SID" > "$LAB/state/.lock-session"
touch -t "$(date -r $(( $(date +%s) - 60 )) +%Y%m%d%H%M.%S)" "$LAB/state/.lock" "$LAB/state/.lock-session"
jq -n --arg s "$SID" --argjson e "$(date +%s)" --argjson p "$LOCKPID" --arg t "$P" '{schema:"fm-heartbeat.v1",generated_epoch:$e,primary:{terminal:{backend:"tmux",target:$t,present:true},session:{trusted_id:$s},writer:{anchor_pid:$p,session_id:$s}}}' > "$LAB/state/heartbeat.json"
printf 'mode=dry-run\nclaude-config-dirs=%s\nmodels=\n' "$LAB/claude" > "$LAB/config/watchdog"
OUT=$(PATH="$FB:$PATH" FM_TEST_SEAM=1 FM_WD_TEST_COMPOSER=empty FM_HOME="$LAB" bash "$R/bin/fm-watchdog.sh" scan 2>&1)
printf '%s\n' "$OUT" | grep -E 'subject|ctx=' | sed "s#$LAB#<lab>#g"
echo
echo "### Scenario 3: a record naming another session falls back to the pin; no pin and no record -> footer owns"
printf 'session=other compact_at=900000 at=1\n' > "$LAB/state/compact-point"
PATH="$FB:$PATH" FM_TEST_SEAM=1 FM_WD_TEST_COMPOSER=empty FM_HOME="$LAB" bash "$R/bin/fm-watchdog.sh" scan 2>&1 | grep -o 'ctx=.*'
rm -f "$LAB/config/handoff-trigger"
PATH="$FB:$PATH" FM_TEST_SEAM=1 FM_WD_TEST_COMPOSER=empty FM_HOME="$LAB" bash "$R/bin/fm-watchdog.sh" scan 2>&1 | grep -o 'ctx=.*'
echo
echo "### Scenario 4: the scan pass writes state/monitor-status; monitor-read rewrites it (real service manager)"
echo "after scan: $(cat "$LAB/state/monitor-status" 2>&1)"
rm -f "$LAB/state/monitor-status"
FM_HOME="$LAB" bash "$R/bin/fm-watchdog.sh" monitor-read; echo "monitor-read exit=$?"
echo "after monitor-read: $(cat "$LAB/state/monitor-status")"
echo "manager-status (monitor): $(FM_HOME="$LAB" bash "$R/bin/fm-monitor-watchdog.sh" manager-status 2>&1 | head -1)"
echo "adversarial: monitor-read on a home with no state dir"
E=$(mktemp -d); FM_HOME="$E" bash "$R/bin/fm-watchdog.sh" monitor-read; echo "exit=$?"; rm -rf "$E"
