#!/usr/bin/env bash
# tests/fm-handoff-reconcile.test.sh - bin/fm-handoff-reconcile.sh ends the
# terminal of a late, refused handoff successor exactly once and only with
# proof, never ends the lock owner, its own terminal, the captain handle, a
# task endpoint or a handoff party, does nothing while a handoff is in
# progress, and reports what it left open.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECONCILE="$ROOT/bin/fm-handoff-reconcile.sh"
TMP_ROOT=$(fm_test_tmproot fm-handoff-reconcile)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
TAB=$(printf '\t')
NOW=$(date +%s)
N1=0123456789abcdef0123456789abcdef
N2=fedcba9876543210fedcba9876543210
N3=00112233445566778899aabbccddeeff

if ! command -v jq >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
  printf '1..0 # SKIP jq and node are needed for the fake Orca\n'
  exit 0
fi

# A fake Orca: a terminal exists while $FAKE_ORCA/<handle>.screen exists.
cat > "$FAKEBIN/orca" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FAKE_ORCA/calls"
if [ "${1:-} ${2:-}" = 'status --json' ]; then
  [ ! -e "$FAKE_ORCA/down" ] || exit 1
  printf '{"ok":true}\n'
  exit 0
fi
[ "${1:-}" = terminal ] || exit 91
action=${2:-}
handle=
shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --terminal) handle=$2; shift 2 ;;
    --limit) shift 2 ;;
    --json) shift ;;
    *) exit 92 ;;
  esac
done
[ ! -e "$FAKE_ORCA/down" ] || exit 1
case "$action" in
  read)
    if [ -f "$FAKE_ORCA/$handle.screen" ]; then
      jq -Rs '{ok: true, result: {terminal: {tail: split("\n")}}}' "$FAKE_ORCA/$handle.screen"
      exit 0
    fi
    printf '{"ok":false,"error":{"message":"terminal not found"}}\n'
    exit 1
    ;;
  close)
    printf '%s\n' "$handle" >> "$FAKE_ORCA/closed"
    [ -e "$FAKE_ORCA/$handle.sticky" ] || rm -f "$FAKE_ORCA/$handle.screen"
    printf '{"ok":true}\n'
    exit 0
    ;;
esac
exit 93
EOF
chmod +x "$FAKEBIN/orca"

HOME_DIR='' FAKE_ORCA=''
new_home() {  # <name>: a home whose lock owner sits in term_owner
  HOME_DIR="$TMP_ROOT/$1"
  FAKE_ORCA="$TMP_ROOT/$1-orca"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$FAKE_ORCA"
  printf '1001\n' > "$HOME_DIR/state/.lock"
  printf 'sess\nanchor_pid=1001\nbackend=orca\nterminal=term_owner\n' > "$HOME_DIR/state/.lock-session"
}

# reconcile [VAR=value ...] [-- args]: run with no terminal of its own.
reconcile() {
  env -u ORCA_TERMINAL_HANDLE -u TMUX_PANE -u FM_SUPERVISOR_TARGET -u HERDR_ENV -u HERDR_PANE_ID \
    -u REX_SESSION -u REX_BLOCK -u HC_TERMINAL_ID -u HC_TERMINAL_SOCKET \
    PATH="$FAKEBIN:$PATH" FAKE_ORCA="$FAKE_ORCA" FM_HOME="$HOME_DIR" "$@" bash "$RECONCILE" ${ARGS[@]+"${ARGS[@]}"}
}
apply() { ARGS=(--apply --report); reconcile "$@"; }
dry() { ARGS=(); reconcile; }

event() {  # <seconds ago> <event> <nonce> <handle> <reason>
  printf 'HANDOFF v1 ts=%s event=%s nonce=%s attempt=1 pid=0 handle=%s reason=%s\n' \
    "$((NOW - $1))" "$2" "$3" "$4" "$5" >> "$HOME_DIR/state/handoff-events.log"
}

# The nonce as a wrapped terminal shows it: split over two bordered lines.
screen() {  # <handle> <nonce>
  printf '| Firstmate handoff successor. nonce=%s |\n|   %s |\n| handoff_reject |\n' \
    "${2:0:20}" "${2:20}" > "$FAKE_ORCA/$1.screen"
}

outcomes() { cat "$HOME_DIR/state/handoff-reconcile.tsv" 2>/dev/null; }
outcome_of() { outcomes | awk -F '\t' -v h="$1" '$3 == h { print $4 " " $5 }'; }
closed() { cat "$FAKE_ORCA/closed" 2>/dev/null; }

test_retires_a_proven_late_successor_once() {
  local out
  new_home retire
  event 300 handoff_started "$N1" term_owner awaiting_ack
  event 100 handoff_failed "$N1" none deadline
  event 50 handoff_reject "$N1" term_late missing_claim
  screen term_late "$N1"
  out=$(dry) || fail "dry run failed"
  assert_contains "$out" "retire term_late" "the dry run names the terminal it would end"
  assert_equals "" "$(closed)" "a dry run closes nothing"
  assert_equals "" "$(outcomes)" "a dry run records nothing"
  out=$(apply) || fail "apply failed"
  assert_equals term_late "$(closed)" "the late successor terminal is closed"
  assert_equals "retired nonce_proven" "$(outcome_of term_late)" "the outcome is recorded"
  assert_contains "$out" "ended the late successor terminal term_late" "the supervisor is told"
  assert_present "$HOME_DIR/data/handoff-late/$N1.txt" "the last screen is saved first"
  assert_contains "$(cat "$HOME_DIR/data/handoff-late/$N1.txt")" "handoff_reject" "the saved screen is the terminal's"
  assert_equals 600 "$(stat -f '%Lp' "$HOME_DIR/data/handoff-late/$N1.txt" 2>/dev/null || stat -c '%a' "$HOME_DIR/data/handoff-late/$N1.txt")" \
    "the saved screen is owner-only"
  assert_equals "1001" "$(cat "$HOME_DIR/state/.lock")" "the session lock is untouched"
  out=$(apply) || fail "second apply failed"
  assert_equals "" "$out" "a handled terminal is not reported again"
  assert_equals term_late "$(closed)" "a handled terminal is not closed again"
  assert_equals 1 "$(outcomes | awk 'END { print NR }')" "one outcome row for one terminal"
  pass "a late refused successor is ended once, with its nonce proven on screen and the screen saved"
}

test_never_ends_a_protected_terminal() {
  local out
  new_home protected
  event 400 handoff_started "$N1" term_owner awaiting_ack
  event 300 handoff_reject "$N1" term_owner missing_claim
  event 290 handoff_reject "$N1" term_self stale_nonce
  event 280 handoff_reject "$N1" term_captain stale_nonce
  event 270 handoff_reject "$N1" term_task stale_nonce
  event 260 handoff_reject "$N1" term_window stale_nonce
  event 250 handoff_reject "$N1" term_party stale_nonce
  event 240 handoff_started "$N2" term_owner awaiting_ack
  event 230 handoff_ack "$N2" term_party lock_transferred
  printf 'backend=orca\ntarget=term_captain\nat=1\n' > "$HOME_DIR/state/captain-handle"
  printf 'kind=ship\nterminal=term_task\n' > "$HOME_DIR/state/t-1.meta"
  printf 'kind=scout\nwindow=term_window\n' > "$HOME_DIR/state/t-2.meta"
  for h in term_owner term_self term_captain term_task term_window term_party; do screen "$h" "$N1"; done
  out=$(apply FM_SUPERVISOR_TARGET=term_self) || fail "apply failed"
  assert_equals "" "$(closed)" "no protected terminal is closed"
  assert_equals "" "$out" "a kept terminal is not reported"
  assert_equals "kept lock_owner" "$(outcome_of term_owner)" "the lock owner's terminal is kept"
  assert_equals "kept own_terminal" "$(outcome_of term_self)" "the caller's own terminal is kept"
  assert_equals "kept captain_handle" "$(outcome_of term_captain)" "the captain handle is kept"
  assert_equals "kept task_endpoint" "$(outcome_of term_task)" "a task terminal is kept"
  assert_equals "kept task_endpoint" "$(outcome_of term_window)" "a task window is kept"
  assert_equals "kept handoff_party" "$(outcome_of term_party)" "a terminal that acknowledged a handoff is kept"
  pass "the lock owner, the caller, the captain handle, task endpoints and handoff parties are never ended"
}

test_does_nothing_while_a_handoff_is_in_progress() {
  local out
  new_home busy
  event 300 handoff_started "$N1" term_owner awaiting_ack
  event 50 handoff_reject "$N1" term_late stale_nonce
  screen term_late "$N1"
  printf '{"nonce":"%s"}\n' "$N2" > "$HOME_DIR/state/.handoff-pending"
  out=$(apply) || fail "apply during a claim failed"
  assert_equals "" "$(closed)$(outcomes)$out" "nothing happens while a claim is pending"
  rm -f "$HOME_DIR/state/.handoff-pending"
  mkdir "$HOME_DIR/state/.lock.acquire"
  out=$(apply) || fail "apply during a lock change failed"
  assert_equals "" "$(closed)$(outcomes)$out" "nothing happens while the lock is changing"
  rmdir "$HOME_DIR/state/.lock.acquire"
  apply >/dev/null || fail "apply after the handoff failed"
  assert_equals "retired nonce_proven" "$(outcome_of term_late)" "the terminal is ended once the handoff is over"
  pass "no terminal is touched while a handoff claim or a lock change is in progress"
}

test_unproven_and_foreign_terminals_are_left_and_reported_once() {
  local out
  new_home left
  event 300 handoff_started "$N1" term_owner awaiting_ack
  event 90 handoff_reject "$N1" %7 missing_claim
  event 80 handoff_reject "$N1" term_reused missing_claim
  event 70 handoff_reject "$N1" term_sticky missing_claim
  printf 'someone else works here now\n' > "$FAKE_ORCA/term_reused.screen"
  screen term_sticky "$N1"
  : > "$FAKE_ORCA/term_sticky.sticky"
  out=$(apply) || fail "apply failed"
  assert_equals "left backend_not_orca" "$(outcome_of %7)" "a terminal of another backend is left"
  assert_equals "left nonce_not_visible" "$(outcome_of term_reused)" "a terminal that no longer shows the nonce is left"
  assert_equals "left close_not_verified" "$(outcome_of term_sticky)" "a close that did not take is not called retired"
  assert_equals term_sticky "$(closed)" "only the proven terminal was sent a close"
  assert_contains "$out" "terminal %7 of a failed handoff attempt was left open (backend_not_orca)" "the foreign terminal is reported"
  assert_contains "$out" "terminal term_reused of a failed handoff attempt was left open (nonce_not_visible)" "the unproven terminal is reported"
  assert_contains "$out" "terminal term_sticky of a failed handoff attempt was left open (close_not_verified)" "the failed close is reported"
  out=$(apply) || fail "second apply failed"
  assert_equals "" "$out" "each left terminal is reported once"
  new_home noowner
  printf 'sess\nanchor_pid=1001\nbackend=unknown\nterminal=unknown\n' > "$HOME_DIR/state/.lock-session"
  event 300 handoff_started "$N1" term_pred awaiting_ack
  event 50 handoff_reject "$N1" term_late missing_claim
  screen term_late "$N1"
  apply >/dev/null || fail "apply with an unknown owner failed"
  assert_equals "" "$(closed)" "nothing is closed when the lock owner's terminal is unknown"
  assert_equals "left owner_terminal_unknown" "$(outcome_of term_late)" "the terminal is left when the owner cannot be told apart"
  pass "a foreign, unproven or unclosable terminal is left open and reported once"
}

test_gone_and_unreachable_are_told_apart() {
  local out
  new_home gone
  event 300 handoff_started "$N1" term_owner awaiting_ack
  event 60 handoff_reject "$N1" term_gone missing_claim
  : > "$FAKE_ORCA/down"
  out=$(apply) || fail "apply with Orca down failed"
  assert_equals "" "$(outcomes)$out" "a terminal is not judged while Orca does not answer"
  rm -f "$FAKE_ORCA/down"
  out=$(apply) || fail "apply failed"
  assert_equals "gone terminal_not_found" "$(outcome_of term_gone)" "a terminal Orca no longer has is recorded as gone"
  assert_equals "" "$(closed)$out" "a gone terminal needs no close and no report"
  pass "a terminal that is gone is recorded, and an unreachable Orca is tried again later"
}

test_ignores_rejects_that_are_not_late_successors() {
  new_home ignore
  event 500 handoff_started "$N1" term_owner awaiting_ack
  event 490 handoff_reject "$N1" term_retried hash_mismatch
  event 480 handoff_ack "$N1" term_other lock_transferred
  event 400 handoff_reject "$N3" term_stranger stale_nonce
  event 300 handoff_started "$N2" term_owner awaiting_ack
  event 290 handoff_reject "$N2" term_pred predecessor_ack
  event 280 handoff_reject none term_unbound lock_held_unbound
  event 270 handoff_reject "$N2" none no_terminal
  printf 'HANDOFF v1 ts=%s event=handoff_started nonce=%s attempt=1 pid=0 handle=term_owner reason=awaiting_ack\n' \
    "$((NOW - 200000))" "${N3:0:30}aa" >> "$HOME_DIR/state/handoff-events.log"
  printf 'HANDOFF v1 ts=%s event=handoff_reject nonce=%s attempt=0 pid=0 handle=term_old reason=missing_claim\n' \
    "$((NOW - 190000))" "${N3:0:30}aa" >> "$HOME_DIR/state/handoff-events.log"
  for h in term_retried term_stranger term_pred term_unbound term_old; do screen "$h" "$N1"; done
  apply >/dev/null || fail "apply failed"
  assert_equals "" "$(closed)" "nothing is closed"
  assert_equals "" "$(outcomes)" "an acknowledged attempt, an unknown nonce, the predecessor, an unbound refusal and an old reject are not candidates"
  pass "only a refused successor of an attempt this home launched and never acknowledged is a candidate"
}

test_bad_arguments_are_refused() {
  local rc
  new_home args
  ARGS=(--report); reconcile >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "--report without --apply"
  ARGS=(--force); reconcile >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "an unknown flag"
  ARGS=(--apply --report)
  rm -rf "$HOME_DIR/state"
  reconcile >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a home with no state directory"
  pass "bad arguments are refused and a home with nothing to reconcile is a quiet success"
}

ARGS=()
fm_test_run \
  test_retires_a_proven_late_successor_once \
  test_never_ends_a_protected_terminal \
  test_does_nothing_while_a_handoff_is_in_progress \
  test_unproven_and_foreign_terminals_are_left_and_reported_once \
  test_gone_and_unreachable_are_told_apart \
  test_ignores_rejects_that_are_not_late_successors \
  test_bad_arguments_are_refused
