#!/usr/bin/env bash
# Print one complete Herdr session inventory for <session> without starting it.
# bin/fm-lifecycle-retire-lib.sh owns when this is proof. The argv is exactly
# `herdr session list --json --session <session>`. A caller replaces this
# command with FM_LIFECYCLE_INVENTORY_COMMAND; the replacement is executed as
# one program plus the session name, never through a shell.
set -eu
if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: fm-lifecycle-herdr-inventory.sh <session>" >&2
  exit 2
fi
exec herdr session list --json --session "$1"
