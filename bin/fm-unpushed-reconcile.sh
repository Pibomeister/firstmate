#!/usr/bin/env bash
# Flag local task branches with commits absent from publishing remote refs.
#
# Usage: fm-unpushed-reconcile.sh scan [--work-dir <private-directory>]
#        fm-unpushed-reconcile.sh discover --work-dir <private-directory>
#        fm-unpushed-reconcile.sh pending --work-dir <private-directory>
# discover records local inventory without running publication/landing proofs.
# A caller supplying --work-dir owns its lifetime and can replay pending after
# killing the scanner's own process group. The timed scan runs in a separate
# group that kill cannot reach, so it records that group in the work directory
# and pending ends it first when it is still live. The scan names that group with
# a random token, kept in the work directory and passed as the timed command's
# last argument. Standalone scan owns its temp dir.
# The private journal is append-only TSV: P|S, project, branch, full head.
# P records inventory before any per-branch proof; S settles that exact head
# when it is excluded, proven published/landed, or its identity is printed.
# pending prints the latest unsettled identity per project/branch. Its task
# eligibility and publication state remain explicitly unverified on timeout.
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
# PR lookups use gh-axi, including its authenticated API for merged heads, for
# GitHub publication targets. Other forges, missing
# tools, malformed responses, and failed reads are explicit unknowns. A PR
# never hides local follow-up commits. Findings request supervisor action,
# including escalation of a blocked pipeline start; retry authority and all
# gate decisions stay with the supervisor. Nothing automatically retries a
# gate-context failure or administers the shared daemon.
#
# FM_HOME selects the home. FM_DATA_OVERRIDE, FM_STATE_OVERRIDE and
# FM_PROJECTS_OVERRIDE select its directories. FM_UNPUSHED_TIMEOUT_SECS bounds
# the entire scan (default 20, maximum 120). FM_UNPUSHED_DEADLINE, an optional
# absolute epoch second, lowers that bound so the scan ends before it, or skips
# the scan when no time is left. A timeout retains partial output,
# names every discovered branch not yet resolved, and prints an actionable
# incomplete-scan diagnostic. Exit 0 includes
# findings/unknowns; usage or an invalid bound or deadline exits 2.
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

journal_settled() { printf 'S\t%s\t%s\t%s\n' "$1" "$2" "$3" >> "$FM_UNPUSHED_WORK/journal"; }

# Ends the recorded timed scan group of <work directory> when it is still live,
# so nothing a cut-short scan started outlives the caller that replays it. Only
# a group with a member whose command line ends with this work directory's scan
# token is ended, and never the caller's own group, so a stale or reused id ends
# nothing else. The token is plain hex, so no work directory path, however
# spelled, can make another scan match. COLUMNS is pinned wide so an ambient
# narrow terminal width never cuts the command column the match reads.
scan_token() { od -An -N12 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'; }
end_scan_group() { # <caller-owned work directory>
  local group own token
  [ -f "$1/group" ] && [ ! -L "$1/group" ] || return 0
  [ -f "$1/token" ] && [ ! -L "$1/token" ] || return 0
  group=$(cat "$1/group" 2>/dev/null) || return 0
  case "$group" in ''|*[!0-9]*|0|1) return 0 ;; esac
  token=$(cat "$1/token" 2>/dev/null) || return 0
  case "$token" in *[!0-9a-f]*) return 0 ;; esac
  [ "${#token}" -eq 24 ] || return 0
  own=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')
  [ "$group" != "$own" ] || return 0
  COLUMNS=10000 ps -A -o pgid= -o command= 2>/dev/null | awk -v g="$group" -v t=" $token" '
    { sub(/[ \t]+$/, "") }
    $1 == g && index($0, "fm-unpushed-reconcile.sh") && substr($0, length($0) - length(t) + 1) == t { found=1 }
    END { exit !found }
  ' || return 0
  kill -KILL -- "-$group" 2>/dev/null || true
}

pending_inventory() { # <caller-owned work directory>; no network or Git reads
  [ -f "$1/journal" ] && [ ! -L "$1/journal" ] || return 0
  awk -F '\t' '
    NF == 4 && ($1 == "P" || $1 == "S") {
      key=$2 SUBSEP $3
      if ($1 == "P") {
        if (!(key in seen)) { order[++n]=key; seen[key]=1 }
        project[key]=$2; branch[key]=$3; head[key]=$4; pending[key]=1
      } else if (head[key] == $4) pending[key]=0
    }
    END {
      for (i=1; i<=n; i++) {
        key=order[i]
        if (pending[key]) printf "UNPUSHED: project=%s branch=%s head=%s; inspection incomplete, task eligibility and publication unverified\n", project[key], branch[key], head[key]
      }
    }
  ' "$1/journal"
}

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
# merged-PR proof requires; otherwise none or an explicit unknown. The PR head
# lives in origin, which in a fork workflow differs from the destination.
merged_evidence() { # <project> <branch> <head> <forge>
  local source owner out shas sha
  github_target "$1" "$4" || return 0
  source=$(fm_role_remote_identity "$(git -C "$1" remote get-url origin 2>/dev/null)" "$1")
  owner=${source#*/}; owner=${owner%%/*}
  case "$source" in
    "$HOST"/?*/?*) ;;
    *) printf 'unknown (no GitHub origin)'; return ;;
  esac
  case "$2" in *[!A-Za-z0-9._/-]*) printf 'unknown (branch name not queryable)'; return ;; esac
  command -v gh-axi >/dev/null 2>&1 || { printf 'unknown (gh-axi absent)'; return; }
  out=$(gh-axi api --hostname "$HOST" "/repos/$REPO/pulls?state=closed&head=$owner:$2&per_page=100" \
    --jq 'if length >= 100 then error("pull request enumeration incomplete") else [.[] | select(.merged_at != null) | .head.sha] | join(" ") end' --full 2>/dev/null) || {
    printf 'unknown (forge read failed)'; return
  }
  printf '%s\n' "$out" | grep -qx '  truncated: false' || { printf 'unknown (invalid forge response)'; return; }
  [ "$(printf '%s\n' "$out" | grep -c '^  body: ')" = 1 ] || { printf 'unknown (invalid forge response)'; return; }
  shas=$(printf '%s\n' "$out" | sed -n 's/^  body: //p')
  case "$shas" in \"*\") shas=${shas#\"}; shas=${shas%\"} ;; esac
  case "$shas" in *[!0-9a-f\ ]*) printf 'unknown (invalid forge response)'; return ;; esac
  for sha in $shas; do
    [ "${#sha}" = 40 ] || { printf 'unknown (invalid forge response)'; return; }
    [ "$sha" != "$3" ] || { printf landed; return; }
  done
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
  branches=$(git -C "$project" for-each-ref --format='%(objectname) %(refname)' refs/heads/) || {
    printf 'UNPUSHED: project=%s incomplete: local branches unreadable\n' "$project"; return
  }
  # Retain every returned non-default identity before metadata, reachability,
  # landing proofs, or network reads can consume either timeout budget.
  while IFS=' ' read -r head branch; do
    [ -n "$branch" ] || continue
    branch=${branch#refs/heads/}
    [ "$branch" != "$default" ] || continue
    printf 'P\t%s\t%s\t%s\n' "$project" "$branch" "$head" >> "$FM_UNPUSHED_WORK/journal" || return 1
  done <<EOF
$branches
EOF
  [ "$DISCOVER_ONLY" = 0 ] || return 0
  refs=$(git -C "$project" for-each-ref --format='%(objectname) %(refname)' refs/remotes/) || {
    printf 'UNPUSHED: project=%s incomplete: remote refs unreadable\n' "$project"; return
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
    if [ "$mode" = local-only ]; then journal_settled "$project" "$branch" "$head"; continue; fi
    if [ -z "$task" ]; then
      case "$branch" in
        "$prefix"*) task=${branch#"$prefix"} ;;
        *) journal_settled "$project" "$branch" "$head"; continue ;;
      esac
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
    if [ "$count" = 0 ] || { [ -n "$base" ] && content_landed "$project" "$head" "$base"; }; then
      journal_settled "$project" "$branch" "$head"; continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\tUNPUSHED: project=%s branch=%s head=%s commits=%s task=%s owner=%s; flag for supervisor recovery\n' \
      "$project" "$branch" "$head" "${task:--}" "${forge:--}" \
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
  scan|discover|pending)
    mode=$1; shift
    own_work=0
    if [ "$#" = 0 ] && [ "$mode" = scan ]; then
      work=$(mktemp -d "${TMPDIR:-/tmp}/fm-unpushed.XXXXXX") || exit 1
      own_work=1
    elif [ "$#" = 2 ] && [ "$1" = --work-dir ]; then
      work=$2
    else
      printf 'usage: fm-unpushed-reconcile.sh scan|discover|pending [--work-dir <private-directory>]\n' >&2; exit 2
    fi
    case "$work" in /*) ;; *) exit 2 ;; esac
    [ -d "$work" ] && [ ! -L "$work" ] && [ -O "$work" ] || exit 2
    for record in journal candidates group token; do
      [ ! -L "$work/$record" ] || exit 2
      { [ ! -e "$work/$record" ] || [ -f "$work/$record" ]; } || exit 2
    done
    [ "$own_work" = 0 ] || trap 'rm -rf "$work"' EXIT
    if [ "$mode" = pending ]; then end_scan_group "$work"; pending_inventory "$work"; exit; fi
    : >> "$work/journal" || exit 1
    : > "$work/candidates" || exit 1
    secs=${FM_UNPUSHED_TIMEOUT_SECS:-20}
    case "$secs" in ''|*[!0-9]*) exit 2 ;; esac
    [ "$secs" -gt 0 ] && [ "$secs" -le 120 ] || exit 2
    # The deadline caps the bound where the timer starts, so time a caller
    # spent reaching this line cannot push the timed group past it. The
    # margin covers the floored clock, the one-second kill grace and reaping.
    case "${FM_UNPUSHED_DEADLINE:-}" in
      '') ;;
      *[!0-9]*) exit 2 ;;
      *)
        left=$(( FM_UNPUSHED_DEADLINE - $(date +%s) - 3 ))
        [ "$left" -ge "$secs" ] || secs=$left
        [ "$secs" -ge 0 ] || secs=0
        ;;
    esac
    child_mode=--scan
    [ "$mode" != discover ] || child_mode=--discover
    # A timeout still names every discovered branch the scan had not resolved.
    # The timer can still start late on a loaded host; the timed group records
    # itself so a caller's replay can end it (end_scan_group).
    rm -f "$work/group" "$work/token"
    # Without a token the scan still runs; a replay just cannot end it.
    token=$(scan_token)
    case "$token" in *[!0-9a-f]*) token= ;; esac
    [ "${#token}" -eq 24 ] || token=
    [ -z "$token" ] || printf '%s\n' "$token" > "$work/token" || exit 1
    if [ "$secs" -eq 0 ] || ! FM_UNPUSHED_WORK=$work fm_run_timed "$secs" bash "$SCRIPT_DIR/fm-unpushed-reconcile.sh" "$child_mode" "$work" ${token:+"$token"}; then
      pending_inventory "$work"
      printf 'UNPUSHED: incomplete scan (failed or exceeded %ss); rerun %s scan\n' "$secs" "$SCRIPT_DIR/fm-unpushed-reconcile.sh"
    fi
    rm -f "$work/group" "$work/token"
    ;;
  --scan|--discover)
    DISCOVER_ONLY=0
    [ "$1" != --discover ] || DISCOVER_ONLY=1
    NL=$'\n'; SEEN=$NL
    [ -n "${FM_UNPUSHED_WORK:-}" ] || exit 2
    # Name this timed group before any read, then stop at once when the
    # caller's deadline passed before the group started.
    ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ' > "$FM_UNPUSHED_WORK/group" || exit 1
    case "${FM_UNPUSHED_DEADLINE:-}" in
      ''|*[!0-9]*) ;;
      *) [ "$(date +%s)" -lt "$FM_UNPUSHED_DEADLINE" ] || exit 1 ;;
    esac
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
    [ "$DISCOVER_ONLY" = 0 ] || exit 0
    # Comparison may be partial, visibility is not: the parent prints every
    # candidate not yet resolved here when the scan budget runs out.
    while IFS=$'\t' read -r project branch head task forge identity; do
      merged=$(merged_evidence "$project" "$branch" "$head" "$forge")
      if [ "$merged" = landed ]; then
        journal_settled "$project" "$branch" "$head"; continue
      fi
      printf '%s\n' "$identity"
      journal_settled "$project" "$branch" "$head"
      compare_branch "$project" "$branch" "$task" "$forge" "$merged"
    done < "$CANDIDATES"
    ;;
  *) printf 'usage: fm-unpushed-reconcile.sh scan\n' >&2; exit 2 ;;
esac
