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
#   fm-self-land.sh protected
#   fm-self-land.sh -h | --help
#
# <pr-url> is the canonical full GitHub pull request URL, and --head is the
# exact commit the merge review approved. The landing form takes no other
# option: there is no waiver flag, no merge method, and no argument that
# reaches the forge.
#
# `covers` exits 0 when config/self-land names the pull request's repository,
# 1 when it does not or the file is absent, and 2 when the file or the URL
# cannot be read. `protected` prints the paths a self-landed diff must not
# touch, one per line.
#
# A landing run refuses, before any forge write, when one of these is true:
#   stop-file       state/.self-land-off exists. Create it to stop every
#                   self-landing in this home; remove it to resume.
#   config          config/self-land is absent (self-landing is off) or cannot
#                   be trusted. docs/configuration.md owns its schema.
#   not-allowlisted no allow line names the repository. Only GitHub
#                   repositories can be named.
#   in-flight       another self-landing run holds this repository, or a
#                   merge it sent has no outcome yet.
#   pending         a pending record exists that cannot be read or settled.
#   breaker         the circuit breaker record for the repository exists.
#   red-base        the head of the pull request's base branch has a failed
#                   check or status. This run also writes the breaker record.
#   hold            the task is held for the captain, or the hold cannot be
#                   read.
#   evidence        config/merge-review does not require a review for the
#                   repository, or no approved two-model review exists at
#                   --head (bin/fm-merge-review.sh owns that verdict).
#   task            the task has no record in this home, or its away-posture
#                   record cannot be read.
#   forge-read      the pull request, its file list, or its base branch could
#                   not be read completely, or the pull request is not open at
#                   --head.
#   protected-path  the diff adds, changes, renames, or removes a protected
#                   path: .github/workflows/, a merge gate script or a library
#                   a gate loads, or a path a protect line names. Such a change
#                   needs the supervisor's merge.
#
# A failed check is a completed check run that concluded failure, timed_out,
# startup_failure, or action_required, or a commit status in state failure or
# error. A base branch with no checks is not red.
#
# Records, under state/self-land/<provider>/<host>/<owner>/<repository>/:
#   lock        one self-landing run per repository at a time. A second run
#               refuses at once instead of waiting.
#   pending     written before the merge is sent and removed when its outcome
#               is known (bin/fm-merge-authority-lib.sh owns the format).
#   breaker     written when the base branch head is red. This wrapper never
#               removes it. After the base branch is green again, the
#               supervisor or the owner removes the file by hand.
#   landed.tsv  one appended line per landed merge: epoch, task id, URL, head,
#               merge commit, and `landed` or `reconciled`.
#
# Lost forge response. After the merge attempt, and at the start of every later
# run that finds a pending record, the wrapper reads the pull request back.
# When it is merged at the recorded head, the wrapper records the outcome for
# supervision (bin/fm-merge-outcome-lib.sh, which records one outcome only
# once), appends the landed line, removes the pending record, and sends no
# merge. When the read fails, the pending record stays and the same command
# settles it later. A pending record whose pull request is still unmerged is
# treated as in flight for FM_SELF_LAND_PENDING_GRACE seconds (default 120, 0
# to 3600), then dropped, because the run that wrote it no longer holds the
# lock.
#
# Limits. Every record is local to this home, so the guards cover one home.
# One lane owner per repository is what makes them cover the repository. The
# file list is read from the forge at --head and read again after, so a head
# that moves away and back between two reads is not seen; the merge itself
# stays bound to --head.
#
# Exit status: 0 when the pull request landed, was reconciled as landed, or
# entered the forge's merge queue; 1 on a refusal; 2 on an invalid request. A
# merge that bin/fm-pr-merge.sh refuses exits with that script's status.
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

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-merge-outcome-lib.sh
. "$SCRIPT_DIR/fm-merge-outcome-lib.sh"
# shellcheck source=bin/fm-merge-authority-lib.sh
. "$SCRIPT_DIR/fm-merge-authority-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

# The merge gates: the entry points that decide a merge and the libraries they
# load directly. A diff that touches one could weaken the gate that lands it.
SL_PROTECT_BUILTIN='.github/workflows/
bin/fm-self-land.sh
bin/fm-pr-merge.sh
bin/fm-pr-check.sh
bin/fm-merge-local.sh
bin/fm-merge-review.sh
bin/fm-review-diff.sh
bin/fm-captain-hold.sh
bin/fm-merge-authority-lib.sh
bin/fm-merge-outcome-lib.sh
bin/fm-pr-lib.sh
bin/fm-afk-contract.sh
bin/fm-lease-lib.sh
bin/fm-wake-lib.sh
bin/fm-backlog-transition-lib.sh'

SL_LOCK=
SL_REPO_DIR=

invalid() {  # <message>
  printf 'error: %s\n' "$1" >&2
  printf 'usage: fm-self-land.sh <task-id> <pr-url> --head <full-sha>\n' >&2
  exit 2
}

refuse() {  # <reason> <message>
  printf 'self-land: refused (%s): %s\n' "$1" "$2" >&2
  exit 1
}

note() {  # <message>
  printf 'self-land: %s\n' "$1" >&2
}

# shellcheck disable=SC2329 # Invoked by the EXIT trap.
release_lock() {
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

protected_paths() {
  printf '%s\n' "$SL_PROTECT_BUILTIN"
  [ -z "$FM_SELF_LAND_PROTECT" ] || printf '%s\n' "$FM_SELF_LAND_PROTECT"
}

case "${1:-}" in
  protected)
    [ "$#" -eq 1 ] || invalid "protected takes no argument"
    rc=0
    fm_self_land_config_load "$SL_CONFIG" || rc=$?
    if [ "$rc" -eq 2 ]; then
      printf 'error: %s\n' "$FM_SELF_LAND_ERROR" >&2
      exit 2
    fi
    protected_paths
    exit 0
    ;;
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

[ "$#" -eq 4 ] && [ "$3" = --head ] \
  || invalid "a landing needs exactly <task-id> <pr-url> --head <full-sha>; there is no other option and no waiver flag"
ID=$1
HEAD=$4
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

SL_GRACE=${FM_SELF_LAND_PENDING_GRACE:-120}
case "$SL_GRACE" in
  '' | *[!0-9]*) SL_GRACE=120 ;;
esac
[ "$SL_GRACE" -le 3600 ] || SL_GRACE=120

# The two switches a person can throw without editing anything else. They are
# read at the start and again just before the merge is sent.
require_switches_on() {
  if [ -e "$SL_STOP_FILE" ] || [ -L "$SL_STOP_FILE" ]; then
    refuse stop-file "state/.self-land-off exists; remove it to resume self-landing"
  fi
  if [ -n "$SL_REPO_DIR" ] && { [ -e "$SL_REPO_DIR/breaker" ] || [ -L "$SL_REPO_DIR/breaker" ]; }; then
    [ ! -f "$SL_REPO_DIR/breaker" ] || sed 's/^/self-land: breaker: /' "$SL_REPO_DIR/breaker" >&2 || true
    refuse breaker "the circuit breaker for $PR_HOST/$PR_PATH is tripped; after the base branch is green again, remove $SL_REPO_DIR/breaker by hand"
  fi
}

require_released_hold() {
  local hold_status=0
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" --distinguish-absent >/dev/null || hold_status=$?
  case "$hold_status" in
    0) refuse hold "task $ID is still held for the captain" ;;
    1 | 3) return 0 ;;
    *) refuse hold "could not determine whether task $ID is still held for the captain" ;;
  esac
}

# Self-landing needs proof, so a repository the merge review does not cover is
# refused here even though bin/fm-pr-merge.sh would merge it unreviewed.
require_review_evidence() {
  local covers_rc=0 check_rc=0 verdict
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-merge-review.sh" covers "$URL" >/dev/null 2>&1 || covers_rc=$?
  case "$covers_rc" in
    0) ;;
    1) refuse evidence "config/merge-review does not require a review for $PR_HOST/$PR_PATH, so no approval can prove this head" ;;
    *) refuse evidence "config/merge-review could not be read" ;;
  esac
  verdict=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-merge-review.sh" check "$URL" --head "$HEAD" 2>&1) || check_rc=$?
  if [ "$check_rc" -ne 0 ]; then
    [ -z "$verdict" ] || printf '%s\n' "$verdict" >&2
    refuse evidence "no approved two-model review exists for $URL at head $HEAD"
  fi
  case "$verdict" in
    *"merge-review: approved head=$HEAD"*) ;;
    *)
      [ -z "$verdict" ] || printf '%s\n' "$verdict" >&2
      refuse evidence "the merge review did not report an approval at head $HEAD"
      ;;
  esac
}

SL_PR_STATE=
SL_PR_MERGED=
SL_PR_HEAD=
SL_PR_BASE=
SL_PR_FILES=
SL_PR_MERGE_COMMIT=
# Read one pull request of this repository from the forge. Returns 1 when the
# read fails or its answer does not have the expected shape.
read_pull() {  # <number>
  local json fields line named=0 total=0
  local state='' merged='' head='' base='' files='' merge_commit=''
  SL_PR_STATE=
  SL_PR_MERGED=
  SL_PR_HEAD=
  SL_PR_BASE=
  SL_PR_FILES=
  SL_PR_MERGE_COMMIT=
  json=$(gh api "repos/$PR_OWNER/$PR_REPO/pulls/$1" 2>/dev/null) || return 1
  fields=$(printf '%s' "$json" | jq -r '
    "state=" + (.state | strings),
    "merged=" + (.merged | booleans | tostring),
    "head=" + (.head.sha | strings),
    "base=" + (.base.ref | strings),
    "files=" + (.changed_files | numbers | tostring),
    "merge_commit=" + (.merge_commit_sha // "" | strings)
  ' 2>/dev/null) || return 1
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      merged=*) merged=${line#merged=} ;;
      head=*) head=${line#head=} ;;
      base=*) base=${line#base=} ;;
      files=*) files=${line#files=} ;;
      merge_commit=*) merge_commit=${line#merge_commit=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  [ "$named" -eq 6 ] && [ "$total" -eq 6 ] || return 1
  case "$state" in open | closed) ;; *) return 1 ;; esac
  case "$merged" in true | false) ;; *) return 1 ;; esac
  fm_pr_head_valid "$head" || return 1
  [[ "$base" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
  case "$base" in *..* | /* | */) return 1 ;; esac
  case "$files" in '' | *[!0-9]*) return 1 ;; esac
  [ -z "$merge_commit" ] || fm_pr_head_valid "$merge_commit" || return 1
  SL_PR_STATE=$state
  SL_PR_MERGED=$merged
  SL_PR_HEAD=$head
  SL_PR_BASE=$base
  SL_PR_FILES=$files
  SL_PR_MERGE_COMMIT=$merge_commit
}

# Refuse a diff that touches a protected path. The whole file list must be
# read: a count that differs from the pull request's own count is a refusal.
require_unprotected_diff() {
  local raw protect result count='' hits=''
  protect=$(protected_paths | jq -R . | jq -s -c .) \
    || refuse forge-read "could not prepare the protected path list"
  raw=$(gh api --paginate "repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER/files?per_page=100" 2>/dev/null) \
    || refuse forge-read "could not read the file list of $URL"
  result=$(printf '%s' "$raw" | jq -s -r --argjson protect "$protect" '
    [ .[] | if type == "array" then .[] else error("shape") end ]
    | map(if (.filename | type) == "string" then . else error("shape") end)
    | "count=\(length)",
      ( [ .[] | .filename, (.previous_filename | strings) ] | unique | .[]
        | . as $path | ($path | ascii_downcase) as $lower
        | select(any($protect[]; . as $entry
            | if ($entry | endswith("/")) then ($lower | startswith($entry)) else $lower == $entry end))
        | "hit=\($path | @json)" )
  ' 2>/dev/null) || refuse forge-read "the file list of $URL did not have the expected shape"
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

# Trip the breaker when the base branch head is red. An unreadable base is a
# refusal and trips nothing.
require_green_base() {
  local sha runs statuses red epoch tmp
  sha=$(gh api "repos/$PR_OWNER/$PR_REPO/branches/$SL_PR_BASE" 2>/dev/null \
    | jq -r '.commit.sha | strings' 2>/dev/null) \
    || refuse forge-read "could not read the head of base branch $SL_PR_BASE"
  fm_pr_head_valid "$sha" || refuse forge-read "could not read the head of base branch $SL_PR_BASE"
  runs=$(gh api --paginate "repos/$PR_OWNER/$PR_REPO/commits/$sha/check-runs?per_page=100" 2>/dev/null \
    | jq -s -r '
      [ .[] | .check_runs | if type == "array" then .[] else error("shape") end
        | select(.status == "completed")
        | select(.conclusion == "failure" or .conclusion == "timed_out"
            or .conclusion == "startup_failure" or .conclusion == "action_required")
        | (.name | strings) // "(unnamed check)" ]
      | unique | .[]' 2>/dev/null) \
    || refuse forge-read "could not read the checks of base branch $SL_PR_BASE at $sha"
  statuses=$(gh api "repos/$PR_OWNER/$PR_REPO/commits/$sha/status" 2>/dev/null \
    | jq -r '
      if (.state | type) == "string" then . else error("shape") end
      | [ (.statuses // [])[] | select(.state == "failure" or .state == "error")
          | (.context | strings) // "(unnamed status)" ]
      | unique | .[]' 2>/dev/null) \
    || refuse forge-read "could not read the statuses of base branch $SL_PR_BASE at $sha"
  red=$(printf '%s\n%s\n' "$runs" "$statuses" | sed '/^$/d' | tr '\n' ',' | sed 's/,$//; s/,/, /g')
  [ -n "$red" ] || return 0
  epoch=$(date +%s)
  if tmp=$(umask 077 && mktemp "$SL_REPO_DIR/.breaker.XXXXXX") \
    && printf '%s\ntripped=%s\nbase=%s\nsha=%s\nred=%s\n' \
      fm-self-land-breaker-v1 "$epoch" "$SL_PR_BASE" "$sha" "$red" > "$tmp" \
    && mv -f -- "$tmp" "$SL_REPO_DIR/breaker"; then
    :
  else
    [ -z "${tmp:-}" ] || rm -f -- "$tmp"
    refuse red-base "base branch $SL_PR_BASE is red at $sha ($red) and the breaker record could not be written"
  fi
  refuse red-base "base branch $SL_PR_BASE is red at $sha ($red); the circuit breaker is now tripped at $SL_REPO_DIR/breaker"
}

# Record a merge this home sent whose outcome bin/fm-pr-merge.sh did not
# record, then log it. The outcome owner records one merge only once.
record_landed() {  # <task-id> <pr-url> <head> <merge-commit> <authority> <landed|reconciled>
  local outcome_rc=0
  if [ "$6" = reconciled ]; then
    fm_merge_outcome_report "$FM_HOME" "$STATE" "$1" "$2" self "$5" || outcome_rc=$?
    case "$outcome_rc" in
      0) ;;
      3) printf 'actionable: merged %s but could not report it upward: this home has no readable secondmate identity or parent binding\n' "$2" >&2 ;;
      *) printf 'actionable: merged %s but could not record the outcome for supervision\n' "$2" >&2 ;;
    esac
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" "${4:--}" "$6" \
    >> "$SL_REPO_DIR/landed.tsv" \
    || printf 'actionable: merged %s but could not append to %s\n' "$2" "$SL_REPO_DIR/landed.tsv" >&2
}

# Settle a pending record left by an earlier run before anything new starts.
# Returns only when no pending record remains and this run may continue.
settle_pending() {
  local rc=0 p_id p_url p_head p_authority p_epoch p_number now age
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
      record_landed "$p_id" "$p_url" "$p_head" "$SL_PR_MERGE_COMMIT" "$p_authority" reconciled
      fm_self_land_pending_clear "$SL_REPO_DIR"
      note "reconciled $p_url as landed at head $p_head; no second merge was sent"
      if [ "$p_url" = "$URL" ]; then
        if [ "$p_head" = "$HEAD" ]; then
          printf 'self-land: landed %s head=%s merge=%s (reconciled)\n' "$URL" "$HEAD" "${SL_PR_MERGE_COMMIT:--}"
          exit 0
        fi
        refuse forge-read "$URL is already merged at head $p_head, not at $HEAD"
      fi
      return 0
    fi
    fm_self_land_pending_clear "$SL_REPO_DIR"
    note "dropped the pending record for $p_url: it merged at head $SL_PR_HEAD, not the recorded $p_head"
    return 0
  fi
  now=$(date +%s)
  age=$((now - p_epoch))
  if [ "$age" -lt "$SL_GRACE" ]; then
    refuse in-flight "a merge for $p_url was sent ${age}s ago and has no outcome yet; retry after ${SL_GRACE}s"
  fi
  fm_self_land_pending_clear "$SL_REPO_DIR"
  note "dropped the pending record for $p_url: it is still unmerged after ${age}s"
}

# --- Gates that need no forge and no lock ------------------------------------

require_switches_on
[ "$PROVIDER" = github ] \
  || refuse not-allowlisted "self-landing supports GitHub pull requests only"
load_grant
fm_self_land_repo_allowed "$PR_HOST" "$PR_PATH" \
  || refuse not-allowlisted "config/self-land has no allow line for $PR_HOST/$PR_PATH"
[ -f "$META" ] || refuse task "task $ID has no record in this home"
if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  refuse forge-read "self-landing needs gh and jq"
fi
fm_pr_github_host_export "$PR_HOST"

SL_REPO_DIR=$(fm_self_land_repo_dir "$STATE" "$PROVIDER" "$PR_HOST" "$PR_PATH") \
  || refuse config "could not name the record directory for $PR_HOST/$PR_PATH"
(umask 077 && mkdir -p -- "$SL_REPO_DIR") \
  || refuse config "could not create $SL_REPO_DIR"
require_switches_on

# --- One self-landing run per repository -------------------------------------

trap release_lock EXIT
trap 'exit 130' INT
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
if [ "$SL_PR_MERGED" = true ] || [ "$SL_PR_STATE" != open ]; then
  refuse forge-read "$URL is not open (state=$SL_PR_STATE, merged=$SL_PR_MERGED); nothing to land"
fi
[ "$SL_PR_HEAD" = "$HEAD" ] \
  || refuse forge-read "$URL is at head $SL_PR_HEAD, not the approved head $HEAD"
FILES_BEFORE=$SL_PR_FILES
require_unprotected_diff
read_pull "$PR_NUMBER" || refuse forge-read "could not read $URL again after its file list"
if [ "$SL_PR_HEAD" != "$HEAD" ] || [ "$SL_PR_FILES" != "$FILES_BEFORE" ] || [ "$SL_PR_STATE" != open ]; then
  refuse forge-read "$URL changed while its file list was read; run again at the head the review approved"
fi
require_green_base
require_switches_on

# --- The merge, bracketed by the pending record ------------------------------

fm_self_land_pending_write "$SL_REPO_DIR" "$ID" "$URL" "$HEAD" "$AUTHORITY" \
  || refuse pending "could not write the pending record; no merge was sent"

merge_rc=0
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-pr-merge.sh" "$ID" "$URL" --expected-head "$HEAD" || merge_rc=$?

if ! read_pull "$PR_NUMBER"; then
  printf 'self-land: outcome unknown: could not read %s after the merge attempt (merge exit %s); the pending record is kept, and running the same command again settles it without a second merge\n' \
    "$URL" "$merge_rc" >&2
  [ "$merge_rc" -ne 0 ] || merge_rc=1
  exit "$merge_rc"
fi

if [ "$SL_PR_MERGED" = true ] && [ "$SL_PR_HEAD" = "$HEAD" ]; then
  if [ "$merge_rc" -eq 0 ]; then
    record_landed "$ID" "$URL" "$HEAD" "$SL_PR_MERGE_COMMIT" "$AUTHORITY" landed
    fm_self_land_pending_clear "$SL_REPO_DIR"
    printf 'self-land: landed %s head=%s merge=%s\n' "$URL" "$HEAD" "${SL_PR_MERGE_COMMIT:--}"
  else
    record_landed "$ID" "$URL" "$HEAD" "$SL_PR_MERGE_COMMIT" "$AUTHORITY" reconciled
    fm_self_land_pending_clear "$SL_REPO_DIR"
    note "the merge command failed (exit $merge_rc) but $URL reads back merged at head $HEAD; no second merge was sent"
    printf 'self-land: landed %s head=%s merge=%s (reconciled)\n' "$URL" "$HEAD" "${SL_PR_MERGE_COMMIT:--}"
  fi
  exit 0
fi

if [ "$SL_PR_MERGED" = true ]; then
  fm_self_land_pending_clear "$SL_REPO_DIR"
  refuse forge-read "$URL merged at head $SL_PR_HEAD, not the approved head $HEAD; this run did not land it"
fi

if [ "$merge_rc" -eq 0 ]; then
  printf 'self-land: queued %s head=%s; the forge has not merged it yet, and the pending record is kept until it does\n' \
    "$URL" "$HEAD"
  exit 0
fi

fm_self_land_pending_clear "$SL_REPO_DIR"
note "bin/fm-pr-merge.sh refused $URL (exit $merge_rc); nothing was merged"
exit "$merge_rc"
