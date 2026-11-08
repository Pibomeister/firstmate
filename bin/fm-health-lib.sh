# shellcheck shell=bash
# fm-health-lib.sh - shared predicates for a home's health.
# Usage: . bin/fm-health-lib.sh
#
# The caller has bin/fm-classify-lib.sh (the status_* wait readers) in scope.
#
# fm_health_open_work <home> [now] [state-dir]
#   0 when <home> has open work: an unresolved dispatch-log goal, or an
#   in-flight task not resting in a declared paused or captain-held wait.
#   A paused wait whose until time has passed is open again; [now] dates it
#   and defaults to the clock. [state-dir] defaults to <home>/state.
#   A goal is unresolved while its latest dispatch-log state is received or
#   queued. No arm applies a secondmate-home exclusion; a caller that wants
#   one adds it.

fm_health_open_work() {
  local home=$1 now=${2:-} state meta task last until
  state=${3:-$home/state}
  # The goal rule twins fm_sup_open_goal (bin/fm-supervision-lib.sh), which adds
  # a secondmate-home exclusion; a change to either rule changes both.
  if [ -s "$state/dispatch-log.tsv" ] && awk -F '\t' '
    $3 == "received" || $3 == "queued" || $3 == "dispatched" || $3 == "blocked" { latest[$4] = $3 }
    END { for (goal in latest) if (latest[goal] == "received" || latest[goal] == "queued") exit 0; exit 1 }
  ' "$state/dispatch-log.tsv"; then
    return 0
  fi
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    task=${meta##*/}; task=${task%.meta}
    last=$(status_declared_wait_line "$state/$task.status")
    status_is_captain_held "$last" && continue
    if status_is_paused "$last" && until=$(status_paused_until "$last"); then
      [ -n "$now" ] || now=$(date +%s)
      [ "$now" -lt "$until" ] && continue
    elif status_is_paused "$last"; then
      continue
    fi
    return 0
  done
  return 1
}
