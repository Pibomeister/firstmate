#!/usr/bin/env bash
# fm-test-queue.sh - a machine-wide first-in, first-out line for heavy test runs.
#
# Many workers share one machine. Without a line, each heavy test run polls the
# load average on its own, several start at the same moment, the load spikes
# again, and nobody is served in order. This script is the line: each run takes
# a ticket, waits its turn, runs, and leaves.
#
# Usage:
#   fm-test-queue.sh run [--label <text>] -- <command> [args...]
#   fm-test-queue.sh status
#   fm-test-queue.sh --help
#
# run takes the next ticket and waits until all three hold at once:
#   - its ticket is the oldest live waiting ticket (the head of the line);
#   - fewer than <slots> tickets are being served;
#   - the 1-minute load average is below <load ceiling>.
# It then runs the command in the foreground, with the caller's stdin, stdout,
# stderr, and terminal, and exits with the command's exit status. The ticket
# and its slot are released after both the wrapper and workload group leave,
# including after an error or signal (INT, TERM, HUP, QUIT). While it waits
# it prints a line to stderr whenever its
# position or the reason it waits changes.
# --label names the run in status output; it defaults to the command line.
#
# A run nested inside a served run (FM_TEST_QUEUE_HELD names a ticket that is
# still being served by a live owner) runs its command at once without a second
# ticket, so a wrapped suite that wraps its own children cannot wait on itself.
#
# status prints the line. The first line is machine-readable, space-separated
# key=value pairs in this fixed order:
#   test-queue: slots=<N> load_ceiling=<X> load1=<X|unknown> serving=<N>
#     waiting=<N> stale=<N> spool=<path>
# (one physical line), then one line per live ticket, served tickets first:
#   serving ticket=<N> pid=<pid> age=<duration> task=<id|-> label=<text>
#   waiting position=<N> ticket=<N> pid=<pid> age=<duration> task=<id|-> label=<text>
# A served ticket's age counts from the moment it was served, a waiting
# ticket's from the moment it took its ticket. stale counts tickets whose wrapper
# and workload group are both dead; status reports them and the next run reclaims them.
#
# Spool: one per user, shared by every firstmate home on the machine:
#   ${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/test-queue
# FM_TEST_QUEUE_DIR overrides it. The spool holds tickets/<N> (one key=value
# file per ticket), next (the ticket counter), and lock (an atomically published
# owner directory that serializes every change to the line).
#
# Configuration: slots=<N> / load_ceiling=<X> lines in $SPOOL/config.
# Blank lines and # comments are ignored. All callers use this shared file;
# per-process slots, ceiling, and config-path overrides are not supported.
# Defaults: slots=2, load_ceiling=16.
# slots is a positive integer and load_ceiling a positive number. An invalid
# value or an unknown config key is reported on stderr and stops the script
# before any ticket is taken.
# FM_TEST_QUEUE_POLL sets the wait between admission checks in seconds
# (default 5).
#
# Dead owners: every ticket records its wrapper's pid and process start time,
# and its command's process group. A ticket is reclaimed only when both the
# wrapper and every process in that group are gone. A surviving command keeps
# its slot after a wrapper is killed, including by SIGKILL.
# Dead lock owners and old locks without a usable owner record are recovered
# only from the observed directory generation, after a 10-second grace period
# for an uninitialized owner record.
#
# Load probe: Darwin reads sysctl vm.loadavg, other systems /proc/loadavg. When
# no probe works, the load condition is skipped and only the line and the slots
# are enforced, with a one-line warning on stderr. Under FM_TEST_SEAM=1,
# FM_TEST_QUEUE_LOAD_FILE names a file whose
# first word stands in for the 1-minute load, read at every check.
#
# Portable to macOS Bash 3.2: no flock(1), no associative arrays.
#
# Exit status: run exits with the command's status, 128+N when a signal N ends
# the wait or the run, 2 on a usage error, and 125 when the queue itself cannot
# run the command (invalid configuration, unwritable spool, or a lock that
# cannot be taken). status exits 0, 2 on a usage error, or 125 on invalid
# configuration.
set -u
CALLER_LC_ALL_SET=${LC_ALL+x}
CALLER_LC_ALL=${LC_ALL-}
export LC_ALL=C

usage() {
  echo "usage: fm-test-queue.sh run [--label <text>] -- <command> [args...] | status | --help" >&2
  exit 2
}

die() {  # <message>: the queue itself cannot proceed
  echo "fm-test-queue: $1" >&2
  exit 125
}

is_uint() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
}

is_positive_number() {
  case "$1" in ''|.|*[!0-9.]*|*.*.*) return 1 ;; esac
  awk -v v="$1" 'BEGIN { exit !(v + 0 > 0) }'
}

SPOOL="${FM_TEST_QUEUE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/test-queue}"
case "$SPOOL" in /*) ;; *) SPOOL="$PWD/$SPOOL" ;; esac
CONFIG_FILE="$SPOOL/config"
TICKETS="$SPOOL/tickets"
LOCK="$SPOOL/lock"

# --- configuration ----------------------------------------------------------
load_config() {
  local key value line
  SLOTS=2
  LOAD_CEILING=16
  if [ -f "$CONFIG_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%%#*}
      line=$(printf '%s' "$line" | tr -d '[:space:]')
      [ -n "$line" ] || continue
      key=${line%%=*}
      value=${line#*=}
      [ "$key" != "$line" ] || die "invalid line in $CONFIG_FILE: $line"
      case "$key" in
        slots) SLOTS=$value ;;
        load_ceiling) LOAD_CEILING=$value ;;
        *) die "unknown key in $CONFIG_FILE: $key" ;;
      esac
    done < "$CONFIG_FILE"
  fi
  POLL=${FM_TEST_QUEUE_POLL:-5}
  { is_uint "$SLOTS" && [ "$SLOTS" -gt 0 ]; } || die "slots must be a positive integer, got '$SLOTS'"
  is_positive_number "$LOAD_CEILING" || die "load_ceiling must be a positive number, got '$LOAD_CEILING'"
  is_positive_number "$POLL" || die "FM_TEST_QUEUE_POLL must be a positive number, got '$POLL'"
}

# --- probes -----------------------------------------------------------------
load1() {  # prints the 1-minute load average, or fails
  local v=""
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_TEST_QUEUE_LOAD_FILE:-}" ]; then
    read -r v _ 2>/dev/null < "$FM_TEST_QUEUE_LOAD_FILE" || v=""
  elif [ -r /proc/loadavg ]; then
    read -r v _ 2>/dev/null < /proc/loadavg || v=""
  elif [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    v=$(sysctl -n vm.loadavg 2>/dev/null | awk '{ gsub(/[{}]/, ""); print $1 }')
  fi
  case "$v" in ''|.|*[!0-9.]*) return 1 ;; esac
  printf '%s\n' "$v"
}

# The start time disambiguates a reused pid. An empty start time (ps missing)
# degrades to a plain liveness check.
pid_start() {  # <pid>
  ps -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

owner_alive() {  # <pid> <recorded-start>
  local now_start
  is_uint "$1" || return 1
  kill -0 "$1" 2>/dev/null || return 1
  [ -n "$2" ] || return 0
  now_start=$(pid_start "$1")
  [ -z "$now_start" ] || [ "$now_start" = "$2" ]
}

path_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

human_age() {  # <seconds>
  local s=$1
  [ "$s" -ge 0 ] 2>/dev/null || s=0
  if [ "$s" -ge 3600 ]; then
    printf '%dh%02dm\n' $((s / 3600)) $((s % 3600 / 60))
  elif [ "$s" -ge 60 ]; then
    printf '%dm%02ds\n' $((s / 60)) $((s % 60))
  else
    printf '%ds\n' "$s"
  fi
}

# --- the lock ---------------------------------------------------------------
LOCK_TOKEN=""
LOCK_GENERATION=""
LOCK_CANDIDATE=""
HAVE_LOCK=0

path_identity() {
  stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null
}

lock_acquire() {
  local tries=0 pid start age m generation owner
  LOCK_TOKEN="$$ $(pid_start "$$")"
  LOCK_CANDIDATE=$(mktemp -d "$SPOOL/.lock.XXXXXXXX") || die "cannot prepare $LOCK"
  mkdir "$LOCK_CANDIDATE/lock" || die "cannot prepare $LOCK"
  (umask 077; printf '%s\n' "$LOCK_TOKEN" > "$LOCK_CANDIDATE/lock/owner") || die "cannot prepare $LOCK/owner"
  while :; do
    if [ ! -d "$LOCK" ] && mv "$LOCK_CANDIDATE/lock" "$SPOOL/" 2>/dev/null; then
      LOCK_GENERATION=$(path_identity "$LOCK") || die "cannot identify $LOCK"
      HAVE_LOCK=1
      rmdir "$LOCK_CANDIDATE"
      LOCK_CANDIDATE=""
      return 0
    fi
    generation=$(path_identity "$LOCK") || generation=""
    owner=$(cat "$LOCK/owner" 2>/dev/null) || owner=""
    pid="" start=""
    read -r pid start <<< "$owner"
    if is_uint "$pid" && [ "$pid" -gt 0 ] 2>/dev/null; then
      if ! owner_alive "$pid" "$start"; then
        lock_break "$generation" "$owner"
      fi
    elif [ -d "$LOCK" ]; then
      m=$(path_mtime "$LOCK") || m=""
      if [ -n "$m" ]; then
        age=$(( $(date +%s) - m ))
        if [ "$age" -gt 10 ]; then
          lock_break "$generation" "$owner"
        fi
      fi
    fi
    tries=$((tries + 1))
    [ "$tries" -lt 600 ] || die "could not take $LOCK (held by pid ${pid:-unknown})"
    sleep 0.05
  done
}

lock_break() (
  local owner=""
  [ -n "$1" ] || return 0
  cd "$LOCK" 2>/dev/null || return 0
  [ "$(path_identity .)" = "$1" ] || return 0
  owner=$(cat owner 2>/dev/null) || owner=""
  [ "$owner" = "$2" ] || return 0
  rm -f owner
  rmdir "$LOCK" 2>/dev/null || true
)

lock_release() {
  [ "$HAVE_LOCK" = 1 ] || return 0
  HAVE_LOCK=0
  lock_break "$LOCK_GENERATION" "$LOCK_TOKEN"
}

# --- tickets ----------------------------------------------------------------
# Each ticket is tickets/<10-digit number>, so lexical order is line order.
# Fields: pid, start, pgid, enqueued, served (empty while waiting), task, label.
T_PID="" T_START="" T_PGID="" T_ENQUEUED="" T_SERVED="" T_TASK="" T_LABEL=""

ticket_read() {  # <file>
  local line k v
  T_PID="" T_START="" T_PGID="" T_ENQUEUED="" T_SERVED="" T_TASK="" T_LABEL=""
  [ -f "$1" ] || return 1
  while IFS= read -r line; do
    k=${line%%=*}
    v=${line#*=}
    case "$k" in
      pid) T_PID=$v ;;
      start) T_START=$v ;;
      pgid) T_PGID=$v ;;
      enqueued) T_ENQUEUED=$v ;;
      served) T_SERVED=$v ;;
      task) T_TASK=$v ;;
      label) T_LABEL=$v ;;
    esac
  done < "$1"
}

ticket_write() {  # <file> ; writes the T_* fields atomically
  local tmp="$1.tmp.$$"
  (umask 077; printf 'pid=%s\nstart=%s\npgid=%s\nenqueued=%s\nserved=%s\ntask=%s\nlabel=%s\n' \
    "$T_PID" "$T_START" "$T_PGID" "$T_ENQUEUED" "$T_SERVED" "$T_TASK" "$T_LABEL" > "$tmp") &&
    mv -f "$tmp" "$1"
}

ticket_files() {
  local f
  for f in "$TICKETS"/[0-9]*; do
    case "$f" in *.tmp.*) continue ;; esac
    [ -f "$f" ] && printf '%s\n' "$f"
  done
}

group_alive() {
  local members
  is_uint "$1" && [ "$1" -gt 0 ] 2>/dev/null || return 1
  kill -0 -- "-$1" 2>/dev/null || return 1
  members=$(ps -axo pgid=,stat=) || return 0
  awk -v g="$1" '$1 == g && $2 !~ /^Z/ { live=1 } END { exit !live }' <<< "$members"
}

ticket_alive() {
  owner_alive "$T_PID" "$T_START" || group_alive "$T_PGID"
}

reclaim_dead() {
  local f
  while IFS= read -r f; do
    ticket_read "$f" || continue
    ticket_alive || rm -f "$f"
  done < <(ticket_files)
}

# --- run --------------------------------------------------------------------
MY_TICKET=""

cleanup() {
  if [ -n "$MY_TICKET" ]; then
    if ticket_read "$MY_TICKET" && ! group_alive "$T_PGID"; then
      rm -f "$MY_TICKET"
    fi
    MY_TICKET=""
  fi
  lock_release
  [ -z "$LOCK_CANDIDATE" ] || rm -rf "$LOCK_CANDIDATE"
}

# Sets MY_NUMBER and MY_TICKET. The number is never below an existing
# ticket's, even when the counter file is lost, so a new ticket cannot jump
# the line.
MY_NUMBER=""
take_ticket() {  # <label>
  local n f last=""
  (umask 077; mkdir -p "$SPOOL" "$TICKETS") 2>/dev/null || die "cannot create $TICKETS"
  chmod 700 "$SPOOL" "$TICKETS" || die "cannot protect $SPOOL"
  { [ -w "$SPOOL" ] && [ -w "$TICKETS" ]; } || die "cannot write to $SPOOL"
  lock_acquire
  reclaim_dead
  n=""
  [ -f "$SPOOL/next" ] && read -r n < "$SPOOL/next"
  is_uint "$n" || n=1
  n=$((10#$n))
  while IFS= read -r f; do last=$f; done < <(ticket_files)
  if [ -n "$last" ] && [ $((10#${last##*/})) -ge "$n" ]; then
    n=$((10#${last##*/} + 1))
  fi
  T_PID=$$
  T_START=$(pid_start "$$")
  T_PGID=""
  T_ENQUEUED=$(date +%s)
  T_SERVED=""
  T_TASK=${FM_TASK_ID:-}
  T_LABEL=$1
  while :; do
    f=$(printf '%s/%010d' "$TICKETS" "$n")
    [ -e "$f" ] || break
    n=$((n + 1))
  done
  ticket_write "$f" || die "cannot write ticket $f"
  MY_TICKET=$f
  MY_NUMBER=$n
  (umask 077; printf '%s\n' $((n + 1)) > "$SPOOL/next") || die "cannot write $SPOOL/next"
  lock_release
}

# Under the lock: decide whether this ticket may be served now. Prints the
# reason it must wait (empty when admitted) and the position.
WAIT_REASON="" POSITION=0
admission_check() {
  local f serving=0 head="" pos=0 load=""
  POSITION=0
  while IFS= read -r f; do
    ticket_read "$f" || continue
    if [ -n "$T_SERVED" ]; then
      serving=$((serving + 1))
    else
      pos=$((pos + 1))
      [ -n "$head" ] || head=$f
      [ "$f" = "$MY_TICKET" ] && POSITION=$pos
    fi
  done < <(ticket_files)
  if [ "$head" != "$MY_TICKET" ]; then
    WAIT_REASON="waiting behind $((POSITION - 1)) earlier ticket(s)"
  elif [ "$serving" -ge "$SLOTS" ]; then
    WAIT_REASON="all $SLOTS slot(s) busy"
  elif load=$(load1) && ! awk -v l="$load" -v c="$LOAD_CEILING" 'BEGIN { exit !(l + 0 < c + 0) }'; then
    WAIT_REASON="load $load is not below $LOAD_CEILING"
  else
    if [ -z "$load" ]; then
      echo "fm-test-queue: warning: load probe failed; enforcing slot limit only" >&2
    fi
    WAIT_REASON=""
  fi
}

command_exec() {
  if [ "$CALLER_LC_ALL_SET" = x ]; then
    export LC_ALL="$CALLER_LC_ALL"
  else
    unset LC_ALL
  fi
  exec "$@"
}

cmd_run() {
  local label="" n last="" command_pid rc terminal=/dev/fd/2 startup_stderr=/dev/null
  while [ $# -gt 0 ]; do
    case "$1" in
      --label) [ $# -ge 2 ] || usage; label=$2; shift 2 ;;
      --) shift; break ;;
      *) usage ;;
    esac
  done
  [ $# -gt 0 ] || usage
  load_config

  # Already inside a served run: run at once rather than waiting on ourselves.
  if [ -n "${FM_TEST_QUEUE_HELD:-}" ] && ticket_read "$FM_TEST_QUEUE_HELD" &&
    [ -n "$T_SERVED" ] && ticket_alive; then
    command_exec "$@"
  fi

  if { : </dev/tty; } 2>/dev/null; then
    terminal=/dev/tty
    startup_stderr=/dev/tty
  fi
  case "$-" in
    *i*) ;;
    *)
      # shellcheck disable=SC2016
      command_exec env HISTFILE= BASH_SILENCE_DEPRECATION_WARNING=1 "$BASH" --noprofile --norc -i -c '
        set +o history
        exec 2>&9 9>&-
        for name in HISTFILE BASH_SILENCE_DEPRECATION_WARNING; do
          if [ "$1" = x ]; then export "$name=$2"; else unset "$name"; fi
          shift 2
        done
        unset name
        . "$0" "$@"
      ' "$0" "${HISTFILE+x}" "${HISTFILE-}" \
        "${BASH_SILENCE_DEPRECATION_WARNING+x}" "${BASH_SILENCE_DEPRECATION_WARNING-}" \
        run --label "$label" -- "$@" 9>&2 2>>"$startup_stderr"
      ;;
  esac

  [ -n "$label" ] || label="$*"
  label=$(printf '%s' "$label" | tr '\n\r' '  ')

  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  trap 'exit 131' QUIT

  take_ticket "$label"
  n=$MY_NUMBER

  while :; do
    lock_acquire
    reclaim_dead
    [ -f "$MY_TICKET" ] || { lock_release; die "ticket $n vanished from $TICKETS"; }
    admission_check
    if [ -z "$WAIT_REASON" ]; then
      ticket_read "$MY_TICKET"
      T_SERVED=$(date +%s)
      ticket_write "$MY_TICKET" || { lock_release; die "cannot update ticket $n"; }
      lock_release
      break
    fi
    lock_release
    if [ "position $POSITION: $WAIT_REASON" != "$last" ]; then
      last="position $POSITION: $WAIT_REASON"
      echo "fm-test-queue: ticket $n, $last" >&2
    fi
    sleep "$POLL"
  done

  [ -z "$last" ] || echo "fm-test-queue: ticket $n served" >&2
  set -m 2>>"$terminal"
  (
    set +m
    while :; do
      ticket_read "$MY_TICKET" || exit 125
      [ -n "$T_PGID" ] && break
      owner_alive "$T_PID" "$T_START" || exit 125
      sleep 0.05
    done
    export FM_TEST_QUEUE_HELD=$MY_TICKET
    command_exec "$@"
  ) <&0 &
  command_pid=$!
  ticket_read "$MY_TICKET" || die "cannot read ticket $n"
  T_PGID=$command_pid
  ticket_write "$MY_TICKET" || die "cannot record process group for ticket $n"
  while :; do
    fg %+ >/dev/null 2>>"$terminal"
    wait "$command_pid"
    rc=$?
    [ "$(jobs -p)" = "$command_pid" ] || break
    if [ "$(jobs -sp)" = "$command_pid" ]; then
      kill -STOP "$$"
    fi
  done
  set +m 2>>"$terminal"
  return "$rc"
}

# --- status -----------------------------------------------------------------
cmd_status() {
  local f now serving=0 waiting=0 stale=0 pos=0 load lines_s="" lines_w="" age
  [ $# -eq 0 ] || usage
  load_config
  now=$(date +%s)
  load=$(load1) || load=unknown
  if [ -d "$TICKETS" ]; then
    while IFS= read -r f; do
      ticket_read "$f" || continue
      if ! ticket_alive; then
        stale=$((stale + 1))
        continue
      fi
      if [ -n "$T_SERVED" ]; then
        serving=$((serving + 1))
        age=$(human_age $((now - T_SERVED)))
        lines_s="${lines_s}serving ticket=$((10#${f##*/})) pid=$T_PID age=$age task=${T_TASK:--} label=$T_LABEL"$'\n'
      else
        waiting=$((waiting + 1))
        pos=$((pos + 1))
        age=$(human_age $((now - ${T_ENQUEUED:-$now})))
        lines_w="${lines_w}waiting position=$pos ticket=$((10#${f##*/})) pid=$T_PID age=$age task=${T_TASK:--} label=$T_LABEL"$'\n'
      fi
    done < <(ticket_files)
  fi
  echo "test-queue: slots=$SLOTS load_ceiling=$LOAD_CEILING load1=$load serving=$serving waiting=$waiting stale=$stale spool=$SPOOL"
  printf '%s%s' "$lines_s" "$lines_w"
}

case "${1:-}" in
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  run) shift; cmd_run "$@" ;;
  status) shift; cmd_status "$@" ;;
  *) usage ;;
esac
