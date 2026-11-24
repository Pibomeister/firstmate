#!/bin/bash
set -u
export FM_TEST_SKIP_ORPHAN_REAP=1
: "${EVIDENCE:?}"
. ./tests/lib.sh
pass() {
  printf 'ok - %s\n' "$1"
  python3 "$EVIDENCE/capture-publication.py" "$TMP_ROOT" "$EVIDENCE/publication"
}
. ./tests/fm-watchdog-publication.test.sh
