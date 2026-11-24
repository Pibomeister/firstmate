#!/bin/bash
set -u
export FM_TEST_SKIP_ORPHAN_REAP=1
. ./tests/lib.sh
fm_test_run() { :; }
. ./tests/fm-watchdog-publication.test.sh
WD="$PWD/.test-validation/baseline-bin/fm-watchdog.sh"
"$1"
