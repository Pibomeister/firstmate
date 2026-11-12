#!/usr/bin/env bash
# Behavior tests for bin/fm-lane-register.sh: what a registration records,
# how a later call amends it, and which inputs it refuses.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REG="$ROOT/bin/fm-lane-register.sh"
TMP_ROOT=$(fm_test_tmproot fm-lane-register)

# setup <case>: a home, a lane repository, and one linked worktree of it.
setup() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  mkdir -p "$HOME_DIR/state"
  fm_git_worktree "$CASE/repo" "$CASE/wt" lane
  REPO=$(cd "$CASE/repo" && pwd -P)
  WT=$(cd "$CASE/wt" && pwd -P)
  RECORD="$HOME_DIR/state/external-lanes/n11-g1.lane"
}

register() {  # [args...] -> RC, ERR
  RC=0
  env -u ORCA_TERMINAL_HANDLE FM_HOME="$HOME_DIR" bash "$REG" "$@" >/dev/null 2>"$CASE/err" || RC=$?
  ERR=$(cat "$CASE/err")
}

field() {  # <key>: the recorded value
  awk -F= -v k="$1" '$1 == k { v = substr($0, length(k) + 2) } END { print v }' "$RECORD"
}

test_register_then_amend_with_the_worktree() {
  local registered
  setup amend
  register n11-g1 --repo "$REPO" --terminal term_abc
  [ "$RC" = 0 ] || fail "registration failed: $ERR"
  [ "$(field repo)" = "$REPO" ] || fail "repo was not recorded"
  [ "$(field terminal)" = term_abc ] || fail "terminal was not recorded"
  [ -z "$(field worktree)" ] || fail "an unnamed worktree was recorded"
  registered=$(field registered)
  case "$registered" in ''|*[!0-9]*) fail "registered is not an epoch: $registered" ;; esac
  register n11-g1 --worktree "$WT"
  [ "$RC" = 0 ] || fail "the worktree amendment failed: $ERR"
  [ "$(field worktree)" = "$WT" ] || fail "the worktree was not recorded"
  [ "$(field repo)" = "$REPO" ] || fail "the amendment dropped the repo"
  [ "$(field terminal)" = term_abc ] || fail "the amendment dropped the terminal"
  [ "$(field registered)" = "$registered" ] || fail "the amendment changed the registration time"
  pass "a lane registers at launch and later amends its worktree, keeping every other field"
}

test_terminal_defaults_to_the_orca_handle() {
  setup orcahandle
  RC=0
  ORCA_TERMINAL_HANDLE=term_from_env FM_HOME="$HOME_DIR" bash "$REG" n11-g1 --repo "$REPO" >/dev/null 2>"$CASE/err" || RC=$?
  [ "$RC" = 0 ] || fail "registration failed: $(cat "$CASE/err")"
  [ "$(field terminal)" = term_from_env ] || fail "the terminal did not default to ORCA_TERMINAL_HANDLE"
  pass "the terminal handle defaults to the Orca terminal the launcher runs in"
}

test_refusals_write_nothing() {
  local other
  setup refuse
  RC=0
  env -u FM_HOME bash "$REG" n11-g1 --repo "$REPO" >/dev/null 2>&1 || RC=$?
  [ "$RC" = 1 ] || fail "a registration without FM_HOME must be refused, got $RC"
  register n11-g1 --worktree "$WT"
  [ "$RC" = 1 ] || fail "a first registration without --repo must be refused, got $RC"
  register n11-g1 --repo "$WT"
  [ "$RC" = 1 ] || fail "a linked worktree as --repo must be refused, got $RC"
  register n11-g1 --repo "$REPO" --worktree "$REPO"
  [ "$RC" = 1 ] || fail "the main checkout as --worktree must be refused, got $RC"
  fm_git_init_commit "$CASE/other"
  other=$(cd "$CASE/other" && pwd -P)
  register n11-g1 --repo "$other" --worktree "$WT"
  [ "$RC" = 1 ] || fail "a worktree of another repository must be refused, got $RC"
  register ../escape --repo "$REPO"
  [ "$RC" = 2 ] || fail "a lane id with a path separator must be refused, got $RC"
  register n11-g1 --repo relative/path
  [ "$RC" = 1 ] || fail "a relative --repo must be refused, got $RC"
  [ ! -e "$RECORD" ] || fail "a refused registration wrote a record"
  [ -z "$(ls -A "$HOME_DIR/state/external-lanes" 2>/dev/null)" ] || fail "a refused registration left a file behind"
  pass "every refused registration writes nothing"
}

fm_test_run \
  test_register_then_amend_with_the_worktree \
  test_terminal_defaults_to_the_orca_handle \
  test_refusals_write_nothing
