#!/usr/bin/env bash
# Native task budget helper. Usage:
#   fm-task-budget.sh validate <inclusive-hard> <inclusive-stop> <fresh-hard> <fresh-stop>
#   fm-task-budget.sh seed <prior-meta-or-dash> <harness> <worktree> <native-log-root> <launch-marker> <four-limits>
#   fm-task-budget.sh measure <task-meta>  # JSON: ok totals, pending, or unknown with reason
#   fm-task-budget.sh tick <task-meta> <config-dir> <home>
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
# ambiguous, unsupported, corrupt, or missing telemetry is unknown, never zero.
# The operator switch is documented in docs/configuration.md (budget-enforcement).
set -eu
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode=${1:-}
case "$mode" in
  -h|--help) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
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
