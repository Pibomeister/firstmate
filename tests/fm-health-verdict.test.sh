#!/usr/bin/env bash
# tests/fm-health-verdict.test.sh - bin/fm-health-verdict.sh: one verdict per
# home from the heartbeat, the captain record's lock verdict and the watcher
# beat, read with the monitor status, the supervision verdict, the open-work
# test and the away record.
#
# Each case builds a fixture home whose lock holder is a real sleeping process,
# writes the records it needs with chosen ages, and runs the command once.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-health-verdict-tests)
HV="$ROOT/bin/fm-health-verdict.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
TYPED="$TMP_ROOT/typed.log"
: > "$TYPED"
# Any endpoint tool the command reached would log here: it must type nothing.
for tool in tmux orca herdr zellij; do
  cat > "$FAKEBIN/$tool" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$tool" "\$*" >> "$TYPED"
exit 1
SH
  chmod +x "$FAKEBIN/$tool"
done
PATH="$FAKEBIN:$PATH"
export PATH

LOCK_PIDS=''
cleanup_health_verdict_tests() {
  local p
  for p in $LOCK_PIDS; do kill "$p" 2>/dev/null || true; done
  fm_test_cleanup
}
trap cleanup_health_verdict_tests EXIT

NOW=$(date +%s)

# new_home <dir> <lock-verdict>: a home whose live lock holder is a sleeping
# process, whose captain record carries <lock-verdict>, whose monitor unit is
# enabled, and whose heartbeat and watcher beat are fresh with a 60s bound.
new_home() {
  local home=$1 alive=$2 pid
  mkdir -p "$home/state/watchdog" "$home/config" "$home/data"
  ( sleep 100000 > /dev/null 2>&1 & printf '%s\n' "$!" > "$home/lockpid" )
  pid=$(cat "$home/lockpid")
  LOCK_PIDS="$LOCK_PIDS $pid"
  printf '%s\n' "$pid" > "$home/state/.lock"
  printf 'owner=pid:%s\nlock_pid=%s\nalive=%s\n' "$pid" "$pid" "$alive" > "$home/state/watchdog/captain"
  printf 'status=enabled at=%s\n' "$NOW" > "$home/state/monitor-status"
  heartbeat "$home" "$NOW" 60
  beat "$home" 0
}

# The age runs from published_epoch. generated_epoch, the observation time, is
# set far older on purpose, so a verdict that read it would see every heartbeat
# as stale.
heartbeat() {  # <home> <published-epoch-json> <stale-after-json>
  jq -n --argjson e "$2" --argjson b "$3" \
    '{schema:"fm-heartbeat.v1", generated_epoch:(if ($e | type) == "number" then $e - 100000 else $e end),
      published_epoch:$e, stale_after_secs:$b}' > "$1/state/heartbeat.json"
}

beat() {  # <home> <age-secs>
  : > "$1/state/.last-watcher-beat"
  fm_touch_epoch "$((NOW - $2))" "$1/state/.last-watcher-beat"
}

open_task() {  # <home>: one in-flight task with no declared wait
  : > "$1/state/task-a.meta"
}

verdict() {  # <home> [extra args]: the printed line, persistent supervision model
  local home=$1
  shift
  FM_SUPERVISION_MODEL=${MODEL:-persistent} FM_GUARD_GRACE=${GRACE:-300} FM_HOME="$home" bash "$HV" --home "$home" "$@" 2>&1
}

field() {  # <line> <key>
  printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"
}

# Marks a supervisor turn under way on the Claude Stop auto-arm model: a
# rewake generation bound to the live lock pid, newer than an old beacon.
mid_turn() {  # <home>
  local pid
  pid=$(cat "$1/lockpid")
  printf 'epoch=7 owner_pid=1 outcome=rewake updated_at=1 session_pid=%s recovery_generation=hv-gen\n' "$pid" \
    > "$1/state/.claude-autoarm-epoch"
  printf 'acked:handling:hv-gen\n' > "$1/state/.watcher-down"
  beat "$1" 400
  fm_touch_epoch "$((NOW - 300))" "$1/state/.claude-autoarm-epoch"
}

assert_nothing_typed() {
  assert_equals "" "$(cat "$TYPED")" "$1"
}

test_fresh_heartbeat_live_lock_fresh_watcher_is_ok() {
  local home="$TMP_ROOT/ok" out
  new_home "$home" live
  out=$(verdict "$home" --write)
  assert_equals "ok fresh live enabled" "$(field "$out" verdict) $(field "$out" reason) $(field "$out" lock) $(field "$out" monitor)" \
    "fresh heartbeat, live lock and fresh watcher"
  assert_contains "$out" "heartbeat_age=" "the line carries the heartbeat age"
  assert_equals "$out" "$(cat "$home/state/health-verdict")" "--write records the printed line"
  assert_equals "" "$(find "$home/state" -name '.health-verdict.*')" "the write leaves no temporary file"
  pass "a fresh heartbeat, a live lock and a fresh watcher give ok"
}

test_a_failed_write_exits_1_and_says_so() {
  local home="$TMP_ROOT/readonly" out rc
  new_home "$home" live
  chmod a-w "$home/state"
  out=$(FM_SUPERVISION_MODEL=persistent FM_HOME="$home" bash "$HV" --home "$home" --write 2>&1 >/dev/null)
  rc=$?
  chmod u+w "$home/state"
  assert_equals 1 "$rc" "a write that cannot land exits 1"
  assert_contains "$out" "cannot write" "a failed write names the record on stderr"
  assert_equals "" "$(find "$home/state" -name 'health-verdict*')" "no record or temporary file is left"
  pass "a --write that cannot record the line exits 1 with a message"
}

# HB-3 replacement (a): a dead publisher stamps nothing more, so the verdict
# reads stale once stale_after_secs has passed after the last publication, and
# not before; that is the stated detection delay.
test_dead_publisher_reads_stale_after_its_bound() {
  local home="$TMP_ROOT/dead-publisher" out now
  new_home "$home" live
  # A fresh clock here, so time the earlier tests used cannot move the case.
  now=$(date +%s)
  heartbeat "$home" "$((now - 50))" 60
  out=$(verdict "$home")
  assert_equals ok "$(field "$out" verdict)" "a heartbeat inside its bound"
  heartbeat "$home" "$((now - 70))" 60
  out=$(verdict "$home")
  assert_equals "stale heartbeat-stale" "$(field "$out" verdict) $(field "$out" reason)" "a heartbeat past its bound"
  pass "a dead publisher reads stale once its bound has passed after the last publication, and not before"
}

test_heartbeat_older_than_its_bound_is_stale() {
  local home="$TMP_ROOT/stale" out
  new_home "$home" live
  heartbeat "$home" "$((NOW - 200))" 60
  out=$(verdict "$home")
  assert_equals "stale heartbeat-stale" "$(field "$out" verdict) $(field "$out" reason)" "an over-age heartbeat outside a turn"
  assert_equals 1 "$([ "$(field "$out" heartbeat_age)" -ge 200 ] && echo 1)" "the verdict carries the measured age"
  pass "outside a supervisor turn a heartbeat older than its bound gives stale with the measured age"
}

test_dead_lock_is_dead_with_a_fresh_heartbeat_and_types_nothing() {
  local home="$TMP_ROOT/dead" out
  new_home "$home" dead
  : > "$TYPED"
  out=$(verdict "$home")
  assert_equals "dead lock-dead dead" "$(field "$out" verdict) $(field "$out" reason) $(field "$out" lock)" \
    "a dead lock with a fresh heartbeat"
  assert_nothing_typed "nothing is typed into a dead lock's endpoint"
  pass "a dead lock pid gives dead even while the heartbeat reads fresh"
}

test_dead_lock_is_dead_inside_a_turn_and_without_a_heartbeat() {
  local home="$TMP_ROOT/dead-turn" out
  new_home "$home" dead
  mid_turn "$home"
  heartbeat "$home" "$((NOW - 900))" 60
  out=$(MODEL=autoarm GRACE=60 verdict "$home")
  assert_equals "dead lock-dead" "$(field "$out" verdict) $(field "$out" reason)" "a dead lock inside a supervisor turn"
  rm -f "$home/state/heartbeat.json"
  out=$(verdict "$home")
  assert_equals "dead lock-dead unknown" "$(field "$out" verdict) $(field "$out" reason) $(field "$out" heartbeat_age)" \
    "a dead lock with no heartbeat file"
  pass "a dead lock gives dead in any turn state and with a missing heartbeat file"
}

test_mismatched_instance_is_unconfirmed_with_no_signal() {
  local home="$TMP_ROOT/mismatch" out pid
  new_home "$home" unconfirmed
  pid=$(cat "$home/lockpid")
  : > "$TYPED"
  out=$(verdict "$home")
  assert_equals "unconfirmed instance-mismatch mismatch" "$(field "$out" verdict) $(field "$out" reason) $(field "$out" lock)" \
    "a live pid whose instance does not match"
  assert_nothing_typed "an unconfirmed owner receives no typed signal"
  kill -0 "$pid" 2>/dev/null || fail "the unconfirmed lock holder must not be signalled or restarted"
  pass "a live pid that does not match its instance gives unconfirmed with no typed signal and no restart"
}

test_unconfirmed_outranks_the_stale_and_unknown_tier() {
  local home="$TMP_ROOT/mismatch-stale" out
  new_home "$home" unconfirmed
  heartbeat "$home" "$((NOW - 200))" 60
  rm -f "$home/state/monitor-status"
  out=$(verdict "$home")
  assert_equals "unconfirmed instance-mismatch" "$(field "$out" verdict) $(field "$out" reason)" \
    "a mismatched instance with a stale heartbeat and a missing monitor unit"
  pass "unconfirmed outranks the stale and unknown tier"
}

test_none_maps_by_open_work_and_away() {
  local home="$TMP_ROOT/none" out
  new_home "$home" none
  out=$(verdict "$home")
  assert_equals "ok idle none" "$(field "$out" verdict) $(field "$out" reason) $(field "$out" lock)" "none with no open work and no away record"
  open_task "$home"
  out=$(verdict "$home")
  assert_equals "dead none-open-work" "$(field "$out" verdict) $(field "$out" reason)" "none with open work"
  rm -f "$home/state/task-a.meta"
  printf 'away\n' > "$home/state/.afk"
  out=$(verdict "$home")
  assert_equals "dead none-away" "$(field "$out" verdict) $(field "$out" reason)" "none with an away record"
  pass "a captain record of none gives dead with open work or an away record, and ok (idle) with neither"
}

test_an_idle_home_past_its_bound_still_reads_idle() {
  local home="$TMP_ROOT/idle-stale" out
  new_home "$home" none
  # The session ended and the watcher with it, so publication stopped long ago.
  heartbeat "$home" "$((NOW - 2000))" 60
  out=$(verdict "$home")
  assert_equals "ok idle none" "$(field "$out" verdict) $(field "$out" reason) $(field "$out" lock)" \
    "an idle home whose heartbeat is past its bound"
  open_task "$home"
  out=$(verdict "$home")
  assert_equals "dead none-open-work" "$(field "$out" verdict) $(field "$out" reason)" \
    "none with open work and a stale heartbeat"
  rm -f "$home/state/task-a.meta"
  printf 'away\n' > "$home/state/.afk"
  out=$(verdict "$home")
  assert_equals "dead none-away" "$(field "$out" verdict) $(field "$out" reason)" \
    "none with an away record and a stale heartbeat"
  pass "an idle home reads ok (idle) past its heartbeat bound, and none with open work or an away record still reads dead"
}

test_a_stale_heartbeat_with_open_work_or_away_still_reads_stale() {
  local home="$TMP_ROOT/live-stale" out
  new_home "$home" live
  heartbeat "$home" "$((NOW - 2000))" 60
  open_task "$home"
  out=$(verdict "$home")
  assert_equals "stale heartbeat-stale" "$(field "$out" verdict) $(field "$out" reason)" \
    "a live home with open work and a stale heartbeat"
  rm -f "$home/state/task-a.meta"
  printf 'away\n' > "$home/state/.afk"
  out=$(verdict "$home")
  assert_equals "stale heartbeat-stale" "$(field "$out" verdict) $(field "$out" reason)" \
    "a live home with an away record and a stale heartbeat"
  pass "a stale heartbeat with open work or an away record still reads stale"
}

test_declared_waits_are_not_open_work() {
  local home="$TMP_ROOT/waits" out
  new_home "$home" none
  : > "$home/state/task-a.meta"
  printf 'working: step 1\npaused [at=1]: waiting on CI\n' > "$home/state/task-a.status"
  out=$(verdict "$home")
  assert_equals "ok idle" "$(field "$out" verdict) $(field "$out" reason)" "a paused task is not open work"
  printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$home/state/task-a.status"
  out=$(verdict "$home")
  assert_equals "ok idle" "$(field "$out" verdict) $(field "$out" reason)" "a captain-held task is not open work"
  printf 'paused [at=1]: waiting until 2001-01-01T00:00Z for the release\n' > "$home/state/task-a.status"
  out=$(verdict "$home")
  assert_equals "dead none-open-work" "$(field "$out" verdict) $(field "$out" reason)" "a pause past its until time is open again"
  printf 'paused [at=1]: waiting until 2999-01-01T00:00Z for the release\n' > "$home/state/task-a.status"
  out=$(verdict "$home")
  assert_equals "ok idle" "$(field "$out" verdict) $(field "$out" reason)" "a pause before its until time is not open work"
  pass "declared paused and captain-held waits are not open work, and a pause past its until time is"
}

test_open_work_counts_on_a_secondmate_home() {
  local home="$TMP_ROOT/mate" out
  new_home "$home" none
  : > "$home/.fm-secondmate-parent"
  open_task "$home"
  out=$(verdict "$home")
  assert_equals "dead none-open-work" "$(field "$out" verdict) $(field "$out" reason)" \
    "the open-work test applies no secondmate-home exclusion"
  pass "the open-work test counts in-flight work on a secondmate home"
}

test_open_goal_counts_on_a_secondmate_home() {
  local home="$TMP_ROOT/mate-goal" out
  new_home "$home" none
  : > "$home/.fm-secondmate-parent"
  printf '2026-10-31T00:00:00Z\t%s\treceived\tgoal\tsummary=work\n' "$NOW" > "$home/state/dispatch-log.tsv"
  out=$(verdict "$home")
  assert_equals "dead none-open-work" "$(field "$out" verdict) $(field "$out" reason)" \
    "an unresolved goal is open work on a secondmate home"
  printf '2026-10-31T00:00:01Z\t%s\tdispatched\tgoal\ttask=a\n' "$NOW" >> "$home/state/dispatch-log.tsv"
  out=$(verdict "$home")
  assert_equals "ok idle" "$(field "$out" verdict) $(field "$out" reason)" "a dispatched goal is no longer open work"
  pass "an unresolved dispatch-log goal is open work on a secondmate home too"
}

test_over_age_heartbeat_inside_a_turn_is_unknown_mid_turn() {
  local home="$TMP_ROOT/mid-turn" out
  new_home "$home" live
  mid_turn "$home"
  heartbeat "$home" "$((NOW - 500))" 60
  out=$(MODEL=autoarm GRACE=60 verdict "$home")
  assert_equals "unknown mid-turn" "$(field "$out" verdict) $(field "$out" reason)" "an over-age heartbeat inside a supervisor turn"
  assert_equals 1 "$([ "$(field "$out" heartbeat_age)" -ge 500 ] && echo 1)" "mid-turn carries the measured age"
  # The divergence this case depends on: the same records outside a turn read stale.
  rm -f "$home/state/.claude-autoarm-epoch"
  out=$(MODEL=autoarm GRACE=60 verdict "$home")
  assert_equals stale "$(field "$out" verdict)" "without the turn proof the same heartbeat is stale"
  pass "inside a supervisor turn with a live lock an over-age heartbeat gives unknown (mid-turn), never ok"
}

test_over_age_heartbeat_inside_a_turn_is_never_stale_whatever_the_lock() {
  local home="$TMP_ROOT/mid-turn-lock" out
  new_home "$home" live
  mid_turn "$home"
  heartbeat "$home" "$((NOW - 500))" 60
  rm -f "$home/state/watchdog/captain"
  out=$(MODEL=autoarm GRACE=60 verdict "$home")
  assert_equals "unknown lock-unknown,mid-turn" "$(field "$out" verdict) $(field "$out" reason)" "inside a turn with no captain record"
  printf 'alive=none\n' > "$home/state/watchdog/captain"
  out=$(MODEL=autoarm GRACE=60 verdict "$home")
  assert_equals "unknown mid-turn none" "$(field "$out" verdict) $(field "$out" reason) $(field "$out" lock)" \
    "inside a turn on an idle home with no lock owner"
  pass "inside a supervisor turn an over-age heartbeat is never stale, whatever the lock verdict"
}

test_mid_turn_never_upgrades_a_missing_monitor() {
  local home="$TMP_ROOT/mid-turn-monitor" out
  new_home "$home" live
  mid_turn "$home"
  heartbeat "$home" "$((NOW - 500))" 60
  rm -f "$home/state/monitor-status"
  out=$(MODEL=autoarm GRACE=60 verdict "$home")
  assert_equals "unknown monitor-missing,mid-turn missing" "$(field "$out" verdict) $(field "$out" reason) $(field "$out" monitor)" \
    "mid-turn with a missing monitor unit"
  pass "a mid-turn reading never upgrades a missing monitor unit to ok"
}

test_missing_heartbeat_is_unknown_not_dead() {
  local home="$TMP_ROOT/missing" out
  new_home "$home" live
  rm -f "$home/state/heartbeat.json"
  out=$(verdict "$home")
  assert_equals "unknown heartbeat-missing unknown" "$(field "$out" verdict) $(field "$out" reason) $(field "$out" heartbeat_age)" \
    "a missing heartbeat file"
  pass "a missing heartbeat file gives unknown, not dead"
}

test_unread_heartbeat_fields_are_unknown() {
  local home="$TMP_ROOT/unread" out
  new_home "$home" live
  jq -n --argjson now "$NOW" '{generated_epoch:$now, published_epoch:"soon", stale_after_secs:60}' > "$home/state/heartbeat.json"
  out=$(verdict "$home")
  assert_equals "unknown heartbeat-field-unread unknown" "$(field "$out" verdict) $(field "$out" reason) $(field "$out" heartbeat_age)" \
    "an unread published_epoch"
  # A record from a publisher with no publication stamp is unread, never aged
  # from its observation time.
  jq -n --argjson now "$NOW" '{generated_epoch:$now, stale_after_secs:60}' > "$home/state/heartbeat.json"
  out=$(verdict "$home")
  assert_equals "unknown heartbeat-field-unread unknown" "$(field "$out" verdict) $(field "$out" reason) $(field "$out" heartbeat_age)" \
    "a record with no published_epoch"
  heartbeat "$home" "$NOW" null
  out=$(verdict "$home")
  assert_equals "unknown stale-bound-unknown" "$(field "$out" verdict) $(field "$out" reason)" "a null stale bound"
  printf '{not json' > "$home/state/heartbeat.json"
  out=$(verdict "$home")
  assert_equals "unknown heartbeat-field-unread,stale-bound-unknown" "$(field "$out" verdict) $(field "$out" reason)" \
    "an unreadable heartbeat"
  pass "an unread heartbeat field or a null stale bound gives unknown for that field and never ok"
}

test_monitor_other_than_enabled_is_unknown_naming_the_outer_guard() {
  local home="$TMP_ROOT/monitor" out status
  new_home "$home" live
  for status in disabled uncovered unreadable; do
    printf 'status=%s at=%s\n' "$status" "$NOW" > "$home/state/monitor-status"
    out=$(verdict "$home")
    assert_equals "unknown monitor-$status $status" "$(field "$out" verdict) $(field "$out" reason) $(field "$out" monitor)" \
      "a $status monitor unit"
  done
  rm -f "$home/state/monitor-status"
  out=$(verdict "$home")
  assert_equals "unknown monitor-missing missing" "$(field "$out" verdict) $(field "$out" reason) $(field "$out" monitor)" \
    "a missing monitor unit"
  pass "a monitor status other than enabled gives unknown naming the outer guard"
}

test_stale_with_a_missing_monitor_is_stale_naming_both() {
  local home="$TMP_ROOT/stale-monitor" out
  new_home "$home" live
  heartbeat "$home" "$((NOW - 200))" 60
  rm -f "$home/state/monitor-status"
  out=$(verdict "$home")
  assert_equals "stale heartbeat-stale,monitor-missing" "$(field "$out" verdict) $(field "$out" reason)" \
    "stale and a general unknown together"
  pass "stale with a missing monitor unit gives stale and names both"
}

test_watcher_beat_older_than_its_bound_is_stale_naming_the_watcher() {
  local home="$TMP_ROOT/watcher" out
  new_home "$home" live
  printf 'watcher-stale-secs=120\n' > "$home/config/watchdog"
  beat "$home" 300
  out=$(verdict "$home")
  assert_equals "ok fresh" "$(field "$out" verdict) $(field "$out" reason)" "an idle home keeps the watcher exemption"
  open_task "$home"
  out=$(verdict "$home")
  assert_equals "stale watcher-stale" "$(field "$out" verdict) $(field "$out" reason)" "a home with open work and an old watcher beat"
  assert_equals 1 "$([ "$(field "$out" watcher_age)" -ge 300 ] && echo 1)" "the verdict carries the watcher age"
  pass "outside a supervisor turn a watcher beat older than its bound gives stale naming the watcher"
}

test_watcher_bound_reads_like_the_watchdog() {
  local home="$TMP_ROOT/watcher-bound" out
  new_home "$home" live
  open_task "$home"
  printf '# local bound\n  watcher-stale-secs = 120  \n' > "$home/config/watchdog"
  beat "$home" 300
  out=$(verdict "$home")
  assert_equals "stale watcher-stale" "$(field "$out" verdict) $(field "$out" reason)" "a spaced watcher-stale-secs line still sets the bound"
  pass "the watcher bound is read with the watchdog's own config reader"
}

test_legacy_last_heartbeat_never_feeds_the_verdict() {
  local home="$TMP_ROOT/legacy" out
  new_home "$home" live
  rm -f "$home/state/heartbeat.json"
  : > "$home/state/.last-heartbeat"
  out=$(verdict "$home")
  assert_equals "unknown heartbeat-missing" "$(field "$out" verdict) $(field "$out" reason)" "a fresh legacy record does not stand in for the heartbeat"
  heartbeat "$home" "$NOW" 60
  fm_touch_epoch "$((NOW - 99999))" "$home/state/.last-heartbeat"
  out=$(verdict "$home")
  assert_equals "ok fresh" "$(field "$out" verdict) $(field "$out" reason)" "an old legacy record does not make the verdict stale"
  pass "the legacy last-heartbeat record never feeds the verdict"
}

test_proven_turn_with_a_young_watcher_beat_is_unknown_mid_turn() {
  local home="$TMP_ROOT/mid-turn-young" out
  new_home "$home" live
  mid_turn "$home"
  # The turn began 50s ago, after a watcher beat 100s old and still inside grace.
  beat "$home" 100
  fm_touch_epoch "$((NOW - 50))" "$home/state/.claude-autoarm-epoch"
  heartbeat "$home" "$((NOW - 100))" 60
  out=$(MODEL=autoarm GRACE=300 verdict "$home")
  assert_equals "unknown mid-turn" "$(field "$out" verdict) $(field "$out" reason)" \
    "a proven turn whose watcher beat is younger than grace"
  # A watcher that beat after the turn proof is between turns: the same heartbeat is stale.
  beat "$home" 10
  out=$(MODEL=autoarm GRACE=300 verdict "$home")
  assert_equals "stale heartbeat-stale" "$(field "$out" verdict) $(field "$out" reason)" \
    "a watcher beat newer than the turn proof is between turns"
  pass "a proven supervisor turn reads mid-turn even before the watcher beat passes grace"
}

test_a_read_without_write_creates_no_state_directory() {
  local home="$TMP_ROOT/no-state" out
  local spy="$TMP_ROOT/no-state-spy" calls="$TMP_ROOT/no-state-calls.log" tool
  mkdir -p "$home/config" "$spy"
  : > "$calls"
  # Every directory create or remove the read makes is logged, then performed.
  for tool in mkdir rmdir; do
    cat > "$spy/$tool" <<SH
#!/usr/bin/env bash
printf '%s %s\\n' "$tool" "\$*" >> "$calls"
exec /bin/$tool "\$@"
SH
    chmod +x "$spy/$tool"
  done
  out=$(PATH="$spy:$PATH" verdict "$home")
  assert_equals unknown "$(field "$out" verdict)" "a home with no records reads unknown"
  assert_equals "" "$(cd "$home" && find . -mindepth 1 ! -path ./config)" "the read leaves the home unchanged"
  assert_equals "" "$(grep -F "$home/state" "$calls")" "the read never creates or removes the state directory"
  pass "a read without --write leaves a home with no state directory unchanged"
}

fm_test_run \
  test_fresh_heartbeat_live_lock_fresh_watcher_is_ok \
  test_a_failed_write_exits_1_and_says_so \
  test_heartbeat_older_than_its_bound_is_stale \
  test_dead_publisher_reads_stale_after_its_bound \
  test_dead_lock_is_dead_with_a_fresh_heartbeat_and_types_nothing \
  test_dead_lock_is_dead_inside_a_turn_and_without_a_heartbeat \
  test_mismatched_instance_is_unconfirmed_with_no_signal \
  test_unconfirmed_outranks_the_stale_and_unknown_tier \
  test_none_maps_by_open_work_and_away \
  test_an_idle_home_past_its_bound_still_reads_idle \
  test_a_stale_heartbeat_with_open_work_or_away_still_reads_stale \
  test_declared_waits_are_not_open_work \
  test_open_work_counts_on_a_secondmate_home \
  test_open_goal_counts_on_a_secondmate_home \
  test_over_age_heartbeat_inside_a_turn_is_unknown_mid_turn \
  test_over_age_heartbeat_inside_a_turn_is_never_stale_whatever_the_lock \
  test_mid_turn_never_upgrades_a_missing_monitor \
  test_missing_heartbeat_is_unknown_not_dead \
  test_unread_heartbeat_fields_are_unknown \
  test_monitor_other_than_enabled_is_unknown_naming_the_outer_guard \
  test_stale_with_a_missing_monitor_is_stale_naming_both \
  test_watcher_beat_older_than_its_bound_is_stale_naming_the_watcher \
  test_watcher_bound_reads_like_the_watchdog \
  test_legacy_last_heartbeat_never_feeds_the_verdict \
  test_proven_turn_with_a_young_watcher_beat_is_unknown_mid_turn \
  test_a_read_without_write_creates_no_state_directory
