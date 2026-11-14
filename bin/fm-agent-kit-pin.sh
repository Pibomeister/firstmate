#!/usr/bin/env bash
# fm-agent-kit-pin.sh - prove the six pinned Cursor agent-kit overlay files
# match the recorded pin, and that ak.project.json review.cold_read and
# review.comprehension match the expected review.*= lines in the same
# .cursor/agent-kit.md pin record. Change those JSON fields and the two
# expected lines together. Non-network.
#
# Usage:
#   bin/fm-agent-kit-pin.sh
#   bin/fm-agent-kit-pin.sh --root <repo>
#
# Reads sha256 digests from <repo>/.cursor/agent-kit.md in GNU sha256sum form
# (`<64 hex>  <relative-path>`) and compares them to the files on disk.
# The required paths are .cursor/bin/ak, .cursor/bin/ak.js,
# .cursor/bin/ak-gate.mjs, .cursor/environment.json, tools/cursor/install.sh,
# and tools/cursor/bun-v1.3.14.sha256.
# Requires `shasum -a 256` or `sha256sum`, and python3 to read ak.project.json.
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

# Lines of the form review.cold_read=<value> or review.comprehension=<value>.
expected_review_setting() {
  local key=$1
  awk -F= -v k="$key" '
    $1 == k {
      print substr($0, length($1) + 2)
    }
  ' "$MANIFEST"
}

actual_review_setting() {
  local file=$1 key=$2
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to read $file"
  python3 - "$file" "$key" <<'PY'
import json, pathlib, sys
path, key = sys.argv[1], sys.argv[2]
try:
    data = json.loads(pathlib.Path(path).read_text())
except (OSError, UnicodeError, json.JSONDecodeError) as exc:
    sys.stderr.write(str(exc) + "\n")
    sys.exit(1)
review = data.get("review")
if not isinstance(review, dict) or key not in review:
    sys.exit(1)
value = review[key]
if not isinstance(value, str) or value == "":
    sys.exit(1)
print(value)
PY
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

PROJECT_RECORD="$ROOT/ak.project.json"
[ -f "$PROJECT_RECORD" ] || fail "missing ak.project.json"

while IFS= read -r key; do
  [ -n "$key" ] || continue
  field=${key#review.}
  expected=$(expected_review_setting "$key")
  [ "$(count_lines "$expected")" = 1 ] || fail "need exactly one recorded $key line"
  actual=$(actual_review_setting "$PROJECT_RECORD" "$field") \
    || fail "missing $key in ak.project.json"
  if [ "$actual" != "$expected" ]; then
    fail "$key is $actual, expected $expected"
  fi
  if [ -n "$ok_parts" ]; then
    ok_parts="$ok_parts $key=$actual"
  else
    ok_parts="$key=$actual"
  fi
done <<'EOF'
review.cold_read
review.comprehension
EOF

printf 'fm-agent-kit-pin: ok %s\n' "$ok_parts"
