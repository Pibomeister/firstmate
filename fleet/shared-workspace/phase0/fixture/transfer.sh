#!/usr/bin/env bash
# Move a published bundle from A's outbox into B's inbox without ever exposing
# a partial copy: copy into a hidden .incoming dir, verify SHA256SUMS, then one
# rename publishes it. A crash at any point leaves either nothing or a hidden
# .incoming dir that B ignores and the next transfer replaces.
#
# Usage: transfer.sh SRC_BUNDLE_DIR DEST_INBOX_DIR
set -euo pipefail
SRC="${1:?usage: transfer.sh SRC_BUNDLE_DIR DEST_INBOX_DIR}"; DEST="${2:?}"
name="$(basename "$SRC")"
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
[ -f "$SRC/SHA256SUMS" ] || { echo "transfer: $SRC is not a published bundle" >&2; exit 1; }
[ ! -e "$DEST/$name" ] || { echo "transfer: $DEST/$name already exists" >&2; exit 1; }
mkdir -p "$DEST"
tmp="$DEST/.incoming-$name"
rm -rf "$tmp"; mkdir "$tmp"
cp -p "$SRC"/* "$tmp"/
while read -r want file; do
    [ "$(sha "$tmp/$file")" = "$want" ] || { echo "transfer: checksum mismatch on $file; leaving $tmp unpublished" >&2; exit 1; }
done < "$tmp/SHA256SUMS"
mv "$tmp" "$DEST/$name"
echo "$DEST/$name"
