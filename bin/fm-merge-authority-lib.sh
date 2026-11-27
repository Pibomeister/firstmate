#!/usr/bin/env bash
# Durable ownership of the authority under which a task's merge was accepted.
#
# The away-posture record (state/.afk-contract) is resolved only at the merge
# gate. After a forge accepts the merge, bin/fm-pr-merge.sh persists that answer
# as:
#   state/<task-id>.merge-authority
#   fm-merge-authority-v1
#   <provider>
#   <host>
#   <path>
#   <number>
#   <authority>                 away | attended
# While an away record exists every merge runs under away authority (the
# record's presence is the whole mechanical fact; which merge the captain's
# away words meant is the supervision session's reading); without one, or while
# the record is quiet mode's (bin/fm-afk-contract.sh mode: the captain is
# present), the merge is attended. The retired values yolo and away-grant are
# still accepted when an existing record is read, so a merge persisted before
# the words model landed is still consumed, but they are never written again.
# The identity comes from the merge run's immutable canonical URL parse;
# persistence revalidates the task's current pr= metadata under its metadata
# and lifecycle locks and refuses a mismatch. The file is atomically published,
# mode 0600, single-link, and on the state filesystem. A poll consumes it only
# when all identity fields match its own validated snapshot.
#
# The label of a landed merge is the authority recorded at the most recent send
# of a merge for that pull request. fm_merge_authority_read is the one function
# that names it, for every reporter of a landing that did not send the merge in
# the same process: the stored record first, then the self-landing pending
# record while it names a merge that this home sent (state sent or queued).
# A self-landing send retires the stored record of its pull request
# (fm_self_land_send_record), so a stored record is never older than the pending
# record next to it. Without either record the authority is external; it is
# never resolved again from a later away-posture record.
#
# Resolution authorizes nothing by itself. bin/fm-pr-merge.sh owns the merge
# gate and persists only after a forge command succeeds, before releasing the
# task lifecycle lock. After observing a landed merge, bin/fm-watch.sh acquires
# that same lock, revalidates the poll, publishes its durable outcome, and
# retires only the exact authority record it read. Teardown uses the same lock,
# so it cannot interleave with that consumption transaction, and removes any
# remaining record.
#
# Self-landing is the one standing authority this file also owns. The local
# config/self-land file is the owner's opt-in: its allow lines name the only
# repositories a lane owner may land through bin/fm-self-land.sh, and an absent
# file means self-landing is off. The grant adds no authority value: a
# self-landed merge is still recorded as away or attended by the answer above.
# Before the merge gate starts the wrapper publishes its intent as:
#   state/self-land/<provider>/<host>/<path>/pending
#   fm-self-land-pending-v1
#   <task-id>
#   <pr-url>
#   <head>
#   <authority>                 away | attended
#   <epoch>                     of the last state change
#   <state>                     armed | sent | queued
#   <run>                       token of the run that wrote the record
#   <sender>                    `-`, or the process id and start time of the
#                               process that sends the merge command
#   <base>                      base branch the diff was checked against
#   <base-commit>               commit the forge named as that base
# The record is mode 0600 and atomically published. It names the one merge this
# home may have sent for that repository, so a later run can read the pull
# request back and settle the record without sending a second merge. The
# states and the rule that changes them are described at the functions below.
# bin/fm-self-land.sh owns every gate and the reconciliation rule; the functions
# here only load the grant and store that record.
#
# Sourced by those scripts and by tests. No side effects on source beyond its
# sourced libraries.

_FM_MERGE_AUTHORITY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$_FM_MERGE_AUTHORITY_LIB_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-afk-contract.sh
. "$_FM_MERGE_AUTHORITY_LIB_DIR/fm-afk-contract.sh"

# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_MERGE_AUTHORITY=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_MERGE_AUTHORITY_REASON=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_MERGE_AUTHORITY_RECORD_IDENTITY=

fm_merge_authority_resolve() {  # <home> <state> <meta> <task-id>
  local home=${1-} state=${2-} meta=${3-} id=${4-}
  FM_MERGE_AUTHORITY=
  FM_MERGE_AUTHORITY_REASON='invalid'
  [ -n "$home" ] && [ -n "$state" ] && [ -n "$meta" ] && [ -n "$id" ] || return 1

  if ! fm_afk_contract_present "$state"; then
    FM_MERGE_AUTHORITY='attended'
    FM_MERGE_AUTHORITY_REASON='attended'
    return 0
  fi
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    "$_FM_MERGE_AUTHORITY_LIB_DIR/fm-afk-contract.sh" validate >/dev/null 2>&1; then
    FM_MERGE_AUTHORITY_REASON='record-unreadable'
    return 1
  fi
  if ! fm_afk_contract_away_present "$state"; then
    FM_MERGE_AUTHORITY='attended'
    FM_MERGE_AUTHORITY_REASON='attended'
    return 0
  fi
  FM_MERGE_AUTHORITY='away'
  # shellcheck disable=SC2034 # Public results consumed by sourcing callers.
  FM_MERGE_AUTHORITY_REASON='away'
  return 0
}

fm_merge_authority_record_matches() {  # <record> <device> <provider> <host> <path> <number>
  local record=$1 device=$2 expected_provider=$3 expected_host=$4 expected_path=$5 expected_number=$6
  local version provider host path number authority
  fm_pr_private_file_valid "$record" 600 "$device" || return 1
  exec 8< "$record" || return 1
  IFS= read -r version <&8 || { exec 8<&-; return 1; }
  IFS= read -r provider <&8 || { exec 8<&-; return 1; }
  IFS= read -r host <&8 || { exec 8<&-; return 1; }
  IFS= read -r path <&8 || { exec 8<&-; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; return 1; }
  IFS= read -r authority <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  case "$authority" in away|attended|yolo|away-grant) ;; *) return 1 ;; esac
  [ "$version" = fm-merge-authority-v1 ] \
    && [ "$provider" = "$expected_provider" ] \
    && [ "$host" = "$expected_host" ] \
    && [ "$path" = "$expected_path" ] \
    && [ "$number" = "$expected_number" ] || return 1
  FM_MERGE_AUTHORITY=$authority
}

fm_merge_authority_persist() {  # <state> <task-id> <meta> <provider> <host> <path> <number> <authority>
  local state=$1 id=$2 meta=$3 provider=$4 host=$5 path=$6 number=$7 authority=$8
  local record tmp='' state_device lock status=0
  fm_pr_task_id_valid "$id" || return 1
  case "$authority" in away|attended) ;; *) return 1 ;; esac
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_metadata_identity_parse "$meta" || return 1
  [ "$FM_PR_META_PROVIDER" = "$provider" ] \
    && [ "$FM_PR_META_HOST" = "$host" ] \
    && [ "$FM_PR_META_PATH" = "$path" ] \
    && [ "$FM_PR_META_NUMBER" = "$number" ] || return 1
  record="$state/$id.merge-authority"
  lock="$record.lock"
  fm_lock_acquire_wait "$lock" || return 1
  fm_pr_regular_destination_on_device_or_absent "$record" "$state_device" || status=1
  if [ "$status" -eq 0 ]; then
    umask 077
    tmp=$(mktemp "$state/.fm-merge-authority.XXXXXX") || status=1
  fi
  if [ "$status" -eq 0 ]; then
    printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
      fm-merge-authority-v1 "$provider" "$host" "$path" "$number" "$authority" > "$tmp" \
      || status=1
  fi
  if [ "$status" -eq 0 ]; then
    chmod 0600 "$tmp" \
      && fm_merge_authority_record_matches "$tmp" "$state_device" \
        "$provider" "$host" "$path" "$number" \
      && fm_pr_regular_destination_on_device_or_absent "$record" "$state_device" \
      && mv -f -- "$tmp" "$record" \
      && fm_merge_authority_record_matches "$record" "$state_device" \
        "$provider" "$host" "$path" "$number" \
      || status=1
  fi
  [ "$status" -eq 0 ] || rm -f -- "$tmp"
  fm_lock_release "$lock" || status=1
  return "$status"
}

fm_merge_authority_read() {  # <state> <task-id> <provider> <host> <path> <number> [head]
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6
  local record state_device lock status=0 authority pending_dir head=${7-}
  FM_MERGE_AUTHORITY='external'
  FM_MERGE_AUTHORITY_RECORD_IDENTITY=
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  record="$state/$id.merge-authority"
  lock="$record.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if fm_merge_authority_record_matches "$record" "$state_device" \
      "$provider" "$host" "$path" "$number"; then
    # shellcheck disable=SC2034 # Public results consumed by sourcing callers.
    FM_MERGE_AUTHORITY_RECORD_IDENTITY=$(fm_pr_file_identity "$record") || status=1
  elif authority=$(
    pending_dir=$(fm_self_land_repo_dir "$state" "$provider" "$host" "$path") || exit 1
    fm_pr_private_file_valid "$pending_dir/pending" 600 "$state_device" || exit 1
    fm_self_land_pending_read "$pending_dir" || exit 1
    [ "$FM_SELF_LAND_PENDING_STATE" = sent ] || [ "$FM_SELF_LAND_PENDING_STATE" = queued ] || exit 1
    [ -z "$head" ] || [ "$FM_SELF_LAND_PENDING_HEAD" = "$head" ] || exit 1
    fm_pr_url_parse "$FM_SELF_LAND_PENDING_URL" || exit 1
    [ "$FM_PR_PROVIDER" = "$provider" ] && [ "$FM_PR_HOST" = "$host" ] \
      && [ "$FM_PR_PATH" = "$path" ] && [ "$FM_PR_NUMBER" = "$number" ] || exit 1
    printf '%s\n' "$FM_SELF_LAND_PENDING_AUTHORITY"
  ); then
    FM_MERGE_AUTHORITY=$authority
  else
    FM_MERGE_AUTHORITY='external'
    status=1
  fi
  fm_lock_release "$lock" || status=1
  return "$status"
}

# Remove the stored record of <task-id> when it names this pull request: a new
# send of a merge for that pull request supersedes it. A record that names
# another pull request stays. FM_MERGE_AUTHORITY is left as it was.
fm_merge_authority_retire() {  # <state> <task-id> <provider> <host> <path> <number>
  local state=${1-} id=${2-} record state_device lock status=0 kept=$FM_MERGE_AUTHORITY
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  record="$state/$id.merge-authority"
  lock="$record.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if fm_merge_authority_record_matches "$record" "$state_device" \
      "${3-}" "${4-}" "${5-}" "${6-}"; then
    rm -f -- "$record" || status=1
  fi
  FM_MERGE_AUTHORITY=$kept
  fm_lock_release "$lock" || status=1
  return "$status"
}

fm_merge_authority_remove_if_matches() {  # <state> <task-id> <provider> <host> <path> <number> <authority> <file-identity>
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6
  local authority=$7 expected_file_identity=$8 record state_device lock current_file_identity status=0
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  record="$state/$id.merge-authority"
  lock="$record.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if [ -e "$record" ] || [ -L "$record" ]; then
    if fm_merge_authority_record_matches "$record" "$state_device" \
        "$provider" "$host" "$path" "$number"; then
      current_file_identity=$(fm_pr_file_identity "$record") || status=1
      if [ "$status" -eq 0 ] \
        && [ "$FM_MERGE_AUTHORITY" = "$authority" ] \
        && [ "$current_file_identity" = "$expected_file_identity" ]; then
        rm -f -- "$record" || status=1
      fi
    elif ! fm_pr_private_file_valid "$record" 600 "$state_device"; then
      status=1
    fi
  fi
  fm_lock_release "$lock" || status=1
  return "$status"
}

# --- Self-landing: the standing grant and the pending-merge record -----------

# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_SELF_LAND_ALLOW=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_SELF_LAND_ERROR=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_SELF_LAND_PENDING_ID=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_SELF_LAND_PENDING_URL=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_SELF_LAND_PENDING_HEAD=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_SELF_LAND_PENDING_AUTHORITY=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_SELF_LAND_PENDING_EPOCH=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_SELF_LAND_PENDING_STATE=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_SELF_LAND_PENDING_RUN=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_SELF_LAND_PENDING_SENDER=

_fm_self_land_trim() {  # <text>
  local text=$1
  text=${text#"${text%%[![:space:]]*}"}
  text=${text%"${text##*[![:space:]]}"}
  printf '%s' "$text"
}

_fm_self_land_lower() {  # <text>
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

# Load the grant. FM_SELF_LAND_ALLOW receives one lowercase repository per
# line. Returns 0 when the file was read, 1 when it is
# absent (self-landing is off), and 2 with FM_SELF_LAND_ERROR set when it cannot
# be trusted, so a typing mistake never widens the grant.
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
fm_self_land_config_load() {  # <config-file>
  local config=${1-} line key val n=0
  local LC_ALL=C
  FM_SELF_LAND_ALLOW=
  FM_SELF_LAND_ERROR=
  if [ -z "$config" ]; then
    FM_SELF_LAND_ERROR='no config/self-land path was given'
    return 2
  fi
  if [ ! -e "$config" ] && [ ! -L "$config" ]; then
    return 1
  fi
  if [ ! -f "$config" ] || [ ! -r "$config" ]; then
    FM_SELF_LAND_ERROR='config/self-land is not a readable file'
    return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=$(_fm_self_land_trim "$line")
    case "$line" in
      '' | '#'*) continue ;;
      *=*) ;;
      *)
        FM_SELF_LAND_ERROR="config/self-land line $n: expected key=value"
        return 2
        ;;
    esac
    key=$(_fm_self_land_trim "${line%%=*}")
    val=$(_fm_self_land_lower "$(_fm_self_land_trim "${line#*=}")")
    case "$key" in
      allow)
        if ! [[ "$val" =~ ^[a-z0-9.-]+/[a-z0-9._-]+/[a-z0-9._-]+$ ]]; then
          FM_SELF_LAND_ERROR="config/self-land line $n: allow needs <host>/<owner>/<repository>, with no wildcard"
          return 2
        fi
        FM_SELF_LAND_ALLOW="${FM_SELF_LAND_ALLOW:+$FM_SELF_LAND_ALLOW
}$val"
        ;;
      *)
        FM_SELF_LAND_ERROR="config/self-land line $n: unknown key \"$key\""
        return 2
        ;;
    esac
  done < "$config"
  return 0
}

# True when the loaded grant names <host>/<path>, without regard to letter case.
fm_self_land_repo_allowed() {  # <host> <path>
  local want
  [ -n "${1-}" ] && [ -n "${2-}" ] || return 1
  [ -n "$FM_SELF_LAND_ALLOW" ] || return 1
  want=$(_fm_self_land_lower "$1/$2")
  printf '%s\n' "$FM_SELF_LAND_ALLOW" | grep -qxF -- "$want"
}

# Print the directory that holds one repository's self-landing records.
fm_self_land_repo_dir() {  # <state> <provider> <host> <path>
  [ -n "${1-}" ] && [ -n "${2-}" ] && [ -n "${3-}" ] && [ -n "${4-}" ] || return 1
  case "$2/$3/$4" in
    *..* | *[[:space:]]*) return 1 ;;
  esac
  printf '%s/self-land/%s/%s\n' "$1" "$2" "$(_fm_self_land_lower "$3/$4")"
}

# The states of the pending-merge record of one repository, <repo-dir>/pending:
#   armed   written before bin/fm-pr-merge.sh starts. No merge was sent.
#   sent    the merge command is about to reach the forge, or reached it.
#   queued  the forge holds the merge: the pull request waits in its merge
#           queue, or auto-merge is armed for it.
# A sent or queued record names a merge that this home sent, and its authority
# is the authority at that send. The authority of an armed record is the answer
# at the start of the run, and it labels nothing.
# The record also names its sender: the process id and the start time of the
# process that sends the merge command, so a later run can tell that the
# command is still running. The sender is `-` while no merge command runs:
# before one is sent, and from the state change that follows its end. The clock
# of a sent record with sender `-` therefore started after its command ended.
# The record names the base branch and the base commit its diff was checked
# against, so a later run can tell that the merge landed on another base.
# A state change is one read, compare, and write under <repo-dir>/pending.lock,
# so two processes never both act on the state they read. The lock functions
# come from bin/fm-wake-lib.sh, which the caller sources.

_fm_self_land_sender_valid() {  # <process id, one space, start time>
  [[ "${1-}" =~ ^[0-9]+\ [A-Za-z0-9\ :=-]+$ ]]
}

# Name process <pid> as a sender: its id and its start time, which an exec
# keeps. Prints `-` when the start time cannot be read. The process functions
# come from bin/fm-wake-lib.sh, which the caller sources.
fm_self_land_sender_of() {  # <pid>
  local start
  if start=$(fm_pid_start_time "${1-}" 2>/dev/null) && _fm_self_land_sender_valid "${1-} $start"; then
    printf '%s %s\n' "$1" "$start"
  else
    printf '%s\n' -
  fi
}

# Succeed when the sender a record names is still the same live process.
fm_self_land_sender_alive() {  # <sender>
  local pid start
  _fm_self_land_sender_valid "${1-}" || return 1
  pid=${1%% *}
  start=${1#* }
  fm_pid_alive "$pid" || return 1
  [ "$(fm_pid_start_time "$pid" 2>/dev/null)" = "$start" ]
}

_fm_self_land_pending_valid() {  # <task-id> <pr-url> <head> <authority> <epoch> <state> <run> <sender> <base> <base-commit>
  fm_pr_task_id_valid "${1-}" || return 1
  fm_pr_head_valid "${3-}" || return 1
  case "${4-}" in away | attended) ;; *) return 1 ;; esac
  case "${2-}" in
    *[[:space:]]*) return 1 ;;
    https://*) ;;
    *) return 1 ;;
  esac
  case "${5-}" in '' | *[!0-9]*) return 1 ;; esac
  case "${6-}" in armed | sent | queued) ;; *) return 1 ;; esac
  case "${7-}" in '' | *[!A-Za-z0-9.-]*) return 1 ;; esac
  [ "${8-}" = - ] || _fm_self_land_sender_valid "${8-}" || return 1
  [[ "${9-}" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
  fm_pr_head_valid "${10-}" || return 1
  return 0
}

_fm_self_land_pending_store() {  # <repo-dir> <task-id> <pr-url> <head> <authority> <epoch> <state> <run> <sender> <base> <base-commit>
  local dir=${1-} tmp
  [ -n "$dir" ] || return 1
  shift
  _fm_self_land_pending_valid "$@" || return 1
  (umask 077 && mkdir -p -- "$dir") || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  tmp=$(umask 077 && mktemp "$dir/.pending.XXXXXX") || return 1
  if printf '%s\n' fm-self-land-pending-v1 "$@" > "$tmp" \
    && chmod 0600 "$tmp" \
    && mv -f -- "$tmp" "$dir/pending"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# Write the armed record of one run. The caller holds the repository lock and
# has settled every earlier record.
fm_self_land_pending_write() {  # <repo-dir> <task-id> <pr-url> <head> <authority> <run> <base> <base-commit>
  local epoch
  epoch=$(date +%s) || return 1
  _fm_self_land_pending_store "${1-}" "${2-}" "${3-}" "${4-}" "${5-}" "$epoch" armed "${6-}" - "${7-}" "${8-}"
}

# Read one repository's pending record into FM_SELF_LAND_PENDING_*. Returns 0
# when a valid record was read, 1 when none exists, and 2 when a record exists
# that cannot be trusted.
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
fm_self_land_pending_read() {  # <repo-dir>
  local record="${1-}/pending" version id url head authority epoch state run sender base base_sha extra
  FM_SELF_LAND_PENDING_ID=
  FM_SELF_LAND_PENDING_URL=
  FM_SELF_LAND_PENDING_HEAD=
  FM_SELF_LAND_PENDING_AUTHORITY=
  FM_SELF_LAND_PENDING_EPOCH=
  FM_SELF_LAND_PENDING_STATE=
  FM_SELF_LAND_PENDING_RUN=
  FM_SELF_LAND_PENDING_SENDER=
  FM_SELF_LAND_PENDING_BASE=
  FM_SELF_LAND_PENDING_BASE_SHA=
  [ -n "${1-}" ] || return 2
  if [ ! -e "$record" ] && [ ! -L "$record" ]; then
    return 1
  fi
  [ -f "$record" ] && [ ! -L "$record" ] && [ -r "$record" ] || return 2
  exec 8< "$record" || return 2
  IFS= read -r version <&8 || { exec 8<&-; return 2; }
  IFS= read -r id <&8 || { exec 8<&-; return 2; }
  IFS= read -r url <&8 || { exec 8<&-; return 2; }
  IFS= read -r head <&8 || { exec 8<&-; return 2; }
  IFS= read -r authority <&8 || { exec 8<&-; return 2; }
  IFS= read -r epoch <&8 || { exec 8<&-; return 2; }
  IFS= read -r state <&8 || { exec 8<&-; return 2; }
  IFS= read -r run <&8 || { exec 8<&-; return 2; }
  IFS= read -r sender <&8 || { exec 8<&-; return 2; }
  IFS= read -r base <&8 || { exec 8<&-; return 2; }
  IFS= read -r base_sha <&8 || { exec 8<&-; return 2; }
  if IFS= read -r extra <&8; then
    exec 8<&-
    return 2
  fi
  exec 8<&-
  [ "$version" = fm-self-land-pending-v1 ] || return 2
  _fm_self_land_pending_valid "$id" "$url" "$head" "$authority" "$epoch" "$state" "$run" "$sender" \
    "$base" "$base_sha" || return 2
  FM_SELF_LAND_PENDING_ID=$id
  FM_SELF_LAND_PENDING_URL=$url
  FM_SELF_LAND_PENDING_HEAD=$head
  FM_SELF_LAND_PENDING_AUTHORITY=$authority
  FM_SELF_LAND_PENDING_EPOCH=$epoch
  FM_SELF_LAND_PENDING_STATE=$state
  FM_SELF_LAND_PENDING_RUN=$run
  FM_SELF_LAND_PENDING_SENDER=$sender
  FM_SELF_LAND_PENDING_BASE=$base
  FM_SELF_LAND_PENDING_BASE_SHA=$base_sha
  return 0
}

# Change the record of run <run> from state <from> to state <to> and restart
# its clock. <to> can equal <from>, which only restarts the clock. With <to>
# given as `none`, remove the record instead. With [sender] given, the record
# names that sender from now on; otherwise it keeps the one it has. The record
# keeps its authority: only fm_self_land_send_record sets it.
# Returns 0 when the change was made, 1 when the record is absent, belongs to
# another run, or is in another state, and 2 when it could not be locked, read,
# or written.
fm_self_land_pending_change() {  # <repo-dir> <run> <from> <to> [sender]
  local dir=${1-} run=${2-} from=${3-} to=${4-} sender=${5-} lock rc=0 epoch
  [ -n "$dir" ] && [ -n "$run" ] && [ -n "$from" ] && [ -n "$to" ] || return 2
  lock="$dir/pending.lock"
  fm_lock_acquire_wait_max "$lock" 30 || return 2
  fm_self_land_pending_read "$dir" || rc=$?
  if [ "$rc" -eq 0 ]; then
    if [ "$FM_SELF_LAND_PENDING_RUN" != "$run" ] || [ "$FM_SELF_LAND_PENDING_STATE" != "$from" ]; then
      rc=1
    elif [ "$to" = none ]; then
      rm -f -- "$dir/pending" || rc=2
    elif epoch=$(date +%s) && _fm_self_land_pending_store "$dir" \
        "$FM_SELF_LAND_PENDING_ID" "$FM_SELF_LAND_PENDING_URL" "$FM_SELF_LAND_PENDING_HEAD" \
        "$FM_SELF_LAND_PENDING_AUTHORITY" "$epoch" "$to" "$run" \
        "${sender:-$FM_SELF_LAND_PENDING_SENDER}" \
        "$FM_SELF_LAND_PENDING_BASE" "$FM_SELF_LAND_PENDING_BASE_SHA"; then
      :
    else
      rc=2
    fi
  fi
  fm_lock_release "$lock" || true
  return "$rc"
}

# Record that run <run> sends its merge command now, under <authority>: the
# armed record of that run becomes sent, names <sender>, and carries that
# authority. The stored record of the same pull request is retired first, so
# the authority of an earlier request cannot label the merge of this send. The
# retirement happens only for a run whose own armed record is still there.
# Returns 0 when the send was recorded, 1 when the record is absent, belongs to
# another run, or is not armed, and 2 when a record could not be locked, read,
# retired, or written. On 1 or 2 the caller sends no merge.
fm_self_land_send_record() {  # <state> <repo-dir> <run> <sender> <authority> <task-id> <provider> <host> <path> <number>
  local state=${1-} dir=${2-} run=${3-} sender=${4-} authority=${5-} lock rc=0 epoch
  [ -n "$state" ] && [ -n "$dir" ] && [ -n "$run" ] && [ -n "$sender" ] && [ -n "$authority" ] || return 2
  lock="$dir/pending.lock"
  fm_lock_acquire_wait_max "$lock" 30 || return 2
  fm_self_land_pending_read "$dir" || rc=$?
  if [ "$rc" -eq 0 ]; then
    if [ "$FM_SELF_LAND_PENDING_RUN" != "$run" ] || [ "$FM_SELF_LAND_PENDING_STATE" != armed ]; then
      rc=1
    elif fm_merge_authority_retire "$state" "${6-}" "${7-}" "${8-}" "${9-}" "${10-}" \
      && epoch=$(date +%s) && _fm_self_land_pending_store "$dir" \
        "$FM_SELF_LAND_PENDING_ID" "$FM_SELF_LAND_PENDING_URL" "$FM_SELF_LAND_PENDING_HEAD" \
        "$authority" "$epoch" sent "$run" "$sender" \
        "$FM_SELF_LAND_PENDING_BASE" "$FM_SELF_LAND_PENDING_BASE_SHA"; then
      :
    else
      rc=2
    fi
  fi
  fm_lock_release "$lock" || true
  return "$rc"
}

# Remove the record without a state check. Only the run that holds the
# repository lock and knows the outcome of the record's merge calls this.
fm_self_land_pending_clear() {  # <repo-dir>
  [ -n "${1-}" ] || return 1
  rm -f -- "$1/pending"
}
