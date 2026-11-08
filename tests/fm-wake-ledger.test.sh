#!/usr/bin/env bash
# tests/fm-wake-ledger.test.sh - every wake-queue removal path (acknowledgement,
# retirement, per-actor claim consumption, task prune) appends one durable
# wake-ledger row naming the sequence numbers it took out, an empty removal
# writes nothing, and bin/fm-wake-ledger.sh counts a window from those rows
# alone: pruned and retired wakes count, a minted but never-written sequence
# number does not, and a wake still queued at a window's end counts once, in the
# window of the row that later removes it. fm_now is the shared fixed-clock seam.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
LEDGER="$ROOT/bin/fm-wake-ledger.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-ledger-tests)
T0=1800000000

# drain_at <state> <now> [args...]: run the drain under a fixed clock.
drain_at() {
  local state=$1 now=$2
  shift 2
  FM_STATE_OVERRIDE="$state" FM_TEST_SEAM=1 FM_NOW="$now" bash "$DRAIN" "$@"
}

# present_at <state> <now>: drain once at <now> and set PRESENTED_THROUGH and
# PRESENTED_GENERATION from the acknowledgement boundary it printed.
present_at() {
  local state=$1 now=$2 err
  err="$state/../drain.err"
  drain_at "$state" "$now" > /dev/null 2> "$err" || fail "presentation drain failed: $(cat "$err")"
  PRESENTED_THROUGH=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  PRESENTED_GENERATION=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$PRESENTED_THROUGH" ] && [ -n "$PRESENTED_GENERATION" ] \
    || fail "drain printed no acknowledgement boundary: $(cat "$err")"
}

# present_and_ack <state> <now>: drain once, then acknowledge exactly what the
# drain presented, both at <now>.
present_and_ack() {
  local state=$1 now=$2
  present_at "$state" "$now"
  drain_at "$state" "$now" --ack-through "$PRESENTED_THROUGH" --recovery-generation "$PRESENTED_GENERATION" \
    > /dev/null 2>&1 || fail "acknowledgement through $PRESENTED_THROUGH failed"
  ACKED_THROUGH=$PRESENTED_THROUGH
  ACKED_GENERATION=$PRESENTED_GENERATION
}

ledger_count() {  # <state> <since> <until>
  FM_STATE_OVERRIDE="$1" bash "$LEDGER" count --since "$2" --until "$3"
}

ledger_rows() {  # <state> <since> <until>
  FM_STATE_OVERRIDE="$1" bash "$LEDGER" rows --since "$2" --until "$3"
}

prune_at() {  # <state> <now> <task> <target>
  FM_STATE_OVERRIDE="$1" FM_TEST_SEAM=1 FM_NOW="$2" \
    bash -c '. "$0/bin/fm-wake-lib.sh"; fm_wake_queue_prune_task "$1" "$2" "$3"' "$ROOT" "$1" "$3" "$4"
}

test_fm_now_fixed_clock_seam() {
  local lib="$ROOT/bin/fm-clock-lib.sh" out real
  out=$(FM_TEST_SEAM=1 FM_NOW=1234567 bash -c '. "$1"; fm_now' _ "$lib") || fail "fm_now failed under the seam"
  [ "$out" = 1234567 ] || fail "fm_now ignored FM_NOW under FM_TEST_SEAM=1: $out"
  real=$(date +%s)
  out=$(FM_TEST_SEAM='' FM_NOW=1234567 bash -c '. "$1"; fm_now' _ "$lib") || fail "fm_now failed without the seam"
  [ "$out" -ge "$real" ] || fail "fm_now honoured FM_NOW without FM_TEST_SEAM=1: $out"
  out=$(FM_TEST_SEAM=1 FM_NOW=12x bash -c '. "$1"; fm_now' _ "$lib") || fail "fm_now failed on a non-integer FM_NOW"
  [ "$out" -ge "$real" ] || fail "fm_now honoured a non-integer FM_NOW: $out"
  out=$(FM_TEST_SEAM=1 FM_NOW='' bash -c '. "$1"; fm_now' _ "$lib") || fail "fm_now failed on an empty FM_NOW"
  [ "$out" -ge "$real" ] || fail "fm_now honoured an empty FM_NOW: $out"
  pass "fm_now reads FM_NOW only under FM_TEST_SEAM=1 and only when it is an integer"
}

test_ack_writes_one_row_and_empty_ack_writes_none() {
  local dir state ledger rows epoch event generation through seqs keys out
  dir=$(make_case ack-row)
  state="$dir/state"
  ledger="$state/wake-ledger.tsv"
  append_wake "$state" signal alpha.status "signal: $state/alpha.status" || fail "append alpha failed"
  append_wake "$state" signal 'beta "quoted" \ key' "signal: beta" || fail "append beta failed"
  append_wake "$state" check "$state/gamma.check.sh" "check: gamma" || fail "append gamma failed"
  [ ! -e "$ledger" ] || fail "an append wrote a wake-ledger row"

  present_and_ack "$state" "$T0"
  [ "$ACKED_THROUGH" = 3 ] || fail "expected an acknowledgement through 3, got $ACKED_THROUGH"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledged rows remained queued"
  rows=$(awk -F '\t' '$2 == "ack"' "$ledger" | wc -l | tr -d ' ')
  [ "$rows" = 1 ] || fail "an acknowledgement of three rows wrote $rows ack rows: $(cat "$ledger")"
  IFS=$'\t' read -r epoch event generation through seqs keys < <(awk -F '\t' '$2 == "ack"' "$ledger")
  [ "$epoch" = "$T0" ] || fail "ack row epoch is not the fixed clock: $epoch"
  [ "$event" = ack ] || fail "ack row event is $event"
  [ "$generation" = "$ACKED_GENERATION" ] || fail "ack row generation $generation is not $ACKED_GENERATION"
  [ "$through" = 3 ] || fail "ack row through is $through"
  [ "$seqs" = 1,2,3 ] || fail "ack row sequence list is $seqs"
  [ "$keys" = "[\"alpha.status\",\"beta \\\"quoted\\\" \\\\ key\",\"$state/gamma.check.sh\"]" ] \
    || fail "ack row keys are not the compact JSON array of the acknowledged keys: $keys"
  awk -F '\t' 'NF != 6 { bad = 1 } END { exit bad }' "$ledger" || fail "a ledger row does not have six columns: $(cat "$ledger")"
  pass "an acknowledgement of three wakes appends one ack row with their sequences and keys"

  cp "$ledger" "$dir/ledger.before"
  drain_at "$state" $((T0 + 5)) --ack-through 3 --recovery-generation "$ACKED_GENERATION" > /dev/null 2>&1 \
    || fail "a repeated acknowledgement failed"
  cmp -s "$ledger" "$dir/ledger.before" || fail "an acknowledgement that removed nothing wrote a ledger row: $(cat "$ledger")"
  pass "an acknowledgement that removes nothing writes no ledger row"

  out=$(ledger_count "$state" "$T0" $((T0 + 1))) || fail "count failed"
  [ "$out" = 'reference=0 highest=3 span=3 unlisted=0 late=0 count=3' ] || fail "unexpected count line: $out"
  rm -f "$state/.wake-queue"
  out=$(ledger_count "$state" "$T0" $((T0 + 1))) || fail "count failed without the queue"
  [ "$out" = 'reference=0 highest=3 span=3 unlisted=0 late=0 count=3' ] || fail "count read the drained queue: $out"
  pass "count derives the acknowledged wake count from the ledger alone"
}

test_consumed_row_names_the_claim_rows_taken_out() {
  local dir state ledger line
  dir=$(make_case consumed-row)
  state="$dir/state"
  ledger="$state/wake-ledger.tsv"
  append_wake "$state" signal one.status "signal: one" || fail "append one failed"
  append_wake "$state" signal two.status "signal: two" || fail "append two failed"
  present_and_ack "$state" "$T0"
  line=$(awk -F '\t' '$2 == "consumed"' "$ledger")
  [ "$(printf '%s\n' "$line" | grep -c .)" = 1 ] || fail "expected one consumed row: $(cat "$ledger")"
  case "$line" in
    "$T0	consumed	$ACKED_GENERATION	2	1,2	[\"one.status\",\"two.status\"]") ;;
    *) fail "consumed row has the wrong fields: $line" ;;
  esac
  [ ! -e "$state/.main-eligible-rows" ] || fail "main claim rows were not consumed"
  pass "consuming the acknowledged claim rows appends one consumed row"
}

test_retired_row_counts_and_unwritten_sequence_does_not() {
  local dir state ledger line out
  dir=$(make_case retired-row)
  state="$dir/state"
  ledger="$state/wake-ledger.tsv"
  append_wake "$state" signal first.status "signal: first" || fail "append first failed"
  # A truncated row keeps its sequence but loses the columns a drain needs.
  printf '%s\t2\tsignal\n' "$T0" >> "$state/.wake-queue"
  printf '2\n' > "$state/.wake-queue.seq"
  # Mint sequence 3 and never write a queue row for it.
  printf '3\n' > "$state/.wake-queue.seq"
  append_wake "$state" signal fourth.status "signal: fourth" || fail "append fourth failed"
  # A row with no usable sequence is retired without a sequence to list.
  printf 'garbage\n' >> "$state/.wake-queue"
  present_and_ack "$state" "$T0"
  line=$(awk -F '\t' '$2 == "retired"' "$ledger")
  [ "$(printf '%s\n' "$line" | grep -c .)" = 1 ] || fail "expected one retired row: $(cat "$ledger")"
  case "$line" in
    "$T0	retired	-	-	2	[\"\"]") ;;
    *) fail "retired row has the wrong fields: $line" ;;
  esac
  awk -F '\t' '$2 == "ack" && $5 == "1,4" { found = 1 } END { exit !found }' "$ledger" \
    || fail "the ack row did not list exactly the acknowledged sequences: $(cat "$ledger")"
  out=$(ledger_count "$state" "$T0" $((T0 + 1))) || fail "count failed"
  [ "$out" = 'reference=0 highest=4 span=4 unlisted=1 late=0 count=3' ] \
    || fail "a retired wake must count and a minted unwritten sequence must not: $out"
  pass "a retired row counts while a minted sequence with no queue row is not counted"
}

test_pruned_rows_and_window_edges() {
  local dir state ledger line out1 out2 rows
  dir=$(make_case pruned-row)
  state="$dir/state"
  ledger="$state/wake-ledger.tsv"
  append_wake "$state" signal keep.status "signal: keep" || fail "append keep failed"
  append_wake "$state" stale test:window-a "stale: test:window-a" || fail "append stale failed"
  append_wake "$state" signal task-a.status "signal: $state/task-a.status" || fail "append status failed"
  prune_at "$state" "$T0" task-a test:window-a || fail "prune failed"
  line=$(awk -F '\t' '$2 == "pruned"' "$ledger")
  case "$line" in
    "$T0	pruned	-	-	2,3	[\"test:window-a\",\"task-a.status\"]") ;;
    *) fail "pruned row has the wrong fields: $line" ;;
  esac
  cp "$ledger" "$dir/ledger.before"
  prune_at "$state" $((T0 + 1)) task-a test:window-a || fail "second prune failed"
  cmp -s "$ledger" "$dir/ledger.before" || fail "a prune that removed nothing wrote a ledger row"
  pass "a task prune appends one pruned row and an empty prune writes none"

  # Sequence 1 is still queued at the end of the first window [T0, T0+100).
  out1=$(ledger_count "$state" "$T0" $((T0 + 100))) || fail "first-window count failed"
  [ "$out1" = 'reference=0 highest=3 span=3 unlisted=1 late=0 count=2' ] \
    || fail "first window must count the pruned wakes and not the still-queued one: $out1"
  present_and_ack "$state" $((T0 + 150))
  out2=$(ledger_count "$state" $((T0 + 100)) $((T0 + 200))) || fail "second-window count failed"
  [ "$out2" = 'reference=3 highest=3 span=0 unlisted=0 late=1 count=1' ] \
    || fail "second window must count the wake its acknowledgement removed, once: $out2"
  out1=$(ledger_count "$state" "$T0" $((T0 + 100))) || fail "first-window recount failed"
  [ "$out1" = 'reference=0 highest=3 span=3 unlisted=1 late=0 count=2' ] \
    || fail "a later removal changed an earlier window's count: $out1"
  out2=$(ledger_count "$state" "$T0" $((T0 + 200))) || fail "union-window count failed"
  [ "$out2" = 'reference=0 highest=3 span=3 unlisted=0 late=0 count=3' ] \
    || fail "the union window must count each of the three wakes once: $out2"
  pass "a wake queued at a window end counts once, in the window of its removal"

  rows=$(ledger_rows "$state" $((T0 + 100)) $((T0 + 200))) || fail "rows failed"
  [ "$rows" = "$(awk -F '\t' -v lo=$((T0 + 100)) -v hi=$((T0 + 200)) '$1 >= lo && $1 < hi' "$ledger")" ] \
    || fail "rows did not print the window rows unchanged: $rows"
  [ -n "$rows" ] || fail "rows printed nothing for a non-empty window"
  rows=$(ledger_rows "$state" $((T0 + 200)) $((T0 + 300))) || fail "rows failed on an empty window"
  [ -z "$rows" ] || fail "rows printed rows outside the window: $rows"
  pass "rows prints exactly the window rows, unchanged"
}

# A branch grant is never re-filtered against the queue, so a granted row a
# prune removed first stays claimed until the branch acknowledges. That claim
# was already counted by the pruned row and must not be counted again.
test_branch_claim_pruned_before_ack_counts_once() {
  local dir state ledger out
  dir=$(make_case branch-pruned-claim)
  state="$dir/state"
  ledger="$state/wake-ledger.tsv"
  append_wake "$state" signal task-a.status "signal: $state/task-a.status" || fail "append status failed"
  append_wake "$state" stale fm-window "stale: fm-window" || fail "append stale failed"
  FM_STATE_OVERRIDE="$state" bash "$ROOT/bin/fm-wake-grant.sh" activate "$$" ledger-scope \
    || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" bash "$ROOT/bin/fm-wake-grant.sh" publish ledger-scope 1 2 \
    || fail "branch grant publication failed"
  prune_at "$state" $((T0 + 50)) task-a "" || fail "prune failed"
  ( export FM_SUPERVISION_ACTOR=branch; present_and_ack "$state" $((T0 + 150)) ) \
    || fail "branch acknowledgement failed"
  awk -F '\t' '$2 == "consumed" { n++; if ($5 != "2") bad = 1 } END { exit (bad || n != 1) }' "$ledger" \
    || fail "want one consumed row naming only the claim the acknowledgement removed: $(cat "$ledger")"
  out=$(ledger_count "$state" "$T0" $((T0 + 100))) || fail "first-window count failed"
  [ "$out" = 'reference=0 highest=1 span=1 unlisted=0 late=0 count=1' ] || fail "first window: $out"
  out=$(ledger_count "$state" $((T0 + 100)) $((T0 + 200))) || fail "second-window count failed"
  [ "$out" = 'reference=1 highest=2 span=1 unlisted=0 late=0 count=1' ] \
    || fail "a pruned branch claim was counted again when the branch acknowledged: $out"
  out=$(ledger_count "$state" "$T0" $((T0 + 200))) || fail "union-window count failed"
  [ "$out" = 'reference=0 highest=2 span=2 unlisted=0 late=0 count=2' ] || fail "union window: $out"
  pass "a branch claim pruned before its acknowledgement counts once"
}

test_prune_without_ledger_library_fails_and_keeps_queue() {
  local dir state bin err
  dir=$(make_case prune-no-ledger-lib)
  state="$dir/state"
  bin="$dir/bin"
  cp -R "$ROOT/bin" "$bin"
  rm -f "$bin/fm-wake-ledger-lib.sh"
  append_wake "$state" signal task-a.status "signal: $state/task-a.status" || fail "append status failed"
  cp "$state/.wake-queue" "$dir/queue.before"
  err="$dir/prune.err"
  if FM_STATE_OVERRIDE="$state" FM_TEST_SEAM=1 FM_NOW="$T0" \
    bash -c '. "$0/fm-wake-lib.sh"; fm_wake_queue_prune_task "$1" "$2" ""' "$bin" "$state" task-a 2> "$err"; then
    fail "a prune without the ledger library reported success"
  fi
  [ -s "$err" ] || fail "a prune without the ledger library printed no error"
  cmp -s "$state/.wake-queue" "$dir/queue.before" || fail "a prune without the ledger library removed queue rows"
  [ ! -e "$state/wake-ledger.tsv" ] || fail "a prune without the ledger library wrote a ledger"
  pass "a prune without the ledger library fails and leaves the queue unchanged"
}

# A ledger that cannot take a row (here a directory in its place) must never
# let a removal take its wakes out uncounted: each removal path leaves the
# queue as it was and says so, and the same removal succeeds, with its row,
# once the ledger is writable again.
test_unwritable_ledger_keeps_removed_wakes() {
  local dir state ledger err rc
  dir=$(make_case unwritable-ledger)
  state="$dir/state"
  ledger="$state/wake-ledger.tsv"
  err="$dir/step.err"

  append_wake "$state" signal one.status "signal: one" || fail "append one failed"
  append_wake "$state" signal two.status "signal: two" || fail "append two failed"
  present_at "$state" "$T0"
  mkdir "$ledger"
  cp "$state/.wake-queue" "$dir/queue.before"
  drain_at "$state" "$T0" --ack-through "$PRESENTED_THROUGH" --recovery-generation "$PRESENTED_GENERATION" \
    > /dev/null 2> "$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an acknowledgement whose ledger row could not be written reported success"
  [ -s "$err" ] || fail "an acknowledgement whose ledger row could not be written printed no error"
  cmp -s "$state/.wake-queue" "$dir/queue.before" \
    || fail "an acknowledgement whose ledger row could not be written removed queue rows"
  rmdir "$ledger"
  drain_at "$state" "$T0" --ack-through "$PRESENTED_THROUGH" --recovery-generation "$PRESENTED_GENERATION" \
    > /dev/null 2> "$err" || fail "the repeated acknowledgement failed: $(cat "$err")"
  [ ! -s "$state/.wake-queue" ] || fail "the repeated acknowledgement left rows queued"
  awk -F '\t' '$2 == "ack" && $5 == "1,2" { n++ } END { exit n != 1 }' "$ledger" \
    || fail "the repeated acknowledgement did not write one ack row for 1,2: $(cat "$ledger")"
  pass "an acknowledgement that cannot write its ledger row fails, keeps its wakes, and succeeds on retry"

  rm -f "$ledger"
  append_wake "$state" signal three.status "signal: three" || fail "append three failed"
  printf '%s\t4\tsignal\n' "$T0" >> "$state/.wake-queue"
  printf '4\n' > "$state/.wake-queue.seq"
  mkdir "$ledger"
  drain_at "$state" "$T0" > /dev/null 2> "$err" || fail "a presentation drain failed on an unwritable ledger: $(cat "$err")"
  grep -q 'could not be retired' "$err" || fail "an unwritten retirement was not reported: $(cat "$err")"
  awk -F '\t' '$2 == "4" && NF < 5 { found = 1 } END { exit !found }' "$state/.wake-queue" \
    || fail "a retirement whose ledger row could not be written removed the row"
  rmdir "$ledger"
  drain_at "$state" "$T0" > /dev/null 2> "$err" || fail "the repeated presentation drain failed: $(cat "$err")"
  awk -F '\t' '$2 == "4" && NF < 5 { found = 1 } END { exit found }' "$state/.wake-queue" \
    || fail "the repeated drain did not retire the row"
  awk -F '\t' '$2 == "retired" && $5 == "4" { n++ } END { exit n != 1 }' "$ledger" \
    || fail "the repeated drain did not write one retired row for 4: $(cat "$ledger")"
  pass "a retirement that cannot write its ledger row keeps the row, reports it, and retires it once the ledger is writable"

  rm -f "$ledger"
  append_wake "$state" signal task-a.status "signal: $state/task-a.status" || fail "append task-a failed"
  cp "$state/.wake-queue" "$dir/queue.before"
  mkdir "$ledger"
  if prune_at "$state" "$T0" task-a "" 2> "$err"; then
    fail "a prune whose ledger row could not be written reported success"
  fi
  [ -s "$err" ] || fail "a prune whose ledger row could not be written printed no error"
  cmp -s "$state/.wake-queue" "$dir/queue.before" || fail "a prune whose ledger row could not be written removed queue rows"
  rmdir "$ledger"
  prune_at "$state" "$T0" task-a "" 2> "$err" || fail "the repeated prune failed: $(cat "$err")"
  awk -F '\t' '$2 == "pruned" { n++ } END { exit n != 1 }' "$ledger" \
    || fail "the repeated prune did not write one pruned row: $(cat "$ledger")"
  pass "a prune that cannot write its ledger row fails, keeps its wakes, and succeeds on retry"
}

# The ack row carries the epoch of the removal itself. The drain does work
# between taking the queue lock and removing the acknowledged rows; here its
# chmod of the acknowledgement scratch file takes two seconds, so a row stamped
# at lock time would land before that work ended. This runs on the real clock.
test_ack_row_epoch_is_the_removal_time() {
  local dir state ledger shim real_chmod log epoch ended
  dir=$(make_case removal-epoch)
  state="$dir/state"
  ledger="$state/wake-ledger.tsv"
  shim="$dir/shim"
  log="$dir/chmod.log"
  real_chmod=$(command -v chmod) || fail "no chmod on PATH"
  mkdir -p "$shim"
  cat > "$shim/chmod" <<EOF
#!/bin/sh
case "\$*" in
  *.wake-queue.ack.*) sleep 2; "$real_chmod" "\$@" || exit \$?; date +%s >> "$log"; exit 0 ;;
esac
exec "$real_chmod" "\$@"
EOF
  "$real_chmod" 0755 "$shim/chmod"
  append_wake "$state" signal slow.status "signal: slow" || fail "append slow failed"
  present_at "$state" "$T0"
  PATH="$shim:$PATH" FM_STATE_OVERRIDE="$state" bash "$DRAIN" \
    --ack-through "$PRESENTED_THROUGH" --recovery-generation "$PRESENTED_GENERATION" > /dev/null 2>&1 \
    || fail "the acknowledgement failed"
  [ -s "$log" ] || fail "the acknowledgement never ran the slowed chmod, so the case proves nothing"
  ended=$(head -n 1 "$log")
  epoch=$(awk -F '\t' '$2 == "ack" { print $1 }' "$ledger")
  [ -n "$epoch" ] || fail "the acknowledgement wrote no ack row: $(cat "$ledger" 2>/dev/null)"
  [ "$epoch" -ge "$ended" ] \
    || fail "the ack row epoch $epoch is before the removal work ended at $ended: it was stamped at lock time"
  pass "the ack row carries the removal time, not the lock-acquire time"
}

# A removal whose ledger row cannot be computed must not happen: when a stage
# of the row extraction fails (here its sort exits non-zero), the
# acknowledgement fails, reports on stderr, and leaves its wakes queued.
test_failed_row_extraction_keeps_removed_wakes() {
  local dir state shim real_sort err rc
  dir=$(make_case failed-extraction)
  state="$dir/state"
  shim="$dir/shim"
  err="$dir/step.err"
  real_sort=$(command -v sort) || fail "no sort on PATH"
  mkdir -p "$shim"
  cat > "$shim/sort" <<EOF
#!/bin/sh
case "\$*" in
  *-k1,1n\ -u*) echo hit >> "$dir/sort.hits"; exit 1 ;;
esac
exec "$real_sort" "\$@"
EOF
  chmod 0755 "$shim/sort"
  append_wake "$state" signal one.status "signal: one" || fail "append one failed"
  present_at "$state" "$T0"
  cp "$state/.wake-queue" "$dir/queue.before"
  PATH="$shim:$PATH" drain_at "$state" "$T0" --ack-through "$PRESENTED_THROUGH" \
    --recovery-generation "$PRESENTED_GENERATION" > /dev/null 2> "$err"; rc=$?
  [ -s "$dir/sort.hits" ] || fail "the acknowledgement never ran the failing sort, so the case proves nothing"
  [ "$rc" -ne 0 ] || fail "an acknowledgement whose row extraction failed reported success"
  [ -s "$err" ] || fail "an acknowledgement whose row extraction failed printed no error"
  cmp -s "$state/.wake-queue" "$dir/queue.before" \
    || fail "an acknowledgement whose row extraction failed removed queue rows"
  [ ! -s "$state/wake-ledger.tsv" ] || fail "a failed extraction wrote a ledger row: $(cat "$state/wake-ledger.tsv")"
  pass "a removal whose row extraction fails stops, reports it, and keeps its wakes"
}

# The consumed-row extraction follows the same rule: when its sort fails, the
# acknowledgement fails and leaves the claim file as it was.
test_failed_consumed_extraction_keeps_claim_rows() {
  local dir state shim real_sort err rc
  dir=$(make_case failed-consumed-extraction)
  state="$dir/state"
  shim="$dir/shim"
  err="$dir/step.err"
  real_sort=$(command -v sort) || fail "no sort on PATH"
  mkdir -p "$shim"
  cat > "$shim/sort" <<EOF
#!/bin/sh
[ "\$*" = "-n -u" ] && { echo hit >> "$dir/sort.hits"; exit 1; }
exec "$real_sort" "\$@"
EOF
  chmod 0755 "$shim/sort"
  append_wake "$state" signal one.status "signal: one" || fail "append one failed"
  present_at "$state" "$T0"
  [ -s "$state/.main-eligible-rows" ] || fail "the presentation left no claim rows to consume"
  cp "$state/.main-eligible-rows" "$dir/claim.before"
  PATH="$shim:$PATH" drain_at "$state" "$T0" --ack-through "$PRESENTED_THROUGH" \
    --recovery-generation "$PRESENTED_GENERATION" > /dev/null 2> "$err"; rc=$?
  [ -s "$dir/sort.hits" ] || fail "the acknowledgement never ran the failing sort, so the case proves nothing"
  [ "$rc" -ne 0 ] || fail "an acknowledgement whose consumed extraction failed reported success"
  cmp -s "$state/.main-eligible-rows" "$dir/claim.before" \
    || fail "an acknowledgement whose consumed extraction failed changed the claim rows"
  ! awk -F '\t' '$2 == "consumed"' "$state/wake-ledger.tsv" 2>/dev/null | grep -q . \
    || fail "a failed consumed extraction wrote a consumed row: $(cat "$state/wake-ledger.tsv")"
  pass "a consumed extraction that fails stops and keeps the claim rows"
}

# A removal interrupted after its ledger row was written but before its queue
# change (here the drain is killed at the queue replace) leaves the row in the
# ledger and the wake still queued. The retry in a later window must write no
# second row for that wake, so the wake counts once in the union window and
# once in the sum of the two windows.
test_retry_after_interrupted_removal_counts_once() {
  local dir state ledger shim real_mv err out first second
  dir=$(make_case interrupted-removal)
  state="$dir/state"
  ledger="$state/wake-ledger.tsv"
  shim="$dir/shim"
  err="$dir/step.err"
  real_mv=$(command -v mv) || fail "no mv on PATH"
  mkdir -p "$shim"
  cat > "$shim/mv" <<EOF
#!/bin/sh
case "\$*" in
  *.wake-queue.ack.*) kill -KILL "\$PPID"; exit 137 ;;
esac
exec "$real_mv" "\$@"
EOF
  chmod 0755 "$shim/mv"
  append_wake "$state" signal one.status "signal: one" || fail "append one failed"
  present_at "$state" "$T0"
  PATH="$shim:$PATH" drain_at "$state" "$T0" --ack-through "$PRESENTED_THROUGH" \
    --recovery-generation "$PRESENTED_GENERATION" > /dev/null 2>&1 \
    && fail "the interrupted acknowledgement reported success"
  awk -F '\t' -v t="$T0" '$1 == t && $2 == "ack" && $5 == "1" { n++ } END { exit n != 1 }' "$ledger" \
    || fail "the interruption did not leave the ack row in the ledger: $(cat "$ledger" 2>/dev/null)"
  awk -F '\t' '$2 == "1" { found = 1 } END { exit !found }' "$state/.wake-queue" \
    || fail "the interruption did not leave the wake queued, so the case proves nothing"

  present_at "$state" $((T0 + 100))
  drain_at "$state" $((T0 + 100)) --ack-through "$PRESENTED_THROUGH" \
    --recovery-generation "$PRESENTED_GENERATION" > /dev/null 2> "$err" \
    || fail "the retried acknowledgement failed: $(cat "$err")"
  awk -F '\t' '$2 == "1" { found = 1 } END { exit found }' "$state/.wake-queue" \
    || fail "the retried acknowledgement left the wake queued"
  awk -F '\t' -v t=$((T0 + 100)) '$1 == t { bad = 1 } END { exit bad }' "$ledger" \
    || fail "the retry wrote a second row for an already-listed wake: $(cat "$ledger")"
  first=$(ledger_count "$state" "$T0" $((T0 + 100))) || fail "first-window count failed"
  second=$(ledger_count "$state" $((T0 + 100)) $((T0 + 200))) || fail "second-window count failed"
  [ $(( ${first##*count=} + ${second##*count=} )) = 1 ] \
    || fail "the per-window counts sum to more than one wake: $first / $second"
  out=$(ledger_count "$state" "$T0" $((T0 + 200))) || fail "union-window count failed"
  [ "${out##*count=}" = 1 ] || fail "the union window does not count one wake: $out"
  pass "a retry after an interrupted removal writes no second row, so the wake counts once"
}

# The public append interface reads fm_now on every call: an epoch a removal
# used earlier in the same shell is never reused for a later direct append.
test_direct_append_reads_the_clock_each_call() {
  local dir state ledger out
  dir=$(make_case direct-append-clock)
  state="$dir/state"
  ledger="$state/wake-ledger.tsv"
  out=$(FM_TEST_SEAM=1 bash -c '
    . "$1/bin/fm-wake-ledger-lib.sh"
    export FM_NOW=100
    fm_wake_ledger_commit_removal_locked "$2" ack - - "$(printf "1\t7\tsignal\tk7\tp")" "" true || exit 1
    FM_NOW=200
    fm_wake_ledger_append_locked "$2" pruned - - 8 "[\"k8\"]" || exit 1
  ' _ "$ROOT" "$state" 2>&1) || fail "the direct append case failed: $out"
  awk -F '\t' '$2 == "ack" && $5 == "7" && $1 == "100" { n++ } END { exit n != 1 }' "$ledger" \
    || fail "the removal row does not carry the first clock value: $(cat "$ledger")"
  awk -F '\t' '$2 == "pruned" && $5 == "8" { print $1 }' "$ledger" | grep -qx 200 \
    || fail "a later direct append reused an earlier removal epoch: $(cat "$ledger")"
  pass "a direct append reads the clock on every call, never an earlier removal epoch"
}

test_ledger_command_contract() {
  local dir state out rc
  dir="$TMP_ROOT/command"
  state="$dir/state"
  mkdir -p "$state"
  out=$(ledger_count "$state" "$T0" $((T0 + 10))) || fail "count failed on an absent ledger"
  [ "$out" = 'reference=0 highest=0 span=0 unlisted=0 late=0 count=0' ] || fail "absent ledger count: $out"
  out=$(ledger_rows "$state" "$T0" $((T0 + 10))) || fail "rows failed on an absent ledger"
  [ -z "$out" ] || fail "rows printed output for an absent ledger: $out"
  FM_STATE_OVERRIDE="$state" bash "$LEDGER" count --since "$T0" > /dev/null 2>&1; rc=$?
  [ "$rc" = 1 ] || fail "count without --until exited $rc"
  FM_STATE_OVERRIDE="$state" bash "$LEDGER" count --since x --until "$T0" > /dev/null 2>&1; rc=$?
  [ "$rc" = 1 ] || fail "count with a non-integer --since exited $rc"
  FM_STATE_OVERRIDE="$state" bash "$LEDGER" bogus > /dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] || fail "an unknown subcommand exited $rc"
  # Home resolution follows fm-dispatch-log.sh: FM_HOME selects the home.
  mkdir -p "$dir/home/state"
  printf '%s\tack\tg1\t7\t5,7\t["a","b"]\n' "$T0" > "$dir/home/state/wake-ledger.tsv"
  out=$(FM_HOME="$dir/home" bash "$LEDGER" count --since "$T0" --until $((T0 + 1))) || fail "FM_HOME count failed"
  [ "$out" = 'reference=0 highest=7 span=7 unlisted=5 late=0 count=2' ] || fail "FM_HOME count: $out"
  pass "the ledger command resolves its home, reads an absent ledger as empty, and refuses bad arguments"
}

test_fm_now_fixed_clock_seam
test_ack_writes_one_row_and_empty_ack_writes_none
test_consumed_row_names_the_claim_rows_taken_out
test_retired_row_counts_and_unwritten_sequence_does_not
test_pruned_rows_and_window_edges
test_branch_claim_pruned_before_ack_counts_once
test_prune_without_ledger_library_fails_and_keeps_queue
test_unwritable_ledger_keeps_removed_wakes
test_ack_row_epoch_is_the_removal_time
test_failed_row_extraction_keeps_removed_wakes
test_failed_consumed_extraction_keeps_claim_rows
test_retry_after_interrupted_removal_counts_once
test_direct_append_reads_the_clock_each_call
test_ledger_command_contract
