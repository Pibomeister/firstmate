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
#   render-launchd            Print a macOS LaunchAgent plist that keeps `run`
#                             alive for this home.
#   render-systemd            Print a Linux systemd unit that keeps `run`
#                             alive for this home.
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
#   daemon-down       No top-level process named <daemon> is running. No action: a relay
#                     cannot work without it. The relay is restarted once the
#                     daemon is back, by the daemon-restarted rule.
#   missing           No process runs the relay command. Start it.
#   duplicate         More than one process runs it. Stop all, start one.
#   daemon-restarted  The relay process is at least as old as the youngest
#                     top-level daemon process, so it may predate the running
#                     daemon. Both whole-second ages come from one ps snapshot,
#                     so a relay started in the daemon's restart second counts,
#                     unless <name>.bound records that this guard started that
#                     relay pid while that daemon pid ran. Stop and start it.
#                     This is deterministic and needs no probe.
#   probe-failed      The relay's probe failed <probe-fails> passes in a row
#                     while the relay is newer than the daemon. Stop and start.
#   ok                Otherwise. A passing probe resets the failure streak.
# missing, duplicate, and probe-failed starts are limited: at most
# <max-restarts> starts per relay within <window-secs>, and after k such starts
# the next waits <backoff-secs> * 2^(k-1) seconds. A refused start reports
# capped or backoff and never loops. daemon-restarted is not limited, because a
# restarted relay is newer than the daemon and cannot repeat that verdict until
# the daemon restarts again, except once for a relay another launcher started
# within the daemon's first second; the daemon's own supervisor owns that rate.
# After the pass's starts it waits <settle-secs>, confirms each started relay is
# running, and runs its probe; a failed post-start probe begins a new streak.
#
# A top-level daemon process is one whose parent is not itself named <daemon>,
# so helpers the daemon re-executes as itself (such as `tailscaled be-child
# ssh` for each Tailscale SSH session) never count as a daemon restart.
#
# Configuration: $FM_HOME/config/relay-guard, one key=value per line, '#'
# comments; docs/examples/relay-guard is a starting point for the m3-forward
# relays. An unknown key, a dangling probe, a relay without a probe, a bad relay
# name, a non-numeric limit, or no relay at all is refused (exit 2) before
# anything is touched.
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
#   probe.<name>=<command>    Required reachability probe for that relay, split
#                             the same way; exit 0 means the far side answers
#                             through the relay, so it must reach the paired
#                             environment, not only the local listener.
#   probe-fails=2  probe-timeout-secs=10  max-restarts=3  window-secs=900
#   backoff-secs=30  settle-secs=2  term-wait-secs=5
# Stopping sends TERM to the matched pids, waits <term-wait-secs>, then KILLs
# survivors whose start time is unchanged since the TERM, so a pid that exited
# and was reused is spared; it never signals a process the relay match did not
# select.
# A started relay runs detached (setsid where available, nohup, stdin from
# /dev/null) with output appended to state/relay-guard/<name>.log, so it
# outlives this command. The rendered units keep relays alive across a guard
# stop or restart (systemd KillMode=process, launchd AbandonProcessGroup) and
# carry the rendering shell's PATH, so relay and probe commands resolve as they
# do when the guard runs by hand.
#
# Files under $FM_HOME/state/relay-guard/:
#   status.tsv     Rewritten atomically each pass: a '# fm-relay-guard v1'
#                  header with epoch and daemon pid, then
#                  name<TAB>verdict<TAB>pids<TAB>detail per relay.
#   actions.tsv    Append-only: epoch name action reason old-pids new-pid probe,
#                  where action is spawn, restart, or hold (a refused start).
#   <name>.fails   Current consecutive probe-failure count.
#   <name>.starts  Epochs of limited starts inside the window.
#   <name>.bound   "<relay-pid> <daemon-pid>" of the relay this guard last
#                  started and the daemon running when it did.
#   <name>.log     The relay's own output.
#   lock.d/        Per-pass lock holding its owner's pid and start time; a pass
#                  already holding it makes once exit 75. A lock whose pid is
#                  gone or now has another start time is a crashed owner's and
#                  is reclaimed by renaming it aside. A lock with no pid yet is
#                  held until it is a minute old, then reclaimed the same way.
#
# Exit status: 0 when every relay ends the pass proven healthy, 3 when any
# relay is not (daemon down, probe failing, capped, backoff, or a start that
# did not stay running), 2 on a usage or configuration error, 75 when another
# pass holds the lock, 1 on any other failure. run keeps looping past 3.
# Requires a procps-style ps that accepts -A, -ww, and
# -o pid=,ppid=,args=,etime=,comm= (Linux procps and macOS both do).
#
# Install: FM_HOME must be absolute. On macOS save render-launchd as
# ~/Library/LaunchAgents/<label>.plist and launchctl bootstrap gui/$(id -u)
# it. On Linux save render-systemd as
# ~/.config/systemd/user/<label>.service, run systemctl --user daemon-reload,
# then systemctl --user enable --now <label>.service (enable lingering for the
# user so it runs without a login). <label> is the Label or unit name printed.
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
  idx=0
  while [ "$idx" -lt "${#NAMES[@]}" ]; do
    [ -n "${PROBES[$idx]}" ] || die "relay.${NAMES[$idx]} has no probe.${NAMES[$idx]}" 2
    idx=$((idx + 1))
  done
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

# "<relay-age> <daemon-age>" in seconds from one ps snapshot, so both ages are
# read at the same instant; '-' stands for a process that is gone.
pair_ages() {  # <relay-pid> <daemon-pid>
  local pid et r=- d=-
  while read -r pid et; do
    [ -n "${et:-}" ] || continue
    [ "$pid" = "$1" ] && r=$(etime_secs "$et")
    [ "$pid" = "$2" ] && d=$(etime_secs "$et")
  done < <(ps -o pid= -o etime= -p "$1,$2" 2>/dev/null)
  printf '%s %s' "$r" "$d"
}

# "<pid> <age>" of the youngest top-level process named $DAEMON; nonzero when
# none. A $DAEMON process whose parent is also $DAEMON is a helper, not a
# restart.
daemon_youngest() {
  local pid et best_pid='' best_age='' age
  while read -r pid et; do
    [ -n "${et:-}" ] || continue
    age=$(etime_secs "$et")
    if [ -z "$best_age" ] || [ "$age" -lt "$best_age" ]; then
      best_pid=$pid
      best_age=$age
    fi
  done < <(ps -A -o pid= -o ppid= -o etime= -o comm= 2>/dev/null | FM_RG_DAEMON="$DAEMON" awk '
    {
      comm = $4
      for (k = 5; k <= NF; k++) comm = comm " " $k
      sub(/.*\//, "", comm)
      if (comm != ENVIRON["FM_RG_DAEMON"]) next
      named[$1] = 1
      n++; pid[n] = $1; ppid[n] = $2; et[n] = $3
    }
    END { for (k = 1; k <= n; k++) if (!(ppid[k] in named)) print pid[k], et[k] }')
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

proc_start() {  # <pid> -> the process's start time; empty when gone
  ps -o lstart= -p "$1" 2>/dev/null
}

stop_pids() {  # <pids...>; nonzero when any survives
  local pid i k alive starts=() survivors=()
  [ "$#" -gt 0 ] || return 0
  for pid in "$@"; do starts+=("$(proc_start "$pid")"); done
  kill -TERM "$@" 2>/dev/null
  i=0
  while [ "$i" -lt $((TERM_WAIT * 10)) ]; do
    alive=0
    for pid in "$@"; do kill -0 "$pid" 2>/dev/null && alive=1; done
    [ "$alive" -eq 1 ] || return 0
    sleep 0.1
    i=$((i + 1))
  done
  # KILL only a pid that is still the process TERM was sent to: a pid that
  # exited and was reused by another process has a different start time.
  k=0
  for pid in "$@"; do
    if [ -n "${starts[$k]}" ] && [ "$(proc_start "$pid")" = "${starts[$k]}" ]; then
      survivors+=("$pid")
    fi
    k=$((k + 1))
  done
  [ "${#survivors[@]}" -gt 0 ] || return 0
  kill -KILL "${survivors[@]}" 2>/dev/null
  sleep 0.2
  for pid in "${survivors[@]}"; do kill -0 "$pid" 2>/dev/null && return 1; done
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
  local now dline dpid='' dage='' ages i name cmd probe pids n rage reason limited verdict
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
    elif ! dline=$(daemon_youngest); then
      verdict='daemon-down'
      detail="no $DAEMON process"
    elif ages=$(pair_ages "${pids[0]}" "${dline%% *}"); rage=${ages%% *}; dage=${ages#* }; [ "$rage" = - ]; then
      reason=missing
      pids=()
    elif [ "$dage" = - ]; then
      verdict='daemon-down'
      detail="no $DAEMON process"
    elif [ "$rage" -gt "$dage" ] || { [ "$rage" -eq "$dage" ] &&
        [ "$(cat "$STATE/$name.bound" 2>/dev/null)" != "${pids[0]} ${dline%% *}" ]; }; then
      reason='daemon-restarted'
      limited=0
      detail="relay age ${rage}s >= $DAEMON age ${dage}s"
    elif run_probe "$name" "$probe"; then
      [ "$ACT" -eq 1 ] && rm -f "$STATE/$name.fails"
      verdict=ok
    else
      fails=$(( $(read_int "$STATE/$name.fails") + 1 ))
      if [ "$fails" -ge "$PROBE_FAILS" ]; then
        reason='probe-failed'
      else
        [ "$ACT" -eq 1 ] && printf '%s\n' "$fails" > "$STATE/$name.fails"
        verdict='probe-failing'
      fi
      detail="probe failed $fails of $PROBE_FAILS passes"
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
      [ "${#pids[@]}" -eq 1 ] && printf '%s %s\n' "${pids[0]}" "$dpid" > "$STATE/$name.bound"
      probe_result=-
      if [ "${#pids[@]}" -eq 0 ]; then
        verdict='start-failed'
        detail="$reason; started relay is not running (see $name.log)"
        unhealthy=1
      elif run_probe "$name" "${PROBES[$idx]}"; then
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

canonical_home() {
  case "$FM_HOME" in /*) ;; *) die "FM_HOME must be absolute to render a unit" 2 ;; esac
  (cd -P -- "$FM_HOME" && pwd -P) || die "cannot resolve $FM_HOME" 2
}

unit_label() {  # <canonical-home>
  local sum _
  read -r sum _ <<< "$(printf '%s' "$1" | cksum)"
  printf 'firstmate-relay-guard-%s' "$sum"
}

xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

systemd_escape() {
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/%/%%/g'
}

render_launchd() {
  local home label script path
  home=$(canonical_home) || exit 2
  label=$(unit_label "$home")
  script=$(printf '%s' "$SCRIPT_DIR/fm-relay-guard.sh" | xml_escape)
  home=$(printf '%s' "$home" | xml_escape)
  path=$(printf '%s' "$PATH" | xml_escape)
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$script</string><string>run</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>FM_HOME</key><string>$home</string>
    <key>PATH</key><string>$path</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>AbandonProcessGroup</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
</dict></plist>
EOF
}

render_systemd() {
  local home label script path
  home=$(canonical_home) || exit 2
  label=$(unit_label "$home")
  script=$(printf '%s' "$SCRIPT_DIR/fm-relay-guard.sh" | systemd_escape)
  home=$(printf '%s' "$home" | systemd_escape)
  path=$(printf '%s' "$PATH" | systemd_escape)
  cat <<EOF
[Unit]
Description=Firstmate relay guard ($label)
StartLimitIntervalSec=0

[Service]
Type=simple
Environment="FM_HOME=$home"
Environment="PATH=$path"
ExecStart=/bin/bash "$script" run
Restart=always
RestartSec=10s
KillMode=process

[Install]
WantedBy=default.target
EOF
}

LOCKED=0
lock_live() {  # <lock dir>; zero while its owner still holds it
  local holder start
  holder=$(read_int "$1/pid")
  if [ "$holder" -gt 0 ]; then
    start=$(sed -n 2p "$1/pid" 2>/dev/null)
    [ -n "$start" ] && kill -0 "$holder" 2>/dev/null && [ "$(proc_start "$holder")" = "$start" ]
    return
  fi
  # No pid yet means the owner is between its mkdir and its pid write, so the
  # lock is live until it is a minute old.
  [ -n "$(find "$1" -prune -mmin -1 2>/dev/null)" ]
}

take_lock() {
  local stale="$STATE/lock.stale.$$"
  if ! mkdir "$STATE/lock.d" 2>/dev/null; then
    lock_live "$STATE/lock.d" && return 1
    mv "$STATE/lock.d" "$stale" 2>/dev/null || return 1
    if lock_live "$stale"; then
      mv "$stale" "$STATE/lock.d" 2>/dev/null
      return 1
    fi
    rm -rf "$stale"
    mkdir "$STATE/lock.d" 2>/dev/null || return 1
  fi
  printf '%s\n%s\n' "$$" "$(proc_start "$$")" > "$STATE/lock.d/pid.$$" && mv "$STATE/lock.d/pid.$$" "$STATE/lock.d/pid"
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
    sleep_pid=
    trap '[ -z "$sleep_pid" ] || kill "$sleep_pid" 2>/dev/null; drop_lock' EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    while :; do
      locked_pass
      [ "$?" -eq 75 ] && printf 'fm-relay-guard: skipped a pass; the lock is held\n' >&2
      sleep "$interval" &
      sleep_pid=$!
      wait "$sleep_pid"
      sleep_pid=
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
  render-launchd)
    [ "$#" -eq 0 ] || die "render-launchd takes no arguments" 2
    render_launchd
    ;;
  render-systemd)
    [ "$#" -eq 0 ] || die "render-systemd takes no arguments" 2
    render_systemd
    ;;
  -h|--help|help)
    sed -n '2,/^set -u$/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'
    ;;
  *)
    die "usage: FM_HOME=<home> fm-relay-guard.sh once|run [--interval <secs>]|scan|status|render-launchd|render-systemd" 2
    ;;
esac
