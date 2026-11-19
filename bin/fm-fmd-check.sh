#!/usr/bin/env bash
# fm-fmd-check.sh - upstream-sync contract check for the fmd sidecar.
#
# Run this for every upstream sync batch before the batch merges.
# It proves three things without touching live fleet state:
#   1. Each upstream-owned script (fm-watch.sh, fm-crew-state.sh,
#      fm-spawn.sh) carries at most one fmd seam line.
#   2. fmd's open-decisions output matches bin/fm-classify-lib.sh's
#      status_open_decisions on every fixture under fmd/fixtures/, once
#      with the default verbs and once with the FM_CLASSIFY_* overrides.
#   3. `fmd check` passes on a fixture home built from those fixtures.
#
# Usage: bin/fm-fmd-check.sh [--home <FM_HOME>] [--build]
#   --home   Home whose config/supervision mode is reported.
#            Defaults to $FM_HOME, then this checkout.
#   --build  Build fmd with cargo first (debug profile) when cargo exists.
#
# Without --build the check uses the binary fm_fmd_bin resolves.
# Without cargo, --build is a no-op and the resolved binary is used.
# When no binary and no cargo exist, a legacy-mode home reports a skip
# and exits 0, because bash alone is a complete supported posture.
# A shadow or fmd home with no usable binary fails, because that home
# asked for fmd and silently falling back would hide the drift.
# With cargo present and no binary, the check builds the debug binary.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)" || exit 1
ROOT=${SCRIPT_DIR%/*}
HOME_ARG=${FM_HOME:-$ROOT}
BUILD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --home) [ $# -ge 2 ] || { printf 'fm-fmd-check: --home needs a value\n' >&2; exit 2; }; HOME_ARG=$2; shift 2 ;;
    --build) BUILD=1; shift ;;
    --help|-h) sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'fm-fmd-check: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done

# shellcheck source=bin/fm-fmd-seam.sh
. "$SCRIPT_DIR/fm-fmd-seam.sh"
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"

fail=0
mode=$(fm_fmd_mode "$HOME_ARG")

# 1. Seam budget on upstream-owned scripts.
for script in fm-watch.sh fm-crew-state.sh fm-spawn.sh; do
  count=$(grep -c 'fm-fmd-seam' "$SCRIPT_DIR/$script" 2>/dev/null) || count=0
  if [ "$count" -gt 1 ]; then
    printf 'fm-fmd-check: FAIL %s carries %s seam lines (max 1)\n' "$script" "$count" >&2
    fail=1
  fi
done

# Resolve or build the binary.
bin_path=$(fm_fmd_bin)
if command -v cargo >/dev/null 2>&1 && { [ "$BUILD" = 1 ] || [ -z "$bin_path" ]; }; then
  if ! cargo build --manifest-path "$ROOT/fmd/Cargo.toml" >/dev/null 2>&1; then
    printf 'fm-fmd-check: FAIL cargo build of fmd/\n' >&2
    exit 1
  fi
  bin_path=$(fm_fmd_bin)
fi
if [ -z "$bin_path" ]; then
  if [ "$mode" = legacy ]; then
    printf 'fm-fmd-check: skip mode=legacy (no fmd binary; bash is the supported posture)\n'
    [ "$fail" = 0 ] || exit 1
    exit 0
  fi
  printf 'fm-fmd-check: FAIL mode=%s but no fmd binary is usable\n' "$mode" >&2
  exit 1
fi

# 2. Parity on fixtures. Command substitution strips trailing newlines on
# both sides, so the bash fold's missing final newline cannot false-fail.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-fmd-check.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home/state" "$tmp/home/config"
printf '%s\n' "$mode" > "$tmp/home/config/supervision"
parity() { # <status-file> <label> -> 0 when bash and fmd agree
  local bash_out fmd_out
  bash_out=$(status_open_decisions "$1")
  fmd_out=$("$bin_path" open-decisions "$1") || fmd_out='__fmd_failed__'
  [ "$bash_out" = "$fmd_out" ] && return 0
  printf 'fm-fmd-check: FAIL parity %s (%s)\n  bash: %s\n  fmd:  %s\n' "$1" "$2" "$bash_out" "$fmd_out" >&2
  return 1
}
for status_file in "$ROOT"/fmd/fixtures/*.status; do
  parity "$status_file" defaults || fail=1
  (
    export FM_CLASSIFY_RESOLVE_VERB=answered FM_CLASSIFY_CAPTAIN_HELD_VERB=parked \
      FM_CLASSIFY_RESERVED_KEY_PREFIXES=own-
    parity "$status_file" overrides
  ) || fail=1
  [ -L "$status_file" ] && continue
  base=${status_file##*/}
  cp "$status_file" "$tmp/home/state/$base"
  meta_file=${status_file%.status}.meta
  [ -f "$meta_file" ] && [ ! -L "$meta_file" ] && cp "$meta_file" "$tmp/home/state/${base%.status}.meta"
done

# 3. Fixture-home check.
if ! check_out=$("$bin_path" check --home "$tmp/home" 2>&1); then
  printf 'fm-fmd-check: FAIL fmd check on fixture home: %s\n' "$check_out" >&2
  fail=1
else
  printf 'fm-fmd-check: %s\n' "$check_out"
fi

if [ "$fail" != 0 ]; then
  exit 1
fi
printf 'fm-fmd-check: ok mode=%s bin=%s\n' "$mode" "$bin_path"
