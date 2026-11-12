#!/usr/bin/env bash
# Remove linked git worktrees whose pull request is merged, or closed while
# the worktree HEAD is already on the default branch. A closed pull request
# whose worktree HEAD is not on the default branch proves nothing about
# landing and never permits removal or cache pruning.
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
# Uncommitted tracked changes, and non-ignored untracked files other than the
# caches and browser profiles named below, are reported and left in place.
# Ignored files, including private .env, .work, and .omc
# files, do not block removal. Decision lines name the worktree and the
# reason. They never include file contents.
# Only pull requests whose head repository owner is the base repository owner
# count. With none open and at least one merged or closed, the highest-numbered
# of those decides. A worktree whose HEAD is not an ancestor of that pull
# request's head commit is reported and left in place. A head commit that is
# missing locally is fetched from origin's refs/pull/<n>/head, and a worktree is
# reported and left in place when that fetch does not produce it.
# A worktree whose only untracked files are caches or browser profiles (a
# top-level `.cache`, `.playwright`, `ms-playwright`, `.ms-playwright`, or
# `.puppeteer` directory, a `playwright_chromiumdev_profile*` or
# `puppeteer_dev_chrome_profile*` directory, or `node_modules/.cache`) does not
# stay behind for them: once every landed proof below has passed, those
# directories are pruned and the tree must then read clean before removal.
# Any other untracked file, and any tracked change, still leaves the worktree
# in place. A dry run reports the prune instead of deleting.
# Each pass first reads bin/fm-disk-alarm.sh and logs its line when the level
# is warn, pause, stop, or unreadable. That reading never blocks the pass,
# because pruning is what frees the space.
# Removal is `git worktree remove`, or `orca worktree rm` for a worktree Orca
# lists so that its list stays correct, never with --force, followed by
# `git worktree prune`. A refusal is reported. Orca removes the directory after
# it answers, so the pass waits up to 60 seconds for the directory to go, and
# reports the worktree when it stays. This script deletes no branch.
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
# A pass with no project argument also covers each external lane registered in
# this home's state/external-lanes/ (bin/fm-lane-register.sh owns the record):
# the registered worktree of the registered repository gets every check above,
# and is also reported and left in place while Orca still lists the lane's
# registered terminal. Other worktrees of that repository are read only for the
# nesting check. After it removes a lane's worktree, the pass deletes the
# lane's record; it also deletes a record whose worktree is gone, or that names
# no worktree, once Orca no longer lists its terminal.
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
ORCA_REMOVE_WAIT=60
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
NESTED=$SCRATCH/nested
LANE_DIR=$STATE/external-lanes
: > "$RECORDS"
: > "$NESTED"

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

# cache_root_of <untracked-path>: print the cache or browser-profile root to
# prune for a known cache path, or nothing for any other path.
cache_root_of() {
  local p=$1 top
  top=${p%%/*}
  case "$top" in
    .cache|.playwright|ms-playwright|.ms-playwright|.puppeteer|playwright_chromiumdev_profile*|puppeteer_dev_chrome_profile*)
      printf '%s' "$top" ;;
    node_modules)
      case "$p" in node_modules/.cache|node_modules/.cache/*) printf 'node_modules/.cache' ;; esac ;;
  esac
}

# prune_landed_caches <worktree>: 0 when the tree holds no untracked files
# beyond known caches and profiles (pruning them, unless this is a dry run),
# 1 when another untracked file is present, 2 when the tree cannot be read.
# Callers must already have proved the work has landed.
prune_landed_caches() {
  local wt=$1 status_file=$SCRATCH/prune-status line path root
  local roots=() seen=' '
  git -C "$wt" status --porcelain=v1 --untracked-files=all -z > "$status_file" || return 2
  while IFS= read -r -d '' line; do
    case "$line" in
      '') continue ;;
      \?\?*) ;;
      *) return 1 ;;
    esac
    path=${line#\?\? }
    root=$(cache_root_of "$path")
    [ -n "$root" ] || return 1
    case "$seen" in *" $root "*) ;; *) seen="$seen$root "; roots+=("$root") ;; esac
  done < "$status_file"
  [ "${#roots[@]}" -gt 0 ] || return 0
  # A cache root that also holds tracked files is not pruned: deleting the
  # root would destroy tracked work the status scan never listed.
  for root in "${roots[@]}"; do
    [ -z "$(git -C "$wt" ls-files -- "$root")" ] || return 1
  done
  if [ "$DRY" -eq 1 ]; then
    emit "worktree-cleanup: dry-run prune caches $wt: ${roots[*]}"
    return 0
  fi
  for root in "${roots[@]}"; do
    rm -rf -- "${wt:?}/${root:?}" || return 2
  done
  emit "worktree-cleanup: prune caches $wt: ${roots[*]}"
  [ "$(dirt_kind "$wt")" = clean ] || return 1
  return 0
}

# default_branch_ref <worktree>: print the ref that names the default
# branch (origin/HEAD, else origin/main, else a local main or master), or
# fail when none can be named.
default_branch_ref() {
  local wt=$1 ref
  ref=$(git -C "$wt" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) && { printf '%s' "$ref"; return 0; }
  for ref in origin/main origin/master main master; do
    git -C "$wt" rev-parse --verify --quiet "$ref" >/dev/null 2>&1 && { printf '%s' "$ref"; return 0; }
  done
  return 1
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

load_orca_handles() {
  orca_path_list "$1" terminal terminals handle
}

# 0 when Orca lists the terminal handle, 1 when it does not, 2 when the list
# cannot be read. The list loads at most once in a pass.
orca_lists_handle() {
  local list=$SCRATCH/orca-handles handle=$1 line
  if [ ! -e "$list" ] && [ ! -e "$list.failed" ]; then
    load_orca_handles "$list" || : > "$list.failed"
  fi
  [ -e "$list" ] || return 2
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" = "$handle" ] && return 0
  done < "$list"
  return 1
}

lane_terminal() {  # <lane-id>: the registered lane's terminal handle
  fm_meta_get "$LANE_DIR/$1.lane" terminal
}

# forget_lane <id> <reason>: drop a registered lane's record once nothing of
# the lane is left for this pass to judge.
forget_lane() {
  local id=$1 reason=$2
  if [ "$DRY" -eq 1 ]; then
    emit "worktree-cleanup: dry-run forget lane $id $reason"
    return 0
  fi
  if rm -f -- "$LANE_DIR/$id.lane"; then
    emit "worktree-cleanup: forget lane $id $reason"
  else
    emit "worktree-cleanup: report lane $id record could not be removed"
  fi
}

contains_registered_worktree() {
  local path=$1 phys=$2 other rest
  while IFS=$'\037' read -r other rest; do
    case "$other" in
      "$path"/*|"$phys"/*) return 0 ;;
    esac
  done < <(cat "$RECORDS" "$NESTED")
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

# 0 when the directory is gone, 1 when removal is refused, 2 when Orca accepted
# the removal and the directory is still there at the end of the wait. Orca
# answers success at once and removes the directory afterward.
remove_with_owner() {
  local repo=$1 wt=$2 orca_listed=$3 waited=0
  if [ "$orca_listed" -eq 1 ]; then
    orca worktree rm --worktree "path:$wt" --json >/dev/null 2>&1 || return 1
    while [ -e "$wt" ]; do
      [ "$waited" -lt "$ORCA_REMOVE_WAIT" ] || return 2
      sleep 1
      waited=$((waited + 1))
    done
  else
    git -C "$repo" worktree remove -- "$wt" >/dev/null 2>&1
  fi
}

remove_worktree() {
  local repo=$1 wt=$2 state=$3 url=$4 orca_listed=$5 lane=${6:-} rc=0
  if [ "$DRY" -eq 1 ]; then
    emit "worktree-cleanup: dry-run $wt pull request $state $url"
    return 0
  fi
  remove_with_owner "$repo" "$wt" "$orca_listed" || rc=$?
  case "$rc" in
    0)
      emit "worktree-cleanup: remove $wt pull request $state $url"
      git -C "$repo" worktree prune
      [ -z "$lane" ] || forget_lane "$lane" "worktree removed"
      ;;
    2) emit "worktree-cleanup: report $wt Orca removal did not finish" ;;
    *) emit "worktree-cleanup: report $wt removal refused" ;;
  esac
  return 0
}

consider_worktree() {
  local repo=$1 path=$2 branch=$3 detached=$4 locked=$5 lane=${6:-}
  local phys pids kind rows row number state head url head_owner main_rc=0 owner_rc orca_listed=0
  local open_count=0 terminal_count=0 chosen_number=0 chosen_state='' chosen_head='' chosen_url=''
  local current lane_handle
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
  if [ -n "$lane" ]; then
    lane_handle=$(lane_terminal "$lane")
    if [ -n "$lane_handle" ]; then
      owner_rc=0
      orca_lists_handle "$lane_handle" || owner_rc=$?
      case "$owner_rc" in
        0)
          emit "worktree-cleanup: report $phys registered lane $lane terminal is open"
          return 0
          ;;
        1) ;;
        *)
          emit "worktree-cleanup: report $phys cannot read Orca"
          return 0
          ;;
      esac
    fi
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
    untracked) ;; # caches and profiles are judged after the landed proofs
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
  # A closed pull request proves nothing about landing by itself. Only a
  # merged pull request, or a closed one whose worktree HEAD is already an
  # ancestor of the default branch, may proceed.
  if [ "$chosen_state" = CLOSED ]; then
    default_ref=$(default_branch_ref "$phys") || default_ref=''
    if [ -z "$default_ref" ] || ! git -C "$phys" merge-base --is-ancestor "$current" "$default_ref" >/dev/null 2>&1; then
      emit "worktree-cleanup: report $phys closed pull request did not land on the default branch"
      return 0
    fi
  fi
  if ! pids=$(fm_control_pids_with_cwd_under "$phys"); then
    emit "worktree-cleanup: report $phys cannot tell whether a process is using it"
    return 0
  fi
  if [ -n "$pids" ]; then
    emit "worktree-cleanup: skip $phys live process"
    return 0
  fi
  prune_landed_caches "$phys" || {
    case $? in
      1) emit "worktree-cleanup: report $phys untracked files" ;;
      *) emit "worktree-cleanup: report $phys cannot read worktree status" ;;
    esac
    return 0
  }
  remove_worktree "$repo" "$phys" "$chosen_state" "$chosen_url" "$orca_listed" "$lane"
}

collect_repo() {
  local repo=$1 out=${2:-$RECORDS} line rec_path='' rec_branch='' rec_detached=0 rec_locked=0
  flush_record() {
    [ -n "$rec_path" ] || return 0
    printf '%s\037%s\037%s\037%s\037%s\037\n' \
      "$rec_path" "$repo" "$rec_branch" "$rec_detached" "$rec_locked" >> "$out"
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
  while IFS=$'\037' read -r path repo branch detached locked lane <&3; do
    if budget_reached; then
      note_budget
      break
    fi
    write_cursor "$path"
    consider_worktree "$repo" "$path" "$branch" "$detached" "$locked" "$lane"
  done 3< "$rotated"
}

# same_path <a> <b>: 0 when both name one directory, or the same missing path.
same_path() {
  [ "$1" = "$2" ] || [ "$1" -ef "$2" ]
}

# collect_lanes: add each registered external lane's worktree to the pass,
# tagged with its lane id. The lane's whole repository is read so the nesting
# check still sees its other worktrees, but only the registered one is judged.
# A lane with no worktree left to judge and no listed terminal is forgotten.
collect_lanes() {
  local rec id repo wt root all row path rest handle rc found
  [ -d "$LANE_DIR" ] && [ ! -L "$LANE_DIR" ] || return 0
  if [ ! -r "$LANE_DIR" ] || [ ! -x "$LANE_DIR" ]; then
    emit "worktree-cleanup: report $LANE_DIR registered lanes cannot be read"
    return 0
  fi
  for rec in "$LANE_DIR"/*.lane; do
    [ -f "$rec" ] || continue
    id=${rec##*/}
    id=${id%.lane}
    if [ ! -r "$rec" ]; then
      emit "worktree-cleanup: report lane $id record cannot be read"
      continue
    fi
    repo=$(fm_meta_get "$rec" repo)
    wt=$(fm_meta_get "$rec" worktree)
    found=0
    if [ -n "$wt" ]; then
      if ! root=$(clone_root_path "$repo"); then
        emit "worktree-cleanup: report $wt registered lane $id repository is unavailable"
        continue
      fi
      all=$SCRATCH/lane-all
      : > "$all"
      collect_repo "$root" "$all"
      while IFS= read -r row; do
        IFS=$'\037' read -r path rest <<EOF
$row
EOF
        if same_path "$path" "$wt"; then
          found=1
          awk -F $'\037' -v p="$path" '$1 != p' "$RECORDS" > "$RECORDS.new" && mv -f -- "$RECORDS.new" "$RECORDS"
          printf '%s%s\n' "${row%$'\037'}" $'\037'"$id" >> "$RECORDS"
        else
          printf '%s\n' "$row" >> "$NESTED"
        fi
      done < "$all"
      if [ "$found" -eq 0 ] && [ -e "$wt" ]; then
        emit "worktree-cleanup: report $wt registered lane $id is not a worktree of its repository"
        continue
      fi
    fi
    [ "$found" -eq 0 ] || continue
    handle=$(fm_meta_get "$rec" terminal)
    if [ -n "$handle" ]; then
      rc=0
      orca_lists_handle "$handle" || rc=$?
      [ "$rc" -eq 1 ] || continue
    fi
    if [ -n "$wt" ]; then
      forget_lane "$id" "worktree is gone"
    else
      forget_lane "$id" "no worktree was registered"
    fi
  done
}

run_target() {
  local raw=$1 resolved
  resolved=$(clone_root_path "$raw") || {
    echo "worktree-cleanup: not a clone root: $raw" >&2
    exit 1
  }
  collect_repo "$resolved"
}

if [ -x "$SCRIPT_DIR/fm-disk-alarm.sh" ]; then
  alarm_line=$("$SCRIPT_DIR/fm-disk-alarm.sh" 2>/dev/null || true)
  case "$alarm_line" in
    *'level=warn'*|*'level=pause'*|*'level=stop'*|*'level=unreadable'*)
      emit "worktree-cleanup: $alarm_line" ;;
  esac
fi

if [ -n "$TARGET" ]; then
  run_target "$TARGET"
else
  if [ -d "$PROJECTS" ] && [ ! -L "$PROJECTS" ]; then
    for project_dir in "$PROJECTS"/*; do
      [ -d "$project_dir" ] || continue
      if project_root=$(clone_root_path "$project_dir"); then
        collect_repo "$project_root"
      fi
    done
  fi
  collect_lanes
fi
run_records
