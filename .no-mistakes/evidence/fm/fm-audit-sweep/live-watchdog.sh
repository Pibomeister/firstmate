#!/usr/bin/env bash
set -eu
ROOT=$PWD
LABROOT=$ROOT/.test-phase-tmp/watchdog-live
mkdir -p "$LABROOT/bin"
REAL_TMUX=$(command -v tmux)
SOCKET=fm-lab-watchdog-$$
NORMAL_PATH=$PATH
cleanup() { "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true; }
trap cleanup EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX TMUX_PANE HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH ORCA_TERMINAL_HANDLE
BASE=$(date +%s)
export LIVE_TMUX=$REAL_TMUX LIVE_SOCKET=$SOCKET
cat > "$LABROOT/bin/tmux" <<'EOF'
#!/usr/bin/env bash
if [ "${FM_INJECT_TRANSPORT_FAULT:-}" = swallow ] && [ "$1" = send-keys ] && [ "${*: -1}" = Enter ]; then exit 0; fi
if [ "${FM_INJECT_TRANSPORT_FAULT:-}" = send-failed ] && [ "$1" = send-keys ]; then
  for a in "$@"; do [ "$a" != -l ] || exit 1; done
fi
exec "$LIVE_TMUX" -f /dev/null -L "$LIVE_SOCKET" "$@"
EOF
chmod +x "$LABROOT/bin/tmux"
for fault in swallow send-failed; do
  H=$LABROOT/$fault
  mkdir -p "$H/state" "$H/data" "$H/config" "$H/transcripts/projects/p"
  cat > "$H/composer.sh" <<'EOF'
#!/usr/bin/env bash
printf 'Synthetic composer transport input\n────────────────────────────────────────\n❯ \n────────────────────────────────────────\n  ? for shortcuts\033[2A\033[3G'
exec cat > /dev/null
EOF
  chmod +x "$H/composer.sh"
  "$REAL_TMUX" -L "$SOCKET" -f /dev/null new-session -d -s "$fault" -x 600 -y 40 "$H/composer.sh"
  T=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$fault" '#{pane_id}')
  P=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$T" '#{pane_pid}')
  SID=00000000-0000-4000-8000-000000000001
  echo "$P" > "$H/state/.lock"
  echo "$SID" > "$H/state/.lock-session"
  jq -n --arg t "$T" --arg s "$SID" --argjson p "$P" --argjson e "$BASE" '{schema:"fm-heartbeat.v1",generated_epoch:$e,primary:{terminal:{backend:"tmux",target:$t,present:true},session:{trusted_id:$s},writer:{anchor_pid:$p,session_id:$s}}}' > "$H/state/heartbeat.json"
  printf 'mode=act\nclaude-config-dirs=%s\nmodels=\nquota-guard=off\nmemory-guard=off\nheartbeat-frozen-secs=600\nkey-settle-secs=1\nrestart=on\nrestart-command=/usr/bin/true\n' "$H/transcripts" > "$H/config/watchdog"
  printf '{"type":"assistant","timestamp":"2026-11-20T00:00:00Z","message":{"content":[{"type":"text","text":"Synthetic idle transcript input."}]}}\n' > "$H/transcripts/projects/p/$SID.jsonl"
  python3 - "$H/transcripts/projects/p/$SID.jsonl" "$((BASE-3000))" "$H/state/.lock" "$H/state/.lock-session" "$BASE" <<'PY'
import os,sys
os.utime(sys.argv[1],(int(sys.argv[2]),int(sys.argv[2])))
for p in sys.argv[3:5]:os.utime(p,(int(sys.argv[5])-1,int(sys.argv[5])-1))
PY
  sleep 0.5
  export PATH=$LABROOT/bin:$NORMAL_PATH FM_HOME=$H FM_TEST_SEAM=1
  printf '\nCASE: real watchdog with synthetic terminal, transport fault=%s\n' "$fault"
  FM_WD_NOW=$BASE bash bin/fm-watchdog.sh once
  FM_INJECT_TRANSPORT_FAULT=$fault FM_WD_NOW=$((BASE+700)) bash bin/fm-watchdog.sh once
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$T" | head -6
  if [ "$fault" = swallow ]; then
    "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$T" | sed -n '4p' | grep -Fx '────────────────────────────────────────'
  fi
  FM_WD_NOW=$((BASE+1000)) bash bin/fm-watchdog.sh once
  cat "$H/state/watchdog/actions.tsv"
  awk -F '\t' '$5=="heartbeat-frozen" && $6=="nudge" && $7=="pending" {pending++} $5=="heartbeat-frozen" && $6=="nudge" && $7=="done" {done++} $5=="heartbeat-frozen" && $6=="restart" && $7=="pending" {restart++} END {exit !(pending==1 && done==0 && restart==0)}' "$H/state/watchdog/actions.tsv"
  printf 'RESULT: failed or unsubmitted transport created no delivery receipt and authorized no restart.\n'
done
