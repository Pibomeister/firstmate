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
BASH_BIN=$(type -P bash)
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

# A daemon that re-executes itself as a helper, as tailscaled does for each
# Tailscale SSH session (`tailscaled be-child ssh`): a bash symlink with the
# daemon name waits for a trigger, then starts a daemon-named child.
start_daemon_with_helper() {
  mkdir -p "$W/b"
  ln -s "$BASH_BIN" "$W/b/$DAEMON_NAME"
  # shellcheck disable=SC2016 # the daemon script expands its own arguments.
  "$W/b/$DAEMON_NAME" -c 'while [ ! -f "$1/helper.go" ]; do sleep 0.1; done
"$1/$2" 600 &
printf "%s\n" "$!" > "$1/helper.pid"
wait' fake "$W" "$DAEMON_NAME" </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$W/daemon.pid"
}

test_daemon_helper_is_not_a_daemon_restart() {
  local m3 m4 out code i
  world
  std_conf
  start_daemon_with_helper
  sleep 0.3
  start_relay m3 7001
  start_relay m4 7002
  sleep 1.6
  : > "$W/helper.go"
  i=0
  while [ ! -s "$W/helper.pid" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$W/helper.pid" ] || fail "fixture helper did not start"
  m3=$(relay_pids m3 7001)
  m4=$(relay_pids m4 7002)
  [ -n "$m3" ] && [ -n "$m4" ] || fail "fixture relays did not start"
  "$W/fake-probe.sh" m3 || fail "fixture relay should be healthy beside the helper"

  out=$(guard once 2>&1)
  code=$?
  kill "$(cat "$W/helper.pid")" "$(cat "$W/daemon.pid")" 2>/dev/null
  [ "$code" -eq 0 ] || fail "a pass beside a daemon helper exited $code: $out"
  assert_equals "$m3" "$(relay_pids m3 7001)"
  assert_equals "$m4" "$(relay_pids m4 7002)"
  assert_absent "$W/home/state/relay-guard/actions.tsv"
  assert_contains "$out" "daemon-pid=$(cat "$W/daemon.pid")"
  pass "a daemon-named helper the daemon spawns is not mistaken for a daemon restart"
}

test_rendered_units_run_the_guard() {
  local home label unit
  world
  home=$(cd -P "$W/home" && pwd -P)
  unit=$(FM_HOME="$home" bash "$GUARD" render-systemd) || fail "render-systemd failed"
  label=$(printf '%s\n' "$unit" | sed -n 's/^Description=Firstmate relay guard (\(.*\))$/\1/p')
  case "$label" in firstmate-relay-guard-*) ;; *) fail "systemd unit has no guard label: $unit" ;; esac
  assert_equals "/bin/bash \"$ROOT/bin/fm-relay-guard.sh\" run" "$(printf '%s\n' "$unit" | sed -n 's/^ExecStart=//p')"
  assert_equals "\"FM_HOME=$home\"" "$(printf '%s\n' "$unit" | sed -n 's/^Environment="FM_HOME/"FM_HOME/p')"
  assert_equals "\"PATH=$PATH\"" "$(printf '%s\n' "$unit" | sed -n 's/^Environment="PATH/"PATH/p')"
  assert_equals "always" "$(printf '%s\n' "$unit" | sed -n 's/^Restart=//p')"
  assert_equals "process" "$(printf '%s\n' "$unit" | sed -n 's/^KillMode=//p')"
  if command -v systemd-analyze >/dev/null 2>&1; then
    printf '%s\n' "$unit" > "$W/$label.service"
    systemd-analyze --user verify "$W/$label.service" >/dev/null 2>&1 || fail "systemd-analyze rejected the unit"
  fi
  FM_HOME="$home" bash "$GUARD" render-launchd > "$W/$label.plist" || fail "render-launchd failed"
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$W/$label.plist" >/dev/null || fail "invalid launchd plist"
    assert_equals "$label" "$(plutil -extract Label raw -o - "$W/$label.plist")"
    assert_equals "/bin/bash" "$(plutil -extract ProgramArguments.0 raw -o - "$W/$label.plist")"
    assert_equals "$ROOT/bin/fm-relay-guard.sh" "$(plutil -extract ProgramArguments.1 raw -o - "$W/$label.plist")"
    assert_equals "run" "$(plutil -extract ProgramArguments.2 raw -o - "$W/$label.plist")"
    assert_equals "$home" "$(plutil -extract EnvironmentVariables.FM_HOME raw -o - "$W/$label.plist")"
    assert_equals "true" "$(plutil -extract KeepAlive raw -o - "$W/$label.plist")"
    assert_equals "true" "$(plutil -extract AbandonProcessGroup raw -o - "$W/$label.plist")"
    assert_equals "$PATH" "$(plutil -extract EnvironmentVariables.PATH raw -o - "$W/$label.plist")"
  fi
  FM_HOME=relative bash "$GUARD" render-systemd >/dev/null 2>&1
  [ "$?" -eq 2 ] || fail "a relative FM_HOME should be refused"
  pass "rendered launchd and systemd units keep the guard's run loop alive for this home"
}

test_run_stops_promptly_during_the_interval() {
  local pid m3 i code sleeper
  world
  std_conf
  start_daemon
  FM_HOME="$W/home" bash "$GUARD" run --interval 600 >/dev/null 2>&1 &
  pid=$!
  i=0
  while [ ! -f "$W/home/state/relay-guard/status.tsv" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -f "$W/home/state/relay-guard/status.tsv" ] || fail "run did not complete a first pass"
  sleep 0.3
  m3=$(relay_pids m3 7001)
  [ -n "$m3" ] || fail "run did not spawn the relay"
  sleeper=$(ps -A -o pid= -o ppid= -o args= | awk -v p="$pid" '$2 == p && $3 ~ /sleep$/ && $4 == "600" { print $1 }')
  [ -n "$sleeper" ] || fail "run is not waiting on its interval"
  kill -TERM "$pid"
  i=0
  while alive "$pid" && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
  if alive "$pid"; then
    kill -KILL "$pid" 2>/dev/null
    fail "run did not exit within 3s of TERM during its interval"
  fi
  wait "$pid"
  code=$?
  assert_equals 143 "$code"
  alive "$sleeper" && fail "run left its interval sleep behind"
  assert_equals "$m3" "$(relay_pids m3 7001)"
  assert_absent "$W/home/state/relay-guard/lock.d"
  kill "$m3" "$(relay_pids m4 7002)" 2>/dev/null
  stop_daemon
  pass "a TERM during the run interval exits at once, reaps the sleep, and leaves relays running"
}

test_example_config_is_accepted() {
  local out code
  world
  cp "$ROOT/docs/examples/relay-guard" "$W/home/config/relay-guard"
  out=$(guard scan 2>&1)
  code=$?
  [ "$code" -eq 0 ] || fail "the example config was refused ($code): $out"
  assert_contains "$out" "m3"
  assert_contains "$out" "m4"
  assert_contains "$out" "studio"
  pass "the example m3-forward config is accepted by the guard"
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
probe.m3=$FALSE_BIN
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
probe.m3=$FALSE_BIN
max-restarts=many
EOF
  guard once >/dev/null 2>&1
  code=$?
  [ "$code" -eq 2 ] || fail "a non-numeric limit should exit 2, got $code"
  start_daemon
  conf <<EOF
daemon=$DAEMON_NAME
relay.m3=$W/fake-relay.sh m3 7001
probe.m3=$W/fake-probe.sh m3
relay.m4=$W/fake-relay.sh m4 7002
EOF
  guard once >/dev/null 2>&1
  code=$?
  stop_daemon
  [ "$code" -eq 2 ] || fail "a relay without a probe should exit 2, got $code"
  [ -z "$(relay_pids m3 7001)" ] || fail "a refused config started a relay"
  assert_absent "$W/home/state/relay-guard"
  guard bogus >/dev/null 2>&1
  code=$?
  [ "$code" -eq 2 ] || fail "an unknown command should exit 2, got $code"
  pass "missing, empty, misspelled, dangling, probe-less, and non-numeric configuration is refused before any action"
}

test_lock_without_pid_is_held_until_it_ages() {
  local out code
  world
  std_conf
  start_daemon
  # A contender can see lock.d in the instant between the owner's mkdir and
  # its pid write. That lock is live, not stale.
  mkdir -p "$W/home/state/relay-guard/lock.d"
  out=$(guard once 2>&1)
  code=$?
  [ "$code" -eq 75 ] || fail "a fresh lock with no pid yet should be held (exit 75), got $code: $out"
  [ -d "$W/home/state/relay-guard/lock.d" ] || fail "a held fresh lock was removed"
  [ -z "$(relay_pids m3 7001)" ] || fail "a pass ran while another pass held a fresh lock"
  # A pid-less lock left behind long ago is a crashed owner's, so it is stale.
  touch -t 202001010000 "$W/home/state/relay-guard/lock.d"
  out=$(guard once 2>&1)
  code=$?
  [ "$code" -eq 0 ] || fail "an old pid-less lock should be reclaimed, got $code: $out"
  [ -n "$(relay_pids m3 7001)" ] || fail "the pass after reclaiming a stale lock did not run"
  assert_absent "$W/home/state/relay-guard/lock.d"
  stop_daemon
  pass "a pid-less lock is held while fresh and reclaimed only once it is old"
}

test_lock_of_a_reused_pid_is_reclaimed() {
  local out code holder
  world
  std_conf
  start_daemon
  # After a crash and reboot, lock.d can name a pid that is alive again as
  # another process. Only the same pid with the same start time holds it.
  sleep 600 >/dev/null 2>&1 &
  holder=$!
  mkdir -p "$W/home/state/relay-guard/lock.d"
  printf '%s\n%s\n' "$holder" "$(ps -o lstart= -p "$holder")" > "$W/home/state/relay-guard/lock.d/pid"
  out=$(guard once 2>&1)
  code=$?
  [ "$code" -eq 75 ] || fail "a lock whose live owner kept its start time should be held (exit 75), got $code: $out"
  [ -z "$(relay_pids m3 7001)" ] || fail "a pass ran while a live owner held the lock"
  printf '%s\n%s\n' "$holder" "Thu Jan  1 00:00:00 2020" > "$W/home/state/relay-guard/lock.d/pid"
  out=$(guard once 2>&1)
  code=$?
  [ "$code" -eq 0 ] || fail "a lock whose pid now has another start time should be reclaimed, got $code: $out"
  [ -n "$(relay_pids m3 7001)" ] || fail "the pass after reclaiming a reused-pid lock did not run"
  printf '%s\n' "$holder" > "$W/home/state/relay-guard/lock.d.tmp"
  mkdir -p "$W/home/state/relay-guard/lock.d"
  mv "$W/home/state/relay-guard/lock.d.tmp" "$W/home/state/relay-guard/lock.d/pid"
  out=$(guard once 2>&1)
  code=$?
  [ "$code" -eq 0 ] || fail "a lock naming a live pid with no start time should be reclaimed, got $code: $out"
  assert_absent "$W/home/state/relay-guard/lock.d"
  [ -z "$(ls -d "$W/home/state/relay-guard"/lock.stale.* 2>/dev/null)" ] || fail "a reclaimed lock was left behind"
  kill "$holder" 2>/dev/null
  kill "$(relay_pids m3 7001)" "$(relay_pids m4 7002)" 2>/dev/null
  stop_daemon
  pass "a lock is held only by its live owner with the same start time; a reused pid is reclaimed"
}

test_contenders_on_a_stale_lock_run_one_pass_at_a_time() {
  local i pids=() code n
  world
  std_conf
  start_daemon
  mkdir -p "$W/home/state/relay-guard/lock.d"
  printf '%s\n%s\n' 999999 "Thu Jan  1 00:00:00 2020" > "$W/home/state/relay-guard/lock.d/pid"
  for i in 1 2 3 4 5 6; do
    guard once >"$W/contender.$i" 2>&1 &
    pids+=("$!")
  done
  n=0
  for i in "${pids[@]}"; do
    wait "$i"
    code=$?
    [ "$code" -eq 0 ] && n=$((n + 1))
    [ "$code" -eq 0 ] || [ "$code" -eq 75 ] || fail "a contender exited $code"
  done
  [ "$n" -ge 1 ] || fail "no contender reclaimed the stale lock"
  [ "$(relay_pids m3 7001 | wc -l | tr -d ' ')" -eq 1 ] || fail "concurrent passes started duplicate relays: $(relay_pids m3 7001 | tr '\n' ' ')"
  [ "$(relay_pids m4 7002 | wc -l | tr -d ' ')" -eq 1 ] || fail "concurrent passes started duplicate m4 relays"
  assert_absent "$W/home/state/relay-guard/lock.d"
  [ -z "$(ls -d "$W/home/state/relay-guard"/lock.stale.* 2>/dev/null)" ] || fail "a reclaimed lock was left behind"
  kill $(relay_pids m3 7001) $(relay_pids m4 7002) 2>/dev/null
  stop_daemon
  pass "contenders racing to reclaim a stale lock run their passes one at a time"
}

test_kill_spares_a_pid_that_is_no_longer_the_relay() {
  local stubborn out real_ps
  world
  real_ps=$(type -P ps)
  cat > "$W/stubborn-relay.sh" <<EOF
#!/bin/sh
trap '' TERM
cat "$W/daemon.pid" > "$W/gen/\$1" 2>/dev/null || : > "$W/gen/\$1"
while :; do sleep 0.2; done
EOF
  chmod +x "$W/stubborn-relay.sh"
  # A ps stand-in that reports a different start time for a marked pid after
  # its first start-time read: the pid now belongs to another process.
  mkdir -p "$W/shim"
  cat > "$W/shim/ps" <<EOF
#!/bin/sh
if [ "\$1" = -o ] && [ "\$2" = lstart= ] && [ "\$3" = -p ] && [ -f "$W/reuse.\$4" ]; then
  n=\$(( \$(cat "$W/reuse.\$4") + 1 ))
  printf '%s\n' "\$n" > "$W/reuse.\$4"
  if [ "\$n" -gt 1 ]; then printf 'Sat Jan  1 00:00:00 2000\n'; exit 0; fi
fi
exec "$real_ps" "\$@"
EOF
  chmod +x "$W/shim/ps"
  conf <<EOF
daemon=$DAEMON_NAME
relay.s=$W/stubborn-relay.sh s 7009
probe.s=$W/fake-probe.sh s
settle-secs=1
term-wait-secs=1
EOF
  start_daemon
  nohup "$W/stubborn-relay.sh" s 7009 </dev/null >/dev/null 2>&1 &
  stubborn=$!
  sleep 1.2
  stop_daemon
  start_daemon
  sleep 0.3
  # Control: a relay that ignores TERM and is still itself is KILLed.
  out=$(guard once 2>&1)
  if alive "$stubborn"; then
    kill -KILL "$stubborn" 2>/dev/null
    fail "control is vacuous: a TERM-proof relay that is still itself was not KILLed: $out"
  fi
  pkill -KILL -f "$W/stubborn-relay.sh" 2>/dev/null
  sleep 0.3
  nohup "$W/stubborn-relay.sh" s 7009 </dev/null >/dev/null 2>&1 &
  stubborn=$!
  sleep 1.2
  stop_daemon
  start_daemon
  sleep 0.3
  printf '0\n' > "$W/reuse.$stubborn"
  out=$(PATH="$W/shim:$PATH" guard once 2>&1)
  if ! alive "$stubborn"; then
    fail "KILL reached a pid whose start time changed after TERM: $out"
  fi
  pkill -KILL -f "$W/stubborn-relay.sh" 2>/dev/null
  stop_daemon
  pass "KILL reaches a TERM-proof relay, never a pid that stopped being that relay"
}

test_relay_started_in_the_daemon_restart_second_is_restarted() {
  local old new out code dead
  world
  std_conf
  start_daemon
  sleep 1.2
  dead=$(cat "$W/daemon.pid")
  stop_daemon
  # The relay starts while no daemon runs, and the new daemon starts in the
  # same second, so both report the same whole-second age. The relay's sockets
  # belong to the daemon that just died, which its generation record shows.
  start_relay m3 7001
  start_daemon
  start_relay m4 7002
  sleep 1.3
  printf '%s\n' "$dead" > "$W/gen/m3"
  old=$(relay_pids m3 7001)
  [ -n "$old" ] || fail "fixture relay did not start"
  if "$W/fake-probe.sh" m3; then
    fail "fixture is vacuous: a relay older than the daemon passes its probe"
  fi
  out=$(guard once 2>&1)
  code=$?
  new=$(relay_pids m3 7001)
  [ -n "$new" ] && [ "$new" != "$old" ] || fail "a relay from the daemon restart second was not restarted ($code): $out"
  assert_grep "$(printf 'm3\trestart\tdaemon-restarted')" "$W/home/state/relay-guard/actions.tsv" "m3 restart was not recorded as daemon-restarted: $out"
  "$W/fake-probe.sh" m3 || fail "restarted m3 relay is not reachable"
  stop_daemon
  pass "a relay as old as the daemon in whole seconds counts as predating the daemon"
}

fm_test_run \
  test_lock_without_pid_is_held_until_it_ages \
  test_lock_of_a_reused_pid_is_reclaimed \
  test_contenders_on_a_stale_lock_run_one_pass_at_a_time \
  test_kill_spares_a_pid_that_is_no_longer_the_relay \
  test_relay_started_in_the_daemon_restart_second_is_restarted \
  test_stale_relays_after_daemon_restart_are_respawned \
  test_missing_relay_is_spawned_and_daemon_loss_waits_for_the_daemon \
  test_duplicate_relays_converge_to_one \
  test_probe_failures_restart_with_backoff_and_cap \
  test_backoff_defers_a_second_restart \
  test_daemon_helper_is_not_a_daemon_restart \
  test_rendered_units_run_the_guard \
  test_run_stops_promptly_during_the_interval \
  test_example_config_is_accepted \
  test_scan_reports_without_acting \
  test_bad_config_is_refused
