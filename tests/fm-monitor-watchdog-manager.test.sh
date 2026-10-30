#!/usr/bin/env bash
# Public manager contract: an uninstalled unit is uncovered, and rendered units
# restart the foreground owner without depending on a captain turn.
set -eu

. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-monitor-watchdog-manager-tests)
SCRIPT="$ROOT/bin/fm-monitor-watchdog.sh"
home=$(make_case manager)
mkdir -p "$home/config"

name=$(FM_HOME="$home" bash "$SCRIPT" manager-name)
case "$name" in firstmate-monitor-watchdog-*) ;; *) fail "invalid manager name: $name" ;; esac

if [ "$(uname -s)" = Darwin ]; then
  FM_HOME="$home" bash "$SCRIPT" manager-status > "$home/status.out" 2>&1 && fail 'uninstalled manager appeared covered'
  grep -q 'uncovered' "$home/status.out" || fail 'uninstalled manager was not reported uncovered'
  FM_HOME="$home" bash "$SCRIPT" render-launchd > "$home/$name.plist" || fail 'launchd render failed'
  plutil -lint "$home/$name.plist" >/dev/null || fail 'invalid launchd plist'
  grep -q '<key>KeepAlive</key>' "$home/$name.plist" || fail 'launchd unit does not restart owner'
  grep -q '<key>RunAtLoad</key>' "$home/$name.plist" || fail 'launchd unit does not start at login'
else
  FM_HOME="$home" bash "$SCRIPT" render-systemd > "$home/$name.service" || fail 'systemd render failed'
  grep -q '^Restart=always$' "$home/$name.service" || fail 'systemd unit does not restart owner'
  grep -q '^WantedBy=default.target$' "$home/$name.service" || fail 'systemd unit is not enableable'
fi
pass 'native manager render and uncovered status'
