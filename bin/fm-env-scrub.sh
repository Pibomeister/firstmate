#!/usr/bin/env bash
# Remove home/task-scoped Firstmate variables before crossing a shared process
# boundary. A new tmux server must not publish its creator's home or task
# identity globally; a worker launch must not inherit another home's identity
# from an old server. Runtime tuning FM_* variables are not scoped and stay.
#
# Source `fm_env_scrub` in a subshell before creating a tmux server, or run:
#   fm-env-scrub.sh [--keep-zellij-session] unset-file <out-file>
#   fm-env-scrub.sh exec <command> [args...]
# `unset-file` writes the scoped names it inherited as unset statements in the
# calling pane shell's syntax; the launch sources the result in that same
# shell, so its rc functions, aliases and syntax apply as before. `exec` runs a
# fixed argv with no shell.
fm_env_scrub_names() {  # [keep-zellij-session: 0|1]
  local keep_zellij=${1:-0} name
  while IFS= read -r name; do
    case "$name" in
      FM_ZELLIJ_SESSION) [ "$keep_zellij" -eq 0 ] || continue ;;
      FM_HOME | FM_TASK_ID | FM_TASK_INBOX | FM_PUBLIC_FOLLOWUP_PRIMARY_HOME | FM_SESSION_ENDPOINT_META | FM_LEASE_HOLDER_SESSION | \
        FM_*_OVERRIDE | FM_PROCEVENT_CLAIM_* | FM_PROCEVENT_CAPTURE_*) ;;
      *) continue ;;
    esac
    printf '%s\n' "$name"
  done < <(compgen -e)
}

fm_env_scrub() {  # [keep-zellij-session: 0|1]
  local name
  while IFS= read -r name; do
    unset "$name"
  done < <(fm_env_scrub_names "${1:-0}")
}

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0
set -eu
keep_zellij=0
if [ "${1:-}" = --keep-zellij-session ]; then
  keep_zellij=1
  shift
fi
case "${1:-}" in
  unset-file) [ "$#" -eq 2 ] ;;
  exec) [ "$#" -ge 2 ] ;;
  *) false ;;
esac || {
  echo 'error: fm-env-scrub needs unset-file and an output file, or exec and a command' >&2
  exit 2
}
if [ "$1" = exec ]; then
  shift
  fm_env_scrub "$keep_zellij"
  exec "$@"
fi
shell=$(ps -o comm= -p "$PPID" 2>/dev/null || true)
shell=${shell##*/}
case "${shell#-}" in
  fish) unset_cmd='set -e' ;;
  *) unset_cmd='unset' ;;
esac
tmp=$(mktemp "$2.XXXXXX")
if ! fm_env_scrub_names "$keep_zellij" | while IFS= read -r name; do
  printf '%s %s\n' "$unset_cmd" "$name"
done > "$tmp" || ! mv -f "$tmp" "$2"; then
  rm -f "$tmp"
  exit 1
fi
