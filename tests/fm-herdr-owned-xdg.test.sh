#!/usr/bin/env bash
# Portable fixture tests for bin/fm-herdr-lab.sh fixture actions and the lab
# tripwire they must not weaken. Live start/check/stop cases live in
# tests/fm-herdr-owned-xdg-live-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

LAB=$ROOT/bin/fm-herdr-lab.sh
OWNED_XDG_LIST=$(fm_test_tmproot fm-herdr-owned-xdg-roots)/roots
: > "$OWNED_XDG_LIST"

[ -x "$LAB" ] || fail "Herdr lab helper is not executable"

remember_owned() { # <root>
  printf '%s\n' "$1" >> "$OWNED_XDG_LIST"
}

# kill -0 is true for a zombie. Poll until the pid is gone, then assert.
wait_until_gone() { # <pid> <msg>
  local pid=$1 msg=$2 i=0
  while [ "$i" -lt 20 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null && fail "$msg"
}

# Install a sleep binary under a new name. A copied macOS arm64e sleep is
# SIGKILLed on launch, so take its x86_64 slice and ad-hoc sign it, matching
# tests/fm-droid-harness.test.sh.
install_renamed_sleep() { # <dest>
  local dest=$1 src
  src=$(command -v sleep) || fail "sleep is required for a renamed decoy"
  mkdir -p "$(dirname "$dest")"
  lipo "$src" -thin x86_64 -output "$dest" 2>/dev/null \
    || cp "$src" "$dest" || fail "could not install a renamed sleep at $dest"
  chmod +x "$dest"
  if command -v codesign >/dev/null 2>&1; then
    codesign -s - -f "$dest" >/dev/null 2>&1 || fail "could not sign the renamed sleep at $dest"
  fi
}

# Start a copy of sleep whose comm is herdr. Do not wrap this in $(); a
# command-substitution subshell would hang up the background decoy.
start_herdr_named_sleep() { # <pidfile> <seconds> [env assignments...]
  local pidfile=$1 seconds=$2 bin
  shift 2
  bin=$(fm_test_tmproot herdr-named-sleep)/bin
  install_renamed_sleep "$bin/herdr"
  env "$@" "$bin/herdr" "$seconds" &
  printf '%s\n' "$!" > "$pidfile"
}

# Hide /proc and feed the Darwin KERN_PROCARGS2 reader a buffer built from
# this pid's real argv and environ (whole NUL fields, argv skipped). Mode
# argv-only writes no buffer, so the reader is unreadable.
push_darwin_env() { # [argv-only]
  export FM_PROC_ROOT_OVERRIDE
  export FM_HERDR_LAB_KERN_PROCARGS2_OVERRIDE
  FM_PROC_ROOT_OVERRIDE=$(fm_test_tmproot fm-herdr-owned-xdg-no-proc)
  FM_HERDR_LAB_KERN_PROCARGS2_OVERRIDE=$(fm_test_tmproot fm-herdr-owned-xdg-procargs2)
  mkdir -p "$FM_HERDR_LAB_KERN_PROCARGS2_OVERRIDE"
  unset FM_HERDR_LAB_DARWIN_ENV_HIDE
  [ "${1-}" = argv-only ] && export FM_HERDR_LAB_DARWIN_ENV_HIDE=1
}

pop_darwin_env() {
  unset FM_PROC_ROOT_OVERRIDE FM_HERDR_LAB_KERN_PROCARGS2_OVERRIDE FM_HERDR_LAB_DARWIN_ENV_HIDE
}

# Build a KERN_PROCARGS2 blob: int32 argc, exec path, argv, then env.
# Extra argv tokens from FM_TEST_HERDR_DECOY_ARGV are argv, not env.
write_kern_procargs2() { # <pid>
  local pid=$1 dest extra=${FM_TEST_HERDR_DECOY_ARGV-}
  [ -n "${FM_HERDR_LAB_KERN_PROCARGS2_OVERRIDE:-}" ] || return 0
  [ "${FM_HERDR_LAB_DARWIN_ENV_HIDE:-}" = 1 ] && return 0
  dest=$FM_HERDR_LAB_KERN_PROCARGS2_OVERRIDE/$pid
  /usr/bin/python3 - "$pid" "$dest" ${extra:+"$extra"} <<'PY' || fail "could not write a KERN_PROCARGS2 buffer"
import struct
import sys

pid = sys.argv[1]
dest = sys.argv[2]
extra = sys.argv[3:]
with open("/proc/%s/cmdline" % pid, "rb") as fh:
    argv = [part for part in fh.read().split(b"\0") if part]
for token in extra:
    argv.append(token.encode())
if not argv:
    sys.exit(1)
with open("/proc/%s/environ" % pid, "rb") as fh:
    env = fh.read()
buf = struct.pack("<i", len(argv)) + argv[0] + b"\0\0"
for part in argv:
    buf += part + b"\0"
buf += b"\0"
if env:
    buf += env if env.endswith(b"\0") else env + b"\0"
with open(dest, "wb") as fh:
    fh.write(buf)
PY
}

owned_suite_cleanup() {
  local root
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    "$LAB" fixture cleanup "$root" >/dev/null 2>&1 || true
  done < "$OWNED_XDG_LIST"
  fm_test_cleanup
}
trap owned_suite_cleanup EXIT
trap 'owned_suite_cleanup; exit 130' INT
trap 'owned_suite_cleanup; exit 143' TERM

test_create_clears_inherited_identity_and_cleanup_removes_only_that_dir() {
  local root sibling status=0 pathfile
  sibling=$(mktemp -d "$(cd /tmp && pwd -P)/hx.XXXXXX")
  pathfile=$(fm_test_tmproot fm-herdr-owned-xdg-create)/root.path
  printf 'keep\n' > "$sibling/keep"
  HERDR_SESSION=default
  HERDR_PANE_ID=w1:p1
  HERDR_SOCKET_PATH=/tmp/not-ours.sock
  herdr_fixture_create > "$pathfile" || fail "create failed"
  [ -z "${HERDR_SESSION:-}" ] || fail "create left HERDR_SESSION set"
  [ -z "${HERDR_PANE_ID:-}" ] || fail "create left HERDR_PANE_ID set"
  [ -z "${HERDR_SOCKET_PATH:-}" ] || fail "create left HERDR_SOCKET_PATH set"
  root=$(cat "$pathfile")
  remember_owned "$root"
  [ -d "$root" ] || fail "create did not print a directory"
  [ -d "$sibling" ] || fail "create removed an unrelated hx directory"
  herdr_fixture_cleanup "$root" || fail "cleanup of a never-started fixture failed"
  [ ! -d "$root" ] || fail "cleanup left the owned directory"
  [ -f "$sibling/keep" ] || fail "cleanup removed an unrelated hx directory"
  rm -rf "$sibling"
  status=0
  herdr_fixture_cleanup /tmp >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "cleanup must refuse /tmp"
  pass "fm-herdr-lab fixture: create clears inherited Herdr identity and cleanup removes only the owned directory"
}

test_cli_refuses_foreign_paths_and_unknown_commands() {
  local status=0 out
  out=$("$LAB" fixture start /tmp 2>&1) || status=$?
  expect_code 1 "$status" "fixture start must refuse /tmp"
  assert_contains "$out" "owned" "foreign-path refusal was unclear"
  status=0
  "$LAB" fixture start default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "fixture start must not accept a session name"
  status=0
  "$LAB" server stop >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "the helper must not grow a server-stop command"
  status=0
  "$LAB" fixture server stop >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "fixture must not grow a server-stop command"
  pass "fm-herdr-lab fixture: CLI refuses foreign paths, session names, and server stop"
}

test_stop_refuses_a_live_non_herdr_pid() {
  local root pid start status=0 token
  root=$(herdr_fixture_create) || fail "create failed"
  remember_owned "$root"
  token=$(cat "$root/.fm-herdr-owned")
  sleep 30 &
  pid=$!
  start=$(LC_ALL=C ps -p "$pid" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  printf 'schema=fm-herdr-owned-xdg.v1\nxdg_root=%s\nmarker_token=%s\npid=%s\npid_start=%s\n' \
    "$root" "$token" "$pid" "$start" > "$root/owned.record"
  herdr_fixture_stop "$root" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "stop must refuse a live non-herdr pid"
  kill -0 "$pid" 2>/dev/null || fail "stop signalled a sleep process stuffed into the record"
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  herdr_fixture_stop "$root" || fail "stop did not become a no-op after the foreign pid exited"
  herdr_fixture_cleanup "$root" || fail "cleanup after a refused stop failed"
  pass "fm-herdr-lab fixture: stop refuses a live process that is not this fixture's herdr"
}

test_stop_refuses_herdr_named_pid_with_wrong_start_time() {
  local root pid start status=0 token pidfile
  root=$(herdr_fixture_create) || fail "create failed"
  remember_owned "$root"
  token=$(cat "$root/.fm-herdr-owned")
  pidfile=$(fm_test_tmproot herdr-named-sleep)/wrong-start.pid
  start_herdr_named_sleep "$pidfile" 30 "XDG_CONFIG_HOME=$root/c"
  pid=$(cat "$pidfile")
  kill -0 "$pid" 2>/dev/null || fail "the herdr-named decoy did not start"
  start=$(LC_ALL=C ps -p "$pid" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$start" ] || fail "could not read the decoy start time"
  printf 'schema=fm-herdr-owned-xdg.v1\nxdg_root=%s\nmarker_token=%s\npid=%s\npid_start=%s\n' \
    "$root" "$token" "$pid" "not-$start" > "$root/owned.record"
  status=0
  herdr_fixture_stop "$root" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "stop must refuse a herdr-named pid whose start time does not match"
  kill -0 "$pid" 2>/dev/null || fail "stop signalled a herdr-named decoy with the wrong start time"
  status=0
  herdr_fixture_cleanup "$root" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "cleanup must refuse a herdr-named pid whose start time does not match"
  kill -0 "$pid" 2>/dev/null || fail "cleanup signalled a herdr-named decoy with the wrong start time"
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  herdr_fixture_cleanup "$root" || fail "cleanup after the start-time decoy exited failed"
  pass "fm-herdr-lab fixture: stop and cleanup refuse a herdr-named pid with the wrong start time"
}

# Drive stop/cleanup against a herdr-named decoy. Fail-closed prove_pid must
# refuse whether the environment lacks this fixture's XDG_CONFIG_HOME or no
# reader yields an environment at all. decoy-shape: missing-xdg (default),
# prefix (XDG_CONFIG_HOME=$root/cX), inject-argv (that XDG only in argv), or
# space-xdg (FOO value contains a space then XDG_CONFIG_HOME=$root/c).
refuse_herdr_named_decoy() { # <pass-msg> [missing-xdg|prefix|inject-argv|space-xdg]
  local root pid start status=0 token pidfile env_text pass_msg=$1 decoy_shape=${2:-missing-xdg} env_ok=1 extra_env=
  unset FM_TEST_HERDR_DECOY_ARGV
  root=$(herdr_fixture_create) || fail "create failed"
  remember_owned "$root"
  token=$(cat "$root/.fm-herdr-owned")
  pidfile=$(fm_test_tmproot herdr-named-sleep)/decoy.pid
  case "$decoy_shape" in
    missing-xdg) ;;
    prefix) extra_env="XDG_CONFIG_HOME=$root/cX" ;;
    inject-argv) export FM_TEST_HERDR_DECOY_ARGV="XDG_CONFIG_HOME=$root/c" ;;
    space-xdg) extra_env="FOO=x XDG_CONFIG_HOME=$root/c" ;;
    *) fail "unknown decoy shape: $decoy_shape" ;;
  esac
  if [ -n "$extra_env" ]; then
    start_herdr_named_sleep "$pidfile" 30 "$extra_env"
  else
    start_herdr_named_sleep "$pidfile" 30
  fi
  pid=$(cat "$pidfile")
  kill -0 "$pid" 2>/dev/null || fail "the herdr-named decoy did not start"
  write_kern_procargs2 "$pid"
  start=$(LC_ALL=C ps -p "$pid" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$start" ] || fail "could not read the decoy start time"
  printf 'schema=fm-herdr-owned-xdg.v1\nxdg_root=%s\nmarker_token=%s\npid=%s\npid_start=%s\n' \
    "$root" "$token" "$pid" "$start" > "$root/owned.record"
  env_text=$(fm_herdr_lab_fixture_process_env "$pid") || env_ok=0
  if [ "$env_ok" -eq 1 ]; then
    printf '%s\n' "$env_text" | grep -Fx "XDG_CONFIG_HOME=$root/c" >/dev/null \
      && fail "the environ decoy unexpectedly inherited this fixture's XDG_CONFIG_HOME"
  fi
  status=0
  herdr_fixture_stop "$root" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "stop must refuse a herdr-named pid that is not this fixture's process"
  kill -0 "$pid" 2>/dev/null || fail "stop signalled a herdr-named decoy that is not this fixture's process"
  status=0
  herdr_fixture_cleanup "$root" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "cleanup must refuse a herdr-named pid that is not this fixture's process"
  kill -0 "$pid" 2>/dev/null || fail "cleanup signalled a herdr-named decoy that is not this fixture's process"
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  herdr_fixture_cleanup "$root" || fail "cleanup after the environ decoy exited failed"
  unset FM_TEST_HERDR_DECOY_ARGV
  pass "$pass_msg"
}

test_stop_refuses_herdr_named_pid_without_fixture_xdg() {
  refuse_herdr_named_decoy \
    "fm-herdr-lab fixture: stop and cleanup refuse a herdr-named pid without this fixture's XDG_CONFIG_HOME"
}

test_stop_refuses_herdr_named_pid_without_fixture_xdg_when_proc_is_hidden() {
  push_darwin_env
  refuse_herdr_named_decoy \
    "fm-herdr-lab fixture: stop and cleanup refuse a herdr-named pid without XDG_CONFIG_HOME when /proc is hidden"
  pop_darwin_env
}

test_stop_refuses_herdr_named_pid_when_darwin_ps_hides_env() {
  push_darwin_env argv-only
  refuse_herdr_named_decoy \
    "fm-herdr-lab fixture: stop and cleanup refuse a herdr-named pid when Darwin ps -E hides the environment"
  pop_darwin_env
}

test_stop_refuses_herdr_named_pid_when_xdg_is_only_in_argv() {
  push_darwin_env
  refuse_herdr_named_decoy \
    "fm-herdr-lab fixture: stop and cleanup refuse a herdr-named pid whose argv contains XDG_CONFIG_HOME" \
    inject-argv
  pop_darwin_env
}

test_stop_refuses_herdr_named_pid_when_proc_is_unreadable_and_ps_e_is_absent() {
  export FM_PROC_ROOT_OVERRIDE
  FM_PROC_ROOT_OVERRIDE=$(fm_test_tmproot fm-herdr-owned-xdg-no-proc)
  refuse_herdr_named_decoy \
    "fm-herdr-lab fixture: stop and cleanup refuse a herdr-named pid when /proc is unreadable and ps -E is absent"
  unset FM_PROC_ROOT_OVERRIDE
}

test_stop_refuses_herdr_named_pid_with_xdg_prefix_collision() {
  refuse_herdr_named_decoy \
    "fm-herdr-lab fixture: stop and cleanup refuse a herdr-named pid whose XDG_CONFIG_HOME only prefixes this fixture's" \
    prefix
}

test_stop_refuses_herdr_named_pid_with_xdg_prefix_collision_when_proc_is_hidden() {
  push_darwin_env
  refuse_herdr_named_decoy \
    "fm-herdr-lab fixture: stop and cleanup refuse a Darwin-read herdr-named pid whose XDG_CONFIG_HOME only prefixes this fixture's" \
    prefix
  pop_darwin_env
}

test_stop_refuses_herdr_named_pid_when_xdg_is_a_space_inside_another_field() {
  push_darwin_env
  refuse_herdr_named_decoy \
    "fm-herdr-lab fixture: stop and cleanup refuse a Darwin-read herdr-named pid whose XDG_CONFIG_HOME is a space inside another field" \
    space-xdg
  pop_darwin_env
}

test_stop_refuses_herdr_named_pid_with_empty_readable_environ() {
  local root pid start status=0 token pidfile proc_root
  root=$(herdr_fixture_create) || fail "create failed"
  remember_owned "$root"
  token=$(cat "$root/.fm-herdr-owned")
  pidfile=$(fm_test_tmproot herdr-named-sleep)/empty-environ.pid
  start_herdr_named_sleep "$pidfile" 30
  pid=$(cat "$pidfile")
  kill -0 "$pid" 2>/dev/null || fail "the herdr-named decoy did not start"
  start=$(LC_ALL=C ps -p "$pid" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$start" ] || fail "could not read the decoy start time"
  printf 'schema=fm-herdr-owned-xdg.v1\nxdg_root=%s\nmarker_token=%s\npid=%s\npid_start=%s\n' \
    "$root" "$token" "$pid" "$start" > "$root/owned.record"
  proc_root=$(fm_test_tmproot fm-herdr-owned-xdg-empty-proc)
  mkdir -p "$proc_root/$pid"
  : > "$proc_root/$pid/environ"
  export FM_PROC_ROOT_OVERRIDE=$proc_root
  status=0
  herdr_fixture_stop "$root" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "stop must refuse a herdr-named pid with an empty readable environ"
  kill -0 "$pid" 2>/dev/null || fail "stop signalled a herdr-named decoy with an empty readable environ"
  status=0
  herdr_fixture_cleanup "$root" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "cleanup must refuse a herdr-named pid with an empty readable environ"
  kill -0 "$pid" 2>/dev/null || fail "cleanup signalled a herdr-named decoy with an empty readable environ"
  unset FM_PROC_ROOT_OVERRIDE
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  herdr_fixture_cleanup "$root" || fail "cleanup after the empty-environ decoy exited failed"
  pass "fm-herdr-lab fixture: stop and cleanup refuse a herdr-named pid with an empty readable environ"
}

test_stop_refuses_herdr_named_pid_when_xdg_is_forged_inside_a_nul_field() {
  local root pid start status=0 token pidfile proc_root
  root=$(herdr_fixture_create) || fail "create failed"
  remember_owned "$root"
  token=$(cat "$root/.fm-herdr-owned")
  pidfile=$(fm_test_tmproot herdr-named-sleep)/newline-environ.pid
  start_herdr_named_sleep "$pidfile" 30
  pid=$(cat "$pidfile")
  kill -0 "$pid" 2>/dev/null || fail "the herdr-named decoy did not start"
  start=$(LC_ALL=C ps -p "$pid" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$start" ] || fail "could not read the decoy start time"
  printf 'schema=fm-herdr-owned-xdg.v1\nxdg_root=%s\nmarker_token=%s\npid=%s\npid_start=%s\n' \
    "$root" "$token" "$pid" "$start" > "$root/owned.record"
  proc_root=$(fm_test_tmproot fm-herdr-owned-xdg-newline-proc)
  mkdir -p "$proc_root/$pid"
  printf 'BAR=1\0FOO=x\nXDG_CONFIG_HOME=%s\0' "$root/c" > "$proc_root/$pid/environ"
  export FM_PROC_ROOT_OVERRIDE=$proc_root
  status=0
  herdr_fixture_stop "$root" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "stop must refuse a herdr-named pid whose XDG_CONFIG_HOME is only a newline inside another field"
  kill -0 "$pid" 2>/dev/null || fail "stop signalled a herdr-named decoy whose XDG_CONFIG_HOME was forged inside another field"
  status=0
  herdr_fixture_cleanup "$root" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "cleanup must refuse a herdr-named pid whose XDG_CONFIG_HOME is only a newline inside another field"
  kill -0 "$pid" 2>/dev/null || fail "cleanup signalled a herdr-named decoy whose XDG_CONFIG_HOME was forged inside another field"
  unset FM_PROC_ROOT_OVERRIDE
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  herdr_fixture_cleanup "$root" || fail "cleanup after the newline-environ decoy exited failed"
  pass "fm-herdr-lab fixture: stop and cleanup refuse a herdr-named pid whose XDG_CONFIG_HOME is forged inside a NUL field"
}

test_lab_tripwire_still_refuses_zero_and_multiple_defaults() {
  local tmp fakebin status=0 out name
  tmp=$(fm_test_tmproot fm-herdr-owned-xdg-tripwire)
  fakebin=$(fm_fakebin "$tmp")
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
if [ "$1" = session ] && [ "${2:-}" = list ]; then
  if [ "${FM_FAKE_DEFAULTS:-}" = 0 ]; then
    printf '%s\n' '{"sessions":[]}'
    exit 0
  fi
  printf '%s\n' '{"sessions":[{"default":true,"name":"default","running":true,"socket_path":"/tmp/a.sock"},{"default":true,"name":"other","running":true,"socket_path":"/tmp/b.sock"}]}'
  exit 0
fi
exit 90
SH
  chmod +x "$fakebin/herdr"
  name=fm-lab-multi-$$
  status=0
  out=$(PATH="$fakebin:$PATH" FM_HERDR_LAB_STATE_DIR="$tmp/lab" FM_FAKE_DEFAULTS=2 \
    "$LAB" provision "$name" 2>&1) || status=$?
  expect_code 1 "$status" "two running defaults must still trip provision"
  assert_contains "$out" "fleet-state tripwire requires exactly one running default session" \
    "multiple-default refusal changed its tripwire wording"
  status=0
  out=$(PATH="$fakebin:$PATH" FM_HERDR_LAB_STATE_DIR="$tmp/lab" FM_FAKE_DEFAULTS=0 \
    "$LAB" provision "$name" 2>&1) || status=$?
  expect_code 1 "$status" "zero running defaults must still trip provision"
  assert_contains "$out" "fleet-state tripwire requires exactly one running default session" \
    "zero-default refusal changed its tripwire wording"
  pass "fm-herdr-lab: fleet-state tripwire still requires exactly one running default session"
}

test_fixture_stays_on_default_when_a_custom_fleet_session_is_exported() {
  local foreign started fakebin status=0 first
  foreign=$(herdr_fixture_create) || fail "create foreign failed"
  remember_owned "$foreign"
  started=$(herdr_fixture_create) || fail "create started failed"
  remember_owned "$started"
  fakebin=$(fm_fakebin "$(fm_test_tmproot fm-herdr-owned-xdg-custom-fleet)/bin")
  install_renamed_sleep "$started/procbin/herdr"
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> $(printf '%q' "$foreign/herdr.log")
printf '%s\\n' "\$*" >> $(printf '%q' "$started/herdr.log")
if [ "\$1" = session ]; then
  if [ "\${FM_FAKE_FOREIGN_DEFAULT:-}" = 1 ]; then
    printf '%s\\n' '{"sessions":[{"default":true,"name":"default","running":true,"socket_path":"/tmp/custom-fleet-foreign.sock"}]}'
    exit 0
  fi
  if [ -s $(printf '%q' "$started/leader.pid") ]; then
    printf '%s\\n' '{"sessions":[{"default":true,"name":"default","running":true,"socket_path":"/tmp/custom-fleet-owned.sock"}]}'
  else
    printf '%s\\n' '{"sessions":[]}'
  fi
  exit 0
fi
if [ "\$1" = server ]; then
  printf 'invoked\\n' > $(printf '%q' "$foreign/server.invoked")
  printf '%s\\n' "\$\$" > $(printf '%q' "$started/leader.pid")
  exec $(printf '%q' "$started/procbin/herdr") 98769
fi
exit 90
SH
  chmod +x "$fakebin/herdr"
  status=0
  FM_HERDR_LAB_FLEET_SESSION=custom FM_FAKE_FOREIGN_DEFAULT=1 PATH="$fakebin:$PATH" \
    "$LAB" fixture start "$foreign" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "start must still refuse a running default when FM_HERDR_LAB_FLEET_SESSION is custom"
  [ ! -e "$foreign/server.invoked" ] || fail "start forked a server against a foreign default under a custom fleet session"
  ! grep -Fq 'server' "$foreign/herdr.log" || fail "start invoked herdr server against a foreign default under a custom fleet session"
  FM_HERDR_LAB_FLEET_SESSION=custom PATH="$fakebin:$PATH" \
    "$LAB" fixture start "$started" || fail "start failed under FM_HERDR_LAB_FLEET_SESSION=custom"
  first=$(sed -n 's/^pid=//p' "$started/owned.record")
  [ -n "$first" ] || fail "start under a custom fleet session recorded no pid"
  FM_HERDR_LAB_FLEET_SESSION=custom PATH="$fakebin:$PATH" \
    "$LAB" fixture check "$started" || fail "check failed under FM_HERDR_LAB_FLEET_SESSION=custom"
  FM_HERDR_LAB_FLEET_SESSION=custom PATH="$fakebin:$PATH" \
    herdr_fixture_cleanup "$started" || fail "cleanup after a custom-fleet start failed"
  herdr_fixture_cleanup "$foreign" || fail "cleanup of the custom-fleet foreign fixture failed"
  pass "fm-herdr-lab fixture: start and check stay on the default session when FM_HERDR_LAB_FLEET_SESSION is custom"
}

test_start_refuses_a_running_default_it_did_not_start() {
  local root fakebin status=0
  root=$(herdr_fixture_create) || fail "create failed"
  remember_owned "$root"
  fakebin=$(fm_fakebin "$(fm_test_tmproot fm-herdr-owned-xdg-foreign)/bin")
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> $(printf '%q' "$root/herdr.log")
if [ "\$1" = session ]; then
  printf '%s\\n' '{"sessions":[{"default":true,"name":"default","running":true,"socket_path":"/tmp/foreign-default.sock"}]}'
  exit 0
fi
if [ "\$1" = server ]; then
  printf 'invoked\\n' > $(printf '%q' "$root/server.invoked")
  exit 0
fi
exit 90
SH
  chmod +x "$fakebin/herdr"
  PATH="$fakebin:$PATH" "$LAB" fixture start "$root" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "start must refuse a running default it did not start"
  [ ! -e "$root/server.invoked" ] || fail "start forked a server against a foreign default"
  ! grep -Fq 'server' "$root/herdr.log" || fail "start invoked herdr server against a foreign default"
  herdr_fixture_cleanup "$root" || fail "cleanup after a foreign-default refusal failed"
  pass "fm-herdr-lab fixture: start refuses a running default it did not start without forking a server"
}

test_second_start_on_a_started_fixture_is_idempotent() {
  local root fakebin first second
  root=$(herdr_fixture_create) || fail "create failed"
  remember_owned "$root"
  install_renamed_sleep "$root/procbin/herdr"
  fakebin=$(fm_fakebin "$(fm_test_tmproot fm-herdr-owned-xdg-idempotent)/bin")
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> $(printf '%q' "$root/herdr.log")
if [ "\$1" = session ]; then
  if [ -s $(printf '%q' "$root/leader.pid") ]; then
    printf '%s\\n' '{"sessions":[{"default":true,"name":"default","running":true,"socket_path":"/tmp/owned-xdg-idempotent.sock"}]}'
  else
    printf '%s\\n' '{"sessions":[]}'
  fi
  exit 0
fi
if [ "\$1" = server ]; then
  printf '%s\\n' "\$\$" > $(printf '%q' "$root/leader.pid")
  exec $(printf '%q' "$root/procbin/herdr") 98768
fi
exit 90
SH
  chmod +x "$fakebin/herdr"
  PATH="$fakebin:$PATH" "$LAB" fixture start "$root" || fail "first start failed"
  first=$(sed -n 's/^pid=//p' "$root/owned.record")
  [ -n "$first" ] || fail "first start recorded no pid"
  PATH="$fakebin:$PATH" "$LAB" fixture start "$root" || fail "second start failed"
  second=$(sed -n 's/^pid=//p' "$root/owned.record")
  [ "$second" = "$first" ] || fail "second start changed the pid from $first to $second"
  [ "$(grep -c '^server$' "$root/herdr.log")" = 1 ] \
    || fail "second start forked another herdr server"
  PATH="$fakebin:$PATH" herdr_fixture_cleanup "$root" || fail "cleanup after an idempotent start failed"
  pass "fm-herdr-lab fixture: a second start on an already-started fixture returns 0 with the pid unchanged"
}

test_start_failure_signals_the_forked_process_group() {
  local root fakebin leader child status=0
  root=$(herdr_fixture_create) || fail "create failed"
  remember_owned "$root"
  fakebin=$(fm_fakebin "$(fm_test_tmproot fm-herdr-owned-xdg-reap)/bin")
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
if [ "\$1" = session ]; then
  if [ -s $(printf '%q' "$root/leader.pid") ]; then
    printf '%s\\n' '{"sessions":[{"default":true,"name":"default","running":true,"socket_path":"/tmp/owned-xdg-reap.sock"}]}'
  else
    printf '%s\\n' '{"sessions":[]}'
  fi
  exit 0
fi
if [ "\$1" = server ]; then
  sleep 98764 &
  printf '%s\\n' "\$!" > $(printf '%q' "$root/child.pid")
  printf '%s\\n' "\$\$" > $(printf '%q' "$root/leader.pid")
  exec sleep 98765
fi
exit 90
SH
  chmod +x "$fakebin/herdr"
  PATH="$fakebin:$PATH" "$LAB" fixture start "$root" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "start must fail when the forked pid's comm is not herdr"
  [ -s "$root/leader.pid" ] || fail "the forked herdr did not record its pid"
  [ -s "$root/child.pid" ] || fail "the forked herdr did not record its process-group child"
  leader=$(cat "$root/leader.pid")
  child=$(cat "$root/child.pid")
  wait_until_gone "$leader" "start left the forked leader pid $leader running"
  wait_until_gone "$child" "start left process-group child $child running after the leader exited"
  herdr_fixture_cleanup "$root" || fail "cleanup after a failed start failed"
  pass "fm-herdr-lab fixture: a failed start whose forked pid is not comm=herdr signals the pid it forked, including the process group"
}

test_start_write_record_failure_signals_the_forked_process() {
  local root fakebin leader status=0
  root=$(herdr_fixture_create) || fail "create failed"
  remember_owned "$root"
  mkdir "$root/owned.record.tmp" || fail "could not occupy the record tmp path"
  fakebin=$(fm_fakebin "$(fm_test_tmproot fm-herdr-owned-xdg-write-record)/bin")
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
if [ "\$1" = session ]; then
  printf '%s\\n' '{"sessions":[]}'
  exit 0
fi
if [ "\$1" = server ]; then
  printf '%s\\n' "\$\$" > $(printf '%q' "$root/leader.pid")
  exec sleep 98766
fi
exit 90
SH
  chmod +x "$fakebin/herdr"
  PATH="$fakebin:$PATH" "$LAB" fixture start "$root" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "start must fail when the ownership record cannot be rewritten after fork"
  [ -s "$root/leader.pid" ] || fail "the forked herdr did not record its pid"
  leader=$(cat "$root/leader.pid")
  wait_until_gone "$leader" "start left the forked leader pid $leader running after write_record failed"
  rmdir "$root/owned.record.tmp" 2>/dev/null || true
  herdr_fixture_cleanup "$root" || fail "cleanup after a write_record failure failed"
  pass "fm-herdr-lab fixture: a write_record failure after fork signals the pid it started"
}

test_start_fails_fast_when_the_forked_pid_has_no_start_time() {
  local root fakebin real_ps leader status=0 out pid_recorded
  root=$(herdr_fixture_create) || fail "create failed"
  remember_owned "$root"
  install_renamed_sleep "$root/procbin/herdr"
  real_ps=$(command -v ps)
  fakebin=$(fm_fakebin "$(fm_test_tmproot fm-herdr-owned-xdg-empty-lstart)/bin")
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
case " \$* " in
  *' lstart= '*|*lstart=*) exit 0 ;;
esac
exec $(printf '%q' "$real_ps") "\$@"
SH
  chmod +x "$fakebin/ps"
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
if [ "\$1" = session ]; then
  printf '%s\\n' '{"sessions":[]}'
  exit 0
fi
if [ "\$1" = server ]; then
  printf '%s\\n' "\$\$" > $(printf '%q' "$root/leader.pid")
  exec $(printf '%q' "$root/procbin/herdr") 98770
fi
exit 90
SH
  chmod +x "$fakebin/herdr"
  status=0
  out=$(PATH="$fakebin:$PATH" "$LAB" fixture start "$root" 2>&1) || status=$?
  expect_code 1 "$status" "start must fail when the forked pid has no start time"
  [ -s "$root/leader.pid" ] || fail "the forked herdr did not record its pid"
  leader=$(cat "$root/leader.pid")
  assert_contains "$out" "$leader" "the empty-start refusal must name the pid left running"
  pid_recorded=$(sed -n 's/^pid=//p' "$root/owned.record")
  [ -z "$pid_recorded" ] || fail "start wrote a usable pid into the record without a start time"
  kill -0 "$leader" 2>/dev/null || fail "start reaped pid $leader that had no start time"
  kill -TERM "$leader" 2>/dev/null || true
  wait "$leader" 2>/dev/null || true
  herdr_fixture_cleanup "$root" || fail "cleanup after an empty-start refusal failed"
  pass "fm-herdr-lab fixture: start fails fast when the forked pid has no start time and writes no usable record"
}

test_start_reaps_when_session_list_hangs() {
  local root fakebin leader child status=0 started elapsed
  root=$(herdr_fixture_create) || fail "create failed"
  remember_owned "$root"
  install_renamed_sleep "$root/procbin/herdr"
  fakebin=$(fm_fakebin "$(fm_test_tmproot fm-herdr-owned-xdg-list-hang)/bin")
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
if [ "\$1" = session ]; then
  exec sleep 98771
fi
if [ "\$1" = server ]; then
  sleep 98772 &
  printf '%s\\n' "\$!" > $(printf '%q' "$root/child.pid")
  printf '%s\\n' "\$\$" > $(printf '%q' "$root/leader.pid")
  exec $(printf '%q' "$root/procbin/herdr") 98773
fi
exit 90
SH
  chmod +x "$fakebin/herdr"
  started=$SECONDS
  PATH="$fakebin:$PATH" "$LAB" fixture start "$root" >/dev/null 2>&1 || status=$?
  elapsed=$((SECONDS - started))
  expect_code 1 "$status" "start must fail when session list never returns"
  [ "$elapsed" -lt 20 ] || fail "start took ${elapsed}s; a first timed-out session list must return within 20s"
  [ -s "$root/leader.pid" ] || fail "the forked herdr did not record its pid"
  [ -s "$root/child.pid" ] || fail "the forked herdr did not record its process-group child"
  leader=$(cat "$root/leader.pid")
  child=$(cat "$root/child.pid")
  wait_until_gone "$leader" "start left the forked leader pid $leader running after session list hung"
  wait_until_gone "$child" "start left process-group child $child running after session list hung"
  herdr_fixture_cleanup "$root" || fail "cleanup after a hung session list failed"
  pass "fm-herdr-lab fixture: start reaps the forked pid when session list never returns"
}

test_reap_started_skips_a_pid_whose_start_time_no_longer_matches() {
  local root decoy
  root=$(herdr_fixture_create) || fail "create failed"
  remember_owned "$root"
  sleep 98767 &
  decoy=$!
  kill -0 "$decoy" 2>/dev/null || fail "the decoy pid did not start"
  fm_herdr_lab_fixture_reap_started "$root" "$decoy" "not-the-fork-start-time"
  kill -0 "$decoy" 2>/dev/null \
    || fail "reap_started signalled pid $decoy whose start time did not match the fork"
  kill -TERM "$decoy" 2>/dev/null || true
  wait "$decoy" 2>/dev/null || true
  herdr_fixture_cleanup "$root" || fail "cleanup after the reused-pid check failed"
  pass "fm-herdr-lab fixture: reap_started does not signal a pid whose start time no longer matches"
}

test_create_clears_inherited_identity_and_cleanup_removes_only_that_dir
test_cli_refuses_foreign_paths_and_unknown_commands
test_stop_refuses_a_live_non_herdr_pid
test_stop_refuses_herdr_named_pid_with_wrong_start_time
test_stop_refuses_herdr_named_pid_without_fixture_xdg
test_stop_refuses_herdr_named_pid_without_fixture_xdg_when_proc_is_hidden
test_stop_refuses_herdr_named_pid_when_darwin_ps_hides_env
test_stop_refuses_herdr_named_pid_when_xdg_is_only_in_argv
test_stop_refuses_herdr_named_pid_when_proc_is_unreadable_and_ps_e_is_absent
test_stop_refuses_herdr_named_pid_with_xdg_prefix_collision
test_stop_refuses_herdr_named_pid_with_xdg_prefix_collision_when_proc_is_hidden
test_stop_refuses_herdr_named_pid_when_xdg_is_a_space_inside_another_field
test_stop_refuses_herdr_named_pid_with_empty_readable_environ
test_stop_refuses_herdr_named_pid_when_xdg_is_forged_inside_a_nul_field
test_lab_tripwire_still_refuses_zero_and_multiple_defaults
test_fixture_stays_on_default_when_a_custom_fleet_session_is_exported
test_start_refuses_a_running_default_it_did_not_start
test_second_start_on_a_started_fixture_is_idempotent
test_start_failure_signals_the_forked_process_group
test_start_write_record_failure_signals_the_forked_process
test_start_fails_fast_when_the_forked_pid_has_no_start_time
test_start_reaps_when_session_list_hangs
test_reap_started_skips_a_pid_whose_start_time_no_longer_matches
