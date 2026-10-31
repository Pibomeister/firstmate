#!/usr/bin/env bash
# Behavioral coverage for tracked fleet learnings at session start and AFK preflight.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fleet-learnings)
FLEET="$ROOT/bin/fm-fleet-learnings.sh"
PREFLIGHT="$ROOT/bin/fm-afk-preflight.sh"
SESSION_START="$ROOT/bin/fm-session-start.sh"
LAUNCH="$ROOT/bin/fm-afk-launch.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

make_min_root() {
  local dir=$1
  mkdir -p "$dir/docs/learnings"
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
}

test_digest_present_in_repo_root() {
  local out
  out=$("$FLEET" digest)
  assert_contains "$out" 'docs/learnings/overnight-learnings.md (tracked fleet learnings' \
    "digest did not label fleet learnings"
  assert_contains "$out" 'Preflight readiness was guessed' \
    "digest did not include shipped fleet learnings content"
  pass "digest prints tracked fleet learnings from the code root"
}

test_digest_absent_does_not_block() {
  local root=$TMP_ROOT/absent-root home=$TMP_ROOT/absent-home out status
  make_min_root "$root"
  mkdir -p "$home/state" "$home/data" "$home/config"
  out=$(FM_ROOT_OVERRIDE="$root" "$FLEET" digest)
  status=$?
  assert_contains "$out" 'ABSENT' "missing fleet learnings did not print ABSENT"
  [ "$status" -eq 0 ] || fail "missing fleet learnings digest exited $status"
  pass "missing fleet learnings digest exits 0"
}

test_preflight_includes_fleet_learnings() {
  local home=$TMP_ROOT/preflight-home out
  mkdir -p "$home/state" "$home/data" "$home/config"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" "$PREFLIGHT")
  assert_contains "$out" 'AFK PREFLIGHT' "preflight did not name its section"
  assert_contains "$out" 'Preflight readiness was guessed' \
    "preflight did not include fleet learnings"
  pass "AFK preflight prints fleet learnings"
}

test_afk_enter_runs_preflight() {
  local home=$TMP_ROOT/enter-home out
  mkdir -p "$home/state" "$home/data" "$home/config"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_HARNESS=codex FM_TEST_SEAM=1 "$LAUNCH" enter --words 'hold the fleet' 2>&1)
  assert_contains "$out" 'AFK PREFLIGHT' "enter did not run AFK preflight"
  assert_contains "$out" 'Preflight readiness was guessed' \
    "enter preflight did not include fleet learnings"
  pass "/afk enter runs AFK preflight with fleet learnings"
}

make_fake_toolchain() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  fm_fake_exit0 "$fakebin" tmux node chrome-devtools-axi gh treehouse no-mistakes quota-axi tasks-axi
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && printf '0.1.29\n'
exit 0
SH
  chmod +x "$fakebin/gh-axi"
  printf '%s\n' "$fakebin"
}

test_session_start_includes_fleet_learnings_when_root_has_file() {
  local root=$TMP_ROOT/ss-root home=$TMP_ROOT/ss-home fakebin out
  make_min_root "$root"
  cp "$ROOT/docs/learnings/overnight-learnings.md" "$root/docs/learnings/overnight-learnings.md"
  mkdir -p "$home/state" "$home/data" "$home/config"
  fakebin=$(make_fake_toolchain "$TMP_ROOT/ss-fakebin-a")
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_FAKE_HARNESS=codex FM_FAKE_HARNESS_PID=$$ PATH="$fakebin:$BASE_PATH" \
    "$SESSION_START" 2>&1 | head -n 400)
  assert_contains "$out" 'docs/learnings/overnight-learnings.md (tracked fleet learnings' \
    "session start did not label fleet learnings in CONTEXT"
  assert_contains "$out" 'Prompts lost during restarts' \
    "session start did not print fleet learnings body"
  pass "session start CONTEXT includes fleet learnings when the code root ships them"
}

test_session_start_missing_fleet_learnings_nonblocking() {
  local root=$TMP_ROOT/ss-miss-root home=$TMP_ROOT/ss-miss-home fakebin out status
  make_min_root "$root"
  mkdir -p "$home/state" "$home/data" "$home/config"
  fakebin=$(make_fake_toolchain "$TMP_ROOT/ss-fakebin-b")
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_FAKE_HARNESS=codex FM_FAKE_HARNESS_PID=$$ PATH="$fakebin:$BASE_PATH" \
    "$SESSION_START" 2>&1)
  status=$?
  assert_contains "$out" 'docs/learnings/overnight-learnings.md (tracked fleet learnings' \
    "session start did not mention fleet learnings subsection"
  fleet_section=$(printf '%s\n' "$out" | awk '/^docs\/learnings\/overnight-learnings\.md \(tracked fleet learnings/{flag=1;next}/^data\//{flag=0}flag')
  assert_contains "$fleet_section" 'ABSENT' "missing fleet learnings section did not print ABSENT"
  [ "$status" -eq 0 ] || fail "session start exited $status when fleet learnings were absent"
  pass "session start stays exit 0 when fleet learnings are absent"
}

test_digest_present_in_repo_root
test_digest_absent_does_not_block
test_preflight_includes_fleet_learnings
test_afk_enter_runs_preflight
test_session_start_includes_fleet_learnings_when_root_has_file
test_session_start_missing_fleet_learnings_nonblocking

echo "# fm-fleet-learnings.test.sh: all assertions passed"
