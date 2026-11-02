# Lab helpers: disposable homes, real tmux panes on a private server.
export REPO=/Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M6BXD59WG48Z7A563RGTYE3S
export EV=/Users/eduardopicazo/.no-mistakes/evidence/01M6BXD59WG48Z7A563RGTYE3S
WD=$REPO/bin/fm-watchdog.sh
unset TMUX TMUX_PANE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE CLAUDE_CONFIG_DIR
LAB=${LAB:-$(cat /tmp/wdt/labpath 2>/dev/null)}
if [ -z "$LAB" ]; then
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); $REPO/bin/fm-lab-home.sh create "$LAB" >/dev/null; echo "$LAB" > /tmp/wdt/labpath
fi
export TMUX_TMPDIR=$($REPO/bin/fm-lab-home.sh tmux-dir "$LAB")
RULE='────────────────────────────────────────────────────────────────────────────────'
N=$(ls "$LAB/homes" 2>/dev/null | wc -l | tr -d ' ')
mk() { # name screen extra-config
  local name=$1 screen=$2 extra=${3:-}
  N=$((N+1)); H=$LAB/homes/$name; mkdir -p "$H"; $REPO/bin/fm-lab-home.sh create "$H" >/dev/null
  SID=$(printf '%08d-0000-4000-8000-%012d' "$N" "$$")
  mkdir -p "$H/state" "$H/config" "$H/data" "$H/claude/projects/p"
  printf '%s\n' "$screen" > "$H/screen.txt"; : > "$H/typed.log"
  cat > "$H/agent.sh" <<SH
#!/usr/bin/env bash
cat "$H/screen.txt"
stty -echo
exec cat >> "$H/typed.log"
SH
  chmod +x "$H/agent.sh"
  T=$(tmux new-session -d -P -F '#{pane_id}' -s "$name" -x 160 -y 40 "$H/agent.sh")
  ( sleep 100000 >/dev/null 2>&1 & echo $! > "$H/lockpid" ); LOCKPID=$(cat "$H/lockpid")
  echo "$LOCKPID" > "$H/state/.lock"; echo "$SID" > "$H/state/.lock-session"
  heartbeat
  printf 'mode=act\nclaude-config-dirs=%s\nkey-settle-secs=1\nmodels=\nnudge-secs=1\nkey-secs=1\nenter-secs=1\nfrozen-secs=5\nowed-input-secs=5\nrestart-quiet-secs=1\ndecision-secs=1\n%s\n' "$H/claude" "$extra" > "$H/config/watchdog"
  sleep 0.5
}
heartbeat() { jq -n --arg t "$T" --arg s "$SID" --argjson e "$(date +%s)" '{schema:"fm-heartbeat.v1",generated_epoch:$e,primary:{terminal:{backend:"tmux",target:$t,present:true},session:{trusted_id:$s}}}' > "$H/state/heartbeat.json"; }
transcript() { # age gap text...
  local age=$1 gap=$2 i=0 n f at iso now; shift 2; f=$H/claude/projects/p/$SID.jsonl; : > "$f"; n=$#; now=$(date +%s)
  for t in "$@"; do i=$((i+1)); at=$((now-age-(n-i)*gap)); iso=$(date -u -r "$at" +%Y-%m-%dT%H:%M:%SZ)
    jq -cn --arg ts "$iso" --arg t "$t" '{type:"assistant",timestamp:$ts,message:{content:[{type:"text",text:$t},{type:"tool_use",name:"ScheduleWakeup",input:{}}]}}' >> "$f"; done
  touch -t "$(date -r $((now-age)) +%Y%m%d%H%M.%S)" "$f"
}
owe() { printf '%s\t1\tcheck\tinbox\tcaptain note waiting\n' "$(( $(date +%s) - $1 ))" > "$H/state/.wake-queue"; }
wd() { FM_HOME=$H "$WD" "$@"; }
pass_once() { wd once 2>&1; }
led() { cut -f5-8 "$H/state/watchdog/actions.tsv" 2>/dev/null | cut -c1-150; }
calls() { cut -f2-8 "$H/state/watchdog/model-calls.tsv" 2>/dev/null; }
stat_() { sed -n '/^## Homes/,$p' "$H/data/watchdog/status.md"; }
typed() { echo "typed: [$(cat "$H/typed.log")]"; }
hdr() { printf '\n=== %s\n' "$*"; }
cfgadd() { printf '%s\n' "$@" >> "$H/config/watchdog"; }
# The real Claude TUI as the pane: disposable config, fake key, unreachable API, so no tokens.
realpane() {
  local c=$H/cc w=$H/work i; mkdir -p "$c" "$w"; local key=sk-ant-fm-watchdog-live-guard-not-a-real-key
  jq -n --arg k "${key: -20}" '{hasCompletedOnboarding:true,customApiKeyResponses:{approved:[$k],rejected:[]}}' > "$c/.claude.json"
  tmux respawn-pane -k -t "$T" -c "$w" env -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT CLAUDE_CONFIG_DIR="$c" ANTHROPIC_API_KEY="$key" ANTHROPIC_BASE_URL=http://127.0.0.1:9 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 claude
  for i in $(seq 1 40); do tmux capture-pane -p -t "$T" | grep -Eiq 'trust this folder|for shortcuts|auto mode|bypass permissions|❯' && break; sleep 1; done
  sleep 2
  if tmux capture-pane -p -t "$T" | grep -Eiq 'trust this folder'; then tmux send-keys -t "$T" Down; sleep 1; tmux send-keys -t "$T" Enter; fi
  for i in $(seq 1 30); do [ "$(bash -c '. "$1/bin/fm-backend.sh"; fm_backend_composer_state tmux "$2"' _ "$REPO" "$T" 2>/dev/null)" = empty ] && return 0; if tmux capture-pane -p -t "$T" | grep -Eq '^ *❯ 1\.'; then tmux send-keys -t "$T" Enter; fi; sleep 1; done
  echo "realpane: composer never empty"; tmux capture-pane -p -t "$T" | tail -8
}
mkr() { mk "$1" "" "${2:-}"; realpane; }
typed() { echo "pane shows doorbell: $(tmux capture-pane -p -J -S -80 -t "$T" | grep -c 'operational input waiting\|fm-op\|operational-inbox')"; }
