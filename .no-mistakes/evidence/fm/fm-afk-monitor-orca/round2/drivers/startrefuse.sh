#!/usr/bin/env bash
# Runs inside a real Orca terminal: the `start` route for a non-native harness.
L=$1; E=$2; cd "$3" || exit 1
{
  env | grep -E '^(TERM_PROGRAM|ORCA_TERMINAL_HANDLE)='
  env -u NO_MISTAKES_GATE FM_HOME="$L" FM_HARNESS=codex bin/fm-afk-launch.sh enter --words lab >/dev/null 2>&1; echo "enter rc=$?"
  env -u NO_MISTAKES_GATE FM_HOME="$L" FM_HARNESS=codex bin/fm-afk-launch.sh start 2>&1 | cut -c1-220; echo "start rc=${PIPESTATUS[0]}"
  grep -c firstmate:0 "$L/state/.supervise-daemon.log" 2>/dev/null | sed 's/^/firstmate:0-mentions=/'
  ls "$L/state/.supervise-daemon.pid" 2>&1 | cut -c1-120
  echo FIN
} > "$E/09-start-refusal-on-orca.txt" 2>&1
exit
