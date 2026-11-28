#!/usr/bin/env bash
# fm-rsi-conflicts.sh - read-only conflict report for pull-request heads.
#
# Usage:
#   fm-rsi-conflicts.sh --repo <dir> --base <commit> <number>=<sha>...
#   fm-rsi-conflicts.sh --help
#
# For each head, a trial three-way combine with the base
# (git merge-tree --write-tree, Git 2.38 or newer) names the paths that
# conflict. The combine writes its objects into a scratch object directory
# whose alternate is the repository's object store, so the repository's refs,
# index, worktree and object store stay unchanged. This command never fetches,
# never contacts a forge, and never lands, rebases or comments on a pull
# request. The caller fetches every head first; docs/rsi/loop-2.md records the
# fetch the loop-2 readings used.
#
# --repo is any directory inside a git repository or worktree. --base is any
# commit-ish the repository resolves. Each <number>=<sha> pair names one
# pull-request number, a positive integer given at most once, and its head
# commit-ish.
#
# Prints, heads in the order given:
#   pr number=<n> state=clean|conflict paths=<k>
#   path number=<n> path=<p>         one per conflicting path, sorted
# then, over every conflicted head:
#   tally path=<p> blocked=<count>   ordered by count descending, then path
#   summary conflicted=<c> heads=<h>
# Paths are printed as git prints them, so an unusual path stays C-quoted.
#
# Exit 0 on a report. Exit 2, with nothing on stdout, on bad usage, a
# directory outside a git repository, an unresolvable base or head, a
# duplicate or malformed pair, or a trial combine that fails for any reason
# other than a conflict.
set -eu

usage() { sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"; }

die() {
  printf 'fm-rsi-conflicts: %s\n' "$*" >&2
  exit 2
}

REPO=
BASE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo) REPO=${2:-}; shift ;;
    --base) BASE=${2:-}; shift ;;
    -*) die "unknown argument: $1" ;;
    *) break ;;
  esac
  shift
done

[ -n "$REPO" ] && [ -n "$BASE" ] && [ "$#" -gt 0 ] ||
  die "usage: fm-rsi-conflicts.sh --repo <dir> --base <commit> <number>=<sha>..."
[ -d "$REPO" ] || die "no such directory: $REPO"
OBJECTS=$(git -C "$REPO" rev-parse --path-format=absolute --git-path objects 2>/dev/null) ||
  die "not a git repository: $REPO"
BASE_SHA=$(git -C "$REPO" rev-parse --verify --quiet "$BASE^{commit}") ||
  die "base does not resolve to a commit: $BASE"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-rsi-conflicts.XXXXXX") || die "cannot create a scratch directory"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir "$SCRATCH/objects"
: > "$SCRATCH/report"
: > "$SCRATCH/paths"

seen=' '
heads=0
conflicted=0
for pair in "$@"; do
  case "$pair" in
    *=*) number=${pair%%=*} head=${pair#*=} ;;
    *) die "not a <number>=<sha> pair: $pair" ;;
  esac
  case "$number" in
    ''|0*|*[!0-9]*) die "not a positive pull-request number: $number" ;;
  esac
  case "$seen" in *" $number "*) die "duplicate pull-request number: $number" ;; esac
  seen="$seen$number "
  head_sha=$(git -C "$REPO" rev-parse --verify --quiet "$head^{commit}") ||
    die "head of $number does not resolve to a commit: $head"

  rc=0
  GIT_OBJECT_DIRECTORY="$SCRATCH/objects" GIT_ALTERNATE_OBJECT_DIRECTORIES="$OBJECTS" \
    git -C "$REPO" merge-tree --write-tree --name-only --no-messages "$BASE_SHA" "$head_sha" \
    > "$SCRATCH/combine" 2>/dev/null || rc=$?
  heads=$((heads + 1))
  case "$rc" in
    0) printf 'pr number=%s state=clean paths=0\n' "$number" >> "$SCRATCH/report" ;;
    1)
      conflicted=$((conflicted + 1))
      tail -n +2 "$SCRATCH/combine" | LC_ALL=C sort -u > "$SCRATCH/head-paths"
      printf 'pr number=%s state=conflict paths=%s\n' "$number" "$(wc -l < "$SCRATCH/head-paths" | tr -d ' ')" >> "$SCRATCH/report"
      while IFS= read -r path; do
        printf 'path number=%s path=%s\n' "$number" "$path" >> "$SCRATCH/report"
      done < "$SCRATCH/head-paths"
      cat "$SCRATCH/head-paths" >> "$SCRATCH/paths"
      ;;
    *) die "trial combine of $number failed (git exit $rc)" ;;
  esac
done

LC_ALL=C sort "$SCRATCH/paths" | uniq -c |
  LC_ALL=C awk '{ count = $1; sub(/^ *[0-9]+ /, ""); printf "%s\t%s\n", count, $0 }' |
  LC_ALL=C sort -t "$(printf '\t')" -k1,1nr -k2 |
  while IFS="$(printf '\t')" read -r count path; do
    printf 'tally path=%s blocked=%s\n' "$path" "$count"
  done >> "$SCRATCH/report"
printf 'summary conflicted=%s heads=%s\n' "$conflicted" "$heads" >> "$SCRATCH/report"
cat "$SCRATCH/report"
