#!/usr/bin/env bash
# shellcheck disable=SC2034 # FM_LIFECYCLE_* output globals are read by sourcing callers.
# fm-lifecycle-lib.sh - the shared implementation of Firstmate's non-force
# task-retirement policy: the refusal guards a task must pass before cleanup and
# the per-task retirement steps that follow them. bin/fm-teardown.sh's header
# remains the owner of what that policy is and why; bin/fm-teardown.sh sources
# this file for ordinary teardown. Every guard and step here takes its home,
# state, task, and record as explicit arguments and reports through
# FM_LIFECYCLE_* globals, so a second caller reuses the same code instead of
# copying it.
#
# Sourcing contract: sourcing defines functions and constants only. It creates
# no file, lock, or directory, installs no trap, probes no runtime, starts no
# agent, and changes no shell option. The functions call owners the caller has
# already sourced (bin/fm-backlog-transition-lib.sh, bin/fm-wake-lib.sh,
# bin/fm-lock-lib.sh, bin/fm-pr-lib.sh, bin/fm-nm-run-lib.sh,
# bin/fm-control-lib.sh, bin/fm-classify-lib.sh, bin/fm-backend.sh,
# bin/fm-public-followup-lib.sh, bin/fm-secondmate-registry-lib.sh,
# bin/fm-secondmate-parent-lib.sh, bin/fm-env-lib.sh); a caller that finds this
# file missing or FM_LIFECYCLE_API_VERSION different from the version it was
# written for refuses before any side effect.
#
# None of these functions has a force, discard, or legacy-record mode: those
# are bin/fm-teardown.sh's own paths and stay there.
#
# Endpoint retirement (inspect, retire, and result) is owned by bin/fm-lifecycle-retire-lib.sh, which this file sources.
# That header is the contract for the request, the proof, the journal, the lock order, and the return codes.
# Sourcing this file still creates no state.

FM_LIFECYCLE_API_VERSION=1
FM_LIFECYCLE_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_LIFECYCLE_TREEHOUSE_LOCK_REFUSED=2
FM_LIFECYCLE_WORKTREE_SAFETY_LOCK_BLOCKED=3
FM_LIFECYCLE_SLOT_REASSIGNED_RC=3

# --- backlog disposition ------------------------------------------------------

# fm_lifecycle_backlog_applies <config> <data> <kind>: 0 when the automatic
# backlog transition applies to this task, 1 when it is skipped
# (FM_LIFECYCLE_BACKLOG_SKIP_REASON), 2 when the backlog data directory is
# inaccessible (FM_LIFECYCLE_BACKLOG_ERROR; the caller owns the refusal).
fm_lifecycle_backlog_applies() {
  local config=$1 data=$2 kind=$3 status=0
  FM_LIFECYCLE_BACKLOG_SKIP_REASON=
  FM_LIFECYCLE_BACKLOG_ERROR=
  fm_backlog_transition_applies "$config" "$data" "$kind" && return 0
  status=$?
  if [ "$status" -eq 2 ]; then
    FM_LIFECYCLE_BACKLOG_ERROR=$FM_BACKLOG_TRANSITION_ERROR
    return 2
  fi
  FM_LIFECYCLE_BACKLOG_SKIP_REASON=$FM_BACKLOG_TRANSITION_SKIP
  return 1
}

# fm_lifecycle_captain_hold_disposition <home> <state> <data> <config> <task-id>:
# cleanup never closes a captain call. Sets FM_LIFECYCLE_BACKLOG_TRANSITION to
# retain while the item is still held for the captain, else close; prints the
# refusal and returns 1 when that cannot be read (bin/fm-captain-hold.sh `open`
# owns the 0/1/2 predicate).
fm_lifecycle_captain_hold_disposition() {
  local home=$1 state=$2 data=$3 config=$4 id=$5 status=0 out
  FM_LIFECYCLE_BACKLOG_TRANSITION=close
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$FM_LIFECYCLE_LIB_DIR/fm-captain-hold.sh" open "$id" 2>&1) || status=$?
  case "$status" in
    0) FM_LIFECYCLE_BACKLOG_TRANSITION=retain ;;
    1) ;;
    *)
      echo "error: task $id cannot be torn down because whether its backlog item is still held for the captain could not be read; fix that read and retry rather than risk closing a captain call with no recorded answer" >&2
      [ -z "$out" ] || printf '%s\n' "$out" >&2
      return 1
      ;;
  esac
}

# fm_lifecycle_backlog_done_args <kind> <mode> <pr-url> <data> <task-id>: the
# completion links the record already holds (FM_LIFECYCLE_DONE_ARGS). A scout's
# deliverable is its report, a local-only ship lands on local main, and every
# other ship carries the PR recorded on its own record.
fm_lifecycle_backlog_done_args() {
  local kind=$1 mode=$2 pr_url=$3 data=$4 id=$5 data_relative
  FM_LIFECYCLE_DONE_ARGS=()
  case "$kind" in
    scout)
      data_relative=$(fm_backlog_data_relative "$data") || return 1
      FM_LIFECYCLE_DONE_ARGS=(--report "$data_relative/$id/report.md")
      ;;
    *)
      if [ "$mode" = local-only ]; then
        FM_LIFECYCLE_DONE_ARGS=(--note "local main")
      elif [ -n "$pr_url" ]; then
        FM_LIFECYCLE_DONE_ARGS=(--pr "$pr_url")
      fi
      ;;
  esac
}

# fm_lifecycle_record_retire <state> <data> <task-id> <close|retain|remove> <close-marker-or-empty> [done-args...]:
# removes the task record, fused with its pending backlog transition for close
# and retain (bin/fm-backlog-transition-lib.sh owns the invariant and the
# pending-close record at <close-marker>; remove takes an empty marker). Returns
# nonzero when the atomic transition fails (FM_BACKLOG_TRANSITION_ERROR); the
# caller owns the message.
fm_lifecycle_record_retire() {
  local state=$1 data=$2 id=$3 transition=$4 marker=$5
  shift 5
  if [ "$transition" = remove ]; then
    fm_backlog_atomic_transition remove "$state/$id.meta" "task record" "$state"
    return
  fi
  fm_backlog_atomic_transition "$transition" "$state/$id.meta" "$marker" \
    "$data" "$id" "$state" "$@"
}

# --- obligation guards --------------------------------------------------------

# fm_lifecycle_pending_replies_unresolved_refuse <state> <task-id>: refuse a
# secondmate's retirement while any parent pending-reply for it is unresolved.
fm_lifecycle_pending_replies_unresolved_refuse() {
  local state=$1 id=$2 rec task_id phase
  [ -d "$state/pending-replies" ] || return 0
  for rec in "$state/pending-replies"/*; do
    [ -f "$rec" ] || continue
    task_id=$(fm_meta_get "$rec" task_id)
    [ "$task_id" = "$id" ] || continue
    phase=$(fm_meta_get "$rec" phase)
    [ "$phase" = resolved ] || {
      echo "REFUSED: secondmate $id still has an unresolved routed reply" >&2
      return 1
    }
  done
  return 0
}

# fm_lifecycle_secondmate_children_refuse <secondmate-home> <task-id>: refuse a
# non-force secondmate retirement while its home still holds any task record.
fm_lifecycle_secondmate_children_refuse() {
  local sub_state="$1/state" id=$2 child_meta
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    echo "REFUSED: secondmate $id still has in-flight work in $sub_state." >&2
    echo "Found $(basename "$child_meta"). Let that home finish or explicitly discard with --force." >&2
    return 1
  done
}

# fm_lifecycle_scout_complete <home> <state> <data> <config> <task-id>: a scout's
# report is its work product; refuse until it exists and the shared
# unresolved-decision completion gate verifies its captain-held inventory.
fm_lifecycle_scout_complete() {
  local home=$1 state=$2 data=$3 config=$4 id=$5 report
  report="$data/$id/report.md"
  if [ ! -f "$report" ]; then
    echo "REFUSED: scout task $id has no report at $report." >&2
    echo "The report is the work product. Have the crewmate write it, or use --force after explicit discard approval." >&2
    return 1
  fi
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
      FM_CONFIG_OVERRIDE="$config" "$FM_LIFECYCLE_LIB_DIR/fm-captain-hold.sh" verify "$id" >/dev/null; then
    echo "REFUSED: scout task $id has not passed the captain-call completion gate." >&2
    echo "Inventory its report and any visual review through bin/fm-captain-hold.sh before teardown." >&2
    return 1
  fi
}

fm_lifecycle_public_followup_canonical_home() {
  local home=$1
  case "$home" in /*) ;; *) return 1 ;; esac
  CDPATH='' cd -- "$home" 2>/dev/null && pwd -P
}

fm_lifecycle_public_followup_resolve_primary_home() {
  local parent=$1 child=$2 id=$3 parent_meta registry meta_home
  fm_pf_home_id_valid "secondmate:$id" || return 1
  parent=$(fm_lifecycle_public_followup_canonical_home "$parent") || return 1
  child=$(fm_lifecycle_public_followup_canonical_home "$child") || return 1
  [ "$parent" != "$child" ] || return 1
  parent_meta="$parent/state/$id.meta"
  [ -f "$parent_meta" ] && [ ! -L "$parent_meta" ] || return 1
  [ "$(fm_meta_get "$parent_meta" kind)" = secondmate ] || return 1
  meta_home=$(fm_meta_get "$parent_meta" home)
  meta_home=$(CDPATH='' cd -- "$meta_home" 2>/dev/null && pwd -P) || return 1
  [ "$meta_home" = "$child" ] || return 1
  registry="$parent/data/secondmates.md"
  secondmate_registry_validate_bindings "$registry" secondmate_registry_path_key "$id" "$child" || return 1
  printf '%s\n' "$parent"
}

# fm_lifecycle_public_followup_resolve <home> <state> <task-id> <kind> <evaluate-relay 0|1>:
# resolve which home holds this work's promised public replies and whether its
# relay is active. <evaluate-relay> 0 leaves FM_LIFECYCLE_PF_RELAY_ACTIVE at 0
# (teardown's --force skips that read). Outputs: FM_LIFECYCLE_PF_HOME,
# FM_LIFECYCLE_PF_STATE, FM_LIFECYCLE_PF_WORK_HOME, FM_LIFECYCLE_PF_PARENT_UNRESOLVED,
# FM_LIFECYCLE_PF_PARENT_RELAY_ACTIVE, FM_LIFECYCLE_PF_RELAY_ACTIVE,
# FM_LIFECYCLE_PF_SECOND_MATE_ID. A home seeded before the durable parent record
# existed keeps its launch-time FM_PUBLIC_FOLLOWUP_PRIMARY_HOME binding.
fm_lifecycle_public_followup_resolve() {
  local home=$1 state=$2 id=$3 kind=$4 evaluate_relay=$5
  local parent_route_file parent_route_record parent_route parent_route_home
  local home_env_token primary_home_candidate parent_bindings_match live_parent_home durable_parent_home
  FM_LIFECYCLE_PF_HOME=$home
  FM_LIFECYCLE_PF_STATE=$state
  FM_LIFECYCLE_PF_WORK_HOME=main
  FM_LIFECYCLE_PF_PARENT_UNRESOLVED=0
  FM_LIFECYCLE_PF_PARENT_RELAY_ACTIVE=0
  FM_LIFECYCLE_PF_RELAY_ACTIVE=0
  FM_LIFECYCLE_PF_SECOND_MATE_ID=
  if [ -f "$home/.fm-secondmate-home" ]; then
    FM_LIFECYCLE_PF_SECOND_MATE_ID=$(sed -n '1p' "$home/.fm-secondmate-home") || return
    # The durable parent record (written once at seeding, next to the identity
    # marker) names this home's route to its parent: "local" when they share a
    # filesystem, "remote" when the parent lives on another machine. Absent for
    # a home seeded before this record existed, which preserves today's exact
    # env-var-only behavior for that legacy home rather than guessing its route.
    parent_route_file="$home/.fm-secondmate-parent"
    parent_route_record=absent
    parent_route=
    parent_route_home=
    if [ -e "$parent_route_file" ] || [ -L "$parent_route_file" ]; then
      parent_route_record=invalid
      if fm_secondmate_parent_record_parse "$parent_route_file"; then
        parent_route=$FM_SECONDMATE_PARENT_ROUTE
        parent_route_home=$FM_SECONDMATE_PARENT_HOME
        parent_route_record=valid
      fi
    fi
    if [ "$parent_route_record" = invalid ]; then
      FM_LIFECYCLE_PF_PARENT_UNRESOLVED=1
    elif [ "$parent_route" = remote ]; then
      # The entire promised-public-reply subsystem is same-filesystem by
      # construction (bin/fm-public-followup-emit.sh header): a parent recorded
      # on another machine can never hold a delegated promise for this child, so
      # the delegated-parent path is out of scope and never refuses cleanup on
      # its own. A token committed directly to THIS home's own .env is still a
      # real, same-filesystem signal, so it is still checked - but read only
      # from the file, never from the process environment, so an unrelated
      # export in the remote host's own login shell cannot trigger it the way
      # fm_pf_relay_active's environment-wins rule would.
      if [ -f "$home/.env" ]; then
        home_env_token=$(fmx_env_get FMX_PAIRING_TOKEN "$home/.env") || return
        [ -z "$home_env_token" ] || FM_LIFECYCLE_PF_PARENT_RELAY_ACTIVE=1
      fi
      if [ "$FM_LIFECYCLE_PF_PARENT_RELAY_ACTIVE" = 1 ]; then
        FM_LIFECYCLE_PF_PARENT_UNRESOLVED=1
      else
        FM_LIFECYCLE_PF_HOME=
        FM_LIFECYCLE_PF_STATE=
      fi
    elif [ "$parent_route" = local ]; then
      FM_LIFECYCLE_PF_PARENT_UNRESOLVED=1
      primary_home_candidate=${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-$parent_route_home}
      parent_bindings_match=1
      if [ -n "${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-}" ]; then
        live_parent_home=$(fm_lifecycle_public_followup_canonical_home \
          "$FM_PUBLIC_FOLLOWUP_PRIMARY_HOME") || parent_bindings_match=0
        durable_parent_home=$(fm_lifecycle_public_followup_canonical_home \
          "$parent_route_home") || parent_bindings_match=0
        if [ "$parent_bindings_match" = 1 ] \
          && [ "$live_parent_home" != "$durable_parent_home" ]; then
          parent_bindings_match=0
        fi
      fi
      if [ "$parent_bindings_match" = 1 ] \
        && fm_pf_home_id_valid "secondmate:$FM_LIFECYCLE_PF_SECOND_MATE_ID"; then
        FM_LIFECYCLE_PF_WORK_HOME="secondmate:$FM_LIFECYCLE_PF_SECOND_MATE_ID"
        if FM_LIFECYCLE_PF_HOME=$(fm_lifecycle_public_followup_resolve_primary_home \
            "$primary_home_candidate" "$home" "$FM_LIFECYCLE_PF_SECOND_MATE_ID"); then
          FM_LIFECYCLE_PF_STATE="$FM_LIFECYCLE_PF_HOME/state"
          FM_LIFECYCLE_PF_PARENT_UNRESOLVED=0
          if [ "$evaluate_relay" = 1 ] \
            && fm_pf_relay_active "$FM_LIFECYCLE_PF_HOME"; then
            FM_LIFECYCLE_PF_RELAY_ACTIVE=1
          fi
        else
          FM_LIFECYCLE_PF_HOME=
          FM_LIFECYCLE_PF_STATE=
        fi
      fi
    else
      # A home seeded before the durable record existed retains the legacy
      # launch-time binding behavior unchanged.
      primary_home_candidate=${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-}
      if [ -n "$primary_home_candidate" ]; then
        if fm_pf_relay_active "$primary_home_candidate"; then
          FM_LIFECYCLE_PF_PARENT_RELAY_ACTIVE=1
        fi
      elif fm_pf_relay_active "$home"; then
        FM_LIFECYCLE_PF_PARENT_RELAY_ACTIVE=1
      fi
      if [ "$FM_LIFECYCLE_PF_PARENT_RELAY_ACTIVE" = 1 ]; then
        FM_LIFECYCLE_PF_PARENT_UNRESOLVED=1
        if fm_pf_home_id_valid "secondmate:$FM_LIFECYCLE_PF_SECOND_MATE_ID"; then
          FM_LIFECYCLE_PF_WORK_HOME="secondmate:$FM_LIFECYCLE_PF_SECOND_MATE_ID"
          if FM_LIFECYCLE_PF_HOME=$(fm_lifecycle_public_followup_resolve_primary_home \
              "$primary_home_candidate" "$home" "$FM_LIFECYCLE_PF_SECOND_MATE_ID"); then
            FM_LIFECYCLE_PF_STATE="$FM_LIFECYCLE_PF_HOME/state"
            FM_LIFECYCLE_PF_PARENT_UNRESOLVED=0
            if [ "$evaluate_relay" = 1 ] \
              && fm_pf_relay_active "$FM_LIFECYCLE_PF_HOME"; then
              FM_LIFECYCLE_PF_RELAY_ACTIVE=1
            fi
          else
            FM_LIFECYCLE_PF_HOME=
            FM_LIFECYCLE_PF_STATE=
          fi
        fi
      else
        FM_LIFECYCLE_PF_HOME=
        FM_LIFECYCLE_PF_STATE=
      fi
    fi
  elif [ "$kind" = secondmate ]; then
    FM_LIFECYCLE_PF_WORK_HOME="secondmate:$id"
    if [ "$evaluate_relay" = 1 ] && fm_pf_relay_active "$home"; then
      FM_LIFECYCLE_PF_RELAY_ACTIVE=1
    fi
  elif [ "$evaluate_relay" = 1 ] && fm_pf_relay_active "$home"; then
    FM_LIFECYCLE_PF_RELAY_ACTIVE=1
  fi
}

# fm_lifecycle_public_followup_refuse <task-id>: after
# fm_lifecycle_public_followup_resolve, refuse while the work's durable parent
# binding cannot be resolved or this home still owes a public reply for exactly
# this work. A public commitment is kept only when its final reply lands in the
# ORIGINAL thread, and cleanup removes the records that make it reconcilable.
fm_lifecycle_public_followup_refuse() {
  local id=$1 blocking
  if [ "$FM_LIFECYCLE_PF_PARENT_UNRESOLVED" = 1 ]; then
    echo "REFUSED: cannot resolve the primary home for marked secondmate $FM_LIFECYCLE_PF_SECOND_MATE_ID; refusing cleanup without its durable parent binding." >&2
    return 1
  fi
  if [ -n "$FM_LIFECYCLE_PF_STATE" ] \
    && [ "$FM_LIFECYCLE_PF_RELAY_ACTIVE" = 1 ] \
    && fm_pf_has_registrations "$FM_LIFECYCLE_PF_STATE"; then
    if ! blocking=$(FM_HOME="$FM_LIFECYCLE_PF_HOME" FM_STATE_OVERRIDE="$FM_LIFECYCLE_PF_STATE" \
        "$FM_LIFECYCLE_LIB_DIR/fm-public-followup.sh" guard-work "$FM_LIFECYCLE_PF_WORK_HOME" "$id" 2>/dev/null); then
      echo "REFUSED: task $id still owes a public reply through the myfirstmate relay." >&2
      printf '%s\n' "$blocking" >&2
      echo "Deliver it with bin/fm-public-followup.sh deliver <obligation-id>, waive it with bin/fm-tasks-axi.sh public-followup waive, or use --force after explicit discard approval." >&2
      return 1
    fi
  fi
}

# fm_lifecycle_public_followup_warn <task-id> <kind> <pr-url> <meta>: the two
# non-blocking warnings - an open public loop with nothing owed while cleaning
# up a merged ship, and a legacy Relay link still on the record.
fm_lifecycle_public_followup_warn() {
  local id=$1 kind=$2 pr_url=$3 meta=$4 x_request
  if [ "$kind" = ship ] && [ -n "$pr_url" ] \
      && [ -n "$FM_LIFECYCLE_PF_STATE" ] \
      && [ "${FM_LIFECYCLE_PF_RELAY_ACTIVE:-0}" = 1 ] \
      && fm_pf_has_delivered_open_loops "$FM_LIFECYCLE_PF_STATE"; then
    echo "warning: an open public loop with nothing owed is still recorded in the consent-holding home while cleaning up ship task $id. Hand it on with bin/fm-public-followup.sh rechain or close it with retire --reason." >&2
  fi
  x_request=$(grep '^x_request=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  if [ -n "$x_request" ]; then
    echo "warning: task $id still carries an unreconciled Relay request link ($x_request) on its task record." >&2
  fi
}

# fm_lifecycle_public_followup_guard <task-id> <kind> <pr-url> <meta>: the
# non-force public follow-up guard - its refusals, then its two warnings. A
# caller with explicit authority to skip the refusals (teardown's --force)
# calls fm_lifecycle_public_followup_warn alone. A caller running under set -e
# that must stop when a warning cannot be written calls refuse and warn as
# separate plain commands, as bin/fm-teardown.sh does, because a function run
# as the left side of || executes with errexit suspended.
fm_lifecycle_public_followup_guard() {
  fm_lifecycle_public_followup_refuse "$1" || return 1
  fm_lifecycle_public_followup_warn "$1" "$2" "$3" "$4"
}

# --- PR-check artifacts -------------------------------------------------------

fm_lifecycle_validate_pr_poll_cleanup() {  # <state> <task-id>
  local state_dir=$1 id=$2 state_device artifact has_artifact=0
  fm_task_id_path_safe "$id" || return 0
  for artifact in "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.merge-authority" "$state_dir/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    has_artifact=1
  done
  [ "$has_artifact" -eq 1 ] || return 0
  [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || return 1
  state_device=$(fm_pr_file_device "$state_dir") || return 1
  for artifact in "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.merge-authority" "$state_dir/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if [ ! -f "$artifact" ] || [ -L "$artifact" ] \
      || [ "$(fm_pr_file_device "$artifact")" != "$state_device" ] \
      || [ "$(fm_pr_file_link_count "$artifact")" != 1 ] \
      || { [ "$artifact" = "$state_dir/$id.merge-authority" ] \
        && [ "$(fm_pr_file_mode "$artifact")" != 600 ]; }; then
      echo "REFUSED: unsafe task PR-check artifact; preserving task state." >&2
      return 1
    fi
  done
  if [ -e "$state_dir/$id.pr-poll-retirement" ] \
    || [ -L "$state_dir/$id.pr-poll-retirement" ]; then
    fm_pr_poll_retirement_state_valid "$state_dir" "$id" || {
      echo "REFUSED: invalid PR-poll retirement receipt; preserving task state." >&2
      return 1
    }
  fi
}

fm_lifecycle_remove_pr_poll_artifacts() {  # <state> <task-id>
  local state_dir=$1 id=$2
  fm_lifecycle_validate_pr_poll_cleanup "$state_dir" "$id" || return 1
  fm_pr_poll_retirement_recover_one "$state_dir" "$id" "$FM_LIFECYCLE_LIB_DIR/fm-pr-poll.sh" || return 1
  fm_pr_poll_merge_notified_remove "$state_dir" "$id" || return 1
  rm -f "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.merge-authority" "$state_dir/$id.check-trust" || return 1
}

# --- worktree-slot ownership ---------------------------------------------------

fm_lifecycle_canonical_existing_dir() {  # <dir>
  local target=$1
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  ( cd "$target" && pwd -P )
}

# fm_lifecycle_live_slot_path <kind> <project> <worktree>: the task's own live
# Treehouse slot, canonicalized, or nonzero when the record has no slot to
# release (a secondmate home, no worktree=, or a path already gone). Every
# slot-ownership check is scoped to that value.
fm_lifecycle_live_slot_path() {
  [ "$1" != secondmate ] || return 1
  fm_treehouse_pool_slot "$2" "$3" || return 1
  fm_lifecycle_canonical_existing_dir "$3"
}

# fm_lifecycle_collect_local_firstmate_states <home> <record-state>: the state
# directories of the local root Firstmate home and every locally registered
# home beneath it (FM_LIFECYCLE_OWNER_STATES), starting with <record-state>.
fm_lifecycle_collect_local_firstmate_states() {
  local start_home=$1 record_state=$2 root home reg line child known existing i=0
  local -a homes
  FM_LIFECYCLE_OWNER_STATES=("$record_state")
  root=$(fm_firstmate_root_home "$start_home") || {
    echo "REFUSED: cannot resolve the root Firstmate home; nothing was changed" >&2
    return 1
  }
  homes=("$root")
  while [ "$i" -lt "${#homes[@]}" ]; do
    home=${homes[$i]}
    i=$((i + 1))
    known=0
    for existing in "${FM_LIFECYCLE_OWNER_STATES[@]}"; do
      [ "$existing" != "$home/state" ] || known=1
    done
    [ "$known" = 1 ] || FM_LIFECYCLE_OWNER_STATES+=("$home/state")
    reg="$home/data/secondmates.md"
    [ ! -e "$reg" ] && [ ! -L "$reg" ] && continue
    [ -f "$reg" ] && [ ! -L "$reg" ] || {
      echo "REFUSED: local Firstmate registry is unsafe at $reg; nothing was changed" >&2
      return 1
    }
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "- "*)
          secondmate_registry_parse_line "$line" || {
            echo "REFUSED: malformed local Firstmate registry entry in $reg; nothing was changed" >&2
            return 1
          }
          [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || continue
          child=$(fm_lifecycle_canonical_existing_dir "$SECONDMATE_REGISTRY_HOME") || {
            echo "REFUSED: registered local Firstmate home is unavailable: $SECONDMATE_REGISTRY_HOME; nothing was changed" >&2
            return 1
          }
          known=0
          for existing in "${homes[@]}"; do
            [ "$existing" != "$child" ] || known=1
          done
          [ "$known" = 1 ] || homes+=("$child")
          ;;
      esac
    done < "$reg"
  done
}

# fm_lifecycle_require_exclusive_slot_record <home> <meta> <task-id> <state> <worktree>:
# refuse when any OTHER task record in this or any locally registered home names
# the same live path in worktree= or home= (bin/fm-teardown.sh header,
# "Worktree-slot ownership"). Skipped when the slot's owner claim names another
# task, because that teardown is records-only.
fm_lifecycle_require_exclusive_slot_record() {
  local home=$1 record_meta=$2 record_id=$3 record_state=$4 worktree=$5
  local slot state_dir other other_id field other_path other_slot
  slot=$(fm_lifecycle_canonical_existing_dir "$worktree") || return 0
  # A slot whose owner claim names another task was reassigned, so this record's
  # teardown is records-only and touches nothing under it; another record naming
  # the slot is then no hazard, and refusing would strand this stale record and
  # block the claimant's own teardown behind it.
  fm_treehouse_slot_owner_state "$slot" "$record_id"
  [ "$FM_TREEHOUSE_SLOT_OWNER" != other ] || return 0
  fm_lifecycle_collect_local_firstmate_states "$home" "$record_state" || return 1
  for state_dir in "${FM_LIFECYCLE_OWNER_STATES[@]}"; do
    for other in "$state_dir"/*.meta; do
      [ -f "$other" ] && [ ! -L "$other" ] || continue
      # Identity, not spelling: the same record reached through a differently
      # resolved state dir (e.g. a symlinked $FM_HOME) is still this record. A
      # differently named hardlink is another task's record, so the name must
      # match too.
      [ "${other##*/}" = "${record_meta##*/}" ] && [ "$other" -ef "$record_meta" ] && continue
      other_id=$(basename "$other" .meta)
      for field in worktree home; do
        other_path=$(fm_meta_get "$other" "$field")
        [ -n "$other_path" ] || continue
        other_slot=$(fm_lifecycle_canonical_existing_dir "$other_path") || continue
        [ "$other_slot" = "$slot" ] || continue
        echo "REFUSED: task $record_id's recorded worktree $slot is also task $other_id's recorded $field." >&2
        echo "Returning that pool slot would kill $other_id's processes and reset its copy, so nothing was changed - not even with --force." >&2
        echo "Reconcile whichever record is wrong (bin/fm-crew-state.sh $record_id; bin/fm-crew-state.sh $other_id), then re-run teardown." >&2
        return 1
      done
    done
  done
}

# fm_lifecycle_require_owned_slot_record <task-id> <worktree>: positive slot
# ownership from the claim the task that took the slot wrote into it
# (bin/fm-wake-lib.sh owns the claim and its states). 0 for a slot this task
# claims or that carries no claim, FM_LIFECYCLE_SLOT_REASSIGNED_RC when another
# task claims it (FM_TREEHOUSE_SLOT_OWNER_ID and FM_TREEHOUSE_SLOT_OWNER_HOME
# name it), and 1 after the refusal for a claim that cannot be read.
fm_lifecycle_require_owned_slot_record() {
  local record_id=$1 worktree=$2 marker
  fm_treehouse_slot_owner_state "$worktree" "$record_id"
  case "$FM_TREEHOUSE_SLOT_OWNER" in
    mine|absent) return 0 ;;
    other)
      echo "warning: task $record_id's recorded worktree $worktree was reassigned to task $FM_TREEHOUSE_SLOT_OWNER_ID${FM_TREEHOUSE_SLOT_OWNER_HOME:+ (home $FM_TREEHOUSE_SLOT_OWNER_HOME)}, which claimed that pool slot after this record was written; that slot is no longer $record_id's, so its processes, copy, and claim are left untouched and only $record_id's own cleanup runs." >&2
      return "$FM_LIFECYCLE_SLOT_REASSIGNED_RC"
      ;;
  esac
  marker=$(fm_treehouse_slot_owner_marker "$worktree" 2>/dev/null) || marker="beside $worktree"
  echo "REFUSED: task $record_id's recorded worktree $worktree carries a slot-owner claim that cannot be read, so the slot cannot be proved to still be this task's; nothing was changed - not even with --force." >&2
  echo "Inspect or repair the claim file at $marker (task= and home= lines), then re-run teardown." >&2
  return 1
}

# --- unlanded-work gate ------------------------------------------------------

fm_lifecycle_default_branch() {  # <project>
  local project=$1 ref branch
  ref=$(git -C "$project" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$project" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

# Resolve the PR number for a worktree branch via gh-axi. Echoes the number on a
# single match and returns 0; returns non-zero on no match or any lookup failure,
# so the caller treats it as "no PR found" (fail-safe).
fm_lifecycle_pr_number_from_branch() {  # <wt> <branch>
  local wt=$1 branch=$2 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  out=$( cd "$wt" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null ) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

fm_lifecycle_pr_number_from_target() {  # <target>
  local target=$1 n
  case "$target" in
    '' ) return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

fm_lifecycle_ensure_commit_object() {  # <wt> <target> <commit>
  local wt=$1 target=$2 commit=$3 n
  git -C "$wt" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  n=$(fm_lifecycle_pr_number_from_target "$target") || return 1
  git -C "$wt" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$wt" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  git -C "$wt" cat-file -e "$commit^{commit}" 2>/dev/null
}

fm_lifecycle_patch_id_for_commit() {  # <wt> <commit>
  local wt=$1 commit=$2
  git -C "$wt" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
    | git patch-id --stable 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

fm_lifecycle_unpushed_patches_are_in_pr_head() {  # <wt> <pr-head>
  local wt=$1 pr_head=$2 current base pr_patch_ids commit patch_id unpushed
  current=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || return 1
  base=$(git -C "$wt" merge-base "$current" "$pr_head" 2>/dev/null) || return 1
  pr_patch_ids=$(
    git -C "$wt" log --format=%H "$base..$pr_head" -- 2>/dev/null \
      | while IFS= read -r commit; do
          fm_lifecycle_patch_id_for_commit "$wt" "$commit"
        done \
      | sed '/^$/d' \
      | sort -u
  ) || return 1
  [ -n "$pr_patch_ids" ] || return 1
  unpushed=$(git -C "$wt" log --format=%H HEAD --not --remotes -- 2>/dev/null) || return 1
  [ -n "$unpushed" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    patch_id=$(fm_lifecycle_patch_id_for_commit "$wt" "$commit") || return 1
    [ -n "$patch_id" ] || return 1
    printf '%s\n' "$pr_patch_ids" | grep -qxF "$patch_id" || return 1
  done <<EOF
$unpushed
EOF
}

# Is the worktree's PR merged for local work contained in that PR? Resolves the
# PR from the recorded pr= URL first, then from the branch name, and asks GitHub
# for both the PR state and head. Returns non-zero when the PR is not merged, the
# current work is not contained in the PR head, no PR is found, or any gh error
# occurs - the caller then falls back to the content check. When no pr= was
# recorded, success also sets FM_LIFECYCLE_PR_URL to the PR it resolved.
fm_lifecycle_pr_is_merged() {  # <wt> <pr-url> <branch>
  local wt=$1 pr_url=$2 branch=$3 target view state remainder head resolved_url current landed=0
  if [ -n "$pr_url" ]; then
    target=$pr_url
  else
    target=$(fm_lifecycle_pr_number_from_branch "$wt" "$branch") || return 1
  fi
  [ -n "$target" ] || return 1
  view=$(cd "$wt" && gh pr view "$target" --json state,headRefOid,url -q '.state + "\t" + .headRefOid + "\t" + .url' 2>/dev/null) || return 1
  state=${view%%$'\t'*}
  remainder=${view#*$'\t'}
  [ "$state" != "$view" ] || return 1
  head=${remainder%%$'\t'*}
  resolved_url=${remainder#*$'\t'}
  [ "$head" != "$remainder" ] || return 1
  case "$state" in
    MERGED|merged) ;;
    *) return 1 ;;
  esac
  [ -n "$head" ] || return 1
  fm_lifecycle_ensure_commit_object "$wt" "$target" "$head" || return 1
  current=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || return 1
  if git -C "$wt" merge-base --is-ancestor "$current" "$head" 2>/dev/null; then
    landed=1
  elif fm_lifecycle_unpushed_patches_are_in_pr_head "$wt" "$head"; then
    landed=1
  fi
  [ "$landed" = 1 ] || return 1
  if [ -z "$pr_url" ]; then
    [ -n "$resolved_url" ] || return 1
    FM_LIFECYCLE_PR_URL=$resolved_url
  fi
  return 0
}

# Is the branch's content already present in the up-to-date default (or base)
# branch? Fetches first, then 3-way merges that branch with HEAD: when HEAD
# introduces nothing it does not already contain (e.g. its change landed via
# squash) the merged tree equals its tree. Returns non-zero when inconclusive
# (no default ref, or a merge conflict), so the caller refuses rather than guesses.
fm_lifecycle_content_in_default() {  # <wt> <project> <base-branch>
  local wt=$1 project=$2 name=${3:-} ref default_tree merged_tree
  [ -n "$name" ] || name=$(fm_lifecycle_default_branch "$project") || return 1
  if git -C "$wt" remote get-url origin >/dev/null 2>&1; then
    git -C "$wt" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 1
    ref="refs/remotes/origin/$name"
  elif git -C "$wt" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  default_tree=$(git -C "$wt" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$wt" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$default_tree" ]
}

# Has the worktree's committed work LANDED, though its commits are not reachable
# from any remote-tracking branch? True when a merged PR proves the current local
# work is contained in the PR head, OR the content is already in the default
# branch (fallback, which also covers the no-PR and gh-error paths).
fm_lifecycle_work_is_landed() {  # <wt> <project> <pr-url> <base-branch> <branch>
  fm_lifecycle_pr_is_merged "$1" "$3" "$5" && return 0
  fm_lifecycle_content_in_default "$1" "$2" "$4"
}

fm_lifecycle_report_worktree_dirt() {  # <porcelain>
  # Use the same porcelain snapshot and exemptions as the refusal predicate.
  printf '%s\n' "$1" | awk '
    /^\?\? / { if (++untracked <= 10) paths = paths "  " substr($0, 4) "\n"; next }
    NF { tracked = 1 }
    END {
      if (tracked) print "uncommitted changes present (includes tracked edits)"
      else print "uncommitted changes present (untracked-only leftovers)"
      if (untracked) {
        print "untracked paths (up to 10):"
        printf "%s", paths
        if (untracked > 10) print "  ... additional untracked paths omitted"
      }
    }
  ' >&2
}

# Absolute path to the git index lock for a worktree/repo dir, or nonzero when it
# cannot be resolved (dir missing or not a git worktree at all).
fm_lifecycle_worktree_git_lock_path() {  # <dir>
  local dir=$1 lock abs_dir
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  lock=$(git -C "$dir" rev-parse --git-path index.lock 2>/dev/null) || return 1
  [ -n "$lock" ] || return 1
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(fm_lifecycle_canonical_existing_dir "$dir") || return 1
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

fm_lifecycle_worktree_safety_blocked_by_lock() {  # <wt> <reason>
  local wt=$1 reason=$2 lock
  lock=$(fm_lifecycle_worktree_git_lock_path "$wt") || lock=""
  [ -n "$lock" ] && [ -e "$lock" ] || return 1
  echo "teardown: cannot inspect worktree $wt for $reason while git lock $lock is present; checking whether the lock is stale" >&2
  return 0
}

# fm_lifecycle_worktree_safety <wt> <kind> <mode> <project> <pr-url> <base-branch>:
# the non-force unlanded-work gate. Uncommitted changes are never landed; commits
# not on any remote must be landed (merged PR or content in the default branch),
# or for local-only work merged into the local default branch. Returns 0, 1 after
# the refusal, or FM_LIFECYCLE_WORKTREE_SAFETY_LOCK_BLOCKED when a git lock kept
# the inspection from running. Caches the inspected branch in
# FM_LIFECYCLE_SAFETY_BRANCH (a retry after the branch was detached reuses it)
# and reports a PR it discovered by branch in FM_LIFECYCLE_PR_URL, which each
# call clears first.
fm_lifecycle_worktree_safety() {
  local wt=$1 kind=$2 mode=$3 project=$4 pr_url=$5 base_branch=$6
  local dirty_raw dirty unpushed_raw unpushed default_name unmerged_raw unmerged branch
  FM_LIFECYCLE_PR_URL=
  [ -d "$wt" ] || return 0
  case "$kind" in
    secondmate|scout) return 0 ;;
  esac

  if ! dirty_raw=$(git -C "$wt" status --porcelain 2>/dev/null); then
    if fm_lifecycle_worktree_safety_blocked_by_lock "$wt" "uncommitted changes"; then
      return "$FM_LIFECYCLE_WORKTREE_SAFETY_LOCK_BLOCKED"
    fi
    echo "REFUSED: cannot inspect worktree $wt for uncommitted changes." >&2
    echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
    return 1
  fi
  dirty=$(printf '%s\n' "$dirty_raw" | grep -vE '^\?\? (\.claude/|\.fm-(grok|kimi)-turnend$)' || true)

  if ! unpushed_raw=$(git -C "$wt" log --oneline HEAD --not --remotes -- 2>/dev/null); then
    if fm_lifecycle_worktree_safety_blocked_by_lock "$wt" "commits not on a remote"; then
      return "$FM_LIFECYCLE_WORKTREE_SAFETY_LOCK_BLOCKED"
    fi
    echo "REFUSED: cannot inspect worktree $wt for commits not on a remote." >&2
    echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
    return 1
  fi
  unpushed=$(printf '%s\n' "$unpushed_raw" | head -5)

  if [ -n "$unpushed" ] && [ "$mode" = local-only ]; then
    default_name=$(fm_lifecycle_default_branch "$project") || { echo "REFUSED: cannot determine default branch for $project; expected origin/HEAD, main, or master." >&2; return 1; }
    if ! unmerged_raw=$(git -C "$wt" log --oneline HEAD --not "$default_name" -- 2>/dev/null); then
      if fm_lifecycle_worktree_safety_blocked_by_lock "$wt" "commits not on $default_name"; then
        return "$FM_LIFECYCLE_WORKTREE_SAFETY_LOCK_BLOCKED"
      fi
      echo "REFUSED: cannot inspect worktree $wt for commits not on $default_name." >&2
      echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
    unmerged=$(printf '%s\n' "$unmerged_raw" | head -5)
    if [ -n "$dirty" ] || [ -n "$unmerged" ]; then
      echo "REFUSED: local-only worktree $wt has work not yet merged into $default_name and not on any remote." >&2
      [ -n "$dirty" ] && fm_lifecycle_report_worktree_dirt "$dirty"
      [ -n "$unmerged" ] && printf 'commits not yet on %s:\n%s\n' "$default_name" "$unmerged" >&2
      echo "Merge the branch into local $default_name first (bin/fm-merge-local.sh after the captain approves), or push to a fork/remote, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
  elif [ -n "$dirty" ]; then
    echo "REFUSED: worktree $wt has uncommitted changes." >&2
    fm_lifecycle_report_worktree_dirt "$dirty"
    echo "Commit them (or get the captain's explicit OK to discard, then --force)." >&2
    return 1
  elif [ -n "$unpushed" ]; then
    branch=${FM_LIFECYCLE_SAFETY_BRANCH:-}
    if [ -z "$branch" ]; then
      branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
      FM_LIFECYCLE_SAFETY_BRANCH=$branch
    fi
    if ! fm_lifecycle_work_is_landed "$wt" "$project" "$pr_url" "$base_branch" "$branch"; then
      echo "REFUSED: worktree $wt has work not on any remote and not landed." >&2
      printf 'unpushed commits:\n%s\n' "$unpushed" >&2
      echo "Push the branch, land its PR, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
  fi
}

# --- Treehouse return and stale git locks ------------------------------------

fm_lifecycle_retry_wait_secs_is_valid() {
  [[ "$1" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]
}

# fm_lifecycle_treehouse_return_knobs: resolve the stale-lock and return-retry
# knobs (bin/fm-teardown.sh header, "Transient / stale worktree git lock
# recovery") into FM_LIFECYCLE_STALE_LOCK_AGE_SECS,
# FM_LIFECYCLE_RETURN_LOCK_RETRIES, and FM_LIFECYCLE_RETURN_LOCK_RETRY_WAIT_SECS,
# warning once about an invalid wait.
fm_lifecycle_treehouse_return_knobs() {
  FM_LIFECYCLE_STALE_LOCK_AGE_SECS=${FM_STALE_WORKTREE_LOCK_AGE_SECS:-30}
  # Bounded patience window for transient index.lock after killing a crew process.
  # New knobs are preferred; FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS remains an alias
  # for the per-attempt wait so existing tests and operators keep working.
  FM_LIFECYCLE_RETURN_LOCK_RETRIES=${FM_TREEHOUSE_RETURN_LOCK_RETRIES:-3}
  FM_LIFECYCLE_RETURN_LOCK_RETRY_WAIT_SECS=${FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS:-${FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS:-1}}
  if ! fm_lifecycle_retry_wait_secs_is_valid "$FM_LIFECYCLE_RETURN_LOCK_RETRY_WAIT_SECS"; then
    echo "teardown: invalid treehouse return lock retry wait '$FM_LIFECYCLE_RETURN_LOCK_RETRY_WAIT_SECS'; using 1s" >&2
    FM_LIFECYCLE_RETURN_LOCK_RETRY_WAIT_SECS=1
  fi
}

# True when treehouse/git stderr shows the transient index.lock "File exists" race.
# Other return failures must not enter the retry path.
fm_lifecycle_treehouse_return_is_index_lock_error() {
  printf '%s\n' "$1" | grep -Eq "Unable to create ['\"].*index\\.lock['\"]: File exists"
}

# The lock-staleness proof (lsof holder check, mtime age, fail-safe defaults) is
# owned by bin/fm-lock-lib.sh's fm_lock_is_provably_stale; this passes the
# worktree dir as the companion directory and the stale-lock age knob.
fm_lifecycle_cleanup_stale_lock_for_safety_check() {  # <dir>
  local dir=$1 lock wait age
  wait=${FM_LIFECYCLE_RETURN_LOCK_RETRY_WAIT_SECS:-1}
  age=${FM_LIFECYCLE_STALE_LOCK_AGE_SECS:-30}
  lock=$(fm_lifecycle_worktree_git_lock_path "$dir") || lock=""
  [ -n "$lock" ] && [ -e "$lock" ] || return 0

  echo "teardown: worktree safety check blocked by git lock $lock; waiting ${wait}s and retrying (owning process may be exiting)" >&2
  sleep "$wait"

  if [ ! -e "$lock" ]; then
    echo "teardown: worktree safety check lock cleared on its own; retrying safety checks" >&2
    return 0
  fi

  if fm_lock_is_provably_stale "$lock" "$dir" "$age"; then
    rm -f "$lock"
    echo "teardown: removed provably-stale git lock $lock (age >= ${age}s, no live holder) and retrying worktree safety checks" >&2
    return 0
  fi

  echo "teardown: worktree safety check blocked by git lock $lock that is not provably stale (may belong to a live process); leaving it in place" >&2
  return "$FM_LIFECYCLE_TREEHOUSE_LOCK_REFUSED"
}

# fm_lifecycle_treehouse_return <dir> <cd-dir> <label> [<post-cleanup-check-function>]:
# return a worktree/home via `treehouse return --force`, tolerating a transient
# or stale git index.lock left by a killed crew process (bin/fm-teardown.sh
# header). Returns FM_LIFECYCLE_TREEHOUSE_LOCK_REFUSED when a lock that is not
# provably stale persisted.
fm_lifecycle_treehouse_return() {
  local dir=$1 cd_dir=$2 label=$3 post_cleanup_check=${4:-}
  local out lock attempt=0 max_retries lock_desc wait age

  wait=${FM_LIFECYCLE_RETURN_LOCK_RETRY_WAIT_SECS:-1}
  age=${FM_LIFECYCLE_STALE_LOCK_AGE_SECS:-30}
  # Capture stdout+stderr so non-lock failures stay visible and lock failures can
  # be matched by signature even when the lock file is already gone mid-check.
  if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
  fi
  [ -n "$out" ] && printf '%s\n' "$out" >&2

  if ! fm_lifecycle_treehouse_return_is_index_lock_error "$out"; then
    return 1
  fi

  lock=$(fm_lifecycle_worktree_git_lock_path "$dir") || lock=""
  if [ -n "$lock" ]; then
    lock_desc=$lock
  else
    lock_desc="index.lock"
  fi

  max_retries=${FM_LIFECYCLE_RETURN_LOCK_RETRIES:-3}
  case "$max_retries" in ''|*[!0-9]*) max_retries=3 ;; esac

  while [ "$attempt" -lt "$max_retries" ]; do
    attempt=$(( attempt + 1 ))
    echo "teardown: $label return failed with transient git lock ($lock_desc); waiting ${wait}s and retrying ($attempt/${max_retries})" >&2
    sleep "$wait"

    if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
      [ -n "$out" ] && printf '%s\n' "$out"
      echo "teardown: $label return succeeded on retry; lock cleared on its own" >&2
      return 0
    fi
    [ -n "$out" ] && printf '%s\n' "$out" >&2

    if ! fm_lifecycle_treehouse_return_is_index_lock_error "$out"; then
      echo "teardown: $label return failed with a non-lock error after retry; aborting" >&2
      return 1
    fi
  done

  # Refresh lock path after the patience window; it may have appeared, moved, or
  # cleared while we waited.
  lock=$(fm_lifecycle_worktree_git_lock_path "$dir") || lock=""
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    lock_desc=$lock
    if fm_lock_is_provably_stale "$lock" "$dir" "$age"; then
      rm -f "$lock"
      echo "teardown: removed provably-stale git lock $lock (age >= ${age}s, no live holder) and retrying $label return" >&2
      if [ -n "$post_cleanup_check" ]; then
        if ! "$post_cleanup_check"; then
          echo "teardown: $label return aborted after stale-lock cleanup because safety checks failed" >&2
          return 1
        fi
      fi
      if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
        [ -n "$out" ] && printf '%s\n' "$out"
        echo "teardown: $label return succeeded after stale-lock cleanup" >&2
        return 0
      fi
      [ -n "$out" ] && printf '%s\n' "$out" >&2
      echo "teardown: $label return still failing after stale-lock cleanup" >&2
      return 1
    fi

    echo "teardown: $label return failed: git lock $lock_desc persisted across ${max_retries} retries (waiting ${wait}s each) and is not provably stale (may belong to a live process); leaving it in place" >&2
    return "$FM_LIFECYCLE_TREEHOUSE_LOCK_REFUSED"
  fi

  echo "teardown: $label return failed: git index.lock signature persisted across ${max_retries} retries (waiting ${wait}s each) even after the lock file disappeared" >&2
  return 1
}

# fm_lifecycle_return_task_worktree <task-id> <wt> <project> <post-cleanup-check-function-or-empty>:
# drop the task branch, remove the hook files a reused pool worktree could still
# fire for a dead task, return the slot to the pool (treehouse resolves the pool
# from the project), and release this task's slot claim only after the return
# succeeded.
fm_lifecycle_return_task_worktree() {
  local id=$1 wt=$2 project=$3 post_check=${4:-} branch
  branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  if [ "$branch" != "HEAD" ]; then
    if git -C "$wt" checkout --detach -q 2>/dev/null; then
      git -C "$wt" branch -D "$branch" >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$wt/.claude/settings.local.json" "$wt/.opencode/plugins/fm-turn-end.js" \
    "$wt/.fm-grok-turnend" "$wt/.fm-kimi-turnend" || return 1
  fm_lifecycle_treehouse_return "$wt" "$project" "worktree" "$post_check" || {
    echo "error: treehouse return failed for worktree $wt; teardown aborted" >&2
    return 1
  }
  # The slot is back in the pool, so this task's claim on it is spent. Dropping
  # it here - and only after a return that succeeded - keeps a returned slot
  # unclaimed until its next holder claims it, and leaves the claim in place
  # whenever the return did not actually happen.
  fm_treehouse_slot_owner_release "$wt" "$id" || return 1
}

# --- own parked no-mistakes run -----------------------------------------------

fm_lifecycle_nm_knobs() {
  FM_LIFECYCLE_NM_TIMEOUT=${FM_TEARDOWN_NM_TIMEOUT:-10}
  case "$FM_LIFECYCLE_NM_TIMEOUT" in ''|*[!0-9]*) FM_LIFECYCLE_NM_TIMEOUT=10 ;; esac
  # How many of the most recent `no-mistakes runs` rows the parked-run
  # continuation proof may scan, mirroring bin/fm-crew-state.sh's limit posture
  # (generous: rows of other branches interleave freely in the real ledger).
  FM_LIFECYCLE_NM_RUNS_LIMIT=${FM_TEARDOWN_NM_RUNS_LIMIT:-200}
  case "$FM_LIFECYCLE_NM_RUNS_LIMIT" in ''|*[!0-9]*) FM_LIFECYCLE_NM_RUNS_LIMIT=200 ;; esac
}

# Does the active-or-most-recent no-mistakes run in worktree <wt> belong to THIS
# task, and is it parked at a gate awaiting an agent that is about to be
# removed? Returns 0 only on a genuine match (FM_LIFECYCLE_TASK_RUN_ID). Identity
# binds through bin/fm-nm-run-lib.sh's strict object-local head rule, with its
# shared ledger-anchored continuation rule as the only recognition for a head
# this copy cannot resolve at all.
fm_lifecycle_task_status_is_own_parked_run() {  # <worktree> <axi-status-output>
  local wt=$1 out=$2 branch run_id run_branch run_head status outcome awaiting has_gate ledger
  FM_LIFECYCLE_TASK_RUN_ID=
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
  [ -n "$branch" ] || return 1
  [ -n "$out" ] || return 1
  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
  [ -n "$run_id" ] || return 1
  run_branch=$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")
  [ -n "$run_branch" ] && [ "$run_branch" = "$branch" ] || return 1
  run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$out" head)")
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$out" outcome)")
  [ -z "$outcome" ] || return 1
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$out" status)")
  [ -n "$status" ] || return 1
  case "$status" in
    completed|failed|cancelled|passed|checks-passed|running|fixing|ci) return 1 ;;
  esac
  if ! fm_nm_head_matches_worktree "$wt" "$run_head"; then
    # The strict object-local rule rejected this run head. That rejection is
    # final when the head object resolves in this copy (diverged or rewritten
    # tips are genuine mismatches), but when the object is absent entirely -
    # the pipeline committed its fix round in its own repo and this copy
    # never fetched it - the ONE shared runs-ledger rule in
    # bin/fm-nm-run-lib.sh owns the only remaining recognition, and it prints
    # nothing for any ledger shape it cannot prove, so the run stays
    # untouched unless the ledger proves this exact continuation. Cleanup
    # consumes only an explicitly active (`running`) proved word: a terminal
    # newest row is finished history, never this parked run's abort
    # authorization (the read path classifies the same owner's answer; the
    # abort here must never fire for a run that already ended).
    [ -n "$run_head" ] || return 1
    [ -z "$(fm_nm_resolve_commit "$wt" "$run_head")" ] || return 1
    ledger=$(fm_nm_run "$wt" "$FM_LIFECYCLE_NM_TIMEOUT" runs --limit "$FM_LIFECYCLE_NM_RUNS_LIMIT")
    [ "$(fm_nm_runs_status_for_worktree "$wt" "$branch" "$ledger" "$run_head")" = running ] || return 1
  fi
  awaiting=$(printf '%s\n' "$out" | grep -E '^[[:space:]]*awaiting_agent:' | head -1 || true)
  has_gate=$(printf '%s\n' "$out" | grep -Eq '^[[:space:]]*gate:[[:space:]]*' && echo 1 || echo 0)
  case "$status" in
    awaiting_approval|fix_review) FM_LIFECYCLE_TASK_RUN_ID=$run_id; return 0 ;;
  esac
  if [ -n "$awaiting" ] || [ "$has_gate" = 1 ]; then
    FM_LIFECYCLE_TASK_RUN_ID=$run_id
    return 0
  fi
  return 1
}

fm_lifecycle_task_run_is_own_parked_run() {  # <worktree>
  local wt=$1 out
  # Accepted best-effort residual: query failures stay fail-open because making
  # no-mistakes availability a prerequisite would block ship tasks with no run.
  out=$(fm_nm_run "$wt" "$FM_LIFECYCLE_NM_TIMEOUT" axi status)
  fm_lifecycle_task_status_is_own_parked_run "$wt" "$out"
}

fm_lifecycle_task_status_is_terminal_run() {  # <axi-status-output> <run-id>
  local out=$1 expected_id=$2 run_id outcome
  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
  [ "$run_id" = "$expected_id" ] || return 1
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$out" outcome)")
  case "$outcome" in
    cancelled|failed|passed|checks-passed|passed-with-override|passed-with-skips) return 0 ;;
  esac
  return 1
}

fm_lifecycle_task_status_is_run_not_found() {  # <status-error> <run-id>
  local actual expected
  actual=$(fm_nm_trim "$1")
  expected=$(printf 'error: "run \\"%s\\" not found"' "$2")
  [ "$actual" = "$expected" ]
}

# fm_lifecycle_conclude_own_parked_run <wt> <task-id> <kind>: abort THIS task's
# own parked no-mistakes run before the worker that would have answered its gate
# is removed, so no run is left orphaned holding a fleet slot. Only a ship drives
# a no-mistakes validation of its own worktree; a run not attributed to this
# exact branch+head is left completely alone.
fm_lifecycle_conclude_own_parked_run() {
  local wt=$1 id=$2 kind=$3 out run_id
  [ "$kind" = ship ] || return 0
  [ -d "$wt" ] || return 0
  command -v no-mistakes >/dev/null 2>&1 || return 0
  fm_lifecycle_nm_knobs
  fm_lifecycle_task_run_is_own_parked_run "$wt" || return 0
  run_id=$FM_LIFECYCLE_TASK_RUN_ID
  echo "teardown: no-mistakes run for $id is parked at a gate; aborting before the worker is removed" >&2
  # Accepted best-effort residual: abort supports run-id targeting but no atomic
  # live-state condition; fully closing the resume race needs upstream compare-and-cancel.
  fm_nm_run_checked "$wt" "$FM_LIFECYCLE_NM_TIMEOUT" axi abort --run "$run_id" >/dev/null 2>&1 || true
  if out=$(fm_nm_run_bounded "$wt" "$FM_LIFECYCLE_NM_TIMEOUT" axi status --run "$run_id" 2>&1); then
    fm_lifecycle_task_status_is_terminal_run "$out" "$run_id" && return 0
  elif fm_lifecycle_task_status_is_run_not_found "$out" "$run_id"; then
    return 0
  fi
  echo "REFUSED: no-mistakes run for $id is still parked after axi abort; confirm it stopped (no-mistakes axi status) or abort it manually (no-mistakes axi abort --run <id>) before retrying teardown." >&2
  return 1
}

# --- leaked task processes ----------------------------------------------------

# pids of every process whose CURRENT WORKING DIRECTORY is exactly <dir> or under
# it, from one bounded system-wide `lsof -a -d cwd` scan (never the recursive +D
# file-tree walk). Never this shell's own pid. Empty output when nothing
# matches; failure means the scan could not establish a safe result.
fm_lifecycle_pids_with_cwd_under() {  # <dir>
  local dir=$1 out pid path line
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  dir=$(cd "$dir" && pwd -P) || return 1
  out=$(lsof -a -d cwd -Fpn 2>/dev/null) || return 1
  [ -n "$out" ] || return 0
  pid=
  while IFS= read -r line; do
    case "$line" in
      p*)
        pid=${line#p}
        case "$pid" in ''|*[!0-9]*) return 1 ;; esac
        ;;
      fcwd) [ -n "$pid" ] || return 1 ;;
      n*)
        [ -n "$pid" ] || return 1
        path=${line#n}
        case "$path" in
          "$dir"|"$dir"/*)
            [ -n "$pid" ] && [ "$pid" != "$$" ] && printf '%s\n' "$pid"
            ;;
        esac
        ;;
      '') ;;
      *) return 1 ;;
    esac
  done <<EOF
$out
EOF
}

# fm_lifecycle_process_identity <pid>: the process's start identity
# (starttime= from /proc, else lstart= from ps), the form this library's
# process-identity comparisons use.
fm_lifecycle_process_identity() {  # <pid>
  local pid=$1 proc_root stat_line starttime value
  local -a stat_fields
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/$pid/stat" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in ''|*[!0-9]*) return 1 ;; esac
    printf 'starttime=%s\n' "$starttime"
    return 0
  fi
  value=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  value=$(fm_nm_trim "$value")
  [ -n "$value" ] || return 1
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf 'lstart=%s\n' "$value"
}

fm_lifecycle_process_identity_matches() {  # <pid> <identity>
  local current
  current=$(fm_lifecycle_process_identity "$1") || return 1
  [ "$current" = "$2" ]
}

fm_lifecycle_pid_list_contains() {  # <pid-list> <pid>
  printf '%s\n' "$1" | grep -Fxq "$2"
}

fm_lifecycle_task_pids_under_roots() {  # <dir>...
  FM_LIFECYCLE_TASK_PIDS=
  FM_LIFECYCLE_TASK_PIDS_FAILED_DIR=
  local dir dir_pids pids=""
  for dir in "$@"; do
    [ -n "$dir" ] || continue
    if ! dir_pids=$(fm_lifecycle_pids_with_cwd_under "$dir"); then
      FM_LIFECYCLE_TASK_PIDS_FAILED_DIR=$dir
      return 1
    fi
    pids="$pids
$dir_pids"
  done
  FM_LIFECYCLE_TASK_PIDS=$(printf '%s\n' "$pids" | grep -E '^[0-9]+$' | sort -un || true)
}

fm_lifecycle_reap_task_backend_process_group() {  # <task-id> <backend> <target> <label>
  local id=$1 backend=$2 target=$3 label=$4 leader leader_start pgid current_pgid own_pgid
  if [ "$backend" != tmux ]; then
    echo "warning: lsof is unavailable; cannot resolve a process-group fallback for $backend task $id" >&2
    return 0
  fi
  leader=$(tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null) || leader=""
  case "$leader" in ''|*[!0-9]*)
    echo "warning: lsof is unavailable; cannot resolve the tmux pane process group for $id" >&2
    return 0
    ;;
  esac
  leader_start=$(fm_lifecycle_process_identity "$leader") || {
    echo "warning: lsof is unavailable; cannot identify the tmux pane process group for $id" >&2
    return 0
  }
  pgid=$(ps -o pgid= -p "$leader" 2>/dev/null) || pgid=""
  pgid=$(printf '%s' "$pgid" | tr -d '[:space:]')
  case "$pgid" in ''|*[!0-9]*|0|1)
    echo "warning: lsof is unavailable; cannot resolve the tmux pane process group for $id" >&2
    return 0
    ;;
  esac
  own_pgid=$(ps -o pgid= -p "$$" 2>/dev/null) || own_pgid=""
  own_pgid=$(printf '%s' "$own_pgid" | tr -d '[:space:]')
  if [ "$pgid" = "$own_pgid" ]; then
    echo "warning: lsof is unavailable; refusing to signal teardown's own process group for $id" >&2
    return 0
  fi
  fm_lifecycle_process_identity_matches "$leader" "$leader_start" || return 0
  current_pgid=$(ps -o pgid= -p "$leader" 2>/dev/null) || current_pgid=""
  current_pgid=$(printf '%s' "$current_pgid" | tr -d '[:space:]')
  [ "$current_pgid" = "$pgid" ] || return 0
  echo "teardown: reaping leaked $label process group for $id: $pgid" >&2
  kill -TERM -- "-$pgid" 2>/dev/null || true
  sleep 1
  if fm_lifecycle_process_identity_matches "$leader" "$leader_start" \
     && [ "$(ps -o pgid= -p "$leader" 2>/dev/null | tr -d '[:space:]')" = "$pgid" ] \
     && kill -0 -- "-$pgid" 2>/dev/null; then
    echo "teardown: force-killing leaked $label process group for $id: $pgid" >&2
    kill -KILL -- "-$pgid" 2>/dev/null || true
  fi
}

# fm_lifecycle_reap_task_processes <task-id> <backend> <target> <label> <dir>...:
# reap every process rooted (by cwd) under this task's own worktree or tasktmp -
# both unique per task and never shared - before either is removed. TERM first,
# then KILL after a short grace period for anything whose identity still
# matches. A missing lsof uses the backend process-group fallback; an lsof scan
# error refuses before destructive teardown.
fm_lifecycle_reap_task_processes() {
  local id=$1 backend=$2 target=$3 label=$4 pids pid identity current_pids i pass=1 max_passes=3
  local -a tracked_pids tracked_identities remaining_pids remaining_identities
  shift 4
  if ! command -v lsof >/dev/null 2>&1; then
    fm_lifecycle_reap_task_backend_process_group "$id" "$backend" "$target" "$label"
    return 0
  fi
  while [ "$pass" -le "$max_passes" ]; do
    if ! fm_lifecycle_task_pids_under_roots "$@"; then
      echo "REFUSED: cannot determine leaked processes under ${FM_LIFECYCLE_TASK_PIDS_FAILED_DIR:-<missing>} for $id (lsof failed); preserving the worktree/tasktmp for manual inspection or retry." >&2
      return 1
    fi
    pids=$FM_LIFECYCLE_TASK_PIDS
    [ -n "$pids" ] || return 0
    tracked_pids=()
    tracked_identities=()
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      if ! identity=$(fm_lifecycle_process_identity "$pid"); then
        if ! fm_lifecycle_task_pids_under_roots "$@"; then
          echo "REFUSED: cannot determine leaked processes under ${FM_LIFECYCLE_TASK_PIDS_FAILED_DIR:-<missing>} for $id (lsof failed); preserving the worktree/tasktmp for manual inspection or retry." >&2
          return 1
        fi
        if fm_lifecycle_pid_list_contains "$FM_LIFECYCLE_TASK_PIDS" "$pid"; then
          echo "REFUSED: cannot verify leaked process $pid identity for $id; preserving the worktree/tasktmp for manual inspection or retry." >&2
          return 1
        fi
        continue
      fi
      tracked_pids+=("$pid")
      tracked_identities+=("$identity")
    done <<EOF
$pids
EOF
    if [ "${#tracked_pids[@]}" -eq 0 ]; then
      pass=$((pass + 1))
      continue
    fi
    if ! fm_lifecycle_task_pids_under_roots "$@"; then
      echo "REFUSED: cannot determine leaked processes under ${FM_LIFECYCLE_TASK_PIDS_FAILED_DIR:-<missing>} for $id (lsof failed); preserving the worktree/tasktmp for manual inspection or retry." >&2
      return 1
    fi
    current_pids=$FM_LIFECYCLE_TASK_PIDS
    echo "teardown: reaping leaked $label process(es) for $id: $(printf '%s' "$pids" | tr '\n' ' ')" >&2
    for i in "${!tracked_pids[@]}"; do
      pid=${tracked_pids[$i]}
      identity=${tracked_identities[$i]}
      if fm_lifecycle_pid_list_contains "$current_pids" "$pid" \
         && fm_lifecycle_process_identity_matches "$pid" "$identity"; then
        kill -TERM "$pid" 2>/dev/null || true
      fi
    done
    sleep 1
    if ! fm_lifecycle_task_pids_under_roots "$@"; then
      echo "REFUSED: cannot determine leaked processes under ${FM_LIFECYCLE_TASK_PIDS_FAILED_DIR:-<missing>} for $id (lsof failed); preserving the worktree/tasktmp for manual inspection or retry." >&2
      return 1
    fi
    current_pids=$FM_LIFECYCLE_TASK_PIDS
    remaining_pids=()
    remaining_identities=()
    for i in "${!tracked_pids[@]}"; do
      pid=${tracked_pids[$i]}
      identity=${tracked_identities[$i]}
      if fm_lifecycle_pid_list_contains "$current_pids" "$pid" \
         && fm_lifecycle_process_identity_matches "$pid" "$identity"; then
        remaining_pids+=("$pid")
        remaining_identities+=("$identity")
      fi
    done
    if [ "${#remaining_pids[@]}" -gt 0 ]; then
      echo "teardown: force-killing leaked $label process(es) for $id: ${remaining_pids[*]}" >&2
      if ! fm_lifecycle_task_pids_under_roots "$@"; then
        echo "REFUSED: cannot determine leaked processes under ${FM_LIFECYCLE_TASK_PIDS_FAILED_DIR:-<missing>} for $id (lsof failed); preserving the worktree/tasktmp for manual inspection or retry." >&2
        return 1
      fi
      current_pids=$FM_LIFECYCLE_TASK_PIDS
      for i in "${!remaining_pids[@]}"; do
        pid=${remaining_pids[$i]}
        identity=${remaining_identities[$i]}
        if fm_lifecycle_pid_list_contains "$current_pids" "$pid" \
           && fm_lifecycle_process_identity_matches "$pid" "$identity"; then
          kill -KILL "$pid" 2>/dev/null || true
        fi
      done
    fi
    pass=$((pass + 1))
  done
  if ! fm_lifecycle_task_pids_under_roots "$@"; then
    echo "REFUSED: cannot determine leaked processes under ${FM_LIFECYCLE_TASK_PIDS_FAILED_DIR:-<missing>} for $id (lsof failed); preserving the worktree/tasktmp for manual inspection or retry." >&2
    return 1
  fi
  [ -z "$FM_LIFECYCLE_TASK_PIDS" ] && return 0
  echo "REFUSED: leaked $label processes for $id remain after $max_passes reap attempts; preserving the worktree/tasktmp for manual inspection or retry." >&2
  return 1
}

# --- outcome delivery and endpoint-bound artifacts -----------------------------

# fm_lifecycle_deliver_outcome <home> <state> <data> <task-id>: publish or
# confirm the task's owed outcome on its parent channel before its record is
# removed (bin/fm-inactive-reconcile.sh `report` owns delivery and dedup).
fm_lifecycle_deliver_outcome() {
  local home=$1 state=$2 data=$3 id=$4
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
      "$FM_LIFECYCLE_LIB_DIR/fm-inactive-reconcile.sh" report "$id"; then
    echo "error: $id's final outcome has not reached the parent channel; retaining every durable task record so a rerun can retry the delivery" >&2
    return 1
  fi
}

# Where a harness's firstmate-owned global turn-end registry entry lives is
# owned by bin/fm-control-lib.sh, so teardown and the control plane's relaunch
# retire the same artifact rather than each carrying its own copy of the path.
fm_lifecycle_remove_grok_turnend_auth() {  # <state> <task-id>
  local state_dir=$1 id=$2 token_path token='' path
  token_path=$(fm_control_harness_turnend_token_path grok "$state_dir" "$id") || return 1
  if [ -n "$token_path" ] && [ -f "$token_path" ]; then
    IFS= read -r token < "$token_path" || [ -n "$token" ] || return 1
  fi
  path=$(fm_control_harness_turnend_auth_path grok "$token") || return 1
  [ -n "$path" ] || return 0
  rm -f -- "$path"
}

fm_lifecycle_remove_kimi_turnend_auth() {  # <state> <task-id>
  local state_dir=$1 id=$2 token_path token='' path
  token_path=$(fm_control_harness_turnend_token_path kimi "$state_dir" "$id") || return 1
  if [ -n "$token_path" ] && [ -f "$token_path" ]; then
    IFS= read -r token < "$token_path" || [ -n "$token" ] || return 1
  fi
  path=$(fm_control_harness_turnend_auth_path kimi "$token") || return 1
  [ -n "$path" ] || return 0
  rm -f -- "$path"
}

fm_lifecycle_retire_busy_state() {  # <state> <task-id> [busy-gen]
  local state_dir=$1 id=$2 gen=${3:-}
  if [ -n "$gen" ]; then
    "$FM_LIFECYCLE_LIB_DIR/fm-busy-event.sh" retire "$state_dir" "$id" --gen "$gen"
  elif [ -f "$state_dir/$id.busy-gen" ]; then
    "$FM_LIFECYCLE_LIB_DIR/fm-busy-event.sh" retire "$state_dir" "$id" --current-gen
  fi
}

# Retire only this Firstmate home's launch namespace. Its never-reused per-spawn
# files leave the equal task-id namespace of every other home untouched.
fm_lifecycle_launch_home_token() {  # <home>
  local home=$1 root hash
  root=$(cd "$home" 2>/dev/null && pwd -P) || root=$home
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | shasum -a 256 | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | sha256sum | awk '{print $1}')
  else
    return 1
  fi
  case "$hash" in
    *[!0-9a-fA-F]*|'') return 1 ;;
  esac
  printf '%s' "$hash"
}

# fm_lifecycle_retire_task_artifacts <home> <state> <config> <task-id> <backend> <target> <tasktmp> <busy-gen>:
# retire the endpoint-bound runtime state of one task incarnation: harness
# turn-end registrations, the backend's transition marker, its per-task temp
# root and launch namespace, PR-check artifacts, busy state, the fleet-ledger
# line, its status presentation, queued wakes, per-harness state files, the
# steering inbox, and the spawn-owned commit-msg strip directory. data/<id>/ is
# deliberately left in place: a successor spawn reads brief.md from it.
fm_lifecycle_retire_task_artifacts() {
  local home=$1 state=$2 config=$3 id=$4 backend=$5 target=$6 tasktmp=$7 busy_gen=$8 token
  fm_lifecycle_remove_grok_turnend_auth "$state" "$id" || return 1
  fm_lifecycle_remove_kimi_turnend_auth "$state" "$id" || return 1
  fm_backend_clear_transition "$backend" "$state" "$target" || true
  # The per-task temp root (/tmp/fm-<id>/, incl. its gotmp/) recorded by spawn;
  # empty (tasks spawned before tasktmp=) is a no-op.
  if [ -n "$tasktmp" ]; then
    rm -rf "$tasktmp" || return 1
  fi
  token=$(fm_lifecycle_launch_home_token "$home") || token=
  if [ -n "$token" ]; then
    rm -rf "/tmp/fm-$id+$token" || return 1
  fi
  fm_lifecycle_remove_pr_poll_artifacts "$state" "$id" || return 1
  fm_lifecycle_retire_busy_state "$state" "$id" "$busy_gen" || return 1
  # Opt-in fleet activity ledger (docs/fleet-ledger.md), before the status log is
  # retired so its last lines are captured; off costs one file test.
  [ ! -e "$config/fleet-ledger" ] || FM_HOME=$home FM_STATE_OVERRIDE=$state FM_CONFIG_OVERRIDE=$config "$FM_LIFECYCLE_LIB_DIR/fm-fleet-ledger.sh" cleaned_up "$id" || true
  status_retire_presentation_task "$state" "$id" || return 1
  fm_wake_queue_prune_task "$state" "$id" "$target" 2>/dev/null || true
  rm -f "$state/$id.turn-ended" "$state/$id.progress" \
    "$(fm_wake_signal_seen_path "$state" "$state/$id.turn-ended")" \
    "$state/$id.pi-ext.ts" "$state/$id.omp-ext.ts" "$state/$id.grok-turnend-token" \
    "$state/$id.kimi-turnend-token" "$state/$id.muse-session" \
    "$state/$id.muse-session-current" "$state/$id.cursor-session" \
    "$state/$id.control-relaunch" "$state/$id.control-relaunch.meta-prior" \
    "$state/$id.control-relaunch.brief-prior" "$state/$id.control-relaunch.note" \
    "$state/$id.reconcile-nudged" "$state/$id.gemini-settings.json" "$state/$id.devin-config.json" \
    "$state/$id.droid-settings.json" "$state/$id.droid-session-end" \
    "$state/$id.droid-submit-receipts" \
    "$state/.$id.branch-outcome-index" \
    "$state/.secondmate-relaunch-$id" "$state/.secondmate-relaunch-bound-$id" || return 1
  # The steering inbox (bin/fm-task-inbox-lib.sh) is runtime state for the
  # retired endpoint; retirement only runs after landing is confirmed, so any
  # leftover unhandled steer here is moot rather than unlanded work.
  # state/<id>.git-hooks is the spawn-owned commit-msg strip directory, left
  # read-only by its installer.
  chmod u+w "$state/$id.git-hooks" 2>/dev/null || true
  rm -rf "$state/$id.inbox" "$state/$id.git-hooks" || return 1
}

# shellcheck source=bin/fm-lifecycle-retire-lib.sh
. "$FM_LIFECYCLE_LIB_DIR/fm-lifecycle-retire-lib.sh"
