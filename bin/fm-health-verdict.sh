#!/usr/bin/env bash
# fm-health-verdict.sh - one health verdict for a home.
#
# Usage:
#   fm-health-verdict.sh [--home <dir>] [--write]
#   fm-health-verdict.sh -h | --help
#
# Prints one line, and with --write also replaces <home>/state/health-verdict
# atomically with it:
#   verdict=<ok|stale|dead|unconfirmed|unknown> reason=<r> heartbeat_age=<secs|unknown>
#   lock=<live|dead|mismatch|none|unknown> watcher_age=<secs|unknown>
#   monitor=<enabled|disabled|uncovered|unreadable|missing> at=<epoch>
# <home> defaults to FM_HOME. reason is a comma-separated list of tokens.
#
# Inputs, and nothing else:
#   - published_epoch and stale_after_secs of state/heartbeat.json; the age
#     runs from the publication stamp, never from generated_epoch (the
#     observation time), and a record with no published_epoch is unread;
#   - the lock verdict (alive=) in state/watchdog/captain: live, dead,
#     unconfirmed (reported as lock=mismatch) or none;
#   - the age of state/.last-watcher-beat, bounded by watcher-stale-secs in
#     <home>/config/watchdog, read with the watchdog's own config reader
#     (fm_wd_conf_int, bin/fm-watchdog-lib.sh); docs/watchdog.md owns the key
#     and its default. The file is <home>'s own, so the bound matches the
#     watchdog's only when <home> is the watchdog owner home;
#   - state/monitor-status (docs/watchdog.md "Layer check chain");
#   - fm_watcher_supervision_verdict (bin/fm-wake-lib.sh): a healthy verdict
#     while the beacon is older than FM_GUARD_GRACE (default 300) means a
#     supervisor turn is under way;
#   - fm_health_open_work (bin/fm-health-lib.sh) and state/.afk.
# The legacy state/.last-heartbeat never feeds the verdict.
#
# Rules, in precedence order:
#   1. dead: the lock verdict is dead, at any heartbeat age and turn state
#      (reason lock-dead); or it is none with open work (none-open-work) or
#      an away record (none-away).
#   2. unconfirmed: the lock pid is live but its instance does not match
#      (reason instance-mismatch).
#   3. stale or unknown, one tier. stale wins inside the tier because it
#      carries a measured age, and its reason also names every unknown:
#      - heartbeat-stale: outside a supervisor turn, the heartbeat is older
#        than stale_after_secs;
#      - watcher-stale: outside a supervisor turn and on a home with open
#        work or an away record, the watcher beat is older than its bound;
#      - mid-turn (unknown): inside a supervisor turn, the heartbeat is older
#        than stale_after_secs; it is never stale there, and a dead or
#        mismatched lock still outranks it;
#      - unknown: heartbeat-missing, heartbeat-field-unread, stale-bound-unknown,
#        lock-unknown, watcher-age-unknown (exempt like watcher-stale), or
#        monitor-<status> for any monitor status other than enabled.
#   4. ok: reason idle when the lock verdict is none, else fresh.
# A general unknown never upgrades any verdict to ok. The command only reads
# records: it types into no endpoint, signals no process and restarts nothing.
#
# Exit status: 0 on success, 2 on a usage error, 1 when --write cannot record
# the line.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '2,/^set -u/{/^set -u/d;s/^# \{0,1\}//;p;}' "$0"; }

home=${FM_HOME:-}
write=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)
      [ "$#" -ge 2 ] || { echo "fm-health-verdict.sh: --home needs a directory" >&2; exit 2; }
      home=$2; shift 2 ;;
    --write) write=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "fm-health-verdict.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$home" ] || { echo "fm-health-verdict.sh: no home: pass --home or set FM_HOME" >&2; exit 2; }
[ -d "$home" ] || { echo "fm-health-verdict.sh: not a directory: $home" >&2; exit 2; }
FM_HOME=$(cd "$home" && pwd)
export FM_HOME
unset FM_STATE_OVERRIDE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
# Loading the wake library creates its state directory. A read must never
# create or remove anything in the home, so load it against the home itself,
# which already exists, and only then name the real state directory.
STATE=$FM_HOME

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
STATE=$FM_HOME/state
FM_WAKE_QUEUE=$STATE/.wake-queue
FM_WAKE_QUEUE_LOCK=$STATE/.wake-queue.lock
# shellcheck source=bin/fm-watchdog-lib.sh
. "$SCRIPT_DIR/fm-watchdog-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-health-lib.sh
. "$SCRIPT_DIR/fm-health-lib.sh"

now=$(date +%s)
reasons_stale='' reasons_unknown=''
add_stale() { reasons_stale=${reasons_stale:+$reasons_stale,}$1; }
add_unknown() { reasons_unknown=${reasons_unknown:+$reasons_unknown,}$1; }

# The heartbeat: its age and its published stale bound.
hb_age=unknown bound=''
if [ ! -e "$STATE/heartbeat.json" ]; then
  add_unknown heartbeat-missing
else
  fields=$(jq -r '[(.published_epoch | if type == "number" and . >= 0 then floor | tostring else "-" end),
    (.stale_after_secs | if type == "number" and . >= 0 then floor | tostring else "-" end)] | join(" ")' \
    "$STATE/heartbeat.json" 2>/dev/null) || fields='- -'
  gen=${fields%% *} bound=${fields##* }
  case "$gen" in
    ''|-|*[!0-9]*) add_unknown heartbeat-field-unread ;;
    *) hb_age=$((now - gen)); [ "$hb_age" -ge 0 ] || hb_age=0 ;;
  esac
  case "$bound" in ''|-|*[!0-9]*) bound=''; add_unknown stale-bound-unknown ;; esac
fi

# The lock verdict the watchdog last recorded.
lock=unknown
case "$(fm_wd_conf_get "$STATE/watchdog/captain" alive '')" in
  live) lock=live ;;
  dead) lock=dead ;;
  unconfirmed) lock=mismatch ;;
  none) lock=none ;;
esac
[ "$lock" != unknown ] || add_unknown lock-unknown

# The watcher beat and its bound.
watcher_age=unknown
[ -e "$STATE/.last-watcher-beat" ] && watcher_age=$(fm_path_age "$STATE/.last-watcher-beat")
case "$watcher_age" in *[!0-9]*) watcher_age=unknown ;; esac
watcher_bound=$(fm_wd_conf_int "$FM_HOME/config/watchdog" watcher-stale-secs 900)

# The monitor unit, the outer guard: anything but enabled folds into unknown.
monitor=missing
if [ -e "$STATE/monitor-status" ]; then
  case "$(sed -n 's/^status=\([a-z]*\).*/\1/p' "$STATE/monitor-status" 2>/dev/null | tail -n 1)" in
    enabled) monitor=enabled ;;
    disabled) monitor=disabled ;;
    uncovered) monitor=uncovered ;;
    *) monitor=unreadable ;;
  esac
fi
[ "$monitor" = enabled ] || add_unknown "monitor-$monitor"

# A supervisor turn is under way when supervision reads healthy without a
# fresh beacon: only the between-turn watcher's own beat makes it fresh. Under
# the auto-arm model, an explicit mid-turn proof (a rewake claimed after the
# last beacon) also marks a turn, even while that beacon is inside grace.
grace=${FM_GUARD_GRACE:-300}
in_turn=0
fm_watcher_supervision_verdict "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$grace" "$FM_HOME" "$FM_ROOT"
if [ "$FM_WATCHER_VERDICT_OK" = true ]; then
  if [ "$watcher_age" = unknown ] || [ "$watcher_age" -ge "$grace" ]; then
    in_turn=1
  elif [ "$(fm_supervision_model)" = autoarm ] && fm_autoarm_midturn_healthy "$STATE" "$grace"; then
    in_turn=1
  fi
fi

open=0 away=0
fm_health_open_work "$FM_HOME" "$now" "$STATE" && open=1
[ -e "$STATE/.afk" ] && away=1

if [ -n "$bound" ] && [ "$hb_age" != unknown ] && [ "$hb_age" -gt "$bound" ]; then
  if [ "$in_turn" = 1 ]; then add_unknown mid-turn; else add_stale heartbeat-stale; fi
fi
if [ "$in_turn" = 0 ] && { [ "$open" = 1 ] || [ "$away" = 1 ]; }; then
  if [ "$watcher_age" = unknown ]; then
    add_unknown watcher-age-unknown
  elif [ "$watcher_age" -gt "$watcher_bound" ]; then
    add_stale watcher-stale
  fi
fi

if [ "$lock" = dead ]; then
  verdict=dead reason=lock-dead
elif [ "$lock" = none ] && [ "$open" = 1 ]; then
  verdict=dead reason=none-open-work
elif [ "$lock" = none ] && [ "$away" = 1 ]; then
  verdict=dead reason=none-away
elif [ "$lock" = mismatch ]; then
  verdict=unconfirmed reason=instance-mismatch
elif [ -n "$reasons_stale" ]; then
  verdict=stale reason=$reasons_stale${reasons_unknown:+,$reasons_unknown}
elif [ -n "$reasons_unknown" ]; then
  verdict=unknown reason=$reasons_unknown
elif [ "$lock" = none ]; then
  verdict=ok reason=idle
else
  verdict=ok reason=fresh
fi

line="verdict=$verdict reason=$reason heartbeat_age=$hb_age lock=$lock watcher_age=$watcher_age monitor=$monitor at=$now"
printf '%s\n' "$line"
if [ "$write" = 1 ]; then
  write_failed() { echo "fm-health-verdict.sh: cannot write $STATE/health-verdict" >&2; exit 1; }
  mkdir -p "$STATE" 2>/dev/null || write_failed
  tmp=$(mktemp "$STATE/.health-verdict.XXXXXX" 2>/dev/null) || write_failed
  if printf '%s\n' "$line" > "$tmp" && mv "$tmp" "$STATE/health-verdict"; then
    exit 0
  fi
  rm -f "$tmp"
  write_failed
fi
