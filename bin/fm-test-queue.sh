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
# It then runs the command as an ordinary child in the wrapper's job, with the
# caller's stdin, stdout, and stderr, and exits with the command's exit status.
# A signal (INT, TERM, HUP, QUIT) sent only to the wrapper takes effect after
# the command exits; signals sent to the job reach its members normally.
# The slot stays occupied while the recorded wrapper, child, or leader group
# is live. Cleanup removes the ticket when no workload remains; tickets left
# after a crash or signal become stale and are reclaimed by the next run.
# While it waits, it prints a line to stderr whenever its position or the
# reason it waits changes.
# --label names the run in status output; it defaults to the command line.
#
# A run nested inside a served run (FM_TEST_QUEUE_HELD names a served ticket
# that is still live under the lifetime rules below) runs at once without a second
# ticket, so a wrapped suite that wraps its own children cannot wait on itself.
# bin/fm-test-run.sh enters this line on its own for broad selections; its
# header owns which selections queue and their inner-script cap per slot.
#
# status prints the line. The first line is machine-readable, space-separated
# key=value pairs in this fixed order:
#   test-queue: slots=<N> load_ceiling=<X> load1=<X|unknown> serving=<N>
#     waiting=<N> stale=<N> spool=<path>
# (one physical line), then one line per live ticket, served tickets first:
#   serving ticket=<N> pid=<pid> age=<duration> task=<id|-> label=<text>
#   waiting position=<N> ticket=<N> pid=<pid> age=<duration> task=<id|-> label=<text>
# A served ticket's age counts from the moment it was served, a waiting
# ticket's from the moment it took its ticket. stale counts tickets with no live
# recorded wrapper, child, or leader group; the next run reclaims them.
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
# Optional remote_hosts is a comma-separated list of SSH aliases (for example
# m3,hetzner). offload_threshold defaults to 8. Above that load, the head ticket
# with a free slot first tries those hosts in order, with noninteractive SSH.
# offload_projects is a comma-separated list of project names, matched against
# the last path segment of the caller checkout's origin URL without .git; it
# defaults to firstmate, whose suites are self-contained Bash. A project not on
# the list always uses local admission.
# These settings live in the shared config; an empty host or project list
# disables offload.
# A failed preparation falls back to ordinary local admission and retries after
# 60 seconds while waiting. Preparation includes the snapshot upload and the
# queue scripts, which travel beside the snapshot rather than inside it, so a
# failure before the suite starts never becomes a test result. It never bypasses the local ceiling or slot limit.
# Remote runs use the remote user's queue and its local load/slot policy;
# FM_TEST_QUEUE_REMOTE_DISABLE=1 prevents recursive offloading there.
# The transport snapshots the current Git checkout (shallow HEAD, tracked and
# nonignored untracked files, including edits and deletions) into a private
# remote temporary checkout. Rsync sends only changed data to a persistent
# per-repository mirror in ~/.cache/firstmate/test-mirrors on each remote host.
# Worktrees sharing a Git common directory reuse that mirror.
# A private copy isolates each run from later syncs and test-written files.
# A SHA-256 inventory verifies source paths, bytes, modes and symlinks before
# admission; Git HEAD, tree and index identity are checked separately.
# A mismatch falls back locally before any workload starts.
# Mirror locks serialize preparations; a busy lock falls back locally, and a lock
# abandoned for more than 30 minutes is reclaimed.
# Commands that need older history must fetch it explicitly. Git, rsync, Python 3,
# Bash and test dependencies must already exist remotely.
# Ignored dependencies, credentials and caller environment are not copied. Worktree paths in argv are rewritten to the remote checkout;
# other absolute paths must be valid remotely. stdin/stdout/stderr and exit
# status pass through. Once execution is attempted, an SSH error is returned,
# never retried locally, because the remote workload may already have started.
# Remote scratch is removed on wrapper exit after a normal result when SSH
# remains reachable. An ambiguous transport/signal result preserves the scratch
# path and reports it, so cleanup cannot disrupt a possibly running workload.
# slots is a positive integer and load_ceiling a positive number. An invalid
# value or an unknown config key is reported on stderr and stops the script
# before any ticket is taken.
# FM_TEST_QUEUE_POLL sets the wait between admission checks in seconds
# (default 5).
#
# Dead owners: every ticket records its wrapper's and direct child's pids and
# process start times. It also records the wrapper's pgid and parent pid when
# the wrapper leads that group (pgid equals pid) and the parent is outside it.
# A ticket stays live while any recorded identity or leader group remains
# alive, including after wrapper SIGKILL.
# Commands inherit the wrapper's job; the queue creates no process group and
# does not manage the terminal. If the wrapper and its direct child both die
# while grandchildren survive in a group the wrapper did not lead, the slot
# can be freed early.
# Stragglers: once the direct child has exited, members of a recorded leader
# group that the workload left behind are ended (TERM, then KILL after a
# 2-second grace) before the slot is released. When a led group's command is
# served, the wrapper starts a small holder in that group and records it with
# the group members already present, which are the pipeline stages its parent
# started beside it and anything a shell that exec'd into the wrapper had
# started. The holder's membership keeps the group id from being
# reused, so only a member reaps the group: the wrapper on exit, or the
# holder once both the wrapper and child are gone. The next run that finds
# both dead only wakes the holder if it is stopped, and the slot stays held
# until the holder is done. While the child has not yet recorded itself, the
# holder waits as long as anything else remains in the group.
# A straggler is a group member other than the wrapper, the holder, or a
# recorded pipeline stage and its own descendants, whose ancestry reaches the
# wrapper or leaves the group through any process other than the recorded
# parent, such as init after reparenting; a recorded parent that is init
# itself counts as none, and orphans that a subreaper parent adopts are
# spared as its own. Each signal goes only to a process
# whose group and start time still match a fresh snapshot; only the brief
# moment between that snapshot and the signal is left open, which no
# portable shell primitive closes. Tickets without a holder, written
# by an older queue, are never reaped. A leaked background process holding
# the caller's output therefore cannot hold a slot or keep the caller's pipe
# open. On a remote host the queue replaces the SSH session's shell, so it
# leads the session group there and the same rule closes the SSH output
# streams.
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
set +m
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
SCRIPT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=bin/fm-test-queue-remote.sh
. "$SCRIPT_DIR/fm-test-queue-remote.sh"

# --- configuration ----------------------------------------------------------
load_config() {
  local key value line
  SLOTS=2
  LOAD_CEILING=16
  REMOTE_HOSTS=""
  OFFLOAD_THRESHOLD=8
  OFFLOAD_PROJECTS=firstmate
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
        remote_hosts) REMOTE_HOSTS=$value ;;
        offload_threshold) OFFLOAD_THRESHOLD=$value ;;
        offload_projects) OFFLOAD_PROJECTS=$value ;;
        *) die "unknown key in $CONFIG_FILE: $key" ;;
      esac
    done < "$CONFIG_FILE"
  fi
  POLL=${FM_TEST_QUEUE_POLL:-5}
  { is_uint "$SLOTS" && [ "$SLOTS" -gt 0 ]; } || die "slots must be a positive integer, got '$SLOTS'"
  is_positive_number "$LOAD_CEILING" || die "load_ceiling must be a positive number, got '$LOAD_CEILING'"
  is_positive_number "$OFFLOAD_THRESHOLD" || die "offload_threshold must be a positive number, got '$OFFLOAD_THRESHOLD'"
  case "$REMOTE_HOSTS" in *[!a-zA-Z0-9@._,-]*|-*|*,-*|,*|*,|*,,*) die "remote_hosts must contain comma-separated SSH aliases" ;; esac
  case "$OFFLOAD_PROJECTS" in *[!a-zA-Z0-9._,-]*|,*|*,|*,,*) die "offload_projects must contain comma-separated project names" ;; esac
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
  TZ=UTC LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# pid_running <pid> <recorded-start>: owner_alive, except that a zombie is
# not running. A killed wrapper stays a zombie while a caller that reads its
# output to the end before waiting is held by a straggler.
pid_running() {
  owner_alive "$1" "$2" || return 1
  case $(ps -p "$1" -o stat= 2>/dev/null) in
    *Z*) return 1 ;;
  esac
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
  local tries=0 pid start age m generation owner lock_pid=${1:-$$}
  LOCK_TOKEN="$lock_pid $(pid_start "$lock_pid")"
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
# Fields: pid, start, child_pid, child_start, pgid, caller_pid, holder_pid,
# holder_start, siblings, enqueued, served, task, label. siblings lists
# pid@start words. Readers ignore unknown fields, and a field an older queue
# did not write is read as empty.
T_PID="" T_START="" T_CHILD_PID="" T_CHILD_START="" T_PGID="" T_CALLER="" T_HOLDER_PID="" T_HOLDER_START="" T_SIBLINGS="" T_ENQUEUED="" T_SERVED="" T_TASK="" T_LABEL=""

ticket_read() {  # <file>
  local line k v
  T_PID="" T_START="" T_CHILD_PID="" T_CHILD_START="" T_PGID="" T_CALLER="" T_HOLDER_PID="" T_HOLDER_START="" T_SIBLINGS="" T_ENQUEUED="" T_SERVED="" T_TASK="" T_LABEL=""
  [ -f "$1" ] || return 1
  while IFS= read -r line; do
    k=${line%%=*}
    v=${line#*=}
    case "$k" in
      pid) T_PID=$v ;;
      start) T_START=$v ;;
      child_pid) T_CHILD_PID=$v ;;
      child_start) T_CHILD_START=$v ;;
      pgid) T_PGID=$v ;;
      caller_pid) T_CALLER=$v ;;
      holder_pid) T_HOLDER_PID=$v ;;
      holder_start) T_HOLDER_START=$v ;;
      siblings) T_SIBLINGS=$v ;;
      enqueued) T_ENQUEUED=$v ;;
      served) T_SERVED=$v ;;
      task) T_TASK=$v ;;
      label) T_LABEL=$v ;;
    esac
  done < "$1"
}

ticket_write() {  # <file> ; writes the T_* fields atomically
  local tmp="$1.tmp.$$"
  (umask 077; printf 'pid=%s\nstart=%s\nchild_pid=%s\nchild_start=%s\npgid=%s\ncaller_pid=%s\nholder_pid=%s\nholder_start=%s\nsiblings=%s\nenqueued=%s\nserved=%s\ntask=%s\nlabel=%s\n' \
    "$T_PID" "$T_START" "$T_CHILD_PID" "$T_CHILD_START" "$T_PGID" "$T_CALLER" "$T_HOLDER_PID" "$T_HOLDER_START" "$T_SIBLINGS" "$T_ENQUEUED" "$T_SERVED" "$T_TASK" "$T_LABEL" > "$tmp") &&
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
  members=$(
    printf '%s\n' "${BASHPID:-$(exec sh -c 'printf "%s" "$PPID"')}"
    exec ps -axo pgid=,pid=,stat=
  ) || return 0
  awk -v g="$1" -v owner="${2:-0}" 'NR == 1 { probe=$1; next } $1 == g && $2 != owner && $2 != probe && $3 !~ /^Z/ { live=1 } END { exit !live }' <<< "$members"
}

workload_alive() {
  owner_alive "$T_CHILD_PID" "$T_CHILD_START" || group_alive "$T_PGID" "${1:-0}"
}

ticket_alive() {
  owner_alive "$T_PID" "$T_START" || workload_alive
}

# group_snapshot: prints the probe's pid, then one "pid ppid pgid stat start"
# line per process, the start time's words joined by "_" so one snapshot
# names a process the same way every time.
group_snapshot() {
  printf '%s\n' "${BASHPID:-$(exec sh -c 'printf "%s" "$PPID"')}"
  TZ=UTC LC_ALL=C exec ps -axo pid=,ppid=,pgid=,stat=,lstart=
}

# group_walk <siblings|stragglers> [<pid to leave out>]: classifies the live
# members of the read ticket's group from one snapshot, printing pid@start
# words. siblings lists the members that do not descend from the wrapper,
# plus its existing children, which a shell that exec'd into the wrapper
# started, such as a process substitution's consumer; stragglers lists the
# header's straggler rule. The probe and its ancestors
# (this reaper's own subshells) are never listed.
group_walk() {
  local members
  members=$(group_snapshot) || return 1
  awk -v mode="$1" -v out="${2:-}" -v g="$T_PGID" -v w="$T_PID" -v c="$T_CALLER" -v sib="$T_SIBLINGS" '
    NR == 1 { probe = $1; next }
    {
      parent[$1] = $2; group[$1] = $3; state[$1] = $4
      s = $5; for (i = 6; i <= NF; i++) s = s "_" $i
      start[$1] = s
    }
    END {
      n = split(sib, list, " ")
      for (i = 1; i <= n; i++) spared[list[i]] = 1
      for (q = probe; (q in parent) && !(q in self); q = parent[q]) self[q] = 1
      for (p in group) {
        if (group[p] != g || p == w || p == out || (p in self) || state[p] ~ /^Z/) continue
        q = p; hops = 0; keep = 0; descends = 0
        while (hops++ < 4096) {
          # The holder and what it runs are never caller stages.
          if (q == out && mode == "siblings") { descends = 1; break }
          if (q == out || (q "@" start[q]) in spared) { keep = 1; break }
          r = parent[q]
          if (r == w) { descends = 1; break }
          if (!(r in group) || group[r] != g) { keep = (r == c && c > 1); break }
          q = r
        }
        if (mode == "siblings" ? (!descends || parent[p] == w) : !keep) print p "@" start[p]
      }
    }' <<< "$members"
}

# signal_listed <signal> <pid@start...>: signals each listed process that is
# still in the read ticket's group with the same start time. TERM is followed
# by CONT so a stopped process acts on it.
signal_listed() {
  local sig=$1 members pids
  shift
  members=$(group_snapshot) || return 0
  pids=$(awk -v want="$*" -v g="$T_PGID" '
    BEGIN { n = split(want, list, " "); for (i = 1; i <= n; i++) listed[list[i]] = 1 }
    NR == 1 { next }
    {
      s = $5; for (i = 6; i <= NF; i++) s = s "_" $i
      if ($3 == g && ($1 "@" s) in listed) print $1
    }' <<< "$members")
  [ -n "$pids" ] || return 0
  # shellcheck disable=SC2086 # One pid per word.
  kill -"$sig" $pids 2>/dev/null
  # shellcheck disable=SC2086 # One pid per word.
  [ "$sig" != TERM ] || kill -CONT $pids 2>/dev/null
}

# ticket_group_reapable <exit|hold|stale>: whether the read ticket's recorded
# group is the wrapper's own, its workload is over, and the caller can prove
# the group was never reused. exit is the wrapper on the way out; hold is the
# holder once the wrapper is gone; stale is another run that finds the wrapper
# gone and the holder alive, and then only wakes the holder.
ticket_group_reapable() {
  local caller_group
  is_uint "$T_PGID" && [ "$T_PGID" -gt 1 ] && [ "$T_PGID" = "$T_PID" ] || return 1
  is_uint "$T_HOLDER_PID" && [ -n "$T_CHILD_PID" ] || return 1
  ! pid_running "$T_CHILD_PID" "$T_CHILD_START" || return 1
  case "$1" in
    exit) [ "$T_PID" = "$$" ] || return 1 ;;
    hold) ! pid_running "$T_PID" "$T_START" || return 1 ;;
    stale)
      ! pid_running "$T_PID" "" || return 1
      [ "$(ps -p "$$" -o pgid= 2>/dev/null | tr -d '[:space:]')" != "$T_PGID" ] || return 1
      [ -n "$T_HOLDER_START" ] && [ "$(pid_start "$T_HOLDER_PID")" = "$T_HOLDER_START" ] || return 1
      [ "$(ps -p "$T_HOLDER_PID" -o pgid= 2>/dev/null | tr -d '[:space:]')" = "$T_PGID" ] || return 1
      ;;
    *) return 1 ;;
  esac
  if is_uint "$T_CALLER" && [ "$T_CALLER" -gt 1 ] && kill -0 "$T_CALLER" 2>/dev/null; then
    caller_group=$(ps -p "$T_CALLER" -o pgid= 2>/dev/null | tr -d '[:space:]')
    [ "$caller_group" != "$T_PGID" ] || return 1
  fi
}

# reap_stragglers [<pid to leave out>]: ends the read ticket's stragglers,
# TERM first, then KILL for any still present after a 2-second grace. The
# left-out pid and its descendants are spared. Returns nonzero when a
# straggler outlasts five KILL rounds.
reap_stragglers() {
  local out=${1:-} list sig=TERM limit=20 i kills=0
  while :; do
    list=$(group_walk stragglers "$out") || return 1
    [ -n "$list" ] || break
    # shellcheck disable=SC2086 # One pid@start per word.
    signal_listed "$sig" $list
    i=0
    while [ "$i" -lt "$limit" ]; do
      sleep 0.1
      list=$(group_walk stragglers "$out") || return 1
      [ -n "$list" ] || break 2
      i=$((i + 1))
    done
    # A straggler that forked after a KILL snapshot leaves a new survivor,
    # so KILL repeats a few rounds before giving up.
    if [ "$sig" = KILL ]; then
      kills=$((kills + 1))
      [ "$kills" -lt 5 ] || return 1
    fi
    sig=KILL limit=10
  done
}

# hold_group: the holder, started in the background when a led group's
# command is served. Its membership keeps the group id reserved. It exits on
# TERM, and if the wrapper dies without its cleanup it reaps the stragglers
# itself once the child is gone. A child that has not recorded itself yet
# shows up as a straggler, so the holder waits while any remain.
hold_group() {
  local nap="" list self tries
  self=${BASHPID:-$(exec sh -c 'printf "%s" "$PPID"')}
  trap '[ -z "$nap" ] || { kill "$nap" 2>/dev/null; kill -CONT "$nap" 2>/dev/null; wait "$nap" 2>/dev/null; }; exit 0' TERM
  # A Ctrl-C to the run's group must not end the holder.
  trap '' INT QUIT
  exec </dev/null >/dev/null 2>&1
  while pid_running "$T_PID" "$T_START"; do
    hold_nap
  done
  while :; do
    ticket_read "$MY_TICKET" || exit 0
    [ -z "$T_CHILD_PID" ] || break
    if list=$(group_walk stragglers); then
      [ -n "$list" ] || exit 0
    fi
    hold_nap
  done
  # Only the holder the ticket names reaps its group.
  [ "$T_HOLDER_PID" = "$self" ] || exit 0
  while pid_running "$T_CHILD_PID" "$T_CHILD_START"; do
    hold_nap
  done
  tries=0
  while ticket_group_reapable hold && ! reap_stragglers; do
    tries=$((tries + 1))
    [ "$tries" -lt 5 ] || break
    hold_nap
  done
  exit 0
}

# hold_nap: a 2-second wait the holder's TERM trap can cut short; it sets
# the caller's nap.
hold_nap() {
  sleep 2 & nap=$!
  wait "$nap"
  nap=""
}

# holder_is_ours: true while the holder is still listed among this shell's
# jobs. A running or stopped job's pid cannot belong to another process; bash
# 3.2 can list a job that something else killed a moment ago until its next
# fork, which leaves only that brief pid-reuse window open.
holder_is_ours() {
  case " $(jobs -p 2>/dev/null | tr '\n' ' ') " in
    *" $HOLDER_PID "*) return 0 ;;
  esac
  return 1
}
# stop_holder: ends the holder and waits only for a holder it signalled; one
# it cannot prove is ours is left to exit on its own once the wrapper is gone.
stop_holder() {
  [ -n "$HOLDER_PID" ] || return 0
  if holder_is_ours; then
    kill "$HOLDER_PID" 2>/dev/null
    kill -CONT "$HOLDER_PID" 2>/dev/null
    wait "$HOLDER_PID" 2>/dev/null
  fi
  HOLDER_PID="" HOLDER_START=""
}

reclaim_dead() {
  local f
  while IFS= read -r f; do
    ticket_read "$f" || continue
    # Only a member reaps, so the group id cannot be reused mid-reap; a
    # stopped holder is woken and the ticket stays live until it is done.
    if ticket_group_reapable stale; then
      kill -CONT "$T_HOLDER_PID" 2>/dev/null
    fi
    ticket_alive || rm -f "$f"
  done < <(ticket_files)
}

# --- run --------------------------------------------------------------------
MY_TICKET=""
HOLDER_PID="" HOLDER_START=""

cleanup() {
  remote_cleanup
  if [ -n "$MY_TICKET" ]; then
    if ticket_read "$MY_TICKET"; then
      # With no recorded child yet, a running holder keeps the group.
      if [ -n "$T_CHILD_PID" ] && ! owner_alive "$T_CHILD_PID" "$T_CHILD_START"; then
        # The holder is spared, so a wrapper killed mid-reap leaves it to finish.
        # A reap that could not finish leaves the holder to retry.
        if ticket_group_reapable exit; then
          ! reap_stragglers "$HOLDER_PID" || stop_holder
        else
          stop_holder
        fi
      fi
      workload_alive "$$" || rm -f "$MY_TICKET"
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
  T_CHILD_PID=""
  T_CHILD_START=""
  T_HOLDER_PID="" T_HOLDER_START="" T_SIBLINGS=""
  T_PGID=$(ps -p "$$" -o pgid= 2>/dev/null | tr -d '[:space:]')
  T_CALLER=$PPID
  # Record a group only when it is this wrapper's own: it leads the group
  # and its parent stays outside it.
  if [ "$T_PGID" != "$$" ] || [ "$(ps -p "$PPID" -o pgid= 2>/dev/null | tr -d '[:space:]')" = "$$" ]; then
    T_PGID="" T_CALLER=""
  fi
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
WAIT_REASON="" POSITION=0 WANT_REMOTE=0 OFFLOAD_LISTED=0
admission_check() {
  local f serving=0 head="" pos=0 load=""
  POSITION=0
  WANT_REMOTE=0
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
  else
    load=$(load1) || load=""
    if [ -z "$REMOTE_HOST" ] && [ "$OFFLOAD_LISTED" = 1 ] &&
      [ -n "$load" ] && awk -v l="$load" -v c="$OFFLOAD_THRESHOLD" 'BEGIN { exit !(l + 0 > c + 0) }'; then
      WANT_REMOTE=1
    fi
    if [ -z "$REMOTE_HOST" ] && [ -n "$load" ] && ! awk -v l="$load" -v c="$LOAD_CEILING" 'BEGIN { exit !(l + 0 < c + 0) }'; then
      WAIT_REASON="load $load is not below $LOAD_CEILING"
      return
    fi
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
  local label="" n last="" remote_retry=0 now
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

  [ -n "$label" ] || label="$*"
  label=$(printf '%s' "$label" | tr '\n\r' '  ')

  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  trap 'exit 131' QUIT

  if [ -n "$REMOTE_HOSTS" ] && [ "${FM_TEST_QUEUE_REMOTE_DISABLE:-}" != 1 ] && remote_project_listed; then
    OFFLOAD_LISTED=1
  fi

  take_ticket "$label"
  n=$MY_NUMBER

  while :; do
    lock_acquire
    reclaim_dead
    [ -f "$MY_TICKET" ] || { lock_release; die "ticket $n vanished from $TICKETS"; }
    admission_check
    now=$(date +%s)
    if [ "$WANT_REMOTE" = 1 ] && [ "$now" -ge "$remote_retry" ]; then
      lock_release
      if ! remote_prepare; then
        echo "fm-test-queue: no remote prepared; using local admission" >&2
        remote_retry=$(( $(date +%s) + 60 ))
      fi
      continue
    fi
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
  if [ -n "$T_PGID" ]; then
    hold_group &
    HOLDER_PID=$!
    HOLDER_START=$(pid_start "$HOLDER_PID")
  fi
  (
    local child_pid siblings
    child_pid=${BASHPID:-$(exec sh -c 'printf "%s" "$PPID"')} || exit 125
    lock_acquire "$child_pid"
    ticket_read "$MY_TICKET" || die "cannot read ticket $n"
    T_CHILD_PID=$child_pid
    T_CHILD_START=$(pid_start "$child_pid")
    # Without a sibling list the holder is left unrecorded, so nothing is
    # reaped rather than a pipeline stage.
    if [ -n "$HOLDER_START" ] && [ -n "$T_PGID" ] && siblings=$(group_walk siblings "$HOLDER_PID"); then
      T_HOLDER_PID=$HOLDER_PID
      T_HOLDER_START=$HOLDER_START
      T_SIBLINGS=$(printf '%s' "$siblings" | tr '\n' ' ')
    fi
    ticket_write "$MY_TICKET" || die "cannot record child for ticket $n"
    lock_release
    export FM_TEST_QUEUE_HELD=$MY_TICKET
    if [ -n "$REMOTE_HOST" ]; then
      remote_exec "$@"
      exit $?
    fi
    command_exec "$@"
  )
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
