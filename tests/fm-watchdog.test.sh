#!/usr/bin/env bash
# tests/fm-watchdog.test.sh - the firstmate assistant watchdog (bin/fm-watchdog.sh).
#
# Detectors run on fixtures through the sourced library. Every action case runs
# the real script against a disposable home whose captain pane is a real tmux
# pane on a private socket, whose lock holder is a real process, and whose
# transcript, wake queue, status files, and ledger are real files. Model CLIs
# are PATH fakes that log every call. Each hard boundary has its own case.
# Optional arguments select test functions; no arguments run the full suite.
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

restore_fake_tmux() {
  cat > "$FAKEBIN/tmux" <<REST
#!/usr/bin/env bash
exec "$REAL_TMUX" -f /dev/null -L "$SOCKET" "\$@"
REST
  chmod +x "$FAKEBIN/tmux"
}

# wrap_tmux_visible fail|blank: intercept capture-pane -S -0 (the viewport
# read). fail exits 1. blank succeeds with an empty viewport.
wrap_tmux_visible() {
  local mode=$1
  cat > "$FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
s=
prev=
for a in "\$@"; do
  if [ "\$prev" = -S ]; then s=\$a; fi
  prev=\$a
done
if [ "\$s" = -0 ]; then
  case "$mode" in
    fail) exit 1 ;;
    blank) exit 0 ;;
  esac
fi
exec "$REAL_TMUX" -f /dev/null -L "$SOCKET" "\$@"
SH
  chmod +x "$FAKEBIN/tmux"
}

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
  # An absent model must also hide a real CLI further down PATH, so no case reaches
  # a live model. It fails as a command that cannot run and logs nothing.
  if [ "$cm" = absent ]; then printf '#!/usr/bin/env bash\nexit 127\n' > "$FAKEBIN/claude"; chmod +x "$FAKEBIN/claude"; fi
  if [ "$am" = absent ]; then printf '#!/usr/bin/env bash\nexit 127\n' > "$FAKEBIN/agy"; chmod +x "$FAKEBIN/agy"; fi
  if [ "$cm" != absent ]; then
    cat > "$FAKEBIN/claude" <<SH
#!/usr/bin/env bash
# A real claude -p reads its prompt from stdin; an empty prompt is a failure.
prompt=\$(cat)
[ -n "\$prompt" ] || exit 1
printf '%s\n' "\$prompt" >> "$dir/prompt.log"
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
  fm_touch_epoch "$((BASE - 1))" "$H/state/.lock" "$H/state/.lock-session"
  # Written by the lock owner itself, as when the owner's own watcher runs it.
  jq -n --arg t "$T" --arg s "$SID" --argjson e "$BASE" --argjson p "$LOCKPID" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:"tmux",target:$t,present:true},session:{trusted_id:$s},writer:{anchor_pid:$p,session_id:$s}}}' \
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
  assert_equals usage-limit "$(lib fm_wd_pane_dialog "$model")" "usage-limit dialog"
  local limit
  for limit in "You hit your weekly limit." "You've hit your session limit" "Claude usage limit reached" "You are out of credits"; do
    assert_equals usage-limit "$(lib fm_wd_pane_dialog "$limit"$'\n ❯ 1. Wait\n   2. Stop\n\nEnter to confirm · Esc to cancel')" "limit picker: $limit"
  done
  assert_equals model-switch "$(lib fm_wd_pane_dialog $'Switch to another model?\n ❯ 1. Wait\n   2. Stop\n\nEnter to confirm · Esc to cancel')" "same-account model switch"
  lib fm_wd_quota_status_line "paused: You have hit your weekly limit" \
    || fail "status line 'You have hit your weekly limit' should match"
  lib fm_wd_quota_status_line "paused: waiting on a rate-limit reset" \
    || fail "status line 'waiting on a rate-limit reset' should match"
  lib fm_wd_quota_status_line "paused: hit the quota floor" \
    || fail "status line 'hit the quota floor' should match"
  lib fm_wd_quota_status_line "paused: Claude usage limit reached" \
    || fail "status line 'Claude usage limit reached' should match"
  lib fm_wd_quota_status_line "working: still going" \
    && fail "a working line should not match a quota floor"
  assert_equals question "$(lib fm_wd_pane_dialog "$question")" "question dialog"
  assert_equals permission "$(lib fm_wd_pane_dialog "$permission")" "permission dialog"
  assert_equals "" "$(lib fm_wd_pane_dialog "$plain")" "a numbered list in prose is no dialog"
  assert_equals permission "$(lib fm_wd_pane_dialog "$trust")" "unnumbered folder-trust picker is a permission dialog"
  assert_equals "" "$(lib fm_wd_pane_dialog "$composer")" "a composer prompt glyph without a picker footer is no dialog"
  local grok=$'                                                                                             █\n\n  ┃\n  ┃  You hit your weekly limit.\n  ┃\n  ┃\n  ┃  1 (○) Buy more credits  Purchase credits to keep using Grok Build\n  ┃  2 (○) Try Again         Resubmit the last prompt once you have usage again\n  ┃\n  ┃  ↑/↓ navigate · y copy                                                  Enter:submit\n  ┃\n\n  Tab:next answer  │  Esc:scrollback  │  Shift+x:dismiss'
  assert_equals "" "$(lib fm_wd_pane_dialog "$grok")" "Grok weekly-limit radio rows are not a pane picker"
  observe() { bash -c '. "$1/bin/fm-watchdog-lib.sh"; . "$1/bin/fm-composer-lib.sh"; shift; "$@"' _ "$ROOT" "$@"; }
  assert_equals usage-limit "$(observe fm_wd_observe_dialog "$grok")" \
    "observe reuses the composer detector and normalizes Grok weekly-limit"
  assert_equals usage-limit "$(observe fm_wd_observe_dialog "$model")" \
    "observe still names a Claude usage-limit pane picker"
  lib fm_wd_usage_limit_autowait $'work output\nUsage limit reached. Continuing automatically at 4:00 AM\n❯ \n  ? for shortcuts' \
    || fail "the usage-limit auto-wait footer in the last rows should match"
  lib fm_wd_usage_limit_autowait $'work output\n❯ \n  ? for shortcuts' \
    && fail "an ordinary idle composer should not match the auto-wait"
  lib fm_wd_usage_limit_autowait "$(printf 'Continuing automatically at 4:00 AM\n'; seq 1 12 | sed 's/.*/line/')" \
    && fail "an auto-wait quote above the last rows should not match"
  lib fm_wd_usage_limit_autowait $'work output\nThe footer reads `Continuing automatically at <reset>` here.\n❯ \n  ? for shortcuts' \
    && fail "an auto-wait quote in conversation just above the composer should not match"
  lib fm_wd_usage_limit_autowait $'work output\nContinuing automatically at 4:00 AM\n❯ \n  ? for shortcuts' \
    && fail "the bare auto-wait phrase above the composer should not match"
  lib fm_wd_usage_limit_autowait $'work output\n❯ \n  Continuing automatically at 4:00 AM' \
    || fail "the auto-wait phrase in the footer below the prompt should match"
  assert_contains "$(lib fm_wd_dialog_options "$model")" $'3\tBuy more credits' "dialog options parsed"
  assert_equals 42 "$(lib fm_wd_footer_percent $'work\n  42% until auto-compact')" "auto-compact footer"
  pass "dialogs need their structure, and each kind is told apart"
}

test_mtime_uses_the_platform_stat_dialect() {
  local out gnu='' statbin real_uname
  make_home $'Captain session\n> '
  transcript 3000 "Working." "Testing." "Green."
  out=$(run_wd 0 scan 2>&1) || fail "native stat scan failed: $out"
  assert_contains "$out" 'transcript_age=3000s' "native stat returns the transcript's age"
  if [ "$(uname -s)" = Linux ]; then
    gnu=$(command -v stat)
  elif command -v gstat >/dev/null 2>&1; then
    gnu=$(command -v gstat)
  fi
  if [ -n "$gnu" ]; then
    statbin="$H/gnu-bin"
    real_uname=$(command -v uname)
    mkdir -p "$statbin"
    cat > "$statbin/stat" <<SH
#!/usr/bin/env bash
exec "$gnu" "\$@"
SH
    cat > "$statbin/uname" <<SH
#!/usr/bin/env bash
case "\${1:-}" in ''|-s) printf 'Linux\n' ;; *) exec "$real_uname" "\$@" ;; esac
SH
    chmod +x "$statbin/stat" "$statbin/uname"
    out=$(PATH="$statbin:$PATH" run_wd 0 scan 2>&1) || fail "GNU stat scan failed: $out"
    assert_contains "$out" 'transcript_age=3000s' "GNU stat returns a numeric transcript age"
  else
    printf 'note: GNU stat unavailable; native stat checked\n'
  fi
  pass "mtime: native and available GNU stat give numeric ages through scan"
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
  for word in "redeploy the staging service" "gh pr merge 5" "enable automerge on PR 5" "cut a prerelease" "republish the package" "REDEPLOY now" "remerge it" "premerge it" "undeploy it" "git push --force origin main" "git push -f origin main" "git push origin main --force-with-lease" "git push -uf origin main" "git push origin +main" "git push origin +main:main" "git push origin +HEAD:refs/heads/main" 'git push origin "+main"'; do
    ! lib fm_wd_text_allowed "$word" || fail "text guard let through: $word"
    lib fm_wd_reserved "$word" || fail "reserved check let through: $word"
  done
  for word in $'git push origin main \\\n --force' $'git push origin main \\\n -f' $'> git push origin long-branch\n> --force-with-lease' $'force\n push it' $'git push origin \\\n +main' $'git push origin \\\n "+main"' $'│ git push origin │\n│ --force │' $'please mer\nge it' $'force\n──────\npush it'; do
    ! lib fm_wd_text_allowed "$word" || fail "text guard let through: $word"
    lib fm_wd_reserved "$word" || fail "reserved check let through: $word"
  done
  lib fm_wd_text_allowed $'> finish the summary\n ? for shortcuts' || fail "a clean draft with its footer is allowed"
  for word in "handle the emergency" "submerge the raft" "re-emerge later" "git push -u origin fix-flag" "git push --follow-tags" "push 2 + 3 rows"; do
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

WD_RULE='────────────────────────────────────────────────────────────'
# A proven plain composer: its prompt row between two long column-0 rules.
ruled() {  # <draft-rows> [rows-under-the-closing-rule]
  printf '%s\n%s\n%s' "$WD_RULE" "$1" "$WD_RULE"
  [ -z "${2:-}" ] || printf '\n%s' "$2"
}

test_draft_rows_are_the_draft_alone() {
  local rule='──────────'
  assert_equals $'> first\n  then enter plan mode\n  third' "$(lib fm_wd_draft_rows "$(ruled $'> first\n  then enter plan mode\n  third' '  ? for shortcuts')")" "a footer word inside a draft does not cut it"
  assert_equals $'> keep going\n ──────\n merge #5' "$(lib fm_wd_draft_rows "$(ruled $'> keep going\n ──────\n merge #5' ' ? for shortcuts')")" "an inner rule does not end the draft"
  assert_equals $'> keep\n'"$WD_RULE"$'\n merge #5' "$(lib fm_wd_draft_rows "$WD_RULE"$'\n> keep\n'"$WD_RULE"$'\n merge #5\n'"$WD_RULE")" "the note runs to the last long rule"
  assert_equals "" "$(lib fm_wd_draft_rows $'› keep going\n merge #5\n 100% context left')" "an unproven draft has no note"
  assert_equals $'> merge #5\n'"$rule"$'\n> ok\n  footer' "$(lib fm_wd_prompt_tail "old"$'\n> merge #5\n'"$rule"$'\n> ok\n  footer')" "the guard reads from the first prompt row to the end"
  lib fm_wd_draft_readable "╭──╮"$'\n│ > finish the summary │\n'"╰──╯" || fail "a bordered prompt row in a box is readable"
  LC_ALL=C lib fm_wd_draft_readable "╭──╮"$'\n│ > finish the summary │\n'"╰──╯" || fail "a bordered prompt row in a box is readable in the C locale"
  ! lib fm_wd_draft_readable "│ > finish the summary │" || fail "a bordered row with no box proves nothing"
  assert_equals $'│ > merge #5 │\n│ ──── │\n│ > quoted │' "$(lib fm_wd_draft_rows $'╭──╮\n│ > merge #5 │\n│ ──── │\n│ > quoted │\n╰──╯\n ? for shortcuts')" "an inner rule does not cut a box's note"
  assert_equals "│ > finish the summary │" "$(lib fm_wd_draft_rows "╭──────╮"$'\n│ > finish the summary │\n'"╰──────╯")" "a box leaves only its text row"
  assert_equals "> now" "$(lib fm_wd_draft_rows "$(printf '> sent earlier\n%s\n> now\n%s' "$WD_RULE" "$WD_RULE")")" "a rule above the prompt ends the conversation"
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
  make_home "Captain session"$'\n'"$(ruled '> continue with the plan')"
  FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=pending run_wd 300 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows pasted-input key pending)" "ordinary unsent text gets Enter"
  for _ in $(seq 1 25); do [ -s "$H/typed.log" ] && break; sleep 0.2; done
  [ -s "$H/typed.log" ] || fail "Enter never reached the pane"
  assert_grep "unsent draft names a merge" "$HOLD_STATUS" "the refusal is reported as a gap"

  make_home "PR #41 merged and the release went out."$'\n'"$(ruled '> finish the summary')"
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
  for draft in "redeploy the staging service" "gh pr merge 5" "enable automerge on PR 5" "cut a prerelease" "republish the package" "git push --force origin main" "git push -f origin main" "git push origin main --force-with-lease" "git push origin +main" "git push origin +main:main" $'git push origin main \\\n --force' $'git push origin feature/some-long-branch\n --force-with-lease' $'force\n push it' $'git push origin \\\n "+main"' $'please mer\nge it'; do
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

test_quoted_row_never_hides_a_taller_draft() {
  local rule='──────────' tall
  tall=$'Captain session\n> merge #5\n one\n two\n three\n four\n> quoted\n six\n seven\n'"$rule"$'\n ? for shortcuts'
  ! lib fm_wd_draft_readable $' two\n three\n four\n> quoted\n six\n seven\n'"$rule"$'\n ? for shortcuts' $'Captain session\n> merge #5\n one' || fail "a prompt row above the window hides the draft top"
  local long='────────────────────────────────────────────────────────────'
  lib fm_wd_draft_readable $'> now\n'"$long" $'> sent earlier\nreply\n'"$long" || fail "a closed pair of column-0 rules proves the boundary"
  ! lib fm_wd_draft_readable $' two\n'"$rule"$'\n> quoted\n six\n'"$rule"$'\n ? for shortcuts' $'> merge #5\n one' || fail "a short nested rule proves nothing"
  ! lib fm_wd_draft_readable $' two\n '"$long"$'\n> quoted\n six\n '"$long"$'\n ? for shortcuts' $'> merge #5\n one' || fail "an indented rule is draft text"
  ! lib fm_wd_draft_readable $' two\n'"$long"$'\n> quoted\n six\n ? for shortcuts' $'> merge #5\n one' || fail "an unclosed rule proves nothing"
  ! lib fm_wd_draft_readable $'reply one\nreply two\n› finish summary\n 100% context left' $'› earlier prompt' || fail "a bare composer under history is not proven"
  lib fm_wd_draft_readable $'╭────╮\n│ > finish │\n╰────╯' $'> earlier\nreply' || fail "a closed box proves the boundary"
  ! lib fm_wd_draft_readable $'│ > finish │\n plain row\n╰────╯' $'> earlier\n╭────╮' || fail "a broken box proves nothing"
  ! lib fm_wd_draft_readable $'│ three │\n│ four │\n│ five │\n│ six │\n│ > quoted │\n│ seven │\n╰────╯\n ? for shortcuts' $'╭────╮\n│ > merge #5 │\n│ one │\n│ two │' || fail "a box that starts above the window proves nothing"
  local hidden_rows i
  hidden_rows='│ row0 │'
  for i in $(seq 1 52); do hidden_rows="$hidden_rows"$'\n'"│ row$i │"; done
  ! lib fm_wd_draft_readable $'│ a │\n│ b │\n│ > quoted │\n│ c │\n╰──╯\n ? for shortcuts' "$hidden_rows" || fail "a box with its top beyond the capture proves nothing"
  ! lib fm_wd_draft_readable $'│ a │\n│ > quoted │\n╰──╯' || fail "a box with no top proves nothing"
  ! lib fm_wd_draft_readable $'│ > quoted │\n╰──╯' $'╭──╮' || fail "a top just above the window proves nothing"
  lib fm_wd_draft_readable $'╭────╮\n│ > fine │\n│ > quoted │\n╰────╯' $'> earlier\nreply' || fail "a whole box in the window is read from its first prompt row"
  ! lib fm_wd_draft_readable $'> now\n'"$rule" || fail "a short rule proves nothing, with nothing above"
  ! lib fm_wd_draft_readable '> now' || fail "a lone plain prompt row proves nothing"
  ! lib fm_wd_draft_readable $' a\n b\n> quoted\n c\n'"$rule" || fail "a plain draft beyond the capture proves nothing"
  ! lib fm_wd_draft_readable $' a\n b\n> quoted\n c\n'"$long" || fail "a closing rule alone proves nothing"
  ! lib fm_wd_draft_readable " │ ❯ finish"$'\n'" ╰──╯" || fail "an indented composer is not supported"
  lib fm_wd_draft_readable "$(ruled '> now')" || fail "a ruled prompt row with nothing above is readable"

  make_home "$tall"
  FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=pending run_wd 300 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows pasted-input key refused)" "the taller draft is refused: $(ledger | cut -f5-8)"
  assert_equals 0 "$(ledger_rows pasted-input key pending)" "the taller draft gets no Enter"
  sleep 1
  assert_equals "" "$(cat "$H/typed.log")" "Enter was never pressed on the taller draft"

  make_home "$tall" "restart=on
restart-command=$TMP_ROOT/fake-captain.sh"
  write_fake_captain
  transcript 3000 "Working." "Testing." "Green."
  kill_holder_with_anchor
  FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
  assert_grep "lost an unreadable draft" "$H/data/watchdog/status.md" "the partial draft is reported as a gap"
  wait_pickup && LOCK_PIDS="$LOCK_PIDS $(cat "$H/state/.lock")"

  make_home "Captain session"$'\n> merge #5\n one\n two\n'"$rule"$'\n> quoted\n six\n'"$rule"$'\n ? for shortcuts\n status\n status two\n status three'
  FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=pending run_wd 300 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows pasted-input key pending)" "a nested rule gets no Enter: $(ledger | cut -f5-8)"
  assert_equals 1 "$(ledger_rows pasted-input key refused)" "the nested rule draft is refused"

  make_home $'> earlier\nreply text\n> fix the bug\nDone.\n'"$long"$'\n> finish summary\n'"$long"$'\n ? for shortcuts\n status'
  FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=pending run_wd 300 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows pasted-input key pending)" "history above a proven composer leaves Enter: $(ledger | cut -f5-8)"

  make_home $'╭────╮\n│ > merge #5 │\n│ one │\n│ two │\n│ three │\n│ four │\n│ five │\n│ six │\n│ > quoted │\n│ seven │\n╰────╯\n ? for shortcuts'
  FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=pending run_wd 300 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows pasted-input key pending)" "a box taller than the window gets no Enter: $(ledger | cut -f5-8)"
  assert_equals 1 "$(ledger_rows pasted-input key refused)" "a box taller than the window is refused"
  assert_grep "boundary is not proven" "$H/data/watchdog/status.md" "the tall box is reported as a gap"

  make_home $'> earlier\nreply\n╭────╮\n│ > merge #5 │\n│ > quoted │\n╰────╯\n ? for shortcuts'
  FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=pending run_wd 300 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows pasted-input key pending)" "merge in a whole box gets no Enter: $(ledger | cut -f5-8)"
  assert_equals 1 "$(ledger_rows pasted-input key refused)" "merge in a whole box is refused"

  make_home $'one\ntwo\nthree\nfour\n> earlier\nreply\n╭────╮\n│ > fine │\n│ > quoted │\n╰────╯\n ? for shortcuts'
  FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=pending run_wd 300 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows pasted-input key refused)" "a clean whole box is not refused: $(ledger | cut -f5-8)"
  assert_equals 1 "$(ledger_rows pasted-input key pending)" "a clean whole box leaves Enter: $(ledger | cut -f5-8)"

  make_home $'│ merge #5 │\n│ one │\n│ two │\n│ three │\n│ four │\n│ five │\n│ six │\n│ > quoted │\n│ seven │\n╰────╯\n ? for shortcuts'
  FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=pending run_wd 300 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows pasted-input key pending)" "a box with no visible top gets no Enter: $(ledger | cut -f5-8)"
  assert_equals 1 "$(ledger_rows pasted-input key refused)" "a box with no visible top is refused"
  assert_grep "boundary is not proven" "$H/data/watchdog/status.md" "the box with no visible top is reported as a gap"

  make_home $'╭──╮\n│ > keep top row │\n│ ──── │\n│ > quoted │\n╰──╯\n ? for shortcuts' "restart=on
restart-command=$TMP_ROOT/fake-captain.sh"
  write_fake_captain
  transcript 3000 "Working." "Testing." "Green."
  kill_holder_with_anchor
  FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
  wait_pickup && LOCK_PIDS="$LOCK_PIDS $(cat "$H/state/.lock")"
  local box_note
  box_note=$(awk '/never submitted/ { on = 1; next } on && /^```/ { if (seen) exit; seen = 1; next } seen { print }' "$H/data/watchdog/handoffs/"*.md)
  assert_equals $'│ > keep top row │\n│ ──── │\n│ > quoted │' "$box_note" "the handoff note holds the whole box draft: $(cat "$H/data/watchdog/handoffs/"*.md)"
  ! grep -q "lost an unreadable draft" "$H/data/watchdog/status.md" || fail "a whole box draft is not a lost draft"
  pass "boundary: a quoted row inside a taller draft never earns Enter or a partial note"
}

test_terminal_service_loss_is_agent_gone() {
  local idle=$'Captain session\n> ' working=$'Captain session\n✻ Working… (esc to interrupt)' screen
  for screen in "$idle" "$working"; do
    make_home "$screen" "restart=on
restart-command=$TMP_ROOT/fake-captain.sh"
    write_fake_captain
    transcript 3000 "Working." "Testing." "Green."
    kill_holder_with_anchor
    run_wd 0 once >/dev/null 2>&1
    assert_equals 1 "$(ledger_rows agent-gone restart pending)" "a pane with no agent process restarts: $(ledger | cut -f5-8)"
    wait_pickup || fail "the new captain never proved pickup: $(ledger | cut -f5-8)"
    LOCK_PIDS="$LOCK_PIDS $(cat "$H/state/.lock")"
    assert_equals "" "$(cat "$H/typed.log")" "nothing is typed into a pane with no agent process"

    make_home "$screen" "restart=on
restart-command=$TMP_ROOT/fake-captain.sh"
    transcript 100 "Working." "Testing." "Green."
    kill_holder_with_anchor
    run_wd 0 once >/dev/null 2>&1
    assert_equals "" "$(ledger)" "one signal is no restart proof"
    assert_grep "lock holder is dead" "$H/data/watchdog/status.md" "the wait for a second signal is a gap"

    make_home "$screen" "restart=off
restart-command=$TMP_ROOT/fake-captain.sh"
    transcript 3000 "Working." "Testing." "Green."
    kill_holder_with_anchor
    run_wd 0 once >/dev/null 2>&1
    assert_equals 1 "$(ledger_rows agent-gone restart refused)" "restart off refuses: $(ledger | cut -f5-8)"
    assert_equals 0 "$(ledger_rows agent-gone restart pending)" "restart off starts nothing"

    make_home "$screen" "restart=on
restart-command=$TMP_ROOT/fake-captain.sh"
    printf 'do-not-touch=%s\n' "$T" >> "$H/config/watchdog"
    transcript 3000 "Working." "Testing." "Green."
    kill_holder_with_anchor
    run_wd 0 once >/dev/null 2>&1
    assert_equals 1 "$(ledger_rows agent-gone restart refused)" "do-not-touch refuses: $(ledger | cut -f5-8)"
    assert_equals 0 "$(ledger_rows agent-gone restart pending)" "do-not-touch starts nothing"

    make_home "$screen" "restart=on
models=claude:haiku
restart-command=$TMP_ROOT/fake-captain.sh"
    write_fake_captain
    fake_models "$H" ok:"RULING A" absent
    transcript 3000 "Working." "Testing." "Green."
    printf 'needs-decision [at=%s] [key=captain-hold-cut]: A or B?\n' "$((BASE - 9000))" > "$H/state/t1.status"
    kill_holder_with_anchor
    run_wd 0 once >/dev/null 2>&1
    wait_pickup && LOCK_PIDS="$LOCK_PIDS $(cat "$H/state/.lock")"
    [ ! -s "$H/model.log" ] || fail "a model saw an owner hold: $(cat "$H/model.log")"
    assert_grep "captain-hold-cut" "$H/state/t1.status" "the owner hold stays open"
    assert_equals "" "$(cat "$H/typed.log")" "the owner hold is never answered"
  done

  make_home "$working" "restart=on
max-nudges=0
restart-command=$TMP_ROOT/fake-captain.sh"
  transcript 3000 "Working." "Testing." "Green."
  owe_input 3000
  run_wd 0 once >/dev/null 2>&1
  run_wd 1000 once >/dev/null 2>&1
  kill -0 "$LOCKPID" 2>/dev/null || fail "a live long tool call was stopped"
  ledger | grep -q restart && fail "a live long tool call must not restart: $(ledger)"
  assert_grep "treated as busy" "$H/data/watchdog/status.md" "the live tool call is protected"
  pass "terminal service loss: no agent process overrides drawn Working; a live tool call stays protected"
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

  local unproven
  for unproven in '> finish the summary' $'reply\n› finish summary\n 100% context left' $' a\n b\n> quoted\n c\n──────────\n ? for shortcuts' $' │ ❯ finish the summary\n ╰──╯' $'┃ > finish the summary' "─────── Andrew ─"$'\n❯ finish the summary\n'"$WD_RULE"$'\n ? for shortcuts'; do
    make_home "$unproven"
    FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
    FM_WD_TEST_COMPOSER=pending run_wd 300 once >/dev/null 2>&1
    assert_equals 1 "$(ledger_rows pasted-input key refused)" "an unproven draft is refused: $unproven: $(ledger | cut -f5-8)"
    assert_equals 0 "$(ledger_rows pasted-input key pending)" "an unproven draft gets no Enter: $unproven"
    assert_grep "boundary is not proven" "$H/data/watchdog/status.md" "the unproven draft is a reported gap: $unproven"
    assert_grep "titled composers are unsupported" "$H/data/watchdog/status.md" "the gap names the unsupported shapes: $unproven"
    sleep 1
    assert_equals "" "$(cat "$H/typed.log")" "Enter was never pressed: $unproven"
  done

  make_home '> finish the summary' 'restart=on
restart-command=/bin/true'
  transcript 5000 "Working." "Testing." "Green."
  owe_input 5000
  local off handoff
  for off in 0 1000 2000 3000 4000; do FM_WD_TEST_COMPOSER=pending run_wd "$off" once >/dev/null 2>&1; done
  assert_equals 0 "$(ledger_rows pasted-input key pending)" "a plain draft on the restart path gets no Enter: $(ledger | cut -f5-8)"
  assert_equals 1 "$(ledger_rows frozen restart pending)" "a plain draft still reaches the restart: $(ledger | cut -f5-8)"
  handoff=$(ls "$H/data/watchdog/handoffs/"*.md)
  assert_grep "GAP: an unsent draft could not be read" "$handoff" "the handoff names the unproven draft"

  make_home $'> finish the summary\n  7% until auto-compact' 'restart=on
restart-command=/bin/true'
  transcript 3000 "Working." "Testing." "Green."
  FM_WD_TEST_COMPOSER=pending run_wd 0 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=pending run_wd 1000 once >/dev/null 2>&1
  assert_equals 0 "$(ledger | awk -F'\t' '$5 == "handoff-request"' | wc -l | tr -d ' ')" "no handoff nudge goes onto a plain draft"
  assert_grep "handoff nudge cannot be delivered" "$H/data/watchdog/status.md" "the low-context hold is a reported gap"
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

judge_calls() { grep -c '^claude -p' "$H/model.log" 2>/dev/null || true; }

test_model_switch_judge_is_rate_limited() {
  local stuck=$'Switch to another model?\n\n ❯ 1. Wait\n   2. Buy more credits\n\nEnter to confirm · Esc to cancel'
  local off

  make_home "$stuck" 'models=claude:haiku'
  fake_models "$H" ok:"NONE" absent
  transcript 100 "Working."
  for off in 0 120 240; do run_wd "$off" once >/dev/null 2>&1 || fail "NONE: pass $off failed"; done
  assert_equals 1 "$(judge_calls)" "NONE: one judge call inside the window"
  assert_grep "next judge call waits" "$H/data/watchdog/status.md" "NONE: the waiting picker is still a gap"
  run_wd 900 once >/dev/null 2>&1 || fail "NONE: pass 900 failed"
  assert_equals 2 "$(judge_calls)" "NONE: the judge is asked again once the window opens"
  assert_equals 0 "$(ledger | awk -F'\t' '$6 == "key"' | wc -l | tr -d ' ')" "NONE: no key row"
  [ ! -s "$H/typed.log" ] || fail "NONE: something was typed: $(cat "$H/typed.log")"

  make_home "$stuck" 'models=claude:haiku'
  fake_models "$H" ok:"OPTION 2" absent
  transcript 100 "Working."
  for off in 0 120 240; do run_wd "$off" once >/dev/null 2>&1 || fail "refused: pass $off failed"; done
  assert_equals 1 "$(judge_calls)" "refused: one judge call inside the window"
  assert_equals 1 "$(ledger_rows dialog key refused)" "refused: one refusal row inside the window"
  [ ! -s "$H/typed.log" ] || fail "refused: a buy-credits option was pressed: $(cat "$H/typed.log")"

  make_home "$stuck" 'models=claude:haiku
mode=dry-run'
  fake_models "$H" ok:"OPTION 1" absent
  transcript 100 "Working."
  for off in 0 120 240; do run_wd "$off" once >/dev/null 2>&1 || fail "dry-run: pass $off failed"; done
  assert_equals 1 "$(judge_calls)" "dry-run: one judge call inside the window"
  assert_equals 1 "$(ledger_rows dialog key dry-run)" "dry-run: one recorded key"
  [ ! -s "$H/typed.log" ] || fail "dry-run: something was typed: $(cat "$H/typed.log")"

  make_home "$stuck" 'models=claude:haiku'
  fake_models "$H" ok:"OPTION 1" absent
  transcript 100 "Working."
  run_wd 0 once >/dev/null 2>&1 || fail "spent: pass 0 failed"
  run_wd 900 once >/dev/null 2>&1 || fail "spent: pass 900 failed"
  assert_equals 2 "$(ledger_rows dialog key failed)" "spent: two keys left the picker showing: $(ledger | cut -f5-8)"
  assert_equals 2 "$(judge_calls)" "spent: each key had its own judge call"
  run_wd 1800 once >/dev/null 2>&1 || fail "spent: pass 1800 failed"
  assert_equals 2 "$(judge_calls)" "spent: no judge call after two failed keys"
  assert_grep "no more keys pressed" "$H/data/watchdog/status.md" "spent: the stuck picker is reported"
  run_wd 4600 once >/dev/null 2>&1 || fail "spent: pass 4600 failed"
  assert_equals 3 "$(judge_calls)" "spent: the judge returns once the failed keys age out of the hour"
  pass "model-switch dialog: the judge and its refusals are rate-limited in every mode and stop after two failed keys"
}

test_secret_looking_decision_reaches_no_council() {
  local sentinel=FAKESENTINEL42 rec_dirs
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  transcript 100 "Working."
  {
    printf 'needs-decision [at=%s] [key=push-layout]: push failed for https://x-access-token:%s@example.invalid/o/r; pick A or B\n' "$((BASE - 9900))" "$sentinel"
    printf 'needs-decision [at=%s] [key=ghp_%s]: A or B?\n' "$((BASE - 9800))" "$sentinel"
    printf 'needs-decision [at=%s] [key=cache-layout]: A (recommended) flat keys or B nested keys?\n' "$((BASE - 9000))"
  } > "$H/state/t1.status"
  run_wd 0 once >/dev/null 2>&1 || fail "first pass failed"
  assert_grep "2 decisions held for the owner" "$H/data/watchdog/status.md" "secret-looking decisions are held gaps"
  assert_equals 1 "$(ledger_rows decisions nudge pending)" "the clean decision still gets its nudge"
  run_wd 2000 once >/dev/null 2>&1 || fail "second pass failed"
  assert_equals 1 "$(ledger_rows decision:cache-layout council "done")" "the clean decision still reaches council"
  assert_equals 0 "$(ledger | grep -c 'decision:push-layout')" "a secret-looking record gets no council"
  assert_equals 2 "$(grep -cE '^(claude|agy) -p' "$H/model.log")" "each seat was called once, for the clean decision"
  assert_equals 1 "$(find "$H/data/watchdog/rulings" -type f | wc -l | tr -d ' ')" "only the clean decision has a ruling file"
  assert_grep "cache-layout" "$H/prompt.log" "a seat saw the clean decision"
  rec_dirs="$H/state/watchdog $H/data/watchdog $H/model.log $H/prompt.log $H/typed.log"
  # shellcheck disable=SC2086
  if grep -rFq "$sentinel" $rec_dirs 2>/dev/null; then fail "the withheld text reached a model, a gap, a ruling, or a nudge"; fi
  pass "decisions: secret-looking text reaches no council seat, ruling, gap, or nudge; a clean decision still settles"
}

test_secret_looking_model_switch_dialog_is_held() {
  local sentinel=FAKESENTINEL42
  make_home "curl run with Bearer $sentinel"$'\n\nSwitch to another model?\n\n ❯ 1. Switch to Sonnet\n   2. Buy more credits\n\nEnter to confirm · Esc to cancel' 'models=claude:haiku,agy:flash'
  fake_models "$H" fail ok:"OPTION 1"
  transcript 100 "Working."
  run_wd 0 once >/dev/null 2>&1 || fail "pass failed on the secret dialog"
  assert_equals 0 "$(ledger | awk -F'\t' '$6 == "key"' | wc -l | tr -d ' ')" "no key goes to a secret-looking dialog: $(ledger | cut -f5-8)"
  [ ! -s "$H/model.log" ] || fail "a model saw a secret-looking dialog: $(cat "$H/model.log")"
  assert_absent "$H/prompt.log" "no prompt was built for any model"
  [ ! -s "$H/typed.log" ] || fail "something was typed: $(cat "$H/typed.log")"
  assert_grep "looks like a secret; held" "$H/data/watchdog/status.md" "the hold is a gap"
  if grep -rFq "$sentinel" "$H/state/watchdog" "$H/data/watchdog"; then fail "the withheld text reached watchdog records"; fi

  make_home $'Switch to another model?\n\n ❯ 1. Switch to Sonnet\n   2. Buy more credits\n\nEnter to confirm · Esc to cancel' 'models=claude:haiku,agy:flash'
  fake_models "$H" fail ok:"OPTION 1"
  transcript 100 "Working."
  run_wd 0 once >/dev/null 2>&1 || fail "pass failed on the ordinary dialog"
  assert_grep "agy -p" "$H/model.log" "the fallback model judges an ordinary dialog"
  assert_equals 1 "$(ledger_rows dialog key pending)" "an ordinary dialog still gets its key: $(ledger | cut -f5-8)"
  pass "model-switch dialog: secret-looking text reaches no model on any fallback; an ordinary one still gets its key"
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

near_loop_home() {  # <extra-config>
  make_home $'Captain session\n> ' "$1"
  transcript 3000 "still waiting on the timer armed alpha" "still waiting on the timer armed beta" "still waiting on the timer armed gamma"
  owe_input 3000
}

test_near_loop_never_masks_frozen_or_input_recovery() {
  local case
  for case in no-model work malformed cap; do
    near_loop_home 'models=claude:haiku
daily-max-usd=0.01'
    case "$case" in
      no-model) fake_models "$H" absent absent ;;
      work) fake_models "$H" ok:WORK absent ;;
      malformed) fake_models "$H" ok:MAYBE absent ;;
      cap)
        fake_models "$H" ok:LOOP absent
        mkdir -p "$H/state/watchdog"
        printf '%s\tloop\tclaude:haiku\tok\t1\t1\tLOOP\t0.02\n' "$BASE" >> "$H/state/watchdog/model-calls.tsv" ;;
    esac
    run_wd 0 once >/dev/null 2>&1 || fail "$case: first pass failed"
    assert_equals 1 "$(ledger_rows unread-input nudge pending)" "$case: owed input is still nudged"
    run_wd 1000 once >/dev/null 2>&1 || fail "$case: second pass failed"
    assert_equals 1 "$(ledger_rows frozen nudge pending)" "$case: a frozen pane is still nudged"
    assert_equals 0 "$(ledger | grep -c timer-loop)" "$case: an unconfirmed near repeat is no loop"
    assert_absent "$H/state/watchdog/escalated/$(home_key)" "$case: an unconfirmed near repeat does not escalate"
    if [ "$case" != work ]; then
      assert_grep "possible loop; no judge answer" "$H/data/watchdog/status.md" "$case: the missing answer is a gap"
    fi
  done
  pass "near loop: no model, the daily cap, WORK, and a bad answer all leave frozen and input recovery running"
}

test_near_loop_judge_sees_the_sequence_and_is_rate_limited() {
  local pass_at
  near_loop_home 'models=claude:haiku'
  fake_models "$H" ok:WORK absent
  for pass_at in 0 120 240 360 480 3000; do
    run_wd "$pass_at" once >/dev/null 2>&1 || fail "pass at $pass_at failed"
  done
  assert_equals 1 "$(grep -c '^claude' "$H/model.log")" "unchanged evidence is judged once across six passes"
  assert_equals 1 "$(grep -c '^assistant: .*alpha$' "$H/prompt.log")" "the judge sees the oldest reply"
  assert_equals 1 "$(grep -c '^assistant: .*beta$' "$H/prompt.log")" "the judge sees the middle reply"
  assert_equals 1 "$(grep -c '^assistant: .*gamma$' "$H/prompt.log")" "the judge sees the newest reply"
  assert_equals 3 "$(grep -c '^tool: ScheduleWakeup' "$H/prompt.log")" "the judge sees the tool call after each reply"
  [ "$(grep -n 'alpha$' "$H/prompt.log" | cut -d: -f1)" -lt "$(grep -n 'gamma$' "$H/prompt.log" | cut -d: -f1)" ] || fail "the newest reply is not last"
  transcript 10 "still waiting on the timer armed delta" "still waiting on the timer armed epsilon" "still waiting on the timer armed zeta"
  run_wd 3060 once >/dev/null 2>&1 || fail "pass with new evidence failed"
  assert_equals 2 "$(grep -c '^claude' "$H/model.log")" "new evidence after the interval is judged again"
  transcript 10 "still waiting on the timer armed eta" "still waiting on the timer armed theta" "still waiting on the timer armed iota"
  run_wd 3120 once >/dev/null 2>&1 || fail "pass with newer evidence failed"
  assert_equals 2 "$(grep -c '^claude' "$H/model.log")" "newer evidence waits for the interval"
  run_wd 4000 once >/dev/null 2>&1 || fail "pass after the interval failed"
  assert_equals 3 "$(grep -c '^claude' "$H/model.log")" "newer evidence is judged once the interval passes"
  pass "near loop: the judge sees the recent sequence, newest last, and repeats only for new evidence after the interval"
}

test_near_loop_confirmed_uses_the_ladder() {
  near_loop_home 'models=claude:haiku'
  fake_models "$H" ok:LOOP absent
  run_wd 0 once >/dev/null 2>&1 || fail "first pass failed"
  assert_equals 1 "$(ledger_rows timer-loop nudge pending)" "a LOOP answer takes the timer-loop ladder"
  assert_equals 0 "$(ledger_rows unread-input nudge pending)" "a confirmed loop is the one symptom this pass"
  run_wd 120 once >/dev/null 2>&1 || fail "second pass failed"
  assert_equals 1 "$(ledger_rows timer-loop nudge pending)" "the standing answer keeps the ladder's rate limit"
  assert_equals 1 "$(grep -c '^claude' "$H/model.log")" "the standing answer costs no second call"
  pass "near loop: a LOOP answer alone takes the existing ladder"
}

test_near_loop_evidence_is_withheld_from_every_model() {
  local case sentinel=FAKESENTINEL42 f
  for case in secret-text reserved-text secret-tool; do
    near_loop_home 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
    fake_models "$H" ok:LOOP ok:LOOP
    case "$case" in
      secret-text) transcript 3000 "still waiting on the timer armed alpha" "still waiting on the timer armed beta" "still waiting on the timer armed token=$sentinel" ;;
      reserved-text) transcript 3000 "still waiting on the timer armed alpha" "still waiting on the timer armed beta" "still waiting on the timer armed deploy $sentinel" ;;
      secret-tool)
        f="$H/claude/projects/p/$SID.jsonl"
        jq -cn --arg a "password=$sentinel" '{type:"assistant",timestamp:"2026-01-01T00:00:00Z",message:{content:[{type:"tool_use",name:"ScheduleWakeup",input:{prompt:$a}}]}}' >> "$f"
        fm_touch_epoch "$((BASE - 3000))" "$f" ;;
    esac
    run_wd 0 once >/dev/null 2>&1 || fail "$case: first pass failed"
    assert_equals 1 "$(ledger_rows unread-input nudge pending)" "$case: unread input is still nudged"
    run_wd 1000 once >/dev/null 2>&1 || fail "$case: second pass failed"
    assert_equals 1 "$(ledger_rows frozen nudge pending)" "$case: a frozen pane is still nudged"
    assert_equals 0 "$(ledger | grep -c timer-loop)" "$case: withheld evidence is unconfirmed"
    [ ! -s "$H/model.log" ] || fail "$case: a model was called: $(cat "$H/model.log")"
    assert_absent "$H/prompt.log" "$case: no prompt was built for any model"
    assert_grep "evidence is withheld from the judge" "$H/data/watchdog/status.md" "$case: the withheld evidence is a gap"
    grep -rFq "$sentinel" "$H/state/watchdog" "$H/data/watchdog" && fail "$case: the withheld text reached watchdog records"
  done
  pass "near loop: evidence with a secret or reserved word reaches no model or record, and recovery still runs"
}

test_fresh_rapid_loop_recovers_without_owed_input() {
  local body
  make_home $'Captain session\n> '
  GAP=30 transcript 10 "Re-arming the timer." "Re-arming the timer." "Re-arming the timer."
  run_wd 0 once >/dev/null 2>&1 || fail "fresh rapid pass failed"
  assert_equals 1 "$(ledger_rows timer-loop nudge pending)" "a fresh rapid loop is recovered without owed input"
  [ -s "$H/typed.log" ] || fail "the live pane received no doorbell"
  body=$(ledger | awk -F'\t' '$5 == "timer-loop" && $6 == "nudge" && $7 == "pending" { print $8 }')
  case "$body" in *'input is waiting'*) fail "the nudge falsely claims waiting input" ;; esac
  run_wd 1000 once >/dev/null 2>&1 || fail "stale rapid pass failed"
  assert_equals 1 "$(ledger_rows timer-loop nudge pending)" "the aged burst is not nudged again without input"
  assert_equals 0 "$(ledger_rows timer-loop restart pending)" "the aged burst is not restarted"
  pass "rapid loop: a fresh burst is nudged without invented input, and its aged tail stays quiet"
}

test_old_rapid_burst_leaves_an_idle_session_alone() {
  make_home $'Captain session\n> ' 'restart=on
restart-command=/bin/true'
  GAP=30 transcript 3000 "No action needed." "No action needed." "No action needed."
  local at
  for at in 0 2000 4000 6000; do
    run_wd "$at" once >/dev/null 2>&1 || fail "pass at $at failed"
  done
  assert_equals 0 "$(ledger | grep -c timer-loop)" "an old burst with no waiting input is no loop"
  assert_equals 0 "$(ledger_rows timer-loop restart pending)" "an idle session is not restarted"
  assert_equals "" "$(cat "$H/typed.log")" "an idle session gets no text"

  make_home $'Captain session\n> '
  GAP=30 transcript 10 "No action needed." "No action needed." "No action needed."
  run_wd 0 once >/dev/null 2>&1 || fail "fresh burst pass failed"
  assert_equals 1 "$(ledger_rows timer-loop nudge pending)" "a fresh burst is recovered even with no waiting input"

  make_home $'Captain session\n> '
  GAP=30 transcript 10 "No action needed." "No action needed." "No action needed."
  owe_input 60
  run_wd 0 once >/dev/null 2>&1 || fail "live burst pass failed"
  assert_equals 1 "$(ledger_rows timer-loop nudge pending)" "a moving burst with waiting input is nudged"

  make_home $'Captain session\n> '
  GAP=30 transcript 3000 "No action needed." "No action needed." "No action needed."
  owe_input 3000
  run_wd 0 once >/dev/null 2>&1 || fail "aged input pass failed"
  assert_equals 1 "$(ledger_rows timer-loop nudge pending)" "an old burst with aged input is nudged"
  pass "rapid loop: a fresh burst is recovered, and an old burst needs aged input"
}

test_primary_ignores_another_sessions_endpoint() {
  make_home $'Captain session\n> '
  transcript 3000 "Working on the fix." "Now testing it." "Tests are green."
  owe_input 3000
  printf '00000000-0000-4000-8000-0000000000ff\n' > "$H/state/.lock-session"
  run_wd 0 once >/dev/null 2>&1 || fail "first pass failed"
  run_wd 1000 once >/dev/null 2>&1 || fail "second pass failed"
  assert_equals "" "$(cat "$H/typed.log")" "another session's pane gets no text"
  assert_equals 0 "$(ledger | awk -F'\t' '$6 == "nudge" && $7 != "refused"' | wc -l | tr -d ' ')" "no nudge goes out to another session's pane: $(ledger | cut -f5-8)"
  assert_grep "no recorded terminal endpoint" "$H/data/watchdog/status.md" "the unproven endpoint is reported"
  printf '%s\n' "$SID" > "$H/state/.lock-session"
  run_wd 1100 once >/dev/null 2>&1 || fail "matching pass failed"
  run_wd 2200 once >/dev/null 2>&1 || fail "second matching pass failed"
  assert_equals 1 "$(ledger_rows frozen nudge pending)" "the matching endpoint is used again"
  pass "primary endpoint: another session's heartbeat is never typed into, and a match restores it"
}

test_primary_without_lock_identity_never_trusts_heartbeat_endpoint() {
  local state out
  for state in empty missing both-missing; do
    make_home $'Captain session\n> '
    transcript 3000 "Working." "Testing." "Green."
    owe_input 3000
    if [ "$state" = empty ]; then
      printf '\n' > "$H/state/.lock-session"
    else
      rm "$H/state/.lock-session"
    fi
    if [ "$state" = both-missing ]; then
      jq 'del(.primary.session.trusted_id)' "$H/state/heartbeat.json" > "$H/heartbeat.tmp"
      mv "$H/heartbeat.tmp" "$H/state/heartbeat.json"
    fi
    run_wd 0 once >/dev/null 2>&1 || fail "$state: untrusted pass failed"
    assert_equals "" "$(cat "$H/typed.log")" "$state: an unproven session's pane gets no text"
    assert_equals 0 "$(ledger_rows unread-input nudge pending)" "$state: no nudge is delivered"
    assert_grep 'no recorded terminal endpoint' "$H/data/watchdog/status.md" "$state: missing identity is reported"
    out=$(run_wd 1 scan 2>&1) || fail "$state: scan failed: $out"
    assert_contains "$out" 'endpoint=none:none session=none' "$state: heartbeat cannot supply its own identity proof"

    printf '%s\n' "$SID" > "$H/state/.lock-session"
    jq --arg sid "$SID" '.primary.session.trusted_id = $sid' "$H/state/heartbeat.json" > "$H/heartbeat.tmp"
    mv "$H/heartbeat.tmp" "$H/state/heartbeat.json"
    # A refused nudge also occupies the 900s rate window.
    run_wd 1000 once >/dev/null 2>&1 || fail "$state: matching pass failed"
    assert_equals 1 "$(ledger_rows unread-input nudge pending)" "$state: a proven matching identity restores delivery"
  done
  pass "primary identity: an absent lock id never authenticates a heartbeat, and a recorded match restores delivery"
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

# write_restart_bin <name>: a restart-command that records its argv, takes the lock, and proves pickup.
write_restart_bin() {
  local name=$1
  mkdir -p "$TMP_ROOT/bin"
  cat > "$TMP_ROOT/bin/$name" <<'SH'
#!/usr/bin/env bash
{
  printf '%s\n' "$0"
  printf '%s\n' "$@"
} > "$PWD/launched-argv.txt"
p="$*"
printf '%s\n' "$$" > "$PWD/state/.lock"
eval "${p##*run: }" > "$PWD/pickup.out" 2>&1
exec sleep 100000
SH
  chmod +x "$TMP_ROOT/bin/$name"
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

captain_field() { sed -n "s/^$1=//p" "$H/state/watchdog/captain" 2>/dev/null | tail -n 1; }

# fresh_heartbeat <pane> [session]: the current lock owner, under the session
# (else SID), reports <pane>, generated now.
fresh_heartbeat() {
  jq -n --arg t "$1" --arg s "${2:-$SID}" --argjson e "$(date +%s)" --argjson p "$(head -n 1 "$H/state/.lock")" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:"tmux",target:$t,present:true},session:{trusted_id:$s},writer:{anchor_pid:$p,session_id:$s}}}' \
    > "$H/state/heartbeat.json"
}

# detached_heartbeat <pane>: the real bin/fm-heartbeat.sh --write, run in its own
# detached tmux session with <pane> as its supervisor target, the way an away
# daemon launched from the captain's pane runs it. No harness is in its ancestry.
detached_heartbeat() {
  local dir="$H/detached-writer" done="$H/detached-writer.done" i
  mkdir -p "$dir/bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$dir/bin/quota-axi"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$dir/bin/no-mistakes"
  cat > "$dir/snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schema":"fm-fleet-snapshot.v1","generated":"2026-11-01T00:00:00Z","tasks":[]}'
SH
  chmod +x "$dir/bin/quota-axi" "$dir/bin/no-mistakes" "$dir/snapshot.sh"
  rm -f "$done"
  # The writer inherits the lock owner's own session variables, as a daemon
  # that owner launched does; only its process ancestry is outside the owner.
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" new-session -d -s "detached$CASE_N-$RANDOM" \
    "env -u CODEX_THREAD_ID -u CODEX_SESSION_ID \
      CLAUDE_PID='$(head -n 1 "$H/state/.lock")' CLAUDE_CODE_SESSION_ID='$(head -n 1 "$H/state/.lock-session")' \
      HOME='$H' PATH='$dir/bin:$PATH' FM_HOME='$H' CLAUDE_CONFIG_DIR='$H/claude' \
      FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET='$1' FM_HEARTBEAT_SNAPSHOT_SCRIPT='$dir/snapshot.sh' \
      '$ROOT/bin/fm-heartbeat.sh' --write; : > '$done'"
  for i in $(seq 1 300); do [ -e "$done" ] && break; sleep 0.1; done
  [ -e "$done" ] || fail "the detached heartbeat writer never finished"
}

# relock_same_session: a new process takes the lock under the same session id.
relock_same_session() {
  ( sleep 100000 > /dev/null 2>&1 & printf '%s\n' "$!" > "$H/lockpid" )
  LOCK_PIDS="$LOCK_PIDS $(cat "$H/lockpid")"
  cat "$H/lockpid" > "$H/state/.lock"
}

test_captain_record_follows_the_lock_owner() {
  local moved new_pid new_pane retired_pane bound
  make_home $'Captain session\n✻ Working… (esc to interrupt)' "restart=off
restart-secs=60
restart-command=$TMP_ROOT/fake-captain-move.sh"
  cat > "$TMP_ROOT/fake-captain-move.sh" <<'SH'
#!/usr/bin/env bash
p="$*"
printf '%s\n' "$$" > "$PWD/state/.lock"
printf '00000000-0000-4000-8000-0000000000aa\n' > "$PWD/state/.lock-session"
printf '%s\n' "${TMUX_PANE:-}" > "$PWD/new-pane"
eval "${p##*run: }" > "$PWD/pickup.out" 2>&1
exec sleep 100000
SH
  chmod +x "$TMP_ROOT/fake-captain-move.sh"
  transcript 3000 "Working." "Testing." "Green."
  run_wd 0 once >/dev/null 2>&1
  assert_equals "$LOCKPID" "$(captain_field lock_pid)" "the record names the lock pid"
  assert_equals live "$(captain_field alive)" "a running lock owner reads live"
  assert_equals "tmux $T" "$(captain_field backend) $(captain_field target)" "the record names the lock owner's terminal"
  moved=$(captain_field moved_at)
  [ -n "$moved" ] || fail "the record has no move time"
  assert_grep "captain pid $LOCKPID live on tmux:$T, moved " "$H/data/watchdog/status.md" "the status file names the captain, its liveness, and its terminal"

  # The process dies while its pane stays connected with a stale working screen.
  kill_holder_with_anchor
  run_wd 120 once >/dev/null 2>&1
  assert_equals dead "$(captain_field alive)" "a dead lock owner reads dead whatever its pane shows"
  assert_equals "$moved" "$(captain_field moved_at)" "the same owner has not moved"
  assert_grep "captain pid $LOCKPID dead" "$H/data/watchdog/status.md" "the dead captain is named in the status file"

  # A restart followed by pickup moves the record to the new terminal at once.
  sed 's/^restart=off$/restart=on/' "$H/config/watchdog" > "$H/config/watchdog.new" && mv "$H/config/watchdog.new" "$H/config/watchdog"
  run_wd 240 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows agent-gone restart pending)" "the dead captain restarts: $(ledger | cut -f5-8)"
  wait_pickup || fail "the new captain never proved pickup: $(ledger | cut -f5-8)"
  new_pid=$(cat "$H/state/.lock")
  LOCK_PIDS="$LOCK_PIDS $new_pid"
  new_pane=$(cat "$H/new-pane")
  [ -n "$new_pane" ] && [ "$new_pane" != "$T" ] || fail "the restart opened no new pane: '$new_pane'"
  assert_equals "$new_pid" "$(captain_field lock_pid)" "pickup records the new lock pid"
  assert_equals "tmux $new_pane" "$(captain_field backend) $(captain_field target)" "pickup records the new terminal"
  assert_equals pickup "$(captain_field source)" "pickup wrote the record"
  assert_not_equals "$moved" "$(captain_field moved_at)" "pickup stamps the move"
  moved=$(captain_field moved_at)
  # The old session's heartbeat still names the old pane; the record keeps the new one.
  run_wd 360 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows agent-gone restart "done")" "the pickup was verified: $(ledger | grep restart)"
  assert_equals "$new_pid live tmux $new_pane $moved" \
    "$(captain_field lock_pid) $(captain_field alive) $(captain_field backend) $(captain_field target) $(captain_field moved_at)" \
    "the next pass keeps the moved owner and its terminal"
  assert_grep "captain pid $new_pid live on tmux:$new_pane, moved " "$H/data/watchdog/status.md" "the status file names the new terminal"

  # A handoff moves the lock to a session whose terminal is not proven yet: the
  # record never names the retired session's pane as the captain's.
  make_home $'Captain session\n> '
  transcript 3000 "Working." "Testing." "Green."
  run_wd 0 once >/dev/null 2>&1
  retired_pane=$T
  moved=$(captain_field moved_at)
  ( sleep 100000 > /dev/null 2>&1 & printf '%s\n' "$!" > "$H/lockpid" )
  LOCK_PIDS="$LOCK_PIDS $(cat "$H/lockpid")"
  cat "$H/lockpid" > "$H/state/.lock"
  printf '00000000-0000-4000-8000-0000000000bb\n' > "$H/state/.lock-session"
  run_wd 120 once >/dev/null 2>&1
  assert_equals "$(cat "$H/lockpid") 00000000-0000-4000-8000-0000000000bb" "$(captain_field lock_pid) $(captain_field session)" "the record follows the new lock owner"
  assert_not_equals "$moved" "$(captain_field moved_at)" "the handoff is a move"
  assert_not_equals "$retired_pane" "$(captain_field target)" "the retired session's pane is never named as the captain's"
  moved=$(captain_field moved_at)
  new_pane=$("$REAL_TMUX" -f /dev/null -L "$SOCKET" new-window -d -t "wd$CASE_N" -P -F '#{pane_id}' "$H/agent.sh")
  [ -n "$new_pane" ] && [ "$new_pane" != "$retired_pane" ] || fail "no new pane for the handoff: '$new_pane'"
  fresh_heartbeat "$new_pane" 00000000-0000-4000-8000-0000000000bb
  run_wd 240 once >/dev/null 2>&1
  assert_equals "tmux $new_pane" "$(captain_field backend) $(captain_field target)" "a fresh heartbeat proves the new owner's pane"
  assert_equals "$moved" "$(captain_field moved_at)" "the new owner's first proven terminal is not a second move"

  # A resume keeps the session id in a new pane while the heartbeat still names
  # the old one: the old pane is never named, and the fresh heartbeat is a move.
  make_home $'Captain session\n> '
  transcript 3000 "Working." "Testing." "Green."
  run_wd 0 once >/dev/null 2>&1
  retired_pane=$T
  moved=$(captain_field moved_at)
  new_pane=$("$REAL_TMUX" -f /dev/null -L "$SOCKET" new-window -d -t "wd$CASE_N" -P -F '#{pane_id}' "$H/agent.sh")
  [ -n "$new_pane" ] && [ "$new_pane" != "$retired_pane" ] || fail "no new pane for the resume: '$new_pane'"
  relock_same_session
  run_wd 120 once >/dev/null 2>&1
  assert_equals "$(cat "$H/lockpid") live" "$(captain_field lock_pid) $(captain_field alive)" "the resumed session reads live"
  assert_equals "" "$(captain_field backend)$(captain_field target)" "a heartbeat older than the lock proves no terminal"
  assert_equals "$moved" "$(captain_field moved_at)" "an unproven terminal is not a move"
  fresh_heartbeat "$new_pane"
  run_wd 240 once >/dev/null 2>&1
  assert_equals "tmux $new_pane" "$(captain_field backend) $(captain_field target)" "a fresh heartbeat proves the new pane"
  assert_not_equals "$moved" "$(captain_field moved_at)" "the resumed session's new pane is a move"

  # A lock rewrite under the same session proven back on the same pane is no move.
  make_home $'Captain session\n> '
  transcript 3000 "Working." "Testing." "Green."
  run_wd 0 once >/dev/null 2>&1
  moved=$(captain_field moved_at)
  relock_same_session
  run_wd 120 once >/dev/null 2>&1
  assert_equals "" "$(captain_field target)" "the old heartbeat proves no terminal after the lock rewrite"
  fresh_heartbeat "$T"
  run_wd 240 once >/dev/null 2>&1
  assert_equals "tmux $T $moved" "$(captain_field backend) $(captain_field target) $(captain_field moved_at)" "a re-anchor on the same pane keeps moved_at"

  # A pid now running another process is not the recorded owner.
  make_home $'Captain session\n> '
  transcript 3000 "Working." "Testing." "Green."
  printf '%s\nanchor_pid=%s\nanchor_start=Sat Nov  1 02:00:00 2026\n' "$SID" "$LOCKPID" > "$H/state/.lock-session"
  run_wd 0 once >/dev/null 2>&1
  assert_equals unconfirmed "$(captain_field alive)" "a lock pid running another process instance is not read as live"

  # A Codex owner proven by its session id stays live after its lock pid exits.
  make_home $'Captain session\n> '
  transcript 3000 "Working." "Testing." "Green."
  # macOS hides a platform binary's environment, so the bound process is python.
  ( env CODEX_THREAD_ID="$SID" CODEX_SESSION_ID="$SID" python3 -c 'import time; time.sleep(100000)' > /dev/null 2>&1 & printf '%s\n' "$!" > "$H/bound" )
  bound=$(cat "$H/bound")
  LOCK_PIDS="$LOCK_PIDS $bound"
  for _ in $(seq 1 20); do python3 "$ROOT/bin/fm-session-process.py" bound "$bound" "$SID" && break; sleep 0.1; done
  python3 "$ROOT/bin/fm-session-process.py" bound "$bound" "$SID" || fail "the fixture process is not bound to session $SID"
  kill "$LOCKPID" 2>/dev/null
  while kill -0 "$LOCKPID" 2>/dev/null; do sleep 0.1; done
  printf 'restart=on\nrestart-command=%s\n' "$TMP_ROOT/fake-captain-move.sh" >> "$H/config/watchdog"
  run_wd 0 once >/dev/null 2>&1
  assert_equals live "$(captain_field alive)" "a live process bound to the recorded session keeps the owner live"
  assert_equals 0 "$(ledger_rows agent-gone restart pending)" "a live owner is never restarted as gone: $(ledger | cut -f5-8)"
  assert_no_grep "AGENT-GONE" "$H/data/watchdog/status.md" "a live owner is not reported gone"
  pass "captain record: lock pid, real liveness, terminal, and move time; pickup moves it, a pane never proves it"
}

# lock_mtime: the epoch the fixture's lock was last written.
lock_mtime() { stat -c %Y "$H/state/.lock" 2>/dev/null || stat -f %m "$H/state/.lock"; }

# An away daemon runs in its own detached terminal with the captain's pane as its
# supervisor target, and its watcher keeps writing fresh heartbeats that read the
# session from the lock. After a resume in a new pane, or a handoff, that heartbeat
# names the lock's session, postdates the lock, and still names the retired pane.
test_captain_record_ignores_a_heartbeat_written_outside_the_owner() {
  local moved retired_pane new_pane
  make_home $'Captain session\n> '
  transcript 3000 "Working." "Testing." "Green."
  run_wd 0 once >/dev/null 2>&1
  assert_equals "tmux $T" "$(captain_field backend) $(captain_field target)" "the owner's own heartbeat proves its pane"
  retired_pane=$T
  moved=$(captain_field moved_at)
  new_pane=$("$REAL_TMUX" -f /dev/null -L "$SOCKET" new-window -d -t "wd$CASE_N" -P -F '#{pane_id}' "$H/agent.sh")
  [ -n "$new_pane" ] && [ "$new_pane" != "$retired_pane" ] || fail "no new pane for the resume: '$new_pane'"
  relock_same_session
  detached_heartbeat "$retired_pane"
  jq -e --arg t "$retired_pane" --arg s "$SID" --argjson at "$(lock_mtime)" \
    '.primary.terminal.target == $t and .primary.session.trusted_id == $s and .generated_epoch >= $at
     and .primary.writer.anchor_pid.unknown == true and .primary.writer.session_id.unknown == true' \
    "$H/state/heartbeat.json" >/dev/null \
    || fail "the detached heartbeat meets every proof condition but the writer: $(jq -c '{generated_epoch, primary}' "$H/state/heartbeat.json")"
  run_wd 120 once >/dev/null 2>&1
  assert_equals "$(cat "$H/lockpid") live" "$(captain_field lock_pid) $(captain_field alive)" "the resumed session reads live"
  assert_equals "" "$(captain_field backend)$(captain_field target)" "after a resume, a heartbeat written outside the lock owner proves no terminal"
  assert_equals "$moved" "$(captain_field moved_at)" "an unproven terminal is not a move"
  fresh_heartbeat "$new_pane"
  run_wd 240 once >/dev/null 2>&1
  assert_equals "tmux $new_pane" "$(captain_field backend) $(captain_field target)" "the owner's own heartbeat proves the new pane"

  make_home $'Captain session\n> '
  transcript 3000 "Working." "Testing." "Green."
  run_wd 0 once >/dev/null 2>&1
  retired_pane=$T
  ( sleep 100000 > /dev/null 2>&1 & printf '%s\n' "$!" > "$H/lockpid" )
  LOCK_PIDS="$LOCK_PIDS $(cat "$H/lockpid")"
  cat "$H/lockpid" > "$H/state/.lock"
  printf '00000000-0000-4000-8000-0000000000cc\n' > "$H/state/.lock-session"
  detached_heartbeat "$retired_pane"
  jq -e --arg t "$retired_pane" '.primary.terminal.target == $t
     and .primary.session.trusted_id == "00000000-0000-4000-8000-0000000000cc"' "$H/state/heartbeat.json" >/dev/null \
    || fail "the detached heartbeat does not read the new session from the lock: $(jq -c .primary "$H/state/heartbeat.json")"
  run_wd 120 once >/dev/null 2>&1
  assert_equals "00000000-0000-4000-8000-0000000000cc live" "$(captain_field session) $(captain_field alive)" "the record follows the handoff"
  assert_equals "" "$(captain_field backend)$(captain_field target)" "after a handoff, a heartbeat written outside the lock owner proves no terminal"
  pass "captain record: a heartbeat written outside the lock owner, as by a detached away daemon, never proves a terminal"
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

# A proven frozen stall. The first sight is not static long enough to restart.
run_frozen_restart() {
  transcript 3000 "Working." "Testing." "Green."
  owe_input 3000
  run_wd 0 once >/dev/null 2>&1
  run_wd 1000 once >/dev/null 2>&1
}

window_count() {  # <session>
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" list-windows -t "=$1" | wc -l | tr -d ' '
}

test_watchdog_allows_muse_restart_with_approval_flag() {
  local muse specs spec cmd needle saved sess
  write_restart_bin muse
  cp "$TMP_ROOT/bin/muse" "$FAKEBIN/muse"
  muse=$TMP_ROOT/bin/muse
  specs=(
    "$muse --yolo"$'\037'"--yolo"
    "env $muse --disable-approval"$'\037'"--disable-approval"
    "$muse --approval-mode never"$'\037'"--approval-mode"
    "$muse --approval-mode=never"$'\037'"--approval-mode=never"
    "PATH=$FAKEBIN:\$PATH muse --yolo"$'\037'"--yolo"
  )
  for spec in "${specs[@]}"; do
    cmd=${spec%%$'\037'*}
    needle=${spec#*$'\037'}
    make_home $'Captain session\n> ' "restart=on
max-nudges=0
restart-command=$cmd"
    saved=$(cat "$H/config/watchdog")
    sess=wd$CASE_N
    run_frozen_restart
    assert_equals "$saved" "$(cat "$H/config/watchdog")" "restart-command is not rewritten: $cmd"
    assert_equals 1 "$(ledger_rows frozen restart pending)" "muse with an approval flag restarts: $cmd: $(ledger | cut -f5-8)"
    assert_equals 0 "$(ledger_rows frozen restart refused)" "an approved muse command is not refused: $cmd"
    wait_pickup || fail "approved muse command never proved pickup: $cmd: $(ledger | cut -f5-8)"
    LOCK_PIDS="$LOCK_PIDS $(cat "$H/state/.lock")"
    ls "$H/data/watchdog/handoffs/"*.md >/dev/null 2>&1 || fail "approved muse command wrote no handoff: $cmd"
    assert_equals 2 "$(window_count "$sess")" "approved muse command opens a window: $cmd"
    assert_grep "$needle" "$H/launched-argv.txt" "the launched argv keeps $needle for: $cmd"
    case "$cmd" in
      *"--approval-mode never"*) assert_grep "never" "$H/launched-argv.txt" "approval-mode never stays two words: $cmd" ;;
    esac
    case "$cmd" in
      *--yolo*) ;;
      *) assert_no_grep "--yolo" "$H/launched-argv.txt" "the watchdog did not add --yolo to: $cmd" ;;
    esac
  done
  pass "restart-command: muse with --yolo, --disable-approval, or --approval-mode never is launched unchanged"
}

test_watchdog_adds_yolo_to_bare_muse_restart() {
  local muse cmds cmd saved sess
  write_restart_bin muse
  write_restart_bin muse-bin
  write_restart_bin muse-bin-1.4.13
  cp "$TMP_ROOT/bin/muse" "$FAKEBIN/muse"
  muse=$TMP_ROOT/bin/muse
  cmds=(
    "$muse"
    "env $muse"
    "PATH=$FAKEBIN:\$PATH muse"
    "$muse --approval-mode on-request"
    "PATH=$FAKEBIN:\$PATH env muse --approval-mode on-request"
    "$TMP_ROOT/bin/muse-bin"
    "$TMP_ROOT/bin/muse-bin-1.4.13"
    "\"$muse\""
  )
  for cmd in "${cmds[@]}"; do
    make_home $'Captain session\n> ' "restart=on
max-nudges=0
restart-command=$cmd"
    saved=$(cat "$H/config/watchdog")
    sess=wd$CASE_N
    run_frozen_restart
    assert_equals "$saved" "$(cat "$H/config/watchdog")" "the configured command is not rewritten on disk: $cmd"
    assert_equals 1 "$(ledger_rows frozen restart pending)" "bare muse still restarts: $cmd: $(ledger | cut -f5-8)"
    assert_equals 0 "$(ledger_rows frozen restart refused)" "bare muse is not refused: $cmd"
    assert_equals 1 "$(grep -c -- '--yolo added by default' "$H/state/watchdog/actions.tsv")" "one ledger line says --yolo was added: $cmd"
    wait_pickup || fail "bare muse never proved pickup: $cmd: $(ledger | cut -f5-8)"
    LOCK_PIDS="$LOCK_PIDS $(cat "$H/state/.lock")"
    ls "$H/data/watchdog/handoffs/"*.md >/dev/null 2>&1 || fail "bare muse wrote no handoff: $cmd"
    assert_equals 2 "$(window_count "$sess")" "bare muse opens a window: $cmd"
    assert_equals "--yolo" "$(sed -n 2p "$H/launched-argv.txt")" "--yolo is the first argument after the muse word: $cmd"
    case "$cmd" in
      *on-request) assert_equals "--approval-mode" "$(sed -n 3p "$H/launched-argv.txt")" "the configured arguments follow --yolo: $cmd" ;;
    esac
  done

  make_home $'Captain session\n> \n  7% until auto-compact' "restart=on
restart-command=$muse"
  transcript 3000 "Working." "Testing." "Green."
  FM_WD_TEST_COMPOSER=empty run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows handoff-request nudge pending)" "low context on bare muse still asks for a full handoff: $(ledger | cut -f5-8)"
  pass "restart-command: bare muse is launched with --yolo added by default"
}

test_watchdog_leaves_non_muse_restart_unchanged() {
  local cmds cmd saved sess
  write_restart_bin musescore
  write_restart_bin my-muse
  write_fake_captain
  cmds=(
    "$TMP_ROOT/bin/musescore"
    "$TMP_ROOT/bin/my-muse"
    "$TMP_ROOT/fake-captain.sh"
    "FM_TEST_DIR=/x/muse $TMP_ROOT/bin/musescore"
    "$TMP_ROOT/bin/my-muse --add-dir /x/muse"
    "FM_TEST_DIR=/x/muse $TMP_ROOT/fake-captain.sh"
  )
  for cmd in "${cmds[@]}"; do
    make_home $'Captain session\n> ' "restart=on
max-nudges=0
restart-command=$cmd"
    saved=$(cat "$H/config/watchdog")
    sess=wd$CASE_N
    run_frozen_restart
    assert_equals "$saved" "$(cat "$H/config/watchdog")" "a non-muse restart-command is not rewritten: $cmd"
    assert_equals 1 "$(ledger_rows frozen restart pending)" "a non-muse command still restarts: $cmd: $(ledger | cut -f5-8)"
    assert_equals 0 "$(ledger_rows frozen restart refused)" "a non-muse command is not refused: $cmd"
    wait_pickup || fail "a non-muse command never proved pickup: $cmd: $(ledger | cut -f5-8)"
    LOCK_PIDS="$LOCK_PIDS $(cat "$H/state/.lock")"
    ls "$H/data/watchdog/handoffs/"*.md >/dev/null 2>&1 || fail "a non-muse command wrote no handoff: $cmd"
    assert_equals 2 "$(window_count "$sess")" "a non-muse command opens a window: $cmd"
    case "$cmd" in
      *musescore*|*my-muse*)
        assert_present "$H/launched-argv.txt" "the non-muse command launched: $cmd"
        assert_no_grep "--yolo" "$H/launched-argv.txt" "a non-muse command is not given --yolo: $cmd"
        ;;
    esac
  done
  pass "restart-command: a non-muse command still restarts unchanged"
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

  make_home "Captain session"$'\n'"$(ruled '> finish the summary')" 'restart=on
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
  make_home "Earlier conversation row"$'\n'"$(ruled $'> finish the summary\n  second row' '  ? for shortcuts')" 'restart=on
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
  assert_equals 2 "$(find "$one/state/watchdog/subjects" -mindepth 1 -maxdepth 1 ! -name ".*" | wc -l | tr -d ' ')" "one subject record per home"
  pass "homes that share a basename keep separate state"
}

test_frozen_low_context_clean_draft_gets_one_enter_then_restarts() {
  make_home "Captain session"$'\n'"$(ruled '> finish the summary' '  7% until auto-compact')" 'restart=on
restart-command=/bin/true'
  transcript 8000 "Working." "Testing." "Green."
  owe_input 8000
  local off
  for off in 0 1000 2000 3000 4000 5000 6000; do FM_WD_TEST_COMPOSER=pending run_wd "$off" once >/dev/null 2>&1; done
  assert_equals 1 "$(ledger_rows pasted-input key pending)" "the frozen draft gets one Enter: $(ledger | cut -f5-8)"
  assert_equals 1 "$(ledger_rows frozen restart pending)" "the frozen ladder reaches the restart: $(ledger | cut -f5-8)"
  assert_equals 0 "$(ledger_rows handoff-request nudge pending)" "no handoff nudge goes onto the draft"

  make_home "Captain session"$'\n'"$(ruled '> finish the summary')"
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

  make_home $'Switch to another model?\n\n ❯ 1. Switch to Sonnet\n   2. Add credit\n\nEnter to confirm · Esc to cancel' 'models=claude:haiku'
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
  make_home "Captain session"$'\n'"$(ruled '> finish the summary' '  7% until auto-compact')" 'restart=on
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
  make_home "Merged PR #41, deleted the branch."$'\n'"$rule"$'\nSwitch to another model?\n\n ❯ 1. Switch to Sonnet\n   2. Buy more credits\n\nEnter to confirm · Esc to cancel' 'models=claude:haiku'
  fake_models "$H" ok:"OPTION 1" absent
  transcript 100 "Working."
  run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows dialog key pending)" "conversation above a ruled model-switch picker does not hold it: $(ledger | cut -f5-8)"

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
    $'──────────\nShould we switch to another database?\n ❯ 1. Yes\n   2. No\n\nEnter to select · Esc to cancel' \
    $'──────────\nHow should the worker handle the refactor?\n ❯ 1. Switch to another model\n   2. Keep Sonnet\n\nEnter to select · Esc to cancel' \
    $'──────────\nWhich approach for the parser?\n ❯ 1. Rewrite it\n   2. Switch model for this file\n\nEnter to select · Esc to cancel' \
    $'What should the banner say?\n ❯ 1. Out of credits\n   2. Try again\n\nEnter to select · Esc to cancel' \
    $'──────────\nWhat is the copy for the 429 page?\n ❯ 1. Usage limit reached\n   2. Slow down\n\nEnter to select · Esc to cancel' \
    $'Should the API add a rate limit to this endpoint?\n ❯ 1. Yes\n   2. No\n\nEnter to select · Esc to cancel' \
    $'Which usage limit should the plan page show?\n ❯ 1. 100\n   2. 200\n\nEnter to select · Esc to cancel'; do
    make_home "$screen" 'models=claude:haiku'
    fake_models "$H" ok:"OPTION 1" absent
    transcript 100 "Working."
    run_wd 0 once >/dev/null 2>&1
    [ ! -s "$H/model.log" ] || fail "a judge was asked about an ordinary question: $(cat "$H/model.log")"
    assert_equals 0 "$(ledger | awk -F'\t' '$6 == "key"' | wc -l | tr -d ' ')" "an ordinary question gets no digit: $(ledger | cut -f5-8)"
    assert_grep "question dialog waiting" "$H/data/watchdog/status.md" "the ordinary question is reported"
  done
  make_home $'You have hit your weekly limit.\n ❯ 1. git push -f origin main\n   2. Wait\n\nEnter to confirm · Esc to cancel' 'models=claude:haiku'
  fake_models "$H" ok:"OPTION 1" absent
  transcript 100 "Working."
  run_wd 0 once >/dev/null 2>&1
  [ ! -s "$H/model.log" ] || fail "a judge saw a force-push option: $(cat "$H/model.log")"
  assert_equals 0 "$(ledger_rows dialog key pending)" "a force-push option gets no key: $(ledger | cut -f5-8)"
  pass "dialog: the kind comes from the dialog, not the conversation above it"
}

test_reserved_model_switch_dialog_is_held() {
  make_home $'Switch to another model; release the sonnet build to production?\n ❯ 1. Yes\n   2. No\n\nEnter to confirm · Esc to cancel' 'models=claude:haiku'
  fake_models "$H" ok:"OPTION 1" absent
  transcript 100 "Working."
  run_wd 0 once >/dev/null 2>&1
  assert_equals 0 "$(ledger | awk -F'\t' '$6 == "key"' | wc -l | tr -d ' ')" "no key goes to a reserved dialog: $(ledger | cut -f5-8)"
  [ ! -s "$H/model.log" ] || fail "a model saw a reserved dialog: $(cat "$H/model.log")"
  [ ! -s "$H/typed.log" ] || fail "something was typed: $(cat "$H/typed.log")"
  assert_grep "owner-reserved category; held" "$H/data/watchdog/status.md" "the hold is a gap"

  make_home $'Switch to another model?\n\n ❯ 1. Switch to Sonnet\n   2. Buy more credits\n\nEnter to confirm · Esc to cancel' 'models=claude:haiku'
  fake_models "$H" ok:"OPTION 1" absent
  transcript 100 "Working."
  run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows dialog key pending)" "an ordinary model-switch dialog gets its key: $(ledger | cut -f5-8)"
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

test_claude_judge_keeps_the_default_login() {
  make_home $'Captain session\n> ' 'models=claude:haiku'
  fake_models "$H" ok:WORK absent
  # The real CLI loses its login when CLAUDE_CONFIG_DIR names the default directory.
  mv "$FAKEBIN/claude" "$FAKEBIN/claude.real"
  cat > "$FAKEBIN/claude" <<SH
#!/usr/bin/env bash
printf '%s\n' "\${CLAUDE_CONFIG_DIR-unset}" >> "$H/config-dir.log"
[ "\${CLAUDE_CONFIG_DIR:-}" != "\$HOME/.claude" ] || { printf '{"is_error":true,"result":"Not logged in"}\n'; exit 1; }
exec "$FAKEBIN/claude.real" "\$@"
SH
  chmod +x "$FAKEBIN/claude"
  out=$(printf 'is this a loop?' | env -u CLAUDE_CONFIG_DIR FM_TEST_SEAM=1 FM_WD_NOW="$BASE" FM_HOME="$H" bash "$WD" judge loop '(LOOP|WORK)') \
    || fail "the Claude judge failed on the default setup"
  assert_equals WORK "$out" "the judge answers with the default login"
  assert_equals unset "$(tail -n 1 "$H/config-dir.log")" "no config directory is forced on the default setup"
  out=$(printf 'is this a loop?' | CLAUDE_CONFIG_DIR="$H/inherited" FM_TEST_SEAM=1 FM_WD_NOW="$BASE" FM_HOME="$H" bash "$WD" judge loop '(LOOP|WORK)') \
    || fail "the judge failed with an inherited config directory"
  assert_equals "$H/inherited" "$(tail -n 1 "$H/config-dir.log")" "an inherited config directory is kept"
  printf 'ordinary\n' > "$H/config/claude-account"
  out=$(printf 'is this a loop?' | CLAUDE_CONFIG_DIR="$H/inherited" FM_TEST_SEAM=1 FM_WD_NOW="$BASE" FM_HOME="$H" bash "$WD" judge loop '(LOOP|WORK)') \
    || fail "the judge failed with an ordinary account"
  assert_equals unset "$(tail -n 1 "$H/config-dir.log")" "an ordinary account leaves the variable unset"
  mkdir -p "$H/pinned"
  printf '%s\n' "$H/pinned" > "$H/config/claude-account"
  out=$(printf 'is this a loop?' | CLAUDE_CONFIG_DIR="$H/inherited" FM_TEST_SEAM=1 FM_WD_NOW="$BASE" FM_HOME="$H" bash "$WD" judge loop '(LOOP|WORK)') \
    || fail "the judge failed with a pinned account"
  assert_equals "$H/pinned" "$(tail -n 1 "$H/config-dir.log")" "a pinned account is used"
  printf 'relative-path\n' > "$H/config/claude-account"
  printf 'is this a loop?' | FM_TEST_SEAM=1 FM_WD_NOW="$BASE" FM_HOME="$H" bash "$WD" judge loop '(LOOP|WORK)' >/dev/null 2>&1 \
    && fail "an invalid pin still reached the judge"
  assert_equals "$H/pinned" "$(tail -n 1 "$H/config-dir.log")" "an invalid pin calls no model"
  printf 'claude-config-dir=%s\n' "$H/account" >> "$H/config/watchdog"
  out=$(printf 'is this a loop?' | CLAUDE_CONFIG_DIR="$H/inherited" FM_TEST_SEAM=1 FM_WD_NOW="$BASE" FM_HOME="$H" bash "$WD" judge loop '(LOOP|WORK)') \
    || fail "the judge failed with a configured account"
  assert_equals "$H/account" "$(tail -n 1 "$H/config-dir.log")" "a configured account wins"
  rm -f "$FAKEBIN/claude" "$FAKEBIN/claude.real"
  pass "the Claude judge keeps the default login unless an account directory is set"
}

test_unknown_heartbeat_endpoint_is_not_reported_ok() {
  make_home $'Do you want to proceed?\n❯ 1. Yes\n  2. No\n'
  transcript 100 "Working."
  jq -n --arg s "$SID" --argjson e "$BASE" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{
       terminal:{backend:{unknown:true,reason:"no supervisor endpoint discovered"},target:{unknown:true,reason:"no supervisor endpoint discovered"},present:{unknown:true,reason:"no supervisor endpoint discovered"}},
       session:{trusted_id:$s}, context_left:{remaining:{percent:42}}}}' > "$H/state/heartbeat.json"
  run_wd 10 once >/dev/null 2>&1
  assert_grep "NO-ENDPOINT" "$H/data/watchdog/status.md" "the health line does not read ok"
  assert_no_grep ": ok" "$H/data/watchdog/status.md" "a home the watchdog cannot see never reads ok"
  assert_grep "no recorded terminal endpoint" "$H/data/watchdog/status.md" "the limit is a reported gap"
  assert_grep "ctx 42%" "$H/data/watchdog/status.md" "the rest of the heartbeat row is still read"
  jq --argjson e "$((BASE - 2000))" '.generated_epoch = $e' "$H/state/heartbeat.json" > "$H/hb.tmp" && mv "$H/hb.tmp" "$H/state/heartbeat.json"
  run_wd 10 once >/dev/null 2>&1
  assert_grep "watcher heartbeat is 33m old" "$H/data/watchdog/status.md" "the stale watcher check still fires"
  pass "a heartbeat with an unknown endpoint keeps its row and reads as a gap, not ok"
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
  # The survey was answered and blank rows pushed it past the 40-row pane; tmux
  # keeps it in history. Blank rows keep it among a scrollback read's last text.
  # clear(1) would not do: where its terminfo has E3, as on Linux, it also erases
  # the history.
  cat > "$H/agent.sh" <<SH
#!/usr/bin/env bash
printf 'work output\n● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss\n'
sleep 0.3
printf '\n%.0s' {1..45}
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

test_away_permission_dialog_pages_the_owner() {
  local dialog=$'Do you want to proceed?\n ❯ 1. Yes\n   2. No, and tell Claude what to do differently\n\nEsc to cancel'
  local secret=$'Do you want to run curl -H "Authorization: Bearer abc123def456"?\n ❯ 1. Yes\n   2. No\n\nEsc to cancel'
  make_home "$dialog"
  transcript 100 "Working."
  printf '%s\n' "$LOCKPID" > "$H/state/.supervise-daemon.pid"
  printf "command:cat >> '%s'\n" "$H/paged.log" > "$H/config/wedge-alarm"
  run_wd 0 once >/dev/null 2>&1
  assert_equals 0 "$(ledger | awk -F'\t' '$6 == "page"' | wc -l | tr -d ' ')" "a present owner is not paged: $(ledger | cut -f5-8)"
  [ ! -e "$H/paged.log" ] || fail "a present owner was paged: $(cat "$H/paged.log")"

  : > "$H/state/.afk"
  run_wd 10 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows dialog page pending)" "an away permission dialog pages the owner: $(ledger | cut -f5-8)"
  assert_equals 1 "$(ledger_rows dialog page "done")" "the page was delivered: $(ledger | cut -f5-8)"
  assert_grep "a permission dialog blocks the away session" "$H/paged.log" "the page names the blocked away session"
  assert_no_grep "Do you want to proceed" "$H/paged.log" "the page carries no dialog text"
  assert_contains "$(ledger | awk -F'\t' '$6 == "page" && $7 == "pending" { print $8 }')" "permission: Do you want to proceed?" "the ledger records which dialog fired"
  assert_grep "permission dialog waiting" "$H/data/watchdog/status.md" "the dialog is still reported"
  [ ! -s "$H/typed.log" ] || fail "the watchdog typed into a permission dialog: $(cat "$H/typed.log")"

  run_wd 300 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows dialog page pending)" "a second page waits for nudge-secs: $(ledger | cut -f5-8)"
  run_wd 1000 once >/dev/null 2>&1
  assert_equals 2 "$(ledger_rows dialog page pending)" "a dialog still showing after nudge-secs pages again: $(ledger | cut -f5-8)"

  printf 'quiet\n' > "$H/state/.afk"
  run_wd 2000 once >/dev/null 2>&1
  assert_equals 2 "$(ledger_rows dialog page pending)" "quiet mode, where the owner watches the session, is not paged: $(ledger | cut -f5-8)"

  : > "$H/state/.afk"
  printf 'off\n' > "$H/config/wedge-alarm"
  run_wd 3000 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows dialog page refused)" "alerts turned off refuse the page: $(ledger | cut -f5-8)"
  assert_grep "permission dialog not paged" "$H/data/watchdog/status.md" "the unpaged dialog is a reported gap"
  assert_equals 2 "$(grep -c 'a permission dialog blocks' "$H/paged.log")" "nothing reached the owner while alerts were off"

  make_home "$secret"
  transcript 100 "Working."
  printf '%s\n' "$LOCKPID" > "$H/state/.supervise-daemon.pid"
  printf "command:cat >> '%s'\n" "$H/paged.log" > "$H/config/wedge-alarm"
  : > "$H/state/.afk"
  run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows dialog page "done")" "a secret-looking dialog still pages the owner: $(ledger | cut -f5-8)"
  assert_no_grep "abc123def456" "$H/state/watchdog/actions.tsv" "a secret-looking dialog text stays out of the ledger"
  assert_grep "withheld: the dialog text looks like a secret" "$H/state/watchdog/actions.tsv" "the withheld dialog is still recorded"

  make_home "Do you want to run $(printf 'x%.0s' $(seq 274)) sk-abcdefghijklmnop?"$'\n ❯ 1. Yes\n   2. No\n\nEsc to cancel'
  transcript 100 "Working."
  printf '%s\n' "$LOCKPID" > "$H/state/.supervise-daemon.pid"
  printf "command:cat >> '%s'\n" "$H/paged.log" > "$H/config/wedge-alarm"
  : > "$H/state/.afk"
  run_wd 0 once >/dev/null 2>&1
  assert_no_grep "sk-a" "$H/state/watchdog/actions.tsv" "a secret cut at the record limit stays out of the ledger"
  assert_grep "withheld: the dialog text looks like a secret" "$H/state/watchdog/actions.tsv" "a secret past the record limit is still withheld"

  make_home "$dialog" 'mode=dry-run'
  transcript 100 "Working."
  printf '%s\n' "$LOCKPID" > "$H/state/.supervise-daemon.pid"
  printf "command:cat >> '%s'\n" "$H/paged.log" > "$H/config/wedge-alarm"
  : > "$H/state/.afk"
  run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows dialog page dry-run)" "dry-run records the page it would send: $(ledger | cut -f5-8)"
  [ ! -e "$H/paged.log" ] || fail "dry-run paged the owner: $(cat "$H/paged.log")"
  pass "away permission dialog: the owner is paged once per window, the dialog is recorded, and no key is sent"
}

# worker_pane <id> <kind> <screen>: a real tmux pane and state/<id>.meta.
# Sets WP to the pane id.
worker_pane() {
  local id=$1 kind=$2 screen=$3 sess
  printf '%s\n' "$screen" > "$H/worker-$id.txt"
  cat > "$H/worker-$id.sh" <<SH
#!/usr/bin/env bash
cat "$H/worker-$id.txt"
stty -echo
exec cat >> "$H/worker-$id.typed"
SH
  chmod +x "$H/worker-$id.sh"
  : > "$H/worker-$id.typed"
  sess="wk${id}${CASE_N}"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" new-session -d -s "$sess" -x 160 -y 40 "$H/worker-$id.sh"
  WP=$("$REAL_TMUX" -f /dev/null -L "$SOCKET" list-panes -t "=$sess" -F '#{pane_id}' | head -n 1)
  printf 'kind=%s\nbackend=tmux\nwindow=%s\nendpoint_task_id=%s\n' "$kind" "$WP" "$id" > "$H/state/$id.meta"
}

page_subjects() {  # <phase>
  awk -F'\t' -v p="$1" '$5 == "dialog" && $6 == "page" && $7 == p { print $4 }' "$H/state/watchdog/actions.tsv" 2>/dev/null | sort
}

test_worker_permission_dialog_pages_the_owner() {
  local dialog=$'Do you want to proceed?\n ❯ 1. Yes\n   2. No, and tell Claude what to do differently\n\nEsc to cancel'
  local question=$'Which plan should I follow?\n ❯ 1. Plan A (Recommended)\n   2. Plan B\n\nEnter to select · ↑/↓ to navigate · Esc to cancel'
  local show_pane gone_sess
  make_home $'Captain session\n> '
  transcript 100 "Working."
  worker_pane show ship "$dialog"
  show_pane=$WP
  worker_pane plain ship $'work output\n> '
  worker_pane other scout "$dialog"
  worker_pane ask ship "$question"
  worker_pane gone scout "$dialog"
  gone_sess="wkgone${CASE_N}"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" kill-session -t "=$gone_sess"
  # A second-mate record is not a ship or scout pane, even on a dialog the worker shows.
  printf 'kind=secondmate\nbackend=tmux\nwindow=%s\nendpoint_task_id=mate\n' "$show_pane" > "$H/state/mate.meta"
  sleep 0.5
  printf '%s\n' "$LOCKPID" > "$H/state/.supervise-daemon.pid"
  printf "command:cat >> '%s'\n" "$H/paged.log" > "$H/config/wedge-alarm"

  run_wd 0 once >/dev/null 2>&1 || fail "a pass with a gone worker endpoint failed"
  assert_equals 0 "$(ledger | awk -F'\t' '$6 == "page"' | wc -l | tr -d ' ')" "a present owner is not paged for a worker dialog: $(ledger | cut -f4-8)"
  [ ! -e "$H/paged.log" ] || fail "a present owner was paged for a worker dialog: $(cat "$H/paged.log")"

  : > "$H/state/.afk"
  run_wd 10 once >/dev/null 2>&1 || fail "the away pass failed"
  assert_equals $'worker:other\nworker:show' "$(page_subjects pending | sort -u)" "only the ship and scout dialogs page: $(page_subjects pending | tr '\n' ' ')"
  assert_equals 2 "$(ledger_rows dialog page pending)" "each worker dialog pages once: $(ledger | cut -f4-8)"
  assert_equals 2 "$(ledger_rows dialog page "done")" "both worker pages were delivered: $(ledger | cut -f4-8)"
  assert_grep "worker show" "$H/paged.log" "the page names the ship worker"
  assert_grep "worker other" "$H/paged.log" "the page names the scout worker"
  assert_no_grep "worker plain" "$H/paged.log" "a worker pane with no dialog is not paged"
  assert_no_grep "worker gone" "$H/paged.log" "a gone worker endpoint is not paged"
  assert_no_grep "worker ask" "$H/paged.log" "a question dialog on a worker gets no page"
  assert_no_grep "worker mate" "$H/paged.log" "a second-mate record is not a worker pane"
  assert_no_grep "Do you want to proceed" "$H/paged.log" "the worker page carries no dialog text"
  assert_grep "permission dialog waiting on worker show" "$H/data/watchdog/status.md" "the ship dialog is reported"
  assert_grep "worker gone endpoint is gone" "$H/data/watchdog/status.md" "the gone endpoint is reported"
  [ ! -s "$H/worker-show.typed" ] || fail "the watchdog typed into a worker permission dialog: $(cat "$H/worker-show.typed")"
  [ ! -s "$H/worker-ask.typed" ] || fail "the watchdog answered a worker question dialog: $(cat "$H/worker-ask.typed")"
  [ ! -s "$H/worker-plain.typed" ] || fail "the watchdog typed into a worker pane with no dialog: $(cat "$H/worker-plain.typed")"

  run_wd 300 once >/dev/null 2>&1
  assert_equals 2 "$(ledger_rows dialog page pending)" "each worker page waits for its own nudge-secs: $(ledger | cut -f4-8)"
  run_wd 1000 once >/dev/null 2>&1
  assert_equals 4 "$(ledger_rows dialog page pending)" "each dialog still showing after nudge-secs pages again: $(ledger | cut -f4-8)"
  assert_equals $'worker:other\nworker:show' "$(page_subjects pending | sort -u)" "the second window still pages only those two workers"

  printf 'quiet\n' > "$H/state/.afk"
  run_wd 2000 once >/dev/null 2>&1
  assert_equals 4 "$(ledger_rows dialog page pending)" "quiet mode does not page a worker dialog: $(ledger | cut -f4-8)"
  pass "worker permission dialog: ship and scout panes page on their own windows, a plain pane and a question do not, and a gone endpoint is not read"
}

test_never_merges_deploys_or_messages_owner() {
  # Every act-mode case above ran with gh, gh-axi, notifiers, and mail faked.
  # The away permission-dialog page reaches only a home's configured alert
  # channel, which test_away_permission_dialog_pages_the_owner sets to a command.
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

test_usage_limit_unknown_harness_queues() {
  local snap
  make_home $'You have hit your weekly limit for Opus.\n\n ❯ 1. Switch to Sonnet\n   2. Wait for the limit to reset\n   3. Buy more credits\n\nEnter to confirm · Esc to cancel' \
    'reroute-candidates=kimi:kimi-k2,codex:gpt-5.4'
  snap="$H/quota.json"
  cat > "$snap" <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "kimi",
      "windows": [],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 0,
            "runway": { "status": "exhausted_now" }
          }
        ]
      }
    },
    {
      "provider": "codex",
      "windows": [],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 40,
            "runway": { "status": "through_reset" }
          }
        ]
      }
    }
  ]
}
JSON
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
cat "$snap"
SH
  chmod +x "$FAKEBIN/quota-axi"
  cat > "$FAKEBIN/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf 'control %s\n' "$*" >> "$H/control.log"
exit 1
SH
  chmod +x "$FAKEBIN/fm-control.sh"
  transcript 100 "Working."
  run_wd 0 once >/dev/null 2>&1 || fail "usage-limit pass failed"
  assert_equals 0 "$(ledger | awk -F'\t' '$6 == "key"' | wc -l | tr -d ' ')" "usage-limit must not press a picker key: $(ledger | cut -f5-8)"
  [ ! -s "$H/typed.log" ] || fail "usage-limit typed into the pane: $(cat "$H/typed.log")"
  [ ! -s "$H/model.log" ] || fail "usage-limit asked a judge: $(cat "$H/model.log")"
  [ ! -e "$H/control.log" ] || fail "watchdog relaunched: $(cat "$H/control.log")"
  assert_equals 1 "$(ledger_rows quota suggest held)" "the pick is recorded, not launched: $(ledger | cut -f5-8)"
  assert_grep "Unknown harness" "$H/data/watchdog/status.md" "a pane with no task record must name unknown harness"
  assert_not_contains "$(cat "$H/data/watchdog/status.md")" "Suggested pick: codex" \
    "unknown harness must not name a pick"
  rm -f "$FAKEBIN/quota-axi" "$FAKEBIN/fm-control.sh"
  pass "usage-limit: unknown harness queues and names the reason"
}

test_claude_pinned_secondmate_with_tooling_gets_no_codex_pick() {
  local parent mate pin snap
  make_home $'Captain session\n> '
  parent=$H
  make_home $'You have hit your weekly limit for Opus.\n\n ❯ 1. Switch to Sonnet\n   2. Wait for the limit to reset\n   3. Buy more credits\n\nEnter to confirm · Esc to cancel'
  mate=$H
  pin="$parent/pin-claude"
  mkdir -p "$pin"
  printf '%s\n' '{"mcpServers":{"docs":{"command":"true"}}}' > "$pin/.claude.json"
  printf '%s\n' "$pin" > "$parent/config/claude-account"
  printf -- '- ghost-mate - test mate (home: %s)\n' "$mate" > "$parent/data/secondmates.md"
  {
    echo "harness=claude"
    echo "kind=secondmate"
    echo "home=$mate"
    echo "worktree=$mate"
    echo "model=default"
  } > "$parent/state/ghost-mate.meta"
  printf 'mode=act\nclaude-config-dirs=%s\nkey-settle-secs=1\nmodels=\nreroute-candidates=codex:gpt-5.4\n' \
    "$parent/claude" > "$parent/config/watchdog"
  snap="$parent/quota.json"
  cat > "$snap" <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "codex",
      "windows": [],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 40,
            "runway": { "status": "through_reset" }
          }
        ]
      }
    }
  ]
}
JSON
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
cat "$snap"
SH
  chmod +x "$FAKEBIN/quota-axi"
  cat > "$FAKEBIN/fm-control.sh" <<SH
#!/usr/bin/env bash
printf 'control %s\n' "\$*" >> "$parent/control.log"
exit 1
SH
  chmod +x "$FAKEBIN/fm-control.sh"
  transcript 100 "Working."
  H=$parent
  mkdir -p "$parent/state/watchdog"
  printf 'stale leftover\n' > "$parent/state/watchdog/.quota-none-reason"
  run_wd 0 once >/dev/null 2>&1 || fail "secondmate usage-limit pass failed"
  [ ! -e "$parent/control.log" ] || fail "watchdog relaunched: $(cat "$parent/control.log")"
  assert_equals 1 "$(ledger_rows quota suggest held)" "the queue is recorded, not launched: $(ledger | cut -f5-8)"
  assert_grep "Claude-specific tooling present" "$parent/data/watchdog/status.md" \
    "a Claude-pinned mate with tooling must name the tooling reason"
  assert_not_contains "$(cat "$parent/data/watchdog/status.md")" "stale leftover" \
    "a stale none-reason must be cleared before the next pick"
  assert_not_contains "$(cat "$parent/data/watchdog/status.md")" "Suggested pick: codex" \
    "Codex must not be named while Claude-specific tooling is present"
  rm -f "$FAKEBIN/quota-axi" "$FAKEBIN/fm-control.sh"
  pass "usage-limit: a Claude-pinned secondmate with tooling is queued, not picked for Codex"
}

wd_quota_snapshot() {  # <file>
  cat > "$1" <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "claude",
      "windows": [],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 40,
            "runway": { "status": "through_reset" }
          }
        ]
      }
    },
    {
      "provider": "codex",
      "windows": [],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 40,
            "runway": { "status": "through_reset" }
          }
        ]
      }
    }
  ]
}
JSON
}

test_ordinary_home_claude_json_mcp_blocks_the_move() {
  local parent mate user snap
  make_home $'Captain session\n> '
  parent=$H
  make_home $'You have hit your weekly limit for Opus.\n\n ❯ 1. Switch to Sonnet\n   2. Wait for the limit to reset\n   3. Buy more credits\n\nEnter to confirm · Esc to cancel'
  mate=$H
  user="$parent/user"
  mkdir -p "$user/.claude"
  printf '%s\n' '{"mcpServers":{"docs":{"command":"true"}}}' > "$user/.claude.json"
  printf -- '- ghost-mate - test mate (home: %s)\n' "$mate" > "$parent/data/secondmates.md"
  {
    echo "harness=claude"
    echo "kind=secondmate"
    echo "home=$mate"
    echo "worktree=$mate"
    echo "model=default"
  } > "$parent/state/ghost-mate.meta"
  printf 'mode=act\nclaude-config-dirs=%s\nkey-settle-secs=1\nmodels=\nreroute-candidates=codex:gpt-5.4\n' \
    "$parent/claude" > "$parent/config/watchdog"
  snap="$parent/quota.json"
  wd_quota_snapshot "$snap"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
cat "$snap"
SH
  chmod +x "$FAKEBIN/quota-axi"
  cat > "$FAKEBIN/fm-control.sh" <<SH
#!/usr/bin/env bash
printf 'control %s\n' "\$*" >> "$parent/control.log"
exit 1
SH
  chmod +x "$FAKEBIN/fm-control.sh"
  transcript 100 "Working."
  H=$parent
  HOME="$user" run_wd 0 once >/dev/null 2>&1 || fail "ordinary .claude.json pass failed"
  assert_equals 1 "$(ledger_rows quota suggest held)" "the queue is recorded: $(ledger | cut -f5-8)"
  assert_not_contains "$(cat "$parent/data/watchdog/status.md")" "Suggested pick: codex" \
    "MCP only in \$HOME/.claude.json must block a Codex pick"
  rm -f "$FAKEBIN/quota-axi" "$FAKEBIN/fm-control.sh"
  pass "usage-limit: MCP only in \$HOME/.claude.json blocks the move"
}

test_codex_task_keeps_same_harness_candidates_under_a_claude_pin() {
  local pin snap
  make_home $'Captain session\n> ' 'reroute-candidates=codex:gpt-5.4,claude:claude-3-5-sonnet'
  pin="$H/pin-claude"
  mkdir -p "$pin" "$H/wt"
  printf '%s\n' '{"mcpServers":{"docs":{"command":"true"}}}' > "$pin/.claude.json"
  printf '%s\n' "$pin" > "$H/config/claude-account"
  {
    echo "harness=codex"
    echo "kind=ship"
    echo "worktree=$H/wt"
    echo "model=default"
  } > "$H/state/ship1.meta"
  printf 'paused [at=%s]: hit the quota floor\n' "$((BASE - 9000))" > "$H/state/ship1.status"
  snap="$H/quota.json"
  wd_quota_snapshot "$snap"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
cat "$snap"
SH
  chmod +x "$FAKEBIN/quota-axi"
  transcript 100 "Working."
  run_wd 0 once >/dev/null 2>&1 || fail "codex quota-floor pass failed"
  assert_grep "Suggested pick: codex gpt-5.4" "$H/state/watchdog/actions.tsv" \
    "a Codex task must keep its same-harness candidates despite a Claude pin"
  assert_no_grep "Suggested pick: claude" "$H/state/watchdog/actions.tsv" \
    "the Claude pin must not reroute a Codex task onto Claude"
  rm -f "$FAKEBIN/quota-axi"
  pass "quota floor: a Codex task under a Claude pin keeps same-harness candidates"
}

test_usage_limit_claude_without_tooling_names_a_pick() {
  local parent mate user snap
  make_home $'Captain session\n> '
  parent=$H
  make_home $'You have hit your weekly limit for Opus.\n\n ❯ 1. Switch to Sonnet\n   2. Wait for the limit to reset\n   3. Buy more credits\n\nEnter to confirm · Esc to cancel'
  mate=$H
  user="$parent/user"
  mkdir -p "$user/.claude"
  printf -- '- ghost-mate - test mate (home: %s)\n' "$mate" > "$parent/data/secondmates.md"
  {
    echo "harness=claude"
    echo "kind=secondmate"
    echo "home=$mate"
    echo "worktree=$mate"
    echo "model=default"
  } > "$parent/state/ghost-mate.meta"
  printf 'mode=act\nclaude-config-dirs=%s\nkey-settle-secs=1\nmodels=\nreroute-candidates=codex:gpt-5.4\n' \
    "$parent/claude" > "$parent/config/watchdog"
  snap="$parent/quota.json"
  wd_quota_snapshot "$snap"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
cat "$snap"
SH
  chmod +x "$FAKEBIN/quota-axi"
  cat > "$FAKEBIN/fm-control.sh" <<SH
#!/usr/bin/env bash
printf 'control %s\n' "\$*" >> "$parent/control.log"
exit 1
SH
  chmod +x "$FAKEBIN/fm-control.sh"
  transcript 100 "Working."
  H=$parent
  HOME="$user" run_wd 0 once >/dev/null 2>&1 || fail "clean Claude usage-limit pass failed"
  [ ! -e "$parent/control.log" ] || fail "watchdog relaunched: $(cat "$parent/control.log")"
  assert_grep "Suggested pick: codex gpt-5.4" "$parent/data/watchdog/status.md" \
    "a Claude mate with no tooling must still name the pick"
  assert_grep "Queue until reset" "$parent/data/watchdog/status.md" \
    "a pane-text usage-limit must queue until reset"
  assert_not_contains "$(cat "$parent/data/watchdog/status.md")" "Supervisor relaunches" \
    "a pane-text usage-limit must not send the supervisor to relaunch"
  assert_equals 1 "$(ledger_rows quota suggest held)" "the home pick is recorded once: $(ledger | cut -f4-8)"
  HOME="$user" run_wd 1 once >/dev/null 2>&1 || fail "rate-limited home usage-limit pass failed"
  assert_equals 1 "$(ledger_rows quota suggest held)" "nudge-secs must not add another home pick: $(ledger | cut -f4-8)"
  rm -f "$FAKEBIN/quota-axi" "$FAKEBIN/fm-control.sh"
  pass "usage-limit: a Claude mate with no tooling names the pick and does not relaunch"
}

test_unreadable_claude_account_pin_gets_no_pick() {
  local parent mate snap
  make_home $'Captain session\n> '
  parent=$H
  make_home $'You have hit your weekly limit for Opus.\n\n ❯ 1. Switch to Sonnet\n   2. Wait for the limit to reset\n   3. Buy more credits\n\nEnter to confirm · Esc to cancel'
  mate=$H
  mkdir -p "$parent/config"
  printf 'not-a-path\n' > "$parent/config/claude-account"
  printf -- '- ghost-mate - test mate (home: %s)\n' "$mate" > "$parent/data/secondmates.md"
  {
    echo "harness=claude"
    echo "kind=secondmate"
    echo "home=$mate"
    echo "worktree=$mate"
    echo "model=default"
  } > "$parent/state/ghost-mate.meta"
  printf 'mode=act\nclaude-config-dirs=%s\nkey-settle-secs=1\nmodels=\nreroute-candidates=codex:gpt-5.4\n' \
    "$parent/claude" > "$parent/config/watchdog"
  snap="$parent/quota.json"
  wd_quota_snapshot "$snap"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
cat "$snap"
SH
  chmod +x "$FAKEBIN/quota-axi"
  cat > "$FAKEBIN/fm-control.sh" <<SH
#!/usr/bin/env bash
printf 'control %s\n' "\$*" >> "$parent/control.log"
exit 1
SH
  chmod +x "$FAKEBIN/fm-control.sh"
  transcript 100 "Working."
  H=$parent
  run_wd 0 once >/dev/null 2>&1 || fail "broken-pin usage-limit pass failed"
  [ ! -e "$parent/control.log" ] || fail "watchdog relaunched: $(cat "$parent/control.log")"
  assert_equals 1 "$(ledger_rows quota suggest held)" "the queue is recorded, not launched: $(ledger | cut -f5-8)"
  assert_not_contains "$(cat "$parent/data/watchdog/status.md")" "Suggested pick:" \
    "an unreadable claude-account pin must not name a pick"
  rm -f "$FAKEBIN/quota-axi" "$FAKEBIN/fm-control.sh"
  pass "usage-limit: an unreadable claude-account pin gets no pick"
}

test_worker_usage_limit_names_a_pick() {
  local snap dialog calls
  dialog=$'You have hit your weekly limit for Opus.\n\n ❯ 1. Switch to Sonnet\n   2. Wait for the limit to reset\n   3. Buy more credits\n\nEnter to confirm · Esc to cancel'
  make_home $'Captain session\n> ' 'reroute-candidates=codex:gpt-5.4'
  mkdir -p "$H/wt" "$H/wt2" "$H/user/.claude"
  worker_pane limit ship "$dialog"
  {
    echo "harness=claude"
    echo "kind=ship"
    echo "worktree=$H/wt"
    echo "model=default"
  } >> "$H/state/limit.meta"
  worker_pane limit2 ship "$dialog"
  {
    echo "harness=claude"
    echo "kind=ship"
    echo "worktree=$H/wt2"
    echo "model=default"
  } >> "$H/state/limit2.meta"
  snap="$H/quota.json"
  wd_quota_snapshot "$snap"
  : > "$H/quota-axi.calls"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
printf 'call\n' >> "$H/quota-axi.calls"
cat "$snap"
SH
  chmod +x "$FAKEBIN/quota-axi"
  cat > "$FAKEBIN/fm-control.sh" <<SH
#!/usr/bin/env bash
printf 'control %s\n' "\$*" >> "$H/control.log"
exit 1
SH
  chmod +x "$FAKEBIN/fm-control.sh"
  transcript 100 "Working."
  sleep 0.5
  HOME="$H/user" run_wd 0 once >/dev/null 2>&1 || fail "worker usage-limit pass failed"
  [ ! -e "$H/control.log" ] || fail "watchdog relaunched: $(cat "$H/control.log")"
  [ ! -s "$H/worker-limit.typed" ] || fail "the watchdog typed into a worker usage-limit picker: $(cat "$H/worker-limit.typed")"
  [ ! -s "$H/worker-limit2.typed" ] || fail "the watchdog typed into a second worker usage-limit picker: $(cat "$H/worker-limit2.typed")"
  assert_equals 2 "$(ledger_rows quota suggest held)" "each worker pick is recorded, not launched: $(ledger | cut -f4-8)"
  calls=$(wc -l < "$H/quota-axi.calls" | tr -d ' ')
  assert_equals 1 "$calls" "one watchdog pass reuses one quota snapshot for both workers"
  assert_grep "usage-limit on worker limit. Suggested pick: codex gpt-5.4" "$H/data/watchdog/status.md" \
    "a worker usage-limit pane must name the pick for that worker"
  assert_grep "usage-limit on worker limit2. Suggested pick: codex gpt-5.4" "$H/data/watchdog/status.md" \
    "a second worker usage-limit pane must name its own pick"
  assert_grep "Queue until reset" "$H/data/watchdog/status.md" \
    "a worker pane-text usage-limit must queue until reset"
  assert_not_contains "$(cat "$H/data/watchdog/status.md")" "Supervisor relaunches" \
    "a worker pane-text usage-limit must not send the supervisor to relaunch"
  HOME="$H/user" run_wd 1 once >/dev/null 2>&1 || fail "rate-limited worker usage-limit pass failed"
  assert_equals 2 "$(ledger_rows quota suggest held)" "nudge-secs must not add another worker pick: $(ledger | cut -f4-8)"
  calls=$(wc -l < "$H/quota-axi.calls" | tr -d ' ')
  assert_equals 1 "$calls" "a rate-limited pass must not call quota-axi again"
  rm -f "$FAKEBIN/quota-axi" "$FAKEBIN/fm-control.sh"
  pass "usage-limit: a worker pane names the pick and does not relaunch"
}

test_grok_weekly_limit_on_a_secondmate_names_a_pick() {
  local parent mate snap grok
  grok=$'                                                                                             █\n\n  ┃\n  ┃  You hit your weekly limit.\n  ┃\n  ┃\n  ┃  1 (○) Buy more credits  Purchase credits to keep using Grok Build\n  ┃  2 (○) Try Again         Resubmit the last prompt once you have usage again\n  ┃\n  ┃  ↑/↓ navigate · y copy                                                  Enter:submit\n  ┃\n\n  Tab:next answer  │  Esc:scrollback  │  Shift+x:dismiss'
  make_home $'Captain session\n> '
  parent=$H
  make_home "$grok"
  mate=$H
  mkdir -p "$parent/user/.claude"
  printf -- '- ghost-mate - test mate (home: %s)\n' "$mate" > "$parent/data/secondmates.md"
  {
    echo "harness=grok"
    echo "kind=secondmate"
    echo "home=$mate"
    echo "worktree=$mate"
    echo "model=default"
  } > "$parent/state/ghost-mate.meta"
  printf 'mode=act\nclaude-config-dirs=%s\nkey-settle-secs=1\nmodels=\nreroute-candidates=codex:gpt-5.4\n' \
    "$parent/claude" > "$parent/config/watchdog"
  snap="$parent/quota.json"
  wd_quota_snapshot "$snap"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
cat "$snap"
SH
  chmod +x "$FAKEBIN/quota-axi"
  cat > "$FAKEBIN/fm-control.sh" <<SH
#!/usr/bin/env bash
printf 'control %s\n' "\$*" >> "$parent/control.log"
exit 1
SH
  chmod +x "$FAKEBIN/fm-control.sh"
  transcript 100 "Working."
  H=$parent
  HOME="$parent/user" run_wd 0 once >/dev/null 2>&1 || fail "Grok weekly-limit pass failed"
  [ ! -e "$parent/control.log" ] || fail "watchdog relaunched: $(cat "$parent/control.log")"
  assert_grep "Suggested pick: codex gpt-5.4" "$parent/data/watchdog/status.md" \
    "a Grok weekly-limit composer must still name the pick"
  assert_grep "Supervisor relaunches" "$parent/data/watchdog/status.md" \
    "a Grok weekly-limit composer still takes a supervisor relaunch"
  rm -f "$FAKEBIN/quota-axi" "$FAKEBIN/fm-control.sh"
  pass "usage-limit: a Grok weekly-limit secondmate names the pick via the composer detector"
}

# Guard, not proof. tmux already uses a true viewport on main, so this case
# still passes there. The Orca scrollback false-positive is the proof case.
test_home_usage_limit_ignores_grok_in_scrollback() {
  local parent mate user snap grok picker mate_t observe history view
  grok=$'                                                                                             █\n\n  ┃\n  ┃  You hit your weekly limit.\n  ┃\n  ┃\n  ┃  1 (○) Buy more credits  Purchase credits to keep using Grok Build\n  ┃  2 (○) Try Again         Resubmit the last prompt once you have usage again\n  ┃\n  ┃  ↑/↓ navigate · y copy                                                  Enter:submit\n  ┃\n\n  Tab:next answer  │  Esc:scrollback  │  Shift+x:dismiss'
  picker=$'You have hit your weekly limit for Opus.\n\n ❯ 1. Switch to Sonnet\n   2. Wait for the limit to reset\n   3. Buy more credits\n\nEnter to confirm · Esc to cancel'
  observe() { bash -c '. "$1/bin/fm-watchdog-lib.sh"; . "$1/bin/fm-composer-lib.sh"; shift; "$@"' _ "$ROOT" "$@"; }
  assert_equals 'Grok weekly-limit choice' "$(observe fm_composer_blocking_dialog "$grok")" \
    "the Grok fixture must match the composer detector, or a scrollback miss would be vacuous"
  assert_equals '' "$(observe fm_composer_blocking_dialog "$picker" || true)" \
    "the viewport picker must not match the Grok composer detector"
  assert_equals usage-limit "$(lib fm_wd_pane_dialog "$picker")" \
    "the viewport picker must still be a pane-text usage-limit"
  make_home $'Captain session\n> '
  parent=$H
  make_home $'Captain session\n> '
  mate=$H
  mate_t=$T
  printf '%s\n' "$grok" > "$mate/grok.txt"
  printf '%s\n' "$picker" > "$mate/picker.txt"
  cat > "$FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
s=
t=
prev=
for a in "\$@"; do
  if [ "\$prev" = -S ]; then s=\$a; fi
  if [ "\$prev" = -t ]; then t=\$a; fi
  prev=\$a
done
if [ "\$t" = "$mate_t" ]; then
  case "\$s" in
    -60) cat "$mate/grok.txt"; exit 0 ;;
    -0) cat "$mate/picker.txt"; exit 0 ;;
  esac
fi
exec "$REAL_TMUX" -f /dev/null -L "$SOCKET" "\$@"
SH
  chmod +x "$FAKEBIN/tmux"
  history=$("$FAKEBIN/tmux" capture-pane -p -t "$mate_t" -S -60)
  view=$("$FAKEBIN/tmux" capture-pane -p -t "$mate_t" -S -0)
  assert_equals 'Grok weekly-limit choice' "$(observe fm_composer_blocking_dialog "$history")" \
    "stubbed scrollback must match the Grok detector"
  assert_equals '' "$(observe fm_composer_blocking_dialog "$view" || true)" \
    "stubbed viewport must not match the Grok detector"
  user="$parent/user"
  mkdir -p "$user/.claude"
  printf -- '- ghost-mate - test mate (home: %s)\n' "$mate" > "$parent/data/secondmates.md"
  {
    echo "harness=claude"
    echo "kind=secondmate"
    echo "home=$mate"
    echo "worktree=$mate"
    echo "model=default"
  } > "$parent/state/ghost-mate.meta"
  printf 'mode=act\nclaude-config-dirs=%s\nkey-settle-secs=1\nmodels=\nreroute-candidates=codex:gpt-5.4\n' \
    "$parent/claude" > "$parent/config/watchdog"
  snap="$parent/quota.json"
  wd_quota_snapshot "$snap"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
cat "$snap"
SH
  chmod +x "$FAKEBIN/quota-axi"
  cat > "$FAKEBIN/fm-control.sh" <<SH
#!/usr/bin/env bash
printf 'control %s\n' "\$*" >> "$parent/control.log"
exit 1
SH
  chmod +x "$FAKEBIN/fm-control.sh"
  H=$mate
  transcript 100 "Working."
  H=$parent
  HOME="$user" run_wd 0 once >/dev/null 2>&1 || { restore_fake_tmux; fail "home usage-limit with Grok in scrollback failed"; }
  restore_fake_tmux
  [ ! -e "$parent/control.log" ] || fail "watchdog relaunched: $(cat "$parent/control.log")"
  assert_grep "Suggested pick: codex gpt-5.4" "$parent/data/watchdog/status.md" \
    "a live pane-text usage-limit must still name the pick"
  assert_grep "Queue until reset" "$parent/data/watchdog/status.md" \
    "a live pane-text usage-limit must queue until reset when only scrollback holds Grok"
  assert_not_contains "$(cat "$parent/data/watchdog/status.md")" "Supervisor relaunches" \
    "a dismissed Grok frame in scrollback must not send the supervisor to relaunch"
  rm -f "$FAKEBIN/quota-axi" "$FAKEBIN/fm-control.sh"
  pass "usage-limit guard: a tmux home pane queues when Grok remains only in scrollback"
}

test_orca_usage_limit_does_not_relaunch_from_scrollback() {
  local parent mate user snap grok grok_json observe
  grok=$'                                                                                             █\n\n  ┃\n  ┃  You hit your weekly limit.\n  ┃\n  ┃\n  ┃  1 (○) Buy more credits  Purchase credits to keep using Grok Build\n  ┃  2 (○) Try Again         Resubmit the last prompt once you have usage again\n  ┃\n  ┃  ↑/↓ navigate · y copy                                                  Enter:submit\n  ┃\n\n  Tab:next answer  │  Esc:scrollback  │  Shift+x:dismiss'
  grok_json=$(printf '%s\n' "$grok" | jq -Rs 'split("\n")')
  observe() { bash -c '. "$1/bin/fm-watchdog-lib.sh"; . "$1/bin/fm-composer-lib.sh"; shift; "$@"' _ "$ROOT" "$@"; }
  assert_equals 'Grok weekly-limit choice' "$(observe fm_composer_blocking_dialog "$grok")" \
    "the Orca scrollback fixture must match the Grok detector, or a miss would be vacuous"
  make_home $'Captain session\n> '
  parent=$H
  make_home $'Captain session\n> '
  mate=$H
  jq -n --arg s "$SID" --argjson e "$BASE" --argjson p "$LOCKPID" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:"orca",target:"term-1",present:true},session:{trusted_id:$s},writer:{anchor_pid:$p,session_id:$s}}}' \
    > "$mate/state/heartbeat.json"
  user="$parent/user"
  mkdir -p "$user/.claude"
  printf -- '- ghost-mate - test mate (home: %s)\n' "$mate" > "$parent/data/secondmates.md"
  {
    echo "harness=claude"
    echo "kind=secondmate"
    echo "home=$mate"
    echo "worktree=$mate"
    echo "model=default"
  } > "$parent/state/ghost-mate.meta"
  printf 'mode=act\nclaude-config-dirs=%s\nkey-settle-secs=1\nmodels=\nreroute-candidates=codex:gpt-5.4\n' \
    "$parent/claude" > "$parent/config/watchdog"
  snap="$parent/quota.json"
  wd_quota_snapshot "$snap"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
cat "$snap"
SH
  chmod +x "$FAKEBIN/quota-axi"
  cat > "$FAKEBIN/fm-control.sh" <<SH
#!/usr/bin/env bash
printf 'control %s\n' "\$*" >> "$parent/control.log"
exit 1
SH
  chmod +x "$FAKEBIN/fm-control.sh"
  cat > "$FAKEBIN/orca" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$parent/orca.log"
case "\$1 \$2" in
  "terminal read")
    case " \$* " in
      *" --screen "*) exit 1 ;;
      *) printf '{"ok":true,"result":{"terminal":{"tail":%s}}}\n' '$grok_json' ;;
    esac ;;
  "terminal wait") printf '{"ok":true,"result":{}}\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$FAKEBIN/orca"
  H=$mate
  transcript 100 "Working."
  H=$parent
  HOME="$user" run_wd 0 once >/dev/null 2>&1 || fail "orca usage-limit with Grok only in scrollback failed"
  [ ! -e "$parent/control.log" ] || fail "watchdog relaunched: $(cat "$parent/control.log")"
  grep -F 'terminal read' "$parent/orca.log" | grep -vq -- '--screen' \
    || fail "the Orca home pane scrollback was not read: $(cat "$parent/orca.log" 2>/dev/null)"
  if grep -q -- '--screen' "$parent/orca.log"; then
    fail "non-Droid Orca must not attempt viewport capture: $(cat "$parent/orca.log")"
  fi
  assert_grep "Queue until reset" "$parent/data/watchdog/status.md" \
    "Grok remaining only in non-Droid Orca scrollback still queues until reset"
  assert_not_contains "$(cat "$parent/data/watchdog/status.md")" "Supervisor relaunches" \
    "Grok remaining only in scrollback must not send the supervisor to relaunch"
  rm -f "$FAKEBIN/quota-axi" "$FAKEBIN/fm-control.sh" "$FAKEBIN/orca"
  pass "usage-limit: Orca does not relaunch from Grok remaining only in scrollback"
}

test_orca_permission_prompt_is_flagged_without_viewport() {
  local parent mate user perm perm_json
  perm=$'Do you want to proceed?\n ❯ 1. Yes\n   2. No, and tell Claude what to do differently\n\nEsc to cancel'
  perm_json=$(printf '%s\n' "$perm" | jq -Rs 'split("\n")')
  assert_equals permission "$(lib fm_wd_pane_dialog "$perm")" \
    "the Orca permission fixture must match the detector, or a miss would be vacuous"
  make_home $'Captain session\n> '
  parent=$H
  make_home $'Captain session\n> '
  mate=$H
  jq -n --arg s "$SID" --argjson e "$BASE" --argjson p "$LOCKPID" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:"orca",target:"term-1",present:true},session:{trusted_id:$s},writer:{anchor_pid:$p,session_id:$s}}}' \
    > "$mate/state/heartbeat.json"
  user="$parent/user"
  mkdir -p "$user/.claude"
  printf -- '- ghost-mate - test mate (home: %s)\n' "$mate" > "$parent/data/secondmates.md"
  {
    echo "harness=claude"
    echo "kind=secondmate"
    echo "home=$mate"
    echo "worktree=$mate"
    echo "model=default"
  } > "$parent/state/ghost-mate.meta"
  printf 'mode=act\nclaude-config-dirs=%s\nkey-settle-secs=1\nmodels=\n' \
    "$parent/claude" > "$parent/config/watchdog"
  cat > "$FAKEBIN/orca" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$parent/orca.log"
case "\$1 \$2" in
  "terminal read")
    case " \$* " in
      *" --screen "*) exit 1 ;;
      *) printf '{"ok":true,"result":{"terminal":{"tail":%s}}}\n' '$perm_json' ;;
    esac ;;
  "terminal wait") printf '{"ok":true,"result":{}}\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$FAKEBIN/orca"
  H=$mate
  transcript 100 "Working."
  H=$parent
  HOME="$user" run_wd 0 once >/dev/null 2>&1 || fail "orca permission with no viewport failed"
  grep -F 'terminal read' "$parent/orca.log" | grep -vq -- '--screen' \
    || fail "the Orca home pane scrollback was not read: $(cat "$parent/orca.log" 2>/dev/null)"
  if grep -q -- '--screen' "$parent/orca.log"; then
    fail "non-Droid Orca must not attempt viewport capture: $(cat "$parent/orca.log")"
  fi
  assert_grep "permission dialog waiting" "$parent/data/watchdog/status.md" \
    "a permission prompt in Orca scrollback must still be flagged"
  rm -f "$FAKEBIN/orca"
  pass "permission: Orca scrollback still flags a prompt when the viewport cannot be read"
}

test_idle_non_droid_orca_is_not_usage_limit() {
  local parent mate user idle idle_json out
  idle=$'Captain session\n> '
  idle_json=$(printf '%s\n' "$idle" | jq -Rs 'split("\n")')
  make_home $'Captain session\n> ' 'reroute-candidates=codex:gpt-5.4'
  parent=$H
  make_home $'Captain session\n> '
  mate=$H
  jq -n --arg s "$SID" --argjson e "$BASE" --argjson p "$LOCKPID" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:"orca",target:"term-1",present:true},session:{trusted_id:$s},writer:{anchor_pid:$p,session_id:$s}}}' \
    > "$mate/state/heartbeat.json"
  user="$parent/user"
  mkdir -p "$user/.claude"
  printf -- '- ghost-mate - test mate (home: %s)\n' "$mate" > "$parent/data/secondmates.md"
  {
    echo "harness=claude"
    echo "kind=secondmate"
    echo "home=$mate"
    echo "worktree=$mate"
    echo "model=default"
  } > "$parent/state/ghost-mate.meta"
  printf 'mode=act\nclaude-config-dirs=%s\nkey-settle-secs=1\nmodels=\nreroute-candidates=codex:gpt-5.4\n' \
    "$parent/claude" > "$parent/config/watchdog"
  cat > "$FAKEBIN/orca" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$parent/orca.log"
case "\$1 \$2" in
  "terminal read")
    case " \$* " in
      *" --screen "*) exit 1 ;;
      *) printf '{"ok":true,"result":{"terminal":{"tail":%s}}}\n' '$idle_json' ;;
    esac ;;
  "terminal wait") printf '{"ok":true,"result":{}}\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$FAKEBIN/orca"
  cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
printf 'quota-axi should not run on an idle non-Droid Orca pane\n' >&2
exit 1
SH
  chmod +x "$FAKEBIN/quota-axi"
  H=$mate
  transcript 100 "Working."
  H=$parent
  out=$(HOME="$user" run_wd 0 scan 2>/dev/null) || fail "idle non-Droid Orca scan failed"
  printf '%s\n' "$out" | grep -F "($mate)" -A5 | grep -q 'dialog=none' \
    || fail "idle non-Droid Orca must read dialog=none, got: $out"
  printf '%s\n' "$out" | grep -q 'dialog=usage-limit' \
    && fail "idle non-Droid Orca must not read as usage-limit: $out"
  if grep -q -- '--screen' "$parent/orca.log" 2>/dev/null; then
    fail "non-Droid Orca must not attempt viewport capture: $(cat "$parent/orca.log")"
  fi
  HOME="$user" run_wd 0 once >/dev/null 2>&1 || fail "idle non-Droid Orca pass failed"
  if [ -f "$parent/data/watchdog/status.md" ]; then
    assert_not_contains "$(cat "$parent/data/watchdog/status.md")" "Queue until reset" \
      "an idle non-Droid Orca pane must not queue as usage-limit"
  fi
  rm -f "$FAKEBIN/orca" "$FAKEBIN/quota-axi"
  pass "idle non-Droid Orca: dialog=none, no viewport capture, no quota pick"
}

test_orca_feedback_and_model_switch_come_from_scrollback() {
  local parent mate user feedback feedback_json model model_json out
  feedback=$'some work\n● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss'
  feedback_json=$(printf '%s\n' "$feedback" | jq -Rs 'split("\n")')
  assert_equals feedback "$(lib fm_wd_pane_dialog "$feedback")" \
    "the Orca feedback fixture must match the detector, or a miss would be vacuous"
  make_home $'Captain session\n> '
  parent=$H
  make_home $'Captain session\n> '
  mate=$H
  jq -n --arg s "$SID" --argjson e "$BASE" --argjson p "$LOCKPID" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:"orca",target:"term-1",present:true},session:{trusted_id:$s},writer:{anchor_pid:$p,session_id:$s}}}' \
    > "$mate/state/heartbeat.json"
  user="$parent/user"
  mkdir -p "$user/.claude"
  printf -- '- ghost-mate - test mate (home: %s)\n' "$mate" > "$parent/data/secondmates.md"
  {
    echo "harness=claude"
    echo "kind=secondmate"
    echo "home=$mate"
    echo "worktree=$mate"
    echo "model=default"
  } > "$parent/state/ghost-mate.meta"
  printf 'mode=act\nclaude-config-dirs=%s\nkey-settle-secs=1\nmodels=\n' \
    "$parent/claude" > "$parent/config/watchdog"
  cat > "$FAKEBIN/orca" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$parent/orca.log"
case "\$1 \$2" in
  "terminal read")
    case " \$* " in
      *" --screen "*) exit 1 ;;
      *) printf '{"ok":true,"result":{"terminal":{"tail":%s}}}\n' '$feedback_json' ;;
    esac ;;
  "terminal wait") printf '{"ok":true,"result":{}}\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$FAKEBIN/orca"
  H=$mate
  transcript 100 "Working."
  H=$parent
  out=$(HOME="$user" run_wd 0 scan 2>/dev/null) || fail "orca feedback scan failed"
  printf '%s\n' "$out" | grep -F "($mate)" -A5 | grep -q 'dialog=feedback' \
    || fail "Orca feedback in scrollback must read dialog=feedback, got: $out"
  printf '%s\n' "$out" | grep -q 'dialog=usage-limit' \
    && fail "Orca feedback must not be reported as usage-limit: $out"
  if grep -q -- '--screen' "$parent/orca.log" 2>/dev/null; then
    fail "non-Droid Orca must not attempt viewport capture: $(cat "$parent/orca.log")"
  fi
  rm -f "$FAKEBIN/orca" "$parent/orca.log"

  model=$'Switch to another model?\n ❯ 1. Wait\n   2. Stop\n\nEnter to confirm · Esc to cancel'
  model_json=$(printf '%s\n' "$model" | jq -Rs 'split("\n")')
  assert_equals model-switch "$(lib fm_wd_pane_dialog "$model")" \
    "the Orca model-switch fixture must match the detector, or a miss would be vacuous"
  cat > "$FAKEBIN/orca" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$parent/orca.log"
case "\$1 \$2" in
  "terminal read")
    case " \$* " in
      *" --screen "*) exit 1 ;;
      *) printf '{"ok":true,"result":{"terminal":{"tail":%s}}}\n' '$model_json' ;;
    esac ;;
  "terminal wait") printf '{"ok":true,"result":{}}\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$FAKEBIN/orca"
  out=$(HOME="$user" run_wd 0 scan 2>/dev/null) || fail "orca model-switch scan failed"
  printf '%s\n' "$out" | grep -F "($mate)" -A5 | grep -q 'dialog=model-switch' \
    || fail "Orca model-switch in scrollback must read dialog=model-switch, got: $out"
  printf '%s\n' "$out" | grep -q 'dialog=usage-limit' \
    && fail "Orca model-switch must not be reported as usage-limit: $out"
  if grep -q -- '--screen' "$parent/orca.log" 2>/dev/null; then
    fail "non-Droid Orca must not attempt viewport capture: $(cat "$parent/orca.log")"
  fi
  rm -f "$FAKEBIN/orca"
  pass "Orca feedback and model-switch dialogs are still read from scrollback"
}

test_orca_feedback_dismiss_records_done() {
  local parent mate user feedback feedback_json idle idle_json
  feedback=$'some work\n● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss'
  feedback_json=$(printf '%s\n' "$feedback" | jq -Rs 'split("\n")')
  idle=$'Captain session\n> '
  idle_json=$(printf '%s\n' "$idle" | jq -Rs 'split("\n")')
  assert_equals feedback "$(lib fm_wd_pane_dialog "$feedback")" \
    "the Orca feedback fixture must match the detector, or a miss would be vacuous"
  make_home $'Captain session\n> '
  parent=$H
  make_home $'Captain session\n> '
  mate=$H
  jq -n --arg s "$SID" --argjson e "$BASE" --argjson p "$LOCKPID" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:"orca",target:"term-1",present:true},session:{trusted_id:$s},writer:{anchor_pid:$p,session_id:$s}}}' \
    > "$mate/state/heartbeat.json"
  user="$parent/user"
  mkdir -p "$user/.claude"
  printf -- '- ghost-mate - test mate (home: %s)\n' "$mate" > "$parent/data/secondmates.md"
  {
    echo "harness=claude"
    echo "kind=secondmate"
    echo "home=$mate"
    echo "worktree=$mate"
    echo "model=default"
  } > "$parent/state/ghost-mate.meta"
  printf 'mode=act\nclaude-config-dirs=%s\nkey-settle-secs=1\nmodels=\n' \
    "$parent/claude" > "$parent/config/watchdog"
  cat > "$FAKEBIN/orca" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$parent/orca.log"
case "\$1 \$2" in
  "terminal send")
    : > "$parent/orca.dismissed"
    printf '{"ok":true}\n'
    ;;
  "terminal read")
    case " \$* " in
      *" --screen "*) exit 1 ;;
      *)
        if [ -e "$parent/orca.dismissed" ]; then
          printf '{"ok":true,"result":{"terminal":{"tail":%s}}}\n' '$idle_json'
        else
          printf '{"ok":true,"result":{"terminal":{"tail":%s}}}\n' '$feedback_json'
        fi
        ;;
    esac ;;
  "terminal wait") printf '{"ok":true,"result":{}}\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$FAKEBIN/orca"
  H=$mate
  transcript 100 "Working."
  H=$parent
  HOME="$user" run_wd 0 once >/dev/null 2>&1 || fail "orca feedback dismiss pass failed"
  assert_equals 1 "$(ledger_rows dialog key "done")" \
    "a dismissed Orca feedback survey must record done, not failed: $(ledger | cut -f5-8)"
  assert_equals 0 "$(ledger_rows dialog key failed)" \
    "a dismissed Orca feedback survey must not record failed: $(ledger | cut -f5-8)"
  [ -e "$parent/orca.dismissed" ] || fail "the watchdog must send the dismiss key"
  rm -f "$FAKEBIN/orca"
  pass "Orca feedback dismiss: a cleared survey records done"
}

test_unknown_viewport_does_not_preempt_a_restart_request() {
  make_home $'Captain session\n> ' "restart=on
restart-command=$TMP_ROOT/fake-captain.sh"
  write_fake_captain
  transcript 3000 "Working." "Testing." "Green."
  run_wd 0 once >/dev/null 2>&1 || fail "cpu-prime pass failed"
  : > "$H/state/.watchdog-restart-request"
  fm_touch_epoch "$((BASE + 5))" "$H/state/.watchdog-restart-request"
  wrap_tmux_visible fail
  run_wd 10 once >/dev/null 2>&1 || { restore_fake_tmux; fail "capture-fail restart pass failed"; }
  restore_fake_tmux
  assert_equals 1 "$(ledger_rows restart-requested restart pending)" \
    "unknown from a failed viewport must not pre-empt a restart request: $(ledger | cut -f5-8)"
  assert_grep "dialog unknown" "$H/data/watchdog/status.md" \
    "a failed viewport read must be a reported gap"
  LOCK_PIDS="$LOCK_PIDS $(cat "$H/state/.lock")"
  pass "unknown viewport: a restart request still restarts, and the failed read is a gap"
}

test_tmux_capture_failure_is_unknown_not_usage_limit() {
  local out snap
  make_home $'Captain session\n> ' 'reroute-candidates=codex:gpt-5.4'
  mkdir -p "$H/wt" "$H/user/.claude"
  worker_pane capfail ship $'Captain session\n> '
  {
    echo "harness=claude"
    echo "kind=ship"
    echo "worktree=$H/wt"
    echo "model=default"
  } >> "$H/state/capfail.meta"
  snap="$H/quota.json"
  wd_quota_snapshot "$snap"
  : > "$H/quota-axi.calls"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
printf 'call\n' >> "$H/quota-axi.calls"
cat "$snap"
SH
  chmod +x "$FAKEBIN/quota-axi"
  wrap_tmux_visible fail
  transcript 100 "Working."
  out=$(HOME="$H/user" run_wd 0 scan 2>/dev/null) || { restore_fake_tmux; fail "tmux capture-fail scan failed"; }
  printf '%s\n' "$out" | grep -q 'dialog=unknown' \
    || { restore_fake_tmux; fail "a failed tmux viewport must read dialog=unknown, got: $out"; }
  printf '%s\n' "$out" | grep -F "worker capfail" | grep -q 'dialog=unknown' \
    || { restore_fake_tmux; fail "a failed tmux worker viewport must read dialog=unknown, got: $out"; }
  printf '%s\n' "$out" | grep -q 'dialog=usage-limit' \
    && { restore_fake_tmux; fail "a failed tmux viewport must not read as usage-limit: $out"; }
  HOME="$H/user" run_wd 0 once >/dev/null 2>&1 || { restore_fake_tmux; fail "tmux capture-fail pass failed"; }
  restore_fake_tmux
  [ ! -s "$H/quota-axi.calls" ] || fail "a failed tmux viewport must not pick quota: $(cat "$H/quota-axi.calls")"
  if [ -f "$H/data/watchdog/status.md" ]; then
    assert_not_contains "$(cat "$H/data/watchdog/status.md")" "Queue until reset" \
      "a failed tmux viewport must not queue as usage-limit"
  fi
  rm -f "$FAKEBIN/quota-axi"
  pass "tmux capture failure: unknown, no quota pick, on home and worker"
}

test_blank_tmux_viewport_is_none_not_usage_limit() {
  local out
  make_home $'Captain session\n> ' 'reroute-candidates=codex:gpt-5.4'
  mkdir -p "$H/user/.claude"
  wrap_tmux_visible blank
  transcript 100 "Working."
  out=$(HOME="$H/user" run_wd 0 scan 2>/dev/null) || { restore_fake_tmux; fail "blank tmux viewport scan failed"; }
  printf '%s\n' "$out" | grep -q 'dialog=none' \
    || { restore_fake_tmux; fail "a blank but successful tmux viewport must read dialog=none, got: $out"; }
  printf '%s\n' "$out" | grep -q 'dialog=usage-limit' \
    && { restore_fake_tmux; fail "a blank tmux viewport must not read as usage-limit: $out"; }
  printf '%s\n' "$out" | grep -q 'dialog=unknown' \
    && { restore_fake_tmux; fail "a successful blank tmux viewport must not read as unknown: $out"; }
  restore_fake_tmux
  pass "blank-but-read tmux viewport: dialog=none"
}

test_quota_axi_failure_is_cached_for_the_pass() {
  local dialog calls
  dialog=$'You have hit your weekly limit for Opus.\n\n ❯ 1. Switch to Sonnet\n   2. Wait for the limit to reset\n   3. Buy more credits\n\nEnter to confirm · Esc to cancel'
  make_home $'Captain session\n> ' 'reroute-candidates=codex:gpt-5.4'
  mkdir -p "$H/wt" "$H/wt2" "$H/user/.claude"
  worker_pane limit ship "$dialog"
  {
    echo "harness=claude"
    echo "kind=ship"
    echo "worktree=$H/wt"
    echo "model=default"
  } >> "$H/state/limit.meta"
  worker_pane limit2 ship "$dialog"
  {
    echo "harness=claude"
    echo "kind=ship"
    echo "worktree=$H/wt2"
    echo "model=default"
  } >> "$H/state/limit2.meta"
  : > "$H/quota-axi.calls"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
printf 'call\n' >> "$H/quota-axi.calls"
exit 1
SH
  chmod +x "$FAKEBIN/quota-axi"
  cat > "$FAKEBIN/fm-control.sh" <<SH
#!/usr/bin/env bash
printf 'control %s\n' "\$*" >> "$H/control.log"
exit 1
SH
  chmod +x "$FAKEBIN/fm-control.sh"
  transcript 100 "Working."
  sleep 0.5
  HOME="$H/user" run_wd 0 once >/dev/null 2>&1 || fail "quota-axi failure pass failed"
  [ ! -e "$H/control.log" ] || fail "watchdog relaunched: $(cat "$H/control.log")"
  calls=$(wc -l < "$H/quota-axi.calls" | tr -d ' ')
  assert_equals 1 "$calls" "one watchdog pass must call quota-axi once when it fails"
  assert_equals 2 "$(ledger_rows quota suggest held)" "each worker still records the failed pick: $(ledger | cut -f4-8)"
  assert_grep "Queue until reset" "$H/data/watchdog/status.md" \
    "a failed quota snapshot must queue until reset"
  assert_not_contains "$(cat "$H/data/watchdog/status.md")" "Suggested pick:" \
    "a failed quota snapshot must not name a pick"
  rm -f "$FAKEBIN/quota-axi" "$FAKEBIN/fm-control.sh"
  pass "usage-limit: a quota-axi failure is cached for the pass"
}

test_primary_usage_limit_autowait_pages_once() {
  make_home $'work output\nUsage limit reached. Continuing automatically at 4:00 AM\n❯ \n  ? for shortcuts'
  transcript 100 "Working."
  printf '%s\n' "$LOCKPID" > "$H/state/.supervise-daemon.pid"
  printf "command:cat >> '%s'\n" "$H/paged.log" > "$H/config/wedge-alarm"
  run_wd 0 once >/dev/null 2>&1 || fail "primary auto-wait pass failed"
  assert_grep 'usage_limit_autowait=1' "$H/state/watchdog/captain" \
    "the captain record must name the auto-wait: $(cat "$H/state/watchdog/captain" 2>/dev/null)"
  assert_equals 1 "$(ledger_rows usage-limit-autowait page pending)" "the auto-wait page is recorded once: $(ledger | cut -f4-8)"
  assert_equals 1 "$(ledger_rows usage-limit-autowait page "done")" "the auto-wait page was delivered: $(ledger | cut -f4-8)"
  assert_grep 'usage-limit auto-wait' "$H/paged.log" "the page names the auto-wait"
  assert_grep 'bin/fm-quota-reroute.sh suggest' "$H/paged.log" "the page names the reroute command"
  assert_grep 'bin/fm-quota-reroute.sh suggest' "$H/data/watchdog/status.md" "the status gap names the reroute command"
  assert_grep 'does not kill or relaunch the primary' "$H/data/watchdog/status.md" "the status gap keeps the primary in place"
  [ ! -s "$H/typed.log" ] || fail "the watchdog typed into an auto-wait pane: $(cat "$H/typed.log")"
  assert_equals 0 "$(ledger | awk -F'\t' '$6 == "restart"' | wc -l | tr -d ' ')" "the watchdog relaunched the primary: $(ledger | cut -f4-8)"
  wd_pid_alive_check "$LOCKPID" || fail "the primary lock holder was killed"
  run_wd 300 once >/dev/null 2>&1 || fail "rate-limited auto-wait pass failed"
  assert_equals 1 "$(ledger_rows usage-limit-autowait page pending)" "a second page waits for nudge-secs: $(ledger | cut -f4-8)"
  assert_equals 1 "$(grep -c 'usage-limit auto-wait' "$H/paged.log")" "the owner was paged only once inside the window"
  pass "usage-limit auto-wait: a primary is recorded, paged once, and never typed into, killed, or relaunched"
}

wd_pid_alive_check() { kill -0 "$1" 2>/dev/null; }

test_primary_autowait_side_checks_type_nothing_and_file_no_issue() {
  make_home $'work output\nUsage limit reached. Continuing automatically at 4:00 AM\n❯ \n  ? for shortcuts' 'issue-repo=example.invalid/owner/repo'
  transcript 100 "Working."
  : > "$H/state/.afk"
  printf '999999\n' > "$H/state/.supervise-daemon.pid"
  printf 'needs-decision [at=%s] [key=cache-layout]: A or B?\n' "$((BASE - 9000))" > "$H/state/t1.status"
  printf 'paused [at=%s]: hit the quota floor\n' "$((BASE - 9000))" > "$H/state/q1.status"
  printf "command:cat >> '%s'\n" "$H/paged.log" > "$H/config/wedge-alarm"
  local off
  for off in 0 1000 2000 3000 4000 8000 12000; do
    run_wd "$off" once >/dev/null 2>&1 || fail "auto-wait pass at +${off}s failed"
  done
  assert_equals 7 "$(ledger_rows usage-limit-autowait page pending)" "each window pages the owner: $(ledger | cut -f4-8)"
  assert_equals 0 "$(ledger | awk -F'\t' '$6 == "nudge"' | wc -l | tr -d ' ')" "a side check nudged an auto-wait primary: $(ledger | cut -f4-8)"
  assert_equals 0 "$(ledger | awk -F'\t' '$6 == "council"' | wc -l | tr -d ' ')" "a council ran for an auto-wait primary: $(ledger | cut -f4-8)"
  assert_equals 0 "$(ledger | awk -F'\t' '$6 == "self-heal"' | wc -l | tr -d ' ')" "a long auto-wait filed a self-heal issue: $(ledger | cut -f4-8)"
  [ ! -s "$H/typed.log" ] || fail "the watchdog typed into an auto-wait pane: $(cat "$H/typed.log")"
  pass "usage-limit auto-wait: a dead away daemon, an aged decision, and a quota floor type nothing, and hours of pages file no issue"
}

test_primary_quoted_autowait_is_not_paged() {
  make_home $'Reading docs/watchdog.md\nIt pages on `Continuing automatically at <reset>` in the footer.\n❯ \n  ? for shortcuts'
  transcript 100 "Working."
  printf '%s\n' "$LOCKPID" > "$H/state/.supervise-daemon.pid"
  printf "command:cat >> '%s'\n" "$H/paged.log" > "$H/config/wedge-alarm"
  run_wd 0 once >/dev/null 2>&1 || fail "quoted auto-wait primary pass failed"
  assert_grep 'usage_limit_autowait=0' "$H/state/watchdog/captain" \
    "a quoted auto-wait phrase must not be detected: $(cat "$H/state/watchdog/captain" 2>/dev/null)"
  assert_equals 0 "$(ledger | awk -F'\t' '$6 == "page"' | wc -l | tr -d ' ')" "a quoted auto-wait phrase paged: $(ledger | cut -f4-8)"
  [ ! -e "$H/paged.log" ] || fail "a quoted auto-wait phrase paged the owner: $(cat "$H/paged.log")"
  pass "usage-limit auto-wait: a phrase quoted in conversation above the composer is not paged"
}

test_primary_ordinary_idle_is_not_paged() {
  make_home $'Captain session\n❯ \n  ? for shortcuts'
  transcript 100 "Working."
  printf '%s\n' "$LOCKPID" > "$H/state/.supervise-daemon.pid"
  printf "command:cat >> '%s'\n" "$H/paged.log" > "$H/config/wedge-alarm"
  run_wd 0 once >/dev/null 2>&1 || fail "ordinary idle primary pass failed"
  run_wd 300 once >/dev/null 2>&1 || fail "second ordinary idle primary pass failed"
  assert_grep 'usage_limit_autowait=0' "$H/state/watchdog/captain" \
    "the captain record must clear the auto-wait: $(cat "$H/state/watchdog/captain" 2>/dev/null)"
  assert_equals 0 "$(ledger | awk -F'\t' '$6 == "page"' | wc -l | tr -d ' ')" "an ordinary idle primary was paged: $(ledger | cut -f4-8)"
  [ ! -e "$H/paged.log" ] || fail "an ordinary idle primary paged the owner: $(cat "$H/paged.log")"
  assert_not_contains "$(cat "$H/data/watchdog/status.md")" "usage-limit auto-wait" \
    "an ordinary idle primary was reported on an auto-wait"
  pass "usage-limit auto-wait: an ordinary idle primary is not paged"
}

if [ "$#" -gt 0 ]; then
  fm_test_run "$@"
  exit
fi

fm_test_run \
  test_dialog_detection \
  test_mtime_uses_the_platform_stat_dialect \
  test_dismissed_dialog_in_scrollback_is_not_showing \
  test_dialog_keys_stop_after_two_failures \
  test_loop_verdicts \
  test_stall_proof_and_text_guards \
  test_frozen_pane_nudges_once_then_rate_limits \
  test_do_not_touch_never_typed \
  test_draft_rows_are_the_draft_alone \
  test_merge_autosuggestion_never_accepted \
  test_unreadable_draft_never_gets_enter \
  test_quoted_row_never_hides_a_taller_draft \
  test_terminal_service_loss_is_agent_gone \
  test_owner_reserved_holds_stay_held_and_council_settles_the_rest \
  test_split_council_gives_no_ruling \
  test_judge_fallback_and_spend_cap \
  test_no_model_still_acts_and_reports_gap \
  test_timer_loop_needs_owed_input \
  test_near_loop_never_masks_frozen_or_input_recovery \
  test_near_loop_judge_sees_the_sequence_and_is_rate_limited \
  test_near_loop_confirmed_uses_the_ladder \
  test_near_loop_evidence_is_withheld_from_every_model \
  test_old_rapid_burst_leaves_an_idle_session_alone \
  test_fresh_rapid_loop_recovers_without_owed_input \
  test_primary_ignores_another_sessions_endpoint \
  test_primary_without_lock_identity_never_trusts_heartbeat_endpoint \
  test_restart_vetoed_by_running_turn \
  test_restart_verified_pickup_and_loop_stop \
  test_captain_record_follows_the_lock_owner \
  test_captain_record_ignores_a_heartbeat_written_outside_the_owner \
  test_no_action_while_restart_awaits_pickup \
  test_dead_captain_restarts_despite_its_anchor \
  test_watchdog_allows_muse_restart_with_approval_flag \
  test_watchdog_adds_yolo_to_bare_muse_restart \
  test_watchdog_leaves_non_muse_restart_unchanged \
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
  test_away_permission_dialog_pages_the_owner \
  test_worker_permission_dialog_pages_the_owner \
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
  test_secret_looking_decision_reaches_no_council \
  test_secret_looking_model_switch_dialog_is_held \
  test_model_switch_judge_is_rate_limited \
  test_usage_limit_unknown_harness_queues \
  test_claude_pinned_secondmate_with_tooling_gets_no_codex_pick \
  test_ordinary_home_claude_json_mcp_blocks_the_move \
  test_codex_task_keeps_same_harness_candidates_under_a_claude_pin \
  test_usage_limit_claude_without_tooling_names_a_pick \
  test_unreadable_claude_account_pin_gets_no_pick \
  test_worker_usage_limit_names_a_pick \
  test_grok_weekly_limit_on_a_secondmate_names_a_pick \
  test_home_usage_limit_ignores_grok_in_scrollback \
  test_orca_usage_limit_does_not_relaunch_from_scrollback \
  test_orca_permission_prompt_is_flagged_without_viewport \
  test_idle_non_droid_orca_is_not_usage_limit \
  test_orca_feedback_and_model_switch_come_from_scrollback \
  test_orca_feedback_dismiss_records_done \
  test_unknown_viewport_does_not_preempt_a_restart_request \
  test_tmux_capture_failure_is_unknown_not_usage_limit \
  test_blank_tmux_viewport_is_none_not_usage_limit \
  test_quota_axi_failure_is_cached_for_the_pass \
  test_primary_usage_limit_autowait_pages_once \
  test_primary_autowait_side_checks_type_nothing_and_file_no_issue \
  test_primary_quoted_autowait_is_not_paged \
  test_primary_ordinary_idle_is_not_paged \
  test_unknown_composer_guards_the_nudge \
  test_orca_turn_probe_keeps_errors_unknown \
  test_no_activity_source_is_not_reported_ok \
  test_claude_judge_keeps_the_default_login \
  test_unknown_heartbeat_endpoint_is_not_reported_ok \
  test_tmux_restart_survives_a_closed_session \
  test_status_file_short_and_staleness_visible \
  test_manager_units \
  test_never_merges_deploys_or_messages_owner
