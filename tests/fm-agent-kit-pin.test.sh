#!/usr/bin/env bash
# Prove bin/fm-agent-kit-pin.sh accepts a matching pin and refuses drift.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PIN="$ROOT/bin/fm-agent-kit-pin.sh"
TMP_ROOT=$(fm_test_tmproot fm-agent-kit-pin)

write_pin_fixture() {  # <repo> <ak-body> <gate-body> <ak-hash-line> <gate-hash-line>
  local repo=$1 ak_body=$2 gate_body=$3 ak_line=$4 gate_line=$5
  mkdir -p "$repo/.cursor/bin"
  printf '%s\n' "$ak_body" >"$repo/.cursor/bin/ak"
  printf '%s\n' "$gate_body" >"$repo/.cursor/bin/ak-gate.mjs"
  cat >"$repo/.cursor/agent-kit.md" <<EOF
# fixture pin

\`\`\`
$ak_line
$gate_line
\`\`\`
EOF
}

digest_text() {  # writes stdin file via arg
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

test_repository_pin_matches() {
  local out
  out=$("$PIN") || fail "repository agent-kit bin pin does not match .cursor/agent-kit.md"
  assert_contains "$out" "fm-agent-kit-pin: ok" "pin check did not report ok"
  pass "the recorded agent-kit bin digests match the vendored files"
}

test_matching_fixture_passes() {
  local repo ak_hash gate_hash out
  repo="$TMP_ROOT/match"
  write_pin_fixture "$repo" "ak-bytes" "gate-bytes" "pending" "pending"
  ak_hash=$(digest_text "$repo/.cursor/bin/ak")
  gate_hash=$(digest_text "$repo/.cursor/bin/ak-gate.mjs")
  write_pin_fixture "$repo" "ak-bytes" "gate-bytes" \
    "$ak_hash  .cursor/bin/ak" \
    "$gate_hash  .cursor/bin/ak-gate.mjs"
  out=$("$PIN" --root "$repo") || fail "matching fixture pin was refused: $out"
  assert_contains "$out" "fm-agent-kit-pin: ok" "matching fixture did not report ok"
  pass "a fixture whose recorded digests match its bin files is accepted"
}

test_mismatched_ak_is_refused() {
  local repo ak_hash gate_hash out rc
  repo="$TMP_ROOT/mismatch"
  write_pin_fixture "$repo" "ak-bytes" "gate-bytes" "pending" "pending"
  ak_hash=$(digest_text "$repo/.cursor/bin/ak")
  gate_hash=$(digest_text "$repo/.cursor/bin/ak-gate.mjs")
  write_pin_fixture "$repo" "ak-bytes" "gate-bytes" \
    "0000000000000000000000000000000000000000000000000000000000000000  .cursor/bin/ak" \
    "$gate_hash  .cursor/bin/ak-gate.mjs"
  set +e
  out=$("$PIN" --root "$repo" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "a drifted .cursor/bin/ak digest must fail"
  assert_contains "$out" "$ak_hash" "refusal did not name the actual ak digest"
  pass "a drifted .cursor/bin/ak digest is refused"
}

test_missing_bin_is_refused() {
  local repo ak_hash gate_hash out rc
  repo="$TMP_ROOT/missing"
  write_pin_fixture "$repo" "ak-bytes" "gate-bytes" "pending" "pending"
  ak_hash=$(digest_text "$repo/.cursor/bin/ak")
  gate_hash=$(digest_text "$repo/.cursor/bin/ak-gate.mjs")
  write_pin_fixture "$repo" "ak-bytes" "gate-bytes" \
    "$ak_hash  .cursor/bin/ak" \
    "$gate_hash  .cursor/bin/ak-gate.mjs"
  rm -f "$repo/.cursor/bin/ak-gate.mjs"
  set +e
  out=$("$PIN" --root "$repo" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "a missing ak-gate.mjs must fail"
  assert_contains "$out" "missing .cursor/bin/ak-gate.mjs" "refusal did not name the missing gate file"
  pass "a missing vendored bin file is refused"
}

test_duplicate_recorded_digest_is_refused() {
  local repo ak_hash gate_hash out rc
  repo="$TMP_ROOT/dup"
  mkdir -p "$repo/.cursor/bin"
  printf 'ak-bytes\n' >"$repo/.cursor/bin/ak"
  printf 'gate-bytes\n' >"$repo/.cursor/bin/ak-gate.mjs"
  ak_hash=$(digest_text "$repo/.cursor/bin/ak")
  gate_hash=$(digest_text "$repo/.cursor/bin/ak-gate.mjs")
  cat >"$repo/.cursor/agent-kit.md" <<EOF
$ak_hash  .cursor/bin/ak
$ak_hash  .cursor/bin/ak
$gate_hash  .cursor/bin/ak-gate.mjs
EOF
  set +e
  out=$("$PIN" --root "$repo" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "duplicate recorded ak digest lines must fail"
  assert_contains "$out" "exactly one recorded digest for .cursor/bin/ak" \
    "refusal did not name the duplicate ak digest"
  pass "duplicate recorded digest lines are refused"
}

fm_test_run \
  test_repository_pin_matches \
  test_matching_fixture_passes \
  test_mismatched_ak_is_refused \
  test_missing_bin_is_refused \
  test_duplicate_recorded_digest_is_refused
