#!/usr/bin/env bash
# fm-stall-ledger.sh - record and score the automatic stall ledger.
#
# Usage:
#   fm-stall-ledger.sh observe
#   fm-stall-ledger.sh rows --since <epoch> --until <epoch>
#   fm-stall-ledger.sh score --since <epoch> --until <epoch>
#   fm-stall-ledger.sh score --kickoff <epoch>
#   fm-stall-ledger.sh window --kickoff <epoch>
#   fm-stall-ledger.sh window --since <epoch> --until <epoch>
#
# bin/fm-stall-ledger-lib.sh owns the row schema and the observe sources.
# This file owns the score bars and which human-intervention events count.
#
# `observe` appends rows for this home from the heartbeat, secondmate progress
# markers, the wake queue, the watchdog action log, verified handoffs, sent
# orders, and inbox notes. Rows are appended and never rewritten. The
# supervision poll calls observe at most once a minute, and a failure there
# does not stop supervision.
# `rows` prints the well-formed rows whose epoch is in [since, until).
# `score` prints PASS or FAIL for that window, then one citation per failing
# bar. A citation is the bar name, a tab, and the ledger row.
# stall-duration, stall-open, and stall-recovery cite the open row.
# stall-recoverer cites the close row. A human close also cites intervention.
# `window` prints `since=<epoch> until=<epoch>`. With --kickoff, until is the
# next 08:00 America/Chicago strictly after the kickoff.
#
# A stall counts when end minus start is over 600 seconds. End is the recovery
# time when a close recovers before until, and until otherwise. The stall is in
# the window when start is before until and end is after since.
# Recovery within 20 minutes means recover minus detect is at most 1200 seconds.
# None over 30 minutes means duration is at most 1800 seconds.
# A heartbeat age, the sample epoch minus the published epoch, fails when it is
# over 600 seconds unless a verified handoff of the same class and subject
# covers that sample and the handoff itself is at most 600 seconds.
# A gap over 600 seconds between primary heartbeat samples, including from
# since to the first sample and from the last sample to until, fails. A
# handoff does not cover a gap. A window with no primary sample fails
# heartbeat-missing. A secondmate sample does not fill that gap.
# A human intervention fails the window when that row's own epoch is inside it.
# The counted rows are an order sent and an inbox note still waiting. An order
# or note outside the window does not make a later close human. A stall whose
# recoverer field is already human still fails, and that close is cited as an
# intervention when its recover epoch is inside the window.
# Exactly 600 seconds of duration does not count. Exactly 1200 seconds of
# recovery latency passes. Exactly 1800 seconds of duration passes. Exactly
# 600 seconds of age passes. Exactly 600 seconds between samples passes.
#
# Exit 0 is observe success, rows, a PASS score, window, or help. Exit 1 is a
# bad flag, an observe write failure, or a FAIL score. An unknown subcommand
# prints this usage and exits 2. -h or --help prints it and exits 0.
# since must be a whole number strictly before until. An absent ledger scores
# as empty and fails heartbeat-missing.
#
# Environment: FM_HOME selects the home. FM_STATE_OVERRIDE overrides its state
# directory. FM_DATA_OVERRIDE overrides its data directory.
# FM_STALL_LEDGER_MIN_SECS (default 60, 0 disables) is the only observe throttle.
# FM_TEST_SEAM=1 and FM_NOW pin the clock (bin/fm-clock-lib.sh).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-bash-compat-lib.sh
. "$SCRIPT_DIR/fm-bash-compat-lib.sh"
# shellcheck source=bin/fm-stall-ledger-lib.sh
. "$SCRIPT_DIR/fm-stall-ledger-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

fail() {
  printf 'fm-stall-ledger: %s\n' "$*" >&2
  exit 1
}

decimal() { # <flag> <value>
  case "$2" in
    ''|*[!0-9]*) fail "$1 must be a decimal whole number: $2" ;;
  esac
  printf '%s\n' "$((10#$2))"
}

cmd=${1:-}
case "$cmd" in
  observe|rows|score|window) shift ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

since=
until=
kick=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --since|--until|--kickoff)
      [ "$#" -ge 2 ] || fail "$1 needs a value"
      value=$(decimal "$1" "$2")
      case "$1" in
        --since)
          [ -z "$since" ] || fail "--since given twice"
          since=$value
          ;;
        --until)
          [ -z "$until" ] || fail "--until given twice"
          until=$value
          ;;
        --kickoff)
          [ -z "$kick" ] || fail "--kickoff given twice"
          kick=$value
          ;;
      esac
      shift 2
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done

require_window() {
  if [ -n "$kick" ]; then
    [ -z "$since" ] && [ -z "$until" ] || fail "--kickoff replaces --since and --until"
    since=$kick
    until=$(fm_stall_ledger_until "$kick") || fail "could not resolve the window"
  fi
  [ -n "$since" ] || fail "--since is required"
  [ -n "$until" ] || fail "--until is required"
  [ "$since" -lt "$until" ] || fail "--since $since is not before --until $until"
}

case "$cmd" in
  observe)
    [ -z "$since$until$kick" ] || fail "observe takes no flags"
    fm_stall_ledger_observe
    ;;
  rows)
    [ -z "$kick" ] || fail "rows does not take --kickoff"
    require_window
    fm_stall_ledger_rows "$since" "$until"
    ;;
  score)
    require_window
    fm_stall_ledger_score "$since" "$until"
    ;;
  window)
    require_window
    printf 'since=%s until=%s\n' "$since" "$until"
    ;;
esac
