#!/usr/bin/env bash
# Behavior tests for bin/fm-herdr-owned-xdg.sh and the lab tripwire it must
# not weaken. Live start/check/stop cases run wherever herdr and jq exist.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-owned-xdg.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-owned-xdg.sh"

HELPER=$ROOT/bin/fm-herdr-owned-xdg.sh
LAB=$ROOT/bin/fm-herdr-lab.sh
OWNED_XDG_LIST=$(fm_test_tmproot fm-herdr-owned-xdg-roots)/roots
: > "$OWNED_XDG_LIST"

[ -x "$HELPER" ] || fail "owned XDG helper is not executable"

remember_owned() { # <root>
  printf '%s\n' "$1" >> "$OWNED_XDG_LIST"
}

owned_suite_cleanup() {
  local root
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    "$HELPER" cleanup "$root" >/dev/null 2>&1 || true
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
  fm_herdr_owned_xdg_create > "$pathfile" || fail "create failed"
  [ -z "${HERDR_SESSION:-}" ] || fail "create left HERDR_SESSION set"
  [ -z "${HERDR_PANE_ID:-}" ] || fail "create left HERDR_PANE_ID set"
  [ -z "${HERDR_SOCKET_PATH:-}" ] || fail "create left HERDR_SOCKET_PATH set"
  root=$(cat "$pathfile")
  remember_owned "$root"
  [ -d "$root" ] || fail "create did not print a directory"
  [ -d "$sibling" ] || fail "create removed an unrelated hx directory"
  fm_herdr_owned_xdg_cleanup "$root" || fail "cleanup of a never-started fixture failed"
  [ ! -d "$root" ] || fail "cleanup left the owned directory"
  [ -f "$sibling/keep" ] || fail "cleanup removed an unrelated hx directory"
  rm -rf "$sibling"
  status=0
  fm_herdr_owned_xdg_cleanup /tmp >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "cleanup must refuse /tmp"
  pass "fm-herdr-owned-xdg: create clears inherited Herdr identity and cleanup removes only the owned directory"
}

test_cli_refuses_foreign_paths_and_unknown_commands() {
  local status=0 out
  out=$("$HELPER" start /tmp 2>&1) || status=$?
  expect_code 1 "$status" "start must refuse /tmp"
  assert_contains "$out" "owned" "foreign-path refusal was unclear"
  status=0
  "$HELPER" start default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "start must not accept a session name"
  status=0
  "$HELPER" server stop >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "the helper must not grow a server-stop command"
  pass "fm-herdr-owned-xdg: CLI refuses foreign paths, session names, and server stop"
}

test_stop_refuses_a_live_non_herdr_pid() {
  local root pid start status=0 token
  root=$(fm_herdr_owned_xdg_create) || fail "create failed"
  remember_owned "$root"
  token=$(cat "$root/.fm-herdr-owned")
  sleep 30 &
  pid=$!
  start=$(LC_ALL=C ps -p "$pid" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  printf 'schema=fm-herdr-owned-xdg.v1\nxdg_root=%s\nmarker_token=%s\npid=%s\npid_start=%s\n' \
    "$root" "$token" "$pid" "$start" > "$root/owned.record"
  fm_herdr_owned_xdg_stop "$root" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "stop must refuse a live non-herdr pid"
  kill -0 "$pid" 2>/dev/null || fail "stop signalled a sleep process stuffed into the record"
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  fm_herdr_owned_xdg_stop "$root" || fail "stop did not become a no-op after the foreign pid exited"
  fm_herdr_owned_xdg_cleanup "$root" || fail "cleanup after a refused stop failed"
  pass "fm-herdr-owned-xdg: stop refuses a live process that is not this fixture's herdr"
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

test_live_owned_fixture_is_the_only_process_cleanup_stops() {
  local a b log fakebin status=0 name pid_a pid_b real_herdr
  command -v herdr >/dev/null 2>&1 || { pass "fm-herdr-owned-xdg: live isolation (skipped, no herdr)"; return; }
  command -v jq >/dev/null 2>&1 || { pass "fm-herdr-owned-xdg: live isolation (skipped, no jq)"; return; }
  real_herdr=$(command -v herdr)
  log=$(fm_test_tmproot fm-herdr-owned-xdg-live)/herdr.log
  fakebin=$(fm_fakebin "$(dirname "$log")")
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> $(printf '%q' "$log")
exec $(printf '%q' "$real_herdr") "\$@"
SH
  chmod +x "$fakebin/herdr"
  a=$("$HELPER" create) || fail "create A failed"
  remember_owned "$a"
  b=$("$HELPER" create) || fail "create B failed"
  remember_owned "$b"
  PATH="$fakebin:$PATH" "$HELPER" start "$a" || fail "start A failed"
  PATH="$fakebin:$PATH" "$HELPER" start "$b" || fail "start B failed"
  pid_a=$(sed -n 's/^pid=//p' "$a/owned.record")
  pid_b=$(sed -n 's/^pid=//p' "$b/owned.record")
  PATH="$fakebin:$PATH" "$HELPER" check "$a" || fail "check A failed"
  PATH="$fakebin:$PATH" "$HELPER" check "$b" || fail "check B failed"
  eval "$("$HELPER" apply "$a")"
  name=fm-lab-owned-$$
  FM_HERDR_LAB_STATE_DIR="$a/lab" "$LAB" provision "$name" >/dev/null || fail "lab provision in owned A failed"
  FM_HERDR_LAB_STATE_DIR="$a/lab" "$LAB" teardown "$name" >/dev/null || fail "lab teardown in owned A failed"
  eval "$("$HELPER" apply "$b")"
  PATH="$fakebin:$PATH" "$HELPER" cleanup "$a" || fail "cleanup A failed"
  [ ! -d "$a" ] || fail "cleanup A left its directory"
  kill -0 "$pid_a" 2>/dev/null && fail "cleanup A left its herdr process"
  kill -0 "$pid_b" 2>/dev/null || fail "cleanup A stopped fixture B's herdr process"
  PATH="$fakebin:$PATH" "$HELPER" check "$b" || fail "cleanup A stopped fixture B"
  PATH="$fakebin:$PATH" "$HELPER" cleanup "$b" || fail "cleanup B failed"
  [ ! -d "$b" ] || fail "cleanup B left its directory"
  kill -0 "$pid_b" 2>/dev/null && fail "cleanup B left its herdr process"
  ! grep -Fq 'server stop' "$log" || fail "lifecycle invoked herdr server stop"
  status=0
  "$HELPER" apply "$a" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "apply after cleanup must refuse the removed fixture"
  pass "fm-herdr-owned-xdg: live start/check/stop own only the recorded fixture and never call server stop"
}

test_start_failure_signals_the_forked_process_group() {
  local root fakebin leader child status=0
  root=$(fm_herdr_owned_xdg_create) || fail "create failed"
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
  PATH="$fakebin:$PATH" "$HELPER" start "$root" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "start must fail when the default session never becomes ready"
  [ -s "$root/leader.pid" ] || fail "the forked herdr did not record its pid"
  [ -s "$root/child.pid" ] || fail "the forked herdr did not record its process-group child"
  leader=$(cat "$root/leader.pid")
  child=$(cat "$root/child.pid")
  kill -0 "$leader" 2>/dev/null && fail "start left the forked leader pid $leader running"
  kill -0 "$child" 2>/dev/null && fail "start left process-group child $child running after the leader exited"
  fm_herdr_owned_xdg_cleanup "$root" || fail "cleanup after a failed start failed"
  pass "fm-herdr-owned-xdg: a failed start signals the pid it forked, including the process group"
}

test_live_empty_owned_xdg_still_trips_lab_provision() {
  local root status=0 out name
  command -v herdr >/dev/null 2>&1 || { pass "fm-herdr-owned-xdg: live zero-default (skipped, no herdr)"; return; }
  command -v jq >/dev/null 2>&1 || { pass "fm-herdr-owned-xdg: live zero-default (skipped, no jq)"; return; }
  root=$("$HELPER" create) || fail "create failed"
  remember_owned "$root"
  eval "$("$HELPER" apply "$root")"
  name=fm-lab-zero-$$
  out=$(FM_HERDR_LAB_STATE_DIR="$root/lab" "$LAB" provision "$name" 2>&1) || status=$?
  expect_code 1 "$status" "lab provision in a never-started owned XDG must fail"
  assert_contains "$out" "fleet-state tripwire requires exactly one running default session" \
    "zero-default live refusal changed its tripwire wording"
  "$HELPER" cleanup "$root" || fail "cleanup of the never-started live fixture failed"
  pass "fm-herdr-lab: live empty owned XDG still refuses provision without a running default"
}

test_create_clears_inherited_identity_and_cleanup_removes_only_that_dir
test_cli_refuses_foreign_paths_and_unknown_commands
test_stop_refuses_a_live_non_herdr_pid
test_lab_tripwire_still_refuses_zero_and_multiple_defaults
test_start_failure_signals_the_forked_process_group
test_live_empty_owned_xdg_still_trips_lab_provision
test_live_owned_fixture_is_the_only_process_cleanup_stops
