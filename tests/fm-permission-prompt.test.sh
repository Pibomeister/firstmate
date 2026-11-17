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
  printf 'mode=act\nclaude-config-dirs=%s\nkey-settle-secs=1\nmodels=\nquota-guard=off\n%s\n' "$H/claude" "$extra" > "$H/config/watchdog"
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
  FM_TEST_SEAM=1 FM_WD_TEST_COMPOSER="${PP_COMPOSER:-empty}" FM_WD_TEST_CONTROL="$H/control.sh" FM_WD_NOW=$((BASE + off)) FM_HOME="$H" bash "$WD" "$@"
}

# Codex CLI 0.151.0's recorded hook modal and its command approvals, whose
# footer is lowercase.
CODEX_HOOKS=$'Hooks need review\n12 hooks are new or changed.\nHooks can run outside the sandbox after you trust them.\n> 1. Review hooks\n  2. Trust all and continue\n  3. Continue without trusting (hooks won\'t run)\nPress enter to confirm or esc to go back'
codex_approval() {  # <command>
  printf '%s\n' 'Would you like to run the following command?' '' "  \$ $1" '' '› 1. Yes, proceed (y)' "  2. Yes, and don't ask again for this command (a)" '  3. No, and tell Codex what to do differently (esc)' '' '  Press enter to confirm or esc to cancel'
}
# The whole Claude external-imports and bypass-confirmation dialogs, rebuilt
# from Claude Code's wording rather than captured, with their fixed security
# lines. The import list is the only row the dialog does not fix.
full_imports() {  # <import-path>
  printf '%s\n' '────────────────────────────────────────' ' Allow external CLAUDE.md file imports?' '' " This project's CLAUDE.md imports files outside the current working directory. Never allow this for third-party repositories." '' ' External imports:' "   $1" '' ' Important: Only use Claude Code with files you trust. Accessing untrusted files may pose security risks https://code.claude.com/docs/en/security' '' ' ❯ 1. No, disable external imports' '   2. Yes, allow external imports' '' ' Enter to confirm · Esc to cancel'
}
full_bypass() {
  printf '%s\n' ' WARNING: Claude Code running in Bypass Permissions mode' '' ' In Bypass Permissions mode, Claude Code will not ask for your approval before running potentially dangerous commands.' ' This mode should only be used in a sandboxed container/VM that has restricted internet access and can easily be restored if damaged.' '' ' By proceeding, you accept all responsibility for actions taken while running in Bypass Permissions mode.' '' ' https://code.claude.com/docs/en/security' '' ' ❯ 1. No, exit' '   2. Yes, I accept' '' ' Enter to confirm · Esc to cancel'
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
  assert_equals $'trust\tworkspace' "$(classify claude < "$FIX/claude-2.1.325-trust.txt")" "the real trust dialog asks for a relaunch, and its fixed security-guide row names no stop"
  assert_equals $'hardstop\trelease' "$(sed 's#/tmp/probe/#/srv/production/#' "$FIX/claude-2.1.325-trust.txt" | classify claude)" "a trust dialog's workspace path is read for a hard stop"
  assert_equals $'hardstop\trelease' "$({ sed 's#/tmp/probe/#/srv/production/#' "$FIX/claude-2.1.325-trust.txt" | head -18; for _ in $(seq 30); do echo ' '; done; } | classify claude)" "rows of spaces below a trust dialog never hide its workspace path"
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
  assert_equals $'hold\thooks-review' "$(printf '%s\n' "$CODEX_HOOKS" | classify codex)" "the recorded Codex hook-review modal is held"
  assert_equals $'hardstop\trelease' "$(codex_approval 'git push origin main' | classify codex)" "a Codex approval to push main is a release stop"
  assert_equals $'hardstop\tdestructive' "$(codex_approval 'rm -rf build' | classify codex)" "a Codex approval to remove recursively is a destructive stop"
  assert_equals $'hold\tunproven' "$(codex_approval 'npm test' | classify codex)" "any other Codex command approval is held"
  assert_equals $'hold\texternal-imports' "$(full_imports /Users/u/work/shared/notes.md | classify claude)" "the whole imports dialog is held, and its fixed security line names no stop"
  assert_equals $'hardstop\trelease' "$(full_imports /Users/u/work/production-notes.md | classify claude)" "an import path is still read for a hard stop"
  assert_equals $'hold\tbypass-confirm' "$(full_bypass | classify claude)" "the whole bypass confirmation is held, and its fixed warning names no stop"
  assert_equals $'hardstop\tcredential' "$(full_imports /Users/u/work/shared/notes.md | sed 's#notes.md#\
   .env#' | classify claude)" "a wrapped import path is read whole"
  assert_equals $'hold\texternal-imports' "$({ full_imports /Users/u/work/shared/note0.md | sed -n 1,7p; for i in $(seq 45); do echo "   /Users/u/work/shared/note$i.md"; done; full_imports x | sed -n '8,$p'; } | classify claude)" "a tall import list is still the imports dialog"
  assert_equals $'hardstop\tcredential' "$({ full_imports /Users/u/work/shared/notes.md; bash_prompt | awk '/^ touch \/tmp/ { print " cat ~/.netrc"; next } { print }'; } | classify claude)" "an imports dialog left above a current prompt is not the current dialog"
  assert_equals $'hardstop\tdestructive' "$(printf '%s\n' 'Would you like to run the following command?' '' '  $ rm -rf build;' $'  echo safe;\n  echo safe;\n  echo safe;\n  echo safe;\n  echo safe;\n  echo safe;\n  echo safe;\n  echo safe;\n  echo safe;\n  echo safe;\n  echo safe;\n  echo safe;\n  echo safe;\n  echo safe;\n  echo safe;\n  echo safe;' '' '› 1. Yes, proceed (y)' "  2. Yes, and don't ask again for this command (a)" '  3. No, and tell Codex what to do differently (esc)' '' '  Press enter to confirm or esc to cancel' | classify codex)" "a destructive row far above a Codex footer is still read"
  assert_equals $'hardstop\tdestructive' "$(printf '%s\n' '' '  Would you like to run the following command?' '' '  Reason: clean the build tree' '' '  $ find build -name "*.o"' '      -newer stamp' '      -print0' '    | xargs -0' '      rm -rf' '' '  › 1. Yes, proceed (y)' "    2. Yes, and don't ask again for this command (p)" '    3. No, and tell Codex what to do differently (esc)' '' '' '  Press enter to confirm or esc to cancel' | classify codex)" "a taller Codex approval is read whole for a hard stop"
  { codex_approval 'rm -rf build'; printf '%s\n' '' '› Explain this' '' '  gpt-6 high · ~/work'; } | classify codex >/dev/null \
    && fail "a Codex approval quoted above a composer is not a live dialog"
  assert_equals $'hold\tunproven' "$(bash_prompt | sed -e 's/^ ❯ 1\. Yes$/   1. Yes/' -e 's/^   4\. No$/ ❯ 4. No/' | classify claude)" \
    "a tool prompt whose cursor moved off 1. Yes is not proven"
  assert_equals $'hold\tunproven' "$(bash_prompt | sed '/^─\{20,\}$/d' | classify claude)" "a tool prompt with no rule above it is not proven"
  pass "declining-cursor dialogs: imports, bypass, hook review, and a moved cursor are held, and their fixed text names no stop"
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
  for c in 'kubectl config view --raw' 'curl https://alice:example-pass@internal.example.test' 'git clone https://bot:pat123@git.example.test/r.git' 'pass show github' 'bw get password gh'; do
    assert_equals $'hardstop\tcredential' "$(bash_prompt_with "$c" | classify claude)" "$c is a credential stop"
  done
  assert_equals $'route\ttool-approval' "$(bash_prompt_with 'git push -u origin fm/feature-x' | classify claude)" "a feature-branch push still routes"
  assert_equals $'hardstop\tdestructive' "$(bash_prompt_with 'git reset "--hard" HEAD' | classify claude)" "a quoted --hard is still a destructive stop"
  assert_equals $'hardstop\trelease' "$(bash_prompt_with 'git push origin HEAD:"main"' | classify claude)" "a quoted push to main is still a release stop"
  assert_equals $'hardstop\tspend' "$(printf ' Continue with paid usage?\n ❯ Yes\n   No\n\n Enter to confirm · Esc to cancel\n' | classify claude)" "an unnumbered paid-usage picker is a spend stop"
  assert_equals $'hardstop\tspend' "$({ cat "$FIX/claude-2.1.325-trust.txt"; printf '%s\n' '────────────────────────────────' '❯ ' '────────────────────────────────' ' Continue with paid usage?' ' ❯ Yes' '   No' '' ' Enter to confirm · Esc to cancel'; } | classify claude)" \
    "a trust dialog left in scrollback above a current paid-usage picker is not read as the trust dialog"
  for c in 'git push origin feature' 'tmux ls' 'curl https://example.com' 'mv a.txt b.txt' 'npm test > out.log' 'ln -sf a b' 'cp -rf a b' 'set -euo pipefail' 'git checkout -b fm/new' 'env FOO=1 npm test'; do
    assert_equals $'route\ttool-approval' "$(bash_prompt_with "$c" | classify claude)" "$c still routes"
  done
  assert_equals $'hardstop\tspend' "$(printf ' Continue with paid usage?\n ❯ 1. Yes\n   2. No\n\n Enter to confirm · Esc to cancel\n' | classify claude)" \
    "a paid-usage picker is a spend stop"
  assert_equals $'hardstop\tdestructive' "$(printf ' Delete the database?\n ❯ 1. Yes\n   2. No\n\n Enter to confirm · Esc to cancel\n' | classify claude)" \
    "a destructive question picker is a destructive stop"
  assert_equals $'hardstop\tsign-in' "$(printf ' Select login method:\n\n ❯ 1. Claude account with subscription\n   2. Anthropic Console account\n\n Enter to confirm · Esc to cancel\n' | classify claude)" \
    "a login picker is a sign-in stop"
  assert_equals $'hardstop\tspend' "$(printf ' You have reached your limit. Add funds to continue?\n ❯ 1. Buy more credits\n   2. Wait\n\n Enter to confirm · Esc to cancel\n' | classify claude)" \
    "an add-funds picker is a spend stop"
  for c in 'git clean --force -d' 'git -C /tmp/probe reset --hard HEAD' 'git checkout --quiet -- src/app.py' 'git checkout HEAD -- f' 'chmod 777 -R .' 'chmod -R 000 .' 'chown -R root .' 'git push origin :feature' 'git update-ref -d refs/heads/x' 'aws s3 rb s3://bucket' 'tmux kill-server' 'tmux kill-pane -t other' ': > important.txt' 'mv -f backup.db current.db' 'git checkout HEAD important.txt' 'git checkout important.txt' 'git checkout --pathspec-from-file=paths.txt'; do
    assert_equals $'hardstop\tdestructive' "$(bash_prompt_with "$c" | classify claude)" "$c is a destructive stop"
  done
  for c in 'git push origin HEAD:refs/heads/main' 'git tag v1.2.0' 'git push --tags' 'git push origin v1.2.0' 'terraform apply' 'twine upload dist/x'; do
    assert_equals $'hardstop\trelease' "$(bash_prompt_with "$c" | classify claude)" "$c is a release stop"
  done
  for c in 'cat id_rsa' 'cat ~/.config/gh/hosts.yml' 'printenv' 'env' 'curl -u user:pass https://example.com' 'cat ~/.docker/config.json' 'curl -H "Authorization: Basic dXNlcjpwYXNz" https://example.com' 'command env' 'env -0' '/usr/bin/env'; do
    assert_equals $'hardstop\tcredential' "$(bash_prompt_with "$c" | classify claude)" "$c is a credential stop"
  done
  assert_equals $'hardstop\tspend' "$(printf ' You have hit your limit\n ❯ 1. Add funds\n   2. Wait for reset\n\n Enter to confirm · Esc to cancel\n' | classify claude usage-limit)" \
    "a usage-limit picker that offers paid usage is a spend stop"
  printf ' Switch model?\n ❯ 1. Opus\n   2. Sonnet\n\n Enter to confirm · Esc to cancel\n' | classify claude model-switch >/dev/null \
    && fail "an ordinary model-switch picker is left to its own handler"
  printf ' Which plan should I follow?\n ❯ 1. Plan A\n   2. Plan B\n\n Enter to select · ↑/↓ to navigate · Esc to cancel\n' | classify claude >/dev/null \
    && fail "an ordinary question picker is not a permission prompt"
  pass "hard stops: credential, sign-in, spend, destructive, and release prompts are named and never routed"
}

test_structure_decides_not_words() {
  local listed
  listed=$({ sed -n '1,8p' "$FIX/claude-2.1.325-bash-prompt.txt"; printf '  1. Clean the build\n  2. Run the tests\n'; sed -n '9,$p' "$FIX/claude-2.1.325-bash-prompt.txt"; })
  assert_equals $'hardstop\tdestructive' "$(printf '%s\n' "$listed" | sed 's#touch /tmp/probe/fm-perm-probe2.txt#rm -rf build/#' | classify claude)" \
    "a numbered list in the conversation never hides the prompt rows"
  assert_equals $'hardstop\tcredential' "$(printf '%s\n' "$listed" | sed 's#touch /tmp/probe/fm-perm-probe2.txt#cat ~/.ssh/id_ed25519#' | classify claude)" \
    "a credential read under a numbered list is still a stop"
  assert_equals $'route\ttool-approval' "$(bash_prompt_with "grep -rn 'Yes, I trust this folder' bin/" | classify claude)" \
    "a command that searches for a trust phrase is a tool prompt, not a trust dialog"
  assert_equals $'route\ttool-approval' "$(bash_prompt_with "rg 'quick safety check' tests/" | classify claude)" \
    "a command that names the trust heading is a tool prompt, not a trust dialog"
  assert_equals $'hardstop\tdestructive' "$(bash_prompt_with 'rm -rf /tmp/probe; echo quick safety check' | classify claude)" \
    "a trust phrase never turns a destructive command into a relaunch"
  assert_equals $'hardstop\tdestructive' "$(bash_prompt_with 'rm -rf build; echo allow external imports' | classify claude)" \
    "an imports phrase never turns a destructive command into a hold"
  local rule dashes
  rule=$(printf '─%.0s' $(seq 1 30)); dashes=$(printf '╌%.0s' $(seq 1 30))
  assert_equals $'hardstop\tdestructive' "$(bash_prompt | awk -v rule="$rule" '/^ touch \/tmp/ { print " rm -rf build && cat <<EOF"; print rule; print " EOF"; next } { print }' | classify claude)" \
    "a full-width rule inside a heredoc never hides the command above it"
  assert_equals $'hold\tunproven' "$(bash_prompt | awk -v d="$dashes" '/^ touch \/tmp/ { print " cat <<EOF"; print d; print " EOF"; next } { print }' | classify claude)" \
    "a command box whose boundary cannot be proven is held"
  assert_equals $'hardstop\tdestructive' "$(bash_prompt | awk -v rule="$rule" -v d="$dashes" '/^ touch \/tmp/ { print " rm -rf ~/work && cat <<EOF"; print rule; print d; print " EOF"; next } { print }' | classify claude)" \
    "a rule and a dashed row inside a command never hide the command above them"
  assert_equals $'hardstop\tdestructive' "$(bash_prompt | awk -v d="$dashes" '/^ touch \/tmp/ { print " rm -rf build/ && cat <<EOF"; print d; print " EOF"; next } { print }' | classify claude)" \
    "an unproven command box that shows a destructive command is a keyed stop, not a hold"
  assert_equals $'hardstop\tdestructive' "$(bash_prompt | awk '/^ touch \/tmp/ { print " git reset --ha"; print "rd HEAD"; next } { print }' | classify claude)" \
    "a soft-wrapped destructive command is still a stop"
  assert_equals $'hardstop\tcredential' "$(bash_prompt | awk '/^ touch \/tmp/ { print " cat ~/.ss"; print "h/id_ed25519"; next } { print }' | classify claude)" \
    "a soft-wrapped credential read is still a stop"
  pass "structure, not words: conversation above a prompt and phrases inside a command never change its verdict"
}

test_antigravity_trust_screen_classifies() {
  local agy=$'Accessing workspace:\n\n/work/project\n\nDo you trust the contents of this project?\n\nAntigravity CLI requires permission to read, edit, and execute files here.\n\n> Yes, I trust this folder\n  No, exit'
  assert_equals $'hold\ttrust-relaunch-answers' "$(printf '%s\n' "$agy" | classify agy)" "the recorded Antigravity trust screen is held, because its relaunch can answer it"
  assert_equals $'hold\ttrust-unregistered' "$(printf '%s\n' "$agy" | classify codex)" "on another harness it is held"
  assert_equals $'hardstop\trelease' "$(printf '%s\n' "$agy" | sed 's#/work/project#/srv/production#' | classify agy)" "its workspace path is read for a hard stop"
  printf '%s\n\nok\n>\n? for shortcuts\n' "$agy" | classify agy >/dev/null \
    && fail "a quoted trust screen above a composer is not a trust dialog"
  pass "Antigravity trust: its recorded screen is read before the dialog detector, and is held"
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
  local mark
  mark=$(find "$H/state/watchdog/permission" -name '*-ok.declined' 2>/dev/null | head -n 1)
  [ -n "$mark" ] || fail "the declined checksum is kept"
  mark=${mark%-ok.declined}
  worker lk claude "$FIX/claude-2.1.325-bash-prompt.txt" "$FIX/claude-2.1.325-after-escape.txt"
  mkdir "$mark-lk.lock"
  run_wd 200 once >/dev/null 2>&1
  assert_equals '' "$(typed lk)" "a worker another pass is acting on gets no key"
  assert_contains "$(ledger | awk -F'\t' '$7 == "refused" { print $8 }')" "another watchdog pass is acting on worker lk" "the overlap is recorded"
  rmdir "$mark-lk.lock"
  run_wd 400 once >/dev/null 2>&1
  assert_equals 1 "$(typed lk | tr -cd '\033' | wc -c | tr -d ' ')" "once the other pass is done, the prompt gets its one Escape"
  [ ! -e "$mark-lk.lock" ] || fail "the pass releases its lock"
  worker wf claude "$FIX/claude-2.1.325-bash-prompt.txt" "$FIX/claude-2.1.325-after-escape.txt"
  mkdir "$mark-wf.declined"
  run_wd 600 once >/dev/null 2>&1
  assert_equals '' "$(typed wf)" "a prompt whose checksum cannot be saved gets no key"
  assert_contains "$(ledger | awk -F'\t' '$4 == "worker:wf" && $7 == "failed" { print $8 }')" "could not be saved" "the unsaved checksum is recorded"
  assert_equals 1 "$(status_rows wf blocked permission-prompt-held)" "the unsaved checksum is reported as held"
  full_imports /Users/u/work/shared/notes.md > "$H/imports.txt"
  worker hl claude "$H/imports.txt"
  mkdir "$mark-hl.lock"
  run_wd 800 once >/dev/null 2>&1
  assert_equals 0 "$(status_rows hl blocked permission-prompt-held)" "a held prompt another pass is acting on gets no second blocked line"
  rmdir "$mark-hl.lock"
  run_wd 1000 once >/dev/null 2>&1
  assert_equals 1 "$(status_rows hl blocked permission-prompt-held)" "once the other pass is done, the held prompt is reported once"
  pass "tool approval: one Escape, verified gone, then a durable rewrite instruction, one pass at a time per worker, and no key without a saved checksum"
}

test_prompt_after_escape_gets_no_instruction() {
  make_home
  worker nt claude "$FIX/claude-2.1.325-bash-prompt.txt" "$FIX/claude-2.1.325-trust.txt"
  printf 'work output\n Continue with paid usage?\n ❯ 1. Yes\n   2. No\n\n Enter to confirm · Esc to cancel\n' > "$H/paid-after.txt"
  worker np claude "$FIX/claude-2.1.325-bash-prompt.txt" "$H/paid-after.txt"
  run_wd 0 once >/dev/null 2>&1 || fail "the watchdog pass failed"
  local id
  for id in nt np; do
    assert_equals "$ESC" "$(typed "$id")" "only the one Escape reaches worker $id: $(typed "$id" | od -c | head -3)"
    assert_equals '' "$(inbox_text "$id")" "no instruction, and so no doorbell, goes to worker $id"
    assert_equals 0 "$(ledger_rows steer "done" "worker:$id")" "no steer is recorded for worker $id"
  done
  assert_equals 1 "$(status_rows nt blocked permission-prompt-held)" "a trust dialog behind the declined prompt is held: $(cat "$H/state/nt.status" 2>&1; ledger | grep nt | cut -f4-8)"
  assert_equals 1 "$(status_rows np blocked permission-prompt-hardstop)" "a paid-usage picker behind the declined prompt is a hard stop: $(cat "$H/state/np.status" 2>&1)"
  assert_grep "shows a spend prompt after a declined tool call" "$H/state/np.status" "the hard stop names its category"
  make_home
  worker nc claude "$FIX/claude-2.1.325-bash-prompt.txt" "$FIX/claude-2.1.325-after-escape.txt"
  PP_COMPOSER=unknown run_wd 0 once >/dev/null 2>&1 || fail "the watchdog pass failed"
  assert_equals "$ESC" "$(typed nc)" "only the one Escape reaches a worker whose composer is not proven empty"
  assert_equals '' "$(inbox_text nc)" "no instruction goes to a composer that is not proven empty"
  assert_equals 1 "$(status_rows nc blocked permission-prompt-held)" "a composer that is not proven empty after Escape is held"
  pass "after Escape: a trust dialog, a paid-usage picker, or an unproven composer gets no instruction, no doorbell, and a keyed blocked line"
}

test_declining_dialogs_on_workers_get_no_key() {
  local id
  make_home
  full_imports /Users/u/work/shared/notes.md > "$H/imports.txt"
  printf '%s\n' "$CODEX_HOOKS" > "$H/codex-hooks.txt"
  worker cx codex "$H/codex-hooks.txt"
  full_bypass > "$H/bypass.txt"
  worker im claude "$H/imports.txt"
  worker by claude "$H/bypass.txt"
  worker dn claude "$FIX/claude-2.1.325-bash-prompt.txt" "$FIX/claude-2.1.325-after-escape.txt"
  printf 'do-not-touch=%s\n' "$WP" >> "$H/config/watchdog"
  run_wd 0 once >/dev/null 2>&1 || fail "the watchdog pass failed"
  for id in im by dn cx; do
    assert_equals '' "$(typed "$id")" "no key reaches worker $id"
    assert_equals 1 "$(status_rows "$id" blocked permission-prompt-held)" "worker $id is reported as held"
  done
  assert_grep "external-imports" "$H/state/im.status" "the imports dialog names its reason"
  assert_grep "bypass-confirm" "$H/state/by.status" "the bypass confirmation names its reason"
  assert_grep "do-not-touch" "$H/state/dn.status" "the do-not-touch hold names its reason"
  assert_grep "hooks-review" "$H/state/cx.status" "the Codex hook review names its reason"
  assert_grep "permission prompt waiting on worker cx" "$H/data/watchdog/status.md" "the Codex dialog the picker detector misses still gets the waiting gap"
  local mark
  mark=$(find "$H/state/watchdog/permission" -name '*-cx.open' 2>/dev/null | head -n 1)
  [ -n "$mark" ] || fail "the Codex hold keeps its open marker"
  mark=${mark%-cx.open}
  codex_approval 'cat ~/.netrc' > "$H/codex-netrc.txt"
  worker cl codex "$H/codex-netrc.txt"
  mkdir "$mark-cl.lock"
  run_wd 200 once >/dev/null 2>&1
  assert_equals '' "$(typed cl)" "a Codex hard stop another pass is acting on gets no key"
  assert_equals 0 "$(status_rows cl blocked permission-prompt-hardstop)" "the pass without the lock writes no blocked line"
  assert_grep "permission prompt waiting on worker cl" "$H/data/watchdog/status.md" "a Codex hard stop still gets the waiting gap while another pass holds the lock"
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
  worker stuck claude "$FIX/claude-2.1.325-bash-prompt.txt"
  run_wd 1000 once >/dev/null 2>&1
  assert_equals 1 "$(typed stuck | tr -cd '\033' | wc -c | tr -d ' ')" "a prompt that stays after Escape got one Escape"
  assert_equals 1 "$(ledger_rows decline failed worker:stuck)" "the failed decline is recorded"
  run_wd 1300 once >/dev/null 2>&1
  assert_equals 1 "$(typed stuck | tr -cd '\033' | wc -c | tr -d ' ')" "the same prompt never gets a second Escape on a later pass"
  pass "decline guard: a repeated prompt, a prompt past the cap, and a prompt that stays after Escape are held, each reported once"
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

  make_home
  printf 'Accessing workspace:\n\n/work/project\n\nDo you trust the contents of this project?\n\nAntigravity CLI requires permission to read, edit, and execute files here.\n\n> Yes, I trust this folder\n  No, exit\n' > "$H/agy-trust.txt"
  worker ag agy "$H/agy-trust.txt"
  run_wd 0 once >/dev/null 2>&1
  assert_equals '' "$(typed ag)" "no key reaches the Antigravity trust picker"
  assert_equals 0 "$({ cat "$H/control.log" 2>/dev/null || true; } | grep -c '^ag relaunch' || true)" "the Antigravity worker is never relaunched, so its spawn never answers the dialog: $(ledger | cut -f4-8)"
  assert_equals 1 "$(status_rows ag blocked permission-prompt-held)" "the Antigravity trust picker is reported as held"
  assert_grep "trust-relaunch-answers" "$H/state/ag.status" "the held line names why"
  assert_grep "waiting on worker ag" "$H/data/watchdog/status.md" "a held Antigravity trust picker still gets the waiting gap"
  pass "trust dialog: no key, a controlled relaunch once per window, and a refusal is reported"
}

test_failed_declines_count_toward_cap() {
  make_home 'permission-decline-cap=2'
  bash_prompt_with 'touch /tmp/probe/a.txt' > "$H/a.txt"
  bash_prompt_with 'touch /tmp/probe/b.txt' > "$H/b.txt"
  bash_prompt_with 'touch /tmp/probe/c.txt' > "$H/c.txt"
  worker cap claude "$H/a.txt"
  run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(typed cap | tr -cd '\033' | wc -c | tr -d ' ')" "the first prompt that stays after Escape got one Escape"
  repaint cap "$H/b.txt"
  run_wd 300 once >/dev/null 2>&1
  assert_equals 1 "$(typed cap | tr -cd '\033' | wc -c | tr -d ' ')" "a second distinct prompt got one Escape"
  assert_equals 2 "$(ledger_rows decline failed worker:cap)" "both failed declines are recorded: $(ledger | cut -f4-8)"
  repaint cap "$H/c.txt"
  run_wd 600 once >/dev/null 2>&1
  assert_equals 0 "$(typed cap | tr -cd '\033' | wc -c | tr -d ' ')" "a third prompt past the cap gets no key"
  assert_equals 1 "$(status_rows cap blocked permission-prompt-held)" "the worker stays reported as held by one open line"
  pass "decline cap: failed declines count toward the hourly cap"
}

test_hardstop_prompts_are_never_answered() {
  make_home
  bash_prompt_with 'security find-generic-password -s gh -w' > "$H/cred.txt"
  bash_prompt_with 'rm -rf build/' > "$H/rm.txt"
  printf ' You have reached your limit. Add funds to continue?\n ❯ 1. Buy more credits\n   2. Wait\n\n Enter to confirm · Esc to cancel\n' > "$H/spend.txt"
  worker cred claude "$H/cred.txt" "$FIX/claude-2.1.325-after-escape.txt"
  worker rm claude "$H/rm.txt" "$FIX/claude-2.1.325-after-escape.txt"
  worker spend claude "$H/spend.txt"
  { cat "$FIX/claude-2.1.325-trust.txt"; printf '%s\n' '────────────────────────────────' '❯ ' '────────────────────────────────' ' Continue with paid usage?' ' ❯ Yes' '   No' '' ' Enter to confirm · Esc to cancel'; } > "$H/stale.txt"
  worker stale claude "$H/stale.txt"
  run_wd 0 once >/dev/null 2>&1 || fail "the watchdog pass failed"
  run_wd 300 once >/dev/null 2>&1
  local id
  for id in cred rm spend stale; do
    assert_equals '' "$(typed "$id")" "no key reaches the $id prompt"
    assert_equals 1 "$(status_rows "$id" blocked permission-prompt-hardstop)" "the $id prompt is reported once as a hard stop"
  done
  assert_grep "shows a credential prompt" "$H/state/cred.status" "the keychain prompt names its category"
  assert_grep "shows a destructive prompt" "$H/state/rm.status" "the remove prompt names its category"
  assert_grep "shows a spend prompt" "$H/state/spend.status" "the add-funds prompt names its category"
  assert_no_grep "find-generic-password" "$H/state/cred.status" "the blocked line carries no prompt text"
  assert_equals 0 "$(ledger_rows decline pending)" "no hard stop is declined"
  assert_equals '' "$(cat "$H/control.log" 2>/dev/null)" "no hard stop is relaunched"

  printf 'work output\n> \n' > "$H/plain.txt"
  repaint cred "$H/plain.txt"
  run_wd 600 once >/dev/null 2>&1
  assert_equals 1 "$(status_rows cred resolved permission-prompt-hardstop)" "the hard stop is resolved once the prompt leaves"
  pass "hard stops: credential, destructive, and spend prompts get no key and one keyed blocked line"
}

test_hardstop_never_reaches_council() {
  make_home 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  printf 'work output\n Delete the build cache?\n ❯ 1. Yes\n   2. No\n\n Enter to confirm · Esc to cancel\n' > "$H/rm-after.txt"
  worker hc claude "$FIX/claude-2.1.325-bash-prompt.txt" "$H/rm-after.txt"
  : > "$CALLS_LOG"
  run_wd 0 once >/dev/null 2>&1 || fail "the watchdog pass failed"
  assert_equals "$ESC" "$(typed hc)" "only the one Escape reaches the worker"
  assert_equals 1 "$(status_rows hc blocked permission-prompt-hardstop)" "the destructive prompt after Escape is a hard stop: $(cat "$H/state/hc.status" 2>&1)"
  run_wd 2000 once >/dev/null 2>&1
  run_wd 4500 once >/dev/null 2>&1
  run_wd 7000 once >/dev/null 2>&1
  assert_equals "$ESC" "$(typed hc)" "no later pass types into the destructive prompt"
  assert_equals 0 "$(grep -cE '^(claude|agy) ' "$CALLS_LOG")" "no council or judge seat is called: $(cat "$CALLS_LOG")"
  assert_equals '' "$(ledger | awk -F'\t' '$5 ~ /permission-prompt-hardstop/ && $6 == "council" && $7 != "held"')" "no council convenes on the hard stop: $(ledger | cut -f4-8)"
  local out
  out=$(run_wd 7100 council --task hc --key permission-prompt-hardstop 2>&1) || true
  assert_contains "$out" "held" "a direct council request on the hard stop is held for the owner: $out"
  assert_equals 0 "$(grep -cE '^(claude|agy) ' "$CALLS_LOG")" "the direct request calls no seat either"
  pass "hard stop after Escape: the keyed blocked line is the owner's and never reaches a council"
}

test_externally_resolved_hardstop_reopens() {
  make_home
  bash_prompt_with 'cat ~/.ssh/id_ed25519' > "$H/key.txt"
  worker xr claude "$H/key.txt"
  run_wd 0 once >/dev/null 2>&1 || fail "the watchdog pass failed"
  assert_equals 1 "$(status_rows xr blocked permission-prompt-hardstop)" "the private-key read is a hard stop"
  FM_HOME="$H" bash "$ROOT/bin/fm-send.sh" xr --resolve-key permission-prompt-hardstop "the key read was answered" >/dev/null 2>&1
  assert_equals 1 "$(grep -c '^resolved .*\[key=permission-prompt-hardstop\]' "$H/state/xr.status")" "the answer closes the hard stop: $(cat "$H/state/xr.status")"
  printf ' Continue with paid usage?\n ❯ 1. Yes\n   2. No\n\n Enter to confirm · Esc to cancel\n' > "$H/paid.txt"
  repaint xr "$H/paid.txt"
  run_wd 300 once >/dev/null 2>&1
  assert_equals 2 "$(status_rows xr blocked permission-prompt-hardstop)" "a new hard stop after an outside answer is reported again: $(cat "$H/state/xr.status")"
  run_wd 600 once >/dev/null 2>&1
  assert_equals 2 "$(status_rows xr blocked permission-prompt-hardstop)" "the reopened hard stop is still reported only once"
  assert_equals '' "$(typed xr)" "no key reaches either prompt"
  pass "hard stop: a key another writer resolved does not hide the next hard stop"
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

  make_home
  sed -i.bak 's/^mode=act$/mode=dry-run/' "$H/config/watchdog"
  worker dm claude "$FIX/claude-2.1.325-bash-prompt.txt" "$FIX/claude-2.1.325-after-escape.txt"
  run_wd 0 once >/dev/null 2>&1
  assert_equals '' "$(typed dm)" "an unset permission-route follows mode=dry-run and presses nothing"
  assert_equals 1 "$(ledger_rows decline dry-run worker:dm)" "mode=dry-run records what it would do: $(ledger | cut -f4-8)"

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
  test_structure_decides_not_words \
  test_antigravity_trust_screen_classifies \
  test_failed_declines_count_toward_cap \
  test_tool_approval_is_declined_and_steered \
  test_prompt_after_escape_gets_no_instruction \
  test_declining_dialogs_on_workers_get_no_key \
  test_repeated_or_capped_prompts_hold \
  test_trust_dialog_relaunches_without_a_key \
  test_hardstop_prompts_are_never_answered \
  test_hardstop_never_reaches_council \
  test_externally_resolved_hardstop_reopens \
  test_unknown_harness_dry_run_and_off
