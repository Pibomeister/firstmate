#!/usr/bin/env bash
# Session-open entry point for harnesses that RUN the digest instead of asking
# the agent to. It is the one command those harnesses' session-open adapters
# invoke, and it decides, from the session-open source, whether this open needs
# the full digest, a context re-emit, or nothing at all.
#
# Why running beats nudging: bin/fm-sessionstart-nudge.sh can only ASK the agent
# to take the helm, and an agent can defer that, including when a first-command
# skill has its own read-only path. When the native adapter injects this
# command's stdout into model context, running the digest here removes that
# discretion - the helm is taken before the model's first turn, whatever the
# first turn is.
#
# Usage: fm-sessionstart-run.sh [--source <source>] [--pi-prerequisite]
#   --source  The harness's own session-open source. When omitted, the source is
#             read from a Claude/Codex-shaped JSON hook payload on stdin
#             (the `source` field). An unreadable or unrecognized source is
#             treated as `startup`, because taking the helm redundantly is
#             cheap and idempotent while not taking it is the whole bug.
#   --pi-prerequisite
#             Internal Pi extension mode. An intentional gate/scope stand-down
#             exits 3 so provider preflight can distinguish it from an eligible
#             native attempt that settled without output. Every ordinary hook
#             invocation retains the always-zero compatibility contract below.
#
# Source routing (see docs/sessionstart-nudge.md for the per-harness names):
#   startup, new            full digest - this process has not taken the helm,
#                           except that a handoff successor opened while its
#                           predecessor still holds the lock gets a short notice
#                           instead (handoff_successor_waits below)
#   clear, compact          `--reemit` digest only when this lock owner recorded
#                           a completed full startup; otherwise a full digest,
#                           so a startup killed mid-sweep is finished first. A
#                           Claude compact re-emit is the short re-entry card
#                           (bin/fm-session-start.sh owns it)
#   resume, reload, fork    delegate to the nudge wrapper. Prior context is
#                           restored on these, so re-running is redundant when
#                           this process still holds the lock (the nudge stays
#                           silent) and a plain instruction is enough when a new
#                           process resumed an old session (the nudge fires).
#
# Every ordinary transport path exits 0, exactly like the nudge wrapper: a
# Claude SessionStart exit 2 blocks session initialization, so a failed session
# start must reach the agent as digest text it can act on, never as a refusal to
# open the session. The internal Pi prerequisite's silent exit 3 never reaches a
# harness hook; it only distinguishes intentional ineligibility before provider
# preflight. A lock another live session holds and a truncated digest are
# reported inside the digest, while broken GitHub auth arrives through the
# deferred network result inline or as a wake, for exactly that reason.
# A fresh clone has no gitignored state dir yet; a root that otherwise
# qualifies as primary gets one created here before the scope check runs, so
# the first session takes the helm without a manual `mkdir state`.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
COMPLETION_FILE="$STATE/.session-start-complete"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"

SOURCE=
PI_PREREQUISITE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --source)
      SOURCE=${2:-}
      # A bare trailing --source leaves the source empty rather than aborting,
      # so a malformed call still falls through to taking the helm.
      if [ $# -ge 2 ]; then shift 2; else shift; fi
      ;;
    --source=*) SOURCE=${1#--source=}; shift ;;
    --pi-prerequisite) PI_PREREQUISITE=1; shift ;;
    *) shift ;;
  esac
done

stand_down() {
  if [ "$PI_PREREQUISITE" = 1 ]; then
    exit 3
  fi
  exit 0
}

# The same two eligibility owners the nudge wrapper uses, so a no-mistakes gate
# agent and an unmarked task worktree can never run a session start for a home
# they do not own. Pi's preflight-only status preserves that intentional silence
# without mistaking it for a failed eligible attempt that needs the manual nudge.
fm_is_gate_agent "$FM_ROOT" && stand_down
if [ ! -d "$STATE" ] && fm_primary_root_matches "$FM_ROOT"; then
  if ! MKDIR_ERR=$(mkdir -p "$STATE" 2>&1); then
    printf 'fm-sessionstart-run: startup could not create the state directory %s: %s\n' \
      "$STATE" "${MKDIR_ERR##*: }" >&2
    stand_down
  fi
fi
fm_primary_scope_matches "$FM_ROOT" "$STATE" || stand_down

session_start_completed() {
  local lock_pid completion_pid
  [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] || return 1
  [ -f "$COMPLETION_FILE" ] && [ ! -L "$COMPLETION_FILE" ] || return 1
  fm_session_lock_owned_by_self "$STATE" || return 1
  lock_pid=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  completion_pid=$(cat "$COMPLETION_FILE" 2>/dev/null) || return 1
  fm_session_pid_valid "$lock_pid" || return 1
  [ "$completion_pid" = "$lock_pid" ]
}

# handoff_successor_waits: a handoff successor opens while its predecessor still
# holds the session lock (bin/fm-handoff-launch.sh launches it with
# FM_HANDOFF_PREDECESSOR_PID). A startup digest now could only run lock-refused
# and read-only, so print a short notice instead and leave the one real session
# start to the successor's launch prompt, after the predecessor has ended.
handoff_successor_waits() {
  local pred=${FM_HANDOFF_PREDECESSOR_PID:-} lock_pid
  case "$pred" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pred" -gt 1 ] || return 1
  { IFS= read -r lock_pid < "$STATE/.lock"; } 2>/dev/null || return 1
  [ "$lock_pid" = "$pred" ] || return 1
  fm_harness_pid_alive "$pred" || return 1
  ! fm_session_lock_owned_by_self "$STATE" || return 1
  printf 'Firstmate handoff successor: the predecessor session, harness pid %s, still holds this home'"'"'s session lock, so this open skips the startup digest, which could only run read-only now.\n' "$pred"
  printf 'Follow your launch prompt: confirm the handoff document hash, wait with FM_HOME=%s %s/bin/fm-handoff-launch.sh --await-predecessor %s, then run FM_HOME=%s %s/bin/fm-session-start.sh once.\n' \
    "$FM_HOME" "$FM_ROOT" "$pred" "$FM_HOME" "$FM_ROOT"
}

if [ -z "$SOURCE" ] && [ ! -t 0 ]; then
  # Claude and Codex both deliver a JSON SessionStart payload on stdin whose
  # `source` field carries startup|resume|clear|compact. Parsed without jq so a
  # host missing it still gets correct routing rather than silent full runs.
  # A terminal stdin is skipped outright: a hook always pipes its payload, and
  # an operator running this by hand must not be left waiting on a read.
  # Splitting on the quote character finds the FIRST "source" key and its value
  # without depending on greedy-regex luck, and it cannot mistake a string VALUE
  # of "source" for the key, because only a key is followed by a bare colon.
  PAYLOAD=$(cat 2>/dev/null || true)
  # Cursor loads the tracked Claude settings as well as its own registration,
  # so a Cursor-delivered payload here is the duplicate: bin/fm-sessionstart-
  # cursor.sh already owns that session open and calls this wrapper with an
  # explicit --source and no payload. Running twice would take the helm twice
  # and repeat every startup sweep.
  if fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    exit 0
  fi
  SOURCE=$(printf '%s' "$PAYLOAD" | awk '
    BEGIN { RS = "\"" }
    seen == 2 { print; exit }
    seen == 1 && $0 ~ /^[[:space:]]*:[[:space:]]*$/ { seen = 2; next }
    seen == 1 { seen = 0 }
    $0 == "source" { seen = 1 }
  ')
fi

case "$SOURCE" in
  resume|reload|fork)
    if fm_session_lock_owned_by_self "$STATE"; then
      FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-order.sh" claim-handle >/dev/null 2>&1 || true
    fi
    exec "$SCRIPT_DIR/fm-sessionstart-nudge.sh"
    ;;
  clear|compact)
    if session_start_completed; then
      "$SCRIPT_DIR/fm-session-start.sh" --reemit --source "$SOURCE" || true
    else
      "$SCRIPT_DIR/fm-session-start.sh" --source "$SOURCE" || true
    fi
    ;;
  *)
    if handoff_successor_waits; then
      exit 0
    fi
    "$SCRIPT_DIR/fm-session-start.sh" --source "$SOURCE" || true
    ;;
esac
exit 0
