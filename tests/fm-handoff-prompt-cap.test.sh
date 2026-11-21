#!/usr/bin/env bash
# Handoff and restart prompts name the document by path and warn above 60 lines.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-handoff-prompt-cap)
trap fm_test_cleanup EXIT

# shellcheck source=bin/fm-handoff-lib.sh
. "$ROOT/bin/fm-handoff-lib.sh"
# shellcheck source=bin/fm-watchdog-lib.sh
. "$ROOT/bin/fm-watchdog-lib.sh"

SENTINEL='UNIQUE_HANDOFF_BODY_SENTINEL_wake_budget'
short=$TMP_ROOT/short.md
sixty=$TMP_ROOT/sixty.md
long=$TMP_ROOT/long.md
odd="$TMP_ROOT/handoff ) '.md"
printf 'short handoff\n' > "$short"
seq 1 10 > "$TMP_ROOT/ten.md"
seq 1 60 > "$sixty"
{ seq 1 60; printf '%s\n' "$SENTINEL"; } > "$long"
printf '%s\n' "$SENTINEL" > "$odd"

[ "$(fm_handoff_prompt_line_cap)" = 60 ] || fail "line cap is $(fm_handoff_prompt_line_cap)"

err=$(fm_handoff_warn_line_cap "$TMP_ROOT/ten.md" 2>&1)
[ -z "$err" ] || fail "10 lines warned: $err"
err=$(fm_handoff_warn_line_cap "$sixty" 2>&1)
[ -z "$err" ] || fail "60 lines warned: $err"
assign="$TMP_ROOT/handoff=1.md"
seq 1 61 > "$assign"
err=$( ( cd "$TMP_ROOT" && fm_handoff_warn_line_cap 'handoff=1.md' ) 2>&1 )
case "$err" in
  *"is 61 lines, above the 60-line launch cap"*) ;;
  *) fail "an awk-assignment path did not warn: $err" ;;
esac
err=$(fm_handoff_warn_line_cap "$long" 2>&1)
case "$err" in
  *"is 61 lines, above the 60-line launch cap"*) ;;
  *) fail "61 lines did not warn: $err" ;;
esac
case "$err" in
  *"$SENTINEL"*) fail "warning inlined the document: $err" ;;
esac

prompt=$(fm_handoff_successor_prompt "$odd" sha256 ack-cmd start-cmd nonce)
case "$prompt" in
  "Firstmate handoff successor. Read the entire document at $odd."*) ;;
  *) fail "successor prompt does not name the path: $prompt" ;;
esac
case "$prompt" in
  *"$SENTINEL"*) fail "successor prompt inlined the document" ;;
esac
case "$prompt" in
  *$'\n'*) fail "successor prompt gained a newline" ;;
esac

wprompt=$(fm_wd_restart_prompt "$long" /tmp/home /tmp/bin tok 2>"$TMP_ROOT/wd.err")
case "$wprompt" in
  "Watchdog restart of this firstmate home. Read $long first,"*) ;;
  *) fail "restart prompt does not name the path: $wprompt" ;;
esac
case "$wprompt" in
  *"$SENTINEL"*) fail "restart prompt inlined the document" ;;
esac
grep -q 'above the 60-line launch cap' "$TMP_ROOT/wd.err" || fail "restart did not warn: $(cat "$TMP_ROOT/wd.err")"
! grep -q "$SENTINEL" "$TMP_ROOT/wd.err" || fail "restart warning inlined the document"

LAB=$TMP_ROOT/home
mkdir -p "$LAB/state" "$LAB/config" "$LAB/data"
hostile="$LAB/handoff ) '.md"
{ seq 1 60; printf '%s\n' "$SENTINEL"; } > "$hostile"
rc=0
FM_HOME="$LAB" bash "$ROOT/bin/fm-handoff-launch.sh" "$hostile" >"$TMP_ROOT/launch.out" 2>"$TMP_ROOT/launch.err" || rc=$?
[ "$rc" -ne 0 ] || fail "unlocked launch succeeded"
grep -q 'only the current session lock owner or its watcher can launch its successor' "$TMP_ROOT/launch.err" \
  || fail "lock refusal missing: $(cat "$TMP_ROOT/launch.err")"
grep -q 'above the 60-line launch cap' "$TMP_ROOT/launch.err" \
  || fail "launch did not warn: $(cat "$TMP_ROOT/launch.err")"
! grep -q "$SENTINEL" "$TMP_ROOT/launch.out" "$TMP_ROOT/launch.err" || fail "launch inlined the document"
pass 'handoff prompts name the path, warn above 60 lines, and do not inline the document'
