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

add_record() {  # <home> <seq> [aged]
  local rec
  rec="$(inbox_of "$1")/$2.msg"
  printf 'schema=fm-task-inbox.v1\nat=x\n--\nSECRET-BODY routed ask\n' > "$rec"
  [ "${3:-aged}" != aged ] || touch -t 202001010000 "$rec"
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
  expect_allow "a fourth deny for the same record"
  mv "$(inbox_of "$home")/001.msg" "$(inbox_of "$home")/handled/"
  hook_call "$home" "$home" self FM_SECONDMATE_INBOX_GUARD_REDENY=0
  expect_deny "the next record gets its own denies"
  grep -q '002.msg' "$ERR" || fail "the next record was not named"
  printf '002.msg\n' > "$(inbox_of "$home")/.escalated"
  hook_call "$home" "$home" self FM_SECONDMATE_INBOX_GUARD_REDENY=0
  expect_allow "a record the watcher already escalated"
  pass "inbox guard: a waiting record is denied with names only, at most 3 times and once per window, and stops at escalation"
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
  young=$(printf '%s' "$PAYLOAD" | sed 's/,"turn_id":"u1"//')
  PAYLOAD=$young hook_call "$home" "$home" self
  expect_allow "a payload that is not Codex-shaped"
  pass "inbox guard: primaries, crewmates, nested or foreign sessions, stale bindings, young records and other payloads are allowed"
}

test_guard_denies_a_waiting_record_then_lets_the_drain_run
test_guard_allows_everything_it_does_not_own
