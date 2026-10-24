#!/usr/bin/env bash
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LAB="$ROOT/.nm-muse-lab"
export FM_HOME="$LAB/home"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE
{
  echo 'Real Muse shell tool: harness detection and lock acquisition'
  "$ROOT/bin/fm-harness.sh"
  "$ROOT/bin/fm-lock.sh"
  "$ROOT/bin/fm-lock.sh" status
  printf 'Recorded lock PID: '; head -1 "$FM_HOME/state/.lock"
  holder=$(head -1 "$FM_HOME/state/.lock")
  ps -p "$holder" -o pid=,ppid=,comm=
  . "$ROOT/bin/fm-session-lock-lib.sh"
  fm_session_lock_owned_by_self "$FM_HOME/state"
  echo 'Ownership verified inside the real tool shell'
  for decoy in amuse musescore; do
    ln -s /bin/sleep "$LAB/bin/$decoy"
    "$LAB/bin/$decoy" 45 &
    decoy_pid=$!
    ps -p "$decoy_pid" -o pid=,comm=
    if fm_harness_pid_alive "$decoy_pid"; then
      kill "$decoy_pid"; echo "ERROR accepted $decoy"; exit 1
    fi
    echo "Rejected live lookalike: $decoy"
    kill "$decoy_pid"
    wait "$decoy_pid" 2>/dev/null || true
  done
  echo LOCK_PROBE_OK
} > "$LAB/lock-proof.txt" 2>&1
cat "$LAB/lock-proof.txt"
