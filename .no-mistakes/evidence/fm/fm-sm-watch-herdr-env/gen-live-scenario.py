import sys
src = open(sys.argv[1]).read()
src = src.replace('. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"', '. "$FM_W/tests/lib.sh"')
src = src.replace('ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"', 'ROOT=$FM_W\nMODE=${MODE:-takeover}')
src = src.replace('rc=0; . "$FM_HOME/bin/fm-push-transition-lib.sh" && fm_secondmate_watch_start',
                  '[ "${FM_T_DROP_SESSION:-}" = 1 ] && unset HERDR_SESSION\nrc=0; . "$FM_HOME/bin/fm-push-transition-lib.sh" && fm_secondmate_watch_start')
src = src.replace('"FM_TASK_INBOX=$L/parent/state/sm-lab-1.inbox"',
                  '"FM_TASK_INBOX=$L/parent/state/sm-lab-1.inbox" "FM_T_DROP_SESSION=${FM_T_DROP_SESSION:-}"')
head, _ = src.split('sm_call fm_secondmate_watch_binding_valid >/dev/null 2>&1 && fail "a missing binding file validated"', 1)
tail = r'''
# Real leftover: the same detached --grok-hold the Codex Stop hook's --detach-hold starts.
env -u TMUX -u TMUX_PANE "${ENVS[@]}" FM_WATCH_HANDLING_SUCCESSOR=1 FM_WATCH_GROK_HOLD=1 \
  nohup "$L/home/bin/fm-watch.sh" --grok-hold >"$L/grok.log" 2>&1 </dev/null &
i=0; while [ ! -s "$L/home/state/.watch.lock/pid" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
GROK=$(cat "$L/home/state/.watch.lock/pid" 2>/dev/null)
[ -n "$GROK" ] || fail "the real --grok-hold leftover never took the watch lock: $(cat "$L/grok.log")"
touch "$L/home/state/.last-watcher-beat"
echo "leftover watcher pid $GROK: $(ps -ww -o args= -p "$GROK")"
rc=0; env -u TMUX -u TMUX_PANE "${ENVS[@]}" HERDR_SESSION="$HERDR_SESSION" HERDR_PANE_ID="$HERDR_PANE_ID" \
  "$L/home/bin/fm-watch.sh" --secondmate-selected || rc=$?
echo "--secondmate-selected (pane env, healthy leftover --grok-hold) rc=$rc"
[ "$rc" = 0 ] || fail "a leftover --grok-hold deselected this Herdr secondmate"
rc=0; env -u TMUX -u TMUX_PANE "${ENVS[@]}" HERDR_PANE_ID="$HERDR_PANE_ID" "$L/home/bin/fm-watch.sh" --secondmate-selected || rc=$?
echo "--secondmate-selected (pane env without HERDR_SESSION) rc=$rc"
[ "$rc" = 0 ] || fail "a Herdr pane without HERDR_SESSION was not selected"
: > "$L/start"
i=0; while [ ! -s "$L/start.rc" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
echo "production start rc=$(cat "$L/start.rc" 2>/dev/null) output: $(cat "$L/start.out" 2>/dev/null)"
if [ "$MODE" = takeover ]; then
  [ "$(cat "$L/start.rc" 2>/dev/null)" = 0 ] || fail "production start failed behind the leftover"
  sleep 1
  kill -0 "$GROK" 2>/dev/null && fail "the leftover --grok-hold is still running"
  echo "leftover pid $GROK: gone"
  NEW=$(cat "$L/home/state/.watch.lock/pid")
  echo "new watcher pid $NEW: $(ps -ww -o args= -p "$NEW")"
  ps -ww -o args= -p "$NEW" | grep -q -- '--secondmate-hold' || fail "the new owner is not the secondmate hold"
  echo "binding: $(tr '\n' ' ' < "$L/home/state/.secondmate-watch")"
  sm_call fm_secondmate_watch_status >/dev/null 2>&1 || fail "the secondmate watcher is not healthy after takeover"
  echo "--secondmate-status: healthy"
  sm_call fm_secondmate_watch_notify >/dev/null 2>&1 || fail "notification failed"
  i=0
  until "$LAB_HELPER" run "$LAB_SESSION" pane read "$PANE" --source recent --lines 40 2>/dev/null | grep -Fq "sm-lab-1.inbox" || [ "$i" -ge 20 ]; do sleep 0.5; i=$((i+1)); done
  [ "$i" -lt 20 ] || fail "doorbell never reached the pane"
  echo "pane shows doorbell: $("$LAB_HELPER" run "$LAB_SESSION" pane read "$PANE" --source recent --lines 40 2>/dev/null | grep -F "sm-lab-1.inbox" | tail -1)"
  pass "$HERDR_VERSION: real leftover --grok-hold taken over by --secondmate-hold in a real Herdr pane; doorbell rang"
else
  [ "$(cat "$L/start.rc" 2>/dev/null)" != 0 ] || fail "start without HERDR_SESSION in a named session succeeded"
  kill -0 "$GROK" 2>/dev/null || fail "a failed proof stopped the leftover watcher"
  echo "leftover pid $GROK still alive: $(ps -ww -o args= -p "$GROK")"
  kill "$GROK" 2>/dev/null
  pass "$HERDR_VERSION: pane in a named session without HERDR_SESSION fails the proof and leaves the leftover watcher running"
fi
'''
open(sys.argv[2], 'w').write(head + tail)
