#!/usr/bin/env bash
# fm-lane-register.sh - register one lane that an external launcher started
# outside Firstmate, so the existing reap and cleanup passes can see it.
#
# Usage:
#   FM_HOME=<home> fm-lane-register.sh <id> --repo <clone> [--terminal <handle>] [--worktree <path>]
#   FM_HOME=<home> fm-lane-register.sh <id> --worktree <path>
#   fm-lane-register.sh --help
#
# The first form registers lane <id>; the second amends a lane already
# registered, for a launcher whose lane creates its worktree after launch.
# Running either again for the same <id> keeps every field it does not name.
#   <id>               letters, digits, dot, underscore, and dash, starting
#                      with a letter or digit, at most 64 characters
#   --repo <clone>     the main checkout the lane's worktree belongs to
#   --terminal <h>     the lane's Orca terminal handle; defaults to
#                      $ORCA_TERMINAL_HANDLE when the record has none
#   --worktree <path>  the lane's linked worktree of <clone>; it must exist
#
# FM_HOME must name the firstmate home explicitly, so a launcher never
# registers against whichever home this checkout happens to be. The record is
# $FM_HOME/state/external-lanes/<id>.lane, written atomically as key=value
# lines: repo=, terminal=, worktree=, registered=<epoch>, updated=<epoch>.
#
# What registration changes:
#   bin/fm-terminal-reap.sh  treats a registered handle as a lane this home
#                            may close once its pane has exited or holds only
#                            an idle shell, with every existing re-proof; a
#                            task record still wins over a registration
#   bin/fm-worktree-cleanup.sh  adds the registered worktree to its pass with
#                            every existing check (landed-work proof on a
#                            merged or closed pull request, dirty and
#                            untracked files kept and reported, no --force),
#                            keeps it while the lane's terminal is still
#                            listed, and deletes the record after it removes
#                            the worktree
# Registration never removes, closes, or stops anything itself.
#
# Exit status: 0 when the record was written; 1 when a check refused it or the
# write failed, with the reason on stderr and no record changed; 2 on a usage
# error.
set -u

usage() { sed -n '2,/^# error\.$/p' "$0" | sed 's/^# \{0,1\}//'; }

die() { echo "fm-lane-register: $*" >&2; exit 1; }

ID=
REPO=
TERMINAL=
WORKTREE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo|--terminal|--worktree)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "fm-lane-register: $1 needs a value" >&2; exit 2; }
      case "$1" in
        --repo) REPO=$2 ;;
        --terminal) TERMINAL=$2 ;;
        --worktree) WORKTREE=$2 ;;
      esac
      shift 2
      ;;
    -*) echo "fm-lane-register: unknown option $1" >&2; exit 2 ;;
    *)
      [ -z "$ID" ] || { echo "fm-lane-register: only one lane id is accepted" >&2; exit 2; }
      ID=$1
      shift
      ;;
  esac
done
[ -n "$ID" ] || { echo "fm-lane-register: a lane id is required" >&2; usage >&2; exit 2; }
case "$ID" in
  [A-Za-z0-9]*) ;;
  *) echo "fm-lane-register: invalid lane id: $ID" >&2; exit 2 ;;
esac
case "$ID" in
  *[!A-Za-z0-9._-]*) echo "fm-lane-register: invalid lane id: $ID" >&2; exit 2 ;;
esac
[ "${#ID}" -le 64 ] || { echo "fm-lane-register: lane id is longer than 64 characters" >&2; exit 2; }

[ -n "${FM_HOME:-}" ] || die "FM_HOME must name the firstmate home"
[ -d "$FM_HOME/state" ] && [ ! -L "$FM_HOME/state" ] || die "not a firstmate home: $FM_HOME"
LANES="$FM_HOME/state/external-lanes"
RECORD="$LANES/$ID.lane"

# A value holds no newline, so a record line is always one key=value pair.
one_line() {
  case "$2" in
    *$'\n'*|*$'\r'*) die "$1 must be a single line" ;;
  esac
}

field() {  # <key>: the recorded value, or nothing
  local line value=''
  [ -f "$RECORD" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$1="*) value=${line#*=} ;; esac
  done < "$RECORD"
  printf '%s' "$value"
}

common_dir() {  # <dir>: the repository's absolute common git directory
  local raw
  raw=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || raw=$(git -C "$1" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$raw" in
    /*) (cd "$raw" && pwd -P) ;;
    *) (cd "$1" && cd "$raw" && pwd -P) ;;
  esac
}

if [ -e "$RECORD" ] && { [ ! -f "$RECORD" ] || [ -L "$RECORD" ] || [ ! -r "$RECORD" ]; }; then
  die "the existing record cannot be read: $RECORD"
fi

[ -n "$REPO" ] || REPO=$(field repo)
[ -n "$REPO" ] || die "--repo is required for a lane that is not registered yet"
[ -n "$TERMINAL" ] || TERMINAL=$(field terminal)
[ -n "$TERMINAL" ] || TERMINAL=${ORCA_TERMINAL_HANDLE:-}
[ -n "$WORKTREE" ] || WORKTREE=$(field worktree)
one_line repo "$REPO"
one_line terminal "$TERMINAL"
one_line worktree "$WORKTREE"
case "$TERMINAL" in
  *[[:space:]]*) die "invalid terminal handle: $TERMINAL" ;;
esac

case "$REPO" in /*) ;; *) die "--repo must be an absolute path: $REPO" ;; esac
[ -d "$REPO" ] || die "--repo is not a directory: $REPO"
REPO=$(cd "$REPO" && pwd -P) || die "--repo cannot be resolved"
top=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) || die "--repo is not a git checkout: $REPO"
[ "$top" -ef "$REPO" ] || die "--repo is not the top of its checkout: $REPO"
repo_common=$(common_dir "$REPO") || die "--repo git directory cannot be read: $REPO"
repo_git=$(cd "$(git -C "$REPO" rev-parse --absolute-git-dir 2>/dev/null)" 2>/dev/null && pwd -P) \
  || die "--repo git directory cannot be read: $REPO"
[ "$repo_git" = "$repo_common" ] || die "--repo must be the main checkout, not a linked worktree: $REPO"

if [ -n "$WORKTREE" ]; then
  case "$WORKTREE" in /*) ;; *) die "--worktree must be an absolute path: $WORKTREE" ;; esac
  [ -d "$WORKTREE" ] || die "--worktree is not a directory: $WORKTREE"
  WORKTREE=$(cd "$WORKTREE" && pwd -P) || die "--worktree cannot be resolved"
  [ "$WORKTREE" != "$REPO" ] || die "--worktree is the main checkout itself: $WORKTREE"
  top=$(git -C "$WORKTREE" rev-parse --show-toplevel 2>/dev/null) || die "--worktree is not a git worktree: $WORKTREE"
  [ "$top" -ef "$WORKTREE" ] || die "--worktree is not the top of its worktree: $WORKTREE"
  wt_common=$(common_dir "$WORKTREE") || die "--worktree git directory cannot be read: $WORKTREE"
  [ "$wt_common" = "$repo_common" ] || die "--worktree is not a worktree of $REPO: $WORKTREE"
fi

now=$(date +%s)
registered=$(field registered)
[ -n "$registered" ] || registered=$now
mkdir -p "$LANES" || die "cannot create $LANES"
tmp=$(mktemp "$LANES/.$ID.XXXXXX") || die "cannot write in $LANES"
if ! printf 'repo=%s\nterminal=%s\nworktree=%s\nregistered=%s\nupdated=%s\n' \
  "$REPO" "$TERMINAL" "$WORKTREE" "$registered" "$now" > "$tmp" \
  || ! mv -f -- "$tmp" "$RECORD"; then
  rm -f -- "$tmp"
  die "cannot write $RECORD"
fi
printf 'registered %s repo=%s terminal=%s worktree=%s\n' "$ID" "$REPO" "${TERMINAL:--}" "${WORKTREE:--}"
