#!/usr/bin/env bash
# tests/fm-relay-guard.test.sh - bin/fm-relay-guard.sh behavior.
#
# Every case drives real processes and no network: a symlink to sleep stands in
# for the network daemon, so its process name is the configured daemon name, and
# a shell script stands in for each relay. The fake relay records the daemon pid
# it started under, and the fake probe passes only while that recorded pid is the
# live daemon, so a relay that outlived a daemon restart is a genuinely stale
# relay that fails its reachability probe - the failure in issue #175.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-relay-guard.sh"
W=
WORLD_N=0
DAEMON_NAME=
SLEEP_BIN=$(type -P sleep)
FALSE_BIN=$(type -P false)

world() {
  W=$(fm_test_tmproot fm-relay-guard) || fail "tmproot"
  mkdir -p "$W/home/config" "$W/home/state" "$W/gen"
  # A distinct daemon name per case, so an earlier case's daemon is never seen.
  WORLD_N=$((WORLD_N + 1))
  DAEMON_NAME="fsd$$x$WORLD_N"  # under the 15-byte Linux comm limit
  ln -s "$SLEEP_BIN" "$W/$DAEMON_NAME"
  cat > "$W/fake-relay.sh" <<EOF
#!/bin/sh
cat "$W/daemon.pid" > "$W/gen/\$1" 2>/dev/null || : > "$W/gen/\$1"
while :; do sleep 0.2; done
EOF
  cat > "$W/fake-probe.sh" <<EOF
#!/bin/sh
d=\$(cat "$W/daemon.pid" 2>/dev/null) || exit 1
g=\$(cat "$W/gen/\$1" 2>/dev/null) || exit 1
[ -n "\$d" ] && [ "\$d" = "\$g" ] && kill -0 "\$d" 2>/dev/null
EOF
  chmod +x "$W/fake-relay.sh" "$W/fake-probe.sh"
}

conf() {
  cat > "$W/home/config/relay-guard"
}

std_conf() {
  conf <<EOF
# two relays bound to the fake daemon
daemon=$DAEMON_NAME
relay.m3=$W/fake-relay.sh m3 7001
probe.m3=$W/fake-probe.sh m3
relay.m4=$W/fake-relay.sh   m4 7002
probe.m4=$W/fake-probe.sh m4
settle-secs=1
term-wait-secs=3
EOF
}

start_daemon() {
  "$W/$DAEMON_NAME" 600 </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$W/daemon.pid"
}

stop_daemon() {
  local pid
  pid=$(cat "$W/daemon.pid")
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  : > "$W/daemon.pid"
}

# An externally started relay, as the box's own launcher leaves them.
start_relay() {  # <name> <port>
  nohup "$W/fake-relay.sh" "$1" "$2" </dev/null >/dev/null 2>&1 &
}

# Pids whose command line ends with exactly "fake-relay.sh <name> <port>".
relay_pids() {  # <name> <port>
  ps -A -ww -o pid= -o args= | while read -r pid args; do
    case "$args" in
      *" $W/fake-relay.sh $1 $2") printf '%s\n' "$pid" ;;
    esac
  done
}

guard() {
  FM_HOME="$W/home" bash "$GUARD" "$@"
}

alive() {
  kill -0 "$1" 2>/dev/null
}

test_stale_relays_after_daemon_restart_are_respawned() {
  local old_m3 old_m4 decoy new_m3 new_m4 out code
  world
  std_conf
  start_daemon
  start_relay m3 7001
  start_relay m4 7002
  start_relay decoy 7001
  sleep 0.5
  "$W/fake-probe.sh" m3 || fail "fixture relay should be healthy before the daemon restart"
  sleep 1.6
  stop_daemon
  start_daemon
  sleep 0.3
  old_m3=$(relay_pids m3 7001)
  old_m4=$(relay_pids m4 7002)
  decoy=$(relay_pids decoy 7001)
  [ -n "$old_m3" ] && [ -n "$old_m4" ] && [ -n "$decoy" ] || fail "fixture relays did not start"
  if "$W/fake-probe.sh" m3; then
    fail "fixture is vacuous: the relay that outlived the daemon still passes its probe"
  fi

  out=$(guard once 2>&1)
  code=$?
  [ "$code" -eq 0 ] || fail "once after a daemon restart exited $code: $out"
  new_m3=$(relay_pids m3 7001)
  new_m4=$(relay_pids m4 7002)
  [ -n "$new_m3" ] && [ "$new_m3" != "$old_m3" ] || fail "m3 relay was not respawned: $out"
  [ -n "$new_m4" ] && [ "$new_m4" != "$old_m4" ] || fail "m4 relay was not respawned: $out"
  if alive "$old_m3" || alive "$old_m4"; then
    fail "a stale relay survived the restart"
  fi
  alive "$decoy" || fail "the scoped stop reached an unrelated process"
  "$W/fake-probe.sh" m3 || fail "respawned m3 relay is not reachable"
  "$W/fake-probe.sh" m4 || fail "respawned m4 relay is not reachable"
  assert_grep 'daemon-restarted' "$W/home/state/relay-guard/actions.tsv"
  assert_contains "$(guard status)" "m3"

  out=$(guard once 2>&1)
  code=$?
  [ "$code" -eq 0 ] || fail "a second pass on healthy relays exited $code: $out"
  assert_equals "$new_m3" "$(relay_pids m3 7001)"
  assert_equals "$new_m4" "$(relay_pids m4 7002)"
  pass "relays that outlived a daemon restart are stopped, respawned, and probed reachable; a repeat pass changes nothing"
}

test_missing_relay_is_spawned_and_daemon_loss_waits_for_the_daemon() {
  local m3 m4 out code
  world
  std_conf
  start_daemon
  out=$(guard once 2>&1)
  code=$?
  [ "$code" -eq 0 ] || fail "spawning missing relays exited $code: $out"
  m3=$(relay_pids m3 7001)
  m4=$(relay_pids m4 7002)
  [ -n "$m3" ] && [ -n "$m4" ] || fail "missing relays were not spawned: $out"
  assert_grep 'missing' "$W/home/state/relay-guard/actions.tsv"

  stop_daemon
  out=$(guard once 2>&1)
  code=$?
  [ "$code" -eq 3 ] || fail "a pass with the daemon down should report unhealthy (3), got $code: $out"
  assert_contains "$out" "daemon-down"
  assert_equals "$m3" "$(relay_pids m3 7001)"

  sleep 1.2
  start_daemon
  out=$(guard once 2>&1)
  code=$?
  [ "$code" -eq 0 ] || fail "recovery after the daemon returned exited $code: $out"
  [ "$(relay_pids m3 7001)" != "$m3" ] || fail "relay was not restarted after the daemon returned"
  "$W/fake-probe.sh" m3 || fail "relay is not reachable after the daemon returned"
  pass "missing relays are spawned, a down daemon leaves relays alone, and its return restarts them"
}

test_duplicate_relays_converge_to_one() {
  local out code
  world
  std_conf
  start_daemon
  start_relay m4 7002
  start_relay m4 7002
  sleep 0.3
  [ "$(relay_pids m4 7002 | wc -l | tr -d ' ')" = 2 ] || fail "fixture duplicates did not start"
  out=$(guard once 2>&1)
  code=$?
  [ "$code" -eq 0 ] || fail "duplicate cleanup exited $code: $out"
  [ "$(relay_pids m4 7002 | wc -l | tr -d ' ')" = 1 ] || fail "duplicates did not converge to one relay: $out"
  pass "duplicate relays for one entry converge to a single relay"
}

test_probe_failures_restart_with_backoff_and_cap() {
  local out code pid
  world
  conf <<EOF
daemon=$DAEMON_NAME
relay.bad=$W/fake-relay.sh bad 7003
probe.bad=$FALSE_BIN
probe-fails=2
max-restarts=2
backoff-secs=0
window-secs=3600
settle-secs=0
term-wait-secs=3
EOF
  start_daemon
  out=$(guard once 2>&1)
  code=$?
  [ "$code" -eq 3 ] || fail "a spawned relay that fails its probe should report unhealthy, got $code: $out"
  pid=$(relay_pids bad 7003)
  [ -n "$pid" ] || fail "relay was not spawned: $out"
  out=$(guard once 2>&1)
  [ "$(relay_pids bad 7003)" != "$pid" ] || fail "a probe failure streak did not restart the relay: $out"
  pid=$(relay_pids bad 7003)
  out=$(guard once 2>&1)
  code=$?
  [ "$code" -eq 3 ] || fail "a capped relay should report unhealthy, got $code: $out"
  assert_contains "$out" "capped"
  out=$(guard once 2>&1)
  assert_equals "$pid" "$(relay_pids bad 7003)"
  [ "$(awk -F '\t' '$2 == "bad" && ($3 == "spawn" || $3 == "restart")' "$W/home/state/relay-guard/actions.tsv" | wc -l | tr -d ' ')" = 2 ] ||
    fail "expected exactly max-restarts starts in the window: $(cat "$W/home/state/relay-guard/actions.tsv")"
  pass "probe failures restart only after the streak, and the restart cap stops further restarts"
}

test_backoff_defers_a_second_restart() {
  local out pid
  world
  conf <<EOF
daemon=$DAEMON_NAME
relay.bad=$W/fake-relay.sh bad 7003
probe.bad=$FALSE_BIN
probe-fails=1
max-restarts=5
backoff-secs=600
settle-secs=0
EOF
  start_daemon
  guard once >/dev/null 2>&1
  pid=$(relay_pids bad 7003)
  [ -n "$pid" ] || fail "relay was not spawned"
  out=$(guard once 2>&1)
  assert_contains "$out" "backoff"
  assert_equals "$pid" "$(relay_pids bad 7003)"
  pass "backoff defers a restart that comes too soon after the previous one"
}

test_scan_reports_without_acting() {
  local old out
  world
  std_conf
  start_daemon
  start_relay m3 7001
  start_relay m4 7002
  sleep 2.1
  stop_daemon
  start_daemon
  sleep 0.3
  old=$(relay_pids m3 7001)
  out=$(guard scan 2>&1) || fail "scan failed: $out"
  assert_contains "$out" "daemon-restarted"
  assert_equals "$old" "$(relay_pids m3 7001)"
  assert_absent "$W/home/state/relay-guard/actions.tsv"
  pass "scan reports a stale relay without stopping or starting anything"
}

test_bad_config_is_refused() {
  local code
  world
  guard once >/dev/null 2>&1
  code=$?
  [ "$code" -eq 2 ] || fail "a missing config should exit 2, got $code"
  conf <<EOF
daemon=$DAEMON_NAME
EOF
  guard once >/dev/null 2>&1
  code=$?
  [ "$code" -eq 2 ] || fail "a config with no relays should exit 2, got $code"
  conf <<EOF
relay.m3=$W/fake-relay.sh m3 7001
relay-typo=1
EOF
  guard once >/dev/null 2>&1
  code=$?
  [ "$code" -eq 2 ] || fail "an unknown key should exit 2, got $code"
  conf <<EOF
relay.m3=$W/fake-relay.sh m3 7001
probe.m9=$FALSE_BIN
EOF
  guard once >/dev/null 2>&1
  code=$?
  [ "$code" -eq 2 ] || fail "a probe for an unknown relay should exit 2, got $code"
  conf <<EOF
relay.m3=$W/fake-relay.sh m3 7001
max-restarts=many
EOF
  guard once >/dev/null 2>&1
  code=$?
  [ "$code" -eq 2 ] || fail "a non-numeric limit should exit 2, got $code"
  guard bogus >/dev/null 2>&1
  code=$?
  [ "$code" -eq 2 ] || fail "an unknown command should exit 2, got $code"
  pass "missing, empty, misspelled, dangling, and non-numeric configuration is refused before any action"
}

fm_test_run \
  test_stale_relays_after_daemon_restart_are_respawned \
  test_missing_relay_is_spawned_and_daemon_loss_waits_for_the_daemon \
  test_duplicate_relays_converge_to_one \
  test_probe_failures_restart_with_backoff_and_cap \
  test_backoff_defers_a_second_restart \
  test_scan_reports_without_acting \
  test_bad_config_is_refused
