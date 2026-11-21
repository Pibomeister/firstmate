#!/usr/bin/env bash
# Stop-hook loop regression and incident drill, using only temporary FM_HOME.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-stop-policy)
trap fm_test_cleanup EXIT
LAB="$TMP_ROOT/home"
printf 'DRILL lab_home=%s (temporary FM_HOME)\n' "$LAB"
mkdir -p "$LAB/state" "$LAB/config" "$LAB/bin" "$LAB/data/orders/parked"
git init -q "$LAB"
git -C "$LAB" -c user.name=test -c user.email=test@example.invalid commit -qm init --allow-empty
: > "$LAB/AGENTS.md"
TRANSCRIPT="$TMP_ROOT/transcript.jsonl"
PAYLOAD="$TMP_ROOT/payload.json"
export FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config"
export FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0 FM_TEST_SEAM=1

turn() { # <session> <text> [active]
  jq -nc --arg t "$2" '{type:"user",message:{content:"Stop hook feedback"}},
    {type:"assistant",message:{content:[{type:"text",text:$t}]}}' >> "$TRANSCRIPT"
  jq -nc --arg s "$1" --arg t "$TRANSCRIPT" --argjson a "${3:-false}" \
    '{session_id:$s,transcript_path:$t,hook_event_name:"Stop",stop_hook_active:$a}' > "$PAYLOAD"
}
guard() {
  RC=0
  if [ "${1:-claude}" = default ]; then
    FM_SUPERVISION_ACTOR=branch FM_SUPERVISION_PRIMARY_HARNESS=claude \
      bash "$ROOT/bin/fm-turnend-guard.sh" < "$PAYLOAD" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err" || RC=$?
  else
    bash "$ROOT/bin/fm-turnend-guard.sh" --claude < "$PAYLOAD" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err" || RC=$?
  fi
}
supervised_guard() {
  local owner
  sleep 60 &
  owner=$!
  mkdir -p "$LAB/state/.claude-autoarm.lock"
  printf '%s\n' "$owner" > "$LAB/state/.claude-autoarm.lock/pid"
  printf 'autoarm\n' > "$LAB/state/.claude-autoarm.lock/role"
  guard
  rm -rf "$LAB/state/.claude-autoarm.lock"
  kill "$owner" 2>/dev/null || true
  wait "$owner" 2>/dev/null || true
}
expect_rc() { [ "$RC" -eq "$1" ] || fail "$2: expected rc=$1, got $RC: $(cat "$TMP_ROOT/err")"; }
event() { rg -q "status=$1 " "$LAB/state/stop-hook.log" || fail "missing $1 event"; }

: > "$LAB/state/task.meta"
printf 'captain-held [at=1]: transferred to owner\n' > "$LAB/state/task.status"
turn parked shipshape
supervised_guard
expect_rc 0 'all parked stops in one turn'
event parked
pass 'DRILL all-parked: stopped in 1 turn'

mkdir -p "$LAB/data/orders/pending"
printf 'kind=order\n--\nnew executable order\n' > "$LAB/data/orders/pending/new.order"
turn parked-order shipshape
guard
expect_rc 2 'an executable order overrides parked tasks'
rm "$LAB/data/orders/pending/new.order"
printf 'paused [at=1]: awaiting external check completion\n' > "$LAB/state/task.status"
turn external shipshape
supervised_guard
expect_rc 0 'all external waits stop'
printf 'working [at=1]: other actionable task\n' > "$LAB/state/other.status"
: > "$LAB/state/other.meta"
turn mixed shipshape
guard
expect_rc 2 'one actionable item prevents parked shortcut'
rm "$LAB/state/other.meta" "$LAB/state/other.status"
pass 'parked shortcut preserves executable orders and mixed work'

printf 'working [at=2]: executable work\n' >> "$LAB/state/task.status"
turn active shipshape true
guard default
expect_rc 0 'stop_hook_active always allows stop'
event hook_active
pass 'stop_hook_active is honored by the ordinary Stop guard'

for n in 1 2 3; do
  case "$n" in 1) text='Shipshape.' ;; 2) text='  SHIPSHAPE.  ' ;; 3) text='shipshape.' ;; esac
  turn repeat "$text"
  guard
  if [ "$n" -lt 3 ]; then expect_rc 2 'actionable work continues'; else expect_rc 0 'third identical reply stops'; fi
  printf 'DRILL repeated reply turn=%s exit=%s\n' "$n" "$RC"
done
event hook_loop
pass 'DRILL constant normalized reply: loop broken by turn 3'

for n in 1 2 3 4 5 6 7 8 9 10 11 12 13; do
  turn budget "different reply $n"
  guard
  if [ "$n" -le 12 ]; then expect_rc 2 'twelve continuations allowed'; else expect_rc 0 'thirteenth continuation refused'; fi
done
event hook_budget
pass 'rolling-hour budget permits at most twelve continuations per session'
for hook in fm-handoff-trigger.sh fm-claude-stop-autoarm.sh; do
  RC=0
  bash "$ROOT/bin/$hook" < "$PAYLOAD" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err" || RC=$?
  expect_rc 0 "$hook honors exhausted session budget"
done

FAKEBIN=$(fm_fakebin "$TMP_ROOT/clock")
REAL_DATE=$(command -v date)
FUTURE=$(( $(date +%s) + 3601 ))
printf '#!/usr/bin/env bash\nif [ "$*" = +%%s ]; then echo %s; else exec %q "$@"; fi\n' "$FUTURE" "$REAL_DATE" > "$FAKEBIN/date"
chmod +x "$FAKEBIN/date"
turn budget 'after rolling hour'
PATH="$FAKEBIN:$PATH" guard
expect_rc 2 'rolling-hour reservations expire'
pass 'budget expires after a rolling hour without affecting other sessions'

# A harness may keep turn_id unchanged across continuations. Without a readable
# transcript it cannot prove that two writers describe the same Stop event.
jq -nc '{session_id:"no-transcript",turn_id:"fixed",stop_hook_active:false}' > "$PAYLOAD"
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13; do
  guard
  if [ "$n" -le 12 ]; then expect_rc 2 'missing transcript still charges continuations'; else expect_rc 0 'missing transcript cannot evade hourly cap'; fi
done
pass 'a fixed turn_id without a transcript cannot bypass the cap'

# A sibling hook for the same Stop must share the charge, including parallel calls.
turn dedup same
guard
expect_rc 2 'first charge'
guard
expect_rc 2 'same Stop retains verdict'
[ "$(rg -c 'session=dedup .*status=continue ' "$LAB/state/stop-hook.log")" -eq 1 ] || fail 'same Stop charged twice'
pass 'parallel Stop entrypoints share one event charge'
turn concurrent same
pids=()
for n in 1 2 3; do
  ( rc=0; bash "$ROOT/bin/fm-turnend-guard.sh" --claude < "$PAYLOAD" > "$TMP_ROOT/concurrent-$n.out" 2>&1 || rc=$?; printf '%s\n' "$rc" > "$TMP_ROOT/concurrent-$n.rc" ) &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid" || fail 'concurrent hook failed'; done
for n in 1 2 3; do
  case "$(cat "$TMP_ROOT/concurrent-$n.rc")" in
    2) : ;;
    0) rg -q 'session=concurrent status=policy_error ' "$LAB/state/stop-hook.log" || fail "concurrent allow lacked a policy_error event: $(cat "$TMP_ROOT/concurrent-$n.out")" ;;
    *) fail "concurrent hook failed: $(cat "$TMP_ROOT/concurrent-$n.out")" ;;
  esac
done
[ "$(rg -c 'session=concurrent .*status=continue ' "$LAB/state/stop-hook.log")" -eq 1 ] || fail 'concurrent Stop charged twice'
pass 'three concurrent Stop writers reserve one continuation'

# The public cheap predicate does not take the ledger lock or parse a transcript.
mkdir "$LAB/state/.stop-hook.check-fast.json.lock"
FASTBIN=$(fm_fakebin "$TMP_ROOT/fast-check")
printf '#!/usr/bin/env bash\nexit 99\n' > "$FASTBIN/cksum"
chmod +x "$FASTBIN/cksum"
turn check-fast same
RC=0
PATH="$FASTBIN:$PATH" bash -c '. "$1/bin/fm-stop-policy-lib.sh"; fm_stop_policy_allows_stop "$(cat "$2")" supervise' _ "$ROOT" "$PAYLOAD" || RC=$?
expect_rc 1 'check-mode contention preserves existing supervision behavior'
[ -d "$LAB/state/.stop-hook.check-fast.json.lock" ] || fail 'check mode touched the ledger lock'
rmdir "$LAB/state/.stop-hook.check-fast.json.lock"
pass 'check mode ignores ledger contention and transcript parsing'

# A tool between identical replies and a new commit independently reset the run.
turn progress same
guard
turn progress same
guard
jq -nc '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",id:"tool1",input:{command:"true"}}]}}' >> "$TRANSCRIPT"
turn progress same
guard
expect_rc 2 'tool call breaks repeated-reply streak'
git -C "$LAB" -c user.name=test -c user.email=test@example.invalid commit -qm progress --allow-empty
turn progress same
guard
expect_rc 2 'commit breaks repeated-reply streak'
pass 'tool calls and commits reset the repeat streak'

seed_full() { # <session>
  local now
  now=$(date +%s)
  jq -nc --argjson now "$now" --argjson n 12 '{times:[range($n)|$now],streak:0}' > "$LAB/state/.stop-hook.$1.json"
}

# A new captain inbox note bypasses an exhausted budget once. The same note
# does not keep waking. Removing it is real work and clears the reservations.
seed_full inbox-bypass
turn inbox-bypass 'exhausted before note'
guard
expect_rc 0 'exhausted budget stops when no inbox note is pending'
mkdir -p "$LAB/state/inbox"
printf 'note\n' > "$LAB/state/inbox/100.note"
turn inbox-bypass 'new inbox note'
guard
expect_rc 2 'a new unacknowledged inbox note bypasses an exhausted budget'
turn inbox-bypass 'same note still pending'
guard
expect_rc 0 'the same pending note does not bypass again'
printf 'note\n' > "$LAB/state/inbox/200.note"
turn inbox-bypass 'second new note'
guard
expect_rc 2 'a second new inbox note bypasses an exhausted budget once'
rm -f "$LAB/state/inbox/100.note" "$LAB/state/inbox/200.note"
turn inbox-bypass 'notes consumed'
guard
expect_rc 2 'consuming the inbox notes clears the reservation budget'
pass 'a new inbox note wakes once through an exhausted budget, and consuming it clears the budget'

seed_full wake-only
printf '1 1 check: lab-wake-only\n' > "$LAB/state/.wake-queue"
turn wake-only 'wake changed'
guard
expect_rc 0 'a wake-queue change does not bypass an exhausted budget'
rm -f "$LAB/state/.wake-queue"
pass 'wake-queue changes do not bypass or clear an exhausted budget'

seed_full tool-poll
jq -nc '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",id:"tool-budget",input:{command:"true"}}]}}' >> "$TRANSCRIPT"
turn tool-poll 'tool only'
guard
expect_rc 0 'a tool call does not reset an exhausted reservation budget'
pass 'tool use does not clear an exhausted reservation budget'

# The first observation stores the lane fingerprint and does not clear a seeded
# full ledger. A later status change or pending lane message does.
seed_full lane-reset
turn lane-reset 'baseline lanes'
guard
expect_rc 0 'first lane observation does not clear a full budget'
printf 'working [at=3]: lane acted\n' >> "$LAB/state/task.status"
turn lane-reset 'lane changed'
guard
expect_rc 2 'a lane status change clears an exhausted budget'
turn lane-reset 'lane unchanged follow-up'
guard
expect_rc 2 'a cleared budget charges the following unchanged poll'
pass 'a lane status change clears an exhausted budget and later polls charge again'

seed_full lane-msg
turn lane-msg 'store lanes'
guard
expect_rc 0 'lane message baseline stays stopped'
mkdir -p "$LAB/state/crew.inbox"
printf 'act\n' > "$LAB/state/crew.inbox/001.msg"
turn lane-msg 'lane message'
guard
expect_rc 2 'a new pending lane inbox message clears an exhausted budget'
pass 'a pending lane inbox message clears an exhausted budget'

# The other Claude Stop writers must not undo an allowed stop.
turn siblings same true
RC=0
bash "$ROOT/bin/fm-handoff-trigger.sh" < "$PAYLOAD" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err" || RC=$?
expect_rc 0 'handoff hook honors active hook'
pass 'handoff gate honors stop_hook_active; auto-arm arming is tested separately'

cat "$LAB/state/stop-hook.log"
