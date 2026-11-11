#!/usr/bin/env bash
# Provision and operate an isolated Herdr lab session without risking the live
# fleet session.
#
# Usage:
#   fm-herdr-lab.sh name <label>
#   fm-herdr-lab.sh prepare <session>
#   fm-herdr-lab.sh provision <session>
#   fm-herdr-lab.sh run <session> <herdr arguments...>
#   fm-herdr-lab.sh viewer start <session>
#   fm-herdr-lab.sh viewer stop <session>
#   fm-herdr-lab.sh stop <session>
#   fm-herdr-lab.sh teardown <session>
#   fm-herdr-lab.sh fixture create
#   fm-herdr-lab.sh fixture apply <xdg-root>
#   fm-herdr-lab.sh fixture start <xdg-root>
#   fm-herdr-lab.sh fixture check <xdg-root>
#   fm-herdr-lab.sh fixture stop <xdg-root>
#   fm-herdr-lab.sh fixture cleanup <xdg-root>
#
# Session names must begin with "fm-lab-" and can never be "default".
# The name command sanitizes the label, caps it at 16 characters, and appends
# process/random suffixes to keep generated socket paths short.
# Every Herdr call made here carries --session <session>: trailing, or
# immediately before the first -- delimiter so it stays a Herdr option instead
# of becoming a passthrough argument such as an agent start argument.
# The run command rejects caller-supplied --session flags, any leading option
# before the subcommand, all session lifecycle operations, and every server
# operation.
# Session stop is available only through guarded stop or teardown, and session
# delete is available only through teardown.
# Both paths perform a fresh refuse-default check immediately before each
# destructive call.
# Provision records the running fleet session as a fleet-state tripwire and
# teardown requires that record to be identical afterward.
# The fleet session is "default" unless FM_HERDR_LAB_FLEET_SESSION names the
# custom session the live fleet runs in; that name must start with an ASCII
# letter or digit, contain only ASCII letters, digits, underscores, or dashes,
# and can never be an fm-lab- session.
# Keep this setting unchanged from preparation/provisioning through teardown,
# including in cleanup traps, so both snapshots protect the same fleet.
# Every Herdr call made here clears HERDR_SOCKET_PATH, HERDR_PANE_ID,
# HERDR_TAB_ID and HERDR_WORKSPACE_ID, which a worker pane inherits from the
# live session.
# The viewer command attaches or detaches one real foreground Herdr client on
# an owned lab session over a fixed 40-row by 120-column pty;
# bin/fm-herdr-lab-viewer.py owns the pty mechanics.
# Start succeeds only when that session reports a foreground client and the
# recorded viewer process still matches its launch identity.
# Stop signals only identity-matched recorded processes and retains its
# ownership record until detach is confirmed or the session is stopped or
# absent; teardown refuses when that stop cannot be confirmed.
# Fixture create/apply/start/check/stop/cleanup own one private XDG tree
# this helper created under $(cd /tmp && pwd -P)/hx.XXXXXX. They prove the
# canonical root and marker token before they act, signal only the recorded
# herdr pid (TERM, then bounded KILL) whose start time still matches, and
# never run `herdr server stop`. They signal only when that pid's environment
# proves XDG_CONFIG_HOME is this fixture's config dir as a whole NUL field:
# /proc/<pid>/environ, or Darwin KERN_PROCARGS2 via /usr/bin/python3 ctypes
# (stock macOS, skipped if that python is the CLT stub). If neither reader
# yields an environment, they refuse to signal.
# Inherited HERDR_* identity is cleared on every fixture command. Lab session
# names still cannot be default.
set -u

fm_herdr_lab_error() {
  echo "fm-herdr-lab: $*" >&2
}

fm_herdr_lab_forget_inherited() {
  unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
}

fm_herdr_lab_validate_name() { # <session>
  local name=${1:-}
  [[ "$name" =~ ^fm-lab-[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] && return 0
  case "$name" in
    default) fm_herdr_lab_error "refusing session name 'default'" ;;
    '') fm_herdr_lab_error "refusing an empty session name" ;;
    *) fm_herdr_lab_error "session name must start with 'fm-lab-' and contain only letters, digits, underscores, or dashes: $name" ;;
  esac
  return 1
}

fm_herdr_lab_state_dir() {
  printf '%s' "${FM_HERDR_LAB_STATE_DIR:-${TMPDIR:-/tmp}/fm-herdr-lab-${UID}}"
}

fm_herdr_lab_tripwire_path() { # <session>
  printf '%s/%s.fleet-state.json' "$(fm_herdr_lab_state_dir)" "$1"
}

fm_herdr_lab_raw() { # <session> <herdr arguments...>
  local name=$1 i
  shift
  local -a args=("$@")
  for ((i = 0; i < ${#args[@]}; i++)); do
    [ "${args[i]}" = -- ] || continue
    env -u HERDR_SOCKET_PATH -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
      HERDR_SESSION="$name" herdr "${args[@]:0:i}" --session "$name" "${args[@]:i}"
    return
  done
  env -u HERDR_SOCKET_PATH -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    HERDR_SESSION="$name" herdr "$@" --session "$name"
}

fm_herdr_lab_session_list() { # <session>
  fm_herdr_lab_raw "$1" session list --json
}

fm_herdr_lab_fleet_session() {
  local fleet=${FM_HERDR_LAB_FLEET_SESSION:-default}
  if [[ ! "$fleet" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || [[ "$fleet" == fm-lab-* ]]; then
    fm_herdr_lab_error "FM_HERDR_LAB_FLEET_SESSION must name the live fleet session, never a lab session: $fleet"
    return 1
  fi
  printf '%s' "$fleet"
}

fm_herdr_lab_fleet_state() { # <session>
  local name=$1 fleet sessions snapshot
  fleet=$(fm_herdr_lab_fleet_session) || return 1
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot read Herdr sessions for the fleet-state tripwire"
    return 1
  }
  snapshot=$(printf '%s' "$sessions" | jq -c --arg fleet "$fleet" '
    if $fleet == "default" then
      [.sessions[]? | select(.default == true)]
      | if length == 1 and .[0].name == "default" and .[0].running == true
        then .[0] | {name, default, running, socket_path}
        else empty
        end
    else
      [.sessions[]? | select(.name == $fleet)]
      | if length == 1 and .[0].default == false and .[0].running == true
        then .[0] | {name, default, running, socket_path}
        else empty
        end
    end
  ' 2>/dev/null)
  [ -n "$snapshot" ] || {
    fm_herdr_lab_error "fleet-state tripwire requires exactly one running $fleet session"
    return 1
  }
  printf '%s\n' "$snapshot"
}

fm_herdr_lab_prepare() { # <session>
  local name=$1 sessions state_dir tripwire
  fm_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { fm_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_lab_error "jq is required"; return 1; }

  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before provisioning '$name'"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    fm_herdr_lab_error "session '$name' already exists; refusing to adopt or overwrite it"
    return 1
  fi

  state_dir=$(fm_herdr_lab_state_dir)
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  mkdir -p "$state_dir" || return 1
  [ ! -e "$tripwire" ] || {
    fm_herdr_lab_error "tripwire already exists for '$name'; refusing ambiguous ownership"
    return 1
  }
  fm_herdr_lab_fleet_state "$name" > "$tripwire" || {
    rm -f "$tripwire"
    return 1
  }
}

fm_herdr_lab_refuse_if_default() { # <session>
  local name=$1 info flag
  fm_herdr_lab_validate_name "$name" || return 1
  info=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "refusing destructive call because session list failed"
    return 1
  }
  flag=$(printf '%s' "$info" | jq -r --arg name "$name" \
    '.sessions[]? | select(.name == $name) | .default' 2>/dev/null)
  [ "$flag" = false ] && return 0
  fm_herdr_lab_error "refusing destructive call for '$name': session is absent or default (default=${flag:-<not found>})"
  return 1
}

fm_herdr_lab_cli() { # <session> <herdr arguments...>
  local name=$1 arg
  shift
  fm_herdr_lab_validate_name "$name" || return 1
  [ "$#" -gt 0 ] || { fm_herdr_lab_error "run requires Herdr arguments"; return 1; }
  case "$1" in
    -*)
      fm_herdr_lab_error "run forbids a leading option before the Herdr subcommand; it could shift a server or session lifecycle operation past the guard or subvert session isolation"
      return 1
      ;;
  esac
  for arg in "$@"; do
    case "$arg" in
      --session|--session=*)
        fm_herdr_lab_error "run forbids caller-supplied --session; the helper supplies the lab session"
        return 1
        ;;
    esac
  done
  case "$1 ${2:-}" in
    "server "*)
      fm_herdr_lab_error "run forbids server operations; use provision for the named lab server"
      return 1
      ;;
    "session list") ;;
    "session "*)
      fm_herdr_lab_error "run forbids session lifecycle operations; use guarded teardown"
      return 1
      ;;
  esac
  fm_herdr_lab_raw "$name" "$@"
}

# --- foreground viewer ------------------------------------------------------
#
# Herdr counts a client as the session's foreground viewer only once that
# client reports a usable window grid, so a zero-sized pty attaches nothing and
# leaves `terminal title clear` answering no_foreground_client. Attaching a
# real viewer is what lets a test drive the live-client teardown paths instead
# of only their detached halves. bin/fm-herdr-lab-viewer.py owns the pty and
# environment mechanics; the guards below own who may be attached to.
# Per-session locks are deliberately absent: generated fm-lab-<label>-$$-$RANDOM
# names have no caller that starts one viewer concurrently, so locks add risk.
# A subsecond interrupt window and SIGKILL residue are accepted in this isolated
# lab helper because teardown drops any stray viewer connection with the session.

readonly fm_herdr_lab_viewer_timeout_seconds=5
readonly fm_herdr_lab_viewer_launcher_grace_seconds=6

fm_herdr_lab_viewer_record_path() { # <session>
  printf '%s/%s.viewer' "$(fm_herdr_lab_state_dir)" "$1"
}

fm_herdr_lab_viewer_log_path() { # <session>
  printf '%s/%s.viewer.log' "$(fm_herdr_lab_state_dir)" "$1"
}

fm_herdr_lab_viewer_launcher_path() {
  printf '%s/fm-herdr-lab-viewer.py' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
}

# Prints the session's current foreground-client reason, or nothing when it
# cannot be read.
fm_herdr_lab_viewer_reason() { # <session>
  local name=$1 out
  out=$(fm_herdr_lab_cli "$name" terminal title clear 2>/dev/null) || return 1
  printf '%s' "$out" | jq -r '.result.reason // empty' 2>/dev/null
}

fm_herdr_lab_process_start() { # <pid>
  LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

fm_herdr_lab_process_parent() { # <pid>
  LC_ALL=C ps -p "$1" -o ppid= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

fm_herdr_lab_viewer_recorded_value() { # <session> <key>
  local record value
  record=$(fm_herdr_lab_viewer_record_path "$1")
  [ -f "$record" ] || return 1
  value=$(sed -n "s/^$2=//p" "$record" | head -n 1)
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

fm_herdr_lab_viewer_owned_pair() { # <session>
  local launcher_pid viewer_pid launcher_start viewer_start current_start parent_pid
  launcher_pid=$(fm_herdr_lab_viewer_recorded_value "$1" launcher_pid) || return 1
  viewer_pid=$(fm_herdr_lab_viewer_recorded_value "$1" viewer_pid) || return 1
  case "$launcher_pid:$viewer_pid" in
    *[!0-9:]*) return 1 ;;
  esac
  launcher_start=$(fm_herdr_lab_viewer_recorded_value "$1" launcher_start) || return 1
  viewer_start=$(fm_herdr_lab_viewer_recorded_value "$1" viewer_start) || return 1
  current_start=$(fm_herdr_lab_process_start "$launcher_pid") || return 1
  [ -n "$current_start" ] && [ "$current_start" = "$launcher_start" ] || return 1
  current_start=$(fm_herdr_lab_process_start "$viewer_pid") || return 1
  [ -n "$current_start" ] && [ "$current_start" = "$viewer_start" ] || return 1
  parent_pid=$(fm_herdr_lab_process_parent "$viewer_pid") || return 1
  [ "$parent_pid" = "$launcher_pid" ] || return 1
  printf '%s %s' "$launcher_pid" "$viewer_pid"
}

fm_herdr_lab_viewer_owned_pid() { # <session> <launcher|viewer>
  local pair
  pair=$(fm_herdr_lab_viewer_owned_pair "$1") || return 1
  case "$2" in
    launcher) printf '%s' "${pair%% *}" ;;
    viewer) printf '%s' "${pair#* }" ;;
    *) return 1 ;;
  esac
}

fm_herdr_lab_viewer_signal() { # <session> <launcher|viewer> <signal>
  local pid
  pid=$(fm_herdr_lab_viewer_owned_pid "$1" "$2") || return 0
  kill "-$3" "$pid" 2>/dev/null || true
}

# True while this lab owns a viewer process that is still running.
fm_herdr_lab_viewer_owned_alive() { # <session>
  fm_herdr_lab_viewer_owned_pair "$1" >/dev/null
}

fm_herdr_lab_viewer_session_stopped_or_absent() { # <session>
  local sessions running
  sessions=$(fm_herdr_lab_session_list "$1" 2>/dev/null) || return 1
  running=$(printf '%s' "$sessions" | jq -r --arg name "$1" \
    '[.sessions[]? | select(.name == $name) | .running] | if length == 0 then "absent" elif length == 1 then .[0] else "ambiguous" end' \
    2>/dev/null) || return 1
  [ "$running" = false ] || [ "$running" = absent ]
}

fm_herdr_lab_viewer_start() { # <session>
  local name=$1 record log launcher launcher_pid waited attempt reason pid interrupt_traps=0 timeout=$fm_herdr_lab_viewer_timeout_seconds
  fm_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { fm_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_lab_error "jq is required"; return 1; }
  command -v python3 >/dev/null 2>&1 || { fm_herdr_lab_error "python3 is required for the lab viewer"; return 1; }

  [ -f "$(fm_herdr_lab_tripwire_path "$name")" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing to attach a viewer to a session this lab does not own"
    return 1
  }
  fm_herdr_lab_refuse_if_default "$name" || return 1

  record=$(fm_herdr_lab_viewer_record_path "$name")
  if fm_herdr_lab_viewer_owned_alive "$name"; then
    fm_herdr_lab_error "a lab viewer is already attached to '$name'; stop it before starting another"
    return 1
  fi
  rm -f "$record"

  launcher=$(fm_herdr_lab_viewer_launcher_path)
  [ -f "$launcher" ] || { fm_herdr_lab_error "missing viewer launcher at $launcher"; return 1; }
  log=$(fm_herdr_lab_viewer_log_path "$name")
  mkdir -p "$(fm_herdr_lab_state_dir)" || return 1
  launcher_pid=
  if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    interrupt_traps=1
    trap 'trap - INT TERM; [ -z "${launcher_pid:-}" ] || fm_herdr_lab_cancel_viewer_launcher "$launcher_pid"; exit 130' INT
    trap 'trap - INT TERM; [ -z "${launcher_pid:-}" ] || fm_herdr_lab_cancel_viewer_launcher "$launcher_pid"; exit 143' TERM
  fi
  nohup python3 "$launcher" "$name" "$record" >"$log" 2>&1 &
  launcher_pid=$!

  waited=0
  attempt=$((timeout * 5))
  while [ "$waited" -lt "$attempt" ]; do
    reason=$(fm_herdr_lab_viewer_reason "$name") || reason=
    if [ "$reason" = cleared ]; then
      pid=$(fm_herdr_lab_viewer_owned_pid "$name" viewer) || pid=
      if [ -n "$pid" ]; then
        [ "$interrupt_traps" = 0 ] || trap - INT TERM
        disown "$launcher_pid" 2>/dev/null || true
        printf 'viewer attached to %s (pid %s)\n' "$name" "$pid"
        return 0
      fi
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  fm_herdr_lab_cancel_viewer_launcher "$launcher_pid"
  [ "$interrupt_traps" = 0 ] || trap - INT TERM
  fm_herdr_lab_error "lab viewer did not become the foreground client of '$name' within $timeout seconds (last reason: ${reason:-<unreadable>})"
  [ ! -s "$log" ] || fm_herdr_lab_error "viewer log: $(tail -n 5 "$log" | tr '\n' ' ')"
  fm_herdr_lab_viewer_stop "$name" >/dev/null 2>&1 || true
  return 1
}

fm_herdr_lab_viewer_stop() { # <session>
  local name=$1 record log role waited attempt reason timeout=$fm_herdr_lab_viewer_timeout_seconds
  fm_herdr_lab_validate_name "$name" || return 1
  record=$(fm_herdr_lab_viewer_record_path "$name")
  log=$(fm_herdr_lab_viewer_log_path "$name")
  # An absent record means this lab owns no viewer. Any client attached in that
  # case belongs to someone else and must never be signalled from here.
  [ -f "$record" ] || return 0

  for role in viewer launcher; do
    fm_herdr_lab_viewer_signal "$name" "$role" TERM
  done
  waited=0
  while fm_herdr_lab_viewer_owned_alive "$name" && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  for role in viewer launcher; do
    fm_herdr_lab_viewer_signal "$name" "$role" KILL
  done

  waited=0
  attempt=$((timeout * 5))
  while [ "$waited" -lt "$attempt" ]; do
    reason=$(fm_herdr_lab_viewer_reason "$name") || reason=
    if [ "$reason" = no_foreground_client ] \
      || { [ -z "$reason" ] && fm_herdr_lab_viewer_session_stopped_or_absent "$name"; }; then
      rm -f "$record" "$log"
      return 0
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  fm_herdr_lab_error "lab viewer for '$name' did not detach within $timeout seconds (last reason: ${reason:-<unreadable>})"
  return 1
}

fm_herdr_lab_viewer() { # <start|stop> <session>
  case "${1:-}" in
    start) fm_herdr_lab_viewer_start "$2" ;;
    stop) fm_herdr_lab_viewer_stop "$2" ;;
    *)
      fm_herdr_lab_error "viewer takes 'start' or 'stop'"
      return 2
      ;;
  esac
}

fm_herdr_lab_cancel_viewer_launcher() { # <pid>
  local pid=$1 attempt=0 max_attempts=$((fm_herdr_lab_viewer_launcher_grace_seconds * 10))
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt "$max_attempts" ]; do
      sleep 0.1
      attempt=$((attempt + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true
}

fm_herdr_lab_cancel_provision() { # <pid>
  local pid=$1 attempt=0
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt 10 ]; do
      sleep 0.1
      attempt=$((attempt + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true
}

fm_herdr_lab_provision() { # <session>
  local name=$1 sessions tripwire running attempt server_pid max_attempts timeout_seconds
  fm_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { fm_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_lab_error "jq is required"; return 1; }

  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before provisioning '$name'"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    tripwire=$(fm_herdr_lab_tripwire_path "$name")
    [ -f "$tripwire" ] || {
      fm_herdr_lab_error "missing fleet-state tripwire for existing session '$name'; refusing to adopt it"
      return 1
    }
    fm_herdr_lab_refuse_if_default "$name" || return 1
    running=$(printf '%s' "$sessions" | jq -r --arg name "$name" \
      '.sessions[]? | select(.name == $name) | .running' 2>/dev/null)
    [ "$running" = false ] || {
      fm_herdr_lab_error "session '$name' is not stopped; refusing to re-provision it"
      return 1
    }
    fm_herdr_lab_check_tripwire "$name" || return 1
  else
    fm_herdr_lab_prepare "$name" || return 1
  fi
  fm_herdr_lab_raw "$name" server >/dev/null 2>&1 &
  server_pid=$!
  attempt=0
  max_attempts=300
  timeout_seconds=60
  while [ "$attempt" -lt "$max_attempts" ]; do
    running=$(fm_herdr_lab_cli "$name" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null) || running=false
    if [ "$running" = true ]; then
      fm_herdr_lab_refuse_if_default "$name" || {
        fm_herdr_lab_cancel_provision "$server_pid"
        return 1
      }
      return 0
    fi
    sleep 0.2
    attempt=$((attempt + 1))
  done
  fm_herdr_lab_cancel_provision "$server_pid"
  fm_herdr_lab_error "lab session '$name' did not report running within $timeout_seconds seconds"
  return 1
}

fm_herdr_lab_check_tripwire() { # <session>
  local name=$1 tripwire before after fleet
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing unverified teardown"
    return 1
  }
  before=$(cat "$tripwire")
  fleet=$(fm_herdr_lab_fleet_session) || return 1
  after=$(fm_herdr_lab_fleet_state "$name") || return 1
  [ "$before" = "$after" ] || {
    fm_herdr_lab_error "FLEET-STATE TRIPWIRE FAILED: $fleet session changed during lab work"
    fm_herdr_lab_error "before: $before"
    fm_herdr_lab_error "after:  $after"
    return 1
  }
}

fm_herdr_lab_verify_tripwire() { # <session>
  local name=$1 tripwire
  fm_herdr_lab_check_tripwire "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  rm -f "$tripwire"
}

fm_herdr_lab_stop() { # <session>
  local name=$1 tripwire
  fm_herdr_lab_validate_name "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing stop"
    return 1
  }
  fm_herdr_lab_refuse_if_default "$name" || return 1
  fm_herdr_lab_raw "$name" session stop "$name" --json
}

fm_herdr_lab_teardown() { # <session>
  local name=$1 tripwire sessions delete_status=0
  fm_herdr_lab_validate_name "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing destructive calls"
    return 1
  }
  fm_herdr_lab_viewer_stop "$name" || {
    fm_herdr_lab_error "refusing teardown of '$name' while this lab's viewer is still attached"
    return 1
  }
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before teardown"
    return 1
  }
  if ! printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    fm_herdr_lab_verify_tripwire "$name"
    return
  fi
  fm_herdr_lab_stop "$name" >/dev/null 2>&1 || true
  sleep 0.5
  fm_herdr_lab_refuse_if_default "$name" || return 1
  fm_herdr_lab_raw "$name" session delete "$name" --json >/dev/null 2>&1 || delete_status=$?
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot confirm removal of lab session '$name' after teardown"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    if [ "$delete_status" -ne 0 ]; then
      fm_herdr_lab_error "session delete failed for '$name' and the lab session remains"
    else
      fm_herdr_lab_error "lab session '$name' remains after teardown"
    fi
    return 1
  fi
  fm_herdr_lab_verify_tripwire "$name"
}

fm_herdr_lab_name() { # <label>
  local label=${1:-lab}
  label=$(printf '%s' "$label" | tr -cd 'a-zA-Z0-9_-' | sed 's/^[^a-zA-Z0-9]*//; s/-*$//')
  [ -n "$label" ] || label=lab
  label=${label:0:16}
  label=${label%-}
  [ -n "$label" ] || label=lab
  printf 'fm-lab-%s-%s-%s\n' "$label" "$$" "$RANDOM"
}

fm_herdr_lab_fixture_prefix() {
  printf '%s/hx.' "$(cd /tmp && pwd -P)"
}

fm_herdr_lab_fixture_record_path() { # <root>
  printf '%s/owned.record' "$1"
}

fm_herdr_lab_fixture_marker_path() { # <root>
  printf '%s/.fm-herdr-owned' "$1"
}

fm_herdr_lab_fixture_record_get() { # <root> <key>
  local record value
  record=$(fm_herdr_lab_fixture_record_path "$1")
  [ -f "$record" ] || return 1
  value=$(sed -n "s/^$2=//p" "$record" | head -n 1)
  printf '%s' "$value"
}

fm_herdr_lab_fixture_write_record() { # <root> <token> <pid> <pid_start>
  local root=$1 token=$2 pid=$3 pid_start=$4 tmp
  tmp=$(fm_herdr_lab_fixture_record_path "$root").tmp
  {
    printf 'schema=fm-herdr-owned-xdg.v1\n'
    printf 'xdg_root=%s\n' "$root"
    printf 'marker_token=%s\n' "$token"
    printf 'pid=%s\n' "$pid"
    printf 'pid_start=%s\n' "$pid_start"
  } > "$tmp" || return 1
  mv -f "$tmp" "$(fm_herdr_lab_fixture_record_path "$root")"
}

fm_herdr_lab_fixture_clear_pid() { # <root>
  local token
  token=$(fm_herdr_lab_fixture_record_get "$1" marker_token) || return 1
  fm_herdr_lab_fixture_write_record "$1" "$token" "" ""
}

fm_herdr_lab_fixture_canonical() { # <path>
  (cd "$1" && pwd -P)
}

fm_herdr_lab_fixture_process_start() { # <pid>
  LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

fm_herdr_lab_fixture_process_comm() { # <pid>
  local comm
  comm=$(LC_ALL=C ps -p "$1" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//') || return 1
  printf '%s' "${comm##*/}"
}

fm_herdr_lab_fixture_process_pgid() { # <pid>
  LC_ALL=C ps -p "$1" -o pgid= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Prints NAME=VALUE lines when the pid's environment is readable.
# Returns 0 even for an empty environment (so a readable /proc file with no
# XDG_CONFIG_HOME still refuses). Returns 1 when nothing can be read.
# /proc fields are NUL-delimited; a newline inside a value is not a new
# assignment. GNU grep -z is not used here because under -z its `.` matches
# newline, so a field `FOO=x\nXDG_CONFIG_HOME=...` would still be emitted.
# awk RS="\0" on this Linux-only branch drops those fields and prints the
# rest as whole records. Darwin has no /proc; env is KERN_PROCARGS2
# (int32 argc, exec path, argv, then env), the same buffer fm-procinfo.py
# reads, via /usr/bin/python3 ctypes. There is no ps -Eww fallback: Apple
# ps already joined env NULs with spaces. A missing or stub python, or a
# failed sysctl, is unreadable. FM_PROC_ROOT_OVERRIDE points tests at a
# fake /proc; FM_HERDR_LAB_KERN_PROCARGS2_OVERRIDE points tests at a fake
# KERN_PROCARGS2 buffer, matching fm-wake-lib.sh's override style.
fm_herdr_lab_fixture_process_env() { # <pid>
  local pid=$1 proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ -r "$proc_root/$pid/environ" ]; then
    awk 'BEGIN { RS = "\0"; ORS = "\n" }
      index($0, "\n") { next }
      /^[A-Za-z_][A-Za-z0-9_]*=/ { print }' "$proc_root/$pid/environ"
    return 0
  fi
  fm_herdr_lab_fixture_darwin_env "$pid"
}

# /usr/bin/python3 with a working ctypes (not the CLT stub). No PATH search:
# Homebrew python is not stock macOS.
fm_herdr_lab_fixture_darwin_python() {
  local py=/usr/bin/python3
  [ -x "$py" ] || return 1
  "$py" -c 'import ctypes, ctypes.util, struct' >/dev/null 2>&1 || return 1
  printf '%s' "$py"
}

# Whole NUL env fields from KERN_PROCARGS2. argv is skipped, not parsed.
# Fields with an embedded newline are dropped, matching the /proc reader.
fm_herdr_lab_fixture_darwin_env() { # <pid>
  local pid=$1 py
  py=$(fm_herdr_lab_fixture_darwin_python) || return 1
  "$py" - "$pid" <<'PY' 2>/dev/null
import ctypes
import ctypes.util
import os
import re
import struct
import sys

CTL_KERN = 1
KERN_PROCARGS2 = 49
NAME = re.compile(br"^[A-Za-z_][A-Za-z0-9_]*=")


def load(pid):
    override = os.environ.get("FM_HERDR_LAB_KERN_PROCARGS2_OVERRIDE")
    if override:
        try:
            with open(os.path.join(override, str(pid)), "rb") as fh:
                buf = fh.read()
        except OSError:
            return None
        return buf or None
    try:
        libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.dylib", use_errno=True)
        mib = (ctypes.c_int * 3)(CTL_KERN, KERN_PROCARGS2, pid)
        size = ctypes.c_size_t(0)
        if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0 or size.value == 0:
            return None
        raw = ctypes.create_string_buffer(size.value)
        if libc.sysctl(mib, 3, raw, ctypes.byref(size), None, 0) != 0:
            return None
        return raw.raw[: size.value]
    except (AttributeError, OSError):
        return None


pid = int(sys.argv[1])
buf = load(pid)
if not buf or len(buf) < 4:
    sys.exit(1)
argc = struct.unpack_from("<i", buf, 0)[0]
if argc <= 0 or argc > 4096:
    sys.exit(1)
strings = buf[4:].split(b"\0")
if not strings or not strings[0]:
    sys.exit(1)
i = 1
while i < len(strings) and not strings[i]:
    i += 1
if i + argc > len(strings):
    sys.exit(1)
i += argc
while i < len(strings) and not strings[i]:
    i += 1
out = sys.stdout.buffer
while i < len(strings):
    raw = strings[i]
    i += 1
    if not raw or b"\n" in raw or not NAME.match(raw):
        continue
    out.write(raw + b"\n")
sys.exit(0)
PY
}

fm_herdr_lab_fixture_prove() { # <root>
  local root token recorded_root recorded_token prefix
  root=$(fm_herdr_lab_fixture_canonical "$1") || {
    fm_herdr_lab_error "not an owned fixture: $1"
    return 1
  }
  prefix=$(fm_herdr_lab_fixture_prefix)
  case "$root" in
    "$prefix"*) ;;
    *)
      fm_herdr_lab_error "refusing a path outside the owned hx prefix: $root"
      return 1
      ;;
  esac
  [ "$root" != "$prefix" ] || {
    fm_herdr_lab_error "refusing the hx prefix itself"
    return 1
  }
  [ -f "$(fm_herdr_lab_fixture_marker_path "$root")" ] || {
    fm_herdr_lab_error "missing ownership marker in $root"
    return 1
  }
  [ -f "$(fm_herdr_lab_fixture_record_path "$root")" ] || {
    fm_herdr_lab_error "missing ownership record in $root"
    return 1
  }
  [ "$(fm_herdr_lab_fixture_record_get "$root" schema)" = fm-herdr-owned-xdg.v1 ] || {
    fm_herdr_lab_error "ownership record schema mismatch in $root"
    return 1
  }
  recorded_root=$(fm_herdr_lab_fixture_record_get "$root" xdg_root)
  [ "$recorded_root" = "$root" ] || {
    fm_herdr_lab_error "ownership record root mismatch in $root"
    return 1
  }
  token=$(cat "$(fm_herdr_lab_fixture_marker_path "$root")")
  recorded_token=$(fm_herdr_lab_fixture_record_get "$root" marker_token)
  [ -n "$token" ] && [ "$token" = "$recorded_token" ] || {
    fm_herdr_lab_error "ownership marker does not match the record in $root"
    return 1
  }
  printf '%s' "$root"
}

fm_herdr_lab_fixture_prove_pid() { # <root>
  local root pid recorded_start current_start comm env_text
  root=$(fm_herdr_lab_fixture_prove "$1") || return 1
  pid=$(fm_herdr_lab_fixture_record_get "$root" pid)
  case "$pid" in
    ''|*[!0-9]*)
      fm_herdr_lab_error "no owned herdr pid recorded for $root"
      return 1
      ;;
  esac
  kill -0 "$pid" 2>/dev/null || {
    fm_herdr_lab_error "recorded herdr pid $pid is not running"
    return 1
  }
  comm=$(fm_herdr_lab_fixture_process_comm "$pid") || {
    fm_herdr_lab_error "recorded pid $pid has no process name"
    return 1
  }
  [ "$comm" = herdr ] || {
    fm_herdr_lab_error "refusing pid $pid: comm is '$comm', not herdr"
    return 1
  }
  recorded_start=$(fm_herdr_lab_fixture_record_get "$root" pid_start)
  current_start=$(fm_herdr_lab_fixture_process_start "$pid")
  [ -n "$recorded_start" ] && [ "$current_start" = "$recorded_start" ] || {
    fm_herdr_lab_error "refusing pid $pid: start time does not match the ownership record"
    return 1
  }
  env_text=$(fm_herdr_lab_fixture_process_env "$pid") || {
    fm_herdr_lab_error "refusing pid $pid: process environment is unreadable"
    return 1
  }
  printf '%s\n' "$env_text" | grep -Fx "XDG_CONFIG_HOME=$root/c" >/dev/null || {
    fm_herdr_lab_error "refusing pid $pid: it does not carry this fixture's XDG_CONFIG_HOME"
    return 1
  }
  printf '%s' "$pid"
}

fm_herdr_lab_fixture_apply_vars() { # <root>
  local root=$1
  export XDG_CONFIG_HOME="$root/c"
  export XDG_CACHE_HOME="$root/k"
  export XDG_DATA_HOME="$root/d"
  export XDG_RUNTIME_DIR="$root/r"
  mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR" || return 1
}

fm_herdr_lab_fixture_ready() {
  local rc=0
  # shellcheck source=bin/fm-timeout-lib.sh
  command -v fm_run_timed_fn >/dev/null 2>&1 || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"
  FM_HERDR_LAB_FLEET_SESSION=default fm_run_timed_fn "$fm_herdr_lab_viewer_timeout_seconds" \
    fm_herdr_lab_fleet_state default >/dev/null 2>&1 || rc=$?
  return "$rc"
}

fm_herdr_lab_fixture_wait_ready() {
  local i=0 rc=0
  while [ "$i" -lt 150 ]; do
    rc=0
    fm_herdr_lab_fixture_ready || rc=$?
    [ "$rc" -eq 0 ] && return 0
    if fm_timed_out "$rc"; then
      return 1
    fi
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

fm_herdr_lab_fixture_create() {
  local root token
  fm_herdr_lab_forget_inherited
  root=$(mktemp -d "$(fm_herdr_lab_fixture_prefix)XXXXXX") || {
    fm_herdr_lab_error "could not create an owned XDG directory"
    return 1
  }
  root=$(fm_herdr_lab_fixture_canonical "$root") || return 1
  mkdir -p "$root/c" "$root/k" "$root/d" "$root/r" || return 1
  token="$$.$RANDOM.$RANDOM"
  printf '%s\n' "$token" > "$(fm_herdr_lab_fixture_marker_path "$root")" || return 1
  fm_herdr_lab_fixture_write_record "$root" "$token" "" "" || return 1
  printf '%s\n' "$root"
}

fm_herdr_lab_fixture_apply() { # <root>
  local root
  fm_herdr_lab_forget_inherited
  root=$(fm_herdr_lab_fixture_prove "$1") || return 1
  fm_herdr_lab_fixture_apply_vars "$root" || return 1
  if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
  fi
  printf 'export XDG_CONFIG_HOME=%q\n' "$XDG_CONFIG_HOME"
  printf 'export XDG_CACHE_HOME=%q\n' "$XDG_CACHE_HOME"
  printf 'export XDG_DATA_HOME=%q\n' "$XDG_DATA_HOME"
  printf 'export XDG_RUNTIME_DIR=%q\n' "$XDG_RUNTIME_DIR"
}

fm_herdr_lab_fixture_start() { # <root>
  local root pid herdr log i started
  fm_herdr_lab_forget_inherited
  root=$(fm_herdr_lab_fixture_prove "$1") || return 1
  command -v herdr >/dev/null 2>&1 || { fm_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_lab_error "jq is required"; return 1; }
  fm_herdr_lab_fixture_apply_vars "$root" || return 1
  if pid=$(fm_herdr_lab_fixture_prove_pid "$root" 2>/dev/null); then
    fm_herdr_lab_fixture_wait_ready || {
      fm_herdr_lab_error "owned herdr pid $pid is running but the default session is not ready"
      return 1
    }
    return 0
  fi
  pid=$(fm_herdr_lab_fixture_record_get "$root" pid)
  if [ -n "$pid" ]; then
    fm_herdr_lab_fixture_clear_pid "$root" || return 1
  fi
  if fm_herdr_lab_fixture_ready; then
    fm_herdr_lab_error "a running default session is already present in $root and is not this fixture's process"
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
    fm_herdr_lab_error "could not start herdr server in $root"
    return 1
  }
  case "$pid" in
    ''|*[!0-9]*)
      fm_herdr_lab_error "herdr server start did not report a pid"
      return 1
      ;;
  esac
  started=
  i=0
  until started=$(fm_herdr_lab_fixture_process_start "$pid"); [ -n "$started" ] || [ "$i" -ge 50 ]; do
    sleep 0.02
    i=$((i + 1))
  done
  [ -n "$started" ] || {
    fm_herdr_lab_error "forked herdr pid $pid has no start time; leaving it running"
    return 1
  }
  fm_herdr_lab_fixture_write_record "$root" "$(fm_herdr_lab_fixture_record_get "$root" marker_token)" \
    "$pid" "$started" || {
    fm_herdr_lab_fixture_reap_started "$root" "$pid" "$started"
    return 1
  }
  if ! fm_herdr_lab_fixture_wait_ready || ! fm_herdr_lab_fixture_prove_pid "$root" >/dev/null; then
    fm_herdr_lab_error "test-owned default Herdr session did not become ready"
    fm_herdr_lab_fixture_reap_started "$root" "$pid" "$started"
    return 1
  fi
}

fm_herdr_lab_fixture_pid_matches_start() { # <pid> <started>
  local pid=$1 started=$2 current
  [ -n "$pid" ] && [ -n "$started" ] || return 1
  current=$(fm_herdr_lab_fixture_process_start "$pid")
  [ -n "$current" ] && [ "$current" = "$started" ]
}

fm_herdr_lab_fixture_reap_started() { # <root> <pid> <started>
  local root=$1 pid=$2 started=$3 i
  if ! fm_herdr_lab_fixture_pid_matches_start "$pid" "$started"; then
    fm_herdr_lab_fixture_clear_pid "$root" || true
    return 0
  fi
  fm_herdr_lab_fixture_signal_tree "$pid" TERM
  i=0
  while fm_herdr_lab_fixture_pid_matches_start "$pid" "$started" && [ "$i" -lt 10 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if fm_herdr_lab_fixture_pid_matches_start "$pid" "$started"; then
    fm_herdr_lab_fixture_signal_tree "$pid" KILL
  fi
  wait "$pid" 2>/dev/null || true
  fm_herdr_lab_fixture_clear_pid "$root" || true
}

fm_herdr_lab_fixture_check() { # <root>
  local root
  fm_herdr_lab_forget_inherited
  root=$(fm_herdr_lab_fixture_prove "$1") || return 1
  fm_herdr_lab_fixture_prove_pid "$root" >/dev/null || return 1
  fm_herdr_lab_fixture_apply_vars "$root" || return 1
  fm_herdr_lab_fixture_ready || {
    fm_herdr_lab_error "owned fixture $root does not have exactly one running default session"
    return 1
  }
}

fm_herdr_lab_fixture_signal_tree() { # <pid> <signal>
  local pid=$1 sig=$2 pgid
  pgid=$(fm_herdr_lab_fixture_process_pgid "$pid")
  kill "-$sig" "$pid" 2>/dev/null || true
  if [ "$pgid" = "$pid" ]; then
    kill "-$sig" -- "-$pid" 2>/dev/null || true
  fi
}

fm_herdr_lab_fixture_stop() { # <root>
  local root pid started
  fm_herdr_lab_forget_inherited
  root=$(fm_herdr_lab_fixture_prove "$1") || return 1
  pid=$(fm_herdr_lab_fixture_record_get "$root" pid)
  if [ -z "$pid" ]; then
    return 0
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    fm_herdr_lab_fixture_clear_pid "$root"
    return 0
  fi
  fm_herdr_lab_fixture_prove_pid "$root" >/dev/null || return 1
  started=$(fm_herdr_lab_fixture_record_get "$root" pid_start)
  fm_herdr_lab_fixture_reap_started "$root" "$pid" "$started"
}

fm_herdr_lab_fixture_cleanup() { # <root>
  local root
  fm_herdr_lab_forget_inherited
  root=$(fm_herdr_lab_fixture_prove "$1") || return 1
  fm_herdr_lab_fixture_stop "$root" || return 1
  root=$(fm_herdr_lab_fixture_prove "$root") || return 1
  rm -rf -- "$root"
}

fm_herdr_lab_usage() {
  sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

fm_herdr_lab_main() {
  local command=${1:-}
  case "$command" in
    name)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_name "$2"
      ;;
    prepare)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_prepare "$2"
      ;;
    provision)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_provision "$2"
      ;;
    run)
      [ "$#" -ge 3 ] || { fm_herdr_lab_usage >&2; return 2; }
      shift
      fm_herdr_lab_cli "$@"
      ;;
    viewer)
      [ "$#" -eq 3 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_viewer "$2" "$3"
      ;;
    stop)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_stop "$2"
      ;;
    teardown)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_teardown "$2"
      ;;
    fixture)
      case "${2:-}" in
        create)
          [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
          fm_herdr_lab_fixture_create
          ;;
        apply)
          [ "$#" -eq 3 ] || { fm_herdr_lab_usage >&2; return 2; }
          fm_herdr_lab_fixture_apply "$3"
          ;;
        start)
          [ "$#" -eq 3 ] || { fm_herdr_lab_usage >&2; return 2; }
          fm_herdr_lab_fixture_start "$3"
          ;;
        check)
          [ "$#" -eq 3 ] || { fm_herdr_lab_usage >&2; return 2; }
          fm_herdr_lab_fixture_check "$3"
          ;;
        stop)
          [ "$#" -eq 3 ] || { fm_herdr_lab_usage >&2; return 2; }
          fm_herdr_lab_fixture_stop "$3"
          ;;
        cleanup)
          [ "$#" -eq 3 ] || { fm_herdr_lab_usage >&2; return 2; }
          fm_herdr_lab_fixture_cleanup "$3"
          ;;
        *)
          fm_herdr_lab_usage >&2
          return 2
          ;;
      esac
      ;;
    -h|--help|help)
      fm_herdr_lab_usage
      ;;
    *)
      fm_herdr_lab_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -e
  fm_herdr_lab_main "$@"
fi
