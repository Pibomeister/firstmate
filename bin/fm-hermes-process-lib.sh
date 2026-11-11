#!/usr/bin/env bash
# Hermes process identity, used by agent-process liveness.
# Match only argv[0], a Node TUI script argument, or Python's exact -m module;
# never a later prompt argument or a working-directory path. Linux argv fields
# preserve spaces; the ps fallback conservatively rejects ambiguous paths.
fm_hermes_process_matches() {  # <args> [pid]
  local args=${1:-} pid=${2:-} word first=1 interpreter='' module=0
  local words=()
  if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ]; then
    while IFS= read -r -d '' word; do words+=("$word"); done < "/proc/$pid/cmdline"
  elif [ -n "$pid" ]; then
    # No /proc (macOS): the live ps command line is the same kernel fact,
    # split on spaces; the matcher below still rejects ambiguous paths.
    local ps_args
    ps_args=$(ps -o args= -p "$pid" 2>/dev/null) || ps_args=
    read -r -a words <<< "${ps_args:-$args}"
  else
    read -r -a words <<< "$args"
  fi
  for word in ${words[@]+"${words[@]}"}; do
    if [ "$first" = 1 ]; then
      first=0
      case "${word##*/}" in
        hermes) return 0 ;;
        node|node-*|node[0-9]*|MainThread) interpreter=node ;;
        python|python[0-9]*|Python|Python[0-9]*) interpreter=python ;;
        *) return 1 ;;
      esac
      continue
    fi
    if [ "$module" = 1 ]; then
      [ "$word" = tui_gateway.entry ] && return 0
      return 1
    fi
    case "$word" in
      -m) [ "$interpreter" = python ] || return 1; module=1; continue ;;
      -c|-e|--eval|--print) return 1 ;;
      -*) continue ;;
    esac
    case "$interpreter:$word" in
      node:*/ui-tui/dist/entry.js|node:*/hermes_cli/tui_dist/entry.js) return 0 ;;
      python:*/hermes|python:*/hermes_cli/main.py) return 0 ;;
    esac
    return 1
  done
  return 1
}
