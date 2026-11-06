#!/usr/bin/env bash
# Opt-in live guard for the usage-limit pane-text classifier.
# Default off. When requested, fail closed until a dated live capture exists.
# Never types Enter into a picker.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_USAGE_LIMIT_PANE_LIVE claude

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
[ -n "$CLAUDE_VERSION" ] || CLAUDE_VERSION=unknown

printf 'not ok - usage-limit pane-text classification is not live-verified for %s\n' \
  "$CLAUDE_VERSION" >&2
printf 'set FM_USAGE_LIMIT_PANE_LIVE=1 only after a dated capture in docs/verification/runtime-backends.md; this guard never types Enter\n' >&2
exit 1
