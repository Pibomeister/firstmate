#!/usr/bin/env bash
# drive2.sh <code-root> <label>: live paused agent surfaces, then dies inside the cadence
set -u
ROOT=$1; LABEL=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
SOCK=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
export TMUX_TMPDIR="$SOCK"; unset TMUX TMUX_PANE
LT() { "$ROOT/bin/fm-lab-home.sh" tmux "$LAB" "$@"; }
cleanup() { LT kill-server >/dev/null 2>&1; "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
# stand-in agent process: argv0=claude (a real sleep)
LT new-session -d -s fmlab -n fm-held "env -i PATH=/usr/bin:/bin HOME=$LAB PS1='$ ' /bin/zsh -f" || exit 1
sleep 1; LT send-keys -t fmlab:fm-held "ARGV0=claude sleep 9999" Enter; sleep 1
ST="$LAB/state"
printf 'window=fmlab:fm-held\nkind=ship\nharness=claude\nbackend=tmux\n' > "$ST/held.meta"
printf 'paused: waiting on the validation run to finish\n' > "$ST/held.status"
alive() { (cd "$ROOT" && bash -c '. bin/fm-backend.sh; fm_backend_agent_alive tmux fmlab:fm-held'); }
echo "== [$LABEL] status: $(cat "$ST/held.status")"
run_watch() {
  local out=$1 t=${2:-${WT:-20}} pid i
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_PAUSE_RESURFACE_SECS=14400 \
    "$ROOT/bin/fm-watch.sh" > "$out" 2>"$out.err" &
  pid=$!
  for i in $(seq 1 $t); do kill -0 $pid 2>/dev/null || break; sleep 1; done
  if kill -0 $pid 2>/dev/null; then kill $pid; wait $pid 2>/dev/null; echo "(watcher still running after ${t}s - no wake)"; else wait $pid; echo "(watcher exited rc=$?)"; fi
  echo "stdout: $(cat "$out")"
}
drain_ack() {
  local err="$ST/.d.err" seq gen
  FM_HOME="$LAB" "$ROOT/bin/fm-wake-drain.sh" 2>"$err" | sed 's/^/   drained: /'
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation.*/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && FM_HOME="$LAB" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}
echo "--- round 1 (agent liveness: $(alive))"; run_watch "$ST/w1.out"; drain_ack
echo "--- round 2 (agent liveness: $(alive))"; run_watch "$ST/w2.out"; drain_ack
echo "--- agent exits to a bare shell"; LT send-keys -t fmlab:fm-held C-c; sleep 1
echo "--- round 3 (agent liveness: $(alive))"; run_watch "$ST/w3.out"; drain_ack
echo "--- round 4 (agent liveness: $(alive))"; run_watch "$ST/w4.out"; drain_ack
echo "--- triage log:"; cat "$ST"/*.log "$ST"/.*log 2>/dev/null | tail -15
