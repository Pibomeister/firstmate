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
CAT_BIN=$(type -P cat)
MKDIR_BIN=$(type -P mkdir)
TR_BIN=$(type -P tr)
PS_BIN=$(type -P ps)

world() {
  W=$(fm_test_tmproot fm-relay-guard) || fail "tmproot"
  mkdir -p "$W/home/config" "$W/home/state" "$W/gen"
  # A distinct daemon name per case, so an earlier case's daemon is never seen.
  WORLD_N=$((WORLD_N + 1))
  DAEMON_NAME="fsd$$x$WORLD_N"  # under the 15-byte Linux comm limit
  ln -s "$SLEEP_BIN" "$W/$DAEMON_NAME"
  # Fixtures call their tools by absolute path, so a PATH shim a case installs
  # for the guard sees only the guard's own calls.
  cat > "$W/fake-relay.sh" <<EOF
#!/bin/sh
"$CAT_BIN" "$W/daemon.pid" > "$W/gen/\$1" 2>/dev/null || : > "$W/gen/\$1"
while :; do "$SLEEP_BIN" 0.2; done
EOF
  cat > "$W/fake-probe.sh" <<EOF
#!/bin/sh
d=\$("$CAT_BIN" "$W/daemon.pid" 2>/dev/null) || exit 1
g=\$("$CAT_BIN" "$W/gen/\$1" 2>/dev/null) || exit 1
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
  local out pid i
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
  # With no settle time the detached relay may still be exec'ing.
  i=0
  pid=$(relay_pids bad 7003)
  while [ -z "$pid" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); pid=$(relay_pids bad 7003); done
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
  # Relays a whole second newer than the daemon: an equal whole-second age
  # counts as a relay that may predate the daemon.
  sleep 1.2
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
  code=0
  guard once >/dev/null 2>&1 || code=$?
  [ "$code" -ne 75 ] || fail "run left the pass lock held after it exited"
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


# One relay, started newer than the daemon, so every pass runs its probe.
probed_world() {  # <probe-script>
  start_daemon
  sleep 1.2
  start_relay m3 7001
  conf <<EOF
daemon=$DAEMON_NAME
relay.m3=$W/fake-relay.sh m3 7001
probe.m3=$1 m3
settle-secs=1
term-wait-secs=3
EOF
}

# A probe that records any second pass whose probe runs while one is in flight,
# then answers as the ordinary fake probe does.
overlap_probe() {
  cat > "$W/overlap-probe.sh" <<EOF
#!/bin/sh
if mkdir "$W/inpass" 2>/dev/null; then
  sleep 1.2
  rmdir "$W/inpass"
else
  : > "$W/overlap"
fi
exec "$W/fake-probe.sh" "\$@"
EOF
  chmod +x "$W/overlap-probe.sh"
}

# A probe that blocks until released, so a test can crash a pass mid-probe.
blocking_probe() {
  cat > "$W/blocking-probe.sh" <<EOF
#!/bin/sh
: > "$W/probing"
while [ ! -f "$W/release" ]; do sleep 0.1; done
exec "$W/fake-probe.sh" "\$@"
EOF
  chmod +x "$W/blocking-probe.sh"
}

wait_for_file() {  # <path>
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$1" ]
}

test_a_crashed_pass_never_blocks_the_next() {
  local gpid out code
  world
  blocking_probe
  probed_world "$W/blocking-probe.sh"
  FM_HOME="$W/home" bash "$GUARD" once >/dev/null 2>&1 &
  gpid=$!
  wait_for_file "$W/probing" || fail "the pass never reached its probe"
  out=$(guard once 2>&1)
  code=$?
  [ "$code" -eq 75 ] || fail "a pass while another is in flight should exit 75, got $code: $out"
  # The pass dies mid-probe and leaves its probe running, as a crash or an
  # OOM kill would. Nothing it left behind may hold the lock.
  kill -KILL "$gpid" 2>/dev/null
  wait "$gpid" 2>/dev/null
  rm -f "$W/probing"
  : > "$W/release"
  out=$(guard once 2>&1)
  code=$?
  [ "$code" -eq 0 ] || fail "the pass after a crashed pass should run at once, got $code: $out"
  out=$(guard once 2>&1)
  code=$?
  [ "$code" -eq 0 ] || fail "a finished pass left the lock held, got $code: $out"
  relay_pids m3 7001 | while read -r p; do kill "$p" 2>/dev/null; done
  stop_daemon
  pass "a pass killed mid-probe releases the lock at once, and its orphaned probe does not hold it"
}

test_concurrent_passes_never_overlap() {
  local real_mv gpid i pids=() code n=0
  world
  overlap_probe
  probed_world "$W/overlap-probe.sh"
  # A directory rename stalls for a second, as on a loaded host. This shim
  # reproduced the check-then-rename race of the earlier mkdir/rename lock,
  # and keeps this test red if a rename-based lock returns. The current
  # flock lock renames nothing, so the shim does not slow it.
  real_mv=$(type -P mv)
  mkdir -p "$W/shim"
  cat > "$W/shim/mv" <<EOF
#!/bin/sh
[ -d "\$1" ] && sleep 1
exec "$real_mv" "\$@"
EOF
  chmod +x "$W/shim/mv"
  # Start from a crashed pass's leftovers.
  blocking_probe
  conf <<EOF
daemon=$DAEMON_NAME
relay.m3=$W/fake-relay.sh m3 7001
probe.m3=$W/blocking-probe.sh m3
EOF
  FM_HOME="$W/home" bash "$GUARD" once >/dev/null 2>&1 &
  gpid=$!
  wait_for_file "$W/probing" || fail "the crashing pass never reached its probe"
  kill -KILL "$gpid" 2>/dev/null
  wait "$gpid" 2>/dev/null
  : > "$W/release"
  conf <<EOF
daemon=$DAEMON_NAME
relay.m3=$W/fake-relay.sh m3 7001
probe.m3=$W/overlap-probe.sh m3
EOF
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    PATH="$W/shim:$PATH" guard once >"$W/contender.$i" 2>&1 &
    pids+=("$!")
    sleep 0.25
  done
  for i in "${pids[@]}"; do
    wait "$i"
    code=$?
    [ "$code" -eq 0 ] && n=$((n + 1))
    [ "$code" -eq 0 ] || [ "$code" -eq 75 ] || fail "a contender exited $code: $(cat "$W"/contender.* 2>/dev/null)"
  done
  [ "$n" -ge 1 ] || fail "no contender ran a pass"
  [ ! -e "$W/overlap" ] || fail "two passes ran their probes at the same time"
  [ "$(relay_pids m3 7001 | wc -l | tr -d ' ')" -eq 1 ] || fail "concurrent passes left duplicate relays: $(relay_pids m3 7001 | tr '\n' ' ')"
  relay_pids m3 7001 | while read -r p; do kill "$p" 2>/dev/null; done
  stop_daemon
  pass "staggered passes racing over a crashed pass's leftovers never run at the same time"
}

test_a_relay_pid_reused_during_the_probe_is_not_signaled() {
  local real_ps relay out
  world
  real_ps=$(type -P ps)
  # The probe fails and, while it runs, the relay's pid passes to another
  # process: a ps stand-in reports a new start time for that pid from then on.
  mkdir -p "$W/shim"
  cat > "$W/shim/ps" <<EOF
#!/bin/sh
if [ "\$1" = -o ] && [ "\$2" = lstart= ] && [ "\$3" = -p ] && [ -f "$W/reused.\$4" ]; then
  printf 'Sat Jan  1 00:00:00 2000\n'
  exit 0
fi
exec "$real_ps" "\$@"
EOF
  cat > "$W/reuse-probe.sh" <<EOF
#!/bin/sh
: > "$W/reused.\$(cat "$W/relay.pid")"
exit 1
EOF
  chmod +x "$W/shim/ps" "$W/reuse-probe.sh"
  start_daemon
  sleep 1.2
  start_relay m3 7001
  sleep 0.3
  relay=$(relay_pids m3 7001)
  [ -n "$relay" ] || fail "fixture relay did not start"
  printf '%s\n' "$relay" > "$W/relay.pid"
  conf <<EOF
daemon=$DAEMON_NAME
relay.m3=$W/fake-relay.sh m3 7001
probe.m3=$W/reuse-probe.sh m3
probe-fails=1
settle-secs=1
term-wait-secs=1
EOF
  out=$(PATH="$W/shim:$PATH" guard once 2>&1)
  [ -f "$W/reused.$relay" ] || fail "fixture is vacuous: the probe never ran: $out"
  alive "$relay" || fail "the guard signaled a pid whose start time changed after the relay was matched: $out"
  pkill -f "$W/fake-relay.sh m3 7001" 2>/dev/null
  stop_daemon
  pass "a relay pid that changed owner during the probe is never sent TERM or KILL"
}

test_leading_zero_numbers_are_decimal() {
  local old new out code
  world
  start_daemon
  start_relay m3 7001
  sleep 1.3
  stop_daemon
  start_daemon
  old=$(relay_pids m3 7001)
  [ -n "$old" ] || fail "fixture relay did not start"
  conf <<EOF
daemon=$DAEMON_NAME
relay.m3=$W/fake-relay.sh m3 7001
probe.m3=$W/fake-probe.sh m3
probe-fails=02
max-restarts=08
window-secs=0900
backoff-secs=09
settle-secs=01
term-wait-secs=08
EOF
  out=$(guard once 2>&1)
  code=$?
  [ "$code" -eq 0 ] || fail "zero-padded numbers should recover a stale relay, got $code: $out"
  new=$(relay_pids m3 7001)
  [ -n "$new" ] && [ "$new" != "$old" ] || fail "the stale relay was not restarted: $out"
  "$W/fake-probe.sh" m3 || fail "the restarted relay is not reachable"
  kill "$new" 2>/dev/null
  out=$(guard run --interval 00 2>&1)
  code=$?
  [ "$code" -eq 2 ] || fail "a zero interval written as 00 should be refused (exit 2), got $code: $out"
  stop_daemon
  pass "zero-padded config numbers parse as decimal and a 00 interval is refused"
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

# A shim for one external command: its first call, from anywhere in the guard's
# process tree, waits for the release file before running the real command,
# so a case can SIGKILL the guard while that child is still alive. Mark command
# completion so a case can check the state after the orphaned write finishes.
holding_shim() {  # <command> <release-file>
  local real
  real=$(type -P "$1") || fail "no $1 on PATH"
  mkdir -p "$W/shim"
  cat > "$W/shim/$1" <<EOF
#!/bin/sh
if "$MKDIR_BIN" "$W/held.$1" 2>/dev/null; then
  : > "$W/holding.$1"
  i=0
  while [ ! -f "$2" ] && [ "\$i" -lt 300 ]; do
    "$SLEEP_BIN" 0.1
    i=\$((i + 1))
  done
fi
"$real" "\$@"
rc=\$?
: > "$W/finished.$1"
exit "\$rc"
EOF
  chmod +x "$W/shim/$1"
}

test_a_killed_guards_pending_start_write_cannot_erase_a_later_start() {
  local c gpid out code before state
  for c in rm mv; do
    world
    start_daemon
    conf <<EOF
daemon=$DAEMON_NAME
relay.m3=$W/fake-relay.sh m3 7001
probe.m3=$W/fake-probe.sh m3
max-restarts=2
window-secs=3600
backoff-secs=0
settle-secs=1
EOF
    state=$W/home/state/relay-guard
    mkdir -p "$state"
    # With no history start_allowed deletes .starts; with live history it
    # replaces .starts. A pending old write must never erase a newer append.
    [ "$c" != mv ] || date +%s > "$state/m3.starts"
    holding_shim "$c" "$W/release"
    FM_HOME="$W/home" PATH="$W/shim:$PATH" bash "$GUARD" once >"$W/old.out" 2>&1 &
    gpid=$!
    wait_for_file "$W/holding.$c" || fail "fixture is vacuous: no pending $c of .starts"
    kill -KILL "$gpid" 2>/dev/null
    wait "$gpid" 2>/dev/null

    out=$(guard once 2>&1)
    code=$?
    # A safe implementation may hold the lock until its pending write ends.
    # On the broken guard this pass succeeds, allowing the actual erasure
    # below to be observed rather than failing only on lock ownership.
    [ "$code" -eq 0 ] || [ "$code" -eq 75 ] || fail "successor exited $code: $out"
    if [ "$code" -eq 0 ]; then
      before=$(cat "$state/m3.starts")
      [ -n "$before" ] || fail "successor did not record its start"
    fi
    : > "$W/release"
    wait_for_file "$W/finished.$c" || fail "pending $c did not finish"
    if [ "$code" -eq 0 ]; then
      assert_equals "$before" "$(cat "$state/m3.starts" 2>/dev/null)" "orphaned $c erased the successor's start record"
    else
      out=$(guard once 2>&1)
      code=$?
      [ "$code" -eq 0 ] || fail "successor after pending $c exited $code: $out"
    fi
    [ -s "$state/m3.starts" ] || fail "successor's start record is absent after $c"
    pkill -f "$W/fake-relay.sh m3 7001" 2>/dev/null
    stop_daemon
  done
  pass "pending start-history deletion and replacement cannot erase a successor's restart record after SIGKILL"
}

test_only_pending_state_writes_of_a_killed_guard_hold_the_lock() {
  local c gpid out code
  for c in date ps awk rm sleep mv; do
    world
    # A relay that predates a daemon restart, so the pass stops, starts,
    # settles, and records: every external command a pass runs is reached.
    start_daemon
    start_relay m3 7001
    sleep 1.2
    stop_daemon
    start_daemon
    conf <<EOF
daemon=$DAEMON_NAME
relay.m3=$W/fake-relay.sh m3 7001
probe.m3=$W/fake-probe.sh m3
settle-secs=1
term-wait-secs=1
EOF
    holding_shim "$c" "$W/release"
    FM_HOME="$W/home" PATH="$W/shim:$PATH" bash "$GUARD" once >/dev/null 2>&1 &
    gpid=$!
    wait_for_file "$W/holding.$c" || fail "fixture is vacuous: the pass never ran $c"
    kill -KILL "$gpid" 2>/dev/null
    wait "$gpid" 2>/dev/null
    out=$(guard once 2>&1)
    code=$?
    case "$c" in
      rm|mv) [ "$code" -eq 75 ] || fail "pending state write $c lost the lock: $out" ;;
      *) [ "$code" -ne 75 ] || fail "the guard's $c child still holds the pass lock: $out" ;;
    esac
    : > "$W/release"
    wait_for_file "$W/finished.$c" || fail "held $c did not finish"
    out=$(guard once 2>&1)
    code=$?
    [ "$code" -ne 75 ] || fail "finished $c left the pass lock held: $out"
    pkill -f "$W/fake-relay.sh m3 7001" 2>/dev/null
    stop_daemon
  done
  pass "only pending state writes retain a killed guard's lock, and release it on completion"
}

# A ps shim for the guard's start-time reads. At the <n>th read it changes the
# identity of the pid read just before: from then on that pid reports another
# start time. It first records whether that pid still lives, waiting up to 1s
# for a signal the guard already sent it to land.
identity_flip_shim() {  # <n>
  mkdir -p "$W/shim"
  cat > "$W/shim/ps" <<EOF
#!/bin/sh
if [ "\$1" = -o ] && [ "\$2" = lstart= ] && [ "\$3" = -p ]; then
  n=\$(( \$("$CAT_BIN" "$W/reads" 2>/dev/null || echo 0) + 1 ))
  echo "\$n" > "$W/reads"
  if [ -f "$W/flip.\$4" ]; then printf 'Sat Jan  1 00:00:00 2000\n'; exit 0; fi
  if [ "\$n" = $1 ]; then
    prev=\$("$CAT_BIN" "$W/last-read")
    i=0
    while :; do
      st=\$("$PS_BIN" -o stat= -p "\$prev" 2>/dev/null | "$TR_BIN" -d ' ')
      case "\$st" in ''|Z*) echo 0 > "$W/flip.\$prev"; break ;; esac
      [ "\$i" -lt 10 ] || { echo 1 > "$W/flip.\$prev"; break; }
      "$SLEEP_BIN" 0.1
      i=\$((i + 1))
    done
  fi
  echo "\$4" > "$W/last-read"
fi
exec "$PS_BIN" "\$@"
EOF
  chmod +x "$W/shim/ps"
}

# A pid whose identity changed while it was still alive was signaled anyway.
assert_no_signal_after_identity_change() {  # <out>
  local f pid
  set -- "$1" "$W"/flip.*
  [ -e "$2" ] || fail "fixture is vacuous: no identity changed: $1"
  for f in "${@:2}"; do
    pid=${f##*.}
    if [ "$(cat "$f")" = 1 ] && ! alive "$pid"; then
      fail "pid $pid was signaled after its start time changed, because the signal used an earlier identity check: $1"
    fi
  done
}

test_each_term_rechecks_its_own_pid_first() {
  local out
  world
  start_daemon
  start_relay m4 7002
  start_relay m4 7002
  sleep 0.3
  [ "$(relay_pids m4 7002 | wc -l | tr -d ' ')" = 2 ] || fail "fixture duplicates did not start"
  conf <<EOF
daemon=$DAEMON_NAME
relay.m4=$W/fake-relay.sh m4 7002
probe.m4=$W/fake-probe.sh m4
settle-secs=1
term-wait-secs=1
EOF
  # Reads 1 and 2 check the two duplicates before TERM; read 2 retires the
  # first one's pid.
  identity_flip_shim 2
  out=$(PATH="$W/shim:$PATH" guard once 2>&1)
  assert_no_signal_after_identity_change "$out"
  pkill -f "$W/fake-relay.sh m4 7002" 2>/dev/null
  stop_daemon
  pass "each TERM follows its own pid's identity check, never a batch of earlier checks"
}

test_each_kill_rechecks_its_own_pid_first() {
  local out
  world
  cat > "$W/stubborn-relay.sh" <<EOF
#!/bin/sh
trap '' TERM
while :; do "$SLEEP_BIN" 0.2; done
EOF
  chmod +x "$W/stubborn-relay.sh"
  start_daemon
  nohup "$W/stubborn-relay.sh" s 7009 </dev/null >/dev/null 2>&1 &
  nohup "$W/stubborn-relay.sh" s 7009 </dev/null >/dev/null 2>&1 &
  sleep 0.3
  conf <<EOF
daemon=$DAEMON_NAME
relay.s=$W/stubborn-relay.sh s 7009
probe.s=$W/fake-probe.sh s
settle-secs=1
term-wait-secs=1
EOF
  # Reads 1 and 2 precede TERM, which both ignore; reads 3 and 4 precede KILL,
  # and read 4 retires the first one's pid.
  identity_flip_shim 4
  out=$(PATH="$W/shim:$PATH" guard once 2>&1)
  assert_no_signal_after_identity_change "$out"
  pkill -KILL -f "$W/stubborn-relay.sh" 2>/dev/null
  stop_daemon
  pass "each KILL follows its own pid's identity check, never a batch of earlier checks"
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
  test_a_killed_guards_pending_start_write_cannot_erase_a_later_start \
  test_a_crashed_pass_never_blocks_the_next \
  test_concurrent_passes_never_overlap \
  test_a_relay_pid_reused_during_the_probe_is_not_signaled \
  test_leading_zero_numbers_are_decimal \
  test_kill_spares_a_pid_that_is_no_longer_the_relay \
  test_only_pending_state_writes_of_a_killed_guard_hold_the_lock \
  test_each_term_rechecks_its_own_pid_first \
  test_each_kill_rechecks_its_own_pid_first \
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
