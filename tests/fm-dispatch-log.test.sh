#!/usr/bin/env bash
# tests/fm-dispatch-log.test.sh - bin/fm-dispatch-log.sh records captain-goal
# intake, dispatch, and explicit blockers as an append-only timestamped ledger,
# and `overdue` flags every goal still undispatched and unblocked past the
# dispatch SLA, while refusing malformed requests without writing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DL="$ROOT/bin/fm-dispatch-log.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-log-tests)
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"
LOG="$STATE/dispatch-log.tsv"
T0=1800000000

dl() {  # <now-epoch> <args...>
  local now=$1
  shift
  FM_STATE_OVERRIDE="$STATE" FM_DISPATCH_NOW="$now" bash "$DL" "$@"
}

dl "$T0" received g1 --summary 'polished V2 video' --project shipcontent-v2 >/dev/null \
  || fail "received refused a well-formed goal"
[ "$(wc -l < "$LOG" | tr -d ' ')" = 1 ] || fail "received did not append exactly one line"
IFS=$'\t' read -r iso epoch ev goal detail < "$LOG"
[ "$epoch" = "$T0" ] && [ "$ev" = received ] && [ "$goal" = g1 ] \
  || fail "received line has wrong fields: $(cat "$LOG")"
case "$iso" in 2027-01-15T08:00:00Z) ;; *) fail "received line has wrong iso time: $iso" ;; esac
case "$detail" in 'project=shipcontent-v2 summary=polished V2 video') ;; *) fail "wrong detail: $detail" ;; esac
pass "received appends one timestamped TSV line with project and summary"

dl $((T0 + 600)) overdue >/dev/null; rc=$?
[ "$rc" = 0 ] || fail "a 10-minute-old goal was reported overdue (rc=$rc)"
out=$(dl $((T0 + 16 * 60)) overdue); rc=$?
[ "$rc" = 3 ] || fail "a 16-minute-old undispatched goal did not exit 3 (rc=$rc)"
case "$out" in 'OVERDUE g1 age=16m received=2027-01-15T08:00:00Z project=shipcontent-v2 summary=polished V2 video') ;;
  *) fail "unexpected overdue line: $out" ;; esac
pass "overdue stays quiet inside the 15-minute SLA and flags the goal after it"

out=$(FM_DISPATCH_SLA_MINUTES=30 dl $((T0 + 16 * 60)) overdue); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] || fail "FM_DISPATCH_SLA_MINUTES=30 did not widen the SLA"
out=$(FM_DISPATCH_SLA_MINUTES=5 FM_STATE_OVERRIDE="$STATE" FM_DISPATCH_NOW=$((T0 + 6 * 60)) bash "$DL" overdue); rc=$?
[ "$rc" = 3 ] || fail "FM_DISPATCH_SLA_MINUTES=5 did not tighten the SLA"
pass "FM_DISPATCH_SLA_MINUTES widens and tightens the SLA"

dl $((T0 + 700)) dispatched g1 --task shipcontent-polished-first-video >/dev/null \
  || fail "dispatched refused a received goal"
out=$(dl $((T0 + 3600)) overdue); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] || fail "a dispatched goal is still overdue: $out"
pass "a dispatched goal is never overdue"

dl "$T0" received g2 --summary 'audit' >/dev/null || fail "second goal refused"
dl $((T0 + 300)) blocked g2 --reason 'grok quota at fair-share floor' >/dev/null \
  || fail "blocked refused a received goal"
out=$(dl $((T0 + 3600)) overdue); rc=$?
[ "$rc" = 0 ] || fail "an explicitly blocked goal was reported overdue: $out"
[ "$(dl 0 show g2 | tail -n 1 | cut -f3,5)" = $'blocked\treason=grok quota at fair-share floor' ] \
  || fail "show did not return the blocked line"
dl $((T0 + 4000)) dispatched g2 --task audit-r2 --note 'quota reset' >/dev/null \
  || fail "dispatched refused a previously blocked goal"
[ "$(dl 0 show g2 | tail -n 1 | cut -f3)" = dispatched ] || fail "dispatch did not supersede the block"
pass "blocked is a logged, non-overdue outcome that a later dispatch supersedes"

before=$(wc -l < "$LOG" | tr -d ' ')
dl "$T0" received g1 --summary dup >/dev/null 2>&1 && fail "a duplicate received was accepted"
dl "$T0" received 'bad id' --summary x >/dev/null 2>&1 && fail "a malformed goal id was accepted"
dl "$T0" received g3 >/dev/null 2>&1 && fail "received without --summary was accepted"
dl "$T0" dispatched nope --task t >/dev/null 2>&1 && fail "dispatched for an unknown goal was accepted"
dl "$T0" dispatched g1 >/dev/null 2>&1 && fail "dispatched without --task was accepted"
dl "$T0" blocked g1 >/dev/null 2>&1 && fail "blocked without --reason was accepted"
FM_DISPATCH_SLA_MINUTES=x dl "$T0" overdue >/dev/null 2>&1 && fail "a non-numeric FM_DISPATCH_SLA_MINUTES was accepted"
dl "$T0" overdue --minutes 30 >/dev/null 2>&1 && fail "the removed --minutes flag was accepted"
[ "$(wc -l < "$LOG" | tr -d ' ')" = "$before" ] || fail "a refused request wrote to the ledger"
pass "malformed, duplicate, and orphan requests are refused without writing"

dl "$T0" received g4 --summary $'two\tfields\nand lines' >/dev/null || fail "free text with tabs refused"
[ "$(tail -n 1 "$LOG" | awk -F '\t' '{ print NF }')" = 5 ] || fail "free text broke the TSV shape"
pass "tabs and newlines in free text are folded so every line stays five fields"

dl $((T0 + 60)) dispatched g4 --task t4 >/dev/null || fail "g4 dispatch refused"
dl "$T0" received late1 --summary 'late dispatch' >/dev/null || fail "late1 refused"
out=$(dl $((T0 + 66 * 60)) dispatched late1 --task t-late) || fail "a late dispatch was refused"
case "$out" in *'LATE late1 late=66m'*) ;; *) fail "a late dispatch did not print LATE: $out" ;; esac
[ "$(dl 0 show late1 | tail -n 1 | cut -f5)" = 'task=t-late late=66m' ] \
  || fail "show did not carry the late mark: $(dl 0 show late1)"
dl "$T0" received late2 --summary 'late block' >/dev/null || fail "late2 refused"
dl $((T0 + 20 * 60)) blocked late2 --reason 'no quota' >/dev/null || fail "a late block was refused"
out=$(dl $((T0 + 90 * 60)) overdue); rc=$?
[ "$rc" = 0 ] || fail "late-resolved goals made overdue exit $rc"
case "$out" in *'LATE late1 late=66m event=dispatched'*'LATE late2 late=20m event=blocked'*) ;;
  *) fail "overdue did not surface late resolutions: $out" ;; esac
dl "$T0" received ontime --summary 'on time' >/dev/null || fail "ontime refused"
out=$(dl $((T0 + 900)) dispatched ontime --task t-ok) || fail "on-time dispatch refused"
case "$out" in *LATE*) fail "a dispatch at exactly the SLA was marked late: $out" ;; esac
pass "a dispatched or blocked line written after the SLA records late=<m>m, and show and overdue surface it"

dl "$T0" received g1 --summary dup >/dev/null 2>&1; rc=$?
[ "$rc" = 4 ] || fail "a duplicate received exited $rc, not 4"
dl "$T0" received 'bad id' --summary x >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] || fail "a malformed id exited $rc, not 1"
pass "a duplicate received exits 4, distinct from other refusals"

dl "$T0" received q1 --summary 'waits behind a running ship' >/dev/null || fail "q1 refused"
dl $((T0 + 300)) queued q1 --reason 'project capacity full' >/dev/null || fail "queued refused"
[ "$(dl 0 show q1 | tail -n 1 | cut -f3,5)" = $'queued\treason=project capacity full' ] \
  || fail "queued line has wrong fields: $(dl 0 show q1)"
dl $((T0 + 600)) overdue >/dev/null; rc=$?
[ "$rc" = 0 ] || fail "a queued goal inside the SLA was overdue (rc=$rc)"
out=$(dl $((T0 + 16 * 60)) overdue); rc=$?
[ "$rc" = 3 ] || fail "a queued goal past the SLA did not exit 3 (rc=$rc)"
case "$out" in *'OVERDUE q1 age=16m'*) ;; *) fail "queued goal missing from overdue: $out" ;; esac
dl $((T0 + 17 * 60)) dispatched q1 --task secondmate:infra >/dev/null || fail "secondmate hand-off refused"
out=$(dl $((T0 + 18 * 60)) overdue); rc=$?
case "$out" in *'OVERDUE q1'*) fail "a dispatched queued goal stayed overdue: $out" ;; esac
dl "$T0" queued nope --reason x >/dev/null 2>&1 && fail "queued for an unknown goal was accepted"
dl "$T0" queued q1 >/dev/null 2>&1 && fail "queued without --reason was accepted"
pass "queued is a non-final state that still goes overdue, and a secondmate hand-off dispatches it"
