#!/usr/bin/env bash
# fm-handoff-launch.sh - launch the successor primary session for a handoff.
#
# The Claude handoff Stop gate (bin/fm-handoff-trigger.sh) refuses to end a
# handing-off primary's turn until state/.handoff-successor names a live
# successor pid. This script is the firstmate-owned launcher that creates
# that successor, so a handoff turn ends with a successor under way instead
# of waiting for a manual launch (issue 116).
#
# Given a written handoff document, it:
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
#   3. launches the successor in a NEW terminal on that backend with a
#      prompt naming the handoff path and the document's sha256 (and its
#      sha8 prefix): confirm the hash, wait until the predecessor harness
#      pid (line 1 of state/.lock) is dead, then run
#      bin/fm-session-start.sh to take the session lock;
#   4. waits for the new harness pid to appear (a live process whose
#      command line carries the handoff path and was not there before the
#      launch), then writes state/.handoff-successor as pid=<pid> and
#      handoff=<path> so the Stop gate passes. It verifies only that live
#      successor pid; the successor confirms the handoff sha256 at pickup
#      and stops on a mismatch.
#
# On tmux the successor opens in the primary's own tmux session when the
# launcher runs inside one, otherwise in firstmate-<home basename>, as
# bin/fm-watchdog.sh's restart launch names it.
#
# It never kills, interrupts, or signals the current session beyond a
# kill -0 liveness read; the predecessor is ended by the captain, a
# leash or operator /exit, or the watchdog restart path, and the
# successor waits for that pid to die before session start. A second
# mate home is refused: a second mate asks its parent to relaunch it.
# When the successor never appears, nothing is recorded and the launch
# fails loudly, leaving the Stop gate blocked rather than satisfied.
#
# Test seam, honoured only with FM_TEST_SEAM=1: FM_HANDOFF_TEST_HARNESS
# pins the resolved primary harness, and
# FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS bounds the successor wait.
#
# Usage: fm-handoff-launch.sh <handoff-file>
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

# The harness must be determined, not guessed: the launcher runs as the
# primary's own subprocess, so its harness is the primary's.
if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_HANDOFF_TEST_HARNESS:-}" ]; then
  HARNESS=$FM_HANDOFF_TEST_HARNESS
else
  HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null) || HARNESS=''
fi
case "$HARNESS" in
  claude) ;;
  '') die "cannot determine the current primary's harness; refusing to launch a successor" ;;
  *) die "the current primary runs harness '$HARNESS', not claude; the handoff successor launcher serves a claude primary only" ;;
esac
command -v claude >/dev/null 2>&1 || die "the lowercase claude binary is not on PATH; refusing to launch a successor"

# The backend must be the home's recorded one, with a supported launcher.
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
BACKEND=$(fm_backend_name 2>/dev/null) || BACKEND=''
[ -n "$BACKEND" ] || die "cannot determine the home's recorded backend; refusing to launch a successor"
case "$BACKEND" in
  orca) command -v orca >/dev/null 2>&1 || die "backend orca is recorded but the orca binary is not on PATH" ;;
  tmux) command -v tmux >/dev/null 2>&1 || die "backend tmux is recorded but the tmux binary is not on PATH" ;;
  *)
    if fm_backend_is_known "$BACKEND"; then
      die "no successor launcher for backend '$BACKEND' yet (supported: orca, tmux); refusing to guess another backend"
    fi
    die "backend '$BACKEND' is not a known backend; refusing to launch a successor"
    ;;
esac

# The predecessor pid anchors the successor's wait and must be real.
[ -f "$STATE/.lock" ] || die "no session lock at $STATE/.lock; cannot name the predecessor pid the successor must wait for"
PRED_PID=$(head -n 1 "$STATE/.lock" 2>/dev/null | tr -cd '0-9')
[ -n "$PRED_PID" ] || die "state/.lock names no predecessor pid; refusing to launch a successor"
kill -0 "$PRED_PID" 2>/dev/null || die "predecessor pid $PRED_PID from state/.lock is not alive; refusing to launch a successor"

# Permission posture: the same flag the home's config gives a claude launch.
CLAUDE_PERMISSION_MODE=bypass
if [ -e "$CONFIG/claude-permission-mode" ]; then
  [ -f "$CONFIG/claude-permission-mode" ] && [ -r "$CONFIG/claude-permission-mode" ] \
    || die "config/claude-permission-mode must be a readable regular file holding one of: bypass, auto"
  CLAUDE_PERMISSION_MODE=$(tr -d '[:space:]' <"$CONFIG/claude-permission-mode" || true)
  case "$CLAUDE_PERMISSION_MODE" in
    bypass | auto) ;;
    *) die "config/claude-permission-mode holds '$CLAUDE_PERMISSION_MODE'; accepted values are: bypass (--dangerously-skip-permissions, the default when the file is absent), auto (--permission-mode auto)" ;;
  esac
fi
case "$CLAUDE_PERMISSION_MODE" in
  auto) PERM_FLAG='--permission-mode auto' ;;
  *) PERM_FLAG='--dangerously-skip-permissions' ;;
esac

# Hash confirmation material for the successor prompt.
if command -v sha256sum >/dev/null 2>&1; then
  SHA256=$(sha256sum "$HANDOFF" 2>/dev/null | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  SHA256=$(shasum -a 256 "$HANDOFF" 2>/dev/null | awk '{print $1}')
else
  die "neither sha256sum nor shasum is available; the successor could not confirm the handoff hash"
fi
case "$SHA256" in
  *[!0-9a-f]* | '') die "could not hash the handoff document: $HANDOFF" ;;
esac
[ "${#SHA256}" -eq 64 ] || die "could not hash the handoff document: $HANDOFF"
SHA8=${SHA256:0:8}

LAUNCH_RECORD="$STATE/.handoff-successor"

PROMPT="Firstmate handoff successor for home $FM_HOME. The handoff document is $HANDOFF with sha256 $SHA256 (sha8 $SHA8). Confirm that hash before acting (sha256sum or shasum -a 256 on the document) and stop if it does not match. Wait until predecessor harness pid $PRED_PID is dead, then run FM_HOME=$FM_HOME $FM_ROOT/bin/fm-session-start.sh to take the session lock and continue from the handoff document."
SUCCESSOR_CMD="claude $PERM_FLAG $(printf '%q' "$PROMPT")"

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

case "$BACKEND" in
  orca)
    orca terminal create --worktree "path:$FM_HOME" --title "firstmate captain" \
      --command "$SUCCESSOR_CMD" --json >/dev/null 2>&1 \
      || die "orca failed to create the successor terminal; no successor was launched"
    ;;
  tmux)
    SESS=''
    [ -z "${TMUX:-}" ] || SESS=$(tmux display-message -p '#{session_name}' 2>/dev/null) || SESS=''
    SESS=${SESS:-firstmate-$(basename "$FM_HOME")}
    if tmux has-session -t "=$SESS" >/dev/null 2>&1; then
      tmux new-window -d -t "=$SESS:" -c "$FM_HOME" -n firstmate "$SUCCESSOR_CMD" >/dev/null 2>&1 \
        || die "tmux failed to open the successor window; no successor was launched"
    else
      tmux new-session -d -s "$SESS" -c "$FM_HOME" -n firstmate "$SUCCESSOR_CMD" >/dev/null 2>&1 \
        || die "tmux failed to create the successor session; no successor was launched"
    fi
    ;;
esac

TIMEOUT=60
if [ "${FM_TEST_SEAM:-}" = 1 ]; then
  case "${FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS:-}" in
    '' | *[!0-9]*) ;;
    *) TIMEOUT=$FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS ;;
  esac
fi

SUCC_PID=''
waited=0
while [ "$waited" -le "$TIMEOUT" ]; do
  # The newest matching pid wins: a terminal may start a shell wrapper
  # first, and the harness it launches carries the higher pid.
  for pid in $(pids_carrying_handoff); do
    case "$BASELINE" in *" $pid "*) continue ;; esac
    [ "$pid" != "$$" ] || continue
    [ "$pid" != "$PRED_PID" ] || continue
    if kill -0 "$pid" 2>/dev/null && [ "$pid" -gt "${SUCC_PID:-0}" ]; then
      SUCC_PID=$pid
    fi
  done
  [ -n "$SUCC_PID" ] && break
  [ "$waited" -lt "$TIMEOUT" ] || break
  sleep 1
  waited=$((waited + 1))
done
[ -n "$SUCC_PID" ] || die "the successor never appeared within ${TIMEOUT}s on backend $BACKEND; state/.handoff-successor left unwritten"

tmp=$(mktemp "$STATE/.handoff-successor.XXXXXX") || die "cannot stage the successor record in $STATE"
printf 'pid=%s\nhandoff=%s\n' "$SUCC_PID" "$HANDOFF" > "$tmp" || { rm -f "$tmp"; die "cannot write the successor record in $STATE"; }
mv "$tmp" "$LAUNCH_RECORD" || { rm -f "$tmp"; die "cannot record the successor in $LAUNCH_RECORD"; }
printf 'successor launched: pid=%s backend=%s handoff=%s sha8=%s\n' "$SUCC_PID" "$BACKEND" "$HANDOFF" "$SHA8"
