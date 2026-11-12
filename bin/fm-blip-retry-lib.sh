#!/usr/bin/env bash
# fm-blip-retry-lib.sh - retry one command across a transient Orca or SSH blip.
#
# Sourced, never executed. This is the single owner of that retry.
#
#   fm_blip_retry [--connect-only|--ssh-connect] [--read] <command> [args...]
#       Run the command. Success returns its status and passes its stdout and
#       stderr through. A definite failure is returned at once, once: not
#       found, permission denied, or a usage error. A transient failure is
#       retried: connection refused, connection reset, timed out, a missing
#       socket, an Orca CLI connect failure (code runtime_unavailable, or the
#       text "This terminal could not connect to Orca."), or an HTTP 5xx,
#       service unavailable, or bad gateway. The wait
#       starts at FM_BLIP_RETRY_BASE_SECS (default 2), doubles each time, and
#       is capped at FM_BLIP_RETRY_CAP_SECS (default 32). Retries stop once
#       FM_BLIP_RETRY_BUDGET_SECS (default 300) have elapsed since the first
#       attempt, and that failing attempt is then reported once. Earlier
#       attempts are discarded. A wait that would pass the budget is shortened
#       to the time remaining; the next attempt does not start after the
#       budget. Each attempt sees the caller's stdin. A caller that must
#       replay stdin across attempts has to spool it first.
#
#       --connect-only is for a command that is not safe to repeat once it
#       may have taken effect. Only the attempt's stderr is classified, and
#       only a failure to connect at all is transient: connection refused,
#       could not resolve the host, no route, a connect that timed out, a
#       connection closed before the session began, a missing socket, or an
#       Orca CLI connect failure (code runtime_unavailable, or the text
#       "This terminal could not connect to Orca."). A reset, a mid-session
#       timeout, or an HTTP 5xx is reported once.
#
#       --ssh-connect is the same rule for an ssh command whose stderr also
#       carries the remote command's own stderr. Only an exit 255 is retried,
#       and only when a stderr line is one ssh prints before any session
#       exists: `ssh: connect to host <h> port <n>: ` followed by refused,
#       timed out, no route, or unreachable, or `ssh: Could not resolve
#       hostname`. No other text is classified.
#
#       --read is for a read-only probe on a supervision path, where a long
#       wait would stall the sweep that called it. Its budget is
#       FM_BLIP_RETRY_READ_BUDGET_SECS (default 15) instead of the 300-second
#       budget, and it then fails exactly as a single attempt would.
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

FM_BLIP_RETRY_BUDGET_DEFAULT=300
FM_BLIP_RETRY_READ_BUDGET_DEFAULT=15

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

fm_blip_text_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# 0 when the text names a definite answer that no retry can change.
fm_blip_text_is_definite() {
  case "$1" in
    *'permission denied'*|*'usage error'*|*'usage:'*) return 0 ;;
  esac
  return 1
}

# 0 when the text names a missing socket, even when it also says not found.
fm_blip_text_is_missing_socket() {
  case "$1" in
    *'socket missing'*|*'socket is missing'*|*'missing socket'*|*'control socket'*) return 0 ;;
    *socket*'not found'*|*'not found'*socket*) return 0 ;;
    *socket*'no such file or directory'*|*'no such file or directory'*socket*) return 0 ;;
  esac
  return 1
}

# 0 when the failure text is a transient blip. Definite answers win, so a
# permission or usage failure is not retried just because it also timed out.
fm_blip_text_is_transient() {
  local text
  text=$(fm_blip_text_lower "$1")
  fm_blip_text_is_definite "$text" && return 1
  fm_blip_text_is_missing_socket "$text" && return 0
  case "$text" in
    *'not found'*) return 1 ;;
  esac
  case "$text" in
    *'connection refused'*|*'connection reset'*|*'econnrefused'*|*'econnreset'*) return 0 ;;
    *'this terminal could not connect to orca'*|*'runtime_unavailable'*) return 0 ;;
    *'timed out'*|*'etimedout'*) return 0 ;;
    *'service unavailable'*|*'bad gateway'*|*'gateway timeout'*) return 0 ;;
  esac
  if printf '%s\n' "$text" | grep -Eq '(^|[^a-z])(http(/[0-9.]+)?|status( code)?)[ :=]+5[0-9][0-9]([^0-9]|$)'; then
    return 0
  fi
  return 1
}

# 0 when the failure text proves the command never reached its target, so a
# repeat cannot duplicate an action that already landed.
fm_blip_text_is_connect_failure() {
  local text
  text=$(fm_blip_text_lower "$1")
  fm_blip_text_is_definite "$text" && return 1
  fm_blip_text_is_missing_socket "$text" && return 0
  case "$text" in
    *'connection refused'*|*'econnrefused'*) return 0 ;;
    *'this terminal could not connect to orca'*|*'runtime_unavailable'*) return 0 ;;
    *'could not resolve'*|*'name or service not known'*|*'nodename nor servname'*) return 0 ;;
    *'no route to host'*|*'network is unreachable'*|*'ehostunreach'*|*'enetunreach'*) return 0 ;;
    *'connect to host'*'timed out'*|*'connect etimedout'*) return 0 ;;
    *'connection closed by'*|*'kex_exchange_identification'*) return 0 ;;
  esac
  return 1
}

# 0 when a stderr line is ssh's own report that it never opened a session.
fm_blip_text_is_ssh_connect_failure() {
  fm_blip_text_lower "$1" | grep -Eq \
    -e '^ssh: connect to host [^ ]+ port [0-9]+: (connection refused|(operation|connection) timed out|no route to host|(network|host) is unreachable)' \
    -e '^ssh: could not resolve hostname '
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
  local dir text errexit=0 connect_only=0 ssh_connect=0 read_only=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --connect-only) connect_only=1; shift ;;
      --ssh-connect) ssh_connect=1; shift ;;
      --read) read_only=1; shift ;;
      *) break ;;
    esac
  done
  [ "$#" -ge 1 ] || { printf 'fm-blip-retry: command required\n' >&2; return 2; }
  base=$(fm_blip_retry_number FM_BLIP_RETRY_BASE_SECS 2 1) || return 2
  cap=$(fm_blip_retry_number FM_BLIP_RETRY_CAP_SECS 32 1) || return 2
  if [ "$read_only" -eq 1 ]; then
    budget=$(fm_blip_retry_number FM_BLIP_RETRY_READ_BUDGET_SECS "$FM_BLIP_RETRY_READ_BUDGET_DEFAULT" 0) || return 2
  else
    budget=$(fm_blip_retry_number FM_BLIP_RETRY_BUDGET_SECS "$FM_BLIP_RETRY_BUDGET_DEFAULT" 0) || return 2
  fi
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
    if [ "$ssh_connect" -eq 1 ]; then
      [ "$rc" -eq 255 ] || break
      fm_blip_text_is_ssh_connect_failure "$(cat "$dir/err")" || break
    elif [ "$connect_only" -eq 1 ]; then
      text=$(cat "$dir/err")
      fm_blip_text_is_connect_failure "$text" || break
    else
      text=$(cat "$dir/out" "$dir/err")
      fm_blip_text_is_transient "$text" || break
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
