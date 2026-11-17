#!/usr/bin/env bash
# Goal-line enforcement (config/goal-integrity). Shared by fm-brief.sh and fm-spawn.sh.

# shellcheck source=bin/fm-config-inherit-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-config-inherit-lib.sh"

fm_goal_integrity_flag_path() {
  printf '%s/goal-integrity\n' "$1"
}

fm_goal_integrity_enabled() {
  local config=$1 flag present
  flag=$(fm_goal_integrity_flag_path "$config") || return 1
  present=$(fm_config_source_present "$flag") || return 1
  [ "$present" = 1 ]
}

# First non-empty line of config/goal-integrity is the owner label in the GOAL prefix.
# An empty flag file uses the literal label "owner".
fm_goal_integrity_owner() {
  local config=$1 flag line
  flag=$(fm_goal_integrity_flag_path "$config") || return 1
  [ -f "$flag" ] || { printf '%s\n' owner; return 0; }
  line=$(sed -n '/[^[:space:]]/p' "$flag" | sed -n '1p')
  [ -n "$line" ] || { printf '%s\n' owner; return 0; }
  case "$line" in
    on|1|yes|true) printf '%s\n' owner; return 0 ;;
  esac
  printf '%s\n' "$line"
}

fm_goal_integrity_prefix() {
  local config=$1 owner
  owner=$(fm_goal_integrity_owner "$config") || return 1
  printf 'GOAL (%s, verbatim): ' "$owner"
}