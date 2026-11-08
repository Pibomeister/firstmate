#!/usr/bin/env bash
# Thin test wrapper over bin/fm-herdr-owned-xdg.sh.
# The production helper owns create/start/check/stop/cleanup. This file
# exists so live Herdr tests source one path rather than inlining lifecycle.
set -u

HERDR_OWNED_XDG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$HERDR_OWNED_XDG_DIR/bin/fm-herdr-owned-xdg.sh"
