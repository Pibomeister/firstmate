#!/usr/bin/env bash
# fm-ci-select.sh - classify changed paths for CI job skip.
#
# Prints exactly one stdout line: mode=full or mode=skip.
# mode=skip only when the path list is non-empty and every path maps to
# no tests in families_for_changed_path. Any other path, including one
# that maps to a family, a script, or __unmapped__, or an empty list, is
# mode=full so a missing diff cannot skip the suite. Usage errors exit 2
# with no mode line.
#
# Skip is derived from that map, not a second glob list. ci.yml also
# forces mode=full before it trusts this script when the diff includes
# bin/fm-ci-select.sh, bin/fm-test-run.sh, or .github/.
#
# A push to main does not call this script. ci.yml forces mode=full there.
#
# Usage:
#   fm-ci-select.sh --files-from -
#   fm-ci-select.sh --base <git-ref>
#   fm-ci-select.sh --help
#
# --files-from - reads one relative path per line from stdin.
# --base <ref> reads git diff --name-only --no-renames <ref>...HEAD from
# the current directory, which CI has checked out. --no-renames lists
# both sides of a rename so a bin/ path moved under docs/ still maps.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAPPER="$ROOT/bin/fm-test-run.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-ci-select: %s\n' "$*" >&2
  exit 2
}

log() {
  printf 'fm-ci-select: %s\n' "$*" >&2
}

emit_mode() {
  local mode=$1
  printf 'mode=%s\n' "$mode"
}

# Paths whose changed-path map is non-empty require the full suite.
mapped_paths() {
  [ -x "$MAPPER" ] || die "changed-path mapper is missing: $MAPPER"
  "$MAPPER" --map-changed-paths
}

classify_paths() {
  local path n=0 first_full='' paths_word mapped
  local -a paths=()
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    path=${path#./}
    paths+=("$path")
    n=$((n + 1))
  done
  if [ "$n" -eq 0 ]; then
    log "mode=full (empty path list; refuse to skip)"
    emit_mode full
    return 0
  fi
  if [ "$n" -eq 1 ]; then
    paths_word=path
  else
    paths_word=paths
  fi
  mapped=$(printf '%s\n' "${paths[@]}" | mapped_paths)
  if [ -n "$mapped" ]; then
    first_full=$(printf '%s\n' "$mapped" | awk 'NF { print; exit }')
    log "mode=full ($first_full requires the full suite; $n $paths_word)"
    emit_mode full
    return 0
  fi
  if [ "$n" -eq 1 ]; then
    log "mode=skip (1 path maps to no tests)"
  else
    log "mode=skip ($n paths map to no tests)"
  fi
  emit_mode skip
}

FILES_FROM=
BASE_REF=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --files-from)
      [ "$#" -ge 2 ] || die "usage: fm-ci-select.sh --files-from -"
      FILES_FROM=$2
      shift 2
      ;;
    --base)
      [ "$#" -ge 2 ] || die "usage: fm-ci-select.sh --base <git-ref>"
      BASE_REF=$2
      shift 2
      ;;
    *)
      die "usage: fm-ci-select.sh --files-from - | --base <git-ref>"
      ;;
  esac
done

if [ -n "$FILES_FROM" ] && [ -n "$BASE_REF" ]; then
  die "use --files-from or --base, not both"
fi

if [ -n "$FILES_FROM" ]; then
  [ "$FILES_FROM" = - ] || die "usage: fm-ci-select.sh --files-from -"
  classify_paths
  exit 0
fi

if [ -n "$BASE_REF" ]; then
  git rev-parse --verify "$BASE_REF" >/dev/null 2>&1 \
    || die "changed-file base ref not found: $BASE_REF"
  git diff --name-only --no-renames "${BASE_REF}...HEAD" | classify_paths
  exit 0
fi

die "usage: fm-ci-select.sh --files-from - | --base <git-ref>"
