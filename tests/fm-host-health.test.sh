#!/usr/bin/env bash
# Host-health executable: independent failures, bounded hangs, optional SSH,
# append-only machine output, and a runnable launchd plist without installation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-host-health)
PROBE="$ROOT/bin/fm-host-health.sh"
FAKE=$(fm_fakebin "$TMP_ROOT")
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
LAB="$TMP_ROOT/lab home & probe"
mkdir -p "$LAB"
export FM_HOSTHEALTH_CALLS="$TMP_ROOT/calls"
export FM_HOSTHEALTH_FAIL='' FM_HOSTHEALTH_HANG=''

cat > "$FAKE/probe-stub" <<'SH'
#!/usr/bin/env bash
name=${0##*/}
check=$name
if [ "$name" = gh ]; then check="gh_$1"; fi
printf '%s' "$name" >> "$FM_HOSTHEALTH_CALLS"
printf ' <%s>' "$@" >> "$FM_HOSTHEALTH_CALLS"
printf '\n' >> "$FM_HOSTHEALTH_CALLS"
if [ "$check" = "$FM_HOSTHEALTH_HANG" ]; then
  printf '%s\n' "$$" > "$FM_HOSTHEALTH_CALLS.pid"
  exec sleep 30
fi
if [[ ",$FM_HOSTHEALTH_FAIL," = *",$check,"* ]]; then
  printf 'sensitive raw error\n' >&2
  exit 1
fi
case "$name" in
  id) printf 'labuser\n' ;;
  dscl) printf 'UniqueID: 501\n' ;;
  uptime) printf '%s\n' "${FM_HOSTHEALTH_UPTIME:-10:00 up 9 days, 16:00, 2 users, load averages: 19.00 18.00 17.00}" ;;
esac
SH
chmod +x "$FAKE/probe-stub"
for tool in id dscl gh ssh uptime; do ln -s probe-stub "$FAKE/$tool"; done

read_probe() {
  RC=0
  OUT=$(FM_HOME="$LAB" USER=labuser PATH="$FAKE:$BASE_PATH" \
    FM_HOSTHEALTH_SSH_ALIAS="${SSH_ALIAS:-hetzner-lab}" \
    FM_HOSTHEALTH_TIMEOUT_SECS="${PROBE_TIMEOUT:-5}" \
    bash "$PROBE" run 2>&1) || RC=$?
}

test_green_and_append() {
  : > "$FM_HOSTHEALTH_CALLS"
  read_probe
  expect_code 0 "$RC" healthy
  assert_contains "$OUT" ' ok=1 fail=none ssh=ok ' 'green machine verdict'
  assert_contains "$OUT" ' load1=19.00 load5=18.00 load15=17.00' 'high load is context only'
  assert_grep 'id <-un>' "$FM_HOSTHEALTH_CALLS" 'checks identity'
  assert_grep 'dscl <.> <-read> </Users/labuser> <UniqueID>' "$FM_HOSTHEALTH_CALLS" 'checks directory service'
  assert_grep 'gh <auth> <status>' "$FM_HOSTHEALTH_CALLS" 'checks credential access'
  assert_grep 'gh <api> </rate_limit>' "$FM_HOSTHEALTH_CALLS" 'checks TLS independently'
  assert_grep 'ssh <-o> <BatchMode=yes> <-o> <ConnectTimeout=5> <hetzner-lab> <true>' "$FM_HOSTHEALTH_CALLS" 'checks SSH without a prompt'
  local first=$OUT
  read_probe
  expect_code 0 "$RC" second
  assert_equals 2 "$(wc -l < "$LAB/state/host-health-beacon.log" | tr -d ' ')" 'appends exactly one line per run'
  assert_equals "$first" "$(head -n 1 "$LAB/state/host-health-beacon.log")" 'preserves prior line'
  python3 - "$LAB/state/host-health-beacon.log" <<'PY' || fail 'parseable versioned record and uptime'
import base64, re, sys
for line in open(sys.argv[1]):
    assert re.fullmatch(r'HOSTHEALTH v1 ts=\d+ ok=1 fail=none ssh=ok uptime_b64=[A-Za-z0-9+/=]+ load1=19.00 load5=18.00 load15=17.00\n', line), line
    fields = dict(x.split('=', 1) for x in line.split()[2:])
    assert 'up 9 days' in base64.b64decode(fields['uptime_b64']).decode()
PY
  pass 'green probes append a parseable beacon with diagnostic uptime/load'
}

test_independent_failures() {
  local check expected
  for check in id dscl gh_auth gh_api ssh uptime; do
    expected=$check
    FM_HOSTHEALTH_FAIL=$check
    read_probe
    expect_code 1 "$RC" "$check failure"
    assert_contains "$OUT" " ok=0 fail=$expected " "$check names the failed check"
    assert_not_contains "$OUT" 'sensitive raw error' 'raw command errors never enter the beacon'
  done
  FM_HOSTHEALTH_FAIL=id,dscl,gh_auth,gh_api,ssh
  : > "$FM_HOSTHEALTH_CALLS"
  read_probe
  expect_code 1 "$RC" 'M3 signature'
  assert_contains "$OUT" 'fail=id,dscl,gh_auth,gh_api,ssh ' 'identity failure does not short-circuit other checks'
  assert_grep 'gh <api> </rate_limit>' "$FM_HOSTHEALTH_CALLS" 'TLS still checked after auth failure'
  assert_grep 'ssh ' "$FM_HOSTHEALTH_CALLS" 'SSH still checked after identity failure'
  FM_HOSTHEALTH_FAIL=
  read_probe
  expect_code 0 "$RC" recovery
  assert_contains "$OUT" 'ok=1 fail=none ' 'next healthy sample recovers'
  pass 'each failed probe and the combined M3 failure are reported independently'
}

test_optional_ssh_and_publication() {
  : > "$FM_HOSTHEALTH_CALLS"
  RC=0
  OUT=$(FM_HOME="$LAB" USER=labuser PATH="$FAKE:$BASE_PATH" \
    FM_HOSTHEALTH_SSH_ALIAS='' bash "$PROBE" 2>&1) || RC=$?
  expect_code 0 "$RC" 'SSH unconfigured'
  assert_contains "$OUT" 'ok=1 fail=none ssh=skip ' 'unconfigured SSH explicitly skipped'
  assert_no_grep 'ssh ' "$FM_HOSTHEALTH_CALLS" 'no unconfigured network call'
  local log="$TMP_ROOT/custom beacon.log"
  FM_HOSTHEALTH_BEACON_LOG="$log" read_probe
  expect_code 0 "$RC" 'custom beacon'
  assert_equals "$OUT" "$(cat "$log")" 'custom existing host beacon receives exact output'
  FM_HOSTHEALTH_BEACON_LOG="$TMP_ROOT" read_probe
  expect_code 2 "$RC" 'unwritable beacon'
  assert_contains "$OUT" 'HOSTHEALTH_ERROR v1 code=beacon_write' 'publication failure cannot look green'
  pass 'SSH is optional, and beacon publication errors are explicit'
}

test_timeout() {
  local check pid started
  PROBE_TIMEOUT=1
  for check in id dscl gh_auth gh_api ssh uptime; do
    FM_HOSTHEALTH_HANG=$check
    started=$SECONDS
    read_probe
    [ "$((SECONDS - started))" -lt 15 ] || fail "$check exceeded its probe bound"
    expect_code 1 "$RC" "$check timeout"
    assert_contains "$OUT" "ok=0 fail=$check " 'a hung probe becomes a failed observation'
    pid=$(cat "$FM_HOSTHEALTH_CALLS.pid")
    ! kill -0 "$pid" 2>/dev/null || fail "$check child survived its timeout"
  done
  FM_HOSTHEALTH_HANG='' PROBE_TIMEOUT=5
  pass 'each hung check is bounded and its child is reaped'
}

test_render_launchd() {
  local plist="$TMP_ROOT/hostprobe.plist"
  FM_HOME="$LAB" USER=labuser PATH="$FAKE:$BASE_PATH" \
    FM_HOSTHEALTH_SSH_ALIAS=hetzner-lab bash "$PROBE" render-launchd > "$plist" \
    || fail 'render launchd'
  python3 - "$plist" "$PROBE" "$LAB" <<'PY' || fail 'rendered plist must preserve environment and execute from /'
import os, plistlib, subprocess, sys
with open(sys.argv[1], 'rb') as f:
    p = plistlib.load(f)
assert p['ProgramArguments'] == ['/bin/bash', sys.argv[2], 'run']
assert p['StartInterval'] == 300 and p['RunAtLoad'] is True
assert 'KeepAlive' not in p
assert p['EnvironmentVariables']['FM_HOME'] == sys.argv[3]
assert p['EnvironmentVariables']['USER'] == 'labuser'
env = dict(os.environ, **p['EnvironmentVariables'])
out = subprocess.run(p['ProgramArguments'], env=env, cwd='/', capture_output=True, text=True, timeout=30)
assert out.returncode == 0, out
assert 'ok=1 fail=none ssh=ok ' in out.stdout, out
PY
  pass 'launchd configuration preserves paths and runs without a session or current directory'
}

test_invalid_config() {
  local timeout
  for timeout in 0 -1 nope 999999999999; do
    PROBE_TIMEOUT=$timeout read_probe
    expect_code 2 "$RC" "invalid timeout $timeout"
    assert_contains "$OUT" 'HOSTHEALTH_ERROR v1 code=timeout' 'machine-readable config error'
  done
  SSH_ALIAS=-oProxyCommand=bad read_probe
  expect_code 2 "$RC" 'option-like SSH alias'
  assert_contains "$OUT" 'HOSTHEALTH_ERROR v1 code=ssh_alias' 'rejects SSH option injection'
  pass 'invalid settings fail before probing'
}

test_missing_tools_and_metrics() {
  FM_HOSTHEALTH_UPTIME='10:00 up 9 days, 16:00, 2 users, load average: 19.00, 18.00, 17.00' read_probe
  expect_code 0 "$RC" 'Linux uptime'
  assert_contains "$OUT" 'load1=19.00 load5=18.00 load15=17.00' 'Linux separators parse'
  FM_HOSTHEALTH_UPTIME='unparseable uptime' read_probe
  expect_code 1 "$RC" 'invalid uptime'
  assert_contains "$OUT" 'fail=uptime ssh=ok uptime_b64=unknown load1=unknown load5=unknown load15=unknown' 'unparseable metrics fail closed'
  mv "$FAKE/dscl" "$FAKE/dscl.saved"
  local no_dscl
  no_dscl=$(fm_test_base_path_sans "$BASE_PATH" dscl)
  RC=0
  OUT=$(FM_HOME="$LAB" USER=labuser PATH="$FAKE:$no_dscl" \
    FM_HOSTHEALTH_SSH_ALIAS='' bash "$PROBE" 2>&1) || RC=$?
  mv "$FAKE/dscl.saved" "$FAKE/dscl"
  expect_code 1 "$RC" 'missing dscl'
  assert_contains "$OUT" 'fail=dscl ' 'missing directory service cannot silently pass'
  RC=0
  OUT=$(FM_HOME="$LAB" USER='' PATH="$FAKE:$BASE_PATH" \
    FM_HOSTHEALTH_SSH_ALIAS='' bash "$PROBE" 2>&1) || RC=$?
  expect_code 1 "$RC" 'missing USER'
  assert_contains "$OUT" 'fail=dscl ' 'missing launchd USER cannot silently pass'
  pass 'portable metrics, missing tools and absent account metadata are explicit'
}

fm_test_run test_green_and_append test_independent_failures \
  test_optional_ssh_and_publication test_timeout test_render_launchd test_invalid_config \
  test_missing_tools_and_metrics
