#!/usr/bin/env bash
# fm-quiet-hours-lib.sh - the quiet-hours clock. bin/fm-quiet-hours.sh is its
# command.
#
# fm_quiet_hours_at [<epoch>] prints one line for that moment:
#   quiet=1 ends=<epoch> window=nightly|weekend   inside quiet hours
#   quiet=0 next=<epoch>                          outside; next is when the next window starts
# With no epoch it reads fm_now (bin/fm-clock-lib.sh), the shared fixed-clock
# seam.
#
# The windows are wall-clock times in the zone named by the quiet-hours-zone
# key of config/escalation (default America/Costa_Rica), never the host's zone.
# Nightly is 22:00 to 08:00. The weekend is Friday 17:00 to Monday 08:00 and
# replaces every nightly window inside it, so Friday 23:00 and Saturday 03:00
# both report window=weekend and ends=Monday 08:00, and the weekend is the
# longest window. A window includes its start second and excludes its end
# second.
#
# docs/configuration.md ("Escalation quiet hours") owns the config/escalation
# format. The file is read from FM_CONFIG_OVERRIDE when set, else from
# $FM_HOME/config, else from the code root's config/.
#
# Prints nothing on stdout when it refuses. It returns 2 when the epoch is not a
# decimal whole number. It returns 3 when the configured zone is unknown: the
# name is absolute or contains "..", or ${TZDIR:-/usr/share/zoneinfo}/<zone> is
# not a zoneinfo (TZif) file. It returns 1 when date cannot convert the moment.

FM_QUIET_HOURS_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; CDPATH='' cd -- "${d:-/}" && pwd)"
# shellcheck source=bin/fm-clock-lib.sh
. "$FM_QUIET_HOURS_LIB_DIR/fm-clock-lib.sh"

FM_QUIET_HOURS_DEFAULT_ZONE=America/Costa_Rica

# _fm_qh_zone: print the configured zone, or the default when the key is unset
# or empty.
_fm_qh_zone() {
  local conf zone=
  conf="${FM_CONFIG_OVERRIDE:-${FM_HOME:-$FM_QUIET_HOURS_LIB_DIR/..}/config}/escalation"
  if [ -f "$conf" ]; then
    zone=$(awk '
      /^[ \t]*#/ { next }
      { i = index($0, "="); if (i == 0) next
        name = substr($0, 1, i - 1); gsub(/^[ \t]+|[ \t]+$/, "", name)
        if (name != "quiet-hours-zone") next
        val = substr($0, i + 1); gsub(/^[ \t]+|[ \t]+$/, "", val); last = val }
      END { print last }
    ' "$conf" 2> /dev/null) || zone=
  fi
  printf '%s\n' "${zone:-$FM_QUIET_HOURS_DEFAULT_ZONE}"
}

# _fm_qh_gnu: succeed when date is GNU date, which accepts -d @<epoch>; BSD
# date has no -d and its -r reads an epoch, where GNU's -r reads a file.
_fm_qh_gnu() {
  date -d @0 +%s > /dev/null 2>&1
}

# _fm_qh_date <zone> <epoch> <format>: format a moment in a zone.
_fm_qh_date() {
  if _fm_qh_gnu; then TZ=$1 date -d "@$2" "+$3"; else TZ=$1 date -r "$2" "+$3"; fi
}

# _fm_qh_epoch <zone> <YYYY-MM-DD> <HH:MM:SS>: the epoch of a wall time in a zone.
_fm_qh_epoch() {
  if _fm_qh_gnu; then TZ=$1 date -d "$2 $3" +%s; else TZ=$1 date -j -f '%Y-%m-%d %H:%M:%S' "$2 $3" +%s; fi
}

# _fm_qh_day <zone> <epoch> <days>: the wall date <days> after the moment's
# date, stepping from local noon so a daylight-saving change cannot skip a day.
_fm_qh_day() {
  local noon
  noon=$(_fm_qh_epoch "$1" "$(_fm_qh_date "$1" "$2" %Y-%m-%d)" 12:00:00) || return 1
  _fm_qh_date "$1" $((noon + $3 * 86400)) %Y-%m-%d
}

# fm_quiet_hours_at [<epoch>]: see the header.
fm_quiet_hours_at() {
  local now zone file parts dow hms days at
  if [ "$#" -gt 0 ]; then now=$1; else now=$(fm_now); fi
  case "$now" in
    ''|*[!0-9]*) printf 'fm-quiet-hours: epoch is not a decimal whole number: %s\n' "$now" >&2; return 2 ;;
  esac
  zone=$(_fm_qh_zone)
  file="${TZDIR:-/usr/share/zoneinfo}/$zone"
  case "$zone" in
    /*|*..*) file= ;;
  esac
  if [ -z "$file" ] || [ ! -f "$file" ] || [ "$(head -c 4 "$file" 2> /dev/null)" != TZif ]; then
    printf 'fm-quiet-hours: unknown quiet-hours-zone: %s\n' "$zone" >&2
    return 3
  fi
  parts=$(_fm_qh_date "$zone" "$now" '%u %H%M%S') || return 1
  dow=${parts% *}
  hms=${parts#* }
  # Weekend: Friday from 17:00, Saturday, Sunday, Monday before 08:00.
  days=
  case "$dow" in
    5) [ "$hms" -lt 170000 ] || days=3 ;;
    6) days=2 ;;
    7) days=1 ;;
    1) [ "$hms" -ge 080000 ] || days=0 ;;
  esac
  if [ -n "$days" ]; then
    at=$(_fm_qh_epoch "$zone" "$(_fm_qh_day "$zone" "$now" "$days")" 08:00:00) || return 1
    printf 'quiet=1 ends=%s window=weekend\n' "$at"
  elif [ "$hms" -lt 080000 ]; then
    at=$(_fm_qh_epoch "$zone" "$(_fm_qh_day "$zone" "$now" 0)" 08:00:00) || return 1
    printf 'quiet=1 ends=%s window=nightly\n' "$at"
  elif [ "$hms" -ge 220000 ]; then
    at=$(_fm_qh_epoch "$zone" "$(_fm_qh_day "$zone" "$now" 1)" 08:00:00) || return 1
    printf 'quiet=1 ends=%s window=nightly\n' "$at"
  elif [ "$dow" = 5 ]; then
    at=$(_fm_qh_epoch "$zone" "$(_fm_qh_day "$zone" "$now" 0)" 17:00:00) || return 1
    printf 'quiet=0 next=%s\n' "$at"
  else
    at=$(_fm_qh_epoch "$zone" "$(_fm_qh_day "$zone" "$now" 0)" 22:00:00) || return 1
    printf 'quiet=0 next=%s\n' "$at"
  fi
}
