#!/usr/bin/env bash
# fm-marker-lib.sh - compatibility entry point for from-firstmate routing.
#
# bin/fm-operational-input.sh owns current operational-input construction,
# parsing, marker bytes, and the established from-firstmate compatibility
# carrier. Existing callers source this path so they do not need a flag-day
# migration. No side effects on source beyond its Bash compatibility level. set -u / set -e safe.

# Bash 5.1+ pipes here-documents, which hang when the host shrinks pipe buffers; from 5.2, level 50 keeps temp files.
[ "${BASH_VERSINFO[0]}" -lt 5 ] || BASH_COMPAT=50

_FM_MARKER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-operational-input.sh
. "$_FM_MARKER_LIB_DIR/fm-operational-input.sh"
unset _FM_MARKER_LIB_DIR
