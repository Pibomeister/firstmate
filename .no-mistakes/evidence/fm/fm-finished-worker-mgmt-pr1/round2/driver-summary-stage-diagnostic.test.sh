#!/usr/bin/env bash
# Behavioral coverage for per-home summary publication through the real
# producer, writer, watcher-carried status trigger, and snapshot ledger consumer.
# Optional arguments select the scheduler test functions below.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRITER="$ROOT/bin/fm-home-summary-refresh.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-home-summary-refresh)
HOME_DIR="$TMP_ROOT/mate-home"
CADENCE_HOME="$TMP_ROOT/cadence-home"
PARENT_HOME="$TMP_ROOT/parent-home"
LARGE_HOME="$TMP_ROOT/large-home"
STATELESS_HOME="$TMP_ROOT/stateless-home"
LARGE_CHILD_HOME="$TMP_ROOT/large-child-home"
LARGE_PARENT_HOME="$TMP_ROOT/large-parent-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
WATCH_PID=
SLOW_WRITER_PID=
SLOW_WORKER_PGID=
SLOW_NM_PID=
LOCK_HOLDER_PID=

cleanup() {
  local pid
  case "$SLOW_WORKER_PGID" in
    ''|*[!0-9]*) ;;
    *) kill -KILL -- "-$SLOW_WORKER_PGID" >/dev/null 2>&1 || true ;;
  esac
  for pid in "$WATCH_PID" "$SLOW_WRITER_PID" "$SLOW_NM_PID" "$LOCK_HOLDER_PID"; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'fixture pane\n> \n' ;;
esac
exit 0
SH
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_TEST_NM_MARKER:-}" ]; then
  printf '%s\n' "$$" > "$FM_TEST_NM_MARKER"
  sleep "${FM_TEST_NM_SLEEP:-30}"
fi
exit 0
SH
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/no-mistakes"

set_summary_clock() {
  printf '%s\n' "$2" > "$1/clock.next"
  mv "$1/clock.next" "$1/clock"
}

assert_summary_idle_launches() {  # <jitter|failure|loaded-idle|loaded-status>
  local mode=$1 home runs hook interval jitter wanted i=0 first_beat last_beat gaps epoch beat cycles
  home=$TMP_ROOT/scheduler-$mode
  runs=$home/refresh-starts
  hook=$home/refresh-boundary.sh
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '# Seeded Firstmate home\n' > "$home/AGENTS.md"
  printf 'scheduler\n' > "$home/.fm-secondmate-home"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$WRITER" \
    || fail "could not seed the scheduler's valid summary"
  mv "$home/state/home-summary.json" "$home/seed-summary.json"
  : > "$runs"
  # Interpose only the public refresh command boundary. Successful calls
  # publish a valid seeded document quickly; failures return nonzero without
  # publication, so producer runtime cannot hide a broken launch schedule.
  cat > "$hook" <<'SH'
fm_test_refresh_boundary() {
  trap - DEBUG
  case "$0" in
    */fm-watch.sh)
      case "$FM_TEST_SUMMARY_MODE" in
        loaded-*)
          export FM_WATCH_NOW
          read -r FM_WATCH_NOW < "$FM_HOME/clock"
          trap 'read -r FM_WATCH_NOW < "$FM_HOME/clock"' DEBUG
          ;;
      esac
      ;;
    */fm-home-summary-refresh.sh)
      if [ "${1:-}" = --best-effort ]; then
        epoch=${FM_WATCH_NOW:-$(date +%s)}
        printf '%s\n' "$epoch" >> "$FM_TEST_SUMMARY_RUNS"
        [ "$FM_TEST_SUMMARY_MODE" != failure ] || exit 1
        jq --argjson epoch "$epoch" '.generated_epoch=$epoch' \
          "$FM_HOME/seed-summary.json" > "$FM_HOME/state/home-summary.next" || exit 1
        mv "$FM_HOME/state/home-summary.next" "$FM_HOME/state/home-summary.json"
        python3 - "$FM_HOME/state/home-summary.json" "$epoch" <<'PY'
import os
import sys
os.utime(sys.argv[1], (int(sys.argv[2]), int(sys.argv[2])))
PY
        exit 0
      fi
      ;;
  esac
}
# BASH_ENV loads before script arguments are installed; the first command's
# DEBUG boundary has the public script name and arguments, then disables itself.
trap 'fm_test_refresh_boundary "$@"' DEBUG
SH
  interval=30 jitter=25 wanted=2
  [ "$mode" != failure ] || { interval=6; jitter=0; wanted=3; }
  epoch=$(date +%s)
  set_summary_clock "$home" "$epoch"
  printf '10 0.00 0.00\n' > "$home/load"
  case "$mode" in
    loaded-*)
      interval=3 jitter=0 wanted=2
      printf '300 0.00 0.00\n' > "$home/load"
      ;;
  esac
  cat > "$home/crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: working · source: run-step · validating (running)\n'
SH
  chmod +x "$home/crew-state.sh"
  if [ "$mode" = loaded-status ]; then
    printf 'window=fmtest:fm-summary\nkind=ship\nharness=claude\n' > "$home/state/summary.meta"
  fi
  fm_test_track_watcher_state "$home/state"
  PATH="$FAKEBIN:$PATH" BASH_ENV="$hook" \
    FM_TEST_SUMMARY_RUNS="$runs" FM_TEST_SUMMARY_MODE="$mode" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_HOME_SUMMARY_INTERVAL="$interval" FM_HOME_SUMMARY_JITTER="$jitter" \
    FM_TEST_SEAM=1 FM_WATCH_RANDOM_SEED=42 FM_HEARTBEAT_BIN=/usr/bin/true \
    FM_LOAD_FILE="$home/load" FM_CREW_STATE_BIN="$home/crew-state.sh" \
    FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
    "$WATCH" > "$home/watch.out" 2> "$home/watch.err" &
  WATCH_PID=$!
  while [ ! -e "$home/state/.last-watcher-beat" ] && [ "$i" -lt 300 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$home/state/.last-watcher-beat" ] || fail "the summary scheduler watcher never polled"
  first_beat=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$home/state/.last-watcher-beat")
  case "$mode" in
    loaded-*)
      i=0
      while [ "$(wc -l < "$runs" | tr -d ' ')" -lt 1 ] && [ "$i" -lt 600 ]; do
        kill -0 "$WATCH_PID" 2>/dev/null || break
        sleep 0.1
        i=$((i + 1))
      done
      [ -s "$runs" ] || fail "the loaded summary never made its first launch"
      set_summary_clock "$home" "$((epoch + 11))"
      [ "$mode" != loaded-status ] || printf 'working: loaded summary refresh\n' >> "$home/state/summary.status"
      beat=$first_beat cycles=0 i=0
      while [ "$cycles" -lt 3 ] && [ "$i" -lt 600 ]; do
        kill -0 "$WATCH_PID" 2>/dev/null || break
        last_beat=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$home/state/.last-watcher-beat")
        if [ "$last_beat" != "$beat" ]; then
          cycles=$((cycles + 1))
          beat=$last_beat
        fi
        sleep 0.1
        i=$((i + 1))
      done
      [ "$cycles" -ge 3 ] || fail "the loaded summary watcher stopped polling"
      assert_equals 1 "$(wc -l < "$runs" | tr -d ' ')" \
        "$mode refreshed before the 12-second throttled gap"
      set_summary_clock "$home" "$((epoch + 12))"
      i=0
      while [ "$(wc -l < "$runs" | tr -d ' ')" -lt 2 ] && [ "$i" -lt 600 ]; do
        kill -0 "$WATCH_PID" 2>/dev/null || break
        sleep 0.1
        i=$((i + 1))
      done
      [ "$(wc -l < "$runs" | tr -d ' ')" -ge 2 ] || fail "the loaded summary never refreshed at its due"
      printf '10 0.00 0.00\n' > "$home/load"
      if [ "$mode" = loaded-status ]; then
        set_summary_clock "$home" "$((epoch + 13))"
        printf 'working: calm summary refresh\n' >> "$home/state/summary.status"
      else
        set_summary_clock "$home" "$((epoch + 15))"
      fi
      i=0
      while [ "$(wc -l < "$runs" | tr -d ' ')" -lt 3 ] && [ "$i" -lt 600 ]; do
        kill -0 "$WATCH_PID" 2>/dev/null || break
        sleep 0.1
        i=$((i + 1))
      done
      [ "$(wc -l < "$runs" | tr -d ' ')" -ge 3 ] || fail "calm summary refreshes never resumed"
      ;;
    *)
      i=0
      while [ "$(wc -l < "$runs" | tr -d ' ')" -lt "$wanted" ] && [ "$i" -lt 700 ]; do
        kill -0 "$WATCH_PID" 2>/dev/null || break
        sleep 0.1
        i=$((i + 1))
      done
      ;;
  esac
  last_beat=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$home/state/.last-watcher-beat")
  kill "$WATCH_PID" >/dev/null 2>&1 || true
  wait "$WATCH_PID" >/dev/null 2>&1 || true
  WATCH_PID=
  [ "$(wc -l < "$runs" | tr -d ' ')" -ge "$wanted" ] || fail "only $(cat "$runs") summary launches were observed"
  [ "$last_beat" -gt "$first_beat" ] || fail "summary scheduling stopped the watcher liveness beat"
  gaps=$(awk 'NR>1 { print $1-prev } { prev=$1 }' "$runs")
  if [ "$mode" = failure ]; then
    [ ! -e "$home/state/home-summary.json" ] || fail "a failed summary refresh published a ledger"
    [ -z "$(awk 'NR>1 && $1-prev < 5 { print $1-prev } { prev=$1 }' "$runs")" ] \
      || fail "failed refreshes retried before the six-second idle gap: $gaps"
  elif [ "$mode" = jitter ]; then
    # Seed 42 shortens the first 30-second interval. The minimum allows one
    # clock-boundary second; a per-poll launch or absent jitter fails here.
    [ -z "$(awk 'NR==2 && ($1-prev < 4 || $1-prev >= 30) { print $1-prev } { prev=$1 }' "$runs")" ] \
      || fail "the seeded summary idle gap was not bounded and shortened: $gaps"
  fi
}

test_summary_jitter_shortens_idle_launches() {
  assert_summary_idle_launches jitter
  pass "summary idle jitter shortens a bounded launch gap while watcher beats continue"
}

test_failed_summary_refresh_waits_for_idle() {
  assert_summary_idle_launches failure
  pass "persistent summary refresh failures retry once per idle gap while watcher beats continue"
}

test_summary_idle_pacing_follows_load() {
  assert_summary_idle_launches loaded-idle
  pass "summary idle refreshes slow above load 200 and resume ordinary pacing below it"
}

test_summary_status_pacing_follows_load() {
  assert_summary_idle_launches loaded-status
  pass "status signals respect the loaded summary gap and refresh promptly when calm"
}

test_snapshot_preserves_absent_state() {
  local mode schema
  mkdir -p "$STATELESS_HOME/data" "$STATELESS_HOME/config" \
    "$STATELESS_HOME/projects"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' \
    > "$STATELESS_HOME/data/backlog.md"
  # Read-only output must preserve an absent state directory. Loading a
  # mutating library merely to collect a snapshot must fail this contract.
  for mode in json secondmate-home-summary; do
    case "$mode" in
      json) schema=fm-fleet-snapshot.v1 ;;
      secondmate-home-summary) schema=fm-secondmate-home-summary.v1 ;;
    esac
    PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$STATELESS_HOME" \
      "$SNAPSHOT" "--$mode" > "$TMP_ROOT/stateless-snapshot.json" \
      || fail "fleet snapshot $mode mode failed without a state directory"
    jq -e --arg schema "$schema" '.schema == $schema and
      ((if $schema == "fm-fleet-snapshot.v1" then .tasks else .active_children end) == [])' \
      "$TMP_ROOT/stateless-snapshot.json" >/dev/null \
      || fail "stateless fleet snapshot $mode output was not valid"
    [ ! -e "$STATELESS_HOME/state" ] \
      || fail "fleet snapshot $mode created operational state"
  done
  pass "fleet snapshot transport does not require or mutate operational state"
}


ROOT=${FM_STAGE_CODE_ROOT:-$ROOT}
WRITER="$ROOT/bin/fm-home-summary-refresh.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" \
  "$HOME_DIR/projects/task" "$HOME_DIR/bin"
HOME_DIR=$(cd "$HOME_DIR" && pwd -P)
printf '# Seeded Firstmate home\n' > "$HOME_DIR/AGENTS.md"
printf 'mate\n' > "$HOME_DIR/.fm-secondmate-home"
fm_git_init_commit "$HOME_DIR/projects/task"
git -C "$HOME_DIR/projects/task" checkout -q -b fm/ledger-task
cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## In flight
- [ ] ledger-task - Publish the home ledger (repo: firstmate) (kind: ship) (since 2026-08-28)

## Queued

## Done
EOF
fm_write_meta "$HOME_DIR/state/ledger-task.meta" \
  "window=fmtest:fm-ledger-task" \
  "worktree=$HOME_DIR/projects/task" \
  "project=firstmate" \
  "harness=claude" \
  "kind=ship" \
  "mode=no-mistakes" \
  "spawn_gen=fm.ledger123456"
busy_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$HOME_DIR/state" ledger-task)
"$ROOT/bin/fm-busy-event.sh" apply "$HOME_DIR/state" ledger-task idle \
  --gen "$busy_gen" --source claude-hook --event stop

NOW_ONE=2026-08-28T10:00:00Z
EPOCH_ONE=1787911200
NOW_TWO=2026-08-28T10:01:00Z
EPOCH_TWO=1787911260
NOW_THREE=2026-08-28T10:02:00Z
EPOCH_THREE=1787911320

run_writer() {  # <now> <epoch> [writer args...]
  local now=$1 epoch=$2
  shift 2
  PATH="$FAKEBIN:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_SNAPSHOT_NOW="$now" FM_SNAPSHOT_NOW_EPOCH="$epoch" \
    "$WRITER" "$@"
}

run_producer() {  # <now> <epoch>
  PATH="$FAKEBIN:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_SNAPSHOT_NOW="$1" FM_SNAPSHOT_NOW_EPOCH="$2" \
    "$SNAPSHOT" --secondmate-home-summary
}

wait_for_ledger_generation() {  # <generated> [tenths]
  local want=$1 attempts=${2:-150} i=0 got
  while [ "$i" -lt "$attempts" ]; do
    got=$(jq -r '.generated // ""' "$HOME_DIR/state/home-summary.json" 2>/dev/null || true)
    [ "$got" = "$want" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

STAGE_MARKER="$TMP_ROOT/stage-no-mistakes.pid"
rm -f "$STAGE_MARKER"
run_writer "$NOW_TWO" "$EPOCH_TWO" || fail "could not settle a good ledger before the slow-stage check"
cp "$HOME_DIR/state/home-summary.json" "$TMP_ROOT/stage-prior-ledger.json"
: > "$HOME_DIR/state/.home-summary-refresh.log"
printf 'working: a status change forces a recompute\n' >> "$HOME_DIR/state/ledger-task.status"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  FM_TEST_NM_MARKER="$STAGE_MARKER" FM_TEST_NM_SLEEP=30 \
  FM_HOME_SUMMARY_TIMEOUT=3 "$WRITER" --best-effort \
  || fail "a slow-stage timeout changed the best-effort caller result"
stage_nm_pid=$(cat "$STAGE_MARKER" 2>/dev/null || true)
[ -z "$stage_nm_pid" ] || kill -KILL "$stage_nm_pid" >/dev/null 2>&1 || true
cp "$HOME_DIR/state/.home-summary-refresh.log" "$FM_STAGE_EVIDENCE"
cp "$HOME_DIR/state/home-summary.json" "$FM_STAGE_EVIDENCE.ledger.json"
grep -F 'refresh exceeded its 3-second deadline in stage task-observation' \
  "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null \
  || fail "the slow stage was not named in the failure log: $(cat "$HOME_DIR/state/.home-summary-refresh.log")"
grep -E 'stages: lock-wait@[0-9]+ producer@[0-9]+ backlog@[0-9]+ task-observation@[0-9]+' \
  "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null \
  || fail "the failure log did not list the stage offsets: $(cat "$HOME_DIR/state/.home-summary-refresh.log")"
cmp -s "$TMP_ROOT/stage-prior-ledger.json" "$HOME_DIR/state/home-summary.json" \
  || fail "a failed refresh replaced the last good ledger"
[ "$(jq -r '.generated' "$HOME_DIR/state/home-summary.json")" = "$NOW_TWO" ] \
  || fail "the last good ledger lost its true generated timestamp"
[ "$(jq -r '.generated_epoch' "$HOME_DIR/state/home-summary.json")" = "$EPOCH_TWO" ] \
  || fail "the last good ledger lost its true generated epoch"
ls "$HOME_DIR/state"/.home-summary-stage.* >/dev/null 2>&1 \
  && fail "the failed refresh leaked its stage file"
pass "a deadline failure names the slow stage and keeps the last good summary"

