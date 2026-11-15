#!/usr/bin/env bash
# tests/fm-permission-prompt.test.sh - worker permission prompts under the
# watchdog (bin/fm-permission-prompt.sh and its route in bin/fm-watchdog.sh).
#
# The classifier runs on real Claude Code 2.1.325 captures in
# tests/fixtures/permission-prompt/ and on prompts built from them. Every route
# case runs the real watchdog against a disposable home whose worker panes are
# real tmux panes on a private socket. A worker pane logs every byte typed into
# it and, when it reads Escape, redraws the screen Claude drew after Escape.
# The fm-control relaunch is a logging fake; the fm-send steer is the real one.
# Optional arguments select test functions; no arguments run the full suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-permission-prompt-tests)
WD="$ROOT/bin/fm-watchdog.sh"
PP="$ROOT/bin/fm-permission-prompt.sh"
FIX="$ROOT/tests/fixtures/permission-prompt"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-permission-prompt-test-$$"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -f /dev/null -L "$SOCKET" "\$@"
SH
chmod +x "$FAKEBIN/tmux"
CALLS_LOG="$TMP_ROOT/external-calls.log"
: > "$CALLS_LOG"
for tool in gh gh-axi osascript terminal-notifier say mail sendmail curl claude agy; do
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
cleanup_permission_prompt_tests() {
  local p
  for p in $LOCK_PIDS; do kill "$p" 2>/dev/null || true; done
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_permission_prompt_tests EXIT

BASE=$(date +%s)
CASE_N=0
ESC=$'\033'

# --- fixtures ----------------------------------------------------------------

bash_prompt() { cat "$FIX/claude-2.1.325-bash-prompt.txt"; }
# bash_prompt_with <command>: the real Bash prompt with another command in it.
bash_prompt_with() { bash_prompt | sed "s#touch /tmp/probe/fm-perm-probe2.txt#$1#"; }

classify() {  # <harness> [dialog]  (screen on stdin)
  bash "$PP" classify --harness "$1" ${2:+--dialog "$2"}
}

# make_home [extra-config]: a disposable home with a live captain pane and lock
# holder, so one watchdog pass visits its recorded workers.
make_home() {
  local extra=${1:-} sess sid
  CASE_N=$((CASE_N + 1))
  H="$TMP_ROOT/home$CASE_N"
  sid="00000000-0000-4000-8000-00000000000$CASE_N"
  mkdir -p "$H/state" "$H/config" "$H/data" "$H/claude/projects/p"
  printf 'Captain session\n> \n' > "$H/screen.txt"
  cat > "$H/agent.sh" <<SH
#!/usr/bin/env bash
cat "$H/screen.txt"
stty -echo
exec cat >> "$H/typed.log"
SH
  chmod +x "$H/agent.sh"
  sess="pp$CASE_N"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" new-session -d -s "$sess" -x 160 -y 40 "$H/agent.sh"
  T=$("$REAL_TMUX" -f /dev/null -L "$SOCKET" list-panes -t "=$sess" -F '#{pane_id}' | head -n 1)
  ( sleep 100000 > /dev/null 2>&1 & printf '%s\n' "$!" > "$H/lockpid" )
  LOCKPID=$(cat "$H/lockpid")
  LOCK_PIDS="$LOCK_PIDS $LOCKPID"
  printf '%s\n' "$LOCKPID" > "$H/state/.lock"
  printf '%s\n' "$sid" > "$H/state/.lock-session"
  fm_touch_epoch "$((BASE - 1))" "$H/state/.lock" "$H/state/.lock-session"
  jq -n --arg t "$T" --arg s "$sid" --argjson e "$BASE" --argjson p "$LOCKPID" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:"tmux",target:$t,present:true},session:{trusted_id:$s},writer:{anchor_pid:$p,session_id:$s}}}' \
    > "$H/state/heartbeat.json"
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{type:"assistant",timestamp:$ts,message:{content:[{type:"text",text:"Working."}]}}' \
    > "$H/claude/projects/p/$sid.jsonl"
  printf 'mode=act\nclaude-config-dirs=%s\nkey-settle-secs=1\nmodels=\n%s\n' "$H/claude" "$extra" > "$H/config/watchdog"
  cat > "$H/control.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$H/control.log"
if [ -e "$H/control.refuse" ]; then
  echo "error: task \$1 is blocked on a prompt: permission. Refusing to type Enter into it." >&2
  exit 1
fi
exit 0
SH
  chmod +x "$H/control.sh"
  sleep 0.3
}

# worker <id> <harness|-> <screen-file> [after-escape-file]: a real tmux pane
# and state/<id>.meta. The pane logs every byte it reads, and redraws
# after-escape-file when it reads Escape, as Claude does.
worker() {
  local id=$1 harness=$2 screen=$3 after=${4:-} sess
  cp "$screen" "$H/worker-$id.txt"
  if [ -n "$after" ]; then cp "$after" "$H/worker-$id.after"; fi
  cat > "$H/worker-$id.sh" <<SH
#!/usr/bin/env bash
cat "$H/worker-$id.txt"
stty -echo -icanon min 1 2>/dev/null
while IFS= read -r -n 1 -d '' c; do
  printf '%s' "\$c" >> "$H/worker-$id.typed"
  if [ "\$c" = "$ESC" ] && [ -f "$H/worker-$id.after" ]; then
    printf '\033[2J\033[H'
    cat "$H/worker-$id.after"
  fi
done
SH
  chmod +x "$H/worker-$id.sh"
  : > "$H/worker-$id.typed"
  sess="pw${id}${CASE_N}"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" new-session -d -s "$sess" -x 160 -y 40 "$H/worker-$id.sh"
  WP=$("$REAL_TMUX" -f /dev/null -L "$SOCKET" list-panes -t "=$sess" -F '#{pane_id}' | head -n 1)
  {
    printf 'kind=ship\nbackend=tmux\nwindow=%s\nendpoint_task_id=%s\n' "$WP" "$id"
    [ "$harness" = - ] || printf 'harness=%s\n' "$harness"
  } > "$H/state/$id.meta"
  # Wait until the fake worker has painted its screen, so a loaded host never
  # hands the watchdog an empty pane.
  local n=0
  until "$REAL_TMUX" -f /dev/null -L "$SOCKET" capture-pane -p -t "$WP" 2>/dev/null | grep -q '[^[:space:]]'; do
    n=$((n + 1))
    [ "$n" -lt 100 ] || fail "worker $id never painted its screen"
    sleep 0.1
  done
}

# repaint <id> <screen-file>: the worker now shows another screen.
repaint() {
  local sess="pw${1}${CASE_N}"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" kill-session -t "=$sess" 2>/dev/null || true
  worker "$1" "$(sed -n 's/^harness=//p' "$H/state/$1.meta")" "$2"
}

run_wd() {  # <offset-secs> <args>...
  local off=$1
  shift
  FM_TEST_SEAM=1 FM_WD_TEST_COMPOSER=empty FM_WD_TEST_CONTROL="$H/control.sh" FM_WD_NOW=$((BASE + off)) FM_HOME="$H" bash "$WD" "$@"
}

ledger() { cat "$H/state/watchdog/actions.tsv" 2>/dev/null; }
ledger_rows() {  # <action> <phase> [subject]
  awk -F'\t' -v a="$1" -v p="$2" -v s="${3:-}" '$5 == "permission-prompt" && $6 == a && $7 == p && (s == "" || $4 == s)' "$H/state/watchdog/actions.tsv" 2>/dev/null | wc -l | tr -d ' '
}
status_rows() {  # <id> <state> <key>
  { cat "$H/state/$1.status" 2>/dev/null || true; } | grep -c "^$2 \[at=[0-9]*\] \[key=$3\]: " || true
}
typed() { cat "$H/worker-$1.typed" 2>/dev/null; }
inbox_text() { cat "$H/state/$1.inbox/"*.msg 2>/dev/null; }

# --- classifier ----------------------------------------------------------------

test_real_claude_prompts_classify() {
  assert_equals $'route\ttool-approval' "$(bash_prompt | classify claude)" "the real Claude Bash prompt routes on a claude worker"
  assert_equals $'hold\tunknown-harness' "$(bash_prompt | classify codex)" "the same prompt on another harness is held"
  assert_equals $'hold\tunknown-harness' "$(bash_prompt | classify '')" "the same prompt with no recorded harness is held"
  assert_equals $'trust\tworkspace' "$(classify claude < "$FIX/claude-2.1.325-trust.txt")" "the real trust dialog asks for a relaunch"
  assert_equals $'hold\ttrust-unregistered' "$(classify codex < "$FIX/claude-2.1.325-trust.txt")" "a trust dialog on a harness with no pre-registration is held"
  classify claude < "$FIX/claude-2.1.325-after-escape.txt" >/dev/null \
    && fail "the screen Claude drew after Escape must not read as a prompt"
  printf 'the password field is validated before submit\n> \n' | classify claude >/dev/null \
    && fail "conversation that mentions a password is not a prompt"
  pass "real Claude 2.1.325 prompts: tool approval routes only on claude, trust relaunches, and the cancelled screen is clear"
}

test_declining_cursor_dialogs_never_route() {
  local imports=$'────────────────────────────────────────\n Allow external CLAUDE.md file imports?\n ❯ 1. No, disable external imports\n   2. Yes, allow external imports\n\n Enter to confirm · Esc to cancel'
  local bypass=$' WARNING: Claude Code running in Bypass Permissions mode\n ❯ 1. No, exit\n   2. Yes, I accept\n\n Enter to confirm · Esc to cancel'
  local hooks=$' 2 hooks are new or changed\n ❯ 1. Review hooks\n   2. Skip\n\n Enter to confirm · Esc to cancel'
  assert_equals $'hold\texternal-imports' "$(printf '%s\n' "$imports" | classify claude)" "the external-imports dialog is held"
  assert_equals $'hold\tbypass-confirm' "$(printf '%s\n' "$bypass" | classify claude)" "the bypass confirmation is held"
  assert_equals $'hold\thooks-review' "$(printf '%s\n' "$hooks" | classify codex)" "the hook-review modal is held"
  assert_equals $'hold\tunproven' "$(bash_prompt | sed -e 's/^ ❯ 1\. Yes$/   1. Yes/' -e 's/^   4\. No$/ ❯ 4. No/' | classify claude)" \
    "a tool prompt whose cursor moved off 1. Yes is not proven"
  assert_equals $'hold\tunproven' "$(bash_prompt | sed '/^─\{20,\}$/d' | classify claude)" "a tool prompt with no rule above it is not proven"
  pass "declining-cursor dialogs: imports, bypass, hook review, and a moved cursor are held"
}

test_hardstop_categories() {
  assert_equals $'hardstop\tcredential' "$(bash_prompt_with 'security find-generic-password -s gh -w' | classify claude)" "a keychain read is a credential stop"
  assert_equals $'hardstop\tcredential' "$(bash_prompt_with 'cat ~/.ssh/id_ed25519' | classify claude)" "a private key read is a credential stop"
  assert_equals $'hardstop\tdestructive' "$(bash_prompt_with 'rm -rf build/' | classify claude)" "a recursive remove is a destructive stop"
  assert_equals $'hardstop\tdestructive' "$(bash_prompt_with 'git reset --hard origin/main' | classify claude)" "a hard reset is a destructive stop"
  assert_equals $'hardstop\trelease' "$(bash_prompt_with 'gh pr merge 12 --squash' | classify claude)" "a merge is a release stop"
  local c
  for c in 'rm report.txt' 'rm --recursive --force build/' 'git restore src/app.py' 'git checkout -f main' 'find . -name x -delete' 'docker system prune -af'; do
    assert_equals $'hardstop\tdestructive' "$(bash_prompt_with "$c" | classify claude)" "$c is a destructive stop"
  done
  assert_equals $'hardstop\tspend' "$(bash_prompt_with 'echo Use paid credits to continue' | classify claude)" "paid-credit wording is a spend stop"
  assert_equals $'hardstop\trelease' "$(bash_prompt_with 'git push origin main' | classify claude)" "a push to main is a release stop"
  assert_equals $'hardstop\tcredential' "$(bash_prompt_with 'op item get gh --reveal' | classify claude)" "a revealed vault item is a credential stop"
  assert_equals $'route\ttool-approval' "$(bash_prompt_with 'git push -u origin fm/feature-x' | classify claude)" "a feature-branch push still routes"
  for c in 'Enter your password:' 'Enter your passphrase:' 'Password for dev@build:' "Password for 'https://x@github.com':" 'Enter OTP:'; do
    assert_equals $'hardstop\tcredential' "$(printf 'work\n%s\n' "$c" | classify claude)" "$c is a credential stop"
  done
  assert_equals $'hardstop\tsign-in' "$(printf "work\nUsername for 'https://github.com':\n" | classify claude)" "a git username input is a sign-in stop"
  assert_equals $'hardstop\tspend' "$(printf ' Continue with paid usage?\n ❯ 1. Yes\n   2. No\n\n Enter to confirm · Esc to cancel\n' | classify claude)" \
    "a paid-usage picker is a spend stop"
  assert_equals $'hardstop\tdestructive' "$(printf ' Delete the database?\n ❯ 1. Yes\n   2. No\n\n Enter to confirm · Esc to cancel\n' | classify claude)" \
    "a destructive question picker is a destructive stop"
  assert_equals $'hardstop\tcredential' "$(printf 'work\n[sudo] password for dev:\n' | classify claude)" "a sudo password input is a credential stop"
  assert_equals $'hardstop\tsign-in' "$(printf 'Browser opened\nPaste code here if prompted >\n' | classify claude)" "a pasted sign-in code is a sign-in stop"
  assert_equals $'hardstop\tsign-in' "$(printf ' Select login method:\n\n ❯ 1. Claude account with subscription\n   2. Anthropic Console account\n\n Enter to confirm · Esc to cancel\n' | classify claude)" \
    "a login picker is a sign-in stop"
  assert_equals $'hardstop\tspend' "$(printf ' You have reached your limit. Add funds to continue?\n ❯ 1. Buy more credits\n   2. Wait\n\n Enter to confirm · Esc to cancel\n' | classify claude)" \
    "an add-funds picker is a spend stop"
  printf ' Which plan should I follow?\n ❯ 1. Plan A\n   2. Plan B\n\n Enter to select · ↑/↓ to navigate · Esc to cancel\n' | classify claude >/dev/null \
    && fail "an ordinary question picker is not a permission prompt"
  pass "hard stops: credential, sign-in, spend, destructive, and release prompts are named and never routed"
}

# --- the watchdog route ----------------------------------------------------------

test_tool_approval_is_declined_and_steered() {
  make_home
  worker ok claude "$FIX/claude-2.1.325-bash-prompt.txt" "$FIX/claude-2.1.325-after-escape.txt"
  run_wd 0 once >/dev/null 2>&1 || fail "the watchdog pass failed"
  assert_equals "$ESC" "$(typed ok | head -c 1)" "the first and only key into the prompt is Escape: $(typed ok | od -c | head -3)"
  assert_equals 1 "$(typed ok | tr -cd '\033' | wc -c | tr -d ' ')" "exactly one Escape is pressed"
  assert_not_contains "$(typed ok | head -c 2)" "1" "no Yes option is selected"
  assert_equals 1 "$(ledger_rows decline "done" worker:ok)" "the decline is recorded: $(ledger | cut -f4-8)"
  assert_equals 1 "$(ledger_rows steer "done" worker:ok)" "the rewrite instruction is recorded: $(ledger | cut -f4-8)"
  assert_contains "$(inbox_text ok)" "declined automatically" "the worker's inbox holds the rewrite instruction"
  assert_contains "$(inbox_text ok)" "<<'EOF'" "the instruction names the checkable heredoc form"
  assert_equals 0 "$(status_rows ok blocked permission-prompt-held)" "a declined prompt is not reported as blocked"
  assert_no_grep "permission dialog waiting on worker ok" "$H/data/watchdog/status.md" "a declined prompt is not a waiting gap"
  assert_equals '' "$(cat "$CALLS_LOG")" "no merge, notifier, or model tool ran"
  pass "tool approval: one Escape, verified gone, then a durable rewrite instruction"
}

test_prompt_after_escape_gets_no_instruction() {
  make_home
  worker nt claude "$FIX/claude-2.1.325-bash-prompt.txt" "$FIX/claude-2.1.325-trust.txt"
  printf 'work output\nEnter your password:\n' > "$H/pw-after.txt"
  worker np claude "$FIX/claude-2.1.325-bash-prompt.txt" "$H/pw-after.txt"
  run_wd 0 once >/dev/null 2>&1 || fail "the watchdog pass failed"
  local id
  for id in nt np; do
    assert_equals "$ESC" "$(typed "$id")" "only the one Escape reaches worker $id: $(typed "$id" | od -c | head -3)"
    assert_equals '' "$(inbox_text "$id")" "no instruction, and so no doorbell, goes to worker $id"
    assert_equals 0 "$(ledger_rows steer "done" "worker:$id")" "no steer is recorded for worker $id"
  done
  assert_equals 1 "$(status_rows nt blocked permission-prompt-held)" "a trust dialog behind the declined prompt is held"
  assert_equals 1 "$(status_rows np blocked permission-prompt-hardstop)" "a password input behind the declined prompt is a hard stop"
  assert_grep "shows a credential prompt after a declined tool call" "$H/state/np.status" "the hard stop names its category"
  pass "after Escape: a trust dialog or credential input behind the prompt gets no instruction, no doorbell, and a keyed blocked line"
}

test_doorbell_never_types_into_a_prompt() {
  make_home
  worker db claude "$FIX/claude-2.1.325-bash-prompt.txt"
  worker dt claude "$FIX/claude-2.1.325-trust.txt"
  local id
  for id in db dt; do
    FM_HOME="$H" bash "$ROOT/bin/fm-send.sh" "$id" "steer for $id" >/dev/null 2>&1
    assert_contains "$(inbox_text "$id")" "steer for $id" "the steer for worker $id is durably recorded"
    sleep 1
    assert_equals '' "$(typed "$id")" "the doorbell types nothing into the prompt on worker $id: $(typed "$id" | od -c | head -3)"
  done
  pass "doorbell: a steer to a worker on a tool-approval prompt or a trust picker is recorded and types nothing"
}

test_declining_dialogs_on_workers_get_no_key() {
  local id
  make_home
  printf '%s\n' '────────────────────────────────────────' ' Allow external CLAUDE.md file imports?' ' ❯ 1. No, disable external imports' '   2. Yes, allow external imports' '' ' Enter to confirm · Esc to cancel' > "$H/imports.txt"
  printf '%s\n' ' WARNING: Claude Code running in Bypass Permissions mode' ' ❯ 1. No, exit' '   2. Yes, I accept' '' ' Enter to confirm · Esc to cancel' > "$H/bypass.txt"
  worker im claude "$H/imports.txt"
  worker by claude "$H/bypass.txt"
  worker dn claude "$FIX/claude-2.1.325-bash-prompt.txt" "$FIX/claude-2.1.325-after-escape.txt"
  printf 'do-not-touch=%s\n' "$WP" >> "$H/config/watchdog"
  run_wd 0 once >/dev/null 2>&1 || fail "the watchdog pass failed"
  for id in im by dn; do
    assert_equals '' "$(typed "$id")" "no key reaches worker $id"
    assert_equals 1 "$(status_rows "$id" blocked permission-prompt-held)" "worker $id is reported as held"
  done
  assert_grep "external-imports" "$H/state/im.status" "the imports dialog names its reason"
  assert_grep "bypass-confirm" "$H/state/by.status" "the bypass confirmation names its reason"
  assert_grep "do-not-touch" "$H/state/dn.status" "the do-not-touch hold names its reason"
  pass "declining dialogs and do-not-touch workers: no key and one keyed held line"
}

test_repeated_or_capped_prompts_hold() {
  make_home 'permission-decline-cap=2'
  worker rep claude "$FIX/claude-2.1.325-bash-prompt.txt" "$FIX/claude-2.1.325-after-escape.txt"
  run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows decline "done" worker:rep)" "the first prompt is declined"
  repaint rep "$FIX/claude-2.1.325-bash-prompt.txt"
  : > "$H/worker-rep.typed"
  cp "$FIX/claude-2.1.325-after-escape.txt" "$H/worker-rep.after"
  run_wd 200 once >/dev/null 2>&1
  assert_equals '' "$(typed rep)" "the same prompt again gets no key"
  assert_equals 1 "$(status_rows rep blocked permission-prompt-held)" "the repeat is reported as held once"
  run_wd 400 once >/dev/null 2>&1
  assert_equals 1 "$(status_rows rep blocked permission-prompt-held)" "the same held prompt is not reported twice"

  bash_prompt_with 'touch /tmp/probe/second.txt' > "$H/second.txt"
  repaint rep "$H/second.txt"
  cp "$FIX/claude-2.1.325-after-escape.txt" "$H/worker-rep.after"
  run_wd 600 once >/dev/null 2>&1
  assert_equals 2 "$(ledger_rows decline "done" worker:rep)" "a different prompt is declined under the cap"
  assert_equals 1 "$(status_rows rep resolved permission-prompt-held)" "the held line is resolved once the prompt leaves"
  bash_prompt_with 'touch /tmp/probe/third.txt' > "$H/third.txt"
  repaint rep "$H/third.txt"
  : > "$H/worker-rep.typed"
  run_wd 800 once >/dev/null 2>&1
  assert_equals '' "$(typed rep)" "a prompt past the hourly cap gets no key"
  assert_equals 2 "$(status_rows rep blocked permission-prompt-held)" "the cap is reported as held"
  assert_grep "cap; nothing more is answered" "$H/state/rep.status" "the held line names the cap"
  pass "decline guard: a repeated prompt and a prompt past the cap are held, each reported once"
}

test_trust_dialog_relaunches_without_a_key() {
  make_home
  worker tr claude "$FIX/claude-2.1.325-trust.txt"
  run_wd 0 once >/dev/null 2>&1
  assert_equals '' "$(typed tr)" "no key reaches a trust dialog whose cursor sits on No, exit"
  assert_equals 1 "$(grep -c '^tr relaunch --note ' "$H/control.log" 2>/dev/null || true)" "the worker is relaunched through fm-control: $(ledger | cut -f4-8)"
  assert_equals 1 "$(ledger_rows relaunch "done" worker:tr)" "the relaunch is recorded: $(ledger | cut -f4-8)"
  run_wd 300 once >/dev/null 2>&1
  assert_equals 1 "$(grep -c . "$H/control.log")" "a trust dialog still showing inside the window is not relaunched again"
  assert_equals 1 "$(status_rows tr blocked permission-prompt-held)" "it is reported as held instead"
  assert_equals '' "$(typed tr)" "still no key"

  make_home
  : > "$H/control.refuse"
  worker tq claude "$FIX/claude-2.1.325-trust.txt"
  run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows relaunch failed worker:tq)" "a refused relaunch is recorded: $(ledger | cut -f4-8)"
  assert_contains "$(ledger | awk -F'\t' '$6 == "relaunch" && $7 == "failed" { print $8 }')" "blocked on a prompt" "the refusal reason is kept"
  assert_equals 1 "$(status_rows tq blocked permission-prompt-held)" "a refused relaunch is reported as held"
  assert_equals '' "$(typed tq)" "a refused relaunch types nothing"
  pass "trust dialog: no key, a controlled relaunch once per window, and a refusal is reported"
}

test_hardstop_prompts_are_never_answered() {
  make_home
  bash_prompt_with 'security find-generic-password -s gh -w' > "$H/cred.txt"
  bash_prompt_with 'rm -rf build/' > "$H/rm.txt"
  printf ' You have reached your limit. Add funds to continue?\n ❯ 1. Buy more credits\n   2. Wait\n\n Enter to confirm · Esc to cancel\n' > "$H/spend.txt"
  printf 'Opening the browser to sign in\nPaste code here if prompted >\n' > "$H/signin.txt"
  worker cred claude "$H/cred.txt" "$FIX/claude-2.1.325-after-escape.txt"
  worker rm claude "$H/rm.txt" "$FIX/claude-2.1.325-after-escape.txt"
  worker spend claude "$H/spend.txt"
  worker signin claude "$H/signin.txt"
  run_wd 0 once >/dev/null 2>&1 || fail "the watchdog pass failed"
  run_wd 300 once >/dev/null 2>&1
  local id
  for id in cred rm spend signin; do
    assert_equals '' "$(typed "$id")" "no key reaches the $id prompt"
    assert_equals 1 "$(status_rows "$id" blocked permission-prompt-hardstop)" "the $id prompt is reported once as a hard stop"
  done
  assert_grep "shows a credential prompt" "$H/state/cred.status" "the keychain prompt names its category"
  assert_grep "shows a destructive prompt" "$H/state/rm.status" "the remove prompt names its category"
  assert_grep "shows a spend prompt" "$H/state/spend.status" "the add-funds prompt names its category"
  assert_grep "shows a sign-in prompt" "$H/state/signin.status" "the sign-in input names its category"
  assert_no_grep "find-generic-password" "$H/state/cred.status" "the blocked line carries no prompt text"
  assert_equals 0 "$(ledger_rows decline pending)" "no hard stop is declined"
  assert_equals '' "$(cat "$H/control.log" 2>/dev/null)" "no hard stop is relaunched"

  printf 'work output\n> \n' > "$H/plain.txt"
  repaint cred "$H/plain.txt"
  run_wd 600 once >/dev/null 2>&1
  assert_equals 1 "$(status_rows cred resolved permission-prompt-hardstop)" "the hard stop is resolved once the prompt leaves"
  pass "hard stops: credential, destructive, spend, and sign-in prompts get no key and one keyed blocked line"
}

test_unknown_harness_dry_run_and_off() {
  make_home
  worker nh - "$FIX/claude-2.1.325-bash-prompt.txt" "$FIX/claude-2.1.325-after-escape.txt"
  run_wd 0 once >/dev/null 2>&1
  assert_equals '' "$(typed nh)" "a worker with no recorded harness gets no key"
  assert_equals 1 "$(status_rows nh blocked permission-prompt-held)" "it is reported as held"
  assert_grep "permission dialog waiting on worker nh" "$H/data/watchdog/status.md" "the waiting gap is kept"

  make_home 'permission-route=dry-run'
  worker dr claude "$FIX/claude-2.1.325-bash-prompt.txt" "$FIX/claude-2.1.325-after-escape.txt"
  run_wd 0 once >/dev/null 2>&1
  assert_equals '' "$(typed dr)" "dry-run presses nothing"
  assert_equals 1 "$(ledger_rows decline dry-run worker:dr)" "dry-run records what it would do: $(ledger | cut -f4-8)"
  [ ! -e "$H/state/dr.status" ] || fail "dry-run wrote a status line: $(cat "$H/state/dr.status")"

  make_home 'permission-route=off'
  worker of claude "$FIX/claude-2.1.325-bash-prompt.txt" "$FIX/claude-2.1.325-after-escape.txt"
  run_wd 0 once >/dev/null 2>&1
  assert_equals '' "$(typed of)" "off presses nothing"
  assert_equals '' "$(ledger | awk -F'\t' '$5 == "permission-prompt"')" "off records no route"
  [ ! -e "$H/state/of.status" ] || fail "off wrote a status line: $(cat "$H/state/of.status")"
  assert_grep "permission dialog waiting on worker of" "$H/data/watchdog/status.md" "off keeps the waiting gap"
  pass "guards: no recorded harness holds, dry-run only records, and off keeps the report-only path"
}

if [ "$#" -gt 0 ]; then
  fm_test_run "$@"
  exit $?
fi
fm_test_run \
  test_real_claude_prompts_classify \
  test_declining_cursor_dialogs_never_route \
  test_hardstop_categories \
  test_tool_approval_is_declined_and_steered \
  test_prompt_after_escape_gets_no_instruction \
  test_doorbell_never_types_into_a_prompt \
  test_declining_dialogs_on_workers_get_no_key \
  test_repeated_or_capped_prompts_hold \
  test_trust_dialog_relaunches_without_a_key \
  test_hardstop_prompts_are_never_answered \
  test_unknown_harness_dry_run_and_off
