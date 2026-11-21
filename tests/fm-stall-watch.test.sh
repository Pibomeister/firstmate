#!/usr/bin/env bash
# tests/fm-stall-watch.test.sh - the built-in stall check
# (bin/fm-stall-watch.sh): redaction of the screen and of everything a
# classifier receives, the deterministic first pass, the Jev and Grok judges
# and their fallbacks, the unchanged-screen guard, the failover, nudge, and
# escalation actions, the tick schedule, and the watcher starting the tick and
# delivering its reports. The screens are recorded fixtures under
# tests/fixtures/stall-watch; grok, curl, fm-failover.sh, fm-send.sh, and the
# captain typer are stand-ins that record what they were given, while every
# decision is the real script's.
set -u
# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-stall-watch)
trap 'fm_test_cleanup' EXIT
SW="$ROOT/bin/fm-stall-watch.sh"
FIX="$ROOT/tests/fixtures/stall-watch"
LAB="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
DELEGATES="$TMP_ROOT/delegates"
LOGS="$TMP_ROOT/logs"
mkdir -p "$FAKEBIN" "$DELEGATES" "$LOGS" "$TMP_ROOT/user"

# grok stand-in: keeps the prompt file it was given and answers with the
# reply file, or fails with FM_TEST_GROK_RC.
cat > "$FAKEBIN/grok" <<'SH'
#!/usr/bin/env bash
n=$(( $(cat "$FM_TEST_LOGS/grok.n" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FM_TEST_LOGS/grok.n"
printf '%s\n' "$@" > "$FM_TEST_LOGS/grok.argv.$n"
prev=''
for a in "$@"; do
  [ "$prev" != --prompt-file ] || cp "$a" "$FM_TEST_LOGS/grok.prompt.$n"
  prev=$a
done
[ "${FM_TEST_GROK_RC:-0}" = 0 ] || exit "$FM_TEST_GROK_RC"
cat "$FM_TEST_GROK_REPLY"
SH
# curl stand-in: keeps argv, the body, and the fd-3 header; writes the reply
# file to -o and prints FM_TEST_CURL_HTTP.
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
n=$(( $(cat "$FM_TEST_LOGS/curl.n" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FM_TEST_LOGS/curl.n"
printf '%s\n' "$@" > "$FM_TEST_LOGS/curl.argv.$n"
out='' prev=''
for a in "$@"; do
  [ "$prev" != -o ] || out=$a
  [ "$a" != @/dev/fd/3 ] || cat /dev/fd/3 > "$FM_TEST_LOGS/curl.header.$n"
  prev=$a
done
cat > "$FM_TEST_LOGS/curl.body.$n"
[ -z "$out" ] || cat "$FM_TEST_CURL_REPLY" > "$out"
printf '%s' "${FM_TEST_CURL_HTTP:-200}"
SH
cat > "$DELEGATES/fm-failover.sh" <<'SH'
#!/usr/bin/env bash
n=$(( $(cat "$FM_TEST_LOGS/failover.n" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FM_TEST_LOGS/failover.n"
printf '%s ' "$@" > "$FM_TEST_LOGS/failover.argv.$n"
printf '%s\n' "${FM_CAPTAIN_WATCHER_FAILOVER:-unset}" > "$FM_TEST_LOGS/failover.captain-env.$n"
rc=${FM_TEST_FO_RC:-0}
if [ "${FM_TEST_FO_SILENT:-0}" != 1 ]; then
  [ "$rc" != 0 ] || echo "switched task=${2:-captain} from=claude to=codex reason=${4:-x}"
  [ "$rc" != 1 ] || echo "none task=${2:-captain} reason=no_eligible_runtime"
fi
exit "$rc"
SH
cat > "$DELEGATES/fm-send.sh" <<'SH'
#!/usr/bin/env bash
n=$(( $(cat "$FM_TEST_LOGS/send.n" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FM_TEST_LOGS/send.n"
printf '%s\n' "$@" > "$FM_TEST_LOGS/send.argv.$n"
exit "${FM_TEST_SEND_RC:-0}"
SH
cat > "$DELEGATES/captain-send" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_TEST_LOGS/captain-send"
exit "${FM_TEST_CAPTAIN_SEND_RC:-0}"
SH
chmod +x "$FAKEBIN"/* "$DELEGATES"/*

export FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config" FM_DATA_OVERRIDE="$LAB/data"
export FM_TEST_SEAM=1 FM_STALL_WATCH_TEST_SCREENS="$LAB/screens" FM_STALL_WATCH_TEST_BIN="$DELEGATES"
export FM_TEST_LOGS="$LOGS" FM_TEST_GROK_REPLY="$TMP_ROOT/grok.reply" FM_TEST_CURL_REPLY="$TMP_ROOT/curl.reply"
export HOME="$TMP_ROOT/user" PATH="$FAKEBIN:$PATH"
unset TYPESAFE_API_KEY TYPESAFE_BASE FM_TEST_GROK_RC FM_TEST_CURL_HTTP FM_TEST_FO_RC FM_TEST_FO_SILENT FM_TEST_SEND_RC FM_STALL_WATCH_NOW

reset_lab() {
  rm -rf "${LAB:?}" "${LOGS:?}"
  mkdir -p "$LAB/state" "$LAB/config" "$LAB/data" "$LAB/screens" "$LOGS"
  grok_says idle_with_goals 0.9
}

grok_says() {  # <reason> <confidence>
  jq -cn --arg r "$1" --argjson c "$2" '{structuredOutput: {reason: $r, confidence: $c}, total_cost_usd: 0.0581}' > "$FM_TEST_GROK_REPLY"
}

jev_says() {  # <choice> <confidence>
  jq -cn --arg r "$1" --argjson c "$2" '{model: "jev-latest", answers: {verdict: {choice: $r, confidence: $c, probabilities: {}}}, usage: {input_tokens: 812, output_tokens: 3}}' > "$FM_TEST_CURL_REPLY"
}

count() { cat "$LOGS/$1.n" 2>/dev/null || echo 0; }

OUT='' ERR='' RC=0
sw() {  # <args...>: run the entry point, keeping stdout, stderr, and the exit code
  RC=0
  OUT=$(bash "$SW" "$@" 2> "$TMP_ROOT/err") || RC=$?
  ERR=$(cat "$TMP_ROOT/err")
}

sw_in() {  # <screen-file> <args...>: the same with the screen on stdin
  local f=$1
  shift
  RC=0
  OUT=$(bash "$SW" "$@" < "$f" 2> "$TMP_ROOT/err") || RC=$?
  ERR=$(cat "$TMP_ROOT/err")
}

# make_worker <id> <fixture>: a ship with a real worktree, a working status,
# and a screen.
make_worker() {
  local id=$1 wt="$TMP_ROOT/wt-$1"
  rm -rf "${wt:?}" "${wt:?}.repo" "${wt:?}.repo.origin.git"
  fm_git_worktree "$wt.repo" "$wt" "fm/$id" >/dev/null 2>&1 || fail "fixture: no worktree for $id"
  fm_write_meta "$LAB/state/$id.meta" "window=fm:fm-$id" kind=ship harness=claude "worktree=$wt" backend=tmux "spawn_gen=s1.$id"
  printf 'working: wiring the parser [at=1]\n' > "$LAB/state/$id.status"
  cp "$FIX/$2" "$LAB/screens/$id.screen"
}

ledger_rows() { awk -F '\t' -v t="$1" '$2 == t' "$LAB/state/stall-watch.tsv" 2>/dev/null | wc -l | tr -d ' '; }

# The planted values are joined from parts at run time so no secret-shaped
# literal is committed; secrets_screen fills them into the recorded screen.
P_GH="gh""p_FAKEexampleTOKEN0123456789abcdefABCD"
P_OPENAI="sk""-FAKEexample0123456789abcdef"
P_AWS="AK""IAFAKEEXAMPLE01234"
P_PASS="hunter2-fake-example"
P_BEARER="FAKEexampleBearerToken"
P_URLPASS="FAKEexamplePass"
P_SLACK="xo""xb-FAKE-example"
P_KEYKIND="OPENSSH PRI""VATE KEY"
P_KEYBODY="b3BlbnNzaC1rZXktdjEAAAAA""FAKEexampleKEYbody"
P_XAI="xa""i-FAKEexample0123456789abcdef"
P_GLPAT="glp""at-FAKEexample0123456789ab"
P_NPM="np""m_FAKEexample0123456789abcdefghij"
P_HF="h""f_FAKEexample0123456789abcd"
P_GOOGLE="AI""zaFAKEexample0123456789abcdefghijk"
P_STRIPE="sk""_live_FAKEexample0123456789"
P_JWT="ey""JhbGciOiJIUzI1NiJ9.eyJzdWIiOiJGQUtFIn0.FAKEsignature0123"
P_CLIKEY="FAKEcliKeyValue0123"
P_CLIQ="FAKEcliQuoted"
P_CLITOK="FAKEcliTokenValue0123"
P_B64="QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlqa2xtbm9wcXJzdHV2d3h5ejAxMjM0NTY3ODk"
P_KEYTAIL="FAKEorphanKeyTail0123"
P_SPACEDIR="Zanzibar"
PLANTED="$P_GH $P_OPENAI $P_AWS $P_PASS $P_BEARER $P_URLPASS $P_SLACK $P_KEYBODY /Users/alice /home/bob
  $P_XAI $P_GLPAT $P_NPM $P_HF $P_GOOGLE $P_STRIPE $P_JWT $P_CLIKEY $P_CLIQ $P_CLITOK $P_B64 $P_KEYTAIL $P_SPACEDIR"

secrets_screen() {  # stdout: tests/fixtures/stall-watch/secrets.screen with the planted values, then more
  sed -e "s|{{GH}}|$P_GH|" -e "s|{{OPENAI}}|$P_OPENAI|" -e "s|{{AWS}}|$P_AWS|" \
    -e "s|{{PASS}}|$P_PASS|" -e "s|{{BEARER}}|$P_BEARER|" -e "s|{{URLPASS}}|$P_URLPASS|" \
    -e "s|{{SLACK}}|$P_SLACK|" -e "s|{{KEYKIND}}|$P_KEYKIND|" -e "s|{{KEYBODY}}|$P_KEYBODY|" \
    "$FIX/secrets.screen"
  printf '  echo %s\n  git push with %s\n  %s\n' "$P_XAI" "$P_GLPAT" "$P_NPM"
  printf '  hub %s and %s\n  stripe %s\n  cookie %s\n' "$P_HF" "$P_GOOGLE" "$P_STRIPE" "$P_JWT"
  printf '  %s\n  open "/Users/alice/My %s Plans/plan.md"\n' "$P_B64" "$P_SPACEDIR"
  printf '  mytool --api-key %s --password "%s pass" --token=%s\n' "$P_CLIKEY" "$P_CLIQ" "$P_CLITOK"
  # A key block whose BEGIN row has scrolled off the top.
  printf '  %s\n  %s\n  -----END %s-----\n' "$P_B64" "$P_KEYTAIL" "$P_KEYKIND"
}
assert_no_planted() {  # <text> <where>
  local s
  for s in $PLANTED "$HOME"; do
    assert_not_contains "$1" "$s" "$2 must not carry $s"
  done
}

test_screen_redacts_secrets_and_paths() {
  reset_lab
  { secrets_screen; printf 'wrote %s/projects/notes.md\n' "$HOME"; printf 'echo %s done\n' "sk""-FAKEbareExample0123456789"; } > "$LAB/screens/captain.screen"
  sw screen captain
  expect_code 0 "$RC" "screen reads the captain screen: $ERR"
  assert_no_planted "$OUT" 'the redacted screen'
  assert_contains "$OUT" 'GITHUB_TOKEN=<redacted>' 'a token value is replaced in place'
  assert_contains "$OUT" 'https://<redacted>@git.example.com' 'URL credentials are replaced'
  assert_contains "$OUT" '<redacted private key>' 'a private key block collapses to one marker'
  assert_contains "$OUT" 'Edited <path> and <path>' 'absolute user paths become <path>'
  assert_contains "$OUT" 'wrote <path>' 'the home directory becomes <path>'
  assert_contains "$OUT" 'echo <redacted> done' 'a bare provider key is replaced in place'
  assert_contains "$OUT" '<redacted key material>' 'a long base64 row is replaced whole'
  assert_contains "$OUT" 'open "<path>"' 'a quoted user path with spaces is replaced whole'
  assert_contains "$OUT" '--api-key <redacted> --password <redacted> --token=<redacted>' 'secret option values are replaced'
  assert_equals 2 "$(printf '%s\n' "$OUT" | grep -c '<redacted private key>')" 'a key block, and one whose BEGIN row scrolled away, each collapse to one marker'  assert_contains "$OUT" 'row(s) withheld: credential-like text' 'a row still credential-like is withheld and counted'
  sw screen captain --lines 3
  [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" -le 3 ] || fail "--lines 3 printed more than 3 rows: $OUT"
  sw screen ghost
  expect_code 1 "$RC" 'an unreadable screen exits 1'
  sw screen '../x'
  expect_code 2 "$RC" 'an invalid target is a usage error'
  pass 'screen: tokens, keys, URL credentials, private keys, and user paths are redacted; leftovers withheld'
}

test_deterministic_pass_skips_the_model() {
  reset_lab
  sw_in "$FIX/rate-limited.screen" classify --classifier grok
  assert_contains "$OUT" 'verdict=rate_limit stalled=yes source=rule' 'a recognized 429 is classed by rule'
  printf 'Allow this command?\n\n❯ 1. Yes\n  2. No\n\nEnter to confirm · Esc to cancel\n' > "$TMP_ROOT/dialog.screen"
  sw_in "$TMP_ROOT/dialog.screen" classify --classifier grok
  assert_contains "$OUT" 'verdict=waiting_on_human stalled=yes source=rule' 'a recognized dialog waits on a person by rule'
  printf 'Which plan should I follow?\n ❯ 1. Plan A (Recommended)\n   2. Plan B\n\nEnter to select · ↑/↓ to navigate · Esc to cancel\n' > "$TMP_ROOT/question.screen"
  sw_in "$TMP_ROOT/question.screen" classify --classifier grok
  assert_contains "$OUT" 'verdict=waiting_on_human stalled=yes source=rule' 'a question picker waits on a person by rule'
  printf 'You hit your weekly limit.\n ❯ 1. Wait\n   2. Stop\n\nEnter to confirm · Esc to cancel\n' > "$TMP_ROOT/limit.screen"
  sw_in "$TMP_ROOT/limit.screen" classify --classifier grok
  assert_contains "$OUT" 'verdict=usage_limit stalled=yes source=rule' 'a usage-limit picker is a usage limit by rule'
  sw_in "$FIX/stalled.screen" classify --classifier grok --kind captain --open-work no
  assert_contains "$OUT" 'verdict=idle_done stalled=no source=supervision' 'a captain with no open work is idle_done without a model'
  assert_equals 0 "$(count grok)" 'no deterministic verdict called the model'
  assert_equals 0 "$(count curl)" 'no deterministic verdict called Jev'
  pass 'deterministic pass: rule refusals, dialogs, and no open work never reach a model'
}

# A rendered busy footer is vendor text that can linger in scrollback, so it
# never decides by rule; the classifier reads it, and a semantic busy record
# (test_unchanged_screen_guard) is the deterministic working signal.
test_rendered_activity_is_not_a_rule() {
  reset_lab
  sw_in "$FIX/working.screen" classify --classifier none
  assert_contains "$OUT" 'verdict=unsure stalled=unsure source=none' 'a busy footer alone is not decided by rule'
  printf 'Plan · 3/8\n\n ⠇ Reading files  (Press ESC to stop)\n\n╭──────╮\n│ > Enter to steer │\n╰──────╯\n' > "$TMP_ROOT/droid-hint.screen"
  sw_in "$TMP_ROOT/droid-hint.screen" classify --classifier none
  assert_contains "$OUT" 'verdict=unsure' 'a stop hint alone is not decided by rule'
  grok_says working 0.95
  sw_in "$FIX/working.screen" classify --classifier grok
  assert_contains "$OUT" 'verdict=working stalled=no source=grok' 'the classifier judges a busy footer'
  assert_equals 1 "$(count grok)" 'one model call for the busy footer'
  pass 'rendered activity: a busy footer reaches the classifier instead of a rule'
}

test_model_judge_maps_answers() {
  local g
  reset_lab
  grok_says idle_with_goals 0.92
  sw_in "$FIX/stalled.screen" classify --classifier grok
  assert_contains "$OUT" 'verdict=idle_with_goals stalled=yes source=grok confidence=0.92' 'a confident grok answer maps to stalled'
  assert_contains "$OUT" 'cost_usd=0.0581' 'the reported cost is kept'
  assert_contains "$(cat "$LOGS/grok.argv.1")" 'grok-4.7-build-fast' 'the Grok fast tier is the default model'
  grok_says idle_done 0.4
  sw_in "$FIX/idle-done.screen" classify --classifier grok
  assert_contains "$OUT" 'verdict=idle_done stalled=unsure source=grok' 'a not-stalled answer below the floor is unsure'
  assert_contains "$OUT" 'below-floor' 'the floor is named'
  grok_says idle_done 0.95
  sw_in "$FIX/idle-done.screen" classify --classifier grok
  assert_contains "$OUT" 'verdict=idle_done stalled=no source=grok' 'a confident not-stalled answer is not stalled'
  FM_TEST_GROK_RC=1 sw_in "$FIX/stalled.screen" classify --classifier grok
  assert_contains "$OUT" 'verdict=unsure stalled=unsure source=none' 'a failed grok call is unsure'
  assert_contains "$OUT" 'grok-exit-1' 'the failure is named'
  printf '{"structuredOutput":{"reason":"sleeping","confidence":0.9}}\n' > "$FM_TEST_GROK_REPLY"
  sw_in "$FIX/stalled.screen" classify --classifier grok
  assert_contains "$OUT" 'verdict=unsure' 'an answer outside the reasons is unsure'
  sw_in "$FIX/stalled.screen" classify --classifier none
  assert_contains "$OUT" 'verdict=unsure stalled=unsure source=none' 'classifier none leaves an ambiguous screen unsure'

  jev_says api_error 0.88
  TYPESAFE_API_KEY=ts-test-key-123 sw_in "$FIX/api-error.screen" classify
  assert_contains "$OUT" 'verdict=api_error stalled=yes source=jev confidence=0.88' 'jev is the default classifier when a key exists'
  assert_contains "$OUT" 'jev-tokens=812/3' 'token usage is kept'
  assert_contains "$(cat "$LOGS/curl.argv.1")" 'https://api.typesafe.ai/v1/systemone' 'jev posts to the TypeSafe systemone endpoint'
  assert_not_contains "$(cat "$LOGS/curl.argv.1")" 'ts-test-key-123' 'the key never reaches argv'
  assert_equals 'Authorization: Bearer ts-test-key-123' "$(cat "$LOGS/curl.header.1")" 'the key reaches curl through fd 3'
  assert_equals jev-latest "$(jq -r .model "$LOGS/curl.body.1")" 'the request names jev-latest'
  assert_equals choice "$(jq -r .questions.verdict.type "$LOGS/curl.body.1")" 'the request is one Choice question'
  assert_equals 10 "$(jq -r '.questions.verdict.criteria | length' "$LOGS/curl.body.1")" 'every reason is an option'

  grok_says api_error 0.8
  sw_in "$FIX/api-error.screen" classify
  assert_contains "$OUT" 'source=grok' 'jev with no key falls back to grok'
  assert_contains "$OUT" 'jev:no-key' 'the fallback is recorded'
  assert_contains "$ERR" 'jev unavailable (no TypeSafe key' 'the fallback logs one line saying so'
  printf 'TYPESAFE_API_KEY=ts-env-file-key\nTYPESAFE_BASE=https://ts.example.test/\n' > "$LAB/.env"
  FM_TEST_CURL_HTTP=500 sw_in "$FIX/api-error.screen" classify
  assert_contains "$(cat "$LOGS/curl.argv.2")" 'https://ts.example.test/v1/systemone' 'TYPESAFE_BASE from .env is honored'
  assert_equals 'Authorization: Bearer ts-env-file-key' "$(cat "$LOGS/curl.header.2")" 'the key from .env is used'
  assert_contains "$OUT" 'source=grok' 'a failed jev call falls back to grok'
  assert_contains "$ERR" 'jev call failed (jev-http-500)' 'the failed call is logged'
  printf 'TYPESAFE_BASE=https://user:pw@ts.example.test\n' > "$LAB/.env"
  TYPESAFE_API_KEY=k sw_in "$FIX/api-error.screen" classify
  assert_contains "$OUT" 'jev:jev-base-invalid' 'an invalid base is refused without a call'
  assert_equals 2 "$(count curl)" 'nothing was posted to an invalid base'
  rm -f "$LAB/.env"
  g=$(count grok)
  jev_says idle_done 0.3
  TYPESAFE_API_KEY=k sw_in "$FIX/idle-done.screen" classify
  assert_contains "$OUT" 'verdict=idle_done stalled=unsure source=jev' 'a jev answer below the floor is unsure'
  assert_contains "$OUT" 'below-floor' 'the floor is named for jev'
  assert_equals "$g" "$(count grok)" 'a usable jev answer below the floor never asks grok'
  printf '{"answers":{"verdict":{"choice":"sleeping","confidence":0.9}}}\n' > "$FM_TEST_CURL_REPLY"
  TYPESAFE_API_KEY=k sw_in "$FIX/api-error.screen" classify
  assert_contains "$OUT" 'source=grok' 'an unparseable jev answer falls back to grok'
  assert_contains "$OUT" 'jev:jev-unparseable' 'the unparseable answer is recorded'
  assert_equals $((g + 1)) "$(count grok)" 'one grok call for the fallback'
  pass 'model judge: jev by default, grok fallback, floors, failures, and the key kept out of argv'
}

test_classifier_never_sees_secrets() {
  reset_lab
  { secrets_screen; printf 'wrote %s/projects/notes.md\n' "$HOME"; } > "$TMP_ROOT/s.screen"
  sw_in "$TMP_ROOT/s.screen" classify --classifier grok --status "working: token=FAKEstatusSecret99 in /Users/alice/x"
  assert_present "$LOGS/grok.prompt.1"
  assert_no_planted "$(cat "$LOGS/grok.prompt.1")" 'the grok prompt'
  assert_not_contains "$(cat "$LOGS/grok.prompt.1")" 'FAKEstatusSecret99' 'the grok prompt status line'
  assert_contains "$(cat "$LOGS/grok.prompt.1")" 'GITHUB_TOKEN=<redacted>' 'the grok prompt carries the redacted screen'
  jev_says idle_with_goals 0.9
  TYPESAFE_API_KEY=ts-test-key-123 sw_in "$TMP_ROOT/s.screen" classify
  assert_no_planted "$(cat "$LOGS/curl.body.1")" 'the jev request body'
  assert_not_contains "$(cat "$LOGS/curl.body.1")" 'ts-test-key-123' 'the jev request body'
  pass 'redaction boundary: neither classifier receives a planted secret or private path'
}

test_unchanged_screen_guard() {
  reset_lab
  make_worker w1 stalled.screen
  grok_says idle_done 0.95
  sw check w1
  assert_contains "$OUT" 'verdict=progress stalled=no source=fingerprint' 'the first check only records the screen'
  assert_equals 0 "$(count grok)" 'a new screen is never classified'
  sw check w1
  assert_contains "$OUT" 'verdict=idle_done stalled=no source=grok' 'an unchanged screen is classified'
  assert_equals 1 "$(count grok)" 'one model call for the unchanged screen'
  printf '\n• Started the third case.\n' >> "$LAB/screens/w1.screen"
  sw check w1
  assert_contains "$OUT" 'verdict=progress' 'a changed screen is progress'
  printf 'working: third case [at=2]\n' >> "$LAB/state/w1.status"
  sw check w1
  assert_contains "$OUT" 'verdict=progress' 'a new status line is progress'
  printf 'x\n' > "$TMP_ROOT/wt-w1/new.txt"
  git -C "$TMP_ROOT/wt-w1" add new.txt >/dev/null 2>&1
  git -C "$TMP_ROOT/wt-w1" -c user.name=t -c user.email=t@example.com commit -qm next >/dev/null 2>&1 || fail 'fixture: commit'
  sw check w1
  assert_contains "$OUT" 'verdict=progress' 'a new commit is progress'
  assert_equals 1 "$(count grok)" 'progress never calls the model'
  assert_equals 5 "$(ledger_rows w1)" 'one ledger row per check'
  sw check w1 --dry-run
  assert_contains "$OUT" 'action=dry-run' 'a dry run classifies'
  assert_contains "$OUT" 'fingerprint=same' 'a dry run reports the guard'
  assert_equals 5 "$(ledger_rows w1)" 'a dry run writes no row'
  bash "$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" w1 >/dev/null || fail 'fixture: arm'
  sw check w1
  assert_contains "$OUT" 'verdict=working stalled=no source=busy' 'a busy semantic record is working'
  pass 'guard: only an unchanged screen, HEAD, and status reach the judge; busy is working'
}

test_actions() {
  reset_lab
  make_worker w2 api-error.screen
  grok_says api_error 0.9
  sw check w2; sw check w2
  assert_contains "$OUT" 'verdict=api_error stalled=yes source=grok' 'the model judges the API error'
  assert_contains "$OUT" 'action=failover-switched' 'a model-judged API error fails over'
  assert_equals "worker w2 --reason api_error --state $LAB/state " "$(cat "$LOGS/failover.argv.1")" 'fm-failover.sh worker with the class'
  assert_contains "$(awk -F '\t' '$3 == "check"' "$LAB/state/.wake-queue")" 'stall-w2-' 'the outcome is a check wake'
  assert_contains "$(cat "$LAB/state/stall-watch"/.report.*)" 'check: w2 moved to the next runtime after the stall check judged it stopped (api_error per grok' 'the report names the judgment'
  sw check w2
  assert_contains "$OUT" 'verdict=already-handled' 'the same screen is handled once'
  assert_equals 1 "$(count failover)" 'one failover per screen'
  assert_equals 1 "$(count grok)" 'a handled screen is not classified again'

  make_worker w3 stalled.screen
  grok_says idle_with_goals 0.9
  sw check w3; sw check w3
  assert_contains "$OUT" 'action=nudged' 'idle with open work is nudged first'
  assert_equals w3 "$(head -n 1 "$LOGS/send.argv.1")" 'the nudge goes through fm-send to the task'
  assert_contains "$(cat "$LOGS/send.argv.1")" 'Stall check:' 'the nudge text'
  sw check w3
  assert_contains "$OUT" 'action=failover-switched' 'still idle on the next check fails over'
  assert_equals "worker w3 --reason stalled --state $LAB/state " "$(cat "$LOGS/failover.argv.2")" 'failover with --reason stalled'

  make_worker w4 waiting-on-human.screen
  grok_says waiting_on_human 0.9
  sw check w4; sw check w4
  assert_contains "$OUT" 'action=escalated' 'a worker waiting on a person escalates'
  assert_contains "$(awk -F '\t' '$3 == "check"' "$LAB/state/.wake-queue")" 'w4 is waiting on a person' 'the escalation wake'
  sw check w4
  assert_contains "$OUT" 'already-handled' 'one escalation per screen'

  make_worker w5 rate-limited.screen
  sw check w5; sw check w5
  assert_contains "$OUT" 'verdict=rate_limit stalled=yes source=rule' 'a rule refusal'
  assert_contains "$OUT" 'action=watcher-owned' 'a rule refusal is left to the watcher failover'
  assert_equals 2 "$(count failover)" 'no failover from the stall check for a rule refusal'

  make_worker w6 idle-done.screen
  grok_says idle_done 0.9
  sw check w6; sw check w6
  assert_contains "$OUT" 'verdict=idle_done stalled=no source=grok confidence=0.9 latency_ms=' 'idle done'
  assert_contains "$OUT" 'action=none' 'idle done does nothing'

  make_worker w7 stalled.screen
  sw check w7
  FM_TEST_GROK_RC=1 sw check w7
  assert_contains "$OUT" 'action=wait' 'the first unsure check waits'
  FM_TEST_GROK_RC=1 sw check w7
  assert_contains "$OUT" 'action=escalated' 'the same screen unsure again escalates'
  assert_contains "$(awk -F '\t' '$3 == "check"' "$LAB/state/.wake-queue")" 'w7 may be stalled and the classifier could not tell twice' 'the unsure escalation wake'

  make_worker w8 stalled.screen
  printf 'done: PR opened [at=3]\n' >> "$LAB/state/w8.status"
  rm -f "$LAB/screens/w8.screen"
  sw check w8
  assert_contains "$OUT" 'verdict=declared stalled=no source=status' 'a declared status is left to supervision'
  assert_contains "$OUT" 'status=done' 'the declared word is named'

  make_worker w9 api-error.screen
  grok_says api_error 0.9
  sw check w9
  FM_TEST_FO_RC=5 sw check w9
  assert_contains "$OUT" 'action=failover-locked' 'a held failover lock'
  sw check w9
  assert_contains "$OUT" 'action=failover-switched' 'a locked failover is retried on the next check'
  pass 'actions: failover, nudge then failover, escalation, rule refusals left alone, once per screen'
}

test_captain_actions() {
  local now
  reset_lab
  make_worker w1 working.screen
  cp "$FIX/stalled.screen" "$LAB/screens/captain.screen"
  sw check captain; sw check captain
  assert_contains "$OUT" 'verdict=idle_done stalled=no source=supervision' 'a captain idle with workers running and nothing owed is waiting on its watcher'
  assert_equals 0 "$(count grok)" 'a healthy idle captain never reaches the model'
  FM_DISPATCH_NOW=1000 bash "$ROOT/bin/fm-dispatch-log.sh" received g1 --summary 'a goal' >/dev/null || fail 'fixture: received'
  cp "$FIX/api-error.screen" "$LAB/screens/captain.screen"
  grok_says usage_limit 0.9
  sw check captain; sw check captain
  assert_contains "$OUT" 'action=failover-switched' 'a model-judged refusal of a captain with an overdue goal fails over'
  assert_equals 'captain --reason usage_limit ' "$(cat "$LOGS/failover.argv.1")" 'fm-failover.sh captain with the class'
  assert_equals 1 "$(cat "$LOGS/failover.captain-env.1")" 'the watcher authorization is requested'
  cp "$FIX/stalled.screen" "$LAB/screens/captain.screen"
  grok_says idle_with_goals 0.9
  sw check captain; sw check captain
  assert_contains "$OUT" 'action=nudged' 'an idle captain with work owed is nudged'
  assert_contains "$(cat "$LOGS/captain-send")" 'Stall check:' 'the captain typer received the nudge'
  sw check captain
  assert_contains "$OUT" 'action=escalated' 'a captain still idle after the nudge is escalated'
  assert_contains "$(awk -F '\t' '$3 == "check"' "$LAB/state/.wake-queue")" 'captain is still idle with work waiting after a nudge' 'the escalation wake'
  assert_equals 1 "$(count failover)" 'an idle captain is never failed over as stalled'
  sw check captain
  assert_contains "$OUT" 'already-handled' 'one escalation per screen'
  cp "$FIX/waiting-on-human.screen" "$LAB/screens/captain.screen"
  grok_says waiting_on_human 0.9
  sw check captain; sw check captain
  assert_contains "$OUT" 'action=none' 'a captain waiting on its owner is only recorded'
  assert_contains "$OUT" 'waiting-on-owner' 'the reason is named'
  # The captain's backend reports its native busy state (hc's `get --json`).
  cat > "$TMP_ROOT/hc" <<'SH'
#!/usr/bin/env bash
[ "$1" = get ] || exit 1
printf '{"status":{"state":"%s"}}\n' "$FM_TEST_HC_STATE"
SH
  chmod +x "$TMP_ROOT/hc"
  printf 'backend=hc\nterminal=default:t1\n' > "$LAB/state/.lock-session"
  cp "$FIX/working.screen" "$LAB/screens/captain.screen"
  grok_says idle_with_goals 0.9
  FM_HC_BIN="$TMP_ROOT/hc" FM_TEST_HC_STATE=working sw check captain
  FM_HC_BIN="$TMP_ROOT/hc" FM_TEST_HC_STATE=working sw check captain
  assert_contains "$OUT" 'verdict=working stalled=no source=busy' 'a natively busy captain is working without a model'
  FM_HC_BIN="$TMP_ROOT/hc" FM_TEST_HC_STATE=idle sw check captain
  assert_contains "$OUT" 'source=grok' 'a natively idle captain with work owed reaches the classifier'
  rm -f "$LAB/state/.lock-session" "$LAB/state/dispatch-log.tsv"
  cp "$FIX/stalled.screen" "$LAB/screens/captain.screen"
  printf '\n• Finished.\n' >> "$LAB/screens/captain.screen"
  sw check captain; sw check captain
  assert_contains "$OUT" 'verdict=idle_done stalled=no source=supervision' 'wakes queued within the interval are not work owed'
  assert_contains "$OUT" 'action=none' 'an idle captain with nothing owed is left alone'
  now=$(date +%s)
  printf '%s\t%s\tcheck\told-key\tan old wake\n' "$((now - 5000))" 999 >> "$LAB/state/.wake-queue"
  sw check captain
  assert_contains "$OUT" 'verdict=idle_with_goals stalled=yes source=grok' 'a wake left in the queue past one interval is work owed'
  assert_contains "$OUT" 'action=nudged' 'and the idle captain is nudged'
  pass 'captain: idle and owing nothing is healthy; owed work comes from overdue goals or old wakes; nudge then one escalation, never a stalled failover'
}

# A declared verb is read from the raw status line, while the classifier only
# ever receives its redacted copy.
test_declared_status_reads_the_raw_verb() {
  reset_lab
  make_worker d1 stalled.screen
  printf 'needs-decision: rotate the password: %s [at=3]\n' "$P_PASS" >> "$LAB/state/d1.status"
  sw check d1
  assert_contains "$OUT" 'verdict=declared stalled=no source=status' 'a credential-like decision line is still declared'
  assert_contains "$OUT" 'status=needs-decision' 'its verb survives redaction'
  make_worker d2 stalled.screen
  printf 'done: fixed the Authorization: header handling [at=3]\n  The follow-up is in the PR body.\n' >> "$LAB/state/d2.status"
  sw check d2
  assert_contains "$OUT" 'status=done' 'a withheld done line with continuation prose is still declared'
  make_worker d3 stalled.screen
  printf 'working: rotate the password: %s [at=3]\n' "$P_PASS" >> "$LAB/state/d3.status"
  grok_says idle_with_goals 0.9
  sw check d3; sw check d3
  assert_contains "$OUT" 'source=grok' 'an undeclared worker is judged'
  assert_not_contains "$(cat "$LOGS/grok.prompt.1")" "$P_PASS" 'the classifier never receives the raw status line'
  pass 'declared status: the verb comes from the raw line; the classifier gets the redacted copy'
}

# A nudge ends only with real work: a new commit or status line. A screen
# change alone, such as the nudge doorbell, keeps it, so idle again fails over.
test_nudge_ends_with_work() {
  reset_lab
  make_worker n3 stalled.screen
  grok_says idle_with_goals 0.9
  sw check n3; sw check n3
  assert_contains "$OUT" 'action=nudged' 'the first idle check nudges'
  printf 'x\n' > "$TMP_ROOT/wt-n3/work.txt"
  git -C "$TMP_ROOT/wt-n3" add work.txt >/dev/null 2>&1
  git -C "$TMP_ROOT/wt-n3" -c user.name=t -c user.email=t@example.com commit -qm work >/dev/null 2>&1 || fail 'fixture: commit'
  sw check n3
  assert_contains "$OUT" 'verdict=progress' 'a commit is progress'
  assert_contains "$OUT" 'worked-after-nudge' 'and it ends the nudge'
  sw check n3
  assert_contains "$OUT" 'action=nudged' 'the next idle spell starts with a nudge again'
  assert_equals 0 "$(count failover)" 'work after a nudge never leads to a stalled failover'
  printf '\n• doorbell\n' >> "$LAB/screens/n3.screen"
  sw check n3
  assert_contains "$OUT" 'nudged-at=' 'a screen change alone keeps the nudge'
  sw check n3
  assert_contains "$OUT" 'action=failover-switched' 'still idle after that fails over'
  pass 'nudge: a commit or status line ends it; a screen change alone does not'
}

# The watcher's failover skips a refusal row after an ordinary Claude stop, so
# the stall check judges that screen instead of leaving it to the watcher.
test_refusal_after_ordinary_stop_is_judged() {
  local gen
  reset_lab
  make_worker r1 rate-limited.screen
  gen=$(bash "$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" r1) || fail 'fixture: arm'
  bash "$ROOT/bin/fm-busy-event.sh" apply "$LAB/state" r1 idle --gen "$gen" --source claude-hook --event stop >/dev/null || fail 'fixture: stop'
  grok_says rate_limit 0.9
  sw check r1; sw check r1
  assert_contains "$OUT" 'verdict=rate_limit stalled=yes source=grok' 'the refusal row is judged by the classifier'
  assert_contains "$OUT" 'action=failover-switched' 'and the stall check fails over itself'
  make_worker r2 rate-limited.screen
  gen=$(bash "$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" r2) || fail 'fixture: arm'
  bash "$ROOT/bin/fm-busy-event.sh" apply "$LAB/state" r2 idle --gen "$gen" --source claude-hook --event stop-failure >/dev/null || fail 'fixture: stop-failure'
  sw check r2; sw check r2
  assert_contains "$OUT" 'action=watcher-owned' 'after a stop-failure the row stays the watcher'"'"'s'
  assert_equals 1 "$(count grok)" 'only the ordinary stop reached the classifier'
  pass 'refusal rows: left to the watcher unless the Claude hook recorded an ordinary stop'
}
config_reports() { grep -l 'the stall check is not running' "$LAB/state/stall-watch"/.report.* 2>/dev/null | wc -l | tr -d ' '; }

test_tick_schedule() {
  reset_lab
  make_worker t1 stalled.screen
  make_worker t2 working.screen
  sw tick
  assert_contains "$ERR" 'off (no config/stall-watch)' 'no config, no tick'
  assert_absent "$LAB/state/stall-watch.tsv"
  printf 'interval=600\nclassifier=none\n' > "$LAB/config/stall-watch"
  FM_STALL_WATCH_NOW=100000 sw tick
  expect_code 0 "$RC" "tick: $ERR"
  assert_equals 1 "$(ledger_rows t1)" 'the tick checks t1'
  assert_equals 1 "$(ledger_rows t2)" 'the tick checks t2'
  FM_STALL_WATCH_NOW=100300 sw tick
  assert_equals 1 "$(ledger_rows t1)" 'a tick before the interval does nothing'
  FM_STALL_WATCH_NOW=100600 sw tick
  assert_equals 2 "$(ledger_rows t1)" 'the next tick runs once the interval passed'
  FM_STALL_WATCH_NOW=100601 sw tick --force
  assert_equals 3 "$(ledger_rows t1)" '--force ignores the interval'
  mkdir -p "$LAB/state/stall-watch/.tick.lock"
  printf '%s\n' "$$" > "$LAB/state/stall-watch/.tick.lock/pid"
  FM_STALL_WATCH_NOW=200000 sw tick
  assert_contains "$ERR" 'another tick is running' 'a live tick is single-flight'
  assert_equals 3 "$(ledger_rows t1)" 'no check while another tick runs'
  printf '999999\n' > "$LAB/state/stall-watch/.tick.lock/pid"
  FM_STALL_WATCH_NOW=200000 sw tick
  assert_equals 4 "$(ledger_rows t1)" 'a dead lock holder is replaced'
  printf 'classifier=gpt\n' > "$LAB/config/stall-watch"
  sw tick
  expect_code 2 "$RC" 'an unknown classifier is a configuration error'
  assert_equals 1 "$(config_reports)" 'a tick reports the invalid file'
  assert_contains "$(awk -F '\t' '$3 == "check"' "$LAB/state/.wake-queue")" 'the stall check is not running because config/stall-watch classifier must be' 'the report names the error'
  sw tick
  expect_code 2 "$RC" 'the same invalid file is still an error'
  assert_equals 1 "$(config_reports)" 'the same file content is reported once'
  printf 'classifier=gpt\ninterval=600\n' > "$LAB/config/stall-watch"
  sw check t1
  expect_code 2 "$RC" 'check refuses the invalid file too'
  assert_equals 1 "$(config_reports)" 'only a tick reports'
  sw tick
  assert_equals 2 "$(config_reports)" 'a changed invalid file is reported again'
  printf 'interval=600\nclassifier=none\n' > "$LAB/config/stall-watch"
  FM_STALL_WATCH_NOW=300000 sw tick
  expect_code 0 "$RC" "a fixed file ticks again: $ERR"
  printf 'classifier=gpt\n' > "$LAB/config/stall-watch"
  sw tick
  assert_equals 3 "$(config_reports)" 'a valid tick clears the memory, so the old error is reported again'
  pass 'tick: opt-in, interval, force, single-flight, config validation, and one report per invalid file'
}

launch_age() { perl -e 'print time - (stat $ARGV[0])[9]' "$1/state/stall-watch/.last-launch"; }

test_watcher_starts_tick_and_delivers_reports() {
  local dir pid i
  dir=$(make_case watch-stall)
  mkdir -p "$dir/config" "$dir/home"
  printf '%s\n' "$(cat "$FIX/stalled.screen")" > "$dir/pane.txt"
  fm_git_worktree "$dir/repo" "$dir/wt" fm/fo >/dev/null 2>&1 || fail 'fixture: no worktree'
  fm_write_meta "$dir/state/fo.meta" window=test:fm-fo kind=ship harness=claude "worktree=$dir/wt" spawn_gen=s1.fo
  printf 'working: wiring the parser\n' > "$dir/state/fo.status"
  printf '%s' "$(seen_sig "$dir/state/fo.status")" > "$dir/state/.seen-fo_status"
  printf 'classifier=none\n' > "$dir/config/stall-watch"
  ( unset FM_TEST_SEAM FM_STALL_WATCH_TEST_SCREENS FM_STALL_WATCH_TEST_BIN
    FM_HOME="$dir/home" FM_CONFIG_OVERRIDE="$dir/config" FM_DATA_OVERRIDE="$dir/home/data" \
      watch_bg "$dir/state" "$dir/fakebin" "$dir/watch.out" env FM_FAKE_TMUX_WINDOW=test:fm-fo FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_WATCH_ONCE=1
    wait "$!" 2>/dev/null || true )
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$dir/state/stall-watch.tsv" ]; do sleep 0.1; i=$((i + 1)); done
  assert_present "$dir/state/stall-watch.tsv"
  assert_contains "$(cat "$dir/state/stall-watch.tsv")" $'fo\tprogress\tno\tfingerprint' 'the watcher-started tick read the real pane through the backend'
  # A launch touches .last-launch first, so its age shows whether one happened.
  perl -e 'my $t = time - 30; utime $t, $t, $ARGV[0]' "$dir/state/stall-watch/.last-launch"
  ( unset FM_TEST_SEAM FM_STALL_WATCH_TEST_SCREENS FM_STALL_WATCH_TEST_BIN
    FM_HOME="$dir/home" FM_CONFIG_OVERRIDE="$dir/config" FM_DATA_OVERRIDE="$dir/home/data" \
      watch_bg "$dir/state" "$dir/fakebin" "$dir/watch1.out" env FM_FAKE_TMUX_WINDOW=test:fm-fo FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_WATCH_ONCE=1
    wait "$!" 2>/dev/null || true )
  [ "$(launch_age "$dir")" -ge 25 ] || fail 'a launch within the last minute must not launch again'
  perl -e 'my $t = time - 120; utime $t, $t, $ARGV[0]' "$dir/state/stall-watch/.last-launch"
  ( unset FM_TEST_SEAM FM_STALL_WATCH_TEST_SCREENS FM_STALL_WATCH_TEST_BIN
    FM_HOME="$dir/home" FM_CONFIG_OVERRIDE="$dir/config" FM_DATA_OVERRIDE="$dir/home/data" \
      watch_bg "$dir/state" "$dir/fakebin" "$dir/watch1.out" env FM_FAKE_TMUX_WINDOW=test:fm-fo FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_WATCH_ONCE=1
    wait "$!" 2>/dev/null || true )
  [ "$(launch_age "$dir")" -lt 25 ] || fail 'a launch older than a minute must launch again'
  printf 'check: fo looks stalled (test report)\n' > "$dir/state/stall-watch/.report.1.1"
  ( unset FM_TEST_SEAM FM_STALL_WATCH_TEST_SCREENS FM_STALL_WATCH_TEST_BIN
    FM_HOME="$dir/home" FM_CONFIG_OVERRIDE="$dir/config" FM_DATA_OVERRIDE="$dir/home/data" \
      watch_bg "$dir/state" "$dir/fakebin" "$dir/watch2.out" env FM_FAKE_TMUX_WINDOW=test:fm-fo FM_FAKE_TMUX_CAPTURE="$dir/pane.txt"
    pid=$!
    wait_for_exit "$pid" 300 >/dev/null 2>&1 || true )
  assert_contains "$(cat "$dir/watch2.out")" 'check: fo looks stalled (test report)' 'the watcher wakes with the tick report'
  assert_absent "$dir/state/stall-watch/.report.1.1"
  pass 'watcher: starts the tick detached at most once a minute while opted in and delivers each report once'
}

# One case per remaining decision of cmd_check: escalations by class, model
# refusals per class, an undeliverable or expired nudge, every failover exit,
# and the targets a check skips.
test_decided_scenarios() {
  local id r rc
  reset_lab
  make_worker a1 stalled.screen
  grok_says auth 0.9
  sw check a1; sw check a1
  assert_contains "$OUT" 'verdict=auth stalled=yes source=grok' 'auth is judged'
  assert_contains "$OUT" 'action=escalated' 'auth escalates'
  assert_contains "$(awk -F '\t' '$3 == "check"' "$LAB/state/.wake-queue")" 'a1 looks signed out or its credentials were rejected' 'the auth wake'
  make_worker c1 stalled.screen
  grok_says crashed 0.9
  sw check c1; sw check c1
  assert_contains "$OUT" 'action=escalated' 'crashed escalates'
  assert_contains "$(awk -F '\t' '$3 == "check"' "$LAB/state/.wake-queue")" 'c1 looks crashed' 'the crashed wake'
  assert_equals 0 "$(count failover)" 'escalations never fail over'

  for r in rate_limit usage_limit billing; do
    id="m-$r"
    id=${id//_/-}
    make_worker "$id" stalled.screen
    grok_says "$r" 0.9
    sw check "$id"; sw check "$id"
    assert_contains "$OUT" "verdict=$r stalled=yes source=grok" "a model-judged $r"
    assert_contains "$OUT" 'action=failover-switched' "a model-judged $r fails over"
  done
  assert_equals "worker m-billing --reason billing --state $LAB/state " "$(cat "$LOGS/failover.argv.3")" 'the worker failover carries the class'

  make_worker n1 stalled.screen
  grok_says idle_with_goals 0.9
  FM_STALL_WATCH_NOW=1000 sw check n1
  FM_TEST_SEND_RC=1 FM_STALL_WATCH_NOW=2000 sw check n1
  assert_contains "$OUT" 'action=escalated' 'a nudge that could not be delivered escalates'
  assert_contains "$(awk -F '\t' '$3 == "check"' "$LAB/state/.wake-queue")" 'n1 is idle with open work and could not be nudged' 'the undeliverable nudge wake'
  make_worker n2 stalled.screen
  FM_STALL_WATCH_NOW=1000 sw check n2
  FM_STALL_WATCH_NOW=2000 sw check n2
  assert_contains "$OUT" 'action=nudged' 'the first idle check nudges'
  FM_STALL_WATCH_NOW=5601 sw check n2
  assert_contains "$OUT" 'action=nudged' 'a nudge older than three intervals nudges again instead of failing over'
  FM_STALL_WATCH_NOW=5700 sw check n2
  assert_contains "$OUT" 'action=failover-switched' 'a fresh nudge followed by idle fails over'

  grok_says api_error 0.9
  for rc in 1 1s 3 6 9; do
    id="fo-$rc"
    make_worker "$id" api-error.screen
    sw check "$id"
    case "$rc" in
      1s) FM_TEST_FO_RC=1 FM_TEST_FO_SILENT=1 sw check "$id" ;;
      *) FM_TEST_FO_RC=$rc sw check "$id" ;;
    esac
    case "$rc" in
      1) assert_contains "$OUT" 'action=failover-none' 'exit 1 with its none line is no runtime'
         assert_contains "$(cat "$LAB/state/stall-watch"/.report.*)" 'fo-1 looks stopped' 'the none report' ;;
      1s) assert_contains "$OUT" 'action=failover-failed' 'exit 1 without a none line is a failure'
          assert_contains "$(cat "$LAB/state/stall-watch"/.report.*)" 'automatic failover failed (exit 1)' 'the failure names the exit' ;;
      3) assert_contains "$OUT" 'action=failover-bound' 'exit 3 is the attempt bound' ;;
      6) assert_contains "$OUT" 'action=failover-not-needed' 'exit 6 needs no failover'
         sw check "$id"
         assert_contains "$OUT" 'already-handled' 'a not-needed failover is not retried on the same screen' ;;
      9) assert_contains "$OUT" 'action=failover-failed' 'any other exit is a failure'
         assert_contains "$(cat "$LAB/state/stall-watch"/.report.*)" 'automatic failover failed (exit 9)' 'the failure names exit 9' ;;
    esac
  done

  fm_write_meta "$LAB/state/sm.meta" "window=fm:fm-sm" kind=secondmate harness=claude backend=tmux
  sw check sm --dry-run
  assert_equals 0 "$(ledger_rows sm)" 'a dry run of a skipped target writes no row'
  sw check sm
  assert_contains "$OUT" 'verdict=not-a-worker' 'a secondmate is not checked'
  assert_equals 1 "$(ledger_rows sm)" 'a skipped non-worker still gets its ledger row'
  make_worker rm1 stalled.screen
  printf 'remote_host=h1\n' >> "$LAB/state/rm1.meta"
  sw check rm1
  assert_contains "$OUT" 'verdict=remote' 'a remote task is not checked'
  assert_equals 1 "$(ledger_rows rm1)" 'a skipped remote task still gets its ledger row'
  make_worker cf1 stalled.screen
  rm -f "$LAB/screens/cf1.screen"
  sw check cf1
  expect_code 1 "$RC" 'an unreadable screen exits 1'
  assert_contains "$OUT" 'verdict=capture-failed stalled=unsure' 'capture failure'
  assert_equals 1 "$(ledger_rows cf1)" 'a capture failure gets its ledger row'
  pass 'decisions: auth and crashed escalate, model refusals fail over, nudges expire, every failover exit maps, skipped targets are recorded'
}

fm_test_run \
  test_screen_redacts_secrets_and_paths \
  test_deterministic_pass_skips_the_model \
  test_rendered_activity_is_not_a_rule \
  test_decided_scenarios \
  test_model_judge_maps_answers \
  test_classifier_never_sees_secrets \
  test_unchanged_screen_guard \
  test_actions \
  test_captain_actions \
  test_declared_status_reads_the_raw_verb \
  test_nudge_ends_with_work \
  test_refusal_after_ordinary_stop_is_judged \
  test_tick_schedule \
  test_watcher_starts_tick_and_delivers_reports
