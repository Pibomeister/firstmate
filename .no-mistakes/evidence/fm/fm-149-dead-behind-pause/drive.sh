#!/usr/bin/env bash
# drive.sh <code-root> <label> <scenario: plain|until>
set -u
ROOT=$1; LABEL=$2; SCEN=${3:-plain}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
SOCK=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
export TMUX_TMPDIR="$SOCK"; unset TMUX TMUX_PANE
LT() { "$ROOT/bin/fm-lab-home.sh" tmux "$LAB" "$@"; }
cleanup() { LT kill-server >/dev/null 2>&1; "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
# A worker whose agent has exited: the window holds only a bare shell.
LT new-session -d -s fmlab -n fm-held "env -i PATH=/usr/bin:/bin HOME=$LAB PS1='$ ' /bin/zsh -f" || exit 1
sleep 1
LT send-keys -t fmlab:fm-held 'echo agent exited' Enter; sleep 1
ST="$LAB/state"
printf 'window=fmlab:fm-held\nkind=ship\nharness=claude\nbackend=tmux\n' > "$ST/held.meta"
if [ "$SCEN" = until ]; then
  U=$(date -u -v+2H '+%Y-%m-%dT%H:%MZ' 2>/dev/null || date -u -d '+2 hour' '+%Y-%m-%dT%H:%MZ')
  printf 'paused: waiting on the release cut until %s\n' "$U" > "$ST/held.status"
elif [ "$SCEN" = held ]; then
  printf 'captain-held [key=release]: awaiting the release call\n' > "$ST/held.status"
else
  printf 'paused: waiting on the upstream release cut\n' > "$ST/held.status"
fi
echo "== [$LABEL/$SCEN] status: $(cat "$ST/held.status")"
echo "== backend liveness: $(cd "$ROOT" && bash -c '. bin/fm-backend.sh; fm_backend_agent_alive tmux fmlab:fm-held')"
echo "== crew state: $(FM_HOME="$LAB" "$ROOT/bin/fm-crew-state.sh" held 2>&1 | head -1)"
run_watch() {
  local out=$1 t=${2:-25} pid i
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_PAUSE_RESURFACE_SECS=14400 \
    "$ROOT/bin/fm-watch.sh" > "$out" 2>"$out.err" &
  pid=$!
  for i in $(seq 1 $t); do kill -0 $pid 2>/dev/null || break; sleep 1; done
  if kill -0 $pid 2>/dev/null; then kill $pid; wait $pid 2>/dev/null; echo "(watcher still running after ${t}s - no wake)"; else wait $pid; echo "(watcher exited rc=$?)"; fi
}
drain_ack() {
  local err="$ST/.d.err" seq gen
  FM_HOME="$LAB" "$ROOT/bin/fm-wake-drain.sh" 2>"$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation.*/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && FM_HOME="$LAB" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}
for r in 1 2 3; do
  echo "--- watcher round $r"
  run_watch "$ST/w$r.out" 20
  echo "stdout: $(cat "$ST/w$r.out")"
  [ -s "$ST/w$r.out.err" ] && echo "stderr: $(tail -3 "$ST/w$r.out.err")"
  echo "drain:"; drain_ack | sed 's/^/   /'
  grep -h "stale\|pause\|dead" "$ST"/*triage* 2>/dev/null | tail -3 | sed 's/^/   triage: /'
done
echo "--- pane:"; LT capture-pane -p -t fmlab:fm-held | grep -v '^$' | tail -3
