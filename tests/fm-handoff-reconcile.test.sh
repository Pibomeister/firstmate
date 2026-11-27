#!/usr/bin/env bash
# tests/fm-handoff-reconcile.test.sh - bin/fm-handoff-reconcile.sh ends the
# terminal of a late, refused handoff successor exactly once and only with
# proof that its live process is the refused successor, never ends the lock owner, its own terminal, the captain handle, a
# task endpoint or a handoff party, does nothing while a handoff is in
# progress, and reports what it left open.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECONCILE="$ROOT/bin/fm-handoff-reconcile.sh"
TMP_ROOT=$(fm_test_tmproot fm-handoff-reconcile)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
ln -s /bin/bash "$FAKEBIN/claude"
TAB=$(printf '\t')
NOW=$(date +%s)
N1=0123456789abcdef0123456789abcdef
N2=fedcba9876543210fedcba9876543210
N3=00112233445566778899aabbccddeeff

if ! command -v jq >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
  printf '1..0 # SKIP jq and node are needed for the fake Orca\n'
  exit 0
fi

# A fake Orca. A terminal is open while $FAKE_ORCA/<handle>.screen exists and
# closed while <handle>.closed exists; any other handle is one Orca no longer
# knows. Marker files make single calls fail the way a real Orca can:
#   down             no call answers at all
#   <handle>.noread  the terminal is described, its screen cannot be read
#   <handle>.odd     the description is refused for another reason
#   <handle>.sticky  a close is accepted and does nothing
#   <handle>.blip    the first description after a close gets no answer
# Its process sweep (diagnostics memory) lists pty session pty-<handle> rooted
# at the pid in <handle>.session; marker nosweep makes the sweep fail.
cat > "$FAKEBIN/orca" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FAKE_ORCA/calls"
if [ "${1:-} ${2:-}" = "diagnostics memory" ]; then
  [ ! -e "$FAKE_ORCA/down" ] && [ ! -e "$FAKE_ORCA/nosweep" ] || exit 1
  for f in "$FAKE_ORCA"/*.session; do
    [ -f "$f" ] || continue
    h=${f##*/}; h=${h%.session}
    jq -n --arg s "pty-$h" --argjson pid "$(cat "$f")" '{sessionId: $s, pid: $pid}'
  done | jq -s '{ok: true, result: {worktrees: [{sessions: .}]}}'
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
marks="${FAKE_ORCA:?}/${handle:?}"
case "$action" in
  show)
    if [ -e "$marks.blipped" ]; then
      rm -f "${marks:?}.blipped"
      exit 1
    fi
    if [ -e "$marks.odd" ]; then
      printf '{"ok":false,"error":{"code":"runtime_unavailable"}}\n'
      exit 1
    fi
    if [ -f "$marks.screen" ]; then
      jq -n --arg h "$handle" '{ok: true, result: {terminal: {handle: $h, ptyId: ("pty-" + $h), connected: true, writable: true}}}'
      exit 0
    fi
    if [ -e "$marks.closed" ]; then
      jq -n --arg h "$handle" \
        '{ok: true, result: {terminal: {handle: $h, connected: false, writable: false, exitCause: {kind: "operator_close"}}}}'
      exit 0
    fi
    printf '{"ok":false,"error":{"code":"terminal_handle_stale"}}\n'
    exit 1
    ;;
  read)
    if [ -f "$marks.screen" ] && [ ! -e "$marks.noread" ]; then
      jq -Rs '{ok: true, result: {terminal: {tail: split("\n")}}}' "$marks.screen"
      exit 0
    fi
    printf '{"ok":false,"error":{"code":"terminal_read_failed"}}\n'
    exit 1
    ;;
  close)
    printf '%s\n' "$handle" >> "$FAKE_ORCA/closed"
    if [ ! -e "$marks.sticky" ]; then
      rm -f "${marks:?}.screen"
      : > "$marks.closed"
    fi
    [ ! -e "$marks.blip" ] || mv "$marks.blip" "$marks.blipped"
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
waiting() { ARGS=(--waiting); reconcile; }

event() {  # <seconds ago> <event> <nonce> <handle> <reason> [pid]
  printf 'HANDOFF v1 ts=%s event=%s nonce=%s attempt=1 pid=%s handle=%s reason=%s\n' \
    "$((NOW - $1))" "$2" "$3" "${6:-0}" "$4" "$5" >> "$HOME_DIR/state/handoff-events.log"
}

# A real process stands in for a harness: Orca's sweep roots the terminal's
# session at it, and the process tree is read from the live process table.
LIVE_PIDS="$TMP_ROOT/live.pids"
trap 'kill $(cat "$LIVE_PIDS" 2>/dev/null) 2>/dev/null; fm_test_cleanup' EXIT
spawn_live() {  # prints the pid of a fresh live process
  sleep 600 >/dev/null 2>&1 &
  printf '%s\n' "$!" >> "$LIVE_PIDS"
  printf '%s' "$!"
}
live() {  # <handle>: root <handle>'s session at a live process; prints its pid
  local pid
  pid=$(spawn_live)
  printf '%s\n' "$pid" > "$FAKE_ORCA/$1.session"
  printf '%s' "$pid"
}

# The nonce as a wrapped terminal shows it: split over two bordered lines.
screen() {  # <handle> <nonce>
  printf '| Firstmate handoff successor. nonce=%s |\n|   %s |\n| handoff_reject |\n' \
    "${2:0:20}" "${2:20}" > "$FAKE_ORCA/$1.screen"
}

outcomes() { cat "$HOME_DIR/state/handoff-reconcile.tsv" 2>/dev/null; }
outcome_of() { outcomes | awk -F '\t' -v h="$1" '$3 == h { print $4 " " $5 }'; }
nonce_of() { outcomes | awk -F '\t' -v h="$1" '$3 == h { print $2 }'; }
closed() { cat "$FAKE_ORCA/closed" 2>/dev/null; }

test_retires_a_proven_late_successor_once() {
  local out
  new_home retire
  event 300 handoff_started "$N1" term_owner awaiting_ack
  event 100 handoff_failed "$N1" none deadline
  event 50 handoff_reject "$N1" term_late missing_claim "$(live term_late)"
  screen term_late "$N1"
  assert_equals "$N1${TAB}term_late" "$(waiting)" "the undecided terminal is listed as waiting"
  assert_absent "$FAKE_ORCA/calls" "listing what waits asks Orca nothing"
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
  assert_equals "" "$(waiting)" "a decided terminal no longer waits"
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
  event 248 handoff_reject "$N1" term_starter stale_nonce
  event 246 handoff_reject "$N1" term_retrier stale_nonce
  event 244 handoff_started "$N3" term_starter awaiting_ack
  event 242 handoff_retry "$N3" term_retrier awaiting_ack
  event 240 handoff_started "$N2" term_owner awaiting_ack
  event 230 handoff_ack "$N2" term_party lock_transferred
  printf 'backend=orca\ntarget=term_captain\nat=1\n' > "$HOME_DIR/state/captain-handle"
  printf 'kind=ship\nterminal=term_task\n' > "$HOME_DIR/state/t-1.meta"
  printf 'kind=scout\nwindow=term_window\n' > "$HOME_DIR/state/t-2.meta"
  for h in term_owner term_self term_captain term_task term_window term_party term_starter term_retrier; do
    screen "$h" "$N1"
  done
  out=$(apply FM_SUPERVISOR_TARGET=term_self) || fail "apply failed"
  assert_equals "" "$(closed)" "no protected terminal is closed"
  assert_equals "" "$out" "a kept terminal is not reported"
  assert_equals "kept lock_owner" "$(outcome_of term_owner)" "the lock owner's terminal is kept"
  assert_equals "kept own_terminal" "$(outcome_of term_self)" "the caller's own terminal is kept"
  assert_equals "kept captain_handle" "$(outcome_of term_captain)" "the captain handle is kept"
  assert_equals "kept task_endpoint" "$(outcome_of term_task)" "a task terminal is kept"
  assert_equals "kept task_endpoint" "$(outcome_of term_window)" "a task window is kept"
  assert_equals "kept handoff_party" "$(outcome_of term_party)" "a terminal that acknowledged a handoff is kept"
  assert_equals "kept handoff_party" "$(outcome_of term_starter)" "a terminal that started a handoff is kept"
  assert_equals "kept handoff_party" "$(outcome_of term_retrier)" "a terminal that retried a handoff is kept"
  pass "the lock owner, the caller, the captain handle, task endpoints and handoff parties are never ended"
}

test_does_nothing_while_a_handoff_is_in_progress() {
  local out
  new_home busy
  event 300 handoff_started "$N1" term_owner awaiting_ack
  event 50 handoff_reject "$N1" term_late stale_nonce "$(live term_late)"
  screen term_late "$N1"
  printf '{"nonce":"%s"}\n' "$N2" > "$HOME_DIR/state/.handoff-pending"
  out=$(apply) || fail "apply during a claim failed"
  assert_equals "" "$(closed)$(outcomes)$out" "nothing happens while a claim is pending"
  assert_equals "$N1${TAB}term_late" "$(waiting)" "the terminal still waits while a claim is pending"
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
  event 70 handoff_reject "$N1" term_sticky missing_claim "$(live term_sticky)"
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
  event 55 handoff_reject "$N1" term_shut missing_claim
  event 50 handoff_reject "$N1" term_odd missing_claim "$(live term_odd)"
  event 45 handoff_reject "$N1" term_dark missing_claim "$(live term_dark)"
  : > "$FAKE_ORCA/term_shut.closed"
  : > "$FAKE_ORCA/term_odd.odd"
  screen term_odd "$N1"
  screen term_dark "$N1"
  : > "$FAKE_ORCA/term_dark.noread"
  : > "$FAKE_ORCA/down"
  out=$(apply) || fail "apply with Orca down failed"
  assert_equals "" "$(outcomes)$out" "a terminal is not judged while Orca does not answer"
  mv "$FAKE_ORCA/down" "$FAKE_ORCA/was-down"
  out=$(apply) || fail "apply failed"
  assert_equals "gone terminal_stale" "$(outcome_of term_gone)" "a handle Orca no longer knows is recorded as gone"
  assert_equals "gone terminal_closed" "$(outcome_of term_shut)" "a terminal Orca describes as closed is recorded as gone"
  assert_equals "" "$(outcome_of term_odd)" "another refusal from Orca is not read as a closed terminal"
  assert_equals "" "$(outcome_of term_dark)" "an open terminal whose screen cannot be read is not judged"
  assert_equals "" "$(closed)$out" "nothing is closed and nothing is reported"
  mv "$FAKE_ORCA/term_odd.odd" "$FAKE_ORCA/term_odd.was-odd"
  mv "$FAKE_ORCA/term_dark.noread" "$FAKE_ORCA/term_dark.was-noread"
  apply >/dev/null || fail "apply after Orca recovered failed"
  assert_equals "retired nonce_proven" "$(outcome_of term_odd)" "the refused terminal is ended once Orca describes it"
  assert_equals "retired nonce_proven" "$(outcome_of term_dark)" "the unread terminal is ended once its screen reads"
  pass "only Orca's exact closed or unknown-handle answer is read as gone; every other failure is tried again"
}

test_a_close_cut_off_before_its_record_is_still_reported() {
  local out
  new_home cutoff
  event 300 handoff_started "$N1" term_owner awaiting_ack
  event 50 handoff_reject "$N1" term_late missing_claim "$(live term_late)"
  screen term_late "$N1"
  : > "$FAKE_ORCA/term_late.blip"
  out=$(apply) || fail "apply failed"
  assert_equals term_late "$(closed)" "the close was sent"
  assert_equals "" "$(outcomes)$out" "an unverified close is neither recorded nor reported"
  assert_equals "$N1${TAB}term_late" "$(waiting)" "the terminal still waits for its verdict"
  out=$(apply) || fail "second apply failed"
  assert_equals term_late "$(closed)" "the close is not sent twice"
  assert_equals "retired nonce_proven" "$(outcome_of term_late)" "the saved screen proves this command closed it"
  assert_contains "$out" "ended the late successor terminal term_late" "the supervisor is still told"
  pass "a run cut off between the close and its record is completed and reported by the next run"
}

test_the_newest_launched_attempt_decides_a_reused_handle() {
  new_home reused
  event 500 handoff_started "$N2" term_owner awaiting_ack
  event 490 handoff_reject "$N2" term_late hash_mismatch
  event 480 handoff_ack "$N2" term_other lock_transferred
  event 400 handoff_reject "$N3" term_late stale_nonce
  event 300 handoff_started "$N1" term_owner awaiting_ack
  event 290 handoff_reject "$N1" term_late missing_claim "$(live term_late)"
  event 280 handoff_reject "$N3" term_late stale_nonce
  screen term_late "$N1"
  assert_equals "$N1${TAB}term_late" "$(waiting)" "the handle waits under its newest launched attempt"
  apply >/dev/null || fail "apply failed"
  assert_equals "retired nonce_proven" "$(outcome_of term_late)" "the terminal is ended"
  assert_equals "$N1" "$(nonce_of term_late)" "an earlier acknowledged attempt and an unknown nonce do not hide it"
  pass "a handle refused under several attempts is judged by the newest one this home launched"
}

test_a_reused_terminal_that_still_shows_the_nonce_is_left_open() {
  local out
  new_home reusedproc
  event 300 handoff_started "$N1" term_owner awaiting_ack
  live term_other >/dev/null
  event 60 handoff_reject "$N1" term_other missing_claim "$(spawn_live)"
  event 55 handoff_reject "$N1" term_nopid missing_claim
  live term_nopid >/dev/null
  event 50 handoff_reject "$N1" term_unswept missing_claim "$(live term_unswept)"
  for h in term_other term_nopid term_unswept; do screen "$h" "$N1"; done
  : > "$FAKE_ORCA/nosweep"
  out=$(apply) || fail "apply with the process sweep failing failed"
  assert_equals "" "$(closed)$(outcome_of term_other)$(outcome_of term_unswept)" "no recorded pid is judged while Orca's process sweep cannot be read"
  rm -f "$FAKE_ORCA/nosweep"
  out=$(dry) || fail "dry run failed"
  assert_contains "$out" "leave term_other (successor_not_proven)" "the dry run names the unproven terminal"
  out=$(apply) || fail "apply failed"
  assert_equals "left successor_not_proven" "$(outcome_of term_other)" "a terminal running another process is left although its screen shows the nonce"
  assert_equals "left successor_not_proven" "$(outcome_of term_nopid)" "a reject that recorded no successor pid proves nothing"
  assert_equals "retired nonce_proven" "$(outcome_of term_unswept)" "the terminal still running the successor is ended"
  assert_equals term_unswept "$(closed)" "only the proven successor's terminal is sent a close"
  assert_present "$FAKE_ORCA/term_other.screen" "the reused terminal stays open"
  assert_contains "$out" "terminal term_other of a failed handoff attempt was left open (successor_not_proven)" "the refusal is reported"
  pass "a terminal whose screen still shows the nonce is closed only while it runs the refused successor"
}

test_a_refused_successor_records_its_harness_pid() {
  local rc pid harness
  new_home refusedpid
  event 300 handoff_started "$N1" term_owner awaiting_ack
  env -u ORCA_TERMINAL_HANDLE -u TMUX -u TMUX_PANE -u ZELLIJ -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION \
    -u FM_SUPERVISOR_BACKEND -u FM_SESSION_ENDPOINT_META -u FM_STATE_OVERRIDE \
    -u CODEX_THREAD_ID -u CODEX_SESSION_ID -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID \
    PATH="$FAKEBIN:$PATH" FAKE_ORCA="$FAKE_ORCA" FM_HOME="$HOME_DIR" FM_SUPERVISOR_TARGET=term_late \
    ACK="$ROOT/bin/fm-handoff-ack.sh" NONCE="$N1" PIDFILE="$HOME_DIR/harness.pid" \
    claude -c 'printf "%s\n" "$$" > "$PIDFILE"; bash "$ACK" "$NONCE" 0 >/dev/null 2>&1; rc=$?; exit "$rc"'
  rc=$?
  expect_code 1 "$rc" "a late acknowledgement"
  harness=$(cat "$HOME_DIR/harness.pid")
  pid=$(awk '$4 == "event=handoff_reject" { for (i = 5; i <= NF; i++) if ($i ~ /^pid=/) print substr($i, 5) }' "$HOME_DIR/state/handoff-events.log")
  assert_equals "$harness" "$pid" "the reject records the pid of the harness the successor runs under"
  pass "a refused successor records its own harness pid with the reject"
}

# refuse <nonce>: a successor in term_late acknowledges with no claim on disk.
refuse() {
  env -u ORCA_TERMINAL_HANDLE -u TMUX -u TMUX_PANE -u ZELLIJ -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION \
    -u FM_SUPERVISOR_BACKEND -u FM_SESSION_ENDPOINT_META -u FM_STATE_OVERRIDE \
    PATH="$FAKEBIN:$PATH" FAKE_ORCA="$FAKE_ORCA" FM_HOME="$HOME_DIR" FM_SUPERVISOR_TARGET=term_late \
    bash "$ROOT/bin/fm-handoff-ack.sh" "$1" 0 >/dev/null 2>&1
}

test_a_refused_successor_arms_the_check_that_ends_it() {
  local rc check
  new_home refused
  check="$HOME_DIR/state/reset-audit.check.sh"
  event 300 handoff_started "$N1" term_owner awaiting_ack
  refuse "$N3"; rc=$?
  expect_code 1 "$rc" "an acknowledgement of an attempt this home never launched"
  assert_absent "$check" "a refusal that names no late successor armed the check"
  refuse "$N1"; rc=$?
  expect_code 1 "$rc" "a late acknowledgement"
  assert_equals "$N1${TAB}term_late" "$(waiting)" "the refused successor waits to be ended"
  [ -x "$check" ] || fail "refusing a late successor did not arm the check that ends it"
  pass "refusing a late successor arms the check that ends it, and no other refusal does"
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
  ARGS=(--waiting --apply); reconcile >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "--waiting with --apply"
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
  test_a_close_cut_off_before_its_record_is_still_reported \
  test_the_newest_launched_attempt_decides_a_reused_handle \
  test_a_refused_successor_arms_the_check_that_ends_it \
  test_ignores_rejects_that_are_not_late_successors \
  test_a_reused_terminal_that_still_shows_the_nonce_is_left_open \
  test_a_refused_successor_records_its_harness_pid \
  test_bad_arguments_are_refused
