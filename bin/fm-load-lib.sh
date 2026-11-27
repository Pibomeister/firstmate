#!/usr/bin/env bash
# fm-load-lib.sh - host-load throttling for the periodic monitoring paths.
#
# This file is the single owner of the load probe, the throttle threshold,
# and the interval arithmetic the heartbeat publication (and the fleet
# snapshot it starts) and the watcher cadences share. When the 1-minute
# load average is above 200, periodic monitoring
# runs at four times its ordinary interval;
# when the load falls back, the ordinary interval returns on the very next read, because nothing here is cached.
# An unreadable load never throttles: a broken probe must not stall
# supervision, so it reads as the ordinary interval.
#
#   fm_load1             print the 1-minute load average, or fail
#   fm_load_throttled    succeed when the load is above the threshold
#   fm_load_factor       print the current interval multiplier (1 or the factor)
#   fm_load_interval <n> print <n> scaled by the current multiplier; a base
#                        that is not a positive integer prints unchanged
#
# Test seam: with FM_TEST_SEAM=1 the load comes only from FM_LOAD_FILE,
# whose first word stands in for the 1-minute load, read at every call.
# Under the seam an unset or unreadable FM_LOAD_FILE is an unreadable load,
# never the host's real load, so a suite driving the heartbeat, snapshot,
# or watcher for unrelated behavior stays deterministic on a loaded host.
# Outside the seam the probe reads /proc/loadavg, else sysctl vm.loadavg.
#
# Sourcing this file defines the functions and has no other side effect.

fm_load1() {
  local v=
  if [ "${FM_TEST_SEAM:-}" = 1 ]; then
    [ -n "${FM_LOAD_FILE:-}" ] || return 1
    v=$(awk 'NR==1 { print $1 }' "$FM_LOAD_FILE" 2>/dev/null) || v=
  elif [ -r /proc/loadavg ]; then
    v=$(awk '{ print $1 }' /proc/loadavg 2>/dev/null) || v=
  else
    v=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{ print $1 }') || v=
  fi
  case "$v" in
    ''|.|*[!0-9.]*|*.*.*) return 1 ;;
  esac
  printf '%s\n' "$v"
}

fm_load_throttled() {
  local load
  load=$(fm_load1) || return 1
  awk -v l="$load" 'BEGIN { exit !(l + 0 > 200) }'
}

fm_load_factor() {
  if fm_load_throttled; then
    printf '4\n'
  else
    printf '1\n'
  fi
}

fm_load_interval() {  # <base-seconds>
  local base=${1:-}
  case "$base" in
    ''|*[!0-9]*|0) printf '%s\n' "$base"; return 0 ;;
  esac
  printf '%s\n' $(( 10#$base * $(fm_load_factor) ))
}
