#!/usr/bin/env bash
# Behavior tests for bin/fm-lifecycle-lib.sh, the shared lifecycle library
# bin/fm-teardown.sh sources for its non-force guards and retirement steps.
#
# Compatibility: teardown refuses before any side effect when the
# library is missing, carries another API version, or does not declare one even
# though the caller's environment does. Each case runs the real teardown,
# reached through a fixture bin directory of links to every real sibling with
# only the library replaced, and proves the task record is byte-identical and no
# lock directory was created afterwards.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lifecycle-tests)

# make_lifecycle_fixture <name> <library: real|missing|stub-v2|stub-unversioned>:
# a home whose bin/ links every real bin/ file except the lifecycle library,
# plus one ordinary task record. Prints the home path.
make_lifecycle_fixture() {
  local name=$1 library=$2 home f
  home="$TMP_ROOT/$name"
  mkdir -p "$home/bin" "$home/state" "$home/data" "$home/config"
  for f in "$ROOT"/bin/*; do
    [ "$(basename "$f")" = fm-lifecycle-lib.sh ] && continue
    ln -s "$f" "$home/bin/$(basename "$f")"
  done
  case "$library" in
    real) ln -s "$ROOT/bin/fm-lifecycle-lib.sh" "$home/bin/fm-lifecycle-lib.sh" ;;
    missing) ;;
    stub-v2)
      printf '%s\n' '# stub: a library from another release' 'FM_LIFECYCLE_API_VERSION=2' \
        > "$home/bin/fm-lifecycle-lib.sh"
      ;;
    stub-unversioned)
      printf '%s\n' '# stub: a library that declares no API version' \
        > "$home/bin/fm-lifecycle-lib.sh"
      ;;
  esac
  fm_write_meta "$home/state/t1.meta" \
    "window=fakeses:fm-t1" \
    "endpoint_task_id=t1" \
    "worktree=$TMP_ROOT/$name-missing-worktree" \
    "project=$TMP_ROOT/$name-missing-project" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "spawn_gen=s1.1.1"
  printf '%s\n' "$home"
}

# state_fingerprint <home>: the record's bytes plus the list of state entries,
# so a refusal that changed nothing leaves the fingerprint identical.
state_fingerprint() {
  {
    shasum -a 256 "$1/state/t1.meta" | cut -d' ' -f1
    (cd "$1/state" && LC_ALL=C ls -A)
  } | shasum -a 256 | cut -d' ' -f1
}

run_teardown() {  # <home> [env assignments...]
  local home=$1
  shift
  env "$@" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-teardown.sh" t1
}

# --- missing library -----------------------------------------------------------
home=$(make_lifecycle_fixture missing missing)
before=$(state_fingerprint "$home")
out=$(run_teardown "$home" 2>&1); rc=$?
assert_equals 1 "$rc" "a missing lifecycle library refuses teardown"
assert_equals "$before" "$(state_fingerprint "$home")" "a missing lifecycle library changes no task state"
assert_contains "$out" "required source fm-lifecycle-lib.sh is missing or unreadable; nothing was changed" \
  "a missing lifecycle library is named in the refusal"
pass "teardown refuses before any side effect when the lifecycle library is missing"

# --- another API version -------------------------------------------------------
home=$(make_lifecycle_fixture v2 stub-v2)
before=$(state_fingerprint "$home")
out=$(run_teardown "$home" 2>&1); rc=$?
assert_equals 1 "$rc" "a lifecycle library with another API version refuses teardown"
assert_equals "$before" "$(state_fingerprint "$home")" "a mismatched API version changes no task state"
assert_contains "$out" "fm-lifecycle-lib.sh has API version 2, not 1; nothing was changed" \
  "the mismatched API version is named in the refusal"
pass "teardown refuses before any side effect when the lifecycle library has another API version"

# --- no declared version, inherited version in the environment ----------------
home=$(make_lifecycle_fixture unversioned stub-unversioned)
before=$(state_fingerprint "$home")
out=$(run_teardown "$home" FM_LIFECYCLE_API_VERSION=1 2>&1); rc=$?
assert_equals 1 "$rc" "an inherited API version does not stand in for the library's own"
assert_equals "$before" "$(state_fingerprint "$home")" "an undeclared API version changes no task state"
assert_contains "$out" "fm-lifecycle-lib.sh has API version <none>, not 1; nothing was changed" \
  "the undeclared API version is named in the refusal"
pass "teardown ignores an inherited API version and refuses a library that declares none"

# --- control: the real library passes the gate ---------------------------------
# With the real library and no task id, teardown gets past the version gate and
# stops at its own request validation (exit 2) without touching any state, even
# when the environment carries another API version.
home=$(make_lifecycle_fixture real real)
before=$(state_fingerprint "$home")
rc=0
out=$(env FM_LIFECYCLE_API_VERSION=2 FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
  "$home/bin/fm-teardown.sh" 2>&1) || rc=$?
assert_equals 2 "$rc" "the real library reaches teardown's request validation"
assert_equals "$before" "$(state_fingerprint "$home")" "the control changes no task state"
assert_contains "$out" "invalid teardown request" "the real library passes the compatibility gate"
assert_not_contains "$out" "fm-lifecycle-lib.sh" "the real library raises no compatibility refusal"
pass "teardown with the real lifecycle library passes the compatibility gate despite an inherited version"

home=$(make_lifecycle_fixture source-later real)
before=$(state_fingerprint "$home")
ready=$TMP_ROOT/source-later.ready
go=$TMP_ROOT/source-later.go
out_file=$TMP_ROOT/source-later.out
rm "$home/bin/fm-nm-run-lib.sh"
cat > "$home/bin/fm-nm-run-lib.sh" <<'SH'
printf 'ready\n' > "$FM_TEST_SOURCE_READY"
while [ ! -e "$FM_TEST_SOURCE_GO" ]; do sleep 0.05; done
. "$FM_TEST_REAL_NM_LIB"
SH
env FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
  FM_TEST_SOURCE_READY="$ready" FM_TEST_SOURCE_GO="$go" \
  FM_TEST_REAL_NM_LIB="$ROOT/bin/fm-nm-run-lib.sh" \
  "$home/bin/fm-teardown.sh" t1 >"$out_file" 2>&1 &
old_pid=$!
n=0
while [ "$n" -lt 80 ] && [ ! -e "$ready" ]; do
  sleep 0.05
  n=$((n + 1))
done
[ -e "$ready" ] || fail "the source-later process did not start"
rm -f "$home/bin/fm-lifecycle-lib.sh"
printf '%s\n' '# stub: a library from another release' 'FM_LIFECYCLE_API_VERSION=2' \
  > "$home/bin/fm-lifecycle-lib.sh"
: > "$go"
old_rc=0
wait "$old_pid" || old_rc=$?
assert_equals 1 "$old_rc" "an old process sourcing later refuses an incompatible library"
assert_equals "$before" "$(state_fingerprint "$home")" "an old source-later process changes no task state"
assert_contains "$(cat "$out_file")" "fm-lifecycle-lib.sh has API version 2, not 1; nothing was changed" \
  "the source-later refusal names the incompatible library"
pass "old teardown process sourcing later refuses incompatible lifecycle library before side effects"
