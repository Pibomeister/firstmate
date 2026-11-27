#!/usr/bin/env bash
# fm-handoff-close.sh <nonce> - close the predecessor's terminal after a
# committed verified handoff. bin/fm-handoff-ack.sh runs it once, after
# fm-lock.sh reports handoff_takeover=verified_transfer for that nonce.
# FM_HOME must name the handoff home.
#
# It acts only on data/handoff-ack-<nonce>.json, which the ack wrote from the
# pending claim before the transfer: the predecessor pid and start, and the
# predecessor endpoint the launcher recorded from state/.lock-session while it
# held the claim lock. It closes only that exact endpoint, and only when all of
# these hold, read fresh:
#   - the transfer committed: state/.lock names the ack's successor, the ack is
#     valid for that pid (fm_handoff_ack_valid), and the lock sidecar's anchor
#     instance matches;
#   - the predecessor's launcher completed the handoff: it wrote
#     state/.handoff-successor for this nonce and successor, and no
#     state/.handoff-launch-failed record names this nonce, so a handoff the
#     launcher reported failed or unresolved is never closed even when a late
#     ack later commits it;
#   - the recorded endpoint is concrete, is not the successor's own terminal,
#     and names a backend with a supported close (tmux or orca);
#   - the predecessor is the same live harness instance the claim recorded;
#   - the backend proves the endpoint hosts it: the predecessor pid is the
#     endpoint's root process or descends from it, and the successor does not.
#     On tmux the recorded target is first resolved once to its exact pane id
#     (#{pane_id}), and that pane id alone is proven, closed, and verified, so
#     a window-style target can never move the close onto another pane; a
#     target that does not resolve to one live pane id, or a recorded pane id
#     that resolves to a different one, is endpoint_unproven, and a resolved
#     pane that is the successor's own terminal is own_endpoint.
#     On tmux the root is the pane's #{pane_pid}. On Orca the terminal must be
#     a connected local terminal of this home, and the root is its pty session
#     process from Orca's own process sweep.
# It waits up to 15 seconds for that completion record before probing the
# endpoint, then runs tmux kill-pane or Orca terminal close, and waits up to 10 seconds for the
# endpoint and the predecessor instance to be gone.
#
# It emits exactly one HANDOFF v1 event (bin/fm-handoff-lib.sh owns the wire
# format) with nonce=<nonce>, pid=<predecessor pid> and
# handle=<backend>:<terminal> (or none):
#   predecessor_closed reason=closed           closed and proven gone
#   predecessor_close_failed reason=<token>    closed, but endpoint_present or
#                                              predecessor_present remained
#   predecessor_close_refused reason=<token>   nothing was closed
# Refusal tokens: invalid_nonce, invalid_ack, not_committed, no_endpoint,
# unsupported_backend, own_endpoint, predecessor_exited, backend_unavailable,
# endpoint_unproven, successor_in_endpoint, launch_failed, not_completed.
# Exit 0 after predecessor_closed, 1 after any other event.
# Test-only: FM_TEST_SEAM=1 enables FM_HANDOFF_CLOSE_RECORD_WAIT_SECS and
# FM_HANDOFF_CLOSE_VERIFY_SECS.
# Usage: fm-handoff-close.sh <nonce> | --help
set -eu
umask 077
case "${1:-}" in
  -h|--help) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:?FM_HOME must name the handoff home}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-handoff-lib.sh
. "$SCRIPT_DIR/fm-handoff-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
RECORD_WAIT=15 VERIFY_WAIT=10
if [ "${FM_TEST_SEAM:-}" = 1 ]; then
  case "${FM_HANDOFF_CLOSE_RECORD_WAIT_SECS:-}" in ''|*[!0-9]*) ;; *) RECORD_WAIT=$FM_HANDOFF_CLOSE_RECORD_WAIT_SECS ;; esac
  case "${FM_HANDOFF_CLOSE_VERIFY_SECS:-}" in ''|*[!0-9]*) ;; *) VERIFY_WAIT=$FM_HANDOFF_CLOSE_VERIFY_SECS ;; esac
fi
nonce=${1:-}
pred=0 endpoint=none
finish() { # <event> <reason>
  fm_handoff_event "$1" "$nonce" 0 "$pred" "$endpoint" "$2"
  if [ "$1" = predecessor_closed ]; then exit 0; fi
  exit 1
}
refuse() { finish predecessor_close_refused "$1"; }
case "$nonce" in ''|*[!a-f0-9]*) refuse invalid_nonce ;; esac
ack="$FM_HOME/data/handoff-ack-$nonce.json"
[ -f "$ack" ] && [ ! -L "$ack" ] || refuse invalid_ack
fields=$(jq -er '[.harness_pid, .terminal_handle, .handoff, .sha256, .predecessor_pid, .predecessor_start,
  (.predecessor_backend // ""), (.predecessor_terminal // "")]
  | map(tostring) | if any(test("[\u001f\n\r]")) then error("unsafe") else join("\u001f") end' "$ack" 2>/dev/null) \
  || refuse invalid_ack
IFS=$'\x1f' read -r succ succ_handle doc sha pred pred_start backend terminal <<FIELDS
$fields
FIELDS
case "$pred" in ''|0|1|*[!0-9]*) pred=0; refuse invalid_ack ;; esac
case "$succ" in ''|0|1|*[!0-9]*) refuse invalid_ack ;; esac
[ -n "$pred_start" ] && [ "$pred" != "$succ" ] || refuse invalid_ack
case "$backend:$terminal" in
  *[!A-Za-z0-9_.:%-]*) ;;
  ?*:?*) endpoint="$backend:$terminal" ;;
esac

# The transfer must have committed to the acknowledged successor.
if ! { [ "$(cat "$STATE/.lock" 2>/dev/null)" = "$succ" ] \
  && fm_handoff_ack_valid "$nonce" "$doc" "$sha" "$succ" \
  && fm_session_lock_anchor_instance_matches "$STATE"; }; then
  refuse not_committed
fi

# The predecessor's launcher must itself conclude the handoff completed.
launch_failed() {
  [ -f "$STATE/.handoff-launch-failed" ] && grep -q " nonce=$nonce " "$STATE/.handoff-launch-failed" 2>/dev/null
}
completed() {
  [ -f "$STATE/.handoff-successor" ] && [ ! -L "$STATE/.handoff-successor" ] \
    && [ "$(sed -n 's/^nonce=//p' "$STATE/.handoff-successor" 2>/dev/null)" = "$nonce" ] \
    && [ "$(sed -n 's/^pid=//p' "$STATE/.handoff-successor" 2>/dev/null)" = "$succ" ]
}
end=$((SECONDS + RECORD_WAIT))
while :; do
  launch_failed && refuse launch_failed
  completed && break
  [ "$SECONDS" -lt "$end" ] || refuse not_completed
  sleep 0.2
done

[ "$endpoint" != none ] && [ "$terminal" != unknown ] || refuse no_endpoint
case "$backend" in tmux|orca) ;; *) refuse unsupported_backend ;; esac
[ "$terminal" != "$succ_handle" ] || refuse own_endpoint
current=$(fm_handoff_endpoint_handle 2>/dev/null) || current=
[ "$terminal" != "$current" ] || refuse own_endpoint

predecessor_live() {
  fm_harness_pid_alive "$pred" && [ "$(fm_session_process_start "$pred" 2>/dev/null)" = "$pred_start" ]
}
# 0 when <pid> is <root> or descends from it.
descends_from() { # <pid> <root>
  local p=$1 i=0
  while [ "$i" -lt 64 ]; do
    [ "$p" = "$2" ] && return 0
    case "$p" in ''|0|1|*[!0-9]*) return 1 ;; esac
    p=$(fm_ps_ppid "$p") || return 1
    i=$((i + 1))
  done
  return 1
}
predecessor_live || refuse predecessor_exited
command -v "$backend" >/dev/null 2>&1 || refuse backend_unavailable

# The exact endpoint every later probe and the close act on. tmux resolves a
# window or session target to whichever pane is active at each call, so the
# recorded target is pinned to one pane id here and never used again.
target=$terminal
if [ "$backend" = tmux ]; then
  target=$(fm_run_timed 5 tmux display-message -p -t "$terminal" '#{pane_id}' 2>/dev/null) || target=
  case "$target" in %*) ;; *) target= ;; esac
  case "${target#%}" in ''|*[!0-9]*) refuse endpoint_unproven ;; esac
  case "$terminal" in %*) [ "$target" = "$terminal" ] || refuse endpoint_unproven ;; esac
  [ "$target" != "$current" ] && [ "$target" != "$succ_handle" ] || refuse own_endpoint
fi

# The endpoint's root process, proven to belong to this endpoint.
endpoint_root() {
  local facts read connected host pty wtpath rc=0
  case "$backend" in
    tmux)
      fm_run_timed 5 tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null
      ;;
    orca)
      facts=$(fm_backend_orca_terminal_facts "$terminal") || return 1
      IFS=$'\x1f' read -r read connected _ host pty wtpath _ <<FACTS
$facts
FACTS
      [ "$read" = ok ] && [ "$connected" = true ] && [ "$host" = local ] || return 1
      [ -n "$wtpath" ] && [ "$(fm_backend_orca_physical_dir "$wtpath")" = "$(fm_backend_orca_physical_dir "$FM_HOME")" ] || return 1
      fm_backend_orca_session_pid "$pty" || rc=$?
      return "$rc"
      ;;
  esac
}
# 0 when the endpoint is proven gone.
endpoint_gone() {
  local facts out rc=0
  case "$backend" in
    tmux)
      # tmux answers a gone pane with exit 0 and an empty line, or reports it
      # missing; only an answer naming the pane, or no answer, keeps it present.
      out=$(fm_run_timed 5 tmux display-message -p -t "$target" '#{pane_id}' 2>&1) || rc=$?
      if [ "$rc" = 0 ]; then
        if printf '%s\n' "$out" | grep -Fqx -- "$target"; then return 1; fi
        return 0
      fi
      case "$out" in *"can't find"*|*"no server running"*|*"error connecting"*) return 0 ;; esac
      return 1
      ;;
    orca)
      facts=$(fm_backend_orca_terminal_facts "$terminal") || return 1
      case "$facts" in stale$'\x1f'*|ok$'\x1f'false$'\x1f'*) return 0 ;; esac
      return 1
      ;;
  esac
}
if [ "$backend" = orca ]; then
  # shellcheck source=bin/backends/orca.sh
  . "$SCRIPT_DIR/backends/orca.sh"
fi
root=$(endpoint_root) || refuse endpoint_unproven
case "$root" in ''|0|1|*[!0-9]*) refuse endpoint_unproven ;; esac
descends_from "$pred" "$root" || refuse endpoint_unproven
! descends_from "$succ" "$root" || refuse successor_in_endpoint

# Re-prove the commit and the endpoint immediately before the close.
[ "$(cat "$STATE/.lock" 2>/dev/null)" = "$succ" ] || refuse not_committed
launch_failed && refuse launch_failed
predecessor_live || refuse predecessor_exited
[ "$(endpoint_root 2>/dev/null)" = "$root" ] || refuse endpoint_unproven

case "$backend" in
  tmux) fm_run_timed 5 tmux kill-pane -t "$target" >/dev/null 2>&1 || true ;;
  orca) fm_backend_orca_kill "$terminal" || true ;;
esac
end=$((SECONDS + VERIFY_WAIT))
while :; do
  gone=1
  endpoint_gone || gone=0
  if [ "$gone" = 1 ] && ! predecessor_live; then finish predecessor_closed closed; fi
  if [ "$SECONDS" -ge "$end" ]; then
    [ "$gone" = 1 ] || finish predecessor_close_failed endpoint_present
    finish predecessor_close_failed predecessor_present
  fi
  sleep 0.2
done
