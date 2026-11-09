#!/usr/bin/env bash
# fm-clock-lib.sh - the shared fixed-clock seam for supervision ledgers.
#
# fm_now prints the current integer epoch. When FM_TEST_SEAM=1 and FM_NOW is a
# non-empty integer it prints FM_NOW instead, so a test can pin every ledger
# timestamp; any other FM_NOW, or FM_NOW without the seam, reads the real clock.
# Sourcing this file defines the function and has no other side effect.

fm_now() {
  if [ "${FM_TEST_SEAM:-}" = 1 ]; then
    case "${FM_NOW:-}" in
      ''|*[!0-9]*) ;;
      *) printf '%s\n' "$FM_NOW"; return 0 ;;
    esac
  fi
  date +%s
}
