#!/usr/bin/env bash
# tests/fm-failover.test.sh - provider failover (bin/fm-failover.sh): the
# order file, the refusal detector, the Claude StopFailure record, a worker
# and a captain moved off a 429 or billing refusal with no lost work, the
# bounds and skips, the preflight night plan, and the watcher moving an idle
# ship within one poll. The runtimes, quota-axi, fm-control, the handoff
# launcher, and the ledger are stand-ins; every decision and record is the
# real script's.
set -u
# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-failover)
trap 'fm_test_cleanup' EXIT
FO="$ROOT/bin/fm-failover.sh"
LAB="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
DELEGATES="$TMP_ROOT/delegates"
QUOTA="$TMP_ROOT/quota"
ACCTS="$TMP_ROOT/accounts"
mkdir -p "$FAKEBIN" "$DELEGATES" "$QUOTA" "$TMP_ROOT/user" "$ACCTS"

# A runtime stand-in answers a one-line call with OK, or with the refusal
# row its probe-reply file holds. `claude auth status` passes when the
# account root holds a signed-in marker.
for h in codex droid claude; do
  cat > "$FAKEBIN/$h" <<'SH'
#!/usr/bin/env bash
name=$(basename "$0")
if [ "$name" = claude ] && [ "${1:-}" = auth ]; then
  [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -e "$CLAUDE_CONFIG_DIR/signed-in" ]
  exit
fi
reply="$FM_TEST_QUOTA/$name.probe"
[ "$name" != claude ] || reply="${CLAUDE_CONFIG_DIR:-/nonexistent}/probe"
if [ -f "$reply" ]; then cat "$reply"; exit 1; fi
echo OK
SH
done
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
provider='' profile=0
while [ $# -gt 0 ]; do
  case "$1" in --provider) provider=$2; shift 2 ;; --profile-only) profile=1; shift ;; *) shift ;; esac
done
if [ "$profile" = 1 ]; then cat "$CLAUDE_CONFIG_DIR/quota.json" 2>/dev/null || exit 1; exit 0; fi
cat "$FM_TEST_QUOTA/$provider.json" 2>/dev/null || exit 1
SH
cat > "$DELEGATES/fm-control.sh" <<'SH'
#!/usr/bin/env bash
n=$(( $(cat "$FM_HOME/control.n" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FM_HOME/control.n"
printf '%s\n' "$@" > "$FM_HOME/control.argv.$n"
printf '%s\n' "${FM_CONTROL_EXPECTED_SPAWN_GEN-unset}" > "$FM_HOME/control.gen.$n"
if [ -n "${FM_TEST_CONTROL_PUBLISH_GEN:-}" ]; then
  sed -e "s/^spawn_gen=.*/spawn_gen=$FM_TEST_CONTROL_PUBLISH_GEN/" \
    -e "s/^harness=.*/harness=${FM_TEST_CONTROL_PUBLISH_HARNESS:-codex}/" \
    "$FM_HOME/state/$1.meta" > "$FM_HOME/state/$1.meta.next"
  mv "$FM_HOME/state/$1.meta.next" "$FM_HOME/state/$1.meta"
fi
rc=$(printf '%s' "${FM_TEST_CONTROL_RCS:-0}" | cut -d, -f"$n")
[ "${rc:-0}" = 0 ] || { echo "error: ${FM_TEST_CONTROL_MSG:-relaunch refused for the test}" >&2; exit "$rc"; }
echo "relaunched $1"
SH
cat > "$DELEGATES/fm-handoff-launch.sh" <<'SH'
#!/usr/bin/env bash
n=$(( $(cat "$FM_HOME/handoff.n" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FM_HOME/handoff.n"
printf '%s\n' "$@" > "$FM_HOME/handoff.argv.$n"
exit "${FM_TEST_HANDOFF_RC:-0}"
SH
cat > "$DELEGATES/fm-ledger.sh" <<'SH'
#!/usr/bin/env bash
doc='' note=''
while [ $# -gt 0 ]; do
  case "$1" in --doc) doc=$2; shift 2 ;; --note) note=$2; shift 2 ;; *) shift ;; esac
done
mkdir -p "$(dirname "$doc")"
printf '# handoff\n%s\n' "$note" > "$doc"
SH
cat > "$DELEGATES/fm-on.sh" <<'SH'
#!/usr/bin/env bash
printf '%s %s %s\n' "$1" "$2" "$3" >> "$FM_HOME/remote.calls"
echo 'entry=1 runtime=codex'
SH
chmod +x "$FAKEBIN"/* "$DELEGATES"/*

export FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config" FM_DATA_OVERRIDE="$LAB/data"
export FM_FAILOVER_TEST_BIN="$DELEGATES" FM_TEST_QUOTA="$QUOTA" HOME="$TMP_ROOT/user"
export PATH="$FAKEBIN:$PATH"
unset FM_BACKEND QUOTA_AXI_SNAPSHOT CLAUDE_CONFIG_DIR FM_CONTROL_BIN FM_TEST_CONTROL_RCS FM_TEST_CONTROL_MSG
unset FM_TEST_HANDOFF_RC FM_FAILOVER_TEST_HARNESS FM_FAILOVER_TEST_LOCK_OWNER

# quota_fixture <provider> <five-hour-left> <weekly-left> [runway]: one
# snapshot both readers accept, the verdict reader and the preflight's
# five-hour and weekly window reader.
quota_fixture() {
  jq -n --arg p "$1" --argjson fh "$2" --argjson wk "$3" --arg r "${4:-through_reset}" '
    {schemaVersion: 5, providers: [{provider: $p,
      windows: [{id: "five_hour", kind: "session", percentRemaining: $fh},
                {id: "seven_day", kind: "weekly", percentRemaining: $wk}],
      quotaSemantics: {status: "known", effectiveAvailability: [{scope: "all_models", status: "known",
        effectivePercentRemaining: ([$fh, $wk] | min), runway: {status: $r}}]}}]}'
}

reset_lab() {
  rm -rf "$LAB"
  mkdir -p "$LAB/state" "$LAB/config" "$LAB/data"
  printf 'tmux\n' > "$LAB/config/backend"
  rm -f "$QUOTA"/*
  quota_fixture codex 80 60 > "$QUOTA/codex.json"
}

OUT='' RC=0
fo() {  # <args...>: run the entry point, keeping its output and exit code
  RC=0
  OUT=$(bash "$FO" "$@" 2>&1) || RC=$?
}

control_calls() { cat "$LAB/control.n" 2>/dev/null || echo 0; }
control_arg() {  # <call> <index from 0>
  awk -v i="$2" 'NR == i + 1' "$LAB/control.argv.$1"
}

# make_worker <id> <harness> [account]: a ship with a real branch, a commit,
# and uncommitted work in its local copy.
make_worker() {
  local id=$1 wt="$TMP_ROOT/wt-$1"
  rm -rf "$wt" "$wt.repo" "$wt.repo.origin.git"
  fm_git_worktree "$wt.repo" "$wt" "fm/$id" >/dev/null 2>&1 || fail "fixture: no worktree for $id"
  printf 'half-done edit\n' > "$wt/work-in-progress.txt"
  fm_write_meta "$LAB/state/$id.meta" "window=fm:fm-$id" kind=ship "harness=$2" "worktree=$wt" \
    backend=tmux "spawn_gen=s1.$id" "branch=fm/$id" ${3:+"account=$3"}
  printf 'working: wiring the parser [at=1]\n' > "$LAB/state/$id.status"
}

payload() {  # <error> [last-assistant-message] [extra-json]
  local extra='{}'
  [ -z "${3:-}" ] || extra=$3
  jq -cn --arg e "$1" --arg m "${2:-}" --argjson x "$extra" \
    '{session_id: "s", transcript_path: "/tmp/s.jsonl", cwd: "/tmp", hook_event_name: "StopFailure", error: $e, last_assistant_message: $m} + $x'
}

GEN=''
# stop_failure_turn <id> <payload>: one busy turn ending on StopFailure, with
# both Claude hooks fm-spawn installs: the busy writer and the failover record.
stop_failure_turn() {
  GEN=$(bash "$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" "$1") || fail "fixture: arm failed"
  bash "$ROOT/bin/fm-busy-event.sh" apply "$LAB/state" "$1" busy --gen "$GEN" --source claude-hook --event user-prompt-submit >/dev/null
  bash "$ROOT/bin/fm-busy-event.sh" apply "$LAB/state" "$1" idle --gen "$GEN" --source claude-hook --event stop-failure >/dev/null
  printf '%s' "$2" | bash "$FO" hook "$1" --gen "$GEN" --state "$LAB/state" || fail "the hook must always exit 0"
}

lab_dispatch() {  # <goal> <task>: the goal that dispatched <task>
  bash "$ROOT/bin/fm-dispatch-log.sh" received "$1" --summary 'parser work' >/dev/null
  bash "$ROOT/bin/fm-dispatch-log.sh" dispatched "$1" --task "$2" >/dev/null
}

no_lost_work() {  # <id> <label>
  local wt="$TMP_ROOT/wt-$1"
  [ "$(cat "$wt/work-in-progress.txt" 2>/dev/null)" = 'half-done edit' ] || fail "$2: the uncommitted work changed"
  [ "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" = "fm/$1" ] || fail "$2: the branch changed"
  [ "$(git -C "$wt" log --oneline | wc -l | tr -d ' ')" = 1 ] || fail "$2: the commits changed"
}

test_order_file() {
  reset_lab
  fo order
  expect_code 0 "$RC" "the default order"
  assert_contains "$OUT" $'entry=1 runtime=codex host=hetzner\nentry=2 runtime=codex\nentry=3 runtime=droid\nentry=4 runtime=claude@next\nmin_5h=30 source=default' \
    'without config/failover-order the host precedes codex, droid, and another Claude account'
  printf '# night order\ncodex host=hz1\n\n  codex:gpt-5.5  \nclaude:opus@ordinary\nclaude@%s/acct\nmin-5h 45\n' "$ACCTS" > "$LAB/config/failover-order"
  fo order
  expect_code 0 "$RC" "a configured order"
  assert_contains "$OUT" $'entry=1 runtime=codex host=hz1\nentry=2 runtime=codex:gpt-5.5\nentry=3 runtime=claude:opus@ordinary\nentry=4 runtime=claude@acct\nmin_5h=45' \
    'every entry form parses in file order, comments and blanks ignored'
  local bad
  for bad in 'codex extra' 'codex host=bad/host' 'codex@next' 'claude@relative' 'Codex' 'codex:-x' 'min-5h' 'min-5h 101' 'min-5h 30 40' 'codex host=a b' 'off'; do
    printf '%s\n' "$bad" > "$LAB/config/failover-order"
    fo order
    expect_code 2 "$RC" "a malformed line '$bad'"
    assert_contains "$OUT" 'error: config/failover-order line 1' "the refusal of '$bad' names its line"
  done
  mkdir -p "$ACCTS/x/same" "$ACCTS/y/same"
  printf 'claude@%s/x/same\nclaude@%s/y/same\n' "$ACCTS" "$ACCTS" > "$LAB/config/failover-order"
  fo worker nobody
  expect_code 2 "$RC" "two Claude accounts sharing a label"
  assert_contains "$OUT" 'share the label claude@same' 'the refusal names the shared label'
  pass 'order: the default, every entry form, min-5h, and each malformed line'
}

test_refusal_detector() {
  local row want got
  # shellcheck source=bin/fm-watchdog-lib.sh
  . "$ROOT/bin/fm-watchdog-lib.sh"
  while IFS='|' read -r want row; do
    got=$(fm_wd_provider_error_class "$row") || got=none
    [ "$got" = "$want" ] || fail "row '$row' classed $got, expected $want"
  done <<'ROWS'
rate_limit|⏺ API Error: Request rejected (429) · This request would exceed your account's rate limit.
rate_limit|■ stream error: unexpected status 429 Too Many Requests: rate_limit_exceeded
rate_limit|API Error: 429 {"type":"error","error":{"type":"rate_limit_error"}}
rate_limit|API Error: Rate limit reached for requests
rate_limit|API Error: status=429
rate_limit|⏺ API Error: code=429 Too Many Requests
rate_limit|API Error: HTTP_STATUS_429
rate_limit|■ stream error: unexpected status:429
rate_limit|Error: rate limit exceeded, retry later
rate_limit|  ⎿  Error: rate_limit_exceeded
billing|⏺ Credit balance is too low
billing|  ⎿  Credit balance too low · Add funds: https://platform.claude.com/settings/billing
billing|API Error: 402 {"error":{"message":"Your payment is past due"}}
billing|Claude Code can't use your Claude subscription right now
billing|Claude Code can't use your Claude subscription, usually because a payment is past due · Pay or renew at https://claude.ai/settings/billing
billing|You're out of extra usage · resets 5pm
billing|■ error: insufficient_quota - You exceeded your current quota
usage_limit|You've hit your limit · resets 3pm (Europe/Madrid)
usage_limit|⎿ Usage limit reached ∙ resets 9pm
usage_limit|Claude usage limit reached. Your limit will reset at 5pm
usage_limit|■ You've hit your usage limit. Upgrade to Pro or try again in 2 hours.
none|API Error: 529 overloaded
none|I fixed the rate limit handling and the 429 path in the API error code
none|12 + API Error: Request rejected (429)
none|- Credit balance is too low
none|The credit balance too low path now returns 402
none|+ API Error: Request rejected (429)
none|  ⎿  Error: File content (34291 tokens) exceeds maximum allowed tokens (25000)
none|Error: build failed after 14290ms
none|    error: unexpected status 4290 from mock
none|• API Error: 500 {"type":"error"} at line 429
none|     Error: Request failed with status code 429
none|⏺ Error: rate limit test fixture now returns 429 as expected
none|Error: too many requests to npm registry
none|API Error: HTTP_STATUS_4290
none|API Error: code=14290
none|Error: request failed, status=429 from the mock server
none|Error: rate limit fixture exceeded its budget
none|Error: billing tests failed after the past due fixture changed
none|Usage limit reached for the GitHub API in my test, retrying later
none|You have hit your limit on PRs today, so I stopped
none|Credit balance too low responses now map to billing
none|  ⎿  API Error (429 {"type":"error"}) · Retrying in 5 seconds… (attempt 2/10)
none|API Error: Request rejected (14290)
ROWS
  got=$(fm_wd_provider_error_screen "$(printf 'API Error: Request rejected (429)\n'; for row in 1 2 3 4 5 6 7 8 9 10 11 12; do printf 'later output %s\n' "$row"; done)") || got=none
  [ "$got" = none ] || fail "a refusal above the last 12 rows must not count, got $got"
  got=$(fm_wd_provider_error_screen "$(printf 'older\n\n⏺ Credit balance is too low\n\n❯ \n')") || got=none
  [ "$got" = billing ] || fail "an idle screen ending on a billing refusal must class billing, got $got"
  pass 'detector: 429, rate-limit, usage-limit, billing, past-due, subscription, and quota rows class; prose, tool errors, digit substrings, retry rows, diff rows, and old rows do not'
}

test_stop_failure_record() {
  reset_lab
  make_worker w1 claude
  stop_failure_turn w1 "$(payload rate_limit 'API Error: Request rejected (429)')"
  fo detect w1
  expect_code 0 "$RC" "a recorded 429"
  assert_contains "$OUT" 'class=rate_limit source=record' 'the StopFailure 429 is recorded for this turn end'
  stop_failure_turn w1 "$(payload rate_limit "You've hit your limit · resets 3pm")"
  fo detect w1
  assert_contains "$OUT" 'class=usage_limit source=record' 'a rate_limit payload stating a usage limit records usage_limit'
  stop_failure_turn w1 "$(payload billing_error 'Credit balance is too low')"
  fo detect w1
  assert_contains "$OUT" 'class=billing source=record' 'a billing_error payload records billing'
  bash "$ROOT/bin/fm-busy-event.sh" apply "$LAB/state" w1 busy --gen "$GEN" --source claude-hook --event user-prompt-submit >/dev/null
  fo detect w1
  expect_code 1 "$RC" "a record after the worker started a new turn"
  bash "$ROOT/bin/fm-busy-event.sh" apply "$LAB/state" w1 idle --gen "$GEN" --source claude-hook --event stop-failure >/dev/null
  bash "$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" w1 >/dev/null
  fo detect w1
  expect_code 1 "$RC" "a record from a replaced incarnation"
  rm -f "$LAB/state/w1.provider-error"
  local p
  for p in "$(payload server_error 'API Error: 500')" "$(payload authentication_failed)" \
    "$(payload rate_limit '' '{"cursor_version":"1.0"}')" "$(payload rate_limit '' '{"transcript_path":"/h/.pi/x.jsonl"}')" 'not json'; do
    stop_failure_turn w1 "$p"
    [ ! -e "$LAB/state/w1.provider-error" ] || fail "payload '$p' must record nothing"
  done
  printf 'API Error: Request rejected (429)\n❯ \n' > "$TMP_ROOT/screen.txt"
  fo detect w1 --screen-file "$TMP_ROOT/screen.txt"
  assert_contains "$OUT" 'class=rate_limit source=pane' 'with no record the idle screen still classes the refusal'
  printf '%s' "$(payload rate_limit)" | bash "$FO" hook captain
  [ ! -e "$LAB/state/captain.provider-error" ] || fail 'the captain hook outside a primary checkout must record nothing'
  pass 'record: the StopFailure hook records 429, usage-limit, and billing for the current turn end only, and nothing else'
}

test_worker_429_moves_to_the_next_runtime() {
  reset_lab
  make_worker w1 claude
  lab_dispatch g-parser w1
  stop_failure_turn w1 "$(payload rate_limit 'API Error: Request rejected (429)')"
  fo worker w1
  expect_code 0 "$RC" "worker failover after a 429: $OUT"
  assert_contains "$OUT" 'candidate runtime=codex eligible verdict=ok' 'codex is measured and eligible'
  assert_contains "$(cat "$LAB/state/dispatch-log.tsv")" 'reason=host route not configured' 'an absent host route is recorded before local failover'
  assert_contains "$OUT" 'switched task=w1 from=claude to=codex reason=rate_limit' 'the switch names both runtimes and the reason'
  expect_code 1 "$(control_calls)" "one relaunch"
  assert_equals "w1 relaunch --harness codex --provider-failover --note" "$(control_arg 1 0) $(control_arg 1 1) $(control_arg 1 2) $(control_arg 1 3) $(control_arg 1 4) $(control_arg 1 5)" 'the relaunch goes through fm-control in place'
  assert_equals s1.w1 "$(cat "$LAB/control.gen.1")" 'the relaunch is bound to the refused incarnation'
  local note
  note=$(sed -n '6,$p' "$LAB/control.argv.1")
  assert_contains "$note" 'rate_limit refusal' 'the note names the refusal'
  assert_contains "$note" 'its branch fm/w1' 'the note carries the branch'
  assert_contains "$note" 'working: wiring the parser' 'the note carries the task status'
  assert_contains "$note" 'no-mistakes axi status' 'the note carries the gates'
  assert_contains "$(cat "$LAB/state/dispatch-log.tsv")" $'\tfailover\tg-parser\ttask=w1 from=claude to=codex reason=rate_limit' \
    'the dispatch log records the switch under the goal that dispatched the task'
  assert_contains "$(bash "$ROOT/bin/fm-dispatch-log.sh" show g-parser)" 'STATE g-parser event=dispatched' 'the switch does not change the goal state'
  [ ! -e "$LAB/state/w1.provider-error" ] || fail 'the record must be cleared after the switch'
  assert_contains "$(cat "$LAB/state/.failover-w1")" $'attempt\tclaude\tcodex\trate_limit' 'the attempt is in the ledger'
  no_lost_work w1 'a 429 failover'
  reset_lab
  make_worker w1 claude
  : > "$LAB/data/secondmates.md"
  FM_FAILOVER_TEST_ON_BIN="$DELEGATES/fm-on.sh" fo worker w1 --reason rate_limit
  expect_code 0 "$RC" "a configured remote route is probed before local failover: $OUT"
  assert_contains "$(cat "$LAB/remote.calls")" 'hetzner fm-failover.sh order' 'the configured host was contacted through the remote transport'
  assert_contains "$(cat "$LAB/state/dispatch-log.tsv")" 'reason=host worktree not configured' 'an available route without the task worktree is recorded'
  pass 'worker 429: relaunched on codex in the same local copy, branch, and gates, recorded, nothing lost'
}

test_worker_billing_moves_past_its_own_runtime() {
  reset_lab
  make_worker w2 codex
  printf '■ error: insufficient_quota - You exceeded your current quota\n› \n' > "$TMP_ROOT/screen.txt"
  fo detect w2 --screen-file "$TMP_ROOT/screen.txt"
  assert_contains "$OUT" 'class=billing source=pane' 'the codex billing screen classes billing'
  fo worker w2 --reason billing
  expect_code 0 "$RC" "worker failover after a billing error: $OUT"
  assert_not_contains "$OUT" 'candidate runtime=codex eligible' 'the refused runtime is never the target'
  assert_contains "$OUT" 'switched task=w2 from=codex to=droid reason=billing' 'billing moves the worker to droid'
  assert_equals droid "$(control_arg 1 3)" 'fm-control relaunches on droid'
  assert_contains "$(cat "$LAB/state/dispatch-log.tsv")" $'\tfailover\tw2\ttask=w2 from=codex to=droid reason=billing' \
    'an undispatched task is logged under its own id'
  no_lost_work w2 'a billing failover'
  pass 'worker billing: relaunched on the next runtime after its own, recorded, nothing lost'
}

test_worker_walks_the_order() {
  reset_lab
  make_worker w3 claude
  FM_TEST_CONTROL_RCS=1,0 fo worker w3
  expect_code 0 "$RC" "a failed first relaunch: $OUT"
  assert_contains "$OUT" 'failed task=w3 to=codex rc=1' 'the failed relaunch is reported'
  assert_contains "$OUT" 'switched task=w3 from=claude to=droid' 'the next runtime takes over'
  reset_lab
  mkdir -p "$ACCTS/after-droid"
  touch "$ACCTS/after-droid/signed-in"
  quota_fixture claude 70 70 > "$ACCTS/after-droid/quota.json"
  printf '%s\n' "$ACCTS/after-droid" > "$LAB/config/claude-accounts"
  make_worker w3 droid
  fo worker w3 --reason rate_limit
  expect_code 0 "$RC" "a refused droid proceeds to the next Claude account: $OUT"
  assert_contains "$OUT" 'switched task=w3 from=droid to=claude@after-droid' 'a later failure never returns to codex'
  assert_not_contains "$OUT" 'candidate runtime=codex eligible' 'codex is before the refused runtime'
  reset_lab
  make_worker w3 claude
  printf '%s\tattempt\tcodex\tdroid\trate_limit\n' "$(date +%s)" > "$LAB/state/.failover-w3"
  fo worker w3 --reason rate_limit
  expect_code 0 "$RC" "a prior refusal is not retried after the order changes: $OUT"
  assert_contains "$OUT" 'candidate runtime=codex skip=refused_in_window' 'a runtime already refused in the window stays excluded'
  reset_lab
  make_worker w3 claude
  FM_TEST_CONTROL_RCS=1,0 FM_TEST_CONTROL_PUBLISH_GEN=s2.w3 fo worker w3
  expect_code 0 "$RC" "a published replacement after a nonzero confirmation: $OUT"
  assert_contains "$OUT" 'switched task=w3 from=claude to=codex' 'the published replacement counts as the switch'
  expect_code 1 "$(control_calls)" 'a published replacement prevents another relaunch'
  assert_contains "$(cat "$LAB/state/dispatch-log.tsv")" 'task=w3 from=claude to=codex reason=rate_limit' 'the published replacement is logged'
  reset_lab
  make_worker w3 claude
  FM_TEST_CONTROL_RCS=7,0 fo worker w3
  expect_code 1 "$RC" "a pre-stop refusal"
  expect_code 1 "$(control_calls)" "relaunches after a pre-stop refusal"
  reset_lab
  make_worker w3 claude
  FM_TEST_CONTROL_RCS=1,0 FM_TEST_CONTROL_MSG='task w3 is at a usage-limit screen that is not live-verified' fo worker w3
  expect_code 1 "$RC" "an unverified usage-limit picker"
  expect_code 1 "$(control_calls)" "relaunches at an unverified usage-limit picker"
  assert_contains "$OUT" 'none task=w3 from=claude reason=rate_limit why=every_relaunch_failed' 'no runtime took over'
  reset_lab
  make_worker w3 claude
  FM_FAILOVER_DEADLINE=$(( $(date +%s) + 10 )) fo worker w3
  expect_code 1 "$RC" "a walk with less than the minimum relaunch time left"
  assert_contains "$OUT" 'none task=w3 from=claude reason=rate_limit why=deadline_before_codex' 'the walk stops before a relaunch it cannot finish'
  expect_code 0 "$(control_calls)" "relaunches started past the deadline"
  reset_lab
  make_worker w3 claude
  FM_FAILOVER_DEADLINE=$(( $(date +%s) + 200 )) fo worker w3
  expect_code 0 "$RC" "a walk with time left: $OUT"
  assert_contains "$OUT" 'switched task=w3 from=claude to=codex' 'a relaunch inside the deadline runs'
  pass 'walk: a failed relaunch moves on, a pre-stop refusal, an unverified usage-limit picker, or the deadline stops'
}

test_worker_candidates_and_skips() {
  reset_lab
  local a
  for a in A B C; do mkdir -p "$ACCTS/$a"; quota_fixture claude 70 70 > "$ACCTS/$a/quota.json"; done
  touch "$ACCTS/A/signed-in" "$ACCTS/B/signed-in"
  printf '%s\n' "$ACCTS/A" "$ACCTS/C" "$ACCTS/B" > "$LAB/config/claude-accounts"
  make_worker w4 claude "$ACCTS/A"
  quota_fixture codex 0 0 exhausted_now > "$QUOTA/codex.json"
  printf '%s\tdroid\texcluded\tfail:rate_limit\tunknown\tunknown\tcall_rate_limit\n' "$(date +%s)" > "$LAB/state/failover-preflight.tsv"
  fo worker w4
  expect_code 0 "$RC" "claude account failover: $OUT"
  assert_not_contains "$OUT" 'candidate runtime=codex eligible' 'the walk does not return to codex before the refused Claude account'
  assert_not_contains "$OUT" 'candidate runtime=droid eligible' 'the walk does not return to droid before the refused Claude account'
  assert_contains "$OUT" 'candidate runtime=claude@C skip=not_signed_in' 'a signed-out account is skipped, never signed in'
  assert_not_contains "$OUT" 'runtime=claude@A' 'the refused account is never a candidate'
  assert_contains "$OUT" 'switched task=w4 from=claude@A to=claude@B' 'another signed-in account takes over'
  assert_equals "--account $ACCTS/B" "$(control_arg 1 4) $(control_arg 1 5)" 'the account goes to fm-control'

  rm -f "$LAB/control.n"
  make_worker w4u claude
  CLAUDE_CONFIG_DIR="$ACCTS/A" fo worker w4u
  expect_code 0 "$RC" "an unpinned claude worker: $OUT"
  assert_not_contains "$OUT" 'runtime=claude@A ' 'the inherited account that refused an unpinned worker is never a candidate'
  assert_contains "$OUT" 'switched task=w4u from=claude to=claude@B' 'an unpinned worker moves off the inherited account'

  reset_lab
  make_worker w5 claude
  printf 'done: PR https://example.test/pr/1\n' >> "$LAB/state/w5.status"
  rm -f "$LAB/config/failover-order"
  fo worker w5
  expect_code 6 "$RC" "a finished task"
  make_worker w5 claude
  touch "$LAB/state/.crew-stopped-w5"
  fo worker w5
  expect_code 6 "$RC" "a task stopped on purpose"
  make_worker w6 claude
  printf 'remote_host=hz1\n' >> "$LAB/state/w6.meta"
  fo worker w6
  expect_code 6 "$RC" "a remote task"
  fm_write_secondmate_meta "$LAB/state/mate.meta" "$LAB"
  fo worker mate
  expect_code 6 "$RC" "a secondmate"
  expect_code 0 "$(control_calls)" "relaunches for skipped targets"
  make_worker w7 claude
  now=$(date +%s)
  printf '%s\tattempt\tclaude\tcodex\trate_limit\n' "$now" "$now" "$now" > "$LAB/state/.failover-w7"
  fo worker w7
  expect_code 3 "$RC" "the attempt bound"
  bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2" && touch "$3"; sleep 30' _ "$ROOT" "$LAB/state/.failover-w6x.lock" "$TMP_ROOT/held" &
  local holder=$!
  make_worker w6x claude
  local i=0
  while [ ! -e "$TMP_ROOT/held" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$TMP_ROOT/held" ] || fail 'fixture: the lock holder never took the lock'
  fo worker w6x
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  expect_code 5 "$RC" "a failover already holding the lock"
  expect_code 0 "$(control_calls)" "relaunches under a bound or a held lock"
  pass 'candidates and skips: quota, night plan, sign-in, accounts, finished, stopped, remote, secondmate, bound, lock'
}

captain_world() {
  reset_lab
  fm_write_meta "$LAB/state/live.meta" window=fm:fm-live kind=ship harness=codex
  export FM_FAILOVER_TEST_LOCK_OWNER=1 FM_FAILOVER_TEST_HARNESS=claude
}

test_captain_429_and_billing_start_a_successor() {
  captain_world
  bash "$FO" record captain --class rate_limit --source claude-hook >/dev/null
  lab_dispatch g-night captain
  fo captain
  expect_code 0 "$RC" "captain failover after a 429: $OUT"
  assert_contains "$OUT" 'candidate runtime=droid skip=refused' 'droid is not a primary runtime'
  assert_contains "$OUT" 'switched task=captain from=claude@ordinary to=codex reason=rate_limit' 'a codex successor takes over'
  local doc
  doc=$(sed -n 's/^handoff doc=//p' <<< "$OUT")
  [ -f "$doc" ] || fail "the handoff document was not written: $OUT"
  assert_contains "$(cat "$doc")" 'rate_limit refusal' 'the handoff says why the successor started'
  assert_equals "--harness codex --reason failover_rate_limit $doc" "$(tr '\n' ' ' < "$LAB/handoff.argv.1" | sed 's/ $//')" \
    'the successor starts through the verified handoff launcher with the handoff'
  assert_contains "$(cat "$LAB/state/dispatch-log.tsv")" 'task=captain from=claude@ordinary to=codex reason=rate_limit' 'the dispatch log records the captain switch'
  [ ! -e "$LAB/state/captain.provider-error" ] || fail 'the captain record must be cleared after the switch'

  captain_world
  fo captain --reason billing
  expect_code 0 "$RC" "captain failover after a billing error: $OUT"
  assert_contains "$OUT" 'switched task=captain from=claude@ordinary to=codex reason=billing' 'billing starts a successor too'
  assert_contains "$(cat "$LAB/state/supervisor-failover.log")" 'event=provider_failover_result scope=primary from=claude@ordinary to=codex result=replaced' \
    'the supervisor failover log records the replacement'

  captain_world
  mkdir -p "$ACCTS/after-droid"
  touch "$ACCTS/after-droid/signed-in"
  quota_fixture claude 70 70 > "$ACCTS/after-droid/quota.json"
  printf '%s\n' "$ACCTS/after-droid" > "$LAB/config/claude-accounts"
  FM_FAILOVER_TEST_HARNESS=droid fo captain --reason billing
  expect_code 0 "$RC" "a captain refused on droid proceeds forward: $OUT"
  assert_contains "$OUT" 'switched task=captain from=droid to=claude@after-droid' 'a captain failure never returns to codex'

  captain_world
  FM_TEST_HANDOFF_RC=4 fo captain --reason billing
  expect_code 1 "$RC" "a handoff missing an open captain order"
  expect_code 1 "$(cat "$LAB/handoff.n")" "successor attempts after a missing order"
  captain_world
  rm "$LAB/state/live.meta"
  fo captain
  expect_code 6 "$RC" "a captain with no open work"
  captain_world
  unset FM_FAILOVER_TEST_LOCK_OWNER
  fo captain
  expect_code 6 "$RC" "a session that does not hold the lock"
  [ ! -e "$LAB/handoff.n" ] || fail 'no successor may start without work or the lock'
  unset FM_FAILOVER_TEST_HARNESS
  pass 'captain 429 and billing: a handoff and a verified successor on the next runtime, recorded; refused without the lock, work, or every order'
}

# hook_primary: a plain checkout that passes the primary-home check, so the
# captain StopFailure hook acts on it.
hook_primary() {
  local p="$TMP_ROOT/primary"
  rm -rf "$p"
  mkdir -p "$p/bin"
  printf '# lab\n' > "$p/AGENTS.md"
  git -C "$p" init -q >/dev/null 2>&1 || fail 'fixture: no primary checkout'
  printf '%s\n' "$p"
}

test_captain_hook_429_and_billing_start_a_successor() {
  local primary class err doc
  primary=$(hook_primary)
  for class in rate_limit billing; do
    captain_world
    err=rate_limit; [ "$class" = rate_limit ] || err=billing_error
    lab_dispatch "g-hook-$class" captain
    printf '%s' "$(payload "$err" 'API Error')" | FM_ROOT_OVERRIDE="$primary" bash "$FO" hook captain
    expect_code 0 "$?" "the captain hook exits 0 after $err"
    assert_contains "$(cat "$LAB/state/failover-captain.log")" "switched task=captain from=claude@ordinary to=codex reason=$class" \
      "the $err hook starts a codex successor in its own process"
    doc=$(sed -n 's/^handoff doc=//p' "$LAB/state/failover-captain.log")
    [ -f "$doc" ] || fail "the $err hook wrote no handoff document"
    assert_contains "$(cat "$doc")" "$class refusal" "the handoff after $err says why the successor started"
    assert_equals "--harness codex --reason failover_$class $doc" "$(tr '\n' ' ' < "$LAB/handoff.argv.1" | sed 's/ $//')" \
      "the $err successor starts through the verified handoff launcher"
    assert_contains "$(cat "$LAB/state/dispatch-log.tsv")" "task=captain from=claude@ordinary to=codex reason=$class" \
      "the dispatch log records the $err captain switch"
    [ ! -e "$LAB/state/captain.provider-error" ] || fail "the captain record must be cleared after the $err switch"
  done

  captain_world
  printf '%s' "$(payload rate_limit)" | FM_ROOT_OVERRIDE="$TMP_ROOT/wt-none" bash "$FO" hook captain
  [ ! -e "$LAB/handoff.n" ] || fail 'a hook outside a primary checkout must not start a successor'
  [ ! -e "$LAB/state/captain.provider-error" ] || fail 'a hook outside a primary checkout must not record'
  captain_world
  unset FM_FAILOVER_TEST_LOCK_OWNER
  printf '%s' "$(payload rate_limit)" | FM_ROOT_OVERRIDE="$primary" bash "$FO" hook captain
  [ ! -e "$LAB/handoff.n" ] || fail 'a hook in a session without the lock must not start a successor'
  captain_world
  printf '%s' "$(payload server_error)" | FM_ROOT_OVERRIDE="$primary" bash "$FO" hook captain
  [ ! -e "$LAB/handoff.n" ] || fail 'a non-provider error must not start a successor'
  unset FM_FAILOVER_TEST_HARNESS FM_FAILOVER_TEST_LOCK_OWNER
  pass 'captain hook: a 429 or billing StopFailure in the primary checkout hands off to a successor in one step; elsewhere, without the lock, or for another error it does nothing'
}
test_preflight_night_plan() {
  reset_lab
  local a
  for a in A B; do mkdir -p "$ACCTS/p$a"; touch "$ACCTS/p$a/signed-in"; done
  quota_fixture claude 20 80 > "$ACCTS/pA/quota.json"
  quota_fixture claude 75 50 > "$ACCTS/pB/quota.json"
  printf '%s\n' "$ACCTS/pA" "$ACCTS/pB" > "$LAB/config/claude-accounts"
  printf 'API Error: Request rejected (429)\n' > "$QUOTA/droid.probe"
  fo preflight
  expect_code 0 "$RC" "the preflight: $OUT"
  assert_contains "$OUT" 'preflight runtime=codex verdict=eligible call=ok five_hour=80 weekly=60' 'a working runtime with headroom is eligible'
  assert_contains "$OUT" 'preflight runtime=droid verdict=excluded call=fail:rate_limit' 'a runtime whose real call is refused is excluded'
  assert_contains "$OUT" 'preflight runtime=claude@pA verdict=excluded call=ok five_hour=20 weekly=80 why=five_hour_below_30' 'an account under the five-hour floor is excluded'
  assert_contains "$OUT" 'preflight runtime=claude@pB verdict=eligible call=ok five_hour=75 weekly=50' 'an account above it is eligible'
  fo plan
  assert_contains "$OUT" 'plan runtime=droid verdict=excluded why=call_rate_limit' 'the plan carries the exclusion'
  assert_contains "$OUT" 'plan runtime=claude@pB verdict=eligible' 'the plan carries the eligible account'
  quota_fixture codex 80 0 > "$QUOTA/codex.json"
  printf 'min-5h 10\n' > "$LAB/config/failover-order"
  printf 'codex\nclaude@next\nmin-5h 10\n' > "$LAB/config/failover-order"
  fo preflight
  assert_contains "$OUT" 'preflight runtime=codex verdict=excluded call=ok five_hour=80 weekly=0 why=weekly_exhausted' 'a spent weekly window excludes after a real call'
  assert_contains "$OUT" 'preflight runtime=claude@pA verdict=eligible' 'the configured floor applies'
  pass 'preflight: a real call and the 5h and weekly windows per runtime and account set the night plan'
}

# --- the watcher moves an idle refused ship within one poll ---
watch_case() {  # <name> <screen> -> case dir with a claude ship and a fake fm-control
  local dir
  dir=$(make_case "$1")
  printf '%s\n' "$2" > "$dir/pane.txt"
  mkdir -p "$dir/config" "$dir/home"
  fm_git_worktree "$dir/repo" "$dir/wt" fm/fo >/dev/null 2>&1 || fail 'fixture: no worktree'
  fm_write_meta "$dir/state/fo.meta" window=test:fm-fo kind=ship harness=claude "worktree=$dir/wt" spawn_gen=s1.fo
  printf 'working: wiring the parser\n' > "$dir/state/fo.status"
  printf '%s' "$(seen_sig "$dir/state/fo.status")" > "$dir/state/.seen-fo_status"
  cat > "$dir/fake-control" <<SH
#!/usr/bin/env bash
printf '%s %s %s %s %s %s\n' "\$1" "\$2" "\$3" "\$4" "\$5" "\$6" >> "$dir/control.calls"
printf '%s %s\n' "\${FM_FAILOVER_RELAUNCH_TIMEOUT:-}" "\$(( \${FM_FAILOVER_DEADLINE:-0} - \$(date +%s) ))" >> "$dir/control.bounds"
printf 'replacement is starting\n' > "$dir/pane.txt"
SH
  chmod +x "$dir/fake-control"
  printf '%s\n' "$dir"
}

watch_once() {  # <dir> [env assignments...]: run the watcher until it exits, at most 30 polls
  local dir=$1 pid
  shift
  FM_CONTROL_BIN="$dir/fake-control" FM_HOME="$dir/home" FM_CONFIG_OVERRIDE="$dir/config" FM_DATA_OVERRIDE="$dir/home/data" \
    watch_bg "$dir/state" "$dir/fakebin" "$dir/watch.out" env FM_FAKE_TMUX_WINDOW=test:fm-fo FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" "$@"
  pid=$!
  wait_for_exit "$pid" 300 >/dev/null 2>&1 || true
}

test_watcher_moves_an_idle_refused_ship_in_one_poll() {
  local dir key
  rm -f "$QUOTA"/*
  quota_fixture codex 80 60 > "$QUOTA/codex.json"
  dir=$(watch_case watch-429 $'⏺ API Error: Request rejected (429) · This request would exceed your account\'s rate limit.\n\n❯ Resend your message to try again\n  ⏵⏵ auto mode on')
  key=$(watch_window_key test:fm-fo)
  [ ! -e "$dir/state/.hash-$key" ] || fail 'fixture: the pane must be unseen'
  watch_once "$dir"
  assert_contains "$(cat "$dir/watch.out")" 'check: fo moved to the next runtime after a rate_limit refusal from its provider (task=fo from=claude to=codex reason=rate_limit)' \
    'the first idle poll of a 429 screen moves the ship and wakes with the switch'
  assert_equals 'fo relaunch --harness codex --provider-failover --note' "$(cat "$dir/control.calls")" 'one relaunch on codex'
  assert_contains "$(cat "$dir/state/dispatch-log.tsv")" 'task=fo from=claude to=codex reason=rate_limit' 'the watcher switch is in the dispatch log'
  assert_contains "$(awk -F '\t' '$3 == "check"' "$dir/state/.wake-queue")" 'failover-fo-' 'the check wake is queued'

  dir=$(watch_case watch-billing $'All done for now.\n\n❯ \n  ⏵⏵ auto mode on')
  local gen
  gen=$(bash "$ROOT/bin/fm-busy-event.sh" arm "$dir/state" fo)
  bash "$ROOT/bin/fm-busy-event.sh" apply "$dir/state" fo idle --gen "$gen" --source claude-hook --event stop-failure >/dev/null
  printf '%s' "$(payload billing_error 'Credit balance is too low')" | bash "$FO" hook fo --gen "$gen" --state "$dir/state"
  watch_once "$dir"
  assert_contains "$(cat "$dir/watch.out")" 'check: fo moved to the next runtime after a billing refusal' \
    'a billing record from the StopFailure hook moves the ship on its first idle poll'

  dir=$(watch_case watch-prose $'I fixed the API error path that returned 429 for rate limits.\n\n❯ \n  ⏵⏵ auto mode on')
  watch_once "$dir"
  [ ! -e "$dir/control.calls" ] || fail "prose about a 429 must not relaunch: $(cat "$dir/control.calls")"
  assert_not_contains "$(cat "$dir/watch.out")" 'moved to the next runtime' 'prose is not a refusal'

  dir=$(watch_case watch-hook-stop $'⏺ API Error: Request rejected (429) · This request would exceed your account\'s rate limit.\n\n❯ \n  ⏵⏵ auto mode on')
  gen=$(bash "$ROOT/bin/fm-busy-event.sh" arm "$dir/state" fo)
  bash "$ROOT/bin/fm-busy-event.sh" apply "$dir/state" fo idle --gen "$gen" --source claude-hook --event stop >/dev/null \
    || fail 'fixture: the ordinary Stop hook record was not applied'
  watch_once "$dir"
  [ -e "$dir/state/fo.failover-judged" ] || fail 'fixture: the watcher never judged the hook-stop screen'
  [ ! -e "$dir/control.calls" ] || fail "a Claude turn end its hook recorded as an ordinary stop must not relaunch from old screen rows: $(cat "$dir/control.calls")"
  pass 'watcher: an idle ship refused by its provider moves on its first idle poll, from the screen or the hook record; prose and a hook-recorded ordinary stop do not'
}

test_watcher_moves_an_idle_refused_captain_in_one_poll() {
  local dir class err
  for class in rate_limit billing; do
    err='⏺ API Error: Request rejected (429)'
    [ "$class" != billing ] || err='⏺ Credit balance is too low'
    dir=$(watch_case "captain-$class" "$err"$'\n\n❯ \n  ⏵⏵ auto mode on')
    rm -f "$dir/state/fo.meta"
    printf 'backend=tmux\nterminal=test:fm-fo\nworktree=%s\n' "$dir/home" > "$dir/state/.lock-session"
    FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/state" bash "$ROOT/bin/fm-dispatch-log.sh" received "g-$class" --summary 'open captain work' >/dev/null
    watch_once "$dir" FM_FAILOVER_TEST_LOCK_OWNER=1 FM_FAILOVER_TEST_HARNESS=claude
    assert_contains "$(cat "$dir/watch.out")" "check: captain moved to the next runtime after a $class refusal" \
      "the watcher hands off a $class refusal from an idle captain pane"
    assert_contains "$(cat "$dir/state/dispatch-log.tsv")" "task=captain from=claude@ordinary to=codex reason=$class" \
      "the captain switch is recorded"
    [ -s "$dir/home/data/handoffs/$(ls "$dir/home/data/handoffs" | head -n 1)" ] || fail 'the captain handoff is missing'
  done
  pass 'watcher: idle captain 429 and billing screens with open goals hand off in one poll'
}

# Every stale grace, from the floor to well past the default, and explicit
# timeouts above and below the cap: the whole call stays strictly inside the
# grace and each relaunch inside fm-failover.sh's deadline.
test_watch_bounds_stay_inside_the_stale_grace() {
  local grace t r m
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh"
  assert_equals '240 220 15' "$(fm_failover_watch_bounds 300)" 'the default grace keeps the historical bounds'
  assert_equals '240 220 15' "$(fm_failover_watch_bounds '')" 'an unset grace reads as the 300s default'
  assert_equals '240 225 15' "$(fm_failover_watch_bounds 300 900 900)" 'explicit bounds past the grace are capped'
  assert_equals '100 80 15' "$(fm_failover_watch_bounds 300 100)" 'an explicit timeout under the cap holds'
  assert_equals '100 50 15' "$(fm_failover_watch_bounds 300 100 50)" 'an explicit relaunch bound under the deadline holds'
  for grace in 2 3 10 30 59 60 61 100 119 120 121 180 300 600 3600; do
    read -r t r m <<< "$(fm_failover_watch_bounds "$grace")"
    [ "$t" -lt "$grace" ] || fail "grace $grace: the call timeout $t is not inside the grace"
    [ "$t" -ge 1 ] || fail "grace $grace: the call timeout $t is not positive"
    [ "$m" -le $((t / 4)) ] || fail "grace $grace: the deadline margin $m eats the call"
    [ "$r" -ge 1 ] && [ "$r" -le $((t - m)) ] || fail "grace $grace: the relaunch bound $r does not fit inside the deadline (t=$t m=$m)"
    read -r t r m <<< "$(fm_failover_watch_bounds "$grace" 99999 99999)"
    [ "$t" -lt "$grace" ] || fail "grace $grace: an explicit timeout $t escapes the grace"
    [ "$r" -le $((t - m)) ] || fail "grace $grace: an explicit relaunch bound $r escapes the deadline"
  done

  # A real watcher on a short grace hands fm-failover.sh a deadline and a
  # relaunch bound inside it; the floor of the earlier clamp gave 45s and 40s.
  rm -f "$QUOTA"/*
  quota_fixture codex 80 60 > "$QUOTA/codex.json"
  local dir
  dir=$(watch_case watch-grace $'⏺ API Error: Request rejected (429) · This request would exceed your account\'s rate limit.\n\n❯ \n  ⏵⏵ auto mode on')
  watch_once "$dir" FM_WATCHER_STALE_GRACE=30 FM_FAILOVER_MIN_RELAUNCH_SECS=1
  [ -s "$dir/control.bounds" ] || fail "the short-grace watcher never relaunched: $(cat "$dir/watch.out")"
  read -r r t < "$dir/control.bounds"
  [ "$r" -lt 30 ] || fail "the relaunch bound $r is not inside a 30s grace"
  [ "$t" -lt 30 ] || fail "the failover deadline is ${t}s away, not inside a 30s grace"
  pass 'watch bounds: the failover call, its deadline, and each relaunch stay inside every stale grace'
}

# `ordinary` and $HOME/.claude name one Claude account, with or without a
# trailing slash, so neither spelling hands a refused worker back to it.
test_worker_account_identity_is_its_config_root() {
  reset_lab
  local me="$HOME/.claude" spelling
  mkdir -p "$me" "$ACCTS/D"
  touch "$me/signed-in" "$ACCTS/D/signed-in"
  quota_fixture claude 70 70 > "$me/quota.json"
  quota_fixture claude 70 70 > "$ACCTS/D/quota.json"
  printf '%s\n' "$me" "$ACCTS/D" > "$LAB/config/claude-accounts"
  printf 'claude@next\n' > "$LAB/config/failover-order"
  for spelling in unset "$me" "$me/"; do
    rm -f "$LAB/control.n"
    make_worker w8 claude
    if [ "$spelling" = unset ]; then
      fo worker w8
    else
      CLAUDE_CONFIG_DIR=$spelling fo worker w8
    fi
    expect_code 0 "$RC" "the inherited account spelled $spelling: $OUT"
    assert_not_contains "$OUT" 'runtime=claude@.claude ' "the refused account spelled $spelling is never a candidate"
    assert_contains "$OUT" 'to=claude@D' "a worker refused on the account spelled $spelling moves to the other account"
  done
  make_worker w8p claude "$me/"
  rm -f "$LAB/control.n"
  fo worker w8p
  assert_not_contains "$OUT" 'runtime=claude@.claude ' 'a pinned account with a trailing slash is the same account'
  assert_contains "$OUT" 'to=claude@D' 'the pinned worker moves to the other account'
  make_worker w8c codex
  printf 'claude@next\n' > "$LAB/config/failover-order"
  rm -f "$LAB/control.n"
  fo worker w8c
  assert_contains "$OUT" 'switched task=w8c from=codex to=claude@.claude' 'a codex worker has no Claude account to exclude'
  pass 'account identity: ordinary, the home config root, and a trailing slash are one account'
}

fm_test_run \
  test_order_file \
  test_refusal_detector \
  test_stop_failure_record \
  test_worker_429_moves_to_the_next_runtime \
  test_worker_billing_moves_past_its_own_runtime \
  test_worker_walks_the_order \
  test_worker_candidates_and_skips \
  test_captain_429_and_billing_start_a_successor \
  test_captain_hook_429_and_billing_start_a_successor \
  test_preflight_night_plan \
  test_watcher_moves_an_idle_refused_ship_in_one_poll \
  test_watcher_moves_an_idle_refused_captain_in_one_poll \
  test_watch_bounds_stay_inside_the_stale_grace \
  test_worker_account_identity_is_its_config_root
