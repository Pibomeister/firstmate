#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process run inside that same session?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock and its
# state/.lock-session sidecar; bin/fm-claude-stop-autoarm.sh uses it to prove a
# Stop hook fires inside the lock-owning primary session before it may arm or
# rewake. Two signals decide ownership, either one sufficient: the recorded pid
# is a member of this process's contiguous harness ancestry, or the trusted
# session id below matches the id recorded beside the lock. Neither
# signal ever fails open: no id, no sidecar, an untrusted id, or a different
# recorded id leaves the ancestry verdict exactly as it was.
#
# Codex adds one shape Claude never has: a shared app-server daemon
# (`codex app-server --listen ... --managed-daemon`, and its
# `app-server daemon` helpers) that parents tool shells for every Codex
# session on the machine, plus a `codex-code-mode-host` execution helper
# that sits between a tool shell and its session process. Neither process
# is the session's model loop, so neither is ever a session process here: the daemon is not harness-liveness
# evidence, never an anchor, and the ancestry walk stops at it rather than
# climbing into whichever session happened to launch it; the host is
# transparent, so the walk climbs through it to the session process above
# it when there is one. A Codex session served only by that daemon has no
# session pid in its ancestry at all; its ownership signal is the trusted
# Codex thread id below, exactly as a Claude session's id carries it when
# its helper chain is recycled.
# This file is sourced by scripts and has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
_FM_SESSION_LOCK_LIB_DIR=${BASH_SOURCE[0]%/*}
[ "$_FM_SESSION_LOCK_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _FM_SESSION_LOCK_LIB_DIR=.
# shellcheck source=bin/fm-cursor-lib.sh
. "${_FM_SESSION_LOCK_LIB_DIR:-/}/fm-cursor-lib.sh"
FM_SESSION_PROCESS_READER="${_FM_SESSION_LOCK_LIB_DIR:-/}/fm-session-process.py"
unset _FM_SESSION_LOCK_LIB_DIR

# Known harness command names; extend when a new adapter is verified. omp is
# anchored exactly like pi: its process name is the bare word `omp` (verified,
# omp 18.1.11), and a substring match would claim ompd or comp. muse is
# anchored the same way bin/fm-harness.sh anchors it: the launcher execs a
# version-suffixed `muse-bin-<version>`, so only the bare name or that prefix
# matches, never a substring such as amuse or musescore.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$|^omp$|^muse$|^muse-bin-'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi omp muse)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

fm_codex_process_class() {
  python3 "$FM_SESSION_PROCESS_READER" class "$1" 2>/dev/null
}

fm_session_process_start() {
  python3 "$FM_SESSION_PROCESS_READER" start "$1" 2>/dev/null
}

# True when the process described by command name $1 and full argument string $2
# is Codex-shaped, whatever its class. This is the raw shape only: the shared
# daemon and the code-mode host are Codex-shaped but are not session
# processes, which fm_harness_process_matches below owns.
fm_codex_process_shaped() {  # <comm> <args>
  _fm_harness_process_matches_raw "$1" "$2" || return 1
  [ "$FM_HARNESS_IS_CODEX" -eq 1 ]
}

# True when pid $1 is a live Codex app-server daemon process.
fm_codex_pid_is_daemon() {  # <pid>
  local pid=$1 comm args
  comm=$(ps -o comm= -p "$1" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$1" 2>/dev/null)
  fm_codex_process_shaped "$comm" "$args" || return 1
  [ "$(fm_codex_process_class "$pid")" = daemon ]
}

fm_codex_pid_bound_to_id() {
  [ -n "$2" ] || return 1
  kill -0 "$1" 2>/dev/null || return 1
  python3 "$FM_SESSION_PROCESS_READER" bound "$1" "$2" 2>/dev/null
}

FM_CODEX_IDENTITY_OWNER_PID=
fm_codex_session_identity_live() {
  FM_CODEX_IDENTITY_OWNER_PID=$(python3 "$FM_SESSION_PROCESS_READER" scan "$1" 2>/dev/null)
  [ -n "$FM_CODEX_IDENTITY_OWNER_PID" ]
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness session process. Sets FM_HARNESS_IS_CLAUDE and
# FM_HARNESS_IS_CODEX for the ancestry walk. A Codex-shaped process whose
# class is daemon or host (fm_codex_process_class) never matches: neither
# process is a session, so neither can anchor a lock, satisfy liveness, or
# own a lock by ancestry.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
#   4. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
FM_HARNESS_IS_CLAUDE=0
FM_HARNESS_IS_CODEX=0
fm_harness_process_matches() {  # <comm> <args> [pid]
  _fm_harness_process_matches_raw "$1" "$2" || return 1
  if [ "$FM_HARNESS_IS_CODEX" -eq 1 ]; then
    case "$(fm_codex_process_class "${3:-}")" in
      daemon|host|'') return 1 ;;
    esac
  fi
  return 0
}

_fm_harness_process_matches_raw() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  FM_HARNESS_IS_CODEX=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in
      *claude*) FM_HARNESS_IS_CLAUDE=1 ;;
      *codex*) FM_HARNESS_IS_CODEX=1 ;;
    esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in
      claude) FM_HARNESS_IS_CLAUDE=1 ;;
      codex) FM_HARNESS_IS_CODEX=1 ;;
    esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in
          *claude*) FM_HARNESS_IS_CLAUDE=1 ;;
          *codex*) FM_HARNESS_IS_CODEX=1 ;;
        esac
        return 0
      fi
      ;;
  esac
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  fm_cursor_process_matches "$comm" "$args" "$argv0" && return 0
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    # The shared Codex app-server daemon parents tool shells for sessions
    # other than the one that launched it, so the walk stops at it: no
    # process above it can be this session's process. The code-mode host
    # needs no special case here - it never matches as a session process,
    # so the walk climbs through it to the session process above it.
    if fm_codex_process_shaped "$comm" "$args" \
      && [ "$(fm_codex_process_class "$pid")" = daemon ]; then
      break
    fi
    if fm_harness_process_matches "$comm" "$args" "$pid"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    # Examine the top of the chain before stopping. Inside a PID namespace the
    # harness itself is pid 1, so stopping as soon as the next pid is 1 hides the
    # very process this walk exists to find. A host's real pid 1 (init, systemd,
    # launchd) is not harness-shaped, so fm_harness_process_matches rejects it.
    case "$pid" in '' | *[!0-9]*) break ;; esac
    [ "$pid" -ge 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the outermost pid of this session's contiguous harness run for callers
# that need that ancestry identity. This is not necessarily the pid written to
# the session lock: fm_session_lock_anchor_pid owns that choice and uses a
# trusted Claude session's model-loop pid instead. Every non-Claude harness
# reports a single pid, so this remains its innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids
  pids=$(fm_harness_ancestry_pids) || return 1
  _fm_harness_outermost_pid "$pids"
}

# Print the last (outermost) pid of ancestry list $1, or return 1 when empty.
_fm_harness_outermost_pid() {  # <ancestry-pids>
  local pid outermost=''
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$1
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True when pid $1 is one of the lines of ancestry list $2.
fm_harness_pid_listed() {  # <pid> <ancestry-pids>
  local pid
  while IFS= read -r pid; do
    [ "$pid" = "$1" ] && return 0
  done <<EOF
$2
EOF
  return 1
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args" "$pid"
}

# --- trusted same-session identity -------------------------------------------
# Claude Code hands every hook and tool shell CLAUDE_CODE_SESSION_ID (the
# session's conversation id) and CLAUDE_PID (the pid of the process running the
# model loop). A background session runs that model loop in a transient helper
# bridged to its front-end by a shared daemon, and when that bridge is recycled
# the contiguous claude-named ancestry from a hook to the recorded lock owner
# breaks while the owner pid stays alive, so ancestry alone reads the session's
# own lock as another live session's. The id is the one identity that survives
# the recycling, so it is accepted as a second ownership signal - but only from
# an environment proven to belong to the current Claude run.
#
# Trust gate: CLAUDE_PID must be a Claude-shaped member of this process's
# contiguous harness ancestry. An id merely retained in a helper environment
# fails that membership and is ignored: a hand-started Pi or codex primary under
# a Claude pane still carries the pane's CLAUDE_CODE_SESSION_ID and CLAUDE_PID,
# and must never own a lock with them. Ids are read from the environment only,
# never from ps argv, where prompts and briefs are visible.
#
# A --fork-session successor mints a new id, so it stays a foreign live owner
# until the pre-fork process exits; that is the safe direction and a documented
# non-goal. Two genuinely different live sessions sharing one id is not a
# supported state (Claude refuses to resume a running session under its id).

# Print the Claude session id this process may own with, or return 1. $1 is the
# ancestry list an earlier walk already produced, so a caller that walked once
# need not walk again.
fm_session_lock_trusted_claude_session_id() {  # [<ancestry-pids>]
  local id=${CLAUDE_CODE_SESSION_ID:-} claude_pid=${CLAUDE_PID:-} pids=${1:-} pid comm args
  [ -n "$id" ] || return 1
  case "$id" in *$'\n'*|*$'\r'*) return 1 ;; esac
  case "$claude_pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -z "$pids" ]; then
    pids=$(fm_harness_ancestry_pids) || return 1
  fi
  while IFS= read -r pid; do
    [ "$pid" = "$claude_pid" ] || continue
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    fm_harness_process_matches "$comm" "$args" "$pid" || return 1
    [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || return 1
    printf '%s\n' "$id"
    return 0
  done <<EOF
$pids
EOF
  return 1
}

# --- trusted Codex thread identity -------------------------------------------
# Codex hands every tool shell CODEX_THREAD_ID and CODEX_SESSION_ID, both
# naming the session's thread (verified live with codex-cli 0.163.0: a tool
# shell reported both, equal, with the session's native Codex process as its
# parent). Codex publishes no pid companion like CLAUDE_PID, so the trust
# gate is the ancestry itself: the id is trusted only when the innermost
# harness-shaped process above this one is Codex-shaped - a session TUI, the
# code-mode host, or the shared app-server daemon, each of which parents
# only its own sessions' tool shells, and Codex rewrites the id for every
# tool call its sessions make. A different harness nearer than any Codex
# process - a hand-started Pi or Claude primary inside a Codex tool shell,
# still carrying the retained id - fails the gate, as does a session that
# publishes only one of the two ids or a disagreeing pair. Ids are read
# from the environment only, never from ps argv, where prompts and briefs
# are visible.

# Print the Codex thread id this process may own with, or return 1. Only
# the documented pair counts: both CODEX_THREAD_ID and CODEX_SESSION_ID
# present and equal (the shape Codex actually publishes to tool shells).
# Either variable alone, or a disagreeing pair, proves nothing.
fm_session_lock_trusted_codex_session_id() {
  local thread=${CODEX_THREAD_ID:-} session=${CODEX_SESSION_ID:-} id pid comm args
  [ -n "$thread" ] && [ -n "$session" ] && [ "$thread" = "$session" ] || return 1
  id=$thread
  case "$id" in *$'\n'*|*$'\r'*) return 1 ;; esac
  pid=$$
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_codex_process_shaped "$comm" "$args"; then
      printf '%s\n' "$id"
      return 0
    fi
    if fm_harness_process_matches "$comm" "$args" "$pid"; then
      return 1
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$pid" in '' | *[!0-9]*) return 1 ;; esac
    [ "$pid" -ge 1 ] || return 1
  done
  return 1
}

# Print the session id this process may own with, or return 1: the trusted
# Claude id when this is a Claude session, else the trusted Codex thread id
# when this is a Codex session. $1 is the ancestry list an earlier walk
# already produced for the Claude gate; the Codex gate walks on its own
# because a daemon-served session has no ancestry pid to reuse.
fm_session_lock_trusted_session_id() {  # [<ancestry-pids>]
  fm_session_lock_trusted_claude_session_id "${1:-}" && return 0
  fm_session_lock_trusted_codex_session_id
}

# Print the session id recorded beside the lock in state dir $1, or return 1.
# bin/fm-lock.sh is the only writer of state/.lock-session; a missing,
# symlinked, unreadable, or empty sidecar, or one whose first line contains a
# newline or carriage return, is simply no recorded id.
fm_session_lock_recorded_session_id() {  # <state>
  local state=$1 recorded
  [ -f "$state/.lock-session" ] && [ ! -L "$state/.lock-session" ] || return 1
  recorded=$(head -n 1 "$state/.lock-session" 2>/dev/null) || return 1
  [ -n "$recorded" ] || return 1
  case "$recorded" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s\n' "$recorded"
}

fm_session_lock_anchor_instance_matches() {
  local state=$1 pid recorded current
  pid=$(cat "$state/.lock" 2>/dev/null) || return 1
  recorded=$(sed -n 's/^anchor_start=//p' "$state/.lock-session" 2>/dev/null)
  [ -n "$recorded" ] || return 0
  [ "$(sed -n 's/^anchor_pid=//p' "$state/.lock-session")" = "$pid" ] || return 1
  current=$(fm_session_process_start "$pid") || return 1
  [ "$current" = "$recorded" ]
}

fm_session_lock_daemon_instance_live() {
  local state=$1 pid recorded current
  pid=$(sed -n 's/^codex_daemon_pid=//p' "$state/.lock-session" 2>/dev/null)
  recorded=$(sed -n 's/^codex_daemon_start=//p' "$state/.lock-session" 2>/dev/null)
  case "$pid" in ''|0|1|*[!0-9]*) return 1 ;; esac
  [ -n "$recorded" ] || return 1
  current=$(fm_session_process_start "$pid") || return 1
  [ "$current" = "$recorded" ] || return 1
  FM_CODEX_IDENTITY_OWNER_PID=$pid
}

fm_session_lock_codex_daemon_pid() {
  local pid=$$ comm args
  fm_session_lock_trusted_codex_session_id >/dev/null || return 1
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    fm_codex_pid_is_daemon "$pid" && { printf '%s\n' "$pid"; return 0; }
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    fm_harness_process_matches "$comm" "$args" "$pid" && return 1
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$pid" in ''|0|1|*[!0-9]*) return 1 ;; esac
  done
  return 1
}

fm_session_lock_recorded_owner_live() {
  local state=$1 lock_pid recorded
  FM_CODEX_IDENTITY_OWNER_PID=
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in ''|*[!0-9]*) return 1 ;; esac
  if fm_session_lock_anchor_instance_matches "$state" && fm_harness_pid_alive "$lock_pid"; then
    FM_CODEX_IDENTITY_OWNER_PID=$lock_pid
    return 0
  fi
  recorded=$(fm_session_lock_recorded_session_id "$state") || return 1
  fm_session_lock_daemon_instance_live "$state" && return 0
  fm_codex_session_identity_live "$recorded"
}

# True when the lock in state dir $1 was recorded by this same session:
# the trusted id (Claude session id or Codex thread id) equals the id
# recorded beside the lock. No trusted id, no sidecar, or a different
# recorded id is false.
fm_session_lock_same_session() {  # <state> [<ancestry-pids>]
  local state=$1 trusted recorded
  trusted=$(fm_session_lock_trusted_session_id "${2:-}") || return 1
  recorded=$(fm_session_lock_recorded_session_id "$state") || return 1
  [ "$recorded" = "$trusted" ]
}

# Print the pid bin/fm-lock.sh records on lock line 1 for this session. For a
# Claude session with a trusted id that is CLAUDE_PID, the model-loop process:
# never the shared transient daemon and never a front-end that outlives the
# session, so "recorded pid dead" keeps meaning "session gone" instead of
# wedging a home behind a live daemon whose session died. A replaced background
# helper leaves a dead pid that its own session's next hook reclaims, because
# the sidecar still names that session. Every other session with a session
# process in its ancestry records the outermost pid of its contiguous run,
# exactly as before - for a Codex TUI that is the TUI process itself, reached
# directly or through its code-mode host, never the shared app-server daemon
# above it. A Codex session served only by that daemon has no session pid in
# its ancestry: line 1 then records the acquiring process and carries no
# liveness meaning at all, because the trusted thread id in the sidecar is
# that session's ownership proof (fm_session_lock_owned_by_self).
fm_session_lock_anchor_pid() {
  local pids
  pids=$(fm_harness_ancestry_pids) || pids=''
  if [ -n "$pids" ]; then
    if fm_session_lock_trusted_claude_session_id "$pids" >/dev/null; then
      printf '%s\n' "$CLAUDE_PID"
      return 0
    fi
    _fm_harness_outermost_pid "$pids"
    return 0
  fi
  if fm_session_lock_trusted_codex_session_id >/dev/null; then
    printf '%s\n' "$$"
    return 0
  fi
  return 1
}

# True when state dir $1 holds a session lock that this process's session owns:
# the recorded pid is ANY harness ancestor of the current process, or the lock
# was recorded by this same trusted session. Membership is the honest ancestry
# test, because the lock owner sits at an unknown depth in a contiguous Claude
# run - it is the outermost pid when the hook fires inside the session's own
# nested worker chain, and an inner pid when a harness-named daemon parents the
# session. The same-session path requires the recorded pid alive so that a
# dead one is reclaimed through bin/fm-lock.sh's ordinary stale-owner path,
# which refreshes line 1, rather than silently owned with a dead anchor. A
# Codex session served only by the shared app-server daemon is the one
# exception: its recorded pid is the acquiring process by construction
# (fm_session_lock_anchor_pid), never a live session process, so a trusted
# thread id matching the sidecar is ownership on its own. A missing lock, a
# malformed lock, a lock held by a harness outside this ancestry under
# another (or no) session id, or an ancestry that cannot be resolved all
# fail closed. A recorded pid that is the shared Codex daemon can never own
# a lock here: it is in no session's ancestry and is not a live harness.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  pids=$(fm_harness_ancestry_pids) || pids=''
  if [ -n "$pids" ] && fm_harness_pid_listed "$lock_pid" "$pids" \
    && fm_session_lock_anchor_instance_matches "$state"; then
    return 0
  fi
  fm_session_lock_same_session "$state" "$pids" || return 1
  if fm_session_lock_anchor_instance_matches "$state" && fm_harness_pid_alive "$lock_pid"; then
    return 0
  fi
  fm_session_lock_trusted_codex_session_id >/dev/null
}

# True when state dir $1 records a live verified harness session process
# outside this process's contiguous harness ancestry that was not recorded
# by this same trusted session. Sets FM_SESSION_LOCK_FOREIGN_OWNER_PID for
# a diagnostic caller. Malformed, missing, dead, daemon-anchored, and
# ancestry-uncertain locks are not foreign-owner evidence.
# shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
FM_SESSION_LOCK_FOREIGN_OWNER_PID=
fm_session_lock_foreign_owner_live() {
  local state=$1 lock_pid pids
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=
  [ -f "$state/.lock" ] && [ ! -L "$state/.lock" ] || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_session_lock_recorded_owner_live "$state" || return 1
  pids=$(fm_harness_ancestry_pids) || pids=''
  if [ -n "$pids" ] && fm_harness_pid_listed "$lock_pid" "$pids" \
    && fm_session_lock_anchor_instance_matches "$state"; then
    return 1
  fi
  fm_session_lock_same_session "$state" "$pids" && return 1
  # shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=$lock_pid
  return 0
}

# Read-only classification of state/.lock for machine-readable callers.
# Never acquires the lock. A held lock is not proof the holder is consuming
# wakes; that question belongs to the inbox readiness projection.
#
# Sets:
#   FM_LOCK_INSPECT_STATE         free|held|stale|unreadable|unknown
#   FM_LOCK_INSPECT_PID           recorded pid, or empty
#   FM_LOCK_INSPECT_LIVE_HARNESS  true|false|unknown
#   FM_LOCK_INSPECT_OWNER_PID     a live pid evidencing the owner, or empty:
#                                 the recorded pid when it is a live session
#                                 process, else a live process bound to the
#                                 recorded Codex thread. Consumers that need
#                                 a live owner's ancestry use this, never a
#                                 dead recorded pid.
#
# shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
FM_LOCK_INSPECT_STATE=unknown
FM_LOCK_INSPECT_PID=
FM_LOCK_INSPECT_LIVE_HARNESS=unknown
FM_LOCK_INSPECT_OWNER_PID=
fm_session_lock_inspect() {  # <state>
  local state=$1 lock pid
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_STATE=unknown
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_PID=
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_LIVE_HARNESS=unknown
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_OWNER_PID=
  lock="$state/.lock"
  if [ ! -e "$lock" ]; then
    FM_LOCK_INSPECT_STATE=free
    FM_LOCK_INSPECT_LIVE_HARNESS=false
    return 0
  fi
  if [ ! -f "$lock" ] || [ -L "$lock" ]; then
    FM_LOCK_INSPECT_STATE=unreadable
    return 0
  fi
  pid=$(cat "$lock" 2>/dev/null) || {
    FM_LOCK_INSPECT_STATE=unreadable
    return 0
  }
  pid=${pid%%$'\n'*}
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_PID=$pid
  case "$pid" in
    ''|*[!0-9]*)
      FM_LOCK_INSPECT_STATE=unknown
      return 0
      ;;
  esac
  if fm_session_lock_recorded_owner_live "$state"; then
    FM_LOCK_INSPECT_STATE=held
    FM_LOCK_INSPECT_LIVE_HARNESS=true
    FM_LOCK_INSPECT_OWNER_PID=$FM_CODEX_IDENTITY_OWNER_PID
    return 0
  fi
  if kill -0 "$pid" 2>/dev/null && ! fm_codex_pid_is_daemon "$pid"; then
    FM_LOCK_INSPECT_STATE=unknown
    FM_LOCK_INSPECT_LIVE_HARNESS=false
    return 0
  fi
  FM_LOCK_INSPECT_STATE=stale
  FM_LOCK_INSPECT_LIVE_HARNESS=false
}
