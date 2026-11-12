#!/usr/bin/env bash
set -u
ROOT=$1
LAB=$(mktemp -d /tmp/fbd-live/lab.XXXX)
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
TD=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
LT() { "$ROOT/bin/fm-lab-home.sh" tmux "$LAB" "$@"; }
KEYS=/tmp/fbd-live/watch.keys; : > "$KEYS"
LT new-session -d -s test -n fm-survey -x 100 -y 30 "${TUI:-/tmp/fbd-live/tui.sh} ${KIND:-survey} $KEYS"
sleep 0.8
S="$LAB/state"
printf 'window=test:fm-survey\nkind=ship\nharness=claude\nbackend=tmux\n' > "$S/survey.meta"
printf 'working: editing parser\n' > "$S/survey.status"
FB=/tmp/fbd-live/fb; mkdir -p "$FB"
printf '#!/usr/bin/env bash\necho "state: working · source: run-step · fixture"\n' > "$FB/fm-crew-state.sh"; chmod +x "$FB/fm-crew-state.sh"
echo "=== watcher cycle against live tmux pane (dialog=${KIND:-survey})"
echo "--- pane before:"; LT capture-pane -p -t test:fm-survey | sed '/^$/d'
for cycle in 1 2; do
  env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$TD" FM_HOME="$LAB" FM_STATE_OVERRIDE="$S" FM_CREW_STATE_BIN="$FB/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_WATCH_ONCE=1 FM_WATCH_NOW=$(( $(date +%s) + 30 )) \
    timeout 60 "$ROOT/bin/fm-watch.sh" > /tmp/fbd-live/watch.out.$cycle 2>/tmp/fbd-live/watch.err.$cycle
  echo "--- watcher cycle $cycle exit=$? stdout=[$(cat /tmp/fbd-live/watch.out.$cycle)]"
  echo "    marker=$(cat $S/.feedback-dismissed-test_fm-survey 2>/dev/null) claims=$(ls -a $S | grep -c feedback-claim)"; echo "    scrollback -S -40 now:"; LT capture-pane -p -t test:fm-survey -S -40 | sed "/^$/d; s/^/      /"
done
echo "--- pane after:"; LT capture-pane -p -t test:fm-survey | sed '/^$/d' | tail -6
echo "--- watcher triage log lines mentioning feedback:"; grep -rh "feedback" "$S" 2>/dev/null | grep -v '^[0-9_]*$' | head
ls -a "$S" | grep -i feedback
echo "--- bytes received by the TUI:"; cat "$KEYS"; echo "(end, $(wc -l < "$KEYS" | tr -d ' ') keystrokes)"
LT kill-server >/dev/null 2>&1; "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"
