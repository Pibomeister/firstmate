#!/usr/bin/env bash
# Live driver: runs the real bin/fm-watch.sh against disposable state homes with
# a hermetic fake tmux (from tests/wake-helpers.sh make_case). Usage: live-driver.sh <worktree>
set -u
WT=$1
. "$WT/tests/fm-watch-triage-common.sh"
WATCH="$WT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-live-driver)
RC=0
ok() { printf 'PASS - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; RC=1; }
base_env() { echo FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999; }

echo "== S1 default mode (no FM_WATCH_NOW/FM_WATCH_ONCE): continuous loop on the real clock"
d=$(make_case s1); s=$d/state
PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE=$s env $(base_env) "$WATCH" > "$d/out" 2> "$d/err" &
pid=$!
sleep 1.5; b1=$(stat -f %m "$s/.last-watcher-beat")
sleep 3.5
if kill -0 $pid 2>/dev/null; then
  b2=$(stat -f %m "$s/.last-watcher-beat")
  echo "  alive after 5s; beacon mtime $b1 -> $b2 (real now $(date +%s))"
  [ "$b2" -gt "$b1" ] && ok "default watcher keeps cycling (beacon advanced on real clock)" || bad "beacon did not advance"
else bad "default watcher exited early: $(cat "$d/err")"; fi
kill -TERM $pid; wait $pid 2>/dev/null; echo "  stopped with TERM rc=$?"

echo "== S2 FM_WATCH_ONCE=1: one cycle then exits cleanly, lock released"
d=$(make_case s2); s=$d/state
t0=$(date +%s)
PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE=$s FM_WATCH_ONCE=1 env $(base_env) "$WATCH" > "$d/out" 2> "$d/err"; rc=$?
echo "  rc=$rc elapsed=$(( $(date +%s)-t0 ))s beacon=$( [ -e "$s/.last-watcher-beat" ] && echo present || echo missing ) stderr='$(head -c 300 "$d/err")'"
PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE=$s FM_WATCH_ONCE=1 env $(base_env) "$WATCH" > "$d/out2" 2> "$d/err2"; rc2=$?
echo "  second once-run rc=$rc2 stderr='$(head -c 300 "$d/err2")'"
[ $rc -eq 0 ] && [ $rc2 -eq 0 ] && ! grep -q 'lock held' "$d/err2" && ok "once mode exits 0 and releases the watcher lock" || bad "once mode rc=$rc/$rc2"

echo "== S3 adversarial: malformed FM_WATCH_NOW is refused before any work"
d=$(make_case s3); s=$d/state
for v in abc -5 01 '' '1.5' ' 12'; do
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE=$s FM_WATCH_ONCE=1 FM_WATCH_NOW="$v" env $(base_env) "$WATCH" > "$d/out" 2> "$d/err"; rc=$?
  echo "  FM_WATCH_NOW='$v' -> rc=$rc '$(cat "$d/err")' lock=$( [ -e "$s/.watch.lock" ] || ls "$s" | grep -q lock && echo touched || echo untouched )"
  [ $rc -eq 2 ] || bad "value '$v' was not refused"
done
[ $RC -eq 0 ] && ok "all malformed values exit 2"

# stale fixture shared by S4/S5
stale_case() {  # <name> -> dir
  local d s key
  d=$(make_case "$1"); s=$d/state
  printf 'idle building output' > "$d/pane.txt"
  printf 'window=test:fm-quiet\nkind=ship\n' > "$s/quiet.meta"
  printf 'working: waiting on CI\n' > "$s/quiet.status"
  printf '%s' "$(seen_sig "$s/quiet.status")" > "$s/.seen-quiet_status"
  key=test_fm-quiet
  printf '%s' "$(hash_text 'idle building output')" > "$s/.hash-$key"
  printf '1\n' > "$s/.count-$key"
  echo "$d"
}
run_cycle() {  # <dir> <out> [env...]
  local d=$1 o=$2; shift 2
  PATH="$d/fakebin:$PATH" FM_FAKE_TMUX_WINDOW=test:fm-quiet FM_FAKE_TMUX_CAPTURE="$d/pane.txt" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · ci (running)' \
    FM_WATCH_HANDLING_SUCCESSOR=1 FM_STATE_OVERRIDE=$d/state FM_CREW_STATE_BIN="$d/fakebin/fm-crew-state.sh" \
    env $(base_env) "$@" "$WATCH" > "$o" 2>> "$d/err"
}

echo "== S4 synthetic clock drives the wedge threshold (boundary 239s vs 241s past a 240s bound)"
d=$(stale_case s4); now=$(( $(date +%s) + 2 ))
t0=$(date +%s)
run_cycle "$d" "$d/a" FM_WATCH_ONCE=1 FM_WATCH_NOW=$now FM_STALE_ESCALATE_SECS=240
echo "  cycle@now: rc=$? out='$(cat "$d/a")' stale-since=$(cat "$d/state/.stale-since-test_fm-quiet" 2>/dev/null)"
run_cycle "$d" "$d/b" FM_WATCH_ONCE=1 FM_WATCH_NOW=$((now + 239)) FM_STALE_ESCALATE_SECS=240
rcb=$?; echo "  cycle@now+239: rc=$rcb out='$(cat "$d/b")' queue=$(cat "$d/state/.wake-queue" 2>/dev/null | wc -c | tr -d " ")B"
run_cycle "$d" "$d/c" FM_WATCH_ONCE=1 FM_WATCH_NOW=$((now + 241)) FM_STALE_ESCALATE_SECS=240
rcc=$?; echo "  cycle@now+241: rc=$rcc out='$(cat "$d/c")'"
echo "  real seconds for all three cycles: $(( $(date +%s)-t0 ))"
[ ! -s "$d/b" ] && grep -q 'possible wedge' "$d/c" && ok "absorbed just under the bound, escalated just past it, in seconds of real time" || bad "threshold boundary wrong"

echo "== S5 default real clock still escalates a wedge end-to-end (no synthetic clock, continuous daemon)"
d=$(stale_case s5); t0=$(date +%s)
run_cycle "$d" "$d/out" FM_STALE_ESCALATE_SECS=3 &
pid=$!
wait_for_exit $pid 150; rc=$?
echo "  wait rc=$rc elapsed=$(( $(date +%s)-t0 ))s out='$(cat "$d/out")'"
grep -q 'possible wedge' "$d/out" && [ $(( $(date +%s)-t0 )) -ge 3 ] && ok "real-clock daemon escalates after the real threshold elapses" || bad "real-clock escalation missing"
kill $pid 2>/dev/null

rm -rf "$TMP_ROOT"
exit $RC
