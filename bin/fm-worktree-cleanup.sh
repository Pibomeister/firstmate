#!/usr/bin/env bash
# Remove linked git worktrees whose pull request is merged or closed.
#
# One decision line per linked worktree, and one line for each main checkout
# the scan sees. A main checkout is never removed. A worktree that a task record
# (worktree= or home= in any local home's state/*.meta) or a Treehouse pool owns,
# or that has a live Orca terminal, is reported and left in place. So is a
# worktree whose path contains another registered worktree, because removing it
# would destroy that worktree before its own checks run. When task records or an
# installed Orca cannot be read, the worktree is reported and left in place. A
# worktree with a live process whose working directory is inside it is skipped.
# When that scan cannot be completed, the worktree is reported and left in place.
# Uncommitted tracked changes and non-ignored untracked files are reported
# and left in place. Ignored files, including private .env, .work, and .omc
# files, do not block removal. Decision lines name the worktree and the
# reason. They never include file contents.
# Only pull requests whose head repository owner is the base repository owner
# count. With none open and at least one merged or closed, the highest-numbered
# of those decides. A worktree whose HEAD is not an ancestor of that pull
# request's head commit is reported and left in place. A head commit that is
# missing locally is fetched from origin's refs/pull/<n>/head, and a worktree is
# reported and left in place when that fetch does not produce it.
# Removal is `git worktree remove`, or `orca worktree rm` for a worktree Orca
# lists so that its list stays correct, never with --force, followed by
# `git worktree prune`. A refusal is reported. This script deletes no branch.
# `orca worktree rm` can delete a local branch that Orca proves is merged.
# --dry-run prints the same decisions and does not remove, prune, or move the
# cursor. It can still fetch a missing pull request head.
#
# `scan` is the watcher entry. It appends the same decision lines to
# state/worktree-cleanup.log and prints nothing, so a pass does not wake
# supervision. A direct run prints each decision and appends it there when
# the state directory exists. The log keeps its newest 2000 lines once it
# passes 1 MiB.
# Set FM_WORKTREE_CLEANUP=0 to make `scan` exit without looking. A direct run
# still performs the requested pass. A pass stops starting worktrees after 20
# seconds. A pass with no project argument walks all worktrees in path order and
# records each path in state/worktree-cleanup.cursor before it starts that
# worktree. The next such pass resumes after that path and wraps around.
#
# With no project argument the pass covers this home's project clones
# ($FM_HOME/projects, or $FM_PROJECTS_OVERRIDE). A directory that is not the
# root of its own work tree is skipped. An explicit project argument is a clone
# path. Linked worktrees of that clone are included wherever they live.
#
# Usage:
#   fm-worktree-cleanup.sh [--dry-run] [scan] [<clone-path>]
#   fm-worktree-cleanup.sh --help
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

DRY=0
SCAN=0
TARGET=
BUDGET=20
START=$(date +%s)
BUDGET_LOGGED=0
LOG_FILE=
CURSOR_FILE=
SCRATCH=

usage() {
  cat <<'EOF'
usage: fm-worktree-cleanup.sh [--dry-run] [scan] [<clone-path>]
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
if [ -n "$LOG_FILE" ] && [ -z "$TARGET" ]; then
  CURSOR_FILE=$STATE/worktree-cleanup.cursor
fi
RECORDS=$SCRATCH/records
: > "$RECORDS"

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
  json=$(cd "$wt" && gh pr list --json number,state,headRefOid,url,headRepositoryOwner --head "$branch" --state all --limit 20 2>/dev/null) || return 1
  rows=$(printf '%s' "$json" | jq -r '
    if type != "array" then
      error("pull request list is not an array")
    else
      .[] | select(type == "object")
      | [
          (.number | tostring),
          (.state | tostring),
          (.headRefOid | tostring),
          (.url | tostring),
          (.headRepositoryOwner.login // "" | tostring)
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
    OPEN|MERGED|CLOSED) ;;
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

pr_owned_by_base_owner() {
  local url=$1 head_owner=$2 base_owner
  base_owner=${url#https://*/}
  base_owner=${base_owner%%/*}
  [ -n "$head_owner" ] || return 1
  [ "$(printf '%s' "$head_owner" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$base_owner" | tr '[:upper:]' '[:lower:]')" ]
}

ensure_pr_head() {
  local wt=$1 number=$2 head=$3
  git -C "$wt" cat-file -e "${head}^{commit}" >/dev/null 2>&1 && return 0
  git -C "$wt" fetch --quiet origin "refs/pull/$number/head" >/dev/null 2>&1 || return 1
  git -C "$wt" cat-file -e "${head}^{commit}" >/dev/null 2>&1
}

load_task_paths() {
  local out=$1 state_dir meta field value
  fm_local_firstmate_state_dirs "$STATE" || return 1
  : > "$out.new"
  for state_dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    for meta in "$state_dir"/*.meta; do
      [ -f "$meta" ] || continue
      for field in worktree home; do
        value=$(fm_meta_get "$meta" "$field")
        [ -z "$value" ] || printf '%s\n' "$value" >> "$out.new"
      done
    done
  done
  mv -f -- "$out.new" "$out"
}

orca_path_list() {
  local out=$1 kind=$2 rows=$3 field=$4 json
  if ! command -v orca >/dev/null 2>&1; then
    : > "$out"
    return 0
  fi
  command -v jq >/dev/null 2>&1 || return 1
  json=$(orca "$kind" list --limit 100000 --json 2>/dev/null) || return 1
  printf '%s' "$json" | jq -er --arg rows "$rows" --arg field "$field" '
    if .ok == true and .result.truncated == false then
      .result[$rows] | map(.[$field] // "") | join("\n")
    else
      error("orca list is incomplete")
    end' > "$out.new" 2>/dev/null || return 1
  mv -f -- "$out.new" "$out"
}

load_orca_worktrees() {
  orca_path_list "$1" worktree worktrees path
}

load_orca_terminals() {
  orca_path_list "$1" terminal terminals worktreePath
}

contains_registered_worktree() {
  local path=$1 phys=$2 other rest
  while IFS=$'\037' read -r other rest; do
    case "$other" in
      "$path"/*|"$phys"/*) return 0 ;;
    esac
  done < "$RECORDS"
  return 1
}

# 0 when the list names the worktree, 1 when it does not, 2 when the list cannot
# be read. Each list loads at most once in a pass.
owner_lists_path() {
  local list=$SCRATCH/$1 loader=$2 wt=$3 path
  if [ ! -e "$list" ] && [ ! -e "$list.failed" ]; then
    "$loader" "$list" || : > "$list.failed"
  fi
  [ -e "$list" ] || return 2
  while IFS= read -r path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    if [ "$path" -ef "$wt" ]; then
      return 0
    fi
  done < "$list"
  return 1
}

remove_with_owner() {
  local repo=$1 wt=$2 orca_listed=$3
  if [ "$orca_listed" -eq 1 ]; then
    orca worktree rm --worktree "path:$wt" --json >/dev/null 2>&1 || return 1
    [ ! -e "$wt" ]
  else
    git -C "$repo" worktree remove -- "$wt" >/dev/null 2>&1
  fi
}

remove_worktree() {
  local repo=$1 wt=$2 state=$3 url=$4 orca_listed=$5
  if [ "$DRY" -eq 1 ]; then
    emit "worktree-cleanup: dry-run $wt pull request $state $url"
    return 0
  fi
  if remove_with_owner "$repo" "$wt" "$orca_listed"; then
    emit "worktree-cleanup: remove $wt pull request $state $url"
    git -C "$repo" worktree prune
    return 0
  fi
  emit "worktree-cleanup: report $wt removal refused"
  return 0
}

consider_worktree() {
  local repo=$1 path=$2 branch=$3 detached=$4 locked=$5
  local phys pids kind rows row number state head url head_owner main_rc=0 owner_rc orca_listed=0
  local open_count=0 terminal_count=0 chosen_number=0 chosen_state='' chosen_head='' chosen_url=''
  local current
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
  if fm_treehouse_pool_slot "$repo" "$phys"; then
    emit "worktree-cleanup: report $phys Treehouse pool owns it"
    return 0
  fi
  owner_rc=0
  owner_lists_path task-paths load_task_paths "$phys" || owner_rc=$?
  case "$owner_rc" in
    0)
      emit "worktree-cleanup: report $phys task record owns it"
      return 0
      ;;
    1) ;;
    *)
      emit "worktree-cleanup: report $phys cannot read task records"
      return 0
      ;;
  esac
  if contains_registered_worktree "$path" "$phys"; then
    emit "worktree-cleanup: report $phys contains another worktree"
    return 0
  fi
  owner_rc=0
  owner_lists_path orca-terminals load_orca_terminals "$phys" || owner_rc=$?
  case "$owner_rc" in
    0)
      emit "worktree-cleanup: report $phys Orca terminal is live"
      return 0
      ;;
    1) ;;
    *)
      emit "worktree-cleanup: report $phys cannot read Orca"
      return 0
      ;;
  esac
  owner_rc=0
  owner_lists_path orca-worktrees load_orca_worktrees "$phys" || owner_rc=$?
  case "$owner_rc" in
    0) orca_listed=1 ;;
    1) ;;
    *)
      emit "worktree-cleanup: report $phys cannot read Orca"
      return 0
      ;;
  esac
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
    IFS=$'\t' read -r number state head url head_owner <<EOF
$row
EOF
    if ! valid_pr_row "$number" "$state" "$head" "$url"; then
      emit "worktree-cleanup: report $phys pull request lookup failed"
      return 0
    fi
    pr_owned_by_base_owner "$url" "$head_owner" || continue
    case "$state" in
      OPEN) open_count=$((open_count + 1)) ;;
      MERGED|CLOSED)
        terminal_count=$((terminal_count + 1))
        if [ "$number" -gt "$chosen_number" ]; then
          chosen_number=$number
          chosen_state=$state
          chosen_head=$(printf '%s' "$head" | tr '[:upper:]' '[:lower:]')
          chosen_url=$url
        fi
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
  if ! ensure_pr_head "$phys" "$chosen_number" "$chosen_head"; then
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
  if ! pids=$(fm_control_pids_with_cwd_under "$phys"); then
    emit "worktree-cleanup: report $phys cannot tell whether a process is using it"
    return 0
  fi
  if [ -n "$pids" ]; then
    emit "worktree-cleanup: skip $phys live process"
    return 0
  fi
  remove_worktree "$repo" "$phys" "$chosen_state" "$chosen_url" "$orca_listed"
}

collect_repo() {
  local repo=$1 line rec_path='' rec_branch='' rec_detached=0 rec_locked=0
  flush_record() {
    [ -n "$rec_path" ] || return 0
    printf '%s\037%s\037%s\037%s\037%s\n' \
      "$rec_path" "$repo" "$rec_branch" "$rec_detached" "$rec_locked" >> "$RECORDS"
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
}

write_cursor() {
  [ -n "$CURSOR_FILE" ] && [ "$DRY" -eq 0 ] || return 0
  { printf '%s\n' "$1" > "$CURSOR_FILE.new" && mv -f -- "$CURSOR_FILE.new" "$CURSOR_FILE"; } 2>/dev/null || :
}

run_records() {
  local cursor='' rotated=$SCRATCH/rotated path repo branch detached locked
  if [ -n "$CURSOR_FILE" ] && [ -f "$CURSOR_FILE" ]; then
    IFS= read -r cursor < "$CURSOR_FILE" || :
  fi
  LC_ALL=C sort "$RECORDS" | LC_ALL=C CURSOR_PATH=$cursor awk -F $'\037' '
    $1 > ENVIRON["CURSOR_PATH"] { print; next }
    { wrapped[++count] = $0 }
    END { for (i = 1; i <= count; i++) print wrapped[i] }' > "$rotated"
  while IFS=$'\037' read -r path repo branch detached locked <&3; do
    if budget_reached; then
      note_budget
      break
    fi
    write_cursor "$path"
    consider_worktree "$repo" "$path" "$branch" "$detached" "$locked"
  done 3< "$rotated"
}

run_target() {
  local raw=$1 resolved
  resolved=$(clone_root_path "$raw") || {
    echo "worktree-cleanup: not a clone root: $raw" >&2
    exit 1
  }
  collect_repo "$resolved"
}

if [ -n "$TARGET" ]; then
  run_target "$TARGET"
elif [ -d "$PROJECTS" ] && [ ! -L "$PROJECTS" ]; then
  for project_dir in "$PROJECTS"/*; do
    [ -d "$project_dir" ] || continue
    if project_root=$(clone_root_path "$project_dir"); then
      collect_repo "$project_root"
    fi
  done
fi
run_records
