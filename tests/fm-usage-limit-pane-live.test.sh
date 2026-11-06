#!/usr/bin/env bash
# Pending-verification marker for the usage-limit pane-text classifier.
# Default skip/pending, never pass. Never starts a session, never types Enter.
# Classify only an existing already-limited pane named by FM_USAGE_LIMIT_PANE.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_USAGE_LIMIT_PANE_LIVE

pane=${FM_USAGE_LIMIT_PANE-}
if [ -z "$pane" ]; then
  printf 'skip: pending: usage-limit pane-text is not live-verified; set FM_USAGE_LIMIT_PANE to an existing already-limited pane to classify it\n'
  exit 0
fi

command -v tmux >/dev/null 2>&1 || {
  printf 'not ok - FM_USAGE_LIMIT_PANE is set but tmux is not installed\n' >&2
  exit 1
}

sock_args=()
if [ -n "${FM_USAGE_LIMIT_PANE_SOCKET-}" ]; then
  sock_args=(-L "$FM_USAGE_LIMIT_PANE_SOCKET")
fi

# Read-only capture. Never send-keys. Never print pane text.
screen=$(tmux "${sock_args[@]}" capture-pane -p -t "$pane" 2>/dev/null) || {
  printf 'not ok - could not capture the named existing pane\n' >&2
  exit 1
}

# shellcheck source=bin/fm-watchdog-lib.sh
. "$ROOT/bin/fm-watchdog-lib.sh"
kind=$(fm_wd_pane_dialog "$screen") || kind=
unset screen

if [ "$kind" = usage-limit ]; then
  pass "named existing pane classified usage-limit with no Enter"
  exit 0
fi

printf 'not ok - named existing pane classified %s, not usage-limit\n' "${kind:-none}" >&2
exit 1
