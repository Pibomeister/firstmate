#!/usr/bin/env bash
# Print one complete Herdr session inventory for <session> without starting it.
# bin/fm-lifecycle-retire-lib.sh owns when this is proof.
set -eu
if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: fm-lifecycle-herdr-inventory.sh <session>" >&2
  exit 2
fi
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
exec "$SCRIPT_DIR/fm-herdr-lab.sh" run "$1" session list --json
