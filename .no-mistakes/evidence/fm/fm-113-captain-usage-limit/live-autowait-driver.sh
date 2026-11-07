#!/usr/bin/env bash
# Live driver: real fm-watchdog.sh (no test seams) against a disposable lab home
# whose primary pane lives on the lab's private tmux server.
set -u
ROOT=$1; MODE=$2   # MODE: autowait | idle | afk-dead
cd "$ROOT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
SOCKDIR=$(bin/fm-lab-home.sh tmux-dir "$LAB")
T() { bin/fm-lab-home.sh tmux "$LAB" "$@"; }
SID=11111111-2222-4333-8444-555555555555
mkdir -p "$LAB/claude/projects/p"
case "$MODE" in
  idle) SCREEN=$'Captain session ready.\n\n❯ \n  ? for shortcuts' ;;
  *) SCREEN=$'● Supervising the fleet.\n\n  ⎿  5-hour limit reached ∙ resets 4am\n     Usage limit reached. Continuing automatically at 4:00 AM\n\n❯ \n  ? for shortcuts' ;;
esac
printf '%s\n' "$SCREEN" > "$LAB/screen.txt"
cat > "$LAB/agent.sh" <<A
#!/usr/bin/env bash
cat "$LAB/screen.txt"; stty -echo; exec cat >> "$LAB/typed.log"
A
chmod +x "$LAB/agent.sh"; : > "$LAB/typed.log"
T new-session -d -s primary -x 160 -y 40 "$LAB/agent.sh"
PANE=$(T list-panes -t primary -F '#{pane_id}' | head -n1)
( sleep 100000 >/dev/null 2>&1 & echo $! > "$LAB/lockpid" ); LP=$(cat "$LAB/lockpid")
echo "$LP" > "$LAB/state/.lock"; echo "$SID" > "$LAB/state/.lock-session"
NOW=$(date +%s)
jq -n --arg t "$PANE" --arg s "$SID" --argjson e "$NOW" --argjson p "$LP" \
 '{schema:"fm-heartbeat.v1",generated_epoch:$e,primary:{terminal:{backend:"tmux",target:$t,present:true},session:{trusted_id:$s},writer:{anchor_pid:$p,session_id:$s}}}' > "$LAB/state/heartbeat.json"
ts=$(date -u -r $((NOW-100)) +%Y-%m-%dT%H:%M:%SZ)
jq -cn --arg ts "$ts" '{type:"assistant",timestamp:$ts,message:{content:[{type:"text",text:"Working."}]}}' > "$LAB/claude/projects/p/$SID.jsonl"
printf 'mode=act\nclaude-config-dirs=%s\nmodels=\nissue-repo=example.invalid/owner/repo\n' "$LAB/claude" > "$LAB/config/watchdog"
printf "command:cat >> '%s'\n" "$LAB/paged.log" > "$LAB/config/wedge-alarm"
if [ "$MODE" = afk-dead ]; then
  : > "$LAB/state/.afk"; echo 999999 > "$LAB/state/.supervise-daemon.pid"
  printf 'needs-decision [at=%s] [key=cache-layout]: A or B?\n' $((NOW-9000)) > "$LAB/state/t1.status"
else
  echo "$LP" > "$LAB/state/.supervise-daemon.pid"
fi
sleep 0.5
run() { env -u FM_TEST_SEAM -u TMUX -u TMUX_PANE -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS TMUX_TMPDIR="$SOCKDIR" FM_HOME="$LAB" bash bin/fm-watchdog.sh "$@"; }
echo "=== mode=$MODE pane=$PANE (lab tmux server, real pane capture, no FM_TEST_SEAM)"
echo "--- pane as captured by the lab tmux server:"; T capture-pane -p -t "$PANE" | sed '/^$/N;/^\n$/D'
echo "--- fm-watchdog.sh scan:"; run scan 2>&1 | sed "s#$LAB#\$LAB#g"
echo "--- fm-watchdog.sh once (pass 1) exit:"; run once >/dev/null 2>&1; echo $?
echo "--- fm-watchdog.sh once (pass 2, immediately) exit:"; run once >/dev/null 2>&1; echo $?
echo "--- state/watchdog/captain:"; sed "s#$LAB#\$LAB#g" "$LAB/state/watchdog/captain"
echo "--- ledger (symptom action phase detail):"; cut -f5-8 "$LAB/state/watchdog/actions.tsv" 2>/dev/null
echo "--- paged.log (owner alert channel):"; [ -e "$LAB/paged.log" ] && sed "s#$LAB#\$LAB#g" "$LAB/paged.log" || echo "(no page)"
echo "--- data/watchdog/status.md:"; sed "s#$LAB#\$LAB#g" "$LAB/data/watchdog/status.md"
echo "--- typed.log bytes (keys typed into the primary pane): $(wc -c < "$LAB/typed.log" | tr -d ' ')"
kill -0 "$LP" 2>/dev/null && echo "--- lock holder pid alive: yes" || echo "--- lock holder pid alive: NO"
echo "--- pane still present: $(T list-panes -a -F '#{pane_id}' | grep -c "^$PANE$")"
kill "$LP" 2>/dev/null; T kill-server >/dev/null 2>&1; bin/fm-lab-home.sh teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"
echo "--- lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
