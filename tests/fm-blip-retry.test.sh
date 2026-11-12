#!/usr/bin/env bash
# Behavior tests for transient Orca and SSH blip retries.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-blip-retry-lib.sh
. "$ROOT/bin/fm-blip-retry-lib.sh"

BLIP_ROOT=$(fm_test_tmproot fm-blip-retry)
mkdir -p "$BLIP_ROOT"
BLIP_COUNT="$BLIP_ROOT/count"
BLIP_OUT="$BLIP_ROOT/out"
BLIP_ERR="$BLIP_ROOT/err"
BLIP_SLEEP="$BLIP_ROOT/sleep"
BLIP_FAILS=2
BLIP_TEXT='connection refused'

blip_reset() {
  unset FM_BLIP_RETRY_BASE_SECS FM_BLIP_RETRY_CAP_SECS FM_BLIP_RETRY_BUDGET_SECS
  BLIP_FAILS=2
  BLIP_TEXT='connection refused'
  printf '0\n' > "$BLIP_COUNT"
  : > "$BLIP_OUT"
  : > "$BLIP_ERR"
  : > "$BLIP_SLEEP"
  FM_BLIP_NOW=1000
  FM_BLIP_SLEEP_LOG=$BLIP_SLEEP
}

blip_stub() {
  local n
  n=$(cat "$BLIP_COUNT")
  n=$((n + 1))
  printf '%s\n' "$n" > "$BLIP_COUNT"
  if [ "$n" -le "$BLIP_FAILS" ]; then
    printf 'leak\n'
    printf '%s\n' "$BLIP_TEXT" >&2
    return 1
  fi
  printf 'ready\n'
}

blip_run() {
  set +e
  fm_blip_retry blip_stub >"$BLIP_OUT" 2>"$BLIP_ERR"
  BLIP_RC=$?
  set -e
}

test_transient_failures_retry_until_success() {
  blip_reset
  BLIP_FAILS=2
  blip_run
  assert_equals 0 "$BLIP_RC" "a transient blip that clears was reported as a failure"
  assert_equals 3 "$(cat "$BLIP_COUNT")" "a transient blip was not retried through to success"
  assert_equals ready "$(cat "$BLIP_OUT")" "a recovered call kept an earlier attempt's stdout"
  assert_equals $'2\n4' "$(cat "$BLIP_SLEEP")" "backoff did not start at 2s and double"
  [ ! -s "$BLIP_ERR" ] || fail "a recovered call kept an earlier attempt's stderr: $(cat "$BLIP_ERR")"
  pass "a transient blip is retried until the call succeeds"
}

test_budget_reports_the_failing_attempt_once() {
  blip_reset
  BLIP_FAILS=99
  FM_BLIP_RETRY_BUDGET_SECS=10 \
    FM_BLIP_RETRY_BASE_SECS=2 \
    FM_BLIP_RETRY_CAP_SECS=32 \
    blip_run
  [ "$BLIP_RC" -ne 0 ] || fail "a blip past the retry budget was reported as success"
  assert_equals 3 "$(cat "$BLIP_COUNT")" "a blip past the retry budget kept being attempted"
  assert_equals $'2\n4\n4' "$(cat "$BLIP_SLEEP")" "the last wait was not shortened to the budget"
  assert_equals leak "$(cat "$BLIP_OUT")" "a spent budget reported more than the last attempt"
  assert_equals 'connection refused' "$(cat "$BLIP_ERR")" "a spent budget repeated the failure text"
  pass "a blip past the retry budget is reported once"
}

test_definite_failure_is_not_retried() {
  blip_reset
  BLIP_FAILS=5
  BLIP_TEXT='permission denied'
  blip_run
  [ "$BLIP_RC" -ne 0 ] || fail "permission denied was treated as success"
  assert_equals 1 "$(cat "$BLIP_COUNT")" "permission denied was retried"
  [ ! -s "$BLIP_SLEEP" ] || fail "permission denied waited before returning: $(cat "$BLIP_SLEEP")"
  assert_equals 'permission denied' "$(cat "$BLIP_ERR")" "permission denied text was dropped"
  pass "a definite failure is returned once"
}

test_definite_failure_wins_over_a_timeout_word() {
  blip_reset
  BLIP_FAILS=5
  BLIP_TEXT='permission denied after timeout'
  blip_run
  [ "$BLIP_RC" -ne 0 ] || fail "a permission failure that mentions timeout succeeded"
  assert_equals 1 "$(cat "$BLIP_COUNT")" "a permission failure that mentions timeout was retried"
  [ ! -s "$BLIP_SLEEP" ] || fail "a definite failure waited because it also said timeout"
  pass "a definite answer is not retried when the same text mentions a timeout"
}

test_backoff_doubles_until_the_cap() {
  blip_reset
  BLIP_FAILS=4
  FM_BLIP_RETRY_CAP_SECS=8 blip_run
  assert_equals 0 "$BLIP_RC" "a capped retry did not recover"
  assert_equals 5 "$(cat "$BLIP_COUNT")" "a capped retry stopped before the successful attempt"
  assert_equals $'2\n4\n8\n8' "$(cat "$BLIP_SLEEP")" "backoff did not stay at the cap"
  pass "backoff doubles and then stays at the cap"
}

test_http_5xx_is_retried() {
  blip_reset
  BLIP_FAILS=1
  BLIP_TEXT='HTTP 503'
  blip_run
  assert_equals 0 "$BLIP_RC" "an HTTP 503 was not retried to success"
  assert_equals 2 "$(cat "$BLIP_COUNT")" "an HTTP 503 was attempted the wrong number of times"
  assert_equals 2 "$(cat "$BLIP_SLEEP")" "an HTTP 503 did not wait before the retry"
  pass "an HTTP 5xx is a transient blip"
}

test_missing_socket_is_retried_even_when_text_says_not_found() {
  blip_reset
  BLIP_FAILS=1
  BLIP_TEXT='control socket not found'
  blip_run
  assert_equals 0 "$BLIP_RC" "a missing control socket was not retried"
  assert_equals 2 "$(cat "$BLIP_COUNT")" "a missing control socket was not retried exactly once"
  pass "a missing socket is retried even when the text says it was not found"
}

blip_bare() {
  local n
  n=$(cat "$BLIP_COUNT")
  n=$((n + 1))
  printf '%s\n' "$n" > "$BLIP_COUNT"
  return 255
}

test_bare_failure_without_transient_text_is_not_retried() {
  blip_reset
  set +e
  fm_blip_retry blip_bare >"$BLIP_OUT" 2>"$BLIP_ERR"
  BLIP_RC=$?
  set -e
  assert_equals 255 "$BLIP_RC" "a bare failure status was replaced"
  assert_equals 1 "$(cat "$BLIP_COUNT")" "a bare failure with no transient text was retried"
  [ ! -s "$BLIP_SLEEP" ] || fail "a bare failure waited before returning"
  pass "a failure with no transient text is returned once"
}

test_invalid_override_fails_before_the_command() {
  blip_reset
  set +e
  FM_BLIP_RETRY_BASE_SECS=soon fm_blip_retry blip_stub >"$BLIP_OUT" 2>"$BLIP_ERR"
  BLIP_RC=$?
  set -e
  assert_equals 2 "$BLIP_RC" "a non-integer retry override was accepted"
  assert_equals 0 "$(cat "$BLIP_COUNT")" "a rejected override still ran the command"
  assert_contains "$(cat "$BLIP_ERR")" 'FM_BLIP_RETRY_BASE_SECS must be an integer' \
    "a rejected override did not name the bad setting"
  pass "a bad retry override is refused before the command runs"
}

test_orca_send_retries_a_transient_cli_blip() {
  local dir count log out_file err_file rc
  dir=$(fm_test_tmproot fm-blip-orca)
  mkdir -p "$dir/bin"
  count=$dir/count
  log=$dir/sleep
  out_file=$dir/out
  err_file=$dir/err
  printf '0\n' > "$count"
  : > "$log"
  cat > "$dir/bin/orca" <<'SH'
#!/usr/bin/env bash
n=$(cat "$FM_BLIP_ORCA_COUNT")
n=$((n + 1))
printf '%s\n' "$n" > "$FM_BLIP_ORCA_COUNT"
if [ "$n" -le "${FM_BLIP_ORCA_FAILS:-2}" ]; then
  printf '%s\n' "${FM_BLIP_ORCA_ERROR:-connect ECONNREFUSED}" >&2
  exit 1
fi
printf '%s\n' '{"ok":true}'
SH
  chmod +x "$dir/bin/orca"
  set +e
  PATH="$dir/bin:$PATH" \
    FM_BLIP_ORCA_COUNT="$count" \
    FM_BLIP_NOW=5000 \
    FM_BLIP_SLEEP_LOG="$log" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_literal term-1 hello' "$ROOT" \
    >"$out_file" 2>"$err_file"
  rc=$?
  set -e
  assert_equals 0 "$rc" "an Orca send did not recover from a refused connection"
  assert_equals 3 "$(cat "$count")" "an Orca send did not retry the refused connection"
  assert_equals $'2\n4' "$(cat "$log")" "an Orca send did not back off between retries"
  if grep -q 'ECONNREFUSED' "$out_file" "$err_file"; then
    fail "an Orca send kept the refused-connection text after it recovered"
  fi
  pass "an Orca terminal send retries a transient CLI blip"
}

test_orca_send_does_not_retry_permission_denied() {
  local dir count log err_file rc
  dir=$(fm_test_tmproot fm-blip-orca-denied)
  mkdir -p "$dir/bin"
  count=$dir/count
  log=$dir/sleep
  err_file=$dir/err
  printf '0\n' > "$count"
  : > "$log"
  cat > "$dir/bin/orca" <<'SH'
#!/usr/bin/env bash
n=$(cat "$FM_BLIP_ORCA_COUNT")
n=$((n + 1))
printf '%s\n' "$n" > "$FM_BLIP_ORCA_COUNT"
printf '%s\n' 'permission denied' >&2
exit 1
SH
  chmod +x "$dir/bin/orca"
  set +e
  PATH="$dir/bin:$PATH" \
    FM_BLIP_ORCA_COUNT="$count" \
    FM_BLIP_NOW=6000 \
    FM_BLIP_SLEEP_LOG="$log" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_literal term-1 hello' "$ROOT" \
    >"$dir/out" 2>"$err_file"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an Orca send treated permission denied as success"
  assert_equals 1 "$(cat "$count")" "an Orca send retried permission denied"
  [ ! -s "$log" ] || fail "an Orca send waited on permission denied"
  assert_contains "$(cat "$err_file")" 'permission denied' "an Orca send hid permission denied"
  pass "an Orca terminal send does not retry permission denied"
}

fm_test_run \
  test_transient_failures_retry_until_success \
  test_budget_reports_the_failing_attempt_once \
  test_definite_failure_is_not_retried \
  test_definite_failure_wins_over_a_timeout_word \
  test_backoff_doubles_until_the_cap \
  test_http_5xx_is_retried \
  test_missing_socket_is_retried_even_when_text_says_not_found \
  test_bare_failure_without_transient_text_is_not_retried \
  test_invalid_override_fails_before_the_command \
  test_orca_send_retries_a_transient_cli_blip \
  test_orca_send_does_not_retry_permission_denied
