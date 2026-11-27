#!/usr/bin/env bash
# Runs inside the receiver container (see host/30-container-receiver.sh).
set -euo pipefail
F=/opt/phase0/fixture
mkdir -p "$FIXTURE_ROOT"
"$VFS_BIN" version --json > "$EVIDENCE_DIR/b-version.json"
/opt/phase0/scripts/pin-vfs.sh record "$VFS_BIN" "$EVIDENCE_DIR" || true
{ uname -a; id; cat /proc/self/status | grep -E '^Cap(Eff|Bnd)'; ls -l /dev/fuse 2>&1; findmnt -o TARGET,PROPAGATION /; } > "$EVIDENCE_DIR/container-facts.txt" 2>&1

# vfs run needs shared propagation on / (a container's / is private by
# default). Changing it needs CAP_SYS_ADMIN, so only tier 1 attempts it; it
# affects this container's own mount namespace only.
if [ -e /dev/fuse ]; then
    mount --make-rshared / && echo "propagation: $(findmnt -no PROPAGATION /)" >> "$EVIDENCE_DIR/container-facts.txt"
fi

moved="$("$F/transfer.sh" /mnt/a-outbox/p0-stopped-1 "$FIXTURE_ROOT/state/inbox-b")"
rc=0
MACHINE="B-linux-$TIER" "$F/machine-b-adopt.sh" "$moved" || rc=$?
MACHINE="B-linux-$TIER" "$F/negative-checks.sh" "$moved" || rc=$?
if [ -e /dev/fuse ]; then "$F/live-checkpoint.sh" || rc=$?; fi
echo "--- checks"; cat "$EVIDENCE_DIR/checks.tsv"
exit "$rc"
