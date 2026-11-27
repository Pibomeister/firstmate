#!/usr/bin/env bash
# Undo for the Phase 0 host run requests. Each scope is independent.
#   99-undo.sh container   remove the receiver image (containers are --rm)
#   99-undo.sh colima      stop and delete ONLY the factory-vfs-pilot profile,
#                          restore the previous docker context
#   99-undo.sh native      unmount any leftover vfs NFS mounts under the root,
#                          then delete the staging root
#   99-undo.sh all         container, colima, native in that order
# The pre-existing Colima profile and everything outside ROOT are never touched.
set -uo pipefail
ROOT="${FIXTURE_HOST_ROOT:-/Users/picazosmacmini/factory-vfs-pilot}"
PROFILE=factory-vfs-pilot
undo_container() {
    for c in $(docker --context "colima-$PROFILE" ps -a --filter name=factory-vfs-pilot -q); do
        docker --context "colima-$PROFILE" rm -f "$c"
    done
    docker --context "colima-$PROFILE" image rm -f factory-vfs-pilot/receiver:phase0 2>/dev/null || true
}
undo_colima() {
    colima stop --profile "$PROFILE" 2>/dev/null || true
    colima delete --profile "$PROFILE" --force
    [ -f "$ROOT/evidence/docker-context-before.txt" ] && docker context use "$(cat "$ROOT/evidence/docker-context-before.txt")"
}
undo_native() {
    mount | awk -v r="$ROOT" '$0 ~ r {print $3}' | while read -r m; do /sbin/umount "$m" || /sbin/umount -f "$m"; done
    case "$ROOT" in /Users/*/factory-vfs-pilot) rm -rf "$ROOT" ;; *) echo "refusing to delete unexpected root $ROOT" >&2; return 1 ;; esac
}
case "${1:-}" in
    container) undo_container ;;
    colima) undo_colima ;;
    native) undo_native ;;
    all) undo_container; undo_colima; undo_native ;;
    *) sed -n '2,9p' "$0"; exit 2 ;;
esac
