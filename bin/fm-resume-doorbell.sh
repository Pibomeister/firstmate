#!/usr/bin/env bash
# fm-resume-doorbell.sh - start a turn in an idle primary after a Claude auto
# compaction, with no model call.
#
# An idle auto compaction runs the SessionStart hook (source=compact), whose
# context re-emit reaches the model only when its next turn starts - and
# nothing starts one. bin/fm-sessionstart-run.sh launches this script detached;
# docs/sessionstart-nudge.md owns when.
#
# It waits FM_RESUME_DOORBELL_SETTLE_SECS (default 20) for the session to
# settle, then polls every FM_RESUME_DOORBELL_POLL_SECS (default 5), at most
# FM_RESUME_DOORBELL_WAIT_SECS (default 120) in all, until the target in
# state/captain-handle is provably idle: its agent is alive, its composer is
# empty, its backend reports native idle, and the session transcript
# (--transcript), when given, has not grown for one poll. A backend with no
# native busy state never qualifies, so the doorbell stands down there.
# It then types the one constant FM_RESUME_DOORBELL_LINE and confirms the
# submit: when the first Enter does not land it presses Enter again only while
# the composer holds exactly that line, at most FM_RESUME_DOORBELL_RESUBMIT_TRIES
# times (default 2) FM_RESUME_DOORBELL_RESUBMIT_DELAY seconds apart (default
# 1.5, clear of the paste window), and reports submitted only once the composer
# reads empty or the agent reads busy.
#
# It stands down, typing nothing, when the session lock changes owner, an away
# or quiet record exists, a Stop claimed after the compaction (a turn already
# ran), the handle is unreadable or older than the session lock, the agent is
# not alive, the composer is not empty, a turn is running, idleness cannot be
# proven before the wait limit, or another doorbell holds or takes over
# state/.resume-doorbell.lock (each poll re-reads the lock's pid, so of two
# doorbells that both cleared a stale lock only the last one types, and a
# doorbell removes the lock on exit only while it still names it). Every run
# appends one row to
# state/.resume-doorbell.log:
#   <utc-iso>\t<epoch>\t<source>\t<backend>:<target>\t<outcome>\t<detail>
# with outcome submitted, unverified, stood-down or failed. It never kills,
# interrupts or signals anything, and it exits 0.
#
# Test seam, honoured only with FM_TEST_SEAM=1: FM_RESUME_DOORBELL_TEST_LIB is
# sourced after bin/fm-backend.sh so a suite can replace the backend reads and
# keystrokes.
#
# Usage: fm-resume-doorbell.sh [--source <source>] [--transcript <path>]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

FM_RESUME_DOORBELL_LINE=': Firstmate resume after context compaction: re-read state and open goals (run bin/fm-wake-drain.sh and bin/fm-order.sh pickup), then continue the open work.'

SOURCE=compact
TRANSCRIPT=
while [ $# -gt 0 ]; do
  case "$1" in
    --source) SOURCE=${2:-compact}; shift; [ $# -eq 0 ] || shift ;;
    --transcript) TRANSCRIPT=${2:-}; shift; [ $# -eq 0 ] || shift ;;
    -h|--help) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) shift ;;
  esac
done

int_or() {  # <value> <default>: a whole number of seconds or tries
  case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}
secs_or() {  # <value> <default>: a sleep(1) duration such as 5 or 0.2
  if printf '%s' "$1" | grep -Eq '^[0-9]+([.][0-9]+)?$'; then printf '%s' "$1"; else printf '%s' "$2"; fi
}
SETTLE=$(secs_or "${FM_RESUME_DOORBELL_SETTLE_SECS:-}" 20)
POLL=$(secs_or "${FM_RESUME_DOORBELL_POLL_SECS:-}" 5)
WAIT=$(int_or "${FM_RESUME_DOORBELL_WAIT_SECS:-}" 120)
TRIES=$(int_or "${FM_RESUME_DOORBELL_RESUBMIT_TRIES:-}" 2)
RESUBMIT_DELAY=$(secs_or "${FM_RESUME_DOORBELL_RESUBMIT_DELAY:-}" 1.5)
LOG="$STATE/.resume-doorbell.log"
LOCK="$STATE/.resume-doorbell.lock"
BACKEND=
TARGET=

log_row() {  # <outcome> <detail>
  local detail
  detail=$(printf '%s' "$2" | tr '\t\r\n' '   ')
  printf '%s\t%s\t%s\t%s:%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date +%s)" \
    "$SOURCE" "${BACKEND:-none}" "${TARGET:-none}" "$1" "$detail" >> "$LOG" 2>/dev/null || true
}

finish() {  # <outcome> <detail>
  log_row "$1" "$2"
  exit 0
}

[ -d "$STATE" ] || exit 0

# Single flight: a second doorbell while one is live types nothing.
if ! mkdir "$LOCK" 2>/dev/null; then
  holder=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    finish stood-down "another resume doorbell (pid $holder) is running"
  fi
  # A lock whose pid is not written yet belongs to a doorbell between its
  # mkdir and its pid write; only an old one is stale.
  if [ -z "$holder" ] && [ -n "$(find "$LOCK" -maxdepth 0 -newermt '-10 seconds' 2>/dev/null)" ]; then
    finish stood-down "another resume doorbell is starting"
  fi
  rm -rf "$LOCK" 2>/dev/null || true
  mkdir "$LOCK" 2>/dev/null || finish stood-down "the doorbell lock could not be taken"
fi
printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null || true
trap '[ "$(cat "$LOCK/pid" 2>/dev/null)" != "$$" ] || rm -rf "$LOCK" 2>/dev/null || true' EXIT

LOCK_PID=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
[ -n "$LOCK_PID" ] || finish stood-down "no session lock"

read_handle() {
  BACKEND=$(sed -n 's/^backend=//p' "$STATE/captain-handle" 2>/dev/null | head -n 1)
  TARGET=$(sed -n 's/^target=//p' "$STATE/captain-handle" 2>/dev/null | head -n 1)
  [ -n "$BACKEND" ] && [ -n "$TARGET" ]
}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh" >/dev/null 2>&1 || finish failed "bin/fm-backend.sh could not be loaded"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh" >/dev/null 2>&1 || finish failed "bin/fm-task-inbox-lib.sh could not be loaded"
if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_RESUME_DOORBELL_TEST_LIB:-}" ]; then
  # shellcheck source=/dev/null
  . "$FM_RESUME_DOORBELL_TEST_LIB" || finish failed "the test seam library could not be loaded"
fi

transcript_size() {
  [ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || { printf ''; return 0; }
  wc -c < "$TRANSCRIPT" 2>/dev/null | tr -d '[:space:]'
}

# Prints the stand-down reason, or nothing when the target is provably idle.
# <previous transcript size> is the size one poll earlier.
idle_reason() {  # <previous-size>
  local prev=$1 agent busy composer size
  # A second doorbell that cleared the same stale lock may have replaced ours.
  [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] || { printf 'another resume doorbell took the lock'; return 0; }
  [ "$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)" = "$LOCK_PID" ] || { printf 'the session lock changed owner'; return 0; }
  kill -0 "$LOCK_PID" 2>/dev/null || { printf 'the session lock changed owner'; return 0; }
  # The handle counts only when this session recorded it: the re-emit's
  # claim-handle rewrites it after the lock, so a handle older than the lock
  # names some earlier session's terminal.
  [ ! "$STATE/.lock" -nt "$STATE/captain-handle" ] || { printf 'state/captain-handle is older than the session lock'; return 0; }
  if [ -e "$STATE/.afk" ] || [ -e "$STATE/.afk-contract" ]; then
    printf 'an away or quiet record exists'; return 0
  fi
  # A Stop that claimed after this compaction means a turn already ran.
  if [ -e "$STATE/.context-epoch" ] && [ "$STATE/.claude-autoarm-epoch" -nt "$STATE/.context-epoch" ]; then
    printf 'a turn already ended after the compaction'; return 0
  fi
  agent=$(fm_backend_agent_state "$BACKEND" "$TARGET" 2>/dev/null || printf unknown)
  [ "$agent" = alive ] || { printf 'agent state is %s' "$agent"; return 0; }
  composer=$(fm_backend_composer_state "$BACKEND" "$TARGET" 2>/dev/null || printf unknown)
  [ "$composer" = empty ] || { printf 'composer is %s' "$composer"; return 0; }
  busy=$(fm_backend_busy_state "$BACKEND" "$TARGET" 2>/dev/null || printf unknown)
  [ "$busy" != busy ] || { printf 'a turn is running'; return 0; }
  [ "$busy" = idle ] || { printf 'busy state is %s, not a native idle' "$busy"; return 0; }
  # Native idle can lag a turn that just started, so a transcript, when one
  # was given, must also have stayed unchanged for a whole poll.
  if [ -n "$TRANSCRIPT" ]; then
    size=$(transcript_size)
    [ -n "$size" ] && [ -n "$prev" ] && [ "$size" = "$prev" ] \
      || { printf 'the transcript is not proven quiet'; return 0; }
  fi
}

sleep "$SETTLE"
deadline=$(( $(date +%s) + WAIT ))
prev=$(transcript_size)
reason=
while :; do
  sleep "$POLL"
  # The handle is read here, not inside idle_reason's command substitution,
  # so the backend and target survive into the send below.
  read_handle || finish stood-down 'state/captain-handle is unreadable'
  reason=$(idle_reason "$prev")
  [ -n "$reason" ] || break
  case "$reason" in
    'another resume doorbell took the lock'|'state/captain-handle is older than the session lock'|'the session lock changed owner'|'agent state is '*|'composer is '*|'a turn is running'|'busy state is '*|'an away or quiet record exists'|'a turn already ended after the compaction')
      finish stood-down "$reason" ;;
  esac
  prev=$(transcript_size)
  [ "$(date +%s)" -lt "$deadline" ] || finish stood-down "not-quiet: $reason"
done

verdict=$(fm_backend_send_text_submit "$BACKEND" "$TARGET" "$FM_RESUME_DOORBELL_LINE" 1 0.4 0.3 2>/dev/null) \
  || finish failed "the send did not complete"
case "$verdict" in
  send-failed) finish failed "send-failed" ;;
  empty) finish submitted "first Enter landed" ;;
esac

# The first Enter did not land (the verdict was pending or unproven). Press
# Enter again only while the composer holds exactly copies of our line.
i=0
while [ "$i" -lt "$TRIES" ]; do
  sleep "$RESUBMIT_DELAY"
  if fm_task_inbox_composer_holds "$BACKEND" "$TARGET" "$FM_RESUME_DOORBELL_LINE"; then
    fm_backend_send_key "$BACKEND" "$TARGET" Enter >/dev/null 2>&1 || finish failed "the resubmit Enter could not be sent"
    i=$((i + 1))
    continue
  fi
  break
done
sleep "$RESUBMIT_DELAY"
if [ "$(fm_backend_busy_state "$BACKEND" "$TARGET" 2>/dev/null || printf unknown)" = busy ]; then
  finish submitted "turn started after $i resubmit Enter(s)"
fi
if [ "$(fm_backend_composer_state "$BACKEND" "$TARGET" 2>/dev/null || printf unknown)" = empty ]; then
  finish submitted "composer cleared after $i resubmit Enter(s)"
fi
finish unverified "submit not confirmed after $i resubmit Enter(s) (first verdict $verdict)"
