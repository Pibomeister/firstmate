#!/usr/bin/env bash
# fm-handoff-launch.sh - launch the successor primary session for a handoff,
# and own the two ends of the predecessor's exit.
#
# The Claude handoff Stop gate (bin/fm-handoff-trigger.sh) refuses to end a
# primary's planned-fresh-start turn until state/.handoff-successor names a
# live successor pid or this launcher recorded a final launch failure. This
# script is the firstmate-owned launcher that creates that successor, so a
# handoff turn ends with a successor under way instead of waiting for a manual
# launch (issue 116).
#
# LAUNCH (fm-handoff-launch.sh <handoff-file>). Given a written handoff
# document, it:
#   1. resolves the home's recorded backend (bin/fm-backend.sh
#      fm_backend_name: FM_BACKEND, config/backend, runtime detection,
#      default tmux) and refuses rather than guess when no supported
#      successor launcher exists for it - currently orca and tmux,
#      mirroring bin/fm-watchdog.sh's restart launch;
#   2. resolves the current primary's harness (bin/fm-harness.sh) and
#      refuses unless it is claude, the only harness the handoff gate
#      serves; the successor runs the lowercase claude binary with the
#      permission flag config/claude-permission-mode selects for this
#      home (bin/fm-spawn.sh's resolution: bypass, the default, is
#      --dangerously-skip-permissions; auto is --permission-mode auto);
#   3. launches the successor in a NEW terminal on that backend, with
#      FM_HANDOFF_PREDECESSOR_PID=<predecessor pid> in its environment (so
#      bin/fm-sessionstart-run.sh skips the read-only startup digest while
#      the predecessor still holds the lock) and a prompt naming the handoff
#      path and the document's sha256 (and its sha8 prefix): confirm the
#      hash and read only that document, wait for the predecessor (line 1 of
#      state/.lock) with --await-predecessor, run bin/fm-session-start.sh
#      once, and re-check PR, worker, order, and decision facts from live
#      records before acting on the document's copy of them, with
#      bin/fm-order.sh pickup listing the captain orders recorded after the
#      launch;
#   4. waits for the new harness pid to appear (a live process whose
#      command line carries the handoff path and was not there before the
#      launch), then checks that it is still alive after a settle, and
#      writes state/.handoff-successor as pid=<pid>, handoff=<path>,
#      predecessor=<predecessor pid>, and launched=<epoch taken just before
#      the document was hashed> so the Stop gate passes, removing any
#      earlier launch-failure record. It
#      verifies only that live successor pid; the successor confirms the
#      handoff sha256 at pickup and stops on a mismatch.
# A launch whose terminal fails to open or whose successor dies during the
# settle is tried again, up to two attempts in all. A successor that never
# appears within the timeout is not retried, because a late start of that
# terminal would leave two successors. When no attempt yields a live successor,
# or the launch is refused after the handoff document was given, it writes
# state/.handoff-launch-failed (at= attempts= backend= handoff= reason=),
# which releases the Stop gate, prints the escalation (tell the captain, keep
# working, let auto-compaction run; the next cycle retries), and exits 1.
#
# On tmux the successor opens in the primary's own tmux session when the
# launcher runs inside one, otherwise in firstmate-<home basename>, as
# bin/fm-watchdog.sh's restart launch names it.
#
# The launch never kills, interrupts, or signals the current session beyond a
# kill -0 liveness read. A second mate home is refused: a second mate asks its
# parent to relaunch it.
#
# AWAIT (fm-handoff-launch.sh --await-predecessor <pid>). The successor's
# bounded wait for the predecessor: exit 0 once <pid> is no longer a live
# harness process, exit 3 when it is still running after the bound (default
# 90 seconds, inside a tool call's default timeout), exit 2 on a usage error.
#
# END (fm-handoff-launch.sh --end-predecessor <pid> <transcript> <bytes>). Run
# detached by the trigger's Stop hook when a handoff's stop can end the old
# session with a live successor recorded (one live pane). When
# FM_HANDOFF_END_AFTER_PID names the hook, it first waits up to 60 seconds for
# that hook to exit; the hook cancels it when it blocks the stop. After a settle (default 15
# seconds) it ends <pid> with SIGTERM, waiting up to 30 seconds for it to go,
# only when all of these still hold: state/.lock names <pid>, the successor
# record names a different live pid, <pid> is a live harness process, and the
# transcript has no new user or queued-message record past <bytes>, and
# `bin/fm-order.sh covers` still passes for the successor record's handoff
# document, which counts an order recorded after the launch as covered by the
# successor's pickup, so an older open order the document omits keeps the old
# session (reason=order-gate). Claude
# can flush the stopped turn's final assistant reply after the Stop hook
# measures <bytes>, so an assistant record, like Claude's own bookkeeping
# after a stop, does not count as a new turn. It records the outcome in state/.handoff-end as
# at= pred= result=ended|alive|skipped reason=. It never signals anything else.
#
# Test seam, honoured only with FM_TEST_SEAM=1: FM_HANDOFF_TEST_HARNESS
# pins the resolved primary harness, FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS bounds
# each attempt's successor wait, FM_HANDOFF_SETTLE_SECS sets the launch settle,
# FM_HANDOFF_LAUNCH_ATTEMPTS the attempt count, FM_HANDOFF_AWAIT_SECS the await
# bound, and FM_HANDOFF_END_SETTLE_SECS and FM_HANDOFF_END_WAIT_SECS the end
# settle and the wait after SIGTERM.
#
# Usage: fm-handoff-launch.sh <handoff-file>
#        fm-handoff-launch.sh --await-predecessor <pid>
#        fm-handoff-launch.sh --end-predecessor <pid> <transcript> <bytes>
#        fm-handoff-launch.sh -h|--help
set -u

case "${1:-}" in
  -h | --help) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

# seam_secs <variable> <default>: a test seam's whole-second value, honoured
# only with FM_TEST_SEAM=1.
seam_secs() {
  local value=$2
  if [ "${FM_TEST_SEAM:-}" = 1 ]; then
    eval "value=\${$1:-$2}"
    case "$value" in '' | *[!0-9]*) value=$2 ;; esac
  fi
  printf '%s\n' "$value"
}

# atomic_record <path> <content>: replace a state record with an atomic rename.
atomic_record() {
  local tmp
  tmp=$(mktemp "$1.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$1"; then return 0; fi
  rm -f "$tmp"
  return 1
}

harness_alive() {  # <pid>
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  fm_harness_pid_alive "$1"
}

# --await-predecessor <pid>
await_predecessor() {
  local pid=$1 bound waited=0
  case "$pid" in '' | *[!0-9]*) printf 'usage: fm-handoff-launch.sh --await-predecessor <pid>\n' >&2; exit 2 ;; esac
  bound=$(seam_secs FM_HANDOFF_AWAIT_SECS 90)
  while harness_alive "$pid"; do
    if [ "$waited" -ge "$bound" ]; then
      printf 'predecessor pid %s is still running after %ss: tell the captain that the old session still runs in its own terminal and ask them to /exit it, then run this wait again; do not take over until it is gone\n' "$pid" "$bound"
      exit 3
    fi
    sleep 1
    waited=$((waited + 1))
  done
  printf 'predecessor pid %s has ended\n' "$pid"
  exit 0
}

# new_turn_since <transcript> <bytes>: true when the transcript gained a
# record that starts a new turn past <bytes>: a user prompt or a queued
# message. A late assistant record is the stopped turn's own final reply.
new_turn_since() {
  tail -c "+$(($2 + 1))" "$1" 2>/dev/null | jq -R -r 'fromjson? | .type // empty | strings' 2>/dev/null \
    | grep -qxE 'user|queue-operation'
}

# --end-predecessor <pid> <transcript> <bytes>
end_predecessor() {
  local pid=$1 transcript=$2 bytes=$3 settle wait_secs after lock succ succ_doc result=skipped reason='' waited=0
  case "$pid:$bytes" in *[!0-9:]* | :* | *:) printf 'usage: fm-handoff-launch.sh --end-predecessor <pid> <transcript> <bytes>\n' >&2; exit 2 ;; esac
  settle=$(seam_secs FM_HANDOFF_END_SETTLE_SECS 15)
  wait_secs=$(seam_secs FM_HANDOFF_END_WAIT_SECS 30)
  # The trigger detaches this ender before its slower gate checks and cancels
  # it when it blocks the stop, so wait first until that hook has exited.
  after=${FM_HANDOFF_END_AFTER_PID:-}
  case "$after" in '' | *[!0-9]*) after= ;; esac
  while [ -n "$after" ] && kill -0 "$after" 2>/dev/null && [ "$waited" -lt 60 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  waited=0
  sleep "$settle"
  lock=$(cat "$STATE/.lock" 2>/dev/null)
  succ=$(sed -n 's/^pid=//p' "$STATE/.handoff-successor" 2>/dev/null | tail -n 1)
  case "$succ" in '' | *[!0-9]*) succ= ;; esac
  succ_doc=$(sed -n 's/^handoff=//p' "$STATE/.handoff-successor" 2>/dev/null | tail -n 1)
  if [ "$lock" != "$pid" ]; then
    reason='lock-moved'
  elif [ -z "$succ" ] || [ "$succ" = "$pid" ] || ! kill -0 "$succ" 2>/dev/null; then
    reason=no-live-successor
  elif ! harness_alive "$pid"; then
    reason=predecessor-gone
  elif [ ! -r "$transcript" ] || new_turn_since "$transcript" "$bytes"; then
    reason=new-turn
  elif ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-order.sh" covers "$succ_doc" >/dev/null 2>&1; then
    reason=order-gate
  else
    kill -TERM "$pid" 2>/dev/null
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$wait_secs" ]; do
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then result=alive reason=term-ignored; else result=ended reason=handoff; fi
  fi
  atomic_record "$STATE/.handoff-end" "at=$(date +%s) pred=$pid result=$result reason=$reason" || true
  exit 0
}

case "${1:-}" in
  --await-predecessor)
    [ $# -eq 2 ] || { printf 'usage: fm-handoff-launch.sh --await-predecessor <pid>\n' >&2; exit 2; }
    await_predecessor "$2" ;;
  --end-predecessor)
    [ $# -eq 4 ] || { printf 'usage: fm-handoff-launch.sh --end-predecessor <pid> <transcript> <bytes>\n' >&2; exit 2; }
    end_predecessor "$2" "$3" "$4" ;;
esac

[ $# -eq 1 ] && [ -n "$1" ] || die "usage: fm-handoff-launch.sh <handoff-file>"
HANDOFF=$1
[ -f "$HANDOFF" ] && [ -r "$HANDOFF" ] || die "handoff document is not a readable file: $HANDOFF"
case "$HANDOFF" in
  /*) ;;
  *) HANDOFF="$(pwd -P)/$HANDOFF" ;;
esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
if fm_root_is_secondmate_home "$FM_HOME"; then
  die "this is a second mate home; a second mate asks its parent to relaunch it and never launches its own successor"
fi

FAILED_RECORD="$STATE/.handoff-launch-failed"
ATTEMPTS=0
BACKEND=''

# fail_launch <reason>: record the final launch failure, which releases the
# Stop gate, and escalate.
fail_launch() {
  atomic_record "$FAILED_RECORD" \
    "at=$(date +%s) attempts=$ATTEMPTS backend=${BACKEND:-unknown} handoff=$HANDOFF reason=$(printf '%s' "$1" | tr -s ' \n' '-' | cut -c1-120)" || true
  printf 'error: %s\n' "$1" >&2
  printf 'No successor is running. state/.handoff-launch-failed records the failure and releases the handoff stop gate: tell the captain that the planned fresh start could not launch a successor (%s), keep working in this session, and let auto-compaction run; the next context cycle tries the handoff again.\n' "$1" >&2
  exit 1
}

# The harness must be determined, not guessed: the launcher runs as the
# primary's own subprocess, so its harness is the primary's.
if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_HANDOFF_TEST_HARNESS:-}" ]; then
  HARNESS=$FM_HANDOFF_TEST_HARNESS
else
  HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null) || HARNESS=''
fi
case "$HARNESS" in
  claude) ;;
  '') fail_launch "cannot determine the current primary's harness; refusing to launch a successor" ;;
  *) fail_launch "the current primary runs harness '$HARNESS', not claude; the handoff successor launcher serves a claude primary only" ;;
esac
command -v claude >/dev/null 2>&1 || fail_launch "the lowercase claude binary is not on PATH; refusing to launch a successor"

# The backend must be the home's recorded one, with a supported launcher.
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
BACKEND=$(fm_backend_name 2>/dev/null) || BACKEND=''
[ -n "$BACKEND" ] || fail_launch "cannot determine the home's recorded backend; refusing to launch a successor"
case "$BACKEND" in
  orca) command -v orca >/dev/null 2>&1 || fail_launch "backend orca is recorded but the orca binary is not on PATH" ;;
  tmux) command -v tmux >/dev/null 2>&1 || fail_launch "backend tmux is recorded but the tmux binary is not on PATH" ;;
  *)
    if fm_backend_is_known "$BACKEND"; then
      fail_launch "no successor launcher for backend '$BACKEND' yet (supported: orca, tmux); refusing to guess another backend"
    fi
    fail_launch "backend '$BACKEND' is not a known backend; refusing to launch a successor"
    ;;
esac

# The predecessor pid anchors the successor's wait and must be real.
[ -f "$STATE/.lock" ] || fail_launch "no session lock at $STATE/.lock; cannot name the predecessor pid the successor must wait for"
PRED_PID=$(head -n 1 "$STATE/.lock" 2>/dev/null | tr -cd '0-9')
[ -n "$PRED_PID" ] || fail_launch "state/.lock names no predecessor pid; refusing to launch a successor"
kill -0 "$PRED_PID" 2>/dev/null || fail_launch "predecessor pid $PRED_PID from state/.lock is not alive; refusing to launch a successor"

# Permission posture: the same flag the home's config gives a claude launch.
CLAUDE_PERMISSION_MODE=bypass
if [ -e "$CONFIG/claude-permission-mode" ]; then
  [ -f "$CONFIG/claude-permission-mode" ] && [ -r "$CONFIG/claude-permission-mode" ] \
    || fail_launch "config/claude-permission-mode must be a readable regular file holding one of: bypass, auto"
  CLAUDE_PERMISSION_MODE=$(tr -d '[:space:]' <"$CONFIG/claude-permission-mode" || true)
  case "$CLAUDE_PERMISSION_MODE" in
    bypass | auto) ;;
    *) fail_launch "config/claude-permission-mode holds '$CLAUDE_PERMISSION_MODE'; accepted values are: bypass (--dangerously-skip-permissions, the default when the file is absent), auto (--permission-mode auto)" ;;
  esac
fi
case "$CLAUDE_PERMISSION_MODE" in
  auto) PERM_FLAG='--permission-mode auto' ;;
  *) PERM_FLAG='--dangerously-skip-permissions' ;;
esac

# Hash confirmation material for the successor prompt. An order recorded from
# here on is left to the successor's pickup (bin/fm-order.sh).
LAUNCHED_AT=$(date +%s)
if command -v sha256sum >/dev/null 2>&1; then
  SHA256=$(sha256sum "$HANDOFF" 2>/dev/null | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  SHA256=$(shasum -a 256 "$HANDOFF" 2>/dev/null | awk '{print $1}')
else
  fail_launch "neither sha256sum nor shasum is available; the successor could not confirm the handoff hash"
fi
case "$SHA256" in
  *[!0-9a-f]* | '') fail_launch "could not hash the handoff document: $HANDOFF" ;;
esac
[ "${#SHA256}" -eq 64 ] || fail_launch "could not hash the handoff document: $HANDOFF"
SHA8=${SHA256:0:8}

LAUNCH_RECORD="$STATE/.handoff-successor"

PROMPT="Firstmate handoff successor for home $FM_HOME. The handoff document is $HANDOFF with sha256 $SHA256 (sha8 $SHA8). Confirm that hash before acting (sha256sum or shasum -a 256 on the document) and stop if it does not match; read only that document, because any addendum file is not part of the handoff. The predecessor session, harness pid $PRED_PID, is ended when its handoff turn ends. Wait for that with FM_HOME=$FM_HOME $FM_ROOT/bin/fm-handoff-launch.sh --await-predecessor $PRED_PID: exit 0 means it is gone; exit 3 means it still runs, so tell the captain that the old session still runs in its own terminal and ask them to /exit it, then wait again, and do not take over until it is gone. Once it is gone, run FM_HOME=$FM_HOME $FM_ROOT/bin/fm-session-start.sh once to take the session lock, unless this session's startup digest already shows that it holds the lock. Before acting on any PR, worker, order, or decision fact from the handoff, re-check it from live records: drain the wake queue, run bin/fm-crew-state.sh, and run bin/fm-order.sh pickup, which also lists the captain orders recorded after this launch, because the document can be stale and stays unchanged after it."
SUCCESSOR_CMD="FM_HANDOFF_PREDECESSOR_PID=$PRED_PID claude $PERM_FLAG $(printf '%q' "$PROMPT")"

# Pids whose command line already carries the handoff path (this launcher
# and its ancestors do), so only a pid appearing after the launch counts.
pids_carrying_handoff() {
  ps -eo pid=,args= 2>/dev/null | while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    pid=${line%% *}
    case "$pid" in *[!0-9]* | '') continue ;; esac
    case "$line" in *"$HANDOFF"*) printf '%s\n' "$pid" ;; esac
  done
}
BASELINE=" $(pids_carrying_handoff | tr '\n' ' ')"

# open_terminal: start the successor command in a new terminal on the backend.
open_terminal() {
  local sess
  case "$BACKEND" in
    orca)
      orca terminal create --worktree "path:$FM_HOME" --title "firstmate captain" \
        --command "$SUCCESSOR_CMD" --json >/dev/null 2>&1
      ;;
    tmux)
      sess=''
      [ -z "${TMUX:-}" ] || sess=$(tmux display-message -p '#{session_name}' 2>/dev/null) || sess=''
      sess=${sess:-firstmate-$(basename "$FM_HOME")}
      if tmux has-session -t "=$sess" >/dev/null 2>&1; then
        tmux new-window -d -t "=$sess:" -c "$FM_HOME" -n firstmate "$SUCCESSOR_CMD" >/dev/null 2>&1
      else
        tmux new-session -d -s "$sess" -c "$FM_HOME" -n firstmate "$SUCCESSOR_CMD" >/dev/null 2>&1
      fi
      ;;
  esac
}

# find_new_pid: set NEW_PID to the newest live pid carrying the handoff path
# that was not there before the first launch. A terminal may start a shell
# wrapper first, and the harness it launches carries the higher pid. It runs in
# this shell, never in a command substitution, whose own fork would carry the
# handoff path and read as a live successor.
find_new_pid() {
  local pid
  NEW_PID=''
  for pid in $(pids_carrying_handoff); do
    case "$BASELINE" in *" $pid "*) continue ;; esac
    [ "$pid" != "$$" ] || continue
    [ "$pid" != "$PRED_PID" ] || continue
    if kill -0 "$pid" 2>/dev/null && [ "$pid" -gt "${NEW_PID:-0}" ]; then
      NEW_PID=$pid
    fi
  done
}

TIMEOUT=$(seam_secs FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS 60)
SETTLE=$(seam_secs FM_HANDOFF_SETTLE_SECS 5)
MAX_ATTEMPTS=$(seam_secs FM_HANDOFF_LAUNCH_ATTEMPTS 2)
[ "$MAX_ATTEMPTS" -ge 1 ] || MAX_ATTEMPTS=1

SUCC_PID=''
LAST_FAILURE=''
while [ -z "$SUCC_PID" ] && [ "$ATTEMPTS" -lt "$MAX_ATTEMPTS" ]; do
  ATTEMPTS=$((ATTEMPTS + 1))
  if ! open_terminal; then
    LAST_FAILURE="$BACKEND failed to open the successor terminal"
    continue
  fi
  waited=0
  while :; do
    find_new_pid
    SUCC_PID=$NEW_PID
    [ -z "$SUCC_PID" ] || break
    [ "$waited" -lt "$TIMEOUT" ] || break
    sleep 1
    waited=$((waited + 1))
  done
  if [ -z "$SUCC_PID" ]; then
    LAST_FAILURE="the successor never appeared within ${TIMEOUT}s on backend $BACKEND"
    break
  fi
  # A harness that dies at start (a bad flag, a login prompt that exits) is no
  # successor: it must still be alive after the settle.
  sleep "$SETTLE"
  if ! kill -0 "$SUCC_PID" 2>/dev/null; then
    LAST_FAILURE="the successor pid $SUCC_PID exited within ${SETTLE}s of its start on backend $BACKEND"
    find_new_pid
    SUCC_PID=$NEW_PID
  fi
done
[ -n "$SUCC_PID" ] || fail_launch "$LAST_FAILURE after $ATTEMPTS attempt(s); state/.handoff-successor left unwritten"

atomic_record "$LAUNCH_RECORD" "pid=$SUCC_PID
handoff=$HANDOFF
predecessor=$PRED_PID
launched=$LAUNCHED_AT" || fail_launch "cannot record the successor in $LAUNCH_RECORD"
rm -f "$FAILED_RECORD"
printf 'successor launched: pid=%s backend=%s handoff=%s sha8=%s attempt %s of %s\n' \
  "$SUCC_PID" "$BACKEND" "$HANDOFF" "$SHA8" "$ATTEMPTS" "$MAX_ATTEMPTS"
