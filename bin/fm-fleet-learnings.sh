#!/usr/bin/env bash
# Print the labeled tracked fleet learnings subsection consumed by
# fm-afk-preflight.sh. (Session start indexes the same file in its own CONTEXT
# section rather than printing it.) A missing file prints ABSENT and still exits
# 0 so away entry never blocks on learnings propagation lag.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
path="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}/docs/learnings/overnight-learnings.md"

printf '\n%s\n%s\n' 'docs/learnings/overnight-learnings.md (tracked fleet learnings; read at each AFK preflight)' '--------------------------------------------------------------------------------'
if [ -s "$path" ]; then
  cat "$path"
elif [ -f "$path" ]; then
  printf '(present, empty)\n'
else
  printf 'ABSENT\n'
fi
