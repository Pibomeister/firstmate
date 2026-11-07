#!/usr/bin/env bash
# Tests for home code drift self-heal (issue #93): a running home keeps
# executing old bin/ code after self-heal fixes merge to main.
#
# The drift check runs on the deferred network path a lock-owning session
# start launches (bin/fm-bootstrap.sh with FM_BOOTSTRAP_NETWORK=only, driven
# by bin/fm-startup-network.sh), never on the blocking digest path. These
# tests drive that exact public bootstrap invocation against a fixture
# FM_ROOT clone:
#   - behind + clean + fast-forwardable: fast-forwards via fm-ff-lib.sh and
#     prints one HOME_DRIFT line naming the behind count
#   - behind + dirty: prints one HOME_DRIFT line naming the count and the
#     dirty reason, preserves the edit, and moves nothing
#   - up to date: silent, moves nothing
#   - fetch failure: prints one HOME_DRIFT line, moves nothing, exits 0 so
#     startup is never blocked or failed by the network
#   - detect-only (the read-only / re-emit session-start path): no fetch, no
#     fast-forward, no HOME_DRIFT line
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"

fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-session-start-drift-tests)

new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config" "$w/fakebin"
  cat > "$w/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$w/fakebin/gh"
  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null
  printf 'v1\n' > "$w/seed/AGENTS.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main
  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true
  printf '%s\n' "$w"
}

bump_origin() {
  local w=$1 n=${2:-1} i=0
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  while [ "$i" -lt "$n" ]; do
    printf 'bump %s\n' "$i" >> "$w/seed/README.md"
    git -C "$w/seed" add -A
    git -C "$w/seed" commit -qm "bump-$i"
    i=$((i + 1))
  done
  git -C "$w/seed" push -q origin main
}

run_drift() {
  local w=$1
  PATH="$w/fakebin:$PATH" FM_BOOTSTRAP_NETWORK=only \
    FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
    bash "$BOOTSTRAP" 2>/dev/null
}

test_behind_clean_fast_forwards() {
  local w out
  w=$(new_world behind-clean)
  bump_origin "$w" 2
  out=$(run_drift "$w")
  assert_contains "$out" "HOME_DRIFT:" "behind+clean must print a HOME_DRIFT line"
  assert_contains "$out" "2 commit(s) behind origin/main" "HOME_DRIFT must name the behind count"
  assert_contains "$out" "fast-forwarded to" "behind+clean must fast-forward"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "behind+clean HEAD did not reach origin/main"
  [ "$(git -C "$w/main" symbolic-ref --short HEAD)" = "main" ] \
    || fail "behind+clean left the default branch"
  pass "behind+clean fast-forwards and reports the behind count"
}

test_behind_dirty_is_reported_and_preserved() {
  local w out before
  w=$(new_world behind-dirty)
  bump_origin "$w" 1
  before=$(git -C "$w/main" rev-parse HEAD)
  printf 'uncommitted local edit\n' >> "$w/main/AGENTS.md"
  out=$(run_drift "$w")
  assert_contains "$out" "HOME_DRIFT:" "behind+dirty must print a HOME_DRIFT line"
  assert_contains "$out" "1 commit(s) behind origin/main" "HOME_DRIFT must name the behind count"
  assert_contains "$out" "not fast-forwarded: dirty working tree" "HOME_DRIFT must name the dirty reason"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "behind+dirty HEAD moved"
  grep -q 'uncommitted local edit' "$w/main/AGENTS.md" \
    || fail "behind+dirty edit was discarded"
  pass "behind+dirty is reported with its reason and preserved"
}

test_up_to_date_is_silent() {
  local w out before
  w=$(new_world up-to-date)
  before=$(git -C "$w/main" rev-parse HEAD)
  out=$(run_drift "$w")
  assert_not_contains "$out" "HOME_DRIFT:" "up-to-date must not print a HOME_DRIFT line"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "up-to-date HEAD moved"
  pass "up-to-date is silent and moves nothing"
}

test_fetch_failure_is_reported_without_blocking() {
  local w out before rc=0
  w=$(new_world fetch-failure)
  bump_origin "$w" 1
  before=$(git -C "$w/main" rev-parse HEAD)
  git -C "$w/main" remote set-url origin "$w/no-such-origin.git"
  out=$(run_drift "$w") || rc=$?
  [ "$rc" -eq 0 ] || fail "fetch failure must not fail bootstrap, got exit $rc"
  assert_contains "$out" "HOME_DRIFT:" "fetch failure must print a HOME_DRIFT line"
  assert_contains "$out" "fetch failed" "fetch failure HOME_DRIFT must name the fetch failure"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "fetch failure HEAD moved"
  pass "fetch failure is reported, moves nothing, and does not fail startup"
}

test_detect_only_never_fast_forwards() {
  local w out before
  w=$(new_world detect-only)
  bump_origin "$w" 1
  before=$(git -C "$w/main" rev-parse HEAD)
  out=$(PATH="$w/fakebin:$PATH" FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" bash "$BOOTSTRAP" 2>/dev/null)
  assert_not_contains "$out" "HOME_DRIFT:" "detect-only must not print a HOME_DRIFT line"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detect-only HEAD moved"
  pass "detect-only (read-only session) never fast-forwards"
}

fm_test_run \
  test_behind_clean_fast_forwards \
  test_behind_dirty_is_reported_and_preserved \
  test_up_to_date_is_silent \
  test_fetch_failure_is_reported_without_blocking \
  test_detect_only_never_fast_forwards
