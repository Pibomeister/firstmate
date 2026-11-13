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

test_first_registration_requires_an_explicit_terminal() {
  local before
  setup explicit
  RC=0
  ORCA_TERMINAL_HANDLE=term_from_env FM_HOME="$HOME_DIR" \
    bash "$REG" n11-g1 --repo "$REPO" >/dev/null 2>"$CASE/err" || RC=$?
  ERR=$(cat "$CASE/err")
  [ "$RC" = 1 ] || fail "a first registration without --terminal must be refused, got $RC: $ERR"
  case "$ERR" in
    *"fm-lane-register: --terminal is required"*) ;;
    *) fail "the refusal did not say --terminal is required: $ERR" ;;
  esac
  [ ! -e "$RECORD" ] || fail "a refused first registration wrote a record"
  [ -z "$(ls -A "$HOME_DIR/state/external-lanes" 2>/dev/null)" ] || fail "a refused first registration left a file behind"

  mkdir -p "$HOME_DIR/state/external-lanes"
  printf 'repo=%s\nterminal=\nworktree=\nregistered=1\nupdated=1\n' "$REPO" > "$RECORD"
  before=$(cat "$RECORD")
  RC=0
  ORCA_TERMINAL_HANDLE=term_from_env FM_HOME="$HOME_DIR" \
    bash "$REG" n11-g1 --worktree "$WT" >/dev/null 2>"$CASE/err" || RC=$?
  ERR=$(cat "$CASE/err")
  [ "$RC" = 1 ] || fail "a lane with no recorded terminal must be refused, got $RC: $ERR"
  [ "$(cat "$RECORD")" = "$before" ] || fail "the refusal changed the record"

  RC=0
  ORCA_TERMINAL_HANDLE=term_from_env FM_HOME="$HOME_DIR" \
    bash "$REG" n11-g1 --terminal term_named >/dev/null 2>"$CASE/err" || RC=$?
  [ "$RC" = 0 ] || fail "naming --terminal on that lane failed: $(cat "$CASE/err")"
  [ "$(field terminal)" = term_named ] || fail "the environment handle was recorded instead of --terminal"

  RC=0
  ORCA_TERMINAL_HANDLE=term_other FM_HOME="$HOME_DIR" \
    bash "$REG" n11-g1 --worktree "$WT" >/dev/null 2>"$CASE/err" || RC=$?
  [ "$RC" = 0 ] || fail "an amend with --worktree failed: $(cat "$CASE/err")"
  [ "$(field terminal)" = term_named ] || fail "the amend replaced the terminal recorded at registration"
  [ "$(field worktree)" = "$WT" ] || fail "the amend did not record the worktree"
  [ "$(field repo)" = "$REPO" ] || fail "the amend dropped the repo"
  pass "a first registration names --terminal, and an amend keeps that handle"
}

test_refusals_write_nothing() {
  local other
  setup refuse
  RC=0
  env -u FM_HOME bash "$REG" n11-g1 --repo "$REPO" --terminal term_abc >/dev/null 2>&1 || RC=$?
  [ "$RC" = 1 ] || fail "a registration without FM_HOME must be refused, got $RC"
  register n11-g1 --terminal term_abc --worktree "$WT"
  [ "$RC" = 1 ] || fail "a first registration without --repo must be refused, got $RC"
  register n11-g1 --repo "$WT" --terminal term_abc
  [ "$RC" = 1 ] || fail "a linked worktree as --repo must be refused, got $RC"
  register n11-g1 --repo "$REPO" --terminal term_abc --worktree "$REPO"
  [ "$RC" = 1 ] || fail "the main checkout as --worktree must be refused, got $RC"
  fm_git_init_commit "$CASE/other"
  other=$(cd "$CASE/other" && pwd -P)
  register n11-g1 --repo "$other" --terminal term_abc --worktree "$WT"
  [ "$RC" = 1 ] || fail "a worktree of another repository must be refused, got $RC"
  register ../escape --repo "$REPO" --terminal term_abc
  [ "$RC" = 2 ] || fail "a lane id with a path separator must be refused, got $RC"
  register n11-g1 --repo relative/path --terminal term_abc
  [ "$RC" = 1 ] || fail "a relative --repo must be refused, got $RC"
  [ ! -e "$RECORD" ] || fail "a refused registration wrote a record"
  [ -z "$(ls -A "$HOME_DIR/state/external-lanes" 2>/dev/null)" ] || fail "a refused registration left a file behind"
  pass "every refused registration writes nothing"
}

test_a_worktree_belongs_to_one_lane() {
  local before
  setup one-owner
  register n11-g1 --repo "$REPO" --terminal term_abc --worktree "$WT"
  [ "$RC" = 0 ] || fail "the first lane could not register: $ERR"
  register n11-g2 --repo "$REPO" --terminal term_def --worktree "$WT"
  [ "$RC" = 1 ] || fail "a second lane naming the same worktree must be refused, got $RC"
  case "$ERR" in
    *"already registered by lane n11-g1"*) ;;
    *) fail "the refusal did not name the lane that owns the worktree: $ERR" ;;
  esac
  [ ! -e "$HOME_DIR/state/external-lanes/n11-g2.lane" ] || fail "the refused lane wrote a record"
  before=$(cat "$RECORD")
  register n11-g1 --worktree "$WT"
  [ "$RC" = 0 ] || fail "the owning lane could not amend its own worktree: $ERR"
  [ "$(field terminal)" = term_abc ] || fail "the amend lost the terminal"
  [ -n "$before" ] || fail "the first record was empty"
  pass "a worktree registers to one lane, and that lane may amend it again"
}

test_a_symlinked_lanes_directory_is_refused() {
  setup symlinked
  mkdir -p "$CASE/elsewhere"
  ln -s "$CASE/elsewhere" "$HOME_DIR/state/external-lanes"
  register n11-g1 --repo "$REPO" --terminal term_abc
  [ "$RC" = 1 ] || fail "a symlinked lanes directory must be refused, got $RC"
  [ -z "$(ls -A "$CASE/elsewhere")" ] || fail "the registration wrote through the symlink"
  pass "a registration refuses a symlinked lanes directory and writes nothing"
}

fm_test_run \
  test_register_then_amend_with_the_worktree \
  test_first_registration_requires_an_explicit_terminal \
  test_refusals_write_nothing \
  test_a_worktree_belongs_to_one_lane \
  test_a_symlinked_lanes_directory_is_refused
