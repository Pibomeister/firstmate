#!/usr/bin/env bash
# Supervisor failover choice: another signed-in Claude account first, then a
# declared comparable model on another verified runtime, never an exhausted or
# unmeasured pool, and never a pin change. quota-axi, claude auth, and the two
# delegates (the handoff launcher and fm-control) are fakes; the choice and
# its records are the real script's.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-supervisor-failover)
trap 'fm_test_cleanup' EXIT
LAB="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
DELEGATES="$TMP_ROOT/delegates"
QUOTA="$TMP_ROOT/quota"
mkdir -p "$LAB/state" "$LAB/config" "$LAB/data" "$FAKEBIN" "$DELEGATES" "$QUOTA" "$TMP_ROOT/user"
printf '# handoff\n' > "$LAB/data/handoff.md"
for h in claude codex agy; do ln -s /bin/bash "$FAKEBIN/$h"; done
# `claude auth status` under the bash stand-in runs the `auth` script found on
# PATH; an account is signed in when its root holds a signed-in marker.
cat > "$FAKEBIN/auth" <<'EOF'
#!/usr/bin/env bash
[ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -e "$CLAUDE_CONFIG_DIR/signed-in" ]
EOF
cat > "$FAKEBIN/quota-axi" <<'EOF'
#!/usr/bin/env bash
provider='' profile=0
while [ $# -gt 0 ]; do
  case "$1" in --provider) provider=$2; shift 2 ;; --profile-only) profile=1; shift ;; *) shift ;; esac
done
echo "$provider profile=$profile root=${CLAUDE_CONFIG_DIR:-}" >> "$FM_TEST_QUOTA/reads"
if [ "$profile" = 1 ]; then cat "$CLAUDE_CONFIG_DIR/quota.json" 2>/dev/null || exit 1; exit 0; fi
cat "$FM_TEST_QUOTA/$provider.json" 2>/dev/null || exit 1
EOF
for d in fm-handoff-launch.sh fm-control.sh; do
  cat > "$DELEGATES/$d" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0")" "$@" > "$FM_HOME/delegate.argv"
exit "${FM_TEST_DELEGATE_RC:-0}"
EOF
done
chmod +x "$FAKEBIN/auth" "$FAKEBIN/quota-axi" "$DELEGATES/"*.sh
export FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config" FM_ROOT_OVERRIDE="$ROOT"
export FM_HANDOFF_TEST_HARNESS=claude FM_SUPERVISOR_FAILOVER_TEST_BIN="$DELEGATES"
export PATH="$FAKEBIN:$PATH" FM_TEST_QUOTA="$QUOTA" HOME="$TMP_ROOT/user"
unset FM_BACKEND QUOTA_AXI_SNAPSHOT FM_TEST_DELEGATE_RC

# Gemini models on agy are bounded by their model-group scope, not all_models.
quota_fixture() { # <provider> <percent> <runway> [<scope>]
  jq -n --arg p "$1" --argjson pct "$2" --arg r "$3" --arg s "${4:-all_models}" \
    '{schemaVersion:5,providers:[{provider:$p,quotaSemantics:{status:"known",effectiveAvailability:[{scope:$s,status:"known",effectivePercentRemaining:$pct,runway:{status:$r}}]}}]}'
}
pins_digest() {
  (cd "$LAB/config" && find . -name '*account*' -exec cksum {} + 2>/dev/null | sort)
}
OUT='' RC=0
# failover <backend> <args...>: run the control with a clean record.
failover() {
  local backend=$1
  shift
  printf '%s\n' "$backend" > "$LAB/config/backend"
  rm -f "$LAB/delegate.argv" "$LAB/state/supervisor-failover.log" "$QUOTA/reads"
  RC=0
  OUT=$(bash "$ROOT/bin/fm-supervisor-failover.sh" "$@" 2>&1) || RC=$?
}
delegate_is() { # <label> <expected arg>...
  local label=$1 line i=0
  shift
  local -a got=()
  [ -f "$LAB/delegate.argv" ] || fail "$label: no delegate ran: $OUT"
  while IFS= read -r line; do got+=("$line"); done < "$LAB/delegate.argv"
  [ "${#got[@]}" = "$#" ] || fail "$label: expected delegate argv '$*', got '${got[*]}'"
  for want; do
    [ "${got[$i]}" = "$want" ] || fail "$label: delegate argv[$i] is '${got[$i]}', expected '$want'"
    i=$((i + 1))
  done
}
no_delegate() { [ ! -e "$LAB/delegate.argv" ] || fail "$1: no delegate may run: $(cat "$LAB/delegate.argv")"; }

# Declared accounts, in list order: A is the current one and exhausted, C is
# signed out with plenty of headroom, and B is signed in with less.
for a in A B C; do mkdir -p "$TMP_ROOT/acct$a"; done
touch "$TMP_ROOT/acctA/signed-in" "$TMP_ROOT/acctB/signed-in"
quota_fixture claude 0 exhausted_now > "$TMP_ROOT/acctA/quota.json"
quota_fixture claude 35 through_reset > "$TMP_ROOT/acctB/quota.json"
quota_fixture claude 90 through_reset > "$TMP_ROOT/acctC/quota.json"
printf '%s\n' "$TMP_ROOT/acctA" "$TMP_ROOT/acctC" "$TMP_ROOT/acctB" > "$LAB/config/claude-accounts"
export CLAUDE_CONFIG_DIR="$TMP_ROOT/acctA"
quota_fixture codex 60 through_reset > "$QUOTA/codex.json"
quota_fixture agy 50 through_reset model:gemini > "$QUOTA/agy.json"
PINS_BEFORE=$(pins_digest)

failover tmux primary "$LAB/data/handoff.md" --candidate codex:gpt-5.5
[ "$RC" = 0 ] || fail "account switch must succeed: $OUT"
assert_contains "$OUT" "candidate harness=claude model=default account=$TMP_ROOT/acctA skip=current_account" 'the current account is not a candidate'
assert_contains "$OUT" "account=$TMP_ROOT/acctC skip=not_signed_in" 'a signed-out account is skipped without a sign-in'
assert_contains "$OUT" "replaced scope=primary from=claude:default:$TMP_ROOT/acctA harness=claude model=default account=$TMP_ROOT/acctB via=account_switch reason=claude_pool_exhausted verdict=ok" \
  'the replacement names the account switch and its reason'
delegate_is 'account switch' fm-handoff-launch.sh --harness claude --reason claude_pool_exhausted --account "$TMP_ROOT/acctB" "$LAB/data/handoff.md"
assert_not_contains "$(cat "$QUOTA/reads")" 'codex' 'a signed-in account with headroom wins before another runtime is measured'
assert_not_contains "$(cat "$QUOTA/reads")" "root=$TMP_ROOT/acctC" 'a signed-out account is never measured'
pass 'account switch: another signed-in Claude account with headroom takes over first'

# Every signed-in Claude account is out: a comparable model on Codex.
quota_fixture claude 0 exhausted_now > "$TMP_ROOT/acctB/quota.json"
failover tmux primary "$LAB/data/handoff.md" --candidate muse:muse-large --candidate claude:opus --candidate codex:gpt-5.5 --reason weekly_cap
[ "$RC" = 0 ] || fail "claude to codex must succeed: $OUT"
assert_contains "$OUT" "account=$TMP_ROOT/acctB verdict=exhausted" 'an exhausted signed-in account is skipped'
assert_contains "$OUT" 'candidate harness=muse model=muse-large account=none skip=refused' 'muse is refused'
assert_contains "$OUT" 'candidate harness=claude model=opus account=none skip=same_runtime_as_current' 'the current runtime is not a failover target'
assert_contains "$OUT" 'harness=codex model=gpt-5.5 account=ambient via=runtime_switch reason=weekly_cap verdict=ok scope=all_models remaining=60' \
  'the choice names the replacement runtime, model, reason, and quota'
delegate_is 'claude to codex' fm-handoff-launch.sh --harness codex --reason weekly_cap --model gpt-5.5 "$LAB/data/handoff.md"
log=$(cat "$LAB/state/supervisor-failover.log")
assert_contains "$log" 'event=failover_choice scope=primary' 'the choice is logged'
assert_contains "$log" 'event=failover_result result=replaced' 'the replacement is logged'
pass 'claude to codex: no Claude account has headroom, so a comparable Codex model takes over'

# Codex is exhausted and the candidates come from the config file: agy.
quota_fixture codex 20 exhausted_now > "$QUOTA/codex.json"
printf '# comparable models\ncodex:gpt-5.5\n\nagy:gemini-3-pro\n' > "$LAB/config/supervisor-failover-candidates"
failover tmux primary "$LAB/data/handoff.md"
[ "$RC" = 0 ] || fail "claude to agy must succeed: $OUT"
assert_contains "$OUT" 'candidate harness=codex model=gpt-5.5 account=ambient verdict=exhausted scope=all_models runway=exhausted_now' 'exhausted_now vetoes codex'
delegate_is 'claude to agy' fm-handoff-launch.sh --harness agy --reason claude_pool_exhausted --model gemini-3-pro "$LAB/data/handoff.md"
pass 'claude to agy: an exhausted_now runtime is vetoed and the next configured candidate takes over'

# Unmeasured quota is never a failover target.
rm "$QUOTA/codex.json"
failover tmux primary "$LAB/data/handoff.md"
assert_contains "$OUT" 'candidate harness=codex model=gpt-5.5 account=ambient verdict=unknown why=no_valid_codex_snapshot' 'unmeasured quota is reported'
delegate_is 'unmeasured codex' fm-handoff-launch.sh --harness agy --reason claude_pool_exhausted --model gemini-3-pro "$LAB/data/handoff.md"
pass 'unmeasured quota: a candidate without a measured headroom reading is skipped'

# On Orca no account can be selected and agy is unverified.
quota_fixture codex 60 through_reset > "$QUOTA/codex.json"
failover orca primary "$LAB/data/handoff.md" --candidate agy:gemini-3-pro --candidate codex:gpt-5.5
assert_contains "$OUT" "account=$TMP_ROOT/acctB skip=orca_cannot_select_account" 'orca skips the account step'
assert_contains "$OUT" 'candidate harness=agy model=gemini-3-pro account=none skip=agy_unverified_on_orca' 'orca skips agy'
delegate_is 'orca codex' fm-handoff-launch.sh --harness codex --reason claude_pool_exhausted --model gpt-5.5 "$LAB/data/handoff.md"
pass 'orca: account and agy steps are skipped, codex takes over'

# Nothing has headroom: no replacement, the outcome is reported and logged.
quota_fixture codex 0 exhausted_now > "$QUOTA/codex.json"
quota_fixture agy 0 through_reset model:gemini > "$QUOTA/agy.json"
failover tmux primary "$LAB/data/handoff.md"
[ "$RC" = 1 ] || fail "an exhausted fleet must exit 1, got $RC: $OUT"
assert_contains "$OUT" "none scope=primary from=claude:default:$TMP_ROOT/acctA reason=no_eligible_runtime" 'no eligible runtime is reported'
assert_contains "$OUT" 'harness=agy model=gemini-3-pro account=ambient verdict=exhausted scope=model:gemini remaining=0' 'a 0% pool is exhausted'
no_delegate 'exhausted fleet'
assert_contains "$(cat "$LAB/state/supervisor-failover.log")" 'event=failover_none' 'the dead end is logged'
pass 'exhausted veto: with every pool exhausted nothing launches'

# A failing delegate is reported with its status. --dry-run is not a mode.
quota_fixture agy 50 through_reset model:gemini > "$QUOTA/agy.json"
FM_TEST_DELEGATE_RC=3 failover tmux primary "$LAB/data/handoff.md"
[ "$RC" = 3 ] || fail "a failed handoff must return its exit status, got $RC"
assert_contains "$OUT" 'failed rc=3 scope=primary' 'the failure is reported'
assert_contains "$(cat "$LAB/state/supervisor-failover.log")" 'event=failover_result result=failed rc=3' 'the failure is logged'
pass 'a failed handoff is reported with its status'
unset FM_TEST_DELEGATE_RC
failover tmux primary "$LAB/data/handoff.md" --dry-run
[ "$RC" = 2 ] || fail "--dry-run must be refused, got $RC: $OUT"
assert_contains "$OUT" 'unexpected argument: --dry-run' 'an unknown mode is a usage error'
no_delegate 'refused dry-run'
pass 'dry-run is refused and nothing launches'

# A secondmate relaunches in its own home through fm-control, with no account step.
printf 'kind=secondmate\nharness=claude\nmodel=opus\nworktree=%s\n' "$TMP_ROOT/mate" > "$LAB/state/mate-a.meta"
quota_fixture codex 45 through_reset > "$QUOTA/codex.json"
failover tmux secondmate mate-a --candidate muse:muse-large --candidate codex:gpt-5.5
[ "$RC" = 0 ] || fail "secondmate failover must succeed: $OUT"
assert_contains "$OUT" 'skip=refused why=muse_is_unverified_as_a_secondmate_and_refused' 'muse is refused for a secondmate'
assert_not_contains "$OUT" 'account_switch' 'a secondmate keeps its account pin'
assert_contains "$OUT" 'replaced scope=secondmate:mate-a from=claude:opus:pin harness=codex model=gpt-5.5' 'the secondmate replacement is reported'
delegate_is 'secondmate' fm-control.sh mate-a relaunch --harness codex --model gpt-5.5 \
  --note 'Supervisor failover: claude pool ran out (claude_pool_exhausted); relaunched on codex gpt-5.5 (verdict=ok scope=all_models remaining=45 runway=through_reset).'
failover tmux secondmate missing-mate --candidate codex:gpt-5.5
[ "$RC" = 2 ] || fail "an unknown secondmate must refuse: $OUT"
no_delegate 'unknown secondmate'
RC=0
OUT=$(env -u FM_HOME bash "$ROOT/bin/fm-supervisor-failover.sh" secondmate mate-a --candidate codex:gpt-5.5 2>&1) || RC=$?
[ "$RC" = 2 ] || fail "a secondmate failover without an explicit home must refuse: $OUT"
pass 'secondmate: relaunched onto codex through fm-control in its own home'

# A secondmate Claude candidate is eligible only when its pin resolves. A pin
# that does not resolve is skipped even when the ambient account has headroom.
# A resolved pin is the account that is measured and reported, and relaunch
# does not receive --account.
printf 'kind=secondmate\nharness=codex\nmodel=gpt-5.5\nworktree=%s\n' "$TMP_ROOT/mate" > "$LAB/state/mate-b.meta"
pin_root="$TMP_ROOT/mate-pin"
mkdir -p "$LAB/config/secondmate-accounts/mate-b" "$pin_root"
printf '%s\n' '/no/such/claude-root' > "$LAB/config/secondmate-accounts/mate-b/claude-account"
quota_fixture claude 90 through_reset > "$QUOTA/claude.json"
quota_fixture agy 40 through_reset model:gemini > "$QUOTA/agy.json"
failover tmux secondmate mate-b --candidate claude:opus --candidate agy:gemini-3-pro
[ "$RC" = 0 ] || fail "a broken pin must fall through to the next runtime: $OUT"
assert_contains "$OUT" 'candidate harness=claude model=opus account=pin skip=pin_unresolved why=error:' \
  'a pin that cannot be resolved is skipped with its error'
assert_contains "$OUT" 'no/such/claude-root' 'the skip names the pin that failed'
assert_not_contains "$(cat "$QUOTA/reads")" 'claude ' 'a broken pin must not be measured as the ambient account'
assert_contains "$OUT" 'replaced scope=secondmate:mate-b from=codex:gpt-5.5:pin harness=agy model=gemini-3-pro account=ambient' \
  'the next runtime takes over'
delegate_is 'broken pin falls through' fm-control.sh mate-b relaunch --harness agy --model gemini-3-pro \
  --note 'Supervisor failover: codex pool ran out (codex_pool_exhausted); relaunched on agy gemini-3-pro (verdict=ok scope=model:gemini remaining=40 runway=through_reset).'
pass 'secondmate claude: an unresolvable pin is skipped and does not win on the ambient account'

quota_fixture claude 70 through_reset > "$pin_root/quota.json"
printf '%s\n' "$pin_root" > "$LAB/config/secondmate-accounts/mate-b/claude-account"
failover tmux secondmate mate-b --candidate claude:opus --candidate codex:gpt-5.5
[ "$RC" = 0 ] || fail "a resolved pin with headroom must take over: $OUT"
assert_contains "$OUT" 'replaced scope=secondmate:mate-b from=codex:gpt-5.5:pin harness=claude model=opus account=pin via=runtime_switch' \
  'the replacement names the pin, not the ambient account'
assert_contains "$(cat "$QUOTA/reads")" "claude profile=1 root=$pin_root" 'quota is read for the resolved pin'
delegate_is 'resolved pin' fm-control.sh mate-b relaunch --harness claude --model opus \
  --note 'Supervisor failover: codex pool ran out (codex_pool_exhausted); relaunched on claude opus (verdict=ok scope=all_models remaining=70 runway=through_reset).'
rm -rf "$LAB/config/secondmate-accounts"
pass 'secondmate claude: a resolved pin is reported as pin and relaunch does not pass --account'

[ "$(pins_digest)" = "$PINS_BEFORE" ] || fail 'account pins and the account list must be unchanged'
[ ! -e "$LAB/config/claude-account" ] || fail 'no Claude pin may be created'
pass 'pin preservation: no account pin or account list changed'
