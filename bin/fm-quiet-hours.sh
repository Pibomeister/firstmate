#!/usr/bin/env bash
# fm-quiet-hours.sh - read the quiet-hours clock.
#
# Usage:
#   fm-quiet-hours.sh at [<epoch>]
#
# `at` prints the quiet-hours reading for <epoch> or, with none, for now
# (fm_now). bin/fm-quiet-hours-lib.sh's header owns the output lines, the
# windows and the quiet-hours-zone key.
#
# Refuses, and prints nothing on stdout, when <epoch> is not a decimal whole
# number or a second argument is given (exit 1), when the configured zone is
# unknown (exit 3), or when date cannot convert the moment (exit 4). An unknown
# subcommand prints this usage and exits 2; -h or --help prints it and exits 0.
#
# Environment: FM_HOME selects the home; FM_CONFIG_OVERRIDE overrides its
# config directory.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-quiet-hours-lib.sh
. "$SCRIPT_DIR/fm-quiet-hours-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

fail() {
  printf 'fm-quiet-hours: %s\n' "$*" >&2
  exit 1
}

case "${1:-}" in
  at) shift ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

[ "$#" -le 1 ] || fail "at takes at most one epoch"
rc=0
fm_quiet_hours_at "$@" || rc=$?
case "$rc" in
  0) ;;
  2) exit 1 ;;
  3) exit 3 ;;
  *) exit 4 ;;
esac
