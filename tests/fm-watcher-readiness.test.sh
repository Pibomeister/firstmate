#!/usr/bin/env bash
# tests/fm-watcher-readiness.test.sh - pane-staleness progress versus a stuck
# subordinate, returning stages versus grace, and the supported starter's
# stale-holder refusal.
# The progress case is red against a beacon touched only at cycle start:
# many completed captures whose sum exceeds grace still age that beacon.
# The returning-stage case is red when completed stages between cycle start
# and the pane scan do not refresh the beacon.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-watcher-readiness-tests)

# Scaled stand-in for the recorded 300s grace and a serial scan that crosses
# it. Grace stays above the pre-loop preamble and above one capture, and below
# the sum of completed captures. Wall clock is compressed. This is not a
# live-home census and not a whole-night pass.
READINESS_RECORDS=20
READINESS_GRACE=8
READINESS_SLEEP=0.4

# Same scaled grace as the capture cases. Three returning helpers of STAGE_STEP
# seconds sum past grace; one helper of STAGE_HUNG seconds is itself past grace.
STAGE_GRACE=8
STAGE_STEP=4
STAGE_HUNG=12

install_capture_tmux() {  # <dir> <sleep-seconds>
  local dir=$1
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" != capture-pane ]; then
  exit 0
fi
target=
prev=
for arg in "$@"; do
  if [ "$prev" = -t ]; then
    target=$arg
  fi
  prev=$arg
done
beat="$FM_READINESS_STATE/.last-watcher-beat"
now_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
if [ -e "$beat" ]; then
  m=$(stat -c %Y "$beat" 2>/dev/null || stat -f %m "$beat")
else
  m=0
fi
age_ms=$((now_ms - m * 1000))
seq=$(cat "$FM_READINESS_STATE/capture-seq" 2>/dev/null || echo 0)
seq=$((seq + 1))
printf '%s\n' "$seq" > "$FM_READINESS_STATE/capture-seq"
printf '%s\t%s\t%s\t%s\t%s\tstart\n' "$seq" "$target" "$now_ms" "$m" "$age_ms" >> "$FM_READINESS_LOG"
sleep "$FM_READINESS_CAPTURE_SLEEP"
now_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
if [ -e "$beat" ]; then
  m=$(stat -c %Y "$beat" 2>/dev/null || stat -f %m "$beat")
else
  m=0
fi
age_ms=$((now_ms - m * 1000))
printf '%s\t%s\t%s\t%s\t%s\tend\n' "$seq" "$target" "$now_ms" "$m" "$age_ms" >> "$FM_READINESS_LOG"
printf 'fixture-capture-%s\n' "$seq"
exit 0
SH
  chmod +x "$dir/fakebin/tmux"
}

seed_records() {  # <state> <count>
  local state=$1 count=$2 i name
  # Fresh stamps keep the pre-loop maintenance passes from running, so the
  # measured age is the pane-staleness scan rather than an absent-stamp sweep.
  touch "$state/home-summary.json" "$state/.last-worktree-cleanup" \
    "$state/.last-check" "$state/.last-heartbeat"
  i=1
  while [ "$i" -le "$count" ]; do
    name=$(printf 'rec-%02d' "$i")
    printf 'kind=ship\nbackend=tmux\nwindow=fix:%s\n' "$name" > "$state/$name.meta"
    i=$((i + 1))
  done
}

run_once() {  # <dir> <state> <log> <sleep>
  local dir=$1 state=$2 log=$3 sleep_s=$4
  PATH="$dir/fakebin:$PATH" \
    FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$state" \
    FM_CONFIG_OVERRIDE="$dir/config" \
    FM_GUARD_GRACE="$READINESS_GRACE" \
    FM_WATCHER_STALE_GRACE="$READINESS_GRACE" \
    FM_WATCHER_STALL_BOUND=999999 \
    FM_POLL=60 \
    FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 \
    FM_WORKTREE_CLEANUP=0 \
    FM_WATCH_ONCE=1 \
    FM_READINESS_STATE="$state" \
    FM_READINESS_LOG="$log" \
    FM_READINESS_CAPTURE_SLEEP="$sleep_s" \
    "$WATCH"
}

summarize_captures() {  # <log> <grace-seconds>
  awk -F '\t' -v grace_ms="$2" '
    $6 == "start" {
      starts++
      age = $5 + 0
      if (starts == 1 || age < min_start) min_start = age
      if (age > max_start) max_start = age
      if (earliest == 0 && age >= grace_ms) {
        earliest = $1
        earliest_age = age
      }
      if (prev_start > 0) {
        gap = ($3 + 0) - prev_start
        if (gaps == 0 || gap > max_gap) max_gap = gap
        gaps++
      }
      prev_start = $3 + 0
      start_at[$1] = $3 + 0
    }
    $6 == "end" {
      ends++
      dur = ($3 + 0) - start_at[$1]
      sum += dur
      if (ends == 1 || dur < min_dur) min_dur = dur
      if (dur > max_dur) max_dur = dur
    }
    END {
      printf "captures=%d ends=%d preamble_ms=%d max_start_age_ms=%d earliest_stale_seq=%d earliest_stale_age_ms=%d min_capture_ms=%d max_capture_ms=%d sum_capture_ms=%d max_record_gap_ms=%d grace_ms=%s\n", \
        starts + 0, ends + 0, min_start + 0, max_start + 0, earliest + 0, earliest_age + 0, min_dur + 0, max_dur + 0, sum + 0, max_gap + 0, grace_ms
    }
  ' "$1"
}

test_capture_accepts_gnu_stat() {
  local dir state log
  dir=$(make_case gnu-stat)
  state="$dir/state"
  log="$dir/capture.log"
  install_capture_tmux "$dir"
  touch "$state/.last-watcher-beat"
  cat > "$dir/fakebin/stat" <<'SH'
#!/usr/bin/env bash
case "$1" in
  -c) printf '946684800\n' ;;
  -f) printf '  File: fixture\n'; exit 1 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/stat"
  PATH="$dir/fakebin:$PATH" FM_READINESS_STATE="$state" \
    FM_READINESS_LOG="$log" FM_READINESS_CAPTURE_SLEEP=0 \
    "$dir/fakebin/tmux" capture-pane -t fixture > "$dir/capture.out" 2> "$dir/capture.err" \
    || fail "capture rejected GNU stat: $(cat "$dir/capture.err")"
  awk -F '\t' 'NF != 6 || $4 != "946684800" { bad = 1 }
    END { exit (bad || NR != 2) }' "$log" \
    || fail "capture timestamps were not numeric GNU stat results: $(cat "$log")"
  pass "capture records numeric timestamps when BSD stat emits text before failing"
}

test_stuck_subordinate_still_becomes_stale() {
  local dir state log out pid i age health=0 started
  dir=$(make_case stuck-subordinate)
  state="$dir/state"
  log="$dir/capture.log"
  mkdir -p "$dir/config"
  install_capture_tmux "$dir"
  seed_records "$state" 1
  : > "$log"
  run_once "$dir" "$state" "$log" "$((READINESS_GRACE + 4))" > "$dir/watch.out" 2> "$dir/watch.err" &
  pid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    if grep -q $'\tstart$' "$log" 2>/dev/null && ! grep -q $'\tend$' "$log" 2>/dev/null; then
      break
    fi
    sleep 0.25
    i=$((i + 1))
  done
  started=0
  grep -q $'\tstart$' "$log" 2>/dev/null && started=1
  [ "$started" -eq 1 ] || fail "stuck capture never started: $(cat "$dir/watch.err" "$dir/watch.out")"
  start_age_ms=$(awk -F '\t' '$6 == "start" { print $5; exit }' "$log")
  [ "$start_age_ms" -lt $((READINESS_GRACE * 1000)) ] || \
    fail "stuck capture began already stale (start age ${start_age_ms}ms, grace ${READINESS_GRACE}s)"
  i=0
  age=0
  while [ "$i" -lt 40 ]; do
    if [ -e "$state/.last-watcher-beat" ]; then
      age=$(( $(date +%s) - $(stat -c %Y "$state/.last-watcher-beat" 2>/dev/null || stat -f %m "$state/.last-watcher-beat") ))
    fi
    [ "$age" -ge "$READINESS_GRACE" ] && break
    sleep 0.25
    i=$((i + 1))
  done
  grep -q $'\tend$' "$log" && fail "stuck capture returned before grace (age=${age}s)"
  [ "$age" -ge "$READINESS_GRACE" ] || fail "stuck beacon age ${age}s never reached grace ${READINESS_GRACE}s"
  health=0
  FM_HOME="$dir" FM_GUARD_GRACE="$READINESS_GRACE" bash -c '
    # shellcheck disable=SC1090
    . "$1"
    fm_watcher_healthy "$2" "$3" "$4" "$5"
  ' _ "$LIB" "$state" "$WATCH" "$READINESS_GRACE" "$dir" || health=$?
  [ "$health" -ne 0 ] || fail "a blocked capture still read as a healthy watcher at beacon age ${age}s"
  wait "$pid" || true
  printf 'counterfactual-stuck revision=%s grace=%s beacon_age=%s health_rc=%s\n' \
    "$(git -C "$ROOT" rev-parse HEAD)" "$READINESS_GRACE" "$age" "$health"
  pass "a capture that stays blocked past grace is not ready"
}

field() {  # <summary> <key>
  local rest=${1#*"$2="}
  printf '%s\n' "${rest%% *}"
}

test_progressing_records_stay_ready_across_grace() {
  local dir state log summary preamble max_start sum_ms max_dur earliest revision grace_ms
  dir=$(make_case progressing-records)
  state="$dir/state"
  log="$dir/capture.log"
  mkdir -p "$dir/config"
  install_capture_tmux "$dir"
  seed_records "$state" "$READINESS_RECORDS"
  : > "$log"
  grace_ms=$((READINESS_GRACE * 1000))
  run_once "$dir" "$state" "$log" "$READINESS_SLEEP" > "$dir/watch.out" 2> "$dir/watch.err" || \
    fail "progressing watcher exited nonzero: $(cat "$dir/watch.err" "$dir/watch.out")"
  summary=$(summarize_captures "$log" "$grace_ms")
  revision=$(git -C "$ROOT" rev-parse HEAD)
  printf 'counterfactual-progress revision=%s records=%s sleep=%s %s\n' \
    "$revision" "$READINESS_RECORDS" "$READINESS_SLEEP" "$summary"
  preamble=$(field "$summary" preamble_ms)
  max_start=$(field "$summary" max_start_age_ms)
  sum_ms=$(field "$summary" sum_capture_ms)
  max_dur=$(field "$summary" max_capture_ms)
  earliest=$(field "$summary" earliest_stale_seq)
  [ "$preamble" -lt "$grace_ms" ] || \
    fail "beacon was already stale before the first record (preamble ${preamble}ms >= grace ${grace_ms}ms); this run does not isolate the serial seam"
  [ "$sum_ms" -gt "$grace_ms" ] || fail "capture sum ${sum_ms}ms did not cross grace ${grace_ms}ms ($summary)"
  [ "$max_dur" -lt "$grace_ms" ] || fail "one capture lasted ${max_dur}ms, which is not a progressing record ($summary)"
  [ "$max_start" -lt "$grace_ms" ] || \
    fail "progressing scan went stale at capture ${earliest} (max start age ${max_start}ms, grace ${grace_ms}ms)"
  pass "completed records stay inside grace while their sum crosses it"
}

# Copy the watcher tree and replace the three helpers the poll runs in
# series between cycle start and the pane scan. The copy is what the watcher
# executes, so the beacon age is the real poll, not a source match.
install_stage_bin() {  # <dest-bin> <step-seconds> <mode>
  local dest=$1 step=$2 mode=$3 name
  mkdir -p "$(dirname "$dest")"
  cp -R "$ROOT/bin" "$dest"
  if [ "$mode" = returning ]; then
    for name in fm-procevent.sh fm-inactive-reconcile.sh fm-worktree-cleanup.sh; do
      printf '#!/usr/bin/env bash\nsleep %s\nexit 0\n' "$step" > "$dest/$name"
      chmod +x "$dest/$name"
    done
  else
    printf '#!/usr/bin/env bash\nsleep %s\nexit 0\n' "$step" > "$dest/fm-procevent.sh"
    chmod +x "$dest/fm-procevent.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$dest/fm-inactive-reconcile.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$dest/fm-worktree-cleanup.sh"
    chmod +x "$dest/fm-inactive-reconcile.sh" "$dest/fm-worktree-cleanup.sh"
  fi
}

# Run one quiet cycle. Samples beacon age until the watcher exits.
# Sets STAGE_MAX and STAGE_RC. A watcher still alive after 90s is a failure.
run_stage_fixture() {  # <name> <step-seconds> <mode>
  local name=$1 step=$2 mode=$3 dir state pid now b age max started deadline rc stg
  dir="$TMP_ROOT/$name"
  rm -rf "$dir"
  mkdir -p "$dir/home/state/procevent" "$dir/home/config" "$dir/fakebin"
  fm_test_track_watcher_state "$dir/home/state"
  install_stage_bin "$dir/tree/bin" "$step" "$mode"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/fakebin/tmux"
  chmod +x "$dir/fakebin/tmux"
  state="$dir/home/state"
  touch "$state/home-summary.json" "$state/.last-check" "$state/.last-heartbeat"
  touch -t 200001010000 "$state/.last-worktree-cleanup"
  printf 'kind=ship\nbackend=tmux\nwindow=fix:rec-01\n' > "$state/rec-01.meta"
  : > "$dir/samples.tsv"
  started=$(date +%s)
  PATH="$dir/fakebin:$PATH" \
    FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$state" \
    FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_GUARD_GRACE="$STAGE_GRACE" \
    FM_WATCHER_STALE_GRACE="$STAGE_GRACE" \
    FM_WATCHER_STALL_BOUND=999999 \
    FM_POLL=60 \
    FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=1 \
    FM_HEARTBEAT=999999 \
    FM_WORKTREE_CLEANUP=1 \
    FM_WATCH_ONCE=1 \
    "$dir/tree/bin/fm-watch.sh" > "$dir/watch.out" 2> "$dir/watch.err" &
  pid=$!
  max=0
  deadline=$((started + 90))
  while kill -0 "$pid" 2>/dev/null; do
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      fail "stage watcher still running after 90s ($name): $(tail -n 30 "$dir/watch.err" "$dir/watch.out")"
    fi
    b=$(stat -c %Y "$state/.last-watcher-beat" 2>/dev/null || stat -f %m "$state/.last-watcher-beat" 2>/dev/null || true)
    stg=$(cut -f3 "$state/.watcher-stage" 2>/dev/null || true)
    if [ -n "${b:-}" ]; then
      age=$((now - b))
      [ "$age" -gt "$max" ] && max=$age
      printf '%s\t%s\t%s\n' "$now" "$age" "$stg" >> "$dir/samples.tsv"
    fi
    sleep 0.5
  done
  rc=0
  wait "$pid" || rc=$?
  STAGE_MAX=$max
  STAGE_RC=$rc
  STAGE_ELAPSED=$(( $(date +%s) - started ))
  printf '%s\n' "$max" > "$dir/max-age"
  printf '%s\n' "$rc" > "$dir/watch.rc"
  printf '%s\n' "$STAGE_ELAPSED" > "$dir/elapsed"
}

test_returning_stages_stay_inside_grace() {
  local need
  run_stage_fixture returning-stages "$STAGE_STEP" returning
  [ "$STAGE_RC" -eq 0 ] || \
    fail "returning watcher exited ${STAGE_RC}: $(cat "$TMP_ROOT/returning-stages/watch.err" "$TMP_ROOT/returning-stages/watch.out")"
  need=$((STAGE_STEP * 3))
  [ "$STAGE_ELAPSED" -ge "$need" ] || \
    fail "returning fixture finished in ${STAGE_ELAPSED}s, so three ${STAGE_STEP}s stages did not run"
  [ "$STAGE_MAX" -lt "$STAGE_GRACE" ] || \
    fail "returning stages reached beacon age ${STAGE_MAX}s against grace ${STAGE_GRACE}s (step ${STAGE_STEP}s, elapsed ${STAGE_ELAPSED}s)"
  printf 'stage-beat mode=returning grace=%s step=%s max_beacon_age=%s elapsed=%s\n' \
    "$STAGE_GRACE" "$STAGE_STEP" "$STAGE_MAX" "$STAGE_ELAPSED"
  pass "returning stages stay inside grace while their sum crosses it"
}

test_hung_stage_still_ages_past_grace() {
  run_stage_fixture hung-stage "$STAGE_HUNG" hung
  [ "$STAGE_RC" -eq 0 ] || \
    fail "hung-stage watcher exited ${STAGE_RC}: $(cat "$TMP_ROOT/hung-stage/watch.err" "$TMP_ROOT/hung-stage/watch.out")"
  [ "$STAGE_ELAPSED" -ge "$STAGE_HUNG" ] || \
    fail "hung fixture finished in ${STAGE_ELAPSED}s, so the ${STAGE_HUNG}s stage did not run"
  [ "$STAGE_MAX" -ge "$STAGE_GRACE" ] || \
    fail "hung stage beacon age ${STAGE_MAX}s stayed inside grace ${STAGE_GRACE}s (elapsed ${STAGE_ELAPSED}s)"
  printf 'stage-beat mode=hung grace=%s step=%s max_beacon_age=%s elapsed=%s\n' \
    "$STAGE_GRACE" "$STAGE_HUNG" "$STAGE_MAX" "$STAGE_ELAPSED"
  pass "a stage that outlasts grace still ages the beacon"
}

test_starter_surfaces_stale_holder_refusal() {
  local dir holder shell owner i rc out log
  dir=$(make_case starter-refusal)
  mkdir -p "$dir/config" "$dir/parent/state" "$dir/parent/state/sm-test-1.inbox/handled"
  printf 'sm-test-1\n' > "$dir/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$dir/parent" > "$dir/.fm-secondmate-parent"
  ln -s "$(command -v bash)" "$dir/fakebin/codex"
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pane process-info") cat "$FM_T_HERDR_INFO" ;;
  "status --json") printf '{"client":{"version":"0.7.4","protocol":14},"server":{"running":true}}\n' ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/herdr"
  cat > "$dir/owner.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
printf '%s\n' "$$" > "$FM_T_DIR/owner.pid"
i=0
while [ ! -e "$FM_T_DIR/start" ] && [ "$i" -lt 400 ]; do
  sleep 0.05
  i=$((i + 1))
done
rc=0
# shellcheck disable=SC1090
. "$FM_PUSH_LIB" && fm_secondmate_watch_start > "$FM_T_DIR/start.out" 2>&1 || rc=$?
printf '%s\n' "$rc" > "$FM_T_DIR/start.rc"
SH
  chmod +x "$dir/owner.sh"
  sleep 60 &
  holder=$!
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\n' "$holder" > "$dir/state/.watch.lock/pid"
  touch -t 200001010000 "$dir/state/.last-watcher-beat"
  env -u TMUX -u TMUX_PANE \
    FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" \
    CONFIG="$dir/config" \
    FM_TASK_INBOX="$dir/parent/state/sm-test-1.inbox" \
    FM_T_DIR="$dir" \
    FM_T_HERDR_INFO="$dir/process-info.json" \
    FM_PUSH_LIB="$ROOT/bin/fm-push-transition-lib.sh" \
    FM_GUARD_GRACE=1 \
    FM_WATCHER_STALE_GRACE=1 \
    FM_WATCHER_STALL_BOUND=9999999999 \
    FM_POLL=5 \
    PATH="$dir/fakebin:$PATH" \
    HERDR_SESSION=lab \
    HERDR_PANE_ID=w1:p1 \
    "$dir/fakebin/codex" "$dir/owner.sh" >/dev/null 2>&1 &
  shell=$!
  i=0
  while [ ! -s "$dir/owner.pid" ] && [ "$i" -lt 200 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  if [ ! -s "$dir/owner.pid" ]; then
    kill "$holder" "$shell" 2>/dev/null || true
    wait "$holder" "$shell" 2>/dev/null || true
    fail "starter lock owner never started"
  fi
  owner=$(cat "$dir/owner.pid")
  printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p1","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"codex","argv0":"codex"}]}}}\n' \
    "$shell" "$owner" "$owner" > "$dir/process-info.json"
  printf '%s\n' 'watcher: lock held by live pid 1 but heartbeat is stale for 9s (>1s); OLD-MARKER' \
    > "$dir/state/.secondmate-watch.log"
  : > "$dir/start"
  i=0
  while [ ! -s "$dir/start.rc" ] && [ "$i" -lt 400 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  rc=$(cat "$dir/start.rc" 2>/dev/null || echo missing)
  out=$(cat "$dir/start.out" 2>/dev/null || true)
  log=$(cat "$dir/state/.secondmate-watch.log" 2>/dev/null || true)
  watcher=$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)
  if [ -n "$watcher" ] && [ "$watcher" != "$holder" ]; then
    kill "$watcher" 2>/dev/null || true
  fi
  kill "$holder" "$owner" "$shell" 2>/dev/null || true
  wait "$holder" "$owner" "$shell" 2>/dev/null || true
  [ "$rc" = 1 ] || fail "starter exit was ${rc}, want 1: ${out}"$'\n'"${log}"
  printf '%s\n' "$out" | grep -F 'heartbeat is stale' >/dev/null \
    || fail "starter hid the stale-holder refusal: ${out}"$'\n'"${log}"
  printf '%s\n' "$out" | grep -F "lock held by live pid ${holder}" >/dev/null \
    || fail "starter refusal did not name the live holder ${holder}: ${out}"
  printf '%s\n' "$out" | grep -F 'OLD-MARKER' >/dev/null \
    && fail "starter relayed a refusal from before this launch: ${out}"
  pass "supported starter surfaces the live stale-holder refusal and exits 1"
}

selection_probe() {  # <case_home> <parent> <mode> [NAME=VALUE...]
  local case_home=$1 parent=$2 mode=$3
  shift 3
  env -u TMUX -u TMUX_PANE -u HERDR_SESSION -u HERDR_PANE_ID \
    -u FM_BACKEND -u FM_SESSION_ENDPOINT_META \
    FM_HOME="$case_home" FM_STATE_OVERRIDE="$case_home/state" FM_CONFIG_OVERRIDE="$case_home/config" \
    FM_TASK_INBOX="$parent/state/fixture-mate.inbox" \
    "$@" "$WATCH" "$mode"
}

test_secondmate_selection_refusal_is_actionable() {
  local dir case_home parent out rc
  dir="$TMP_ROOT/selection-refusal"
  case_home="$dir/home"
  parent="$dir/parent"
  mkdir -p "$case_home/state" "$case_home/config" "$parent/state/fixture-mate.inbox"
  printf 'fixture-mate\n' > "$case_home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$case_home/.fm-secondmate-parent"
  : > "$case_home/config/supervision-host-off"

  rc=0
  out=$(selection_probe "$case_home" "$parent" --secondmate-selected 2>&1) || rc=$?
  assert_equals 1 "$rc" 'a missing terminal candidate must remain refused'
  assert_contains "$out" 'native endpoint registration' 'selection silently refused the missing prerequisite'
  rc=0
  out=$(selection_probe "$case_home" "$parent" --secondmate 2>&1) || rc=$?
  assert_equals 1 "$rc" 'the starter must refuse the same missing prerequisite'
  assert_contains "$out" 'native endpoint registration' 'starter hid the selection refusal reason'

  selection_probe "$case_home" "$parent" --secondmate-selected HERDR_PANE_ID=wlab:plab \
    || fail 'a candidate with a valid local parent and inbox was not eligible'
  rc=0
  out=$(selection_probe "$case_home" "$parent" --secondmate-status HERDR_PANE_ID=wlab:plab 2>&1) || rc=$?
  assert_equals 1 "$rc" 'selection eligibility became readiness without a verified binding'
  assert_contains "$out" 'not ready' 'unbound status must stay unready'

  rc=0
  out=$(selection_probe "$case_home" "$parent" --secondmate-selected \
    HERDR_PANE_ID=wlab:plab FM_TASK_INBOX=foreign.inbox 2>&1) || rc=$?
  assert_equals 1 "$rc" 'a foreign inbox must remain refused'
  assert_contains "$out" 'steering inbox' 'foreign-inbox refusal lacked its reason'

  mv "$case_home/.fm-secondmate-parent" "$case_home/parent.saved"
  rc=0
  out=$(selection_probe "$case_home" "$parent" --secondmate-selected HERDR_PANE_ID=wlab:plab 2>&1) || rc=$?
  assert_equals 1 "$rc" 'a missing parent record must remain refused'
  assert_contains "$out" 'parent' 'missing-parent refusal lacked its reason'
  mv "$case_home/parent.saved" "$case_home/.fm-secondmate-parent"

  : > "$case_home/state/.afk"
  rc=0
  out=$(selection_probe "$case_home" "$parent" --secondmate-selected HERDR_PANE_ID=wlab:plab 2>&1) || rc=$?
  assert_equals 1 "$rc" 'an away-owned case_home must remain refused'
  assert_contains "$out" 'away' 'ownership-mode refusal lacked its reason'
  rm "$case_home/state/.afk"

  rm "$case_home/.fm-secondmate-home"
  rc=0
  out=$(selection_probe "$case_home" "$parent" --secondmate-selected HERDR_PANE_ID=wlab:plab 2>&1) || rc=$?
  assert_equals 1 "$rc" 'a primary or unmarked home must remain refused'
  assert_contains "$out" 'secondmate home' 'case_home-scope refusal lacked its reason'
  assert_absent "$case_home/state/.watch.lock" 'read-only selection or refused start armed a watcher'
  assert_absent "$case_home/state/.last-watcher-beat" 'read-only selection manufactured a beat'
  pass 'secondmate selection reports actionable refusals without granting binding readiness'
}

if [ "$#" -gt 0 ]; then
  fm_test_run "$@"
  exit "$?"
fi

fm_test_run \
  test_secondmate_selection_refusal_is_actionable \
  test_capture_accepts_gnu_stat \
  test_stuck_subordinate_still_becomes_stale \
  test_progressing_records_stay_ready_across_grace \
  test_returning_stages_stay_inside_grace \
  test_hung_stage_still_ages_past_grace \
  test_starter_surfaces_stale_holder_refusal
