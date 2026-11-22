#!/bin/bash
# Drive bin/fm-watchdog.sh once against disposable homes. Synthetic records,
# real watchdog, real private tmux pane, real alert command.
set -u
ROOT={run-worktree}
EVID=~/.no-mistakes/evidence/01M7R2ZFJFRPP8E2BZJBJRS14F
WD=$ROOT/bin/fm-watchdog.sh
ORIG_PATH=$PATH
REAL_TMUX=$(command -v tmux) || { echo 'tmux missing' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo 'jq missing' >&2; exit 1; }
SOCKET=fm-stall-live-$$
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-stall-live.XXXXXX") || exit 1
FAKEBIN=$LAB/fakebin
mkdir -p "$FAKEBIN"
LOCK_PIDS=''
N=0
FAILS=0
BAD=0
NOTE_BUF=''
: > "$EVID/scenario-results.tsv"
: > "$EVID/stall-live-transcript.txt"

cat > "$FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -f /dev/null -L "$SOCKET" "\$@"
SH
chmod +x "$FAKEBIN/tmux"
for tool in gh gh-axi osascript terminal-notifier say mail sendmail curl; do
  cat > "$FAKEBIN/$tool" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$tool" "\$*" >> "$LAB/external-calls.log"
exit 1
SH
  chmod +x "$FAKEBIN/$tool"
done
: > "$LAB/external-calls.log"

cleanup() {
  local p
  for p in $LOCK_PIDS; do kill "$p" 2>/dev/null || true; done
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT

BASE=$(date +%s)

touch_epoch() {
  local epoch=$1 stamp
  shift
  stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S) || return 1
  touch -t "$stamp" "$@"
}

ok() { NOTE_BUF="${NOTE_BUF}ok: $1
"; }
bad() { BAD=1; NOTE_BUF="${NOTE_BUF}FAIL: $1
"; }
expect_eq() {
  if [ "$1" = "$2" ]; then ok "$3=$1"; else bad "$3 expected [$2] got [$1]"; fi
}

rows() { # symptom phase
  local f=$H/state/watchdog/actions.tsv
  [ -f "$f" ] || { printf '0\n'; return; }
  awk -F'\t' -v s="$1" -v p="$2" '$5 == s && $6 == "page" && $7 == p' "$f" | wc -l | tr -d ' '
}
stall_any() {
  local f=$H/state/watchdog/actions.tsv
  [ -f "$f" ] || { printf '0\n'; return; }
  awk -F'\t' '$5 ~ /^stall-/' "$f" | wc -l | tr -d ' '
}
restarts() {
  local f=$H/state/watchdog/actions.tsv
  [ -f "$f" ] || { printf '0\n'; return; }
  awk -F'\t' '$6 == "restart"' "$f" | wc -l | tr -d ' '
}

expect_quiet_stall() {
  expect_eq "$(stall_any)" 0 "stall-rows"
  if [ -e "$H/paged.log" ]; then bad "paged.log exists: $(cat "$H/paged.log")"; else ok "no page delivered"; fi
}
expect_no_restart() {
  expect_eq "$(restarts)" 0 "restart-rows"
  if cmp -s "$H/state/.lock" "$H/lock.before"; then ok "lock unchanged"; else bad "session lock changed"; fi
  if cmp -s "$H/state/.lock-session" "$H/lock-session.before"; then ok "lock session unchanged"; else bad "lock session changed"; fi
}

make_home() {
  local extra=${1-} sess drawn=0
  N=$((N + 1))
  H=$LAB/home$N
  SID=$(printf '00000000-0000-4000-8000-%012d' "$N")
  mkdir -p "$H/state/inbox" "$H/config" "$H/data" "$H/claude/projects/p"
  printf 'Captain session\n> \n' > "$H/screen.txt"
  cat > "$H/agent.sh" <<SH
#!/usr/bin/env bash
cat "$H/screen.txt"
stty -echo
: > "$H/agent.ready"
exec cat >> "$H/typed.log"
SH
  chmod +x "$H/agent.sh"
  : > "$H/typed.log"
  sess=stall$N
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" new-session -d -s "$sess" -x 160 -y 40 "$H/agent.sh"
  T=$("$REAL_TMUX" -f /dev/null -L "$SOCKET" list-panes -t "$sess" -F '#{pane_id}' | head -n 1)
  ( sleep 100000 >/dev/null 2>&1 & printf '%s\n' "$!" > "$H/lockpid" )
  LOCKPID=$(cat "$H/lockpid")
  LOCK_PIDS="$LOCK_PIDS $LOCKPID"
  printf '%s\n' "$LOCKPID" > "$H/state/.lock"
  printf '%s\n' "$SID" > "$H/state/.lock-session"
  touch_epoch $((BASE - 1)) "$H/state/.lock" "$H/state/.lock-session"
  jq -n --arg t "$T" --arg s "$SID" --argjson e "$BASE" --argjson p "$LOCKPID" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:"tmux",target:$t,present:true},session:{trusted_id:$s},writer:{anchor_pid:$p,session_id:$s}}}' \
    > "$H/state/heartbeat.json"
  printf 'mode=act\nclaude-config-dirs=%s\nkey-settle-secs=1\nmodels=\nquota-guard=off\nmemory-guard=off\nheartbeat-frozen-secs=0\ncall-timeout-secs=3\n%s\n' \
    "$H/claude" "$extra" > "$H/config/watchdog"
  if [ "${ALARM:-command}" = off ]; then
    printf 'off\n' > "$H/config/wedge-alarm"
  else
    printf "command:cat >> '%s'\n" "$H/paged.log" > "$H/config/wedge-alarm"
  fi
  local at=$((BASE - 30)) iso f
  f=$H/claude/projects/p/$SID.jsonl
  iso=$(date -u -r "$at" +%Y-%m-%dT%H:%M:%SZ)
  jq -cn --arg ts "$iso" --arg t "Working." \
    '{type:"assistant",timestamp:$ts,message:{content:[{type:"text",text:$t},{type:"tool_use",name:"ScheduleWakeup",input:{}}]}}' > "$f"
  touch_epoch "$at" "$f"
  while [ ! -e "$H/agent.ready" ]; do
    drawn=$((drawn + 1))
    [ "$drawn" -le 50 ] || { echo "pane never started for $H" >&2; return 1; }
    sleep 0.1
  done
  cp "$H/state/.lock" "$H/lock.before"
  cp "$H/state/.lock-session" "$H/lock-session.before"
}

add_task() { # id yolo status-line [kind]
  local id=$1 yolo=$2 line=$3 kind=${4:-ship}
  printf 'kind=%s\nbackend=tmux\nwindow=%%9%s\nterminal=term_%s\nyolo=%s\nendpoint_task_id=%s\n' \
    "$kind" "$N" "$id" "$yolo" "$id" > "$H/state/$id.meta"
  printf '%s\n' "$line" > "$H/state/$id.status"
}

wake_line() { # epoch key text
  printf '%s\t1\tcheck\t%s\t%s\n' "$1" "$2" "$3" > "$H/state/.wake-queue"
}

add_note() { # epoch body
  printf '%s\n' "$2" > "$H/state/inbox/captain.note"
  touch_epoch "$1" "$H/state/inbox/captain.note"
}

add_marker() { # id version provider host path number
  printf '%s\n%s\n%s\n%s\n%s\n' "$2" "$3" "$4" "$5" "$6" > "$H/state/$1.pr-poll-merge-notified"
  chmod 600 "$H/state/$1.pr-poll-merge-notified"
}

run_once() { # offset [seam|none]
  local off=$1 seam=${2:-empty} rc
  if [ "$seam" = none ]; then
    env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS \
      -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
      -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_HOME \
      -u FM_WD_TEST_COMPOSER \
      FM_TEST_SEAM=1 FM_WD_NOW=$((BASE + off)) FM_HOME="$H" PATH="$FAKEBIN:$ORIG_PATH" \
      bash "$WD" once >"$H/once.$off.out" 2>"$H/once.$off.err"
  else
    env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS \
      -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
      -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_HOME \
      FM_TEST_SEAM=1 FM_WD_TEST_COMPOSER="$seam" FM_WD_NOW=$((BASE + off)) FM_HOME="$H" \
      PATH="$FAKEBIN:$ORIG_PATH" \
      bash "$WD" once >"$H/once.$off.out" 2>"$H/once.$off.err"
  fi
  rc=$?
  printf '%s\n' "$rc" > "$H/once.$off.rc"
  expect_eq "$rc" 0 "watchdog-once-exit@$off"
}

finish() { # name artifact
  local name=$1 tag=$2
  {
    printf '== %s ==\n' "$name"
    printf '%s' "$NOTE_BUF"
    printf -- '--- page ---\n'
    if [ -f "$H/paged.log" ]; then cat "$H/paged.log"; else printf '(no page delivered)\n'; fi
    printf -- '--- stall ledger rows ---\n'
    if [ -f "$H/state/watchdog/actions.tsv" ]; then
      awk -F'\t' 'BEGIN { OFS="\t" } $5 ~ /^stall-/ { print $1, $5, $6, $7, $8 }' "$H/state/watchdog/actions.tsv"
    else
      printf '(no ledger)\n'
    fi
    printf -- '--- status lines ---\n'
    if [ -f "$H/data/watchdog/status.md" ]; then
      grep -n -E 'stall|unhandled|ready PR|not paged' "$H/data/watchdog/status.md" || printf '(no stall lines)\n'
    else
      printf '(no status)\n'
    fi
    printf -- '--- typed into captain pane ---\n'
    if [ -s "$H/typed.log" ]; then cat "$H/typed.log"; else printf '(nothing typed)\n'; fi
  } > "$EVID/$tag.txt"
  {
    printf '\n======== %s ========\n' "$name"
    cat "$EVID/$tag.txt"
  } >> "$EVID/stall-live-transcript.txt"
  if [ "$BAD" = 0 ]; then
    printf 'PASS\t%s\t%s\n' "$name" "$tag" | tee -a "$EVID/scenario-results.tsv"
  else
    printf 'FAIL\t%s\t%s\n' "$name" "$tag" | tee -a "$EVID/scenario-results.tsv"
    FAILS=$((FAILS + 1))
  fi
  BAD=0
  NOTE_BUF=''
}

SECRET='please-merge-the-secret-note-do-not-relay'
GH_URL=https://github.com/o/r/pull/7
FJ_URL=https://git.example.com/o/r/pulls/9

# 1. Unhandled input with work in flight pages once per window.
ALARM=command
make_home
add_task fm-a off "working [at=$((BASE - 100))]: implementing"
wake_line $((BASE - 1000)) inbox "captain note waiting"
run_once 0
expect_eq "$(rows stall-input pending)" 1 "stall-input pending"
expect_eq "$(rows stall-input done)" 1 "stall-input delivered"
if [ -f "$H/paged.log" ] && grep -F -q '1 unhandled inputs, the oldest 16 minutes old, while 1 tasks are in flight' "$H/paged.log"; then
  ok "page names the count and age"
else
  bad "page text missing the 16-minute in-flight line"
fi
if [ -f "$H/paged.log" ] && grep -F -q 'restarted nothing' "$H/paged.log"; then
  ok "page says nothing was restarted"
else
  bad "page did not say the watchdog restarted nothing"
fi
if [ -f "$H/paged.log" ] && grep -F -q 'captain note waiting' "$H/paged.log"; then
  bad "page carried the wake text"
else
  ok "page omitted the wake text"
fi
if grep -F -q 'stalled: 1 inputs unhandled' "$H/data/watchdog/status.md"; then ok "status gap"; else bad "status missing stall gap"; fi
if kill -0 "$LOCKPID" 2>/dev/null; then ok "live lock holder still running"; else bad "live lock holder died"; fi
expect_no_restart
run_once 600
expect_eq "$(rows stall-input pending)" 1 "no second page inside the hour"
if grep -F -q 'stalled: 1 inputs unhandled' "$H/data/watchdog/status.md"; then ok "gap remains between pages"; else bad "gap disappeared inside the window"; fi
run_once 3700
expect_eq "$(rows stall-input pending)" 2 "page again after stall-page-secs"
expect_eq "$(rows stall-pr pending)" 0 "no PR page"
expect_no_restart
cp "$H/paged.log" "$EVID/stall-input-page.txt"
finish "Unhandled input older than 15 minutes with a working task pages once per hour and does not restart" stall-input-rate

# 2. Under threshold, idle home, and a shorter stall-secs.
make_home
add_task fm-a off "working [at=$((BASE - 100))]: implementing"
wake_line $((BASE - 600)) inbox "captain note waiting"
run_once 0
expect_eq "$(rows stall-input pending)" 0 "input under 15 minutes"
expect_quiet_stall
finish "Input younger than 15 minutes with work in flight does not page" stall-input-young

make_home
wake_line $((BASE - 3000)) inbox "captain note waiting"
run_once 0
expect_quiet_stall
expect_no_restart
finish "Old input with no in-flight task does not page" stall-input-idle

make_home 'stall-secs=300'
add_task fm-a off "working [at=$((BASE - 100))]: implementing"
wake_line $((BASE - 400)) inbox "captain note waiting"
run_once 0
expect_eq "$(rows stall-input done)" 1 "stall-secs=300 pages a 400s input"
expect_no_restart
finish "A configured stall-secs of 300 pages input that has waited 400 seconds" stall-secs-custom

# 3. Done and failed are not in flight. Note text never leaves the home.
make_home
add_task fm-d off "done [at=$((BASE - 2000))]: PR $GH_URL checks green"
wake_line $((BASE - 1000)) inbox "captain note waiting"
run_once 0
expect_quiet_stall
if grep -F -q 'inputs unhandled' "$H/data/watchdog/status.md"; then bad "done-only home left a stall gap"; else ok "no stall gap for a done task"; fi
finish "A home whose only task is done does not page stall-input" stall-done-only

make_home
add_task fm-f on "failed [at=$((BASE - 2000))]: the build broke; see $GH_URL"
add_note $((BASE - 1000)) "$SECRET"
run_once 0
expect_quiet_stall
if grep -R -F -q "$SECRET" "$H/data/watchdog" "$H/paged.log" "$H/state/watchdog" 2>/dev/null; then
  bad "secret note body leaked into watchdog output"
else
  ok "secret note body stayed out of the page and status"
fi
finish "A failed task is not in flight and an old inbox note does not page or leak its text" stall-failed-only

make_home
add_task fm-d off "done [at=$((BASE - 2000))]: PR $GH_URL checks green"
add_task fm-f on "failed [at=$((BASE - 1800))]: the build broke"
add_task fm-a off "working [at=$((BASE - 100))]: implementing"
add_note $((BASE - 1000)) "$SECRET"
run_once 0
expect_eq "$(rows stall-input done)" 1 "working task beside finished ones pages"
if [ -f "$H/paged.log" ] && grep -F -q 'while 1 tasks are in flight' "$H/paged.log"; then
  ok "only the working task counts"
else
  bad "in-flight count was not 1"
fi
if [ -f "$H/paged.log" ] && grep -F -q "$SECRET" "$H/paged.log"; then bad "page contained the note"; else ok "page omitted the note"; fi
expect_no_restart
cp "$H/paged.log" "$EVID/stall-input-mixed-page.txt"
finish "Done and failed tasks beside one working task page once and count only the working task" stall-mixed-flight

# 4. Declared waits, t3 thread, leading-zero timestamp.
make_home
add_task fm-a off "working [at=$((BASE - 100))]: implementing"
add_task fm-w off "paused [at=$((BASE - 2000))]: waiting on the machine-wide test queue"
printf '%s\t1\tsignal\tfm-w.status\tsignal: %s\n' "$((BASE - 2000))" "$H/state/fm-w.status" > "$H/state/.wake-queue"
printf '%s\t2\tstale\tterm_fm-w\tstale: term_fm-w\n' "$((BASE - 1900))" >> "$H/state/.wake-queue"
run_once 0
expect_quiet_stall
finish "Wake rows about a task in a declared wait stay quiet" stall-wait-rows

make_home
add_task fm-w off "paused [at=$((BASE - 2000))]: waiting on the machine-wide test queue"
wake_line $((BASE - 2000)) inbox "captain note waiting"
run_once 0
expect_quiet_stall
finish "A home whose only work is a declared wait does not page" stall-wait-only

make_home
add_task fm-a off "working [at=$((BASE - 100))]: implementing"
add_task fm-w off "paused [at=$((BASE - 2000))]: waiting on the machine-wide test queue"
printf '%s\t1\tsignal\tfm-w.status\tsignal\n' "$((BASE - 2000))" > "$H/state/.wake-queue"
printf '%s\t2\tsignal\tfm-a.status\tsignal\n' "$((BASE - 1000))" >> "$H/state/.wake-queue"
run_once 0
expect_eq "$(rows stall-input done)" 1 "working-task row still pages"
if [ -f "$H/paged.log" ] && grep -F -q '1 unhandled inputs, the oldest 16 minutes old' "$H/paged.log"; then
  ok "only the working row counts"
else
  bad "working-row age was not reported"
fi
finish "A wake about working-task input still pages beside a declared wait" stall-wait-beside

make_home
add_task fm-a off "working [at=$((BASE - 100))]: implementing"
add_task fm-w off "paused [at=$((BASE - 3000))]: waiting on CI"
printf 'resolved [at=%s]: CI finished\n' "$((BASE - 2500))" >> "$H/state/fm-w.status"
printf '%s\t1\tsignal\tfm-w.status\tsignal\n' "$((BASE - 2000))" > "$H/state/.wake-queue"
run_once 0
expect_eq "$(rows stall-input done)" 1 "resolved wait is in flight again"
finish "A resolved wait is no longer quiet" stall-wait-resolved

make_home
add_task fm-a off "working [at=$((BASE - 100))]: implementing"
printf 'kind=ship\nbackend=t3code\nt3_thread_id=thr-wait-1\nyolo=off\nendpoint_task_id=fm-t3\n' > "$H/state/fm-t3.meta"
printf 'paused [at=%s]: waiting on CI\n' "$((BASE - 2000))" > "$H/state/fm-t3.status"
printf '08\t1\tsignal\tbad-octal\tsignal\n' > "$H/state/.wake-queue"
printf '%s\t2\tstale\tthr-wait-1\tstale: thr-wait-1\n' "$((BASE - 1900))" >> "$H/state/.wake-queue"
run_once 0
expect_quiet_stall
finish "A t3code declared wait stays quiet and a leading-zero wake timestamp is ignored" stall-t3-octal

# 5. Ready PR, Forgejo, marker identity.
make_home
add_task fm-p on "done [at=$((BASE - 1000))]: PR $GH_URL checks green"
run_once 0
expect_eq "$(rows stall-pr done)" 1 "github PR delivered"
if [ -f "$H/paged.log" ] && grep -F -q "$GH_URL" "$H/paged.log" && grep -F -q 'waited up to 16 minutes' "$H/paged.log"; then
  ok "page names the PR and the age"
else
  bad "PR page missing url or age"
fi
if grep -F -q 'stalled: 1 ready PRs unlanded' "$H/data/watchdog/status.md"; then ok "PR gap"; else bad "PR gap missing"; fi
expect_no_restart
run_once 600
expect_eq "$(rows stall-pr pending)" 1 "PR page rate-limited"
add_marker fm-p fm-pr-poll-merge-notified-v1 github github.com o/r 7
run_once 3700
expect_eq "$(rows stall-pr pending)" 1 "landed PR does not page again"
if grep -F -q 'ready PRs unlanded' "$H/data/watchdog/status.md"; then bad "landed PR still a gap"; else ok "landed PR left the gaps"; fi
cp "$H/paged.log" "$EVID/stall-pr-page.txt"
finish "A yolo=on GitHub PR unlanded 16 minutes pages once until its merge marker matches" stall-pr-github

make_home
add_task fm-p on "done [at=$((BASE - 1000))]: PR $GH_URL checks green"
add_marker fm-p fm-pr-poll-merge-notified-v1 github github.com o/r 6
run_once 0
expect_eq "$(rows stall-pr done)" 1 "other PR number does not count as landed"
finish "A merge marker for another PR number does not suppress stall-pr" stall-pr-other-number

make_home
add_task fm-p on "done [at=$((BASE - 1000))]: PR $FJ_URL checks green"
add_marker fm-p fm-pr-poll-merge-notified-v1 forgejo other.example.com o/r 9
run_once 0
expect_eq "$(rows stall-pr done)" 1 "forgejo other host still pages"
if [ -f "$H/paged.log" ] && grep -F -q "$FJ_URL" "$H/paged.log"; then ok "page names the Forgejo URL"; else bad "Forgejo URL missing from the page"; fi
add_marker fm-p fm-pr-poll-merge-notified-v1 forgejo git.example.com o/r 9
run_once 3700
expect_eq "$(rows stall-pr pending)" 1 "matching Forgejo marker stops the next page"
cp "$H/paged.log" "$EVID/stall-pr-forgejo-page.txt"
finish "A Forgejo /pulls/ URL pages, and only a marker for that host counts as landed" stall-pr-forgejo

make_home
add_task fm-p on "done [at=$((BASE - 1000))]: PR $FJ_URL checks green"
add_marker fm-p fm-pr-poll-merge-notified-v0 forgejo git.example.com o/r 9
run_once 0
expect_eq "$(rows stall-pr done)" 1 "wrong marker version does not count as landed"
finish "A merge marker with the wrong version does not suppress stall-pr" stall-pr-bad-version

make_home
add_task fm-s on "done [at=$((BASE - 1000))]: reviewed $GH_URL" scout
run_once 0
expect_quiet_stall
finish "A scout task that names a PR URL does not trigger stall-pr" stall-pr-scout

make_home
add_task fm-p off "done [at=$((BASE - 1000))]: PR $GH_URL checks green"
run_once 0
expect_quiet_stall
finish "A PR waiting on the owner's merge word stays quiet" stall-pr-yolo-off

make_home
add_task fm-p on "done [at=$((BASE - 600))]: PR $GH_URL checks green"
run_once 0
expect_eq "$(rows stall-pr pending)" 0 "PR under stall-secs"
expect_quiet_stall
finish "A ready PR younger than 15 minutes does not page" stall-pr-young

make_home
add_task fm-p on "paused [at=$((BASE - 1000))]: PR $GH_URL held as a draft"
run_once 0
expect_quiet_stall
finish "A PR held in a declared wait stays quiet" stall-pr-paused

# 6. Dead holder cannot hide or lose the lock. Live holder without the composer seam cannot hide it.
make_home
add_task fm-a off "working [at=$((BASE - 100))]: implementing"
wake_line $((BASE - 1000)) inbox "captain note waiting"
kill "$LOCKPID" 2>/dev/null || true
sleep 0.3
run_once 0
expect_eq "$(rows stall-input done)" 1 "dead holder still pages"
if cmp -s "$H/state/.lock" "$H/lock.before"; then ok "dead holder's lock was not taken"; else bad "lock file changed after the holder died"; fi
expect_eq "$(restarts)" 0 "restart-rows"
finish "A dead lock holder still gets the stall page and the watchdog does not take the lock" stall-dead-holder

make_home
add_task fm-a off "working [at=$((BASE - 100))]: implementing"
wake_line $((BASE - 1000)) inbox "captain note waiting"
run_once 0 none
expect_eq "$(rows stall-input done)" 1 "real pane classification still pages"
if kill -0 "$LOCKPID" 2>/dev/null; then ok "live holder survived"; else bad "live holder died"; fi
expect_no_restart
if [ -f "$H/paged.log" ]; then cp "$H/paged.log" "$EVID/stall-input-live-pane-page.txt"; fi
finish "A live lock holder and a fresh heartbeat, with the real pane read, do not hide the stall page" stall-live-pane

# 7. Dry-run records without sending. Alerts off refuse and still report the gap.
make_home 'mode=dry-run'
add_task fm-a off "working [at=$((BASE - 100))]: implementing"
wake_line $((BASE - 1000)) inbox "captain note waiting"
run_once 0
expect_eq "$(rows stall-input dry-run)" 1 "dry-run recorded"
if [ -e "$H/paged.log" ]; then bad "dry-run delivered a page"; else ok "dry-run sent nothing"; fi
expect_no_restart
finish "Dry-run records the stall page it would send and does not deliver it" stall-dry-run

ALARM=off
make_home
add_task fm-a off "working [at=$((BASE - 100))]: implementing"
wake_line $((BASE - 1000)) inbox "captain note waiting"
run_once 0
expect_eq "$(rows stall-input refused)" 1 "alerts off refused"
if grep -F -q 'stall-input not paged' "$H/data/watchdog/status.md"; then ok "unpaged stall stays a gap"; else bad "refused stall was not reported"; fi
if [ -e "$H/paged.log" ]; then bad "alerts off still wrote a page"; else ok "no page file"; fi
expect_no_restart
ALARM=command
finish "Alerts turned off refuse the stall page and the gap stays visible" stall-alerts-off

# External tools must not have been asked to merge, deploy, or notify.
if grep -E 'merge|deploy|osascript|terminal-notifier|mail' "$LAB/external-calls.log" >/dev/null 2>&1; then
  bad "watchdog called a merge, deploy, or desktop notifier"
  FAILS=$((FAILS + 1))
  printf 'FAIL\texternal tools\n' | tee -a "$EVID/scenario-results.tsv"
else
  ok "no merge, deploy, or desktop notifier call"
  printf 'PASS\tno merge deploy or desktop notification\n' | tee -a "$EVID/scenario-results.tsv"
fi
cp "$LAB/external-calls.log" "$EVID/external-calls.log" 2>/dev/null || : > "$EVID/external-calls.log"

printf 'failures=%s\n' "$FAILS" | tee -a "$EVID/scenario-results.tsv"
exit "$FAILS"
