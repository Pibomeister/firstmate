#!/usr/bin/env bash
# fm-wake-ledger.sh - count and list wake-ledger rows over a time window.
#
# Usage:
#   fm-wake-ledger.sh count --since <epoch> --until <epoch>
#   fm-wake-ledger.sh rows  --since <epoch> --until <epoch>
#
# The wake ledger (<state>/wake-ledger.tsv; bin/fm-wake-ledger-lib.sh owns its
# columns) holds one row for every removal from the wake queue. A row belongs
# to the window when since <= epoch < until. Every wake count reads this
# ledger, never the drained wake queue.
#
# `rows` prints the window rows unchanged.
# `count` prints one line
#   reference=<n> highest=<n> span=<n> unlisted=<n> late=<n> count=<n>
# where reference is the highest sequence number any row before the window
# lists (0 when none), highest is the highest sequence number a window row
# lists, or reference when no window row lists one above it, span is highest
# minus reference, unlisted is how many sequence numbers in (reference,
# highest] no window row lists, late is how many distinct sequence numbers
# window rows list at or below reference, and count is span - unlisted + late:
# the number of distinct sequence numbers the window rows list.
# So a pruned or retired wake counts, a sequence number that was minted but
# never written as a queue row is listed by no row and never counts, and a wake
# still queued at a window's end counts in the window of the row that later
# removes it.
# An absent ledger is an empty one. Rows without six columns, a numeric epoch,
# and a comma-separated sequence list are skipped.
#
# Refuses, and prints nothing, when a flag is missing, repeated, unknown, or not
# a decimal whole number, or when since is after until (exit 1). An unknown
# subcommand prints this usage and exits 2; -h or --help prints it and exits 0.
#
# Environment: FM_HOME selects the home; FM_STATE_OVERRIDE overrides its state
# directory.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-wake-ledger-lib.sh
. "$SCRIPT_DIR/fm-wake-ledger-lib.sh"
LEDGER=$(fm_wake_ledger_path "$STATE")

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

fail() {
  printf 'fm-wake-ledger: %s\n' "$*" >&2
  exit 1
}

cmd=${1:-}
case "$cmd" in
  count|rows) shift ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

since=
until=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --since|--until)
      [ "$#" -ge 2 ] || fail "$1 needs a value"
      case "$2" in ''|*[!0-9]*) fail "$1 must be a decimal whole number: $2" ;; esac
      if [ "$1" = --since ]; then
        [ -z "$since" ] || fail "--since given twice"
        since=$((10#$2))
      else
        [ -z "$until" ] || fail "--until given twice"
        until=$((10#$2))
      fi
      shift 2
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[ -n "$since" ] || fail "--since is required"
[ -n "$until" ] || fail "--until is required"
[ "$since" -le "$until" ] || fail "--since $since is after --until $until"

[ -f "$LEDGER" ] || LEDGER=/dev/null

if [ "$cmd" = rows ]; then
  awk -F '\t' -v since="$since" -v until="$until" '
    NF == 6 && $1 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+(,[0-9]+)*$/ && $1 + 0 >= since + 0 && $1 + 0 < until + 0
  ' "$LEDGER"
  exit 0
fi

awk -F '\t' -v since="$since" -v until="$until" '
  NF == 6 && $1 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+(,[0-9]+)*$/ {
    n = split($5, seq, ",")
    if ($1 + 0 < since + 0) {
      for (i = 1; i <= n; i++) if (seq[i] + 0 > reference) reference = seq[i] + 0
    } else if ($1 + 0 < until + 0) {
      for (i = 1; i <= n; i++) listed[seq[i] + 0] = 1
    }
  }
  END {
    reference += 0
    highest = reference
    above = 0
    late = 0
    for (s in listed) {
      if (s + 0 > reference) { above++; if (s + 0 > highest) highest = s + 0 }
      else late++
    }
    span = highest - reference
    unlisted = span - above
    printf "reference=%d highest=%d span=%d unlisted=%d late=%d count=%d\n", \
      reference, highest, span, unlisted, late, span - unlisted + late
  }
' "$LEDGER"
