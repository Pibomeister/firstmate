#!/usr/bin/env bash
# Write the one-line snippet a pane sources after its agent command.
#
#   fm-agent-exit-snippet.sh <snippet-file> <spawn-gen> <record-file>
#
# The launch file the pane sources cannot contain a status spelling or a bare
# assignment: fish parses that file before running any of it, rejects `$?`, and
# has no `name=value` statement. This runs in the pane, before the agent, and
# writes one line in the syntax of the shell that invoked it, detected from
# that shell the same way `fm-env-scrub.sh unset-file` does. The pane sources
# the line after the agent. Its first command reads the status, so the read is
# the agent command's exit and not the status of `source` itself.
set -eu

quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

[ "$#" -eq 3 ] || {
  echo 'error: fm-agent-exit-snippet needs a snippet file, a spawn incarnation, and a record file' >&2
  exit 2
}
snippet=$1
gen=$2
record=$3
case "$gen" in
  *[!A-Za-z0-9.]*|'')
    echo 'error: fm-agent-exit-snippet: spawn incarnation is not a usable token' >&2
    exit 2
    ;;
esac
[ -n "$snippet" ] && [ -n "$record" ] || {
  echo 'error: fm-agent-exit-snippet needs a snippet file and a record file' >&2
  exit 2
}

shell=$(ps -o comm= -p "$PPID" 2>/dev/null || true)
shell=${shell##*/}
# shellcheck disable=SC2016 # Literal status spellings: the pane shell expands them in the snippet.
case "${shell#-}" in
  fish) status_spell='$status' ;;
  *) status_spell='$?' ;;
esac

tmp=$(mktemp "$snippet.XXXXXX")
if ! printf '%s\n' "printf '%s\\t%s\\n' $(quote "$gen") \"${status_spell}\" > $(quote "$record") 2>/dev/null || true" > "$tmp" \
  || ! mv -f "$tmp" "$snippet"; then
  rm -f "$tmp"
  exit 1
fi
