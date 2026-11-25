#!/usr/bin/env bash
# tests/fm-permission-route.test.sh - the permission prompt route
# (bin/fm-permission-route.sh).
#
# Every case runs the real script as the harness runs it: a hook payload on
# stdin, a disposable state directory holding a real task record, and the
# script's stdout read as the hook answer. The keyed wake is read back through
# bin/fm-classify-lib.sh's own open-decision fold, the reader supervision uses.
# The real-harness half lives in tests/fm-permission-route-live-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-permission-route-tests)
ROUTE="$ROOT/bin/fm-permission-route.sh"
BT='`'

# The established class: an assignment, an unquoted heredoc whose body holds a
# backtick, and a later command.
class_command() {  # [<tail-command>]
  printf 'N=/nonexistent/n; cat <<EOF\n%strue%s\nEOF\n%s' "$BT" "$BT" "${1:-echo \$N}"
}

new_home() {  # <name> [<meta key=value>...]
  local home="$TMP_ROOT/$1"
  shift
  mkdir -p "$home/state" "$home/config"
  if [ "$#" -eq 0 ]; then
    set -- kind=ship harness=claude approval_mode=bypass
  fi
  fm_write_meta "$home/state/task.meta" "$@"
  printf '%s' "$home"
}

bash_payload() {  # <command> [<extra tool_input json>]
  local extra=${2:-}
  [ -n "$extra" ] || extra='{}'
  jq -cn --arg command "$1" --argjson extra "$extra" '{
    hook_event_name: "PermissionRequest", permission_mode: "bypassPermissions",
    tool_name: "Bash", tool_input: ({command: $command, description: "d"} + $extra),
    permission_suggestions: [], cwd: "/x", session_id: "s"}'
}

finished_payload() {  # <command> [<event>]
  jq -cn --arg command "$1" --arg event "${2:-PostToolUse}" '{
    hook_event_name: $event, permission_mode: "bypassPermissions",
    tool_name: "Bash", tool_input: {command: $command, description: "another"}}'
}

# request <home> <payload>: run the hook as an unattended worker. Sets OUT, RC.
request() {
  OUT=$(printf '%s' "$2" | AK_LIFECYCLE_POLICY=unattended bash "$ROUTE" claude-request "$1/state" task)
  RC=$?
}

settle() {  # <home> <event> [<payload>]
  printf '%s' "${3:-}" | bash "$ROUTE" claude-settled "$1/state" task "$2"
}

classify() {  # <command>
  printf '%s' "$1" | bash "$ROUTE" classify
}

HELD=permission-prompt-held
HARDSTOP=permission-prompt-hardstop

# open_keys <home>: the route's keys the supervisor's fold still reads as
# open, sorted, on one row.
open_keys() {
  status_open_decisions "$1/state/task.status" ship | cut -f1 | grep '^permission-prompt' | sort | tr '\n' ' ' | sed 's/ $//'
}

key_is_open() {  # <home> [<key>]
  status_open_decisions "$1/state/task.status" ship | grep -q "^${2:-permission-prompt-[a-z]*}$(printf '\t')"
}

pane_clear() {  # <home> [<quiet-secs>]
  FM_PERMISSION_ROUTE_PANE_CLEAR_SECS=${2:-} bash "$ROUTE" claude-settled "$1/state" task pane-clear </dev/null
}

ledger_field() {  # <home> <row> <field>
  sed -n "${2}p" "$1/state/task.permission-route.tsv" 2>/dev/null | cut -f"$3"
}

assert_held() {  # <home> <category> <label> [<key>]
  expect_code 0 "$RC" "$3 exit"
  assert_equals "" "$OUT" "$3 prints no answer, so the prompt stays for a person"
  assert_equals "hold" "$(tail -n 1 "$1/state/task.permission-route.tsv" | cut -f2)" "$3 is recorded as a hold"
  assert_equals "$2" "$(tail -n 1 "$1/state/task.permission-route.tsv" | cut -f3)" "$3 records its category"
  assert_equals "${4:-$HELD}" "$(open_keys "$1")" "$3 opens exactly its supervisor wake"
}

test_identified_class_is_refused_with_a_fix_instruction() {
  local home command sha
  home=$(new_home refuse)
  command=$(class_command)
  request "$home" "$(bash_payload "$command")"
  expect_code 0 "$RC" "refusal exit"
  assert_equals "PermissionRequest" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName')" "the answer names its hook event"
  assert_equals "deny" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.decision.behavior')" "the class is refused, never allowed"
  assert_contains "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.decision.message')" "did not run" "the refusal says the command did not run"
  assert_contains "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.decision.message')" "<<'EOF'" "the refusal carries the fix"
  assert_not_contains "$OUT" "nonexistent" "the refusal never echoes the command"
  sha=$(printf '%s' "$command" | shasum -a 256 | cut -d' ' -f1)
  assert_equals "refuse" "$(ledger_field "$home" 1 2)" "the refusal is recorded"
  assert_equals "class" "$(ledger_field "$home" 1 3)" "the refusal records its class"
  assert_equals "$sha" "$(ledger_field "$home" 1 5)" "the record names the command by hash"
  assert_no_grep "nonexistent" "$home/state/task.permission-route.tsv" "the record never holds the command text"
  assert_absent "$home/state/task.status" "a refusal wakes nobody"
  assert_absent "$home/state/task.permission-held" "a refusal leaves no open hold"
  pass "the identified prompt class is refused with a fix instruction and recorded"
}

test_each_reserved_category_is_held_for_a_person() {
  local row category tail home
  while IFS='|' read -r category tail; do
    home=$(new_home "reserved-$category")
    request "$home" "$(bash_payload "$(class_command "$tail")")"
    assert_held "$home" "$category" "a $category prompt" "$HARDSTOP"
    assert_grep "only the owner answers it" "$home/state/task.status" "a $category wake says who may answer it"
  done <<'ROWS'
credential|cat ~/.aws/config
sign-in|gcloud auth login
spend|npm run upgrade-billing
security|sudo ls
destructive|git -C . push origin main
production|kubectl get pods
release|git tag v1.2.0
ROWS
  home=$(new_home reserved-divergence)
  request "$home" "$(bash_payload "$(class_command 'echo done')")"
  assert_equals "deny" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.decision.behavior')" \
    "the same command without a reserved word is refused, so the holds above came from the reserved word"
  pass "credential, sign-in, spend, security, destructive, production, and release prompts are held under the owner-reserved key"
}

test_command_text_verdicts() {
  local label want command
  while IFS='|' read -r label want command; do
    command=$(printf '%b' "$command" | sed "s/@/$BT/g")
    assert_equals "$want" "$(classify "$command")" "classify: $label"
  done <<'ROWS'
minimal class|refuse|N=1; cat <<EOF\n'@true@'\nEOF\necho $N
tab-stripped heredoc|refuse|cat <<-EOF\n\t@x@\n\tEOF\necho y
second heredoc carries the backtick|refuse|cat <<A; cat <<B\nplain\nA\n@t@\nB\necho z
test and loop keywords|refuse|cat <<EOF\n@t@\nEOF\nif [ -n "$x" ]; then echo y; fi; for f in $A; do echo $f; done
quoted delimiter|hold unidentified|cat <<'EOF'\n@true@\nEOF\necho x
partly quoted delimiter|hold unidentified|cat <<E'O'F\n@true@\nEOF\necho x
escaped delimiter|hold unidentified|cat <<\\EOF\n@true@\nEOF\necho x
here-string|hold unidentified|cat <<<"@true@"
arithmetic shift|hold unidentified|echo $((1 << n))\necho @date@
unclosed heredoc|hold unidentified|cat <<EOF\n@true@
escaped backticks only|hold unidentified|cat <<EOF\n\\@true\\@\nEOF
no heredoc|hold unidentified|echo hello
computed command word|hold computed|cat <<EOF\n@t@\nEOF\n$TOOL run
quoted computed command word|hold computed|cat <<EOF\n@t@\nEOF\n"$BIN/x" run
computed word behind a redirection|hold computed|cat <<EOF >out\n@t@\nEOF\n>log $CMD
glob command word|hold computed|cat <<EOF\n@t@\nEOF\n./bin/*.sh
command word from a backtick substitution|hold computed|cat <<EOF\n@t@\nEOF\n@t@tool@t@ run
eval wrapper|hold wrapper|cat <<EOF\n@t@\nEOF\neval "$X"
shell wrapper in a subshell|hold wrapper|cat <<EOF\n@t@\nEOF\n( true && bash tests/a.test.sh )
dot wrapper|hold wrapper|cat <<EOF\n@t@\nEOF\n. ./lib.sh
removal split by quotes|hold destructive|cat <<EOF\n@t@\nEOF\nr''m -rf target
removal split by a line continuation|hold destructive|cat <<EOF\n@t@\nEOF\nr\\\nm -rf target
network transfer|hold security|cat <<EOF\n@t@\nEOF\ncurl https://example.invalid
release word|hold production|cat <<EOF\n@t@\nEOF\nnpm publish
tag from the watchdog vocabulary|hold release|cat <<EOF\n@t@\nEOF\ngit tag v1.2.0
escape byte|hold shape|cat <<EOF\n@t@\nEOF\nprintf '\033[0m'
wrapper behind a quoted assignment|hold computed|cat <<EOF\n@t@\nEOF\nFOO="a b" eval "$X"
computed word behind a quoted redirection|hold computed|cat <<EOF\n@t@\nEOF\n> "a b" $cmd
wrapper split by a line continuation|hold computed|cat <<EOF\n@t@\nEOF\nev\\\nal "$X"
plain assignment and redirection|refuse|cat <<EOF\n@t@\nEOF\nN=1 2> err.log echo hi
reserved word split by quotes|hold release|cat <<EOF\n@t@\nEOF\ngit t"a"g v1.2.0
ROWS
  assert_equals "hold shape" "$(classify "")" "classify: empty command"
  # shellcheck disable=SC2046
  assert_equals "hold computed" "$(classify "$(printf 'A%s=1 ' $(seq 1 70))$(class_command true)")" \
    "classify: more leading assignments than the scan reads leave the command word unknown"
  assert_equals "hold shape" "$(printf '%s' "$(class_command)" | FM_PERMISSION_ROUTE_MAX_BYTES=10 bash "$ROUTE" classify)" "classify: over the byte bound"
  pass "the command text is refused only for the closed, plain, unquoted heredoc class"
}

test_attended_session_is_left_alone() {
  local home out
  home=$(new_home attended)
  out=$(bash_payload "$(class_command)" | env -u AK_LIFECYCLE_POLICY bash "$ROUTE" claude-request "$home/state" task)
  expect_code 0 "$?" "attended exit"
  assert_equals "" "$out" "an attended session gets no answer"
  out=$(bash_payload "$(class_command)" | AK_LIFECYCLE_POLICY=attended bash "$ROUTE" claude-request "$home/state" task)
  assert_equals "" "$out" "a named attended policy gets no answer"
  assert_absent "$home/state/task.permission-route.tsv" "an attended session records nothing"
  assert_absent "$home/state/task.status" "an attended session wakes nobody"
  pass "a session without the unattended policy is neither answered nor recorded"
}

test_posture_tool_and_input_are_held() {
  local home payload
  home=$(new_home posture-auto kind=ship harness=claude approval_mode=auto)
  request "$home" "$(bash_payload "$(class_command)")"
  assert_held "$home" posture "a worker launched in auto posture"
  home=$(new_home posture-secondmate kind=secondmate harness=claude approval_mode=bypass)
  request "$home" "$(bash_payload "$(class_command)")"
  assert_held "$home" posture "a second mate"
  home=$(new_home posture-harness kind=ship harness=codex approval_mode=bypass)
  request "$home" "$(bash_payload "$(class_command)")"
  assert_held "$home" posture "another harness"
  home=$(new_home posture-mode)
  request "$home" "$(bash_payload "$(class_command)" | jq -c '.permission_mode = "default"')"
  assert_held "$home" posture "a payload outside bypass mode"
  home=$(new_home posture-nometa)
  rm -f "$home/state/task.meta"
  request "$home" "$(bash_payload "$(class_command)")"
  assert_held "$home" posture "a task with no record"
  home=$(new_home tool)
  payload=$(jq -cn '{hook_event_name: "PermissionRequest", permission_mode: "bypassPermissions", tool_name: "Write", tool_input: {file_path: "/x/.claude/settings.json", content: "{}"}}')
  request "$home" "$payload"
  assert_held "$home" tool "a file write to a settings path" "$HARDSTOP"
  assert_equals "Write" "$(ledger_field "$home" 1 4)" "the hold records the tool"
  home=$(new_home tool-plain)
  payload=$(jq -cn '{hook_event_name: "PermissionRequest", permission_mode: "bypassPermissions", tool_name: "Write", tool_input: {file_path: "/x/notes.txt", content: "plain"}}')
  request "$home" "$payload"
  assert_held "$home" tool "a file write that names no reserved category"
  home=$(new_home tool-nested)
  payload=$(jq -cn '{hook_event_name: "PermissionRequest", permission_mode: "bypassPermissions", tool_name: "mcp__x__run", tool_input: {steps: [{note: "plain"}, {argv: ["gh", "auth", "login"]}]}}')
  request "$home" "$payload"
  assert_held "$home" tool "a tool whose nested input names a sign-in" "$HARDSTOP"
  home=$(new_home input-sandbox)
  request "$home" "$(bash_payload "$(class_command)" '{"dangerouslyDisableSandbox": true}')"
  assert_held "$home" input "a request to leave the sandbox" "$HARDSTOP"
  home=$(new_home input-unknown)
  request "$home" "$(bash_payload "$(class_command)" '{"surprise": 1}')"
  assert_held "$home" input "a request with an unknown input key"
  home=$(new_home malformed)
  request "$home" 'not json'
  assert_held "$home" posture "a malformed payload" "$HARDSTOP"
  home=$(new_home oversize)
  OUT=$(bash_payload "$(class_command)" | AK_LIFECYCLE_POLICY=unattended FM_PERMISSION_ROUTE_MAX_BYTES=10 bash "$ROUTE" claude-request "$home/state" task)
  RC=$?
  assert_held "$home" shape "a command past the size limit" "$HARDSTOP"
  pass "wrong posture, another tool, and unexpected input are held, and a request that cannot be read whole is owner-reserved"
}

test_repeat_and_ceiling_stop_a_refusal_loop() {
  local home
  home=$(new_home caps)
  request "$home" "$(bash_payload "$(class_command 'echo one')")"
  assert_equals "deny" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.decision.behavior')" "the first request is refused"
  request "$home" "$(bash_payload "$(class_command 'echo one')")"
  assert_held "$home" repeat "the same command again"
  home=$(new_home ceiling)
  request "$home" "$(bash_payload "$(class_command 'echo one')")"
  OUT=$(bash_payload "$(class_command 'echo two')" | AK_LIFECYCLE_POLICY=unattended FM_PERMISSION_ROUTE_MAX_REFUSALS=2 bash "$ROUTE" claude-request "$home/state" task)
  assert_equals "deny" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.decision.behavior')" "a second distinct command is refused under a ceiling of two"
  OUT=$(bash_payload "$(class_command 'echo three')" | AK_LIFECYCLE_POLICY=unattended FM_PERMISSION_ROUTE_MAX_REFUSALS=2 bash "$ROUTE" claude-request "$home/state" task)
  RC=$?
  assert_held "$home" ceiling "a third distinct command over the ceiling"
  pass "a repeated command and a reached ceiling are held instead of refused again"
}

test_unwritable_record_is_a_hold() {
  local home
  home=$(new_home record)
  mkdir "$home/state/task.permission-route.tsv"
  request "$home" "$(bash_payload "$(class_command)")"
  expect_code 0 "$RC" "unwritable record exit"
  assert_equals "" "$OUT" "no refusal is printed when it cannot be recorded first"
  key_is_open "$home" "$HELD" || fail "the supervisor is woken when the record cannot be written"
  assert_grep "held as record" "$home/state/task.status" "the wake names the record failure"
  pass "a refusal that cannot be recorded becomes a hold that still wakes the supervisor"
}

test_hold_opens_once_and_closes_when_the_request_finishes() {
  local home held other
  home=$(new_home lifecycle)
  held=$(class_command 'sudo ls')
  other=$(class_command 'kubectl get pods')
  request "$home" "$(bash_payload "$held")"
  request "$home" "$(bash_payload "$held")"
  assert_equals "1" "$(grep -c '^blocked ' "$home/state/task.status")" "the same waiting request wakes the supervisor once"
  request "$home" "$(bash_payload "$other")"
  assert_equals "2" "$(grep -c '^blocked ' "$home/state/task.status")" "a second waiting request wakes the supervisor again"
  settle "$home" tool-finished "$(finished_payload 'echo unrelated')"
  key_is_open "$home" || fail "an unrelated finished tool call must not close the hold"
  settle "$home" tool-finished "$(finished_payload "$held")"
  key_is_open "$home" || fail "the hold stays open while another held request waits"
  settle "$home" tool-finished "$(finished_payload "$other" PostToolUseFailure)"
  ! key_is_open "$home" || fail "the hold closes when the last held request finishes"
  assert_absent "$home/state/task.permission-held" "a closed hold leaves no held set"
  assert_absent "$home/state/task.permission-lock" "the lock is released"
  assert_equals "1" "$(grep -c '^resolved ' "$home/state/task.status")" "the hold closes once"
  settle "$home" tool-finished "$(finished_payload "$held")"
  assert_equals "1" "$(grep -c '^resolved ' "$home/state/task.status")" "a later tool call adds no second close"
  pass "a hold wakes once per waiting request and closes when the last one finishes"
}

test_session_end_and_supervisor_answer_close_a_hold() {
  local home held
  home=$(new_home session-end)
  held=$(class_command 'sudo ls')
  request "$home" "$(bash_payload "$held")"
  key_is_open "$home" || fail "the hold opens"
  settle "$home" session-end
  ! key_is_open "$home" || fail "session end closes the hold"
  assert_absent "$home/state/task.permission-held" "session end clears the held set"
  settle "$home" session-end
  assert_equals "1" "$(grep -c '^resolved ' "$home/state/task.status")" "session end with no hold writes nothing"

  home=$(new_home answered)
  request "$home" "$(bash_payload "$held")"
  printf '%s\n' "resolved [key=$HARDSTOP]: answered: denied in the terminal" >>"$home/state/task.status"
  ! key_is_open "$home" || fail "the supervisor answer closes the key"
  request "$home" "$(bash_payload "$held")"
  key_is_open "$home" || fail "the same request waiting again after the supervisor closed the key wakes the supervisor again"
  assert_equals "2" "$(grep -c '^blocked ' "$home/state/task.status")" "the second wait is a new wake"
  pass "session end closes a hold, and a hold the supervisor closed can open again"
}

test_each_key_closes_on_its_own() {
  local home plain reserved
  home=$(new_home two-keys)
  plain='echo hello'
  reserved=$(class_command 'sudo ls')
  request "$home" "$(bash_payload "$plain")"
  assert_held "$home" unidentified "a request that names no reserved category"
  request "$home" "$(bash_payload "$reserved")"
  assert_equals "$HARDSTOP $HELD" "$(open_keys "$home")" "two waiting requests of different kinds hold both keys open"
  assert_equals "$HARDSTOP $HELD" "$(bash "$ROUTE" held-keys "$home/state" task | sort | tr '\n' ' ' | sed 's/ $//')" "held-keys names both"
  settle "$home" tool-finished "$(finished_payload "$plain")"
  assert_equals "$HARDSTOP" "$(open_keys "$home")" "the finished request closes its own key and leaves the owner-reserved one"
  assert_equals "$HARDSTOP" "$(bash "$ROUTE" held-keys "$home/state" task)" "held-keys names the one still open"
  settle "$home" tool-finished "$(finished_payload "$reserved")"
  assert_equals "" "$(open_keys "$home")" "the second finished request closes the owner-reserved key"
  assert_equals "" "$(bash "$ROUTE" held-keys "$home/state" task)" "held-keys prints nothing when nothing is held"
  assert_absent "$home/state/task.permission-held" "no held set is left"
  pass "each waiting request closes only the key it was held under"
}

test_pane_clear_closes_only_a_settled_ordinary_hold() {
  local home
  home=$(new_home pane-clear)
  request "$home" "$(bash_payload 'echo hello')"
  request "$home" "$(bash_payload "$(class_command 'sudo ls')")"
  pane_clear "$home"
  assert_equals "$HARDSTOP $HELD" "$(open_keys "$home")" "a hold written a moment ago is not closed: its prompt may not be drawn yet"
  pane_clear "$home" 0
  assert_equals "$HARDSTOP" "$(open_keys "$home")" "a clear pane closes the ordinary hold and never the owner-reserved one"
  assert_grep "key=$HELD]: permission prompt no longer waiting: the worker pane shows an empty composer" "$home/state/task.status" "the close says what was proven"
  pane_clear "$home" 0
  assert_equals "1" "$(grep -c '^resolved ' "$home/state/task.status")" "a second clear pane writes nothing more"
  assert_equals "$HARDSTOP" "$(open_keys "$home")" "the owner-reserved hold still waits"
  assert_absent "$home/state/task.permission-lock" "the lock is released"

  # A key the supervisor already answered leaves no row behind for the pane.
  home=$(new_home pane-clear-answered)
  request "$home" "$(bash_payload 'echo hello')"
  printf '%s\n' "resolved [key=$HELD]: answered: declined in the terminal" >>"$home/state/task.status"
  pane_clear "$home" 0
  assert_equals "1" "$(grep -c '^resolved ' "$home/state/task.status")" "an answered key gets no second close"
  assert_absent "$home/state/task.permission-held" "its row is dropped"
  pass "a proven-clear pane closes only an ordinary hold that has had time to draw its prompt"
}

test_reserved_request_is_always_reported() {
  local home i
  # The ordinary key stops taking rows at its limit; the reserved key does not.
  home=$(new_home limit)
  for i in 1 2 3; do
    FM_PERMISSION_ROUTE_MAX_HELD=2 request "$home" "$(bash_payload "echo hello $i")"
  done
  assert_equals "2" "$(grep -c "^blocked .*key=$HELD\]" "$home/state/task.status")" "an ordinary request past the limit joins the open decision"
  assert_equals "3" "$(grep -c . "$home/state/task.permission-route.tsv")" "it is still recorded"
  for i in 1 2 3; do
    FM_PERMISSION_ROUTE_MAX_HELD=2 request "$home" "$(bash_payload "sudo ls $i")"
  done
  assert_equals "3" "$(grep -c "^blocked .*key=$HARDSTOP\]" "$home/state/task.status")" "every reserved request gets its line at the limit"
  assert_equals "$HARDSTOP $HELD" "$(bash "$ROUTE" held-keys "$home/state" task | sort | tr '\n' ' ' | sed 's/ $//')" "held-keys names the reserved key"

  # The same command asked again as a sandbox escape is a reserved request.
  home=$(new_home sandbox)
  request "$home" "$(bash_payload 'echo hello')"
  request "$home" "$(bash_payload 'echo hello' '{"dangerouslyDisableSandbox": true}')"
  assert_equals "$HARDSTOP $HELD" "$(open_keys "$home")" "the sandbox escape opens the owner-reserved key beside the ordinary one"
  settle "$home" tool-finished "$(finished_payload 'echo hello')"
  assert_equals "$HARDSTOP" "$(open_keys "$home")" "the finished ordinary call does not close the sandbox escape"

  # A request first held as ordinary and asked again with a reserved input.
  home=$(new_home rekey)
  request "$home" "$(jq -cn '{hook_event_name: "PermissionRequest", permission_mode: "bypassPermissions", tool_name: "Write", tool_input: {file_path: "/tmp/notes.txt", content: "x"}}')"
  assert_equals "$HELD" "$(open_keys "$home")" "a plain write is an ordinary hold"
  request "$home" "$(jq -cn '{hook_event_name: "PermissionRequest", permission_mode: "bypassPermissions", tool_name: "Write", tool_input: {file_path: "/tmp/notes.txt", content: "x", password: null}}')"
  assert_equals "$HARDSTOP $HELD" "$(open_keys "$home")" "a reserved key name with a null value is still owner-reserved"
  pass "a reserved request always gets its own line: at the ordinary limit, as a sandbox escape, and by a key name alone"
}

test_held_set_follows_the_latest_requests() {
  local home i rc
  # A request asked again restarts the quiet period before a pane-clear close.
  home=$(new_home asked-again)
  request "$home" "$(bash_payload 'echo hello')"
  awk -F '\t' -v OFS='\t' -v e="$(($(date +%s) - 3600))" '{ $3 = e; print }' "$home/state/task.permission-held" >"$home/held.new" \
    && mv "$home/held.new" "$home/state/task.permission-held"
  request "$home" "$(bash_payload 'echo hello')"
  assert_equals "1" "$(grep -c '^blocked ' "$home/state/task.status")" "a request asked again writes no second line"
  pane_clear "$home"
  assert_equals "$HELD" "$(open_keys "$home")" "a request asked again a moment ago is not closed from the pane: its prompt may not be drawn yet"

  # A request past the limit still waits when the others finish, so no
  # finished call closes the key then: the pane or the session end does.
  home=$(new_home overflow)
  for i in 1 2 3; do
    FM_PERMISSION_ROUTE_MAX_HELD=2 request "$home" "$(bash_payload "echo hello $i")"
  done
  for i in 1 2 3; do
    settle "$home" tool-finished "$(finished_payload "echo hello $i")"
  done
  assert_equals "$HELD" "$(open_keys "$home")" "a request past the limit keeps the key open when every finished call is in"
  assert_equals "2" "$(grep -c '^blocked ' "$home/state/task.status")" "and it wrote no line of its own under the open key"
  pane_clear "$home"
  assert_equals "$HELD" "$(open_keys "$home")" "a request asked a moment ago keeps the pane from closing it"
  pane_clear "$home" 0
  assert_equals "" "$(open_keys "$home")" "a proven-clear pane closes it"

  # A limit of zero is no limit to hide a hold behind.
  home=$(new_home zero)
  FM_PERMISSION_ROUTE_MAX_HELD=0 request "$home" "$(bash_payload 'echo hello')"
  assert_equals "$HELD" "$(open_keys "$home")" "a hold is reported under a limit of zero"

  # A request that arrives with no payload is not read whole.
  home=$(new_home empty)
  request "$home" ''
  assert_equals "$HARDSTOP" "$(open_keys "$home")" "an empty payload is held for the owner"

  # An input field this route does not know names another request.
  home=$(new_home field)
  request "$home" "$(bash_payload 'echo hello' '{"mode": "x"}')"
  assert_equals "$HELD" "$(open_keys "$home")" "a request with an unknown input field is held"
  settle "$home" tool-finished "$(finished_payload 'echo hello')"
  assert_equals "$HELD" "$(open_keys "$home")" "a finished call without that field does not close it"
  settle "$home" tool-finished "$(jq -cn '{hook_event_name: "PostToolUse", tool_name: "Bash", tool_input: {command: "echo hello", description: "another", mode: "x"}}')"
  assert_equals "" "$(open_keys "$home")" "the finished call with that field closes it"

  # A held set that cannot be read is an error to the watchdog, never no hold.
  if [ "$(id -u)" -ne 0 ]; then
    home=$(new_home unreadable-set)
    request "$home" "$(bash_payload 'echo hello')"
    chmod 000 "$home/state/task.permission-held"
    bash "$ROUTE" held-keys "$home/state" task >/dev/null 2>&1
    rc=$?
    settle "$home" tool-finished "$(finished_payload 'echo hello')"
    chmod 600 "$home/state/task.permission-held"
    assert_equals "1" "$rc" "held-keys fails on a held set it cannot read"
    assert_equals "1" "$(grep -c . "$home/state/task.permission-held")" "a held set that cannot be read is left as it is"
  fi
  pass "the held set follows the latest requests, tells requests apart by their input, and is never read as empty when it cannot be read"
}

test_unreadable_payload_never_matches_a_finished_call() {
  local home
  home=$(new_home unreadable)
  request "$home" 'not json'
  assert_equals "$HARDSTOP" "$(open_keys "$home")" "an unreadable request is owner-reserved"
  assert_equals "-" "$(cut -f2 "$home/state/task.permission-held")" "its row carries no request hash"
  request "$home" '{"tool_input": {'
  assert_equals "1" "$(grep -c '^blocked ' "$home/state/task.status")" "a second unreadable request joins the open decision"
  settle "$home" tool-finished '{"tool_name": "Bash", "tool_inp'
  settle "$home" tool-finished '{}'
  settle "$home" tool-finished ''
  assert_equals "$HARDSTOP" "$(open_keys "$home")" "an unreadable finished-tool payload closes nothing"
  settle "$home" session-end
  assert_equals "" "$(open_keys "$home")" "session end closes it"
  pass "an unreadable payload is held for the owner and no finished tool call closes it"
}

test_bad_task_id_and_missing_state_touch_nothing() {
  local home out
  home=$(new_home badid)
  out=$(bash_payload "$(class_command)" | AK_LIFECYCLE_POLICY=unattended bash "$ROUTE" claude-request "$home/state" '../task')
  expect_code 0 "$?" "bad id exit"
  assert_equals "" "$out" "a bad task id gets no answer"
  out=$(bash_payload "$(class_command)" | AK_LIFECYCLE_POLICY=unattended bash "$ROUTE" claude-request "$home/absent" task)
  expect_code 0 "$?" "missing state exit"
  assert_equals "" "$out" "a missing state directory gets no answer"
  assert_equals "task.meta" "$(ls -A "$home/state")" "nothing is written for a bad task id"
  bash "$ROUTE" claude-settled "$home/state" '../task' session-end </dev/null
  expect_code 0 "$?" "bad id settle exit"
  bash "$ROUTE" --help | grep -q 'claude-request <state-dir> <id>' || fail "--help prints the usage"
  bash "$ROUTE" nonsense >/dev/null 2>&1
  expect_code 2 "$?" "unknown subcommand exit"
  pass "a bad task id or a missing state directory writes nothing and answers nothing"
}

fm_test_run \
  test_identified_class_is_refused_with_a_fix_instruction \
  test_each_reserved_category_is_held_for_a_person \
  test_command_text_verdicts \
  test_attended_session_is_left_alone \
  test_posture_tool_and_input_are_held \
  test_repeat_and_ceiling_stop_a_refusal_loop \
  test_unwritable_record_is_a_hold \
  test_hold_opens_once_and_closes_when_the_request_finishes \
  test_session_end_and_supervisor_answer_close_a_hold \
  test_each_key_closes_on_its_own \
  test_pane_clear_closes_only_a_settled_ordinary_hold \
  test_reserved_request_is_always_reported \
  test_held_set_follows_the_latest_requests \
  test_unreadable_payload_never_matches_a_finished_call \
  test_bad_task_id_and_missing_state_touch_nothing
