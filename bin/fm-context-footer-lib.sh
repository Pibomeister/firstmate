#!/usr/bin/env bash
# Single owner of the external auto-compact footer parse.
#
# The measurement is the harness pane text "N% until auto-compact".
# bin/fm-heartbeat.sh and bin/fm-context-burn.sh both use this function.
# A model self-estimate is never a footer. Sourced, never executed.
# The three shapes match the pane text heartbeat already accepted:
#   "... 12% until auto-compact"
#   "12% until auto-compact"
#   "... until auto-compact: 7%"

fm_context_footer_percent_from_text() {
  local raw
  raw=$(sed -n -E \
    's/.*[^0-9]([0-9]{1,3})% until auto-compact.*/\1/p; s/^([0-9]{1,3})% until auto-compact.*/\1/p; s/.*until auto-compact: ([0-9]{1,3})%.*/\1/p' \
    | tail -n 1)
  case "$raw" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ "$raw" -gt 100 ]; then
    return 1
  fi
  printf '%s\n' "$((10#$raw))"
}
