#!/usr/bin/env bash
# Host run request R2: a dedicated, new Colima profile for the Linux receiver.
# Never starts, stops or edits an existing profile. Mounts only the staging
# root into the VM. Records the previous docker context so undo restores it.
# Needs network (Colima VM image download). Free; no account or spend.
# Undo: host/99-undo.sh colima
set -euo pipefail
ROOT="${FIXTURE_HOST_ROOT:-/Users/picazosmacmini/factory-vfs-pilot}"
PROFILE=factory-vfs-pilot
mkdir -p "$ROOT/evidence"
colima list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$PROFILE" && { echo "profile $PROFILE already exists; inspect it first" >&2; exit 1; }
docker context show > "$ROOT/evidence/docker-context-before.txt" 2>/dev/null || echo default > "$ROOT/evidence/docker-context-before.txt"
colima start --profile "$PROFILE" --arch aarch64 --vm-type vz --cpu 2 --memory 4 --disk 20 \
    --runtime docker --mount "$ROOT:w"
# colima switches the current docker context; put the previous one back and
# address the new VM only by explicit --context from here on.
docker context use "$(cat "$ROOT/evidence/docker-context-before.txt")" > /dev/null || true
docker --context "colima-$PROFILE" info --format '{{.OSType}} {{.Architecture}} {{.KernelVersion}}' | tee "$ROOT/evidence/colima-docker-info.txt"
colima ssh --profile "$PROFILE" -- sh -c 'uname -a; ls -l /dev/fuse; cat /sys/kernel/security/lsm 2>/dev/null' | tee "$ROOT/evidence/colima-vm-facts.txt"
