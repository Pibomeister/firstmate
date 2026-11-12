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
#   startup, new            full digest - this process has not taken the helm
#   clear, compact          `--reemit` digest only when this lock owner recorded
#                           a completed full startup; otherwise a full digest,
#                           so a startup killed mid-sweep is finished first.
#                           A completed owner's clear or compact also writes
#                           state/.context-epoch, and a Claude auto compact with
#                           open work starts one detached bin/fm-resume-doorbell.sh
#                           (FM_RESUME_DOORBELL=0 disables it; docs/sessionstart-nudge.md)
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

# The payload's transcript_path, parsed the same quote-split way as `source`.
TRANSCRIPT=$(printf '%s' "${PAYLOAD:-}" | awk '
  BEGIN { RS = "\"" }
  seen == 2 { print; exit }
  seen == 1 && $0 ~ /^[[:space:]]*:[[:space:]]*$/ { seen = 2; next }
  seen == 1 { seen = 0 }
  $0 == "transcript_path" { seen = 1 }
')

# A compact or clear by the completed lock owner starts a new context. Record
# it as state/.context-epoch so a Stop-hook claim taken before it stops
# deferring later Stops (fm_autoarm_claim_open in bin/fm-wake-lib.sh).
record_context_epoch() {
  local tmp lock_pid
  lock_pid=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
  tmp=$(mktemp "$STATE/.context-epoch.XXXXXX" 2>/dev/null) || return 0
  if printf 'source=%s\nlock_pid=%s\nat=%s\n' "$SOURCE" "$lock_pid" "$(date +%s)" > "$tmp" \
    && mv -f "$tmp" "$STATE/.context-epoch"; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 0
}

# Open supervision work the resumed session must pick up: needed supervision,
# a pending wake row, or an open captain order.
resume_work_open() {
  local data order
  # shellcheck source=bin/fm-supervision-lib.sh
  . "$SCRIPT_DIR/fm-supervision-lib.sh" || return 1
  fm_supervision_status "$STATE"
  [ "$FM_SUP_NEEDED" = true ] && return 0
  [ "$FM_SUP_QUEUE_PENDING" = true ] && return 0
  data=${FM_DATA_OVERRIDE:-$FM_HOME/data}
  for order in "$data"/orders/pending/*.order "$data"/orders/acked/*.order; do
    [ -e "$order" ] && return 0
  done
  return 1
}

# An idle Claude auto compaction re-emits context but starts no turn, so a
# primary with open work would sit idle. Start one detached, model-free resume
# doorbell (bin/fm-resume-doorbell.sh) that types a fixed resume line only into
# a provably idle session with an empty composer. Only a Claude auto
# compaction qualifies: a manual /compact (including the supervision host's
# warm compact) has someone at the keyboard, and other harnesses deliver their
# own post-compaction message. FM_RESUME_DOORBELL=0 turns it off. Test seam,
# honoured only with FM_TEST_SEAM=1: FM_RESUME_DOORBELL_BIN replaces the launched
# program and FM_RESUME_DOORBELL_TEST_HARNESS pins the resolved harness.
# Prints the doorbell program when this open qualifies, else nothing.
resume_doorbell_bin() {
  local bin harness
  [ "${FM_RESUME_DOORBELL:-1}" != 0 ] || return 0
  [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  [ "$(grep -F 'compact_boundary' "$TRANSCRIPT" 2>/dev/null \
    | jq -Rr 'fromjson? | select(.type == "system" and .subtype == "compact_boundary") | .compactMetadata.trigger // empty' 2>/dev/null \
    | tail -n 1)" = auto ] || return 0
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_RESUME_DOORBELL_TEST_HARNESS:-}" ]; then
    harness=$FM_RESUME_DOORBELL_TEST_HARNESS
  else
    harness=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null) || harness=
  fi
  [ "$harness" = claude ] || return 0
  resume_work_open || return 0
  bin="$SCRIPT_DIR/fm-resume-doorbell.sh"
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_RESUME_DOORBELL_BIN:-}" ]; then
    bin=$FM_RESUME_DOORBELL_BIN
  fi
  [ -x "$bin" ] || return 0
  printf '%s\n' "$bin"
}

launch_resume_doorbell() {  # <program>
  local bin=$1
  # Detached from the hook: its own process group, stdio away from the hook's
  # pipes, so the SessionStart hook returns at once.
  (
    set -m 2>/dev/null || true
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      nohup "$bin" --source compact --transcript "$TRANSCRIPT" </dev/null >/dev/null 2>&1 &
  ) || true
  return 0
}

case "$SOURCE" in
  resume|reload|fork)
    if fm_session_lock_owned_by_self "$STATE"; then
      FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-order.sh" claim-handle >/dev/null 2>&1 || true
    fi
    exec "$SCRIPT_DIR/fm-sessionstart-nudge.sh"
    ;;
  clear|compact)
    if session_start_completed; then
      record_context_epoch
      # Decide before the re-emit: its wake drain may move the queued rows
      # that prove open work.
      DOORBELL_BIN=
      [ "$SOURCE" != compact ] || DOORBELL_BIN=$(resume_doorbell_bin)
      "$SCRIPT_DIR/fm-session-start.sh" --reemit --source "$SOURCE" || true
      [ -z "$DOORBELL_BIN" ] || launch_resume_doorbell "$DOORBELL_BIN"
    else
      "$SCRIPT_DIR/fm-session-start.sh" --source "$SOURCE" || true
    fi
    ;;
  *)
    "$SCRIPT_DIR/fm-session-start.sh" --source "$SOURCE" || true
    ;;
esac
exit 0
