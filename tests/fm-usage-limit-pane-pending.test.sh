#!/usr/bin/env bash
# Portable skip/pending and named-pane classify for the usage-limit live marker.
# Never enables the live mode in CI. Never starts a session or types Enter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/tests/fm-usage-limit-pane-live.test.sh"
TMP=$(fm_test_tmproot fm-usage-limit-pane-pending)

run_guard() {
  env -u FM_LIVE -u FM_USAGE_LIMIT_PANE_LIVE -u FM_USAGE_LIMIT_PANE \
    -u FM_USAGE_LIMIT_PANE_SOCKET "$@" bash "$GUARD"
}

test_default_is_skip_pending_never_pass() {
  local out rc=0
  out=$(run_guard 2>&1) || rc=$?
  expect_code 0 "$rc" "default live marker must skip, not fail"$'\n'"$out"
  printf '%s\n' "$out" | grep -Eq '^skip: (live: opt-in|pending:)' \
    || fail "default must print a skip/pending marker, got:"$'\n'"$out"
  printf '%s\n' "$out" | grep -Eq '^ok |^pass ' \
    && fail "default skip/pending must never pass:"$'\n'"$out"
  pass "usage-limit live marker: default is skip/pending, never pass"
}

test_fm_live_zero_prints_the_family_skip() {
  local out rc=0
  out=$(run_guard FM_LIVE=0 2>&1) || rc=$?
  expect_code 0 "$rc" "FM_LIVE=0 must skip"$'\n'"$out"
  printf '%s\n' "$out" | grep -qx 'skip: live: disabled by FM_LIVE=0' \
    || fail "FM_LIVE=0 must print the family skip line, got:"$'\n'"$out"
  pass "usage-limit live marker: FM_LIVE=0 prints skip: live: disabled by FM_LIVE=0"
}

test_fm_live_one_without_a_pane_is_pending() {
  local out rc=0
  out=$(run_guard FM_LIVE=1 2>&1) || rc=$?
  expect_code 0 "$rc" "FM_LIVE=1 without a pane must skip pending, not fail"$'\n'"$out"
  printf '%s\n' "$out" | grep -q '^skip: pending:' \
    || fail "FM_LIVE=1 without a pane must print skip: pending, got:"$'\n'"$out"
  printf '%s\n' "$out" | grep -Eq 'claude is not installed|^ok ' \
    && fail "FM_LIVE=1 without a pane must not require claude or pass:"$'\n'"$out"
  pass "usage-limit live marker: FM_LIVE=1 without a pane is pending"
}

test_opt_in_without_a_pane_is_pending() {
  local out rc=0
  out=$(run_guard FM_USAGE_LIMIT_PANE_LIVE=1 2>&1) || rc=$?
  expect_code 0 "$rc" "opt-in without a pane must skip pending"$'\n'"$out"
  printf '%s\n' "$out" | grep -q '^skip: pending:' \
    || fail "opt-in without a pane must print skip: pending, got:"$'\n'"$out"
  pass "usage-limit live marker: opt-in without FM_USAGE_LIMIT_PANE is pending"
}

install_fake_tmux() {  # <capture-file>
  mkdir -p "$TMP/fakebin"
  cat > "$TMP/fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/tmux.args"
for a in "\$@"; do
  if [ "\$a" = send-keys ]; then
    printf '%s\n' "\$*" >> "$TMP/tmux.send-keys"
    exit 1
  fi
done
case " \$* " in
  *" capture-pane "*)
    cat "$1"
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$TMP/fakebin/tmux"
}

test_named_pane_classifies_usage_limit_without_enter() {
  local out rc=0 capture
  capture="$TMP/limit.capture"
  printf '%s\n' \
    'You have hit your weekly limit for Opus.' \
    'SECRET_PANE_TOKEN_DO_NOT_LOG' \
    '' \
    ' ❯ 1. Switch to Sonnet' \
    '   2. Wait' \
    '' \
    'Enter to confirm · Esc to cancel' > "$capture"
  : > "$TMP/tmux.args"
  : > "$TMP/tmux.send-keys"
  install_fake_tmux "$capture"
  out=$(PATH="$TMP/fakebin:$PATH" run_guard \
    FM_USAGE_LIMIT_PANE_LIVE=1 FM_USAGE_LIMIT_PANE=sess:p0 2>&1) || rc=$?
  expect_code 0 "$rc" "named existing pane must classify"$'\n'"$out"
  printf '%s\n' "$out" | grep -q 'named existing pane classified usage-limit with no Enter' \
    || fail "named pane must pass only on usage-limit classify, got:"$'\n'"$out"
  [ ! -s "$TMP/tmux.send-keys" ] \
    || fail "named-pane classify typed keys: $(cat "$TMP/tmux.send-keys")"
  grep -Fq 'capture-pane' "$TMP/tmux.args" \
    || fail "named-pane classify never captured: $(cat "$TMP/tmux.args")"
  printf '%s\n' "$out" | grep -Fq 'SECRET_PANE_TOKEN_DO_NOT_LOG' \
    && fail "named-pane classify leaked pane text:"$'\n'"$out"
  pass "usage-limit live marker: named existing pane classifies usage-limit with no Enter"
}

test_named_non_limit_pane_never_passes() {
  local out rc=0 capture
  capture="$TMP/plain.capture"
  printf '%s\nWorking.\n> \n' 'SECRET_PANE_TOKEN_DO_NOT_LOG' > "$capture"
  : > "$TMP/tmux.args"
  : > "$TMP/tmux.send-keys"
  install_fake_tmux "$capture"
  out=$(PATH="$TMP/fakebin:$PATH" run_guard \
    FM_USAGE_LIMIT_PANE_LIVE=1 FM_USAGE_LIMIT_PANE=sess:p0 2>&1) || rc=$?
  expect_code 1 "$rc" "a named non-limit pane must fail closed"$'\n'"$out"
  printf '%s\n' "$out" | grep -Eq '^ok |classified usage-limit with no Enter' \
    && fail "a named non-limit pane must never pass:"$'\n'"$out"
  [ ! -s "$TMP/tmux.send-keys" ] \
    || fail "non-limit classify typed keys: $(cat "$TMP/tmux.send-keys")"
  printf '%s\n' "$out" | grep -Fq 'SECRET_PANE_TOKEN_DO_NOT_LOG' \
    && fail "non-limit classify leaked pane text:"$'\n'"$out"
  pass "usage-limit live marker: a named non-limit pane never passes"
}

if [ "$#" -gt 0 ]; then
  fm_test_run "$@"
  exit
fi

fm_test_run \
  test_default_is_skip_pending_never_pass \
  test_fm_live_zero_prints_the_family_skip \
  test_fm_live_one_without_a_pane_is_pending \
  test_opt_in_without_a_pane_is_pending \
  test_named_pane_classifies_usage_limit_without_enter \
  test_named_non_limit_pane_never_passes
