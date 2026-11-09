#!/usr/bin/env bash
# fm-incident-ledger-lib.sh - the append-only incident ledger: one row per
# incident transition, which the escalation gate alone writes.
# bin/fm-incident-ledger.sh reads it.
#
# The ledger is <state>/incident-ledger.tsv, one tab-separated row per
# transition:
#   id  epoch  home  subject  signal  state  class  episode  cause  reserved  action
# id is `t<N>`, one more than the highest id in the ledger, starting at t1.
# epoch is fm_now (bin/fm-clock-lib.sh). An incident key is home, subject,
# signal and state (fm_incident_key). class is the exception class or
# `routine`. cause and reserved are `-` when empty. action is one of escalate,
# delta, closure, hold or record. Rows are appended and never rewritten, so a
# key's latest row is its last row in the file.
#
# Every value is made tab- and newline-free the way bin/fm-watchdog-lib.sh's
# _fm_wd_field does, and every reader applies the same rule to the values it
# looks up, so a lookup with the raw value finds its row.
#
# A writer holds the ledger lock (<state>/.incident-ledger.lock, taken with
# fm_lock_acquire_wait in bin/fm-wake-lib.sh) around each append, so concurrent
# writers lose no row and never share an id. Readers take no lock and skip a
# row without eleven columns, a `t<N>` id and a decimal epoch; that rule lives
# only in _fm_incident_select, which every reader uses. An absent ledger reads
# as empty.

FM_INCIDENT_LEDGER_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; CDPATH='' cd -- "${d:-/}" && pwd)"
# shellcheck source=bin/fm-clock-lib.sh
. "$FM_INCIDENT_LEDGER_LIB_DIR/fm-clock-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_INCIDENT_LEDGER_LIB_DIR/fm-wake-lib.sh"

# fm_incident_ledger_path <state-dir>: the incident ledger of that state directory.
fm_incident_ledger_path() {
  printf '%s/incident-ledger.tsv\n' "$1"
}

# fm_incident_ledger_lock <state-dir>: take the ledger lock, waiting for a live
# holder. Returns non-zero when the state directory does not exist.
fm_incident_ledger_lock() {
  fm_lock_acquire_wait "$1/.incident-ledger.lock"
}

# fm_incident_ledger_unlock <state-dir>: release the ledger lock.
fm_incident_ledger_unlock() {
  fm_lock_release "$1/.incident-ledger.lock"
}

# _fm_incident_field <text>: the value with tabs and newlines made spaces.
_fm_incident_field() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-600
}

# fm_incident_key <home> <subject> <signal> <state>: print the incident key.
fm_incident_key() {
  printf '%s|%s|%s|%s\n' "$(_fm_incident_field "$1")" "$(_fm_incident_field "$2")" \
    "$(_fm_incident_field "$3")" "$(_fm_incident_field "$4")"
}

# fm_incident_ledger_append_locked <state-dir> <home> <subject> <signal> <state> <class> <episode> <cause> <reserved> <action>
# Append one transition row and print its id. The caller holds the ledger
# lock. Exit 2, writing nothing, on an unknown action or an empty home,
# subject, signal, state, class or episode.
fm_incident_ledger_append_locked() {
  local dir=$1 ledger epoch next home subject signal state class episode cause reserved action
  home=$(_fm_incident_field "$2")
  subject=$(_fm_incident_field "$3")
  signal=$(_fm_incident_field "$4")
  state=$(_fm_incident_field "$5")
  class=$(_fm_incident_field "$6")
  episode=$(_fm_incident_field "$7")
  cause=$(_fm_incident_field "${8:-}")
  reserved=$(_fm_incident_field "${9:-}")
  action=${10:-}
  case "$action" in
    escalate|delta|closure|hold|record) ;;
    *) printf 'fm-incident-ledger: invalid action: %s\n' "$action" >&2; return 2 ;;
  esac
  if [ -z "$home" ] || [ -z "$subject" ] || [ -z "$signal" ] || [ -z "$state" ] \
    || [ -z "$class" ] || [ -z "$episode" ]; then
    printf 'fm-incident-ledger: home, subject, signal, state, class and episode must be non-empty\n' >&2
    return 2
  fi
  [ -n "$cause" ] || cause=-
  [ -n "$reserved" ] || reserved=-
  ledger=$(fm_incident_ledger_path "$dir")
  next=1
  if [ -f "$ledger" ]; then
    next=$(LC_ALL=C awk -F '\t' '$1 ~ /^t[0-9]+$/ { n = substr($1, 2) + 0; if (n > max) max = n }
      END { print max + 1 }' "$ledger") || return 1
  fi
  epoch=$(fm_now) || return 1
  printf 't%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$next" "$epoch" "$home" "$subject" \
    "$signal" "$state" "$class" "$episode" "$cause" "$reserved" "$action" >> "$ledger" || return 1
  printf 't%s\n' "$next"
}

# _fm_incident_select <state-dir> <mode> <home> <subject> <signal> [<state>|<episode>|<since>]
# mode `latest` prints the last row matching home, subject and signal; `key`
# the last row also matching state; `episode` every row also matching episode;
# `rows` ignores home, subject and signal and prints every row whose epoch is
# at or after <since> (default 0).
_fm_incident_select() {
  local ledger
  ledger=$(fm_incident_ledger_path "$1")
  [ -f "$ledger" ] || return 0
  _FM_INC_MODE=$2 _FM_INC_HOME=$(_fm_incident_field "$3") _FM_INC_SUBJECT=$(_fm_incident_field "$4") \
    _FM_INC_SIGNAL=$(_fm_incident_field "$5") _FM_INC_EXTRA=$(_fm_incident_field "${6:-}") \
    LC_ALL=C awk -F '\t' '
      BEGIN {
        # Each value is made a string so every match compares text: 01 is not 1.
        mode = ENVIRON["_FM_INC_MODE"] ""; home = ENVIRON["_FM_INC_HOME"] ""
        subject = ENVIRON["_FM_INC_SUBJECT"] ""; signal = ENVIRON["_FM_INC_SIGNAL"] ""
        extra = ENVIRON["_FM_INC_EXTRA"] ""
      }
      NF != 11 || $1 !~ /^t[0-9]+$/ || $2 !~ /^[0-9]+$/ { next }
      mode == "rows" { if ($2 + 0 >= extra + 0) print; next }
      $3 != home || $4 != subject || $5 != signal { next }
      mode == "key" && $6 != extra { next }
      mode == "episode" { if ($8 == extra) print; next }
      { last = $0; found = 1 }
      END { if (found) print last }
    ' "$ledger"
}

# fm_incident_ledger_latest <state-dir> <home> <subject> <signal>: print the
# latest row for that home, subject and signal in any state, or nothing.
fm_incident_ledger_latest() {
  _fm_incident_select "$1" latest "$2" "$3" "$4"
}

# fm_incident_ledger_latest_key <state-dir> <home> <subject> <signal> <state>:
# print the latest row of that exact key, or nothing.
fm_incident_ledger_latest_key() {
  _fm_incident_select "$1" key "$2" "$3" "$4" "$5"
}

# fm_incident_ledger_episode_rows <state-dir> <home> <subject> <signal> <episode>:
# print every row of that episode in ledger order, or nothing.
fm_incident_ledger_episode_rows() {
  _fm_incident_select "$1" episode "$2" "$3" "$4" "$5"
}
