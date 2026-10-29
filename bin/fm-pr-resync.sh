#!/usr/bin/env bash
# The one owner for continuing work on a branch whose pull-request head the
# no-mistakes pipeline may have rebased and republished. Spawn, promotion,
# relaunch and worker guidance call this instead of hand-run recovery.
#
# Usage: fm-pr-resync.sh <task-id> <worktree> <branch> [--check]
#
# In the absolute task <worktree> it verifies <branch>'s published head on
# origin (the fetched ref must equal the freshly advertised head), classifies the
# local branch against it and advances it with an old-OID-conditional ref
# update followed by a keep-style two-tree index/worktree update on a clean tree:
#   equal              no ref change
#   ahead:N            no ref change; N unpublished local commits stay
#   advanced           local was behind and now sits at the published head
#   archived-advanced  local diverged (stale pre-rebase history): it is first
#                      preserved at refs/heads/archive/<task>-pre-rebase-<sha8>
# A detached worktree is first switched to <branch>, created at the published
# head when absent, refusing without switching if detached commits are absent
# from both the requested branch and published history. It refuses an in-progress
# rebase/merge/cherry-pick/revert/bisect, <branch> checked out elsewhere, a different named branch, a branch
# origin lacks, and an archive name already held by another commit. The remote
# head is read again just before and just after the move. A concurrent local
# branch writer makes the conditional update refuse, preserving that writer.
# Every Git network operation uses the existing bounded-command runner with
# NM_TIMEOUT seconds (120 by default, FM_PR_RESYNC_TIMEOUT may override with a
# positive integer). Network failure or timeout refuses and reports any earlier
# archive or advance; no coreutils timeout dependency is required.
#
# When the worktree has a `no-mistakes` remote, branch custody is read with the
# read-only `no-mistakes axi sync --check` before anything moves, again just
# before the move, and after it. continue_active_run exits 3. Settled verdicts:
# synchronized, already_synchronized, user_owned, custody_returned/gate_ready,
# or no push binding for the branch (blocked_wrong_branch with no run). It acts
# only on native next_action codes, with fixed commands: recover_custody runs
# `no-mistakes axi sync --recover`, adding --keep-local only when the native
# command carries it and its recovery block proves (proof: verified) a
# refs/heads/archive/<task>-* archive at preserved_head with the local head as
# required_head; adopt_published runs `no-mistakes axi sync --adopt-published`.
# blocked_recover_manual_reconciliation naming an unpublished preserved
# pipeline head fetches that commit from the gate, archives it at
# refs/heads/archive/<task>-pipeline-<sha8> and binds it with the bind-only
# `no-mistakes sync --bind-archive-ref <ref>`, then continues only on the
# recover_custody offer above. Each action is followed by a fresh check that
# must read settled; anything else refuses and prints the native output.
# It never force-pushes, force-moves or deletes a ref, starts, aborts or
# cancels a run, discards a pipeline commit, or administers the daemon.
# A verdict outside that handled set (settled, blocked_diverged,
# blocked_remote_rewritten, blocked_recover_manual_reconciliation, a
# recover_custody or adopt_published offer, continue_active_run) refuses before
# anything moves. --check runs the checks and the read-only custody preflight,
# fetching objects only, then reports the planned action without any switch,
# ref change (remote-tracking refs and FETCH_HEAD included) or recovery.
#
# Exit: 0 settled, 1 refused (output names what already changed), 2 usage,
# 3 pipeline-active (prints the monitoring-only contract, each line prefixed
# `fm-pr-resync: monitoring-only: `). The last stdout line is always
#   fm-pr-resync: result=<equal|ahead:N|advanced|archived-advanced|planned:<none|advance|archive-advance|create>> archive=<refs,|-> custody=<settled|none|pipeline-active|refused> head=<sha|->
# custody=none means the worktree has no no-mistakes gate, or --check.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

NM_TIMEOUT=${FM_PR_RESYNC_TIMEOUT:-120}
[[ "$NM_TIMEOUT" =~ ^[0-9]*[1-9][0-9]*$ ]] || { echo "error: FM_PR_RESYNC_TIMEOUT must be a positive integer" >&2; exit 2; }

usage() {
  echo "usage: fm-pr-resync.sh <task-id> <absolute-worktree> <branch> [--check]" >&2
  exit 2
}

check_mode=0
if [ "$#" -eq 4 ] && [ "$4" = --check ]; then
  check_mode=1
  set -- "$1" "$2" "$3"
fi
[ "$#" -eq 3 ] || usage
task=$1 wt=$2 branch=$3
case "$task" in ''|*[!A-Za-z0-9._-]*) usage ;; esac
case "$wt" in /*) ;; *) usage ;; esac
git check-ref-format --branch "$branch" >/dev/null 2>&1 || usage
git check-ref-format "refs/heads/archive/$task-pre-rebase-x" || usage

archive=- changed='' result=planned:none

g() { git -C "$wt" "$@"; }
say() { printf 'fm-pr-resync: %s\n' "$1"; }
finish() {  # <rc> <result> <custody>
  printf 'fm-pr-resync: result=%s archive=%s custody=%s head=%s\n' "$2" "$archive" "$3" \
    "$(g rev-parse -q --verify "refs/heads/$branch" 2>/dev/null || echo -)"
  exit "$1"
}
refuse() {
  say "refused: $1"
  say "changed: ${changed:-nothing}; no commit was made unreachable"
  finish 1 "$result" refused
}
note_change() { changed="${changed:+$changed; }$1"; }
clean() { [ -z "$(g status --porcelain --untracked-files=all 2>&1)" ]; }
network_git() { fm_nm_bounded "$wt" "$NM_TIMEOUT" git "$@"; }
advertised() {
  local out
  out=$(network_git ls-remote --heads origin "refs/heads/$branch" 2>/dev/null) || return 1
  printf '%s\n' "$out" | awk 'NR == 1 { print $1 }'
}

monitoring_only() {  # <rc-3 result>
  local line
  for line in \
    "A no-mistakes run holds custody of branch $branch." \
    "You may reattach the active run with \`no-mistakes axi run\` (no flags), answer the gates it presents under your brief's gate and ask-user rules, and make your brief's CI-ready report through its named-head check." \
    "Do not edit, commit, start, rerun or abort a run, begin a new phase, or take any other outward action until \`$SCRIPT_DIR/fm-pr-resync.sh $task $wt $branch\` exits 0 against the published head."; do
    say "monitoring-only: $line"
  done
  finish 3 "$1" pipeline-active
}

nm_check() {
  v_out=$(fm_nm_run_bounded "$wt" "$NM_TIMEOUT" axi sync --check 2>&1)
  v_state=$(fm_nm_branch_sync_state "$v_out")
  v_safety=$(fm_nm_strip_quotes "$(fm_nm_field "$v_out" safety)")
  v_code=$(fm_nm_branch_sync_nested "$v_out" next_action code)
  v_cmd=$(fm_nm_branch_sync_nested "$v_out" next_action command)
  v_run=$(fm_nm_branch_sync_nested "$v_out" pipeline run)
}
settled() {
  case "$v_state" in synchronized|already_synchronized|user_owned) return 0 ;; esac
  [ "$v_state" = custody_returned ] && [ "$v_safety" = gate_ready ] && return 0
  [ -n "$v_state" ] && [ "$v_safety" = blocked_wrong_branch ] && [ -z "$v_run" ]
}
unsettled() {
  printf '%s\n' "$v_out"
  refuse "no-mistakes custody is ${v_state:-unreadable}/${v_safety:-unknown} (next_action ${v_code:-none}), not a verdict this owner settles"
}
handled() {  # verdicts the git step or a native-offered action can settle
  settled && return 0
  case "$v_safety" in blocked_diverged|blocked_remote_rewritten|blocked_recover_manual_reconciliation) return 0 ;; esac
  case "$v_code" in recover_custody|adopt_published) return 0 ;; esac
  return 1
}
rec() { fm_nm_branch_sync_nested "$v_out" recovery "$1"; }
keep_local_proven() {
  local ref pres
  [ "$(rec proof)" = verified ] || return 1
  ref=$(rec archive_ref)
  case "$ref" in "refs/heads/archive/$task-"*) ;; *) return 1 ;; esac
  pres=$(rec preserved_head)
  [ -n "$pres" ] && [ "$(g rev-parse -q --verify "$ref^{commit}")" = "$pres" ] || return 1
  [ "$(rec required_head)" = "$(g rev-parse -q --verify "refs/heads/$branch")" ]
}

make_archive() {  # <kind> <commit>
  local ref have
  ref="refs/heads/archive/$task-$1-$(printf '%.8s' "$2")"
  have=$(g rev-parse -q --verify "$ref^{commit}")
  if [ -n "$have" ]; then
    [ "$have" = "$2" ] || refuse "archive $ref already exists at $have, not $2"
    say "reusing archive $ref at $2"
  else
    g update-ref "$ref" "$2" "" || refuse "could not create archive $ref"
    note_change "created archive $ref at $2"
  fi
  if [ "$archive" = - ]; then archive=$ref; else archive="$archive,$ref"; fi
}

run_fixed() {  # <no-mistakes args...>
  local out rc
  out=$(fm_nm_run_bounded "$wt" "$NM_TIMEOUT" "$@" 2>&1)
  rc=$?
  printf '%s\n' "$out"
  [ "$rc" -eq 0 ] || refuse "\`no-mistakes $*\` failed (exit $rc)"
}

bind_pipeline_head() {
  local ph
  ph=$(fm_nm_branch_sync_nested "$v_out" pipeline current_head)
  case "$ph" in *[!0-9a-f]*|'') unsettled ;; esac
  [ "${#ph}" -eq 40 ] || unsettled
  ! g merge-base --is-ancestor "$ph" "refs/heads/$branch" 2>/dev/null || unsettled
  network_git fetch --quiet --no-tags no-mistakes "$ph" || refuse "could not fetch preserved pipeline head $ph from the no-mistakes gate (network failure or ${NM_TIMEOUT}s timeout)"
  [ "$(g cat-file -t "$ph" 2>/dev/null)" = commit ] || refuse "preserved pipeline head $ph is not a commit"
  make_archive pipeline "$ph"
  run_fixed sync --bind-archive-ref "refs/heads/archive/$task-pipeline-$(printf '%.8s' "$ph")"
  nm_check
  [ "$v_code" = recover_custody ] || unsettled
}

# --- a: guards before any change ------------------------------------------------
[ -d "$wt" ] || refuse "$wt is not a directory"
top=$(g rev-parse --show-toplevel 2>/dev/null) || refuse "$wt is not a git worktree"
wt_phys=$(cd "$wt" && pwd -P)
[ "$(cd "$top" && pwd -P)" = "$wt_phys" ] || refuse "$wt is not a worktree top level"
for p in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
  path=$(g rev-parse --git-path "$p")
  case "$path" in /*) ;; *) path="$wt/$path" ;; esac
  [ ! -e "$path" ] || refuse "worktree has an in-progress operation ($p)"
done
while IFS= read -r other; do
  [ -n "$other" ] || continue
  [ "$( (cd "$other" 2>/dev/null && pwd -P) || printf '%s' "$other")" = "$wt_phys" ] \
    || refuse "branch $branch is checked out in another worktree ($other)"
done < <(g worktree list --porcelain | awk -v want="branch refs/heads/$branch" \
  '/^worktree / { w = substr($0, 10) } $0 == want { print w }')
cur=$(g symbolic-ref -q --short HEAD)
[ -z "$cur" ] || [ "$cur" = "$branch" ] || refuse "worktree is on branch $cur, not $branch"

if [ "$check_mode" -eq 1 ]; then
  # Objects only: no remote-tracking ref or FETCH_HEAD changes in --check, so
  # the advertised head is read before and after the fetch and must agree.
  pub=$(advertised) || refuse "could not read origin $branch (network failure or ${NM_TIMEOUT}s timeout)"
  network_git fetch --quiet --no-tags --no-write-fetch-head --refmap= origin "refs/heads/$branch" 2>/dev/null \
    || refuse "origin has no branch $branch, or fetch failed (network failure or ${NM_TIMEOUT}s timeout)"
  fetched=$(g rev-parse -q --verify "$pub^{commit}" 2>/dev/null)
  now=$(advertised) || refuse "could not re-read origin $branch (network failure or ${NM_TIMEOUT}s timeout)"
  [ "$now" = "$pub" ] || refuse "origin $branch moved from ${pub:-nothing} to ${now:-nothing} during the fetch"
else
  network_git fetch --quiet --no-tags origin "+refs/heads/$branch:refs/remotes/origin/$branch" 2>/dev/null \
    || refuse "origin has no branch $branch, or fetch failed (network failure or ${NM_TIMEOUT}s timeout)"
  fetched=$(g rev-parse -q --verify "refs/remotes/origin/$branch^{commit}")
  pub=$(advertised) || refuse "could not read origin $branch (network failure or ${NM_TIMEOUT}s timeout)"
fi
[ "$pub" = "$fetched" ] || refuse "origin advertises $branch at $pub but the fetch produced ${fetched:-nothing}"

local_head=$(g rev-parse -q --verify "refs/heads/$branch^{commit}")
if [ -z "$cur" ]; then
  detached_head=$(g rev-parse --verify HEAD) || refuse "could not capture detached HEAD"
  # Both tips may contain different parts of the detached history.
  if [ -n "$local_head" ]; then
    uncontained=$(g rev-list "$detached_head" --not "$local_head" "$pub")
  else
    uncontained=$(g rev-list "$detached_head" --not "$pub")
  fi
  [ -z "$uncontained" ] || refuse "detached HEAD $detached_head contains commits absent from $branch and the published head; HEAD is unchanged"
fi
if [ -z "$cur" ] && [ "$check_mode" -eq 0 ]; then
  clean || refuse "detached worktree has local changes; cannot switch to $branch"
  if [ -n "$local_head" ]; then
    g switch -q "$branch" || refuse "could not switch the detached worktree to $branch"
    say "switched the detached worktree to $branch"
  else
    g switch -q -c "$branch" "$pub" || refuse "could not create $branch at $pub"
    local_head=$pub
    note_change "created local branch $branch at $pub"
    say "created local branch $branch at the published head $pub"
  fi
fi

# --- b: classify --------------------------------------------------------------------
if [ -z "$local_head" ]; then rel=create action=create
elif [ "$local_head" = "$pub" ]; then rel=equal action=none
elif g merge-base --is-ancestor "$local_head" "$pub"; then rel=behind action=advance
elif g merge-base --is-ancestor "$pub" "$local_head"; then rel=ahead action=none
else rel=diverged action=archive-advance
fi
result=planned:$action

gate=0
g remote get-url no-mistakes >/dev/null 2>&1 && gate=1
if [ "$gate" -eq 1 ]; then
  nm_check
  [ "$v_code" != continue_active_run ] || monitoring_only "$result"
  handled || unsettled
fi
[ "$check_mode" -eq 0 ] || finish 0 "$result" none

# --- c/d: move --------------------------------------------------------------------
case "$rel" in
  equal) result=equal ;;
  ahead) result=ahead:$(g rev-list --count "$pub..$local_head") ;;
  behind|diverged)
    clean || refuse "worktree has local changes and $branch must move to the published head $pub"
    if [ "$gate" -eq 1 ]; then
      nm_check
      [ "$v_code" != continue_active_run ] || monitoring_only "$result"
      handled || unsettled
    fi
    now=$(advertised) || refuse "could not re-read origin $branch before the advance (network failure or ${NM_TIMEOUT}s timeout)"
    [ "$now" = "$pub" ] || refuse "origin $branch moved from $pub before the advance"
    [ "$rel" = behind ] || make_archive pre-rebase "$local_head"
    g update-ref "refs/heads/$branch" "$pub" "$local_head" \
      || refuse "branch $branch changed after classification; conditional advance from $local_head refused"
    note_change "advanced $branch from $local_head to $pub"
    g read-tree -m -u "$local_head" "$pub" || refuse "keep-style index/worktree update to $pub failed after the conditional advance"
    [ "$(g rev-parse "refs/heads/$branch")" = "$pub" ] \
      || refuse "branch $branch changed after the conditional advance; the concurrent head is preserved"
    if [ "$rel" = behind ]; then result=advanced; else result=archived-advanced; fi
    now=$(advertised) || refuse "could not re-read origin $branch (network failure or ${NM_TIMEOUT}s timeout)"
    [ "$now" = "$pub" ] || refuse "origin $branch moved to ${now:-nothing} after the advance; $branch stays at the previously verified published head $pub"
    ;;
esac

# --- e: custody ---------------------------------------------------------------------
[ "$gate" -eq 1 ] || finish 0 "$result" none
nm_check
[ "$v_safety" != blocked_recover_manual_reconciliation ] || bind_pipeline_head
settled && finish 0 "$result" settled
[ "$v_code" != continue_active_run ] || monitoring_only "$result"
case "$v_code:$v_cmd" in
  "recover_custody:no-mistakes axi sync --recover") run_fixed axi sync --recover ;;
  "recover_custody:no-mistakes axi sync --recover --keep-local")
    keep_local_proven || { printf '%s\n' "$v_out"; refuse "keep-local recovery offered without a verified bound archive of this task at the local head"; }
    run_fixed axi sync --recover --keep-local ;;
  "adopt_published:no-mistakes axi sync --adopt-published") run_fixed axi sync --adopt-published ;;
  *) unsettled ;;
esac
nm_check
settled && finish 0 "$result" settled
unsettled
