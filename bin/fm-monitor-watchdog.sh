#!/usr/bin/env bash
# Keep one home-scoped watcher arm owned by a process manager, independently of
# the primary harness's turn-end hook. Run this as a foreground user service;
# launchd/systemd owns restarting this process if it itself is killed.
# Usage: FM_HOME=<absolute-home> fm-monitor-watchdog.sh
#   run|status|manager-name|manager-status|render-launchd|render-systemd
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:?FM_HOME must name the home this owner watches}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

WATCH="$SCRIPT_DIR/fm-watch.sh"
ARM="$SCRIPT_DIR/fm-watch-arm.sh"
if [ "${FM_GATE_REFUSE_BYPASS:-}" = 1 ] && [ -n "${FM_TEST_WATCHDOG_ARM:-}" ]; then
  ARM=$FM_TEST_WATCHDOG_ARM
fi
LOCK="$STATE/.monitor-watchdog.lock"
ALERT="$STATE/.monitor-watchdog-alert"
CHILD=
CAPTURE=

canonical_home() {
  case "$FM_HOME" in /*) ;; *) echo 'watchdog: FM_HOME must be absolute' >&2; return 2 ;; esac
  (cd -P -- "$FM_HOME" && pwd -P)
}

manager_name() {
  local home sum ignored
  home=$(canonical_home) || return
  read -r sum ignored <<EOF
$(printf '%s' "$home" | cksum)
EOF
  printf 'firstmate-monitor-watchdog-%s\n' "$sum"
}

xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

systemd_escape() {
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/%/%%/g'
}

render_launchd() {
  local home label script
  home=$(canonical_home) || return
  label=$(manager_name) || return
  script=$(printf '%s' "$SCRIPT_DIR/fm-monitor-watchdog.sh" | xml_escape)
  home=$(printf '%s' "$home" | xml_escape)
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$script</string><string>run</string>
  </array>
  <key>EnvironmentVariables</key><dict><key>FM_HOME</key><string>$home</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>1</integer>
</dict></plist>
EOF
}

render_systemd() {
  local home name script
  home=$(canonical_home) || return
  name=$(manager_name) || return
  script=$(printf '%s' "$SCRIPT_DIR/fm-monitor-watchdog.sh" | systemd_escape)
  home=$(printf '%s' "$home" | systemd_escape)
  cat <<EOF
[Unit]
Description=Firstmate home watcher owner ($name)
StartLimitIntervalSec=0

[Service]
Type=simple
Environment="FM_HOME=$home"
ExecStart=/bin/bash "$script" run
Restart=always
RestartSec=1s

[Install]
WantedBy=default.target
EOF
}

manager_status() {
  local name unit
  name=$(manager_name) || return
  case "$(uname -s)" in
    Darwin)
      unit="$HOME/Library/LaunchAgents/$name.plist"
      if [ ! -f "$unit" ]; then echo 'manager: uncovered (unit not installed)'; return 1; fi
      if launchctl print "gui/$(id -u)/$name" >/dev/null 2>&1; then
        echo "manager: enabled ($name)"; return 0
      fi ;;
    Linux)
      unit="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$name.service"
      if [ ! -f "$unit" ]; then echo 'manager: uncovered (unit not installed)'; return 1; fi
      if systemctl --user is-enabled --quiet "$name.service" \
        && systemctl --user is-active --quiet "$name.service"; then
        echo "manager: enabled ($name)"; return 0
      fi ;;
    *) echo 'manager: uncovered (unsupported platform)'; return 1 ;;
  esac
  echo "manager: disabled ($name)"
  return 1
}

watchdog_help() {
  cat <<'EOF'
Usage: FM_HOME=<absolute-home> fm-monitor-watchdog.sh <command>
  run              Foreground home owner; launchd or user systemd restarts it.
  status           Check the identity-matched watcher and fresh beacon.
  manager-name     Print this home's stable service label.
  manager-status   Report enabled, disabled, or uncovered native service.
  render-launchd   Print this home's macOS LaunchAgent plist.
  render-systemd   Print this home's Linux user service.

Install one rendered unit for this home only. On macOS, save render-launchd
as ~/Library/LaunchAgents/$(manager-name).plist, then use launchctl bootstrap
gui/$(id -u) <plist>. On Linux, save render-systemd as
~/.config/systemd/user/$(manager-name).service, run systemctl --user
daemon-reload, then systemctl --user enable --now <unit>. Use manager-status
after installation. Disable only this home's unit with launchctl bootout
gui/$(id -u)/<label> or systemctl --user disable --now <unit>.
EOF
}

watchdog_alert() {  # <arm-exit-code>
  local arm_rc=$1 page_state=failed tmp
  [ ! -f "$ALERT" ] || return 0
  page_state=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" \
    bash "$SCRIPT_DIR/fm-supervise-daemon.sh" page \
      "Firstmate watcher recovery failed for $FM_HOME" "$ALERT" 2>/dev/null) || true
  page_state=${page_state#page: }
  case "$page_state" in sent|failed|pending) ;; *) page_state=failed ;; esac
  tmp=$(mktemp "$STATE/.monitor-watchdog-alert.XXXXXX") || return 1
  if ! printf 'at=%s arm_exit=%s page=%s\n' "$(date +%s)" "$arm_rc" "$page_state" > "$tmp" \
    || ! mv -f -- "$tmp" "$ALERT"; then
    rm -f -- "$tmp"
    return 1
  fi
}

watchdog_cleanup() {
  if [ -n "$CHILD" ]; then
    kill -TERM "$CHILD" 2>/dev/null || true
    wait "$CHILD" 2>/dev/null || true
  fi
  [ -z "$CAPTURE" ] || rm -f -- "$CAPTURE"
  fm_lock_release "$LOCK" 2>/dev/null || true
}

watchdog_run() {
  local rc=0
  umask 077
  mkdir -p "$STATE" || return 1
  if ! fm_lock_try_acquire "$LOCK"; then
    echo 'watchdog: another owner holds this home' >&2
    return 1
  fi
  trap watchdog_cleanup EXIT
  trap 'exit 0' TERM INT
  while :; do
    CAPTURE=$(mktemp "$STATE/.monitor-watchdog-arm.XXXXXX") || return 1
    # This child is never fire-and-forget: the service waits for its complete
    # arm cycle and owns the next one. The watch lock still elects one watcher
    # if a Stop-hook arm or supervision host is active at the same time.
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" bash "$ARM" >"$CAPTURE" 2>&1 &
    CHILD=$!
    wait "$CHILD" || rc=$?
    CHILD=
    if [ "$rc" -ne 0 ]; then
      printf 'watchdog: arm exited %s: %s\n' "$rc" "$(tail -n 1 "$CAPTURE")" >&2
      if ! fm_watcher_healthy "$STATE" "$WATCH" "${FM_GUARD_GRACE:-300}" "$FM_HOME"; then
        watchdog_alert "$rc" || echo 'watchdog: could not persist recovery alert' >&2
      fi
    fi
    rm -f -- "$CAPTURE"
    CAPTURE=
    rc=0
    sleep 1
  done
}

watchdog_status() {
  if fm_watcher_healthy "$STATE" "$WATCH" "${FM_GUARD_GRACE:-300}" "$FM_HOME"; then
    printf 'watchdog: watcher healthy pid=%s\n' "$FM_WATCHER_HEALTHY_PID"
    return 0
  fi
  echo 'watchdog: no live watcher with a fresh beacon' >&2
  return 1
}

case "${1:-}" in
  run) [ "$#" -eq 1 ] || exit 2; watchdog_run ;;
  status) [ "$#" -eq 1 ] || exit 2; watchdog_status ;;
  manager-name) [ "$#" -eq 1 ] || exit 2; manager_name ;;
  manager-status) [ "$#" -eq 1 ] || exit 2; manager_status ;;
  render-launchd) [ "$#" -eq 1 ] || exit 2; render_launchd ;;
  render-systemd) [ "$#" -eq 1 ] || exit 2; render_systemd ;;
  help|--help|-h) watchdog_help ;;
  *) echo 'usage: FM_HOME=<absolute-home> fm-monitor-watchdog.sh run|status|manager-name|manager-status|render-launchd|render-systemd' >&2; exit 2 ;;
esac
