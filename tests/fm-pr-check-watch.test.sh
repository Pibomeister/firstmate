#!/usr/bin/env bash
# Exercise the public named-check watch against a disposable GitHub fixture.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-pr-check-watch-tests)
export FM_HOME="$TMP_ROOT/home"
export FM_STATE_OVERRIDE="$FM_HOME/state"
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
mkdir -p "$FM_STATE_OVERRIDE" "$TMP_ROOT/bin"
fm_test_track_procevent_home "$FM_HOME"

export FM_TEST_PR_HEAD_FILE="$TMP_ROOT/head"
export FM_TEST_CHECKS_FILE="$TMP_ROOT/checks.json"
export FM_TEST_GH_LOG="$TMP_ROOT/gh.log"
printf '%s\n' 0123456789abcdef0123456789abcdef01234567 > "$FM_TEST_PR_HEAD_FILE"
printf '%s\n' '{"total_count":1,"check_runs":[{"name":"Build","status":"completed","conclusion":"success","app":{"id":42}}]}' > "$FM_TEST_CHECKS_FILE"
cat > "$TMP_ROOT/bin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "$*" in
  *'/repos/acme/widget/pulls/7'*)
    body=$(printf '{"state":"open","head":{"sha":"%s"}}\n' "$(cat "$FM_TEST_PR_HEAD_FILE")")
    ;;
  *'/repos/acme/widget/commits/'*'/check-runs'*)
    body=$(cat "$FM_TEST_CHECKS_FILE")
    ;;
  *)
    printf 'unexpected fixture request: %s\n' "$*" >&2
    exit 1
    ;;
esac
if [ "${4:-}" = --jq ]; then
  printf '%s\n' "$body" | jq -r "$5"
else
  printf 'rendered gh-axi API response, not JSON\n'
fi
SH
chmod +x "$TMP_ROOT/bin/gh-axi"
export PATH="$TMP_ROOT/bin:$PATH"

WATCH="$ROOT/bin/fm-pr-check-watch.sh"
help=$("$WATCH" --help 2>&1) || fail 'the public watch command must describe its usage'
assert_contains "$help" 'arm <task>' 'help names the registration selector'
assert_contains "$help" '--producer-app <id>' 'help names the required producer input'
assert_contains "$help" 'status|retire|rearm' 'help names the watch lifecycle selectors'
task_meta() {
  printf 'kind=ship\nmode=direct-PR\npr=%s\n' "${2:-https://github.com/acme/widget/pull/7}" > "$FM_STATE_OVERRIDE/$1.meta"
  chmod 0600 "$FM_STATE_OVERRIDE/$1.meta"
}
if "$WATCH" arm missing-task https://github.com/acme/widget/pull/7 Build --producer-app 42 >"$TMP_ROOT/missing-task.out" 2>&1; then
  fail 'a syntactically valid but nonexistent task must not own a check watch'
fi
task_meta wrong-pr https://github.com/acme/widget/pull/8
if "$WATCH" arm wrong-pr https://github.com/acme/widget/pull/7 Build --producer-app 42 >"$TMP_ROOT/wrong-pr.out" 2>&1; then
  fail 'a task PR binding must agree with the arm request'
fi
task_meta check-task
if ! out=$("$WATCH" arm check-task https://github.com/acme/widget/pull/7 Build --producer-app 42 2>"$TMP_ROOT/arm.err"); then
  fail "a valid named check must arm: $(cat "$TMP_ROOT/arm.err")"
fi
assert_contains "$out" 'state=live' 'arm reports a live watch'
ref=$(printf '%s\n' "$out" | sed -n 's/^watch_ref=//p')
[ -n "$ref" ] || fail 'arm must print the generation-specific watch reference'
status=$("$WATCH" status "$ref") || fail 'status must read the armed watch'
assert_contains "$status" 'head=0123456789abcdef0123456789abcdef01234567' 'status binds the PR head'
assert_contains "$status" 'producer=app:42' 'status binds the producer'
assert_contains "$status" 'task=check-task' 'status binds the task'
assert_contains "$status" 'pr=https://github.com/acme/widget/pull/7' 'status binds the canonical PR'
assert_contains "$status" 'check=Build' 'status binds the check name'
if "$WATCH" status when-prcheck-000000000000-000000000000 >"$TMP_ROOT/absent.out" 2>&1; then
  fail 'an absent reference must not report a live watch'
fi
assert_contains "$(cat "$TMP_ROOT/absent.out")" 'state=absent' 'absent status is explicit'
for invalid in 'bad/task' '../task'; do
  if "$WATCH" arm "$invalid" https://github.com/acme/widget/pull/7 Build --producer-app 42 >/dev/null 2>&1; then
    fail 'invalid task id must be refused'
  fi
done
if "$WATCH" arm invalid-app https://github.com/acme/widget/pull/7 Build --producer-app wrong >/dev/null 2>&1; then
  fail 'invalid producer App ID must be refused'
fi
if "$WATCH" arm check-task https://github.com/acme/widget/pull/7 Build --producer-app 42 >"$TMP_ROOT/duplicate.out" 2>&1; then
  fail 'duplicate arm must refuse without creating another source'
fi
assert_contains "$(cat "$TMP_ROOT/duplicate.out")" "$ref" 'duplicate refusal names the existing generation'
if "$WATCH" arm check-task https://github.com/acme/widget/pull/8 Build --producer-app 42 >"$TMP_ROOT/other-pr.out" 2>&1; then
  fail 'a task must not silently bind the same check to another PR while its watch is live'
fi
assert_contains "$(cat "$TMP_ROOT/other-pr.out")" 'bound to another PR' 'other-PR arm refuses the task binding'
pass 'arm binds head and producer and refuses a duplicate'

record="$FM_STATE_OVERRIDE/pr-check-watch/$ref.json"
original_hash=$(shasum -a 256 "$record" | awk '{print $1}')
"$WATCH" condition "$ref" "$original_hash" >"$TMP_ROOT/green.out" || fail 'bound success must satisfy the condition'
green=$("$WATCH" action "$ref" "$original_hash") || fail 'bound success must produce a green receipt'
assert_contains "$green" 'observed_at=' 'green action records observation time'
assert_contains "$green" 'head=0123456789abcdef0123456789abcdef01234567' 'green receipt retains the bound head SHA'
observed_at=$(printf '%s\n' "$green" | sed -n 's/^observed_at=//p')
[[ "$observed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  || fail "green receipt must use an ISO 8601 UTC timestamp, got $observed_at"
assert_contains "$green" 'producer=app:42' 'green action retains the bound producer'
printf '%s\n' '{"total_count":1,"check_runs":[{"name":"Build","status":"in_progress","conclusion":null,"app":{"id":42}}]}' > "$FM_TEST_CHECKS_FILE"
"$WATCH" condition "$ref" "$original_hash" >"$TMP_ROOT/pending.out"; rc=$?
[ "$rc" -eq 1 ] || fail "pending check should be false, got exit $rc"
if "$WATCH" action "$ref" "$original_hash" >"$TMP_ROOT/stale.out" 2>&1; then
  fail 'an action must not reuse an earlier green observation on the same head'
fi
printf '%s\n' '{"total_count":1,"check_runs":[{"name":"Build","status":"completed","conclusion":"failure","app":{"id":42}}]}' > "$FM_TEST_CHECKS_FILE"
"$WATCH" condition "$ref" "$original_hash" >"$TMP_ROOT/failed.out"; rc=$?
[ "$rc" -eq 2 ] || fail "failed check should terminate actionably, got exit $rc"
assert_contains "$(cat "$TMP_ROOT/failed.out")" failed 'failure is named'
printf '%s\n' '{"total_count":1,"check_runs":[{"name":"Build","status":"completed","conclusion":"success","app":{"id":99}}]}' > "$FM_TEST_CHECKS_FILE"
"$WATCH" condition "$ref" "$original_hash" >"$TMP_ROOT/producer.out"; rc=$?
[ "$rc" -eq 2 ] || fail "wrong producer should terminate actionably, got exit $rc"
assert_contains "$(cat "$TMP_ROOT/producer.out")" producer-mismatch 'wrong producer is named'
printf '%s\n' '{"total_count":0,"check_runs":[]}' > "$FM_TEST_CHECKS_FILE"
"$WATCH" condition "$ref" "$original_hash" >"$TMP_ROOT/missing.out"; rc=$?
[ "$rc" -eq 1 ] || fail "missing check should remain false until deadline, got exit $rc"
printf '%s\n' '{"total_count":2,"check_runs":[{"id":11,"name":"Build","status":"completed","conclusion":"success","app":{"id":42},"check_suite":{"id":1}},{"id":12,"name":"Build","status":"completed","conclusion":"success","app":{"id":42},"check_suite":{"id":2}}]}' > "$FM_TEST_CHECKS_FILE"
"$WATCH" condition "$ref" "$original_hash" >"$TMP_ROOT/ambiguous.out"; rc=$?
[ "$rc" -eq 2 ] || fail "duplicate producer runs should be ambiguous, got exit $rc"
assert_contains "$(cat "$TMP_ROOT/ambiguous.out")" ambiguous 'duplicate runs are named'
printf '%s\n' '{"total_count":2,"check_runs":[{"id":12,"name":"Build","status":"in_progress","conclusion":null,"app":{"id":42},"check_suite":{"id":1}},{"id":11,"name":"Build","status":"completed","conclusion":"failure","app":{"id":42},"check_suite":{"id":1}}]}' > "$FM_TEST_CHECKS_FILE"
"$WATCH" condition "$ref" "$original_hash" >"$TMP_ROOT/rerun-pending.out"; rc=$?
[ "$rc" -eq 1 ] || fail "a pending re-run of a failed attempt should wait, got exit $rc"
printf '%s\n' '{"total_count":3,"check_runs":[{"id":12,"name":"Build","status":"completed","conclusion":"success","app":{"id":42},"check_suite":{"id":1}},{"id":11,"name":"Build","status":"completed","conclusion":"failure","app":{"id":42},"check_suite":{"id":1}},{"id":13,"name":"Build","status":"completed","conclusion":"success","app":{"id":99},"check_suite":{"id":5}}]}' > "$FM_TEST_CHECKS_FILE"
"$WATCH" condition "$ref" "$original_hash" >"$TMP_ROOT/rerun-green.out" || fail 'the green newest re-run attempt should satisfy the condition'
"$WATCH" action "$ref" "$original_hash" >"$TMP_ROOT/rerun-action.out" || fail 'the action boundary should accept the green newest re-run attempt'
printf '%s\n' '{"total_count":2,"check_runs":[{"id":11,"name":"Build","status":"completed","conclusion":"success","app":{"id":42},"check_suite":{"id":1}},{"id":12,"name":"Build","status":"completed","conclusion":"failure","app":{"id":42},"check_suite":{"id":1}}]}' > "$FM_TEST_CHECKS_FILE"
"$WATCH" condition "$ref" "$original_hash" >"$TMP_ROOT/rerun-failed.out"; rc=$?
[ "$rc" -eq 2 ] || fail "a failed newest attempt must not be masked by an older green one, got exit $rc"
assert_contains "$(cat "$TMP_ROOT/rerun-failed.out")" failed 'the newest attempt decides the verdict'
printf '%s\n' '{"total_count":101,"check_runs":[{"name":"Build","status":"completed","conclusion":"success","app":{"id":42}}]}' > "$FM_TEST_CHECKS_FILE"
"$WATCH" condition "$ref" "$original_hash" >"$TMP_ROOT/incomplete.out"; rc=$?
[ "$rc" -eq 2 ] || fail "incomplete check-run pagination should not be green, got exit $rc"
assert_contains "$(cat "$TMP_ROOT/incomplete.out")" incomplete 'incomplete pagination is named'
printf '%s\n' '{"total_count":1,"check_runs":[{"name":"Build","status":"completed","conclusion":"success","app":{"id":42}}]}' > "$FM_TEST_CHECKS_FILE"
printf '%s\n' fedcba9876543210fedcba9876543210fedcba98 > "$FM_TEST_PR_HEAD_FILE"
"$WATCH" condition "$ref" "$original_hash" >"$TMP_ROOT/moved.out"; rc=$?
[ "$rc" -eq 2 ] || fail "head movement should terminate actionably, got exit $rc"
assert_contains "$(cat "$TMP_ROOT/moved.out")" head-moved 'head movement is named'
printf '%s\n' 0123456789abcdef0123456789abcdef01234567 > "$FM_TEST_PR_HEAD_FILE"
pass 'condition and action reject non-green, wrong-producer, and moved-head observations'

mkdir -p "$FM_STATE_OVERRIDE/procevent-inbox"
rm -f "$FM_STATE_OVERRIDE/procevent/$ref.source"
printf '%s\n' 'captured fixture result' > "$FM_STATE_OVERRIDE/procevent-inbox/$ref.1.result"
status=$("$WATCH" status "$ref") || fail 'status must expose a captured result'
assert_contains "$status" 'state=result-unhandled' 'a pending captured result covers the watch'
: > "$FM_STATE_OVERRIDE/procevent-inbox/$ref.1.handled"
status=$("$WATCH" status "$ref") || fail 'status must expose a handled result'
assert_contains "$status" 'state=ended' 'a handled result no longer covers a pause'
pass 'status distinguishes an unhandled result from a handled result'

jq '.check = "Other"' "$record" > "$TMP_ROOT/tampered.json"
chmod 0600 "$TMP_ROOT/tampered.json"
mv "$TMP_ROOT/tampered.json" "$record"
"$WATCH" condition "$ref" "$original_hash" >"$TMP_ROOT/tamper.out" 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "a changed watch record must end the condition actionably, got exit $rc"
assert_contains "$(cat "$TMP_ROOT/tamper.out")" 'watch record changed' 'identity mutation is detected before a forge read'
"$WATCH" condition when-prcheck-000000000000-000000000000 "$original_hash" >"$TMP_ROOT/absent-cond.out" 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "an absent watch record must end the condition actionably, got exit $rc"
"$WATCH" condition "$ref" >"$TMP_ROOT/argc-cond.out" 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "a malformed condition invocation must end the condition actionably, got exit $rc"
pass 'condition refuses changed bound identity'

export FM_PR_CHECK_WATCH_INTERVAL=0.1
task_meta runtime-task
runtime=$("$WATCH" arm runtime-task https://github.com/acme/widget/pull/7 Build --producer-app 42) \
  || fail 'runtime watch must arm'
runtime_ref=$(printf '%s\n' "$runtime" | sed -n 's/^watch_ref=//p')
"$ROOT/bin/fm-procevent.sh" reconcile >/dev/null || fail 'the generic runner must start the registered watch'
result=
for _ in $(seq 1 150); do
  for candidate in "$FM_STATE_OVERRIDE/procevent-inbox/$runtime_ref".*.result; do
    [ -f "$candidate" ] && result=$candidate
  done
  [ -z "$result" ] || break
  sleep 0.1
done
[ -n "$result" ] || fail 'the registered watch must capture a terminal result'
assert_contains "$("$ROOT/bin/fm-procevent-when.sh" classify "$result")" fired 'the generic runner captures the green result'
status=$("$WATCH" status "$runtime_ref") || fail 'status reads the captured result'
assert_contains "$status" 'state=result-unhandled' 'captured result covers the pause before acknowledgement'
seq=${result%.*}; seq=${seq##*.}
assert_contains "$status" "result_source=$runtime_ref" 'status prints the source needed for acknowledgement'
assert_contains "$status" "result_sequence=$seq" 'status prints the sequence needed for acknowledgement'
if "$WATCH" rearm "$runtime_ref" >"$TMP_ROOT/rearm-before-handled.out" 2>&1; then
  fail 're-arm must preserve an unhandled result'
fi
if "$WATCH" retire "$runtime_ref" >"$TMP_ROOT/retire-before-handled.out" 2>&1; then
  fail 'retire must preserve an unhandled result'
fi
for _ in $(seq 1 50); do
  [ -f "$FM_STATE_OVERRIDE/.wake-queue" ] && break
  sleep 0.1
done
[ -f "$FM_STATE_OVERRIDE/.wake-queue" ] || fail 'the generic runner must publish the captured result to the wake queue'
before=$(grep -c "procevent when $runtime_ref" "$FM_STATE_OVERRIDE/.wake-queue" || true)
check_reads_before=$(grep -c '/check-runs' "$FM_TEST_GH_LOG" || true)
"$ROOT/bin/fm-procevent.sh" reconcile >/dev/null || fail 'reconcile must retain the captured result'
after=$(grep -c "procevent when $runtime_ref" "$FM_STATE_OVERRIDE/.wake-queue" || true)
check_reads_after=$(grep -c '/check-runs' "$FM_TEST_GH_LOG" || true)
[ "$after" -gt "$before" ] || fail "an unhandled result must be re-announced by the existing runner (before=$before after=$after)"
[ "$check_reads_after" -eq "$check_reads_before" ] || fail 're-announcement must not rerun the check action or condition'
results=$(find "$FM_STATE_OVERRIDE/procevent-inbox" -maxdepth 1 -name "$runtime_ref.*.result" | wc -l | tr -d ' ')
[ "$results" -eq 1 ] || fail "one source generation must have one terminal result, got $results"
"$ROOT/bin/fm-procevent.sh" handled "$runtime_ref" "$seq" >/dev/null || fail 'the result can be acknowledged'
status=$("$WATCH" status "$runtime_ref") || fail 'status reads the handled result'
assert_contains "$status" 'state=ended' 'acknowledged result ends pause coverage'
assert_contains "$status" "result_source=$runtime_ref" 'handled result retains its captured source identity'
assert_contains "$status" "result_sequence=$seq" 'handled result retains its captured sequence identity'
ln -s "$ROOT/bin" "$TMP_ROOT/bin dir"
new=$("$TMP_ROOT/bin dir/fm-pr-check-watch.sh" rearm "$runtime_ref") || fail 'handled result can be explicitly re-armed'
new_ref=$(printf '%s\n' "$new" | sed -n 's/^watch_ref=//p')
[ "$new_ref" != "$runtime_ref" ] || fail 're-arm must allocate a new generation'
: > "$FM_STATE_OVERRIDE/procevent/.$new_ref.launch-failed"
status=$("$WATCH" status "$new_ref") || fail 'status must show an unhealthy registered source'
assert_contains "$status" 'state=unhealthy' 'runner launch failure does not count as a healthy watch'
if "$WATCH" arm runtime-task https://github.com/acme/widget/pull/7 Build --producer-app 42 >"$TMP_ROOT/unhealthy-duplicate.out" 2>&1; then
  fail 'an unhealthy registered generation must still prevent a duplicate arm'
fi
assert_contains "$(cat "$TMP_ROOT/unhealthy-duplicate.out")" "$new_ref" 'unhealthy duplicate refusal identifies the existing generation'
rm -f "$FM_STATE_OVERRIDE/procevent/.$new_ref.launch-failed"
"$WATCH" retire "$new_ref" >/dev/null || fail 'an active watch can be retired explicitly'
absent=$("$WATCH" retire "$new_ref") || fail 'retire is idempotent after cleanup'
assert_contains "$absent" 'state=absent' 'retire reports an absent watch without creating state'
orphan=$("$WATCH" arm runtime-task https://github.com/acme/widget/pull/7 Build --producer-app 42) \
  || fail 'orphan watch must arm'
orphan_ref=$(printf '%s\n' "$orphan" | sed -n 's/^watch_ref=//p')
[ -e "$FM_STATE_OVERRIDE/procevent/$orphan_ref.source" ] || fail 'armed watch must register its source'
rm -f "$FM_HOME/state/pr-check-watch/$orphan_ref.json" "$FM_STATE_OVERRIDE/pr-check-watch/$orphan_ref.json"
"$WATCH" retire "$orphan_ref" >/dev/null || fail 'retire of an absent record must succeed'
[ ! -e "$FM_STATE_OVERRIDE/procevent/$orphan_ref.source" ] || fail 'retire of an absent record must still retire its source'
pass 'real runner captures, acknowledges, and re-arms a bound check watch'

printf '%s\n' '{"total_count":1,"check_runs":[{"name":"Build","status":"in_progress","conclusion":null,"app":{"id":42}}]}' > "$FM_TEST_CHECKS_FILE"
export FM_PR_CHECK_WATCH_DEADLINE=2
task_meta deadline-task
deadline=$("$WATCH" arm deadline-task https://github.com/acme/widget/pull/7 Build --producer-app 42) \
  || fail 'deadline watch must arm'
deadline_ref=$(printf '%s\n' "$deadline" | sed -n 's/^watch_ref=//p')
"$ROOT/bin/fm-procevent.sh" reconcile >/dev/null || fail 'deadline watch must start'
deadline_result=
for _ in $(seq 1 150); do
  for candidate in "$FM_STATE_OVERRIDE/procevent-inbox/$deadline_ref".*.result; do
    [ -f "$candidate" ] && deadline_result=$candidate
  done
  [ -z "$deadline_result" ] || break
  sleep 0.1
done
[ -n "$deadline_result" ] || fail 'pending check must reach its bounded deadline'
assert_contains "$("$ROOT/bin/fm-procevent-when.sh" classify "$deadline_result")" never-true 'deadline is actionable without a green claim'
pass 'pending check reaches an explicit bounded deadline'

unset FM_PR_CHECK_WATCH_DEADLINE
printf '%s\n' '{malformed' > "$FM_TEST_CHECKS_FILE"
task_meta error-task
error_watch=$("$WATCH" arm error-task https://github.com/acme/widget/pull/7 Build --producer-app 42) \
  || fail 'an unreadable check watch must still arm for bounded error delivery'
error_ref=$(printf '%s\n' "$error_watch" | sed -n 's/^watch_ref=//p')
"$ROOT/bin/fm-procevent.sh" reconcile >/dev/null || fail 'error watch must start'
error_result=
for _ in $(seq 1 150); do
  for candidate in "$FM_STATE_OVERRIDE/procevent-inbox/$error_ref".*.result; do
    [ -f "$candidate" ] && error_result=$candidate
  done
  [ -z "$error_result" ] || break
  sleep 0.1
done
[ -n "$error_result" ] || fail 'malformed forge data must yield a bounded terminal result'
assert_contains "$("$ROOT/bin/fm-procevent-when.sh" classify "$error_result")" condition-error 'forge parse error is actionable without a green claim'
assert_grep 'forge-error' "$error_result" 'captured result names the forge read failure'
pass 'forge error terminates through the registered runner'
