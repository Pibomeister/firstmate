#!/usr/bin/env bash
# shellcheck disable=SC2016
# Behavior tests for the Codex secondmate steering-inbox guard
# (bin/fm-secondmate-inbox-guard.sh), driven through the real Bash PreToolUse
# transport (bin/fm-arm-pretool-check.sh) exactly as .codex/hooks.json calls it:
# a Codex-shaped payload on stdin, the hook's working directory as the home, and
# a real process tree in which a fake `codex` (bash under that name) holds or
# lacks the home's session lock.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-arm-pretool-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-secondmate-inbox-guard)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
ln -s /bin/bash "$FAKEBIN/codex"
PAYLOAD='{"cwd":"x","hook_event_name":"PreToolUse","model":"m","permission_mode":"bypassPermissions","session_id":"s1","tool_input":{"command":"ls"},"tool_name":"Bash","tool_use_id":"t1","transcript_path":"p","turn_id":"u1"}'

make_secondmate() {  # <name> -> echoes the secondmate home
  local home="$TMP_ROOT/$1" parent="$TMP_ROOT/$1-parent"
  mkdir -p "$home/state" "$parent/state/sm1.inbox/handled"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$home/.fm-secondmate-parent"
  printf 'sm1\n' > "$home/.fm-secondmate-home"
  printf '%s\n' "$home"
}

inbox_of() { printf '%s-parent/state/sm1.inbox' "$1"; }

add_record() {  # <home> <seq> [aged|young|fire-and-forget]
  local rec
  rec="$(inbox_of "$1")/$2.msg"
  if [ "${3:-aged}" = fire-and-forget ]; then
    printf 'schema=fm-task-inbox.v1\nat=x\ndelivery=fire-and-forget\n--\nSECRET-BODY event\n' > "$rec"
  else
    printf 'schema=fm-task-inbox.v1\nat=x\n--\nSECRET-BODY routed ask\n' > "$rec"
  fi
  [ "${3:-aged}" = young ] || touch -t 202001010000 "$rec"
}

# Run one hook call from <cwd> inside a fake codex session process. With
# <owner> = self that process holds <home>'s lock; nested runs the hook from a
# second codex below the lock holder; other leaves the lock on a stranger.
hook_call() {  # <home> <cwd> <owner> [env...]
  local home=$1 cwd=$2 owner=$3
  shift 3
  OUT="$TMP_ROOT/out"; ERR="$TMP_ROOT/err"; STATUS=0
  env -u FM_TASK_INBOX -u FM_HOME FM_HOOK_PAYLOAD="$PAYLOAD" FM_HOOK_CHECK="$CHECK" FM_HOOK_HOME="$home" FM_HOOK_CWD="$cwd" \
    FM_HOOK_OWNER="$owner" FM_FAKEBIN="$FAKEBIN" "$@" \
    "$FAKEBIN/codex" -c '
      case "$FM_HOOK_OWNER" in
        self) printf "%s\n" "$$" > "$FM_HOOK_HOME/state/.lock" ;;
        other) sleep 30 & printf "%s\n" "$!" > "$FM_HOOK_HOME/state/.lock" ;;
      esac
      cd "$FM_HOOK_CWD" || exit 9
      if [ "$FM_HOOK_OWNER" = nested ]; then
        printf "%s\n" "$$" > "$FM_HOOK_HOME/state/.lock"
        "$FM_FAKEBIN/codex" -c "printf %s \"\$FM_HOOK_PAYLOAD\" | bash \"\$FM_HOOK_CHECK\""
      else
        printf %s "$FM_HOOK_PAYLOAD" | bash "$FM_HOOK_CHECK"
      fi
    ' > "$OUT" 2> "$ERR" || STATUS=$?
}

expect_deny() {  # <message>
  [ "$STATUS" = 2 ] || fail "$1: expected a deny (exit 2), got $STATUS: $(cat "$OUT" "$ERR")"
  grep -q '"permissionDecision":"deny"' "$ERR" || fail "$1: no Codex deny object: $(cat "$ERR")"
}

expect_allow() {  # <message>
  [ "$STATUS" = 0 ] && [ ! -s "$OUT" ] && [ ! -s "$ERR" ] \
    || fail "$1: expected an allow, got $STATUS: $(cat "$OUT" "$ERR")"
}

test_guard_denies_a_waiting_record_then_lets_the_drain_run() {
  local home
  home=$(make_secondmate deny)
  add_record "$home" 001
  add_record "$home" 002
  hook_call "$home" "$home" self
  expect_deny "an aged waiting record"
  grep -q '001.msg 002.msg' "$ERR" || fail "the deny does not name the waiting records: $(cat "$ERR")"
  ! grep -q 'SECRET-BODY' "$OUT" "$ERR" || fail "the deny exposed a record body"
  hook_call "$home" "$home" self
  expect_allow "a call inside the re-deny window"
  hook_call "$home" "$home" self FM_SECONDMATE_INBOX_GUARD_REDENY=0
  expect_deny "a record still waiting after the window"
  hook_call "$home" "$home" self FM_SECONDMATE_INBOX_GUARD_REDENY=0
  expect_deny "the third deny"
  hook_call "$home" "$home" self FM_SECONDMATE_INBOX_GUARD_REDENY=0
  expect_deny "the next waiting record gets its own denies once the oldest has spent its three"
  hook_call "$home" "$home" self FM_SECONDMATE_INBOX_GUARD_REDENY=0
  expect_deny "the next record's second deny"
  hook_call "$home" "$home" self FM_SECONDMATE_INBOX_GUARD_REDENY=0
  expect_deny "the next record's third deny"
  hook_call "$home" "$home" self FM_SECONDMATE_INBOX_GUARD_REDENY=0
  expect_allow "a seventh deny after both waiting records spent their three"
  pass "inbox guard: each waiting record is denied with names only, at most 3 times, and the window spaces every deny"
}

# A stuck oldest record that the watcher escalated after its denies were spent
# never switches the drain off for a later record.
test_guard_moves_past_a_stuck_oldest_record() {
  local home
  home=$(make_secondmate stuck-oldest)
  add_record "$home" 005
  hook_call "$home" "$home" self FM_SECONDMATE_INBOX_GUARD_REDENY=0
  hook_call "$home" "$home" self FM_SECONDMATE_INBOX_GUARD_REDENY=0
  hook_call "$home" "$home" self FM_SECONDMATE_INBOX_GUARD_REDENY=0
  expect_deny "the oldest record's third deny"
  hook_call "$home" "$home" self FM_SECONDMATE_INBOX_GUARD_REDENY=0
  expect_allow "a fourth deny for a lone record"
  printf '005.msg\n' > "$(inbox_of "$home")/.escalated"
  hook_call "$home" "$home" self FM_SECONDMATE_INBOX_GUARD_REDENY=0
  expect_allow "a lone record the watcher already escalated"
  add_record "$home" 006
  hook_call "$home" "$home" self FM_SECONDMATE_INBOX_GUARD_REDENY=0
  expect_deny "an aged record behind an escalated, deny-spent oldest"
  grep -q '006.msg' "$ERR" || fail "the deny does not name the later record: $(cat "$ERR")"
  pass "inbox guard: an escalated oldest record with its denies spent does not stop the drain for a later record"
}

# However many escalated records wait ahead of it, a later record still gets
# its deny: 200 escalated records never hide an aged 201st.
test_guard_skips_a_record_the_watcher_escalated_before_any_deny() {
  local home
  home=$(make_secondmate escalated-undenied)
  # The watcher escalates a due record when the endpoint is unavailable, which
  # can happen before the guard has denied it at all.
  add_record "$home" 005
  printf '005.msg\n' > "$(inbox_of "$home")/.escalated"
  hook_call "$home" "$home" self FM_SECONDMATE_INBOX_GUARD_REDENY=0
  expect_allow "a lone record the watcher escalated before any deny"
  add_record "$home" 006
  hook_call "$home" "$home" self FM_SECONDMATE_INBOX_GUARD_REDENY=0
  expect_deny "an aged record behind one escalated with no denies"
  grep -q '006.msg' "$ERR" && ! grep -q '005.msg' "$ERR" \
    || fail "the deny does not name only the later record: $(cat "$ERR")"
  [ "$(cut -f1,2 "$home/state/.inbox-guard")" = "$(printf '006.msg\t1')" ] \
    || fail "the guard state does not record one deny for 006.msg: $(cat "$home/state/.inbox-guard")"
  pass "inbox guard: a record the watcher escalated before any deny is skipped on its own, not only once its denies are spent"
}

test_guard_scans_past_any_number_of_spent_records() {
  local home i
  home=$(make_secondmate spent-prefix)
  i=1
  while [ "$i" -le 200 ]; do
    add_record "$home" "$(printf '%03d' "$i")"
    printf '%03d.msg\n' "$i" >> "$(inbox_of "$home")/.escalated"
    i=$((i + 1))
  done
  add_record "$home" 201
  hook_call "$home" "$home" self
  expect_deny "an aged 201st record behind 200 escalated ones"
  grep -q '201.msg' "$ERR" || fail "the deny does not name the 201st record: $(cat "$ERR")"
  pass "inbox guard: escalated records ahead of a later record never hide it, however many there are"
}

# The oldest record is chosen by sequence number, so 999 precedes 1000 even
# though it sorts after it as text.
test_guard_orders_records_numerically() {
  local home
  home=$(make_secondmate numeric)
  add_record "$home" 999
  add_record "$home" 1000 young
  hook_call "$home" "$home" self
  expect_deny "an aged 999 ahead of a young 1000"
  grep -q '999.msg 1000.msg' "$ERR" || fail "the deny does not list 999 before 1000: $(cat "$ERR")"
  pass "inbox guard: the oldest waiting record is the lowest sequence number, not the first name as text"
}

# A GNU-shaped stat first on PATH (as under coreutils, or a gnubin PATH in the
# hook's login shell) still yields the record's age: `stat -f` is GNU's
# filesystem report, so a BSD-first read would never deny there.
test_guard_age_read_survives_gnu_stat() {
  local home gnu="$TMP_ROOT/gnu-stat-bin" real
  real=$(command -v stat)
  mkdir -p "$gnu"
  cat > "$gnu/stat" <<SH
#!/usr/bin/env bash
case "\$1" in
  -f) printf '  File: "%s"\n    ID: 0 Namelen: 255 Type: apfs\n' "\${3:-}"; exit 1 ;;
  -c) [ "\$2" = %Y ] || exit 1; if [ "\$(uname)" = Darwin ]; then exec /usr/bin/stat -f %m "\$3"; fi; exec "$real" -c %Y "\$3" ;;
esac
exit 1
SH
  chmod +x "$gnu/stat"
  home=$(make_secondmate gnu-stat)
  add_record "$home" 001
  hook_call "$home" "$home" self PATH="$gnu:$PATH"
  expect_deny "an aged waiting record read through a GNU-shaped stat"
  pass "inbox guard: the record's age is read portably, so a GNU stat first on PATH still denies"
}

# A fire-and-forget record never enters the watcher's ladder, so the guard
# does not deny for it either.
test_guard_skips_fire_and_forget_records() {
  local home
  home=$(make_secondmate fire-and-forget)
  add_record "$home" 001 fire-and-forget
  hook_call "$home" "$home" self
  expect_allow "an inbox holding only an aged fire-and-forget record"
  add_record "$home" 002
  hook_call "$home" "$home" self
  expect_deny "an aged ordinary record behind a fire-and-forget one"
  pass "inbox guard: fire-and-forget records are skipped exactly as the watcher's ladder skips them"
}

# FM_PRETOOL_PAYLOAD_KEYS_FILE, the live guard's capture switch, records only
# the payload's top-level key names, one sorted JSON array per call, and never
# a value; unset, nothing is written.
test_hook_records_payload_key_names_only() {
  local home keys
  home=$(make_secondmate keys)
  keys="$TMP_ROOT/payload-keys"
  PAYLOAD=$(printf '%s' "$PAYLOAD" | sed 's/"command":"ls"/"command":"echo SECRETVALUE"/') \
    hook_call "$home" "$home" self FM_PRETOOL_PAYLOAD_KEYS_FILE="$keys"
  expect_allow "a capture call"
  [ "$(cat "$keys" 2>/dev/null)" = "$(printf '%s' "$PAYLOAD" | jq -c keys)" ] \
    || fail "the capture did not record exactly the top-level key names: $(cat "$keys" 2>/dev/null)"
  ! grep -q 'SECRETVALUE\|s1\|u1' "$keys" || fail "the capture recorded a payload value"
  rm -f "$keys"
  hook_call "$home" "$home" self
  [ ! -e "$keys" ] || fail "the hook wrote a capture without the switch"
  pass "pretool hook: the capture switch records top-level payload key names only"
}

test_guard_allows_everything_it_does_not_own() {
  local home young primary crew
  home=$(make_secondmate allow)
  hook_call "$home" "$home" self
  expect_allow "an empty inbox"
  add_record "$home" 001 young
  hook_call "$home" "$home" self
  expect_allow "a record younger than the grace"
  rm -f "$(inbox_of "$home")/001.msg"
  add_record "$home" 001
  hook_call "$home" "$home" nested
  expect_allow "a nested codex that inherited the secondmate's home"
  hook_call "$home" "$home" other
  expect_allow "a session that does not own the lock"
  hook_call "$home" "$home" self FM_TASK_INBOX="$TMP_ROOT/elsewhere.inbox"
  expect_allow "an inherited inbox binding naming another inbox"
  primary="$TMP_ROOT/primary"; mkdir -p "$primary/state"
  hook_call "$primary" "$primary" self FM_TASK_INBOX="$(inbox_of "$home")"
  expect_allow "a primary home"
  crew="$TMP_ROOT/crew-worktree"; mkdir -p "$crew"
  hook_call "$home" "$crew" self FM_HOME="$home" FM_TASK_INBOX="$(inbox_of "$home")"
  expect_allow "a crewmate worktree inheriting the secondmate's environment"
  # No live record of Codex's PreToolUse payload exists, so every other shape
  # must allow (docs/verification/runtime-backends.md).
  for young in 's/,"turn_id":"u1"//' 's/"session_id":"s1",//' 's/"tool_input":{"command":"ls"},//'; do
    PAYLOAD=$(printf '%s' "$PAYLOAD" | sed "$young") hook_call "$home" "$home" self
    expect_allow "a payload that is not Codex-shaped ($young)"
  done
  pass "inbox guard: primaries, crewmates, nested or foreign sessions, stale bindings, young records and other payloads are allowed"
}

test_guard_denies_a_waiting_record_then_lets_the_drain_run
test_guard_moves_past_a_stuck_oldest_record
test_guard_skips_a_record_the_watcher_escalated_before_any_deny
test_guard_scans_past_any_number_of_spent_records
test_guard_orders_records_numerically
test_guard_age_read_survives_gnu_stat
test_guard_skips_fire_and_forget_records
test_guard_allows_everything_it_does_not_own
test_hook_records_payload_key_names_only
