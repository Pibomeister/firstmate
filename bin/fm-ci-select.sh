#!/usr/bin/env bash
# fm-ci-select.sh - classify changed paths for CI job skip.
#
# Prints exactly one stdout line: mode=full or mode=skip.
# mode=skip only when the path list is non-empty and every path matches a
# skip glob below. Any other path, or an empty list, is mode=full so a
# missing diff cannot skip the suite. Usage errors exit 2 with no mode line.
#
# Skip globs (bash case patterns; * matches /). These are docs, license,
# assets, gitignore, and the vendored Cursor overlay paths that
# families_for_changed_path maps to no tests. Everything else, including
# .github/, bin/, tests/, AGENTS.md, and shared test helpers, is full.
#   docs/*
#   assets/*
#   README.md
#   LICENSE
#   CONTRIBUTING.md
#   GROK_BOT.md
#   VISION.md
#   .gitignore
#   .cursor/skills/*
#   .cursor/agents/*
#   .cursor/rules/*
#   .cursor/roles/*
#   .cursor/references/*
#   .cursor/schemas/*
#   .cursor/templates/*
#   .cursor/licenses/*
#   .cursor/catalog.yaml
#
# A push to main does not call this script. ci.yml forces mode=full there.
#
# Usage:
#   fm-ci-select.sh --files-from -
#   fm-ci-select.sh --base <git-ref>
#   fm-ci-select.sh --help
#
# --files-from - reads one relative path per line from stdin.
# --base <ref> reads git diff --name-only <ref>...HEAD from the current
# directory, which CI has checked out.
set -eu

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

# True when $1 may skip the heavy CI lanes.
path_is_skip() {
  local path=$1
  path=${path#./}
  case "$path" in
    docs/*|assets/*|README.md|LICENSE|CONTRIBUTING.md|GROK_BOT.md|VISION.md|.gitignore|\
    .cursor/skills/*|.cursor/agents/*|.cursor/rules/*|.cursor/roles/*|\
    .cursor/references/*|.cursor/schemas/*|.cursor/templates/*|.cursor/licenses/*|\
    .cursor/catalog.yaml)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

emit_mode() {
  local mode=$1
  printf 'mode=%s\n' "$mode"
}

classify_paths() {
  local path n=0 first_full= paths_word
  while IFS= read -r path; do
    [ -n "$path" ] || continue
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
  log "mode=skip ($n $paths_word match skip globs)"
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
  git diff --name-only "${BASE_REF}...HEAD" | classify_paths
  exit 0
fi

die "usage: fm-ci-select.sh --files-from - | --base <git-ref>"
