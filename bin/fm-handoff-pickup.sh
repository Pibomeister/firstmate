#!/usr/bin/env bash
# fm-handoff-pickup.sh - finish a primary handoff without an external exit.
#
# bin/fm-handoff-launch.sh transfers the lock by acknowledgement and does
# not start this script. This script is the successor command when a launch
# record names the successor before the lock moves and the predecessor is
# still the lock holder. A successor that only waits then never takes the
# lock. This script is the single owner of that completion:
#   1. confirm the handoff document's sha256 and stop on a mismatch;
#   2. wait until state/.handoff-successor names this successor and that
#      handoff document;
#   3. end the predecessor only when its lock pid, process start time, and
#      harness shape are still the instance read before the signal, checked
#      again immediately before TERM and again before KILL;
#   4. take the session lock with bin/fm-lock.sh only after that instance
#      is gone, then exec claude in this same process so the lock pid is
#      the successor session.
# The session lock stays the single supervision owner. This script never
# signals a pid whose start time changed, a process that is not a harness,
# or its own ancestor. A primary has no task endpoint, so this verified
# exit is the lock identity rather than bin/fm-control.sh.
#
# The process re-execs through a temporary bash symlink named claude before
# it takes the lock. The session lock anchor has to be a harness-shaped
# process, and exec into the real claude binary keeps that pid. The symlink
# is removed before the lock call. Both platforms' harness matchers accept
# it: the command path's basename is claude.
#
# Test seam, honoured only with FM_TEST_SEAM=1:
#   FM_HANDOFF_PICKUP_RECORD_WAIT_SECS  bound waiting for the launch record
#   FM_HANDOFF_PICKUP_GRACE_SECS        pause after the record is visible
#   FM_HANDOFF_PICKUP_DEATH_WAIT_SECS   bound waiting for the predecessor
#   FM_HANDOFF_PICKUP_NO_EXEC=1         hold the lock in this process instead
#                                       of execing claude
#
# Usage: fm-handoff-pickup.sh <handoff-file> <sha256> <bypass|auto>
#        fm-handoff-pickup.sh -h|--help
set -u

case "${1:-}" in
  -h | --help) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

if [ "${1:-}" != --ready ]; then
  ready=$(mktemp -d "${TMPDIR:-/tmp}/fm-handoff-pickup.XXXXXX") || {
    printf 'error: cannot create a successor identity directory\n' >&2
    exit 1
  }
  if ! ln -s /bin/bash "$ready/claude"; then
    rm -rf "$ready"
    printf 'error: cannot prepare the successor harness identity\n' >&2
    exit 1
  fi
  exec "$ready/claude" "$0" --ready "$ready" "$@"
fi

ready_dir=$2
shift 2
case "$(basename "$ready_dir")" in
  fm-handoff-pickup.*) rm -rf "$ready_dir" ;;
  *)
    printf 'error: refusing to clear an unexpected identity directory\n' >&2
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

# A successor must not inherit the predecessor's session identity and then
# confirm that session's lock as its own.
unset CLAUDE_PID CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID CODEX_SESSION_ID

[ $# -eq 3 ] || die "usage: fm-handoff-pickup.sh <handoff-file> <sha256> <bypass|auto>"
HANDOFF=$1
SHA=$2
MODE=$3
case "$SHA" in
  *[!0-9a-f]* | '') die "handoff sha256 is not 64 hex characters" ;;
esac
[ "${#SHA}" -eq 64 ] || die "handoff sha256 is not 64 hex characters"
case "$MODE" in
  bypass | auto) ;;
  *) die "permission mode must be bypass or auto" ;;
esac
[ -f "$HANDOFF" ] && [ -r "$HANDOFF" ] || die "handoff document is not a readable file: $HANDOFF"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
if fm_root_is_secondmate_home "$FM_HOME"; then
  die "this is a second mate home; a second mate asks its parent to relaunch it and never launches its own successor"
fi

if command -v sha256sum >/dev/null 2>&1; then
  got=$(sha256sum "$HANDOFF" 2>/dev/null | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  got=$(shasum -a 256 "$HANDOFF" 2>/dev/null | awk '{print $1}')
else
  die "neither sha256sum nor shasum is available; the successor could not confirm the handoff hash"
fi
[ "$got" = "$SHA" ] || die "handoff sha256 does not match $HANDOFF"

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

bound() { # <env-name> <default>
  local name=$1 def=$2 val
  if [ "${FM_TEST_SEAM:-}" != 1 ]; then
    printf '%s' "$def"
    return 0
  fi
  val=${!name:-}
  case "$val" in
    '' | *[!0-9]*) printf '%s' "$def" ;;
    *) printf '%s' "$val" ;;
  esac
}

RECORD_WAIT=$(bound FM_HANDOFF_PICKUP_RECORD_WAIT_SECS 90)
GRACE=$(bound FM_HANDOFF_PICKUP_GRACE_SECS 2)
DEATH_WAIT=$(bound FM_HANDOFF_PICKUP_DEATH_WAIT_SECS 10)

[ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] || die "no session lock at $STATE/.lock"
PRED_PID=$(head -n 1 "$STATE/.lock" 2>/dev/null | tr -cd '0-9')
case "$PRED_PID" in
  '' | *[!0-9]* | 0 | 1) die "state/.lock names no predecessor pid" ;;
esac

process_state() { # <pid>
  ps -o stat= -p "$1" 2>/dev/null | awk 'NR == 1 { print $1 }'
}

# A zombie still answers kill -0. Treat it as gone so the lock call does
# not read the dead predecessor as a live harness.
alive_same_start() {
  local now state
  [ -n "${PRED_START:-}" ] || return 1
  state=$(process_state "$PRED_PID")
  [ -n "$state" ] || return 1
  case "$state" in
    Z*) return 1 ;;
  esac
  kill -0 "$PRED_PID" 2>/dev/null || return 1
  now=$(fm_session_process_start "$PRED_PID" 2>/dev/null) || return 1
  [ "$now" = "$PRED_START" ]
}

is_self_or_ancestor() { # <pid>
  local target=$1 pid=$$
  [ "$pid" = "$target" ] && return 0
  local _hop
  for _hop in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || return 1
    case "$pid" in '' | 0 | 1) return 1 ;; esac
    [ "$pid" = "$target" ] && return 0
  done
  return 1
}

side_pid=$(sed -n 's/^anchor_pid=//p' "$STATE/.lock-session" 2>/dev/null | tail -1 || true)
side_start=$(sed -n 's/^anchor_start=//p' "$STATE/.lock-session" 2>/dev/null | tail -1 || true)
PRED_START=
if kill -0 "$PRED_PID" 2>/dev/null; then
  PRED_START=$(fm_session_process_start "$PRED_PID" 2>/dev/null) || PRED_START=
  [ -n "$PRED_START" ] || die "cannot read the predecessor's process start time"
  if [ -n "$side_start" ] && [ "$side_pid" = "$PRED_PID" ] && [ "$side_start" != "$PRED_START" ]; then
    die "predecessor lock identity does not match the live process (pid $PRED_PID); refusing to signal"
  fi
  fm_harness_pid_alive "$PRED_PID" \
    || die "predecessor pid $PRED_PID is alive but not a harness session; refusing to signal or take the lock"
fi

record_names_us() {
  local recorded_handoff recorded_pid args
  [ -f "$STATE/.handoff-successor" ] && [ ! -L "$STATE/.handoff-successor" ] || return 1
  recorded_handoff=$(sed -n 's/^handoff=//p' "$STATE/.handoff-successor" | tail -1)
  recorded_pid=$(sed -n 's/^pid=//p' "$STATE/.handoff-successor" | tail -1)
  [ "$recorded_handoff" = "$HANDOFF" ] || return 1
  case "$recorded_pid" in '' | *[!0-9]*) return 1 ;; esac
  [ "$recorded_pid" != "$PRED_PID" ] || return 1
  kill -0 "$recorded_pid" 2>/dev/null || return 1
  is_self_or_ancestor "$recorded_pid" || return 1
  args=$(ps -o args= -p "$recorded_pid" 2>/dev/null) || return 1
  printf '%s\n' "$args" | grep -F -q -e "$HANDOFF"
}

deadline=$((SECONDS + RECORD_WAIT))
while ! record_names_us; do
  [ "$SECONDS" -le "$deadline" ] || die "handoff successor record did not name this successor within ${RECORD_WAIT}s"
  sleep 0.2
done

if [ "$GRACE" -gt 0 ]; then
  sleep "$GRACE"
fi

# The launch record is complete and this successor is the process it names.
# Re-read the predecessor immediately before each signal.
if alive_same_start; then
  fm_harness_pid_alive "$PRED_PID" \
    || die "predecessor pid $PRED_PID is alive but not a harness session; refusing to signal or take the lock"
  if is_self_or_ancestor "$PRED_PID"; then
    die "predecessor pid $PRED_PID is this successor or its ancestor; refusing to signal it"
  fi
  alive_same_start \
    || die "predecessor changed identity before exit; refusing to signal the new process"
  kill -TERM "$PRED_PID" 2>/dev/null || true
  ticks=$((DEATH_WAIT * 5))
  waited=0
  while alive_same_start; do
    [ "$waited" -lt "$ticks" ] || break
    sleep 0.2
    waited=$((waited + 1))
  done
  if alive_same_start; then
    fm_harness_pid_alive "$PRED_PID" \
      || die "predecessor changed identity during exit; refusing to signal the new process"
    alive_same_start \
      || die "predecessor changed identity during exit; refusing to signal the new process"
    kill -KILL "$PRED_PID" 2>/dev/null || true
    waited=0
    while alive_same_start; do
      [ "$waited" -lt "$ticks" ] || die "predecessor pid $PRED_PID did not exit within ${DEATH_WAIT}s"
      sleep 0.2
      waited=$((waited + 1))
    done
  fi
fi

if alive_same_start; then
  die "predecessor pid $PRED_PID is still the lock holder; refusing to take the session lock"
fi

lock_out=$("$SCRIPT_DIR/fm-lock.sh" 2>&1) || die "cannot take the session lock: $lock_out"
lock_pid=$(head -n 1 "$STATE/.lock" 2>/dev/null | tr -cd '0-9')
[ "$lock_pid" = "$$" ] || die "session lock names pid $lock_pid after acquisition, not this successor $$"

if [ "${FM_TEST_SEAM:-}" = 1 ] && [ "${FM_HANDOFF_PICKUP_NO_EXEC:-}" = 1 ]; then
  printf 'handoff pickup: lock held pid=%s\n' "$$"
  sleep 3600 &
  holder=$!
  trap 'kill "$holder" 2>/dev/null || true; exit 0' TERM INT
  wait "$holder"
fi

real=$(command -v claude 2>/dev/null) || die "the lowercase claude binary is not on PATH"
[ -n "$real" ] || die "the lowercase claude binary is not on PATH"
prompt="Firstmate handoff successor for home $FM_HOME. The handoff document is $HANDOFF with sha256 $SHA. The hash was confirmed. The predecessor session has exited and this process holds the session lock. Run FM_HOME=$FM_HOME $FM_ROOT/bin/fm-session-start.sh once to load the session digest, then continue from the handoff document."
case "$MODE" in
  auto) exec "$real" --permission-mode auto "$prompt" ;;
  bypass) exec "$real" --dangerously-skip-permissions "$prompt" ;;
esac
