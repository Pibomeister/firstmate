#!/usr/bin/env bash
# Shared verified-handoff contract. Callers source session-lock-lib and wake-lib.
# Pending claim: state/.handoff-pending JSON version=1, nonce, handoff, sha256,
# predecessor_pid/start, deadline (Unix seconds). Only the owning predecessor
# creates it. The successor reads the document and calls fm-handoff-ack.sh.
# Ack: data/handoff-ack-<nonce>.json version=1, nonce, harness_pid, fm_lock_pid,
# harness_start, terminal_handle, sha256. fm_lock_pid is the proposed anchor;
# it becomes authoritative only after fm-lock.sh validates it under .lock.acquire
# and .fm-lease-command.lock and replaces the predecessor. An ack alone never
# clears the Stop gate. Expired/nonmatching claims cannot transfer a live lock.
# The completed state/.handoff-successor carries pid, nonce, handoff, sha256.
#
# Watchdog wire format (stdout and append-only state/handoff-events.log):
# HANDOFF v1 ts=<epoch> event=<handoff_started|handoff_retry|handoff_ack|handoff_failed|handoff_reject>
#   nonce=<hex-or-none> attempt=<0|1|2> pid=<digits-or-0> handle=<safe-token-or-none> reason=<safe-token>
# Each event is ONE line, fields in that order; no prose or paths on the wire.
# reason=lock_held_unbound (always nonce=none) is a refused session during a
# live claim that did not present the claim's nonce. It is NOT a successor
# reject and must not end an attempt; only a nonce-bound handoff_reject does.

fm_handoff_event() { # <event> <nonce> <attempt> <pid> <handle> <reason>
  local line handle=$5 nonce=$2 pid=$4
  case "$handle" in ''|*[!A-Za-z0-9_.:%-]*) handle=none ;; esac
  case "$nonce" in ''|*[!a-f0-9]*) nonce=none ;; esac
  case "$pid" in ''|*[!0-9]*) pid=0 ;; esac
  line="HANDOFF v1 ts=$(date +%s) event=$1 nonce=$nonce attempt=$3 pid=$pid handle=$handle reason=$6"
  printf '%s\n' "$line" >> "$STATE/handoff-events.log"
  printf '%s\n' "$line"
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

fm_handoff_can_transfer() { # <new-anchor> <recorded-predecessor>
  local claim="$STATE/.handoff-pending" nonce doc sha pred_start deadline
  [ -n "${FM_HANDOFF_NONCE:-}" ] || return 1
  [ -f "$claim" ] && [ ! -L "$claim" ] || return 1
  nonce=$(jq -er '.nonce | select(type == "string")' "$claim") || return 1
  [ "$nonce" = "$FM_HANDOFF_NONCE" ] || return 1
  jq -e --arg old "$2" '.version == 1 and (.predecessor_pid | tostring) == $old and (.deadline | type == "number")' "$claim" >/dev/null || return 1
  deadline=$(jq -r .deadline "$claim")
  [ "$(date +%s)" -lt "$deadline" ] || return 1
  [ "$1" != "$2" ] || return 1
  pred_start=$(fm_session_process_start "$2") || return 1
  [ "$pred_start" = "$(jq -r .predecessor_start "$claim")" ] || return 1
  doc=$(jq -er .handoff "$claim") || return 1
  sha=$(jq -er .sha256 "$claim") || return 1
  fm_handoff_ack_valid "$nonce" "$doc" "$sha" "$1" || return 1
  [ "$(date +%s)" -lt "$deadline" ]
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
