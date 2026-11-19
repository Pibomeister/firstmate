#!/usr/bin/env bash
# Goal-line enforcement (config/goal-integrity). Shared by fm-brief.sh and fm-spawn.sh.

# shellcheck source=bin/fm-config-inherit-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-config-inherit-lib.sh"

fm_goal_integrity_flag_path() {
  printf '%s/goal-integrity\n' "$1"
}

# Exit 0 when enforcement is on, 1 when off, 2 on inspection error.
fm_goal_integrity_enabled() {
  local config=$1 flag present
  flag=$(fm_goal_integrity_flag_path "$config") || return 2
  present=$(fm_config_source_present "$flag") || return 2
  [ "$present" = 1 ]
}

# Print the owner label for the GOAL prefix. Refuses disabled-looking values.
fm_goal_integrity_owner() {
  local config=$1 flag line
  flag=$(fm_goal_integrity_flag_path "$config") || return 1
  if [ ! -f "$flag" ] || [ ! -r "$flag" ]; then
    echo "error: $flag must be a readable regular file when goal-line enforcement is enabled" >&2
    return 1
  fi
  line=$(awk 'NF { print; exit }' "$flag")
  case "$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')" in
    ''|on|1|yes|true) printf '%s\n' owner; return 0 ;;
    off|0|no|false)
      echo "error: remove $flag to disable goal-line enforcement; do not write off/false into it" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$line"
}

fm_goal_integrity_prefix() {
  local config=$1 owner
  owner=$(fm_goal_integrity_owner "$config") || return 1
  printf 'GOAL (%s, verbatim): ' "$owner"
}
