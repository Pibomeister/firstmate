#!/usr/bin/env bash
# Remove linked git worktrees whose pull request is merged or closed.
#
# One decision line per linked worktree, and one line for each main checkout
# the scan sees. A main checkout is never removed. A worktree with a live
# process whose working directory is inside it is skipped. When that scan
# cannot be completed, the worktree is reported and left in place.
# Uncommitted tracked changes and non-ignored untracked files are reported
# and left in place. Ignored files, including private .env, .work, and .omc
# files, do not block removal. Decision lines name the worktree and the
# reason. They never include file contents.
# A worktree whose HEAD is not an ancestor of the pull request's head commit
# is reported and left in place. No branch is deleted.
# Removal is `git worktree remove` without --force. If Git refuses because it
# still treats ignored files as dirt, and a fresh status proves there is no
# tracked change and no non-ignored untracked file, removal is retried once
# with a single --force. A locked worktree is never forced.
# After at least one removal in a repository, `git worktree prune` runs once.
# --dry-run prints the same decisions and does not remove or prune.
#
# `scan` is the watcher entry. It appends the same decision lines to
# state/worktree-cleanup.log and prints nothing, so a pass does not wake
# supervision. A direct run prints each decision and appends it there when
# the state directory exists. The log keeps its newest 2000 lines once it
# passes 1 MiB.
# Set FM_WORKTREE_CLEANUP=0 to make `scan` exit without looking. A direct run
# still performs the requested pass. The scan stops after
# FM_WORKTREE_CLEANUP_BUDGET seconds (default 20) and continues on a later
# pass.
#
# With no project argument the pass covers this home's project clones
# ($FM_HOME/projects, or $FM_PROJECTS_OVERRIDE). A directory that is not the
# root of its own work tree is skipped. An explicit project argument is a
# clone path, a bare project name, or projects/<name>. Linked worktrees of
# that clone are included wherever they live.
#
# Usage:
#   fm-worktree-cleanup.sh [--dry-run] [scan] [<project-dir-or-name>]
#   fm-worktree-cleanup.sh --help
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"

DRY=0
SCAN=0
TARGET=
BUDGET=${FM_WORKTREE_CLEANUP_BUDGET:-20}
case "$BUDGET" in
  ''|*[!0-9]*|0) BUDGET=20 ;;
esac
START=$(date +%s)
BUDGET_LOGGED=0
LOG_FILE=
SCRATCH=

usage() {
  cat <<'EOF'
usage: fm-worktree-cleanup.sh [--dry-run] [scan] [<project-dir-or-name>]
       fm-worktree-cleanup.sh --help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --dry-run) DRY=1; shift ;;
    scan) SCAN=1; shift ;;
    --)
      shift
      break
      ;;
    -*)
      echo "worktree-cleanup: unknown option $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [ -n "$TARGET" ]; then
        echo "worktree-cleanup: only one project argument is accepted" >&2
        usage >&2
        exit 2
      fi
      TARGET=$1
      shift
      ;;
  esac
done
if [ "$#" -gt 0 ]; then
  echo "worktree-cleanup: only one project argument is accepted" >&2
  usage >&2
  exit 2
fi

if [ "$SCAN" -eq 1 ] && [ "${FM_WORKTREE_CLEANUP:-1}" = 0 ]; then
  exit 0
fi

cleanup_scratch() {
  [ -z "$SCRATCH" ] || rm -rf -- "$SCRATCH"
}
trap cleanup_scratch EXIT
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-worktree-cleanup.XXXXXX")

if [ -d "$STATE" ] && [ ! -L "$STATE" ]; then
  LOG_FILE=$STATE/worktree-cleanup.log
elif [ "$SCAN" -eq 1 ]; then
  echo "worktree-cleanup: state directory is unavailable" >&2
  exit 1
fi

emit() {
  local line=$1 size keep
  if [ "$SCAN" -eq 0 ]; then
    printf '%s\n' "$line"
  fi
  [ -n "$LOG_FILE" ] || return 0
  printf '%s\n' "$line" >> "$LOG_FILE"
  size=$(wc -c < "$LOG_FILE" | tr -d '[:space:]')
  if [ "$size" -gt 1048576 ]; then
    keep=$SCRATCH/log-tail
    tail -n 2000 "$LOG_FILE" > "$keep"
    mv -f -- "$keep" "$LOG_FILE"
  fi
}

budget_reached() {
  local now
  now=$(date +%s)
  [ $((now - START)) -ge "$BUDGET" ]
}

note_budget() {
  if [ "$BUDGET_LOGGED" -eq 0 ]; then
    emit "worktree-cleanup: stop budget reached"
    BUDGET_LOGGED=1
  fi
}

resolve_project_arg() {
  local arg=$1 candidate
  case "$arg" in
    projects/*)
      candidate="$PROJECTS/${arg#projects/}"
      if [ -d "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
      ;;
    */*)
      if [ -d "$arg" ]; then
        printf '%s\n' "$arg"
        return 0
      fi
      ;;
    *)
      candidate="$PROJECTS/$arg"
      if [ -d "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
      if [ -d "$arg" ]; then
        printf '%s\n' "$arg"
        return 0
      fi
      ;;
  esac
  return 1
}

# A clone root is the top of its own work tree. Git discovery walks upward, so
# a nested directory must not be treated as the repository that contains it.
clone_root_path() {
  local dir=$1 top abs
  [ -d "$dir" ] || return 1
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  abs=$(cd "$dir" && pwd -P) || return 1
  [ "$top" -ef "$abs" ] || return 1
  printf '%s\n' "$abs"
}

absolute_git_path() {
  local wt=$1 kind=$2 raw
  case "$kind" in
    git)
      raw=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) || return 1
      ;;
    common)
      raw=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
        || raw=$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null) \
        || return 1
      ;;
    *) return 1 ;;
  esac
  case "$raw" in
    /*) (cd "$raw" && pwd -P) ;;
    *) (cd "$wt" && cd "$raw" && pwd -P) ;;
  esac
}

# 0 when the path is the repository's main checkout, 1 when it is a linked
# worktree, and 2 when the distinction cannot be read.
is_main_worktree() {
  local wt=$1 git_dir common_dir
  git_dir=$(absolute_git_path "$wt" git) || return 2
  common_dir=$(absolute_git_path "$wt" common) || return 2
  if [ "$git_dir" = "$common_dir" ]; then
    return 0
  fi
  return 1
}

dirt_kind() {
  local wt=$1 line kind=clean status_file
  status_file=$SCRATCH/status
  git -C "$wt" status --porcelain=v1 --untracked-files=all -z > "$status_file" || return 1
  while IFS= read -r -d '' line; do
    case "$line" in
      '') continue ;;
      \?\?*) kind=untracked ;;
      *)
        printf 'tracked'
        return 0
        ;;
    esac
  done < "$status_file"
  printf '%s' "$kind"
}

pr_rows() {
  local wt=$1 branch=$2 json rows
  command -v gh >/dev/null 2>&1 || return 2
  command -v jq >/dev/null 2>&1 || return 2
  json=$(cd "$wt" && gh pr list --json number,state,headRefOid,url --head "$branch" --state all --limit 20 2>/dev/null) || return 1
  rows=$(printf '%s' "$json" | jq -r '
    if type != "array" then
      error("pull request list is not an array")
    else
      .[] | select(type == "object")
      | [
          (.number | tostring),
          (.state | tostring),
          (.headRefOid | tostring),
          (.url | tostring)
        ]
      | @tsv
    end' 2>/dev/null) || return 1
  printf '%s\n' "$rows"
}

valid_pr_row() {
  local number=$1 state=$2 head=$3 url=$4
  case "$number" in
    ''|*[!0-9]*|0|0*) return 1 ;;
  esac
  case "$state" in
    OPEN|open|MERGED|merged|CLOSED|closed) ;;
    *) return 1 ;;
  esac
  case "$head" in
    *[!0-9a-fA-F]*) return 1 ;;
  esac
  [ "${#head}" -eq 40 ] || [ "${#head}" -eq 64 ] || return 1
  case "$url" in
    *[[:space:]]*) return 1 ;;
    https://*) [ "${#url}" -le 500 ] || return 1 ;;
    *) return 1 ;;
  esac
}

canonical_state() {
  case "$1" in
    OPEN|open) printf 'OPEN' ;;
    MERGED|merged) printf 'MERGED' ;;
    CLOSED|closed) printf 'CLOSED' ;;
    *) return 1 ;;
  esac
}

remove_worktree() {
  local repo=$1 wt=$2 state=$3 url=$4 err kind
  if [ "$DRY" -eq 1 ]; then
    emit "worktree-cleanup: dry-run $wt pull request $state $url"
    return 0
  fi
  err=$SCRATCH/remove.err
  : > "$err"
  if git -C "$repo" worktree remove -- "$wt" 2>"$err"; then
    emit "worktree-cleanup: remove $wt pull request $state $url"
    REPO_REMOVED=1
    return 0
  fi
  if grep -q 'modified or untracked' "$err"; then
    kind=$(dirt_kind "$wt") || kind=unknown
    if [ "$kind" = clean ] && git -C "$repo" worktree remove --force -- "$wt" 2>"$err"; then
      emit "worktree-cleanup: remove $wt pull request $state $url"
      REPO_REMOVED=1
      return 0
    fi
  fi
  emit "worktree-cleanup: report $wt removal refused"
  return 0
}

consider_worktree() {
  local repo=$1 path=$2 branch=$3 detached=$4 locked=$5
  local phys pids kind rows row number state head url main_rc=0
  local open_count=0 terminal_count=0 chosen_state='' chosen_head='' chosen_url=''
  local current normalized
  if budget_reached; then
    note_budget
    return 0
  fi
  if [ ! -d "$path" ]; then
    emit "worktree-cleanup: report $path worktree directory is missing"
    return 0
  fi
  phys=$(cd "$path" && pwd -P) || {
    emit "worktree-cleanup: report $path worktree directory is missing"
    return 0
  }
  is_main_worktree "$phys" || main_rc=$?
  case "$main_rc" in
    0)
      emit "worktree-cleanup: skip $phys main checkout"
      return 0
      ;;
    1) ;;
    *)
      emit "worktree-cleanup: report $phys cannot read worktree status"
      return 0
      ;;
  esac
  if ! pids=$(fm_control_pids_with_cwd_under "$phys"); then
    emit "worktree-cleanup: report $phys cannot tell whether a process is using it"
    return 0
  fi
  if [ -n "$pids" ]; then
    emit "worktree-cleanup: skip $phys live process"
    return 0
  fi
  if [ "$locked" -eq 1 ]; then
    emit "worktree-cleanup: report $phys worktree is locked"
    return 0
  fi
  if [ "$detached" -eq 1 ] || [ -z "$branch" ]; then
    emit "worktree-cleanup: report $phys no branch"
    return 0
  fi
  kind=$(dirt_kind "$phys") || {
    emit "worktree-cleanup: report $phys cannot read worktree status"
    return 0
  }
  case "$kind" in
    tracked)
      emit "worktree-cleanup: report $phys uncommitted tracked changes"
      return 0
      ;;
    untracked)
      emit "worktree-cleanup: report $phys untracked files"
      return 0
      ;;
    clean) ;;
    *)
      emit "worktree-cleanup: report $phys cannot read worktree status"
      return 0
      ;;
  esac
  if ! rows=$(pr_rows "$phys" "$branch"); then
    emit "worktree-cleanup: report $phys pull request lookup failed"
    return 0
  fi
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS=$'\t' read -r number state head url <<EOF
$row
EOF
    if ! valid_pr_row "$number" "$state" "$head" "$url"; then
      emit "worktree-cleanup: report $phys pull request lookup failed"
      return 0
    fi
    normalized=$(canonical_state "$state") || {
      emit "worktree-cleanup: report $phys pull request lookup failed"
      return 0
    }
    case "$normalized" in
      OPEN) open_count=$((open_count + 1)) ;;
      MERGED|CLOSED)
        terminal_count=$((terminal_count + 1))
        chosen_state=$normalized
        chosen_head=$(printf '%s' "$head" | tr '[:upper:]' '[:lower:]')
        chosen_url=$url
        ;;
    esac
  done <<EOF
$rows
EOF
  if [ "$open_count" -gt 0 ]; then
    emit "worktree-cleanup: skip $phys pull request is open"
    return 0
  fi
  if [ "$terminal_count" -eq 0 ]; then
    emit "worktree-cleanup: skip $phys no pull request"
    return 0
  fi
  if [ "$terminal_count" -ne 1 ]; then
    emit "worktree-cleanup: report $phys more than one pull request"
    return 0
  fi
  if ! git -C "$phys" cat-file -e "${chosen_head}^{commit}" >/dev/null 2>&1; then
    emit "worktree-cleanup: report $phys pull request head is not in this repository"
    return 0
  fi
  current=$(git -C "$phys" rev-parse --verify HEAD) || {
    emit "worktree-cleanup: report $phys cannot read worktree status"
    return 0
  }
  if ! git -C "$phys" merge-base --is-ancestor "$current" "$chosen_head" >/dev/null 2>&1; then
    emit "worktree-cleanup: report $phys commits not on PR head"
    return 0
  fi
  remove_worktree "$repo" "$phys" "$chosen_state" "$chosen_url"
}

scan_repo() {
  local repo=$1 line rec_path='' rec_branch='' rec_detached=0 rec_locked=0
  REPO_REMOVED=0
  flush_record() {
    [ -n "$rec_path" ] || return 0
    consider_worktree "$repo" "$rec_path" "$rec_branch" "$rec_detached" "$rec_locked"
    rec_path=
    rec_branch=
    rec_detached=0
    rec_locked=0
  }
  while IFS= read -r line; do
    case "$line" in
      '') flush_record ;;
      worktree\ *)
        flush_record
        rec_path=${line#worktree }
        ;;
      'branch '*)
        rec_branch=${line#branch }
        rec_branch=${rec_branch#refs/heads/}
        ;;
      detached) rec_detached=1 ;;
      locked*) rec_locked=1 ;;
    esac
  done <<PORCELAIN
$(git -C "$repo" -c core.quotePath=false worktree list --porcelain 2>/dev/null || true)
PORCELAIN
  flush_record
  if [ "$DRY" -eq 0 ] && [ "$REPO_REMOVED" -eq 1 ]; then
    git -C "$repo" worktree prune
  fi
}

run_target() {
  local raw=$1 resolved
  resolved=$(resolve_project_arg "$raw") || {
    echo "worktree-cleanup: project not found: $raw" >&2
    exit 1
  }
  resolved=$(clone_root_path "$resolved") || {
    echo "worktree-cleanup: not a clone root: $raw" >&2
    exit 1
  }
  scan_repo "$resolved"
}

if [ -n "$TARGET" ]; then
  run_target "$TARGET"
  exit 0
fi

if [ -d "$PROJECTS" ] && [ ! -L "$PROJECTS" ]; then
  for project_dir in "$PROJECTS"/*; do
    [ -d "$project_dir" ] || continue
    if budget_reached; then
      note_budget
      break
    fi
    if project_root=$(clone_root_path "$project_dir"); then
      scan_repo "$project_root"
    fi
  done
fi
