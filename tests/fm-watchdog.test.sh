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
  FM_TEST_SEAM=1 FM_WD_TEST_COMPOSER="${FM_WD_TEST_COMPOSER:-empty}" FM_WD_NOW=$((BASE + off)) FM_HOME="$H" bash "$WD" "$@"
}

home_key() { local c; c=$(cd -P "$H" && pwd -P); printf '%s-%s' "$(basename "$c")" "$(printf '%s' "$c" | cksum | cut -d ' ' -f 1)"; }
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
  local limit
  for limit in "You hit your weekly limit." "You've hit your session limit" "Claude usage limit reached" "You are out of credits" "Switch to another model?"; do
    assert_equals model-switch "$(lib fm_wd_pane_dialog "$limit"$'\n ❯ 1. Wait\n   2. Stop\n\nEnter to confirm · Esc to cancel')" "limit picker: $limit"
  done
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
  local word
  for word in "redeploy the staging service" "gh pr merge 5" "enable automerge on PR 5" "cut a prerelease" "republish the package" "REDEPLOY now" "remerge it" "premerge it" "undeploy it"; do
    ! lib fm_wd_text_allowed "$word" || fail "text guard let through: $word"
    lib fm_wd_reserved "$word" || fail "reserved check let through: $word"
  done
  for word in "handle the emergency" "submerge the raft" "re-emerge later"; do
    lib fm_wd_text_allowed "$word" || fail "text guard over-refused: $word"
    ! lib fm_wd_reserved "$word" || fail "reserved check over-refused: $word"
  done
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
  local entry link off
  for entry in link 'link home' slash; do
    make_home $'Captain session\n> ' 'restart=on
restart-command=/bin/true'
    link="$(dirname "$H")/$entry-$$"
    rm -f "$link"
    ln -s "$H" "$link"
    [ "$entry" != slash ] || link="$H/"
    printf 'do-not-touch=%s\n' "$link" >> "$H/config/watchdog"
    transcript 5000 "Working." "Testing." "Green."
    owe_input 5000
    for off in 0 1000 2000 3000 4000; do run_wd "$off" once >/dev/null 2>&1; done
    assert_equals 0 "$(ledger | awk -F'\t' '$6 == "nudge" && $7 == "pending"' | wc -l | tr -d ' ')" "no nudge goes out for $entry: $(ledger | cut -f5-8)"
    assert_equals 0 "$(ledger_rows frozen restart pending)" "no restart runs for $entry: $(ledger | cut -f5-8)"
    [ "$(ledger | awk -F'\t' '$7 == "refused" && $8 ~ /do-not-touch/' | wc -l | tr -d ' ')" -ge 1 ] || fail "the refusal is not recorded for $entry: $(ledger | cut -f5-8)"
    sleep 1
    assert_equals "" "$(cat "$H/typed.log")" "nothing is typed for $entry"
    rm -f "$(dirname "$H")/$entry-$$"
  done
  pass "boundary: never types into a pane on the do-not-touch list"
}

test_draft_rows_are_the_draft_alone() {
  local rule='──────────'
  assert_equals $'> first\n  then enter plan mode\n  third' "$(lib fm_wd_draft_rows "> first"$'\n  then enter plan mode\n  third\n'"$rule"$'\n  ? for shortcuts')" "a footer word inside a draft does not cut it"
  assert_equals $'> first\n  accept edits later' "$(lib fm_wd_draft_rows $'old row\n> first\n  accept edits later\n  ? for shortcuts\n  7% until auto-compact')" "with no rule, only trailing footer rows drop"
  assert_equals $'> merge #5\n> ok' "$(lib fm_wd_draft_rows "> merge #5"$'\n> ok\n'"$rule"$'\n  ? for shortcuts')" "a second prompt glyph in a draft does not cut it"
  assert_equals $'> keep going\n ──────\n merge #5' "$(lib fm_wd_draft_rows "old"$'\n'"$rule"$'\n> keep going\n ──────\n merge #5\n'"$rule"$'\n ? for shortcuts')" "an inner rule does not end the draft"
  assert_equals $'› keep going\n ────\n merge #5' "$(lib fm_wd_draft_rows $'› keep going\n ────\n merge #5\n 100% context left')" "with no closing rule, rows under an inner rule stay in the note"
  assert_equals $'> keep going\n ──────\n merge #5' "$(lib fm_wd_draft_rows $'> keep going\n ──────\n merge #5\n ? for shortcuts')" "an inner rule above text is not closing"
  assert_equals $'> merge #5\n'"$rule"$'\n> ok\n  footer' "$(lib fm_wd_prompt_tail "old"$'\n> merge #5\n'"$rule"$'\n> ok\n  footer')" "the guard reads from the first prompt row to the end"
  lib fm_wd_draft_readable "│ > finish the summary │" || fail "a bordered prompt row is readable"
  LC_ALL=C lib fm_wd_draft_readable "│ > finish the summary │" || fail "a bordered prompt row is readable in the C locale"
  assert_equals "│ > finish the summary │" "$(lib fm_wd_draft_rows "╭──────╮"$'\n│ > finish the summary │\n'"╰──────╯")" "a box leaves only its text row"
  assert_equals "> now" "$(lib fm_wd_draft_rows "> sent earlier"$'\n'"$rule"$'\n> now\n'"$rule")" "a rule above the prompt ends the conversation"
  pass "draft rows: from the prompt row to the rule, and no footer word cuts them"
}

test_merge_autosuggestion_never_accepted() {
  make_home $'Captain session\n> merge #12'
  FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=pending run_wd 300 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=pending run_wd 400 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows pasted-input key refused)" "pending merge text is refused once per window"
  sleep 1
  assert_equals "" "$(cat "$H/typed.log")" "Enter was never pressed on merge #12"
  local HOLD_STATUS="$H/status.merge"
  cp "$H/data/watchdog/status.md" "$HOLD_STATUS"
  make_home $'Captain session\n> continue with the plan'
  FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=pending run_wd 300 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows pasted-input key pending)" "ordinary unsent text gets Enter"
  for _ in $(seq 1 25); do [ -s "$H/typed.log" ] && break; sleep 0.2; done
  [ -s "$H/typed.log" ] || fail "Enter never reached the pane"
  assert_grep "unsent draft names a merge" "$HOLD_STATUS" "the refusal is reported as a gap"

  make_home $'PR #41 merged and the release went out.\n> finish the summary'
  FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=pending run_wd 300 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows pasted-input key pending)" "a merge word in conversation does not block the draft: $(ledger | cut -f5-8)"

  make_home $'Captain session\n> first row\n  then enter plan mode\n  merge #5\n──────────\n  ? for shortcuts'
  FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=pending run_wd 300 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows pasted-input key pending)" "a footer word cannot hide a merge word from Enter: $(ledger | cut -f5-8)"
  assert_equals 1 "$(ledger_rows pasted-input key refused)" "the draft is refused: $(ledger | cut -f5-8)"
  assert_grep "unsent draft names a merge" "$H/data/watchdog/status.md" "the draft refusal is a gap"

  local draft
  for draft in "redeploy the staging service" "gh pr merge 5" "enable automerge on PR 5" "cut a prerelease" "republish the package"; do
    make_home "Captain session"$'\n'"> $draft"
    FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
    FM_WD_TEST_COMPOSER=pending run_wd 300 once >/dev/null 2>&1
    assert_equals 1 "$(ledger_rows pasted-input key refused)" "the draft is refused: $draft: $(ledger | cut -f5-8)"
    assert_equals 0 "$(ledger_rows pasted-input key pending)" "the draft gets no Enter: $draft"
    sleep 1
    assert_equals "" "$(cat "$H/typed.log")" "Enter was never pressed on: $draft"
  done

  local window
  for window in \
    $'old\n──────────\n> keep going\n ──────\n merge #5\n──────────\n ? for shortcuts' \
    $'› keep going\n ────\n merge #5\n 100% context left' \
    $'> keep going\n ──────\n merge #5\n ? for shortcuts' \
    $'> merge #5\n──────────\n> ok\n──────────\n ? for shortcuts'; do
    make_home "$window"
    FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
    FM_WD_TEST_COMPOSER=pending run_wd 300 once >/dev/null 2>&1
    assert_equals 0 "$(ledger_rows pasted-input key pending)" "no rule hides a merge word from Enter: $window: $(ledger | cut -f5-8)"
    assert_equals 1 "$(ledger_rows pasted-input key refused)" "the draft is refused: $window: $(ledger | cut -f5-8)"
    sleep 1
    assert_equals "" "$(cat "$H/typed.log")" "Enter was never pressed: $window"
  done

  make_home "╭──────╮"$'\n│ > finish the summary │\n'"╰──────╯"
  FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=pending run_wd 300 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows pasted-input key pending)" "a clean bordered draft gets Enter: $(ledger | cut -f5-8)"
  assert_equals 0 "$(ledger_rows pasted-input key refused)" "a clean bordered draft is not refused"
  ! grep -q 'paste placeholder or taller' "$H/data/watchdog/status.md" || fail "a bordered draft reads as unreadable"

  make_home "╭──────╮"$'\n│ > merge #5 │\n'"╰──────╯"
  FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=pending run_wd 300 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows pasted-input key pending)" "a bordered merge draft gets no Enter: $(ledger | cut -f5-8)"
  assert_equals 1 "$(ledger_rows pasted-input key refused)" "a bordered merge draft is refused"
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
  assert_grep "unanimous" "$H/data/watchdog/rulings/$(home_key)-t1-cache-layout.md" "ruling records unanimity"
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
  assert_present "$H/state/watchdog/escalated/$(home_key)" "a restart loop escalates"
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
  assert_absent "$H/state/watchdog/escalated/$(home_key)" "a normal restart is no restart loop"
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

test_low_context_second_episode_asks_again() {
  make_home $'Captain session\n> \n  7% until auto-compact' "restart=on
restart-command=/bin/true"
  transcript 3000 "Working." "Testing." "Green."
  FM_WD_TEST_COMPOSER=empty run_wd 0 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=empty run_wd 1300 once >/dev/null 2>&1
  assert_equals 2 "$(ledger_rows handoff-request nudge pending)" "a later low asks for a full handoff again"
  assert_equals 0 "$(ledger_rows restart-requested restart pending)" "a later low does not restart on the old nudge: $(ledger | cut -f5-8)"
  kill -0 "$LOCKPID" 2>/dev/null || fail "the session was stopped without being asked"
  pass "low context: an old nudge does not count for a later low"
}

test_low_context_undelivered_nudge_starts_no_wait() {
  make_home $'Captain session\n> [Pasted text #1 +40 lines]\n  7% until auto-compact' "restart=on
restart-command=/bin/true"
  transcript 3000 "Working." "Testing." "Green."
  FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=pending run_wd 1000 once >/dev/null 2>&1
  assert_equals 0 "$(ledger | awk -F'\t' '$5 == "handoff-request"' | wc -l | tr -d ' ')" "no nudge goes at an unreadable draft"
  assert_equals 1 "$(ledger_rows pasted-input key refused)" "an unreadable draft gets no Enter: $(ledger | cut -f5-8)"
  assert_equals 0 "$(ledger_rows restart-requested restart pending)" "a refused nudge starts no wait: $(ledger | cut -f5-8)"
  assert_grep "Enter not pressed" "$H/data/watchdog/status.md" "the held draft is a reported gap"
  kill -0 "$LOCKPID" 2>/dev/null || fail "the session with an unsent draft was stopped"
  FM_WD_TEST_COMPOSER=empty run_wd 2000 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows handoff-request nudge pending)" "the nudge goes out once the composer is empty"
  pass "low context: only a delivered nudge starts the handoff wait"
}

test_restart_interval_holds_without_escalating() {
  make_home $'Captain session\n> ' "restart=on
restart-command=$TMP_ROOT/fake-captain.sh"
  write_fake_captain
  transcript 3000 "Working." "Testing." "Green."
  local home
  home=$(cd -P "$H" && pwd -P)
  mkdir -p "$H/state/watchdog"
  printf '%s\tx1\t%s\thome\tfrozen\trestart\tpending\ttoken=ab old_pid=1\n%s\tx1\t%s\thome\tfrozen\trestart\tdone\tverified\n' \
    "$((BASE - 1800))" "$home" "$((BASE - 1700))" "$home" > "$H/state/watchdog/actions.tsv"
  : > "$H/state/.watchdog-restart-request"
  fm_touch_epoch "$((BASE - 10))" "$H/state/.watchdog-restart-request"
  run_wd 0 once >/dev/null 2>&1
  run_wd 10 once >/dev/null 2>&1
  assert_absent "$H/state/watchdog/escalated/$(home_key)" "one earlier restart is no loop: $(ledger | cut -f5-8)"
  assert_equals 0 "$(ledger_rows restart-requested restart pending)" "the minimum interval holds a restart"
  assert_grep "restart held" "$H/data/watchdog/status.md" "the hold is a reported gap"
  run_wd 5500 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows restart-requested restart pending)" "the restart runs after restart-secs: $(ledger | cut -f5-8)"
  wait_pickup || fail "the new captain never proved pickup"
  LOCK_PIDS="$LOCK_PIDS $(cat "$H/state/.lock")"
  pass "restart-secs holds a sooner restart across symptoms, and only max-restarts escalates"
}

test_cleared_dialog_records_the_key_as_done() {
  make_home $'Captain session\n> '
  cat > "$H/agent.sh" <<SH
#!/usr/bin/env bash
printf 'work output\n● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss\n'
stty -echo raw
dd bs=1 count=1 of=/dev/null 2>/dev/null
stty sane -echo
clear
printf '> \n'
exec cat >> "$H/typed.log"
SH
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" respawn-pane -k -t "$T" "$H/agent.sh"
  sleep 0.5
  FM_WD_TEST_COMPOSER=empty run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows dialog key "done")" "the dismissed survey records done: $(ledger | cut -f5-8)"
  assert_equals 0 "$(ledger_rows dialog key failed)" "a cleared dialog is no failed key"
  pass "dialog: a key that clears the dialog is recorded as done"
}

test_low_context_asks_nothing_when_no_restart_can_run() {
  make_home $'Captain session\n> \n  7% until auto-compact'
  transcript 3000 "Working." "Testing." "Green."
  FM_WD_TEST_COMPOSER=empty run_wd 0 once >/dev/null 2>&1
  assert_equals 0 "$(ledger | awk -F'\t' '$5 == "handoff-request"' | wc -l | tr -d ' ')" "restart off asks for no handoff: $(ledger | cut -f5-8)"
  assert_grep "restart is off" "$H/data/watchdog/status.md" "restart off is a gap"

  make_home $'Captain session\n> \n  7% until auto-compact' 'restart=on
restart-command=/bin/true'
  transcript 3000 "Working." "Testing." "Green."
  mkdir -p "$H/state/watchdog/escalated"
  printf '%s\n' "$BASE" > "$H/state/watchdog/escalated/$(home_key)"
  FM_WD_TEST_COMPOSER=empty run_wd 0 once >/dev/null 2>&1
  assert_equals 0 "$(ledger | awk -F'\t' '$5 == "handoff-request"' | wc -l | tr -d ' ')" "an escalated home asks for no handoff"
  assert_grep "escalated" "$H/data/watchdog/status.md" "escalation is a gap"
  pass "low context: no handoff is asked for when no restart can run"
}

test_restart_request_does_not_shadow_frozen_recovery() {
  make_home $'Captain session\n> '
  transcript 3000 "Working." "Testing." "Green."
  owe_input 3000
  : > "$H/state/.watchdog-restart-request"
  fm_touch_epoch "$((BASE - 10))" "$H/state/.watchdog-restart-request"
  FM_WD_TEST_COMPOSER=empty run_wd 0 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=empty run_wd 1000 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows frozen nudge pending)" "the frozen nudge still goes out: $(ledger | cut -f5-8)"

  local extra
  for extra in 'restart=on' 'do-not-touch=home'; do
    make_home $'Captain session\n> ' "$extra"
    [ "$extra" = restart=on ] || printf 'restart=on\nrestart-command=/bin/true\ndo-not-touch=%s\n' "$T" >> "$H/config/watchdog"
    transcript 3000 "Working." "Testing." "Green."
    owe_input 3000
    : > "$H/state/.watchdog-restart-request"
    fm_touch_epoch "$((BASE - 10))" "$H/state/.watchdog-restart-request"
    run_wd 0 once >/dev/null 2>&1
    run_wd 1000 once >/dev/null 2>&1
    assert_equals 1 "$(ledger | awk -F'\t' '$5 == "frozen" && $6 == "nudge"' | wc -l | tr -d ' ')" "frozen handling runs with $extra: $(ledger | cut -f5-8)"
    assert_grep "no handoff is asked for" "$H/data/watchdog/status.md" "the unrunnable restart is a gap"
  done

  make_home $'Captain session\n> ' 'restart=on
restart-command=/bin/true'
  owe_input 3000
  : > "$H/state/.watchdog-restart-request"
  fm_touch_epoch "$((BASE - 10))" "$H/state/.watchdog-restart-request"
  run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows unread-input nudge pending)" "no activity source leaves unread input handled: $(ledger | cut -f5-8)"

  make_home $'Captain session\n> ' 'restart=on
restart-command=/bin/true'
  owe_input 3000
  transcript 100 "Working."
  : > "$H/state/.watchdog-restart-request"
  fm_touch_epoch "$((BASE - 10))" "$H/state/.watchdog-restart-request"
  jq -n --arg s "$SID" --argjson e "$BASE" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:"herdr",target:"pane-1",present:true},session:{trusted_id:$s}}}' \
    > "$H/state/heartbeat.json"
  run_wd 0 once >/dev/null 2>&1
  assert_grep "has no restart launcher" "$H/data/watchdog/status.md" "an unsupported backend is a gap"
  assert_equals 1 "$(ledger | awk -F'\t' '$5 == "unread-input" && $6 == "nudge"' | wc -l | tr -d ' ')" "an unsupported backend leaves unread input handled: $(ledger | cut -f5-8)"
  pass "a restart request that cannot run leaves frozen recovery in place"
}

test_held_nudges_reach_the_restart_proof() {
  local state
  for state in pending-unproven unknown; do
    make_home $'Captain session\n> ' 'restart=on
restart-command=/bin/true'
    transcript 5000 "Working." "Testing." "Green."
    owe_input 5000
    local off
    for off in 0 1000 2000 3000; do FM_WD_TEST_COMPOSER=$state run_wd "$off" once >/dev/null 2>&1; done
    assert_equals 2 "$(ledger_rows frozen nudge held)" "$state holds two nudges: $(ledger | cut -f5-8)"
    assert_equals 1 "$(ledger_rows frozen restart pending)" "$state reaches the restart: $(ledger | cut -f5-8)"
    [ ! -s "$H/typed.log" ] || fail "text was typed on a $state composer: $(cat "$H/typed.log")"
  done

  make_home $'Captain session\n> finish the summary' 'restart=on
restart-command=/bin/true'
  transcript 6000 "Working." "Testing." "Green."
  owe_input 6000
  for off in 0 1000 2000 3000 4000; do FM_WD_TEST_COMPOSER=pending run_wd "$off" once >/dev/null 2>&1; done
  assert_equals 1 "$(ledger_rows pasted-input key pending)" "a stable clean draft gets one Enter first: $(ledger | cut -f5-8)"
  assert_equals 1 "$(ledger_rows frozen restart pending)" "a draft that stays still reaches the restart: $(ledger | cut -f5-8)"
  pass "frozen: a held nudge counts toward the restart proof, and a clean draft gets Enter first"
}

test_held_nudge_restart_keeps_the_draft_or_names_the_gap() {
  local handoff off
  make_home $'Earlier conversation row\n> finish the summary\n  second row\n──────────\n  ? for shortcuts' 'restart=on
restart-command=/bin/true'
  transcript 5000 "Working." "Testing." "Green."
  owe_input 5000
  for off in 0 1000 2000 3000 4000; do FM_WD_TEST_COMPOSER=pending run_wd "$off" once >/dev/null 2>&1; done
  assert_equals 1 "$(ledger_rows frozen restart pending)" "a readable draft still restarts: $(ledger | cut -f5-8)"
  handoff=$(ls "$H/data/watchdog/handoffs/"*.md)
  assert_grep "Unsent draft at restart, never submitted" "$handoff" "the handoff marks the draft as unsubmitted"
  assert_equals $'> finish the summary\n  second row' "$(awk '/^```$/ { if (f) exit; f = 1; next } f' "$handoff")" "the draft note holds only the draft rows"
  ! grep -q '^GAP:' "$handoff" || fail "a readable draft is not a gap: $(cat "$handoff")"

  make_home $'Captain session\n> [Pasted text #3 +40 lines]' 'restart=on
restart-command=/bin/true'
  transcript 5000 "Working." "Testing." "Green."
  owe_input 5000
  for off in 0 1000 2000 3000; do FM_WD_TEST_COMPOSER=pending-unproven run_wd "$off" once >/dev/null 2>&1; done
  assert_equals 1 "$(ledger_rows frozen restart pending)" "a placeholder still restarts: $(ledger | cut -f5-8)"
  assert_equals 0 "$(ledger_rows pasted-input key pending)" "a placeholder never gets Enter"
  handoff=$(ls "$H/data/watchdog/handoffs/"*.md)
  assert_grep "GAP: an unsent draft could not be read" "$handoff" "the handoff names the lost draft"
  [ ! -s "$H/typed.log" ] || fail "text was typed on a placeholder: $(cat "$H/typed.log")"

  make_home $'Captain session\n> ' 'restart=on
restart-command=/bin/true'
  transcript 5000 "Working." "Testing." "Green."
  owe_input 5000
  jq -n --arg s "$SID" --argjson e "$BASE" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:"orca",target:"term-1",present:true},session:{trusted_id:$s}}}' \
    > "$H/state/heartbeat.json"
  cat > "$FAKEBIN/orca" <<SH
#!/usr/bin/env bash
case "\$1 \$2" in
  "terminal read") printf '{"ok":true,"result":{"terminal":{"tail":["Captain session","status row"],"draft":"finish the summary"}}}\n' ;;
  "terminal wait") printf '{"ok":true,"result":{}}\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$FAKEBIN/orca"
  for off in 0 1000 2000 3000; do FM_WD_TEST_COMPOSER=empty run_wd "$off" once >/dev/null 2>&1; done
  rm -f "$FAKEBIN/orca"
  handoff=$(ls "$H/data/watchdog/handoffs/"*.md)
  assert_grep "finish the summary" "$handoff" "a read Orca draft goes into the handoff"
  assert_grep "unsent draft or a harness suggestion" "$handoff" "a read Orca draft names both readings"
  ! grep -q '^GAP:' "$handoff" || fail "a read Orca draft is not a gap: $(cat "$handoff")"

  make_home $'\n' 'restart=on
restart-command=/bin/true'
  transcript 5000 "Working." "Testing." "Green."
  write_fake_captain
  kill_holder_with_anchor
  FM_WD_TEST_COMPOSER=unknown run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows agent-gone restart pending)" "the dead holder restarts: $(ledger | cut -f5-8)"
  handoff=$(ls "$H/data/watchdog/handoffs/"*.md)
  ! grep -Eq '^GAP:|never submitted' "$handoff" || fail "no draft was proven: $(cat "$handoff")"
  assert_grep "Composer state was unknown at restart" "$handoff" "an empty capture says the state was unknown"
  assert_grep "no draft was seen" "$handoff" "an empty capture says no draft was seen"
  ! grep -q 'lost an unreadable draft' "$H/data/watchdog/status.md" || fail "the status file claims a lost draft"

  make_home $'Captain session\n> [Pasted text #3 +40 lines]' 'restart=on
restart-command=/bin/true'
  transcript 5000 "Working." "Testing." "Green."
  write_fake_captain
  kill_holder_with_anchor
  FM_WD_TEST_COMPOSER=unknown run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows agent-gone restart pending)" "the dead holder with a placeholder row restarts: $(ledger | cut -f5-8)"
  handoff=$(ls "$H/data/watchdog/handoffs/"*.md)
  ! grep -q '^GAP:' "$handoff" || fail "a placeholder on an unknown composer is no lost draft: $(cat "$handoff")"
  assert_grep "no draft was seen" "$handoff" "an unknown composer with a placeholder says no draft was seen"
  ! grep -q 'lost an unreadable draft' "$H/data/watchdog/status.md" || fail "the status file claims a lost draft on an unknown composer"
  pass "held restart: the handoff keeps a readable draft, names an unreadable one, and claims nothing unproven"
}

test_context_burn_file_is_not_a_context_source() {
  make_home $'Captain session\n> '
  transcript 100 "Working."
  printf '%s\t%s\tuser\t5\n' "$BASE" "$SID" > "$H/state/context-burn.tsv"
  run_wd 0 once >/dev/null 2>&1
  assert_equals 0 "$(ledger | awk -F'\t' '$5 == "handoff-request" || $5 == "restart-requested"' | wc -l | tr -d ' ')" "a burn sample starts no low-context ladder: $(ledger | cut -f5-8)"
  pass "context: state/context-burn.tsv is not read"
}

test_low_context_undeliverable_nudge_leaves_frozen_recovery() {
  make_home $'Captain session\n> \n  7% until auto-compact' 'restart=on
restart-command=/bin/true'
  transcript 5000 "Working." "Testing." "Green."
  owe_input 5000
  local off
  for off in 0 1000 2000 3000; do FM_WD_TEST_COMPOSER=pending-unproven run_wd "$off" once >/dev/null 2>&1; done
  assert_equals 1 "$(ledger_rows frozen restart pending)" "the frozen ladder still reaches the restart: $(ledger | cut -f5-8)"
  pass "low context: a nudge that cannot be delivered does not hide frozen recovery"
}

test_homes_with_one_basename_keep_their_own_state() {
  local one two
  make_home $'Captain one\n> '
  one="$TMP_ROOT/a$CASE_N/firstmate"; mkdir -p "$(dirname "$one")"; mv "$H" "$one"
  H=$one; transcript 3000 "Working." "Testing." "Green."; owe_input 3000
  make_home $'Captain two\n> '
  two="$TMP_ROOT/b$CASE_N/firstmate"; mkdir -p "$(dirname "$two")"; mv "$H" "$two"
  H=$two; transcript 3000 "Working." "Testing." "Green."; owe_input 3000
  sed -i.bak "s|^claude-config-dirs=.*|claude-config-dirs=$one/claude,$two/claude|" "$one/config/watchdog"
  printf 'homes=%s,%s\n' "$one" "$two" >> "$one/config/watchdog"
  H=$one
  run_wd 0 once >/dev/null 2>&1
  run_wd 1000 once >/dev/null 2>&1
  assert_equals 2 "$(ledger_rows frozen nudge pending)" "each home keeps its own pane record: $(ledger | cut -f3,5-8)"
  assert_equals 2 "$(ls "$one/state/watchdog/subjects" | wc -l | tr -d ' ')" "one subject record per home"
  pass "homes that share a basename keep separate state"
}

test_frozen_low_context_clean_draft_gets_one_enter_then_restarts() {
  make_home $'Captain session\n> finish the summary\n  7% until auto-compact' 'restart=on
restart-command=/bin/true'
  transcript 8000 "Working." "Testing." "Green."
  owe_input 8000
  local off
  for off in 0 1000 2000 3000 4000 5000 6000; do FM_WD_TEST_COMPOSER=pending run_wd "$off" once >/dev/null 2>&1; done
  assert_equals 1 "$(ledger_rows pasted-input key pending)" "the frozen draft gets one Enter: $(ledger | cut -f5-8)"
  assert_equals 1 "$(ledger_rows frozen restart pending)" "the frozen ladder reaches the restart: $(ledger | cut -f5-8)"
  assert_equals 0 "$(ledger_rows handoff-request nudge pending)" "no handoff nudge goes onto the draft"

  make_home $'Captain session\n> finish the summary'
  transcript 100 "Working."
  for off in 0 400 800 1200; do FM_WD_TEST_COMPOSER=pending run_wd "$off" once >/dev/null 2>&1; done
  assert_equals 1 "$(ledger_rows pasted-input key pending)" "an idle draft gets one Enter: $(ledger | cut -f5-8)"
  assert_grep "no second Enter" "$H/data/watchdog/status.md" "the spent Enter is a gap"
  pass "unsent input: Enter goes once in two hours, and a frozen low-context draft reaches the restart"
}

test_restart_request_is_only_the_file() {
  make_home $'Captain session\n> ' 'restart=on
restart-command=/bin/true'
  transcript 3000 "Working." "Quoting the phrase: RESTART REQUESTED"
  run_wd 0 once >/dev/null 2>&1
  assert_equals 0 "$(ledger | awk -F'\t' '$5 == "restart-requested"' | wc -l | tr -d ' ')" "assistant text requests nothing: $(ledger | cut -f5-8)"
  pass "restart request: assistant text is not a channel"
}

test_blank_stripping_keeps_a_trailing_t() {
  assert_equals "2	Add credit" "$(lib fm_wd_dialog_options $'Pick\n ❯ 1. Wait\n   2. Add credit\n\nEnter to confirm' | tail -n 1)" "an option keeps its last letter"

  make_home $'You have hit your weekly limit for Opus.\n\n ❯ 1. Switch to Sonnet\n   2. Add credit\n\nEnter to confirm · Esc to cancel' 'models=claude:haiku'
  fake_models "$H" ok:"OPTION 2" absent
  transcript 100 "Working."
  run_wd 0 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows dialog key pending)" "a credit option ending in t is refused: $(ledger | cut -f5-8)"
  assert_equals 1 "$(ledger_rows dialog key refused)" "the refusal is recorded"

  local moved
  make_home $'Captain session\n> '
  moved="${H}t"; mv "$H" "$moved"; H=$moved
  transcript 3000 "Working." "Testing." "Green."; owe_input 3000
  sed -i.bak "s|^claude-config-dirs=.*|claude-config-dirs=$H/claude|" "$H/config/watchdog"
  printf 'homes=%s\n' "$H" >> "$H/config/watchdog"
  run_wd 0 once >/dev/null 2>&1
  run_wd 1000 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows frozen nudge pending)" "a home path ending in t is watched: $(ledger | cut -f3,5-8)"

  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED T" ok:"PROCEED T"
  transcript 100 "Working."
  printf 'needs-decision [at=%s] [key=cache-layout]: T (recommended) flat keys or B nested keys?\n' "$((BASE - 9000))" > "$H/state/t1.status"
  run_wd 0 once >/dev/null 2>&1
  run_wd 2000 once >/dev/null 2>&1
  [ -f "$H/data/watchdog/rulings/$(home_key)-t1-cache-layout.md" ] || fail "a verdict ending in T read as failed: $(cat "$H/state/watchdog/model-calls.tsv")"
  pass "sed blank classes keep a trailing t in options, homes, and verdicts"
}

test_low_context_submits_a_clean_draft_then_nudges() {
  make_home $'Captain session\n> finish the summary\n  7% until auto-compact' 'restart=on
restart-command=/bin/true'
  transcript 3000 "Working." "Testing." "Green."
  FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=pending run_wd 1000 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows pasted-input key pending)" "the clean draft gets Enter: $(ledger | cut -f5-8)"
  FM_WD_TEST_COMPOSER=empty run_wd 2000 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows handoff-request nudge pending)" "the nudge follows the submitted draft: $(ledger | cut -f5-8)"
  pass "low context: a clean draft is submitted so the handoff nudge can follow"
}

test_stale_or_foreign_heartbeat_percent_is_ignored() {
  local case_sid age
  for case_sid in old other; do
    make_home $'Captain session\n> ' 'restart=on
restart-command=/bin/true'
    transcript 3000 "Working." "Testing." "Green."
    age=0
    [ "$case_sid" = old ] && age=2000
    jq -n --arg t "$T" --arg s "$([ "$case_sid" = other ] && printf 'another-session' || printf '%s' "$SID")" --argjson e "$((BASE - age))" \
      '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:"tmux",target:$t,present:true},session:{trusted_id:$s},context_left:{remaining:{percent:7}}}}' \
      > "$H/state/heartbeat.json"
    FM_WD_TEST_COMPOSER=empty run_wd 0 once >/dev/null 2>&1
    assert_equals 0 "$(ledger_rows handoff-request nudge pending)" "$case_sid heartbeat percent starts nothing: $(ledger | cut -f5-8)"
  done
  jq -n --arg t "$T" --arg s "$SID" --argjson e "$BASE" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:"tmux",target:$t,present:true},session:{trusted_id:$s},context_left:{remaining:{percent:7}}}}' \
    > "$H/state/heartbeat.json"
  FM_WD_TEST_COMPOSER=empty run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows handoff-request nudge pending)" "a fresh percent for this session counts: $(ledger | cut -f5-8)"
  pass "heartbeat percent counts only when fresh and for the current session"
}

test_orca_draft_probe_failure_holds_the_nudge() {
  make_home $'Captain session\n> '
  transcript 3000 "Working." "Testing." "Green."
  owe_input 3000
  jq -n --arg s "$SID" --argjson e "$BASE" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:"orca",target:"term-1",present:true},session:{trusted_id:$s}}}' \
    > "$H/state/heartbeat.json"
  cat > "$FAKEBIN/orca" <<SH
#!/usr/bin/env bash
case "\$1 \$2" in
  "terminal read")
    case " \$* " in
      *" --limit 60 "*) printf '{"ok":true,"result":{"terminal":{"tail":["Captain session","> "]}}}\n' ;;
      *" --limit 5 "*) printf '{"ok":true,"result":{"terminal":{"tail":[]}}}\n' ;;
      *) exec sleep 12 ;;
    esac ;;
  "terminal wait") printf '{"ok":true,"result":{}}\n' ;;
  "terminal send") printf 'send\n' >> "$H/orca-sends.log" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$FAKEBIN/orca"
  run_wd 0 once >/dev/null 2>&1
  run_wd 1000 once >/dev/null 2>&1
  rm -f "$FAKEBIN/orca"
  assert_equals 0 "$(ledger_rows frozen nudge pending)" "a hung draft read takes no nudge: $(ledger | cut -f5-8)"
  [ ! -s "$H/orca-sends.log" ] || fail "text was sent after a hung draft read"
  assert_grep "composer is pending-unproven" "$H/data/watchdog/status.md" "the hold is a gap"
  pass "orca: a draft read that hangs holds the nudge"
}

test_orca_draft_is_never_typed_onto() {
  make_home $'Captain session\n> '
  transcript 3000 "Working." "Testing." "Green."
  owe_input 3000
  jq -n --arg s "$SID" --argjson e "$BASE" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:"orca",target:"term-1",present:true},session:{trusted_id:$s}}}' \
    > "$H/state/heartbeat.json"
  cat > "$FAKEBIN/orca" <<SH
#!/usr/bin/env bash
case "\$1 \$2" in
  "terminal read") printf '{"ok":true,"result":{"terminal":{"tail":["Captain session","> "],"draft":"merge PR #12"}}}\n' ;;
  "terminal wait") printf '{"ok":true,"result":{}}\n' ;;
  "terminal send") printf 'send\n' >> "$H/orca-sends.log" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$FAKEBIN/orca"
  FM_WD_TEST_COMPOSER=empty run_wd 0 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=empty run_wd 1000 once >/dev/null 2>&1
  rm -f "$FAKEBIN/orca"
  assert_equals 0 "$(ledger_rows frozen nudge pending)" "an Orca draft takes no nudge: $(ledger | cut -f5-8)"
  [ ! -s "$H/orca-sends.log" ] || fail "text was sent onto an Orca draft"
  assert_grep "composer is pending-unproven" "$H/data/watchdog/status.md" "the hold is a gap"
  pass "orca: a draft holds the nudge and is never submitted"
}

test_reserved_task_or_key_is_held_and_refused_nudges_are_gaps() {
  make_home $'Captain session\n> '
  transcript 100 "Working."
  printf 'needs-decision [at=%s] [key=cache-layout]: A or B?\n' "$((BASE - 9000))" > "$H/state/release-notes-fix.status"
  printf 'needs-decision [at=%s] [key=merge-order]: A or B?\n' "$((BASE - 9000))" > "$H/state/t2.status"
  printf 'needs-decision [at=%s] [key=cache-size]: A or B?\n' "$((BASE - 9000))" > "$H/state/t3.status"
  run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows decisions nudge pending)" "the clean decision still gets its nudge: $(ledger | cut -f5-8)"
  assert_equals 0 "$(ledger_rows decisions nudge refused)" "a reserved task or key does not refuse the rollup"
  assert_grep "2 decisions held for the owner" "$H/data/watchdog/status.md" "both reserved names are held"

  make_home $'Captain session\n> '
  transcript 100 "Working."
  printf 'paused [at=%s]: hit the quota floor\n' "$((BASE - 9000))" > "$H/state/release-q.status"
  run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows quota:release-q nudge refused)" "the quota nudge is refused"
  assert_grep "quota:release-q held" "$H/data/watchdog/status.md" "the refused quota nudge is a gap"
  run_wd 100 once >/dev/null 2>&1
  assert_grep "quota:release-q held" "$H/data/watchdog/status.md" "the gap stays inside the nudge rate limit"
  pass "decisions: a reserved task or key is held, and a refused nudge is a gap"
}

test_second_mate_restart_ends_the_pass() {
  local parent mate
  make_home $'Captain session\n> '
  parent=$H
  make_home $'Mate session\n> '
  mate=$H
  transcript 3000 "Working." "Testing." "Green."
  : > "$mate/state/.watchdog-restart-request"
  fm_touch_epoch "$((BASE - 10))" "$mate/state/.watchdog-restart-request"
  printf -- '- ghost-mate - test mate (home: %s)\n' "$mate" > "$parent/data/secondmates.md"
  printf 'mode=act\nclaude-config-dirs=%s\nkey-settle-secs=1\nmodels=\nrestart=on\nrelaunch-timeout-secs=20\n' "$mate/claude" > "$parent/config/watchdog"
  H=$parent
  run_wd 0 once >/dev/null 2>&1
  printf 'needs-decision [at=%s] [key=cache-layout]: A or B?\n' "$((BASE - 9000))" > "$mate/state/t1.status"
  run_wd 10 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows restart-requested restart pending)" "the second mate relaunch ran: $(ledger | cut -f5-8)"
  assert_equals 0 "$(ledger_rows decisions nudge pending)" "the same pass types nothing more: $(ledger | cut -f5-8)"
  pass "second mate: a relaunch ends the pass for its old endpoint"
}

test_dialog_reserved_check_reads_only_dialog_rows() {
  local rule='────────────────────'
  make_home "Merged PR #41, deleted the branch."$'\n'"$rule"$'\nYou have hit your weekly limit for Opus.\n\n ❯ 1. Switch to Sonnet\n   2. Buy more credits\n\nEnter to confirm · Esc to cancel' 'models=claude:haiku'
  fake_models "$H" ok:"OPTION 1" absent
  transcript 100 "Working."
  run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows dialog key pending)" "conversation above a ruled limit picker does not hold it: $(ledger | cut -f5-8)"

  make_home "Merged PR #41, deleted the branch."$'\n'"$rule"$'\nWhich plan should I follow?\n ❯ 1. Plan A\n   2. Plan B\n\nEnter to select · Esc to cancel'
  transcript 100 "Working."
  run_wd 0 once >/dev/null 2>&1
  assert_equals 0 "$(ledger | awk -F'\t' '$6 == "key"' | wc -l | tr -d ' ')" "a ruled question with an Esc footer gets no key: $(ledger | cut -f5-8)"
  assert_grep "question dialog waiting" "$H/data/watchdog/status.md" "the ruled question is reported"

  make_home $'Continuing bills your card and deletes the production data.\n\nContinue after the weekly limit?\n ❯ 1. Yes\n   2. No\n\nEnter to confirm · Esc to cancel' 'models=claude:haiku'
  fake_models "$H" ok:"OPTION 1" absent
  transcript 100 "Working."
  run_wd 0 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows dialog key pending)" "a reserved paragraph with no proven boundary holds a picker: $(ledger | cut -f5-8)"
  [ ! -s "$H/model.log" ] || fail "a model saw a reserved picker: $(cat "$H/model.log")"

  local list=$'1. Merged it\n2. Deleted it\n\nWhich?\n ❯ 1. Plan A\n   2. Plan B\n\nEnter to select'
  assert_equals "2	Plan B" "$(lib fm_wd_dialog_options "$list" | tail -n 1)" "options come from the dialog"
  assert_equals 2 "$(lib fm_wd_dialog_options "$list" | wc -l | tr -d ' ')" "a numbered list above is not an option"
  pass "dialog: reserved words hold unless a rule proves they sit outside the dialog"
}

test_dialog_kind_ignores_conversation_rows() {
  local q=$'\n\nWhich task first?\n ❯ 1. Task A\n   2. Task B\n\nEnter to select · Esc to cancel'
  assert_equals question "$(lib fm_wd_pane_dialog "I told the worker to switch to sonnet.$q")" "a model name in conversation is no model switch"
  assert_equals permission "$(lib fm_wd_pane_dialog "It asked: do you want to proceed?$q")" "a permission phrase with no proven boundary holds"
  assert_equals question "$(lib fm_wd_pane_dialog $'It asked: do you want to proceed?\n──────────'"$q")" "a rule proves a permission phrase is conversation"
  assert_equals permission "$(lib fm_wd_pane_dialog $'Do you trust the files in this folder?\n\n/some/path\n\nClaude Code may read files here.\n ❯ 1. Yes, proceed\n   2. No, exit\n\nEnter to confirm · Esc to cancel')" "a trust phrase above a detail paragraph is permission"

  make_home $'Do you want to proceed?\n\ndetail row\n ❯ 1. Yes\n   2. No\n\nEnter to confirm · Esc to cancel'
  transcript 100 "Working."
  run_wd 0 once >/dev/null 2>&1
  assert_equals 0 "$(ledger | awk -F'\t' '$6 == "key"' | wc -l | tr -d ' ')" "an unproven dialog gets no Escape: $(ledger | cut -f5-8)"
  assert_grep "permission dialog waiting" "$H/data/watchdog/status.md" "the dialog left alone is reported"

  make_home "I told the worker to switch to sonnet.$q" 'models=claude:haiku'
  fake_models "$H" ok:"OPTION 1" absent
  transcript 100 "Working."
  run_wd 0 once >/dev/null 2>&1
  [ ! -s "$H/model.log" ] || fail "a judge was asked about a question: $(cat "$H/model.log")"
  [ ! -s "$H/state/watchdog/model-calls.tsv" ] || fail "a model call ran: $(cat "$H/state/watchdog/model-calls.tsv")"
  assert_equals 0 "$(ledger | awk -F'\t' '$6 == "key"' | wc -l | tr -d ' ')" "an unproven question gets no key: $(ledger | cut -f5-8)"
  assert_grep "question dialog waiting" "$H/data/watchdog/status.md" "the unproven question is reported"

  make_home $'You have hit your weekly limit.\n\nWhat should happen next?\n ❯ 1. Wait\n   2. Stop\n\nEnter to select · Esc to cancel'
  transcript 100 "Working."
  run_wd 0 once >/dev/null 2>&1
  assert_equals 0 "$(ledger | awk -F'\t' '$6 == "key"' | wc -l | tr -d ' ')" "a limit word in another paragraph proves nothing: $(ledger | cut -f5-8)"
  assert_grep "question dialog waiting" "$H/data/watchdog/status.md" "the limit screen is reported"

  make_home $'──────────\nEnable browser tools?\n ❯ 1. Yes\n   2. No\n\nEnter to confirm · Esc to keep browser tools off'
  transcript 100 "Working."
  run_wd 0 once >/dev/null 2>&1
  assert_equals 0 "$(ledger | awk -F'\t' '$6 == "key"' | wc -l | tr -d ' ')" "an Esc footer with a side effect gets no key: $(ledger | cut -f5-8)"
  assert_grep "question dialog waiting" "$H/data/watchdog/status.md" "the startup picker is reported"

  make_home $'Do you trust the files in this folder?\n\n/some/path\n\nClaude Code may read files here.\n ❯ 1. Yes, proceed\n   2. No, exit\n\nEnter to confirm · Esc to cancel'
  transcript 100 "Working."
  run_wd 0 once >/dev/null 2>&1
  assert_equals 0 "$(ledger | awk -F'\t' '$6 == "key"' | wc -l | tr -d ' ')" "a trust dialog gets no key: $(ledger | cut -f5-8)"
  assert_grep "permission dialog waiting" "$H/data/watchdog/status.md" "the trust dialog is reported"

  local screen
  for screen in \
    $'──────────\nShould the worker use Opus or Sonnet for the refactor?\n ❯ 1. Opus\n   2. Sonnet\n\nEnter to select · Esc to cancel' \
    $'──────────\nThis task burns credits fast; split it in two?\n ❯ 1. Yes\n   2. No\n\nEnter to select · Esc to cancel' \
    $'──────────\nShould the API add a rate limit to this endpoint?\n ❯ 1. Yes\n   2. No\n\nEnter to select · Esc to cancel' \
    $'──────────\nWhich usage limit should the plan page show?\n ❯ 1. 100\n   2. 200\n\nEnter to select · Esc to cancel' \
    $'──────────\nWhat should the banner say once the limit resets or the limit reached state shows?\n ❯ 1. Short\n   2. Long\n\nEnter to select · Esc to cancel' \
    $'──────────\nShould we warn when you hit your weekly limit?\n ❯ 1. Yes\n   2. No\n\nEnter to select · Esc to cancel' \
    $'──────────\nShould we switch to another database?\n ❯ 1. Yes\n   2. No\n\nEnter to select · Esc to cancel'; do
    make_home "$screen" 'models=claude:haiku'
    fake_models "$H" ok:"OPTION 1" absent
    transcript 100 "Working."
    run_wd 0 once >/dev/null 2>&1
    [ ! -s "$H/model.log" ] || fail "a judge was asked about an ordinary question: $(cat "$H/model.log")"
    assert_equals 0 "$(ledger | awk -F'\t' '$6 == "key"' | wc -l | tr -d ' ')" "an ordinary question gets no digit: $(ledger | cut -f5-8)"
    assert_grep "question dialog waiting" "$H/data/watchdog/status.md" "the ordinary question is reported"
  done
  pass "dialog: the kind comes from the dialog, not the conversation above it"
}

test_reserved_model_switch_dialog_is_held() {
  make_home $'You have hit your weekly limit; release the sonnet build to production?\n ❯ 1. Yes\n   2. No\n\nEnter to confirm · Esc to cancel' 'models=claude:haiku'
  fake_models "$H" ok:"OPTION 1" absent
  transcript 100 "Working."
  run_wd 0 once >/dev/null 2>&1
  assert_equals 0 "$(ledger | awk -F'\t' '$6 == "key"' | wc -l | tr -d ' ')" "no key goes to a reserved dialog: $(ledger | cut -f5-8)"
  [ ! -s "$H/model.log" ] || fail "a model saw a reserved dialog: $(cat "$H/model.log")"
  [ ! -s "$H/typed.log" ] || fail "something was typed: $(cat "$H/typed.log")"
  assert_grep "owner-reserved category; held" "$H/data/watchdog/status.md" "the hold is a gap"

  make_home $'You have hit your weekly limit for Opus.\n\n ❯ 1. Switch to Sonnet\n   2. Buy more credits\n\nEnter to confirm · Esc to cancel' 'models=claude:haiku'
  fake_models "$H" ok:"OPTION 1" absent
  transcript 100 "Working."
  run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows dialog key pending)" "an ordinary limit dialog gets its key: $(ledger | cut -f5-8)"
  pass "model-switch dialog: reserved text is held before the judge; an ordinary one still gets its key"
}

test_unknown_composer_guards_the_nudge() {
  local screen
  for screen in $'Captain session\n> merge PR #12' $'Captain session\n> [Pasted text #1 +40 lines]' $'Captain session\n> finish the summary' $'Captain session\n> '; do
    make_home "$screen"
    transcript 3000 "Working." "Testing." "Green."
    owe_input 3000
    FM_WD_TEST_COMPOSER=unknown run_wd 0 once >/dev/null 2>&1
    FM_WD_TEST_COMPOSER=unknown run_wd 1000 once >/dev/null 2>&1
    assert_equals 1 "$(ledger_rows frozen nudge held)" "an unsafe unknown composer holds the nudge: $(ledger | cut -f5-8)"
    assert_equals 0 "$(ledger_rows frozen nudge pending)" "nothing is typed onto it"
    [ ! -s "$H/typed.log" ] || fail "text was typed onto an unknown composer: $(cat "$H/typed.log")"
    assert_grep "composer is unknown" "$H/data/watchdog/status.md" "the hold is a gap"
  done
  pass "unknown composer: a nudge types only on a composer proven empty"
}

test_orca_turn_probe_keeps_errors_unknown() {
  make_home $'Captain session\n> '
  jq -n --arg s "$SID" --argjson e "$BASE" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:"orca",target:"term-1",present:true},session:{trusted_id:$s}}}' \
    > "$H/state/heartbeat.json"
  cat > "$FAKEBIN/orca" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "terminal read") printf '{"ok":true,"result":{"terminal":{"tail":["Captain session","> "]}}}\n' ;;
  "terminal wait")
    case "$ORCA_WAIT" in
      idle) printf '{"ok":true,"result":{}}\n' ;;
      timeout) printf '{"ok":false,"error":{"code":"timeout"}}\n'; exit 1 ;;
      *) printf '{"ok":false,"error":{"code":"runtime_unavailable"}}\n'; exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$FAKEBIN/orca"
  ORCA_WAIT=idle run_wd 0 scan 2>/dev/null | grep -q 'turn_running=0' || { rm -f "$FAKEBIN/orca"; fail "an idle reply reads as no turn"; }
  ORCA_WAIT=timeout run_wd 0 scan 2>/dev/null | grep -q 'turn_running=1' || { rm -f "$FAKEBIN/orca"; fail "a timeout reads as a running turn"; }
  ORCA_WAIT=error run_wd 0 scan 2>/dev/null | grep -q 'turn_running=unknown' || { rm -f "$FAKEBIN/orca"; fail "a probe error must read as unknown"; }
  rm -f "$FAKEBIN/orca"
  pass "orca: a failed turn probe is unknown, not idle"
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
  rm -rf "$H/state/watchdog"
  plist=$(run_wd 0 render-launchd)
  [ -d "$H/state/watchdog" ] || fail "render-launchd leaves the log directory missing"
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
  test_draft_rows_are_the_draft_alone \
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
  test_low_context_second_episode_asks_again \
  test_low_context_undelivered_nudge_starts_no_wait \
  test_restart_interval_holds_without_escalating \
  test_cleared_dialog_records_the_key_as_done \
  test_low_context_asks_nothing_when_no_restart_can_run \
  test_restart_request_does_not_shadow_frozen_recovery \
  test_held_nudges_reach_the_restart_proof \
  test_held_nudge_restart_keeps_the_draft_or_names_the_gap \
  test_context_burn_file_is_not_a_context_source \
  test_dialog_kind_ignores_conversation_rows \
  test_low_context_undeliverable_nudge_leaves_frozen_recovery \
  test_homes_with_one_basename_keep_their_own_state \
  test_dialog_reserved_check_reads_only_dialog_rows \
  test_orca_draft_probe_failure_holds_the_nudge \
  test_frozen_low_context_clean_draft_gets_one_enter_then_restarts \
  test_restart_request_is_only_the_file \
  test_blank_stripping_keeps_a_trailing_t \
  test_low_context_submits_a_clean_draft_then_nudges \
  test_stale_or_foreign_heartbeat_percent_is_ignored \
  test_orca_draft_is_never_typed_onto \
  test_reserved_task_or_key_is_held_and_refused_nudges_are_gaps \
  test_second_mate_restart_ends_the_pass \
  test_reserved_model_switch_dialog_is_held \
  test_unknown_composer_guards_the_nudge \
  test_orca_turn_probe_keeps_errors_unknown \
  test_no_activity_source_is_not_reported_ok \
  test_tmux_restart_survives_a_closed_session \
  test_status_file_short_and_staleness_visible \
  test_manager_units \
  test_never_merges_deploys_or_messages_owner
