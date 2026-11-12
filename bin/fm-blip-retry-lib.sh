#!/usr/bin/env bash
# fm-blip-retry-lib.sh - retry one command across a transient Orca or SSH blip.
#
# Sourced, never executed. This is the single owner of that retry.
#
#   fm_blip_retry <command> [args...]
#       Run the command. Success returns its status and passes its stdout and
#       stderr through. A definite failure is returned at once, once: not
#       found, permission denied, or a usage error. A transient failure is
#       retried: connection refused, connection reset, timeout, a missing
#       socket, or an HTTP 5xx. The wait starts at FM_BLIP_RETRY_BASE_SECS
#       (default 2), doubles each time, and is capped at
#       FM_BLIP_RETRY_CAP_SECS (default 32). Retries stop once
#       FM_BLIP_RETRY_BUDGET_SECS (default 300) have elapsed since the first
#       attempt, and that failing attempt is then reported once. Earlier
#       attempts are discarded. A wait that would pass the budget is shortened
#       to the time remaining; the next attempt does not start after the
#       budget. Each attempt sees the caller's stdin. A caller that must
#       replay stdin across attempts has to spool it first.
#
#       Unset overrides use the defaults. A set override must be an integer.
#       The base and the cap must be >= 1, and the cap must be >= the base.
#       The budget may be 0, which runs one attempt and does not retry.
#
#   fm_blip_now
#   fm_blip_sleep <seconds>
#       The clock and the wait. With FM_TEST_SEAM=1 and FM_BLIP_NOW set to an
#       integer epoch, fm_blip_now prints that epoch and fm_blip_sleep adds the
#       requested seconds to it instead of waiting. FM_BLIP_SLEEP_LOG, when
#       set, receives one line per wait. Any other state uses the real clock
#       and sleep. The seam is how a test crosses the five-minute budget
#       without waiting.

fm_blip_now() {
  if [ "${FM_TEST_SEAM:-}" = 1 ]; then
    case "${FM_BLIP_NOW:-}" in
      ''|*[!0-9]*) ;;
      *) printf '%s\n' "$FM_BLIP_NOW"; return 0 ;;
    esac
  fi
  date +%s
}

fm_blip_sleep() {
  local secs=$1
  case "$secs" in
    ''|*[!0-9]*) printf 'fm-blip-retry: sleep seconds must be an integer\n' >&2; return 1 ;;
  esac
  if [ "${FM_TEST_SEAM:-}" = 1 ]; then
    case "${FM_BLIP_NOW:-}" in
      ''|*[!0-9]*) ;;
      *)
        FM_BLIP_NOW=$((FM_BLIP_NOW + secs))
        if [ -n "${FM_BLIP_SLEEP_LOG:-}" ]; then
          printf '%s\n' "$secs" >> "$FM_BLIP_SLEEP_LOG" || return 1
        fi
        return 0
        ;;
    esac
  fi
  sleep "$secs"
}

# 0 when the failure text is a transient blip. Definite answers win, so a
# permission or usage failure is not retried just because it also says timeout.
# A missing socket is transient even when its text also says it was not found.
fm_blip_text_is_transient() {
  local text
  text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$text" in
    *'permission denied'*|*'usage error'*|*'usage:'*) return 1 ;;
  esac
  case "$text" in
    *'socket missing'*|*'socket is missing'*|*'missing socket'*|*'control socket'*) return 0 ;;
    *socket*'not found'*|*'not found'*socket*) return 0 ;;
    *'no such file or directory'*)
      case "$text" in
        *socket*) return 0 ;;
      esac
      ;;
  esac
  case "$text" in
    *'not found'*) return 1 ;;
  esac
  case "$text" in
    *'connection refused'*|*'connection reset'*|*'econnrefused'*|*'econnreset'*) return 0 ;;
    *'timed out'*|*'etimedout'*|*'timeout'*) return 0 ;;
    *'service unavailable'*|*'bad gateway'*) return 0 ;;
    *' 5xx'*|*'5xx '*|*'5xx'*) return 0 ;;
  esac
  if printf '%s\n' "$text" | grep -Eq '(^|[^0-9])(status|http|error|code)[^0-9]{0,16}5[0-9][0-9]([^0-9]|$)'; then
    return 0
  fi
  return 1
}

fm_blip_retry_number() { # <name> <default> <minimum>
  local name=$1 default=$2 min=$3 value
  value=${!name-}
  if [ -z "$value" ]; then
    printf '%s\n' "$default"
    return 0
  fi
  case "$value" in
    *[!0-9]*) printf 'fm-blip-retry: %s must be an integer\n' "$name" >&2; return 1 ;;
  esac
  value=$((10#$value))
  if [ "$value" -lt "$min" ]; then
    printf 'fm-blip-retry: %s must be >= %s\n' "$name" "$min" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

fm_blip_retry_emit() { # <dir>
  cat "$1/out"
  cat "$1/err" >&2
  rm -rf -- "$1"
}

fm_blip_retry() {
  local start now elapsed delay wait base cap budget rc=0 attempt=0
  local dir text errexit=0
  [ "$#" -ge 1 ] || { printf 'fm-blip-retry: command required\n' >&2; return 2; }
  base=$(fm_blip_retry_number FM_BLIP_RETRY_BASE_SECS 2 1) || return 2
  cap=$(fm_blip_retry_number FM_BLIP_RETRY_CAP_SECS 32 1) || return 2
  budget=$(fm_blip_retry_number FM_BLIP_RETRY_BUDGET_SECS 300 0) || return 2
  [ "$cap" -ge "$base" ] || {
    printf 'fm-blip-retry: FM_BLIP_RETRY_CAP_SECS is below FM_BLIP_RETRY_BASE_SECS\n' >&2
    return 2
  }
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-blip-retry.XXXXXX") || return 1
  : > "$dir/out"
  : > "$dir/err"
  start=$(fm_blip_now) || { rm -rf -- "$dir"; return 1; }
  case "$start" in
    ''|*[!0-9]*) printf 'fm-blip-retry: clock is not an integer epoch\n' >&2; rm -rf -- "$dir"; return 1 ;;
  esac
  delay=$base
  while true; do
    now=$(fm_blip_now) || { fm_blip_retry_emit "$dir"; return 1; }
    case "$now" in
      ''|*[!0-9]*) printf 'fm-blip-retry: clock is not an integer epoch\n' >&2; fm_blip_retry_emit "$dir"; return 1 ;;
    esac
    if [ "$attempt" -gt 0 ] && [ $((now - start)) -ge "$budget" ]; then
      break
    fi
    : > "$dir/out"
    : > "$dir/err"
    errexit=0
    case $- in *e*) errexit=1; set +e ;; esac
    "$@" > "$dir/out" 2> "$dir/err"
    rc=$?
    [ "$errexit" -eq 1 ] && set -e
    attempt=$((attempt + 1))
    if [ "$rc" -eq 0 ]; then
      fm_blip_retry_emit "$dir"
      return 0
    fi
    text=$(cat "$dir/out" "$dir/err")
    if ! fm_blip_text_is_transient "$text"; then
      break
    fi
    now=$(fm_blip_now) || { fm_blip_retry_emit "$dir"; return 1; }
    elapsed=$((now - start))
    if [ "$elapsed" -ge "$budget" ]; then
      break
    fi
    wait=$delay
    [ "$wait" -le "$cap" ] || wait=$cap
    [ "$wait" -le $((budget - elapsed)) ] || wait=$((budget - elapsed))
    if [ "$wait" -le 0 ]; then
      break
    fi
    fm_blip_sleep "$wait" || { fm_blip_retry_emit "$dir"; return 1; }
    if [ "$delay" -le $((cap / 2)) ]; then
      delay=$((delay * 2))
    else
      delay=$cap
    fi
  done
  fm_blip_retry_emit "$dir"
  return "$rc"
}
