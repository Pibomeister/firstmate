#!/usr/bin/env bash
# A large persistent secondmate history must not fork once per routine line.
# The oracle is the fixture's 130 distinct, unresolved keyed decisions and its
# exact queue/status bytes, not another implementation of the fold.
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-drain-latency)
fixture_home=$(make_case large-history)
printf 'kind=secondmate\n' > "$fixture_home/state/mate.meta"
awk 'BEGIN {
  for (i=1; i<=130; i++) printf "needs-decision [key=decision-%d]: retain decision %d verbatim\n", i, i
  for (i=1; i<=10000; i++) print "working: routine historical status"
}' > "$fixture_home/state/mate.status"
cp "$fixture_home/state/mate.status" "$fixture_home/status.before"
append_wake "$fixture_home/state" check retained 'unhandled wake must survive'
cp "$fixture_home/state/.wake-queue" "$fixture_home/queue.before"
rc=0
FM_HOME="$fixture_home" FM_STATE_OVERRIDE="$fixture_home/state" fm_run_timed 15 "$ROOT/bin/fm-wake-drain.sh" > "$fixture_home/drain.out" 2> "$fixture_home/drain.err" || rc=$?
[ "$rc" = 0 ] || fail "large-history drain exceeded its 15-second fixture budget or failed: $rc"
cmp "$fixture_home/queue.before" "$fixture_home/state/.wake-queue" || fail "presentation consumed or changed an unhandled wake"
cmp "$fixture_home/status.before" "$fixture_home/state/mate.status" || fail "presentation changed authoritative status bytes"
# shellcheck disable=SC2016 # Positional arguments expand in the child Bash.
FM_STATE_OVERRIDE="$fixture_home/state" fm_run_timed 5 bash -c '
  . "$1/bin/fm-classify-lib.sh"
  status_open_decisions_incremental "$2"
' _ "$ROOT" "$fixture_home/state/mate.status" > "$fixture_home/open" || fail "unchanged decision fold was slow or failed"
awk 'BEGIN { for(i=1;i<=130;i++) printf "decision-%d\tneeds-decision\tretain decision %d verbatim\n",i,i }' > "$fixture_home/expected"
# Command substitutions omit trailing newlines; normalize only that separator.
awk '1' "$fixture_home/open" > "$fixture_home/open.lines"
cmp "$fixture_home/expected" "$fixture_home/open.lines" || fail "large-history drain lost or changed an unresolved decision"
grep -F 'unhandled wake must survive' "$fixture_home/drain.out" >/dev/null || fail "unhandled wake was hidden"
grep -F 'OPEN DECISIONS' "$fixture_home/drain.out" >/dev/null || fail "open decisions were hidden"
pass "large secondmate history drains within a bounded budget and preserves every wake and decision"
