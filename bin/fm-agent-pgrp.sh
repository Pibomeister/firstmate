#!/usr/bin/env bash
# Run a worker agent in a process group of its own that owns the terminal.
#
#   fm-agent-pgrp.sh <command> [args...]
#
# bin/fm-spawn.sh puts this in front of every templated harness command, so
# each crewmate, scout, and secondmate agent it launches runs isolated from the
# process group of whatever started it. A cleanup trap or test-runner teardown
# that signals an inherited group (`kill 0`, `kill -TERM -<pgid>`) from the
# launching pane shell's side - for example from a pane whose shell runs
# without job control, where every command it starts shares one group - then
# reaches only that group and never the agent.
#
# The agent deliberately stays in the pane's session and becomes the
# terminal's foreground process group, rather than moving into a session of
# its own with setsid: every pane backend's liveness classifier reads the pane
# terminal's foreground process group, interrupts and exit commands arrive as
# keystrokes on that terminal, and a TUI needs it as its controlling terminal
# for /dev/tty and SIGWINCH. A new session would lose all of that. So the
# deliberate control paths are unchanged: bin/fm-control.sh's keystrokes,
# terminal-generated signals, and an endpoint close (SIGHUP to the foreground
# group) still reach the agent, and so does a signal addressed to the agent's
# own pid or group.
#
# What it cannot isolate: a descendant the agent itself starts inherits the
# agent's group unless the harness gives it its own, so a tool command's
# `kill 0` still reaches the agent on a harness that does not isolate its tool
# commands. bin/fm-test-run.sh contains each test script in its own group for
# that reason.
#
# Mechanics: a perl parent forks; the child calls setpgid(0, 0), takes the
# terminal with tcsetpgrp when the parent's group held it, restores the signal
# dispositions it inherited, and execs <command> through PATH, so the agent
# keeps its own process name with no shell layer in between. The parent ignores
# HUP, INT, QUIT, TERM and the job-control stop signals, so a stray group
# signal cannot kill it and orphan the agent, and never forwards any signal.
# It leaves the agent's working directory, waits for the agent, hands the
# terminal back to its own group if the agent's group still holds it, and
# exits with the agent's status, using 128+N for death by signal N as a shell
# reports it. It exits 127 when <command> cannot be executed and refuses to run
# without perl rather than launching the agent unisolated.
set -u

[ "$#" -ge 1 ] || {
  echo 'usage: fm-agent-pgrp.sh <command> [args...]' >&2
  exit 2
}
command -v perl >/dev/null 2>&1 || {
  echo 'error: fm-agent-pgrp.sh needs perl to start the agent in its own process group; refusing to launch it unisolated' >&2
  exit 127
}

# shellcheck disable=SC2016 # the program is perl, not shell
exec perl -MPOSIX=setpgid,tcgetpgrp,tcsetpgrp -e '
  my @signals = qw(HUP INT QUIT TERM TSTP TTIN TTOU);
  my %inherited = map { ($_ => (defined $SIG{$_} && $SIG{$_} eq "IGNORE") ? "IGNORE" : "DEFAULT") } @signals;
  $SIG{$_} = "IGNORE" for @signals;
  my $own = getpgrp();
  my $tty;
  for my $fd (0, 1, 2) {
    next unless -t $fd;
    my $fg = tcgetpgrp($fd);
    if (defined $fg && $fg == $own) { $tty = $fd; last }
  }
  my $child = fork;
  if (!defined $child) {
    print STDERR "error: fm-agent-pgrp.sh could not fork the agent: $!\n";
    exit 127;
  }
  if ($child == 0) {
    setpgid(0, 0);
    tcsetpgrp($tty, $$) if defined $tty;
    $SIG{$_} = $inherited{$_} for @signals;
    exec { $ARGV[0] } @ARGV;
    print STDERR "error: fm-agent-pgrp.sh could not run $ARGV[0]: $!\n";
    POSIX::_exit(127);
  }
  setpgid($child, $child);
  chdir "/";
  my $done;
  do { $done = waitpid($child, 0) } while ($done == -1 && $!{EINTR});
  my $status = $?;
  if (defined $tty) {
    my $fg = tcgetpgrp($tty);
    tcsetpgrp($tty, $own) if defined $fg && $fg == $child;
  }
  exit 127 if $done != $child;
  exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
' -- "$@"
