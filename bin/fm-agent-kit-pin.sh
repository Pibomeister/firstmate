#!/usr/bin/env bash
# fm-agent-kit-pin.sh - prove the vendored Cursor agent-kit bin files match the recorded pin.
#
# Usage:
#   bin/fm-agent-kit-pin.sh
#   bin/fm-agent-kit-pin.sh --root <repo>
#
# Reads sha256 digests from <repo>/.cursor/agent-kit.md in GNU sha256sum form
# (`<64 hex>  .cursor/bin/<name>`) and compares them to the files on disk.
# Non-network. Requires `shasum -a 256` or `sha256sum`.
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

MANIFEST="$ROOT/.cursor/agent-kit.md"
AK="$ROOT/.cursor/bin/ak"
GATE="$ROOT/.cursor/bin/ak-gate.mjs"

[ -f "$MANIFEST" ] || fail "missing .cursor/agent-kit.md"
[ -f "$AK" ] || fail "missing .cursor/bin/ak"
[ -f "$GATE" ] || fail "missing .cursor/bin/ak-gate.mjs"

expected_ak=$(sed -n 's/^\([0-9a-f]\{64\}\)  \.cursor\/bin\/ak$/\1/p' "$MANIFEST")
expected_gate=$(sed -n 's/^\([0-9a-f]\{64\}\)  \.cursor\/bin\/ak-gate\.mjs$/\1/p' "$MANIFEST")

[ "$(count_lines "$expected_ak")" = 1 ] || fail "need exactly one recorded digest for .cursor/bin/ak"
[ "$(count_lines "$expected_gate")" = 1 ] || fail "need exactly one recorded digest for .cursor/bin/ak-gate.mjs"

actual_ak=$(digest_file "$AK")
actual_gate=$(digest_file "$GATE")

if [ "$actual_ak" != "$expected_ak" ]; then
  fail ".cursor/bin/ak digest $actual_ak does not match recorded $expected_ak"
fi
if [ "$actual_gate" != "$expected_gate" ]; then
  fail ".cursor/bin/ak-gate.mjs digest $actual_gate does not match recorded $expected_gate"
fi

printf 'fm-agent-kit-pin: ok ak=%s ak-gate.mjs=%s\n' "$actual_ak" "$actual_gate"
