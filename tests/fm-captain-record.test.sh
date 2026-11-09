#!/usr/bin/env bash
# tests/fm-captain-record.test.sh - captain record and second-mate endpoint
# provenance in bin/fm-watchdog.sh.
#
# Each case builds disposable homes whose lock holder is a real process and
# whose panes are real tmux panes on a private socket, writes a heartbeat with
# a chosen session, writer, and time, and runs one `scan` pass with a fixed
# clock. The pass prints each subject's endpoint and rewrites each home's
# state/watchdog/captain record; scan takes no action.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-captain-record-tests)
WD="$ROOT/bin/fm-watchdog.sh"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-captain-record-test-$$"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -f /dev/null -L "$SOCKET" "\$@"
SH
chmod +x "$FAKEBIN/tmux"
PATH="$FAKEBIN:$PATH"
export PATH

LOCK_PIDS=''
cleanup_captain_record_tests() {
  local p
  for p in $LOCK_PIDS; do kill "$p" 2>/dev/null || true; done
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_captain_record_tests EXIT

BASE=$(date +%s)
LOCK_AT=$((BASE - 100))
PANES="$TMP_ROOT/panes"
: > "$PANES"

# new_pane: a fresh pane in its own session on the private socket; prints its id.
# It runs in a command substitution, so the session count lives in a file.
new_pane() {
  local sess
  printf 'x\n' >> "$PANES"
  sess="cr$(wc -l < "$PANES" | tr -d ' ')"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" new-session -d -s "$sess" -x 120 -y 30 "printf '%s\n> \n' '$sess'; exec cat > /dev/null"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" list-panes -t "$sess" -F '#{pane_id}' | head -n 1
}

# new_home <dir> <session>: a home whose live lock holder took the lock at LOCK_AT.
new_home() {
  local home=$1 sid=$2
  mkdir -p "$home/state" "$home/config" "$home/data"
  ( sleep 100000 > /dev/null 2>&1 & printf '%s\n' "$!" > "$home/lockpid" )
  LOCK_PIDS="$LOCK_PIDS $(cat "$home/lockpid")"
  cat "$home/lockpid" > "$home/state/.lock"
  printf '%s\n' "$sid" > "$home/state/.lock-session"
  fm_touch_epoch "$LOCK_AT" "$home/state/.lock" "$home/state/.lock-session"
  printf 'mode=dry-run\nmodels=\n' > "$home/config/watchdog"
}

# heartbeat <home> <pane> <session> <epoch> <writer>: writer is `owner` (the
# lock holder's pid and session), `daemon` (written outside the owner, as an
# away daemon's watcher writes it: no harness anchor and no trusted session),
# or `foreign` (a known live writer whose pid and session are not the owner's).
heartbeat() {
  local home=$1 pane=$2 sid=$3 at=$4 writer=$5 wpid wsid
  case "$writer" in
    owner) wpid=$(cat "$home/lockpid") wsid=$sid ;;
    foreign) wpid=$$ wsid=00000000-0000-4000-8000-0000000000f1 ;;
    *) wpid=- wsid=- ;;
  esac
  jq -n --arg t "$pane" --arg s "$sid" --argjson e "$at" --arg p "$wpid" --arg w "$wsid" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e,
      primary:{terminal:{backend:"tmux",target:$t,present:true}, session:{trusted_id:$s},
        writer:{anchor_pid:(if $p == "-" then {unknown:true} else ($p | tonumber) end),
          session_id:(if $w == "-" then {unknown:true} else $w end)}}}' > "$home/state/heartbeat.json"
}

# scan <owner-home> <offset>: one observation pass at BASE+offset; prints the pass.
scan() {
  FM_TEST_SEAM=1 FM_WD_TEST_COMPOSER=empty FM_WD_NOW=$((BASE + $2)) FM_HOME="$1" bash "$WD" scan 2>&1
}

field() {  # <home> <key>
  sed -n "s/^$2=//p" "$1/state/watchdog/captain" 2>/dev/null | tail -n 1
}

terminal() {  # <home>
  printf '%s %s' "$(field "$1" backend)" "$(field "$1" target)"
}

# endpoint_of <scan-output> <home>: the endpoint the pass read for that subject.
endpoint_of() {
  printf '%s\n' "$1" | awk -v h="($2)" '$1 == "subject" && $3 == h { f = 1; next } f && $1 ~ /^endpoint=/ { sub(/^endpoint=/, "", $1); print $1; exit }'
}

# A parent home with one registered second mate whose endpoint the parent records.
make_pair() {  # <dir>: sets PARENT, MATE, MATE_SID, META_PANE
  PARENT="$1/parent" MATE="$1/mate"
  MATE_SID=00000000-0000-4000-8000-0000000000b1
  new_home "$PARENT" 00000000-0000-4000-8000-0000000000a1
  new_home "$MATE" "$MATE_SID"
  heartbeat "$PARENT" "$(new_pane)" 00000000-0000-4000-8000-0000000000a1 "$BASE" owner
  META_PANE=$(new_pane)
  printf -- '- ghost-mate - test mate (home: %s)\n' "$MATE" > "$PARENT/data/secondmates.md"
  printf 'kind=secondmate\nbackend=tmux\nwindow=%s\nhome=%s\n' "$META_PANE" "$MATE" > "$PARENT/state/ghost-mate.meta"
}

test_lock_session_heartbeat_updates_the_record() {
  local home="$TMP_ROOT/owner" sid=00000000-0000-4000-8000-0000000000c1 pane
  new_home "$home" "$sid"
  pane=$(new_pane)
  heartbeat "$home" "$pane" "$sid" "$LOCK_AT" owner
  scan "$home" 10 >/dev/null
  assert_equals "$sid $((BASE + 10)) watchdog" "$(field "$home" session) $(field "$home" checked_at) $(field "$home" source)" \
    "a heartbeat naming the lock session, written at the lock write, updates the record"
  assert_equals "tmux $pane" "$(terminal "$home")" "the owner's heartbeat proves its terminal"
  pass "a lock-session heartbeat no older than the lock write updates the captain record"
}

test_heartbeat_older_than_the_lock_write_proves_no_terminal() {
  local home="$TMP_ROOT/older" sid=00000000-0000-4000-8000-0000000000c2
  new_home "$home" "$sid"
  heartbeat "$home" "$(new_pane)" "$sid" "$((LOCK_AT - 1))" owner
  scan "$home" 10 >/dev/null
  assert_equals "$sid $((BASE + 10))" "$(field "$home" session) $(field "$home" checked_at)" \
    "the record still follows the lock session"
  assert_equals "" "$(field "$home" backend)$(field "$home" target)" \
    "a heartbeat older than the lock write proves no terminal"
  pass "a lock-session heartbeat older than the lock write does not update the recorded terminal"
}

test_daemon_heartbeat_updates_the_record_but_not_the_terminal() {
  local home="$TMP_ROOT/daemon" sid=00000000-0000-4000-8000-0000000000d1 pane other
  new_home "$home" "$sid"
  pane=$(new_pane)
  heartbeat "$home" "$pane" "$sid" "$BASE" owner
  scan "$home" 10 >/dev/null
  assert_equals "tmux $pane" "$(terminal "$home")" "the owner's heartbeat proves its terminal first"
  other=$(new_pane)
  heartbeat "$home" "$other" "$sid" "$((BASE + 15))" daemon
  # The divergence this case depends on: the daemon's heartbeat meets every
  # proof condition but the writer.
  jq -e --arg s "$sid" --argjson at "$LOCK_AT" \
    '.primary.session.trusted_id == $s and .generated_epoch >= $at and .primary.writer.anchor_pid.unknown == true' \
    "$home/state/heartbeat.json" >/dev/null || fail "the daemon heartbeat should name the lock session after the lock write"
  scan "$home" 20 >/dev/null
  assert_equals "$sid $((BASE + 20))" "$(field "$home" session) $(field "$home" checked_at)" \
    "a daemon-written heartbeat naming the lock session updates the record"
  assert_equals "tmux $pane" "$(terminal "$home")" "a daemon-written heartbeat never changes the recorded terminal"
  pass "a daemon-written lock-session heartbeat updates the record and leaves the terminal unchanged"
}

test_foreign_writer_heartbeat_never_changes_the_terminal() {
  local home="$TMP_ROOT/foreign" sid=00000000-0000-4000-8000-0000000000d2 pane other
  new_home "$home" "$sid"
  pane=$(new_pane)
  heartbeat "$home" "$pane" "$sid" "$BASE" owner
  scan "$home" 10 >/dev/null
  assert_equals "tmux $pane" "$(terminal "$home")" "the owner's heartbeat proves its terminal first"
  other=$(new_pane)
  heartbeat "$home" "$other" "$sid" "$((BASE + 15))" foreign
  # The divergence this case depends on: the writer is known and live, but
  # neither its pid nor its session is the lock holder's.
  jq -e --arg s "$sid" --argjson lp "$(cat "$home/lockpid")" \
    '.primary.session.trusted_id == $s and (.primary.writer.anchor_pid | type) == "number"
      and .primary.writer.anchor_pid != $lp and .primary.writer.session_id != $s' \
    "$home/state/heartbeat.json" >/dev/null || fail "the foreign heartbeat should name a known writer that is not the owner"
  scan "$home" 20 >/dev/null
  assert_equals "$sid $((BASE + 20))" "$(field "$home" session) $(field "$home" checked_at)" \
    "a foreign-written heartbeat naming the lock session updates the record"
  assert_equals "tmux $pane" "$(terminal "$home")" "a known writer that is not the owner never changes the recorded terminal"
  pass "a lock-session heartbeat from a known non-owner writer leaves the terminal unchanged"
}

test_current_session_child_heartbeat_names_a_new_pane() {
  local new moved out
  make_pair "$TMP_ROOT/child-new"
  heartbeat "$MATE" "$(new_pane)" 00000000-0000-4000-8000-0000000000b0 "$BASE" daemon
  scan "$PARENT" 10 >/dev/null
  assert_equals "tmux $META_PANE" "$(terminal "$MATE")" "before the move the record holds the parent's endpoint"
  moved=$(field "$MATE" moved_at)
  new=$(new_pane)
  heartbeat "$MATE" "$new" "$MATE_SID" "$((BASE + 15))" owner
  out=$(scan "$PARENT" 20)
  assert_equals "tmux:$new" "$(endpoint_of "$out" "$MATE")" "the pass reads the new pane"
  assert_equals "tmux $new" "$(terminal "$MATE")" "a current-session child heartbeat naming a new pane updates the record"
  assert_not_equals "$moved" "$(field "$MATE" moved_at)" "the new pane is a move"
  assert_equals "$((BASE + 20))" "$(field "$MATE" moved_at)" "the move is stamped at the pass"
  pass "a current-session child heartbeat naming a new pane updates the captain record"
}

test_prior_session_child_heartbeat_yields_no_mismatch() {
  local old out
  make_pair "$TMP_ROOT/child-prior"
  old=$(new_pane)
  # Fresh, but it names a session the mate's lock does not hold.
  heartbeat "$MATE" "$old" 00000000-0000-4000-8000-0000000000b0 "$((BASE + 5))" daemon
  out=$(scan "$PARENT" 10)
  assert_equals "tmux:$META_PANE" "$(endpoint_of "$out" "$MATE")" "a prior-session child heartbeat is not compared"
  assert_equals "tmux $META_PANE" "$(terminal "$MATE")" "the record names the parent's endpoint, not the prior session's pane"
  assert_not_contains "$out" "tmux:$old" "the prior session's pane is never read"
  pass "a child heartbeat from a prior session yields no endpoint mismatch"
}

test_parent_record_wins_during_a_mismatch() {
  local stale out
  make_pair "$TMP_ROOT/child-mismatch"
  stale=$(new_pane)
  heartbeat "$MATE" "$stale" "$MATE_SID" "$((BASE + 5))" owner
  scan "$PARENT" 10 >/dev/null
  assert_equals "tmux $stale" "$(terminal "$MATE")" "the current session's own heartbeat first proves its pane"
  # The child's heartbeat now names no session the lock holds: a mismatch.
  heartbeat "$MATE" "$stale" "" "$((BASE + 15))" daemon
  out=$(scan "$PARENT" 20)
  assert_equals "tmux:$META_PANE" "$(endpoint_of "$out" "$MATE")" "during a mismatch the pass reads the parent's endpoint"
  assert_equals "tmux $META_PANE" "$(terminal "$MATE")" "during a mismatch the parent record wins"
  pass "during a mismatch the parent record wins"
}

fm_test_run \
  test_lock_session_heartbeat_updates_the_record \
  test_heartbeat_older_than_the_lock_write_proves_no_terminal \
  test_daemon_heartbeat_updates_the_record_but_not_the_terminal \
  test_foreign_writer_heartbeat_never_changes_the_terminal \
  test_current_session_child_heartbeat_names_a_new_pane \
  test_prior_session_child_heartbeat_yields_no_mismatch \
  test_parent_record_wins_during_a_mismatch
