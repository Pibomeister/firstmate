#!/usr/bin/env bash
# Remove home/task-scoped Firstmate variables before crossing a shared process
# boundary. A new tmux server must not publish its creator's FM_* environment
# globally; a worker launch must not inherit FM_* values from an old server.
#
# Source `fm_env_scrub` in a subshell before creating a tmux server, or run:
#   fm-env-scrub.sh [--keep-zellij-session] shell <command-string>
#   fm-env-scrub.sh exec <command> [args...]
# `shell` uses the destination pane's SHELL as an interactive shell so generated
# and raw launch syntax keeps the interpreter, rc functions and aliases it had
# when sourced directly in that pane. `exec` runs a fixed argv with no shell.
fm_env_scrub() {  # [keep-zellij-session: 0|1]
  local keep_zellij=${1:-0} name
  while IFS= read -r name; do
    case "$name" in
      FM_ZELLIJ_SESSION) [ "$keep_zellij" -eq 0 ] || continue ;;
      FM_*) ;;
      *) continue ;;
    esac
    unset "$name"
  done < <(compgen -e)
}

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0
set -eu
keep_zellij=0
if [ "${1:-}" = --keep-zellij-session ]; then
  keep_zellij=1
  shift
fi
case "${1:-}" in
  shell) [ "$#" -eq 2 ] ;;
  exec) [ "$#" -ge 2 ] ;;
  *) false ;;
esac || {
  echo 'error: fm-env-scrub needs shell and one command string, or exec and a command' >&2
  exit 2
}
mode=$1
shift
fm_env_scrub "$keep_zellij"
[ "$mode" = exec ] || set -- "${SHELL:-/bin/sh}" -ic "$1"
exec "$@"
