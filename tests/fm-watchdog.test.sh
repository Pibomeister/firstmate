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

# wrap_tmux_literal_send_fails: a literal text send fails as tmux reports a
# command it cannot send, while every other tmux call reaches the real server.
wrap_tmux_literal_send_fails() {
  cat > "$FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
if [ "\$1" = send-keys ]; then
  for a in "\$@"; do
    [ "\$a" != -l ] || { echo "command too long" >&2; exit 1; }
  done
fi
exec "$REAL_TMUX" -f /dev/null -L "$SOCKET" "\$@"
SH
  chmod +x "$FAKEBIN/tmux"
}

# echoing_composer_pane: replace the captain pane with a Claude-shaped composer
# whose terminal echoes typed text into the composer row, so the real composer
# classifier reads typed-but-unsubmitted text as pending. The window is widened
# first so a doorbell naming a long temporary path stays on the composer row
# instead of wrapping over the rule below it.
echoing_composer_pane() {
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" resize-window -t "$T" -x 600 -y 40
  cat > "$H/echo-agent.sh" <<'SH'
#!/usr/bin/env bash
printf 'Captain session\n────────────────────────────────────────\n❯ \n────────────────────────────────────────\n  ? for shortcuts\033[2A\033[3G'
exec cat > /dev/null
SH
  chmod +x "$H/echo-agent.sh"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" respawn-pane -k -t "$T" "$H/echo-agent.sh"
  local drawn=0
  until [ "$(composer_line)" = '❯' ]; do
    drawn=$((drawn + 1))
    [ "$drawn" -le 300 ] || fail "echoing_composer_pane: the composer never drew"
    sleep 0.1
  done
}

# composer_line [row]: one captain pane row (default the composer row 3),
# trailing blanks trimmed.
composer_line() {
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" capture-pane -p -t "$T" 2>/dev/null | sed -n "${1:-3}p" | sed 's/[[:space:]]*$//'
}

# wrap_tmux_enter_swallowed: a bare Enter is accepted but never reaches the
# pane, so typed text stays in the composer, while every other tmux call
# reaches the real server.
wrap_tmux_enter_swallowed() {
  cat > "$FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
if [ "\$1" = send-keys ] && [ "\${*: -1}" = Enter ]; then
  exit 0
fi
exec "$REAL_TMUX" -f /dev/null -L "$SOCKET" "\$@"
SH
  chmod +x "$FAKEBIN/tmux"
}

# Every long-lived fixture process ends its argv with this marked duration, so
# this suite can find all of its own fixtures, including ones whose pid no case
# recorded, while another suite's fixtures carry a different marker.
WD_FIXTURE_SLEEP="100000.$$"
export WD_FIXTURE_SLEEP

# reap_marked_fixtures: TERM every process whose last argument is this suite's
# marker, compared as a string so 100000.12 never matches 100000.120. The
# marker reaches awk through the environment, so the probe itself never
# matches.
reap_marked_fixtures() {
  local pids
  pids=$(ps -axo pid=,args= 2>/dev/null | awk '"" $NF == "" ENVIRON["WD_FIXTURE_SLEEP"] { print $1 }')
  # shellcheck disable=SC2086 # One pid per word.
  [ -z "$pids" ] || kill $pids 2>/dev/null || true
}

LOCK_PIDS=''
cleanup_watchdog_tests() {
  local p
  for p in $LOCK_PIDS; do kill "$p" 2>/dev/null || true; done
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  reap_marked_fixtures
  fm_test_cleanup
}
trap cleanup_watchdog_tests EXIT

# A suite killed too hard to run its traps (SIGKILL, or a kill aimed at the
# suite process alone) would strand every fixture, reparented to init and
# still holding whatever it inherited. A detached guardian outlives the suite,
# holds none of its output, and sweeps the same fixtures once the suite's pid
# (checked with its start time) is gone. Job control puts it in its own
# process group, so a kill aimed at the suite's group, such as the test queue
# ending a dead run's stragglers, cannot end it before it sweeps.
start_fixture_guardian() {
  local suite=$$ start
  start=$(ps -p "$suite" -o lstart= 2>/dev/null)
  (
    set -m
    (
      exec </dev/null >/dev/null 2>&1
      trap '' HUP INT
      # A zombie suite is gone: its parent may wait only after reading output
      # a fixture still holds.
      while kill -0 "$suite" 2>/dev/null && { [ -z "$start" ] || [ "$(ps -p "$suite" -o lstart= 2>/dev/null)" = "$start" ]; }; do
        case $(ps -p "$suite" -o stat= 2>/dev/null) in
          *Z*) break ;;
        esac
        sleep 2
      done
      "$REAL_TMUX" -L "$SOCKET" kill-server || true
      reap_marked_fixtures
    ) &
  ) 2>/dev/null
}
start_fixture_guardian

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
: > "$H/agent.ready"
exec cat >> "$H/typed.log"
SH
  chmod +x "$H/agent.sh"
  : > "$H/typed.log"
  sess="wd$CASE_N"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" new-session -d -s "$sess" -x 160 -y 40 "$H/agent.sh"
  T=$("$REAL_TMUX" -f /dev/null -L "$SOCKET" list-panes -t "$sess" -F '#{pane_id}' | head -n 1)
  # Detached, so the lock holder is reparented and reaped like a real session.
  ( sleep "$WD_FIXTURE_SLEEP" > /dev/null 2>&1 & printf '%s\n' "$!" > "$H/lockpid" )
  LOCKPID=$(cat "$H/lockpid")
  LOCK_PIDS="$LOCK_PIDS $LOCKPID"
  printf '%s\n' "$LOCKPID" > "$H/state/.lock"
  printf '%s\n' "$SID" > "$H/state/.lock-session"
  fm_touch_epoch "$((BASE - 1))" "$H/state/.lock" "$H/state/.lock-session"
  # Written by the lock owner itself, as when the owner's own watcher runs it.
  jq -n --arg t "$T" --arg s "$SID" --argjson e "$BASE" --argjson p "$LOCKPID" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:"tmux",target:$t,present:true},session:{trusted_id:$s},writer:{anchor_pid:$p,session_id:$s}}}' \
    > "$H/state/heartbeat.json"
  printf 'mode=act\nclaude-config-dirs=%s\nkey-settle-secs=1\nmodels=\nquota-guard=off\nmemory-guard=off\nheartbeat-frozen-secs=0\n%s\n' "$H/claude" "$extra" > "$H/config/watchdog"
  # A loaded host can start the agent late; a blank pane would read as an
  # unknown composer and silently change what a pass decides.
  # A deliberately blank screen only waits for the agent to start.
  local drawn=0 blank=0
  [ -n "$(printf '%s' "$screen" | tr -d '[:space:]')" ] || blank=1
  while [ ! -e "$H/agent.ready" ] \
    || { [ "$blank" = 0 ] && [ -z "$("$REAL_TMUX" -f /dev/null -L "$SOCKET" capture-pane -p -t "$T" 2>/dev/null | tr -d '[:space:]')" ]; }; do
    drawn=$((drawn + 1))
    [ "$drawn" -le 300 ] || fail "make_home: the captain pane never drew its screen"
    sleep 0.1
  done
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
council_record_path() {  # <rulings|no-rulings> <task> <key>
  local f
  for f in "$H/data/watchdog/$1/"*.md; do
    [ -f "$f" ] || continue
    grep -Fxq -- "- task: $2" "$f" || continue
    grep -Fxq -- "- key: $3" "$f" || continue
    printf '%s\n' "$f"
    return 0
  done
  return 1
}

council_fixture_record() {  # Seed and remove one record to obtain its opaque fixture path.
  local out record
  out=$(run_wd -10 council --task "$1" --key "$2" --record-file "$H/record.txt" 2>&1) || fail "cannot seed council fixture: $out"
  case "$out" in council=ruled*) ;; *) fail "cannot seed council fixture: $out" ;; esac
  record=${out#*record=}; record=${record%% prior=*}
  rm -f "$record"
  : > "$H/model.log"
  printf '%s\n' "$record"
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
  pass "dialogs need their structure, and each kind is told apart"
}

test_mtime_uses_the_platform_stat_dialect() {
  local out gnu='' statbin real_uname
  make_home $'Captain session\n> '
  transcript 3000 "Working." "Testing." "Green."
  out=$(run_wd 0 scan 2>&1) || fail "native stat scan failed: $out"
  assert_contains "$out" 'activity_age=3000s (transcript)' "native stat returns the transcript's age"
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
    assert_contains "$out" 'activity_age=3000s (transcript)' "GNU stat returns a numeric transcript age"
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
  ls "$H/data/watchdog/rulings/"*.md >/dev/null 2>&1 || fail "no ruling file for a unanimous council"
  assert_grep "unanimous" "$(council_record_path rulings t1 cache-layout)" "ruling records unanimity"
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

test_worker_dialog_key_does_not_close_home_key_window() {
  local stuck=$'Switch to another model?\n\n ❯ 1. Wait\n   2. Buy more credits\n\nEnter to confirm · Esc to cancel'
  local home_canon
  make_home "$stuck" 'models=claude:haiku'
  fake_models "$H" ok:"OPTION 1" absent
  transcript 100 "Working."
  home_canon=$(cd -P "$H" && pwd -P)
  mkdir -p "$H/state/watchdog"
  printf '%s\tw1\t%s\tworker:other\tdialog\tkey\tpending\tpress 0: dismiss the feedback survey\n' \
    "$((BASE - 10))" "$home_canon" > "$H/state/watchdog/actions.tsv"
  run_wd 0 once >/dev/null 2>&1 || fail "pass 0 failed"
  assert_equals 1 "$(ledger | awk -F'\t' '$4 != "worker:other" && $5 == "dialog" && $6 == "key" && $7 == "pending"' | wc -l | tr -d ' ')" \
    "a worker's recent dialog key does not hold back the home pane's model-switch key: $(ledger | cut -f4-8)"
  pass "dialog key rate window is per pane: a worker's key does not block the home pane's key"
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

test_worker_human_step_key_is_held_for_the_owner() {
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  transcript 100 "Working."
  # Brief rule 11's record of a human-only step, worded with none of the
  # reserved or secret-looking words, beside an ordinary decision.
  {
    printf 'blocked [at=%s] [key=human-step-device]: human-only step: approve the browser prompt on the phone\n' "$((BASE - 9000))"
    printf 'needs-decision [at=%s] [key=cache-layout]: A (recommended) flat keys or B nested keys?\n' "$((BASE - 9000))"
  } > "$H/state/t1.status"
  run_wd 0 once >/dev/null 2>&1 || fail "first pass failed"
  assert_grep "1 decisions held for the owner" "$H/data/watchdog/status.md" "the human-only step is a held gap"
  assert_equals 1 "$(ledger_rows decisions nudge pending)" "the ordinary decision still gets its nudge"
  if grep -rqsF 'human-step-device' "$H/state/operational-inbox"; then
    fail "the nudge asks the supervisor to answer a human-only step: $(cat "$H"/state/operational-inbox/* 2>&1)"
  fi
  run_wd 2000 once >/dev/null 2>&1 || fail "second pass failed"
  assert_equals 1 "$(ledger_rows decision:cache-layout council "done")" "the ordinary decision still reaches council"
  assert_equals 0 "$(ledger | grep -c 'decision:human-step-device')" "the human-only step reaches no council"
  assert_no_grep "browser prompt on the phone" "$H/prompt.log" "no seat saw the human-only step"
  assert_equals 2 "$(grep -cE '^(claude|agy) -p' "$H/model.log")" "each seat was called once, for the ordinary decision"
  pass "decisions: a worker's human-step key is the owner's, never nudged or put to council; an ordinary decision still settles"
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

# How many council or judge seats were really called in this home.
seat_calls() {
  local c
  c=$(grep -cE '^(claude|agy) -p' "$H/model.log" 2>/dev/null)
  printf '%s\n' "${c:-0}"
}

test_seat_family_derivation() {
  assert_equals anthropic "$(lib fm_wd_seat_family claude:haiku)" "a claude alias is Anthropic"
  assert_equals anthropic "$(lib fm_wd_seat_family claude:claude-fable-5-2)" "a full claude id is Anthropic"
  assert_equals anthropic "$(lib fm_wd_seat_family agy:claude-opus-5-5)" "the model name wins over the harness"
  assert_equals google "$(lib fm_wd_seat_family agy:gemini-4-carbon-high)" "a gemini id is Google"
  assert_equals google "$(lib fm_wd_seat_family agy:flash)" "a gemini alias is Google"
  assert_equals google "$(lib fm_wd_seat_family agy:some-new-name)" "an unnamed model falls back to its harness"
  assert_equals openai "$(lib fm_wd_seat_family agy:gpt-9)" "a gpt id is OpenAI"
  assert_equals unknown "$(lib fm_wd_seat_family other:model)" "an unknown harness and model has no family"
  assert_equals unknown "$(lib fm_wd_seat_family '')" "an empty seat has no family"
  pass "council seats: the model family comes from the model name, then the harness, else unknown"
}

test_decisions_act_while_everything_else_stays_dry_run() {
  make_home $'Captain session\n> ' 'mode=dry-run
decisions=act
models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  transcript 100 "Working."
  owe_input 4000
  printf 'needs-decision [at=%s] [key=cache-layout]: A (recommended) flat keys or B nested keys?\n' "$((BASE - 9000))" > "$H/state/t1.status"
  run_wd 0 once >/dev/null 2>&1 || fail "first pass failed"
  assert_equals 1 "$(ledger_rows decisions nudge pending)" "the decision nudge is delivered: $(ledger | cut -f5-8)"
  wait_typed ": fm-op " || wait_typed "operational-inbox" || fail "the decision nudge never reached the pane: $(cat "$H/typed.log")"
  assert_equals 0 "$(ledger_rows unread-input nudge pending)" "another symptom's nudge stays a dry run"
  assert_equals 1 "$(ledger_rows unread-input nudge dry-run)" "the other symptom is recorded as a dry run: $(ledger | cut -f5-8)"
  run_wd 2000 once >/dev/null 2>&1 || fail "second pass failed"
  assert_equals 1 "$(ledger_rows decision:cache-layout council "done")" "the council convened for real: $(ledger | cut -f5-8)"
  assert_equals 0 "$(ledger_rows decision:cache-layout council dry-run)" "no dry-run council row"
  assert_present "$(council_record_path rulings t1 cache-layout)" "the ruling file exists"
  assert_equals 1 "$(ledger_rows ruling:cache-layout nudge pending)" "the ruling nudge is delivered"
  assert_equals 0 "$(ledger | awk -F'\t' '($6 == "key" || $6 == "enter" || $6 == "restart") && $7 == "pending"' | wc -l | tr -d ' ')" "no key, Enter, or restart acted"
  pass "decisions=act: the decision nudge, council, and ruling nudge act while the rest of the ladder stays dry-run"
}

test_decisions_key_follows_mode_and_can_hold_it_back() {
  make_home $'Captain session\n> ' 'mode=dry-run
models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  transcript 100 "Working."
  printf 'needs-decision [at=%s] [key=cache-layout]: A (recommended) flat keys or B nested keys?\n' "$((BASE - 9000))" > "$H/state/t1.status"
  run_wd 0 once >/dev/null 2>&1
  run_wd 2000 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows decision:cache-layout council dry-run)" "with no decisions key, mode=dry-run keeps the council a dry run"
  assert_equals 0 "$(seat_calls)" "a dry run calls no seat"
  make_home $'Captain session\n> ' 'decisions=dry-run
models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  transcript 100 "Working."
  printf 'needs-decision [at=%s] [key=cache-layout]: A (recommended) flat keys or B nested keys?\n' "$((BASE - 9000))" > "$H/state/t1.status"
  run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows decisions nudge dry-run)" "decisions=dry-run holds the decision nudge back under mode=act"
  run_wd 2000 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows decision:cache-layout council dry-run)" "decisions=dry-run holds the council back under mode=act"
  [ ! -e "$H/data/watchdog/rulings" ] || fail "a dry run wrote a ruling"
  pass "decisions: an unset key follows mode; decisions=dry-run holds the decision path back on its own"
}

test_one_family_council_is_refused_without_a_call() {
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,claude:sonnet'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  transcript 100 "Working."
  printf 'needs-decision [at=%s] [key=cache-layout]: A (recommended) flat keys or B nested keys?\n' "$((BASE - 9000))" > "$H/state/t1.status"
  run_wd 0 once >/dev/null 2>&1
  run_wd 2000 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows decision:cache-layout council refused)" "a one-family council is refused: $(ledger | cut -f5-8)"
  assert_equals 0 "$(seat_calls)" "a refused council calls no seat"
  assert_grep "two model families" "$H/data/watchdog/status.md" "the refusal is a visible gap"
  [ ! -e "$H/data/watchdog/rulings" ] && [ ! -e "$H/data/watchdog/no-rulings" ] || fail "a refused council wrote a record"
  pass "boundary: two seats of one model family give no ruling, call no model, and show as a gap"
}

test_council_outcome_is_final_for_its_decision() {
  local rec
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED B"
  transcript 100 "Working."
  printf 'needs-decision [at=%s] [key=cache-layout]: A flat keys or B nested keys?\n' "$((BASE - 9000))" > "$H/state/t1.status"
  run_wd 0 once >/dev/null 2>&1
  run_wd 2000 once >/dev/null 2>&1
  rec="$(council_record_path no-rulings t1 cache-layout)"
  assert_present "$rec" "a split council leaves a durable record"
  assert_grep "seat1=PROCEED A" "$rec" "the record names the first seat's answer"
  assert_grep "seat2=PROCEED B" "$rec" "the record names the dissenting seat's answer"
  assert_equals 2 "$(seat_calls)" "each seat was called once"
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  run_wd 30000 once >/dev/null 2>&1
  run_wd 60000 once >/dev/null 2>&1
  assert_equals 2 "$(seat_calls)" "a decided key is never put to council again"
  [ ! -e "$H/data/watchdog/rulings" ] || fail "a later pass turned a split into a ruling"
  assert_grep "held for the owner after a council gave no ruling" "$H/data/watchdog/status.md" "the hold stays visible on later passes"
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  transcript 100 "Working."
  printf 'needs-decision [at=%s] [key=cache-layout]: A (recommended) flat keys or B nested keys?\n' "$((BASE - 9000))" > "$H/state/t1.status"
  run_wd 0 once >/dev/null 2>&1
  run_wd 2000 once >/dev/null 2>&1
  assert_present "$(council_record_path rulings t1 cache-layout)" "the unanimous council ruled"
  run_wd 30000 once >/dev/null 2>&1
  run_wd 32000 once >/dev/null 2>&1
  assert_equals 2 "$(seat_calls)" "a ruled key is never put to council again"
  assert_grep "unapplied council ruling" "$H/data/watchdog/status.md" "a ruling on a still-open decision stays visible"
  pass "council: one convening per decision; a split is recorded with its dissent and held, a ruling is never re-rolled"
}

test_council_with_no_answer_is_not_a_convening() {
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" fail fail
  transcript 100 "Working."
  printf 'needs-decision [at=%s] [key=cache-layout]: A (recommended) flat keys or B nested keys?\n' "$((BASE - 9000))" > "$H/state/t1.status"
  run_wd 0 once >/dev/null 2>&1
  run_wd 2000 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows decision:cache-layout council failed)" "an unanswered council is recorded as failed: $(ledger | cut -f5-8)"
  [ ! -e "$H/data/watchdog/no-rulings" ] || fail "a council no seat answered left a final record"
  fake_models "$H" ok:"PROCEED A" fail
  # The first late pass repeats the rolled-up nudge; the council runs a window after it.
  run_wd 30000 once >/dev/null 2>&1
  run_wd 32000 once >/dev/null 2>&1
  assert_present "$(council_record_path no-rulings t1 cache-layout)" "one answer and one failed seat is a final no-ruling"
  assert_grep "seat2=FAILED" "$(council_record_path no-rulings t1 cache-layout)" "the record names the failed seat"
  [ ! -e "$H/data/watchdog/rulings" ] || fail "one seat ruled alone"
  pass "council: no answer at all is retried later; a partial answer is final and holds"
}

test_council_calls_use_their_own_budget_and_time_limit() {
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash
council-call-max-usd=0.50
council-timeout-secs=300'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  transcript 100 "Working."
  printf 'cache layout: A (recommended) flat keys or B nested keys?\n' > "$H/record.txt"
  run_wd 0 council --task t1 --key s1-cache --record-file "$H/record.txt" >/dev/null 2>&1 || fail "council command failed"
  assert_grep "max-budget-usd 0.50" "$H/model.log" "the council seat got the council budget"
  assert_grep "print-timeout 300s" "$H/model.log" "the council seat got the council time limit"
  : > "$H/model.log"
  printf 'is this a loop?' | run_wd 10 judge loop '(LOOP|WORK)' >/dev/null 2>&1
  assert_grep "max-budget-usd 0.05" "$H/model.log" "a judge call keeps the judge budget"
  pass "council: council-call-max-usd and council-timeout-secs apply to council seats only"
}

test_council_command_rules_now_once_and_types_nothing() {
  local out sentinel=FAKESENTINEL43
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  transcript 100 "Working."
  printf 'Third review round on the cache theme. A (recommended) ship plus filed follow-up, or B one more fix round?\n' > "$H/record.txt"
  out=$(run_wd 0 council --task t1 --key s1-cache --record-file "$H/record.txt" 2>/dev/null) || fail "council command failed"
  assert_contains "$out" "council=ruled" "a unanimous council rules: $out"
  assert_contains "$out" "answer=PROCEED A" "the answer is printed: $out"
  assert_contains "$out" "record=$H/data/watchdog/rulings/" "the record path is printed: $out"
  assert_equals 2 "$(seat_calls)" "each seat was called once"
  assert_equals 1 "$(ledger_rows decision:s1-cache council "done")" "the convening is in the ledger"
  fake_models "$H" ok:"PROCEED B" ok:"PROCEED B"
  out=$(run_wd 100 council --task t1 --key s1-cache --record-file "$H/record.txt" 2>/dev/null) || fail "repeat council command failed"
  assert_contains "$out" "council=ruled" "a repeat call returns the recorded outcome: $out"
  assert_contains "$out" "answer=PROCEED A" "a repeat call cannot change the answer: $out"
  assert_contains "$out" "prior=1" "a repeat call is marked as a replay: $out"
  assert_equals 2 "$(seat_calls)" "a repeat call reaches no seat"
  # An open decision's own record is the default record.
  printf 'needs-decision [at=%s] [key=index-shape]: A (recommended) one index or B two?\n' "$((BASE - 60))" > "$H/state/t2.status"
  fake_models "$H" ok:"PROCEED A" ok:"HOLD"
  out=$(run_wd 200 council --task t2 --key index-shape 2>/dev/null) || fail "council on an open decision failed"
  assert_contains "$out" "council=no-ruling" "a split council prints no ruling: $out"
  assert_contains "$out" "answer=none" "a split council prints no answer: $out"
  assert_grep "one index or B two" "$(council_record_path no-rulings t2 index-shape)" "the open decision's record was the question"
  run_wd 300 council --task t2 --key not-open >/dev/null 2>&1 && fail "a key with no record and no open decision was accepted"
  # Owner-reserved and secret-looking records never reach a seat.
  : > "$H/model.log"
  : > "$H/prompt.log"
  printf 'merge PR #5 now, A yes or B wait?\n' > "$H/reserved.txt"
  out=$(run_wd 400 council --task t1 --key s1-ship --record-file "$H/reserved.txt" 2>/dev/null) || fail "held council command failed"
  assert_contains "$out" "council=held" "an owner-reserved record is held: $out"
  out=$(run_wd 410 council --task t1 --key captain-hold-x --record-file "$H/record.txt" 2>/dev/null) || fail "held council command failed"
  assert_contains "$out" "council=held" "an owner hold key is held: $out"
  printf 'push failed for https://x-access-token:%s@example.invalid/o/r; A or B?\n' "$sentinel" > "$H/secret.txt"
  out=$(run_wd 420 council --task t1 --key s1-push --record-file "$H/secret.txt" 2>/dev/null) || fail "held council command failed"
  assert_contains "$out" "council=held" "a secret-looking record is held: $out"
  assert_equals 0 "$(seat_calls)" "a held record reaches no seat"
  if grep -rFq "$sentinel" "$H/state/watchdog" "$H/data/watchdog" "$H/model.log" "$H/prompt.log" 2>/dev/null; then fail "the withheld text reached a record or a model"; fi
  assert_equals "" "$(cat "$H/typed.log")" "the council command types nothing into the pane"
  run_wd 500 council --key s1-cache --record-file "$H/record.txt" >/dev/null 2>&1; assert_equals 2 "$?" "a missing task is a usage error"
  run_wd 500 council --task t1 --key 'bad/key' --record-file "$H/record.txt" >/dev/null 2>&1; assert_equals 2 "$?" "a key with a path separator is a usage error"
  pass "council command: rules at once through the same seats and holds, replays a recorded outcome, and types nothing"
}

test_council_keeps_dashed_decision_identities_separate() {
  local out first second
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  printf 'A (recommended) flat keys or B nested keys?\n' > "$H/record.txt"
  out=$(run_wd 0 council --task a-b --key c --record-file "$H/record.txt" 2>&1) || fail "first council failed: $out"
  assert_contains "$out" "answer=PROCEED A" "the first decision rules A"
  first=${out#*record=}; first=${first%% prior=*}
  fake_models "$H" ok:"PROCEED B" ok:"PROCEED B"
  out=$(run_wd 10 council --task a --key b-c --record-file "$H/record.txt" 2>/dev/null) || fail "second council failed"
  assert_contains "$out" "answer=PROCEED B" "a distinct dashed identity must convene its own council: $out"
  assert_contains "$out" "prior=0" "the second decision is not a replay"
  second=${out#*record=}; second=${second%% prior=*}
  [ "$first" != "$second" ] || fail "different decisions share a record path"
  assert_equals 4 "$(seat_calls)" "both decisions convened independently"
  out=$(run_wd 20 council --task a-b --key c --record-file "$H/record.txt" 2>/dev/null) || fail "first replay failed"
  assert_contains "$out" "answer=PROCEED A" "the first decision retains its own answer"
  assert_contains "$out" "prior=1" "the first decision replays"
  assert_equals 4 "$(seat_calls)" "a replay calls no seat"
  pass "council: dashed task and key fields identify distinct decisions"
}

test_council_checks_stored_identity_and_replays_legacy_records() {
  local out legacy record
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED B" ok:"PROCEED B"
  printf 'A flat keys or B (recommended) nested keys?\n' > "$H/record.txt"
  legacy="$H/data/watchdog/rulings/$(home_key)-a-b-c.md"
  mkdir -p "$(dirname "$legacy")"
  printf -- '- home: %s\n- task: a-b\n- key: c\n- ruling: PROCEED A (unanimous, 2 blind seats)\n- seats: seat1=PROCEED A seat2=PROCEED A\n' "$H" > "$legacy"
  out=$(run_wd 0 council --task a-b --key c --record-file "$H/record.txt" 2>/dev/null) || fail "legacy replay failed"
  assert_contains "$out" "answer=PROCEED A" "a matching legacy record retains its ruling"
  assert_contains "$out" "prior=1" "a matching legacy record replays"
  assert_equals 0 "$(seat_calls)" "legacy replay calls no seat"
  out=$(run_wd 10 council --task a --key b-c --record-file "$H/record.txt" 2>/dev/null) || fail "distinct council failed"
  assert_contains "$out" "answer=PROCEED B" "a legacy record for another identity cannot replay: $out"
  record=${out#*record=}; record=${record%% prior=*}
  cp "$legacy" "$record"
  out=$(run_wd 20 council --task a --key b-c --record-file "$H/record.txt" 2>/dev/null) || fail "identity check failed"
  assert_contains "$out" "answer=PROCEED B" "a new filename also needs a matching stored identity: $out"
  assert_contains "$out" "prior=0" "a mismatched record is not replayed"
  assert_equals 4 "$(seat_calls)" "both mismatched records required a fresh council"
  pass "council: stored identity is checked for new and legacy filenames"
}

test_council_requires_durable_publication() {
  local fault out record real_mv
  real_mv=$(command -v mv)
  for fault in write publish directory; do
    make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
    fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
    printf 'A (recommended) flat keys or B nested keys?\n' > "$H/record.txt"
    record=$(council_fixture_record t1 s1-cache) || fail "cannot prepare persistence fixture"
    mkdir -p "$(dirname "$record")"
    if [ "$fault" = write ]; then
      mkdir "$record.tmp"
    elif [ "$fault" = directory ]; then
      mkdir "$record"
    else
      cat > "$FAKEBIN/mv" <<SH
#!/usr/bin/env bash
case "\$1" in *.md.tmp) exit 1 ;; esac
exec "$real_mv" "\$@"
SH
      chmod +x "$FAKEBIN/mv"
    fi
    out=$(run_wd 0 council --task t1 --key s1-cache --record-file "$H/record.txt" 2>/dev/null) || fail "council command failed"
    rm -f "$FAKEBIN/mv"
    assert_contains "$out" "council=failed" "$fault failure must not report a ruling: $out"
    assert_contains "$out" "answer=none record=none" "an unpublished result cannot be applied"
    [ ! -f "$record" ] || fail "a failed publication left a final record"
    assert_equals 1 "$(ledger_rows decision:s1-cache council failed)" "persistence failure is recorded as failed"
    assert_equals 0 "$(find "$H/state/watchdog/council-locks" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "persistence failure releases its lock"
    rm -rf "$record.tmp"
    [ "$fault" != directory ] || rmdir "$record"
    out=$(run_wd 10 council --task t1 --key s1-cache --record-file "$H/record.txt" 2>/dev/null) || fail "retry failed"
    assert_contains "$out" "council=ruled" "a retry can publish after storage recovers"
    assert_present "$record" "the recovered council has a durable record"
    assert_equals 4 "$(seat_calls)" "the unpublished decision is convened again"
  done
  pass "council: write, rename, and directory-target failures cannot return a successful ruling"
}

test_council_checks_the_complete_record_before_calling_seats() {
  local out
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  { printf 'A flat keys or B nested keys? '; printf '%2100s' x; printf ' Deploy to production data after owner approval.\n'; } > "$H/record.txt"
  out=$(run_wd 0 council --task t1 --key long-record --record-file "$H/record.txt" 2>&1) || fail "long reserved record failed: $out"
  assert_contains "$out" "council=held answer=none" "a reserved condition after 2000 characters must hold: $out"
  assert_equals 0 "$(seat_calls)" "no seat sees a reserved record's safe-looking prefix"
  { printf 'needs-decision [at=%s] [key=long-status]: A flat keys or B nested keys? ' "$BASE"; printf '%600s' x; printf ' Deploy to production data after owner approval.\n'; } > "$H/state/t1.status"
  out=$(run_wd 10 council --task t1 --key long-status 2>&1) || fail "long status decision failed: $out"
  assert_contains "$out" "council=held answer=none" "a reserved condition after 500 characters in a status record must hold: $out"
  assert_equals 0 "$(seat_calls)" "no status decision is judged from a truncated prefix"
  printf 'A flat keys or B nested keys? %2100s' x > "$H/record.txt"
  out=$(run_wd 20 council --task t1 --key oversized --record-file "$H/record.txt" 2>&1) || fail "oversized record failed: $out"
  assert_contains "$out" "council=refused answer=none" "an oversized ordinary record is refused, not silently shortened: $out"
  assert_equals 0 "$(seat_calls)" "oversized records call no seat"
  assert_grep 'record exceeds 2000 characters' "$H/state/watchdog/actions.tsv" "the refusal explains the context limit"
  pass "council: complete file and status records are checked; oversized context is refused"
}

test_council_never_shortens_a_prompt_to_the_judge_limit() {
  local out
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash
judge-max-chars=64'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  printf 'A (recommended) flat keys or B nested keys?\n' > "$H/record.txt"
  out=$(run_wd 0 council --task t1 --key prompt-limit --record-file "$H/record.txt" 2>&1) || fail "bounded prompt failed: $out"
  assert_contains "$out" "council=failed answer=none record=none" "an undersized judge limit cannot turn a partial question into a ruling: $out"
  assert_equals 0 "$(seat_calls)" "no seat is asked a truncated council prompt"
  pass "council: a configured judge limit never removes part of a decision prompt"
}

test_council_dry_run_withholds_an_existing_ruling() {
  local out
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  printf 'A (recommended) flat keys or B nested keys?\n' > "$H/record.txt"
  out=$(run_wd 0 council --task t1 --key replay-mode --record-file "$H/record.txt" 2>&1) || fail "active council failed: $out"
  assert_contains "$out" "council=ruled answer=PROCEED A" "active mode creates a ruling"
  printf '\ndecisions=dry-run\n' >> "$H/config/watchdog"
  out=$(run_wd 10 council --task t1 --key replay-mode --record-file "$H/record.txt" 2>&1) || fail "dry-run replay failed: $out"
  assert_contains "$out" "council=dry-run answer=none record=none" "dry-run never exposes an actionable replay: $out"
  assert_equals 2 "$(seat_calls)" "dry-run replay calls no extra seats"
  assert_present "$(council_record_path rulings t1 replay-mode)" "dry-run preserves the existing record"
  pass "council: dry-run withholds actionable prior rulings without deleting them"
}

test_council_does_not_expire_a_live_owner() {
  local out lock
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  printf 'A (recommended) flat keys or B nested keys?\n' > "$H/record.txt"
  lock=$(council_fixture_record t1 live-owner) || fail "cannot prepare lock fixture"
  lock="$H/state/watchdog/council-locks/$(basename "${lock%.md}")"
  mkdir -p "$lock"
  printf '%s\n' "$LOCKPID" > "$lock/pid"
  fm_touch_epoch "$((BASE - 10000))" "$lock"
  out=$(run_wd 0 council --task t1 --key live-owner --record-file "$H/record.txt" 2>&1) || fail "aged live-owner council failed: $out"
  assert_contains "$out" "council=busy" "a live owner's age does not authorize stealing its council: $out"
  assert_equals 0 "$(seat_calls)" "a live council owner excludes all contenders"
  assert_equals "$LOCKPID" "$(cat "$lock/pid")" "the live owner's lock survives"
  pass "council: a live owner is never replaced solely because its lock is old"
}

test_council_stale_reclaim_excludes_a_second_contender() {
  local lock real_cat first second i tool previous_lock_pids first_rc=0 second_rc=0
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  printf 'A (recommended) flat keys or B nested keys?\n' > "$H/record.txt"
  lock=$(council_fixture_record t1 stale-race) || fail "cannot prepare lock fixture"
  lock="$H/state/watchdog/council-locks/$(basename "${lock%.md}")"
  mkdir -p "$lock"
  printf '999999\n' > "$lock/pid"
  : > "$H/started.log"
  real_cat=$(command -v cat)
  cat > "$FAKEBIN/cat" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "$lock/pid" ] && [ -n "\${RACER:-}" ]; then
  value=\$("$real_cat" "\$@")
  if [ "\$value" = 999999 ] && [ ! -e "$H/seen.\$RACER" ]; then
    touch "$H/seen.\$RACER"
    for i in \$(seq 1 400); do [ ! -e "$H/go.\$RACER" ] || break; sleep 0.05; done
    [ -e "$H/go.\$RACER" ] || exit 1
  fi
  printf '%s\n' "\$value"
else
  exec "$real_cat" "\$@"
fi
SH
  chmod +x "$FAKEBIN/cat"
  for tool in claude agy; do
    mv "$FAKEBIN/$tool" "$FAKEBIN/$tool.seat"
    cat > "$FAKEBIN/$tool" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$RACER" >> "$H/started.log"
for i in \$(seq 1 400); do [ ! -e "$H/release-seats" ] || break; sleep 0.05; done
[ -e "$H/release-seats" ] || exit 1
exec "$FAKEBIN/$tool.seat" "\$@"
SH
    chmod +x "$FAKEBIN/$tool"
  done
  RACER=one run_wd 0 council --task t1 --key stale-race --record-file "$H/record.txt" > "$H/first.out" 2> "$H/first.err" &
  first=$!
  RACER=two run_wd 0 council --task t1 --key stale-race --record-file "$H/record.txt" > "$H/second.out" 2> "$H/second.err" &
  second=$!
  previous_lock_pids=$LOCK_PIDS
  LOCK_PIDS="$LOCK_PIDS $first $second"
  for i in $(seq 1 400); do [ ! -e "$H/seen.one" ] || [ ! -e "$H/seen.two" ] || break; sleep 0.05; done
  touch "$H/go.one"
  for i in $(seq 1 400); do [ "$(wc -l < "$H/started.log" 2>/dev/null || printf 0)" -lt 2 ] || break; sleep 0.05; done
  touch "$H/go.two"
  for i in $(seq 1 400); do
    grep -q 'council=busy' "$H/second.out" && break
    [ "$(wc -l < "$H/started.log" 2>/dev/null || printf 0)" -lt 4 ] || break
    sleep 0.05
  done
  touch "$H/release-seats"
  wait "$first" || first_rc=$?
  wait "$second" || second_rc=$?
  LOCK_PIDS=$previous_lock_pids
  rm -f "$FAKEBIN/cat"
  for tool in claude agy; do mv "$FAKEBIN/$tool.seat" "$FAKEBIN/$tool"; done
  assert_present "$H/seen.one" "the first contender observed the stale owner"
  assert_present "$H/seen.two" "the second contender also observed that same stale owner"
  assert_equals 0 "$first_rc" "the first council command completes: $(cat "$H/first.err")"
  assert_equals 0 "$second_rc" "the second council command completes: $(cat "$H/second.err")"
  assert_grep 'council=ruled' "$H/first.out" "the first stale-lock claimant convenes"
  assert_grep 'council=busy' "$H/second.out" "the second stale reader must not remove the replacement owner's lock"
  assert_equals 2 "$(seat_calls)" "only one council's two seats were called"
  pass "council: simultaneous stale readers cannot replace the winning live owner"
}

test_concurrent_councils_keep_their_prompts_separate() {
  local one two previous_lock_pids rc_one=0 rc_two=0
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  printf 'A (recommended) flat keys or B nested keys?\n' > "$H/record.txt"
  mv "$FAKEBIN/claude" "$FAKEBIN/claude.seat"
  cat > "$FAKEBIN/claude" <<SH
#!/usr/bin/env bash
touch "$H/entered.\$RACER"
for i in \$(seq 1 400); do [ ! -e "$H/entered.one" ] || [ ! -e "$H/entered.two" ] || break; sleep 0.05; done
[ -e "$H/entered.one" ] && [ -e "$H/entered.two" ] || exit 1
cat > "$H/read.\$RACER"
exec "$FAKEBIN/claude.seat" "\$@" < "$H/read.\$RACER"
SH
  chmod +x "$FAKEBIN/claude"
  RACER=one run_wd 0 council --task alpha --key layout --record-file "$H/record.txt" > "$H/one.out" 2> "$H/one.err" &
  one=$!
  RACER=two run_wd 0 council --task beta --key layout --record-file "$H/record.txt" > "$H/two.out" 2> "$H/two.err" &
  two=$!
  previous_lock_pids=$LOCK_PIDS
  LOCK_PIDS="$LOCK_PIDS $one $two"
  wait "$one" || rc_one=$?
  wait "$two" || rc_two=$?
  LOCK_PIDS=$previous_lock_pids
  mv "$FAKEBIN/claude.seat" "$FAKEBIN/claude"
  assert_equals 0 "$rc_one" "alpha command completes: $(cat "$H/one.err")"
  assert_equals 0 "$rc_two" "beta command completes: $(cat "$H/two.err")"
  assert_present "$H/entered.one" "alpha's seat was live during the overlap"
  assert_present "$H/entered.two" "beta's seat was live during the overlap"
  assert_grep 'task: alpha' "$H/read.one" "alpha's seat must read alpha's complete prompt"
  assert_grep 'task: beta' "$H/read.two" "beta's seat must read beta's complete prompt"
  assert_equals 4 "$(seat_calls)" "each council called its own two seats"
  assert_equals 0 "$(find "$H/state/watchdog/judge-scratch" -type f | wc -l | tr -d ' ')" "completed model calls clean up their prompt files"
  pass "council: concurrent decisions never share or retain a seat input file"
}

test_council_never_reads_stale_input_after_a_prompt_write_failure() {
  local out scratch
  if [ "$(id -u)" = 0 ]; then pass "prompt write failure # SKIP root can write permission-denied fixtures"; return; fi
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  printf 'A (recommended) flat keys or B nested keys?\n' > "$H/record.txt"
  scratch="$H/state/watchdog/judge-scratch"
  mkdir -p "$scratch"
  printf 'task: stale-other-decision\nrecord: A or B?\n' > "$scratch/prompt.txt"
  chmod 400 "$scratch/prompt.txt"
  chmod 500 "$scratch"
  out=$(run_wd 0 council --task t1 --key prompt-write --record-file "$H/record.txt" 2>&1)
  chmod 700 "$scratch"
  chmod 600 "$scratch/prompt.txt"
  assert_contains "$out" "council=no-ruling answer=none" "a failed input write cannot use stale input to rule: $out"
  assert_equals 1 "$(seat_calls)" "only the seat that needs no input file was called"
  assert_not_contains "$(cat "$H/prompt.log")" 'stale-other-decision' "no seat read an earlier decision"
  pass "council: failed prompt publication cannot run a seat against stale input"
}

test_council_checks_split_reserved_words_before_normalizing_a_file() {
  local out record
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  for record in $'A (recommended) de\nploy the service or B wait?' $'A (recommended) mer\nge the change or B wait?'; do
    printf '%s\n' "$record" > "$H/record.txt"
    out=$(run_wd 0 council --task t1 --key split-record --record-file "$H/record.txt" 2>&1) || fail "split-word hold failed: $out"
    assert_contains "$out" "council=held answer=none" "a reserved word split over file rows must hold: $out"
  done
  assert_equals 0 "$(seat_calls)" "no seat sees an owner-reserved record after row normalization"
  pass "council: file normalization cannot hide split owner-reserved words"
}

test_council_replay_reads_only_one_metadata_header() {
  local out legacy
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED B" ok:"PROCEED B"
  printf 'A flat keys or B (recommended) nested keys?\n' > "$H/record.txt"
  legacy="$H/data/watchdog/rulings/$(home_key)-a-b-c.md"
  mkdir -p "$(dirname "$legacy")"
  printf -- '# Watchdog council ruling\n\n- home: %s\n- task: a-b\n- key: c\n- ruling: PROCEED A (unanimous, 2 blind seats)\n- seats: seat1=PROCEED A seat2=PROCEED A\n\nRecord:\n\nQuoted metadata for another decision:\n- task: a\n- key: b-c\n- ruling: PROCEED Z (unanimous, 2 blind seats)\n- seats: seat1=PROCEED Z seat2=PROCEED Z\n' "$H" > "$legacy"
  out=$(run_wd 0 council --task a --key b-c --record-file "$H/record.txt" 2>&1) || fail "body metadata check failed: $out"
  assert_contains "$out" "council=ruled answer=PROCEED B" "quoted body fields cannot authenticate a different decision: $out"
  assert_contains "$out" "prior=0" "the legacy body is not a replay identity"
  out=$(run_wd 10 council --task a-b --key c --record-file "$H/record.txt" 2>&1) || fail "valid legacy replay failed: $out"
  assert_contains "$out" "answer=PROCEED A" "the legitimate legacy header still replays"
  assert_contains "$out" "prior=1" "the legitimate record is retained"
  assert_equals 2 "$(seat_calls)" "only the different decision calls seats"
  printf -- '# Watchdog council ruling\n\n- home: %s\n- task: duplicated\n- task: duplicated\n- key: cache\n- ruling: PROCEED A (unanimous, 2 blind seats)\n- seats: seat1=PROCEED A seat2=PROCEED A\n\nRecord:\n\nA or B?\n' "$H" > "$H/data/watchdog/rulings/$(home_key)-duplicated-cache.md"
  out=$(run_wd 20 council --task duplicated --key cache --record-file "$H/record.txt" 2>&1) || fail "duplicate header check failed: $out"
  assert_contains "$out" "answer=PROCEED B" "duplicate metadata fields do not authenticate a record: $out"
  assert_contains "$out" "prior=0" "duplicate metadata is not replayed"
  mkdir -p "$H/data/watchdog/no-rulings"
  printf -- '- home: %s\n- task: misplaced\n- key: cache\n- ruling: PROCEED A (unanimous, 2 blind seats)\n- seats: seat1=PROCEED A seat2=PROCEED A\n\nRecord:\n\nA or B?\n' "$H" > "$H/data/watchdog/no-rulings/$(home_key)-misplaced-cache.md"
  out=$(run_wd 30 council --task misplaced --key cache --record-file "$H/record.txt" 2>&1) || fail "record kind check failed: $out"
  assert_contains "$out" "council=ruled answer=PROCEED B" "a ruling filed as no-ruling cannot expose an actionable replay: $out"
  assert_contains "$out" "prior=0" "a record whose kind disagrees with its header is not replayed"
  pass "council: one complete metadata header owns replay identity and answers"
}

test_council_replay_validates_the_recorded_vote_outcome() {
  local out folder ruling seats task seat i=0
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED B" ok:"PROCEED B"
  printf 'A flat keys or B (recommended) nested keys?\n' > "$H/record.txt"
  mkdir -p "$H/data/watchdog/rulings" "$H/data/watchdog/no-rulings"
  while IFS=$'\t' read -r folder ruling seats; do
    i=$((i + 1))
    task="invalid$i"
    printf -- '- home: %s\n- task: %s\n- key: cache\n- ruling: %s\n- seats: %s\n\nRecord:\n\nA or B?\n' "$H" "$task" "$ruling" "$seats" > "$H/data/watchdog/$folder/$(home_key)-$task-cache.md"
    out=$(run_wd 0 council --task "$task" --key cache --record-file "$H/record.txt" 2>&1) || fail "invalid vote check failed: $out"
    assert_contains "$out" "council=ruled answer=PROCEED B" "contradictory or malformed votes must not authenticate a replay: $ruling; $seats; $out"
    assert_contains "$out" "prior=0" "an invalid outcome is not replayed"
  done <<'EOF'
rulings	PROCEED A (not unanimous, 2 blind seats)	seat1=PROCEED A seat2=HOLD
no-rulings	PROCEED A	seat1=PROCEED A seat2=HOLD
rulings	PROCEED A (unanimous, 2 blind seats)	seat1=PROCEED A seat2=HOLD
rulings	PROCEED A (unanimous, 3 blind seats)	seat1=PROCEED A seat2=PROCEED A
no-rulings	none (not unanimous, 2 blind seats; held for the owner)	seat1=PROCEED A seat2=PROCEED A
no-rulings	none (not unanimous, 2 blind seats; held for the owner)	seat1=FAILED seat2=FAILED
EOF
  {
    printf -- '- home: %s\n- task: many-seats\n- key: cache\n- ruling: PROCEED A (unanimous, 10 blind seats)\n- seats:' "$H"
    for seat in $(seq 1 10); do printf ' seat%s=PROCEED A' "$seat"; done
    printf '\n\nRecord:\n\nA or B?\n'
  } > "$H/data/watchdog/rulings/$(home_key)-many-seats-cache.md"
  out=$(run_wd 10 council --task many-seats --key cache --record-file "$H/record.txt" 2>&1) || fail "valid vote count failed: $out"
  assert_contains "$out" "answer=PROCEED A" "a valid ten-seat record keeps its answer: $out"
  assert_contains "$out" "prior=1" "a valid multi-digit seat count remains replayable"
  pass "council: replay requires a supported outcome consistent with its seat votes"
}

test_council_rejects_additional_metadata_blocks() {
  local out record
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  printf 'A flat keys or B nested keys?\n' > "$H/record.txt"
  out=$(run_wd 0 council --task block --key cache --record-file "$H/record.txt" 2>&1) || fail "initial record failed: $out"
  record=${out#*record=}; record=${record%% prior=*}
  printf -- '- home: %s\n- task: block\n- key: cache\n- ruling: PROCEED A (unanimous, 2 blind seats)\n- seats: seat1=PROCEED A seat2=PROCEED A\n\n- ruling: PROCEED B (unanimous, 2 blind seats)\n- seats: seat1=HOLD seat2=HOLD\n\nRecord:\n\nA or B?\n' "$H" > "$record"
  fake_models "$H" ok:"PROCEED B" ok:"PROCEED B"
  out=$(run_wd 10 council --task block --key cache --record-file "$H/record.txt" 2>&1) || fail "metadata block check failed: $out"
  assert_contains "$out" "answer=PROCEED B" "a blank line cannot hide contradictory metadata before Record: $out"
  assert_contains "$out" "prior=0" "additional metadata is not authenticated"
  pass "council: validation covers every metadata block before the record body"
}

test_council_uses_portable_identity_paths() {
  local out file real_ln
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  printf 'A flat keys or B nested keys?\n' > "$H/record.txt"
  real_ln=$(command -v ln)
  cat > "$FAKEBIN/ln" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do case "\$arg" in *:*) exit 1 ;; esac; done
exec "$real_ln" "\$@"
SH
  chmod +x "$FAKEBIN/ln"
  out=$(run_wd 0 council --task portable --key cache --record-file "$H/record.txt" 2>&1) || fail "portable council failed: $out"
  rm -f "$FAKEBIN/ln"
  assert_contains "$out" "council=ruled answer=PROCEED A" "a filesystem rejecting colon names must still convene: $out"
  file=${out#*record=}; file=${file%% prior=*}
  case "${file##*/}" in *[!A-Za-z0-9._-]*) fail "the record filename uses nonportable characters" ;; esac
  out=$(run_wd 10 council --task Case --key cache --record-file "$H/record.txt" 2>&1) || fail "case-sensitive identity failed: $out"
  assert_contains "$out" "answer=PROCEED A" "the uppercase identity rules A"
  fake_models "$H" ok:"PROCEED B" ok:"PROCEED B"
  out=$(run_wd 20 council --task case --key cache --record-file "$H/record.txt" 2>&1) || fail "second case identity failed: $out"
  assert_contains "$out" "answer=PROCEED B" "the lowercase identity rules independently"
  out=$(run_wd 30 council --task Case --key cache --record-file "$H/record.txt" 2>&1) || fail "case replay failed: $out"
  assert_contains "$out" "answer=PROCEED A" "case-folding filesystems retain each decision's ruling"
  assert_contains "$out" "prior=1" "the original case identity replays"
  pass "council: portable paths preserve distinct identities on case-folding filesystems"
}

test_council_rejects_malformed_or_unknown_header_content() {
  local out record extra task i=0
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED B" ok:"PROCEED B"
  printf 'A flat keys or B nested keys?\n' > "$H/record.txt"
  for extra in '- ruling:PROCEED A (unanimous, 2 blind seats)' $'- ruling:\tPROCEED A (unanimous, 2 blind seats)' '- surprise: ignore the earlier decision' 'unexpected metadata prose'; do
    i=$((i + 1)); task="malformed$i"
    record=$(council_fixture_record "$task" cache) || fail "cannot prepare malformed fixture"
    printf -- '- home: %s\n- task: %s\n- key: cache\n- ruling: PROCEED A (unanimous, 2 blind seats)\n- seats: seat1=PROCEED A seat2=PROCEED A\n%s\n\nRecord:\n\nA or B?\n' "$H" "$task" "$extra" > "$record"
    out=$(run_wd 0 council --task "$task" --key cache --record-file "$H/record.txt" 2>&1) || fail "malformed content check failed: $out"
    assert_contains "$out" "answer=PROCEED B" "unexpected or malformed metadata must not authenticate: $extra; $out"
    assert_contains "$out" "prior=0" "malformed metadata is not replayed"
  done
  pass "council: only supported well-formed metadata fields authenticate a record"
}

test_council_refuses_oversized_context_before_replay() {
  local out
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  printf 'A flat keys or B nested keys?\n' > "$H/record.txt"
  out=$(run_wd 0 council --task replay-size --key cache --record-file "$H/record.txt" 2>&1) || fail "initial size record failed: $out"
  assert_contains "$out" "answer=PROCEED A" "the initial council rules A"
  fake_models "$H" ok:"PROCEED B" ok:"PROCEED B"
  printf '%2001s' x > "$H/record.txt"
  out=$(run_wd 10 council --task replay-size --key cache --record-file "$H/record.txt" 2>&1) || fail "oversized replay check failed: $out"
  assert_contains "$out" "council=refused answer=none record=none" "oversized context cannot return an actionable replay: $out"
  printf '%2000s' x > "$H/record.txt"
  out=$(run_wd 20 council --task replay-size --key cache --record-file "$H/record.txt" 2>&1) || fail "boundary replay failed: $out"
  assert_contains "$out" "answer=PROCEED A" "the supported boundary preserves the recorded answer"
  assert_contains "$out" "prior=1" "the valid record survives an oversized call"
  assert_equals 2 "$(seat_calls)" "size refusal and replay call no new seats"
  pass "council: size validation precedes replay and preserves valid recorded outcomes"
}

test_council_requires_the_seats_field_separator() {
  local out record
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED B" ok:"PROCEED B"
  printf 'A flat keys or B nested keys?\n' > "$H/record.txt"
  record=$(council_fixture_record seats-format cache) || fail "cannot prepare seats fixture"
  printf -- '- home: %s\n- task: seats-format\n- key: cache\n- ruling: PROCEED A (unanimous, 2 blind seats)\n- seats:seat1=PROCEED A seat2=PROCEED A\n\nRecord:\n\nA or B?\n' "$H" > "$record"
  out=$(run_wd 0 council --task seats-format --key cache --record-file "$H/record.txt" 2>&1) || fail "seats grammar check failed: $out"
  assert_contains "$out" "answer=PROCEED B" "a malformed seats field does not authenticate: $out"
  assert_contains "$out" "prior=0" "missing metadata separator is not replayed"
  pass "council: seats use the same required field separator as other metadata"
}

test_automatic_decisions_refuse_oversized_recorded_context() {
  local out
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  SID=00000000-0000-4000-8000-000000000099
  printf '%s\n' "$SID" > "$H/state/.lock-session"
  jq --arg sid "$SID" '.primary.session.trusted_id=$sid | .primary.writer.session_id=$sid' "$H/state/heartbeat.json" > "$H/state/heartbeat.new"
  mv "$H/state/heartbeat.new" "$H/state/heartbeat.json"
  fm_touch_epoch "$((BASE - 1))" "$H/state/.lock-session"
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  transcript 100 "Working."
  printf 'A flat keys or B nested keys?\n' > "$H/record.txt"
  out=$(run_wd 0 council --task t1 --key cache --record-file "$H/record.txt" 2>&1) || fail "initial automatic record failed: $out"
  assert_contains "$out" "answer=PROCEED A" "the decision already has a ruling"
  { printf 'needs-decision [at=%s] [key=cache]: A' "$((BASE - 9000))"; printf '%2000s\n' x; } > "$H/state/t1.status"
  run_wd 0 once >/dev/null 2>&1 || fail "oversized automatic pass failed"
  assert_grep 'record exceeds 2000 characters' "$H/data/watchdog/status.md" "automatic processing refuses oversized recorded context"
  assert_not_contains "$(cat "$H/data/watchdog/status.md")" 'unapplied council ruling' "an oversized context is excluded from ruling handling"
  assert_equals 1 "$(ledger_rows decision:cache council refused)" "the oversized decision is recorded as refused"
  run_wd 10 once >/dev/null 2>&1 || fail "repeated oversized pass failed"
  assert_equals 1 "$(ledger_rows decision:cache council refused)" "a stable refusal is rate-limited"
  { printf 'needs-decision [at=%s] [key=cache]: A' "$((BASE - 9000))"; printf '%1999s\n' x; } > "$H/state/t1.status"
  run_wd 20 once >/dev/null 2>&1 || fail "valid boundary automatic pass failed"
  assert_grep 'unapplied council ruling' "$H/data/watchdog/status.md" "the valid boundary still recognizes its stored ruling"
  assert_equals 2 "$(seat_calls)" "refusal and valid automatic replay call no new seats"
  pass "automatic decisions: context size is checked before either recorded-outcome lookup"
}

test_council_command_honours_the_dry_run_switch() {
  local out
  make_home $'Captain session\n> ' 'mode=dry-run
models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  printf 'A (recommended) ship plus filed follow-up, or B one more fix round?\n' > "$H/record.txt"
  out=$(run_wd 0 council --task t1 --key s1-cache --record-file "$H/record.txt" 2>/dev/null) || fail "dry-run council command failed"
  assert_contains "$out" "council=dry-run" "a dry-run home convenes nothing: $out"
  assert_equals 0 "$(seat_calls)" "a dry run calls no seat"
  [ ! -e "$H/data/watchdog/rulings" ] || fail "a dry run wrote a ruling"
  pass "council command: a home whose decision path is a dry run gets no council"
}

test_council_runs_one_at_a_time_per_decision() {
  local out lock
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  printf 'A (recommended) ship plus filed follow-up, or B one more fix round?\n' > "$H/record.txt"
  lock=$(council_fixture_record t1 s1-cache) || fail "cannot prepare lock fixture"
  lock="$H/state/watchdog/council-locks/$(basename "${lock%.md}")"
  mkdir -p "$lock"
  printf '%s\n' "$LOCKPID" > "$lock/pid"
  out=$(run_wd 0 council --task t1 --key s1-cache --record-file "$H/record.txt" 2>/dev/null) || fail "council command failed under a live lock"
  assert_contains "$out" "council=busy" "a running council on the same decision is not joined: $out"
  assert_equals 0 "$(seat_calls)" "a busy council calls no seat"
  printf '999999\n' > "$lock/pid"
  out=$(run_wd 10 council --task t1 --key s1-cache --record-file "$H/record.txt" 2>/dev/null) || fail "council command failed past a dead lock"
  assert_contains "$out" "council=ruled" "a lock whose owner is gone does not block the council: $out"
  [ ! -e "$lock" ] || fail "the council left its lock behind"
  pass "council: one convening of a decision at a time; a dead owner's lock is cleared"
}

test_awaiting_approval_reaches_council_despite_merge_word() {
  local out
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  printf '%s\n' 'PR #562 no-mistakes test step awaiting_approval after the once-rerun. A (recommended) approve the step so the PR can merge when gate-green, or B hold for the owner?' > "$H/record.txt"
  out=$(run_wd 0 council --task t1 --key nm-test-awaiting --record-file "$H/record.txt" 2>&1) || fail "awaiting_approval council failed: $out"
  assert_contains "$out" "council=ruled answer=PROCEED A" "an awaiting_approval step is a council decision even when the record names the merge it unblocks: $out"
  assert_equals 2 "$(seat_calls)" "both seats saw the awaiting_approval record"
  printf '%s\n' 'PR #9 no-mistakes deploy step awaiting_approval. A deploy to production, or B hold for the owner?' > "$H/record.txt"
  out=$(run_wd 10 council --task t1 --key nm-deploy --record-file "$H/record.txt" 2>&1) || fail "human-only council failed: $out"
  assert_contains "$out" "council=held answer=none" "a deploy awaiting_approval stays the owner's: $out"
  assert_equals 2 "$(seat_calls)" "no seat saw the human-only record"
  pass "council: a no-mistakes awaiting_approval step reaches the council despite a merge word; a human-only category stays held"
}

test_known_unreachable_timing_flake_defaults_approve_not_clean() {
  local out
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  printf '%s\n' 'PR #562 no-mistakes test awaiting_approval. The once-rerun failed only on a known load-sensitive timing flake in a test the PR cannot reach. A approve the park, or B hold for the owner?' > "$H/record.txt"
  out=$(run_wd 0 council --task t1 --key nm-flake --record-file "$H/record.txt" 2>&1) || fail "flake council failed: $out"
  assert_contains "$out" "council=ruled answer=PROCEED A" "the flake council rules: $out"
  assert_grep "known unreachable timing flake: default to PROCEED A" "$H/prompt.log" "the seat prompt defaults a known unreachable timing flake to approve, labeled not clean"
  assert_grep "approved, not clean" "$H/prompt.log" "the seat prompt labels the flake approval not clean"
  : > "$H/prompt.log"
  printf '%s\n' 'A (recommended) flat keys, or B nested keys?' > "$H/record.txt"
  out=$(run_wd 10 council --task t1 --key plain-layout --record-file "$H/record.txt" 2>&1) || fail "plain council failed: $out"
  assert_no_grep "known unreachable timing flake: default to PROCEED A" "$H/prompt.log" "an ordinary record gets no flake default"
  pass "council: a known unreachable timing flake is put to the seats as a default approve, labeled not clean"
}

test_council_revisit_on_contradicting_record() {
  local out archived
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED B" ok:"PROCEED B"
  printf '%s\n' 'PR #562 no-mistakes test awaiting_approval. A approve the park, or B hold for the owner?' > "$H/record.txt"
  out=$(run_wd 0 council --task t1 --key nm-hold --record-file "$H/record.txt" 2>&1) || fail "first council failed: $out"
  assert_contains "$out" "answer=PROCEED B" "the first council holds: $out"
  out=$(run_wd 10 council --task t1 --key nm-hold --record-file "$H/record.txt" 2>&1) || fail "replay failed: $out"
  assert_contains "$out" "answer=PROCEED B" "without a revisit the recorded outcome replays: $out"
  assert_equals 2 "$(seat_calls)" "a plain repeat reaches no seat"
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  printf '%s\n' 'Later standing order contradicting the hold on PR #562: merge gate-green PRs with no per-PR OK and accept the known flake risk. PR #562 no-mistakes test awaiting_approval. A approve the park, or B hold for the owner?' > "$H/record2.txt"
  out=$(run_wd 20 council --task t1 --key nm-hold --record-file "$H/record2.txt" --revisit 2>&1) || fail "revisit council failed: $out"
  assert_contains "$out" "council=ruled answer=PROCEED A" "a contradicting later order gets a fresh ruling, not a fishing refusal: $out"
  assert_equals 4 "$(seat_calls)" "the revisit convened both seats again"
  archived=$(grep -rl 'PROCEED B (unanimous' "$H/data/watchdog/revisits/" 2>/dev/null | head -n 1)
  [ -n "$archived" ] || fail "the superseded ruling was not archived under data/watchdog/revisits/"
  pass "council: a later contradicting order revisits a hold through --revisit, archiving the prior ruling"
}

test_decision_nudge_names_pr_by_number() {
  make_home $'Captain session\n> ' 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  fake_models "$H" ok:"PROCEED A" ok:"PROCEED A"
  transcript 100 "Working."
  printf 'needs-decision [at=%s] [key=nm-test-awaiting]: G3 no-mistakes test awaiting_approval for PR #562. A (recommended) approve, or B hold?\n' "$((BASE - 9000))" > "$H/state/t1.status"
  run_wd 0 once >/dev/null 2>&1 || fail "decision pass failed"
  assert_equals 1 "$(ledger_rows decisions nudge pending)" "the aged decision gets its nudge: $(ledger | cut -f5-8)"
  grep -rqs 'PR #562' "$H/state/operational-inbox" || fail "the decision nudge does not name the PR by number: $(cat "$H"/state/operational-inbox/* 2>&1)"
  pass "decisions: the nudge names work by PR number from the record, not by a goal alias alone"
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
  fm_touch_epoch "$((BASE - 1))" "$H/state/.lock-session"
  run_wd 0 once >/dev/null 2>&1 || fail "first pass failed"
  run_wd 1000 once >/dev/null 2>&1 || fail "second pass failed"
  assert_equals "" "$(cat "$H/typed.log")" "another session's pane gets no text"
  assert_equals 0 "$(ledger | awk -F'\t' '$6 == "nudge" && $7 != "refused"' | wc -l | tr -d ' ')" "no nudge goes out to another session's pane: $(ledger | cut -f5-8)"
  assert_grep "no recorded terminal endpoint" "$H/data/watchdog/status.md" "the unproven endpoint is reported"
  printf '%s\n' "$SID" > "$H/state/.lock-session"
  fm_touch_epoch "$((BASE - 1))" "$H/state/.lock-session"
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
      fm_touch_epoch "$((BASE - 1))" "$H/state/.lock-session"
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
    jq --arg sid "$SID" '.primary.session.trusted_id = $sid | .primary.writer.session_id = $sid' "$H/state/heartbeat.json" > "$H/heartbeat.tmp"
    mv "$H/heartbeat.tmp" "$H/state/heartbeat.json"
    fm_touch_epoch "$((BASE - 1))" "$H/state/.lock-session"
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
  local pane home
  make_home $'Captain session\n> ' "restart=on
max-nudges=0
pickup-secs=600
restart-command=$TMP_ROOT/fake-captain.sh"
  cat > "$TMP_ROOT/fake-captain.sh" <<'SH'
#!/usr/bin/env bash
p="$*"
sid=$(head -n 1 "$PWD/state/.lock-session")
printf '%s\n' "$$" > "$PWD/state/.lock"
# A real session start records the endpoint it took the lock from.
printf '%s\nbackend=tmux\nterminal=%s\nworktree=%s\n' "$sid" "$TMUX_PANE" "$PWD" > "$PWD/state/.lock-session"
( sleep "${WD_FIXTURE_SLEEP:-100000}" > /dev/null 2>&1 & printf '%s\n' "$!" > "$PWD/state/.supervise-daemon.pid" )
eval "${p##*run: }" > "$PWD/pickup.out" 2>&1
# Leave an idle composer on the successor pane so later passes can read it.
printf 'Captain session\n> \n'
exec sleep "${WD_FIXTURE_SLEEP:-100000}"
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
  pane=$(captain_field target)
  [ -n "$pane" ] || fail "pickup left no captain terminal"
  fresh_heartbeat "$pane"
  # Two restarts inside a day is a loop: the next proven stall escalates instead.
  # A pending row needs a token and a matching done row so reconcile does not
  # treat the injected earlier restart as an in-flight relaunch with no outcome.
  home=$(cd -P "$H" && pwd -P)
  printf '%s\tx1\t%s\thome\tfrozen\trestart\tpending\ttoken=ab old_pid=1\n%s\tx1\t%s\thome\tfrozen\trestart\tdone\tverified\n' \
    "$((BASE - 20000))" "$home" "$((BASE - 19900))" "$home" >> "$H/state/watchdog/actions.tsv"
  # The successor pane must stay still for a freeze proof; a typed nudge would reset it.
  FM_WD_TEST_COMPOSER=unknown run_wd 20000 once >/dev/null 2>&1
  FM_WD_TEST_COMPOSER=unknown run_wd 21000 once >/dev/null 2>&1
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
exec sleep "${WD_FIXTURE_SLEEP:-100000}"
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
exec sleep "${WD_FIXTURE_SLEEP:-100000}"
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
  printf '%s\nanchor_pid=%s\nanchor_start=Sat Nov  1 02:00:00 2026\nbackend=tmux\nterminal=%s\nworktree=%s\n' "$SID" "$LOCKPID" "$T" "$H" > "$H/state/.lock-session"
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

# owner_heartbeat [backend] [target]: rewrite the home's heartbeat as this lock
# owner at BASE, the same proof make_home writes. A heartbeat without writer
# identity is not an address.
owner_heartbeat() {
  jq -n --arg b "${1:-tmux}" --arg t "${2:-$T}" --arg s "$SID" --argjson e "$BASE" --argjson p "$LOCKPID" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:$b,target:$t,present:true},session:{trusted_id:$s},writer:{anchor_pid:$p,session_id:$s}}}' \
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
  ( sleep "$WD_FIXTURE_SLEEP" > /dev/null 2>&1 & printf '%s\n' "$!" > "$H/lockpid" )
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
exec sleep "${WD_FIXTURE_SLEEP:-100000}"
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
  ( sleep "$WD_FIXTURE_SLEEP" > /dev/null 2>&1 & printf '%s\n' "$!" > "$H/lockpid" )
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
  ( env CODEX_THREAD_ID="$SID" CODEX_SESSION_ID="$SID" python3 -c 'import time; time.sleep(100000)' "$WD_FIXTURE_SLEEP" > /dev/null 2>&1 & printf '%s\n' "$!" > "$H/bound" )
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
  ( sleep "$WD_FIXTURE_SLEEP" > /dev/null 2>&1 & printf '%s\n' "$!" > "$H/lockpid" )
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

test_no_quota_check_while_restart_awaits_pickup() {
  make_home $'Captain session\n> ' "restart=on
max-nudges=0
pickup-secs=600
restart-command=/bin/true
quota-guard-every-secs=100"
  grep -v '^quota-guard=' "$H/config/watchdog" > "$H/watchdog.conf" && mv "$H/watchdog.conf" "$H/config/watchdog"
  wd_quota_snapshot "$H/quota.json"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
cat "$H/quota.json"
SH
  chmod +x "$FAKEBIN/quota-axi"
  transcript 3000 "Working." "Testing." "Green."
  owe_input 3000
  run_wd 0 once >/dev/null 2>&1
  run_wd 1000 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows frozen restart pending)" "the proven stall restarts"
  assert_equals 1 "$(ledger_rows quota-guard check "done")" \
    "the pass that starts the restart runs no quota check: $(ledger | cut -f1,5-7)"
  local before
  before=$(ledger | wc -l | tr -d ' ')
  rm -f "$H/state/.wake-queue"
  # A worker on the auto-wait footer is a limit warning, which is only recorded.
  mkdir -p "$H/wt"
  worker_pane waiter ship $'work output\nUsage limit reached. Continuing automatically at 4:00 AM\n❯ \n  ? for shortcuts'
  printf 'harness=claude\nworktree=%s\nmodel=default\n' "$H/wt" >> "$H/state/waiter.meta"
  sleep 0.5
  # A quota check is due on every pass here, so only the hold keeps it away.
  run_wd 1120 once >/dev/null 2>&1
  assert_equals "$before" "$(ledger | awk -F'\t' '!($5 == "quota-guard" && $6 == "warning")' | wc -l | tr -d ' ')" \
    "no quota check runs while the restart awaits pickup: $(ledger | cut -f1,5-7)"
  assert_grep "	waiter	ordinary	default	claude" "$H/state/quota-limit-dialogs.tsv" "the worker's limit dialog is still recorded"
  assert_no_grep "trigger=warning" "$H/state/quota-guard/last" "the worker's limit warning runs no check while the restart awaits pickup"
  rm -f "$FAKEBIN/quota-axi"
  pass "boundary: a home whose restart awaits pickup gets no quota check either"
}

test_mate_warning_holds_while_its_parent_restart_awaits_pickup() {
  local parent mate autowait
  autowait=$'work output\nUsage limit reached. Continuing automatically at 4:00 AM\n❯ \n  ? for shortcuts'
  make_home $'Captain session\n> ' "restart=on
max-nudges=0
pickup-secs=600
restart-command=/bin/true
quota-guard-every-secs=100"
  parent=$H
  grep -v '^quota-guard=' "$parent/config/watchdog" > "$parent/watchdog.conf" && mv "$parent/watchdog.conf" "$parent/config/watchdog"
  wd_quota_snapshot "$parent/quota.json"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
cat "$parent/quota.json"
SH
  chmod +x "$FAKEBIN/quota-axi"
  transcript 3000 "Working." "Testing." "Green."
  owe_input 3000
  run_wd 0 once >/dev/null 2>&1
  run_wd 1000 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows frozen restart pending)" "the proven stall restarts"
  rm -f "$parent/state/.wake-queue"
  make_home "$autowait"
  mate=$H
  transcript 100 "Working."
  H=$parent
  printf -- '- ghost-mate - test mate (home: %s)\n' "$mate" > "$parent/data/secondmates.md"
  printf 'harness=claude\nkind=secondmate\nhome=%s\nworktree=%s\nmodel=default\n' "$mate" "$mate" > "$parent/state/ghost-mate.meta"
  sleep 0.5
  run_wd 1120 once >/dev/null 2>&1
  assert_grep "	ghost-mate	ordinary	default	claude" "$parent/state/quota-limit-dialogs.tsv" \
    "the second mate's limit dialog is still recorded in its parent: $(cat "$parent/state/quota-limit-dialogs.tsv" 2>&1)"
  assert_no_grep "trigger=warning" "$parent/state/quota-guard/last" \
    "a second mate's warning runs no check in a parent whose restart awaits pickup"
  rm -f "$FAKEBIN/quota-axi"
  pass "boundary: a second mate's limit warning runs no check while its parent's restart awaits pickup"
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

# A fresh-start launch that fails between the pass's observation and its
# restart leaves the session supervising with auto-compaction as its reset.
# The watchdog takes the launcher's own launch lock before it re-reads the
# reset, so a launch under way, or one that just failed, stops nobody.
test_low_context_restart_rechecks_a_failed_launch() {
  local seam="$TMP_ROOT/ln-seam" launcher i
  make_home $'Captain session\n> \n  7% until auto-compact' "restart=on
handoff-wait-secs=600
restart-command=$TMP_ROOT/fake-captain.sh"
  write_fake_captain
  transcript 3000 "Working." "Testing." "Green."
  printf 'session=%s compact_at=100000 at=%s reset=handoff\n' "$SID" "$BASE" > "$H/state/compact-point"
  FM_WD_TEST_COMPOSER=empty run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows handoff-request nudge pending)" "a handoff cycle at low context asks for a handoff"

  # A launcher holds its launch lock: the restart waits for it.
  bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2/state/.handoff-launch.lock" || exit 1; : > "$2/launcher-ready"; sleep 60' \
    _ "$ROOT" "$H" &
  launcher=$!
  i=0
  while [ ! -e "$H/launcher-ready" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$H/launcher-ready" ] || fail "the launcher fixture never took its lock"
  FM_WD_TEST_COMPOSER=empty run_wd 700 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows restart-requested restart pending)" "no restart while a fresh-start launch is under way: $(ledger | cut -f5-8)"
  assert_equals 0 "$(ledger_rows restart-requested restart refused)" "a held restart is a gap, not a rate-counted restart row"
  assert_grep "a fresh-start launch is under way" "$H/data/watchdog/status.md" "the held restart is a reported gap"
  kill -0 "$LOCKPID" 2>/dev/null || fail "the session was stopped during a launch"
  kill "$launcher" 2>/dev/null; wait "$launcher" 2>/dev/null || true
  rm -rf "$H/state/.handoff-launch.lock"

  # The launch fails just before the watchdog takes the lock, after the pass
  # observed the handoff reset: the re-read under the lock sees it.
  mkdir -p "$seam"
  cat > "$seam/ln" <<EOF
#!/usr/bin/env bash
case "\${*: -1}" in
  */.handoff-launch.lock) printf 'at=%s pid=%s nonce=none attempt=2 reason=deadline\\n' "$BASE" "$LOCKPID" > "$H/state/.handoff-launch-failed" ;;
esac
exec "$(command -v ln)" "\$@"
EOF
  chmod +x "$seam/ln"
  [ ! -e "$H/state/.handoff-launch-failed" ] || fail "the failure record must land during the pass"
  PATH="$seam:$PATH" FM_WD_TEST_COMPOSER=empty run_wd 750 once >/dev/null 2>&1
  [ -e "$H/state/.handoff-launch-failed" ] || fail "the seam never recorded the failed launch"
  assert_equals 0 "$(ledger_rows restart-requested restart pending)" "no restart starts after a failed launch: $(ledger | cut -f5-8)"
  assert_grep "left this cycle to auto-compaction" "$H/data/watchdog/status.md" "the refused restart is a reported gap"
  [ ! -e "$H/state/.handoff-launch.lock" ] && [ ! -L "$H/state/.handoff-launch.lock" ] || fail "the watchdog left the launch lock held"
  kill -0 "$LOCKPID" 2>/dev/null || fail "the surviving session was stopped"
  FM_WD_TEST_COMPOSER=empty run_wd 800 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows restart-requested restart pending)" "a later pass reads auto-compaction and restarts nobody"
  kill -0 "$LOCKPID" 2>/dev/null || fail "a later pass stopped the surviving session"
  pass "low context: a fresh-start launch under way or just failed leaves the session running"
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
  owner_heartbeat herdr pane-1
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
  owner_heartbeat orca term-1
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
  [ -f "$(council_record_path rulings t1 cache-layout)" ] || fail "a verdict ending in T read as failed: $(cat "$H/state/watchdog/model-calls.tsv")"
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
    jq -n --arg t "$T" --arg s "$([ "$case_sid" = other ] && printf 'another-session' || printf '%s' "$SID")" --argjson e "$((BASE - age))" --argjson p "$LOCKPID" \
      '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:"tmux",target:$t,present:true},session:{trusted_id:$s},writer:{anchor_pid:$p,session_id:$s},context_left:{remaining:{percent:7}}}}' \
      > "$H/state/heartbeat.json"
    fm_touch_epoch "$((BASE - age - 1))" "$H/state/.lock" "$H/state/.lock-session"
    FM_WD_TEST_COMPOSER=empty run_wd 0 once >/dev/null 2>&1
    assert_equals 0 "$(ledger_rows handoff-request nudge pending)" "$case_sid heartbeat percent starts nothing: $(ledger | cut -f5-8)"
  done
  jq -n --arg t "$T" --arg s "$SID" --argjson e "$BASE" --argjson p "$LOCKPID" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:"tmux",target:$t,present:true},session:{trusted_id:$s},writer:{anchor_pid:$p,session_id:$s},context_left:{remaining:{percent:7}}}}' \
    > "$H/state/heartbeat.json"
  FM_WD_TEST_COMPOSER=empty run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows handoff-request nudge pending)" "a fresh percent for this session counts: $(ledger | cut -f5-8)"
  pass "heartbeat percent counts only when fresh and for the current session"
}

test_orca_draft_probe_failure_holds_the_nudge() {
  make_home $'Captain session\n> '
  transcript 3000 "Working." "Testing." "Green."
  owe_input 3000
  owner_heartbeat orca term-1
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
  owner_heartbeat orca term-1
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
  # The mate's session took its lock before it wrote that transcript.
  fm_touch_epoch "$((BASE - 5000))" "$mate/state/.lock" "$mate/state/.lock-session"
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

# mate_code_root: a copy of bin/ whose fm-control.sh logs its argv and exits 0
# without starting anything, the zero exit a second mate relaunch can give
# while its session never takes over. Sets MATE_WD.
MATE_WD=''
mate_code_root() {
  [ -z "$MATE_WD" ] || return 0
  mkdir -p "$TMP_ROOT/code"
  cp -R "$ROOT/bin" "$TMP_ROOT/code/bin"
  cat > "$TMP_ROOT/code/bin/fm-control.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP_ROOT/code/control.log"
exit 0
SH
  chmod +x "$TMP_ROOT/code/bin/fm-control.sh"
  MATE_WD=$TMP_ROOT/code/bin/fm-watchdog.sh
}

# mate_restarted: a parent home whose second mate asked for a restart, run
# until that relaunch exits 0. Sets H (parent), MATE, and MATE_OLD (the old lock pid).
mate_restarted() {
  local parent
  mate_code_root
  : > "$TMP_ROOT/code/control.log"
  make_home $'Captain session\n> '
  parent=$H
  make_home $'Mate session\n> '
  MATE=$H
  MATE_OLD=$LOCKPID
  transcript 3000 "Working." "Testing." "Green."
  printf '%s\n' "$MATE_OLD" > "$MATE/state/.session-start-complete"
  fm_touch_epoch "$((BASE - 5000))" "$MATE/state/.lock" "$MATE/state/.lock-session" "$MATE/state/.session-start-complete"
  : > "$MATE/state/.watchdog-restart-request"
  fm_touch_epoch "$((BASE - 10))" "$MATE/state/.watchdog-restart-request"
  printf -- '- ghost-mate - test mate (home: %s)\n' "$MATE" > "$parent/data/secondmates.md"
  printf 'mode=act\nclaude-config-dirs=%s\nkey-settle-secs=1\nmodels=\nrestart=on\npickup-secs=600\nrelaunch-timeout-secs=20\n' "$MATE/claude" > "$parent/config/watchdog"
  H=$parent
  WD=$MATE_WD run_wd 0 once >/dev/null 2>&1
  WD=$MATE_WD run_wd 10 once >/dev/null 2>&1
  assert_grep "ghost-mate relaunch --note-file" "$TMP_ROOT/code/control.log" "the relaunch went through the parent"
  assert_equals 1 "$(ledger_rows restart-requested restart pending)" "the relaunch is pending: $(ledger | cut -f5-8)"
}

# mate_lock <pid>: the second mate's lock names <pid>, taken at offset 20.
mate_lock() {
  printf '%s\n' "$1" > "$MATE/state/.lock"
  fm_touch_epoch "$((BASE + 20))" "$MATE/state/.lock"
}

# mate_started <pid> <offset>: session start completed under <pid> at <offset>.
mate_started() {
  printf '%s\n' "$1" > "$MATE/state/.session-start-complete"
  fm_touch_epoch "$((BASE + $2))" "$MATE/state/.session-start-complete"
}

live_pid() { ( sleep "$WD_FIXTURE_SLEEP" > /dev/null 2>&1 & printf '%s\n' "$!" > "$TMP_ROOT/live.pid" ); cat "$TMP_ROOT/live.pid"; }

test_second_mate_zero_exit_relaunch_is_not_done() {
  local dead new
  mate_restarted
  WD=$MATE_WD run_wd 20 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows restart-requested restart "done")" "a zero exit with the old lock is not done: $(ledger | cut -f5-8)"
  assert_grep "RESTART-AWAITING-PICKUP" "$H/data/watchdog/status.md" "the second mate waits for its pickup"
  # The old session runs session start again under its own lock.
  mate_started "$MATE_OLD" 30
  WD=$MATE_WD run_wd 40 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows restart-requested restart "done")" "the old pid is no pickup: $(ledger | cut -f5-8)"
  ( sleep 0 & printf '%s\n' "$!" > "$TMP_ROOT/dead.pid" )
  dead=$(cat "$TMP_ROOT/dead.pid")
  while kill -0 "$dead" 2>/dev/null; do sleep 0.1; done
  mate_lock "$dead"
  mate_started "$dead" 50
  WD=$MATE_WD run_wd 60 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows restart-requested restart "done")" "a dead new lock holder is no pickup: $(ledger | cut -f5-8)"
  new=$(live_pid)
  LOCK_PIDS="$LOCK_PIDS $new"
  mate_lock "$new"
  mate_started "$MATE_OLD" 30
  WD=$MATE_WD run_wd 70 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows restart-requested restart "done")" "a new lock before session start completes is no pickup: $(ledger | cut -f5-8)"
  mate_started "$new" -100
  WD=$MATE_WD run_wd 80 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows restart-requested restart "done")" "a session start from before the restart is no pickup: $(ledger | cut -f5-8)"
  mate_started "$MATE_OLD" 30
  WD=$MATE_WD run_wd 610 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows restart-requested restart failed)" "no proof within pickup-secs fails the restart: $(ledger | cut -f5-8)"
  assert_equals 0 "$(ledger_rows restart-requested restart "done")" "the failed restart is never done: $(ledger | cut -f5-8)"
  assert_grep "self-heal issue not filed for watchdog-restart-requested" "$H/data/watchdog/status.md" "the unproven pickup reaches self-heal"
  WD=$MATE_WD run_wd 700 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows restart-requested restart pending)" "restart-secs still holds the next relaunch: $(ledger | cut -f5-8)"
  assert_equals 1 "$(grep -c relaunch "$TMP_ROOT/code/control.log")" "one relaunch inside the restart interval"
  pass "second mate: a zero-exit relaunch is done only after a verified pickup, and caps hold"
}

test_second_mate_restart_done_after_session_start_under_new_lock() {
  local new
  mate_restarted
  new=$(live_pid)
  LOCK_PIDS="$LOCK_PIDS $new"
  mate_lock "$new"
  mate_started "$new" 30
  WD=$MATE_WD run_wd 40 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows restart-requested restart "done")" "a new live lock with its session start is done: $(ledger | cut -f5-8)"
  assert_contains "$(ledger | awk -F'\t' '$6 == "restart" && $7 == "done"' | cut -f8)" "session start verified; new lock pid $new" "the done row names the new lock pid"
  pass "second mate: a relaunch is done once its session start runs under a new live lock"
}

test_second_mate_session_start_after_the_window_is_not_done() {
  local new
  mate_restarted
  new=$(live_pid)
  LOCK_PIDS="$LOCK_PIDS $new"
  mate_lock "$new"
  # The restart began at offset 10, so pickup-secs=600 closes its window at 610.
  mate_started "$new" 611
  WD=$MATE_WD run_wd 620 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows restart-requested restart "done")" "a session start after the window is no pickup: $(ledger | cut -f5-8)"
  assert_equals 1 "$(ledger_rows restart-requested restart failed)" "the late pickup fails the restart: $(ledger | cut -f5-8)"
  pass "second mate: a session start after pickup-secs is not a pickup"
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
  assert_equals question "$(lib fm_wd_pane_dialog "It asked: do you want to proceed?$q")" "a permission phrase in an earlier paragraph does not label the current picker"
  assert_equals question "$(lib fm_wd_pane_dialog $'It asked: do you want to proceed?\n──────────'"$q")" "a rule proves a permission phrase is conversation"
  assert_equals question "$(lib fm_wd_pane_dialog $'Do you trust the files in this folder?\n\n/some/path\n\nClaude Code may read files here.\n ❯ 1. Yes, proceed\n   2. No, exit\n\nEnter to confirm · Esc to cancel')" "a trust phrase outside the current picker paragraph does not label it"

  make_home $'Do you want to proceed?\n\ndetail row\n ❯ 1. Yes\n   2. No\n\nEnter to confirm · Esc to cancel'
  transcript 100 "Working."
  run_wd 0 once >/dev/null 2>&1
  assert_equals 0 "$(ledger | awk -F'\t' '$6 == "key"' | wc -l | tr -d ' ')" "an unproven dialog gets no Escape: $(ledger | cut -f5-8)"
  assert_grep "question dialog waiting" "$H/data/watchdog/status.md" "the dialog left alone is reported"

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
  assert_grep "question dialog waiting" "$H/data/watchdog/status.md" "the picker whose trust heading is outside its paragraph is still held and reported"

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
  owner_heartbeat orca term-1
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

# act_rows <owner-home>: the supervisor-activity record.
act_rows() { cat "$1/state/night-score/supervisor-activity.tsv" 2>/dev/null; }

test_second_mate_activity_sources() {
  local parent mate m tag out led
  make_home $'Captain session\n> '
  parent=$H
  transcript 100 "Working."
  make_home $'Mate session\n> '
  mate=$H
  MATE_LOCKPID=$LOCKPID MATE_SID=$SID
  m=$(canon "$mate")
  tag=$(basename "$m")
  printf -- '- act-mate - test mate (home: %s)\n' "$mate" > "$parent/data/secondmates.md"
  printf 'harness=codex\n' > "$parent/state/act-mate.meta"
  rm -f "$mate/state/.lock" "$mate/state/.lock-session"
  H=$parent
  out=$(run_wd 0 scan --home "$m" 2>&1)
  assert_contains "$out" 'activity_age=unknowns' "a mate with no record has no activity source: $out"
  run_wd 0 once >/dev/null 2>&1
  assert_grep "$tag: no activity source" "$parent/data/watchdog/status.md" "the sourceless mate is reported"
  assert_equals "$BASE"$'\t'"$m"$'\tnone\t-' "$(act_rows "$parent" | awk -F'\t' -v h="$m" '$2 == h')" "the record names a mate with no source"

  # A mate whose session took its lock and has not acknowledged a wake yet: the
  # lock is the source, so a harness with no other record is still measured.
  printf '%s\n' "$MATE_LOCKPID" > "$mate/state/.lock"
  printf '%s\n' "$MATE_SID" > "$mate/state/.lock-session"
  fm_touch_epoch "$((BASE - 900))" "$mate/state/.lock" "$mate/state/.lock-session"
  out=$(run_wd 0 scan --home "$m" 2>&1)
  assert_contains "$out" 'activity_age=900s (session-lock)' "a freshly started mate reads its session lock: $out"

  # A Codex mate: its own drain acknowledgement is the source. Other removal
  # rows, a malformed stamp, and a stamp later than the clock do not count.
  led=$mate/state/wake-ledger.tsv
  {
    printf '%s\tack\tg1\t4\t4\t["a"]\n' "$((BASE - 400))"
    printf '%s\tack\tg1\t5\t5\t["b"]\n' "$((BASE - 120))"
    printf '%s\tconsumed\tg1\t5\t5\t["b"]\n' "$((BASE - 10))"
    printf '%s\tretired\t-\t-\t6\t["c"]\n' "$((BASE - 5))"
    printf '0%s\tack\tg1\t7\t7\t["d"]\n' "$((BASE - 2))"
    printf '%s\tack\tg1\t8\t8\t["e"]\n' "$((BASE + 500))"
  } > "$led"
  assert_equals "$((BASE - 120))" "$(lib fm_wd_last_wake_ack "$led" "$BASE")" "the newest ack row not later than the clock"
  lib fm_wd_last_wake_ack "$mate/state/absent.tsv" "$BASE" >/dev/null && fail "an absent ledger has no ack"
  out=$(run_wd 0 scan --home "$m" 2>&1)
  assert_contains "$out" 'activity_age=120s (wake-ack)' "a Codex mate reads its last acknowledgement: $out"
  # An acknowledgement the away daemon made is not the session's own activity.
  printf 'g1\t5\n' > "$mate/state/.supervise-daemon.acks"
  assert_equals "$((BASE - 400))" "$(lib fm_wd_last_wake_ack "$led" "$BASE" "$mate/state/.supervise-daemon.acks")" "the daemon's ack row is skipped"
  out=$(run_wd 0 scan --home "$m" 2>&1)
  assert_contains "$out" 'activity_age=400s (wake-ack)' "the daemon's acknowledgement does not count for the mate: $out"
  rm -f "$mate/state/.supervise-daemon.acks"

  # A Claude mate: its parent-side busy record, only from a trusted source of
  # the current incarnation.
  printf 'harness=claude\n' > "$parent/state/act-mate.meta"
  printf 'g7\n' > "$parent/state/act-mate.busy-gen"
  printf 'v1 gen=g7 seq=3 state=idle source=claude-hook event=stop ts=%s\n' "$((BASE - 60))" > "$parent/state/act-mate.busy-state"
  out=$(run_wd 0 scan --home "$m" 2>&1)
  assert_contains "$out" 'activity_age=60s (busy-state)' "a Claude mate reads its busy record: $out"
  printf 'v1 gen=g7 seq=4 state=idle source=pi-ext event=stop ts=%s\n' "$((BASE - 30))" > "$parent/state/act-mate.busy-state"
  out=$(run_wd 0 scan --home "$m" 2>&1)
  assert_contains "$out" 'activity_age=120s (wake-ack)' "a source the harness does not trust is no activity: $out"
  printf 'v1 gen=g6 seq=5 state=idle source=claude-hook event=stop ts=%s\n' "$((BASE - 30))" > "$parent/state/act-mate.busy-state"
  out=$(run_wd 0 scan --home "$m" 2>&1)
  assert_contains "$out" 'activity_age=120s (wake-ack)' "a stale incarnation is no activity: $out"

  : > "$parent/state/act-mate.turn-ended"
  fm_touch_epoch "$((BASE - 20))" "$parent/state/act-mate.turn-ended"
  out=$(run_wd 0 scan --home "$m" 2>&1)
  assert_contains "$out" 'activity_age=20s (turn-ended)' "the newest source wins: $out"
  run_wd 10 once >/dev/null 2>&1
  assert_grep "$tag: ok, last turn 0m ago via turn-ended" "$parent/data/watchdog/status.md" "a mate with a source reads ok"
  assert_no_grep "$tag: NO-ACTIVITY-SOURCE" "$parent/data/watchdog/status.md" "the mate is no longer sourceless"
  assert_equals "$((BASE + 10))"$'\t'"$m"$'\tturn-ended\t30' "$(act_rows "$parent" | awk -F'\t' -v h="$m" '$2 == h' | tail -n 1)" "the record names the source and its age"
  assert_equals "$((BASE + 10))"$'\t'"$(canon "$parent")"$'\ttranscript\t110' "$(act_rows "$parent" | awk -F'\t' -v h="$(canon "$parent")" '$2 == h' | tail -n 1)" "the owner home has its own row"
  assert_absent "$mate/state/night-score/supervisor-activity.tsv" "the second mate's own home holds no record"
  out=$(run_wd 20 scan >/dev/null 2>&1; act_rows "$parent" | wc -l | tr -d ' ')
  assert_equals 4 "$out" "scan appends nothing"
  pass "second mate: its session lock, a drain acknowledgement, a trusted busy record, or a turn-ended marker is an activity source"
}

test_second_mate_freeze_is_seen_without_a_transcript() {
  local parent mate
  make_home $'Captain session\n> '
  parent=$H
  transcript 100 "Working."
  make_home $'Mate session\n> '
  mate=$H
  printf -- '- frozen-mate - test mate (home: %s)\n' "$mate" > "$parent/data/secondmates.md"
  printf 'harness=codex\n' > "$parent/state/frozen-mate.meta"
  printf '%s\tack\tg1\t4\t4\t["a"]\n' "$((BASE - 3000))" > "$mate/state/wake-ledger.tsv"
  owe_input 3000
  H=$parent
  run_wd 0 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows frozen nudge pending)" "a first sight is no stall"
  run_wd 1000 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows frozen nudge pending)" "a frozen Codex mate with owed input gets one nudge: $(ledger | cut -f5-8)"
  pass "second mate: a mate with no transcript is seen to freeze through its activity source"
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
  LOCKPID=$(cat "$H/state/.lock")
  owner_heartbeat
  fm_touch_epoch "$((BASE - 1))" "$H/state/.lock" "$H/state/.lock-session"
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
exec sleep $WD_FIXTURE_SLEEP
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
  make_home $'work output 1\n● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss'
  run_wd 0 once >/dev/null 2>&1
  # The shared claim never sends a second key on the same pane hash.
  run_wd 150 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows dialog key pending)" "the shared claim never sends a second key on the same pane"
  printf '%s\n' $'work output 2\n● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss' > "$H/screen.txt"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" respawn-pane -k -t "$T" "$H/agent.sh"
  sleep 0.3
  run_wd 200 once >/dev/null 2>&1
  printf '%s\n' $'work output 3\n● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss' > "$H/screen.txt"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" respawn-pane -k -t "$T" "$H/agent.sh"
  sleep 0.3
  run_wd 400 once >/dev/null 2>&1
  assert_equals 2 "$(ledger_rows dialog key failed)" "two keys that left the dialog showing are recorded as failed"
  assert_equals 2 "$(ledger_rows dialog key pending)" "no third key is pressed within the hour"
  assert_grep "no more keys pressed" "$H/data/watchdog/status.md" "the stuck dialog is reported"
  pass "dialog keys stop after two failures in an hour, so a misread screen is never typed into repeatedly"
}

# A ticking status percentage under the dialog's input box is not part of the
# dialog. One dismiss key, then a changed percentage, must not send another.
# A changed row above the footer still may.
test_statusline_percentage_does_not_rearm_feedback_dismiss() {
  local dir state fake keys pane rc screen
  dir="$TMP_ROOT/statusline-dismiss-$CASE_N"
  state="$dir/state"
  fake="$dir/fakebin"
  keys="$dir/keys.log"
  pane="$dir/pane.txt"
  mkdir -p "$state" "$fake"
  cat > "$fake/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  capture-pane) cat "$FM_TEST_WATCH_PANE"; exit 0 ;;
  send-keys)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) shift; printf 'LITERAL:%s\n' "${1:-}" >> "$FM_TEST_WATCH_KEYS"; shift ;;
        *) printf 'KEY:%s\n' "$1" >> "$FM_TEST_WATCH_KEYS"; shift ;;
      esac
    done
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fake/tmux"
  : > "$keys"
  survey_screen() {  # <above> <percent>
    printf '%s\n● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss\n────────────────────────────────────────\n❯ \n────────────────────────────────────────\n  Context left until auto-compact: %s%% · ◯ IDE connected\n' "$1" "$2"
  }
  dismiss_once() {
    screen=$(survey_screen "$1" "$2")
    printf '%s\n' "$screen" > "$pane"
    rc=0
    PATH="$fake:$PATH" FM_TEST_WATCH_PANE="$pane" FM_TEST_WATCH_KEYS="$keys" \
      bash -c '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-control-lib.sh"; fm_control_dismiss_feedback_dialog "$2" tmux "test:fm-pct" claude "$3" "fm-pct" 0.1' \
      _ "$ROOT" "$state" "$screen" >/dev/null 2>&1 || rc=$?
    printf '%s\n' "$rc"
  }
  assert_equals 4 "$(dismiss_once "work output 1" 8)" "the first sticky survey records a sent key that left the dialog up"
  assert_equals "LITERAL:0" "$(cat "$keys")" "the first poll sends one dismiss key"
  assert_equals 2 "$(dismiss_once "work output 1" 7)" "a changed auto-compact percentage does not authorize another key"
  assert_equals "LITERAL:0" "$(cat "$keys")" "the percentage tick sends no second dismiss key"
  assert_equals 4 "$(dismiss_once "work output 2" 7)" "a changed row above the footer still authorizes one more key"
  assert_equals $'LITERAL:0\nLITERAL:0' "$(cat "$keys")" "the row above the footer receives the second dismiss key and nothing else"
  pass "feedback dismiss: a statusline percentage tick does not send another key"
}

status_actions() {
  awk '/^## Actions/ { f = 1; next } /^## / { f = 0 } f && /^- /' "$H/data/watchdog/status.md" | wc -l | tr -d ' '
}

# --- supervisor-gap record -----------------------------------------------------

gap_raw() { cat "$1/state/night-score/supervisor-gap.tsv" 2>/dev/null; }
# gap_rows <home>: the rows of the record by the documented rule: a line that
# ends in a newline, with exactly two TAB bytes, no NUL byte and a first field
# of 10 ASCII digits. The shell read drops a NUL byte, so each one is turned
# into a byte the loop can see.
gap_rows() {
  local line tabs epoch
  [ -f "$1/state/night-score/supervisor-gap.tsv" ] || return 0
  LC_ALL=C tr '\000' '\001' < "$1/state/night-score/supervisor-gap.tsv" | while IFS= read -r line; do
    case "$line" in *$'\001'*) continue ;; esac
    tabs=${line//[!$'\t']/}
    epoch=${line%%$'\t'*}
    [ "${#tabs}" -eq 2 ] && [ "${#epoch}" -eq 10 ] || continue
    case "$epoch" in *[!0123456789]*) continue ;; esac
    printf '%s\n' "$line"
  done
}
canon() { (cd -P "$1" && pwd -P); }
# publish <home> <json-value>: stamps the fixture heartbeat with a published_epoch.
publish() {
  jq --argjson p "$2" '.published_epoch = $p' "$1/state/heartbeat.json" > "$1/state/heartbeat.json.new" \
    && mv "$1/state/heartbeat.json.new" "$1/state/heartbeat.json"
}

# gap_no_rows <label> <home> <now> <published-epoch>: the builder refuses the reading.
gap_no_rows() {
  local label=$1 out
  shift
  if out=$(lib fm_wd_supervisor_gap_rows "$@"); then fail "$label: the builder accepted it"; fi
  assert_equals "" "$out" "$label: no row"
}

# gap_report <label> <stderr-text>: a failed append is the open gap in the status
# file and the whole of standard error, one line. The caller removes the status
# file before the pass, so the open gap is the one that pass wrote.
gap_report() {
  assert_grep "supervisor-gap record append failed" "$H/data/watchdog/status.md" "$1 is an open gap in the status file"
  assert_equals 1 "$(printf '%s\n' "$2" | wc -l | tr -d ' ')" "$1 is one standard error line: $2"
  case "$2" in
    'fm-watchdog: supervisor-gap record append failed for '*) ;;
    *) fail "$1 is not named on standard error: $2" ;;
  esac
}

test_supervisor_gap_rows_from_one_reading() {
  local now=1794000000
  assert_equals "$now"$'\tobserved\t/h' "$(lib fm_wd_supervisor_gap_rows /h "$now" "$now")" "age 0 is one observation row"
  assert_equals "$now"$'\tobserved\t/h' "$(lib fm_wd_supervisor_gap_rows /h "$now" 1793999400)" "age 600 is not a gap"
  assert_equals "$now"$'\t/h\theartbeat_age=601\n'"$now"$'\tobserved\t/h' "$(lib fm_wd_supervisor_gap_rows /h "$now" 1793999399)" \
    "age 601 is the gap row, then the observation row"
  gap_no_rows "a stamp later than the clock" /h "$now" 1794000001
  gap_no_rows "a zero stamp" /h "$now" 0
  gap_no_rows "a negative stamp" /h "$now" -5
  gap_no_rows "a fractional stamp" /h "$now" 1793999400.5
  gap_no_rows "a stamp that is not a number" /h "$now" abc
  gap_no_rows "an empty stamp" /h "$now" ""
  gap_no_rows "a zero-padded stamp" /h "$now" 01793999400
  gap_no_rows "a stamp with a digit that is not ASCII" /h "$now" $'179399940\xc2\xb2'
  gap_no_rows "a clock with a digit that is not ASCII" /h $'179400000\xc2\xb2' 1793999400
  gap_no_rows "a stamp too long for shell arithmetic" /h "$now" 99999999999999999999
  gap_no_rows "a clock that is not a number" /h now 1793999400
  gap_no_rows "a zero clock" /h 0 0
  gap_no_rows "a clock of 9 digits" /h 999999999 999999400
  gap_no_rows "a clock of 11 digits" /h 10000000000 9999999400
  gap_no_rows "an empty home" "" "$now" 1793999400
  gap_no_rows "a home with a TAB" $'/h\tx' "$now" 1793999400
  gap_no_rows "a home with a newline" $'/h\nx' "$now" 1793999400
  gap_no_rows "a home with a carriage return" $'/h\rx' "$now" 1793999400
  pass "supervisor-gap rows: an observation per reading, a gap row over 600 s, and no row for an invalid reading or a clock that does not have 10 digits"
}

test_supervisor_gap_heartbeat_stamp_reading() {
  local d="$TMP_ROOT/hb-stamp" f out doc
  mkdir -p "$d/dir.json" "$d/shim"
  f="$d/heartbeat.json"
  printf '{"schema":"fm-heartbeat.v1","generated_epoch":5,"published_epoch":1794000000}\n' > "$f"
  assert_equals 1794000000 "$(lib fm_wd_heartbeat_published "$f")" "a published heartbeat prints its stamp"
  printf '{\n  "schema": "fm-heartbeat.v1",\n  "published_epoch": 1794000000\n}\n' > "$f"
  assert_equals 1794000000 "$(lib fm_wd_heartbeat_published "$f")" "an indented heartbeat prints its stamp"
  # A heartbeat of real size, about 90 KB and indented. No time limit is set here:
  # a text check that matches each key or each space of it makes this the slow case.
  jq -n '{schema:"fm-heartbeat.v1",published_epoch:1794000000,tasks:[range(900) | {id:"task-\(.)",state:"working",note:"x y z"}]}' > "$d/large.json"
  assert_equals 1794000000 "$(lib fm_wd_heartbeat_published "$d/large.json")" "a heartbeat of real size prints its stamp"
  ln -s "$f" "$d/link.json"
  if out=$(lib fm_wd_heartbeat_published "$d/link.json"); then fail "a symbolic link to a heartbeat was accepted"; fi
  assert_equals "" "$out" "a symbolic link to a heartbeat prints nothing"
  printf '{"schema":"fm-heartbeat.v1","published_epoch":999999999999999}\n' > "$f"
  assert_equals 999999999999999 "$(lib fm_wd_heartbeat_published "$f")" "a 15-digit stamp is read"
  printf '{"schema":"fm-heartbeat.v1","published_epoch":1794000000,"task":"caf\351 \377"}\n' > "$f"
  assert_equals 1794000000 "$(lib fm_wd_heartbeat_published "$f")" "bytes that are not UTF-8 in another field do not hide the stamp"
  printf '%s\n' '{"schema":"fm-heartbeat.v1","published_epoch":1794000000,"note":"x,\"published_epoch\":5}","names":["published_epoch"]}' > "$f"
  assert_equals 1794000000 "$(lib fm_wd_heartbeat_published "$f")" "the name of the stamp inside a string value is not a second key"
  printf '%s\n' '{"schema":"fm-heartbeat.v1","published_epoch":1794000000,"n":"x,","m":"{ ","k,":1,"a":["x,","published_epoch"]}' > "$f"
  assert_equals 1794000000 "$(lib fm_wd_heartbeat_published "$f")" "a string that ends in a comma or a brace starts no key"
  for doc in '{"schema":"fm-heartbeat.v1","generated_epoch":1794000000}' \
    '{"schema":"fm-heartbeat.v1","published_epoch":0}' \
    '{"schema":"fm-heartbeat.v1","published_epoch":-1794000000}' \
    '{"schema":"fm-heartbeat.v1","published_epoch":1794000000.5}' \
    '{"schema":"fm-heartbeat.v1","published_epoch":"1794000000"}' \
    '{"schema":"fm-heartbeat.v1","published_epoch":null}' \
    '{"schema":"fm-heartbeat.v1","published_epoch":true}' \
    '{"schema":"fm-heartbeat.v1","published_epoch":1e30}' \
    '{"schema":"fm-heartbeat.v1","published_epoch":1.794e9}' \
    '{"schema":"fm-heartbeat.v1","published_epoch":1794000000.0}' \
    '{"schema":"fm-heartbeat.v1","published_epoch":1234567890123456}' \
    '{"schema":"fm-heartbeat.v2","published_epoch":1794000000}' \
    '{"published_epoch":1794000000}' \
    '[{"schema":"fm-heartbeat.v1","published_epoch":1794000000}]' \
    $'{}\n{"schema":"fm-heartbeat.v1","published_epoch":1794000000}' \
    $'{"schema":"fm-heartbeat.v1","published_epoch":1794000000}\nnull' \
    '{"schema":"fm-heartbeat.v1","published_epoch":1.794e9,"nested":{"published_epoch":1794000000}}' \
    '{"schema":"fm-heartbeat.v1","published_epoch":1794000000,"nested":{"published_epoch":1794000000}}' \
    '{"schema":"fm-heartbeat.v1","published_epoch":1000,"published_epoch":2000}' \
    '{"schema":"fm-heartbeat.v1","published_epoch":1794000000,"published_epoch":1.794e9}' \
    '{"schema":"fm-heartbeat.v1","published_epoch":1794000000,"\u0070ublished_epoch":1.794e9}' \
    '{"schema":"fm-heartbeat.v1","published_epoch":1.794e9,"pub lished_epoch":1794000000}' \
    '{"schema":"fm-heartbeat.v1","published_epoch":1794000000.0,"x\"published_epoch":1794000000}' \
    '1794000000' \
    'not json' \
    ''; do
    printf '%s\n' "$doc" > "$f"
    if out=$(lib fm_wd_heartbeat_published "$f"); then fail "an unread heartbeat was accepted: $doc"; fi
    assert_equals "" "$out" "an unread heartbeat prints nothing: $doc"
  done
  printf '{"schema":"fm-heartbeat.v1","published_epoch":1794000000}\n\0' > "$f"
  if out=$(lib fm_wd_heartbeat_published "$f" 2>/dev/null); then fail "a heartbeat with a NUL byte after the document was accepted"; fi
  assert_equals "" "$out" "a heartbeat with a NUL byte after the document prints nothing"
  # The heartbeat is replaced by rename while a reading is under way: this jq
  # replaces it, as soon as it has read it, with a file that no reading accepts.
  cat > "$d/shim/jq" <<'SH'
#!/usr/bin/env bash
"$REAL_JQ" "$@"
rc=$?
printf 'not json\n' > "$HB.new" && mv "$HB.new" "$HB"
exit "$rc"
SH
  chmod +x "$d/shim/jq"
  printf '{"schema":"fm-heartbeat.v1","published_epoch":1794000000}\n' > "$f"
  out=$(REAL_JQ=$(command -v jq) HB="$f" PATH="$d/shim:$PATH" lib fm_wd_heartbeat_published "$f") \
    || fail "a heartbeat replaced during the reading was not read"
  assert_equals 1794000000 "$out" "a heartbeat replaced during the reading prints the stamp that was read"
  assert_equals "not json" "$(cat "$f")" "the reading under test did see the heartbeat replaced"
  if out=$(lib fm_wd_heartbeat_published "$d/absent.json"); then fail "an absent heartbeat was accepted"; fi
  assert_equals "" "$out" "an absent heartbeat prints nothing"
  if out=$(lib fm_wd_heartbeat_published "$d/dir.json"); then fail "a directory was accepted"; fi
  assert_equals "" "$out" "a directory prints nothing"
  pass "supervisor-gap reading: only the one positive integer published_epoch of one fm-heartbeat.v1 document is read, from one read of the file"
}

test_supervisor_gap_record_follows_published_heartbeat_age() {
  local home obs gap first
  make_home $'Captain session\n> '
  transcript 100 "Working."
  home=$(canon "$H")
  publish "$H" "$BASE"
  run_wd 0 scan >/dev/null 2>&1
  assert_absent "$H/state/night-score/supervisor-gap.tsv" "scan writes no record"
  run_wd 0 once >/dev/null 2>&1
  assert_equals "$BASE"$'\tobserved\t'"$home" "$(gap_rows "$H")" "a fresh heartbeat is one observation row"
  assert_equals $'\t\t\t\n'"$BASE"$'\tobserved\t'"$home" "$(gap_raw "$H")" "the append is a line of three TABs, then the row"
  publish "$H" "$((BASE - 590))"
  run_wd 10 once >/dev/null 2>&1
  assert_equals "$((BASE + 10))"$'\tobserved\t'"$home" "$(gap_rows "$H" | tail -n +2)" "an age of exactly 600 adds one observation row and no gap row"
  publish "$H" "$((BASE - 581))"
  run_wd 20 once >/dev/null 2>&1
  gap="$((BASE + 20))"$'\t'"$home"$'\theartbeat_age=601'
  obs="$((BASE + 20))"$'\tobserved\t'"$home"
  assert_equals "$gap"$'\n'"$obs" "$(gap_rows "$H" | tail -n +3)" "an age of 601 adds the gap row, then the observation row"
  first=$(gap_rows "$H")
  jq -n --argjson pid "$LOCKPID" --argjson deadline "$((BASE + 500))" \
    '{version:1,nonce:"n1",handoff:"data/handoff.md",sha256:"0",predecessor_pid:$pid,predecessor_start:"x",deadline:$deadline}' \
    > "$H/state/.handoff-pending"
  run_wd 20 once >/dev/null 2>&1
  assert_equals "$first" "$(gap_rows "$H" | head -n 4)" "a handoff claim in the home leaves the rows already written unchanged"
  assert_equals "$gap"$'\n'"$obs" "$(gap_rows "$H" | tail -n +5)" "a pass during a handoff claim still appends the gap row"
  rm -f "$H/state/.handoff-pending"
  run_wd 20 once --dry-run >/dev/null 2>&1
  assert_equals "$gap"$'\n'"$obs" "$(gap_rows "$H" | tail -n +7)" "a dry-run pass appends the same rows"
  assert_equals 8 "$(gap_rows "$H" | wc -l | tr -d ' ')" "the record holds the rows of the five passes"
  assert_equals 5 "$(gap_raw "$H" | grep -c "^$(printf '\t\t\t')\$")" "each of the five appends starts with its line of three TABs"
  assert_equals 13 "$(gap_raw "$H" | wc -l | tr -d ' ')" "the record holds those rows and lines and nothing else"
  pass "supervisor-gap record: each action pass appends the reading, a gap row over 600 s, and scan appends nothing"
}

test_supervisor_gap_unread_heartbeat_writes_no_row() {
  local doc saved before
  make_home $'Captain session\n> '
  transcript 100 "Working."
  run_wd 0 once >/dev/null 2>&1
  assert_equals "" "$(gap_raw "$H")" "a heartbeat with no published_epoch writes no row"
  publish "$H" "$((BASE + 1))"
  run_wd 0 once >/dev/null 2>&1
  assert_equals "" "$(gap_raw "$H")" "a heartbeat stamped later than the clock writes no row"
  saved=$(cat "$H/state/heartbeat.json")
  for doc in 0 -5 1794000000.5 '"1794000000"' null; do
    publish "$H" "$doc"
    run_wd 0 once >/dev/null 2>&1
    assert_equals "" "$(gap_raw "$H")" "published_epoch $doc writes no row"
  done
  printf '%s\n' "$saved" | jq --argjson p "$BASE" '.schema = "fm-heartbeat.v2" | .published_epoch = $p' > "$H/state/heartbeat.json"
  run_wd 0 once >/dev/null 2>&1
  assert_equals "" "$(gap_raw "$H")" "another schema writes no row"
  printf 'not json\n' > "$H/state/heartbeat.json"
  run_wd 0 once >/dev/null 2>&1
  assert_equals "" "$(gap_raw "$H")" "a heartbeat that is not JSON writes no row"
  rm -f "$H/state/heartbeat.json"
  run_wd 0 once >/dev/null 2>&1
  assert_equals "" "$(gap_raw "$H")" "an absent heartbeat writes no row"
  printf '%s\n' "$saved" | jq --argjson p "$BASE" '.published_epoch = $p' > "$H/state/heartbeat.real"
  ln -s heartbeat.real "$H/state/heartbeat.json"
  run_wd 0 once >/dev/null 2>&1
  assert_equals "" "$(gap_raw "$H")" "a heartbeat that is a symbolic link to a good file writes no row"
  rm -f "$H/state/heartbeat.json"
  mv "$H/state/heartbeat.real" "$H/state/heartbeat.json"
  run_wd 0 once >/dev/null 2>&1
  assert_equals "$BASE"$'\tobserved\t'"$(canon "$H")" "$(gap_rows "$H")" "the same home is recorded once its heartbeat is read"
  # A clock that does not have 10 digits: the reading is good, and no row is written.
  before=$(gap_raw "$H" | cksum)
  publish "$H" 9999999300
  run_wd "$((10000000000 - BASE))" once >/dev/null 2>&1
  assert_equals "$before" "$(gap_raw "$H" | cksum)" "a clock of 11 digits writes no row"
  publish "$H" 999999300
  run_wd "$((999999999 - BASE))" once >/dev/null 2>&1
  assert_equals "$before" "$(gap_raw "$H" | cksum)" "a clock of 9 digits writes no row"
  pass "supervisor-gap record: a heartbeat that was not read, or a clock that does not have 10 digits, leaves the home with no row"
}

test_supervisor_gap_rows_name_each_watched_home() {
  local parent mate p m
  make_home $'Captain session\n> '
  parent=$H
  transcript 100 "Working."
  make_home $'Mate session\n> '
  mate=$H
  transcript 100 "Working."
  p=$(canon "$parent")
  m=$(canon "$mate")
  publish "$parent" "$BASE"
  publish "$mate" "$((BASE - 700))"
  printf -- '- gap-mate - test mate (home: %s)\n' "$mate" > "$parent/data/secondmates.md"
  H=$parent
  run_wd 0 once >/dev/null 2>&1
  assert_equals "$BASE"$'\tobserved\t'"$p" "$(gap_rows "$parent" | awk -F'\t' -v h="$p" '$2 == h || $3 == h')" "the owner home has its observation row"
  assert_equals "$BASE"$'\t'"$m"$'\theartbeat_age=700\n'"$BASE"$'\tobserved\t'"$m" "$(gap_rows "$parent" | awk -F'\t' -v h="$m" '$2 == h || $3 == h')" \
    "the second mate has its gap row and its observation row in the owner home's record"
  assert_equals 3 "$(gap_rows "$parent" | wc -l | tr -d ' ')" "one unfiltered pass writes the rows of both homes only"
  assert_absent "$mate/state/night-score/supervisor-gap.tsv" "the second mate's own home holds no record"
  run_wd 5 once --home "$mate" >/dev/null 2>&1
  assert_equals "$((BASE + 5))"$'\t'"$m"$'\theartbeat_age=705\n'"$((BASE + 5))"$'\tobserved\t'"$m" "$(gap_rows "$parent" | tail -n +4)" \
    "a pass filtered to the second mate appends the second mate's rows only"
  pass "supervisor-gap record: the owner home's record names each home the pass read, and a filtered pass names one"
}

test_supervisor_gap_torn_line_and_failed_append() {
  local home rec row gaprow earlier err before target
  make_home $'Captain session\n> '
  transcript 100 "Working."
  home=$(canon "$H")
  rec="$H/state/night-score/supervisor-gap.tsv"
  row="$BASE"$'\tobserved\t'"$home"
  publish "$H" "$BASE"
  mkdir -p "$H/state/night-score" "$H/shim"

  # The row rule these cases read the record by: each of these lines is not a row.
  printf '\tobserved\t/h\n794000000\tobserved\t/h\n17940000000\tobserved\t/h\n179400000a\tobserved\t/h\n' > "$rec"
  printf '179400000\302\262\tobserved\t/h\n1794000000\tobserved\t/h\0\n1794000000\tobserved\n' >> "$rec"
  printf '1794000000\tobserved\t/h\tx\n1794000000\tobserved\t/h' >> "$rec"
  assert_equals "" "$(gap_rows "$H")" "an empty, short, long or non-digit first field, a NUL byte, another TAB count and a line with no newline are not rows"
  printf '1794000000\tobserved\t/h\n' > "$rec"
  assert_equals $'1794000000\tobserved\t/h' "$(gap_rows "$H")" "a line of two TABs with a first field of 10 digits is a row"
  printf '%s\tobserved\t/torn/ho' "$((BASE - 120))" > "$rec"
  run_wd 0 once >/dev/null 2>&1
  assert_equals 2 "$(wc -l < "$rec" | tr -d ' ')" "the cut piece is closed and the new row is on its own line"
  [ "$(awk -F'\t' 'NR == 1 { print NF }' "$rec")" -ge 4 ] || fail "the closed piece still reads as a three-field row: $(head -n 1 "$rec")"
  assert_equals "$row" "$(gap_rows "$H")" "the row after a cut piece is whole, and the closed piece is not a row"

  printf '%s\tobserved\t/torn/ho\0' "$((BASE - 120))" > "$rec"
  run_wd 0 once >/dev/null 2>&1
  assert_equals 2 "$(wc -l < "$rec" | tr -d ' ')" "a cut piece that ends in a NUL byte is closed"
  # Counted in bytes: an awk that stops at the NUL would see three fields.
  assert_equals 5 "$(head -n 1 "$rec" | tr -cd '\t' | wc -c | tr -d ' ')" "the closed NUL-ended line holds its two TABs and the three closing TABs"
  assert_equals "$row" "$(tail -n 1 "$rec")" "the row after a NUL-ended piece is whole"

  # Another pass leaves a cut piece after the last moment this pass could look at
  # the record: this cat puts the piece there just before it appends the rows.
  cat > "$H/shim/cat" <<'SH'
#!/usr/bin/env bash
[ "$#" -eq 0 ] || exec "$REAL_CAT" "$@"
data=$("$REAL_CAT"; printf x)
case "$data" in *$'\tobserved\t'*) printf '%s' "$PIECE" >> "$REC" ;; esac
printf '%s' "${data%x}"
SH
  chmod +x "$H/shim/cat"
  earlier="$((BASE - 60))"$'\tobserved\t'"$home"
  printf '%s\n' "$earlier" > "$rec"
  REC="$rec" PIECE="$((BASE - 120))"$'\tobserved\t/torn/ho' REAL_CAT=$(command -v cat) PATH="$H/shim:$PATH" run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(grep -c '/torn/ho' "$rec")" "the pass under test did get a cut piece just before its append"
  assert_equals "$earlier"$'\n'"$row" "$(gap_rows "$H")" "a piece that lands just before the append is closed and joins no row"
  assert_equals 3 "$(wc -l < "$rec" | tr -d ' ')" "the record holds the earlier row, the closed piece and the new row"

  # The same, for a piece with no TAB and a reading that is a gap: the piece is
  # closed, so it does not join the gap row, and both rows are rows.
  publish "$H" "$((BASE - 700))"
  gaprow="$BASE"$'\t'"$home"$'\theartbeat_age=700'
  printf '%s\n' "$earlier" > "$rec"
  REC="$rec" PIECE=1794 REAL_CAT=$(command -v cat) PATH="$H/shim:$PATH" run_wd 0 once >/dev/null 2>&1
  assert_equals $'1794\t\t\t' "$(sed -n 2p "$rec")" "the pass under test did get a piece with no TAB just before its append, and closed it"
  assert_equals "$earlier"$'\n'"$gaprow"$'\n'"$row" "$(gap_rows "$H")" "a piece with no TAB joins no row: the gap row and the observation row are whole"
  publish "$H" "$BASE"

  if [ "$(id -u)" != 0 ]; then
    printf '%s\tobserved\t/torn/ho' "$((BASE - 120))" > "$rec"
    chmod 200 "$rec"
    run_wd 0 once >/dev/null 2>&1
    chmod 644 "$rec"
    assert_equals 2 "$(wc -l < "$rec" | tr -d ' ')" "a record that cannot be read still has its cut piece closed"
    assert_equals "$row" "$(gap_rows "$H")" "the row appended to a record that cannot be read is whole"

    printf '%s\tobserved\t/torn/ho' "$((BASE - 120))" > "$rec"
    chmod 444 "$rec"
    before=$(cksum < "$rec")
    rm -f "$H/data/watchdog/status.md"
    err=$(run_wd 0 once 2>&1 >/dev/null) || fail "a record that cannot be written fails the pass: $err"
    assert_equals "$before" "$(cksum < "$rec")" "a record that cannot be written keeps its bytes: no closing line and no row"
    gap_report "the append to a read-only record" "$err"
    chmod 644 "$rec"
  else
    printf '# not run here: root can write any file, so the record that cannot be read and the read-only record are not checked\n'
  fi

  rm -rf "$H/state/night-score"
  mkdir -p "$H/state/night-score/supervisor-gap.tsv"
  rm -f "$H/data/watchdog/status.md"
  err=$(run_wd 0 once 2>&1 >/dev/null) || fail "a directory in place of the record fails the pass: $err"
  assert_equals "" "$(find "$rec" -mindepth 1)" "nothing is appended when a directory stands in place of the record"
  gap_report "the append to a directory" "$err"

  rm -rf "$H/state/night-score"
  : > "$H/state/night-score"
  before=$(ledger)
  rm -f "$H/data/watchdog/status.md"
  err=$(run_wd 0 once 2>&1 >/dev/null) || fail "a record that cannot be appended fails the pass: $err"
  [ -f "$H/state/night-score" ] && [ ! -s "$H/state/night-score" ] || fail "a row was written although the record cannot be appended"
  gap_report "the append with no record directory" "$err"
  assert_equals "$before" "$(ledger)" "the failed append takes no action"

  # A write that fails after the record opened, where the system has a full device.
  if [ -c /dev/full ]; then
    rm -f "$H/state/night-score"
    mkdir -p "$H/state/night-score"
    ln -s /dev/full "$rec"
    rm -f "$H/data/watchdog/status.md"
    err=$(run_wd 0 once 2>&1 >/dev/null) || fail "a record on a full device fails the pass: $err"
    gap_report "the write to a full device" "$err"
  else
    printf '# not run here: this system has no /dev/full, so the write to a full device is checked on Linux only\n'
  fi

  # A write that fails after it started: the record is filled so that a file-size
  # limit of 1 MiB leaves room for the line of three TABs, the gap row and 5 bytes
  # of the observation row. Linux cuts the append there. A system that lets the
  # append land whole has no failed write to check.
  rm -rf "$H/state/night-score"
  mkdir -p "$H/state/night-score"
  publish "$H" "$((BASE - 700))"
  gaprow="$BASE"$'\t'"$home"$'\theartbeat_age=700'
  target=$((1048576 - 4 - $(printf '%s' "$gaprow" | wc -c | tr -d ' ') - 1 - 5))
  awk -v n="$target" 'BEGIN {
    for (i = 0; i < int(n / 16); i++) print "padding-line\t\t\t"
    r = n % 16
    if (r) { s = ""; for (i = 1; i < r; i++) s = s "x"; print s }
  }' > "$rec"
  assert_equals "$target" "$(wc -c < "$rec" | tr -d ' ')" "the record is filled to the size the cut needs"
  rm -f "$H/data/watchdog/status.md"
  err=$( (trap '' XFSZ; ulimit -f 1024; run_wd 0 once) 2>&1 >/dev/null) || fail "a write cut short by a size limit fails the pass: $err"
  if [ "$(tail -n 1 "$rec")" != "$row" ]; then
    gap_report "the write cut short by a size limit" "$err"
    assert_no_grep "$(printf '\tobserved\t')" "$H/data/watchdog/status.md" "the row of a failed write does not go to the status file"
    assert_equals "$gaprow" "$(gap_rows "$H")" "a write cut short leaves the gap row whole and no observation row"
    run_wd 5 once >/dev/null 2>&1
    assert_equals "$gaprow"$'\n'"$((BASE + 5))"$'\t'"$home"$'\theartbeat_age=705\n'"$((BASE + 5))"$'\tobserved\t'"$home" "$(gap_rows "$H")" \
      "after a write cut short, the next pass closes the piece it left and appends whole rows"
  elif [ "$(uname -s)" = Linux ]; then
    fail "the size-limited append landed whole on Linux, so the write that fails after it started was not checked"
  else
    printf '# not run here: the size-limited append landed whole, so the write that fails after it started is checked on Linux only\n'
  fi

  # The pass cannot create its work files: it fails before it reads a home.
  before=$(cksum < "$rec")
  rm -rf "$H/state/watchdog"
  : > "$H/state/watchdog"
  if run_wd 0 once >/dev/null 2>&1; then fail "a pass that cannot create its work files did not fail"; fi
  assert_equals "$before" "$(cksum < "$rec")" "a pass that cannot create its work files appends nothing"
  rm -f "$H/state/watchdog"
  pass "supervisor-gap record: a cut piece never joins a row, and a failed append is reported and does not fail the pass"
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

# fake_memory_tools <swap-used>|fail: a sysctl fake for the memory guard's
# macOS reader; fail exits 1. The guard reads the real process table.
fake_memory_tools() {
  if [ "$1" = fail ]; then
    printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/sysctl"
  else
    printf '#!/usr/bin/env bash\nprintf "total = 9.00M  used = %s  free = 1.00M  (encrypted)\\n"\n' "$1" > "$FAKEBIN/sysctl"
  fi
  chmod +x "$FAKEBIN/sysctl"
}

test_memory_guard_samples_once_per_pass() {
  make_home $'Captain session\n> ' 'memory-guard=on'
  printf 'swap_warn_mb=5\nproc_rss_mb=999999999\nmode=reap-scratch\n' > "$H/config/memory-guard"
  fake_memory_tools 7.00M
  FM_MEMORY_GUARD_OS=Darwin run_wd 0 once >/dev/null 2>&1 || fail "a pass with a memory alarm failed"
  assert_equals 1 "$(wc -l < "$H/state/memory-guard.tsv" | tr -d ' ')" "one memory sample per pass"
  assert_equals "$BASE	7" "$(cut -f 1-2 "$H/state/memory-guard.tsv")" "the sample uses the watchdog clock"
  assert_grep "- host: memory alarm swap_used_mb=7 " "$H/data/watchdog/status.md" "an alarm in force is an open gap"
  assert_grep "- host: swap used 7 MB is at or over 5 MB" "$H/data/watchdog/status.md" "the new alarm line is an open gap"
  assert_grep "mode=reap-scratch" "$H/data/watchdog/status.md" "an acting watchdog keeps the configured reap-scratch mode"
  FM_MEMORY_GUARD_OS=Darwin run_wd 120 once --dry-run >/dev/null 2>&1 || fail "a second pass failed"
  assert_equals 2 "$(wc -l < "$H/state/memory-guard.tsv" | tr -d ' ')" "the next pass adds one more sample"
  assert_grep "- host: memory alarm" "$H/data/watchdog/status.md" "a deduplicated alarm stays an open gap"
  assert_no_grep "- host: swap used" "$H/data/watchdog/status.md" "a deduplicated alarm line is not repeated"
  assert_grep "mode=observe" "$H/data/watchdog/status.md" "a dry-run watchdog forces observe mode"
  rm -f "$H/state/memory-guard.tsv"
  mkdir "$H/state/memory-guard.tsv"
  # With no alarm in force, a sample that cannot be recorded is a failure.
  printf 'swap_warn_mb=999999\nproc_rss_mb=999999999\n' > "$H/config/memory-guard"
  FM_MEMORY_GUARD_OS=Darwin run_wd 240 once >/dev/null 2>&1 || fail "a failed memory sample stopped the pass"
  assert_grep "- host: memory guard sample failed (exit 1)" "$H/data/watchdog/status.md" "a failed sample is a gap"
  assert_grep "## Homes" "$H/data/watchdog/status.md" "the pass still writes the status file"
  rmdir "$H/state/memory-guard.tsv"
  printf 'memory-guard=off\n' >> "$H/config/watchdog"
  FM_MEMORY_GUARD_OS=Darwin run_wd 360 once >/dev/null 2>&1
  assert_absent "$H/state/memory-guard.tsv" "memory-guard=off takes no sample"
  rm -f "$FAKEBIN/sysctl"
  pass "the watchdog samples host memory once per pass and never stops on a failed sample"
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

# A credential stop on an approval picker can show a value that the secret
# detector does not recognize, so its away page records no pane text at all.
test_worker_credential_page_withholds_typed_values() {
  local cookie=$'Bash command\n\n  curl -H "Cookie: session=rvw7731cookie" https://api.example.com/me\n  Fetch the profile\n\nDo you want to proceed?\n ❯ 1. Yes\n   2. No, and tell Claude what to do differently\n\nEsc to cancel'
  local mode key
  for mode in act dry-run locked; do
    if [ "$mode" = dry-run ]; then make_home $'Captain session\n> ' 'mode=dry-run'; else make_home $'Captain session\n> '; fi
    transcript 100 "Working."
    worker_pane cookie ship "$cookie"
    if [ "$mode" = locked ]; then
      # Another pass holds the worker's lock, so this pass writes no marker.
      key="$(basename "$H")-$(printf '%s' "$H" | cksum | cut -d ' ' -f 1)"
      mkdir -p "$H/state/watchdog/permission/$key-cookie.lock"
      printf '%s\n' "$$" > "$H/state/watchdog/permission/$key-cookie.lock/pid"
    fi
    sleep 0.5
    printf '%s\n' "$LOCKPID" > "$H/state/.supervise-daemon.pid"
    printf "command:cat >> '%s'\n" "$H/paged.log" > "$H/config/wedge-alarm"
    : > "$H/state/.afk"
    run_wd 0 once >/dev/null 2>&1 || fail "the $mode away pass failed"
    if [ "$mode" = locked ]; then
      assert_equals 1 "$(grep -c 'another watchdog pass is acting on worker cookie' "$H/state/watchdog/actions.tsv")" "the busy lock is recorded: $(ledger | cut -f4-8)"
    fi
    if [ "$mode" != dry-run ]; then
      assert_equals 1 "$(ledger_rows dialog page pending)" "the credential stop pages the owner: $(ledger | cut -f4-8)"
    else
      assert_equals 1 "$(ledger_rows dialog page dry-run)" "dry-run records the page it would send: $(ledger | cut -f4-8)"
    fi
    assert_no_grep "rvw7731cookie" "$H/state/watchdog/actions.tsv" "a session cookie in a credential picker stays out of the $mode ledger"
    assert_equals 1 "$(grep -c 'withheld: a credential or sign-in prompt' "$H/state/watchdog/actions.tsv")" "the $mode ledger names the withheld prompt"
    if [ -e "$H/paged.log" ]; then
      assert_no_grep "rvw7731cookie" "$H/paged.log" "the page carries no session cookie"
    fi
  done
  pass "a credential stop on an approval picker pages the owner without recording its pane text, even while another pass holds the worker lock"
}

test_away_bash_prompt_row_keeps_the_command() {
  local out
  make_home "$(cat "$ROOT/tests/fixtures/permission-prompt/claude-2.1.325-bash-prompt.txt")"
  transcript 100 "Working."
  printf '%s\n' "$LOCKPID" > "$H/state/.supervise-daemon.pid"
  printf "command:cat >> '%s'\n" "$H/paged.log" > "$H/config/wedge-alarm"
  : > "$H/state/.afk"
  run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows dialog page pending)" "the real Bash prompt pages the owner: $(ledger | cut -f5-8)"
  out=$(FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_CONFIG_OVERRIDE="$H/config" "$ROOT/bin/fm-afk-preallow.sh" derive) \
    || fail "derive on the recorded row failed: $out"
  assert_contains "$out" "entries=1 excluded=0" "the recorded row of a real Bash prompt gives one entry: $out"
  assert_equals "Bash(touch /tmp/probe/fm-perm-probe2.txt)" "$(cat "$H/state/afk-preallow/candidate.list")" \
    "the entry is the exact command shown in the prompt"
  pass "an away Bash prompt with a pane-wide rule records its whole command for the pre-allow list"
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

test_quota_guard_checks_at_kickoff_and_periodically() {
  local snap
  make_home $'Captain session\n> '
  # The guard runs by default, so this home carries no quota-guard key at all.
  grep -v '^quota-guard=' "$H/config/watchdog" > "$H/watchdog.conf" && mv "$H/watchdog.conf" "$H/config/watchdog"
  snap="$H/quota.json"
  wd_quota_snapshot "$snap"
  : > "$H/quota-axi.calls"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$H/quota-axi.calls"
cat "$snap"
SH
  chmod +x "$FAKEBIN/quota-axi"
  transcript 100 "Working."
  run_wd 0 once >/dev/null 2>&1 || fail "quota guard kickoff pass failed"
  assert_equals 1 "$(ledger_rows quota-guard check "done")" "the first pass is a kickoff check: $(ledger | cut -f4-8)"
  assert_grep "trigger=kickoff" "$H/state/quota-guard/last" "the kickoff check is on record"
  assert_grep "quota-guard: unknown trigger=kickoff" "$H/data/watchdog/status.md" \
    "a check that is not ok stays a gap"
  run_wd 60 once >/dev/null 2>&1 || fail "quota guard quiet pass failed"
  assert_equals 1 "$(ledger_rows quota-guard check "done")" "no check is due inside the period"
  assert_grep "quota-guard: unknown trigger=kickoff" "$H/data/watchdog/status.md" \
    "the last check's verdict stays a gap while it is not ok"
  run_wd 7300 once >/dev/null 2>&1 || fail "quota guard periodic pass failed"
  assert_equals 2 "$(ledger_rows quota-guard check "done")" "a check runs again after two hours"
  assert_grep "trigger=periodic" "$H/state/quota-guard/last" "the periodic check is on record"
  assert_no_grep "allow-keychain-prompt" "$H/quota-axi.calls" "the guard never opens a sign-in prompt"
  [ ! -s "$H/typed.log" ] || fail "an unknown verdict typed into the pane: $(cat "$H/typed.log")"
  rm -f "$FAKEBIN/quota-axi"
  pass "quota guard: by default the watchdog checks at kickoff and every two hours"
}

test_quota_guard_nudge_names_each_move_with_a_quoted_home() {
  local home="$TMP_ROOT/owner home" out cmd
  mkdir -p "$home"
  out=$(FM_HOME="$home" bash -c '. "$1"; O_HOME=$2; wd_quota_guard_nudge_text "$3"' _ "$WD" "$home" \
    "quota-guard: act trigger=kickoff window=3600s pools=2 ok=0 unknown=0 short=1 exhausted=1 steer=1 failover=2") ||
    fail "the nudge text could not be built: $out"
  assert_contains "$out" "Move each steered worker with bin/fm-control.sh relaunch on its named pick." \
    "a check with a steered worker names the worker relaunch"
  assert_contains "$out" "run bin/fm-supervisor-failover.sh primary <handoff-file> --reason quota_guard in the background" \
    "a check with a supervisor failover names the primary's command"
  cmd=${out#*for a second mate, run }
  cmd=${cmd%% --reason quota_guard.*}
  assert_equals "FM_HOME=$(printf '%q' "$home") bin/fm-supervisor-failover.sh secondmate <id>" "$cmd" \
    "the second mate command quotes the owning home"
  assert_contains "$out" "Never change an account pin, sign in, or spend." "the nudge keeps its limits"
  pass "quota guard: the nudge names each move, and the second mate command quotes its home"
}
test_quota_guard_act_nudges_after_any_check() {
  local snap root
  make_home $'Captain session\n> '
  grep -v '^quota-guard=' "$H/config/watchdog" > "$H/watchdog.conf" && mv "$H/watchdog.conf" "$H/config/watchdog"
  transcript 100 "Working."
  # The lock holder here is not a harness process, so each pass names it. The
  # primary's transcript lives under $H/claude, so its account is that root, not
  # the ordinary ~/.claude; only that lane is exhausted.
  root="$H/claude"
  snap="$H/claude-quota.json"
  jq -n --arg r "$root" '{schemaVersion: 6, providers: [{provider: "claude", accountKey: "acct", accountLocator: {path: $r},
    state: {status: "fresh", stale: false},
    quotaSemantics: {status: "known", effectiveAvailability: [{scope: "all_models", status: "known", effectivePercentRemaining: 0, runway: {status: "exhausted_now"}}]}}]}' > "$snap"
  wd_quota_snapshot "$H/quota.json"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" --provider claude "*) cat "$snap" ;;
  *) cat "$H/quota.json" ;;
esac
SH
  chmod +x "$FAKEBIN/quota-axi"
  FM_SESSION_LOCK_OWNER_HARNESS=claude run_wd 0 once >/dev/null 2>&1 || fail "quota guard kickoff pass failed"
  assert_grep "pool: claude:$root status=exhausted runway=0 supervisors=primary" "$H/state/quota-guard/report.txt" \
    "the primary is judged on the account that holds its transcript: $(cat "$H/state/quota-guard/report.txt" 2>&1)"
  assert_equals 1 "$(ledger_rows quota-guard nudge pending)" "an act check nudges the primary: $(ledger | cut -f4-8)"
  grep -rqs "quota-guard: act trigger=kickoff" "$H/state/operational-inbox" || fail "the act nudge does not name the kickoff check"
  grep -rqsF "run bin/fm-supervisor-failover.sh primary <handoff-file> --reason quota_guard in the background" "$H/state/operational-inbox" ||
    fail "a supervisor failover nudge does not name the failover command: $(cat "$H"/state/operational-inbox/* 2>&1)"
  ! grep -rqsF "fm-control.sh relaunch" "$H/state/operational-inbox" ||
    fail "a nudge with no worker move names the worker relaunch: $(cat "$H"/state/operational-inbox/* 2>&1)"
  FM_SESSION_LOCK_OWNER_HARNESS=claude run_wd 1000 once >/dev/null 2>&1 || fail "quota guard quiet pass failed"
  assert_equals 1 "$(ledger_rows quota-guard nudge pending)" "a check already nudged is not nudged again: $(ledger | cut -f4-8)"
  # A limit warning runs its own check between passes; the next pass nudges it
  # even though no periodic check is due.
  FM_HOME="$H" FM_TEST_SEAM=1 FM_NOW=$((BASE + 1100)) FM_QUOTA_GUARD_CONF="$H/config/watchdog" "$ROOT/bin/fm-quota-guard.sh" \
    warning --subject primary --harness claude --primary-harness claude --primary-account "$root" >/dev/null 2>&1
  assert_grep "trigger=warning" "$H/state/quota-guard/last" "the warning check is on record"
  FM_SESSION_LOCK_OWNER_HARNESS=claude run_wd 2000 once >/dev/null 2>&1 || fail "quota guard pass after a warning failed"
  assert_equals 1 "$(ledger_rows quota-guard check "done")" "the pass runs no check of its own after the warning check: $(ledger | cut -f4-8)"
  assert_equals 2 "$(ledger_rows quota-guard nudge pending)" "a warning's act check nudges on the next pass: $(ledger | cut -f4-8)"
  grep -rqs "quota-guard: act trigger=warning" "$H/state/operational-inbox" || fail "the second nudge does not name the warning check"
  rm -f "$FAKEBIN/quota-axi"
  pass "quota guard: every act check nudges the primary once, whichever path ran it"
}

test_quota_guard_act_never_nudges_a_human_step_pane() {
  local snap root
  make_home $'API Error: 401 · Please run /login\n❯ \n  ? for shortcuts'
  grep -v '^quota-guard=' "$H/config/watchdog" > "$H/watchdog.conf" && mv "$H/watchdog.conf" "$H/config/watchdog"
  transcript 100 "Working."
  root="$H/claude"
  snap="$H/claude-quota.json"
  jq -n --arg r "$root" '{schemaVersion: 6, providers: [{provider: "claude", accountKey: "acct", accountLocator: {path: $r},
    state: {status: "fresh", stale: false},
    quotaSemantics: {status: "known", effectiveAvailability: [{scope: "all_models", status: "known", effectivePercentRemaining: 0, runway: {status: "exhausted_now"}}]}}]}' > "$snap"
  wd_quota_snapshot "$H/quota.json"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" --provider claude "*) cat "$snap" ;;
  *) cat "$H/quota.json" ;;
esac
SH
  chmod +x "$FAKEBIN/quota-axi"
  FM_SESSION_LOCK_OWNER_HARNESS=claude run_wd 0 once >/dev/null 2>&1 || fail "quota guard pass failed"
  assert_equals 1 "$(ledger_rows quota-guard check "done")" "the quota check still runs: $(ledger | cut -f4-8)"
  assert_equals "act" "$(sed -n 's/^verdict=//p' "$H/state/quota-guard/last")" "the check names moves"
  assert_equals 0 "$(ledger | awk -F'\t' '$5 == "quota-guard" && $6 == "nudge"' | wc -l | tr -d ' ')" \
    "an act check never nudges a pane showing a human-only step: $(ledger | cut -f4-8)"
  if grep -rqsF "quota-guard: act" "$H/state/operational-inbox"; then
    fail "a quota nudge reached a pane showing a human-only step: $(cat "$H"/state/operational-inbox/* 2>&1)"
  fi
  [ ! -s "$H/typed.log" ] || fail "something was typed into a human-only step: $(cat "$H/typed.log")"
  rm -f "$FAKEBIN/quota-axi"
  pass "quota guard: an act check never nudges a pane showing a human-only step"
}

# quota_guard_exhausted_root <root>: a fake quota-axi on which only the Claude
# account at <root> is exhausted.
quota_guard_exhausted_root() {
  local root=$1 snap="$H/claude-quota.json"
  jq -n --arg r "$root" '{schemaVersion: 6, providers: [{provider: "claude", accountKey: "acct", accountLocator: {path: $r},
    state: {status: "fresh", stale: false},
    quotaSemantics: {status: "known", effectiveAvailability: [{scope: "all_models", status: "known", effectivePercentRemaining: 0, runway: {status: "exhausted_now"}}]}}]}' > "$snap"
  wd_quota_snapshot "$H/quota.json"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" --provider claude "*) cat "$snap" ;;
  *) cat "$H/quota.json" ;;
esac
SH
  chmod +x "$FAKEBIN/quota-axi"
}

test_quota_guard_nudge_retries_a_failed_send_and_skips_a_dead_primary() {
  make_home $'Captain session\n> '
  grep -v '^quota-guard=' "$H/config/watchdog" > "$H/watchdog.conf" && mv "$H/watchdog.conf" "$H/config/watchdog"
  transcript 100 "Working."
  quota_guard_exhausted_root "$H/claude"
  # A file where the inbox directory goes makes the nudge's record fail.
  printf 'x\n' > "$H/state/operational-inbox"
  FM_SESSION_LOCK_OWNER_HARNESS=claude run_wd 0 once >/dev/null 2>&1 || fail "failing-nudge pass failed"
  assert_equals 1 "$(ledger_rows quota-guard nudge failed)" "the nudge whose record failed is a failed row: $(ledger | cut -f4-8)"
  rm -f "$H/state/operational-inbox"
  FM_SESSION_LOCK_OWNER_HARNESS=claude run_wd 1000 once >/dev/null 2>&1 || fail "retry pass failed"
  assert_equals 2 "$(ledger_rows quota-guard nudge pending)" "a nudge that never reached the primary is sent again: $(ledger | cut -f4-8)"
  grep -rqs "quota-guard: act trigger=kickoff" "$H/state/operational-inbox" || fail "the retried nudge does not name the kickoff check"
  FM_HOME="$H" FM_TEST_SEAM=1 FM_NOW=$((BASE + 1100)) FM_QUOTA_GUARD_CONF="$H/config/watchdog" "$ROOT/bin/fm-quota-guard.sh" \
    warning --subject primary --harness claude --primary-harness claude --primary-account "$H/claude" >/dev/null 2>&1
  assert_grep "trigger=warning" "$H/state/quota-guard/last" "the warning check is on record"
  kill "$LOCKPID" 2>/dev/null
  sleep 0.5
  ! kill -0 "$LOCKPID" 2>/dev/null || fail "the lock holder is still alive"
  FM_SESSION_LOCK_OWNER_HARNESS=claude run_wd 2000 once >/dev/null 2>&1 || fail "dead-primary pass failed"
  assert_equals 2 "$(ledger_rows quota-guard nudge pending)" "a primary whose lock holder is dead is not nudged: $(ledger | cut -f4-8)"
  # Only the earlier nudge's progress check may land now; no new nudge starts.
  assert_equals 0 "$(ledger | awk -F'\t' '$5 == "quota-guard" && $6 == "nudge" && $7 != "failed" && $1 >= '"$((BASE + 2000))" | wc -l | tr -d ' ')" \
    "no nudge of any phase starts for a dead primary: $(ledger | cut -f4-8)"
  rm -f "$FAKEBIN/quota-axi"
  pass "quota guard: a nudge that failed is sent again, and a dead primary is never nudged"
}

test_quota_guard_nudge_skips_a_holder_that_died_during_the_check() {
  make_home $'Captain session\n> '
  grep -v '^quota-guard=' "$H/config/watchdog" > "$H/watchdog.conf" && mv "$H/watchdog.conf" "$H/config/watchdog"
  transcript 100 "Working."
  quota_guard_exhausted_root "$H/claude"
  # The Claude read comes after the guard judged the primary live, so the
  # holder dies while the check is still running.
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" --provider claude "*)
    kill "$LOCKPID" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do kill -0 "$LOCKPID" 2>/dev/null || break; sleep 0.1; done
    cat "$H/claude-quota.json" ;;
  *) cat "$H/quota.json" ;;
esac
SH
  chmod +x "$FAKEBIN/quota-axi"
  FM_SESSION_LOCK_OWNER_HARNESS=claude run_wd 0 once >/dev/null 2>&1 || fail "quota guard kickoff pass failed"
  assert_grep "quota-guard: act trigger=kickoff" "$H/state/quota-guard/report.txt" \
    "the check judged the primary while it was live: $(cat "$H/state/quota-guard/report.txt" 2>&1)"
  assert_equals 0 "$(ledger | awk -F'\t' '$5 == "quota-guard" && $6 == "nudge"' | wc -l | tr -d ' ')" \
    "a holder that died during the check is not nudged: $(ledger | cut -f4-8)"
  rm -f "$FAKEBIN/quota-axi"
  pass "quota guard: a primary whose holder died during the check gets no nudge"
}

test_autowait_footers_on_a_mate_and_a_worker_are_limit_warnings() {
  local parent mate autowait
  autowait=$'work output\nUsage limit reached. Continuing automatically at 4:00 AM\n❯ \n  ? for shortcuts'
  make_home $'Captain session\n> '
  parent=$H
  grep -v '^quota-guard=' "$parent/config/watchdog" > "$parent/watchdog.conf" && mv "$parent/watchdog.conf" "$parent/config/watchdog"
  transcript 100 "Working."
  make_home "$autowait"
  mate=$H
  transcript 100 "Working."
  # Input that has waited long enough would draw an unread-input nudge, and an
  # away record with a dead daemon would draw a daemon-dead side check.
  owe_input 1000
  : > "$mate/state/.afk"
  printf '999999\n' > "$mate/state/.supervise-daemon.pid"
  H=$parent
  printf -- '- ghost-mate - test mate (home: %s)\n' "$mate" > "$parent/data/secondmates.md"
  {
    echo "harness=claude"
    echo "kind=secondmate"
    echo "home=$mate"
    echo "worktree=$mate"
    echo "model=default"
  } > "$parent/state/ghost-mate.meta"
  mkdir -p "$parent/wt"
  worker_pane waiter ship "$autowait"
  printf 'harness=claude\nworktree=%s\nmodel=default\n' "$parent/wt" >> "$parent/state/waiter.meta"
  # Only the account that holds the primary's transcript is exhausted.
  quota_guard_exhausted_root "$parent/claude"
  sleep 0.5
  FM_SESSION_LOCK_OWNER_HARNESS=claude run_wd 0 once >/dev/null 2>&1 || fail "auto-wait footer pass failed"
  assert_grep "	ghost-mate	ordinary	default	claude" "$parent/state/quota-limit-dialogs.tsv" \
    "a second mate's auto-wait footer is recorded as a limit dialog in its parent: $(cat "$parent/state/quota-limit-dialogs.tsv" 2>&1)"
  assert_grep "	waiter	ordinary	default	claude" "$parent/state/quota-limit-dialogs.tsv" \
    "a worker's auto-wait footer is recorded as a limit dialog"
  assert_grep "trigger=warning" "$parent/state/quota-guard/last" "the second mate's warning checks quota"
  assert_grep "pool: claude:$parent/claude status=exhausted runway=0 supervisors=primary" "$parent/state/quota-guard/report.txt" \
    "the second mate's check judges the primary on its own account: $(cat "$parent/state/quota-guard/report.txt" 2>&1)"
  [ ! -s "$mate/typed.log" ] || fail "the watchdog typed into the second mate's auto-wait pane: $(cat "$mate/typed.log")"
  assert_equals 0 "$(ledger | awk -F'\t' -v m="$(basename "$mate")" '$4 == m && $6 == "nudge"' | wc -l | tr -d ' ')" \
    "a second mate on the auto-wait gets no nudge: $(ledger | cut -f4-8)"
  [ ! -s "$parent/worker-waiter.typed" ] || fail "the watchdog typed into the worker's auto-wait pane: $(cat "$parent/worker-waiter.typed")"
  rm -f "$FAKEBIN/quota-axi"
  pass "quota guard: an auto-wait footer on a second mate or a worker is a limit warning judged on the primary's account"
}
test_failed_limit_dialog_record_is_retried() {
  local snap dialog
  dialog=$'You have hit your weekly limit for Opus.\n\n ❯ 1. Switch to Sonnet\n   2. Wait for the limit to reset\n   3. Buy more credits\n\nEnter to confirm · Esc to cancel'
  make_home $'Captain session\n> ' 'reroute-candidates=codex:gpt-5.4'
  mkdir -p "$H/wt" "$H/user/.claude"
  worker_pane limit ship "$dialog"
  printf 'harness=claude\nworktree=%s\nmodel=default\n' "$H/wt" >> "$H/state/limit.meta"
  snap="$H/quota.json"
  wd_quota_snapshot "$snap"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
cat "$snap"
SH
  chmod +x "$FAKEBIN/quota-axi"
  transcript 100 "Working."
  sleep 0.5
  # A directory where the record file goes makes the append fail.
  mkdir -p "$H/state/quota-limit-dialogs.tsv"
  HOME="$H/user" run_wd 0 once >/dev/null 2>&1 || fail "failing-record pass failed"
  assert_equals 1 "$(ledger_rows quota-guard warning failed)" "a dialog that cannot be recorded is a failed row: $(ledger | cut -f4-8)"
  assert_grep "limit dialog on limit not recorded" "$H/data/watchdog/status.md" "a failed record is a gap"
  rmdir "$H/state/quota-limit-dialogs.tsv"
  HOME="$H/user" run_wd 1 once >/dev/null 2>&1 || fail "retry pass failed"
  assert_equals 1 "$(ledger_rows quota-guard warning "done")" "a failed record is tried again on the next pass: $(ledger | cut -f4-8)"
  assert_grep "	limit	ordinary	default	claude" "$H/state/quota-limit-dialogs.tsv" "the retried dialog is recorded"
  HOME="$H/user" run_wd 2 once >/dev/null 2>&1 || fail "rate-limited pass failed"
  assert_equals 1 "$(wc -l < "$H/state/quota-limit-dialogs.tsv" | tr -d ' ')" "a recorded dialog waits nudge-secs"
  rm -f "$FAKEBIN/quota-axi"
  pass "quota guard: a limit dialog that failed to record is tried again on the next pass"
}
test_failed_warning_check_records_the_dialog_once() {
  local snap dialog
  dialog=$'You have hit your weekly limit for Opus.\n\n ❯ 1. Switch to Sonnet\n   2. Wait for the limit to reset\n   3. Buy more credits\n\nEnter to confirm · Esc to cancel'
  make_home $'Captain session\n> ' 'reroute-candidates=codex:gpt-5.4'
  grep -v '^quota-guard=' "$H/config/watchdog" > "$H/watchdog.conf" && mv "$H/watchdog.conf" "$H/config/watchdog"
  mkdir -p "$H/wt" "$H/user/.claude"
  worker_pane limit ship "$dialog"
  printf 'harness=claude\nworktree=%s\nmodel=default\n' "$H/wt" >> "$H/state/limit.meta"
  snap="$H/quota.json"
  wd_quota_snapshot "$snap"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
cat "$snap"
SH
  chmod +x "$FAKEBIN/quota-axi"
  transcript 100 "Working."
  sleep 0.5
  # A file where the guard's state directory goes makes every check fail.
  printf 'x\n' > "$H/state/quota-guard"
  HOME="$H/user" run_wd 0 once >/dev/null 2>&1 || fail "failing-check pass failed"
  assert_equals 1 "$(ledger_rows quota-guard warning "done")" "a recorded dialog is done even when its check fails: $(ledger | cut -f4-8)"
  assert_equals 0 "$(ledger_rows quota-guard warning failed)" "a failed check after the record is no failed record: $(ledger | cut -f4-8)"
  assert_grep "quota guard check after the limit dialog on limit failed" "$H/data/watchdog/status.md" "the failed check is a gap"
  assert_equals 0 "$(ledger_rows quota-guard check "done")" "a check that could not save its result is no done check: $(ledger | cut -f4-8)"
  assert_grep "quota guard check failed (exit 1)" "$H/data/watchdog/status.md" "the pass's failed check is a gap"
  HOME="$H/user" run_wd 1 once >/dev/null 2>&1 || fail "second failing-check pass failed"
  assert_equals 1 "$(wc -l < "$H/state/quota-limit-dialogs.tsv" | tr -d ' ')" "a failing check never records the dialog again"
  rm -f "$FAKEBIN/quota-axi" "$H/state/quota-guard"
  pass "quota guard: a limit warning whose check fails records its dialog once"
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
  assert_grep "	limit	ordinary	default	claude" "$H/state/quota-limit-dialogs.tsv" \
    "a worker's limit dialog is recorded with its account and model"
  assert_grep "	limit2	ordinary	default	claude" "$H/state/quota-limit-dialogs.tsv" \
    "each worker's limit dialog is recorded"
  HOME="$H/user" run_wd 1 once >/dev/null 2>&1 || fail "rate-limited worker usage-limit pass failed"
  assert_equals 2 "$(wc -l < "$H/state/quota-limit-dialogs.tsv" | tr -d ' ')" "a dialog is recorded once per nudge-secs"
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

# shellcheck disable=SC2016
test_feedback_claim_recovery_serializes_contenders() {
  local dir claim dead_pid pid_a pid_b rc_a rc_b
  dir=$(fm_test_tmproot feedback-recovery)
  claim="$dir/claim"
  FM_STATE_OVERRIDE="$dir/state" "$BASH" -c '. "$1/bin/fm-control-lib.sh"; printf "%s\n" "$$" > "$2/dead-pid"; fm_control_acquire_feedback_claim "$2/claim"' _ "$ROOT" "$dir" &
  dead_pid=$!
  wait "$dead_pid" || fail "the initial owner could not acquire the claim"
  dead_pid=$(cat "$dir/dead-pid")
  cat > "$dir/contender.sh" <<'SH'
#!/usr/bin/env bash
set -u
root=$1 dir=$2 who=$3 dead_pid=$4
. "$root/bin/fm-control-lib.sh"
kill() {
  if [ "${1:-}" = -0 ] && [ "${2:-}" = "$dead_pid" ]; then
    : > "$dir/$who.observed"
    local n=0
    if [ "$who" = a ]; then
      while [ ! -f "$dir/b.observed" ] && [ "$n" -lt 100 ]; do sleep 0.02; n=$((n + 1)); done
    else
      while [ ! -f "$dir/a.acquired" ] && [ "$n" -lt 100 ]; do sleep 0.02; n=$((n + 1)); done
    fi
    return 1
  fi
  builtin kill "$@"
}
if fm_control_acquire_feedback_claim "$dir/claim"; then
  : > "$dir/$who.acquired"
  if [ "$who" = a ]; then
    n=0
    while [ ! -f "$dir/b.finished" ] && [ "$n" -lt 150 ]; do sleep 0.02; n=$((n + 1)); done
  fi
  fm_control_release_feedback_claim "$dir/claim"
  rc=0
else
  rc=1
fi
: > "$dir/$who.finished"
exit "$rc"
SH
  FM_STATE_OVERRIDE="$dir/state" "$BASH" "$dir/contender.sh" "$ROOT" "$dir" a "$dead_pid" > "$dir/a.log" 2>&1 &
  pid_a=$!
  FM_STATE_OVERRIDE="$dir/state" "$BASH" "$dir/contender.sh" "$ROOT" "$dir" b "$dead_pid" > "$dir/b.log" 2>&1 &
  pid_b=$!
  rc_a=0; wait "$pid_a" || rc_a=$?
  rc_b=0; wait "$pid_b" || rc_b=$?
  [ -f "$dir/a.observed" ] && [ -f "$dir/b.observed" ] || fail "both contenders must inspect the dead owner"
  assert_equals 0 "$rc_a" "the first contender recovers the stale claim"
  assert_equals 1 "$rc_b" "a contender with a stale observation cannot reclaim a fresh live claim"
  [ ! -e "$dir/b.acquired" ] || fail "two contenders held the claim simultaneously"
  pass "feedback claim: competing stale recovery preserves the fresh owner"
}

# shellcheck disable=SC2016
test_feedback_claim_recovers_legacy_owner() {
  local dir dead_pid rc=0
  dir=$(fm_test_tmproot feedback-legacy)
  mkdir -p "$dir/claim"
  printf '%s 0\n' "$$" > "$dir/claim/owner"
  touch -t 200101010101 "$dir/claim"
  FM_STATE_OVERRIDE="$dir/state" "$BASH" -c '. "$1/bin/fm-control-lib.sh"; fm_control_acquire_feedback_claim "$2"' _ "$ROOT" "$dir/claim" || rc=$?
  assert_equals 1 "$rc" "an old-format claim with a live owner is preserved regardless of age"
  "$BASH" -c 'exit 0' &
  dead_pid=$!
  wait "$dead_pid"
  printf '%s 0\n' "$dead_pid" > "$dir/claim/owner"
  rc=0
  FM_STATE_OVERRIDE="$dir/state" "$BASH" -c '. "$1/bin/fm-control-lib.sh"; fm_control_acquire_feedback_claim "$2" && fm_control_release_feedback_claim "$2"' _ "$ROOT" "$dir/claim" || rc=$?
  assert_equals 0 "$rc" "a dead old-format owner does not strand feedback dismissal after an upgrade"
  pass "feedback claim: legacy owners are recovered only after they exit"
}

# shellcheck disable=SC2016
test_feedback_claim_release_preserves_another_owner() {
  local dir holder n=0 rc=0
  dir=$(fm_test_tmproot feedback-release)
  FM_STATE_OVERRIDE="$dir/state" "$BASH" -c '. "$1/bin/fm-control-lib.sh"; fm_control_acquire_feedback_claim "$2/claim" || exit 1; : > "$2/ready"; sleep 30' _ "$ROOT" "$dir" &
  holder=$!
  LOCK_PIDS="$LOCK_PIDS $holder"
  while [ ! -f "$dir/ready" ] && [ "$n" -lt 100 ]; do sleep 0.02; n=$((n + 1)); done
  [ -f "$dir/ready" ] || fail "the live owner could not acquire its claim"
  FM_STATE_OVERRIDE="$dir/state" "$BASH" -c '. "$1/bin/fm-control-lib.sh"; fm_control_release_feedback_claim "$2"' _ "$ROOT" "$dir/claim"
  [ -d "$dir/claim" ] || fail "release removed another process's claim"
  FM_STATE_OVERRIDE="$dir/state" "$BASH" -c '. "$1/bin/fm-control-lib.sh"; fm_control_acquire_feedback_claim "$2"' _ "$ROOT" "$dir/claim" || rc=$?
  assert_equals 1 "$rc" "another process cannot acquire the preserved live claim"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "feedback claim: release preserves another live owner"
}

test_watchdog_rearms_uncertain_feedback_on_primary_and_worker() {
  local subject target marker n
  for subject in primary worker; do
    make_home $'working\n> ' $'key-secs=0\nkey-settle-secs=0'
    target=$T
    if [ "$subject" = worker ]; then
      worker_pane feedback ship $'working\n> '
      printf 'harness=codex\n' >> "$H/state/feedback.meta"
      target=$WP
    fi
    printf '%s\n' $'How was this?\n\n 1. bug         Crash, error message, hang, or broken UI/behavior\n 2. bad_result  Output was off-target, incorrect, incomplete, or unhelpful\n 3. other       Slowness, feature suggestion, UX feedback, or anything else\n\nPress enter to confirm or esc to go back' > "$H/feedback.txt"
    cat > "$H/dialog.sh" <<'SH'
#!/usr/bin/env bash
home=$1
for i in 1 2; do
  printf '\033[2J\033[H'
  cat "$home/feedback.txt"
  stty -echo raw
  dd bs=1 count=1 of="$home/key-$i" 2>/dev/null
  stty sane -echo
  while [ ! -e "$home/clear-$i" ]; do sleep 0.02; done
  printf '\033[2J\033[Hworking\n> \n'
  : > "$home/ready-$i"
  while [ ! -e "$home/reopen" ]; do sleep 0.02; done
done
SH
    "$REAL_TMUX" -f /dev/null -L "$SOCKET" respawn-pane -k -t "$target" "bash '$H/dialog.sh' '$H'"
    sleep 0.2
    run_wd 0 once >/dev/null 2>&1 || fail "$subject initial uncertain dismissal failed"
    assert_equals 1 "$(wc -c < "$H/key-1" | tr -d ' ')" "$subject receives its first dismiss key"
    marker=$(find "$H/state" -maxdepth 1 -name '.feedback-dismissed-*' | head -n 1)
    [ -f "$marker" ] || fail "$subject uncertain dismissal did not retain a marker"
    : > "$H/clear-1"
    n=0
    while [ ! -e "$H/ready-1" ] && [ "$n" -lt 100 ]; do sleep 0.02; n=$((n + 1)); done
    [ -f "$H/ready-1" ] || fail "$subject dialog never cleared"
    cp "$H/config/watchdog" "$H/watchdog-original"
    printf 'do-not-touch=%s\n' "$target" >> "$H/config/watchdog"
    run_wd 1 once >/dev/null 2>&1 || fail "$subject do-not-touch observation failed"
    [ -f "$marker" ] || fail "$subject do-not-touch observation changed the marker"
    cp "$H/watchdog-original" "$H/config/watchdog"
    run_wd 2 once --dry-run >/dev/null 2>&1 || fail "$subject dry-run observation failed"
    [ -f "$marker" ] || fail "$subject dry-run observation changed the marker"
    run_wd 2 scan >/dev/null 2>&1 || fail "$subject scan observation failed"
    [ -f "$marker" ] || fail "$subject scan observation changed the marker"
    wrap_tmux_visible fail
    run_wd 2 once >/dev/null 2>&1 || fail "$subject failed viewport observation failed"
    [ -f "$marker" ] || fail "$subject failed viewport cleared the marker"
    wrap_tmux_visible blank
    run_wd 3 once >/dev/null 2>&1 || fail "$subject empty viewport observation failed"
    [ -f "$marker" ] || fail "$subject empty viewport cleared the marker"
    restore_fake_tmux
    run_wd 4 once >/dev/null 2>&1 || fail "$subject absent-dialog observation failed"
    [ ! -f "$marker" ] || fail "$subject absent-dialog observation did not clear the marker"
    : > "$H/reopen"
    sleep 0.2
    run_wd 4000 once >/dev/null 2>&1 || fail "$subject reopened-dialog pass failed"
    assert_equals 1 "$(wc -c < "$H/key-2" | tr -d ' ')" "$subject identical reopening receives a new dismiss key"
  done
  pass "watchdog: primary and worker absence observations rearm uncertain dialogs with capture and do-not-touch guards"
}

test_feedback_uncertain_dismissal_reopens() {
  local dir mode
  dir=$(fm_test_tmproot feedback-reopen)
  for mode in sticky empty; do
    cat > "$dir/check.sh" <<'SH'
set -u
root=$1 dir=$2 mode=$3
mkdir -p "$dir"
. "$root/bin/fm-control-lib.sh"
screen=$'How was this?\n\n 1. bug         Crash, error message, hang, or broken UI/behavior\n 2. bad_result  Output was off-target, incorrect, incomplete, or unhelpful\n 3. other       Slowness, feature suggestion, UX feedback, or anything else\n\nPress enter to confirm or esc to go back'
printf '%s\n' "$screen" > "$dir/pane"
fm_control_capture_feedback_pane() { cat "$dir/pane"; }
fm_control_send_feedback_dismiss() {
  printf '%s\n' "$3" >> "$dir/keys"
  if [ "$mode" = empty ]; then : > "$dir/pane"; fi
}
rc=0
fm_control_dismiss_feedback_dialog "$dir/state" tmux test codex "$screen" '' 0 5 || rc=$?
[ "$rc" = 4 ] || exit 10
printf 'working\n> \n' > "$dir/pane"
rc=0
fm_control_dismiss_feedback_dialog "$dir/state" tmux test codex "$(cat "$dir/pane")" '' 0 5 || rc=$?
[ "$rc" = 1 ] || { printf 'clear observation rc=%s\n' "$rc"; exit 11; }
printf '%s\n' "$screen" > "$dir/pane"
rc=0
fm_control_dismiss_feedback_dialog "$dir/state" tmux test codex "$screen" '' 0 5 || rc=$?
[ "$rc" = 4 ] || exit 12
SH
    FM_STATE_OVERRIDE="$dir/$mode/state" "$BASH" "$dir/check.sh" "$ROOT" "$dir/$mode" "$mode" </dev/null
    assert_equals 0 "$?" "a $mode post-send capture is rearmed by a later clear observation"
    assert_equals $'Escape\nEscape' "$(cat "$dir/$mode/keys")" "an identical reopened dialog gets a new dismiss key after $mode verification"
  done
  pass "feedback dismiss: a later clear observation rearms an uncertain dismissal"
}

test_feedback_and_bug_report_dialog_dismissal() {
  local agy_survey agy_multiline claude_survey claude_survey_statusline claude_survey_autocompact claude_draft claude_modal_input claude_modal_scope claude_modal_consent claude_followup codex_feedback codex_upload near_miss unknown_picker
  agy_survey=$'work output\nHow\'s the CLI experience so far? Help us improve: [1] Good [2] Fine [3] Bad [0] Skip\n> \n  ? for shortcuts'
  agy_multiline=$'work output\nHow\'s the CLI experience so far? Help us improve:\n  [1] Good  [2] Fine  [3] Bad  [0] Skip'
  claude_survey=$'some work\n● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss'
  claude_survey_statusline=$'some work\n● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss\n────────────────────────────────────────\n❯\xc2\xa0\n────────────────────────────────────────\n  [opus-4.6] workspace/firstmate · main'
  claude_survey_autocompact=$'some work\n● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss\n────────────────────────────────────────\n❯ \n────────────────────────────────────────\n  Context left until auto-compact: 8% · ◯ IDE connected'
  claude_draft=$'some work\n● Bug report drafted: tool timeout on large file\n  1 to review · 2 to send · 0 to dismiss'
  claude_modal_input=$'Submit feedback / bug report\nDescribe the issue below:\n\nPress Enter to continue · Esc to cancel'
  claude_modal_scope=$'Report a bug or share your conversation\nHow much session history should we include?\n ❯ 1. This session only\n   2. Last 5 sessions\n\nEnter to choose · Esc to cancel'
  claude_modal_consent=$'Submit feedback / bug report\nThis report will include:\n- Your feedback / bug description: hang\n\nEnter to submit · ↑/↓ to navigate · Esc to cancel'
  claude_followup=$'● What went wrong? (optional)\n\n  enter to send · esc to skip'
  codex_feedback=$'How was this?\n\n ❯ 1. bug         Crash, error message, hang, or broken UI/behavior\n   2. bad_result  Output was off-target, incorrect, incomplete, or unhelpful\n   3. other       Slowness, feature suggestion, UX feedback, or anything else\n\nPress enter to confirm or esc to go back'
  codex_upload=$'Upload logs?\nThe following files will be sent:\n  • codex-logs.log\n\n ❯ 1. Yes\n   2. No\n\nPress enter to confirm or esc to go back'
  unknown_picker=$'Which plan should I follow?\n ❯ 1. Plan A (Recommended)\n   2. Plan B\n\nEnter to select · ↑/↓ to navigate · Esc to cancel'

  # 1. Exact per-harness signatures choose only the skip/dismiss key (0 or Escape), never submit.
  assert_equals $'agy-cli-feedback\t0' "$(lib fm_control_feedback_dialog_dismiss agy "$agy_survey")" "agy single-line CLI survey chooses 0/Skip"
  assert_equals $'agy-cli-feedback\t0' "$(lib fm_control_feedback_dialog_dismiss agy "$agy_multiline")" "agy two-line CLI survey chooses 0/Skip"
  assert_equals $'claude-session-feedback\t0' "$(lib fm_control_feedback_dialog_dismiss claude "$claude_survey")" "claude session survey chooses 0/Dismiss"
  assert_equals $'claude-session-feedback\t0' "$(lib fm_control_feedback_dialog_dismiss claude "$claude_survey_statusline")" "claude session survey with statusLine under input box chooses 0/Dismiss"
  assert_equals $'claude-session-feedback\t0' "$(lib fm_control_feedback_dialog_dismiss claude "$claude_survey_autocompact")" "claude session survey with auto-compact row under input box chooses 0/Dismiss"
  assert_equals $'claude-bug-report-draft\t0' "$(lib fm_control_feedback_dialog_dismiss claude "$claude_draft")" "claude drafted bug report card chooses 0/dismiss"
  assert_equals $'claude-bug-report-dialog\tEscape' "$(lib fm_control_feedback_dialog_dismiss claude "$claude_modal_input")" "claude bug report input step chooses Escape"
  assert_equals $'claude-bug-report-dialog\tEscape' "$(lib fm_control_feedback_dialog_dismiss claude "$claude_modal_scope")" "claude bug report scope step chooses Escape"
  assert_equals $'claude-bug-report-dialog\tEscape' "$(lib fm_control_feedback_dialog_dismiss claude "$claude_modal_consent")" "claude bug report consent step chooses Escape"
  assert_equals $'claude-survey-followup\tEscape' "$(lib fm_control_feedback_dialog_dismiss claude "$claude_followup")" "claude survey follow-up chooses Escape"
  assert_equals $'codex-feedback-dialog\tEscape' "$(lib fm_control_feedback_dialog_dismiss codex "$codex_feedback")" "codex feedback picker chooses Escape"
  assert_equals $'codex-upload-logs\tEscape' "$(lib fm_control_feedback_dialog_dismiss codex "$codex_upload")" "codex upload logs prompt chooses Escape"

  local screen
  for screen in "$agy_survey" "$agy_multiline" "$claude_survey" "$claude_survey_statusline" "$claude_survey_autocompact" "$claude_draft" "$claude_modal_input" "$claude_modal_scope" "$claude_modal_consent" "$claude_followup" "$codex_feedback" "$codex_upload"; do
    assert_equals feedback "$(lib fm_wd_pane_dialog "$screen")" "fm_wd_pane_dialog classifies known feedback/bug-report fixture as feedback"
  done

  # 2. Per-harness scoping: a signature from another harness is never matched.
  ! lib fm_control_feedback_dialog_dismiss claude "$agy_survey" || fail "claude adapter matched agy survey"
  ! lib fm_control_feedback_dialog_dismiss codex "$agy_survey" || fail "codex adapter matched agy survey"
  ! lib fm_control_feedback_dialog_dismiss pi "$agy_survey" || fail "pi adapter matched agy survey"
  ! lib fm_control_feedback_dialog_dismiss agy "$claude_survey" || fail "agy adapter matched claude survey"
  ! lib fm_control_feedback_dialog_dismiss codex "$claude_draft" || fail "codex adapter matched claude bug report draft"
  ! lib fm_control_feedback_dialog_dismiss claude "$codex_feedback" || fail "claude adapter matched codex feedback dialog"

  # 3. Near-miss texts, altered footers, and unknown dialogs are never dismissed.
  for near_miss in \
    $'Log: How\'s the CLI experience so far? Help us improve: [1] Good [2] Fine [3] Bad [0] Skip' \
    $'How\'s the CLI experience so far? Help us improve: [1] Good [2] Fine [3] Bad' \
    $'● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good' \
    $'● Bug report drafted: tool timeout\n  1 to review · 2 to send' \
    $'Submit feedback / bug report\nDescribe the issue below:\n\nPress Enter to continue' \
    $'How was this?\n\n ❯ 1. bug         Crash, error message, hang, or broken UI/behavior\n\nDo not press esc to close' \
    $'How was this?\n\n ❯ 1. bug         Crash, error message, hang, or broken UI/behavior\n\nPress space to continue or esc to close' \
    $'Upload logs?\nThe following files will be sent:\n  • codex-logs.log\n\nPress space to confirm' \
    $'How\'s the CLI experience so far? Help us improve: [1] Good [2] Fine [3] Bad [0] Skip\nnew work output after survey\n> '; do
    ! lib fm_control_feedback_dialog_dismiss "" "$near_miss" || fail "near-miss matched feedback dismissal: $near_miss"
    assert_equals "" "$(lib fm_wd_pane_dialog "$near_miss")" "near-miss is not classified as a dialog: $near_miss"
  done
  # 3b. A TUI that full-clears its screen pushes the closed dialog and its input
  #     box into scrollback, then draws a clean or populated prompt below. The
  #     later input box proves the dialog is stale; dismissing it would type 0
  #     into the composer or corrupt an existing draft.
  local stale_boxed stale_bare stale_rule stale_boxed_draft stale_bare_draft stale_rule_draft
  stale_boxed=$'● Done. I updated the parser and ran the tests.\n● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss\n╭──────────────────────────────╮\n│ >                            │\n╰──────────────────────────────╯\n  ? for shortcuts\n● Done. I updated the parser and ran the tests.\n╭──────────────────────────────╮\n│ >                            │\n╰──────────────────────────────╯\n  ? for shortcuts'
  stale_bare=$'some work\n● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss\n> \nsome work\n> '
  stale_rule=$'some work\n● Bug report drafted: tool timeout on large file\n  1 to review · 2 to send · 0 to dismiss\n────────────────────────────────────────\n❯ \n────────────────────────────────────────\n  [opus-4.6] workspace/firstmate · main\nsome work\n────────────────────────────────────────\n❯ \n────────────────────────────────────────\n  [opus-4.6] workspace/firstmate · main'
  stale_boxed_draft=$'● Done. I updated the parser and ran the tests.\n● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss\n╭──────────────────────────────╮\n│ >                            │\n╰──────────────────────────────╯\n  ? for shortcuts\n● Done. I updated the parser and ran the tests.\n╭──────────────────────────────╮\n│ > existing draft             │\n╰──────────────────────────────╯\n  ? for shortcuts'
  stale_bare_draft=$'some work\n● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss\n> \nsome work\n> existing draft'
  stale_rule_draft=$'some work\n● Bug report drafted: tool timeout on large file\n  1 to review · 2 to send · 0 to dismiss\n────────────────────────────────────────\n❯ \n────────────────────────────────────────\n  [opus-4.6] workspace/firstmate · main\nsome work\n────────────────────────────────────────\n❯ existing draft\n────────────────────────────────────────\n  [opus-4.6] workspace/firstmate · main'
  for screen in "$stale_boxed" "$stale_bare" "$stale_rule" "$stale_boxed_draft" "$stale_bare_draft" "$stale_rule_draft"; do
    ! lib fm_control_feedback_dialog_dismiss claude "$screen" || fail "stale dialog above a newer prompt matched feedback dismissal: $screen"
  done
  ! lib fm_control_feedback_dialog_dismiss "" "$unknown_picker" || fail "unknown picker matched feedback dismissal"
  assert_equals question "$(lib fm_wd_pane_dialog "$unknown_picker")" "unknown picker still classifies as question"

  # 4. Watchdog auto-dismisses worker feedback and bug-report dialogs without submitting,
  #    enforces per-harness scoping on worker panes, preserves the home pane's composer
  #    state (home draft + worker dialog in one pass), and does not let worker failures
  #    consume the primary home pane's two-failure cap.
  make_home $'Captain session\n────────────────────────────────────────\n❯ home draft in progress\n────────────────────────────────────────\n  ? for shortcuts'
  transcript 100 "Working."
  local home_canon
  home_canon=$(cd -P "$H" && pwd -P)
  mkdir -p "$H/state/watchdog"
  printf '%s\tw1\t%s\tworker:other\tdialog\tkey\tfailed\tstuck\n%s\tw2\t%s\tworker:other\tdialog\tkey\tfailed\tstuck\n' \
    "$((BASE - 200))" "$home_canon" "$((BASE - 100))" "$home_canon" > "$H/state/watchdog/actions.tsv"
  cat > "$H/worker-agy.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' 'How'\''s the CLI experience so far? Help us improve: [1] Good [2] Fine [3] Bad [0] Skip'
stty -echo raw
dd bs=1 count=1 of="$H/worker-agy.key" 2>/dev/null
stty sane -echo
clear
printf '> \n'
exec sleep $WD_FIXTURE_SLEEP
SH
  chmod +x "$H/worker-agy.sh"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" new-session -d -s "wkagy${CASE_N}" -x 160 -y 40 "$H/worker-agy.sh"
  WP=$("$REAL_TMUX" -f /dev/null -L "$SOCKET" list-panes -t "=wkagy${CASE_N}" -F '#{pane_id}' | head -n 1)
  printf 'kind=ship\nharness=agy\nbackend=tmux\nwindow=%s\nendpoint_task_id=agyw\n' "$WP" > "$H/state/agyw.meta"
  cat > "$H/worker-mismatch.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' 'How'\''s the CLI experience so far? Help us improve: [1] Good [2] Fine [3] Bad [0] Skip'
stty -echo
exec cat >> "$H/worker-mismatch.key"
SH
  chmod +x "$H/worker-mismatch.sh"
  : > "$H/worker-mismatch.key"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" new-session -d -s "wkmis${CASE_N}" -x 160 -y 40 "$H/worker-mismatch.sh"
  local WP_MIS
  WP_MIS=$("$REAL_TMUX" -f /dev/null -L "$SOCKET" list-panes -t "=wkmis${CASE_N}" -F '#{pane_id}' | head -n 1)
  printf 'kind=ship\nharness=claude\nbackend=tmux\nwindow=%s\nendpoint_task_id=misw\n' "$WP_MIS" > "$H/state/misw.meta"
  sleep 0.5
  local post_worker_state
  post_worker_state=$(
    FM_TEST_SEAM=1 FM_WD_NOW="$BASE" FM_HOME="$H" bash -c '
      HOME_T=$2
      . "$1"
      fm_backend_composer_state() {
        if [ "$2" = "$HOME_T" ]; then printf "pending\n"; else printf "empty\n"; fi
      }
      mkdir -p "$WD" "$OUT"
      WD_GAPS=$(mktemp "$WD/.gaps.XXXXXX")
      wd_observe "$FM_HOME" - primary
      O_DRAFT="home-orca-draft"
      WD_SYMPTOM=ok WD_RESTARTED=0
      wd_handle_subject
      wd_visit_worker_dialogs page
      rm -f "$WD_GAPS"
      printf "%s|%s|%s\n" "$O_COMPOSER" "$O_DRAFT" "$(printf "%s" "$O_COMPOSER_TEXT" | tr "\n" " ")"
    ' _ "$WD" "$T"
  ) || fail "watchdog worker feedback pass failed"
  assert_equals "0" "$(cat "$H/worker-agy.key" 2>/dev/null)" "worker agy survey received literal 0 and nothing else"
  assert_equals "" "$(cat "$H/worker-mismatch.key" 2>/dev/null)" "claude worker showing an agy survey receives no key"
  assert_equals 0 "$(awk -F'\t' '$4 == "worker:misw"' "$H/state/watchdog/actions.tsv" | wc -l | tr -d ' ')" \
    "mismatched-harness worker records no dialog key action"
  assert_equals 1 "$(awk -F'\t' '$4 == "worker:agyw" && $5 == "dialog" && $6 == "key" && $7 == "done"' "$H/state/watchdog/actions.tsv" | wc -l | tr -d ' ')" \
    "worker agy feedback dismissal recorded done despite another worker's two failures: $(ledger)"
  assert_grep "composer=pending" "$H/state/watchdog/subjects/$(home_key)" \
    "home subject recorded pending composer"
  assert_contains "$post_worker_state" "pending|home-orca-draft|" \
    "worker feedback dismissal did not overwrite the home pane's O_COMPOSER or O_DRAFT"
  assert_contains "$post_worker_state" "home draft in progress" \
    "worker feedback dismissal did not overwrite the home pane's O_COMPOSER_TEXT"
  [ ! -s "$H/typed.log" ] || fail "home pane with draft was typed into during worker dialog dismissal: $(cat "$H/typed.log")"

  # 5. Watcher (fm-watch.sh) auto-dismisses an idle worker's feedback dialog and logs the dismissal, but leaves a busy worker alone.
  local wdir wstate wfake wout
  wdir="$TMP_ROOT/watch-feedback-$CASE_N"
  wstate="$wdir/state"
  wfake="$wdir/fakebin"
  wout="$wdir/watch.out"
  mkdir -p "$wstate" "$wfake" "$wdir/config"
  printf 'window=test:fm-agy\nkind=ship\nharness=agy\nbackend=tmux\n' > "$wstate/agy.meta"
  cat > "$wfake/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf 'fm-agy\n'; exit 0 ;;
  capture-pane) cat "$FM_TEST_WATCH_PANE"; exit 0 ;;
  send-keys)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) shift; printf 'LITERAL:%s\n' "${1:-}" >> "$FM_TEST_WATCH_KEYS"; shift ;;
        *) printf 'KEY:%s\n' "$1" >> "$FM_TEST_WATCH_KEYS"; shift ;;
      esac
    done
    [ -z "${FM_TEST_WATCH_CLEAR_ON_SEND:-}" ] || printf 'work output\n> \n' > "$FM_TEST_WATCH_PANE"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$wfake/tmux"
  printf '%s\n' "$agy_survey" > "$wdir/pane-idle.txt"
  : > "$wdir/keys.log"
  PATH="$wfake:$PATH" FM_TEST_WATCH_PANE="$wdir/pane-idle.txt" FM_TEST_WATCH_KEYS="$wdir/keys.log" FM_TEST_WATCH_CLEAR_ON_SEND=1 \
    FM_HOME="$wdir" FM_STATE_OVERRIDE="$wstate" FM_CONFIG_OVERRIDE="$wdir/config" \
    FM_WATCH_ONCE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    bash "$ROOT/bin/fm-watch.sh" > "$wout" 2>&1 || fail "fm-watch.sh once failed on idle feedback pane: $(cat "$wout")"
  assert_equals "LITERAL:0" "$(cat "$wdir/keys.log")" "watcher sent only literal 0 (never Enter or submit) on idle agy survey"
  assert_grep "auto-dismissed feedback dialog (agy-cli-feedback key=0): test:fm-agy" "$wstate/.watch-triage.log" \
    "watcher logged the feedback dismissal"

  # 6. Shared atomic claim: when two callers race on one pane (even with different
  #    status-row snapshots), serialization sends the dismiss key at most once.
  local rstate="$wdir/race-state" pid1 pid2
  mkdir -p "$rstate"
  printf '%s\n' "$claude_survey_statusline" > "$wdir/pane-race.txt"
  : > "$wdir/race-keys.log"
  cat > "$wfake/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  capture-pane) cat "$FM_TEST_WATCH_PANE"; exit 0 ;;
  send-keys)
    sleep 0.1
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) shift; printf 'LITERAL:%s\n' "${1:-}" >> "$FM_TEST_WATCH_KEYS"; shift ;;
        *) printf 'KEY:%s\n' "$1" >> "$FM_TEST_WATCH_KEYS"; shift ;;
      esac
    done
    printf 'work output\n> \n' > "$FM_TEST_WATCH_PANE"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$wfake/tmux"
  (
    PATH="$wfake:$PATH" FM_TEST_WATCH_PANE="$wdir/pane-race.txt" FM_TEST_WATCH_KEYS="$wdir/race-keys.log" \
      bash -c '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-control-lib.sh"; fm_control_dismiss_feedback_dialog "$2" tmux "test:fm-agy" claude "$3" "fm-agy" 0.1' \
      _ "$ROOT" "$rstate" "$claude_survey_statusline" >/dev/null 2>&1 || true
  ) &
  pid1=$!
  (
    PATH="$wfake:$PATH" FM_TEST_WATCH_PANE="$wdir/pane-race.txt" FM_TEST_WATCH_KEYS="$wdir/race-keys.log" \
      bash -c '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-control-lib.sh"; fm_control_dismiss_feedback_dialog "$2" tmux "test:fm-agy" claude "$3" "fm-agy" 0.1' \
      _ "$ROOT" "$rstate" "$claude_survey_autocompact" >/dev/null 2>&1 || true
  ) &
  pid2=$!
  wait "$pid1" "$pid2"
  assert_equals "LITERAL:0" "$(cat "$wdir/race-keys.log")" "concurrent callers racing with different snapshots on one pane send the dismiss key exactly once"

  # 7. A key delivery that fails leaves the dialog retryable on the next tick.
  local fstate="$wdir/fail-state" frc=0
  mkdir -p "$fstate"
  printf '%s\n' "$agy_survey" > "$wdir/pane-fail.txt"
  : > "$wdir/fail-keys.log"
  : > "$wdir/send-fails-once"
  cat > "$wfake/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  capture-pane) cat "$FM_TEST_WATCH_PANE"; exit 0 ;;
  send-keys)
    if [ -e "$FM_TEST_SEND_FAILS_ONCE" ]; then rm -f "$FM_TEST_SEND_FAILS_ONCE"; exit 1; fi
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) shift; printf 'LITERAL:%s\n' "${1:-}" >> "$FM_TEST_WATCH_KEYS"; shift ;;
        *) printf 'KEY:%s\n' "$1" >> "$FM_TEST_WATCH_KEYS"; shift ;;
      esac
    done
    printf 'work output\n> \n' > "$FM_TEST_WATCH_PANE"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$wfake/tmux"
  PATH="$wfake:$PATH" FM_TEST_WATCH_PANE="$wdir/pane-fail.txt" FM_TEST_WATCH_KEYS="$wdir/fail-keys.log" FM_TEST_SEND_FAILS_ONCE="$wdir/send-fails-once" \
    bash -c '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-control-lib.sh"; fm_control_dismiss_feedback_dialog "$2" tmux "test:fm-agy" agy "$3" "fm-agy" 0.1' \
    _ "$ROOT" "$fstate" "$agy_survey" >/dev/null 2>&1 || frc=$?
  assert_equals 3 "$frc" "a failed key delivery reports delivery failure"
  assert_equals "" "$(cat "$wdir/fail-keys.log")" "no key reached the pane on the failed delivery"
  frc=0
  PATH="$wfake:$PATH" FM_TEST_WATCH_PANE="$wdir/pane-fail.txt" FM_TEST_WATCH_KEYS="$wdir/fail-keys.log" FM_TEST_SEND_FAILS_ONCE="$wdir/send-fails-once" \
    bash -c '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-control-lib.sh"; fm_control_dismiss_feedback_dialog "$2" tmux "test:fm-agy" agy "$3" "fm-agy" 0.1' \
    _ "$ROOT" "$fstate" "$agy_survey" >/dev/null 2>&1 || frc=$?
  assert_equals 0 "$frc" "the next tick retries the unchanged dialog after a failed delivery and clears it"
  assert_equals "LITERAL:0" "$(cat "$wdir/fail-keys.log")" "the retry sends the dismiss key once"

  # 7b. After a verified dismissal clears .feedback-dismissed-*, an identical dialog
  #     reappearing later on the same endpoint is dismissed again.
  printf '%s\n' "$agy_survey" > "$wdir/pane-fail.txt"
  : > "$wdir/fail-keys.log"
  frc=0
  PATH="$wfake:$PATH" FM_TEST_WATCH_PANE="$wdir/pane-fail.txt" FM_TEST_WATCH_KEYS="$wdir/fail-keys.log" \
    bash -c '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-control-lib.sh"; fm_control_dismiss_feedback_dialog "$2" tmux "test:fm-agy" agy "$3" "fm-agy" 0.1' \
    _ "$ROOT" "$fstate" "$agy_survey" >/dev/null 2>&1 || frc=$?
  assert_equals 0 "$frc" "an identical dialog reappearing after a verified dismissal is dismissed again"
  assert_equals "LITERAL:0" "$(cat "$wdir/fail-keys.log")" "the reopened identical dialog receives its dismiss key"

  # 7c. A failed, empty, or timed-out live pre-send capture refuses to send any key.
  local cstate="$wdir/cap-state" cap_mode
  mkdir -p "$cstate"
  for cap_mode in fail empty timeout; do
    : > "$wdir/cap-keys.log"
    cat > "$wfake/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  capture-pane)
    case "$cap_mode" in
      fail) exit 1 ;;
      empty) exit 0 ;;
      timeout) sleep 5; exit 0 ;;
    esac ;;
  send-keys)
    printf 'SENT\n' >> "$wdir/cap-keys.log"
    exit 0 ;;
esac
exit 0
SH
    chmod +x "$wfake/tmux"
    frc=0
    PATH="$wfake:$PATH" bash -c '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-control-lib.sh"; fm_control_dismiss_feedback_dialog "$2" tmux "test:fm-agy" agy "$3" "fm-agy" 0.1 1' \
      _ "$ROOT" "$cstate" "$agy_survey" >/dev/null 2>&1 || frc=$?
    assert_equals 2 "$frc" "live capture mode '$cap_mode' refuses dismissal with rc 2"
    assert_equals "" "$(cat "$wdir/cap-keys.log")" "live capture mode '$cap_mode' sends zero keys"
  done

  # 7d. An interrupted claimant (dead owner PID) or expired stale claim is recovered
  #     by a subsequent caller on the same endpoint.
  local kstate="$wdir/kill-state" dead_pid
  mkdir -p "$kstate"
  printf '%s\n' "$agy_survey" > "$wdir/pane-kill.txt"
  : > "$wdir/kill-keys.log"
  cat > "$wfake/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  capture-pane)
    if [ -e "${FM_TEST_HOLD_CLAIM:-}" ]; then
      : > "$FM_TEST_HOLD_CLAIM.ready"
      sleep 30
    fi
    cat "$FM_TEST_WATCH_PANE"
    exit 0 ;;
  send-keys)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) shift; printf 'LITERAL:%s\n' "${1:-}" >> "$FM_TEST_WATCH_KEYS"; shift ;;
        *) printf 'KEY:%s\n' "$1" >> "$FM_TEST_WATCH_KEYS"; shift ;;
      esac
    done
    printf 'work output\n> \n' > "$FM_TEST_WATCH_PANE"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$wfake/tmux"
  : > "$wdir/hold-claim"
  (
    PATH="$wfake:$PATH" FM_TEST_WATCH_PANE="$wdir/pane-kill.txt" FM_TEST_WATCH_KEYS="$wdir/kill-keys.log" FM_TEST_HOLD_CLAIM="$wdir/hold-claim" \
      bash -c '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-control-lib.sh"; fm_control_dismiss_feedback_dialog "$2" tmux "test:fm-agy" agy "$3" "fm-agy" 0.1 20' \
      _ "$ROOT" "$kstate" "$agy_survey" >/dev/null 2>&1
  ) &
  dead_pid=$!
  local wait_i=0
  while [ ! -e "$wdir/hold-claim.ready" ] && [ "$wait_i" -lt 40 ]; do
    sleep 0.05
    wait_i=$((wait_i + 1))
  done
  kill -9 "$dead_pid" 2>/dev/null || true
  wait "$dead_pid" 2>/dev/null || true
  rm -f "$wdir/hold-claim" "$wdir/hold-claim.ready"
  [ -d "$kstate/.feedback-claim-tmux_test_fm-agy" ] || fail "killed claimant did not leave a claim directory behind"
  frc=0
  PATH="$wfake:$PATH" FM_TEST_WATCH_PANE="$wdir/pane-kill.txt" FM_TEST_WATCH_KEYS="$wdir/kill-keys.log" \
    bash -c '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-control-lib.sh"; fm_control_dismiss_feedback_dialog "$2" tmux "test:fm-agy" agy "$3" "fm-agy" 0.1' \
    _ "$ROOT" "$kstate" "$agy_survey" >/dev/null 2>&1 || frc=$?
  assert_equals 0 "$frc" "subsequent caller recovers a claim left by a terminated owner and dismisses the dialog"
  assert_equals "LITERAL:0" "$(cat "$wdir/kill-keys.log")" "recovered claim sends the dismiss key once"

  # Busy worker showing `esc to cancel` alongside the text is not touched.
  printf '%s\n  esc to cancel\n' "$agy_survey" > "$wdir/pane-busy.txt"
  : > "$wdir/keys.log"
  rm -rf "$wstate"/.feedback-dismissed-* "$wstate"/.feedback-claim-*
  PATH="$wfake:$PATH" FM_TEST_WATCH_PANE="$wdir/pane-busy.txt" FM_TEST_WATCH_KEYS="$wdir/keys.log" \
    FM_HOME="$wdir" FM_STATE_OVERRIDE="$wstate" FM_CONFIG_OVERRIDE="$wdir/config" \
    FM_WATCH_ONCE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    bash "$ROOT/bin/fm-watch.sh" > "$wout" 2>&1 || fail "fm-watch.sh once failed on busy pane"
  assert_equals "" "$(cat "$wdir/keys.log")" "watcher sends no key while the worker is busy"
  pass "feedback and bug-report dialogs: exact per-harness signatures auto-dismiss when idle without submitting, near-misses and unknown dialogs do not"
}

test_default_heartbeat_freeze_stays_above_a_quiet_home() {
  make_home $'Captain session\n❯ \n  ? for shortcuts'
  grep -v '^heartbeat-frozen-secs=' "$H/config/watchdog" > "$H/config/watchdog.new"
  mv "$H/config/watchdog.new" "$H/config/watchdog"
  transcript 3000 "Working."
  run_wd 0 once >/dev/null 2>&1
  run_wd 837 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows heartbeat-frozen detect held)" "a quiet home at the 837s healthy age was treated as frozen"
  assert_equals 0 "$(ledger_rows heartbeat-frozen nudge pending)" "a quiet home at the 837s healthy age was nudged"
  run_wd 900 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows heartbeat-frozen detect held)" "the default freeze threshold did not observe a 900s heartbeat"
  assert_equals 1 "$(ledger_rows heartbeat-frozen nudge pending)" "the default freeze threshold did not nudge a 900s heartbeat"
  pass "the default heartbeat freeze stays above a quiet home's healthy age and still fires at 900s"
}

test_default_heartbeat_freeze_uses_published_deadline() {
  make_home $'Synthetic session\n❯ \n  ? for shortcuts'
  grep -v '^heartbeat-frozen-secs=' "$H/config/watchdog" > "$H/config/watchdog.new"
  mv "$H/config/watchdog.new" "$H/config/watchdog"
  transcript 3000 "Working."
  # A 400-second collection starts at BASE. The publisher allows 2271
  # seconds after publication; generated-age readers must retain that offset.
  jq --argjson generated "$BASE" --argjson published "$((BASE + 400))" \
    '.generated_epoch=$generated | .published_epoch=$published | .stale_after_secs=2271' \
    "$H/state/heartbeat.json" > "$H/state/heartbeat.new"
  mv "$H/state/heartbeat.new" "$H/state/heartbeat.json"
  run_wd 400 once >/dev/null 2>&1
  run_wd 1300 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows heartbeat-frozen nudge pending)" "a valid long-cadence heartbeat was nudged at 900 seconds"
  assert_no_grep 'watcher heartbeat is' "$H/data/watchdog/status.md" "a valid long-cadence heartbeat was reported stale"
  run_wd 2671 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows heartbeat-frozen detect held)" "the inclusive publication freshness bound was shortened"
  run_wd 2672 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows heartbeat-frozen detect held)" "an expired long-cadence heartbeat was not detected"
  assert_equals 1 "$(ledger_rows heartbeat-frozen nudge pending)" "an expired long-cadence heartbeat was not nudged"
  assert_grep 'watcher heartbeat is' "$H/data/watchdog/status.md" "an expired long-cadence heartbeat was not reported stale"
  pass "default heartbeat recovery and stale reporting honor publication freshness and collection duration"
}

test_explicit_heartbeat_freeze_thresholds_keep_precedence() {
  local threshold offset expected before
  for threshold in 600 0; do
    make_home $'Synthetic session\n❯ \n  ? for shortcuts' "heartbeat-frozen-secs=$threshold
watcher-stale-secs=600"
    before=$(cat "$H/config/watchdog")
    transcript 3000 "Working."
    jq --argjson generated "$BASE" --argjson published "$((BASE + 400))" \
      '.generated_epoch=$generated | .published_epoch=$published | .stale_after_secs=2271' \
      "$H/state/heartbeat.json" > "$H/state/heartbeat.new"
    mv "$H/state/heartbeat.new" "$H/state/heartbeat.json"
    run_wd 400 once >/dev/null 2>&1
    offset=600 expected=1
    [ "$threshold" != 0 ] || { offset=3400; expected=0; }
    run_wd "$offset" once >/dev/null 2>&1
    assert_equals "$expected" "$(ledger_rows heartbeat-frozen detect held)" "explicit heartbeat-frozen-secs=$threshold was replaced by the derived default"
    assert_equals "$expected" "$(ledger_rows heartbeat-frozen nudge pending)" "explicit heartbeat-frozen-secs=$threshold changed recovery behavior"
    assert_grep 'watcher heartbeat is' "$H/data/watchdog/status.md" "an explicit stale-watcher threshold was replaced"
    assert_equals "$before" "$(cat "$H/config/watchdog")" "an explicit recovery setting was rewritten"
  done
  pass "explicit positive heartbeat recovery thresholds and zero disable retain their behavior"
}

test_long_cadence_context_uses_the_default_freshness_bound() {
  local setting expected
  for setting in default 900; do
    make_home $'Synthetic session\n> ' 'restart=on
restart-command=/bin/true'
    [ "$setting" = default ] || printf 'watcher-stale-secs=%s\n' "$setting" >> "$H/config/watchdog"
    transcript 3000 "Working."
    run_wd 0 once >/dev/null 2>&1
    jq --argjson published "$((BASE + 400))" \
      '.published_epoch=$published | .stale_after_secs=2271
        | .primary.context_left.remaining.percent=7' \
      "$H/state/heartbeat.json" > "$H/state/heartbeat.new"
    mv "$H/state/heartbeat.new" "$H/state/heartbeat.json"
    run_wd 1300 once >/dev/null 2>&1
    expected=1
    [ "$setting" = default ] || expected=0
    assert_equals "$expected" "$(ledger_rows handoff-request nudge pending)" \
      "$setting stale-watcher setting misclassified the current session's fresh context"
  done
  pass "long-cadence context stays usable under the derived default and honors explicit staleness"
}

test_invalid_heartbeat_freshness_keeps_legacy_default() {
  local variant
  for variant in string reversed future; do
    make_home $'Synthetic session\n❯ \n  ? for shortcuts'
    grep -v '^heartbeat-frozen-secs=' "$H/config/watchdog" > "$H/config/watchdog.new"
    mv "$H/config/watchdog.new" "$H/config/watchdog"
    transcript 3000 "Working."
    jq --arg variant "$variant" --argjson published "$BASE" \
      '.published_epoch=$published | .stale_after_secs=2271
        | if $variant == "string" then .stale_after_secs="2271"
          elif $variant == "reversed" then .published_epoch=($published-1)
          else .published_epoch=($published+901) end' \
      "$H/state/heartbeat.json" > "$H/state/heartbeat.new"
    mv "$H/state/heartbeat.new" "$H/state/heartbeat.json"
    run_wd 0 once >/dev/null 2>&1
    run_wd 900 once >/dev/null 2>&1
    assert_equals 1 "$(ledger_rows heartbeat-frozen nudge pending)" "$variant freshness metadata suppressed the legacy default"
  done
  pass "unusable publication freshness cannot extend the legacy watchdog default"
}

test_pending_handoff_suppresses_heartbeat_recovery() {
  local claim=$TMP_ROOT/pending-heartbeat.json now=1793000000
  jq -n --argjson d "$((now + 300))" '{version:1,predecessor_pid:4242,deadline:$d}' > "$claim"
  lib fm_wd_handoff_in_progress "$claim" 4242 "$now" 600 || fail "bounded matching handoff was not recognized"
  lib fm_wd_handoff_in_progress "$claim" 4243 "$now" 600 && fail "another owner claim counted"
  lib fm_wd_handoff_in_progress "$claim" 4242 "$((now + 301))" 600 && fail "expired handoff counted"
  lib fm_wd_handoff_in_progress "$claim" 4242 "$((now - 400))" 600 && fail "unbounded handoff counted"
  make_home $'Captain session\n❯ \n  ? for shortcuts' 'heartbeat-frozen-secs=600
restart=on
restart-command=/bin/false'
  transcript 3000 "Working."
  jq -n --argjson p "$LOCKPID" --argjson d "$((BASE + 1000))" '{version:1,predecessor_pid:$p,deadline:$d}' > "$H/state/.handoff-pending"
  run_wd 0 once >/dev/null 2>&1
  run_wd 700 once >/dev/null 2>&1
  run_wd 950 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows heartbeat-frozen detect held)" "the pending-handoff test did not observe a stale heartbeat"
  assert_equals 0 "$(ledger_rows heartbeat-frozen nudge pending)" "a pending handoff was nudged"
  assert_equals 0 "$(ledger_rows heartbeat-frozen restart pending)" "a pending handoff was restarted"
  pass "heartbeat recovery leaves a pending handoff alone"
}

test_heartbeat_recovery_preserves_account_pins() {
  local pin
  make_home $'Captain session\n❯ \n  ? for shortcuts' "heartbeat-frozen-secs=600
restart=on
restart-command=$TMP_ROOT/fake-captain.sh"
  write_fake_captain
  pin=$H/config/claude-account
  printf '%s\n' "$H/claude" > "$pin"
  transcript 3000 "Working."
  run_wd 0 once >/dev/null 2>&1
  run_wd 700 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows heartbeat-frozen nudge pending)" "stale heartbeat was not nudged"
  run_wd 800 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows heartbeat-frozen restart pending)" "restart preceded its grace period"
  run_wd 1000 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows heartbeat-frozen restart pending)" "unanswered heartbeat nudge did not restart"
  wait_pickup || fail "configured restart did not prove pickup"
  LOCK_PIDS="$LOCK_PIDS $(cat "$H/state/.lock")"
  assert_equals "$H/claude" "$(cat "$pin")" "heartbeat recovery changed an account pin"
  pass "heartbeat recovery uses the configured restart without changing account pins"
}

test_heartbeat_response_cannot_suppress_recovery_forever() {
  make_home $'Captain session\n❯ \n  ? for shortcuts' "heartbeat-frozen-secs=600
restart=on
restart-command=$TMP_ROOT/fake-captain.sh"
  write_fake_captain
  transcript 3000 "Working."
  run_wd 0 once >/dev/null 2>&1
  run_wd 700 once >/dev/null 2>&1
  fm_touch_epoch "$((BASE + 750))" "$H/claude/projects/p/$SID.jsonl"
  run_wd 1000 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows heartbeat-frozen restart pending)" "a response was ignored"
  run_wd 1700 once >/dev/null 2>&1
  assert_equals 2 "$(ledger_rows heartbeat-frozen nudge pending)" "a historical response prevented another nudge"
  run_wd 2000 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows heartbeat-frozen restart pending)" "one old response suppressed recovery indefinitely"
  wait_pickup || fail "the retried heartbeat recovery did not prove pickup"
  LOCK_PIDS="$LOCK_PIDS $(cat "$H/state/.lock")"
  pass "one transcript response cannot suppress later heartbeat recovery forever"
}

test_heartbeat_recovery_preserves_the_running_turn_veto() {
  make_home $'Captain session\n✻ Running tool… (esc to interrupt)' 'heartbeat-frozen-secs=600
restart=on
restart-command=/bin/false'
  transcript 3000 "Working."
  run_wd 0 once >/dev/null 2>&1
  run_wd 700 once >/dev/null 2>&1
  run_wd 1000 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows heartbeat-frozen detect held)" "the busy-turn test did not observe a stale heartbeat"
  assert_equals 0 "$(ledger_rows heartbeat-frozen nudge pending)" "a running turn was nudged"
  assert_equals 0 "$(ledger_rows heartbeat-frozen restart pending)" "a running turn was restarted"
  kill -0 "$LOCKPID" 2>/dev/null || fail "busy lock owner was stopped"
  pass "heartbeat recovery keeps the main running-turn veto"
}

test_heartbeat_dryrun_never_counts_as_delivery() {
  make_home $'Captain session\n❯ \n  ? for shortcuts' "heartbeat-frozen-secs=600
mode=dry-run
nudge-secs=1
restart=on
restart-command=$TMP_ROOT/fake-captain.sh"
  write_fake_captain
  transcript 3000 "Working."
  run_wd 0 once >/dev/null 2>&1
  run_wd 700 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows heartbeat-frozen nudge dry-run)" "the preview nudge was not recorded"
  printf 'mode=act\n' >> "$H/config/watchdog"
  run_wd 1000 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows heartbeat-frozen restart pending)" "preview history authorized a real restart"
  assert_equals 1 "$(ledger_rows heartbeat-frozen nudge pending)" "active mode did not deliver its own nudge"
  run_wd 1100 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows heartbeat-frozen restart pending)" "active delivery lost its full grace period"
  run_wd 1300 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows heartbeat-frozen restart pending)" "a proven active delivery never recovered"
  wait_pickup || fail "active recovery did not prove pickup"
  LOCK_PIDS="$LOCK_PIDS $(cat "$H/state/.lock")"
  pass "dry-run history cannot satisfy the active heartbeat delivery prerequisite"
}

test_heartbeat_swallowed_enter_never_counts_as_delivery() {
  make_home $'Captain session\n❯ \n  ? for shortcuts' "heartbeat-frozen-secs=600
restart=on
restart-command=$TMP_ROOT/fake-captain.sh"
  write_fake_captain
  echoing_composer_pane
  transcript 3000 "Working."
  run_wd 0 once >/dev/null 2>&1
  wrap_tmux_enter_swallowed
  run_wd 700 once >/dev/null 2>&1
  case "$(composer_line)" in
    '❯ '?*) ;;
    *) fail "the swallowed nudge never stayed in the composer: $(composer_line)" ;;
  esac
  [ "$(composer_line 4)" = '────────────────────────────────────────' ] \
    || fail "the nudge wrapped over the composer's lower rule: $(composer_line 4)"
  restore_fake_tmux
  assert_equals 1 "$(ledger_rows heartbeat-frozen nudge pending)" "the stale heartbeat was not nudged"
  assert_equals 0 "$(ledger_rows heartbeat-frozen nudge "done")" "a nudge whose Enter was swallowed was recorded as a delivery"
  run_wd 1000 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows heartbeat-frozen restart pending)" "a nudge left unsubmitted in the composer authorized a restart"
  pass "a heartbeat nudge whose Enter was swallowed never counts as delivery"
}

test_heartbeat_failed_send_never_counts_as_delivery() {
  make_home $'Captain session\n❯ \n  ? for shortcuts' "heartbeat-frozen-secs=600
restart=on
restart-command=$TMP_ROOT/fake-captain.sh"
  write_fake_captain
  transcript 3000 "Working."
  run_wd 0 once >/dev/null 2>&1
  wrap_tmux_literal_send_fails
  run_wd 700 once >/dev/null 2>&1
  restore_fake_tmux
  assert_equals 1 "$(ledger_rows heartbeat-frozen nudge pending)" "the stale heartbeat was not nudged"
  assert_equals 0 "$(ledger_rows heartbeat-frozen nudge "done")" "a failed send was recorded as a delivery"
  run_wd 1000 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows heartbeat-frozen restart pending)" "a nudge that never reached the session authorized a restart"
  pass "a heartbeat nudge whose send failed never counts as delivery"
}

test_heartbeat_ignores_orphan_and_previous_owner_receipts() {
  local history
  for history in orphan previous-owner; do
    make_home $'Captain session\n❯ \n  ? for shortcuts' "heartbeat-frozen-secs=600
nudge-secs=1
restart=on
restart-command=$TMP_ROOT/fake-captain.sh"
    write_fake_captain
    transcript 3000 "Working."
    run_wd 0 once >/dev/null 2>&1
    printf '%s\told\t%s\tprimary\theartbeat-frozen\tnudge\tpending\tinterrupted delivery\n' "$((BASE + 700))" "$H" >> "$H/state/watchdog/actions.tsv"
    if [ "$history" = previous-owner ]; then
      printf '%s\told\t%s\tprimary\theartbeat-frozen\tnudge\tdone\theartbeat-owner=999999:old-session:old-start\n' "$((BASE + 700))" "$H" >> "$H/state/watchdog/actions.tsv"
    fi
    run_wd 1000 once >/dev/null 2>&1
    assert_equals 0 "$(ledger_rows heartbeat-frozen restart pending)" "$history history authorized a restart"
    assert_equals 2 "$(ledger_rows heartbeat-frozen nudge pending)" "$history history prevented a fresh delivery"
    awk -F '\t' -v owner="heartbeat-owner=$LOCKPID:$SID:" '
      $5 == "heartbeat-frozen" && $6 == "nudge" && $7 == "done" && index($8, owner) == 1 { found = 1 }
      END { exit !found }
    ' "$H/state/watchdog/actions.tsv" || fail "$history case has no current-owner delivery receipt"
    run_wd 1300 once >/dev/null 2>&1
    assert_equals 1 "$(ledger_rows heartbeat-frozen restart pending)" "$history case never recovered after its own delivery"
    wait_pickup || fail "$history recovery did not prove pickup"
    LOCK_PIDS="$LOCK_PIDS $(cat "$H/state/.lock")"
  done
  pass "orphan pending rows and another owner's delivery cannot authorize heartbeat restart"
}

test_heartbeat_recovery_serializes_with_handoff_launch() {
  local ready release holder n
  make_home $'Captain session\n❯ \n  ? for shortcuts' "heartbeat-frozen-secs=600
restart=on
restart-command=$TMP_ROOT/fake-captain.sh"
  write_fake_captain
  transcript 3000 "Working."
  run_wd 0 once >/dev/null 2>&1
  run_wd 700 once >/dev/null 2>&1
  ready=$H/launch-ready
  release=$H/launch-release
  FM_HOME="$H" STATE="$H/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$2" || exit 1
    : > "$3"
    n=0
    while [ ! -e "$4" ] && [ "$n" -lt 600 ]; do sleep 0.1; n=$((n + 1)); done
    fm_lock_release "$2"
  ' _ "$ROOT" "$H/state/.handoff-launch.lock" "$ready" "$release" &
  holder=$!
  n=0
  while [ ! -e "$ready" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done
  [ -e "$ready" ] || fail "the isolated launch owner did not acquire its lock"
  run_wd 1000 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows heartbeat-frozen restart pending)" "heartbeat recovery raced a launch before its claim existed"
  : > "$release"
  wait "$holder" || fail "the isolated launch owner did not release its lock"
  run_wd 1100 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows heartbeat-frozen restart pending)" "recovery did not resume after launch serialization cleared"
  wait_pickup || fail "serialized recovery did not prove pickup"
  LOCK_PIDS="$LOCK_PIDS $(cat "$H/state/.lock")"
  pass "heartbeat recovery shares the existing launch lock before restarting"
}

test_heartbeat_recovery_respects_recent_wake_activity() {
  make_home $'Captain session\n❯ \n  ? for shortcuts' "heartbeat-frozen-secs=600
restart=on
restart-command=$TMP_ROOT/fake-captain.sh"
  write_fake_captain
  transcript 3000 "Working."
  run_wd 0 once >/dev/null 2>&1
  run_wd 700 once >/dev/null 2>&1
  printf '%s\tack\tg1\t1\t1\t["handled"]\n' "$((BASE + 950))" > "$H/state/wake-ledger.tsv"
  run_wd 1000 once >/dev/null 2>&1
  assert_equals 0 "$(ledger_rows heartbeat-frozen restart pending)" "a recent own wake acknowledgement was ignored"
  assert_contains "$(act_rows "$H")" $'\twake-ack\t50' "the recent activity source was not observed"
  kill -0 "$LOCKPID" 2>/dev/null || fail "a responsive session was stopped"
  pass "heartbeat recovery respects the newest verified session activity source"
}

test_heartbeat_recovery_requires_a_known_activity_source() {
  make_home $'Captain session\n❯ \n  ? for shortcuts' 'heartbeat-frozen-secs=600
restart=on
restart-command=/bin/false'
  run_wd 0 once >/dev/null 2>&1
  run_wd 700 once >/dev/null 2>&1
  run_wd 1000 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows heartbeat-frozen detect held)" "the source-less heartbeat case was not observed"
  assert_equals 0 "$(ledger_rows heartbeat-frozen nudge pending)" "unknown activity was treated as idle"
  assert_equals 0 "$(ledger_rows heartbeat-frozen restart pending)" "unknown activity authorized restart"
  kill -0 "$LOCKPID" 2>/dev/null || fail "a session with unknown activity was stopped"
  pass "heartbeat recovery preserves main's verified activity-source requirement"
}

# --- human-only steps ----------------------------------------------------------

HS_LOGIN=$'Claude Code can be used with your Claude subscription or billed based on API usage.\n\nSelect login method:\n\n ❯ 1. Claude account with subscription\n   2. Anthropic Console account\n   3. 3rd-party platform'
HS_OTP=$'! First copy your one-time code: 8F3A-21C4\nPress Enter to open github.com in your browser...'
HS_CODE=$'We sent a code to your email.\nEnter verification code: '

# hs_base <day|night>: the next Wednesday after today at 12:00 or 23:30 in the
# default quiet-hours zone (America/Costa_Rica, UTC-6 all year), so the day and
# night cases never depend on when the suite runs.
hs_base() {
  local d
  d=$(( $(date +%s) / 86400 + 1 ))
  while [ $(( (d + 4) % 7 )) -ne 3 ]; do d=$((d + 1)); done
  case "$1" in
    day) printf '%s\n' $((d * 86400 + 18 * 3600)) ;;
    weekend) printf '%s\n' $(((d + 3) * 86400 + 18 * 3600)) ;;
    *) printf '%s\n' $((d * 86400 + 29 * 3600 + 1800)) ;;
  esac
}

# hs_screen <text>: replace what the home pane shows.
hs_screen() {
  printf '%s\n' "$1" > "$H/screen.txt"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" respawn-pane -k -t "$T" "$H/agent.sh"
  sleep 0.5
}

hs_rows() {  # <subject> <channel>
  awk -F'\t' -v s="$1" -v c="$2" '$2 == s && $5 == c' "$H/state/watchdog/human-steps.tsv" 2>/dev/null | wc -l | tr -d ' '
}

test_human_step_detection() {
  assert_equals sign-in "$(lib fm_wd_human_step "$HS_LOGIN")" "the Claude login picker is a sign-in step"
  assert_equals otp "$(lib fm_wd_human_step "$HS_OTP")" "a one-time device code is an OTP step"
  assert_equals verification-code "$(lib fm_wd_human_step "$HS_CODE")" "a verification-code prompt"
  assert_equals verification-code "$(lib fm_wd_human_step $'Browser did not open? Use the url below to sign in\nPaste code here if prompted > ')" "the pasted sign-in code prompt"
  assert_equals captcha "$(lib fm_wd_human_step $'Please verify you are human.\nComplete the CAPTCHA to continue.')" "a captcha"
  assert_equals approval "$(lib fm_wd_human_step $'Waiting for approval on your other device...\nCheck your phone to approve this sign-in.')" "a device approval wait"
  assert_equals sign-in "$(lib fm_wd_human_step $'API Error: 401 · Please run /login\n❯ \n  ? for shortcuts')" "a sign-in error above the composer"
  assert_equals sign-in "$(lib fm_wd_human_step $'Login expired · Please run /login\n❯ \n  ? for shortcuts')" "an expired login above the composer is a sign-in step"
  assert_equals sign-in "$(lib fm_wd_human_step $'Failed to authenticate: OAuth session expired and could not be refreshed\n❯ \n  ? for shortcuts')" "an expired OAuth session above the composer is a sign-in step"
  assert_equals sign-in "$(lib fm_wd_human_step 'Login expired · Please run /login')" "a standalone expired login is a sign-in step"
  assert_equals sign-in "$(lib fm_wd_human_step 'Failed to authenticate: OAuth session expired and could not be refreshed')" "a standalone expired OAuth session is a sign-in step"
  assert_equals "" "$(lib fm_wd_human_step $'I documented Login expired · Please run /login and Failed to authenticate: OAuth session expired.\n❯ \n  ? for shortcuts')" "conversation that mentions expired login errors is not a step"
  assert_equals "" "$(lib fm_wd_human_step $'I updated the sign in to GitHub docs and the OTP section.\nThe verification code flow is unchanged.\n❯ \n  ? for shortcuts')" "conversation that mentions a sign-in is not a step"
  assert_equals "" "$(lib fm_wd_human_step $'Captain session\n❯ \n  ? for shortcuts')" "a plain composer is not a step"
  assert_equals "" "$(lib fm_wd_human_step $'Do you want to proceed?\n ❯ 1. Yes\n   2. No\n\nEsc to cancel')" "a permission dialog is not a step"
  assert_equals "" "$(lib fm_wd_human_step $'Bash command\n\n  npm test -- auth/mfa.test.ts\n  Run the 2FA tests\n\nDo you want to proceed?\n ❯ 1. Yes\n   2. Yes, and don\'t ask again for npm test commands in /w/fm-2fa-flow\n   3. No\n\nEsc to cancel')" "a permission dialog for an MFA command is not a step"
  assert_equals "" "$(lib fm_wd_human_step $'Edit file\n  auth/mfa.ts\n  1 export const x = 1\nDo you want to make this edit to mfa.ts?\n ❯ 1. Yes\n   2. Yes, allow all edits during this session (shift+tab)\n   3. No, and tell Claude what to do differently (esc)\n\nEsc to cancel')" "an edit dialog for an MFA file is not a step"
  assert_equals "" "$(lib fm_wd_human_step $'Create file\n  otp-verify.ts\n  1 export {}\nDo you want to create otp-verify.ts?\n ❯ 1. Yes\n   2. Yes, allow all edits during this session (shift+tab)\n   3. No, and tell Claude what to do differently (esc)\n\nEsc to cancel')" "a create dialog for an OTP file is not a step"
  assert_equals "" "$(lib fm_wd_human_step $'Working on the MFA enrolment.\n────────────────────────────────────────\n❯ \n────────────────────────────────────────\n  fm/fm-mfa-enroll · ~/w/fm-2fa-flow · ? for shortcuts')" "a branch name in the status line is not a step"
  assert_equals "" "$(lib fm_wd_human_step $'GitHub needs you to sign in to continue before the push.\n> 1. merge the PR\n  2. then clean up')" "an echoed numbered prompt under a sign-in reply is not a step"
  assert_equals "" "$(lib fm_wd_human_step $'The 2FA and otp checks pass now.\n> 1. merge it')" "a numbered composer draft under a 2FA reply is not a step"
  assert_equals "" "$(lib fm_wd_human_step $'Working on the mirror.\n────────────────────────────────────────\n❯ check whether\n  authentication is required for the mirror\n────────────────────────────────────────\n  ? for shortcuts')" "a wrapped composer draft that mentions authentication is not a step"
  assert_equals "" "$(lib fm_wd_human_step $'Working.\n────────────────────────────────────────\n❯ check auth\n\n Also update 2FA tests\n────────────────────────────────────────\n  ? for shortcuts')" "a blank line inside a ruled draft does not expose draft text as a step"
  assert_equals "" "$(lib fm_wd_human_step $'Working.\n────────────────────────────────────────\n❯ check auth\n\n Also update 2FA tests\n────────────────────────────────────────')" "a composer rule alone excludes multiline draft text"
  assert_equals "" "$(lib fm_wd_human_step $'Working.\n❯ check auth\n\n Also update 2FA tests\n  ? for shortcuts')" "a composer footer alone excludes multiline draft text"
  local long_draft=$'❯ check auth\n\n Also update 2FA tests' i
  for i in {1..16}; do long_draft+=$'\n More draft text'; done
  long_draft+=$'\n Also update OTP tests\n────────────────────────────────────────\n  ? for shortcuts'
  assert_equals "" "$(lib fm_wd_human_step "$long_draft")" "a long draft whose prompt is outside the detection window is not a step"
  assert_equals "" "$(lib fm_wd_human_step $' Also update OTP tests\n More draft text\n────────────────────────────────────────\n  ? for shortcuts')" "a cropped composer with no visible prompt is not a step"
  assert_equals "" "$(lib fm_wd_human_step $'Working on the login flow.\n❯ next, enable the\n  2fa check and sign in to the staging app')" "a borderless wrapped draft that mentions 2FA and sign-in is not a step"
  assert_equals verification-code "$(lib fm_wd_human_step $'❯ /login\n\nBrowser did not open? Use the url below to sign in\nPaste code here if prompted > ')" "a sign-in prompt below an echoed turn, with no composer under it"
  assert_equals otp "$(lib fm_wd_human_step $'❯ push the PR\n\n! First copy your one-time code: 8F3A-21C4\nPress Enter to open github.com in your browser...')" "a device code below an echoed turn, with no composer under it"
  assert_equals "" "$(lib fm_wd_human_step $'❯ push the PR\n\n! First copy your one-time code: 8F3A-21C4\n\n────────────────────────────────────────\n❯ \n────────────────────────────────────────\n  ? for shortcuts')" "conversation above a live composer is not a step"
  assert_equals "" "$(lib fm_wd_human_step $'I set up the sign in to GitHub docs.\n› \n\n  ? for shortcuts   100% context left')" "an empty row and one footer row under a composer are not an echoed turn"
  assert_equals "" "$(lib fm_wd_human_step $'Would you like to run the following command?\n\n  $ op item get gh --otp\n\n› 1. Yes, proceed (y)\n  2. Yes, and don\'t ask again for this command (a)\n  3. No, and tell Codex what to do differently (esc)\n\n  Press enter to confirm or esc to cancel')" "a Codex command approval for an OTP command is not a step"
  assert_equals "" "$(lib fm_wd_human_step $'  Would you like to run the following command?\n\n  $ op item get gh --otp\n\n  › 1. Yes, proceed (y)\n    2. No, and tell Codex what to do differently (esc)\n\n  Press enter to confirm or esc to cancel')" "an indented Codex command approval for an OTP command is not a step"
  assert_equals "" "$(lib fm_wd_human_step $'I set up 2FA on the account earlier.\n\nContinue with paid usage?\n ❯ Yes\n   No\n\n Enter to confirm · Esc to cancel')" "conversation above an unnumbered picker is not a step"
  assert_equals sign-in "$(lib fm_wd_human_step $'Working.\n\nSign in to continue:\n ❯ Open the browser\n   Paste a token\n\n Enter to confirm · Esc to cancel')" "an unnumbered sign-in picker is a step"
  assert_equals sign-in "$(lib fm_wd_human_step $'Earlier: Do you want to proceed?\n\nSign in to continue:\n ❯ Open the browser\n   Paste a token\n\n Enter to confirm · Esc to cancel')" "permission wording in conversation does not mask a sign-in picker"
  assert_equals sign-in "$(lib fm_wd_human_step $'Earlier: Do you want to proceed?\n\nSign in to continue:\n\n ❯ 1. Open the browser\n   2. Paste a token\n\n Enter to confirm · Esc to cancel')" "permission wording in conversation does not mask a numbered sign-in picker"
  pass "human-only step: sign-in, OTP, code, captcha, and approval prompts are detected, and conversation, dialogs, and status lines about them are not"
}

test_wrapped_draft_about_a_sign_in_is_unsent_input_not_a_step() {
  make_home "Working on the mirror."$'\n'"$(ruled $'> check whether\n  authentication is required for the mirror' '  ? for shortcuts')"
  transcript 100 "Working."
  local off
  for off in 0 400 800 1200; do FM_WD_TEST_COMPOSER=pending run_wd "$off" once >/dev/null 2>&1; done
  assert_equals 0 "$(ledger | awk -F'\t' '$5 == "human-step"' | wc -l | tr -d ' ')" "a draft that mentions authentication is escalated as a step: $(ledger | cut -f5-8)"
  assert_no_grep "human-only" "$H/data/watchdog/status.md" "a draft is reported as a human-only step"
  assert_equals 1 "$(ledger_rows pasted-input key pending)" "the held draft still gets its one Enter: $(ledger | cut -f5-8)"
  pass "human-only step: a wrapped composer draft that mentions a sign-in is unsent input, not a step"
}

test_human_step_pages_once_after_ten_minutes_and_is_never_typed_into() {
  local BASE off
  BASE=$(hs_base day)
  make_home "$HS_LOGIN" $'restart=on\nrestart-command=true\nissue-repo=example.invalid/owner/repo'
  transcript 3000 "Working."
  owe_input 3000
  printf '%s\n' "$LOCKPID" > "$H/state/.supervise-daemon.pid"
  printf 'needs-decision [at=%s] [key=cache-layout]: A or B?\n' "$((BASE - 9000))" > "$H/state/t1.status"
  printf "command:cat >> '%s'\n" "$H/paged.log" > "$H/config/wedge-alarm"
  for off in 0 300 540; do
    run_wd "$off" once >/dev/null 2>&1 || fail "human-step pass at +${off}s failed"
  done
  assert_equals 0 "$(ledger | awk -F'\t' '$5 == "human-step"' | wc -l | tr -d ' ')" "a step under ten minutes was escalated: $(ledger | cut -f4-8)"
  [ ! -e "$H/paged.log" ] || fail "a step under ten minutes paged the owner: $(cat "$H/paged.log")"
  assert_grep "human-only sign-in step" "$H/data/watchdog/status.md" "the waiting step is a reported gap"
  assert_grep "HUMAN-STEP" "$H/data/watchdog/status.md" "the health line does not read the step as normal work"
  assert_no_grep ": ok," "$H/data/watchdog/status.md" "a pane waiting on a human step read as ok"

  run_wd 600 once >/dev/null 2>&1 || fail "the ten-minute pass failed"
  assert_equals 1 "$(ledger_rows human-step page pending)" "a step over ten minutes is escalated: $(ledger | cut -f4-8)"
  assert_equals 1 "$(ledger_rows human-step page "done")" "the escalation page was delivered: $(ledger | cut -f4-8)"
  assert_grep "human-only sign-in step has waited 10 minutes" "$H/paged.log" "the page names the step and its wait"
  assert_no_grep "Select login method" "$H/paged.log" "the page carries no pane text"
  assert_equals 1 "$(hs_rows "$(basename "$H")" page)" "the escalation is recorded: $(cat "$H/state/watchdog/human-steps.tsv" 2>/dev/null)"

  for off in 700 1700 4000 9000; do
    FM_WD_TEST_COMPOSER=pending run_wd "$off" once >/dev/null 2>&1 || fail "pass at +${off}s failed"
  done
  assert_equals 1 "$(ledger_rows human-step page pending)" "one episode is escalated once: $(ledger | cut -f4-8)"
  sleep 1
  [ ! -s "$H/typed.log" ] || fail "the watchdog typed into a human-only step: $(cat "$H/typed.log")"
  assert_equals 0 "$(ledger | awk -F'\t' '$6 ~ /^(nudge|key|restart|council|self-heal)$/' | wc -l | tr -d ' ')" "a key, nudge, restart, council, or issue reached the step: $(ledger | cut -f4-8)"
  wd_pid_alive_check "$LOCKPID" || fail "the session holding the step was killed"
  pass "human-only step: escalated once after ten minutes by day, never typed into, restarted, or nudged"
}

test_human_step_overnight_reports_only_what_it_recorded() {
  local BASE
  BASE=$(hs_base night)
  make_home "$HS_OTP" 'mode=dry-run'
  transcript 100 "Working."
  run_wd 0 once >/dev/null 2>&1
  run_wd 600 once >/dev/null 2>&1
  assert_grep "would be recorded for the morning handoff" "$H/data/watchdog/status.md" "a dry run reports the record it would write"
  assert_no_grep "; recorded for the morning handoff" "$H/data/watchdog/status.md" "a dry run claims a record it never wrote"
  assert_equals 0 "$(hs_rows "$(basename "$H")" morning-handoff)" "a dry run writes no morning-handoff row"

  # A record that cannot be written is reported as such, never as recorded.
  make_home "$HS_OTP"
  transcript 100 "Working."
  mkdir -p "$H/state/watchdog/human-steps.tsv"
  run_wd 0 once >/dev/null 2>&1
  run_wd 600 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows human-step handoff failed)" "the failed write is on record: $(ledger | cut -f4-8)"
  assert_grep "morning-handoff record could not be written" "$H/data/watchdog/status.md" "a failed write is reported"
  assert_no_grep "; recorded for the morning handoff" "$H/data/watchdog/status.md" "a failed write claims a record"
  pass "human-only step: overnight, the status names a dry run or a failed write, never a record that was not written"
}

test_human_step_daytime_dry_run_names_the_page_it_would_send() {
  local BASE
  BASE=$(hs_base day)
  make_home "$HS_LOGIN" 'mode=dry-run'
  transcript 100 "Working."
  printf '%s\n' "$LOCKPID" > "$H/state/.supervise-daemon.pid"
  printf "command:cat >> '%s'\n" "$H/paged.log" > "$H/config/wedge-alarm"
  run_wd 0 once >/dev/null 2>&1 || fail "the first daytime dry-run pass failed"
  run_wd 600 once >/dev/null 2>&1 || fail "the ten-minute daytime dry-run pass failed"
  assert_grep "would page the owner" "$H/data/watchdog/status.md" "a daytime dry run names the page it would send"
  assert_no_grep "its escalation is retried after nudge-secs" "$H/data/watchdog/status.md" "a daytime dry run that never paged claims a retry"
  assert_equals 1 "$(ledger_rows human-step page dry-run)" "the dry run is on the ledger: $(ledger | cut -f4-8)"
  assert_equals 0 "$(ledger_rows human-step page pending)" "a dry run opened a page: $(ledger | cut -f4-8)"
  assert_equals 0 "$(ledger_rows human-step page "done")" "a dry run delivered a page: $(ledger | cut -f4-8)"
  [ ! -e "$H/paged.log" ] || fail "a daytime dry run paged the owner: $(cat "$H/paged.log")"
  sleep 1
  [ ! -s "$H/typed.log" ] || fail "a daytime dry run typed into the step: $(cat "$H/typed.log")"
  pass "human-only step: a daytime dry run names the page it would send and sends none"
}

test_human_step_overnight_goes_to_the_morning_handoff() {
  local BASE
  BASE=$(hs_base night)
  make_home "$HS_OTP"
  transcript 100 "Working."
  printf '%s\n' "$LOCKPID" > "$H/state/.supervise-daemon.pid"
  printf "command:cat >> '%s'\n" "$H/paged.log" > "$H/config/wedge-alarm"
  run_wd 0 once >/dev/null 2>&1
  run_wd 600 once >/dev/null 2>&1
  assert_grep "recorded for the morning handoff" "$H/data/watchdog/status.md" "the handoff is reported"
  run_wd 1800 once >/dev/null 2>&1
  [ ! -e "$H/paged.log" ] || fail "a step in quiet hours paged the owner: $(cat "$H/paged.log")"
  assert_equals 0 "$(ledger_rows human-step page pending)" "quiet hours sent a page: $(ledger | cut -f4-8)"
  assert_equals 1 "$(ledger_rows human-step handoff "done")" "the step went into the morning handoff once: $(ledger | cut -f4-8)"
  assert_equals 1 "$(hs_rows "$(basename "$H")" morning-handoff)" "the morning-handoff row was written"

  hs_screen $'Captain session\n❯ \n  ? for shortcuts'
  run_wd 2000 once >/dev/null 2>&1
  assert_equals 1 "$(hs_rows "$(basename "$H")" cleared)" "a step that left the pane closes its handoff row"
  hs_screen "$HS_OTP"
  run_wd 2100 once >/dev/null 2>&1
  run_wd 2800 once >/dev/null 2>&1
  assert_equals 2 "$(ledger_rows human-step handoff "done")" "a new episode is escalated again: $(ledger | cut -f4-8)"

  # Saturday noon is inside the weekend quiet window, so it is overnight too.
  BASE=$(hs_base weekend)
  make_home "$HS_CODE"
  transcript 100 "Working."
  printf '%s\n' "$LOCKPID" > "$H/state/.supervise-daemon.pid"
  printf "command:cat >> '%s'\n" "$H/paged.log" > "$H/config/wedge-alarm"
  run_wd 0 once >/dev/null 2>&1
  run_wd 600 once >/dev/null 2>&1
  [ ! -e "$H/paged.log" ] || fail "a weekend step paged the owner: $(cat "$H/paged.log")"
  assert_equals 1 "$(ledger_rows human-step handoff "done")" "a weekend step went into the morning handoff: $(ledger | cut -f4-8)"

  # Away or quiet mode by day is not overnight: the step is still paged.
  local mode
  for mode in away quiet; do
    BASE=$(hs_base day)
    make_home "$HS_CODE"
    transcript 100 "Working."
    printf '%s\n' "$LOCKPID" > "$H/state/.supervise-daemon.pid"
    printf "command:cat >> '%s'\n" "$H/paged.log" > "$H/config/wedge-alarm"
    if [ "$mode" = quiet ]; then printf 'quiet\n' > "$H/state/.afk"; else : > "$H/state/.afk"; fi
    run_wd 0 once >/dev/null 2>&1
    run_wd 600 once >/dev/null 2>&1
    assert_grep "human-only verification-code step" "$H/paged.log" "a daytime step in $mode mode paged the owner"
    assert_equals 1 "$(ledger_rows human-step page "done")" "a daytime step in $mode mode was paged once: $(ledger | cut -f4-8)"
    assert_equals 0 "$(ledger_rows human-step handoff "done")" "a daytime step in $mode mode was held for the morning: $(ledger | cut -f4-8)"
    [ ! -s "$H/typed.log" ] || fail "the watchdog typed into a step in $mode mode: $(cat "$H/typed.log")"
  done
  pass "human-only step: overnight and weekend steps are recorded for the morning handoff and never paged; daytime away and quiet still page"
}

test_human_step_overnight_handoff_is_paged_by_day_unless_briefed() {
  local BASE since
  BASE=$(hs_base night)
  make_home "$HS_OTP"
  transcript 100 "Working."
  printf '%s\n' "$LOCKPID" > "$H/state/.supervise-daemon.pid"
  printf "command:cat >> '%s'\n" "$H/paged.log" > "$H/config/wedge-alarm"
  run_wd 0 once >/dev/null 2>&1
  run_wd 600 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows human-step handoff "done")" "the overnight step went into the morning handoff: $(ledger | cut -f4-8)"
  [ ! -e "$H/paged.log" ] || fail "an overnight step paged the owner: $(cat "$H/paged.log")"
  # 08:30 the next morning, outside away mode: nobody has seen the handoff.
  run_wd 32400 once >/dev/null 2>&1
  assert_grep "human-only otp step" "$H/paged.log" "a handed-off step still showing by day was never paged"
  assert_equals 1 "$(ledger_rows human-step page "done")" "the morning page was not recorded: $(ledger | cut -f4-8)"
  run_wd 33400 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows human-step page pending)" "the morning page was sent again: $(ledger | cut -f4-8)"

  # A handoff the away return brief already showed counts as delivered.
  make_home "$HS_OTP"
  transcript 100 "Working."
  printf '%s\n' "$LOCKPID" > "$H/state/.supervise-daemon.pid"
  printf "command:cat >> '%s'\n" "$H/paged.log" > "$H/config/wedge-alarm"
  run_wd 0 once >/dev/null 2>&1
  run_wd 600 once >/dev/null 2>&1
  since=$(awk -F'\t' '$5 == "morning-handoff" { print $4 }' "$H/state/watchdog/human-steps.tsv")
  printf '%s\t%s\totp\t%s\tbriefed\n' "$((BASE + 30000))" "$(basename "$H")" "$since" >> "$H/state/watchdog/human-steps.tsv"
  run_wd 32400 once >/dev/null 2>&1
  [ ! -e "$H/paged.log" ] || fail "a briefed handoff was paged again: $(cat "$H/paged.log")"
  assert_equals 0 "$(ledger_rows human-step page pending)" "a briefed handoff was paged: $(ledger | cut -f4-8)"
  pass "human-only step: an overnight handoff still showing by day is paged once, unless the away return brief showed it"
}

test_human_step_removed_worker_closes_its_handoff() {
  local BASE
  BASE=$(hs_base night)
  make_home $'Captain session\n❯ \n  ? for shortcuts'
  transcript 100 "Working."
  worker_pane auth ship "$HS_OTP"
  sleep 0.5
  printf '%s\n' "$LOCKPID" > "$H/state/.supervise-daemon.pid"
  run_wd 0 once >/dev/null 2>&1
  run_wd 600 once >/dev/null 2>&1
  assert_equals 1 "$(hs_rows worker:auth morning-handoff)" "the worker step went into the morning handoff: $(cat "$H/state/watchdog/human-steps.tsv" 2>/dev/null)"
  [ -e "$H/state/watchdog/human-step/$(home_key)-worker_auth" ] || fail "the worker episode was not recorded"
  rm -f "$H/state/auth.meta"
  run_wd 700 once >/dev/null 2>&1
  assert_equals 1 "$(hs_rows worker:auth cleared)" "a removed worker left its handoff open: $(cat "$H/state/watchdog/human-steps.tsv" 2>/dev/null)"
  [ ! -e "$H/state/watchdog/human-step/$(home_key)-worker_auth" ] || fail "a removed worker left its episode behind"
  run_wd 800 once >/dev/null 2>&1
  assert_equals 1 "$(hs_rows worker:auth cleared)" "the removed worker's handoff was closed twice"
  pass "human-only step: a worker no longer recorded in the home closes its morning-handoff row"
}

test_human_step_undelivered_page_falls_back_to_the_record() {
  local BASE subject
  BASE=$(hs_base day)
  make_home "$HS_CODE"
  subject=$(basename "$H")
  transcript 100 "Working."
  printf '%s\n' "$LOCKPID" > "$H/state/.supervise-daemon.pid"
  printf 'off\n' > "$H/config/wedge-alarm"
  run_wd 0 once >/dev/null 2>&1
  run_wd 600 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows human-step page failed)" "the undelivered page is recorded: $(ledger | cut -f4-8)"
  assert_equals 0 "$(( $(ledger_rows human-step page "done") + $(ledger_rows human-step handoff "done") ))" "an undelivered page counted as an escalation: $(ledger | cut -f4-8)"
  assert_equals 1 "$(hs_rows "$subject" morning-handoff)" "the step was recorded so it stays visible"
  assert_grep "not paged" "$H/data/watchdog/status.md" "the unpaged step is a reported gap"
  run_wd 700 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows human-step page pending)" "the page was retried inside nudge-secs: $(ledger | cut -f4-8)"
  run_wd 1500 once >/dev/null 2>&1
  assert_equals 2 "$(ledger_rows human-step page failed)" "the page was not retried after nudge-secs: $(ledger | cut -f4-8)"
  assert_equals 1 "$(hs_rows "$subject" morning-handoff)" "a retry duplicated the record"

  # The channel recovers: the next retry delivers the page, and the record
  # stays open until the step leaves the pane.
  printf "command:cat >> '%s'\n" "$H/paged.log" > "$H/config/wedge-alarm"
  run_wd 2500 once >/dev/null 2>&1
  assert_grep "human-only verification-code step" "$H/paged.log" "the recovered channel was never used"
  assert_equals 1 "$(ledger_rows human-step page "done")" "the delivered page was not recorded: $(ledger | cut -f4-8)"
  run_wd 3500 once >/dev/null 2>&1
  assert_equals 3 "$(ledger_rows human-step page pending)" "a delivered page was sent again: $(ledger | cut -f4-8)"
  assert_equals 0 "$(hs_rows "$subject" cleared)" "the record closed while the step still showed"
  hs_screen $'Captain session\n❯ \n  ? for shortcuts'
  run_wd 3600 once >/dev/null 2>&1
  assert_equals 1 "$(hs_rows "$subject" cleared)" "the record stayed open after the step left the pane"
  [ ! -s "$H/typed.log" ] || fail "the watchdog typed into the step: $(cat "$H/typed.log")"
  pass "human-only step: an undelivered page stays pending and visible, is retried after nudge-secs, and reaches a recovered channel"
}

test_human_step_daytime_handoff_write_failure_is_reported_and_retried() {
  if [ "$(id -u)" = 0 ]; then pass "human-step write failure # SKIP root can write permission-denied fixtures"; return; fi
  local BASE subject record episode
  BASE=$(hs_base day)
  make_home "$HS_CODE" 'human-step-secs=0'
  transcript 100 "Working."
  subject=$(basename "$H")
  record=$H/state/watchdog/human-steps.tsv
  episode=$H/state/watchdog/human-step/$(home_key)
  printf 'off\n' > "$H/config/wedge-alarm"
  mkdir -p "${record%/*}"
  : > "$record"
  chmod a-w "$record"
  run_wd 0 once >/dev/null 2>&1 || fail "the failed daytime handoff pass failed"
  assert_equals 1 "$(ledger_rows human-step page failed)" "the failed page is not recorded"
  assert_equals 1 "$(ledger_rows human-step handoff failed)" "the failed daytime handoff is not recorded"
  assert_equals 0 "$(hs_rows "$subject" morning-handoff)" "the unwritable record contains a handoff"
  assert_grep "morning-handoff record could not be written" "$H/data/watchdog/status.md" "the write failure is not reported"
  assert_no_grep "; recorded," "$H/data/watchdog/status.md" "the failed append claims persistence"
  [ -f "$episode" ] || fail "the failed handoff lost its episode"
  chmod u+w "$record"
  run_wd 900 once >/dev/null 2>&1 || fail "the daytime handoff retry failed"
  assert_equals 1 "$(hs_rows "$subject" morning-handoff)" "the recovered writer was not retried"
  assert_grep "; recorded," "$H/data/watchdog/status.md" "the successful retry is not reported"
  pass "human-only step: a failed daytime handoff reports the write failure and retries after recovery"
}

test_human_step_failed_clear_keeps_its_episode_for_retry() {
  if [ "$(id -u)" = 0 ]; then pass "human-step clear failure # SKIP root can write permission-denied fixtures"; return; fi
  local BASE subject record episode original
  BASE=$(hs_base night)
  make_home "$HS_OTP" 'human-step-secs=0'
  transcript 100 "Working."
  subject=$(basename "$H")
  record=$H/state/watchdog/human-steps.tsv
  episode=$H/state/watchdog/human-step/$(home_key)
  run_wd 0 once >/dev/null 2>&1 || fail "the overnight handoff pass failed"
  assert_equals 1 "$(hs_rows "$subject" morning-handoff)" "the overnight handoff was not written"
  original=$(cat "$episode")
  chmod a-w "$record"
  hs_screen $'Captain session\n❯ \n  ? for shortcuts'
  run_wd 1 once >/dev/null 2>&1 || fail "the failed handoff closure pass failed"
  assert_equals 0 "$(hs_rows "$subject" cleared)" "the unwritable record contains a closure"
  assert_equals "$original" "$(cat "$episode" 2>/dev/null)" "the failed closure lost its episode"
  assert_grep "morning-handoff record could not be cleared" "$H/data/watchdog/status.md" "the failed closure is not reported"
  chmod u+w "$record"
  run_wd 2 once >/dev/null 2>&1 || fail "the handoff closure retry failed"
  assert_equals 1 "$(hs_rows "$subject" cleared)" "the recovered writer did not close the handoff"
  [ ! -e "$episode" ] || fail "the successful closure kept its episode"
  run_wd 3 once >/dev/null 2>&1 || fail "the pass after closure failed"
  assert_equals 1 "$(hs_rows "$subject" cleared)" "the handoff was closed twice"
  pass "human-only step: a failed handoff closure keeps its episode and retries until the closure is written"
}

test_worker_human_step_keeps_other_work_moving() {
  local BASE perm_pane dialog=$'Do you want to proceed?\n ❯ 1. Yes\n   2. No, and tell Claude what to do differently\n\nEsc to cancel'
  BASE=$(hs_base day)
  make_home $'Captain session\n❯ \n  ? for shortcuts'
  transcript 100 "Working."
  worker_pane auth ship "$HS_OTP"
  worker_pane perm ship "$dialog"
  perm_pane=$WP
  worker_pane plain scout $'work output\n> '
  sleep 0.5
  printf '%s\n' "$LOCKPID" > "$H/state/.supervise-daemon.pid"
  printf 'needs-decision [at=%s] [key=cache-layout]: A or B?\n' "$((BASE - 9000))" > "$H/state/t1.status"
  printf "command:cat >> '%s'\n" "$H/paged.log" > "$H/config/wedge-alarm"
  : > "$H/state/.afk"
  run_wd 0 once >/dev/null 2>&1 || fail "the first worker pass failed"
  assert_equals 1 "$(ledger_rows dialog page "done")" "another worker's permission dialog still pages: $(ledger | cut -f4-8)"
  assert_equals 1 "$(ledger_rows decisions nudge pending)" "the home's decision nudge still goes out: $(ledger | cut -f4-8)"
  assert_grep "human-only otp step on $(basename "$H") worker auth" "$H/data/watchdog/status.md" "the worker step is a reported gap"
  run_wd 600 once >/dev/null 2>&1 || fail "the ten-minute worker pass failed"
  assert_grep "human-only otp step has waited 10 minutes on $(basename "$H") worker auth" "$H/paged.log" "a daytime away worker step was not paged"
  assert_equals 0 "$(hs_rows worker:auth morning-handoff)" "a daytime away worker step was held for the morning: $(cat "$H/state/watchdog/human-steps.tsv" 2>/dev/null)"
  sleep 1
  [ ! -s "$H/worker-auth.typed" ] || fail "the watchdog typed into the worker step: $(cat "$H/worker-auth.typed")"
  [ ! -s "$H/worker-plain.typed" ] || fail "the watchdog typed into a plain worker pane: $(cat "$H/worker-plain.typed")"
  [ ! -e "$H/state/auth.status" ] || fail "the watchdog wrote a status that could hold the worker's PR: $(cat "$H/state/auth.status")"
  assert_equals 0 "$(ledger | awk -F'\t' '$4 == "worker:auth" && $6 != "page"' | wc -l | tr -d ' ')" "the worker step got an action other than its page: $(ledger | cut -f4-8)"
  local word
  for word in merge deploy hold; do
    assert_no_grep "$word" "$H/state/watchdog/human-steps.tsv" "the record names no merge, deploy, or hold: $word"
  done

  rm -f "$H/state/.afk"
  printf '%s\n' "$HS_CODE" > "$H/worker-perm.txt"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" respawn-pane -k -t "$perm_pane" "$H/worker-perm.sh"
  sleep 0.5
  run_wd 700 once >/dev/null 2>&1
  run_wd 1300 once >/dev/null 2>&1
  assert_grep "human-only verification-code step has waited 10 minutes on $(basename "$H") worker perm" "$H/paged.log" "a worker step is paged by day: $(ledger | cut -f4-8)"
  assert_equals 1 "$(ledger | awk -F'\t' '$4 == "worker:perm" && $5 == "human-step" && $6 == "page" && $7 == "done"' | wc -l | tr -d ' ')" "the day worker page is recorded once: $(ledger | cut -f4-8)"
  pass "human-only step: a worker step is escalated on its own episode while other workers and the home keep being handled"
}

# A Codex approval that names an OTP command is a permission prompt, not a
# human-only step: the hard stop and its away page still run on the worker.
test_codex_approval_on_a_worker_is_a_hard_stop_not_a_human_step() {
  local approval=$'\n  Would you like to run the following command?\n\n  $ op item get gh --otp\n\n  › 1. Yes, proceed (y)\n    2. Yes, and don\'t ask again for this command (p)\n    3. No, and tell Codex what to do differently (esc)\n\n  Press enter to confirm or esc to cancel'
  make_home $'Captain session\n❯ \n  ? for shortcuts'
  transcript 100 "Working."
  worker_pane cx ship "$approval"
  printf 'harness=codex\n' >> "$H/state/cx.meta"
  sleep 0.5
  printf '%s\n' "$LOCKPID" > "$H/state/.supervise-daemon.pid"
  printf "command:cat >> '%s'\n" "$H/paged.log" > "$H/config/wedge-alarm"
  : > "$H/state/.afk"
  run_wd 0 once >/dev/null 2>&1 || fail "the worker pass failed"
  run_wd 600 once >/dev/null 2>&1 || fail "the ten-minute worker pass failed"
  assert_equals 0 "$(ledger | awk -F'\t' '$4 == "worker:cx" && $5 == "human-step"' | wc -l | tr -d ' ')" "the Codex approval was read as a human-only step: $(ledger | cut -f4-8)"
  assert_no_grep "human-only" "$H/data/watchdog/status.md" "the Codex approval is reported as a human-only step"
  assert_grep "permission-prompt-hardstop" "$H/state/cx.status" "the Codex credential approval got no hard stop: $(cat "$H/state/cx.status" 2>/dev/null)"
  sleep 1
  [ ! -s "$H/worker-cx.typed" ] || fail "the watchdog answered the Codex approval: $(cat "$H/worker-cx.typed")"
  pass "permission prompt: a Codex approval naming an OTP command on a worker is a hard stop, not a human-only step"
}

test_worker_permission_blocker_clears_on_a_human_step() {
  local BASE pane open screen off=0 approval=$'  Would you like to run the following command?\n\n  $ gh auth login\n\n  › 1. Yes, proceed (y)\n    2. No, and tell Codex what to do differently (esc)\n\n  Press enter to confirm or esc to cancel'
  BASE=$(hs_base day)
  make_home $'Captain session\n❯ \n  ? for shortcuts' 'human-step-secs=0'
  transcript 100 "Working."
  worker_pane cx ship "$approval"
  pane=$WP
  printf 'harness=codex\n' >> "$H/state/cx.meta"
  printf "command:cat >> '%s'\n" "$H/paged.log" > "$H/config/wedge-alarm"
  sleep 0.5
  run_wd 0 once >/dev/null 2>&1 || fail "the tool-approval pass failed"
  grep -Eq '^blocked .*\[key=permission-prompt-hardstop\]' "$H/state/cx.status" || fail "the sign-in command did not create a permission hard stop"

  for screen in "$HS_OTP" $'Earlier: Do you want to proceed?\n\nSign in to continue:\n ❯ Open the browser\n   Paste a token\n\n Enter to confirm · Esc to cancel'; do
    off=$((off + 1))
    printf '%s\n' "$screen" > "$H/worker-cx.txt"
    "$REAL_TMUX" -f /dev/null -L "$SOCKET" respawn-pane -k -t "$pane" "$H/worker-cx.sh"
    sleep 0.5
    run_wd "$off" once >/dev/null 2>&1 || fail "the human-step pass failed"
    grep -Eq '^resolved .*\[key=permission-prompt-hardstop\]' "$H/state/cx.status" || fail "the obsolete permission hard stop was not resolved"
    open=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$H/state/cx.status") || fail "the worker status could not be read"
    assert_equals "" "$open" "the human-only step left an open blocker: $open"
  done
  assert_equals 1 "$(ledger | awk -F'\t' '$4 == "worker:cx" && $5 == "human-step" && $6 == "page" && $7 == "done"' | wc -l | tr -d ' ')" "the human-only step was not escalated"
  assert_grep "human-only otp step" "$H/paged.log" "the device-code page was not delivered"
  sleep 1
  [ ! -s "$H/worker-cx.typed" ] || fail "the watchdog typed into the approval or device-code step: $(cat "$H/worker-cx.typed")"
  pass "human-only step: replacing a tool approval resolves its permission blocker without typing into the worker"
}

if [ "$#" -gt 0 ]; then
  fm_test_run "$@"
  exit
fi

fm_test_run \
  test_dialog_detection \
  test_feedback_claim_recovery_serializes_contenders \
  test_feedback_claim_recovers_legacy_owner \
  test_feedback_claim_release_preserves_another_owner \
  test_watchdog_rearms_uncertain_feedback_on_primary_and_worker \
  test_feedback_uncertain_dismissal_reopens \
  test_feedback_and_bug_report_dialog_dismissal \
  test_mtime_uses_the_platform_stat_dialect \
  test_dismissed_dialog_in_scrollback_is_not_showing \
  test_dialog_keys_stop_after_two_failures \
  test_statusline_percentage_does_not_rearm_feedback_dismiss \
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
  test_seat_family_derivation \
  test_decisions_act_while_everything_else_stays_dry_run \
  test_decisions_key_follows_mode_and_can_hold_it_back \
  test_one_family_council_is_refused_without_a_call \
  test_council_outcome_is_final_for_its_decision \
  test_council_with_no_answer_is_not_a_convening \
  test_council_calls_use_their_own_budget_and_time_limit \
  test_council_command_rules_now_once_and_types_nothing \
  test_council_keeps_dashed_decision_identities_separate \
  test_council_checks_stored_identity_and_replays_legacy_records \
  test_council_requires_durable_publication \
  test_council_checks_the_complete_record_before_calling_seats \
  test_council_never_shortens_a_prompt_to_the_judge_limit \
  test_council_dry_run_withholds_an_existing_ruling \
  test_council_does_not_expire_a_live_owner \
  test_council_stale_reclaim_excludes_a_second_contender \
  test_concurrent_councils_keep_their_prompts_separate \
  test_council_never_reads_stale_input_after_a_prompt_write_failure \
  test_council_checks_split_reserved_words_before_normalizing_a_file \
  test_council_replay_reads_only_one_metadata_header \
  test_council_replay_validates_the_recorded_vote_outcome \
  test_council_rejects_additional_metadata_blocks \
  test_council_uses_portable_identity_paths \
  test_council_rejects_malformed_or_unknown_header_content \
  test_council_refuses_oversized_context_before_replay \
  test_council_requires_the_seats_field_separator \
  test_automatic_decisions_refuse_oversized_recorded_context \
  test_council_command_honours_the_dry_run_switch \
  test_council_runs_one_at_a_time_per_decision \
  test_awaiting_approval_reaches_council_despite_merge_word \
  test_known_unreachable_timing_flake_defaults_approve_not_clean \
  test_council_revisit_on_contradicting_record \
  test_decision_nudge_names_pr_by_number \
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
  test_no_quota_check_while_restart_awaits_pickup \
  test_mate_warning_holds_while_its_parent_restart_awaits_pickup \
  test_dead_captain_restarts_despite_its_anchor \
  test_watchdog_allows_muse_restart_with_approval_flag \
  test_watchdog_adds_yolo_to_bare_muse_restart \
  test_watchdog_leaves_non_muse_restart_unchanged \
  test_dead_holder_is_not_hidden_by_earlier_symptoms \
  test_low_context_waits_for_full_handoff_then_restarts \
  test_low_context_timeout_restarts_with_lean_handoff \
  test_low_context_restart_rechecks_a_failed_launch \
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
  test_away_bash_prompt_row_keeps_the_command \
  test_worker_permission_dialog_pages_the_owner \
  test_worker_credential_page_withholds_typed_values \
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
  test_second_mate_zero_exit_relaunch_is_not_done \
  test_second_mate_restart_done_after_session_start_under_new_lock \
  test_second_mate_session_start_after_the_window_is_not_done \
  test_reserved_model_switch_dialog_is_held \
  test_secret_looking_decision_reaches_no_council \
  test_worker_human_step_key_is_held_for_the_owner \
  test_secret_looking_model_switch_dialog_is_held \
  test_model_switch_judge_is_rate_limited \
  test_worker_dialog_key_does_not_close_home_key_window \
  test_usage_limit_unknown_harness_queues \
  test_claude_pinned_secondmate_with_tooling_gets_no_codex_pick \
  test_ordinary_home_claude_json_mcp_blocks_the_move \
  test_codex_task_keeps_same_harness_candidates_under_a_claude_pin \
  test_usage_limit_claude_without_tooling_names_a_pick \
  test_unreadable_claude_account_pin_gets_no_pick \
  test_worker_usage_limit_names_a_pick \
  test_quota_guard_checks_at_kickoff_and_periodically \
  test_quota_guard_act_nudges_after_any_check \
  test_quota_guard_act_never_nudges_a_human_step_pane \
  test_quota_guard_nudge_names_each_move_with_a_quoted_home \
  test_quota_guard_nudge_retries_a_failed_send_and_skips_a_dead_primary \
  test_quota_guard_nudge_skips_a_holder_that_died_during_the_check \
  test_autowait_footers_on_a_mate_and_a_worker_are_limit_warnings \
  test_failed_limit_dialog_record_is_retried \
  test_failed_warning_check_records_the_dialog_once \
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
  test_human_step_detection \
  test_codex_approval_on_a_worker_is_a_hard_stop_not_a_human_step \
  test_worker_permission_blocker_clears_on_a_human_step \
  test_wrapped_draft_about_a_sign_in_is_unsent_input_not_a_step \
  test_human_step_pages_once_after_ten_minutes_and_is_never_typed_into \
  test_human_step_overnight_reports_only_what_it_recorded \
  test_human_step_daytime_dry_run_names_the_page_it_would_send \
  test_human_step_overnight_goes_to_the_morning_handoff \
  test_human_step_overnight_handoff_is_paged_by_day_unless_briefed \
  test_human_step_removed_worker_closes_its_handoff \
  test_human_step_undelivered_page_falls_back_to_the_record \
  test_human_step_daytime_handoff_write_failure_is_reported_and_retried \
  test_human_step_failed_clear_keeps_its_episode_for_retry \
  test_worker_human_step_keeps_other_work_moving \
  test_unknown_composer_guards_the_nudge \
  test_orca_turn_probe_keeps_errors_unknown \
  test_no_activity_source_is_not_reported_ok \
  test_second_mate_activity_sources \
  test_second_mate_freeze_is_seen_without_a_transcript \
  test_claude_judge_keeps_the_default_login \
  test_unknown_heartbeat_endpoint_is_not_reported_ok \
  test_tmux_restart_survives_a_closed_session \
  test_supervisor_gap_rows_from_one_reading \
  test_supervisor_gap_heartbeat_stamp_reading \
  test_supervisor_gap_record_follows_published_heartbeat_age \
  test_supervisor_gap_unread_heartbeat_writes_no_row \
  test_supervisor_gap_rows_name_each_watched_home \
  test_supervisor_gap_torn_line_and_failed_append \
  test_status_file_short_and_staleness_visible \
  test_memory_guard_samples_once_per_pass \
  test_manager_units \
  test_never_merges_deploys_or_messages_owner \
  test_default_heartbeat_freeze_stays_above_a_quiet_home \
  test_default_heartbeat_freeze_uses_published_deadline \
  test_explicit_heartbeat_freeze_thresholds_keep_precedence \
  test_long_cadence_context_uses_the_default_freshness_bound \
  test_invalid_heartbeat_freshness_keeps_legacy_default \
  test_pending_handoff_suppresses_heartbeat_recovery \
  test_heartbeat_recovery_preserves_account_pins \
  test_heartbeat_response_cannot_suppress_recovery_forever \
  test_heartbeat_recovery_preserves_the_running_turn_veto \
  test_heartbeat_dryrun_never_counts_as_delivery \
  test_heartbeat_failed_send_never_counts_as_delivery \
  test_heartbeat_swallowed_enter_never_counts_as_delivery \
  test_heartbeat_ignores_orphan_and_previous_owner_receipts \
  test_heartbeat_recovery_serializes_with_handoff_launch \
  test_heartbeat_recovery_respects_recent_wake_activity \
  test_heartbeat_recovery_requires_a_known_activity_source
