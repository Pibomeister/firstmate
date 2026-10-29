#!/usr/bin/env bash
# Run one bounded foreground watcher checkpoint for harnesses that should not
# rely on background-task completion to wake the model.
#
# SUPERVISION HOST. A home opted in with config/supervision-host
# (docs/configuration.md "Supervision host" owns the gate;
# config/supervision-host-off opts out, and a Codex home without the file does not run the host) runs
# bin/fm-supervision-host.sh in the watcher's place for the checkpoint's bound,
# as the host's park boundary; the host takes away-posture wakes itself and
# returns only when main is needed (its header owns the output read here).
# While an away record state/.afk-contract exists (never quiet mode's, whose
# captain is present: bin/fm-afk-contract.sh mode), the bound is
# raised to FM_CODEX_WATCH_CHECKPOINT_AWAY (default 3600) when that is longer,
# so a parked main is not woken every few minutes; an engine turn that starts
# before the bound may finish after it. A close that carries a wake or a
# "supervision-host:" line other than the park boundary passes through as a
# wake; the boundary alone is the ordinary quiet checkpoint. On a home that
# does not run the host nothing below changes.
#
# SECONDMATE HOME. In a genuine local secondmate home the bound, on either
# path, is capped at FM_SECONDMATE_CHECKPOINT_MAX (default 60) and the away
# raise never lifts it above that, so the secondmate's turn returns to its
# parent-owned steering inbox regularly; on the host path that bound is also
# the host's turn limit, so an away close whose engine turn could outlast it
# is handed to the secondmate rather than run. A primary's bound is unchanged. On the
# plain path only (the inbox is passed to that watcher alone, never exported to
# the host's), the watcher also ends the checkpoint within a few seconds of a
# record in that inbox it has not yet announced, and this script prints
# "checkpoint: firstmate instruction waiting in the steering inbox: <names>".
# Each record is announced once, so one the model cannot acknowledge yet
# never turns checkpoints into a tight loop; when the announce-once record
# cannot be written the wait stays an ordinary bounded one. The inbox path
# comes from the home's own marker and parent record (fm_secondmate_home_inbox).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SECONDS_ARG=${FM_CODEX_WATCH_CHECKPOINT:-180}

usage() {
  cat <<'EOF'
Usage: fm-watch-checkpoint.sh [--seconds <n>]

Run bin/fm-watch.sh in the foreground for a bounded checkpoint.
On an actionable watcher wake, pass through the watcher output and exit 0.
On a quiet checkpoint, print "checkpoint: no actionable wake within <n>s" and exit 0,
so a harness never presents an ordinary quiet bound as a failed command.
A nonzero exit always means the checkpoint itself failed.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --seconds)
      [ "$#" -gt 1 ] || { echo "error: --seconds requires a value" >&2; exit 2; }
      SECONDS_ARG=$2
      shift 2
      ;;
    --seconds=*)
      SECONDS_ARG=${1#--seconds=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$SECONDS_ARG" in
  ''|*[!0-9]*) echo "error: --seconds must be a positive integer" >&2; exit 2 ;;
  0) echo "error: --seconds must be greater than zero" >&2; exit 2 ;;
esac

# A checkpoint is neither an ordinary watcher start nor an Option B handling
# successor. It keeps an announced recovery episode stable while preserving the
# watcher's ordinary recovery of a generation that becomes pending.
export FM_WATCH_FOREGROUND_CHECKPOINT=1

OUT=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.out.XXXXXX") || exit 1
ERR=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.err.XXXXXX") || {
  rm -f "$OUT"
  exit 1
}
trap 'rm -f "$OUT" "$ERR"' EXIT

run_with_perl_timeout() {  # <seconds> <signal> <kill-after-seconds> <command...>
  perl -e '
    use POSIX qw(:sys_wait_h);
    my $seconds = shift;
    my $signal = shift;
    my $kill_after = shift;
    my $pid = fork;
    die "fork failed\n" unless defined $pid;
    if (!$pid) {
      setpgrp(0, 0);
      exec @ARGV;
      die "exec failed: $!\n";
    }
    my $timed_out = 0;
    local $SIG{ALRM} = sub {
      if ($timed_out) {
        kill "KILL", -$pid;
        waitpid $pid, 0;
        exit 137;
      }
      $timed_out = 1;
      kill $signal, -$pid;
      alarm($kill_after) if $kill_after;
    };
    alarm $seconds;
    while (1) {
      my $waited = waitpid $pid, WNOHANG;
      if ($waited == $pid) {
        alarm 0;
        exit($timed_out ? 124 : ($? >> 8));
      }
      select undef, undef, undef, 0.05;
    }
  ' "$@"
}

run_bounded() {  # <seconds> <signal> <kill-after-seconds> <command...>
  local seconds=$1 signal=$2 kill_after=$3 cleanup_lock_bound
  shift 3
  if [ "$kill_after" -gt 0 ]; then
    cleanup_lock_bound=${FM_WATCHER_CLEANUP_LOCK_BOUND:-2}
    case "$cleanup_lock_bound" in
      ''|*[!0-9]*) cleanup_lock_bound=2 ;;
      *) cleanup_lock_bound=$((10#$cleanup_lock_bound)) ;;
    esac
    [ "$cleanup_lock_bound" -gt 0 ] || cleanup_lock_bound=2
    [ "$cleanup_lock_bound" -gt "$kill_after" ] || cleanup_lock_bound=$kill_after
    kill_after=$cleanup_lock_bound
  fi
  if command -v timeout >/dev/null 2>&1; then
    if [ "$kill_after" -gt 0 ]; then
      timeout --signal="$signal" --kill-after="${kill_after}s" "$seconds" "$@"
    else
      timeout --signal="$signal" "$seconds" "$@"
    fi
  elif command -v gtimeout >/dev/null 2>&1; then
    if [ "$kill_after" -gt 0 ]; then
      gtimeout --signal="$signal" --kill-after="${kill_after}s" "$seconds" "$@"
    else
      gtimeout --signal="$signal" "$seconds" "$@"
    fi
  else
    run_with_perl_timeout "$seconds" "$signal" "$kill_after" "$@"
  fi
}

positive_or() {  # <value> <default>
  case "$1" in ''|0*|*[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
SECONDMATE_MAX=
SECONDMATE_INBOX=
# Only the plain path's own watcher receives the inbox (passed inline below);
# the supervision host's watchers never see it.
unset FM_WATCH_CHECKPOINT_INBOX
if SECONDMATE_INBOX=$(fm_secondmate_home_inbox "$FM_HOME" 2>/dev/null); then
  SECONDMATE_MAX=$(positive_or "${FM_SECONDMATE_CHECKPOINT_MAX:-}" 60)
  [ "$SECONDS_ARG" -le "$SECONDMATE_MAX" ] || SECONDS_ARG=$SECONDMATE_MAX
fi

require_clean_shutdown() {
  if [ "$RC" -eq 137 ]; then
    [ ! -s "$OUT" ] || cat "$OUT"
    [ ! -s "$ERR" ] || cat "$ERR" >&2
    echo "checkpoint: forced KILL ended the checkpoint before clean shutdown" >&2
    exit "$RC"
  fi
  if grep -E '^(supervision-host: )?watcher: recovery state could not be persisted;' "$OUT" "$ERR" >/dev/null 2>&1; then
    [ ! -s "$OUT" ] || cat "$OUT"
    [ ! -s "$ERR" ] || cat "$ERR" >&2
    exit 1
  fi
}

# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$SCRIPT_DIR/fm-supervision-engine-lib.sh"
if fm_supervision_host_enabled "$CONFIG" codex; then
  BOUND=$SECONDS_ARG
  if [ -f "$STATE/.afk-contract" ] \
    && [ "$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" mode 2>/dev/null)" != quiet ]; then
    AWAY_BOUND=$(positive_or "${FM_CODEX_WATCH_CHECKPOINT_AWAY:-}" 3600)
    [ "$AWAY_BOUND" -le "$BOUND" ] 2>/dev/null || BOUND=$AWAY_BOUND
  fi
  [ -z "$SECONDMATE_MAX" ] || [ "$BOUND" -le "$SECONDMATE_MAX" ] || BOUND=$SECONDMATE_MAX
  # The host's park boundary stays below the 28800-second registration.
  [ "$BOUND" -lt 27000 ] 2>/dev/null || BOUND=27000
  LIMIT=$BOUND
  [ -n "$SECONDMATE_MAX" ] \
    || LIMIT=$(( BOUND + $(positive_or "${FM_SUPERVISION_HOST_TURN_TIMEOUT:-}" 1200) + $(positive_or "${FM_SUPERVISION_ENGINE_GRACE:-}" 30) ))
  set +e
  # The host ends its own park; the outer bound only catches a host that
  # outlived every one of its own bounds.
  FM_SUPERVISION_HOST_PRIMARY=codex FM_SUPERVISION_HOST_PARK_SECONDS=$BOUND FM_SUPERVISION_HOST_PARK_LIMIT=$LIMIT \
    run_bounded $((LIMIT + 120)) TERM 0 "$SCRIPT_DIR/fm-supervision-host.sh" park >"$OUT" 2>"$ERR"
  RC=$?
  set -e
  require_clean_shutdown
  if grep -E '^(signal:|stale:|check:|heartbeat($|:)|supervision-host:)' "$OUT" 2>/dev/null \
    | grep -Ev '^supervision-host: cycle boundary' >/dev/null; then
    grep -Ev '^watcher: (started|attached) ' "$OUT"
    [ ! -s "$ERR" ] || cat "$ERR" >&2
    exit "$RC"
  fi
  if [ "$RC" -eq 0 ] && grep -E '^supervision-host: cycle boundary' "$OUT" >/dev/null 2>&1; then
    printf 'checkpoint: no actionable wake within %ss\n' "$BOUND"
    exit 0
  fi
  [ ! -s "$OUT" ] || cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  if [ "$RC" -eq 124 ]; then
    echo "checkpoint: the supervision host outlived its own bound of ${BOUND}s" >&2
    exit 1
  fi
  [ "$RC" -ne 0 ] || RC=1
  exit "$RC"
fi

set +e
# Interrupt the checkpoint's active check group so the watcher's native EXIT cleanup can release its lock; ordinary watcher shutdown still uses TERM.
FM_WATCH_CHECKPOINT_INBOX=$SECONDMATE_INBOX run_bounded "$SECONDS_ARG" INT 5 "$SCRIPT_DIR/fm-watch.sh" >"$OUT" 2>"$ERR"
RC=$?
set -e
require_clean_shutdown

if grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" >/dev/null 2>&1; then
  cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  exit 0
fi

if INBOX_NAMES=$(sed -n 's/^checkpoint-inbox://p' "$OUT" 2>/dev/null) && [ -n "$INBOX_NAMES" ]; then
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  printf 'checkpoint: firstmate instruction waiting in the steering inbox:%s - read, act on and acknowledge each record now, then start the next checkpoint\n' "$INBOX_NAMES"
  exit 0
fi

if grep -E '^watcher: already running' "$OUT" "$ERR" >/dev/null 2>&1; then
  [ ! -s "$OUT" ] || cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  echo "checkpoint: watcher is already running outside this foreground checkpoint" >&2
  exit 1
fi

if [ "$RC" -eq 124 ]; then
  printf 'checkpoint: no actionable wake within %ss\n' "$SECONDS_ARG"
  exit 0
fi

[ ! -s "$OUT" ] || cat "$OUT"
[ ! -s "$ERR" ] || cat "$ERR" >&2
exit "$RC"
