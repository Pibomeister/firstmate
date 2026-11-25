#!/usr/bin/env bash
# fm-self-land.sh - guarded self-landing of a task's approved pull request.
#
# A lane owner lands its own approved pull request through this wrapper, so a
# quiet supervisor does not hold finished work. The wrapper adds refusals and a
# durable record around bin/fm-pr-merge.sh. It sends a merge only through that
# script, which is unchanged and still applies every gate of its own.
#
# Usage:
#   fm-self-land.sh <task-id> <pr-url> --head <full-sha>
#   fm-self-land.sh covers <pr-url>
#   fm-self-land.sh -h | --help
#
# <pr-url> is the canonical full GitHub pull request URL, and --head is the
# exact commit the merge review approved. The landing form takes no other
# option: there is no waiver flag, no merge method, and no argument that
# reaches the forge.
#
# `covers` exits 0 when config/self-land names the pull request's repository,
# 1 when it does not or the file is absent, and 2 when the file or the URL
# cannot be read.
#
# A landing run refuses, before any forge write, when one of these is true:
#   stop-file       state/.self-land-off exists. Create it to stop every
#                   self-landing in this home; remove it to resume.
#   config          config/self-land is absent (self-landing is off) or cannot
#                   be trusted. docs/configuration.md owns its schema.
#   not-allowlisted no allow line names the repository. Only GitHub
#                   repositories can be named.
#   in-flight       another self-landing run holds this repository, or a
#                   merge it sent has no outcome yet, or the forge holds that
#                   merge (merge queue or armed auto-merge), or the merge
#                   command an earlier run sent still runs.
#   pending         a pending record exists that cannot be read, settled, or
#                   written.
#   breaker         the circuit breaker record for the repository exists.
#   red-base        the head of the pull request's base branch, or of the
#                   repository's default branch, has a failed check or status.
#                   This run also writes the breaker record.
#   pending-base    the head of the pull request's base branch has a check run
#                   that has not completed or a commit status in state pending,
#                   and no failed check. This keeps landings from stacking ahead
#                   of the branch's checks. The run writes no record, and the
#                   same command can be run again when the checks finish.
#   hold            the task is held for the captain, or another task of
#                   this home whose record names the pull request is held, or
#                   a hold cannot be read.
#   evidence        config/merge-review does not require a review for the
#                   repository, or no approved two-model review exists at
#                   --head (bin/fm-merge-review.sh owns that verdict). In front
#                   of the merge command the review must also name the merge
#                   base of the diff that was checked.
#   task            the task has no record in this home, or its away-posture
#                   record cannot be read.
#   forge-read      the pull request, its file list, or a branch could not be
#                   read completely, the pull request is not open at --head,
#                   or its base, head, or file count changed after its diff
#                   was checked, or the default branch changed, or a checked
#                   branch moved to another commit while its health was read.
#                   The file list is the forge's comparison of the base commit
#                   with --head, which lists at most 300 files, so a larger
#                   diff always refuses here.
#   protected-path  the diff adds, changes, renames, or removes a protected
#                   path: .github/workflows/, a merge gate script, a library a
#                   gate loads directly or through another library, or the
#                   poll script the pull request check publishes. The list is
#                   fixed in this script. Such a change needs the supervisor's
#                   merge.
#   deferred-merge  the base branch requires a merge queue, or the pull request
#                   is already queued or has auto-merge armed.
#
# The forge gate. bin/fm-pr-merge.sh can wait a long time before it sends the
# merge: for the task's lock, and for the forge to compute mergeability. The
# wrapper therefore runs that script with a private `gh` in front of the real
# one. Every call passes through unchanged except the merge command. In front
# of it the wrapper repeats its checks, forge reads first and local reads last:
# the health of the default branch and of the base branch, then the pull
# request, which must still be open at --head with the base and the file count
# the diff check saw. That one answer also names the default branch and the
# heads of both branches, which must be the branches and the commits whose
# health was just read. Then come the holds, the review at --head for the
# merge base of the checked diff, config/self-land, the stop file, and the
# breaker. No forge read comes after the local reads. The pending record is
# then marked as sent and names the process that sends the merge command. A
# refusal there stops the merge command itself, so no merge is sent.
#
# The forge host. Every forge read, and the merge command, addresses the host
# the pull request URL names. A GH_HOST value from the caller's environment is
# replaced, so it cannot point the run at another host that has a repository
# of the same name.
#
# A failed check is a completed check run that concluded failure, timed_out,
# startup_failure, or action_required, or a commit status in state failure or
# error. A failed check run does not count when a run of the same name on the
# same commit concluded success, neutral, or skipped and started later; both
# runs must report a whole-second UTC start time. A check run with no name is
# never replaced by another. A commit status is never replaced, every page of
# statuses is read, and a combined status of failure is red even when no
# listed status explains it. A check that still runs is not red: on the base
# branch it refuses the landing (pending-base) without tripping the breaker, and
# on the default branch it is ignored. A branch with no checks and no statuses
# is not red and does not refuse.
#
# Records, under state/self-land/<provider>/<host>/<owner>/<repository>/:
#   lock        one self-landing run per repository at a time. A second run
#               refuses at once instead of waiting.
#   pending     written before bin/fm-pr-merge.sh starts and removed when the
#               outcome of its merge is known and recorded
#               (bin/fm-merge-authority-lib.sh owns the format and states).
#   breaker     written when a checked branch head is red, when a merge
#               landed on another base branch or base commit than the one its
#               diff was checked against, when a pull request this home sent a
#               merge for merged at another head or is held by the forge at
#               another head, or when a merge was accepted that did not pass
#               the forge gate. This wrapper never removes it. After the
#               branch is green again, or the merge was reviewed by hand, the
#               supervisor or the owner removes the file by hand.
#   .gate.*     the private directory of one run that holds the forge gate. The
#               run removes it when it ends. A run that was killed can leave
#               one behind; remove it by hand only when no merge gate of that
#               run is still alive.
#
# Lost forge response. After the merge attempt, and at the start of every later
# run that finds a pending record, the wrapper reads the pull request back.
#   - Merged at the recorded head: the wrapper records the outcome for
#     supervision (bin/fm-merge-outcome-lib.sh, which records one outcome only
#     once), removes the pending record, and sends no merge.
#     When the outcome cannot be written, the pending
#     record stays and the same command completes the record later. When the
#     pull request reads back with another base branch or base commit than the
#     pending record names, the wrapper also trips the breaker.
#   - Merged at another head: the forge landed a head no review approved. The
#     wrapper trips the breaker, reports it, and removes the pending record.
#   - Unreadable: the pending record stays and the same command settles it.
#   - Held by the forge, which is a pull request in the merge queue or with
#     auto-merge armed: the pending record stays, with no time limit, and
#     every landing in the repository refuses until the pull request merges
#     or the forge no longer holds it. When the pull request is no longer at
#     the recorded head, the wrapper also trips the breaker and reports it.
#   - Unmerged and not held after a merge command was sent: the forge may
#     still apply it, so the pending record stays for as long as the process
#     that sends the command still runs, and for 120 seconds after that. The
#     120 seconds start when the run sees its merge command end, or when a
#     later run first finds that process ended, or when the forge was last
#     seen to hold the merge. After that the forge did not accept the merge
#     and a later run drops the record.
#   - No merge command was sent (the merge gate or the forge gate refused):
#     the pending record is removed at once.
#
# Limits. Every record is local to this home, so the guards cover one home.
# One lane owner per repository is what makes them cover the repository. The
# forge gate ends its checks before the merge command starts, and the forge
# binds a merge only to the head commit. A change after the gate's last read
# of a value is therefore not prevented: a branch that turns red, a hold, or a
# stop file that arrives in that window does not stop the merge. A change of
# the base branch in that window is detected after the merge; the wrapper
# trips the breaker and reports it. The breaker reads branch heads only when a
# landing is attempted, and a branch that is neither the pull request's base
# nor the default branch is not read.
#
# A merge the forge holds is not a landing and returns a refusal. The wrapper
# refuses known queue requirements and pre-armed auto-merge before sending a
# merge command. If the forge nevertheless defers it, the pending record stays
# and prevents another merge command while the forge holds the first. A push
# during that time can still land a head no review approved. A later run
# detects that change, trips the breaker, and reports it; a person then takes
# the pull request out of the queue or disables its auto-merge at the forge.
#
# Exit status: 0 when the pull request landed or was reconciled as landed;
# 1 on a refusal, a deferred merge, or an unknown
# outcome; 2 on an invalid request; 3 when the pull request landed but its
# record, which includes the outcome for supervision, could not
# be completed. A merge that bin/fm-pr-merge.sh refuses exits with that
# script's status.
set -u
set -o pipefail

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SL_CONFIG="$FM_HOME/config/self-land"
SL_STOP_FILE="$STATE/.self-land-off"
# Seconds an unmerged, unqueued pull request keeps its pending record after a
# merge command was sent for it.
SL_GRACE=120

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-merge-outcome-lib.sh
. "$SCRIPT_DIR/fm-merge-outcome-lib.sh"
# shellcheck source=bin/fm-merge-authority-lib.sh
. "$SCRIPT_DIR/fm-merge-authority-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

# The merge gates: the entry points that decide a merge, every library one of
# them loads directly or through another library, and the poll script the pull
# request check publishes. A diff that touches one could weaken the gate that
# lands it. Entries are lowercase; an entry that ends in / covers a directory.
SL_PROTECT='.github/workflows/
bin/fm-self-land.sh
bin/fm-pr-merge.sh
bin/fm-pr-check.sh
bin/fm-pr-poll.sh
bin/fm-merge-local.sh
bin/fm-merge-review.sh
bin/fm-review-diff.sh
bin/fm-captain-hold.sh
bin/fm-afk-contract.sh
bin/fm-backlog-transition-lib.sh
bin/fm-bash-compat-lib.sh
bin/fm-brief-heading-lib.sh
bin/fm-classify-lib.sh
bin/fm-clock-lib.sh
bin/fm-cursor-lib.sh
bin/fm-dod-lib.sh
bin/fm-external-review-lib.sh
bin/fm-hold-reason-lib.sh
bin/fm-lease-lib.sh
bin/fm-merge-authority-lib.sh
bin/fm-merge-outcome-lib.sh
bin/fm-nm-run-lib.sh
bin/fm-parent-channel-lib.sh
bin/fm-path-lib.sh
bin/fm-pr-lib.sh
bin/fm-secondmate-parent-lib.sh
bin/fm-session-lock-lib.sh
bin/fm-supervision-engine-lib.sh
bin/fm-tasks-axi-lib.sh
bin/fm-timeout-lib.sh
bin/fm-wake-ledger-lib.sh
bin/fm-wake-lib.sh'

SL_LOCK=
SL_REPO_DIR=
SL_GATE_DIR=
# The forge client. The forge gate runs behind the private `gh`, so it names
# the real one by its path.
SL_GH=gh
# Appended to a refusal that the forge gate prints.
SL_WHERE=

invalid() {  # <message>
  printf 'error: %s\n' "$1" >&2
  printf 'usage: fm-self-land.sh <task-id> <pr-url> --head <full-sha>\n' >&2
  exit 2
}

refuse() {  # <reason> <message>
  printf 'self-land: refused (%s): %s%s\n' "$1" "$2" "$SL_WHERE" >&2
  exit 1
}

note() {  # <message>
  printf 'self-land: %s\n' "$1" >&2
}

remove_gate() {
  case "$SL_GATE_DIR" in
    "$SL_REPO_DIR"/.gate.*) rm -rf -- "$SL_GATE_DIR" ;;
  esac
  SL_GATE_DIR=
}

# shellcheck disable=SC2329 # Invoked by the EXIT trap.
release_lock() {
  [ -z "$SL_GATE_DIR" ] || remove_gate
  [ -z "$SL_LOCK" ] || fm_lock_release "$SL_LOCK" || true
  SL_LOCK=
}

# Load config/self-land or stop. An absent file is the off position.
load_grant() {
  local rc=0
  fm_self_land_config_load "$SL_CONFIG" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) refuse config "config/self-land is absent, so self-landing is off in this home" ;;
    *) refuse config "$FM_SELF_LAND_ERROR" ;;
  esac
}

case "${1:-}" in
  covers)
    if [ "$#" -eq 2 ]; then
      if ! fm_pr_url_parse "$2"; then
        printf 'error: invalid pull request URL\n' >&2
        exit 2
      fi
      rc=0
      fm_self_land_config_load "$SL_CONFIG" || rc=$?
      case "$rc" in
        0) ;;
        1) exit 1 ;;
        *)
          printf 'error: %s\n' "$FM_SELF_LAND_ERROR" >&2
          exit 2
          ;;
      esac
      [ "$FM_PR_PROVIDER" = github ] || exit 1
      fm_self_land_repo_allowed "$FM_PR_HOST" "$FM_PR_PATH" || exit 1
      exit 0
    fi
    ;;
esac

# The landing form, or the forge gate this script runs in front of its own
# merge command (see prepare_forge_gate; it is not a form for a caller).
SL_MODE=land
SL_RUN=
SL_SCAN_BASE=
SL_SCAN_BASE_SHA=
SL_SCAN_FILES=
SL_SCAN_MERGE_BASE=
SL_DEFAULT_BRANCH=
# The branch heads whose health was read last.
SL_HEALTH_BASE_TIP=
SL_HEALTH_DEFAULT_TIP=
if [ "${1:-}" = __forge-gate ]; then
  [ "$#" -eq 11 ] || invalid "the forge gate is run by a landing, not by a caller"
  SL_MODE=gate
  ID=$2
  HEAD=$4
  SL_RUN=$5
  SL_SCAN_BASE=$6
  SL_SCAN_BASE_SHA=$7
  SL_SCAN_FILES=$8
  SL_SCAN_MERGE_BASE=$9
  SL_DEFAULT_BRANCH=${10}
  SL_GH=${11}
  SL_WHERE=' (read again just before the merge command; no merge was sent)'
  set -- "$ID" "$3"
else
  [ "$#" -eq 4 ] && [ "$3" = --head ] \
    || invalid "a landing needs exactly <task-id> <pr-url> --head <full-sha>; there is no other option and no waiver flag"
  ID=$1
  HEAD=$4
fi
fm_pr_task_id_valid "$ID" || invalid "invalid task id"
fm_pr_url_parse "$2" || invalid "invalid pull request URL"
fm_pr_head_valid "$HEAD" || invalid "--head needs the full lowercase commit id"
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
PR_HOST=$FM_PR_HOST
PR_PATH=$FM_PR_PATH
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
META="$STATE/$ID.meta"

# The switches a person can throw without editing anything else. They are read
# at the start, before the merge gate starts, and in the forge gate.
require_switches_on() {
  if [ -e "$SL_STOP_FILE" ] || [ -L "$SL_STOP_FILE" ]; then
    refuse stop-file "state/.self-land-off exists; remove it to resume self-landing"
  fi
  if [ -n "$SL_REPO_DIR" ] && { [ -e "$SL_REPO_DIR/breaker" ] || [ -L "$SL_REPO_DIR/breaker" ]; }; then
    [ ! -f "$SL_REPO_DIR/breaker" ] || sed 's/^/self-land: breaker: /' "$SL_REPO_DIR/breaker" >&2 || true
    refuse breaker "the circuit breaker for $PR_HOST/$PR_PATH is tripped; after the branch is green again, remove $SL_REPO_DIR/breaker by hand"
  fi
}

require_allowlisted() {
  [ "$PROVIDER" = github ] \
    || refuse not-allowlisted "self-landing supports GitHub pull requests only"
  load_grant
  fm_self_land_repo_allowed "$PR_HOST" "$PR_PATH" \
    || refuse not-allowlisted "config/self-land has no allow line for $PR_HOST/$PR_PATH"
}

require_task_not_held() {  # <task-id> <words that name the task>
  local hold_status=0
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-captain-hold.sh" open "$1" --distinguish-absent >/dev/null || hold_status=$?
  case "$hold_status" in
    0) refuse hold "$2 is still held for the captain" ;;
    1 | 3) return 0 ;;
    *) refuse hold "could not determine whether $2 is still held for the captain" ;;
  esac
}

# Succeed when <recorded-url> names the pull request of this run. The parse
# runs in a subshell, so it does not replace the names this run parsed.
names_this_pull() {  # <recorded-url>
  (
    fm_pr_url_parse "$1" || exit 1
    [ "$FM_PR_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_NUMBER" = "$PR_NUMBER" ] \
      && [ "$(_fm_self_land_lower "$FM_PR_HOST/$FM_PR_PATH")" = "$(_fm_self_land_lower "$PR_HOST/$PR_PATH")" ]
  )
}

# A hold counts under whichever task id the caller names: the named task must
# be free, and so must every task of this home whose record names this pull
# request. The merge gate binds a pull request to a task that names none, so
# the named task alone does not prove that the pull request is free. A task
# record names the pull request of its last `pr=` line, as the merge gate reads
# it.
require_released_hold() {
  local meta id recorded
  require_task_not_held "$ID" "task $ID"
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    [ "$id" != "$ID" ] || continue
    recorded=$(sed -n 's/^pr=//p' "$meta" 2>/dev/null) \
      || refuse hold "could not read the task record $meta, so it is not known whether a held task names $URL"
    recorded=${recorded##*$'\n'}
    # A cheap test first: most records name another pull request or none.
    case "$recorded" in */"$PR_NUMBER") ;; *) continue ;; esac
    names_this_pull "$recorded" || continue
    fm_pr_task_id_valid "$id" \
      || refuse hold "the task record $meta names $URL and has no valid task id, so its hold cannot be read"
    require_task_not_held "$id" "task $id, whose record names $URL,"
  done
}

# Self-landing needs proof, so a repository the merge review does not cover is
# refused here even though bin/fm-pr-merge.sh would merge it unreviewed. A
# review approves one diff, which its head and its merge base name. Once the
# merge base of the checked diff is known, the receipts must name that merge
# base, so a review of the same head against another base proves nothing.
require_review_evidence() {
  local covers_rc=0 check_rc=0 verdict scope=''
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-merge-review.sh" covers "$URL" >/dev/null 2>&1 || covers_rc=$?
  case "$covers_rc" in
    0) ;;
    1) refuse evidence "config/merge-review does not require a review for $PR_HOST/$PR_PATH, so no approval can prove this head" ;;
    *) refuse evidence "config/merge-review could not be read" ;;
  esac
  if [ -n "$SL_SCAN_MERGE_BASE" ]; then
    scope=" for the diff from merge base $SL_SCAN_MERGE_BASE"
    verdict=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-merge-review.sh" check "$URL" \
      --head "$HEAD" --base "$SL_SCAN_MERGE_BASE" 2>&1) || check_rc=$?
  else
    verdict=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-merge-review.sh" check "$URL" --head "$HEAD" 2>&1) || check_rc=$?
  fi
  if [ "$check_rc" -ne 0 ]; then
    [ -z "$verdict" ] || printf '%s\n' "$verdict" >&2
    refuse evidence "no approved two-model review exists for $URL at head $HEAD$scope"
  fi
  case "$verdict" in
    *"merge-review: approved head=$HEAD"*) ;;
    *)
      [ -z "$verdict" ] || printf '%s\n' "$verdict" >&2
      refuse evidence "the merge review did not report an approval at head $HEAD$scope"
      ;;
  esac
}

sl_branch_name_valid() {  # <name>
  [[ "$1" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
  case "$1" in *..* | /* | */) return 1 ;; esac
  return 0
}

SL_PR_STATE=
SL_PR_MERGED=
SL_PR_QUEUED=
SL_PR_HEAD=
SL_PR_BASE=
SL_PR_BASE_SHA=
SL_PR_FILES=
SL_PR_MERGE_COMMIT=
SL_PR_DEFAULT=
SL_PR_AUTO=
SL_PR_BASE_TIP=
SL_PR_DEFAULT_TIP=
# Read one pull request of this repository from the forge, in one answer, so
# its merged state, its merge queue state, its auto-merge state, the default
# branch, and the heads of the base branch and the default branch belong to
# the same moment. A branch head is empty when the forge names none.
# Returns 1 when the read fails or its answer does not have the expected shape.
read_pull() {  # <number>
  local json fields line named=0 total=0
  local state='' merged='' queued='' head='' base='' base_sha='' files='' merge_commit='' default='' auto=''
  local base_tip='' default_tip=''
  SL_PR_STATE=
  SL_PR_MERGED=
  SL_PR_QUEUED=
  SL_PR_HEAD=
  SL_PR_BASE=
  SL_PR_BASE_SHA=
  SL_PR_FILES=
  SL_PR_MERGE_COMMIT=
  SL_PR_DEFAULT=
  SL_PR_AUTO=
  SL_PR_BASE_TIP=
  SL_PR_DEFAULT_TIP=
  # shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
  json=$("$SL_GH" api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){defaultBranchRef{name target{oid}} pullRequest(number:$number){state merged isInMergeQueue headRefOid baseRefName baseRefOid baseRef{target{oid}} changedFiles mergeCommit{oid} autoMergeRequest{enabledAt}}}}' \
    -F "owner=$PR_OWNER" -F "repo=$PR_REPO" -F "number=$1" 2>/dev/null) || return 1
  fields=$(printf '%s' "$json" | jq -r '
    .data.repository as $repo | $repo.pullRequest as $pull
    | "state=" + ($pull.state | strings),
      "merged=" + ($pull.merged | booleans | tostring),
      "queued=" + ($pull.isInMergeQueue | booleans | tostring),
      "head=" + ($pull.headRefOid | strings),
      "base=" + ($pull.baseRefName | strings),
      "base_sha=" + ($pull.baseRefOid | strings),
      "files=" + ($pull.changedFiles | numbers | tostring),
      "merge_commit=" + ($pull.mergeCommit.oid // "" | strings),
      "default=" + ($repo.defaultBranchRef.name | strings),
      "auto=" + (($pull.autoMergeRequest != null) | tostring),
      "base_tip=" + ($pull.baseRef.target.oid // "" | strings),
      "default_tip=" + ($repo.defaultBranchRef.target.oid // "" | strings)
  ' 2>/dev/null) || return 1
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      merged=*) merged=${line#merged=} ;;
      queued=*) queued=${line#queued=} ;;
      head=*) head=${line#head=} ;;
      base=*) base=${line#base=} ;;
      base_sha=*) base_sha=${line#base_sha=} ;;
      files=*) files=${line#files=} ;;
      merge_commit=*) merge_commit=${line#merge_commit=} ;;
      default=*) default=${line#default=} ;;
      auto=*) auto=${line#auto=} ;;
      base_tip=*) base_tip=${line#base_tip=} ;;
      default_tip=*) default_tip=${line#default_tip=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  [ "$named" -eq 12 ] && [ "$total" -eq 12 ] || return 1
  case "$state" in OPEN | CLOSED | MERGED) ;; *) return 1 ;; esac
  case "$merged" in true | false) ;; *) return 1 ;; esac
  case "$queued" in true | false) ;; *) return 1 ;; esac
  case "$auto" in true | false) ;; *) return 1 ;; esac
  fm_pr_head_valid "$head" || return 1
  fm_pr_head_valid "$base_sha" || return 1
  sl_branch_name_valid "$base" || return 1
  sl_branch_name_valid "$default" || return 1
  case "$files" in '' | *[!0-9]*) return 1 ;; esac
  [ -z "$merge_commit" ] || fm_pr_head_valid "$merge_commit" || return 1
  [ -z "$base_tip" ] || fm_pr_head_valid "$base_tip" || return 1
  [ -z "$default_tip" ] || fm_pr_head_valid "$default_tip" || return 1
  SL_PR_STATE=$state
  SL_PR_MERGED=$merged
  SL_PR_QUEUED=$queued
  SL_PR_HEAD=$head
  SL_PR_BASE=$base
  SL_PR_BASE_SHA=$base_sha
  SL_PR_FILES=$files
  SL_PR_MERGE_COMMIT=$merge_commit
  SL_PR_DEFAULT=$default
  SL_PR_AUTO=$auto
  SL_PR_BASE_TIP=$base_tip
  SL_PR_DEFAULT_TIP=$default_tip
}

# Where the forge holds a merge of the pull request last read: prints the
# place, or nothing when the forge holds none. An armed auto-merge is a merge
# the forge applies later by itself, the same as an entry in its merge queue.
forge_hold() {
  if [ "$SL_PR_QUEUED" = true ]; then
    printf '%s\n' "in the forge's merge queue"
  elif [ "$SL_PR_AUTO" = true ]; then
    printf '%s\n' "at the forge with auto-merge armed"
  fi
}

# Refuse unless the head of <branch> in the pull request read is the commit
# whose health was read. A branch that pointed at another commit for a moment
# cannot lend its health.
require_health_of_tip() {  # <kind> <branch> <commit whose health was read> <head in the pull request read>
  fm_pr_head_valid "$3" \
    || refuse forge-read "the health of $1 $2 was not read before the pull request was read again"
  [ -n "$4" ] || refuse forge-read "the forge did not name the head of $1 $2 with the pull request"
  [ "$3" = "$4" ] \
    || refuse forge-read "$1 $2 moved from $3 to $4 while its health was read; run again so the health of its new head is read"
}

# Read the pull request again and refuse unless it is still the one whose diff
# was checked: open, at the approved head, on the same base, with the same
# number of changed files. The head and the base commit name the diff. The
# same answer names the default branch and the heads of the checked branches,
# which must be the branches and the commits whose health was read.
require_checked_pull() {
  local queued held
  queued=$("$SL_GH" api --paginate "repos/$PR_OWNER/$PR_REPO/rules/branches/${SL_SCAN_BASE//\//%2F}" 2>/dev/null \
    | jq -s -r '
      if length > 0 and all(.[]; type == "array" and all(.[]; type == "object" and (.type | type) == "string"))
      then any(.[][]; .type == "merge_queue") else error("shape") end' 2>/dev/null) \
    || refuse forge-read "could not read the merge-queue rules of base branch $SL_SCAN_BASE"
  [ "$queued" = false ] \
    || refuse deferred-merge "base branch $SL_SCAN_BASE requires a merge queue; self-landing requires an immediate merge at the approved head"
  read_pull "$PR_NUMBER" || refuse forge-read "could not read $URL again after its diff was checked"
  if [ "$SL_PR_MERGED" = true ] || [ "$SL_PR_STATE" != OPEN ]; then
    refuse forge-read "$URL is no longer open (state=$SL_PR_STATE, merged=$SL_PR_MERGED)"
  fi
  [ "$SL_PR_HEAD" = "$HEAD" ] \
    || refuse forge-read "$URL moved to head $SL_PR_HEAD, away from the approved head $HEAD"
  held=$(forge_hold)
  [ -z "$held" ] \
    || refuse deferred-merge "$URL waits $held; self-landing requires an immediate merge at the approved head"
  if [ "$SL_PR_BASE" != "$SL_SCAN_BASE" ] || [ "$SL_PR_BASE_SHA" != "$SL_SCAN_BASE_SHA" ] \
    || [ "$SL_PR_FILES" != "$SL_SCAN_FILES" ]; then
    refuse forge-read "$URL changed after its diff was checked (base $SL_SCAN_BASE at $SL_SCAN_BASE_SHA with $SL_SCAN_FILES changed files, now $SL_PR_BASE at $SL_PR_BASE_SHA with $SL_PR_FILES); run again so the new diff is checked"
  fi
  [ "$SL_PR_DEFAULT" = "$SL_DEFAULT_BRANCH" ] \
    || refuse forge-read "the default branch of $PR_HOST/$PR_PATH changed from $SL_DEFAULT_BRANCH to $SL_PR_DEFAULT after its health was read; run again so the health of the new default branch is read"
  require_health_of_tip "base branch" "$SL_SCAN_BASE" "$SL_HEALTH_BASE_TIP" "$SL_PR_BASE_TIP"
  [ "$SL_DEFAULT_BRANCH" = "$SL_SCAN_BASE" ] \
    || require_health_of_tip "default branch" "$SL_DEFAULT_BRANCH" "$SL_HEALTH_DEFAULT_TIP" "$SL_PR_DEFAULT_TIP"
}

# Refuse a diff that touches a protected path. The file list is read for the
# two commits the pull request was read at, not for the pull request number,
# so it is the list of exactly the diff that require_checked_pull confirms
# later; a pull request that pointed at another base for a moment cannot lend
# its list. The whole list must be read: a count that differs from the pull
# request's own count is a refusal, and the forge lists 300 files at most.
# The same answer names the merge base of that diff, which the review must
# name too (require_review_evidence).
require_unprotected_diff() {
  local raw protect result count='' hits='' merge_base=''
  protect=$(printf '%s\n' "$SL_PROTECT" | jq -R . | jq -s -c .) \
    || refuse forge-read "could not prepare the protected path list"
  raw=$("$SL_GH" api "repos/$PR_OWNER/$PR_REPO/compare/$SL_SCAN_BASE_SHA...$HEAD?per_page=1" 2>/dev/null) \
    || refuse forge-read "could not read the file list of $URL between base commit $SL_SCAN_BASE_SHA and head $HEAD"
  result=$(printf '%s' "$raw" | jq -r --arg base "$SL_SCAN_BASE_SHA" --argjson protect "$protect" '
    if .base_commit.sha == $base and (.files | type) == "array" then . else error("shape") end
    | "merge_base=\(.merge_base_commit.sha | strings)",
      ( .files
        | map(if (.filename | type) == "string" then . else error("shape") end)
        | "count=\(length)",
          ( [ .[] | .filename, (.previous_filename | strings) ] | unique | .[]
            | . as $path | ($path | ascii_downcase) as $lower
            | select(any($protect[]; . as $entry
                | if ($entry | endswith("/")) then ($lower | startswith($entry)) else $lower == $entry end))
            | "hit=\($path | @json)" ) )
  ' 2>/dev/null) || refuse forge-read "the file list of $URL did not have the expected shape"
  merge_base=$(printf '%s\n' "$result" | sed -n 's/^merge_base=//p')
  fm_pr_head_valid "$merge_base" \
    || refuse forge-read "the file list of $URL did not name the merge base of base commit $SL_SCAN_BASE_SHA and head $HEAD"
  SL_SCAN_MERGE_BASE=$merge_base
  count=$(printf '%s\n' "$result" | sed -n 's/^count=//p')
  hits=$(printf '%s\n' "$result" | sed -n 's/^hit=//p')
  if [ -z "$count" ] || [ "$count" != "$SL_PR_FILES" ]; then
    refuse forge-read "read ${count:-0} of $SL_PR_FILES changed files of $URL; the file list is incomplete"
  fi
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | sed 's/^/self-land: protected path: /' >&2
    refuse protected-path "$URL touches a protected path; the supervisor must land it"
  fi
}

# Write the breaker record. Returns 1 when it could not be written.
trip_breaker() {  # <branch> <commit> <reason>
  local epoch tmp=''
  epoch=$(date +%s)
  if tmp=$(umask 077 && mktemp "$SL_REPO_DIR/.breaker.XXXXXX") \
    && printf '%s\ntripped=%s\nbranch=%s\nsha=%s\nred=%s\n' \
      fm-self-land-breaker-v1 "$epoch" "$1" "$2" "$3" > "$tmp" \
    && mv -f -- "$tmp" "$SL_REPO_DIR/breaker"; then
    return 0
  fi
  [ -z "$tmp" ] || rm -f -- "$tmp"
  return 1
}

# Trip the breaker when the head of <branch> is red. An unreadable branch is a
# refusal and trips nothing. A branch name holds no character but / that needs
# encoding as one URL path segment (sl_branch_name_valid).
require_green_branch() {  # <branch> <base branch|default branch>
  local branch=$1 kind=$2 sha runs statuses red running
  sha=$("$SL_GH" api "repos/$PR_OWNER/$PR_REPO/branches/${branch//\//%2F}" 2>/dev/null \
    | jq -r '.commit.sha | strings' 2>/dev/null) \
    || refuse forge-read "could not read the head of $kind $branch"
  fm_pr_head_valid "$sha" || refuse forge-read "could not read the head of $kind $branch"
  case "$kind" in
    "base branch") SL_HEALTH_BASE_TIP=$sha ;;
    *) SL_HEALTH_DEFAULT_TIP=$sha ;;
  esac
  runs=$("$SL_GH" api --paginate "repos/$PR_OWNER/$PR_REPO/commits/$sha/check-runs?per_page=100" 2>/dev/null \
    | jq -s -r '
      def settled_at:
        if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
        then . else null end;
      [ .[] | .check_runs | if type == "array" then .[] else error("shape") end ] as $all
      | ( [ $all[] | select(.status != "completed")
            | if (.name | type) == "string" and (.name | length) > 0 then .name else "(unnamed check)" end ]
          | unique | .[] | "P " + . ),
        ( $all
      | [ to_entries[]
          | .key as $i
          | .value
          | select(.status == "completed")
          | {
              name: (if (.name | type) == "string" then .name else "" end),
              red: (.conclusion == "failure" or .conclusion == "timed_out"
                or .conclusion == "startup_failure" or .conclusion == "action_required"),
              green: (.conclusion == "success" or .conclusion == "neutral" or .conclusion == "skipped"),
              at: (.started_at | settled_at)
            }
          | . + {group: (if .name == "" then ["", $i] else [.name, -1] end)} ]
      | [ group_by(.group)[]
          | ([.[] | select(.green) | .at | select(. != null)] | max) as $newest_green
          | select(any(.[]; .red and ($newest_green == null or .at == null or .at >= $newest_green)))
          | if .[0].name == "" then "(unnamed check)" else .[0].name end ]
      | unique | .[] | "R " + . )' 2>/dev/null) \
    || refuse forge-read "could not read the checks of $kind $branch at $sha"
  # Every page repeats the combined state and carries its own slice of the
  # statuses, so the pages are read together.
  statuses=$("$SL_GH" api --paginate "repos/$PR_OWNER/$PR_REPO/commits/$sha/status?per_page=100" 2>/dev/null \
    | jq -s -r '
      if length == 0 then error("shape") else . end
      | map(if type == "object" and (.state | type) == "string" and ((.statuses // []) | type) == "array"
            then . else error("shape") end)
      | ( [ .[] | (.statuses // [])[] | select(.state == "pending")
            | if (.context | type) == "string" and (.context | length) > 0 then .context else "(unnamed status)" end ]
          | unique | .[] | "P " + . ),
        ( ( [ .[] | (.statuses // [])[] | select(.state == "failure" or .state == "error")
              | if (.context | type) == "string" and (.context | length) > 0 then .context else "(unnamed status)" end ]
            | unique ) as $named
          | if ($named | length) > 0 then $named[]
            elif any(.[]; .state == "failure" or .state == "error") then "(combined status)"
            else empty end
          | "R " + . )' 2>/dev/null) \
    || refuse forge-read "could not read the statuses of $kind $branch at $sha"
  red=$(printf '%s\n%s\n' "$runs" "$statuses" | sed -n 's/^R //p' | tr '\n' ',' | sed 's/,$//; s/,/, /g')
  if [ -z "$red" ]; then
    [ "$kind" = "base branch" ] || return 0
    running=$(printf '%s\n%s\n' "$runs" "$statuses" | sed -n 's/^P //p' | tr '\n' ',' | sed 's/,$//; s/,/, /g')
    [ -n "$running" ] || return 0
    refuse pending-base "$kind $branch at $sha has checks that have not finished ($running); no merge was sent, and the same command can be run again when they finish"
  fi
  trip_breaker "$branch" "$sha" "$red" \
    || refuse red-base "$kind $branch is red at $sha ($red) and the breaker record could not be written"
  refuse red-base "$kind $branch is red at $sha ($red); the circuit breaker is now tripped at $SL_REPO_DIR/breaker"
}

# Read the health of the default branch, then of the base branch. The default
# branch comes first, so a base branch whose checks still run does not end the
# run before a red default branch trips the breaker. require_checked_pull
# follows every call and binds the commits read here to the pull request read.
require_green_branches() {
  SL_HEALTH_BASE_TIP=
  SL_HEALTH_DEFAULT_TIP=
  [ "$SL_DEFAULT_BRANCH" = "$SL_SCAN_BASE" ] || require_green_branch "$SL_DEFAULT_BRANCH" "default branch"
  require_green_branch "$SL_SCAN_BASE" "base branch"
}

# Record a merge this home sent. The outcome is reported for
# every landing: the outcome owner records one merge only once, so the report
# is a no-op after bin/fm-pr-merge.sh recorded it, and it is the record when
# that script could not write it and still exited 0. Returns 1 when the record
# is not complete, so the caller keeps the pending record and a later run
# completes it.
record_landed() {  # <task-id> <pr-url> <authority>
  local outcome_rc=0
  fm_merge_outcome_report "$FM_HOME" "$STATE" "$1" "$2" self "$3" || outcome_rc=$?
  case "$outcome_rc" in
    0) ;;
    3)
      printf 'actionable: merged %s but could not report it upward: this home has no readable secondmate identity or parent binding\n' "$2" >&2
      return 1
      ;;
    *)
      printf 'actionable: merged %s but could not record the outcome for supervision\n' "$2" >&2
      return 1
      ;;
  esac
  return 0
}

# Stop after a merge landed whose record is not complete. The pending record
# stays, so the same command completes the record and sends no merge.
stop_unrecorded() {  # <pr-url> <head> <merge-commit>
  printf 'self-land: landed %s head=%s merge=%s, but its record is not complete; the pending record is kept, and running the same command again completes it without a second merge\n' \
    "$1" "$2" "${3:--}" >&2
  exit 3
}

# Trip the breaker and report it. The breaker stops every later landing.
trip_and_report() {  # <branch> <commit> <reason for the record> <report>
  trip_breaker "$1" "$2" "$3" \
    || printf 'actionable: could not write the breaker record at %s\n' "$SL_REPO_DIR/breaker" >&2
  printf 'actionable: %s; the circuit breaker is tripped, and the merge needs a review by hand\n' "$4" >&2
}

# The pull request read is merged. Trip the breaker when it landed on another
# base than the one its diff was checked against. The forge names the base
# branch and the base commit of a merged pull request as they were when it
# merged, so either one differs after a change of the base.
require_merged_on_checked_base() {  # <pr-url> <checked base> <checked base commit>
  [ "$SL_PR_BASE" != "$2" ] || [ "$SL_PR_BASE_SHA" != "$3" ] || return 0
  trip_and_report "$SL_PR_BASE" "${SL_PR_MERGE_COMMIT:--}" \
    "merged into $SL_PR_BASE at base commit $SL_PR_BASE_SHA, but its diff was checked against $2 at $3" \
    "$1 merged into $SL_PR_BASE at base commit $SL_PR_BASE_SHA, but its diff was checked against $2 at $3; the base changed between the last read and the merge"
}

# The pull request read is merged, and not at the head this home sent a merge
# for. A forge that held the merge can land a later head, which no review
# approved.
report_merged_at_other_head() {  # <pr-url> <head the merge was sent for>
  trip_and_report "$SL_PR_BASE" "${SL_PR_MERGE_COMMIT:--}" \
    "merged at head $SL_PR_HEAD, but the merge was sent for the approved head $2" \
    "$1 merged at head $SL_PR_HEAD, but this home sent its merge for the approved head $2; no review covers the head that landed"
}

# The forge holds the merge of the pull request read. Trip the breaker when its
# head is no longer the head the merge was sent for: the forge can land that
# head, which no review approved. This wrapper sends the forge no command that
# takes the merge back.
require_held_at_sent_head() {  # <pr-url> <head the merge was sent for>
  [ "$SL_PR_HEAD" != "$2" ] || return 0
  trip_and_report "$SL_PR_BASE" "$SL_PR_HEAD" \
    "the forge holds a merge sent for head $2, and the pull request is now at head $SL_PR_HEAD" \
    "the forge still holds the merge of $1, which this home sent for the approved head $2, and the pull request is now at head $SL_PR_HEAD, which no review approved; take the pull request out of the merge queue or disable its auto-merge at the forge by hand"
}

# Settle a pending record left by an earlier run before anything new starts.
# Returns only when no pending record remains and this run may continue.
settle_pending() {
  local rc=0 p_id p_url p_head p_authority p_epoch p_state p_run p_sender p_base p_base_sha p_number now age held
  fm_self_land_pending_read "$SL_REPO_DIR" || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    *) refuse pending "$SL_REPO_DIR/pending cannot be read; confirm the pull request it names, then remove it by hand" ;;
  esac
  p_id=$FM_SELF_LAND_PENDING_ID
  p_url=$FM_SELF_LAND_PENDING_URL
  p_head=$FM_SELF_LAND_PENDING_HEAD
  p_authority=$FM_SELF_LAND_PENDING_AUTHORITY
  p_epoch=$FM_SELF_LAND_PENDING_EPOCH
  p_state=$FM_SELF_LAND_PENDING_STATE
  p_run=$FM_SELF_LAND_PENDING_RUN
  p_sender=$FM_SELF_LAND_PENDING_SENDER
  p_base=$FM_SELF_LAND_PENDING_BASE
  p_base_sha=$FM_SELF_LAND_PENDING_BASE_SHA
  if [ "$p_state" = armed ]; then
    # The run that wrote it no longer holds the repository, and it sent no
    # merge. Its merge gate may still be alive: the forge gate of that run
    # then finds no armed record of its own and refuses.
    rc=0
    fm_self_land_pending_change "$SL_REPO_DIR" "$p_run" armed none || rc=$?
    case "$rc" in
      0)
        note "dropped the pending record for $p_url: its run ended before a merge was sent"
        return 0
        ;;
      1) refuse in-flight "the pending record for $p_url changed while it was settled: an earlier run is sending its merge; retry shortly" ;;
      *) refuse pending "could not lock or remove $SL_REPO_DIR/pending" ;;
    esac
  fi
  if ! fm_pr_url_parse "$p_url" || [ "$FM_PR_PROVIDER" != "$PROVIDER" ] \
    || [ "$(_fm_self_land_lower "$FM_PR_HOST/$FM_PR_PATH")" != "$(_fm_self_land_lower "$PR_HOST/$PR_PATH")" ]; then
    refuse pending "$SL_REPO_DIR/pending names another repository; confirm it, then remove it by hand"
  fi
  p_url=$FM_PR_URL
  p_number=$FM_PR_NUMBER
  read_pull "$p_number" \
    || refuse forge-read "could not read $p_url to settle its pending merge; the pending record is kept and no merge was sent"
  if [ "$SL_PR_MERGED" = true ]; then
    if [ "$SL_PR_HEAD" = "$p_head" ]; then
      # Before the record, so a record that cannot be completed does not skip it.
      require_merged_on_checked_base "$p_url" "$p_base" "$p_base_sha"
      record_landed "$p_id" "$p_url" "$p_authority" \
        || stop_unrecorded "$p_url" "$p_head" "$SL_PR_MERGE_COMMIT"
      fm_self_land_pending_clear "$SL_REPO_DIR"
      note "reconciled $p_url as landed at head $p_head; no second merge was sent"
      if [ "$p_number" = "$PR_NUMBER" ]; then
        if [ "$p_head" = "$HEAD" ]; then
          printf 'self-land: landed %s head=%s merge=%s (reconciled)\n' "$URL" "$HEAD" "${SL_PR_MERGE_COMMIT:--}"
          exit 0
        fi
        refuse forge-read "$URL is already merged at head $p_head, not at $HEAD"
      fi
      return 0
    fi
    # The breaker record now carries what the pending record told.
    report_merged_at_other_head "$p_url" "$p_head"
    fm_self_land_pending_clear "$SL_REPO_DIR"
    note "dropped the pending record for $p_url: it merged at head $SL_PR_HEAD, not the recorded $p_head"
    return 0
  fi
  held=$(forge_hold)
  if [ -n "$held" ]; then
    require_held_at_sent_head "$p_url" "$p_head"
    if [ "$p_state" != queued ]; then
      fm_self_land_pending_change "$SL_REPO_DIR" "$p_run" "$p_state" queued \
        || refuse pending "could not mark $SL_REPO_DIR/pending as held by the forge"
    fi
    refuse in-flight "the merge for $p_url waits $held; nothing else lands in $PR_HOST/$PR_PATH until it merges or the forge no longer holds it"
  fi
  if [ "$p_state" = queued ]; then
    # The forge stopped holding it, unmerged, in this read. The forge may still
    # be closing the merge, so the clock of the unmerged case starts now. The
    # command that sent it ended before the forge was seen to hold the merge.
    fm_self_land_pending_change "$SL_REPO_DIR" "$p_run" queued sent - \
      || refuse pending "could not update $SL_REPO_DIR/pending"
    refuse in-flight "the forge no longer holds the merge for $p_url, and it is not merged yet; retry after ${SL_GRACE}s"
  fi
  now=$(date +%s)
  age=$((now - p_epoch))
  if [ "$p_sender" != - ]; then
    # The record still names the process that sends the merge command, so the
    # run that started it did not see it end. Age does not end a command that
    # still runs: it can still reach the forge.
    if fm_self_land_sender_alive "$p_sender"; then
      refuse in-flight "the merge command sent for $p_url ${age}s ago still runs as process ${p_sender%% *}; nothing else lands in $PR_HOST/$PR_PATH until it ends"
    fi
    # It ended at a time nobody recorded, and it can have sent its request in
    # its last moment. The clock starts now, when it is first seen ended.
    fm_self_land_pending_change "$SL_REPO_DIR" "$p_run" sent sent - \
      || refuse pending "could not update $SL_REPO_DIR/pending"
    refuse in-flight "the merge command sent for $p_url ended, and it is not merged yet; retry after ${SL_GRACE}s"
  fi
  # The clock of this record started when its merge command was known ended.
  if [ "$age" -lt "$SL_GRACE" ]; then
    refuse in-flight "the merge command for $p_url ended ${age}s ago and has no outcome yet; retry after ${SL_GRACE}s"
  fi
  fm_self_land_pending_clear "$SL_REPO_DIR"
  note "dropped the pending record for $p_url: the forge did not accept the merge whose command ended ${age}s ago"
}

# Build the private `gh` that bin/fm-pr-merge.sh finds first on its PATH. It
# runs this script's forge gate in front of the merge command and passes every
# other call to the real gh unchanged. The directory lives for one run.
prepare_forge_gate() {
  local real gate_cmd='' part
  real=$(command -v gh) || return 1
  case "$real" in /*) ;; *) return 1 ;; esac
  # The directory goes on a PATH, where a colon would split it.
  case "$SL_REPO_DIR" in *:*) return 1 ;; esac
  SL_GATE_DIR=$(umask 077 && mktemp -d "$SL_REPO_DIR/.gate.XXXXXX") || return 1
  for part in "$SCRIPT_DIR/fm-self-land.sh" __forge-gate "$ID" "$URL" "$HEAD" "$SL_RUN" \
    "$SL_SCAN_BASE" "$SL_SCAN_BASE_SHA" "$SL_SCAN_FILES" "$SL_SCAN_MERGE_BASE" "$SL_DEFAULT_BRANCH" "$real"; do
    gate_cmd="$gate_cmd $(printf '%q' "$part")"
  done
  {
    printf '#!/usr/bin/env bash\n'
    printf '# Written by bin/fm-self-land.sh for one landing run.\n'
    # shellcheck disable=SC2016 # The private gh expands these when it runs.
    printf 'if [ "${1-}" = pr ] && [ "${2-}" = merge ]; then\n'
    printf '  FM_HOME=%q FM_STATE_OVERRIDE=%q%s || { : > %q; exit 1; }\n' \
      "$FM_HOME" "$STATE" "$gate_cmd" "$SL_GATE_DIR/refused"
    printf 'fi\n'
    # shellcheck disable=SC2016 # The private gh expands this when it runs.
    printf 'exec %q "$@"\n' "$real"
  } > "$SL_GATE_DIR/gh" || return 1
  chmod 0700 "$SL_GATE_DIR/gh"
}

SL_REPO_DIR=$(fm_self_land_repo_dir "$STATE" "$PROVIDER" "$PR_HOST" "$PR_PATH") \
  || refuse config "could not name the record directory for $PR_HOST/$PR_PATH"
# The run addresses the host the URL names, whatever the caller exported.
GH_HOST=$PR_HOST
export GH_HOST

# --- The forge gate: the last checks, in front of the merge command ----------

if [ "$SL_MODE" = gate ]; then
  case "$SL_GH" in /*) ;; *) invalid "the forge gate needs the path of the real gh" ;; esac
  if ! fm_pr_head_valid "$SL_SCAN_BASE_SHA" || ! sl_branch_name_valid "$SL_SCAN_BASE"; then
    invalid "the forge gate needs the base its landing checked"
  fi
  case "$SL_SCAN_FILES" in '' | *[!0-9]*) invalid "the forge gate needs the file count its landing checked" ;; esac
  fm_pr_head_valid "$SL_SCAN_MERGE_BASE" || invalid "the forge gate needs the merge base of the diff its landing checked"
  sl_branch_name_valid "$SL_DEFAULT_BRANCH" || invalid "the forge gate needs the default branch its landing read"
  # The forge reads come first and the pull request is the last of them. The
  # reads of this home follow, so a stop file, a breaker, a removed grant, a
  # hold, or a removed review requirement that appeared during a forge read
  # still stops the merge command.
  require_green_branches
  require_checked_pull
  require_released_hold
  require_review_evidence
  require_allowlisted
  require_switches_on
  # Last, so the record says sent only when the merge command follows. The
  # caller of this gate is the private gh, which becomes the merge command. A
  # sent record with no sender means that its command ended, so a sender that
  # cannot be named stops the merge.
  sender=$(fm_self_land_sender_of "$PPID")
  [ "$sender" != - ] \
    || refuse pending "the process that sends the merge command could not be named, so its merge is not sent"
  fm_self_land_pending_change "$SL_REPO_DIR" "$SL_RUN" armed sent "$sender" \
    || refuse pending "the pending record of this run is gone or changed, so its merge is not sent"
  exit 0
fi

# --- Gates that need no forge and no lock ------------------------------------

require_switches_on
require_allowlisted
[ -f "$META" ] || refuse task "task $ID has no record in this home"
if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  refuse forge-read "self-landing needs gh and jq"
fi
(umask 077 && mkdir -p -- "$SL_REPO_DIR") \
  || refuse config "could not create $SL_REPO_DIR"

# --- One self-landing run per repository -------------------------------------

trap release_lock EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 131' QUIT
trap 'exit 143' TERM
if ! fm_lock_try_acquire "$SL_REPO_DIR/lock"; then
  refuse in-flight "another self-landing run holds $PR_HOST/$PR_PATH; one merge at a time"
fi
SL_LOCK="$SL_REPO_DIR/lock"

settle_pending
require_switches_on
require_released_hold
require_review_evidence
if ! fm_merge_authority_resolve "$FM_HOME" "$STATE" "$META" "$ID"; then
  refuse task "the away-posture record could not be read"
fi
AUTHORITY=$FM_MERGE_AUTHORITY

# --- Gates read from the forge -----------------------------------------------

read_pull "$PR_NUMBER" || refuse forge-read "could not read $URL"
if [ "$SL_PR_MERGED" = true ] || [ "$SL_PR_STATE" != OPEN ]; then
  refuse forge-read "$URL is not open (state=$SL_PR_STATE, merged=$SL_PR_MERGED); nothing to land"
fi
[ "$SL_PR_HEAD" = "$HEAD" ] \
  || refuse forge-read "$URL is at head $SL_PR_HEAD, not the approved head $HEAD"
SL_SCAN_BASE=$SL_PR_BASE
SL_SCAN_BASE_SHA=$SL_PR_BASE_SHA
SL_SCAN_FILES=$SL_PR_FILES
SL_DEFAULT_BRANCH=$SL_PR_DEFAULT
require_unprotected_diff
require_green_branches
require_checked_pull
require_switches_on

# --- The merge, bracketed by the pending record ------------------------------

SL_RUN="$$.$(date +%s).$RANDOM"
fm_self_land_pending_write "$SL_REPO_DIR" "$ID" "$URL" "$HEAD" "$AUTHORITY" "$SL_RUN" \
  "$SL_SCAN_BASE" "$SL_SCAN_BASE_SHA" \
  || refuse pending "could not write the pending record; no merge was sent"
if ! prepare_forge_gate; then
  fm_self_land_pending_clear "$SL_REPO_DIR"
  refuse pending "could not prepare the forge gate; no merge was sent"
fi

merge_rc=0
PATH="$SL_GATE_DIR:$PATH" FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-pr-merge.sh" "$ID" "$URL" --expected-head "$HEAD" || merge_rc=$?
gate_refused=false
[ ! -e "$SL_GATE_DIR/refused" ] || gate_refused=true
remove_gate

# The state of this run's record says whether a merge command was sent.
sent_state=
if fm_self_land_pending_read "$SL_REPO_DIR" && [ "$FM_SELF_LAND_PENDING_RUN" = "$SL_RUN" ]; then
  sent_state=$FM_SELF_LAND_PENDING_STATE
fi
if [ "$sent_state" = armed ] && [ "$merge_rc" -eq 0 ]; then
  # The merge gate reports an accepted merge that did not pass the forge gate.
  # That must not happen. The record is kept as a sent merge, so the outcome
  # below is still settled, and the breaker stops every later landing.
  fm_self_land_pending_change "$SL_REPO_DIR" "$SL_RUN" armed sent || true
  sent_state=sent
  trip_breaker "$SL_SCAN_BASE" "$HEAD" "a merge of $URL was accepted without the check in front of the merge command" \
    || printf 'actionable: could not write the breaker record at %s\n' "$SL_REPO_DIR/breaker" >&2
  printf 'actionable: bin/fm-pr-merge.sh reported an accepted merge of %s that did not pass the check in front of the merge command; the circuit breaker is tripped, and the merge needs a review by hand\n' \
    "$URL" >&2
fi
case "$sent_state" in
  armed)
    fm_self_land_pending_clear "$SL_REPO_DIR"
    if [ "$gate_refused" = true ]; then
      note "the forge gate stopped the merge command for $URL; no merge was sent"
    else
      note "bin/fm-pr-merge.sh refused $URL (exit $merge_rc); no merge was sent"
    fi
    [ "$merge_rc" -ne 0 ] || merge_rc=1
    exit "$merge_rc"
    ;;
  sent)
    # The merge command ended. The clock of the record starts here, not when
    # the command started: it can take long to send its request. When this
    # change fails, the record still names the ended sender, and the run that
    # finds it starts the clock.
    fm_self_land_pending_change "$SL_REPO_DIR" "$SL_RUN" sent sent - || true
    ;;
  *)
    printf 'self-land: outcome unknown: the pending record of this run is gone or changed (merge exit %s); confirm %s by hand\n' \
      "$merge_rc" "$URL" >&2
    [ "$merge_rc" -ne 0 ] || merge_rc=1
    exit "$merge_rc"
    ;;
esac

if ! read_pull "$PR_NUMBER"; then
  printf 'self-land: outcome unknown: could not read %s after the merge attempt (merge exit %s); the pending record is kept, and running the same command again settles it without a second merge\n' \
    "$URL" "$merge_rc" >&2
  [ "$merge_rc" -ne 0 ] || merge_rc=1
  exit "$merge_rc"
fi

if [ "$SL_PR_MERGED" = true ] && [ "$SL_PR_HEAD" = "$HEAD" ]; then
  suffix=
  if [ "$merge_rc" -ne 0 ]; then
    suffix=' (reconciled)'
  fi
  # Before the record, so a record that cannot be completed does not skip it.
  require_merged_on_checked_base "$URL" "$SL_SCAN_BASE" "$SL_SCAN_BASE_SHA"
  record_landed "$ID" "$URL" "$AUTHORITY" \
    || stop_unrecorded "$URL" "$HEAD" "$SL_PR_MERGE_COMMIT"
  fm_self_land_pending_clear "$SL_REPO_DIR"
  [ "$merge_rc" -eq 0 ] \
    || note "the merge command failed (exit $merge_rc) but $URL reads back merged at head $HEAD; no second merge was sent"
  printf 'self-land: landed %s head=%s merge=%s%s\n' "$URL" "$HEAD" "${SL_PR_MERGE_COMMIT:--}" "$suffix"
  exit 0
fi

if [ "$SL_PR_MERGED" = true ]; then
  report_merged_at_other_head "$URL" "$HEAD"
  fm_self_land_pending_clear "$SL_REPO_DIR"
  refuse forge-read "$URL merged at head $SL_PR_HEAD, not the approved head $HEAD; this run did not land it"
fi

held=$(forge_hold)
if [ -n "$held" ]; then
  if [ "$SL_PR_HEAD" != "$HEAD" ]; then
    require_held_at_sent_head "$URL" "$HEAD"
    fm_self_land_pending_change "$SL_REPO_DIR" "$SL_RUN" sent queued || true
    refuse in-flight "the merge for $URL waits $held at head $SL_PR_HEAD, not the approved head $HEAD; the pending record is kept"
  fi
  if ! fm_self_land_pending_change "$SL_REPO_DIR" "$SL_RUN" sent queued; then
    printf 'actionable: could not mark %s as held by the forge; a later run marks it\n' "$SL_REPO_DIR/pending" >&2
  fi
  refuse in-flight "the merge for $URL waits $held at approved head $HEAD but has not landed; the pending record is kept until it merges or the forge no longer holds it"
fi

# A merge command was sent, and the pull request reads back unmerged and not
# held by the forge. The forge may still apply it, so the pending record stays.
if [ "$merge_rc" -eq 0 ]; then
  printf 'self-land: outcome unknown: the merge command succeeded, but %s reads back unmerged and not held by the forge; the pending record is kept, and running the same command again settles it\n' \
    "$URL" >&2
  exit 1
fi
note "the merge command for $URL failed (exit $merge_rc) and it reads back unmerged; the pending record is kept for ${SL_GRACE}s in case the forge still applies the merge, and no other self-landing starts in $PR_HOST/$PR_PATH until then"
exit "$merge_rc"
