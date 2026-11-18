#!/usr/bin/env bash
# Behavior tests for the in-session watcher's stale-wedge budget on a
# provably-working pane (bin/fm-watch.sh). Shared fixtures live in
# tests/watch-triage-helpers.sh.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-stale-backoff-tests)

# Each cycle is a whole watcher process. On a loaded host, startup can outlast
# the helpers' 50-poll default, so waits of at least that standard 100-poll
# budget get FM_TEST_WAIT_POLLS polls instead (default 1200, 120s).
FM_BACKOFF_WAIT_FLOOR=${FM_TEST_WAIT_POLLS:-1200}
case "$FM_BACKOFF_WAIT_FLOOR" in
  ''|*[!0-9]*)
    printf 'not ok - FM_TEST_WAIT_POLLS must be a whole number of polls, got %s\n' "'$FM_BACKOFF_WAIT_FLOOR'" >&2
    exit 1
    ;;
esac
load_tolerant_polls() {  # <polls>: the budget a wait of <polls> polls actually gets
  if [ "$1" -ge 100 ] && [ "$1" -lt "$FM_BACKOFF_WAIT_FLOOR" ]; then
    printf '%s\n' "$FM_BACKOFF_WAIT_FLOOR"
  else
    printf '%s\n' "$1"
  fi
}
eval "fm_backoff_base_wait_for_exit() $(declare -f wait_for_exit | tail -n +2)"
wait_for_exit() {  # <pid> [polls]
  fm_backoff_base_wait_for_exit "$1" "$(load_tolerant_polls "${2:-50}")"
}

# Idle ages below the 300s floor. 254 and 286 fired under the old 240s default.
# 299s is the probe just under the floor.
STALE_BACKOFF_SILENT_ELAPSED='0 2 6 14 30 62 94 126 158 190 222 254 286 299'

run_backoff_cycle() {  # <state> <fakebin> <out> <capture> <window> <key> <t0> <elapsed>
  local state=$1 fakebin=$2 out=$3 capture=$4 window=$5 key=$6 t0=$7 elapsed=$8 pid
  printf '%s\n' "$t0" > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_WATCH_ONCE=1 FM_WATCH_NOW="$((t0 + elapsed))" FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 \
    "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || {
    reap "$pid"
    fail "watcher did not finish a once-cycle at elapsed ${elapsed}s: $(cat "$out")"
  }
}

test_working_pane_stale_outage_waits_300s_backoff() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig t0 elapsed
  unset FM_STALE_ESCALATE_SECS
  dir=$(make_case stale-backoff-working); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-quiet"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/quiet.meta"
  printf 'working: still compiling\n' > "$state/quiet.status"
  sig=$(seen_sig "$state/quiet.status"); printf '%s' "$sig" > "$state/.seen-quiet_status"
  key=$(watch_window_key "$window")
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · ci running'
  t0=$(( $(date +%s) + 60 ))
  printf '%s\n' "$t0" > "$state/.stale-since-$key"

  for elapsed in $STALE_BACKOFF_SILENT_ELAPSED; do
    run_backoff_cycle "$state" "$fakebin" "$out" "$capture_file" "$window" "$key" "$t0" "$elapsed"
    if grep -F 'stale:' "$out" >/dev/null; then
      fail "elapsed ${elapsed}s printed a stale wake under the production default: $(cat "$out")"
    fi
    [ "$(wedge_stale_wakes "$state" "$window")" -eq 0 ] \
      || fail "elapsed ${elapsed}s queued a stale wake under the production default: $(cat "$state/.wake-queue")"
    ack_stopped_cycle "$state" >/dev/null || true
  done

  run_backoff_cycle "$state" "$fakebin" "$out" "$capture_file" "$window" "$key" "$t0" 300
  grep -F "stale: $window" "$out" >/dev/null \
    || fail "elapsed 300s did not print a stale wake: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the 300s stale wake failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null \
    || fail "elapsed 300s did not queue a stale wake: $(cat "$drain_out")"
  unset FM_FAKE_CREW_STATE
  pass "a provably-working stale pane is silent through 299s of backoff and queued as stale at 300s"
}

fm_test_run test_working_pane_stale_outage_waits_300s_backoff
