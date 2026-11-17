#!/usr/bin/env bash
# Behavior tests for bin/fm-quota-guard.sh: every supervisor pool is read and
# judged against the window, stale quota is unknown, workers are moved off a
# short supervisor pool, a short or exhausted supervisor gets a failover pick, limit
# dialogs are recorded, and tick runs at kickoff and periodically.
#
# A fake quota-axi answers a --provider claude read from $CASE/claude.json and
# any other read from $CASE/main.json, and logs its arguments and the Claude
# account environment of every read. A fake tmux reports the pane ids listed
# in $CASE/panes as live.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-quota-guard)
TOOL="$ROOT/bin/fm-quota-guard.sh"
NOW=1700000000

# new_case <name> -> sets CASE HOME_DIR FAKEBIN
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  FAKEBIN="$CASE/fakebin"
  mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data" "$FAKEBIN" "$CASE/user-home/.claude"
  : > "$CASE/panes"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
printf 'profiles=%s config=%s snapshot=%s args=%s\n' "\${QUOTA_AXI_CLAUDE_PROFILES-unset}" "\${CLAUDE_CONFIG_DIR-unset}" "\${QUOTA_AXI_SNAPSHOT-unset}" "\$*" >> '$CASE/reads'
case " \$* " in
  *" --provider claude "*) cat '$CASE/claude.json' ;;
  *) cat '$CASE/main.json' ;;
esac
SH
  cat > "$FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
case "\$1" in
  list-panes) cat '$CASE/panes' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$FAKEBIN/quota-axi" "$FAKEBIN/tmux"
  printf '{"schemaVersion":5,"providers":[]}\n' > "$CASE/main.json"
  printf '{"schemaVersion":6,"providers":[]}\n' > "$CASE/claude.json"
  # The primary is a supervisor only while its session-lock holder is live.
  printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
}

# scope <runway-status> [usableRunwaySeconds]: one known all_models row.
scope() {
  jq -cn --arg runway "$1" --arg seconds "${2:-}" '{
    scope: "all_models", status: "known", effectivePercentRemaining: 40,
    runway: ({status: $runway} + (if $seconds == "" then {} else {usableRunwaySeconds: ($seconds | tonumber), projectionConfidence: "established"} end))
  }'
}

# provider_row <provider> <scope-json> [stale]: one provider row.
provider_row() {
  jq -cn --arg p "$1" --argjson s "$2" --arg stale "${3:-}" '{
    provider: $p,
    state: (if $stale == "" then {status: "fresh", stale: false} else {status: "fresh", stale: true, error: "last read failed"} end),
    quotaSemantics: {status: "known", effectiveAvailability: [$s]}
  }'
}

# claude_row <key> <root> <scope-json> [stale]: one Claude account lane.
claude_row() {
  provider_row claude "$3" "${4:-}" | jq -c --arg k "$1" --arg r "$2" '. + {accountKey: $k, accountLocator: {path: $r}}'
}

# snapshot <file> <schema> <row-json>...
snapshot() {
  local file=$1 schema=$2
  shift 2
  printf '%s\n' "$@" | jq -s --argjson v "$schema" '{schemaVersion: $v, providers: .}' > "$file"
}

run_tool() {
  env -i HOME="$CASE/user-home" PATH="$FAKEBIN:$PATH" TZ=UTC FM_HOME="$HOME_DIR" \
    FM_TEST_SEAM=1 FM_NOW="${RUN_NOW:-$NOW}" "$TOOL" "$@" 2>&1
}

# register_mate <id> <harness> [account]: a registered second mate whose
# record lives in this home.
register_mate() {
  local id=$1 home="$CASE/$1-home"
  mkdir -p "$home/state" "$home/config"
  printf -- '- %s - test scope (home: %s; projects: alpha)\n' "$id" "$home" >> "$HOME_DIR/data/secondmates.md"
  fm_write_secondmate_meta "$HOME_DIR/state/$id.meta" "$home" "" alpha "$2"
  [ -z "${3:-}" ] || printf 'account=%s\n' "$3" >> "$HOME_DIR/state/$id.meta"
}

# worker <dir> <id> <harness> <model> <pane> [account]
worker() {
  local dir=$1 id=$2
  fm_write_meta "$dir/$id.meta" "window=$5" "harness=$3" "model=$4" "kind=ship" "worktree=$CASE/wt-$id"
  [ -z "${6:-}" ] || printf 'account=%s\n' "$6" >> "$dir/$id.meta"
}

test_stale_quota_is_unknown_not_headroom() {
  local out rc
  new_case stale
  snapshot "$CASE/claude.json" 6 "$(claude_row ordinary "$CASE/user-home/.claude" "$(scope through_reset)" stale)"
  out=$(run_tool check --primary-harness claude --window-secs 28800); rc=$?
  expect_code 0 "$rc" "an unknown pool is not an act verdict: $out"
  assert_contains "$out" "quota-guard: unknown trigger=manual window=28800s pools=1 ok=0 unknown=1 short=0 exhausted=0 steer=0 failover=0" \
    "stale data must count as unknown, never ok"
  assert_contains "$out" "pool: claude:ordinary status=unknown runway=- supervisors=primary workers=- why=stale quota data (last read failed)" \
    "the pool line must name the stale read"
  assert_grep "args=--provider claude --json --full --no-credential-refresh" "$CASE/reads" \
    "Claude accounts are read with no credential refresh"
  assert_no_grep "allow-keychain-prompt" "$CASE/reads" "the guard never asks for a keychain prompt"
  assert_equals "$out" "$(cat "$HOME_DIR/state/quota-guard/report.txt")" "the report file holds the full output"
  pass "stale quota data reads as unknown, not as headroom"
}

test_short_supervisor_pool_steers_its_workers_and_fails_over() {
  local out rc
  new_case short
  snapshot "$CASE/main.json" 5 \
    "$(provider_row codex "$(scope projected_exhaustion 3600)")" \
    "$(provider_row claude "$(scope through_reset)")"
  snapshot "$CASE/claude.json" 6 "$(claude_row ordinary "$CASE/user-home/.claude" "$(scope through_reset)")"
  printf '%%1\n%%2\n' > "$CASE/panes"
  worker "$HOME_DIR/state" alive codex gpt-5.4 %1
  worker "$HOME_DIR/state" gone codex gpt-5.4 %9
  worker "$HOME_DIR/state" other claude default %2
  out=$(run_tool check --primary-harness codex --window-secs 28800 --candidate claude:opus); rc=$?
  expect_code 3 "$rc" "a short supervisor pool with a worker on it needs a move: $out"
  assert_contains "$out" "quota-guard: act trigger=manual window=28800s pools=1 ok=0 unknown=0 short=1 exhausted=0 steer=1 failover=1" \
    "only the supervisor pool is judged, one worker is moved, and the supervisor fails over"
  assert_contains "$out" "pool: codex:codex-home status=short runway=3600 supervisors=primary workers=alive why=all_models runs out in 3600s, inside the 28800s window" \
    "the pool names its runway and members"
  assert_contains "$out" "steer: alive pool=codex:codex-home pick=claude opus why=keep short pool for its supervisors" \
    "the live worker on the short pool is steered to the candidate"
  assert_not_contains "$out" "steer: gone" "a worker with no live endpoint is not moved"
  assert_not_contains "$out" "other" "a worker on a pool no supervisor uses gets no move or pool line"
  assert_contains "$out" "failover: primary pool=codex:codex-home pick=claude opus why=supervisor pool short" \
    "a short supervisor pool fails its supervisor over before the pool runs out"
  pass "a short supervisor pool moves its live workers off and fails its supervisor over"
}

test_exhausted_supervisor_fails_over_to_another_account() {
  local out rc before
  new_case exhausted
  register_mate zenith-mate claude "$CASE/acct-b"
  snapshot "$CASE/claude.json" 6 \
    "$(claude_row ordinary "$CASE/user-home/.claude" "$(scope exhausted_now)")" \
    "$(claude_row acct-b "$CASE/acct-b" "$(scope through_reset)")"
  printf 'ordinary\n%s\n' "$CASE/acct-b" > "$HOME_DIR/config/claude-accounts"
  printf 'ordinary\n' > "$HOME_DIR/config/claude-account"
  printf '%%1\n' > "$CASE/panes"
  worker "$HOME_DIR/state" busy claude default %1
  before=$(cd "$HOME_DIR/config" && ls -l)
  out=$(run_tool check --primary-harness claude --window-secs 28800); rc=$?
  expect_code 3 "$rc" "an exhausted supervisor pool needs a move: $out"
  assert_contains "$out" "quota-guard: act trigger=manual window=28800s pools=2 ok=1 unknown=0 short=0 exhausted=1 steer=1 failover=1" \
    "both Claude pools are judged"
  assert_contains "$out" "pool: claude:ordinary status=exhausted runway=0 supervisors=primary workers=busy why=all_models exhausted now" \
    "the exhausted pool names its supervisor and worker"
  assert_contains "$out" "pool: claude:$CASE/acct-b status=ok runway=through_reset supervisors=zenith-mate workers=- why=every scope runs through its reset" \
    "the second mate's own account is its own pool"
  assert_contains "$out" "steer: busy pool=claude:ordinary pick=account $CASE/acct-b why=keep exhausted pool for its supervisors" \
    "the worker moves to the account with headroom"
  assert_contains "$out" "failover: primary pool=claude:ordinary pick=account $CASE/acct-b why=supervisor pool exhausted" \
    "the supervisor fails over to another signed-in account first"
  assert_equals 1 "$(grep -c -- '--provider claude' "$CASE/reads")" "every Claude account is read in one call"
  assert_grep "profiles=$CASE/acct-b config=unset snapshot=unset" "$CASE/reads" \
    "the Claude read names the account roots and sheds the inherited account"
  assert_equals "ordinary" "$(cat "$HOME_DIR/config/claude-account")" "the account pin is never changed"
  assert_equals "$before" "$(cd "$HOME_DIR/config" && ls -l)" "the guard writes nothing under config"
  pass "an exhausted supervisor pool fails over to another signed-in account with headroom"
}

test_exhausted_supervisor_with_no_way_out_names_none() {
  local out rc
  new_case none
  snapshot "$CASE/claude.json" 6 "$(claude_row ordinary "$CASE/user-home/.claude" "$(scope exhausted_now)")"
  out=$(run_tool check --primary-harness claude --window-secs 28800); rc=$?
  expect_code 3 "$rc" "an exhausted supervisor still needs the failover path: $out"
  assert_contains "$out" "failover: primary pool=claude:ordinary pick=none (no reroute candidate off this pool) why=supervisor pool exhausted" \
    "with no account and no candidate the pick is none"
  pass "an exhausted supervisor with no account or candidate names no pick"
}

test_stale_candidate_is_not_a_failover_pick() {
  local out rc
  new_case stale-candidate
  snapshot "$CASE/claude.json" 6 "$(claude_row ordinary "$CASE/user-home/.claude" "$(scope exhausted_now)")"
  snapshot "$CASE/main.json" 5 "$(provider_row codex "$(scope through_reset)" stale)"
  out=$(run_tool check --primary-harness claude --window-secs 28800 --candidate codex:gpt-5.4); rc=$?
  expect_code 3 "$rc" "an exhausted supervisor still needs the failover path: $out"
  assert_contains "$out" "failover: primary pool=claude:ordinary pick=none (no reroute candidate off this pool) why=supervisor pool exhausted" \
    "a candidate whose quota is stale is not headroom"
  snapshot "$CASE/main.json" 5 "$(provider_row codex "$(scope through_reset)")"
  out=$(run_tool check --primary-harness claude --window-secs 28800 --candidate codex:gpt-5.4)
  assert_contains "$out" "failover: primary pool=claude:ordinary pick=codex gpt-5.4 why=supervisor pool exhausted" \
    "the same candidate with a fresh read is the pick"
  pass "a stale candidate is never named as a failover pick"
}

test_second_mate_picks_follow_its_own_pin_and_home() {
  local out mate_home
  new_case mate-picks
  register_mate zenith-mate claude
  mate_home="$CASE/zenith-mate-home"
  snapshot "$CASE/claude.json" 6 \
    "$(claude_row ordinary "$CASE/user-home/.claude" "$(scope exhausted_now)")" \
    "$(claude_row acct-b "$CASE/acct-b" "$(scope through_reset)")" \
    "$(claude_row acct-c "$CASE/acct-c" "$(scope through_reset)")"
  snapshot "$CASE/main.json" 5 "$(provider_row codex "$(scope through_reset)")"
  printf 'ordinary\n%s\n' "$CASE/acct-b" > "$HOME_DIR/config/claude-accounts"
  printf 'ordinary\n%s\n' "$CASE/acct-c" > "$mate_home/config/claude-accounts"
  printf '%%1\n' > "$CASE/panes"
  worker "$mate_home/state" child claude default %1
  out=$(run_tool check --primary-harness codex --window-secs 28800 --candidate codex:gpt-5.4)
  assert_contains "$out" "failover: zenith-mate pool=claude:ordinary pick=codex gpt-5.4 why=supervisor pool exhausted" \
    "a second mate relaunches on its own pin, so its failover is a model pick, not an account"
  assert_contains "$out" "steer: zenith-mate/child pool=claude:ordinary pick=account $CASE/acct-c why=keep exhausted pool for its supervisors" \
    "a mate's worker moves to an account its own home declares"
  assert_not_contains "$out" "pick=account $CASE/acct-b" "no move names an account its home cannot launch"
  pass "a second mate gets a model failover and its worker an account from the mate's home"
}
test_claude_candidate_lands_on_the_relaunching_pin() {
  local out
  new_case candidate-pin
  register_mate zenith-mate codex
  mkdir -p "$CASE/acct-b" "$HOME_DIR/config/secondmate-accounts/zenith-mate"
  snapshot "$CASE/main.json" 5 \
    "$(provider_row codex "$(scope exhausted_now)")" \
    "$(provider_row claude "$(scope through_reset)")"
  snapshot "$CASE/claude.json" 6 \
    "$(claude_row ordinary "$CASE/user-home/.claude" "$(scope through_reset)")" \
    "$(claude_row acct-b "$CASE/acct-b" "$(scope exhausted_now)")"
  printf 'ordinary\n' > "$HOME_DIR/config/claude-account"
  printf '%s\n' "$CASE/acct-b" > "$HOME_DIR/config/secondmate-accounts/zenith-mate/claude-account"
  out=$(run_tool check --primary-harness codex --window-secs 28800 --candidate claude:opus)
  assert_contains "$out" "failover: primary pool=codex:codex-home pick=claude opus why=supervisor pool exhausted" \
    "the primary relaunches on the ordinary pin, which has headroom"
  assert_contains "$out" "failover: zenith-mate pool=codex:codex-home pick=none (no reroute candidate off this pool) why=supervisor pool exhausted" \
    "the mate relaunches on its own exhausted pin, so Claude is no way out for it"
  assert_grep "profiles=$CASE/acct-b " "$CASE/reads" "the mate's pin is read even though nothing runs on it yet"
  printf '%s\n' "$CASE/acct-b" > "$HOME_DIR/config/claude-account"
  rm -rf "$HOME_DIR/config/secondmate-accounts"
  out=$(run_tool check --primary-harness codex --window-secs 28800 --candidate claude:opus)
  assert_contains "$out" "failover: primary pool=codex:codex-home pick=none (no reroute candidate off this pool) why=supervisor pool exhausted" \
    "a home pin on an exhausted account rules Claude out for the primary"
  pass "a Claude candidate is judged on the account its relaunch would land on"
}

test_unrecorded_model_with_a_short_model_scope_is_unknown() {
  local out row
  new_case hidden-model
  row=$(claude_row ordinary "$CASE/user-home/.claude" "$(scope through_reset)" |
    jq -c '.quotaSemantics.effectiveAvailability += [{scope: "model:opus", status: "known", effectivePercentRemaining: 0, runway: {status: "exhausted_now"}}]')
  snapshot "$CASE/claude.json" 6 "$row"
  out=$(run_tool check --primary-harness claude --window-secs 28800)
  assert_contains "$out" "pool: claude:ordinary status=unknown runway=- supervisors=primary workers=- why=model not recorded, and model:opus is short, exhausted, or unmeasured" \
    "a supervisor with no recorded model may be on the exhausted model"
  row=$(claude_row ordinary "$CASE/user-home/.claude" "$(scope through_reset)" |
    jq -c '.quotaSemantics.effectiveAvailability += [{scope: "model:opus", status: "known", effectivePercentRemaining: 90, runway: {status: "through_reset"}}]')
  snapshot "$CASE/claude.json" 6 "$row"
  out=$(run_tool check --primary-harness claude --window-secs 28800)
  assert_contains "$out" "pool: claude:ordinary status=ok" "a model scope with headroom leaves the pool ok"
  row=$(claude_row ordinary "$CASE/user-home/.claude" "$(scope through_reset)" |
    jq -c '.quotaSemantics.effectiveAvailability += [{scope: "model:opus", status: "unknown", runway: {status: "unknown"}}]')
  snapshot "$CASE/claude.json" 6 "$row"
  out=$(run_tool check --primary-harness claude --window-secs 28800)
  assert_contains "$out" "pool: claude:ordinary status=unknown runway=- supervisors=primary workers=- why=model not recorded, and model:opus is short, exhausted, or unmeasured" \
    "a supervisor with no recorded model may be on a model whose headroom is unknown"
  row=$(claude_row ordinary "$CASE/user-home/.claude" "$(scope through_reset)" |
    jq -c '.quotaSemantics.effectiveAvailability += [{scope: "product:claude_code", status: "known", effectivePercentRemaining: 50, runway: {status: "unknown"}}]')
  snapshot "$CASE/claude.json" 6 "$row"
  out=$(run_tool check --primary-harness claude --window-secs 28800)
  assert_contains "$out" "why=model not recorded, and product:claude_code is short, exhausted, or unmeasured" \
    "a known scope whose runway cannot be projected is not headroom either"
  pass "an unrecorded model is unknown while any model scope is short, exhausted, or unmeasured"
}
test_account_pick_skips_a_pool_another_member_holds_short() {
  local out
  new_case account-pool
  register_mate zenith-mate claude "$CASE/acct-b"
  printf 'model=opus\n' >> "$HOME_DIR/state/zenith-mate.meta"
  mkdir -p "$CASE/acct-b"
  snapshot "$CASE/claude.json" 6 \
    "$(claude_row ordinary "$CASE/user-home/.claude" "$(scope exhausted_now)")" \
    "$(claude_row acct-b "$CASE/acct-b" "$(scope through_reset)" |
      jq -c '.quotaSemantics.effectiveAvailability += [{scope: "model:opus", status: "known", effectivePercentRemaining: 0, runway: {status: "exhausted_now"}}]')"
  printf 'ordinary\n%s\n' "$CASE/acct-b" > "$HOME_DIR/config/claude-accounts"
  printf '%%1\n' > "$CASE/panes"
  worker "$HOME_DIR/state" busy claude sonnet %1
  out=$(run_tool check --primary-harness claude --window-secs 28800)
  assert_contains "$out" "pool: claude:$CASE/acct-b status=exhausted runway=0 supervisors=zenith-mate workers=- why=model:opus exhausted now" \
    "the second mate's model leaves its account's pool exhausted"
  assert_contains "$out" "steer: busy pool=claude:ordinary pick=none (no reroute candidate off this pool) why=keep exhausted pool for its supervisors" \
    "a worker is not moved onto a pool a supervisor already finds exhausted"
  sed 's/^model=opus$/model=sonnet/' "$HOME_DIR/state/zenith-mate.meta" > "$CASE/meta" && mv "$CASE/meta" "$HOME_DIR/state/zenith-mate.meta"
  out=$(run_tool check --primary-harness claude --window-secs 28800)
  assert_contains "$out" "steer: busy pool=claude:ordinary pick=account $CASE/acct-b why=keep exhausted pool for its supervisors" \
    "the same account is the pick once its pool is ok"
  pass "an account pick skips a pool that another member's model leaves exhausted"
}

test_provider_prefixed_model_binds_its_model_scope() {
  local out
  new_case prefixed-model
  register_mate zenith-mate omp
  printf 'model=openai-codex/gpt-5.4\n' >> "$HOME_DIR/state/zenith-mate.meta"
  snapshot "$CASE/main.json" 5 "$(provider_row codex "$(scope through_reset)" |
    jq -c '.quotaSemantics.effectiveAvailability += [{scope: "model:gpt-5.4", status: "known", effectivePercentRemaining: 0, runway: {status: "exhausted_now"}}]')"
  out=$(run_tool check --window-secs 28800)
  assert_contains "$out" "status=exhausted runway=0 supervisors=zenith-mate workers=- why=model:gpt-5.4 exhausted now" \
    "an OMP model is judged on the scope of its bare model name"
  assert_contains "$out" "failover: zenith-mate pool=codex:" "the exhausted second mate gets the failover path"
  pass "a provider-prefixed model is judged on its own model scope"
}
test_primary_account_carries_to_a_later_check() {
  local out
  new_case primary-account
  register_mate zenith-mate claude
  mkdir -p "$CASE/acct-b"
  printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
  snapshot "$CASE/claude.json" 6 \
    "$(claude_row ordinary "$CASE/user-home/.claude" "$(scope through_reset)")" \
    "$(claude_row acct-b "$CASE/acct-b" "$(scope exhausted_now)")"
  out=$(run_tool check --primary-harness claude --primary-account "$CASE/acct-b" --window-secs 28800)
  assert_contains "$out" "pool: claude:$CASE/acct-b status=exhausted runway=0 supervisors=primary" \
    "the primary is judged on the account it was given"
  assert_grep "primary_account=$CASE/acct-b" "$HOME_DIR/state/quota-guard/last" "the check records the primary's account"
  # A second mate's warning names no primary harness or account; the check keeps
  # the last ones while the same session-lock holder is live.
  out=$(run_tool warning --subject zenith-mate --window-secs 28800)
  assert_contains "$out" "pool: claude:$CASE/acct-b status=exhausted runway=0 supervisors=primary workers=-" \
    "a later check without the account still judges the primary on it"
  assert_contains "$out" "pool: claude:ordinary status=ok runway=through_reset supervisors=zenith-mate" \
    "the second mate stays on its own account"
  run_tool record-dialog --subject primary --harness claude >/dev/null
  assert_grep "	primary	$CASE/acct-b	-	claude" "$HOME_DIR/state/quota-limit-dialogs.tsv" \
    "a primary dialog with no account named is recorded on the last known account"
  printf '%s\n' "$(sleep 0 & echo "$!")" > "$HOME_DIR/state/.lock"
  out=$(run_tool check --window-secs 28800)
  assert_not_contains "$out" "supervisors=primary" "a new lock holder that is not live carries nothing over"
  out=$(run_tool check --primary-harness claude --primary-account "$CASE/acct-b" --window-secs 28800)
  assert_not_contains "$out" "supervisors=primary" "a named harness does not make a dead primary a supervisor"
  assert_not_contains "$out" "failover: primary" "a dead primary gets no failover"
  pass "a check with no primary harness or account keeps the last ones for the same session"
}

test_codex_primary_proven_by_its_session_stays_a_supervisor() {
  local out sid=00000000-0000-4000-8000-0000000000c1 bound dead
  new_case codex-session-owner
  snapshot "$CASE/main.json" 5 "$(provider_row codex "$(scope exhausted_now)")"
  dead=$(sleep 0 & echo "$!")
  wait "$dead" 2>/dev/null
  printf '%s\n' "$dead" > "$HOME_DIR/state/.lock"
  printf '%s\n' "$sid" > "$HOME_DIR/state/.lock-session"
  # macOS hides a platform binary's environment, so the bound process is python.
  env CODEX_THREAD_ID="$sid" CODEX_SESSION_ID="$sid" python3 -c 'import time; time.sleep(120)' >/dev/null 2>&1 &
  bound=$!
  for _ in $(seq 1 20); do python3 "$ROOT/bin/fm-session-process.py" bound "$bound" "$sid" && break; sleep 0.1; done
  python3 "$ROOT/bin/fm-session-process.py" bound "$bound" "$sid" || { kill "$bound" 2>/dev/null; fail "the fixture process is not bound to session $sid"; }
  out=$(run_tool check --window-secs 28800)
  assert_contains "$out" "pool: codex:codex-home status=exhausted runway=0 supervisors=primary" \
    "a Codex primary whose lock pid exited is live through its recorded session"
  assert_contains "$out" "failover: primary pool=codex:codex-home" "the live Codex primary gets the failover path"
  run_tool check --primary-harness claude --window-secs 28800 >/dev/null
  out=$(run_tool check --window-secs 28800)
  assert_contains "$out" "supervisors=primary workers=- why=no quota lane for Claude account ordinary" \
    "a later check keeps the recorded harness while the recorded session stays live"
  kill "$bound" 2>/dev/null
  wait "$bound" 2>/dev/null
  out=$(run_tool check --window-secs 28800)
  assert_not_contains "$out" "supervisors=primary" "once no process holds the recorded session the primary is gone"
  pass "a Codex primary proven live by its recorded session stays a supervisor"
}

test_pick_skips_a_pool_a_worker_off_the_supervisor_pools_holds() {
  local out
  new_case off-pool
  mkdir -p "$CASE/acct b"
  snapshot "$CASE/claude.json" 6 \
    "$(claude_row ordinary "$CASE/user-home/.claude" "$(scope exhausted_now)")" \
    "$(claude_row acct-b "$CASE/acct b" "$(scope through_reset)" |
      jq -c '.quotaSemantics.effectiveAvailability += [{scope: "model:opus", status: "known", effectivePercentRemaining: 0, runway: {status: "exhausted_now"}}]')"
  printf 'ordinary\n%s\n' "$CASE/acct b" > "$HOME_DIR/config/claude-accounts"
  printf '%%1\n%%2\n' > "$CASE/panes"
  worker "$HOME_DIR/state" busy claude sonnet %1
  worker "$HOME_DIR/state" heavy claude opus %2 "$CASE/acct b"
  out=$(run_tool check --primary-harness claude --window-secs 28800)
  assert_grep "profiles=$CASE/acct b config=" "$CASE/reads" "an account root with a space is read as one profile"
  assert_contains "$out" "quota-guard: act trigger=manual window=28800s pools=1 " \
    "a pool only an off-pool worker runs on is not a report pool"
  assert_contains "$out" "steer: busy pool=claude:ordinary pick=none (no reroute candidate off this pool) why=keep exhausted pool for its supervisors" \
    "a worker is not moved onto an account another live worker's model leaves exhausted"
  assert_not_contains "$out" "heavy" "a worker off every supervisor pool gets no move"
  printf '%%1\n' > "$CASE/panes"
  out=$(run_tool check --primary-harness claude --window-secs 28800)
  assert_contains "$out" "steer: busy pool=claude:ordinary pick=account $CASE/acct b why=keep exhausted pool for its supervisors" \
    "the same account is the pick once no live worker holds it short"
  pass "a pick skips a pool that a worker off the supervisor pools leaves exhausted"
}
test_sole_keyless_claude_lane_is_the_ordinary_account() {
  local out rc
  new_case sole-lane
  # A read of one account is the legacy shape: schema 5, no key, no locator.
  snapshot "$CASE/claude.json" 5 "$(provider_row claude "$(scope exhausted_now)")"
  out=$(run_tool check --primary-harness claude --window-secs 28800); rc=$?
  expect_code 3 "$rc" "an exhausted sole lane needs a move: $out"
  assert_contains "$out" "pool: claude:ordinary status=exhausted runway=0 supervisors=primary workers=- why=all_models exhausted now" \
    "a sole lane with no locator is the ordinary account's own row"
  assert_contains "$out" "failover: primary pool=claude:ordinary" "the exhausted primary gets the failover path"
  out=$(run_tool check --primary-harness claude --primary-account "$CASE/acct-b" --window-secs 28800)
  assert_contains "$out" "pool: claude:$CASE/acct-b status=unknown runway=- supervisors=primary workers=- why=no quota lane for Claude account $CASE/acct-b" \
    "another account never binds the keyless lane"
  printf 'ordinary\n%s\n' "$CASE/acct-b" > "$HOME_DIR/config/claude-accounts"
  out=$(run_tool check --primary-harness claude --primary-account ordinary --window-secs 28800)
  assert_contains "$out" "pool: claude:ordinary status=unknown runway=- supervisors=primary workers=- why=no quota lane for Claude account ordinary" \
    "a read that names another root binds no keyless lane, even to the ordinary account"
  pass "a sole Claude lane with no locator is the ordinary account"
}
test_listed_home_claude_candidate_names_its_account() {
  local out
  new_case listed-candidate
  mkdir -p "$CASE/acct-b"
  snapshot "$CASE/main.json" 5 \
    "$(provider_row codex "$(scope projected_exhaustion 3600)")" \
    "$(provider_row claude "$(scope through_reset)")"
  snapshot "$CASE/claude.json" 6 \
    "$(claude_row ordinary "$CASE/user-home/.claude" "$(scope exhausted_now)")" \
    "$(claude_row acct-b "$CASE/acct-b" "$(scope through_reset)")"
  printf 'ordinary\n%s\n' "$CASE/acct-b" > "$HOME_DIR/config/claude-accounts"
  printf '%%1\n' > "$CASE/panes"
  worker "$HOME_DIR/state" alive codex gpt-5.4 %1
  out=$(run_tool check --primary-harness codex --window-secs 28800 --candidate claude:opus)
  assert_contains "$out" "steer: alive pool=codex:codex-home pick=claude opus account $CASE/acct-b why=keep short pool for its supervisors" \
    "under a declared account list a Claude candidate names the declared account with headroom"
  # The provider-wide read reports the ordinary account, which is exhausted;
  # the chooser must judge the candidate on the declared account it lands on.
  snapshot "$CASE/main.json" 5 \
    "$(provider_row codex "$(scope projected_exhaustion 3600)")" \
    "$(provider_row claude "$(scope exhausted_now)")"
  out=$(run_tool check --primary-harness codex --window-secs 28800 --candidate claude:opus)
  assert_contains "$out" "steer: alive pool=codex:codex-home pick=claude opus account $CASE/acct-b why=keep short pool for its supervisors" \
    "an exhausted ordinary account in the provider-wide read does not reject the declared account"
  snapshot "$CASE/main.json" 6 \
    "$(provider_row codex "$(scope projected_exhaustion 3600)" | jq -c '. + {accountKey: "codex-home"}')" \
    "$(provider_row claude "$(scope exhausted_now)" | jq -c '. + {accountKey: "default"}')"
  out=$(run_tool check --primary-harness codex --window-secs 28800 --candidate claude:opus)
  assert_contains "$out" "steer: alive pool=codex:codex-home pick=claude opus account $CASE/acct-b why=keep short pool for its supervisors" \
    "a keyed provider-wide read is judged on the declared account too"
  pass "a Claude candidate in a home with an account list names its account"
}
test_lock_change_during_a_check_is_a_kickoff_that_carries_nothing() {
  local out newpid
  new_case lock-swap
  mkdir -p "$CASE/acct-b"
  snapshot "$CASE/claude.json" 6 \
    "$(claude_row ordinary "$CASE/user-home/.claude" "$(scope through_reset)")" \
    "$(claude_row acct-b "$CASE/acct-b" "$(scope through_reset)")"
  sleep 120 &
  newpid=$!
  # The first read stands in for a primary restart that lands mid-check.
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
[ -e '$CASE/swapped' ] || { : > '$CASE/swapped'; printf '%s\n' '$newpid' > '$HOME_DIR/state/.lock'; }
case " \$* " in
  *" --provider claude "*) cat '$CASE/claude.json' ;;
  *) cat '$CASE/main.json' ;;
esac
SH
  run_tool check --primary-harness claude --primary-account "$CASE/acct-b" --window-secs 28800 >/dev/null
  assert_grep "primary_lock=$$" "$HOME_DIR/state/quota-guard/last" \
    "the check records the lock owner it judged, not the one that took over mid-check"
  out=$(run_tool tick --window-secs 28800)
  assert_contains "$out" "trigger=kickoff" "the new session's first tick is a kickoff"
  assert_not_contains "$out" "claude:$CASE/acct-b" "the new session inherits no account from the old one"
  kill "$newpid" 2>/dev/null
  wait "$newpid" 2>/dev/null
  pass "a lock change during a check makes the next tick a kickoff that carries nothing over"
}

test_pi_member_pinned_to_its_own_root_is_its_own_pool() {
  local out
  new_case pi-root
  mkdir -p "$CASE/pi-b"
  snapshot "$CASE/main.json" 5 \
    "$(provider_row codex "$(scope exhausted_now)")" \
    "$(provider_row pi "$(scope through_reset)")"
  register_mate zenith-mate pi "$CASE/pi-b"
  register_mate casco-mate pi
  printf 'model=openai-codex/gpt-5.4\n' >> "$HOME_DIR/state/zenith-mate.meta"
  printf 'model=openai-codex/gpt-5.4\n' >> "$HOME_DIR/state/casco-mate.meta"
  out=$(run_tool check --primary-harness codex --window-secs 28800 --candidate pi:openai-codex/gpt-5.4)
  assert_contains "$out" "pool: pi:pi-root:$CASE/pi-b status=unknown runway=- supervisors=zenith-mate workers=- why=no quota read scoped to Pi root $CASE/pi-b" \
    "a Pi member pinned to another root never takes the ambient read's verdict"
  assert_contains "$out" "pool: pi:openai-codex status=ok runway=through_reset supervisors=casco-mate workers=-" \
    "an unpinned Pi member is judged on the ambient read"
  assert_contains "$out" "failover: primary pool=codex:codex-home pick=pi openai-codex/gpt-5.4" \
    "a Pi candidate with no pin lands on the ambient root, which has headroom"
  printf '%s\nopenai-codex\n' "$CASE/pi-b" > "$HOME_DIR/config/pi-account"
  out=$(run_tool check --primary-harness codex --window-secs 28800 --candidate pi:openai-codex/gpt-5.4)
  assert_contains "$out" "failover: primary pool=codex:codex-home pick=none (no reroute candidate off this pool) why=supervisor pool exhausted" \
    "a Pi candidate relaunched on a pinned root has no read of its own, so it is no pick"
  pass "a Pi member pinned to its own root is judged as its own unknown pool"
}

test_limit_dialogs_are_recorded_with_account_and_model() {
  local rows rc
  new_case dialogs
  register_mate casco-mate claude
  register_mate dorado-mate claude
  worker "$HOME_DIR/state" task1 claude opus %1 "$CASE/acct-b"
  worker "$CASE/casco-mate-home/state" child codex gpt-5.4 %2
  worker "$CASE/dorado-mate-home/state" child claude sonnet %3 "$CASE/acct-d"
  run_tool record-dialog --subject task1 >/dev/null; rc=$?
  expect_code 0 "$rc" "a task's dialog is recorded"
  run_tool record-dialog --subject primary --harness claude >/dev/null
  run_tool record-dialog --subject casco-mate/child >/dev/null
  run_tool record-dialog --subject dorado-mate/child >/dev/null
  run_tool record-dialog --subject casco-mate >/dev/null
  rows=$(cat "$HOME_DIR/state/quota-limit-dialogs.tsv")
  assert_contains "$rows" "$NOW	task1	$CASE/acct-b	opus	claude" "the task's account and model come from its record"
  assert_contains "$rows" "$NOW	primary	ordinary	-	claude" "the primary's Claude account defaults to ordinary"
  assert_contains "$rows" "$NOW	casco-mate/child	codex-home	gpt-5.4	codex" "a second mate's worker is found in that mate's home"
  assert_contains "$rows" "$NOW	dorado-mate/child	$CASE/acct-d	sonnet	claude" "the same task id in another mate's home is that mate's worker"
  assert_contains "$rows" "$NOW	casco-mate	ordinary	-	claude" "a second mate's own dialog uses its record here"
  run_tool record-dialog --subject 'bad id' >/dev/null; rc=$?
  expect_code 2 "$rc" "a malformed subject is refused"
  assert_absent "$HOME_DIR/state/quota-guard" "recording a dialog does not run a check"
  pass "each limit dialog is recorded with its account and model"
}

test_warning_records_then_checks() {
  local out rc
  new_case warning
  snapshot "$CASE/claude.json" 6 "$(claude_row ordinary "$CASE/user-home/.claude" "$(scope through_reset)")"
  out=$(run_tool warning --subject primary --harness claude --primary-harness claude --window-secs 600); rc=$?
  expect_code 0 "$rc" "a warning with headroom is ok: $out"
  assert_contains "$out" "quota-guard: ok trigger=warning window=600s pools=1 ok=1" "a warning checks at once"
  assert_grep "primary	ordinary	-	claude" "$HOME_DIR/state/quota-limit-dialogs.tsv" "a warning also records the dialog"
  pass "a limit warning records the dialog and checks quota"
}

test_tick_runs_at_kickoff_and_periodically() {
  local out rows
  new_case tick
  snapshot "$CASE/claude.json" 6 "$(claude_row ordinary "$CASE/user-home/.claude" "$(scope through_reset)")"
  out=$(run_tool tick --primary-harness claude --window-secs 600)
  assert_contains "$out" "quota-guard: ok trigger=kickoff" "the first tick is a kickoff check"
  out=$(RUN_NOW=$((NOW + 60)) run_tool tick --primary-harness claude --window-secs 600)
  assert_equals "" "$out" "a tick before the period prints nothing"
  out=$(RUN_NOW=$((NOW + 7200)) run_tool tick --primary-harness claude --window-secs 600)
  assert_contains "$out" "quota-guard: ok trigger=periodic" "a tick after two hours is a periodic check"
  printf '%s\n' "$PPID" > "$HOME_DIR/state/.lock"
  out=$(RUN_NOW=$((NOW + 7300)) run_tool tick --primary-harness claude --window-secs 600)
  assert_contains "$out" "quota-guard: ok trigger=kickoff" "a new session-lock holder is a kickoff"
  printf 'quota-guard-every-secs=60\n' > "$HOME_DIR/config/watchdog"
  out=$(RUN_NOW=$((NOW + 7400)) run_tool tick --primary-harness claude --window-secs 600)
  assert_contains "$out" "quota-guard: ok trigger=periodic" "the period comes from config"
  rows=$(cut -f 2 "$HOME_DIR/state/quota-guard/checks.tsv" | tr '\n' ' ')
  assert_equals "kickoff periodic kickoff periodic " "$rows" "every check is logged with its trigger"
  pass "tick checks at kickoff and every period, and stays quiet between"
}

test_window_defaults_to_the_morning() {
  local out
  new_case window
  snapshot "$CASE/claude.json" 6 "$(claude_row ordinary "$CASE/user-home/.claude" "$(scope projected_exhaustion 30000)")"
  out=$(run_tool check --primary-harness claude)
  assert_contains "$out" "quota-guard: act trigger=manual window=35200s pools=1 ok=0 unknown=0 short=1" \
    "the window runs to 08:00 local time, so a 30000s runway is short"
  printf 'quota-guard-window-secs=1800\n' > "$HOME_DIR/config/watchdog"
  out=$(run_tool check --primary-harness claude)
  assert_contains "$out" "quota-guard: ok trigger=manual window=1800s" "a configured window wins"
  pass "the window defaults to the next morning and follows config"
}

test_no_quota_axi_is_unknown() {
  local out rc
  new_case missing
  rm -f "$FAKEBIN/quota-axi"
  out=$(env -i HOME="$CASE/user-home" PATH="$FAKEBIN:/usr/bin:/bin" FM_HOME="$HOME_DIR" \
    "$TOOL" check --primary-harness claude --window-secs 600 2>&1); rc=$?
  expect_code 0 "$rc" "a missing quota-axi is unknown, not a failure: $out"
  assert_contains "$out" "pool: claude:ordinary status=unknown runway=- supervisors=primary workers=- why=quota-axi not installed" \
    "the missing tool is named"
  pass "a missing quota-axi reads as unknown"
}


# The lightweight check uses the production harness resolver with its supported
# supervision-primary pin, so it never depends on this test runner ancestry.
run_snapshot_check() {
  env -i HOME="$CASE/user-home" PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    FM_SUPERVISION_ACTOR=branch FM_SUPERVISION_PRIMARY_HARNESS=codex \
    FM_TEST_SEAM=1 FM_NOW="$NOW" "$TOOL" check "$@"
}

toon_snapshot() {  # <runway> <percent> [seconds]
  cat > "$CASE/quota.toon" <<EOF
bin: quota-axi
generatedAt: 2026-11-16T00:00:00Z
quota[1]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  codex,all_models,$2,0.5,$1,established,weekly,unknown
EOF
  if [ -n "${3:-}" ]; then
    cat >> "$CASE/quota.toon" <<EOF
exhaustion[1]{provider,scope,usableRunwaySeconds,projectedExhaustedAt,limitingWindowId}:
  codex,all_models,$3,unknown,weekly
EOF
  else
    printf 'exhaustion[0]:\n' >> "$CASE/quota.toon"
  fi
  printf 'attention[0]:\n' >> "$CASE/quota.toon"
}

check_verdict() {  # <expected> [options]
  local expected=$1 out
  shift
  out=$(run_snapshot_check --snapshot "$CASE/quota.toon" --json "$@") || fail "check failed: $out"
  printf '%s\n' "$out" | jq -e --arg v "$expected" \
    '.pools | length == 1 and all(.[]; .verdict == $v)' >/dev/null || fail "expected $expected: $out"
}

test_snapshot_horizon_and_exhaustion() {
  new_case toon-horizon
  toon_snapshot through_reset 40
  check_verdict HEALTHY
  toon_snapshot projected_exhaustion 40 35999
  check_verdict TIGHT_HORIZON
  check_verdict HEALTHY --horizon-secs 35999
  toon_snapshot projected_exhaustion 40 36000
  check_verdict HEALTHY
  toon_snapshot exhausted_now 5 0
  check_verdict EXHAUSTED
  toon_snapshot through_reset 0
  check_verdict EXHAUSTED
  toon_snapshot through_reset 40 0
  check_verdict EXHAUSTED
  toon_snapshot projected_exhaustion 40 unknown
  check_verdict unknown
  [ ! -e "$CASE/reads" ] || fail "--snapshot called quota-axi"
  pass "TOON check classifies reset, exact horizon, zero percent, zero runway and unknown time"
}

test_snapshot_attention_and_missing_data() {
  local kind out
  new_case toon-attention
  for kind in stale error auth_required; do
    toon_snapshot through_reset 40
    sed '$d' "$CASE/quota.toon" > "$CASE/attention.toon"
    cat >> "$CASE/attention.toon" <<EOF
attention[1]{provider,scope,kind,detail,remedy}:
  codex,all_models,$kind,"cached, uncertain",unknown
EOF
    out=$(run_snapshot_check --snapshot "$CASE/attention.toon" --json) || fail "attention check failed"
    printf '%s\n' "$out" | jq -e --arg k "$kind" \
      '.pools[0].verdict == "unknown" and (.pools[0].detail | contains($k)) and .alerts == ""' >/dev/null || fail "$out"
  done
  printf 'quota[0]:\nexhaustion[0]:\nattention[0]:\n' > "$CASE/quota.toon"
  check_verdict unknown
  printf 'quota[0]:\nexhaustion[0]:\nattention[1]{provider,scope,kind,detail,remedy}:\n  codex,all_models,stale,cached,unknown\n' > "$CASE/quota.toon"
  check_verdict unknown
  printf 'invalid\n' > "$CASE/quota.toon"
  check_verdict unknown
  pass "stale, error, auth attention, absent pools and malformed TOON stay unknown"
}

test_snapshot_local_members_and_config() {
  local out
  new_case toon-members
  cat > "$HOME_DIR/config/secondmate-harness" <<'EOF'
codex
mate local: claude
EOF
  printf 'kind=secondmate\nharness=\n' > "$HOME_DIR/state/local.meta"
  printf 'kind=secondmate\nharness=grok\nremote_host=other-host\n' > "$HOME_DIR/state/remote.meta"
  printf 'kind=ship\nharness=kimi\n' > "$HOME_DIR/state/worker.meta"
  printf 'kind=secondmate\nharness=kimi\n' > "$CASE/foreign.meta"
  ln -s "$CASE/foreign.meta" "$HOME_DIR/state/foreign.meta"
  cat > "$CASE/quota.toon" <<'EOF'
bin: quota-axi
generatedAt: 2026-11-16T00:00:00Z
quota[2]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  codex,all_models,40,0.5,through_reset,established,weekly,unknown
  claude,all_models,50,0.5,through_reset,established,weekly,unknown
exhaustion[0]:
attention[0]:
EOF
  out=$(run_snapshot_check --snapshot "$CASE/quota.toon" --json) || fail "member discovery failed"
  printf '%s\n' "$out" | jq -e '.pools | length == 2 and all(.[]; .verdict == "HEALTHY") and (map(.members[]) | sort == ["local","primary"])' >/dev/null || fail "$out"
  mkdir -p "$CASE/isolated-account"
  printf '%s\n' "$CASE/isolated-account" > "$HOME_DIR/config/claude-account"
  cp "$HOME_DIR/config/claude-account" "$CASE/pin.before"
  out=$(run_snapshot_check --snapshot "$CASE/quota.toon" --json) || fail "pinned discovery failed"
  printf '%s\n' "$out" | jq -e '.pools[] | select(.provider == "claude") | .verdict == "unknown"' >/dev/null || fail "$out"
  cmp -s "$CASE/pin.before" "$HOME_DIR/config/claude-account" || fail "pin changed"
  printf 'mate local: invalid extra extra extra\n' > "$HOME_DIR/config/secondmate-harness"
  if run_snapshot_check --snapshot "$CASE/quota.toon" --json > "$CASE/invalid.out" 2>&1; then
    fail "malformed secondmate config silently fell back"
  fi
  pass "discovery uses own local meta and resolver pins, skips remote, worker and symlink records"
}

test_snapshot_account_keys_and_scopes() {
  local out
  new_case toon-accounts
  cat > "$CASE/quota.toon" <<'EOF'
bin: quota-axi
generatedAt: 2026-11-16T00:00:00Z
quota[3]{provider,accountKey,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  codex,codex-home,all_models,40,0.5,through_reset,established,weekly,unknown
  codex,codex-home,model:small,5,0.1,projected_exhaustion,established,weekly,unknown
  codex,other,all_models,0,0,exhausted_now,established,weekly,unknown
exhaustion[1]{provider,accountKey,scope,usableRunwaySeconds,projectedExhaustedAt,limitingWindowId}:
  codex,codex-home,model:small,60,unknown,weekly
attention[1]{provider,accountKey,scope,kind,detail,remedy}:
  codex,other,all_models,error,unavailable,unknown
EOF
  out=$(run_snapshot_check --snapshot "$CASE/quota.toon" --json) || fail "schema 6 failed"
  printf '%s\n' "$out" | jq -e '.pools | length == 2 and all(.[]; .account == "codex-home") and (map(.verdict) | sort == ["HEALTHY","TIGHT_HORIZON"])' >/dev/null || fail "$out"
  pass "schema-6 joins stay on the selected account and retain potentially limiting model scopes"
}

test_snapshot_alert_dedup_and_rotation() {
  local out count
  new_case toon-log
  toon_snapshot projected_exhaustion 5 100
  out=$(run_snapshot_check --snapshot "$CASE/quota.toon") || fail "first alert failed"
  assert_contains "$out" TIGHT_HORIZON "first crossing alerts"
  assert_contains "$out" 'move new workers off' "recommendation preserves supervisor pool"
  out=$(run_snapshot_check --snapshot "$CASE/quota.toon") || fail "repeat failed"
  [ -z "$out" ] || fail "repeated condition alerted: $out"
  toon_snapshot exhausted_now 0 0
  out=$(run_snapshot_check --snapshot "$CASE/quota.toon") || fail "exhaustion failed"
  assert_contains "$out" EXHAUSTED "escalation alerts"
  toon_snapshot through_reset 40
  out=$(run_snapshot_check --snapshot "$CASE/quota.toon") || fail "recovery failed"
  [ -z "$out" ] || fail "healthy check printed alert"
  toon_snapshot projected_exhaustion 5 100
  out=$(run_snapshot_check --snapshot "$CASE/quota.toon") || fail "recurrence failed"
  assert_contains "$out" TIGHT_HORIZON "recovery rearms alert"
  awk 'BEGIN { for (i=0; i<1010; i++) print i "\tcodex\tall_models\tTIGHT_HORIZON\t5\tprojected_exhaustion\t100\taccount=default members=primary; " }' > "$HOME_DIR/state/quota-guard.tsv"
  out=$(run_snapshot_check --snapshot "$CASE/quota.toon") || fail "rotation failed"
  [ -z "$out" ] || fail "rotation lost dedup state"
  count=$(wc -l < "$HOME_DIR/state/quota-guard.tsv" | tr -d ' ')
  expect_code 1000 "$count" "ledger is bounded"
  awk -F '\t' -v now="$NOW" 'NF != 8 {exit 1} END {if ($1 != now) exit 1}' "$HOME_DIR/state/quota-guard.tsv" || fail "rotated TSV malformed or newest row missing"
  pass "new conditions alert once, recovery rearms, and TSV rotation keeps 1000 structured rows"
}

test_snapshot_one_live_read_and_options() {
  local out arg
  new_case toon-read
  toon_snapshot through_reset 40
  cp "$CASE/quota.toon" "$CASE/main.json"
  out=$(run_snapshot_check --json) || fail "live read failed"
  printf '%s\n' "$out" | jq -e '.horizon_secs == 36000 and .pools[0].verdict == "HEALTHY"' >/dev/null || fail "$out"
  [ "$(wc -l < "$CASE/reads" | tr -d ' ')" = 1 ] || fail "more than one quota read"
  assert_contains "$(cat "$CASE/reads")" 'args=--no-credential-refresh' "default TOON read never refreshes credentials"
  for arg in 0 -1 text 01 1000000000; do
    if run_snapshot_check --horizon-secs "$arg" > "$CASE/option.out" 2>&1; then fail "accepted horizon $arg"; fi
  done
  run_snapshot_check --help > "$CASE/help" || fail "check help failed"
  pass "one bounded default-format read, default horizon, strict options and help"
}
fm_test_run \
  test_snapshot_horizon_and_exhaustion \
  test_snapshot_attention_and_missing_data \
  test_snapshot_local_members_and_config \
  test_snapshot_account_keys_and_scopes \
  test_snapshot_alert_dedup_and_rotation \
  test_snapshot_one_live_read_and_options \
  test_stale_quota_is_unknown_not_headroom \
  test_short_supervisor_pool_steers_its_workers_and_fails_over \
  test_exhausted_supervisor_fails_over_to_another_account \
  test_exhausted_supervisor_with_no_way_out_names_none \
  test_stale_candidate_is_not_a_failover_pick \
  test_second_mate_picks_follow_its_own_pin_and_home \
  test_claude_candidate_lands_on_the_relaunching_pin \
  test_unrecorded_model_with_a_short_model_scope_is_unknown \
  test_account_pick_skips_a_pool_another_member_holds_short \
  test_primary_account_carries_to_a_later_check \
  test_codex_primary_proven_by_its_session_stays_a_supervisor \
  test_pick_skips_a_pool_a_worker_off_the_supervisor_pools_holds \
  test_provider_prefixed_model_binds_its_model_scope \
  test_sole_keyless_claude_lane_is_the_ordinary_account \
  test_listed_home_claude_candidate_names_its_account \
  test_pi_member_pinned_to_its_own_root_is_its_own_pool \
  test_lock_change_during_a_check_is_a_kickoff_that_carries_nothing \
  test_limit_dialogs_are_recorded_with_account_and_model \
  test_warning_records_then_checks \
  test_tick_runs_at_kickoff_and_periodically \
  test_window_defaults_to_the_morning \
  test_no_quota_axi_is_unknown
