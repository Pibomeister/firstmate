#!/usr/bin/env bash
# fm-home-summary-refresh.sh - publish this home's structured summary ledger.
#
# Usage: fm-home-summary-refresh.sh [--best-effort]
#
# The published state/home-summary.json is the exact
# `fm-fleet-snapshot.sh --secondmate-home-summary` document for this FM_HOME.
# Its schema remains `fm-secondmate-home-summary.v1`, declares the current hold
# classifier contract, and includes both the existing generated timestamp and
# generated_epoch for freshness arithmetic.
#
# Publication is atomic: the producer writes and validates a unique mode-0600
# temporary file on the state directory's filesystem, then renames it over the
# ledger. After a failed, interrupted, or killed refresh, the ledger path holds
# either the prior complete document or the new complete document, never torn output.
# A home-local refresh lock serializes concurrent triggers so an older in-flight
# summary cannot overwrite one computed after a later status change. The shared
# timeout owner gives acquisition and publication FM_HOME_SUMMARY_TIMEOUT
# (default 60 seconds), followed by a failure-recording and lock-cleanup grace
# of 3 seconds with an exec-capable timer or 1 second with the Bash fallback.
# No reader can observe temporary output through the ledger path.
#
# A failed refresh never rewrites the ledger, so the last good summary keeps its
# own generated and generated_epoch values: readers see its true age, never the
# time of the failed attempt. The producer reports each stage it enters to a
# per-attempt stage file (FM_SNAPSHOT_STAGE_FD), and a failed attempt, whether
# it hit the deadline or the worker handled the failure itself, logs the stage it
# was in plus the stage start offsets, so a slow or failing stage is named in
# state/.home-summary-refresh.log instead of a bare deadline.
# The worker adds its own stages to that file: lock-wait, producer, validate and
# publish, with the producer's stages between producer and validate.
# The parent only names the file; the worker creates and opens it, so opening it
# counts against the deadline too. Every later parent-side read or removal of the
# file runs under its own 2-second limit, and a worker whose parent is gone
# removes the file itself. Only a path under the state directory named like the
# default is ever used, so a stray FM_HOME_SUMMARY_STAGE_PATH is ignored.
#
# With --best-effort, a failure is appended to the bounded home-local
# state/.home-summary-refresh.log when available, with stderr as the bounded
# fallback, and the command exits zero. Session start, watcher, spawn, and
# teardown use that mode so this side-band publication can never change their
# result. Without it, failures are printed and returned to the direct caller
# for tests and diagnostics.
#
# A refresh that fails while holding the publication lock records backoff
# before releasing it, delaying the next --best-effort attempt: the
# delay doubles after each consecutive failure, from 30 seconds up to
# 1800 seconds. Eligibility is rechecked under that lock, and a publication
# clears the record. An attempt skipped for a busy lock or active backoff
# leaves the record unchanged.
# The record is state/.home-summary-refresh.backoff (failures and the next
# permitted attempt epoch). A direct call without --best-effort bypasses backoff,
# so tests and diagnostics are never deferred. This is the interim relief
# until the producer itself is fast enough that failures stop recurring.
# Concurrent best-effort workers coalesce at a nonblocking per-home admission
# lock, state/.home-summary-flight.lock, inside the same whole-refresh deadline.
# It is one waiting slot: a worker holds it only until it takes the publication
# lock, so a trigger arriving during a collection still queues for a pass of its
# own, and any further trigger exits zero because that queued pass has not
# collected yet. An FM_HOME_SUMMARY_IF_IDLE try never waits, so it skips the
# slot and cannot stand in for a queued pass. Explicit synchronous callers keep
# the publication-lock wait and failure contract above.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
LEDGER="$STATE/home-summary.json"
BACKOFF_FILE="$STATE/.home-summary-refresh.backoff"
BACKOFF_BASE=30
BACKOFF_MAX=1800
ERROR_LOG="$STATE/.home-summary-refresh.log"
REFRESH_LOCK="$STATE/.home-summary-refresh.lock"
ERROR_LOG_MAX_BYTES=${FM_HOME_SUMMARY_ERROR_LOG_MAX_BYTES:-65536}
HOME_SUMMARY_TIMEOUT=${FM_HOME_SUMMARY_TIMEOUT:-60}
HOME_SUMMARY_IF_IDLE=${FM_HOME_SUMMARY_IF_IDLE:-0}
BEST_EFFORT=0
HOME_SUMMARY_MODE=parent
HOME_SUMMARY_ERROR=
HOME_SUMMARY_FAILURE_STAMP=
HOME_SUMMARY_TMP=
HOME_SUMMARY_ERR_TMP=
HOME_SUMMARY_LOCK_HELD=0
HOME_SUMMARY_FLIGHT_HELD=0

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

# shellcheck source=bin/fm-clock-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-clock-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  '') ;;
  --best-effort) BEST_EFFORT=1 ;;
  --_worker)
    HOME_SUMMARY_MODE=worker
    BEST_EFFORT=${FM_HOME_SUMMARY_WORKER_BEST_EFFORT:-0}
    ;;
  --_log-failure) HOME_SUMMARY_MODE=log-failure ;;
  --_stage-note) HOME_SUMMARY_MODE=stage-note ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
case "$ERROR_LOG_MAX_BYTES" in
  ''|*[!0-9]*|0) ERROR_LOG_MAX_BYTES=65536 ;;
esac
case "$HOME_SUMMARY_TIMEOUT" in
  ''|*[!0-9]*|0*) HOME_SUMMARY_TIMEOUT=60 ;;
esac
case "$HOME_SUMMARY_IF_IDLE" in
  0|1) ;;
  *) HOME_SUMMARY_IF_IDLE=0 ;;
esac
BACKOFF_FAILURES=0
BACKOFF_NEXT=0
backoff_read() {
  local line key value
  BACKOFF_FAILURES=0
  BACKOFF_NEXT=0
  [ -f "$BACKOFF_FILE" ] || return 0
  while IFS= read -r line; do
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      failures) case "$value" in ''|*[!0-9]*) ;; *) BACKOFF_FAILURES=$value ;; esac ;;
      next) case "$value" in ''|*[!0-9]*) ;; *) BACKOFF_NEXT=$value ;; esac ;;
    esac
  done < "$BACKOFF_FILE" 2>/dev/null || true
}

backoff_delay() {  # <consecutive-failures>
  local delay=$BACKOFF_BASE i=1
  while [ "$i" -lt "$1" ] && [ "$delay" -lt "$BACKOFF_MAX" ]; do
    delay=$((delay * 2))
    [ "$delay" -le "$BACKOFF_MAX" ] || delay=$BACKOFF_MAX
    i=$((i + 1))
  done
  printf '%s\n' "$delay"
}

backoff_active() {
  local now
  [ "$BEST_EFFORT" -eq 1 ] || return 1
  now=$(fm_now 2>/dev/null) || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  backoff_read
  [ "$BACKOFF_NEXT" -gt "$now" ]
}

backoff_record_failure() {  # <now-epoch>
  local failures delay tmp
  backoff_read
  failures=$((BACKOFF_FAILURES + 1))
  delay=$(backoff_delay "$failures")
  [ -d "$STATE" ] || return 0
  tmp="$BACKOFF_FILE.tmp.${BASHPID:-$$}"
  (umask 077; printf 'failures=%s\nnext=%s\n' "$failures" "$(($1 + delay))" > "$tmp") 2>/dev/null \
    && mv -f -- "$tmp" "$BACKOFF_FILE" 2>/dev/null \
    || rm -f -- "$tmp" 2>/dev/null || true
}

if [ "$HOME_SUMMARY_MODE" = worker ] && backoff_active; then
  exit 0
fi

if [ "$HOME_SUMMARY_MODE" = worker ]; then
  # shellcheck source=bin/fm-wake-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
fi

# shellcheck disable=SC2329 # Invoked by the signal and EXIT traps below.
home_summary_cleanup() {
  local exit_rc=$? backoff_failure_now cleanup_pid
  trap '' HUP INT TERM
  if [ "$HOME_SUMMARY_LOCK_HELD" -eq 1 ] \
      && { [ "$exit_rc" -ne 0 ] || [ -n "$HOME_SUMMARY_ERROR" ]; } \
      && fm_current_pid cleanup_pid && [ "$cleanup_pid" = "$$" ]; then
    backoff_failure_now=$(fm_now 2>/dev/null) || backoff_failure_now=
    case "$backoff_failure_now" in
      ''|*[!0-9]*) ;;
      *) backoff_record_failure "$backoff_failure_now" ;;
    esac
  fi
  home_summary_stage_orphan_cleanup
  [ -z "$HOME_SUMMARY_TMP" ] || rm -f -- "$HOME_SUMMARY_TMP" 2>/dev/null || true
  [ -z "$HOME_SUMMARY_ERR_TMP" ] || rm -f -- "$HOME_SUMMARY_ERR_TMP" 2>/dev/null || true
  if [ "$HOME_SUMMARY_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$REFRESH_LOCK" || true
    HOME_SUMMARY_LOCK_HELD=0
  fi
  if [ "$HOME_SUMMARY_FLIGHT_HELD" -eq 1 ]; then
    fm_lock_release "$STATE/.home-summary-flight.lock" || true
    HOME_SUMMARY_FLIGHT_HELD=0
  fi
}

# Only a stage file under this home's state directory, named like the parent's
# own, is ever read, appended to or removed: a stray environment value must not
# point the refresh at an unrelated file.
home_summary_stage_path_ok() {  # <path>
  case "$1" in
    "$STATE"/.home-summary-stage.*) return 0 ;;
  esac
  return 1
}

# A worker whose parent is gone (killed, or signalled before the worker opened
# the file) would leave the stage file behind, because the parent's cleanup ran
# before the file existed. The worker removes it itself in that case.
home_summary_stage_orphan_cleanup() {
  [ "$HOME_SUMMARY_MODE" = worker ] || return 0
  [ -n "${FM_HOME_SUMMARY_STAGE_FILE:-}" ] || return 0
  case "${FM_HOME_SUMMARY_PARENT_PID:-}" in
    ''|*[!0-9]*) return 0 ;;
  esac
  home_summary_stage_path_ok "$FM_HOME_SUMMARY_STAGE_FILE" || return 0
  kill -0 "$FM_HOME_SUMMARY_PARENT_PID" 2>/dev/null && return 0
  rm -f -- "$FM_HOME_SUMMARY_STAGE_FILE" 2>/dev/null || true
}

# Record that the worker entered <stage>, at its seconds since the worker
# started, on the stage descriptor the worker opened itself. Like the producer's own
# stage reports, it writes through that descriptor and never by path, so a stage
# file the parent already removed is not recreated.
home_summary_stage() {  # <stage-name>
  case "${FM_SNAPSHOT_STAGE_FD:-}" in
    ''|*[!0-9]*) return 0 ;;
  esac
  { printf '%s\t%s\n' "$1" "$SECONDS" >&"$FM_SNAPSHOT_STAGE_FD"; } 2>/dev/null || true
}

home_summary_fail() {
  HOME_SUMMARY_ERROR=$1
  return 1
}

home_summary_refresh_once() {
  local producer_rc producer_error validation_rc remaining
  if ! mkdir -p "$STATE" 2>/dev/null; then
    home_summary_fail "state directory is unavailable: $STATE"
    return 1
  fi
  HOME_SUMMARY_TMP=$(umask 077; mktemp "$STATE/.home-summary.json.XXXXXX") || {
    home_summary_fail "could not create an atomic publication file in $STATE"
    return 1
  }
  HOME_SUMMARY_ERR_TMP=$(umask 077; mktemp "$STATE/.home-summary-error.XXXXXX") || {
    home_summary_fail "could not create a producer diagnostic file in $STATE"
    return 1
  }

  home_summary_stage producer
  remaining=$((HOME_SUMMARY_TIMEOUT - SECONDS))
  [ "$remaining" -gt 0 ] || return 124
  # Nested work must also stop when this lock owner dies, even if the parent's
  # bounded descendant snapshot stalls. The Bash watchdog tracks its caller;
  # an independent external timer otherwise keeps running until its deadline.
  if fm_run_timed_fn "$remaining" env \
    FM_SNAPSHOT_STAGE_BASE="$SECONDS" \
    FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_HOME="$FM_HOME" \
    FM_STATE_OVERRIDE="$STATE" \
    FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$PROJECTS" \
    "$SCRIPT_DIR/fm-fleet-snapshot.sh" --secondmate-home-summary \
      > "$HOME_SUMMARY_TMP" 2> "$HOME_SUMMARY_ERR_TMP"; then
    producer_rc=0
  else
    producer_rc=$?
  fi
  [ "$producer_rc" -ne 124 ] || return 124
  if [ "$producer_rc" -ne 0 ]; then
    producer_error=$(tail -n 1 "$HOME_SUMMARY_ERR_TMP" 2>/dev/null \
      | tr '\t\r\n' '   ' | cut -c1-500)
    if [ -n "$producer_error" ]; then
      home_summary_fail "summary producer failed with exit $producer_rc: $producer_error"
    else
      home_summary_fail "summary producer failed with exit $producer_rc"
    fi
    return 1
  fi
  rm -f -- "$HOME_SUMMARY_ERR_TMP"
  HOME_SUMMARY_ERR_TMP=
  home_summary_stage validate
  remaining=$((HOME_SUMMARY_TIMEOUT - SECONDS))
  [ "$remaining" -gt 0 ] || return 124
  # shellcheck disable=SC2016 # jq, not the shell, expands $home.
  if fm_run_timed_fn "$remaining" jq -e --arg home "$FM_HOME" '
    .schema == "fm-secondmate-home-summary.v1"
    and .hold_classifier_schema == "fm-captain-hold-buckets.v1"
    and .home == $home
    and (.generated | type) == "string"
    and (.generated | length) > 0
    and (.generated_epoch | type) == "number"
    and .generated_epoch >= 0
    and (.generated_epoch | floor) == .generated_epoch
    and (.valid | type) == "boolean"
    and (.state | type) == "string"
    and (.invalidity | type) == "object"
    and (.active_children | type) == "array"
    and (.decisions_open | type) == "array"
    and (.holds | type) == "array"
    and (.queued | type) == "array"
    and (.landed | type) == "array"
    and (.endpoints | type) == "array"
    and (.counts | type) == "object"
    and (.omitted | type) == "array"
  ' "$HOME_SUMMARY_TMP" >/dev/null 2>&1; then
    :
  else
    validation_rc=$?
    [ "$validation_rc" -ne 124 ] || return 124
    home_summary_fail "summary producer returned a malformed ledger document"
    return 1
  fi
  home_summary_stage publish
  [ "$SECONDS" -lt "$HOME_SUMMARY_TIMEOUT" ] || return 124
  if ! chmod 600 "$HOME_SUMMARY_TMP" 2>/dev/null; then
    home_summary_fail "could not set the publication file mode"
    return 1
  fi
  [ "$SECONDS" -lt "$HOME_SUMMARY_TIMEOUT" ] || return 124
  if ! mv -f -- "$HOME_SUMMARY_TMP" "$LEDGER" 2>/dev/null; then
    home_summary_fail "atomic ledger replacement failed: $LEDGER"
    return 1
  fi
  HOME_SUMMARY_TMP=
  return 0
}

home_summary_log_failure() {
  local size stamp tmp
  stamp=$HOME_SUMMARY_FAILURE_STAMP
  [ -n "$stamp" ] || stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if ! printf '[%s] %s\n' "$stamp" "$HOME_SUMMARY_ERROR" >> "$ERROR_LOG" 2>/dev/null; then
    printf 'fm-home-summary-refresh: %s\n' "$HOME_SUMMARY_ERROR" >&2
    return 0
  fi
  size=$(wc -c < "$ERROR_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if [ "$size" -ge "$ERROR_LOG_MAX_BYTES" ]; then
    tmp="$ERROR_LOG.tmp.${BASHPID:-$$}"
    tail -n 200 "$ERROR_LOG" > "$tmp" 2>/dev/null \
      && mv -f -- "$tmp" "$ERROR_LOG" 2>/dev/null
    rm -f -- "$tmp" 2>/dev/null || true
  fi
}

if [ "$HOME_SUMMARY_MODE" = log-failure ]; then
  HOME_SUMMARY_ERROR=${FM_HOME_SUMMARY_PARENT_ERROR:-"refresh worker failed"}
  HOME_SUMMARY_FAILURE_STAMP=${FM_HOME_SUMMARY_PARENT_STAMP:-}
  home_summary_log_failure
  exit 0
fi

# Name the stage a failed attempt was in, from the producer's stage file:
# "in stage <last stage> (stages: <stage>@<seconds> ...)", or nothing when the
# producer never reported one.
home_summary_stage_note() {  # <stage-file>
  local file=$1 last all
  [ -s "$file" ] || return 0
  # A read that fails is not an empty file: report it as unreadable (status 1),
  # never as a worker that recorded no stage.
  last=$(tail -n 1 "$file" 2>/dev/null) || return 1
  last=${last%%$'\t'*}
  [ -n "$last" ] || return 0
  all=$(cut -f1,2 "$file" 2>/dev/null) || return 1
  all=$(printf '%s\n' "$all" | tr '\t' '@' | tr '\n' ' ' | sed 's/ $//' | cut -c1-300)
  printf ' in stage %s (stages: %s)' "$last" "$all"
}

if [ "$HOME_SUMMARY_MODE" = stage-note ]; then
  # Run by the parent under its own short limit, so reading the stage file on a
  # stalled filesystem cannot hold the caller.
  if home_summary_stage_path_ok "${2:-}"; then
    home_summary_stage_note "$2" || exit 1
  fi
  exit 0
fi

# Remove a stage file without letting a stalled filesystem hold the caller.
home_summary_stage_remove() {  # <path>
  [ -n "$1" ] || return 0
  fm_run_timed 2 rm -f -- "$1" >/dev/null 2>&1 || true
}

if [ "$HOME_SUMMARY_MODE" = parent ]; then
  attempt_stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || attempt_stamp=
  stage_file=
  home_summary_runner_pid=
  home_summary_runner_starting=0
  home_summary_parent_signal=
  # A signalled parent must not leave its stage file behind in state/, so the
  # traps are registered before the file can exist.
  # shellcheck disable=SC2329 # Invoked by the signal and EXIT traps below.
  home_summary_parent_cleanup() {
    # Catch repeats without exporting ignored signals into cleanup helpers.
    trap ':' HUP INT TERM
    if [ -n "$home_summary_runner_pid" ]; then
      # This is our unreaped child. Snapshot before signalling so helpers in
      # their own process groups are also stopped under their exact identities.
      # The parent deliberately does not source the state-initializing wake
      # library. Load it inside a bounded helper, including that initialization.
      # shellcheck disable=SC2016 # Helper arguments expand in the child shell.
      fm_run_timed 4 bash -c '
        . "$1/fm-wake-lib.sh"
        identity=$(fm_pid_identity "$2") || exit 0
        fm_watcher_stop_tree "$2" "$identity" 3
      ' _ "$SCRIPT_DIR" "$home_summary_runner_pid" >/dev/null 2>&1 || true
      kill -TERM "$home_summary_runner_pid" 2>/dev/null || true
      wait "$home_summary_runner_pid" 2>/dev/null || true
    fi
    home_summary_stage_remove "$stage_file"
  }
  # A signal can arrive between starting the child and assigning $!. Retain it
  # until that assignment, then exit through the same owned-child cleanup.
  # shellcheck disable=SC2329 # Invoked by the signal traps below.
  home_summary_parent_cancel() {
    home_summary_parent_signal=$1
    if [ "$home_summary_runner_starting" -eq 1 ] && [ -z "$home_summary_runner_pid" ]; then
      return
    fi
    exit "$home_summary_parent_signal"
  }
  trap home_summary_parent_cleanup EXIT
  trap 'home_summary_parent_cancel 129' HUP
  trap 'home_summary_parent_cancel 130' INT
  trap 'home_summary_parent_cancel 143' TERM
  # The parent only names the stage file; the worker creates and opens it inside
  # the deadline. Every later parent-side touch of that path (reading the stage,
  # removing the file) runs under its own short limit, so a stalled state
  # filesystem cannot hold the caller past the deadline. A worker that outlives
  # its parent removes the file itself.
  # FM_HOME_SUMMARY_STAGE_PATH is a test seam, honored only for a path under the
  # state directory named like the default.
  stage_file="$STATE/.home-summary-stage.$$.$RANDOM"
  if [ -n "${FM_HOME_SUMMARY_STAGE_PATH:-}" ] \
      && home_summary_stage_path_ok "$FM_HOME_SUMMARY_STAGE_PATH"; then
    stage_file=$FM_HOME_SUMMARY_STAGE_PATH
  fi
  # Keep the exec timer's owner guarantees where available, and the existing
  # bounded Bash runner on hosts without an exec-capable timer.
  home_summary_runner=(fm_exec_timed "$HOME_SUMMARY_TIMEOUT" 3)
  if [ "$(fm_timeout_mechanism)" = bash ]; then
    home_summary_runner=(fm_run_timed "$HOME_SUMMARY_TIMEOUT")
  fi
  # Run synchronously inside the explicit background subshell below. Bash 3.2
  # can lose a timer's status in an implicitly backgrounded function body.
  home_summary_worker_start() {
    trap - EXIT HUP INT TERM
    "${home_summary_runner[@]}" env \
    FM_HOME_SUMMARY_WORKER_BEST_EFFORT="$BEST_EFFORT" \
    FM_HOME_SUMMARY_IF_IDLE="$HOME_SUMMARY_IF_IDLE" \
    FM_HOME_SUMMARY_STAGE_FILE="$stage_file" \
    FM_HOME_SUMMARY_PARENT_PID="$$" \
      "$SCRIPT_DIR/fm-home-summary-refresh.sh" --_worker
  }
  [ -z "$home_summary_parent_signal" ] || exit "$home_summary_parent_signal"
  home_summary_runner_starting=1
  # Background the subshell itself, so $! names the timer's lifetime owner
  # rather than a function wrapper that can die while that owner stays alive.
  if fm_timeout_stdin_is_redirected; then
    { (home_summary_worker_start) 0<&3 3<&- & } 3<&0
  else
    (home_summary_worker_start) </dev/null &
  fi
  home_summary_runner_pid=$!
  home_summary_runner_starting=0
  [ -z "$home_summary_parent_signal" ] || exit "$home_summary_parent_signal"
  # The wait builtin handles process-directed signals immediately; a foreground
  # runner would defer the public parent's cancellation traps until its deadline.
  if wait "$home_summary_runner_pid"; then
    home_summary_runner_pid=
    home_summary_stage_remove "$stage_file"
    stage_file=
    exit 0
  else
    refresh_rc=$?
  fi
  home_summary_runner_pid=
  if stage_note=$(fm_run_timed 2 "$SCRIPT_DIR/fm-home-summary-refresh.sh" \
      --_stage-note "$stage_file" 2>/dev/null); then
    if [ -z "$stage_note" ] && [ "$refresh_rc" -eq 124 ]; then
      stage_note=" before its first stage"
    fi
  else
    stage_note=" (stage unreadable)"
  fi
  home_summary_stage_remove "$stage_file"
  stage_file=
  if [ "$BEST_EFFORT" -eq 1 ]; then
    if [ "$refresh_rc" -eq 124 ]; then
      parent_error="refresh exceeded its ${HOME_SUMMARY_TIMEOUT}-second deadline${stage_note}"
    else
      parent_error="refresh worker failed with exit $refresh_rc${stage_note}"
    fi
    fm_run_timed 2 env \
      FM_HOME_SUMMARY_PARENT_ERROR="$parent_error" \
      FM_HOME_SUMMARY_PARENT_STAMP="$attempt_stamp" \
      "$SCRIPT_DIR/fm-home-summary-refresh.sh" --_log-failure >/dev/null || true
    exit 0
  fi
  if [ "$refresh_rc" -eq 124 ]; then
    printf 'fm-home-summary-refresh: refresh exceeded its %s-second deadline%s\n' \
      "$HOME_SUMMARY_TIMEOUT" "$stage_note" >&2
  fi
  exit "$refresh_rc"
fi

# The worker opens the parent's stage file itself, inside the deadline, and keeps
# the descriptor so a stage file the parent already removed is never recreated by
# a later append. The wake library, sourced before this point, already creates
# the state directory, so a fresh home reports its stages too.
FM_SNAPSHOT_STAGE_FD=
if [ -n "${FM_HOME_SUMMARY_STAGE_FILE:-}" ] \
    && home_summary_stage_path_ok "$FM_HOME_SUMMARY_STAGE_FILE" \
    && [ -d "$STATE" ]; then
  stage_umask=$(umask)
  umask 077
  if { exec 9>>"$FM_HOME_SUMMARY_STAGE_FILE"; } 2>/dev/null; then
    FM_SNAPSHOT_STAGE_FD=9
  fi
  umask "$stage_umask"
fi
export FM_SNAPSHOT_STAGE_FD

trap home_summary_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if [ "$BEST_EFFORT" -eq 1 ] && [ "$HOME_SUMMARY_IF_IDLE" -eq 0 ]; then
  fm_lock_try_acquire "$STATE/.home-summary-flight.lock" || exit 0
  HOME_SUMMARY_FLIGHT_HELD=1
fi
if [ "$HOME_SUMMARY_IF_IDLE" -eq 1 ]; then
  fm_lock_try_acquire "$REFRESH_LOCK" || exit 0
else
  home_summary_stage lock-wait
  remaining=$((HOME_SUMMARY_TIMEOUT - SECONDS))
  [ "$remaining" -gt 0 ] || exit 124
  fm_lock_acquire_wait_bounded "$REFRESH_LOCK" "$remaining" || exit "$?"
fi
HOME_SUMMARY_LOCK_HELD=1
# The admission lock is the one waiting slot, not the running pass: free it now
# so a trigger arriving during this collection queues for a pass of its own.
if [ "$HOME_SUMMARY_FLIGHT_HELD" -eq 1 ]; then
  fm_lock_release "$STATE/.home-summary-flight.lock" || true
  HOME_SUMMARY_FLIGHT_HELD=0
fi
backoff_active && exit 0
if home_summary_refresh_once; then
  rm -f -- "$BACKOFF_FILE" 2>/dev/null || true
  exit 0
else
  refresh_rc=$?
fi
[ "$refresh_rc" -ne 124 ] || exit 124

# A failure the worker handled itself names its stage too, like a deadline the
# parent reports, so every failed refresh says where it stopped.
if [ -n "${FM_HOME_SUMMARY_STAGE_FILE:-}" ] \
    && home_summary_stage_path_ok "$FM_HOME_SUMMARY_STAGE_FILE"; then
  HOME_SUMMARY_ERROR="$HOME_SUMMARY_ERROR$(home_summary_stage_note "$FM_HOME_SUMMARY_STAGE_FILE")"
fi
if [ "$BEST_EFFORT" -eq 1 ]; then
  home_summary_log_failure
  exit 0
fi
printf 'fm-home-summary-refresh: %s\n' "$HOME_SUMMARY_ERROR" >&2
exit "$refresh_rc"
