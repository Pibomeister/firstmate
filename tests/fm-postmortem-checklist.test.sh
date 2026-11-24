#!/usr/bin/env bash
# Behavior tests for bin/fm-postmortem-checklist.sh: the overnight
# postmortem receipt checklist. One row per machine (M3, Studio, Hetzner,
# local); a row closes only when its artifact receipt verifies (path
# exists and its sha256 matches the recorded hash); unclosed rows stay
# open and are named, never silently absent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKLIST="$ROOT/bin/fm-postmortem-checklist.sh"
TMP_ROOT=$(fm_test_tmproot fm-postmortem-checklist-tests)
NIGHT=2026-11-24

make_home() {  # <name> -> prints the home dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/artifacts"
  printf '%s\n' "$dir"
}

checklist() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash "$CHECKLIST" "$@"
}

sha_of() {  # <file>
  shasum -a 256 "$1" | awk '{print $1}'
}

seed_artifact() {  # <home> <machine> -> prints the artifact path
  local path="$1/artifacts/$2.md"
  printf '%s overnight postmortem\n' "$2" > "$path"
  printf '%s\n' "$path"
}

test_missing_machine_is_named_open_and_bad_hash_stays_open() {
  local h out rc artifact
  h=$(make_home missing)
  out=$(checklist "$h" start --night "$NIGHT") || fail "start failed: $out"
  assert_contains "$out" "night=$NIGHT" "start did not name the night"
  # Re-starting the same night is idempotent.
  checklist "$h" start --night "$NIGHT" >/dev/null || fail "second start failed"
  assert_equals 1 "$(grep -c "opened" "$h/state/postmortem-checklist.tsv")" "a second start duplicated the checklist"

  artifact=$(seed_artifact "$h" M3)
  out=$(checklist "$h" receipt --machine M3 --path "$artifact" --hash "$(sha_of "$artifact")" --night "$NIGHT") \
    || fail "the M3 receipt failed: $out"
  assert_contains "$out" $'M3\tclosed\t' "a verified receipt did not close its row: $out"
  artifact=$(seed_artifact "$h" local)
  checklist "$h" receipt --machine local --path "$artifact" --hash "$(sha_of "$artifact")" --night "$NIGHT" >/dev/null \
    || fail "the local receipt failed"
  # Studio's artifact is present but its recorded hash is wrong.
  artifact=$(seed_artifact "$h" Studio)
  out=$(checklist "$h" receipt --machine Studio --path "$artifact" \
    --hash 0000000000000000000000000000000000000000000000000000000000000000 --night "$NIGHT") \
    || fail "the Studio receipt failed: $out"
  assert_contains "$out" $'Studio\topen\tartifact hash mismatch' "a bad hash did not stay open at receipt time: $out"
  # Hetzner records no receipt at all.

  set +e
  out=$(checklist "$h" check --night "$NIGHT")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "check should exit 1 while any row is open (rc=$rc): $out"
  assert_contains "$out" $'M3\tclosed\t' "the verified M3 row did not close: $out"
  assert_contains "$out" $'local\tclosed\t' "the verified local row did not close: $out"
  assert_contains "$out" $'Studio\topen\tartifact hash mismatch' "the bad-hash Studio row closed: $out"
  assert_contains "$out" $'Hetzner\topen\tno artifact receipt recorded' "the missing machine was silently absent: $out"

  out=$(checklist "$h" open --night "$NIGHT") || fail "open failed: $out"
  assert_contains "$out" "Hetzner" "open did not name the missing machine: $out"
  assert_contains "$out" "Studio" "open did not name the bad-hash machine: $out"
  assert_not_contains "$out" "M3" "open listed a closed machine: $out"
  assert_not_contains "$out" "local" "open listed the closed local home: $out"
  pass "a missing machine is named open and a present artifact with a bad hash stays open"
}

test_all_closed_check_passes_and_missing_artifact_stays_open() {
  local h out rc artifact machine
  h=$(make_home closed)
  checklist "$h" start --night "$NIGHT" >/dev/null || fail "start failed"
  for machine in M3 Studio Hetzner local; do
    artifact=$(seed_artifact "$h" "$machine")
    checklist "$h" receipt --machine "$machine" --path "$artifact" --hash "$(sha_of "$artifact")" --night "$NIGHT" >/dev/null \
      || fail "the $machine receipt failed"
  done
  out=$(checklist "$h" check --night "$NIGHT") || fail "check should exit 0 when every row is closed: $out"
  assert_not_contains "$out" "open" "a fully closed checklist still reported an open row: $out"
  out=$(checklist "$h" open --night "$NIGHT") || fail "open failed on a closed checklist: $out"
  assert_equals "" "$out" "open printed rows for a fully closed checklist"

  # An artifact that disappears after its receipt reopens its row.
  rm "$h/artifacts/Hetzner.md"
  set +e
  out=$(checklist "$h" check --night "$NIGHT")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "check should reopen a row whose artifact vanished (rc=$rc): $out"
  assert_contains "$out" $'Hetzner\topen\tartifact missing at recorded path' "a missing artifact did not reopen its row: $out"

  # An artifact changed after its receipt also reopens its row.
  artifact=$(seed_artifact "$h" Hetzner)
  checklist "$h" receipt --machine Hetzner --path "$artifact" --hash "$(sha_of "$artifact")" --night "$NIGHT" >/dev/null \
    || fail "the replacement Hetzner receipt failed"
  printf 'tampered\n' >> "$artifact"
  out=$(checklist "$h" open --night "$NIGHT") || fail "open failed after tampering: $out"
  assert_contains "$out" $'Hetzner\topen\tartifact hash mismatch' "a changed artifact did not reopen its row: $out"
  pass "check passes only when every row verifies, and missing or changed artifacts reopen their rows"
}

test_unknown_night_and_bad_input_are_refused() {
  local h out rc artifact
  h=$(make_home refused)
  set +e
  out=$(checklist "$h" check --night "$NIGHT" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "check on an unopened night should exit 2 (rc=$rc): $out"
  assert_contains "$out" "no postmortem checklist for night $NIGHT" "an unopened night was not reported: $out"
  set +e
  out=$(checklist "$h" open --night "$NIGHT" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "open on an unopened night should exit 2 (rc=$rc): $out"

  checklist "$h" start --night "$NIGHT" >/dev/null || fail "start failed"
  artifact=$(seed_artifact "$h" M3)
  set +e
  out=$(checklist "$h" receipt --machine mainframe --path "$artifact" --hash "$(sha_of "$artifact")" --night "$NIGHT" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "an unknown machine should be refused (rc=$rc): $out"
  set +e
  out=$(checklist "$h" receipt --machine M3 --path "$artifact" --hash deadbeef --night "$NIGHT" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a malformed hash should be refused (rc=$rc): $out"
  set +e
  out=$(checklist "$h" receipt --machine M3 --path "$artifact" --hash "$(sha_of "$artifact")" --night 24-11-2026 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a malformed night should be refused (rc=$rc): $out"
  # None of the refused receipts was recorded: M3 is still open.
  out=$(checklist "$h" open --night "$NIGHT") || fail "open failed: $out"
  assert_contains "$out" $'M3\topen\tno artifact receipt recorded' "a refused receipt was recorded anyway: $out"
  pass "an unopened night and malformed receipt input are refused without recording anything"
}

test_receipt_before_start_still_opens_the_night() {
  local h out artifact
  h=$(make_home early-receipt)
  artifact=$(seed_artifact "$h" Studio)
  checklist "$h" receipt --machine Studio --path "$artifact" --hash "$(sha_of "$artifact")" --night "$NIGHT" >/dev/null \
    || fail "an early receipt failed"
  out=$(checklist "$h" open --night "$NIGHT") || fail "open failed for an early-receipt night: $out"
  assert_contains "$out" $'M3\topen\tno artifact receipt recorded' "an early receipt did not open the other rows: $out"
  assert_not_contains "$out" "Studio" "the early verified receipt did not close its row: $out"
  pass "a receipt recorded before start still opens the night with the other machines named open"
}

test_missing_machine_is_named_open_and_bad_hash_stays_open
test_all_closed_check_passes_and_missing_artifact_stays_open
test_unknown_night_and_bad_input_are_refused
test_receipt_before_start_still_opens_the_night

echo "all fm-postmortem-checklist tests passed"
