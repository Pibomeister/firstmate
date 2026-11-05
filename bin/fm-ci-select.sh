#!/usr/bin/env bash
# fm-ci-select.sh - classify changed paths for CI job skip.
#
# Prints exactly one stdout line: mode=full or mode=skip.
# mode=skip only when the path list is non-empty, every path exists in
# this checkout, and every path is on the skip allowlist below. Any other
# path, a deleted or missing path, or an empty list, is mode=full so a
# missing diff cannot skip the suite. Usage errors exit 2 with no mode
# line.
#
# The allowlist is exact paths. A path may skip only when it is unread
# (no literal match in tests/ or bin/, and not selected by
# docs/documentation-audiences.json trackedPatterns or that inventory)
# or when a skip-mode check covers it. Repo invariants runs
# bin/fm-doc-audience-check.sh so glob-read Markdown still fails on a
# broken link, anchor, or owner pointer. tests/fm-ci-select.test.sh
# enforces that coverage. It is not derived from
# families_for_changed_path: that map is a --changed selector, and its
# empty arms are not a skip oracle.
#
# Skip allowlist:
#   GROK_BOT.md
#   VISION.md
#   assets/banner.png
#   docs/documentation-audiences.md
#   docs/examples/wedge-alarm
#   docs/opencode-2-plugin-port-scope.md
#   docs/pi-supervision-branch-poster.svg
#   docs/scripts.md
#
# ci.yml also forces mode=full before it trusts this script when the
# diff includes bin/fm-ci-select.sh, bin/fm-test-run.sh, or .github/.
# A push to main does not call this script. ci.yml forces mode=full there.
#
# Usage:
#   fm-ci-select.sh --files-from -
#   fm-ci-select.sh --base <git-ref>
#   fm-ci-select.sh --list-skip
#   fm-ci-select.sh --list-skip-checks
#   fm-ci-select.sh --help
#
# --files-from - reads one relative path per line from stdin.
# --base <ref> reads git diff --name-only --no-renames <ref>...HEAD from
# the current directory, which CI has checked out. --no-renames lists
# both sides of a rename so a bin/ path moved under docs/ still maps.
# --list-skip prints the allowlist, one path per line, and exits 0.
# --list-skip-checks prints the commands Repo invariants runs on skip,
# one per line, and exits 0.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

skip_allowlist() {
  cat <<'EOF'
GROK_BOT.md
VISION.md
assets/banner.png
docs/documentation-audiences.md
docs/examples/wedge-alarm
docs/opencode-2-plugin-port-scope.md
docs/pi-supervision-branch-poster.svg
docs/scripts.md
EOF
}

skip_checks() {
  cat <<'EOF'
bin/fm-doc-audience-check.sh
EOF
}

# True when $1 exists in this checkout and is on the skip allowlist.
path_is_skip() {
  local path=${1#./}
  [ -e "$ROOT/$path" ] || return 1
  skip_allowlist | grep -Fxq -- "$path"
}

classify_paths() {
  local path n=0 first_full='' paths_word
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    path=${path#./}
    n=$((n + 1))
    if [ -z "$first_full" ] && ! path_is_skip "$path"; then
      first_full=$path
    fi
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
  if [ -n "$first_full" ]; then
    log "mode=full ($first_full requires the full suite; $n $paths_word)"
    emit_mode full
    return 0
  fi
  if [ "$n" -eq 1 ]; then
    log "mode=skip (1 path is on the skip allowlist)"
  else
    log "mode=skip ($n paths are on the skip allowlist)"
  fi
  emit_mode skip
}

FILES_FROM=
BASE_REF=
LIST_SKIP=0
LIST_SKIP_CHECKS=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --list-skip)
      LIST_SKIP=1
      shift
      ;;
    --list-skip-checks)
      LIST_SKIP_CHECKS=1
      shift
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
      die "usage: fm-ci-select.sh --files-from - | --base <git-ref> | --list-skip | --list-skip-checks"
      ;;
  esac
done

if [ "$LIST_SKIP" -eq 1 ] && [ "$LIST_SKIP_CHECKS" -eq 1 ]; then
  die "use --list-skip or --list-skip-checks, not both"
fi

if [ "$LIST_SKIP" -eq 1 ]; then
  [ -z "$FILES_FROM" ] && [ -z "$BASE_REF" ] \
    || die "use --list-skip alone"
  skip_allowlist
  exit 0
fi

if [ "$LIST_SKIP_CHECKS" -eq 1 ]; then
  [ -z "$FILES_FROM" ] && [ -z "$BASE_REF" ] \
    || die "use --list-skip-checks alone"
  skip_checks
  exit 0
fi

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

die "usage: fm-ci-select.sh --files-from - | --base <git-ref> | --list-skip | --list-skip-checks"
