#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
#
# Line 1 of state/.lock is the owning session's anchor pid, resolved by
# fm_session_lock_anchor_pid in bin/fm-session-lock-lib.sh: the harness (agent)
# process found by walking the shell's ancestry, which lives as long as the
# firstmate session - unlike the transient subshell PID of any one tool call,
# which is dead moments after it is written. For a Claude session that proves a
# trusted session id the anchor is CLAUDE_PID, the model-loop process, so a
# shared transient daemon or a front-end that outlives the session never keeps
# a dead session's lock alive. A Codex session anchors on its TUI process,
# never on the shared Codex app-server daemon that parents its tool shells;
# a legacy daemon-pid lock without session-lifetime evidence is reclaimed
# here through the ordinary path, with no hand-deletion. A Codex session
# served only by that daemon has no session
# pid in its ancestry, so its line 1 carries no liveness meaning and the
# sidecar below is its ownership proof. On Windows that pid is recorded tagged,
# and a /clear re-key under the same tagged pid refreshes the sidecar as it does
# on POSIX. Line 1 keeps its whole-line pid format because every other reader
# takes the first line as the pid.
#
# The trusted id itself (a Claude session id or a Codex thread id) is
# recorded beside the lock in state/.lock-session, a sidecar written only
# here and only under the claim lock. Line 1 holds that id (empty when no
# trusted id is available); anchor_pid and anchor_start identify the recorded
# process instance. Daemon-served Codex records also carry codex_daemon_pid
# and codex_daemon_start for the lifetime query owned by the shared library.
# Valid FM_SESSION_ENDPOINT_META from a secondmate launch contributes the
# Orca backend, terminal, worktree, and spawn_gen fields with precedence over
# terminal environment variables. A primary's current terminal replaces a
# previous sidecar endpoint on re-publication; otherwise its Orca or tmux
# endpoint is preserved for the same trusted session id.
# Confirmed-own acquisition leaves a matching anchor instance's sidecar
# byte-identical; otherwise it republishes the record. A same-session
# confirmation keeps a live line 1 that is in this session's harness ancestry,
# because bin/fm-startup-network.sh compares that pid across its deferred
# sweeps; a dead recorded pid is reclaimed and rewritten to this session's
# anchor. A live line 1 outside the ancestry, owned only through the trusted
# id, is rewritten to the anchor under the claim lock and then the
# lease-command lock, and task leases recorded against the old pid move to the
# anchor in that same section (fm_lease_rekey_holder in bin/fm-lease-lib.sh),
# as does a Claude auto-arm rewake bound to the old pid, under
# state/.claude-autoarm.lock (fm_autoarm_rekey_session in bin/fm-wake-lib.sh).
# A later /clear re-key in the same process is then still proven by ancestry
# after the id changes, a held lease stays live, and the mid-turn guard still
# accepts that rewake. A lease or rewake that cannot be moved, including when
# the auto-arm lock stays busy past LEASE_LOCK_WAIT seconds, is reported as a
# warning and the re-anchor still completes. A busy lease-command lock past
# LEASE_LOCK_WAIT seconds instead refuses acquisition without re-anchoring.
# A foreign replacement retires the previous session's task leases under that
# same lease-command lock before publishing its new anchor. A verified handoff
# from a live predecessor retires them only after line 1 verifies as the
# successor, so a refused or rolled-back transfer keeps the predecessor's leases.
#
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0.
#                             A held lock is not proof the holder is consuming
#                             wakes. Machine-readable lock fields live on
#                             fm-inbox.sh ready, from the same inspect helper.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
LOCK_SESSION="$STATE/.lock-session"
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness, trusted
# session id, anchor pid) is owned by the shared session-lock lib so the Claude
# Stop auto-arm applies the exact same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-handoff-lib.sh
. "$SCRIPT_DIR/fm-handoff-lib.sh"

if [ "${1:-}" = "status" ]; then
  fm_session_lock_inspect "$STATE"
  case "$FM_LOCK_INSPECT_STATE" in
    free) echo "lock: free" ;;
    unreadable) echo "lock: unreadable" ;;
    held) echo "lock: held by live harness pid $FM_LOCK_INSPECT_PID" ;;
    *) echo "lock: stale (pid $FM_LOCK_INSPECT_PID dead or not a harness)" ;;
  esac
  exit 0
fi

me=$(fm_session_lock_anchor_pid) || {
  if fm_win_boundary_applies; then
    # Here the parent link does not reach the harness at all, so "not in the
    # ancestry" would describe the wrong problem and send the reader hunting a
    # process tree that can never contain the answer.
    echo "error: cannot identify this harness session on Windows: it publishes no session pid this build recognizes (see FM_WIN_HARNESS_PID_VARS in bin/fm-session-lock-lib.sh; CLAUDE_PID is taken only together with CLAUDE_CODE_SESSION_ID); operate read-only until resolved" >&2
  else
    echo "error: cannot locate harness process in ancestry" >&2
  fi
  exit 1
}
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
LEASE_LOCK="$STATE/.fm-lease-command.lock"
LEASE_LOCK_HELD=0
LEASE_LOCK_WAIT=5
AUTOARM_LOCK="$STATE/.claude-autoarm.lock"
AUTOARM_LOCK_HELD=0
# The live line-1 pid a same-session confirmation is moving off, or empty.
REANCHOR=
# PHASE 0: committed/none. 1: sidecar mutated, line 1 not written. 2: line 1 written, not verified.
# KIND 0: no backup. 1: restore $LOCK_SESSION_PREV. 2: sidecar was absent.
LOCK_SESSION_PHASE=0
LOCK_SESSION_KIND=0
LOCK_SESSION_PREV="$STATE/.lock-session.prev"
LOCK_LINE_PRE=
release_autoarm_lock() {
  if [ "$AUTOARM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$AUTOARM_LOCK"
    AUTOARM_LOCK_HELD=0
  fi
}
release_lease_lock() {
  if [ "$LEASE_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$LEASE_LOCK"
    LEASE_LOCK_HELD=0
  fi
}
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
restore_uncommitted_lock_session() {
  case "$LOCK_SESSION_PHASE" in
    1)
      case "$LOCK_SESSION_KIND" in
        1) mv -f "$LOCK_SESSION_PREV" "$LOCK_SESSION" 2>/dev/null || true ;;
        2) rm -f "$LOCK_SESSION" "$LOCK_SESSION_PREV" 2>/dev/null || true ;;
      esac
      ;;
    2)
      if verified_handoff_transfer && [ -n "$LOCK_LINE_PRE" ]; then
        cp -f "$LOCK_LINE_PRE" "$LOCK" 2>/dev/null || true
        case "$LOCK_SESSION_KIND" in
          1) mv -f "$LOCK_SESSION_PREV" "$LOCK_SESSION" 2>/dev/null || true ;;
          *) rm -f "$LOCK_SESSION" "$LOCK_SESSION_PREV" 2>/dev/null || true ;;
        esac
      else
        rm -f "$LOCK_SESSION" "$LOCK_SESSION_PREV" 2>/dev/null || true
      fi
      ;;
  esac
  LOCK_SESSION_PHASE=0
  LOCK_SESSION_KIND=0
}
verified_handoff_transfer() {
  [ -z "$REANCHOR" ] && [ "${HANDOFF_TAKEOVER:-}" = verified_transfer ] && [ -n "${FM_HANDOFF_NONCE:-}" ]
}
commit_lock_session() {
  LOCK_SESSION_PHASE=0
  LOCK_SESSION_KIND=0
  rm -f "$LOCK_SESSION_PREV" 2>/dev/null || true
}
on_lock_exit() {
  # Complete ownership restoration and lock release after the first signal.
  trap '' HUP INT TERM
  trap - EXIT
  restore_uncommitted_lock_session
  [ -n "$LOCK_LINE_PRE" ] && rm -f "$LOCK_LINE_PRE"
  release_autoarm_lock
  release_lease_lock
  release_claim_lock
}
trap on_lock_exit EXIT
trap 'exit 1' HUP INT TERM

remember_lock_session() {
  [ "$LOCK_SESSION_PHASE" -eq 0 ] || return 0
  if [ -e "$LOCK_SESSION" ] || [ -L "$LOCK_SESSION" ]; then
    rm -f "$LOCK_SESSION_PREV" 2>/dev/null || true
    cp -P "$LOCK_SESSION" "$LOCK_SESSION_PREV" 2>/dev/null || return 1
    LOCK_SESSION_KIND=1
  else
    LOCK_SESSION_KIND=2
  fi
  LOCK_SESSION_PHASE=1
}

publish_lock_endpoint() {
  local trusted=$1 recorded=$2 candidate=${FM_SESSION_ENDPOINT_META:-} source='' field value endpoint_backend=tmux explicit=0
  if [ -n "$trusted" ] && [ "$trusted" = "$recorded" ]; then
    source=$LOCK_SESSION
  fi
  if [ -n "$candidate" ] && [ -f "$candidate" ] && [ ! -L "$candidate" ] \
    && [ "$(sed -n 's/^backend=//p' "$candidate")" = orca ] \
    && [ "$(sed -n 's/^worktree=//p' "$candidate")" = "${FM_HOME%/}" ] \
    && [ -n "$(sed -n 's/^terminal=//p' "$candidate")" ]; then
    source=$candidate
    explicit=1
  fi
  # A resumed primary can move terminals while retaining its trusted id.
  # Its live terminal outranks its old sidecar, but not explicit launch metadata.
  if [ "$explicit" -eq 0 ] && value=$(fm_handoff_endpoint_handle); then
    case "$value" in *[!A-Za-z0-9_.:%-]*) return 1 ;; esac
    [ -n "${TMUX_PANE:-}" ] || endpoint_backend=orca
    printf 'backend=%s\nterminal=%s\nworktree=%s\n' "$endpoint_backend" "$value" "${FM_HOME%/}"
    return 0
  fi
  [ -n "$source" ] && [ -f "$source" ] && [ ! -L "$source" ] || return 0
  case "$(sed -n 's/^backend=//p' "$source")" in orca|tmux) ;; *) return 0 ;; esac
  value=$(sed -n 's/^worktree=//p' "$source")
  [ -n "$value" ] && [ "$value" = "${FM_HOME%/}" ] || return 0
  [ -n "$(sed -n 's/^terminal=//p' "$source")" ] || return 0
  for field in backend terminal worktree spawn_gen; do
    value=$(sed -n "s/^$field=//p" "$source")
    case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
    [ -z "$value" ] || printf '%s=%s\n' "$field" "$value"
  done
  return 0
}

publish_lock_session() {
  local anchor=${1:-$me} trusted recorded tmp start daemon daemon_start
  trusted=$(fm_session_lock_trusted_session_id) || trusted=
  recorded=$(fm_session_lock_recorded_session_id "$STATE") || recorded=
  if [ "$anchor" = "$(cat "$LOCK" 2>/dev/null)" ] && [ "$trusted" = "$recorded" ] \
    && [ -n "$(sed -n 's/^anchor_start=//p' "$LOCK_SESSION" 2>/dev/null)" ] \
    && fm_session_lock_anchor_instance_matches "$STATE"; then
    return 0
  fi
  start=$(fm_session_process_start "$anchor") || return 1
  daemon=$(fm_session_lock_codex_daemon_pid) || daemon=
  daemon_start=
  if [ -n "$daemon" ]; then
    daemon_start=$(fm_session_process_start "$daemon") || return 1
  fi
  remember_lock_session || return 1
  tmp=$(mktemp "$STATE/.lock-session.XXXXXX" 2>/dev/null) || return 1
  if ! {
    {
      printf '%s\nanchor_pid=%s\nanchor_start=%s\n' "$trusted" "$anchor" "$start"
      [ -z "$daemon" ] || printf 'codex_daemon_pid=%s\ncodex_daemon_start=%s\n' "$daemon" "$daemon_start"
      publish_lock_endpoint "$trusted" "$recorded"
    } > "$tmp" && mv -f "$tmp" "$LOCK_SESSION"
  } 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  return 0
}

publish_lock_session_or_die() {
  publish_lock_session "${1:-$me}" && return 0
  echo "error: cannot record the session identity beside the lock; operate read-only until resolved" >&2
  exit 1
}

# This session already holds the lock, recorded as pid $1. Line 1 stays exactly
# as recorded while that pid is alive and in this session's ancestry; only the
# sidecar is refreshed, under the claim lock, so a /clear re-key inside the same
# process replaces the old id. A live line 1 outside the ancestry is re-anchored
# as the header describes: REANCHOR records it and the caller keeps both locks
# for the guarded write below.
# A same-session confirmation waits for the claim lock so the sidecar refresh
# completes. After the wait, the lock is re-read and the sidecar is refreshed
# only when this session still owns it; otherwise the claim lock is released
# and the caller continues with the ordinary live-owner or reclaim path. The
# prior-session-sweep-is-finishing refusal is a takeover rule and does not
# apply here.
confirm_own_lock() {  # <recorded-pid>
  local recorded pids waited=0
  if [ "$CLAIM_LOCK_HELD" -ne 1 ]; then
    fm_lock_acquire_wait "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=1
    waited=1
  fi
  recorded=$(cat "$LOCK" 2>/dev/null || true)
  if fm_session_lock_owned_by_self "$STATE"; then
    pids=$(fm_harness_ancestry_pids) || pids=
    if ! fm_session_lock_anchor_instance_matches "$STATE" \
      || ! kill -0 "$recorded" 2>/dev/null \
      || { [ "$recorded" != "$me" ] && [ -n "$pids" ] && ! fm_harness_pid_listed "$recorded" "$pids"; }; then
      if ! fm_lock_acquire_wait_max "$LEASE_LOCK" "$LEASE_LOCK_WAIT"; then
        echo "error: cannot serialize the session re-anchor with task leases; operate read-only until resolved" >&2
        exit 1
      fi
      LEASE_LOCK_HELD=1
      REANCHOR=$recorded
      return 0
    fi
    publish_lock_session_or_die "$recorded"
    commit_lock_session
    release_claim_lock
    echo "lock acquired: harness pid $recorded"
    exit 0
  fi
  if [ "$waited" -eq 1 ]; then
    release_claim_lock
  fi
  return 1
}

refuse_live_owner() {  # <recorded-pid>
  local recorded deadline nonce
  if [ -f "$STATE/.handoff-pending" ] \
    && deadline=$(jq -er '.deadline | numbers' "$STATE/.handoff-pending" 2>/dev/null) \
    && [ "$(date +%s)" -lt "$deadline" ]; then
    nonce=$(jq -r '.nonce // ""' "$STATE/.handoff-pending" 2>/dev/null)
    if [ -n "$nonce" ] && [ "${FM_HANDOFF_NONCE:-}" = "$nonce" ]; then
      fm_handoff_event handoff_reject "$nonce" 0 "$me" "$(fm_handoff_endpoint_handle || true)" lock_held >&2
    else
      fm_handoff_event handoff_reject none 0 "$me" "$(fm_handoff_endpoint_handle || true)" lock_held_unbound >&2
    fi
  fi
  if recorded=$(fm_session_lock_recorded_session_id "$STATE"); then
    echo "error: another live firstmate session holds the lock (pid $1, session $recorded); operate read-only until resolved" >&2
  else
    echo "error: another live firstmate session holds the lock (pid $1); operate read-only until resolved" >&2
  fi
  exit 1
}

retire_previous_leases() {
  local lease task
  for lease in "$STATE"/.lease-*; do
    [ -f "$lease" ] || [ -L "$lease" ] || continue
    task=${lease##*/.lease-}
    fm_lease_valid_id "$task" || continue
    rm -f -- "$lease" || return 1
  done
}

# A handoff successor needs a valid ack while the recorded owner is live.
# A proven-dead owner takes the ordinary stale path only while the presented
# nonce's claim is still pending and unexpired; a pid that still exists
# without a live owner verdict is doubt and refuses. The verdict is taken
# once, under both locks, before any task lease is retired.
HANDOFF_TAKEOVER=verified_transfer
handoff_transfer_refused() {  # <recorded-pid>
  [ -n "${FM_HANDOFF_NONCE:-}" ] || return 1
  if fm_session_lock_recorded_owner_live "$STATE"; then
    ! fm_handoff_can_transfer "$me" "$1"
    return
  fi
  case "$1" in ''|*[!0-9]*) return 0 ;; esac
  ! kill -0 "$1" 2>/dev/null || return 0
  fm_handoff_claim_live "$FM_HANDOFF_NONCE" || return 0
  HANDOFF_TAKEOVER=stale_takeover
  return 1
}

if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  old=$(cat "$LOCK" 2>/dev/null || true)
  if fm_session_lock_owned_by_self "$STATE"; then
    confirm_own_lock "$old"
    old=$(cat "$LOCK" 2>/dev/null || true)
  fi
  if [ -z "$REANCHOR" ] && fm_session_lock_recorded_owner_live "$STATE" && ! fm_handoff_can_transfer "$me" "$old"; then
    refuse_live_owner "$old"
  fi
fi

if [ "$CLAIM_LOCK_HELD" -ne 1 ]; then
  if ! fm_lock_try_acquire "$CLAIM_LOCK"; then
    sweep_pid=$(sed -n 's/^pid=//p' "$STATE/.startup-network.status" 2>/dev/null | tail -1)
    if [ -n "${FM_LOCK_HELD_PID:-}" ] && [ "$FM_LOCK_HELD_PID" = "$sweep_pid" ]; then
      echo "error: the prior session's bounded startup sweep is finishing; operate read-only until it releases the fleet lock" >&2
      exit 1
    fi
    fm_lock_acquire_wait "$CLAIM_LOCK"
  fi
  CLAIM_LOCK_HELD=1
fi

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  # A re-anchor decided above has held the claim lock since, so line 1 is the
  # pid it recorded and needs no second verdict.
  if [ -z "$REANCHOR" ] && fm_session_lock_recorded_owner_live "$STATE"; then
    fm_session_lock_owned_by_self "$STATE" && confirm_own_lock "$old"
    old=$(cat "$LOCK" 2>/dev/null || true)
    if [ -z "$REANCHOR" ] && fm_session_lock_recorded_owner_live "$STATE" && ! fm_handoff_can_transfer "$me" "$old"; then
      refuse_live_owner "$old"
    fi
  fi
fi
# The sidecar goes first: a fresh pid beside a previous session's id would let
# that session's resume own this lock. If the sidecar changes before line 1 is
# written, a failure restores the previous sidecar. If line 1 is written but
# not yet verified, a failure removes the sidecar and leaves the lock
# ancestry-only, except on a verified transfer, where it restores both the
# predecessor's line 1 and its sidecar under the held locks. On the re-anchor path a HUP, INT, or TERM during the lease
# move or the bounded .claude-autoarm.lock wait, before commit_lock_session,
# still runs restore_uncommitted_lock_session with phase 2 and removes the
# sidecar. A verified transfer retires the predecessor's leases only after
# commit_lock_session, still under the lease lock and with signals ignored, so
# a rolled-back transfer keeps them and a committed one reports success; a
# lease left by a failed retirement reads as stale against a non-owner pid.
if [ -z "$REANCHOR" ]; then
  fm_lock_acquire_wait_max "$LEASE_LOCK" "$LEASE_LOCK_WAIT" || {
    echo "error: cannot retire the previous session's task leases; operate read-only until resolved" >&2
    exit 1
  }
  LEASE_LOCK_HELD=1
  # The ack must still be valid at the actual mutation, after waiting for
  # leases. Both claim and lease locks are held through publication.
  if handoff_transfer_refused "${old:-}"; then
    refuse_live_owner "${old:-}"
  fi
  if ! verified_handoff_transfer; then
    retire_previous_leases || {
      echo "error: cannot retire a previous session task lease; operate read-only until resolved" >&2
      exit 1
    }
  fi
fi
publish_lock_session_or_die
if [ -f "$LOCK" ]; then
  LOCK_LINE_PRE=$(mktemp "$STATE/.lock.pre.XXXXXX") || {
    echo "error: cannot write session lock; operate read-only until resolved" >&2
    exit 1
  }
  if ! cp "$LOCK" "$LOCK_LINE_PRE" 2>/dev/null; then
    echo "error: cannot write session lock; operate read-only until resolved" >&2
    exit 1
  fi
fi
LOCK_SESSION_PHASE=2
if ! { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null; then
  lock_unchanged=0
  if [ -n "$LOCK_LINE_PRE" ] && cmp -s "$LOCK_LINE_PRE" "$LOCK"; then
    lock_unchanged=1
  elif [ -z "$LOCK_LINE_PRE" ] && [ ! -e "$LOCK" ] && [ ! -L "$LOCK" ]; then
    lock_unchanged=1
  fi
  if [ "$lock_unchanged" -eq 1 ]; then
    if [ "$LOCK_SESSION_KIND" -ne 0 ]; then
      LOCK_SESSION_PHASE=1
    else
      LOCK_SESSION_PHASE=0
    fi
  fi
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
written=$(cat "$LOCK" 2>/dev/null) || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$me" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
if [ -n "$REANCHOR" ] && ! fm_lease_rekey_holder "$REANCHOR" "$me"; then
  echo "warning: a task lease recorded against pid $REANCHOR could not be moved to pid $me, so it reads as stale" >&2
fi
if [ -n "$REANCHOR" ] && fm_autoarm_ledger_read "$STATE" && [ "$FM_AUTOARM_SESSION" = "$REANCHOR" ]; then
  if fm_lock_acquire_wait_max "$AUTOARM_LOCK" "$LEASE_LOCK_WAIT"; then
    AUTOARM_LOCK_HELD=1
  fi
  if [ "$AUTOARM_LOCK_HELD" -ne 1 ] || ! fm_autoarm_rekey_session "$STATE" "$REANCHOR" "$me"; then
    echo "warning: the Claude auto-arm rewake recorded against pid $REANCHOR could not be moved to pid $me, so a mid-turn guard can report supervision off until the next Stop" >&2
  fi
  release_autoarm_lock
fi
if verified_handoff_transfer; then
  trap '' HUP INT TERM
  commit_lock_session
  retire_previous_leases \
    || echo "warning: a previous session task lease could not be retired, so it reads as stale" >&2
else
  commit_lock_session
fi
release_lease_lock
release_claim_lock
[ -z "${FM_HANDOFF_NONCE:-}" ] || echo "handoff_takeover=$HANDOFF_TAKEOVER"
echo "lock acquired: harness pid $me"
