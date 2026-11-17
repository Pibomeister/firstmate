#!/usr/bin/env bash
# Default-on live guard for bin/fm-herdr-lab.sh fixture start/check/stop/cleanup
# against a real Herdr server. Fake-herdr cases stay in
# tests/fm-herdr-owned-xdg.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

fm_live_gate default-on FM_HERDR_OWNED_XDG_LIVE herdr jq

LAB=$ROOT/bin/fm-herdr-lab.sh
OWNED_XDG_LIST=$(fm_test_tmproot fm-herdr-owned-xdg-live-roots)/roots
: > "$OWNED_XDG_LIST"

[ -x "$LAB" ] || fail "Herdr lab helper is not executable"

remember_owned() { # <root>
  printf '%s\n' "$1" >> "$OWNED_XDG_LIST"
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

test_live_owned_fixture_is_the_only_process_cleanup_stops() {
  local a b log fakebin status=0 name pid_a pid_b real_herdr
  real_herdr=$(command -v herdr)
  log=$(fm_test_tmproot fm-herdr-owned-xdg-live)/herdr.log
  fakebin=$(fm_fakebin "$(dirname "$log")")
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> $(printf '%q' "$log")
exec $(printf '%q' "$real_herdr") "\$@"
SH
  chmod +x "$fakebin/herdr"
  a=$("$LAB" fixture create) || fail "create A failed"
  remember_owned "$a"
  b=$("$LAB" fixture create) || fail "create B failed"
  remember_owned "$b"
  PATH="$fakebin:$PATH" "$LAB" fixture start "$a" || fail "start A failed"
  PATH="$fakebin:$PATH" "$LAB" fixture start "$b" || fail "start B failed"
  pid_a=$(sed -n 's/^pid=//p' "$a/owned.record")
  pid_b=$(sed -n 's/^pid=//p' "$b/owned.record")
  PATH="$fakebin:$PATH" "$LAB" fixture check "$a" || fail "check A failed"
  PATH="$fakebin:$PATH" "$LAB" fixture check "$b" || fail "check B failed"
  eval "$("$LAB" fixture apply "$a")"
  name=fm-lab-owned-$$
  FM_HERDR_LAB_STATE_DIR="$a/lab" "$LAB" provision "$name" >/dev/null || fail "lab provision in owned A failed"
  FM_HERDR_LAB_STATE_DIR="$a/lab" "$LAB" teardown "$name" >/dev/null || fail "lab teardown in owned A failed"
  eval "$("$LAB" fixture apply "$b")"
  PATH="$fakebin:$PATH" "$LAB" fixture cleanup "$a" || fail "cleanup A failed"
  [ ! -d "$a" ] || fail "cleanup A left its directory"
  kill -0 "$pid_a" 2>/dev/null && fail "cleanup A left its herdr process"
  kill -0 "$pid_b" 2>/dev/null || fail "cleanup A stopped fixture B's herdr process"
  PATH="$fakebin:$PATH" "$LAB" fixture check "$b" || fail "cleanup A stopped fixture B"
  PATH="$fakebin:$PATH" "$LAB" fixture cleanup "$b" || fail "cleanup B failed"
  [ ! -d "$b" ] || fail "cleanup B left its directory"
  kill -0 "$pid_b" 2>/dev/null && fail "cleanup B left its herdr process"
  ! grep -Fq 'server stop' "$log" || fail "lifecycle invoked herdr server stop"
  status=0
  "$LAB" fixture apply "$a" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "apply after cleanup must refuse the removed fixture"
  pass "fm-herdr-lab fixture: live start/check/stop own only the recorded fixture and never call server stop"
}

test_live_empty_owned_xdg_still_trips_lab_provision() {
  local root status=0 out name
  root=$("$LAB" fixture create) || fail "create failed"
  remember_owned "$root"
  eval "$("$LAB" fixture apply "$root")"
  name=fm-lab-zero-$$
  out=$(FM_HERDR_LAB_STATE_DIR="$root/lab" "$LAB" provision "$name" 2>&1) || status=$?
  expect_code 1 "$status" "lab provision in a never-started owned XDG must fail"
  assert_contains "$out" "fleet-state tripwire requires exactly one running default session" \
    "zero-default live refusal changed its tripwire wording"
  "$LAB" fixture cleanup "$root" || fail "cleanup of the never-started live fixture failed"
  pass "fm-herdr-lab: live empty owned XDG still refuses provision without a running default"
}

test_live_empty_owned_xdg_still_trips_lab_provision
test_live_owned_fixture_is_the_only_process_cleanup_stops
