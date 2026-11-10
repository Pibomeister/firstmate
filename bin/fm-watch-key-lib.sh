#!/usr/bin/env bash
# Shared watcher marker identity. Source this library, then call window_key
# with one backend endpoint to obtain its filename suffix.
#
# The derivation is the fork's long-standing one, owned by
# bin/fm-classify-lib.sh (which defines the same function for its own
# consumers): `:` `/` `.` fold to `_`. Live homes hold markers on disk under
# this format, so it does not change here. The donor's SHA-256 `v3.` key
# format (with its documented one-time marker reset in
# docs/configuration.md) is deferred to the part of the upstream sync that
# brings that note; until then this body must stay byte-identical in effect
# to fm-classify-lib.sh's window_key.
window_key() {  # <window>
  local key=${1//:/_}
  key=${key//\//_}
  printf '%s' "${key//./_}"
}
