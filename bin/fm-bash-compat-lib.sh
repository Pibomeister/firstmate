#!/usr/bin/env bash
# fm-bash-compat-lib.sh - the Darwin bash here-document gate (one owner).
#
# Bash 5.1 through 5.3.15 on macOS writes a whole here-document or here-string
# into a pipe before any reader of that pipe exists. Under machine-wide
# pipe-memory pressure a new macOS pipe holds only 512 bytes, so any document
# between 512 bytes and about 64 KB blocks that write forever, wedging whatever
# shell ran it. Upstream patch bash53-016 (bash 5.3.16 and later) falls back to
# a temporary file; bash below 5.1 always used one, and Linux bash checks the
# pipe's capacity first. Compatibility level 50 restores the temporary-file path.
#
# Sourcing this file applies the gate once to the sourcing shell: on an
# affected runtime it sets BASH_COMPAT=50 in that shell only and never exports
# it, so worker panes, projects and child shells are untouched (the supervision
# and steering entry points source this themselves, directly or through
# a library, and tests/fm-bash-compat.test.sh pins them; lab, install and CI
# tools may not); on every other runtime it changes nothing, including an
# inherited BASH_COMPAT.
# This file must never contain a here-document: it runs before the gate does.
#
#   fm_bash_heredoc_affected [<ostype> <major> <minor> <patch>]
#       0 iff the given runtime, else the running shell's, is affected.
#   fm_bash_compat_apply
#       Apply the gate to the running shell (idempotent).
#   fm_bash_heredoc_warning <bash-path>
#       One plain line naming <bash-path> when that executable is affected.
#   fm_bash_heredoc_startup_warnings
#       The startup check: one line for each affected bash among the running
#       shell and the one PATH selects for `#!/usr/bin/env bash` children.
#       bin/fm-session-start.sh prints it before its lock work and exports
#       FM_BASH_HEREDOC_WARNED=1; bin/fm-bootstrap.sh prints it unless that is set.
#
# Test seams, honoured only with FM_TEST_SEAM=1:
#   FM_TEST_BASH_RUNTIME="<ostype> <major> <minor> <patch>" replaces the running
#     shell's detected runtime.
#   FM_BASH_HEREDOC_PROBE_PATH replaces the PATH-selected bash the startup check probes.
#   FM_BASH_COMPAT_PROBE=<file>: the first gate a shell applies appends
#     "<script>\t<applied|unaffected>" to <file> and exits that shell at once.

fm_bash_heredoc_affected() {
  local ostype major minor patch
  if [ "$#" -ge 4 ]; then
    ostype=$1 major=$2 minor=$3 patch=$4
  elif [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_TEST_BASH_RUNTIME:-}" ]; then
    # shellcheck disable=SC2086 # the profile is four whitespace-separated words
    set -- $FM_TEST_BASH_RUNTIME
    ostype=${1:-} major=${2:-} minor=${3:-} patch=${4:-}
  else
    ostype=${OSTYPE:-} major=${BASH_VERSINFO[0]:-} minor=${BASH_VERSINFO[1]:-} patch=${BASH_VERSINFO[2]:-}
  fi
  case "$ostype" in darwin*) ;; *) return 1 ;; esac
  case "$major$minor$patch" in '' | *[!0-9]*) return 1 ;; esac
  [ "$major" -eq 5 ] || return 1
  case "$minor" in
    1 | 2) return 0 ;;
    3) [ "$patch" -lt 16 ] ;;
    *) return 1 ;;
  esac
}

fm_bash_compat_apply() {
  local verdict=unaffected
  if fm_bash_heredoc_affected; then
    BASH_COMPAT=50
    export -n BASH_COMPAT
    verdict=applied
  fi
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_BASH_COMPAT_PROBE:-}" ]; then
    printf '%s\t%s\n' "${0##*/}" "$verdict" >> "$FM_BASH_COMPAT_PROBE"
    exit 0
  fi
}

_fm_bash_heredoc_message() {  # <path> <major> <minor> <patch>
  printf 'WARNING: %s is bash %s.%s.%s on macOS, which can hang forever writing a here-document under pipe-memory pressure (fixed in bash 5.3.16, upstream patch bash53-016); firstmate forces temporary-file here-documents in its own scripts on it, but upgrade it: brew upgrade bash\n' \
    "$1" "$2" "$3" "$4"
}

fm_bash_heredoc_warning() {  # <bash-path>
  local bash_path=${1:-} profile
  [ -n "$bash_path" ] || return 0
  # shellcheck disable=SC2016 # expanded by the probed bash, not this one
  profile=$("$bash_path" -c 'printf "%s %s %s %s" "${OSTYPE:-}" "${BASH_VERSINFO[0]:-}" "${BASH_VERSINFO[1]:-}" "${BASH_VERSINFO[2]:-}"' 2>/dev/null) || return 0
  # shellcheck disable=SC2086 # the probed profile is four whitespace-separated words
  set -- $profile
  [ "$#" -eq 4 ] || return 0
  fm_bash_heredoc_affected "$@" || return 0
  _fm_bash_heredoc_message "$bash_path" "$2" "$3" "$4"
}

fm_bash_heredoc_startup_warnings() {
  local running path_bash profile
  running=${BASH:-bash}
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_TEST_BASH_RUNTIME:-}" ]; then
    profile=$FM_TEST_BASH_RUNTIME
  else
    profile="${OSTYPE:-} ${BASH_VERSINFO[0]:-} ${BASH_VERSINFO[1]:-} ${BASH_VERSINFO[2]:-}"
  fi
  # shellcheck disable=SC2086 # the profile is four whitespace-separated words
  set -- $profile
  if [ "$#" -eq 4 ] && fm_bash_heredoc_affected "$@"; then
    _fm_bash_heredoc_message "$running" "$2" "$3" "$4"
    return 0
  fi
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_BASH_HEREDOC_PROBE_PATH:-}" ]; then
    path_bash=$FM_BASH_HEREDOC_PROBE_PATH
  else
    path_bash=$(command -v bash 2>/dev/null) || path_bash=
  fi
  # One line in total: the running shell when it is affected, else the bash
  # PATH selects for `#!/usr/bin/env bash` children.
  [ -n "$path_bash" ] && [ "$path_bash" != "$running" ] || return 0
  fm_bash_heredoc_warning "$path_bash"
}

fm_bash_compat_apply
