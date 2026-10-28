#!/usr/bin/env bash
# Shared marker-or-plain-checkout predicate for tracked hooks that must act only
# in a genuine firstmate primary home.
# This file is sourced by hook entrypoints and has no side effects on source.
# fm_primary_root_matches is split out so a caller can confirm primary-home
# identity before its gitignored state dir exists, such as to create it.

# shellcheck source=bin/fm-bash-compat-lib.sh
. "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; CDPATH='' cd -- "${d:-/}" && pwd)/fm-bash-compat-lib.sh"
# Return 0 when $1 carries a genuine secondmate-home marker.
fm_root_is_secondmate_home() {
  local marker="$1/.fm-secondmate-home" id LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Echo the parent-owned steering inbox of the genuine local secondmate home $1,
# <parent_home>/state/<id>.inbox, from its identity marker and parent record and
# never from the environment. Fails for a primary home, a remote route, or a
# missing or malformed record.
fm_secondmate_home_inbox() {
  local id
  fm_root_is_secondmate_home "$1" || return 1
  IFS= read -r id < "$1/.fm-secondmate-home" || return 1
  id=${id//[[:space:]]/}
  if ! command -v fm_secondmate_parent_record_parse >/dev/null 2>&1; then
    # shellcheck source=bin/fm-secondmate-parent-lib.sh
    . "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; CDPATH='' cd -- "${d:-/}" && pwd)/fm-secondmate-parent-lib.sh"
  fi
  fm_secondmate_parent_record_parse "$1/.fm-secondmate-parent" || return 1
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || return 1
  printf '%s/state/%s.inbox\n' "$FM_SECONDMATE_PARENT_HOME" "$id"
}

# Echo the branch named by $1's genuine linked-primary marker and return 0.
# The captain writes .fm-primary-home by hand in a primary home that is itself a
# linked git worktree (an Orca workspace, for example); its whitespace-stripped
# first line is the branch that home is meant to sit on. Never inferred.
fm_primary_home_branch() {
  local marker="$1/.fm-primary-home" branch LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r branch < "$marker" 2>/dev/null || [ -n "$branch" ] || return 1
  branch=${branch//[[:space:]]/}
  [ -n "$branch" ] || return 1
  case "$branch" in
    *[!A-Za-z0-9._/-]*|-*|/*|*/|*//*|*..*) return 1 ;;
  esac
  printf '%s\n' "$branch"
}

# Return 0 when $1 is a genuine primary root, regardless of whether its state
# dir exists yet. A valid secondmate or linked-primary marker includes that home.
# Otherwise only a plain checkout is primary, never a linked task worktree.
fm_primary_root_matches() {
  local root=$1 git_dir git_common_dir
  if ! fm_root_is_secondmate_home "$root" && ! fm_primary_home_branch "$root" >/dev/null; then
    git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    [ "$git_dir" = "$git_common_dir" ] || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
}

# Return 0 when $1 is a genuine primary root whose effective state dir $2
# already exists.
fm_primary_scope_matches() {
  local root=$1 state=$2
  fm_primary_root_matches "$root" && [ -d "$state" ]
}
