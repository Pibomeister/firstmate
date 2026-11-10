#!/usr/bin/env bash
# fm-agent-kit-pin.sh - prove the six pinned Cursor agent-kit overlay files match the recorded pin.
#
# Usage:
#   bin/fm-agent-kit-pin.sh
#   bin/fm-agent-kit-pin.sh --root <repo>
#
# Reads sha256 digests from <repo>/.cursor/agent-kit.md in GNU sha256sum form
# (`<64 hex>  <relative-path>`) and compares them to the files on disk.
# The required paths are .cursor/bin/ak, .cursor/bin/ak.js,
# .cursor/bin/ak-gate.mjs, .cursor/environment.json, tools/cursor/install.sh,
# and tools/cursor/bun-v1.3.14.sha256. Non-network.
# Requires `shasum -a 256` or `sha256sum`.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  printf 'Usage: %s [--root <repo>]\n' "$(basename "$0")" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ $# -ge 2 ] || usage
      ROOT="$(cd "$2" && pwd)"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

digest_file() {
  local file=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    printf 'fm-agent-kit-pin: shasum or sha256sum is required\n' >&2
    return 1
  fi
}

fail() {
  printf 'fm-agent-kit-pin: %s\n' "$1" >&2
  exit 1
}

count_lines() {
  local text=$1 n
  n=$(printf '%s' "$text" | grep -c . || true)
  printf '%s\n' "$n"
}

# GNU sha256sum form: 64 hex, two spaces, the relative path.
expected_digest() {
  local rel=$1
  awk -v p="$rel" '
    length($1) == 64 && $1 ~ /^[0-9a-f]+$/ && NF >= 2 {
      path = substr($0, index($0, $2))
      if (path == p) print $1
    }
  ' "$MANIFEST"
}

MANIFEST="$ROOT/.cursor/agent-kit.md"
[ -f "$MANIFEST" ] || fail "missing .cursor/agent-kit.md"

ok_parts=
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ -f "$ROOT/$rel" ] || fail "missing $rel"
  expected=$(expected_digest "$rel")
  [ "$(count_lines "$expected")" = 1 ] || fail "need exactly one recorded digest for $rel"
  actual=$(digest_file "$ROOT/$rel")
  if [ "$actual" != "$expected" ]; then
    fail "$rel digest $actual does not match recorded $expected"
  fi
  if [ -n "$ok_parts" ]; then
    ok_parts="$ok_parts ${rel##*/}=$actual"
  else
    ok_parts="${rel##*/}=$actual"
  fi
done <<'EOF'
.cursor/bin/ak
.cursor/bin/ak.js
.cursor/bin/ak-gate.mjs
.cursor/environment.json
tools/cursor/install.sh
tools/cursor/bun-v1.3.14.sha256
EOF

printf 'fm-agent-kit-pin: ok %s\n' "$ok_parts"
