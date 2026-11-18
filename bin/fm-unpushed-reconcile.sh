#!/usr/bin/env bash
# Flag local task branches with commits absent from publishing remote refs.
#
# Usage: fm-unpushed-reconcile.sh scan
# Read-only: never fetches, pushes, steers a worker, answers a gate, changes a
# ledger row, or resolves a blocker. The locked session start's deferred stage
# captures these findings in its report and delivers its ordinary durable wake.
# Re-running converges on the same findings until the underlying work changes.
#
# Scope: this home's project clones and projects named by its ordinary task
# metadata, accepting only checkout roots and deduplicating by Git common
# directory. Never traverse secondmate
# homes or backend endpoint inventories. Branches match the registered prefix
# (default fm/) or an exact ordinary task metadata branch. Local-only projects
# and tasks are excluded. Each finding names the branch/head, count of commits
# unreachable from publishing remote-tracking refs, matching task, backlog row,
# open PR lookup, and still-open status decisions. No-mistakes proxy refs do
# not prove publication. Remote refs are local evidence, not a live remote
# inventory; startup's fleet refresh owns fetching them. A head whose content
# already sits in origin's copy of its base branch (the task's recorded
# base_branch, else the default) has landed, as in fm-teardown.sh's
# content-in-default proof, which covers squash and rebase merges after the
# remote task branch is deleted. When that content proof conflicts or is
# unavailable, a merged GitHub PR whose head is exactly the local head also
# proves landing, as in fm-teardown.sh's merged-PR proof. Newer local commits,
# an older merged head under the same branch name, or a failed proof read keep
# the branch flagged, and the finding names the merged-proof result.
#
# Open PR lookups use gh-axi and merged-head lookups use gh's authenticated
# API for GitHub publication targets. Other forges, missing
# tools, malformed responses, and failed reads are explicit unknowns. A PR
# never hides local follow-up commits. Findings request supervisor action,
# including escalation of a blocked pipeline start; retry authority and all
# gate decisions stay with the supervisor. Nothing automatically retries a
# gate-context failure or administers the shared daemon.
#
# FM_HOME selects the home. FM_DATA_OVERRIDE, FM_STATE_OVERRIDE and
# FM_PROJECTS_OVERRIDE select its directories. FM_UNPUSHED_TIMEOUT_SECS bounds
# the entire scan (default 20, maximum 120). A timeout retains partial output,
# names every discovered branch not yet resolved, and prints an actionable
# incomplete-scan diagnostic. Exit 0 includes
# findings/unknowns; usage or an invalid bound exits 2.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
export FM_HOME
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-role-lib.sh
. "$SCRIPT_DIR/fm-role-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"

field() { printf '%s' "$1" | tr '\t\r\n' '   '; }

github_target() { # <project> <forge>; sets HOST and REPO or prints the unknown reason
  local target
  [ "$2" = none ] || { printf 'unknown (forge=%s)' "$2"; return 1; }
  target=$(fm_role_publication_target "$1")
  HOST=${target%%/*}
  REPO=${target#*/}
  case "$HOST" in
    github.com|*.ghe.com) ;;
    *) printf 'unknown (no GitHub target)'; return 1 ;;
  esac
}

pr_evidence() { # <project> <branch> <forge>
  local out count urls
  github_target "$1" "$3" || return 0
  command -v gh-axi >/dev/null 2>&1 || { printf 'unknown (gh-axi absent)'; return; }
  out=$(gh-axi pr list --hostname "$HOST" -R "$REPO" --state open \
    --head "$2" --limit 100 --fields url 2>/dev/null) || {
    printf 'unknown (forge read failed)'; return
  }
  count=$(printf '%s\n' "$out" | sed -n 's/^count: \([0-9][0-9]*\).*$/\1/p')
  case "$count" in
    0) printf none ;;
    ''|*[!0-9]*) printf 'unknown (invalid forge response)' ;;
    *)
      urls=$(printf '%s\n' "$out" | grep -Eo 'https://[^" ,]*/pull/[0-9]+' | tr '\n' ' ')
      if [ -n "$urls" ]; then printf 'open %s' "$urls"
      else printf 'unknown (missing PR URL)'; fi
      ;;
  esac
}

# Prints landed when a merged PR's head is exactly <head>, as fm-teardown.sh's
# merged-PR proof requires; otherwise none or an explicit unknown.
merged_evidence() { # <project> <branch> <head> <forge>
  local out sha url
  github_target "$1" "$4" || return 0
  command -v gh >/dev/null 2>&1 || { printf 'unknown (gh absent)'; return; }
  out=$(gh api --hostname "$HOST" --method GET "repos/$REPO/pulls" \
    -f state=closed -f head="${REPO%%/*}:$2" -F per_page=100 \
    --jq '.[] | select(.merged_at != null) | .head.sha + "\t" + .html_url' 2>/dev/null) || {
    printf 'unknown (forge read failed)'; return
  }
  while IFS=$'\t' read -r sha url; do
    [ -n "$sha$url" ] || continue
    case "$sha" in *[!0-9a-f]*|'') printf 'unknown (invalid forge response)'; return ;; esac
    [ "${#sha}" = 40 ] || { printf 'unknown (invalid forge response)'; return; }
    [ "$sha" != "$3" ] || { printf landed; return; }
  done <<EOF
$out
EOF
  printf none
}

content_landed() { # <project> <head> <base-branch>
  local base tree merged
  base=$(git -C "$1" rev-parse --quiet --verify "refs/remotes/origin/$3^{tree}" 2>/dev/null) || return 1
  merged=$(git -C "$1" merge-tree --write-tree "refs/remotes/origin/$3" "$2" 2>/dev/null) || return 1
  tree=$(printf '%s\n' "$merged" | head -1)
  [ "$tree" = "$base" ]
}

scan_project() { # <project>
  local project=$1 name common prefix posture forge branch head task owner meta
  local matched count refs ref default mode meta_branch candidate_mode branches
  local base candidate_base top
  top=$(git -C "$project" rev-parse --show-toplevel 2>/dev/null) || return 0
  [ "$project" -ef "$top" ] || return 0
  common=$(git -C "$project" rev-parse --git-common-dir 2>/dev/null) || return 0
  common=$(cd "$project" && cd "$common" && pwd -P) || return 0
  case "$SEEN" in *"$NL$common$NL"*) return 0 ;; esac
  SEEN="$SEEN$common$NL"
  name=${project%/}; name=${name##*/}
  posture=$(FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-project-mode.sh" "$name" 2>/dev/null) || {
    printf 'UNPUSHED: project=%s incomplete: delivery posture unreadable\n' "$project"; return
  }
  case "$posture" in local-only\ *) return 0 ;; esac
  prefix=$(FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-project-mode.sh" --branch-prefix "$name" 2>/dev/null)
  forge=$(FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-project-mode.sh" --forge "$name" 2>/dev/null)
  default=$(fm_default_branch "$project" || true)
  # Resolve immutable object IDs, not branch names, so a concurrent branch move
  # cannot change which commit the count in this finding describes.
  refs=$(git -C "$project" for-each-ref --format='%(objectname) %(refname)' refs/remotes/) || {
    printf 'UNPUSHED: project=%s incomplete: remote refs unreadable\n' "$project"; return
  }
  branches=$(git -C "$project" for-each-ref --format='%(objectname) %(refname)' refs/heads/) || {
    printf 'UNPUSHED: project=%s incomplete: local branches unreadable\n' "$project"; return
  }
  while IFS=' ' read -r head branch; do
    [ -n "$branch" ] || continue
    branch=${branch#refs/heads/}
    [ "$branch" != "$default" ] || continue
    task='' owner=missing matched='' mode='' base=$default
    while IFS=$'\t' read -r meta matched meta_branch candidate_mode candidate_base; do
      [ "$meta_branch" = "$branch" ] || continue
      # Bind metadata to this Git repository, not just the branch name.
      ref=$(git -C "$matched" rev-parse --git-common-dir 2>/dev/null) || continue
      ref=$(cd "$matched" && cd "$ref" && pwd -P) || continue
      [ "$ref" = "$common" ] || continue
      task=${meta##*/}; task=${task%.meta}
      owner=recorded
      mode=$candidate_mode
      [ "$candidate_base" = - ] || base=$candidate_base
      break
    done <<EOF
$META_ROWS
EOF
    [ "$mode" != local-only ] || continue
    if [ -z "$task" ]; then
      case "$branch" in "$prefix"*) task=${branch#"$prefix"} ;; *) continue ;; esac
    fi
    # Exclude every publishing remote, not just the task's upstream. The
    # no-mistakes remote is a local validation proxy, not a publishing remote.
    set -- "$head" --not
    while IFS=' ' read -r ref matched; do
      [ -n "$ref" ] || continue
      case "$matched" in refs/remotes/no-mistakes/*) continue ;; esac
      set -- "$@" "$ref"
    done <<EOF
$refs
EOF
    count=$(git -C "$project" rev-list --count "$@" 2>/dev/null) || {
      printf 'UNPUSHED: project=%s branch=%s incomplete: reachability unreadable\n' "$project" "$branch"; continue
    }
    [ "$count" != 0 ] || continue
    [ -z "$base" ] || ! content_landed "$project" "$head" "$base" || continue
    printf '%s\t%s\t%s\t%s\t%s\tUNPUSHED: project=%s branch=%s head=%s commits=%s task=%s owner=%s; flag for supervisor recovery\n' \
      "$project" "$branch" "$head" "${task:--}" "$forge" \
      "$project" "$branch" "$head" "$count" "$task" "$owner" >> "$CANDIDATES"
  done <<EOF
$branches
EOF
}

compare_branch() { # <project> <branch> <task> <forge> <merged-evidence>
  local project=$1 branch=$2 task=$3 forge=$4 merged=$5 ledger=unknown decisions key verb note
  if fm_task_id_path_safe "$task"; then
    if fm_backlog_row_probe "$DATA" "$task"; then
      ledger=${FM_BACKLOG_ROW_STATE% no no}
    elif [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then ledger=missing
    fi
    decisions=$(status_open_decisions "$STATE/$task.status")
    while IFS=$'\t' read -r key verb note; do
      [ -n "$key" ] || continue
      printf 'UNPUSHED: task=%s [key=%s] %s: %s; escalate before retrying publication\n' \
        "$task" "$key" "$verb" "$(field "$note")"
    done <<EOF
$decisions
EOF
  fi
  printf 'UNPUSHED: branch=%s ledger=%s pr=%s merged=%s; reconcile the ledger and resume the owning task or escalate its blocker\n' \
    "$branch" "$ledger" "$(pr_evidence "$project" "$branch" "$forge")" "$merged"
}

case "${1:-}" in
  -h|--help) sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
  scan)
    secs=${FM_UNPUSHED_TIMEOUT_SECS:-20}
    case "$secs" in ''|*[!0-9]*) exit 2 ;; esac
    [ "$secs" -gt 0 ] && [ "$secs" -le 120 ] || exit 2
    work=$(mktemp -d "${TMPDIR:-/tmp}/fm-unpushed.XXXXXX") || exit 1
    trap 'rm -rf "$work"' EXIT
    : > "$work/candidates"; : > "$work/resolved"
    # A timeout still names every discovered branch the scan had not resolved.
    FM_UNPUSHED_WORK=$work fm_run_timed "$secs" bash "$SCRIPT_DIR/fm-unpushed-reconcile.sh" --scan || {
      tail -n +"$(( $(wc -l < "$work/resolved") + 1 ))" "$work/candidates" | cut -f6-
      printf 'UNPUSHED: incomplete scan (failed or exceeded %ss); rerun %s scan\n' "$secs" "$SCRIPT_DIR/fm-unpushed-reconcile.sh"
    }
    ;;
  --scan)
    NL=$'\n'; SEEN=$NL
    [ -n "${FM_UNPUSHED_WORK:-}" ] || exit 2
    CANDIDATES=$FM_UNPUSHED_WORK/candidates
    # Read metadata once, rather than forking a read for every branch x task.
    # Missing fields use a placeholder to keep empty TSV fields from shifting.
    set -- /dev/null
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      set -- "$@" "$meta"
    done
    META_ROWS=$(awk -F= '
      function emit() {
        if (project != "" && kind != "secondmate")
          printf "%s\t%s\t%s\t%s\t%s\n", file, project, (branch == "" ? "-" : branch), (mode == "" ? "-" : mode), (base == "" ? "-" : base)
      }
      FNR == 1 { emit(); file=FILENAME; project=branch=mode=kind=base="" }
      $1 == "project" { project=substr($0,9) }
      $1 == "branch" { branch=substr($0,8) }
      $1 == "mode" { mode=substr($0,6) }
      $1 == "kind" { kind=substr($0,6) }
      $1 == "base_branch" { base=substr($0,13) }
      END { emit() }
    ' "$@") || { printf 'UNPUSHED: incomplete scan: task metadata unreadable\n'; exit 0; }
    for project in "$PROJECTS"/*; do
      [ -d "$project" ] || continue
      scan_project "$project"
    done
    while IFS=$'\t' read -r meta project _branch _mode _base; do
      [ -n "$project" ] || continue
      scan_project "$project"
    done <<EOF
$META_ROWS
EOF
    # Comparison may be partial, visibility is not: the parent prints every
    # candidate not yet resolved here when the scan budget runs out.
    while IFS=$'\t' read -r project branch head task forge identity; do
      merged=$(merged_evidence "$project" "$branch" "$head" "$forge")
      if [ "$merged" = landed ]; then
        echo >> "$FM_UNPUSHED_WORK/resolved"; continue
      fi
      printf '%s\n' "$identity"
      echo >> "$FM_UNPUSHED_WORK/resolved"
      compare_branch "$project" "$branch" "$task" "$forge" "$merged"
    done < "$CANDIDATES"
    ;;
  *) printf 'usage: fm-unpushed-reconcile.sh scan\n' >&2; exit 2 ;;
esac
