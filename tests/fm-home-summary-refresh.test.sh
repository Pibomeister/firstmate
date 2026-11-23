#!/usr/bin/env bash
# Behavioral coverage for per-home summary publication through the real
# producer, writer, watcher-carried status trigger, and snapshot ledger consumer.
# Optional arguments select the test functions below.
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
# Parent consumers reject child homes beneath their declared code root. Keep
# that root beside the fixture homes, including when TMPDIR is in the worktree.
PARENT_CODE_ROOT="$TMP_ROOT/parent-code-root"
mkdir -p "$PARENT_CODE_ROOT"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
WATCH_PID=
SLOW_WRITER_PID=
SLOW_WORKER_PGID=
SLOW_NM_PID=
SLOW_VALIDATOR_PID=
LOCK_HOLDER_PID=

cleanup() {
  local pid
  case "$SLOW_WORKER_PGID" in
    ''|*[!0-9]*) ;;
    *) kill -KILL -- "-$SLOW_WORKER_PGID" >/dev/null 2>&1 || true ;;
  esac
  for pid in "$WATCH_PID" "$SLOW_WRITER_PID" "$SLOW_NM_PID" "$SLOW_VALIDATOR_PID" "$LOCK_HOLDER_PID"; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# Resolve delegates before PATH interposition; command-cache warmth can mask self-delegation.
REAL_JQ=$(command -v jq)
REAL_TAIL=$(command -v tail)

if [ "${1:-}" != --backoff ]; then

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

assert_summary_idle_launches() {  # <jitter|failure>
  local mode=$1 home runs hook interval jitter wanted i=0 first_beat last_beat gaps
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
    */fm-home-summary-refresh.sh)
      if [ "${1:-}" = --best-effort ]; then
        date +%s >> "$FM_TEST_SUMMARY_RUNS"
        [ "$FM_TEST_SUMMARY_MODE" != failure ] || exit 1
        jq --argjson epoch "$(date +%s)" '.generated_epoch=$epoch' \
          "$FM_HOME/seed-summary.json" > "$FM_HOME/state/home-summary.next" || exit 1
        mv "$FM_HOME/state/home-summary.next" "$FM_HOME/state/home-summary.json"
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
  fm_test_track_watcher_state "$home/state"
  PATH="$FAKEBIN:$PATH" BASH_ENV="$hook" \
    FM_TEST_SUMMARY_RUNS="$runs" FM_TEST_SUMMARY_MODE="$mode" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_HOME_SUMMARY_INTERVAL="$interval" FM_HOME_SUMMARY_JITTER="$jitter" \
    FM_TEST_SEAM=1 FM_WATCH_RANDOM_SEED=42 FM_HEARTBEAT_BIN=/usr/bin/true \
    FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
    "$WATCH" > "$home/watch.out" 2> "$home/watch.err" &
  WATCH_PID=$!
  while [ ! -e "$home/state/.last-watcher-beat" ] && [ "$i" -lt 300 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$home/state/.last-watcher-beat" ] || fail "the summary scheduler watcher never polled"
  first_beat=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$home/state/.last-watcher-beat")
  i=0
  while [ "$(wc -l < "$runs" | tr -d ' ')" -lt "$wanted" ] && [ "$i" -lt 700 ]; do
    kill -0 "$WATCH_PID" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
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
  else
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

test_locked_deadlines_record_backoff() {
  local code home stalls operation attempts expected lib actual
  code="$TMP_ROOT/locked-deadline-code"
  stalls="$TMP_ROOT/locked-deadline-hooks.sh"
  mkdir -p "$code/bin"
  ln -s "$WRITER" "$code/bin/fm-home-summary-refresh.sh"
  for lib in fm-timeout-lib.sh fm-clock-lib.sh fm-wake-lib.sh fm-bash-compat-lib.sh fm-path-lib.sh; do
    ln -s "$ROOT/bin/$lib" "$code/bin/$lib"
  done
  cat > "$code/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf 'attempt\n' >> "$FM_TEST_ATTEMPTS"
[ "$FM_TEST_STALL_AT" != log ] || exit 7
cat "$FM_TEST_SUMMARY"
SH
  chmod +x "$code/bin/fm-fleet-snapshot.sh"
  cat > "$stalls" <<'SH'
fm_test_stall() {
  [ "${HOME_SUMMARY_LOCK_HELD:-0}" -eq 1 ] || return 0
  [ ! -e "$FM_TEST_STALLED" ] || return 0
  case "$FM_TEST_STALL_AT:$1" in
    mkdir:mkdir|rm:rm|chmod:chmod) ;;
    ledger-temp:mktemp) case "$2" in */.home-summary.json.*) ;; *) return 0 ;; esac ;;
    error-temp:mktemp) case "$2" in */.home-summary-error.*) ;; *) return 0 ;; esac ;;
    replace:mv) case "${@: -1}" in */home-summary.json) ;; *) return 0 ;; esac ;;
    stage:printf) [ "${3:-}" = producer ] || return 0 ;;
    log:printf) [ -n "${HOME_SUMMARY_ERROR:-}" ] || return 0 ;;
    *) return 0 ;;
  esac
  builtin printf 'operation=%s worker=%s seconds=%s\n' "$1" "$$" "$SECONDS" > "$FM_TEST_STALLED"
  sleep 60
}
mkdir() { fm_test_stall mkdir "$@"; command mkdir "$@"; }
mktemp() { fm_test_stall mktemp "$@"; command mktemp "$@"; }
rm() { fm_test_stall rm "$@"; command rm "$@"; }
chmod() { fm_test_stall chmod "$@"; command chmod "$@"; }
mv() { fm_test_stall mv "$@"; command mv "$@"; }
printf() { fm_test_stall printf "$@"; builtin printf "$@"; }
SH
  . "$ROOT/bin/fm-timeout-lib.sh"
  for operation in stage mkdir ledger-temp error-temp rm chmod replace log; do
    home="$TMP_ROOT/locked-deadline-$operation"
    attempts="$home/attempts"
    mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
    : > "$attempts"
    jq -n --arg home "$home" '{
      schema:"fm-secondmate-home-summary.v1", hold_classifier_schema:"fm-captain-hold-buckets.v1",
      home:$home, generated:"2026-08-28T10:00:00Z", generated_epoch:1787911200,
      valid:true, state:"no_active_work", invalidity:{}, active_children:[], decisions_open:[],
      holds:[], queued:[], landed:[], endpoints:[], counts:{}, omitted:[]
    }' > "$home/summary.json"
    BASH_ENV="$stalls" FM_TEST_STALL_AT="$operation" FM_TEST_STALLED="$home/stalled" \
      FM_TEST_ATTEMPTS="$attempts" FM_TEST_SUMMARY="$home/summary.json" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_HOME_SUMMARY_TIMEOUT=8 \
      FM_TEST_SEAM=1 FM_NOW=1000 \
      fm_run_timed 30 "$code/bin/fm-home-summary-refresh.sh" --best-effort \
      2> "$home/refresh.err" || {
        cat "$home/refresh.err" >&2
        fail "$operation deadline escaped its bound or changed the caller result"
      }
    [ -e "$home/stalled" ] || fail "$operation fixture never reached its lock-held stall"
    actual=$(cat "$home/state/.home-summary-refresh.backoff" 2>/dev/null)
    if [ "$actual" != "$(printf 'failures=1\nnext=1030')" ]; then
      printf 'backoff after %s deadline: <%s>\n' "$operation" "$actual" >&2
      cat "$home/stalled" "$home/refresh.err" "$home/state/.home-summary-refresh.log" >&2
      ls -la "$home/state" >&2
      fail "$operation deadline did not record exactly one failure before unlock"
    fi
    expected=$(wc -l < "$attempts" | tr -d ' ')
    FM_TEST_STALL_AT=none FM_TEST_ATTEMPTS="$attempts" FM_TEST_SUMMARY="$home/summary.json" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_SEAM=1 FM_NOW=1001 \
      "$code/bin/fm-home-summary-refresh.sh" --best-effort \
      || fail "$operation retry changed the caller result"
    [ "$(wc -l < "$attempts" | tr -d ' ')" -eq "$expected" ] \
      || fail "$operation deadline allowed an immediate producer retry"
    FM_TEST_STALL_AT=none FM_TEST_ATTEMPTS="$attempts" FM_TEST_SUMMARY="$home/summary.json" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      "$code/bin/fm-home-summary-refresh.sh" \
      || fail "$operation recovery did not publish"
    cmp -s "$home/summary.json" "$home/state/home-summary.json" \
      || fail "$operation recovery did not publish the complete document"
    [ ! -e "$home/state/.home-summary-refresh.backoff" ] || fail "$operation recovery did not reset backoff"
  done
  FM_TEST_STALL_AT=log FM_TEST_ATTEMPTS="$attempts" FM_TEST_SUMMARY="$home/summary.json" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_SEAM=1 FM_NOW=2000 \
    "$code/bin/fm-home-summary-refresh.sh" --best-effort \
    || fail "an ordinary producer failure changed the best-effort result"
  [ "$(cat "$home/state/.home-summary-refresh.backoff")" = "$(printf 'failures=1\nnext=2030')" ] \
    || fail "an ordinary best-effort failure was not recorded exactly once"
  if FM_TEST_STALL_AT=log FM_TEST_ATTEMPTS="$attempts" FM_TEST_SUMMARY="$home/summary.json" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_SEAM=1 FM_NOW=2030 \
      "$code/bin/fm-home-summary-refresh.sh"; then
    fail "a direct producer failure returned success"
  fi
  [ "$(cat "$home/state/.home-summary-refresh.backoff")" = "$(printf 'failures=2\nnext=2090')" ] \
    || fail "a direct failure did not advance backoff exactly once"
  pass "every lock-held deadline records bounded backoff before admission resumes"
}

test_refresh_without_external_timer() {
  local home no_timer_env
  home="$TMP_ROOT/no-external-timer-home"
  no_timer_env="$TMP_ROOT/no-external-timer.sh"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  home=$(cd "$home" && pwd -P)
  printf '# Seeded Firstmate home\n' > "$home/AGENTS.md"
  printf 'fallback\n' > "$home/.fm-secondmate-home"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  cat > "$no_timer_env" <<'SH'
command() {
  case "${1:-}:${2:-}" in -v:perl) return 1 ;; esac
  builtin command "$@"
}
type() {
  case "${1:-}:${2:-}" in -P:timeout|-P:gtimeout) return 1 ;; esac
  builtin type "$@"
}
SH
  BASH_ENV="$no_timer_env" PATH="$FAKEBIN:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$WRITER" \
    || fail "refresh failed without Perl or an external timeout"
  jq -e --arg home "$home" '
    .schema == "fm-secondmate-home-summary.v1" and .home == $home and .valid == true
  ' "$home/state/home-summary.json" >/dev/null \
    || fail "the bounded Bash fallback did not publish a complete summary"
  [ ! -d "$home/state/.home-summary-refresh.lock" ] \
    || fail "the bounded Bash fallback retained the publication lock"
  pass "refresh publishes through the bounded Bash fallback without an external timer"
}

if [ "$#" -gt 0 ]; then
  fm_test_run "$@"
  exit
fi

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

run_writer "$NOW_ONE" "$EPOCH_ONE" || fail "initial home-summary publication failed"
jq -e --arg home "$HOME_DIR" --arg now "$NOW_ONE" --argjson epoch "$EPOCH_ONE" '
  .schema == "fm-secondmate-home-summary.v1"
  and .home == $home
  and .generated == $now
  and .generated_epoch == $epoch
' "$HOME_DIR/state/home-summary.json" >/dev/null \
  || fail "initial ledger did not expose the extended producer schema"

PATH="$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_SNAPSHOT_NOW="$NOW_TWO" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_TWO" \
  FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  "$WATCH" > "$TMP_ROOT/watch.out" 2> "$TMP_ROOT/watch.err" &
WATCH_PID=$!
i=0
while [ ! -e "$HOME_DIR/state/.last-watcher-beat" ] && [ "$i" -lt 100 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$HOME_DIR/state/.last-watcher-beat" ] \
  || fail "the real watcher did not begin polling: $(cat "$TMP_ROOT/watch.err" 2>/dev/null)"
printf 'blocked [key=fixture-dependency]: waiting for the fixture dependency\n' \
  >> "$HOME_DIR/state/ledger-task.status"
wait_for_ledger_generation "$NOW_TWO" \
  || fail "a status append did not refresh the ledger within the watcher cadence"
wait "$WATCH_PID" >/dev/null 2>&1 || true
WATCH_PID=

run_producer "$NOW_TWO" "$EPOCH_TWO" > "$TMP_ROOT/fresh-summary.json" \
  || fail "fresh secondmate-home-summary production failed"
jq -S 'del(.generated, .generated_epoch)' "$HOME_DIR/state/home-summary.json" \
  > "$TMP_ROOT/published-normalized.json"
jq -S 'del(.generated, .generated_epoch)' "$TMP_ROOT/fresh-summary.json" \
  > "$TMP_ROOT/fresh-normalized.json"
cmp -s "$TMP_ROOT/published-normalized.json" "$TMP_ROOT/fresh-normalized.json" \
  || fail "the status-triggered ledger differed from the real fresh producer"
pass "watcher-carried status append publishes the real home summary"

# A structured in-flight inventory above Linux MAX_ARG_STRLEN must remain
# publishable through every fleet snapshot mode and the real home-summary writer.
mkdir -p "$LARGE_HOME/state" "$LARGE_HOME/data" "$LARGE_HOME/config" \
  "$LARGE_HOME/projects"
printf '# Seeded Firstmate home\n' > "$LARGE_HOME/AGENTS.md"
printf 'large\n' > "$LARGE_HOME/.fm-secondmate-home"
large_id_suffix=$(printf 'i%.0s' $(seq 1 110))
{
  printf '%s\n' '## In flight'
  i=1
  while [ "$i" -le 1200 ]; do
    printf '%s\n' "- [ ] orphan-$i-$large_id_suffix - Missing metadata (repo: firstmate) (kind: ship)"
    i=$((i + 1))
  done
  printf '%s\n' '' '## Queued' '' '## Done'
} > "$LARGE_HOME/data/backlog.md"
[ "$(wc -c < "$LARGE_HOME/data/backlog.md")" -gt 131072 ] \
  || fail "large in-flight fixture did not exceed the per-argument limit"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LARGE_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$SNAPSHOT" --json > "$TMP_ROOT/large-snapshot.json" \
  || fail "fleet snapshot json mode failed for a large backlog"
jq -e '.schema == "fm-fleet-snapshot.v1"
  and (.backlog.records | length) == 1200
  and (.main_inventory.orphan_in_flight | length) == 1200' \
  "$TMP_ROOT/large-snapshot.json" >/dev/null \
  || fail "large fleet snapshot did not preserve the orphan inventory"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LARGE_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$SNAPSHOT" --secondmate-home-summary > "$TMP_ROOT/large-summary.json" \
  || fail "secondmate home-summary mode failed for a large backlog"
jq -e '.schema == "fm-secondmate-home-summary.v1"' "$TMP_ROOT/large-summary.json" \
  >/dev/null || fail "large secondmate home-summary output was not valid"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LARGE_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$SNAPSHOT" --contribution-input > "$TMP_ROOT/large-contribution-input.json" \
  || fail "contribution-input mode failed for a large backlog"
jq -e '(.backlog.records | length) == 1200 and (.tasks | type) == "array"' \
  "$TMP_ROOT/large-contribution-input.json" >/dev/null \
  || fail "large contribution input did not preserve the backlog records"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LARGE_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$WRITER" || fail "home-summary writer failed for a large backlog"
jq -e '.schema == "fm-secondmate-home-summary.v1"' \
  "$LARGE_HOME/state/home-summary.json" >/dev/null \
  || fail "large secondmate home-summary was not published"
pass "large backlog snapshots and home-summary publication stay within exec limits"

mkdir -p "$STATELESS_HOME/data" "$STATELESS_HOME/config" \
  "$STATELESS_HOME/projects"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' \
  > "$STATELESS_HOME/data/backlog.md"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$STATELESS_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$SNAPSHOT" --json > "$TMP_ROOT/stateless-snapshot.json" \
  || fail "fleet snapshot json mode failed without a state directory"
jq -e '.schema == "fm-fleet-snapshot.v1" and (.tasks | length) == 0' \
  "$TMP_ROOT/stateless-snapshot.json" >/dev/null \
  || fail "stateless fleet snapshot output was not valid"
[ ! -e "$STATELESS_HOME/state" ] \
  || fail "fleet snapshot created operational state for transport files"
pass "fleet snapshot transport does not require or mutate operational state"

mkdir -p "$LARGE_CHILD_HOME/state" "$LARGE_CHILD_HOME/data" \
  "$LARGE_CHILD_HOME/config" "$LARGE_CHILD_HOME/projects" "$LARGE_CHILD_HOME/bin"
printf '# Seeded Firstmate home\n' > "$LARGE_CHILD_HOME/AGENTS.md"
printf 'large-child\n' > "$LARGE_CHILD_HOME/.fm-secondmate-home"
{
  printf '%s\n' '## In flight'
  i=1
  while [ "$i" -le 600 ]; do
    printf '%s\n' "- [ ] orphan-$i-$large_id_suffix - Missing metadata (repo: firstmate) (kind: ship)"
    i=$((i + 1))
  done
  printf '%s\n' '' '## Queued' '' '## Done'
} > "$LARGE_CHILD_HOME/data/backlog.md"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LARGE_CHILD_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$WRITER" || fail "large child home-summary publication failed"
large_child_bytes=$(wc -c < "$LARGE_CHILD_HOME/state/home-summary.json")
[ "$large_child_bytes" -gt 131072 ] && [ "$large_child_bytes" -le 262144 ] \
  || fail "large child ledger did not cross only the per-argument limit: $large_child_bytes"
mkdir -p "$LARGE_PARENT_HOME/state" "$LARGE_PARENT_HOME/data" \
  "$LARGE_PARENT_HOME/config" "$LARGE_PARENT_HOME/projects"
printf -- '- large-child - fixture domain (home: %s; scope: fixture work; projects: firstmate; added 2026-08-28)\n' \
  "$LARGE_CHILD_HOME" > "$LARGE_PARENT_HOME/data/secondmates.md"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' \
  > "$LARGE_PARENT_HOME/data/backlog.md"
fm_write_secondmate_meta "$LARGE_PARENT_HOME/state/large-child.meta" \
  "$LARGE_CHILD_HOME" "fmtest:fm-large-child" firstmate claude
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$PARENT_CODE_ROOT" FM_HOME="$LARGE_PARENT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$SNAPSHOT" --json > "$TMP_ROOT/large-parent-snapshot.json" \
  || fail "parent fleet snapshot failed for a large child ledger"
jq -e '.secondmate_current.records[0]
  | .provenance.summary_source == "local-ledger"
    and .invalidity.kind == "orphan_in_flight"
    and (.invalidity.ids | length) == 600' \
  "$TMP_ROOT/large-parent-snapshot.json" >/dev/null \
  || fail "parent fleet snapshot did not preserve the large child invalidity"
pass "parent snapshot consumes large child ledgers without argument transport"

mkdir -p "$CADENCE_HOME/state" "$CADENCE_HOME/data" "$CADENCE_HOME/config" \
  "$CADENCE_HOME/projects"
printf '# Seeded Firstmate home\n' > "$CADENCE_HOME/AGENTS.md"
printf 'cadence\n' > "$CADENCE_HOME/.fm-secondmate-home"
cat > "$CADENCE_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CADENCE_HOME" \
  FM_SNAPSHOT_NOW="$NOW_TWO" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_TWO" \
  "$WRITER" || fail "could not seed the cadence ledger"
touch -t 203801010000 "$CADENCE_HOME/state/home-summary.json"
PATH="$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CADENCE_HOME" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=1 FM_SIGNAL_GRACE=0 \
  FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  "$WATCH" > "$TMP_ROOT/cadence-watch.out" 2> "$TMP_ROOT/cadence-watch.err" &
WATCH_PID=$!
i=0
while [ ! -e "$CADENCE_HOME/state/.last-watcher-beat" ] && [ "$i" -lt 100 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$CADENCE_HOME/state/.last-watcher-beat" ] \
  || fail "the cadence watcher did not complete its initial cycle"
python3 - "$CADENCE_HOME/data/backlog.md" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
path.write_text(text.replace("## Queued\n\n## Done", "## Queued\n- [ ] cadence-task - Publish without a status signal (repo: firstmate) (kind: ship)\n\n## Done"))
PY
i=0
while ! jq -e 'any(.queued[]; .id == "cadence-task")' \
  "$CADENCE_HOME/state/home-summary.json" >/dev/null 2>&1; do
  kill -0 "$WATCH_PID" 2>/dev/null \
    || fail "the cadence watcher exited before publishing the backlog-only change"
  [ "$i" -lt 80 ] \
    || fail "a backlog-only change did not refresh within the configured watcher cadence"
  sleep 0.1
  i=$((i + 1))
done
kill "$WATCH_PID" >/dev/null 2>&1 || true
wait "$WATCH_PID" >/dev/null 2>&1 || true
WATCH_PID=
pass "live watcher cadence bounds publication staleness without signals"

test_summary_jitter_shortens_idle_launches
test_failed_summary_refresh_waits_for_idle
test_locked_deadlines_record_backoff
test_refresh_without_external_timer

# Consumer boundary: first serialize behind any watcher-started publication,
# then replace the ledger with a structurally complete but semantically false
# state. The default parent snapshot must consume that publication rather than
# silently recomputing a different view of the owning home.
run_writer "$NOW_TWO" "$EPOCH_TWO" || fail "could not settle the ledger before the consumer check"
jq '.state = "no_active_work" | .active_children = [] | .holds = []
    | .counts.active_children = 0 | .counts.holds = 0' \
  "$HOME_DIR/state/home-summary.json" > "$HOME_DIR/state/home-summary.poisoned"
mv -f "$HOME_DIR/state/home-summary.poisoned" "$HOME_DIR/state/home-summary.json"
mkdir -p "$PARENT_HOME/state" "$PARENT_HOME/data" "$PARENT_HOME/config" "$PARENT_HOME/projects"
printf -- '- mate - fixture domain (home: %s; scope: fixture work; projects: firstmate; added 2026-08-28)\n' \
  "$HOME_DIR" > "$PARENT_HOME/data/secondmates.md"
cat > "$PARENT_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
fm_write_secondmate_meta "$PARENT_HOME/state/mate.meta" "$HOME_DIR" \
  "fmtest:fm-mate" firstmate claude
PATH="$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$PARENT_CODE_ROOT" FM_HOME="$PARENT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_TWO" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_TWO" \
  "$SNAPSHOT" --json > "$TMP_ROOT/parent-snapshot.json" \
  || fail "parent fleet snapshot failed"
jq -e '
  .secondmate_current.records[0].provenance.selected == "structured-home"
  and .secondmate_current.records[0].provenance.summary_source == "local-ledger"
  and .secondmate_current.records[0].current.state == "no_active_work"
  and (.secondmate_current.records[0].active_children | length) == 0
  and (.secondmate_current.records[0].holds | length) == 0
' "$TMP_ROOT/parent-snapshot.json" >/dev/null \
  || fail "fleet snapshot did not consume the published local ledger: $(jq -c '.secondmate_current.records[0]' "$TMP_ROOT/parent-snapshot.json")"
pass "fleet snapshot consumes the published local ledger by default"

# Stop the writer after real validation accepts the old document.
# The prior ledger must stay complete, and replacement publication must survive
# the old attempt finishing after its lock owner is killed.
run_writer "$NOW_TWO" "$EPOCH_TWO" || fail "could not restore the real ledger"
printf 'working: replacement summary is being computed\n' \
  >> "$HOME_DIR/state/ledger-task.status"
cp "$HOME_DIR/state/home-summary.json" "$TMP_ROOT/prior-ledger.json"
SLOW_MARKER="$TMP_ROOT/slow-validator.pid"
VALIDATION_RELEASE="$TMP_ROOT/validation-release"
VALIDATION_BIN="$TMP_ROOT/validation-bin"
mkdir -p "$VALIDATION_BIN"
cat > "$VALIDATION_BIN/jq" <<'SH'
#!/usr/bin/env bash
jq_rc=0
"$FM_TEST_REAL_JQ" "$@" || jq_rc=$?
for arg in "$@"; do
  case "$arg" in
    */.home-summary.json.*)
      [ "$jq_rc" -eq 0 ] || exit "$jq_rc"
      printf '%s\n' "$$" > "$FM_TEST_VALIDATOR_MARKER"
      while [ ! -e "$FM_TEST_VALIDATION_RELEASE" ]; do sleep 0.1; done
      ;;
  esac
done
exit "$jq_rc"
SH
chmod +x "$VALIDATION_BIN/jq"
PATH="$VALIDATION_BIN:$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  FM_TEST_REAL_JQ="$REAL_JQ" FM_TEST_VALIDATOR_MARKER="$SLOW_MARKER" \
  FM_TEST_VALIDATION_RELEASE="$VALIDATION_RELEASE" FM_HOME_SUMMARY_TIMEOUT=120 \
  "$WRITER" > "$TMP_ROOT/killed-writer.out" 2> "$TMP_ROOT/killed-writer.err" &
SLOW_WRITER_PID=$!
i=0
while [ ! -s "$SLOW_MARKER" ] && [ "$i" -lt 100 ]; do
  kill -0 "$SLOW_WRITER_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -s "$SLOW_MARKER" ] || fail "the writer did not reach controlled validation of a valid document"
SLOW_VALIDATOR_PID=$(cat "$SLOW_MARKER")
writer_pgid=$(ps -o pgid= -p "$SLOW_WRITER_PID" 2>/dev/null | tr -d '[:space:]')
ancestor=$SLOW_VALIDATOR_PID
slow_ancestors=
child_pgid=
i=0
while [ "$i" -lt 20 ]; do
  slow_ancestors="${slow_ancestors:+$slow_ancestors,}$ancestor"
  ancestor_pgid=$(ps -o pgid= -p "$ancestor" 2>/dev/null | tr -d '[:space:]')
  parent=$(ps -o ppid= -p "$ancestor" 2>/dev/null | tr -d '[:space:]')
  if [ "$parent" = "$SLOW_WRITER_PID" ]; then
    if [ "$ancestor_pgid" != "$writer_pgid" ]; then
      SLOW_WORKER_PGID=$ancestor_pgid
    else
      SLOW_WORKER_PGID=$child_pgid
    fi
    break
  fi
  child_pgid=$ancestor_pgid
  ancestor=$parent
  i=$((i + 1))
done
case "$SLOW_WORKER_PGID" in
  ''|*[!0-9]*) fail "the bounded writer did not expose its worker process group" ;;
esac
[ "$SLOW_WORKER_PGID" != "$writer_pgid" ] \
  || fail "the bounded worker did not have an isolated process group"
kill -KILL -- "-$SLOW_WORKER_PGID" >/dev/null 2>&1 \
  || fail "the bounded writer process group could not be terminated"
wait "$SLOW_WRITER_PID" >/dev/null 2>&1 || true
SLOW_WRITER_PID=
SLOW_WORKER_PGID=
jq -e . "$HOME_DIR/state/home-summary.json" >/dev/null \
  || fail "killing the writer exposed invalid JSON at the ledger path"
cmp -s "$TMP_ROOT/prior-ledger.json" "$HOME_DIR/state/home-summary.json" \
  || fail "killing the writer replaced the prior complete ledger"

# Observe the ledger continuously through one successful replacement. Every read
# must parse, and the final document must be the newly computed complete summary.
READER_FAILURE="$TMP_ROOT/reader-failure"
SUCCESS_MARKER="$TMP_ROOT/success-no-mistakes.pid"
PATH="$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  FM_TEST_NM_MARKER="$SUCCESS_MARKER" FM_TEST_NM_SLEEP=1 \
  "$WRITER" > "$TMP_ROOT/success-writer.out" 2> "$TMP_ROOT/success-writer.err" &
SLOW_WRITER_PID=$!
while kill -0 "$SLOW_WRITER_PID" 2>/dev/null; do
  if ! jq -e . "$HOME_DIR/state/home-summary.json" >/dev/null 2>&1; then
    : > "$READER_FAILURE"
    break
  fi
done
if ! wait "$SLOW_WRITER_PID"; then
  SLOW_WRITER_PID=
  fail "successful atomic replacement failed: $(cat "$TMP_ROOT/success-writer.err" 2>/dev/null)"
fi
SLOW_WRITER_PID=
[ ! -e "$READER_FAILURE" ] || fail "a reader observed torn JSON during atomic replacement"
jq -e --arg now "$NOW_THREE" --argjson epoch "$EPOCH_THREE" '
  .generated == $now and .generated_epoch == $epoch
' "$HOME_DIR/state/home-summary.json" >/dev/null \
  || fail "the successful replacement did not publish the new complete document"
: > "$VALIDATION_RELEASE"
i=0
while ps -p "$slow_ancestors" -o stat= 2>/dev/null \
    | awk '$1 !~ /^Z/ { alive=1 } END { exit !alive }'; do
  [ "$i" -lt 600 ] || fail "the interrupted attempt did not finish within its controlled delay"
  sleep 0.1
  i=$((i + 1))
done
SLOW_VALIDATOR_PID=
jq -e --arg now "$NOW_THREE" --argjson epoch "$EPOCH_THREE" '
  .generated == $now and .generated_epoch == $epoch
' "$HOME_DIR/state/home-summary.json" >/dev/null \
  || fail "an interrupted attempt overwrote the newer replacement ledger"
pass "writer interruption cannot overwrite a later atomic replacement"

# Best-effort mode is the contract used by every lifecycle trigger. A failed
# producer records the failure and returns success without touching the ledger.
FAILBIN="$TMP_ROOT/failbin"
mkdir -p "$FAILBIN"
cat > "$FAILBIN/jq" <<'SH'
#!/usr/bin/env bash
exit 7
SH
chmod +x "$FAILBIN/jq"
cp "$HOME_DIR/state/home-summary.json" "$TMP_ROOT/before-best-effort.json"
PATH="$FAILBIN:$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  "$WRITER" --best-effort \
  || fail "best-effort refresh propagated its producer failure"
cmp -s "$TMP_ROOT/before-best-effort.json" "$HOME_DIR/state/home-summary.json" \
  || fail "failed best-effort refresh changed the prior ledger"
grep -F 'summary producer failed' "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null \
  || fail "best-effort refresh did not log its failure"
pass "best-effort publication logs and continues"

LOCK_MARKER="$TMP_ROOT/lock-held"
rm -f "$HOME_DIR/state/.home-summary-refresh.log" \
  "$HOME_DIR/state/.home-summary-refresh.backoff"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"
  : > "$3"
  # Held until killed below: on a loaded host the timed steps that need the
  # lock busy can together outlast any short fixed hold.
  exec sleep 600
' _ "$ROOT" "$HOME_DIR" "$LOCK_MARKER" &
LOCK_HOLDER_PID=$!
i=0
while [ ! -e "$LOCK_MARKER" ] && [ "$i" -lt 100 ]; do
  kill -0 "$LOCK_HOLDER_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$LOCK_MARKER" ] || fail "could not hold the publication lock for timeout coverage"
started=$(date +%s)
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_HOME_SUMMARY_TIMEOUT=1 "$WRITER" --best-effort \
  || fail "lock timeout changed the best-effort caller result"
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 4 ] || fail "best-effort refresh waited $elapsed seconds on its lock"
rm -f "$HOME_DIR/state/.home-summary-refresh.backoff"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_HOME_SUMMARY_TIMEOUT=1 "$WRITER" --best-effort \
  || fail "repeated lock timeout changed the best-effort caller result"
[ "$(grep -c 'refresh exceeded its 1-second deadline' "$HOME_DIR/state/.home-summary-refresh.log" 2>/dev/null || true)" -ge 2 ] \
  || fail "repeated publication lock timeouts vanished from failure reporting"
# A deadline hit while queued behind another refresh must name the lock wait.
: > "$HOME_DIR/state/.home-summary-refresh.log"
rm -f "$HOME_DIR/state/.home-summary-refresh.backoff"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_HOME_SUMMARY_TIMEOUT=3 "$WRITER" --best-effort \
  || fail "a lock-wait timeout changed the best-effort caller result"
grep -F 'refresh exceeded its 3-second deadline in stage lock-wait' \
  "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null \
  || fail "the lock wait was not named in the failure log: $(cat "$HOME_DIR/state/.home-summary-refresh.log")"
[ ! -e "$HOME_DIR/state/.home-summary-refresh.backoff" ] \
  || fail "a lock-wait timeout changed another owner's backoff"
printf 'failures=2\nnext=0\n' > "$HOME_DIR/state/.home-summary-refresh.backoff"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_HOME_SUMMARY_IF_IDLE=1 FM_HOME_SUMMARY_TIMEOUT=30 "$WRITER" \
  || fail "an if-idle refresh behind a held lock did not skip cleanly"
[ -f "$HOME_DIR/state/.home-summary-refresh.backoff" ] \
  || fail "an if-idle refresh that skipped a held lock cleared the backoff"
kill "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
wait "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
LOCK_HOLDER_PID=
pass "best-effort refresh bounds publication lock acquisition"

# A refresh that blows its deadline inside a slow stage must name that stage in
# the failure log, and must leave the last good summary untouched so it keeps its
# own generated timestamp rather than the time of the failed attempt.
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

# Signalling the parent while its worker is still running must not leak the
# per-attempt stage file in state/.
SIGNAL_MARKER="$TMP_ROOT/signal-no-mistakes.pid"
rm -f "$SIGNAL_MARKER" "$HOME_DIR/state/.home-summary-refresh.backoff"
printf 'working: a status change forces a recompute\n' >> "$HOME_DIR/state/ledger-task.status"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  FM_TEST_NM_MARKER="$SIGNAL_MARKER" FM_TEST_NM_SLEEP=30 \
  "$WRITER" --best-effort > /dev/null 2>&1 &
SLOW_WRITER_PID=$!
i=0
while [ ! -s "$SIGNAL_MARKER" ] && [ "$i" -lt 200 ]; do
  kill -0 "$SLOW_WRITER_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -s "$SIGNAL_MARKER" ] || fail "the signalled-parent refresh never reached its slow worker"
ls "$HOME_DIR/state"/.home-summary-stage.* >/dev/null 2>&1 \
  || fail "the parent did not create a stage file to clean up"
kill -TERM "$SLOW_WRITER_PID" >/dev/null 2>&1 || true
wait "$SLOW_WRITER_PID" >/dev/null 2>&1 || true
SLOW_WRITER_PID=
signal_nm_pid=$(cat "$SIGNAL_MARKER" 2>/dev/null || true)
[ -z "$signal_nm_pid" ] || kill -KILL "$signal_nm_pid" >/dev/null 2>&1 || true
ls "$HOME_DIR/state"/.home-summary-stage.* >/dev/null 2>&1 \
  && fail "a signalled parent leaked its stage file"
pass "a signalled parent removes its stage file"

# The producer reports stages only through a descriptor its caller opened, never
# by path: a stage file the caller already removed (a signalled parent cleaned it
# up) is not recreated, and a descriptor that is not open is ignored.
GONE_LOG="$TMP_ROOT/gone-stage.log"
: > "$GONE_LOG"
exec 9>>"$GONE_LOG"
rm -f "$GONE_LOG"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  FM_SNAPSHOT_STAGE_FD=9 "$SNAPSHOT" --secondmate-home-summary >/dev/null 2>&1 \
  || fail "the producer failed with a removed stage file"
exec 9>&-
[ ! -e "$GONE_LOG" ] || fail "the producer recreated a removed stage file"
LIVE_LOG="$TMP_ROOT/live-stage.log"
: > "$LIVE_LOG"
exec 9>>"$LIVE_LOG"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  FM_SNAPSHOT_STAGE_FD=9 "$SNAPSHOT" --secondmate-home-summary >/dev/null 2>&1 \
  || fail "the producer failed with a live stage descriptor"
exec 9>&-
grep -E '^summary	[0-9]+$' "$LIVE_LOG" >/dev/null \
  || fail "the producer did not report its stages to the open descriptor"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  FM_SNAPSHOT_STAGE_FD=7 "$SNAPSHOT" --secondmate-home-summary >/dev/null 2>&1 \
  || fail "the producer failed with a stage descriptor that is not open"
pass "the producer never recreates a deleted stage log"

# Opening the stage file is bounded by the refresh deadline: the worker, not the
# parent, creates and opens it. A stage path that blocks on open (a named pipe
# with no reader) stands in for a stalled filesystem, and only a refresh whose
# parent never touches that path inside its own process returns in time.
STALL_PATH="$HOME_DIR/state/.home-summary-stage.stalled"
rm -f "$STALL_PATH"
mkfifo "$STALL_PATH"
: > "$HOME_DIR/state/.home-summary-refresh.log"
started=$(date +%s)
PATH="$FAKEBIN:$PATH" FM_HOME_SUMMARY_STAGE_PATH="$STALL_PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_HOME_SUMMARY_TIMEOUT=2 \
  "$WRITER" --best-effort \
  || fail "a stalled stage-file open changed the best-effort caller result"
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 20 ] || fail "a stalled stage-file open held the refresh for $elapsed seconds"
grep -F 'refresh exceeded its 2-second deadline before its first stage' \
  "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null \
  || fail "a stalled stage-file open was not logged: $(cat "$HOME_DIR/state/.home-summary-refresh.log")"
[ ! -e "$STALL_PATH" ] || fail "a stalled stage-file open left its stage path behind"
pass "stage-file open is bounded by the refresh deadline"

HANGBIN="$TMP_ROOT/hangbin"
mkdir -p "$HANGBIN"
cat > "$HANGBIN/jq" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */.home-summary.json.*) sleep 120 ;;
  esac
done
exec "$FM_TEST_REAL_JQ" "$@"
SH
chmod +x "$HANGBIN/jq"
rm -f "$HOME_DIR/state/.home-summary-refresh.backoff"
started=$(date +%s)
PATH="$HANGBIN:$FAKEBIN:$PATH" FM_TEST_REAL_JQ="$REAL_JQ" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_HOME_SUMMARY_TIMEOUT=1 \
  "$WRITER" --best-effort \
  || fail "validation timeout changed the best-effort caller result"
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 4 ] || fail "best-effort refresh waited $elapsed seconds on validation"
grep -F 'refresh exceeded its 1-second deadline' \
  "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null \
  || fail "publication validation timeout was not logged"
pass "best-effort refresh bounds validation and publication"

# A worker killed at the deadline right after it created the stage file must not
# leave that file behind: the parent removes the name it handed out.
# Use the normal 60-second collection budget here. A short budget can expire
# during task observation on a loaded host, before the blocked validation this
# case needs to exercise. Keep validation blocked beyond that whole budget.
ORPHAN_PATH="$HOME_DIR/state/.home-summary-stage.orphan"
rm -f "$ORPHAN_PATH" "$HOME_DIR/state/.home-summary-refresh.backoff"
: > "$HOME_DIR/state/.home-summary-refresh.log"
PATH="$HANGBIN:$FAKEBIN:$PATH" FM_TEST_REAL_JQ="$REAL_JQ" \
  FM_HOME_SUMMARY_STAGE_PATH="$ORPHAN_PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_HOME_SUMMARY_TIMEOUT=60 \
  "$WRITER" --best-effort \
  || fail "a deadline hit after stage-file creation changed the best-effort caller result"
grep -F 'refresh exceeded its 60-second deadline in stage validate' \
  "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null \
  || fail "the worker did not write to the stage file the parent named: $(cat "$HOME_DIR/state/.home-summary-refresh.log")"
[ ! -e "$ORPHAN_PATH" ] || fail "a worker killed after creating the stage file left it behind"
pass "a stage file created before a deadline kill is removed"

# After the worker ends, the parent reads the stage file and removes it under its
# own short limit, so a state filesystem that stalls on those operations cannot
# hold the caller past the deadline. The shims stall tail and rm on the stage
# path only; a FIFO could not show this, because stat and unlink never block on one.
STALLFS="$TMP_ROOT/stall-fs-bin"
REAL_RM=$(command -v rm)
mkdir -p "$STALLFS"
for shim in tail rm; do
  real=$(command -v "$shim")
  cat > "$STALLFS/$shim" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    */.home-summary-stage.*) sleep 30 ;;
  esac
done
exec "$real" "\$@"
SH
  chmod +x "$STALLFS/$shim"
done
: > "$HOME_DIR/state/.home-summary-refresh.log"; rm -f "$HOME_DIR/state/.home-summary-refresh.backoff"
started=$(date +%s)
PATH="$STALLFS:$HANGBIN:$FAKEBIN:$PATH" FM_TEST_REAL_JQ="$REAL_JQ" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_HOME_SUMMARY_TIMEOUT=3 \
  "$WRITER" --best-effort \
  || fail "a stalled stage-file read changed the best-effort caller result"
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 20 ] || fail "stalled parent-side stage-file operations held the refresh for $elapsed seconds"
grep -F 'refresh exceeded its 3-second deadline' "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null \
  || fail "the deadline was not logged when parent-side stage operations stalled: $(cat "$HOME_DIR/state/.home-summary-refresh.log")"
grep -F 'refresh exceeded its 3-second deadline (stage unreadable)' "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null \
  || fail "an unreadable stage file was not reported as unreadable: $(cat "$HOME_DIR/state/.home-summary-refresh.log")"
if grep -F 'before its first stage' "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null; then
  fail "an unreadable stage file was reported as a deadline before the first stage"
fi
"$REAL_RM" -f "$HOME_DIR/state"/.home-summary-stage.*
pass "parent-side stage-file reads and removals are bounded"

# A stage file that cannot be read at all (not stalled, failing at once) is
# reported as unreadable, never as a worker that recorded no stage.
FAILTAIL="$TMP_ROOT/fail-tail-bin"
mkdir -p "$FAILTAIL"
cat > "$FAILTAIL/tail" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */.home-summary-stage.*) echo "tail: read error" >&2; exit 1 ;;
  esac
done
exec "$FM_TEST_REAL_TAIL" "$@"
SH
chmod +x "$FAILTAIL/tail"
: > "$HOME_DIR/state/.home-summary-refresh.log"; rm -f "$HOME_DIR/state/.home-summary-refresh.backoff"
PATH="$FAILTAIL:$HANGBIN:$FAKEBIN:$PATH" FM_TEST_REAL_JQ="$REAL_JQ" FM_TEST_REAL_TAIL="$REAL_TAIL" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_HOME_SUMMARY_TIMEOUT=3 \
  "$WRITER" --best-effort \
  || fail "an unreadable stage file changed the best-effort caller result"
grep -F 'refresh exceeded its 3-second deadline (stage unreadable)' "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null \
  || fail "an immediately failing stage read was not reported as unreadable: $(cat "$HOME_DIR/state/.home-summary-refresh.log")"
if grep -F 'before its first stage' "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null; then
  fail "an immediately failing stage read was reported as a deadline before the first stage"
fi
pass "an unreadable stage file is reported as unreadable"

# Kill the parent before the worker opens its stage file. The timeout runner may
# cancel the worker before that open, or the worker may finish and clean up its
# own stage file. Neither path may leave a running worker or a stage file behind.
SLOWBIN="$TMP_ROOT/slow-orphan-bin"
REAL_MKDIR=$(command -v mkdir)
mkdir -p "$SLOWBIN"
cat > "$SLOWBIN/mkdir" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_HOME_SUMMARY_STAGE_FILE:-}" ] && [ -n "${FM_TEST_MKDIR_MARK:-}" ] \
    && [ ! -e "$FM_TEST_MKDIR_MARK" ]; then
  printf '%s\n' "$PPID" > "$FM_TEST_MKDIR_MARK"
  sleep 3
fi
exec "$FM_TEST_REAL_MKDIR" "$@"
SH
chmod +x "$SLOWBIN/mkdir"
ORPHAN_MARK="$TMP_ROOT/orphan-mkdir.mark"
rm -f "$ORPHAN_MARK" "$HOME_DIR/state"/.home-summary-stage.* "$HOME_DIR/state/.home-summary-refresh.backoff"
printf 'working: a status change forces a recompute\n' >> "$HOME_DIR/state/ledger-task.status"
PATH="$SLOWBIN:$FAKEBIN:$PATH" FM_TEST_REAL_MKDIR="$REAL_MKDIR" FM_TEST_REAL_JQ="$REAL_JQ" \
  FM_TEST_MKDIR_MARK="$ORPHAN_MARK" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  "$WRITER" --best-effort > /dev/null 2>&1 &
ORPHAN_PARENT=$!
i=0
while [ ! -e "$ORPHAN_MARK" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
[ -e "$ORPHAN_MARK" ] || fail "the worker never reached its state-directory step"
ORPHAN_WORKER_PID=$(cat "$ORPHAN_MARK")
SLOW_WORKER_PGID=$(ps -o pgid= -p "$ORPHAN_WORKER_PID" 2>/dev/null | tr -d '[:space:]')
test_pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]')
case "$SLOW_WORKER_PGID" in
  ''|*[!0-9]*) fail "the orphan fixture did not record its worker process group" ;;
esac
[ "$SLOW_WORKER_PGID" != "$test_pgid" ] \
  || fail "the orphan fixture worker did not have an isolated process group"
kill -KILL "$ORPHAN_PARENT" >/dev/null 2>&1 || true
wait "$ORPHAN_PARENT" >/dev/null 2>&1 || true
i=0
while ps -p "$ORPHAN_WORKER_PID" -o stat= 2>/dev/null \
    | awk '$1 !~ /^Z/ { alive=1 } END { exit !alive }'; do
  [ "$i" -lt 900 ] || fail "a refresh worker outlived its parent's death and refresh deadline"
  sleep 0.1
  i=$((i + 1))
done
SLOW_WORKER_PGID=
if ls "$HOME_DIR/state"/.home-summary-stage.* >/dev/null 2>&1; then
  fail "a worker whose parent is gone left its stage file behind"
fi
pass "parent loss leaves no running refresh worker or stage file"

# A fresh home has no state directory when the refresh starts. The wake library
# creates it in the worker before the stage file is opened, so a deadline hit on a
# first refresh still names its stage rather than claiming it never started.
FRESH_HOME="$TMP_ROOT/fresh-home"
rm -rf "${FRESH_HOME:?}"
cp -R "$HOME_DIR" "$FRESH_HOME"
rm -rf "${FRESH_HOME:?}/state"
PATH="$HANGBIN:$FAKEBIN:$PATH" FM_TEST_REAL_JQ="$REAL_JQ" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$FRESH_HOME" FM_HOME_SUMMARY_TIMEOUT=60 \
  "$WRITER" --best-effort \
  || fail "a first refresh on a home without a state directory changed the best-effort caller result"
grep -F 'refresh exceeded its 60-second deadline in stage validate' \
  "$FRESH_HOME/state/.home-summary-refresh.log" >/dev/null \
  || fail "a first refresh with no state directory did not name its stage: $(cat "$FRESH_HOME/state/.home-summary-refresh.log" 2>&1)"
pass "a first refresh on a home without a state directory names its stage"

# The stage path override is honored only for a path under the state directory
# named like the default. A stray value pointing elsewhere must not make the
# refresh append to or delete an unrelated file.
DECOY="$TMP_ROOT/decoy-not-a-stage-file"
printf 'keep me\n' > "$DECOY"
PATH="$FAKEBIN:$PATH" FM_HOME_SUMMARY_STAGE_PATH="$DECOY" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  "$WRITER" || fail "a stray stage path override broke a normal refresh"
[ "$(cat "$DECOY")" = "keep me" ] || fail "a stray stage path override let the refresh modify or delete an unrelated file"
printf 'working: status change\n' >> "$HOME_DIR/state/ledger-task.status"
PATH="$HANGBIN:$FAKEBIN:$PATH" FM_TEST_REAL_JQ="$REAL_JQ" FM_HOME_SUMMARY_STAGE_PATH="$DECOY" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_HOME_SUMMARY_TIMEOUT=3 \
  "$WRITER" --best-effort || fail "a stray stage path override changed a failing best-effort refresh"
[ "$(cat "$DECOY")" = "keep me" ] || fail "a failing refresh touched an unrelated file named by a stray override"
pass "a stray stage path override never touches an unrelated file"

# A deadline hit while validating, or while publishing, must name that stage
# rather than blaming the producer's last stage, and the offsets must share one
# timeline that includes the worker's own stages.
# As above, allow the normal collection budget before requiring a late stage.
: > "$HOME_DIR/state/.home-summary-refresh.log"; rm -f "$HOME_DIR/state/.home-summary-refresh.backoff"
PATH="$HANGBIN:$FAKEBIN:$PATH" FM_TEST_REAL_JQ="$REAL_JQ" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_HOME_SUMMARY_TIMEOUT=60 \
  "$WRITER" --best-effort \
  || fail "a validation stage timeout changed the best-effort caller result"
grep -F 'refresh exceeded its 60-second deadline in stage validate' \
  "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null \
  || fail "the validate stage was not named in the failure log: $(cat "$HOME_DIR/state/.home-summary-refresh.log")"
grep -E 'stages: lock-wait@[0-9]+ producer@[0-9]+ backlog@[0-9]+ .*summary@[0-9]+ validate@[0-9]+' \
  "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null \
  || fail "the stage list did not run lock-wait, producer, the producer's stages, then validate: $(cat "$HOME_DIR/state/.home-summary-refresh.log")"
PUBBIN="$TMP_ROOT/pub-hangbin"
REAL_MV=$(command -v mv)
mkdir -p "$PUBBIN"
cat > "$PUBBIN/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */home-summary.json) sleep 120 ;;
  esac
done
exec "$FM_TEST_REAL_MV" "$@"
SH
chmod +x "$PUBBIN/mv"
: > "$HOME_DIR/state/.home-summary-refresh.log"; rm -f "$HOME_DIR/state/.home-summary-refresh.backoff"
PATH="$PUBBIN:$FAKEBIN:$PATH" FM_TEST_REAL_MV="$REAL_MV" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_HOME_SUMMARY_TIMEOUT=60 \
  "$WRITER" --best-effort \
  || fail "a publish stage timeout changed the best-effort caller result"
grep -F 'refresh exceeded its 60-second deadline in stage publish' \
  "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null \
  || fail "the publish stage was not named in the failure log: $(cat "$HOME_DIR/state/.home-summary-refresh.log")"
pass "a deadline names the lock-wait, validate and publish stages"

# A failure the worker handles itself, with no deadline involved, must name its
# stage too: a malformed document in validate, a refused replacement in publish.
JQFAILBIN="$TMP_ROOT/jq-fail-bin"
mkdir -p "$JQFAILBIN"
cat > "$JQFAILBIN/jq" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */.home-summary.json.*) exit 1 ;;
  esac
done
exec "$FM_TEST_REAL_JQ" "$@"
SH
chmod +x "$JQFAILBIN/jq"
: > "$HOME_DIR/state/.home-summary-refresh.log"; rm -f "$HOME_DIR/state/.home-summary-refresh.backoff"
PATH="$JQFAILBIN:$FAKEBIN:$PATH" FM_TEST_REAL_JQ="$REAL_JQ" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  "$WRITER" --best-effort \
  || fail "a worker-handled validation failure changed the best-effort caller result"
grep -F 'summary producer returned a malformed ledger document in stage validate (stages: lock-wait@' \
  "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null \
  || fail "a worker-handled validation failure did not name its stage: $(cat "$HOME_DIR/state/.home-summary-refresh.log")"
MVFAILBIN="$TMP_ROOT/mv-fail-bin"
mkdir -p "$MVFAILBIN"
cat > "$MVFAILBIN/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */home-summary.json) exit 1 ;;
  esac
done
exec "$FM_TEST_REAL_MV" "$@"
SH
chmod +x "$MVFAILBIN/mv"
: > "$HOME_DIR/state/.home-summary-refresh.log"; rm -f "$HOME_DIR/state/.home-summary-refresh.backoff"
PATH="$MVFAILBIN:$FAKEBIN:$PATH" FM_TEST_REAL_MV="$REAL_MV" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  "$WRITER" --best-effort \
  || fail "a worker-handled publish failure changed the best-effort caller result"
grep -F 'atomic ledger replacement failed' "$HOME_DIR/state/.home-summary-refresh.log" \
  | grep -F ' in stage publish (stages: lock-wait@' >/dev/null \
  || fail "a worker-handled publish failure did not name its stage: $(cat "$HOME_DIR/state/.home-summary-refresh.log")"
# Without --best-effort the direct caller sees the same stage on stderr.
PATH="$MVFAILBIN:$FAKEBIN:$PATH" FM_TEST_REAL_MV="$REAL_MV" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  "$WRITER" 2> "$TMP_ROOT/direct-failure.err" \
  && fail "a refused replacement did not fail the direct caller"
grep -F ' in stage publish (stages: ' "$TMP_ROOT/direct-failure.err" >/dev/null \
  || fail "the direct caller did not see the failing stage: $(cat "$TMP_ROOT/direct-failure.err")"
pass "a failure the worker handles itself names its stage"

# The producer reads current state for every task through a sliding window, not
# in barriers. Five tasks run behind two slots: the first task's read cannot end
# until the other four have, so it only finishes if the window refills a slot the
# moment a fast task ends. A barrier, or serial reads, strand that read until the
# fake gives up, and the event order below fails. The assertion counts reads and
# their overlap, never elapsed time. Give the intentionally blocked read enough
# budget for all four peer reads, rather than the production per-read timeout.
# Endpoint observations must also finish before comparing windows. Short liveness
# deadlines can expire under host load and change otherwise identical task rows.
SLIDE_HOME="$TMP_ROOT/slide-home"
mkdir -p "$SLIDE_HOME/state" "$SLIDE_HOME/data" "$SLIDE_HOME/config" "$SLIDE_HOME/projects"
SLIDE_HOME=$(cd "$SLIDE_HOME" && pwd -P)
printf '# Seeded Firstmate home\n' > "$SLIDE_HOME/AGENTS.md"
printf 'mate\n' > "$SLIDE_HOME/.fm-secondmate-home"
{
  printf '## In flight\n'
  n=1
  while [ "$n" -le 5 ]; do
    printf -- '- [ ] slide-%s - Window task %s (repo: firstmate) (kind: ship) (since 2026-08-28)\n' "$n" "$n"
    fm_git_init_commit "$SLIDE_HOME/projects/slide-$n"
    git -C "$SLIDE_HOME/projects/slide-$n" checkout -q -b "fm/slide-$n"
    fm_write_meta "$SLIDE_HOME/state/slide-$n.meta" \
      "window=fmtest:fm-slide-$n" "worktree=$SLIDE_HOME/projects/slide-$n" \
      "project=firstmate" "harness=claude" "kind=ship" "mode=no-mistakes" \
      "spawn_gen=fm.slide$n"
    printf 'working: window fixture\n' > "$SLIDE_HOME/state/slide-$n.status"
    n=$((n + 1))
  done
  printf '\n## Queued\n\n## Done\n'
} > "$SLIDE_HOME/data/backlog.md"
SLIDEBIN="$TMP_ROOT/slide-bin"
mkdir -p "$SLIDEBIN"
cat > "$SLIDEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ -n "${FM_TEST_SLIDE_LOG:-}" ] && [ "$*" = "axi status" ] || exit 0
id=$(basename "$PWD")
case "$id" in slide-*) ;; *) exit 0 ;; esac
printf 'start %s\n' "$id" >> "$FM_TEST_SLIDE_LOG"
if [ "$id" = slide-1 ]; then
  n=0
  while [ "$(grep -c '^end ' "$FM_TEST_SLIDE_LOG")" -lt 4 ] && [ "$n" -lt 600 ]; do
    sleep 0.05
    n=$((n + 1))
  done
fi
printf 'end %s\n' "$id" >> "$FM_TEST_SLIDE_LOG"
exit 0
SH
chmod +x "$SLIDEBIN/no-mistakes"
run_slide() {  # <concurrency> [log]
  PATH="$SLIDEBIN:$FAKEBIN:$PATH" FM_TEST_SLIDE_LOG="${2:-}" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$SLIDE_HOME" \
    FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
    FM_SNAPSHOT_LOCAL_READ_CONCURRENCY="$1" \
    FM_SNAPSHOT_ENDPOINT_TIMEOUT=90 FM_CREW_STATE_PANE_TIMEOUT=90 \
    FM_SNAPSHOT_CREW_STATE_TIMEOUT=120 FM_CREW_STATE_NM_TIMEOUT=90 \
    "$SNAPSHOT" --secondmate-home-summary
}
SLIDE_LOG="$TMP_ROOT/slide-events.log"
: > "$SLIDE_LOG"
run_slide 2 "$SLIDE_LOG" > "$TMP_ROOT/slide-window.json" \
  || fail "the sliding-window producer run failed"
[ "$(grep -c '^start ' "$SLIDE_LOG")" -eq 5 ] \
  || fail "the window did not read all five tasks once: $(tr '\n' ' ' < "$SLIDE_LOG")"
[ "$(tail -n 1 "$SLIDE_LOG")" = "end slide-1" ] \
  || fail "a free slot was not refilled while the slow read ran (barrier or serial reads): $(tr '\n' ' ' < "$SLIDE_LOG")"
max_inflight=$(awk '/^start /{n++; if (n>m) m=n} /^end /{n--} END{print m+0}' "$SLIDE_LOG")
[ "$max_inflight" -eq 2 ] \
  || fail "the window ran $max_inflight reads at once instead of its limit of 2: $(tr '\n' ' ' < "$SLIDE_LOG")"
# The composed summary must not depend on how many reads overlapped.
run_slide 1 > "$TMP_ROOT/slide-serial.json" || fail "the serial producer run failed"
run_slide 16 > "$TMP_ROOT/slide-wide.json" || fail "the wide producer run failed"
jq -S . "$TMP_ROOT/slide-serial.json" > "$TMP_ROOT/slide-serial.norm"
jq -S . "$TMP_ROOT/slide-window.json" > "$TMP_ROOT/slide-window.norm"
jq -S . "$TMP_ROOT/slide-wide.json" > "$TMP_ROOT/slide-wide.norm"
cmp -s "$TMP_ROOT/slide-serial.norm" "$TMP_ROOT/slide-window.norm" \
  || fail "overlapping reads changed the summary: $(diff "$TMP_ROOT/slide-serial.norm" "$TMP_ROOT/slide-window.norm" | head -5)"
cmp -s "$TMP_ROOT/slide-serial.norm" "$TMP_ROOT/slide-wide.norm" \
  || fail "a wide window changed the summary"
jq -e '(.invalidity.ids | sort) == ["slide-1","slide-2","slide-3","slide-4","slide-5"] and .counts.endpoints == 5' \
  "$TMP_ROOT/slide-window.json" >/dev/null \
  || fail "the window summary lost a task row: $(jq -c '[.invalidity, .counts]' "$TMP_ROOT/slide-window.json")"
pass "current-state reads refill a free slot and never change the summary"

# Row composition goes through the same window. The fake jq stands in for the
# row builder's final compose step (the only jq call that carries both the task
# id and the observation time): slide-1's compose cannot end until the other four
# composes have, so a serial row builder strands it and the event order fails.
# Reads here are instant, so only row composition can overlap. The comparison is
# on complete task rows from --json, because the summary projection drops fields.
ROWBIN="$TMP_ROOT/row-bin"
mkdir -p "$ROWBIN"
cat > "$ROWBIN/jq" <<'SH'
#!/usr/bin/env bash
id=
saw_observed=0
prev=
for arg in "$@"; do
  [ "$prev" = id ] && [ -z "$id" ] && id=$arg
  [ "$arg" = observed_at ] && saw_observed=1
  prev=$arg
done
case "$id" in slide-*) ;; *) id= ;; esac
if [ -n "${FM_TEST_ROW_LOG:-}" ] && [ -n "$id" ] && [ "$saw_observed" -eq 1 ]; then
  printf 'start %s\n' "$id" >> "$FM_TEST_ROW_LOG"
  if [ "$id" = slide-1 ]; then
    n=0
    while [ "$(grep -c '^end ' "$FM_TEST_ROW_LOG")" -lt 4 ] && [ "$n" -lt 600 ]; do
      sleep 0.05
      n=$((n + 1))
    done
  fi
  "$FM_TEST_REAL_JQ" "$@"
  rc=$?
  printf 'end %s\n' "$id" >> "$FM_TEST_ROW_LOG"
  exit "$rc"
fi
exec "$FM_TEST_REAL_JQ" "$@"
SH
chmod +x "$ROWBIN/jq"
run_rows() {  # <concurrency> [log]
  PATH="$ROWBIN:$SLIDEBIN:$FAKEBIN:$PATH" FM_TEST_REAL_JQ="$REAL_JQ" FM_TEST_ROW_LOG="${2:-}" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$SLIDE_HOME" \
    FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
    FM_SNAPSHOT_LOCAL_READ_CONCURRENCY="$1" \
    FM_SNAPSHOT_ENDPOINT_TIMEOUT=90 FM_CREW_STATE_PANE_TIMEOUT=90 \
    FM_SNAPSHOT_CREW_STATE_TIMEOUT=120 FM_CREW_STATE_NM_TIMEOUT=90 \
    "$SNAPSHOT" --json
}
ROW_LOG="$TMP_ROOT/row-events.log"
: > "$ROW_LOG"
run_rows 2 "$ROW_LOG" > "$TMP_ROOT/rows-window.json" \
  || fail "the windowed row-composition run failed"
[ "$(grep -c '^start ' "$ROW_LOG")" -eq 5 ] \
  || fail "row composition did not run once per task: $(tr '\n' ' ' < "$ROW_LOG")"
[ "$(tail -n 1 "$ROW_LOG")" = "end slide-1" ] \
  || fail "row composition did not overlap behind the window (serial rows): $(tr '\n' ' ' < "$ROW_LOG")"
max_rows=$(awk '/^start /{n++; if (n>m) m=n} /^end /{n--} END{print m+0}' "$ROW_LOG")
[ "$max_rows" -eq 2 ] \
  || fail "row composition ran $max_rows at once instead of the window limit of 2: $(tr '\n' ' ' < "$ROW_LOG")"
run_rows 1 > "$TMP_ROOT/rows-serial.json" || fail "the serial row run failed"
run_rows 16 > "$TMP_ROOT/rows-wide.json" || fail "the wide row run failed"
jq -S '.tasks' "$TMP_ROOT/rows-serial.json" > "$TMP_ROOT/rows-serial.norm"
jq -S '.tasks' "$TMP_ROOT/rows-window.json" > "$TMP_ROOT/rows-window.norm"
jq -S '.tasks' "$TMP_ROOT/rows-wide.json" > "$TMP_ROOT/rows-wide.norm"
# The fake tmux inventory has no windows. A timed-out probe is not an equivalent
# observation, even if every run happened to time out in the same way.
for row_run in serial window wide; do
  jq -e '(.tasks | length) == 5 and all(.tasks[];
    .endpoint.exists == false and .endpoint.status == "absent")' \
    "$TMP_ROOT/rows-$row_run.json" >/dev/null \
    || fail "the $row_run run did not observe all five absent fixture endpoints"
done
cmp -s "$TMP_ROOT/rows-serial.norm" "$TMP_ROOT/rows-window.norm" \
  || fail "overlapping row composition changed a task row: $(diff "$TMP_ROOT/rows-serial.norm" "$TMP_ROOT/rows-window.norm" | head -5)"
cmp -s "$TMP_ROOT/rows-serial.norm" "$TMP_ROOT/rows-wide.norm" \
  || fail "a wide window changed a task row: $(diff -u "$TMP_ROOT/rows-serial.norm" "$TMP_ROOT/rows-wide.norm" | head -40)"
pass "row composition overlaps behind the window and keeps every task row identical"

# Task ids may contain dots, so a task named like another task's row file ("ship"
# and "ship.row") must not share files with it: both rows survive the snapshot.
DOT_HOME="$TMP_ROOT/dot-home"
mkdir -p "$DOT_HOME/state" "$DOT_HOME/data" "$DOT_HOME/config" "$DOT_HOME/projects"
DOT_HOME=$(cd "$DOT_HOME" && pwd -P)
printf '# Seeded Firstmate home\n' > "$DOT_HOME/AGENTS.md"
printf 'mate\n' > "$DOT_HOME/.fm-secondmate-home"
{
  printf '## In flight\n'
  for dot_id in ship ship.row; do
    printf -- '- [ ] %s - Dotted task %s (repo: firstmate) (kind: ship) (since 2026-08-28)\n' "$dot_id" "$dot_id"
    fm_git_init_commit "$DOT_HOME/projects/$dot_id"
    git -C "$DOT_HOME/projects/$dot_id" checkout -q -b "fm/$dot_id"
    fm_write_meta "$DOT_HOME/state/$dot_id.meta" \
      "window=fmtest:fm-$dot_id" "worktree=$DOT_HOME/projects/$dot_id" \
      "project=firstmate" "harness=claude" "kind=ship" "mode=no-mistakes" \
      "spawn_gen=fm.dot$dot_id"
    printf 'working: dotted fixture\n' > "$DOT_HOME/state/$dot_id.status"
  done
  printf '\n## Queued\n\n## Done\n'
} > "$DOT_HOME/data/backlog.md"
for dot_conc in 1 16; do
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$DOT_HOME" \
    FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
    FM_SNAPSHOT_LOCAL_READ_CONCURRENCY="$dot_conc" \
    "$SNAPSHOT" --json > "$TMP_ROOT/dot-snapshot-$dot_conc.json" 2> "$TMP_ROOT/dot-snapshot-$dot_conc.err" \
    || fail "a snapshot of tasks named ship and ship.row failed at concurrency $dot_conc: $(cat "$TMP_ROOT/dot-snapshot-$dot_conc.err")"
  jq -e '([.tasks[].id] | sort) == ["ship","ship.row"]' "$TMP_ROOT/dot-snapshot-$dot_conc.json" >/dev/null \
    || fail "a dotted task id lost or swapped its row at concurrency $dot_conc: $(jq -c '[.tasks[].id]' "$TMP_ROOT/dot-snapshot-$dot_conc.json")"
done
pass "task ids that extend another task's row file name keep separate rows"

MKBIN="$TMP_ROOT/mkdir-hangbin"
REAL_MKDIR=$(command -v mkdir)
mkdir -p "$MKBIN"
cat > "$MKBIN/mkdir" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "$FM_TEST_STALLED_STATE" ]; then
    sleep 30
  fi
done
exec "$FM_TEST_REAL_MKDIR" "$@"
SH
chmod +x "$MKBIN/mkdir"
rm -f "$HOME_DIR/state/.home-summary-refresh.backoff"
started=$(date +%s)
PATH="$MKBIN:$FAKEBIN:$PATH" FM_TEST_REAL_MKDIR="$REAL_MKDIR" \
  FM_TEST_STALLED_STATE="$HOME_DIR/state" FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$HOME_DIR" FM_HOME_SUMMARY_TIMEOUT=1 \
  "$WRITER" --best-effort >/dev/null 2>"$TMP_ROOT/stalled-state.err" \
  || fail "state initialization timeout changed the best-effort caller result"
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 6 ] \
  || fail "best-effort refresh waited $elapsed seconds before bounded state initialization"
pass "best-effort refresh bounds state initialization"

SIGNALBIN="$TMP_ROOT/signalbin"
SIGNAL_MARKER="$TMP_ROOT/worker-signaled"
REAL_ENV=$(command -v env)
mkdir -p "$SIGNALBIN"
cat > "$SIGNALBIN/env" <<'SH'
#!/usr/bin/env bash
if [ ! -e "$FM_TEST_SIGNAL_MARKER" ]; then
  : > "$FM_TEST_SIGNAL_MARKER"
  exit 143
fi
exec "$FM_TEST_REAL_ENV" "$@"
SH
chmod +x "$SIGNALBIN/env"
rm -f "$HOME_DIR/state/.home-summary-refresh.log" \
  "$HOME_DIR/state/.home-summary-refresh.backoff"
PATH="$SIGNALBIN:$FAKEBIN:$PATH" FM_TEST_REAL_ENV="$REAL_ENV" \
  FM_TEST_SIGNAL_MARKER="$SIGNAL_MARKER" FM_TIMEOUT_MECHANISM_OVERRIDE=bash \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" "$WRITER" --best-effort \
  || fail "worker termination changed the best-effort caller result"
grep -F 'refresh worker failed with exit 143' \
  "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null \
  || fail "worker termination was not logged at the parent boundary"
pass "best-effort refresh logs worker termination"

rm -f "$SIGNAL_MARKER" "$HOME_DIR/state/.home-summary-refresh.log" \
  "$HOME_DIR/state/.home-summary-refresh.backoff"
mkdir "$HOME_DIR/state/.home-summary-refresh.log"
if ! PATH="$SIGNALBIN:$FAKEBIN:$PATH" FM_TEST_REAL_ENV="$REAL_ENV" \
  FM_TEST_SIGNAL_MARKER="$SIGNAL_MARKER" FM_TIMEOUT_MECHANISM_OVERRIDE=bash \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" WRITER="$WRITER" python3 - <<'PY'
import os
import subprocess
import time

read_fd, write_fd = os.pipe()
os.set_blocking(write_fd, False)
try:
    while True:
        os.write(write_fd, b"x" * 4096)
except BlockingIOError:
    pass
os.set_blocking(write_fd, True)
started = time.monotonic()
try:
    result = subprocess.run(
        [os.environ["WRITER"], "--best-effort"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=write_fd,
        env=os.environ,
        timeout=7,
    )
finally:
    os.close(write_fd)
    os.close(read_fd)
elapsed = time.monotonic() - started
if result.returncode != 0:
    raise SystemExit(f"blocked failure logger changed caller result: {result.returncode}")
if elapsed >= 6:
    raise SystemExit(f"blocked failure logger exceeded its bound: {elapsed:.2f}s")
PY
then
  fail "best-effort failure reporting was not fully bounded"
fi
pass "best-effort refresh bounds failure reporting fallback"

PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$WRITER" || fail "an unavailable failure record blocked valid publication"
jq -e --arg now "$NOW_ONE" '.generated == $now' \
  "$HOME_DIR/state/home-summary.json" >/dev/null \
  || fail "valid publication did not replace the ledger with an unavailable failure record"
rmdir "$HOME_DIR/state/.home-summary-refresh.log"
pass "valid publication ignores an unavailable failure record"

# --- publication cost, beacon isolation, and failure discoverability ---------
#
# The three regressions below all came from one live incident: in a real home
# whose tasks had accumulated ordinary status history, the producer needed
# minutes, so publication burned its whole deadline on every attempt, never
# published, starved the watcher's liveness beacon while it did, and said
# nothing about any of it because --best-effort is deliberately non-fatal.

# Publication cost must scale with what a home actually accumulates. Status
# history is append-only and unbounded, and the producer folds every task's
# whole stream, so an ordinary long-lived home is the real input - not the
# one-line log a freshly seeded fixture has. This home carries a status log of
# realistic width and depth and must still publish inside a deadline well under
# the default one.
COST_HOME="$TMP_ROOT/cost-home"
mkdir -p "$COST_HOME/state" "$COST_HOME/data" "$COST_HOME/config" \
  "$COST_HOME/projects/task"
printf '# Seeded Firstmate home\n' > "$COST_HOME/AGENTS.md"
printf 'cost\n' > "$COST_HOME/.fm-secondmate-home"
fm_git_init_commit "$COST_HOME/projects/task"
cat > "$COST_HOME/data/backlog.md" <<'EOF'
## In flight
- [ ] cost-task - Publish from an accumulated home (repo: firstmate) (kind: ship) (since 2026-08-28)

## Queued

## Done
EOF
fm_write_meta "$COST_HOME/state/cost-task.meta" \
  "window=fmtest:fm-cost-task" \
  "worktree=$COST_HOME/projects/task" \
  "project=firstmate" \
  "harness=claude" \
  "kind=ship" \
  "mode=no-mistakes" \
  "spawn_gen=fm.cost123456"
cost_busy_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$COST_HOME/state" cost-task)
"$ROOT/bin/fm-busy-event.sh" apply "$COST_HOME/state" cost-task idle \
  --gen "$cost_busy_gen" --source claude-hook --event stop
python3 - "$COST_HOME/state/cost-task.status" <<'PY'
import sys
note = ("the crewmate ran validation and reported checks on the branch "
        "after review ") * 25
with open(sys.argv[1], "w") as handle:
    for i in range(300):
        handle.write(f"working: {note}({i})\n")
    handle.write("needs-decision [key=cost-gate]: which base to rebuild from\n")
PY
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$COST_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  FM_HOME_SUMMARY_TIMEOUT=30 "$WRITER" --best-effort \
  || fail "accumulated-home publication changed the best-effort caller result"
[ -f "$COST_HOME/state/home-summary.json" ] \
  || fail "an accumulated home did not publish within a 30-second deadline: $(cat "$COST_HOME/state/.home-summary-refresh.log" 2>/dev/null)"
jq -e --arg home "$COST_HOME" '
  .schema == "fm-secondmate-home-summary.v1"
  and .home == $home
  and any(.decisions_open[]; .key == "cost-gate")
' "$COST_HOME/state/home-summary.json" >/dev/null \
  || fail "the accumulated home published a ledger missing its open decision"
pass "publication completes on a home carrying accumulated status history"

# One unreachable home must not extend publication without limit. A remote
# secondmate's current state is read over ssh, and ssh's own dead-peer detection
# deliberately never kills a slow-but-alive remote command, so nothing under the
# producer bounds that read on its own. Point the transport at a stub that never
# answers and require the producer to return anyway, reporting that home as
# unknown rather than waiting on it.
REMOTE_HOME="$TMP_ROOT/remote-home"
mkdir -p "$REMOTE_HOME/state" "$REMOTE_HOME/data" "$REMOTE_HOME/config" \
  "$REMOTE_HOME/projects" "$TMP_ROOT/sshbin"
printf '# Seeded Firstmate home\n' > "$REMOTE_HOME/AGENTS.md"
printf 'remote\n' > "$REMOTE_HOME/.fm-secondmate-home"
cat > "$REMOTE_HOME/data/backlog.md" <<'EOF'
## In flight
- [ ] rsm - Read remote current state (repo: firstmate) (kind: ship) (since 2026-08-28)

## Queued

## Done
EOF
cat > "$REMOTE_HOME/data/secondmates.md" <<'EOF'
- rsm - remote test domain (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-08-02)
EOF
fm_write_meta "$REMOTE_HOME/state/rsm.meta" \
  "window=remote:rsm" \
  "endpoint_task_id=rsm" \
  "worktree=/remote/home/never-locally-present" \
  "harness=claude" \
  "kind=secondmate" \
  "mode=secondmate" \
  "home=/remote/home" \
  "remote_host=remote-mac" \
  "remote_root=/remote/root" \
  "remote_backend=herdr" \
  "remote_herdr_session=fm-remote" \
  "remote_target=fm-remote:w1:p1"
cat > "$TMP_ROOT/sshbin/stalled-ssh" <<'SH'
#!/usr/bin/env bash
: > "$FM_TEST_SSH_CALLED"
cat > /dev/null
sleep 60
SH
chmod +x "$TMP_ROOT/sshbin/stalled-ssh"
started=$(date +%s)
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$REMOTE_HOME" \
  FM_SSH_BIN="$TMP_ROOT/sshbin/stalled-ssh" FM_TEST_SSH_CALLED="$TMP_ROOT/stalled-ssh.called" \
  FM_SNAPSHOT_NOW="$NOW_TWO" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_TWO" \
  FM_SNAPSHOT_CREW_STATE_TIMEOUT=2 \
  "$SNAPSHOT" --secondmate-home-summary > "$TMP_ROOT/stalled-summary.json" \
  || fail "an unreachable remote home failed the whole producer"
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 40 ] \
  || fail "the producer waited $elapsed seconds despite skipping remote endpoint state"
[ ! -e "$TMP_ROOT/stalled-ssh.called" ] \
  || fail "the producer issued a remote per-task state probe"
jq -e '
  .schema == "fm-secondmate-home-summary.v1"
  and .valid == false
  and .state == "unknown"
  and .invalidity.kind == "child_current_unavailable"
  and (.invalidity.ids == ["rsm"])
  and any(.endpoints[]; .id == "rsm" and .state == "unknown")
' "$TMP_ROOT/stalled-summary.json" >/dev/null \
  || fail "an unreachable remote task was not reported as unknown"
pass "producer skips remote per-task state probes"

# The watcher's beacon is what the rest of supervision reads as proof it is
# alive. Publication is side-band, so no matter how long it takes, the beacon
# must keep advancing. Hold the publication lock for the whole observation
# window, then require the beacon to keep ticking anyway.
BEAT_HOME="$TMP_ROOT/beat-home"
mkdir -p "$BEAT_HOME/state" "$BEAT_HOME/data" "$BEAT_HOME/config" \
  "$BEAT_HOME/projects"
printf '# Seeded Firstmate home\n' > "$BEAT_HOME/AGENTS.md"
printf 'beat\n' > "$BEAT_HOME/.fm-secondmate-home"
cat > "$BEAT_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
BEAT_LOCK_MARKER="$TMP_ROOT/beat-lock-held"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BEAT_HOME" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"
  : > "$3"
  sleep 120
' _ "$ROOT" "$BEAT_HOME" "$BEAT_LOCK_MARKER" &
LOCK_HOLDER_PID=$!
i=0
while [ ! -e "$BEAT_LOCK_MARKER" ] && [ "$i" -lt 100 ]; do
  kill -0 "$LOCK_HOLDER_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$BEAT_LOCK_MARKER" ] || fail "could not stall publication for beacon coverage"
PATH="$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BEAT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=1 FM_HOME_SUMMARY_TIMEOUT=90 \
  FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  "$WATCH" > "$TMP_ROOT/beat-watch.out" 2> "$TMP_ROOT/beat-watch.err" &
WATCH_PID=$!
i=0
while [ ! -e "$BEAT_HOME/state/.last-watcher-beat" ] && [ "$i" -lt 200 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$BEAT_HOME/state/.last-watcher-beat" ] \
  || fail "the stalled-publication watcher never beat: $(cat "$TMP_ROOT/beat-watch.err" 2>/dev/null)"
beat_mtime() { python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime)' "$1"; }
seen=0
last=$(beat_mtime "$BEAT_HOME/state/.last-watcher-beat")
i=0
while [ "$seen" -lt 3 ] && [ "$i" -lt 200 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null \
    || fail "the stalled-publication watcher exited: $(cat "$TMP_ROOT/beat-watch.err" 2>/dev/null)"
  sleep 0.1
  now=$(beat_mtime "$BEAT_HOME/state/.last-watcher-beat")
  if [ "$now" != "$last" ]; then
    seen=$((seen + 1))
    last=$now
  fi
  i=$((i + 1))
done
[ "$seen" -ge 3 ] \
  || fail "the beacon advanced only $seen time(s) in 20 seconds while publication was stalled"
kill "$WATCH_PID" >/dev/null 2>&1 || true
wait "$WATCH_PID" >/dev/null 2>&1 || true
WATCH_PID=
kill "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
wait "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
LOCK_HOLDER_PID=
pass "a stalled publication does not delay the watcher liveness beacon"

RESTART_HOME="$TMP_ROOT/restart-home"
mkdir -p "$RESTART_HOME/state" "$RESTART_HOME/data" "$RESTART_HOME/config" \
  "$RESTART_HOME/projects/task"
printf '# Seeded Firstmate home\n' > "$RESTART_HOME/AGENTS.md"
printf 'restart\n' > "$RESTART_HOME/.fm-secondmate-home"
fm_git_init_commit "$RESTART_HOME/projects/task"
cat > "$RESTART_HOME/data/backlog.md" <<'EOF'
## In flight
- [ ] restart-task - Preserve publication single flight (repo: firstmate) (kind: ship) (since 2026-08-28)

## Queued

## Done
EOF
fm_write_meta "$RESTART_HOME/state/restart-task.meta" \
  "window=fmtest:fm-restart-task" \
  "worktree=$RESTART_HOME/projects/task" \
  "project=firstmate" \
  "harness=claude" \
  "kind=ship" \
  "mode=no-mistakes" \
  "spawn_gen=fm.restart123456"
RESTART_LOCK_MARKER="$TMP_ROOT/restart-lock-held"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$RESTART_HOME" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"
  : > "$3"
  sleep 30
' _ "$ROOT" "$RESTART_HOME" "$RESTART_LOCK_MARKER" &
LOCK_HOLDER_PID=$!
i=0
while [ ! -e "$RESTART_LOCK_MARKER" ] && [ "$i" -lt 100 ]; do
  kill -0 "$LOCK_HOLDER_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$RESTART_LOCK_MARKER" ] || fail "could not hold the publication lock for restart coverage"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$RESTART_HOME" \
  FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=999999 FM_HOME_SUMMARY_TIMEOUT=2 \
  FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  "$WATCH" > "$TMP_ROOT/restart-watch-one.out" 2> "$TMP_ROOT/restart-watch-one.err" &
WATCH_PID=$!
i=0
while [ ! -e "$RESTART_HOME/state/.last-watcher-beat" ] && [ "$i" -lt 100 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$RESTART_HOME/state/.last-watcher-beat" ] \
  || fail "the first restart watcher did not begin polling"
printf 'needs-decision [key=restart-gate]: restart the watcher\n' \
  > "$RESTART_HOME/state/restart-task.status"
i=0
while kill -0 "$WATCH_PID" 2>/dev/null && [ "$i" -lt 100 ]; do
  sleep 0.05
  i=$((i + 1))
done
kill -0 "$WATCH_PID" 2>/dev/null \
  && fail "the first restart watcher did not surface its actionable signal"
wait "$WATCH_PID" >/dev/null 2>&1 || true
WATCH_PID=
rm -f "$RESTART_HOME/state/.last-watcher-beat"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$RESTART_HOME" \
  FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=999999 FM_HOME_SUMMARY_TIMEOUT=2 \
  FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  "$WATCH" > "$TMP_ROOT/restart-watch-two.out" 2> "$TMP_ROOT/restart-watch-two.err" &
WATCH_PID=$!
i=0
while [ ! -e "$RESTART_HOME/state/.last-watcher-beat" ] && [ "$i" -lt 100 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$RESTART_HOME/state/.last-watcher-beat" ] \
  || fail "the replacement restart watcher did not begin polling"
sleep 4
[ ! -s "$RESTART_HOME/state/.home-summary-refresh.log" ] \
  || fail "watcher restart queued refreshes behind a live publication lock: $(cat "$RESTART_HOME/state/.home-summary-refresh.log")"
if ! kill -0 "$WATCH_PID" 2>/dev/null; then
  wait "$WATCH_PID" >/dev/null 2>&1 || true
  rm -f "$RESTART_HOME/state/.last-watcher-beat"
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$RESTART_HOME" \
    FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=999999 FM_HOME_SUMMARY_TIMEOUT=2 \
    FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
    "$WATCH" > "$TMP_ROOT/restart-watch-three.out" 2> "$TMP_ROOT/restart-watch-three.err" &
  WATCH_PID=$!
  i=0
  while [ ! -e "$RESTART_HOME/state/.last-watcher-beat" ] && [ "$i" -lt 100 ]; do
    kill -0 "$WATCH_PID" 2>/dev/null || break
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$RESTART_HOME/state/.last-watcher-beat" ] \
    || fail "the recovery replacement watcher did not begin polling"
fi
kill -KILL "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
wait "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
LOCK_HOLDER_PID=
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$RESTART_HOME" \
  FM_HOME_SUMMARY_IF_IDLE=1 "$WRITER" --best-effort \
  || fail "stale-lock recovery changed the best-effort caller result"
i=0
while [ ! -e "$RESTART_HOME/state/home-summary.json" ] && [ "$i" -lt 200 ]; do
  sleep 0.05
  i=$((i + 1))
done
[ -e "$RESTART_HOME/state/home-summary.json" ] \
  || fail "a dead publication lock wedged publication"
kill "$WATCH_PID" >/dev/null 2>&1 || true
wait "$WATCH_PID" >/dev/null 2>&1 || true
WATCH_PID=
pass "publication remains single-flight across watcher restart"

# A publication that keeps failing is deliberately non-fatal to its caller, so
# the only way an operator learns about it is a session start saying so. Seed
# the home-local failure record a real failing home would have, and require the
# check a session start already runs to name it - then go quiet once the ledger
# is published again.
REPORT_HOME="$TMP_ROOT/report-home"
mkdir -p "$REPORT_HOME/state" "$REPORT_HOME/data" "$REPORT_HOME/config" \
  "$REPORT_HOME/projects"
printf '# Seeded Firstmate home\n' > "$REPORT_HOME/AGENTS.md"
printf 'report\n' > "$REPORT_HOME/.fm-secondmate-home"
cat > "$REPORT_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
cat > "$REPORT_HOME/state/.home-summary-refresh.log" <<'EOF'
[2026-08-28T09:58:00Z] refresh exceeded its 60-second deadline
[2026-08-28T09:59:00Z] refresh exceeded its 60-second deadline
EOF
run_bootstrap_detect() {
  local threshold=${2:-2}
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$1" \
    FM_HOME_SUMMARY_FAILURE_REPORT="$threshold" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

COMPAT_HOME="$TMP_ROOT/compat-home"
mkdir -p "$COMPAT_HOME/state" "$COMPAT_HOME/data" "$COMPAT_HOME/config" \
  "$COMPAT_HOME/projects"
printf '# Seeded Firstmate home\n' > "$COMPAT_HOME/AGENTS.md"
printf 'compat\n' > "$COMPAT_HOME/.fm-secondmate-home"
cat > "$COMPAT_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$COMPAT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$WRITER" || fail "could not seed the compatibility ledger"
cat > "$COMPAT_HOME/state/.home-summary-refresh.log" <<'EOF'
[2026-08-28T09:58:00Z] historical failure before publication
[2026-08-28T09:59:00Z] historical failure before publication
[2026-08-28T10:01:00Z] first failure after publication
EOF
compat_out=$(run_bootstrap_detect "$COMPAT_HOME")
case "$compat_out" in
  *HOME_SUMMARY:*)
    fail "historical failures satisfied the current publication threshold: $compat_out"
    ;;
esac
printf '[2026-08-28T10:02:00Z] second failure after publication\n' \
  >> "$COMPAT_HOME/state/.home-summary-refresh.log"
compat_out=$(run_bootstrap_detect "$COMPAT_HOME")
printf '%s\n' "$compat_out" | grep -F '2 failed attempt(s)' >/dev/null \
  || fail "current publication failures did not satisfy the report threshold: $compat_out"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$COMPAT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  "$WRITER" || fail "could not republish the compatibility ledger"
compat_out=$(run_bootstrap_detect "$COMPAT_HOME")
case "$compat_out" in
  *HOME_SUMMARY:*)
    fail "republishing did not scope retained failure history: $compat_out"
    ;;
esac
pass "bootstrap scopes retained failures to the current publication"

# A timed-out attempt can finish recording after a newer ledger is published.
# Its record must retain the attempt's ordering rather than look like a failure
# of the newer publication and keep the session-start diagnostic active.
ORDER_HOME="$TMP_ROOT/order-home"
ORDER_DATE_BIN="$TMP_ROOT/order-date-bin"
mkdir -p "$ORDER_HOME/state" "$ORDER_HOME/data" "$ORDER_HOME/config" \
  "$ORDER_HOME/projects" "$ORDER_DATE_BIN"
printf '# Seeded Firstmate home\n' > "$ORDER_HOME/AGENTS.md"
printf 'order\n' > "$ORDER_HOME/.fm-secondmate-home"
cat > "$ORDER_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
REAL_DATE=$(command -v date)
cat > "$ORDER_DATE_BIN/date" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 2 ] && [ "$1" = -u ] && [ "$2" = +%Y-%m-%dT%H:%M:%SZ ]; then
  python3 - "$FM_TEST_ORDER_START" "$FM_TEST_ORDER_EARLY" "$FM_TEST_ORDER_LATE" <<'PY'
import sys
import time

started = float(sys.argv[1])
print(sys.argv[2] if time.time() - started < 1 else sys.argv[3])
PY
  exit 0
fi
exec "$FM_TEST_REAL_DATE" "$@"
SH
chmod +x "$ORDER_DATE_BIN/date"
ORDER_LOCK_MARKER="$TMP_ROOT/order-lock-held"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$ORDER_HOME" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"
  : > "$3"
  sleep 30
' _ "$ROOT" "$ORDER_HOME" "$ORDER_LOCK_MARKER" &
LOCK_HOLDER_PID=$!
i=0
while [ ! -e "$ORDER_LOCK_MARKER" ] && [ "$i" -lt 100 ]; do
  kill -0 "$LOCK_HOLDER_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$ORDER_LOCK_MARKER" ] || fail "could not hold the publication lock for ordering coverage"
order_started=$(python3 -c 'import time; print(time.time())')
PATH="$ORDER_DATE_BIN:$FAKEBIN:$PATH" FM_TEST_REAL_DATE="$REAL_DATE" \
  FM_TEST_ORDER_START="$order_started" FM_TEST_ORDER_EARLY="$NOW_ONE" \
  FM_TEST_ORDER_LATE="$NOW_THREE" FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$ORDER_HOME" FM_HOME_SUMMARY_TIMEOUT=2 \
  "$WRITER" --best-effort \
  || fail "ordered timeout changed the best-effort caller result"
kill "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
wait "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
LOCK_HOLDER_PID=
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$ORDER_HOME" \
  FM_SNAPSHOT_NOW="$NOW_TWO" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_TWO" \
  "$WRITER" || fail "could not publish after the ordered timeout"
order_out=$(run_bootstrap_detect "$ORDER_HOME" 1)
case "$order_out" in
  *HOME_SUMMARY:*)
    fail "a pre-publication attempt was reported after the newer ledger: $order_out"
    ;;
esac
pass "failure records preserve refresh attempt ordering"

report_out=$(run_bootstrap_detect "$REPORT_HOME")
printf '%s\n' "$report_out" \
  | grep -F 'HOME_SUMMARY: this home has never published state/home-summary.json' \
    >/dev/null \
  || fail "a home that never published its ledger was reported as silent: $report_out"
printf '%s\n' "$report_out" \
  | grep -F '2 failed attempt(s)' >/dev/null \
  || fail "the publication report omitted the recorded failure count: $report_out"
printf '%s\n' "$report_out" \
  | grep -F 'refresh exceeded its 60-second deadline' >/dev/null \
  || fail "the publication report omitted the recorded reason: $report_out"

PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$REPORT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  "$WRITER" || fail "could not publish the ledger that clears the report"
report_out=$(run_bootstrap_detect "$REPORT_HOME")
case "$report_out" in
  *HOME_SUMMARY:*)
    fail "a published ledger still reported stale publication failures: $report_out"
    ;;
esac
pass "repeated publication failure is reported at session start until it clears"

fi

# A failed refresh must wait longer before the next side-band attempt instead
# of costing a full producer run on every watcher poll. The delay doubles
# after each failure and is capped; a success resets it.
BACKOFF_HOME="$TMP_ROOT/backoff-home"
mkdir -p "$BACKOFF_HOME/state" "$BACKOFF_HOME/data" "$BACKOFF_HOME/config" \
  "$BACKOFF_HOME/projects"
printf '# Seeded Firstmate home\n' > "$BACKOFF_HOME/AGENTS.md"
printf 'backoff\n' > "$BACKOFF_HOME/.fm-secondmate-home"
cat > "$BACKOFF_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
FAILBIN="$TMP_ROOT/backoff-failbin"
mkdir -p "$FAILBIN"
cat > "$FAILBIN/jq" <<'SH'
#!/usr/bin/env bash
exit 7
SH
chmod +x "$FAILBIN/jq"
backoff_failures() {
  grep -c 'summary producer failed' "$BACKOFF_HOME/state/.home-summary-refresh.log" 2>/dev/null || true
}
backoff_attempt() {  # <now-epoch>
  PATH="$FAILBIN:$FAKEBIN:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BACKOFF_HOME" \
    FM_TEST_SEAM=1 FM_NOW="$1" \
    "$WRITER" --best-effort \
    || fail "backed-off refresh changed the best-effort caller result"
}
backoff_epoch=1000
backoff_count=0
for backoff_delay in 30 60 120 240 480 960 1800 1800; do
  backoff_attempt "$backoff_epoch"
  backoff_count=$((backoff_count + 1))
  [ "$(backoff_failures)" -eq "$backoff_count" ] || fail "an eligible refresh did not retry"
  backoff_epoch=$((backoff_epoch + backoff_delay))
  backoff_attempt "$((backoff_epoch - 1))"
  [ "$(backoff_failures)" -eq "$backoff_count" ] || fail "a refresh retried before its fixed backoff elapsed"
done
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BACKOFF_HOME" \
  FM_TEST_SEAM=1 FM_NOW=1000 \
  "$WRITER" || fail "a direct refresh did not run and clear the backoff"
[ ! -e "$BACKOFF_HOME/state/.home-summary-refresh.backoff" ] || fail "publication did not clear backoff"
backoff_attempt 1001
[ "$(backoff_failures)" -eq 9 ] || fail "a successful refresh did not reset the backoff"
pass "failed refresh backs off from 30 to 1800 seconds and resets on publication"

. "$ROOT/bin/fm-timeout-lib.sh"
QUEUEDBIN="$TMP_ROOT/queued-bin"
mkdir -p "$QUEUEDBIN"
cat > "$QUEUEDBIN/jq" <<'SH'
#!/usr/bin/env bash
printf 'attempt\n' >> "$FM_TEST_ATTEMPTS"
if [ ! -e "$FM_TEST_READY" ]; then
  : > "$FM_TEST_READY"
  read -r _ < "$FM_TEST_RELEASE"
fi
exit 7
SH
chmod +x "$QUEUEDBIN/jq"
rm -f "$BACKOFF_HOME/state/.home-summary-refresh.backoff"
RELEASE="$TMP_ROOT/queued-release"
READY="$TMP_ROOT/queued-ready"
ATTEMPTS="$TMP_ROOT/queued-attempts"
QUEUED_STAGE="$BACKOFF_HOME/state/.home-summary-stage.queued"
mkfifo "$RELEASE"
PATH="$QUEUEDBIN:$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BACKOFF_HOME" \
  FM_TEST_ATTEMPTS="$ATTEMPTS" FM_TEST_READY="$READY" FM_TEST_RELEASE="$RELEASE" \
  FM_TEST_SEAM=1 FM_NOW=1000 "$WRITER" --best-effort &
SLOW_WRITER_PID=$!
i=0
while [ ! -e "$READY" ] && [ "$i" -lt 600 ]; do sleep 0.05; i=$((i + 1)); done
[ -e "$READY" ] || fail "the first producer did not start"
printf 'failures=2\nnext=900\n' > "$BACKOFF_HOME/state/.home-summary-refresh.backoff"
PATH="$QUEUEDBIN:$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BACKOFF_HOME" \
  FM_TEST_SEAM=1 FM_NOW=1000 FM_HOME_SUMMARY_IF_IDLE=1 "$WRITER" --best-effort \
  || fail "an if-idle refresh did not skip a busy publication lock"
[ "$(cat "$BACKOFF_HOME/state/.home-summary-refresh.backoff")" = "$(printf 'failures=2\nnext=900')" ] \
  || fail "an if-idle skip changed the existing backoff record"
rm -f "$BACKOFF_HOME/state/.home-summary-refresh.backoff"
PATH="$QUEUEDBIN:$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BACKOFF_HOME" \
  FM_TEST_ATTEMPTS="$ATTEMPTS" FM_TEST_READY="$READY" FM_TEST_RELEASE="$RELEASE" \
  FM_HOME_SUMMARY_STAGE_PATH="$QUEUED_STAGE" \
  FM_TEST_SEAM=1 FM_NOW=1000 "$WRITER" --best-effort &
SLOW_NM_PID=$!
i=0
until grep -q '^lock-wait' "$QUEUED_STAGE" 2>/dev/null; do
  [ "$i" -lt 600 ] || fail "the second refresh never queued for the publication lock"
  sleep 0.05
  i=$((i + 1))
done
printf 'release\n' > "$RELEASE"
wait "$SLOW_WRITER_PID" || fail "the first best-effort refresh failed"
SLOW_WRITER_PID=
wait "$SLOW_NM_PID" || fail "the queued best-effort refresh failed"
SLOW_NM_PID=
[ "$(wc -l < "$ATTEMPTS" | tr -d ' ')" -eq 1 ] || fail "a queued refresh bypassed the preceding failure's backoff"
PATH="$QUEUEDBIN:$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BACKOFF_HOME" \
  FM_TEST_ATTEMPTS="$ATTEMPTS" FM_TEST_READY="$READY" FM_TEST_RELEASE="$RELEASE" \
  FM_TEST_SEAM=1 FM_NOW=1030 "$WRITER" --best-effort \
  || fail "an eligible refresh failed after contention"
[ "$(wc -l < "$ATTEMPTS" | tr -d ' ')" -eq 2 ] || fail "the queued skip changed the retry time"
pass "a queued refresh checks backoff after taking the lock"

TIMEOUTBIN="$TMP_ROOT/timeout-backoff-bin"
TIMEOUT_FAILBIN="$TMP_ROOT/timeout-backoff-failbin"
mkdir -p "$TIMEOUTBIN" "$TIMEOUT_FAILBIN"
cat > "$TIMEOUTBIN/jq" <<'SH'
#!/usr/bin/env bash
: > "$FM_TEST_TIMEOUT_READY"
sleep 60
exit 7
SH
cat > "$TIMEOUTBIN/tail" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */.home-summary-stage.timeout-race)
      # Worker failure reporting reads this path too. Pause only the parent's
      # diagnostics; stopping it twice would strand the test after its resume.
      if [ -z "${FM_HOME_SUMMARY_STAGE_FILE:-}" ]; then
        kill -STOP "$(cat "$FM_TEST_TIMEOUT_PARENT_FILE")"
        : > "$FM_TEST_TIMEOUT_PARENT_STOPPED"
      fi
      ;;
  esac
done
exec "$FM_TEST_REAL_TAIL" "$@"
SH
cat > "$TIMEOUT_FAILBIN/jq" <<'SH'
#!/usr/bin/env bash
: > "$FM_TEST_QUEUED_PRODUCER"
exit 7
SH
chmod +x "$TIMEOUTBIN/jq" "$TIMEOUTBIN/tail" "$TIMEOUT_FAILBIN/jq"
rm -f "$BACKOFF_HOME/state/.home-summary-refresh.backoff"
TIMEOUT_PARENT_FILE="$TMP_ROOT/timeout-parent.pid"
TIMEOUT_PARENT_STOPPED="$TMP_ROOT/timeout-parent-stopped"
TIMEOUT_READY="$TMP_ROOT/timeout-ready"
QUEUED_PRODUCER="$TMP_ROOT/timeout-queued-producer"
TIMEOUT_QUEUED_STAGE="$BACKOFF_HOME/state/.home-summary-stage.timeout-queued"
PATH="$TIMEOUTBIN:$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BACKOFF_HOME" \
  FM_TEST_TIMEOUT_READY="$TIMEOUT_READY" FM_TEST_TIMEOUT_PARENT_FILE="$TIMEOUT_PARENT_FILE" \
  FM_TEST_TIMEOUT_PARENT_STOPPED="$TIMEOUT_PARENT_STOPPED" FM_TEST_REAL_TAIL="$REAL_TAIL" \
  FM_HOME_SUMMARY_STAGE_PATH="$BACKOFF_HOME/state/.home-summary-stage.timeout-race" \
  FM_HOME_SUMMARY_TIMEOUT=10 FM_TEST_SEAM=1 FM_NOW=1000 "$WRITER" --best-effort &
SLOW_WRITER_PID=$!
printf '%s\n' "$SLOW_WRITER_PID" > "$TIMEOUT_PARENT_FILE"
i=0
while [ ! -e "$TIMEOUT_READY" ] && [ "$i" -lt 600 ]; do sleep 0.05; i=$((i + 1)); done
[ -e "$TIMEOUT_READY" ] || fail "the timeout producer did not start"
PATH="$TIMEOUT_FAILBIN:$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BACKOFF_HOME" \
  FM_TEST_QUEUED_PRODUCER="$QUEUED_PRODUCER" FM_HOME_SUMMARY_STAGE_PATH="$TIMEOUT_QUEUED_STAGE" \
  FM_HOME_SUMMARY_TIMEOUT=60 FM_TEST_SEAM=1 FM_NOW=1000 "$WRITER" --best-effort &
SLOW_NM_PID=$!
i=0
until grep -q '^lock-wait' "$TIMEOUT_QUEUED_STAGE" 2>/dev/null; do
  [ "$i" -lt 600 ] || fail "the timeout sibling did not queue for the lock"
  sleep 0.05
  i=$((i + 1))
done
i=0
while [ ! -e "$TIMEOUT_PARENT_STOPPED" ] && [ "$i" -lt 600 ]; do sleep 0.05; i=$((i + 1)); done
[ -e "$TIMEOUT_PARENT_STOPPED" ] || fail "the timed-out caller did not reach stage diagnostics"
wait "$SLOW_NM_PID" || fail "the timeout sibling changed its best-effort result"
SLOW_NM_PID=
[ ! -e "$QUEUED_PRODUCER" ] || fail "a queued producer started before timeout backoff was recorded"
[ "$(cat "$BACKOFF_HOME/state/.home-summary-refresh.backoff")" = "$(printf 'failures=1\nnext=1030')" ] \
  || fail "the timeout was not recorded exactly once before the lock was released"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BACKOFF_HOME" "$WRITER" \
  || fail "direct publication failed while the older caller was finishing diagnostics"
[ ! -e "$BACKOFF_HOME/state/.home-summary-refresh.backoff" ] || fail "direct publication did not reset timeout backoff"
kill -CONT "$SLOW_WRITER_PID"
wait "$SLOW_WRITER_PID" || fail "the timed-out caller changed its best-effort result"
SLOW_WRITER_PID=
[ ! -e "$BACKOFF_HOME/state/.home-summary-refresh.backoff" ] || fail "an older timeout restored backoff after publication"
jq -e '.schema == "fm-secondmate-home-summary.v1"' "$BACKOFF_HOME/state/home-summary.json" >/dev/null \
  || fail "finishing an older timeout changed the newly published ledger"
pass "timeout backoff precedes admission and cannot undo a later publication"

STALLBIN="$TMP_ROOT/backoff-stall-bin"
mkdir -p "$STALLBIN"
REAL_MV=$(command -v mv)
cat > "$STALLBIN/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */.home-summary-refresh.backoff)
      : > "$FM_TEST_BACKOFF_STALLED"
      sleep 60
      ;;
  esac
done
exec "$FM_TEST_REAL_MV" "$@"
SH
cat > "$STALLBIN/jq" <<'SH'
#!/usr/bin/env bash
: > "$FM_TEST_BACKOFF_PRODUCER_STARTED"
sleep 60
exit 7
SH
chmod +x "$STALLBIN/mv" "$STALLBIN/jq"
rm -f "$BACKOFF_HOME/state/.home-summary-refresh.backoff"
PATH="$STALLBIN:$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BACKOFF_HOME" \
  FM_TEST_REAL_MV="$REAL_MV" FM_TEST_BACKOFF_STALLED="$TMP_ROOT/backoff-write-stalled" \
  FM_TEST_BACKOFF_PRODUCER_STARTED="$TMP_ROOT/backoff-producer-started" \
  FM_HOME_SUMMARY_TIMEOUT=10 fm_run_timed 30 "$WRITER" --best-effort \
  || fail "stalled backoff publication escaped its bound or changed best-effort status"
[ -e "$TMP_ROOT/backoff-producer-started" ] || fail "the stalled-write fixture never started its producer"
[ -e "$TMP_ROOT/backoff-write-stalled" ] || fail "the lock owner did not attempt to record its timeout"
pass "a stalled timeout backoff write remains bounded while holding the lock"

cat > "$TMP_ROOT/stall-backoff-read.sh" <<'SH'
read() {
  case "${HOME_SUMMARY_MODE:-}" in
    parent|worker)
      : > "$FM_TEST_BACKOFF_STALLED"
      sleep 60
      ;;
  esac
  builtin read "$@"
}
SH
printf 'failures=1\nnext=0\n' > "$BACKOFF_HOME/state/.home-summary-refresh.backoff"
BASH_ENV="$TMP_ROOT/stall-backoff-read.sh" \
  FM_TEST_BACKOFF_STALLED="$TMP_ROOT/backoff-read-stalled" \
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BACKOFF_HOME" \
  FM_HOME_SUMMARY_TIMEOUT=1 fm_run_timed 20 "$WRITER" --best-effort \
  || fail "a stalled backoff read escaped its bound or changed best-effort status"
[ -e "$TMP_ROOT/backoff-read-stalled" ] || fail "the stalled backoff read was not reached"
pass "backoff eligibility and failure reads cannot hold a lifecycle caller"
