#!/usr/bin/env bash
# Automatic entry requests for the existing /afk posture.
# Usage:
#   fm-auto-away.sh arm [--session-start]
#                                       register the normal scheduled check;
#                                       --session-start also records activity
#   fm-auto-away.sh check               queue one request when a trigger is due
#   fm-auto-away.sh enter <activity>    revalidate a request and run AFK entry
#   fm-auto-away.sh captain-message     record a genuine captain message
#
# docs/configuration.md owns config/auto-away and its defaults. No extra timer
# or daemon runs here. The watcher executes the authenticated shim at its normal
# check cadence. Requests go directly to the durable wake queue, before their
# de-duplication receipt is saved, so an interrupted check cannot lose a request.
# Entry is handled in main's turn, where /afk can launch the correct supervision
# path and announce once. It rechecks both the activity stamp and the triggers:
# a message that arrived after a queued request cancels that request.
#
# A failed or obsolete entry releases its matching request under the lock, so
# a failed entry, including one before launch, leaves a later check free to
# retry. A request stays fulfilled while a posture or pending return holds, so
# a successful or repeated entry keeps it; enter reports each distinct
# failure once and stays silent while it repeats unchanged. The failure record
# holds the next retry time and the failure signature: a new signature retries
# at the next check, an unchanged one only after ENTRY_BACKOFF seconds.
#
# captain-message is the harness-independent activity boundary, called by main
# only for genuine captain input, never for operational wakes. A captain-opened
# session start arms with --session-start and counts as captain activity,
# because the opening message precedes the instruction to record it; a trigger
# missed while no session ran therefore never fires on session open. A clear or
# compact, re-emitted or full, arms without it; a disabled feature still records
# a captain-opened start, which also clears pending entry state as a captain
# message does. A handoff successor or a watchdog restart, including one run by
# another home's watchdog, is detected at arm. Automated starts and re-arms
# preserve the last stamp, so both deadlines hold.
# An existing quiet or away posture is never replaced.
# The AFK launch owner's lock serializes entry against explicit /afk and /quiet.
# Test-only clock: FM_TEST_SEAM=1 FM_AUTO_AWAY_NOW=<epoch>.
set -eu
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ACTIVITY="$STATE/.captain-message-epoch"
REQUEST="$STATE/.auto-away-request"
LOCK="$STATE/.auto-away.lock"
FAILURE="$STATE/.auto-away-failure"
ENTRY_FAILURE="$STATE/.auto-away-entry-failure"
ENTRY_BACKOFF=1800

usage() { sed -n '2,9s/^# \{0,1\}//p' "$0"; }
# The watcher turns only check stdout into a wake, so a check reports there,
# once per distinct failure until a clean check clears the receipt.
fail() {
  if [ "$CMD" = check ]; then
    if [ -d "$STATE" ] && [ ! -L "$STATE" ]; then
      [ "$(cat "$FAILURE" 2>/dev/null || true)" != "$1" ] || exit 1
      write_record "$FAILURE" "$1" || true
    fi
    printf 'auto-away check failed: %s\n' "$1"
  elif [ "$CMD" = enter ] && [ "$LOCKED" = 1 ]; then
    entry_failed "$1"
  else printf 'fm-auto-away: %s\n' "$1" >&2
  fi
  exit 1
}

# An away or quiet posture, or a pending return, blocks automatic entry.
posture_held() {
  [ -e "$STATE/.afk-contract" ] || [ -e "$STATE/.afk" ] \
    || [ -e "$STATE/.afk-return-catchup" ] || [ -e "$STATE/.quiet-exit-pending" ]
}

# Only a failed or obsolete entry frees its own request for a later check;
# a fulfilled one is kept, so a stale stamp cannot request entry again.
release_request() {
  ! posture_held || return 0
  [ "$(cat "$REQUEST" 2>/dev/null || true)" != "$ENTRY_ACTIVITY" ] || rm -f "$REQUEST"
}

# Report a failure signature once; an unchanged repeat backs off silently.
entry_failed() { # <signature>
  local previous
  release_request
  previous=$(cat "$ENTRY_FAILURE" 2>/dev/null || true)
  if [ "${previous#* }" = "$1" ]; then
    write_record "$ENTRY_FAILURE" "$((NOW + ENTRY_BACKOFF)) $1" || true
    exit 0
  fi
  write_record "$ENTRY_FAILURE" "$NOW $1" || true
  printf 'auto-away entry failed: %s\n' "$1"
  exit 1
}

# Parse values, never source configuration as shell code.
read_config() {
  local line key value
  ENABLED=on
  AT=23:00
  SILENCE=7200
  ZONE=local
  if [ -e "$CONFIG/auto-away" ] || [ -L "$CONFIG/auto-away" ]; then
    [ -f "$CONFIG/auto-away" ] && [ ! -L "$CONFIG/auto-away" ] || fail 'config/auto-away is not a regular file'
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      key=${line%%=*}; value=${line#*=}
      case "$key" in
        enabled) ENABLED=$value ;;
        time) AT=$value ;;
        silence-seconds) SILENCE=$value ;;
        timezone) ZONE=$value ;;
        *) fail "unknown config/auto-away key: $key" ;;
      esac
    done < "$CONFIG/auto-away"
  fi
  case "$ENABLED" in on|off) ;; *) fail 'enabled must be on or off' ;; esac
  [[ "$AT" = off || "$AT" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || fail 'time must be HH:MM or off'
  [[ "$SILENCE" =~ ^(0|[1-9][0-9]{0,8})$ ]] || fail 'silence-seconds must be 0 or a positive integer (at most 9 digits)'
  if [ "$ZONE" != local ]; then
    case "$ZONE" in ''|/*|*..*) fail 'timezone must be local or an IANA zone name' ;; esac
    [ -f "/usr/share/zoneinfo/$ZONE" ] \
      && [ "$(head -c 4 "/usr/share/zoneinfo/$ZONE" 2>/dev/null)" = TZif ] || fail "unknown timezone: $ZONE"
    export TZ="$ZONE"
  fi
}

now() {
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_AUTO_AWAY_NOW:-}" ]; then
    [[ "$FM_AUTO_AWAY_NOW" =~ ^[1-9][0-9]{0,9}$ ]] || fail 'invalid test clock'
    printf '%s\n' "$FM_AUTO_AWAY_NOW"
  else
    date +%s
  fi
}

local_date() { # <epoch> <format>
  date -d "@$1" "$2" 2>/dev/null || date -r "$1" "$2" 2>/dev/null
}

# Sets CLOCK_DUE=1 when the daily boundary passed since LAST.
clock_due() {
  local stamp clock today seconds boundary previous hour minute second
  stamp=$(local_date "$NOW" '+%Y%m%d %H:%M %H %M %S') || return 1
  read -r today clock hour minute second <<< "$stamp"
  boundary="$today ${AT}"
  if [[ "$clock" < "$AT" ]]; then
    # Prior local noon is safely on the previous date on either side of a
    # DST transition; subtracting 86400 near midnight need not be.
    seconds=$((10#$hour * 3600 + 10#$minute * 60 + 10#$second))
    previous=$(local_date "$((NOW - seconds - 43200))" '+%Y%m%d') || return 1
    boundary="$previous ${AT}"
  fi
  stamp=$(local_date "$LAST" '+%Y%m%d %H:%M') || return 1
  [[ "$stamp" < "$boundary" ]] && CLOCK_DUE=1
  return 0
}

read_activity() {
  LAST=
  [ -f "$ACTIVITY" ] && [ ! -L "$ACTIVITY" ] || return 1
  LAST=$(cat "$ACTIVITY") || return 1
  [[ "$LAST" =~ ^[1-9][0-9]{0,9}$ ]]
}

write_record() { # <path> <value>
  local path=$1 value=$2 tmp
  [ ! -L "$path" ] && { [ ! -e "$path" ] || [ -f "$path" ]; } || return 1
  tmp=$(mktemp "$STATE/.auto-away.XXXXXX") || return 1
  if ! printf '%s\n' "$value" > "$tmp" || ! mv -f "$tmp" "$path"; then
    rm -f "$tmp"
    return 1
  fi
}

due() {
  local CLOCK_DUE=0
  REASON=
  [ "$ENABLED" = on ] || return 1
  ! posture_held || return 1
  read_activity || return 1
  [ "$NOW" -ge "$LAST" ] || return 1
  if [ "$AT" != off ]; then
    if clock_due; then CLOCK_OK=1
    else CLOCK_ERROR='cannot convert epoch to local time; clock trigger skipped'
    fi
    if [ "$CLOCK_DUE" = 1 ]; then REASON=clock; return 0; fi
  fi
  if [ "$SILENCE" -gt 0 ] && [ $((NOW - LAST)) -ge "$SILENCE" ]; then
    REASON=silence
    return 0
  fi
  return 1
}

# A handoff successor holding the lock, or a watchdog restart of this home,
# opened the session; the captain did not. A restarted holder carries the
# watchdog's restart prompt in its own arguments, which covers a home whose
# watchdog owner is another home; the owner's ledger lives in that owner.
automated_start() {
  local holder home
  holder=$(head -n 1 "$STATE/.lock" 2>/dev/null || true)
  case "$holder" in ''|*[!0-9]*) holder= ;; esac
  if [ -n "$holder" ]; then
    [ "$(sed -n 's/^pid=//p' "$STATE/.handoff-successor" 2>/dev/null | tail -1)" != "$holder" ] || return 0
    case "$(ps -o args= -p "$holder" 2>/dev/null || true)" in
      *'Watchdog restart of this firstmate home.'*) return 0 ;;
    esac
  fi
  home=$(cd -P -- "$FM_HOME" 2>/dev/null && pwd -P) || return 1
  [ "$(awk -F'\t' -v h="$home" '$3 == h && $6 == "restart" { p = $7 } END { print p }' \
    "$STATE/watchdog/actions.tsv" 2>/dev/null)" = pending ]
}

arm() {
  local shim="$STATE/auto-away.check.sh" tmp
  if [ "$SESSION_START" = 1 ] && automated_start; then SESSION_START=0; fi
  if [ "$SESSION_START" = 1 ] || ! read_activity; then
    write_record "$ACTIVITY" "$NOW" || fail 'cannot record session start activity'
    [ "$SESSION_START" != 1 ] || rm -f "$REQUEST" "$ENTRY_FAILURE"
  fi
  if [ "$ENABLED" = off ]; then
    "$SCRIPT_DIR/fm-check-unregister.sh" auto-away >/dev/null
    rm -f "$REQUEST"
    return
  fi
  if [ -L "$shim" ] || { [ -e "$shim" ] && [ ! -f "$shim" ]; }; then
    fail 'unsafe check shim'
  fi
  tmp=$(mktemp "$STATE/.auto-away-shim.XXXXXX") || fail 'cannot stage check shim'
  # Pin all three roots: a check can be invoked from an unrelated environment.
  if ! printf '#!/usr/bin/env bash\nexport FM_HOME=%q FM_STATE_OVERRIDE=%q FM_CONFIG_OVERRIDE=%q\nexec %q check\n' \
      "$FM_HOME" "$STATE" "$CONFIG" "$SCRIPT_DIR/fm-auto-away.sh" > "$tmp" \
      || ! chmod 700 "$tmp" || ! mv -f "$tmp" "$shim"; then
    rm -f "$tmp"
    fail 'cannot publish check shim'
  fi
  "$SCRIPT_DIR/fm-check-register.sh" auto-away >/dev/null || fail 'cannot register check shim'
  printf 'armed: state/auto-away.check.sh\n'
}

CMD=${1:-check}
CLOCK_ERROR=
CLOCK_OK=0
LOCKED=0
NOW=
ENTRY_ACTIVITY=${2:-}
case "$CMD" in
  --help|-h|help) usage; exit 0 ;;
  arm) [ "$#" -eq 1 ] || { [ "$#" -eq 2 ] && [ "$2" = --session-start ]; } || { usage >&2; exit 2; } ;;
  check|captain-message) [ "$#" -le 1 ] || { usage >&2; exit 2; } ;;
  enter) [ "$#" -eq 2 ] && [[ "$2" =~ ^[1-9][0-9]{0,9}$ ]] || { usage >&2; exit 2; } ;;
  *) usage >&2; exit 2 ;;
esac
SESSION_START=0
[ "${2:-}" != --session-start ] || SESSION_START=1
# This feature is only for the primary conversation, never a secondmate home.
[ ! -e "$FM_HOME/.fm-secondmate-home" ] || exit 0
umask 077
mkdir -p "$STATE"
[ ! -L "$STATE" ] || fail 'state is not a real directory'
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
fm_lock_acquire_wait "$LOCK" || fail 'cannot acquire activity lock'
trap 'fm_lock_release "$LOCK"' EXIT
LOCKED=1
NOW=$(now)
[ "$CMD" = captain-message ] || read_config
case "${1:-check}" in
  captain-message)
    write_record "$ACTIVITY" "$NOW" || fail 'cannot record captain activity'
    rm -f "$REQUEST" "$ENTRY_FAILURE"
    ;;
  arm) arm ;;
  check)
    [ "$ENABLED" != off ] || rm -f "$REQUEST"
    [ "$ENABLED" = on ] && [ "$AT" != off ] || CLOCK_OK=1
    if due; then
      request=$LAST
      retry=$(cat "$ENTRY_FAILURE" 2>/dev/null || true)
      retry=${retry%% *}
      [[ "$retry" =~ ^[0-9]{1,10}$ ]] || retry=0
      if [ "$(cat "$REQUEST" 2>/dev/null || true)" != "$request" ] && [ "$NOW" -ge "$retry" ]; then
        fm_wake_append check auto-away \
          "check: auto-away $REASON trigger; load /afk and run bin/fm-auto-away.sh enter $LAST; only if it prints an entry, finish /afk supervision setup and announce it once." \
          || fail 'cannot queue automatic entry'
        write_record "$REQUEST" "$request" || fail 'cannot save entry request receipt'
      fi
    fi
    [ -z "$CLOCK_ERROR" ] || fail "$CLOCK_ERROR"
    # A check that never reached the clock keeps a clock failure receipt.
    if [ "$CLOCK_OK" = 1 ] || [ "$(cat "$FAILURE" 2>/dev/null || true)" != 'cannot convert epoch to local time; clock trigger skipped' ]; then
      rm -f "$FAILURE"
    fi
    ;;
  enter)
    if due && [ "$LAST" = "$2" ]; then
      errors=$(mktemp "$STATE/.auto-away-entry.XXXXXX") || fail 'cannot stage entry errors'
      status=0
      FM_AFK_MODE=away "$SCRIPT_DIR/fm-afk-launch.sh" enter-auto 2>"$errors" || status=$?
      signature="exit $status: $(head -n 1 "$errors")"
      [ "$status" != 0 ] || cat "$errors" >&2
      rm -f "$errors"
      [ "$status" = 0 ] || entry_failed "$signature"
      rm -f "$ENTRY_FAILURE"
    else
      release_request
    fi
    ;;
esac
