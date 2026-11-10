#!/usr/bin/env bash
# Prove bin/fm-agent-kit-pin.sh accepts a matching pin and refuses drift.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PIN="$ROOT/bin/fm-agent-kit-pin.sh"
TMP_ROOT=$(fm_test_tmproot fm-agent-kit-pin)

write_pin_fixture() {  # <repo> <ak-body> <js-body> <gate-body> <ak-line> <js-line> <gate-line>
  local repo=$1 ak_body=$2 js_body=$3 gate_body=$4 ak_line=$5 js_line=$6 gate_line=$7
  mkdir -p "$repo/.cursor/bin"
  printf '%s\n' "$ak_body" >"$repo/.cursor/bin/ak"
  printf '%s\n' "$js_body" >"$repo/.cursor/bin/ak.js"
  printf '%s\n' "$gate_body" >"$repo/.cursor/bin/ak-gate.mjs"
  cat >"$repo/.cursor/agent-kit.md" <<EOF
# fixture pin

\`\`\`
$ak_line
$js_line
$gate_line
\`\`\`
EOF
}

digest_text() {  # hashes the file named in $1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

matching_lines() {  # <repo> -> writes ak.js gate hash lines on stdout
  local repo=$1
  printf '%s  .cursor/bin/ak\n' "$(digest_text "$repo/.cursor/bin/ak")"
  printf '%s  .cursor/bin/ak.js\n' "$(digest_text "$repo/.cursor/bin/ak.js")"
  printf '%s  .cursor/bin/ak-gate.mjs\n' "$(digest_text "$repo/.cursor/bin/ak-gate.mjs")"
}

write_matching_fixture() {  # <repo>
  local repo=$1 ak_line js_line gate_line
  write_pin_fixture "$repo" "ak-bytes" "js-bytes" "gate-bytes" "pending" "pending" "pending"
  {
    read -r ak_line
    read -r js_line
    read -r gate_line
  } < <(matching_lines "$repo")
  write_pin_fixture "$repo" "ak-bytes" "js-bytes" "gate-bytes" "$ak_line" "$js_line" "$gate_line"
}

test_repository_pin_matches() {
  local out
  out=$("$PIN") || fail "repository agent-kit bin pin does not match .cursor/agent-kit.md"
  assert_contains "$out" "fm-agent-kit-pin: ok" "pin check did not report ok"
  assert_contains "$out" "ak.js=" "pin check did not report the ak.js digest"
  pass "the recorded agent-kit bin digests match the vendored files"
}

test_matching_fixture_passes() {
  local repo out
  repo="$TMP_ROOT/match"
  write_matching_fixture "$repo"
  out=$("$PIN" --root "$repo") || fail "matching fixture pin was refused: $out"
  assert_contains "$out" "fm-agent-kit-pin: ok" "matching fixture did not report ok"
  pass "a fixture whose recorded digests match its bin files is accepted"
}

test_mismatched_ak_is_refused() {
  local repo ak_hash out rc ak_line js_line gate_line
  repo="$TMP_ROOT/mismatch-ak"
  write_matching_fixture "$repo"
  ak_hash=$(digest_text "$repo/.cursor/bin/ak")
  {
    read -r ak_line
    read -r js_line
    read -r gate_line
  } < <(matching_lines "$repo")
  write_pin_fixture "$repo" "ak-bytes" "js-bytes" "gate-bytes" \
    "0000000000000000000000000000000000000000000000000000000000000000  .cursor/bin/ak" \
    "$js_line" "$gate_line"
  rc=0
  out=$("$PIN" --root "$repo" 2>&1) || rc=$?
  expect_code 1 "$rc" "a drifted .cursor/bin/ak digest must fail"
  assert_contains "$out" "$ak_hash" "refusal did not name the actual ak digest"
  pass "a drifted .cursor/bin/ak digest is refused"
}

test_mismatched_ak_js_is_refused() {
  local repo js_hash out rc ak_line js_line gate_line
  repo="$TMP_ROOT/mismatch-js"
  write_matching_fixture "$repo"
  js_hash=$(digest_text "$repo/.cursor/bin/ak.js")
  {
    read -r ak_line
    read -r js_line
    read -r gate_line
  } < <(matching_lines "$repo")
  write_pin_fixture "$repo" "ak-bytes" "js-bytes" "gate-bytes" \
    "$ak_line" \
    "0000000000000000000000000000000000000000000000000000000000000000  .cursor/bin/ak.js" \
    "$gate_line"
  rc=0
  out=$("$PIN" --root "$repo" 2>&1) || rc=$?
  expect_code 1 "$rc" "a drifted .cursor/bin/ak.js digest must fail"
  assert_contains "$out" "$js_hash" "refusal did not name the actual ak.js digest"
  pass "a drifted .cursor/bin/ak.js digest is refused"
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
  local repo ak_hash js_hash gate_hash out rc
  repo="$TMP_ROOT/dup"
  mkdir -p "$repo/.cursor/bin"
  printf 'ak-bytes\n' >"$repo/.cursor/bin/ak"
  printf 'js-bytes\n' >"$repo/.cursor/bin/ak.js"
  printf 'gate-bytes\n' >"$repo/.cursor/bin/ak-gate.mjs"
  ak_hash=$(digest_text "$repo/.cursor/bin/ak")
  js_hash=$(digest_text "$repo/.cursor/bin/ak.js")
  gate_hash=$(digest_text "$repo/.cursor/bin/ak-gate.mjs")
  cat >"$repo/.cursor/agent-kit.md" <<EOF
$ak_hash  .cursor/bin/ak
$ak_hash  .cursor/bin/ak
$js_hash  .cursor/bin/ak.js
$gate_hash  .cursor/bin/ak-gate.mjs
EOF
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
  test_mismatched_ak_is_refused \
  test_mismatched_ak_js_is_refused \
  test_missing_gate_is_refused \
  test_missing_ak_js_is_refused \
  test_duplicate_recorded_digest_is_refused
