#!/usr/bin/env bash
# fm-incident-ledger.sh - read the incident ledger.
#
# Usage:
#   fm-incident-ledger.sh latest --home <home> --subject <subject> --signal <signal> [--state <state>]
#   fm-incident-ledger.sh rows [--since <epoch>]
#
# The incident ledger (<state>/incident-ledger.tsv; bin/fm-incident-ledger-lib.sh
# owns its columns) holds one row per incident transition, appended by the
# escalation gate and never rewritten.
#
# `latest` prints the latest row for that home, subject and signal in any
# state, or with --state the latest row of that exact key; it prints nothing
# when there is none.
# `rows` prints every well-formed row in ledger order, or with --since only the
# rows whose epoch is at or after <epoch>.
# An absent ledger is an empty one. Neither verb takes the ledger lock.
#
# Refuses, and prints nothing, when a flag is missing, repeated or unknown, or
# --since is not a decimal whole number (exit 1). An unknown subcommand prints
# this usage and exits 2; -h or --help prints it and exits 0.
#
# Environment: FM_HOME selects the home; FM_STATE_OVERRIDE overrides its state
# directory.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
LEDGER_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-incident-ledger-lib.sh
. "$SCRIPT_DIR/fm-incident-ledger-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

fail() {
  printf 'fm-incident-ledger: %s\n' "$*" >&2
  exit 1
}

cmd=${1:-}
case "$cmd" in
  latest|rows) shift ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

home='' subject='' signal='' state='' since=''
seen=' '
while [ "$#" -gt 0 ]; do
  flag=$1
  case "$cmd:$flag" in
    latest:--home|latest:--subject|latest:--signal|latest:--state|rows:--since) ;;
    *) fail "unknown flag for $cmd: $flag" ;;
  esac
  case "$seen" in *" $flag "*) fail "repeated flag: $flag" ;; esac
  seen="$seen$flag "
  [ "$#" -ge 2 ] || fail "missing value for $flag"
  case "$flag" in
    --home) home=$2 ;;
    --subject) subject=$2 ;;
    --signal) signal=$2 ;;
    --state) state=$2 ;;
    --since) since=$2 ;;
  esac
  shift 2
done

case "$cmd" in
  latest)
    [ -n "$home" ] || fail "missing --home"
    [ -n "$subject" ] || fail "missing --subject"
    [ -n "$signal" ] || fail "missing --signal"
    case "$seen" in
      *" --state "*) fm_incident_ledger_latest_key "$LEDGER_STATE" "$home" "$subject" "$signal" "$state" ;;
      *) fm_incident_ledger_latest "$LEDGER_STATE" "$home" "$subject" "$signal" ;;
    esac
    ;;
  rows)
    case "$since" in
      '') since=0 ;;
      *[!0-9]*) fail "--since is not a decimal whole number: $since" ;;
    esac
    _fm_incident_select "$LEDGER_STATE" rows '' '' '' "$since"
    ;;
esac
