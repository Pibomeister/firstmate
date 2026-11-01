#!/usr/bin/env bash
# fm-disk-alarm.sh - read free space on /System/Volumes/Data before a launch.
#
# Usage:
#   fm-disk-alarm.sh
#       Print the reading and exit 0. ok, warn, pause, stop, absent, and
#       unreadable are all readings. This mode never refuses.
#   fm-disk-alarm.sh --gate crew
#       A fresh crewmate or scout launch. Exit 1 on pause, stop, or unreadable.
#       Exit 0 on ok, warn, and absent.
#   fm-disk-alarm.sh --gate lane
#       A new lane, worktree, or validation run. Exit 1 on stop or unreadable.
#       Exit 0 on ok, warn, pause, and absent.
#   fm-disk-alarm.sh --help
#
# The volume is /System/Volumes/Data. When that path is not a directory, including
# when it is a file, the alarm is not in force: both gates allow, and df is not
# called. A directory whose free space cannot be read is unreadable. Both gates
# refuse unreadable the same way they refuse a stop.
#
# Levels are strict less-than comparisons of df -Pk Available, in 1024-byte
# blocks. This header is the only statement of the numbers:
#   under 5 GiB  (5242880)  stop
#   under 10 GiB (10485760) pause
#   under 15 GiB (15728640) warn
#   otherwise               ok
# Exactly 15 GiB is ok. Exactly 10 GiB is warn. Exactly 5 GiB is pause.
# A stop includes pause and warn. A pause includes warn.
#
# Stdout is one machine line, except --help and a usage error, which print
# nothing on stdout and do not probe:
#   disk-alarm: level=<ok|warn|pause|stop|absent|unreadable> free_kib=<n|unknown> volume=<path>
#
# Stderr carries one human line for warn, pause, stop, and unreadable, including
# when a gate allows:
#   disk-alarm: WARN free space on <volume> is under 15 GiB (<gib> GiB free); tell the captain. Launch may continue.
#   disk-alarm: PAUSE free space on <volume> is under 10 GiB (<gib> GiB free); no new crewmate launch. Place this work on another host or cloud. Do not retry it on this host.
#   disk-alarm: STOP free space on <volume> is under 5 GiB (<gib> GiB free); no new lane, worktree, or gate. Place this work on another host or cloud. Do not retry it on this host.
#   disk-alarm: STOP free space on <volume> could not be read; no new lane, worktree, or gate. Place this work on another host or cloud. Do not retry it on this host.
# <gib> is free_kib / 1048576 printed to one decimal. A value that is still
# under a threshold can round to that threshold's whole number. The level and
# the "under N GiB" phrase are the decision.
#
# Exit 2 is a usage error: an unknown flag, --gate without crew or lane, or
# extra arguments. Usage errors do not probe.
#
# FM_DISK_ALARM_VOLUME replaces the volume only when FM_TEST_SEAM=1. Any other
# launch probes /System/Volumes/Data.
#
# This script does not notify a leash. A separate host check does that.
# "tell the captain" is an instruction to whoever reads a warn line.
# A refusal is not a retry on this host. Place the work on another host or cloud.
set -u

WARN_KIB=15728640
PAUSE_KIB=10485760
STOP_KIB=5242880
KIB_PER_GIB=1048576
DEFAULT_VOLUME=/System/Volumes/Data

usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

usage_error() {
  echo "usage: fm-disk-alarm.sh [--gate crew|lane|--help]" >&2
  exit 2
}

kib_below() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'
}

gib_of() {
  awk -v k="$1" -v d="$2" 'BEGIN { printf "%.1f", k / d }'
}

gate=
if [ $# -eq 0 ]; then
  :
elif [ $# -eq 1 ] && { [ "$1" = --help ] || [ "$1" = -h ]; }; then
  usage
  exit 0
elif [ $# -eq 2 ] && [ "$1" = --gate ]; then
  case "$2" in
    crew | lane) gate=$2 ;;
    *) usage_error ;;
  esac
else
  usage_error
fi

volume=$DEFAULT_VOLUME
if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_DISK_ALARM_VOLUME:-}" ]; then
  volume=$FM_DISK_ALARM_VOLUME
fi

level=absent
free=unknown
if [ -d "$volume" ]; then
  avail=$(df -Pk "$volume" 2>/dev/null | awk 'NR == 2 { print $4 }') || avail=
  case "$avail" in
    '' | *[!0-9]*)
      level=unreadable
      free=unknown
      ;;
    *)
      free=$avail
      if kib_below "$free" "$STOP_KIB"; then
        level=stop
      elif kib_below "$free" "$PAUSE_KIB"; then
        level=pause
      elif kib_below "$free" "$WARN_KIB"; then
        level=warn
      else
        level=ok
      fi
      ;;
  esac
fi

printf 'disk-alarm: level=%s free_kib=%s volume=%s\n' "$level" "$free" "$volume"

case "$level" in
  warn)
    gib=$(gib_of "$free" "$KIB_PER_GIB")
    printf 'disk-alarm: WARN free space on %s is under 15 GiB (%s GiB free); tell the captain. Launch may continue.\n' \
      "$volume" "$gib" >&2
    ;;
  pause)
    gib=$(gib_of "$free" "$KIB_PER_GIB")
    printf 'disk-alarm: PAUSE free space on %s is under 10 GiB (%s GiB free); no new crewmate launch. Place this work on another host or cloud. Do not retry it on this host.\n' \
      "$volume" "$gib" >&2
    ;;
  stop)
    gib=$(gib_of "$free" "$KIB_PER_GIB")
    printf 'disk-alarm: STOP free space on %s is under 5 GiB (%s GiB free); no new lane, worktree, or gate. Place this work on another host or cloud. Do not retry it on this host.\n' \
      "$volume" "$gib" >&2
    ;;
  unreadable)
    printf 'disk-alarm: STOP free space on %s could not be read; no new lane, worktree, or gate. Place this work on another host or cloud. Do not retry it on this host.\n' \
      "$volume" >&2
    ;;
esac

case "$gate" in
  '') exit 0 ;;
  crew)
    case "$level" in
      pause | stop | unreadable) exit 1 ;;
      *) exit 0 ;;
    esac
    ;;
  lane)
    case "$level" in
      stop | unreadable) exit 1 ;;
      *) exit 0 ;;
    esac
    ;;
esac
exit 0
