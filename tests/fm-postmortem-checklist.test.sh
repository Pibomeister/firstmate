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

install_clock() {
  local h=$1
  export POSTMORTEM_REAL_DATE
  POSTMORTEM_REAL_DATE=$(command -v date)
  mkdir -p "$h/fakebin"
  cat > "$h/fakebin/date" <<'SH'
#!/bin/bash
case "$*" in
  +%s) printf '%s\n' "$POSTMORTEM_TEST_EPOCH" ;;
  +%F) python3 -c 'import datetime, os; print(datetime.datetime.fromtimestamp(int(os.environ["POSTMORTEM_TEST_EPOCH"])).date())' ;;
  *) exec "$POSTMORTEM_REAL_DATE" "$@" ;;
esac
SH
  chmod +x "$h/fakebin/date"
  export PATH="$h/fakebin:$PATH" POSTMORTEM_TEST_EPOCH
}

inbox_receipt() {
  local h=$1 epoch=$2 suffix=$3 directory=$4 machine=$5 path=$6 hash=$7
  mkdir -p "$h/state/inbox/$directory"
  printf 'id=%s-%s\n--\npostmortem-receipt\t%s\t%s\t%s\t%s\n' \
    "$epoch" "$suffix" "$NIGHT" "$machine" "$path" "$hash" > "$h/state/inbox/$directory/$epoch-$suffix.note"
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
  local h out rc artifact machine
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
  [ "$rc" -eq 0 ] || fail "open on an unopened night should name missing machines (rc=$rc): $out"
  for machine in M3 Studio Hetzner local; do
    assert_contains "$out" "$machine" "unopened checklist hid $machine"
  done

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

test_relative_receipts_survive_a_different_working_directory() {
  local h artifact hash out
  h=$(make_home relative)
  artifact=$(seed_artifact "$h" M3)
  hash=$(sha_of "$artifact")
  (cd "$h" && checklist "$h" receipt --machine M3 --path artifacts/M3.md --hash "$hash" --night "$NIGHT") >/dev/null \
    || fail "relative receipt failed"
  out=$(cd "$TMP_ROOT" && checklist "$h" check --night "$NIGHT") || :
  assert_contains "$out" $'M3\tclosed\t' "changing directories reopened the artifact: $out"
  pass "relative receipts identify the same artifact from another directory"
}

test_unavailable_or_failed_hashing_keeps_every_machine_open() {
  local h machine artifact fakebin tool out rc
  h=$(make_home no-hash)
  for machine in M3 Studio Hetzner local; do
    artifact=$(seed_artifact "$h" "$machine")
    checklist "$h" receipt --machine "$machine" --path "$artifact" --hash "$(sha_of "$artifact")" --night "$NIGHT" >/dev/null \
      || fail "could not record $machine"
  done
  fakebin="$h/fakebin"
  mkdir -p "$fakebin"
  for tool in bash dirname awk cut tr date mkdir sed python3; do
    ln -s "$(command -v "$tool")" "$fakebin/$tool"
  done
  if out=$(PATH="$fakebin" checklist "$h" check --night "$NIGHT"); then
    rc=0
  else
    rc=$?
  fi
  assert_equals 1 "$rc" "missing SHA tools reported a complete checklist"
  for machine in M3 Studio Hetzner local; do
    assert_contains "$out" "$machine"$'\topen\tartifact hash verification failed' "hash failure hid $machine: $out"
  done
  out=$(PATH="$fakebin" checklist "$h" open --night "$NIGHT") || fail "open failed without SHA tools"
  for machine in M3 Studio Hetzner local; do
    assert_contains "$out" "$machine" "open hid unverified $machine"
  done
  cat > "$fakebin/shasum" <<'SH'
#!/bin/bash
printf '%064d  artifact\n' 0
exit 1
SH
  chmod +x "$fakebin/shasum"
  out=$(PATH="$fakebin" checklist "$h" receipt --machine M3 --path "$h/artifacts/M3.md" \
    --hash 0000000000000000000000000000000000000000000000000000000000000000 --night "$NIGHT") || fail "receipt failed"
  assert_contains "$out" $'M3\topen\tartifact hash verification failed' "a failed SHA command closed the row"
  pass "missing or failing SHA tools keep every affected machine named and open"
}

test_collection_creates_each_due_morning_and_reads_inbox_receipts() (
  local h out machine artifact hash since now rc
  h=$(make_home collection)
  install_clock "$h"
  since=$(python3 -c 'import datetime as d; print(int(d.datetime(2026,11,22,20).timestamp()))')
  now=$(python3 -c 'import datetime as d; print(int(d.datetime(2026,11,24,7,45).timestamp()))')
  POSTMORTEM_TEST_EPOCH=$((now - 1))
  artifact=$(seed_artifact "$h" M3)
  hash=$(sha_of "$artifact")
  inbox_receipt "$h" "$POSTMORTEM_TEST_EPOCH" m3 handled M3 "$artifact" "$hash"
  out=$(checklist "$h" collect --since "$since") || fail "early collection failed"
  assert_not_contains "$out" '2026-11-24:' "collection opened a morning before 07:45"
  if checklist "$h" check --night "$NIGHT" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_equals 2 "$rc" "early collection created a future checklist"
  POSTMORTEM_TEST_EPOCH=$now
  out=$(checklist "$h" collect --since "$since") || fail "collection failed: $out"
  for machine in M3 Studio Hetzner local; do
    assert_contains "$out" "$machine"$'\topen\t2026-11-23: no artifact receipt recorded' "first morning hid $machine"
  done
  assert_contains "$out" $'Hetzner\topen\t2026-11-24: no artifact receipt recorded' "07:45 hid a missing machine"
  assert_not_contains "$out" $'M3\topen\t2026-11-24:' "handled inbox receipt was ignored"
  out=$(checklist "$h" open --night 2026-11-24) || fail "open failed"
  assert_not_contains "$out" $'M3\topen' "open disagreed with collection about receipt"
  if out=$(checklist "$h" collect --until "$now" 2>&1); then rc=0; else rc=$?; fi
  assert_equals 2 "$rc" "collection accepted a historical clock override"
  pass "collection creates every due morning and consumes durable inbox receipts"
)

test_open_machines_survive_new_away_windows_and_later_mornings() (
  local h out artifact machine since
  h=$(make_home retained)
  install_clock "$h"
  POSTMORTEM_TEST_EPOCH=$(python3 -c 'import datetime as d; print(int(d.datetime(2026,11,24,8).timestamp()))')
  for machine in M3 Studio local; do
    artifact=$(seed_artifact "$h" "$machine")
    checklist "$h" receipt --machine "$machine" --path "$artifact" --hash "$(sha_of "$artifact")" >/dev/null || fail "could not record $machine"
  done
  out=$(checklist "$h" collect) || fail "first return failed"
  assert_contains "$out" $'Hetzner\topen\t2026-11-24:' "first return hid the missing machine"
  since=$(python3 -c 'import datetime as d; print(int(d.datetime(2026,11,24,8,30).timestamp()))')
  POSTMORTEM_TEST_EPOCH=$((since + 1800))
  out=$(checklist "$h" collect --since "$since") || fail "second return failed"
  assert_contains "$out" $'Hetzner\topen\t2026-11-24:' "new away window hid an open machine"
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "second return duplicated or reopened rows"
  POSTMORTEM_TEST_EPOCH=$(python3 -c 'import datetime as d; print(int(d.datetime(2026,11,25,9).timestamp()))')
  since=$((POSTMORTEM_TEST_EPOCH - 1800))
  out=$(checklist "$h" collect --since "$since") || fail "next morning failed"
  assert_contains "$out" $'Hetzner\topen\t2026-11-24:' "next morning hid an unresolved checklist"
  assert_contains "$out" $'M3\topen\t2026-11-25:' "late away entry hid the current morning"
  artifact=$(seed_artifact "$h" Hetzner)
  checklist "$h" receipt --machine Hetzner --path "$artifact" --hash "$(sha_of "$artifact")" --night "$NIGHT" >/dev/null || fail "could not close old row"
  out=$(checklist "$h" collect --since "$since") || fail "collection after closure failed"
  assert_not_contains "$out" '2026-11-24:' "verified old checklist stayed open"
  pass "unresolved machines remain visible across away windows and mornings until verified"
)

test_receipt_conflicts_do_not_depend_on_scan_order() (
  local case_name h out artifact hash bad epoch rc receipt_hash
  epoch=$(python3 -c 'import datetime as d; print(int(d.datetime(2026,11,24,8).timestamp()))')
  bad=0000000000000000000000000000000000000000000000000000000000000000
  for case_name in pending-za pending-az handled-good handled-bad ledger-good ledger-bad path; do
    h=$(make_home "conflict-$case_name")
    install_clock "$h"
    POSTMORTEM_TEST_EPOCH=$epoch
    artifact=$(seed_artifact "$h" M3)
    hash=$(sha_of "$artifact")
    checklist "$h" start >/dev/null || fail "could not start checklist"
    case "$case_name" in
      pending-az)
        inbox_receipt "$h" "$epoch" a '' M3 "$artifact" "$hash"
        inbox_receipt "$h" "$epoch" z '' M3 "$artifact" "$bad" ;;
      pending-za)
        inbox_receipt "$h" "$epoch" z '' M3 "$artifact" "$hash"
        inbox_receipt "$h" "$epoch" a '' M3 "$artifact" "$bad" ;;
      handled-good)
        inbox_receipt "$h" "$epoch" good handled M3 "$artifact" "$hash"
        inbox_receipt "$h" "$epoch" bad '' M3 "$artifact" "$bad" ;;
      handled-bad)
        inbox_receipt "$h" "$epoch" good '' M3 "$artifact" "$hash"
        inbox_receipt "$h" "$epoch" bad handled M3 "$artifact" "$bad" ;;
      ledger-good)
        checklist "$h" receipt --machine M3 --path "$artifact" --hash "$hash" >/dev/null || fail "ledger receipt failed"
        inbox_receipt "$h" "$epoch" bad '' M3 "$artifact" "$bad" ;;
      ledger-bad)
        checklist "$h" receipt --machine M3 --path "$artifact" --hash "$bad" >/dev/null || fail "ledger receipt failed"
        inbox_receipt "$h" "$epoch" good '' M3 "$artifact" "$hash" ;;
      path)
        cp "$artifact" "$h/artifacts/other.md"
        inbox_receipt "$h" "$epoch" first '' M3 "$artifact" "$hash"
        inbox_receipt "$h" "$epoch" second '' M3 "$h/artifacts/other.md" "$hash" ;;
    esac
    if out=$(checklist "$h" check); then rc=0; else rc=$?; fi
    assert_equals 1 "$rc" "$case_name conflict reported complete"
    assert_contains "$out" $'M3\topen\tartifact receipt could not be verified' "$case_name selected a receipt by scan order"
    out=$(checklist "$h" open) || fail "open failed"
    assert_contains "$out" $'M3\topen\t' "$case_name hid the conflicting machine"
    receipt_hash=$hash
    [ "$case_name" != ledger-bad ] || receipt_hash=$bad
    out=$(checklist "$h" receipt --machine M3 --path "$artifact" --hash "$receipt_hash") || fail "receipt failed"
    assert_contains "$out" $'M3\topen\t' "$case_name receipt ignored tied inbox evidence"
    out=$(checklist "$h" collect) || fail "collection failed"
    assert_contains "$out" $'M3\topen\t2026-11-24:' "$case_name collection hid the conflict"
    POSTMORTEM_TEST_EPOCH=$((epoch + 1))
    out=$(checklist "$h" receipt --machine M3 --path "$artifact" --hash "$hash") || fail "newer receipt failed"
    assert_contains "$out" $'M3\tclosed\t' "$case_name did not accept a strictly newer receipt"
    export PATH=${PATH#*:}
  done
  pass "conflicting receipts stay open across filename orders, inbox locations, and ledger boundaries"
)

test_identical_ties_and_ordered_ledger_receipts_verify() (
  local h artifact hash out
  h=$(make_home identical)
  install_clock "$h"
  POSTMORTEM_TEST_EPOCH=$(python3 -c 'import datetime as d; print(int(d.datetime(2026,11,24,8).timestamp()))')
  artifact=$(seed_artifact "$h" M3)
  hash=$(sha_of "$artifact")
  checklist "$h" receipt --machine M3 --path "$artifact" --hash "$(printf '%064d' 0)" >/dev/null || fail "first ledger receipt failed"
  out=$(checklist "$h" receipt --machine M3 --path "$artifact" --hash "$hash") || fail "replacement receipt failed"
  assert_contains "$out" $'M3\tclosed\t' "known ledger order was treated as ambiguous"
  inbox_receipt "$h" "$POSTMORTEM_TEST_EPOCH" a '' M3 "$artifact" "$hash"
  inbox_receipt "$h" "$POSTMORTEM_TEST_EPOCH" z handled M3 "$artifact" "$(printf '%s' "$hash" | tr 'a-f' 'A-F')"
  out=$(checklist "$h" open) || fail "open failed"
  assert_not_contains "$out" M3 "identical receipts were treated as conflicting"
  pass "identical receipt ties and known ledger order retain the successful path"
)

test_calendar_dates_are_validated_and_invalid_history_is_isolated() (
  local h artifact hash invalid action out rc before
  h=$(make_home calendar)
  install_clock "$h"
  POSTMORTEM_TEST_EPOCH=$(python3 -c 'import datetime as d; print(int(d.datetime(2026,11,24,8).timestamp()))')
  artifact=$(seed_artifact "$h" M3)
  hash=$(sha_of "$artifact")
  checklist "$h" receipt --machine M3 --path "$artifact" --hash "$hash" >/dev/null || fail "valid receipt failed"
  before=$(cat "$h/state/postmortem-checklist.tsv")
  for invalid in 2026-11-31 2026-02-29 1900-02-29 0000-01-01 2026-00-01 2026-01-00 2026-13-01; do
    for action in start receipt check open; do
      if [ "$action" = receipt ]; then
        if out=$(checklist "$h" receipt --machine M3 --path "$artifact" --hash "$hash" --night "$invalid" 2>&1); then rc=0; else rc=$?; fi
      else
        if out=$(checklist "$h" "$action" --night "$invalid" 2>&1); then rc=0; else rc=$?; fi
      fi
      assert_equals 2 "$rc" "$action accepted invalid calendar date $invalid: $out"
    done
  done
  assert_equals "$before" "$(cat "$h/state/postmortem-checklist.tsv")" "invalid input changed the ledger"
  for valid in 2000-02-29 2024-02-29 2026-11-30; do
    checklist "$h" start --night "$valid" >/dev/null || fail "Gregorian date $valid was refused"
  done
  printf '2026-11-31\t-\topened\t\t\t%s\n2026-02-29\tM3\treceipt\t%s\t%s\t%s\n' \
    "$POSTMORTEM_TEST_EPOCH" "$artifact" "$hash" "$POSTMORTEM_TEST_EPOCH" >> "$h/state/postmortem-checklist.tsv"
  out=$(checklist "$h" collect) || fail "invalid legacy dates stopped collection: $out"
  assert_contains "$out" $'Hetzner\topen\t2026-11-24:' "invalid history hid a valid morning"
  assert_not_contains "$out" $'M3\topen\t2026-11-24:' "invalid history lost a valid receipt"
  assert_not_contains "$out" '2026-11-31:' "invalid legacy morning was collected"
  assert_not_contains "$out" '2026-02-29:' "invalid legacy receipt was collected"
  pass "Gregorian input validation rejects impossible dates and isolates invalid legacy rows"
)

test_receipt_inputs_are_read_once_per_command() (
  local h night machine artifact hash epoch directory out action
  h=$(make_home reads)
  install_clock "$h"
  epoch=$(python3 -c 'import datetime as d; print(int(d.datetime(2026,11,24,8).timestamp()))')
  POSTMORTEM_TEST_EPOCH=$epoch
  for night in 2026-11-22 2026-11-23 2026-11-24; do
    checklist "$h" start --night "$night" >/dev/null || fail "could not start $night"
    NIGHT=$night
    for machine in M3 Studio Hetzner local; do
      [ "$night/$machine" != 2026-11-22/Hetzner ] || continue
      artifact="$h/artifacts/$night-$machine.md"
      printf '%s %s postmortem\n' "$night" "$machine" > "$artifact"
      hash=$(sha_of "$artifact")
      [ "$night/$machine" != 2026-11-23/Studio ] || hash=$(printf '%064d' 0)
      directory=''
      [ "$machine" != local ] || directory=handled
      inbox_receipt "$h" "$epoch" "$night-$machine" "$directory" "$machine" "$artifact" "$hash"
    done
  done
  NIGHT=2026-11-24
  printf 'id=%s-noise\n--\nordinary inbox note\n' "$epoch" > "$h/state/inbox/$epoch-noise.note"
  export POSTMORTEM_READ_HOME="$h" POSTMORTEM_READ_LOG="$h/reads.log" POSTMORTEM_REAL_AWK POSTMORTEM_REAL_PYTHON
  POSTMORTEM_REAL_AWK=$(command -v awk)
  POSTMORTEM_REAL_PYTHON=$(command -v python3)
  cat > "$h/fakebin/awk" <<'SH'
#!/bin/bash
for arg in "$@"; do
  case "$arg" in
    "$POSTMORTEM_READ_HOME"/state/inbox/*.note|"$POSTMORTEM_READ_HOME"/state/postmortem-checklist.tsv)
      printf '%s\n' "$arg" >> "$POSTMORTEM_READ_LOG" ;;
  esac
done
exec "$POSTMORTEM_REAL_AWK" "$@"
SH
  cat > "$h/fakebin/python3" <<'SH'
#!/bin/bash
exec "$POSTMORTEM_REAL_PYTHON" -c '
import os, sys
log = open(os.environ["POSTMORTEM_READ_LOG"], "a")
home = os.environ["POSTMORTEM_READ_HOME"]
def record(event, args):
    if event == "open" and isinstance(args[0], str) and args[1] == "r":
        path = args[0]
        if path == home + "/state/postmortem-checklist.tsv" or (path.startswith(home + "/state/inbox/") and path.endswith(".note")):
            log.write(path + "\n")
            log.flush()
sys.addaudithook(record)
if sys.argv[1] == "-":
    code = sys.stdin.read()
    sys.argv = sys.argv[1:]
else:
    assert sys.argv[1] == "-c"
    code = sys.argv[2]
    sys.argv = ["-c", *sys.argv[3:]]
exec(compile(code, "<receipt-read-probe>", "exec"))
' "$@"
SH
  chmod +x "$h/fakebin/awk" "$h/fakebin/python3"
  for action in check open receipt collect; do
    : > "$POSTMORTEM_READ_LOG"
    if [ "$action" = receipt ]; then
      artifact="$h/artifacts/2026-11-24-M3.md"
      hash=$(sha_of "$artifact")
      out=$(checklist "$h" receipt --machine M3 --path "$artifact" --hash "$hash") || fail "receipt failed: $out"
      assert_contains "$out" $'M3\tclosed\t' "new receipt was absent from the invocation snapshot"
    else
      out=$(checklist "$h" "$action") || fail "$action failed: $out"
      case "$action" in
        check) assert_contains "$out" $'M3\tclosed\t' "current morning did not verify" ;;
        open) assert_equals '' "$out" "closed current morning was reopened" ;;
        collect)
          assert_contains "$out" $'Hetzner\topen\t2026-11-22: no artifact receipt recorded' "snapshot skipped the missing machine"
          assert_contains "$out" $'Studio\topen\t2026-11-23: artifact hash mismatch' "snapshot skipped the bad hash"
          assert_equals 2 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "snapshot lost or duplicated historical rows" ;;
      esac
    fi
    "$POSTMORTEM_REAL_PYTHON" - "$h" "$POSTMORTEM_READ_LOG" <<'PYCHECK'
import collections
import sys
from pathlib import Path

home, log = map(Path, sys.argv[1:])
notes = set((home / "state/inbox").glob("*.note")) | set((home / "state/inbox/handled").glob("*.note"))
assert len(notes) == 12
expected = notes | {home / "state/postmortem-checklist.tsv"}
reads = collections.Counter(map(Path, log.read_text().splitlines()))
assert set(reads) == expected, (set(reads), expected)
assert all(reads[path] == 1 for path in expected), reads
PYCHECK
    [ "$?" -eq 0 ] || fail "$action re-read or skipped receipt inputs"
  done
  pass "each command reads every ledger and inbox input once while preserving historical verification"
)

test_calendar_dates_are_validated_and_invalid_history_is_isolated
test_receipt_inputs_are_read_once_per_command
test_relative_receipts_survive_a_different_working_directory
test_unavailable_or_failed_hashing_keeps_every_machine_open
test_collection_creates_each_due_morning_and_reads_inbox_receipts
test_open_machines_survive_new_away_windows_and_later_mornings
test_receipt_conflicts_do_not_depend_on_scan_order
test_identical_ties_and_ordered_ledger_receipts_verify
test_missing_machine_is_named_open_and_bad_hash_stays_open
test_all_closed_check_passes_and_missing_artifact_stays_open
test_unknown_night_and_bad_input_are_refused
test_receipt_before_start_still_opens_the_night

echo "all fm-postmortem-checklist tests passed"
