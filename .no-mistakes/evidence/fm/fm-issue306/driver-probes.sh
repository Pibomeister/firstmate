#!/usr/bin/env bash
set -u
ROOT=$PWD
EV=~/.no-mistakes/evidence/01M7ZVEBH1V4QBZFMZ76991HYS
mkdir -p .test306/probe-scratch
cd .test306/probe-scratch || exit 1
. "$ROOT/bin/fm-timeout-lib.sh"
export DISABLE_AUTOUPDATER=1
{
 printf 'Real Claude default-login diagnostic (no credential changes):\n'
 fm_run_timed 60 claude -p 'Reply with exactly OK. Use no tools.' --model haiku --tools '' --strict-mcp-config --settings '{"disableAllHooks":true}' --no-session-persistence --output-format json
 printf '\nCLAUDE_EXIT_STATUS=%s\n' "$?"
 printf '\nReal Agy Claude-family diagnostic (no credential changes):\n'
 fm_run_timed 60 agy -p 'Reply with exactly OK. Use no tools.' --model claude-opus-5-5-low --output-format json --disable-slash-commands --print-timeout 55s
 printf '\nAGY_EXIT_STATUS=%s\n' "$?"
} > "$EV/model-diagnostics.log" 2>&1
