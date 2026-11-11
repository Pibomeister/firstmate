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
# captain-message is the harness-independent activity boundary, called by main
# only for genuine captain input, never for operational wakes. A true session
# start arms with --session-start and counts as captain activity, because the
# opening message precedes the instruction to record it; a trigger missed while
# no session ran therefore never fires on session open. A re-emit after clear or
# compact arms without it and preserves the last stamp, so both deadlines hold.
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

usage() { sed -n '2,9s/^# \{0,1\}//p' "$0"; }
fail() { printf 'fm-auto-away: %s\n' "$1" >&2; exit 1; }

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
    [ -f "/usr/share/zoneinfo/$ZONE" ] || fail "unknown timezone: $ZONE"
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
  if [ "$_FM_UNAME" = Darwin ]; then date -r "$1" "$2"
  else date -d "@$1" "$2"
  fi
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
  local stamp clock today seconds boundary previous hour minute second
  REASON=
  [ "$ENABLED" = on ] || return 1
  [ ! -e "$STATE/.afk-contract" ] && [ ! -e "$STATE/.afk" ] || return 1
  [ ! -e "$STATE/.afk-return-catchup" ] && [ ! -e "$STATE/.quiet-exit-pending" ] || return 1
  read_activity || return 1
  [ "$NOW" -ge "$LAST" ] || return 1
  if [ "$AT" != off ]; then
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
    if [[ "$stamp" < "$boundary" ]]; then REASON=clock; return 0; fi
  fi
  if [ "$SILENCE" -gt 0 ] && [ $((NOW - LAST)) -ge "$SILENCE" ]; then
    REASON=silence
    return 0
  fi
  return 1
}

arm() {
  local shim="$STATE/auto-away.check.sh" tmp
  if [ "$ENABLED" = off ]; then
    "$SCRIPT_DIR/fm-check-unregister.sh" auto-away >/dev/null
    rm -f "$REQUEST"
    return
  fi
  if [ "$SESSION_START" = 1 ] || ! read_activity; then
    write_record "$ACTIVITY" "$NOW" || fail 'cannot record session start activity'
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

case "${1:-check}" in
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
case "${1:-check}" in
  captain-message) ;;
  *) read_config ;;
esac
mkdir -p "$STATE"
[ ! -L "$STATE" ] || fail 'state is not a real directory'
umask 077
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
fm_lock_acquire_wait "$LOCK" || fail 'cannot acquire activity lock'
trap 'fm_lock_release "$LOCK"' EXIT
NOW=$(now)
case "${1:-check}" in
  captain-message)
    write_record "$ACTIVITY" "$NOW" || fail 'cannot record captain activity'
    rm -f "$REQUEST"
    ;;
  arm) arm ;;
  check)
    [ "$ENABLED" != off ] || rm -f "$REQUEST"
    if due; then
      request=$LAST
      if [ "$(cat "$REQUEST" 2>/dev/null || true)" != "$request" ]; then
        fm_wake_append check auto-away \
          "check: auto-away $REASON trigger; load /afk and run bin/fm-auto-away.sh enter $LAST; only if it prints an entry, finish /afk supervision setup and announce it once." \
          || fail 'cannot queue automatic entry'
        write_record "$REQUEST" "$request" || fail 'cannot save entry request receipt'
      fi
    fi
    ;;
  enter)
    if due && [ "$LAST" = "$2" ]; then
      FM_AFK_MODE=away "$SCRIPT_DIR/fm-afk-launch.sh" enter-auto
    elif [ "$(cat "$REQUEST" 2>/dev/null || true)" = "$2" ]; then
      # A changed setting can invalidate a queued request without a new
      # message. Let its next real crossing publish a fresh request.
      rm -f "$REQUEST"
    fi
    ;;
esac
