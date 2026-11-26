#!/usr/bin/env bash
# fm-timeout-lib.sh - the single owner of bounded command execution.
#
# Sourced, never executed. Provides one hard-bound runner so no caller has to
# re-derive the coreutils/BSD/perl selection, and so every bounded call in this
# repo agrees on what "the bound was hit" means.
#
#   fm_timeout_mechanism
#       Prints the mechanism fm_run_timed will use on this host: "timeout",
#       "gtimeout", "perl", or "bash". Set FM_TIMEOUT_MECHANISM_OVERRIDE=bash
#       to force the dependency-free fallback. An omp shell defines timeout as
#       a builtin; command -v reports that builtin, and invoking the name runs
#       it. timeout and gtimeout are selected only when type -P yields an
#       executable path, and that path is what fm_run_timed and fm_exec_timed
#       invoke, so a builtin or function of the same name cannot shadow the
#       runner. The perl and bash fallbacks are unchanged.
#
#   fm_run_timed <seconds> <command> [args...]
#       Runs the command with a hard bound, preserving the caller's stdin. Exit
#       status is the command's own,
#       except 124, which means the bound was hit (GNU timeout's convention,
#       reproduced by the perl and bash fallbacks), and a command killed by
#       signal n, which reports 128+n on every mechanism - so a SIGKILLed child
#       is 137 and a SIGTERMed one 143, never the 0 a caller would read as
#       success. A signal-death status the wrapper records while the runner
#       already reports the bound is the bound's own TERM, not the command's
#       exit, and is reported as 124 too. Only 137 raised by GNU/BSD timeout's
#       own KILL escalation, with no status recorded by the bounded command,
#       also collapses into 124: there it means the bound fired, not that the
#       command chose to die. The perl and bash mechanisms TERM the bounded
#       group at the bound and KILL it 1 s later. A perl runner that is itself
#       sent TERM, INT or HUP (an outer bound stopping it) TERMs its bounded
#       group, KILLs it 0.5 s later and exits, so a bound nested inside another
#       never strands its command; GNU/BSD timeout places its command in a group
#       of its own that an outer group signal does not reach, so there the
#       inner deadline still applies.
#
#   fm_run_timed_fn <seconds> <function-or-command> [args...]
#       fm_run_timed for a shell function too: the call runs in a subshell in
#       its own process group under the bash mechanism, with the same status
#       contract (124 when the bound fired). Variables the call sets do not
#       reach the caller.
#
#   fm_run_cancellable_fn <function-or-command> [args...]
#       fm_run_timed_fn with no deadline: the call runs in a subshell in its
#       own process group until it returns, with its own status. A trap in the
#       calling shell stops and reaps it through fm_cancel_bash_timeout, and
#       the group also ends within about two seconds of the calling shell's
#       death.
#
#   fm_exec_timed <seconds> <grace-seconds> <command> [args...]
#       Replaces the calling shell with the bounded command, so it must be the
#       last command of a subshell: the bound kills the command, not the
#       caller. The command runs in its own process group; TERM goes to that
#       group at the bound, and KILL once <grace-seconds> more have passed,
#       for a command that ignores TERM or is mid-way through work it will not
#       abandon. A TERM, INT, or HUP delivered to the bounding process is
#       forwarded to the group and starts the same grace. The perl watchdog
#       also starts that escalation when its own parent dies before it could
#       be signalled (an owner torn down by an outer group-kill cannot leave
#       the bounded subtree orphaned behind it). The owner is captured before
#       the watchdog starts: FM_EXEC_TIMED_OWNER_PID when the caller names it,
#       else the calling script ($$) when fm_exec_timed runs in a subshell,
#       else the shell's parent. The escalation starts once that owner is gone
#       or the watchdog's parent changes, so an owner that dies while the
#       watchdog is still starting is detected too. The timeout/gtimeout
#       fallback does not track the owner: it bounds the command only by its
#       deadline and grace, so owner death alone does not stop the command.
#       Exit status is the command's own, except 124 (the bound was hit) or
#       137 (GNU timeout's status when its KILL had to fire); fm_timed_out
#       accepts both. The seconds and grace values must be positive integers
#       (125 otherwise). The perl watchdog is
#       preferred: once termination has begun it also KILLs whatever the group
#       left behind, so a descendant that outlives the command and holds its
#       output cannot keep a capturing caller waiting, and GNU timeout, the
#       fallback, cannot be followed by that reap from a replaced shell. A
#       descendant that moves into a process group of its own is outside both
#       signals and the reap (the Claude and Pi CLIs do this for every tool
#       command they run), so it ends only through the command's own TERM
#       handling; that is what the grace is for, and a command KILLed after
#       the grace can leave such a descendant running. With
#       no perl, timeout, or gtimeout on the host it refuses with 127 rather
#       than run unbounded: there is no bash fallback, because a monitor-mode
#       watchdog cannot replace the caller.
#
#   fm_timed_out <status>
#       0 iff <status> is how fm_run_timed or fm_exec_timed reports the bound.
#
# Callers must supply a positive integer bound; `timeout 0` disables the deadline.
#
# All four fm_run_timed mechanisms terminate the whole process GROUP, not just
# the direct child, so a hung grandchild (a vendor CLI spawned by a wrapper
# script, a git fetch spawned by a sweep) cannot outlive the bound. GNU/BSD
# `timeout` does this by default because it does not run the command in the
# foreground process group; the perl fallback does it explicitly with setpgid
# plus a negative pid, and the bash fallback uses monitor mode to give the
# bounded child its own process group before signaling its negative pid.
# shellcheck source=bin/fm-bash-compat-lib.sh
. "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; CDPATH='' cd -- "${d:-/}" && pwd)/fm-bash-compat-lib.sh"
set -u

# Print the PATH path of timeout, else gtimeout, when that path is executable.
fm_external_timeout_path() {
  local name timeout_path
  for name in timeout gtimeout; do
    timeout_path=$(type -P "$name" 2>/dev/null) || true
    if [ -n "$timeout_path" ] && [ -x "$timeout_path" ]; then
      printf '%s\n' "$timeout_path"
      return 0
    fi
  done
  return 1
}

fm_timeout_mechanism() {
  local timeout_path
  if [ "${FM_TIMEOUT_MECHANISM_OVERRIDE:-}" = bash ]; then
    printf 'bash\n'
  elif timeout_path=$(fm_external_timeout_path); then
    printf '%s\n' "${timeout_path##*/}"
  elif command -v perl >/dev/null 2>&1; then
    printf 'perl\n'
  else
    printf 'bash\n'
  fi
}

# True when stdin is a pipe or file. A terminal is not a redirected payload,
# and a closed stdin cannot be duplicated.
fm_timeout_stdin_is_redirected() {
  [ ! -t 0 ] && ( exec 3<&0 ) 2>/dev/null
}

# Background "$@" and keep a redirected stdin. A non-interactive bash assigns
# /dev/null to an async command's stdin, then applies explicit redirections, so
# 0<&3 restores the dup. The group redirection is undone when the group ends,
# and 3<&- keeps the spare fd out of the child. A terminal or closed stdin gets
# an explicit /dev/null: under set -m (the bash mechanism) bash skips its
# implicit one, which would hand the terminal to a background process group.
fm_timeout_background() {
  if fm_timeout_stdin_is_redirected; then
    { "$@" 0<&3 3<&- & } 3<&0
  else
    "$@" </dev/null &
  fi
}

fm_bash_timeout_child() {
  local status_file=$1 command_rc
  shift
  set +m
  "$@"
  command_rc=$?
  printf '%s\n' "$command_rc" > "$status_file"
  exit "$command_rc"
}

# Read $! without tripping set -u before the shell has started any job.
_fm_bash_timeout_last_job() {  # sets _FM_BASH_TIMEOUT_LAST_JOB
  local nounset=0
  case $- in *u*) nounset=1; set +u ;; esac
  _FM_BASH_TIMEOUT_LAST_JOB=$!
  [ "$nounset" -eq 0 ] || set -u
}

# Signal a bounded job's process group, or the job itself when job control
# could not give it a group of its own.
_fm_bash_timeout_signal() {  # <signal> <pid>
  [ -n "${2:-}" ] || return 0
  kill "-$1" -- "-$2" 2>/dev/null || kill "-$1" "$2" 2>/dev/null || true
}

# Stop the active fm_run_bash_timeout call from a trap in the calling shell.
# The pid variables are that call's dynamically scoped locals. A job launched
# but not yet recorded is recovered from $!, and a reaped job is never
# signalled because each pid is cleared as soon as it is reaped.
fm_cancel_bash_timeout() {
  case "${_FM_BASH_TIMEOUT_LAUNCHING:-}" in
    child|watchdog)
      _fm_bash_timeout_last_job
      if [ -n "$_FM_BASH_TIMEOUT_LAST_JOB" ] \
        && [ "$_FM_BASH_TIMEOUT_LAST_JOB" != "${_FM_BASH_TIMEOUT_PREVIOUS_JOB:-}" ]; then
        if [ "$_FM_BASH_TIMEOUT_LAUNCHING" = child ]; then
          _FM_BASH_TIMEOUT_CHILD_PID=$_FM_BASH_TIMEOUT_LAST_JOB
        else
          _FM_BASH_TIMEOUT_WATCHDOG_PID=$_FM_BASH_TIMEOUT_LAST_JOB
        fi
      fi
      ;;
  esac
  _FM_BASH_TIMEOUT_LAUNCHING=
  _fm_bash_timeout_signal TERM "${_FM_BASH_TIMEOUT_WATCHDOG_PID:-}"
  if [ -n "${_FM_BASH_TIMEOUT_CHILD_PID:-}" ]; then
    _fm_bash_timeout_signal TERM "$_FM_BASH_TIMEOUT_CHILD_PID"
    command -p sleep 1
    _fm_bash_timeout_signal KILL "$_FM_BASH_TIMEOUT_CHILD_PID"
    wait "$_FM_BASH_TIMEOUT_CHILD_PID" 2>/dev/null || true
    _FM_BASH_TIMEOUT_CHILD_PID=
  fi
  if [ -n "${_FM_BASH_TIMEOUT_WATCHDOG_PID:-}" ]; then
    _fm_bash_timeout_signal KILL "$_FM_BASH_TIMEOUT_WATCHDOG_PID"
    wait "$_FM_BASH_TIMEOUT_WATCHDOG_PID" 2>/dev/null || true
    _FM_BASH_TIMEOUT_WATCHDOG_PID=
  fi
  [ -z "${_FM_BASH_TIMEOUT_STATUS_FILE:-}" ] \
    || command -p rm -f "$_FM_BASH_TIMEOUT_STATUS_FILE" "${_FM_BASH_TIMEOUT_DEADLINE_FILE:-}" 2>/dev/null || true
}

fm_run_bash_timeout() {
  local seconds=$1 _FM_BASH_TIMEOUT_STATUS_FILE='' _FM_BASH_TIMEOUT_DEADLINE_FILE=''
  local _FM_BASH_TIMEOUT_CHILD_PID='' _FM_BASH_TIMEOUT_WATCHDOG_PID='' command_rc recorded_rc monitor_was_on=0 caller
  local _FM_BASH_TIMEOUT_LAUNCHING='' _FM_BASH_TIMEOUT_PREVIOUS_JOB='' _FM_BASH_TIMEOUT_LAST_JOB=''
  shift
  # Its helper tools come from the default PATH (an absolute sh, command -p
  # otherwise), so a caller with a trimmed PATH still gets a real bound rather
  # than an immediate 124.
  caller=$(exec /bin/sh -c 'echo "$PPID"')
  _FM_BASH_TIMEOUT_STATUS_FILE=$(command -p mktemp "${TMPDIR:-/tmp}/fm-bash-timeout-command.XXXXXX" 2>/dev/null) || return 124
  _FM_BASH_TIMEOUT_DEADLINE_FILE="${_FM_BASH_TIMEOUT_STATUS_FILE}.deadline"
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m
  _fm_bash_timeout_last_job
  _FM_BASH_TIMEOUT_PREVIOUS_JOB=$_FM_BASH_TIMEOUT_LAST_JOB
  _FM_BASH_TIMEOUT_LAUNCHING=child
  fm_timeout_background fm_bash_timeout_child "$_FM_BASH_TIMEOUT_STATUS_FILE" "$@"
  _FM_BASH_TIMEOUT_CHILD_PID=$!
  _FM_BASH_TIMEOUT_PREVIOUS_JOB=$_FM_BASH_TIMEOUT_CHILD_PID
  _FM_BASH_TIMEOUT_LAUNCHING=watchdog
  # The watchdog's sleeps come from the default PATH (command -p): a bound is
  # wall-clock time even where a caller's PATH puts a stub or wrapper first.
  # Its own group outlives a caller stopped from outside, so it also ends the
  # command within a second of that caller's exit.
  (
    set +m
    case "$seconds" in
      none) while kill -0 "$caller" 2>/dev/null; do command -p sleep 1; done ;;
      *[!0-9]*) command -p sleep "$seconds" ;;
      *)
        i=0
        while [ "$i" -lt "$seconds" ] && kill -0 "$caller" 2>/dev/null; do
          command -p sleep 1
          i=$((i + 1))
        done ;;
    esac
    printf 'expired\n' > "$_FM_BASH_TIMEOUT_DEADLINE_FILE"
    kill -TERM -- "-$_FM_BASH_TIMEOUT_CHILD_PID" 2>/dev/null || true
    command -p sleep 1
    kill -KILL -- "-$_FM_BASH_TIMEOUT_CHILD_PID" 2>/dev/null || true
    exit 124
  ) &
  _FM_BASH_TIMEOUT_WATCHDOG_PID=$!
  _FM_BASH_TIMEOUT_LAUNCHING=
  [ "$monitor_was_on" -eq 1 ] || set +m

  if wait "$_FM_BASH_TIMEOUT_CHILD_PID" 2>/dev/null; then
    command_rc=0
  else
    command_rc=$?
  fi
  if [ -s "$_FM_BASH_TIMEOUT_DEADLINE_FILE" ]; then
    # The watchdog still owns the KILL escalation for the child's group.
    wait "$_FM_BASH_TIMEOUT_WATCHDOG_PID" 2>/dev/null || true
    _FM_BASH_TIMEOUT_WATCHDOG_PID=
    _FM_BASH_TIMEOUT_CHILD_PID=
    command_rc=124
  else
    _FM_BASH_TIMEOUT_CHILD_PID=
    # The command is reaped and the watchdog holds no state, so KILL ends it:
    # a TERM ignored since this shell started would leave the wait below
    # hanging until the bound, or forever with no deadline.
    _fm_bash_timeout_signal KILL "$_FM_BASH_TIMEOUT_WATCHDOG_PID"
    wait "$_FM_BASH_TIMEOUT_WATCHDOG_PID" 2>/dev/null || true
    _FM_BASH_TIMEOUT_WATCHDOG_PID=
    recorded_rc=$(command -p cat "$_FM_BASH_TIMEOUT_STATUS_FILE" 2>/dev/null || true)
    case "$recorded_rc" in ''|*[!0-9]*) ;; *) command_rc=$recorded_rc ;; esac
  fi
  command -p rm -f "$_FM_BASH_TIMEOUT_STATUS_FILE" "$_FM_BASH_TIMEOUT_DEADLINE_FILE" 2>/dev/null || true
  return "$command_rc"
}

# Only signals the caller left at their default disposition carry a forwarding
# trap, so restoring resets exactly those and is a no-op once already done.
_fm_external_timeout_restore_traps() {
  local signal
  for signal in ${_FM_EXTERNAL_TIMEOUT_SIGNALS:-}; do
    trap - "$signal"
  done
  _FM_EXTERNAL_TIMEOUT_SIGNALS=
  _FM_EXTERNAL_TIMEOUT_PID=
  _FM_EXTERNAL_TIMEOUT_STATUS=
}

# shellcheck disable=SC2317,SC2329 # Invoked by the traps fm_run_external_timeout installs.
_fm_external_timeout_forward() {  # <signal>
  local signal=$1 pid=${_FM_EXTERNAL_TIMEOUT_PID:-} self
  if [ -n "$pid" ]; then
    kill "-$signal" -- "-$pid" 2>/dev/null || kill "-$signal" "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    kill -KILL -- "-$pid" 2>/dev/null || true
  fi
  [ -z "${_FM_EXTERNAL_TIMEOUT_STATUS:-}" ] || rm -f "$_FM_EXTERNAL_TIMEOUT_STATUS" 2>/dev/null || true
  _fm_external_timeout_restore_traps
  self=$(exec /bin/sh -c 'echo "$PPID"')
  kill "-$signal" "$self"
}

fm_run_external_timeout() {
  local runner=$1 seconds=$2 status_file runner_pid runner_rc command_rc signal
  shift 2
  status_file=$(mktemp "${TMPDIR:-/tmp}/fm-timeout-status.XXXXXX" 2>/dev/null) || return 124
  # Run the executable path asynchronously (never a bare name: that is the omp
  # timeout builtin, and backgrounding it leaves $! empty) so its pid - also
  # the process-group id created by GNU/BSD timeout without --foreground -
  # remains available for cleanup. fm_timeout_background keeps a redirected
  # stdin across that async assignment.
  # A shell wrapper can exit promptly on TERM while one of its descendants
  # ignores TERM; timeout then considers the command finished and does not send
  # its configured KILL. Explicitly reap that leftover group on a real timeout.
  # shellcheck disable=SC2016  # Expansion is deliberately deferred to the child shell.
  fm_timeout_background "$runner" -k 1 "$seconds" bash -c '
    status_file=$1
    shift
    "$@"
    command_rc=$?
    printf "%s\n" "$command_rc" > "$status_file"
    exit "$command_rc"
  ' _ "$status_file" "$@"
  runner_pid=$!
  # Like the perl path, a TERM, INT or HUP that would end the caller first
  # stops the runner's group and is then re-raised, so no command outlives it.
  # A signal the caller already traps or ignores is the caller's deliberate
  # choice: its trap stays in place, the command keeps running to its own
  # bound, and the wait resumes after that trap returns.
  _FM_EXTERNAL_TIMEOUT_SIGNALS=
  _FM_EXTERNAL_TIMEOUT_PID=$runner_pid
  _FM_EXTERNAL_TIMEOUT_STATUS=$status_file
  for signal in INT TERM HUP; do
    [ -z "$(trap -p "$signal")" ] || continue
    _FM_EXTERNAL_TIMEOUT_SIGNALS="$_FM_EXTERNAL_TIMEOUT_SIGNALS $signal"
    # shellcheck disable=SC2064  # The signal name is fixed when the trap is set.
    trap "_fm_external_timeout_forward $signal" "$signal"
  done
  while :; do
    if wait "$runner_pid"; then
      runner_rc=0
    else
      runner_rc=$?
    fi
    if [ "$runner_rc" -le 128 ] || ! kill -0 "$runner_pid" 2>/dev/null; then
      break
    fi
  done
  _fm_external_timeout_restore_traps
  command_rc=$(cat "$status_file" 2>/dev/null || true)
  rm -f "$status_file" 2>/dev/null || true
  case "$command_rc" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$command_rc" -le 255 ]; then
        case "$runner_rc" in
          124) [ "$command_rc" -lt 128 ] && return "$command_rc" ;;
          *) return "$command_rc" ;;
        esac
      fi
      ;;
  esac
  case "$runner_rc" in
    124|137)
      kill -KILL -- "-$runner_pid" 2>/dev/null || true
      return 124
      ;;
    *) return "$runner_rc" ;;
  esac
}

fm_run_timed() {  # <seconds> <command...>
  local seconds=$1 timeout_path
  shift
  case "$(fm_timeout_mechanism)" in
    timeout|gtimeout)
      timeout_path=$(fm_external_timeout_path) || return 127
      fm_run_external_timeout "$timeout_path" "$seconds" "$@"
      ;;
    perl)
      local saved_traps='' caller_trap signal runner_pid='' interrupted='' runner_rc monitor_was_on=0
      # Bash 4.3+ drops inherited inactive trap strings on any trap change.
      # Older Bash retains them across a reset, so save only strings it clears.
      trap - KILL
      for signal in INT HUP TERM; do
        caller_trap=$(trap -p "$signal")
        trap - "$signal"
        if [ "$caller_trap" != "$(trap -p "$signal")" ]; then
          saved_traps="$saved_traps
$caller_trap"
        fi
      done
      # wait on an asynchronous runner so Bash handles a process-directed signal
      # immediately instead of deferring the trap until a foreground Perl exits.
      trap 'interrupted=INT; [ -z "$runner_pid" ] || kill -INT "$runner_pid" 2>/dev/null || true' INT
      trap 'interrupted=HUP; [ -z "$runner_pid" ] || kill -HUP "$runner_pid" 2>/dev/null || true' HUP
      trap 'interrupted=TERM; [ -z "$runner_pid" ] || kill -TERM "$runner_pid" 2>/dev/null || true' TERM
      case $- in *m*) monitor_was_on=1 ;; esac
      set -m
      perl -MPOSIX=WNOHANG,setpgid -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e '
        my $bound = shift;
        my ($signal, $kill_at, $result) = (0, 0, 0);
        for my $entry ([HUP => 1], [INT => 2], [TERM => 15]) {
          my ($name, $number) = @$entry;
          $SIG{$name} = sub { $signal ||= $number };
        }
        my $pid = fork;
        exit 127 unless defined $pid;
        if (!$pid) {
          $SIG{$_} = "DEFAULT" for qw(INT HUP TERM);
          setpgid(0, 0);
          exec @ARGV;
          exit 127;
        }
        # Both sides establish the group before the parent can signal it.
        setpgid($pid, $pid);
        my $deadline = clock_gettime(CLOCK_MONOTONIC) + $bound;
        while (1) {
          if (!$kill_at && ($signal || clock_gettime(CLOCK_MONOTONIC) >= $deadline)) {
            $result = $signal ? 128 + $signal : 124;
            $kill_at = clock_gettime(CLOCK_MONOTONIC) + 0.2;
            kill "TERM", -$pid;
          }
          my $done = waitpid $pid, WNOHANG;
          if ($done == $pid) {
            my $status = $?;
            kill "KILL", -$pid if $kill_at;
            exit($kill_at ? $result : ($status & 127) ? 128 + ($status & 127) : $status >> 8);
          }
          exit 127 if $done == -1;
          if ($kill_at && clock_gettime(CLOCK_MONOTONIC) >= $kill_at) {
            kill "KILL", -$pid;
            waitpid $pid, 0;
            exit $result;
          }
          select undef, undef, undef, 0.02;
        }
      ' -- "$seconds" "$@" <&0 &
      runner_pid=$!
      [ "$monitor_was_on" -eq 1 ] || set +m
      [ -z "$interrupted" ] || kill -"$interrupted" "$runner_pid" 2>/dev/null || true
      while :; do
        if wait "$runner_pid"; then runner_rc=0; else runner_rc=$?; fi
        # A trap interrupts wait before the runner has finished its cleanup.
        kill -0 "$runner_pid" 2>/dev/null || break
      done
      trap - INT HUP TERM
      eval "$saved_traps"
      [ -z "$interrupted" ] || kill -s "$interrupted" "$(exec perl -e 'print getppid()')"
      case "$interrupted" in
        INT) return 130 ;;
        HUP) return 129 ;;
        TERM) return 143 ;;
      esac
      return "$runner_rc"
      ;;
    bash) fm_run_bash_timeout "$seconds" "$@" ;;
    *) return 124 ;;
  esac
}

fm_run_timed_fn() {  # <seconds> <function-or-command> [args...]
  fm_run_bash_timeout "$@"
}

fm_run_cancellable_fn() {  # <function-or-command> [args...]
  fm_run_bash_timeout none "$@"
}

fm_timed_out() {  # <status>
  case ${1:-} in
    124 | 137) return 0 ;;
  esac
  return 1
}

# The perl watchdog forks the command into its own process group (both sides
# call setpgid, so the group exists before either can signal it) and polls
# waitpid(WNOHANG) against wall-clock deadlines rather than using alarm+die,
# which keeps the bound off perl's platform-dependent syscall-restart signal
# semantics and off the drift of counting sleep intervals.
fm_exec_timed() {  # <seconds> <grace-seconds> <command...>
  local seconds=${1:-} grace=${2:-} value owner timeout_path
  for value in "$seconds" "$grace"; do
    case "$value" in
      '' | 0* | *[!0-9]*)
        echo "fm_exec_timed: usage: fm_exec_timed <positive-seconds> <positive-grace-seconds> <command> [args...]" >&2
        exit 125
        ;;
    esac
  done
  shift 2
  if [ "$#" -eq 0 ]; then
    echo "fm_exec_timed: usage: fm_exec_timed <positive-seconds> <positive-grace-seconds> <command> [args...]" >&2
    exit 125
  fi
  owner=${FM_EXEC_TIMED_OWNER_PID:-$$}
  unset FM_EXEC_TIMED_OWNER_PID
  if command -v perl >/dev/null 2>&1; then
    exec perl -MPOSIX=WNOHANG,setpgid -MTime::HiRes=time -e '
      my ($bound, $grace, $owner, $shell_parent) = (shift, shift, shift, shift);
      # exec preserves the shell PID, including in Bash 3.2 subshells where
      # BASHPID is unavailable. Keep the pre-exec parent for startup races.
      $owner = $shell_parent if $owner == $$;
      my $parent = getppid();
      my ($pid, $pending, $kill_at, $timed_out) = (0, "", 0, 0);
      for my $sig (qw(TERM INT HUP)) {
        $SIG{$sig} = sub {
          if ($pid) { kill $sig, -$pid } else { $pending = $sig }
          $kill_at ||= time + $grace;
        };
      }
      my $child = fork;
      exit 127 unless defined $child;
      if ($child == 0) {
        $SIG{$_} = "DEFAULT" for qw(TERM INT HUP);
        setpgid(0, 0);
        exec @ARGV;
        exit 127;
      }
      setpgid($child, $child);
      $pid = $child;
      kill $pending, -$pid if $pending;
      my $deadline = time + $bound;
      sub finish {
        my $status = shift;
        kill "KILL", -$pid if $kill_at;
        exit 124 if $timed_out;
        exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
      }
      while (1) {
        my $done = waitpid $pid, WNOHANG;
        finish($?) if $done == $pid;
        exit 127 if $done == -1;
        if ($kill_at) {
          if (time >= $kill_at) {
            kill "KILL", -$pid;
            waitpid $pid, 0;
            finish($?);
          }
        } elsif (time >= $deadline) {
          $timed_out = 1;
          $kill_at = time + $grace;
          kill "TERM", -$pid;
        } elsif (getppid() != $parent || !kill(0, $owner)) {
          $kill_at = time + $grace;
          kill "TERM", -$pid;
        }
        select undef, undef, undef, 0.05;
      }
    ' -- "$seconds" "$grace" "$owner" "$PPID" "$@"
  elif timeout_path=$(fm_external_timeout_path); then
    exec "$timeout_path" -k "$grace" "$seconds" "$@"
  fi
  printf 'fm_exec_timed: cannot bound %s within %ss: none of perl, timeout, or gtimeout is available\n' "${1##*/}" "$seconds" >&2
  exit 127
}
