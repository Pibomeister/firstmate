#!/usr/bin/env bash
# fm-fmd-seam.sh - fork-only seam between the bash supervision scripts and
# the opt-in fmd Rust sidecar (fmd/).
#
# Sourced, never executed as the supervision path itself.
# Bash remains the default and the fallback: every function here answers
# "stay on bash" unless the home opts in and a usable fmd binary exists.
#
# Upstream-owned scripts (fm-watch.sh, fm-crew-state.sh, fm-spawn.sh) may
# source this file with at most one line and ask fm_fmd_defer.
# All seam logic lives here so an upstream port touches one line, not logic.
# This slice adds the seam only; no upstream-owned script defers yet.
#
#   fm_fmd_mode [home]
#       Prints legacy, shadow, or fmd from <home>/config/supervision.
#       The home defaults to $FM_HOME, then the current directory.
#       The raw first line must be exactly shadow or fmd, with no trimming.
#       A missing file or any other first line prints legacy.
#       $FM_CONFIG_OVERRIDE replaces <home>/config when set.
#
#   fm_fmd_bin
#       Prints the fmd binary fm_fmd_defer would use, or nothing.
#       A nonempty $FM_FMD_BIN is authoritative: only that path counts.
#       Otherwise, in order: this repo's fmd/target/release/fmd, then
#       fmd/target/debug/fmd. A binary on PATH never counts.
#       A candidate counts only when it is an executable regular file.
#
#   fm_fmd_defer [home]
#       Exit 0 only when the mode is fmd and fm_fmd_bin finds a binary.
#       Callers that get a nonzero exit keep running their bash path.
#
#   fm_fmd_shadow [home]
#       Exit 0 only when the mode is shadow and fm_fmd_bin finds a binary.
#       Shadow callers run bash as the authority and may compare fmd output.

_FM_FMD_SEAM_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd 2>/dev/null)" || _FM_FMD_SEAM_DIR="."

fm_fmd_mode() { # [home] -> legacy|shadow|fmd
  local home=${1:-${FM_HOME:-.}} cfg first=''
  cfg=${FM_CONFIG_OVERRIDE:-$home/config}
  if [ -f "$cfg/supervision" ] && [ -r "$cfg/supervision" ]; then
    IFS= read -r first < "$cfg/supervision" || :
  fi
  case "$first" in
    shadow|fmd) printf '%s\n' "$first" ;;
    *) printf 'legacy\n' ;;
  esac
}

fm_fmd_bin() { # -> binary path or empty
  local cand root
  root=${_FM_FMD_SEAM_DIR%/*}
  if [ -n "${FM_FMD_BIN:-}" ]; then
    if [ -f "$FM_FMD_BIN" ] && [ -x "$FM_FMD_BIN" ]; then
      printf '%s\n' "$FM_FMD_BIN"
    fi
    return 0
  fi
  for cand in "$root/fmd/target/release/fmd" "$root/fmd/target/debug/fmd"; do
    if [ -n "$cand" ] && [ -f "$cand" ] && [ -x "$cand" ]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 0
}

fm_fmd_defer() { # [home] -> 0 iff mode is fmd and a binary exists
  [ "$(fm_fmd_mode "${1:-}")" = fmd ] || return 1
  [ -n "$(fm_fmd_bin)" ]
}

fm_fmd_shadow() { # [home] -> 0 iff mode is shadow and a binary exists
  [ "$(fm_fmd_mode "${1:-}")" = shadow ] || return 1
  [ -n "$(fm_fmd_bin)" ]
}
