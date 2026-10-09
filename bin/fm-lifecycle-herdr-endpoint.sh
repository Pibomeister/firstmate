#!/usr/bin/env bash
# Endpoint-absent probe only. bin/fm-lifecycle-retire-lib.sh never calls this
# for session-absent proof.
set -eu
if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
  echo "usage: fm-lifecycle-herdr-endpoint.sh <session> <pane-id>" >&2
  exit 2
fi
exec /Users/eduardopicazo/Documents/Workspace/firstmate/bin/fm-herdr-lab.sh run "$1" pane get "$2"
