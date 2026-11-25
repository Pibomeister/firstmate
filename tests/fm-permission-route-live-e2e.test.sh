#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the permission prompt route
# (bin/fm-permission-route.sh), which answers a prompt the vendor raises.
# Each case is one real `claude -p --dangerously-skip-permissions` session in
# its own disposable project, with the real script wired through the same four
# hook events bin/fm-spawn.sh registers and a disposable state directory that
# holds a real task record. It proves, against the installed Claude Code:
#   - the established prompt class is refused with the fix instruction, the
#     model reissues a command the harness can check, and that command runs;
#   - a request that names a reserved category is never answered, for six of
#     the categories (the portable test also covers release): the harness's
#     own refusal stands and the supervisor wake is written;
#   - an open hold closes when the held request is answered elsewhere and
#     finishes, whether the command succeeds or fails, and when the session
#     ends;
#   - a session without the unattended policy is left untouched.
# A second PermissionRequest hook stands in for the person who answers a held
# prompt, because a headless session has no dialog to answer.
# Claude keeps using its existing managed authentication. No fleet home,
# worktree, or session is touched. Set FM_PERMISSION_ROUTE_LIVE_EVIDENCE to a
# directory to keep each case's transcript and records.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PERMISSION_ROUTE_LIVE_E2E claude jq

ROUTE="$ROOT/bin/fm-permission-route.sh"
MODEL=${FM_PERMISSION_ROUTE_LIVE_MODEL:-haiku}
LIMIT=${FM_PERMISSION_ROUTE_LIVE_TIMEOUT:-300}
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
LAB=$(fm_test_tmproot fm-permission-route-live)
BT='`'
REFUSAL_MARK='Firstmate permission route: refused'
RESERVED='credential:password sign-in:login spend:purchase security:sudo destructive:rm production:production'

keep_evidence() {
  local dest=${FM_PERMISSION_ROUTE_LIVE_EVIDENCE:-} dir name
  [ -n "$dest" ] || return 0
  for dir in "$LAB"/*/; do
    name=$(basename "$dir")
    mkdir -p "$dest/$name"
    cp "$dir"prompt.txt "$dir"stream.jsonl "$dir"stderr.txt "$dir"work/.claude/settings.local.json "$dest/$name/" 2>/dev/null
    cp "$dir"home/state/task.status "$dir"home/state/task.permission-route.tsv "$dest/$name/" 2>/dev/null
  done
  return 0
}

fail() {
  keep_evidence
  printf 'not ok - %s: %s\n' "$CLAUDE_VERSION" "$1" >&2
  exit 1
}

# The established class, with <tail> as the command after the heredoc.
class_command() {  # <tail>
  printf 'N=/nonexistent/n; cat <<EOF\n%s%strue%s%s\nEOF\n%s' "'" "$BT" "$BT" "'" "$1"
}

# start_case <name> <attended|unattended> <tail> [answered]
# `answered` adds the stand-in for a person: a second hook that allows the
# request two seconds later, after the route has held it.
start_case() {
  local name=$1 policy=$2 tail=$3 answered=${4:-} dir state route_q state_q request settle ending allow
  dir="$LAB/$name"
  state="$dir/home/state"
  mkdir -p "$dir/work/.claude" "$state" "$dir/home/config"
  fm_write_meta "$state/task.meta" kind=ship harness=claude approval_mode=bypass
  route_q=$(printf '%q' "$ROUTE")
  state_q=$(printf '%q' "$state")
  request="$route_q claude-request $state_q task 2>/dev/null || true"
  settle="[ ! -e $(printf '%q' "$state/task.permission-held") ] || $route_q claude-settled $state_q task tool-finished 2>/dev/null || true"
  ending="$route_q claude-settled $state_q task session-end 2>/dev/null || true"
  allow=
  if [ -n "$answered" ]; then
    allow="sleep 2; printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"allow\"}}}'"
  fi
  jq -n --arg request "$request" --arg settle "$settle" --arg ending "$ending" --arg allow "$allow" '
    def hook($c): {hooks: [{type: "command", command: $c, timeout: 10}]};
    {hooks: {
      PermissionRequest: ([hook($request)] + (if $allow == "" then [] else [hook($allow)] end)),
      PostToolUse: [hook($settle)],
      PostToolUseFailure: [hook($settle)],
      SessionEnd: [hook($ending)]}}' >"$dir/work/.claude/settings.local.json"
  {
    printf 'Run the following shell command with the Bash tool exactly as written, byte for byte. '
    printf 'If the tool call is refused and the refusal gives a correction, apply that correction once and run the corrected command. '
    printf 'Otherwise do not run anything else. Then reply with the single word DONE.\n\n<command>\n'
    class_command "$tail"
    printf '\n</command>\n'
  } >"$dir/prompt.txt"
  (
    cd "$dir/work" || exit 1
    if [ "$policy" = unattended ]; then
      export AK_LIFECYCLE_POLICY=unattended
    else
      unset AK_LIFECYCLE_POLICY
    fi
    exec claude -p --dangerously-skip-permissions --setting-sources local --model "$MODEL" \
      --output-format stream-json --verbose --no-session-persistence
  ) <"$dir/prompt.txt" >"$dir/stream.jsonl" 2>"$dir/stderr.txt" &
  PIDS="$PIDS $!"
}

# Print each tool result as `<is_error>\t<text on one line>`.
results() {  # <name>
  jq -r '
    select(.type == "user") | .message.content[]? | select(.type == "tool_result")
    | [(.is_error // false | tostring),
       (.content | if type == "array" then map(.text? // "") | join(" ") else tostring end | gsub("[\n\t]"; " "))]
    | @tsv' "$LAB/$1/stream.jsonl" 2>/dev/null
}

ledger() {  # <name> -> `<verdict> <category>` rows
  cut -f2,3 "$LAB/$1/home/state/task.permission-route.tsv" 2>/dev/null | tr '\t' ' '
}

status_line() {  # <name> <n>
  sed -n "${2}p" "$LAB/$1/home/state/task.status" 2>/dev/null
}

# The harness asked, the route held the request, and nothing answered for it.
assert_held() {  # <name> <category>
  local name=$1 category=$2 first
  first=$(ledger "$name" | head -n 1)
  [ -n "$first" ] || fail "$name: the harness raised no permission request for the established command class, so the route was never consulted; refresh the cause evidence for this version"
  [ "$first" = "hold $category" ] || fail "$name: expected the request held as $category, the route recorded '$first'"
  ! ledger "$name" | grep -q '^refuse' || fail "$name: a request that names a reserved category was refused instead of held"
  ! results "$name" | grep -qF "$REFUSAL_MARK" || fail "$name: the route answered a request that names a reserved category"
  status_line "$name" 1 | grep -Eq "^blocked \[at=[0-9]+\] \[key=permission-prompt-hardstop\]: .* held as $category;" \
    || fail "$name: no supervisor wake for the held request, status starts with '$(status_line "$name" 1)'"
}

# The model may ask again with its command reshaped, and each distinct waiting
# request wakes the supervisor once. The close comes once and last.
assert_closed() {  # <name> <reason>
  local name=$1 reason=$2 lines asked wakes
  lines=$(grep -c . "$LAB/$name/home/state/task.status" 2>/dev/null)
  asked=$(awk -F '\t' '$2 == "hold" { print $7 }' "$LAB/$name/home/state/task.permission-route.tsv" 2>/dev/null | sort -u | grep -c .)
  wakes=$(grep -c '^blocked \[at=[0-9]*\] \[key=permission-prompt-hardstop\]: ' "$LAB/$name/home/state/task.status" 2>/dev/null)
  [ "$asked" -ge 1 ] || fail "$name: the route recorded no held request, so the close proves nothing"
  [ "$wakes" = "$asked" ] || fail "$name: expected one wake for each of the $asked held requests, the status record holds $wakes"
  [ "$lines" = $((wakes + 1)) ] || fail "$name: expected $wakes wake(s) and one close, the status record holds $lines lines"
  status_line "$name" "$lines" | grep -Eq "^resolved \[at=[0-9]+\] \[key=permission-prompt-hardstop\]: .*$reason\$" \
    || fail "$name: the hold did not close because $reason, status ends with '$(status_line "$name" "$lines")'"
  [ ! -e "$LAB/$name/home/state/task.permission-held" ] || fail "$name: the held set outlived the close"
}

PIDS=
start_case refuse unattended "echo \$N"
for entry in $RESERVED; do
  start_case "reserved-${entry%%:*}" unattended "echo \$N ${entry#*:}"
done
start_case answered unattended "echo \$N login" answered
start_case answered-failing unattended "echo \$N login; false" answered
start_case attended attended "echo \$N"

(
  sleep "$LIMIT"
  # shellcheck disable=SC2086 # the pid list is split on purpose
  kill $PIDS 2>/dev/null
) &
TIMER=$!
for pid in $PIDS; do
  wait "$pid" 2>/dev/null || true
done
kill "$TIMER" 2>/dev/null
wait "$TIMER" 2>/dev/null || true

for dir in "$LAB"/*/; do
  name=$(basename "$dir")
  grep -q '"type":"result"' "$dir/stream.jsonl" 2>/dev/null \
    || fail "$name: the session did not finish within ${LIMIT}s: $(tail -n 5 "$dir/stderr.txt" 2>/dev/null)"
done

# Refusal: the route's answer reaches the model, and the corrected command runs.
first=$(ledger refuse | head -n 1)
[ -n "$first" ] || fail "refuse: the harness raised no permission request for the established command class, so the route was never consulted; refresh the cause evidence for this version"
[ "$first" = 'refuse class' ] || fail "refuse: expected the established class refused, the route recorded '$first'"
results refuse | head -n 1 | grep -q "^true.*$REFUSAL_MARK" \
  || fail "refuse: the refusal message did not reach the model: $(results refuse | head -n 1)"
results refuse | sed 1d | grep -q '^false.*/nonexistent/n' \
  || fail "refuse: the model did not run a corrected command after the refusal: $(results refuse | tr '\n' '|')"
[ ! -s "$LAB/refuse/home/state/task.status" ] \
  || fail "refuse: a refusal the model corrected still woke the supervisor: $(cat "$LAB/refuse/home/state/task.status")"

# Each reserved category: held, never answered, and closed by the session end.
for entry in $RESERVED; do
  category=${entry%%:*}
  assert_held "reserved-$category" "$category"
  results "reserved-$category" | head -n 1 | grep -q '^true' \
    || fail "reserved-$category: the held request ran: $(results "reserved-$category" | head -n 1)"
  assert_closed "reserved-$category" 'the session ended'
done

# A held request that is answered elsewhere and finishes closes the hold.
assert_held answered sign-in
results answered | grep -q '^false.*/nonexistent/n login' \
  || fail "answered: the answered request did not run: $(results answered | tr '\n' '|')"
assert_closed answered 'the held request was answered and finished'
assert_held answered-failing sign-in
results answered-failing | grep -q '^true.*/nonexistent/n login' \
  || fail "answered-failing: the answered request did not run and fail: $(results answered-failing | tr '\n' '|')"
assert_closed answered-failing 'the held request was answered and finished'

# No unattended policy: the route records nothing and answers nothing.
[ ! -e "$LAB/attended/home/state/task.permission-route.tsv" ] && [ ! -e "$LAB/attended/home/state/task.status" ] \
  || fail "attended: the route acted on a session without the unattended policy"
! results attended | grep -qF "$REFUSAL_MARK" || fail "attended: the route answered a session without the unattended policy"
results attended | head -n 1 | grep -q '^true' \
  || fail "attended: the harness did not refuse the established command class by itself: $(results attended | head -n 1)"

keep_evidence
printf 'ok - %s live E2E refused the established prompt class with a correction the model applied, held each reserved category for a person, closed answered holds, and left an attended session alone\n' "$CLAUDE_VERSION"
