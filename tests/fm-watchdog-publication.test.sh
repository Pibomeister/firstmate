#!/usr/bin/env bash
# Public watchdog publication during a finite sweep and failed replacement.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-watchdog-publication)
WD="$ROOT/bin/fm-watchdog.sh"
REAL_DATE=$(command -v date)
REAL_MV=$(command -v mv)
BASE=1700000000
BLOCKED_PID=
cleanup_publication_cases() {
  if [ -n "$BLOCKED_PID" ]; then
    : >"$H/release"
    wait "$BLOCKED_PID" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup_publication_cases EXIT

make_publication_case() {
  H="$TMP_ROOT/$1"
  mkdir -p "$H/state" "$H/data" "$H/config" "$H/user" "$H/tmp" "$H/bin"
  printf '%s\n' "$BASE" >"$H/clock"
  : >"$H/targets"
  : >"$H/reads.jsonl"
  : >"$H/outward.log"
  printf 'mode=dry-run\nrestart=off\nmodels=\ncouncil-seats=\nquota-guard=off\nmemory-guard=off\npermission-route=off\ninterval-secs=120\n' >"$H/config/watchdog"
  printf '1700000000\t1\tcheck\tretain\tunhandled fixture wake\n' >"$H/state/.wake-queue"
  printf 'needs-decision [key=held]: preserve this decision\n' >"$H/state/keeper.status"
  printf 'kind=secondmate\n' >"$H/state/keeper.meta"
  cp "$H/state/.wake-queue" "$H/queue.before"
  cp "$H/state/keeper.status" "$H/status.before"
  cat >"$H/bin/date" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "$1" = +%s ]; then
  IFS= read -r now <"$WD_CLOCK"
  printf '%s\n' "$now"
else
  exec "$WD_REAL_DATE" "$@"
fi
SH
  cat >"$H/bin/mv" <<'SH'
#!/usr/bin/env bash
for argument in "$@"; do target=$argument; done
if [ "$target" = "$FM_HOME/data/watchdog/status.md" ]; then
  phase=complete
  if grep -q 'scan incomplete' "$1"; then phase=progress; fi
  if [ "$WD_FAIL_STATUS" = 1 ] || { [ "$WD_FAIL_STATUS" = progress ] && [ "$phase" = progress ]; }; then
    printf '%s refused\n' "$phase" >>"$FM_HOME/replacements.log"
    printf 'fixture status replacement refused\n' >&2
    exit 73
  fi
  "$WD_REAL_MV" "$@" || exit "$?"
  printf '%s replaced\n' "$phase" >>"$FM_HOME/replacements.log"
  exit 0
fi
exec "$WD_REAL_MV" "$@"
SH
  cat >"$H/bin/orca" <<'PY'
#!/usr/bin/env python3
import datetime
import json
import os
from pathlib import Path
import re
import sys
import time
h = Path(os.environ['FM_HOME'])
args = sys.argv[1:]
if args[:2] == ['terminal', 'list']:
    targets = (h / 'targets').read_text().splitlines()
    print(json.dumps({'ok': True, 'result': {'terminals': [{'id': x} for x in targets], 'truncated': False}}))
elif args[:2] == ['terminal', 'read']:
    target = args[args.index('--terminal') + 1]
    if os.environ['WD_TEST_BLOCK_READ'] == '1':
        (h / 'blocked').write_text('reader entered\n')
        for _ in range(100):
            if (h / 'release').exists():
                break
            time.sleep(.05)
        else:
            sys.exit(70)
    now = int((h / 'clock').read_text()) + int(os.environ['WD_READ_COST'])
    (h / 'clock').write_text(str(now) + '\n')
    published = (h / 'data/watchdog/status.md').read_text()
    expiry = re.search(r'STALE IF NOT UPDATED BY (\S+)', published).group(1)
    expires = int(datetime.datetime.fromisoformat(expiry.replace('Z', '+00:00')).timestamp())
    with (h / 'reads.jsonl').open('a') as log:
        log.write(json.dumps({'target': target, 'now': now, 'expires': expires, 'expired': now > expires,
                              'incomplete': 'scan incomplete' in published, 'publication': published}) + '\n')
    print(json.dumps({'ok': True, 'result': {'terminal': {'tail': 'fixture idle\n> '}}}))
else:
    with (h / 'outward.log').open('a') as log:
        log.write('orca ' + ' '.join(args) + '\n')
    sys.exit(1)
PY
  for tool in claude agy no-mistakes quota-axi launchctl tmux herdr gh gh-axi osascript terminal-notifier curl say mail sendmail; do
    cat >"$H/bin/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$0" "$*" >>"$FM_HOME/outward.log"
exit 1
SH
  done
  chmod +x "$H/bin/"*
}

publication_once() {
  local cost=$1 fail_write=${2:-0} filter=${3:-}
  set -- once --dry-run
  [ -z "$filter" ] || set -- "$@" --home "$filter"
  env -i HOME="$H/user" PATH="$H/bin:$PATH" TMPDIR="$H/tmp" LC_ALL=C \
    FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_SEAM=1 FM_ORCA_CLI_CACHE=1 FM_ORCA_CLI_CACHE_TTL=0 \
    FM_ORCA_CLI_CACHE_DIR="$H/cache" WD_CLOCK="$H/clock" WD_READ_COST="$cost" \
    WD_TEST_BLOCK_READ="${WD_TEST_BLOCK_READ:-0}" \
    WD_REAL_DATE="$REAL_DATE" WD_REAL_MV="$REAL_MV" WD_FAIL_STATUS="$fail_write" \
    /bin/bash "$WD" "$@" >"$H/once.out" 2>"$H/once.err"
}

seed_workers() {
  local count=$1 i=1 target
  while [ "$i" -le "$count" ]; do
    target="term-fixture-$i"
    printf '%s\n' "$target" >>"$H/targets"
    printf 'kind=ship\nbackend=orca\nwindow=%s\nharness=codex\n' "$target" >"$H/state/worker-$i.meta"
    i=$((i + 1))
  done
}

assert_records_retained() {
  cmp "$H/queue.before" "$H/state/.wake-queue" || fail 'publication consumed a wake'
  cmp "$H/status.before" "$H/state/keeper.status" || fail 'publication changed a held decision'
  if grep -E '(^orca terminal (send|create|close|focus)|/(claude|agy|herdr|gh|gh-axi|osascript|terminal-notifier|curl|say|mail|sendmail)( |$))' "$H/outward.log"; then
    fail 'a publication fixture attempted an outward or model action'
  fi
}

test_publication_fast_control() {
  make_publication_case control
  publication_once 0 || fail 'baseline control publication failed'
  printf '%s\n' "$((BASE + 120))" >"$H/clock"
  seed_workers 1
  publication_once 14 || fail 'fast control sweep failed'
  if ! python3 - "$H" <<'PY'
import json, sys
from pathlib import Path
h = Path(sys.argv[1]); rows = [json.loads(x) for x in (h/'reads.jsonl').read_text().splitlines()]
assert rows and all(not x['expired'] for x in rows), rows
print(json.dumps({'case': 'control', 'reads': len(rows), 'expired_reads': 0}))
PY
  then
    fail 'control was not a genuine nonexpired read'
  fi
  assert_records_retained
  pass 'fast complete watchdog publication remains valid'
}

test_completed_reads_keep_publication_honest() {
  make_publication_case cumulative
  publication_once 0 || fail 'initial complete publication failed'
  cp "$H/data/watchdog/status.md" "$H/complete.before"
  printf '%s\n' "$((BASE + 120))" >"$H/clock"
  seed_workers 21
  publication_once 14 || fail 'finite cumulative sweep failed'
  if ! python3 - "$H" <<'PY'
import json, sys
from pathlib import Path
h = Path(sys.argv[1]); rows = [json.loads(x) for x in (h/'reads.jsonl').read_text().splitlines()]
expired = sum(x['expired'] for x in rows); progress = [x for x in rows if x['incomplete']]
print(json.dumps({'case': 'cumulative', 'reads': len(rows), 'expired_reads': expired,
                  'progress_observed': bool(progress), 'distinct_targets': len({x['target'] for x in rows})}))
assert len({x['target'] for x in rows}) == 21, 'fixture did not read every distinct target'
assert len(rows) * 14 > 540, 'fixture never crossed the remaining published budget'
assert expired == 0, 'completed reads continued past the actual published expiry'
assert progress, 'no honest incomplete progress publication was observed'
for item in progress:
    assert 'last complete' in item['publication'], 'old coverage was relabelled complete'
    prior = (h/'complete.before').read_text().splitlines()
    observed = item['publication'].splitlines()
    assert observed[0] == prior[0] and observed[3:] == prior[3:], 'prior complete observations/gaps changed'
done = set(); previous = None; previous_count = 0
for item in rows:
    if previous is not None and previous != item['target']:
        done.add(previous)
    if item['incomplete']:
        import re
        count = int(re.search(r'completed worker checks (\d+)', item['publication']).group(1))
        assert previous_count <= count <= len(done), 'progress claimed unfinished checks'
        previous_count = count
    previous = item['target']
assert 'scan incomplete' not in (h/'data/watchdog/status.md').read_text(), 'finite scan never completed'
PY
  then
    fail 'cumulative completed reads starved publication or hid incomplete coverage'
  fi
  assert_records_retained
  pass 'completed bounded reads publish honest progress and eventually finish all workers'
}

test_blocked_reader_does_not_publish_timer_progress() {
  local ticks=0
  make_publication_case blocked
  publication_once 0 || fail 'blocked-reader baseline failed'
  cp "$H/data/watchdog/status.md" "$H/status.good"
  printf '%s\n' "$((BASE + 120))" >"$H/clock"
  seed_workers 1
  WD_TEST_BLOCK_READ=1 publication_once 14 &
  BLOCKED_PID=$!
  while [ ! -s "$H/blocked" ] && [ "$ticks" -lt 100 ]; do sleep 0.1; ticks=$((ticks + 1)); done
  [ -s "$H/blocked" ] || fail 'controlled reader never entered'
  printf '%s\n' "$((BASE + 800))" >"$H/clock"
  sleep 0.2
  cmp "$H/status.good" "$H/data/watchdog/status.md" || fail 'unfinished reader generated timer-only progress'
  : >"$H/release"
  wait "$BLOCKED_PID" || fail 'released reader failed'
  BLOCKED_PID=
  assert_records_retained
  pass 'a blocked reader cannot advance publication from a timer alone'
}

test_status_write_failure_is_reported() {
  local rc=0
  make_publication_case write-failure
  publication_once 0 || fail 'initial write control failed'
  cp "$H/data/watchdog/status.md" "$H/status.good"
  printf '%s\n' "$((BASE + 120))" >"$H/clock"
  publication_once 0 1 || rc=$?
  cmp "$H/status.good" "$H/data/watchdog/status.md" || fail 'failed replacement destroyed last good publication'
  assert_records_retained
  printf 'write-failure public_exit=%s last_good_preserved=true\n' "$rc"
  [ "$rc" -ne 0 ] || fail 'public once swallowed the status replacement failure'
  pass 'failed status replacement preserves prior bytes and returns failure'
}

test_filtered_progress_failure_is_reported() {
  local count rc skipped
  for count in 1 2; do
    make_publication_case "filtered-progress-failure-$count"
    publication_once 0 || fail 'filtered progress baseline failed'
    skipped="$H/skipped"
    mkdir -p "$skipped/state"
    printf 'homes=%s,%s\n' "$H" "$skipped" >>"$H/config/watchdog"
    printf '%s\n' "$((BASE + 120))" >"$H/clock"
    seed_workers "$count"
    : >"$H/replacements.log"
    rc=0
    publication_once 120 progress "$H" || rc=$?
    assert_grep 'progress publication failed' "$H/once.err" 'progress failure was not exercised'
    assert_equals "$count" "$(grep -c '^progress refused$' "$H/replacements.log")" 'worker completion did not attempt progress publication'
    assert_equals 'complete replaced' "$(tail -n 1 "$H/replacements.log")" 'final publication did not succeed'
    assert_no_grep 'scan incomplete' "$H/data/watchdog/status.md" 'final publication remained incomplete'
    assert_absent "$skipped/state/monitor-status" 'filtered scan visited the excluded home'
    assert_records_retained
    printf 'filtered-progress-failure workers=%s public_exit=%s final_replaced=true\n' "$count" "$rc"
    [ "$rc" -ne 0 ] || fail 'skipped subject hid an earlier progress publication failure'
  done
  pass 'filtered scans retain progress failures after skipped subjects and final success'
}

if [ "$#" -gt 0 ]; then fm_test_run "$@"; else
  fm_test_run test_publication_fast_control test_completed_reads_keep_publication_honest test_blocked_reader_does_not_publish_timer_progress test_status_write_failure_is_reported test_filtered_progress_failure_is_reported
fi
