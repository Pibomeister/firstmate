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

blip_expect_once() { # <text> <label>
  blip_reset
  BLIP_FAILS=5
  BLIP_TEXT=$1
  blip_run
  [ "$BLIP_RC" -ne 0 ] || fail "$2 was treated as success"
  assert_equals 1 "$(cat "$BLIP_COUNT")" "$2 was retried"
  [ ! -s "$BLIP_SLEEP" ] || fail "$2 waited before returning: $(cat "$BLIP_SLEEP")"
}

test_definite_texts_near_transient_words_fail_once() {
  blip_expect_once 'invalid --timeout-ms value' 'a timeout option error'
  blip_expect_once 'error: line 512 malformed' 'a parse error that names line 512'
  blip_expect_once 'error code 501 not implemented' 'an error code 501'
  blip_expect_once 'usage: orca terminal read --terminal <id>' 'a usage error'
  blip_expect_once 'worktree not found' 'a missing worktree'
  pass "definite errors that mention timeouts or 5NN numbers fail once"
}

test_real_transient_texts_retry() {
  local text
  for text in 'request timed out' 'connect ETIMEDOUT 10.0.0.1:443' 'HTTP/1.1 502 Bad Gateway' \
    'status: 504' 'service unavailable' 'read ECONNRESET'; do
    blip_reset
    BLIP_FAILS=1
    BLIP_TEXT=$text
    blip_run
    assert_equals 0 "$BLIP_RC" "transient text '$text' was not retried to success"
    assert_equals 2 "$(cat "$BLIP_COUNT")" "transient text '$text' was not retried exactly once"
  done
  pass "timed-out, reset, and real HTTP 5xx failures are retried"
}

blip_connect_run() {
  set +e
  fm_blip_retry --connect-only "$@" blip_stub >"$BLIP_OUT" 2>"$BLIP_ERR"
  BLIP_RC=$?
  set -e
}

test_connect_only_retries_a_failure_to_connect() {
  local text
  for text in 'This terminal could not connect to Orca.' 'runtime_unavailable' \
    'ssh: Could not resolve hostname remote-mac' \
    'ssh: connect to host remote-mac port 22: Operation timed out' \
    'Connection closed by 10.0.0.2 port 22' 'orca socket missing'; do
    blip_reset
    BLIP_FAILS=1
    BLIP_TEXT=$text
    blip_connect_run
    assert_equals 0 "$BLIP_RC" "connect failure '$text' was not retried to success"
    assert_equals 2 "$(cat "$BLIP_COUNT")" "connect failure '$text' was not retried exactly once"
  done
  pass "a command that never connected is retried in connect-only mode"
}

test_connect_only_does_not_repeat_a_call_that_may_have_landed() {
  local text
  for text in 'Timeout, server not responding.' \
    'Read from remote host remote-mac: Connection reset by peer' \
    'request timed out' 'HTTP 503' 'permission denied'; do
    blip_reset
    BLIP_FAILS=5
    BLIP_TEXT=$text
    blip_connect_run
    [ "$BLIP_RC" -ne 0 ] || fail "connect-only '$text' was treated as success"
    assert_equals 1 "$(cat "$BLIP_COUNT")" "connect-only repeated a call after '$text'"
    [ ! -s "$BLIP_SLEEP" ] || fail "connect-only waited after '$text'"
  done
  pass "connect-only mode does not repeat a call whose reply was lost"
}

blip_stdout_only() {
  local n
  n=$(cat "$BLIP_COUNT")
  n=$((n + 1))
  printf '%s\n' "$n" > "$BLIP_COUNT"
  printf 'ssh: connect to host x port 22: Connection refused\n'
  return 255
}

test_connect_only_ignores_stdout() {
  blip_reset
  set +e
  fm_blip_retry --connect-only blip_stdout_only >"$BLIP_OUT" 2>"$BLIP_ERR"
  BLIP_RC=$?
  set -e
  assert_equals 255 "$BLIP_RC" "connect-only replaced the exit status"
  assert_equals 1 "$(cat "$BLIP_COUNT")" "connect-only classified the command's own stdout"
  pass "connect-only mode never classifies the command's stdout"
}

test_ssh_connect_retries_only_exit_255() {
  blip_reset
  BLIP_FAILS=5
  BLIP_TEXT='ssh: connect to host remote-mac port 22: Connection refused'
  set +e
  fm_blip_retry --ssh-connect blip_stub >"$BLIP_OUT" 2>"$BLIP_ERR"
  BLIP_RC=$?
  set -e
  [ "$BLIP_RC" -ne 0 ] || fail "an ssh-connect failure with exit 1 was treated as success"
  assert_equals 1 "$(cat "$BLIP_COUNT")" "an ssh-connect exit other than 255 was retried"
  pass "--ssh-connect retries only an ssh exit 255"
}

BLIP_SSH_TEXT=''
BLIP_SSH_FAILS=5

blip_ssh() {
  local n
  n=$(cat "$BLIP_COUNT")
  n=$((n + 1))
  printf '%s\n' "$n" > "$BLIP_COUNT"
  if [ "$n" -le "$BLIP_SSH_FAILS" ]; then
    printf '%s\n' "$BLIP_SSH_TEXT" >&2
    return 255
  fi
  printf 'ready\n'
}

blip_ssh_run() { # <text> <fails>
  blip_reset
  BLIP_SSH_TEXT=$1
  BLIP_SSH_FAILS=$2
  set +e
  fm_blip_retry --ssh-connect blip_ssh >"$BLIP_OUT" 2>"$BLIP_ERR"
  BLIP_RC=$?
  set -e
}

test_ssh_connect_retries_a_pre_session_failure() {
  local text
  for text in 'ssh: connect to host remote-mac port 22: Connection refused' \
    'ssh: connect to host remote-mac port 22: Operation timed out' \
    'ssh: connect to host remote-mac port 22: No route to host' \
    'ssh: Could not resolve hostname remote-mac: nodename nor servname provided, or not known'; do
    blip_ssh_run "$text" 1
    assert_equals 0 "$BLIP_RC" "pre-session ssh failure '$text' was not retried to success"
    assert_equals 2 "$(cat "$BLIP_COUNT")" "pre-session ssh failure '$text' was not retried exactly once"
  done
  pass "an ssh that never opened a session is retried"
}

test_ssh_connect_does_not_repeat_a_session_that_may_have_run() {
  local text
  for text in 'packet_write_wait: Connection to remote-mac port 22: No route to host' \
    'Read from remote host remote-mac: No route to host' \
    'Read from remote host remote-mac: Network is unreachable' \
    'Read from remote host remote-mac: Connection timed out' \
    'Timeout, server not responding.' \
    'error: upstream connection refused' \
    'could not resolve hostname api.example.com'; do
    blip_ssh_run "$text" 5
    assert_equals 255 "$BLIP_RC" "ssh status 255 was replaced after '$text'"
    assert_equals 1 "$(cat "$BLIP_COUNT")" "an ssh session was repeated after '$text'"
    [ ! -s "$BLIP_SLEEP" ] || fail "an ssh session waited after '$text'"
  done
  pass "an ssh drop or remote stderr text is never retried"
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
  if [ -n "${FM_BLIP_ORCA_ERROR:-}" ]; then
    printf '%s\n' "$FM_BLIP_ORCA_ERROR" >&2
  else
    printf '%s\n' '{"ok":false,"error":{"code":"runtime_unavailable","message":"This terminal could not connect to Orca."}}'
  fi
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
  if grep -q 'could not connect to Orca' "$out_file" "$err_file"; then
    fail "an Orca send kept the connect-failure text after it recovered"
  fi
  pass "an Orca terminal send retries a transient CLI blip"
}

test_orca_send_retries_connect_text_on_stderr() {
  local dir
  dir=$(blip_orca_stub_dir fm-blip-orca-stderr)
  set +e
  PATH="$dir/bin:$PATH" \
    FM_BLIP_ORCA_COUNT="$dir/count" \
    FM_BLIP_ORCA_FAILS=1 \
    FM_BLIP_ORCA_ERROR='This terminal could not connect to Orca.' \
    FM_BLIP_NOW=5100 \
    FM_BLIP_SLEEP_LOG="$dir/sleep" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_literal term-1 hello' "$ROOT" \
    >"$dir/out" 2>"$dir/err"
  BLIP_RC=$?
  set -e
  assert_equals 0 "$BLIP_RC" "an Orca send did not recover from connect text on stderr"
  assert_equals 2 "$(cat "$dir/count")" "an Orca send did not retry connect text on stderr"
  pass "an Orca terminal send retries connect text printed on stderr"
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

blip_orca_stub_dir() { # <name>
  local dir
  dir=$(fm_test_tmproot "$1")
  mkdir -p "$dir/bin"
  printf '0\n' > "$dir/count"
  : > "$dir/sleep"
  cat > "$dir/bin/orca" <<'SH'
#!/usr/bin/env bash
n=$(cat "$FM_BLIP_ORCA_COUNT")
n=$((n + 1))
printf '%s\n' "$n" > "$FM_BLIP_ORCA_COUNT"
if [ "$n" -le "${FM_BLIP_ORCA_FAILS:-2}" ]; then
  if [ -n "${FM_BLIP_ORCA_ERROR:-}" ]; then
    printf '%s\n' "$FM_BLIP_ORCA_ERROR" >&2
  else
    printf '%s\n' '{"ok":false,"error":{"code":"runtime_unavailable","message":"This terminal could not connect to Orca."}}'
  fi
  exit 1
fi
printf '%s\n' '{"ok":true,"result":{"terminal":{"handle":"term-9"}}}'
SH
  chmod +x "$dir/bin/orca"
  printf '%s' "$dir"
}

blip_orca_call() { # <dir> <error> <shell snippet>
  set +e
  PATH="$1/bin:$PATH" \
    FM_BLIP_ORCA_COUNT="$1/count" \
    FM_BLIP_ORCA_FAILS=5 \
    FM_BLIP_ORCA_ERROR="$2" \
    FM_BLIP_NOW=7000 \
    FM_BLIP_SLEEP_LOG="$1/sleep" \
    bash -c '. "$0/bin/backends/orca.sh"; '"$3" "$ROOT" >"$1/out" 2>"$1/err"
  BLIP_RC=$?
  set -e
}

test_orca_mutations_do_not_repeat_after_a_lost_reply() {
  local dir err call
  for call in 'fm_backend_orca_send_literal term-1 hello' 'fm_backend_orca_send_text_line term-1 hello' \
    'fm_backend_orca_send_key term-1 C-c' 'fm_backend_orca_terminal_create wt-1 title' \
    'fm_backend_orca_remove_worktree wt-1'; do
    for err in 'request timed out' 'read ECONNRESET' 'HTTP 503 Service Unavailable'; do
      dir=$(blip_orca_stub_dir fm-blip-orca-mutation)
      blip_orca_call "$dir" "$err" "$call"
      [ "$BLIP_RC" -ne 0 ] || fail "'$call' treated '$err' as success"
      assert_equals 1 "$(cat "$dir/count")" "'$call' was repeated after '$err'"
      [ ! -s "$dir/sleep" ] || fail "'$call' waited after '$err'"
    done
  done
  pass "Orca sends and creates are not repeated after a reply that may have been lost"
}

test_orca_reads_retry_a_timed_out_reply() {
  local dir
  dir=$(blip_orca_stub_dir fm-blip-orca-read)
  set +e
  PATH="$dir/bin:$PATH" \
    FM_BLIP_ORCA_COUNT="$dir/count" \
    FM_BLIP_ORCA_FAILS=1 \
    FM_BLIP_ORCA_ERROR='request timed out' \
    FM_BLIP_NOW=8000 \
    FM_BLIP_SLEEP_LOG="$dir/sleep" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_blip orca terminal read --terminal term-1 --json' "$ROOT" \
    >"$dir/out" 2>"$dir/err"
  BLIP_RC=$?
  set -e
  assert_equals 0 "$BLIP_RC" "an Orca read did not recover from a timed-out reply"
  assert_equals 2 "$(cat "$dir/count")" "an Orca read did not retry a timed-out reply"
  pass "an Orca read retries a timed-out reply"
}

blip_sum() { # <file>
  awk '{ total += $1 } END { print total + 0 }' "$1"
}

test_orca_capture_gives_up_within_the_short_read_budget() {
  local dir
  dir=$(blip_orca_stub_dir fm-blip-orca-capture)
  set +e
  PATH="$dir/bin:$PATH" \
    FM_BLIP_ORCA_COUNT="$dir/count" \
    FM_BLIP_ORCA_FAILS=99 \
    FM_BLIP_NOW=9000 \
    FM_BLIP_SLEEP_LOG="$dir/sleep" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_capture term-1 40' "$ROOT" \
    >"$dir/out" 2>"$dir/err"
  BLIP_RC=$?
  set -e
  [ "$BLIP_RC" -ne 0 ] || fail "an Orca capture against a refused connection reported success"
  [ "$(blip_sum "$dir/sleep")" -le 15 ] \
    || fail "an Orca capture waited past the 15-second read budget: $(tr '\n' ' ' < "$dir/sleep")"
  [ "$(cat "$dir/count")" -gt 1 ] || fail "an Orca capture did not retry a refused connection at all"
  assert_contains "$(cat "$dir/err")" 'This terminal could not connect to Orca.' \
    "an Orca capture hid the connect-failure error"
  pass "an Orca capture against a refused connection gives up within the short read budget"
}

test_orca_draft_present_holds_within_the_short_read_budget() {
  local dir
  dir=$(blip_orca_stub_dir fm-blip-orca-draft)
  set +e
  PATH="$dir/bin:$PATH" \
    FM_BLIP_ORCA_COUNT="$dir/count" \
    FM_BLIP_ORCA_FAILS=99 \
    FM_BLIP_NOW=9500 \
    FM_BLIP_SLEEP_LOG="$dir/sleep" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_draft_present term-1' "$ROOT" \
    >"$dir/out" 2>"$dir/err"
  BLIP_RC=$?
  set -e
  assert_equals 0 "$BLIP_RC" "an unreadable Orca draft probe did not hold"
  [ "$(blip_sum "$dir/sleep")" -le 15 ] \
    || fail "an Orca draft probe waited past the 15-second read budget: $(tr '\n' ' ' < "$dir/sleep")"
  pass "an unreadable Orca draft probe still holds within the short read budget"
}

test_orca_send_retries_past_the_short_read_budget() {
  local dir
  dir=$(blip_orca_stub_dir fm-blip-orca-send-long)
  set +e
  PATH="$dir/bin:$PATH" \
    FM_BLIP_ORCA_COUNT="$dir/count" \
    FM_BLIP_ORCA_FAILS=5 \
    FM_BLIP_NOW=9800 \
    FM_BLIP_SLEEP_LOG="$dir/sleep" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_literal term-1 hello' "$ROOT" \
    >"$dir/out" 2>"$dir/err"
  BLIP_RC=$?
  set -e
  assert_equals 0 "$BLIP_RC" "an Orca send gave up before its 5-minute budget"
  assert_equals 6 "$(cat "$dir/count")" "an Orca send did not retry through five refused connections"
  assert_equals $'2\n4\n8\n16\n32' "$(cat "$dir/sleep")" "an Orca send did not keep doubling past 15 seconds"
  pass "an Orca send keeps retrying past the short read budget"
}

fm_test_run \
  test_transient_failures_retry_until_success \
  test_budget_reports_the_failing_attempt_once \
  test_definite_failure_is_not_retried \
  test_definite_failure_wins_over_a_timeout_word \
  test_backoff_doubles_until_the_cap \
  test_http_5xx_is_retried \
  test_missing_socket_is_retried_even_when_text_says_not_found \
  test_definite_texts_near_transient_words_fail_once \
  test_real_transient_texts_retry \
  test_connect_only_retries_a_failure_to_connect \
  test_connect_only_does_not_repeat_a_call_that_may_have_landed \
  test_connect_only_ignores_stdout \
  test_ssh_connect_retries_only_exit_255 \
  test_ssh_connect_retries_a_pre_session_failure \
  test_ssh_connect_does_not_repeat_a_session_that_may_have_run \
  test_bare_failure_without_transient_text_is_not_retried \
  test_invalid_override_fails_before_the_command \
  test_orca_send_retries_a_transient_cli_blip \
  test_orca_send_retries_connect_text_on_stderr \
  test_orca_send_does_not_retry_permission_denied \
  test_orca_mutations_do_not_repeat_after_a_lost_reply \
  test_orca_reads_retry_a_timed_out_reply \
  test_orca_capture_gives_up_within_the_short_read_budget \
  test_orca_draft_present_holds_within_the_short_read_budget \
  test_orca_send_retries_past_the_short_read_budget
