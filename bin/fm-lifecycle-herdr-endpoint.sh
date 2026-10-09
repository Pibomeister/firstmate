#!/usr/bin/env bash
# Endpoint-absent probe only. bin/fm-lifecycle-retire-lib.sh never calls this
# for session-absent proof. The argv is `herdr pane get <pane> --session <session>`.
# FM_LIFECYCLE_ENDPOINT_COMMAND replaces it as one program plus the session and
# pane id, never through a shell.
set -eu
if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
  echo "usage: fm-lifecycle-herdr-endpoint.sh <session> <pane-id>" >&2
  exit 2
fi
exec herdr pane get "$2" --session "$1"
