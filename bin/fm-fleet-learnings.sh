#!/usr/bin/env bash
# Emit the tracked fleet learnings file for session-start and AFK preflight.
#
# Usage:
#   fm-fleet-learnings.sh digest
#
# `digest` prints the labeled subsection consumed by fm-session-start.sh and
# fm-afk-preflight.sh. A missing file prints ABSENT and still exits 0 so startup
# and away entry never block on learnings propagation lag.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_FLEET_LEARNINGS_REL=docs/learnings/overnight-learnings.md
FM_FLEET_LEARNINGS_LABEL='docs/learnings/overnight-learnings.md (tracked fleet learnings; read at session start and each AFK preflight)'

usage() {
  sed -n '2,9{s/^# \{0,1\}//;p;}' "$0"
}

fm_fleet_learnings_root() {
  printf '%s\n' "${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
}

cmd_digest() {
  local root path
  root=$(fm_fleet_learnings_root) || return 1
  path="$root/$FM_FLEET_LEARNINGS_REL"
  printf '\n%s\n%s\n' "$FM_FLEET_LEARNINGS_LABEL" '--------------------------------------------------------------------------------'
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      cat "$path"
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
  return 0
}

case "${1:-}" in
  digest)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    cmd_digest
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  '')
    usage >&2
    exit 2
    ;;
  *)
    printf 'fm-fleet-learnings: unknown command: %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac
