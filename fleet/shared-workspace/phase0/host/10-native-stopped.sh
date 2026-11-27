#!/usr/bin/env bash
# Host run request R1: native macOS stopped-session qualification.
# Machine A and machine B are two HOMEs under the staging root on the Mac Mini.
# Needs network once (GitHub release download). Writes only under ROOT.
# Undo: host/99-undo.sh native
set -euo pipefail
PHASE0="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${FIXTURE_HOST_ROOT:-/Users/picazosmacmini/factory-vfs-pilot}"
mkdir -p "$ROOT"/{bases,state,mount,outbox,artifacts,evidence} "$ROOT/bin"

# Pin: download the darwin arm64 release asset, verify sha256, record version.
"$PHASE0/scripts/pin-vfs.sh" release "$ROOT/bin/darwin" | tee "$ROOT/evidence/pin-darwin.json"
VFS_BIN="$(ls "$ROOT"/bin/darwin/bin/vfs-cli-*-apple-darwin/vfs)"
export VFS_BIN FIXTURE_ROOT="$ROOT"
# Prefer a git the Seatbelt profile can read (/opt/homebrew) over the xcrun shim.
[ -x /opt/homebrew/bin/git ] && export PATH="/opt/homebrew/bin:$PATH"

set +e
"$PHASE0/fixture/run-local-pair.sh" 2>&1 | tee "$ROOT/evidence/native-run.log"
rc=${PIPESTATUS[0]}
set -e
"$PHASE0/fixture/live-checkpoint.sh" || true     # records SKIP on macOS
echo "native run exit $rc; evidence in $ROOT/evidence (checks.tsv)"
exit "$rc"
