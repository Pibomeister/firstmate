#!/usr/bin/env bash
# Behavior tests for the deadlines on supervision paths: a send whose doorbell
# hangs after durable enqueue still returns "durably recorded" within its bound
# and frees the home's lease-command lock for the next send; a pending-reply
# recovery send that reaches its bound records an unknown outcome, never a
# failure; a watcher whose wake-queue lock is held by a live process outside its
# tree keeps beating and defers that work, then delivers it once the holder
# goes; a bounded runner stopped by an outer bound stops its own command; and
# the herdr server a bounded call may start does not share that call's process
# group. Every blocking dependency is a real process the test controls, and
# every case runs under an outer bound so a regression fails instead of hanging.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-supervision-bounds)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Lock-holder fixtures are stopped even when a case fails part-way.
FIXTURE_PIDS=
suite_cleanup() {
  local p
  for p in $FIXTURE_PIDS; do kill "$p" 2>/dev/null; done
  fm_test_cleanup
}
trap suite_cleanup EXIT

# A watcher on <state> with tight cadences, extra environment as NAME=value args.
watch_start() {  # <state> <fakebin> <out> [NAME=value...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  env PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 "$@" "$ROOT/bin/fm-watch.sh" > "$out" &
}

# 0 once <pid>'s beacon has been touched <count> more times while it stays alive.
wait_beats() {  # <state> <pid> <count> <max-ticks>
  local beat="$1/.last-watcher-beat" n=0 i=0
  while [ "$n" -lt "$3" ]; do
    rm -f "$beat"
    while [ ! -e "$beat" ]; do
      kill -0 "$2" 2>/dev/null || return 1
      [ "$i" -lt "$4" ] || return 1
      sleep 0.1
      i=$((i + 1))
    done
    n=$((n + 1))
  done
}

# A tmux stand-in whose capture hangs on demand, so the doorbell's composer
# read blocks only after the steer is durably enqueued.
make_send_stubs() {  # <dir> -> fakebin
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ "${FM_FAKE_HANG_CAPTURE:-0}" = 1 ]; then command -p sleep 600; fi
    printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf 'fm-t1\nfm-t2\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

test_hung_doorbell_returns_delivered_and_frees_the_lock() {
  local dir home fb err1 err2 pid1 start1 start2 rc1 elapsed1 elapsed2 i
  dir="$TMP_ROOT/doorbell"
  home="$dir/home"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"   # the lease guard holds the home lock here
  fb=$(make_send_stubs "$dir")
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
  fm_write_meta "$home/state/t2.meta" "window=sess:fm-t2" "kind=ship" "harness=claude"
  err1="$dir/send1.err"
  err2="$dir/send2.err"
  start1=$(date +%s)
  fm_run_timed 40 env -u PI_CODING_AGENT -u FM_SUPERVISION_ACTOR PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_SEND_SETTLE=0 FM_SEND_RING_BUDGET=3 FM_FAKE_HANG_CAPTURE=1 \
    "$ROOT/bin/fm-send.sh" t1 "first steer" >/dev/null 2>"$err1" &
  pid1=$!
  for i in $(seq 1 50); do [ -f "$home/state/t1.inbox/001.msg" ] && break; sleep 0.1; done
  [ -f "$home/state/t1.inbox/001.msg" ] || fail "the first steer was not enqueued before its doorbell"
  start2=$(date +%s)
  fm_run_timed 40 env -u PI_CODING_AGENT -u FM_SUPERVISION_ACTOR PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_SEND_SETTLE=0 FM_SEND_RING_BUDGET=3 \
    "$ROOT/bin/fm-send.sh" t2 "second steer" >/dev/null 2>"$err2" &
  for i in $(seq 1 150); do [ -f "$home/state/t2.inbox/001.msg" ] && break; sleep 0.1; done
  elapsed2=$(( $(date +%s) - start2 ))
  [ -f "$home/state/t2.inbox/001.msg" ] \
    || fail "a send to another task never enqueued while the first send's doorbell hung (waited ${elapsed2}s)"
  [ "$elapsed2" -le 9 ] || fail "a send to another task waited ${elapsed2}s behind the first send's hung doorbell"
  wait "$pid1"
  rc1=$?
  elapsed1=$(( $(date +%s) - start1 ))
  [ "$rc1" -eq 0 ] || fail "a send whose doorbell hung after enqueue must still exit 0, got $rc1 after ${elapsed1}s: $(cat "$err1")"
  [ "$elapsed1" -le 9 ] || fail "a send whose doorbell hung took ${elapsed1}s with a 3s ring bound"
  assert_contains "$(cat "$err1")" "durably recorded" "the hung-doorbell send must report the steer as durably recorded"
  assert_contains "$(cat "$err1")" "did not reach" "the hung-doorbell send must report the doorbell as not reached"
  wait
  [ "$(find "$home/state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" = 1 ] \
    || fail "the hung-doorbell send must leave exactly one record"
  [ "$(find "$home/state/t2.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" = 1 ] \
    || fail "the second send must leave exactly one record"
  [ ! -e "$home/state/.fm-lease-command.lock" ] || fail "the lease-command lock was not released after the sends returned"
  pass "a hung doorbell after enqueue returns 'durably recorded' within its bound and a send to another task proceeds"
}

recovery_record() {  # <home> -> corr
  local home=$1 corr
  corr=$(fm_pending_reply_create "$home" "$home/state" mate "status of phase 7")
  fm_pending_reply_mark_delivered "$home/state" "$corr"
  fm_pending_reply_observe_busy "$home/state" "$corr" busy
  fm_pending_reply_observe_busy "$home/state" "$corr" idle
  printf '%s\n' "$corr"
}

test_recovery_send_bound_records_unknown_never_failed() {
  local home corr start elapsed rec
  # shellcheck source=bin/fm-pending-reply-lib.sh
  . "$ROOT/bin/fm-pending-reply-lib.sh"
  home="$TMP_ROOT/recovery-unknown"
  mkdir -p "$home/state"
  export FM_PENDING_REPLY_NOW=2000 FM_PENDING_REPLY_GRACE_SECS=0
  # shellcheck disable=SC2329 # invoked through FM_PENDING_REPLY_SEND_HOOK
  hang_hook() { command -p sleep 600; }
  # shellcheck disable=SC2329
  fail_hook() { return 7; }
  export -f hang_hook fail_hook
  corr=$(recovery_record "$home")
  start=$(date +%s)
  # shellcheck disable=SC2016 # expanded by the child shell
  FM_PENDING_REPLY_SEND_HOOK=hang_hook FM_PENDING_REPLY_SEND_BUDGET=3 \
    fm_run_timed 30 bash -c '. "$1"; fm_pending_reply_send_recovery "$2" "$3"' _ \
      "$ROOT/bin/fm-pending-reply-lib.sh" "$home/state" "$corr" >/dev/null 2>&1
  elapsed=$(( $(date +%s) - start ))
  rec=$(fm_pending_reply_path "$home/state" "$corr")
  [ "$elapsed" -le 9 ] || fail "a hung recovery send took ${elapsed}s with a 3s bound"
  [ "$(fm_pending_reply_get "$rec" phase)" = recovery_unknown ] \
    || fail "a recovery send stopped at its bound must be recovery_unknown, got $(fm_pending_reply_get "$rec" phase)"
  [ "$(fm_pending_reply_get "$rec" recovery_delivery_outcome)" = unknown ] \
    || fail "a recovery send stopped at its bound must record an unknown outcome"
  corr=$(recovery_record "$home")
  # shellcheck disable=SC2016 # expanded by the child shell
  FM_PENDING_REPLY_SEND_HOOK=fail_hook FM_PENDING_REPLY_SEND_BUDGET=3 \
    fm_run_timed 30 bash -c '. "$1"; fm_pending_reply_send_recovery "$2" "$3"' _ \
      "$ROOT/bin/fm-pending-reply-lib.sh" "$home/state" "$corr" >/dev/null 2>&1
  rec=$(fm_pending_reply_path "$home/state" "$corr")
  [ "$(fm_pending_reply_get "$rec" phase)" = recovery_failed ] \
    || fail "a recovery send that fails within its bound must stay recovery_failed, got $(fm_pending_reply_get "$rec" phase)"
  unset FM_PENDING_REPLY_NOW FM_PENDING_REPLY_GRACE_SECS
  pass "a recovery send stopped at its bound is recorded unknown; one that fails inside it stays failed"
}

test_watcher_diagnostic_records_stay_complete_during_updates() {
  local kind dir file writer i owner epoch label holder
  for kind in stage deferral; do
    dir=$(make_case "diagnostic-$kind")
    case "$kind" in
      stage) file="$dir/state/.watcher-stage" ;;
      deferral) file="$dir/state/.watcher-deferral.wake-queue" ;;
    esac
    FM_STATE_OVERRIDE="$dir/state" bash -c '
      . "$1"
      dir=$2
      kind=$3
      file=$4
      FM_WATCH_NOW=100
      if [ "$kind" = stage ]; then watch_stage first
      else watch_lock_deferred wake-queue 111; fi
      cp "$file" "$dir/before"
      builtin printf "%s\n" "$$" > "$dir/writer"
      # Pause the actual output operation after its redirection has opened.
      # The public record must still contain the previous complete record.
      printf() {
        if [ "${1:-}" != -v ]; then
          : > "$dir/paused"
          while [ ! -e "$dir/resume" ]; do sleep 0.01; done
        fi
        builtin printf "$@"
      }
      FM_WATCH_NOW=200
      if [ "$kind" = stage ]; then watch_stage next
      else watch_lock_deferred wake-queue 222; fi
    ' _ "$ROOT/bin/fm-watch.sh" "$dir" "$kind" "$file" &
    writer=$!
    FIXTURE_PIDS="$FIXTURE_PIDS $writer"
    for i in $(seq 1 100); do [ -e "$dir/paused" ] && break; sleep 0.1; done
    [ -e "$dir/paused" ] || fail "the $kind writer did not reach its update"
    cmp -s "$dir/before" "$file" \
      || fail "the published $kind record was incomplete during its update"
    : > "$dir/resume"
    wait "$writer" || fail "the $kind update failed"
    IFS=$'\t' read -r owner epoch label holder < "$file"
    [ "$owner" = "$(cat "$dir/writer")" ] || fail "the $kind update lost its owner"
    if [ "$kind" = stage ]; then
      [ "$epoch" = 200 ] && [ "$label" = next ] && [ -z "$holder" ] \
        || fail "the new stage record was not published completely"
    else
      [ "$epoch" = 100 ] && [ "$label" = wake-queue ] && [ "$holder" = 222 ] \
        || fail "the deferral update lost its first epoch or new holder"
      FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; watch_lock_acquired wake-queue' _ "$ROOT/bin/fm-watch.sh"
      [ ! -e "$file" ] || fail "the acquired lock retained its deferral record"
    fi
  done
  pass "watcher stage and deferral records remain complete during updates"
}

test_watcher_defers_work_behind_a_held_wake_queue_lock() {
  local dir state fakebin out holder holder_pid watcher i d_owner d_first d_name d_holder s_pid s_epoch s_stage
  dir=$(make_case wake-lock-held)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  # The holder takes the queue lock after the watcher's first beat and, while
  # holding it, queues a process-event result the watcher will try to surface.
  holder="$dir/fm-fake-queue-holder.sh"
  # shellcheck disable=SC2016 # expanded by the holder script
  printf '%s\n' '#!/usr/bin/env bash' 'export STATE="$2" FM_WAKE_QUEUE="$2/.wake-queue" FM_WAKE_QUEUE_LOCK="$3"' \
    '. "$1"' 'fm_lock_try_acquire "$3" || exit 1' \
    'fm_wake_append_locked check "procevent:fake:src:1" "check: process-event fake src 1" || exit 1' 'sleep 120 >/dev/null 2>&1 &' 'trap "kill $! 2>/dev/null; exit 0" TERM' 'wait $!' > "$holder"
  chmod +x "$holder"
  watch_start "$state" "$fakebin" "$out" FM_WATCH_HANDLING_SUCCESSOR=1 FM_WAKE_QUEUE_LOCK_WAIT=2 FM_WATCHER_STALL_BOUND=600
  watcher=$!
  wait_beats "$state" "$watcher" 1 300 || fail "the watcher did not complete a first cycle: $(cat "$out")"
  "$holder" "$ROOT/bin/fm-wake-lib.sh" "$state" "$state/.wake-queue.lock" &
  holder_pid=$!
  FIXTURE_PIDS="$FIXTURE_PIDS $holder_pid $watcher"
  for i in $(seq 1 50); do [ "$(cat "$state/.wake-queue.lock/pid" 2>/dev/null)" = "$holder_pid" ] && break; sleep 0.1; done
  wait_beats "$state" "$watcher" 2 600 \
    || fail "the watcher stopped beating while a live process held its wake-queue lock: $(cat "$out")"
  grep -q 'deferred wake-queue' "$state/.watch-triage.log" 2>/dev/null \
    || fail "the watcher did not record deferring its wake-queue work; triage: $(tail -5 "$state/.watch-triage.log" 2>/dev/null); queue: $(cat "$state/.wake-queue" 2>/dev/null); lock pid: $(cat "$state/.wake-queue.lock/pid" 2>/dev/null) holder $holder_pid; out: $(cat "$out")"
  [ -f "$state/.watcher-deferral.wake-queue" ] || fail "the watcher left no deferral record for the guard to report"
  IFS=$'\t' read -r d_owner d_first d_name d_holder < "$state/.watcher-deferral.wake-queue"
  if [ "$d_owner" != "$watcher" ] || [ "$d_name" != wake-queue ] || [ "$d_holder" != "$holder_pid" ] \
    || ! [ "$d_first" -gt 0 ] 2>/dev/null; then
    fail "the deferral record must name the watcher, the work and the holder, got: $(cat "$state/.watcher-deferral.wake-queue")"
  fi
  IFS=$'\t' read -r s_pid s_epoch s_stage < "$state/.watcher-stage"
  if [ "$s_pid" != "$watcher" ] || [ -z "$s_stage" ] || ! [ "$s_epoch" -gt 0 ] 2>/dev/null; then
    fail "the watcher must record its own stage for the guard, got: $(cat "$state/.watcher-stage" 2>/dev/null)"
  fi
  kill "$holder_pid" 2>/dev/null
  wait "$holder_pid" 2>/dev/null
  for i in $(seq 1 300); do kill -0 "$watcher" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$watcher" 2>/dev/null && { kill "$watcher" 2>/dev/null; fail "the watcher never delivered the deferred work after the holder went"; }
  [ "$(grep -c 'procevent:fake:src:1' "$out")" -eq 1 ] \
    || fail "the deferred process-event result must be delivered exactly once after the lock is free: $(cat "$out")"
  [ ! -f "$state/.watcher-deferral.wake-queue" ] || fail "the deferral record outlived the deferral"
  pass "a held wake-queue lock defers the watcher's queue work while it keeps beating; the work is delivered after release"
}

test_stopped_perl_bound_stops_its_command() {
  local path pidfile rc pid i
  path="$TMP_ROOT/perl-only-bin"
  mkdir -p "$path"
  for tool in perl bash sleep; do ln -sf "$(command -v "$tool")" "$path/$tool"; done
  pidfile="$TMP_ROOT/nested.pid"
  rm -f "$pidfile"
  # The outer bound stops a bash whose inner perl-bounded command ignores TERM.
  # shellcheck disable=SC2016 # expanded by the nested shells
  # Output goes to /dev/null, not a capture: a surviving orphan would hold a
  # capture's pipe open and make this wait for it, hiding the survival.
  PATH="$path" fm_run_timed 2 bash -c '
    . "$1"
    fm_run_timed 60 bash -c "trap \"\" TERM; echo \$\$ > \"\$1\"; exec sleep 600" _ "$2"' _ "$ROOT/bin/fm-timeout-lib.sh" "$pidfile" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 124 ] || fail "the outer bound should report 124, got $rc"
  pid=$(cat "$pidfile" 2>/dev/null)
  [ -n "$pid" ] || fail "the inner command never started"
  for i in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null
    fail "a TERM-ignoring command under a nested perl bound survived the outer bound"
  fi
  fm_run_timed_fn 2 bash -c 'exit 3'
  rc=$?
  [ "$rc" -eq 3 ] || fail "fm_run_timed_fn must pass a finished command's status through, got $rc"
  # shellcheck disable=SC2329 # invoked by fm_run_timed_fn
  hang_fn() { command -p sleep 600; }
  fm_run_timed_fn 2 hang_fn
  rc=$?
  [ "$rc" -eq 124 ] || fail "fm_run_timed_fn must bound a shell function with 124, got $rc"
  pass "a perl bound stopped by an outer bound stops its TERM-ignoring command; shell functions can be bounded"
}

# The server is started from inside whatever process group its caller runs in
# (an arm, a doorbell bound). Killing that whole group, as an arm's own bound
# does, must leave the fleet's herdr server and its panes running.
test_herdr_server_survives_its_spawning_group_kill() {
  local fb caller_pgid server_pid server_pgid i
  fb="$TMP_ROOT/herdr-fakebin"
  mkdir -p "$fb"
  # A stand-in herdr: `server` records its pid and process group and stays up.
  cat > "$fb/herdr" <<SH
#!/usr/bin/env bash
case "\$*" in
  *server*) printf '%s %s\n' \$\$ "\$(ps -o pgid= -p \$\$ | tr -d ' ')" > "$TMP_ROOT/herdr-server.ids"; exec /bin/sleep 30 ;;
  *status*) printf '{"server":{"running":false}}\n' ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  rm -f "$TMP_ROOT/herdr-server.ids" "$TMP_ROOT/herdr-caller.pgid"
  # The caller leads its own group, like an arm, and stays alive after the
  # start so the group kill below has a live group to hit; the subshell keeps it
  # out of this shell's job table.
  # shellcheck disable=SC2016 # expanded by the nested shell
  ( PATH="$fb:$PATH" perl -e 'setpgrp(0, 0); exec @ARGV' bash -c '
    . "$1/bin/fm-backend.sh"
    fm_backend_source herdr >/dev/null 2>&1 || exit 9
    ps -o pgid= -p $$ | tr -d " " > "$2"
    fm_backend_herdr_server_ensure fm-test-session >/dev/null 2>&1 || true
    exec sleep 30' _ "$ROOT" "$TMP_ROOT/herdr-caller.pgid" </dev/null >/dev/null 2>&1 & )
  for i in $(seq 1 150); do
    [ -s "$TMP_ROOT/herdr-server.ids" ] && [ -s "$TMP_ROOT/herdr-caller.pgid" ] && break
    sleep 0.1
  done
  caller_pgid=$(cat "$TMP_ROOT/herdr-caller.pgid" 2>/dev/null)
  read -r server_pid server_pgid < "$TMP_ROOT/herdr-server.ids" 2>/dev/null || true
  [ -n "$server_pid" ] || fail "the stand-in herdr server never started (caller pgid $caller_pgid)"
  [ -n "$caller_pgid" ] && [ "$caller_pgid" != "$(ps -o pgid= -p $$ | tr -d ' ')" ] \
    || fail "the fixture caller did not lead a process group of its own: $caller_pgid"
  kill -KILL -- "-$caller_pgid" 2>/dev/null
  sleep 0.5
  if kill -0 "$server_pid" 2>/dev/null; then i=alive; else i=gone; fi
  [ "$server_pgid" = "$(ps -o pgid= -p $$ | tr -d ' ')" ] \
    || kill -TERM -- "-$server_pgid" 2>/dev/null || true
  [ "$server_pgid" != "$caller_pgid" ] \
    || fail "the herdr server started inside its caller's process group $caller_pgid"
  [ "$i" = alive ] || fail "killing the spawning process group $caller_pgid also stopped the herdr server (pid $server_pid)"
  pass "a herdr server started by the backend survives a kill of its spawning process group"
}

# FM_SUPERVISION_BOUNDS_ONLY=<test function> runs that one case, so each can be
# shown failing on its own against an older revision.
if [ -n "${FM_SUPERVISION_BOUNDS_ONLY:-}" ]; then
  "$FM_SUPERVISION_BOUNDS_ONLY"
  exit $?
fi

test_hung_doorbell_returns_delivered_and_frees_the_lock
test_recovery_send_bound_records_unknown_never_failed
test_watcher_diagnostic_records_stay_complete_during_updates
test_watcher_defers_work_behind_a_held_wake_queue_lock
test_stopped_perl_bound_stops_its_command
test_herdr_server_survives_its_spawning_group_kill
