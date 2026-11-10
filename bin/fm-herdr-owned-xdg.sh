#!/usr/bin/env bash
# Own a brand-new short-path Herdr XDG tree and the herdr server started in it.
#
# Usage:
#   fm-herdr-owned-xdg.sh create
#   fm-herdr-owned-xdg.sh apply <xdg-root>
#   fm-herdr-owned-xdg.sh start <xdg-root>
#   fm-herdr-owned-xdg.sh check <xdg-root>
#   fm-herdr-owned-xdg.sh stop <xdg-root>
#   fm-herdr-owned-xdg.sh cleanup <xdg-root>
#
# create prints the new root. apply exports XDG_* in the current shell when
# sourced, or prints eval-able export lines when invoked as a command.
# The root is a fresh directory under $(cd /tmp && pwd -P)/hx.XXXXXX.
# start/check/stop/cleanup prove that ownership record before they act.
# stop signals only the recorded herdr pid (TERM, then bounded KILL) and
# never runs `herdr server stop`.
# cleanup removes only that exact owned directory.
# Inherited HERDR_SESSION and HERDR_PANE_ID (and the rest of the pane
# identity set) are cleared on every command.
# This helper does not target, stop, or delete anyone else's sessions,
# including the user default. Lab session names remain bin/fm-herdr-lab.sh's
# contract and still cannot be default.
set -u

fm_herdr_owned_xdg_error() {
  echo "fm-herdr-owned-xdg: $*" >&2
}

fm_herdr_owned_xdg_forget_inherited() {
  unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
}

fm_herdr_owned_xdg_prefix() {
  printf '%s/hx.' "$(cd /tmp && pwd -P)"
}

fm_herdr_owned_xdg_record_path() { # <root>
  printf '%s/owned.record' "$1"
}

fm_herdr_owned_xdg_marker_path() { # <root>
  printf '%s/.fm-herdr-owned' "$1"
}

fm_herdr_owned_xdg_record_get() { # <root> <key>
  local record value
  record=$(fm_herdr_owned_xdg_record_path "$1")
  [ -f "$record" ] || return 1
  value=$(sed -n "s/^$2=//p" "$record" | head -n 1)
  printf '%s' "$value"
}

fm_herdr_owned_xdg_write_record() { # <root> <token> <pid> <pid_start>
  local root=$1 token=$2 pid=$3 pid_start=$4 tmp
  tmp=$(fm_herdr_owned_xdg_record_path "$root").tmp
  {
    printf 'schema=fm-herdr-owned-xdg.v1\n'
    printf 'xdg_root=%s\n' "$root"
    printf 'marker_token=%s\n' "$token"
    printf 'pid=%s\n' "$pid"
    printf 'pid_start=%s\n' "$pid_start"
  } > "$tmp" || return 1
  mv -f "$tmp" "$(fm_herdr_owned_xdg_record_path "$root")"
}

fm_herdr_owned_xdg_clear_pid() { # <root>
  local token
  token=$(fm_herdr_owned_xdg_record_get "$1" marker_token) || return 1
  fm_herdr_owned_xdg_write_record "$1" "$token" "" ""
}

fm_herdr_owned_xdg_canonical() { # <path>
  (cd "$1" && pwd -P)
}

fm_herdr_owned_xdg_process_start() { # <pid>
  LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

fm_herdr_owned_xdg_process_comm() { # <pid>
  local comm
  comm=$(LC_ALL=C ps -p "$1" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//') || return 1
  printf '%s' "${comm##*/}"
}

fm_herdr_owned_xdg_process_pgid() { # <pid>
  LC_ALL=C ps -p "$1" -o pgid= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

fm_herdr_owned_xdg_prove() { # <root>
  local root token recorded_root recorded_token prefix
  root=$(fm_herdr_owned_xdg_canonical "$1") || {
    fm_herdr_owned_xdg_error "not an owned fixture: $1"
    return 1
  }
  prefix=$(fm_herdr_owned_xdg_prefix)
  case "$root" in
    "$prefix"*) ;;
    *)
      fm_herdr_owned_xdg_error "refusing a path outside the owned hx prefix: $root"
      return 1
      ;;
  esac
  [ "$root" != "$prefix" ] || {
    fm_herdr_owned_xdg_error "refusing the hx prefix itself"
    return 1
  }
  [ -f "$(fm_herdr_owned_xdg_marker_path "$root")" ] || {
    fm_herdr_owned_xdg_error "missing ownership marker in $root"
    return 1
  }
  [ -f "$(fm_herdr_owned_xdg_record_path "$root")" ] || {
    fm_herdr_owned_xdg_error "missing ownership record in $root"
    return 1
  }
  [ "$(fm_herdr_owned_xdg_record_get "$root" schema)" = fm-herdr-owned-xdg.v1 ] || {
    fm_herdr_owned_xdg_error "ownership record schema mismatch in $root"
    return 1
  }
  recorded_root=$(fm_herdr_owned_xdg_record_get "$root" xdg_root)
  [ "$recorded_root" = "$root" ] || {
    fm_herdr_owned_xdg_error "ownership record root mismatch in $root"
    return 1
  }
  token=$(cat "$(fm_herdr_owned_xdg_marker_path "$root")")
  recorded_token=$(fm_herdr_owned_xdg_record_get "$root" marker_token)
  [ -n "$token" ] && [ "$token" = "$recorded_token" ] || {
    fm_herdr_owned_xdg_error "ownership marker does not match the record in $root"
    return 1
  }
  printf '%s' "$root"
}

fm_herdr_owned_xdg_prove_pid() { # <root>
  local root pid recorded_start current_start comm
  root=$(fm_herdr_owned_xdg_prove "$1") || return 1
  pid=$(fm_herdr_owned_xdg_record_get "$root" pid)
  case "$pid" in
    ''|*[!0-9]*)
      fm_herdr_owned_xdg_error "no owned herdr pid recorded for $root"
      return 1
      ;;
  esac
  kill -0 "$pid" 2>/dev/null || {
    fm_herdr_owned_xdg_error "recorded herdr pid $pid is not running"
    return 1
  }
  comm=$(fm_herdr_owned_xdg_process_comm "$pid") || {
    fm_herdr_owned_xdg_error "recorded pid $pid has no process name"
    return 1
  }
  [ "$comm" = herdr ] || {
    fm_herdr_owned_xdg_error "refusing pid $pid: comm is '$comm', not herdr"
    return 1
  }
  recorded_start=$(fm_herdr_owned_xdg_record_get "$root" pid_start)
  current_start=$(fm_herdr_owned_xdg_process_start "$pid")
  [ -n "$recorded_start" ] && [ "$current_start" = "$recorded_start" ] || {
    fm_herdr_owned_xdg_error "refusing pid $pid: start time does not match the ownership record"
    return 1
  }
  if [ -r "/proc/$pid/environ" ]; then
    tr '\0' '\n' < "/proc/$pid/environ" | grep -Fx "XDG_CONFIG_HOME=$root/c" >/dev/null || {
      fm_herdr_owned_xdg_error "refusing pid $pid: it does not carry this fixture's XDG_CONFIG_HOME"
      return 1
    }
  fi
  printf '%s' "$pid"
}

fm_herdr_owned_xdg_apply_vars() { # <root>
  local root=$1
  export XDG_CONFIG_HOME="$root/c"
  export XDG_CACHE_HOME="$root/k"
  export XDG_DATA_HOME="$root/d"
  export XDG_RUNTIME_DIR="$root/r"
  mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR" || return 1
}

fm_herdr_owned_xdg_default_ready() {
  command -v herdr >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  herdr session list --json 2>/dev/null | jq -e \
    '[.sessions[]? | select(.default == true and .name == "default" and .running == true)] | length == 1' \
    >/dev/null
}

fm_herdr_owned_xdg_create() {
  local root token
  fm_herdr_owned_xdg_forget_inherited
  root=$(mktemp -d "$(fm_herdr_owned_xdg_prefix)XXXXXX") || {
    fm_herdr_owned_xdg_error "could not create an owned XDG directory"
    return 1
  }
  root=$(fm_herdr_owned_xdg_canonical "$root") || return 1
  mkdir -p "$root/c" "$root/k" "$root/d" "$root/r" || return 1
  token="$$.$RANDOM.$RANDOM"
  printf '%s\n' "$token" > "$(fm_herdr_owned_xdg_marker_path "$root")" || return 1
  fm_herdr_owned_xdg_write_record "$root" "$token" "" "" || return 1
  printf '%s\n' "$root"
}

fm_herdr_owned_xdg_apply() { # <root>
  local root
  fm_herdr_owned_xdg_forget_inherited
  root=$(fm_herdr_owned_xdg_prove "$1") || return 1
  fm_herdr_owned_xdg_apply_vars "$root" || return 1
  if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
  fi
  printf 'export XDG_CONFIG_HOME=%q\n' "$XDG_CONFIG_HOME"
  printf 'export XDG_CACHE_HOME=%q\n' "$XDG_CACHE_HOME"
  printf 'export XDG_DATA_HOME=%q\n' "$XDG_DATA_HOME"
  printf 'export XDG_RUNTIME_DIR=%q\n' "$XDG_RUNTIME_DIR"
}

fm_herdr_owned_xdg_start() { # <root>
  local root pid herdr log i
  fm_herdr_owned_xdg_forget_inherited
  root=$(fm_herdr_owned_xdg_prove "$1") || return 1
  command -v herdr >/dev/null 2>&1 || { fm_herdr_owned_xdg_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_owned_xdg_error "jq is required"; return 1; }
  fm_herdr_owned_xdg_apply_vars "$root" || return 1
  if pid=$(fm_herdr_owned_xdg_prove_pid "$root" 2>/dev/null); then
    i=0
    until fm_herdr_owned_xdg_default_ready || [ "$i" -ge 150 ]; do
      sleep 0.2
      i=$((i + 1))
    done
    fm_herdr_owned_xdg_default_ready || {
      fm_herdr_owned_xdg_error "owned herdr pid $pid is running but the default session is not ready"
      return 1
    }
    return 0
  fi
  pid=$(fm_herdr_owned_xdg_record_get "$root" pid)
  if [ -n "$pid" ]; then
    fm_herdr_owned_xdg_clear_pid "$root" || return 1
  fi
  if fm_herdr_owned_xdg_default_ready; then
    fm_herdr_owned_xdg_error "a running default session is already present in $root and is not this fixture's process"
    return 1
  fi
  herdr=$(command -v herdr)
  log=$root/server.log
  pid=$(perl -e '
    defined(my $pid = fork) or exit 1;
    if ($pid) { print $pid; exit 0; }
    require POSIX;
    POSIX::setsid() >= 0 or exit 1;
    my $log = $ARGV[0];
    open STDOUT, ">>", $log or exit 1;
    open STDERR, ">>&STDOUT";
    exec $ARGV[1], "server";
    exit 127;
  ' "$log" "$herdr") || {
    fm_herdr_owned_xdg_error "could not start herdr server in $root"
    return 1
  }
  case "$pid" in
    ''|*[!0-9]*)
      fm_herdr_owned_xdg_error "herdr server start did not report a pid"
      return 1
      ;;
  esac
  i=0
  until [ -n "$(fm_herdr_owned_xdg_process_start "$pid")" ] || [ "$i" -ge 50 ]; do
    sleep 0.02
    i=$((i + 1))
  done
  fm_herdr_owned_xdg_write_record "$root" "$(fm_herdr_owned_xdg_record_get "$root" marker_token)" \
    "$pid" "$(fm_herdr_owned_xdg_process_start "$pid")" || return 1
  i=0
  until fm_herdr_owned_xdg_default_ready || [ "$i" -ge 150 ]; do
    sleep 0.2
    i=$((i + 1))
  done
  if ! fm_herdr_owned_xdg_prove_pid "$root" >/dev/null || ! fm_herdr_owned_xdg_default_ready; then
    fm_herdr_owned_xdg_error "test-owned default Herdr session did not become ready"
    fm_herdr_owned_xdg_signal_tree "$pid" TERM
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 10 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      fm_herdr_owned_xdg_signal_tree "$pid" KILL
    fi
    wait "$pid" 2>/dev/null || true
    fm_herdr_owned_xdg_clear_pid "$root" || true
    return 1
  fi
}

fm_herdr_owned_xdg_check() { # <root>
  local root
  fm_herdr_owned_xdg_forget_inherited
  root=$(fm_herdr_owned_xdg_prove "$1") || return 1
  fm_herdr_owned_xdg_prove_pid "$root" >/dev/null || return 1
  fm_herdr_owned_xdg_apply_vars "$root" || return 1
  fm_herdr_owned_xdg_default_ready || {
    fm_herdr_owned_xdg_error "owned fixture $root does not have exactly one running default session"
    return 1
  }
}

fm_herdr_owned_xdg_signal_tree() { # <pid> <signal>
  local pid=$1 sig=$2 pgid
  pgid=$(fm_herdr_owned_xdg_process_pgid "$pid")
  kill "-$sig" "$pid" 2>/dev/null || true
  if [ "$pgid" = "$pid" ]; then
    kill "-$sig" -- "-$pid" 2>/dev/null || true
  fi
}

fm_herdr_owned_xdg_stop() { # <root>
  local root pid i
  fm_herdr_owned_xdg_forget_inherited
  root=$(fm_herdr_owned_xdg_prove "$1") || return 1
  pid=$(fm_herdr_owned_xdg_record_get "$root" pid)
  if [ -z "$pid" ]; then
    return 0
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    fm_herdr_owned_xdg_clear_pid "$root"
    return 0
  fi
  fm_herdr_owned_xdg_prove_pid "$root" >/dev/null || return 1
  fm_herdr_owned_xdg_signal_tree "$pid" TERM
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 10 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    fm_herdr_owned_xdg_signal_tree "$pid" KILL
  fi
  wait "$pid" 2>/dev/null || true
  fm_herdr_owned_xdg_clear_pid "$root"
}

fm_herdr_owned_xdg_cleanup() { # <root>
  local root
  fm_herdr_owned_xdg_forget_inherited
  root=$(fm_herdr_owned_xdg_prove "$1") || return 1
  fm_herdr_owned_xdg_stop "$root" || return 1
  root=$(fm_herdr_owned_xdg_prove "$root") || return 1
  rm -rf -- "$root"
}

fm_herdr_owned_xdg_usage() {
  sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

fm_herdr_owned_xdg_main() {
  local command=${1:-}
  case "$command" in
    create)
      [ "$#" -eq 1 ] || { fm_herdr_owned_xdg_usage >&2; return 2; }
      fm_herdr_owned_xdg_create
      ;;
    apply)
      [ "$#" -eq 2 ] || { fm_herdr_owned_xdg_usage >&2; return 2; }
      fm_herdr_owned_xdg_apply "$2"
      ;;
    start)
      [ "$#" -eq 2 ] || { fm_herdr_owned_xdg_usage >&2; return 2; }
      fm_herdr_owned_xdg_start "$2"
      ;;
    check)
      [ "$#" -eq 2 ] || { fm_herdr_owned_xdg_usage >&2; return 2; }
      fm_herdr_owned_xdg_check "$2"
      ;;
    stop)
      [ "$#" -eq 2 ] || { fm_herdr_owned_xdg_usage >&2; return 2; }
      fm_herdr_owned_xdg_stop "$2"
      ;;
    cleanup)
      [ "$#" -eq 2 ] || { fm_herdr_owned_xdg_usage >&2; return 2; }
      fm_herdr_owned_xdg_cleanup "$2"
      ;;
    -h|--help|help)
      fm_herdr_owned_xdg_usage
      ;;
    *)
      fm_herdr_owned_xdg_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -e
  fm_herdr_owned_xdg_main "$@"
fi
