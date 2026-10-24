#!/usr/bin/env bash
# Read-only real Orca adapter probe. Run only from the exact pipeline worktree.
set -u
expected=/Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5NKPNRRG36VA9QBW5RC1KWQ
[ "$PWD" = "$expected" ] || exit 2
evidence=/Users/eduardopicazo/.no-mistakes/evidence/01M5NKPNRRG36VA9QBW5RC1KWQ/orca-readonly-round2
terminal=term_da54e1ca-45ea-477d-8f2f-b4a86cfd2f81
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$evidence/started.txt"
git rev-parse HEAD > "$evidence/head.txt"
git status --short > "$evidence/status-before.txt"
shasum -a 256 bin/backends/orca.sh bin/fm-composer-lib.sh bin/fm-busy-lib.sh > "$evidence/source-before.sha256"
. ./bin/backends/orca.sh
# No expected label: this exercises the ordinary Grok path and reads no task metadata.
exec 9> "$evidence/adapter.xtrace.txt"
export BASH_XTRACEFD=9
PS4='+ ${BASH_SOURCE}:${LINENO}: '
set -x
fm_backend_orca_composer_state "$terminal" > "$evidence/adapter.verdict.txt" 2> "$evidence/adapter.stderr.txt"
adapter_exit=$?
set +x
printf '%s\n' "$adapter_exit" > "$evidence/adapter.exit.txt"
# Preserve a separate raw command response from the same capture primitive.
printf '%s\n' "orca terminal read --terminal $terminal --limit $FM_COMPOSER_CAPTURE_LINES --json" > "$evidence/stream.command.txt"
orca terminal read --terminal "$terminal" --limit "$FM_COMPOSER_CAPTURE_LINES" --json > "$evidence/stream.json" 2> "$evidence/stream.stderr.txt"
stream_exit=$?
printf '%s\n' "$stream_exit" > "$evidence/stream.exit.txt"
if [ "$stream_exit" -eq 0 ]; then
  fm_backend_orca_json_text "$(cat "$evidence/stream.json")" > "$evidence/stream.capture.txt"
fi
printf '%s\n' "orca terminal read --terminal $terminal --screen --json" > "$evidence/viewport.command.txt"
if [ "$(cat "$evidence/viewport.exit.txt")" -eq 0 ]; then
  fm_backend_orca_json_text "$(cat "$evidence/viewport.json")" screen > "$evidence/viewport.capture.txt"
fi
fm_backend_orca_composer_caps > "$evidence/capabilities.txt"
shasum -a 256 bin/backends/orca.sh bin/fm-composer-lib.sh bin/fm-busy-lib.sh > "$evidence/source-after.sha256"
printf 'adapter exit=%s verdict=%s; stream exit=%s\n' "$adapter_exit" "$(cat "$evidence/adapter.verdict.txt")" "$stream_exit"
