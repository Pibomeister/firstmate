#!/usr/bin/env bash
# Away-mode preflight output shown when the captain enters /afk.
#
# Usage: fm-afk-preflight.sh
#
# Prints a bounded digest section the away session should read before acting.
# Hard dependency dry-runs and other checks belong here as they land; fleet
# learnings are always included first. Missing learnings never refuse entry.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RULE='================================================================================'

printf '\n%s\nAFK PREFLIGHT\n%s\n' "$RULE" "$RULE"
"$SCRIPT_DIR/fm-fleet-learnings.sh" || true
exit 0
