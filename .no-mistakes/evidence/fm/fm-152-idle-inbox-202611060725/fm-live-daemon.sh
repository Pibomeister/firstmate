#!/usr/bin/env bash
# usage: fm-live-daemon.sh <code-root> <label>
set -u
CODE=$1; LABEL=$2; WT=$PWD
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
SOCK=$("$WT/bin/fm-lab-home.sh" tmux-dir "$LAB")
GOT="$LAB/pane-received.log"; : > "$GOT"
cat > "$LAB/fakeprimary.sh" <<EOF
#!/usr/bin/env bash
while true; do printf '\342\235\257 '; IFS= read -r l || exit 0; printf '%s %s\n' "\$(date +%s)" "\$l" >> "$GOT"; done
EOF
chmod +x "$LAB/fakeprimary.sh"
"$WT/bin/fm-lab-home.sh" tmux "$LAB" new-session -d -s primary -x 200 -y 50 "$LAB/fakeprimary.sh"
printf 'away\n' > "$LAB/state/.afk"
cd "$CODE"
env -u TMUX -u TMUX_PANE -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$SOCK" FM_HOME="$LAB" FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=primary:0 \
  FM_ESCALATE_BATCH_SECS=999 FM_HEARTBEAT_SCAN_SECS=3600 \
  bash "$CODE/bin/fm-supervise-daemon.sh" > "$LAB/daemon.log" 2>&1 &
DPID=$!
sleep 8
echo "[$LABEL] daemon pid $DPID alive: $(kill -0 $DPID 2>/dev/null && echo yes || echo no)"
T0=$(date +%s)
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS FM_HOME="$LAB" bash "$CODE/bin/fm-inbox.sh" note "live captain note for #152"
echo "[$LABEL] note queued at $T0; waiting up to 60s for the pane to receive it"
for i in $(seq 1 60); do grep -q 'captain inbox note' "$GOT" 2>/dev/null && break; grep -q 'operational-inbox\|doorbell\|\[fm' "$GOT" 2>/dev/null && break; sleep 1; done; [ "$i" = 60 ] && echo "[$LABEL] NOT delivered within 60s"
T1=$(date +%s)
echo "[$LABEL] elapsed ${i}s (~$((T1-T0))s)"
echo "[$LABEL] pane received:"; cat "$GOT"
echo "[$LABEL] escalation buffer:"; cat "$LAB/state/.subsuper-escalations" 2>/dev/null || echo "(none)"
echo "[$LABEL] pane screen:"; "$WT/bin/fm-lab-home.sh" tmux "$LAB" capture-pane -p -t primary | grep -v '^$' | tail -8
echo "[$LABEL] daemon log tail:"; tail -15 "$LAB/daemon.log"
kill $DPID 2>/dev/null; sleep 2; kill -9 $DPID 2>/dev/null
pkill -f "FM_HOME=$LAB" 2>/dev/null
"$WT/bin/fm-lab-home.sh" tmux "$LAB" kill-server 2>/dev/null; "$WT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
for m in "$LAB"/state/operational-inbox/*.msg; do echo "[$LABEL] delivered record $(basename "$m"):"; grep -F "captain inbox note" "$m" || head -c 400 "$m"; done
rm -rf "$LAB"
