#!/usr/bin/env bash
# Run the whole stopped-session fixture on one host, with machine A and
# machine B simulated by two separate HOMEs (two ~/.vfs stores) and two
# separate base checkouts. Use it to smoke-test a host before the real
# cross-machine run (macOS host -> Linux container).
#
# Env: VFS_BIN, FIXTURE_ROOT, [SESSION_ID]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${VFS_BIN:?}"; : "${FIXTURE_ROOT:?}"
export VFS_BIN FIXTURE_ROOT
rm -f "$FIXTURE_ROOT/evidence/checks.tsv"
bundle="$("$HERE/machine-a-pack.sh")"
inbox="$FIXTURE_ROOT/state/inbox-b"
moved="$("$HERE/transfer.sh" "$bundle" "$inbox")"
"$HERE/machine-b-adopt.sh" "$moved"
"$HERE/negative-checks.sh" "$moved"
"$HERE/crash-recovery.sh"
"$HERE/backup-barrier.sh"
echo "--- checks"
cat "$FIXTURE_ROOT/evidence/checks.tsv"
! grep -q $'\tFAIL\t' "$FIXTURE_ROOT/evidence/checks.tsv"
