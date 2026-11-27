#!/usr/bin/env bash
# Host run request R3: Mac (machine A, from R1) -> Linux container (machine B).
#
# Usage: 30-container-receiver.sh TIER
#   tier0   no device, all capabilities dropped, no network. Stopped adopt and
#           offline checks only (resume is recorded as SKIP). Run this first.
#   tier1a  + /dev/fuse and CAP_SYS_ADMIN only (all other caps still dropped).
#   tier1b  + Docker's default capability set (tier1a was not enough).
#   tier1c  + AppArmor unconfined (only if the Colima VM enforces AppArmor and
#             tier1b was refused by it).
# Tier 1 runs B11 (resume over FUSE) and the Linux live-checkpoint leg.
# Every tier is --network none, non-privileged, resource-limited, and sees
# only: A's outbox (read-only), the pinned Linux vfs (read-only), the Phase 0
# scripts (read-only), and one evidence directory (read-write).
# NEVER --privileged. Tier 1 options need review before they are run.
# Undo: host/99-undo.sh container
set -euo pipefail
TIER="${1:?usage: 30-container-receiver.sh tier0|tier1a|tier1b|tier1c}"
PHASE0="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${FIXTURE_HOST_ROOT:-/Users/picazosmacmini/factory-vfs-pilot}"
CTX=colima-factory-vfs-pilot
IMAGE=factory-vfs-pilot/receiver:phase0
D="docker --context $CTX"

[ -d "$ROOT/outbox/p0-stopped-1" ] || { echo "run R1 first: no Mac-packed bundle in $ROOT/outbox" >&2; exit 1; }

# Linux arm64 vfs, verified against the pinned sha256 (downloaded, not run, on macOS).
[ -x "$ROOT/bin/linux/bin/vfs-cli-aarch64-unknown-linux-gnu/vfs" ] ||
    "$PHASE0/scripts/pin-vfs.sh" fetch aarch64-unknown-linux-gnu "$ROOT/bin/linux" | tee "$ROOT/evidence/fetch-linux.json"

# Image build needs network for the base image and apt packages (only here).
$D image inspect "$IMAGE" > /dev/null 2>&1 || $D build -t "$IMAGE" "$PHASE0/fixture/container"
$D image inspect "$IMAGE" --format '{{.Id}} {{json .RepoDigests}}' > "$ROOT/evidence/receiver-image.txt"

EV="$ROOT/evidence/container-$TIER"; rm -rf "$EV"; mkdir -p "$EV"
opts=(--rm --name "factory-vfs-pilot-$TIER" --network none --pids-limit 512 --memory 2g --cpus 2
      --security-opt no-new-privileges --tmpfs /srv/factory-vfs-pilot:rw,exec,size=1g
      -v "$ROOT/outbox:/mnt/a-outbox:ro"
      -v "$ROOT/bin/linux/bin/vfs-cli-aarch64-unknown-linux-gnu:/opt/vfs:ro"
      -v "$PHASE0:/opt/phase0:ro"
      -v "$EV:/mnt/evidence:rw"
      -e VFS_BIN=/opt/vfs/vfs -e FIXTURE_ROOT=/srv/factory-vfs-pilot -e EVIDENCE_DIR=/mnt/evidence
      -e TIER="$TIER")
case "$TIER" in
    tier0)  opts+=(--cap-drop ALL) ;;
    tier1a) opts+=(--cap-drop ALL --cap-add SYS_ADMIN --device /dev/fuse) ;;
    tier1b) opts+=(--cap-add SYS_ADMIN --device /dev/fuse) ;;
    tier1c) opts+=(--cap-add SYS_ADMIN --device /dev/fuse --security-opt apparmor=unconfined) ;;
    *) echo "unknown tier $TIER" >&2; exit 2 ;;
esac
printf '%q ' $D run "${opts[@]}" "$IMAGE" > "$EV/docker-run-argv.txt"; echo >> "$EV/docker-run-argv.txt"
set +e
$D run "${opts[@]}" "$IMAGE" /opt/phase0/fixture/container/receiver-entry.sh 2>&1 | tee "$EV/run.log"
rc=${PIPESTATUS[0]}
set -e
echo "container $TIER exit $rc; evidence in $EV"
exit "$rc"
