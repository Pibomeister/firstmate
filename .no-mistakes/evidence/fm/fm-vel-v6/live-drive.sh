#!/usr/bin/env bash
# Disposable live drive of bin/fm-watchdog.sh stall pages.
# Real clock, private tmux socket, disposable home. Not the operator fleet.
set -u
ROOT="{run-worktree}"
EVID="~/.no-mistakes/evidence/01M7R2ZFJFRPP8E2BZJBJRS14F"
LIVE="$EVID/tmp/live-stall"
WD="$ROOT/bin/fm-watchdog.sh"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-stall-live-$$"
FAKE="$LIVE/fakebin"
LOG="$EVID/live-drive.log"
: > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }

fail() { say "FAIL: $*"; echo FAIL >> "$EVID/live-drive.result"; exit 1; }

cleanup() {
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  if [ -n "${LOCKPID:-}" ]; then kill "$LOCKPID" 2>/dev/null || true; fi
}
trap cleanup EXIT

mkdir -p "$FAKE" "$LIVE"
cat > "$FAKE/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -f /dev/null -L "$SOCKET" "\$@"
SH
chmod +x "$FAKE/tmux"
export PATH="$FAKE:$PATH"
unset TMUX NO_MISTAKES_GATE FM_HOME FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_ROOT_OVERRIDE FM_TEST_SEAM FM_WD_NOW FM_WD_TEST_COMPOSER FM_GATE_REFUSE_BYPASS

H="$LIVE/home"
rm -rf "$H"
mkdir -p "$H/state/inbox" "$H/config" "$H/data" "$H/claude/projects/p"
printf '%s\n' $'Captain session\n> ' > "$H/screen.txt"
cat > "$H/agent.sh" <<SH
#!/usr/bin/env bash
cat "$H/screen.txt"
stty -echo
: > "$H/agent.ready"
exec cat >> "$H/typed.log"
SH
chmod +x "$H/agent.sh"
: > "$H/typed.log"
"$REAL_TMUX" -f /dev/null -L "$SOCKET" new-session -d -s primary -x 160 -y 40 "$H/agent.sh"
T=$("$REAL_TMUX" -f /dev/null -L "$SOCKET" list-panes -t primary -F '#{pane_id}' | head -n 1)
[ -n "$T" ] || fail "no pane"
( sleep 600 >/dev/null 2>&1 & printf '%s\n' "$!" > "$H/lockpid" )
LOCKPID=$(cat "$H/lockpid")
printf '%s\n' "$LOCKPID" > "$H/state/.lock"
SID="00000000-0000-4000-8000-0000000000aa"
printf '%s\n' "$SID" > "$H/state/.lock-session"
NOW=$(date +%s)
jq -n --arg t "$T" --arg s "$SID" --argjson e "$NOW" --argjson p "$LOCKPID" \
  '{schema:"fm-heartbeat.v1", generated_epoch:$e, published_epoch:$e, stale_after_secs:900, primary:{terminal:{backend:"tmux",target:$t,present:true},session:{trusted_id:$s},writer:{anchor_pid:$p,session_id:$s}}}' \
  > "$H/state/heartbeat.json"
printf 'mode=act\nclaude-config-dirs=%s\nkey-settle-secs=1\nmodels=\nquota-guard=off\nmemory-guard=off\nheartbeat-frozen-secs=0\n' "$H/claude" > "$H/config/watchdog"
printf "command:cat >> '%s'\n" "$H/paged.log" > "$H/config/wedge-alarm"
drawn=0
while [ ! -e "$H/agent.ready" ]; do
  drawn=$((drawn + 1))
  [ "$drawn" -le 50 ] || fail "pane never started"
  sleep 0.1
done

# Fresh transcript so the home is not frozen (activity younger than frozen-secs).
iso=$(date -u -r $((NOW - 30)) +%Y-%m-%dT%H:%M:%SZ)
jq -cn --arg ts "$iso" '{type:"assistant",timestamp:$ts,message:{content:[{type:"text",text:"Working."},{type:"tool_use",name:"ScheduleWakeup",input:{}}]}}' \
  > "$H/claude/projects/p/$SID.jsonl"

ship() { # id yolo status-line
  printf 'kind=ship\nbackend=tmux\nwindow=%%9\nterminal=term_%s\nyolo=%s\nendpoint_task_id=%s\n' "$1" "$2" "$1" > "$H/state/$1.meta"
  printf '%s\n' "$3" > "$H/state/$1.status"
}

reset_case() {
  rm -f "$H/state/"*.meta "$H/state/"*.status "$H/state/.wake-queue" "$H/paged.log" "$H/state/inbox/"*.note
  rm -rf "$H/state/watchdog" "$H/data/watchdog"
  : > "$H/typed.log"
  cp "$H/state/.lock" "$H/lock.before"
  cp "$H/state/.lock-session" "$H/lock-session.before"
  # Refresh the beacon so this pass still has a live holder and a fresh heartbeat.
  NOW=$(date +%s)
  jq -n --arg t "$T" --arg s "$SID" --argjson e "$NOW" --argjson p "$LOCKPID" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e, published_epoch:$e, stale_after_secs:900, primary:{terminal:{backend:"tmux",target:$t,present:true},session:{trusted_id:$s},writer:{anchor_pid:$p,session_id:$s}}}' \
    > "$H/state/heartbeat.json"
}

run_once() {
  local rc=0
  env -u TMUX FM_HOME="$H" bash "$WD" once >>"$LOG" 2>&1 || rc=$?
  say "once-exit:$rc"
  return 0
}

pages() { # symptom phase
  awk -F'\t' -v s="$1" -v p="$2" '$5==s && $6=="page" && $7==p' "$H/state/watchdog/actions.tsv" 2>/dev/null | wc -l | tr -d ' '
}

stall_rows() {
  awk -F'\t' '$5 ~ /^stall-/' "$H/state/watchdog/actions.tsv" 2>/dev/null | wc -l | tr -d ' '
}

assert_lock() {
  cmp -s "$H/state/.lock" "$H/lock.before" || fail "$1: session lock changed"
  cmp -s "$H/state/.lock-session" "$H/lock-session.before" || fail "$1: lock session changed"
  kill -0 "$LOCKPID" 2>/dev/null || fail "$1: lock holder died"
  if awk -F'\t' '$6=="restart"' "$H/state/watchdog/actions.tsv" 2>/dev/null | grep -q .; then
    fail "$1: restart recorded"
  fi
  return 0
}

say "pane=$T lock=$LOCKPID home=$H"

# 1. A failed ship is not work in flight, so old input does not page.
reset_case
ship fm-f off "failed [at=$((NOW - 2000))]: the build broke"
printf '%s\t1\tcheck\tinbox\tcaptain note waiting\n' "$((NOW - 1000))" > "$H/state/.wake-queue"
run_once
[ "$(stall_rows)" = 0 ] || fail "failed-only home paged: $(cat "$H/state/watchdog/actions.tsv")"
[ ! -e "$H/paged.log" ] || fail "failed-only home wrote a page: $(cat "$H/paged.log")"
assert_lock "failed-only"
say "PASS failed-task-not-in-flight"

# 2. An old inbox note, with a ship still working, pages once and omits the note text.
reset_case
ship fm-a off "working [at=$((NOW - 100))]: implementing"
mkdir -p "$H/state/inbox"
printf '%s\n' 'please handle sk-live-stall-secret and the captain note body' > "$H/state/inbox/old.note"
python3 - "$H/state/inbox/old.note" "$((NOW - 1000))" <<'PY'
import os, sys
p, ago = sys.argv[1], int(sys.argv[2])
os.utime(p, (ago, ago))
PY
run_once
[ "$(pages stall-input done)" = 1 ] || fail "inbox note did not page: $(cat "$H/state/watchdog/actions.tsv" 2>/dev/null)"
grep -F '1 unhandled inputs' "$H/paged.log" >/dev/null || fail "page missing the input count: $(cat "$H/paged.log")"
grep -F 'while 1 tasks are in flight' "$H/paged.log" >/dev/null || fail "page missing in-flight count: $(cat "$H/paged.log")"
grep -F 'sk-live-stall-secret' "$H/paged.log" && fail "page leaked the note text"
grep -F 'stalled:' "$H/data/watchdog/status.md" >/dev/null || fail "status missing the stall gap"
assert_lock "inbox-note"
cp "$H/paged.log" "$EVID/live-inbox-page.txt"
cp "$H/data/watchdog/status.md" "$EVID/live-inbox-status.md"
say "PASS inbox-note-pages-without-note-text"
# Immediate second pass stays inside the default one-hour window.
run_once
[ "$(pages stall-input pending)" = 1 ] || fail "second pass paged again inside the window: $(awk -F'\t' '$5=="stall-input"' "$H/state/watchdog/actions.tsv")"
say "PASS inbox-note-rate-limited"

# 3. A running turn (esc to interrupt) and a fresh heartbeat do not hide the page, and nothing is typed.
reset_case
printf '%s\n' $'Working on the task\nesc to interrupt\n> ' > "$H/screen.txt"
"$REAL_TMUX" -f /dev/null -L "$SOCKET" respawn-pane -k -t primary "$H/agent.sh"
sleep 0.4
ship fm-a off "working [at=$((NOW - 80))]: implementing"
printf '%s\t1\tcheck\tinbox\tcaptain note waiting\n' "$((NOW - 1000))" > "$H/state/.wake-queue"
run_once
[ "$(pages stall-input done)" = 1 ] || fail "running turn hid the stall: $(cat "$H/state/watchdog/actions.tsv" 2>/dev/null)"
[ ! -s "$H/typed.log" ] || fail "watchdog typed into a running turn: $(cat "$H/typed.log")"
assert_lock "running-turn"
cp "$H/paged.log" "$EVID/live-running-turn-page.txt"
say "PASS running-turn-does-not-hide-stall"
say "ALL-LIVE-DRIVE-PASS"
echo PASS > "$EVID/live-drive.result"
