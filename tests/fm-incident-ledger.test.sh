#!/usr/bin/env bash
# tests/fm-incident-ledger.test.sh - the incident ledger appends one row per
# transition, keyed by home, subject, signal and state, and never rewrites a
# row; the latest row of a key and an episode's rows are read from the ledger
# alone; and concurrent appenders under the ledger lock lose no row and get
# unique ids. fm_now is the shared fixed-clock seam.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-incident-ledger-lib.sh"
CLI="$ROOT/bin/fm-incident-ledger.sh"
TMP_ROOT=$(fm_test_tmproot fm-incident-ledger-tests)
T0=1800000000

# lib <now> <function> [args...]: call one library function under a fixed clock.
lib() {
  local now=$1
  shift
  FM_TEST_SEAM=1 FM_NOW="$now" bash -c '. "$0"; "$@"' "$LIB" "$@"
}

# append <state> <now> <home> <subject> <signal> <state> <class> <episode> <cause> <reserved> <action>:
# take the ledger lock, append one row, release it, and print the new id.
append() {
  local state=$1 now=$2
  shift 2
  FM_TEST_SEAM=1 FM_NOW="$now" bash -c '
    . "$0"
    s=$1
    shift
    fm_incident_ledger_lock "$s" || exit 1
    rc=0
    fm_incident_ledger_append_locked "$s" "$@" || rc=$?
    fm_incident_ledger_unlock "$s"
    exit "$rc"
  ' "$LIB" "$state" "$@"
}

cli() {  # <state> args...
  local state=$1
  shift
  env -u FM_HOME FM_STATE_OVERRIDE="$state" bash "$CLI" "$@"
}

new_state() {  # <name>: a fresh state directory
  mkdir -p "$TMP_ROOT/$1/state"
  printf '%s\n' "$TMP_ROOT/$1/state"
}

tab=$(printf '\t')

test_append_writes_one_row_per_transition() {
  local s id1 id2 ledger row
  s=$(new_state append)
  ledger=$(lib "$T0" fm_incident_ledger_path "$s")
  assert_equals "$s/incident-ledger.tsv" "$ledger" "the ledger path"
  id1=$(append "$s" "$T0" /h1 feat-a dead open routine e1 '' '' escalate) || fail "first append failed"
  id2=$(append "$s" $((T0 + 60)) /h1 feat-a dead closed routine e1 'k1' 'r' closure) || fail "second append failed"
  assert_equals t1 "$id1" "the first transition id"
  assert_equals t2 "$id2" "the second transition id"
  row=$(sed -n 1p "$ledger")
  assert_equals "t1${tab}$T0${tab}/h1${tab}feat-a${tab}dead${tab}open${tab}routine${tab}e1${tab}-${tab}-${tab}escalate" "$row" \
    "the first row's columns, with empty cause and reserved as -"
  row=$(sed -n 2p "$ledger")
  assert_equals "t2${tab}$((T0 + 60))${tab}/h1${tab}feat-a${tab}dead${tab}closed${tab}routine${tab}e1${tab}k1${tab}r${tab}closure" "$row" \
    "the second row's columns"
  assert_equals 2 "$(wc -l < "$ledger" | tr -d ' ')" "one row per transition"
  pass "append writes one row per transition with id, epoch and every column"
}

test_append_never_rewrites_a_row() {
  local s ledger before
  s=$(new_state rewrite)
  ledger="$s/incident-ledger.tsv"
  append "$s" "$T0" /h1 feat-a dead open routine e1 '' '' escalate > /dev/null || fail "append failed"
  append "$s" "$T0" /h1 feat-a dead open routine e1 '' '' hold > /dev/null || fail "repeat append failed"
  before="$TMP_ROOT/rewrite/before.tsv"
  cp "$ledger" "$before"
  append "$s" $((T0 + 5)) /h1 feat-a dead closed routine e1 '' '' closure > /dev/null || fail "third append failed"
  [ "$(head -c "$(wc -c < "$before" | tr -d ' ')" "$ledger" | cksum)" = "$(cksum < "$before")" ] \
    || fail "an append changed an earlier row"
  assert_equals 3 "$(wc -l < "$ledger" | tr -d ' ')" "a repeated key appends a new row"
  assert_equals t3 "$(tail -1 "$ledger" | cut -f1)" "ids grow across a repeated key"
  pass "appends never rewrite an earlier row, and a repeated key gets a new row"
}

test_append_refuses_malformed_input() {
  local s rc
  s=$(new_state refuse)
  append "$s" "$T0" /h1 feat-a dead open routine e1 '' '' shout > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "an unknown action is refused"
  append "$s" "$T0" '' feat-a dead open routine e1 '' '' record > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "an empty home is refused"
  append "$s" "$T0" /h1 feat-a dead open routine '' '' '' record > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "an empty episode is refused"
  [ ! -s "$s/incident-ledger.tsv" ] || fail "a refused append wrote a row"
  for action in escalate delta closure hold record; do
    append "$s" "$T0" /h1 feat-a dead open routine e1 '' '' "$action" > /dev/null || fail "action $action was refused"
  done
  pass "append refuses an unknown action or an empty key field and writes nothing"
}

test_fields_are_tab_and_newline_free() {
  local s row
  s=$(new_state sanitize)
  append "$s" "$T0" "/h${tab}1" "feat
a" dead open "rou${tab}tine" e1 "c${tab}x" '' record > /dev/null || fail "append with separators failed"
  assert_equals 1 "$(wc -l < "$s/incident-ledger.tsv" | tr -d ' ')" "a newline in a value does not split the row"
  row=$(cat "$s/incident-ledger.tsv")
  assert_equals 11 "$(printf '%s\n' "$row" | awk -F '\t' '{ print NF }')" "a tab in a value does not add a column"
  assert_equals "/h 1" "$(printf '%s\n' "$row" | cut -f3)" "a tab in the home becomes a space"
  assert_equals "feat a" "$(printf '%s\n' "$row" | cut -f4)" "a newline in the subject becomes a space"
  row=$(lib "$T0" fm_incident_ledger_latest "$s" "/h${tab}1" "feat
a" dead)
  assert_equals t1 "$(printf '%s\n' "$row" | cut -f1)" "a lookup with the same raw values finds the sanitized row"
  pass "field values are made tab- and newline-free, and lookups match them"
}

test_latest_reads_from_the_ledger_alone() {
  local s out
  s=$(new_state latest)
  append "$s" "$T0" /h1 feat-a dead open routine e1 '' '' escalate > /dev/null
  append "$s" $((T0 + 1)) /h1 feat-b dead open routine e2 '' '' escalate > /dev/null
  append "$s" $((T0 + 2)) /h1 feat-a dead closed routine e1 '' '' closure > /dev/null
  append "$s" $((T0 + 3)) /h2 feat-a dead open quota e3 '' '' escalate > /dev/null
  append "$s" $((T0 + 4)) /h1 feat-a stale open routine e4 '' '' escalate > /dev/null
  out=$(lib "$T0" fm_incident_ledger_latest "$s" /h1 feat-a dead)
  assert_equals t3 "$(printf '%s\n' "$out" | cut -f1)" "latest of home, subject and signal in any state"
  out=$(lib "$T0" fm_incident_ledger_latest_key "$s" /h1 feat-a dead open)
  assert_equals t1 "$(printf '%s\n' "$out" | cut -f1)" "latest of the exact key"
  out=$(lib "$T0" fm_incident_ledger_latest_key "$s" /h1 feat-a dead held)
  assert_equals "" "$out" "latest of an unknown key prints nothing"
  out=$(lib "$T0" fm_incident_ledger_latest "$s" /h3 feat-a dead)
  assert_equals "" "$out" "latest of an unknown home prints nothing"
  out=$(lib "$T0" fm_incident_ledger_latest "$TMP_ROOT/latest/absent" /h1 feat-a dead)
  assert_equals "" "$out" "an absent ledger reads as empty"
  out=$(lib "$T0" fm_incident_key /h1 feat-a dead open)
  assert_equals "/h1|feat-a|dead|open" "$out" "the incident key"
  append "$s" $((T0 + 5)) /h1 feat-a dead open routine e5 '' '' escalate > /dev/null
  out=$(lib "$T0" fm_incident_ledger_episode_rows "$s" /h1 feat-a dead e1 | cut -f1 | tr '\n' ' ')
  assert_equals "t1 t3 " "$out" "an episode's rows in order"
  out=$(lib "$T0" fm_incident_ledger_episode_rows "$s" /h1 feat-a dead e9)
  assert_equals "" "$out" "an unknown episode prints nothing"
  pass "latest, latest-of-key and episode rows read from the ledger alone"
}

test_every_reader_skips_a_malformed_row() {
  local s ledger out
  s=$(new_state malformed)
  ledger="$s/incident-ledger.tsv"
  append "$s" "$T0" /h1 feat-a dead open routine e1 '' '' escalate > /dev/null
  {
    printf 't9\tsoon\t/h1\tfeat-a\tdead\topen\troutine\te1\t-\t-\tescalate\n'
    printf 'x2\t%s\t/h1\tfeat-a\tdead\topen\troutine\te1\t-\t-\tescalate\n' "$T0"
    printf 't8\t%s\t/h1\tfeat-a\tdead\topen\n' "$T0"
  } >> "$ledger"
  out=$(lib "$T0" fm_incident_ledger_latest "$s" /h1 feat-a dead | cut -f1)
  assert_equals t1 "$out" "latest skips a row with a bad epoch, a bad id or too few columns"
  out=$(lib "$T0" fm_incident_ledger_latest_key "$s" /h1 feat-a dead open | cut -f1)
  assert_equals t1 "$out" "latest of the key skips the malformed rows"
  out=$(lib "$T0" fm_incident_ledger_episode_rows "$s" /h1 feat-a dead e1 | cut -f1 | tr '\n' ' ')
  assert_equals "t1 " "$out" "episode rows skip the malformed rows"
  out=$(cli "$s" rows | cut -f1 | tr '\n' ' ')
  assert_equals "t1 " "$out" "rows skips the malformed rows"
  pass "every reader skips a row without eleven columns, a t<N> id and a decimal epoch"
}

test_concurrent_appends_lose_no_row() {
  local s i ids pids=() n
  s=$(new_state concurrent)
  for i in $(seq 1 20); do
    append "$s" "$T0" /h1 "feat-$i" dead open routine "e$i" '' '' escalate > "$TMP_ROOT/concurrent/id.$i" &
    pids+=("$!")
  done
  for i in "${pids[@]}"; do
    wait "$i" || fail "a concurrent appender failed"
  done
  assert_equals 20 "$(wc -l < "$s/incident-ledger.tsv" | tr -d ' ')" "twenty concurrent appends wrote twenty rows"
  n=$(cut -f1 "$s/incident-ledger.tsv" | sort -u | wc -l | tr -d ' ')
  assert_equals 20 "$n" "the twenty ids are unique"
  ids=$(cat "$TMP_ROOT"/concurrent/id.* | sort -t t -k2,2n | tr '\n' ' ')
  assert_equals "$(seq 1 20 | sed 's/^/t/' | tr '\n' ' ')" "$ids" "the appenders were handed t1 to t20"
  n=$(cut -f4 "$s/incident-ledger.tsv" | sort -u | wc -l | tr -d ' ')
  assert_equals 20 "$n" "every appender's row is present"
  [ ! -e "$s/.incident-ledger.lock" ] || fail "the ledger lock was left behind"
  pass "twenty concurrent appenders under the ledger lock lose no row and get unique ids"
}

test_lock_excludes_a_second_holder() {
  local s holder
  s=$(new_state lock)
  bash -c '. "$0"; fm_incident_ledger_lock "$1" || exit 1; : > "$1/held"; while [ -e "$1/hold" ]; do sleep 0.05; done; fm_incident_ledger_unlock "$1"' \
    "$LIB" "$s" &
  holder=$!
  : > "$s/hold"
  for _ in $(seq 1 100); do [ -e "$s/held" ] && break; sleep 0.05; done
  [ -e "$s/held" ] || fail "the first holder never took the lock"
  [ -e "$s/.incident-ledger.lock" ] || fail "the lock is not <state>/.incident-ledger.lock"
  bash -c '. "$0"; fm_lock_try_acquire "$1/.incident-ledger.lock"' "$LIB" "$s" \
    && fail "a second holder took the ledger lock while it was held"
  rm -f "$s/hold"
  wait "$holder" || fail "the first holder failed"
  [ ! -e "$s/.incident-ledger.lock" ] || fail "unlock left the lock behind"
  pass "the ledger lock excludes a second holder until it is released"
}

test_command_contract() {
  local s out rc
  s=$(new_state cli)
  append "$s" "$T0" /h1 feat-a dead open routine e1 '' '' escalate > /dev/null
  append "$s" $((T0 + 10)) /h1 feat-a dead closed routine e1 '' '' closure > /dev/null
  append "$s" $((T0 + 20)) /h1 feat-b dead open routine e2 '' '' escalate > /dev/null
  out=$(cli "$s" latest --home /h1 --subject feat-a --signal dead | cut -f1)
  assert_equals t2 "$out" "latest prints the latest row in any state"
  out=$(cli "$s" latest --home /h1 --subject feat-a --signal dead --state open | cut -f1)
  assert_equals t1 "$out" "latest --state prints the latest row of that key"
  out=$(cli "$s" latest --home /h1 --subject feat-z --signal dead); rc=$?
  assert_equals "0:" "$rc:$out" "latest of an unknown key prints nothing and succeeds"
  out=$(cli "$s" rows | cut -f1 | tr '\n' ' ')
  assert_equals "t1 t2 t3 " "$out" "rows prints every row"
  out=$(cli "$s" rows --since $((T0 + 10)) | cut -f1 | tr '\n' ' ')
  assert_equals "t2 t3 " "$out" "rows --since keeps rows at or after the epoch"
  cli "$s" latest --home /h1 --subject feat-a > /dev/null 2>&1; rc=$?
  assert_equals 1 "$rc" "latest without --signal is refused"
  cli "$s" latest --home /h1 --home /h2 --subject feat-a --signal dead > /dev/null 2>&1; rc=$?
  assert_equals 1 "$rc" "a repeated flag is refused"
  cli "$s" rows --since soon > /dev/null 2>&1; rc=$?
  assert_equals 1 "$rc" "a non-numeric --since is refused"
  cli "$s" rewrite > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "an unknown subcommand exits 2"
  cli "$s" --help > /dev/null 2>&1; rc=$?
  assert_equals 0 "$rc" "--help exits 0"
  pass "the latest and rows verbs and their refusals"
}

fm_test_run \
  test_append_writes_one_row_per_transition \
  test_append_never_rewrites_a_row \
  test_append_refuses_malformed_input \
  test_fields_are_tab_and_newline_free \
  test_latest_reads_from_the_ledger_alone \
  test_every_reader_skips_a_malformed_row \
  test_concurrent_appends_lose_no_row \
  test_lock_excludes_a_second_holder \
  test_command_contract
