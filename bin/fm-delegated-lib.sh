#!/usr/bin/env bash
# fm-delegated-lib.sh - pure helpers for the delegated-agent progress contract.
#
# Sourced, never executed, with no side effects on source.
# bin/fm-delegated.sh owns the records and the commands; this library owns
# the hash, identifier, and state-derivation rules so tests can pin them
# without a home on disk.
#
# Contract (tickets 3a and 9b, council fm-fable-rca-1108):
# - Every delegated task records a named deliverable, a heartbeat interval,
#   a silence window, and a deliverable receipt bound to artifact path plus
#   content hash.
# - A dispatch-only receipt is never progress: a task whose only receipt is
#   dispatch renders as dispatched-not-progressing in the supervisor view.
# - A missing artifact or a hash mismatch can never close a deliverable.
# - A cross-agent handoff filed only outside the receiver's read location
#   is a delivery failure naming the hidden item, never silence.
# - Once a handoff is mirrored into the read location, the receiver's read
#   is receipted against the same path-plus-hash receipt.
#
# Functions:
#   fm_del_now
#       Prints the delegated clock: FM_DELEGATED_NOW under FM_TEST_SEAM=1,
#       else the current epoch.
#   fm_del_sha256 <file>
#       Prints the SHA-256 of <file>, or returns 1 with no output.
#   fm_del_valid_id <id>
#       Returns 0 for a task or handoff id: 1-128 chars of A-Za-z0-9._-,
#       never starting with a dot and never holding `..` or a slash.
#   fm_del_valid_hash <hash>
#       Returns 0 for exactly 64 hexadecimal characters.
#   fm_del_record_get <file> <key>
#       Prints the last `key=value` value in <file>, or nothing.
#   fm_del_task_state <closed> <has-progress> <last-kind> <dispatched-at>
#       Prints closed, progressing, dispatched-not-progressing, or registered.
#   fm_del_verify_artifact <path> <expected-hash>
#       Prints ok, missing, or mismatch and returns 0, 1, or 2 respectively.
#       An empty or invalid expected hash is a mismatch by construction, so
#       an unbound receipt can never verify.
#   fm_del_silence_age <now> <last-activity> <silence-secs>
#       Prints the silence age and returns 0 when it exceeds the window,
#       else returns 1 with no output.

fm_del_now() {
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_DELEGATED_NOW:-}" ]; then
    case "$FM_DELEGATED_NOW" in ''|*[!0-9]*) date +%s ;; *) printf '%s\n' "$FM_DELEGATED_NOW" ;; esac
  else
    date +%s
  fi
}

fm_del_sha256() {  # <file>
  [ -f "$1" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

fm_del_valid_id() {  # <id>
  case "$1" in ''|.*|*..*|*/*) return 1 ;; esac
  [ "${#1}" -le 128 ] || return 1
  case "$1" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

fm_del_valid_hash() {  # <hash>
  [ "${#1}" -eq 64 ] || return 1
  case "$1" in *[!0-9a-fA-F]*) return 1 ;; esac
  return 0
}

fm_del_record_get() {  # <file> <key>
  [ -f "$1" ] || return 0
  awk -v k="$2" '
    { i = index($0, "="); if (i == 0) next
      if (substr($0, 1, i - 1) == k) { v = substr($0, i + 1); found = 1 } }
    END { if (found) print v }
  ' "$1" 2>/dev/null
}

fm_del_task_state() {  # <closed> <has-progress> <last-kind> <dispatched-at>
  if [ "$1" = 1 ]; then printf 'closed\n'; return 0; fi
  if [ "$2" = 1 ]; then printf 'progressing\n'; return 0; fi
  case "$3" in
    dispatch) printf 'dispatched-not-progressing\n'; return 0 ;;
  esac
  if [ -n "$4" ]; then printf 'dispatched-not-progressing\n'; return 0; fi
  printf 'registered\n'
}

fm_del_verify_artifact() {  # <path> <expected-hash>
  local path=$1 want=$2 actual
  want=$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')
  fm_del_valid_hash "$want" || { printf 'mismatch\n'; return 2; }
  [ -f "$path" ] || { printf 'missing\n'; return 1; }
  actual=$(fm_del_sha256 "$path") || { printf 'missing\n'; return 1; }
  if [ "$actual" = "$want" ]; then printf 'ok\n'; return 0; fi
  printf 'mismatch\n'
  return 2
}

fm_del_silence_age() {  # <now> <last-activity> <silence-secs>
  local now=$1 last=$2 window=$3 age
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  case "$window" in ''|*[!0-9]*|0) return 1 ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  age=$((now - last))
  [ "$age" -gt "$window" ] || return 1
  printf '%s\n' "$age"
}
