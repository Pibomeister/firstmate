#!/usr/bin/env bash
# fm-resume-doorbell.sh - start a turn in an idle primary after a Claude auto
# compaction, with no model call.
#
# An idle auto compaction runs the SessionStart hook (source=compact), whose
# context re-emit reaches the model only when its next turn starts - and
# nothing starts one. bin/fm-sessionstart-run.sh launches this script detached;
# docs/sessionstart-nudge.md owns when.
#
# It waits FM_RESUME_DOORBELL_SETTLE_SECS (default 20) for the session to
# settle, then polls every FM_RESUME_DOORBELL_POLL_SECS (default 5), at most
# FM_RESUME_DOORBELL_WAIT_SECS (default 120) in all, until the target in
# state/captain-handle is provably idle: its agent is alive, its composer is
# empty, its backend reports native idle, and the session transcript
# (--transcript), when given, has not grown for one poll. A backend with no
# native busy state never qualifies, so the doorbell stands down there.
# It then writes the resume instruction to a shared operational-input record
# (bin/fm-operational-input.sh "Record-backed carrier", kind session-start)
# and types the constant ASCII doorbell naming that record - Claude strips the
# invisible protocol mark from typed prompts, and the doorbell text alone
# proves nothing, so the prompt the primary submits classifies as Firstmate
# operational input and the host mirror never records it as captain dialog -
# and confirms the submit: a pending or pending-unproven first verdict is the
# only one that earns resubmit Enters, at most
# FM_RESUME_DOORBELL_RESUBMIT_TRIES times (default 2)
# FM_RESUME_DOORBELL_RESUBMIT_DELAY seconds apart (default 1.5, clear of the
# paste window) and only while the composer holds exactly that doorbell line;
# every other unproven verdict (unknown, unconfirmed, a named dialog) finishes
# unverified with zero extra Enters. A submit whose payload check fails never
# erases the composer: this process refuses every composer-clear the sourced
# backend defines, so operator text typed while the doorbell settled survives
# and the run fails closed as unverified. It reports submitted only once the
# composer reads empty or the agent reads busy.
#
# It stands down, typing nothing, when the session lock changes owner, an away
# or quiet record exists, state/.context-epoch no longer matches the one seen at
# start (a /clear or another compaction began a new context), a Stop claimed
# after the compaction (a turn already ran), the handle is unreadable or older
# than the session lock, the agent is not alive, the composer is not empty, a
# turn is running (native busy, a rendered busy footer, or an assistant record
# after the newest compact boundary in the transcript), idleness cannot be
# proven before the wait limit, or another doorbell holds or takes over
# state/.resume-doorbell.lock. A doorbell started under a newer context waits,
# bounded, for a live one started under an older context to stand down and
# then takes the lock; each poll re-reads
# the lock's pid, so of two doorbells that both cleared a stale lock only the
# last one types, and a doorbell removes the lock on exit only while it still
# names it. The context epoch also names the session lock owner that recorded
# it, and a different owner stands the doorbell down. The lock owner, doorbell
# lock, away or quiet record and context epoch are re-checked right before
# every keystroke, inside the shared send helper and adapter too (the call that
# issues each keystroke is wrapped in this process); a change withholds the
# keystroke, and logs stood-down before anything was typed or unverified after. Every run appends one row to
# state/.resume-doorbell.log:
#   <utc-iso>\t<epoch>\t<source>\t<backend>:<target>\t<outcome>\t<detail>
# with outcome submitted, unverified, stood-down or failed. It never kills,
# interrupts or signals anything, and it exits 0.
#
# Test seam, honoured only with FM_TEST_SEAM=1: FM_RESUME_DOORBELL_TEST_LIB is
# sourced after bin/fm-backend.sh so a suite can replace the backend reads and
# keystrokes.
#
# --epoch-sum is the cksum(1) output of state/.context-epoch as the launching
# hook recorded it (or "absent"). A doorbell whose context differs from that by
# the time it pins it stands down, so a /clear between launch and start cannot
# become its context.
#
# Usage: fm-resume-doorbell.sh [--source <source>] [--transcript <path>] [--epoch-sum <cksum>]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

FM_RESUME_DOORBELL_BODY='Firstmate resume after context compaction: re-read state and open goals (run bin/fm-wake-drain.sh and bin/fm-order.sh pickup), then continue the open work.'

SOURCE=compact
TRANSCRIPT=
EXPECTED_EPOCH_SUM=
while [ $# -gt 0 ]; do
  case "$1" in
    --source) SOURCE=${2:-compact}; shift; [ $# -eq 0 ] || shift ;;
    --transcript) TRANSCRIPT=${2:-}; shift; [ $# -eq 0 ] || shift ;;
    --epoch-sum) EXPECTED_EPOCH_SUM=${2:-}; shift; [ $# -eq 0 ] || shift ;;
    -h|--help) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) shift ;;
  esac
done

int_or() {  # <value> <default>: a whole number of seconds or tries
  case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}
secs_or() {  # <value> <default>: a sleep(1) duration such as 5 or 0.2
  if printf '%s' "$1" | grep -Eq '^[0-9]+([.][0-9]+)?$'; then printf '%s' "$1"; else printf '%s' "$2"; fi
}
SETTLE=$(secs_or "${FM_RESUME_DOORBELL_SETTLE_SECS:-}" 20)
POLL=$(secs_or "${FM_RESUME_DOORBELL_POLL_SECS:-}" 5)
WAIT=$(int_or "${FM_RESUME_DOORBELL_WAIT_SECS:-}" 120)
TRIES=$(int_or "${FM_RESUME_DOORBELL_RESUBMIT_TRIES:-}" 2)
RESUBMIT_DELAY=$(secs_or "${FM_RESUME_DOORBELL_RESUBMIT_DELAY:-}" 1.5)
LOG="$STATE/.resume-doorbell.log"
LOCK="$STATE/.resume-doorbell.lock"
BACKEND=
TARGET=

log_row() {  # <outcome> <detail>
  local detail
  detail=$(printf '%s' "$2" | tr '\t\r\n' '   ')
  printf '%s\t%s\t%s\t%s:%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date +%s)" \
    "$SOURCE" "${BACKEND:-none}" "${TARGET:-none}" "$1" "$detail" >> "$LOG" 2>/dev/null || true
}

finish() {  # <outcome> <detail>
  log_row "$1" "$2"
  exit 0
}

[ -d "$STATE" ] || exit 0

current_epoch_sum() {
  if [ -e "$STATE/.context-epoch" ]; then
    cksum < "$STATE/.context-epoch" 2>/dev/null || true
  else
    printf 'absent'
  fi
}
# Checked before the lock too, so a doorbell for a context already gone never
# takes a live lock over.
if [ -n "$EXPECTED_EPOCH_SUM" ] && [ "$(current_epoch_sum)" != "$EXPECTED_EPOCH_SUM" ]; then
  finish stood-down "a new context began after the compaction"
fi

# Single flight: a second doorbell while one is live types nothing, unless the
# live one was started under an older context. That one stands down at its
# next check (its pinned epoch was replaced) and removes the lock, so this
# newer doorbell waits for it to exit, bounded, and then takes the lock afresh
# rather than both standing down. No doorbell ever rewrites a live holder's
# lock.
holder_wait_deadline=$(( $(date +%s) + ${SETTLE%.*} + WAIT + 30 ))
pin_wait_deadline=$(( $(date +%s) + 3 ))
older_holder=
while ! mkdir "$LOCK" 2>/dev/null; do
  holder=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    if [ -e "$STATE/.context-epoch" ] && [ -e "$LOCK/context-epoch.$holder" ] \
      && ! [ "$STATE/.context-epoch" -ef "$LOCK/context-epoch.$holder" ]; then
      # The holder is bound to an older context and will stand down.
      older_holder=$holder
      [ "$(date +%s)" -lt "$holder_wait_deadline" ] \
        || finish stood-down "an older resume doorbell (pid $holder) did not stand down"
    elif [ -e "$STATE/.context-epoch" ] && [ ! -e "$LOCK/context-epoch.$holder" ] \
      && [ "$(date +%s)" -lt "$pin_wait_deadline" ]; then
      : # The holder has not pinned its context yet; look again shortly.
    elif [ "$(cat "$LOCK/pid" 2>/dev/null || true)" != "$holder" ] || [ "$older_holder" = "$holder" ]; then
      # The lock moved or vanished under this look, or an older holder's pin
      # vanished as it stood down and removed its lock: look again.
      [ "$(date +%s)" -lt "$holder_wait_deadline" ] \
        || finish stood-down "an older resume doorbell (pid $holder) did not stand down"
    else
      finish stood-down "another resume doorbell (pid $holder) is running"
    fi
    if [ -n "$EXPECTED_EPOCH_SUM" ] && [ "$(current_epoch_sum)" != "$EXPECTED_EPOCH_SUM" ]; then
      finish stood-down "a new context began after the compaction"
    fi
    sleep 0.2
    continue
  fi
  # An older holder seen earlier is removing its lock (its pid goes first):
  # look again rather than mistake it for a new doorbell starting.
  if [ -z "$holder" ] && [ -n "$older_holder" ]; then
    [ "$(date +%s)" -lt "$holder_wait_deadline" ] \
      || finish stood-down "an older resume doorbell (pid $older_holder) did not stand down"
    sleep 0.2
    continue
  fi
  # A lock whose pid is not written yet belongs to a doorbell between its
  # mkdir and its pid write; only an old one is stale.
  if [ -z "$holder" ] && [ -n "$(find "$LOCK" -maxdepth 0 -newermt '-10 seconds' 2>/dev/null)" ]; then
    finish stood-down "another resume doorbell is starting"
  fi
  rm -rf "$LOCK" 2>/dev/null || true
  mkdir "$LOCK" 2>/dev/null || finish stood-down "the doorbell lock could not be taken"
  break
done
printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null || true
trap '[ "$(cat "$LOCK/pid" 2>/dev/null)" != "$$" ] || rm -rf "$LOCK" 2>/dev/null || true' EXIT

LOCK_PID=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
[ -n "$LOCK_PID" ] || finish stood-down "no session lock"

# The context this doorbell was started for. A /clear or a later compaction
# replaces state/.context-epoch (mktemp plus mv), so a hard link pinned inside
# the doorbell lock stops naming the same file, and its bytes change too. An
# epoch absent at start must stay absent. The pin is per doorbell, so a newer
# doorbell can tell that a live holder started under an older context.
EPOCH_PIN="$LOCK/context-epoch.$$"
if [ -e "$STATE/.context-epoch" ]; then
  if ln "$STATE/.context-epoch" "$EPOCH_PIN" 2>/dev/null; then
    EPOCH_SUM=$(cksum < "$EPOCH_PIN" 2>/dev/null || true)
  else
    EPOCH_PIN=
    EPOCH_SUM=$(cksum < "$STATE/.context-epoch" 2>/dev/null || true)
  fi
  [ -n "$EPOCH_SUM" ] || finish stood-down "state/.context-epoch is unreadable"
else
  EPOCH_PIN=
  EPOCH_SUM=absent
fi
# The pinned context must be the one the launching hook recorded.
if [ -n "$EXPECTED_EPOCH_SUM" ] && [ "$EPOCH_SUM" != "$EXPECTED_EPOCH_SUM" ]; then
  finish stood-down "a new context began after the compaction"
fi
# The context belongs to the session that recorded it: a replacement session
# that took the session lock before this doorbell started is not its target.
if [ "$EPOCH_SUM" != absent ]; then
  epoch_owner=$(sed -n 's/^lock_pid=//p' "${EPOCH_PIN:-$STATE/.context-epoch}" 2>/dev/null | head -n 1)
  [ -z "$epoch_owner" ] || [ "$epoch_owner" = "$LOCK_PID" ] \
    || finish stood-down "the session lock changed owner"
fi
context_epoch_same() {
  if [ "$EPOCH_SUM" = absent ]; then
    [ ! -e "$STATE/.context-epoch" ]
    return
  fi
  [ -e "$STATE/.context-epoch" ] || return 1
  [ -z "$EPOCH_PIN" ] || [ "$STATE/.context-epoch" -ef "$EPOCH_PIN" ] || return 1
  [ "$(cksum < "$STATE/.context-epoch" 2>/dev/null || true)" = "$EPOCH_SUM" ]
}

read_handle() {
  BACKEND=$(sed -n 's/^backend=//p' "$STATE/captain-handle" 2>/dev/null | head -n 1)
  TARGET=$(sed -n 's/^target=//p' "$STATE/captain-handle" 2>/dev/null | head -n 1)
  [ -n "$BACKEND" ] && [ -n "$TARGET" ]
}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh" >/dev/null 2>&1 || finish failed "bin/fm-backend.sh could not be loaded"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh" >/dev/null 2>&1 || finish failed "bin/fm-task-inbox-lib.sh could not be loaded"
if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_RESUME_DOORBELL_TEST_LIB:-}" ]; then
  # shellcheck source=/dev/null
  . "$FM_RESUME_DOORBELL_TEST_LIB" || finish failed "the test seam library could not be loaded"
fi

transcript_size() {
  [ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || { printf ''; return 0; }
  wc -c < "$TRANSCRIPT" 2>/dev/null | tr -d '[:space:]'
}

# True when the transcript shows a turn after the newest compact boundary: an
# idle compaction writes no assistant record, while a compaction inside a turn
# is followed by that turn's assistant records, including a tool call still
# running. Unprovable (no jq, unreadable) counts as a turn.
transcript_turn_after_compaction() {
  local from
  [ -n "$TRANSCRIPT" ] || return 1
  command -v jq >/dev/null 2>&1 && [ -r "$TRANSCRIPT" ] || return 0
  from=$(grep -n -F 'compact_boundary' "$TRANSCRIPT" 2>/dev/null \
    | jq -Rr 'capture("^(?<n>[0-9]+):(?<j>.*)$")? | select((.j | fromjson? | (.type == "system" and .subtype == "compact_boundary")) == true) | .n' 2>/dev/null \
    | tail -n 1)
  tail -n +"${from:-1}" "$TRANSCRIPT" 2>/dev/null \
    | jq -Rr 'fromjson? | select(.type == "assistant") | "turn"' 2>/dev/null | grep -q turn
}

# The rendered Claude busy footer, on a backend that exposes one. Native idle
# can read idle during a long foreground tool call (docs/herdr-backend.md), so
# a rendered busy footer independently proves a running turn.
rendered_busy() {
  local fn="fm_backend_${BACKEND}_rendered_busy_state"
  # The other backend reads load the adapter inside their own command
  # substitutions, so it is not loaded here yet.
  declare -F "$fn" >/dev/null 2>&1 || fm_backend_source "$BACKEND" >/dev/null 2>&1 || true
  declare -F "$fn" >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  "$fn" "$TARGET" claude 2>/dev/null || printf 'unknown'
}

# Prints why this doorbell may no longer press a key, or nothing: ownership,
# posture and context checks that hold for the first send and every resubmit.
posture_reason() {
  # A second doorbell that cleared the same stale lock may have replaced ours.
  [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] || { printf 'another resume doorbell took the lock'; return 0; }
  [ "$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)" = "$LOCK_PID" ] || { printf 'the session lock changed owner'; return 0; }
  kill -0 "$LOCK_PID" 2>/dev/null || { printf 'the session lock changed owner'; return 0; }
  if [ -e "$STATE/.afk" ] || [ -e "$STATE/.afk-contract" ]; then
    printf 'an away or quiet record exists'; return 0
  fi
  context_epoch_same || { printf 'a new context began after the compaction'; return 0; }
}

# Prints the stand-down reason, or nothing when the target is provably idle.
# <previous transcript size> is the size one poll earlier.
idle_reason() {  # <previous-size>
  local prev=$1 agent busy composer size reason
  reason=$(posture_reason)
  [ -z "$reason" ] || { printf '%s' "$reason"; return 0; }
  # The handle counts only when this session recorded it: the re-emit's
  # claim-handle rewrites it after the lock, so a handle older than the lock
  # names some earlier session's terminal.
  [ ! "$STATE/.lock" -nt "$STATE/captain-handle" ] || { printf 'state/captain-handle is older than the session lock'; return 0; }
  # A Stop that claimed after this compaction means a turn already ran.
  if [ -e "$STATE/.context-epoch" ] && [ "$STATE/.claude-autoarm-epoch" -nt "$STATE/.context-epoch" ]; then
    printf 'a turn already ended after the compaction'; return 0
  fi
  agent=$(fm_backend_agent_state "$BACKEND" "$TARGET" 2>/dev/null || printf unknown)
  [ "$agent" = alive ] || { printf 'agent state is %s' "$agent"; return 0; }
  composer=$(fm_backend_composer_state "$BACKEND" "$TARGET" 2>/dev/null || printf unknown)
  [ "$composer" = empty ] || { printf 'composer is %s' "$composer"; return 0; }
  busy=$(fm_backend_busy_state "$BACKEND" "$TARGET" 2>/dev/null || printf unknown)
  [ "$busy" != busy ] || { printf 'a turn is running'; return 0; }
  [ "$busy" = idle ] || { printf 'busy state is %s, not a native idle' "$busy"; return 0; }
  [ "$(rendered_busy)" != busy ] || { printf 'a turn is running'; return 0; }
  # Native idle can lag a turn that just started, so a transcript, when one
  # was given, must also have stayed unchanged for a whole poll.
  if [ -n "$TRANSCRIPT" ]; then
    size=$(transcript_size)
    [ -n "$size" ] && [ -n "$prev" ] && [ "$size" = "$prev" ] \
      || { printf 'the transcript is not proven quiet'; return 0; }
    ! transcript_turn_after_compaction || { printf 'a turn is running after the compaction'; return 0; }
  fi
}

sleep "$SETTLE"
deadline=$(( $(date +%s) + WAIT ))
prev=$(transcript_size)
reason=
while :; do
  sleep "$POLL"
  # The handle is read here, not inside idle_reason's command substitution,
  # so the backend and target survive into the send below.
  read_handle || finish stood-down 'state/captain-handle is unreadable'
  reason=$(idle_reason "$prev")
  [ -n "$reason" ] || break
  case "$reason" in
    'another resume doorbell took the lock'|'state/captain-handle is older than the session lock'|'the session lock changed owner'|'agent state is '*|'composer is '*|'a turn is running'|'a turn is running after the compaction'|'busy state is '*|'an away or quiet record exists'|'a new context began after the compaction'|'a turn already ended after the compaction')
      finish stood-down "$reason" ;;
  esac
  prev=$(transcript_size)
  [ "$(date +%s)" -lt "$deadline" ] || finish stood-down "not-quiet: $reason"
done

# The idle reads above take time; the ownership, posture and context checks
# run once more before the send.
reason=$(posture_reason)
[ -z "$reason" ] || finish stood-down "$reason"

# The shared send helper and the adapter read the composer, the agent and the
# endpoint again before they type and before each Enter. So the one call that
# issues each keystroke (the herdr, tern or hc CLI's send subcommands, or the
# adapter's keystroke functions elsewhere) is wrapped, in this process only, to
# re-run those checks right before it. A withheld keystroke is recorded in
# WITHHELD and reports failure; TYPED records that the line was typed.
WITHHELD="$LOCK/withheld.$$"
TYPED="$LOCK/typed.$$"
# shellcheck disable=SC2329 # Invoked from the eval wrapper in guard_keystroke.
keystroke_allowed() {
  local why
  why=$(posture_reason)
  [ -n "$why" ] || return 0
  [ -e "$WITHHELD" ] || printf '%s\n' "$why" > "$WITHHELD" 2>/dev/null || true
  return 1
}
# shellcheck disable=SC2329 # Invoked from the eval wrapper in guard_keystroke.
keystroke_kind() {  # <function> <args...>: prints text, key, or nothing for a read
  local fn=$1
  shift
  case "$fn" in
    fm_backend_herdr_cli)
      if [ "${2:-}" = pane ]; then
        case "${3:-}" in send-text|run) printf 'text' ;; send-keys) printf 'key' ;; esac
      fi
      ;;
    fm_backend_tern_cli)
      case "${1:-}" in
        send) if [ "${3:-}" = text ]; then printf 'text'; else printf 'key'; fi ;;
        run) printf 'text' ;;
      esac
      ;;
    fm_backend_hc_cli)
      case "${2:-}" in send) printf 'text' ;; keys) printf 'key' ;; esac
      ;;
    *_send_literal|*_turn_start) printf 'text' ;;
    *_send_key) printf 'key' ;;
  esac
}
guard_keystroke() {  # <function>: 0 wrapped, 2 absent, 1 failed
  local fn=$1 body
  declare -F "$fn" >/dev/null 2>&1 || return 2
  body=$(declare -f "$fn") || return 1
  eval "fm_rd_unguarded_${body}" || return 1
  eval "$fn() {
    local kind
    kind=\$(keystroke_kind $fn \"\$@\")
    if [ -n \"\$kind\" ]; then keystroke_allowed || return 1; fi
    fm_rd_unguarded_$fn \"\$@\" || return
    [ \"\$kind\" != text ] || : > \"\$TYPED\" 2>/dev/null || true
  }"
}
withheld_detail() {  # prints "<what>: <reason>" for a withheld keystroke, or fails
  [ -s "$WITHHELD" ] || return 1
  if [ -e "$TYPED" ]; then
    printf 'a keystroke was withheld after typing: %s' "$(cat "$WITHHELD")"
  else
    printf 'the send was withheld before typing: %s' "$(cat "$WITHHELD")"
  fi
}
fm_backend_source "$BACKEND" >/dev/null 2>&1 || finish failed "the $BACKEND backend could not be loaded"
case "$BACKEND" in
  herdr|tern|hc) keystroke_fns="fm_backend_${BACKEND}_cli" ;;
  *) keystroke_fns="fm_backend_${BACKEND}_send_literal fm_backend_${BACKEND}_send_key fm_backend_${BACKEND}_turn_start" ;;
esac
guarded=0
for keystroke_fn in $keystroke_fns; do
  rc=0
  guard_keystroke "$keystroke_fn" || rc=$?
  case "$rc" in
    0) guarded=$((guarded + 1)) ;;
    2) ;;
    *) finish failed "the $BACKEND keystrokes could not be guarded" ;;
  esac
done
[ "$guarded" -gt 0 ] || finish failed "the $BACKEND keystrokes could not be guarded"

# A submit whose payload check fails would clear the composer with Ctrl+U,
# and by then the composer may hold operator text typed while the doorbell
# settled, so this process wraps every composer-clear the sourced backend (or
# the test seam) defines to refuse, erasing nothing: the submit then returns
# its unproven verdict and the run fails closed below.
CLEAR_REFUSED="$LOCK/clear-refused.$$"
for clear_fn in $(declare -F | sed -n 's/^declare -f \(fm_backend_[a-z0-9][a-z0-9_]*_composer_clear\)$/\1/p'); do
  eval "$clear_fn() {
    printf '%s\n' 'the composer clear was refused so the composer text survived' > \"\$CLEAR_REFUSED\" 2>/dev/null || true
    return 1
  }" || finish failed "the $BACKEND composer clear could not be refused"
done

# The line travels as the shared operational-input record carrier: Claude
# strips the invisible U+2063 mark from typed prompts, so the resume
# instruction is written to a durable record and the typed ASCII doorbell
# names it, keeping the submitted prompt Firstmate operational input rather
# than captain dialog (bin/fm-operational-input.sh "Record-backed carrier";
# bin/fm-host-mirror.sh drops it while the record is live).
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
DOORBELL_LINE=
fm_operational_record_write "$STATE" session-start "$FM_RESUME_DOORBELL_BODY" DOORBELL_LINE \
  || finish failed "the resume operational-input record could not be written"

verdict=$(fm_backend_send_text_submit "$BACKEND" "$TARGET" "$DOORBELL_LINE" 1 0.4 0.3 2>/dev/null) || verdict=
if detail=$(withheld_detail); then
  case "$detail" in
    'the send was withheld'*) finish stood-down "$detail" ;;
    *) finish unverified "$detail (first verdict ${verdict:-none})" ;;
  esac
fi
case "$verdict" in
  '') finish failed "the send did not complete" ;;
  send-failed) finish failed "send-failed" ;;
  empty) finish submitted "first Enter landed" ;;
  # Only a still-pending composer earns resubmit Enters: every other
  # unproven verdict (unknown, unconfirmed, a named dialog) finishes
  # unverified, and a later Enter could confirm a picker or land on
  # operator text.
  pending|pending-unproven) ;;
  *)
    if [ -s "$CLEAR_REFUSED" ]; then
      finish unverified "the submit aborted without clearing the composer: $(cat "$CLEAR_REFUSED") (first verdict $verdict)"
    fi
    finish unverified "the submit could not be confirmed (first verdict $verdict)"
    ;;
esac

# The first Enter did not land (the verdict was pending or pending-unproven,
# the only verdicts that reach here). Press Enter again only while the
# composer holds exactly copies of our line and the ownership, posture and
# context checks still pass.
i=0
while [ "$i" -lt "$TRIES" ]; do
  sleep "$RESUBMIT_DELAY"
  # The composer read comes first, so the posture check is the last read
  # before the Enter (and the guarded Enter re-checks it once more).
  if fm_task_inbox_composer_holds "$BACKEND" "$TARGET" "$DOORBELL_LINE"; then
    reason=$(posture_reason)
    [ -z "$reason" ] || finish unverified "resubmit withheld after $i resubmit Enter(s): $reason (first verdict $verdict)"
    if ! fm_backend_send_key "$BACKEND" "$TARGET" Enter >/dev/null 2>&1; then
      if detail=$(withheld_detail); then
        finish unverified "resubmit withheld after $i resubmit Enter(s): $(cat "$WITHHELD") (first verdict $verdict)"
      fi
      finish failed "the resubmit Enter could not be sent"
    fi
    i=$((i + 1))
    continue
  fi
  break
done
sleep "$RESUBMIT_DELAY"
if [ "$(fm_backend_busy_state "$BACKEND" "$TARGET" 2>/dev/null || printf unknown)" = busy ]; then
  finish submitted "turn started after $i resubmit Enter(s)"
fi
if [ "$(fm_backend_composer_state "$BACKEND" "$TARGET" 2>/dev/null || printf unknown)" = empty ]; then
  finish submitted "composer cleared after $i resubmit Enter(s)"
fi
finish unverified "submit not confirmed after $i resubmit Enter(s) (first verdict $verdict)"
