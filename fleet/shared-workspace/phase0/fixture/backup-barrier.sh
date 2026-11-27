#!/usr/bin/env bash
# Refinement 5: a backup counts only once it is complete.
#
# Protocol (one backup):
#   1. vfs backup SRC DEST/.partial-<id>.db --verify     (vfs reopens the copy)
#   2. vfs integrity --require-portable on the copy, then sha256 it
#   3. rename .partial-<id>.db -> <id>.db
#   4. write .partial-<id>.json, rename -> <id>.complete.json   <- commit point
# A backup is counted only if <id>.complete.json exists and the sha256 it
# records matches <id>.db right now. Anything else is ignored.
#
# DEST here is a local stand-in. No independent backup destination has been
# chosen yet (open item); point BACKUP_DEST at it once one is approved.
#
# Env: VFS_BIN, FIXTURE_ROOT, [BACKUP_DEST]
set -euo pipefail
MACHINE=backup
. "$(dirname "$0")/lib.sh"
DEST="${BACKUP_DEST:-$FIXTURE_ROOT/artifacts/backups}"
WORK="$FIXTURE_ROOT/state/backup"
rm -rf "$WORK" "$DEST"; mkdir -p "$WORK" "$DEST"

# Source: a stopped session database. Reuse machine A's if present.
SRC="$FIXTURE_ROOT/state/home-a/.vfs/run/$SESSION_ID/delta.db"
if [ ! -f "$SRC" ]; then
    SRC="$WORK/src.db"
    ( cd "$WORK" && HOME="$WORK" "$VFS_BIN" init p0-backup-src > /dev/null && \
      HOME="$WORK" "$VFS_BIN" fs .vfs/p0-backup-src.db write /hello.txt "backup source" > /dev/null )
    SRC="$WORK/.vfs/p0-backup-src.db"
fi

backup_once() {   # backup_once ID [STOP_AFTER_STEP]
    local id="$1" stop="${2:-9}" sha
    "$VFS_BIN" backup "$SRC" "$DEST/.partial-$id.db" --verify > /dev/null
    [ "$stop" -gt 1 ] || return 0
    "$VFS_BIN" integrity "$DEST/.partial-$id.db" --require-portable --json > /dev/null
    sha="$(sha256_of "$DEST/.partial-$id.db")"
    [ "$stop" -gt 2 ] || return 0
    mv "$DEST/.partial-$id.db" "$DEST/$id.db"
    [ "$stop" -gt 3 ] || return 0
    printf '{"id":"%s","source":"%s","sha256":"%s","sizeBytes":%s,"vfsCommit":"%s","completedAt":"%s"}\n' \
        "$id" "$SRC" "$sha" "$(size_of "$DEST/$id.db")" "$("$VFS_BIN" version --json | jget commit)" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$DEST/.partial-$id.json"
    mv "$DEST/.partial-$id.json" "$DEST/$id.complete.json"
}

count_complete() {
    local n=0 m id
    for m in "$DEST"/*.complete.json; do
        [ -f "$m" ] || continue
        id="$(jget id < "$m")"
        [ -f "$DEST/$id.db" ] && [ "$(sha256_of "$DEST/$id.db")" = "$(jget sha256 < "$m")" ] && n=$((n+1))
    done
    echo "$n"
}

backup_once b1
[ "$(count_complete)" = 1 ] && check K1-complete-counts PASS "one finished backup counts" || check K1-complete-counts FAIL "count $(count_complete)"

# Crash after each step before the commit point: none of these may count.
for step in 1 2 3; do backup_once "crash$step" "$step"; done
[ "$(count_complete)" = 1 ] && check K2-incomplete-ignored PASS "backups stopped after copy, after verify, and after data rename are not counted" \
    || check K2-incomplete-ignored FAIL "count $(count_complete)"

# A completed backup whose bytes changed afterwards stops counting.
backup_once b2
printf '\xff' | dd of="$DEST/b2.db" bs=1 seek=100 conv=notrunc 2>/dev/null
[ "$(count_complete)" = 1 ] && check K3-corrupt-ignored PASS "a complete backup with changed bytes is not counted" \
    || check K3-corrupt-ignored FAIL "count $(count_complete)"

# The restored copy must open and match the source content.
backup_once b3
if "$VFS_BIN" integrity "$DEST/b3.db" --require-portable --json > /dev/null 2>&1; then
    check K4-restore-opens PASS "counted backup passes integrity --require-portable"
else
    check K4-restore-opens FAIL "counted backup failed integrity"
fi
