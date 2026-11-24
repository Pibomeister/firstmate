#!/usr/bin/env bash
# fm-postmortem-checklist.sh - the overnight postmortem receipt checklist.
#
# The 07:45 overnight-postmortem order is a checklist with one row per
# machine: M3, Studio, Hetzner, and the local home. A row closes only when
# that machine's artifact receipt verifies: the recorded artifact path
# exists as a readable regular file and its sha256 content hash matches
# the hash the receipt recorded (the artifact receipt shape shared with
# the delegated-agent progress contract: path plus content hash). A row
# with no receipt, a missing artifact, or a mismatched hash stays open.
#
# Usage:
#   fm-postmortem-checklist.sh start [--night <YYYY-MM-DD>]
#       Open the checklist for a night. Idempotent; prints the night.
#   fm-postmortem-checklist.sh receipt --machine <name> --path <path> \
#       --hash <sha256> [--night <YYYY-MM-DD>]
#       Record one machine's artifact receipt. Recording never closes a
#       row by itself; it prints that row's verified state after recording.
#   fm-postmortem-checklist.sh check [--night <YYYY-MM-DD>]
#       Print one tab-separated row per machine,
#       <machine><TAB>closed|open<TAB><path-or-reason>, in machine order.
#       Exit 0 only when every row is closed, 1 when any row is open,
#       2 when no checklist exists for the night.
#   fm-postmortem-checklist.sh open [--night <YYYY-MM-DD>]
#       Print only the open rows, in the same shape as `check`.
#       Exit 0; an unopened night lists every machine as missing.
#   fm-postmortem-checklist.sh collect [--since <epoch>]
#       Report existing nights and mornings due at 07:45 through now.
#       Nights name the morning of collection; --night defaults to today.
#       Inbox note bodies may contain a tab-separated receipt line:
#       postmortem-receipt<TAB>night<TAB>machine<TAB>absolute-path<TAB>sha256
#       Pending and handled notes both count; their id supplies the epoch.
#
# State: an append-only tab-separated ledger at
# state/postmortem-checklist.tsv under the home (FM_HOME, or
# FM_STATE_OVERRIDE). Rows are
# <night><TAB><machine><TAB><event><TAB><path><TAB><hash><TAB><epoch>
# with event `opened` (machine `-`, from `start`) or `receipt`. The
# newest ledger or inbox receipt for a machine and night is verified.
# Ledger append order is authoritative within the ledger.
# Cross-record receipt epochs order candidates; conflicting ties stay open.
# A night exists once any row names it, so a receipt recorded before
# `start` still opens the other machines' rows for that night.
#
# This script records and verifies receipts only. It never writes any
# machine's postmortem content. bin/fm-afk-return.sh reads the open rows
# through `collect` and names each unclosed machine in the morning return
# brief's "Waiting on you" section, so a missing machine is named at
# 07:45 rather than silently absent.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LEDGER="$STATE/postmortem-checklist.tsv"

# The fixed machine roster, in checklist order. The local home's row is
# named `local`.
MACHINES="M3 Studio Hetzner local"

usage() {
  sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {  # <message> [code]
  printf 'fm-postmortem-checklist: %s\n' "$1" >&2
  exit "${2:-1}"
}

valid_night() {  # <YYYY-MM-DD>
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

valid_machine() {  # <name>
  local m
  for m in $MACHINES; do
    [ "$m" = "$1" ] && return 0
  done
  return 1
}

valid_hash() {  # <sha256 hex>
  case "$1" in
    *[!0-9a-fA-F]*) return 1 ;;
  esac
  [ "${#1}" -eq 64 ]
}

file_sha256() {  # <file>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

night_exists() {  # <night>
  [ -f "$LEDGER" ] || return 1
  awk -F '\t' -v night="$1" '$1 == night { found = 1 } END { exit !found }' "$LEDGER"
}

# The latest recorded receipt for one machine and night:
# prints <path><TAB><hash>, empty when none was recorded.
latest_receipt() {  # <night> <machine>
  local night=$1 machine=$2 note id epoch
  {
    if [ -f "$LEDGER" ]; then
      awk -F '\t' -v night="$night" -v machine="$machine" '
        $1 == night && $2 == machine && $3 == "receipt" {
          epoch = $6; path = $4; hash = $5
        }
        END { if (path != "") printf "%s\t%s\t%s\n", epoch, path, hash }' "$LEDGER" || return 1
    fi
    for note in "$STATE/inbox/"*.note "$STATE/inbox/handled/"*.note; do
      [ -f "$note" ] || continue
      id=${note##*/}; epoch=${id%%-*}
      case "$epoch" in ''|*[!0-9]*) continue ;; esac
      awk -F '\t' -v epoch="$epoch" -v night="$night" -v machine="$machine" '
        /^--$/ { body = 1; next }
        body && NF == 5 && $1 == "postmortem-receipt" && $2 == night && $3 == machine {
          printf "%s\t%s\t%s\n", epoch, $4, $5
        }' "$note" || return 1
    done
  } | awk -F '\t' '
    $1 ~ /^[0-9]+$/ {
      if (!seen || $1 + 0 > latest) {
        seen = 1; latest = $1 + 0; path = $2; hash = tolower($3); conflict = 0
      } else if ($1 + 0 == latest && ($2 != path || tolower($3) != hash)) {
        conflict = 1
      }
    }
    END {
      if (conflict) exit 1
      if (path != "") printf "%s\t%s\n", path, hash
    }'
}

# One machine's verified row: <machine><TAB>closed|open<TAB><detail>.
machine_row() {  # <night> <machine>
  local night=$1 machine=$2 receipt path hash actual
  if ! receipt=$(latest_receipt "$night" "$machine"); then
    printf '%s\topen\tartifact receipt could not be verified\n' "$machine"
    return 0
  fi
  if [ -z "$receipt" ]; then
    printf '%s\topen\tno artifact receipt recorded\n' "$machine"
    return 0
  fi
  path=$(printf '%s' "$receipt" | cut -f1)
  hash=$(printf '%s' "$receipt" | cut -f2)
  hash=$(printf '%s' "$hash" | tr 'A-F' 'a-f')
  if [[ "$path" != /* ]] || ! valid_hash "$hash"; then
    printf '%s\topen\tinvalid artifact receipt\n' "$machine"
    return 0
  fi
  if [ ! -f "$path" ] || [ ! -r "$path" ]; then
    printf '%s\topen\tartifact missing at recorded path: %s\n' "$machine" "$path"
    return 0
  fi
  if ! actual=$(file_sha256 "$path") || ! valid_hash "$actual"; then
    printf '%s\topen\tartifact hash verification failed for %s\n' "$machine" "$path"
    return 0
  fi
  actual=$(printf '%s' "$actual" | tr 'A-F' 'a-f')
  if [ "$actual" != "$hash" ]; then
    printf '%s\topen\tartifact hash mismatch for %s\n' "$machine" "$path"
    return 0
  fi
  printf '%s\tclosed\t%s\n' "$machine" "$path"
}

print_rows() {  # <night> <all|open>
  local night=$1 mode=$2 machine row state open_count=0
  for machine in $MACHINES; do
    row=$(machine_row "$night" "$machine") || row="$machine"$'\topen\tartifact verification failed'
    state=$(printf '%s' "$row" | cut -f2)
    [ "$state" = open ] && open_count=$((open_count + 1))
    if [ "$mode" = all ] || [ "$state" = open ]; then
      printf '%s\n' "$row"
    fi
  done
  return "$open_count"
}

append_row() {  # <night> <machine> <event> <path> <hash>
  mkdir -p "$STATE" || die "cannot create state directory $STATE"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$(date +%s)" >> "$LEDGER" \
    || die "cannot append to $LEDGER"
}

parse_night() {  # consumes [--night <date>] from $@; prints the night
  local night=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --night)
        [ $# -ge 2 ] || die "--night needs a YYYY-MM-DD date" 2
        night=$2; shift 2 ;;
      *) die "unknown argument: $1" 2 ;;
    esac
  done
  [ -n "$night" ] || night=$(date +%F)
  valid_night "$night" || die "night must be YYYY-MM-DD, got: $night" 2
  printf '%s' "$night"
}

cmd_start() {
  local night
  night=$(parse_night "$@") || exit $?
  if ! night_exists "$night"; then
    append_row "$night" - opened "" ""
  fi
  printf 'night=%s machines=%s\n' "$night" "$MACHINES"
}

cmd_receipt() {
  local machine="" path="" hash="" night=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --machine) [ $# -ge 2 ] || die "--machine needs a name" 2; machine=$2; shift 2 ;;
      --path) [ $# -ge 2 ] || die "--path needs a path" 2; path=$2; shift 2 ;;
      --hash) [ $# -ge 2 ] || die "--hash needs a sha256 hash" 2; hash=$2; shift 2 ;;
      --night) [ $# -ge 2 ] || die "--night needs a YYYY-MM-DD date" 2; night=$2; shift 2 ;;
      *) die "unknown argument: $1" 2 ;;
    esac
  done
  [ -n "$machine" ] || die "receipt needs --machine <name>" 2
  valid_machine "$machine" || die "unknown machine: $machine (expected one of: $MACHINES)" 2
  [ -n "$path" ] || die "receipt needs --path <path>" 2
  case "$path" in
    *$'\t'*|*$'\r'*|*$'\n'*) die "artifact path contains a ledger delimiter" 2 ;;
    /*) ;;
    *) path="$PWD/$path" ;;
  esac
  [ -n "$hash" ] || die "receipt needs --hash <sha256>" 2
  valid_hash "$hash" || die "hash must be 64 hex sha256 characters" 2
  hash=$(printf '%s' "$hash" | tr 'A-F' 'a-f')
  [ -n "$night" ] || night=$(date +%F)
  valid_night "$night" || die "night must be YYYY-MM-DD, got: $night" 2
  append_row "$night" "$machine" receipt "$path" "$hash"
  machine_row "$night" "$machine"
}

cmd_check() {  # <all|open> [args...]
  local mode=$1
  shift
  local night open_count
  night=$(parse_night "$@") || exit $?
  if [ "$mode" = all ]; then
    night_exists "$night" || die "no postmortem checklist for night $night" 2
  fi
  print_rows "$night" "$mode"
  open_count=$?
  if [ "$mode" = all ]; then
    [ "$open_count" -eq 0 ]
    return
  fi
  return 0
}

cmd_collect() {
  local since="" now nights night machine state detail rc=0
  now=$(date +%s) || return 1
  while [ $# -gt 0 ]; do
    case "$1" in
      --since) [ $# -ge 2 ] || die "--since needs an epoch" 2; since=$2; shift 2 ;;
      *) die "unknown argument: $1" 2 ;;
    esac
  done
  nights=$(python3 - "$since" "$now" "$LEDGER" <<'PYDATES'
import datetime as dt
import sys
from pathlib import Path

end = dt.datetime.fromtimestamp(int(sys.argv[2]))
start = dt.datetime.fromtimestamp(int(sys.argv[1])) if sys.argv[1] else end.replace(hour=0, minute=0, second=0, microsecond=0)
nights = set()
ledger = Path(sys.argv[3])
if ledger.exists():
    for row in ledger.read_text().splitlines():
        night = dt.date.fromisoformat(row.split("\t", 1)[0])
        if night <= end.date():
            nights.add(night)
day = start.date()
while day <= end.date():
    due = dt.datetime.combine(day, dt.time(7, 45))
    if due <= end and (due >= start or day == end.date()):
        nights.add(day)
    day += dt.timedelta(days=1)
for night in sorted(nights):
    print(night.isoformat())
PYDATES
  ) || {
    for machine in $MACHINES; do
      printf '%s\topen\tpostmortem collection failed; receipts unverified\n' "$machine"
    done
    return 1
  }
  while IFS= read -r night; do
    [ -n "$night" ] || continue
    (cmd_start --night "$night") >/dev/null || rc=1
    cmd_check open --night "$night" | while IFS=$'\t' read -r machine state detail; do
      printf '%s\t%s\t%s: %s\n' "$machine" "$state" "$night" "$detail"
    done || rc=1
  done <<< "$nights"
  return "$rc"
}

case "${1:-}" in
  collect) shift; cmd_collect "$@" ;;
  start) shift; cmd_start "$@" ;;
  receipt) shift; cmd_receipt "$@" ;;
  check) shift; cmd_check all "$@" ;;
  open) shift; cmd_check open "$@" ;;
  --help|-h|help|"") usage ;;
  *) die "unknown command: $1 (expected start, receipt, check, open, or collect)" 2 ;;
esac
