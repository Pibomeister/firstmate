#!/usr/bin/env bash
# fm-jev-mem-guard.sh - Wrapper for Jev Multi-Agent Memory RSS & Swap Thrashing Guard (Pattern 46)

# Bash 5.1+ pipes here-documents, which hang when the host shrinks pipe buffers; from 5.2, level 50 keeps temp files.
[ "${BASH_VERSINFO[0]}" -lt 5 ] || BASH_COMPAT=50

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec python3 "$SCRIPT_DIR/fm-jev-mem-guard.py" "$@"
