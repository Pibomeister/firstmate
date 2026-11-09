#!/usr/bin/env bash
# fm-relay-guard.sh - the single owner of a host's network-daemon-bound relays.
#
# Usage: FM_HOME=<home> fm-relay-guard.sh <command>
#   once                      One locked pass: observe, recover, prove, record.
#   run [--interval <secs>]   Foreground loop of passes (default 30 s) for an
#                             init system, a launchd agent, or a box watchdog.
#   scan                      Observe and print each relay's verdict; no action
#                             and no state written.
#   status                    Print the status file the last pass wrote.
#
# Why it exists: a relay process (for example the Grok Bot box's
# m3-forward.mjs port forwarders into the tailnet) keeps running after the
# network daemon it depends on (tailscaled) restarts, but its sockets and
# sessions belong to the dead daemon, so it accepts connections and forwards
# nothing. A watchdog that restarts only the daemon turns every daemon restart
# into a stale-relay outage that needs a manual relay kill. This guard is the
# one owner of the relays: it decides from kernel process facts, stops only the
# relay processes its configuration names, starts them again, and proves each
# one with its reachability probe. Give relays exactly one owner - when this
# guard owns them, retire any other respawn path for the same relays.
#
# Each pass, per configured relay, in this order:
#   daemon-down       No process named <daemon> is running. No action: a relay
#                     cannot work without it. The relay is restarted once the
#                     daemon is back, by the daemon-restarted rule.
#   missing           No process runs the relay command. Start it.
#   duplicate         More than one process runs it. Stop all, start one.
#   daemon-restarted  The relay process is older than the youngest daemon
#                     process, so it predates the running daemon. Stop and
#                     start it. This is deterministic and needs no probe.
#   probe-failed      The relay's probe failed <probe-fails> passes in a row
#                     while the relay is newer than the daemon. Stop and start.
#   ok                Otherwise. A passing probe resets the failure streak.
# missing, duplicate, and probe-failed starts are limited: at most
# <max-restarts> starts per relay within <window-secs>, and after k such starts
# the next waits <backoff-secs> * 2^(k-1) seconds. A refused start reports
# capped or backoff and never loops. daemon-restarted is not limited, because a
# restarted relay is newer than the daemon and cannot repeat that verdict until
# the daemon restarts again; the daemon's own supervisor owns that rate.
# After the pass's starts it waits <settle-secs>, confirms each started relay is
# running, and runs its probe; a failed post-start probe begins a new streak.
#
# Configuration: $FM_HOME/config/relay-guard, one key=value per line, '#'
# comments. An unknown key, a dangling probe, a bad relay name, a non-numeric
# limit, or no relay at all is refused (exit 2) before anything is touched.
#   daemon=<name>             Process name of the network daemon, as `ps -o
#                             comm=` prints it (basename). Default tailscaled.
#   relay.<name>=<command>    Start command for one relay; <name> is
#                             [A-Za-z0-9_-]+. It is split on whitespace with no
#                             globbing, quoting, or shell syntax, and executed
#                             directly. A running process is this relay when
#                             its `ps -o args=` command line, with whitespace
#                             collapsed, equals the command or ends with a
#                             space and the command (an interpreter prefix such
#                             as `/bin/sh` or `node` may precede it). Run
#                             `scan` first to confirm existing relays match.
#   probe.<name>=<command>    Optional reachability probe for that relay, split
#                             the same way; exit 0 means the far side answers
#                             through the relay. Without one, a running relay
#                             newer than the daemon is ok.
#   probe-fails=2  probe-timeout-secs=10  max-restarts=3  window-secs=900
#   backoff-secs=30  settle-secs=2  term-wait-secs=5
# Stopping sends TERM to the matched pids, waits <term-wait-secs>, then KILLs
# survivors; it never signals a process the relay match did not select.
# A started relay runs detached (setsid where available, nohup, stdin from
# /dev/null) with output appended to state/relay-guard/<name>.log, so it
# outlives this command; under systemd keep the service's default cgroup kill
# so stopping the guard unit stops the relays it owns.
#
# Files under $FM_HOME/state/relay-guard/:
#   status.tsv     Rewritten atomically each pass: a '# fm-relay-guard v1'
#                  header with epoch and daemon pid, then
#                  name<TAB>verdict<TAB>pids<TAB>detail per relay.
#   actions.tsv    Append-only: epoch name action reason old-pids new-pid probe,
#                  where action is spawn, restart, or hold (a refused start).
#   <name>.fails   Current consecutive probe-failure count.
#   <name>.starts  Epochs of limited starts inside the window.
#   <name>.log     The relay's own output.
#   lock.d/        Per-pass lock; a pass already holding it makes once exit 75.
#
# Exit status: 0 when every relay ends the pass proven healthy, 3 when any
# relay is not (daemon down, probe failing, capped, backoff, or a start that
# did not stay running), 2 on a usage or configuration error, 75 when another
# pass holds the lock, 1 on any other failure. run keeps looping past 3.
# Requires a procps-style ps that accepts -A, -ww, and -o pid=,args=,etime=,comm=
# (Linux procps and macOS both do).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

die() { printf 'fm-relay-guard: %s\n' "$1" >&2; exit "${2:-1}"; }

[ -n "${FM_HOME:-}" ] || die "FM_HOME must name the home that holds config/relay-guard" 2
CONF=$FM_HOME/config/relay-guard
STATE=$FM_HOME/state/relay-guard

DAEMON=tailscaled
PROBE_FAILS=2
PROBE_TIMEOUT=10
MAX_RESTARTS=3
WINDOW=900
BACKOFF=30
SETTLE=2
TERM_WAIT=5
NAMES=()
CMDS=()
PROBES=()

# Collapse runs of whitespace to single spaces and trim both ends.
squash() {
  local words
  read -r -a words <<< "$1" || true
  printf '%s' "${words[*]:-}"
}

relay_index() {  # <name> -> index on stdout; nonzero when absent
  local i=0
  while [ "$i" -lt "${#NAMES[@]}" ]; do
    [ "${NAMES[$i]}" = "$1" ] && { printf '%s' "$i"; return 0; }
    i=$((i + 1))
  done
  return 1
}

load_config() {
  local line key val name idx pending_probes=() p
  [ -f "$CONF" ] || die "no configuration at $CONF" 2
  set -f
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(squash "$line")
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) die "config line has no '=': $line" 2 ;; esac
    key=${line%%=*}
    val=$(squash "${line#*=}")
    case "$key" in
      daemon)
        [ -n "$val" ] || die "daemon is empty" 2
        DAEMON=$val ;;
      relay.*|probe.*)
        name=${key#*.}
        case "$name" in ''|*[!A-Za-z0-9_-]*) die "bad relay name in key: $key" 2 ;; esac
        [ -n "$val" ] || die "$key has no command" 2
        if [ "${key%%.*}" = relay ]; then
          relay_index "$name" >/dev/null && die "relay $name is defined twice" 2
          NAMES+=("$name")
          CMDS+=("$val")
          PROBES+=("")
        else
          pending_probes+=("$name=$val")
        fi ;;
      probe-fails|probe-timeout-secs|max-restarts|window-secs|backoff-secs|settle-secs|term-wait-secs)
        case "$val" in ''|*[!0-9]*) die "$key must be a whole number: $val" 2 ;; esac
        case "$key" in
          probe-fails) PROBE_FAILS=$val ;;
          probe-timeout-secs) PROBE_TIMEOUT=$val ;;
          max-restarts) MAX_RESTARTS=$val ;;
          window-secs) WINDOW=$val ;;
          backoff-secs) BACKOFF=$val ;;
          settle-secs) SETTLE=$val ;;
          term-wait-secs) TERM_WAIT=$val ;;
        esac ;;
      *) die "unknown config key: $key" 2 ;;
    esac
  done < "$CONF"
  for p in "${pending_probes[@]:-}"; do
    [ -n "$p" ] || continue
    name=${p%%=*}
    idx=$(relay_index "$name") || die "probe.$name names no relay.$name" 2
    PROBES[idx]=${p#*=}
  done
  [ "${#NAMES[@]}" -gt 0 ] || die "no relay.<name> entries in $CONF" 2
  [ "$PROBE_FAILS" -ge 1 ] || PROBE_FAILS=1
  [ "$PROBE_TIMEOUT" -ge 1 ] || PROBE_TIMEOUT=1
}

# [[dd-]hh:]mm:ss -> seconds.
etime_secs() {
  local t=$1 d=0 h=0 m=0 s=0 a b c
  case "$t" in *-*) d=${t%%-*}; t=${t#*-} ;; esac
  IFS=: read -r a b c <<< "$t"
  if [ -n "${c:-}" ]; then h=$a; m=$b; s=$c
  elif [ -n "${b:-}" ]; then m=$a; s=$b
  else s=$a
  fi
  printf '%s' $(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

proc_age() {  # <pid> -> seconds; nonzero when gone
  local et
  et=$(ps -o etime= -p "$1" 2>/dev/null | tr -d '[:space:]')
  [ -n "$et" ] || return 1
  etime_secs "$et"
}

# "<pid> <age>" of the youngest process named $DAEMON; nonzero when none.
daemon_youngest() {
  local pid et comm best_pid='' best_age='' age
  while read -r pid et comm; do
    [ -n "${comm:-}" ] || continue
    [ "${comm##*/}" = "$DAEMON" ] || continue
    age=$(etime_secs "$et")
    if [ -z "$best_age" ] || [ "$age" -lt "$best_age" ]; then
      best_pid=$pid
      best_age=$age
    fi
  done < <(ps -A -o pid= -o etime= -o comm= 2>/dev/null)
  [ -n "$best_pid" ] || return 1
  printf '%s %s' "$best_pid" "$best_age"
}

relay_pids() {  # <command> -> matching pids, one per line
  ps -A -ww -o pid= -o args= 2>/dev/null | FM_RG_CMD="$1" FM_RG_SELF="$$" awk '
    {
      pid = $1
      line = $0
      sub(/^[ \t]*[0-9]+[ \t]*/, "", line)
      gsub(/[ \t]+/, " ", line)
      sub(/ $/, "", line)
      c = ENVIRON["FM_RG_CMD"]
      if (pid == ENVIRON["FM_RG_SELF"]) next
      if (line == c) { print pid; next }
      n = length(line); m = length(c)
      if (n > m && substr(line, n - m) == " " c) print pid
    }'
}

stop_pids() {  # <pids...>; nonzero when any survives
  local pid i alive
  [ "$#" -gt 0 ] || return 0
  kill -TERM "$@" 2>/dev/null
  i=0
  while [ "$i" -lt $((TERM_WAIT * 10)) ]; do
    alive=0
    for pid in "$@"; do kill -0 "$pid" 2>/dev/null && alive=1; done
    [ "$alive" -eq 1 ] || return 0
    sleep 0.1
    i=$((i + 1))
  done
  kill -KILL "$@" 2>/dev/null
  sleep 0.2
  for pid in "$@"; do kill -0 "$pid" 2>/dev/null && return 1; done
  return 0
}

spawn_relay() {  # <name> <command>
  local words
  set -f
  read -r -a words <<< "$2"
  if command -v setsid >/dev/null 2>&1; then
    ( exec setsid nohup "${words[@]}" </dev/null >>"$STATE/$1.log" 2>&1 ) &
  else
    ( exec nohup "${words[@]}" </dev/null >>"$STATE/$1.log" 2>&1 ) &
  fi
}

run_probe() {  # <name> <probe-command>; status of the probe
  local words
  set -f
  read -r -a words <<< "$2"
  if [ -d "$STATE" ] && [ "$ACT" -eq 1 ]; then
    fm_run_timed "$PROBE_TIMEOUT" "${words[@]}" </dev/null >>"$STATE/$1.log" 2>&1
  else
    fm_run_timed "$PROBE_TIMEOUT" "${words[@]}" </dev/null >/dev/null 2>&1
  fi
}

read_int() {  # <file> -> integer, 0 when absent or malformed
  local v=''
  [ -f "$1" ] && IFS= read -r v < "$1"
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  printf '%s' "$v"
}

# Prints "ok", "capped", or "backoff <seconds-left>" for a limited start.
start_allowed() {  # <name> <now>
  local f=$STATE/$1.starts e kept=() k last=0 wait
  if [ -f "$f" ]; then
    while IFS= read -r e; do
      case "$e" in ''|*[!0-9]*) continue ;; esac
      [ $(( $2 - e )) -lt "$WINDOW" ] || continue
      kept+=("$e")
      [ "$e" -gt "$last" ] && last=$e
    done < "$f"
  fi
  if [ "${#kept[@]}" -gt 0 ]; then
    printf '%s\n' "${kept[@]}" > "$f.tmp" && mv "$f.tmp" "$f"
  else
    rm -f "$f"
  fi
  k=${#kept[@]}
  if [ "$k" -ge "$MAX_RESTARTS" ]; then
    printf 'capped'
    return
  fi
  if [ "$k" -gt 0 ] && [ "$BACKOFF" -gt 0 ]; then
    wait=$(( BACKOFF * (1 << (k - 1)) ))
    if [ $(( $2 - last )) -lt "$wait" ]; then
      printf 'backoff %s' $(( last + wait - $2 ))
      return
    fi
  fi
  printf 'ok'
}

ledger() {  # <now> <name> <action> <reason> <old-pids> <new-pid> <probe>
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$STATE/actions.tsv"
}

join_pids() {
  local IFS=,
  printf '%s' "$*"
}

# One pass. ACT=1 acts and records; ACT=0 only observes.
pass_once() {
  local now dline dpid='' dage='' i name cmd probe pids n rage reason limited verdict
  local detail fails gate unhealthy=0 started=() started_reason=() started_old=() status_lines=()
  now=$(date +%s)
  if dline=$(daemon_youngest); then
    dpid=${dline%% *}
    dage=${dline#* }
  fi
  i=0
  while [ "$i" -lt "${#NAMES[@]}" ]; do
    name=${NAMES[$i]}
    cmd=${CMDS[$i]}
    probe=${PROBES[$i]}
    pids=()
    while IFS= read -r n; do [ -n "$n" ] && pids+=("$n"); done < <(relay_pids "$cmd")
    reason=''
    limited=1
    verdict=''
    detail=''
    if [ -z "$dpid" ]; then
      verdict='daemon-down'
      detail="no $DAEMON process"
    elif [ "${#pids[@]}" -eq 0 ]; then
      reason=missing
    elif [ "${#pids[@]}" -gt 1 ]; then
      reason=duplicate
    elif ! rage=$(proc_age "${pids[0]}"); then
      reason=missing
      pids=()
    elif [ "$rage" -gt "$dage" ]; then
      reason='daemon-restarted'
      limited=0
      detail="relay age ${rage}s > $DAEMON age ${dage}s"
    elif [ -n "$probe" ]; then
      if run_probe "$name" "$probe"; then
        [ "$ACT" -eq 1 ] && rm -f "$STATE/$name.fails"
        verdict=ok
      else
        fails=$(( $(read_int "$STATE/$name.fails") + 1 ))
        if [ "$fails" -ge "$PROBE_FAILS" ]; then
          reason='probe-failed'
          detail="probe failed $fails of $PROBE_FAILS passes"
        else
          [ "$ACT" -eq 1 ] && printf '%s\n' "$fails" > "$STATE/$name.fails"
          verdict='probe-failing'
          detail="probe failed $fails of $PROBE_FAILS passes"
        fi
      fi
    else
      verdict=ok
    fi
    if [ -n "$reason" ]; then
      if [ "$ACT" -eq 0 ]; then
        verdict="would-restart:$reason"
      else
        gate=ok
        [ "$limited" -eq 1 ] && gate=$(start_allowed "$name" "$now")
        if [ "$gate" != ok ]; then
          verdict=${gate%% *}
          if [ "$verdict" = backoff ]; then
            detail="$reason; next start in ${gate#* }s"
          else
            detail="$reason; $MAX_RESTARTS starts within ${WINDOW}s"
          fi
          ledger "$now" "$name" hold "$reason:$verdict" "$(join_pids "${pids[@]:-}")" - -
        elif ! stop_pids "${pids[@]:-}"; then
          verdict='stop-failed'
          detail="$reason; a relay process survived KILL"
        else
          spawn_relay "$name" "$cmd"
          [ "$limited" -eq 1 ] && printf '%s\n' "$now" >> "$STATE/$name.starts"
          rm -f "$STATE/$name.fails"
          started+=("$i")
          started_reason+=("$reason")
          started_old+=("$(join_pids "${pids[@]:-}")")
          i=$((i + 1))
          continue
        fi
      fi
    fi
    case "$verdict" in ok) ;; *) unhealthy=1 ;; esac
    status_lines+=("$name"$'\t'"$verdict"$'\t'"$(join_pids "${pids[@]:-}")"$'\t'"$detail")
    i=$((i + 1))
  done

  if [ "${#started[@]}" -gt 0 ]; then
    [ "$SETTLE" -gt 0 ] && sleep "$SETTLE"
    local j idx new probe_result action
    j=0
    while [ "$j" -lt "${#started[@]}" ]; do
      idx=${started[$j]}
      name=${NAMES[$idx]}
      reason=${started_reason[$j]}
      action=restart
      [ "$reason" = missing ] && action=spawn
      pids=()
      while IFS= read -r n; do [ -n "$n" ] && pids+=("$n"); done < <(relay_pids "${CMDS[$idx]}")
      new=$(join_pids "${pids[@]:-}")
      probe_result=-
      if [ "${#pids[@]}" -eq 0 ]; then
        verdict='start-failed'
        detail="$reason; started relay is not running (see $name.log)"
        unhealthy=1
      elif [ -n "${PROBES[$idx]}" ]; then
        if run_probe "$name" "${PROBES[$idx]}"; then
          probe_result=ok
          verdict=$action
          detail="$reason; probe ok"
        else
          probe_result=fail
          printf '1\n' > "$STATE/$name.fails"
          verdict='probe-failing'
          detail="$reason; started, probe failed"
          unhealthy=1
        fi
      else
        verdict=$action
        detail="$reason; running"
      fi
      ledger "$now" "$name" "$action" "$reason" "${started_old[$j]:--}" "${new:--}" "$probe_result"
      status_lines+=("$name"$'\t'"$verdict"$'\t'"$new"$'\t'"$detail")
      j=$((j + 1))
    done
  fi

  local header="# fm-relay-guard v1 epoch=$now daemon=$DAEMON daemon-pid=${dpid:-none}"
  if [ "$ACT" -eq 1 ]; then
    { printf '%s\n' "$header"; printf '%s\n' "${status_lines[@]}"; } > "$STATE/status.tsv.tmp" &&
      mv "$STATE/status.tsv.tmp" "$STATE/status.tsv"
  fi
  printf '%s\n' "$header"
  printf '%s\n' "${status_lines[@]}"
  [ "$unhealthy" -eq 0 ] || return 3
}

LOCKED=0
take_lock() {
  local holder
  if ! mkdir "$STATE/lock.d" 2>/dev/null; then
    holder=$(read_int "$STATE/lock.d/pid")
    if [ "$holder" -gt 0 ] && kill -0 "$holder" 2>/dev/null; then
      return 1
    fi
    rm -rf "$STATE/lock.d"
    mkdir "$STATE/lock.d" 2>/dev/null || return 1
  fi
  printf '%s\n' "$$" > "$STATE/lock.d/pid"
  LOCKED=1
}

drop_lock() {
  [ "$LOCKED" -eq 1 ] && rm -rf "$STATE/lock.d"
  LOCKED=0
}

locked_pass() {
  local rc
  take_lock || { printf 'fm-relay-guard: another pass holds %s\n' "$STATE/lock.d" >&2; return 75; }
  pass_once
  rc=$?
  drop_lock
  return "$rc"
}

ACT=1
cmd=${1:-}
[ "$#" -gt 0 ] && shift
case "$cmd" in
  once)
    [ "$#" -eq 0 ] || die "once takes no arguments" 2
    load_config
    mkdir -p "$STATE" || die "cannot create $STATE"
    trap drop_lock EXIT
    locked_pass
    exit $?
    ;;
  run)
    interval=30
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --interval)
          [ "$#" -ge 2 ] || die "--interval needs seconds" 2
          interval=$2
          shift 2 ;;
        *) die "unknown run argument: $1" 2 ;;
      esac
    done
    case "$interval" in ''|*[!0-9]*|0) die "--interval must be a positive whole number" 2 ;; esac
    load_config
    mkdir -p "$STATE" || die "cannot create $STATE"
    trap drop_lock EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    while :; do
      locked_pass
      [ "$?" -eq 75 ] && printf 'fm-relay-guard: skipped a pass; the lock is held\n' >&2
      sleep "$interval"
    done
    ;;
  scan)
    [ "$#" -eq 0 ] || die "scan takes no arguments" 2
    load_config
    ACT=0
    pass_once
    exit 0
    ;;
  status)
    [ -f "$STATE/status.tsv" ] || die "no status yet at $STATE/status.tsv" 1
    cat "$STATE/status.tsv"
    ;;
  -h|--help|help)
    sed -n '2,/^set -u$/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'
    ;;
  *)
    die "usage: FM_HOME=<home> fm-relay-guard.sh once|run [--interval <secs>]|scan|status" 2
    ;;
esac
