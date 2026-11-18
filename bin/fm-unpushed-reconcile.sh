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
# metadata, deduplicated by Git common directory. Never traverse secondmate
# homes or backend endpoint inventories. Branches match the registered prefix
# (default fm/) or an exact ordinary task metadata branch. Local-only projects
# and tasks are excluded. Each finding names the branch/head, count of commits
# unreachable from publishing remote-tracking refs, matching task, backlog row,
# open PR lookup, and still-open status decisions. No-mistakes proxy refs do
# not prove publication. Remote refs are local evidence, not a live remote
# inventory; startup's fleet refresh owns fetching them.
#
# PR lookups use gh-axi for GitHub publication targets. Other forges, missing
# tools, malformed responses, and failed reads are explicit unknowns. A PR
# never hides local follow-up commits. Findings request supervisor action,
# including escalation of a blocked pipeline start; retry authority and all
# gate decisions stay with the supervisor. Nothing automatically retries a
# gate-context failure or administers the shared daemon.
#
# FM_HOME selects the home. FM_DATA_OVERRIDE, FM_STATE_OVERRIDE and
# FM_PROJECTS_OVERRIDE select its directories. FM_UNPUSHED_TIMEOUT_SECS bounds
# the entire scan (default 20, maximum 120). A timeout retains partial output
# and prints an actionable incomplete-scan diagnostic. Exit 0 includes
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

pr_evidence() { # <project> <branch> <forge>
  local target host repo out count urls
  [ "$3" = none ] || { printf 'unknown (forge=%s)' "$3"; return; }
  target=$(fm_role_publication_target "$1")
  host=${target%%/*}
  repo=${target#*/}
  case "$host" in
    github.com|*.ghe.com) ;;
    *) printf 'unknown (no GitHub target)'; return ;;
  esac
  command -v gh-axi >/dev/null 2>&1 || { printf 'unknown (gh-axi absent)'; return; }
  out=$(gh-axi pr list --hostname "$host" -R "$repo" --state open \
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

scan_project() { # <project>
  local project=$1 name common prefix posture forge branch head task owner meta
  local matched count refs ref default mode meta_branch candidate_mode branches
  git -C "$project" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
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
    task='' owner=missing matched='' mode=''
    while IFS=$'\t' read -r meta matched meta_branch candidate_mode; do
      [ "$meta_branch" = "$branch" ] || continue
      # Bind metadata to this Git repository, not just the branch name.
      ref=$(git -C "$matched" rev-parse --git-common-dir 2>/dev/null) || continue
      ref=$(cd "$matched" && cd "$ref" && pwd -P) || continue
      [ "$ref" = "$common" ] || continue
      task=${meta##*/}; task=${task%.meta}
      owner=recorded
      mode=$candidate_mode
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
    # Emit the branch before any external read so an aggregate timeout cannot
    # swallow the branch identity that prompted recovery.
    printf 'UNPUSHED: project=%s branch=%s head=%s commits=%s task=%s owner=%s; flag for supervisor recovery\n' \
      "$project" "$branch" "$head" "$count" "$task" "$owner"
    printf '%s\t%s\t%s\t%s\n' "$project" "$branch" "${task:--}" "$forge" >> "$CANDIDATES"
  done <<EOF
$branches
EOF
}

compare_branch() { # <project> <branch> <task> <forge>
  local project=$1 branch=$2 task=$3 forge=$4 ledger=unknown decisions key verb note
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
  printf 'UNPUSHED: branch=%s ledger=%s pr=%s; reconcile the ledger and resume the owning task or escalate its blocker\n' \
    "$branch" "$ledger" "$(pr_evidence "$project" "$branch" "$forge")"
}

case "${1:-}" in
  -h|--help) sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
  scan)
    secs=${FM_UNPUSHED_TIMEOUT_SECS:-20}
    case "$secs" in ''|*[!0-9]*) exit 2 ;; esac
    [ "$secs" -gt 0 ] && [ "$secs" -le 120 ] || exit 2
    fm_run_timed "$secs" bash "$SCRIPT_DIR/fm-unpushed-reconcile.sh" --scan || \
      printf 'UNPUSHED: incomplete scan (failed or exceeded %ss); rerun %s scan\n' "$secs" "$SCRIPT_DIR/fm-unpushed-reconcile.sh"
    ;;
  --scan)
    NL=$'\n'; SEEN=$NL
    CANDIDATES=$(mktemp "${TMPDIR:-/tmp}/fm-unpushed.XXXXXX") || exit 1
    trap 'rm -f "$CANDIDATES"' EXIT
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
          printf "%s\t%s\t%s\t%s\n", file, project, (branch == "" ? "-" : branch), (mode == "" ? "-" : mode)
      }
      FNR == 1 { emit(); file=FILENAME; project=branch=mode=kind="" }
      $1 == "project" { project=substr($0,9) }
      $1 == "branch" { branch=substr($0,8) }
      $1 == "mode" { mode=substr($0,6) }
      $1 == "kind" { kind=substr($0,6) }
      END { emit() }
    ' "$@") || { printf 'UNPUSHED: incomplete scan: task metadata unreadable\n'; exit 0; }
    for project in "$PROJECTS"/*; do
      [ -d "$project" ] || continue
      scan_project "$project"
    done
    while IFS=$'\t' read -r meta project _branch _mode; do
      [ -n "$project" ] || continue
      scan_project "$project"
    done <<EOF
$META_ROWS
EOF
    # Flag every locally discovered branch before a slow forge or ledger can
    # consume the scan budget. Comparison may be partial, visibility is not.
    while IFS=$'\t' read -r project branch task forge; do
      compare_branch "$project" "$branch" "$task" "$forge"
    done < "$CANDIDATES"
    ;;
  *) printf 'usage: fm-unpushed-reconcile.sh scan\n' >&2; exit 2 ;;
esac
