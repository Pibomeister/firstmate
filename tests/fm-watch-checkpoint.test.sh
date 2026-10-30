#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

wait_for_checkpoint_lock() {
  local home=$1 i=0
  while [ "$i" -lt 100 ]; do
    if [ -s "$home/state/.watch.lock/pid" ] \
      && [ -e "$home/state/.last-watcher-beat" ]; then
      return 0
    fi
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

test_quiet_checkpoint_exits_0_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  ! grep -E '^(signal:|stale:|check:|heartbeat)' "$out" >/dev/null \
    || fail "a quiet checkpoint printed a wake line: $(cat "$out")"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 0 with a clean checkpoint line, no wake, and no live lock"
}

# A seeded local secondmate home: identity marker plus a parent record whose
# home owns the steering inbox the checkpoint watches.
make_secondmate_home() {  # <name> -> echoes the secondmate home
  local home parent
  home=$(make_home "$1")
  parent="$TMP_ROOT/$1-parent"
  mkdir -p "$parent/state/sm1.inbox/handled"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$home/.fm-secondmate-parent"
  printf 'sm1\n' > "$home/.fm-secondmate-home"
  printf '%s\n' "$home"
}

run_secondmate_checkpoint() {  # <home> <seconds> [max]; sets STATUS and ELAPSED
  local start
  start=$(date +%s)
  STATUS=0
  FM_HOME="$1" FM_POLL=2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_CHECKPOINT_MAX="${3:-60}" \
    "$CHECKPOINT" --seconds "$2" >"$1/out.txt" 2>"$1/err.txt" || STATUS=$?
  ELAPSED=$(( $(date +%s) - start ))
}

# A secondmate's own checkpoint is capped (60 s by default) while a primary's
# requested bound is unchanged.
test_secondmate_checkpoint_bound_is_capped() {
  local home
  home=$(make_secondmate_home sm-cap)
  run_secondmate_checkpoint "$home" 180 2
  expect_code 0 "$STATUS" "secondmate quiet checkpoint: $(cat "$home/err.txt")"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 2s" "the secondmate bound was not capped"
  [ "$ELAPSED" -le 15 ] || fail "a capped secondmate checkpoint ran ${ELAPSED}s"
  home=$(make_home primary-uncapped)
  run_secondmate_checkpoint "$home" 3 2
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 3s" "a primary's bound was capped"
  pass "checkpoint: a secondmate's own checkpoint is capped and a primary's bound is unchanged"
}

# A record arriving in the parent-owned inbox ends the secondmate checkpoint
# within a few seconds, once per record, so an unacknowledgeable record can
# never turn checkpoints into a tight loop.
test_secondmate_checkpoint_returns_for_a_waiting_record() {
  local home inbox
  home=$(make_secondmate_home sm-inbox)
  inbox="$TMP_ROOT/sm-inbox-parent/state/sm1.inbox"
  ( sleep 2; printf 'schema=fm-task-inbox.v1\nat=x\n--\nroute this\n' > "$inbox/001.msg" ) &
  run_secondmate_checkpoint "$home" 40
  wait
  expect_code 0 "$STATUS" "inbox checkpoint: $(cat "$home/err.txt")"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: firstmate instruction waiting in the steering inbox: 001.msg" "the waiting record was not announced"
  [ "$ELAPSED" -le 12 ] || fail "the checkpoint took ${ELAPSED}s to return for a waiting record"
  ! grep -qF 'route this' "$home/out.txt" "$home/err.txt" || fail "the checkpoint printed a record body"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived the inbox return"
  run_secondmate_checkpoint "$home" 3
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 3s" "an announced record returned the checkpoint again"
  printf 'schema=fm-task-inbox.v1\nat=x\n--\nnext\n' > "$inbox/002.msg"
  run_secondmate_checkpoint "$home" 40
  assert_contains "$(cat "$home/out.txt")" "steering inbox: 002.msg" "a new record behind an announced one was not announced"
  [ "$ELAPSED" -le 12 ] || fail "a record waiting at start took ${ELAPSED}s to return"
  pass "checkpoint: a secondmate returns within seconds for each new parent inbox record, once per record"
}

# The announce-once record is what keeps an unacknowledgeable record from
# looping checkpoints, so when it cannot be written the checkpoint is an
# ordinary bounded wait rather than an immediate announcement every time.
test_secondmate_checkpoint_unwritable_marker_is_a_plain_wait() {
  local home inbox n
  home=$(make_secondmate_home sm-marker)
  inbox="$TMP_ROOT/sm-marker-parent/state/sm1.inbox"
  printf 'schema=fm-task-inbox.v1\nat=x\n--\nroute this\n' > "$inbox/001.msg"
  mkdir "$home/state/.checkpoint-inbox-seen"
  for n in 1 2; do
    run_secondmate_checkpoint "$home" 3
    expect_code 0 "$STATUS" "checkpoint $n beside an unwritable marker: $(cat "$home/err.txt")"
    assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 3s" "checkpoint $n announced a record it could not record as announced"
    [ "$ELAPSED" -ge 3 ] || fail "checkpoint $n returned after ${ELAPSED}s instead of waiting its bound"
  done
  pass "checkpoint: an unwritable announce-once marker leaves the secondmate checkpoint an ordinary bounded wait"
}

test_cleanup_persistence_failure_is_not_a_quiet_checkpoint() {
  local home holder status
  home=$(make_home cleanup-persistence-failure)
  cat > "$home/state/blocked.check.sh" <<'SH'
#!/usr/bin/env bash
: > "$FM_HOME/check-started"
sleep "$FM_TEST_STUB_MAX_BLOCK_SECONDS"
SH
  chmod 0700 "$home/state/blocked.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" blocked >/dev/null \
    || fail "could not register the blocked check"
  FM_HOME="$home" bash -c '
    . "$1"
    i=0
    while [ ! -e "$FM_HOME/check-started" ] && [ "$i" -lt 300 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    [ -e "$FM_HOME/check-started" ] || exit 1
    fm_lock_acquire_wait "$FM_HOME/state/.watcher-down.lock" || exit 1
    : > "$FM_HOME/cleanup-lock-held"
    while [ ! -e "$FM_HOME/release-cleanup-lock" ] && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 0.1; done
    fm_lock_release "$FM_HOME/state/.watcher-down.lock"
  ' _ "$ROOT/bin/fm-wake-lib.sh" &
  holder=$!
  status=0
  FM_HOME="$home" FM_POLL=1 FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=120 FM_HEARTBEAT=999999 \
    FM_WATCHER_CLEANUP_LOCK_BOUND=2 "$CHECKPOINT" --seconds 30 >"$home/out.txt" 2>"$home/err.txt" || status=$?
  : > "$home/release-cleanup-lock"
  wait_for_exit "$holder" 100 >/dev/null 2>&1 || true
  [ -e "$home/cleanup-lock-held" ] || fail "fixture did not hold the cleanup lock"
  expect_code 1 "$status" "cleanup persistence failure checkpoint exit"
  assert_contains "$(cat "$home/err.txt")" 'watcher: recovery state could not be persisted; retaining stale lock evidence' \
    "checkpoint hid the cleanup persistence failure"
  assert_not_contains "$(cat "$home/out.txt")" 'checkpoint: no actionable wake' \
    "cleanup persistence failure was reported as quiet success"
  [ -s "$home/state/.watch.lock/pid" ] || fail "cleanup failure discarded the stale watcher lock evidence"
  pass "checkpoint reports recovery persistence failure instead of quiet success"
}

# Hold the recovery lock before the watcher starts. The checkpoint must
# interrupt startup while its queue lock is held, before the first beacon.
test_interrupted_startup_reports_failed_cleanup() {
  local home holder status i
  home=$(make_home interrupted-startup)
  FM_HOME="$home" bash -c '
    . "$1"
    fm_lock_acquire_wait "$FM_HOME/state/.watcher-down.lock" || exit 1
    : > "$FM_HOME/recovery-held"
    i=0
    while [ ! -e "$FM_HOME/release-recovery" ] && [ "$i" -lt 300 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    fm_lock_release "$FM_HOME/state/.watcher-down.lock"
  ' _ "$ROOT/bin/fm-wake-lib.sh" &
  holder=$!
  i=0
  while [ ! -e "$home/recovery-held" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$home/recovery-held" ] || fail "startup: recovery lock was not held"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_WATCHER_CLEANUP_LOCK_BOUND=2 "$CHECKPOINT" --seconds 1 >"$home/out.txt" 2>"$home/err.txt" || status=$?
  : > "$home/release-recovery"
  wait "$holder" || fail "startup: recovery holder did not release its lock"
  expect_code 1 "$status" "interrupted startup must report failed cleanup"
  assert_contains "$(cat "$home/err.txt")" 'watcher: recovery state could not be persisted; retaining stale lock evidence' \
    "startup interruption hid the failed cleanup"
  assert_not_contains "$(cat "$home/out.txt")" 'checkpoint: no actionable wake' \
    "startup interruption became quiet success"
  [ -s "$home/state/.watch.lock/pid" ] || fail "startup: failed cleanup discarded watcher evidence"
  assert_absent "$home/state/.last-watcher-beat" "startup fixture reached the poll loop"
  pass "checkpoint: interrupted startup retains failed-cleanup evidence and returns nonzero"
}

test_preconfirmation_predecessor_retirement_uses_verified_identity() {
  local home holder predecessor replacement watcher initial identity i status=0 real_date real_mktemp
  home=$(make_real_host_home preconfirmation-predecessor)
  fm_test_track_watcher_state "$home/state"
  real_date=$(command -v date) || fail "date is required for startup synchronization"
  real_mktemp=$(command -v mktemp) || fail "mktemp is required for startup synchronization"
  cat > "$home/pre-exec.env" <<'SH'
case "$(ps -ww -o args= -p "$$" 2>/dev/null)" in
  *"$FM_TEST_WATCH_PATH")
    if [ "${FM_PRECONFIRM_EXECED:-0}" != 1 ]; then
      printf '%s\n' "$$" > "$FM_HOME/pre-exec.pid"
      : > "$FM_HOME/pre-exec-ready"
      while [ ! -e "$FM_HOME/pre-exec-go" ] && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 0.05; done
      export FM_PRECONFIRM_EXECED=1
      exec bash --noprofile "$FM_TEST_WATCH_PATH"
    fi
    ;;
esac
SH
  cat > "$home/fakebin/date" <<'SH'
#!/usr/bin/env bash
if [ -e "$FM_HOME/pre-exec-ready" ] && [ ! -e "$FM_HOME/pre-exec-go" ]; then
  case "$(ps -ww -o args= -p "$PPID" 2>/dev/null)" in
    *fm-watch-arm*) : > "$FM_HOME/initial-identity-captured" ;;
  esac
fi
exec "$FM_TEST_REAL_DATE" "$@"
SH
  cat > "$home/fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'/.supervision-host-arm.XXXXXX'*)
    if [ -e "$FM_HOME/predecessor-killed" ]; then
      : > "$FM_HOME/unexpected-successor"
      exit 1
    fi
    ;;
esac
exec "$FM_TEST_REAL_MKTEMP" "$@"
SH
  chmod +x "$home/fakebin/date" "$home/fakebin/mktemp"
  FM_HOME="$home" bash -c '
    . "$1"
    fm_lock_acquire_wait "$STATE/.watcher-down.lock" || exit 1
    : > "$FM_HOME/recovery-held"
    while [ ! -e "$FM_HOME/recovery-release" ] && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 0.05; done
    fm_lock_release "$STATE/.watcher-down.lock"
  ' _ "$ROOT/bin/fm-wake-lib.sh" &
  holder=$!
  i=0
  while [ ! -e "$home/recovery-held" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$home/recovery-held" ] || fail "preconfirmation fixture never held the recovery lock"
  # shellcheck disable=SC2016
  FM_HOME="$home" BASH_ENV="$home/pre-exec.env" PATH="$home/fakebin:$PATH" FM_TEST_REAL_DATE="$real_date" FM_TEST_REAL_MKTEMP="$real_mktemp" \
    FM_TEST_WATCH_PATH="${CHECKPOINT%/*}/fm-watch.sh" \
    FM_SUPERVISION_HOST_PRIMARY=codex FM_SUPERVISION_HOST_PARK_SECONDS=120 \
    FM_WATCHER_CLEANUP_LOCK_BOUND=8 FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$home/fakebin/codex" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      "$0" park
    ' "${CHECKPOINT%/*}/fm-supervision-host.sh" > "$home/predecessor.out" 2> "$home/predecessor.err" &
  predecessor=$!
  i=0
  while [ ! -e "$home/initial-identity-captured" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$home/initial-identity-captured" ] || fail "arm did not capture the pre-exec watcher identity"
  watcher=$(cat "$home/pre-exec.pid")
  initial=$(FM_HOME="$home" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$watcher") \
    || fail "could not read the pre-exec watcher identity"
  : > "$home/pre-exec-go"
  i=0
  while [ ! -s "$home/state/.watch.lock/pid-identity" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
  identity=$(cat "$home/state/.watch.lock/pid-identity")
  [ -n "$identity" ] && [ "$identity" != "$initial" ] || fail "watcher exec did not change its process identity"
  [ "$(cat "$home/state/.watch.lock/pid")" = "$watcher" ] || fail "watcher exec changed its pid"
  assert_absent "$home/state/.last-watcher-beat" "preconfirmation watcher reached its first beacon"
  kill -KILL "$(awk -F '\t' '$1 == "host" { print $2; exit }' "$home/state/.supervision-host")"
  wait_for_exit "$predecessor" 200 >/dev/null 2>&1 || true
  : > "$home/predecessor-killed"
  # shellcheck disable=SC2016
  FM_HOME="$home" BASH_ENV="$home/pre-exec.env" PATH="$home/fakebin:$PATH" FM_TEST_REAL_DATE="$real_date" FM_TEST_REAL_MKTEMP="$real_mktemp" \
    FM_TEST_WATCH_PATH="${CHECKPOINT%/*}/fm-watch.sh" \
    FM_SUPERVISION_HOST_PRIMARY=codex FM_SUPERVISION_HOST_PARK_SECONDS=120 \
    FM_WATCHER_CLEANUP_LOCK_BOUND=8 FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$home/fakebin/codex" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      "$0" park
    ' "${CHECKPOINT%/*}/fm-supervision-host.sh" > "$home/out.txt" 2> "$home/err.txt" &
  replacement=$!
  wait_for_exit "$replacement" 300 || status=$?
  : > "$home/recovery-release"
  wait_for_exit "$holder" 100 >/dev/null 2>&1 || fail "preconfirmation recovery holder did not release"
  expect_code 1 "$status" "preconfirmation predecessor retirement must fail"
  assert_contains "$(cat "$home/out.txt" "$home/err.txt")" \
    'supervision-host: watcher: recovery state could not be persisted; retaining stale lock evidence' \
    "preconfirmation retirement discarded its failed-cleanup diagnostic"
  assert_absent "$home/unexpected-successor" "failed predecessor cleanup started another watcher arm"
  [ "$(cat "$home/state/.watch.lock/pid")" = "$watcher" ] || fail "preconfirmation retirement discarded the watcher lock"
  [ "$(cat "$home/state/.watch.lock/pid-identity")" = "$identity" ] || fail "preconfirmation retirement changed the retained identity"
  assert_absent "$home/state/.last-watcher-beat" "replacement retired startup as a healthy cycle"
  pass "preconfirmation predecessor retirement reports cleanup failure using the verified post-exec identity"
}

# Copy the checkpoint into <home>/root/bin and build <home>/fixture-bin, a
# PATH holding only the named host tools, so stubs decide which timeout runs.
make_isolated_checkpoint() {  # <home> <tool...>
  local home=$1 tool tool_path
  shift
  mkdir -p "$home/root/bin" "$home/fixture-bin"
  cp "$CHECKPOINT" "$home/root/bin/fm-watch-checkpoint.sh"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$home/root/bin/fm-supervision-engine-lib.sh"
  cp "$ROOT/bin/fm-bash-compat-lib.sh" "$home/root/bin/fm-bash-compat-lib.sh"
  for tool in "$@"; do
    tool_path=$(command -v "$tool") || fail "could not locate $tool for the isolated checkpoint fixture"
    ln -s "$tool_path" "$home/fixture-bin/$tool"
  done
}

write_non_gnu_timeout_stub() {  # <path>
  cat > "$1" <<'SH'
#!/bin/bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'uutils 0.12.0'
  exit 0
fi
exit 137
SH
  chmod +x "$1"
}

# A GNU stub records its name and arguments, then reports a timeout.
write_gnu_timeout_stub() {  # <path>
  cat > "$1" <<'SH'
#!/bin/bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'timeout (GNU coreutils) 9.5'
  exit 0
fi
printf '%s' "${0##*/}" >> "$FM_HOME/timeout-calls"
printf ' %s' "$@" >> "$FM_HOME/timeout-calls"
printf '\n' >> "$FM_HOME/timeout-calls"
exit 124
SH
  chmod +x "$1"
}

expect_gnu_timeout_call() {  # <home> <command-name> <label>
  local home=$1 name=$2 label=$3 status
  status=0
  PATH="$home/fixture-bin" FM_HOME="$home" FM_SIGNAL_GRACE=1 \
    "$home/root/bin/fm-watch-checkpoint.sh" --seconds 1 >"$home/out.txt" 2>"$home/err.txt" || status=$?
  expect_code 0 "$status" "$label checkpoint exit"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 1s" \
    "$label did not return a quiet checkpoint"
  [ "$(cat "$home/timeout-calls" 2>/dev/null)" = "$name --signal=INT --kill-after=5s 1 $home/root/bin/fm-watch.sh" ] \
    || fail "$label did not run $name with the watcher bound: $(cat "$home/timeout-calls" 2>/dev/null)"
}

test_gnu_timeout_runs_the_watcher_bound() {
  local home
  home=$(make_home gnu-timeout)
  make_isolated_checkpoint "$home" bash dirname mktemp rm grep cat
  write_gnu_timeout_stub "$home/fixture-bin/timeout"
  write_gnu_timeout_stub "$home/fixture-bin/gtimeout"
  expect_gnu_timeout_call "$home" timeout "GNU timeout"
  pass "GNU timeout runs the watcher with the INT signal and kill-after bound"
}

test_non_gnu_timeout_uses_gnu_gtimeout() {
  local home
  home=$(make_home non-gnu-timeout-gtimeout)
  make_isolated_checkpoint "$home" bash dirname mktemp rm grep cat
  write_non_gnu_timeout_stub "$home/fixture-bin/timeout"
  write_gnu_timeout_stub "$home/fixture-bin/gtimeout"
  expect_gnu_timeout_call "$home" gtimeout "GNU gtimeout"
  pass "non-GNU timeout yields to GNU gtimeout with the INT signal and kill-after bound"
}

test_non_gnu_timeout_falls_back_to_perl_before_escalating() {
  local home fallback_bin status watcher_pid
  home=$(make_home non-gnu-timeout)
  fallback_bin="$home/fixture-bin"
  make_isolated_checkpoint "$home" bash dirname mktemp rm perl grep cat
  write_non_gnu_timeout_stub "$fallback_bin/timeout"
  cat > "$home/root/bin/fm-watch.sh" <<'PL'
#!/usr/bin/env perl
use strict;
use warnings;
$SIG{INT} = sub {
  open my $int_file, '>', "$ENV{FM_HOME}/int-received" or die "open INT marker: $!";
  close $int_file;
};
open my $pid_file, '>', "$ENV{FM_HOME}/watcher.pid" or die "open pid file: $!";
printf {$pid_file} "%s\n", $$;
close $pid_file;
my $cleanup_deadline = time + 7;
while ((my $left = $cleanup_deadline - time) > 0) {
  sleep $left;
}
open my $cleanup_file, '>', "$ENV{FM_HOME}/cleanup-reached" or die "open cleanup marker: $!";
print {$cleanup_file} "reached\n";
close $cleanup_file;
END {
  if (open my $exit_file, '>', "$ENV{FM_HOME}/natural-exit") {
    print {$exit_file} "natural\n";
  }
}
sleep 20;
PL
  chmod +x "$home/root/bin/fm-watch-checkpoint.sh" "$home/root/bin/fm-watch.sh"

  status=0
  PATH="$fallback_bin" FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_WATCHER_CLEANUP_LOCK_BOUND=8 \
    "$home/root/bin/fm-watch-checkpoint.sh" --seconds 1 >"$home/out.txt" 2>"$home/err.txt" || status=$?

  expect_code 137 "$status" "Perl fallback checkpoint exit"
  assert_not_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake" \
    "Perl fallback reported a forced shutdown as quiet success"
  assert_contains "$(cat "$home/err.txt")" "forced KILL" "Perl fallback hid its forced shutdown"
  [ -e "$home/int-received" ] || fail "the Perl fallback did not deliver INT to the watcher"
  [ -e "$home/cleanup-reached" ] || fail "the Perl fallback killed the watcher before its 8-second cleanup bound"
  [ ! -e "$home/natural-exit" ] || fail "the INT-surviving watcher exited naturally instead of being killed"
  [ -s "$home/watcher.pid" ] || fail "the INT-surviving watcher did not start"
  watcher_pid=$(cat "$home/watcher.pid")
  if kill -0 "$watcher_pid" 2>/dev/null; then
    fail "the watcher survived the Perl fallback KILL escalation"
  fi
  pass "non-GNU timeout falls back to Perl and honors the cleanup bound before escalating"
}

run_real_perl_shutdown() {
  local kind=$1 home fallback_bin tool tool_path source holder='' watcher status expected=137 hash_tool
  home=$(make_home "real-perl-$kind")
  fallback_bin="$home/fallback-bin"
  mkdir -p "$fallback_bin" "$home/root/bin"
  for source in "$ROOT/bin/"*; do ln -s "$source" "$home/root/bin/${source##*/}"; done
  rm "$home/root/bin/fm-watch-checkpoint.sh"
  cp "$CHECKPOINT" "$home/root/bin/fm-watch-checkpoint.sh"
  for tool in bash sh dirname mktemp rm perl grep cat date mkdir rmdir readlink ln chmod mv ps awk sed stat tr tail head wc sleep sort cmp cut touch od env node uname git jq basename cp id; do
    tool_path=$(command -v "$tool") || fail "could not locate $tool for the real Perl fixture"
    ln -s "$tool_path" "$fallback_bin/$tool"
  done
  hash_tool=shasum
  tool_path=$(command -v "$hash_tool") || { hash_tool=sha256sum; tool_path=$(command -v "$hash_tool"); } \
    || fail "could not locate a supported custom-check hashing tool"
  ln -s "$tool_path" "$fallback_bin/$hash_tool"
  cat > "$fallback_bin/tmux" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  # Leave ordinary quiet shutdown free of the contention/forwarding shims.
  if [ "$kind" != quiet ]; then
    rm "$fallback_bin/cat" "$fallback_bin/mv"
    cat > "$fallback_bin/cat" <<'SH'
#!/usr/bin/env bash
"$FM_TEST_REAL_CAT" "$@"
result=$?
last=
for last in "$@"; do :; done
if [ "$last" = "$FM_HOME/state/.watcher-down.lock/pid" ] && [ -e "$FM_HOME/force-cleanup-contention" ]; then
  : > "$FM_HOME/cleanup-contended"
  while [ ! -e "$FM_HOME/release-cleanup-contention" ] && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 0.1; done
fi
exit "$result"
SH
    cat > "$fallback_bin/mv" <<'SH'
#!/usr/bin/env bash
last=
for last in "$@"; do :; done
if [ "$last" = "$FM_HOME/state/.watch-deliveries.log" ]; then
  : > "$FM_HOME/perl-output-ready"
  while [ ! -e "$FM_HOME/perl-output-go" ] && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 0.1; done
fi
exec "$FM_TEST_REAL_MV" "$@"
SH
    chmod +x "$fallback_bin/cat" "$fallback_bin/mv"
  fi
  chmod +x "$fallback_bin/tmux"
  if [ "$kind" = quiet ]; then
    expected=0
  else
    if [ "$kind" = signal ]; then
      printf 'project=fixture\nwindow=fm-demo\nharness=codex\n' > "$home/state/demo.meta"
    else
      cat > "$home/state/blocked.check.sh" <<'SH'
#!/usr/bin/env bash
: > "$FM_HOME/check-started"
sleep "$FM_TEST_STUB_MAX_BLOCK_SECONDS"
SH
      chmod 0700 "$home/state/blocked.check.sh"
      FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" blocked >/dev/null || fail "could not register the real Perl blocked check"
    fi
  fi
  if [ "$kind" != quiet ]; then
    FM_HOME="$home" bash -c '
      . "$1"
      kind=$2
      i=0
      while [ "$i" -lt 1000 ]; do
        if [ "$kind" = signal ]; then
          [ -s "$FM_HOME/state/.watch.lock/pid" ] && [ -e "$FM_HOME/state/.last-watcher-beat" ] && break
        else
          [ -e "$FM_HOME/check-started" ] && break
        fi
        sleep 0.1
        i=$((i + 1))
      done
      [ "$i" -lt 1000 ] || exit 1
      cat "$FM_HOME/state/.watch.lock/pid" > "$FM_HOME/watcher-before-kill"
      if [ "$kind" = signal ]; then
        # This case measures shutdown after delivery, not busy-pane triage.
        printf "done: real Perl shutdown\n" > "$FM_HOME/state/demo.status"
        i=0
        while [ ! -e "$FM_HOME/perl-output-ready" ] && [ "$i" -lt 1000 ]; do sleep 0.1; i=$((i + 1)); done
        [ -e "$FM_HOME/perl-output-ready" ] || exit 1
        cp "$FM_HOME/state/.wake-queue" "$FM_HOME/queued-before-kill"
      fi
      fm_lock_acquire_wait "$FM_HOME/state/.watcher-down.lock" || exit 1
      : > "$FM_HOME/cleanup-lock-held"
      : > "$FM_HOME/force-cleanup-contention"
      : > "$FM_HOME/perl-output-go"
      while [ ! -e "$FM_HOME/release-cleanup-lock" ] && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 0.1; done
      fm_lock_release "$FM_HOME/state/.watcher-down.lock"
    ' _ "$ROOT/bin/fm-wake-lib.sh" "$kind" &
    holder=$!
  fi
  # The runner can inherit ignored SIGINT; reset it before Bash starts.
  status=0
  FM_HOME="$home" FM_TEST_REAL_CAT="$(command -v cat)" FM_TEST_REAL_MV="$(command -v mv)" PATH="$fallback_bin" \
    FM_WATCH_DELIVERY_MAX_BYTES=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=120 \
    FM_HEARTBEAT=999999 FM_WATCHER_CLEANUP_LOCK_BOUND=8 \
    perl -e '$SIG{INT}="DEFAULT"; exec @ARGV or die "exec failed: $!\n"' \
      "$home/root/bin/fm-watch-checkpoint.sh" --seconds 15 >"$home/out.txt" 2>"$home/err.txt" || status=$?
  : > "$home/release-cleanup-lock"
  : > "$home/release-cleanup-contention"
  [ -z "$holder" ] || wait_for_exit "$holder" 100 || fail "real Perl contention controller did not complete: $(cat "$home/out.txt" "$home/err.txt")"
  if [ "$kind" != quiet ]; then
    [ -e "$home/cleanup-lock-held" ] || fail "real Perl fixture did not hold its cleanup lock"
    [ -e "$home/cleanup-contended" ] || fail "real Perl watcher never attempted contended cleanup: $(cat "$home/err.txt")"
    watcher=$(cat "$home/watcher-before-kill")
  fi
  expect_code "$expected" "$status" "real Perl $kind exit: $(cat "$home/out.txt" "$home/err.txt")"
  if [ "$kind" = quiet ]; then
    assert_contains "$(cat "$home/out.txt")" 'checkpoint: no actionable wake within 15s' "ordinary Perl quiet completion failed"
  else
    assert_contains "$(cat "$home/err.txt")" 'forced KILL' "real Perl escalation diagnostic was hidden"
    assert_not_contains "$(cat "$home/out.txt")" 'checkpoint: no actionable wake' "real Perl escalation became quiet success"
    [ "$(cat "$home/state/.watch.lock/pid")" = "$watcher" ] || fail "real Perl escalation discarded process evidence"
    ! is_live_non_zombie "$watcher" || fail "real Perl escalation left the watcher alive"
    if [ "$kind" = signal ]; then
      [ "$(grep -c '^signal: .*demo.status' "$home/out.txt")" -eq 1 ] || fail "real Perl escalation lost or repeated its wake"
      cmp -s "$home/queued-before-kill" "$home/state/.wake-queue" || fail "real Perl escalation changed queued work"
    fi
  fi
  pass "real Perl $kind preserves the shutdown result and any real wake"
}

test_real_perl_shutdown_classification() {
  run_real_perl_shutdown blocked
  run_real_perl_shutdown signal
  run_real_perl_shutdown quiet
}

test_announced_recovery_is_not_reannounced_by_next_checkpoint() {
  local home out err status marker
  home=$(make_home announced-recovery)
  out="$home/out.txt"
  err="$home/err.txt"
  append_wake "$home/state" check buried 'check: unacknowledged durable wake' \
    || fail "could not append the unacknowledged durable wake"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "first recovery checkpoint exit"
  assert_contains "$(cat "$out")" "check: rearm-resurface" \
    "first checkpoint did not announce the pending recovery"
  marker=$(cat "$home/state/.watcher-down")
  case "$marker" in
    announced:downtime:*) ;;
    *) fail "first checkpoint did not leave an announced generation: $marker" ;;
  esac
  [ -s "$home/state/.wake-queue" ] \
    || fail "durable wake did not stay unacknowledged after the announcement"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?

  expect_code 0 "$status" "announced recovery checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 5s" \
    "announced recovery checkpoint did not supervise for its bound"
  assert_not_contains "$(cat "$out")" "check: rearm-resurface" \
    "announced recovery was reannounced by the next checkpoint"
  [ "$(cat "$home/state/.watcher-down")" = "$marker" ] \
    || fail "announced recovery checkpoint changed the outstanding generation"
  grep "$(printf '\tcheck\tburied\tcheck: unacknowledged durable wake')" \
    "$home/state/.wake-queue" >/dev/null \
    || fail "unacknowledged durable wake was not retained"
  pass "an announced recovery is not reannounced by the next foreground checkpoint"
}

test_never_announced_recovery_is_announced_once() {
  local home out err status
  home=$(make_home pending-recovery)
  out="$home/out.txt"
  err="$home/err.txt"
  printf 'pending:downtime:unreported.1.aaa\n' > "$home/state/.watcher-down"
  append_wake "$home/state" check buried 'check: durable row buried by the downtime' \
    || fail "could not append the buried durable wake"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?

  expect_code 0 "$status" "pending recovery checkpoint exit"
  [ "$(grep -c '^check: rearm-resurface$' "$out" || true)" -eq 1 ] \
    || fail "never-announced recovery did not surface exactly once: $(cat "$out")"
  [ "$(cat "$home/state/.watcher-down")" = 'announced:downtime:unreported.1.aaa' ] \
    || fail "never-announced recovery did not retain its announced generation"

  home=$(make_home pending-recovery-empty)
  out="$home/out.txt"
  err="$home/err.txt"
  printf 'pending:downtime:unreported.2.bbb\n' > "$home/state/.watcher-down"
  status=0
  # This assertion needs the first poll to finish, not a one-second startup
  # deadline on a shared machine.
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?

  expect_code 0 "$status" "empty-queue pending recovery checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 5s" \
    "an empty-queue pending recovery did not stay a quiet checkpoint"
  assert_not_contains "$(cat "$out")" "check: rearm-resurface" \
    "an empty-queue pending recovery woke for bookkeeping"
  # The checkpoint's own exit opens the next downtime episode, so the retired
  # generation must be gone rather than left pending or announced.
  case "$(cat "$home/state/.watcher-down")" in
    acked:downtime:unreported.2.bbb|pending:downtime:*) ;;
    *) fail "an empty-queue pending recovery was not retired silently: $(cat "$home/state/.watcher-down")" ;;
  esac
  [ "$(cat "$home/state/.watcher-down")" != 'pending:downtime:unreported.2.bbb' ] \
    || fail "an empty-queue pending recovery was not retired on its own generation"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "second empty-queue checkpoint exit"
  assert_not_contains "$(cat "$out")" "check: rearm-resurface" \
    "the episode opened by a quiet checkpoint exit woke the next checkpoint"
  pass "a never-announced recovery surfaces once while a row is buried and retires silently with an empty queue"
}

test_queue_append_during_checkpoint_still_resurfaces() {
  local home out err status checkpoint_pid
  home=$(make_home queue-append)
  out="$home/out.txt"
  err="$home/err.txt"

  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" &
  checkpoint_pid=$!
  wait_for_checkpoint_lock "$home" || {
    kill "$checkpoint_pid" 2>/dev/null || true
    wait "$checkpoint_pid" 2>/dev/null || true
    fail "queue-append checkpoint did not take the watcher lock"
  }
  append_wake "$home/state" check concurrent 'check: appended during checkpoint' \
    || fail "could not append a durable wake during the checkpoint"
  status=0
  wait "$checkpoint_pid" || status=$?

  expect_code 0 "$status" "queue-append checkpoint exit"
  assert_contains "$(cat "$out")" "check: rearm-resurface" \
    "queue append during checkpoint did not resurface"
  grep "$(printf '\tcheck\tconcurrent\tcheck: appended during checkpoint')" \
    "$home/state/.wake-queue" >/dev/null \
    || fail "queue append was not retained durably after checkpoint recovery"
  pass "a queue append during a foreground checkpoint still resurfaces"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained producer
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  # Establish the ordinary home ledger before measuring checkpoint delivery.
  FM_HOME="$home" "$ROOT/bin/fm-home-summary-refresh.sh" >/dev/null \
    || fail "could not publish the signal fixture's initial home summary"
  (
    wait_for_checkpoint_lock "$home" || exit 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  producer=$!
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  wait "$producer" || fail "signal producer did not observe a ready checkpoint"
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

# A home opted into the supervision host whose checkpoint runs a stub host in
# a fixture code root: the stub records the bound it was given, then closes
# the way $FM_HOME/host-kind says.
make_host_home() {  # <name>
  local home f
  home=$(make_home "$1")
  mkdir -p "$home/root/bin"
  cp "$CHECKPOINT" "$home/root/bin/fm-watch-checkpoint.sh"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$home/root/bin/fm-supervision-engine-lib.sh"
  cp "$ROOT/bin/fm-bash-compat-lib.sh" "$home/root/bin/fm-bash-compat-lib.sh"
  # The secondmate-home check and the parent inbox path it reads.
  for f in fm-primary-scope-lib.sh fm-secondmate-parent-lib.sh fm-task-inbox-lib.sh fm-wake-lib.sh fm-backend.sh \
    fm-path-lib.sh fm-classify-lib.sh fm-timeout-lib.sh fm-session-lock-lib.sh; do
    cp "$ROOT/bin/$f" "$home/root/bin/$f"
  done
  cat > "$home/root/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'args=%s\nprimary=%s\npark=%s\nlimit=%s\n' "$*" "${FM_SUPERVISION_HOST_PRIMARY:-}" \
  "${FM_SUPERVISION_HOST_PARK_SECONDS:-}" "${FM_SUPERVISION_HOST_PARK_LIMIT:-}" > "$FM_HOME/host-env"
if [ -e "$FM_HOME/cleanup-error" ]; then
  if [ "$(cat "$FM_HOME/cleanup-error")" = stdout ]; then
    printf 'watcher: recovery state could not be persisted; retaining stale lock evidence\n'
  else
    printf 'watcher: recovery state could not be persisted; retaining stale lock evidence\n' >&2
  fi
fi
case "$(cat "$FM_HOME/host-kind")" in
  boundary) printf 'supervision-host: cycle boundary - fixture\n' ;;
  handback)
    printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
    printf 'signal: demo.status\nsupervision-host: the away session could not take this wake: fixture; this wake is yours\n'
    ;;
  stood-down) printf 'supervision-host stood down: this session no longer owns supervision\n' ;;
esac
SH
  chmod +x "$home/root/bin/fm-watch-checkpoint.sh" "$home/root/bin/fm-supervision-host.sh"
  : > "$home/config/supervision-host"
  printf '%s\n' "$home"
}

run_host_checkpoint() {  # <home> <kind> [checkpoint args...]; sets STATUS
  local home=$1
  printf '%s\n' "$2" > "$home/host-kind"
  shift 2
  STATUS=0
  FM_HOME="$home" "$home/root/bin/fm-watch-checkpoint.sh" "$@" >"$home/out.txt" 2>"$home/err.txt" || STATUS=$?
}

test_host_checkpoint_bounds_the_park_by_posture() {
  local home f
  home=$(make_host_home host-bound)
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 0 "$STATUS" "a host park that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 5s" "the boundary must read as the ordinary quiet line"
  assert_contains "$(cat "$home/host-env")" $'args=park\nprimary=codex\npark=5\nlimit=1235' \
    "attended, the host must park for the checkpoint's own bound with the codex pin and a turn limit past it"
  : > "$home/state/.afk-contract"
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 0 "$STATUS" "an away park that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 3600s" "away, the bound must be raised"
  assert_contains "$(cat "$home/host-env")" 'park=3600' "away, the host must park for the away bound"
  FM_CODEX_WATCH_CHECKPOINT_AWAY=900 run_host_checkpoint "$home" boundary --seconds 5
  assert_contains "$(cat "$home/host-env")" 'park=900' "the away bound must be configurable"
  FM_CODEX_WATCH_CHECKPOINT_AWAY=900 run_host_checkpoint "$home" boundary --seconds 1000
  assert_contains "$(cat "$home/host-env")" 'park=1000' "the away bound must never shorten a longer checkpoint"
  # Quiet mode's record is a present captain (bin/fm-afk-contract.sh AWAY OR
  # QUIET), so the checkpoint keeps its attended bound beside it.
  for f in fm-bash-compat-lib.sh fm-afk-contract.sh fm-classify-lib.sh fm-timeout-lib.sh; do cp "$ROOT/bin/$f" "$home/root/bin/$f"; done
  rm -f "$home/state/.afk-contract"
  FM_HOME="$home" FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter --words 'keep routine wakes off my main' >/dev/null 2>&1 \
    || fail "fixture: could not record quiet mode"
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 0 "$STATUS" "a park beside a quiet record that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/host-env")" 'park=5' "beside a quiet record the host must park for the attended bound"
  pass "checkpoint: an opted-in home runs the host for the checkpoint's bound, raised only while away"
}

# A secondmate home that opted into the host gets the same 60 s cap: an
# attended long checkpoint and the away raise both park for at most 60 s.
test_host_checkpoint_caps_a_secondmate_park() {
  local home
  home=$(make_host_home host-secondmate)
  mkdir -p "$TMP_ROOT/host-secondmate-parent/state/sm1.inbox/handled"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$TMP_ROOT/host-secondmate-parent" > "$home/.fm-secondmate-parent"
  printf 'sm1\n' > "$home/.fm-secondmate-home"
  run_host_checkpoint "$home" boundary --seconds 1000
  expect_code 0 "$STATUS" "an attended secondmate host park: $(cat "$home/err.txt")"
  assert_contains "$(cat "$home/host-env")" 'park=60' "an attended secondmate host park was not capped at 60 s"
  : > "$home/state/.afk-contract"
  FM_CODEX_WATCH_CHECKPOINT_AWAY=900 run_host_checkpoint "$home" boundary --seconds 5
  assert_contains "$(cat "$home/host-env")" 'park=60' "the away raise lifted a secondmate host park above 60 s"
  pass "checkpoint: a secondmate home's host park is capped at 60 s, attended and away"
}

# The inbox early exit belongs to the plain path alone: the host's watchers
# never inherit it, so a parent record arriving mid-park in a secondmate home
# that runs the real host leaves an ordinary quiet checkpoint, not a failed
# one, and is not marked announced.
# shellcheck disable=SC2016
test_real_host_secondmate_park_ignores_the_inbox() {
  local home fakebin status
  home=$(make_secondmate_home host-real-sm)
  : > "$home/config/supervision-host"
  fakebin="$TMP_ROOT/host-real-sm-bin"
  mkdir -p "$fakebin"
  ln -s /bin/bash "$fakebin/codex"
  ( sleep 1; printf 'schema=fm-task-inbox.v1\nat=x\n--\nroute this\n' > "$TMP_ROOT/host-real-sm-parent/state/sm1.inbox/001.msg" ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$fakebin/codex" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$0" --seconds 4
  ' "$CHECKPOINT" >"$home/out.txt" 2>"$home/err.txt" || status=$?
  wait
  expect_code 0 "$status" "a secondmate host checkpoint with a new parent record: $(cat "$home/out.txt" "$home/err.txt")"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 4s" "the host park did not end as the quiet line"
  assert_not_contains "$(cat "$home/out.txt" "$home/err.txt")" 'FAILED' "the host's watcher failed on the parent record"
  assert_absent "$home/state/.checkpoint-inbox-seen" "the host's watcher announced the record the plain path owns"
  if [ -e "$home/state/.watch.lock/pid" ] && kill -0 "$(cat "$home/state/.watch.lock/pid")" 2>/dev/null; then
    fail "a secondmate host checkpoint left its watcher running"
  fi
  pass "checkpoint: a secondmate's host park never runs the plain path's inbox exit"
}

# A secondmate's capped bound is also the real host's turn limit: an away close
# whose engine turn could outlast it is handed to the secondmate at once rather
# than holding its turn for the engine's own bound, and the checkpoint leaves
# no host, engine or watcher behind.
# shellcheck disable=SC2016
test_real_host_secondmate_turn_never_outlives_the_cap() {
  local home fakebin start elapsed status pid
  home=$(make_secondmate_home host-real-sm-turn)
  printf 'claude\n' > "$home/config/supervision-host"
  printf 'project=demo\nwindow=fm-demo\nharness=claude\n' > "$home/state/demo.meta"
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" enter --words 'watch the fleet; merge nothing' >/dev/null 2>&1 \
    || fail "fixture: could not record the away posture"
  fakebin="$TMP_ROOT/host-real-sm-turn-bin"
  mkdir -p "$fakebin"
  ln -s /bin/bash "$fakebin/codex"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/tmux"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$$" >> "%s/engine-calls"\nexec sleep 40\n' "$home" > "$fakebin/engine"
  chmod +x "$fakebin/tmux" "$fakebin/engine"
  make_fake_crew_state "$fakebin" >/dev/null
  (
    i=0
    while [ "$i" -lt 150 ] && [ ! -s "$home/state/.watch.lock/pid" ]; do sleep 0.1; i=$((i + 1)); done
    sleep 1
    printf 'working [at=%s]: one close\n' "$(date +%s)" >> "$home/state/demo.status"
  ) &
  start=$(date +%s)
  status=0
  FM_HOME="$home" PATH="$fakebin:$PATH" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_SUPERVISION_ENGINE_CLAUDE_BIN="$fakebin/engine" FM_SUPERVISION_HOST_TURN_TIMEOUT=25 FM_SUPERVISION_ENGINE_GRACE=1 \
    FM_SECONDMATE_CHECKPOINT_MAX=15 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$fakebin/codex" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      "$0" --seconds 60
    ' "$CHECKPOINT" >"$home/out.txt" 2>"$home/err.txt" || status=$?
  elapsed=$(( $(date +%s) - start ))
  wait
  expect_code 0 "$status" "a secondmate host checkpoint with an away close: $(cat "$home/out.txt" "$home/err.txt")"
  [ "$elapsed" -le 20 ] || fail "a secondmate host checkpoint capped at 15s ran ${elapsed}s: $(cat "$home/out.txt" "$home/err.txt")"
  assert_contains "$(cat "$home/out.txt")" "signal: $home/state/demo.status" "the close was not handed to the secondmate"
  assert_absent "$home/engine-calls" "the host ran an engine turn that could outlast the secondmate's cap"
  pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$home/state/.supervision-host" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    fail "a secondmate host checkpoint left its host running"
  fi
  if [ -e "$home/state/.watch.lock/pid" ] && kill -0 "$(cat "$home/state/.watch.lock/pid")" 2>/dev/null; then
    fail "a secondmate host checkpoint left its watcher running"
  fi
  pass "checkpoint: a secondmate's host park never runs an engine turn past its capped bound"
}

test_host_checkpoint_does_not_mask_cleanup_failure() {
  local home kind channel
  home=$(make_host_home host-cleanup-failure)
  for kind in boundary handback; do
    for channel in stdout stderr; do
      printf '%s\n' "$channel" > "$home/cleanup-error"
      run_host_checkpoint "$home" "$kind" --seconds 5
      expect_code 1 "$STATUS" "host $kind with cleanup failure on $channel"
      assert_contains "$(cat "$home/out.txt" "$home/err.txt")" \
        'watcher: recovery state could not be persisted; retaining stale lock evidence' \
        "host checkpoint hid the cleanup failure"
      assert_not_contains "$(cat "$home/out.txt")" 'checkpoint: no actionable wake' \
        "host cleanup failure was reported as quiet success"
      if [ "$kind" = handback ]; then
        [ "$(grep -c '^signal: demo.status$' "$home/out.txt")" -eq 1 ] \
          || fail "cleanup failure lost or duplicated the actionable wake"
      fi
    done
  done
  pass "checkpoint preserves host cleanup failures and their actionable wakes on either output stream"
}

test_host_checkpoint_passes_a_handback_and_reports_a_stand_down() {
  local home
  home=$(make_host_home host-handback)
  run_host_checkpoint "$home" handback --seconds 5
  expect_code 0 "$STATUS" "a handed-back wake is an actionable checkpoint"
  assert_contains "$(cat "$home/out.txt")" $'signal: demo.status\nsupervision-host: the away session could not take this wake' \
    "the wake and its host line must pass through"
  assert_not_contains "$(cat "$home/out.txt")" "watcher: started" "the host's cycle status is not part of the wake"
  run_host_checkpoint "$home" stood-down --seconds 5
  expect_code 1 "$STATUS" "a host that stood down is a failed checkpoint"
  assert_contains "$(cat "$home/out.txt")" "supervision-host stood down" "the stand-down must be shown"
  pass "checkpoint: a handed-back wake passes through, and a host stand-down is a failure"
}

# The Codex owner stays file-gated: without config/supervision-host, or with
# config/supervision-host-off, the checkpoint never runs the host.
test_host_checkpoint_needs_the_file_and_honors_off() {
  local home line
  home=$(make_host_home host-gate)
  for line in - off; do
    rm -f "$home/config/supervision-host" "$home/config/supervision-host-off" "$home/host-env"
    [ "$line" = - ] || : > "$home/config/supervision-host-off"
    run_host_checkpoint "$home" boundary --seconds 1
    [ ! -e "$home/host-env" ] || fail "a Codex home whose config/supervision-host is ${line/-/absent} ran the supervision host"
  done
  pass "checkpoint: a Codex home without config/supervision-host, or with an off file, never runs the host"
}

# The real host under a fake Codex harness that holds the home's session lock.
make_real_host_home() {
  local home
  home=$(make_home "$1")
  echo claude > "$home/config/supervision-host"
  printf 'project=fixture\nwindow=fm-demo\nharness=codex\n' > "$home/state/demo.meta"
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" enter --words 'fixture; merge nothing' >/dev/null \
    || fail "could not record the fixture away posture"
  mkdir -p "$home/fakebin"
  ln -s /bin/bash "$home/fakebin/codex"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$home/fakebin/tmux"
  chmod +x "$home/fakebin/tmux"
  printf '%s\n' "$home"
}

run_real_arm_forwarding() {
  local mode=$1 home arm i status expected=0 real_cat
  home=$(make_real_host_home "arm-forwarding-$mode")
  real_cat=$(command -v cat) || fail "could not locate cat for forwarding synchronization"
  cat > "$home/fakebin/cat" <<'SH'
#!/usr/bin/env bash
"$FM_TEST_REAL_CAT" "$@" || exit $?
case "$*" in
  *'/.watch-arm-output.'*)
    : > "$FM_HOME/forwarding-ready"
    while [ ! -e "$FM_HOME/forwarding-go" ] && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 0.1; done
    ;;
esac
SH
  chmod +x "$home/fakebin/cat"
  FM_HOME="$home" PATH="$home/fakebin:$PATH" FM_TEST_REAL_CAT="$real_cat" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "${CHECKPOINT%/*}/fm-watch-arm.sh" >"$home/out.txt" 2>"$home/err.txt" &
  arm=$!
  i=0
  while ! grep -q '^watcher: started pid=' "$home/out.txt" && [ "$i" -lt 1000 ]; do sleep 0.1; i=$((i + 1)); done
  grep -q '^watcher: started pid=' "$home/out.txt" || fail "forwarding fixture never confirmed its watcher"
  printf 'working: forwarding fixture\n' > "$home/state/demo.status"
  i=0
  while [ ! -e "$home/forwarding-ready" ] && [ "$i" -lt 1000 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$home/forwarding-ready" ] || fail "the real arm never forwarded its completed capture"
  cp "$home/state/.wake-queue" "$home/queued-before-term"
  if [ "$mode" = TERM ]; then
    expected=143
    kill -TERM "$arm" || fail "could not signal the forwarding arm"
  fi
  : > "$home/forwarding-go"
  status=0
  wait_for_exit "$arm" 200 || status=$?
  expect_code "$expected" "$status" "$mode forwarding exit: $(cat "$home/out.txt" "$home/err.txt")"
  [ "$(grep -c '^signal: .*demo.status' "$home/out.txt")" -eq 1 ] || fail "$mode forwarding emitted the real wake more than once: $(cat "$home/out.txt")"
  cmp -s "$home/queued-before-term" "$home/state/.wake-queue" || fail "$mode forwarding changed the queued work"
  for i in "$home/state"/.watch-arm-output.*; do [ ! -e "$i" ] || fail "$mode forwarding retained a consumed capture"; done
  pass "$mode during real arm forwarding preserves exactly one wake and its queue"
}

test_real_arm_forwarding_is_signal_safe() {
  run_real_arm_forwarding normal
  run_real_arm_forwarding TERM
}

# shellcheck disable=SC2016
run_real_host_cleanup_failure() {
  local kind=$1 cleanup_bound=${2:-2} home fakebin checkpoint_pid holder watcher first i status holder_status pending=0 capture arm
  home=$(make_real_host_home "host-retirement-$kind-$cleanup_bound")
  fakebin="$home/fakebin"
  cat > "$fakebin/engine" <<'SH'
#!/usr/bin/env bash
: > "$FM_HOME/engine-ready"
while [ ! -e "$FM_HOME/engine-go" ] && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 0.1; done
exit 3
SH
  chmod +x "$fakebin/tmux" "$fakebin/engine"
  if [ "$kind" = boundary ]; then
    cat > "$home/state/retirement.check.sh" <<'SH'
#!/usr/bin/env bash
: > "$FM_HOME/retirement-check-ready"
sleep "$FM_TEST_STUB_MAX_BLOCK_SECONDS"
SH
    chmod 0700 "$home/state/retirement.check.sh"
    FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" retirement >/dev/null \
      || fail "could not register the retirement check"
  fi
  echo 0 > "$home/park-clock"
  FM_HOME="$home" PATH="$fakebin:$PATH" FM_POLL=1 FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=120 FM_HEARTBEAT=999999 \
    FM_CODEX_WATCH_CHECKPOINT_AWAY=120 FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" \
    FM_SUPERVISION_HOST_TURN_TIMEOUT=60 FM_SUPERVISION_ENGINE_GRACE=1 \
    FM_SUPERVISION_ENGINE_CLAUDE_BIN="$fakebin/engine" FM_WATCHER_CLEANUP_LOCK_BOUND="$cleanup_bound" \
    "$fakebin/codex" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      "$0" --seconds 120
    ' "$CHECKPOINT" >"$home/out.txt" 2>"$home/err.txt" &
  checkpoint_pid=$!
  i=0
  while [ "$i" -lt 1000 ]; do
    if grep -Eq '^watcher: started pid=[0-9]+ \(beacon fresh\)' "$home/state"/.supervision-host-arm.* 2>/dev/null \
      && [ -s "$home/state/.watch.lock/pid" ]; then break; fi
    sleep 0.1
    i=$((i + 1))
  done
  if [ "$i" -eq 1000 ]; then
    kill -TERM "$checkpoint_pid" 2>/dev/null || true
    wait_for_exit "$checkpoint_pid" 100 >/dev/null 2>&1 || true
    fail "real host did not confirm its watcher: $(cat "$home/out.txt" "$home/err.txt")"
  fi
  first=$(cat "$home/state/.watch.lock/pid")
  watcher=$first
  if [ "$kind" = boundary ]; then
    i=0
    while [ ! -e "$home/retirement-check-ready" ] && [ "$i" -lt 1000 ]; do sleep 0.1; i=$((i + 1)); done
    [ -e "$home/retirement-check-ready" ] || fail "watcher did not reach its active check before retirement"
  else
    printf 'working: retirement fixture\n' > "$home/state/demo.status"
    i=0
    while [ ! -e "$home/engine-ready" ] && [ "$i" -lt 1000 ]; do sleep 0.1; i=$((i + 1)); done
    [ -e "$home/engine-ready" ] || fail "real host did not reach its engine with a confirmed successor"
    watcher=$(cat "$home/state/.watch.lock/pid")
    [ "$watcher" != "$first" ] || fail "the hand-back fixture did not start a successor"
  fi
  kill -0 "$watcher" 2>/dev/null || fail "confirmed watcher exited before lock contention"
  FM_HOME="$home" bash -c '
    . "$1"
    fm_lock_acquire_wait "$FM_HOME/state/.watcher-down.lock" || exit 1
    : > "$FM_HOME/retirement-lock-held"
    while kill -0 "$2" 2>/dev/null && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 0.1; done
    fm_lock_release "$FM_HOME/state/.watcher-down.lock"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$watcher" &
  holder=$!
  i=0
  while [ ! -e "$home/retirement-lock-held" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$home/retirement-lock-held" ] || fail "fixture did not acquire the retirement lock"
  case "$kind" in
    boundary) echo 120 > "$home/park-clock" ;;
    handback) : > "$home/engine-go" ;;
    interrupted) kill -TERM "$(awk -F '\t' '$1 == "host" {print $2}' "$home/state/.supervision-host")" ;;
  esac
  status=0
  wait "$checkpoint_pid" || status=$?
  expect_code 1 "$status" "real host $kind cleanup failure checkpoint exit"
  # The watcher can finish after the host retains an unfinished retirement.
  # Its retained arm record, not later watcher liveness, owns that result.
  arm=$(awk -F '\t' '$1 == "arm" { print $2; exit }' "$home/state/.supervision-host" 2>/dev/null || true)
  if [ -n "$arm" ]; then
    pending=1
    capture=
    for capture in "$home/state"/.supervision-host-arm.*; do [ -f "$capture" ] && break; done
    [ -f "$capture" ] || fail "unfinished retirement discarded its capture"
    if kill -0 "$watcher" 2>/dev/null; then
      kill -TERM "$arm" || fail "unfinished retirement lost its owned arm"
      sleep 0.2
      if kill -0 "$watcher" 2>/dev/null; then
        is_live_non_zombie "$arm" || fail "a repeated stop killed the retiring arm"
      fi
    fi
    assert_contains "$(cat "$home/out.txt")" 'did not finish retirement; retaining its capture and process record' \
      "unfinished retirement did not explain its retained evidence"
  fi
  holder_status=0
  wait_for_exit "$holder" $((cleanup_bound * 20 + 100)) >/dev/null 2>&1 || holder_status=$?
  expect_code 0 "$holder_status" "retirement lock holder exit"
  [ "$(cat "$home/state/.watch.lock/pid")" = "$watcher" ] || fail "retirement discarded stale recovery evidence"
  ! kill -0 "$watcher" 2>/dev/null || fail "retirement left the owned watcher alive"
  if [ "$kind" = boundary ]; then
    assert_grep 'boundary' "$home/state/.supervision-host.log" "fixture did not reach the park boundary"
  else
    assert_grep 'demo.status' "$home/state/.wake-queue" "retirement lost the durable wake"
    if [ "$kind" = handback ]; then
      [ "$(grep -c '^signal: .*demo.status' "$home/out.txt")" -eq 1 ] || fail "hand-back lost or repeated its wake reason"
      assert_contains "$(cat "$home/out.txt")" 'the engine turn failed (exit 3); this wake is yours' "fixture did not reach the failed-engine hand-back"
    fi
  fi
  if [ "$pending" -eq 1 ]; then
    i=0
    while is_live_non_zombie "$arm" && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
    ! is_live_non_zombie "$arm" || fail "retained arm did not finish after watcher cleanup"
    assert_contains "$(cat "$capture")" 'watcher: recovery state could not be persisted; retaining stale lock evidence' \
      "unfinished retirement did not retain the late cleanup diagnostic"
  else
    assert_contains "$(cat "$home/out.txt")" \
      'supervision-host: watcher: recovery state could not be persisted; retaining stale lock evidence' \
      "real host $kind discarded its retirement diagnostic"
  fi
  assert_not_contains "$(cat "$home/out.txt")" 'checkpoint: no actionable wake' "failed retirement was reported as quiet"
  pass "real host $kind preserves watcher retirement failures and stale recovery evidence"
}

test_real_host_retirement_preserves_cleanup_failures() {
  run_real_host_cleanup_failure boundary
  run_real_host_cleanup_failure handback
  run_real_host_cleanup_failure interrupted
  run_real_host_cleanup_failure boundary 30
  run_real_host_cleanup_failure handback 30
}

# shellcheck disable=SC2016
run_real_host_signal_close() {
  local kind=$1 cleanup_bound=${2:-2} home checkpoint_pid holder watcher arm i status real_mv expected_status=1
  home=$(make_real_host_home "host-signal-$kind-$cleanup_bound")
  real_mv=$(command -v mv) || fail "could not locate mv for delivery synchronization"
  if [ "$cleanup_bound" -gt 5 ]; then
    cat > "$home/fakebin/cat" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "$FM_HOME/state/.watcher-down.lock/pid" ] && [ -e "$FM_HOME/observe-cleanup-wait" ]; then
  : > "$FM_HOME/cleanup-wait-ready"
fi
exec /bin/cat "$@"
SH
    chmod +x "$home/fakebin/cat"
  fi
  cat > "$home/fakebin/mv" <<'SH'
#!/usr/bin/env bash
last=
for last in "$@"; do :; done
if [ "$last" = "$FM_HOME/state/.watch-deliveries.log" ]; then
  : > "$FM_HOME/completed-output-ready"
  while [ ! -e "$FM_HOME/completed-output-go" ] && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 0.1; done
fi
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$home/fakebin/mv"
  cat > "$home/fakebin/engine" <<'SH'
#!/usr/bin/env bash
set -eu
: > "$FM_HOME/engine-called"
drain=$("$FM_REPO/bin/fm-wake-drain.sh" 2>&1)
ack=$(printf '%s\n' "$drain" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' | tail -1)
"$FM_REPO/bin/fm-lease.sh" claim demo >/dev/null
"$FM_REPO/bin/fm-branch-report.sh" --task demo --verdict routine --summary handled >/dev/null
[ -z "$ack" ] || "$FM_REPO/bin/fm-wake-drain.sh" $ack >/dev/null
"$FM_REPO/bin/fm-lease.sh" release demo >/dev/null
echo 120 > "$FM_HOME/park-clock"
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0,"usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1},"session_id":"stub"}\n'
SH
  chmod +x "$home/fakebin/engine"
  echo 0 > "$home/park-clock"
  FM_HOME="$home" FM_REPO="$ROOT" FM_TEST_REAL_MV="$real_mv" FM_WATCH_DELIVERY_MAX_BYTES=1 \
    PATH="$home/fakebin:$PATH" FM_POLL=1 FM_CHECK_INTERVAL=999999 \
    FM_SIGNAL_GRACE=0 FM_HEARTBEAT=999999 FM_CODEX_WATCH_CHECKPOINT_AWAY=120 \
    FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" FM_SUPERVISION_HOST_TURN_TIMEOUT=60 FM_SUPERVISION_ENGINE_GRACE=1 \
    FM_SUPERVISION_ENGINE_CLAUDE_BIN="$home/fakebin/engine" FM_WATCHER_CLEANUP_LOCK_BOUND="$cleanup_bound" \
    "$home/fakebin/codex" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      "$0" --seconds 120
    ' "$CHECKPOINT" >"$home/out.txt" 2>"$home/err.txt" &
  checkpoint_pid=$!
  i=0
  while [ "$i" -lt 1000 ]; do
    if grep -Eq '^watcher: started pid=[0-9]+ \(beacon fresh\)' "$home/state"/.supervision-host-arm.* 2>/dev/null; then break; fi
    sleep 0.1
    i=$((i + 1))
  done
  [ "$i" -lt 1000 ] || fail "completed-close fixture never reached a ready watcher"
  watcher=$(cat "$home/state/.watch.lock/pid")
  printf 'working: completed close fixture\n' > "$home/state/demo.status"
  i=0
  while [ ! -e "$home/completed-output-ready" ] && [ "$i" -lt 1000 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$home/completed-output-ready" ] || fail "watcher did not reach its delivery publication"
  grep -Eq '^signal: .*demo.status' "$home/state"/.watch-arm-output.* \
    || fail "watcher had not emitted its real signal before lock contention"
  assert_grep 'demo.status' "$home/state/.wake-queue" "watcher had not durably queued its real signal"
  cp "$home/state/.wake-queue" "$home/queued-before-retirement"
  FM_HOME="$home" bash -c '
    . "$1"
    fm_lock_acquire_wait "$FM_HOME/state/.watcher-down.lock" || exit 1
    : > "$FM_HOME/completed-lock-held"
    while kill -0 "$2" 2>/dev/null && [ ! -e "$FM_HOME/release-cleanup-lock" ] \
      && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 0.1; done
    fm_lock_release "$FM_HOME/state/.watcher-down.lock"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$watcher" &
  holder=$!
  i=0
  while [ ! -e "$home/completed-lock-held" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$home/completed-lock-held" ] || fail "completed-close fixture did not acquire its marker lock"
  if [ "$cleanup_bound" -gt 5 ]; then
    : > "$home/observe-cleanup-wait"
    : > "$home/completed-output-go"
    i=0
    while [ ! -e "$home/cleanup-wait-ready" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
    [ -e "$home/cleanup-wait-ready" ] || fail "watcher did not reach its contended cleanup lock"
  fi
  case "$kind" in
    predecessor-*)
      arm=$(awk -F '\t' '$1 == "arm" { print $2; exit }' "$home/state/.supervision-host")
      kill -KILL "$(awk -F '\t' '$1 == "host" { print $2; exit }' "$home/state/.supervision-host")" \
        || fail "could not interrupt the predecessor host"
      status=0
      wait_for_exit "$checkpoint_pid" 200 || status=$?
      [ "$status" -ne 0 ] || fail "killed predecessor checkpoint claimed success"
      is_live_non_zombie "$arm" || fail "predecessor did not leave its arm for replacement activation"
      mv "$home/out.txt" "$home/predecessor-out.txt"
      mv "$home/err.txt" "$home/predecessor-err.txt"
      FM_HOME="$home" FM_REPO="$ROOT" FM_TEST_REAL_MV="$real_mv" FM_WATCH_DELIVERY_MAX_BYTES=1 \
        PATH="$home/fakebin:$PATH" FM_POLL=1 FM_CHECK_INTERVAL=999999 \
        FM_SIGNAL_GRACE=0 FM_HEARTBEAT=999999 FM_CODEX_WATCH_CHECKPOINT_AWAY=120 \
        FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" FM_SUPERVISION_HOST_TURN_TIMEOUT=60 FM_SUPERVISION_ENGINE_GRACE=1 \
        FM_SUPERVISION_ENGINE_CLAUDE_BIN="$home/fakebin/engine" FM_WATCHER_CLEANUP_LOCK_BOUND="$cleanup_bound" \
        "$home/fakebin/codex" -c '
          printf "%s\n" "$$" > "$FM_HOME/state/.lock"
          "$0" --seconds 120
        ' "$CHECKPOINT" >"$home/out.txt" 2>"$home/err.txt" &
      checkpoint_pid=$!
      ;;
  esac
  if [ "$kind" != completed-failure ]; then
    if [ "$cleanup_bound" -le 5 ]; then
      echo 120 > "$home/park-clock"
      arm=$(awk -F '\t' '$1 == "arm" { print $2; exit }' "$home/state/.supervision-host")
      kill -TERM "$arm" || fail "could not retire the arm with a real signal pending"
      is_live_non_zombie "$watcher" || fail "watcher finished before controlled retirement"
    elif [ "$kind" = retired-failure ]; then
      echo 120 > "$home/park-clock"
    fi
    if [ "$kind" = retired-clean ] || [ "$kind" = predecessor-clean ]; then
      expected_status=0
      : > "$home/release-cleanup-lock"
      wait_for_exit "$holder" 100 >/dev/null 2>&1 || fail "clean retirement lock holder did not release"
      holder=
    fi
  fi
  : > "$home/completed-output-go"
  status=0
  wait "$checkpoint_pid" || status=$?
  [ -z "$holder" ] || wait_for_exit "$holder" 100 >/dev/null 2>&1 || fail "completed-close lock holder did not exit"
  expect_code "$expected_status" "$status" "$kind checkpoint exit: $(cat "$home/out.txt" "$home/err.txt")"
  [ ! -e "$home/engine-called" ] || fail "$kind reached dispatch"
  [ "$(grep -c '^signal: .*demo.status' "$home/out.txt")" -eq 1 ] || fail "$kind lost or repeated its wake: $(cat "$home/out.txt")"
  cmp -s "$home/queued-before-retirement" "$home/state/.wake-queue" || fail "$kind changed its durable wake rows"
  if [ "$kind" = retired-clean ] || [ "$kind" = predecessor-clean ]; then
    assert_absent "$home/state/.watch.lock/pid" "clean retirement retained a watcher lock"
    assert_not_contains "$(cat "$home/out.txt" "$home/err.txt")" 'recovery state could not be persisted' "clean retirement reported cleanup failure"
  else
    assert_contains "$(cat "$home/out.txt")" 'supervision-host: watcher: recovery state could not be persisted; retaining stale lock evidence' \
      "$kind lost its diagnostic"
    [ "$(cat "$home/state/.watch.lock/pid")" = "$watcher" ] || fail "$kind discarded stale recovery evidence"
  fi
  ! is_live_non_zombie "$watcher" || fail "$kind left its watcher alive"
  assert_not_contains "$(cat "$home/out.txt")" 'checkpoint: no actionable wake' "$kind became quiet success"
  if [ "$kind" != completed-failure ]; then
    case "$kind" in
      predecessor-clean)
        assert_contains "$(cat "$home/out.txt")" 'a predecessor watcher already delivered this wake' "$kind did not hand the original wake back"
        ;;
      predecessor-failure) ;;
      *) assert_grep 'boundary' "$home/state/.supervision-host.log" "$kind did not reach the park boundary" ;;
    esac
    assert_grep $'\tsignal=TERM\treason=arm-interrupted\t' "$home/state/.watch-cycle-exits.log" "$kind did not reach the arm signal-close boundary"
  fi
  pass "$kind preserves one real signal and durable wake with its cleanup result"
}

test_real_host_completed_close_preserves_cleanup_failure() {
  run_real_host_signal_close completed-failure
}

test_real_host_retired_signal_preserves_wake() {
  run_real_host_signal_close retired-clean
  run_real_host_signal_close retired-failure
}

test_real_host_predecessor_capture_preserves_wake() {
  run_real_host_signal_close predecessor-clean
  run_real_host_signal_close predecessor-failure
  run_real_host_signal_close predecessor-failure 8
  run_real_host_signal_close predecessor-failure 30
}

test_real_host_forced_retirement_preserves_wake() {
  run_real_host_signal_close retired-failure 8
  run_real_host_signal_close retired-failure 30
}

start_orphaned_test_watcher() {
  local home=$1 tag=$2 predecessor=${3:-} arm i real_mv real_mktemp
  real_mv=$(command -v mv)
  real_mktemp=$(command -v mktemp)
  FM_HOME="$home" FM_TEST_REAL_MV="$real_mv" FM_TEST_REAL_MKTEMP="$real_mktemp" PATH="$home/fakebin:$PATH" \
    FM_WATCH_PREDECESSOR_ARM_PID="$predecessor" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_WATCHER_CLEANUP_LOCK_BOUND=2 FM_WATCH_DELIVERY_MAX_BYTES=4096 FM_ARM_CONFIRM_TIMEOUT=30 \
    "${CHECKPOINT%/*}/fm-watch-arm.sh" >"$home/$tag.out" 2>"$home/$tag.err" &
  arm=$!
  i=0
  while ! grep -q '^watcher: started pid=' "$home/$tag.out" && [ "$i" -lt 1000 ]; do sleep 0.1; i=$((i + 1)); done
  grep -q '^watcher: started pid=' "$home/$tag.out" || fail "original arm did not confirm a healthy watcher: $(cat "$home/$tag.out" "$home/$tag.err")"
  cp "$home/state/.watch.lock/pid" "$home/$tag.pid"
  cp "$home/state/.watch.lock/pid-identity" "$home/$tag.identity"
  kill -KILL "$arm" || fail "could not terminate the original watcher arm"
  wait "$arm" 2>/dev/null || true
  FM_HOME="$home" bash -c '. "$1"; fm_watcher_healthy "$FM_HOME/state" "$2" 300 "$FM_HOME"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "${CHECKPOINT%/*}/fm-watch.sh" || fail "the watcher did not remain healthy after its original arm died"
  ORPHANED_WATCHER=$(cat "$home/$tag.pid")
}

# shellcheck disable=SC2016
run_real_attached_host_cleanup() {
  local kind=$1 order=${2:-} home checkpoint_pid watcher first_arm holder i status expected=1 source_tag=original real_mv real_mktemp real_cat wake_count=0
  home=$(make_real_host_home "host-attached-$kind${order:+-$order}")
  fm_test_track_watcher_state "$home/state"
  real_mv=$(command -v mv)
  real_mktemp=$(command -v mktemp)
  real_cat=$(command -v cat)
  cat > "$home/fakebin/cat" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'/.watch.lock/pid')
    if [ -e "$FM_HOME/stop-order" ] && [ -e "$FM_HOME/retiring-arm.pid" ] \
      && grep -q "arm_pid=$("$FM_TEST_REAL_CAT" "$FM_HOME/retiring-arm.pid").*reason=arm-interrupted" "$FM_HOME/state/.watch-cycle-exits.log" 2>/dev/null; then
      case "$(ps -o args= -p "$PPID" 2>/dev/null)" in
        *fm-watch-arm.sh*)
          if mkdir "$FM_HOME/ordered-read-claimed" 2>/dev/null; then
            if [ "$("$FM_TEST_REAL_CAT" "$FM_HOME/stop-order")" = stop-first ]; then
              "$FM_TEST_REAL_CAT" "$@" > "$FM_HOME/ordered-pid"
            fi
            : > "$FM_HOME/ordered-read-ready"
            while [ ! -e "$FM_HOME/ordered-read-go" ] && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 0.05; done
            if [ -e "$FM_HOME/ordered-pid" ]; then
              exec "$FM_TEST_REAL_CAT" "$FM_HOME/ordered-pid"
            fi
            [ ! -e "$FM_HOME/state/.watch.lock/pid" ] || exit 1
            : > "$FM_HOME/ordered-read-after-cleanup"
          fi
          ;;
      esac
    fi
    ;;
esac
exec "$FM_TEST_REAL_CAT" "$@"
SH
  printf '%s\tunrelated-fixture\t%04096d\n' "$$" 0 > "$home/state/.watch-deliveries.log"
  cat > "$home/fakebin/mv" <<'SH'
#!/usr/bin/env bash
last=
for last in "$@"; do :; done
if [ "$last" = "$FM_HOME/state/.watch-deliveries.log" ] && [ -e "$FM_HOME/block-delivery" ]; then
  : > "$FM_HOME/external-output-ready"
  while [ ! -e "$FM_HOME/external-output-go" ] && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 0.1; done
fi
exec "$FM_TEST_REAL_MV" "$@"
SH
  cat > "$home/fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'/.supervision-host-arm.XXXXXX'*)
    if [ -e "$FM_HOME/pause-successor" ] && [ -e "$FM_HOME/first-arm-allocated" ]; then
      : > "$FM_HOME/successor-allocation-ready"
      while [ ! -e "$FM_HOME/successor-allocation-go" ] && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 0.1; done
    fi
    : > "$FM_HOME/first-arm-allocated"
    ;;
esac
exec "$FM_TEST_REAL_MKTEMP" "$@"
SH
  cat > "$home/fakebin/engine" <<'SH'
#!/usr/bin/env bash
: > "$FM_HOME/engine-ready"
while [ ! -e "$FM_HOME/engine-go" ] && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 0.1; done
exit 3
SH
  chmod +x "$home/fakebin/cat" "$home/fakebin/mv" "$home/fakebin/mktemp" "$home/fakebin/engine"
  case "$kind" in
    *clean|completed-mismatch|completed-home-mismatch|completed-path-mismatch) expected=0 ;;
  esac
  export FM_TEST_REAL_CAT="$real_cat"
  case "$kind" in successor-*) : > "$home/pause-successor" ;; esac
  echo 0 > "$home/park-clock"
  start_orphaned_test_watcher "$home" original
  watcher=$ORPHANED_WATCHER
  FM_HOME="$home" FM_TEST_REAL_MV="$real_mv" FM_TEST_REAL_MKTEMP="$real_mktemp" PATH="$home/fakebin:$PATH" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT=5 FM_CODEX_WATCH_CHECKPOINT_AWAY=120 FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" \
    FM_SUPERVISION_HOST_TURN_TIMEOUT=60 FM_SUPERVISION_ENGINE_GRACE=1 FM_SUPERVISION_ENGINE_CLAUDE_BIN="$home/fakebin/engine" \
    FM_WATCHER_CLEANUP_LOCK_BOUND=2 "$home/fakebin/codex" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      "$0" --seconds 120
    ' "$CHECKPOINT" >"$home/out.txt" 2>"$home/err.txt" &
  checkpoint_pid=$!
  i=0
  while ! grep -q "^watcher: attached pid=$watcher " "$home/state"/.supervision-host-arm.* 2>/dev/null && [ "$i" -lt 1000 ]; do sleep 0.1; i=$((i + 1)); done
  grep -q "^watcher: attached pid=$watcher " "$home/state"/.supervision-host-arm.* \
    || fail "the real host never attached to the orphaned healthy watcher"
  first_arm=$(awk -F '\t' '$1 == "arm" { print $2; exit }' "$home/state/.supervision-host")
  case "$kind" in
    successor-*)
      printf 'working: attached successor fixture\n' > "$home/state/demo.status"
      i=0
      while [ ! -e "$home/successor-allocation-ready" ] && [ "$i" -lt 1000 ]; do sleep 0.1; i=$((i + 1)); done
      [ -e "$home/successor-allocation-ready" ] || fail "the host did not reach successor allocation"
      case "$kind" in
        successor-signal-*)
          printf '%s\tunrelated-successor-fixture\t%04096d\n' "$$" 0 >> "$home/state/.watch-deliveries.log"
          : > "$home/block-delivery"
          ;;
      esac
      start_orphaned_test_watcher "$home" successor "$first_arm"
      source_tag=successor
      watcher=$ORPHANED_WATCHER
      : > "$home/successor-allocation-go"
      i=0
      while [ ! -e "$home/engine-ready" ] && [ "$i" -lt 1000 ]; do sleep 0.1; i=$((i + 1)); done
      [ -e "$home/engine-ready" ] || fail "host did not reach its engine after verifying the successor"
      grep -q "^watcher: attached pid=$watcher " "$home/state"/.supervision-host-arm.* \
        || fail "the host successor did not attach to the second orphaned watcher"
      wake_count=1
      if [ -n "$order" ]; then
        first_arm=$(awk -F '\t' '$1 == "arm" { print $2; exit }' "$home/state/.supervision-host")
      fi
      ;;
  esac
  case "$kind" in
    completed-*|boundary-signal-*|successor-signal-*)
      : > "$home/block-delivery"
      case "$kind" in completed-*) : > "$home/state/.afk" ;; esac
      printf 'working: attached completion fixture\n' > "$home/state/demo.status"
      i=0
      while [ ! -e "$home/external-output-ready" ] && [ "$i" -lt 1000 ]; do sleep 0.1; i=$((i + 1)); done
      [ -e "$home/external-output-ready" ] || fail "the attached watcher did not print its real signal"
      grep -q '^signal: .*demo.status' "$home/state"/.watch-arm-output.* || fail "the original capture contains no real watcher signal"
      wake_count=$((wake_count + 1))
      ;;
  esac
  if [ -n "$order" ]; then
    printf '%s\n' "$first_arm" > "$home/retiring-arm.pid"
    printf '%s\n' "$order" > "$home/stop-order"
  fi
  : > "$home/queued-before-stop"
  [ ! -f "$home/state/.wake-queue" ] || cp "$home/state/.wake-queue" "$home/queued-before-stop"
  FM_HOME="$home" bash -c '
    . "$1"
    fm_lock_acquire_wait "$FM_HOME/state/.watcher-down.lock" || exit 1
    : > "$FM_HOME/attached-lock-held"
    while kill -0 "$2" 2>/dev/null && [ ! -e "$FM_HOME/release-attached-lock" ] && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 0.1; done
    fm_lock_release "$FM_HOME/state/.watcher-down.lock"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$watcher" &
  holder=$!
  i=0
  while [ ! -e "$home/attached-lock-held" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$home/attached-lock-held" ] || fail "attached cleanup fixture did not hold the recovery lock"
  case "$kind" in
    completed-mismatch) printf 'replacement-identity\n' > "$home/state/.watch.lock/pid-identity" ;;
    completed-home-mismatch) printf 'foreign-home\n' > "$home/state/.watch.lock/fm-home" ;;
    completed-path-mismatch) printf 'foreign-watcher\n' > "$home/state/.watch.lock/watcher-path" ;;
  esac
  case "$kind" in
    *clean)
      : > "$home/release-attached-lock"
      wait_for_exit "$holder" 100 || fail "the clean attached fixture did not release its lock"
      holder=
      ;;
  esac
  case "$kind" in
    successor-*) : > "$home/engine-go" ;;
    completed-*) : > "$home/external-output-go" ;;
    boundary-signal-*)
      echo 120 > "$home/park-clock"
      i=0
      while ! grep -q "arm_pid=$first_arm.*reason=arm-interrupted" "$home/state/.watch-cycle-exits.log" 2>/dev/null && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
      grep -q "arm_pid=$first_arm.*reason=arm-interrupted" "$home/state/.watch-cycle-exits.log" \
        || fail "the host did not retire its attached arm before watcher completion"
      [ -n "$order" ] || : > "$home/external-output-go"
      ;;
    *) echo 120 > "$home/park-clock" ;;
  esac
  if [ -n "$order" ]; then
    i=0
    while [ ! -e "$home/ordered-read-ready" ] && [ "$i" -lt 300 ]; do sleep 0.05; i=$((i + 1)); done
    [ -e "$home/ordered-read-ready" ] || fail "$kind $order never reached the ordered PID read"
    if [ "$order" = stop-first ]; then
      [ "$(cat "$home/ordered-pid")" = "$watcher" ] || fail "stop did not read the observed watcher before cleanup"
      [ -s "$home/state/.watch.lock/pid" ] || fail "stop-first cleanup ran before the PID read"
      : > "$home/ordered-read-go"
    fi
    : > "$home/external-output-go"
    if [ "$order" = cleanup-first ]; then
      i=0
      while [ -e "$home/state/.watch.lock/pid" ] && [ "$i" -lt 300 ]; do sleep 0.05; i=$((i + 1)); done
      assert_absent "$home/state/.watch.lock/pid" "cleanup-first did not remove the lock before the PID read"
      : > "$home/ordered-read-go"
    fi
  fi
  status=0
  wait_for_exit "$checkpoint_pid" 600 || status=$?
  [ -z "$holder" ] || wait_for_exit "$holder" 100 || fail "the attached recovery lock holder did not finish"
  if [ "$expected" -ne 0 ] || [[ "$kind" = *mismatch ]]; then
    # Retirement can end the watcher before its own cleanup diagnostic prints.
    # The host must report its matching retained evidence below. Mismatch cases
    # need the original diagnostic to prove the failure the host must decline.
    if [[ "$kind" = *mismatch ]]; then
      assert_contains "$(cat "$home/$source_tag.err")" 'watcher: recovery state could not be persisted; retaining stale lock evidence' \
        "the real watcher did not report failed cleanup through its original owner's stderr"
    fi
    [ "$(cat "$home/state/.watch.lock/pid")" = "$watcher" ] || fail "attached cleanup lost its original process evidence"
  else
    assert_absent "$home/state/.watch.lock/pid" "successful attached cleanup retained the watcher lock"
  fi
  expect_code "$expected" "$status" "attached $kind, original stderr=$(cat "$home/$source_tag.err"), host=$(cat "$home/out.txt" "$home/err.txt")"
  if [ "$order" = cleanup-first ]; then
    [ -e "$home/ordered-read-after-cleanup" ] || fail "the ordered PID read did not follow clean lock removal"
  fi
  [ "$(grep -c '^signal: .*demo.status' "$home/out.txt")" -eq "$wake_count" ] || fail "attached $kind lost or repeated a real wake: $(cat "$home/out.txt")"
  if [ -f "$home/state/.wake-queue" ]; then
    cmp -s "$home/queued-before-stop" "$home/state/.wake-queue" || fail "attached $kind changed its queued work"
  else
    [ ! -s "$home/queued-before-stop" ] || fail "attached $kind removed its queued work"
  fi
  if [ "$expected" -ne 0 ]; then
    assert_contains "$(cat "$home/out.txt" "$home/err.txt")" 'watcher: recovery state could not be persisted; retaining stale lock evidence' \
      "attached $kind hid matching failed cleanup evidence"
    assert_not_contains "$(cat "$home/out.txt")" 'checkpoint: no actionable wake' "attached cleanup failure became quiet success"
  elif [ "$kind" = boundary-clean ]; then
    assert_contains "$(cat "$home/out.txt")" 'checkpoint: no actionable wake within 120s' "successful attached cleanup was not a quiet success"
  else
    assert_not_contains "$(cat "$home/out.txt" "$home/err.txt")" 'recovery state could not be persisted' "nonmatching or released lock was classified as this watcher's cleanup failure"
  fi
  ! is_live_non_zombie "$watcher" || fail "attached cleanup left its watcher alive"
  case "$kind" in
    successor-*) assert_contains "$(cat "$home/out.txt")" 'the engine turn failed (exit 3)' "fixture did not exercise successor retirement" ;;
    *) [ ! -e "$home/engine-ready" ] || fail "attached completion reached engine dispatch" ;;
  esac
  if [ "$kind" = completed-failure ]; then
    status=0
    FM_HOME="$home" "${CHECKPOINT%/*}/fm-watch-arm.sh" --stop >"$home/dead-stop.txt" 2>&1 || status=$?
    expect_code 1 "$status" "explicit stop must retain an already-dead watcher's cleanup failure"
    assert_contains "$(cat "$home/dead-stop.txt")" 'recovery state could not be persisted' "explicit stop lost retained failed-cleanup evidence"
    [ "$(grep -c '^signal: .*demo.status' "$home/dead-stop.txt")" -eq 1 ] || fail "explicit stop lost or repeated the retained real wake"
  fi
  pass "real attached $kind preserves the cleanup result, original wake and queue"
}

test_stop_preserves_foreign_process_identity_guards() {
  local field home foreign identity status
  for field in fm-home watcher-path pid-identity; do
    home=$(make_home "stop-identity-$field")
    mkdir "$home/state/.watch.lock"
    sleep "$FM_TEST_STUB_MAX_BLOCK_SECONDS" &
    foreign=$!
    identity=$(FM_HOME="$home" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$foreign") \
      || fail "could not identify the fixture process"
    printf '%s\n' "$foreign" > "$home/state/.watch.lock/pid"
    printf '%s\n' "$home" > "$home/state/.watch.lock/fm-home"
    printf '%s\n' "${CHECKPOINT%/*}/fm-watch.sh" > "$home/state/.watch.lock/watcher-path"
    printf '%s\n' "$identity" > "$home/state/.watch.lock/pid-identity"
    printf 'foreign-value\n' > "$home/state/.watch.lock/$field"
    status=0
    FM_HOME="$home" "${CHECKPOINT%/*}/fm-watch-arm.sh" --stop >"$home/out.txt" 2>"$home/err.txt" || status=$?
    expect_code 0 "$status" "$field refusal: $(cat "$home/out.txt" "$home/err.txt")"
    is_live_non_zombie "$foreign" || fail "stop signalled a process despite a mismatched $field"
    assert_not_contains "$(cat "$home/out.txt" "$home/err.txt")" 'recovery state could not be persisted' "a foreign process was labelled as this watcher's failed cleanup"
    kill -TERM "$foreign"
    wait "$foreign" 2>/dev/null || true
  done
  pass "explicit stop preserves home, watcher-path and process-identity refusals"
}

test_real_attached_host_cleanup() {
  local kind
  for kind in boundary-failure boundary-clean boundary-signal-failure completed-failure completed-clean completed-mismatch completed-home-mismatch completed-path-mismatch successor-failure successor-clean; do
    run_real_attached_host_cleanup "$kind"
  done
  for kind in boundary-signal-clean successor-signal-clean; do
    run_real_attached_host_cleanup "$kind" cleanup-first
    run_real_attached_host_cleanup "$kind" stop-first
  done
}

# shellcheck disable=SC2016
run_real_host_startup_failure() {
  local close=$1 home checkpoint_pid i status real_cat failure='watcher: FAILED - FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS must be whole seconds'
  home=$(make_home "host-startup-failure-$close")
  append_wake "$home/state" signal existing 'signal: existing queued work'
  cp "$home/state/.wake-queue" "$home/queued-before-start"
  : > "$home/config/supervision-host"
  mkdir -p "$home/fakebin"
  ln -s /bin/bash "$home/fakebin/codex"
  real_cat=$(command -v cat) || fail "could not locate cat for close synchronization"
  cat > "$home/fakebin/cat" <<'SH'
#!/usr/bin/env bash
if [ "$*" = "$FM_HOME/park-clock" ]; then
  : > "$FM_HOME/boundary-probe-ready"
  while [ ! -e "$FM_HOME/boundary-probe-go" ] && [ "$SECONDS" -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do sleep 0.05; done
fi
exec "$FM_TEST_REAL_CAT" "$@"
SH
  chmod +x "$home/fakebin/cat"
  echo 0 > "$home/park-clock"
  FM_HOME="$home" PATH="$home/fakebin:$PATH" FM_TEST_REAL_CAT="$real_cat" \
    FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=invalid FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" \
    FM_SUPERVISION_HOST_PRIMARY=codex FM_SUPERVISION_HOST_PARK_SECONDS=120 FM_CLOSE_FIXTURE="$close" \
    "$home/fakebin/codex" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      if [ "$FM_CLOSE_FIXTURE" = boundary ]; then
        "$0" --seconds 120
      else
        "$1" park
      fi
    ' "$CHECKPOINT" "${CHECKPOINT%/*}/fm-supervision-host.sh" >"$home/out.txt" 2>"$home/err.txt" &
  checkpoint_pid=$!
  i=0
  while [ ! -e "$home/boundary-probe-ready" ] && [ "$i" -lt 1000 ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$home/boundary-probe-ready" ] || fail "startup failure never reached the close-ordering probe"
  i=0
  while ! grep -q "$failure" "$home/state"/.supervision-host-arm.* 2>/dev/null && [ "$i" -lt 1000 ]; do sleep 0.05; i=$((i + 1)); done
  grep -q "$failure" "$home/state"/.supervision-host-arm.* \
    || fail "the real watcher did not publish its startup failure before close consumption"
  assert_absent "$home/state/.watch.lock/pid" "startup refusal acquired the watcher lock"
  case "$close" in boundary) echo 120 > "$home/park-clock" ;; esac
  : > "$home/boundary-probe-go"
  status=0
  wait_for_exit "$checkpoint_pid" 600 || status=$?
  expect_code 1 "$status" "$close startup failure must stay nonzero: $(cat "$home/out.txt" "$home/err.txt")"
  assert_contains "$(cat "$home/out.txt" "$home/err.txt")" "supervision-host: $failure" \
    "$close discarded the typed startup diagnostic"
  [ "$(grep -c "$failure" "$home/out.txt" "$home/err.txt" | awk -F : '{ n += $NF } END { print n }')" -eq 1 ] \
    || fail "$close lost or repeated the startup diagnostic"
  assert_not_contains "$(cat "$home/out.txt")" 'checkpoint: no actionable wake' "$close startup failure became quiet success"
  ! grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$home/out.txt" \
    || fail "$close startup refusal invented an actionable wake"
  cmp -s "$home/queued-before-start" "$home/state/.wake-queue" || fail "$close startup refusal changed queued work"
  if [ "$close" = boundary ]; then
    assert_contains "$(cat "$home/out.txt")" 'supervision-host: cycle boundary -' "fixture did not retire the failed capture at the park boundary"
  else
    ! grep -q 'pass-through' "$home/state/.supervision-host.log" \
      || fail "completed startup failure bypassed failure classification"
  fi
  pass "real host $close preserves a pre-lock startup failure as nonzero"
}

test_real_host_startup_failures_stay_nonzero() {
  run_real_host_startup_failure boundary
  run_real_host_startup_failure completed
}

# shellcheck disable=SC2016
test_real_host_checkpoint_ends_quietly_at_its_bound() {
  local home fakebin status
  home=$(make_home host-real)
  : > "$home/config/supervision-host"
  fakebin="$TMP_ROOT/host-real-bin"
  mkdir -p "$fakebin"
  ln -s /bin/bash "$fakebin/codex"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$fakebin/codex" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$0" --seconds 4
  ' "$CHECKPOINT" >"$home/out.txt" 2>"$home/err.txt" || status=$?
  expect_code 0 "$status" "a quiet host checkpoint: $(cat "$home/out.txt" "$home/err.txt")"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 4s" "the real host's boundary must read as the quiet line"
  assert_grep '	boundary	' "$home/state/.supervision-host.log" "the host must have ended its own park"
  if [ -e "$home/state/.watch.lock/pid" ] && kill -0 "$(cat "$home/state/.watch.lock/pid")" 2>/dev/null; then
    fail "a host checkpoint left its watcher running"
  fi
  pass "checkpoint: the real host ends its park at the checkpoint bound as a quiet checkpoint"
}

test_interrupted_startup_reports_failed_cleanup
test_preconfirmation_predecessor_retirement_uses_verified_identity
test_quiet_checkpoint_exits_0_cleanly
test_secondmate_checkpoint_bound_is_capped
test_secondmate_checkpoint_returns_for_a_waiting_record
test_secondmate_checkpoint_unwritable_marker_is_a_plain_wait
test_cleanup_persistence_failure_is_not_a_quiet_checkpoint
test_gnu_timeout_runs_the_watcher_bound
test_non_gnu_timeout_uses_gnu_gtimeout
test_non_gnu_timeout_falls_back_to_perl_before_escalating
test_real_perl_shutdown_classification
test_announced_recovery_is_not_reannounced_by_next_checkpoint
test_never_announced_recovery_is_announced_once
test_queue_append_during_checkpoint_still_resurfaces
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_host_checkpoint_bounds_the_park_by_posture
test_host_checkpoint_caps_a_secondmate_park
test_host_checkpoint_does_not_mask_cleanup_failure
test_host_checkpoint_passes_a_handback_and_reports_a_stand_down
test_host_checkpoint_needs_the_file_and_honors_off
test_real_host_completed_close_preserves_cleanup_failure
test_real_host_retired_signal_preserves_wake
test_real_host_predecessor_capture_preserves_wake
test_real_host_forced_retirement_preserves_wake
test_real_arm_forwarding_is_signal_safe
test_real_attached_host_cleanup
test_stop_preserves_foreign_process_identity_guards
test_real_host_retirement_preserves_cleanup_failures
test_real_host_startup_failures_stay_nonzero
test_real_host_secondmate_park_ignores_the_inbox
test_real_host_secondmate_turn_never_outlives_the_cap
test_real_host_checkpoint_ends_quietly_at_its_bound
