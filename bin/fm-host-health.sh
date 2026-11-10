#!/usr/bin/env bash
# fm-host-health.sh - independent, read-only host probes for an external watchdog.
#
# Usage: FM_HOME=<absolute-home> fm-host-health.sh [run|render-launchd|--help]
# Environment (also captured by render-launchd):
#   FM_HOSTHEALTH_BEACON_LOG  Absolute existing host beacon log, or default
#                            $FM_HOME/state/host-health-beacon.log.
#   FM_HOSTHEALTH_SSH_ALIAS   Optional SSH-config alias; empty skips SSH.
#   FM_HOSTHEALTH_TIMEOUT_SECS  Per-command bound, integer 1..60 (default 5).
#   USER                     Local account for /Users/$USER; never derived
#                            from id, so a broken identity lookup cannot hide dscl.
#
# Each run appends and prints exactly one observation, with keys in this order:
# HOSTHEALTH v1 ts=<epoch-seconds> ok=<0|1> fail=<checks> ssh=<ok|fail|skip>
#   uptime_b64=<base64|unknown> load1=<n|unknown> load5=<n|unknown> load15=<n|unknown>
# (One physical line.) fail=none when healthy, otherwise comma-separated names
# in probe order: id,dscl,gh_auth,gh_api,ssh,uptime. No spaces in values.
# uptime_b64 is the base64-encoded C-locale uptime output without its trailing
# newline. Load values are decimal numbers from that same output. Failed or
# unparseable uptime sets all four diagnostic fields to unknown and fails uptime.
# High load/long uptime do not change health. SSH skip is healthy, not a check.
# Command output is suppressed: credentials and untrusted errors are not logged.
# ts is sample START time, so a delayed/hung sample cannot claim fresh evidence.
# Exit 0 = healthy and published; 1 = unhealthy and published; 2 = config or
# publication error (stderr: HOSTHEALTH_ERROR v1 code=<name>, no healthy stdout).
#
# render-launchd prints a home-scoped LaunchAgent plist: RunAtLoad plus a
# 300-second StartInterval, no KeepAlive retry loop. Captures PATH, HOME, USER,
# FM_HOME and the settings above; render from the intended account/environment.
# It only renders XML and never installs, starts, or restarts a service.
# Save it as ~/Library/LaunchAgents/<Label>.plist, then explicitly activate:
#   launchctl bootstrap gui/$(id -u) <absolute-plist-path>
# Rollback: launchctl bootout gui/$(id -u)/<Label>
# Paging the owner is TODO pending a channel choice; no pager or repair here.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

health_error() {
  printf 'HOSTHEALTH_ERROR v1 code=%s\n' "$1" >&2
  exit 2
}

health_help() {
  sed -n '2,/^set -u/{ /^set -u/d; s/^# \{0,1\}//; p; }' "$SCRIPT_DIR/fm-host-health.sh"
}

case "${1:-run}" in
  --help|-h) health_help; exit 0 ;;
  run|render-launchd) MODE=${1:-run} ;;
  *) health_error usage ;;
esac
[ "$#" -le 1 ] || health_error usage

case "${FM_HOME:-}" in /*) ;; *) health_error home ;; esac
BEACON=${FM_HOSTHEALTH_BEACON_LOG:-$FM_HOME/state/host-health-beacon.log}
case "$BEACON" in /*) ;; *) health_error beacon_path ;; esac
BOUND=${FM_HOSTHEALTH_TIMEOUT_SECS:-5}
case "$BOUND" in ''|0*|*[!0-9]*) health_error timeout ;; esac
[ "${#BOUND}" -le 2 ] && [ "$BOUND" -le 60 ] || health_error timeout
SSH_ALIAS=${FM_HOSTHEALTH_SSH_ALIAS:-}
case "$SSH_ALIAS" in -*|*[!a-zA-Z0-9._-]*) health_error ssh_alias ;; esac

xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

render_launchd() {
  local sum key value
  read -r sum _ <<EOF
$(printf '%s' "$FM_HOME" | cksum)
EOF
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.firstmate.host-health-$sum</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$(printf '%s' "$SCRIPT_DIR/fm-host-health.sh" | xml_escape)</string><string>run</string>
  </array>
  <key>EnvironmentVariables</key><dict>
EOF
  for key in FM_HOME HOME USER PATH FM_HOSTHEALTH_BEACON_LOG FM_HOSTHEALTH_SSH_ALIAS FM_HOSTHEALTH_TIMEOUT_SECS; do
    case "$key" in
      FM_HOSTHEALTH_BEACON_LOG) value=$BEACON ;;
      FM_HOSTHEALTH_SSH_ALIAS) value=$SSH_ALIAS ;;
      FM_HOSTHEALTH_TIMEOUT_SECS) value=$BOUND ;;
      *) value=${!key:-} ;;
    esac
    printf '    <key>%s</key><string>%s</string>\n' "$key" "$(printf '%s' "$value" | xml_escape)"
  done
  cat <<'EOF'
  </dict>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>300</integer>
</dict></plist>
EOF
}

if [ "$MODE" = render-launchd ]; then render_launchd; exit; fi

export LC_ALL=C
TS=$(date +%s) || health_error clock
case "$TS" in ''|*[!0-9]*) health_error clock ;; esac
FAIL=
mark_failed() { FAIL="${FAIL:+$FAIL,}$1"; }
probe() { fm_run_timed "$BOUND" "$@" </dev/null 2>/dev/null; }

IDENTITY=$(probe id -un) || IDENTITY=
[ -n "$IDENTITY" ] || mark_failed id
# Do not fall back to id for USER: that is the failing dependency under test.
if [ -z "${USER:-}" ] || ! probe dscl . -read "/Users/$USER" UniqueID >/dev/null; then
  mark_failed dscl
fi
probe gh auth status >/dev/null || mark_failed gh_auth
probe gh api /rate_limit >/dev/null || mark_failed gh_api
SSH=skip
if [ -n "$SSH_ALIAS" ]; then
  SSH=ok
  if ! probe ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_ALIAS" true >/dev/null; then
    SSH=fail
    mark_failed ssh
  fi
fi

UPTIME_B64=unknown LOAD1=unknown LOAD5=unknown LOAD15=unknown
if UPTIME=$(probe uptime) &&
  read -r LOAD1 LOAD5 LOAD15 < <(printf '%s\n' "$UPTIME" | awk '
    /load averages?:/ { sub(/^.*load averages?:[[:space:]]*/, ""); gsub(/,/, ""); print $1, $2, $3 }
  ') &&
  [[ "$LOAD1" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
  [[ "$LOAD5" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
  [[ "$LOAD15" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  UPTIME_B64=$(printf '%s' "$UPTIME" | base64 2>/dev/null | tr -d '\r\n')
  if [ -z "$UPTIME_B64" ]; then
    UPTIME_B64=unknown LOAD1=unknown LOAD5=unknown LOAD15=unknown
    mark_failed uptime
  fi
else
  UPTIME_B64=unknown LOAD1=unknown LOAD5=unknown LOAD15=unknown
  mark_failed uptime
fi
OK=1
[ -z "$FAIL" ] || OK=0
LINE="HOSTHEALTH v1 ts=$TS ok=$OK fail=${FAIL:-none} ssh=$SSH uptime_b64=$UPTIME_B64 load1=$LOAD1 load5=$LOAD5 load15=$LOAD15"
mkdir -p "$(dirname "$BEACON")" 2>/dev/null || health_error beacon_write
if ! { printf '%s\n' "$LINE" >> "$BEACON"; } 2>/dev/null; then
  health_error beacon_write
fi
printf '%s\n' "$LINE"
[ "$OK" = 1 ]
