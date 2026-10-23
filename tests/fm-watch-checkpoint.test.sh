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

test_perl_timeout_fallback_honors_cleanup_bound_before_escalating() {
  local home fallback_bin tool tool_path status watcher_pid
  home=$(make_home perl-fallback)
  fallback_bin="$home/fallback-bin"
  mkdir -p "$home/root/bin" "$fallback_bin"
  cp "$CHECKPOINT" "$home/root/bin/fm-watch-checkpoint.sh"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$home/root/bin/fm-supervision-engine-lib.sh"
  for tool in bash dirname mktemp rm perl grep cat; do
    tool_path=$(command -v "$tool") || fail "could not locate $tool for the Perl fallback fixture"
    ln -s "$tool_path" "$fallback_bin/$tool"
  done
  cat > "$home/root/bin/fm-watch.sh" <<'PL'
#!/usr/bin/env perl
use strict;
use warnings;
$SIG{INT} = 'IGNORE';
open my $pid_file, '>', "$ENV{FM_HOME}/watcher.pid" or die "open pid file: $!";
printf {$pid_file} "%s\n", $$;
close $pid_file;
sleep 7;
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

  expect_code 0 "$status" "Perl fallback checkpoint exit"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 1s" \
    "Perl fallback did not return a quiet checkpoint"
  [ -e "$home/cleanup-reached" ] || fail "the Perl fallback killed the watcher before its 8-second cleanup bound"
  [ ! -e "$home/natural-exit" ] || fail "the INT-ignoring watcher exited naturally instead of being killed"
  [ -s "$home/watcher.pid" ] || fail "the INT-ignoring watcher did not start"
  watcher_pid=$(cat "$home/watcher.pid")
  if kill -0 "$watcher_pid" 2>/dev/null; then
    fail "the INT-ignoring watcher survived the Perl fallback escalation"
  fi
  pass "Perl fallback honors the cleanup bound before escalating an INT-ignoring direct watcher"
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
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
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
  local home
  home=$(make_home "$1")
  mkdir -p "$home/root/bin"
  cp "$CHECKPOINT" "$home/root/bin/fm-watch-checkpoint.sh"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$home/root/bin/fm-supervision-engine-lib.sh"
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
  for f in fm-afk-contract.sh fm-classify-lib.sh fm-timeout-lib.sh; do cp "$ROOT/bin/$f" "$home/root/bin/$f"; done
  rm -f "$home/state/.afk-contract"
  FM_HOME="$home" FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter --words 'keep routine wakes off my main' >/dev/null 2>&1 \
    || fail "fixture: could not record quiet mode"
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 0 "$STATUS" "a park beside a quiet record that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/host-env")" 'park=5' "beside a quiet record the host must park for the attended bound"
  pass "checkpoint: an opted-in home runs the host for the checkpoint's bound, raised only while away"
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
  if kill -0 "$watcher" 2>/dev/null; then
    pending=1
    capture=
    for capture in "$home/state"/.supervision-host-arm.*; do [ -f "$capture" ] && break; done
    [ -f "$capture" ] || fail "unfinished retirement discarded its capture"
    awk -F '\t' '$1 == "arm" { found = 1 } END { exit !found }' "$home/state/.supervision-host" \
      || fail "unfinished retirement discarded its process record"
    arm=$(awk -F '\t' '$1 == "arm" { print $2; exit }' "$home/state/.supervision-host")
    kill -TERM "$arm" || fail "unfinished retirement lost its owned arm"
    sleep 0.2
    is_live_non_zombie "$arm" || fail "a repeated stop killed the retiring arm"
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
  local kind=$1 home checkpoint_pid holder watcher arm i status real_mv expected_status=1
  home=$(make_real_host_home "host-signal-$kind")
  real_mv=$(command -v mv) || fail "could not locate mv for delivery synchronization"
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
    FM_SUPERVISION_ENGINE_CLAUDE_BIN="$home/fakebin/engine" FM_WATCHER_CLEANUP_LOCK_BOUND=2 \
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
  if [ "$kind" != completed-failure ]; then
    echo 120 > "$home/park-clock"
    arm=$(awk -F '\t' '$1 == "arm" { print $2; exit }' "$home/state/.supervision-host")
    kill -TERM "$arm" || fail "could not retire the arm with a real signal pending"
    is_live_non_zombie "$watcher" || fail "watcher finished before controlled retirement"
    if [ "$kind" = retired-clean ]; then
      expected_status=0
      : > "$home/release-cleanup-lock"
      wait_for_exit "$holder" 100 >/dev/null 2>&1 || fail "clean retirement lock holder did not release"
    fi
  fi
  : > "$home/completed-output-go"
  status=0
  wait "$checkpoint_pid" || status=$?
  wait_for_exit "$holder" 100 >/dev/null 2>&1 || fail "completed-close lock holder did not exit"
  expect_code "$expected_status" "$status" "$kind checkpoint exit: $(cat "$home/out.txt" "$home/err.txt")"
  [ ! -e "$home/engine-called" ] || fail "$kind reached dispatch"
  [ "$(grep -c '^signal: .*demo.status' "$home/out.txt")" -eq 1 ] || fail "$kind lost or repeated its wake: $(cat "$home/out.txt")"
  cmp -s "$home/queued-before-retirement" "$home/state/.wake-queue" || fail "$kind changed its durable wake rows"
  if [ "$kind" = retired-clean ]; then
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
    assert_grep 'boundary' "$home/state/.supervision-host.log" "$kind did not reach the park boundary"
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

test_quiet_checkpoint_exits_0_cleanly
test_cleanup_persistence_failure_is_not_a_quiet_checkpoint
test_perl_timeout_fallback_honors_cleanup_bound_before_escalating
test_announced_recovery_is_not_reannounced_by_next_checkpoint
test_never_announced_recovery_is_announced_once
test_queue_append_during_checkpoint_still_resurfaces
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_host_checkpoint_bounds_the_park_by_posture
test_host_checkpoint_does_not_mask_cleanup_failure
test_host_checkpoint_passes_a_handback_and_reports_a_stand_down
test_host_checkpoint_needs_the_file_and_honors_off
test_real_host_completed_close_preserves_cleanup_failure
test_real_host_retired_signal_preserves_wake
test_real_host_retirement_preserves_cleanup_failures
test_real_host_checkpoint_ends_quietly_at_its_bound
