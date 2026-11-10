#!/usr/bin/env bash
# Prove bin/fm-agent-kit-pin.sh accepts a matching pin and refuses drift.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PIN="$ROOT/bin/fm-agent-kit-pin.sh"
TMP_ROOT=$(fm_test_tmproot fm-agent-kit-pin)
PINNED_RELS=(
  .cursor/bin/ak
  .cursor/bin/ak.js
  .cursor/bin/ak-gate.mjs
  .cursor/environment.json
  tools/cursor/install.sh
  tools/cursor/bun-v1.3.14.sha256
)
ZERO_DIGEST=0000000000000000000000000000000000000000000000000000000000000000

write_pin_files() {  # <repo>
  local repo=$1
  mkdir -p "$repo/.cursor/bin" "$repo/tools/cursor"
  printf 'ak-bytes\n' >"$repo/.cursor/bin/ak"
  printf 'js-bytes\n' >"$repo/.cursor/bin/ak.js"
  printf 'gate-bytes\n' >"$repo/.cursor/bin/ak-gate.mjs"
  printf '{"name":"agent-kit"}\n' >"$repo/.cursor/environment.json"
  printf 'install-bytes\n' >"$repo/tools/cursor/install.sh"
  printf 'sums-bytes\n' >"$repo/tools/cursor/bun-v1.3.14.sha256"
}

digest_text() {  # hashes the file named in $1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

matching_lines() {  # <repo> -> writes one GNU sha256sum line per pinned path
  local repo=$1 rel
  for rel in "${PINNED_RELS[@]}"; do
    printf '%s  %s\n' "$(digest_text "$repo/$rel")" "$rel"
  done
}

write_matching_fixture() {  # <repo>
  local repo=$1
  write_pin_files "$repo"
  {
    printf '%s\n\n' '# fixture pin'
    printf '%s\n' '```'
    matching_lines "$repo"
    printf '%s\n' '```'
  } >"$repo/.cursor/agent-kit.md"
}

replace_recorded_digest() {  # <manifest> <rel> <digest>
  local manifest=$1 rel=$2 digest=$3 tmp
  tmp="$manifest.new"
  awk -v p="$rel" -v d="$digest" '
    length($1) == 64 && $1 ~ /^[0-9a-f]+$/ && NF >= 2 {
      path = substr($0, index($0, $2))
      if (path == p) {
        print d "  " p
        next
      }
    }
    { print }
  ' "$manifest" >"$tmp"
  mv "$tmp" "$manifest"
}

test_repository_pin_matches() {
  local out
  out=$("$PIN") || fail "repository agent-kit bin pin does not match .cursor/agent-kit.md"
  assert_contains "$out" "fm-agent-kit-pin: ok" "pin check did not report ok"
  assert_contains "$out" "ak.js=" "pin check did not report the ak.js digest"
  assert_contains "$out" "environment.json=" "pin check did not report the environment.json digest"
  assert_contains "$out" "install.sh=" "pin check did not report the install.sh digest"
  assert_contains "$out" "bun-v1.3.14.sha256=" "pin check did not report the bun sha256 digest"
  pass "the recorded agent-kit pin digests match the vendored files"
}

test_matching_fixture_passes() {
  local repo out
  repo="$TMP_ROOT/match"
  write_matching_fixture "$repo"
  out=$("$PIN" --root "$repo") || fail "matching fixture pin was refused: $out"
  assert_contains "$out" "fm-agent-kit-pin: ok" "matching fixture did not report ok"
  pass "a fixture whose recorded digests match its pinned files is accepted"
}

test_tampering_each_pinned_file_is_refused() {
  local rel repo actual rc out
  for rel in "${PINNED_RELS[@]}"; do
    repo="$TMP_ROOT/tamper-${rel//\//_}"
    write_matching_fixture "$repo"
    actual=$(digest_text "$repo/$rel")
    replace_recorded_digest "$repo/.cursor/agent-kit.md" "$rel" "$ZERO_DIGEST"
    rc=0
    out=$("$PIN" --root "$repo" 2>&1) || rc=$?
    expect_code 1 "$rc" "tampering $rel must fail"
    assert_contains "$out" "$actual" "refusal did not name the actual digest for $rel"
  done
  pass "tampering each pinned file is refused"
}

test_missing_gate_is_refused() {
  local repo out rc
  repo="$TMP_ROOT/missing-gate"
  write_matching_fixture "$repo"
  rm -f "$repo/.cursor/bin/ak-gate.mjs"
  rc=0
  out=$("$PIN" --root "$repo" 2>&1) || rc=$?
  expect_code 1 "$rc" "a missing ak-gate.mjs must fail"
  assert_contains "$out" "missing .cursor/bin/ak-gate.mjs" "refusal did not name the missing gate file"
  pass "a missing vendored bin file is refused"
}

test_missing_ak_js_is_refused() {
  local repo out rc
  repo="$TMP_ROOT/missing-js"
  write_matching_fixture "$repo"
  rm -f "$repo/.cursor/bin/ak.js"
  rc=0
  out=$("$PIN" --root "$repo" 2>&1) || rc=$?
  expect_code 1 "$rc" "a missing ak.js must fail"
  assert_contains "$out" "missing .cursor/bin/ak.js" "refusal did not name the missing ak.js file"
  pass "a missing .cursor/bin/ak.js is refused"
}

test_duplicate_recorded_digest_is_refused() {
  local repo ak_hash out rc
  repo="$TMP_ROOT/dup"
  write_pin_files "$repo"
  ak_hash=$(digest_text "$repo/.cursor/bin/ak")
  {
    matching_lines "$repo"
    printf '%s  .cursor/bin/ak\n' "$ak_hash"
  } >"$repo/.cursor/agent-kit.md"
  rc=0
  out=$("$PIN" --root "$repo" 2>&1) || rc=$?
  expect_code 1 "$rc" "duplicate recorded ak digest lines must fail"
  assert_contains "$out" "exactly one recorded digest for .cursor/bin/ak" \
    "refusal did not name the duplicate ak digest"
  pass "duplicate recorded digest lines are refused"
}

fm_test_run \
  test_repository_pin_matches \
  test_matching_fixture_passes \
  test_tampering_each_pinned_file_is_refused \
  test_missing_gate_is_refused \
  test_missing_ak_js_is_refused \
  test_duplicate_recorded_digest_is_refused
