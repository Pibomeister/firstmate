#!/usr/bin/env bash
# Behavior tests for the fmd sidecar seam and upstream-sync check.
#
# The seam (bin/fm-fmd-seam.sh) is exercised directly.
# Parity against bin/fm-classify-lib.sh runs through the public check
# (bin/fm-fmd-check.sh), which compares the fmd binary's output to the
# bash fold on the checked-in fixtures.
# When cargo and a built fmd are both absent, the check reports its
# documented legacy skip and the test says so instead of passing silently.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_mode_defaults_to_legacy() {
  local home mode
  home=$(mktemp -d "${TMPDIR:-/tmp}/fm-fmd-test.XXXXXX") || fail "mktemp"
  # shellcheck source=bin/fm-fmd-seam.sh
  . "$ROOT/bin/fm-fmd-seam.sh"
  mode=$(fm_fmd_mode "$home")
  [ "$mode" = legacy ] || fail "absent config: mode=$mode, want legacy"
  mkdir -p "$home/config"
  printf 'bogus\n' > "$home/config/supervision"
  mode=$(fm_fmd_mode "$home")
  [ "$mode" = legacy ] || fail "bogus config: mode=$mode, want legacy"
  printf 'fmd \n' > "$home/config/supervision"
  mode=$(fm_fmd_mode "$home")
  [ "$mode" = legacy ] || fail "trailing space: mode=$mode, want legacy"
  printf 'fmd' > "$home/config/supervision"
  mode=$(fm_fmd_mode "$home")
  [ "$mode" = fmd ] || fail "unterminated first line: mode=$mode, want fmd"
  mkdir -p "$home/override"
  printf 'shadow\n' > "$home/override/supervision"
  mode=$(FM_CONFIG_OVERRIDE="$home/override" fm_fmd_mode "$home")
  [ "$mode" = shadow ] || fail "config override: mode=$mode, want shadow"
  rm -rf "$home"
  pass "mode reads the raw first line, honors the config override, and defaults to legacy"
}

test_defer_requires_fmd_mode_and_binary() {
  local home fake
  home=$(mktemp -d "${TMPDIR:-/tmp}/fm-fmd-test.XXXXXX") || fail "mktemp"
  mkdir -p "$home/config" "$home/bin"
  fake="$home/bin/fmd"
  printf '#!/bin/sh\nexit 0\n' > "$fake"
  chmod +x "$fake"
  printf 'shadow\n' > "$home/config/supervision"
  if FM_FMD_BIN="$fake" fm_fmd_defer "$home"; then
    fail "shadow mode must not defer to fmd"
  fi
  FM_FMD_BIN="$fake" fm_fmd_shadow "$home" || fail "shadow mode with binary must allow shadow reads"
  printf 'fmd\n' > "$home/config/supervision"
  FM_FMD_BIN="$fake" fm_fmd_defer "$home" || fail "fmd mode with binary must defer"
  if FM_FMD_BIN="$home/bin/missing" fm_fmd_defer "$home"; then
    fail "fmd mode without a binary must stay on bash"
  fi
  rm -rf "$home"
  pass "defer requires fmd mode plus a usable binary; shadow never defers"
}

test_bin_ignores_path() {
  local dir got
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-fmd-test.XXXXXX") || fail "mktemp"
  printf '#!/bin/sh\nexit 0\n' > "$dir/fmd"
  chmod +x "$dir/fmd"
  got=$(FM_FMD_BIN='' PATH="$dir:$PATH" fm_fmd_bin)
  [ "$got" != "$dir/fmd" ] || fail "an fmd on PATH must not count as the sidecar"
  rm -rf "$dir"
  pass "fm_fmd_bin never picks an fmd from PATH"
}

test_fmd_check_parity_or_documented_skip() {
  local out rc
  out=$("$ROOT/bin/fm-fmd-check.sh" --build 2>&1) && rc=0 || rc=$?
  if [ "$rc" != 0 ]; then
    fail "fm-fmd-check failed (rc=$rc): $out"
  fi
  case "$out" in
    *"fm-fmd-check: ok"*) pass "fm-fmd-check parity passes" ;;
    *"fm-fmd-check: skip mode=legacy"*)
      command -v cargo >/dev/null 2>&1 && fail "skip reported although cargo exists: $out"
      pass "fm-fmd-check documented legacy skip (no cargo, no binary)" ;;
    *) fail "fm-fmd-check gave an unrecognized verdict: $out" ;;
  esac
}

fm_test_run \
  test_mode_defaults_to_legacy \
  test_defer_requires_fmd_mode_and_binary \
  test_bin_ignores_path \
  test_fmd_check_parity_or_documented_skip
