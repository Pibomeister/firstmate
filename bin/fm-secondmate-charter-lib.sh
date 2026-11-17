#!/usr/bin/env bash
# Shared extraction of secondmate registry summary and scope from a charter.
# Source only. FM_SECONDMATE_CHARTER and FM_SECONDMATE_SCOPE remain explicit
# caller overrides; otherwise the named sections in the filled brief are used.

normalize_registry_text() {
  awk '
    {
      gsub(/[;()]/, " ")
      gsub(/[[:space:]]+/, " ")
      sub(/^ /, "")
      sub(/ $/, "")
      if ($0 != "") out = out (out == "" ? "" : " ") $0
    }
    END { print out }
  '
}

brief_section_text() {
  local brief=$1 heading=$2
  awk -v heading="# $heading" '
    $0 == heading { in_section=1; next }
    in_section && /^# / { exit }
    in_section { print }
  ' "$brief"
}

registry_summary_for_brief() {
  local brief=$1
  if [ -n "${FM_SECONDMATE_CHARTER:-}" ]; then
    printf '%s\n' "$FM_SECONDMATE_CHARTER" | normalize_registry_text
  else
    brief_section_text "$brief" "Charter" | normalize_registry_text
  fi
}

registry_scope_for_brief() {
  local brief=$1
  if [ -n "${FM_SECONDMATE_SCOPE:-}" ]; then
    printf '%s\n' "$FM_SECONDMATE_SCOPE" | normalize_registry_text
  else
    brief_section_text "$brief" "Routing scope" | normalize_registry_text
  fi
}

# Exact project grants for self-service claims, narrower than a prose charter.
# docs/configuration.md owns claim-project; fm-ledger.sh owns the transaction.
# Missing configuration grants nothing. A malformed grant refuses the whole list.
fm_secondmate_claim_projects() { # <config-dir>
  local file="$1/mission-ledger" line project
  [ -e "$file" ] || [ -L "$file" ] || return 0
  [ -f "$file" ] && [ -r "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      claim-project=*)
        project=${line#*=}
        case "$project" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
        printf '%s\n' "$project"
        ;;
    esac
  done < "$file"
}

fm_secondmate_claim_guidance() { # <config-dir>
  local projects
  projects=$(fm_secondmate_claim_projects "$1") || return 1
  [ -n "$projects" ] || return 0
  printf '\n# Approved local queue continuation\n\n'
  printf 'Continue approved ready work in this home through bin/fm-ledger.sh claim when the supervisor is quiet.\n'
  printf 'Read bin/fm-ledger.sh --help for the claim, spawn and recovery contract before using it.\n'
  printf 'The exact project grants within this charter are: %s.\n' "$(printf '%s' "$projects" | tr '\n' ' ')"
}
