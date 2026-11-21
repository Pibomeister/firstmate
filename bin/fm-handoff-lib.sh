#!/usr/bin/env bash
# Shared verified-handoff contract. Callers source session-lock-lib and wake-lib.
# Pending claim: state/.handoff-pending JSON version=1, nonce, handoff, sha256,
# predecessor_pid/start, deadline (Unix seconds), successor (the launcher's
# runtime choice and quota verdict, informational). Only the owning predecessor
# creates it. The successor reads the document and calls fm-handoff-ack.sh.
# Ack: data/handoff-ack-<nonce>.json version=1, nonce, harness_pid, fm_lock_pid,
# harness_start, terminal_handle, sha256. fm_lock_pid is the proposed anchor;
# it becomes authoritative only after fm-lock.sh validates it under .lock.acquire
# and .fm-lease-command.lock and replaces the predecessor. An ack alone never
# clears the Stop gate. Expired/nonmatching claims cannot transfer a live lock.
# The completed state/.handoff-successor carries pid, nonce, handoff, sha256,
# and the same informational successor line.
#
# Watchdog wire format (stdout and append-only state/handoff-events.log):
# HANDOFF v1 ts=<epoch> event=<handoff_started|handoff_retry|handoff_ack|handoff_failed|handoff_reject>
#   nonce=<hex-or-none> attempt=<0|1|2> pid=<digits-or-0> handle=<safe-token-or-none> reason=<safe-token>
# Each event is ONE line, fields in that order; no prose or paths on the wire.
# reason=lock_held_unbound (always nonce=none) is a refused session during a
# live claim that did not present the claim's nonce. It is NOT a successor
# reject and must not end an attempt; only a nonce-bound handoff_reject does.
# An unfinished launcher's signal/error exit emits handoff_failed with
# reason=interrupted or reason=error, respectively, unless the lock already
# moved to the acknowledged successor; then it records completion instead.
# The launcher decides completion and failure only under .lock.acquire, the
# lock fm-lock.sh holds from its transfer verdict through commit or rollback.
# When that lock is still busy at the launcher's bounded exit, it emits
# handoff_failed reason=unresolved instead. Consumers treat unresolved as not
# final: a later handoff_ack reason=lock_transferred with the same nonce
# settles it as a transfer; otherwise it stands as the failure.
# handoff_ack reason=lock_transferred is a verified transfer from a live
# predecessor; reason=stale_takeover means the predecessor was proven dead and
# the successor took the lock through the ordinary stale-owner path.
#
# Launch failure: state/.handoff-launch-failed is one line,
#   at=<epoch> pid=<predecessor-pid> nonce=<hex-or-none> attempt=<0|1|2> reason=<safe-token>
# rewritten by the launcher with every handoff_failed it emits, including
# reason=unresolved, and with any unfinished exit after it removed an earlier
# record. A later launch removes it once it holds the launch lock.
# While the record names the current, live lock pid, the predecessor survived the
# failed launch and keeps supervising this home. A planned fresh start whose
# trigger marker is no newer than the record (fm_handoff_launch_failed_since)
# is then no longer handing off: bin/fm-handoff-trigger.sh releases its Stop
# gate for that cycle, and the cycle's published reset reads compaction, so
# auto-compaction stays the session's reset and a watchdog never restarts the
# surviving session for a handoff that will not come. A record that names any
# other pid, such as after an unresolved failure the transfer later committed,
# releases nothing.
#
# Launch prompts name a handoff by path and never include its text.
# fm_handoff_prompt_line_cap is 60. fm_handoff_warn_line_cap warns on stderr
# when the document is longer, and the launch still passes only the path.

# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-supervisor-target-lib.sh"

# This session's terminal. discover_supervisor_target owns the precedence and
# refuses the legacy tmux fallback; an unresolved endpoint is not a handle.
fm_handoff_endpoint_handle() {
  local target rc=0
  target=$(discover_supervisor_target 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || return 1
  case "$target" in ''|*[!A-Za-z0-9_.:%-]*) return 1 ;; esac
  printf '%s' "$target"
}

fm_handoff_event() { # <event> <nonce> <attempt> <pid> <handle> <reason>
  local line handle=$5 nonce=$2 pid=$4
  case "$handle" in ''|*[!A-Za-z0-9_.:%-]*) handle=none ;; esac
  case "$nonce" in ''|*[!a-f0-9]*) nonce=none ;; esac
  case "$pid" in ''|*[!0-9]*) pid=0 ;; esac
  line="HANDOFF v1 ts=$(date +%s) event=$1 nonce=$nonce attempt=$3 pid=$pid handle=$handle reason=$6"
  printf '%s\n' "$line" >> "$STATE/handoff-events.log"
  printf '%s\n' "$line"
}

fm_handoff_record_launch_failed() { # <pid> <nonce> <attempt> <reason>
  local pid=$1 nonce=$2 attempt=$3 reason=$4 tmp
  case "$pid" in ''|*[!0-9]*) pid=0 ;; esac
  case "$nonce" in ''|*[!a-f0-9]*) nonce=none ;; esac
  case "$attempt" in [0-2]) ;; *) attempt=0 ;; esac
  case "$reason" in ''|*[!A-Za-z0-9_.:-]*) reason=error ;; esac
  tmp=$(mktemp "$STATE/.handoff-launch-failed.XXXXXX") || return 1
  if printf 'at=%s pid=%s nonce=%s attempt=%s reason=%s\n' "$(date +%s)" "$pid" "$nonce" "$attempt" "$reason" > "$tmp" \
    && mv -f "$tmp" "$STATE/.handoff-launch-failed"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# True when <state-dir> records a failed launch at or after <epoch> whose
# predecessor still holds the lock and is alive. Reads only that record and
# the lock file.
fm_handoff_launch_failed_since() { # <state-dir> <epoch>
  local record="$1/.handoff-launch-failed" since=$2 line
  local shape='^at=([0-9]+) pid=([0-9]+) nonce=(none|[a-f0-9]+) attempt=[0-2] reason=[A-Za-z0-9_.:-]+$'
  case "$since" in ''|*[!0-9]*) return 1 ;; esac
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  IFS= read -r line < "$record" || [ -n "$line" ] || return 1
  [[ $line =~ $shape ]] || return 1
  [ "${BASH_REMATCH[2]}" != 0 ] && [ "${BASH_REMATCH[2]}" = "$(cat "$1/.lock" 2>/dev/null)" ] || return 1
  [ "${BASH_REMATCH[1]}" -ge "$since" ] || return 1
  kill -0 "${BASH_REMATCH[2]}" 2>/dev/null
}

fm_handoff_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | awk '{print $1}'
  else
    shasum -a 256 -- "$1" | awk '{print $1}'
  fi
}

fm_handoff_ack_valid() { # <nonce> <handoff> <sha> [<expected-pid>]
  local nonce=$1 doc=$2 sha=$3 expected=${4:-} ack pid start
  case "$nonce" in ''|*[!a-f0-9]*) return 1 ;; esac
  ack="$FM_HOME/data/handoff-ack-$nonce.json"
  [ -f "$ack" ] && [ ! -L "$ack" ] || return 1
  jq -e --arg nonce "$nonce" --arg sha "$sha" '
    .version == 1 and .nonce == $nonce and .sha256 == $sha and
    (.harness_pid | type == "number") and .harness_pid > 1 and
    .harness_pid == .fm_lock_pid and
    (.terminal_handle | type == "string" and test("^[A-Za-z0-9_.:%-]+$")) and
    (.harness_start | type == "string" and length > 0)' "$ack" >/dev/null 2>&1 || return 1
  pid=$(jq -r .harness_pid "$ack")
  case "$pid" in *[!0-9]*) return 1 ;; esac
  [ -z "$expected" ] || [ "$pid" = "$expected" ] || return 1
  fm_harness_pid_alive "$pid" || return 1
  start=$(fm_session_process_start "$pid") || return 1
  [ "$start" = "$(jq -r .harness_start "$ack")" ] || return 1
  [ "$(fm_handoff_hash "$doc")" = "$sha" ] || return 1
}

fm_handoff_claim_live() { # <nonce>
  local claim="$STATE/.handoff-pending" deadline
  [ -n "$1" ] && [ -f "$claim" ] && [ ! -L "$claim" ] || return 1
  [ "$(jq -er '.nonce | select(type == "string")' "$claim" 2>/dev/null)" = "$1" ] || return 1
  deadline=$(jq -er '.deadline | numbers' "$claim" 2>/dev/null) || return 1
  [ "$(date +%s)" -lt "$deadline" ]
}

fm_handoff_can_transfer() { # <new-anchor> <recorded-predecessor>
  local claim="$STATE/.handoff-pending" nonce=${FM_HANDOFF_NONCE:-} doc sha pred_start
  fm_handoff_claim_live "$nonce" || return 1
  jq -e --arg old "$2" '.version == 1 and (.predecessor_pid | tostring) == $old' "$claim" >/dev/null || return 1
  [ "$1" != "$2" ] || return 1
  pred_start=$(fm_session_process_start "$2") || return 1
  [ "$pred_start" = "$(jq -r .predecessor_start "$claim")" ] || return 1
  doc=$(jq -er .handoff "$claim") || return 1
  sha=$(jq -er .sha256 "$claim") || return 1
  fm_handoff_ack_valid "$nonce" "$doc" "$sha" "$1" || return 1
  fm_handoff_claim_live "$nonce"
}

fm_handoff_completed() { # <record-file>
  local record=$1 pid nonce doc sha
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  pid=$(sed -n 's/^pid=//p' "$record")
  nonce=$(sed -n 's/^nonce=//p' "$record")
  doc=$(sed -n 's/^handoff=//p' "$record")
  sha=$(sed -n 's/^sha256=//p' "$record")
  [ "$pid" = "$(cat "$STATE/.lock" 2>/dev/null)" ] || return 1
  [ -n "$(sed -n 's/^anchor_start=//p' "$STATE/.lock-session" 2>/dev/null)" ] || return 1
  fm_session_lock_anchor_instance_matches "$STATE" || return 1
  fm_handoff_ack_valid "$nonce" "$doc" "$sha" "$pid" || return 1
  [ "$(jq -r .terminal_handle "$FM_HOME/data/handoff-ack-$nonce.json")" = "$(sed -n 's/^terminal=//p' "$STATE/.lock-session")" ]
}

# Successor and restart prompts name the document by path. Sixty lines is the
# warning cap; a longer file still launches, and the prompt never includes it.
fm_handoff_prompt_line_cap() { printf '60'; }

fm_handoff_warn_line_cap() { # <path>
  local path=$1 lines=0 cap
  [ -f "$path" ] || return 0
  cap=$(fm_handoff_prompt_line_cap)
  # Read the file on stdin. A path whose text is an awk assignment or flag
  # must not become an operand, or awk waits on stdin with no file to count.
  lines=$(2>/dev/null awk 'END { print NR+0 }' < "$path") || return 0
  case "$lines" in ''|*[!0-9]*) return 0 ;; esac
  [ "$lines" -gt "$cap" ] || return 0
  printf 'warning: handoff %s is %s lines, above the %s-line launch cap; the prompt names the path and does not inline the document\n' \
    "$path" "$lines" "$cap" >&2
}

fm_handoff_successor_prompt() { # <path> <sha256> <ack-cmd> <start-cmd> <nonce>
  printf 'Firstmate handoff successor. Read the entire document at %s. Its sha256 must be %s. Before doing any project work or starting a read-only session, run this exact acknowledgement command: %s . It writes your harness pid, lock pid, terminal handle and document hash, and transfers the predecessor lock only after validation. If it refuses, emit no claim of readiness and exit; it records handoff_reject. After success run %s and continue the document. nonce=%s' \
    "$1" "$2" "$3" "$4" "$5"
}
