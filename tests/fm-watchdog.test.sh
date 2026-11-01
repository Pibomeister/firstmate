#!/usr/bin/env bash
# tests/fm-watchdog.test.sh - the firstmate assistant watchdog (bin/fm-watchdog.sh).
#
# Detectors run on fixtures through the sourced library. Every action case runs
# the real script against a disposable home whose captain pane is a real tmux
# pane on a private socket, whose lock holder is a real process, and whose
# transcript, wake queue, status files, and ledger are real files. Model CLIs
# are PATH fakes that log every call. Each hard boundary has its own case.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-watchdog-tests)
WD="$ROOT/bin/fm-watchdog.sh"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-watchdog-test-$$"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -f /dev/null -L "$SOCKET" "\$@"
SH
chmod +x "$FAKEBIN/tmux"
CALLS_LOG="$TMP_ROOT/external-calls.log"
: > "$CALLS_LOG"
# Every tool that could merge, deploy, notify the owner, or file upstream logs here.
for tool in gh gh-axi osascript terminal-notifier say mail sendmail curl; do
  cat > "$FAKEBIN/$tool" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$tool" "\$*" >> "$CALLS_LOG"
exit 1
SH
  chmod +x "$FAKEBIN/$tool"
done
PATH="$FAKEBIN:$PATH"
export PATH

LOCK_PIDS=''
cleanup_watchdog_tests() {
  local p
  for p in $LOCK_PIDS; do kill "$p" 2>/dev/null || true; done
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_watchdog_tests EXIT

BASE=$(date +%s)
CASE_N=0

# fake_models <dir> <claude-mode> <agy-mode>: mode ok:<answer>, fail, or absent.
fake_models() {
  local dir=$1 cm=$2 am=$3
  rm -f "$FAKEBIN/claude" "$FAKEBIN/agy"
  if [ "$cm" != absent ]; then
    cat > "$FAKEBIN/claude" <<SH
#!/usr/bin/env bash
# A real claude -p reads its prompt from stdin; an empty prompt is a failure.
[ -n "\$(cat)" ] || exit 1
printf 'claude %s\n' "\$*" >> "$dir/model.log"
case "$cm" in
  ok:*) printf '{"result":"%s","total_cost_usd":0.0012,"usage":{"input_tokens":50,"output_tokens":3}}\n' "${cm#ok:}" ;;
  *) exit 1 ;;
esac
SH
    chmod +x "$FAKEBIN/claude"
  fi
  if [ "$am" != absent ]; then
    cat > "$FAKEBIN/agy" <<SH
#!/usr/bin/env bash
printf 'agy %s\n' "\$*" >> "$dir/model.log"
case "$am" in
  ok:*) printf '{"status":"success","response":"%s","usage":{"input_tokens":40,"output_tokens":2}}\n' "${am#ok:}" ;;
  *) exit 1 ;;
esac
SH
    chmod +x "$FAKEBIN/agy"
  fi
}

# make_home <screen-text> [extra-config]: builds a disposable home whose captain
# pane shows <screen-text> and then echoes everything typed into typed.log.
# Sets H (home), T (pane target), LOCKPID, SID.
make_home() {
  local screen=$1 extra=${2:-} sess
  CASE_N=$((CASE_N + 1))
  H="$TMP_ROOT/home$CASE_N"
  SID="00000000-0000-4000-8000-00000000000$CASE_N"
  mkdir -p "$H/state" "$H/config" "$H/data" "$H/claude/projects/p"
  printf '%s\n' "$screen" > "$H/screen.txt"
  cat > "$H/agent.sh" <<SH
#!/usr/bin/env bash
cat "$H/screen.txt"
stty -echo
exec cat >> "$H/typed.log"
SH
  chmod +x "$H/agent.sh"
  : > "$H/typed.log"
  sess="wd$CASE_N"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" new-session -d -s "$sess" -x 160 -y 40 "$H/agent.sh"
  T=$("$REAL_TMUX" -f /dev/null -L "$SOCKET" list-panes -t "$sess" -F '#{pane_id}' | head -n 1)
  # Detached, so the lock holder is reparented and reaped like a real session.
  ( sleep 100000 > /dev/null 2>&1 & printf '%s\n' "$!" > "$H/lockpid" )
  LOCKPID=$(cat "$H/lockpid")
  LOCK_PIDS="$LOCK_PIDS $LOCKPID"
  printf '%s\n' "$LOCKPID" > "$H/state/.lock"
  printf '%s\n' "$SID" > "$H/state/.lock-session"
  jq -n --arg t "$T" --arg s "$SID" --argjson e "$BASE" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:"tmux",target:$t,present:true},session:{trusted_id:$s}}}' \
    > "$H/state/heartbeat.json"
  printf 'mode=act\nclaude-config-dirs=%s\nkey-settle-secs=1\nmodels=\n%s\n' "$H/claude" "$extra" > "$H/config/watchdog"
  sleep 0.5
}

# transcript <age-secs> <text>...: one assistant text per argument, 600s apart,
# each followed by a ScheduleWakeup tool call; the file is aged <age-secs>.
transcript() {
  local age=$1 i=0 n t f
  shift
  f="$H/claude/projects/p/$SID.jsonl"
  : > "$f"
  n=$#
  for t in "$@"; do
    i=$((i + 1))
    local at=$((BASE - age - (n - i) * ${GAP:-600}))
    local iso
    iso=$(date -u -r "$at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$at" +%Y-%m-%dT%H:%M:%SZ)
    jq -cn --arg ts "$iso" --arg t "$t" '{type:"assistant",timestamp:$ts,message:{content:[{type:"text",text:$t},{type:"tool_use",name:"ScheduleWakeup",input:{}}]}}' >> "$f"
  done
  fm_touch_epoch "$((BASE - age))" "$f"
}

owe_input() {  # <age-secs>
  printf '%s\t1\tcheck\tinbox\tcaptain note waiting\n' "$((BASE - $1))" > "$H/state/.wake-queue"
}

run_wd() {  # <offset-secs> <args>...
  local off=$1
  shift
  FM_TEST_SEAM=1 FM_WD_NOW=$((BASE + off)) FM_HOME="$H" bash "$WD" "$@"
}

ledger() { cat "$H/state/watchdog/actions.tsv" 2>/dev/null; }
ledger_rows() {  # <symptom> <action> <phase>
  awk -F'\t' -v s="$1" -v a="$2" -v p="$3" '$5 == s && $6 == a && $7 == p' "$H/state/watchdog/actions.tsv" 2>/dev/null | wc -l | tr -d ' '
}

wait_typed() {  # <needle>
  local i
  for i in $(seq 1 50); do
    grep -Fq -- "$1" "$H/typed.log" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}

# --- detectors -----------------------------------------------------------------

lib() { bash -c '. "$1/bin/fm-watchdog-lib.sh"; shift; "$@"' _ "$ROOT" "$@"; }

test_dialog_detection() {
  local feedback model question permission plain trust composer
  feedback=$'some work\n● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss'
  model=$'You have hit your weekly limit for Opus.\n\n ❯ 1. Switch to Sonnet\n   2. Wait for the limit to reset\n   3. Buy more credits\n\nEnter to confirm · Esc to cancel'
  question=$'Which plan should I follow?\n ❯ 1. Plan A (Recommended)\n   2. Plan B\n\nEnter to select · ↑/↓ to navigate · Esc to cancel'
  permission=$'Do you want to proceed?\n ❯ 1. Yes\n   2. No, and tell Claude what to do differently\n\nEsc to cancel'
  plain=$'I will now choose:\n 1. Plan A\n 2. Plan B\n\n> '
  trust=$' Quick safety check: Is this a project you created or one you trust?\n Claude Code\'ll be able to read, edit, and execute files here.\n ❯ No, exit\n   Yes, I trust this folder\n Enter to confirm · Esc to cancel'
  composer=$'❯ fix the bug in the parser\n  ? for shortcuts'
  assert_equals feedback "$(lib fm_wd_pane_dialog "$feedback")" "feedback survey"
  assert_equals model-switch "$(lib fm_wd_pane_dialog "$model")" "model-switch dialog"
  assert_equals question "$(lib fm_wd_pane_dialog "$question")" "question dialog"
  assert_equals permission "$(lib fm_wd_pane_dialog "$permission")" "permission dialog"
  assert_equals "" "$(lib fm_wd_pane_dialog "$plain")" "a numbered list in prose is no dialog"
  assert_equals permission "$(lib fm_wd_pane_dialog "$trust")" "unnumbered folder-trust picker is a permission dialog"
  assert_equals "" "$(lib fm_wd_pane_dialog "$composer")" "a composer prompt glyph without a picker footer is no dialog"
  assert_contains "$(lib fm_wd_dialog_options "$model")" $'3\tBuy more credits' "dialog options parsed"
  assert_equals 42 "$(lib fm_wd_footer_percent $'work\n  42% until auto-compact')" "auto-compact footer"
  pass "dialogs need their structure, and each kind is told apart"
}

test_loop_verdicts() {
  local ev
  ev=$'T\t1000\tI re-armed the wake as job b6vfy20jj. Still waiting.\nU\t1001\tScheduleWakeup\t\nT\t1600\tI re-armed the wake as job k2c9x1aa. Still waiting.\nU\t1601\tScheduleWakeup\t\nT\t2200\tI re-armed the wake as job z81q0pp4. Still waiting.'
  assert_equals loop "$(printf '%s\n' "$ev" | lib fm_wd_loop_verdict 180 | cut -f1)" "re-arm loop with changing job ids"
  ev=$'T\t1000\tStill read-only, still waiting.\nT\t1050\tStill read-only, still waiting.\nT\t1100\tStill read-only, still waiting.'
  assert_equals rapid "$(printf '%s\n' "$ev" | lib fm_wd_loop_verdict 180 | cut -f1)" "repeats inside 180s are rapid"
  ev=$'T\t1000\tStill waiting.\nU\t1001\tEdit\tx\nT\t1600\tStill waiting.\nT\t2200\tStill waiting.'
  assert_equals none "$(printf '%s\n' "$ev" | lib fm_wd_loop_verdict 180 | cut -f1)" "real work between repeats is no loop"
  ev=$'T\t1000\tThe build failed at step three, retrying.\nT\t1600\tThe build failed at step three, now green.\nT\t2200\tThe build failed at step three, shipped it.'
  assert_equals near "$(printf '%s\n' "$ev" | lib fm_wd_loop_verdict 180 | cut -f1)" "same opening, different endings goes to the judge"
  pass "loop verdicts: loop, rapid, near, and work-between"
}

test_stall_proof_and_text_guards() {
  lib fm_wd_stall_proof 0 0 rendered filesystem || fail "two kinds, idle, should prove a stall"
  ! lib fm_wd_stall_proof 0 0 rendered rendered || fail "one kind twice is not two signals"
  ! lib fm_wd_stall_proof 1 0 rendered filesystem kernel || fail "a running turn must veto"
  ! lib fm_wd_stall_proof 0 1 rendered filesystem kernel || fail "a busy CPU must veto"
  ! lib fm_wd_stall_proof unknown 0 rendered filesystem || fail "an unknown turn must veto"
  ! lib fm_wd_text_allowed "merge #12" || fail "merge #12 must be refused"
  ! lib fm_wd_text_allowed "Deploy to prod" || fail "deploy must be refused"
  lib fm_wd_text_allowed "emerge from the wake queue" || fail "emerge is not merge"
  lib fm_wd_reserved "spend \$40 on credits?" || fail "spend is owner-reserved"
  ! lib fm_wd_reserved "pick the cache layout" || fail "an ordinary decision is not reserved"
  pass "stall proof needs two signals and no veto; merge and deploy text is refused"
}

# --- actions -------------------------------------------------------------------

test_frozen_pane_nudges_once_then_rate_limits() {
  make_home $'Captain session\n> '
  transcript 3000 "Working on the fix." "Now testing it." "Tests are green."
  owe_input 3000
  run_wd 0 once >/dev/null 2>&1 || fail "first pass failed"
  assert_equals 0 "$(ledger_rows frozen nudge pending)" "a first sight is no stall"
  run_wd 1000 once >/dev/null 2>&1 || fail "second pass failed"
  assert_equals 1 "$(ledger_rows frozen nudge pending)" "a frozen pane with owed input gets one nudge"
  wait_typed ": fm-op " || wait_typed "operational-inbox" || fail "the doorbell never reached the pane: $(cat "$H/typed.log")"
  ls "$H/state/operational-inbox/"*.msg >/dev/null 2>&1 || fail "no durable operational record behind the doorbell"
  run_wd 1100 once >/dev/null 2>&1 || fail "third pass failed"
  assert_equals 1 "$(ledger_rows frozen nudge pending)" "a second nudge inside the window is rate-limited"
  pass "frozen pane: proven by records, nudged once with a record-backed doorbell, then rate-limited"
}

test_do_not_touch_never_typed() {
  make_home $'Captain session\n> '
  printf 'do-not-touch=%s\n' "$T" >> "$H/config/watchdog"
  transcript 3000 "Working." "Testing." "Green."
  owe_input 3000
  run_wd 0 once >/dev/null 2>&1
  run_wd 1000 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows frozen nudge refused)" "a do-not-touch endpoint records a refusal"
  sleep 1
  assert_equals "" "$(cat "$H/typed.log")" "nothing is typed into a do-not-touch pane"
  pass "boundary: never types into a pane on the do-not-touch list"
}

test_merge_autosuggestion_never_accepted() {
  make_home $'Captain session\n> merge #12'
  FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=pending run_wd 300 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=pending run_wd 400 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows pasted-input key refused)" "pending merge text is refused once per window"
  sleep 1
  assert_equals "" "$(cat "$H/typed.log")" "Enter was never pressed on merge #12"
  make_home $'Captain session\n> continue with the plan'
  FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=pending run_wd 300 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows pasted-input key pending)" "ordinary unsent text gets Enter"
  for _ in $(seq 1 25); do [ -s "$H/typed.log" ] && break; sleep 0.2; done
  [ -s "$H/typed.log" ] || fail "Enter never reached the pane"
  pass "boundary: never accepts a merge autosuggestion, while ordinary unsent text is submitted"
}

test_unreadable_draft_never_gets_enter() {
  make_home $'Captain session\n> [Pasted text #1 +40 lines]'
  FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=pending run_wd 300 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows pasted-input key refused)" "a paste placeholder is refused"
  assert_grep "Enter not pressed" "$H/data/watchdog/status.md" "the placeholder is a reported gap"
  sleep 1
  assert_equals "" "$(cat "$H/typed.log")" "Enter was never pressed on a paste placeholder"
  make_home $'> merge PR #5\n  a\n  b\n  c\n  d\n  e\n  f\n  g\n  h\n  i'
  FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=pending run_wd 300 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows pasted-input key refused)" "a draft taller than the window is refused"
  sleep 1
  assert_equals "" "$(cat "$H/typed.log")" "Enter was never pressed on a draft taller than the window"
  pass "boundary: a draft whose whole text cannot be read never gets Enter"
}

test_owner_reserved_holds_stay_held_and_council_settles_the_rest() {
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  transcript 100 "Working."
  {
    printf 'needs-decision [at=%s] [key=captain-hold-pricing-1]: pick a price tier\n' "$((BASE - 9000))"
    printf 'needs-decision [at=%s] [key=ship-it]: merge PR #5 now or wait?\n' "$((BASE - 9000))"
    printf 'needs-decision [at=%s] [key=cache-layout]: A (recommended) flat keys or B nested keys?\n' "$((BASE - 9000))"
  } > "$H/state/t1.status"
  run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows decisions nudge pending)" "aged decisions get one rolled-up nudge"
  run_wd 2000 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows decision:cache-layout council "done")" "the ordinary decision goes to council after the nudge window"
  ledger | grep -F 'captain-hold-pricing-1' | grep -Eq 'council|ruling' && fail "an owner hold reached council"
  ledger | grep -F 'ship-it' | grep -Eq 'council|ruling' && fail "a merge decision reached council"
  assert_grep "held for the owner" "$H/data/watchdog/status.md" "held decisions are reported as gaps"
  ls "$H/data/watchdog/rulings/"*cache-layout*.md >/dev/null 2>&1 || fail "no ruling file for a unanimous council"
  assert_grep "unanimous" "$H/data/watchdog/rulings/home$CASE_N-t1-cache-layout.md" "ruling records unanimity"
  assert_equals 2 "$(grep -cE '^(claude|agy) -p' "$H/model.log")" "each blind seat was called once"
  pass "boundary: owner-reserved holds stay held; an ordinary decision is settled by a unanimous blind council"
}

test_split_council_gives_no_ruling() {
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"HOLD"
  transcript 100 "Working."
  printf 'needs-decision [at=%s] [key=cache-layout]: A flat keys or B nested keys?\n' "$((BASE - 9000))" > "$H/state/t1.status"
  run_wd 0 once >/dev/null 2>&1
  run_wd 2000 once >/dev/null 2>&1
  ls "$H/data/watchdog/rulings/"*.md >/dev/null 2>&1 && fail "a split council must not write a ruling"
  ledger | grep -F 'ruling:cache-layout' && fail "a split council must not nudge a ruling"
  pass "council needs unanimity; a split vote holds"
}

test_judge_fallback_and_spend_cap() {
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
daily-max-usd=0.01'
  fake_models "$H" fail ok:WORK
  out=$(printf 'is this a loop?' | run_wd 0 judge loop '(LOOP|WORK)') || fail "judge failed despite a working second model"
  assert_equals WORK "$out" "the second model answered"
  assert_grep "claude" "$H/model.log" "the first model was tried"
  assert_equals 2 "$(wc -l < "$H/state/watchdog/model-calls.tsv" | tr -d ' ')" "both calls were logged"
  printf '%s\tloop\tclaude:haiku\tok\t1\t1\tLOOP\t0.02\n' "$BASE" >> "$H/state/watchdog/model-calls.tsv"
  : > "$H/model.log"
  printf 'is this a loop?' | run_wd 10 judge loop '(LOOP|WORK)' >/dev/null 2>&1 && fail "judge ran over the daily cap"
  assert_equals "" "$(cat "$H/model.log")" "no model is called once the daily cap is spent"
  grep -Fq cap-reached "$H/state/watchdog/model-calls.tsv" || fail "the cap refusal is logged"
  pass "boundary: judge falls back across models, logs every call, and never spends past the daily cap"
}

test_no_model_still_acts_and_reports_gap() {
  make_home $'Captain session\n> '
  fake_models "$H" absent absent
  transcript 3000 "Working." "Testing." "Green."
  owe_input 3000
  run_wd 0 once >/dev/null 2>&1
  run_wd 1000 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows frozen nudge pending)" "deterministic nudge still happens with no model"
  assert_grep "no model configured" "$H/data/watchdog/status.md" "the missing model is a reported gap"
  pass "with no model available, deterministic actions still run and the gap is reported"
}

test_timer_loop_needs_owed_input() {
  make_home $'Captain session\n> '
  transcript 1000 "Captain, shipshape." "Captain, shipshape." "Captain, shipshape."
  run_wd 0 once >/dev/null 2>&1
  assert_equals 0 "$(ledger | grep -c timer-loop)" "idle shipshape heartbeats are no loop"
  owe_input 2000
  run_wd 10 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows timer-loop nudge pending)" "the same loop with aged owed input is nudged"
  pass "timer loop fires only with aged owed input, never on idle heartbeats"
}

test_restart_vetoed_by_running_turn() {
  make_home $'Captain session\n✻ Running tool… (esc to interrupt)' 'restart=on
max-nudges=0
restart-command=/bin/false'
  transcript 3000 "Working." "Testing." "Green."
  owe_input 3000
  run_wd 0 once >/dev/null 2>&1
  run_wd 1000 once >/dev/null 2>&1
  kill -0 "$LOCKPID" 2>/dev/null || fail "a busy session was stopped"
  ledger | grep -q restart && fail "a running turn must never be restarted: $(ledger)"
  assert_grep "treated as busy" "$H/data/watchdog/status.md" "the veto is reported"
  pass "boundary: a long running turn is not a stall and is never restarted"
}

test_restart_verified_pickup_and_loop_stop() {
  make_home $'Captain session\n> ' "restart=on
max-nudges=0
pickup-secs=600
restart-command=$TMP_ROOT/fake-captain.sh"
  cat > "$TMP_ROOT/fake-captain.sh" <<'SH'
#!/usr/bin/env bash
p="$*"
printf '%s\n' "$$" > "$PWD/state/.lock"
( sleep 100000 > /dev/null 2>&1 & printf '%s\n' "$!" > "$PWD/state/.supervise-daemon.pid" )
eval "${p##*run: }" > "$PWD/pickup.out" 2>&1
exec sleep 100000
SH
  chmod +x "$TMP_ROOT/fake-captain.sh"
  printf 'unlanded\n' > "$H/data/unlanded-work.txt"
  transcript 3000 "Working." "Testing." "Green."
  owe_input 3000
  # Away mode with a dead away daemon is due a nudge on both passes unless the restart stops it.
  : > "$H/state/.afk"
  printf '999999\n' > "$H/state/.supervise-daemon.pid"
  run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows daemon-dead nudge pending)" "the dead away daemon is nudged before any restart"
  run_wd 1000 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows frozen restart pending)" "a proven stall after the nudge budget restarts"
  assert_equals 0 "$(awk -F'\t' -v t="$((BASE + 1000))" '$1 == t && $6 != "restart" && $7 == "pending"' "$H/state/watchdog/actions.tsv" | wc -l | tr -d ' ')" \
    "after a restart, the stopped session's old endpoint gets nothing more that pass: $(ledger | cut -f1,5-7)"
  for _ in $(seq 1 50); do [ -s "$H/pickup.out" ] && break; sleep 0.2; done
  kill -0 "$LOCKPID" 2>/dev/null && fail "the old session still runs"
  LOCK_PIDS="$LOCK_PIDS $(cat "$H/state/.lock") $(cat "$H/state/.supervise-daemon.pid")"
  ls "$H/data/watchdog/handoffs/"*.md >/dev/null 2>&1 || fail "no restart handoff written"
  run_wd 1100 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows frozen restart "done")" "the pickup was verified with a live away daemon: $(ledger | grep restart)"
  assert_present "$H/data/unlanded-work.txt" "a restart never tears down work"
  # Two restarts inside a day is a loop: the next proven stall escalates instead.
  printf '%s\tx1\t%s\thome\tfrozen\trestart\tpending\told\n' "$((BASE - 20000))" "$(cd -P "$H" && pwd -P)" >> "$H/state/watchdog/actions.tsv"
  run_wd 20000 once >/dev/null 2>&1
  run_wd 21000 once >/dev/null 2>&1
  assert_present "$H/state/watchdog/escalated/home$CASE_N" "a restart loop escalates"
  [ "$(ledger_rows frozen restart pending)" -le 2 ] || fail "restart kept looping"
  pass "restart: lean handoff, new terminal, verified pickup with lock takeover; a loop stops and escalates"
}

# write_fake_captain: a restart-command that takes the lock and proves pickup.
write_fake_captain() {
  cat > "$TMP_ROOT/fake-captain.sh" <<'SH'
#!/usr/bin/env bash
p="$*"
printf '%s\n' "$$" > "$PWD/state/.lock"
eval "${p##*run: }" > "$PWD/pickup.out" 2>&1
exec sleep 100000
SH
  chmod +x "$TMP_ROOT/fake-captain.sh"
}

wait_pickup() {
  local i
  for i in $(seq 1 50); do [ -s "$H/pickup.out" ] && return 0; sleep 0.2; done
  return 1
}

# End the lock holder, then stamp the anchor a real bin/fm-lock.sh writes for it.
kill_holder_with_anchor() {
  printf '%s\nanchor_pid=%s\nanchor_start=Sat Nov  1 02:00:00 2026\n' "$SID" "$LOCKPID" > "$H/state/.lock-session"
  kill "$LOCKPID" 2>/dev/null
  while kill -0 "$LOCKPID" 2>/dev/null; do sleep 0.1; done
}

test_no_action_while_restart_awaits_pickup() {
  make_home $'Captain session\n> ' "restart=on
max-nudges=0
pickup-secs=600
restart-command=/bin/true"
  transcript 3000 "Working." "Testing." "Green."
  owe_input 3000
  run_wd 0 once >/dev/null 2>&1
  run_wd 1000 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows frozen restart pending)" "the proven stall restarts"
  local before
  before=$(ledger | wc -l | tr -d ' ')
  # With the input drained, the stopped holder alone would read as a dead agent.
  rm -f "$H/state/.wake-queue"
  run_wd 1120 once >/dev/null 2>&1
  assert_equals "$before" "$(ledger | wc -l | tr -d ' ')" "nothing is recorded or done while the restart awaits pickup: $(ledger | cut -f1,5-7)"
  assert_absent "$H/state/watchdog/escalated/home$CASE_N" "a normal restart is no restart loop"
  assert_grep "RESTART-AWAITING-PICKUP" "$H/data/watchdog/status.md" "the hold is visible in the health line"
  run_wd 1600 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows frozen restart failed)" "the pickup window still closes the restart"
  pass "boundary: a home whose restart awaits pickup gets no action until the restart closes"
}

test_dead_captain_restarts_despite_its_anchor() {
  make_home $'Captain session\n> ' "restart=on
restart-command=$TMP_ROOT/fake-captain.sh"
  write_fake_captain
  transcript 3000 "Working." "Testing." "Green."
  kill_holder_with_anchor
  run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows agent-gone restart pending)" "a dead captain with a real anchor restarts: $(ledger | cut -f5-8)"
  wait_pickup || fail "the new captain never proved pickup: $(ledger | cut -f5-8)"
  LOCK_PIDS="$LOCK_PIDS $(cat "$H/state/.lock")"
  assert_equals 2 "$("$REAL_TMUX" -f /dev/null -L "$SOCKET" list-windows -t "=wd$CASE_N" | wc -l | tr -d ' ')" "the new window joins the old session"
  pass "agent gone: a dead lock holder with a recorded anchor still restarts"
}

test_dead_holder_is_not_hidden_by_earlier_symptoms() {
  make_home $'work output\n● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss' "restart=on
restart-command=$TMP_ROOT/fake-captain.sh"
  write_fake_captain
  transcript 3000 "Working." "Testing." "Green."
  owe_input 3000
  : > "$H/state/.afk"
  printf 'needs-decision [at=%s] [key=cache-layout]: A or B?\n' "$((BASE - 9000))" > "$H/state/t1.status"
  kill_holder_with_anchor
  run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows agent-gone restart pending)" "a dead holder restarts with input waiting and a stale dialog: $(ledger | cut -f5-8)"
  wait_pickup || fail "the new captain never proved pickup"
  LOCK_PIDS="$LOCK_PIDS $(cat "$H/state/.lock")"
  assert_equals "" "$(cat "$H/typed.log")" "nothing is typed into the pane a dead holder left"
  assert_equals 1 "$(ledger | wc -l | tr -d ' ')" "the restart is the only action: $(ledger | cut -f5-8)"

  make_home $'Captain session\n> ' "restart=on
restart-command=$TMP_ROOT/fake-captain.sh"
  transcript 100 "Working." "Testing." "Green."
  owe_input 3000
  kill_holder_with_anchor
  run_wd 0 once >/dev/null 2>&1
  assert_equals "" "$(ledger)" "a recently dead holder gets no action yet"
  assert_grep "lock holder is dead" "$H/data/watchdog/status.md" "the wait is a reported gap"
  sleep 1
  assert_equals "" "$(cat "$H/typed.log")" "nothing is typed while the dead holder's quiet time runs"
  pass "agent gone comes before every other symptom, and a dead holder's endpoint gets no typing"
}

test_low_context_waits_for_full_handoff_then_restarts() {
  make_home $'Captain session\n> \n  7% until auto-compact' "restart=on
restart-command=$TMP_ROOT/fake-captain.sh"
  write_fake_captain
  transcript 3000 "Working." "Testing." "Green."
  FM_WD_TEST_COMPOSER=empty run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows handoff-request nudge pending)" "low context first asks for a full handoff"
  assert_equals 0 "$(ledger_rows restart-requested restart pending)" "the nudge comes before any restart"
  wait_typed ": fm-op " || wait_typed "operational-inbox" || fail "the handoff nudge never reached the pane: $(cat "$H/typed.log")"
  grep -Fq '.watchdog-restart-request' "$H/state/operational-inbox/"*.msg || fail "the delivered nudge does not name the request file"
  FM_WD_TEST_COMPOSER=empty run_wd 120 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows restart-requested restart pending)" "no restart inside the wait"
  : > "$H/data/handoff-full.md"
  fm_touch_epoch "$((BASE + 150))" "$H/data/handoff-full.md"
  FM_WD_TEST_COMPOSER=empty run_wd 200 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows restart-requested restart pending)" "a handoff without the request file is not enough"
  : > "$H/state/.watchdog-restart-request"
  fm_touch_epoch "$((BASE + 210))" "$H/state/.watchdog-restart-request"
  FM_WD_TEST_COMPOSER=empty run_wd 240 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows restart-requested restart pending)" "a newer handoff plus the request file allows the restart: $(ledger | cut -f5-8)"
  assert_equals 0 "$(ledger_rows handoff-request nudge timed-out)" "a written handoff is no gap"
  wait_pickup || fail "the new captain never proved pickup"
  LOCK_PIDS="$LOCK_PIDS $(cat "$H/state/.lock")"
  grep -Fq "$(cd -P "$H" && pwd -P)/data/handoff-full.md" "$H/data/watchdog/handoffs/"*.md || fail "the restart handoff does not name the full handoff"
  pass "low context: nudge, wait, and restart only on a newer full handoff plus the request file"
}

test_low_context_timeout_restarts_with_lean_handoff() {
  make_home $'Captain session\n> \n  7% until auto-compact' "restart=on
handoff-wait-secs=600
restart-command=$TMP_ROOT/fake-captain.sh"
  write_fake_captain
  transcript 3000 "Working." "Testing." "Green."
  : > "$H/data/handoff-old.md"
  fm_touch_epoch "$((BASE - 500))" "$H/data/handoff-old.md"
  FM_WD_TEST_COMPOSER=empty run_wd 0 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=empty run_wd 599 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows restart-requested restart pending)" "an older handoff does not end the wait"
  FM_WD_TEST_COMPOSER=empty run_wd 700 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows restart-requested restart pending)" "the timeout restarts: $(ledger | cut -f5-8)"
  assert_equals 1 "$(ledger_rows handoff-request nudge timed-out)" "the missed handoff is recorded"
  assert_grep "uses the lean handoff" "$H/data/watchdog/status.md" "the gap is in the status file"
  wait_pickup || fail "the new captain never proved pickup"
  LOCK_PIDS="$LOCK_PIDS $(cat "$H/state/.lock")"
  pass "low context: the bounded wait ends in a lean restart and a recorded gap"
}

test_no_activity_source_is_not_reported_ok() {
  make_home $'Captain session\n> '
  run_wd 0 once >/dev/null 2>&1
  assert_grep "NO-ACTIVITY-SOURCE" "$H/data/watchdog/status.md" "the health line does not read ok"
  assert_no_grep ": ok" "$H/data/watchdog/status.md" "a subject with no activity source never reads ok"
  assert_grep "no activity source" "$H/data/watchdog/status.md" "the limit is a reported gap"
  transcript 100 "Working."
  run_wd 10 once >/dev/null 2>&1
  assert_grep ": ok" "$H/data/watchdog/status.md" "a subject with a transcript reads ok"
  pass "a subject with no activity source reads as a gap, not ok"
}

test_tmux_restart_survives_a_closed_session() {
  make_home $'Captain session\n> ' "restart=on
max-nudges=0
restart-command=$TMP_ROOT/fake-captain.sh"
  write_fake_captain
  local sess="wd$CASE_N"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" list-panes -t "=$sess" -F '#{pane_pid}' | head -n 1 > "$H/state/.lock"
  transcript 3000 "Working." "Testing." "Green."
  owe_input 3000
  run_wd 0 once >/dev/null 2>&1
  run_wd 1000 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows frozen restart pending)" "the captain that is its pane's own command restarts: $(ledger | cut -f5-8)"
  wait_pickup || fail "no new captain after its session closed: $(ledger | cut -f5-8)"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" has-session -t "=$sess" || fail "the old session name was not reused"

  make_home $'Captain session\n> ' "restart=on
restart-command=$TMP_ROOT/fake-captain.sh"
  transcript 3000 "Working." "Testing." "Green."
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" kill-session -t "=wd$CASE_N"
  kill_holder_with_anchor
  run_wd 0 once >/dev/null 2>&1
  wait_pickup || fail "no new captain after its pane was already gone: $(ledger | cut -f5-8)"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" has-session -t "=firstmate-home$CASE_N" || fail "no session opened for a captain whose pane was gone"
  pass "tmux restart: resolves the session before the stop and opens one when the old session closed"
}

test_dismissed_dialog_in_scrollback_is_not_showing() {
  make_home $'Captain session\n> '
  # The survey was answered and the screen cleared; tmux keeps it in history.
  cat > "$H/agent.sh" <<SH
#!/usr/bin/env bash
printf 'work output\n● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss\n'
sleep 0.3
clear
printf 'work output\n> \n'
exec sleep 100000
SH
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" respawn-pane -k -t "$T" "$H/agent.sh"
  sleep 1
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" capture-pane -p -t "$T" -S -60 | grep -Fq 'How is Claude doing' ||
    fail "the fixture lost the survey from history, so this case would be vacuous"
  run_wd 0 once >/dev/null 2>&1
  ledger | grep -q dialog && fail "a survey left in scrollback was treated as showing: $(ledger)"
  pass "a dismissed dialog that only remains in scrollback is not read as showing"
}

test_dialog_keys_stop_after_two_failures() {
  make_home $'work output\n● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss'
  run_wd 0 once >/dev/null 2>&1
  run_wd 200 once >/dev/null 2>&1
  run_wd 400 once >/dev/null 2>&1
  assert_equals 2 "$(ledger_rows dialog key failed)" "two keys that left the dialog showing are recorded as failed"
  assert_equals 2 "$(ledger_rows dialog key pending)" "no third key is pressed within the hour"
  assert_grep "no more keys pressed" "$H/data/watchdog/status.md" "the stuck dialog is reported"
  pass "dialog keys stop after two failures in an hour, so a misread screen is never typed into repeatedly"
}

status_actions() {
  awk '/^## Actions/ { f = 1; next } /^## / { f = 0 } f && /^- /' "$H/data/watchdog/status.md" | wc -l | tr -d ' '
}

test_status_file_short_and_staleness_visible() {
  make_home $'Captain session\n> '
  local i
  mkdir -p "$H/state/watchdog"
  for i in $(seq 1 30); do
    printf '%s\tid%s\t%s\thome\tfrozen\tnudge\tdry-run\tx\n' "$BASE" "$i" "$(cd -P "$H" && pwd -P)" >> "$H/state/watchdog/actions.tsv"
  done
  run_wd 5 once >/dev/null 2>&1
  [ "$(wc -l < "$H/data/watchdog/status.md")" -lt 40 ] || fail "status file is 40 lines or more"
  assert_grep "STALE IF NOT UPDATED BY" "$H/data/watchdog/status.md" "staleness is visible"
  assert_grep "## Homes" "$H/data/watchdog/status.md" "per-home health"
  assert_grep "## Actions since last read" "$H/data/watchdog/status.md" "actions section"
  assert_grep "## Open gaps" "$H/data/watchdog/status.md" "gaps section"
  assert_equals 10 "$(status_actions)" "actions since last read are listed, capped"
  run_wd 6 ack-read
  run_wd 7 once >/dev/null 2>&1
  assert_equals 0 "$(status_actions)" "acknowledged actions drop out"
  pass "status file stays under 40 lines with timestamp, health, actions since last read, gaps, and a staleness line"
}

test_never_merges_deploys_or_messages_owner() {
  # Every act-mode case above ran with gh, gh-axi, notifiers, and mail faked.
  assert_no_grep "merge" "$CALLS_LOG" "the watchdog invoked a merge"
  assert_no_grep "deploy" "$CALLS_LOG" "the watchdog invoked a deploy"
  assert_no_grep "osascript" "$CALLS_LOG" "the watchdog notified the owner"
  assert_no_grep "terminal-notifier" "$CALLS_LOG" "the watchdog notified the owner"
  assert_no_grep "mail" "$CALLS_LOG" "the watchdog mailed the owner"
  local h
  for h in "$TMP_ROOT"/home*; do
    ls "$h/state/inbox/"*.note >/dev/null 2>&1 && fail "the watchdog wrote a captain inbox note in $h"
  done
  pass "boundary: across every act-mode case, no merge, deploy, owner notification, or captain note"
}

test_manager_units() {
  make_home $'x'
  local plist
  plist=$(run_wd 0 render-launchd)
  assert_contains "$plist" "<string>run</string>" "plist runs the loop"
  assert_contains "$plist" "<key>PATH</key>" "plist carries PATH"
  assert_contains "$plist" "$(cd -P "$H" && pwd -P)" "plist carries FM_HOME"
  if command -v plutil >/dev/null 2>&1; then
    printf '%s\n' "$plist" > "$H/unit.plist"
    plutil -lint "$H/unit.plist" >/dev/null || fail "plist does not lint"
  fi
  assert_contains "$(run_wd 0 render-systemd)" "Restart=always" "systemd unit restarts"
  assert_contains "$(run_wd 0 manager-name)" "firstmate-watchdog-" "manager name"
  pass "launchd and systemd units run outside every session with FM_HOME and PATH"
}

fm_test_run \
  test_dialog_detection \
  test_dismissed_dialog_in_scrollback_is_not_showing \
  test_dialog_keys_stop_after_two_failures \
  test_loop_verdicts \
  test_stall_proof_and_text_guards \
  test_frozen_pane_nudges_once_then_rate_limits \
  test_do_not_touch_never_typed \
  test_merge_autosuggestion_never_accepted \
  test_unreadable_draft_never_gets_enter \
  test_owner_reserved_holds_stay_held_and_council_settles_the_rest \
  test_split_council_gives_no_ruling \
  test_judge_fallback_and_spend_cap \
  test_no_model_still_acts_and_reports_gap \
  test_timer_loop_needs_owed_input \
  test_restart_vetoed_by_running_turn \
  test_restart_verified_pickup_and_loop_stop \
  test_no_action_while_restart_awaits_pickup \
  test_dead_captain_restarts_despite_its_anchor \
  test_dead_holder_is_not_hidden_by_earlier_symptoms \
  test_low_context_waits_for_full_handoff_then_restarts \
  test_low_context_timeout_restarts_with_lean_handoff \
  test_no_activity_source_is_not_reported_ok \
  test_tmux_restart_survives_a_closed_session \
  test_status_file_short_and_staleness_visible \
  test_manager_units \
  test_never_merges_deploys_or_messages_owner
