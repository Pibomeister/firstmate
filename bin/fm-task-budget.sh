#!/usr/bin/env bash
# Native task budget helper. Usage:
#   fm-task-budget.sh validate <inclusive-hard> <inclusive-stop> <fresh-hard> <fresh-stop>
#   fm-task-budget.sh seed <prior-meta-or-dash> <harness> <worktree> <native-log-root> <launch-marker> <four-limits>
#   fm-task-budget.sh measure <task-meta>  # JSON: ok totals, pending, or unknown with reason
#   fm-task-budget.sh tick <task-meta> <config-dir> <home>
#   fm-task-budget.sh prelaunch <home>
#   fm-task-budget.sh fold-away <lane-budget> <child-meta>
#   fm-task-budget.sh bind <harness> <worktree> <native-log-root> <launch-marker> <prior-meta-or-dash>
# validate performs no writes; seed carries measured prior-incarnation usage
# (or warns and carries none when it is unknown) and prints a fragment for
# atomic task metadata publication.
# tick holds the existing task-meta lock, defaults to dry-run, and uses only the
# existing fm-control interrupt, at most once per stop-line episode. <id>.budget
# holds native bindings, incremental counters (byte offset plus folded totals),
# allocation episodes and claimed control attempts; <id>.budget-diagnostic
# deduplicates unknown telemetry without discarding corrupt counter state.
# A claim without a completion proof is uncertain and is not blindly replayed.
# fresh = uncached input + cache write + output; inclusive adds cache reads.
# Claude usage uses the latest complete snapshot per message id; Codex uses
# cumulative input/output once and subtracts cached input only for fresh usage.
# Bind the main native session to its initial user-message launch marker,
# canonical worktree and launch boundary;
# Claude's canonical record doorbell instead binds by its SHA-256 fingerprint.
# ambiguous, unsupported, corrupt, or missing telemetry is unknown, never zero,
# except a child whose session has not recorded usage yet, which counts as zero
# and is named pending. A mate session that is not yet identifiable refuses a
# launch rather than counting as zero.
# A secondmate lane total adds that mate, its sidechain logs, every child task,
# and usage folded when a child is torn down. prelaunch refuses a new child
# when the lane total is already at a recorded stop. fold-away adds a torn-down
# child's total once; a still-pending child is folded as zero.
# The operator switch is documented in docs/configuration.md (budget-enforcement).
set -eu
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode=${1:-}
case "$mode" in
  -h|--help) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
if [ "$mode" = prelaunch ] || [ "$mode" = fold-away ]; then
  if [ "$mode" = prelaunch ]; then
    [ "$#" = 2 ] || exit 2
    home=$2
    lane="$home/state/lane-budget"
    lock="$home/state/.lane-budget.lock"
  else
    [ "$#" = 3 ] || exit 2
    lane=$2
    child=$3
    lock="$(dirname "$lane")/.lane-budget.lock"
  fi
  if [ ! -f "$lane" ] || [ -L "$lane" ]; then
    exit 0
  fi
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  if ! fm_lock_acquire_wait_max "$lock" 30; then
    if [ "$mode" = prelaunch ]; then
      echo "budget-prelaunch refuse unknown: lane budget is locked" >&2
    else
      echo "budget-unknown fold-away: lane budget is locked" >&2
    fi
    exit 1
  fi
  trap 'fm_lock_release "$lock"' EXIT
  code=0
  if [ "$mode" = prelaunch ]; then
    python3 "$SCRIPT_DIR/fm-task-budget.py" prelaunch "$home" || code=$?
  else
    python3 "$SCRIPT_DIR/fm-task-budget.py" fold-away "$lane" "$child" || code=$?
  fi
  exit "$code"
fi
if [ "$mode" = tick ] || [ "$mode" = measure ]; then
  if [ "$mode" = tick ]; then
    [ "$#" = 4 ] || exit 2
    config=$3 budget_home=$4
  else
    [ "$#" = 2 ] || exit 2
  fi
  meta=$2
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    [ "$mode" != measure ] || printf '%s\n' '{"status":"unknown","reason":"invalid task metadata path"}'
    exit 0
  fi
  if [ "$mode" = tick ]; then
    grep -q '^budget_inclusive_hard=' "$meta" || exit 0
  fi
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  budget_lock=$(fm_meta_lock_path "$meta") || exit 1
  if ! fm_lock_try_acquire "$budget_lock"; then
    [ "$mode" != measure ] || printf '%s\n' '{"status":"unknown","reason":"task metadata is locked"}'
    exit 0
  fi
  trap 'fm_lock_release "$budget_lock"' EXIT
  if [ "$mode" = measure ]; then
    python3 "$SCRIPT_DIR/fm-task-budget.py" measure "$meta"
    exit 0
  fi
  action=$(python3 "$SCRIPT_DIR/fm-task-budget.py" prepare "$meta" "$config") || exit 1
  if [ "$action" = interrupt ]; then
    id=${meta##*/}; id=${id%.meta}
    code=0
    output=$(FM_HOME="$budget_home" FM_STATE_OVERRIDE="${meta%/*}" FM_CONFIG_OVERRIDE="$config" \
      "$BASH" "$SCRIPT_DIR/fm-control.sh" "$id" interrupt 2>&1) || code=$?
    python3 "$SCRIPT_DIR/fm-task-budget.py" finish "$meta" "$code" "$output"
  fi
  exit 0
fi
exec python3 "$SCRIPT_DIR/fm-task-budget.py" "$@"
